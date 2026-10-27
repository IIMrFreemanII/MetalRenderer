import AppKit
import EngineCore
import Foundation
import Modeling
import Procedural
import SwiftUI
import simd

/// The Procedural workspace's state: the active object's network as it is edited (its JSON is the object's `network`;
/// every edit is one of the Modeller's undo steps), the network view's (selection, pan and zoom, Tab's search), and the
/// cooks. A cook runs on a queue of its own and puts the display node's geometry into the object's mesh; the
/// template nodes' outputs are drawn beside it as wires.
final class ProceduralSession: ObservableObject, GraphCanvasModel {
    weak var model: ModelingModel?

    /// The network being edited, and the object it is of.
    @Published private(set) var graph = ProcGraph()
    @Published private(set) var objectID: UUID?
    /// The last cook's report per node (the badges, the info popup), and whether one is running.
    @Published private(set) var info: [String: ProcNodeInfo] = [:]
    @Published private(set) var cooking = false
    /// The display node's geometry and the template nodes', as the last cook left them.
    private(set) var displayGeometry: ProcGeo?
    private(set) var templates: [(id: String, geometry: ProcGeo)] = []
    /// Cook on the caller's thread at once (tests, scripts), not on the cook queue.
    var synchronous = false

    // The network view's.
    @Published var pan = CGPoint(x: 160, y: 60)
    @Published var zoom: CGFloat = 1
    var canvasSize = CGSize(width: 600, height: 400)
    var canvasOrigin = CGPoint.zero
    var hover = CGPoint(x: 200, y: 120)
    var focusCanvas: (() -> Void)?
    @Published var selection: Set<String> = []
    /// The current node: the parameter pane's, the spreadsheet's and the handles'.
    @Published var focus: String? { didSet { if focus != oldValue, focus != nil, focus != graph.displayNode { requestCook() } } }
    @Published private(set) var searchAt: SIMD2<Float>?
    /// The node whose info popup shows.
    @Published var infoNode: String?

    // What the viewport and the left area show (ProcInspect).
    enum LeftTab: String, CaseIterable { case sceneView = "Scene View", spreadsheet = "Geometry Spreadsheet" }
    @Published var leftTab: LeftTab = .sceneView
    @Published var spreadsheetClass: AttributeClass = .point
    @Published var showPoints = false { didSet { model?.redraw() } }
    @Published var pointNumbers = false
    @Published var primNumbers = false
    @Published var showNormals = false { didSet { model?.redraw() } }
    @Published var showColors = true { didSet { model?.redraw() } }
    @Published var showHandles = true { didSet { model?.redraw() } }
    /// The current node's geometry when it isn't the display node's (the spreadsheet's), from the last cook.
    private(set) var inspected: (id: String, geometry: ProcGeo)?
    /// A handle being dragged.
    var handleDrag: ProcHandleDrag?
    /// The viewport's buffers of the display geometry coloured by Cd.
    var colorMesh: (key: Int, mesh: ViewportMesh, palette: [SIMD4<Float>])?

    private let cookQueue = DispatchQueue(label: "modeller.procedural.cook", qos: .userInitiated)
    /// Touched on the cook queue only (or the caller's, when synchronous).
    private let cooker: ProcCooker
    /// Bumped by each cook request: a cook that finds a newer one asked for stops.
    private var generation = 0
    private let latest = Latest()
    /// What the object's mesh was last cooked from (the display node's key and the mesh it made), so a document change
    /// that didn't touch the network doesn't put the same mesh in again.
    private var applied: (object: UUID, key: UInt64, templates: [UInt64], mesh: UInt64)?
    private var dragBefore: ModelingDocument?

    init(model: ModelingModel) {
        self.model = model
        cooker = ProcCooker(environment: .assets)
    }

    private final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: The document

    /// The active object's index, if it has a network.
    private var objectIndex: Int? {
        guard let model, let id = objectID else { return nil }
        return model.document.index(of: id)
    }

    var hasNetwork: Bool { objectIndex != nil }

