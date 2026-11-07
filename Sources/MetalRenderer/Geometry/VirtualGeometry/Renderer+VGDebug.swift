import EngineCore
import Foundation
import Metal
import simd

/// Virtual geometry as the Debug window, the `vg_stats` / `vg_set` tools and the VG lab's benchmark read and drive it.
/// Render thread (or inside `perform`), like the rest of the renderer's state.
package struct VGReport {
    package var summary = ""
    package var meshes = 0, instances = 0
    package var sourceTriangles = 0, triangles = 0, clusters = 0
    package var megabytes = 0.0, rebuilds = 0, lastBuildMs = 0.0, lastCutMs = 0.0, skipped = 0
    package var busy = false
    package var pixelError: Float = 1
    package var frozen = false
    package var waitRule = true
    package var rows: [VirtualBLAS.InstanceStats] = []
    package var meshNames: [String] = []
    package var residency: [Float] = []                     // per mesh: share of its cache pages in memory
    package var history: [VirtualBLAS.HistorySample] = []   // oldest first
    /// What the crosshair's pixel hit, while a geometry debug view is drawn (nil otherwise, or nothing virtual there).
    package var probe: GPUVGProbe?

    /// As JSON (vg_stats, the benchmark's vglab.json). `rows`: at most this many instances, nearest first.
    package func json(rows limit: Int = 64, history historyLimit: Int = 120) -> [String: Any] {
        func r(_ x: Double, _ digits: Double = 1000) -> Double { (x * digits).rounded() / digits }
        let nearest = rows.sorted { $0.distance < $1.distance }.prefix(limit)
        var out: [String: Any] = [
            "summary": summary, "meshes": meshes, "instances": instances, "sourceTriangles": sourceTriangles,
            "triangles": triangles, "clusters": clusters, "megabytes": r(megabytes), "rebuilds": rebuilds,
            "lastBuildMs": r(lastBuildMs), "lastCutMs": r(lastCutMs), "skipped": skipped, "busy": busy,
            "pixelError": Double(pixelError), "frozen": frozen, "waitRule": waitRule,
            "residency": zip(meshNames, residency).map { ["mesh": $0.0, "resident": r(Double($0.1))] },
            "rows": nearest.map { s -> [String: Any] in
                ["instance": s.instance, "mesh": s.name, "distance": r(Double(s.distance)), "clusters": s.clusters,
                 "triangles": s.triangles, "finestTriangles": s.finestTriangles, "minLevel": s.minLevel,
                 "maxLevel": s.maxLevel, "waited": s.waited, "slack": s.slack.isFinite ? r(Double(s.slack)) : -1,
                 "rebuilds": s.rebuilds, "rebuiltFrame": Int(s.rebuiltFrame), "bytes": s.bytes,
                 "gatherMs": r(s.gatherMs), "faults": s.faults, "watertight": s.watertight]
            },
            "history": history.suffix(historyLimit).map {
                ["cutMs": r(Double($0.cutMs)), "rebuilds": Int($0.rebuilds), "triangles": Int($0.triangles),
                 "megabytes": r(Double($0.megabytes))]
            },
        ]
        if let p = probe {
            out["probe"] = ["instance": Int(p.ids.x), "cluster": Int(p.ids.y), "group": Int(p.ids.z), "level": Int(p.ids.w),
                            "ownErrorPx": p.errors.x.isFinite ? r(Double(p.errors.x)) : -1,
                            "parentErrorPx": p.errors.y.isFinite ? r(Double(p.errors.y)) : -1,
                            "distance": r(Double(p.errors.z)), "backFace": p.errors.w > 0.5]
        }
        return out
    }
}

extension Renderer {
    /// Virtual geometry's state now; nil when the scene has none.
    package func vgReport() -> VGReport? {
        guard let vt = virtualTracing else { return nil }
        let vg = vt.blas
        var r = VGReport()
        r.summary = vg.summary
        r.meshes = vg.meshCount
        r.instances = vg.instanceCount
        r.sourceTriangles = vg.sourceTriangles
        r.triangles = vg.stats.triangles
        r.clusters = vg.stats.clusters
        r.megabytes = vg.stats.megabytes
        r.rebuilds = vg.stats.rebuilds
        r.lastBuildMs = vg.stats.lastBuildMs
        r.lastCutMs = vg.stats.lastCutMs
        r.skipped = vg.stats.skippedInstances
        r.busy = vg.isBusy
        r.pixelError = settings.virtualGeometry.pixelError
        r.frozen = frozenLOD != nil
        r.waitRule = settings.virtualGeometry.waitRule
        r.rows = vg.instanceStats(camPos: vgDebugView?.camPos ?? camera.position, sceneInstances: scene.instances)
        r.meshNames = scene.virtualMeshNames
        r.residency = (0..<vg.meshCount).map { vg.residency(mesh: $0) }
        r.history = vg.history
        if RenderSettings.drawsGeometryDebug(settings.viewMode), let b = vgProbe {
            let p = b.contents().load(as: GPUVGProbe.self)
            if p.ids.x != .max { r.probe = p }
        }
        return r
    }

    /// The next cut of every virtual instance is made afresh (as if nothing were known of the last).
    package func vgForceRecut() { virtualTracing?.blas.forceRecut() }

    /// Drops the cache pages of the virtual meshes whose names contain `match` (all of them if nil) and cuts every
    /// instance afresh: their next BLASes read them from disk. The meshes' residency after, by name.
    @discardableResult
    package func vgEvict(matching match: String? = nil) -> [(mesh: String, resident: Float)] {
        guard let vg = virtualTracing?.blas else { return [] }
        let names = scene.virtualMeshNames
        let chosen = names.indices.filter { m in match.map { names[m].lowercased().contains($0.lowercased()) } ?? true }
        for m in chosen { vg.evict(mesh: m) }
        return chosen.map { (names[$0], vg.residency(mesh: $0)) }
    }
}
