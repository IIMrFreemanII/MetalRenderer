import Foundation
import Metal
import simd

/// Virtual geometry, ray-tracing friendly: the Nanite cut through each virtual mesh's cluster DAG is evaluated on the
/// CPU, and every instance whose cut changed gets a fresh BLAS over exactly the cut's triangles, built in the
/// background from the memory-mapped cache (the OS streams the pages it touches from disk; they are prefetched with
/// madvise first). Rays then traverse one tree per model, which the custom tracer walks like any other instance,
/// instead of a tree of clusters spanning every model (VirtualGeometry, METALRENDERER_VG_MODE=clusters).
///
/// Two builders, used by METALRENDERER_VG_BLAS:
///   spliced: an SAH tree over the cut's clusters, with each cluster's own BVH from its page copied in under it. Only
///     the clusters are sorted, so a rebuild is little more than a copy of the cut's data (gallery: 1-9 ms), but the
///     clusters overlap, so rays visit more nodes (gallery: ~50% slower traces).
///   sah: one binned-SAH tree over every triangle of the cut (gallery: 20-150 ms per rebuild).
///   hybrid (default): a big change of an instance's cut (the first one, a jump, a new error setting: over
///     `splicedShare` of its triangles) is published spliced at once, then rebuilt with SAH on a background queue and
///     swapped in if the cut is still the same. Small changes, as when the camera glides, go straight to SAH: a
///     spliced tree for every step would trace slower for the whole move. Benchmarks (sync) always build SAH.
///
/// GPU memory holds only the current cuts: about one triangle per traced pixel at the default error of 1 px.
final class VirtualBLAS {
    /// Per VG instance on the GPU (MSL `VGBlas`): its current BLAS (nodes, then triangles as v0 e1 e2 with the debug
    /// views' IDs in e1.w / e2.w, then per triangle 6 words of attributes: 3 octahedral normals, 3 half2 UVs, all in BLAS
    /// leaf order).
    struct Entry {
        var nodes: UInt64 = 0
        var tris: UInt64 = 0
        var attrs: UInt64 = 0
        var triangles: UInt32 = 0
        var pad: UInt32 = 0
    }

    static let sync = VirtualGeometry.sync
    enum Builder: String { case hybrid, spliced, sah }
    static let builder = Builder(rawValue: ProcessInfo.processInfo.environment["METALRENDERER_VG_BLAS"] ?? "") ?? .hybrid
    static let splicedShare: Float = 0.25

    /// What an instance's last cut was made for, and how far the camera can move before any of its tests could change.
    private struct CutInput {
        var transform: float4x4
        var camPos: SIMD3<Float>
        var pixelScale: Float
        var tau: Float
        var slack: Float
    }

    private let device: MTLDevice
    private let meshes: [VirtualMesh]
    private let instances: [(instance: Int, mesh: Int)]
    private var tables: [MTLBuffer] = []                 // per slot: Entry per VG instance
    private var current: [(buffer: MTLBuffer?, entry: Entry, selection: [UInt32])]
    private var retired: [(MTLBuffer, UInt32)] = []      // recycled once the GPU is past that frame
    private var freeBuffers: [MTLBuffer] = []            // recycled BLAS buffers, oldest first (under `lock`)
    private let worker = DispatchQueue(label: "metalrenderer.vg.blas", qos: .userInitiated)
    private let refiner = DispatchQueue(label: "metalrenderer.vg.refine", qos: .utility)   // hybrid: the SAH rebuilds
    private var versions: [Int]                          // per instance: bumped with every new cut (under `lock`)
    private let lock = NSLock()
    private var busy = false
    private var finished: [(index: Int, buffer: MTLBuffer?, entry: Entry, selection: [UInt32])] = []
    private var workerSelection: [[UInt32]]              // the worker's own copy of what it last built
    private var lastCut: [CutInput?]                     // the worker's
    private var started = false
    private(set) var stats = (triangles: 0, clusters: 0, rebuilds: 0, lastBuildMs: 0.0, megabytes: 0.0, lastCutMs: 0.0,
                              skippedInstances: 0, lastRefineMs: 0.0)

