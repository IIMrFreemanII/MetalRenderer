import Foundation
import Metal
import simd

/// Kernels of virtual geometry's per-frame cut (Shaders/VirtualGeometry.metal).
struct VGPipelines {
    let reset, cut, finish, pad, hierarchy, fit: MTLComputePipelineState
}

/// Virtual geometry at run time (custom ray tracer): every frame the GPU picks a cut through each virtual mesh's
/// cluster DAG (vgCutKernel), builds a top-level tree over the picked clusters with the same LBVH kernels as the
/// moving instances, and asks for finer groups it would have liked, which its VGStreamer loads.
final class VirtualGeometry {
    static let capacity = 65536          // most clusters selected per frame (the cluster tree's leaves)
    static let requestCapacity = 4096
    /// Streaming and LOD updates on the calling thread (deterministic): see VGStreamer.sync.
    static let sync = VGStreamer.sync

    let streamer: VGStreamer
    var poolBytes: Int { streamer.poolBytes }
    var pool: MTLBuffer { streamer.pool }
    private let instanceTable: MTLBuffer
    private let workCount: Int
    let instanceCount: Int
    /// Triangles at the finest level, over every instance (what drawing without LOD would trace).
    let sourceTriangles: Int
    private let leafBoxes, keys, values, nodeParent, leafParent, fitCounters, counts: MTLBuffer
    private var counterBuffers: [MTLBuffer] = []      // per slot: selected, requests, overflow, triangles
    private var requestBuffers: [MTLBuffer] = []
    private(set) var selectedBuffers: [MTLBuffer] = []
    private(set) var rootsBuffers: [MTLBuffer] = []
    private(set) var nodeInstanceBuffers: [MTLBuffer] = []   // per slot: each cluster-tree node's instance (RT_ENTER)

    private var cutCounts = (selected: 0, triangles: 0, overflow: false)
    var stats: (selected: Int, triangles: Int, overflow: Bool, residentGroups: Int, pending: Int, loadedThisFrame: Int) {
        lock.lock(); let c = cutCounts; lock.unlock()
        let s = streamer.stats
        return (c.selected, c.triangles, c.overflow, s.residentGroups, s.pending, s.loadedThisFrame)
    }
    private let lock = NSLock()