    /// Follows the document: the active object's network (after a selection, an undo), then a cook if it changed.
    func documentChanged() {
        guard let model else { return }
        let active = model.activeObject
        guard let o = active, let json = o.network else {
            if objectID != nil || !graph.nodes.isEmpty {
                objectID = nil
                graph = ProcGraph()
                info = [:]
                selection = []
                focus = nil
                templates = []
                displayGeometry = nil
            }
            return
        }
        if o.id != objectID || encoded(graph) != json {
            let g = (try? JSONDecoder().decode(ProcGraph.self, from: Data(json.utf8))) ?? ProcGraph()
            if o.id != objectID {
                selection = []
                focus = g.displayNode
                objectID = o.id
                DispatchQueue.main.async { [weak self] in self?.frameAll(in: self?.canvasSize ?? .zero) }
            } else {
                selection = selection.filter { g.node($0) != nil }
                if let f = focus, g.node(f) == nil { focus = nil }
            }
            graph = g
        }
        requestCook()
    }

    private func encoded(_ g: ProcGraph) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(g)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Changes the network as one undo step (`coalesce`: edits with the same key within a moment are one, a field
    /// being dragged).
    func edit(_ name: String, coalesce key: String? = nil, _ change: (inout ProcGraph) -> Void) {
        guard let model, let i = objectIndex else { return }
        var g = graph
        change(&g)
        guard g != graph else { return }
        graph = g
        let json = encoded(g)
        if let key {
            model.editCoalesced(name, key: key) { $0.objects[i].network = json }
        } else {
            model.edit(name) { $0.objects[i].network = json }
        }
    }

    /// Gives the active object a network: a box, displayed (Houdini's new geometry object).
    func makeNetwork() {
        guard let model, let i = model.activeIndex else { addObject(); return }
        var g = ProcGraph()
        g.add(.box, at: [0, 0])
        let json = encoded(g)
        model.edit("New Network") { $0.objects[i].network = json }
    }

    /// A new object (`geo1`, `geo2` …) with a network of its own, active.
    func addObject() {
        guard let model else { return }
        var g = ProcGraph()
        g.add(.box, at: [0, 0])
        let json = encoded(g)
        let names = Set(model.document.objects.map(\.name))
        var k = 1
        while names.contains("geo\(k)") { k += 1 }
        var o = ModelObject(name: "geo\(k)", mesh: EditMesh())
        o.network = json
        model.edit("Add Procedural Object") { d in
            d.objects.append(o)
            d.active = d.objects.count - 1
            d.selection = [o.id]
        }
    }

    // MARK: Assets

    /// The asset the active object's network was saved as (its slug), if it was.
    @Published var assetSlug: String?

    /// Saves the network as a procedural asset (`Assets/Procedural/<slug>.proc.json`), with the object's material
    /// slots. False (and a message) if it couldn't.
    @discardableResult
    func saveAsset(named name: String, in folder: URL? = ProcStore.folder) -> Bool {
        guard let model, let o = model.activeObject, hasNetwork else { return false }
        let slug = ModelStore.slug(name)
        do {
            try ProcStore.write(ProcAsset(name: name, graph: graph, materials: o.materials), slug: slug, in: folder)
            assetSlug = slug
            model.report("Saved the procedural asset \(slug)")
            return true
        } catch {
            model.report("Couldn't save \(slug): \(error)")
            return false
        }
    }

    /// Opens the asset `slug` as a new object with its network and material slots, active, in the Procedural
    /// workspace; saving it under its name writes the same file. False (and a message) if there is no such asset.
    @discardableResult
    func openAsset(_ slug: String, in folder: URL? = ProcStore.folder) -> Bool {
        guard let model else { return false }
        guard let asset = ProcStore.read(slug, in: folder) else {
            model.report("No procedural asset \(slug)")
            return false
        }
        var o = ModelObject(name: asset.name, mesh: EditMesh())
        o.network = encoded(asset.graph)
        o.materials = asset.materials
        model.setWorkspace(.procedural)
        model.edit("Open Procedural Asset") { d in
            d.objects.append(o)
            d.active = d.objects.count - 1
            d.selection = [o.id]
        }
        assetSlug = slug
        model.report("Opened the procedural asset \(slug)")
        return true
    }

    /// The scene's reference to the saved asset with its promoted parameters' values now.
    var assetReference: String? {
        guard let slug = assetSlug else { return nil }
        var values: [String: String] = [:]
        for p in graph.interface { values[p.name] = ProcAssetReference.text(p.value) }
        return ProcAssetReference(slug: slug, values: values).asset
    }

    /// Places the saved asset in the main scene, in front of its camera, with the parameters' values now.
    func placeAsset() {
        guard let model, let ref = assetReference else { model?.report("Save the network as a procedural asset first"); return }
        model.host?.placeAsset(ref)
        model.report("Placed \(ref)")
    }

    func setInterfaceValue(_ name: String, _ value: ProcParam) {
        edit("Asset Parameter", coalesce: "iface:\(name)") { g in
            guard let i = g.interface.firstIndex(where: { $0.name == name }) else { return }
            g.interface[i].value = value
            // The network shows the value too (what the asset makes with it).
            for t in g.interface[i].targets {
                if let n = g.named(t.node) ?? g.node(t.node) { g.setParam(n.id, t.param, value) }
            }
        }
    }

    /// Takes the network off the active object, keeping the mesh it made.
    func bakeNetwork() {
        guard let model, let i = objectIndex else { return }
        model.edit("Bake Network") { $0.objects[i].network = nil }
    }

    // MARK: Cooking

    /// Cooks the display node and the template nodes (on the cook queue), then puts the display node's geometry
    /// into the object's mesh.
    func requestCook() {
        guard let id = objectID else { return }
        generation += 1
        let gen = generation
        latest.set(gen)
        let g = graph
        let focus = self.focus
        let doc = model?.document
        var environment = fileEnvironment(doc, object: id)
        environment.frame = frame
        let work = { [cooker, latest] () -> CookResult in
            cooker.environment = environment
            var r = CookResult(generation: gen, object: id)
            guard let display = g.displayNode else { return r }
            r.key = cooker.key(g, display) ?? 0
            switch cooker.cook(g, display, cancelled: { latest.get() != gen }) {
            case .success(let geo): r.display = geo
            case .failure(let e): r.error = e
            }
            for n in g.nodes where n.template && n.id != display {
                if case .success(let geo) = cooker.cook(g, n.id) { r.templates.append((n.id, geo, cooker.key(g, n.id) ?? 0)) }
            }
            if let f = focus, f != display, g.node(f) != nil, case .success(let geo) = cooker.cook(g, f) { r.inspected = (f, geo) }
            r.info = cooker.info
            return r
        }
        if synchronous {
            finish(work())
            return
        }
        cooking = true
        cookQueue.async { [weak self] in
            let r = work()
            DispatchQueue.main.async { self?.finish(r) }
        }
    }

    private struct CookResult {
        var generation: Int
        var object: UUID
        var key: UInt64 = 0
        var display: ProcGeo?
        var error: ProcCookError?
        var templates: [(String, ProcGeo, UInt64)] = []
        var inspected: (id: String, geometry: ProcGeo)?
        var info: [String: ProcNodeInfo] = [:]
    }

    private func finish(_ r: CookResult) {
        guard r.generation == generation, r.object == objectID else { return }
        cooking = false
        info = r.info
        templates = r.templates.map { ($0.0, $0.1) }
        inspected = r.inspected
        if let d = r.display { displayGeometry = d }
        if r.error?.message == "cancelled" { return }
        guard let model, let i = objectIndex else { return }
        let templateKeys = r.templates.map(\.2)
        let mesh = model.document.objects[i].mesh.generation
        if let a = applied, a.object == r.object, a.key == r.key, a.mesh == mesh, r.display != nil {
            if a.templates != templateKeys { applied?.templates = templateKeys; model.redraw() }
            return
        }
        guard let geo = r.display else {
            if let e = r.error { model.report("\(graph.node(e.node)?.name ?? "Cook"): \(e.message)") }
            model.redraw()
            return
        }
        displayGeometry = geo
        let (m, materials) = geo.editMesh()
        var d = model.document
        d.objects[i].mesh = m
        d.objects[i].materials = Self.slots(materials, keeping: d.objects[i].materials)
        model.setDocument(d, coarse: true)
        applied = (r.object, r.key, templateKeys, m.generation)
    }

    /// Material slots named as the geometry's materials, keeping the colours of slots of the same names.
    static func slots(_ names: [String], keeping old: [MaterialSlot]) -> [MaterialSlot] {
        names.map { n in old.first { $0.name == n } ?? MaterialSlot(name: n) }
    }

    /// File nodes' geometry: `object:<name>` another object of the document (its mesh where it is, seen from this
    /// object), else the model assets'.
    private func fileEnvironment(_ doc: ModelingDocument?, object id: UUID) -> ProcEnvironment {
        let objects = doc?.objects ?? []
        let me = objects.first { $0.id == id }
        let toLocal = me.map { $0.transform.matrix.inverse } ?? matrix_identity_float4x4
        func find(_ name: String) -> ModelObject? {
            guard name.hasPrefix("object:") else { return nil }
            let n = String(name.dropFirst(7))
            return objects.first { $0.name == n && $0.id != id }
        }
        return ProcEnvironment(
            file: { name in
                if let o = find(name) {
                    return ProcGeo(o.mesh.transformed(by: toLocal * o.transform.matrix), materials: o.materials.map(\.name))
                }
                return ProcEnvironment.readAsset(name)
            },
            stamp: { name in
                if let o = find(name) { return o.mesh.generation &+ UInt64(truncatingIfNeeded: o.transform.matrix.columns.3.x.bitPattern) }
                return ProcEnvironment.assets.stamp(name)
            })
    }

    /// The template nodes' outputs as the viewport's draws (wires only, never picked), in the object's place.
    private var templateMeshes: [String: (key: Int, mesh: ViewportMesh)] = [:]
    func templateDraws(_ scene: ViewportScene, transform: float4x4) -> [ViewportObjectDraw] {
        var out: [ViewportObjectDraw] = []
        var live = Set<String>()
        for (id, geo) in templates {
            live.insert(id)
            let key = geo.hashValueForDraw
            var entry = templateMeshes[id] ?? (key: 0, mesh: ViewportMesh(device: scene.device))
            if entry.key != key || entry.mesh.cageKey == nil {
                let m = geo.editMesh(cusp: 180).mesh
                entry.mesh.setFaces(m, edit: false)
                entry.mesh.setCage(m)
                entry.key = key
            }
            templateMeshes[id] = entry
            var d = ViewportObjectDraw(mesh: entry.mesh, transform: transform, color: [0.6, 0.6, 0.6], materialColors: [])
            d.template = true
            d.objectID = UInt32.max - 1
            out.append(d)
        }
        for id in templateMeshes.keys where !live.contains(id) { templateMeshes[id] = nil }
        return out
    }

    // MARK: Nodes

    /// Adds a node of `kind` at `at` (the graph's units). With one node selected (or `after`), wires it into the new
    /// one's first input, puts the new one below it and gives it the display flag, as Houdini's Tab menu does.
    @discardableResult
    func add(_ kind: ProcNodeKind, at: SIMD2<Float>? = nil, after: String? = nil) -> String? {
        guard hasNetwork else { return nil }
        let above = after ?? (selection.count == 1 ? selection.first : nil)
        var place = at ?? graphPoint(hover)
        if let a = above, let n = graph.node(a), at == nil || after != nil { place = n.at + [0, ProcNetworkLayout.rowGap] }
        var id = ""
        edit("Add \(kind.spec.title)") { g in
            id = g.add(kind, at: place)
            if let a = above, !kind.spec.inputs.isEmpty, g.node(a) != nil {
                g.link(a, to: id, 0)
                g.setDisplay(id)
            }
        }
        selection = [id]
        focus = id
        closeSearch()
        return id
    }

    /// Sets a parameter. Its keyed channels take a key on the frame with their part of `value` (auto-key); the others
    /// their value as set.
    func setParam(_ node: String, _ name: String, _ value: ProcParam) {
        guard let n = graph.node(node), current(n, name) != value else { return }
        let channels = n.kind.spec.param(name).map(ProcExprContext.channels) ?? []
        guard channels.contains(where: { n.curves[$0] != nil }) else {
            edit("Change \(n.name)", coalesce: "proc:\(node).\(name)") { $0.setParam(node, name, value) }
            return
        }
        let was = current(n, name).vec4, now = value.vec4, frame = frame
        edit("Key \(n.name)", coalesce: "proc:\(node).\(name)") { g in
            guard let i = g.index(of: node) else { return }
            var literal = g.nodes[i].param(name)
            for (k, c) in channels.enumerated() where was[k] != now[k] {
                if g.nodes[i].curves[c] != nil { g.nodes[i].curves[c]!.set(frame, now[k]) } else { literal = literal.setting(channels.count > 1 ? k : nil, now[k]) }
            }
            g.nodes[i].params[name] = literal
        }
    }

    /// A parameter as the frame has it: its keyed channels at their value on the frame.
    func current(_ n: ProcNode, _ name: String) -> ProcParam {
        var v = n.param(name)
        guard !n.curves.isEmpty, let spec = n.kind.spec.param(name) else { return v }
        let channels = ProcExprContext.channels(of: spec)
        for (k, c) in channels.enumerated() {
            if let curve = n.curves[c] { v = v.setting(channels.count > 1 ? k : nil, curve.value(at: frame)) }
        }
        return v
    }

    // MARK: Expressions

    /// The frame expressions and keys read (`$F`, `$T`): the timeline's.
    @Published var frame: Float = 1 { didSet { if frame != oldValue { requestCook() } } }
    /// Playing the frames at 24 a second, over the network's range and round again.
    @Published var playing = false {
        didSet {
            player?.invalidate()
            player = nil
            guard playing else { return }
            player = Timer.scheduledTimer(withTimeInterval: 1 / Double(ProcExprContext.fps), repeats: true) { [weak self] _ in
                guard let self else { return }
                let r = self.graph.frames
                self.frame = self.frame >= Float(r.upperBound) || self.frame < Float(r.lowerBound) ? Float(r.lowerBound) : self.frame.rounded(.down) + 1
            }
        }
    }
    private var player: Timer?
    /// The parameter Copy Parameter took, for Paste Relative References.
    @Published var copiedParameter: (node: String, param: String)?

    /// Sets channel `channel`'s expression (empty: removes it), in place of its keys.
    func setExpression(_ node: String, _ channel: String, _ source: String) {
        let s = source.trimmingCharacters(in: .whitespaces)
        let new = s.isEmpty ? nil : s
        guard let n = graph.node(node), n.expressions[channel] != new || (new != nil && n.curves[channel] != nil) else { return }
        edit("Expression on \(n.name)", coalesce: "proc:\(node).\(channel).expr") { g in
            guard let i = g.index(of: node) else { return }
            g.nodes[i].expressions[channel] = new
            if new != nil { g.nodes[i].curves[channel] = nil }
        }
    }

    // MARK: Keys

    /// Which pane is under the parameters: the network, or the curve editor.
    enum LowerTab { case network, curves }
    @Published var lowerTab: LowerTab = .network
    /// The channels the curve editor shows only ("node/channel"; empty: every keyed channel of the current node).
    @Published var curveSolo: Set<String> = []

    /// The node the parameter pane, the timeline and the curve editor show.
    var currentNode: String? { focus ?? graph.displayNode }

    /// The keyed channels the timeline and the curve editor show: the solo ones, else the current node's (in its
    /// parameters' order).
    var shownCurves: [(node: String, channel: String, curve: ProcCurve)] {
        let solo = curveSolo.compactMap { id -> (String, String, ProcCurve)? in
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let c = graph.node(parts[0])?.curves[parts[1]] else { return nil }
            return (parts[0], parts[1], c)
        }
        if !solo.isEmpty { return solo.sorted { ($0.0, $0.1) < ($1.0, $1.1) } }
        guard let id = currentNode, let n = graph.node(id) else { return [] }
        return n.kind.spec.params.flatMap(ProcExprContext.channels).compactMap { c in n.curves[c].map { (id, c, $0) } }
    }

    /// Houdini's Alt-click on a label: a key on the frame for each of the parameter's channels, of the value it has
    /// there (an expression's from the last cook: the key replaces it).
    func setKeys(_ node: String, _ param: String) {
        guard let n = graph.node(node), let spec = n.kind.spec.param(param) else { return }
        let channels = ProcExprContext.channels(of: spec)
        guard !channels.isEmpty else { return }
        let v = current(n, param).vec4, values = info[node]?.channels ?? [:], frame = frame
        edit("Set Key") { g in
            guard let i = g.index(of: node) else { return }
            for (k, c) in channels.enumerated() {
                let x = g.nodes[i].expressions[c] != nil ? (values[c] ?? nil) ?? v[k] : v[k]
                var curve = g.nodes[i].curves[c] ?? ProcCurve()
                curve.set(frame, x)
                g.nodes[i].curves[c] = curve
                g.nodes[i].expressions[c] = nil
            }
        }
    }

    /// The parameter's keys on the frame removed; a channel left with none keeps the value it had as set.
    func deleteKeys(_ node: String, _ param: String) {
        guard let n = graph.node(node), let spec = n.kind.spec.param(param) else { return }
        let channels = ProcExprContext.channels(of: spec).filter { n.curves[$0]?.index(at: frame) != nil }
        guard !channels.isEmpty else { return }
        let changes = channels.map { c -> (String, String, ProcCurve?) in
            var curve = n.curves[c]!
            curve.remove(at: frame)
            return (node, c, curve.keys.isEmpty ? nil : curve)
        }
        setCurves(changes, "Delete Key")
    }

    /// The interpolation of the parameter's keys on the frame (nil: all its keys).
    func setInterpolation(_ node: String, _ param: String, _ interpolation: ProcInterpolation, onFrame: Bool = true) {
        guard let n = graph.node(node), let spec = n.kind.spec.param(param) else { return }
        let changes = ProcExprContext.channels(of: spec).compactMap { c -> (String, String, ProcCurve?)? in
            guard var curve = n.curves[c] else { return nil }
            for i in curve.keys.indices where !onFrame || abs(curve.keys[i].frame - frame) < 0.005 {
                curve.update(i) { $0.interpolation = interpolation }
            }
            return (node, c, curve)
        }
        setCurves(changes, "Interpolation")
    }

    /// Channels given new curves (nil: their keys removed, each keeping its value on the frame as set), as one undo
    /// step named `name`.
    func setCurves(_ changes: [(node: String, channel: String, curve: ProcCurve?)], _ name: String) {
        guard !changes.isEmpty else { return }
        let frame = frame
        edit(name) { g in ProceduralSession.apply(changes, to: &g, frame: frame) }
    }

    /// ...during a drag (the curve editor's, the timeline's): no undo step (endDrag makes it).
    func setCurvesLive(_ changes: [(node: String, channel: String, curve: ProcCurve?)]) {
        guard let model, let i = objectIndex else { return }
        ProceduralSession.apply(changes, to: &graph, frame: frame)
        var d = model.document
        d.objects[i].network = encoded(graph)
        model.setDocument(d)
        requestCook()
    }

    private static func apply(_ changes: [(node: String, channel: String, curve: ProcCurve?)], to g: inout ProcGraph, frame: Float) {
        for (node, c, curve) in changes {
            guard let i = g.index(of: node) else { continue }
            if curve == nil, let old = g.nodes[i].curves[c], let (spec, k) = ProcExprContext.locate(c, in: g.nodes[i].kind) {
                g.nodes[i].params[spec.name] = g.nodes[i].param(spec.name).setting(k, old.value(at: frame))
            }
            g.nodes[i].curves[c] = curve
            if curve != nil { g.nodes[i].expressions[c] = nil }
        }
    }

    /// The frames the timeline plays.
    func setFrameRange(_ r: ClosedRange<Int>) {
        guard r != graph.frames else { return }
        edit("Frame Range") { $0.frames = r }
    }

    /// A number typed into a channel that has an expression: the value, the expression gone.
    func setChannelValue(_ node: String, _ param: String, _ component: Int?, _ value: Float) {
        guard let n = graph.node(node), let spec = n.kind.spec.param(param) else { return }
        let channels = ProcExprContext.channels(of: spec)
        let channel = component.map { channels[$0] } ?? param
        edit("Change \(n.name)") { g in
            guard let i = g.index(of: node) else { return }
            g.nodes[i].params[param] = g.nodes[i].param(param).setting(component, value)
            g.nodes[i].expressions[channel] = nil
        }
    }

    /// Houdini's Delete Channels: the parameter's expressions and keys removed, each channel keeping its value on the
    /// frame.
    func deleteChannels(_ node: String, _ param: String) {
        guard let n = graph.node(node), let spec = n.kind.spec.param(param) else { return }
        let channels = ProcExprContext.channels(of: spec)
        guard channels.contains(where: { n.isDriven($0) }) else { return }
        let values = info[node]?.channels ?? [:], frame = frame
        edit("Delete Channels") { g in
            guard let i = g.index(of: node) else { return }
            var v = g.nodes[i].param(param)
            for (k, c) in channels.enumerated() where g.nodes[i].isDriven(c) {
                let x = g.nodes[i].curves[c]?.value(at: frame) ?? (values[c] ?? nil)
                if let x { v = v.setting(channels.count > 1 ? k : nil, x) }
                g.nodes[i].expressions[c] = nil
                g.nodes[i].curves[c] = nil
            }
            g.nodes[i].params[param] = v
        }
    }

    /// Each channel of `param` as `ch()` of the copied parameter's channel at the same place.
    func pasteRelativeReferences(_ node: String, _ param: String) {
        guard let (fromNode, fromParam) = copiedParameter, let src = graph.node(fromNode), let srcSpec = src.kind.spec.param(fromParam),
              let n = graph.node(node), let spec = n.kind.spec.param(param) else { return }
        let from = ProcExprContext.channels(of: srcSpec), to = ProcExprContext.channels(of: spec)
        edit("Paste Relative References") { g in
            guard let i = g.index(of: node) else { return }
            for (k, c) in to.enumerated() where k < from.count {
                g.nodes[i].expressions[c] = src.id == n.id ? "ch(\"\(from[k])\")" : "ch(\"../\(src.name)/\(from[k])\")"
                g.nodes[i].curves[c] = nil
            }
        }
    }

    func revertParam(_ node: String, _ name: String) {
        edit("Revert Parameter") { g in
            guard let i = g.index(of: node) else { return }
            g.nodes[i].params[name] = nil
            for c in g.nodes[i].kind.spec.param(name).map(ProcExprContext.channels) ?? [] {
                g.nodes[i].expressions[c] = nil
                g.nodes[i].curves[c] = nil
            }
        }
    }

    func rename(_ node: String, to name: String) {
        edit("Rename Node") { $0.rename(node, to: name) }
    }

    func setDisplay(_ node: String) { edit("Display Flag") { $0.setDisplay(node) } }
    func setRender(_ node: String) { edit("Render Flag") { $0.setRender(node) } }
    func toggleBypass(_ node: String) { toggle(node, "Bypass Flag") { $0.bypass.toggle() } }
    func toggleTemplate(_ node: String) { toggle(node, "Template Flag") { $0.template.toggle() } }

    private func toggle(_ node: String, _ name: String, _ change: (inout ProcNode) -> Void) {
        edit(name) { g in if let i = g.index(of: node) { change(&g.nodes[i]) } }
    }

    /// Promotes a node parameter to the asset's interface (named after the parameter, made unique).
    func promote(_ node: String, _ name: String) {
        guard let n = graph.node(node), let spec = n.kind.spec.param(name) else { return }
        edit("Promote Parameter") { g in
            var key = name, k = 2
            while g.interface.contains(where: { $0.name == key }) { key = "\(name)\(k)"; k += 1 }
            var span: ClosedRange<Float>?
            if case .number(let r) = spec.ui { span = r }
            if case .integer(let r) = spec.ui { span = Float(r.lowerBound)...Float(r.upperBound) }
            g.interface.append(PromotedParam(key, title: spec.title, value: n.param(name), span: span,
                                             targets: [.init(node: n.name, param: name)]))
        }
    }

    /// Lays the selected nodes (or all) out in rows by depth: each node a row below the lowest of its inputs.
    func layout() {
        let ids = selection.isEmpty ? Set(graph.nodes.map(\.id)) : selection
        edit("Layout") { g in
            var depth: [String: Int] = [:]
            func d(_ id: String, _ seen: Set<String> = []) -> Int {
                if let v = depth[id] { return v }
                let ins = g.inputs(of: id).compactMap { $0 }.filter { ids.contains($0) && !seen.contains($0) }
                let v = ins.map { d($0, seen.union([id])) + 1 }.max() ?? 0
                depth[id] = v
                return v
            }
            let order = g.nodes.filter { ids.contains($0.id) }
            guard let origin = order.map(\.at).reduce(nil, { (r: SIMD2<Float>?, p) in r.map { simd_min($0, p) } ?? p }) else { return }
            var columns: [Int: Int] = [:]
            for n in order {
                let row = d(n.id)
                let col = columns[row, default: 0]
                columns[row] = col + 1
                if let i = g.index(of: n.id) {
                    g.nodes[i].at = origin + [Float(col) * ProcNetworkLayout.columnGap, Float(row) * ProcNetworkLayout.rowGap]
                }
            }
        }
    }

    // MARK: GraphCanvasModel

    func click(_ id: String, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if !selection.contains(id) {
            selection = [id]
        }
        focus = id
    }

    func clearSelection() { selection = []; infoNode = nil }
    func selectAll() { selection = Set(graph.nodes.map(\.id)) }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let gone = selection
        edit(gone.count == 1 ? "Delete Node" : "Delete Nodes") { $0.remove(gone) }
        selection = []
        if let f = focus, gone.contains(f) { focus = nil }
    }

