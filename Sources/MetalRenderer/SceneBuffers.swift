import Metal
import simd

/// A mesh in a buffer of its own: a borrowed mesh (`Scene.BorrowedMesh`: an open world's tile, a plant of the
/// library), which is the same triangles in every scene that has a mesh of its name. The scenes share the block: a
/// scene made around the next tile takes the blocks of the one being drawn (`SceneBuffers.Options.blocks`) and fills
/// only the ones that are new, and a block goes when the last scene that has it does. A hit reaches its vertices
/// through its address in the mesh table (`GPUMesh.block`, STREAMED in the shaders).
final class MeshBlock {
    let name: String
    /// `vertexCount` positions, as many normals, as many UVs, `indexCount` indices into them, and a material offset
    /// (a byte) per triangle: one after the other (fetchHitVertices in Shaders/Surface.metal reads them so).
    let geometry: MTLBuffer
    let vertexCount: Int, indexCount: Int
    var indexOffset: Int { MeshBlock.indexOffset(vertices: vertexCount) }
    static func indexOffset(vertices: Int) -> Int { vertices * (2 * MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride) }

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
}

/// The instances of a group (`Scene.InstanceGroup`: the plants of an open world's tile) as the renderer keeps them,
/// which are the same instances in every scene that has a group of its name. The scenes share the block as they share
/// a mesh's (`MeshBlock`): the next scene takes the blocks of the one being drawn (`SceneBuffers.Options.instanceBlocks`)
/// and makes only the new ones, and a block goes when the last scene that has it does.
///
/// A scene's top-level structure is built from every instance's descriptor, and a block has its instances' ready
/// (`descriptors`). (A structure per block under the scene's traces at half the speed.) The block's records are in a
/// buffer of the block's own; an instance is named by the block's number and its place in the block (`id`), in every
/// scene, and a hit finds its record through the scene's table of the blocks' addresses (TILED in the shaders).
final class InstanceBlock {
    let name: String
    /// Its number among the blocks alive (1...): the high bits of its instances' ids. 0 is a scene's own instances.
    let number: Int
    let count: Int
    static let shift = 20, capacity = 1 << (32 - shift)
    static let assembly: UInt32 = 0x8000_0000
    func id(_ instance: Int) -> UInt32 { UInt32(number << InstanceBlock.shift | instance) }

    /// The records, a GPUInstanceData per instance, in a buffer of the block's own. An assembly's has `assembly` and
    /// its number where a mesh's has its mesh: the meshes' count, which the assemblies are numbered after, differs from
    /// scene to scene.
    let buffer: MTLBuffer
    private static var free: [Int] = [], next = 1
    private static let numbers = NSLock()
    private let lock = NSLock()

    init(device: MTLDevice, name: String, instances: [Scene.Instance]) throws {
        guard !instances.isEmpty, instances.count <= 1 << InstanceBlock.shift, instances.allSatisfy(\.isStatic),
              let buffer = device.makeBuffer(length: max(instances.count * MemoryLayout<GPUInstanceData>.stride, 16), options: .storageModeShared) else {
            throw RendererError.resourceCreation("the instances of \(name)")
        }
        InstanceBlock.numbers.lock()
        let taken = InstanceBlock.free.popLast() ?? InstanceBlock.next
        if taken == InstanceBlock.next { InstanceBlock.next += 1 }
        InstanceBlock.numbers.unlock()
        (self.name, number, count, self.buffer) = (name, taken, instances.count, buffer)
        guard taken < InstanceBlock.capacity else { throw RendererError.resourceCreation("more than \(InstanceBlock.capacity) groups of instances") }
        buffer.label = name
        let out = buffer.contents().bindMemory(to: GPUInstanceData.self, capacity: instances.count)
        for (i, inst) in instances.enumerated() {
            out[i] = GPUInstanceData(transform: inst.transform, prevTransform: inst.prevTransform, normalMatrix: inst.normalMatrix,
                                     meshIndex: inst.mesh >= 0 ? UInt32(inst.mesh) : InstanceBlock.assembly | UInt32(inst.assembly),
                                     materialIndex: UInt32(inst.material), pad0: inst.mask)
        }
    }

