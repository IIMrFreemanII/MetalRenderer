import Foundation
import Metal
import simd

/// Matches `LumenMeshSDF` in Shaders/LumenSDF.metal: a mesh's distance field in the brick atlas, or its heights.
struct GPULumenMeshSDF {
    var lo: SIMD4<Float>        // bricks: xyz = the volume's first sample (mesh space), w = voxel;
                                // heights: x, z = the first sample, w = the cell
    var bricks: SIMD4<UInt32>   // bricks: xyz = bricks per axis, w = its first entry in the brick table;
                                // heights: x = samples a side; (x = 0: not baked)
    var info: SIMD4<Float>      // x = 1 if two-sided, y = its coarse grid's or heights' first value (a UInt32's bits),
                                // z = 1 for heights, w = their slope factor
}

/// Matches `LumenSDFInstance` in Shaders/LumenSDF.metal: an instance traced through its mesh's distance field.
struct GPULumenSDFInstance {
    var lo: SIMD4<Float>        // world box: xyz, w = the instance's smallest scale (world units per mesh unit)
    var hi: SIMD4<Float>        // xyz, w = the mesh's field (as a float's bits)
    var id: UInt32              // the instance's id (its card table's row)
    var pad = SIMD3<UInt32>(0, 0, 0)
}

/// Lumen's scene for one Scene: a distance field for each traced kind of geometry (MeshSDFBuilder): the meshes (the
/// scene's arrays or borrowed ones), the virtual meshes (a coarse cut of their clusters) and the plants' assemblies
/// (all their parts, in plant space), indexed as the instances' `meshIndex`. Flat ones (terrain, grounds, quads) are
/// heights. Baked in the background (and cached), their bricks in one 3D atlas; each frame, the instances that are
/// traced through them.
final class LumenScene {
    /// METALRENDERER_LUMEN_LOG=1: a line per field as it lands.
    static let log = ProcessInfo.processInfo.environment["METALRENDERER_LUMEN_LOG"] == "1"
    static let atlasBricks = 32                    // bricks a row and a column of a layer
    static let cacheVersion = 5                    // 2: voxels by the largest side; 3: the coarse grid; 4: steep heights;
                                                   // 5: open surfaces of closed meshes

    private let device: MTLDevice
    private(set) var atlas: MTLTexture             // r8Snorm, 8³ texels a brick
    private var usedBricks = 0
    private var meshRecords: [GPULumenMeshSDF]     // per mesh of the scene
    private var brickTable: [UInt32] = []
    private var coarseData: [Float] = []           // the meshes' coarse grids (MeshSDF.coarse), one after another
    private(set) var baked = 0
    let toBake: Int

    private let lock = NSLock()
    enum Baked {
        case bricks(MeshSDF)
        case heights(Heightfield)
    }
    private var inbox: [(field: Int, baked: Baked?)] = []
    private var fieldBounds: [AABB]                // per field, in its own space (where it is not empty)
    private var cancelled = false
    private static let queue = DispatchQueue(label: "MetalRenderer.lumenBake", qos: .utility)

    // Per frame slot: the meshes' records, the brick table, the traced instances.
    private var recordBuffers: [MTLBuffer]
    private var tableBuffers: [MTLBuffer]
    private var coarseBuffers: [MTLBuffer]
    private var instanceBuffers: [MTLBuffer]
    private var written: [Int]                     // the records' generation each slot holds
    private var generation = 0
    private(set) var instanceCount = 0
    /// This frame's update: the boxes of the traced instances that moved (last frame's and this one's), and whether
    /// fields landed since the last (the global field composes everything again).
    private(set) var movedBoxes: [AABB] = []
    private(set) var fieldsChanged = false
    private var lastGeneration = -1

    var isBaking: Bool { baked < toBake }

    /// A field's index: as the instance's `meshIndex` (Scene.writeInstanceData).
    static func field(of inst: Scene.Instance, in scene: Scene) -> Int {
        inst.mesh >= 0 ? inst.mesh : inst.assembly >= 0 ? scene.meshes.count + scene.virtualMeshes.count + inst.assembly
            : scene.meshes.count + inst.virtualMesh
    }

