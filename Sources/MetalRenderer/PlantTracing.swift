import Foundation
import Metal
import simd

/// A part of an assembly as the GPU reads it (MSL `RTPart`, Shaders/Foliage.metal): plant -> part rows, its mesh,
/// where its leaves start and how many they are, its bones.
struct RTPart {
    var row0 = SIMD4<Float>()
    var row1 = SIMD4<Float>()
    var row2 = SIMD4<Float>()
    var mesh: UInt32 = 0
    var pad: UInt32 = 0             // RTPart.rigid: a building's part (no wind)
    var firstLeaf: UInt32 = 0
    var leafCount: UInt32 = 0       // the mesh's leaf triangles, which autumn drops (0 = evergreen)
    var limb = SIMD4<Float>()       // the wind's bones: pivot and largest turn, axis and phase (Scene.Assembly.Bone)
    var limbAxis = SIMD4<Float>()
    var bough = SIMD4<Float>()
    var boughAxis = SIMD4<Float>()

    /// `pad`: the part is a rigid assembly's (Scene.Assembly.rigid, MSL RT_PART_RIGID).
    static let rigid: UInt32 = 1
}

/// The wind's math on the CPU, as Shaders/Foliage.metal has it: what a plant's instance and a patch of ground cover's
/// carry in their transforms (the shading does the same to the hit point).
enum Wind {
    static let phases = 8           // PLANT_PHASES

    /// windWave: a sine's shape (period 2 pi) from a parabola.
    static func wave(_ x: Float) -> Float {
        let y = x * 0.15915494
        let t = (y - y.rounded(.down)) * 2 - 1
        return 4 * t * (1 - abs(t))
    }

    /// windGust: how hard it blows at `p`, 0...1.
    static func gust(_ wind: SIMD4<Float>, _ p: SIMD3<Float>, _ time: Float) -> Float {
        let along = wind.x * p.x + wind.y * p.z, across = -wind.y * p.x + wind.x * p.z
        let w = 0.6 * wave(along * 0.07 - time * 1.1 + 0.6 * wave(across * 0.05)) + 0.4 * wave(along * 0.19 - time * 2.3 + across * 0.11)
        return 1 + (0.5 + 0.5 * w - 1) * wind.w
    }

    /// windTurn's matrix: a turn by `angle` about the unit `axis` (Rodrigues, the sine and cosine by their series).
    static func turn(_ axis: SIMD3<Float>, _ angle: Float) -> float3x3 {
        let a2 = angle * angle
        let s = angle * (1 - a2 / 6), oneMinusC = a2 * (0.5 - a2 / 24)
        func apply(_ v: SIMD3<Float>) -> SIMD3<Float> { v + cross(axis, v) * s + (axis * dot(axis, v) - v) * oneMinusC }
        return float3x3(apply([1, 0, 0]), apply([0, 1, 0]), apply([0, 0, 1]))
    }

    /// A plant's phase (plantWind's) and its bucket (plantBucket), from its id.
    static func phaseBits(_ id: UInt32) -> UInt32 { VoxelLOD.pcgHash(id &+ 0x5EED) & 0xFFFF }
    static func bucket(_ id: UInt32) -> Int { Int((phaseBits(id) * UInt32(phases)) >> 16) }

    /// A plant's instance transform in the wind: `transform` turned about the plant's foot as plantWind turns it.
    static func plant(_ transform: float4x4, wind: SIMD4<Float>, time: Float, id: UInt32) -> float4x4 {
        guard wind.z > 0 else { return transform }
        let linear = float3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                              SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                              SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let origin = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let downwind = linear.inverse * SIMD3(wind.x, 0, wind.y)
        let axis = cross(SIMD3<Float>(0, 1, 0), downwind)
        let len = length(axis)
        let unit = len > 1e-6 ? axis / len : SIMD3<Float>(1, 0, 0)
        let phase = Float(phaseBits(id)) * (2 * .pi / 65536)
        let angle = wind.z * Scene.Assembly.rootSway * gust(wind, origin, time) * (0.55 + 0.45 * wave(time * 1.3 + phase))
        let r = turn(unit, angle)
        return transform * float4x4(SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(0, 0, 0, 1))
    }