    deinit {
        InstanceBlock.numbers.lock()
        if number < InstanceBlock.capacity { InstanceBlock.free.append(number) }
        InstanceBlock.numbers.unlock()
    }

    private var held: UnsafePointer<GPUInstanceData> {
        UnsafePointer(buffer.contents().bindMemory(to: GPUInstanceData.self, capacity: count))
    }

    /// `body` over its records (any thread).
    func withRecords<T>(_ body: (UnsafeBufferPointer<GPUInstanceData>) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(UnsafeBufferPointer(start: held, count: count))
    }

    private var triangleCount: Int?
    /// The triangles of its instances in all (the Debug window's count), counted the first time it is asked for.
    /// `of`: a record's mesh's or assembly's.
    func triangles(_ of: (_ mesh: Int?, _ assembly: Int?) -> Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let triangleCount { return triangleCount }
        let records = held
        let sum = (0..<count).reduce(0) { sum, i in
            let mesh = records[i].meshIndex
            return sum + (mesh & InstanceBlock.assembly != 0 ? of(nil, Int(mesh & ~InstanceBlock.assembly)) : of(Int(mesh), nil))
        }
        triangleCount = sum
        return sum
    }

    // The instances' descriptors as a scene's structure is built from them (indirect ones: they name
    // their meshes' structures by resource ID, and their instances by `id`), and the structures they name.
    private var descriptors: (bytes: [UInt8], structures: [Int: MTLAccelerationStructure])?

    /// The descriptors, for a scene whose meshes' structures are `primitives`: made the first time, and again only if
    /// a mesh has another structure now (any thread). A plant (an assembly's record) names its variant in `plants`
    /// for the season's `fall`; those are the scene's own, and not kept.
    func descriptors(primitives: [MTLAccelerationStructure], plants: PlantTracing? = nil, fall: Float = 0) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if plants == nil, let made = descriptors, made.structures.allSatisfy({ $0.key < primitives.count && primitives[$0.key] === $0.value }) {
            return made.bytes
        }
        let stride = SceneBuffers.indirectStride
        let options = MTLAccelerationStructureInstanceOptions([.opaque, .disableTriangleCulling]).rawValue
        var bytes = [UInt8](repeating: 0, count: count * stride), structures: [Int: MTLAccelerationStructure] = [:]
        let records = held
        var hasPlants = false
        bytes.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                let record = records[i], mesh = Int(record.meshIndex)
                if record.meshIndex & InstanceBlock.assembly != 0, let plants {
                    hasPlants = true
                    let assembly = Int(record.meshIndex & ~InstanceBlock.assembly)
                    SceneBuffers.writeDescriptor(raw.baseAddress! + i * stride, transform: record.transform, options: plants.instanceOptions,
                                                 mask: record.pad0, userID: id(i),
                                                 structure: plants.structure(set: 0, assembly: assembly, id: id(i), fall: fall))
                    continue
                }
                SceneBuffers.writeDescriptor(raw.baseAddress! + i * stride, transform: record.transform, options: options, mask: record.pad0,
                                             userID: id(i), structure: primitives[mesh])
                structures[mesh] = primitives[mesh]
            }
        }
        if !hasPlants { descriptors = (bytes, structures) }
        return bytes
    }
}