    /// What copying puts on the pasteboard: the nodes and the wires among them.
    private struct Clip: Codable {
        var procnodes: [ProcNode]
        var links: [ProcLink]
    }

    func copySelection() {
        let nodes = graph.nodes.filter { selection.contains($0.id) }
        guard !nodes.isEmpty else { return }
        let clip = Clip(procnodes: nodes, links: graph.links.filter { selection.contains($0.from) && selection.contains($0.to) })
        guard let data = try? JSONEncoder().encode(clip) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }

    func paste() {
        guard let s = NSPasteboard.general.string(forType: .string), let clip = try? JSONDecoder().decode(Clip.self, from: Data(s.utf8)) else { return }
        var added: Set<String> = []
        edit("Paste Nodes") { g in
            var map: [String: String] = [:]
            for var n in clip.procnodes {
                let id = g.uniqueID()
                map[n.id] = id
                n.id = id
                n.name = g.named(n.name) == nil ? n.name : g.uniqueName(n.kind.spec.baseName)
                n.at += [30, 30]
                n.display = false
                n.render = false
                g.nodes.append(n)
                added.insert(id)
            }
            for l in clip.links { if let a = map[l.from], let b = map[l.to] { g.links.append(ProcLink(a, to: b, l.input)) } }
        }
        selection = added
    }

