"""usage: specular.py <run-dir> ... — scores METALRENDERER_BENCH=speccheck: direct light with specular materials, each
direct-light path against the accumulated reference in refs/speccheck/. "mean" is the image's brightness over the
reference's (1.00 = nothing counted twice or lost); "highlights" is the same over the brightest 2% of the reference's
pixels that aren't clipped (the lights' own shapes are), where direct specular dominates."""
import os, sys
import numpy as np
from evalcommon import *

SCENES = ["area", "spots", "tubes"]
runs = sys.argv[1:]
pick_up_refs("speccheck", runs, [f"{s}-ref" for s in SCENES])


def luminance(a):
    linear = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    return linear @ [0.2126, 0.7152, 0.0722]


print(f"{'run:setting':34s}{'PSNR':>9s}{'mean':>9s}{'highlights':>12s}    (direct light, vs the accumulated reference)")
for d in runs:
    for scene in SCENES:
        if not os.path.exists(f"{refs_dir('speccheck')}/{scene}-ref.png"): continue
        r = ref("speccheck", f"{scene}-ref")
        lr = luminance(r)
        unclipped = r.max(axis=2) < 0.98
        bright = unclipped & (lr >= np.quantile(lr[unclipped], 0.98))
        for path in ("shadow-denoiser", "svgf", "restir"):
            img = capture(d, f"{scene}-{path}")
            if img is None: continue
            li = luminance(img)
            print(f"{os.path.basename(d) + ':' + scene + ' ' + path:34s}" +
                  fmt([psnr(img, r), li.mean() / lr.mean()]) + f"{li[bright].mean() / lr[bright].mean():12.2f}")
