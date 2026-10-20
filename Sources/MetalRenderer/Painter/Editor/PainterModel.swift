import AppKit
import Combine
import Foundation
import simd

/// What the Material Painter's window needs of the renderer (RendererController; a stand-in in the tests).
protocol PainterHost: AnyObject {
    var settings: RenderSettings { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void)
    /// Click-to-pick (the Material Designer's): the next click in the view names what is under it.
    func pickMaterial(_ picked: @escaping (MaterialPick?) -> Void)
    func cancelPick()
    /// The renderer's painter status, every time it changes (main thread).
    func observePainter(_ observer: @escaping (PainterStatus) -> Void)
    /// Work for the renderer's painter, on its thread (nothing in the tests).
    func painter(_ work: @escaping (Renderer) -> Void)
    /// Instance `i`'s paint fingerprint and whether it can be painted, from the scene shown (main thread).
    func paintInfo(_ instance: Int, _ answer: @escaping (_ fingerprint: String?) -> Void)
}

/// The Material Painter's state, on the main thread: the painted objects of the scene shown and the one being edited,
/// its document (layers, bottom first), the selected layer and what of it a stroke paints, the brush and tool, and
/// paint mode. Every edit of the layers goes to the renderer's sessions at once (PaintDocuments); strokes are the
/// renderer's (paint mode: dragging in the main view), their undo registered here as they are kept. One undo step per
/// edit; a slider's drag is one.
final class PainterModel: ObservableObject {
    let host: PainterHost
    let undo = UndoManager()

    @Published private(set) var status = PainterStatus()
    /// The painted object edited (its index in the renderer's status), and its document.
    @Published var object: Int?
    @Published private(set) var document: PaintDocument?
    @Published var selectedLayer: UUID?
    /// What a stroke paints of the selected layer: its channels, or its mask.
    @Published var paintsMask = false
    @Published var brush = PaintBrush() { didSet { sendBrush() } }
    @Published var tool = PaintTool.brush { didSet { sendBrush() } }
    @Published private(set) var painting = false
    @Published var picking = false
    @Published var message = ""
    /// The centre view: which of the set it shows, and its picture (the renderer's, made on request).
    @Published var view = "basecolor"
    @Published private(set) var picture: CGImage?
    @Published private(set) var thumbnails: [UUID: CGImage] = [:]
    @Published var exportFormat = MatExport.Format.png8
    private var dragging = false

    init(host: PainterHost) {
        self.host = host
        undo.groupsByEvent = false
        host.observePainter { [weak self] s in self?.received(s) }
    }

    // MARK: - The renderer's status

    private func received(_ s: PainterStatus) {
        let before = status
        status = s
        if !s.message.isEmpty { message = s.message }
        for id in s.strokes { registerStroke(id) }
        if object == nil || !(s.objects.indices.contains(object ?? -1)) { object = s.objects.isEmpty ? nil : 0 }
        if let k = object, k < s.objects.count, document?.name != s.objects[k].document { open(s.objects[k].document) }
        painting = s.active != nil
        if before.objects != s.objects { refreshPictures() }
    }

    private func open(_ name: String) {
        document = PaintDocuments.shared.document(name)
        selectedLayer = document?.layers.last?.id
        sendBrush()
        refreshPictures()
    }

    var currentObject: PainterStatus.Object? { object.flatMap { status.objects.indices.contains($0) ? status.objects[$0] : nil } }
    var selected: PaintLayer? { document?.layers.first { $0.id == selectedLayer } }

    // MARK: - Objects

    /// The next click in the view picks what the painter paints: its instance gets a document of its own (named after
    /// the scene and the instance) and the scene is made again with it painted.
    func pickObject() {
        picking = true
        host.pickMaterial { [weak self] p in
            guard let self else { return }
            self.picking = false
            guard let p else { return }
            self.host.paintInfo(p.instance) { fingerprint in
                guard let fingerprint else { self.message = "That can't be painted (not a mesh of its own)"; return }
                self.assign(instance: p.instance, fingerprint: fingerprint, document: self.documentName(for: p.instance))
            }
        }
    }

    func cancelPick() { host.cancelPick(); picking = false }

    func documentName(for instance: Int) -> String {
        "\(MaterialAssignments.scope(host.settings.scene).replacingOccurrences(of: ",", with: " ")) object \(instance)"
    }

