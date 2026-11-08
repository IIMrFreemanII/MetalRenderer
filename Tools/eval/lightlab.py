"""usage: lightlab.py <run-dir> ... — scores the Light lab's benchmarks (METALRENDERER_BENCH=lightlab and lightlabq, one or both
in the folders given) and writes a contact sheet.

Bias (lightlab): per booth with a direct check, built alone at its bookmark with GI off, accumulated: Sampled's and MegaLights'
PSNR and mean-luminance ratio against every light traced ("exact"), and the leak test, mean |alone - full| / mean of the exact
image of the booth alone against the same booth in the full hall (flagged above 0.5%: light came through a wall, or the kit
differs).

Quality (lightlabq): per booth in the full hall against an accumulated reference at 640x400 (MetalFX's 1920x1200 output is
box-filtered down 3x first), per method and denoiser: PSNR of the still, of the camera dolly (its last frame is still moving,
at the bookmark) and of the animation running (booths 21 and 22), flicker (RMS difference from the frame before, in 8-bit levels)
and, for booths with a specular check, the PSNR over the reference's brightest 2% of unclipped pixels (where direct specular
dominates). `.gi` booths: the app's cascades GI under MetalFX against the path-traced reference ("gi" column).

Contact sheet: <first run-dir>/lightlab-contact.png, each booth's MegaLights image at its bookmark (the quality run's, else the
bias run's) labelled with number, name and key scores. Settings are named `lab<NN> <group> <what>`; a missing image is a dash.
(manylights.py, shadow.py and specular.py run when imported, so their small helpers are written out here; the PSNR, flicker and
luminance functions are evalcommon's.)"""
import glob, os, re, sys
import numpy as np
from PIL import Image, ImageDraw
from evalcommon import psnr, flicker, mean_luminance, load, fmt, HERE

runs = sys.argv[1:]
if not runs:
    raise SystemExit(__doc__)
LEAK_LIMIT = 0.005
YARD = {23, 24, 25}   # open-air zones: no leak check


