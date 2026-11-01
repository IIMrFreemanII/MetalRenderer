#!/usr/bin/env python3
"""Reads the `gilevels` benchmark's pictures: the radiance cascades' light over the reference path tracer's, on what the
camera sees that the sun lights and on what lies in shade (lit only by the GI). 1 matches; the sky isn't counted. Writes a
ratio picture per scene (blue: darker than traced, red: brighter, white: the same, full colour at a factor of 1.5).

  ~/.venvs/metalrenderer-eval/bin/python Tools/eval/gilevels.py <folder with the pictures>
"""
import glob
import os
import re
import sys

import numpy as np
from PIL import Image

folder = sys.argv[1]
shots = {}
for path in glob.glob(os.path.join(folder, "*.png")):
    m = re.match(r"\d+-(\w+?)-(cascades-gaps|cascades-contact|cascades-raw|cascades-before|cascades-maps|cascades|normals|direct|traced)\.png$", os.path.basename(path))
    if m:
        shots.setdefault(m.group(1), {})[m.group(2)] = path


def linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


for scene in sorted(shots):
    s = shots[scene]
    if "traced" not in s:
        continue
    size = Image.open(s["traced"]).size
    def load(name):   # linear, and only then averaged down to the reference's size (leaves' light and dark don't average in sRGB)
        a = linear(np.asarray(Image.open(s[name]).convert("RGB"), dtype=np.float64) / 255.0)
        k = a.shape[1] // size[0]
        return a.reshape(size[1], k, size[0], k, 3).mean((1, 3)) if k > 1 else a
    traced = load("traced").mean(-1)
    surface = load("normals").max(-1) > 0.0005
    direct = load("direct").mean(-1)
    lit = surface & (direct > 0.01)
    shade = surface & ~lit
    print("%s  (surfaces %.0f%% of the frame, in shade %.0f%% of them)" % (scene, surface.mean() * 100, shade.sum() / max(surface.sum(), 1) * 100))
    for name in ("cascades", "cascades-maps", "cascades-before", "cascades-raw", "cascades-gaps", "cascades-contact"):
        if name not in s:
            continue
        c = load(name).mean(-1)
        row = []
        for label, mask in (("sunlit", lit), ("shade", shade)):
            row.append("%s %.3f" % (label, c[mask].sum() / max(traced[mask].sum(), 1e-6)) if mask.sum() else "%s  -" % label)
        print("  %-18s" % name + "  ".join(row))
    c = load("cascades").mean(-1)
    r = np.log(np.maximum(c, 1e-3) / np.maximum(traced, 1e-3)) / np.log(1.5)
    r = np.clip(r, -1, 1)
    r[~surface] = 0
    rgb = np.stack([1 + np.minimum(r, 0), 1 - np.abs(r), 1 - np.maximum(r, 0)], -1)
    Image.fromarray((rgb * 255).astype(np.uint8)).save(os.path.join(folder, "ratio-%s.png" % scene))