    /// The fields `fields` of `scene` are baked in the background, in that order.
    /// `source`: what the bakes read, if it was kept before the scene let go of its arrays (the open world's).
    init(device: MTLDevice, scene: Scene, fields: [Int], source kept: Source? = nil, frameSlots: Int) throws {
        self.device = device
        let fieldCount = scene.meshes.count + scene.virtualMeshes.count + scene.assemblies.count
        meshRecords = Array(repeating: GPULumenMeshSDF(lo: .zero, bricks: .zero, info: .zero), count: fieldCount)
        fieldBounds = Array(repeating: AABB(), count: fieldCount)
        atlas = try LumenScene.makeAtlas(device: device, layers: 4)
        func buffers(_ label: String) throws -> [MTLBuffer] {
            try (0..<frameSlots).map { i in
                guard let b = device.makeBuffer(length: 4096, options: .storageModeShared) else { throw RendererError.resourceCreation(label) }
                b.label = "\(label) \(i)"
                return b
            }
        }
        recordBuffers = try buffers("lumen mesh sdfs")
        tableBuffers = try buffers("lumen sdf bricks")
        coarseBuffers = try buffers("lumen sdf coarse")
        instanceBuffers = try buffers("lumen sdf instances")
        written = Array(repeating: -1, count: frameSlots)
        toBake = fields.count

        // The job keeps what it reads (copy on write: the scene's arrays stay as they are).
        let source = kept ?? Source(scene: scene)
        LumenScene.queue.async { [weak self] in
            for f in fields {
                guard let self, !self.isCancelled else { return }
                let baked = source.geometry(field: f).flatMap { LumenScene.bake(positions: $0.positions, indices: $0.indices) }
                self.lock.lock()
                self.inbox.append((f, baked))
                self.lock.unlock()
            }
        }
    }

    /// What the bakes read of a scene: its arrays, borrowed meshes, virtual meshes and assemblies.
    struct Source {
        let positions: [SIMD3<Float>]
        let indices: [UInt32]
        let meshes: [GPUMesh]
        let borrowed: [Int: Scene.BorrowedMesh]   // by mesh
        let virtualMeshes: [VirtualMesh]
        let assemblies: [Scene.Assembly]

        init(scene: Scene) {
            positions = scene.positions
            indices = scene.indices
            meshes = scene.meshes
            borrowed = Dictionary(scene.borrowed.map { ($0.mesh, $0) }, uniquingKeysWith: { a, _ in a })
            virtualMeshes = scene.virtualMeshes
            assemblies = scene.assemblies
        }

        /// A mesh's triangles on their own: its vertices in the order its triangles first use them.
        func mesh(_ m: Int) -> (positions: [SIMD3<Float>], indices: [UInt32])? {
            if let b = borrowed[m] { return (b.positions.array, b.indices.array) }
            let mesh = meshes[m]
            let first = Int(mesh.firstIndex), end = first + Int(mesh.indexCount)
            guard end <= indices.count, mesh.indexCount > 0 else { return nil }
            var remap: [UInt32: UInt32] = [:]
            var local: [SIMD3<Float>] = [], tris: [UInt32] = []
            tris.reserveCapacity(end - first)
            for i in indices[first..<end] {
                guard Int(i) < positions.count else { return nil }
                if let j = remap[i] { tris.append(j); continue }
                let j = UInt32(local.count)
                remap[i] = j
                local.append(positions[Int(i)])
                tris.append(j)
            }
            return (local, tris)
        }

