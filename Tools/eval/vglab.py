"""usage: vglab.py <vglab-run-dir> [--fly <vglabfly-run-dir>] [--json out.json] — the VG lab's pass/fail check.

Reads a folder written by `render.sh -m vglab` (PNGs `NN-vglabXX-<bookmark>-<view>-<vg|full>.png` and vglab.json, one entry
per config with the virtual geometry report) and, optionally, one from `-m vglabfly`. Prints a table (check, config,
value, limit, PASS/FAIL/INFO/SKIP) and exits 1 if any row FAILs. Run it with ~/.venvs/metalrenderer-eval/bin/python."""
import argparse, glob, json, os, sys
import numpy as np
from PIL import Image

# Limits. Each is the plan's number for its check.
CRACK_PIXELS = 8              # exact magenta pixels in a Cracks view: holes or folds in closed generated meshes
CRACK_GATED = ("02", "03")    # booths whose closed shapes are near: the check fails there. Elsewhere it is INFO: a thin
                              # shape far away (the field's torus knots, a tube a few cm thick) simplifies to an error
                              # larger than its thickness, and its walls may cross within that error, showing back faces
                              # (VGFoldTests proves the cuts themselves are closed and face out)
LOD_ERROR_FRACTION = 0.001    # share of the image the LOD error view may paint red / magenta (cut error beyond 1.05 / 0.95 tau)
LOD_MIN_RED = 40              # smallest red / magenta channel value counted (the kernel's shading factor is at least 0.35)
SILHOUETTE_TAU_FACTOR = 2.0   # mean silhouette deviation (px) allowed, in units of the report's pixelError
CUT_MS_FIELD = 5.0            # lastCutMs allowed at the "05 Field" bookmarks
MEGABYTES_LIMIT = 1024.0      # virtual geometry memory allowed anywhere
MEGABYTES_NOTE = 512.0        # memory above this is reported (INFO) but passes
SETTLED_SAMPLES = 8           # history samples at the end of a still config that must have no BLAS rebuilds
FLY_SWAPS_PER_INSTANCE_S = 1.0   # BLAS swaps per virtual instance per second over the fly (history: a sample a frame, 60 fps);
                                 # the glide passes 478 instances at ~20 m/s: a cut changes about every 1.5 s each
FLY_FPS = 60.0
MOVERS = "06"                 # bookmark number of the movers, excluded from the still checks (the scene moves)
FIELD = "05"                  # bookmark number of the field, where the cut time is limited

rows = []


def add(check, config, value, limit, status):
    rows.append({"check": check, "config": config, "value": value, "limit": limit, "status": status})


def slug(name):
    return name.replace(" ", "-")


def png_path(run, entry):
    s = slug(entry["name"])
    for p in sorted(glob.glob(f"{run}/*-{s}.png")):
        if os.path.basename(p).split("-", 1)[1] == s + ".png":
            return p
    return None


def load(run, entry):
    p = png_path(run, entry)
    return None if p is None else np.asarray(Image.open(p).convert("RGB")).astype(int)


def bookmark_number(entry):
    return entry["bookmark"][:2]


def is_cold(entry):
    """The cold-cache step (it evicts, then flies in): the entry with the residency before and after eviction. The
    stills at the 08 Cold bookmarks are ordinary stills."""
    return "residencyBefore" in entry


def tau(entry):
    r = entry.get("report") or {}
    return float(r.get("pixelError") or 1)


def find(entries, bookmark, view, vg):
    for e in entries:
        if e["bookmark"] == bookmark and e["view"] == view and e["vg"] == vg:
            return e


def short(entry):
    return entry["name"].replace("vglab", "", 1)


def check_cracks(run, entries):
    hits = [e for e in entries if e["vg"] and e["viewName"] == "Cracks"]
    if not hits: return add("cracks", "-", None, CRACK_PIXELS, "SKIP")
    for e in hits:
        img = load(run, e)
        if img is None: add("cracks", short(e), "no png", CRACK_PIXELS, "SKIP"); continue
        n = int(np.sum((img[..., 0] == 255) & (img[..., 1] == 0) & (img[..., 2] == 255)))
        if bookmark_number(e) in CRACK_GATED:
            add("cracks", short(e), n, CRACK_PIXELS, "PASS" if n <= CRACK_PIXELS else "FAIL")
        else:
            add("cracks (far, thin)", short(e), n, "-", "INFO")


