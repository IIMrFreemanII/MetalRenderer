#!/usr/bin/env python3
"""Moves top-level declarations (with their doc comments) from one Swift file to another.

    python3 Tools/modules/moveblocks.py <from.swift> <to.swift> Name [Name …]

A declaration is a line at column 0 that declares `Name` (struct, class, enum, protocol, typealias, func, extension),
with the `///` lines above it, through the first `}` at column 0 after it (or the line itself for a one-line one).
The destination is created with the source's imports if it doesn't exist; blocks are appended in the order named.
Used to split files when the engine moved into modules.
"""
import re
import sys


def blocks(lines):
    """[(name, kind, start, end)] of the top-level declarations (end exclusive)."""
    out, i = [], 0
    decl = re.compile(r"^(?:@[\w.()\" ,:]+\s+)*(?:(?:package|public|internal|fileprivate|private|final|indirect)\s+)*"
                      r"(struct|class|enum|protocol|typealias|func|extension|actor)\s+([\w.]+)")
    while i < len(lines):
        m = decl.match(lines[i])
        if not m:
            i += 1
            continue
        start = i
        while start > 0 and lines[start - 1].startswith("///"):
            start -= 1
        j = i
        code = lines[i].split("//")[0]
        if "{" in code and code.count("{") == code.count("}") or ("{" not in code and m.group(1) in ("typealias",)):
            end = i + 1
        else:
            j = i + 1
            while j < len(lines) and lines[j] != "}":
                j += 1
            end = j + 1
        out.append((m.group(2), m.group(1), start, end))
        i = end
    return out


def main():
    src, dst, names = sys.argv[1], sys.argv[2], sys.argv[3:]
    lines = open(src).read().split("\n")
    found = {}
    for name, kind, start, end in blocks(lines):
        if name in names:
            found.setdefault(name, []).append((start, end))
    missing = [n for n in names if n not in found]
    if missing:
        sys.exit(f"moveblocks: not found in {src}: {', '.join(missing)}")
    taken = sorted(r for n in names for r in found[n])
    moved = []
    for n in names:
        for start, end in found[n]:
            moved.append("\n".join(lines[start:end]).rstrip())
    keep, at = [], 0
    for start, end in taken:
        keep += lines[at:start]
        at = end
        while at < len(lines) and lines[at] == "" and keep and keep[-1] == "":
            at += 1
    keep += lines[at:]
    open(src, "w").write("\n".join(keep))
    try:
        head = open(dst).read().rstrip() + "\n\n"
    except FileNotFoundError:
        imports = [l for l in lines if l.startswith("import ")]
        head = "\n".join(imports) + "\n\n"
    open(dst, "w").write(head + "\n\n".join(moved) + "\n")
    print(f"moved {len(moved)} declarations: {' '.join(names)}")


if __name__ == "__main__":
    main()
