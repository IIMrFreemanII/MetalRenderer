#!/usr/bin/env python3
"""Writes a synthetic equirectangular HDR sky (Radiance .hdr) for testing MetalGI's image skies:
a blue-to-white gradient, a brown-green ground, a few soft cloud blobs and a bright sun disc (0.3 degrees,
at the given elevation and azimuth). u = 0.5 faces -z, v = 0 is straight up, as Shaders.metal equirectSample.

usage: make-test-sky.py <out.hdr> [elevation_deg=35] [azimuth_deg=20]   (azimuth: from -z toward +x)
"""
import math, struct, sys
import numpy as np

out = sys.argv[1]
elev = math.radians(float(sys.argv[2]) if len(sys.argv) > 2 else 35)
azim = math.radians(float(sys.argv[3]) if len(sys.argv) > 3 else 20)
W, H = 1024, 512
u = (np.arange(W) + 0.5) / W
v = (np.arange(H) + 0.5) / H
phi = (u - 0.5) * 2 * math.pi
theta = v * math.pi
st, ct = np.sin(theta)[:, None], np.cos(theta)[:, None]
d = np.stack([st * np.sin(phi)[None, :], np.broadcast_to(ct, (H, W)), -st * np.cos(phi)[None, :]], -1)
y = d[..., 1:2]
sun = np.array([math.cos(elev) * math.sin(azim), math.sin(elev), -math.cos(elev) * math.cos(azim)])

zenith, horizon, ground = np.array([0.25, 0.45, 0.95]), np.array([0.9, 0.95, 1.0]), np.array([0.25, 0.22, 0.15])
t = np.clip(y, 0, 1) ** 0.5
img = np.where(y > 0, horizon * (1 - t) + zenith * t, ground * 0.6)
img = img * 0.15   # real skies: the sun outshines the sky about 5 to 1 on a level floor
# Soft clouds: a few gaussian blobs above the horizon.
rng = np.random.default_rng(7)
for _ in range(14):
    a, e, s = rng.uniform(0, 2 * math.pi), rng.uniform(0.08, 0.7), rng.uniform(0.06, 0.15)
    c = np.array([math.cos(e) * math.sin(a), math.sin(e), -math.cos(e) * math.cos(a)])
    w = np.exp(-(1 - (d @ c)) / (s * s))[..., None]
    img = img * (1 - 0.8 * w) + np.array([1.3, 1.3, 1.25]) * 0.15 * w * 0.8
# Glow around the sun, then the disc (0.3 degrees, radiance ~ 2e4 x the sky).
cs = d @ sun
img = img + np.array([1.0, 0.9, 0.7])[None, None, :] * (np.exp((cs[..., None] - 1) * 60) * 2.0)
img = np.where(cs[..., None] > math.cos(math.radians(0.3)), np.array([1.0, 0.95, 0.85]) * 2.5e4, img)
img = np.maximum(img, 0).astype(np.float32)

# RGBE, flat scanlines.
m = img.max(-1)
e = np.where(m > 1e-32, np.floor(np.log2(np.maximum(m, 1e-32))) + 1, 0)
scale = np.where(m > 1e-32, 256.0 / np.exp2(e), 0)
rgbe = np.zeros((H, W, 4), np.uint8)
rgbe[..., :3] = np.clip(img * scale[..., None], 0, 255).astype(np.uint8)
rgbe[..., 3] = np.where(m > 1e-32, e + 128, 0).astype(np.uint8)
with open(out, "wb") as f:
    f.write(b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n" + f"-Y {H} +X {W}\n".encode())
    f.write(rgbe.tobytes())
print(f"wrote {out}: {W}x{H}, sun at elevation {math.degrees(elev):.1f}, azimuth {math.degrees(azim):.1f}")
