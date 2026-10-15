import XCTest
import AppKit
import Metal
import SwiftUI
import simd
@testable import MetalRenderer

/// The Material Designer without its window (MaterialEditorModel): its edits and undo, wiring, a pixel processor's
/// function, copy and paste, saving, what it sends the renderer, assignments; its bakes (thumbnails) on the GPU; and,
/// with MATERIAL_EDITOR_PNG=<folder>, pictures of its window drawn offscreen.
final class MaterialEditorTests: XCTestCase {
    private final class Host: MaterialEditorHost {
        var settings = RenderSettings()
        var defaultSettings = RenderSettings()
        var metalDevice: MTLDevice?
        var updates = 0
        var armed = false
        var answer: ((MaterialPick?) -> Void)?
        private var observers: [(RenderSettings) -> Void] = []
        func update(_ change: @escaping (inout RenderSettings) -> Void) {
            change(&settings)
            updates += 1
            observers.forEach { $0(settings) }
        }
        func observeSettings(_ observer: @escaping (RenderSettings) -> Void) { observers.append(observer) }
        func pickMaterial(_ picked: @escaping (MaterialPick?) -> Void) { armed = true; answer = picked }
        func cancelPick() { armed = false; answer?(nil) }
    }

    private func editor(folder: URL? = nil, gpu: Bool = false) -> (MaterialEditorModel, Host) {
        let host = Host()
        host.settings.scene.kind = .materials
        if gpu { host.metalDevice = MTLCreateSystemDefaultDevice() }
        let m = MaterialEditorModel(controller: host, saved: MaterialCatalog(), folder: folder, draft: false)
        m.pasteboard = NSPasteboard(name: NSPasteboard.Name("MaterialEditorTests"))
        m.select("Red Bricks")
        return (m, host)
    }

