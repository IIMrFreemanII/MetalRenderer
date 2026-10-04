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
                for m in chunk.materials where m.textures.x != .max && m.textures.x != World.groundDetail { XCTAssertNotNil(World.kind(ofTexture: m.textures.x)) }
            }
            // Buildings stand on the city's ground, and are no skyscrapers of a kilometre.
            let top = tile.chunks.map(\.bounds.hi.y).max()!
            XCTAssertGreaterThan(top, city.level + 6)
            XCTAssertLessThan(top, city.level + 200)
        }
        assertSame(tiles[0], WorldTile.build(world, x: tx, z: tz, level: 0, flora: flora), "a city tile made again")
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