def blocks(img, k=8):
    """Means over k x k pixels (the image cropped to a multiple of k)."""
    h, w = img.shape[0] // k * k, img.shape[1] // k * k
    a = img[:h, :w]
    return a.reshape(h // k, k, w // k, k, *a.shape[2:]).mean(axis=(1, 3))


def find(name):
    """The capture `<index>-<name>.png` in any of the runs (exact name), or None."""
    for d in runs:
        for p in glob.glob(f"{d}/*-{name}.png"):
            if os.path.basename(p).split("-", 1)[1] == f"{name}.png":
                return load(p)
    return None


def booth_names():
    names = {}
    path = os.path.join(HERE, "..", "..", "Sources", "Game", "Scene", "Builders", "LightLab", "LightLab.swift")
    if os.path.exists(path):
        for n, name in re.findall(r'LabBooth\(number: (\d+), name: "([^"]+)"', open(path).read()):
            names[int(n)] = name
    return names


def booths_found():
    """{number: group tag} from the file names."""
    found = {}
    for d in runs:
        for p in glob.glob(f"{d}/*-lab[0-9][0-9]-*.png"):
            m = re.match(r"\d+-lab(\d\d)-([a-z]+)-", os.path.basename(p))
            if m: found[int(m.group(1))] = m.group(2)
    return dict(sorted(found.items()))


def get(n, group, what):
    return find(f"lab{n:02d}-{group}-{what}")


def to_ref_size(img, ref):
    """MetalFX's output (3x the reference's size) box-filtered down to it."""
    if img is None or img.shape == ref.shape: return img
    fy, fx = img.shape[0] // ref.shape[0], img.shape[1] // ref.shape[1]
    if fy < 1 or fy != fx or img.shape[0] != ref.shape[0] * fy: return None
    return img.reshape(ref.shape[0], fy, ref.shape[1], fx, 3).mean(axis=(1, 3))


def luminance(a):
    linear = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    return linear @ [0.2126, 0.7152, 0.0722]


def highlight_psnr(img, ref):
    lr = luminance(ref)
    unclipped = ref.max(axis=2) < 0.98
    if not unclipped.any(): return None
    bright = unclipped & (lr >= np.quantile(lr[unclipped], 0.98))
    mse = np.mean((img[bright] - ref[bright]) ** 2)
    return 10 * np.log10(1 / mse) if mse > 0 else None


def safe(f, *a):
    try:
        return f(*a)
    except Exception:
        return None


names, found = booth_names(), booths_found()
if not found:
    raise SystemExit(f"no lab<NN>-... images in {', '.join(runs)}")

# ---- bias and leaks
rows, scores = [], {}
for n, g in found.items():
    exact = get(n, g, "exact")
    if exact is None: continue
    row = []
    for method in ("sampled", "megalights"):
        img = get(n, g, method)
        row += [psnr(img, exact), mean_luminance(img) / mean_luminance(exact)] if img is not None else [None, None]
    full = get(n, g, "exact-full")
    # Light from elsewhere: compared over 8x8-pixel means, so the two accumulations' own noise doesn't count. The yard's
    # zones (23-25) share open ground and booth 25's second sun: there, alone and in full differ by design.
    leak = (float(np.mean(np.abs(blocks(exact) - blocks(full))) / max(np.mean(exact), 1e-9))
            if full is not None and n not in YARD else None)
    scores[n] = {"bias": row, "leak": leak}
    flag = "" if leak is None or leak <= LEAK_LIMIT else "  LEAK"
    rows.append(f"{n:3d} {names.get(n, '?')[:22]:23s}" + fmt(row) + (f"{leak * 100:10.3f}%" if leak is not None else f"{'—':>11s}") + flag)
if rows:
    print(f"{'':27s}{'sampled':>18s}{'megalights':>18s}")
    print(f"{'booth':27s}{'PSNR':>9s}{'mean':>9s}{'PSNR':>9s}{'mean':>9s}{'leak':>11s}    (accumulated vs every light traced; leak = mean |alone - full| / mean, limit {LEAK_LIMIT * 100:.1f}%)")
    print("\n".join(rows))

# ---- realtime quality
checks = {}
src = os.path.join(HERE, "..", "..", "Sources", "Game", "Scene", "Builders", "LightLab", "LightLab.swift")
if os.path.exists(src):
    for n, c in re.findall(r'LabBooth\(number: (\d+), .*?checks: \[([^\]]*)\]', open(src).read()):
        checks[int(n)] = set(re.findall(r"\.(\w+)", c))
rows = []
for n, g in found.items():
    ref = get(n, g, "ref-direct")
    if ref is None: continue
    for method in ("megalights", "sampled"):
        for look in ("metalfx", "svgf"):
            base = f"{method}-{look}"
            st = to_ref_size(get(n, g, f"{base}-static"), ref)
            if st is None: continue
            prev = to_ref_size(get(n, g, f"{base}-static-prev"), ref)
            cam, mv = to_ref_size(get(n, g, f"{base}-camera"), ref), to_ref_size(get(n, g, f"{base}-moving"), ref)
            hl = highlight_psnr(st, ref) if "specular" in checks.get(n, set()) else None
            vals = [psnr(st, ref), flicker(st, prev) if prev is not None else None, psnr(cam, ref) if cam is not None else None,
                    psnr(mv, ref) if mv is not None else None, hl]
            scores.setdefault(n, {}).setdefault("q", {})[base] = vals
            rows.append(f"{n:3d} {names.get(n, '?')[:20]:21s}{method:11s}{look:8s}" + fmt(vals))
if rows:
    print(f"\n{'booth':25s}{'method':11s}{'denoiser':8s}{'still':>9s}{'flicker':>9s}{'camera':>9s}{'moving':>9s}{'highlt':>9s}    (PSNR dB vs the accumulated reference; flicker in 8-bit levels)")
    print("\n".join(rows))

rows = []
for n, g in found.items():
    pt, gi = get(n, g, "ref-pt"), get(n, g, "megalights-gi")
    if pt is None or gi is None: continue
    gi = to_ref_size(gi, pt)  # (the GI frame is MetalFX's, 3x)
    if gi is None: continue
    vals = [psnr(gi, pt), mean_luminance(gi) / mean_luminance(pt)]
    scores.setdefault(n, {})["gi"] = vals
    rows.append(f"{n:3d} {names.get(n, '?')[:22]:23s}" + fmt(vals))
if rows:
    print(f"\n{'booth':27s}{'PSNR':>9s}{'mean':>9s}    (cascades GI + MegaLights under MetalFX vs the path-traced reference)")
    print("\n".join(rows))

# ---- contact sheet
TILE, LABEL, COLS = (480, 300), 44, 4
tiles = []
for n, g in found.items():
    img = get(n, g, "megalights-metalfx-static")
    if img is None: img = get(n, g, "megalights-svgf-static")
    if img is None: img = get(n, g, "megalights")
    tile = Image.new("RGB", (TILE[0], TILE[1] + LABEL), (24, 24, 24))
    if img is not None:
        tile.paste(Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)).resize(TILE, Image.LANCZOS), (0, LABEL))
    s = scores.get(n, {})
    parts = []
    if s.get("bias") and s["bias"][2] is not None: parts.append(f"bias {s['bias'][2]:.1f} dB x{s['bias'][3]:.2f}")
    if s.get("leak") is not None: parts.append(f"leak {s['leak'] * 100:.2f}%")
    q = s.get("q", {}).get("megalights-metalfx") or s.get("q", {}).get("megalights-svgf")
    if q: parts.append(f"still {q[0]:.1f} dB")
    if "gi" in s: parts.append(f"gi {s['gi'][0]:.1f} dB")
    d = ImageDraw.Draw(tile)
    d.text((6, 4), f"{n:02d} {names.get(n, '')}", fill=(255, 255, 255))
    d.text((6, 22), "  ".join(parts) or "no scores", fill=(255, 120, 120) if (s.get("leak") or 0) > LEAK_LIMIT else (170, 200, 255))
    tiles.append(tile)
rowsN = (len(tiles) + COLS - 1) // COLS
sheet = Image.new("RGB", (COLS * TILE[0], rowsN * (TILE[1] + LABEL)), (0, 0, 0))
for i, t in enumerate(tiles):
    sheet.paste(t, ((i % COLS) * TILE[0], (i // COLS) * (TILE[1] + LABEL)))
out = os.path.join(runs[0], "lightlab-contact.png")
sheet.save(out)
print(f"\ncontact sheet: {out}")
