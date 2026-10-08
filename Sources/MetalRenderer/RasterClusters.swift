import Foundation
import Metal
import simd

/// Virtual geometry in the raster visibility buffer as Nanite draws it (`VirtualGeometrySettings.raster` = clusters,
/// Shaders/RasterClusters.metal): every frame, in each of the raster's two passes, rasterVGCutKernel walks the cluster
/// groups of the virtual instances that pass drew, picks the cut there with the rule the per-instance BLAS uses
/// (projected error at most `tau` traced pixels), culls each picked cluster against the view (and in the second pass the
/// depth pyramid), and appends it to the pass's draw list: the raster draws it from the streaming pool, a 128-triangle
/// slot like a chunk. Clusters it would have liked finer whose finer group isn't resident ask for it, and this pool
/// (its own VGStreamer; the rays keep the BLAS) streams it in.
///
/// A drawn cluster's triangle is named in the visibility buffer by its entry in this frame's cluster list
/// (`list`: selfError bits, pool offset in float4s), which the trace reads as TraceScene's clusters.
final class RasterClusters {
    static let capacity = 1 << 17         // clusters drawn a frame, both passes (the list's entries)
    static let requestCapacity = 4096
    /// Where the list's owners start (after its entries): each entry's virtual instance and scene instance (uint2).
    static let ownersOffset = capacity * 8
    static let flag: UInt32 = 0x8000_0000  // visibility buffer y: a cluster's triangle (entry << 7 | triangle)
    /// Rays from a drawn cluster leave this many times its simplification error in front of it (traceKernel), in case
    /// the BLAS they meet lies in front of the drawn cut: `METALRENDERER_RASTER_VG_BIAS`. Off (0) by default: in the
    /// gallery and a showcase model, direct light alone, 1 took 0.5-0.7 dB off the match with traced primary rays (and an
    /// offset of a traced pixel's width 1-3 dB, also in camera moves with the BLAS built behind), as the rays then start
    /// past nearby occluders; the two cuts are picked by the same rule, and meet within RAY_EPSILON.
    static let bias = Float(ProcessInfo.processInfo.environment["METALRENDERER_RASTER_VG_BIAS"] ?? "") ?? 0

    let streamer: VGStreamer
    /// What it was made for: the tracer's virtual geometry (a new scene has a new one).
    weak var source: VirtualBLAS?
    let vinstances: MTLBuffer             // VGRasterInstance per virtual instance (MSL)
    let groupRecords: MTLBuffer           // VGGroupRecord per global group (MSL)
    let workCount: Int                    // (virtual instance, group) pairs: rasterVGCutKernel's threads
    let instanceCount: Int
    let sourceTriangles: Int
    private var counterBuffers: [MTLBuffer] = []   // per slot: drawn, requests, overflow, triangles (MSL RasterVGCounters)
    private var requestBuffers: [MTLBuffer] = []
    private(set) var listBuffers: [MTLBuffer] = []
    // The shadow maps' clusters (vsmVGCutKernel): per slot, which virtual instances' meshes got groups this frame, the
    // shadow maps' own requests (a count, then pairs), and their records per (active view, virtual instance).
    private var changedBuffers: [MTLBuffer] = []
    private var vsmRequestBuffers: [MTLBuffer] = []
    private var vsmRecordBuffers: [MTLBuffer?] = []
    private let meshOfInstance: [Int]
    private let device: MTLDevice
    private let lock = NSLock()
    private var counts = (drawn: 0, triangles: 0, overflow: false, retested: 0)
    private var cameraDraws = false   // the last collected frame's raster drew them (else the shadow maps only)
    var drawnByCamera: Bool { lock.lock(); defer { lock.unlock() }; return cameraDraws }

    var stats: (drawn: Int, triangles: Int, overflow: Bool, retested: Int, residentGroups: Int, pending: Int, loadedThisFrame: Int) {
        lock.lock(); let c = counts; lock.unlock()
        let s = streamer.stats
        return (c.drawn, c.triangles, c.overflow, c.retested, s.residentGroups, s.pending, s.loadedThisFrame)
    }

