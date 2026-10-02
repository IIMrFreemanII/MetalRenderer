"""usage: restir.py <run-dir> ... — scores METALRENDERER_BENCH=restirq (stress scene direct light, 640x400, 32 to 4096 lights,
each direct-light method) against refs/restir/, and METALRENDERER_BENCH=restircheck (accumulated ReSTIR sampling against
every light traced, per light type) within a run."""
import os, sys
from evalcommon import *

LIGHTS = (32, 128, 1024, 4096)
runs = sys.argv[1:]
pick_up_refs("restir", runs, [f"ref-direct-{n}" for n in LIGHTS])


header = False
for d in runs:
    for n in LIGHTS:
        for mode in ("exact", "grouped", "restir"):
            st = capture(d, f"{mode}-static-{n}")
            if st is None: continue
            if not header:
                print(f"{'run':16s}{'lights':>7s}  {'method':9s}{'static':>9s}{'flicker':>9s}{'moving':>9s}{'mean':>9s}    (direct light)")
                header = True
            r = ref("restir", f"ref-direct-{n}")
            stp, mv = capture(d, f"{mode}-static-{n}-prev"), capture(d, f"{mode}-moving-{n}")
            print(f"{os.path.basename(d):16s}{n:7d}  {mode:9s}" + fmt([psnr(st, r), flicker(st, stp) if stp is not None else None,
                  psnr(mv, r) if mv is not None else None, mean_luminance(st) / mean_luminance(r)]))

header = False
for d in runs:
    for tag in ("rect", "tube", "sphere", "rect-mesh", "tube-mesh", "sphere-mesh", "spots", "tubes", "area", "emissive", "mixed",
                "stress32"):
        exact, restir = capture(d, f"{tag}-exact"), capture(d, f"{tag}-restir")
        if exact is None or restir is None: continue
        if not header:
            print(f"\n{'run':16s}{'scene':14s}{'PSNR':>9s}{'mean':>9s}    (accumulated ReSTIR sampling vs every light traced)")
            header = True
        print(f"{os.path.basename(d):16s}{tag:14s}" + fmt([psnr(restir, exact), mean_luminance(restir) / mean_luminance(exact)]))
