"""usage: stress.py <run-dir> ... — scores METALRENDERER_BENCH=stressq (stress scene, 640x400) against refs/stress/."""
import os, sys
from evalcommon import *

runs = sys.argv[1:]
pick_up_refs("stress", runs, ["ref-direct-32", "ref-direct-128", "ref8-final-32", "ref8-indirect-32", "ref-albedo-1.5x",
                              "ref-direct-1.5x"])
CROP = (180, 230, 460, 390)   # floor in front of the pillars: contact shadows of the bouncing balls
print(f"{'run':16s}{'lights':>7s}{'static':>9s}{'crop':>9s}{'flicker':>9s}{'moving':>9s}{'camera':>9s}    (direct light)")
for d in runs:
    for lights in (32, 128):
        st = capture(d, f"direct-static-{lights}")
        if st is None: continue
        r = ref("stress", f"ref-direct-{lights}")
        stp, mv, cam = (capture(d, n) for n in (f"direct-static-{lights}-prev", f"direct-moving-{lights}", f"direct-camera-{lights}"))
        print(f"{os.path.basename(d):16s}{lights:7d}" + fmt([psnr(st, r), psnr(crop(st, CROP), crop(r, CROP)),
              flicker(st, stp) if stp is not None else None, psnr(mv, r), psnr(cam, r)]))

print(f"\n{'run:GI method':24s}{'static':>9s}{'crop':>9s}{'flicker':>9s}{'moving':>9s}{'camera':>9s}{'indirect':>9s}{'mean':>9s}"
      "    (final image vs 8-bounce reference; indirect: indirect light only, mean: its brightness vs the reference's)")
for d in runs:
    for m in ("cascades", "cascades-hq", "pt", "restirgi", "restirgi-q", "lumen"):
        st = capture(d, f"{m}-static-32")
        if st is None: continue
        r = ref("stress", "ref8-final-32")
        stp, mv, cam, ind = (capture(d, f"{m}-{n}") for n in ("static-32-prev", "moving-32", "camera-32", "indirect-32"))
        rI = ref("stress", "ref8-indirect-32") if ind is not None else None
        p = lambda a: psnr(a, r) if a is not None else None
        print(f"{os.path.basename(d) + ':' + m:24s}" + fmt([psnr(st, r), psnr(crop(st, CROP), crop(r, CROP)),
              flicker(st, stp) if stp is not None else None, p(mv), p(cam), psnr(ind, rI) if ind is not None else None,
              mean_luminance(ind) / mean_luminance(rI) if ind is not None else None]))

print(f"\n{'run:upscaler':24s}{'alb st':>9s}{'flicker':>9s}{'alb mv':>9s}{'alb cam':>9s}{'dir st':>9s}{'dir mv':>9s}    (3x vs supersampled 1920x1200)")
for d in runs:
    for k in ("denoiser",):
        st = capture(d, f"albedo-static-{k}")
        if st is None: continue
        ra, rd = ref("stress", "ref-albedo-1.5x"), ref("stress", "ref-direct-1.5x")
        stp, mv, cam, ds, dm = (capture(d, n) for n in (f"albedo-static-{k}-prev", f"albedo-moving-{k}", f"albedo-camera-{k}",
                                                        f"direct-static-{k}", f"direct-moving-{k}"))
        print(f"{os.path.basename(d) + ':' + k:24s}" + fmt([psnr(st, ra), flicker(st, stp), psnr(mv, ra), psnr(cam, ra),
                                                           psnr(ds, rd), psnr(dm, rd)]))
