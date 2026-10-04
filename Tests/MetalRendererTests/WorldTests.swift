import XCTest
import simd
@testable import MetalRenderer

/// The open world as a function of its seed and a place (World.swift), and its tiles (WorldTile.swift).
final class WorldTests: XCTestCase {
    private let world = World(seed: 7)
    private lazy var flora = World.Flora(Foliage.library(seed: 7))

    private func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

    private func assertSame(_ a: WorldTile, _ b: WorldTile, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.chunks.count, b.chunks.count, what, file: file, line: line)
        for (p, q) in zip(a.chunks, b.chunks) {
            XCTAssertEqual(p.positions.array, q.positions.array, what, file: file, line: line)
            XCTAssertEqual(p.normals.array, q.normals.array, what, file: file, line: line)
            XCTAssertEqual(p.uvs.array, q.uvs.array, what, file: file, line: line)
            XCTAssertEqual(p.indices.array, q.indices.array, what, file: file, line: line)
            XCTAssertEqual(p.triangleMaterials.array, q.triangleMaterials.array, what, file: file, line: line)
            XCTAssertEqual(bytes(p.materials), bytes(q.materials), what, file: file, line: line)
            XCTAssertEqual(p.glass, q.glass, what, file: file, line: line)
            XCTAssertEqual(p.bounds.lo, q.bounds.lo, what, file: file, line: line)
            XCTAssertEqual(p.bounds.hi, q.bounds.hi, what, file: file, line: line)
        }
        XCTAssertEqual(a.trees, b.trees, what, file: file, line: line)
    }

    /// A tile is the same whatever was made before it, and the same from its file.
    func testATileDependsOnItsPlaceAlone() throws {
        let first = WorldTile.build(world, x: 3, z: -2, level: 1, flora: flora)
        _ = WorldTile.build(world, x: 4, z: -2, level: 1, flora: flora)
        _ = WorldTile.build(world, x: -90, z: 55, level: 2, flora: flora)
        assertSame(first, WorldTile.build(world, x: 3, z: -2, level: 1, flora: flora), "made again")
        XCTAssertGreaterThan(first.triangles, 2 * 64 * 64)
        XCTAssertFalse(first.trees.isEmpty)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorldTests-\(UUID().uuidString).tile")
        defer { try? FileManager.default.removeItem(at: url) }
        try first.write(to: url, key: "a key")
        assertSame(first, try XCTUnwrap(WorldTile(url: url, key: "a key", x: 3, z: -2, level: 1)), "from its file")
        XCTAssertNil(WorldTile(url: url, key: "another key", x: 3, z: -2, level: 1))
        // Another world is another ground.
        XCTAssertNotEqual(WorldTile.build(World(seed: 8), x: 3, z: -2, level: 1, flora: flora).chunks[0].positions.array, first.chunks[0].positions.array)
    }

    /// A tile's file has the trees over its chunks once they were asked for (the custom tracer's scenes ask): each
    /// the tree the tracer builds of the chunk's arrays, in the bytes its buffer has. A file without them is a tile
    /// all the same, and gets them.
    func testATilesFileHasItsTrees() throws {
        // (Where the cache's files go for this test only: `make` reads and writes there.)
        let world = World(seed: 7_000_000 + UInt64.random(in: 0..<1_000_000))
        let folder = WorldTile.url(world, x: 0, z: 0, level: 0).deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try XCTSkipUnless(GeneratedCache.enabled, "the cache is off")

        let bare = WorldTile.make(world, x: 3, z: -2, level: 1, flora: flora)
        XCTAssertFalse(bare.hasTrees)
        XCTAssertTrue(bare.chunks.allSatisfy { if case .mapped = $0.positions { return true } else { return false } }, "from its file")
        var built = WorldTile.build(world, x: 3, z: -2, level: 1, flora: flora)
        XCTAssertFalse(built.hasTrees)
        built.addTrees()
        XCTAssertTrue(built.hasTrees)

        // The file had none: they are built from its arrays, and it is written again with them.
        let stored = WorldTile.make(world, x: 3, z: -2, level: 1, flora: flora, trees: true)
        assertSame(built, stored, "with its trees")
        let url = WorldTile.url(world, x: 3, z: -2, level: 1), key = WorldTile.key(world, x: 3, z: -2, level: 1)
        let again = try XCTUnwrap(WorldTile(url: url, key: key, x: 3, z: -2, level: 1))
        XCTAssertTrue(stored.hasTrees && again.hasTrees)
        XCTAssertTrue(WorldTile.make(world, x: 3, z: -2, level: 1, flora: flora).hasTrees, "and has them for whoever asks for none")
        for (c, chunk) in again.chunks.enumerated() {
            let tree = try XCTUnwrap(chunk.tree), made = try XCTUnwrap(built.chunks[c].tree)
            XCTAssertTrue(tree.fits(indexCount: chunk.indices.count))
            XCTAssertEqual([tree.nodeCount, tree.depth], [made.nodeCount, made.depth])
            XCTAssertEqual(tree.bounds.lo, made.bounds.lo)
            XCTAssertEqual(tree.bounds.hi, made.bounds.hi)
            XCTAssertEqual(tree.memory.data, made.memory.data, "chunk \(c)")
            if case .made = tree.memory { XCTFail("the tree is the file's, mapped") }
            // What the builder makes of the chunk's triangles: their box, and each triangle once after the nodes.
            XCTAssertEqual(tree.bounds.lo, chunk.bounds.lo)
            XCTAssertEqual(tree.bounds.hi, chunk.bounds.hi)
            let triangles = tree.memory.array[(tree.nodeCount * Scene.BorrowedTree.vectorsPerNode)...]
            XCTAssertEqual(triangles.count, chunk.indices.count)
            XCTAssertEqual(Set(stride(from: triangles.startIndex, to: triangles.endIndex, by: 3).map { triangles[$0].w.bitPattern }).count,
                           chunk.triangles)
        }
        // A tile made where there is no file comes with them at once.
        let fresh = WorldTile.make(world, x: 4, z: -2, level: 2, flora: flora, trees: true)
        XCTAssertTrue(fresh.hasTrees)
        XCTAssertEqual(fresh.chunks[0].tree?.fits(indexCount: fresh.chunks[0].indices.count), true)
    }

    /// Neighbouring tiles' grounds meet: the same heights and normals along the side they share, near the origin
    /// and 50 km from it; and every level's vertices lie on the world's ground.
    func testNeighboursShareTheirSides() {
        for (x, z) in [(0, 0), (-1, 5), (200, -150)] {
            let level = 1, n = Int(World.tileSize / World.cellSize(level))
            let here = WorldTile.build(world, x: x, z: z, level: level, flora: flora).chunks[0]
            let east = WorldTile.build(world, x: x + 1, z: z, level: level, flora: flora).chunks[0]
            let south = WorldTile.build(world, x: x, z: z + 1, level: level, flora: flora).chunks[0]
            for k in 0...n {
                let a = k * (n + 1) + n, b = k * (n + 1)   // this tile's last column, the eastern one's first
                XCTAssertEqual(here.positions[a].y, east.positions[b].y, "tile \(x) \(z) east \(k)")
                XCTAssertEqual(here.normals[a], east.normals[b], "tile \(x) \(z) east \(k)")
                XCTAssertEqual(here.positions[a].x, World.tileSize)
                let c = n * (n + 1) + k                    // its last row, the southern one's first
                XCTAssertEqual(here.positions[c].y, south.positions[k].y, "tile \(x) \(z) south \(k)")
                XCTAssertEqual(here.normals[c], south.normals[k], "tile \(x) \(z) south \(k)")
            }
            let origin = WorldTile.origin(x, z)
            for level in 0..<World.levels where level > 0 || (x, z) == (0, 0) {
                let cell = World.cellSize(level), m = Int(World.tileSize / cell)
                let ground = level == 1 ? here : WorldTile.build(world, x: x, z: z, level: level, flora: flora).chunks[0]
                for (i, j) in [(0, 0), (m / 2, 3), (m, m), (5, m - 1)] {
                    let p = ground.positions[j * (m + 1) + i]
                    XCTAssertEqual(p.y, world.height(origin.x + Double(Float(i) * cell), origin.y + Double(Float(j) * cell)), "level \(level)")
                }
                XCTAssertTrue(ground.positions.array.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.y) < 400 })
                XCTAssertTrue(ground.indices.array.allSatisfy { Int($0) < ground.positions.count })
                XCTAssertTrue(ground.triangleMaterials.array.allSatisfy { Int($0) < ground.materials.count })
                XCTAssertEqual(ground.triangleMaterials.count * 3, ground.indices.count)
            }
        }
    }

    /// The trees of a square are the trees of its parts: asking for another square moves none. They stand on the
    /// ground, in their own tile, and none in a city.
    func testTreesStandWhereTheWorldPutsThem() throws {
        let side = Double(World.tileSize)
        let whole = world.trees(x0: 512, z0: -1024, side: 2 * side, flora: flora)
        var parts: [SIMD2<Double>] = []
        for (i, j) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let x0 = 512 + Double(i) * side, z0 = -1024 + Double(j) * side
            let trees = world.trees(x0: x0, z0: z0, side: side, flora: flora)
            for t in trees {
                XCTAssertTrue(t.x >= 0 && t.x < World.tileSize && t.z >= 0 && t.z < World.tileSize)
                XCTAssertEqual(t.y, world.height(x0 + Double(t.x), z0 + Double(t.z)) - 0.12, accuracy: 0.02)
                XCTAssertLessThan(Int(t.species), Foliage.Species.allCases.count)
                parts.append(SIMD2(x0 + Double(t.x), z0 + Double(t.z)))
            }
        }
        let all = whole.map { SIMD2(512 + Double($0.x), -1024 + Double($0.z)) }
        XCTAssertEqual(all.count, parts.count)
        func sorted(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] { points.sorted { ($0.x, $0.y) < ($1.x, $1.y) } }
        for (a, b) in zip(sorted(all), sorted(parts)) { XCTAssertEqual(distance(a, b), 0, accuracy: 1e-3) }
        // A wooded hectare has about `treeDensity` trees: this square is partly open country.
        XCTAssertGreaterThan(whole.count, 200)
        XCTAssertLessThan(Float(whole.count), world.treeDensity * 26.2 * 1.3)

        let city = try XCTUnwrap(world.city(cell: SIMD2(0, 0)), "the origin's cell always has a city")
        XCTAssertEqual(world.city(near: city.center.x, city.center.y), city)
        let tile = SIMD2(Int((city.center.x / side).rounded(.down)), Int((city.center.y / side).rounded(.down)))
        XCTAssertTrue(world.trees(x0: Double(tile.x) * side, z0: Double(tile.y) * side, side: side, flora: flora).isEmpty, "trees in a city")
        XCTAssertEqual(world.height(city.center.x + 40, city.center.y - 90), city.level, "a city's ground is level")
        let cover = world.groundCover(x0: 512, z0: -1024, side: 32, flora: flora)
        XCTAssertEqual(cover, world.groundCover(x0: 512, z0: -1024, side: 32, flora: flora))
        XCTAssertTrue(cover.allSatisfy { $0.x >= 0 && $0.x < 32 && $0.z >= 0 && $0.z < 32 })
        XCTAssertTrue(world.groundCover(x0: Double(tile.x) * side, z0: Double(tile.y) * side, side: 32, flora: flora).isEmpty)
    }

    /// The scene follows the camera a quarter of a tile late, so pacing across a tile's side changes nothing.
    func testTheSceneFollowsTheCamera() {
        let begin = world.start
        var place = WorldPlace(world: world, anchorTile: world.anchorTile, tile: SIMD2(10, -3), middle: .zero)
        let anchor = place.anchor
        XCTAssertEqual(anchor, WorldTile.origin(world.anchorTile.x, world.anchorTile.y))
        XCTAssertLessThan(abs(begin.place.x - anchor.x), 2000, "the world starts near its origin")
        XCTAssertEqual(Float(begin.place.y), world.height(begin.place.x, begin.place.z) + 1.7, accuracy: 0.01)
        func at(_ tx: Double, _ tz: Double) -> SIMD3<Float> {   // in tiles, from the world's origin
            SIMD3(Float(tx * 256 - anchor.x), 5, Float(tz * 256 - anchor.y))
        }
        XCTAssertEqual(place.wanted(for: at(10.5, -2.5)), SIMD2(10, -3), "its middle")
        XCTAssertEqual(place.wanted(for: at(11.2, -2.5)), SIMD2(10, -3), "a fifth of a tile into the next")
        XCTAssertEqual(place.wanted(for: at(11.3, -2.5)), SIMD2(11, -3))
        XCTAssertEqual(place.wanted(for: at(9.9, -3.3)), SIMD2(10, -4))
        XCTAssertEqual(place.wanted(for: at(13.6, -6.1)), SIMD2(13, -7), "far off: straight to the camera's tile")
        // The origin stays until the scene's middle is 8 tiles from it, then moves to a corner near the middle.
        place.anchorTile = SIMD2(16, 0)
        XCTAssertEqual(place.anchorTile(around: SIMD2(24, -8)), SIMD2(16, 0))
        XCTAssertEqual(place.anchorTile(around: SIMD2(25, -3)), SIMD2(24, 0))
        XCTAssertEqual(place.anchorTile(around: SIMD2(160, -121)), SIMD2(160, -120))
        XCTAssertEqual(place.wanted(for: SIMD3(Float(10.5 * 256 - place.anchor.x), 5, Float(-2.5 * 256))), SIMD2(10, -3))
        XCTAssertEqual(SceneKind.world.envName, "world")
        XCTAssertTrue(SceneKind.world.hasPlants && SceneKind.world.cameraFromScene)
    }

    /// A city's tile: blocks with their buildings and glass at level 0, less at each level after it; a block belongs
    /// to one tile only; nothing is built off the level ground.
    func testCityTiles() throws {
        let city = try XCTUnwrap(world.city(cell: SIMD2(0, 0)))
        let side = Double(World.tileSize)
        let tx = Int((city.center.x / side).rounded(.down)), tz = Int((city.center.y / side).rounded(.down))
        var seen = Set<SIMD2<Int>>()
        for j in -1...1 {
            for i in -1...1 {
                let found = try XCTUnwrap(world.blocks(x0: Double(tx + i) * side, z0: Double(tz + j) * side, side: side))
                XCTAssertEqual(found.city, city)
                for block in found.blocks {
                    XCTAssertTrue(seen.insert(block.index).inserted, "block \(block.index) is in two tiles")
                    let r = block.plan.blocks[0].rect
                    XCTAssertEqual(r.size, World.blockSize)
                    XCTAssertLessThan(length(simd_max(abs(r.lo), abs(r.hi))), city.radius)
                    for lot in block.plan.lots { XCTAssertTrue(r.contains(lot.rect), "a lot outside its block") }
                }
            }
        }
        XCTAssertGreaterThan(seen.count, 30)
        let again = try XCTUnwrap(world.blocks(x0: Double(tx) * side, z0: Double(tz) * side, side: side))
        XCTAssertEqual(again.blocks.map(\.plan.lots.count), world.blocks(x0: Double(tx) * side, z0: Double(tz) * side, side: side)!.blocks.map(\.plan.lots.count))
        XCTAssertEqual(world.blocks(x0: city.center.x + 2000, z0: city.center.y, side: side)?.blocks.count ?? 0, 0, "far from the city")

        let tiles = (0..<World.levels).map { WorldTile.build(world, x: tx, z: tz, level: $0, flora: flora) }
        XCTAssertTrue(tiles[0].chunks.contains { $0.glass })
        XCTAssertFalse(tiles[1].chunks.contains { $0.glass })
        XCTAssertGreaterThan(tiles[0].triangles, tiles[1].triangles)
        XCTAssertGreaterThan(tiles[1].triangles, 4 * tiles[2].triangles)
        for tile in tiles {
            for chunk in tile.chunks {
                XCTAssertLessThanOrEqual(chunk.materials.count, 256)
                XCTAssertTrue(chunk.indices.array.allSatisfy { Int($0) < chunk.positions.count })
                XCTAssertTrue(chunk.triangleMaterials.array.allSatisfy { Int($0) < chunk.materials.count })
                XCTAssertEqual(chunk.triangleMaterials.count * 3, chunk.indices.count)
                XCTAssertEqual(chunk.normals.count, chunk.positions.count)
                XCTAssertEqual(chunk.uvs.count, chunk.positions.count)
                XCTAssertFalse(chunk.bounds.isEmpty)
                for m in chunk.materials where m.textures.x != .max && m.textures.x != World.groundDetail && m.textures.x != World.fieldRows {
                    XCTAssertNotNil(World.kind(ofTexture: m.textures.x))
                }
            }
            // Buildings stand on the city's ground, and are no skyscrapers of a kilometre.
            let top = tile.chunks.map(\.bounds.hi.y).max()!
            XCTAssertGreaterThan(top, city.level + 6)
            XCTAssertLessThan(top, city.level + 200)
        }
        assertSame(tiles[0], WorldTile.build(world, x: tx, z: tz, level: 0, flora: flora), "a city tile made again")
    }

    /// A city's ground: a street along every side of a built block and a crossing at each of its corners, each one
    /// tile's; all of it on level ground, the coarsest ground's cells under it too. Around it fields, their sides on
    /// those cells; and nothing grows on a road.
    func testACitysGround() throws {
        let city = try XCTUnwrap(world.city(cell: SIMD2(0, 0)))
        let side = Double(World.tileSize), pitch = World.blockPitch, half = World.roadWidth / 2
        let tx = Int((city.center.x / side).rounded(.down)), tz = Int((city.center.y / side).rounded(.down))
        let reach = Int((Double(city.radius) / side).rounded(.up)) + 1
        func name(_ lo: SIMD2<Float>, _ along: Int) -> [Int] { [Int(lo.x.rounded()), Int(lo.y.rounded()), along] }
        var seen = Set<[Int]>(), roads: [World.Road] = []
        for j in -reach...reach {
            for i in -reach...reach {
                let x0 = Double(tx + i) * side, z0 = Double(tz + j) * side
                guard let found = world.roads(x0: x0, z0: z0, side: side) else { continue }
                XCTAssertEqual(found.city, city)
                XCTAssertEqual(found.origin, SIMD2(Float(city.center.x - x0), Float(city.center.y - z0)))
                for road in found.roads {
                    XCTAssertTrue(seen.insert(name(road.rect.lo, road.along)).inserted, "a road in two tiles")
                    roads.append(road)
                }
            }
        }
        var built = 0
        let span = Int(city.radius / pitch.y) + 2
        for j in -span...span {
            for i in -span...span where world.built(city, i, j) {
                built += 1
                let c = SIMD2(Float(i), Float(j)) * pitch
                let around: [(SIMD2<Float>, Int)] = [
                    (c + SIMD2(-half, half), 1), (c + SIMD2(pitch.x - half, half), 1), (c + SIMD2(half, -half), 0), (c + SIMD2(half, pitch.y - half), 0),
                    (c - half, 2), (c + pitch - half, 2), (c + SIMD2(pitch.x, 0) - half, 2), (c + SIMD2(0, pitch.y) - half, 2)]
                for (lo, along) in around { XCTAssertTrue(seen.contains(name(lo, along)), "block \(i) \(j) has no road \(along) at \(lo)") }
                // The block itself is paved, and no road lies on it.
                XCTAssertTrue(world.paved(city, city.center.x + Double(c.x + pitch.x / 2), city.center.y + Double(c.y + pitch.y / 2)))
                XCTAssertFalse(roads.contains { $0.rect.overlaps(CityPlan.Rect(lo: c + half, hi: c + pitch - half)) })
            }
        }
        XCTAssertGreaterThan(built, 30)
        XCTAssertLessThan(roads.count, 3 * built + 4 * span * 4, "roads where no block is")
        for road in roads {
            let r = road.rect
            // (A street is a block long; the first metres of a road to another city are a street too.)
            let stub = World.Highway.stub
            XCTAssertTrue(r.size == (road.along == 0 ? SIMD2(World.blockSize.x, 2 * half) : road.along == 1 ? SIMD2(2 * half, World.blockSize.y) : SIMD2(2 * half, 2 * half))
                          || r.size == (road.along == 0 ? SIMD2(stub, 2 * half) : SIMD2(2 * half, stub)), "\(r.size)")
            for corner in [r.lo, r.hi, SIMD2(r.lo.x, r.hi.y), SIMD2(r.hi.x, r.lo.y)] {
                for d in [SIMD2<Float>(0, 0), SIMD2(16, 16), SIMD2(-16, 16), SIMD2(16, -16), SIMD2(-16, -16)] {
                    XCTAssertEqual(world.height(city.center.x + Double(corner.x + d.x), city.center.y + Double(corner.y + d.y)), city.level)
                }
            }
            let x = city.center.x + Double(r.center.x), z = city.center.y + Double(r.center.y)
            XCTAssertTrue(world.paved(city, x, z) || (world.highway(city, x, z).map { $0.distance < $0.half } ?? false))
        }
        // In the middle of the city four streets meet at every crossing; at its edge fewer do.
        XCTAssertEqual(roads.first { $0.along == 1 && name($0.rect.lo, 1) == name(SIMD2(-half, half), 1) }?.junction, [true, true])
        XCTAssertTrue(roads.contains { $0.along < 2 && $0.junction.contains(false) })

        // Beyond the last road: fields, each of one kind over a cell of the coarsest ground, and no tree in them.
        let out = Double(city.radius + World.cityApron)
        XCTAssertFalse(world.paved(city, city.center.x + out, city.center.y, margin: 2))
        var kinds = Set<Int>()
        for k in 0..<96 {
            let angle = Double(k) / 96 * 2 * .pi, x = city.center.x + (out + 4) * cos(angle), z = city.center.y + (out + 4) * sin(angle)
            let field = try XCTUnwrap(world.field(city, x, z), "the belt next to the city is open")
            // (But for the grass beside a road out of the city.)
            let verge = (world.highway(city, x, z)?.distance ?? .infinity) < World.Highway.shoulder
            XCTAssertEqual(world.ground(x, z, up: 1, city: city), verge ? World.Ground.meadow : field)
            kinds.insert(field)
            // The cell of the coarsest ground it is in (from the city's middle, a multiple of 16 m itself).
            let x0 = (x / 16).rounded(.down) * 16, z0 = (z / 16).rounded(.down) * 16
            for (dx, dz) in [(0.5, 0.5), (15.5, 0.5), (0.5, 15.5), (15.5, 15.5)] {
                if let other = world.field(city, x0 + dx, z0 + dz) { XCTAssertEqual(other, field) }
            }
        }
        XCTAssertGreaterThan(kinds.count, 2)
        XCTAssertNil(world.field(city, city.center.x + out + Double(World.cityBlend) + 50, city.center.y))
        XCTAssertNil(world.field(nil, 0, 0))

        // Grass and bushes come up to the roads and stop there, and none grow in a sown field.
        var grown = 0
        for k in -12..<12 {
            let x0 = city.center.x + Double(k) * 32, z0 = city.center.y + (Double(city.radius) / 32).rounded(.down) * 32 - 64
            for j in 0..<5 {
                for p in world.groundCover(x0: x0, z0: z0 + Double(j) * 32, side: 32, flora: flora) {
                    let x = x0 + Double(p.x), z = z0 + Double(j) * 32 + Double(p.z)
                    XCTAssertFalse(world.paved(city, x, z, margin: 1))
                    XCTAssertEqual(world.field(city, x, z) ?? World.Ground.meadow, World.Ground.meadow)
                    grown += 1
                }
            }
        }
        XCTAssertGreaterThan(grown, 100)

        // A tile's roads are a few sheets at the edge of sight, and painted nearer.
        let tiles = (0..<World.levels).map { WorldTile.build(world, x: tx, z: tz, level: $0, flora: flora) }
        func count(_ tile: WorldTile, _ color: SIMD3<Float>) -> Int {
            tile.chunks.reduce(0) { sum, chunk in
                let own = Set(chunk.materials.indices.filter { SIMD3(chunk.materials[$0].albedo.x, chunk.materials[$0].albedo.y, chunk.materials[$0].albedo.z) == color
                                                               && chunk.materials[$0].textures.x == .max })
                return sum + chunk.triangleMaterials.array.reduce(0) { $0 + (own.contains(Int($1)) ? 1 : 0) }
            }
        }
        let paint = SIMD3<Float>(0.7, 0.7, 0.66)
        XCTAssertGreaterThan(count(tiles[0], paint), 200)
        XCTAssertEqual(count(tiles[1], paint), count(tiles[0], paint))
        XCTAssertEqual(count(tiles[2], paint), 0)
    }

    /// The roads between cities: one from a city to each city in a cell next to its own, the same road from either
    /// end, leaving by the end of the street through the city's middle and never near another road. The ground under
    /// it is the road's own; a tile has the part of it that is in the tile, lying on the tile's ground at every
    /// level; and nothing grows on it.
    func testRoadsBetweenCities() throws {
        typealias Highway = World.Highway
        var roads: [(from: World.City, to: World.City, road: Highway)] = []
        for j in -3...3 {
            for i in -3...3 {
                guard let city = world.city(cell: SIMD2(i, j)) else { continue }
                var expected = 0
                for (axis, step) in [(0, SIMD2(1, 0)), (1, SIMD2(0, 1))] {
                    if let next = world.city(cell: SIMD2(i, j) &+ step) {
                        expected += 1
                        let road = try XCTUnwrap(city.highways.first { $0.axis == axis && $0.u0 > city.center[axis] })
                        XCTAssertTrue(next.highways.contains(road), "the same road from its other end")
                        roads.append((city, next, road))
                    }
                    if world.city(cell: SIMD2(i, j) &- step) != nil { expected += 1 }
                }
                XCTAssertEqual(city.highways.count, expected)
            }
        }
        XCTAssertGreaterThan(roads.count, 8)
        var steepest: Float = 0
        for (a, b, road) in roads {
            // From the last crossing of the one's middle street to the first of the other's, straight on at both.
            let pitch = Double(World.blockPitch[road.axis]), reach = Double(World.roadWidth / 2 + Highway.stub)
            XCTAssertEqual(road.u0, a.center[road.axis] + Double(world.gate(a, axis: road.axis)) * pitch + reach)
            XCTAssertEqual(road.u1, b.center[road.axis] - Double(world.gate(b, axis: road.axis)) * pitch - reach)
            XCTAssertTrue(world.built(a, road.axis == 0 ? world.gate(a, axis: road.axis) - 1 : 0, road.axis == 1 ? world.gate(a, axis: road.axis) - 1 : 0))
            XCTAssertGreaterThan(road.u1 - road.u0, 800)
            XCTAssertEqual(road.across(road.u0).v, a.center[1 - road.axis])
            XCTAssertEqual(road.across(road.u1).v, b.center[1 - road.axis])
            XCTAssertEqual(road.across(road.u0).slope, 0)
            XCTAssertEqual(road.across(road.u1).slope, 0)
            XCTAssertEqual(road.bed(road.u0).level, a.level)
            XCTAssertEqual(road.bed(road.u1).level, b.level)
            XCTAssertEqual(road.half(road.u0), World.roadWidth / 2)
            XCTAssertEqual(road.half(road.u0 + 300), Highway.width / 2)
            for u in stride(from: road.u0, to: road.u1 - 16, by: 16) {
                let (v, slope) = road.across(u), p = road.place(u, v), q = (1 + slope * slope).squareRoot()
                steepest = max(steepest, abs(road.bed(u + 16).level - road.bed(u).level) / Float(16 * q))
                // The ground is the road's from its middle to 4 m beyond the asphalt in x and in z: the cells of
                // the ground at levels 0 and 1 that are under the asphalt are the road's planes.
                let edge = Double(road.half(u)) * q
                for across in [-edge, 0, edge] {
                    for (du, dv) in [(0.0, 0.0), (4, 4), (4, -4), (-4, 4), (-4, -4)] {
                        let at = road.place(u + du, v + across + dv)
                        XCTAssertEqual(world.height(at.x, at.y), road.bed(u + du).level, "\(u - road.u0) m along, \(across + dv) m across")
                    }
                }
                XCTAssertEqual(world.ground(p.x, p.y, up: 1, city: world.city(near: p.x, p.y)), World.Ground.meadow)
                // Where the road goes from the one city's cell into the other's, either city says the same of the ground.
                if abs(u - Double(b.cell[road.axis]) * World.cityCell) < 64 {
                    for across in [-60.0, -12, 0, 30] {
                        let at = road.place(u, v + across * q)
                        XCTAssertEqual(world.height(at.x, at.y, city: a), world.height(at.x, at.y, city: b))
                    }
                }
                // No other road of either city comes near, away from the city itself.
                for other in a.highways + b.highways where other != road {
                    if let d = other.distance(p.x, p.y) { XCTAssertGreaterThan(d, 2 * (Highway.shoulder + Highway.widestBank)) }
                }
            }
        }
        XCTAssertLessThan(steepest, 0.2)
        XCTAssertGreaterThan(steepest, 0.02)

        // The first road of the origin's city, in the four tiles along it from 512 m out.
        let (_, _, road) = try XCTUnwrap(roads.first { $0.from.cell == SIMD2(0, 0) || $0.to.cell == SIMD2(0, 0) })
        let side = Double(World.tileSize)
        let from = ((road.u0 + 512) / side).rounded(.down) * side
        var expected = 0.0, tiles = Set<SIMD2<Int>>()
        for u in stride(from: from, to: from + 4 * side, by: 8) {
            let (va, sa) = road.across(u), (vb, sb) = road.across(u + 8)
            let wa = Double(road.half(u)) * (1 + sa * sa).squareRoot(), wb = Double(road.half(u + 8)) * (1 + sb * sb).squareRoot()
            expected += 8 * (wa + wb)
            for v in [va - wa, va + wa, vb - wb, vb + wb] {
                let p = road.place(u + 4, v)
                tiles.insert(SIMD2(Int((p.x / side).rounded(.down)), Int((p.y / side).rounded(.down))))
            }
        }
        let asphalt = SIMD3<Float>(0.1, 0.1, 0.11), paint = SIMD3<Float>(0.7, 0.7, 0.66)
        /// The triangles of a tile that have a material of `color`: their corners.
        func triangles(_ tile: WorldTile, _ color: SIMD3<Float>) -> [[SIMD3<Float>]] {
            var out: [[SIMD3<Float>]] = []
            for chunk in tile.chunks {
                let own = Set(chunk.materials.indices.filter { SIMD3(chunk.materials[$0].albedo.x, chunk.materials[$0].albedo.y, chunk.materials[$0].albedo.z) == color })
                let positions = chunk.positions.array, indices = chunk.indices.array
                for (t, m) in chunk.triangleMaterials.array.enumerated() where own.contains(Int(m)) {
                    out.append((0..<3).map { positions[Int(indices[3 * t + $0])] })
                }
            }
            return out
        }
        for level in 0..<World.levels {
            var area = 0.0, painted = 0
            for at in tiles.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) {
                let tile = WorldTile.build(world, x: at.x, z: at.y, level: level, flora: flora)
                let x0 = Double(at.x) * side, z0 = Double(at.y) * side
                let cell = World.cellSize(level), n = Int(World.tileSize / cell), ground = tile.chunks[0].positions.array
                for corners in triangles(tile, asphalt) {
                    for p in corners {
                        XCTAssertTrue(p.x > -1e-3 && p.x < World.tileSize + 1e-3 && p.z > -1e-3 && p.z < World.tileSize + 1e-3, "in its tile")
                        if level < 2 {
                            XCTAssertEqual(p.y, world.height(x0 + Double(p.x), z0 + Double(p.z)) + 0.02, accuracy: 2e-3, "level \(level)")
                        } else {
                            // On the triangle of the tile's own ground that is under it.
                            let i = min(Int(p.x / cell), n - 1), j = min(Int(p.z / cell), n - 1)
                            let s = p.x / cell - Float(i), t = p.z / cell - Float(j)
                            let a = ground[j * (n + 1) + i].y, b = ground[j * (n + 1) + i + 1].y
                            let c = ground[(j + 1) * (n + 1) + i].y, d = ground[(j + 1) * (n + 1) + i + 1].y
                            let under = s >= t ? a + (b - a) * s + (d - b) * t : a + (c - a) * t + (d - c) * s
                            XCTAssertEqual(p.y, under + 0.02, accuracy: 5e-3, "level 2")
                        }
                    }
                    let e1 = corners[1] - corners[0], e2 = corners[2] - corners[0]
                    XCTAssertGreaterThan(e1.z * e2.x - e1.x * e2.z, 0, "it faces up")
                    area += Double(abs(e1.z * e2.x - e1.x * e2.z)) / 2
                }
                painted += triangles(tile, paint).count
                for tree in tile.trees {
                    let x = x0 + Double(tree.x), z = z0 + Double(tree.z)
                    XCTAssertGreaterThan(world.highway(world.city(near: x, z), x, z)?.distance ?? .infinity, Highway.shoulder + 1)
                }
            }
            // All of the road, once: no piece left out where tiles meet, none twice.
            XCTAssertEqual(area, expected, accuracy: expected * 1e-3, "level \(level)")
            if level < 2 { XCTAssertGreaterThan(painted, 4 * 32 * 6) } else { XCTAssertEqual(painted, 0) }
        }
        // Grass comes up to the asphalt.
        var grown = 0
        for u in stride(from: from, to: from + 256, by: 32) {
            let p = road.place(u, road.across(u).v)
            let x0 = (p.x / 32).rounded(.down) * 32, z0 = (p.y / 32).rounded(.down) * 32
            for plant in world.groundCover(x0: x0, z0: z0, side: 32, flora: flora) {
                let x = x0 + Double(plant.x), z = z0 + Double(plant.z)
                guard let near = world.highway(world.city(near: x, z), x, z) else { continue }
                XCTAssertGreaterThanOrEqual(near.distance, near.half + 1)
                if near.distance < Highway.shoulder { grown += 1 }
            }
        }
        XCTAssertGreaterThan(grown, 20)
    }

    /// The world's day: the sun over -z at noon and under the horizon for four tenths of the day, the moon the light
    /// when it is; the cities' lights come on as it sets, and the scene has them before they do.
    func testTheDay() {
        func at(_ phase: Float) -> Heavens { Heavens(at: (phase - Heavens.start) * Heavens.day) }
        let degree = Float.pi / 180
        XCTAssertEqual(Heavens.phase(at: 0), Heavens.start)
        XCTAssertEqual(Heavens.phase(at: 1.5 * Heavens.day), Heavens.start + 0.5, accuracy: 1e-5)
        XCTAssertEqual(Heavens.phase(at: 0.75 * Heavens.day), Heavens.start + 0.75 - 1, accuracy: 1e-5)
        XCTAssertEqual(SceneKind.world.dayCycle, Heavens.day)

        XCTAssertEqual(at(0.5).sunElevation, 60 * degree, accuracy: 1e-3)
        XCTAssertEqual(at(0).sunElevation, -24 * degree, accuracy: 1e-3)
        XCTAssertEqual(at(0.5).sun.x, 0, accuracy: 1e-5)
        XCTAssertLessThan(at(0.5).sun.z, 0)
        XCTAssertGreaterThan(at(0.3).sun.x, 0, "it rises in the east")
        var night = 0
        for step in 0..<1000 {
            let h = at(Float(step) / 1000)
            XCTAssertEqual(length(h.sun), 1, accuracy: 1e-5)
            XCTAssertEqual(length(h.moon), 1, accuracy: 1e-5)
            XCTAssertGreaterThan(max(h.sun.y, h.moon.y), 0.05, "one of them is always up")
            XCTAssertEqual(h.light, h.lightIsMoon ? h.moon : h.sun)
            XCTAssertEqual(h.lightIsMoon, h.sunElevation <= -Heavens.discRadius)
            if h.lightIsMoon {
                night += 1
                XCTAssertEqual(h.moonUp, 1, "the moon is up when it is the light")
            } else {
                XCTAssertEqual(h.moonlight, 0, "no moonlight while any of the sun is up")
            }
            XCTAssertTrue(h.adaptation >= 1 && h.adaptation <= 128)
        }
        XCTAssertTrue((370...390).contains(night), "\(night) thousandths of the day")
        XCTAssertEqual(at(0).moonlight, 1)
        XCTAssertEqual(at(0.5).adaptation, 1)
        // The eye adapts more the lower the sun.
        let heights = stride(from: Float(0.5), through: 1, by: 0.01).map { at($0) }
        XCTAssertTrue(zip(heights, heights.dropFirst()).allSatisfy { $0.adaptation <= $1.adaptation })

        // The lights: off by day and when the scene first has them, on in the dark; a lamp as the sun sets, the
        // windows one after the other.
        for window in [nil, 0, 0.5, 0.999] as [Float?] {
            XCTAssertEqual(World.lightOn(elevation: 30 * degree, window: window), 0)
            XCTAssertEqual(World.lightOn(elevation: World.lightsReady, window: window), 0)
            XCTAssertEqual(World.lightOn(elevation: 3.01 * degree, window: window), 0)
            XCTAssertEqual(World.lightOn(elevation: -8 * degree, window: window), 1)
        }
        XCTAssertEqual(World.lightOn(elevation: 0.5 * degree), 1, "the lamps are on as the sun sets")
        XCTAssertGreaterThan(World.lightOn(elevation: degree, window: 0), World.lightOn(elevation: degree, window: 0.5))
        XCTAssertEqual(World.lightOn(elevation: -2 * degree, window: 0.9), 0)
    }

    /// A city's tile has its lights, and is made for the share of its windows that are lit; the country's has none.
    func testTileLights() throws {
        let city = try XCTUnwrap(world.city(cell: SIMD2(0, 0)))
        let side = Double(World.tileSize)
        let tx = Int((city.center.x / side).rounded(.down)), tz = Int((city.center.y / side).rounded(.down))

        var brighter = world
        brighter.lit = 0.6
        // Far from the city: the same tile whatever the share of lit windows, and no lights.
        XCTAssertFalse(world.hasCity(x0: Double(tx + 12) * side, z0: Double(tz) * side, side: side))
        XCTAssertEqual(WorldTile.key(brighter, x: tx + 12, z: tz, level: 1), WorldTile.key(world, x: tx + 12, z: tz, level: 1))
        let country = WorldTile.build(brighter, x: tx + 12, z: tz, level: 1, flora: flora)
        assertSame(country, WorldTile.build(world, x: tx + 12, z: tz, level: 1, flora: flora), "the country")
        XCTAssertTrue(country.lights.isEmpty)
        // In it: another tile for another share.
        XCTAssertTrue(world.hasCity(x0: Double(tx) * side, z0: Double(tz) * side, side: side))
        XCTAssertNotEqual(WorldTile.key(world, x: tx, z: tz, level: 0), WorldTile.key(brighter, x: tx, z: tz, level: 0))

        func emits(_ m: GPUMaterial) -> Bool { m.emission.x + m.emission.y + m.emission.z > 0 }
        func isLamp(_ m: GPUMaterial) -> Bool { SIMD3(m.emission.x, m.emission.y, m.emission.z) == World.lampEmission }
        var emitting: [Int] = []
        for level in 0..<World.levels {
            let tile = WorldTile.build(world, x: tx, z: tz, level: level, flora: flora)
            XCTAssertFalse(tile.lights.isEmpty, "level \(level)")
            // What emits has a colour: what it looks like by day, when it is off.
            for chunk in tile.chunks where !chunk.glass {
                for m in chunk.materials where emits(m) { XCTAssertGreaterThan(m.albedo.x + m.albedo.y + m.albedo.z, 0.3) }
            }
            // Street lamps to level 1; lit windows at every level (at 2, on the buildings' boxes).
            let materials = tile.lights.map { tile.chunks[Int($0.chunk)].materials[Int($0.material)] }
            XCTAssertEqual(materials.contains(where: isLamp), level <= 1, "level \(level)")
            XCTAssertTrue(materials.contains { emits($0) && !isLamp($0) }, "level \(level)")
            // A light is the triangles of its chunk that have its material, each once, one light after the other.
            var next = 0
            for light in tile.lights {
                let chunk = tile.chunks[Int(light.chunk)], material = chunk.materials[Int(light.material)]
                XCTAssertFalse(chunk.glass)
                XCTAssertTrue(emits(material))
                XCTAssertEqual(Int(light.first), next)
                next += Int(light.count)
                XCTAssertEqual(Int(light.count), chunk.triangleMaterials.array.filter { $0 == UInt8(light.material) }.count)
                let own = tile.emissive.array[Int(light.first)..<Int(light.first + light.count)]
                XCTAssertEqual(own.last?.v0.w, 1)
                XCTAssertTrue(zip(own, own.dropFirst()).allSatisfy { $0.v0.w <= $1.v0.w }, "a running share of the light's power")
                let area = own.reduce(Float(0)) { $0 + length(cross(SIMD3($1.e1.x, $1.e1.y, $1.e1.z), SIMD3($1.e2.x, $1.e2.y, $1.e2.z))) / 2 }
                XCTAssertEqual(light.power.x, material.emission.x * area, accuracy: 1e-3 * light.power.x)
                XCTAssertGreaterThan(light.center.w, 0)
                for t in own {
                    XCTAssertLessThanOrEqual(distance(SIMD3(t.v0.x, t.v0.y, t.v0.z), SIMD3(light.center.x, light.center.y, light.center.z)),
                                             light.center.w * 1.001)
                }
            }
            XCTAssertEqual(next, tile.emissive.count)
            emitting.append(next)

            // And its file has them.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorldTests-\(UUID().uuidString).tile")
            defer { try? FileManager.default.removeItem(at: url) }
            try tile.write(to: url, key: "a night")
            let stored = try XCTUnwrap(WorldTile(url: url, key: "a night", x: tx, z: tz, level: level))
            assertSame(tile, stored, "from its file")
            XCTAssertEqual(bytes(stored.lights), bytes(tile.lights))
            XCTAssertEqual(stored.emissive.data, tile.emissive.data)
        }

        // The share of lit windows is the world's: with none, the lamps and the shops are all that is on.
        var dark = world
        dark.lit = 0
        let few = WorldTile.build(dark, x: tx, z: tz, level: 0, flora: flora)
        XCTAssertTrue(few.lights.contains { isLamp(few.chunks[Int($0.chunk)].materials[Int($0.material)]) })
        XCTAssertLessThan(few.emissive.count, emitting[0] / 2)
    }
}
