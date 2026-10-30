import EngineCore
import Foundation
import simd

/// Reads a plant file: its program's members, each statement of its functions a stage's call with literal settings, or
/// kept as it is written. It never fails on what's inside a function: at worst, that's a statement node.
struct PlantSwiftParser {
    private let source: String
    private let bytes: [UInt8]
    private let tokens: [PlantToken]

    init(_ source: String) {
        self.source = source
        bytes = Array(source.utf8)
        tokens = PlantSwiftLexer.tokens(source)
    }

    private func text(_ a: Int, _ b: Int) -> String { String(decoding: bytes[a..<b], as: UTF8.self) }

    /// The token after `i` that isn't a comment or a newline.
    private func next(_ i: Int) -> Int {
        var j = i + 1
        while j < tokens.count, tokens[j].kind == .comment || tokens[j].kind == .newline { j += 1 }
        return j
    }

    private func isCode(_ i: Int) -> Bool { i < tokens.count && tokens[i].kind != .comment && tokens[i].kind != .newline }

    /// The token closing the bracket at `i`.
    private func closing(_ i: Int) -> Int? {
        var depth = 0
        var j = i
        while j < tokens.count {
            if tokens[j].kind == .punctuation {
                switch tokens[j].text {
                case "{", "(", "[": depth += 1
                case "}", ")", "]":
                    depth -= 1
                    if depth == 0 { return j }
                default: break
                }
            }
            j += 1
        }
        return nil
    }

    /// The start of the line the token is on, in the source.
    private func lineStart(_ offset: Int) -> Int {
        var a = offset
        while a > 0, bytes[a - 1] != 10 { a -= 1 }
        return a
    }

    private func lineEnd(_ offset: Int) -> Int {
        var b = offset
        while b < bytes.count, bytes[b] != 10 { b += 1 }
        return b
    }

