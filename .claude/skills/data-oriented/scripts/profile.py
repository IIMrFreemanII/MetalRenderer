#!/usr/bin/env python3
"""Reads a Time Profiler export (xctrace export … time-profile table) and prints where the frames' CPU time goes.

    profile.py <export.xml> [--top N] [--all] [--callers SYMBOL …]

By default only samples under Renderer.drawFrame (or Scene.update) count, and a scene's load (prepareScene,
rebuildScene) is left out, so what's left is the per-frame work. --all counts every sample of the process.
Prints the functions with the most samples including their callees ("inclusive", ours only), the most samples in
the function itself ("self", runtime and system calls included), the runtime calls a fast loop must not make
(retain/release, swift_beginAccess, objc_msgSend, memmove of copied elements …) with the functions of ours that make
them, and with --callers the call paths into the named symbols. One sample is about 1 ms of one thread.
"""
import argparse
import collections
import sys
import xml.etree.ElementTree as ET

RUNTIME = ("swift_retain", "swift_release", "swift_bridgeObject", "swift_unknownObject", "objc_retain", "objc_release",
           "swift_allocObject", "malloc", "_xzm_", "swift_beginAccess", "swift_endAccess", "swift_isUniquelyReferenced",
           "swift_dynamicCast", "objc_msgSend", "_platform_memmove", "conformsToProtocol", "__psynch_mutexwait")
FRAME_ROOTS = ("Renderer.drawFrame", "Scene.update")
LOAD = ("prepareScene", "rebuildScene")


def samples(path):
    """(thread name, [frame names, leaf first]) per sample."""
    root = ET.parse(path).getroot()
    ids = {}

    def resolve(e):
        r = e.get("ref")
        if r is not None:
            return ids[r]
        i = e.get("id")
        if i is not None:
            ids[i] = e
        for c in e:
            resolve(c)
        return e

    for row in root.iter("row"):
        thread = row.find("thread")
        name = resolve(thread).get("fmt", "?") if thread is not None else "?"
        bt = row.find("tagged-backtrace")
        if bt is None:
            continue
        frames = [resolve(f).get("name") or "?" for f in resolve(bt).iter("frame")]
        if frames:
            yield name, frames


def ours(name):
    """A function of this project's (as far as a name tells): not the runtime's, the system's or the driver's."""
    return (not name.startswith(("_", "-[", "+[", "0x", "<", "swift_", "objc_", "thread_start", "start_wqthread",
                                 "dyld", "thunk for", "specialized autoreleasepool", "specialized Array",
                                 "specialized _Array", "specialized _ContiguousArray"))
            and "AGX" not in name and "::" not in name and "IOGPU" not in name and "MTL" not in name[:4])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xml")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--all", action="store_true", help="every sample, the load included")
    ap.add_argument("--callers", nargs="*", default=[], help="print the call paths into these symbols (substrings)")
    args = ap.parse_args()

    inclusive, own, runtime, callers = (collections.Counter() for _ in range(4))
    total = 0
    for _, frames in samples(args.xml):
        if not args.all:
            if not any(r in f for f in frames for r in FRAME_ROOTS) or any(l in f for f in frames for l in LOAD):
                continue
        total += 1
        own[frames[0][:100]] += 1
        for f in set(frames):
            if ours(f):
                inclusive[f[:100]] += 1
        if frames[0].startswith(RUNTIME) or any(frames[0].startswith("_" + r) or r in frames[0] for r in RUNTIME):
            caller = next((f for f in frames[1:] if ours(f) and not f.startswith("specialized Array")), "?")
            runtime[(frames[0][:40], caller[:90])] += 1
        for target in args.callers:
            if target in frames[0]:
                callers[(target, " <- ".join(f[:60] for f in frames[1:5]))] += 1

    print(f"{total} samples{'' if args.all else ' in frames (load left out)'}")
    print("\n--- inclusive (ours)")
    shown = [(name, n) for name, n in inclusive.most_common() if n < total or args.all][:args.top]   # (not the
    for name, n in shown:                                                                              # loop's frames)
        print(f"{n:6d}  {name}")
    print("\n--- self")
    for name, n in own.most_common(args.top):
        print(f"{n:6d}  {name}")
    print("\n--- runtime calls, by the function of ours that makes them")
    for (sym, caller), n in runtime.most_common(args.top):
        print(f"{n:6d}  {sym:40s} <- {caller}")
    if args.callers:
        print("\n--- callers")
        for (target, path), n in callers.most_common(args.top):
            print(f"{n:6d}  {target} <- {path}")


if __name__ == "__main__":
    sys.exit(main())
