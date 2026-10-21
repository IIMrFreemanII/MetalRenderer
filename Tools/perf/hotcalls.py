#!/usr/bin/env python3
"""Checks that the hot loops listed in hot-functions.txt stay in the fast subset of Swift, and that splitting the
engine into modules left them as they were.

    python3 Tools/perf/hotcalls.py [--binary .build/release/MetalRenderer] [-v]
    python3 Tools/perf/hotcalls.py --save-baseline main.json          # on main's build: what each function calls
    python3 Tools/perf/hotcalls.py --against main.json                # on the branch's: nothing new is called

Disassembles the release binary (otool -tV), finds every function of ours (defined in one of the package's modules)
whose demangled name contains one of the list's patterns, and fails if one of them:
  * calls into the runtime: reference counting (swift_retain / objc_retain …), heap allocation, exclusivity checks
    (swift_beginAccess), copy-on-write uniqueness checks, dynamic casts, Objective-C messages, generic metadata or
    witness tables, lazy globals (swift_once);
  * calls a metadata accessor, a protocol witness, a dispatch thunk or a global's addressor (a `static let` read from
    another module);
  * calls a function of another of the package's modules (with -disable-cmo nothing is inlined across a module: a
    helper, computed property or init that was inlined is a call there), unless cross-allow.txt allows it.
Calls are `bl`s, tail calls (a `b` out of the function) and indirect calls (`blr`, counted).

--save-baseline writes, per function of hot-functions.txt and boundary-functions.txt, what it calls, its indirect
calls and its size; --against fails when a function calls anything its baseline didn't (something is no longer
inlined) and cross-allow.txt doesn't allow, makes more indirect calls, or is gone, and warns when it grew by more
than 15%. Functions are matched by
their demangled names with the modules taken out, so a function that moved to another module is still itself.
boundary-functions.txt lists the loops that call across modules by design (they are only compared, not held clean).

Only each function's own body is read: a call it makes to another function of ours is listed with -v but not
followed, so list the callees that are hot too. A pattern that matches no function fails as well (a rename left the
list stale). Build release first: `Tools/release.sh`.
"""
import argparse
import collections
import glob
import json
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
    "swift_getGenericMetadata", "swift_getWitnessTable", "swift_getAssociated", "swift_once",
    "__swift_instantiateConcreteTypeFromMangledName",
)
# Callees (by demangled name) a hot loop must not call: what a call across modules turns an inlined access into.
FORBIDDEN_KINDS = ("type metadata accessor", "protocol witness for", "dispatch thunk of", "unsafeMutableAddressor",
                   "lazy protocol witness table")

HEADER = re.compile(r"^(_\S+):$")
LINE = re.compile(r"^([0-9a-f]+)\t(\S+)\t?(.*)$")
STUB = re.compile(r"symbol stub for: (_\S+)")
TARGET = re.compile(r"^(?:0x([0-9a-f]+))?\s*(?:; )?(?:symbol stub for: )?(_\S+)?")
SPECIALIZATION = re.compile(r"^((?:[a-z]+ )*(?:generic |function signature )?specialization <.*?> of )+")


class Function:
    __slots__ = ("name", "start", "end", "calls", "tails", "indirect")

    def __init__(self, name, start):
        self.name, self.start, self.end = name, start, start
        self.calls, self.tails, self.indirect = [], [], 0


def disassemble(binary):
    """The binary's functions in address order: name, range, `bl` targets, `b` targets and indirect calls."""
    out = subprocess.run(["xcrun", "otool", "-tV", binary], capture_output=True, text=True, check=True).stdout
    funcs, current, pending = [], None, None
    for line in out.splitlines():
        m = HEADER.match(line)
        if m:
            pending = m.group(1)
            continue
        m = LINE.match(line)
        if not m:
            continue
        address, op, rest = int(m.group(1), 16), m.group(2), m.group(3)
        if pending is not None:
            current = Function(pending, address)
            funcs.append(current)
            pending = None
        if current is None:
            continue
        current.end = address
        if op == "bl":
            current.calls.append(target(rest))
        elif op == "b":
            current.tails.append(target(rest))
        elif op == "blr":
            current.indirect += 1
    return funcs


def target(operand):
    """A branch's target: (address or None, symbol or None)."""
    stub = STUB.search(operand)
    if stub:
        return None, stub.group(1)
    m = TARGET.match(operand.strip())
    address = int(m.group(1), 16) if m and m.group(1) else None
    return address, (m.group(2) if m else None)