    /// A patch of ground cover's instance transform in the wind: `transform` sheared downwind by height (coverLean).
    static func cover(_ transform: float4x4, wind: SIMD4<Float>, time: Float) -> float4x4 {
        guard wind.z > 0 else { return transform }
        let inverse = transform.inverse
        let origin = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let to = SIMD4<Float>(wind.x, 0, wind.y, 0)
        var downwind = SIMD2((inverse * to).x, (inverse * to).z)
        let swing = 0.6 + 0.4 * wave(time * 2.6 - (wind.x * origin.x + wind.y * origin.z) * 0.9)
        let lean = wind.z * Scene.coverLean * gust(wind, origin, time) * swing
        downwind *= lean / max(length(downwind), 1e-6)
        var shear = matrix_identity_float4x4
        shear.columns.1 = SIMD4(downwind.x, 1, downwind.y, 0)
        return transform * shear
    }

    /// plantKeep: the share of its leaves a deciduous plant still has when `fall` of all leaves are down.
    static func keep(fall: Float, id: UInt32) -> Float {
        1 - min(max(fall * 1.6 - 0.6 * Float(VoxelLOD.pcgHash(id &+ 0xFA11) & 0xFF) / 255, 0), 1)
    }
}

/// The plants (assemblies, Scene+Forest.swift) in Metal's structures, by multi-level instancing. Each assembly has
/// variants: instance structures over its parts, one per phase of the wind (`Wind.phases`) and, for a plant that drops
/// its leaves, per share of them still on it (`keepLevels`: its leafy parts' structures are over a prefix of their
/// triangles, the leaves being shuffled). A plant's instance names the variant of its phase's bucket and of its share,
/// and its transform carries its own turn about its foot (`Wind.plant`); the variants' parts are posed in the wind every
/// frame by plantWindKernel (one phase each, the mean gust) and their structures refitted (`windWork`). A part
/// instance's user id is the part's number among every assembly's (`parts`), which a hit names it by.
///
/// A scene that moves has a set of variants per frame slot; a still one (the open world's tiles: instance blocks,
/// whose structure is built once) has one, at rest: its plants stand still.
final class PlantTracing {
    static let keepLevels: [Float] = [0, 0.25, 0.5, 0.75, 1]
    static let descriptorStride = SceneBuffers.indirectStride
    /// After its parts, a variant has two instances that no ray meets (mask 0) at its assembly's box's corners: the
    /// variant's bounds stay its plant's, padded for the wind, however its parts turn (the top-level structure keeps them).
    static let pads = 2

    let parts: MTLBuffer
    private let partBase: [Int]
    private let partCount: [Int]
    private let keeps: [Int]                     // per assembly: 1, or keepLevels.count for one that drops its leaves
    private let phases: [Int]                    // per assembly: Wind.phases, or 1 for a rigid one (a building)
    private let rigid: [Bool]                    // per assembly: Scene.Assembly.rigid
    private let variantBase: [Int]               // per assembly: its first variant
    private let descriptorBase: [Int]            // per variant: its first descriptor
    let variantCount: Int
    private let descriptorCount: Int
    /// Per set (a frame slot's, or the one of a still scene): the variants' structures and their descriptors.
    private(set) var sets: [[MTLAccelerationStructure]] = []
    private var descriptorBuffers: [MTLBuffer] = []
    private var variantDescriptors: [[MTLInstanceAccelerationStructureDescriptor]] = []
    private let work: MTLBuffer                  // per descriptor: (part, phase bucket); ~0 for the pads
    private let scratch: MTLBuffer               // the refits', a range per variant
    private let scratchOffsets: [Int]
    /// Per variant: the structures its parts name (and the pads'), resident while it is built or refitted.
    private let variantBlases: [[MTLAccelerationStructure]]
    /// The structures the variants name (the meshes', the leafy meshes' prefixes, the pads'): resident wherever a
    /// variant is built, refitted or traced.
    let blases: [MTLAccelerationStructure]
    private let prefixes: [MTLAccelerationStructure]
    /// The leaf cards' alpha layers, one after the other (Scene.cutouts), for the ray queries' alpha test.
    let cutouts: MTLBuffer
    let hasCards: Bool
    /// Per set: what its parts were last posed for (WindFrame.poseKey; a still wind's at rest), and the variants its
    /// plants name (the ones its frames refit).
    private var posed: [SIMD8<Float>]
    private var used: [[Int]]
    /// Far plants as their voxels (SceneSettings.voxelBoxes, a scene that moves): the assemblies' grids, whose boxes
    /// a far plant's instance names at its level instead of its variant (as VoxelLOD does a still scene's baked plants).
    var voxels: VoxelGrids?
    /// Per set: what each plant's descriptor names (its variant, variantCount + its rest variant, or -1 - its voxel
    /// level's box), to tell when another structure is named: the top-level structure is then built again, not refitted.
    private var chosen: [[Int32]]
    /// A scene that moves: per assembly and share kept, a variant at rest, built once and never posed or refitted,
    /// which a plant beyond the wind's `sway` reach names (it still leans as a whole: its instance's transform). Per
    /// assembly, its first.
    private(set) var rest: [MTLAccelerationStructure] = []
    private var restBase: [Int] = []

