import XCTest
import simd
@testable import MetalRenderer

/// The water's data: its looks, the FFT ocean's spectrum, the water map, the terrain's rivers, the open world's
/// hydrology.
final class WaterTests: XCTestCase {
    func testSpectrumIsHermitianAndAsHighAsTheWindMakesIt() {
        var variance = 0.0
        for c in 0..<WaterWaves.cascades {
            let a = WaterSpectrum.amplitudes(cascade: c, wind: 7, direction: 0.4)
            let n = WaterWaves.size
            // Each texel's second pair is the conjugate of the first pair of the opposite wave number.
            for (i, m) in [(3, 5), (100, 7), (255, 128), (17, 200)] {
                let here = a[m * n + i], there = a[((n - m) % n) * n + (n - i) % n]
                XCTAssertEqual(here.z, there.x, accuracy: 1e-7)
                XCTAssertEqual(here.w, -there.y, accuracy: 1e-7)
            }
            variance += a.reduce(0.0) { $0 + 2 * Double($1.x * $1.x + $1.y * $1.y) }
        }
        // A 7 m/s wind over a sea grown full: waves about a metre high (significant height, 4 sigma).
        let hs = 4 * variance.squareRoot()
        XCTAssertGreaterThan(hs, 0.6)
        XCTAssertLessThan(hs, 2.0)
    }

    func testLooksAndOldDocuments() throws {
        let body = WaterBody(name: "Lake", kind: .lake, level: 2)
        XCTAssertEqual(body.appearance, WaterLook.preset(.lake))
        XCTAssertEqual(WaterBody(kind: .sea).appearance, WaterLook.preset(.ocean))
        // A document saved before water had looks and kept beds still reads.
        let json = #"{"name":"Lake","kind":"lake","level":2,"seed":[0,0],"points":[],"width":8,"depth":1.5,"material":"","color":[0.05,0.12,0.1]}"#
        let read = try JSONDecoder().decode(WaterBody.self, from: Data(json.utf8))
        XCTAssertNil(read.look)
        XCTAssertNil(read.bed)
        XCTAssertEqual(read.level, 2)
        var swamp = body
        swamp.look = .preset(.swamp)
        XCTAssertEqual(try JSONDecoder().decode(WaterBody.self, from: JSONEncoder().encode(swamp)), swamp)
        XCTAssertEqual(MemoryLayout<GPUWaterLook>.stride, 64)
        for p in WaterLook.Preset.allCases { XCTAssertGreaterThan(WaterLook.preset(p).gpu.absorption.w, 1) }
    }

    func testMapOfALevelField() {
        // Water a metre deep over flat ground at 0, inside a square of 100 m.
        let field = LevelWaterField(level: 1, look: 2, lo: [-50, -50], hi: [50, 50]) { _, _ in 0 }
        let level = WaterMap.draw(field, level: 0, origin: WaterMap.origin(level: 0, at: [0, 0]))
        let wet = level.surface.filter { $0.x > WaterMap.dry }.count
        XCTAssertEqual(Double(wet), 100 * 100, accuracy: 400)
        let middle = level.surface[WaterMap.size / 2 * WaterMap.size + WaterMap.size / 2]
        XCTAssertEqual(middle.x, 1)
        XCTAssertEqual(middle.y, 0)
        XCTAssertEqual((level.info[WaterMap.size / 2 * WaterMap.size + WaterMap.size / 2] >> 16) & 0xFF, 2)
        XCTAssertFalse(WaterMap.stale(level: 0, origin: level.origin, at: [10, 10]))
        XCTAssertTrue(WaterMap.stale(level: 0, origin: level.origin, at: [200, 0]))
    }

