import Metal
import simd

/// A mesh in a buffer of its own: a borrowed mesh (`Scene.BorrowedMesh`: an open world's tile, a plant of the
/// library), which is the same triangles in every scene that has a mesh of its name. The scenes share the block: a
/// scene made around the next tile takes the blocks of the one being drawn (`SceneBuffers.Options.blocks`) and fills
/// only the ones that are new, and a block goes when the last scene that has it does. A hit reaches its vertices
/// through its address in the mesh table (`GPUMesh.block`, STREAMED in the shaders), the custom tracer its tree
/// through its address in its instances' records.
final class MeshBlock {
    let name: String
    /// `vertexCount` positions, as many normals, as many UVs, `indexCount` indices into them, and a material offset
    /// (a byte) per triangle: one after the other (fetchHitVertices in Shaders/Surface.metal reads them so).
    let geometry: MTLBuffer
    let vertexCount: Int, indexCount: Int
    var indexOffset: Int { MeshBlock.indexOffset(vertices: vertexCount) }
    static func indexOffset(vertices: Int) -> Int { vertices * (2 * MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride) }

    /// The custom tracer's tree over it, in a buffer of its own: `nodeCount` nodes, the root first (none: the mesh has
    /// no triangle), then three vectors per triangle in leaf order (BVHBuilder.BLASResult.triangles), which the
    /// leaves count from the buffer's start. `cutout`: the mesh's, as the scene the tree was built for had it (it is
    /// in the triangles).
    struct Tree {
        let buffer: MTLBuffer
        let nodeCount: Int
        let triangles: Int
        let bounds: AABB
        let depth: Int
        let cutout: UInt32
    }
    private var built: Tree?
    private let lock = NSLock()
    /// A mesh of fewer triangles isn't cached: its tree is built sooner than a file is read.
    private static let cachedTriangles = 4_000
    private enum Section {
        static let nodes = SectionFile.id("node"), triangles = SectionFile.id("tris"), shape = SectionFile.id("shap"), bounds = SectionFile.id("bnds")
    }

    init(device: MTLDevice, name: String, mesh: Scene.BorrowedMesh) throws {
        self.name = name
        (vertexCount, indexCount) = (mesh.positions.count, mesh.indices.count)
        let indexOffset = MeshBlock.indexOffset(vertices: vertexCount)
        let length = indexOffset + indexCount * MemoryLayout<UInt32>.stride + indexCount / 3
        guard let buffer = device.makeBuffer(length: max((length + 15) & ~15, 16), options: .storageModeShared) else {
            throw RendererError.resourceCreation("buffer \(name)")
        }
        buffer.label = name
        geometry = buffer
        var at = buffer.contents()
        func copy<T>(_ from: Stored<T>) {
            from.withUnsafeBufferPointer { if let base = $0.baseAddress { at.copyMemory(from: base, byteCount: $0.count * MemoryLayout<T>.stride) } }
            at += from.count * MemoryLayout<T>.stride
        }
        copy(mesh.positions)
        copy(mesh.normals)
        copy(mesh.uvs)
        copy(mesh.indices)
        if let materials = mesh.materials { copy(materials) }   // (a new buffer is zeros: one material)
    }

    var hasTree: Bool {
        lock.lock()
        defer { lock.unlock() }
        return built != nil
    }