    func beginDrag() { if dragBefore == nil { dragBefore = model?.document } }

    func endDrag() { endDrag("Move Nodes") }

    /// The drag's changes as one undo step named `name`.
    func endDrag(_ name: String) {
        guard let before = dragBefore, let model else { return }
        dragBefore = nil
        if before.objects.first(where: { $0.id == objectID })?.network != model.activeObject?.network {
            model.registerUndo(name, before: before)
            model.documentChanged(dirty: true)
        }
    }

    /// A parameter changed during a drag (a handle's): the network and a cook, no undo step (endDrag makes it).
    func setParamLive(_ node: String, _ name: String, _ value: ProcParam) {
        guard let model, let i = objectIndex, graph.node(node) != nil else { return }
        graph.setParam(node, name, value)
        var d = model.document
        d.objects[i].network = encoded(graph)
        model.setDocument(d)
        requestCook()
    }

    /// Moves nodes during a drag: the network changes without an undo step (endDrag makes the one).
    func moveSelection(by delta: SIMD2<Float>, ids: Set<String>?) {
        guard let model, let i = objectIndex else { return }
        let moving = ids ?? selection
        for k in graph.nodes.indices where moving.contains(graph.nodes[k].id) { graph.nodes[k].at += delta }
        var d = model.document
        d.objects[i].network = encoded(graph)
        model.setDocument(d)
    }

