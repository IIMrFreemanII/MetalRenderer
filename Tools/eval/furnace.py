#!/usr/bin/env python3
"""Reads the `furnace` benchmark's pictures: each sphere's light against the sky's, per row and roughness. 1 is a surface
that keeps all the energy it gets (the grey metal's row: 0.5).

  ~/.venvs/metalrenderer-eval/bin/python Tools/eval/furnace.py <folder with the pictures>
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

ROWS = ["white metal", "white", "grey metal"]
DISTANCE, SPACING, FOV = 14.0, 1.6, np.radians(60.0)


def linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


for path in sorted(glob.glob(os.path.join(sys.argv[1], "*furnace*.png"))):
    image = linear(np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0).mean(-1)
    h, w = image.shape
    scale = (h / 2) / (np.tan(FOV / 2) * DISTANCE)   # pixels per metre at the spheres' plane
    sky = image[: h // 20, : w // 20].mean()
    print("%s  sky %.3f, white floor %.3f" % (os.path.basename(path), sky, image[int(h * 0.94) :, w // 4 : 3 * w // 4].mean() / sky))
    print("%-12s" % "roughness" + " ".join("%5.2f" % max(c / 8, 0.03) for c in range(9)))
    for row, name in enumerate(ROWS):
        means = []
        for column in range(9):
            cx, cy = w / 2 + (column - 4) * SPACING * scale, h / 2 - (1 - row) * SPACING * scale
            y, x = np.ogrid[:h, :w]
            means.append(image[(x - cx) ** 2 + (y - cy) ** 2 <= (0.45 * scale) ** 2].mean() / sky)
        print("%-12s" % name + " ".join("%5.2f" % m for m in means))
