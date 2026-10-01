"""usage: shadow.py <run-dir> ... — scores METALGI_BENCH=shadow (Cornell direct light, 640x400) against refs/shadow/."""
import os, sys
from evalcommon import *

runs = sys.argv[1:]
pick_up_refs("shadow", runs, ["ref-direct"])
reference = ref("shadow", "ref-direct")
CROP = (150, 170, 400, 330)   # contact shadows at the base of the tall box
print(f"{'run':16s}{'static':>9s}{'crop':>9s}{'flicker':>9s}{'moving':>9s}{'m.crop':>9s}{'camera':>9s}")
for d in runs:
    st, stp, mv, cam = (capture(d, n) for n in ("direct-static", "direct-static-prev", "direct-moving", "direct-camera"))
    if st is None: continue
    print(f"{os.path.basename(d):16s}" + fmt([psnr(st, reference), psnr(crop(st, CROP), crop(reference, CROP)),
                                              flicker(st, stp) if stp is not None else None, psnr(mv, reference),
                                              psnr(crop(mv, CROP), crop(reference, CROP)), psnr(cam, reference)]))