    /// The tree, built the first time it is asked for (any thread).
    func tree(device: MTLDevice, cutout: UInt32) throws -> Tree {
        lock.lock()
        defer { lock.unlock() }
        if let built, built.cutout == cutout { return built }
        let base = geometry.contents()
        let positions = base.bindMemory(to: SIMD3<Float>.self, capacity: 2 * vertexCount)
        let uvs = (base + 2 * vertexCount * MemoryLayout<SIMD3<Float>>.stride).bindMemory(to: SIMD2<Float>.self, capacity: vertexCount)
        let indices = UnsafeBufferPointer(start: (base + indexOffset).bindMemory(to: UInt32.self, capacity: indexCount), count: indexCount)
        func storage(_ nodes: Int) -> MTLBuffer? {
            let made = device.makeBuffer(length: max(nodes * MemoryLayout<BVHNode>.stride + indexCount * MemoryLayout<SIMD4<Float>>.stride, 16),
                                         options: .storageModeShared)
            made?.label = "tree of " + name
            return made
        }
        // From the cache, where trees are cached (an unoptimised build, which takes a minute over an open world's):
        // a file named by the mesh's bytes.
        var cache: String?
        if GeneratedCache.cachesTrees, indexCount / 3 >= MeshBlock.cachedTriangles {
            var hasher = GeneratedCache.Hasher()
            hasher.add(UnsafeBufferPointer(start: positions, count: vertexCount))
            hasher.add(indices)
            if cutout != 0 {   // only cards' UVs are in the tree
                hasher.add(UnsafeBufferPointer(start: uvs, count: vertexCount))
                hasher.add("cutout \(cutout)")
            }
            cache = "tree-\(hasher.name()).sect"
        }
        let key = "tree v\(BVHBuilder.version)"
        if let cache, let file = GeneratedCache.load(cache, key: key), let shape: [Int] = file.array(Section.shape), shape.count == 2,
           let bounds: [AABB] = file.array(Section.bounds), bounds.count == 1, let buffer = storage(shape[0]) {
            let nodeBytes = shape[0] * MemoryLayout<BVHNode>.stride, triangleBytes = indexCount * MemoryLayout<SIMD4<Float>>.stride
            let read = file.withBytes(Section.nodes) { raw -> Bool in
                guard raw.count == nodeBytes, let from = raw.baseAddress else { return raw.count == nodeBytes }
                buffer.contents().copyMemory(from: from, byteCount: nodeBytes)
                return true
            } == true && file.withBytes(Section.triangles) { raw -> Bool in
                guard raw.count == triangleBytes, let from = raw.baseAddress else { return raw.count == triangleBytes }
                (buffer.contents() + nodeBytes).copyMemory(from: from, byteCount: triangleBytes)
                return true
            } == true
            if read {
                let tree = Tree(buffer: buffer, nodeCount: shape[0], triangles: indexCount / 3, bounds: bounds[0], depth: shape[1], cutout: cutout)
                built = tree
                return tree
            }
        }
        var buffer: MTLBuffer?
        let shape = BVHBuilder.buildBLAS(positions: positions, uvs: uvs, indices: indices, cutout: cutout) { nodes in
            buffer = storage(nodes)
            return buffer?.contents()
        }
        guard let shape, let buffer else { throw RendererError.resourceCreation("the tree of \(name)") }
        let tree = Tree(buffer: buffer, nodeCount: shape.nodes, triangles: indexCount / 3, bounds: shape.bounds, depth: shape.depth, cutout: cutout)
        if let cache {
            var writer = SectionFile.Writer()
            let nodes = buffer.contents().bindMemory(to: BVHNode.self, capacity: shape.nodes)
            let triangles = (buffer.contents() + shape.nodes * MemoryLayout<BVHNode>.stride).bindMemory(to: SIMD4<Float>.self, capacity: indexCount)
            writer.add(Section.nodes, Array(UnsafeBufferPointer(start: nodes, count: shape.nodes)))
            writer.add(Section.triangles, Array(UnsafeBufferPointer(start: triangles, count: indexCount)))
            writer.add(Section.shape, [shape.nodes, shape.depth])
            writer.add(Section.bounds, [shape.bounds])
            GeneratedCache.store(cache, key: key, writer)
        }
        built = tree
        return tree
    }
}

/// A scene on the GPU: its geometry's buffers, its instances' records, and for Metal's ray tracer its acceleration
/// structures. Made on any thread: where the scene is prepared (the background, when the app changes scenes), so
/// that installing a scene between two frames only swaps these in.
///
/// A still scene (nothing in it moves or deforms: `Scene.isStill`) has one set of instance records and one
/// top-level structure for every frame slot, written and built here, once. Any other has a set per slot, which the
/// frames write and build (the CPU writes a slot's while the GPU may still read the others').
///
/// A mesh with a name (`Scene.meshNames`: an open world's tile, a generated plant) is the same triangles in every
/// scene that has it, so its structure outlives the scene: the next scene's `Options.known` hands it over, and only
/// the meshes that are new are built. A borrowed mesh's vertices outlive the scene the same way (`MeshBlock`).
struct SceneBuffers {
    struct Options {
        var rayTracer: RayTracerKind
        var api: RenderAPI
        var slots: Int
        /// Metal's per-mesh structures: built for fast intersection (macOS 26), compacted.
        var fastIntersection = true
        var compact = true
        /// How the top-level structure is built when the frames refit it (a still scene's is built once, for tracing).
        var instanceUsage: MTLAccelerationStructureUsage = [.preferFastBuild, .refit]
        /// The per-mesh structures of the scene being drawn, by their meshes' names.
        var known: [String: MTLAccelerationStructure] = [:]
        /// Its borrowed meshes' blocks, by their names.
        var blocks: [String: MeshBlock] = [:]
    }

