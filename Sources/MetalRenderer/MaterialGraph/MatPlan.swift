import Foundation
import simd

/// A graph as the engine bakes it (MatEngine): its subgraphs inlined, its exposed parameters set, its nodes in an
/// order that has every input before its node, each with what it is resolved to: its inputs' sources, its outputs'
/// types, its size and precision, its parameters packed for its kernel (a float4 a parameter, in its spec's order;
/// curves and gradients as 256-entry tables), and a hash of all that and its inputs' hashes (a node whose hash didn't
/// change needn't be baked again: undo finds its image too).
struct MatPlan {
    /// Where an input comes from: a step's output, of a type.
    struct Source: Equatable {
        var step: Int
        var output: Int
        var type: MatType
    }

    struct Step {
        /// The node's id in the flattened graph (a subgraph's nodes: "<subgraph node>/<its id>").
        let id: String
        let node: MatNode
        /// Per spec input (nil: unwired).
        let inputs: [Source?]
        /// Per spec output.
        let outputs: [MatType]
        /// log2 of its width and height.
        let size: Int
        let bits: MatBits
        let params: [SIMD4<Float>]
        let luts: [[SIMD4<Float>]]
        let seed: UInt32
        let hash: UInt64

        var kind: MatOpKind { node.kind }
        var pixels: Int { 1 << size }
    }

    let steps: [Step]
    let index: [String: Int]
    /// The output nodes the renderer's channels come from.
    let channels: [MatChannel: Int]
    let size: Int
    let surface: MatSurface
    let name: String

    /// The plan of `graph`, its subgraphs found by name in `library`.
    init(_ graph: MaterialGraph, library: (String) -> MaterialGraph? = { MaterialCatalog.launch.graph($0) }) throws {
        let flat = try MatPlan.flatten(graph, library: library)
        size = min(max(graph.size, 4), 12)
        surface = graph.surface
        name = graph.name
        let order = try MatPlan.order(flat)
        var steps: [Step] = []
        var index: [String: Int] = [:]
        for n in order {
            let spec = n.kind.spec
            // Inputs, in the spec's order.
            let sources: [Source?] = spec.inputs.map { pin in
                guard let l = flat.link(into: n.id, pin.name), let k = index[l.from] else { return nil }
                let from = steps[k]
                guard let o = from.node.kind.spec.outputs.firstIndex(where: { $0.name == l.output }) else { return nil }
                return Source(step: k, output: o, type: from.outputs[o])
            }
            let outputs = spec.outputs.map { MatPlan.type(of: $0.type, n, sources) }
            // Size: the first wired input's, else the graph's; then the node's own.
            let base = sources.compactMap { $0 }.first.map { steps[$0.step].size } ?? size
            let s: Int
            switch n.size {
            case .inherit: s = base
            case .relative(let d): s = base + d
            case .absolute(let a): s = a
            }
            let bits = n.bits != .inherit ? n.bits : graph.bits != .inherit ? graph.bits : (outputs.contains(.color) ? .b8 : .b16)
            var luts: [[SIMD4<Float>]] = []
            let params = MatPlan.pack(n, luts: &luts)
            let seed = MatPlan.seed(graph.seed, n.int("seed"))
            var h = Hasher64()
            h.add(n.kind.rawValue)
            for p in params { h.add(p) }
            for t in luts { for v in t { h.add(v) } }
            for p in spec.params where p.value.isText { h.add(n.text(p.name)) }
            if let f = n.function, let code = try? f.code() { h.add(code.metal) }
            h.add(UInt64(min(max(s, 4), 12)))
            h.add(bits.rawValue)
            for o in outputs { h.add(o.rawValue) }
            for (i, src) in sources.enumerated() {
                h.add(UInt64(i))
                if let src { h.add(steps[src.step].hash); h.add(UInt64(src.output)); h.add(src.type.rawValue) } else { h.add("-") }
            }
            h.add(UInt64(seed))
            index[n.id] = steps.count
            steps.append(Step(id: n.id, node: n, inputs: sources, outputs: outputs, size: min(max(s, 4), 12), bits: bits, params: params,
                              luts: luts, seed: seed, hash: h.value))
        }
        self.steps = steps
        self.index = index
        var channels: [MatChannel: Int] = [:]
        for (c, id) in flat.channels { if let k = index[id] { channels[c] = k } }
        self.channels = channels
    }

    // MARK: - Types

