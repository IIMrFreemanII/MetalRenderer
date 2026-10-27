import EngineCore
import Foundation
import Modeling
import simd

/// Why a node didn't cook: its message, and the node it is about.
package struct ProcCookError: Error, Equatable, CustomStringConvertible {
    package var message: String
    package var node: String = ""
    package init(_ message: String, node: String = "") { self.message = message; self.node = node }
    package var description: String { message }

    static let cancelled = ProcCookError("cancelled")
}

/// What a network reads from outside it: the geometry a File node names (`mesh:<slug>`, `object:<name>`) and a
/// stamp that changes when that geometry does (part of the node's cook key), and the library's assets an asset node
/// puts in (`ProcGraph.syncingDefinitions`).
package struct ProcEnvironment {
    package var file: (String) -> ProcGeo?
    package var stamp: (String) -> UInt64
    package var definition: (String) -> ProcAsset?
    /// The frame expressions read (`$F`, `$T`): the Procedural workspace's frame field, a placed asset's `frame=`.
    package var frame: Float = 1

    package init(file: @escaping (String) -> ProcGeo?, stamp: @escaping (String) -> UInt64,
                 definition: @escaping (String) -> ProcAsset? = { ProcStore.cachedRead($0) }) {
        self.file = file
        self.stamp = stamp
        self.definition = definition
    }

    /// Model assets (`mesh:<slug>` in ModelStore's folder): their objects' meshes, placed, as one geometry.
    package static let assets = ProcEnvironment(
        file: { ProcEnvironment.readAsset($0) },
        stamp: { name in
            guard name.hasPrefix("mesh:"), let url = ModelStore.url(String(name.dropFirst(5))),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return 0 }
            return UInt64(date.timeIntervalSince1970 * 1000)
        })

    package static func readAsset(_ name: String) -> ProcGeo? {
        guard name.hasPrefix("mesh:"), let url = ModelStore.url(String(name.dropFirst(5))),
              let doc = ModelAsset.readDocument(url) else { return nil }
        var out = ProcGeo()
        for o in doc.objects where o.renders {
            let names = o.materials.map(\.name)
            out.merge(ProcGeo(o.mesh.transformed(by: o.transform.matrix), materials: names))
        }
        return out
    }
}

/// What the cook left of a node: how long it took, whether it came from the cache, its error or warnings, and its
/// output's counts (the network view's badges and the info popup).
package struct ProcNodeInfo: Equatable {
    package var milliseconds: Double = 0
    package var cached = false
    package var error: String?
    package var warnings: [String] = []
    package var points = 0
    package var vertices = 0
    package var prims = 0
    /// The output's attribute names (with their types) and group names, by class: what a field below offers.
    package var attributes: [AttributeClass: [(name: String, type: AttributeType)]] = [:]
    package var groups: [AttributeClass: [String]] = [:]
    /// Each channel with an expression: its value (nil: it varies per element).
    package var channels: [String: Float?] = [:]

    package static func == (a: ProcNodeInfo, b: ProcNodeInfo) -> Bool {
        a.milliseconds == b.milliseconds && a.cached == b.cached && a.error == b.error && a.warnings == b.warnings
            && a.points == b.points && a.vertices == b.vertices && a.prims == b.prims && a.groups == b.groups && a.channels == b.channels
            && a.attributes.mapValues { $0.map(\.name) } == b.attributes.mapValues { $0.map(\.name) }
    }
}

