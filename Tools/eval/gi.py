"""usage: gi.py <run-dir> ... — scores METALRENDERER_BENCH=gi (Cornell, every GI method) against the 8-bounce references in refs/gi/."""
import glob, os, sys
from evalcommon import *

runs = sys.argv[1:]
pick_up_refs("gi", runs, ["ref8-0.5x", "ref8-indirect-0.5x", "ref8-1.5x"])
r, rI, rHQ = ref("gi", "ref8-0.5x"), ref("gi", "ref8-indirect-0.5x"), ref("gi", "ref8-1.5x")
CROP = (150, 170, 400, 330)   # contact shadows at the base of the tall box (640x400)
hdr = ["static", "crop", "flicker", "indirect", "mean", "moving", "camera", "default", "spatial"]
print(f"{'run:mode':28s}" + "".join(f"{h:>9s}" for h in hdr) + "    (PSNR dB; mean: indirect brightness vs the reference's;"
      " default/spatial: 3x upscaled vs the 1.5x reference)")
for d in runs:
    tags = sorted({os.path.basename(p).split("-", 1)[1].rsplit("-static.png", 1)[0] for p in glob.glob(f"{d}/*-static.png")})
    for tag in tags:
        st, stp, ind, mv, cam, df, sp = (capture(d, f"{tag}-{s}") for s in
                                         ("static", "static-prev", "static-indirect", "moving", "camera", "default-moving", "spatial-moving"))
        p = lambda a, b: psnr(a, b) if a is not None else None
        print(f"{os.path.basename(d) + ':' + tag:28s}" + fmt([psnr(st, r), psnr(crop(st, CROP), crop(r, CROP)),
              flicker(st, stp) if stp is not None else None, p(ind, rI),
              mean_luminance(ind) / mean_luminance(rI) if ind is not None else None, p(mv, r), p(cam, r), p(df, rHQ), p(sp, rHQ)]))
