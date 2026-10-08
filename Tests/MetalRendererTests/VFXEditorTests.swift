import XCTest
import AppKit
import SwiftUI
import simd
@testable import MetalRenderer

/// The VFX editor without its window (VFXEditorModel, VFXLayout), how its edits reach a running particle system
/// (VFXLive.swift), and, with VFX_EDITOR_PNG=<folder>, pictures of its window drawn offscreen.
final class VFXEditorTests: XCTestCase {
    private final class Host: VFXEditorHost {
        var settings = RenderSettings()
        var defaultSettings = RenderSettings()
        var effectsStatus: VFXStatus?
        var updates = 0
        private var observers: [(RenderSettings) -> Void] = []
        func update(_ change: @escaping (inout RenderSettings) -> Void) {
            change(&settings)
            updates += 1
            observers.forEach { $0(settings) }
        }
        func observeSettings(_ observer: @escaping (RenderSettings) -> Void) { observers.append(observer) }
        func observeTick(_ observer: @escaping () -> Void) {}
    }

    private func editor(folder: URL? = nil, kind: SceneKind = .vfxStage) -> (VFXEditorModel, Host) {
        let host = Host()
        host.settings.scene.kind = kind
        let m = VFXEditorModel(controller: host, saved: VFXCatalog(), folder: folder, draft: false)
        m.pasteboard = NSPasteboard(name: NSPasteboard.Name("VFXEditorTests"))
        m.select("fireworks")
        return (m, host)
    }

    /// A drag is one undo step however many values it went through; each other edit is one; undo and redo walk them.
    func testUndoStepsAreEdits() {
        let (m, _) = editor()
        XCTAssertEqual(m.effect.block("stars.gravity")?.block.float("share"), 0.35)
        m.beginDrag()
        for v: Float in [0.4, 0.5, 0.6] { m.setParam("stars.gravity", "share", .float(v)) }
        m.endDrag()
        m.setParam("stars.drag", "drag", .float(1.5))
        XCTAssertTrue(m.isDirty)
        m.undo.undo()
        XCTAssertEqual(m.effect.block("stars.drag")?.block.float("drag"), 0.7)
        XCTAssertEqual(m.effect.block("stars.gravity")?.block.float("share"), 0.6)
        m.undo.undo()
        XCTAssertEqual(m.effect.block("stars.gravity")?.block.float("share"), 0.35)
        XCTAssertFalse(m.isDirty, "back to the built-in effect")
        m.undo.redo()
        m.undo.redo()
        XCTAssertEqual(m.effect.block("stars.drag")?.block.float("drag"), 1.5)
    }

    /// Every edit reaches the scenes as the edited catalog's key; the stage shows the selected effect.
    func testEditsReachTheScenes() throws {
        let (m, host) = editor(kind: .particles)
        m.setParam("starColor", "emission", .float(9))
        XCTAssertEqual(host.settings.scene.effects, m.key)
        XCTAssertEqual(VFXCatalog.resolve(host.settings.scene.effects).effects["fireworks"], m.effect)
        m.showOnStage()
        XCTAssertEqual(host.settings.scene.kind, .vfxStage)
        XCTAssertEqual(host.settings.scene.stage.effects, ["fireworks"])
        m.select("campfire")
        XCTAssertEqual(host.settings.scene.stage.effects, ["campfire"], "the stage follows the selection")
    }

    /// The same catalog gets the same key however its parameters' dictionaries were filled (a new key each time would
    /// make the scene again at every settings report, and the editor push it again).
    func testCatalogKeysAreTheirContents() {
        var a = VFXEditorModel.template, b = VFXEditorModel.template
        for (name, value) in [("rate", VFXParam.float(5)), ("start", .float(1)), ("stop", .float(9)), ("span", .float(2))] {
            a.setParam("sparks.rate", name, value)
        }
        for (name, value) in [("span", VFXParam.float(2)), ("stop", .float(9)), ("start", .float(1)), ("rate", .float(5))] {
            b.setParam("sparks.rate", name, value)
        }
        XCTAssertEqual(a, b)
        let keys = Set((0..<20).map { i in VFXCatalog.register(VFXCatalog(effects: ["x": i % 2 == 0 ? a : b])) })
        XCTAssertEqual(keys.count, 1)
        let (m, host) = editor()
        m.newEffect()
        m.showOnStage()
        let updates = host.updates
        m.showOnStage()
        XCTAssertLessThanOrEqual(host.updates, updates + 1, "nothing new to send")
    }

