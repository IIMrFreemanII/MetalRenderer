#!/usr/bin/env python3
"""Writes the small OpenEXR fixtures EXRImageTests decodes, and what the OpenEXR library itself decodes from them.

Three images, each in every compression EXRImage reads (NONE, RLE, ZIPS, ZIP, PIZ, DWAA, DWAB), 37 x 41 pixels so the
8 x 8 DCT blocks, the 16-line ZIP and 32-line PIZ/DWAA chunks are partial; the data window starts at (5, -3):
  color_<c>.exr     A, B, G, R half (a smooth gradient with noise, values below 0 and above 1, a flat corner),
                    Z float, id uint
  gray_<c>.exr      Y half
  floatrgb_<c>.exr  B, G, R float
plus
  tiled_zip.exr     R, G, B half of color in 16 x 16 tiles (EXRImage hands tiled files to ImageIO)
  layers_dwaa.exr   left.B, left.G, left.R, right.Y: DWA's colour sets by layer
  ramp_piz.exr      540 x 32 halves counting up: PIZ's 16-bit wavelet
  hash_zips.exr     16 x 16 hashed uints, stored uncompressed (they don't compress)

The references are raw little-endian float32, each channel's rows from the top, channels in name order:
  ref_<image>.bin        the lossless files (the script checks the library decodes every one of them to the same)
  ref_<image>_dwaa.bin   what the library decodes from the lossy DWAA file (and _dwab for DWAB)

usage: venv/bin/python -I make.py [out_dir=this script's folder]   (needs numpy and the OpenEXR package, 3.3 or later)
"""
import os, sys
import numpy as np
import OpenEXR

out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
W, H = 37, 41
X0, Y0 = 5, -3
rng = np.random.default_rng(17)
y, x = np.mgrid[0:H, 0:W].astype(np.float32)

def smooth(scale, phase):
    return (np.sin(x * scale + phase) * np.cos(y * scale * 0.7 - phase)).astype(np.float32)

def noise(amount):
    return (rng.standard_normal((H, W)) * amount).astype(np.float32)

r = 0.05 + 1.6 * x / W + 0.3 * smooth(0.21, 0.4) + noise(0.02)
g = -0.2 + 1.1 * y / H + 0.2 * smooth(0.13, 1.1) + noise(0.02)
b = 0.5 + 0.45 * smooth(0.31, 2.0) + noise(0.03)
b[30:, 25:] = 3.75 + noise(0.2)[30:, 25:]             # bright: the log branch of the DWA curve
for c in (r, g, b):
    c[:10, :12] = 0.25                                 # flat: constant DCT blocks
