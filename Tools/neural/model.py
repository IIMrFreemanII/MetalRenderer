"""The denoising upscaler: a recurrent U-Net at the render resolution that reads the frame's noisy light and guides
plus last frame's output (warped by the motion vectors and folded into the render resolution, 3x3 output pixels per
render pixel) and writes this frame's output at the output resolution.

Every operation is one the Metal kernels (Shaders/Neural.metal) do the same way: 3x3 convolutions with ReLU, 2x2 max
pooling, nearest 2x upsampling, concatenation, pixel (un)shuffle by the upscale factor, and a warp with clamped edges,
bilinear or bicubic (`grid_sample(align_corners=False, padding_mode="border")`).

Its architecture (`arch`, kept in the checkpoint and the .nnw) has three choices, the defaults being the first net's:
- inputs "v1": log colour and the guides; "v2" adds the light in parts (Output.metal's FLAG_SPLIT_OUTPUT: log diffuse
  light / albedo, log specular light / specular albedo, log emission and fog) and how much of last frame shows.
- head "direct": per output pixel a blend weight with the warped history and a new colour; "kernel" (v2 inputs only):
  softmax weights over the 3x3 render pixels around it and the warped history, for each part of the light, and the
  surface's colours accumulated over the jittered frames; the output is albedo * diffuse + specular albedo * specular
  + the rest, so the net filters light and never has to make up a colour.
- warp "bilinear" or "bicubic" (cubic convolution, a = -0.75: the history doesn't soften frame after frame as the
  camera moves).
The U-Net has a level per width (`widths`), each but the last halving the resolution.
"""
import torch
import torch.nn as nn
import torch.nn.functional as F

HIDDEN = 8           # recurrent state per output pixel, next to the output's channels
WIDTHS = (32, 48, 64)   # the default; a checkpoint keeps its own ("widths")
ARCH = {"inputs": "v1", "head": "direct", "warp": "bilinear"}   # the first net's; a checkpoint keeps its own ("arch")
GUIDES = 14          # v1: log colour 3, albedo 3, specular albedo 3, normal 3, depth 1, roughness 1
SPLIT = ["diffuse", "specularlight", "extra"]   # v2's arrays (common.INPUTS_V2)
MIN_SPECULAR = 1e-3  # Output.metal's SPLIT_MIN_SPECULAR: color = albedo * diffuse + max(specular, this) * specular light + extra


def guides(arch):
    """Per-frame input channels: v1's, and in v2 log diffuse 3, log specular light 3, log extra 3, history validity 1."""
    return GUIDES + (10 if arch["inputs"] == "v2" else 0)


def prepare(color, albedo, specular, normal, roughness, exposure, diffuse=None, specularlight=None, extra=None):
    """The per-frame input channels, (B, guides, H, W), from the arrays as saved (channels first, float32); v2 with
    `diffuse`, `specularlight` and `extra` (its alpha: how much of last frame shows)."""
    e = exposure.view(-1, 1, 1, 1)
    log = lambda x: torch.log1p(torch.clamp(x, min=0) * e)
    view_depth = normal[:, 3:4]
    depth = torch.where(view_depth > 0, 1 / (1 + view_depth), torch.zeros_like(view_depth))   # sky: 0
    parts = [log(color), albedo, specular, normal[:, :3], depth, roughness]
    if diffuse is not None:
        parts += [log(diffuse), log(specularlight), log(extra[:, :3]), extra[:, 3:4]]
    return torch.cat(parts, 1)


def warp(image, motion, factor, mode="bilinear"):
    """`image` (output resolution) moved to this frame: each output pixel reads last frame's at its position plus the
    motion (render pixels, previous minus current, upsampled to the output by nearest). "bicubic": 4x4 taps with
    PyTorch's (and Keys') cubic convolution weights, a = -0.75, the taps clamped to the edges."""
    b, _, h, w = image.shape
    m = F.interpolate(motion, scale_factor=factor, mode="nearest") * factor
    ys, xs = torch.meshgrid(torch.arange(h, device=image.device), torch.arange(w, device=image.device), indexing="ij")
    gx = (xs + 0.5 + m[:, 0]) / w * 2 - 1
    gy = (ys + 0.5 + m[:, 1]) / h * 2 - 1
    grid = torch.stack([gx, gy], -1)
    return F.grid_sample(image, grid, mode=mode, padding_mode="border", align_corners=False)


def conv(cin, cout):
    return nn.Conv2d(cin, cout, 3, padding=1)


