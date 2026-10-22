#!/usr/bin/env python3
"""Marks declarations of the lower modules `package` from a build log's access errors, and makes the initializers
the modules above them call. Prints what it did and what it couldn't.

    python3 Tools/modules/pkgfix.py <repo> <build log> <lower module's folder> […]

Only files in the folders given are changed (the modules whose declarations the build above them can't see). Run by
Tools/modules/loop.sh, which builds, runs this, and builds again until the build passes. Written for moving the engine
into modules: an `internal` declaration a module above uses becomes `package`; an implicit memberwise or default
initializer (internal even on a package type) gets an explicit `package init` in the type's body, the same.
"""
import os, re, sys, collections

repo = sys.argv[1]
log = re.sub(r'\x1b\[[0-9;]*m', '', open(sys.argv[2]).read())
lower = [os.path.join(repo, d) for d in sys.argv[3:]]
modules = sorted({os.path.basename(d.rstrip('/')) for d in lower}
                 | {n for n in os.listdir(os.path.join(repo, 'Sources'))})

DECL = re.compile(r'^(\s*)((?:@[\w.]+(?:\([^)]*\))?\s+)*)((?:(?:private\(set\)|fileprivate\(set\)|package|public|internal|static|final|mutating|nonmutating|override|indirect|lazy|weak|unowned|convenience|required|nonisolated|dynamic|optional|class)\s+)*)(struct|class|enum|protocol|typealias|actor|func|let|var|init|subscript|case|extension)\b')
ACCESS = re.compile(r'\b(private|fileprivate|internal|package|public|open)\b')

files = {}
def lines(p):
    if p not in files: files[p] = open(p).read().split('\n')
    return files[p]

# Index of engine declarations by name: (path, line index, depth)
index = collections.defaultdict(list)
def walk():
    for d in lower:
        yield from os.walk(d)
for root, _, fs in walk():
    for f in fs:
        if not f.endswith('.swift'): continue
        p = os.path.join(root, f)
        depth = 0
        for i, l in enumerate(lines(p)):
            m = re.match(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:static|final|mutating|override|indirect|lazy|private|fileprivate|package|public|weak|unowned)\s+)*(?:struct|class|enum|protocol|typealias|actor|func|let|var)\s+`?([A-Za-z_]\w*)', l)
            if m: index[m.group(1)].append((p, i, depth))
            depth += l.count('{') - l.count('}')

# Declarations by (enclosing type, name): the type is the nearest struct/class/enum/protocol/extension around it.
members = collections.defaultdict(list)
for root, _, fs in walk():
    for f in fs:
        if not f.endswith('.swift'): continue
        p = os.path.join(root, f)
        depth = 0; stack = []
        for i, l in enumerate(lines(p)):
            code = l.split('//')[0]
            while stack and depth <= stack[-1][0]: stack.pop()
            t = re.match(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:package|public|internal|private|fileprivate|final|indirect)\s+)*(struct|class|enum|protocol|extension|actor)\s+([\w.]+)', code)
            m = re.match(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:private\(set\)|fileprivate\(set\)|static|final|mutating|override|indirect|lazy|private|fileprivate|package|public|internal|convenience|required|nonisolated|weak|unowned|class)\s+)*(?:func|let|var|init|subscript|case|typealias|struct|class|enum|protocol)\s*`?([A-Za-z_]\w*)?', code)
            if m and stack and depth == stack[-1][0] + 1:
                name = m.group(1) or ('subscript' if re.search(r'\bsubscript\b', code) else 'init')
                if re.match(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:package|public|internal|convenience|required|override|private|fileprivate)\s+)*init\b', code): name = 'init'
                members[(stack[-1][1].split('.')[-1], name)].append((p, i))
                if re.search(r'\b(let|var)\b', code) and ',' in code:
                    for extra in re.findall(r',\s*`?([A-Za-z_]\w*)`?\s*(?::|=)', code):
                        members[(stack[-1][1].split('.')[-1], extra)].append((p, i))
            # several names on one line: let a = 1, b = 2
            if t: stack.append((depth, t.group(2)))
            depth += code.count('{') - code.count('}')

