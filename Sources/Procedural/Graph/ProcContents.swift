import Foundation
import simd

/// Networks in a node, as Houdini's subnetworks and digital assets: a Subnetwork holds its network (`contents`), a
/// Procedural Asset node a library asset's (a copy of its definition, put in again from the library while it is
/// locked: `syncingDefinitions`; `editable`: its contents are its own until Match Current Definition). The contents'
/// interface is the node's parameters (their values the node's own, keyed or with expressions like any other's), and
/// its Sub-Network Input nodes are the node's inputs.
extension ProcNodeKind {
    /// A node that holds a network.
    package var isContainer: Bool { self == .subnet || self == .asset }
}

extension ProcNode {
    /// What the node is: its kind's spec, but a container's parameters and inputs are its contents'.
    package var spec: ProcNodeSpec {
        guard kind.isContainer else { return kind.spec }
        var s = kind.spec
        guard let contents else { return s }
        s.params += contents.interface.map(ProcParamSpec.init(promoted:))
        s.inputs = contents.inputLabels
        return s
    }

    /// A locked asset node's library asset (its contents come from there).
    package var definition: String? { kind == .asset ? param("asset").string : nil }
}

extension ProcParamSpec {
    /// A container's parameter: one of its contents' interface, edited by the kind of its value.
    package init(promoted p: PromotedParam) {
        let ui: UI
        switch p.value {
        case .float: ui = .number(p.span ?? 0...1)
        case .int: ui = .integer(p.span.map { Int($0.lowerBound.rounded())...Int($0.upperBound.rounded()) } ?? 0...10)
        case .bool: ui = .toggle
        case .vec2, .vec3, .vec4: ui = .vector
        default: ui = .text
        }
        self.init(p.name, p.title, p.value, ui)
    }
}

extension ProcGraph {
    /// The labels of the inputs a network's Sub-Network Input nodes make: as many as the highest's number.
    package var inputLabels: [String] {
        let subs = nodes.filter { $0.kind == .subinput }
        let count = subs.map { max(1, $0.param("input").int) }.max() ?? 0
        return (0..<count).map { k in
            let label = subs.first { $0.param("input").int == k + 1 }?.param("label").string ?? ""
            return label.isEmpty ? "Input \(k + 1)" : label
        }
    }

    /// The network at `path` (container ids from this one; empty: this one). Setting one at a path that isn't there
    /// does nothing.
    package subscript(path path: [String]) -> ProcGraph? {
        get {
            var g = self
            for id in path {
                guard let c = g.node(id)?.contents else { return nil }
                g = c
            }
            return g
        }
        set {
            guard let first = path.first else {
                if let newValue { self = newValue }
                return
            }
            guard let i = index(of: first), var c = nodes[i].contents else { return }
            c[path: Array(path.dropFirst())] = newValue
            nodes[i].contents = c
        }
    }

    /// Is the network at `path` a locked asset's (or in one)? Its edits go to the definition, not here.
    package func isLocked(_ path: [String]) -> Bool {
        var g = self
        for id in path {
            guard let n = g.node(id), let c = n.contents else { return false }
            if n.kind == .asset, !n.editable { return true }
            g = c
        }
        return false
    }

    /// Every node of the network and of the networks in it, with the path of container ids it is at.
    package func walk(_ path: [String] = [], _ body: (ProcNode, [String]) -> Void) {
        for n in nodes {
            body(n, path)
            n.contents?.walk(path + [n.id], body)
        }
    }

    /// The network with each locked asset node's contents put in again from its definition (`definition` finds an
    /// asset by slug), at every depth. `chain`: the assets being put in (an asset that contains itself is left as
    /// it was; the cook says so). An asset the library doesn't have keeps the contents it was saved with.
    package func syncingDefinitions(_ definition: (String) -> ProcAsset?, chain: [String] = []) -> ProcGraph {
        var g = self
        for i in g.nodes.indices {
            let n = g.nodes[i]
            switch n.kind {
            case .subnet:
                g.nodes[i].contents = (n.contents ?? ProcGraph()).syncingDefinitions(definition, chain: chain)
            case .asset:
                let slug = n.param("asset").string
                guard !chain.contains(slug) else { continue }
                if !n.editable, let d = definition(slug) {
                    g.nodes[i].contents = d.graph.syncingDefinitions(definition, chain: chain + [slug])
                } else if let c = n.contents {
                    g.nodes[i].contents = c.syncingDefinitions(definition, chain: chain + [slug])
                }
            default: break
            }
        }
        return g
    }