a = np.clip(x / (W - 1), 0, 1)
a[:, 20:] = 1.0                                        # runs for RLE
yy = 0.35 + 0.5 * smooth(0.17, 0.3) + noise(0.01)
z = (1.0 + 99.0 * (x + W * y) / (W * H) + noise(0.5)).astype(np.float32)
ident = ((x // 4) * 7 + (y // 3) * 13).astype(np.uint32) % 1000

images = {
    "color": {"A": a.astype(np.float16), "B": b.astype(np.float16), "G": g.astype(np.float16),
              "R": r.astype(np.float16), "Z": z, "id": ident},
    "gray": {"Y": yy.astype(np.float16)},
    "floatrgb": {"B": b, "G": g, "R": r},
}
compressions = {
    "none": OpenEXR.NO_COMPRESSION, "rle": OpenEXR.RLE_COMPRESSION, "zips": OpenEXR.ZIPS_COMPRESSION,
    "zip": OpenEXR.ZIP_COMPRESSION, "piz": OpenEXR.PIZ_COMPRESSION, "dwaa": OpenEXR.DWAA_COMPRESSION,
    "dwab": OpenEXR.DWAB_COMPRESSION,
}

def header(compression, tiled=False):
    h = {"compression": compression, "type": OpenEXR.tiledimage if tiled else OpenEXR.scanlineimage,
         "dataWindow": (np.array([X0, Y0], dtype=np.int32), np.array([X0 + W - 1, Y0 + H - 1], dtype=np.int32)),
         "displayWindow": (np.array([0, 0], dtype=np.int32), np.array([63, 63], dtype=np.int32))}
    if tiled:
        # Data window = display window, so that what ImageIO hands back has the same pixels.
        h["dataWindow"] = h["displayWindow"] = (np.array([0, 0], dtype=np.int32), np.array([W - 1, H - 1], dtype=np.int32))
        t = OpenEXR.TileDescription()
        t.xSize, t.ySize, t.mode = 16, 16, OpenEXR.ONE_LEVEL
        h["tiles"] = t
    return h

def decoded(path):
    with OpenEXR.File(path, separate_channels=True) as f:
        h = f.header()
        lo, hi = h["dataWindow"]
        assert (lo[0], lo[1], hi[0], hi[1]) == (X0, Y0, X0 + W - 1, Y0 + H - 1), h["dataWindow"]
        return {n: c.pixels for n, c in f.channels().items()}

def save_reference(name, channels):
    planes = [np.asarray(channels[n], dtype=np.float32).reshape(H, W) for n in sorted(channels)]
    np.concatenate([p.ravel() for p in planes]).astype("<f4").tofile(os.path.join(out, f"ref_{name}.bin"))

for image, channels in images.items():
    for cname, compression in compressions.items():
        path = os.path.join(out, f"{image}_{cname}.exr")
        OpenEXR.File(header(compression), dict(channels)).write(path)
        back = decoded(path)
        assert sorted(back) == sorted(channels), (path, sorted(back))
        if cname.startswith("dwa"):
            save_reference(f"{image}_{cname}", back)
        else:
            for n, v in channels.items():
                assert back[n].dtype == v.dtype and np.array_equal(back[n].view(np.uint8), v.view(np.uint8)), (path, n)
    save_reference(image, channels)

OpenEXR.File(header(OpenEXR.ZIP_COMPRESSION, tiled=True), {n: images["color"][n] for n in "RGB"}).write(
    os.path.join(out, "tiled_zip.exr"))

# Layers: DWA groups R, G, B by their name's prefix.
layers = {"left.B": images["color"]["B"], "left.G": images["color"]["G"], "left.R": images["color"]["R"],
          "right.Y": images["gray"]["Y"]}
path = os.path.join(out, "layers_dwaa.exr")
OpenEXR.File(header(OpenEXR.DWAA_COMPRESSION), dict(layers)).write(path)
save_reference("layers_dwaa", decoded(path))

def plain_header(compression, w, h):
    return {"compression": compression, "type": OpenEXR.scanlineimage,
            "dataWindow": (np.array([0, 0], dtype=np.int32), np.array([w - 1, h - 1], dtype=np.int32)),
            "displayWindow": (np.array([0, 0], dtype=np.int32), np.array([w - 1, h - 1], dtype=np.int32))}

# A PIZ chunk with more than 2^14 distinct 16-bit words takes the 16-bit wavelet: one 32-line chunk of halves
# whose bit patterns count up, pixel i (row by row) holding half i, which the test recomputes.
w, h = 540, 32
ramp = np.arange(w * h, dtype=np.uint16).view(np.float16).reshape(h, w)
assert w * h > 1 << 14 and np.isfinite(ramp).all()
path = os.path.join(out, "ramp_piz.exr")
OpenEXR.File(plain_header(OpenEXR.PIZ_COMPRESSION, w, h), {"Y": ramp}).write(path)
assert os.path.getsize(path) < ramp.nbytes // 2, "the ramp was stored uncompressed"

# Chunks that don't compress are stored as they are: hashed uints, 2654435761 i mod 2^32, in ZIPS.
n = 16
hashed = (np.arange(n * n, dtype=np.uint64) * 2654435761 % (1 << 32)).astype(np.uint32).reshape(n, n)
path = os.path.join(out, "hash_zips.exr")
OpenEXR.File(plain_header(OpenEXR.ZIPS_COMPRESSION, n, n), {"id": hashed}).write(path)
assert os.path.getsize(path) > hashed.nbytes + 8 * n, "the hashed rows compressed"
print("wrote", len(images) * len(compressions) + 4, "files to", out)
