import Foundation
import simd

/// One tile of the open world (World.swift) at one level of detail: everything the world has in a 256 m square, made
/// from the seed and the tile's place alone, in metres from the tile's corner (y is the world's height). A tile is
/// kept as a file of its arrays (SectionFile), so it is made once; for the custom ray tracer, with the trees over its
/// meshes (`addTrees`), which are then built once too.
///
///   The ground     a grid of cells (1, 4 or 16 m by level) with a skirt down its sides, which hides the step to a
///                  neighbour of another level; each cell of one of the world's ground materials.
///   The city       the blocks whose middle is in the tile: sidewalks inside a kerb, lawns in the courtyards, street
///                  lamps and trees, and the buildings (BuildingGenerator): whole at level 0, without their glass at
///                  level 1, a box each at level 2. And the roads of the tile's part of the city's grid, each a
///                  sheet of asphalt on the ground, painted at levels 0 and 1: a broken line down its middle, and
///                  where streets meet a crossing for people and a line to stop at.
///   The roads      between cities (World.Highway), where they cross the tile: asphalt in pieces of 8 m, each cut at
///                  the tile's sides, with a line along each edge and a broken one down the middle at levels 0 and 1.
///   The trees      as placements: which plant of the world's library stands where.
///   The lights     a city's street lamps (level 0 and 1) and the share of its windows with a light behind them (on
///                  a building's box at level 2) are emissive, and the tile's lights (`lights`): the mesh lights a
///                  scene samples at night, made once, with the tile. How far on they are is the scene's to say, by
///                  the time of day (Scene.setCityLights): by day they emit nothing.
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
        /// The custom tracer's tree over it, where the tile has its trees.
        var tree: Scene.BorrowedTree? = nil

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

    /// A light of the tile: the triangles of a chunk that have one of its materials, an emissive one, as a mesh
    /// light (Scene.MeshLight). 64 bytes, as the tile's file holds it.
    struct Light {
        var chunk: UInt32
        var material: UInt32            // in the chunk's list
        var first: UInt32, count: UInt32   // its triangles among `emissive`
        var center: SIMD4<Float>        // of the triangles' bounding sphere; w = its radius
        var normal: SIMD4<Float>        // their area-weighted mean normal; w = flatness
        var power: SIMD4<Float>         // sum of emitted radiance x area
    }

    let x: Int, z: Int, level: Int
    var chunks: [Chunk] = []
    var trees: [World.Placement] = []
    var lights: [Light] = []
    /// The lights' triangles, in their chunks' coordinates: a light's one after the other.
    var emissive: Stored<GPUEmissiveTriangle> = .made([])

    /// From the world's origin to the tile's corner.
    static func origin(_ x: Int, _ z: Int) -> SIMD2<Double> { SIMD2(Double(x), Double(z)) * Double(World.tileSize) }
    var triangles: Int { chunks.reduce(0) { $0 + $1.triangles } }
    var hasTrees: Bool { chunks.allSatisfy { $0.tree != nil } }

    /// Builds the trees of the chunks that have none (what the tracer would build for each: `MeshBlock.tree`).
    mutating func addTrees() {
        for c in chunks.indices where chunks[c].tree == nil {
            let chunk = chunks[c]
            var memory: UnsafeMutableRawPointer?, bytes = 0
            let shape = chunk.positions.withUnsafeBufferPointer { positions in
                chunk.uvs.withUnsafeBufferPointer { uvs in
                    chunk.indices.withUnsafeBufferPointer { indices in
                        BVHBuilder.buildBLAS(positions: positions.baseAddress!, uvs: uvs.baseAddress!, indices: indices, cutout: 0) { nodes in
                            bytes = nodes * MemoryLayout<BVHNode>.stride + indices.count * MemoryLayout<SIMD4<Float>>.stride
                            memory = malloc(max(bytes, 16))
                            return memory
                        }
                    }
                }
            }
            guard let memory else { continue }
            // (The tree's memory goes to the file from where it is, and is freed with this tile: once that is written.)
            let own = Data(bytesNoCopy: memory, count: bytes, deallocator: .free)
            guard let shape else { continue }
            chunks[c].tree = Scene.BorrowedTree(memory: .mapped(own), nodeCount: shape.nodes, depth: shape.depth, bounds: shape.bounds)
        }
    }

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
            for block in blocks { add(block, of: city, level: level, lit: world.lit, opaque: &opaque, glass: &glass) }
        }
        if let (city, from, roads) = world.roads(x0: origin.x, z0: origin.y, side: side) {
            add(roads, of: city, from: from, level: level, into: &opaque)
        }
        if let city = world.city(near: origin.x + side / 2, origin.y + side / 2), !city.highways.isEmpty {
            add(city.highways, of: world, city: city, origin: origin, level: level, into: &opaque)
        }
        tile.chunks = opaque.finish() + glass.finish()
        tile.trees = world.trees(x0: origin.x, z0: origin.y, side: side, flora: flora)
        tile.addLights()
        return tile
    }

    /// The tile's lights: for each chunk, the triangles of each of its emissive materials.
    private mutating func addLights() {
        var triangles: [GPUEmissiveTriangle] = []
        for (c, chunk) in chunks.enumerated() where !chunk.glass {
            let emission = chunk.materials.map { SIMD3($0.emission.x, $0.emission.y, $0.emission.z) }
            guard emission.contains(where: { $0.max() > 0 }) else { continue }
            var drafts = [Scene.MeshLightDraft](repeating: Scene.MeshLightDraft(), count: emission.count)
            chunk.positions.withUnsafeBufferPointer { positions in
                chunk.indices.withUnsafeBufferPointer { indices in
                    chunk.triangleMaterials.withUnsafeBufferPointer { materials in
                        for t in 0..<materials.count where emission[Int(materials[t])].max() > 0 {
                            drafts[Int(materials[t])].add(positions[Int(indices[3 * t])], positions[Int(indices[3 * t + 1])],
                                                          positions[Int(indices[3 * t + 2])], emission: emission[Int(materials[t])])
                        }
                    }
                }
            }
            for m in drafts.indices {
                guard let light = drafts[m].finish(instance: 0, firstTriangle: triangles.count) else { continue }
                lights.append(Light(chunk: UInt32(c), material: UInt32(m), first: UInt32(triangles.count), count: UInt32(light.triangleCount),
                                    center: SIMD4(light.center, light.radius), normal: SIMD4(light.normal, light.flatness),
                                    power: SIMD4(light.power, 0)))
                triangles += drafts[m].triangles
            }
        }
        emissive = .made(triangles)
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
        let scale = 1 / World.groundTile
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

    /// A block of a city: its sidewalk and what stands on it. `lit`: the share of its windows with a light behind
    /// them. (What emits has a colour too: what it looks like by day, with its light off.)
    private static func add(_ block: World.Block, of city: World.City, level: Int, lit: Float, opaque: inout Assembler,
                            glass: inout Assembler) {
        let plan = block.plan
        let place = translate([block.origin.x, city.level, block.origin.y])
        func builder(_ m: SurfaceMaterial) -> MeshBuilder { MeshBuilder(uvScale: m.uvScale) }
        let paving = SurfaceMaterial(color: [0.52, 0.5, 0.47], surface: .paving)
        var sidewalks = builder(paving)
        let r = plan.blocks[0].rect
        if level == 0 {
            // The kerb: a border of stone around the paving.
            let stone = SurfaceMaterial(color: [0.6, 0.59, 0.56]), inner = r.inset(WorldTile.kerb)
            var kerb = builder(stone)
            kerb.box([r.lo.x, 0, r.lo.y], [r.hi.x, 0.15, r.hi.y], faces: .sides)
            kerb.floor(x0: r.lo.x, x1: r.hi.x, z0: r.lo.y, z1: inner.lo.y, y: 0.15)
            kerb.floor(x0: r.lo.x, x1: r.hi.x, z0: inner.hi.y, z1: r.hi.y, y: 0.15)
            kerb.floor(x0: r.lo.x, x1: inner.lo.x, z0: inner.lo.y, z1: inner.hi.y, y: 0.15)
            kerb.floor(x0: inner.hi.x, x1: r.hi.x, z0: inner.lo.y, z1: inner.hi.y, y: 0.15)
            opaque.add(kerb, material(stone), place)
            sidewalks.floor(x0: inner.lo.x, x1: inner.hi.x, z0: inner.lo.y, z1: inner.hi.y, y: 0.15)
        } else {
            sidewalks.box([r.lo.x, 0, r.lo.y], [r.hi.x, 0.15, r.hi.y], faces: [.sides, .top])
        }
        opaque.add(sidewalks, material(paving), place)
        // Grass: a park's, and the courtyards'.
        let grass = SurfaceMaterial(color: [0.2, 0.34, 0.12])
        var lawn = builder(grass)
        for l in plan.blocks[0].park ? [r.inset(CityPlan.sidewalk)] : plan.courts.map({ $0.inset(1.5) }) where l.size.x > 1 && l.size.y > 1 {
            lawn.box([l.lo.x, 0.15, l.lo.y], [l.hi.x, 0.22, l.hi.y], faces: [.sides, .top])
        }
        opaque.add(lawn, material(grass), place)
        if level <= 1 {
            // Street lamps, as the City scene's: their heads' undersides are lights, and from further away the heads
            // are all there is of them.
            let iron = SurfaceMaterial(color: [0.07, 0.075, 0.08])
            let lampLight = SurfaceMaterial(color: [0.6, 0.6, 0.58], emission: World.lampEmission)
            var posts = builder(iron), heads = builder(lampLight)
            for lamp in plan.lamps {
                let p = SIMD3<Float>(lamp.position.x, 0.15, lamp.position.y), out = SIMD3<Float>(lamp.toRoad.x, 0, lamp.toRoad.y)
                let across = SIMD3<Float>(-out.z, 0, out.x)
                let a = p + [0, 6.1, 0], b = a + out * 1.6
                if level == 0 {
                    posts.cylinder(p, radius: 0.08, topRadius: 0.05, height: 6.2, segments: 8)
                    posts.box(simd_min(a - across * 0.04, b + across * 0.04) - [0, 0.04, 0], simd_max(a - across * 0.04, b + across * 0.04) + [0, 0.04, 0])
                }
                let c = b - out * 0.35
                let lo = simd_min(c - across * 0.14 - out * 0.3, c + across * 0.14 + out * 0.3)
                let hi = simd_max(c - across * 0.14 - out * 0.3, c + across * 0.14 + out * 0.3)
                posts.box(lo - [0, 0.14, 0], hi - [0, 0.04, 0], faces: [.sides, .top])
                heads.floor(x0: lo.x, x1: hi.x, z0: lo.z, z1: hi.z, y: lo.y - 0.14, up: false)
            }
            opaque.add(posts, material(iron), place)
            opaque.add(heads, material(lampLight), place)
        }
        if level <= 1 {
            let bark = SurfaceMaterial(color: [0.25, 0.18, 0.12]), leaves = SurfaceMaterial(color: [0.12, 0.26, 0.08])
            var trunks = builder(bark), crowns = builder(leaves)
            for tree in plan.trees + plan.courtTrees {
                let p = SIMD3<Float>(tree.x, 0.15, tree.y), size = tree.z
                trunks.cylinder(p, radius: 0.16 * size, topRadius: 0.1 * size, height: 2.6 * size, segments: 6, cap: false)
                crowns.ball(p + [0, 3.9 * size, 0], radius: SIMD3(1.7, 1.9, 1.7) * size, subdivisions: level == 0 ? 1 : 0)
            }
            opaque.add(trunks, material(bark), place)
            opaque.add(crowns, material(leaves), place)
        }
        // The buildings, each from its lot's own seed, in the lots' order.
        var settings = plan.settings
        settings.lit = lit
        let specs = plan.lots.map { BuildingSpec(lot: $0, city: settings, night: true) }
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
                // Its lit windows: each moved out of the building, along its normal, onto the box. (Unlit, they are
                // the wall.)
                if let lit = building.parts.first(where: { $0.slot == .lit }) {
                    var glow = lit.material
                    glow.color = wall.material.color
                    var windows = builder(glow)
                    let p = lit.mesh.positions, normals = lit.mesh.normals
                    for q in stride(from: 0, to: p.count - 3, by: 4) {
                        let n = normals[q], middle = (p[q] + p[q + 1] + p[q + 2] + p[q + 3]) / 4
                        var out = Float.infinity
                        for k in 0..<3 where abs(n[k]) > 1e-3 { out = min(out, ((n[k] > 0 ? hi[k] : lo[k]) - middle[k]) / n[k]) }
                        guard out.isFinite else { continue }
                        let by = n * (max(out, 0) + 0.05)
                        windows.quad(p[q] + by, p[q + 1] + by, p[q + 2] + by, p[q + 3] + by)
                    }
                    opaque.add(windows, material(glow), transform)
                }
                continue
            }
            // (A lit blind is a blind, and a room's lamp is white, when they are off.)
            let blind = building.parts.first { $0.slot == .blind }?.material.color ?? BuildingStyle().blind.color
            for part in building.parts {
                if part.material.glass {
                    if level == 0 { glass.add(part.mesh, material(part.material), transform) }
                } else {
                    var surface = part.material
                    if part.slot == .lit { surface.color = blind } else if part.slot == .lamp { surface.color = [0.8, 0.8, 0.78] }
                    opaque.add(part.mesh, material(surface), transform)
                }
            }
        }
    }

    /// How wide a block's kerb is, and how far over the ground the roads and the paint on them lie.
    private static let kerb: Float = 0.3, roadHeight: Float = 0.02, paintHeight: Float = 0.03

    /// The roads: asphalt, and at levels 0 and 1 what is painted on it.
    private static func add(_ roads: [World.Road], of city: World.City, from origin: SIMD2<Float>, level: Int, into opaque: inout Assembler) {
        let asphalt = SurfaceMaterial(color: [0.1, 0.1, 0.11], surface: .asphalt), paint = SurfaceMaterial(color: [0.7, 0.7, 0.66])
        var sheets = MeshBuilder(uvScale: asphalt.uvScale), lines = MeshBuilder(uvScale: paint.uvScale)
        for road in roads {
            let r = road.rect
            sheets.floor(x0: r.lo.x, x1: r.hi.x, z0: r.lo.y, z1: r.hi.y, y: roadHeight)
            guard level <= 1, road.along < 2 else { continue }
            // Along the street `u` (from its low end), across it `v` (from its middle, toward +z or +x).
            let alongX = road.along == 0, length = alongX ? r.size.x : r.size.y, half = (alongX ? r.size.y : r.size.x) / 2
            func mark(_ u0: Float, _ u1: Float, _ v0: Float, _ v1: Float) {
                if alongX {
                    lines.floor(x0: r.lo.x + u0, x1: r.lo.x + u1, z0: r.center.y + v0, z1: r.center.y + v1, y: paintHeight)
                } else {
                    lines.floor(x0: r.center.x + v0, x1: r.center.x + v1, z0: r.lo.y + u0, z1: r.lo.y + u1, y: paintHeight)
                }
            }
            // Cars keep to the right: going toward +x that is +z, going toward +z it is -x.
            let right: Float = alongX ? 1 : -1
            var from: Float = 2, to = length - 2
            for end in 0..<2 where road.junction[end] {
                /// From `d0` to `d1` metres in from this end.
                func markIn(_ d0: Float, _ d1: Float, _ v0: Float, _ v1: Float) {
                    if end == 0 { mark(d0, d1, v0, v1) } else { mark(length - d1, length - d0, v0, v1) }
                }
                // Where people cross: stripes half a metre wide.
                for k in 0..<Int(2 * half) {
                    let v = -half + 0.25 + Float(k)
                    markIn(0.6, 3.6, v, v + 0.5)
                }
                // Where the cars that come to the crossing stop: across their lane.
                let lane: Float = end == 0 ? -right : right
                markIn(4.6, 5, min(lane * 0.08, lane * half), max(lane * 0.08, lane * half))
                if end == 0 { from = 7 } else { to = length - 7 }
            }
            // The middle line: 3 m of paint, 5 m of none.
            let count = Int(((to - from + 5) / 8).rounded(.down))
            let first = from + (to - from - (Float(count) * 8 - 5)) / 2
            for k in 0..<max(count, 0) { mark(first + Float(k) * 8, first + Float(k) * 8 + 3, -0.08, 0.08) }
        }
        let place = translate([origin.x, city.level, origin.y])
        opaque.add(sheets, material(asphalt), place)
        opaque.add(lines, material(paint), place)
    }

    /// The part of a convex polygon (x, z) where a * x + b * z >= c.
    private static func clip(_ polygon: [SIMD2<Float>], _ a: Float, _ b: Float, _ c: Float) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for i in polygon.indices {
            let p = polygon[i], q = polygon[(i + 1) % polygon.count]
            let dp = a * p.x + b * p.y - c, dq = a * q.x + b * q.y - c
            if dp >= 0 { out.append(p) }
            if (dp > 0 && dq < 0) || (dp < 0 && dq > 0) { out.append(p + (q - p) * (dp / (dp - dq))) }
        }
        return out
    }

    /// The roads between cities, where they cross the tile: each in pieces of 8 m along its axis, cut at the tile's
    /// sides. At levels 0 and 1 the ground under a road is the road's own (World.height), and a piece lies flat on
    /// it. At level 2 the ground's cells are wider than the road's shoulders: there a piece is cut along the cells'
    /// triangles too, and each part lies on its triangle.
    private static func add(_ roads: [World.Highway], of world: World, city: World.City, origin: SIMD2<Double>, level: Int,
                            into opaque: inout Assembler) {
        let asphalt = SurfaceMaterial(color: [0.1, 0.1, 0.11], surface: .asphalt), paint = SurfaceMaterial(color: [0.7, 0.7, 0.66])
        var sheets = MeshBuilder(uvScale: asphalt.uvScale), lines = MeshBuilder(uvScale: paint.uvScale)
        let side = World.tileSize, step = 8.0
        // The asphalt's texture goes by the builder's x and z: these are from a place the texture repeats at all
        // over the world, so a road is one surface from tile to tile.
        let tile = Double(SurfaceKind.asphalt.tile)
        let shift = SIMD2(Float(origin.x - (origin.x / tile).rounded(.down) * tile), Float(origin.y - (origin.y / tile).rounded(.down) * tile))
        let cell = World.cellSize(level), n = Int(side / cell)
        var heights: [Float] = []   // the ground's, at level 2: as `ground` has them
        /// A polygon of road on the coarsest ground: its part in each of the ground's triangles, `lift` over it.
        func drape(_ polygon: [SIMD2<Float>], lift: Float, into mesh: inout MeshBuilder) {
            if heights.isEmpty {
                heights = (0...n).flatMap { j in
                    (0...n).map { i in world.height(origin.x + Double(Float(i) * cell), origin.y + Double(Float(j) * cell), city: city) }
                }
            }
            let xs = polygon.map(\.x), zs = polygon.map(\.y)
            let i0 = max(Int(xs.min()! / cell), 0), i1 = min(Int(xs.max()! / cell), n - 1)
            let j0 = max(Int(zs.min()! / cell), 0), j1 = min(Int(zs.max()! / cell), n - 1)
            guard i0 <= i1, j0 <= j1 else { return }
            for j in j0...j1 {
                for i in i0...i1 {
                    let x0 = Float(i) * cell, z0 = Float(j) * cell
                    let inside = clip(clip(clip(clip(polygon, 1, 0, x0), -1, 0, -x0 - cell), 0, 1, z0), 0, -1, -z0 - cell)
                    guard inside.count >= 3 else { continue }
                    let a = heights[j * (n + 1) + i], b = heights[j * (n + 1) + i + 1]
                    let c = heights[(j + 1) * (n + 1) + i], d = heights[(j + 1) * (n + 1) + i + 1]
                    // The cell's two triangles, either side of its diagonal from (i, j): the one toward +x, the one toward +z.
                    for (part, dx, dz) in [(clip(inside, 1, -1, x0 - z0), b - a, d - b), (clip(inside, -1, 1, z0 - x0), d - c, c - a)]
                    where part.count >= 3 {
                        mesh.ground(part.map { SIMD3($0.x + shift.x, a + (($0.x - x0) * dx + ($0.y - z0) * dz) / cell + lift, $0.y + shift.y) })
                    }
                }
            }
        }
        for road in roads {
            // The tile's corner as (along the road's axis, across it).
            let lo = road.axis == 0 ? origin : SIMD2(origin.y, origin.x)
            let first = max(road.u0, lo.x), last = min(road.u1, lo.x + Double(side))
            guard first < last else { continue }
            var m = (first / step).rounded(.down)
            while m * step < last {
                let ua = max(m * step, first), ub = min((m + 1) * step, last)
                m += 1
                guard ub - ua > 1e-3 else { continue }
                let (va, sa) = road.across(ua), (vb, sb) = road.across(ub)
                let qa = (1 + sa * sa).squareRoot(), qb = (1 + sb * sb).squareRoot(), reach = Double(World.roadWidth) * max(qa, qb)
                guard max(va, vb) + reach > lo.y, min(va, vb) - reach < lo.y + Double(side) else { continue }
                let ha = road.half(ua), hb = road.half(ub), ya = road.bed(ua).level, yb = road.bed(ub).level
                /// A piece from `s0` to `s1` of the way along (0...1), from `c0` to `c1` across: metres from the road's
                /// middle, given half its width there.
                func piece(_ s0: Float, _ s1: Float, _ c0: (Float) -> Float, _ c1: (Float) -> Float, lift: Float, into mesh: inout MeshBuilder) {
                    func corner(_ s: Float, _ c: (Float) -> Float) -> SIMD2<Float> {
                        let t = Double(s), across = Double(c(ha + (hb - ha) * s)) * (qa + (qb - qa) * t)
                        let p = road.place(ua + (ub - ua) * t, va + (vb - va) * t + across)
                        return SIMD2(Float(p.x - origin.x), Float(p.y - origin.y))
                    }
                    var polygon = [corner(s0, c0), corner(s1, c0), corner(s1, c1), corner(s0, c1)]
                    polygon = clip(clip(clip(clip(polygon, 1, 0, 0), -1, 0, -side), 0, 1, 0), 0, -1, -side)
                    guard polygon.count >= 3 else { return }
                    guard level < 2 else { return drape(polygon, lift: lift, into: &mesh) }
                    let from = Float(ua - lo.x), climb = (yb - ya) / Float(ub - ua)
                    mesh.ground(polygon.map { SIMD3($0.x + shift.x, ya + ((road.axis == 0 ? $0.x : $0.y) - from) * climb + lift, $0.y + shift.y) })
                }
                piece(0, 1, { -$0 }, { $0 }, lift: roadHeight, into: &sheets)
                guard level <= 1 else { continue }
                piece(0, 1, { 0.3 - $0 }, { 0.45 - $0 }, lift: paintHeight, into: &lines)
                piece(0, 1, { $0 - 0.45 }, { $0 - 0.3 }, lift: paintHeight, into: &lines)
                // The middle line: 3 m of paint in every 8 m of road.
                let count = max(Int((((ub - ua) * (ub - ua) + (vb - va) * (vb - va)).squareRoot() / 8).rounded()), 1)
                for k in 0..<count {
                    piece((Float(k) + 0.3125) / Float(count), (Float(k) + 0.6875) / Float(count), { _ in -0.08 }, { _ in 0.08 }, lift: paintHeight,
                          into: &lines)
                }
            }
        }
        let place = translate([-shift.x, 0, -shift.y])
        opaque.add(sheets, material(asphalt), place)
        opaque.add(lines, material(paint), place)
    }

    // MARK: - The tile's file

    /// A chunk in the file: where its arrays are among the tile's (MSL has no need of it: the renderer reads it).
    private struct ChunkRecord {
        var firstVertex: UInt32, vertexCount: UInt32, firstIndex: UInt32, indexCount: UInt32
        var firstMaterial: UInt32, materialCount: UInt32, glass: UInt32, pad: UInt32 = 0
        var lo: SIMD4<Float>, hi: SIMD4<Float>
    }
    /// A chunk's tree in the file: where it is among the tile's trees (in vectors), and the builder it is of.
    private struct TreeRecord {
        var first: UInt32, nodeCount: UInt32, depth: UInt32, builder: UInt32
        var lo: SIMD4<Float>, hi: SIMD4<Float>
    }
    private enum Section {
        static let chunks = SectionFile.id("chnk"), positions = SectionFile.id("posi"), normals = SectionFile.id("norm")
        static let uvs = SectionFile.id("uvco"), indices = SectionFile.id("indx"), triangleMaterials = SectionFile.id("tmat")
        static let materials = SectionFile.id("matl"), trees = SectionFile.id("tree")
        /// The chunks' trees (the plants above are `trees`): a record a chunk, and the trees one after the other.
        /// A file may have none: it is then written again with them when a tile with trees is asked for.
        static let chunkTrees = SectionFile.id("bvhr"), treeMemory = SectionFile.id("bvhm")
        /// The tile's lights and their triangles, if it has any.
        static let lights = SectionFile.id("lite"), emissive = SectionFile.id("emtr")
    }

    /// The tile's file: one folder to a world and its settings, one below it to a level.
    static func url(_ world: World, x: Int, z: Int, level: Int) -> URL {
        GeneratedCache.folder.appendingPathComponent("world-\(world.seed)-v\(World.version)").appendingPathComponent("\(level)")
            .appendingPathComponent("\(x)_\(z).tile")
    }

    /// Whether the tile is a city's: made for the cities' settings too. (The country's is the same whatever they are.)
    private static func hasCity(_ world: World, x: Int, z: Int) -> Bool {
        let origin = origin(x, z)
        return world.hasCity(x0: origin.x, z0: origin.y, side: Double(World.tileSize))
    }

    /// What the file was made for: the world's settings and the plants' library too.
    static func key(_ world: World, x: Int, z: Int, level: Int) -> String {
        "\(place(world, x: x, z: z)) level \(level)\(hasCity(world, x: x, z: z) ? ", lit \(world.lit)" : "")"
    }

    /// The same without the level: what a tile's trees are made for (every level has the same ones).
    static func place(_ world: World, x: Int, z: Int) -> String {
        "tile v\(World.version) plants v\(Foliage.version) seed \(world.seed) trees \(world.treeDensity) under \(world.undergrowth) "
            + "cities \(world.cityShare) at \(x) \(z)"
    }

    func write(to url: URL, key: String) throws {
        var records: [ChunkRecord] = [], materials: [GPUMaterial] = [], vertices = 0, indices = 0
        for chunk in chunks {
            records.append(ChunkRecord(firstVertex: UInt32(vertices), vertexCount: UInt32(chunk.positions.count),
                                       firstIndex: UInt32(indices), indexCount: UInt32(chunk.indices.count),
                                       firstMaterial: UInt32(materials.count), materialCount: UInt32(chunk.materials.count),
                                       glass: chunk.glass ? 1 : 0, lo: SIMD4(chunk.bounds.lo, 0), hi: SIMD4(chunk.bounds.hi, 0)))
            vertices += chunk.positions.count
            indices += chunk.indices.count
            materials += chunk.materials
        }
        // (The chunks' arrays go to the file one after the other, from where they are.)
        var writer = SectionFile.Writer()
        writer.add(Section.chunks, records)
        writer.add(Section.positions, stride: MemoryLayout<SIMD3<Float>>.stride, parts: chunks.map(\.positions.data))
        writer.add(Section.normals, stride: MemoryLayout<SIMD3<Float>>.stride, parts: chunks.map(\.normals.data))
        writer.add(Section.uvs, stride: MemoryLayout<SIMD2<Float>>.stride, parts: chunks.map(\.uvs.data))
        writer.add(Section.indices, stride: MemoryLayout<UInt32>.stride, parts: chunks.map(\.indices.data))
        writer.add(Section.triangleMaterials, stride: MemoryLayout<UInt8>.stride, parts: chunks.map(\.triangleMaterials.data))
        writer.add(Section.materials, materials)
        writer.add(Section.trees, trees)
        if !lights.isEmpty {
            writer.add(Section.lights, lights)
            writer.add(Section.emissive, stride: MemoryLayout<GPUEmissiveTriangle>.stride, parts: [emissive.data])
        }
        if hasTrees {
            var treeRecords: [TreeRecord] = [], vectors = 0
            for chunk in chunks {
                let tree = chunk.tree!
                treeRecords.append(TreeRecord(first: UInt32(vectors), nodeCount: UInt32(tree.nodeCount), depth: UInt32(tree.depth),
                                              builder: UInt32(BVHBuilder.version), lo: SIMD4(tree.bounds.lo, 0), hi: SIMD4(tree.bounds.hi, 0)))
                vectors += tree.memory.count
            }
            writer.add(Section.chunkTrees, treeRecords)
            writer.add(Section.treeMemory, stride: MemoryLayout<SIMD4<Float>>.stride, parts: chunks.map { $0.tree!.memory.data })
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer.write(to: url, key: key)
    }

    init(x: Int, z: Int, level: Int) {
        (self.x, self.z, self.level) = (x, z, level)
    }

    /// The tile in the file at `url`, if it is there, whole, and was written for `key`. Its chunks' arrays are the
    /// file's, mapped; so are their trees, if the file has them and they are this builder's.
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
        if let lights: [Light] = file.array(Section.lights) {
            guard let emissive = file.mapped(Section.emissive, of: GPUEmissiveTriangle.self) else { return nil }
            let count = emissive.count / MemoryLayout<GPUEmissiveTriangle>.stride
            guard lights.allSatisfy({ Int($0.chunk) < chunks.count && Int($0.material) < chunks[Int($0.chunk)].materials.count
                                      && Int($0.first) + Int($0.count) <= count }) else { return nil }
            (self.lights, self.emissive) = (lights, .mapped(emissive))
        }
        guard let treeRecords: [TreeRecord] = file.array(Section.chunkTrees), treeRecords.count == chunks.count,
              let memory = file.mapped(Section.treeMemory, of: SIMD4<Float>.self) else { return }
        var found: [Scene.BorrowedTree] = []
        for (c, r) in treeRecords.enumerated() {
            let vectors = Int(r.nodeCount) * Scene.BorrowedTree.vectorsPerNode + chunks[c].indices.count
            guard r.builder == UInt32(BVHBuilder.version), r.nodeCount % 3 == 0,
                  let own = slice(memory, Int(r.first)..<(Int(r.first) + vectors), stride: 16) else { return }
            found.append(Scene.BorrowedTree(memory: .mapped(own), nodeCount: Int(r.nodeCount), depth: Int(r.depth),
                                            bounds: AABB(lo: SIMD3(r.lo.x, r.lo.y, r.lo.z), hi: SIMD3(r.hi.x, r.hi.y, r.hi.z))))
        }
        for c in chunks.indices { chunks[c].tree = found[c] }
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
        for road in city.highways {
            // Along it every 4 m: how long it is, how steep, and how far its ground is from the country's.
            var length = 0.0, climb: Float = 0, cut: Float = 0, mean: Float = 0, turn = 0.0, count: Float = 0
            for u in stride(from: road.u0, to: road.u1, by: 4) {
                let (v, slope) = road.across(u), p = road.place(u, v), run = 4 * (1 + slope * slope).squareRoot()
                length += run
                turn = max(turn, abs(slope))
                climb = max(climb, abs(road.bed(u + 4).level - road.bed(u).level) / Float(run))
                let apart = abs(world.country(p.x, p.y) - road.bed(u).level)
                cut = max(cut, apart)
                mean += apart
                count += 1
            }
            let out = road.u0 > city.center[road.axis], to = road.place(out ? road.u1 : road.u0, out ? road.v1 : road.v0)
            print(String(format: "  a road along %@ toward the city at (%.0f, %.0f): %.0f m, at most %.0f degrees off its axis and %.1f%% steep, "
                         + "%.1f m of cut or fill (%.1f at most)", road.axis == 0 ? "x" : "z", to.x, to.y, length, atan(turn) * 180 / .pi,
                         climb * 100, mean / max(count, 1), cut))
        }
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
        if let road = city.highways.first {
            // The tile 600 m along the first road, at each level.
            let u = road.u0 > city.center[road.axis] ? road.u0 + 600 : road.u1 - 600, p = road.place(u, road.across(u).v)
            let x = Int((p.x / side).rounded(.down)), z = Int((p.y / side).rounded(.down))
            for level in 0..<World.levels {
                let t = CFAbsoluteTimeGetCurrent(), tile = build(world, x: x, z: z, level: level, flora: flora)
                print(String(format: "  a tile a road crosses, level %d: %d triangles, %d trees, %.1f ms", level, tile.triangles, tile.trees.count,
                             (CFAbsoluteTimeGetCurrent() - t) * 1000))
            }
        }
        let cover = world.groundCover(x0: city.center.x + Double(city.radius) + 400, z0: city.center.y, side: 32, flora: flora)
        print("  a ground-cover cell outside the city: \(cover.count) plants")
    }

    /// The tile: from its file, or made now and written there, then taken from the file all the same (its arrays are
    /// then the file's pages). Without the cache: made, and kept as made. `trees`: with its chunks' trees (the custom
    /// tracer's); a file without them gets them.
    static func make(_ world: World, x: Int, z: Int, level: Int, flora: World.Flora, trees: Bool = false) -> WorldTile {
        let url = url(world, x: x, z: z, level: level), key = key(world, x: x, z: z, level: level)
        var tile: WorldTile
        if GeneratedCache.enabled, let stored = WorldTile(url: url, key: key, x: x, z: z, level: level) {
            if !trees || stored.hasTrees {
                GeneratedCache.used(url)
                return stored
            }
            tile = stored
        } else {
            tile = build(world, x: x, z: z, level: level, flora: flora)
        }
        if trees { tile.addTrees() }
        guard GeneratedCache.enabled else { return tile }
        do { try tile.write(to: url, key: key) } catch { print("World: tile \(x) \(z) not written: \(error)") }
        GeneratedCache.written()
        return WorldTile(url: url, key: key, x: x, z: z, level: level) ?? tile
    }
}
