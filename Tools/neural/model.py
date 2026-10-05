"""The denoising upscaler: a recurrent U-Net at the render resolution that reads the frame's noisy light and guides
plus last frame's output (warped by the motion vectors and folded into the render resolution, 3x3 output pixels per
render pixel) and writes this frame's output at the output resolution.

Every operation is one the Metal kernels (Shaders/Neural.metal) do the same way: 3x3 convolutions with ReLU, 2x2 max
pooling, nearest 2x upsampling, concatenation, pixel (un)shuffle by the upscale factor, and a bilinear warp with
clamped edges (`grid_sample(align_corners=False, padding_mode="border")`).
"""
import torch
import torch.nn as nn
import torch.nn.functional as F

GUIDES = 14          # log colour 3, albedo 3, specular albedo 3, normal 3, depth 1, roughness 1
HIDDEN = 8           # recurrent state per output pixel, next to the output's 3 (log) colour channels
WIDTHS = (32, 48, 64)


def prepare(color, albedo, specular, normal, roughness, exposure):
    """The per-frame input channels, (B, GUIDES, H, W), from the arrays as saved (channels first, float32)."""
    log_color = torch.log1p(torch.clamp(color, min=0) * exposure.view(-1, 1, 1, 1))
    view_depth = normal[:, 3:4]
    depth = torch.where(view_depth > 0, 1 / (1 + view_depth), torch.zeros_like(view_depth))   # sky: 0
    return torch.cat([log_color, albedo, specular, normal[:, :3], depth, roughness], 1)


def warp(image, motion, factor):
    """`image` (output resolution) moved to this frame: each output pixel reads last frame's at its position plus the
    motion (render pixels, previous minus current, upsampled to the output by nearest)."""
    b, _, h, w = image.shape
    m = F.interpolate(motion, scale_factor=factor, mode="nearest") * factor
    ys, xs = torch.meshgrid(torch.arange(h, device=image.device), torch.arange(w, device=image.device), indexing="ij")
    gx = (xs + 0.5 + m[:, 0]) / w * 2 - 1
    gy = (ys + 0.5 + m[:, 1]) / h * 2 - 1
    grid = torch.stack([gx, gy], -1)
    return F.grid_sample(image, grid, mode="bilinear", padding_mode="border", align_corners=False)


def conv(cin, cout):
    return nn.Conv2d(cin, cout, 3, padding=1)


class DenoisingUpscaler(nn.Module):
    def __init__(self, factor=3):
        super().__init__()
        self.factor = factor
        f2 = factor * factor
        w0, w1, w2 = WIDTHS
        cin = GUIDES + 2 + f2 * (3 + HIDDEN)   # guides, jitter, last frame's output and state folded
        self.enc0 = nn.ModuleList([conv(cin, w0), conv(w0, w0)])
        self.enc1 = nn.ModuleList([conv(w0, w1), conv(w1, w1)])
        self.mid = nn.ModuleList([conv(w1, w2), conv(w2, w2)])
        self.dec1 = nn.ModuleList([conv(w2 + w1, w1), conv(w1, w1)])
        self.dec0 = nn.ModuleList([conv(w1 + w0, w0), conv(w0, w0)])
        self.head = conv(w0, f2 * (1 + 3 + HIDDEN))   # per output pixel: blend, new colour, state

    @staticmethod
    def _run(layers, x):
        for layer in layers:
            x = F.relu(layer(x))
        return x

    def initial_state(self, b, h, w, device):
        """No history (the first frame, or after a reset): zero output and state at the output resolution."""
        f = self.factor
        return torch.zeros(b, 3 + HIDDEN, h * f, w * f, device=device)

    def forward(self, guides, motion, jitter, state):
        """One frame. guides (B, GUIDES, H, W), motion (B, 2, H, W), jitter (B, 2), state (B, 3 + HIDDEN, fH, fW).
        Returns the output in log space, (B, 3, fH, fW), and the new state (output + hidden)."""
        f = self.factor
        b, _, h, w = guides.shape
        history = warp(state, motion, f)
        jit = jitter.view(b, 2, 1, 1).expand(b, 2, h, w)
        x = torch.cat([guides, jit, F.pixel_unshuffle(history, f)], 1)
        e0 = self._run(self.enc0, x)
        e1 = self._run(self.enc1, F.max_pool2d(e0, 2))
        m = self._run(self.mid, F.max_pool2d(e1, 2))
        d1 = self._run(self.dec1, torch.cat([F.interpolate(m, scale_factor=2, mode="nearest"), e1], 1))
        d0 = self._run(self.dec0, torch.cat([F.interpolate(d1, scale_factor=2, mode="nearest"), e0], 1))
        y = F.pixel_shuffle(self.head(d0), f)
        alpha = torch.sigmoid(y[:, 0:1])
        new = y[:, 1:4]
        hidden = torch.tanh(y[:, 4:])
        out = torch.clamp(alpha * history[:, :3] + (1 - alpha) * new, min=0)
        return out, torch.cat([out, hidden], 1)


def to_linear(log_out, exposure):
    """The output as linear light before exposure, as the app's tone mapping pass wants it."""
    return torch.expm1(log_out) / exposure.view(-1, 1, 1, 1)