    func testRiverKeepsItsBedOnceCarved() {
        let field = TerrainField(base: FlatTerrainBase(grid: .square(size: 256, cells: 256)))
        var river = WaterBody(name: "River", kind: .river, points: [[-100, 0], [0, 10], [100, 0]], width: 10, depth: 2)
        let before = TerrainWater.bed(field.snapshot(), river: river)
        river.bed = before
        river.bedPoints = river.points
        var record = TerrainUndoRecord(title: "Carve")
        field.edit { s in TerrainWater.carve(&s, river: river, record: &record) }
        // Its bed as it was, though the ground under it went down; and carving again digs no deeper.
        XCTAssertEqual(TerrainWater.bed(field.snapshot(), river: river), before)
        let once = field.snapshot().height(x: 0, z: 10)
        field.edit { s in TerrainWater.carve(&s, river: river, record: &record) }
        XCTAssertEqual(field.snapshot().height(x: 0, z: 10), once, accuracy: 1e-4)
        XCTAssertEqual(once, before[1], accuracy: 0.05)
        // The water map's field: the river's surface over its bed, flowing along it.
        let s = TerrainWaterField(snapshot: field.snapshot(), bodies: [river], looks: [0])
        let w = s.water(0, 10, ground: s.ground(0, 10))
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.level ?? 0, before[1] + 1.6, accuracy: 0.05)
        XCTAssertGreaterThan(w?.flow.x ?? 0, 0.1)
        XCTAssertNil(s.water(0, 60, ground: s.ground(0, 60)))
    }

    func testScenesShapeTheirWaterIntoTheirBase() {
        let hills = NoiseTerrainBase(size: 320, cells: 160, seed: 3, relief: 9)
        let river = SceneWaterMaker.river(name: "Stream", base: hills, from: [-100, -100], to: [60, 40], width: 5, depth: 1.1, meander: 10, seed: 7)
        // The same river from the same base, its bed never running uphill.
        XCTAssertEqual(SceneWaterMaker.river(name: "Stream", base: hills, from: [-100, -100], to: [60, 40], width: 5, depth: 1.1,
                                             meander: 10, seed: 7).body.bed, river.body.bed)
        let beds = river.body.bed!
        XCTAssertTrue(zip(beds, beds.dropFirst()).allSatisfy { $0.1 <= $0.0 })
        let pond = Scene.pond(on: hills, center: [40, 30], radii: [10, 7], depth: 1.5)
        let shaped = ShapedTerrainBase(hills, shapes: TerrainShapes(bowls: [pond.bowl], channels: [river.channel]))
        XCTAssertNotEqual(shaped.fingerprint, hills.fingerprint)
        // Shaped, not added up: asked again, the same height.
        for (i, j) in [(10, 20), (80, 80), (120, 140)] { XCTAssertEqual(shaped.height(i, j), shaped.height(i, j)) }
        // The ground under the river's water along its line, and under the pond's in its middle.
        for (p, bed) in zip(river.channel.points, beds) {
            XCTAssertLessThan(SceneWaterMaker.height(shaped, p.x, p.y), bed + river.body.depth * 0.8)
        }
        XCTAssertLessThan(SceneWaterMaker.height(shaped, 40, 30), pond.body.level - 1)
    }

    func testWorldWaterIsTheSameFromAnyTile() {
        let world = World(seed: 7)
        let w = world.water
        XCTAssertLessThanOrEqual(w.seaLevel, -14)
        // The origin's city stays dry.
        if let city = world.city(cell: SIMD2(0, 0)) { XCTAssertGreaterThan(city.level, w.seaLevel + 6) }
        let square = w.contents(lo: [-6000, -6000], hi: [6000, 6000])
        let longest = square.chains.map(\.count).max() ?? 0
        print("World water: sea at \(w.seaLevel), \(square.edges.count) river steps in \(square.chains.count) chains (longest \(longest)), \(square.ponds.count) ponds")
        XCTAssertGreaterThan(square.edges.count, 20)
        // A place's ground and water, asked from a fresh world of the same seed, are the same.
        let again = World(seed: 7)
        for e in square.edges.prefix(10) {
            let p = (e.a + e.b) / 2
            XCTAssertEqual(world.height(p.x, p.y), again.height(p.x, p.y))
            // Under the river's surface there: its bed, the water over it.
            let ground = w.carve(p.x, p.y, w.natural(p.x, p.y))
            let (edges, ponds) = w.near(lo: p, hi: p)
            let s = WorldWater.sample(p.x, p.y, ground: ground, edges: edges, ponds: ponds, seaLevel: w.seaLevel, looks: (0, 1, 2))
            XCTAssertNotNil(s, "at \(p)")
            if let s, s.look == 2 { XCTAssertGreaterThan(s.level, ground) }
        }
        // Beds go down the way the rivers run.
        for e in square.edges { XCTAssertLessThanOrEqual(e.bedB, e.bedA + 1e-3) }
    }
}
