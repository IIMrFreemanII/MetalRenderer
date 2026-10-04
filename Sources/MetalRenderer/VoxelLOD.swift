import Foundation
import Metal
import QuartzCore
import simd

/// Metal's tracer: distance level of detail for baked plants, by their voxel grids (FoliageVoxels, VoxelGrids). As on
/// the custom tracer (rtPrepKernel), a plant far enough that a voxel of one of its grid's levels is smaller than the
/// "Distance LOD (voxels)" bias in traced pixels is that level's voxels: its wood instance points at the level's box
/// (whose rays the ray queries march through the grid, Shaders/Intersect.metal) and its leaf instance is masked out.
///
/// A still scene's top-level structure is built once, for tracing: the levels change it by building another in the
/// background (`rebuild`), which the renderer swaps in at a frame's start (`swap`). Its levels trail the camera by
/// a few frames; the frames trace as fast as before.
final class VoxelLOD {
    /// A baked plant's instance that has a grid: its wood's, or its leaves'.
    struct Entry {
        var position: SIMD3<Float>
        var size: Float                 // its grid's level 0 voxel, placed (the grid's size x the instance's scale)
        var jitter: Float               // its own offset of the level boundaries (as rtPrepKernel's)
        var descriptor: Int             // its instance descriptor
        var mesh: Int
        var grid: Int
        var leaves: Bool
        var mask: UInt32
    }

    let grids: VoxelGrids
    private let entries: [Entry]
    /// Each entry's: 0 = its triangles, else the level of its grid it is traced at + 1.
    private var levels: [UInt8]
    private let descriptors: MTLBuffer
    private let stride: Int
    private let indirect: Bool
    private let primitives: [MTLAccelerationStructure]   // the meshes', then the boxes'
    private let meshCount: Int
    private let instanceCount: Int
    private let usage: MTLAccelerationStructureUsage
    private let scratch: MTLBuffer
    /// The structure the frames trace, and the one the next levels are built into.
    private(set) var current: MTLAccelerationStructure
    private var spare: MTLAccelerationStructure
    /// The view the levels were last picked for: (camera position, bias / pixel scale), as rtPrepKernel's lodView.
    private(set) var pickedView: SIMD4<Float>?
    /// What the last `rebuild` took: picking (CPU) and building, and how many instances it changed.
    private(set) var last: (pickMs: Double, buildMs: Double, changed: Int) = (0, 0, 0)

    /// `descriptors`: the still scene's, all its instances at their meshes; `current`: the structure built from them.
    init(device: MTLDevice, grids: VoxelGrids, entries: [Entry], descriptors: MTLBuffer, stride: Int, indirect: Bool,
         primitives: [MTLAccelerationStructure], meshCount: Int, instanceCount: Int, usage: MTLAccelerationStructureUsage,
         current: MTLAccelerationStructure, scratch: MTLBuffer) throws {
        (self.grids, self.entries, self.descriptors, self.stride, self.indirect) = (grids, entries, descriptors, stride, indirect)
        (self.primitives, self.meshCount, self.instanceCount, self.usage, self.current, self.scratch) =
            (primitives, meshCount, instanceCount, usage, current, scratch)
        levels = [UInt8](repeating: 0, count: entries.count)
        guard let spare = device.makeAccelerationStructure(size: current.size) else {
            throw RendererError.resourceCreation("instance acceleration structure (voxel levels)")
        }
        spare.label = "instances (voxel levels)"
        self.spare = spare
    }

    var megabytes: Double { Double(spare.size) / 1_048_576 }

    // MARK: - Levels

    /// rtPrepKernel's level for a plant at `distance` from the camera: 0 = its triangles, else the level + 1.
    /// `view`: bias in traced pixels / the view's pixel scale (0 = always triangles).
    static func level(distance: Float, size: Float, view: Float, jitter: Float) -> UInt8 {
        guard view > 0 else { return 0 }
        let lod = log2(distance * view / size) + jitter
        return lod < 0 ? 0 : UInt8(min(Int(lod), FoliageVoxels.levels - 1) + 1)
    }

    /// MSL pcgHash (Shaders/Sampling.metal).
    static func pcgHash(_ v: UInt32) -> UInt32 {
        let state = v &* 747796405 &+ 2891336453
        let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
        return (word >> 22) ^ word
    }