def demangle(names):
    if not names:
        return {}
    tool = subprocess.run(["xcrun", "--find", "swift-demangle"], capture_output=True, text=True, check=True).stdout.strip()
    res = subprocess.run([tool, "--simplified"], input="\n".join(names), capture_output=True, text=True, check=True).stdout
    return dict(zip(names, res.splitlines()))


def package_modules(repo):
    """The package's Swift targets (not the tests'), from Package.swift."""
    with open(os.path.join(repo, "Package.swift")) as f:
        text = f.read()
    return set(re.findall(r'\.(?:target|executableTarget)\(\s*name:\s*"([^"]+)"', text))


def mangled_module(symbol):
    """The module a Swift symbol's mangling names first ($s13MetalRenderer… → MetalRenderer), or None."""
    m = re.match(r"_?\$s(\d+)", symbol)
    if not m:
        return None
    n, at = int(m.group(1)), m.end()
    return symbol[at:at + n]


SHARED = "(shared)"


def defining_modules(binary, modules):
    """Symbol -> the module whose object file defines it (a module's .o next to the binary: SwiftPM's products), or
    SHARED for what several modules emit a copy of (specialisations of the standard library's generics, outlined
    copies and destroys: the linker keeps one, and calling it is no call across modules)."""
    owner = {}
    folder = os.path.dirname(os.path.realpath(binary))
    for path in glob.glob(os.path.join(folder, "*.o")):
        module = os.path.splitext(os.path.basename(path))[0]
        if module not in modules:
            continue
        res = subprocess.run(["nm", "-U", "-j", path], capture_output=True, text=True)
        for sym in res.stdout.split():
            owner[sym] = SHARED if owner.get(sym, module) != module else module
    return owner


def normalise(name, modules):
    """A demangled name without the package's module names: the same function wherever it lives."""
    for module in modules:
        name = name.replace(f"(extension in {module}):", "").replace(f"{module}.", "")
    return name


def callee_key(name):
    """A callee's name for comparing builds: a specialisation's arguments taken out (they differ between builds),
    but kept a specialisation (one that became a plain call is new)."""
    m = SPECIALIZATION.match(name)
    if m:
        return "specialised " + name[m.end():]
    return "specialised " + name[len("specialized "):] if name.startswith("specialized ") else name


