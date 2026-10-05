"""Trains the denoising upscaler on a dataset (see common.py) and keeps the best checkpoint on the held-out scenes.

    python3 train.py <dataset> [--val forest,market] [--exclude stress] [--epochs 50] [--out runs/first]

Loss, on log light (log1p of the exposed colour): L1 against the reference, L1 of the frame-to-frame change against
the reference's (temporal stability), L1 of the image gradients (sharp edges). Each sample runs `--length` frames
from an empty history, so the net learns to start from nothing too, as after a reset.
"""
import argparse, math, os, time
import numpy as np
import torch
import torch.nn.functional as F

import common
from dataset import Sequences
from model import DenoisingUpscaler, prepare


def device():
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def run_sequence(net, batch, dev):
    """Runs the net over a batch of sequences; returns its outputs and the references, log space, (T, B, 3, H, W)."""
    t_len = batch["color"].shape[1]
    exposure = batch["exposure"].to(dev)
    outs, refs = [], []
    state = None
    for t in range(t_len):
        g = {k: batch[k][:, t].to(dev) for k in ["color", "albedo", "specular", "normal", "roughness", "motion"]}
        guides = prepare(g["color"], g["albedo"], g["specular"], g["normal"], g["roughness"], exposure[:, t])
        if state is None:
            b, _, h, w = guides.shape
            state = net.initial_state(b, h, w, dev)
        out, state = net(guides, g["motion"], batch["jitter"][:, t].to(dev), state)
        outs.append(out)
        refs.append(torch.log1p(batch["reference"][:, t].to(dev).clamp(min=0) * exposure[:, t].view(-1, 1, 1, 1)))
    return torch.stack(outs), torch.stack(refs)


def loss_fn(out, ref):
    spatial = F.l1_loss(out, ref)
    temporal = F.l1_loss(out[1:] - out[:-1], ref[1:] - ref[:-1])
    grad = lambda x: (x[..., :, 1:] - x[..., :, :-1], x[..., 1:, :] - x[..., :-1, :])
    (ox, oy), (rx, ry) = grad(out), grad(ref)
    gradient = F.l1_loss(ox, rx) + F.l1_loss(oy, ry)
    return spatial + 0.5 * temporal + 0.25 * gradient


@torch.no_grad()
def validate(net, loader, dev):
    """PSNR of the display images (as Tools/eval scores them) for the net and for MetalFX on the same frames, over
    each sequence's second half (with history), and the flicker of both against the reference's."""
    net.eval()
    scores = {"net": [], "metalfx": [], "net flicker": [], "metalfx flicker": []}
    for batch in loader:
        out, _ = run_sequence(net, batch, dev)
        exp = batch["exposure"].numpy()
        t_len = out.shape[0]
        for b in range(out.shape[1]):
            shown = {}
            for t in range(t_len // 2, t_len):
                e = exp[b, t]
                lin = (torch.expm1(out[t, b]).cpu().numpy() / e).transpose(1, 2, 0)
                ref = batch["reference"][b, t].numpy().transpose(1, 2, 0)
                mfx = batch["metalfx"][b, t].numpy().transpose(1, 2, 0)
                d = {"net": common.display(lin, e), "metalfx": common.display(mfx, e), "ref": common.display(ref, e)}
                scores["net"].append(common.psnr(d["net"], d["ref"]))
                scores["metalfx"].append(common.psnr(d["metalfx"], d["ref"]))
                if shown:
                    dr = d["ref"] - shown["ref"]
                    for k in ["net", "metalfx"]:
                        scores[k + " flicker"].append(float(np.sqrt(np.mean((d[k] - shown[k] - dr) ** 2)) * 255))
                shown = d
    net.train()
    return {k: float(np.mean(v)) for k, v in scores.items() if v}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("dataset")
    p.add_argument("--val", default="", help="scenes held out for validation, comma separated (default: the last scene)")
    p.add_argument("--exclude", default="", help="scenes not used at all, comma separated")
    p.add_argument("--epochs", type=int, default=50)
    p.add_argument("--samples", type=int, default=1000, help="training sequences per epoch")
    p.add_argument("--length", type=int, default=8)
    p.add_argument("--crop", type=int, default=96)
    p.add_argument("--batch", type=int, default=4)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--out", default="runs/latest")
    p.add_argument("--resume", default="")
    args = p.parse_args()

    clips = common.clip_dirs(args.dataset, exclude=[s for s in args.exclude.split(",") if s])
    scenes = sorted({os.path.basename(c).split("-")[0] for c in clips})
    val_scenes = [s for s in args.val.split(",") if s] or scenes[-1:]
    train_clips = [c for c in clips if os.path.basename(c).split("-")[0] not in val_scenes]
    val_clips = [c for c in clips if os.path.basename(c).split("-")[0] in val_scenes]
    if not train_clips or not val_clips:
        raise SystemExit(f"need clips of other scenes than {val_scenes} to train on, and of those to validate on ({scenes})")
    print(f"train on {len(train_clips)} clips of {sorted(set(scenes) - set(val_scenes))}, validate on {len(val_clips)} of {val_scenes}")

    train = Sequences(train_clips, args.length, args.crop, args.samples)
    val = Sequences(val_clips, args.length, args.crop * 2, samples=max(8, args.batch * 4), exposure_jitter=0)
    torch.manual_seed(0)
    loader = torch.utils.data.DataLoader(train, batch_size=args.batch, num_workers=args.workers, persistent_workers=args.workers > 0)
    val_loader = torch.utils.data.DataLoader(val, batch_size=args.batch, num_workers=args.workers)

    dev = device()
    net = DenoisingUpscaler(train.factor).to(dev)
    print(f"{sum(p.numel() for p in net.parameters()):,} parameters, factor {train.factor}, on {dev}")
    opt = torch.optim.AdamW(net.parameters(), lr=args.lr, weight_decay=1e-4)
    steps = args.epochs * len(loader)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: 0.5 * (1 + math.cos(math.pi * min(s / steps, 1))))
    start, best = 0, -1.0
    os.makedirs(args.out, exist_ok=True)
    if args.resume:
        ck = torch.load(args.resume, map_location=dev)
        net.load_state_dict(ck["model"]); opt.load_state_dict(ck["opt"]); sched.load_state_dict(ck["sched"])
        start, best = ck["epoch"] + 1, ck.get("best", -1.0)

    for epoch in range(start, args.epochs):
        t0, total = time.time(), 0.0
        for batch in loader:
            out, ref = run_sequence(net, batch, dev)
            loss = loss_fn(out, ref)
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0)
            opt.step()
            sched.step()
            total += loss.item()
        v = validate(net, val_loader, dev)
        line = f"epoch {epoch}: loss {total / len(loader):.4f}, " + ", ".join(f"{k} {x:.2f}" for k, x in v.items())
        print(line + f" ({time.time() - t0:.0f} s)", flush=True)
        ck = {"model": net.state_dict(), "opt": opt.state_dict(), "sched": sched.state_dict(), "epoch": epoch,
              "factor": train.factor, "best": best}
        if v["net"] > best:
            best = ck["best"] = v["net"]
            torch.save(ck, os.path.join(args.out, "best.pt"))
        torch.save(ck, os.path.join(args.out, "last.pt"))


if __name__ == "__main__":
    main()