    func wire(into owner: String, _ input: String) -> (from: String, output: String)? {
        guard let k = Int(input), let l = graph.links.first(where: { $0.to == owner && $0.input == k }) else { return nil }
        return (l.from, "out")
    }

    @discardableResult
    func link(_ from: String, _ output: String, to: String, _ input: String) -> Bool {
        guard graph.canLink(from, to: to), let n = graph.node(to) else { return false }
        let k: Int
        if let i = Int(input) {
            k = i
        } else if n.kind.spec.multiInput {
            k = graph.inputs(of: to).count
        } else {
            // Over the node: its first free input.
            let ins = graph.inputs(of: to)
            k = ins.firstIndex { $0 == nil } ?? 0
        }
        var ok = false
        edit("Connect") { ok = $0.link(from, to: to, k) }
        return ok
    }

    func unlink(_ to: String, _ input: String) {
        guard let k = Int(input) else { return }
        edit("Disconnect") { $0.unlink(to: to, k) }
    }

    func openSearch() { if hasNetwork { searchAt = graphPoint(hover) } }
    func closeSearch() { searchAt = nil; focusCanvas?() }

    func frameAll(in size: CGSize) {
        guard !graph.nodes.isEmpty else { return }
        frame(ProcNetworkLayout.bounds(graph), in: size)
    }
}

extension ProcGeo {
    /// A cheap fingerprint of what the viewport draws of it (counts and a sample of positions).
    var hashValueForDraw: Int {
        var h = Hasher()
        h.combine(pointCount); h.combine(primCount); h.combine(vertexCount)
        let step = max(1, pointCount / 64)
        for i in stride(from: 0, to: pointCount, by: step) { h.combine(P[i].x); h.combine(P[i].y); h.combine(P[i].z) }
        return h.finalize()
    }
}
