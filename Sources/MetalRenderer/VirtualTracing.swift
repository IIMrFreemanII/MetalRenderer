import Foundation
import Metal
import simd

/// Virtual geometry in the top-level structure: what the virtual instances' descriptors point at, and what the ray
/// queries and hits read of it (TraceScene.vgBlas, .clusters, .pool). Either
/// * a BLAS per virtual instance over its current cut (VirtualBLAS, the default): the instance's descriptor names it,
///   and a new cut rebuilds the top-level structure over it; or
/// * this frame's cut of clusters as boxes (VirtualGeometry, `METALRENDERER_VG_MODE=clusters`): one instance of their
///   own after the scene's (`extraInstances`), whose structure the frame builds; the virtual instances are masked out.
final class VirtualTracing {
    let blas: VirtualBLAS?
    let clusters: VirtualGeometry?
    /// The virtual instances, in their rank (GPUInstanceData.pad1 - 1).
    private let virtualInstances: [Int]
    /// The cluster instance's mask: every virtual instance's.
    private let clusterMask: UInt32
    /// A structure for a descriptor that has none yet (masked out: no ray meets it).
    private let placeholder: MTLAccelerationStructure
    private let placeholderBuffer: MTLBuffer
    /// Per slot: the VirtualBLAS version its descriptors were written for (-1: none yet).
    private var written: [Int]

    /// Instances the top-level structure has after the scene's own.
    var extraInstances: Int { clusters == nil ? 0 : 1 }

    init(device: MTLDevice, queue: MTLCommandQueue, scene: Scene, poolMB: Int, slots: Int) throws {
        let virtual = scene.instances.indices.filter { scene.instances[$0].virtualMesh >= 0 }
        let pairs = virtual.map { ($0, scene.instances[$0].virtualMesh) }
        virtualInstances = virtual
        clusterMask = virtual.reduce(0) { $0 | scene.instances[$1].mask }
        if VirtualGeometry.clusterMode {
            clusters = try VirtualGeometry(device: device, meshes: scene.virtualMeshes, instances: pairs, poolMB: poolMB, slots: slots)
            blas = nil
        } else {
            blas = try VirtualBLAS(device: device, meshes: scene.virtualMeshes, instances: pairs, slots: slots)
            clusters = nil
        }
        written = [Int](repeating: -1, count: slots)
        // One triangle far away, for the descriptors that point at nothing yet.
        let far: [SIMD4<Float>] = [SIMD4(1e30, 1e30, 1e30, 0), SIMD4(1e30, 1e30, 1e30, 0), SIMD4(1e30, 1e30, 1e30, 0)]
        guard let vertices = far.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw RendererError.resourceCreation("buffer vgPlaceholder")
        }
        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = vertices
        geometry.vertexStride = MemoryLayout<SIMD4<Float>>.stride
        geometry.vertexFormat = .float3
        geometry.triangleCount = 1
        geometry.opaque = true
        let d = MTLPrimitiveAccelerationStructureDescriptor()
        d.geometryDescriptors = [geometry]
        let sizes = device.accelerationStructureSizes(descriptor: d)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RendererError.resourceCreation("acceleration structure (vgPlaceholder)")
        }
        enc.build(accelerationStructure: structure, descriptor: d, scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        structure.label = "vgPlaceholder"
        (placeholder, placeholderBuffer) = (structure, vertices)
    }

    /// The structures the descriptors of `slot` name (the top-level structure's build reads them).
    func structures(slot: Int) -> [MTLAccelerationStructure] {
        if let clusters { return [clusters.structures[slot], placeholder] }
        return [placeholder] + (blas?.structures.compactMap { $0 } ?? [])
    }

    /// What `slot`'s ray queries and hits read through TraceScene.
    func resources(slot: Int) -> [MTLResource] {
        (blas?.resources(slot: slot) ?? []) + (clusters?.resources(slot: slot) ?? []) + [placeholder]
    }

    var vgTable: (Int) -> MTLBuffer? { { [blas] slot in blas?.table(slot: slot) } }
    func selected(slot: Int) -> MTLBuffer? { clusters?.selectedBuffers[slot] }
    var pool: MTLBuffer? { clusters?.pool }

    /// Render thread, before encoding `frame`: the next cut (VirtualBLAS swaps in the BLASes it has finished).
    func update(frame: UInt32, slot: Int, framesInFlight: Int, view: VGView, scene: Scene) {
        clusters?.update(frame: frame, framesInFlight: framesInFlight)
        blas?.update(frame: frame, slot: slot, framesInFlight: framesInFlight, camPos: view.camPos, pixelScale: view.pixelScale,
                     tau: view.tau, sceneInstances: scene.instances)
    }

    /// Writes the virtual instances' descriptors into `slot`'s (and the cluster instance's, at `first`): true if the
    /// structures they name changed since the slot's last ones, when the top-level structure must be built again
    /// rather than refitted. `stride`: an indirect descriptor's (they name their structures by resource ID).
    func writeDescriptors(slot: Int, into buffer: MTLBuffer, stride: Int, first: Int, scene: Scene) -> Bool {
        let base = buffer.contents()
        let options = MTLAccelerationStructureInstanceOptions([.opaque, .disableTriangleCulling]).rawValue
        let current = blas?.structures
        for (rank, i) in virtualInstances.enumerated() {
            let structure = current?[rank]
            SceneBuffers.writeDescriptor(base + i * stride, transform: scene.instances[i].transform, options: options,
                                         mask: structure == nil ? 0 : scene.instances[i].mask, userID: UInt32(i),
                                         structure: structure ?? placeholder)
        }
        if let clusters {
            // Its boxes are in world space: the identity. Not opaque: the queries' loop walks the clusters they meet.
            let boxOptions = MTLAccelerationStructureInstanceOptions([.nonOpaque, .disableTriangleCulling]).rawValue
            SceneBuffers.writeDescriptor(base + first * stride, transform: matrix_identity_float4x4, options: boxOptions,
                                         mask: clusterMask, userID: UInt32(first), structure: clusters.structures[slot])
        }
        let version = blas?.version ?? 0
        defer { written[slot] = version }
        return written[slot] != version
    }

    /// Stats for the benchmark log.
    var summary: String? { blas?.summary ?? clusters?.summary }
}