    /// `instances`: (scene instance index, virtual mesh index) for every virtual instance.
    init(device: MTLDevice, meshes: [VirtualMesh], instances: [(instance: Int, mesh: Int)], poolMB: Int, slots: Int) throws {
        func buffer(_ length: Int, _ label: String, shared: Bool = false) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 16), options: shared ? .storageModeShared : .storageModePrivate) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            b.label = label
            return b
        }
        streamer = try VGStreamer(device: device, meshes: meshes, poolMB: poolMB, slots: slots)

        // Per virtual instance: scene instance, cluster range, first work item, mesh bounds (MSL VGInstance).
        var table: [SIMD4<UInt32>] = []
        var work = 0
        precondition(instances.count <= 256, "the cluster tree's keys have 8 bits for the virtual instance")
        for (instance, mesh) in instances {
            let count = meshes[mesh].clusters.count
            let b = meshes[mesh].bounds
            table.append(SIMD4(UInt32(instance), UInt32(streamer.meshClusterBase[mesh]), UInt32(count), UInt32(work)))
            table.append(SIMD4(b.lo.x.bitPattern, b.lo.y.bitPattern, b.lo.z.bitPattern, 0))
            table.append(SIMD4(b.hi.x.bitPattern, b.hi.y.bitPattern, b.hi.z.bitPattern, 0))
            work += count
        }
        workCount = work
        instanceCount = instances.count
        sourceTriangles = instances.reduce(0) { $0 + meshes[$1.mesh].triangleCount }

        let tableData = try buffer(table.count * 16, "vgInstances", shared: true)   // 48 bytes per instance
        table.withUnsafeBytes { if $0.count > 0 { tableData.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        instanceTable = tableData

        let cap = VirtualGeometry.capacity
        leafBoxes = try buffer(cap * 32, "vgLeafBoxes")
        keys = try buffer(cap * 4, "vgKeys")
        values = try buffer(cap * 4, "vgValues")
        nodeParent = try buffer(cap * 4, "vgNodeParent")
        leafParent = try buffer(cap * 4, "vgLeafParent")
        fitCounters = try buffer(cap * 4, "vgFitCounters")
        counts = try buffer(16, "vgCounts")
        for slot in 0..<slots {
            counterBuffers.append(try buffer(16, "vgCounters\(slot)", shared: true))
            requestBuffers.append(try buffer(VirtualGeometry.requestCapacity * 8, "vgRequests\(slot)", shared: true))
            selectedBuffers.append(try buffer(cap * 8, "vgSelected\(slot)"))
            let roots = try buffer(16, "vgRoots\(slot)", shared: true)
            roots.contents().storeBytes(of: BVHNode.none, as: UInt32.self)
            rootsBuffers.append(roots)
            nodeInstanceBuffers.append(try buffer(cap * 4, "vgNodeInstance\(slot)"))
        }
        print(String(format: "Virtual geometry: %d meshes, %d instances, %d clusters in %d groups, pool %d MB (roots %.1f MB)",
                     meshes.count, instanceCount, streamer.clusterCount, streamer.groupCount, poolBytes >> 20,
                     Double(streamer.rootBytes) / 1_048_576))
    }

    var residentMB: Double { streamer.residentMB }
    var meshCount: Int { streamer.meshes.count }
    var groupCount: Int { streamer.groupCount }
    var clusterCount: Int { streamer.clusterCount }
    var summary: String {
        let stats = stats
        return String(format: "VG: %d triangles in %d clusters drawn%@, %d groups resident (%.0f MB of %d), %d requests waiting",
                      stats.triangles, stats.selected, stats.overflow ? " (capacity reached)" : "", stats.residentGroups, residentMB,
                      poolBytes >> 20, stats.pending)
    }

    // MARK: Per frame

    /// VGParams in Shaders/VirtualGeometry.metal (48 bytes).
    struct Params {
        var camPos: SIMD4<Float>
        var tau: Float
        var workCount, instanceCount, capacity, frame, requestCapacity, nodeBase, pad: UInt32
    }

    /// Encodes the cut and the cluster tree build. `nodeBase`: the tree's first node in `tlasNodes`.
    func encode(_ enc: ComputePass, slot: Int, rt: RTPipelines, vg: VGPipelines, instanceData: MTLBuffer,
                tlasNodes: MTLBuffer, nodeBase: Int, camPos: SIMD3<Float>, pixelScale: Float, tau: Float, frame: UInt32) {
        let groupPage = streamer.bindPages(slot: slot)
        func dispatch(_ pso: MTLComputePipelineState, _ threads: Int, group: Int = 64) {
            enc.setComputePipelineState(pso)
            enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(group, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        var p = Params(camPos: SIMD4(camPos, pixelScale), tau: tau, workCount: UInt32(workCount), instanceCount: UInt32(instanceCount),
                       capacity: UInt32(VirtualGeometry.capacity), frame: frame, requestCapacity: UInt32(VirtualGeometry.requestCapacity),
                       nodeBase: UInt32(nodeBase), pad: 0)
        enc.setBuffer(counterBuffers[slot], offset: 0, index: 0)
        dispatch(vg.reset, 1)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.setBuffer(instanceTable, offset: 0, index: 1)
        enc.setBuffer(streamer.clusterBuffer, offset: 0, index: 2)
        enc.setBuffer(groupPage, offset: 0, index: 3)
        enc.setBuffer(instanceData, offset: 0, index: 4)
        enc.setBuffer(counterBuffers[slot], offset: 0, index: 5)
        enc.setBuffer(selectedBuffers[slot], offset: 0, index: 6)
        enc.setBuffer(leafBoxes, offset: 0, index: 7)
        enc.setBuffer(requestBuffers[slot], offset: 0, index: 8)
        enc.setBuffer(streamer.requestStamp, offset: 0, index: 9)
        enc.setBuffer(streamer.lastUsed, offset: 0, index: 10)
        enc.setBuffer(keys, offset: 0, index: 13)
        enc.setBuffer(values, offset: 0, index: 14)
        dispatch(vg.cut, workCount)
        enc.setBuffer(counts, offset: 0, index: 11)
        enc.setBuffer(rootsBuffers[slot], offset: 0, index: 12)
        dispatch(vg.finish, 1)
        dispatch(vg.pad, VirtualGeometry.capacity)

        // The cluster tree: keys come from the cut (instance first, then Morton), so it splits by instance and each
        // instance's part stays in its object space (vgHierarchyKernel / vgFitKernel).
        CustomRayTracer.encodeSort(enc, rt: rt, counts: .buffer(counts), capacity: VirtualGeometry.capacity, keys: keys, values: values)
        var params = SIMD2<UInt32>(0, UInt32(nodeBase))
        enc.setBytes(&params, length: 8, index: 0)
        enc.setBuffer(keys, offset: 0, index: 1)
        enc.setBuffer(values, offset: 0, index: 2)
        enc.setBuffer(leafBoxes, offset: 0, index: 3)
        enc.setBuffer(tlasNodes, offset: nodeBase * MemoryLayout<BVHNode>.stride, index: 4)
        enc.setBuffer(nodeParent, offset: 0, index: 5)
        enc.setBuffer(leafParent, offset: 0, index: 6)
        enc.setBuffer(fitCounters, offset: 0, index: 7)
        enc.setBuffer(counts, offset: 0, index: 8)
        enc.setBuffer(selectedBuffers[slot], offset: 0, index: 9)
        enc.setBuffer(nodeInstanceBuffers[slot], offset: 0, index: 10)
        enc.setBuffer(rootsBuffers[slot], offset: 0, index: 12)
        enc.setBuffer(instanceData, offset: 0, index: 15)
        dispatch(vg.hierarchy, VirtualGeometry.capacity - 1)
        dispatch(vg.fit, VirtualGeometry.capacity)
    }

    /// The frame that used `slot` has finished on the GPU: collect its requests (any thread).
    func collect(slot: Int, frame: UInt32) {
        let c = counterBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: 4)
        let n = min(Int(c[1]), VirtualGeometry.requestCapacity)
        let r = requestBuffers[slot].contents().bindMemory(to: SIMD2<UInt32>.self, capacity: VirtualGeometry.requestCapacity)
        streamer.addRequests(r, count: n, frame: frame)
        lock.lock()
        cutCounts = (Int(c[0]), Int(c[3]), c[2] != 0)
        lock.unlock()
    }

    /// Render thread, before encoding `frame`: see VGStreamer.update.
    func update(frame: UInt32, framesInFlight: Int) { streamer.update(frame: frame, framesInFlight: framesInFlight) }

    func resources(slot: Int) -> [MTLResource] { [pool, selectedBuffers[slot], rootsBuffers[slot], nodeInstanceBuffers[slot]] }
}
