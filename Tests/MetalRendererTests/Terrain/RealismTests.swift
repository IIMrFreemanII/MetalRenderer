import Metal
import XCTest
import simd
@testable import Game
@testable import MetalRenderer

/// The realistic look (SceneSettings.realism): its ground maps, the terrain's table, the scans' names, and that the
/// scenes it changes stay their seed's (with or without the scans in Assets/Textures).
final class RealismTests: XCTestCase {
    /// A map's weights are normalised per texel, layers 0...3 in the first texture, 4...7 in the second.
    func testGroundMapsAreNormalised() {
        let look = GroundLook(layers: (0..<6).map { GroundLook.Layer(set: "x\($0)", color: .one) }, lo: [-10, -10], size: [20, 20],
                              texels: 16, key: "test") { x, z in [1, 0.5, 0, max(x, 0), 0, 2 * max(z, 0)] }
        let (a, b) = look.draw()
        for i in 0..<(16 * 16) {
            let sum = (0..<4).reduce(0) { $0 + Int(a.pixels[i * 4 + $1]) } + (0..<2).reduce(0) { $0 + Int(b.pixels[i * 4 + $1]) }
            XCTAssertEqual(Double(sum), 255, accuracy: 4)
            XCTAssertEqual(b.pixels[i * 4 + 2], 0)
        }
    }

    /// Off, the table is the layers' as it always was (15 in its header); on, 16, and the scene's ground rows after it.
    func testTheTableSaysTheLook() {
        let layers = TerrainDocument.sceneLayers()
        let plain = SceneTerrain.table(layers, firstLayer: 3, offset: .zero)
        XCTAssertEqual(plain.count, TerrainTile.layers)
        XCTAssertEqual(plain[0].w, 15)
        var g = GroundRows()
        g.materials = [7, 8]
        g.metres = [2, 4]
        g.contrast = [1, 0.5]
        g.rock = 1
        let real = SceneTerrain.table(layers, firstLayer: 3, offset: .zero, realistic: true, ground: g, macro: 5)
        XCTAssertEqual(real[0].w, 16)
        XCTAssertEqual(real.count, TerrainTile.layers + 3 + 2)
        XCTAssertEqual(real[16], SIMD4(2, -1, -1, 5))
        XCTAssertEqual(real[18].x, 1)
        XCTAssertEqual(real[20], SIMD4(8, 0.25, 0.5, 1))
    }

    /// Layers wear the scans their names say; an old document (no textureSet) reads as before.
    func testLayersNameTheirScans() throws {
        XCTAssertEqual(TerrainLayer(name: "Rock").scanSet, "rock")
        XCTAssertEqual(TerrainLayer(name: "Dry grass").scanSet, "dry-grass")
        XCTAssertEqual(TerrainLayer(name: "Litter").scanSet, "forest-floor")
        XCTAssertNil(TerrainLayer(name: "Layer 12").scanSet)
        var none = TerrainLayer(name: "Rock")
        none.textureSet = ""
        XCTAssertNil(none.scanSet)
        let old = #"{"name":"Rock","material":"","color":[0.3,0.3,0.3],"roughness":0.8,"tileMetres":6,"rule":{"enabled":false}}"#
        if let layer = try? JSONDecoder().decode(TerrainLayer.self, from: Data(old.utf8)) {
            XCTAssertNil(layer.textureSet)
            XCTAssertEqual(layer.scanSet, "rock")
        }
        let round = try JSONDecoder().decode(TerrainLayer.self, from: JSONEncoder().encode(none))
        XCTAssertEqual(round.textureSet, "")
    }

    /// The realistic forest: its ground made of its map's layers, its rocks; the same twice; off, none of it.
    func testTheRealisticForestIsItsSeed() {
        var settings = SceneSettings(kind: .forest)
        settings.trees = 40
        settings.undergrowth = 10
        settings.realism = .on
        let a = Scene(settings), b = Scene(settings)
        XCTAssertEqual(a.terrain?.realistic, true)
        XCTAssertEqual(a.terrain?.ground?.materials.count, 8)
        XCTAssertNotEqual(a.terrain?.ground?.mapB, .max)
        XCTAssertEqual(a.instances.count, b.instances.count)
        XCTAssertTrue(zip(a.instances, b.instances).allSatisfy { $0.transform == $1.transform && $0.material == $1.material })
        XCTAssertTrue(a.meshNames.values.contains { $0.hasPrefix("rock-") })
        settings.realism = .off
        let off = Scene(settings)
        XCTAssertEqual(off.terrain?.realistic, false)
        XCTAssertNil(off.terrain?.ground)
        XCTAssertFalse(off.meshNames.values.contains { $0.hasPrefix("rock-") })
        XCTAssertLessThan(off.instances.count, a.instances.count)
    }

