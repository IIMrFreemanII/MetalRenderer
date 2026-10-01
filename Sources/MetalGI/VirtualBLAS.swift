import Foundation
import Metal
import simd

/// Virtual geometry, ray-tracing friendly: the Nanite cut through each virtual mesh's cluster DAG is evaluated on the
/// CPU, and every instance whose cut changed gets a fresh SAH BLAS over exactly the cut's triangles, built in the
/// background from the memory-mapped cache (the OS streams the pages it touches from disk). Rays then traverse one
/// tight tree per model, which the custom tracer walks like any other instance, instead of a tree of overlapping
/// clusters (VirtualGeometry, METALGI_VG_MODE=clusters: 2.3x the node visits inside models).
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

    private let device: MTLDevice
    private let meshes: [VirtualMesh]
    private let instances: [(instance: Int, mesh: Int)]
    private var tables: [MTLBuffer] = []                 // per slot: Entry per VG instance
    private var current: [(buffer: MTLBuffer?, entry: Entry, selection: [UInt32])]
    private var retired: [(MTLBuffer, UInt32)] = []      // freed once the GPU is past that frame
    private let worker = DispatchQueue(label: "metalgi.vg.blas", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var finished: [(index: Int, buffer: MTLBuffer?, entry: Entry, selection: [UInt32])] = []
    private var workerSelection: [[UInt32]]              // the worker's own copy of what it last built
    private var started = false
    private(set) var stats = (triangles: 0, clusters: 0, rebuilds: 0, lastBuildMs: 0.0, megabytes: 0.0)

    init(device: MTLDevice, meshes: [VirtualMesh], instances: [(instance: Int, mesh: Int)], slots: Int) throws {
        self.device = device
        self.meshes = meshes
        self.instances = instances
        current = Array(repeating: (nil, Entry(), []), count: instances.count)
        workerSelection = Array(repeating: [], count: instances.count)
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

    func table(slot: Int) -> MTLBuffer { tables[slot] }
    func resources(slot: Int) -> [MTLResource] { [tables[slot]] + current.compactMap(\.buffer) }

    var summary: String {
        String(format: "VG: %d triangles in %d clusters, %.0f MB of BLAS, %d rebuilds (last %.0f ms)",
               stats.triangles, stats.clusters, stats.megabytes, stats.rebuilds, stats.lastBuildMs)
    }

    /// Main thread, before encoding `frame`: swap in finished BLASes, then start the next cut if the worker is free.
    /// `transforms` = this frame's object -> world matrix of every scene instance.
    func update(frame: UInt32, slot: Int, framesInFlight: Int, camPos: SIMD3<Float>, pixelScale: Float,
                tau: Float, transforms: [float4x4]) {
        retired.removeAll { $0.1 &+ UInt32(framesInFlight) < frame }   // frames finish in order
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
        let done = finished
        finished.removeAll()
        lock.unlock()
        for f in done {
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

    /// Nanite's rule without residency (every page is readable): a cluster is in the cut when its group's
    /// simplification is too coarse on screen and its own error is fine enough (or it is at the finest level).
    private func selection(mesh: VirtualMesh, transform m: float4x4, camPos: SIMD3<Float>, pixelScale: Float, tau: Float) -> [UInt32] {
        let scale = max(length(SIMD3(m[0].x, m[0].y, m[0].z)), length(SIMD3(m[1].x, m[1].y, m[1].z)), length(SIMD3(m[2].x, m[2].y, m[2].z)))
        func projected(_ s: SIMD4<Float>, _ error: Float) -> Float {
            let c = m * SIMD4<Float>(s.x, s.y, s.z, 1)
            let d = length(SIMD3(c.x, c.y, c.z) - camPos) - s.w * scale
            return d <= 1e-4 ? .infinity : error * scale * pixelScale / d
        }
        var out: [UInt32] = []
        for (i, c) in mesh.clusters.enumerated() {
            if c.hi.w != .infinity && projected(c.parentSphere, c.hi.w) <= tau { continue }
            if c.childGroup != .max && projected(c.selfSphere, c.lo.w) > tau { continue }
            out.append(UInt32(i))
        }
        return out
    }

    /// Worker: the cut for every instance; instances whose cut changed get a new BLAS (in parallel).
    private func cut(camPos: SIMD3<Float>, pixelScale: Float, tau: Float, transforms: [float4x4]) {
        let start = CFAbsoluteTimeGetCurrent()
        var changed: [(Int, [UInt32])] = []
        for (k, (_, mesh)) in instances.enumerated() {
            let sel = selection(mesh: meshes[mesh], transform: transforms[k], camPos: camPos, pixelScale: pixelScale, tau: tau)
            if sel != workerSelection[k] { changed.append((k, sel)); workerSelection[k] = sel }
        }
        guard !changed.isEmpty else { return }
        var results = [(index: Int, buffer: MTLBuffer?, entry: Entry, selection: [UInt32])?](repeating: nil, count: changed.count)
        let resultLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: changed.count) { j in
            let (k, sel) = changed[j]
            let r = build(mesh: meshes[instances[k].mesh], selection: sel)
            resultLock.lock(); results[j] = (k, r.buffer, r.entry, sel); resultLock.unlock()
        }
        lock.lock()
        finished += results.compactMap { $0 }
        stats.rebuilds += changed.count
        stats.lastBuildMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lock.unlock()
    }

    /// Gathers the selected clusters' triangles from the (memory-mapped) pages and builds an SAH BLAS over them.
    private func build(mesh: VirtualMesh, selection: [UInt32]) -> (buffer: MTLBuffer?, entry: Entry) {
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
        guard let buffer = device.makeBuffer(length: nodeBytes + triBytes + attrBytes, options: .storageModeShared) else {
            return (nil, Entry())
        }
        buffer.label = "vgBLAS"
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
