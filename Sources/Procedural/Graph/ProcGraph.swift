import Foundation
import simd

/// A node of a network: its kind, its name (`box1`, unique in the network, what a promoted parameter and the editor
/// call it), the parameters set away from the spec's defaults, where the network view draws it, and Houdini's flags:
/// display (the node the viewport shows; one per network), render (what an asset outputs when it has no Output
/// node), bypass (passes its first input through) and template (shown greyed beside the display node).
package struct ProcNode: Codable, Equatable, Identifiable {
    package var id: String
    package var name: String
    package var kind: ProcNodeKind
    package var params: [String: ProcParam] = [:]
    /// Expressions by channel (`tx`, `seed`: ProcExprContext.swift), hscript's: a channel with one is cooked from it;
    /// its value in `params` stays for when it is removed.
    package var expressions: [String: String] = [:]
    /// Keyframed channels (ProcCurve.swift): a channel with one is cooked from its value at the frame. A channel has an
    /// expression or a curve, not both.
    package var curves: [String: ProcCurve] = [:]
    package var at = SIMD2<Float>.zero
    package var display = false
    package var render = false
    package var bypass = false
    package var template = false
    package var comment = ""

    package init(_ kind: ProcNodeKind, id: String, name: String? = nil, params: [String: ProcParam] = [:], at: SIMD2<Float> = .zero) {
        self.kind = kind
        self.id = id
        self.name = name ?? id
        self.params = params
        self.at = at
    }

    /// A parameter's value: what is set, else the spec's default.
    package func param(_ name: String) -> ProcParam {
        params[name] ?? kind.spec.param(name)?.value ?? .float(0)
    }

    /// Is channel `c` cooked from something other than its value as set (an expression, keys)?
    package func isDriven(_ c: String) -> Bool { expressions[c] != nil || curves[c] != nil }

    private enum Key: String, CodingKey { case id, name, kind, params, expressions, curves, at, display, render, bypass, template, comment }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decode(ProcNodeKind.self, forKey: .kind)
        params = try c.decodeIfPresent([String: ProcParam].self, forKey: .params) ?? [:]
        expressions = try c.decodeIfPresent([String: String].self, forKey: .expressions) ?? [:]
        curves = try c.decodeIfPresent([String: ProcCurve].self, forKey: .curves) ?? [:]
        at = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .at) ?? .zero
        display = try c.decodeIfPresent(Bool.self, forKey: .display) ?? false
        render = try c.decodeIfPresent(Bool.self, forKey: .render) ?? false
        bypass = try c.decodeIfPresent(Bool.self, forKey: .bypass) ?? false
        template = try c.decodeIfPresent(Bool.self, forKey: .template) ?? false
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        if name != id { try c.encode(name, forKey: .name) }
        try c.encode(kind, forKey: .kind)
        if !params.isEmpty { try c.encode(params, forKey: .params) }
        if !expressions.isEmpty { try c.encode(expressions, forKey: .expressions) }
        if !curves.isEmpty { try c.encode(curves, forKey: .curves) }
        try c.encode(at, forKey: .at)
        if display { try c.encode(true, forKey: .display) }
        if render { try c.encode(true, forKey: .render) }
        if bypass { try c.encode(true, forKey: .bypass) }
        if template { try c.encode(true, forKey: .template) }
        if !comment.isEmpty { try c.encode(comment, forKey: .comment) }
    }
}

/// A wire: node `from`'s output into input `input` of node `to` (for a multi-input node such as Merge, the order of
/// its wires).
package struct ProcLink: Codable, Equatable, Hashable {
    package var from: String
    package var to: String
    package var input: Int

    package init(_ from: String, to: String, _ input: Int = 0) {
        self.from = from
        self.to = to
        self.input = input
    }
}

/// A parameter an asset shows: its name and title, its default and slider span, and the node parameters it sets.
package struct PromotedParam: Codable, Equatable, Identifiable {
    package struct Target: Codable, Equatable, Hashable {
        package var node: String
        package var param: String
        package init(node: String, param: String) { self.node = node; self.param = param }
    }

    package var name: String
    package var title: String
    package var value: ProcParam
    package var span: ClosedRange<Float>?
    package var targets: [Target]
    package var id: String { name }

    package init(_ name: String, title: String? = nil, value: ProcParam, span: ClosedRange<Float>? = nil, targets: [Target]) {
        self.name = name
        self.title = title ?? name
        self.value = value
        self.span = span
        self.targets = targets
    }
}