    /// `meshStructures`: each mesh's (SceneBuffers.primitives); `positions` and `indices`: the scene's arrays, which the
    /// leafy meshes' prefixes are built over. `sets`: 1 for a still scene, else the frame slots.
    init(device: MTLDevice, queue: MTLCommandQueue, scene: Scene, meshStructures: [MTLAccelerationStructure], positions: MTLBuffer,
         indices: MTLBuffer, sets setCount: Int) throws {
        func buffer(_ length: Int, _ label: String, shared: Bool = true) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(length, 16), options: shared ? .storageModeShared : .storageModePrivate) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            b.label = label
            return b
        }
        // Every assembly's parts.
        var records: [RTPart] = [], bases: [Int] = [], counts: [Int] = [], keeps: [Int] = []
        for assembly in scene.assemblies {
            bases.append(records.count)
            counts.append(assembly.parts.count)
            keeps.append(!assembly.rigid && !assembly.evergreen && !scene.remadeOften && assembly.parts.contains { $0.leafCount > 0 }
                         ? PlantTracing.keepLevels.count : 1)
            for part in assembly.parts {
                let inv = part.transform.inverse
                records.append(RTPart(row0: SIMD4(inv[0][0], inv[1][0], inv[2][0], inv[3][0]),
                                      row1: SIMD4(inv[0][1], inv[1][1], inv[2][1], inv[3][1]),
                                      row2: SIMD4(inv[0][2], inv[1][2], inv[2][2], inv[3][2]),
                                      mesh: UInt32(part.mesh), firstLeaf: part.firstLeaf, leafCount: part.leafCount,
                                      limb: SIMD4(part.limb.pivot, part.limb.angle), limbAxis: SIMD4(part.limb.axis, part.limb.phase),
                                      bough: SIMD4(part.bough.pivot, part.bough.angle), boughAxis: SIMD4(part.bough.axis, part.bough.phase)))
            if assembly.rigid { records[records.count - 1].pad = RTPart.rigid }
            }
        }
        precondition(MemoryLayout<RTPart>.stride == 128, "RTPart: Shaders/Foliage.metal")
        parts = try records.withUnsafeBytes { raw in
            guard let b = raw.isEmpty ? device.makeBuffer(length: 16) : device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) else {
                throw RendererError.resourceCreation("buffer plantParts")
            }
            b.label = "plantParts"
            return b
        }
        let rigid = scene.assemblies.map(\.rigid), phases = rigid.map { $0 ? 1 : Wind.phases }
        (partBase, partCount, self.keeps, self.phases, self.rigid) = (bases, counts, keeps, phases, rigid)

        // The leafy meshes' prefixes: a structure over the wood and the first share of the leaves, for each share.
        var prefixes: [SIMD2<Int>: MTLAccelerationStructure] = [:]
        var jobs: [(key: SIMD2<Int>, descriptor: MTLPrimitiveAccelerationStructureDescriptor)] = []
        for (a, assembly) in scene.assemblies.enumerated() where keeps[a] > 1 {
            for part in assembly.parts where part.leafCount > 0 {
                let mesh = scene.meshes[part.mesh]
                for keep in PlantTracing.keepLevels.dropLast() {
                    let count = Int(part.firstLeaf) + Int(Float(part.leafCount) * keep)
                    let key = SIMD2(part.mesh, count)
                    guard prefixes[key] == nil, !jobs.contains(where: { $0.key == key }) else { continue }
                    let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
                    geometry.vertexBuffer = positions
                    geometry.vertexBufferOffset = Int(mesh.vertexOffset) * MemoryLayout<SIMD3<Float>>.stride
                    geometry.vertexStride = MemoryLayout<SIMD3<Float>>.stride
                    geometry.indexBuffer = indices
                    geometry.indexBufferOffset = Int(mesh.firstIndex) * MemoryLayout<UInt32>.stride
                    geometry.indexType = .uint32
                    geometry.triangleCount = max(count, 1)
                    geometry.opaque = mesh.cutout == 0   // leaf cards: the queries' loop cuts them out
                    let d = MTLPrimitiveAccelerationStructureDescriptor()
                    d.geometryDescriptors = [geometry]
                    jobs.append((key, d))
                }
            }
        }
        // A tiny triangle at the origin, which the pads place at the corners.
        let corner: [SIMD3<Float>] = [[0, 0, 0], [1e-4, 0, 0], [0, 1e-4, 0]]
        let padVertices = try corner.withUnsafeBytes { raw in
            guard let b = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) else { throw RendererError.resourceCreation("buffer plantPad") }
            return b
        }
        let padGeometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        padGeometry.vertexBuffer = padVertices
        padGeometry.vertexStride = MemoryLayout<SIMD3<Float>>.stride
        padGeometry.triangleCount = 1
        padGeometry.opaque = true
        let padDescriptor = MTLPrimitiveAccelerationStructureDescriptor()
        padDescriptor.geometryDescriptors = [padGeometry]
        jobs.append((SIMD2(-1, -1), padDescriptor))
        var built: [MTLAccelerationStructure] = []
        if let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() {
            var scratchBytes = 0, offsets: [Int] = []
            let sizes = jobs.map { device.accelerationStructureSizes(descriptor: $0.descriptor) }
            for s in sizes { offsets.append(scratchBytes); scratchBytes += (s.buildScratchBufferSize + 255) & ~255 }
            let scratch = try buffer(scratchBytes, "plantPrefixScratch", shared: false)
            for (k, job) in jobs.enumerated() {
                guard let accel = device.makeAccelerationStructure(size: sizes[k].accelerationStructureSize) else {
                    throw RendererError.resourceCreation("acceleration structure (a leafy mesh's prefix)")
                }
                enc.build(accelerationStructure: accel, descriptor: job.descriptor, scratchBuffer: scratch, scratchBufferOffset: offsets[k])
                built.append(accel)
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            // They never change: compacted, before any descriptor names them.
            if !scene.remadeOften { built = try SceneBuffers.copyAndCompact(built, device: device, queue: queue) }
        }
        guard built.count == jobs.count, let pad = built.last else { throw RendererError.resourceCreation("the plants' structures") }
        for (k, job) in jobs.enumerated().dropLast() { prefixes[job.key] = built[k] }

        // The variants: per assembly, per phase, per share kept; per variant its parts' descriptors, then the pads.
        var variantBase: [Int] = [], descriptorBase: [Int] = [], workItems: [SIMD2<UInt32>] = []
        var variant = 0
        for (a, assembly) in scene.assemblies.enumerated() {
            variantBase.append(variant)
            for _ in 0..<(phases[a] * keeps[a]) {
                descriptorBase.append(workItems.count)
                variant += 1
                let phase = UInt32((variant - 1 - variantBase[a]) % phases[a])
                for p in assembly.parts.indices { workItems.append(SIMD2(UInt32(partBase[a] + p), phase)) }
                for _ in 0..<PlantTracing.pads { workItems.append(SIMD2(.max, 0)) }
            }
        }
        (self.variantBase, self.descriptorBase, variantCount, descriptorCount) = (variantBase, descriptorBase, variant, workItems.count)
        work = try workItems.withUnsafeBytes { raw in
            guard let b = raw.isEmpty ? device.makeBuffer(length: 16) : device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) else {
                throw RendererError.resourceCreation("buffer plantWork")
            }
            b.label = "plantWork"
            return b
        }
        var perVariant: [[MTLAccelerationStructure]] = []
        for (a, assembly) in scene.assemblies.enumerated() {
            for v in 0..<(phases[a] * keeps[a]) {
                let keep = PlantTracing.keepLevels[keeps[a] == 1 ? PlantTracing.keepLevels.count - 1 : v / phases[a]]
                var mine: [ObjectIdentifier: MTLAccelerationStructure] = [ObjectIdentifier(pad): pad]
                for part in assembly.parts {
                    let count = Int(part.firstLeaf) + Int(Float(part.leafCount) * keep)
                    let structure = keep < 1 && part.leafCount > 0 ? prefixes[SIMD2(part.mesh, count)]! : meshStructures[part.mesh]
                    mine[ObjectIdentifier(structure)] = structure
                }
                perVariant.append(Array(mine.values))
            }
        }
        variantBlases = perVariant
        var named: [ObjectIdentifier: MTLAccelerationStructure] = [ObjectIdentifier(pad): pad]
        for assembly in scene.assemblies { for part in assembly.parts { named[ObjectIdentifier(meshStructures[part.mesh])] = meshStructures[part.mesh] } }
        for prefix in prefixes.values { named[ObjectIdentifier(prefix)] = prefix }
        blases = Array(named.values)
        self.prefixes = Array(prefixes.values) + [pad]

        // The cutouts, one layer after the other.
        let layers = scene.cutouts.flatMap(\.alpha)
        hasCards = !layers.isEmpty
        cutouts = try layers.withUnsafeBytes { raw in
            guard let b = raw.isEmpty ? device.makeBuffer(length: 16) : device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) else {
                throw RendererError.resourceCreation("buffer cutouts")
            }
            b.label = "cutouts"
            return b
        }

        // Each set: its descriptors at rest, and its variants built over them.
        let stride = PlantTracing.descriptorStride
        let options = MTLAccelerationStructureInstanceOptions([.disableTriangleCulling]).rawValue   // (the meshes say what is opaque)
        var refitOffsets: [Int] = [], refitBytes = 0
        for _ in 0..<setCount {
            let descriptors = try buffer(descriptorCount * stride, "plantVariants")
            let base = descriptors.contents()
            for (a, assembly) in scene.assemblies.enumerated() {
                for v in 0..<(phases[a] * keeps[a]) {
                    let keep = PlantTracing.keepLevels[keeps[a] == 1 ? PlantTracing.keepLevels.count - 1 : v / phases[a]]
                    var d = descriptorBase[variantBase[a] + v]
                    for (p, part) in assembly.parts.enumerated() {
                        let count = Int(part.firstLeaf) + Int(Float(part.leafCount) * keep)
                        let structure = keep < 1 && part.leafCount > 0 ? prefixes[SIMD2(part.mesh, count)]! : meshStructures[part.mesh]
                        SceneBuffers.writeDescriptor(base + d * stride, transform: part.transform, options: options, mask: 0xFF,
                                                     userID: UInt32(partBase[a] + p), structure: structure)
                        d += 1
                    }
                    for corner in [assembly.bounds.lo, assembly.bounds.hi] {
                        SceneBuffers.writeDescriptor(base + d * stride, transform: translate(corner), options: options, mask: 0,
                                                     userID: 0, structure: pad)
                        d += 1
                    }
                }
            }
            var structures: [MTLAccelerationStructure] = [], made: [MTLInstanceAccelerationStructureDescriptor] = []
            var buildSizes: [MTLAccelerationStructureSizes] = []
            for v in 0..<variantCount {
                let count = (v + 1 < variantCount ? descriptorBase[v + 1] : descriptorCount) - descriptorBase[v]
                let d = MTLInstanceAccelerationStructureDescriptor()
                d.instanceDescriptorBuffer = descriptors
                d.instanceDescriptorBufferOffset = descriptorBase[v] * stride
                d.instanceDescriptorStride = stride
                d.instanceCount = count
                guard #available(macOS 14.0, *) else { throw RendererError.unsupported("indirect instance descriptors (macOS 14)") }
                d.instanceDescriptorType = .indirect
                d.usage = setCount > 1 ? .refit : []
                let sizes = device.accelerationStructureSizes(descriptor: d)
                guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize) else {
                    throw RendererError.resourceCreation("acceleration structure (a plant's variant)")
                }
                accel.label = "plantVariant"
                structures.append(accel)
                made.append(d)
                buildSizes.append(sizes)
                if sets.isEmpty {
                    refitOffsets.append(refitBytes)
                    refitBytes += (max(sizes.refitScratchBufferSize, sizes.buildScratchBufferSize) + 255) & ~255
                }
            }
            sets.append(structures)
            descriptorBuffers.append(descriptors)
            variantDescriptors.append(made)
        }
        scratch = try buffer(refitBytes, "plantScratch", shared: false)
        scratchOffsets = refitOffsets
        posed = [SIMD8<Float>](repeating: WindFrame().poseKey, count: setCount)
        used = [[Int]](repeating: Array(0..<variantCount), count: setCount)
        chosen = [[Int32]](repeating: [], count: setCount)
        for set in sets.indices {
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() else {
                throw RendererError.resourceCreation("acceleration structure command encoder")
            }
            enc.useResources(blases, usage: .read)
            for v in 0..<variantCount {
                enc.build(accelerationStructure: sets[set][v], descriptor: variantDescriptors[set][v], scratchBuffer: scratch,
                          scratchBufferOffset: scratchOffsets[v])
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        // A still scene's one set is never refitted: compacted (the open world's plants name it).
        if setCount == 1 {
            sets[0] = try SceneBuffers.copyAndCompact(sets[0], device: device, queue: queue)
        }
        if setCount > 1 { try buildRest(device: device, queue: queue, compact: !scene.remadeOften) }
        print(String(format: "Plants: %d assemblies, %d parts, %d variants (%d structures), %.1f MB of variants",
                     scene.assemblies.count, records.count, variantCount, variantCount * sets.count,
                     Double(sets.joined().reduce(0) { $0 + $1.size } + rest.reduce(0) { $0 + $1.size }
                            + descriptorBuffers.reduce(0) { $0 + $1.length }) / 1_048_576))
    }

    /// The variants at rest (`rest`), from the first set's descriptors while they are still at rest: each share kept's
    /// phase 0 (the phases differ only once posed).
    private func buildRest(device: MTLDevice, queue: MTLCommandQueue, compact: Bool) throws {
        var made: [MTLInstanceAccelerationStructureDescriptor] = [], sizes: [MTLAccelerationStructureSizes] = []
        for a in variantBase.indices {
            restBase.append(made.count)
            for k in 0..<keeps[a] {
                let d = variantDescriptors[0][variantBase[a] + k * Wind.phases].copy() as! MTLInstanceAccelerationStructureDescriptor
                d.usage = []
                made.append(d)
                sizes.append(device.accelerationStructureSizes(descriptor: d))
            }
        }
        var offsets: [Int] = [], scratchBytes = 0
        for s in sizes { offsets.append(scratchBytes); scratchBytes += (s.buildScratchBufferSize + 255) & ~255 }
        guard let scratch = device.makeBuffer(length: max(scratchBytes, 16), options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeAccelerationStructureCommandEncoder() else {
            throw RendererError.resourceCreation("the plants' variants at rest")
        }
        enc.useResources(blases, usage: .read)
        for (k, d) in made.enumerated() {
            guard let accel = device.makeAccelerationStructure(size: sizes[k].accelerationStructureSize) else {
                throw RendererError.resourceCreation("acceleration structure (a plant's variant at rest)")
            }
            accel.label = "plantRest"
            enc.build(accelerationStructure: accel, descriptor: d, scratchBuffer: scratch, scratchBufferOffset: offsets[k])
            rest.append(accel)
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if compact { rest = try SceneBuffers.copyAndCompact(rest, device: device, queue: queue) }
    }

    /// The set a frame slot traces: its own, or the one of a still scene.
    func set(slot: Int) -> Int { min(slot, sets.count - 1) }

    /// The variant a plant of `assembly` named `id` traces when `fall` of the leaves are down.
    func variant(assembly: Int, id: UInt32, fall: Float) -> Int {
        if rigid[assembly] { return variantBase[assembly] }
        var v = Wind.bucket(id)
        if keeps[assembly] > 1 {
            let keep = Wind.keep(fall: fall, id: id)
            v += Wind.phases * Int((keep * Float(keeps[assembly] - 1)).rounded())
        }
        return variantBase[assembly] + v
    }
    func structure(set: Int, assembly: Int, id: UInt32, fall: Float) -> MTLAccelerationStructure {
        sets[set][variant(assembly: assembly, id: id, fall: fall)]
    }

    /// Plant and ground-cover descriptors of `slot`'s top-level structure in the wind (and the plants' variants for
    /// the season's `fall`, their voxels' levels for `view`: camera position, bias / pixel scale, as VoxelLOD's),
    /// written over what SceneBuffers wrote. True if a plant names another structure than it did.
    @discardableResult
    func writeDescriptors(slot: Int, into buffer: MTLBuffer, stride: Int, scene: Scene, wind: WindFrame, view: SIMD4<Float>? = nil) -> Bool {
        let base = buffer.contents(), set = set(slot: slot)
        let boxOptions = MTLAccelerationStructureInstanceOptions([.nonOpaque, .disableTriangleCulling]).rawValue
        let camera = view.map { SIMD3($0.x, $0.y, $0.z) }
        let instances = scene.instances, meshes = scene.meshes, variants = sets[set], options = instanceOptions
        // Beyond the sway's reach (in the wind, in a scene with variants at rest), a plant's limbs stand still.
        let reach = wind.wind.z > 0 && !rest.isEmpty ? wind.sway.w : 0, near = SIMD3(wind.sway.x, wind.sway.y, wind.sway.z)
        let variantTotal = Int32(variantCount)
        // What each instance's descriptor names (its variant, -1 - a voxel level, or none), in parts side by side: a
        // forest's thousands of plants every frame the wind blows.
        var choice = [Int32](repeating: .max, count: instances.count)
        let part = 1024
        choice.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: (instances.count + part - 1) / part) { k in
                for i in (k * part)..<min((k + 1) * part, instances.count) {
                    let inst = instances[i]
                    if inst.assembly >= 0, rigid[inst.assembly] {   // a building: still, never refitted
                        SceneBuffers.writeDescriptor(base + i * stride, transform: inst.transform, options: options, mask: inst.mask,
                                                     userID: UInt32(i), structure: variants[variantBase[inst.assembly]])
                    } else if inst.assembly >= 0 {
                        let id = UInt32(i), transform = Wind.plant(inst.transform, wind: wind.wind, time: wind.time, id: id)
                        var level: UInt8 = 0
                        if let voxels, let view, let camera {
                            let position = SIMD3(inst.transform.columns.3.x, inst.transform.columns.3.y, inst.transform.columns.3.z)
                            let scale = length(SIMD3(inst.transform.columns.0.x, inst.transform.columns.0.y, inst.transform.columns.0.z))
                            level = VoxelLOD.level(distance: distance(position, camera), size: voxels.gridRecords[inst.assembly].lo.w * scale,
                                                   view: view.w, jitter: VoxelLOD.jitter(position))
                        }
                        if level > 0, let voxels {
                            let box = voxels.boxes[VoxelGrids.levels * inst.assembly + Int(level) - 1]
                            SceneBuffers.writeDescriptor(base + i * stride, transform: transform, options: boxOptions, mask: Scene.maskVoxels,
                                                         userID: id, structure: box)
                            out[i] = -Int32(level)
                            continue
                        }
                        let v = variant(assembly: inst.assembly, id: id, fall: wind.leafFall)
                        let position = SIMD3(inst.transform.columns.3.x, inst.transform.columns.3.y, inst.transform.columns.3.z)
                        if reach > 0, distance(position, near) > reach * exp2(VoxelLOD.jitter(position)) {
                            let r = restBase[inst.assembly] + (v - variantBase[inst.assembly]) / Wind.phases
                            out[i] = variantTotal + Int32(r)
                            SceneBuffers.writeDescriptor(base + i * stride, transform: transform, options: options, mask: inst.mask,
                                                         userID: id, structure: rest[r])
                            continue
                        }
                        out[i] = Int32(v)
                        SceneBuffers.writeDescriptor(base + i * stride, transform: transform, options: options, mask: inst.mask,
                                                     userID: id, structure: variants[v])
                    } else if inst.mesh >= 0, meshes[inst.mesh].sways != 0 {
                        let m = Wind.cover(inst.transform, wind: wind.wind, time: wind.time)
                        var offset = 0
                        for column in 0..<4 {
                            for row in 0..<3 { (base + i * stride).storeBytes(of: m[column][row], toByteOffset: offset, as: Float.self); offset += 4 }
                        }
                    }
                }
            }
        }
        var usedHere = [Bool](repeating: false, count: variantCount)
        for c in choice where c >= 0 && c < variantTotal { usedHere[Int(c)] = true }
        used[set] = usedHere.indices.filter { usedHere[$0] }
        defer { chosen[set] = choice }
        return chosen[set] != choice
    }

    /// A plant's instance options: opaque unless the scene has leaf cards, which the queries' loop cuts out.
    var instanceOptions: UInt32 {
        MTLAccelerationStructureInstanceOptions(hasCards ? [.disableTriangleCulling] : [.opaque, .disableTriangleCulling]).rawValue
    }

    /// `slot`'s variants' descriptors (tests read what plantWindKernel wrote there), and what each one is: (its part,
    /// its phase bucket), or ~0 for a pad.
    func descriptors(slot: Int) -> MTLBuffer { descriptorBuffers[set(slot: slot)] }
    var workItems: [SIMD2<UInt32>] {
        Array(UnsafeBufferPointer(start: work.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: descriptorCount), count: descriptorCount))
    }

    /// Whether `slot`'s variants need posing this frame: in the wind while time runs, or back at rest after it.
    func needsPosing(slot: Int, wind: WindFrame) -> Bool { sets.count > 1 && posed[set(slot: slot)] != wind.poseKey }

    /// Poses `slot`'s variants' parts for this frame's wind (plantWindKernel), then has them refitted (`refit`).
    func encodeWind(_ enc: ComputePass, slot: Int, pipeline: MTLComputePipelineState, wind: WindFrame) {
        let set = set(slot: slot)
        posed[set] = wind.poseKey
        struct Params { var wind: SIMD4<Float>; var time: Float; var count: UInt32; var stride: UInt32; var pad: UInt32 = 0 }
        var p = Params(wind: wind.wind, time: wind.time, count: UInt32(descriptorCount), stride: UInt32(PlantTracing.descriptorStride / 4))
        enc.setComputePipelineState(pipeline)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.setBuffer(work, offset: 0, index: 1)
        enc.setBuffer(parts, offset: 0, index: 2)
        enc.setBuffer(descriptorBuffers[set], offset: 0, index: 3)
        enc.dispatchThreads(MTLSize(width: max(descriptorCount, 1), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }

    /// The refit of `slot`'s variants around their posed parts: the ones its plants name.
    struct Refit: PrimitiveWork4 {
        let structures: [MTLAccelerationStructure]
        let descriptors: [MTLInstanceAccelerationStructureDescriptor]
        let used: [Int]
        let blases: [[MTLAccelerationStructure]]
        let scratch: MTLBuffer
        let offsets: [Int]

        /// Metal 3: refits to an encoder (`METALRENDERER_PLANT_REFITS`). M1 Max: two make the moving forest 3% faster
        /// than one, three or more crash the driver; M4 Max: any number, no faster. (Metal 4 refits them side by side
        /// in the frame's encoder: `encode4`.)
        static let perEncoder = max(1, Int(ProcessInfo.processInfo.environment["METALRENDERER_PLANT_REFITS"] ?? "") ?? 2)
        var encoderCount: Int { (used.count + Refit.perEncoder - 1) / Refit.perEncoder }
        func encode(into enc: MTLAccelerationStructureCommandEncoder, part: Int) {
            for v in used[(part * Refit.perEncoder)..<min((part + 1) * Refit.perEncoder, used.count)] {
                enc.useResources(blases[v], usage: .read)
                enc.refit(sourceAccelerationStructure: structures[v], descriptor: descriptors[v], destinationAccelerationStructure: structures[v],
                          scratchBuffer: scratch, scratchBufferOffset: offsets[v])
            }
        }

        /// Metal 4: every refit in `enc`, with no barrier between them (each has its own scratch range, so the GPU may
        /// run them side by side). `keep` makes what they touch resident.
        @available(macOS 26.0, *)
        func encode4(into enc: MTL4ComputeCommandEncoder, keep: (MTLAllocation) -> Void) {
            keep(scratch)
            for v in used {
                let d3 = descriptors[v]
                guard let instances = d3.instanceDescriptorBuffer else { continue }
                keep(instances)
                keep(structures[v])
                blases[v].forEach(keep)
                let d = MTL4InstanceAccelerationStructureDescriptor()
                d.instanceDescriptorBuffer = MTL4BufferRange(bufferAddress: instances.gpuAddress + UInt64(d3.instanceDescriptorBufferOffset),
                                                             length: UInt64(d3.instanceCount * d3.instanceDescriptorStride))
                d.instanceDescriptorStride = d3.instanceDescriptorStride
                d.instanceCount = d3.instanceCount
                d.instanceDescriptorType = d3.instanceDescriptorType
                d.usage = d3.usage
                let end = v + 1 < offsets.count ? offsets[v + 1] : scratch.length
                enc.refit(sourceAccelerationStructure: structures[v], descriptor: d, destinationAccelerationStructure: structures[v],
                          scratchBuffer: MTL4BufferRange(bufferAddress: scratch.gpuAddress + UInt64(offsets[v]), length: UInt64(end - offsets[v])))
            }
        }
    }
    func refit(slot: Int) -> Refit {
        let set = set(slot: slot)
        return Refit(structures: sets[set], descriptors: variantDescriptors[set], used: used[set], blases: variantBlases, scratch: scratch,
                     offsets: scratchOffsets)
    }

    /// What `slot`'s ray queries read through the plants' variants and TraceScene, besides the meshes' structures (the
    /// scene declares those): the variants and the leafy meshes' prefixes.
    func resources(slot: Int) -> [MTLResource] {
        [parts, cutouts] + sets[set(slot: slot)] + rest + prefixes + (voxels.map { $0.buffers + $0.boxes } ?? [])
    }
    /// The structures `slot`'s top-level structure names (its build reads them).
    func structures(slot: Int) -> [MTLAccelerationStructure] { sets[set(slot: slot)] + rest + blases + (voxels?.boxes ?? []) }
}
