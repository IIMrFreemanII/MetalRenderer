import Metal
import QuartzCore
import simd

/// Metal's tracer: the plants' voxel grids (FoliageVoxels) on the GPU, and for each grid and level a structure of one
/// bounding box, the grid's, whose primitive data says what the ray queries march through it (MSL `VoxelBox` in
/// Shaders/Intersect.metal). A far plant's wood instance points at one of these instead of its mesh (VoxelLOD).
/// The scenes of an open world share it: the same library in the same order (SceneBuffers.Options.voxelGrids).
final class VoxelGrids {
    /// MSL `VoxelBox`: a box's primitive data.
    struct BoxData {
        var grid: UInt64                // its RTVoxels record
        var cells: UInt64               // every grid's cells (the record's offsets count from here)
        var level: UInt32
        var pad: (UInt32, UInt32, UInt32) = (0, 0, 0)   // (a SIMD3 would be aligned to 16 bytes: 48 in all)
    }

    /// What it was made from: the plants' keys (FoliageVoxels.Plant.key), hashed.
    let key: String
    /// The grids as on the GPU: a plant's voxel size picks its level (VoxelLOD).
    let gridRecords: [FoliageVoxels.Grid]
    let grids: MTLBuffer
    let cells: MTLBuffer
    let boxData: MTLBuffer
    let bounds: MTLBuffer
    /// Grid g's level l is `boxes[levels * g + l]`.
    let boxes: [MTLAccelerationStructure]
    static let levels = FoliageVoxels.levels

    /// What a frame reads of it, besides the structures: the ray queries reach these through the boxes' data.
    var buffers: [MTLBuffer] { [grids, cells, boxData, bounds] }
    var megabytes: Double { Double(buffers.reduce(0) { $0 + $1.length } + boxes.reduce(0) { $0 + $1.size }) / 1_048_576 }

    static func key(_ plants: [FoliageVoxels.Plant]) -> String {
        var hasher = GeneratedCache.Hasher()
        for plant in plants {
            hasher.add(plant.key)
            hasher.add(plant.pieces.map(\.leafCoverage))
        }
        return hasher.name()
    }

    /// Builds the boxes on `queue` and waits for them.
    init(device: MTLDevice, queue: MTLCommandQueue, plants: [FoliageVoxels.Plant]) throws {
        let start = CACurrentMediaTime()
        key = VoxelGrids.key(plants)
        let built = FoliageVoxels.cached(plants)
        gridRecords = built.grids
        func buffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
            guard let made = array.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: max(raw.count, 16), options: .storageModeShared)
            }) else { throw RendererError.resourceCreation("buffer \(label)") }
            made.label = label
            return made
        }
        let grids = try buffer(built.grids.isEmpty ? [FoliageVoxels.Grid()] : built.grids, "voxelGrids")
        let cells = try buffer(built.cells.isEmpty ? [UInt32(0)] : built.cells, "voxelCells")
        (self.grids, self.cells) = (grids, cells)
        let levels = VoxelGrids.levels
        let bounds = try buffer(built.grids.map { g -> MTLAxisAlignedBoundingBox in
            let hi = SIMD3(g.lo.x, g.lo.y, g.lo.z) + SIMD3<Float>(Float(g.dims.x), Float(g.dims.y), Float(g.dims.z)) * g.lo.w
            return MTLAxisAlignedBoundingBox(min: MTLPackedFloat3Make(g.lo.x, g.lo.y, g.lo.z), max: MTLPackedFloat3Make(hi.x, hi.y, hi.z))
        } + [MTLAxisAlignedBoundingBox()], "voxelBounds")
        self.bounds = bounds
        let gridStride = MemoryLayout<FoliageVoxels.Grid>.stride
        let boxData = try buffer(built.grids.indices.flatMap { g in
            (0..<levels).map { BoxData(grid: grids.gpuAddress + UInt64(g * gridStride), cells: cells.gpuAddress, level: UInt32($0)) }
        } + [BoxData(grid: 0, cells: 0, level: 0)], "voxelBoxData")
        self.boxData = boxData

        // One structure per grid and level, each a single box: tiny, built side by side in one command buffer, each
        // with a scratch range of its own.
        let boxStride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride, dataStride = MemoryLayout<BoxData>.stride
        var descriptors: [MTLPrimitiveAccelerationStructureDescriptor] = []
        for g in built.grids.indices {
            for l in 0..<levels {
                let geometry = MTLAccelerationStructureBoundingBoxGeometryDescriptor()
                geometry.boundingBoxBuffer = bounds
                geometry.boundingBoxBufferOffset = g * boxStride
                geometry.boundingBoxStride = boxStride
                geometry.boundingBoxCount = 1
                geometry.opaque = false
                geometry.primitiveDataBuffer = boxData
                geometry.primitiveDataBufferOffset = (levels * g + l) * dataStride
                geometry.primitiveDataStride = dataStride
                geometry.primitiveDataElementSize = dataStride
                let d = MTLPrimitiveAccelerationStructureDescriptor()
                d.geometryDescriptors = [geometry]
                descriptors.append(d)
            }
        }
        var structures: [MTLAccelerationStructure] = [], scratchOffsets: [Int] = [], scratchSize = 0
        for d in descriptors {
            let sizes = device.accelerationStructureSizes(descriptor: d)
            guard let s = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else {
                throw RendererError.resourceCreation("voxel box structure")
            }
            s.label = "voxelBox"
            structures.append(s)
            scratchOffsets.append(scratchSize)
            scratchSize += (max(sizes.buildScratchBufferSize, 16) + 255) & ~255
        }
        boxes = structures
        guard !descriptors.isEmpty else { return }
        let megabytes = self.megabytes
        guard let scratch = device.makeBuffer(length: scratchSize, options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RendererError.resourceCreation("voxel box build")
        }
        for (i, d) in descriptors.enumerated() {
            enc.build(accelerationStructure: structures[i], descriptor: d, scratchBuffer: scratch, scratchBufferOffset: scratchOffsets[i])
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        print(String(format: "Plant voxel boxes: %d grids, %.1f MB, made in %.1f ms", built.grids.count, megabytes,
                     (CACurrentMediaTime() - start) * 1000))
    }
}