    mutating func program(fallbackID: String) -> (Foliage.SpeciesInfo, PlantGraph)? {
        // The type: `enum|struct|class Name: ... PlantProgram ... {`.
        var i = 0
        var open = -1
        while i < tokens.count {
            if tokens[i].kind == .identifier, ["enum", "struct", "class"].contains(tokens[i].text) {
                var j = next(i)
                if j < tokens.count, tokens[j].kind == .identifier {
                    j = next(j)
                    if j < tokens.count, tokens[j].text == ":" {
                        var k = j, found = false
                        while k < tokens.count, tokens[k].text != "{" {
                            if tokens[k].text == "PlantProgram" { found = true }
                            k += 1
                        }
                        if found, k < tokens.count { open = k; break }
                    }
                }
            }
            i += 1
        }
        guard open >= 0, let close = closing(open) else { return nil }
        var graph = PlantGraph()
        var src = PlantGraph.Source()
        let declarationStart = lineStart(tokens[i].start)
        src.header = text(0, declarationStart)
        src.declaration = text(declarationStart, tokens[open].end)
        let afterClose = lineEnd(tokens[close].end)
        src.footer = afterClose + 1 <= bytes.count ? text(min(afterClose + 1, bytes.count), bytes.count) : ""

        var info = Foliage.SpeciesInfo(id: fallbackID)
        var twigBody: (Int, Int, [String])?, plantBody: (Int, Int, [String])?
        var palette: (settings: Foliage.Palette, doc: [String], notes: PlantNotes, at: SIMD2<Float>?)?
        var functions: [String: (text: String, doc: [String], at: SIMD2<Float>?)] = [:]

        // The members.
        var at = open + 1
        while at < close {
            var doc: [String] = []
            var position: SIMD2<Float>?
            while at < close, !isCode(at) {
                if tokens[at].kind == .comment {
                    if let p = PlantSwiftParser.position(tokens[at].text) { position = p } else { doc.append(tokens[at].text) }
                }
                at += 1
            }
            guard at < close else { break }
            // To its end: a body's closing brace, or the line's end outside brackets.
            let first = at
            var end = at
            var body: Int?
            var j = at
            var isFunc = false
            while j < close {
                let t = tokens[j]
                if t.kind == .newline {
                    // The member goes on if the next line's code is `{` or it's still open.
                    let n = next(j)
                    if n < close, tokens[n].text == "{" || tokens[n].text == "." { j = n; continue }
                    break
                }
                if t.kind == .identifier, t.text == "func" { isFunc = true }
                if t.kind == .punctuation, ["{", "(", "["].contains(t.text) {
                    guard let c = closing(j) else { break }
                    if t.text == "{" { body = j }
                    end = c
                    j = c + 1
                    if t.text == "{" { break }
                    continue
                }
                if t.kind != .comment { end = j }
                j += 1
            }
            at = end + 1
            let words = tokens[first...end].filter { $0.kind == .identifier }.map(\.text)
            let verbatim = text(lineStart(tokens[first].start), tokens[end].end)
            if isFunc, let f = words.firstIndex(of: "func"), f + 1 < words.count, let body {
                let name = words[f + 1]
                if name == "twig" { twigBody = (body, end, doc); continue }
                if name == "plant" { plantBody = (body, end, doc); continue }
                functions[name] = (text(tokens[first].start, tokens[end].end), doc, position)
                continue
            }
            if words.contains("let") || words.contains("var") {
                if let eq = (first...end).first(where: { tokens[$0].text == "=" }), let l = (first...end).first(where: { tokens[$0].text == "let" || tokens[$0].text == "var" }) {
                    let name = tokens[next(l)].text
                    if name == "species", let closure = closure(after: eq, upTo: end),
                       let id = speciesID(eq, end) {
                        var base = Foliage.SpeciesInfo(id: id)
                        base.name = id
                        if let tree = PlantTree(encoding: base), let made = apply(closure.lines, to: tree)?.decode(Foliage.SpeciesInfo.self) {
                            info = made
                            src.speciesDoc = doc
                            src.speciesNotes = closure.notes
                            continue
                        }
                    }
                    if name == "palette", let closure = closure(after: eq, upTo: end),
                       let tree = PlantTree(encoding: Foliage.Palette()), let made = apply(closure.lines, to: tree)?.decode(Foliage.Palette.self) {
                        palette = (made, doc, closure.notes, position)
                        src.paletteDoc = doc
                        src.paletteNotes = closure.notes
                        continue
                    }
                    if name == "code" { continue }     // (the code nodes' table: written anew)
                }
            }
            // Not the program's: kept, comments and all.
            let lead = doc.isEmpty ? "" : doc.map { "    " + $0 }.joined(separator: "\n") + "\n"
            src.extras.append(lead + verbatim)
        }
        guard let plantBody else { return nil }

        var names: [String: Int32] = [:]
        var usedFunctions = Set<String>()
        func add(_ settings: PlantNodeSettings, name: String, side: PlantSide, preset: PlantPreset, inputs: [Int32], doc: [String], at: SIMD2<Float>?, notes: PlantNotes) {
            let id = graph.nextID
            var node = PlantNode(id: id, name: name, side: side, preset: preset, settings: settings, inputs: inputs)
            node.doc = doc
            node.at = at
            node.notes = notes
            graph.nodes.append(node)
            if !name.isEmpty { names[name] = id }
        }

        /// One function's statements.
        func read(_ body: (Int, Int, [String]), side: PlantSide) -> String? {
            var returned: String?
            var i = body.0 + 1
            let close = body.1
            while i < close {
                var doc: [String] = []
                var position: SIMD2<Float>?
                while i < close, !isCode(i) {
                    if tokens[i].kind == .comment {
                        if let p = PlantSwiftParser.position(tokens[i].text) { position = p } else { doc.append(tokens[i].text) }
                    }
                    i += 1
                }
                guard i < close else { break }
                let start = i
                // To the end of the line, brackets balanced; a `{` on the next line goes on too.
                var j = i, end = i
                while j < close {
                    let t = tokens[j]
                    if t.kind == .newline {
                        let n = next(j)
                        if n < close, tokens[n].text == "{" || tokens[n].text == "." { j = n; continue }
                        break
                    }
                    if t.kind == .punctuation, ["{", "(", "["].contains(t.text), let c = closing(j) {
                        end = c
                        j = c + 1
                        continue
                    }
                    if t.kind != .comment { end = j }
                    if t.text == ";" { break }
                    j += 1
                }
                i = max(end + 1, j)
                // `return x`, `return p.stage(...)`, `p.stage(...)`, `let x = p.stage(...)`.
                if tokens[start].text == "return", next(start) <= end {
                    let n = next(start)
                    if n == end, tokens[n].kind == .identifier { returned = tokens[n].text; continue }
                    if let stage = stage(n, end, names: names, side: side) {
                        let name = graph.uniqueName(stage.settings.kind.name(side: side))
                        add(stage.settings, name: name, side: side, preset: stage.preset, inputs: stage.inputs, doc: doc, at: position, notes: stage.notes)
                        returned = name
                        continue
                    }
                }
                if tokens[start].text == "p", let stage = stage(start, end, names: names, side: side) {
                    // (A function of one expression returns it.)
                    let name = graph.uniqueName(stage.settings.kind.name(side: side))
                    add(stage.settings, name: name, side: side, preset: stage.preset, inputs: stage.inputs, doc: doc, at: position, notes: stage.notes)
                    returned = name
                    continue
                }
                if tokens[start].text == "let", next(start) < end, tokens[next(start)].kind == .identifier {
                    let name = tokens[next(start)].text
                    let eq = next(next(start))
                    if eq < end, tokens[eq].text == "=" {
                        if let stage = stage(next(eq), end, names: names, side: side) {
                            add(stage.settings, name: name, side: side, preset: stage.preset, inputs: stage.inputs, doc: doc, at: position, notes: stage.notes)
                            continue
                        }
                        // `let x = p.code(fn, input)`.
                        if let call = codeCall(next(eq), end, names: names), let f = functions[call.function] {
                            usedFunctions.insert(call.function)
                            add(.code(PlantCode(text: dedented(f.text))), name: name, side: side, preset: .standard, inputs: [call.input],
                                doc: f.doc, at: f.at ?? position, notes: PlantNotes())
                            continue
                        }
                    }
                }
                // Anything else: as it's written, wired from the names it mentions.
                let statement = text(tokens[start].start, tokens[end].end)
                var inputs: [Int32] = []
                for t in tokens[start...end] where t.kind == .identifier {
                    if let id = names[t.text], !inputs.contains(id) { inputs.append(id) }
                }
                var name = ""
                if tokens[start].text == "let" || tokens[start].text == "var", tokens[next(start)].kind == .identifier { name = tokens[next(start)].text }
                add(.statement(dedented(statement)), name: name, side: side, preset: .standard, inputs: inputs, doc: doc, at: position, notes: PlantNotes())
            }
            return returned
        }

        var twigResult: Int32?
        if let twigBody {
            src.twigDoc = twigBody.2
            if let r = read(twigBody, side: .twig) { twigResult = names[r] }
        }
        if let palette {
            let id = graph.nextID
            var node = PlantNode(id: id, name: graph.uniqueName("palette"), side: .twig, preset: .standard, settings: .palette(palette.settings),
                                 inputs: [twigResult ?? -1])
            node.at = palette.at
            node.notes = palette.notes
            graph.nodes.append(node)
            names["p.palette"] = id
        }
        src.plantDoc = plantBody.2
        _ = read(plantBody, side: .plant)
        // Functions no node calls are the file's own helpers.
        for (name, f) in functions.sorted(by: { $0.key < $1.key }) where !usedFunctions.contains(name) {
            let lead = f.doc.isEmpty ? "" : f.doc.map { "    " + $0 }.joined(separator: "\n") + "\n"
            src.extras.append(lead + "    " + f.text)
        }
        graph.source = src
        return (info, graph)
    }

