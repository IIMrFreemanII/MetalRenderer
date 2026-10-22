import XCTest
import simd
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Landscape
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// The terrain's data: its grid, its bases, its edits, its sectors' meshes and its files.
final class TerrainDocumentTests: XCTestCase {
    /// The Forest's terrain as the scene makes it.
    private func forest(seed: UInt64 = 7) -> (Terrain, NoiseTerrainBase) {
        let flat = (center: SIMD2<Float>(0, 0), inner: Float(12), outer: Float(55))
        return (Terrain(size: 320, cells: 320, seed: seed, relief: 9, flat: flat),
                NoiseTerrainBase(size: 320, cells: 320, seed: seed, relief: 9, flat: flat))
    }

    func testNoiseBaseIsTerrainsGround() {
        let (terrain, base) = forest()
        for (i, j) in [(0, 0), (320, 320), (17, 250), (160, 160), (301, 3)] {
            XCTAssertEqual(base.height(i, j), terrain.heights[j * 321 + i], "sample \(i) \(j)")
        }
        let field = TerrainField(base: base), s = field.snapshot()
        for p in [SIMD2<Float>(-12.3, 40.45), SIMD2<Float>(100.5, -99.25), SIMD2<Float>(0, 0), SIMD2<Float>(159.9, 159.9)] {
            XCTAssertEqual(s.height(x: Double(p.x), z: Double(p.y)), terrain.height(p.x, p.y), accuracy: 1e-4, "at \(p)")
            XCTAssertEqual(simd_distance(s.normal(x: Double(p.x), z: Double(p.y)), terrain.normal(p.x, p.y)), 0, accuracy: 1e-5)
        }
    }

    func testGridTilesAndSectors() {
        let (_, base) = forest()
        let grid = base.grid
        XCTAssertEqual(grid.tiles?.count, 4)
        XCTAssertEqual(grid.tile(-1, 0), SIMD2(-1, 0))
        XCTAssertEqual(grid.tile(256, 255), SIMD2(1, 0))
        let sectors = grid.tiles!.flatMap { TerrainSector.sectors(of: $0, level: 0, grid: grid) }
        XCTAssertEqual(sectors.count, 25)   // 320 m in 64 m sectors: 5 x 5
        XCTAssertEqual(sectors.reduce(0) { $0 + $1.cells.x * $1.cells.y }, 320 * 320)
        // The open world's tiles: 16 sectors at level 0, one at the others.
        let world = TerrainGrid(cell: 1, origin: .zero)
        XCTAssertEqual(TerrainSector.sectors(of: SIMD2(-3, 5), level: 0, grid: world).count, 16)
        XCTAssertEqual(TerrainSector.sectors(of: SIMD2(-3, 5), level: 1, grid: world).map(\.cells), [SIMD2(64, 64)])
        XCTAssertEqual(TerrainSector.sectors(of: SIMD2(-3, 5), level: 2, grid: world).map(\.cells), [SIMD2(16, 16)])
    }

    /// An unedited sector is the Forest's mesh where it covers it: the same vertices and normals.
    func testSectorMeshIsTerrainsMesh() {
        let (terrain, base) = forest()
        let mesh = terrain.mesh(), s = TerrainField(base: base).snapshot()
        let style = TerrainMeshStyle(uvOrigin: base.grid.origin, uvScale: 1 / 320)
        for sector in TerrainSector.sectors(of: SIMD2(1, 0), level: 0, grid: base.grid) + TerrainSector.sectors(of: SIMD2(0, 0), level: 0, grid: base.grid).prefix(2) {
            let m = TerrainSectorMesh(s, sector: sector, style: style)
            XCTAssertEqual(m.positions.count, sector.vertexCount)
            XCTAssertEqual(m.indices.count, sector.indexCount)
            XCTAssertNil(m.materials)
            let corner = base.grid.place(base.grid.firstSample(sector.tile).x, base.grid.firstSample(sector.tile).y)
            for (k, (i, j)) in [(0, 0), (sector.cells.x, sector.cells.y), (3, 7)].enumerated() {
                let v = j * (sector.cells.x + 1) + i
                let gi = sector.first.x + i, gj = sector.first.y + j
                let reference = gj * 321 + gi
                let world = m.positions[v] + SIMD3(Float(corner.x), 0, Float(corner.y))
                XCTAssertEqual(simd_distance(world, mesh.positions[reference]), 0, accuracy: 1e-4, "vertex \(k) of \(sector)")
                XCTAssertEqual(simd_distance(m.normals[v], mesh.normals[reference]), 0, accuracy: 1e-5)
                XCTAssertEqual(simd_distance(m.uvs[v], mesh.uvs[reference]), 0, accuracy: 1e-5)
            }
        }
    }