changed = set()
def mark(p, i, why):
    L = lines(p)
    l = L[i]
    if not any(p.startswith(d.rstrip('/') + '/') for d in lower): return f'not a lower module\'s file {p}:{i+1}'
    m = DECL.match(l)
    if not m:
        return f'no decl at {p}:{i+1}: {l.strip()[:80]}'
    head = l[:m.start(4)]
    if ACCESS.search(head):
        if re.search(r'\b(private|fileprivate)\b(?!\(set\))', head): return f'private at {p}:{i+1}: {l.strip()[:80]}'
        if 'package' in head or 'public' in head: return None
    kw = m.group(4)
    if kw in ('case',): return f'enum case at {p}:{i+1}'
    if kw == 'extension':
        return f'extension at {p}:{i+1}'
    # insert after attributes, before the modifiers
    pos = m.start(3)
    L[i] = l[:pos] + 'package ' + l[pos:]
    changed.add((p, i))
    return None


def split_top(text, sep=','):
    out, depth, cur, q = [], 0, '', False
    for ch in text:
        if ch == '"': q = not q
        if not q:
            if ch in '([<{': depth += 1
            elif ch in ')]>}': depth -= 1
            elif ch == sep and depth == 0:
                out.append(cur); cur = ''; continue
        cur += ch
    out.append(cur)
    return out

def infer(default):
    d = default.strip()
    if re.fullmatch(r'-?[\d_]+', d): return 'Int'
    if re.fullmatch(r'-?[\d_]+\.[\d_]+(e-?\d+)?', d): return 'Double'
    if d in ('true', 'false'): return 'Bool'
    if d.startswith('"'): return 'String'
    if re.search(r'\s(!=|==|<=|>=|&&|\|\|)\s', d): return 'Bool'
    if '??' in d: return None
    # Type(...), Type.Inner(...), Type<T>(...), Type.member, Type.member(...): the leading capitalised names
    m = re.match(r'^([A-Z]\w*(?:\.[A-Z]\w*)*(?:<[^>]*>)?)(\(|\.[a-z]\w*)', d)
    if m: return m.group(1)
    return None

def find_type(name):
    if '.' in name:
        parts = name.split('.')
        return [(p_, i_, 1) for p_, i_ in members.get((parts[-2], parts[-1]), []) if re.search(r'\b(struct|class)\s+' + parts[-1] + r'\b', lines(p_)[i_])]
    return [c for c in by_name(name, ['struct', 'class']) if not re.search(r'\b(private|fileprivate)\b', lines(c[0])[c[1]])]

def gen_init(name):
    cands = find_type(name)
    if len(cands) > 1: cands = [c for c in cands if re.search(r'\bpackage\b', lines(c[0])[c[1]])] or cands
    if len(cands) != 1: return f'init for {name}: {len(cands)} candidates'
    p, i, _ = cands[0]
    L = lines(p)
    if 'class ' in L[i] and 'struct ' not in L[i]:
        kind = 'class'
    else:
        kind = 'struct'
    depth = 0; props = []; end = None; problems = []; explicit = []
    for j in range(i, len(L)):
        l = L[j]
        code = l.split('//')[0]
        if depth == 1 and j > i and re.match(r'^\s*(?:@[\w.]+\s+)*(?:(?:package|public|internal|convenience|required|override)\s+)*init[?!]?\s*\(', code):
            if 'init(from decoder' not in code and 'init(rawValue' not in code: explicit.append(j)
        if depth == 1 and j > i:
            m = re.match(r'^\s*(?:@[\w.]+\s+)*((?:(?:package|public|internal|private\(set\)|fileprivate\(set\)|package\(set\))\s+)*)(var|let)\s+(.*)$', code)
            if m and 'static' not in code.split(m.group(2))[0] and 'lazy' not in code:
                rest = m.group(3).rstrip()
                if re.search(r'\{\s*$', rest) or re.search(r'\{\s*(get|set|didSet|willSet)', rest) or re.search(r'^\w+\s*:[^=]*\{', rest):
                    pass   # computed or observed
                else:
                    for part in split_top(rest):
                        part = part.strip()
                        if not part: continue
                        mm = re.match(r'^`?(\w+)`?\s*(?::\s*([^=]+?))?\s*(?:=\s*(.+))?$', part)
                        if not mm: problems.append(f'{p}:{j+1}: {part}'); continue
                        pname, ptype, pdef = mm.group(1), mm.group(2), mm.group(3)
                        if pdef is not None and (pdef.count('(') != pdef.count(')') or pdef.count('[') != pdef.count(']') or pdef.count('{') != pdef.count('}')):
                            problems.append(f'{p}:{j+1}: multi-line default of {pname}'); continue
                        if m.group(2) == 'let' and pdef is not None: continue
                        if ptype is None:
                            ptype = infer(pdef or '')
                            if ptype is None: problems.append(f'{p}:{j+1}: type of {pname} = {pdef}'); continue
                        if pdef is None and m.group(2) == 'var' and re.search(r'(\?|Optional<.*>)\s*$', ptype.strip()):
                            pdef = 'nil'   # an optional var's memberwise parameter defaults to nil
                        props.append((pname, ptype.strip(), pdef))
        depth += code.count('{') - code.count('}')
        if depth == 0 and j > i:
            end = j; break
        if depth == 0 and '{' in code and j == i:
            pass
    if end is None: return f'init for {name}: no end'
    if explicit:   # no memberwise one: its own initializers, made the package's
        for j in explicit: mark(p, j, 'init')
        if not re.search(r'\b(package|public)\b', L[i].split(kind)[0]): mark(p, i, 'init')
        return None
    if problems: return f'init for {name}: ' + '; '.join(problems)
    indent = re.match(r'^(\s*)', L[i]).group(1) + '    '
    esc = lambda t: ('@escaping ' + t) if re.match(r'^\(.*\)\s*(throws\s*)?->', t) and not t.rstrip().endswith('?') else t
    params = ', '.join(f'{n}: {esc(t)}' + (f' = {d}' if d is not None else '') for n, t, d in props)
    body = [f'{indent}/// (As the memberwise initializer, for the modules above this one.)', f'{indent}package init({params}) {{'] + \
           [f'{indent}    self.{n} = {n}' for n, _, _ in props] + [f'{indent}}}']
    if kind == 'class' and props: return f'init for class {name}: has stored properties'
    L[end:end] = [''] + body
    changed.add((p, end))
    if not re.search(r'\b(package|public)\b', L[i].split(kind)[0]): mark(p, i, 'init')
    return None

