"""usage: restir.py <run-dir> ... — scores METALRENDERER_BENCH=restirq (stress scene direct light, 640x400, 32 to 4096 lights,
each direct-light method) against refs/restir/, and METALRENDERER_BENCH=restircheck (accumulated ReSTIR sampling against
every light traced, per light type) within a run; MegaLights alongside ReSTIR in both and in marketq."""
import os, sys
from evalcommon import *

LIGHTS = (32, 128, 1024, 4096)
runs = sys.argv[1:]
pick_up_refs("restir", runs, [f"ref-direct-{n}" for n in LIGHTS])


header = False
for d in runs:
    for n in LIGHTS:
        for mode in ("exact", "grouped", "restir", "megalights"):
            st = capture(d, f"{mode}-static-{n}")
            if st is None: continue
            if not header:
                print(f"{'run':16s}{'lights':>7s}  {'method':9s}{'static':>9s}{'flicker':>9s}{'moving':>9s}{'mean':>9s}    (direct light)")
                header = True
            r = ref("restir", f"ref-direct-{n}")
            stp, mv = capture(d, f"{mode}-static-{n}-prev"), capture(d, f"{mode}-moving-{n}")
            print(f"{os.path.basename(d):16s}{n:7d}  {mode:9s}" + fmt([psnr(st, r), flicker(st, stp) if stp is not None else None,
                  psnr(mv, r) if mv is not None else None, mean_luminance(st) / mean_luminance(r)]))

pick_up_refs("restir", runs, ["ref-direct-market", "ref-indirect-market", "ref-scattering-market"])
header = False
for d in runs:
    # METALRENDERER_BENCH=marketq: ReSTIR's candidates from the table alone / the light grid; MegaLights
    for source, prefix in (("table", "restir-table"), ("grid", "restir-grid"), ("mega", "megalights")):
        st = capture(d, f"{prefix}-static-market")
        if st is None: continue
        if not header:
            print(f"\n{'run':16s}{'source':9s}{'static':>9s}{'flicker':>9s}{'moving':>9s}{'mean':>9s}{'accum64':>9s}    (Night market direct light, 4096 bulbs)")
            header = True
        r = ref("restir", "ref-direct-market")
        stp, mv = capture(d, f"{prefix}-static-market-prev"), capture(d, f"{prefix}-moving-market")
        ac = capture(d, f"{prefix}-accum-market")
        print(f"{os.path.basename(d):16s}{source:9s}" + fmt([psnr(st, r), flicker(st, stp) if stp is not None else None,
              psnr(mv, r) if mv is not None else None, mean_luminance(st) / mean_luminance(r),
              psnr(ac, r) if ac is not None else None]))

header = False
for d in runs:   # METALRENDERER_BENCH=marketq: the grid at the secondary hits (indirect light alone) and in the fog
    for (name, refname) in (("pt indirect", "ref-indirect-market"), ("cascades indirect", "ref-indirect-market"),
                            ("fog scattering", "ref-scattering-market"), ("pt accum indirect", "ref-indirect-market"),
                            ("fog accum scattering", "ref-scattering-market")):
        kind, what = name.split(" ", 1)
        row = []
        for source in ("table", "grid"):
            c = capture(d, f"{kind}-{source}-{what.replace(' ', '-')}-market")
            r = ref("restir", refname)
            row += [psnr(c, r), mean_luminance(c) / mean_luminance(r)] if c is not None else [None, None]
        if all(v is None for v in row): continue
        if not header:
            print(f"\n{'run':16s}{'signal':22s}{'table':>9s}{'mean':>9s}{'grid':>9s}{'mean':>9s}    (Night market: GI's and the fog's candidates)")
            header = True
        print(f"{os.path.basename(d):16s}{name:22s}" + fmt(row))

header = False
for d in runs:
    for tag in ("rect", "tube", "sphere", "rect-mesh", "tube-mesh", "sphere-mesh", "spots", "tubes", "area", "emissive", "mixed",
                "stress32"):
        exact = capture(d, f"{tag}-exact")
        if exact is None: continue
        for source in ("restir", "restir-grid", "megalights"):   # the table alone; the light grid (ReGIR) + the table; MegaLights
            restir = capture(d, f"{tag}-{source}")
            if restir is None: continue
            if not header:
                print(f"\n{'run':16s}{'scene':14s}{'source':12s}{'PSNR':>9s}{'mean':>9s}    (accumulated sampling vs every light traced)")
                header = True
            print(f"{os.path.basename(d):16s}{tag:14s}{source:12s}" + fmt([psnr(restir, exact), mean_luminance(restir) / mean_luminance(exact)]))