    func testEditsRevisionsAndRestore() {
        let (_, base) = forest()
        let field = TerrainField(base: base)
        let before = field.snapshot()
        let touched = field.edit { s in
            var tile = s.tiles[SIMD2(0, 0)] ?? TerrainTile(cells: 256)
            tile.delta[10 * 256 + 20] = 3
            s.tiles[SIMD2(0, 0)] = tile
            return [SIMD2(0, 0)]
        }
        XCTAssertEqual(touched, [SIMD2(0, 0)])
        let after = field.snapshot()
        XCTAssertEqual(after.height(20, 10), before.height(20, 10) + 3)
        XCTAssertEqual(before.delta(20, 10), 0, "a snapshot keeps what it was")
        XCTAssertEqual(field.revision, 1)
        let sector = TerrainSector.sectors(of: SIMD2(0, 0), level: 0, grid: base.grid)[0]
        XCTAssertEqual(after.revision(around: sector), 1)
        // (A sector reads the ring of samples around it: the Forest's all touch tile (0, 0). On an endless grid one
        // two tiles away doesn't.)
        let endless = TerrainField(base: FlatTerrainBase(grid: TerrainGrid(cell: 1, origin: .zero)))
        endless.edit { s in s.tiles[SIMD2(0, 0)] = TerrainTile(cells: 256); return [SIMD2(0, 0)] }
        let far = TerrainSector.sectors(of: SIMD2(2, 0), level: 0, grid: endless.grid)[0]
        let near = TerrainSector.sectors(of: SIMD2(1, 0), level: 0, grid: endless.grid)[0]
        XCTAssertEqual(endless.snapshot().revision(around: far), 0)
        XCTAssertEqual(endless.snapshot().revision(around: near), 1)
        field.restore([SIMD2(0, 0): nil])
        XCTAssertEqual(field.snapshot().height(20, 10), before.height(20, 10))
        XCTAssertEqual(field.snapshot().revision(around: sector), 2, "an undone tile is a change too")
    }

    func testRaycastFindsTheGround() {
        let (terrain, base) = forest()
        let s = TerrainField(base: base).snapshot()
        let origin = SIMD3<Double>(-80, 60, -70), target = SIMD3<Double>(30, Double(terrain.height(30, 40)), 40)
        let hit = s.raycast(origin: origin, direction: SIMD3<Float>(target - origin))
        XCTAssertNotNil(hit)
        if let hit { XCTAssertEqual(simd_distance(hit.point, target), 0, accuracy: 0.05) }
        XCTAssertNil(s.raycast(origin: origin, direction: [0, 1, 0]), "up into the sky")
    }

