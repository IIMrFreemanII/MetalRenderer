"""usage: gallery.py <run-dir> ... — scores METALRENDERER_BENCH=gallery (glTF models, PBR, virtual geometry) against the
path-traced references in refs/gallery/ (full BRDF, full-detail meshes, 4 bounces, 1024 frames)."""
import os, sys
from evalcommon import *

runs = sys.argv[1:]
pick_up_refs("gallery", runs, ["ref-overview", "ref-closeup"])
ro, rc = ref("gallery", "ref-overview"), ref("gallery", "ref-closeup")
print(f"{'run:setting':34s}{'PSNR':>9s}{'flicker':>9s}    (final image, 640x400, vs the path-traced reference)")
for d in runs:
    for geometry in ("full", "vg0.5", "vg1", "vg2"):
        for name, r in ((f"{geometry}-cascades-static", ro), (f"{geometry}-cascades-closeup", rc), (f"{geometry}-pt-closeup", rc)):
            img = capture(d, name)
            if img is None: continue
            prev = capture(d, name + "-prev")
            print(f"{os.path.basename(d) + ':' + name:34s}" + fmt([psnr(img, r), flicker(img, prev) if prev is not None else None]))
