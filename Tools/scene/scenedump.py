#!/usr/bin/env python3
"""Prints a scene file (Assets/Scenes/<scene>.scene, SceneFile.swift) as text: one line per object, light and generator,
and the camera. git uses it to show the files' diffs (README, "Scene files"):

    git config diff.scenedump.textconv "python3 Tools/scene/scenedump.py"

    scenedump.py <file.scene>
"""
import struct
import sys

MAGIC, VERSION, KEY = 0x4653_524D, 1, b"scene/1"


def sections(data):
    magic, version, key_len, count = struct.unpack_from("<4I", data, 0)
    if magic != MAGIC or version != VERSION:
        raise SystemExit(f"not a section file of version {VERSION}")
    key = data[16:16 + key_len]
    if key != KEY:
        raise SystemExit(f"a section file for {key.decode(errors='replace')!r}, not a scene")
    out, at = {}, 16 + key_len
    for _ in range(count):
        ident, stride, offset, size = struct.unpack_from("<IIQQ", data, at)
        at += 24
        out[ident.to_bytes(4, "little").decode()] = (stride, data[offset:offset + size])
    return out


def records(sec, name, fmt):
    if name not in sec:
        return []
    stride, raw = sec[name]
    return [struct.unpack_from(fmt, raw, i) for i in range(0, len(raw), stride)]


def fmt(v):
    return " ".join(f"{x:g}" for x in v)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    data = open(sys.argv[1], "rb").read()
    sec = sections(data)
    text = sec.get("strs", (1, b""))[1]
    ranges = records(sec, "stro", "<2I")
    def s(i):
        if i >= len(ranges):
            return ""
        lo, n = ranges[i]
        return text[lo:lo + n].decode(errors="replace")
    for k, o in enumerate(records(sec, "objs", "<12f5I")):
        pos, rot, scale = o[0:3], o[4:8], o[8:11]
        asset, name, material, parent, flags = o[12], o[13], o[14], struct.unpack("<i", struct.pack("<I", o[15]))[0], o[16]
        extra = (f" parent={parent}" if parent >= 0 else "") + (f" material={s(material)}" if s(material) else "") + (f" flags={flags}" if flags else "")
        print(f"object {k} {s(name)!r} {s(asset)} at {fmt(pos)} rot {fmt(rot)} scale {fmt(scale)}{extra}")
    kinds = ["sphere", "spot", "rect", "tube", "sun"]
    for l in records(sec, "lite", "<16fI"):
        kind = int(l[3])
        print(f"light {s(l[16])!r} {kinds[kind] if kind < len(kinds) else kind} at {fmt(l[0:3])} dir {fmt(l[4:7])} color {fmt(l[8:11])} size {fmt(l[12:16])}")
    blob = [r[0] for r in records(sec, "blob", "<f")]
    for g in records(sec, "gens", "<Q4I"):
        seed, name, first, count = g[0], g[1], g[2], g[3]
        print(f"generator {s(name)!r} seed {seed} params {fmt(blob[first:first + count])}")
    for c in records(sec, "camr", "<8f"):
        print(f"camera at {fmt(c[0:3])} yaw {c[3]:g} pitch {c[4]:g} fov {c[5]:g}")


if __name__ == "__main__":
    main()