    func testStoreRoundTrip() throws {
        let (_, base) = forest()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terrain-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let field = TerrainField(base: base)
        field.edit { s in
            var t = TerrainTile(cells: 256)
            t.delta[5] = -1.25
            t.paint = [UInt8](repeating: 0, count: 256 * 256 * 16)
            t.paint![16 * 7 + 3] = 200
            t.mask = [UInt8](repeating: 0, count: 256 * 256)
            t.mask![7] = 255
            s.tiles[SIMD2(1, 1)] = t
            s.tiles[SIMD2(0, 1)] = TerrainTile(cells: 256)   // empty: not written
            return [SIMD2(1, 1), SIMD2(0, 1)]
        }
        var doc = TerrainDocument(name: "forest test")
        doc.layers[2].tileMetres = 9
        doc.water.append(WaterBody(name: "Pond", kind: .lake, level: -1, seed: SIMD2(3, 4)))
        try TerrainStore.save(doc, snapshot: field.snapshot(), in: folder)
        let loaded = try XCTUnwrap(TerrainStore.load("forest test", base: base, in: folder))
        XCTAssertEqual(loaded.document, doc)
        XCTAssertEqual(Set(loaded.tiles.keys), [SIMD2(1, 1)])
        XCTAssertEqual(loaded.tiles[SIMD2(1, 1)]?.delta, field.snapshot().tiles[SIMD2(1, 1)]?.delta)
        XCTAssertEqual(loaded.tiles[SIMD2(1, 1)]?.paint?[16 * 7 + 3], 200)
        // Over another ground: the document, none of the edits.
        let (_, other) = forest(seed: 8)
        XCTAssertEqual(TerrainStore.load("forest test", base: other, in: folder)?.tiles.count, 0)
    }

    func testRuleWeights() {
        let rock = TerrainDocument.defaultLayers[2].rule
        XCTAssertEqual(rock.weight(height: 0, slope: 10, noise: 0), 0)
        XCTAssertEqual(rock.weight(height: 0, slope: 60, noise: 0), 1)
        XCTAssertEqual(rock.weight(height: 0, slope: 36, noise: 0), 0.5, accuracy: 1e-5)
    }
}

/// Heightmaps and splat maps in and out (TerrainIO).
final class TerrainIOTests: XCTestCase {
    private func field() -> TerrainField {
        TerrainField(base: NoiseTerrainBase(size: 128, cells: 128, seed: 3, relief: 8))
    }

    func testHeightsRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terrain-io-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for format in TerrainIO.Format.allCases {
            let source = field(), s = source.snapshot()
            let region = TerrainIO.Region.of(s.grid, tiles: [])!
            let url = folder.appendingPathComponent("h.\(format.fileExtension)")
            let side = try TerrainIO.exportHeights(s, terrain: "t", region: region, to: url, format: format)
            // Into a flat terrain of the same grid: the same heights, to a 16-bit step (EXR: exactly).
            let target = TerrainField(base: FlatTerrainBase(grid: s.grid))
            let picture = try TerrainIO.read(url)
            XCTAssertEqual(picture.width, 129)
            var record = TerrainUndoRecord()
            target.edit { t in TerrainIO.importHeights(&t, picture: picture, region: region, mode: .absolute(low: side.low, high: side.high),
                                                       record: &record) }
            let step = (side.high - side.low) / 65535 * 1.01
            let back = target.snapshot()
            for (i, j) in [(0, 0), (128, 128), (37, 91), (64, 3)] {
                XCTAssertEqual(back.height(i, j), s.height(i, j), accuracy: format == .exr ? 1e-4 : step, "\(format) \(i) \(j)")
            }
            XCTAssertFalse(record.before.isEmpty)
        }
    }

    func testWeightsRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terrain-io-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let f = field()
        var record = TerrainUndoRecord()
        f.edit { s in TerrainPaint.dab(&s, brush: TerrainBrush(tool: .paint, radius: 20, strength: 1, layer: 6),
                                       dab: TerrainDab(center: [0, 0], amount: 1), layers: TerrainDocument.sceneLayers(), record: &record) }
        let s = f.snapshot(), region = TerrainIO.Region.of(s.grid, tiles: [])!
        let urls = try TerrainIO.exportWeights(s, layers: TerrainDocument.sceneLayers(), region: region, to: folder.appendingPathComponent("w"))
        XCTAssertEqual(urls.count, 4)
        let pictures = try urls.map { try TerrainIO.readRGBA($0) }
        let target = TerrainField(base: s.base)
        var r2 = TerrainUndoRecord()
        target.edit { t in TerrainIO.importWeights(&t, pictures: pictures, region: region, record: &r2) }
        let middle = target.snapshot().paint(64, 64)
        XCTAssertNotNil(middle)
        XCTAssertGreaterThan(Int(middle!.weights[6]), 200, "the painted layer where it was painted")
        XCTAssertGreaterThan(Int(target.snapshot().paint(2, 2)!.weights[0]), 250, "the ground's own away from it")
    }
}

