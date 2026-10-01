"""usage: pngdiff.py <dirA> <dirB> — per-file max / RMS difference of same-named PNGs (8-bit levels), e.g. to check
that a refactor renders the same frames."""
import os, sys
import numpy as np
from evalcommon import load

a, b = sys.argv[1:3]
for n in sorted(os.listdir(a)):
    if not n.endswith(".png") or not os.path.exists(f"{b}/{n}"): continue
    d = abs(load(f"{a}/{n}") - load(f"{b}/{n}")) * 255
    print(f"{n:45s} max {d.max():5.1f}  rms {np.sqrt((d ** 2).mean()):.3f}  >8 levels {(d.max(2) > 8).mean() * 100:.2f}%")