    /// A plant's offset of its level boundaries: the same for its wood and its leaves (they stand at one place).
    static func jitter(_ position: SIMD3<Float>) -> Float {
        let h = pcgHash(position.x.bitPattern ^ pcgHash(position.z.bitPattern ^ pcgHash(position.y.bitPattern)))
        return Float(h & 0xFF) * (0.5 / 255) - 0.25
    }

    /// The entry of an instance, if its mesh has a grid (`meshVoxels`: Scene.meshVoxels).
    static func entry(descriptor: Int, transform m: float4x4, mesh: Int, mask: UInt32, meshVoxels: [Int: UInt32],
                      grids: [FoliageVoxels.Grid]) -> Entry? {
        guard let v = meshVoxels[mesh] else { return nil }
        let grid = Int(v & ~Scene.meshVoxelsLeaves), position = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let scale = length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        return Entry(position: position, size: grids[grid].lo.w * scale, jitter: jitter(position), descriptor: descriptor, mesh: mesh,
                     grid: grid, leaves: v & Scene.meshVoxelsLeaves != 0, mask: mask)
    }

    /// Picks every entry's level for `view` and writes the descriptors of the ones that changed. Returns how many.
    private func pick(_ view: SIMD4<Float>) -> Int {
        let camera = SIMD3(view.x, view.y, view.z), w = view.w
        var next = levels
        let part = 8192, count = entries.count
        next.withUnsafeMutableBufferPointer { out in
            entries.withUnsafeBufferPointer { e in
                DispatchQueue.concurrentPerform(iterations: (count + part - 1) / part) { k in
                    for i in (k * part)..<min((k + 1) * part, count) {
                        out[i] = VoxelLOD.level(distance: distance(e[i].position, camera), size: e[i].size, view: w, jitter: e[i].jitter)
                    }
                }
            }
        }
        var changed = 0
        let base = descriptors.contents()
        for i in 0..<count where next[i] != levels[i] {
            write(base + entries[i].descriptor * stride, entries[i], level: next[i])
            changed += 1
        }
        levels = next
        pickedView = view
        return changed
    }

    /// Bytes 48 on of an entry's descriptor (the transform stays): at its mesh, or its wood at a box and its leaves
    /// masked out.
    private func write(_ p: UnsafeMutableRawPointer, _ e: Entry, level: UInt8) {
        let voxels = level > 0
        let options: MTLAccelerationStructureInstanceOptions = voxels && !e.leaves ? [.nonOpaque, .disableTriangleCulling]
                                                                                   : [.opaque, .disableTriangleCulling]
        let mask = !voxels ? e.mask : e.leaves ? 0 : Scene.maskVoxels
        let index = voxels && !e.leaves ? meshCount + VoxelGrids.levels * e.grid + Int(level) - 1 : e.mesh
        p.storeBytes(of: options.rawValue, toByteOffset: 48, as: UInt32.self)
        p.storeBytes(of: mask, toByteOffset: 52, as: UInt32.self)
        if indirect {
            p.storeBytes(of: primitives[index].gpuResourceID, toByteOffset: 64, as: MTLResourceID.self)   // (the user ID at 60 stays)
        } else {
            p.storeBytes(of: UInt32(index), toByteOffset: 60, as: UInt32.self)
        }
    }

    // MARK: - Structures

    /// Picks the levels for `view` and, if any changed, builds the spare structure from them on `queue` and waits:
    /// true if there is one to `swap` in. Off the main thread; not while the spare is still traced (Renderer).
    func rebuild(for view: SIMD4<Float>, queue: MTLCommandQueue) -> Bool {
        let start = CACurrentMediaTime()
        let changed = pick(view)
        let picked = CACurrentMediaTime()
        guard changed > 0 else { last = ((picked - start) * 1000, 0, 0); return false }
        let build = TLASUpdate(structure: spare, scratch: scratch, refit: false, instanceCount: instanceCount, usage: usage,
                               instances: descriptors, instanceStride: stride, primitives: primitives)
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() else { return false }
        // Indirect descriptors name the meshes' structures by ID: the build reads them, so they must be resident.
        if indirect { enc.useResources(primitives, usage: .read) }
        enc.build(accelerationStructure: spare, descriptor: build.descriptor(indirect: indirect), scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        last = ((picked - start) * 1000, (CACurrentMediaTime() - picked) * 1000, changed)
        return cmd.status == .completed
    }

    /// The structure `rebuild` built becomes the one the frames trace; the old one is the next spare.
    func swap() { (current, spare) = (spare, current) }
}
