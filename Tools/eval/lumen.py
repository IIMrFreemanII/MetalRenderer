"""usage: lumen.py <run-dir> ... — scores METALRENDERER_BENCH=lumen: the mesh distance fields against the G-buffer (the
"SDF depth check" view: coverage and depth error per scene), and Lumen's indirect light (distance fields, the default)
against triangles, without screen traces and without the surface cache (PSNR, dB)."""
import glob, os, sys
import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(np.float64) / 255.0


def find(d, name):
    hits = glob.glob(f"{d}/*-{name}.png")
    return hits[0] if hits else None


def psnr(a, b):
    mse = np.mean((a - b) ** 2)
    return 99.0 if mse == 0 else 10 * np.log10(1.0 / mse)


print(f"{'run:scene':24s}{'coverage':>10s}{'err cm':>9s}{'<2 cm':>8s}{'sdf/tri':>9s}{'screen':>8s}{'cards':>8s}"
      "    (coverage: G-buffer pixels a field covers; err: mean depth error where both; the rest: indirect PSNR")
for d in sys.argv[1:]:
    scenes = sorted({os.path.basename(p).split("-", 1)[1].rsplit("-lumen-sdf-depth.png", 1)[0]
                     for p in glob.glob(f"{d}/*-lumen-sdf-depth.png")})
    for scene in scenes:
        img = load(find(d, f"{scene}-lumen-sdf-depth"))
        surface, hit = img[..., 2] > 0.5, img[..., 1] > 0.5
        both = surface & hit
        error = img[..., 0][both] / 10.0  # metres (saturates at 10 cm)
        coverage = both.sum() / max(surface.sum(), 1)
        cols = [f"{coverage:10.3f}", f"{error.mean() * 100 if error.size else float('nan'):9.2f}",
                f"{(error < 0.02).mean() if error.size else float('nan'):8.3f}"]
        sdf, tri, noscreen, nocards = (find(d, f"{scene}-{n}") for n in ("lumen-indirect", "lumen-triangles-indirect",
                                                                         "lumen-noscreen-indirect", "lumen-nocards-indirect"))
        for other, width in ((tri, 9), (noscreen, 8), (nocards, 8)):
            cols.append(f"{psnr(load(sdf), load(other)):{width}.2f}" if sdf and other else f"{'—':>{width}s}")
        print(f"{os.path.basename(d) + ':' + scene:24s}" + "".join(cols))