/// A network of nodes, as Houdini's SOP networks: nodes, the wires between them, and the parameters it promotes when
/// it is an asset.
package struct ProcGraph: Codable, Equatable {
    package var nodes: [ProcNode] = []
    package var links: [ProcLink] = []
    package var interface: [PromotedParam] = []
    /// The frames the network plays (the timeline's range), and a placed asset of it.
    package var frames: ClosedRange<Int> = ProcGraph.defaultFrames

    package static let defaultFrames = 1...240

    package init() {}

    private enum Key: String, CodingKey { case nodes, links, interface, frames }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        nodes = try c.decodeIfPresent([ProcNode].self, forKey: .nodes) ?? []
        links = try c.decodeIfPresent([ProcLink].self, forKey: .links) ?? []
        interface = try c.decodeIfPresent([PromotedParam].self, forKey: .interface) ?? []
        frames = try c.decodeIfPresent(ClosedRange<Int>.self, forKey: .frames) ?? ProcGraph.defaultFrames
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(links, forKey: .links)
        try c.encode(interface, forKey: .interface)
        if frames != ProcGraph.defaultFrames { try c.encode(frames, forKey: .frames) }
    }

    package func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }
    package func node(_ id: String) -> ProcNode? { index(of: id).map { nodes[$0] } }
    package func named(_ name: String) -> ProcNode? { nodes.first { $0.name == name } }

    /// The node the viewport shows: the one with the display flag, else the last one made.
    package var displayNode: String? { nodes.first { $0.display }?.id ?? nodes.last?.id }

    /// What an asset outputs: its Output node, else the node with the render flag, else the display node.
    package var outputNode: String? {
        nodes.first { $0.kind == .output }?.id ?? nodes.first { $0.render }?.id ?? displayNode
    }

    /// The nodes wired into `id`, by input: a multi-input node's in their wires' order with no gaps, another's with
    /// nil where an input is free.
    package func inputs(of id: String) -> [String?] {
        guard let n = node(id) else { return [] }
        let wires = links.filter { $0.to == id }.sorted { $0.input < $1.input }
        if n.kind.spec.multiInput { return wires.map { $0.from } }
        var out = [String?](repeating: nil, count: n.kind.spec.inputs.count)
        for w in wires where w.input < out.count { out[w.input] = w.from }
        return out
    }

    /// The nodes `id` feeds.
    package func outputs(of id: String) -> [String] { links.filter { $0.from == id }.map(\.to) }

    /// Every node above `id` (that it depends on), and itself.
    package func upstream(of id: String) -> Set<String> {
        var seen: Set<String> = [id]
        var stack = [id]
        while let n = stack.popLast() {
            for l in links where l.to == n && !seen.contains(l.from) {
                seen.insert(l.from)
                stack.append(l.from)
            }
        }
        return seen
    }

    // MARK: Edits

    /// A name for a new node of `base` (`box` → `box1`, `box2`, …) that no node has.
    package func uniqueName(_ base: String) -> String {
        let names = Set(nodes.map(\.name))
        var i = 1
        while names.contains("\(base)\(i)") { i += 1 }
        return "\(base)\(i)"
    }

    package func uniqueID() -> String {
        let ids = Set(nodes.map(\.id))
        var i = nodes.count + 1
        while ids.contains("n\(i)") { i += 1 }
        return "n\(i)"
    }

    /// Adds a node of `kind` at `at`, named for its kind; the first node gets the display flag. Its id.
    @discardableResult
    package mutating func add(_ kind: ProcNodeKind, at: SIMD2<Float> = .zero, params: [String: ProcParam] = [:], name: String? = nil) -> String {
        let id = uniqueID()
        var n = ProcNode(kind, id: id, name: name ?? uniqueName(kind.spec.baseName), params: params, at: at)
        if !nodes.contains(where: { $0.display }) { n.display = true }
        nodes.append(n)
        return id
    }

    /// Can `from` be wired into `to` (no cycle, both there)?
    package func canLink(_ from: String, to: String) -> Bool {
        from != to && node(from) != nil && node(to) != nil && !upstream(of: from).contains(to)
    }

    /// Wires `from` into input `input` of `to`, replacing what was wired there (a multi-input node: inserted at that
    /// place, the wires after it moved along). False if it would make a cycle.
    @discardableResult
    package mutating func link(_ from: String, to: String, _ input: Int = 0) -> Bool {
        guard canLink(from, to: to), let n = node(to) else { return false }
        if n.kind.spec.multiInput {
            let at = min(input, links.filter { $0.to == to }.count)
            for i in links.indices where links[i].to == to && links[i].input >= at { links[i].input += 1 }
            links.append(ProcLink(from, to: to, at))
            renumber(to)
        } else {
            guard input < n.kind.spec.inputs.count else { return false }
            links.removeAll { $0.to == to && $0.input == input }
            links.append(ProcLink(from, to: to, input))
        }
        return true
    }

    /// Takes the wire off input `input` of `to`.
    package mutating func unlink(to: String, _ input: Int) {
        links.removeAll { $0.to == to && $0.input == input }
        if node(to)?.kind.spec.multiInput == true { renumber(to) }
    }

    /// A multi-input node's wires numbered 0, 1, 2… in their order.
    private mutating func renumber(_ to: String) {
        let order = links.indices.filter { links[$0].to == to }.sorted { links[$0].input < links[$1].input }
        for (k, i) in order.enumerated() { links[i].input = k }
    }

    /// Removes nodes and their wires; a node that was wired through one (its first input to an output) is wired
    /// past it, as Houdini does when a node in a chain is deleted.
    package mutating func remove(_ ids: Set<String>) {
        var bridges: [ProcLink] = []
        for id in ids {
            guard let above = inputs(of: id).compactMap({ $0 }).first, !ids.contains(above) else { continue }
            for l in links where l.from == id && !ids.contains(l.to) { bridges.append(ProcLink(above, to: l.to, l.input)) }
        }
        let hadDisplay = nodes.contains { ids.contains($0.id) && $0.display }
        nodes.removeAll { ids.contains($0.id) }
        links.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        for b in bridges { link(b.from, to: b.to, b.input) }
        interface = interface.compactMap { p in
            var p = p
            p.targets.removeAll { ids.contains($0.node) }
            return p.targets.isEmpty ? nil : p
        }
        if hadDisplay, let last = bridges.first?.from ?? nodes.last?.id { setDisplay(last) }
    }

    /// Gives `id` the display flag (and takes it from the others).
    package mutating func setDisplay(_ id: String) {
        for i in nodes.indices { nodes[i].display = nodes[i].id == id }
    }

    package mutating func setRender(_ id: String) {
        for i in nodes.indices { nodes[i].render = nodes[i].id == id }
    }

    package mutating func setParam(_ node: String, _ name: String, _ value: ProcParam) {
        guard let i = index(of: node) else { return }
        nodes[i].params[name] = value
    }

    /// Renames a node (to a unique name): false if the name is taken or empty.
    @discardableResult
    package mutating func rename(_ id: String, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !nodes.contains(where: { $0.name == n && $0.id != id }), let i = index(of: id) else { return false }
        nodes[i].name = n
        return true
    }

    /// The network with an asset's parameter values set: each promoted parameter's value (`values[name]`, else its
    /// default) into the node parameters it targets.
    package func applying(_ values: [String: ProcParam]) -> ProcGraph {
        var g = self
        for (k, p) in interface.enumerated() {
            let v = values[p.name] ?? p.value
            // What `ch("../name")` reads.
            g.interface[k].value = v
            for t in p.targets {
                guard let i = g.nodes.firstIndex(where: { $0.name == t.node || $0.id == t.node }) else { continue }
                g.nodes[i].params[t.param] = v
                // The promoted value wins over the target's expressions and keys.
                if let spec = g.nodes[i].kind.spec.param(t.param) {
                    for c in ProcExprContext.channels(of: spec) { g.nodes[i].expressions[c] = nil; g.nodes[i].curves[c] = nil }
                }
            }
        }
        return g
    }
}
