import Metal
import XCTest
import simd
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
}
