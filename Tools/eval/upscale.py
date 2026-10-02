"""usage: upscale.py <run-dir> ... — scores METALRENDERER_BENCH=upscale against the supersampled 1920x1200 references in refs/upscale/."""
import os, sys
from evalcommon import *

runs = sys.argv[1:]
pick_up_refs("upscale", runs, ["ref-albedo", "ref-direct"])
ra, rd = ref("upscale", "ref-albedo"), ref("upscale", "ref-direct")
print(f"{'run:upscaler':22s}{'alb st':>9s}{'flicker':>9s}{'alb mv':>9s}{'alb cam':>9s}{'alb pan':>9s}{'dir st':>9s}{'dir mv':>9s}")
for d in runs:
    for k in ("metalfx", "custom", "spatial"):
        st = capture(d, f"albedo-static-{k}")
        if st is None: continue
        stp, mv, cam, pan, ds, dm = (capture(d, f"{n}-{k}") for n in
                                     ("albedo-static", "albedo-moving", "albedo-camera", "albedo-pan", "direct-static", "direct-moving"))
        stp = capture(d, f"albedo-static-{k}-prev")
        p = lambda a, b: psnr(a, b) if a is not None else None
        print(f"{os.path.basename(d) + ':' + k:22s}" + fmt([psnr(st, ra), flicker(st, stp) if stp is not None else None,
                                                           p(mv, ra), p(cam, ra), p(pan, ra), p(ds, rd), p(dm, rd)]))
