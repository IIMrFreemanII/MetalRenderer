"""Trains the denoising upscaler on a dataset (see common.py) and keeps the best checkpoint on the held-out scenes.

    python3 train.py <dataset> [--val forest,market] [--exclude stress] [--epochs 50] [--out runs/first]

Loss, on log light (log1p of the exposed colour): L1 against the reference, L1 of the frame-to-frame change against
the reference's (temporal stability), L1 of the image gradients (sharp edges). Each sample runs `--length` frames
from an empty history, so the net learns to start from nothing too, as after a reset.

Paused clips (common.paused: a still view, new noise every frame) teach it to keep accumulating, as MetalFX does while
a view holds still: after every `--paused-every` batches, a batch of them runs a random number of frames (up to
`--paused-length` - `--length`) without gradients first, then trains on the next `--length`. "still" scores are the
last 20 of `--paused-length` frames of the held-out paused clips (MetalFX's came after the clip's warm-up as well).
"""
import argparse, math, os, random, time
import numpy as np
import torch
import torch.nn.functional as F

import common
from dataset import Sequences
from model import WIDTHS, DenoisingUpscaler, prepare


def device():
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def run_sequence(net, batch, dev, warm=0):
    """Runs the net over a batch of sequences; returns its outputs and the references, log space, (T, B, 3, H, W), and
    where the references are valid, (T, B, 1, H, W): a reference pixel can be NaN where one path-traced sample was.
    The first `warm` frames only build the history (no gradients, not returned)."""
    t_len = batch["color"].shape[1]
    exposure = batch["exposure"].to(dev)
    outs, refs, valid = [], [], []
    state = None
    for t in range(t_len):
        with torch.set_grad_enabled(torch.is_grad_enabled() and t >= warm):
            g = {k: batch[k][:, t].to(dev) for k in ["color", "albedo", "specular", "normal", "roughness", "motion"]}
            guides = prepare(g["color"], g["albedo"], g["specular"], g["normal"], g["roughness"], exposure[:, t])
            if state is None:
                b, _, h, w = guides.shape
                state = net.initial_state(b, h, w, dev)
            out, state = net(guides, g["motion"], batch["jitter"][:, t].to(dev), state)
        if t < warm:
            continue
        outs.append(out)
        ref = batch["reference"][:, t].to(dev)
        ok = torch.isfinite(ref).all(dim=1, keepdim=True)
        valid.append(ok)
        ref = torch.where(ok, ref, 0).clamp(min=0)
        refs.append(torch.log1p(ref * exposure[:, t].view(-1, 1, 1, 1)))
    return torch.stack(outs), torch.stack(refs), torch.stack(valid)


def masked_l1(a, b, mask):
    """F.l1_loss over the pixels where `mask` holds (the same value where it holds everywhere)."""
    m = mask.expand_as(a).to(a.dtype)
    return ((a - b).abs() * m).sum() / m.sum().clamp(min=1)


def loss_fn(out, ref, valid):
    spatial = masked_l1(out, ref, valid)
    temporal = masked_l1(out[1:] - out[:-1], ref[1:] - ref[:-1], valid[1:] & valid[:-1])
    grad = lambda x: (x[..., :, 1:] - x[..., :, :-1], x[..., 1:, :] - x[..., :-1, :])
    both = lambda m: (m[..., :, 1:] & m[..., :, :-1], m[..., 1:, :] & m[..., :-1, :])
    (ox, oy), (rx, ry), (mx, my) = grad(out), grad(ref), both(valid)
    gradient = masked_l1(ox, rx, mx) + masked_l1(oy, ry, my)
    return spatial + 0.5 * temporal + 0.25 * gradient


