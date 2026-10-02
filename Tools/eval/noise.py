"""usage: noise.py <run-dir> ... — scores METALRENDERER_BENCH=denoise runs against the METALRENDERER_BENCH=noise references in refs/noise/."""
import os, sys
from evalcommon import *

runs = sys.argv[1:]
pick_up_refs("noise", runs, ["ref-0.5x", "ref-1.5x", "ref-direct-0.5x"])
r, R, rd = ref("noise", "ref-0.5x"), ref("noise", "ref-1.5x"), ref("noise", "ref-direct-0.5x")
CROP = (150, 170, 400, 330)          # contact shadows at the base of the tall box (640x400)
CROP3 = tuple(3 * c for c in CROP)   # the same region at 1920x1200
hdr = ["static", "crop", "flicker", "moving", "direct", "d.crop", "dflt st", "crop", "flicker", "dflt mv"]
print(f"{'run':22s}" + "".join(f"{h:>9s}" for h in hdr))
for d in runs:
    st, stp, mv, dr = (capture(d, n) for n in ("static-0.5x", "static-0.5x-prev", "moving-0.5x", "static-direct-0.5x"))
    sd, sdp, md = (capture(d, n) for n in ("static-default", "static-default-prev", "moving-default"))
    if st is None: continue
    print(f"{os.path.basename(d):22s}" + fmt([psnr(st, r), psnr(crop(st, CROP), crop(r, CROP)), flicker(st, stp), psnr(mv, r),
                                              psnr(dr, rd), psnr(crop(dr, CROP), crop(rd, CROP)), psnr(sd, R),
                                              psnr(crop(sd, CROP3), crop(R, CROP3)), flicker(sd, sdp), psnr(md, R)]))
