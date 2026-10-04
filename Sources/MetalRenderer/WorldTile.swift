import Foundation
import simd

/// One tile of the open world (World.swift) at one level of detail: everything the world has in a 256 m square, made
/// from the seed and the tile's place alone, in metres from the tile's corner (y is the world's height). A tile is
/// kept as a file of its arrays (SectionFile), so it is made once.
///
///   The ground     a grid of cells (1, 4 or 16 m by level) with a skirt down its sides, which hides the step to a
///                  neighbour of another level; each cell of one of the world's ground materials.
///   The city       the blocks whose middle is in the tile: sidewalks, street lamps and trees, and the buildings
///                  (BuildingGenerator): whole at level 0, without their glass at level 1, a box each at level 2.
///   The trees      as placements: which plant of the world's library stands where.
///
/// Its meshes are chunks: a chunk's triangles name their materials by a byte, an index into the chunk's own list
/// (a city tile has more than 256 materials: it is several chunks). Window glass is in chunks of its own.
struct WorldTile {
    struct Chunk {
        var positions: Stored<SIMD3<Float>>
        var normals: Stored<SIMD3<Float>>
        var uvs: Stored<SIMD2<Float>>
        var indices: Stored<UInt32>             // into this chunk's vertices
        var triangleMaterials: Stored<UInt8>    // into `materials`
        /// Generated surfaces' textures are named by kind (World.texture) in `textures.x`.
        var materials: [GPUMaterial]
        var glass: Bool
        var bounds: AABB

        var triangles: Int { indices.count / 3 }
    }

    /// A chunk being put together.
    private struct Draft {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var triangleMaterials: [UInt8] = []
        var materials: [GPUMaterial] = []
    }

    let x: Int, z: Int, level: Int
    var chunks: [Chunk] = []
    var trees: [World.Placement] = []

    /// From the world's origin to the tile's corner.
    static func origin(_ x: Int, _ z: Int) -> SIMD2<Double> { SIMD2(Double(x), Double(z)) * Double(World.tileSize) }
    var triangles: Int { chunks.reduce(0) { $0 + $1.triangles } }

    // MARK: - Putting meshes together

    /// Collects meshes into chunks of at most 256 materials.
    private struct Assembler {
        let glass: Bool
        private var done: [Draft] = []
        private var open = Draft()
        private var slots: [Data: UInt8] = [:]

        init(glass: Bool) { self.glass = glass }

        /// The open chunk's index for `material`, starting another chunk if this one's list is full.
        mutating func slot(_ material: GPUMaterial) -> UInt8 {
            let key = withUnsafeBytes(of: material) { Data($0) }
            if let known = slots[key] { return known }
            if open.materials.count == 256 { close() }
            open.materials.append(material)
            slots[key] = UInt8(open.materials.count - 1)
            return UInt8(open.materials.count - 1)
        }

        private mutating func close() {
            if !open.indices.isEmpty { done.append(open) }
            open = Draft()
            slots = [:]
        }

        /// Adds `mesh`, moved by `transform` (rigid).
        mutating func add(_ mesh: MeshBuilder, _ material: GPUMaterial, _ transform: float4x4) {
            guard !mesh.isEmpty else { return }
            let slot = slot(material), base = UInt32(open.positions.count)
            let c = transform.columns
            let x = SIMD3(c.0.x, c.0.y, c.0.z), y = SIMD3(c.1.x, c.1.y, c.1.z), z = SIMD3(c.2.x, c.2.y, c.2.z), t = SIMD3(c.3.x, c.3.y, c.3.z)
            open.positions.reserveCapacity(open.positions.count + mesh.positions.count)
            open.normals.reserveCapacity(open.normals.count + mesh.positions.count)
            for i in mesh.positions.indices {
                let p = mesh.positions[i], n = mesh.normals[i]
                open.positions.append(x * p.x + y * p.y + z * p.z + t)
                open.normals.append(x * n.x + y * n.y + z * n.z)
            }
            open.uvs += mesh.uvs
            open.indices += mesh.indices.map { $0 + base }
            open.triangleMaterials += [UInt8](repeating: slot, count: mesh.triangleCount)
        }

