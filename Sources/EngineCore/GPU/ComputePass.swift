import Metal
import QuartzCore

/// What a compute stage encodes into: Metal 4's frame with its argument table (`Metal4Frame`). The methods are
/// `MTLComputeCommandEncoder`'s, so a test can run a stage on a plain encoder (the tests' `Metal3Pass`).
package protocol ComputePass {
    func setComputePipelineState(_ state: MTLComputePipelineState)
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setTexture(_ texture: MTLTexture?, index: Int)
    func setTextures(_ textures: [MTLTexture?], range: Range<Int>)
    func setAccelerationStructure(_ accelerationStructure: MTLAccelerationStructure?, bufferIndex: Int)
    func useResource(_ resource: MTLResource, usage: MTLResourceUsage)
    func useResources(_ resources: [MTLResource], usage: MTLResourceUsage)
    func useHeap(_ heap: MTLHeap)
    func memoryBarrier(scope: MTLBarrierScope)
    func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize)
    func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize)
    /// As many threadgroups as an `MTLDispatchThreadgroupsIndirectArguments` the GPU wrote says.
    func dispatchThreadgroups(indirectBuffer: MTLBuffer, indirectBufferOffset: Int, threadsPerThreadgroup: MTLSize)
    /// What `useResource`, `useResources` and `useHeap` hold for: the frame (a test's encoder). The renderer
    /// declares the scene's resources once per scope (`Renderer.bindScene`).
    var declarationScope: AnyObject { get }
}

/// One named compute dispatch (or a few) of a frame.
package struct ComputeStage {
    package let pass: String
    package let encode: (ComputePass) -> Void

    /// (As the memberwise initializer, for the modules above this one.)
    package init(pass: String, encode: @escaping (ComputePass) -> Void) {
        self.pass = pass
        self.encode = encode
    }
}

