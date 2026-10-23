import AppKit
import EngineCore
import Foundation
import Metal
import MetalRenderer
import Modeling
import simd

/// A Modeller for the tools and scripts to drive (README, "Scripts"): its own document, viewport and Rendered stage,
/// offscreen, in a headless app or beside the window's (whose Modeller it never touches). The socket's `modeller`
/// request, the MCP server's `modeller` tool, `Tools/script.py --modeller` and a full-form script's `run.modeller` all
/// come here: steps (ModellerStep) done as a user's keys, clicks and drags would be, its state, its pictures.
///
/// The Modeller lives on the main thread: each step goes there and back, one at a time, and the waits (a stage
/// settling, `wait`, the scene's selection opening) happen on the caller's thread between them. From the render thread
/// (a short script, `run.render {}`) that would never return: the calls fail there instead.
package final class ScriptModeller {
    package typealias Failure = ScriptRequests.Failure

    /// What a capture shows: the viewport as its renderer draws it, the whole window as AppKit draws it, or the
    /// Rendered view's stage (the engine's path tracer).
    package enum View: String, CaseIterable {
        case viewport, window, rendered
    }

    /// The app's (registered at launch), or one made for the renderer a script runs in.
    private static let lock = NSLock()
    private static var shared: ScriptModeller?

    /// The socket's `modeller` request answered by the app's ScriptModeller, made on `renderer`. Main thread.
    package static func register(renderer: Renderer) {
        let m = modeller(for: renderer)
        ScriptRequests.register("modeller") { body in m.request(body) }
    }

    package static func modeller(for renderer: Renderer) -> ScriptModeller {
        lock.lock()
        defer { lock.unlock() }
        if let s = shared, s.renderer === renderer { return s }
        let s = ScriptModeller(device: renderer.metalDevice, renderer: renderer)
        shared = s
        return s
    }

    /// The app's renderer: its scene (where saved assets go), its scripts' folder (nil in the tests: no scene).
    package let renderer: Renderer?
    private let device: MTLDevice
    /// The Modeller while there is one (made by the first step, dropped by `close`). Main thread.
    private var session: Session?

    private final class Session {
        let model: ModelingModel
        let host: RendererModelingHost?   // (the model holds it weakly)
        /// The popup the last key opened (W, X, M, Shift-A …), for `pick`.
        var popup: ModelingMenu?

        init(device: MTLDevice, renderer: Renderer?) throws {
            host = renderer.map { RendererModelingHost(renderer: $0) }
            model = ModelingModel(host: host)
            model.renderer = try ViewportRenderer(device: device)
            model.scene = ViewportScene(device: device)
            model.viewSize = [1000, 640]
            model.pixelScale = 2
            model.presentMenu = { [weak self] menu, _ in self?.popup = menu }
            // The Rendered view draws into textures, the size of the viewport's pixels.
            model.stageSurface = { [weak model] device in
                let size = model?.viewSize ?? [1000, 640], scale = model?.pixelScale ?? 2
                return OffscreenSurface(device: device, pointSize: CGSize(width: CGFloat(size.x), height: CGFloat(size.y)),
                                        backingScale: CGFloat(scale))
            }
        }
    }

    /// A ScriptModeller of its own (the tests'): `renderer` nil has no scene to save into or take a selection from.
    init(device: MTLDevice, renderer: Renderer? = nil) {
        self.device = device
        self.renderer = renderer
    }

    // MARK: - The socket's request

    /// `{"steps": [...], "state": true, "capture": "window" | {"view": "rendered", "scale": 0.5, "path": "…", "frames": 32}}`:
    /// the steps in order, then the state (unless `"state": false`), then the picture.
    func request(_ body: Any) -> Result<[String: Any], Failure> {
        guard let body = body as? [String: Any] else {
            return .failure(Failure("give an object: {\"steps\": [...], \"state\": true, \"capture\": \"viewport\"}", badRequest: true))
        }
        var steps: [ModellerStep] = []
        if let list = body["steps"] {
            switch ModellerStep.decode(list: list) {
            case .success(let s): steps = s
            case .failure(let f): return .failure(f)
            }
        }
        var capture: (view: View, scale: Double, path: String?, frames: Int)?
        if let c = body["capture"] {
            let options = c as? [String: Any] ?? [:]
            let name = c as? String ?? options["view"] as? String ?? "viewport"
            guard let view = View(rawValue: name) else {
                return .failure(Failure("capture: one of \(View.allCases.map(\.rawValue).joined(separator: ", "))", badRequest: true))
            }
            capture = (view, (options["scale"] as? NSNumber)?.doubleValue ?? (body["scale"] as? NSNumber)?.doubleValue ?? 1,
                       options["path"] as? String, options["frames"] as? Int ?? 32)
        }
        do {
            var answer: [String: Any] = [:]
            if !steps.isEmpty { answer["steps"] = try perform(steps) }
            if body["state"] as? Bool ?? true { answer["state"] = try state() }
            if let c = capture { answer["capture"] = try self.capture(c.view, scale: c.scale, to: c.path, frames: c.frames).path }
            return .success(answer)
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(Failure("\(error)"))
        }
    }

    // MARK: - Steps

    /// Does `steps` in order; what each said (the Modeller's message, or what didn't happen). The first that fails
    /// stops the rest.
    @discardableResult
    func perform(_ steps: [ModellerStep]) throws -> [String] {
        var notes: [String] = []
        for (k, step) in steps.enumerated() {
            do {
                notes.append(try perform(step))
            } catch let f as Failure {
                throw Failure("step \(k + 1) of \(steps.count): \(f)" + (notes.isEmpty ? "" : " (done before it: \(notes.joined(separator: "; ")))"))
            }
        }
        return notes
    }

    private func perform(_ step: ModellerStep) throws -> String {
        switch step {
        case .wait(let seconds):
            try offRenderThread("wait")
            Thread.sleep(forTimeInterval: seconds)
            return "waited \(seconds) s"
        case .open(.selection):
            // The scene's selection comes from the render thread, then to the main thread: wait here for it.
            let before = try onMain { () -> (Int, String) in
                let m = try model()
                guard m.host != nil else { throw Failure("no app to take the selection from") }
                m.editSceneSelection()
                return (m.revision, m.message)
            }
            let start = Date()
            while Date().timeIntervalSince(start) < 10 {
                Thread.sleep(forTimeInterval: 0.02)
                let (revision, message) = try onMain { () -> (Int, String) in let m = try model(); return (m.revision, m.message) }
                if revision != before.0 { return message }
                if message != before.1 { throw Failure(message) }
            }
            throw Failure("the scene's selection didn't come within 10 s")
        default:
            return try onMain { try execute(step) }
        }
    }

    /// One step, on the main thread.
    private func execute(_ step: ModellerStep) throws -> String {
        if case .close = step {
            if let s = session {
                s.model.cancelModal()
                if s.model.shading.mode == .rendered { s.model.shading.mode = .solid }
            }
            session = nil
            return "closed"
        }
        let s = try current()
        let m = s.model
        let message = m.message
        m.message = ""
        var note = ""
        defer { if m.message.isEmpty { m.message = message } }
        switch step {
        case .keys(let chords):
            var unused: [String] = []
            for c in chords where !key(c, in: s) { unused.append(c.description) }
            if !unused.isEmpty { note = "nothing used \(unused.joined(separator: ", "))" }
        case .type(let text):
            if m.search != nil {
                m.search?.query += text
                m.search?.selected = 0
            } else {
                for ch in text {
                    let k = ch == " " ? "space" : String(ch).lowercased()
                    _ = key(KeyChord(k, shift: ch.isUppercase), in: s)
                }
            }
        case let .click(point, button, flags, count):
            let p = try point.resolved(m)
            m.mouseMoved(to: p, flags: flags)
            for n in 1...count {
                m.mouseDown(button, at: p, flags: flags, clickCount: n)
                m.mouseUp(button, at: p, flags: flags)
            }
        case let .drag(world, button, flags, pressure):
            let points = try world.map { try $0.resolved(m) }
            func pressureAt(_ k: Int) -> Float { pressure.isEmpty ? 1 : pressure[min(k, pressure.count - 1)] }
            m.mouseMoved(to: points[0], flags: flags)
            m.mouseDown(button, at: points[0], flags: flags, pressure: pressureAt(0))
            for k in 1..<points.count { m.mouseDragged(to: points[k], flags: flags, pressure: pressureAt(k)) }
            m.mouseUp(button, at: points[points.count - 1], flags: flags)
        case .move(let p):
            m.mouseMoved(to: try p.resolved(m), flags: [])
        case let .scroll(dy, at, flags):
            if let at { m.mouseMoved(to: try at.resolved(m), flags: flags) }
            m.scroll(dx: 0, dy: dy, precise: false, flags: flags)
        case .run(let name):
            let e = try entry(named: name, in: m)
            m.runSearch(e)
            note = "ran \(e.path)"
        case .pick(let path):
            let (title, action) = try popupItem(path, in: s)
            s.popup = nil
            action()
            note = "picked \(title)"
        case .add(let p):
            m.add(p)
        case .mode(let mode):
            m.setMode(mode)
            if m.mode != mode { throw Failure(m.message.isEmpty ? "can't enter \(mode.rawValue) mode" : m.message) }
        case .selectMode(let mode):
            guard m.mode == .edit else { throw Failure("select modes are edit mode's ({\"mode\": \"edit\"} first)") }
            m.setSelectMode(mode)
        case .tool(let t):
            guard ModelingTool.tools(for: m.mode).joined().contains(t) else { throw Failure("\(m.mode.rawValue) mode has no \(t.rawValue) tool") }
            m.tool = t
        case .shading(let mode):
            m.shading.mode = mode
            if mode == .rendered && m.stage == nil { throw Failure(m.message.isEmpty ? "no Rendered view" : m.message) }
        case .workspace(let w):
            m.setWorkspace(w)
        case .brush(let b):
            m.selectBrush(b)
        case .open(let what):
            switch what {
            case .primitive(let p):
                m.replaceDocument(ModelingDocument(name: p.title, objects: [ModelObject(name: p.title, mesh: p.mesh())]))
            case .asset(let slug):
                m.open(asset: slug)
            case .file(let path):
                m.importFile(URL(fileURLWithPath: path))
            case .selection:
                break   // (perform's)
            }
            if m.message.hasPrefix("Couldn't") || m.message.hasPrefix("Can't") { throw Failure(m.message) }
        case .new:
            m.newDocument()
        case .save(let name):
            m.save(as: name)
            if m.message.hasPrefix("Couldn't") || m.message.hasPrefix("No model folder") { throw Failure(m.message) }
        case .place:
            guard let slug = m.document.asset else { throw Failure("the model isn't saved: {\"save\": \"Name\"} first") }
            guard let host = m.host else { throw Failure("no app scene to place it in") }
            host.placeModelAsset(slug)
            note = "placed mesh:\(slug)"
        case .size(let size):
            m.viewSize = size
            m.redraw()
            if m.stage != nil { note = "the Rendered view keeps its size until it is shown again" }
        case .wait, .close:
            break   // (perform's, and above)
        }
        if !m.message.isEmpty { note = note.isEmpty ? m.message : "\(note); \(m.message)" }
        return note
    }

    /// A key as the window would take it: the open search's field first, then the viewport's keymap. False if nothing
    /// used it.
    private func key(_ c: KeyChord, in s: Session) -> Bool {
        let m = s.model
        if m.search != nil {
            switch c.key {
            case "esc": m.closeSearch()
            case "return", "numpadenter": m.searchRun()
            case "up": m.searchMove(-1)
            case "down": m.searchMove(1)
            case "backspace": m.search?.query = String((m.search?.query ?? "").dropLast()); m.search?.selected = 0
            case "space": m.search?.query += " "; m.search?.selected = 0
            default:
                guard c.key.count == 1, !c.ctrl, !c.cmd else { return false }
                m.search?.query += c.shift ? c.key.uppercased() : c.key
                m.search?.selected = 0
            }
            return true
        }
        // A key that opens a popup replaces the last one; any other leaves it (a pick follows its key).
        return m.keyDown(c)
    }

    /// The operator `name` names: the mode's menus' entry of that title, or the one whose menu path has every word
    /// of it. Several or none: the error lists what there is.
    private func entry(named name: String, in m: ModelingModel) throws -> SearchEntry {
        let all = m.searchEntries()
        let q = name.lowercased().replacingOccurrences(of: ">", with: "▸")
        if let e = all.first(where: { $0.title.lowercased() == q || $0.path.lowercased() == q }) { return e }
        let words = q.split(whereSeparator: { $0 == " " || $0 == "▸" }).map(String.init)
        let found = all.filter { e in words.allSatisfy { e.path.lowercased().contains($0) } }
        if found.count == 1 { return found[0] }
        if found.isEmpty {
            throw Failure("\(m.mode.rawValue) mode has no operator \"\(name)\"; it has: \(all.map(\.title).joined(separator: ", "))")
        }
        throw Failure("\"\(name)\" names \(found.count) operators: \(found.prefix(12).map(\.path).joined(separator: "; "))")
    }

    /// The last popup's item that `path` names (its title, or the submenus' titles then its, split by ▸ or >).
    private func popupItem(_ path: String, in s: Session) throws -> (String, () -> Void) {
        guard let menu = s.popup else { throw Failure("no popup is open: a key that opens one first (w, x, m, shift+a, ctrl+e …)") }
        let want = path.replacingOccurrences(of: ">", with: "▸").split(separator: "▸").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var found: [(String, () -> Void)] = []
        for (titles, item) in ScriptModeller.items(of: menu) {
            guard let action = item.action else { continue }
            let have = titles.map { $0.lowercased() }
            if have.count >= want.count, Array(have.suffix(want.count)) == want { found.append((titles.joined(separator: " ▸ "), action)) }
        }
        if found.count == 1 { return found[0] }
        let all = ScriptModeller.items(of: menu).filter { $0.1.action != nil }.map { $0.0.joined(separator: " ▸ ") }
        if found.isEmpty { throw Failure("the \(menu.title) popup has no \"\(path)\"; it has: \(all.joined(separator: ", "))") }
        throw Failure("\"\(path)\" names \(found.count) items of the \(menu.title) popup: \(found.map(\.0).joined(separator: "; "))")
    }

    /// A menu's items with the titles of the submenus they are in, then their own.
    private static func items(of menu: ModelingMenu, in path: [String] = []) -> [([String], ModelingMenu.Item)] {
        var out: [([String], ModelingMenu.Item)] = []
        for item in menu.items where !item.separator {
            let p = path + [item.title]
            if let sub = item.submenu { out += items(of: sub, in: p) } else { out.append((p, item)) }
        }
        return out
    }

    // MARK: - State

    /// The Modeller as JSON: the mode and tools, the operator running and its hints, the popup or search open, the
    /// document's objects (counts, selection, modifiers, bounds), sculpt mode's mesh, the camera, the stage.
    func state() throws -> [String: Any] {
        try onMain {
            let s = try current()
            let m = s.model
            func xyz(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }
            let names: [SelectMode: String] = [.vertex: "vertex", .edge: "edge", .face: "face"]
            var out: [String: Any] = [
                "mode": m.mode.rawValue, "selectMode": names[m.selectMode] ?? "", "tool": m.tool.rawValue,
                "workspace": m.workspace.rawValue, "shading": m.shading.mode.rawValue, "xray": m.shading.xray,
                "statistics": m.statistics, "message": m.message, "operatorStatus": m.operatorStatus,
                "hints": m.hints.map { "\($0.0): \($0.1)" }, "dirty": m.dirty,
                "undo": m.undo.canUndo ? m.undo.undoActionName : "", "redo": m.undo.canRedo ? m.undo.redoActionName : "",
                "viewSize": [Double(m.viewSize.x), Double(m.viewSize.y)],
                "camera": ["target": xyz(m.camera.target), "distance": Double(m.camera.distance), "eye": xyz(m.camera.eye),
                           "forward": xyz(m.camera.forward), "fovY": Double(m.camera.fovY)],
                "cursor": xyz(m.document.cursor),
                "stage": m.stage != nil,
            ]
            if let op = m.modal { out["modal"] = ["name": op.name, "type": String(describing: Swift.type(of: op))] }
            if let menu = s.popup {
                out["popup"] = ["title": menu.title, "items": ScriptModeller.items(of: menu).filter { $0.1.action != nil }.map { $0.0.joined(separator: " ▸ ") }]
            }
            if let search = m.search {
                out["search"] = ["query": search.query, "selected": search.selected, "results": m.searchResults(search.query).prefix(14).map(\.path)]
            }
            let d = m.document
            out["document"] = [
                "name": d.name, "asset": d.asset ?? "", "active": d.active ?? -1,
                "objects": d.objects.map { o -> [String: Any] in
                    let mesh = o.mesh
                    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                    let mat = o.transform.matrix
                    for p in mesh.positions {
                        let q = mat * SIMD4(p, 1)
                        lo = simd_min(lo, SIMD3(q.x, q.y, q.z))
                        hi = simd_max(hi, SIMD3(q.x, q.y, q.z))
                    }
                    var e: [String: Any] = [
                        "name": o.name, "selected": d.selection.contains(o.id), "visible": o.visible,
                        "vertices": mesh.vertexCount, "edges": mesh.edgeCount, "faces": mesh.faceCount,
                        "selectedVertices": mesh.selectedVertices.count, "selectedEdges": mesh.selectedEdges.count,
                        "selectedFaces": mesh.selectedFaces.count, "closedManifold": mesh.isClosedManifold(),
                        "modifiers": o.modifiers.map(\.kind.rawValue), "materials": o.materials.map(\.name),
                        "location": xyz(o.transform.location), "rotation": xyz(o.transform.rotation), "scale": xyz(o.transform.scale),
                    ]
                    if mesh.vertexCount > 0 { e["bounds"] = [xyz(lo), xyz(hi)] }
                    if o.multires != nil { e["multires"] = true }
                    return e
                },
            ] as [String: Any]
            if let sc = m.sculpt {
                out["sculpt"] = ["brush": m.sculptBrush.kind.rawValue, "radius": Double(m.sculptBrush.radius),
                                 "strength": Double(m.sculptBrush.strength), "vertices": sc.vertexCount,
                                 "triangles": sc.triangleCount, "dyntopo": m.dyntopo]
            }
            return out
        }
    }

    // MARK: - Pictures

    /// A picture of `view` as a PNG (default: in the scripts' folder, under `captures`), `scale` times its size. The
    /// Rendered view's after its stage is in and `frames` more frames (its GI settling).
    @discardableResult
    package func capture(_ view: View = .viewport, scale: Double = 1, to path: String? = nil, frames: Int = 32) throws -> URL {
        let folder = (renderer?.scripts?.workDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent("captures")
        let url = path.map { URL(fileURLWithPath: $0) }
            ?? folder.appendingPathComponent("modeller-\(view.rawValue)-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        switch view {
        case .viewport:
            try onMain {
                guard let image = ModelingPictures.viewport(try model()) else { throw Failure("the viewport drew nothing") }
                try ModelingPictures.write(image, to: url, scale: scale)
            }
        case .window:
            try onMain {
                let m = try model()
                // (The window sized so its viewport is the script's: the picture's points are the clicks'.)
                let size = m.viewSize, pixels = m.pixelScale
                defer { m.viewSize = size; m.pixelScale = pixels }
                guard let image = ModelingPictures.window(m, viewport: size)?.cgImage else { throw Failure("the window drew nothing") }
                try ModelingPictures.write(image, to: url, scale: scale)
            }
        case .rendered:
            try offRenderThread("a Rendered capture")
            guard let stage = try onMain({ try model().stage }) else {
                throw Failure("no Rendered view: {\"shading\": \"rendered\"} first")
            }
            // The model goes to the stage a moment after its last change (StageRenderer.show), then the scene is made.
            Thread.sleep(forTimeInterval: 0.35)
            let start = Date()
            while !onStage(stage, { $0.sceneSettled }) {
                if Date().timeIntervalSince(start) > 120 { throw Failure("the stage isn't in after 120 s") }
                Thread.sleep(forTimeInterval: 1.0 / 120)
            }
            let first = onStage(stage) { $0.frameIndex }
            while onStage(stage, { $0.frameIndex }) &- first < UInt32(max(frames, 0)) {
                if Date().timeIntervalSince(start) > 180 { break }
                Thread.sleep(forTimeInterval: 1.0 / 120)
            }
            let done = DispatchSemaphore(value: 0)
            var written = false
            stage.renderer.perform { $0.captureFrame(to: url, scale: scale) { ok in written = ok; done.signal() } }
            guard done.wait(timeout: .now() + 30) == .success, written else { throw Failure("the stage gave no frame") }
        }
        return url
    }

    /// `body` on the stage's render thread, waited for.
    private func onStage<T>(_ stage: StageRenderer, _ body: @escaping (Renderer) -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        stage.renderer.perform { r in
            result = body(r)
            done.signal()
        }
        done.wait()
        return result!
    }

    // MARK: - The Swift API (a full-form script's `run.modeller`)

    /// Chords through the keymap, e.g. `"tab 3 ctrl+r"`.
    @discardableResult package func keys(_ chords: String) throws -> String { try one(ModellerStep.chords(chords).get()).first ?? "" }
    /// Each character a key (a typed value), or F3's search query.
    package func type(_ text: String) throws { try one(.type(text)) }
    package func click(_ x: Float, _ y: Float, button: String = "left", mods: String = "", count: Int = 1) throws {
        guard let b = ModellerStep.button(named: button) else { throw Failure("button is left, right or middle") }
        try one(.click(.screen([x, y]), button: b, flags: ModellerStep.modifiers(mods), count: max(1, count)))
    }
    /// A click where the camera shows `world`.
    package func click(world: SIMD3<Float>, button: String = "left", mods: String = "", count: Int = 1) throws {
        guard let b = ModellerStep.button(named: button) else { throw Failure("button is left, right or middle") }
        try one(.click(.world(world), button: b, flags: ModellerStep.modifiers(mods), count: max(1, count)))
    }
    /// Where the camera shows `world` in the viewport (points from its top left), nil behind it.
    package func point(_ world: SIMD3<Float>) throws -> SIMD2<Float>? {
        try onMain { let m = try model(); return m.camera.project(world, size: m.viewSize).map { SIMD2($0.x, $0.y) } }
    }
    /// Press at the first point, a move to each of the others, release at the last (a sculpt stroke: with `pressure`).
    package func drag(_ points: [SIMD2<Float>], button: String = "left", mods: String = "", pressure: [Float] = []) throws {
        guard points.count >= 2 else { throw Failure("drag: two points or more") }
        guard let b = ModellerStep.button(named: button) else { throw Failure("button is left, right or middle") }
        try one(.drag(points.map { .screen($0) }, button: b, flags: ModellerStep.modifiers(mods), pressure: pressure))
    }
    package func move(_ x: Float, _ y: Float) throws { try one(.move(.screen([x, y]))) }
    /// An operator of the mode's menus by name or menu path ("Bridge Edge Loops", "Edge ▸ Spin").
    @discardableResult package func run(_ name: String) throws -> String { try one(.run(name)).first ?? "" }
    /// An item of the popup the last key opened.
    @discardableResult package func pick(_ path: String) throws -> String { try one(.pick(path)).first ?? "" }
    package func add(_ p: Primitive) throws { try one(.add(p)) }
    package func open(_ p: Primitive) throws { try one(.open(.primitive(p))) }
    package func mode(_ m: EditorMode) throws { try one(.mode(m)) }
    /// Any steps as the socket takes them (`[["keys": "tab"], ["click": [500, 320]]]`).
    @discardableResult package func perform(json steps: [Any]) throws -> [String] { try perform(ModellerStep.decode(list: steps).get()) }
    /// The Modeller as JSON, as the `modeller` request's `state`.
    package var json: [String: Any] { get throws { try state() } }
    /// The document as it is (its objects' meshes, modifiers, materials).
    package var document: ModelingDocument { get throws { try onMain { try model().document } } }
    /// The document changed as one undo step.
    package func edit(_ name: String = "Script", _ change: @escaping (inout ModelingDocument) -> Void) throws {
        try onMain { try model().edit(name, change) }
    }
    /// The Modeller goes (its stage stops); the next call makes a new one.
    package func close() throws { try one(.close) }

    @discardableResult private func one(_ step: ModellerStep) throws -> [String] { try perform([step]) }
    @discardableResult private func one(_ chords: [KeyChord]) throws -> [String] { try perform([.keys(chords)]) }

    // MARK: - Threads

    private func model() throws -> ModelingModel { try current().model }

    /// The session, made the first time. Main thread.
    private func current() throws -> Session {
        if let s = session { return s }
        let s = try Session(device: device, renderer: renderer)
        session = s
        return s
    }

    private func offRenderThread(_ what: String) throws {
        if renderer?.renderThread.isCurrent == true {
            throw Failure("\(what) on the render thread (a short script, render {}, onFrame) would never return: drive the Modeller "
                          + "from a full-form script (func run(_ run: ScriptRun)) or the modeller command")
        }
    }

    /// `body` on the main thread, waited for.
    private func onMain<T>(_ body: () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        try offRenderThread("the Modeller")
        var result: Result<T, Error>!
        DispatchQueue.main.sync { result = Result { try body() } }
        return try result.get()
    }
}

extension ScriptRun {
    /// The app's scripted Modeller (ScriptModeller): offscreen, never the window's. From the full form only.
    package var modeller: ScriptModeller { ScriptModeller.modeller(for: renderer) }
}
