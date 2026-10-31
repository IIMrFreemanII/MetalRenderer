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

/// Virtual geometry in the top-level structure: what the virtual instances' descriptors point at, and what the ray
/// queries and hits read of it (TraceScene.vgBlas): a BLAS per virtual instance over its current cut (VirtualBLAS). The
/// instance's descriptor names it, and a new cut rebuilds the top-level structure over it.
package final class VirtualTracing {
    let blas: VirtualBLAS
    /// The virtual instances, in their rank (GPUInstanceData.pad1 - 1).
    private let virtualInstances: [Int]
    /// A structure for a descriptor that has none yet (masked out: no ray meets it).
    private let placeholder: MTLAccelerationStructure
    private let placeholderBuffer: MTLBuffer
    /// Per slot: the VirtualBLAS version its descriptors were written for (-1: none yet).
    private var written: [Int]

    package init(device: MTLDevice, queue: MTLCommandQueue, scene: Scene, slots: Int) throws {
        let virtual = scene.instances.indices.filter { scene.instances[$0].virtualMesh >= 0 }
        let pairs = virtual.map { ($0, scene.instances[$0].virtualMesh) }
        virtualInstances = virtual
        blas = try VirtualBLAS(device: device, meshes: scene.virtualMeshes, instances: pairs, slots: slots)
        written = [Int](repeating: -1, count: slots)
        // One inactive triangle (NaN), for the descriptors that point at nothing yet. (Not one far away: its instance
        // would stretch the top-level structure to it, which hardware traversal pays for at every ray.)
        let far = [SIMD4<Float>](repeating: SIMD4(.nan, .nan, .nan, 0), count: 3)
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

    /// The structures the descriptors name (the top-level structure's build reads them).
    func structures(slot: Int) -> [MTLAccelerationStructure] {
        [placeholder] + blas.structures.compactMap { $0 }
    }

    /// What `slot`'s ray queries and hits read through TraceScene.
    func resources(slot: Int) -> [MTLResource] {
        blas.resources(slot: slot) + [placeholder]
    }

    func vgTable(_ slot: Int) -> MTLBuffer { blas.table(slot: slot) }

    /// What the per-instance BLASes retired since the last call (VirtualBLAS.takeReleased).
    func takeReleased() -> [MTLResource] { blas.takeReleased() }

    /// Render thread, before encoding `frame`: the next cut (VirtualBLAS swaps in the BLASes it has finished).
    func update(frame: UInt32, slot: Int, framesInFlight: Int, view: VGView, scene: Scene) {
        blas.update(frame: frame, slot: slot, framesInFlight: framesInFlight, camPos: view.camPos, pixelScale: view.pixelScale,
                    tau: view.tau, sceneInstances: scene.instances)
    }

    /// Writes the virtual instances' descriptors into `slot`'s: true if the structures they name changed since the
    /// slot's last ones, when the top-level structure must be built again rather than refitted. `stride`: an indirect
    /// descriptor's (they name their structures by resource ID).
    func writeDescriptors(slot: Int, into buffer: MTLBuffer, stride: Int, scene: Scene) -> Bool {
        let base = buffer.contents()
        let options = MTLAccelerationStructureInstanceOptions([.opaque, .disableTriangleCulling]).rawValue
        let current = blas.structures
        for (rank, i) in virtualInstances.enumerated() {
            let structure = current[rank]
            SceneBuffers.writeDescriptor(base + i * stride, transform: scene.instances[i].transform, options: options,
                                         mask: structure == nil ? 0 : scene.instances[i].mask, userID: UInt32(i),
                                         structure: structure ?? placeholder)
        }
        defer { written[slot] = blas.version }
        return written[slot] != blas.version
    }

    /// Stats for the benchmark log.
    var summary: String { blas.summary }
}
