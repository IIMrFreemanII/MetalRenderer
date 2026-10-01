"""usage: stress.py <run-dir> ... — scores METALGI_BENCH=stressq (stress scene, 640x400) against refs/stress/."""
import os, sys
from evalcommon import *

runs = sys.argv[1:]
pick_up_refs("stress", runs, ["ref-direct-32", "ref-direct-128", "ref8-final-32"])
CROP = (180, 230, 460, 390)   # floor in front of the pillars: contact shadows of the bouncing balls
print(f"{'run':16s}{'lights':>7s}{'static':>9s}{'crop':>9s}{'flicker':>9s}{'moving':>9s}{'camera':>9s}    (direct light)")
for d in runs:
    for lights in (32, 128):
        st = capture(d, f"direct-static-{lights}")
        if st is None: continue
        r = ref("stress", f"ref-direct-{lights}")
        stp, mv, cam = (capture(d, n) for n in (f"direct-static-{lights}-prev", f"direct-moving-{lights}", f"direct-camera-{lights}"))
        print(f"{os.path.basename(d):16s}{lights:7d}" + fmt([psnr(st, r), psnr(crop(st, CROP), crop(r, CROP)),
              flicker(st, stp) if stp is not None else None, psnr(mv, r), psnr(cam, r)]))
    out = [(m, capture(d, f"{m}-static-32")) for m in ("cascades", "pt", "surfels")]
    out = [f"{m} {psnr(a, ref('stress', 'ref8-final-32')):.2f}" for m, a in out if a is not None]
    if out: print(f"{os.path.basename(d):16s} final image vs 8-bounce reference: " + ", ".join(out))