    /// A boulder is closed, finite and sits on its foot.
    func testBouldersAreSound() {
        for seed in 0..<4 {
            let (mesh, uvs) = Scene.boulder(seed: UInt64(seed))
            XCTAssertEqual(mesh.positions.count, uvs.count)
            XCTAssertTrue(mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_length($0) < 1.6 })
            XCTAssertGreaterThan(mesh.positions.map(\.y).min()!, -0.3)
            XCTAssertTrue(mesh.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-3 })
        }
    }

    /// The exposure meter settles on a scene's middle grey: a histogram all at one luminance gives key / luminance.
    func testAutoExposureFindsMiddleGrey() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let meter = AutoExposure(device: device, framesInFlight: 2)
        // Luminance 2^-2: its bin.
        let bin = Int((Float(-2) - AutoExposure.logMin) / (AutoExposure.logMax - AutoExposure.logMin) * Float(AutoExposure.bins))
        var e: Float = 1
        for _ in 0..<4 {
            _ = meter.next()   // (moves to the next histogram)
        }
        for _ in 0..<3 {
            // The histogram the next frame reads: fill it.
            let next = meter.peekNext()
            let h = next.contents().bindMemory(to: UInt32.self, capacity: AutoExposure.bins)
            h[bin] = 1000
            e = meter.next()
        }
        let step = (AutoExposure.logMax - AutoExposure.logMin) / Float(AutoExposure.bins)
        let measured = exp2(AutoExposure.logMin + (Float(bin) + 0.5) * step)
        XCTAssertEqual(log2(e), log2(AutoExposure.key / measured), accuracy: 0.6)
    }

    /// Fills the histogram the meter reads next with 1000 pixels at log2 luminance `l`, and returns its exposure.
    private func meter(_ meter: AutoExposure, at l: Float, dt: Float = 1.0 / 60) -> Float {
        let bin = Int((l - AutoExposure.logMin) / (AutoExposure.logMax - AutoExposure.logMin) * Float(AutoExposure.bins))
        let h = meter.peekNext().contents().bindMemory(to: UInt32.self, capacity: AutoExposure.bins)
        h[bin] = 1000
        return meter.next(dt: dt)
    }

    /// A very dark view (a storeroom lit only through its door) opens the exposure past 2^6 only half as fast, and no
    /// further than 2^limit.
    func testAutoExposureOpensDarkRoomsPartly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let m = AutoExposure(device: device, framesInFlight: 2)
        for _ in 0..<4 { _ = m.next() }
        var e: Float = 1
        for _ in 0..<3 { e = meter(m, at: -10) }   // the first measure is taken at once
        let full = log2(AutoExposure.key) + 10
        XCTAssertGreaterThan(log2(e), AutoExposure.fullLimit)
        XCTAssertEqual(log2(e), AutoExposure.fullLimit + (full - AutoExposure.fullLimit) / 2, accuracy: 0.4)
        for _ in 0..<3 { e = meter(m, at: -14) }
        XCTAssertLessThanOrEqual(log2(e), AutoExposure.limit + 1e-3)
    }

    /// The exposure eases by the clock: four frames of 1/60 s go as far as one of 4/60 s; it closes down (a brighter
    /// view) faster than it opens up.
    func testAutoExposureEasesByTheClock() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        func settled(at l: Float) -> AutoExposure {
            let m = AutoExposure(device: device, framesInFlight: 2)
            for _ in 0..<4 { _ = m.next() }
            for _ in 0..<3 { _ = meter(m, at: l) }
            return m
        }
        // From a settled -2 to a view 3 stops darker: four short frames vs one long one.
        let a = settled(at: -2), b = settled(at: -2)
        var ea: Float = 0
        for _ in 0..<4 { ea = meter(a, at: -5) }
        let eb = meter(b, at: -5, dt: 4.0 / 60)
        XCTAssertEqual(log2(ea), log2(eb), accuracy: 0.05)
        // The same 3 stops brighter instead: a larger step toward its target.
        let c = settled(at: -2), start = log2(meter(c, at: -2))
        let up = log2(eb) - start, down = start - log2(meter(c, at: 1, dt: 4.0 / 60))
        XCTAssertGreaterThan(down, up * 1.5)
    }

    /// Realism high's fine sectors: as many vertices as counted, and their seam sides on the coarse sector's
    /// triangles (no crack) where the relief and the smoothing fade out.
    func testFineSectorsMeetTheCoarseOnes() {
        let base = NoiseTerrainBase(size: 128, cells: 128, seed: 3, relief: 6)
        let entry = Scene.openTerrain("realism-fine-test", base: base, layers: TerrainDocument.sceneLayers())
        let s = entry.field.snapshot(), grid = entry.field.grid
        guard var sector = grid.tiles.flatMap({ TerrainSector.sectors(of: $0[0], level: 0, grid: grid).first }) else { return XCTFail("no sector") }
        let coarse = TerrainSectorMesh(s, sector: sector, style: TerrainMeshStyle())
        sector.subdiv = 4
        sector.seams = 0b1111
        let fine = TerrainSectorMesh(s, sector: sector, style: TerrainMeshStyle())
        XCTAssertEqual(fine.positions.count, sector.vertexCount)
        XCTAssertEqual(fine.indices.count, sector.indexCount)
        XCTAssertEqual(fine.weights.count, fine.positions.count)
        let n = sector.cells.x + 1
        for a in 0...sector.quads.x {   // its -z side: on the coarse edges between the samples
            let i = min(a / 4, sector.cells.x - 1), t = Float(a - i * 4) / 4
            let expected = coarse.positions[i].y + (coarse.positions[i + 1].y - coarse.positions[i].y) * t
            XCTAssertEqual(fine.positions[a].y, expected, accuracy: 1e-3)
        }
        XCTAssertLessThan(n, sector.quads.x + 1)
        // Inside, smooth: not on the coarse planes everywhere.
        let middle = (sector.quads.y / 2) * (sector.quads.x + 1) + sector.quads.x / 2 + 1
        XCTAssertTrue(fine.positions[middle].y.isFinite)
    }

    /// A layer without a scan has no relief; one with a flat scan neither (its height at the middle).
    func testPlainGroundHasNoRelief() {
        let flat = TextureSet.HeightField(side: 2, values: [0.5, 0.5, 0.5, 0.5])
        let relief = GroundRelief(ground: [.init(height: nil, scale: 1, contrast: 1, relief: 0.3), .init(height: flat, scale: 1, contrast: 1, relief: 0.3)],
                                  painted: [], maps: nil, lo: .zero, size: [10, 10], rock: -1, slope: [0.6, 0.8], offset: .zero)
        var w = SIMD16<Float>()
        w[0] = 1
        XCTAssertEqual(relief(x: 3, z: 4, up: 1, weights: w), 0)
        let bumpy = TextureSet.HeightField(side: 2, values: [0, 1, 1, 0])
        XCTAssertNotEqual(bumpy.sample(0.25, 0.25), bumpy.sample(0.75, 0.25))
        XCTAssertEqual(bumpy.sample(0.25, 0.25), bumpy.sample(1.25, 0.25), accuracy: 1e-6)   // (it wraps)
    }

    /// Realism high's bark: denser trunks, built at the size they were counted (Foliage.build checks), pushed out
    /// no more than 15% of a radius; without it the plant as before.
    func testBarkReliefBuildsItsCountedMesh() {
        let ridges = TextureSet.HeightField(side: 4, values: (0..<16).map { Float($0 % 4) / 3 })
        let plain = Foliage.plant(.dead, age: .mature, seed: 7, palette: [])
        let rough = Foliage.plant(PlantCatalog.builtIn[.dead], .dead, age: .mature, seed: 7, palette: [],
                                  bark: Foliage.Bark(height: ridges, relief: 0.03))
        XCTAssertGreaterThan(rough.meshes[0].positions.count, plain.meshes[0].positions.count)
        XCTAssertTrue(rough.meshes[0].positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        let again = Foliage.plant(.dead, age: .mature, seed: 7, palette: [])
        XCTAssertEqual(plain.meshes[0].positions, again.meshes[0].positions)
    }

    /// Realism on keeps the plants' names (their meshes, structures and voxel caches are main's); only high's bark
    /// renames them.
    func testOnlyHighRenamesThePlants() {
        func names(_ r: Realism) -> Set<String> {
            var settings = SceneSettings(kind: .forest)
            settings.trees = 20
            settings.undergrowth = 5
            settings.plantCatalog = "builtin"
            settings.realism = r
            return Set(Scene(settings).meshNames.values.filter { $0.hasPrefix("plants v") })
        }
        let off = names(.off)
        XCTAssertFalse(off.isEmpty)
        XCTAssertEqual(off, names(.on))
        if TextureSet.find("bark-oak") != nil { XCTAssertTrue(off.isDisjoint(with: names(.high))) }
    }

    /// Realism high reads the ground map on the CPU at every make; the workshop, made again at every edit, takes it
    /// from the last make's instead of drawing it again.
    func testHighWorkshopIsMadeAgainQuickly() {
        var settings = SceneSettings(kind: .plants)
        settings.plantCatalog = "builtin"
        settings.realism = .high
        _ = Scene(settings)
        settings.plants.variant = 1
        let start = Date()
        let again = Scene(settings)
        let seconds = Date().timeIntervalSince(start)
        print("Realism high workshop made again in \(Int(seconds * 1000)) ms")
        XCTAssertNotNil(again.terrain?.ground)
        XCTAssertLessThan(seconds, 1.2)
    }
}