    /// A wire goes only into a pin that takes one, from a node's output, and never makes a loop; a second wire into a
    /// pin replaces the first; taking it off leaves the value.
    func testWiringRules() throws {
        let (m, _) = editor()
        let fx = m.effect
        XCTAssertFalse(fx.canLink("hue", "out", to: "id", "a"), "particle id has no inputs")
        XCTAssertFalse(fx.canLink("hue", "out", to: "perRocket", "a"), "a loop: hue is downstream of perRocket")
        XCTAssertFalse(fx.canLink("hue", "out", to: "stars.flipbook", "atlas"), "an atlas is a value, not a pin")
        XCTAssertFalse(fx.canLink("stars.size", "out", to: "lit", "a"), "a block has no outputs")
        XCTAssertTrue(fx.canLink("burnOut", "out", to: "stars.size", "size"))
        XCTAssertTrue(m.link("burnOut", "out", to: "stars.size", "size"))
        XCTAssertEqual(m.effect.link(into: "stars.size", "size")?.from, "burnOut")
        XCTAssertTrue(m.link("hue", "out", to: "stars.size", "size"))
        XCTAssertEqual(m.effect.links.filter { $0.to == "stars.size" }.count, 1, "one wire a pin")
        m.unlink("stars.size", "size")
        XCTAssertNil(m.effect.link(into: "stars.size", "size"))
        // Types: a generic node takes the widest of what it is given.
        XCTAssertEqual(m.effect.outputType("lit"), .color, "rainbow (a colour) times burn-out (a float)")
        XCTAssertEqual(m.effect.outputType("golden"), .float)
        XCTAssertEqual(m.effect.pinType("starColor", "color"), .color)
    }

    /// Adding and removing nodes, blocks and emitters; deleting takes their wires; copy and paste keeps the wires
    /// between the copied nodes, under new ids.
    func testGraphEdits() throws {
        let (m, _) = editor()
        let n = m.addNode(.sin, at: [10, 20])
        XCTAssertEqual(m.effect.node(n)?.canvas, [10, 20])
        XCTAssertTrue(m.link("t", "out", to: n, "a"))
        let block = try XCTUnwrap(m.addBlock(.force, to: "stars", .update))
        XCTAssertEqual(m.effect.emitter("stars")?.update.last?.id, block)
        XCTAssertNil(m.addBlock(.rate, to: "stars", .update), "a Rate is a Spawn block")
        m.selection = [n]
        m.deleteSelection()
        XCTAssertNil(m.effect.node(n))
        XCTAssertFalse(m.effect.links.contains { $0.from == n || $0.to == n })
        // Copy and paste two wired nodes.
        m.selection = ["perRocket", "rocket"]
        m.copySelection()
        m.paste()
        XCTAssertEqual(m.selection.count, 2)
        let pasted = m.effect.nodes.filter { m.selection.contains($0.id) }
        XCTAssertEqual(Set(pasted.map(\.kind)), [.divide, .floor])
        XCTAssertEqual(m.effect.links.filter { m.selection.contains($0.from) && m.selection.contains($0.to) }.count, 1)
        // An emitter, and its removal with its blocks' wires.
        let e = m.addEmitter()
        XCTAssertEqual(m.effect.emitters.count, 3)
        XCTAssertEqual(m.effect.emitter(e)?.spawn.first?.id, "\(e).rate")
        m.selection = ["stars"]
        m.deleteSelection()
        XCTAssertFalse(m.effect.links.contains { $0.to.hasPrefix("stars.") })
        XCTAssertNil(m.effect.emitter("stars"))
    }

