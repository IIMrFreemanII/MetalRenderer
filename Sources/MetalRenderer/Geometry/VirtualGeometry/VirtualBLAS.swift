import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Metal
import Physics
import Plants
import simd

/// Virtual geometry, ray-tracing friendly: the Nanite cut through each virtual mesh's cluster DAG is evaluated on the
/// CPU, and every instance whose cut changed gets a fresh BLAS over exactly the cut's triangles, made in the background
/// from the memory-mapped cache (the OS streams the pages it touches from disk; they are prefetched with madvise first):
/// the triangles are gathered into a buffer, and Metal builds its structure over them on a queue of its own. The top-level
/// structure has each virtual instance at its current BLAS (VirtualTracing).
///
/// GPU memory holds only the current cuts: about one triangle per traced pixel at the default error of 1 px.
package final class VirtualBLAS {
    /// Per VG instance on the GPU (MSL `VGBlas`): its current cut's triangles (p0 p1 p2 as float4s, the debug views'
    /// IDs in p1.w and p2.w; the BLAS is built over them), then per triangle 6 words of attributes: 3 octahedral
    /// normals, 3 half2 UVs. A hit's primitive is a triangle's place there. The rest is for the debug views: the
    /// frame its BLAS was swapped in, its mesh's cluster records (`VGClusterInfo`, by cluster) and `flagWatertight`.
    struct Entry {
        package var tris: UInt64 = 0
        package var attrs: UInt64 = 0
        package var triangles: UInt32 = 0
        package var rebuiltFrame: UInt32 = 0
        package var clusterInfo: UInt64 = 0
        package var flags: UInt32 = 0
        package var pad0: UInt32 = 0
        package var pad1: UInt32 = 0
        package var pad2: UInt32 = 0
    }
    static let flagWatertight: UInt32 = 1

    /// A cluster as the debug views read it (MSL `VGClusterInfo`): its bounding sphere and error, its parents' (the
    /// group's) sphere and error (infinity for a root), and its DAG level.
    struct ClusterInfo {
        var selfSphere = SIMD4<Float>()
        var parentSphere = SIMD4<Float>()
        var selfError: Float = 0
        var parentError: Float = 0
        var level: UInt32 = 0
        var pad: UInt32 = 0
    }

    /// The wait rule (`buildsNow`): a changed cut waits while under `share` of its triangles differ, for at most
    /// `passes` of the worker's passes. nil: every changed cut is built at once.
    struct Wait: Equatable {
        var share: Float = VirtualBLAS.waitShare
        var passes: Int = VirtualBLAS.waitPasses
    }

    /// One virtual instance as the Debug window's table and `vg_stats` show it.
    package struct InstanceStats {
        package var instance = 0                 // the scene's instance index
        package var mesh = 0
        package var name = ""
        package var distance: Float = 0          // camera to the mesh's bounds' centre (world)
        package var clusters = 0                 // in the cut
        package var triangles = 0                // in the cut
        package var finestTriangles = 0          // the mesh's finest level
        package var minLevel = 0, maxLevel = 0   // DAG levels in the cut (0 = finest)
        package var waited = 0                   // passes a changed cut has waited (the wait rule)
        package var slack: Float = 0             // how far the camera can move before the cut could change
        package var rebuilds = 0
        package var rebuiltFrame: UInt32 = 0
        package var bytes = 0                    // triangle buffer + BLAS
        package var gatherMs = 0.0               // the last gather
        package var faults = 0                   // major page faults in the last build's pass (all instances built in it)
        package var watertight = false
    }

    /// One frame of the history graph: the last cut's time, BLASes swapped in this frame, triangles and MB.
    package struct HistorySample {
        package var cutMs: Float = 0
        package var rebuilds: UInt16 = 0
        package var triangles: UInt32 = 0
        package var megabytes: Float = 0
    }
    static let historyLength = 512

    /// Cuts and builds on the calling thread (deterministic): benchmarks, or METALRENDERER_VG_SYNC=1; =0 forces the
    /// background path even in benchmarks.
    static let sync: Bool = {
        let env = ProcessInfo.processInfo.environment["METALRENDERER_VG_SYNC"]
        return env == "1" || (Benchmark.isEnabled && env != "0")
    }()
    /// A changed cut waits while under this share of its triangles differ, for at most this many of the worker's passes:
    /// every cut is free of cracks, so one a little out of date only has slightly the wrong detail, and a BLAS and the
    /// top-level structure over it aren't built for a few clusters.
    static let waitShare: Float = 0.1
    static let waitPasses = 16

    /// Triangles in one of two cuts of `mesh` but not the other (both in ascending order, as `selection` makes them).
    static func changedTriangles(mesh: VirtualMesh, from a: [UInt32], to b: [UInt32]) -> Int {
        var i = 0, j = 0, changed = 0
        while i < a.count || j < b.count {
            if j == b.count || (i < a.count && a[i] < b[j]) {
                changed += Int(mesh.clusters[Int(a[i])].triangles)
                i += 1
            } else if i == a.count || b[j] < a[i] {
                changed += Int(mesh.clusters[Int(b[j])].triangles)
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return changed
    }

    /// Whether a cut with `changed` of its `triangles` different is built now, having waited `waited` passes.
    static func buildsNow(changed: Int, triangles: Int, waited: Int, wait: Wait? = Wait()) -> Bool {
        guard let wait else { return true }
        return waited >= wait.passes || Float(changed) >= wait.share * Float(triangles)
    }

    /// What an instance's last cut was made for, and how far the camera can move before any of its tests could change.
    private struct CutInput {
        var transform: float4x4
        var camPos: SIMD3<Float>
        var pixelScale: Float
        var tau: Float
        var slack: Float
    }

    /// An instance's cut as built: its triangles' buffer, Metal's structure over them, and what the GPU reads.
    private struct Built {
        package var buffer: MTLBuffer?
        package var structure: MTLAccelerationStructure?
        package var entry = Entry()
        package var selection: [UInt32] = []
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue                   // the builds: off the frames' queue, which would wait behind them
    private let meshes: [VirtualMesh]
    private let instances: [(instance: Int, mesh: Int)]
    private var tables: [MTLBuffer] = []                 // per slot: Entry per VG instance
    private var current: [Built]
    private var retired: [(Built, UInt32)] = []          // recycled once the GPU is past that frame
    private var released: [MTLResource] = []             // retired ones the GPU is past, for `takeReleased`
    private var freeBuffers: [MTLBuffer] = []            // recycled triangle buffers, oldest first (under `lock`)
    private var scratch: MTLBuffer?                      // the worker's, for the builds
    private let worker = DispatchQueue(label: "metalrenderer.vg.blas", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var finished: [(index: Int, built: Built)] = []
    private var workerSelection: [[UInt32]]              // the worker's own copy of what it last built
    private var lastCut: [CutInput?]                     // the worker's
    private var waited: [Int]                            // the worker's: passes a changed cut has waited
    private var started = false
    private var gatherMs: [Double] = []                  // the worker's: the last build's gathers
    private var recutAll = false                         // under `lock`: the next pass cuts every instance again
    private var workerStats: [InstanceStats]             // the worker's (under `lock` when read)
    private let names: [String]
    private let watertight: Set<Int>
    private let clusterInfo: [MTLBuffer?]                // per mesh: ClusterInfo per cluster, for the debug views
    private var historyRing = [HistorySample](repeating: HistorySample(), count: VirtualBLAS.historyLength)
    private var historyNext = 0
    /// Bumped whenever an instance's structure changes: the top-level structure is rebuilt over the new ones.
    private(set) var version = 0
    private(set) var stats = (triangles: 0, clusters: 0, rebuilds: 0, lastBuildMs: 0.0, megabytes: 0.0, lastCutMs: 0.0,
                              skippedInstances: 0)

    package init(device: MTLDevice, meshes: [VirtualMesh], instances: [(instance: Int, mesh: Int)], slots: Int,
                 names: [String] = [], watertight: Set<Int> = []) throws {
        guard let queue = device.makeCommandQueue() else { throw RendererError.resourceCreation("command queue (virtual geometry)") }
        queue.label = "vgBLAS"
        self.device = device
        self.queue = queue
        self.meshes = meshes
        self.instances = instances
        current = Array(repeating: Built(), count: instances.count)
        workerSelection = Array(repeating: [], count: instances.count)
        lastCut = Array(repeating: nil, count: instances.count)
        waited = Array(repeating: 0, count: instances.count)
        self.names = names
        self.watertight = watertight
        workerStats = instances.map { p in
            InstanceStats(instance: p.instance, mesh: p.mesh, name: p.mesh < names.count ? names[p.mesh] : "mesh \(p.mesh)",
                          finestTriangles: meshes[p.mesh].triangleCount, watertight: watertight.contains(p.mesh))
        }
        clusterInfo = meshes.enumerated().map { m, mesh in
            let info = mesh.clusters.map { c in
                ClusterInfo(selfSphere: c.selfSphere, parentSphere: c.parentSphere, selfError: c.lo.w, parentError: c.hi.w,
                            level: mesh.groups[Int(c.group)].level)
            }
            let buffer = info.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared) }
            buffer?.label = "vgClusterInfo\(m)"
            return buffer
        }
        for slot in 0..<slots {
            guard let t = device.makeBuffer(length: max(instances.count, 1) * MemoryLayout<Entry>.stride, options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer vgBlasTable")
            }
            t.label = "vgBlasTable\(slot)"
            memset(t.contents(), 0, t.length)
            tables.append(t)
        }
        print("Virtual geometry (per-instance BLAS): \(meshes.count) meshes, \(instances.count) instances, "
              + "\(meshes.reduce(0) { $0 + $1.clusters.count }) clusters")
    }

    var meshCount: Int { meshes.count }
    var instanceCount: Int { instances.count }
    /// Triangles at the finest level, over every instance (what drawing without LOD would trace).
    var sourceTriangles: Int { instances.reduce(0) { $0 + meshes[$1.mesh].triangleCount } }
    /// The worker is computing a cut or building BLASes.
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    func table(slot: Int) -> MTLBuffer { tables[slot] }
    func resources(slot: Int) -> [MTLResource] {
        [tables[slot]] + current.compactMap(\.buffer) + current.compactMap(\.structure) + clusterInfo.compactMap { $0 }
    }
    /// Each virtual instance's current structure (nil: none yet, or an empty cut), in their rank.
    var structures: [MTLAccelerationStructure?] { current.map(\.structure) }

    var summary: String {
        String(format: "VG: %d triangles in %d clusters, %.0f MB of triangles and BLAS, %d rebuilds (last %.1f ms), cut %.1f ms (%d of %d instances skipped)",
               stats.triangles, stats.clusters, stats.megabytes, stats.rebuilds, stats.lastBuildMs, stats.lastCutMs,
               stats.skippedInstances, instances.count)
    }

    /// The structures and triangle buffers retired since the last call that no frame in flight uses any more (a recycled
    /// buffer comes back when a frame binds it again): a Metal 4 frame lets them out of its residency set
    /// (`FrameEncoder.release`), which a camera move would otherwise fill with thousands of them.
    func takeReleased() -> [MTLResource] {
        defer { released.removeAll() }
        return released
    }

    /// Render thread, before encoding `frame`: swap in finished BLASes, then start the next cut if the worker is free.
    /// `sceneInstances`: every scene instance, for this frame's object -> world matrices.
    func update(frame: UInt32, slot: Int, framesInFlight: Int, camPos: SIMD3<Float>, pixelScale: Float,
                tau: Float, wait: Wait? = Wait(), sceneInstances: [Scene.Instance]) {
        // Buffers the GPU is done with go back to the pool (frames finish in order), which keeps about as many bytes as
        // the current BLASes, dropping the oldest beyond that.
        let past = retired.filter { $0.1 &+ UInt32(framesInFlight) < frame }.map(\.0)
        let done = past.compactMap(\.buffer)
        retired.removeAll { $0.1 &+ UInt32(framesInFlight) < frame }
        released += done as [MTLResource] + past.compactMap(\.structure)
        if !done.isEmpty {
            let keep = current.reduce(0) { $0 + ($1.buffer?.length ?? 0) }
            lock.lock()
            freeBuffers += done
            var bytes = freeBuffers.reduce(0) { $0 + $1.length }
            while bytes > keep, !freeBuffers.isEmpty { bytes -= freeBuffers.removeFirst().length }
            lock.unlock()
        }
        let snapshot = instances.map { sceneInstances[$0.instance].transform }
        let job = { [self] in self.cut(camPos: camPos, pixelScale: pixelScale, tau: tau, wait: wait, transforms: snapshot) }
        if VirtualBLAS.sync || !started {
            started = true
            job()   // benchmarks (deterministic: the cut matches this frame's camera), and the first frame (no pop-in)
        } else {
            lock.lock()
            let start = !busy
            if start { busy = true }
            lock.unlock()
            if start { worker.async { job(); self.lock.lock(); self.busy = false; self.lock.unlock() } }
        }
        lock.lock()
        let finishedNow = finished
        finished.removeAll()
        lock.unlock()
        for f in finishedNow {
            retired.append((current[f.index], frame))
            current[f.index] = f.built
            current[f.index].entry.rebuiltFrame = frame
        }
        if !finishedNow.isEmpty { version += 1 }
        var bytes = 0, triangles = 0
        for c in current {
            bytes += (c.buffer?.length ?? 0) + (c.structure?.size ?? 0)
            triangles += Int(c.entry.triangles)
        }
        stats.megabytes = Double(bytes) / 1_048_576
        stats.triangles = triangles
        stats.clusters = current.reduce(0) { $0 + $1.selection.count }
        historyRing[historyNext] = HistorySample(cutMs: Float(stats.lastCutMs), rebuilds: UInt16(min(finishedNow.count, 65535)),
                                                 triangles: UInt32(triangles), megabytes: Float(stats.megabytes))
        historyNext = (historyNext + 1) % VirtualBLAS.historyLength
        current.map(\.entry).withUnsafeBytes { tables[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    // MARK: Debugging (the Debug window, vg_stats, the VG lab)

    /// The next pass cuts every instance again, as if nothing were known of the last cuts.
    func forceRecut() {
        lock.lock()
        recutAll = true
        lock.unlock()
    }

    /// Every virtual instance as it stands, its distance from `camPos` (render thread: `sceneInstances` this frame's).
    func instanceStats(camPos: SIMD3<Float>, sceneInstances: [Scene.Instance]) -> [InstanceStats] {
        lock.lock()
        var out = workerStats
        lock.unlock()
        for k in out.indices {
            let b = meshes[instances[k].mesh].bounds
            let c = sceneInstances[instances[k].instance].transform * SIMD4<Float>(b.centroid, 1)
            out[k].distance = length(SIMD3(c.x, c.y, c.z) - camPos)
            out[k].rebuiltFrame = current[k].entry.rebuiltFrame
            out[k].bytes = (current[k].buffer?.length ?? 0) + (current[k].structure?.size ?? 0)
            // What is swapped in, rather than the worker's newest (which may still be building).
            out[k].clusters = current[k].selection.count
            out[k].triangles = Int(current[k].entry.triangles)
        }
        return out
    }

    /// The last `historyLength` frames, oldest first.
    var history: [HistorySample] { Array(historyRing[historyNext...] + historyRing[..<historyNext]) }

    /// The share of `mesh`'s cache pages in memory now (mincore over its mapping).
    func residency(mesh m: Int) -> Float {
        let (resident, total) = VirtualBLAS.pages(of: meshes[m].pageData) { base, length in
            let pageSize = Int(vm_page_size)
            var vec = [CChar](repeating: 0, count: (length + pageSize - 1) / pageSize)
            guard mincore(base, length, &vec) == 0 else { return 0 }
            return vec.reduce(0) { $0 + (($1 & 1) != 0 ? 1 : 0) }
        }
        return total == 0 ? 0 : Float(resident) / Float(total)
    }

    /// Asks the OS to drop `mesh`'s cache pages from memory (best effort: MS_INVALIDATE then MADV_DONTNEED over its
    /// mapping; the file is clean, so they can go), and cuts every instance again once they are gone, so their next
    /// gathers read them from disk. `residency` tells whether they went.
    func evict(mesh m: Int) {
        _ = VirtualBLAS.pages(of: meshes[m].pageData) { base, length in
            msync(base, length, MS_INVALIDATE)
            madvise(base, length, MADV_DONTNEED)
            return 0
        }
        forceRecut()
    }

    /// `body` over the OS pages that `data`'s bytes lie on (base aligned down, length rounded up); the page count.
    private static func pages(of data: Data, _ body: (UnsafeMutableRawPointer, Int) -> Int) -> (Int, Int) {
        data.withUnsafeBytes { raw in
            guard let start = raw.baseAddress, raw.count > 0 else { return (0, 0) }
            let pageSize = Int(vm_page_size)
            let aligned = Int(bitPattern: start) & ~(pageSize - 1)
            let length = Int(bitPattern: start) + raw.count - aligned
            let pages = (length + pageSize - 1) / pageSize
            return (body(UnsafeMutableRawPointer(bitPattern: aligned)!, length), pages)
        }
    }

    /// The process's major page faults so far (getrusage): pages read from disk.
    static func majorFaults() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_majflt)
    }

    /// Nanite's rule without residency (every page is readable), over `groups` of `mesh`: a cluster is in the cut when
    /// its group's simplification is too coarse on screen and its own error is fine enough (or it is at the finest
    /// level). A group's clusters share the first test, so it is made once per group.
    ///
    /// `slack`: how far the camera can move before any test made here could turn out differently. Each test
    /// "projected error <= tau" is "distance to the sphere >= error x scale x pixelScale / tau", and that distance
    /// changes at most as much as the camera moves.
    static func selection(mesh: VirtualMesh, groups: Range<Int>, transform m: float4x4, camPos: SIMD3<Float>,
                          pixelScale: Float, tau: Float) -> (selection: [UInt32], slack: Float) {
        let scale = max(length(SIMD3(m[0].x, m[0].y, m[0].z)), length(SIMD3(m[1].x, m[1].y, m[1].z)), length(SIMD3(m[2].x, m[2].y, m[2].z)))
        var slack = Float.infinity
        func fineEnough(_ s: SIMD4<Float>, _ error: Float) -> Bool {
            let c = m * SIMD4<Float>(s.x, s.y, s.z, 1)
            let d = length(SIMD3(c.x, c.y, c.z) - camPos) - s.w * scale
            slack = min(slack, abs(d - max(error * scale * pixelScale / tau, 1e-4)))
            return d > 1e-4 && error * scale * pixelScale / d <= tau
        }
        var out: [UInt32] = []
        mesh.clusters.withUnsafeBufferPointer { clusters in
            for g in groups {
                let grp = mesh.groups[g]
                let first = Int(grp.clusterStart), end = first + Int(grp.clusterCount)
                guard first < end else { continue }
                let shared = clusters[first]   // every cluster of a group has the group's sphere and error as its parent's
                if shared.hi.w != .infinity && fineEnough(shared.parentSphere, shared.hi.w) { continue }   // coarser is enough
                for ci in first..<end {
                    let c = clusters[ci]
                    if c.childGroup != .max && !fineEnough(c.selfSphere, c.lo.w) { continue }   // the finer clusters instead
                    out.append(UInt32(ci))
                }
            }
        }
        return (out, slack)
    }

    /// Worker: the cut for every instance whose cut could have changed (in parallel, in ranges of groups), then a new
    /// BLAS for each instance whose cut did change (in parallel), after asking the OS to read their pages ahead.
    private func cut(camPos: SIMD3<Float>, pixelScale: Float, tau: Float, wait: Wait?, transforms: [float4x4]) {
        let start = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if recutAll { lastCut = Array(repeating: nil, count: instances.count) }
        recutAll = false
        lock.unlock()
        // An instance with the same transform and error settings, whose camera hasn't moved as far as its slack, keeps
        // its cut (0.99: margin for rounding).
        let todo = instances.indices.filter { k in
            guard let l = lastCut[k], l.transform == transforms[k], l.pixelScale == pixelScale, l.tau == tau else { return true }
            return !(length(camPos - l.camPos) < 0.99 * l.slack)
        }
        var changed: [(Int, [UInt32])] = []
        if !todo.isEmpty {
            let groupCount = todo.reduce(0) { $0 + meshes[instances[$1].mesh].groups.count }
            let chunk = max(256, groupCount / (4 * ProcessInfo.processInfo.activeProcessorCount))
            var items: [(k: Int, groups: Range<Int>)] = []
            for k in todo {
                let n = meshes[instances[k].mesh].groups.count
                for s in stride(from: 0, to: n, by: chunk) { items.append((k, s..<min(s + chunk, n))) }
            }
            var parts = [(selection: [UInt32], slack: Float)](repeating: ([], .infinity), count: items.count)
            parts.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: items.count) { i in
                    let (k, groups) = items[i]
                    out[i] = VirtualBLAS.selection(mesh: meshes[instances[k].mesh], groups: groups, transform: transforms[k],
                                                   camPos: camPos, pixelScale: pixelScale, tau: tau)
                }
            }
            var i = 0
            for k in todo {   // an instance's items are consecutive and in group order
                var sel: [UInt32] = []
                var slack = Float.infinity
                while i < items.count && items[i].k == k {
                    sel += parts[i].selection
                    slack = min(slack, parts[i].slack)
                    i += 1
                }
                lastCut[k] = CutInput(transform: transforms[k], camPos: camPos, pixelScale: pixelScale, tau: tau, slack: slack)
                lock.lock()
                workerStats[k].slack = slack
                lock.unlock()
                if sel == workerSelection[k] {
                    waited[k] = 0
                } else {
                    let mesh = meshes[instances[k].mesh]
                    let triangles = sel.reduce(0) { $0 + Int(mesh.clusters[Int($1)].triangles) }
                    if VirtualBLAS.buildsNow(changed: VirtualBLAS.changedTriangles(mesh: mesh, from: workerSelection[k], to: sel),
                                             triangles: triangles, waited: waited[k], wait: wait) {
                        changed.append((k, sel))
                        workerSelection[k] = sel
                        waited[k] = 0
                    } else {
                        waited[k] += 1
                        lastCut[k] = nil   // looked at again next pass, or a camera now at rest would never build it
                    }
                }
                lock.lock()
                workerStats[k].waited = waited[k]
                lock.unlock()
            }
        }
        let cutMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lock.lock()
        stats.lastCutMs = cutMs
        stats.skippedInstances = instances.count - todo.count
        lock.unlock()
        guard !changed.isEmpty else { return }

        prefetch(changed)
        let faultsBefore = VirtualBLAS.majorFaults()
        let results = build(changed)
        let faults = VirtualBLAS.majorFaults() - faultsBefore
        lock.lock()
        for (j, r) in results.enumerated() {
            let k = r.index, mesh = meshes[instances[k].mesh]
            var lo = Int.max, hi = 0
            for ci in r.built.selection {
                let level = Int(mesh.groups[Int(mesh.clusters[Int(ci)].group)].level)
                lo = min(lo, level)
                hi = max(hi, level)
            }
            workerStats[k].clusters = r.built.selection.count
            workerStats[k].triangles = Int(r.built.entry.triangles)
            workerStats[k].minLevel = lo == .max ? 0 : lo
            workerStats[k].maxLevel = hi
            workerStats[k].rebuilds += 1
            workerStats[k].gatherMs = gatherMs[j]
            workerStats[k].faults = faults
        }
        finished += results
        stats.rebuilds += changed.count
        stats.lastBuildMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 - cutMs
        lock.unlock()
    }

    /// New BLASes for `changed` (instance, selection): their triangles gathered in parallel, then Metal's structures
    /// built over them in one command buffer and compacted, which this waits for (the worker's, or a benchmark's frame).
    private func build(_ changed: [(Int, [UInt32])]) -> [(index: Int, built: Built)] {
        var gathered = [Built](repeating: Built(), count: changed.count)
        var times = [Double](repeating: 0, count: changed.count)
        times.withUnsafeMutableBufferPointer { ms in
            gathered.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: changed.count) { j in
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let (k, sel) = changed[j]
                    let m = instances[k].mesh
                    var g = gather(mesh: meshes[m], selection: sel)
                    g.entry.clusterInfo = clusterInfo[m]?.gpuAddress ?? 0
                    g.entry.flags = watertight.contains(m) ? VirtualBLAS.flagWatertight : 0
                    out[j] = Built(buffer: g.buffer, entry: g.entry, selection: sel)
                    ms[j] = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                }
            }
        }
        gatherMs = times
        // One structure per cut, built from a range of one scratch buffer each (the builds of an encoder may run side
        // by side).
        var jobs: [(j: Int, descriptor: MTLPrimitiveAccelerationStructureDescriptor, structure: MTLAccelerationStructure, scratch: Int)] = []
        var scratchBytes = 0
        for (j, g) in gathered.enumerated() {
            guard let buffer = g.buffer, g.entry.triangles > 0 else { continue }
            let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
            geometry.vertexBuffer = buffer
            geometry.vertexStride = MemoryLayout<SIMD4<Float>>.stride
            geometry.vertexFormat = .float3
            geometry.triangleCount = Int(g.entry.triangles)   // no index buffer: three vertices a triangle, in order
            geometry.opaque = true
            let d = MTLPrimitiveAccelerationStructureDescriptor()
            d.geometryDescriptors = [geometry]
            let sizes = device.accelerationStructureSizes(descriptor: d)
            guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else { continue }
            structure.label = "vgBLAS"
            jobs.append((j, d, structure, scratchBytes))
            scratchBytes += (sizes.buildScratchBufferSize + 255) & ~255
        }
        if !jobs.isEmpty {
            if (scratch?.length ?? 0) < scratchBytes {
                scratch = device.makeBuffer(length: scratchBytes + scratchBytes / 4, options: .storageModePrivate)
                scratch?.label = "vgBLASScratch"
            }
            if let scratch, let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() {
                for job in jobs {
                    enc.build(accelerationStructure: job.structure, descriptor: job.descriptor, scratchBuffer: scratch,
                              scratchBufferOffset: job.scratch)
                    gathered[job.j].structure = job.structure
                }
                enc.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
                if cmd.status != .completed {
                    for job in jobs { gathered[job.j].structure = nil }
                } else if let small = try? SceneBuffers.copyAndCompact(jobs.map(\.structure), device: device, queue: queue) {
                    for (job, structure) in zip(jobs, small) { gathered[job.j].structure = structure }
                }
            }
        }
        for j in gathered.indices where gathered[j].structure == nil {
            gathered[j].entry = Entry()   // no structure: the instance is left out until the next cut
        }
        return zip(changed, gathered).map { (index: $0.0, built: $1) }
    }

    /// Asks the OS to start reading the pages of the groups these cuts use (MADV_WILLNEED), so a cold cache is read
    /// with many requests in flight instead of one page fault at a time while gathering.
    private func prefetch(_ changed: [(Int, [UInt32])]) {
        var wanted = [Set<Int>](repeating: [], count: meshes.count)
        for (k, sel) in changed {
            let mesh = meshes[instances[k].mesh]
            for ci in sel { wanted[instances[k].mesh].insert(Int(mesh.clusters[Int(ci)].group)) }
        }
        let pageSize = Int(vm_page_size)
        for (m, groups) in wanted.enumerated() where !groups.isEmpty {
            let mesh = meshes[m]
            mesh.pageData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                // Byte ranges of the groups, merged where they touch or share an OS page.
                var ranges: [(start: Int, end: Int)] = []
                for g in groups.sorted() {
                    let s = Int(mesh.groups[g].pageOffset), e = s + Int(mesh.groups[g].pageSize)
                    if let last = ranges.last, s <= last.end + pageSize { ranges[ranges.count - 1].end = max(last.end, e) }
                    else { ranges.append((s, e)) }
                }
                for r in ranges {
                    let address = Int(bitPattern: base) + r.start
                    let aligned = address & ~(pageSize - 1)
                    madvise(UnsafeMutableRawPointer(bitPattern: aligned), Int(bitPattern: base) + r.end - aligned, MADV_WILLNEED)
                }
            }
        }
    }

    /// A shared buffer of at least `length` bytes: a recycled one up to twice that size, or a new one with some room
    /// to grow.
    private func obtainBuffer(length: Int) -> MTLBuffer? {
        lock.lock()
        let fit = freeBuffers.indices.filter { freeBuffers[$0].length >= length && freeBuffers[$0].length <= 2 * length }
            .min { freeBuffers[$0].length < freeBuffers[$1].length }
        let reused = fit.map { freeBuffers.remove(at: $0) }
        lock.unlock()
        if let reused { return reused }
        let rounded = (length + length / 4 + 0xFFFF) & ~0xFFFF
        let buffer = device.makeBuffer(length: rounded, options: .storageModeShared)
        buffer?.label = "vgBLAS"
        return buffer
    }

    /// Gathers the selected clusters' triangles from the (memory-mapped) pages, in the clusters' order, into a buffer
    /// laid out as `Entry` says.
    private func gather(mesh: VirtualMesh, selection: [UInt32]) -> (buffer: MTLBuffer?, entry: Entry) {
        guard !selection.isEmpty else { return (nil, Entry()) }
        let n = selection.count
        var triBase = [Int](repeating: 0, count: n), dataBase = [Int](repeating: 0, count: n)
        var triCount = 0
        for (j, ci) in selection.enumerated() {
            let c = mesh.clusters[Int(ci)]
            dataBase[j] = Int(mesh.groups[Int(c.group)].pageOffset) + Int(c.pageOffset)
            triBase[j] = triCount
            triCount += Int(c.triangles)
        }
        let triBytes = triCount * 48, attrBytes = triCount * 24
        guard triCount > 0, let buffer = obtainBuffer(length: triBytes + attrBytes) else { return (nil, Entry()) }
        let p = buffer.contents()
        let tris = p.bindMemory(to: SIMD4<Float>.self, capacity: triCount * 3)
        let at = p.advanced(by: triBytes).bindMemory(to: UInt32.self, capacity: triCount * 6)
        // Clusters in parallel chunks (they write disjoint ranges).
        let chunks = min(n, max(1, n / 256))
        mesh.pageData.withUnsafeBytes { raw in
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                for j in (n * chunk / chunks)..<(n * (chunk + 1) / chunks) {
                    let ci = selection[j]
                    let c = mesh.clusters[Int(ci)]
                    let base = dataBase[j], tb = triBase[j]
                    func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: base + o, as: UInt32.self) }
                    let clusterTris = Int(u32(8)), posOffset = Int(u32(20)), uvOffset = Int(u32(24)), triOffset = Int(u32(28))
                    let groupLevel = c.group & 0xFFFFFF | min(mesh.groups[Int(c.group)].level, 255) << 24
                    for t in 0..<clusterTris {
                        let packed = u32(triOffset + 4 * t)
                        let i = tb + t
                        for k in 0..<3 {
                            let vi = Int((packed >> (8 * UInt32(k))) & 0xFF)
                            let v = raw.loadUnaligned(fromByteOffset: base + posOffset + 16 * vi, as: SIMD4<Float>.self)
                            // The corners; the w components are free: the debug views' IDs
                            let id: UInt32 = k == 0 ? 0 : k == 1 ? ci & 0xFFFFFF | UInt32(t) << 24 : groupLevel
                            tris[3 * i + k] = SIMD4(v.x, v.y, v.z, Float(bitPattern: id))
                            at[6 * i + k] = v.w.bitPattern                  // normals
                            at[6 * i + 3 + k] = u32(uvOffset + 4 * vi)      // UVs
                        }
                    }
                }
            }
        }
        let entry = Entry(tris: buffer.gpuAddress, attrs: buffer.gpuAddress + UInt64(triBytes), triangles: UInt32(triCount))
        return (buffer, entry)
    }
}
