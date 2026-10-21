import AppKit
import Combine
import EngineCore
import Foundation
import MetalRenderer
import Physics
import Plants
import simd

/// What the Terrain Editor's window needs of the renderer (RendererController; a stand-in in the tests).
protocol TerrainHost: AnyObject {
    var settings: RenderSettings { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void)
    /// The renderer's terrain status, every time it changes (main thread).
    func observeTerrain(_ observer: @escaping (TerrainStatus) -> Void)
    /// Work for the renderer's terrain side, on its thread (nothing in the tests).
    func terrain(_ work: @escaping (Renderer) -> Void)
}

/// The Terrain Editor's state, on the main thread: the scene's terrain and its document (layers, generator, erosion,
/// scatter rules, water), the brush, sculpt mode, the map and the tiles selected on it. The heights and paint are the
/// renderer's (strokes in the main view, TerrainField); their undo is registered here as they are kept. Document edits
/// go to TerrainDocuments at once; one undo step each, a slider's drag one.
final class TerrainModel: ObservableObject {
    let host: TerrainHost
    let undo = UndoManager()

    enum Tab: String, CaseIterable, Identifiable {
        case brush, layers, generate, erosion, scatter, water, files
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    @Published private(set) var status = TerrainStatus()
    @Published private(set) var document: TerrainDocument?
    @Published var brush = TerrainBrush() { didSet { sendBrush() } }
    @Published var tab = Tab.brush
    /// The map: what it shows, its picture, the tiles selected on it (generators and imports work on them).
    @Published var mapView = TerrainMap.View.shaded { didSet { refreshMap() } }
    @Published private(set) var map: TerrainMap?
    @Published var selectedTiles: Set<SIMD2<Int>> = []
    /// Drags on the map are the brush's (coarse painting, sculpting from above) rather than a selection.
    @Published var mapBrush = false
    @Published var message = ""
    @Published var busy = false
    // Files.
    @Published var exportFormat = TerrainIO.Format.png16
    @Published var importLow: Float = 0
    @Published var importHigh: Float = 100
    @Published var importAdditive = false
    private var dragging = false
    private var sentBrush = TerrainBrush()
    private var dragStart: TerrainDocument?
    private var dragName = ""

    package init(host: TerrainHost) {
        self.host = host
        undo.groupsByEvent = false
        host.observeTerrain { [weak self] s in self?.received(s) }
    }

    var name: String? { status.terrain }
    var sculpting: Bool { status.active }

    // MARK: - The renderer's status

    private func received(_ s: TerrainStatus) {
        let before = status
        status = s
        if !s.message.isEmpty { message = s.message }
        // The brush changed in the view ([ ] keys): the window's follows.
        if s.brush != sentBrush && s.brush != brush && s.brush != before.brush { sentBrush = s.brush; brush = s.brush }
        for id in s.strokes { registerStroke(id) }
        if s.terrain != before.terrain {
            document = s.terrain.flatMap { TerrainDocuments.shared.document($0) }
            selectedTiles = []
            map = nil
        }
        if s.terrain != before.terrain || s.revision != before.revision || (map != nil && moved(before.camera, s.camera)) { scheduleMap() }
    }

    /// The camera went far enough that an endless terrain's map shows other tiles.
    private func moved(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        guard let map, let doc = document, let grid = TerrainDocuments.shared.entry(doc.name)?.field.grid, !grid.isFinite else { return false }
        let r = TerrainMap.region(grid, around: SIMD2(b.x, b.z))
        return r.lo != map.lo || r.hi != map.hi || simd_distance(a, b) > 1e6
    }

    // MARK: - Sculpt mode and the brush

    func setSculpting(_ on: Bool) {
        sendBrush()
        host.terrain { $0.setTerrainMode(on) }
    }

    func toggleSculpting() { setSculpting(!sculpting) }

    func sendBrush() {
        let b = brush
        guard b != sentBrush || !sculpting else { return }
        sentBrush = b
        host.terrain { $0.setTerrainBrush(b) }
    }