unresolved = []
inits_done = set()
def by_name(name, kinds=None):
    c = index.get(name, [])
    if kinds: c = [x for x in c if re.search(r'\b(' + '|'.join(kinds) + r')\s+`?' + re.escape(name) + r'\b', lines(x[0])[x[1]])]
    return c

msgs = log.split('\n')
unmarked = 0
for l in msgs:
    m = re.match(r"^error: (/\S+?):(\d+):\d+ attribute 'package' can only be used in a non-local scope", l)
    if m:
        p, i = m.group(1), int(m.group(2)) - 1
        L = lines(p)
        if 'package ' in L[i]:
            L[i] = L[i].replace('package ', '', 1); changed.add((p, i)); unmarked += 1

for k, l in enumerate(msgs):
    m = re.match(r'^(/\S+?):(\d+):(\d+): error: (.*)$', l)
    if not m: continue
    path, line, col, text = m.group(1), int(m.group(2)) - 1, int(m.group(3)) - 1, m.group(4)
    if 'initializer is inaccessible' in text:
        text = re.sub(r"<[\w, .]+>", "", text)   # PipelineCache<Value>.Key: the type's own name
    if re.search(r"extra arguments? |missing arguments? for parameter|argument passed to call that takes no arguments|no exact matches in call to initializer|incorrect argument label|missing argument label|does not conform to expected type .Decoder.", text):
        src = lines(path)[line]
        calls = [(mm.start(), mm.group(1)) for mm in re.finditer(r'([A-Za-z_][\w.]*)\s*\(', src) if mm.start() <= col + 1]
        if not calls: unresolved.append(f'{path}:{line+1}: {text}'); continue
        name = calls[-1][1].split('.')[-1]
        if name == 'init': unresolved.append(f'{path}:{line+1}: {text} (.init)'); continue
        full = calls[-1][1]
        if re.match(r'^[A-Z]\w*(\.[A-Z]\w*)+$', full): name = full   # Outer.Inner(...)
        if name and name[0].isupper():
            ext = [h for h in members.get((name.split('.')[-1], 'init'), []) if 'init(from decoder' not in lines(h[0])[h[1]] and 'init(rawValue' not in lines(h[0])[h[1]]]
            for h in ext:
                if 'package' not in lines(h[0])[h[1]]: mark(h[0], h[1], text)
            if not any('package' in lines(h[0])[h[1]] for h in ext): inits_done.add(name)
        else:
            c = [x for x in by_name(name) if x[2] == 0]
            if not c: c = [(p_, i_, 1) for (t_, n_), hs in members.items() if n_ == name for (p_, i_) in hs]
            for x in c: mark(x[0], x[1], text)
            if not c: unresolved.append(f'{path}:{line+1}: {text} ({name})')
        continue
    # notes on the lines after: 'x' declared here
    notes = []
    for n in msgs[k + 1:k + 60]:
        nm = re.match(r'^(/\S+?):(\d+):\d+: note: (.*)$', n)
        if nm: notes.append((nm.group(1), int(nm.group(2)) - 1, nm.group(3)))
        elif re.match(r'^/\S+?:\d+:\d+: (error|warning)', n): break
    tnote = [n for n in notes if 'type declared here' in n[2]]
    if 'internal type' in text and tnote:
        for n in tnote:
            r = mark(n[0], n[1], text)
            if r: unresolved.append(r + '  <- ' + text)
        continue
    mreq = re.match(r"(?:method|property|initializer|subscript|type alias|associated type|getter|setter|instance method|static method|static property|class method) '([\w]+)(?:\([^)]*\))?' must be declared (?:package|public) because it matches a requirement", text)
    if mreq:
        name = mreq.group(1)
        L = lines(path)
        # the type's own declarations of it, in this file below the type's line, then anywhere in the engine
        hit = None
        for j in range(line, len(L)):
            if re.search(r'\b(func|var|let|init|typealias)\s+`?' + re.escape(name) + r'\b', L[j]): hit = (path, j); break
        if hit is None:
            c = by_name(name)
            if len(c) == 1: hit = (c[0][0], c[0][1])
        if hit:
            r = mark(hit[0], hit[1], text)
            if r: unresolved.append(r + '  <- ' + text)
        else:
            unresolved.append(f'{path}:{line+1}: {text}')
        continue
    ms = re.match(r"static member '(\w+)' cannot be used on instance of type '([\w.]+)'", text)
    if ms:
        # the instance member of that name is internal, so the name found the static one: mark the instance one
        hs = [h for h in members.get((ms.group(2).split('.')[-1], ms.group(1)), []) if 'static' not in lines(h[0])[h[1]]]
        for h in hs:
            r = mark(h[0], h[1], text)
            if r: unresolved.append(r + '  <- ' + text)
        if not hs: unresolved.append(f'{path}:{line+1}: {text}')
        continue
    if "'package' modifier cannot be used in protocols" in text:
        L = lines(path)
        L[line] = L[line].replace('package ', '', 1); changed.add((path, line))
        for j in range(line, -1, -1):
            if re.match(r'^\s*(?:\w+\s+)*protocol\s', L[j]):
                mark(path, j, text); break
        continue
    if "initializer 'init(rawValue:)' must be as accessible" in text:
        L = lines(path)
        j = next((j for j in range(line, min(line + 6, len(L))) if re.search(r'\blet rawValue: (\w+)', L[j])), None)
        if j is not None and not any('init(rawValue' in L[x] for x in range(line, min(line + 8, len(L)))):
            t = re.search(r'\blet rawValue: (\w+)', L[j]).group(1)
            ind = re.match(r'^(\s*)', L[j]).group(1)
            L.insert(j + 1, f'{ind}package init(rawValue: {t}) {{ self.rawValue = rawValue }}')
            changed.add((path, j))
        continue
    if 'must be as accessible as its enclosing type' in text or re.search(r'must be declared (package|public) because', text):
        r = mark(path, line, text)
        if r: unresolved.append(r + '  <- ' + text)
        continue
    mi = re.match(r"'([\w.]+)' initializer is inaccessible due to 'internal' protection level", text)
    if mi and not [n for n in notes if 'declared here' in n[2]]:
        name = mi.group(1)
        inits_done.add(name)
        continue
    if 'inaccessible due to \'internal\' protection level' in text or "is internal and cannot be referenced" in text \
            or "initializer is inaccessible" in text:
        decl = [n for n in notes if 'declared here' in n[2]]
        qn = None
        for n in msgs[k + 1:k + 60]:
            qm = re.match(r'^(?:' + '|'.join(modules) + r')\.([\w.]+?)(?:\(.*\))?:\d+:\d+: note: .*declared here', n)
            if qm: qn = qm.group(1); break
            if re.match(r'^/\S+?:\d+:\d+: error', n): break
        if not decl and qn:
            parts = qn.split('.')
            if len(parts) == 1:
                c = [x for x in by_name(parts[0]) if x[2] == 0]
                hits = [(c[0][0], c[0][1])] if len(c) == 1 else []
            else:
                hits = members.get((parts[-2], parts[-1]), [])
                alias = {'simd_float4x4': 'float4x4', 'simd_float3x3': 'float3x3', 'simd_quatf': 'simd_quatf'}
                if not hits and parts[-2] in alias: hits = members.get((alias[parts[-2]], parts[-1]), [])
                if parts[-1] != 'init' and len(hits) > 1:
                    hits = hits[:1] if len(set(h[0] for h in hits)) == 1 and False else hits
            if hits:
                for h in hits:
                    r = mark(h[0], h[1], text)
                    if r and 'enum case' not in r: unresolved.append(r + '  <- ' + text)
            else:
                unresolved.append(f'{qn}: not found  <- {text}')
            continue
        if decl:
            r = mark(decl[0][0], decl[0][1], text)
            if r: unresolved.append(r + '  <- ' + text)
        else:
            unresolved.append(f'{path}:{line+1}: {text}')
        continue
    m2 = re.match(r"cannot find (?:type )?'(\w+)' in scope", text)
    if m2:
        name = m2.group(1)
        cands = by_name(name, ['struct', 'class', 'enum', 'protocol', 'typealias', 'actor']) if 'type' in text else by_name(name)
        top = [c for c in cands if c[2] == 0]
        cands = top or cands
        if len(cands) == 1 or (top and all(re.search(r'\bfunc\b', lines(c[0])[c[1]]) for c in cands)):
            for c in cands:
                r = mark(c[0], c[1], text)
                if r: unresolved.append(r + '  <- ' + text)
        else:
            unresolved.append(f'{path}:{line+1}: {text}  ({len(cands)} candidates)')
        continue
    m3 = re.search(r"cannot be declared (?:package|public) because its (?:\w+ )*(?:type|parameter|result)(?: '([\w.]+)')? uses an? (?:internal|fileprivate|private) type", text) \
        or re.search(r"(?:uses|use) an? internal type", text)
    if m3:
        name = m3.group(1) if m3.lastindex else None
        targets = []
        if name and '.' in name:
            parts = name.split('.')
            hs = members.get((parts[-2], parts[-1]), [])
            for h in hs: mark(h[0], h[1], text)
            if hs: continue
            targets = [parts[-1]]
        elif name:
            targets = [name]
        else:
            # every capitalised name on the declaration line that is an internal engine type
            L_ = lines(path); src = ''
            for j in range(line, min(line + 6, len(L_))):
                src += L_[j]
                if '{' in L_[j]: break
            targets = [t for t in set(re.findall(r'\b([A-Z]\w*)\b', src))]
            # nested types named in the signature (Outer.Inner), and those nested in the declaring file's types
            for outer, inner in set(re.findall(r'\b([A-Z]\w*)\.([A-Z]\w*)\b', src)):
                for h in members.get((outer, inner), []): mark(h[0], h[1], text)
            for t in list(targets):
                for (o_, n_), hs in members.items():
                    if n_ == t:
                        for h in hs:
                            if h[0] == path: mark(h[0], h[1], text)
        hit = False
        for t in targets:
            cands = by_name(t, ['struct', 'class', 'enum', 'protocol', 'typealias', 'actor'])
            top = [c for c in cands if c[2] == 0] or cands
            if len(top) == 1:
                r = mark(top[0][0], top[0][1], text)
                if r and 'no decl' not in r: unresolved.append(r + '  <- ' + text)
                hit = True
        if not hit: unresolved.append(f'{path}:{line+1}: {text}')
        continue
    unresolved.append(f'{path}:{line+1}: {text}')

# The initializers last, from the bottom of each file up: they add lines.
pending = []
for name in inits_done:
    c = find_type(name)
    pending.append((c[0][0], c[0][1], name) if c else (None, 0, name))
for p_, i_, name in sorted(pending, key=lambda x: (x[0] or '', -x[1])):
    r = gen_init(name)
    if r: unresolved.append(r)

for p in {p for p, _ in changed}:
    open(p, 'w').write('\n'.join(files[p]))
print(f'marked {len(changed)} declarations in {len({p for p, _ in changed})} files')
seen = set()
for u in unresolved:
    if u in seen: continue
    seen.add(u)
    print('  ?', u)
