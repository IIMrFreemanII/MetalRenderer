"""Writes a checkpoint's weights for the app (NeuralUpscaler.swift), and a golden test vector for its kernels.

    python3 export.py runs/latest/best.pt [--out ../../Assets/Neural/denoiser.nnw]
    python3 export.py --golden ../../Tests/MetalRendererTests/Neural/golden.nnw   # the test's: seeded random weights

The .nnw container: "NNW1", a little-endian u32 length, that much JSON, zero padding to a multiple of 16, then the
tensors' data. The JSON has the net's shape (factor, guides, hidden, widths) and `tensors`: name, shape, dtype ("f16"
or "f32") and byte offset into the data. Convolution weights keep PyTorch's layout, [out][in][ky][kx].

The golden vector runs the net over two frames of synthetic input (fixed seed, 16 x 12 render pixels, so 8-bit
padding and the U-Net's halving are both exercised) and stores the inputs as saved by the app and the net's linear
output of both frames. NeuralUpscalerTests runs the Metal kernels on them. It needs no trained net: without a
checkpoint the weights are PyTorch's initialisation from a fixed seed.
"""
import argparse, json, os, struct
import numpy as np
import torch

from model import DenoisingUpscaler, GUIDES, HIDDEN, WIDTHS, prepare, to_linear


def write_nnw(path, meta, tensors):
    """tensors: [(name, np.ndarray)], float16 or float32."""
    entries, blobs, offset = [], [], 0
    for name, a in tensors:
        a = np.ascontiguousarray(a)
        dtype = {np.dtype(np.float16): "f16", np.dtype(np.float32): "f32"}[a.dtype]
        entries.append({"name": name, "shape": list(a.shape), "dtype": dtype, "offset": offset})
        blob = a.tobytes()
        blob += b"\0" * (-len(blob) % 16)
        blobs.append(blob)
        offset += len(blob)
    header = json.dumps({**meta, "tensors": entries}).encode()
    pad = -(8 + len(header)) % 16
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"NNW1" + struct.pack("<I", len(header) + pad) + header + b" " * pad)
        for b in blobs:
            f.write(b)


def golden(net, seed=1, h=12, w=16, frames=2):
    g = torch.Generator().manual_seed(seed)
    rand = lambda *s: torch.rand(*s, generator=g)
    tensors, state = [], None
    for t in range(frames):
        color = rand(1, 3, h, w) ** 4 * 8          # mostly dim, some bright
        albedo, specular = rand(1, 3, h, w), rand(1, 3, h, w) * 0.2
        normal = torch.cat([torch.nn.functional.normalize(rand(1, 3, h, w) * 2 - 1, dim=1), 1 + rand(1, 1, h, w) * 9], 1)
        normal[:, 3, 0, :3] = -1                     # some sky
        roughness, motion = rand(1, 1, h, w), (rand(1, 2, h, w) - 0.5) * 3
        jitter, exposure = rand(1, 2) - 0.5, torch.tensor([0.8])
        with torch.no_grad():
            guides = prepare(color, albedo, specular, normal, roughness, exposure)
            if state is None:
                state = net.initial_state(1, h, w, "cpu")
            out, state = net(guides, motion, jitter, state)
        hwc = lambda x: x[0].permute(1, 2, 0).numpy().astype(np.float32)
        for name, x in [("color", color), ("albedo", albedo), ("specular", specular), ("normal", normal),
                        ("roughness", roughness), ("motion", motion)]:
            tensors.append((f"f{t}.{name}", hwc(x)))
        tensors.append((f"f{t}.jitter", jitter[0].numpy().astype(np.float32)))
        tensors.append((f"f{t}.exposure", exposure.numpy().astype(np.float32)))
        tensors.append((f"f{t}.output", hwc(to_linear(out, exposure))))
    return tensors


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser()
    p.add_argument("checkpoint", nargs="?", help="none: seeded random weights, for --golden only")
    p.add_argument("--out", default=os.path.join(here, "../../Assets/Neural/denoiser.nnw"))
    p.add_argument("--golden", default="")
    args = p.parse_args()
    if args.checkpoint:
        ck = torch.load(args.checkpoint, map_location="cpu")
        net = DenoisingUpscaler(ck["factor"], ck.get("widths", WIDTHS))
        net.load_state_dict(ck["model"])
    else:
        torch.manual_seed(0)
        net = DenoisingUpscaler(3)
    net.eval()
    meta = {"factor": net.factor, "guides": GUIDES, "hidden": HIDDEN, "widths": list(net.widths)}
    weights = [(k, v.numpy().astype(np.float16)) for k, v in net.state_dict().items()]
    if args.checkpoint:
        write_nnw(args.out, meta, weights)
        print(f"{args.out}: {sum(v.size for _, v in weights):,} weights")
    if args.golden:
        # The golden vector uses the same weights in float16, as the app does, so only the arithmetic differs.
        net.load_state_dict({k: torch.from_numpy(v.astype(np.float32)) for k, v in weights})
        write_nnw(args.golden, meta, weights + golden(net))
        print(f"{args.golden}: golden vector")


if __name__ == "__main__":
    main()
