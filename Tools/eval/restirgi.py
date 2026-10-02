"""usage: restirgi.py <run-dir> ... — scores METALRENDERER_BENCH=restirgicheck: accumulated ReSTIR GI (without reuse, with
reuse, quarter budget) against accumulated path tracing, indirect light only, within each run."""
import os, sys
from evalcommon import *


print(f"{'run':16s}{'scene':10s}{'method':18s}{'PSNR':>9s}{'mean':>9s}    (accumulated, indirect light only, vs path traced)")
for d in sys.argv[1:]:
    for scene in ("cornell", "stress"):
        pt = capture(d, f"{scene}-pt")
        if pt is None: continue
        for method in ("restirgi-noreuse", "restirgi-reuse", "restirgi-quarter"):
            a = capture(d, f"{scene}-{method}")
            if a is None: continue
            print(f"{os.path.basename(d):16s}{scene:10s}{method:18s}" + fmt([psnr(a, pt), mean_luminance(a) / mean_luminance(pt)]))
