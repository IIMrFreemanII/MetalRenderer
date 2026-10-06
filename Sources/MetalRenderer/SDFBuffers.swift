import Metal
import QuartzCore
import simd

/// The scene's SDF shapes on the GPU (MSL SDFScene in Shaders/SDF.metal): the shapes, their nodes, the baked grids and
/// their samples, and a record of the four addresses that both tracers march them by (the custom one through
/// RTScene.sdf, Metal's through the boxes' primitive data). For Metal's tracer also a structure of one box per shape,
/// the shape's, whose primitive data names it (MSL `SDFBox`); an SDF shape's instance points at its shape's box, as
/// a mesh's instance at its mesh's structure, and the ray queries march what their loop is handed (Intersect.metal).
final class SDFBuffers {
    /// MSL `SDFBox`: laid out as VoxelGrids.BoxData, `tag` where that has its level.
    struct BoxData {
        var scene: UInt64
        var shape: UInt32
        var pad0: UInt32 = 0
        var tag: UInt32 = SDFBuffers.boxTag
        var pad: (UInt32, UInt32, UInt32) = (0, 0, 0)
    }
    static let boxTag: UInt32 = 0xFFFF_FFFF

    let shapes: MTLBuffer
    let nodes: MTLBuffer
    let volumes: MTLBuffer
    let cells: MTLBuffer
    let scene: MTLBuffer
    let shapeCount: Int
    /// Metal's tracer: shape s's box is `boxes[s]` (`buildBoxes`).
    private(set) var boxes: [MTLAccelerationStructure] = []
    private var boxBuffers: [MTLBuffer] = []

    /// What a frame reads of it, besides the structures.
    var buffers: [MTLBuffer] { [shapes, nodes, volumes, cells, scene] + boxBuffers }

    init(device: MTLDevice, scene sdf: Scene) throws {
        func buffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
            guard let made = array.withUnsafeBytes({ raw in
                raw.isEmpty ? device.makeBuffer(length: 16, options: .storageModeShared)
                            : device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
            }) else { throw RendererError.resourceCreation("buffer \(label)") }
            made.label = label
            return made
        }
        var records: [GPUSDFShape] = [], nodeRecords: [GPUSDFNode] = []
        for (s, shape) in sdf.sdfShapes.enumerated() {
            let box = sdf.sdfBounds[s]
            records.append(GPUSDFShape(lo: SIMD4(box.lo, shape.stepScale), hi: SIMD4(box.hi, 0),
                                       range: SIMD4(UInt32(nodeRecords.count), UInt32(shape.nodes.count), 0, 0)))
            nodeRecords += shape.gpuNodes
        }
        var volumeRecords: [GPUSDFVolume] = [], samples: [Float16] = []
        for v in sdf.sdfVolumes {
            volumeRecords.append(v.gpu(firstSample: samples.count))
            samples += v.samples
        }
        shapeCount = records.count
        shapes = try buffer(records, "sdfShapes")
        nodes = try buffer(nodeRecords, "sdfNodes")
        volumes = try buffer(volumeRecords, "sdfVolumes")
        cells = try buffer(samples, "sdfCells")
        scene = try buffer([shapes.gpuAddress, nodes.gpuAddress, volumes.gpuAddress, cells.gpuAddress], "sdfScene")
        if !records.isEmpty {
            print(String(format: "SDF shapes: %d shapes, %d nodes, %d grids (%.1f MB)", records.count, nodeRecords.count,
                         volumeRecords.count, Double(samples.count * 2) / 1_048_576))
        }
    }

    /// Metal's tracer: one structure per shape, each a single box, built side by side on `queue` (a Metal 3 one,
    /// whatever the frames are encoded with), and waited for.
    func buildBoxes(device: MTLDevice, queue: MTLCommandQueue, scene sdf: Scene) throws {
        guard shapeCount > 0, boxes.isEmpty else { return }
        func buffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
            guard let made = array.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            made.label = label
            return made
        }
        let bounds = try buffer(sdf.sdfBounds.map { b in
            MTLAxisAlignedBoundingBox(min: MTLPackedFloat3Make(b.lo.x, b.lo.y, b.lo.z), max: MTLPackedFloat3Make(b.hi.x, b.hi.y, b.hi.z))
        }, "sdfBounds")
        let data = try buffer((0..<shapeCount).map { BoxData(scene: scene.gpuAddress, shape: UInt32($0)) }, "sdfBoxData")
        boxBuffers = [bounds, data]
        let boxStride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride, dataStride = MemoryLayout<BoxData>.stride
        precondition(dataStride == 32 && MemoryLayout<BoxData>.offset(of: \.tag) == 16, "SDFBox: Shaders/Intersect.metal")
        var descriptors: [MTLPrimitiveAccelerationStructureDescriptor] = []
        for s in 0..<shapeCount {
            let geometry = MTLAccelerationStructureBoundingBoxGeometryDescriptor()
            geometry.boundingBoxBuffer = bounds
            geometry.boundingBoxBufferOffset = s * boxStride
            geometry.boundingBoxStride = boxStride
            geometry.boundingBoxCount = 1
            geometry.opaque = false
            geometry.primitiveDataBuffer = data
            geometry.primitiveDataBufferOffset = s * dataStride
            geometry.primitiveDataStride = dataStride
            geometry.primitiveDataElementSize = dataStride
            let d = MTLPrimitiveAccelerationStructureDescriptor()
            d.geometryDescriptors = [geometry]
            descriptors.append(d)
        }
        var structures: [MTLAccelerationStructure] = [], scratchOffsets: [Int] = [], scratchSize = 0
        for d in descriptors {
            let sizes = device.accelerationStructureSizes(descriptor: d)
            guard let s = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else {
                throw RendererError.resourceCreation("SDF box structure")
            }
            s.label = "sdfBox"
            structures.append(s)
            scratchOffsets.append(scratchSize)
            scratchSize += (max(sizes.buildScratchBufferSize, 16) + 255) & ~255
        }
        guard let scratch = device.makeBuffer(length: scratchSize, options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RendererError.resourceCreation("SDF box build")
        }
        for (i, d) in descriptors.enumerated() {
            enc.build(accelerationStructure: structures[i], descriptor: d, scratchBuffer: scratch, scratchBufferOffset: scratchOffsets[i])
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        boxes = structures
    }
}