    /// What output type `pin` is: its spec's, or for `any`: the node's own choice (an input's type, an output's
    /// channel, a pixel processor's mode), else colour if any `any` input gets colour, else the spec's default.
    static func type(of pin: MatPinType, _ n: MatNode, _ sources: [Source?]) -> MatType {
        switch pin {
        case .grey: return .grey
        case .color: return .color
        case .any:
            switch n.kind {
            case .input: return n.choice("type") == "color" ? .color : .grey
            case .output:
                if let c = MatChannel(rawValue: n.choice("usage")) { return c.type }
            case .pixelProcessor, .code: return n.choice("mode") == "grey" ? .grey : .color
            default: break
            }
            let spec = n.kind.spec
            var wired = false
            for (i, pinSpec) in spec.inputs.enumerated() where pinSpec.type == .any {
                guard let s = sources[i] else { continue }
                wired = true
                if s.type == .color { return .color }
            }
            return wired ? .grey : spec.anyDefault
        }
    }

    // MARK: - Subgraphs

    /// `graph` with its subgraph nodes replaced by their graphs' nodes (ids prefixed with the node's), wired to what
    /// was wired to the subgraph node, and every exposed parameter set from its input. A subgraph's input node takes
    /// what is wired into its pin (then it is a pass-through), its output nodes are pass-throughs.
    static func flatten(_ graph: MaterialGraph, library: (String) -> MaterialGraph?) throws -> MaterialGraph {
        var out = MaterialGraph(graph.name, size: graph.size)
        out.surface = graph.surface
        out.seed = graph.seed
        out.bits = graph.bits
        try inline(graph, prefix: "", values: [:], stack: [graph.name], top: true, into: &out, library: library)
        return out
    }

    /// The pins a subgraph node has: its graph's input nodes (by name) and output nodes.
    static func pins(of graph: MaterialGraph) -> (inputs: [MatInputSpec], outputs: [(name: String, type: MatPinType)]) {
        let inputs = graph.nodes.filter { $0.kind == .input }.map {
            MatInputSpec($0.text("name"), $0.text("name"), $0.choice("type") == "color" ? .color : .grey, optional: true)
        }
        let outputs = graph.nodes.filter { $0.kind == .output }.map { n -> (name: String, type: MatPinType) in
            let t: MatPinType = MatChannel(rawValue: n.choice("usage")).map { $0.type == .color ? .color : .grey } ?? .any
            return (n.text("name"), t)
        }
        return (inputs, outputs)
    }

    private static func inline(_ g: MaterialGraph, prefix: String, values: [String: MatParam], stack: [String], top: Bool,
                               into out: inout MaterialGraph, library: (String) -> MaterialGraph?) throws {
        // Per subgraph node: its pins' nodes in the flattened graph.
        var inputsOf: [String: [String: String]] = [:]    // node → pin → its input node's flattened id
        var outputsOf: [String: [String: String]] = [:]   // node → pin → its output node's flattened id
        for var n in g.nodes {
            for (param, input) in n.exposed {
                if let v = values[input] ?? g.inputs.first(where: { $0.name == input })?.value { n.params[param] = v }
            }
            let id = prefix + n.id
            if n.kind == .subgraph {
                let name = n.text("graph")
                guard let sub = library(name) else { throw MatError("\(n.id): no graph named \"\(name)\"") }
                guard !stack.contains(name) else { throw MatError("\(n.id): \"\(name)\" is inside itself") }
                var subValues: [String: MatParam] = [:]
                for i in sub.inputs { subValues[i.name] = n.params[i.name] ?? i.value }
                try inline(sub, prefix: id + "/", values: subValues, stack: stack + [name], top: false, into: &out, library: library)
                inputsOf[n.id] = Dictionary(sub.nodes.filter { $0.kind == .input }.map { ($0.text("name"), id + "/" + $0.id) }, uniquingKeysWith: { a, _ in a })
                outputsOf[n.id] = Dictionary(sub.nodes.filter { $0.kind == .output }.map { ($0.text("name"), id + "/" + $0.id) }, uniquingKeysWith: { a, _ in a })
                continue
            }
            if !top, n.kind == .output { n.params["usage"] = .choice("none") }
            n.id = id
            out.nodes.append(n)
        }
        for l in g.links {
            var from = prefix + l.from, output = l.output
            if let outs = outputsOf[l.from] {
                guard let o = outs[l.output] else { continue }
                from = o
                output = "out"
            }
            if let ins = inputsOf[l.to] {
                // The subgraph's input node becomes a pass-through of what is wired into its pin.
                guard let target = ins[l.input], let k = out.index(target) else { continue }
                var pass = MatNode(.output, ["usage": .choice("none"), "name": .text(l.input)], id: target, at: out.nodes[k].at)
                pass.bits = out.nodes[k].bits
                pass.size = out.nodes[k].size
                out.nodes[k] = pass
                out.links.append(MatLink(from, output, to: target, "in"))
            } else {
                out.links.append(MatLink(from, output, to: prefix + l.to, l.input))
            }
        }
    }