    /// `// @node (x, y)`.
    private static func position(_ comment: String) -> SIMD2<Float>? {
        guard let m = comment.wholeMatch(of: #/\/\/\s*@node\s*\(\s*(-?[0-9.e+-]+)\s*,\s*(-?[0-9.e+-]+)\s*\)\s*/#),
              let x = Float(m.1), let y = Float(m.2) else { return nil }
        return SIMD2(x, y)
    }

    /// The text with the indent of its first line taken from each.
    private func dedented(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return text }
        let indents = lines.dropFirst().filter { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix { $0 == " " }.count }
        let cut = indents.min() ?? 0
        // (The closing brace's indent is the statement's own.)
        return lines.enumerated().map { $0.offset == 0 ? String($0.element) : String($0.element.dropFirst(min(cut, $0.element.count))) }.joined(separator: "\n")
    }

    private func speciesID(_ eq: Int, _ end: Int) -> String? {
        var j = eq
        while j < end {
            if tokens[j].text == "id", tokens[next(j)].text == ":" {
                let v = tokens[next(next(j))]
                if v.kind == .string { return String(v.text.dropFirst().dropLast()) }
            }
            j += 1
        }
        return nil
    }

    private struct Line {
        var path: [(key: String, optional: Bool)]
        var literal: PlantTree?      // nil: `nil`
    }