    /// The node at a path of names from this network (`subnet1/box1`), and the container ids to its network.
    package func node(named path: String) -> (node: ProcNode, path: [String])? {
        let names = path.split(separator: "/").map(String.init)
        guard let last = names.last else { return nil }
        var g = self
        var ids: [String] = []
        for name in names.dropLast() {
            guard let n = g.named(name) ?? g.node(name), let c = n.contents else { return nil }
            ids.append(n.id)
            g = c
        }
        return (g.named(last) ?? g.node(last)).map { ($0, ids) }
    }
}

// MARK: Collapse and extract

extension ProcGraph {
    /// Why an edit of the networks in nodes can't be made.
    package struct EditError: Error, CustomStringConvertible {
        package var message: String
        package init(_ message: String) { self.message = message }
        package var description: String { message }
    }

    /// Houdini's Collapse into Subnetwork: the nodes `ids` go into a new Subnetwork in their place. Each node outside
    /// wired into them becomes one of its inputs (a Sub-Network Input inside, numbered in the order they are met), the
    /// one node feeding the outside (if any) its output; the paths in expressions are rewritten to where the nodes are
    /// now (`../box9` inside to `../../box9`, `../box1` outside to `../subnet1/box1`), and so are promoted parameters'
    /// targets. Its id.
    @discardableResult
    package mutating func collapse(_ ids: Set<String>, name: String? = nil) throws -> String {
        let moved = nodes.filter { ids.contains($0.id) }
        guard !moved.isEmpty else { throw EditError("Select the nodes to collapse") }
        let names = Set(moved.map(\.name))
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let into = links.filter { !ids.contains($0.from) && ids.contains($0.to) }.sorted { (order[$0.to]!, $0.input) < (order[$1.to]!, $1.input) }
        let out = links.filter { ids.contains($0.from) && !ids.contains($0.to) }
        let feeders = Set(out.map(\.from))
        guard feeders.count <= 1 else { throw EditError("More than one of the nodes feeds the network outside them: a subnetwork has one output") }
        var sources: [String] = []
        for l in into where !sources.contains(l.from) { sources.append(l.from) }

        let subnet = name.flatMap { $0.isEmpty || named($0) != nil ? nil : $0 } ?? uniqueName("subnet")
        let sid = uniqueID()
        var c = ProcGraph()
        c.nodes = moved.map { n in
            var n = n.rewritingPaths { ProcPathMove.collapsedInside($0, $1, moved: names) }
            n.display = false
            n.render = false
            return n
        }
        c.links = links.filter { ids.contains($0.from) && ids.contains($0.to) }
        let top = moved.map(\.at.y).min()!, left = moved.map(\.at.x).min()!
        for (k, source) in sources.enumerated() {
            let id = c.uniqueID()
            c.nodes.append(ProcNode(.subinput, id: id, name: c.uniqueName("subinput"), params: ["input": .int(k + 1)],
                                    at: [left + Float(k) * ProcGraph.columnGap, top - ProcGraph.rowGap]))
            for l in into where l.from == source { c.links.append(ProcLink(id, to: l.to, l.input)) }
        }
        if let d = feeders.first ?? moved.first(where: \.display)?.id ?? moved.last?.id { c.setDisplay(d) }

        let hadDisplay = moved.contains(where: \.display), hadRender = moved.contains(where: \.render)
        for i in interface.indices {
            for k in interface[i].targets.indices {
                let t = interface[i].targets[k].node
                if names.contains(String(t.split(separator: "/").first ?? "")) { interface[i].targets[k].node = "\(subnet)/\(t)" }
            }
        }
        nodes.removeAll { ids.contains($0.id) }
        links.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        for i in nodes.indices { nodes[i] = nodes[i].rewritingPaths { ProcPathMove.collapsedOutside($0, $1, moved: names, into: subnet) } }
        var s = ProcNode(.subnet, id: sid, name: subnet, at: moved.map(\.at).reduce(.zero, +) / Float(moved.count))
        s.contents = c
        s.render = hadRender
        nodes.append(s)
        for (k, source) in sources.enumerated() { links.append(ProcLink(source, to: sid, k)) }
        for l in out { links.append(ProcLink(sid, to: l.to, l.input)) }
        if hadDisplay || !nodes.contains(where: \.display) { setDisplay(sid) }
        return sid
    }

