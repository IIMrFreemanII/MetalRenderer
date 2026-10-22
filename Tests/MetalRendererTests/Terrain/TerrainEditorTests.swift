import AppKit
import SwiftUI
import XCTest
import simd
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Plants

/// The Terrain Editor's model (with a stand-in for the renderer) and its window, drawn offscreen.
final class TerrainEditorTests: XCTestCase {
    private final class Host: TerrainHost {
        var settings = RenderSettings()
        var sent = 0
        var observer: ((TerrainStatus) -> Void)?
        func update(_ change: @escaping (inout RenderSettings) -> Void) { change(&settings) }
        func observeSettings(_ observer: @escaping (RenderSettings) -> Void) {}
        func observeTerrain(_ observer: @escaping (TerrainStatus) -> Void) { self.observer = observer }
        func terrain(_ work: @escaping (Renderer) -> Void) { sent += 1 }
    }

    /// A terrain opened under `name` (the registry's), for the model to find.
    private func open(_ name: String) -> TerrainDocuments.Entry {
        TerrainDocuments.shared.close(name)
        return TerrainDocuments.shared.open(name, base: NoiseTerrainBase(size: 512, cells: 512, seed: 4, relief: 12),
                                            document: TerrainDocument(name: name))
    }

    func testDocumentEditsAreUndoSteps() {
        let name = "terrain editor test \(UUID().uuidString)"
        let entry = open(name)
        let host = Host(), model = TerrainModel(host: host)
        host.observer?(TerrainStatus(terrain: name))
        XCTAssertEqual(model.document?.name, name)
        model.updateLayer(2, "Rock") { $0.tileMetres = 11 }
        model.edit("Add step") { $0.generator.nodes.append(GeneratorNode(kind: .terrace)) }
        XCTAssertEqual(TerrainDocuments.shared.document(name)?.layers[2].tileMetres, 11, "edits reach the renderer's documents")
        XCTAssertEqual(TerrainDocuments.shared.version(name), 2)
        model.undo.undo()
        XCTAssertEqual(model.document?.generator.nodes.count, GeneratorStack().nodes.count)
        model.undo.undo()
        XCTAssertEqual(model.document?.layers[2].tileMetres, TerrainDocument.defaultLayers[2].tileMetres)
        model.undo.redo()
        XCTAssertEqual(model.document?.layers[2].tileMetres, 11)
        // A layer's material (another graph): the scene is made again.
        let key = host.settings.scene.terrainKey
        model.updateLayer(4, "Material") { $0.material = "Red Bricks" }
        XCTAssertNotEqual(host.settings.scene.terrainKey, key)
        // Strokes the renderer kept are undo steps (undoing one asks the renderer).
        host.observer?(TerrainStatus(terrain: name, strokes: [7]))
        let sent = host.sent
        model.undo.undo()
        XCTAssertEqual(host.sent, sent + 1)
        // The map's tiles and selection.
        XCTAssertEqual(model.tile(at: [-255, -255]), SIMD2(0, 0))
        model.select(tile: SIMD2(1, 1), extend: false)
        model.select(tile: SIMD2(0, 1), extend: true)
        XCTAssertEqual(model.selectedTiles, [SIMD2(1, 1), SIMD2(0, 1)])
        XCTAssertEqual(model.region, TerrainIO.Region(lo: SIMD2(0, 256), hi: SIMD2(512, 512)))
        model.selectedTiles = []
        XCTAssertEqual(model.region, TerrainIO.Region(lo: .zero, hi: SIMD2(512, 512)), "a finite terrain: the whole of it")
        _ = entry
        TerrainDocuments.shared.close(name)
    }

    func testTheMapDraws() throws {
        let entry = open("terrain map test")
        let s = entry.field.snapshot(), r = TerrainMap.region(s.grid, around: .zero)
        for view in TerrainMap.View.allCases {
            let map = try XCTUnwrap(TerrainMap.draw(s, layers: TerrainDocument.defaultLayers, lo: r.lo, hi: r.hi, side: 64, view: view))
            XCTAssertEqual(map.image.width, 64)
            XCTAssertEqual(map.tiles.count, 4, "512 m from sample 0: tiles 0 and 1 a side")
        }
        // An endless terrain: the tiles around the camera.
        let world = TerrainField(base: FlatTerrainBase(grid: TerrainGrid(cell: 1, origin: .zero))).snapshot()
        let wr = TerrainMap.region(world.grid, around: [1000, -300], reach: 2)
        XCTAssertEqual(wr.hi - wr.lo, SIMD2(1280, 1280))
        TerrainDocuments.shared.close("terrain map test")
    }

    /// A block of heights read at once (a sector mesh's) is what the samples read one by one are: across a tile's edge,
    /// over an edited tile, a tile whose base heights are cached and one whose aren't, and `step` apart.
    func testHeightsAtOnceAreTheSamples() {
        let base = NoiseTerrainBase(size: 512, cells: 512, seed: 4, relief: 12)
        let n = base.grid.tileCells
        let edited = TerrainTile(delta: (0..<(n * n)).map { Float($0 % 97) * 0.01 })
        let s = TerrainField(base: base, tiles: [SIMD2(1, 0): edited]).snapshot()
        _ = s.baseCache.heights(SIMD2(0, 0), base: base)   // tile (0, 0) from the cache, (1, 0) from the base
        for step in [1, 3] {
            let first = SIMD2(n - 70, 10), count = SIMD2(120, 40)
            let block = s.heights(from: first, count: count, step: step)
            for b in 0..<count.y {
                for a in 0..<count.x {
                    let i = first.x + a * step, j = first.y + b * step
                    XCTAssertEqual(block[b * count.x + a], s.height(i, j), "sample (\(i), \(j)), step \(step)")
                }
            }
        }
    }

    /// TERRAIN_EDITOR_PNG=<folder>: the window drawn offscreen with each tab.
    func testPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["TERRAIN_EDITOR_PNG"] else { throw XCTSkip("TERRAIN_EDITOR_PNG not set") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "terrain editor pictures"
        _ = open(name)
        let host = Host(), model = TerrainModel(host: host)
        host.observer?(TerrainStatus(terrain: name, hover: SIMD3(12, 3.5, -40), slope: 14, camera: [-100, 30, 120]))
        model.edit("Scatter") { $0.scatter.append(ScatterRule(name: "Rocks", source: .rock(roughness: 0.5))) }
        model.edit("Water") { $0.water.append(WaterBody(name: "Lake", kind: .lake, level: 2, seed: [0, 0])) }
        model.selectedTiles = [SIMD2(1, 0)]
        let size = NSSize(width: 1320, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: TerrainView().environmentObject(model))
        window.contentView = view
        func shoot(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
        model.refreshMap()
        for (k, tab) in TerrainModel.Tab.allCases.filter({ $0 != .brush }).enumerated() {
            model.tab = tab
            if tab == .layers { model.mapView = .layers }
            if tab == .erosion { model.mapView = .slope }
            if tab == .scatter { model.choose(.paint) }
            try shoot("\(k + 1)-\(tab.rawValue)")
        }
        TerrainDocuments.shared.close(name)
    }
}