def check_lod_error(run, entries):
    hits = [e for e in entries if e["vg"] and e["viewName"] == "LOD error"]
    if not hits: return add("lod error", "-", None, LOD_ERROR_FRACTION, "SKIP")
    for e in hits:
        if bookmark_number(e) == MOVERS or is_cold(e): continue
        img = load(run, e)
        if img is None: add("lod error", short(e), "no png", LOD_ERROR_FRACTION, "SKIP"); continue
        r, g, b = img[..., 0], img[..., 1], img[..., 2]
        red = (g == 0) & (b == 0) & (r >= LOD_MIN_RED)
        magenta = (g == 0) & (np.abs(r - b) <= 2) & (r >= LOD_MIN_RED)
        for what, mask in (("red", red), ("magenta", magenta)):
            f = float(mask.mean())
            add(f"lod error {what}", short(e), f"{100 * f:.4f}%", f"{100 * LOD_ERROR_FRACTION:.1f}%",
                "PASS" if f <= LOD_ERROR_FRACTION else "FAIL")


def hit_mask(img):
    return img.max(axis=2) > 0


def boundary(mask):
    p = np.pad(mask, 1, constant_values=False)
    inner = p[:-2, 1:-1] & p[2:, 1:-1] & p[1:-1, :-2] & p[1:-1, 2:]
    return mask & ~inner


def check_silhouettes(run, entries):
    # The Triangles view of the full-detail meshes against the virtual geometry's: sky is black in both, so a pixel
    # that is a hit in one and a miss in the other is silhouette error.
    pairs = [(e, find(entries, e["bookmark"], 8, False)) for e in entries if e["vg"] and e["view"] == 8]
    pairs = [(v, f) for v, f in pairs if f is not None]
    if not pairs: return add("silhouette", "-", None, f"{SILHOUETTE_TAU_FACTOR} tau", "SKIP")
    for v, f in pairs:
        if bookmark_number(v) == MOVERS: continue
        a, b = load(run, v), load(run, f)
        if a is None or b is None or a.shape != b.shape: add("silhouette", short(v), "no png", "-", "SKIP"); continue
        ma, mb = hit_mask(a), hit_mask(b)
        edge = int(boundary(mb).sum())
        if edge == 0: add("silhouette", short(v), "no edge", "-", "SKIP"); continue
        dev = float((ma ^ mb).sum()) / edge
        limit = SILHOUETTE_TAU_FACTOR * tau(v)
        add("silhouette px", short(v), f"{dev:.3f}", f"{limit:g}", "PASS" if dev <= limit else "FAIL")


def check_cut_and_memory(entries):
    reports = [e for e in entries if e["report"]]
    field = [e for e in reports if bookmark_number(e) == FIELD]
    if not field: add("cut ms", "05 Field", None, CUT_MS_FIELD, "SKIP")
    for e in field:
        ms = float(e["report"].get("lastCutMs", 0))
        add("cut ms", short(e), f"{ms:.3f}", CUT_MS_FIELD, "PASS" if ms <= CUT_MS_FIELD else "FAIL")
    if not reports: return add("megabytes", "-", None, MEGABYTES_LIMIT, "SKIP")
    top = max(reports, key=lambda e: e["report"].get("megabytes", 0))
    mb = float(top["report"].get("megabytes", 0))
    add("megabytes (max)", short(top), f"{mb:.1f}", MEGABYTES_LIMIT, "PASS" if mb <= MEGABYTES_LIMIT else "FAIL")
    for e in reports:
        mb = float(e["report"].get("megabytes", 0))
        if mb > MEGABYTES_NOTE and mb <= MEGABYTES_LIMIT:
            add("megabytes over 512", short(e), f"{mb:.1f}", MEGABYTES_NOTE, "INFO")