    /// Houdini's Extract Contents: Subnetwork `id`'s nodes into this network in its place (named as they were where
    /// that is free), wired as its inputs and output were; its parameters join this network's (their values the
    /// subnetwork's as set), and paths are rewritten back. Its nodes' new ids.
    @discardableResult
    package mutating func extract(_ id: String) throws -> [String] {
        guard let i = index(of: id), nodes[i].kind == .subnet, let c = nodes[i].contents else { throw EditError("Only a subnetwork's contents can be extracted") }
        let s = nodes[i]
        let inputs = inputs(of: id)
        // Its parameters, renamed where this network has one of the name.
        var params: [String: String] = [:]
        var added: [PromotedParam] = []
        for p in c.interface {
            var name = p.name, k = 2
            while interface.contains(where: { $0.name == name }) || added.contains(where: { $0.name == name }) { name = "\(p.name)\(k)"; k += 1 }
            params[p.name] = name
            added.append(PromotedParam(name, title: p.title, value: s.param(p.name), span: p.span, targets: p.targets))
        }
        // Its nodes (not its inputs), renamed where taken, and given ids free here.
        let moving = c.nodes.filter { $0.kind != .subinput }
        var renamed: [String: String] = [:], ids: [String: String] = [:]
        var taken = Set(nodes.map(\.name)).subtracting([s.name]), usedIDs = Set(nodes.map(\.id))
        for n in moving {
            var name = n.name
            if taken.contains(name) {
                let base = String(name.reversed().drop { $0.isNumber }.reversed())
                var k = 1
                while taken.contains("\(base)\(k)") { k += 1 }
                name = "\(base)\(k)"
            }
            taken.insert(name)
            renamed[n.name] = name
            var nid = n.id, k = nodes.count + 1
            while usedIDs.contains(nid) { nid = "n\(k)"; k += 1 }
            usedIDs.insert(nid)
            ids[n.id] = nid
        }
        for k in added.indices {
            added[k].targets = added[k].targets.map { t in
                var t = t
                let parts = t.node.split(separator: "/").map(String.init)
                if let first = parts.first, let r = renamed[first] { t.node = ([r] + parts.dropFirst()).joined(separator: "/") }
                return t
            }
        }
        for k in interface.indices {
            interface[k].targets = interface[k].targets.compactMap { t in
                var t = t
                let parts = t.node.split(separator: "/").map(String.init)
                guard parts.first == s.name else { return t }
                guard parts.count > 1, let r = renamed[parts[1]] else { return nil }
                t.node = ([r] + parts.dropFirst(2)).joined(separator: "/")
                return t
            }
        }
        // What its output is: an Output node inside goes (it would become this network's output), wired through.
        var inner = c
        var output = c.outputNode
        if let o = output, c.node(o)?.kind == .output {
            output = c.inputs(of: o).first ?? nil
            inner.remove([o])
        }
        let centre = moving.isEmpty ? s.at : moving.map(\.at).reduce(.zero, +) / Float(moving.count)
        var new: [ProcNode] = []
        for n in inner.nodes where n.kind != .subinput {
            var n = n.rewritingPaths { ProcPathMove.extractedInside($0, $1, renamed: renamed, params: params) }
            n.id = ids[n.id]!
            n.name = renamed[n.name] ?? n.name
            n.at += s.at - centre
            n.display = s.display && ids[output ?? ""] == n.id
            n.render = false
            new.append(n)
        }
        var wires: [ProcLink] = []
        for l in inner.links {
            guard let to = ids[l.to] else { continue }
            if let from = ids[l.from] {
                wires.append(ProcLink(from, to: to, l.input))
            } else if let sub = inner.node(l.from), sub.kind == .subinput {
                let k = sub.param("input").int - 1
                if k >= 0, k < inputs.count, let up = inputs[k] { wires.append(ProcLink(up, to: to, l.input)) }
            }
        }
        // Its output's wires out: from what its output was.
        let outputs = links.filter { $0.from == id }
        var source = output.flatMap { ids[$0] }
        if source == nil, let o = output, let sub = inner.node(o), sub.kind == .subinput {
            let k = sub.param("input").int - 1
            source = k >= 0 && k < inputs.count ? inputs[k] : nil
        }
        nodes.remove(at: i)
        links.removeAll { $0.from == id || $0.to == id }
        for k in nodes.indices {
            nodes[k] = nodes[k].rewritingPaths { ProcPathMove.extractedOutside($0, $1, subnet: s.name, renamed: renamed, params: params) }
        }
        nodes += new
        links += wires
        if let source { for l in outputs { links.append(ProcLink(source, to: l.to, l.input)) } }
        interface += added
        if s.display, !nodes.contains(where: \.display), let last = new.last?.id { setDisplay(last) }
        return new.map(\.id)
    }

    /// Where new nodes go below others (ProcNetworkLayout's gaps).
    static let rowGap: Float = 64
    static let columnGap: Float = 170
}