        /// The open chunk, to add vertices and triangles to by hand (the ground).
        mutating func withOpen(_ body: (inout Draft) -> Void) { body(&open) }

        mutating func finish() -> [Chunk] {
            close()
            return done.map { draft in
                var box = AABB()
                draft.positions.withUnsafeBufferPointer { for p in $0 { box.grow(p) } }
                return Chunk(positions: .made(draft.positions), normals: .made(draft.normals), uvs: .made(draft.uvs),
                             indices: .made(draft.indices), triangleMaterials: .made(draft.triangleMaterials),
                             materials: draft.materials, glass: glass, bounds: box)
            }
        }
    }

    private static func material(_ m: SurfaceMaterial) -> GPUMaterial {
        if m.glass { return GPUMaterial(albedo: SIMD4(m.color, 0), emission: SIMD4(.zero, 0), params: SIMD4(0, 1, 0, 0)) }
        var gpu = GPUMaterial(albedo: SIMD4(m.color, m.metallic), emission: SIMD4(m.emission, m.roughness), params: SIMD4(m.specular ? 1 : 0, 1, 0, 0))
        if let kind = m.surface { gpu.textures.x = World.texture(kind) }
        return gpu
    }

    // MARK: - Making a tile

    static func build(_ world: World, x: Int, z: Int, level: Int, flora: World.Flora) -> WorldTile {
        var tile = WorldTile(x: x, z: z, level: level)
        let origin = WorldTile.origin(x, z), side = Double(World.tileSize)
        var opaque = Assembler(glass: false), glass = Assembler(glass: true)
        ground(world, origin: origin, level: level, into: &opaque)
        if let (city, blocks) = world.blocks(x0: origin.x, z0: origin.y, side: side) {
            for block in blocks { add(block, of: city, level: level, opaque: &opaque, glass: &glass) }
        }
        tile.chunks = opaque.finish() + glass.finish()
        tile.trees = world.trees(x0: origin.x, z0: origin.y, side: side, flora: flora)
        return tile
    }