    /// Save writes the edited effects (a built-in one as built in: its file goes), revert brings back what is saved,
    /// Copy as Swift is the effect's Swift.
    func testSavingAndCopyAsSwift() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vfx-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (m, _) = editor(folder: folder)
        m.setParam("rockets.rate", "rate", .float(2))
        m.newEffect()
        XCTAssertEqual(m.selectedEffect, "effect")
        m.rename("sparkler")
        XCTAssertEqual(m.selectedEffect, "sparkler")
        m.save()
        XCTAssertFalse(m.isDirty)
        let saved = VFXStore.load(from: folder)
        XCTAssertEqual(Set(saved.effects.keys), ["fireworks", "sparkler"])
        XCTAssertEqual(saved.effects["fireworks"]?.block("rockets.rate")?.block.float("rate"), 2)
        // Revert: the shown effect as saved.
        m.select("fireworks")
        m.setParam("rockets.rate", "rate", .float(3))
        m.revert()
        XCTAssertEqual(m.effect.block("rockets.rate")?.block.float("rate"), 2)
        // Back to built in, saved: its file goes.
        m.resetToBuiltIn()
        XCTAssertEqual(m.effect, VFXLibrary.named("fireworks"))
        m.save()
        XCTAssertEqual(Set(VFXStore.load(from: folder).effects.keys), ["sparkler"])
        m.copyAsSwift()
        XCTAssertEqual(m.pasteboard.string(forType: .string), VFXLibrary.named("fireworks")!.swiftSource)
    }

    /// What an edit takes, running: a value in place; a wire, new code; a capacity, the scene made again.
    func testEditKinds() throws {
        func system(_ fx: VFXEffect) -> ParticleSystem { VFXLowering.system([VFXInstance(effect: fx, place: .identity)]).system }
        let fireworks = try XCTUnwrap(VFXLibrary.named("fireworks")), campfire = try XCTUnwrap(VFXLibrary.named("campfire"))
        var values = fireworks
        values.setParam("stars.gravity", "share", .float(0.5))
        values.setParam("rockets.color", "emission", .float(12))
        XCTAssertEqual(system(fireworks).edit(to: system(values)), .values)
        var curve = fireworks   // a curve's keys are parameters too
        curve.setParam("burnOut", "curve", .curve(VFXCurve([[0, 1], [0.3, 0.5], [1, 0]])))
        XCTAssertEqual(system(fireworks).edit(to: system(curve)), .values)
        var wired = fireworks
        wired.nodes.append(VFXNode(.float, ["value": .float(2)], id: "two"))
        wired.links.append(VFXLink("two", to: "stars.drag", "drag"))
        XCTAssertEqual(system(fireworks).edit(to: system(wired)), .code)
        var bigger = fireworks
        bigger.emitters[1].capacity = 2000
        XCTAssertEqual(system(fireworks).edit(to: system(bigger)), .rebuild)
        var unlit = campfire   // shadows off: the pool's order changes
        let flames = try XCTUnwrap(unlit.emitters.firstIndex { $0.first(.lighting)?.bool("shadows") == true })
        unlit.setParam(unlit.emitters[flames].first(.lighting)!.id, "shadows", .bool(false))
        XCTAssertEqual(system(campfire).edit(to: system(unlit)), .rebuild)
        var hot = campfire      // a built-in effect, its values: still no code
        hot.setParam(campfire.emitters[0].spawn[0].id, "rate", .float(500))
        let hotSystem = system(hot)
        XCTAssertNil(hotSystem.programSource)
        XCTAssertEqual(system(campfire).edit(to: hotSystem), .values)
        // The new system goes on from where the old one is.
        let old = system(campfire)
        _ = old.claim(to: 2)
        XCTAssertEqual(hotSystem.continuing(old).stepIndex, old.stepIndex)
    }

    /// The canvas's layout: every wire's ends have places, and nothing is drawn over anything else.
    func testLayout() throws {
        for name in VFXLibrary.names {
            let fx = try XCTUnwrap(VFXLibrary.named(name))
            let layout = VFXLayout(fx)
            for l in fx.links {
                XCTAssertNotNil(layout.outputs[.init(owner: l.from, name: l.output)], "\(name): \(l.from).\(l.output)")
                XCTAssertNotNil(layout.inputs[.init(owner: l.to, name: l.input)], "\(name): \(l.to).\(l.input)")
            }
            let boxes = Array(layout.emitters.values) + Array(layout.nodes.values)
            for i in boxes.indices { for j in boxes.indices where i < j { XCTAssertFalse(boxes[i].intersects(boxes[j]), "\(name): \(boxes[i]) \(boxes[j])") } }
            XCTAssertEqual(layout.input(near: try XCTUnwrap(layout.inputs.first?.value), radius: 1), layout.inputs.first?.key)
        }
    }

    // MARK: - Pictures

    /// VFX_EDITOR_PNG=<folder>: the window drawn offscreen, as it opens (fireworks), with a block selected (a gradient
    /// in the inspector) and with a node (a curve).
    func testPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["VFX_EDITOR_PNG"] else { throw XCTSkip("VFX_EDITOR_PNG not set") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (m, host) = editor()
        host.effectsStatus = VFXStatus(emitters: [.init(effect: "fireworks", name: "rockets", program: true, capacity: 24),
                                                  .init(effect: "fireworks", name: "stars", program: true, capacity: 1600)],
                                       compileMs: 1210)
        m.select("fireworks")
        let size = NSSize(width: 1240, height: 780)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: VFXEditorView().environmentObject(m))
        window.contentView = view
        func shoot(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        m.frameAll(in: m.canvasSize)
        try shoot("1-fireworks")
        m.click("starColor")
        try shoot("2-block")
        m.click("burnOut")
        try shoot("3-node")
        m.select("campfire")
        m.frameAll(in: m.canvasSize)
        try shoot("4-campfire")
    }
}