    func choose(_ tool: TerrainTool) {
        brush.tool = tool
        if tool.paints { brush.layer = max(brush.layer, 1) }
        if !sculpting && name != nil { setSculpting(true) }
    }

    // MARK: - The document (every edit one undo step)

    func edit(_ name: String, _ change: (inout TerrainDocument) -> Void) {
        guard var d = document else { return }
        let before = d
        change(&d)
        guard d != before else { return }
        if !dragging { registerUndo(before, name: name) } else { dragName = name }
        apply(d, before: before)
    }

    private func registerUndo(_ old: TerrainDocument, name: String) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.restore(old, name: name) }
        undo.setActionName(name)
        undo.endUndoGrouping()
    }

    private func restore(_ d: TerrainDocument, name: String) {
        guard let now = document else { return }
        undo.registerUndo(withTarget: self) { m in m.restore(now, name: name) }
        undo.setActionName(name)
        apply(d, before: now)
    }

    /// The document as it is now, to the renderer (in place); a layer's material changed (another graph), or water
    /// that is somewhere else or shaped otherwise, makes the scene again (a water's look alone the renderer takes as
    /// it is).
    private func apply(_ d: TerrainDocument, before: TerrainDocument) {
        document = d
        TerrainDocuments.shared.update(d)
        func shapes(_ w: [WaterBody]) -> [WaterBody] { w.map { var b = $0; b.look = nil; b.color = .zero; return b } }
        if d.layers.map(\.material) != before.layers.map(\.material) || shapes(d.water) != shapes(before.water) {
            host.update { $0.scene.terrainKey = UUID().uuidString }
        }
        if d.layers != before.layers && mapView == .layers { scheduleMap() }
    }

    func beginDrag() {
        guard !dragging else { return }
        dragging = true
        dragStart = document
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        if let start = dragStart, start != document { registerUndo(start, name: dragName) }
        dragStart = nil
    }

    func updateLayer(_ l: Int, _ name: String, _ change: (inout TerrainLayer) -> Void) {
        edit(name) { d in if d.layers.indices.contains(l) { change(&d.layers[l]) } }
    }

    // MARK: - Strokes' undo

    private func registerStroke(_ id: Int) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.strokeUndone(id, undo: true) }
        undo.setActionName("Terrain stroke")
        undo.endUndoGrouping()
    }

    private func strokeUndone(_ id: Int, undo isUndo: Bool) {
        host.terrain { $0.undoTerrain(id, undo: isUndo) }
        undo.registerUndo(withTarget: self) { m in m.strokeUndone(id, undo: !isUndo) }
        undo.setActionName("Terrain stroke")
    }

    // MARK: - Saving, the workshop

    /// The terrain saved (Assets/Terrains/<name>.terrain): its document and its edited tiles.
    func save() {
        guard let name else { return }
        busy = true
        message = "Saving \(name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure: String?
            do { try TerrainDocuments.shared.save(name); failure = nil } catch { failure = "\(error)" }
            DispatchQueue.main.async {
                self?.busy = false
                self?.message = failure.map { "Not saved: \($0)" } ?? "Saved \(name)"
            }
        }
    }

    var isDirty: Bool { name.map { TerrainDocuments.shared.isDirty($0) } ?? false }

    /// The terrain workshop: a terrain of its own (`size` across, from `base`).
    func showWorkshop(size: TerrainWorkshopSettings.Size, base: TerrainWorkshopSettings.Base) {
        host.update {
            $0.scene.kind = .terrain
            $0.scene.terrainWorkshop.size = size
            $0.scene.terrainWorkshop.base = base
        }
    }

    // MARK: - The map

    private var mapPending = false

    func scheduleMap() {
        guard !mapPending else { return }
        mapPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.mapPending = false
            self?.refreshMap()
        }
    }

    private var mapGeneration = 0

    func refreshMap() {
        guard let name, let entry = TerrainDocuments.shared.entry(name) else { map = nil; return }
        let snapshot = entry.field.snapshot(), layers = document?.layers ?? TerrainDocument.defaultLayers, view = mapView
        let region = TerrainMap.region(entry.field.grid, around: SIMD2(status.camera.x, status.camera.z))
        mapGeneration += 1
        let generation = mapGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let drawn = TerrainMap.draw(snapshot, layers: layers, lo: region.lo, hi: region.hi, side: 384, view: view)
            DispatchQueue.main.async {
                guard let self, generation == self.mapGeneration else { return }
                self.map = drawn
            }
        }
    }

    /// The tile under a place of the world.
    func tile(at p: SIMD2<Double>) -> SIMD2<Int>? {
        guard let name, let grid = TerrainDocuments.shared.entry(name)?.field.grid else { return nil }
        let g = grid.coordinates(p.x, p.y)
        return grid.tile(Int(g.x.rounded(.down)), Int(g.y.rounded(.down)))
    }

    func select(tile t: SIMD2<Int>, extend: Bool) {
        if extend {
            if selectedTiles.contains(t) { selectedTiles.remove(t) } else { selectedTiles.insert(t) }
        } else {
            selectedTiles = selectedTiles == [t] ? [] : [t]
        }
    }

    func flyTo(_ p: SIMD2<Double>) { host.terrain { $0.flyTerrainCamera(to: p) } }

    /// A stroke drawn on the map (the world's x, z).
    func strokeOnMap(_ points: [SIMD2<Double>]) {
        sendBrush()
        host.terrain { $0.terrainStrokeWorld(points) }
    }

    /// What generators, imports and exports work on: the selected tiles, else the whole terrain (an endless one: the
    /// tiles the map shows).
    var region: TerrainIO.Region? {
        guard let name, let grid = TerrainDocuments.shared.entry(name)?.field.grid else { return nil }
        let tiles = selectedTiles.isEmpty && !grid.isFinite ? (map?.tiles ?? []) : Array(selectedTiles)
        return TerrainIO.Region.of(grid, tiles: tiles)
    }

    // MARK: - Files

    func importHeights() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .init(filenameExtension: "exr")!, .tiff].compactMap { $0 }
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url, let region else { return }
        do {
            let picture = try TerrainIO.read(url)
            let mode: TerrainIO.ImportMode = importAdditive ? .additive(scale: importHigh - importLow) : .absolute(low: importLow, high: importHigh)
            host.terrain { $0.importTerrainHeights(picture, region: region, mode: mode) }
            message = "Imported \(url.lastPathComponent) (\(picture.width) x \(picture.height)) over \(region.size.x) x \(region.size.y) samples"
        } catch {
            message = "Not imported: \(error)"
        }
    }

    func importSplat() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = true
        panel.message = "Up to four RGBA pictures: layers 0-3, 4-7, 8-11, 12-15 (by name order)"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let region else { return }
        let urls = panel.urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(4)
        do {
            let pictures = try urls.map { try TerrainIO.readRGBA($0) }
            host.terrain { $0.importTerrainWeights(pictures, region: region) }
            message = "Imported \(pictures.count) splat maps"
        } catch {
            message = "Not imported: \(error)"
        }
    }

    func export() {
        guard let name, let entry = TerrainDocuments.shared.entry(name), let region else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let snapshot = entry.field.snapshot(), layers = document?.layers ?? TerrainDocument.defaultLayers, format = exportFormat
        let stem = folder.appendingPathComponent(TerrainDocument.slug(name))
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do {
                try TerrainIO.exportHeights(snapshot, terrain: name, region: region, to: stem.appendingPathExtension(format.fileExtension),
                                            format: format)
                _ = try TerrainIO.exportWeights(snapshot, layers: layers, region: region, to: stem)
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                self?.busy = false
                self?.message = failure.map { "Not exported: \($0)" } ?? "Exported \(stem.lastPathComponent) to \(folder.lastPathComponent)"
            }
        }
    }
}
