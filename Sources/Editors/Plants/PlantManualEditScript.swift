import AppKit
import EngineCore
import MetalRenderer
import Plants
import simd

private extension NSView {
    func subviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? $0.subviews(of: type) }
    }
}

/// `METALRENDERER_PLANT_EDIT_SCRIPT=<folder>` (the app with its window, `METALRENDERER_SCENE=plants`): a Manual Edit node
/// used as its user does, mouse events sent to the inspector's tool and the view. After each step the editor's window and
/// the view's frame go to the folder as PNGs and what's so is printed; it quits at the end. With
/// `METALRENDERER_PLANTS=builtin`, and run as a copy of the binary under another name: its settings and its draft
/// (UserDefaults, named after the executable) are then not the user's.
enum PlantManualEditScript {
    private static var folder: URL? {
        ProcessInfo.processInfo.environment["METALRENDERER_PLANT_EDIT_SCRIPT"].map { URL(fileURLWithPath: $0) }
    }

    static func run(_ panel: PlantEditorPanel, controller: RendererController, renderer: Renderer, window: NSWindow) {
        guard let folder, let view = controller.renderView else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let m = panel.model
        var k = 0, failures = 0
        var nodeID: Int32 = -1

        func edit() -> Growth.ManualEdit? {
            if case .manualEdit(let e)? = m.graph.node(nodeID)?.settings { return e }
            return nil
        }
        func say(_ text: String) {
            print("plant edit script: \(text)")
            fflush(stdout)
        }
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            say("\(ok ? "ok" : "FAILED"): \(what)")
        }
        func shot(_ name: String) {
            k += 1
            let e = edit()
            say("\(k) \(name): tool \(m.editTool.map(\.rawValue) ?? "off"), view \(m.scene.plants.view), \(e?.points.count ?? -1) points, \(e?.removed.count ?? -1) cuts, "
                + "picked \(m.editPick.map { String($0.point) } ?? "-"), hovering \(m.hoverPick.map { String($0.point) } ?? "-"), compile \(m.compile)")
            let file = String(format: "%02d-%@", k, name.replacingOccurrences(of: " ", with: "-"))
            if let content = panel.panel.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(file + "-editor.png"))
            }
            renderer.perform { $0.captureFrame(to: folder.appendingPathComponent(file + "-view.png"), scale: 0.5) { _ in } }
        }

        // MARK: The mouse

        func event(_ type: NSEvent.EventType, at p: NSPoint, in w: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        /// In the view: where a cursor (0...1 across and down) is in its window.
        func location(_ c: SIMD2<Float>) -> NSPoint {
            view.convert(NSPoint(x: CGFloat(c.x) * view.bounds.width, y: CGFloat(1 - c.y) * view.bounds.height), to: nil)
        }
        func press(_ type: NSEvent.EventType, _ c: SIMD2<Float>) {
            if let e = event(type, at: location(c), in: window) { window.sendEvent(e) }
        }
        func hover(_ c: SIMD2<Float>) {
            if let e = event(.mouseMoved, at: location(c), in: window) { view.mouseMoved(with: e) }
        }
        /// A click of the tool's segment in the inspector, as the window gets it.
        func tool(_ label: String) -> Bool {
            guard let content = panel.panel.contentView else { return false }
            for control in content.subviews(of: NSSegmentedControl.self) {
                let labels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
                guard labels.contains("Off"), labels.contains("Move"), let s = labels.firstIndex(of: label) else { continue }
                let width = control.bounds.width / CGFloat(control.segmentCount)
                let p = control.convert(NSPoint(x: width * (CGFloat(s) + 0.5), y: control.bounds.midY), to: nil)
                panel.panel.makeKeyAndOrderFront(nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = event(type, at: p, in: panel.panel) { NSApp.postEvent(e, atStart: false) }
                }
                return true
            }
            return false
        }

        /// What the camera sees, on the render thread, then on the main one.
        func camera(_ done: @escaping (_ eye: SIMD3<Float>, _ cursor: @escaping (SIMD3<Float>) -> SIMD2<Float>, _ ray: @escaping (SIMD2<Float>) -> SIMD3<Float>) -> Void) {
            renderer.perform { r in
                let c = r.camera, size = r.gizmoViewSize, t = tan(c.fovY / 2), aspect = size.x / max(size.y, 1)
                let cursor = { (p: SIMD3<Float>) -> SIMD2<Float> in
                    let v = p - c.position, z = dot(v, c.forward)
                    return SIMD2(dot(v, c.right) / (z * t * aspect) * 0.5 + 0.5, 0.5 - dot(v, c.up) / (z * t) * 0.5)
                }
                let ray = { (s: SIMD2<Float>) -> SIMD3<Float> in
                    normalize(c.forward + c.right * ((2 * s.x - 1) * t * aspect) + c.up * ((1 - 2 * s.y) * t))
                }
                DispatchQueue.main.async { done(c.position, cursor, ray) }
            }
        }
        /// Where a branch's wood is on the screen, in the crown's lower half, a point past its foot with wood beyond it, not
        /// one of `used`'s branches.
        func find(_ used: Set<Int>, _ done: @escaping (SIMD2<Float>?, PlantEditing.Pick?) -> Void) {
            camera { eye, _, ray in
                guard let editing = m.editing else { return done(nil, nil) }
                for y in stride(from: Float(0.5), to: 0.75, by: 0.01) {
                    for x in stride(from: Float(0.3), to: 0.7, by: 0.01) {
                        if let p = editing.pick(origin: eye, direction: ray([x, y])), p.branch != 0, p.index >= 2, !used.contains(p.branch),
                           editing.canTurn(p), editing.lines(branch: p.branch, from: p.index).count >= 3 { return done([x, y], p) }
                    }
                }
                done(nil, nil)
            }
        }
        /// A press at one point of the view and a drag to another, 12 steps a third of a second, as a hand does.
        func drag(from a: SIMD2<Float>, to b: SIMD2<Float>, done: @escaping () -> Void) {
            window.makeKeyAndOrderFront(nil)
            press(.leftMouseDown, a)
            var i = 1
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.05, repeating: 1.0 / 30)
            timer.setEventHandler {
                let t = Float(i) / 12
                press(.leftMouseDragged, a + (b - a) * t)
                i += 1
                guard i > 12 else { return }
                timer.cancel()
                press(.leftMouseUp, b)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
            }
            timer.resume()
        }

        // MARK: The steps

        var picked: Set<Int> = []
        var handleAtStart = SIMD3<Float>.zero
        var steps: [(wait: Double, name: String, () -> Void)] = []
        func step(_ wait: Double, _ name: String, _ action: @escaping () -> Void) { steps.append((wait, name, action)) }
        /// A step that says when it's done.
        var waiting: ((@escaping () -> Void) -> Void)?
        func later(_ wait: Double, _ name: String, _ action: @escaping (@escaping () -> Void) -> Void) {
            step(wait, name) { waiting = action }
        }

        step(3, "open") {
            panel.panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            m.frameAll(in: m.canvasSize)
        }
        step(2, "node added") {
            // (A draft of an earlier run would be in the way: `defaults delete` the copy's name.)
            check(!m.graph.nodes.contains { $0.kind == .manualEdit }, "it starts with no Manual Edit")
            guard let carve = m.graph.first(.carve, .plant), let wood = m.graph.first(.skeleton, .plant) else { return check(false, "the oak has its stages") }
            m.click("\(carve.id)", extend: false)
            m.addNode(.manualEdit, at: nil)
            guard let node = m.graph.nodes.first(where: { $0.kind == .manualEdit }) else { return check(false, "a node was added") }
            nodeID = node.id
            check(m.link("\(node.id)", "out", to: "\(wood.id)", "0"), "wired into the Mesh Builder")
            m.layoutAll()
            m.click("\(node.id)", extend: false)
            check(m.graph.nodes.filter { $0.kind == .manualEdit }.count == 1, "one node was added")
        }
        step(3, "tool taken up") {
            check(tool("Move"), "the inspector has its tool's segments")
        }
        step(0.3, "hero chosen") {
            check(m.editTool == .transform, "the click on Move took the tool up")
            check(edit()?.seed != 0, "the plant in view became the hero")
            check(m.scene.plants.view == .skeleton, "the workshop shows stems")
        }
        later(0.8, "hover") { done in
            find(picked) { c, _ in
                guard let c else { check(false, "wood on the screen"); return done() }
                hover(c)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    check(m.hoverPick != nil, "hovering over wood highlights it")
                    done()
                }
            }
        }
        later(0.8, "point clicked") { done in
            find(picked) { c, pick in
                guard let c, let pick else { check(false, "wood to click"); return done() }
                picked.insert(pick.branch)
                // (The panel is key: this is the first click in the view.)
                press(.leftMouseDown, c)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    press(.leftMouseUp, c)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        check(m.editPick != nil, "a first click in the view picks a point")
                        done()
                    }
                }
            }
        }
        later(1.5, "arrow dragged") { done in
            guard let pick = m.editPick, let editing = m.editing else { check(false, "something picked"); return done() }
            let at = editing.position(pick.point)
            handleAtStart = at
            camera { eye, cursor, _ in
                let size = PlantToolHandle.size(at, from: eye)
                let before = edit()?.points.count ?? 0, canUndo = m.undo.canUndo
                drag(from: cursor(at + [size * 0.85, 0, 0]), to: cursor(at + [size * 2.2, 0, 0])) {
                    let now = m.editPick.flatMap { p in m.editing?.position(p.point) } ?? at
                    check(now.x - at.x > size * 0.8, "the x arrow's drag moved the point \(now.x - at.x) m along x (size \(size))")
                    check(abs(now.y - at.y) < 1e-3 && abs(now.z - at.z) < 1e-3, "and only along x")
                    check((edit()?.points.count ?? 0) > before && canUndo, "the node holds it")
                    done()
                }
            }
        }
        later(1.5, "ring dragged") { done in
            guard let pick = m.editPick, let editing = m.editing else { check(false, "something picked"); return done() }
            let at = editing.position(pick.point), before = edit()?.points.count ?? 0
            let tipBefore = editing.lines(branch: pick.branch).last?.b ?? at
            camera { eye, cursor, _ in
                let r = PlantToolHandle.size(at, from: eye) * 0.7, s = r * Float(0.5).squareRoot()
                drag(from: cursor(at + [s, s, 0]), to: cursor(at + [-s, s, 0])) {
                    guard let e = m.editing else { check(false, "still editing"); return done() }
                    let tip = e.lines(branch: pick.branch).last?.b ?? at
                    check(simd_distance(tip, tipBefore) > 0.05, "the z ring's drag turned what's beyond by \(simd_distance(tip, tipBefore)) m")
                    check(simd_distance(e.position(pick.point), at) < 1e-3, "the point itself stayed")
                    check((edit()?.points.count ?? 0) >= before, "the node holds it")
                    done()
                }
            }
        }
        later(0.8, "undo of the turn") { done in
            let before = m.editing.flatMap { e in m.editPick.flatMap { p in e.lines(branch: p.branch).last?.b } }
            m.undo.undo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let now = m.editing.flatMap { e in m.editPick.flatMap { p in e.lines(branch: p.branch).last?.b } }
                check(before != nil && now != nil && simd_distance(before!, now!) > 0.05, "one undo takes the whole drag back, the tool following")
                m.undo.redo()
                done()
            }
        }
        later(1, "a drag elsewhere looks") { done in
            let before = edit()
            camera { eye, cursor, _ in
                drag(from: cursor(handleAtStart + [6, 6, 0]), to: cursor(handleAtStart + [6, 5.6, 0])) {
                    check(edit() == before, "a drag off the handle edits nothing")
                    camera { now, _, _ in
                        check(true, "the camera \(simd_distance(eye, now) > 0 ? "moved" : "stayed") (a look turns it where it stands)")
                        done()
                    }
                }
            }
        }
        step(1.5, "remove up") { check(tool("Remove"), "Remove's segment") }
        later(2.5, "a branch removed") { done in
            check(m.editTool == .removeBranch, "the click on Remove changed the tool")
            find(picked) { c, pick in
                guard let c, let pick else { check(false, "a branch to remove"); return done() }
                picked.insert(pick.branch)
                hover(c)
                let before = edit()?.removed.count ?? 0
                window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    press(.leftMouseDown, c)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        press(.leftMouseUp, c)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            check(edit()?.removed.count == before + 1, "a click cuts the branch off")
                            done()
                        }
                    }
                }
            }
        }
        step(1.5, "trim up") { check(tool("Trim"), "Trim's segment") }
        later(2.5, "a branch trimmed") { done in
            check(m.editTool == .trim, "the click on Trim changed the tool")
            find(picked) { c, pick in
                guard let c, let pick else { check(false, "a branch to trim"); return done() }
                picked.insert(pick.branch)
                let before = edit()?.removed.count ?? 0
                window.makeKeyAndOrderFront(nil)
                press(.leftMouseDown, c)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    press(.leftMouseUp, c)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        check(edit()?.removed.count == before + 1, "a click cuts the branch beyond the point")
                        done()
                    }
                }
            }
        }
        step(3, "tool off") { check(tool("Off"), "Off's segment") }
        later(12, "the plant, edited and compiled") { done in
            check(m.editTool == nil, "the click on Off put the tool down")
            check(m.scene.plants.view == .plant, "the plant's view is back")
            let e = edit()
            check((e?.points.isEmpty == false) && (e?.removed.count ?? 0) >= 2, "its edits stay")
            check(!m.swiftText.isEmpty && PlantSwift.parse(m.swiftText)?.graph?.canonical == m.graph.canonical, "the file reads back as the graph")
            done()
        }
        step(0.5, "compile state") {
            if case .compiled = m.compile { check(true, "the edited plant's file compiled") } else { check(false, "the edited plant's file compiled: \(m.compile)") }
        }
        step(3, "cleared") {
            m.clearEditing(moves: true)
            m.clearEditing(moves: false)
            check(edit()?.points.isEmpty == true && edit()?.removed.isEmpty == true, "the Clear buttons' actions clear them")
        }

        func queue(_ i: Int) {
            guard i < steps.count else {
                say("done, \(failures) failed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                return
            }
            let (wait, name, action) = steps[i]
            func next() {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    shot(name)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { queue(i + 1) }
                }
            }
            waiting = nil
            action()
            if let w = waiting { w(next) } else { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { queue(0) }
    }
}
