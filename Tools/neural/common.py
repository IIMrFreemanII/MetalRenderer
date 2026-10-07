"""What the training, inference and export scripts share: the dataset's files and the app's tone curve.

A dataset is the folder METALRENDERER_BENCH=dataset / datasetref write (Benchmark+Dataset.swift): one folder per clip,
and in it per frame `fNNNN.json` (time, camera, jitter, exposure, sizes) and float16 arrays `fNNNN-<buffer>.npy`:
render resolution: color (noisy linear light), albedo, specular (specular albedo), normal (xyz + view depth, sky -1),
depth (reversed Z), motion (previous minus current pixel, render pixels), roughness;
output resolution: metalfx (MetalFX's denoising scaler, the baseline) and reference (supersampled, path traced).
Paused clips (`paused`) have one reference for all their frames.
"""
import glob, json, os
import numpy as np

INPUTS = ["color", "albedo", "specular", "normal", "motion", "roughness"]


def matches(clip, names):
    """Whether a clip folder (`<scene>-<seed>-<clip>`) is one of `names`: a scene ("market") or a scene's clips of one
    seed ("market-2")."""
    base = os.path.basename(clip)
    return any(n == base.split("-")[0] or base.startswith(n + "-") for n in names)


def clip_dirs(root, scenes=None, exclude=()):
    """The clip folders under `root`, optionally only those of `scenes` (see `matches`), without `exclude`."""
    out = []
    for d in sorted(glob.glob(os.path.join(root, "*"))):
        if not os.path.exists(os.path.join(d, "f0000.json")) or matches(d, exclude) or (scenes and not matches(d, scenes)):
            continue
        out.append(d)
    return out


def frames(clip, need=("reference",)):
    """The frame numbers of `clip` with a row and the arrays `need`, in order."""
    out = []
    for row in sorted(glob.glob(os.path.join(clip, "f[0-9][0-9][0-9][0-9].json"))):
        f = int(os.path.basename(row)[1:5])
        if all(os.path.exists(array_path(clip, f, b)) for b in need):
            out.append(f)
    return out


def paused(clip):
    """A paused clip (`<scene>-<seed>-p<n>`): a still camera on a paused scene, every frame new noise over the same
    image, so its one reference (frame 0's) is every frame's."""
    return os.path.basename(clip).split("-")[-1].startswith("p")


def array_path(clip, frame, buffer):
    if buffer == "reference" and paused(clip):
        frame = 0
    return os.path.join(clip, f"f{frame:04d}-{buffer}.npy")


def row(clip, frame):
    with open(os.path.join(clip, f"f{frame:04d}.json")) as f:
        return json.load(f)


def load(clip, frame, buffer, window=None):
    """An array as float32, (H, W, C). `window` = (y, x, h, w) reads only that part (memory-mapped)."""
    a = np.load(array_path(clip, frame, buffer), mmap_mode="r")
    if window:
        y, x, h, w = window
        a = a[y:y + h, x:x + w]
    return np.asarray(a, dtype=np.float32)


def aces(x):
    """Output.metal's acesFilm (Narkowicz 2015), the app's default tone curve."""
    return np.clip((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0, 1)


def display(linear, exposure):
    """Linear light as the app shows it: exposure, ACES, sRGB encoding (the drawable's format), in [0, 1]."""
    c = aces(np.maximum(linear, 0) * exposure)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def psnr(a, b):
    """On display images in [0, 1], like Tools/eval."""
    return float(10 * np.log10(1 / max(np.mean((a - b) ** 2), 1e-12)))