    /// `instances`: (scene instance index, virtual mesh index) for every virtual instance, in their rank (pad1 - 1).
    init(device: MTLDevice, meshes: [VirtualMesh], instances: [(instance: Int, mesh: Int)], poolMB: Int, slots: Int) throws {
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            b.label = label
            return b
        }
        streamer = try VGStreamer(device: device, meshes: meshes, poolMB: poolMB, slots: slots, label: "rasterVG")
        self.device = device
        meshOfInstance = instances.map(\.mesh)

        // Per global group: its clusters' parent sphere and error (shared by all of them), its clusters.
        var records: [SIMD4<Float>] = []
        for (m, mesh) in meshes.enumerated() {
            for g in mesh.groups {
                let first = mesh.clusters[Int(g.clusterStart)]
                records.append(first.parentSphere)
                records.append(SIMD4(first.hi.w, Float(bitPattern: UInt32(streamer.meshClusterBase[m]) + g.clusterStart),
                                     Float(bitPattern: g.clusterCount), 0))
            }
        }
        let groupData = try buffer(records.count * 16, "rasterVGGroups")
        records.withUnsafeBytes { if $0.count > 0 { groupData.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        groupRecords = groupData

        var table: [SIMD4<UInt32>] = []
        var work = 0
        for (instance, mesh) in instances {
            let count = meshes[mesh].groups.count
            table.append(SIMD4(UInt32(instance), UInt32(streamer.meshGroupBase[mesh]), UInt32(count), UInt32(work)))
            work += count
        }
        workCount = work
        instanceCount = instances.count
        sourceTriangles = instances.reduce(0) { $0 + meshes[$1.mesh].triangleCount }
        let tableData = try buffer(table.count * 16, "rasterVGInstances")
        table.withUnsafeBytes { if $0.count > 0 { tableData.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        vinstances = tableData

        for slot in 0..<slots {
            // Counters (RVG_HEADER words), then per virtual instance its RasterInstance and whether it is in view.
            counterBuffers.append(try buffer(64 + 68 * instances.count, "rasterVGState\(slot)"))
            // Requests, then the clusters the first pass holds back for the second (uint4 each).
            requestBuffers.append(try buffer(RasterClusters.requestCapacity * 8 + RasterClusters.capacity * 16, "rasterVGRequests\(slot)"))
            // The entries (selfError, pool offset), then each entry's virtual instance and scene instance.
            listBuffers.append(try buffer(RasterClusters.capacity * 16, "rasterVGList\(slot)"))
            changedBuffers.append(try buffer(4 * instances.count, "rasterVGChanged\(slot)"))
            vsmRequestBuffers.append(try buffer(16 + RasterClusters.requestCapacity * 8, "rasterVGShadowRequests\(slot)"))
            vsmRecordBuffers.append(nil)
        }
        print(String(format: "Raster clusters: %d instances, %d clusters in %d groups, pool %d MB (roots %.1f MB)",
                     instanceCount, streamer.clusterCount, streamer.groupCount, streamer.poolBytes >> 20,
                     Double(streamer.rootBytes) / 1_048_576))
    }

    /// MSL RasterVGParams (48 bytes).
    struct Params {
        var lodCam: SIMD4<Float>        // xyz = where detail is chosen for, w = pixels per unit of error at distance 1
        var tau: Float
        var workCount, instanceCount, capacity, frame, requestCapacity, flags, pad: UInt32
        static let previous: UInt32 = 1   // the last frame's depth pyramid is there to test against (RVG_P_PREV)
        static let mesh: UInt32 = 2       // drawn by mesh shaders (RVG_P_MESH)
    }
    /// Mesh shaders' indirect arguments in the state, per pass (RVG_MESH_ARGS words in).
    static func meshArgsOffset(pass: Int) -> Int { (9 + 3 * pass) * 4 }

    func params(view: VGView, previous: Bool, mesh: Bool) -> Params {
        Params(lodCam: SIMD4(view.camPos, view.pixelScale), tau: view.tau, workCount: UInt32(workCount),
               instanceCount: UInt32(instanceCount), capacity: UInt32(RasterClusters.capacity), frame: view.frame,
               requestCapacity: UInt32(RasterClusters.requestCapacity),
               flags: (previous ? Params.previous : 0) | (mesh ? Params.mesh : 0), pad: 0)
    }

    /// The frame's state: counters, then per virtual instance the RasterInstance the raster's culling left it and
    /// whether it is in view.
    func state(slot: Int) -> MTLBuffer { counterBuffers[slot] }
    func requests(slot: Int) -> MTLBuffer { requestBuffers[slot] }

    /// The frame that used `slot` has finished on the GPU: collect its requests (any thread).
    /// `camera`, `shadows`: the raster's cut, the shadow maps' cut ran in that frame (their counters are its).
    func collect(slot: Int, frame: UInt32, camera: Bool, shadows: Bool) {
        let c = counterBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: 5)
        if camera {
            let n = min(Int(c[1]), RasterClusters.requestCapacity)
            let r = requestBuffers[slot].contents().bindMemory(to: SIMD2<UInt32>.self, capacity: RasterClusters.requestCapacity)
            streamer.addRequests(r, count: n, frame: frame)
        }
        if shadows {
            let v = vsmRequestBuffers[slot].contents()
            let vn = min(Int(v.load(as: UInt32.self)), RasterClusters.requestCapacity)
            streamer.addRequests(v.advanced(by: 16).bindMemory(to: SIMD2<UInt32>.self, capacity: RasterClusters.requestCapacity),
                                 count: vn, frame: frame)
        }
        lock.lock()
        counts = camera ? (min(Int(c[0]), RasterClusters.capacity), Int(c[3]), c[2] != 0, min(Int(c[4]), RasterClusters.capacity))
                        : (0, 0, false, 0)
        cameraDraws = camera
        lock.unlock()
    }

    /// Render thread, before encoding `frame`: see VGStreamer.update.
    func update(frame: UInt32, slot: Int, framesInFlight: Int) {
        streamer.update(frame: frame, framesInFlight: framesInFlight)
        let meshes = streamer.takePublished()
        let changed = changedBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: instanceCount)
        for (i, m) in meshOfInstance.enumerated() { changed[i] = meshes.contains(m) ? 1 : 0 }
    }

    /// The shadow maps' arguments (MSL VSMClusterArgs, 96 bytes): what vsmCullKernel, vsmInvalidateKernel,
    /// vsmVGCutKernel and vsmVertex reach of the clusters. Their records hold `views` active views a frame.
    func shadowArgs(slot: Int, views: Int, tau: Float) -> (bytes: [UInt64], resources: [MTLResource])? {
        let length = max(views * instanceCount * 112, 16)
        if (vsmRecordBuffers[slot]?.length ?? 0) < length {
            vsmRecordBuffers[slot] = device.makeBuffer(length: length, options: .storageModePrivate)
            vsmRecordBuffers[slot]?.label = "rasterVGShadowRecords\(slot)"
        }
        guard let records = vsmRecordBuffers[slot] else { return nil }
        let pages = streamer.bindPages(slot: slot)   // (this frame's: the shadow maps run ahead of the raster)
        let buffers = [records, changedBuffers[slot], vsmRequestBuffers[slot], streamer.pool, vinstances, groupRecords,
                       streamer.clusterBuffer, pages, streamer.requestStamp, streamer.lastUsed]
        var bytes = buffers.map(\.gpuAddress)
        bytes.append(UInt64(instanceCount) | UInt64(workCount) << 32)
        bytes.append(UInt64(RasterClusters.requestCapacity) | UInt64(tau.bitPattern) << 32)
        return (bytes, buffers)
    }

    /// What the raster's kernels and vertices, and the trace, reach in this frame's slot.
    func resources(slot: Int) -> [MTLResource] {   // (the shadow maps' come with shadowArgs)
        [streamer.pool, streamer.clusterBuffer, streamer.requestStamp, streamer.lastUsed, streamer.pageTable(slot: slot),
         vinstances, groupRecords, counterBuffers[slot], requestBuffers[slot], listBuffers[slot]]
    }

    var summary: String {
        let s = stats
        if !drawnByCamera {
            return String(format: "Raster clusters (the shadow maps'): %d groups resident (%.0f MB of %d), %d requests waiting",
                          s.residentGroups, streamer.residentMB, streamer.poolBytes >> 20, s.pending)
        }
        return String(format: "Raster clusters: %d triangles in %d clusters drawn%@ (%d held back for the second pass), %d groups resident (%.0f MB of %d), %d requests waiting",
                      s.triangles, s.drawn, s.overflow ? " (capacity reached)" : "", s.retested, s.residentGroups, streamer.residentMB,
                      streamer.poolBytes >> 20, s.pending)
    }
}
