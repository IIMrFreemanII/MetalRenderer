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
            XCTAssertEqual(p.positions, q.positions, what, file: file, line: line)
            XCTAssertEqual(p.normals, q.normals, what, file: file, line: line)
            XCTAssertEqual(p.uvs, q.uvs, what, file: file, line: line)
            XCTAssertEqual(p.indices, q.indices, what, file: file, line: line)
            XCTAssertEqual(p.triangleMaterials, q.triangleMaterials, what, file: file, line: line)
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
        XCTAssertNotEqual(WorldTile.build(World(seed: 8), x: 3, z: -2, level: 1, flora: flora).chunks[0].positions, first.chunks[0].positions)
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
                XCTAssertTrue(ground.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.y) < 400 })
                XCTAssertTrue(ground.indices.allSatisfy { Int($0) < ground.positions.count })
                XCTAssertTrue(ground.triangleMaterials.allSatisfy { Int($0) < ground.materials.count })
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
        let anchor = world.anchor, begin = world.start
        XCTAssertEqual(anchor.x.truncatingRemainder(dividingBy: Double(World.tileSize)), 0)
        XCTAssertLessThan(abs(begin.place.x - anchor.x), 2000, "the world starts near its origin")
        XCTAssertEqual(Float(begin.place.y), world.height(begin.place.x, begin.place.z) + 1.7, accuracy: 0.01)
        let place = WorldPlace(world: world, anchor: anchor, tile: SIMD2(10, -3), middle: .zero)
        func at(_ tx: Double, _ tz: Double) -> SIMD3<Float> {   // in tiles, from the world's origin
            SIMD3(Float(tx * 256 - anchor.x), 5, Float(tz * 256 - anchor.y))
        }
        XCTAssertEqual(place.wanted(for: at(10.5, -2.5)), SIMD2(10, -3), "its middle")
        XCTAssertEqual(place.wanted(for: at(11.2, -2.5)), SIMD2(10, -3), "a fifth of a tile into the next")
        XCTAssertEqual(place.wanted(for: at(11.3, -2.5)), SIMD2(11, -3))
        XCTAssertEqual(place.wanted(for: at(9.9, -3.3)), SIMD2(10, -4))
        XCTAssertEqual(place.wanted(for: at(13.6, -6.1)), SIMD2(13, -7), "far off: straight to the camera's tile")
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
                XCTAssertTrue(chunk.indices.allSatisfy { Int($0) < chunk.positions.count })
                XCTAssertTrue(chunk.triangleMaterials.allSatisfy { Int($0) < chunk.materials.count })
                XCTAssertEqual(chunk.triangleMaterials.count * 3, chunk.indices.count)
                XCTAssertEqual(chunk.normals.count, chunk.positions.count)
                XCTAssertEqual(chunk.uvs.count, chunk.positions.count)
                XCTAssertFalse(chunk.bounds.isEmpty)
                for m in chunk.materials where m.textures.x != .max && m.textures.x != World.groundDetail { XCTAssertNotNil(World.kind(ofTexture: m.textures.x)) }
            }
            // Buildings stand on the city's ground, and are no skyscrapers of a kilometre.
            let top = tile.chunks.map(\.bounds.hi.y).max()!
            XCTAssertGreaterThan(top, city.level + 6)
            XCTAssertLessThan(top, city.level + 200)
        }
        assertSame(tiles[0], WorldTile.build(world, x: tx, z: tz, level: 0, flora: flora), "a city tile made again")
    }
}
