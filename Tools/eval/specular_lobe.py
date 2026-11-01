#!/usr/bin/env python3
"""Prints Surface.metal's SPECULAR_LOBE: what the GGX lobe (height-correlated Smith, as Surface.metal shades it) reflects
of light from all round, as a share of F0 and of F90, on a 17x17 grid of roughness and sqrt(NoV).

  ~/.venvs/metalrenderer-eval/bin/python Tools/eval/specular_lobe.py
"""
import numpy as np

SIZE = 17


def lobe(roughness, nov, n=512):
    """Visible-normal samples: the lobe's cos-weighted BRDF over their pdf is G2 / G1, Fresnel apart."""
    a = max(roughness * roughness, 1e-4)
    a2 = a * a
    nov = max(nov, 1e-3)
    v = np.array([np.sqrt(1 - nov * nov), 0, nov])
    g1 = 2 * nov / (nov + np.sqrt(a2 + (1 - a2) * nov * nov))
    vh = np.array([a * v[0], 0, v[2]])
    vh /= np.linalg.norm(vh)
    t1 = np.array([0, 1.0, 0]) if vh[0] > 0 else np.array([1.0, 0, 0])
    t2 = np.cross(vh, t1)
    u1, u2 = np.meshgrid((np.arange(n) + 0.5) / n, (np.arange(n) + 0.5) / n)
    r = np.sqrt(u1)
    phi = 2 * np.pi * u2
    s = 0.5 * (1 + vh[2])
    p1 = r * np.cos(phi)
    p2 = (1 - s) * np.sqrt(np.maximum(0, 1 - p1 * p1)) + s * r * np.sin(phi)
    nh = p1[..., None] * t1 + p2[..., None] * t2 + np.sqrt(np.maximum(0, 1 - p1 * p1 - p2 * p2))[..., None] * vh
    h = np.stack([a * nh[..., 0], a * nh[..., 1], np.maximum(0, nh[..., 2])], -1)
    h /= np.linalg.norm(h, axis=-1, keepdims=True)
    voh = (h * v).sum(-1)
    lz = 2 * voh * h[..., 2] - v[2]
    gv = lz * np.sqrt(nov * nov * (1 - a2) + a2)
    gl = nov * np.sqrt(lz * lz * (1 - a2) + a2)
    w = np.where(lz > 0, 2 * lz * nov / np.maximum(gv + gl, 1e-7) / g1, 0)
    fresnel = (1 - np.clip(voh, 0, 1)) ** 5
    return (w * (1 - fresnel)).mean(), (w * fresnel).mean()


for i in range(SIZE):
    row = [lobe(i / (SIZE - 1), (j / (SIZE - 1)) ** 2) for j in range(SIZE)]
    print("    " + " ".join("{%.4ff, %.4ff}," % ab for ab in row))