/// Cooks networks: pulls a node's geometry from its inputs', recursively, as Houdini does. Every node has a key, a
/// hash of its kind, its parameters and its inputs' keys (nothing of where it is or what it is called), and its output
/// is kept under that key: a parameter edit recooks that node and what is below it; undo finds the old outputs again;
/// two networks (two placed assets) with the same nodes share them. The cache holds up to `budget` bytes, dropping the
/// least recently used.
///
/// Not thread-safe: an editor cooks on one queue of its own.
package final class ProcCooker {
    package var environment: ProcEnvironment
    package var budget = 768 << 20

    private struct Entry { var geo: ProcGeo; var bytes: Int; var used: UInt64; var channels: [String: Float?] = [:] }
    private var cache: [UInt64: Entry] = [:]
    private var bytes = 0
    private var tick: UInt64 = 0
    /// The last cook's report per node (of the nodes it reached): by id, a node in a container's network by the
    /// containers' ids and its own (`n3/n2`).
    package private(set) var info: [String: ProcNodeInfo] = [:]

    /// Bumped when a node's cook changes, so outputs cooked before aren't taken for the new ones'.
    package static let version = 4

    package init(environment: ProcEnvironment = .assets) { self.environment = environment }

    /// Forgets every kept output.
    package func clear() {
        cache.removeAll()
        bytes = 0
    }

    package var cachedBytes: Int { bytes }

    /// One cook of a network: its keys and outputs by node, so a node two others read cooks once. A container's
    /// network has a pass of its own, below its container's.
    private final class Pass {
        let graph: ProcGraph
        var keys: [String: UInt64] = [:]
        var geos: [String: ProcGeo] = [:]
        var visiting: Set<String> = []
        let cancelled: () -> Bool
        /// A For-Each loop's pass: its Block Begin's output (the piece) and key.
        var overrides: [String: (geo: ProcGeo, key: UInt64)] = [:]
        /// The expressions' channels found in this pass (a For-Each pass has its own: its piece differs).
        let expressions = ProcExprState()
        /// The channels a key is being found for, in every pass of the cook (a `ch()` loop).
        let channelKeys: Visits
        /// The pass of the network this one's container is in, and the container (nil: the top network).
        private(set) var parentPass: Pass?
        let parentNode: String?
        /// The containers' ids down to this network (`n3/n7/`; empty at the top): what `info` is keyed by.
        let prefix: String
        /// The assets this network is in (an asset that contains itself).
        let slugs: [String]
        /// The passes of the containers' networks in this one, by container.
        var children: [String: Pass] = [:]

        final class Visits { var set: Set<String> = [] }

        init(graph: ProcGraph, cancelled: @escaping () -> Bool, parent: Pass? = nil, node: String? = nil, prefix: String = "",
             slugs: [String] = [], channelKeys: Visits = Visits()) {
            self.graph = graph
            self.cancelled = cancelled
            parentPass = parent
            parentNode = node
            self.prefix = prefix
            self.slugs = slugs
            self.channelKeys = channelKeys
        }

        var parent: (pass: Pass, node: String)? {
            guard let p = parentPass, let n = parentNode else { return nil }
            return (p, n)
        }

        /// A pass beside this one (a For-Each pass): the same place, keys and outputs of its own.
        func sibling() -> Pass {
            Pass(graph: graph, cancelled: cancelled, parent: parentPass, node: parentNode, prefix: prefix, slugs: slugs, channelKeys: channelKeys)
        }

        /// Lets go of the passes below (they hold this one).
        func release() {
            for c in children.values { c.release() }
            children.removeAll()
            parentPass = nil
        }
    }

    /// Node `id`'s geometry (cooking what it needs), or why it can't be had. `path`: the containers (ids, from the
    /// top) whose network `id` is in, cooked with their inputs and parameters. `cancelled` is asked between nodes: a
    /// cook a newer edit made stale stops there.
    package func cook(_ graph: ProcGraph, at path: [String] = [], _ id: String, cancelled: @escaping () -> Bool = { false }) -> Result<ProcGeo, ProcCookError> {
        let root = Pass(graph: graph, cancelled: cancelled)
        defer { root.release() }
        tick += 1
        do {
            let g = try geometry(id, try pass(root, at: path))
            trim()
            return .success(g)
        } catch let e as ProcCookError {
            trim()
            return .failure(e)
        } catch {
            return .failure(ProcCookError("\(error)", node: id))
        }
    }

    /// Node `id`'s cook key (`path`: as for `cook`).
    package func key(_ graph: ProcGraph, at path: [String] = [], _ id: String) -> UInt64? {
        let root = Pass(graph: graph, cancelled: { false })
        defer { root.release() }
        return try? key(id, try pass(root, at: path))
    }

    /// The pass of the network at `path` below `root`'s: each container's with its parameters' values.
    private func pass(_ root: Pass, at path: [String]) throws -> Pass {
        var p = root
        for id in path {
            guard let node = p.graph.node(id) else { throw ProcCookError("no node \(id)", node: id) }
            var values: [String: ProcParam]?
            if node.contents?.interface.contains(where: { s in ProcExprContext.channels(of: ProcParamSpec(promoted: s)).contains(where: node.isDriven) }) == true,
               let x = expressions(id, p) {
                do {
                    values = try resolve(node, x).params
                } catch let e as ProcCookError {
                    throw ProcCookError(e.message, node: id)
                }
            }
            p = try contents(id, in: p, values: values)
        }
        return p
    }

    // MARK: Networks in nodes

    /// The pass of container `id`'s network: its contents with `values` (nil: the container's parameters as set)
    /// put into their interface's targets. The one made before is kept for the keys and the cook.
    private func contents(_ id: String, in pass: Pass, values: [String: ProcParam]? = nil) throws -> Pass {
        if values == nil, let p = pass.children[id] { return p }
        guard let node = pass.graph.node(id) else { throw ProcCookError("no node \(id)", node: id) }
        guard node.kind.isContainer else { throw ProcCookError("\(node.name) has no network inside", node: id) }
        var slugs = pass.slugs
        if let slug = node.definition {
            guard !slugs.contains(slug) else { throw ProcCookError("proc:\(slug) contains itself", node: id) }
            slugs.append(slug)
        }
        guard let c = node.contents else { throw ProcCookError("The library has no procedural asset \(node.definition ?? "")", node: id) }
        var set: [String: ProcParam] = [:]
        for p in c.interface { set[p.name] = node.param(p.name) }
        let child = Pass(graph: c.applying(values ?? set), cancelled: pass.cancelled, parent: pass, node: id,
                         prefix: pass.prefix + id + "/", slugs: slugs, channelKeys: pass.channelKeys)
        pass.children[id]?.release()
        pass.children[id] = child
        return child
    }

    /// What a Sub-Network Input passes on: the node wired into its container's input of its number, and its pass.
    private func subinputSource(_ node: ProcNode, _ pass: Pass) -> (pass: Pass, id: String)? {
        guard let (p, container) = pass.parent else { return nil }
        let inputs = p.graph.inputs(of: container)
        let i = node.param("input").int - 1
        guard i >= 0, i < inputs.count, let up = inputs[i] else { return nil }
        return (p, up)
    }

    /// A container's geometry: its network's output (its Output node, else its display flag) cooked with its
    /// parameters' values.
    private func cookContents(_ id: String, _ c: ProcCook, _ pass: Pass) throws -> ProcGeo {
        let interface = c.node.contents?.interface ?? []
        var values: [String: ProcParam] = [:]
        for p in interface { values[p.name] = c.param(p.name) }
        let child = try contents(id, in: pass, values: interface.allSatisfy { c.resolved[$0.name] == nil } ? nil : values)
        guard let out = child.graph.outputNode else { return ProcGeo() }
        do {
            return try geometry(out, child)
        } catch let e as ProcCookError where e != .cancelled {
            guard let n = child.graph.node(e.node) else { throw ProcCookError(e.message) }
            throw ProcCookError("\(n.name): \(e.message)")
        }
    }

    /// Where a node path leads from node `from` of `pass`'s network: `.` stays, `..` is the network's container
    /// (from a network: its container's), a name a node of the network reached (from a node: of its network inside).
    /// A bare name is a node beside `from`.
    private enum Place {
        case node(Pass, String)
        /// The network itself: its container (`..`), or at the top the asset (its promoted parameters).
        case network(Pass)
    }

    private func place(_ path: String, from: String, _ pass: Pass) throws -> Place {
        let parts = path.split(separator: "/").map(String.init)
        var at = Place.node(pass, from)
        if parts.count == 1, parts[0] != ".", parts[0] != ".." { at = .network(pass) }
        for part in parts {
            switch (part, at) {
            case (".", _): break
            case ("..", .node(let p, _)): at = .network(p)
            case ("..", .network(let p)):
                guard let up = p.parent else { throw ProcCookError("\"\(path)\" goes above the top network") }
                at = .network(up.pass)
            case (_, .network(let p)):
                guard let n = p.graph.named(part) ?? p.graph.node(part) else { throw ProcCookError("\"\(path)\": no node \(part)") }
                at = .node(p, n.id)
            case (_, .node(let p, let id)):
                let c = try contents(id, in: p)
                guard let n = c.graph.named(part) ?? c.graph.node(part) else { throw ProcCookError("\"\(path)\": no node \(part)") }
                at = .node(c, n.id)
            }
        }
        return at
    }

    // MARK: Keys

    private func key(_ id: String, _ pass: Pass) throws -> UInt64 {
        if let k = pass.keys[id] { return k }
        if let o = pass.overrides[id] { pass.keys[id] = o.key; return o.key }
        guard let node = pass.graph.node(id) else { throw ProcCookError("no node \(id)", node: id) }
        guard !pass.visiting.contains(id) else { throw ProcCookError("the network loops through \(node.name)", node: id) }
        pass.visiting.insert(id)
        defer { pass.visiting.remove(id) }
        let inputs = pass.graph.inputs(of: id)
        var h = Hasher64()
        if node.bypass {
            // A bypassed node is its first input.
            let k = try inputs.first.flatMap { $0 }.map { try key($0, pass) } ?? Hasher64().value
            pass.keys[id] = k
            return k
        }
        h.add(ProcCooker.version)
        h.add(node.kind.rawValue)
        for s in node.spec.params {
            h.add(s.name)
            node.param(s.name).hash(into: &h)
            if ProcExprContext.expands(s), case .string(let t) = node.param(s.name) { try textDependencies(t, of: node, pass, into: &h) }
        }
        for (channel, source) in node.expressions.sorted(by: { $0.key < $1.key }) {
            h.add(channel)
            h.add(source)
            try dependencies(source, of: node, pass, into: &h)
        }
        // A keyed channel's value at the frame, not the frame: frames where it holds share a cook.
        for (channel, curve) in node.curves.sorted(by: { $0.key < $1.key }) {
            h.add("curve")
            h.add(channel)
            h.add(curve.value(at: environment.frame))
        }
        if node.kind == .switchnode {
            let pick = try switchIndex(node, inputs.count, pass)
            h.add(pick ?? -1)
            if let i = pick, let up = inputs[i] { h.add(try key(up, pass)) }
        } else {
            for i in inputs {
                if let i { h.add(try key(i, pass)) } else { h.add(0) }
            }
        }
        if node.kind == .file { h.add(environment.stamp(node.param("file").string)) }
        if node.kind == .subinput { h.add(try subinputSource(node, pass).map { try key($0.id, $0.pass) } ?? 0) }
        if node.kind.isContainer {
            // Its network's output's key (which has what it reads through `..`), nothing of its ids or names.
            let child = try contents(id, in: pass)
            h.add("contents")
            h.add(try child.graph.outputNode.map { try key($0, child) } ?? 0)
        }
        pass.keys[id] = h.value
        return h.value
    }

    /// What an expression reads besides its node's inputs, into its node's key: the frame, the channels it reads
    /// (theirs in turn), the nodes it reads by path.
    private func dependencies(_ source: String, of node: ProcNode, _ pass: Pass, into h: inout Hasher64) throws {
        guard let refs = try? ProcExpr.parse(source).references else { return }   // (the cook reports it)
        if refs.frame { h.add("frame"); h.add(environment.frame) }
        for path in refs.channels { try channelKey(path, from: node, pass, into: &h) }
        for path in refs.otherFrames { try channelKey(path, from: node, pass, anyFrame: true, into: &h) }
        for path in refs.nodes {
            guard case .node(let p, let id)? = try? place(path, from: node.id, pass), p !== pass || id != node.id else { continue }
            h.add(try key(id, p))
        }
    }

    /// A text parameter's `backticks` and `$F`, as `dependencies`.
    private func textDependencies(_ text: String, of node: ProcNode, _ pass: Pass, into h: inout Hasher64) throws {
        guard text.contains("`") || text.contains("$") else { return }
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        for (k, part) in parts.enumerated() {
            if k % 2 == 1 { try dependencies(String(part), of: node, pass, into: &h) }
            else if part.contains("$F") || part.contains("$T") { h.add("frame"); h.add(environment.frame) }
        }
    }

    /// What a `ch()` path's value comes from: a promoted parameter's value, a channel's value as set, its keys' value
    /// at the frame (`anyFrame`, `chf()` at another frame: all of its keys), or its expression and what that reads
    /// (and its node's inputs, which it may read).
    private func channelKey(_ path: String, from owner: ProcNode, _ pass: Pass, anyFrame: Bool = false, into h: inout Hasher64) throws {
        h.add(path)
        let (at, channel) = ProcExprContext.split(path)
        var target = owner
        var tp = pass
        if let at {
            // A path that leads nowhere: the cook says so.
            guard let place = try? place(at, from: owner.id, pass) else { return }
            switch place {
            case .node(let p, let id):
                guard let n = p.graph.node(id) else { return }
                (tp, target) = (p, n)
            case .network(let p):
                if let (up, c) = p.parent, let n = up.graph.node(c) {
                    (tp, target) = (up, n)
                } else {
                    let i = p.graph.interface
                    let promoted = i.first { $0.name == channel } ?? i.first { $0.name == String(channel.dropLast()) }
                    promoted?.value.hash(into: &h)
                    return
                }
            }
        }
        let visit = "\(tp.prefix)\(target.id)/\(channel)"
        guard !pass.channelKeys.set.contains(visit) else {
            throw ProcCookError("\(target.name)/\(channel) reads itself through ch()", node: owner.id)
        }
        pass.channelKeys.set.insert(visit)
        defer { pass.channelKeys.set.remove(visit) }
        if let curve = target.curves[channel] {
            h.add("curve")
            if anyFrame { curve.hash(into: &h) } else { h.add(curve.value(at: environment.frame)) }
        } else if let source = target.expressions[channel] {
            h.add(source)
            try dependencies(source, of: target, tp, into: &h)
            if tp !== pass || target.id != owner.id, (try? ProcExpr.parse(source).references.inputs) == true {
                for i in tp.graph.inputs(of: target.id) { h.add(try i.map { try key($0, tp) } ?? 0) }
            }
        } else if let spec = ProcExprContext.locate(channel, in: target)?.spec ?? target.spec.param(channel) {
            let v = target.param(spec.name)
            v.hash(into: &h)
            if case .string(let t) = v { try textDependencies(t, of: target, tp, into: &h) }
        }
    }

    // MARK: Expressions

    /// Node `id`'s expressions in this pass: its inputs (`inputs`, cooked; else cooked when read) and other nodes'
    /// outputs. `geometry` false: reading geometry is an error (a Switch's pick, which its key needs before cooking).
    private func expressions(_ id: String, _ pass: Pass, inputs: [ProcGeo?] = [], geometry: Bool = true) -> ProcExprContext? {
        guard let node = pass.graph.node(id) else { return nil }
        let ids = pass.graph.inputs(of: id)
        let refuse = ProcExprError("A Switch's input expression can't read geometry: the input is picked before anything cooks")
        return ProcExprContext(
            graph: pass.graph, node: node, frame: environment.frame, state: pass.expressions,
            input: { [unowned self] i in
                guard geometry else { throw refuse }
                if i < inputs.count, let g = inputs[i] { return g }
                guard i < ids.count, let up = ids[i] else { return nil }
                return try self.geometry(up, pass)
            },
            find: { [unowned self] path in
                let place: Place
                do { place = try self.place(path, from: id, pass) } catch let e as ProcCookError { throw ProcExprError(e.message) }
                switch place {
                case .node(let p, let n):
                    guard let x = self.expressions(n, p, geometry: geometry) else { throw ProcExprError("\"\(path)\": no node") }
                    return .node(x)
                case .network(let p):
                    if let (up, c) = p.parent, let x = self.expressions(c, up, geometry: geometry) { return .node(x) }
                    return .parameters(p.graph.interface)
                }
            },
            output: { [unowned self] in
                guard geometry else { throw refuse }
                return try self.geometry(id, pass)
            })
    }

    /// The input a Switch passes (its expression evaluated), clamped to its inputs (nil without inputs).
    private func switchIndex(_ node: ProcNode, _ count: Int, _ pass: Pass) throws -> Int? {
        guard count > 0 else { return nil }
        var pick = node.param("input").int
        if node.isDriven("input"), let x = expressions(node.id, pass, geometry: false) {
            do {
                pick = Int(try x.value(ofChannel: "input").rounded())
            } catch let e as ProcExprError {
                throw ProcCookError("Select Input: \(e.message)", node: node.id)
            }
        }
        return min(max(0, pick), count - 1)
    }

    /// The parameters the cook reads with their expressions evaluated, and each expression channel's value.
    private func resolve(_ node: ProcNode, _ x: ProcExprContext) throws -> (params: [String: ProcParam], channels: [String: Float?]) {
        var params: [String: ProcParam] = [:]
        var channels: [String: Float?] = [:]
        for s in node.spec.params {
            do {
                if let v = try x.resolved(s) { params[s.name] = v }
                for c in ProcExprContext.channels(of: s) where node.isDriven(c) {
                    let varying = s.perElement ? try x.varies(c) : false
                    channels[c] = varying ? Float?.none : try x.value(ofChannel: c)
                }
            } catch let e as ProcExprError {
                throw ProcCookError("\(s.title): \(e.message)")
            }
        }
        return (params, channels)
    }

    // MARK: Cooking

    private func geometry(_ id: String, _ pass: Pass) throws -> ProcGeo {
        if let g = pass.geos[id] { return g }
        let at = pass.prefix + id
        if let o = pass.overrides[id] {
            pass.geos[id] = o.geo
            record(at, o.geo, ms: 0, cached: false, warnings: [])
            return o.geo
        }
        let k = try key(id, pass)
        guard let node = pass.graph.node(id) else { throw ProcCookError("no node \(id)", node: id) }
        if var e = cache[k] {
            e.used = tick
            cache[k] = e
            record(at, e.geo, ms: 0, cached: true, warnings: info[at]?.warnings ?? [])
            info[at]?.channels = e.channels
            pass.geos[id] = e.geo
            return e.geo
        }
        if pass.cancelled() { throw ProcCookError.cancelled }
        let inputIDs = pass.graph.inputs(of: id)
        if node.bypass {
            let g = try inputIDs.first.flatMap { $0 }.map { try geometry($0, pass) } ?? ProcGeo()
            pass.geos[id] = g
            record(at, g, ms: 0, cached: false, warnings: [])
            return g
        }
        // The inputs (a Switch: only the one it passes; a container's network cooks those it reads).
        var inputs = [ProcGeo?](repeating: nil, count: inputIDs.count)
        let pick = node.kind == .switchnode ? try switchIndex(node, inputIDs.count, pass) : nil
        for (i, up) in inputIDs.enumerated() {
            guard let up, node.kind != .switchnode || i == pick, !node.kind.isContainer else { continue }
            do {
                inputs[i] = try geometry(up, pass)
            } catch let e as ProcCookError where e != .cancelled {
                info[at] = ProcNodeInfo(error: "Input \(i + 1) has an error")
                throw e
            }
        }
        var c = ProcCook(node: node, inputs: inputs, environment: environment)
        var channels: [String: Float?] = [:]
        if let x = expressions(id, pass, inputs: inputs), !node.expressions.isEmpty || !node.curves.isEmpty || node.params.values.contains(where: {
            if case .string(let t) = $0 { return t.contains("`") || t.contains("$") }
            return false
        }) {
            do {
                (c.resolved, channels) = try resolve(node, x)
            } catch let e as ProcCookError where e != .cancelled {
                info[at] = ProcNodeInfo(error: e.message)
                throw ProcCookError(e.message, node: id)
            }
            c.expressions = x
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let g: ProcGeo
        do {
            switch node.kind {
            case .foreachend: g = try forEach(id, c, pass)
            case .subnet, .asset: g = try cookContents(id, c, pass)
            case .subinput: g = try subinputSource(node, pass).map { try geometry($0.id, $0.pass) } ?? ProcGeo()
            default: g = try node.kind.cook(&c)
            }
        } catch let e as ProcCookError {
            info[at] = ProcNodeInfo(error: e.message)
            throw ProcCookError(e.message, node: id)
        } catch let e as GroupPattern.Failure {
            info[at] = ProcNodeInfo(error: e.description)
            throw ProcCookError(e.description, node: id)
        } catch let e as ProcExprError {
            info[at] = ProcNodeInfo(error: e.message)
            throw ProcCookError(e.message, node: id)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        #if DEBUG
        if let problem = g.validate() { assertionFailure("\(node.kind.rawValue) made bad geometry: \(problem)") }
        #endif
        let size = g.byteSize
        cache[k] = Entry(geo: g, bytes: size, used: tick, channels: channels)
        bytes += size
        pass.geos[id] = g
        record(at, g, ms: ms, cached: false, warnings: c.warnings)
        info[at]?.channels = channels
        return g
    }

    // MARK: For-Each

    /// The Block Begin a Block End closes: named by its `blockpath`, else the nearest one above it.
    private func blockBegin(_ end: ProcNode, _ graph: ProcGraph) -> String? {
        let name = end.param("blockpath").string
        if !name.isEmpty { return graph.named(name)?.id ?? graph.node(name)?.id }
        var frontier = graph.inputs(of: end.id).compactMap { $0 }
        var seen = Set<String>()
        while !frontier.isEmpty {
            var next: [String] = []
            for id in frontier where !seen.contains(id) {
                seen.insert(id)
                if graph.node(id)?.kind == .foreachbegin { return id }
                next += graph.inputs(of: id).compactMap { $0 }
            }
            frontier = next
        }
        return nil
    }

    /// A For-Each loop: the body (from the Block Begin to the End's input) cooked once per piece, point or count, the
    /// Begin giving out the piece (or, feeding back, the last pass's output), the passes merged or the last kept. Each
    /// pass's outputs are kept under keys of their own (the Begin's key and the pass's number), so an edit below the
    /// loop doesn't run it again.
    private func forEach(_ id: String, _ c: ProcCook, _ pass: Pass) throws -> ProcGeo {
        let node = c.node
        guard let begin = blockBegin(node, pass.graph) else { throw ProcCookError("No Block Begin above this Block End") }
        guard let source = pass.graph.inputs(of: begin).first ?? nil else { throw ProcCookError("The Block Begin has no input") }
        guard let tail = pass.graph.inputs(of: id).first ?? nil else { throw ProcCookError("Nothing is wired into the Block End") }
        let input = try geometry(source, pass)
        let baseKey = try key(source, pass)
        let method = c.string("iterationmethod")
        let feedback = c.string("gather") == "feedback"
        let pieces: [ProcGeo] = method == "count"
            ? [ProcGeo](repeating: input, count: max(1, min(10_000, c.int("iterations"))))
            : FlowNodes.pieces(input, method: method, attribute: c.string("pieceattrib"))
        var merged = ProcGeo()
        var last = input
        var lastKey = baseKey
        for (k, piece) in pieces.enumerated() {
            if pass.cancelled() { throw ProcCookError.cancelled }
            var g = feedback ? last : piece
            g.detail.set("iteration", .int([Int32(k)]))
            g.detail.set("numiterations", .int([Int32(pieces.count)]))
            var h = Hasher64()
            h.add("foreach")
            h.add(feedback ? lastKey : baseKey)
            h.add(k)
            h.add(method)
            let sub = pass.sibling()
            defer { sub.release() }
            sub.overrides = pass.overrides
            sub.overrides[begin] = (g, h.value)
            let out = try geometry(tail, sub)
            if feedback {
                last = out
                lastKey = try key(tail, sub)
            } else {
                merged.merge(out)
            }
        }
        return feedback ? last : merged
    }

    private func record(_ id: String, _ g: ProcGeo, ms: Double, cached: Bool, warnings: [String]) {
        var i = ProcNodeInfo(milliseconds: ms, cached: cached, error: nil, warnings: warnings,
                             points: g.pointCount, vertices: g.vertexCount, prims: g.primCount)
        for c in AttributeClass.allCases {
            let t = g.table(c)
            i.attributes[c] = (c == .point ? [("P", AttributeType.vector3)] : []) + t.attributes.map { ($0.name, $0.values.type) }
            if !t.groups.isEmpty { i.groups[c] = t.groupNames }
        }
        info[id] = i
    }

    /// Drops the least recently used outputs (not this cook's) past the budget.
    private func trim() {
        guard bytes > budget else { return }
        let old = cache.filter { $0.value.used < tick }.sorted { $0.value.used < $1.value.used }
        for (k, e) in old where bytes > budget {
            cache[k] = nil
            bytes -= e.bytes
        }
    }
}

/// One node's cook: its parameters, its inputs' geometry, and the warnings it leaves.
package struct ProcCook {
    package let node: ProcNode
    package var inputs: [ProcGeo?]
    package var warnings: [String] = []
    package let environment: ProcEnvironment
    /// The parameters whose expressions the cooker evaluated (the rest are as set).
    package var resolved: [String: ProcParam] = [:]
    /// The node's expressions, for the parameters that vary per element.
    package var expressions: ProcExprContext?

    package init(node: ProcNode, inputs: [ProcGeo?], environment: ProcEnvironment) {
        self.node = node
        self.inputs = inputs
        self.environment = environment
    }

    package func param(_ name: String) -> ProcParam { resolved[name] ?? node.param(name) }

    /// A per-element parameter's value for each element of class `c` of `geo` (nil: it doesn't vary, `param` stands).
    package func elementValues(_ name: String, in geo: ProcGeo, _ c: AttributeClass) throws -> [SIMD4<Float>]? {
        guard let x = expressions, let spec = node.spec.param(name), spec.perElement else { return nil }
        return try x.elementValues(spec, over: ProcExprElements(geo, c))
    }
    package func float(_ name: String) -> Float { param(name).float }
    package func int(_ name: String) -> Int { param(name).int }
    package func bool(_ name: String) -> Bool { param(name).bool }
    package func vec2(_ name: String) -> SIMD2<Float> { param(name).vec2 }
    package func vec3(_ name: String) -> SIMD3<Float> { param(name).vec3 }
    package func vec4(_ name: String) -> SIMD4<Float> { param(name).vec4 }
    package func string(_ name: String) -> String { param(name).string }

    /// Input `i`'s geometry, or an error naming it if nothing is wired there.
    package func input(_ i: Int = 0) throws -> ProcGeo {
        guard i < inputs.count, let g = inputs[i] else {
            let inputs = node.spec.inputs
            let label = i < inputs.count ? inputs[i] : "\(i + 1)"
            throw ProcCookError("Input \(i + 1) (\(label)) isn't connected")
        }
        return g
    }

    /// The class a menu parameter names (`class`, `grouptype`: "points" / "primitives" too).
    package func attributeClass(_ name: String = "class") -> AttributeClass {
        switch string(name) {
        case "points", "point": .point
        case "primitives", "primitive", "prims": .primitive
        case "vertices", "vertex": .vertex
        case "detail": .detail
        default: .point
        }
    }

    /// What a group field picks of class `c`.
    package func group(_ name: String = "group", in geo: ProcGeo, _ c: AttributeClass) throws -> [Bool] {
        try GroupPattern.evaluate(string(name), in: geo, c)
    }

    package mutating func warn(_ message: String) { warnings.append(message) }
}