    /// `instance` painted with `document` (nil: no longer painted) in the scene shown: the assignments' new key.
    func assign(instance: Int, fingerprint: String, document: String?) {
        var a = PaintAssignments.resolve(host.settings.scene.paintAssignments)
        a.set(host.settings.scene, instance: instance, fingerprint: fingerprint, document: document)
        let key = PaintAssignments.register(a)
        host.update { $0.scene.paintAssignments = key }
        message = document.map { "Painting \($0)" } ?? "Unpainted"
    }

    /// The painter workshop with this object (a shape, the character, a model): the scene is made again.
    func showInWorkshop(_ subject: PainterWorkshopSettings.Subject) {
        host.update {
            $0.scene.kind = .painter
            $0.scene.painterWorkshop.subject = subject
        }
    }

    // MARK: - Paint mode

    func togglePaintMode() { setPaintMode(!painting) }

    func setPaintMode(_ on: Bool) {
        let k = on ? object : nil
        sendBrush()
        host.painter { $0.setPaintMode(k) }
    }

    func sendBrush() {
        let b = brush, layer = selectedLayer, tool = tool
        let target: PaintTarget = paintsMask ? .mask : .channels(b.channels)
        host.painter { $0.setPainterBrush(b, layer: layer, target: target, tool: tool) }
    }

    func selectLayer(_ id: UUID?) {
        selectedLayer = id
        if let l = selected, l.kind == .fill { paintsMask = true }
        sendBrush()
    }

    // MARK: - Layers (every edit one undo step)

    /// Changes the document as `change` says: one undo step (a drag's changes, while it lasts, are one).
    func edit(_ name: String, _ change: (inout PaintDocument) -> Void) {
        guard var d = document else { return }
        let before = d
        change(&d)
        guard d != before else { return }
        if !dragging { registerUndo(before, name: name) } else { dragName = name }
        apply(d, structure: before)
    }

