#!/usr/bin/env python3
"""Adds an import of a module to Swift files that don't have it.

    python3 Tools/modules/addimport.py [--testable] <Module> <file or folder> […]

The line goes into the file's imports where it sorts (`@testable import` lines among the testable ones), or at the top
when it has none. Used when the engine moved into modules: each file imports the modules it uses.
"""
import os
import re
import sys


def files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                for n in sorted(names):
                    if n.endswith(".swift"):
                        yield os.path.join(root, n)
        elif p.endswith(".swift"):
            yield p


def add(path, module, testable):
    lines = open(path).read().split("\n")
    pattern = re.compile(r"^(@testable )?import (\w+)\s*$")
    if any((m := pattern.match(l)) and m.group(2) == module for l in lines):
        return False
    new = f"{'@testable ' if testable else ''}import {module}"
    imports = [i for i, l in enumerate(lines) if pattern.match(l)]
    same = [i for i in imports if bool(pattern.match(lines[i]).group(1)) == testable]
    if not imports:
        lines[0:0] = [new, ""]
    elif not same:
        lines.insert(imports[-1] + 1 if testable else imports[0], new)
    else:
        at = next((i for i in same if pattern.match(lines[i]).group(2).lower() > module.lower()), same[-1] + 1)
        lines.insert(at, new)
    open(path, "w").write("\n".join(lines))
    return True


def main():
    args = sys.argv[1:]
    testable = args and args[0] == "--testable"
    if testable:
        args = args[1:]
    module, paths = args[0], args[1:]
    n = sum(add(f, module, testable) for f in files(paths))
    print(f"import {module} added to {n} files")


if __name__ == "__main__":
    main()
