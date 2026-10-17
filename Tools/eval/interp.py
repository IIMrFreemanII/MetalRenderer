"""usage: interp.py <run-dir> — scores frame interpolation (METALRENDERER_BENCH=interp, Benchmark+Modes.swift).

Per scene, PSNR in dB against the frame really rendered at the in-between moment ("<scene> 60 fps between"):
  interpolated  MetalFX's in-between picture (the 30 fps setting's `-interp`)
  held          the last frame before it (`-prev`): what 30 fps without interpolation shows at that moment
  next          the frame after it (the 30 fps setting's last)
  ceiling       the 30 fps setting's last frame against the 60 fps run's frame at the same moment: how close two runs
                come anyway (their noise and their denoisers' histories differ)
Interpolation helps where `interpolated` beats `held` and `next`; `ceiling` is as good as it can score.
"""
import glob, os, sys
import numpy as np
from evalcommon import load


def psnr(a, b):
    mse = ((a - b) ** 2).mean()
    return 99.0 if mse == 0 else 10 * np.log10(1 / mse)


run = sys.argv[1]
scenes = sorted({os.path.basename(p).split("-", 1)[1].rsplit("-30-fps", 1)[0] for p in glob.glob(f"{run}/*-30-fps.png")})
print(f"{'scene':12s} {'interpolated':>12s} {'held':>8s} {'next':>8s} {'ceiling':>8s}")
for scene in scenes:
    def one(pattern):
        hits = glob.glob(f"{run}/*-{scene}-{pattern}.png")
        return load(hits[0]) if hits else None
    truth, last60 = one("60-fps-between"), one("60-fps-last")
    interp, prev, cur = one("30-fps-interp"), one("30-fps-prev"), one("30-fps")
    if truth is None or interp is None or prev is None or cur is None:
        print(f"{scene:12s} missing pictures")
        continue
    ceiling = psnr(cur, last60) if last60 is not None else float("nan")
    print(f"{scene:12s} {psnr(interp, truth):12.2f} {psnr(prev, truth):8.2f} {psnr(cur, truth):8.2f} {ceiling:8.2f}")
