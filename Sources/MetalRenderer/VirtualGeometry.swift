import Foundation
import Metal
import simd

/// Kernels of virtual geometry's per-frame cut (Shaders/VirtualGeometry.metal).
struct VGPipelines {
    let reset, cut, boxes: MTLComputePipelineState
}

/// Virtual geometry traced as clusters (`METALRENDERER_VG_MODE=clusters`; the default is a BLAS per instance over its
/// cut, VirtualBLAS): every frame the GPU picks a cut through each virtual mesh's cluster DAG (vgCutKernel), asks for
/// finer groups it would have liked, which its VGStreamer loads, and writes each picked cluster's box in world space
/// (vgBoxesKernel). Metal builds a structure over the boxes (`work`), one instance of the top-level structure
/// (VirtualTracing), and the ray queries walk the clusters' own BVHs in the boxes they meet (Shaders/Intersect.metal).
final class VirtualGeometry {
    static let clusterMode = ProcessInfo.processInfo.environment["METALRENDERER_VG_MODE"] == "clusters"
    static let capacity = 65536          // most clusters selected per frame (the structure's boxes)
    static let requestCapacity = 4096
    /// A box's primitive data (MSL ClusterBox): its instance's world -> object rows, its place in the cut, its mask.
    static let boxDataStride = 64
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
    private let leafBoxes: MTLBuffer
    private var counterBuffers: [MTLBuffer] = []      // per slot: selected, requests, overflow, triangles
    private var requestBuffers: [MTLBuffer] = []
    private(set) var selectedBuffers: [MTLBuffer] = []
    /// Per slot: the boxes (MTLAxisAlignedBoundingBox), their data (ClusterBox), and the structure over them.
    private var boxBuffers: [MTLBuffer] = [], boxDataBuffers: [MTLBuffer] = []
    private(set) var structures: [MTLAccelerationStructure] = []
    private var descriptors: [MTLPrimitiveAccelerationStructureDescriptor] = []
    private let scratch: MTLBuffer

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

        // Per virtual instance: scene instance, cluster range, first work item (MSL VGInstance).
        var table: [SIMD4<UInt32>] = []
        var work = 0
        for (instance, mesh) in instances {
            let count = meshes[mesh].clusters.count
            table.append(SIMD4(UInt32(instance), UInt32(streamer.meshClusterBase[mesh]), UInt32(count), UInt32(work)))
            work += count
        }
        workCount = work
        instanceCount = instances.count
        sourceTriangles = instances.reduce(0) { $0 + meshes[$1.mesh].triangleCount }

        let tableData = try buffer(table.count * 16, "vgInstances", shared: true)
        table.withUnsafeBytes { if $0.count > 0 { tableData.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        instanceTable = tableData

        let cap = VirtualGeometry.capacity
        leafBoxes = try buffer(cap * 32, "vgLeafBoxes")
        var scratchBytes = 16
        for slot in 0..<slots {
            counterBuffers.append(try buffer(16, "vgCounters\(slot)", shared: true))
            requestBuffers.append(try buffer(VirtualGeometry.requestCapacity * 8, "vgRequests\(slot)", shared: true))
            selectedBuffers.append(try buffer(cap * 8, "vgSelected\(slot)"))
            let boxes = try buffer(cap * MemoryLayout<MTLAxisAlignedBoundingBox>.stride, "vgBoxes\(slot)")
            let data = try buffer(cap * VirtualGeometry.boxDataStride, "vgBoxData\(slot)")
            let geometry = MTLAccelerationStructureBoundingBoxGeometryDescriptor()
            geometry.boundingBoxBuffer = boxes
            geometry.boundingBoxStride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride
            geometry.boundingBoxCount = cap
            geometry.primitiveDataBuffer = data
            geometry.primitiveDataStride = VirtualGeometry.boxDataStride
            geometry.primitiveDataElementSize = VirtualGeometry.boxDataStride
            geometry.opaque = false   // the ray queries' loop gets every box (boxCandidate)
            let d = MTLPrimitiveAccelerationStructureDescriptor()
            d.geometryDescriptors = [geometry]
            d.usage = .preferFastBuild
            let sizes = device.accelerationStructureSizes(descriptor: d)
            guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else {
                throw RendererError.resourceCreation("the cut's acceleration structure")
            }
            accel.label = "vgClusters\(slot)"
            scratchBytes = max(scratchBytes, sizes.buildScratchBufferSize)
            boxBuffers.append(boxes)
            boxDataBuffers.append(data)
            structures.append(accel)
            descriptors.append(d)
        }
        scratch = try buffer(scratchBytes, "vgClustersScratch")
        print(String(format: "Virtual geometry (clusters): %d meshes, %d instances, %d clusters in %d groups, pool %d MB (roots %.1f MB)",
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
        var workCount, instanceCount, capacity, frame, requestCapacity, pad0, pad1: UInt32
    }

    /// Encodes the cut and its boxes (`instanceData`: the slot's instance records).
    func encode(_ enc: ComputePass, slot: Int, vg: VGPipelines, instanceData: MTLBuffer, camPos: SIMD3<Float>, pixelScale: Float,
                tau: Float, frame: UInt32) {
        let groupPage = streamer.bindPages(slot: slot)
        func dispatch(_ pso: MTLComputePipelineState, _ threads: Int, group: Int = 64) {
            enc.setComputePipelineState(pso)
            enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(group, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        var p = Params(camPos: SIMD4(camPos, pixelScale), tau: tau, workCount: UInt32(workCount), instanceCount: UInt32(instanceCount),
                       capacity: UInt32(VirtualGeometry.capacity), frame: frame, requestCapacity: UInt32(VirtualGeometry.requestCapacity),
                       pad0: 0, pad1: 0)
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
        dispatch(vg.cut, workCount)
        enc.setBuffer(boxBuffers[slot], offset: 0, index: 11)
        enc.setBuffer(boxDataBuffers[slot], offset: 0, index: 12)
        dispatch(vg.boxes, VirtualGeometry.capacity)
    }

    /// The build of `slot`'s structure over the boxes `encode` wrote: after it, ahead of the top-level structure.
    struct Build: PrimitiveWork {
        let structure: MTLAccelerationStructure
        let descriptor: MTLPrimitiveAccelerationStructureDescriptor
        let scratch: MTLBuffer

        func encode(into enc: MTLAccelerationStructureCommandEncoder, part: Int) {
            enc.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
        }
    }
    func build(slot: Int) -> Build { Build(structure: structures[slot], descriptor: descriptors[slot], scratch: scratch) }

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

    /// What `slot`'s ray queries read: the pool and the cut (the boxes' data through the structure).
    func resources(slot: Int) -> [MTLResource] { [pool, selectedBuffers[slot], boxDataBuffers[slot], structures[slot]] }
}
