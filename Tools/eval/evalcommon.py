"""Shared helpers for the benchmark scorers in this folder.

Every scorer reads PNGs saved by a benchmark run (`METALRENDERER_BENCH=<mode> METALRENDERER_BENCH_DIR=<run-dir>`) and compares
them with converged reference images in refs/<mode>/. A run that renders the references (the "ref ..." settings,
skipped with METALRENDERER_GI_REFS=0) refreshes refs/<mode>/ automatically, so re-render them after any change that
alters the ground truth (scene, lights, materials) and commit the new files.
"""
import glob, os, shutil
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


def refs_dir(mode):
    return os.path.join(HERE, "refs", mode)


def pick_up_refs(mode, run_dirs, names):
    """Copies reference captures named `<index>-<name>.png` from any run into refs/<mode>/<name>.png."""
    out = refs_dir(mode)
    for d in run_dirs:
        for name in names:
            hits = glob.glob(f"{d}/*-{name}.png")
            if hits:
                os.makedirs(out, exist_ok=True)
                shutil.copy(hits[0], f"{out}/{name}.png")


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), float) / 255


def ref(mode, name):
    path = f"{refs_dir(mode)}/{name}.png"
    if not os.path.exists(path):
        raise SystemExit(f"missing reference {path}: run METALRENDERER_BENCH={mode} once without METALRENDERER_GI_REFS=0")
    return load(path)


def capture(run_dir, name):
    """The capture `<index>-<name>.png` of a run (exact name, so "x-static" doesn't match "x-static-prev"), or None."""
    hits = [p for p in glob.glob(f"{run_dir}/*-{name}.png") if os.path.basename(p).split("-", 1)[1] == f"{name}.png"]
    return load(hits[0]) if hits else None


def psnr(a, b):
    return 10 * np.log10(1 / np.mean((a - b) ** 2))


def flicker(a, b):
    """RMS difference between consecutive frames, in 8-bit levels."""
    return np.sqrt(np.mean((a - b) ** 2)) * 255


def crop(a, box):
    return a[box[1]:box[3], box[0]:box[2]]


def fmt(values, width=9):
    return "".join(f"{v:{width}.2f}" if v is not None else f"{'—':>{width}s}" for v in values)