    private struct Closure {
        var lines: [Line] = []
        var notes = PlantNotes()
    }

    /// The trailing closure of the expression from `from` to `end`, if it's only `$0.x = literal` lines; or none at
    /// all, an empty one.
    private func closure(after from: Int, upTo end: Int) -> Closure? {
        var depth = 0
        var j = from
        while j <= end {
            let t = tokens[j]
            if t.kind == .punctuation {
                if t.text == "(" || t.text == "[" { depth += 1 } else if t.text == ")" || t.text == "]" { depth -= 1 }
                if t.text == "{" && depth == 0 { return lines(j, end) }
            }
            j += 1
        }
        return Closure()
    }

    /// A closure's lines, from its `{` at `open` to `close`.
    private func lines(_ open: Int, _ close: Int) -> Closure? {
        guard tokens[close].text == "}" else { return nil }
        var out = Closure()
        var pending: [String] = []
        var i = open + 1
        while i < close {
            let t = tokens[i]
            if t.kind == .newline || t.text == ";" { i += 1; continue }
            if t.kind == .comment { pending.append(t.text); i += 1; continue }
            guard t.text == "$0" else { return nil }
            i += 1
            var path: [(key: String, optional: Bool)] = []
            var pathText = ""
            var optional = false
            while i < close, tokens[i].text == "." || tokens[i].text == "?." {
                if !path.isEmpty, tokens[i].text == "?." { path[path.count - 1].optional = true }
                i += 1
                guard i < close, tokens[i].kind == .identifier else { return nil }
                path.append((tokens[i].text, false))
                pathText += (pathText.isEmpty ? "" : ".") + tokens[i].text
                i += 1
            }
            _ = optional
            optional = false
            guard !path.isEmpty, i < close, tokens[i].text == "=" else { return nil }
            i += 1
            // Its literal: to the line's end, or the closure's, or a `;`.
            var e = i, depth = 0
            while e < close {
                let k = tokens[e]
                if k.kind == .punctuation {
                    if ["(", "[", "{"].contains(k.text) { depth += 1 } else if [")", "]", "}"].contains(k.text) { depth -= 1 }
                }
                if depth == 0, k.kind == .newline || k.kind == .comment || k.text == ";" { break }
                e += 1
            }
            guard e > i else { return nil }
            let value = Array(tokens[i..<e]).filter { $0.kind != .newline && $0.kind != .comment }
            var cursor = 0
            guard let literal = literal(value, &cursor, field: path.last!.key), cursor == value.count else { return nil }
            out.lines.append(Line(path: path, literal: literal.isNil ? nil : literal.tree))
            if !pending.isEmpty { out.notes.above[pathText] = pending; pending = [] }
            if e < close, tokens[e].kind == .comment {
                out.notes.trailing[pathText] = tokens[e].text
                e += 1
            }
            i = e
        }
        return out
    }

    private func apply(_ lines: [Line], to tree: PlantTree) -> PlantTree? {
        var out = tree
        for line in lines {
            guard let next = out.setting(ArraySlice(line.path), to: line.literal) else { return nil }
            out = next
        }
        return out
    }