        /// Field `f`'s triangles in its own space.
        func geometry(field f: Int) -> (positions: [SIMD3<Float>], indices: [UInt32])? {
            if f < meshes.count { return mesh(f) }
            if f < meshes.count + virtualMeshes.count { return LumenScene.coarseCut(virtualMeshes[f - meshes.count]) }
            // An assembly: all its parts, placed (at rest: the wind is not in the field).
            var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
            for part in assemblies[f - meshes.count - virtualMeshes.count].parts {
                guard let m = mesh(part.mesh) else { continue }
                let base = UInt32(positions.count)
                positions += m.positions.map { p in let q = part.transform * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z) }
                indices += m.indices.map { $0 + base }
            }
            return indices.isEmpty ? nil : (positions, indices)
        }
    }

    /// A virtual mesh as triangles: the cut of its cluster DAG at about half the voxel its field will have (a cluster
    /// whose own error is within it and its parents' not), decoded from its pages (VirtualGeometryBuilder.clusterBlob).
    static func coarseCut(_ vm: VirtualMesh) -> (positions: [SIMD3<Float>], indices: [UInt32])? {
        let tolerance = MeshSDFBuilder.voxel(for: vm.bounds) / 2
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        vm.pageData.withUnsafeBytes { raw in
            for c in vm.clusters where c.lo.w <= tolerance && c.hi.w > tolerance {
                let at = Int(vm.groups[Int(c.group)].pageOffset) + Int(c.pageOffset)
                guard at + 32 <= raw.count else { continue }
                func word(_ i: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at + 4 * i, as: UInt32.self)) }
                let vertexCount = word(1), triangleCount = word(2), posOffset = word(5), triOffset = word(7)
                guard at + triOffset + 4 * triangleCount <= raw.count else { continue }
                let base = UInt32(positions.count)
                for v in 0..<vertexCount {
                    let p = raw.loadUnaligned(fromByteOffset: at + posOffset + 16 * v, as: SIMD4<Float>.self)
                    positions.append(SIMD3(p.x, p.y, p.z))
                }
                for t in 0..<triangleCount {
                    let packed = raw.loadUnaligned(fromByteOffset: at + triOffset + 4 * t, as: UInt32.self)
                    indices += [base + (packed & 0xFF), base + (packed >> 8 & 0xFF), base + (packed >> 16 & 0xFF)]
                }
            }
        }
        return indices.isEmpty ? nil : (positions, indices)
    }

    deinit { cancel() }
    /// Waits for the bakes (benchmarks: their pictures don't depend on how long a bake takes).
    func waitForBakes() { LumenScene.queue.sync {} }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    var megabytes: Int { (atlas.width * atlas.height * atlas.depth + brickTable.count * 4) >> 20 }

    func records(slot: Int) -> MTLBuffer { recordBuffers[slot] }
    func table(slot: Int) -> MTLBuffer { tableBuffers[slot] }
    func coarse(slot: Int) -> MTLBuffer { coarseBuffers[slot] }
    func instances(slot: Int) -> MTLBuffer { instanceBuffers[slot] }

    private static func makeAtlas(device: MTLDevice, layers: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r8Snorm
        d.width = atlasBricks * MeshSDF.brickSide
        d.height = atlasBricks * MeshSDF.brickSide
        d.depth = layers * MeshSDF.brickSide
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("lumen sdf atlas") }
        t.label = "lumen sdf atlas"
        return t
    }

    /// A field: from the cache if it was baked before (named by its triangles), else baked and stored. Flat meshes
    /// are heights.
    static func bake(positions local: [SIMD3<Float>], indices tris: [UInt32]) -> Baked? {
        var bounds = AABB()
        for p in local { bounds.grow(p) }
        var hasher = GeneratedCache.Hasher()
        hasher.add(local)
        hasher.add(tris)
        let geometry = hasher.name()
        if MeshSDFBuilder.isHeightfield(bounds) {
            let name = "hfld-\(geometry).sect", key = "hfld v\(cacheVersion)"
            let head = SectionFile.id("head"), heights = SectionFile.id("hght")
            if let file = GeneratedCache.load(name, key: key), let h: [Float] = file.array(head), h.count == 11,
               let values: [Float] = file.array(heights), values.count == Int(h[3]) * Int(h[3]) {
                return .heights(Heightfield(lo: SIMD2(h[0], h[1]), cell: h[2], side: Int(h[3]), heights: values, slope: h[4],
                                            bounds: AABB(lo: SIMD3(h[5], h[6], h[7]), hi: SIMD3(h[8], h[9], h[10]))))
            }
            if let field = MeshSDFBuilder.heightfield(positions: local, indices: tris) {
            var writer = SectionFile.Writer()
            writer.add(head, [field.lo.x, field.lo.y, field.cell, Float(field.side), field.slope, field.bounds.lo.x,
                              field.bounds.lo.y, field.bounds.lo.z, field.bounds.hi.x, field.bounds.hi.y, field.bounds.hi.z])
            writer.add(heights, field.heights)
            GeneratedCache.store(name, key: key, writer)
            return .heights(field)
            }
            // Too steep for heights (a stored miss is not kept: the bricks' file is what is read next time).
        }
        let name = "msdf-\(geometry).sect", key = "msdf v\(cacheVersion)"
        let head = SectionFile.id("head"), table = SectionFile.id("tabl"), data = SectionFile.id("data")
        let coarse = SectionFile.id("crse")
        if let file = GeneratedCache.load(name, key: key), let h: [Float] = file.array(head), h.count == 8,
           let t: [UInt32] = file.array(table), let d: [Int8] = file.array(data), let c: [Float] = file.array(coarse),
           c.count == MeshSDF.coarseSide * MeshSDF.coarseSide * MeshSDF.coarseSide {
            let bricks = SIMD3<Int>(Int(h[4]), Int(h[5]), Int(h[6]))
            if t.count == bricks.x * bricks.y * bricks.z {
                return .bricks(MeshSDF(lo: SIMD3(h[0], h[1], h[2]), voxel: h[3], bricks: bricks, table: t, data: d,
                                       twoSided: h[7] != 0, coarse: c))
            }
        }
        guard let sdf = MeshSDFBuilder.build(positions: local, indices: tris) else { return nil }
        var writer = SectionFile.Writer()
        writer.add(head, [sdf.lo.x, sdf.lo.y, sdf.lo.z, sdf.voxel, Float(sdf.bricks.x), Float(sdf.bricks.y), Float(sdf.bricks.z),
                          sdf.twoSided ? 1 : 0])
        writer.add(table, sdf.table)
        writer.add(data, sdf.data)
        writer.add(coarse, sdf.coarse)
        GeneratedCache.store(name, key: key, writer)
        return .bricks(sdf)
    }

    /// Takes in what the baker finished: its bricks into the atlas (grown if full), its table, its record.
    private func receive() {
        lock.lock()
        let done = inbox
        inbox.removeAll()
        lock.unlock()
        guard !done.isEmpty else { return }
        for (m, result) in done {
            baked += 1
            if LumenScene.log {
                switch result {
                case nil: print("Lumen field \(m): none")
                case .heights(let f)?: print("Lumen field \(m): heights \(f.side)², cell \(f.cell), slope \(f.slope), \(f.bounds.lo) ... \(f.bounds.hi)")
                case .bricks(let f)?: print("Lumen field \(m): bricks \(f.bricks), voxel \(f.voxel), two-sided \(f.twoSided), \(f.lo) ... \(f.hi)")
                }
            }
            switch result {
            case nil: continue
            case .heights(let field)?:
                // Heights: in the coarse buffer.
                let first = UInt32(coarseData.count)
                coarseData += field.heights
                meshRecords[m] = GPULumenMeshSDF(lo: SIMD4(field.lo.x, 0, field.lo.y, field.cell),
                                                 bricks: SIMD4(UInt32(field.side), UInt32(field.side), 0, 0),
                                                 info: SIMD4(0, Float(bitPattern: first), 1, field.slope))
                // Its box: a few cells below (solid) and above (the hits' reach), not the flat mesh's own.
                var box = field.bounds
                let pad = max(4 * field.cell, 0.02 * (box.hi - box.lo).max())
                box.lo.y -= pad
                box.hi.y += pad
                fieldBounds[m] = box
                continue
            case .bricks(let sdf)?:
                guard sdf.bricks.x > 0 else { continue }
                receive(sdf, field: m)
            }
        }
        generation += 1
    }

    private func receive(_ sdf: MeshSDF, field m: Int) {
        let side = MeshSDF.brickSide, perBrick = side * side * side, perLayer = LumenScene.atlasBricks * LumenScene.atlasBricks
        do {
            let needed = usedBricks + sdf.storedBricks
            let layers = (needed + perLayer - 1) / perLayer
            if layers * side > atlas.depth, let grown = try? LumenScene.makeAtlas(device: device, layers: max(layers, atlas.depth / side * 2)) {
                // Copy what is there (in-flight frames keep the old one).
                let region = MTLRegionMake3D(0, 0, 0, atlas.width, atlas.height, atlas.depth)
                var bytes = [Int8](repeating: 0, count: atlas.width * atlas.height * atlas.depth)
                bytes.withUnsafeMutableBytes {
                    atlas.getBytes($0.baseAddress!, bytesPerRow: atlas.width, bytesPerImage: atlas.width * atlas.height, from: region, mipmapLevel: 0, slice: 0)
                }
                bytes.withUnsafeBytes {
                    grown.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!, bytesPerRow: atlas.width,
                                  bytesPerImage: atlas.width * atlas.height)
                }
                atlas = grown
            }
            guard needed <= (atlas.depth / side) * perLayer else {   // the atlas could not grow: not traced
                if LumenScene.log { print("Lumen field \(m): the atlas is full (\(usedBricks) bricks, \(sdf.storedBricks) more)") }
                return
            }
            sdf.data.withUnsafeBytes { raw in
                for b in 0..<sdf.storedBricks {
                    let slot = usedBricks + b
                    let origin = MTLOrigin(x: slot % LumenScene.atlasBricks * side, y: slot / LumenScene.atlasBricks % LumenScene.atlasBricks * side,
                                           z: slot / perLayer * side)
                    atlas.replace(region: MTLRegion(origin: origin, size: MTLSize(width: side, height: side, depth: side)), mipmapLevel: 0,
                                  slice: 0, withBytes: raw.baseAddress! + b * perBrick, bytesPerRow: side, bytesPerImage: side * side)
                }
            }
            let first = brickTable.count
            brickTable += sdf.table.map { $0 >= MeshSDF.emptyInside ? $0 : $0 + UInt32(usedBricks) }
            usedBricks += sdf.storedBricks
            let coarseFirst = UInt32(coarseData.count)
            coarseData += sdf.coarse
            meshRecords[m] = GPULumenMeshSDF(lo: SIMD4(sdf.lo, sdf.voxel),
                                             bricks: SIMD4(UInt32(sdf.bricks.x), UInt32(sdf.bricks.y), UInt32(sdf.bricks.z), UInt32(first)),
                                             info: SIMD4(sdf.twoSided ? 1 : 0, Float(bitPattern: coarseFirst), 0, 0))
            fieldBounds[m] = AABB(lo: sdf.lo, hi: sdf.hi)
        }
    }

    /// This frame: takes in finished bakes, and writes slot `slot`'s records, table (when they changed) and the
    /// instances traced through a baked field: `eligible` ones of `scene` whose mesh has one.
    func update(scene: Scene, eligible: (Scene.Instance) -> Bool, slot: Int) {
        receive()
        func write<T>(_ values: [T], to buffers: inout [MTLBuffer]) {
            let bytes = max(values.count * MemoryLayout<T>.stride, 16)
            if buffers[slot].length < bytes, let b = device.makeBuffer(length: bytes * 2, options: .storageModeShared) {
                b.label = buffers[slot].label
                buffers[slot] = b
            }
            guard buffers[slot].length >= bytes else { return }
            values.withUnsafeBytes { if let base = $0.baseAddress { buffers[slot].contents().copyMemory(from: base, byteCount: $0.count) } }
        }
        if written[slot] != generation {
            write(meshRecords, to: &recordBuffers)
            write(brickTable, to: &tableBuffers)
            write(coarseData, to: &coarseBuffers)
            written[slot] = generation
        }
        fieldsChanged = generation != lastGeneration
        lastGeneration = generation
        movedBoxes.removeAll(keepingCapacity: true)
        var list: [GPULumenSDFInstance] = []
        for (i, inst) in scene.instances.enumerated() where eligible(inst) {
            let field = LumenScene.field(of: inst, in: scene)
            guard field < meshRecords.count, meshRecords[field].bricks.x > 0 else { continue }
            let local = fieldBounds[field]
            let box = local.transformed(inst.transform)
            if inst.transform != inst.prevTransform { movedBoxes += [box, local.transformed(inst.prevTransform)] }
            let m = inst.transform
            let scale = min(length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)), length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                            length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
            list.append(GPULumenSDFInstance(lo: SIMD4(box.lo, scale), hi: SIMD4(box.hi, Float(bitPattern: UInt32(field))), id: UInt32(i)))
        }
        instanceCount = list.count
        write(list, to: &instanceBuffers)
    }
}