def check_settled(entries):
    hits = [e for e in entries if e["report"] and e["vg"] and bookmark_number(e) != MOVERS and not is_cold(e)]
    if not hits: return add("settled rebuilds", "-", None, 0, "SKIP")
    for e in hits:
        tail = e["report"]["history"][-SETTLED_SAMPLES:]
        if len(tail) < SETTLED_SAMPLES: add("settled rebuilds", short(e), f"{len(tail)} samples", 0, "SKIP"); continue
        n = sum(int(s["rebuilds"]) for s in tail)
        add("settled rebuilds", short(e), n, 0, "PASS" if n == 0 else "FAIL")


def check_fly(fly):
    path = os.path.join(fly, "vglabfly.json")
    if not os.path.exists(path): return add("fly", fly, "no vglabfly.json", "-", "SKIP")
    for e in json.load(open(path)):
        h = (e.get("report") or {}).get("history") or []
        if not h: add("fly swaps/instance/s", e["name"], "no history", FLY_SWAPS_PER_INSTANCE_S, "SKIP"); continue
        swaps = sum(int(s["rebuilds"]) for s in h) / (len(h) / FLY_FPS)
        rate = swaps / max(1, int(e["report"].get("instances", 1)))
        add("fly swaps/s", e["name"], f"{swaps:.1f}", "-", "INFO")
        add("fly swaps/instance/s", e["name"], f"{rate:.2f}", FLY_SWAPS_PER_INSTANCE_S, "PASS" if rate <= FLY_SWAPS_PER_INSTANCE_S else "FAIL")
        add("fly max cut ms", e["name"], f"{max(float(s['cutMs']) for s in h):.3f}", "-", "INFO")
        tri, mb = [int(s["triangles"]) for s in h], [float(s["megabytes"]) for s in h]
        add("fly triangles min/max", e["name"], f"{min(tri)} / {max(tri)}", "-", "INFO")
        add("fly megabytes min/max", e["name"], f"{min(mb):.1f} / {max(mb):.1f}", "-", "INFO")


def check_cold(entries):
    # Report only: evicting a mesh doesn't drop macOS's file cache without `sudo purge`, so a warm result proves nothing.
    cold = [e for e in entries if is_cold(e)]
    if not cold: return add("cold cache (report only)", "-", None, "-", "SKIP")
    for e in cold:
        for key in ("residencyBefore", "residencyAfter"):
            r = e.get(key) or []
            by_mesh = {}
            for x in r: by_mesh[x["mesh"]] = x["resident"]
            text = ", ".join(f"{m.split(' 3d model')[0]}{m[m.rfind('#'):]} {v:.2f}" for m, v in sorted(by_mesh.items()))
            add(f"cold {key}", short(e), text or "-", "-", "INFO")
        for row in (e.get("report") or {}).get("rows", []):
            if any(k in row["mesh"] for k in ("owl", "golem")):
                add("cold row faults/gatherMs", f"{row['mesh']} @{row['distance']}", f"{row['faults']} / {row['gatherMs']}", "-", "INFO")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dir")
    ap.add_argument("--fly")
    ap.add_argument("--json")
    a = ap.parse_args()
    path = os.path.join(a.dir, "vglab.json")
    if not os.path.exists(path): raise SystemExit(f"missing {path}: run render.sh -m vglab first")
    entries = json.load(open(path))
    check_cracks(a.dir, entries)
    check_lod_error(a.dir, entries)
    check_silhouettes(a.dir, entries)
    check_cut_and_memory(entries)
    check_settled(entries)
    if a.fly: check_fly(a.fly)
    else: add("fly", "-", None, "-", "SKIP")
    check_cold(entries)
    print("(cold cache rows are INFO only: eviction doesn't drop macOS's file cache without `sudo purge`)")
    print(f"{'check':26s}{'config':44s}{'value':>22s}{'limit':>10s}  status")
    for r in rows:
        v = "-" if r["value"] is None else str(r["value"])
        print(f"{r['check']:26s}{r['config'][:43]:44s}{v[:60]:>22s}{str(r['limit']):>10s}  {r['status']}")
    fails = sum(r["status"] == "FAIL" for r in rows)
    print(f"{sum(r['status'] == 'PASS' for r in rows)} pass, {fails} fail, {sum(r['status'] == 'SKIP' for r in rows)} skip")
    if a.json:
        json.dump(rows, open(a.json, "w"), indent=1)
    sys.exit(1 if fails else 0)


main()