    private func registerUndo(_ old: PaintDocument, name: String) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.restore(old, name: name) }
        undo.setActionName(name)
        undo.endUndoGrouping()
    }

    private func restore(_ d: PaintDocument, name: String) {
        guard let now = document else { return }
        undo.registerUndo(withTarget: self) { m in m.restore(now, name: name) }
        undo.setActionName(name)
        apply(d, structure: now)
    }

    /// The document as it now is, to the renderer; a change of what the scene is made for (holes, emission, the
    /// set's size) makes the scene again.
    private func apply(_ d: PaintDocument, structure before: PaintDocument) {
        document = d
        PaintDocuments.shared.update(d)
        if d.opacity != before.opacity || d.emissive != before.emissive || d.resolution != before.resolution {
            // The same assignments under a new key: the scene is made again with the document's new shape.
            var a = PaintAssignments.resolve(host.settings.scene.paintAssignments)
            a.revision = (a.revision ?? 0) + 1
            let key = PaintAssignments.register(a)
            host.update { $0.scene.paintAssignments = key }
        }
        if selectedLayer == nil || !d.layers.contains(where: { $0.id == selectedLayer }) { selectedLayer = d.layers.last?.id }
        sendBrush()
        schedulePictures()
    }

    private var dragStart: PaintDocument?
    private var dragName = ""

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

    func addFill() {
        let layer = PaintLayer.fill("Fill \(document?.layers.count ?? 0)", PaintValues(color: [0.7, 0.7, 0.7], roughness: 0.5), channels: [.color, .roughness])
        insert([layer], name: "Add fill layer")
    }

    func addPaint() {
        var layer = PaintLayer(name: "Paint \(document?.layers.count ?? 0)")
        layer.channels = [.color, .roughness, .metallic, .height]
        insert([layer], name: "Add paint layer")
        paintsMask = false
    }

    /// A paint layer filled from the object as it was (its own textures), above the base.
    func addOriginal() {
        var layer = PaintLayer(name: "As it was")
        layer.channels = [.color, .roughness, .metallic]
        layer.source = "original"
        insert([layer], name: "Add the object as it was")
    }

    func addSmart(_ m: SmartMaterial) { insert(m.instantiate(), name: "Add \(m.name)") }

    private func insert(_ layers: [PaintLayer], name: String) {
        edit(name) { d in
            let at = selectedLayer.flatMap { id in d.layers.firstIndex { $0.id == id } }.map { $0 + 1 } ?? d.layers.count
            d.layers.insert(contentsOf: layers, at: min(at, d.layers.count))
        }
        selectLayer(layers.last?.id)
    }

    func deleteLayer() {
        guard let id = selectedLayer else { return }
        edit("Delete layer") { $0.layers.removeAll { $0.id == id } }
    }

    func duplicateLayer() {
        guard let l = selected, l.kind == .fill else { message = "Only fill layers duplicate (a paint layer's pixels are its own)"; return }
        var c = l
        c.id = UUID()
        c.name = l.name + " copy"
        insert([c], name: "Duplicate layer")
    }

    func moveLayer(_ by: Int) {
        guard let id = selectedLayer else { return }
        edit("Move layer") { d in
            guard let i = d.layers.firstIndex(where: { $0.id == id }) else { return }
            let j = min(max(i + by, 0), d.layers.count - 1)
            d.layers.swapAt(i, j)
        }
    }

    func updateLayer(_ id: UUID, _ name: String, _ change: (inout PaintLayer) -> Void) {
        edit(name) { d in
            guard let i = d.layers.firstIndex(where: { $0.id == id }) else { return }
            change(&d.layers[i])
        }
    }

    func setMask(_ id: UUID, base: Float?) {
        updateLayer(id, base == nil ? "Remove mask" : "Add mask") { l in
            l.mask = base.map { PaintMask(base: $0, generator: nil, painted: true) }
        }
    }

    func setGenerator(_ id: UUID, _ g: PaintGenerator?) {
        updateLayer(id, "Mask generator") { l in
            var m = l.mask ?? PaintMask(base: 0, generator: nil, painted: false)
            m.generator = g
            l.mask = m
        }
    }

    func setSet(_ name: String, _ change: (inout PaintDocument) -> Void) { edit(name, change) }

    // MARK: - Strokes' undo

    private func registerStroke(_ id: Int) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.strokeUndone(id, undo: true) }
        undo.setActionName("Paint stroke")
        undo.endUndoGrouping()
    }

    private func strokeUndone(_ id: Int, undo isUndo: Bool) {
        host.painter { $0.undoPaintStroke(id, undo: isUndo) }
        undo.registerUndo(withTarget: self) { m in m.strokeUndone(id, undo: !isUndo) }
        undo.setActionName("Paint stroke")
        schedulePictures()
    }

    // MARK: - Saving, export

    /// The document saved: its JSON and its pixels (Assets/Painter/<name>.painter), and the scene's assignments.
    func save() {
        guard let d = document, let k = object, let package = PainterStore.package(d.name) else { return }
        do {
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(d).write(to: package.appendingPathComponent("document.json"), options: .atomic)
            if let url = PaintAssignments.url { try PaintAssignments.resolve(host.settings.scene.paintAssignments).save(to: url) }
        } catch {
            message = "Not saved: \(error)"
            return
        }
        message = "Saving \(d.name)…"
        host.painter { [weak self] r in
            let failure = r.savePainted(k)
            DispatchQueue.main.async { self?.message = failure.map { "Not saved: \($0)" } ?? "Saved \(d.name)" }
        }
    }

    func export() {
        guard let k = object else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let format = exportFormat
        host.painter { [weak self] r in
            let failure = r.exportPainted(k, to: folder, format: format)
            DispatchQueue.main.async { self?.message = failure.map { "Not exported: \($0)" } ?? "Exported to \(folder.lastPathComponent)" }
        }
    }

    /// The current stack as a smart material, under `name`.
    func saveSmart(_ name: String) {
        guard let d = document else { return }
        let layers = d.layers.filter { $0.kind == .fill }
        do {
            try SmartMaterial(name: name, layers: layers).save()
            message = "Smart material \(name) saved (\(layers.count) fill layers)"
        } catch {
            message = "Not saved: \(error)"
        }
    }

    // MARK: - Pictures

    private var picturesPending = false

    /// The centre view's picture and the layers' thumbnails, again (a few times a second at most).
    func schedulePictures() {
        guard !picturesPending else { return }
        picturesPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.picturesPending = false
            self?.refreshPictures()
        }
    }

    func refreshPictures() {
        guard let k = object, let d = document else { return }
        let view = view
        let ids = d.layers.map(\.id)
        host.painter { [weak self] r in
            let picture = r.painterPicture(k, output: view, side: 512)
            var thumbs: [UUID: CGImage] = [:]
            for id in ids { if let t = r.painterPicture(k, output: "", layer: id, side: 48) { thumbs[id] = t } }
            DispatchQueue.main.async {
                self?.picture = picture
                self?.thumbnails = thumbs
            }
        }
    }
}
