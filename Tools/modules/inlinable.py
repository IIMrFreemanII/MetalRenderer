#!/usr/bin/env python3
"""Rebuilds what inlined an @inlinable declaration that changed: the build doesn't.

    python3 Tools/modules/inlinable.py <build folder>      (Tools/build.sh and Tools/release.sh run it first)

A module's dependents are rebuilt when its interface changes, but an @inlinable body isn't part of it: after an edit
to one (a helper the frame's loops inline from the core, say), the modules above keep the copy they inlined before,
until something else rebuilds them. So this hashes each module's @inlinable declarations (their text, attribute to
closing brace) into <build folder>/inlinable/<Module>, and when a module's hash differs from the last build's, removes
the build's intermediates of every module that depends on it (Package.swift's dependencies, followed), so the build
compiles them again (touching their sources wouldn't do: the build compares contents). The first run in a build
folder only records. (Nothing else crosses a module inlined: the modules build with -disable-cmo, Package.swift.)
"""
import hashlib
import os
import re
import shutil
import sys

repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def targets():
    """Module -> (folder, its dependencies), from Package.swift."""
    text = open(os.path.join(repo, "Package.swift")).read()
    out = {}
    starts = list(re.finditer(r'\.(?:target|executableTarget|testTarget)\(\s*name:\s*"(\w+)"', text))
    for k, m in enumerate(starts):
        name, body = m.group(1), text[m.end():starts[k + 1].start() if k + 1 < len(starts) else len(text)]
        deps = re.search(r'dependencies:\s*\[([^\]]*)\]', body)
        path = re.search(r'path:\s*"([^"]+)"', body)
        out[name] = (path.group(1) if path else f"Sources/{name}", re.findall(r'"(\w+)"', deps.group(1)) if deps else [])
    return out


def inlinable_text(folder):
    """Every @inlinable declaration in the folder's Swift files, through its closing brace."""
    h = hashlib.sha256()
    for root, _, names in sorted(os.walk(os.path.join(repo, folder))):
        for n in sorted(names):
            if not n.endswith(".swift"):
                continue
            lines = open(os.path.join(root, n)).read().split("\n")
            i = 0
            while i < len(lines):
                if "@inlinable" in lines[i].split("//")[0]:
                    depth, j, opened = 0, i, False
                    while j < len(lines):
                        code = lines[j].split("//")[0]
                        depth += code.count("{") - code.count("}")
                        opened |= "{" in code
                        h.update(lines[j].encode())
                        j += 1
                        if opened and depth <= 0:
                            break
                    i = j
                else:
                    i += 1
    return h.hexdigest()


def products():
    """Product -> its targets (an executable's or the tests' intermediates are named after the product)."""
    text = open(os.path.join(repo, "Package.swift")).read()
    out = {m.group(1): re.findall(r'"(\w+)"', m.group(2))
           for m in re.finditer(r'\.executable\(name:\s*"(\w+)",\s*targets:\s*\[([^\]]*)\]', text)}
    return out


def intermediates(build, module):
    """The build's intermediates folders of `module` (each configuration's)."""
    names = {f"{module}-t.build", f"{module}-p.build"} | {f"{p}-p.build" for p, ts in products().items() if module in ts}
    out = []
    root = os.path.join(build, "out", "Intermediates.noindex")
    for project in (os.listdir(root) if os.path.isdir(root) else []):
        for config in (os.listdir(os.path.join(root, project)) if os.path.isdir(os.path.join(root, project)) else []):
            for n in names:
                path = os.path.join(root, project, config, n)
                if os.path.isdir(path):
                    out.append(path)
    return out


def main():
    build = sys.argv[1]
    store = os.path.join(build, "inlinable")
    os.makedirs(store, exist_ok=True)
    ts = targets()
    above = {m: set() for m in ts}           # module -> the modules that depend on it, directly or not
    for m, (_, deps) in ts.items():
        for d in deps:
            if d in above:
                above[d].add(m)
    changed = True
    while changed:
        changed = False
        for m in above:
            more = set().union(*(above[d] for d in above[m])) - above[m] if above[m] else set()
            if more:
                above[m] |= more
                changed = True
    touched = set()
    for m, (folder, _) in ts.items():
        if not os.path.isdir(os.path.join(repo, folder)):
            continue
        digest = inlinable_text(folder)
        path = os.path.join(store, m)
        before = open(path).read() if os.path.exists(path) else None
        if before is not None and before != digest:
            for d in above[m]:
                touched.add(d)
        open(path, "w").write(digest)
    for d in sorted(touched):
        for path in intermediates(build, d):
            shutil.rmtree(path)
        print(f"inlinable.py: an @inlinable body below {d} changed: it is compiled again", file=sys.stderr)


if __name__ == "__main__":
    main()