    /// The scene's arrays (what its borrowed meshes have is in `blocks`), and its mesh table.
    let positions, normals, indices, meshes, uvs, emissive, triangleMaterials: MTLBuffer
    /// Per mesh: the block of a borrowed mesh, nil for a mesh of the arrays. Empty if no mesh is borrowed.
    let blocks: [MeshBlock?]
    private(set) var namedBlocks: [String: MeshBlock] = [:]
    let materials: [MTLBuffer]                              // per slot: light proxies' and leaves' materials change
    let instanceData: [MTLBuffer]                           // per slot (GPUInstanceData)
    let still: Bool                                         // the instances are written, and their structure built

    // Metal's ray tracer only.
    let instanceDescriptors: [MTLBuffer]                    // per slot
    private(set) var primitives: [MTLAccelerationStructure] = []        // per mesh
    private(set) var namedPrimitives: [String: MTLAccelerationStructure] = [:]
    private(set) var primitiveRefit: PrimitiveRefit?        // the meshes that deform (the crowd's pose slots)
    private(set) var instanceStructures: [MTLAccelerationStructure] = []   // per slot
    private(set) var instanceScratch: [MTLBuffer] = []      // per slot; none for a still scene

    static func descriptorStride(_ api: RenderAPI) -> Int { api == .metal4 ? 72 : 64 }
    private static let buildBatchBytes = 256 << 20

    /// The borrowed meshes' buffers: a hit reads them through the addresses in the mesh table.
    var blockBuffers: [MTLBuffer] { blocks.compactMap { $0?.geometry } }

    /// Every buffer of the scene a frame reads.
    var buffers: [MTLBuffer] {
        [positions, normals, indices, meshes, uvs, emissive, triangleMaterials] + materials + (still ? [instanceData[0]] : instanceData)
            + blockBuffers
    }

    /// What the scene takes on the GPU, in megabytes: its geometry, its instances' records, and Metal's structures
    /// (per mesh, and over the instances).
    var megabytes: (geometry: Double, instances: Double, primitives: Double, instanceStructures: Double) {
        func mb(_ n: Int) -> Double { Double(n) / 1_048_576 }
        func distinct<T: AnyObject>(_ list: [T]) -> [T] {
            var seen = Set<ObjectIdentifier>()
            return list.filter { seen.insert(ObjectIdentifier($0)).inserted }
        }
        return (mb(([positions, normals, indices, meshes, uvs, emissive, triangleMaterials] + materials + distinct(blockBuffers))
                       .reduce(0) { $0 + $1.length }),
                mb(distinct(instanceData + instanceDescriptors).reduce(0) { $0 + $1.length }),
                mb(primitives.reduce(0) { $0 + $1.size }),
                mb(distinct(instanceStructures).reduce(0) { $0 + $1.size } + instanceScratch.reduce(0) { $0 + $1.length }))
    }