    /// The nodes in an order that has every node after those wired into it; a loop is an error.
    static func order(_ g: MaterialGraph) throws -> [MatNode] {
        var into: [String: [String]] = [:]
        for l in g.links { into[l.to, default: []].append(l.from) }
        var state: [String: Int] = [:]   // 1 visiting, 2 done
        var out: [MatNode] = []
        let byID = Dictionary(g.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func visit(_ id: String) throws {
            if state[id] == 2 { return }
            if state[id] == 1 { throw MatError("a loop through \(id)") }
            guard let n = byID[id] else { return }
            state[id] = 1
            for f in into[id] ?? [] { try visit(f) }
            state[id] = 2
            out.append(n)
        }
        for n in g.nodes { try visit(n.id) }
        return out
    }

    // MARK: - Parameters

    static let lutSize = 256

    /// A node's parameters for its kernel: a float4 each, in its spec's order (a choice: its index; a curve or a
    /// gradient: its table's index in `luts`; text: 0).
    static func pack(_ n: MatNode, luts: inout [[SIMD4<Float>]]) -> [SIMD4<Float>] {
        n.kind.spec.params.map { p in
            let v = n.param(p.name)
            switch v {
            case .float(let f): return SIMD4(f, 0, 0, 0)
            case .int(let i): return SIMD4(Float(i), 0, 0, 0)
            case .bool(let b): return SIMD4(b ? 1 : 0, 0, 0, 0)
            case .vec2(let x): return SIMD4(x.x, x.y, 0, 0)
            case .color(let c): return c
            case .choice(let s): return SIMD4(Float(max(p.choices.firstIndex(of: s) ?? 0, 0)), 0, 0, 0)
            case .curve(let c):
                luts.append((0..<lutSize).map { i in let y = c.value(Float(i) / Float(lutSize - 1)); return SIMD4(y, y, y, 1) })
                return SIMD4(Float(luts.count - 1), 0, 0, 0)
            case .gradient(let g):
                luts.append((0..<lutSize).map { i in g.value(Float(i) / Float(lutSize - 1)) })
                return SIMD4(Float(luts.count - 1), 0, 0, 0)
            case .text: return .zero
            }
        }
    }

    /// A node's seed: the graph's and its own, mixed.
    static func seed(_ graph: Int, _ node: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: graph) &* 0x9e37_79b9 ^ UInt32(truncatingIfNeeded: node) &* 0x85eb_ca6b
        h ^= h >> 16; h = h &* 0x7feb_352d; h ^= h >> 15
        return h
    }
}

extension MatParam {
    var isText: Bool { if case .text = self { return true }; return false }
}

/// FNV-1a over what is added: a plan step's hash.
struct Hasher64 {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037
    mutating func add(_ bytes: UnsafeRawBufferPointer) { for b in bytes { value = (value ^ UInt64(b)) &* 1_099_511_628_211 } }
    mutating func add(_ v: UInt64) { withUnsafeBytes(of: v) { add($0) } }
    mutating func add(_ v: SIMD4<Float>) { withUnsafeBytes(of: v) { add($0) } }
    mutating func add(_ s: String) {
        add(UInt64(s.utf8.count))
        for b in s.utf8 { value = (value ^ UInt64(b)) &* 1_099_511_628_211 }
    }
}

extension MaterialGraph {
    /// The pins node `id` has: its kind's, or for a subgraph node its graph's.
    func pins(_ n: MatNode, library: (String) -> MaterialGraph?) -> (inputs: [MatInputSpec], outputs: [(name: String, type: MatPinType)]) {
        if n.kind == .subgraph {
            guard let g = library(n.text("graph")) else { return ([], []) }
            return MatPlan.pins(of: g)
        }
        return (n.kind.spec.inputs, n.kind.spec.outputs)
    }

    /// Whether `from`'s output can be wired into `to`'s input: both are pins, and `to` isn't upstream of `from`.
    func canLink(_ from: String, _ output: String, to: String, _ input: String, library: (String) -> MaterialGraph?) -> Bool {
        guard from != to, let a = node(from), let b = node(to) else { return false }
        guard pins(a, library: library).outputs.contains(where: { $0.name == output }),
              pins(b, library: library).inputs.contains(where: { $0.name == input }) else { return false }
        return !upstream(of: from).contains(to)
    }
}