    private func literal(_ t: [PlantToken], _ i: inout Int, field: String) -> (tree: PlantTree, isNil: Bool)? {
        guard let first = scalar(t, &i, field: field) else { return nil }
        if i < t.count, t[i].text == "..." {
            i += 1
            guard let hi = scalar(t, &i, field: field) else { return nil }
            return (.array([first.tree, hi.tree]), false)
        }
        return first
    }

    private func scalar(_ t: [PlantToken], _ i: inout Int, field: String) -> (tree: PlantTree, isNil: Bool)? {
        guard i < t.count else { return nil }
        let token = t[i]
        i += 1
        switch token.kind {
        case .number:
            return PlantSwiftParser.number(token.text).map { (.number($0), false) }
        case .string:
            guard token.text.hasPrefix("\""), !token.text.hasPrefix("\"\"\""), !token.text.contains("\\("),
                  let data = token.text.data(using: .utf8), let s = try? JSONDecoder().decode(String.self, from: data) else { return nil }
            return (.string(s), false)
        case .identifier:
            switch token.text {
            case "true": return (.bool(true), false)
            case "false": return (.bool(false), false)
            case "nil": return (.null, true)
            default: return nil
            }
        case .punctuation:
            if token.text == "-" {
                guard i < t.count, t[i].kind == .number, let n = PlantSwiftParser.number(t[i].text) else { return nil }
                i += 1
                return (.number("-" + n), false)
            }
            if token.text == "[" {
                var items: [PlantTree] = []
                while i < t.count, t[i].text != "]" {
                    guard let v = literal(t, &i, field: field) else { return nil }
                    items.append(v.tree)
                    if i < t.count, t[i].text == "," { i += 1 }
                }
                guard i < t.count else { return nil }
                i += 1
                return (.array(items), false)
            }
            if token.text == ".", i < t.count, t[i].kind == .identifier {
                let name = t[i].text
                i += 1
                if i < t.count, t[i].text == "(" {
                    i += 1
                    var args: [PlantTree] = []
                    while i < t.count, t[i].text != ")" {
                        guard let v = literal(t, &i, field: field) else { return nil }
                        args.append(v.tree)
                        if i < t.count, t[i].text == "," { i += 1 }
                    }
                    guard i < t.count else { return nil }
                    i += 1
                    if name == "init" {
                        guard args.isEmpty, let fresh = PlantLiteral.fresh(field: field) else { return nil }
                        return (fresh, false)
                    }
                    return (.object([(name, args.count == 1 ? args[0] : .array(args))]), false)
                }
                return (.string(name), false)
            }
            return nil
        default:
            return nil
        }
    }

    /// A number's literal as JSON's.
    private static func number(_ text: String) -> String? {
        let plain = text.replacingOccurrences(of: "_", with: "")
        if plain.hasPrefix("0x") { return UInt64(plain.dropFirst(2), radix: 16).map(String.init) }
        return Double(plain) == nil ? nil : plain
    }

    private struct Stage {
        var settings: PlantNodeSettings
        var preset: PlantPreset
        var inputs: [Int32]
        var notes: PlantNotes
    }