def patterns(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for raw in f:
            line = raw.strip()   # (names have "#" in them: "closure #1 in …", so only whole lines are comments)
            if line and not line.startswith("#"):
                out.append(line)
    return out


def allowances(path):
    """cross-allow.txt: `caller pattern -> callee pattern  # why` lines."""
    out = []
    for line in patterns(path):
        line = line.split("  #")[0].strip()
        if "->" in line:
            caller, callee = (s.strip() for s in line.split("->", 1))
            out.append((caller, callee))
    return out


def main():
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    here = os.path.join(repo, "Tools/perf")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary", default=os.path.join(repo, ".build/release/MetalRenderer"))
    ap.add_argument("--list", default=os.path.join(here, "hot-functions.txt"))
    ap.add_argument("--boundary", default=os.path.join(here, "boundary-functions.txt"))
    ap.add_argument("--allow", default=os.path.join(here, "cross-allow.txt"))
    ap.add_argument("--save-baseline", metavar="JSON", help="write what each listed function calls")
    ap.add_argument("--against", metavar="JSON", help="fail on anything a listed function calls that its baseline didn't")
    ap.add_argument("-v", "--verbose", action="store_true", help="also list each function's other calls")
    args = ap.parse_args()
    if not os.path.exists(args.binary):
        sys.exit(f"hotcalls: {args.binary} not found; run Tools/release.sh")

    modules = package_modules(repo)
    funcs = disassemble(args.binary)
    by_address = {f.start: f for f in funcs}
    owner = defining_modules(args.binary, modules)

    def module_of(symbol):
        return owner.get(symbol) or mangled_module(symbol)

    def home_of(symbol):
        """The module a function is ours in: the one that defines it, the shared ones by their mangling's."""
        m = owner.get(symbol)
        return mangled_module(symbol) if m in (None, SHARED) else m

    ours = [f for f in funcs if home_of(f.name) in modules]
    callee_names = set()
    for f in ours:
        for address, sym in f.calls + f.tails:
            if sym is None and address in by_address:
                sym = by_address[address].name
            if sym and sym.startswith("_$s"):
                callee_names.add(sym)
    names = demangle(sorted({f.name[1:] for f in ours} | {s[1:] for s in callee_names}))

    def pretty(sym):
        return names.get(sym[1:], sym[1:]) if sym.startswith("_$s") else sym[1:] if sym.startswith("_") else sym

    def calls_of(f):
        """(symbol, how) for every call the function makes: bl's and tail calls out of its range."""
        out = []
        for address, sym in f.calls:
            if sym is None:
                sym = by_address[address].name if address in by_address else "?"
            out.append((sym, "call"))
        for address, sym in f.tails:
            if sym is None:
                if address is None or f.start <= address <= f.end or address not in by_address:
                    continue   # a branch inside the function
                sym = by_address[address].name
            out.append((sym, "tail"))
        return out

    allow = allowances(args.allow)
    failed = False
    record = {}
    hot, boundary = patterns(args.list), patterns(args.boundary)
    for listed, pattern in [(True, p) for p in hot] + [(False, p) for p in boundary]:
        matched = [f for f in ours if pattern in names.get(f.name[1:], "")]
        if not matched:
            print(f"STALE  {pattern}: no function matches")
            failed = True
            continue
        for f in matched:
            name = names[f.name[1:]]
            caller_module = home_of(f.name)
            calls = calls_of(f)
            problems = collections.Counter()
            for sym, how in calls:
                plain = sym[1:] if sym.startswith("_") else sym
                callee = pretty(sym)
                if plain.startswith(FORBIDDEN):
                    problems[plain] += 1
                elif any(k in callee for k in FORBIDDEN_KINDS):
                    problems[callee] += 1
                else:
                    other = module_of(sym)
                    if other in modules and other != caller_module and not any(
                            c in name and d in callee for c, d in allow):
                        problems[f"{callee}  [{other}, from {caller_module}]"] += 1
            key = normalise(name, modules)
            entry = record.setdefault(key, {"callees": [], "indirect": 0, "size": 0})
            entry["callees"] = sorted(set(entry["callees"]) | {callee_key(normalise(pretty(s), modules))
                                                               for s, _ in calls})
            entry["indirect"] += f.indirect
            entry["size"] = max(entry["size"], f.end - f.start + 4)
            # A closure's partial-apply forwarder runs once per call of the closure (per part of a loop, not per
            # element), and retains its context: only compared with the baseline.
            listed = listed and not name.startswith("partial apply for ")
            if listed:
                status = "FAIL " if problems else "ok   "
                print(f"{status} [{caller_module}] {name}")
                for what, count in sorted(problems.items()):
                    print(f"         {count}× {what}")
                failed |= bool(problems)
            elif args.verbose:
                print(f"bound  [{caller_module}] {name}")
            if args.verbose:
                other = collections.Counter(f"{pretty(s)} ({how})" for s, how in calls)
                for what, count in sorted(other.items()):
                    print(f"         ({count}× {what})")
                if f.indirect:
                    print(f"         ({f.indirect}× indirect)")

    if args.save_baseline:
        with open(args.save_baseline, "w") as out:
            json.dump(record, out, indent=1, sort_keys=True)
        print(f"baseline: {len(record)} functions written to {args.save_baseline}")
    if args.against:
        with open(args.against) as f:
            base = json.load(f)
        for key, was in sorted(base.items()):
            now = record.get(key)
            if now is None:
                print(f"GONE   {key}")
                failed = True
                continue
            # (cross-allow.txt may allow a callee; a function's call to its own specialisation is its thunk's)
            new = sorted(c for c in set(now["callees"]) - set(was["callees"])
                         if not any(a in key and b in c for a, b in allow) and c != "specialised " + key)
            if new or now["indirect"] > was["indirect"]:
                failed = True
                print(f"NEW    {key}")
                for callee in new:
                    print(f"         calls {callee}")
                if now["indirect"] > was["indirect"]:
                    print(f"         indirect calls {was['indirect']} → {now['indirect']}")
            elif now["size"] > was["size"] * 1.15:
                print(f"GREW   {key}: {was['size']} → {now['size']} bytes")
        print(f"against {args.against}: {len(base)} functions compared")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