    /// Has the GPU use `buffers` now (a few bytes of each are copied), and waits for it. The first command buffer to
    /// name a buffer pays for bringing it into the GPU's memory map (5 to 12 ms for an open world's): a frame, unless
    /// this has been done where the buffers were made.
    static func touch(_ buffers: [MTLBuffer], device: MTLDevice, queue: MTLCommandQueue) {
        guard !buffers.isEmpty, let sink = device.makeBuffer(length: 16 * buffers.count, options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        for (i, buffer) in buffers.enumerated() {
            blit.copy(from: buffer, sourceOffset: 0, to: sink, destinationOffset: 16 * i, size: min(16, buffer.length))
        }
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// `queue`: for the builds, which this waits for. Not the frames' queue when they are being drawn meanwhile: its
    /// command buffers run in order, and a frame would wait behind a build.
    init(device: MTLDevice, queue: MTLCommandQueue, scene: Scene, options: Options) throws {
        func buffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
            let length = max(MemoryLayout<T>.stride * array.count, 16)
            let made: MTLBuffer? = array.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count > 0 else { return device.makeBuffer(length: length, options: .storageModeShared) }
                return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
            }
            guard let made else { throw RendererError.resourceCreation("buffer \(label)") }
            made.label = label
            return made
        }
        func empty(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let made = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            made.label = label
            return made
        }
        positions = try buffer(scene.positions, "positions")
        normals = try buffer(scene.normals, "normals")
        indices = try buffer(scene.indices, "indices")
        uvs = try buffer(scene.uvs, "uvs")
        // (Zeros for the arrays' triangles where only borrowed meshes have several materials: a hit reads one for each.)
        triangleMaterials = scene.triangleMaterials.isEmpty && scene.hasMaterialOffsets
            ? try empty(scene.indices.count / 3, "triangleMaterials") : try buffer(scene.triangleMaterials, "triangleMaterials")
        // The borrowed meshes: each in the block the scene being drawn has it in, or copied from where it is (a tile's
        // file) into a new one. The mesh table says where.
        guard !scene.hasBorrowedMeshes || !scene.borrowed.isEmpty else {
            throw RendererError.resourceCreation("the buffers of a scene that has let go of its borrowed meshes")
        }
        var table = scene.meshes
        var blocks = [MeshBlock?](repeating: nil, count: scene.borrowed.isEmpty ? 0 : scene.meshes.count)
        var new: [Scene.BorrowedMesh] = []
        for mesh in scene.borrowed {
            if let name = scene.meshNames[mesh.mesh], let known = options.blocks[name], known.vertexCount == mesh.positions.count,
               known.indexCount == mesh.indices.count {
                blocks[mesh.mesh] = known
            } else {
                new.append(mesh)
            }
        }
        var made = [MeshBlock?](repeating: nil, count: new.count)
        made.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: new.count) { k in
                out[k] = try? MeshBlock(device: device, name: scene.meshNames[new[k].mesh] ?? "mesh \(new[k].mesh)", mesh: new[k])
            }
        }
        for (k, mesh) in new.enumerated() {
            guard let block = made[k] else { throw RendererError.resourceCreation("buffer of mesh \(mesh.mesh)") }
            blocks[mesh.mesh] = block
        }
        for (m, block) in blocks.enumerated() {
            guard let block else { continue }
            table[m].block = block.geometry.gpuAddress
            namedBlocks[block.name] = block
        }
        self.blocks = blocks
        meshes = try buffer(table, "meshes")
        materials = try (0..<options.slots).map { try buffer(scene.materials, "materials\($0)") }
        emissive = try buffer(scene.emissiveTriangles, "emissiveTriangles")

        still = scene.isStill
        let count = scene.instances.count, sets = still ? 1 : options.slots
        var data = try (0..<sets).map { try empty(count * MemoryLayout<GPUInstanceData>.stride, "instanceData\($0)") }
        if still {
            let records = data[0].contents().bindMemory(to: GPUInstanceData.self, capacity: count)
            SceneBuffers.inParts(count) { scene.writeInstanceData(into: records, all: true, range: $0) }
            data = [MTLBuffer](repeating: data[0], count: options.slots)
        }
        instanceData = data
        guard options.rayTracer == .metal else {
            instanceDescriptors = []
            return
        }

        precondition(MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride == 64)
        if #available(macOS 14.0, *) { precondition(MemoryLayout<MTLIndirectAccelerationStructureInstanceDescriptor>.stride == 72) }
        let stride = SceneBuffers.descriptorStride(options.api)
        var descriptors = try (0..<sets).map { try empty(count * stride, "instanceDescriptors\($0)") }
        if still { descriptors = [MTLBuffer](repeating: descriptors[0], count: options.slots) }
        instanceDescriptors = descriptors
        try buildPrimitives(device: device, queue: queue, scene: scene, options: options)
        guard let placeholder = primitives.first else { return }

        // The instances' structures, sized from the descriptor a build uses (the structure and its scratch buffer
        // don't exist yet: the descriptor is made with placeholders for them).
        var usage = options.instanceUsage
        if still { usage.remove([.refit, .preferFastBuild]) }
        func update(_ structure: MTLAccelerationStructure, _ scratch: MTLBuffer, slot: Int) -> TLASUpdate {
            TLASUpdate(structure: structure, scratch: scratch, refit: false, instanceCount: count, usage: usage,
                       instances: descriptors[slot], instanceStride: stride, primitives: primitives)
        }
        let layout = update(placeholder, descriptors[0], slot: 0)
        let sizes: MTLAccelerationStructureSizes
        if still {
            sizes = device.accelerationStructureSizes(descriptor: layout.descriptor(indirect: options.api == .metal4))
        } else if options.api == .metal4, #available(macOS 26.0, *) {
            sizes = device.accelerationStructureSizes(descriptor: layout.descriptor4)
        } else {
            sizes = device.accelerationStructureSizes(descriptor: layout.descriptor)
        }
        for _ in 0..<sets {
            guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, sizes.refitScratchBufferSize, 16),
                                                  options: .storageModePrivate) else {
                throw RendererError.resourceCreation("instance acceleration structure")
            }
            instanceStructures.append(accel)
            instanceScratch.append(scratch)
        }
        guard still else { return }
        // A still scene's: built here, on a Metal 3 queue whatever the frames are encoded with (Metal 4's instance
        // descriptors name their meshes' structures by resource ID, which Metal 3 builds from too).
        let whole = self   // (a copy for the closure: `self` is being initialised)
        SceneBuffers.inParts(count) { whole.writeInstanceDescriptors(slot: 0, scene: scene, api: options.api, all: true, range: $0) }
        guard let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RendererError.resourceCreation("acceleration structure command encoder")
        }
        let build = update(instanceStructures[0], instanceScratch[0], slot: 0)
        encoder.build(accelerationStructure: build.structure, descriptor: build.descriptor(indirect: options.api == .metal4),
                      scratchBuffer: build.scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        instanceStructures = [MTLAccelerationStructure](repeating: instanceStructures[0], count: options.slots)
        instanceScratch = []
    }

    /// `body` for the parts of `0..<count`, side by side: a still scene's hundreds of thousands of records, each
    /// written once (an unoptimised build takes a second over them in one loop).
    private static func inParts(_ count: Int, _ body: (Range<Int>) -> Void) {
        let part = 16384
        DispatchQueue.concurrentPerform(iterations: (count + part - 1) / part) { body(($0 * part)..<min(($0 + 1) * part, count)) }
    }

    /// Instance descriptors for Metal's top-level structure, into `slot`'s buffer: every instance's (`all`; of
    /// `range`, for a caller that writes them in parts), or the moving ones'.
    func writeInstanceDescriptors(slot: Int, scene: Scene, api: RenderAPI, all: Bool, range: Range<Int>? = nil) {
        let base = instanceDescriptors[slot].contents()
        let options = MTLAccelerationStructureInstanceOptions([.opaque, .disableTriangleCulling]).rawValue
        let indirect = api == .metal4, stride = SceneBuffers.descriptorStride(api)
        func write(_ i: Int) {
            let instance = scene.instances[i]
            let p = base.advanced(by: i * stride)
            let m = instance.transform
            var offset = 0
            for column in 0..<4 {           // packed column-major 4x3 matrix
                for row in 0..<3 {
                    p.storeBytes(of: m[column][row], toByteOffset: offset, as: Float.self)
                    offset += 4
                }
            }
            p.storeBytes(of: options, toByteOffset: 48, as: UInt32.self)
            p.storeBytes(of: instance.mask, toByteOffset: 52, as: UInt32.self)
            p.storeBytes(of: UInt32(0), toByteOffset: 56, as: UInt32.self)              // intersection function table offset
            if indirect {
                p.storeBytes(of: UInt32(i), toByteOffset: 60, as: UInt32.self)          // user ID (unused)
                p.storeBytes(of: primitives[instance.mesh].gpuResourceID, toByteOffset: 64, as: MTLResourceID.self)
            } else {
                p.storeBytes(of: UInt32(instance.mesh), toByteOffset: 60, as: UInt32.self)  // index into `primitives`
            }
        }
        if all {
            for i in range ?? scene.instances.indices { write(i) }
        } else {
            for i in scene.movingInstances { write(i) }
        }
    }

    /// One bottom-level (primitive) acceleration structure per mesh, built once: the named ones the last scene had
    /// are taken from it. The meshes that deform (the crowd's pose slots) are built to be refitted: `primitiveRefit`
    /// holds what the frames refit. Of the poses of one character only the first is built: the others take its tree,
    /// refitted around their own vertices.
    private mutating func buildPrimitives(device: MTLDevice, queue: MTLCommandQueue, scene: Scene, options: Options) throws {
        var structures = [MTLAccelerationStructure?](repeating: nil, count: scene.meshes.count)
        var new: [Int] = []
        for i in scene.meshes.indices {
            if let name = scene.meshNames[i], let known = options.known[name] { structures[i] = known } else { new.append(i) }
        }
        // The crowd's pose slots deform: their structures are built to be refitted every frame, and stay as built.
        var refitted: [(index: Int, descriptor: MTLPrimitiveAccelerationStructureDescriptor, scratch: Int)] = []
        var jobs: [(index: Int, descriptor: MTLPrimitiveAccelerationStructureDescriptor, sizes: MTLAccelerationStructureSizes, deforms: Bool)] = []
        // The poses that take another's tree: (its place in `refitted`, the mesh whose tree it takes).
        var copies: [(refit: Int, of: Int)] = []
        var firstPose: [SIMD2<UInt32>: Int] = [:]   // by the triangles a pose has: its character's
        for i in new {
            let mesh = scene.meshes[i]
            let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
            if let block = blocks.isEmpty ? nil : blocks[i] {
                geometry.vertexBuffer = block.geometry
                geometry.indexBuffer = block.geometry
                geometry.indexBufferOffset = block.indexOffset
            } else {
                geometry.vertexBuffer = positions
                geometry.vertexBufferOffset = Int(mesh.vertexOffset) * MemoryLayout<SIMD3<Float>>.stride
                geometry.indexBuffer = indices
                geometry.indexBufferOffset = Int(mesh.firstIndex) * MemoryLayout<UInt32>.stride
            }
            geometry.vertexStride = MemoryLayout<SIMD3<Float>>.stride
            geometry.indexType = .uint32
            geometry.triangleCount = Int(mesh.indexCount) / 3
            geometry.opaque = true

            let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
            descriptor.geometryDescriptors = [geometry]
            // The meshes never change, so their structures are built once, for the fastest traversal Metal offers.
            let deforms = mesh.prevOffset != 0
            if deforms { descriptor.usage = .refit }
            else if options.fastIntersection, #available(macOS 26.0, *) { descriptor.usage = .preferFastIntersection }
            let sizes = device.accelerationStructureSizes(descriptor: descriptor)
            if deforms { refitted.append((i, descriptor, max(sizes.refitScratchBufferSize, 16))) }
            if deforms, let first = firstPose[SIMD2(mesh.firstIndex, mesh.indexCount)] {
                copies.append((refitted.count - 1, first))
                continue
            }
            if deforms { firstPose[SIMD2(mesh.firstIndex, mesh.indexCount)] = i }
            jobs.append((i, descriptor, sizes, deforms))
        }

        // Built and compacted a batch at a time: a build reserves the worst case, about twice what the structure keeps
        // once compacted (less memory to walk, so fewer cache misses per ray), and a batch's builds are let go of before
        // the next batch is built (the open world's first scene would hold 760 MB of them otherwise).
        var before = 0, after = 0
        func build(_ batch: Range<Int>) throws {
            guard !batch.isEmpty, let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeAccelerationStructureCommandEncoder(),
                  let compactedSizes = device.makeBuffer(length: batch.count * MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
                if batch.isEmpty { return }
                throw RendererError.resourceCreation("acceleration structure command encoder")
            }
            var built: [MTLAccelerationStructure] = [], scratchBuffers: [MTLBuffer] = []
            for (k, j) in batch.enumerated() {
                let job = jobs[j]
                guard let accel = device.makeAccelerationStructure(size: job.sizes.accelerationStructureSize),
                      let scratch = device.makeBuffer(length: max(job.sizes.buildScratchBufferSize, 16), options: .storageModePrivate) else {
                    throw RendererError.resourceCreation("primitive acceleration structure")
                }
                encoder.build(accelerationStructure: accel, descriptor: job.descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
                if options.compact && !job.deforms {
                    // Its size once compacted (a UInt32), written by the GPU after the build.
                    encoder.writeCompactedSize(accelerationStructure: accel, buffer: compactedSizes,
                                               offset: k * MemoryLayout<UInt32>.stride, sizeDataType: .uint)
                }
                structures[job.index] = accel
                built.append(accel)
                scratchBuffers.append(scratch)
            }
            encoder.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            guard options.compact, let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeAccelerationStructureCommandEncoder() else { return }
            let sizes = compactedSizes.contents().bindMemory(to: UInt32.self, capacity: batch.count)
            for (k, j) in batch.enumerated() where !jobs[j].deforms {
                guard let small = device.makeAccelerationStructure(size: Int(sizes[k])) else {
                    throw RendererError.resourceCreation("compacted acceleration structure")
                }
                encoder.copyAndCompact(sourceAccelerationStructure: built[k], destinationAccelerationStructure: small)
                structures[jobs[j].index] = small
                before += built[k].size
                after += small.size
            }
            encoder.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        var first = 0, bytes = 0
        for j in jobs.indices {
            bytes += jobs[j].sizes.accelerationStructureSize
            if bytes >= SceneBuffers.buildBatchBytes {
                try autoreleasepool { try build(first..<(j + 1)) }
                (first, bytes) = (j + 1, 0)
            }
        }
        try autoreleasepool { try build(first..<jobs.count) }
        if options.compact, !jobs.isEmpty {
            print(String(format: "Metal BLAS: %d meshes (%d the last scene's), %.1f MB compacted to %.1f MB", structures.count,
                         structures.count - new.count, Double(before) / 1_048_576, Double(after) / 1_048_576))
        }
        if !refitted.isEmpty {
            // One scratch buffer, a range per structure: the refits of a frame may run side by side.
            var offsets: [Int] = [], length = 0
            for r in refitted { offsets.append(length); length += (r.scratch + 255) & ~255 }
            guard let scratch = device.makeBuffer(length: length, options: .storageModePrivate) else {
                throw RendererError.resourceCreation("refit scratch buffer")
            }
            scratch.label = "blasRefitScratch"
            // A character's other poses: its first pose's tree, refitted into a structure of their own. A pose keeps
            // its triangles, so the tree fits every one of them as it fits the first through its loop; a refit costs
            // a fraction of a build; and every pose then has the triangles in the same order. That last part matters
            // to the picture: a shadow ray stops at the first occluder its tree has (isVisibleBlocker in
            // Shaders/Lights.metal) and the shadow filter takes that one's distance, while Metal builds these meshes
            // a little differently from run to run (more so the more of them it builds, or with the GPU busy): with
            // a tree built per pose, the same crowd came out as one of several pictures.
            if !copies.isEmpty {
                guard let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeAccelerationStructureCommandEncoder() else {
                    throw RendererError.resourceCreation("acceleration structure command encoder")
                }
                for copy in copies {
                    let pose = refitted[copy.refit]
                    guard let first = structures[copy.of], let accel = device.makeAccelerationStructure(size: first.size) else {
                        throw RendererError.resourceCreation("primitive acceleration structure")
                    }
                    encoder.refit(sourceAccelerationStructure: first, descriptor: pose.descriptor, destinationAccelerationStructure: accel,
                                  scratchBuffer: scratch, scratchBufferOffset: offsets[copy.refit])
                    structures[pose.index] = accel
                }
                encoder.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
            }
            primitiveRefit = PrimitiveRefit(structures: refitted.map { structures[$0.index]! }, descriptors: refitted.map(\.descriptor),
                                            scratch: scratch, scratchOffsets: offsets)
        }
        primitives = structures.map { $0! }
        for (i, name) in scene.meshNames { namedPrimitives[name] = primitives[i] }
    }
}
