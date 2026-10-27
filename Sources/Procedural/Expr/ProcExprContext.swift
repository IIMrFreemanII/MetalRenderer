import EngineCore
import Foundation
import simd

/// What one cook's expressions share: the channels being evaluated (a loop through `ch` is an error) and the values
/// found.
package final class ProcExprState {
    var visiting: Set<String> = []
    var values: [String: Float] = [:]
    package init() {}
}

/// A node's expressions in one cook: what their names mean there. Channels are a parameter's name, plus x y z w for a
/// vector's components (`tx`, `sizey`); a path in `ch()` is a channel of this node (`sizex`), of another
/// (`../box1/sizex`), or the network's promoted parameter (`../seed`). Variables: `$F $FF $T $FPS $PI $E` and `$OS`
/// (the node's name, in text); the node's first input's `$NPT $NPR $NVTX $CEX… $XMIN… $SIZEX…`; per element `$PT $PR
/// $TX… $NX… $CR…` and `@attr`. The cooker gives the context its inputs and other nodes' outputs, cooked on demand.
package final class ProcExprContext {
    package let graph: ProcGraph
    package let node: ProcNode
    package let frame: Float
    let input: (Int) throws -> ProcGeo?
    let cook: (String) throws -> ProcGeo
    let other: (String) -> ProcExprContext?
    let state: ProcExprState

    /// `input`: this node's input `i` (nil if nothing is wired there); `cook`: a node's output, by id; `other`:
    /// another node's context, by id.
    package init(graph: ProcGraph, node: ProcNode, frame: Float, state: ProcExprState, input: @escaping (Int) throws -> ProcGeo?,
                 cook: @escaping (String) throws -> ProcGeo, other: @escaping (String) -> ProcExprContext?) {
        self.graph = graph
        self.node = node
        self.frame = frame
        self.state = state
        self.input = input
        self.cook = cook
        self.other = other
    }

    package static let fps: Float = 24

    // MARK: Channels

    /// A parameter's channels: its name, or its name and x y z (w) for a vector. None for text, points, ramps, code.
    package static func channels(of spec: ProcParamSpec) -> [String] {
        switch spec.value {
        case .float, .int, .bool: [spec.name]
        case .vec2: ["x", "y"].map { spec.name + $0 }
        case .vec3: ["x", "y", "z"].map { spec.name + $0 }
        case .vec4: ["x", "y", "z", "w"].map { spec.name + $0 }
        default: []
        }
    }

    /// The parameter a channel is of, and its component (nil: the parameter is a number). `r g b a` name a colour's.
    package static func locate(_ channel: String, in kind: ProcNodeKind) -> (spec: ProcParamSpec, component: Int?)? {
        if let s = kind.spec.param(channel), channels(of: s) == [channel] { return (s, nil) }
        guard let last = channel.last, let k = ProcExprParser.component(last) else { return nil }
        guard let s = kind.spec.param(String(channel.dropLast())) else { return nil }
        let n = channels(of: s).count
        return n > 1 && k < n ? (s, k) : nil
    }

    /// Channel `channel` of this node: its expression's value, else its value as set.
    package func value(ofChannel channel: String) throws -> Float {
        let key = "\(node.id)/\(channel)"
        if let v = state.values[key] { return v }
        guard let (spec, k) = ProcExprContext.locate(channel, in: node.kind) else {
            throw ProcExprError("\(node.name) has no channel \(channel)")
        }
        let v: Float
        if let source = node.expressions[channel] {
            guard !state.visiting.contains(key) else { throw ProcExprError("\(node.name)/\(channel) reads itself through ch()") }
            state.visiting.insert(key)
            defer { state.visiting.remove(key) }
            do {
                v = try evaluate(source)
            } catch let e as ProcExprError {
                throw ProcExprError(spec.perElement && (try? ProcExpr.parse(source).references.element) == true
                                    ? "\(node.name)/\(channel) varies per element: ch() can't read it" : e.message, column: e.column)
            }
        } else {
            let p = node.param(spec.name)
            v = k.map { p.vec4[$0] } ?? p.float
        }
        state.values[key] = v
        return v
    }

    /// The value of a `ch()` path.
    package func channel(_ path: String) throws -> Float {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: return try value(ofChannel: path)
        case 2 where parts[0] == ".": return try value(ofChannel: parts[1])
        case 2 where parts[0] == "..": return try promoted(parts[1])
        case 3 where parts[0] == "..":
            guard let n = graph.named(parts[1]) ?? graph.node(parts[1]), let c = other(n.id) else {
                throw ProcExprError("ch(\"\(path)\"): no node \(parts[1])")
            }
            return try c.value(ofChannel: parts[2])
        default:
            throw ProcExprError("ch(\"\(path)\"): a path is a channel (sizex), ../node/channel or ../parameter")
        }
    }

    /// A promoted parameter's value (`../seed`, `../sizex` of a vector one).
    private func promoted(_ name: String) throws -> Float {
        if let p = graph.interface.first(where: { $0.name == name }) {
            if case .string = p.value { throw ProcExprError("../\(name) is text") }
            return p.value.float
        }
        if let last = name.last, let k = ProcExprParser.component(last),
           let p = graph.interface.first(where: { $0.name == String(name.dropLast()) }) {
            return p.value.vec4[k]
        }
        throw ProcExprError("The network promotes no parameter \(name)")
    }

    /// A `chs()` path's text: a text parameter (expanded), or a promoted one.
    package func channelString(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "..", let p = graph.interface.first(where: { $0.name == parts[1] }) { return p.value.string }
        var ctx: ProcExprContext = self
        var name = path
        if parts.count == 2, parts[0] == "." { name = parts[1] }
        if parts.count == 3, parts[0] == ".." {
            guard let n = graph.named(parts[1]) ?? graph.node(parts[1]), let c = other(n.id) else {
                throw ProcExprError("chs(\"\(path)\"): no node \(parts[1])")
            }
            ctx = c
            name = parts[2]
        }
        if let spec = ctx.node.kind.spec.param(name), case .string(let s) = ctx.node.param(name) {
            return ProcExprContext.expands(spec) ? try ctx.expand(s) : s
        }
        return ProcExprContext.format(try ctx.channel(name))
    }

    /// The number at the end of a node's name (`copy3`: 3; `.`: this node).
    func opdigits(_ path: String) throws -> Float {
        var name = node.name
        if path != "." {
            let last = path.split(separator: "/").last.map(String.init) ?? path
            guard let n = graph.named(last) ?? graph.node(last) else { throw ProcExprError("opdigits(\"\(path)\"): no node \(last)") }
            name = n.name
        }
        return Float(String(name.reversed().prefix { $0.isNumber }.reversed())) ?? 0
    }

    // MARK: Variables and geometry

    func variable(_ v: String) throws -> Float {
        switch v {
        case "F": return frame.rounded()
        case "FF": return frame
        case "T": return (frame - 1) / ProcExprContext.fps
        case "FPS": return ProcExprContext.fps
        case "PI": return .pi
        case "E": return Float(M_E)
        case "OS": throw ProcExprError("$OS is the node's name: it goes in a text field")
        default: break
        }
        guard ProcExpr.nodeVariables.contains(v) else { throw ProcExprError("$\(v) means nothing here") }
        guard let g = try input(0) else { throw ProcExprError("$\(v) reads the first input, and nothing is wired there") }
        switch v {
        case "NPT": return Float(g.pointCount)
        case "NPR": return Float(g.primCount)
        case "NVTX": return Float(g.vertexCount)
        case "CEX": return ProcExprContext.bounds(g, "D_X", centroid: true)!
        case "CEY": return ProcExprContext.bounds(g, "D_Y", centroid: true)!
        case "CEZ": return ProcExprContext.bounds(g, "D_Z", centroid: true)!
        default: return ProcExprContext.bounds(g, "D_" + (v.hasPrefix("SIZE") ? String(v.last!) + "SIZE" : v), centroid: false)!
        }
    }

    func geometry(_ i: ProcExprInput) throws -> ProcGeo {
        switch i {
        case .index(let k):
            guard let g = try input(k) else { throw ProcExprError("Input \(k) (the \(k + 1)\(k == 0 ? "st" : k == 1 ? "nd" : "th") one) isn't connected") }
            return g
        case .path(let p):
            let name = p.split(separator: "/").last.map(String.init) ?? p
            guard p != ".", let n = graph.named(name) ?? graph.node(name), n.id != node.id else {
                throw ProcExprError("\"\(p)\" isn't another node of the network")
            }
            return try cook(n.id)
        }
    }

    /// `bbox()`'s and `centroid()`'s values (`D_XMIN`…, `D_XSIZE`…; `D_X`… for the centre). Nil: no such constant.
    static func bounds(_ g: ProcGeo, _ which: String, centroid: Bool) -> Float? {
        let b = g.bounds
        let lo = b.isEmpty ? SIMD3<Float>.zero : b.lo, hi = b.isEmpty ? SIMD3<Float>.zero : b.hi
        let axes: [Character: Int] = ["X": 0, "Y": 1, "Z": 2]
        guard which.hasPrefix("D_"), let a = which.dropFirst(2).first.flatMap({ axes[$0] }) else { return nil }
        switch which.dropFirst(3) {
        case "" where centroid: return (lo[a] + hi[a]) / 2
        case "MIN" where !centroid: return lo[a]
        case "MAX" where !centroid: return hi[a]
        case "SIZE" where !centroid: return hi[a] - lo[a]
        default: return nil
        }
    }

    /// A component of an attribute of class `cls`, row by row (P for points).
    static func column(_ g: ProcGeo, _ cls: AttributeClass, _ name: String, _ k: Int) throws -> [Float] {
        guard k >= 0 && k < 4 else { throw ProcExprError("A component is 0 to 3") }
        if name == "P" && cls == .point { return g.P.map { $0[min(k, 2)] } }
        guard let values = g.table(cls)[name] else { throw ProcExprError("No \(cls.rawValue) attribute \(name)") }
        return try components(values, k, name)
    }

    private static func components(_ values: AttributeValues, _ k: Int, _ name: String) throws -> [Float] {
        switch values {
        case .float(let a): return k == 0 ? a : [Float](repeating: 0, count: a.count)
        case .int(let a): return k == 0 ? a.map { Float($0) } : [Float](repeating: 0, count: a.count)
        case .vector2(let a): return a.map { k < 2 ? $0[k] : 0 }
        case .vector3(let a): return a.map { k < 3 ? $0[k] : 0 }
        case .vector4(let a): return a.map { $0[k] }
        case .string: throw ProcExprError("@\(name) is text")
        }
    }

    /// What `@name` reads per element of class `cls`: the class's attribute (a vertex's point's if the vertices don't
    /// have it), P (a primitive's: its centre), the numbers; or a detail attribute, as one value.
    static func elementColumn(_ g: ProcGeo, _ cls: AttributeClass, _ name: String, _ k: Int) throws -> [Float] {
        switch (name, cls) {
        case ("ptnum", .vertex): return g.vertexPoint.map { Float($0) }
        case ("primnum", .vertex):
            var out = [Float](repeating: 0, count: g.vertexCount)
            for p in 0..<g.primCount { for v in g.vertexRange(p) { out[v] = Float(p) } }
            return out
        case ("P", .vertex): return g.vertexPoint.map { g.P[Int($0)][min(k, 2)] }
        case ("P", .primitive): return (0..<g.primCount).map { g.primCenter($0)[min(k, 2)] }
        case ("ptnum", _), ("primnum", _), ("vtxnum", _): throw ProcExprError("@\(name) means nothing for \(cls.rawValue) elements")
        default: break
        }
        if name == "P" && cls == .point || g.table(cls)[name] != nil { return try column(g, cls, name, k) }
        if cls == .vertex, name == "P" || g.points[name] != nil {
            let points = try column(g, .point, name, k)
            return g.vertexPoint.map { points[Int($0)] }
        }
        if let d = g.detail[name] { return [try components(d, k, name).first ?? 0] }
        throw ProcExprError("No \(cls.rawValue) attribute \(name)")
    }

    // MARK: Evaluating

    /// An expression's value here, with no elements.
    package func evaluate(_ source: String) throws -> Float {
        let program = try ProcExprCompiler.compile(try ProcExpr.parse(source), self, elements: nil)
        return program.constant ?? program.run()[0]
    }

    /// An expression's value per element of `elements`.
    package func evaluate(_ source: String, over elements: ProcExprElements) throws -> [Float] {
        try ProcExprCompiler.compile(try ProcExpr.parse(source), self, elements: elements).run()
    }

    /// Whether a text parameter's value is expanded (`backticks`, `$OS`, `$F`); code never is.
    package static func expands(_ spec: ProcParamSpec) -> Bool {
        switch spec.ui {
        case .text, .group, .attribute, .file: true
        default: false
        }
    }

    /// Text with its `` `expressions` `` and `$VARIABLES` put in, as Houdini's text fields do (`piece$F`,
    /// `` `chs("../name")` ``). An unknown variable stays as it is.
    package func expand(_ text: String) throws -> String {
        guard text.contains("`") || text.contains("$") else { return text }
        var out = ""
        let c = Array(text)
        var i = 0
        while i < c.count {
            if c[i] == "`" {
                guard let end = c[(i + 1)...].firstIndex(of: "`") else { throw ProcExprError("A ` isn't closed", column: i) }
                out += try expandExpression(String(c[(i + 1)..<end]))
                i = end + 1
            } else if c[i] == "$", i + 1 < c.count, c[i + 1].isLetter {
                var j = i + 1
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                let v = String(c[(i + 1)..<j])
                if v == "OS" { out += node.name } else if let x = try? variable(v) { out += ProcExprContext.format(x) } else { out += String(c[i..<j]) }
                i = j
            } else {
                out.append(c[i])
                i += 1
            }
        }
        return out
    }

    /// A backtick's text: a string, `$OS`, `chs(…)`, or a number.
    private func expandExpression(_ source: String) throws -> String {
        let e = try ProcExpr.parse(source)
        switch e {
        case .string(let s): return s
        case .variable("OS"): return node.name
        case .call("chs", let args):
            guard args.count == 1, case .string(let p) = args[0] else { throw ProcExprError("chs() takes a path in quotes") }
            return try channelString(p)
        default: return ProcExprContext.format(try evaluate(source))
        }
    }

    /// A number in text: whole numbers without a point.
    package static func format(_ v: Float) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%g", v)
    }

    // MARK: A node's parameters

    /// What the cook reads for `spec`: its channels' expressions evaluated (those that vary per element left as set,
    /// for `elementValues`), its text expanded. Nil: nothing to evaluate, the value as set stands.
    package func resolved(_ spec: ProcParamSpec) throws -> ProcParam? {
        let set = node.param(spec.name)
        if ProcExprContext.expands(spec), case .string(let s) = set, s.contains("`") || s.contains("$") {
            return .string(try expand(s))
        }
        let names = ProcExprContext.channels(of: spec)
        guard names.contains(where: { node.expressions[$0] != nil }) else { return nil }
        var v = set.vec4
        for (k, name) in names.enumerated() where node.expressions[name] != nil {
            if spec.perElement, try varies(name) { continue }
            v[k] = try value(ofChannel: name)
        }
        switch set {
        case .float: return .float(v.x)
        case .int: return .int(Int(v.x.rounded()))
        case .bool: return .bool(v.x != 0)
        case .vec2: return .vec2(SIMD2(v.x, v.y))
        case .vec3: return .vec3(SIMD3(v.x, v.y, v.z))
        default: return .vec4(v)
        }
    }

    /// Does channel `name`'s expression vary per element?
    package func varies(_ name: String) throws -> Bool {
        guard let source = node.expressions[name] else { return false }
        return try ProcExpr.parse(source).references.element
    }

    /// A per-element parameter's value for each element of `elements` (nil: none of its channels varies, the
    /// parameter's value stands for all).
    package func elementValues(_ spec: ProcParamSpec, over elements: ProcExprElements) throws -> [SIMD4<Float>]? {
        let names = ProcExprContext.channels(of: spec)
        guard try names.contains(where: { try varies($0) }) else { return nil }
        let base = (try resolved(spec) ?? node.param(spec.name)).vec4
        var out = [SIMD4<Float>](repeating: base, count: elements.count)
        for (k, name) in names.enumerated() where try varies(name) {
            let values = try evaluate(node.expressions[name]!, over: elements)
            for i in 0..<out.count { out[i][k] = values[i] }
        }
        return out
    }
}