class DenoisingUpscaler(nn.Module):
    def __init__(self, factor=3, widths=WIDTHS, arch=None):
        super().__init__()
        self.factor, self.widths, self.arch = factor, tuple(widths), {**ARCH, **(arch or {})}
        if self.arch["head"] == "kernel" and self.arch["inputs"] != "v2":
            raise ValueError("the kernel head filters the light in parts: it needs v2 inputs")
        f2, ws, levels = factor * factor, self.widths, len(self.widths)
        kernel = self.arch["head"] == "kernel"
        # State per output pixel: the output in log light (direct), or log diffuse, log specular, log extra, the
        # accumulated albedo and specular albedo (kernel); then the hidden channels.
        self.out_channels = 15 if kernel else 3
        self.state_channels = self.out_channels + HIDDEN
        # Head per output pixel: blend weight + new colour (direct), or 3 x (9 + 1) filter logits + the albedos' blend
        # weight (kernel); then the hidden channels.
        self.head_channels = (31 if kernel else 4) + HIDDEN
        cin = guides(self.arch) + 2 + f2 * self.state_channels   # guides, jitter, last frame's output and state folded
        # Names as the first (3-level) net's, so its checkpoints load: enc0, enc1, ..., mid, ..., dec1, dec0.
        self.encs = [f"enc{i}" for i in range(levels - 1)]
        prev = cin
        for i, name in enumerate(self.encs):
            setattr(self, name, nn.ModuleList([conv(prev, ws[i]), conv(ws[i], ws[i])]))
            prev = ws[i]
        self.mid = nn.ModuleList([conv(prev, ws[-1]), conv(ws[-1], ws[-1])])
        for i in reversed(range(levels - 1)):
            setattr(self, f"dec{i}", nn.ModuleList([conv(ws[i + 1] + ws[i], ws[i]), conv(ws[i], ws[i])]))
        self.head = conv(ws[0], f2 * self.head_channels)

    @staticmethod
    def _run(layers, x):
        for layer in layers:
            x = F.relu(layer(x))
        return x

    def initial_state(self, b, h, w, device):
        """No history (the first frame, or after a reset): zero output and state at the output resolution."""
        f = self.factor
        return torch.zeros(b, self.state_channels, h * f, w * f, device=device)

    def forward(self, guides, motion, jitter, state):
        """One frame. guides (B, guides(arch), H, W), motion (B, 2, H, W), jitter (B, 2), state (B, state_channels, fH, fW).
        Returns the output in log space (log1p of the exposed light), (B, 3, fH, fW), and the new state."""
        f = self.factor
        b, _, h, w = guides.shape
        history = warp(state, motion, f, self.arch["warp"])
        jit = jitter.view(b, 2, 1, 1).expand(b, 2, h, w)
        x = torch.cat([guides, jit, F.pixel_unshuffle(history, f)], 1)
        skips = []
        for name in self.encs:
            x = self._run(getattr(self, name), x)
            skips.append(x)
            x = F.max_pool2d(x, 2)
        x = self._run(self.mid, x)
        for i in reversed(range(len(self.encs))):
            x = self._run(getattr(self, f"dec{i}"), torch.cat([F.interpolate(x, scale_factor=2, mode="nearest"), skips[i]], 1))
        y = F.pixel_shuffle(self.head(x), f)
        if self.arch["head"] == "kernel":
            return self._kernel(y, guides, history)
        alpha = torch.sigmoid(y[:, 0:1])
        new = y[:, 1:4]
        hidden = torch.tanh(y[:, 4:])
        out = torch.clamp(alpha * history[:, :3] + (1 - alpha) * new, min=0)
        return out, torch.cat([out, hidden], 1)

    def _kernel(self, y, guides, history):
        """The kernel head. y: the head's output per output pixel (B, 31 + HIDDEN, fH, fW)."""
        f = self.factor
        lin = lambda x: torch.expm1(x).clamp(min=0)
        # The noisy parts, linear (exposed), and each output pixel's 3x3 render pixels around its own: (B, 3, 9, fH, fW).
        noisy = [lin(guides[:, GUIDES + 3 * k:GUIDES + 3 * k + 3]) for k in range(3)]
        def neighbours(x):
            n = F.unfold(F.pad(x, (1, 1, 1, 1), mode="replicate"), 3)   # (B, 3*9, H*W)
            n = n.view(x.shape[0], 3 * 9, x.shape[2], x.shape[3])
            return F.interpolate(n, scale_factor=f, mode="nearest").view(x.shape[0], 3, 9, x.shape[2] * f, x.shape[3] * f)
        parts = []
        for k in range(3):
            logits = y[:, 10 * k:10 * k + 10]                           # 9 render pixels, then the history
            wts = torch.softmax(logits, 1)
            filtered = (neighbours(noisy[k]) * wts[:, None, :9]).sum(2)
            parts.append(filtered + wts[:, 9:10] * lin(history[:, 3 * k:3 * k + 3]))
        # The surface's colours: this frame's (the render pixel's, nearest) blended into the history's (not below 0:
        # the bicubic warp overshoots at edges).
        beta = torch.sigmoid(y[:, 30:31])
        up = lambda x: F.interpolate(x, scale_factor=f, mode="nearest")
        albedo = torch.clamp(beta * history[:, 9:12] + (1 - beta) * up(guides[:, 3:6]), min=0)
        spec_albedo = torch.clamp(beta * history[:, 12:15] + (1 - beta) * up(guides[:, 6:9]), min=0)
        light = albedo * parts[0] + torch.clamp(spec_albedo, min=MIN_SPECULAR) * parts[1] + parts[2]
        out = torch.log1p(light)
        hidden = torch.tanh(y[:, 31:])
        state = torch.cat([torch.log1p(parts[0]), torch.log1p(parts[1]), torch.log1p(parts[2]), albedo, spec_albedo, hidden], 1)
        return out, state


def to_linear(log_out, exposure):
    """The output as linear light before exposure, as the app's tone mapping pass wants it."""
    return torch.expm1(log_out) / exposure.view(-1, 1, 1, 1)
