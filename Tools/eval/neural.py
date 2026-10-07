"""usage: neural.py <run-dir> ... — scores METALRENDERER_BENCH=neuralq against its supersampled 1920x1200 references in
refs/neural/, traced as deep as the neural denoiser's dataset (4 bounces, not the app's 2: hwrt.py's references).

MetalFX's denoising scaler ("denoiser") and ours ("neural", Tools/neural) in the Cornell room and the stress hall: PSNR
of a still frame, its flicker against the frame before, and PSNR with the animation running and during the camera move."""
import os, sys
from evalcommon import *

runs = sys.argv[1:]
scenes = ("cornell", "stress")
pick_up_refs("neural", runs, [f"{s}-ref-neural" for s in scenes])
print(f"{'run:scene:output':34s}{'static':>9s}{'flicker':>9s}{'moving':>9s}{'camera':>9s}")
for d in runs:
    for s in scenes:
        r = ref("neural", f"{s}-ref-neural")
        for k in ("denoiser", "neural"):
            st = capture(d, f"{s}-final-static-{k}")
            if st is None: continue
            stp = capture(d, f"{s}-final-static-{k}-prev")
            mv, cam = (capture(d, f"{s}-final-{n}-{k}") for n in ("moving", "camera"))
            p = lambda a: psnr(a, r) if a is not None else None
            print(f"{os.path.basename(d) + ':' + s + ':' + k:34s}" + fmt([psnr(st, r), flicker(st, stp) if stp is not None else None, p(mv), p(cam)]))
