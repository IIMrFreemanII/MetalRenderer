import AppKit
import Characters
import EngineCore
import Foundation
import Garments
import MetalRenderer
import Physics
import SwiftUI
import simd

/// The Garment Designer's state: the garment being made (its panels, seams, fabrics), what is selected, the 2D tools,
/// and the 3D stage that drapes it (GarmentStageRenderer). Every edit is one undo step; a moment after the last, the
/// garment goes to the stage with its drape carried over (GarmentBuild.carry), so the cloth goes on from where it was.
final class GarmentModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select, editPoint, polygon, rectangle, circle, line, dart, seam, freeze, trace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: return "Select / Move (A)"
            case .editPoint: return "Edit Points (Z)"
            case .polygon: return "Polygon (H)"
            case .rectangle: return "Rectangle (S)"
            case .circle: return "Circle (E)"
            case .line: return "Internal Line (G)"
            case .dart: return "Dart (D)"
            case .seam: return "Sew Segments (N)"
            case .freeze: return "Freeze (F)"
            case .trace: return "Trace on Avatar (T)"
            }
        }
        var symbol: String {
            switch self {
            case .select: return "arrow.up.left.and.arrow.down.right"
            case .editPoint: return "point.topleft.down.curvedto.point.bottomright.up"
            case .polygon: return "pentagon"
            case .rectangle: return "rectangle"
            case .circle: return "circle"
            case .line: return "line.diagonal"
            case .dart: return "triangle"
            case .seam: return "link"
            case .freeze: return "snowflake"
            case .trace: return "scribble"
            }
        }
        var key: String {
            switch self {
            case .select: return "a"
            case .editPoint: return "z"
            case .polygon: return "h"
            case .rectangle: return "s"
            case .circle: return "e"
            case .line: return "g"
            case .dart: return "d"
            case .seam: return "n"
            case .freeze: return "f"
            case .trace: return "t"
            }
        }
    }

    enum Tab: String, CaseIterable { case garment = "Garment", panel = "Panel", seam = "Seam", fabric = "Fabric", avatar = "Body" }

    @Published var garment: Garment
    @Published var selection: Set<Int> = []
    @Published var selectedPoint: (panel: Int, point: Int)?
    @Published var selectedSeam: Int?
    @Published var tool: Tool = .select { didSet { draft = []; seamDraft = ([], []) } }
    @Published var tab: Tab = .garment
    @Published var simulating = true
    @Published var avatar: String = GarmentAvatar.yBot
    @Published var report: GarmentReport?
    @Published var message = ""
    /// The saved file's id (nil: never saved), and whether there are edits since.
    @Published var fileID: String?
    @Published var dirty = false
    // Display.
    @Published var snap = true
    @Published var showAllowance = false
    @Published var showLengths = true
    @Published var allowance: Float = 0.01
    /// The polygon or line being drawn (sheet points), and the seam being made (its two sides).
    @Published var draft: [SIMD2<Float>] = []
    @Published var seamDraft: (a: [SeamEnd], b: [SeamEnd]) = ([], [])
    /// The trace on the avatar (3D points on its body).
    @Published var trace: [SIMD3<Float>] = []
    /// The 2D view: the sheet point at the canvas's middle and the pixels a metre.
    @Published var pan = SIMD2<Float>(1.2, 0.5)
    @Published var zoom: Float = 320
    /// The 3D view's orbit.
    @Published var orbit = Orbit()
    /// A script's picture of the stage, drawn in the 3D view's place (the window drawn offscreen has no layer to show).
    @Published var stagePicture: CGImage?
    /// Where the 3D view is in the window (top-left points), for a script's picture of it.
    var viewportRect: CGRect = .zero

    let undo = UndoManager()
    var stage: GarmentStageRenderer?
    /// Makes the stage (the window's: a layer; a script's: offscreen textures).
    var makeStage: (() -> GarmentStageRenderer?)?
    private var pending: DispatchWorkItem?
    private var pushing = false, pushAgain = false
    private let builds = DispatchQueue(label: "MetalRenderer.garments", qos: .userInitiated)
    private var reportTimer: Timer?
    var measurements = BodyMeasurements()

    struct Orbit: Equatable {
        var target = SIMD3<Float>(0, 1.05, 0)
        var yaw: Float = 0
        var pitch: Float = -0.08
        var distance: Float = 3.2
        var fovY: Float = 0.75

        var forward: SIMD3<Float> { SIMD3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)) }
        var eye: SIMD3<Float> { target - forward * distance }
    }

    init() {
        let m = BodyMeasurements()
        garment = GarmentTemplate.make(.tshirt, GarmentTemplate.params(.tshirt, body: m), body: m)
        undo.levelsOfDetail()
    }

    // MARK: - The stage

    /// The stage made (if it isn't), showing the garment.
    func startStage() {
        guard stage == nil, let s = makeStage?() else { return }
        stage = s
        s.setCamera(orbit)
        measurements = GarmentAvatars.character(avatar).map(BodyMeasurements.measure) ?? BodyMeasurements()
        push(carry: false)
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollReport() }
    }

    func stopStage() {
        reportTimer?.invalidate()
        reportTimer = nil
        stage?.stop()
        stage = nil
    }

    private func pollReport() {
        stage?.renderer.perform { r in
            let report = r.garmentReport
            DispatchQueue.main.async { [weak self] in if self?.report != report { self?.report = report } }
        }
    }

    /// The garment to the stage a moment after the last change, its drape carried over.
    func scheduleRebuild(delay: Double = 0.18) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.push(carry: true) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Sends the garment: the stage's drape read, the new build's carried from it (in the background), registered,
    /// and named in the stage's settings.
    func push(carry: Bool) {
        guard let stage else { return }
        if pushing { pushAgain = true; return }
        pushing = true
        let g = garment, avatar = self.avatar, simulate = simulating
        let send: (Garment) -> Void = { [weak self] g in
            let key = GarmentCatalog.register(g)
            stage.show(garment: key, avatar: avatar, simulate: simulate)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pushing = false
                if self.pushAgain { self.pushAgain = false; self.push(carry: true) }
            }
        }
        guard carry else { builds.async { send(g) }; return }
        stage.renderer.perform { [weak self] r in
            let drape = r.garmentDrape()
            self?.builds.async {
                var g = g
                if let drape, drape.build.particleCount > 0, r.scene.settings.garmentWorkshop.avatar == avatar {
                    let build = GarmentBuild.make(g)
                    g.drape = build.carry(from: drape.build, positions: drape.positions)
                }
                send(g)
            }
        }
    }

    /// Placed round the body again and sewn from the start.
    func resetDrape() { push(carry: false) }

    func toggleSimulation() {
        simulating.toggle()
        let on = simulating
        stage?.renderer.perform { $0.setGarmentSimulating(on) }
    }

    func setAvatar(_ name: String) {
        guard name != avatar else { return }
        avatar = name
        measurements = GarmentAvatars.character(name).map(BodyMeasurements.measure) ?? BodyMeasurements()
        push(carry: false)
    }

    // MARK: - Edits

    /// One undo step: `change` applied to the garment, mirrored panels kept in step, the stage told.
    func edit(_ name: String, rebuild: Bool = true, _ change: (inout Garment) -> Void) {
        let before = garment
        var g = garment
        change(&g)
        guard g != before else { return }
        syncMirrors(&g, from: before)
        set(g, name: name, previous: before)
        if rebuild { scheduleRebuild() }
    }

    private func set(_ g: Garment, name: String, previous: Garment) {
        undo.registerUndo(withTarget: self) { m in
            let now = m.garment
            m.set(previous, name: name, previous: now)
            m.scheduleRebuild()
        }
        undo.setActionName(name)
        garment = g
        dirty = true
        selection = selection.filter { g.panel(id: $0) != nil }
    }

    /// A drag's edits as one undo step: the garment before it is kept, each move changes it in place.
    private var dragStart: Garment?
    func beginDrag() { dragStart = garment }
    func dragEdit(_ change: (inout Garment) -> Void) {
        var g = garment
        change(&g)
        syncMirrors(&g, from: garment)
        garment = g
        dirty = true
        scheduleRebuild(delay: 0.12)
    }
    func endDrag(_ name: String) {
        guard let start = dragStart else { return }
        dragStart = nil
        if start != garment {
            let now = garment
            garment = start
            set(now, name: name, previous: start)
        }
    }

    /// A panel and its mirror move together: whichever changed, the other made its mirror image again where it was.
    private func syncMirrors(_ g: inout Garment, from before: Garment) {
        for i in g.panels.indices {
            guard let source = g.panels[i].mirrorOf, let si = g.panelIndex(id: source) else { continue }
            let mirror = g.panels[i], original = g.panels[si]
            let oldMirror = before.panel(id: mirror.id), oldOriginal = before.panel(id: source)
            let mirrorShape = oldMirror.map { $0.points != mirror.points || $0.lines != mirror.lines } ?? false
            let originalShape = oldOriginal.map { $0.points != original.points || $0.lines != original.lines } ?? false
            if originalShape && !mirrorShape {
                var m = original.mirrored(axis: original.centre.x)
                m.translate(SIMD2(mirror.centre.x - m.centre.x, mirror.centre.y - m.centre.y))
                g.panels[i].points = m.points
                g.panels[i].lines = m.lines
            } else if mirrorShape && !originalShape {
                var o = mirror.mirrored(axis: mirror.centre.x)
                o.translate(SIMD2(original.centre.x - o.centre.x, original.centre.y - o.centre.y))
                g.panels[si].points = o.points
                g.panels[si].lines = o.lines
            }
        }
    }

    // MARK: - Panels

    func addPanel(_ name: String, _ points: [PathPoint]) {
        var made = 0
        edit("New Panel") { g in
            var p = Panel(id: g.nextPanelID, name: name, points: points)
            if p.signedArea < 0 { p.points = p.points.reversed().map { PathPoint($0.p, handleIn: $0.handleOut, handleOut: $0.handleIn, smooth: $0.smooth) } }
            p.arrangement = Arrangement(slot: .chestFront, offset: SIMD2(0, measurements.chestHeight))
            made = p.id
            g.panels.append(p)
        }
        selection = [made]
        tab = .panel
    }

    func deleteSelection() {
        if let s = selectedSeam {
            edit("Delete Seam") { g in g.seams.removeAll { $0.id == s } }
            selectedSeam = nil
            return
        }
        if let sp = selectedPoint {
            edit("Delete Point") { g in
                guard let i = g.panelIndex(id: sp.panel), g.panels[i].points.count > 3 else { return }
                g.panels[i].points.remove(at: sp.point)
                g.seams.removeAll { ($0.a + $0.b).contains { $0.panel == sp.panel } }
            }
            selectedPoint = nil
            return
        }
        guard !selection.isEmpty else { return }
        let gone = selection
        edit("Delete Panels") { g in
            g.panels.removeAll { gone.contains($0.id) }
            for i in g.panels.indices where g.panels[i].mirrorOf.map(gone.contains) == true { g.panels[i].mirrorOf = nil }
            g.seams.removeAll { ($0.a + $0.b).contains { gone.contains($0.panel) } }
            g.buttons.removeAll { gone.contains($0.panel) || gone.contains($0.holePanel) }
        }
        selection = []
    }

    /// The selected panels copied beside themselves (their mirror images with Shift: linked, they change together).
    func duplicateSelection(mirrored: Bool) {
        let ids = selection
        var made: Set<Int> = []
        edit(mirrored ? "Mirror Panels" : "Duplicate Panels") { g in
            for id in ids.sorted() {
                guard let p = g.panel(id: id) else { continue }
                let b = p.bounds
                var c = mirrored ? p.mirrored(axis: b.hi.x + 0.06 + (b.hi.x - b.lo.x) / 2) : p
                if !mirrored { c.translate(SIMD2(b.hi.x - b.lo.x + 0.08, 0)) }
                c.id = g.nextPanelID
                c.name = p.name + (mirrored ? " mirrored" : " copy")
                c.mirrorOf = mirrored ? p.id : nil
                if mirrored, var a = c.arrangement { a.offset.x = -a.offset.x; c.arrangement = a }
                made.insert(c.id)
                g.panels.append(c)
            }
        }
        selection = made
    }

    func updatePanels(_ name: String, _ change: @escaping (inout Panel) -> Void) {
        let ids = selection
        edit(name) { g in for i in g.panels.indices where ids.contains(g.panels[i].id) { change(&g.panels[i]) } }
    }

    // MARK: - Seams

    /// A click on edge `e` of panel `p` at fraction `f` with the seam tool: the stretch starts at the edge's end
    /// nearer the click. Shift adds to the side being made (an N:1 seam); otherwise the second side's first click
    /// makes the seam.
    func seamClick(panel p: Int, edge e: Int, at f: Float, extend: Bool) {
        let end = f < 0.5 ? SeamEnd(panel: p, edge: e) : SeamEnd(panel: p, edge: e, t0: 1, t1: 0)
        if seamDraft.b.isEmpty && (seamDraft.a.isEmpty || extend) {
            seamDraft.a.append(end)
            message = extend ? "Shift-click more edges for this side, then click the other side's" : "Now click the edge it sews to, near the end that meets this one's"
            return
        }
        seamDraft.b.append(end)
        if !extend { finishSeam() } else { message = "Shift-click more, Return to sew" }
    }

    func finishSeam() {
        let (a, b) = seamDraft
        seamDraft = ([], [])
        guard !a.isEmpty, !b.isEmpty else { return }
        var id = 0
        edit("Sew") { g in
            id = g.nextSeamID
            g.seams.append(Seam(id: id, a: a, b: b))
        }
        selectedSeam = id
        tab = .seam
        let la = a.reduce(Float(0)) { $0 + SeamSampling.length(garment, $1) }, lb = b.reduce(Float(0)) { $0 + SeamSampling.length(garment, $1) }
        message = String(format: "Sewn: %.1f cm to %.1f cm", la * 100, lb * 100)
    }

    func updateSeam(_ name: String, _ change: @escaping (inout Seam) -> Void) {
        guard let id = selectedSeam else { return }
        edit(name) { g in if let i = g.seams.firstIndex(where: { $0.id == id }) { change(&g.seams[i]) } }
    }

    /// The seams whose two sides differ by more than 3% in length (they gather or stretch).
    var mismatchedSeams: [(seam: Int, a: Float, b: Float)] {
        garment.seams.compactMap { s in
            let a = s.a.reduce(Float(0)) { $0 + SeamSampling.length(garment, $1) }, b = s.b.reduce(Float(0)) { $0 + SeamSampling.length(garment, $1) }
            return abs(a - b) > 0.03 * max(a, b) && s.kind != .elastic ? (s.id, a, b) : nil
        }
    }

    // MARK: - Darts, lines

    /// A dart cut into panel `p`'s edge `e` at `f`: `width` across the edge, `depth` in, its legs sewn together.
    func addDart(panel p: Int, edge e: Int, at f: Float, width: Float = 0.04, depth: Float = 0.1) {
        edit("Dart") { g in
            guard let i = g.panelIndex(id: p) else { return }
            var panel = g.panels[i]
            let curve = panel.edge(e)
            let len = curve.length
            guard len > width * 1.5 else { return }
            let f0 = max(0.02, f - width / 2 / len), f1 = min(0.98, f + width / 2 / len)
            let a = curve.point(at: f0), b = curve.point(at: f1), mid = curve.point(at: (f0 + f1) / 2)
            let t = curve.tangent(at: (f0 + f1) / 2)
            let inward = SIMD2<Float>(-t.y, t.x)   // left of the edge: inside a counter-clockwise outline
            let tip = mid + inward * depth
            // The edge's curve is lost where the dart cuts it (its handles dropped).
            panel.points[e].handleOut = .zero
            panel.points[(e + 1) % panel.points.count].handleIn = .zero
            panel.points.insert(contentsOf: [PathPoint(a), PathPoint(tip), PathPoint(b)], at: e + 1)
            // Seams on the panel's later edges move up by three.
            for s in g.seams.indices {
                for k in g.seams[s].a.indices where g.seams[s].a[k].panel == p && g.seams[s].a[k].edge > e { g.seams[s].a[k].edge += 3 }
                for k in g.seams[s].b.indices where g.seams[s].b[k].panel == p && g.seams[s].b[k].edge > e { g.seams[s].b[k].edge += 3 }
            }
            g.panels[i] = panel
            // The legs: from the outline in to the tip, both.
            g.seams.append(Seam(id: g.nextSeamID, a: [SeamEnd(panel: p, edge: e + 1)], b: [SeamEnd(panel: p, edge: e + 2, t0: 1, t1: 0)]))
        }
    }

    func addLine(panel p: Int, points: [SIMD2<Float>], kind: InternalLine.Kind = .fold) {
        guard points.count >= 2 else { return }
        edit("Internal Line") { g in
            guard let i = g.panelIndex(id: p) else { return }
            g.panels[i].lines.append(InternalLine(points, kind: kind, foldAngle: kind == .fold ? .pi / 2 : 0))
        }
    }

    /// The loop traced on the body flattened into a new panel, set down right of the others, arranged where it was drawn.
    func panelFromTrace() {
        guard let c = GarmentAvatars.character(avatar), let flat = AvatarFrame(c).flatten(trace) else { message = "Trace a loop on the body first"; return }
        trace = []
        var right: Float = 0
        for p in garment.panels { right = max(right, p.bounds.hi.x) }
        var lo = SIMD2<Float>(repeating: .infinity)
        for q in flat.outline { lo = simd_min(lo, q) }
        let pts = flat.outline.map { PathPoint($0 - lo + SIMD2(right + 0.12, 0)) }
        var made = 0
        edit("Panel from Trace") { g in
            var p = Panel(id: g.nextPanelID, name: "Traced", points: pts)
            p.arrangement = flat.arrangement
            made = p.id
            g.panels.append(p)
        }
        selection = [made]
        tab = .panel
        tool = .select
    }

    // MARK: - Templates, fabrics

    func newFromTemplate(_ kind: GarmentTemplate.Kind) {
        let m = measurements
        let g = GarmentTemplate.make(kind, GarmentTemplate.params(kind, body: m), body: m)
        let before = garment
        set(g, name: "New \(kind.label)", previous: before)
        selection = []
        selectedSeam = nil
        fileID = nil
        push(carry: false)
        frame()
    }

    /// A template's garment worn over this one: its panels a layer out (a jacket over the shirt).
    func addLayer(_ kind: GarmentTemplate.Kind) {
        let m = measurements
        let over = GarmentTemplate.make(kind, GarmentTemplate.params(kind, body: m, ease: 0.16), body: m)
        let top = (garment.panels.map(\.layer).max() ?? -1) + 1
        edit("Add \(kind.label) Over") { g in g = g.adding(over, layer: top) }
        frame()
    }

    /// The template's parameter changed: its panels drawn again (their ids and order kept), the drape carried.
    func setTemplateParam(_ key: String, _ value: Float) {
        guard let t = garment.template else { return }
        var params = t.params
        params[key] = value
        let made = GarmentTemplate.make(t.kind, params, body: measurements)
        edit("Template") { g in
            let fabrics = g.fabrics
            let assigned = Dictionary(uniqueKeysWithValues: g.panels.map { ($0.id, $0.fabric) })
            g.panels = made.panels.map { var p = $0; p.fabric = assigned[p.id] ?? 0; return p }
            g.seams = made.seams
            g.buttons = made.buttons
            g.template = made.template
            g.fabrics = fabrics
        }
    }

    /// The template drawn again for the avatar's measurements.
    func gradeToAvatar() {
        guard let t = garment.template else { return }
        let params = GarmentTemplate.params(t.kind, body: measurements)
        let made = GarmentTemplate.make(t.kind, params, body: measurements)
        edit("Fit to Avatar") { g in
            g.panels = made.panels
            g.seams = made.seams
            g.buttons = made.buttons
            g.template = made.template
        }
    }

    func setFabric(_ index: Int, _ change: (inout Fabric) -> Void) {
        edit("Fabric") { g in if g.fabrics.indices.contains(index) { change(&g.fabrics[index]) } }
    }

    // MARK: - Files

    func save(as id: String? = nil) {
        let id = id ?? fileID ?? GarmentStore.id(for: garment.name)
        var g = garment
        g.avatar = avatar
        let positions = DispatchSemaphore(value: 0)
        var drape: [SIMD3<Float>]?
        stage?.renderer.perform { r in drape = r.garmentDrape()?.positions; positions.signal() }
        if stage != nil { _ = positions.wait(timeout: .now() + 1) }
        g.drape = drape
        do {
            let url = try GarmentStore.save(g, id: id)
            fileID = id
            dirty = false
            message = "Saved \(url.lastPathComponent)"
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func open(_ id: String) {
        guard let g = GarmentStore.load(id) else { message = "Couldn't read \(id)"; return }
        let before = garment
        set(g, name: "Open", previous: before)
        fileID = id
        dirty = false
        if g.avatar != avatar {
            avatar = g.avatar
            measurements = GarmentAvatars.character(avatar).map(BodyMeasurements.measure) ?? BodyMeasurements()
        }
        // The drape it was saved with goes as it is.
        if let stage {
            let key = GarmentCatalog.register(g)
            stage.show(garment: key, avatar: avatar, simulate: simulating)
        }
        frame()
    }

    /// Exports to `url`: by its extension, DXF (the flat pattern), OBJ or glTF (the drape, its pattern's UVs).
    func export(to url: URL) {
        let ext = url.pathExtension.lowercased()
        do {
            switch ext {
            case "dxf":
                try DXFWriter.write(garment, allowance: allowance).write(to: url, atomically: true, encoding: .utf8)
            case "obj", "glb":
                let sem = DispatchSemaphore(value: 0)
                var drape: (build: GarmentBuild, positions: [SIMD3<Float>])?
                stage?.renderer.perform { r in drape = r.garmentDrape(); sem.signal() }
                _ = sem.wait(timeout: .now() + 1)
                guard let d = drape else { message = "Nothing draped to export"; return }
                let mesh = GarmentExport.Mesh(build: d.build, positions: d.positions, garment: garment)
                if ext == "obj" { try GarmentExport.obj(mesh).write(to: url, atomically: true, encoding: .utf8) }
                else { try GarmentExport.glb(mesh).write(to: url) }
            default:
                message = "Export as .dxf, .obj or .glb"
                return
            }
            message = "Exported \(url.lastPathComponent)"
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    /// The drape over the next `seconds` (the avatar's clip, if it moves) into a point cache at `url`: PC2 (Blender's
    /// Mesh Cache) or `.gcache`, a frame every other frame of the stage's.
    func bake(seconds: Double, to url: URL, done: @escaping (String) -> Void = { _ in }) {
        guard let stage else { message = "No stage to bake"; return }
        stage.renderer.perform { $0.garmentRecord(true) }
        message = "Baking \(Int(seconds)) s…"
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            stage.renderer.perform { r in
                guard let rec = r.garmentTakeRecording() else { return }
                let frames = stride(from: 0, to: rec.frames.count, by: 2).map { rec.frames[$0] }
                let data = url.pathExtension.lowercased() == "pc2" ? GarmentExport.pc2(frames) : GarmentExport.gcache(frames, triangles: rec.triangles)
                let note: String
                do { try data.write(to: url); note = "Baked \(frames.count) frames to \(url.lastPathComponent)" } catch { note = "Couldn't bake: \(error)" }
                DispatchQueue.main.async { self?.message = note; done(note) }
            }
        }
    }

    /// The avatar's clip ("" its bind pose): the scene made again with the drape carried, the avatar moving.
    @Published var clip = ""
    func setClip(_ name: String) {
        clip = name
        stage?.setClip(name)
        push(carry: true)
    }

    // MARK: - View

    /// The 2D view fitted round every panel (`size`: the canvas's, points).
    var canvasSize = CGSize(width: 800, height: 600)
    func frame() {
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for p in garment.panels { let b = p.bounds; lo = simd_min(lo, b.lo); hi = simd_max(hi, b.hi) }
        guard lo.x <= hi.x else { return }
        pan = (lo + hi) / 2
        let span = hi - lo + 0.2
        zoom = max(40, min(4000, min(Float(canvasSize.width) / span.x, Float(canvasSize.height) / span.y)))
    }

    func setOrbit(_ o: Orbit) {
        orbit = o
        stage?.setCamera(o)
    }

    /// The front, back or side of the avatar.
    func view(_ yaw: Float) {
        var o = orbit
        o.yaw = yaw
        o.pitch = -0.08
        o.target = SIMD3(0, 1.05, 0)
        o.distance = 3.2
        setOrbit(o)
    }
}

private extension UndoManager {
    func levelsOfDetail() { levelsOfUndo = 200 }
}