/// This frame's update of the top-level acceleration structure: a refit of the tree it has, or a build.
package struct TLASUpdate {
    package let structure: MTLAccelerationStructure
    package let scratch: MTLBuffer
    package let refit: Bool
    package let instanceCount: Int
    package let usage: MTLAccelerationStructureUsage
    /// Metal 3: instance descriptors that index `primitives`, or `indirect` ones, which name them by resource ID
    /// (Metal 4's always are).
    package let instances: MTLBuffer
    package let instanceStride: Int
    package let primitives: [MTLAccelerationStructure]
    package var indirect = false

    /// Metal 3's descriptor for it.
    package var descriptor: MTLInstanceAccelerationStructureDescriptor {
        let d = MTLInstanceAccelerationStructureDescriptor()
        d.instancedAccelerationStructures = primitives
        d.instanceCount = instanceCount
        d.instanceDescriptorBuffer = instances
        d.instanceDescriptorBufferOffset = 0
        d.instanceDescriptorStride = instanceStride
        d.instanceDescriptorType = .default
        d.usage = usage
        return d
    }

    /// Metal 3's descriptor for a build from either kind of instance descriptors: a still scene's structure is built
    /// once, off the frames, on a Metal 3 queue (SceneBuffers).
    package func descriptor(indirect: Bool) -> MTLInstanceAccelerationStructureDescriptor {
        let d = descriptor
        if indirect {
            d.instancedAccelerationStructures = nil
            d.instanceDescriptorType = .indirect
        }
        return d
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(structure: MTLAccelerationStructure, scratch: MTLBuffer, refit: Bool, instanceCount: Int, usage: MTLAccelerationStructureUsage, instances: MTLBuffer, instanceStride: Int, primitives: [MTLAccelerationStructure], indirect: Bool = false) {
        self.structure = structure
        self.scratch = scratch
        self.refit = refit
        self.instanceCount = instanceCount
        self.usage = usage
        self.instances = instances
        self.instanceStride = instanceStride
        self.primitives = primitives
        self.indirect = indirect
    }
}

/// Per-mesh structures a frame builds or refits, in an acceleration-structure encoder of their own (Metal 4: on the
/// Metal 3 queue, between the frame's command buffers; the plants' variants in the frame's encoder, PlantTracing.Refit).
package protocol PrimitiveWork {
    /// How many encoders it takes: the M1 Max's driver doesn't refit many instance structures in one encoder (three
    /// crash), so the plants' variants take two each (PlantTracing.Refit.perEncoder).
    var encoderCount: Int { get }
    /// Encodes part `part` (0..<encoderCount) of the work.
    func encode(into enc: MTLAccelerationStructureCommandEncoder, part: Int)
}
extension PrimitiveWork {
    package var encoderCount: Int { 1 }
}

/// Per-mesh work Metal 4 encodes in the frame's own encoder (Metal4Frame.updatePrimitives), side by side, rather
/// than through the Metal 3 queue between the frame's command buffers: the plants' refits, the particles' build.
package protocol PrimitiveWork4: PrimitiveWork {
    /// Whether this one can (else it goes through the Metal 3 queue after all).
    var encodes4: Bool { get }
    /// Encodes all of it into `enc`; `keep` makes what it touches resident.
    func encode4(into enc: MTL4ComputeCommandEncoder, keep: (MTLAllocation) -> Void)
}
extension PrimitiveWork4 {
    package var encodes4: Bool { true }
}

/// This frame's refit of the per-mesh structures that deform (the crowd's pose slots): each keeps its tree and takes
/// its boxes from the vertices its descriptor points at, which the skinning has just rewritten. And the build of those
/// whose triangles change (a liquid's surface: FluidSurface.swift), from scratch, into the same structure.
package struct PrimitiveRefit: PrimitiveWork {
    package let structures: [MTLAccelerationStructure]
    package let descriptors: [MTLPrimitiveAccelerationStructureDescriptor]
    package let scratch: MTLBuffer
    package let scratchOffsets: [Int]
    package var rebuilt: [(structure: MTLAccelerationStructure, descriptor: MTLPrimitiveAccelerationStructureDescriptor, scratchOffset: Int)] = []
    /// The mesh each rebuilt structure is of, and each refitted one.
    package var rebuiltMeshes: [Int] = []
    package var refittedMeshes: [Int] = []
    /// This frame's refits to leave out (meshes that didn't move: a parked car's panels).
    package var skipping: Set<Int> = []
    /// The refitted mesh to build again this frame instead (a car's that came apart: PhysicsGPU.nextRebuild; -1 none),
    /// in `rebuildScratch` (as big as the largest of those that may be: Scene.rebuiltOnDemand's).
    package var rebuilding = -1
    package var rebuildScratch: MTLBuffer?
    /// Whether this frame has anything to refit or build.
    package var hasWork: Bool {
        !rebuilt.isEmpty || rebuilding >= 0 || refittedMeshes.count != structures.count || refittedMeshes.contains { !skipping.contains($0) }
    }

    /// How many of rebuilt structure `i`'s triangles the next builds take (the rest are left out: a liquid's surface
    /// holds room for far more than it needs): at most what it was made for.
    package func setTriangles(_ i: Int, _ count: Int) {
        guard let geometry = rebuilt[i].descriptor.geometryDescriptors?.first as? MTLAccelerationStructureTriangleGeometryDescriptor
        else { return }
        geometry.triangleCount = count
    }

    package func encode(into enc: MTLAccelerationStructureCommandEncoder, part: Int) {
        for (i, structure) in structures.enumerated() {
            if i < refittedMeshes.count && refittedMeshes[i] == rebuilding, let rebuildScratch {
                enc.build(accelerationStructure: structure, descriptor: descriptors[i], scratchBuffer: rebuildScratch, scratchBufferOffset: 0)
                continue
            }
            if i < refittedMeshes.count && skipping.contains(refittedMeshes[i]) { continue }
            enc.refit(sourceAccelerationStructure: structure, descriptor: descriptors[i], destinationAccelerationStructure: structure,
                      scratchBuffer: scratch, scratchBufferOffset: scratchOffsets[i])
        }
        for r in rebuilt {
            enc.build(accelerationStructure: r.structure, descriptor: r.descriptor, scratchBuffer: scratch, scratchBufferOffset: r.scratchOffset)
        }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(structures: [MTLAccelerationStructure], descriptors: [MTLPrimitiveAccelerationStructureDescriptor], scratch: MTLBuffer, scratchOffsets: [Int], rebuilt: [(structure: MTLAccelerationStructure, descriptor: MTLPrimitiveAccelerationStructureDescriptor, scratchOffset: Int)] = [], rebuiltMeshes: [Int] = [], refittedMeshes: [Int] = []) {
        self.structures = structures
        self.descriptors = descriptors
        self.scratch = scratch
        self.scratchOffsets = scratchOffsets
        self.rebuilt = rebuilt
        self.rebuiltMeshes = rebuiltMeshes
        self.refittedMeshes = refittedMeshes
    }
}

/// Metal 4: in the frame's own encoder when it only rebuilds (a liquid's surfaces), rather than through the Metal 3
/// queue between the frame's command buffers (an interlude, which leaves the GPU idle around it). Not refits: on
/// macOS 27.0.1 a Metal 4 refit of a structure Metal 3 built lost its triangles (the water's near patch missing from
/// every frame), and of one Metal 4 had built came out stale after a change of scene, while a Metal 4 build matched
/// Metal 3's frames bit for bit. And building the near patch every frame instead of refitting it cost Metal 4 frames
/// 0.3-0.5 ms more than its interlude does. So refits (the near patch, the crowd's poses) stay on the Metal 3 queue.
extension PrimitiveRefit: PrimitiveWork4 {
    /// Triangles and curves only, and nothing to refit.
    package var encodes4: Bool {
        guard structures.isEmpty else { return false }
        return (descriptors + rebuilt.map(\.descriptor)).allSatisfy { d in
            d.motionKeyframeCount <= 1 && (d.geometryDescriptors ?? []).allSatisfy {
                ($0 is MTLAccelerationStructureTriangleGeometryDescriptor || $0 is MTLAccelerationStructureCurveGeometryDescriptor)
                    && $0.primitiveDataBuffer == nil
            }
        }
    }

    package func encode4(into enc: MTL4ComputeCommandEncoder, keep: (MTLAllocation) -> Void) {
        keep(scratch)
        func range(_ buffer: MTLBuffer, _ offset: Int) -> MTL4BufferRange {
            keep(buffer)
            return MTL4BufferRange(bufferAddress: buffer.gpuAddress + UInt64(offset), length: UInt64(buffer.length - offset))
        }
        func metal4(_ d: MTLPrimitiveAccelerationStructureDescriptor) -> MTL4PrimitiveAccelerationStructureDescriptor {
            let out = MTL4PrimitiveAccelerationStructureDescriptor()
            out.usage = d.usage
            out.geometryDescriptors = (d.geometryDescriptors ?? []).map { g -> MTL4AccelerationStructureGeometryDescriptor in
                if let t = g as? MTLAccelerationStructureTriangleGeometryDescriptor {
                    let n = MTL4AccelerationStructureTriangleGeometryDescriptor()
                    if let v = t.vertexBuffer { n.vertexBuffer = range(v, t.vertexBufferOffset) }
                    n.vertexStride = t.vertexStride
                    n.vertexFormat = t.vertexFormat
                    if let i = t.indexBuffer { n.indexBuffer = range(i, t.indexBufferOffset) }
                    n.indexType = t.indexType
                    n.triangleCount = t.triangleCount
                    n.opaque = t.opaque
                    n.allowDuplicateIntersectionFunctionInvocation = t.allowDuplicateIntersectionFunctionInvocation
                    n.intersectionFunctionTableOffset = t.intersectionFunctionTableOffset
                    return n
                }
                let c = g as! MTLAccelerationStructureCurveGeometryDescriptor
                let n = MTL4AccelerationStructureCurveGeometryDescriptor()
                if let p = c.controlPointBuffer { n.controlPointBuffer = range(p, c.controlPointBufferOffset) }
                n.controlPointCount = c.controlPointCount
                n.controlPointStride = c.controlPointStride
                n.controlPointFormat = c.controlPointFormat
                if let r = c.radiusBuffer { n.radiusBuffer = range(r, c.radiusBufferOffset) }
                n.radiusStride = c.radiusStride
                n.radiusFormat = c.radiusFormat
                if let i = c.indexBuffer { n.indexBuffer = range(i, c.indexBufferOffset) }
                n.indexType = c.indexType
                n.segmentCount = c.segmentCount
                n.segmentControlPointCount = c.segmentControlPointCount
                n.curveType = c.curveType
                n.curveBasis = c.curveBasis
                n.curveEndCaps = c.curveEndCaps
                n.opaque = c.opaque
                n.allowDuplicateIntersectionFunctionInvocation = c.allowDuplicateIntersectionFunctionInvocation
                n.intersectionFunctionTableOffset = c.intersectionFunctionTableOffset
                return n
            }
            return out
        }
        // Each structure's scratch runs to the next one's offset (they share the buffer).
        let offsets = rebuilt.map(\.scratchOffset).sorted()
        func scratchRange(_ offset: Int) -> MTL4BufferRange {
            let end = offsets.first { $0 > offset } ?? scratch.length
            return MTL4BufferRange(bufferAddress: scratch.gpuAddress + UInt64(offset), length: UInt64(end - offset))
        }
        for r in rebuilt {
            keep(r.structure)
            enc.build(destinationAccelerationStructure: r.structure, descriptor: metal4(r.descriptor), scratchBuffer: scratchRange(r.scratchOffset))
        }
    }
}