extension ProcNode {
    /// The node with the paths in its expressions (and in its text parameters' backticks) passed through `map`: a
    /// path's node part (its components) and its channel (nil: a node path, `npoints("../box1")`), to new ones (nil:
    /// unchanged).
    package func rewritingPaths(_ map: ([String], String?) -> (place: [String], channel: String?)?) -> ProcNode {
        var n = self
        func rewrite(_ source: String) -> String {
            guard let refs = try? ProcExpr.parse(source).references else { return source }
            let channels = Set(refs.channels + refs.otherFrames), nodes = Set(refs.nodes)
            return ProcExpr.rewritingStrings(source) { s in
                if nodes.contains(s) {
                    return map(s.split(separator: "/").map(String.init), nil).map { $0.place.joined(separator: "/") }
                }
                guard channels.contains(s) else { return nil }
                let (place, channel) = ProcExprContext.split(s)
                guard let place, let r = map(place.split(separator: "/").map(String.init), channel) else { return nil }
                return r.place.joined(separator: "/") + "/" + (r.channel ?? channel)
            }
        }
        for (c, source) in expressions { n.expressions[c] = rewrite(source) }
        for (k, p) in params {
            guard case .string(let t) = p, t.contains("`") else { continue }
            let parts = t.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
            n.params[k] = .string(parts.enumerated().map { $0.offset % 2 == 1 ? rewrite($0.element) : $0.element }.joined(separator: "`"))
        }
        return n
    }
}

extension ProcExpr {
    /// `source` with each string literal's text passed through `map` (nil: kept as it is).
    package static func rewritingStrings(_ source: String, _ map: (String) -> String?) -> String {
        let c = Array(source)
        var out = ""
        var i = 0
        while i < c.count {
            guard c[i] == "\"" || c[i] == "'" else { out.append(c[i]); i += 1; continue }
            let quote = c[i], start = i
            var text = ""
            i += 1
            while i < c.count, c[i] != quote {
                if c[i] == "\\", i + 1 < c.count { i += 1 }
                text.append(c[i])
                i += 1
            }
            guard i < c.count else { out += String(c[start...]); break }
            i += 1
            if let r = map(text) {
                out.append(quote)
                out += r.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: String(quote), with: "\\" + String(quote))
                out.append(quote)
            } else {
                out += String(c[start..<i])
            }
        }
        return out
    }
}

/// How a path changes when the nodes it is from or to move between networks (`place`: its node part's components;
/// `channel`: nil for a node path).
package enum ProcPathMove {
    typealias Result = (place: [String], channel: String?)?

    /// From a node moved into a new subnetwork with `moved` (names).
    static func collapsedInside(_ place: [String], _ channel: String?, moved: Set<String>) -> Result {
        guard let first = place.first, first != "." else { return nil }
        if first == ".." {
            if place.count == 1 || place[1] == ".." { return ([".."] + place, channel) }   // the container's, one up now
            return moved.contains(place[1]) ? nil : ([".."] + place, channel)
        }
        return moved.contains(first) ? nil : (["..", ".."] + place, channel)                // a bare name: beside
    }

    /// From a node left beside the new subnetwork `subnet`.
    static func collapsedOutside(_ place: [String], _ channel: String?, moved: Set<String>, into subnet: String) -> Result {
        if place.first == "..", place.count >= 2, moved.contains(place[1]) { return (["..", subnet] + place.dropFirst(), channel) }
        if let first = place.first, first != ".", first != "..", moved.contains(first) { return (["..", subnet] + place, channel) }
        return nil
    }

    /// From a node taken out of a subnetwork (its nodes `renamed`, its parameters now the network's, `params`).
    static func extractedInside(_ place: [String], _ channel: String?, renamed: [String: String], params: [String: String]) -> Result {
        guard let first = place.first, first != "." else { return nil }
        if first == ".." {
            if place.count == 1 { return channel.map { ([".."], rename($0, params)) } }
            if place[1] == ".." { return (Array(place.dropFirst()), channel) }
            return renamed[place[1]].map { (["..", $0] + place.dropFirst(2), channel) }
        }
        return renamed[first].map { ([$0] + place.dropFirst(), channel) }
    }

    /// From a node beside the subnetwork `subnet` its contents were taken out of.
    static func extractedOutside(_ place: [String], _ channel: String?, subnet: String, renamed: [String: String], params: [String: String]) -> Result {
        let rest: [String]
        if place.first == "..", place.count >= 2, place[1] == subnet { rest = Array(place.dropFirst(2)) }
        else if place.first == subnet { rest = Array(place.dropFirst()) }
        else { return nil }
        guard let name = rest.first else { return channel.map { ([".."], rename($0, params)) } }   // the subnetwork's own
        return renamed[name].map { (["..", $0] + rest.dropFirst(), channel) }
    }

    /// A channel of a renamed parameter (`width` → `width2`, `widthx` → `width2x`).
    package static func rename(_ channel: String, _ params: [String: String]) -> String {
        if let r = params[channel] { return r }
        if let last = channel.last, ProcExprParser.component(last) != nil, let r = params[String(channel.dropLast())] { return r + String(last) }
        return channel
    }
}
