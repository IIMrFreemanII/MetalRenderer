import AppKit
import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants
import QuartzCore

private extension NSView {
    func subviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? $0.subviews(of: type) }
    }
}

/// `METALRENDERER_PLANT_SCRIPT=<folder>` (the app with its window, `METALRENDERER_SCENE=plants`): the plant editor driven
/// as its user does, clicks sent to the window, as the renderer runs it. After each step the editor's window and the
/// workshop's frame are written to the folder as PNGs and the workshop's report is printed; its slider drags are timed;
/// the app quits at the end. With `METALRENDERER_PLANTS=builtin`, and run as a copy of the binary under another name:
/// its settings and its draft (UserDefaults, named after the executable) are then not the user's.
enum PlantEditorScript {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["METALRENDERER_PLANT_SCRIPT"].map { URL(fileURLWithPath: $0) }
    }

    static func run(_ panel: PlantEditorPanel, controller: RendererController, renderer: Renderer) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let m = panel.model
        var k = 0
        func shot(_ name: String) {
            k += 1
            let s = controller.status?.plantStats
            print("plant script \(k) \(name): stage \(m.scene.plants.stage) shown \(s?.stage ?? -99), previewed \(m.previewed?.name ?? "-"), pinned \(m.pinned.map(String.init) ?? "-"), "
                  + "\(s?.traced ?? 0) triangles traced, \(s?.leafTriangles ?? 0) leaves, height \(s?.height ?? 0), thumbnails \(m.thumbnails.images.count), "
                  + "problem \(m.previewed.flatMap { m.stageProblem($0.id) } ?? "none")")
            fflush(stdout)
            let file = String(format: "%02d-%@", k, name.replacingOccurrences(of: " ", with: "-"))
            if let view = panel.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(file + "-editor.png"))
            }
            let url = folder.appendingPathComponent(file + "-workshop.png")
            renderer.perform { $0.captureFrame(to: url, scale: 0.5) { _ in } }
        }
        /// A click where a node is, or at a point of it (the graph's units from its corner), as the window gets it.
        func click(_ node: PlantNode, at offset: SIMD2<Float>? = nil) {
            guard let content = panel.panel.contentView, let host = content.subviews(of: GraphHostingView.self).first else { return }
            let v = m.viewPoint((node.at ?? .zero) + (offset ?? PlantGraphLayout.size / 2 - [40, 0]))
            let at = host.convert(NSPoint(x: v.x, y: host.isFlipped ? v.y : host.bounds.height - v.y), to: nil)
            func send(_ type: NSEvent.EventType) {
                if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    panel.panel.sendEvent(e)
                }
            }
            send(.leftMouseDown)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { send(.leftMouseUp) }
        }
        func node(_ kind: PlantNodeKind, _ side: PlantSide = .plant) -> PlantNode? { m.graph.first(kind, side) }
        /// 45 edits of the plant's Grower 30 times a second, as a slider sends them: how long the main thread took
        /// over each and how late its next one came, and how many workshops got made.
        func drag(_ name: String, _ done: @escaping () -> Void) {
            guard let grow = node(.grow), case .grow(let start) = grow.settings else { return done() }
            var i = 0, edit = [Double](), late = [Double](), made = 0, last = controller.status?.plantStats
            var at = CACurrentMediaTime()
            let began = at
            m.beginDrag()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler {
                let now = CACurrentMediaTime()
                if i > 0 { late.append(max(now - at - 1.0 / 30, 0) * 1000) }
                at = now
                var p = start
                p.cycles = max(start.cycles - 6, 1) + (i / 3) % 7
                p.trunk.segment = start.trunk.segment * (1 + 0.1 * sin(Float(i) * 0.2))
                m.setSettings(grow.id, .grow(p))
                edit.append((CACurrentMediaTime() - now) * 1000)
                let stats = controller.status?.plantStats
                if stats != last { made += 1; last = stats }
                i += 1
                guard i >= 45 else { return }
                timer.cancel()
                m.endDrag()
                let mean = { (a: [Double]) in a.reduce(0, +) / Double(max(a.count, 1)) }
                print(String(format: "plant script drag %@: edit %.2f ms mean, %.2f worst; timer late %.2f ms mean, %.2f worst; %d workshops in %.1f s; last built in %.1f ms",
                             name, mean(edit), edit.max() ?? 0, mean(late), late.max() ?? 0, made, CACurrentMediaTime() - began, last?.buildMs ?? 0))
                fflush(stdout)
                done()
            }
            timer.resume()
        }

        var steps: [(String, Double, () -> Void)] = [
            ("open", 3, { panel.panel.makeKeyAndOrderFront(nil); m.frameAll(in: m.canvasSize) }),
            ("the whole oak", 2, {}),
        ]
        for (name, kind, side) in [("grower", PlantNodeKind.grow, PlantSide.plant), ("grafts", .grafts, .plant), ("carve", .carve, .plant), ("wood", .skeleton, .plant),
                                   ("twigs hung", .distribute, .plant), ("output", .output, .plant), ("twig grower", .grow, .twig), ("twig wood", .skeleton, .twig),
                                   ("twig leaves", .leaves, .twig), ("twig", .twig, .twig), ("palette", .palette, .twig)] {
            steps.append((name, 2, { node(kind, side).map { click($0) } }))
        }
        steps += [
            ("the plant framed again", 2, { node(.skeleton).map { click($0) } }),
            ("pinned by its button", 2, { node(.skeleton).map { click($0, at: [PlantGraphLayout.size.x - 12, 12]) } }),
            ("the grower selected, the wood pinned", 2, { node(.grow).map { click($0) } }),
            ("unpinned by P", 2, { m.togglePin(m.pinned) }),
        ]
        func queue(_ i: Int) {
            guard i < steps.count else {
                // The drags, the Grower selected in all of them (its inspector open): the Output pinned and no thumbnails
                // (as it was before them), with them, and at the Grower itself. A first drag warms up.
                // (Selected through the model: a window on a locked screen gets no clicks.)
                node(.grow).map { m.click("\($0.id)", extend: false) }
                m.togglePin(node(.output)?.id)
                m.thumbnailsWanted = false
                print("plant script drags")
                fflush(stdout)
                let rest = 2.0
                DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                    drag("warm-up") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                            drag("whole plant, no thumbnails") {
                                m.thumbnailsWanted = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                                    drag("whole plant, thumbnails") {
                                        m.togglePin(m.pinned)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                                            drag("at the grower, thumbnails") {
                                                DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                                                    shot("after the drags")
                                                    codeNode()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return
            }
            let (name, wait, action) = steps[i]
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                shot(name)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { queue(i + 1) }
            }
        }
        /// A Swift Code node on the twigs' places: nothing with a shape; a Carve with its pin not wired.
        func codeNode() {
            guard let hung = node(.distribute) else { return finish() }
            m.selection = ["\(hung.id)"]
            m.addNode(.code, at: [560, 300])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                shot("swift code on twig places")
                m.selection = []
                m.addNode(.carve, at: [560, 420])
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    shot("carve not wired")
                    drag("nodes off the chain") { finish() }
                }
            }
        }
        /// The Project Graph, closed through all of that, opened (it catches up then) and written to the folder too.
        func finish() {
            controller.onToggleProjectGraph?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if let window = NSApp.windows.first(where: { $0.title == "Project Graph" && $0.isVisible }), let view = window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("project-graph.png"))
                    print("plant script project graph open")
                }
                print("plant script done")
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { queue(0) }
    }
}
