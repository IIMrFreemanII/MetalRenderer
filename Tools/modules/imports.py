#!/usr/bin/env python3
"""Keeps each module's imports to the package's modules it depends on (Package.swift).

    python3 Tools/modules/imports.py [--check]

A file moved from one module to another keeps the imports it had; one of a package module its new target doesn't
depend on still compiles while that module happens to be built already (its interface is on the search path), but
nothing orders the builds then, and a stale one can shadow a declaration that moved. This removes those imports
(`--check`: lists them, and fails if there are any).
"""
import importlib.util
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("inlinable", os.path.join(here, "inlinable.py"))
inlinable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inlinable)


def main():
    check = "--check" in sys.argv
    targets = inlinable.targets()
    modules = set(targets)
    found = []
    for name, (folder, deps) in targets.items():
        allowed = set(deps) | {name}
        root = os.path.join(inlinable.repo, folder)
        for dirpath, _, files in os.walk(root):
            for f in files:
                if not f.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, f)
                lines = open(path).read().split("\n")
                keep = []
                for l in lines:
                    m = re.match(r"^(?:@testable )?import (\w+)\s*$", l)
                    if m and m.group(1) in modules and m.group(1) not in allowed:
                        found.append(f"{os.path.relpath(path, inlinable.repo)}: import {m.group(1)}")
                        continue
                    keep.append(l)
                if len(keep) != len(lines) and not check:
                    open(path, "w").write("\n".join(keep))
    for line in found:
        print(line)
    print(f"{len(found)} imports of modules the target doesn't depend on" + ("" if check else " removed"))
    sys.exit(1 if check and found else 0)


if __name__ == "__main__":
    main()