    /// Bakes are asynchronous (on the engine's queue, back on the main thread): waits for one to land.
    private func waitForBake(_ m: MaterialEditorModel, until: () -> Bool = { true }) {
        let deadline = Date().addingTimeInterval(10)
        repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } while (m.result == nil || !until()) && Date() < deadline
    }

    func testEditsAreUndoStepsAndReachTheRenderer() {
        let (m, host) = editor()
        let bricks = m.graph.nodes.first { $0.kind == .bricks }!.id
        m.beginDrag()
        for v: Float in [0.1, 0.2, 0.3] { m.setParam(bricks, "gap", .float(v)) }
        m.endDrag()
        m.setParam(bricks, "rows", .int(12))
        XCTAssertEqual(m.graph.node(bricks)?.float("gap"), 0.3)
        XCTAssertNotEqual(host.settings.scene.materials, "", "the edited catalog's key")
        XCTAssertEqual(MaterialCatalog.resolve(host.settings.scene.materials).graph("Red Bricks")?.node(bricks)?.int("rows"), 12)
        m.undo.undo()
        XCTAssertEqual(m.graph.node(bricks)?.int("rows"), 10)
        XCTAssertEqual(m.graph.node(bricks)?.float("gap"), 0.3)
        m.undo.undo()
        XCTAssertEqual(m.graph.node(bricks)?.float("gap"), 0.008, "the drag is one step")
        m.undo.redo()
        XCTAssertEqual(m.graph.node(bricks)?.float("gap"), 0.3)
    }

    func testWiringAndDeleting() {
        let (m, _) = editor()
        let a = m.addNode(.perlinNoise, at: [0, 0])
        let b = m.addNode(.levels, at: [200, 0])
        XCTAssertTrue(m.link(a, "out", to: b, "in"))
        XCTAssertFalse(m.link(b, "out", to: b, "in"), "not into itself")
        XCTAssertFalse(m.link(b, "out", to: a, "in"), "the noise has no input")
        let c = m.addNode(.blend, at: [400, 0])
        XCTAssertTrue(m.link(b, "out", to: c, "fg"))
        XCTAssertFalse(m.link(c, "out", to: b, "in"), "a loop")
        XCTAssertNotNil(m.wire(into: c, "fg"))
        m.unlink(c, "fg")
        XCTAssertNil(m.wire(into: c, "fg"))
        m.selection = [b]
        m.deleteSelection()
        XCTAssertNil(m.graph.node(b))
        XCTAssertFalse(m.graph.links.contains { $0.from == b || $0.to == b })
        m.addOutput(.emissive, at: [600, 0])
        XCTAssertNotNil(m.graph.channels[.emissive])
        m.addOutput(.emissive, at: [600, 100])
        XCTAssertEqual(m.graph.nodes.filter { $0.kind == .output && $0.choice("usage") == "emissive" }.count, 1, "one a channel")
    }

    func testFunctionsAreEditedOnTheCanvas() throws {
        let (m, _) = editor()
        let pp = m.addNode(.pixelProcessor, at: [0, 400])
        m.editingFunction = pp
        XCTAssertEqual(m.function?.nodes.map(\.kind), [.position, .sample, .result])
        let one = m.addFunctionNode(.oneMinus, at: [-100, 100])
        XCTAssertTrue(m.link("sample", "out", to: one, "a"))
        XCTAssertTrue(m.link(one, "out", to: "result", "value"))
        XCTAssertTrue(try m.function!.code().metal.contains("1.0 - "))
        m.selection = ["result"]
        m.deleteSelection()
        XCTAssertNotNil(m.function?.result, "the Result stays")
        m.undo.undo()
        XCTAssertEqual(m.function?.link(into: "result", "value")?.from, "sample", "undo walks the function's edits too")
        m.editingFunction = nil
        XCTAssertEqual(m.graph.node(pp)?.function?.nodes.count, 4)
    }

    func testCopyAndPaste() {
        let (m, _) = editor()
        let a = m.addNode(.perlinNoise, at: [0, 0])
        let b = m.addNode(.levels, at: [200, 0])
        m.link(a, "out", to: b, "in")
        m.selection = [a, b]
        m.copySelection()
        let before = m.graph.nodes.count
        m.paste()
        XCTAssertEqual(m.graph.nodes.count, before + 2)
        XCTAssertEqual(m.selection.count, 2)
        let pasted = m.graph.links.filter { m.selection.contains($0.from) && m.selection.contains($0.to) }
        XCTAssertEqual(pasted.count, 1, "the wire between them, renamed")
    }

    func testSaveRenameAndRevert() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("material-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (m, _) = editor(folder: folder)
        m.newGraph()
        let name = m.selectedGraph
        XCTAssertEqual(name, "Material")
        m.rename("Moss")
        XCTAssertEqual(m.selectedGraph, "Moss")
        m.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: MaterialStore.url("Moss", in: folder).path))
        XCTAssertFalse(m.isDirty)
        let id = m.graph.nodes[0].id
        m.setParam(id, "color", .color([1, 0, 0, 1]))
        XCTAssertTrue(m.isDirty)
        m.revert()
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(MaterialStore.load(from: folder).graphs.keys.sorted(), ["Moss"])
        m.deleteGraph()
        m.save()
        XCTAssertEqual(MaterialStore.load(from: folder).graphs.count, 0)
        XCTAssertTrue(m.graph.swiftSource.contains("MaterialGraph("))
    }

    func testPickAndAssign() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("material-assign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (m, host) = editor(folder: folder)
        host.settings.scene.kind = .cornell
        host.update { _ in }
        m.pick()
        XCTAssertTrue(host.armed)
        XCTAssertTrue(m.picking)
        host.answer?(MaterialPick(instance: 3, material: 2, fingerprint: "abc", albedo: [0.5, 0.5, 0.5], position: .zero))
        XCTAssertFalse(m.picking)
        XCTAssertEqual(m.picked?.material, 2)
        m.assign("Red Bricks", to: m.picked!)
        XCTAssertEqual(m.sceneAssignments.map(\.material), [2])
        XCTAssertNotEqual(host.settings.scene.materialAssignments, "")
        let a = MaterialAssignments.resolve(host.settings.scene.materialAssignments)
        XCTAssertEqual(a.scenes["cornell"]?.first?.graph, "Red Bricks")
        m.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MaterialAssignments.file).path))
        m.unassign(2)
        XCTAssertTrue(m.sceneAssignments.isEmpty)
    }

    /// A scene built with an assignment makes that material procedural (its fingerprint matching), and drops a stale one.
    func testAssignmentsApplyWhenTheSceneIsMade() {
        var s = SceneSettings()
        s.kind = .cornell
        let plain = Scene(s)
        let target = 1
        let fp = MaterialAssignments.fingerprint(plain.materials[target])
        var a = MaterialAssignments()
        a.scenes["cornell"] = [.init(material: target, fingerprint: fp, graph: "Perforated Metal"),
                               .init(material: 0, fingerprint: "stale", graph: "Red Bricks")]
        s.materialAssignments = MaterialAssignments.register(a)
        let made = Scene(s)
        XCTAssertEqual(made.procedural.map(\.material), [target])
        XCTAssertEqual(made.procedural.first?.fingerprint, fp)
        XCTAssertTrue(made.hasOpacity, "the perforated metal cuts holes")
        XCTAssertEqual(made.textures.count, plain.textures.count + ProcSlot.allCases.count)
        XCTAssertNotEqual(made.lightTypeMask & 0x8000, 0, "MATERIAL_EXTRAS")
    }

    func testBakesGiveThumbnails() throws {
        let (m, _) = editor(gpu: true)
        guard m.engine != nil else { throw XCTSkip("no Metal device") }
        m.bake()
        waitForBake(m) { m.thumbnails.count == m.graph.nodes.count }
        XCTAssertEqual(m.thumbnails.count, m.graph.nodes.count)
        XCTAssertTrue(m.errors.isEmpty, "\(m.errors)")
        XCTAssertNotNil(m.result?.outputs.baseColor)
        // The renderer's bake of the same graph is the editor's.
        let key = MaterialBake.key(m.graph, catalog: m.catalog)
        XCTAssertNotNil(MaterialBake.shared(m.engine!.device).baked(key))
    }

    /// MATERIAL_EDITOR_PNG=<folder>: the window drawn offscreen (its Metal views are left black by the drawing).
    func testPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["MATERIAL_EDITOR_PNG"] else { throw XCTSkip("MATERIAL_EDITOR_PNG not set") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (m, _) = editor(gpu: true)
        let size = NSSize(width: 1440, height: 860)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: MaterialEditorView().environmentObject(m))
        window.contentView = view
        func shoot(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        m.frameAll(in: m.canvasSize)
        waitForBake(m) { m.thumbnails.count == m.graph.nodes.count }
        try shoot("1-red-bricks")
        m.click(m.graph.nodes.first { $0.kind == .gradientMap }!.id)
        try shoot("2-gradient-map")
        m.select("Perforated Metal")
        m.frameAll(in: m.canvasSize)
        waitForBake(m) { m.result?.plan.name == "Perforated Metal" && m.thumbnails.count == m.graph.nodes.count }
        m.click(m.graph.nodes.first { $0.kind == .tileSampler }!.id)
        try shoot("3-perforated-metal")
        let pp = m.addNode(.pixelProcessor, at: [0, 600])
        m.editingFunction = pp
        m.frameAll(in: m.canvasSize)
        m.click("sample")
        try shoot("4-function")
    }
}
