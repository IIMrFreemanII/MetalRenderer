"""usage: hwrt.py <run-dir> ... — scores METALRENDERER_BENCH=hwrtq against the supersampled 1920x1200 references in refs/hwrt/.

MetalFX's denoising scaler in the Cornell room and the stress hall: PSNR of a still frame, its flicker against the frame before, and PSNR with the animation running and
during the camera move."""
import os, sys
from evalcommon import *

runs = sys.argv[1:]
scenes = ("cornell", "stress")
pick_up_refs("hwrt", runs, [f"{s}-ref-final" for s in scenes])
print(f"{'run:scene:output':34s}{'static':>9s}{'flicker':>9s}{'moving':>9s}{'camera':>9s}")
for d in runs:
    for s in scenes:
        r = ref("hwrt", f"{s}-ref-final")
        for k in ("denoiser", "neural"):
            st = capture(d, f"{s}-final-static-{k}")
            if st is None: continue
            stp, mv, cam = (capture(d, f"{s}-final-{n}-{k}") for n in ("static-" + k + "-prev", "moving", "camera"))
            stp = capture(d, f"{s}-final-static-{k}-prev")
            p = lambda a: psnr(a, r) if a is not None else None
            print(f"{os.path.basename(d) + ':' + s + ':' + k:34s}" + fmt([psnr(st, r), flicker(st, stp) if stp is not None else None, p(mv), p(cam)]))
