"""Runs a checkpoint over whole clips and scores it against the references, next to MetalFX on the same frames.

    python3 infer.py runs/latest/best.pt <dataset> [--scenes forest,market] [--png out/]

Prints PSNR (display images, as Tools/eval) and flicker per clip; with --png writes each frame's
net | MetalFX | reference side by side.
"""
import argparse, os
import numpy as np
import torch
import torch.nn.functional as F

import common
from model import DenoisingUpscaler, prepare, to_linear
from train import device


def chw(a, dev):
    return torch.from_numpy(a).permute(2, 0, 1).unsqueeze(0).to(dev)


@torch.no_grad()
def run_clip(net, clip, dev, frames=None):
    """The net's output for each frame of `clip` (linear light, (H, W, 3) arrays), from an empty history."""
    frames = frames if frames is not None else common.frames(clip, need=())
    state, outs = None, []
    for f in frames:
        r = common.row(clip, f)
        a = {b: chw(common.load(clip, f, b), dev) for b in common.INPUTS}
        h, w = a["color"].shape[2:]
        ph, pw = -h % 4, -w % 4   # the U-Net halves twice
        if ph or pw:
            a = {b: F.pad(x, (0, pw, 0, ph), mode="replicate") for b, x in a.items()}
        exposure = torch.tensor([r["exposure"]], device=dev)
        guides = prepare(a["color"], a["albedo"], a["specular"], a["normal"], a["roughness"], exposure)
        if state is None:
            state = net.initial_state(1, *guides.shape[2:], dev)
        out, state = net(guides, a["motion"], torch.tensor([r["jitter"]], device=dev), state)
        k = net.factor
        outs.append(to_linear(out, exposure)[0, :, :h * k, :w * k].permute(1, 2, 0).cpu().numpy())
    return outs


def main():
    p = argparse.ArgumentParser()
    p.add_argument("checkpoint")
    p.add_argument("dataset")
    p.add_argument("--scenes", default="")
    p.add_argument("--png", default="")
    args = p.parse_args()
    dev = device()
    ck = torch.load(args.checkpoint, map_location=dev)
    net = DenoisingUpscaler(ck["factor"]).to(dev)
    net.load_state_dict(ck["model"])
    net.eval()
    scenes = [s for s in args.scenes.split(",") if s] or None
    for clip in common.clip_dirs(args.dataset, scenes):
        frames = common.frames(clip)
        if not frames:
            continue
        outs = run_clip(net, clip, dev, frames)
        score = {"net": [], "metalfx": [], "net flicker": [], "metalfx flicker": []}
        shown = None
        for f, out in zip(frames, outs):
            e = common.row(clip, f)["exposure"]
            d = {"net": common.display(out, e), "metalfx": common.display(common.load(clip, f, "metalfx"), e),
                 "ref": common.display(common.load(clip, f, "reference"), e)}
            if f >= frames[0] + 4:   # with some history
                for k in ["net", "metalfx"]:
                    score[k].append(common.psnr(d[k], d["ref"]))
                    if shown:
                        diff = d[k] - shown[k] - (d["ref"] - shown["ref"])
                        score[k + " flicker"].append(float(np.sqrt(np.mean(diff ** 2)) * 255))
            shown = d
            if args.png:
                from PIL import Image
                os.makedirs(args.png, exist_ok=True)
                row = np.concatenate([d["net"], d["metalfx"], d["ref"]], 1)
                Image.fromarray((row * 255 + 0.5).astype(np.uint8)).save(
                    os.path.join(args.png, f"{os.path.basename(clip)}-f{f:04d}.png"))
        print(f"{os.path.basename(clip):24s} " + "  ".join(f"{k} {np.mean(v):6.2f}" for k, v in score.items() if v))


if __name__ == "__main__":
    main()
