#!/usr/bin/env python3
"""Marks `package` every member without an access level of the lower modules' types that a module above names.

    python3 Tools/modules/markmembers.py <folder above> <lower module's folder> […]

For the SwiftUI views of the editors: a member they can't see breaks a view's type inference, and the compiler's
error then names something else (a timeout, a Binding it can't convert), so marking the members one error at a time
(pkgfix.py) gets stuck. Members of the types the folder above names, and of the extensions of those types, become
`package`: no difference to the code (with -enable-testing internal declarations are exported anyway). Private ones,
enum cases, protocol requirements and declarations inside functions are left alone.
"""
import os
import re
import sys

TYPE = re.compile(r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:package|public|internal|private|fileprivate|final|indirect)\s+)*"
                  r"(struct|class|enum|protocol|extension|actor)\s+([\w.]+)")
MEMBER = re.compile(r"^(\s*)((?:@[\w.]+(?:\([^)]*\))?\s+)*)((?:(?:static|final|mutating|nonmutating|override|lazy|weak|unowned|"
                    r"convenience|required|nonisolated|class|dynamic|indirect)\s+)*)(func|var|let|init|subscript|typealias|struct|class|enum)\b")
ACCESS = re.compile(r"\b(private|fileprivate|internal|package|public|open)\b")


def swift_files(folder):
    for root, _, names in os.walk(folder):
        for n in names:
            if n.endswith(".swift"):
                yield os.path.join(root, n)


def main():
    above, lower = sys.argv[1], sys.argv[2:]
    named = set()
    for p in swift_files(above):
        named |= set(re.findall(r"\b([A-Z]\w*)\b", open(p).read()))
    changed = 0
    for folder in lower:
        for p in swift_files(folder):
            lines = open(p).read().split("\n")
            stack, depth, dirty = [], 0, False   # (depth inside the type's braces, its name, is a protocol)
            for i, l in enumerate(lines):
                code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', l.split("//")[0])
                while stack and depth < stack[-1][0]:
                    stack.pop()
                t = TYPE.match(code)
                m = MEMBER.match(code)
                if m and stack and depth == stack[-1][0] and not stack[-1][2] and stack[-1][1].split(".")[-1] in named:
                    head = l[:m.start(4)]
                    if not ACCESS.search(head) and not re.search(r"\bprivate\(set\)", head):
                        pos = m.start(3)
                        lines[i] = l[:pos] + "package " + l[pos:]
                        dirty = True
                        changed += 1
                if t and "{" in code:
                    stack.append((depth + code[:code.index("{")].count("{") + 1, t.group(2), t.group(1) == "protocol"))
                depth += code.count("{") - code.count("}")
            if dirty:
                open(p, "w").write("\n".join(lines))
    print(f"marked {changed} members")


if __name__ == "__main__":
    main()