/// The generator and erosion (TerrainGenerator, TerrainErosion).
final class TerrainErosionTests: XCTestCase {
    func testThermalKeepsTheEarth() {
        let w = 48, h = 40
        var b = (0..<(w * h)).map { k -> Float in
            let i = k % w, j = k / w
            return Float(max(0, 20 - abs(i - 24) - abs(j - 20))) * 2   // a steep pyramid
        }
        let before = b.reduce(0, +), peak = b.max()!
        var e = ErosionSettings()
        e.talus = 30
        TerrainErosion.thermal(&b, w: w, h: h, cell: 1, settings: e, iterations: 200)
        XCTAssertEqual(b.reduce(0, +), before, accuracy: before * 1e-4, "what crumbles goes to the neighbours")
        XCTAssertLessThan(b.max()!, peak)
        // No slope steeper than about the talus remains between neighbours.
        var steepest: Float = 0
        for j in 0..<h { for i in 0..<(w - 1) { steepest = max(steepest, abs(b[j * w + i + 1] - b[j * w + i])) } }
        XCTAssertLessThan(steepest, 1.3, "from the pyramid's 2 toward the talus")
    }

    func testHydraulicCarvesAndStaysFinite() {
        let w = 64, h = 64
        var b = (0..<(w * h)).map { k -> Float in
            let i = Float(k % w), j = Float(k / w)
            return 30 - 0.3 * j + 2 * sin(i * 0.4) + Terrain.noise(SIMD2(i, j) / 6, seed: 3) * 3
        }
        let before = b
        var e = ErosionSettings()
        e.hydraulicIterations = 120
        TerrainErosion.hydraulic(&b, w: w, h: h, cell: 1, settings: e, iterations: 120)
        XCTAssertTrue(b.allSatisfy(\.isFinite))
        let moved = zip(b, before).map { abs($0 - $1) }.reduce(0, +) / Float(b.count)
        XCTAssertGreaterThan(moved, 0.001, "the water moved earth")
        XCTAssertLessThan(moved, 3, "and not wildly")
        XCTAssertEqual(b.reduce(0, +), before.reduce(0, +), accuracy: before.reduce(0, +) * 0.002, "earth is carried, not lost")
    }

    func testTheGeneratorRunsOverARegion() {
        let field = TerrainField(base: FlatTerrainBase(grid: .square(size: 256, cells: 256)))
        var stack = GeneratorStack()
        stack.nodes = [GeneratorNode(kind: .ridged, amplitude: 50, scale: 80, octaves: 4, seed: 2), GeneratorNode(kind: .terrace, amplitude: 5)]
        var record = TerrainUndoRecord()
        field.edit { s in TerrainGenerator.run(&s, stack: stack, lo: .zero, hi: SIMD2(256, 256), border: 0, record: &record) }
        let s = field.snapshot()
        let heights = (0..<50).map { s.height($0 * 5, 128) }
        XCTAssertGreaterThan(heights.max()! - heights.min()!, 5)
        XCTAssertEqual(s.height(100, 100), TerrainGenerator.height(stack, x: s.grid.place(100, 100).x, z: s.grid.place(100, 100).y, ground: 0),
                       accuracy: 1e-4)
        // Faded at a region's edge: its border's samples keep the ground.
        let f2 = TerrainField(base: FlatTerrainBase(grid: .square(size: 256, cells: 256)))
        f2.edit { s in TerrainGenerator.run(&s, stack: stack, lo: SIMD2(64, 64), hi: SIMD2(192, 192), border: 20, record: &record) }
        XCTAssertEqual(f2.snapshot().height(64, 100), 0)
        XCTAssertEqual(f2.snapshot().height(30, 30), 0)
    }
}