    init(device: MTLDevice, meshes: [VirtualMesh], instances: [(instance: Int, mesh: Int)], slots: Int) throws {
        self.device = device
        self.meshes = meshes
        self.instances = instances
        current = Array(repeating: (nil, Entry(), []), count: instances.count)
        workerSelection = Array(repeating: [], count: instances.count)
        lastCut = Array(repeating: nil, count: instances.count)
        versions = Array(repeating: 0, count: instances.count)
        for slot in 0..<slots {
            guard let t = device.makeBuffer(length: max(instances.count, 1) * MemoryLayout<Entry>.stride, options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer vgBlasTable")
            }
            t.label = "vgBlasTable\(slot)"
            memset(t.contents(), 0, t.length)
            tables.append(t)
        }
        print("Virtual geometry (per-instance BLAS, \(VirtualBLAS.builder.rawValue)): \(meshes.count) meshes, "
              + "\(instances.count) instances, \(meshes.reduce(0) { $0 + $1.clusters.count }) clusters")
    }

    var meshCount: Int { meshes.count }
    var instanceCount: Int { instances.count }
    /// Triangles at the finest level, over every instance (what drawing without LOD would trace).
    var sourceTriangles: Int { instances.reduce(0) { $0 + meshes[$1.mesh].triangleCount } }
    /// The worker is computing a cut or building BLASes.
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }

    func table(slot: Int) -> MTLBuffer { tables[slot] }
    func resources(slot: Int) -> [MTLResource] { [tables[slot]] + current.compactMap(\.buffer) }

    var summary: String {
        String(format: "VG: %d triangles in %d clusters, %.0f MB of BLAS, %d rebuilds (last %.1f ms, refined in %.1f ms), cut %.1f ms (%d of %d instances skipped)",
               stats.triangles, stats.clusters, stats.megabytes, stats.rebuilds, stats.lastBuildMs, stats.lastRefineMs,
               stats.lastCutMs, stats.skippedInstances, instances.count)
    }

    /// Main thread, before encoding `frame`: swap in finished BLASes, then start the next cut if the worker is free.
    /// `transforms` = this frame's object -> world matrix of every scene instance.
    func update(frame: UInt32, slot: Int, framesInFlight: Int, camPos: SIMD3<Float>, pixelScale: Float,
                tau: Float, transforms: [float4x4]) {
        // Buffers the GPU is done with go back to the pool (frames finish in order), which keeps about as many bytes as
        // the current BLASes, dropping the oldest beyond that.
        let done = retired.filter { $0.1 &+ UInt32(framesInFlight) < frame }.map(\.0)
        retired.removeAll { $0.1 &+ UInt32(framesInFlight) < frame }
        if !done.isEmpty {
            let keep = current.reduce(0) { $0 + ($1.buffer?.length ?? 0) }
            lock.lock()
            freeBuffers += done
            var bytes = freeBuffers.reduce(0) { $0 + $1.length }
            while bytes > keep, !freeBuffers.isEmpty { bytes -= freeBuffers.removeFirst().length }
            lock.unlock()
        }
        let snapshot = instances.map { transforms[$0.instance] }
        let job = { [self] in self.cut(camPos: camPos, pixelScale: pixelScale, tau: tau, transforms: snapshot) }
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
            if let old = current[f.index].buffer { retired.append((old, frame)) }
            current[f.index] = (f.buffer, f.entry, f.selection)
        }
        var bytes = 0, triangles = 0
        for c in current {
            bytes += c.buffer?.length ?? 0
            triangles += Int(c.entry.triangles)
        }
        stats.megabytes = Double(bytes) / 1_048_576
        stats.triangles = triangles
        stats.clusters = current.reduce(0) { $0 + $1.selection.count }
        current.map(\.entry).withUnsafeBytes { tables[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    /// Nanite's rule without residency (every page is readable), over `groups` of `mesh`: a cluster is in the cut when
    /// its group's simplification is too coarse on screen and its own error is fine enough (or it is at the finest
    /// level). A group's clusters share the first test, so it is made once per group.
    ///
    /// `slack`: how far the camera can move before any test made here could turn out differently. Each test
    /// "projected error <= tau" is "distance to the sphere >= error x scale x pixelScale / tau", and that distance
    /// changes at most as much as the camera moves.
    private func selection(mesh: VirtualMesh, groups: Range<Int>, transform m: float4x4, camPos: SIMD3<Float>,
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
    private func cut(camPos: SIMD3<Float>, pixelScale: Float, tau: Float, transforms: [float4x4]) {
        let start = CFAbsoluteTimeGetCurrent()
        // An instance with the same transform and error settings, whose camera hasn't moved as far as its slack, keeps
        // its cut (0.99: margin for rounding).
        let todo = instances.indices.filter { k in
            guard let l = lastCut[k], l.transform == transforms[k], l.pixelScale == pixelScale, l.tau == tau else { return true }
            return !(length(camPos - l.camPos) < 0.99 * l.slack)
        }
        var changed: [(k: Int, selection: [UInt32], big: Bool)] = []
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
                    out[i] = selection(mesh: meshes[instances[k].mesh], groups: groups, transform: transforms[k],
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
                if sel != workerSelection[k] {
                    let big = changedShare(mesh: meshes[instances[k].mesh], workerSelection[k], sel) > VirtualBLAS.splicedShare
                    changed.append((k, sel, big))
                    workerSelection[k] = sel
                }
            }
        }
        let cutMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lock.lock()
        stats.lastCutMs = cutMs
        stats.skippedInstances = instances.count - todo.count
        lock.unlock()
        guard !changed.isEmpty else { return }

        prefetch(changed.map { ($0.k, $0.selection) })
        let builder = VirtualBLAS.builder
        let quick = changed.filter { builder == .spliced || (builder == .hybrid && !VirtualBLAS.sync && $0.big) }
        let slow = changed.filter { !(builder == .spliced || (builder == .hybrid && !VirtualBLAS.sync && $0.big)) }
        func publish(_ cuts: [(k: Int, selection: [UInt32], big: Bool)], spliced: Bool) -> [(k: Int, selection: [UInt32], version: Int)] {
            guard !cuts.isEmpty else { return [] }
            let results = build(cuts.map { ($0.k, $0.selection) }, spliced: spliced)
            lock.lock()
            defer { lock.unlock() }
            finished += results
            stats.rebuilds += cuts.count
            stats.lastBuildMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 - cutMs
            return cuts.map { c in versions[c.k] += 1; return (c.k, c.selection, versions[c.k]) }
        }
        let spliced = publish(quick, spliced: true)   // first: these are the ones worth seeing early
        _ = publish(slow, spliced: false)
        if builder == .hybrid && !spliced.isEmpty { refiner.async { self.refine(spliced) } }
    }

    /// The share of triangles that differ between two cuts of `mesh` (cluster indices in ascending order).
    private func changedShare(mesh: VirtualMesh, _ a: [UInt32], _ b: [UInt32]) -> Float {
        func tris(_ c: UInt32) -> Int { Int(mesh.clusters[Int(c)].triangles) }
        var i = 0, j = 0, differ = 0
        while i < a.count || j < b.count {
            if j == b.count || (i < a.count && a[i] < b[j]) { differ += tris(a[i]); i += 1 }
            else if i == a.count || b[j] < a[i] { differ += tris(b[j]); j += 1 }
            else { i += 1; j += 1 }
        }
        let total = max(a.reduce(0) { $0 + tris($1) }, b.reduce(0) { $0 + tris($1) }, 1)
        return Float(differ) / Float(total)
    }

    /// New BLASes for `changed` (instance, selection), one per instance in parallel.
    private func build(_ changed: [(Int, [UInt32])], spliced: Bool) -> [(index: Int, buffer: MTLBuffer?, entry: Entry, selection: [UInt32])] {
        var results = [(index: Int, buffer: MTLBuffer?, entry: Entry, selection: [UInt32])?](repeating: nil, count: changed.count)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: changed.count) { j in
                let (k, sel) = changed[j]
                let mesh = meshes[instances[k].mesh]
                let r = spliced ? buildSpliced(mesh: mesh, selection: sel) : buildSAH(mesh: mesh, selection: sel)
                out[j] = (k, r.buffer, r.entry, sel)
            }
        }
        return results.compactMap { $0 }
    }

    /// Hybrid, in the background: SAH BLASes for cuts that were just published as spliced ones. A cut that has been
    /// replaced since (its version moved on) is skipped, or its result dropped if that happened during the build.
    private func refine(_ cuts: [(k: Int, selection: [UInt32], version: Int)]) {
        let start = CFAbsoluteTimeGetCurrent()
        func current(_ c: (k: Int, selection: [UInt32], version: Int)) -> Bool { versions[c.k] == c.version }
        lock.lock()
        let live = cuts.filter(current)
        lock.unlock()
        guard !live.isEmpty else { return }
        let results = build(live.map { ($0.k, $0.selection) }, spliced: false)
        lock.lock()
        for (c, r) in zip(live, results) {
            if current(c) { finished.append(r) } else if let b = r.buffer { freeBuffers.append(b) }   // never used by the GPU
        }
        stats.lastRefineMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lock.unlock()
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

    /// The cut's BLAS from its clusters' own BVHs: an SAH tree over the clusters' boxes on top, then each cluster's
    /// nodes as stored in its page (refs moved to their place in this buffer), then the triangles and attributes in
    /// each cluster's leaf order, read straight from the (memory-mapped) pages into the buffer.
    private func buildSpliced(mesh: VirtualMesh, selection: [UInt32]) -> (buffer: MTLBuffer?, entry: Entry) {
        guard !selection.isEmpty else { return (nil, Entry()) }
        let n = selection.count
        let topCount = max(n - 1, 1)
        var nodeBase = [Int](repeating: 0, count: n), triBase = [Int](repeating: 0, count: n)
        var dataBase = [Int](repeating: 0, count: n)   // each cluster's data in `pageData`
        var nodeCount = topCount, triCount = 0
        mesh.pageData.withUnsafeBytes { raw in
            for (j, ci) in selection.enumerated() {
                let c = mesh.clusters[Int(ci)]
                dataBase[j] = Int(mesh.groups[Int(c.group)].pageOffset) + Int(c.pageOffset)
                nodeBase[j] = nodeCount
                triBase[j] = triCount
                nodeCount += Int(raw.loadUnaligned(fromByteOffset: dataBase[j], as: UInt32.self))
                triCount += Int(c.triangles)
            }
        }
        let boxes = selection.map { ci -> AABB in
            let c = mesh.clusters[Int(ci)]
            return AABB(lo: SIMD3(c.lo.x, c.lo.y, c.lo.z), hi: SIMD3(c.hi.x, c.hi.y, c.hi.z))
        }
        let top = BVHBuilder.buildOverSubtrees(boxes: boxes) { UInt32(nodeBase[$0]) }
        precondition(top.count == topCount)

        let nodeBytes = nodeCount * 64, triBytes = triCount * 48, attrBytes = triCount * 24
        guard let buffer = obtainBuffer(length: nodeBytes + triBytes + attrBytes) else { return (nil, Entry()) }
        let p = buffer.contents()
        top.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let nodes = p.bindMemory(to: BVHNode.self, capacity: nodeCount)
        let tris = p.advanced(by: nodeBytes).bindMemory(to: SIMD4<Float>.self, capacity: triCount * 3)
        let at = p.advanced(by: nodeBytes + triBytes).bindMemory(to: UInt32.self, capacity: triCount * 6)

        // Clusters in parallel chunks (they write disjoint ranges).
        let chunks = min(n, max(1, n / 256))
        mesh.pageData.withUnsafeBytes { raw in
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                for j in (n * chunk / chunks)..<(n * (chunk + 1) / chunks) {
                    let ci = selection[j]
                    let c = mesh.clusters[Int(ci)]
                    let base = dataBase[j], nb = UInt32(nodeBase[j]), tb = triBase[j]
                    func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: base + o, as: UInt32.self) }
                    let clusterNodes = Int(u32(0)), clusterTris = Int(u32(8))
                    let nodeOffset = Int(u32(16)), posOffset = Int(u32(20)), uvOffset = Int(u32(24)), triOffset = Int(u32(28))
                    func moved(_ ref: UInt32) -> UInt32 {
                        if ref == BVHNode.none { return ref }
                        if ref & BVHNode.leafBit != 0 { return (ref & 0xF000_0000) | ((ref & 0x0FFF_FFFF) + UInt32(tb)) }
                        return ref + nb
                    }
                    for i in 0..<clusterNodes {
                        var node = raw.loadUnaligned(fromByteOffset: base + nodeOffset + 64 * i, as: BVHNode.self)
                        node.lo0.w = Float(bitPattern: moved(node.lo0.w.bitPattern))
                        node.lo1.w = Float(bitPattern: moved(node.lo1.w.bitPattern))
                        nodes[Int(nb) + i] = node
                    }
                    let groupLevel = c.group & 0xFFFFFF | min(mesh.groups[Int(c.group)].level, 255) << 24
                    for t in 0..<clusterTris {
                        let packed = u32(triOffset + 4 * t)
                        let i = tb + t
                        var p0 = SIMD3<Float>()
                        for k in 0..<3 {
                            let vi = Int((packed >> (8 * UInt32(k))) & 0xFF)
                            let v = raw.loadUnaligned(fromByteOffset: base + posOffset + 16 * vi, as: SIMD4<Float>.self)
                            let p3 = SIMD3(v.x, v.y, v.z)
                            if k == 0 { p0 = p3 }
                            // v0, then the edges; the w components are free: the index, then debug IDs
                            tris[3 * i + k] = k == 0 ? SIMD4(p3, Float(bitPattern: UInt32(i)))
                                : SIMD4(p3 - p0, Float(bitPattern: k == 1 ? ci & 0xFFFFFF | UInt32(t) << 24 : groupLevel))
                            at[6 * i + k] = v.w.bitPattern                  // normals
                            at[6 * i + 3 + k] = u32(uvOffset + 4 * vi)      // UVs
                        }
                    }
                }
            }
        }
        let entry = Entry(nodes: buffer.gpuAddress, tris: buffer.gpuAddress + UInt64(nodeBytes),
                          attrs: buffer.gpuAddress + UInt64(nodeBytes + triBytes), triangles: UInt32(triCount))
        return (buffer, entry)
    }

    /// Gathers the selected clusters' triangles from the (memory-mapped) pages and builds an SAH BLAS over them.
    private func buildSAH(mesh: VirtualMesh, selection: [UInt32]) -> (buffer: MTLBuffer?, entry: Entry) {
        var positions: [SIMD3<Float>] = []
        var attrs: [SIMD3<UInt32>] = []      // per corner: (octahedral normal, half2 UV, 0)
        var boxes: [AABB] = []
        var ids: [SIMD2<UInt32>] = []        // per triangle, for the debug views: cluster | triangle << 24, group | level << 24
        mesh.pageData.withUnsafeBytes { raw in
            for ci in selection {
                let c = mesh.clusters[Int(ci)]
                let base = Int(mesh.groups[Int(c.group)].pageOffset) + Int(c.pageOffset)
                func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: base + o, as: UInt32.self) }
                let triCount = Int(u32(8)), posOffset = Int(u32(20)), uvOffset = Int(u32(24)), triOffset = Int(u32(28))
                let groupLevel = c.group & 0xFFFFFF | min(mesh.groups[Int(c.group)].level, 255) << 24
                for t in 0..<triCount {
                    let packed = u32(triOffset + 4 * t)
                    var box = AABB()
                    for k in 0..<3 {
                        let v = Int((packed >> (8 * UInt32(k))) & 0xFF)
                        let p = raw.loadUnaligned(fromByteOffset: base + posOffset + 16 * v, as: SIMD4<Float>.self)
                        let p3 = SIMD3(p.x, p.y, p.z)
                        positions.append(p3)
                        attrs.append(SIMD3(p.w.bitPattern, u32(uvOffset + 4 * v), 0))
                        box.grow(p3)
                    }
                    boxes.append(box)
                    ids.append(SIMD2(ci & 0xFFFFFF | UInt32(t) << 24, groupLevel))
                }
            }
        }
        guard !boxes.isEmpty else { return (nil, Entry()) }
        let (nodes, order) = BVHBuilder.buildCluster(boxes: boxes)
        let nodeBytes = nodes.count * 64, triBytes = boxes.count * 48, attrBytes = boxes.count * 24
        guard let buffer = obtainBuffer(length: nodeBytes + triBytes + attrBytes) else { return (nil, Entry()) }
        let p = buffer.contents()
        nodes.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let tris = p.advanced(by: nodeBytes).bindMemory(to: SIMD4<Float>.self, capacity: boxes.count * 3)
        let at = p.advanced(by: nodeBytes + triBytes).bindMemory(to: UInt32.self, capacity: boxes.count * 6)
        for (i, t) in order.enumerated() {
            let p0 = positions[3 * t], p1 = positions[3 * t + 1], p2 = positions[3 * t + 2]
            tris[3 * i] = SIMD4(p0, Float(bitPattern: UInt32(i)))
            tris[3 * i + 1] = SIMD4(p1 - p0, Float(bitPattern: ids[t].x))   // the w components are free: debug IDs
            tris[3 * i + 2] = SIMD4(p2 - p0, Float(bitPattern: ids[t].y))
            for k in 0..<3 {
                at[6 * i + k] = attrs[3 * t + k].x          // normals
                at[6 * i + 3 + k] = attrs[3 * t + k].y      // UVs
            }
        }
        let entry = Entry(nodes: buffer.gpuAddress, tris: buffer.gpuAddress + UInt64(nodeBytes),
                          attrs: buffer.gpuAddress + UInt64(nodeBytes + triBytes), triangles: UInt32(boxes.count))
        return (buffer, entry)
    }
}
