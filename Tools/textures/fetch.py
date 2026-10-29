#!/usr/bin/env python3
"""Fetch the CC0 photo-scanned texture sets in manifest.json into Assets/Textures/<set>/.

    Tools/textures/fetch.py --list          # names, sources and download sizes; downloads nothing
    Tools/textures/fetch.py [--yes] [set…]  # download (asks first unless --yes)

Each set becomes albedo.jpg, normal.jpg (OpenGL convention), roughness.jpg, ao.jpg, height.jpg and,
for atlases, opacity.jpg, plus info.json (source, id, physical size in metres) and LICENSE.txt.
Sources: Poly Haven (api.polyhaven.com) and ambientCG (ambientcg.com), both CC0.
"""
import argparse, io, json, os, shutil, sys, tempfile, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "Assets", "Textures")
RES = "2k"
UA = {"User-Agent": "MetalRenderer-texture-fetch/1.0"}

def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return json.load(r)

def get_bytes(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=300) as r:
        return r.read()

# Poly Haven map names → ours.
PH_MAPS = {"Diffuse": "albedo", "nor_gl": "normal", "Rough": "roughness", "AO": "ao", "Displacement": "height"}
# ambientCG file suffixes → ours.
ACG_MAPS = {"Color": "albedo", "NormalGL": "normal", "Roughness": "roughness", "AmbientOcclusion": "ao",
            "Displacement": "height", "Opacity": "opacity"}

def plan_polyhaven(entry):
    files = get_json(f"https://api.polyhaven.com/files/{entry['id']}")
    info = get_json(f"https://api.polyhaven.com/info/{entry['id']}")
    if info.get("type") != 1:
        raise SystemExit(f"{entry['id']}: not a Poly Haven texture")
    maps = {}
    for key, ours in PH_MAPS.items():
        if key in files and RES in files[key] and "jpg" in files[key][RES]:
            f = files[key][RES]["jpg"]
            maps[ours] = (f["url"], f["size"])
    if "albedo" not in maps or "normal" not in maps:
        raise SystemExit(f"{entry['id']}: no {RES} albedo/normal")
    dims = info.get("dimensions") or [2000, 2000]
    return {"maps": maps, "size": sum(s for _, s in maps.values()), "metres": dims[0] / 1000.0,
            "author": ", ".join(info.get("authors", {}).keys()), "page": f"https://polyhaven.com/a/{entry['id']}"}

def plan_ambientcg(entry):
    d = get_json(f"https://ambientcg.com/api/v2/full_json?id={entry['id']}&include=downloadData,dimensionsData")
    found = d.get("foundAssets") or []
    if not found:
        raise SystemExit(f"{entry['id']}: not on ambientCG")
    a = found[0]
    zips = a["downloadFolders"]["default"]["downloadFiletypeCategories"]["zip"]["downloads"]
    z = next((c for c in zips if c["attribute"] == f"{RES.upper()}-JPG"), None)
    if z is None:
        raise SystemExit(f"{entry['id']}: no {RES.upper()}-JPG zip")
    metres = entry.get("metres") or (a.get("dimensionX") or 200) / 100.0   # (some sets say no size: the manifest does)
    return {"zip": z["downloadLink"], "size": z["size"], "metres": metres, "author": "ambientCG",
            "page": f"https://ambientcg.com/view?id={entry['id']}"}

def plan(entry):
    return plan_polyhaven(entry) if entry["source"] == "polyhaven" else plan_ambientcg(entry)

def fetch(entry, p):
    dest = os.path.join(OUT, entry["set"])
    tmp = tempfile.mkdtemp(prefix="tex-")
    try:
        if "maps" in p:
            for ours, (url, _) in p["maps"].items():
                with open(os.path.join(tmp, ours + ".jpg"), "wb") as f:
                    f.write(get_bytes(url))
        else:
            data = get_bytes(p["zip"])
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                for name in zf.namelist():
                    base = os.path.basename(name)
                    stem, ext = os.path.splitext(base)
                    if ext.lower() not in (".jpg", ".jpeg"):
                        continue
                    suffix = stem.split("_")[-1]
                    if suffix in ACG_MAPS:
                        with open(os.path.join(tmp, ACG_MAPS[suffix] + ".jpg"), "wb") as f:
                            f.write(zf.read(name))
        missing = [m for m in ("albedo", "normal") if not os.path.exists(os.path.join(tmp, m + ".jpg"))]
        if missing:
            raise SystemExit(f"{entry['id']}: missing {missing}")
        info = {"source": entry["source"], "id": entry["id"], "metres": p["metres"],
                "author": p["author"], "page": p["page"], "use": entry.get("use", "")}
        if "cells" in entry:   # a leaf sheet's grid: columns, rows (LeafOutline)
            info["cells"] = entry["cells"]
        with open(os.path.join(tmp, "info.json"), "w") as f:
            json.dump(info, f, indent=2)
        with open(os.path.join(tmp, "LICENSE.txt"), "w") as f:
            f.write(f"CC0 1.0 Universal (public domain). {p['page']} by {p['author']}.\n")
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        os.makedirs(OUT, exist_ok=True)
        shutil.move(tmp, dest)
        tmp = None
    finally:
        if tmp and os.path.isdir(tmp):
            shutil.rmtree(tmp)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--yes", action="store_true")
    args = ap.parse_args()
    manifest = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "manifest.json")))
    entries = [e for e in manifest["sets"] if not args.sets or e["set"] in args.sets]
    plans = []
    for e in entries:
        p = plan(e)
        plans.append((e, p))
        have = "  (present)" if os.path.isdir(os.path.join(OUT, e["set"])) else ""
        print(f"{e['set']:13} {e['source']:9} {e['id']:22} {p['size'] / 1e6:6.1f} MB  {p['metres']:.2f} m{have}")
    total = sum(p["size"] for _, p in plans)
    print(f"total download {total / 1e6:.1f} MB")
    if args.list:
        return
    if not args.yes and input("download? [y/N] ").strip().lower() != "y":
        return
    for e, p in plans:
        print("fetching", e["set"], flush=True)
        fetch(e, p)
    print("done:", OUT)

if __name__ == "__main__":
    main()