@torch.no_grad()
def validate(net, loader, dev, first=None, prefix=""):
    """PSNR of the display images (as Tools/eval scores them) for the net and for MetalFX on the same frames, from
    frame `first` (default: each sequence's second half, with history) to the end, and the flicker of both against the
    reference's. Keys start with `prefix`."""
    net.eval()
    scores = {"net": [], "metalfx": [], "net flicker": [], "metalfx flicker": []}
    for batch in loader:
        t_len = batch["color"].shape[1]
        first = t_len // 2 if first is None else first
        out, _, _ = run_sequence(net, batch, dev, warm=first)
        exp = batch["exposure"].numpy()
        for b in range(out.shape[1]):
            shown = {}
            for i in range(out.shape[0]):
                t = first + i
                e = exp[b, t]
                lin = (torch.expm1(out[i, b]).cpu().numpy() / e).transpose(1, 2, 0)
                ref = batch["reference"][b, t].numpy().transpose(1, 2, 0)
                mfx = batch["metalfx"][b, t].numpy().transpose(1, 2, 0)
                ok = np.isfinite(ref).all(-1)
                d = {"net": common.display(lin, e)[ok], "metalfx": common.display(mfx, e)[ok],
                     "ref": common.display(np.where(ok[..., None], ref, 0), e)[ok]}
                scores["net"].append(common.psnr(d["net"], d["ref"]))
                scores["metalfx"].append(common.psnr(d["metalfx"], d["ref"]))
                if shown and shown["ok"].shape == ok.shape and (shown["ok"] == ok).all():
                    dr = d["ref"] - shown["ref"]
                    for k in ["net", "metalfx"]:
                        scores[k + " flicker"].append(float(np.sqrt(np.mean((d[k] - shown[k] - dr) ** 2)) * 255))
                shown = dict(d, ok=ok)
    net.train()
    return {prefix + k: float(np.mean(v)) for k, v in scores.items() if v}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("dataset")
    p.add_argument("--val", default="", help="held out for validation, comma separated: scenes (forest) or one seed's clips (forest-2); default: the last scene")
    p.add_argument("--exclude", default="", help="scenes not used at all, comma separated")
    p.add_argument("--epochs", type=int, default=50)
    p.add_argument("--samples", type=int, default=1000, help="training sequences per epoch")
    p.add_argument("--length", type=int, default=8)
    p.add_argument("--crop", type=int, default=96)
    p.add_argument("--batch", type=int, default=4)
    p.add_argument("--lr", type=float, default=3e-4)
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--out", default="runs/latest")
    p.add_argument("--resume", default="", help="carry on a run: its weights, optimizer, schedule and epoch")
    p.add_argument("--init", default="", help="start from a checkpoint's weights (and widths), with a new schedule")
    p.add_argument("--widths", default=",".join(map(str, WIDTHS)), help="the U-Net's channels per level, e.g. 64,96,128")
    p.add_argument("--paused-every", type=int, default=4, help="a batch of paused clips after this many (0: none)")
    p.add_argument("--paused-length", type=int, default=80, help="frames of a paused sample, warm-up included")
    args = p.parse_args()

    clips = common.clip_dirs(args.dataset, exclude=[s for s in args.exclude.split(",") if s])
    scenes = sorted({os.path.basename(c).split("-")[0] for c in clips})
    val_scenes = [s for s in args.val.split(",") if s] or scenes[-1:]
    train_clips = [c for c in clips if not common.matches(c, val_scenes)]
    val_clips = [c for c in clips if common.matches(c, val_scenes)]
    if not train_clips or not val_clips:
        raise SystemExit(f"need clips other than {val_scenes} to train on, and of those to validate on ({scenes})")
    train_scenes = sorted({os.path.basename(c).split("-")[0] for c in train_clips})
    print(f"train on {len(train_clips)} clips of {train_scenes}, validate on {len(val_clips)} of {val_scenes}")

    moving = lambda cs: [c for c in cs if not common.paused(c)]
    still = lambda cs: [c for c in cs if common.paused(c)] if args.paused_every > 0 else []
    train = Sequences(moving(train_clips), args.length, args.crop, args.samples)
    val = Sequences(moving(val_clips), args.length, args.crop * 2, samples=max(8, args.batch * 4), exposure_jitter=0)
    torch.manual_seed(0)
    loader = torch.utils.data.DataLoader(train, batch_size=args.batch, num_workers=args.workers, persistent_workers=args.workers > 0)
    val_loader = torch.utils.data.DataLoader(val, batch_size=args.batch, num_workers=args.workers)
    paused_loader = paused_val_loader = None
    if still(train_clips):
        paused = Sequences(still(train_clips), args.paused_length, args.crop, args.batch * (len(loader) // args.paused_every + 1))
        paused_loader = torch.utils.data.DataLoader(paused, batch_size=args.batch, num_workers=args.workers)
        print(f"{len(still(train_clips))} paused clips, a batch of them every {args.paused_every}")
    if still(val_clips):
        paused_val = Sequences(still(val_clips), args.paused_length, args.crop * 2, samples=max(4, 2 * len(still(val_clips))), exposure_jitter=0)
        paused_val_loader = torch.utils.data.DataLoader(paused_val, batch_size=args.batch, num_workers=args.workers)

    dev = device()
    init = torch.load(args.init, map_location=dev) if args.init else None
    widths = tuple(init["widths"]) if init else tuple(int(w) for w in args.widths.split(","))
    net = DenoisingUpscaler(train.factor, widths).to(dev)
    if init:
        net.load_state_dict(init["model"])
    print(f"{sum(p.numel() for p in net.parameters()):,} parameters, widths {widths}, factor {train.factor}, on {dev}")
    opt = torch.optim.AdamW(net.parameters(), lr=args.lr, weight_decay=1e-4)
    steps = args.epochs * len(loader)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: 0.5 * (1 + math.cos(math.pi * min(s / steps, 1))))
    start, best = 0, -1.0
    os.makedirs(args.out, exist_ok=True)
    if args.resume:
        ck = torch.load(args.resume, map_location=dev)
        net.load_state_dict(ck["model"]); opt.load_state_dict(ck["opt"]); sched.load_state_dict(ck["sched"])
        start, best = ck["epoch"] + 1, ck.get("best", -1.0)

    def step(batch, warm=0):
        out, ref, valid = run_sequence(net, batch, dev, warm)
        loss = loss_fn(out, ref, valid)
        opt.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0)
        opt.step()
        return loss.item()

    for epoch in range(start, args.epochs):
        t0, total, total_paused, n_paused = time.time(), 0.0, 0.0, 0
        paused_batches = iter(paused_loader) if paused_loader else None
        for i, batch in enumerate(loader):
            total += step(batch)
            sched.step()
            if paused_batches and (i + 1) % args.paused_every == 0:
                pb = next(paused_batches, None)
                if pb is not None:
                    warm = random.randint(0, args.paused_length - args.length)
                    total_paused += step({k: v[:, :warm + args.length] for k, v in pb.items()}, warm)
                    n_paused += 1
        v = validate(net, val_loader, dev)
        if paused_val_loader:
            v.update(validate(net, paused_val_loader, dev, first=args.paused_length - 20, prefix="still "))
        line = f"epoch {epoch}: loss {total / len(loader):.4f}, "
        if n_paused:
            line += f"paused loss {total_paused / n_paused:.4f}, "
        line += ", ".join(f"{k} {x:.2f}" for k, x in v.items())
        print(line + f" ({time.time() - t0:.0f} s)", flush=True)
        ck = {"model": net.state_dict(), "opt": opt.state_dict(), "sched": sched.state_dict(), "epoch": epoch,
              "factor": train.factor, "widths": widths, "best": best}
        score = (v["net"] + v["still net"]) / 2 if "still net" in v else v["net"]   # moving and still alike
        if score > best:
            best = ck["best"] = score
            torch.save(ck, os.path.join(args.out, "best.pt"))
        torch.save(ck, os.path.join(args.out, "last.pt"))


if __name__ == "__main__":
    main()