    /// A stage's call, `p.stage(args) { ... }`, from `start` to `end`.
    private func stage(_ start: Int, _ end: Int, names: [String: Int32], side: PlantSide) -> Stage? {
        guard tokens[start].text == "p", next(start) <= end, tokens[next(start)].text == "." else { return nil }
        let kind = next(next(start))
        guard kind <= end, tokens[kind].kind == .identifier else { return nil }
        var args: [(label: String?, value: String)] = []
        var i = next(kind)
        if i <= end, tokens[i].text == "(" {
            guard let c = closing(i), c <= end else { return nil }
            var j = next(i)
            while j < c {
                var label: String?
                if tokens[j].kind == .identifier, next(j) < c, tokens[next(j)].text == ":" {
                    label = tokens[j].text
                    j = next(next(j))
                }
                var value = ""
                while j < c, tokens[j].text != "," {
                    if isCode(j) { value += tokens[j].text }
                    j += 1
                }
                args.append((label, value))
                if j < c { j = next(j) }
            }
            i = next(c)
        }
        var closure = Closure()
        if i <= end {
            guard tokens[i].text == "{", let c = closing(i), c == end, let made = lines(i, c) else { return nil }
            closure = made
        }
        var preset = PlantPreset.standard
        var wires: [(label: String?, id: Int32)] = []
        for a in args {
            if a.value == ".twig" { preset = .twig; continue }
            if a.value == ".standard" { continue }
            guard let id = names[a.value] else { return nil }
            wires.append((a.label, id))
        }
        func wire(_ label: String?) -> Int32 { wires.first { $0.label == label }?.id ?? -1 }
        func settings<T: Codable>(_ base: T) -> T? {
            guard let tree = PlantTree(encoding: base), let applied = apply(closure.lines, to: tree) else { return nil }
            return applied.decode(T.self)
        }
        switch tokens[kind].text {
        case "grow":
            guard wires.isEmpty, let s = settings(preset == .twig ? Growth.Twigs.twigGrowth : Growth.Params()) else { return nil }
            return Stage(settings: .grow(s.growOnly(preset)), preset: preset, inputs: [], notes: closure.notes)
        case "growMore":
            guard wires.count == 1, let s = settings(Growth.GrowMore()) else { return nil }
            return Stage(settings: .growMore(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "grafts":
            guard wires.count == 1, let s = settings(Growth.Grafts()) else { return nil }
            return Stage(settings: .grafts(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "spurs":
            guard wires.count == 1, let s = settings(Growth.Spurs()) else { return nil }
            return Stage(settings: .spurs(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "carve":
            guard wires.count == 1, let s = settings(Growth.Carve()) else { return nil }
            return Stage(settings: .carve(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "gravity":
            guard wires.count == 1, let s = settings(Growth.Gravity()) else { return nil }
            return Stage(settings: .gravity(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "manualEdit":
            guard wires.count == 1, let s = settings(Growth.ManualEdit()) else { return nil }
            return Stage(settings: .manualEdit(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "boneReduction":
            guard wires.count == 1, let s = settings(Growth.BoneReduction()) else { return nil }
            return Stage(settings: .boneReduction(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "skeleton":
            guard wires.count == 1, let s = settings(preset == .twig ? Growth.Twigs.twigGrowth.wood : Growth.Wood()) else { return nil }
            return Stage(settings: .skeleton(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "leaves":
            guard wires.count == 1, let s = settings(preset == .twig ? Growth.Twigs().leaf : Foliage.LeafRecipe()) else { return nil }
            return Stage(settings: .leaves(s), preset: preset, inputs: [wires[0].id], notes: closure.notes)
        case "twig":
            guard wires.count == 2, closure.lines.isEmpty else { return nil }
            return Stage(settings: .twig, preset: .standard, inputs: [wire(nil), wire("leaves")], notes: closure.notes)
        case "distribute":
            guard let s = settings(Growth.Twigs()) else { return nil }
            return Stage(settings: .distribute(s.placingOnly), preset: .standard, inputs: [wire(nil), wire("palette")], notes: closure.notes)
        case "output":
            guard let s = settings(Foliage.Assembly()) else { return nil }
            return Stage(settings: .output(s), preset: .standard, inputs: [wire(nil), wire("twigs"), wire("leaves")], notes: closure.notes)
        case "grass":
            guard wires.isEmpty, let s = settings(Foliage.GrassPatch()) else { return nil }
            return Stage(settings: .grass(s), preset: .standard, inputs: [], notes: closure.notes)
        default:
            return nil
        }
    }

    /// `p.code(function, input)`.
    private func codeCall(_ start: Int, _ end: Int, names: [String: Int32]) -> (function: String, input: Int32)? {
        let t = tokens[start...end].filter { $0.kind != .comment && $0.kind != .newline }.map(\.text)
        guard t.count == 8, t[0] == "p", t[1] == ".", t[2] == "code", t[3] == "(", t[5] == ",", t[7] == ")", let input = names[t[6]] else { return nil }
        return (t[4], input)
    }
}