/// A scene on the GPU: its geometry's buffers, its instances' records, and its acceleration structures. Made on any
/// thread: where the scene is prepared (the background, when the app changes scenes), so that installing a scene
/// between two frames only swaps these in.
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
        /// Its instance groups' blocks, by their names.
        var instanceBlocks: [String: InstanceBlock] = [:]
        /// Its plants' voxel grids, which a scene of the same plants takes as they are.
        var voxelGrids: VoxelGrids?
        /// Instances the top-level structure has after the scene's (virtual geometry's cut of clusters: VirtualTracing),
        /// whose descriptors their owner writes.
        var extraInstances = 0
        /// The share of the leaves that have fallen (Scene.leafFall): which variants a still scene's plants name.
        var leafFall: Float = 0
        /// The load to report the buffers and the structures' batches to; the batches stop when it is cancelled.
        var load: LoadJob?
    }

    /// The scene's arrays (what its borrowed meshes have is in `blocks`), and its mesh table.
    let positions, normals, indices, meshes, uvs, emissive, triangleMaterials: MTLBuffer
    /// Per mesh: the block of a borrowed mesh, nil for a mesh of the arrays. Empty if no mesh is borrowed.
    let blocks: [MeshBlock?]
    private(set) var namedBlocks: [String: MeshBlock] = [:]
    let materials: [MTLBuffer]                              // per slot: light proxies' and leaves' materials change
    let instanceData: [MTLBuffer]                           // per slot (GPUInstanceData)
    /// The SDF shapes, and their boxes, which come after the meshes' structures in `primitives`.
    let sdf: SDFBuffers
    let still: Bool                                         // the instances are written, and their structure built
    /// The plants' structures (assemblies, by multi-level instancing), if the scene has any.
    private(set) var plants: PlantTracing?
    /// What `plants`' variants were chosen for in a still scene (a moving one's frames choose theirs).
    let leafFall: Float
    /// The scene's groups' blocks, in the groups' order: the instances are counted through, the scene's own first,
    /// then each block's (the descriptors are in that order).
    let instanceBlocks: [InstanceBlock]
    private(set) var namedInstanceBlocks: [String: InstanceBlock] = [:]
    let instanceCount: Int
    /// What the top-level structure is built over: `instanceCount`, and `Options.extraInstances` after them.
    let structureInstances: Int
    /// With blocks (TILED): the table a hit finds a record through, the records' addresses by block number (the
    /// scene's own, `instanceData`, at 0), and what it points at.
    let instanceTable: MTLBuffer?
    let instanceResources: [MTLBuffer]

    let instanceDescriptors: [MTLBuffer]                    // per slot
    private(set) var primitives: [MTLAccelerationStructure] = []        // per mesh
    private(set) var namedPrimitives: [String: MTLAccelerationStructure] = [:]
    private(set) var primitiveRefit: PrimitiveRefit?        // the meshes that deform (the crowd's pose slots)
    /// The strands' control points' radii (Scene.curveRadii), which their curves' structures read.
    private(set) var curveRadii: MTLBuffer?
    private(set) var instanceStructures: [MTLAccelerationStructure] = []   // per slot
    private(set) var instanceScratch: [MTLBuffer] = []      // per slot; none for a still scene
    /// A still scene with baked plants that have voxel grids: their levels, and the structures over the instances
    /// they are built into (the frames trace its `current`, not `instanceStructures`).
    private(set) var voxelLOD: VoxelLOD?

    static let indirectStride = 72
    var descriptorStride: Int { indirect ? SceneBuffers.indirectStride : 64 }
    /// The descriptors are indirect ones: Metal 4's, and those of a scene with instance blocks or virtual geometry
    /// under either API (they carry the ids a hit names an instance by, or the structures of the cuts).
    let indirect: Bool
    private static let buildBatchBytes = 256 << 20

    /// The borrowed meshes' buffers: a hit reads them through the addresses in the mesh table.
    var blockBuffers: [MTLBuffer] { blocks.compactMap { $0?.geometry } }

    /// Every buffer of the scene a frame reads.
    var buffers: [MTLBuffer] {
        [positions, normals, indices, meshes, uvs, emissive, triangleMaterials] + materials + (still ? [instanceData[0]] : instanceData)
            + blockBuffers + instanceResources + sdf.buffers
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
                mb(distinct(instanceData + instanceDescriptors + instanceResources).reduce(0) { $0 + $1.length }),
                mb(primitives.reduce(0) { $0 + $1.size }),
                mb(distinct(instanceStructures).reduce(0) { $0 + $1.size } + instanceScratch.reduce(0) { $0 + $1.length })
                    + (voxelLOD.map { $0.megabytes + $0.grids.megabytes } ?? 0))
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
        options.load?.step("Buffers", detail: scene.hasSDFShapes ? "arrays, SDF shapes" : "arrays")
        positions = try buffer(scene.positions, "positions")
        sdf = try SDFBuffers(device: device, scene: scene)
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
        // The groups: each in the block the scene being drawn has it in, or a new one, made from the group's instances.
        guard !scene.hasGroups || (!scene.groups.isEmpty && still) else {
            throw RendererError.resourceCreation("the buffers of a scene that has let go of its instance groups, or in which something moves")
        }
        var known = scene.groups.map { group in options.instanceBlocks[group.name].flatMap { $0.count == group.count ? $0 : nil } }
        var firsts: [Int] = [], total = count
        for group in scene.groups {
            firsts.append(total)
            total += group.count
        }
        instanceCount = total
        structureInstances = total + options.extraInstances
        indirect = options.api == .metal4 || scene.hasGroups || scene.usesVirtualGeometry || !scene.assemblies.isEmpty
        leafFall = options.leafFall
        let recordStride = MemoryLayout<GPUInstanceData>.stride
        var data = try (0..<sets).map { try empty(count * recordStride, "instanceData\($0)") }
        if still {
            let records = data[0].contents().bindMemory(to: GPUInstanceData.self, capacity: count)
            SceneBuffers.inParts(count) { scene.writeInstanceData(into: records, all: true, range: $0) }
            data = [MTLBuffer](repeating: data[0], count: options.slots)
        }
        instanceData = data
        // A block the scene being drawn has, as it is. A new one: made from its group's instances, which are let go of as
        // soon as their records are written.
        known.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: out.count) { g in
                guard out[g] == nil else { return }
                let group = scene.groups[g], instances = group.make()
                if instances.count == group.count { out[g] = try? InstanceBlock(device: device, name: group.name, instances: instances) }
            }
        }
        guard !known.contains(where: { $0 == nil }) else { throw RendererError.resourceCreation("the instances of a group") }
        instanceBlocks = known.map { $0! }
        for block in instanceBlocks { namedInstanceBlocks[block.name] = block }
        if scene.hasGroups {
            guard count <= 1 << InstanceBlock.shift else { throw RendererError.resourceCreation("the ids of \(count) instances outside the groups") }
            let buffers = instanceBlocks.map(\.buffer)
            var addresses = [UInt64](repeating: 0, count: InstanceBlock.capacity)
            addresses[0] = data[0].gpuAddress
            for (b, block) in instanceBlocks.enumerated() { addresses[block.number] = buffers[b].gpuAddress }
            let table = try buffer(addresses, "instanceTable")
            instanceTable = table
            instanceResources = [table, data[0]] + buffers
        } else {
            instanceTable = nil
            instanceResources = []
        }

        precondition(MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride == 64)
        if #available(macOS 14.0, *) { precondition(MemoryLayout<MTLIndirectAccelerationStructureInstanceDescriptor>.stride == SceneBuffers.indirectStride) }
        let stride = indirect ? SceneBuffers.indirectStride : 64, descriptorCount = structureInstances
        var descriptors = try (0..<sets).map { try empty(descriptorCount * stride, "instanceDescriptors\($0)") }
        if still { descriptors = [MTLBuffer](repeating: descriptors[0], count: options.slots) }
        instanceDescriptors = descriptors
        try buildPrimitives(device: device, queue: queue, scene: scene, options: options)
        if !scene.assemblies.isEmpty {
            plants = try PlantTracing(device: device, queue: queue, scene: scene, meshStructures: primitives, positions: positions,
                                      indices: indices, sets: still ? 1 : options.slots)
        }
        // The SDF shapes' boxes after the meshes' structures (an SDF instance's descriptor names its shape's there).
        try sdf.buildBoxes(device: device, queue: queue, scene: scene)
        primitives += sdf.boxes
        // Far plants: their grids' boxes after the meshes' structures (VoxelLOD names them from there; PlantTracing
        // names the assemblies' by their grids).
        let voxelGrids = scene.hasVoxelBoxes
            ? try options.voxelGrids.flatMap { $0.key == VoxelGrids.key(scene.voxelPlants) ? $0 : nil }
                ?? VoxelGrids(device: device, queue: queue, plants: scene.voxelPlants)
            : nil
        let meshStructures = primitives.count
        if let voxelGrids { primitives += voxelGrids.boxes }
        if !still { plants?.voxels = voxelGrids }
        guard let placeholder = primitives.first else { return }

        // The instances' structures, sized from the descriptor a build uses (the structure and its scratch buffer
        // don't exist yet: the descriptor is made with placeholders for them).
        var usage = options.instanceUsage
        if still { usage.remove([.refit, .preferFastBuild]) }
        func update(_ structure: MTLAccelerationStructure, _ scratch: MTLBuffer, slot: Int) -> TLASUpdate {
            TLASUpdate(structure: structure, scratch: scratch, refit: false, instanceCount: structureInstances, usage: usage,
                       instances: descriptors[slot], instanceStride: stride, primitives: primitives, indirect: indirect)
        }
        let layout = update(placeholder, descriptors[0], slot: 0)
        let sizes: MTLAccelerationStructureSizes
        if still {
            sizes = device.accelerationStructureSizes(descriptor: layout.descriptor(indirect: indirect))
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
        // The blocks' after the scene's own: each block's as it has them, the new blocks' made here.
        let groups = instanceBlocks, structures = primitives, into = descriptors[0].contents(), plants = plants, fall = leafFall
        DispatchQueue.concurrentPerform(iterations: groups.count) { b in
            groups[b].descriptors(primitives: structures, plants: plants, fall: fall).withUnsafeBytes {
                (into + firsts[b] * stride).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }
        guard let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RendererError.resourceCreation("acceleration structure command encoder")
        }
        let build = update(instanceStructures[0], instanceScratch[0], slot: 0)
        // Indirect descriptors name the meshes' structures by ID: the build reads them, so they must be resident (a
        // structure the GPU has let go of reads as empty, and its instances aren't in the tree).
        if indirect { encoder.useResources(primitives + (plants?.structures(slot: 0) ?? []), usage: .read) }
        encoder.build(accelerationStructure: build.structure, descriptor: build.descriptor(indirect: indirect),
                      scratchBuffer: build.scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let voxelGrids {
            // Every baked plant's instance that has a grid: the scene's own, and the blocks' (by their places).
            let lookup = scene.meshVoxels, records = voxelGrids.gridRecords
            var entries: [VoxelLOD.Entry] = []
            for (i, inst) in scene.instances.enumerated() where inst.mesh >= 0 {
                if let e = VoxelLOD.entry(descriptor: i, transform: inst.transform, mesh: inst.mesh, mask: inst.mask, meshVoxels: lookup, grids: records) {
                    entries.append(e)
                }
            }
            for (b, block) in instanceBlocks.enumerated() {
                block.withRecords { r in
                    for i in r.indices {
                        if let e = VoxelLOD.entry(descriptor: firsts[b] + i, transform: r[i].transform, mesh: Int(r[i].meshIndex),
                                                  mask: r[i].pad0, meshVoxels: lookup, grids: records) {
                            entries.append(e)
                        }
                    }
                }
            }
            voxelLOD = try VoxelLOD(device: device, grids: voxelGrids, entries: entries, descriptors: descriptors[0], stride: stride,
                                    indirect: indirect, primitives: primitives, meshCount: meshStructures, instanceCount: total,
                                    usage: usage, current: instanceStructures[0], scratch: instanceScratch[0])
        }
        instanceStructures = [MTLAccelerationStructure](repeating: instanceStructures[0], count: options.slots)
        instanceScratch = []
    }

    /// Compacted copies of `structures`, built and done: their compacted sizes (UInt32s) are in `sizes` at the indices
    /// `at` (nil: written here first, one after the other). A compacted copy holds what its structure keeps, about half
    /// what a build reserves: less memory to walk, fewer cache misses per ray.
    static func copyAndCompact(_ structures: [MTLAccelerationStructure], sizes: MTLBuffer? = nil, at: [Int]? = nil,
                               device: MTLDevice, queue: MTLCommandQueue) throws -> [MTLAccelerationStructure] {
        guard !structures.isEmpty else { return [] }
        let stride = MemoryLayout<UInt32>.stride
        var sizeBuffer = sizes
        if sizeBuffer == nil {
            guard let b = device.makeBuffer(length: structures.count * stride, options: .storageModeShared),
                  let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeAccelerationStructureCommandEncoder() else {
                throw RendererError.resourceCreation("compacted sizes")
            }
            for (k, structure) in structures.enumerated() {
                encoder.writeCompactedSize(accelerationStructure: structure, buffer: b, offset: k * stride, sizeDataType: .uint)
            }
            encoder.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            sizeBuffer = b
        }
        guard let sizeBuffer, let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RendererError.resourceCreation("acceleration structure command encoder")
        }
        let index = at ?? Array(structures.indices)
        let read = sizeBuffer.contents().bindMemory(to: UInt32.self, capacity: (index.max() ?? 0) + 1)
        var small: [MTLAccelerationStructure] = []
        for (k, structure) in structures.enumerated() {
            guard let copy = device.makeAccelerationStructure(size: Int(read[index[k]])) else {
                throw RendererError.resourceCreation("compacted acceleration structure")
            }
            copy.label = structure.label
            encoder.copyAndCompact(sourceAccelerationStructure: structure, destinationAccelerationStructure: copy)
            small.append(copy)
        }
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return small
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
        // An SDF shape's box: the ray queries' loop is handed it (it isn't opaque) and marches the shape.
        let boxOptions = MTLAccelerationStructureInstanceOptions([.nonOpaque, .disableTriangleCulling]).rawValue
        let stride = indirect ? SceneBuffers.indirectStride : 64
        let meshCount = scene.meshes.count
        let plants = plants, set = plants?.set(slot: slot) ?? 0
        let holes = scene.hasOpacity   // an alpha-tested instance (a procedural material's opacity) isn't opaque either
        func write(_ i: Int) {
            let instance = scene.instances[i]
            guard instance.virtualMesh < 0 else { return }   // its cut's structure: VirtualTracing writes it
            if instance.assembly >= 0, let plants {   // a plant: its assembly's variant (in the wind, PlantTracing writes it again)
                SceneBuffers.writeDescriptor(base.advanced(by: i * stride), transform: instance.transform, options: plants.instanceOptions,
                                             mask: instance.mask, userID: UInt32(i),
                                             structure: plants.structure(set: set, assembly: instance.assembly, id: UInt32(i), fall: leafFall))
                return
            }
            let index = instance.sdf >= 0 ? meshCount + instance.sdf : instance.mesh
            // An indirect one's user ID: the instance's id, which a scene with instance blocks takes a hit's from.
            SceneBuffers.writeDescriptor(base.advanced(by: i * stride), transform: instance.transform,
                                         options: instance.sdf >= 0 || (holes && scene.cutsHoles(i)) ? boxOptions : options, mask: instance.mask,
                                         userID: UInt32(i), structure: indirect ? primitives[index] : nil, index: index)
        }
        if all {
            for i in range ?? scene.instances.indices { write(i) }
        } else {
            for i in scene.movingInstances { write(i) }
        }
    }

    /// An instance descriptor at `p`: an indirect one, which names its mesh's `structure` by resource ID and has a
    /// user ID, or without a structure Metal 3's, which has the mesh's `index` among the structures.
    static func writeDescriptor(_ p: UnsafeMutableRawPointer, transform m: float4x4, options: UInt32, mask: UInt32, userID: UInt32,
                                structure: MTLAccelerationStructure?, index: Int = 0) {
        var offset = 0
        for column in 0..<4 {           // packed column-major 4x3 matrix
            for row in 0..<3 {
                p.storeBytes(of: m[column][row], toByteOffset: offset, as: Float.self)
                offset += 4
            }
        }
        p.storeBytes(of: options, toByteOffset: 48, as: UInt32.self)
        p.storeBytes(of: mask, toByteOffset: 52, as: UInt32.self)
        p.storeBytes(of: UInt32(0), toByteOffset: 56, as: UInt32.self)              // intersection function table offset
        if let structure {
            p.storeBytes(of: userID, toByteOffset: 60, as: UInt32.self)
            p.storeBytes(of: structure.gpuResourceID, toByteOffset: 64, as: MTLResourceID.self)
        } else {
            p.storeBytes(of: UInt32(index), toByteOffset: 60, as: UInt32.self)      // index into `primitives`
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
        // A liquid's surface changes its triangles: its structure is built again every frame (fast to build).
        var rebuilt: [(index: Int, descriptor: MTLPrimitiveAccelerationStructureDescriptor, scratch: Int)] = []
        var jobs: [(index: Int, descriptor: MTLPrimitiveAccelerationStructureDescriptor, sizes: MTLAccelerationStructureSizes, deforms: Bool)] = []
        // The poses that take another's tree: (its place in `refitted`, the mesh whose tree it takes).
        var copies: [(refit: Int, of: Int)] = []
        var firstPose: [SIMD2<UInt32>: Int] = [:]   // by the triangles a pose has: its character's
        if scene.hasCurves {
            curveRadii = device.makeBuffer(bytes: scene.curveRadii, length: max(scene.curveRadii.count, 1) * MemoryLayout<Float>.stride,
                                           options: .storageModeShared)
            curveRadii?.label = "curveRadii"
        }
        for i in new {
            let mesh = scene.meshes[i]
            if let curves = scene.curveMeshes[i], let curveRadii, #available(macOS 14.0, *) {
                // Strands: round Catmull-Rom curves through the mesh's control points (its vertices), refitted every
                // frame as the GPU moves them.
                let geometry = MTLAccelerationStructureCurveGeometryDescriptor()
                geometry.controlPointBuffer = positions
                geometry.controlPointBufferOffset = Int(mesh.vertexOffset) * MemoryLayout<SIMD3<Float>>.stride
                geometry.controlPointCount = curves.radii.count
                geometry.controlPointStride = MemoryLayout<SIMD3<Float>>.stride
                geometry.controlPointFormat = .float3
                geometry.radiusBuffer = curveRadii
                geometry.radiusBufferOffset = curves.radii.lowerBound * MemoryLayout<Float>.stride
                geometry.radiusStride = MemoryLayout<Float>.stride
                geometry.radiusFormat = .float
                geometry.indexBuffer = indices
                geometry.indexBufferOffset = Int(mesh.firstIndex) * MemoryLayout<UInt32>.stride
                geometry.indexType = .uint32
                geometry.segmentCount = curves.segments
                geometry.segmentControlPointCount = 4
                geometry.curveType = .round
                geometry.curveBasis = .catmullRom
                geometry.curveEndCaps = .disk
                geometry.opaque = true
                let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
                descriptor.geometryDescriptors = [geometry]
                descriptor.usage = .refit
                let sizes = device.accelerationStructureSizes(descriptor: descriptor)
                refitted.append((i, descriptor, max(sizes.refitScratchBufferSize, 16)))
                jobs.append((i, descriptor, sizes, true))
                continue
            }
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
            geometry.opaque = mesh.cutout == 0   // leaf cards: the queries' loop cuts them out (Intersect.metal, rtCutout)

            let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
            descriptor.geometryDescriptors = [geometry]
            // The meshes never change, so their structures are built once, for the fastest traversal Metal offers.
            let deforms = mesh.prevOffset != 0
            if scene.rebuiltMeshes.contains(i) {
                descriptor.usage = .preferFastBuild
                let sizes = device.accelerationStructureSizes(descriptor: descriptor)
                rebuilt.append((i, descriptor, max(sizes.buildScratchBufferSize, 16)))
                jobs.append((i, descriptor, sizes, true))
                continue
            }
            if deforms { descriptor.usage = .refit }
            else if scene.remadeOften { descriptor.usage = .preferFastBuild }
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
                if options.compact && !scene.remadeOften && !job.deforms {
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
            guard options.compact && !scene.remadeOften else { return }
            let kept = (0..<batch.count).filter { !jobs[batch.lowerBound + $0].deforms }
            let small = try SceneBuffers.copyAndCompact(kept.map { built[$0] }, sizes: compactedSizes, at: kept, device: device, queue: queue)
            for (n, k) in kept.enumerated() {
                structures[jobs[batch.lowerBound + k].index] = small[n]
                before += built[k].size
                after += small[n].size
            }
        }
        let step = options.load?.step("Metal BLAS", total: jobs.count, detail: new.count < structures.count
                                      ? "\(structures.count - new.count) kept from the last scene" : "")
        var first = 0, bytes = 0, total = 0
        func buildBatch(_ batch: Range<Int>) throws {
            if step?.isCancelled == true { throw CancellationError() }   // another scene was asked for
            try autoreleasepool { try build(batch) }
            total += batch.reduce(0) { $0 + jobs[$1].sizes.accelerationStructureSize }
            step?.advance(by: batch.count, detail: String(format: "%.0f MB built", Double(total) / 1_048_576))
        }
        for j in jobs.indices {
            bytes += jobs[j].sizes.accelerationStructureSize
            if bytes >= SceneBuffers.buildBatchBytes {
                try buildBatch(first..<(j + 1))
                (first, bytes) = (j + 1, 0)
            }
        }
        try buildBatch(first..<jobs.count)
        if options.compact && !scene.remadeOften, !jobs.isEmpty {
            print(String(format: "Metal BLAS: %d meshes (%d the last scene's), %.1f MB compacted to %.1f MB", structures.count,
                         structures.count - new.count, Double(before) / 1_048_576, Double(after) / 1_048_576))
        }
        if !refitted.isEmpty || !rebuilt.isEmpty {
            // One scratch buffer, a range per structure: the refits (and builds) of a frame may run side by side.
            var offsets: [Int] = [], length = 0
            for r in refitted { offsets.append(length); length += (r.scratch + 255) & ~255 }
            var rebuiltOffsets: [Int] = []
            for r in rebuilt { rebuiltOffsets.append(length); length += (r.scratch + 255) & ~255 }
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
                                            scratch: scratch, scratchOffsets: offsets,
                                            rebuilt: rebuilt.indices.map { (structures[rebuilt[$0].index]!, rebuilt[$0].descriptor, rebuiltOffsets[$0]) },
                                            rebuiltMeshes: rebuilt.map(\.index))
        }
        primitives = structures.map { $0! }
        for (i, name) in scene.meshNames { namedPrimitives[name] = primitives[i] }
    }
}
