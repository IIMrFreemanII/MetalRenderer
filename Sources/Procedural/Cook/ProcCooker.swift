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
/// stamp that changes when that geometry does (part of the node's cook key).
package struct ProcEnvironment {
    package var file: (String) -> ProcGeo?
    package var stamp: (String) -> UInt64

    package init(file: @escaping (String) -> ProcGeo?, stamp: @escaping (String) -> UInt64) {
        self.file = file
        self.stamp = stamp
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

    package static func == (a: ProcNodeInfo, b: ProcNodeInfo) -> Bool {
        a.milliseconds == b.milliseconds && a.cached == b.cached && a.error == b.error && a.warnings == b.warnings
            && a.points == b.points && a.vertices == b.vertices && a.prims == b.prims && a.groups == b.groups
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

    private struct Entry { var geo: ProcGeo; var bytes: Int; var used: UInt64 }
    private var cache: [UInt64: Entry] = [:]
    private var bytes = 0
    private var tick: UInt64 = 0
    /// The last cook's report per node id (of the nodes it reached).
    package private(set) var info: [String: ProcNodeInfo] = [:]

    /// Bumped when a node's cook changes, so outputs cooked before aren't taken for the new ones'.
    package static let version = 1

    package init(environment: ProcEnvironment = .assets) { self.environment = environment }

    /// Forgets every kept output.
    package func clear() {
        cache.removeAll()
        bytes = 0
    }

    package var cachedBytes: Int { bytes }

    /// One cook: its keys and outputs by node, so a node two others read cooks once.
    private struct Pass {
        let graph: ProcGraph
        var keys: [String: UInt64] = [:]
        var geos: [String: ProcGeo] = [:]
        var visiting: Set<String> = []
        let cancelled: () -> Bool
    }

    /// Node `id`'s geometry (cooking what it needs), or why it can't be had. `cancelled` is asked between nodes: a
    /// cook a newer edit made stale stops there.
    package func cook(_ graph: ProcGraph, _ id: String, cancelled: @escaping () -> Bool = { false }) -> Result<ProcGeo, ProcCookError> {
        var pass = Pass(graph: graph, cancelled: cancelled)
        tick += 1
        do {
            let g = try geometry(id, &pass)
            trim()
            return .success(g)
        } catch let e as ProcCookError {
            trim()
            return .failure(e)
        } catch {
            return .failure(ProcCookError("\(error)", node: id))
        }
    }

    /// Node `id`'s cook key.
    package func key(_ graph: ProcGraph, _ id: String) -> UInt64? {
        var pass = Pass(graph: graph, cancelled: { false })
        return try? key(id, &pass)
    }

    // MARK: Keys

    private func key(_ id: String, _ pass: inout Pass) throws -> UInt64 {
        if let k = pass.keys[id] { return k }
        guard let node = pass.graph.node(id) else { throw ProcCookError("no node \(id)", node: id) }
        guard !pass.visiting.contains(id) else { throw ProcCookError("the network loops through \(node.name)", node: id) }
        pass.visiting.insert(id)
        defer { pass.visiting.remove(id) }
        let inputs = pass.graph.inputs(of: id)
        var h = Hasher64()
        if node.bypass {
            // A bypassed node is its first input.
            let k = try inputs.first.flatMap { $0 }.map { try key($0, &pass) } ?? Hasher64().value
            pass.keys[id] = k
            return k
        }
        h.add(ProcCooker.version)
        h.add(node.kind.rawValue)
        for s in node.kind.spec.params {
            h.add(s.name)
            node.param(s.name).hash(into: &h)
        }
        if node.kind == .switchnode {
            let pick = ProcCook.switchIndex(node, inputs.count)
            h.add(pick ?? -1)
            if let i = pick, let up = inputs[i] { h.add(try key(up, &pass)) }
        } else {
            for i in inputs {
                if let i { h.add(try key(i, &pass)) } else { h.add(0) }
            }
        }
        if node.kind == .file { h.add(environment.stamp(node.param("file").string)) }
        pass.keys[id] = h.value
        return h.value
    }

    // MARK: Cooking

    private func geometry(_ id: String, _ pass: inout Pass) throws -> ProcGeo {
        if let g = pass.geos[id] { return g }
        let k = try key(id, &pass)
        guard let node = pass.graph.node(id) else { throw ProcCookError("no node \(id)", node: id) }
        if var e = cache[k] {
            e.used = tick
            cache[k] = e
            record(id, e.geo, ms: 0, cached: true, warnings: info[id]?.warnings ?? [])
            pass.geos[id] = e.geo
            return e.geo
        }
        if pass.cancelled() { throw ProcCookError.cancelled }
        let inputIDs = pass.graph.inputs(of: id)
        if node.bypass {
            let g = try inputIDs.first.flatMap { $0 }.map { try geometry($0, &pass) } ?? ProcGeo()
            pass.geos[id] = g
            record(id, g, ms: 0, cached: false, warnings: [])
            return g
        }
        // The inputs (a Switch: only the one it passes).
        var inputs = [ProcGeo?](repeating: nil, count: inputIDs.count)
        let pick = node.kind == .switchnode ? ProcCook.switchIndex(node, inputIDs.count) : nil
        for (i, up) in inputIDs.enumerated() {
            guard let up, node.kind != .switchnode || i == pick else { continue }
            do {
                inputs[i] = try geometry(up, &pass)
            } catch let e as ProcCookError where e != .cancelled {
                info[id] = ProcNodeInfo(error: "Input \(i + 1) has an error")
                throw e
            }
        }
        var c = ProcCook(node: node, inputs: inputs, environment: environment)
        let start = DispatchTime.now().uptimeNanoseconds
        let g: ProcGeo
        do {
            g = try node.kind.cook(&c)
        } catch let e as ProcCookError {
            info[id] = ProcNodeInfo(error: e.message)
            throw ProcCookError(e.message, node: id)
        } catch let e as GroupPattern.Failure {
            info[id] = ProcNodeInfo(error: e.description)
            throw ProcCookError(e.description, node: id)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        #if DEBUG
        if let problem = g.validate() { assertionFailure("\(node.kind.rawValue) made bad geometry: \(problem)") }
        #endif
        let size = g.byteSize
        cache[k] = Entry(geo: g, bytes: size, used: tick)
        bytes += size
        pass.geos[id] = g
        record(id, g, ms: ms, cached: false, warnings: c.warnings)
        return g
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

    package init(node: ProcNode, inputs: [ProcGeo?], environment: ProcEnvironment) {
        self.node = node
        self.inputs = inputs
        self.environment = environment
    }

    package func param(_ name: String) -> ProcParam { node.param(name) }
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
            let label = i < node.kind.spec.inputs.count ? node.kind.spec.inputs[i] : "\(i + 1)"
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

    /// The input a Switch passes, clamped to its inputs (nil without inputs).
    static func switchIndex(_ node: ProcNode, _ count: Int) -> Int? {
        count == 0 ? nil : min(max(0, node.param("input").int), count - 1)
    }

    package mutating func warn(_ message: String) { warnings.append(message) }
}