    /// The ground: the grid's cells, then a skirt down each of its four sides.
    private static func ground(_ world: World, origin: SIMD2<Double>, level: Int, into assembler: inout Assembler) {
        let cell = World.cellSize(level), n = Int(World.tileSize / cell)
        let city = world.city(near: origin.x + Double(World.tileSize) / 2, origin.y + Double(World.tileSize) / 2)
        // Heights on the grid and one ring around it: a vertex's normal is from its neighbours, the neighbouring
        // tile's among them, so the two tiles' normals along their shared side are the same.
        let m = n + 3
        var heights = [Float](repeating: 0, count: m * m)
        heights.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: m) { j in   // a row each
                for i in 0..<m {
                    out[j * m + i] = world.height(origin.x + Double(Float(i - 1) * cell), origin.y + Double(Float(j - 1) * cell), city: city)
                }
            }
        }
        func h(_ i: Int, _ j: Int) -> Float { heights[(j + 1) * m + i + 1] }
        // Every ground material, in the world's order: a cell's material index is then the world's.
        for material in World.groundMaterials { _ = assembler.slot(material) }
        let scale = 1 / SurfaceKind.asphalt.tile
        assembler.withOpen { chunk in
            let base = UInt32(chunk.positions.count)
            precondition(base == 0, "the ground is a tile's first mesh")
            for j in 0...n {
                for i in 0...n {
                    let p = SIMD3(Float(i) * cell, h(i, j), Float(j) * cell)
                    chunk.positions.append(p)
                    chunk.normals.append(normalize(SIMD3(h(i - 1, j) - h(i + 1, j), 2 * cell, h(i, j - 1) - h(i, j + 1))))
                    chunk.uvs.append(SIMD2(p.x, p.z) * scale)
                }
            }
            var kinds = [UInt8](repeating: 0, count: n * n)
            for j in 0..<n {
                for i in 0..<n {
                    let a = UInt32(j * (n + 1) + i), b = a + 1, c = a + UInt32(n + 1), d = c + 1
                    chunk.indices += [a, d, b, a, c, d]
                    let dx = (h(i + 1, j) + h(i + 1, j + 1) - h(i, j) - h(i, j + 1)) / (2 * cell)
                    let dz = (h(i, j + 1) + h(i + 1, j + 1) - h(i, j) - h(i + 1, j)) / (2 * cell)
                    let kind = UInt8(world.ground(origin.x + Double((Float(i) + 0.5) * cell), origin.y + Double((Float(j) + 0.5) * cell),
                                                  up: 1 / (1 + dx * dx + dz * dz).squareRoot(), city: city))
                    kinds[j * n + i] = kind
                    chunk.triangleMaterials += [kind, kind]
                }
            }
            // The skirt: under each side, as deep as a coarser neighbour's ground can lie below this one's.
            let drop = 2 * cell + 2
            func skirt(_ count: Int, vertex: (Int) -> Int, kind: (Int) -> UInt8) {
                let first = UInt32(chunk.positions.count)
                for k in 0...count {
                    let v = vertex(k)
                    chunk.positions.append(chunk.positions[v] - SIMD3(0, drop, 0))
                    chunk.normals.append(chunk.normals[v])
                    chunk.uvs.append(chunk.uvs[v])
                }
                for k in 0..<count {
                    let a = UInt32(vertex(k)), b = UInt32(vertex(k + 1)), c = first + UInt32(k), d = c + 1
                    chunk.indices += [a, b, d, a, d, c]
                    chunk.triangleMaterials += [kind(k), kind(k)]
                }
            }
            skirt(n, vertex: { $0 }, kind: { kinds[$0] })
            skirt(n, vertex: { n * (n + 1) + $0 }, kind: { kinds[(n - 1) * n + $0] })
            skirt(n, vertex: { $0 * (n + 1) }, kind: { kinds[$0 * n] })
            skirt(n, vertex: { $0 * (n + 1) + n }, kind: { kinds[$0 * n + n - 1] })
        }
    }

    /// A block of a city: its sidewalk and what stands on it.
    private static func add(_ block: World.Block, of city: World.City, level: Int, opaque: inout Assembler, glass: inout Assembler) {
        let plan = block.plan
        let place = translate([block.origin.x, city.level, block.origin.y])
        func builder(_ m: SurfaceMaterial) -> MeshBuilder { MeshBuilder(uvScale: m.uvScale) }
        let paving = SurfaceMaterial(color: [0.52, 0.5, 0.47], surface: .paving)
        var sidewalks = builder(paving)
        let r = plan.blocks[0].rect
        sidewalks.box([r.lo.x, 0, r.lo.y], [r.hi.x, 0.15, r.hi.y], faces: [.sides, .top])
        opaque.add(sidewalks, material(paving), place)
        if plan.blocks[0].park {
            let grass = SurfaceMaterial(color: [0.2, 0.34, 0.12])
            var lawn = builder(grass)
            let l = r.inset(CityPlan.sidewalk)
            lawn.box([l.lo.x, 0.15, l.lo.y], [l.hi.x, 0.22, l.hi.y], faces: [.sides, .top])
            opaque.add(lawn, material(grass), place)
        }
        if level == 0 {
            // Street lamps and the street's trees, as the City scene's.
            let iron = SurfaceMaterial(color: [0.07, 0.075, 0.08])
            var posts = builder(iron)
            for lamp in plan.lamps {
                let p = SIMD3<Float>(lamp.position.x, 0.15, lamp.position.y), out = SIMD3<Float>(lamp.toRoad.x, 0, lamp.toRoad.y)
                let across = SIMD3<Float>(-out.z, 0, out.x)
                posts.cylinder(p, radius: 0.08, topRadius: 0.05, height: 6.2, segments: 8)
                let a = p + [0, 6.1, 0], b = a + out * 1.6
                posts.box(simd_min(a - across * 0.04, b + across * 0.04) - [0, 0.04, 0], simd_max(a - across * 0.04, b + across * 0.04) + [0, 0.04, 0])
                let c = b - out * 0.35
                let lo = simd_min(c - across * 0.14 - out * 0.3, c + across * 0.14 + out * 0.3)
                let hi = simd_max(c - across * 0.14 - out * 0.3, c + across * 0.14 + out * 0.3)
                posts.box(lo - [0, 0.14, 0], hi - [0, 0.04, 0])
            }
            opaque.add(posts, material(iron), place)
        }
        if level <= 1 {
            let bark = SurfaceMaterial(color: [0.25, 0.18, 0.12]), leaves = SurfaceMaterial(color: [0.12, 0.26, 0.08])
            var trunks = builder(bark), crowns = builder(leaves)
            for tree in plan.trees {
                let p = SIMD3<Float>(tree.x, 0.15, tree.y), size = tree.z
                trunks.cylinder(p, radius: 0.16 * size, topRadius: 0.1 * size, height: 2.6 * size, segments: 6, cap: false)
                crowns.ball(p + [0, 3.9 * size, 0], radius: SIMD3(1.7, 1.9, 1.7) * size, subdivisions: level == 0 ? 1 : 0)
            }
            opaque.add(trunks, material(bark), place)
            opaque.add(crowns, material(leaves), place)
        }
        // The buildings, each from its lot's own seed, in the lots' order.
        let specs = plan.lots.map { BuildingSpec(lot: $0, city: plan.settings, night: false) }
        var built = [Building?](repeating: nil, count: specs.count)
        built.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: specs.count) { i in out[i] = BuildingGenerator.generate(specs[i]) }
        }
        for (i, building) in built.enumerated() {
            guard let building else { continue }
            let transform = place * plan.lots[i].transform
            if level == 2 {
                // What is left of it at the edge of sight: its box, in its walls' and its roof's colours.
                var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
                for part in building.parts where !part.material.glass {
                    let b = part.mesh.bounds
                    lo = simd_min(lo, b.lo)
                    hi = simd_max(hi, b.hi)
                }
                guard lo.x <= hi.x, let wall = building.parts.first(where: { $0.slot == .wall }) ?? building.parts.first else { continue }
                let roof = building.parts.first { $0.slot == .roof } ?? wall
                var walls = builder(wall.material), top = builder(roof.material)
                walls.box(lo, hi, faces: .sides)
                top.floor(x0: lo.x, x1: hi.x, z0: lo.z, z1: hi.z, y: hi.y)
                opaque.add(walls, material(wall.material), transform)
                opaque.add(top, material(roof.material), transform)
                continue
            }
            for part in building.parts {
                if part.material.glass {
                    if level == 0 { glass.add(part.mesh, material(part.material), transform) }
                } else {
                    opaque.add(part.mesh, material(part.material), transform)
                }
            }
        }
    }

    // MARK: - The tile's file

    /// A chunk in the file: where its arrays are among the tile's (MSL has no need of it: the renderer reads it).
    private struct ChunkRecord {
        var firstVertex: UInt32, vertexCount: UInt32, firstIndex: UInt32, indexCount: UInt32
        var firstMaterial: UInt32, materialCount: UInt32, glass: UInt32, pad: UInt32 = 0
        var lo: SIMD4<Float>, hi: SIMD4<Float>
    }
    private enum Section {
        static let chunks = SectionFile.id("chnk"), positions = SectionFile.id("posi"), normals = SectionFile.id("norm")
        static let uvs = SectionFile.id("uvco"), indices = SectionFile.id("indx"), triangleMaterials = SectionFile.id("tmat")
        static let materials = SectionFile.id("matl"), trees = SectionFile.id("tree")
    }

    /// The tile's file: one folder to a world and its settings, one below it to a level.
    static func url(_ world: World, x: Int, z: Int, level: Int) -> URL {
        GeneratedCache.folder.appendingPathComponent("world-\(world.seed)-v\(World.version)").appendingPathComponent("\(level)")
            .appendingPathComponent("\(x)_\(z).tile")
    }

    /// What the file was made for: the world's settings and the plants' library too.
    static func key(_ world: World, x: Int, z: Int, level: Int) -> String {
        "tile v\(World.version) plants v\(Foliage.version) seed \(world.seed) trees \(world.treeDensity) under \(world.undergrowth) "
            + "cities \(world.cityShare) at \(x) \(z) level \(level)"
    }

    func write(to url: URL, key: String) throws {
        var records: [ChunkRecord] = []
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        var triangleMaterials: [UInt8] = [], materials: [GPUMaterial] = []
        for chunk in chunks {
            records.append(ChunkRecord(firstVertex: UInt32(positions.count), vertexCount: UInt32(chunk.positions.count),
                                       firstIndex: UInt32(indices.count), indexCount: UInt32(chunk.indices.count),
                                       firstMaterial: UInt32(materials.count), materialCount: UInt32(chunk.materials.count),
                                       glass: chunk.glass ? 1 : 0, lo: SIMD4(chunk.bounds.lo, 0), hi: SIMD4(chunk.bounds.hi, 0)))
            chunk.positions.withUnsafeBufferPointer { positions.append(contentsOf: $0) }
            chunk.normals.withUnsafeBufferPointer { normals.append(contentsOf: $0) }
            chunk.uvs.withUnsafeBufferPointer { uvs.append(contentsOf: $0) }
            chunk.indices.withUnsafeBufferPointer { indices.append(contentsOf: $0) }
            chunk.triangleMaterials.withUnsafeBufferPointer { triangleMaterials.append(contentsOf: $0) }
            materials += chunk.materials
        }
        var writer = SectionFile.Writer()
        writer.add(Section.chunks, records)
        writer.add(Section.positions, positions)
        writer.add(Section.normals, normals)
        writer.add(Section.uvs, uvs)
        writer.add(Section.indices, indices)
        writer.add(Section.triangleMaterials, triangleMaterials)
        writer.add(Section.materials, materials)
        writer.add(Section.trees, trees)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer.write(to: url, key: key)
    }

    init(x: Int, z: Int, level: Int) {
        (self.x, self.z, self.level) = (x, z, level)
    }

    /// The tile in the file at `url`, if it is there, whole, and was written for `key`. Its chunks' arrays are the
    /// file's, mapped.
    init?(url: URL, key: String, x: Int, z: Int, level: Int) {
        guard let file = SectionFile(url: url, key: key),
              let records: [ChunkRecord] = file.array(Section.chunks), let positions = file.mapped(Section.positions, of: SIMD3<Float>.self),
              let normals = file.mapped(Section.normals, of: SIMD3<Float>.self), let uvs = file.mapped(Section.uvs, of: SIMD2<Float>.self),
              let indices = file.mapped(Section.indices, of: UInt32.self), let triangleMaterials = file.mapped(Section.triangleMaterials, of: UInt8.self),
              let materials: [GPUMaterial] = file.array(Section.materials), let trees: [World.Placement] = file.array(Section.trees),
              normals.count == positions.count, uvs.count * 2 == positions.count, triangleMaterials.count * 12 == indices.count else { return nil }
        (self.x, self.z, self.level) = (x, z, level)
        self.trees = trees
        /// Elements `range` of a section, still in the mapping.
        func slice(_ data: Data, _ range: Range<Int>, stride: Int) -> Data? {
            guard range.upperBound * stride <= data.count else { return nil }
            return data[(data.startIndex + range.lowerBound * stride)..<(data.startIndex + range.upperBound * stride)]
        }
        for r in records {
            let v = Int(r.firstVertex)..<Int(r.firstVertex + r.vertexCount), i = Int(r.firstIndex)..<Int(r.firstIndex + r.indexCount)
            let m = Int(r.firstMaterial)..<Int(r.firstMaterial + r.materialCount)
            guard m.upperBound <= materials.count, i.lowerBound % 3 == 0, i.count % 3 == 0,
                  let p = slice(positions, v, stride: 16), let n = slice(normals, v, stride: 16), let uv = slice(uvs, v, stride: 8),
                  let index = slice(indices, i, stride: 4),
                  let offsets = slice(triangleMaterials, (i.lowerBound / 3)..<(i.upperBound / 3), stride: 1) else { return nil }
            chunks.append(Chunk(positions: .mapped(p), normals: .mapped(n), uvs: .mapped(uv), indices: .mapped(index),
                                triangleMaterials: .mapped(offsets), materials: Array(materials[m]), glass: r.glass != 0,
                                bounds: AABB(lo: SIMD3(r.lo.x, r.lo.y, r.lo.z), hi: SIMD3(r.hi.x, r.hi.y, r.hi.z))))
        }
    }

    /// A tile's level for a viewer `rings` tiles away (the larger of the two distances along the axes): the viewer's
    /// tile and its neighbours whole, coarser from 380 m and from a kilometre on; nil beyond `reach` tiles.
    static func level(rings: Int, reach: Int = 8) -> Int? { rings <= 1 ? 0 : rings <= 4 ? 1 : rings <= reach ? 2 : nil }

    /// `METALRENDERER_WORLD_TEST=<seed>`: makes every tile a viewer at the middle of the origin's city has around
    /// them, at its level, and says what they hold and how long they took.
    static func runTest(seed: UInt64) {
        let world = World(seed: seed)
        let start = CFAbsoluteTimeGetCurrent()
        let flora = World.Flora(Foliage.library(seed: seed))
        print(String(format: "World %d: the plants' library in %.1f ms", seed, (CFAbsoluteTimeGetCurrent() - start) * 1000))
        let city = world.city(cell: SIMD2(0, 0))!
        let side = Double(World.tileSize)
        let cx = Int((city.center.x / side).rounded(.down)), cz = Int((city.center.y / side).rounded(.down))
        print(String(format: "  the city at the origin: middle (%.0f, %.0f), radius %.0f m, ground at %.1f m", city.center.x, city.center.y,
                     city.radius, city.level))
        var jobs: [(x: Int, z: Int, level: Int)] = []
        for j in -8...8 {
            for i in -8...8 {
                if let level = level(rings: max(abs(i), abs(j))) { jobs.append((cx + i, cz + j, level)) }
            }
        }
        var tiles = [WorldTile?](repeating: nil, count: jobs.count), times = [Double](repeating: 0, count: jobs.count)
        let wall = CFAbsoluteTimeGetCurrent()
        tiles.withUnsafeMutableBufferPointer { out in
            times.withUnsafeMutableBufferPointer { time in
                DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
                    let t = CFAbsoluteTimeGetCurrent()
                    out[k] = build(world, x: jobs[k].x, z: jobs[k].z, level: jobs[k].level, flora: flora)
                    time[k] = CFAbsoluteTimeGetCurrent() - t
                }
            }
        }
        print(String(format: "  %d tiles in %.2f s on every core", jobs.count, CFAbsoluteTimeGetCurrent() - wall))
        for level in 0..<World.levels {
            let own = jobs.indices.filter { jobs[$0].level == level }
            let made = own.map { tiles[$0]! }
            let triangles = made.map(\.triangles), trees = made.reduce(0) { $0 + $1.trees.count }
            let bytes = made.reduce(0) { sum, tile in
                sum + tile.chunks.reduce(0) { $0 + $1.positions.count * 40 + $1.indices.count * 4 + $1.triangleMaterials.count + $1.materials.count * 64 }
                    + tile.trees.count * MemoryLayout<World.Placement>.stride
            }
            let slowest = own.map { times[$0] }.max() ?? 0, mean = own.reduce(0) { $0 + times[$1] } / Double(max(own.count, 1))
            print(String(format: "  level %d: %3d tiles, %8d triangles (%d...%d a tile), %6d trees, %6.1f MB, %.1f ms a tile (%.1f the slowest)",
                         level, own.count, triangles.reduce(0, +), triangles.min() ?? 0, triangles.max() ?? 0, trees, Double(bytes) / 1e6,
                         mean * 1000, slowest * 1000))
        }
        let cover = world.groundCover(x0: city.center.x + Double(city.radius) + 400, z0: city.center.y, side: 32, flora: flora)
        print("  a ground-cover cell outside the city: \(cover.count) plants")
    }

    /// The tile: from its file, or made now and written there, then taken from the file all the same (its arrays are
    /// then the file's pages). Without the cache: made, and kept as made.
    static func make(_ world: World, x: Int, z: Int, level: Int, flora: World.Flora) -> WorldTile {
        let url = url(world, x: x, z: z, level: level), key = key(world, x: x, z: z, level: level)
        if GeneratedCache.enabled, let tile = WorldTile(url: url, key: key, x: x, z: z, level: level) { return tile }
        let tile = build(world, x: x, z: z, level: level, flora: flora)
        guard GeneratedCache.enabled else { return tile }
        do { try tile.write(to: url, key: key) } catch { print("World: tile \(x) \(z) not written: \(error)") }
        return WorldTile(url: url, key: key, x: x, z: z, level: level) ?? tile
    }
}
