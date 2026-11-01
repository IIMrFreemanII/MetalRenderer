#!/usr/bin/env python3
"""Reads the `frost` benchmark's pictures: the frosted sphere's grain, flicker and error against the path tracer, inside
the sphere so its silhouette doesn't count. Grain is what a 9 px blur removes, in 8-bit levels (the sphere's own blur
is wider); flicker is the RMS difference between two frames of the still shot, in 8-bit levels.

  ~/.venvs/metalrenderer-eval/bin/python Tools/eval/frost.py <folder with the pictures> ...
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from evalcommon import capture, flicker, psnr

# The frost mode's view: the sphere centred, radius 0.5 at 2.45 m, and the clear and green ones 1.5 m to either side.
DISTANCE, RADIUS, SPACING, FOV = np.hypot(0.5, 2.4), 0.5, 1.5, np.radians(60.0)


def inside(image, along=0.0):
    """The middle of the sphere `along` spheres to the right of the frosted one."""
    h, w = image.shape[:2]
    scale = (h / 2) / np.tan(FOV / 2) / DISTANCE
    half = int(RADIUS * scale * 0.6)
    x, y = w // 2 + int(along * SPACING * scale), h // 2
    return image[y - half : y + half, x - half : x + half]


def blur(image, size=9):
    kernel = np.ones(size) / size
    for axis in (0, 1):
        image = np.apply_along_axis(lambda line: np.convolve(line, kernel, mode="same"), axis, image)
    return image


def grain(crop):
    """From the median deviation, so the reference's few fireflies (sun glints a path rarely finds) don't count."""
    grey = crop.mean(-1)
    edge = 9
    rest = (grey - blur(grey))[edge:-edge, edge:-edge]
    return float(1.4826 * np.median(np.abs(rest - np.median(rest))) * 255)


def rim_grain(image):
    """The same in the ring near the frosted sphere's silhouette, where Fresnel's share changes fastest."""
    h, w = image.shape[:2]
    radius = RADIUS * (h / 2) / np.tan(FOV / 2) / DISTANCE
    reach = int(radius) + 10
    x, y = w // 2, h // 2
    grey = image[y - reach : y + reach, x - reach : x + reach].mean(-1)
    rest = grey - blur(grey, 5)
    yy, xx = np.mgrid[-reach:reach, -reach:reach]
    ring = rest[(np.hypot(xx, yy) > radius * 0.8) & (np.hypot(xx, yy) < radius * 0.95)]
    return float(1.4826 * np.median(np.abs(ring - np.median(ring))) * 255)


def without_fireflies(crop):
    return np.median(np.lib.stride_tricks.sliding_window_view(crop, (5, 5), axis=(0, 1)), axis=(-2, -1))


for folder in sys.argv[1:]:
    print(folder)
    traced = capture(folder, "frost-traced")
    if traced is None:
        print("  no frost-traced picture")
        continue
    reference = inside(traced)
    print("  %-14s %7s %7s %7s %7s %7s" % ("", "grain", "rim", "flicker", "dB", "mean"))
    print("  %-14s %7.2f %7.2f %7s %7s %7.3f" % ("frost traced", grain(reference), rim_grain(traced), "-", "-", 1.0))
    reference = without_fireflies(reference)
    for name in ("frost", "frost-moving", "frost-raw"):
        image = capture(folder, name)
        if image is None:
            continue
        previous = capture(folder, name + "-prev")
        crop = inside(image)
        same = crop[2:-2, 2:-2]
        print("  %-14s %7.2f %7.2f %7s %7.2f %7.3f" % (
            name, grain(crop), rim_grain(image), "%.2f" % flicker(crop, inside(previous)) if previous is not None else "-",
            psnr(same, reference), same.mean() / reference.mean()))
