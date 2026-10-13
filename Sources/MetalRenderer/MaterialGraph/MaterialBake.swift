import Foundation
import Metal
import QuartzCore

/// The renderer's side of the material graphs: bakes the graphs a scene's procedural materials name (Scene+Procedural)
/// into the textures the renderer puts in their slots (Renderer.applyProcedural). One engine per device, which the
/// Material Designer shares: a graph the editor has just baked is baked again here from its cache (nothing new).
/// A graph is known by its key (its JSON's hash): a bake is asked for once per key, and the last few are kept.
final class MaterialBake {
    private static let lock = NSLock()
    private static var made: [ObjectIdentifier: MaterialBake] = [:]

    /// The device's.
    static func shared(_ device: MTLDevice) -> MaterialBake {
        lock.lock(); defer { lock.unlock() }
        if let b = made[ObjectIdentifier(device)] { return b }
        let b = MaterialBake(device: device)
        made[ObjectIdentifier(device)] = b
        return b
    }

    let engine: MatEngine
    private let lock = NSLock()
    private var outputs: [String: MatOutputs] = [:]
    private var order: [String] = []
    private var asked: Set<String> = []
    private var failures: [String: String] = [:]

    init(device: MTLDevice) { engine = MatEngine(device: device) }

    /// A graph's key: what its bake depends on (the graph, and its subgraphs as `catalog` has them).
    static func key(_ graph: MaterialGraph, catalog: MaterialCatalog) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var h = Hasher64()
        h.add(String(data: (try? encoder.encode(graph)) ?? Data(), encoding: .utf8) ?? "")
        for n in graph.nodes where n.kind == .subgraph {
            if let sub = catalog.graph(n.text("graph")) { h.add(key(sub, catalog: catalog)) }
        }
        return String(h.value, radix: 36)
    }

    /// `key`'s textures, if they are baked.
    func baked(_ key: String) -> MatOutputs? {
        lock.lock(); defer { lock.unlock() }
        return outputs[key]
    }

    /// Why `key`'s bake failed, if it did.
    func failure(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return failures[key]
    }

    /// Bakes `graph` under `key` in the background (once a key), then calls `done` on the main thread.
    func request(_ graph: MaterialGraph, key: String, catalog: MaterialCatalog, done: @escaping () -> Void) {
        lock.lock()
        guard outputs[key] == nil, asked.insert(key).inserted else { lock.unlock(); return }
        lock.unlock()
        guard let plan = plan(graph, key: key, catalog: catalog) else { return }
        engine.evaluate(plan) { [self] result in
            keep(key, result)
            done()
        }
    }

    /// Bakes `graph` now (benchmarks: a scene's first frame has its materials).
    @discardableResult
    func bakeNow(_ graph: MaterialGraph, key: String, catalog: MaterialCatalog) -> MatOutputs? {
        if let o = baked(key) { return o }
        guard let plan = plan(graph, key: key, catalog: catalog) else { return nil }
        let start = CACurrentMediaTime()
        let result = engine.evaluateNow(plan)
        keep(key, result)
        print(String(format: "Materials: %@ baked in %.0f ms (GPU %.1f ms, %d of %d nodes, %d px)%@", graph.name, (CACurrentMediaTime() - start) * 1000,
                     result.gpuMilliseconds, result.baked, plan.steps.count, 1 << plan.size,
                     result.errors.isEmpty ? "" : ": \(result.errors)"))
        return result.outputs
    }

    /// What the Material Designer baked as it edits (its result is this key's bake).
    func adopt(_ result: MatResult, key: String) { keep(key, result) }

    private func plan(_ graph: MaterialGraph, key: String, catalog: MaterialCatalog) -> MatPlan? {
        do {
            return try MatPlan(graph, library: { catalog.graph($0) })
        } catch {
            lock.lock()
            failures[key] = "\(error)"
            lock.unlock()
            print("Materials: \(graph.name) doesn't bake: \(error)")
            return nil
        }
    }

    private func keep(_ key: String, _ result: MatResult) {
        lock.lock(); defer { lock.unlock() }
        outputs[key] = result.outputs
        if !result.errors.isEmpty { failures[key] = result.errors.map { "\($0.key): \($0.value)" }.joined(separator: "; ") }
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 16 { let gone = order.removeFirst(); outputs[gone] = nil; asked.remove(gone) }
    }
}
