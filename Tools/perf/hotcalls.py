#!/usr/bin/env python3
"""Checks that the hot loops listed in hot-functions.txt stay in the fast subset of Swift.

    python3 Tools/perf/hotcalls.py [--binary .build/release/MetalRenderer] [--list Tools/perf/hot-functions.txt] [-v]

Disassembles the release binary (otool -tV), finds every function whose demangled name contains one of the list's
patterns, and fails if one of them calls into the runtime: reference counting (swift_retain / objc_retain …), heap
allocation, exclusivity checks (swift_beginAccess), copy-on-write uniqueness checks, dynamic casts or Objective-C
messages. Those are what a loop over thousands of elements a frame must not do (references/cpu-swift.md §2).

Only each function's own body is read: a call it makes to another function of ours is listed with -v but not
followed, so list the callees that are hot too. A pattern that matches no function fails as well (a rename left the
list stale). Build release first: `swift build -c release`.
"""
import argparse
import collections
import os
import re
import subprocess
import sys

# Runtime entry points a hot loop must not call (prefixes of the stub's symbol, without the leading underscore).
FORBIDDEN = (
    "swift_retain", "swift_release", "swift_bridgeObjectRetain", "swift_bridgeObjectRelease",
    "swift_unknownObjectRetain", "swift_unknownObjectRelease", "objc_retain", "objc_release",
    "swift_allocObject", "swift_allocBox", "swift_slowAlloc", "malloc",
    "swift_beginAccess", "swift_isUniquelyReferenced", "swift_arrayInitWithCopy", "swift_arrayDestroy",
    "swift_dynamicCast", "objc_msgSend",
)

HEADER = re.compile(r"^(_\S+):$")
CALL = re.compile(r"\tbl\t0x[0-9a-f]+(?: ; (?:symbol stub for: )?(_\S+))?")


def functions(binary):
    """Mangled name -> the symbols its body calls (direct `bl`s; stubs by their target's name)."""
    out = subprocess.run(["xcrun", "otool", "-tV", binary], capture_output=True, text=True, check=True).stdout
    calls, current = {}, None
    for line in out.splitlines():
        m = HEADER.match(line)
        if m:
            current = m.group(1)
            calls[current] = []
            continue
        if current is not None and "\tbl\t" in line:
            c = CALL.search(line)
            calls[current].append(c.group(1) if c and c.group(1) else "?")
    return calls


def demangle(names):
    tool = subprocess.run(["xcrun", "--find", "swift-demangle"], capture_output=True, text=True, check=True).stdout.strip()
    res = subprocess.run([tool, "--simplified"], input="\n".join(names), capture_output=True, text=True, check=True).stdout
    return dict(zip(names, res.splitlines()))


def patterns(path):
    out = []
    with open(path) as f:
        for raw in f:
            line = raw.strip()   # (names have "#" in them: "closure #1 in …", so only whole lines are comments)
            if line and not line.startswith("#"):
                out.append(line)
    return out


def main():
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary", default=os.path.join(repo, ".build/release/MetalRenderer"))
    ap.add_argument("--list", default=os.path.join(repo, "Tools/perf/hot-functions.txt"))
    ap.add_argument("-v", "--verbose", action="store_true", help="also list each function's other calls")
    args = ap.parse_args()
    if not os.path.exists(args.binary):
        sys.exit(f"hotcalls: {args.binary} not found; run swift build -c release")

    calls = functions(args.binary)
    ours = [n for n in calls if n.startswith("_$s13MetalRenderer")]
    names = demangle([n[1:] for n in ours])   # swift-demangle wants the name without the leading underscore
    failed = False
    for pattern in patterns(args.list):
        matched = [n for n in ours if pattern in names[n[1:]]]
        if not matched:
            print(f"STALE  {pattern}: no function matches")
            failed = True
            continue
        for n in matched:
            bad = collections.Counter(c[1:] for c in calls[n] if c[1:].startswith(FORBIDDEN))
            status = "FAIL " if bad else "ok   "
            print(f"{status} {names[n[1:]]}")
            for sym, count in sorted(bad.items()):
                print(f"         {count}× {sym}")
            if args.verbose:
                other = collections.Counter(c[1:] for c in calls[n] if not c[1:].startswith(FORBIDDEN))
                for sym, count in sorted(other.items()):
                    print(f"         ({count}× {demangle([sym])[sym] if sym.startswith('$s') else sym})")
            failed |= bool(bad)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
