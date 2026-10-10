import AppKit
import Combine
import Metal
import QuartzCore
import simd

/// What the Material Designer needs of the renderer (RendererController; a stand-in in the tests).
protocol MaterialEditorHost: AnyObject {
    var settings: RenderSettings { get }
    var defaultSettings: RenderSettings { get }
    /// The GPU the renderer draws with (the editor bakes on it, sharing MaterialBake's engine); nil: none (tests).
    var metalDevice: MTLDevice? { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void)
    /// Click-to-pick: the next click in the renderer's view names the material under it (`picked` on the main
    /// thread: nil if nothing was there, or the pick was cancelled).
    func pickMaterial(_ picked: @escaping (MaterialPick?) -> Void)
    func cancelPick()
}

/// What a click in the view found (Renderer.readPick): the instance, its material (its index in the scene), the
/// material's fingerprint as the scene made it (MaterialAssignments), the graph it already is (if it is procedural),
/// its colour there, and where.
struct MaterialPick: Equatable {
    var instance: Int
    var material: Int
    var fingerprint = ""
    var graph: String?
    var albedo: SIMD3<Float>
    var position: SIMD3<Float>
}

/// The Material Designer's state, on the main thread: the graphs as edited (a catalog: the built-in ones edited, and
/// new ones) and as saved, which one is shown, what of it is selected, the canvas's view, and the bake of it.
///
/// Every edit is baked at once on the GPU (MatEngine, MaterialBake's: the renderer's bakes share its cache) for the
/// nodes' thumbnails, the 2D view and the 3D preview, and goes to the renderer as the catalog's registry key
/// (`SceneSettings.materials`): the material workshop and every scene whose procedural materials name the graph bake it
/// again in place (Renderer.editMaterials). While a drag lasts, at most 30 a second. Unsaved edits are a draft until
/// saved or reverted. One undo step per edit; a drag (a slider's, a node's) is one edit.
///
/// A pixel processor's function is edited on the same canvas (`editingFunction`): its math nodes instead of the graph's.
final class MaterialEditorModel: GraphCanvasModel {
    let controller: MaterialEditorHost
    let undo = UndoManager()
    private let folder: URL?
    private let keepsDraft: Bool
    var pasteboard = NSPasteboard.general
    private static let draftKey = "materialDesigner.draft"
    /// The engine every edit bakes on (nil without a GPU: the tests).
    let engine: MatEngine?

    @Published private(set) var catalog: MaterialCatalog
    @Published private(set) var saved: MaterialCatalog
    @Published var selectedGraph: String
    /// The pixel processor whose function the canvas shows (nil: the graph).
    @Published var editingFunction: String? { didSet { if editingFunction != oldValue { selection = []; focus = nil; search = nil } } }
    @Published var selection: Set<String> = []
    @Published var focus: String?
    @Published var pan = CGPoint(x: 120, y: 40)
    @Published var zoom: CGFloat = 0.8
    @Published var search: SIMD2<Float>?
    /// The bake: each node's thumbnail and error, the result (the 3D preview's textures, the plan the 2D view finds a
    /// node's image by), how long the GPU took.
    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var result: MatResult?
    @Published private(set) var planError: String?
    @Published private(set) var message: String?
    @Published private(set) var scene: SceneSettings
    /// The node the 2D view shows: pinned, else the focus, else the base colour's output.
    @Published var pinned: String?
    /// The picked material (click-to-pick) and whether a pick is armed.
    @Published private(set) var picked: MaterialPick?
    @Published private(set) var picking = false
    /// Which scene materials graphs replace (MaterialAssignments), as edited and as saved.
    @Published private(set) var assignments: MaterialAssignments
    @Published private(set) var savedAssignments: MaterialAssignments
    private let assignmentsURL: URL?

    var canvasSize = CGSize(width: 800, height: 600)
    var canvasOrigin = CGPoint(x: 0, y: 33)
    var hover = CGPoint(x: 200, y: 200)
    var focusCanvas: (() -> Void)?

    private var thumbsByHash: [UInt64: CGImage] = [:]
    private var dragging = false
    private var dragStart: MaterialCatalog?
    private var liveSent = 0.0
    private var pendingLive: DispatchWorkItem?
    private var draftSave: DispatchWorkItem?

    init(controller: MaterialEditorHost, saved: MaterialCatalog = MaterialCatalog.launch, folder: URL? = MaterialStore.folder,
         draft: Bool = true) {
        self.controller = controller
        self.saved = saved
        self.folder = folder
        keepsDraft = draft
        engine = controller.metalDevice.map { MaterialBake.shared($0).engine }
        assignmentsURL = folder?.appendingPathComponent(MaterialAssignments.file)
        let a = folder == MaterialStore.folder ? MaterialAssignments.launch
            : assignmentsURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(MaterialAssignments.self, from: $0) } ?? MaterialAssignments()
        assignments = a
        savedAssignments = a
        undo.groupsByEvent = false
        catalog = (draft ? MaterialEditorModel.loadDraft() : nil) ?? saved
        scene = controller.settings.scene
        selectedGraph = controller.settings.scene.materialWorkshop.graph
        if !catalog.names.contains(selectedGraph) { selectedGraph = catalog.names.first ?? "Red Bricks" }
        controller.observeSettings { [weak self] s in self?.received(s) }
        if catalog != saved { push(final: true) } else { bake() }
    }

    // MARK: - What is edited

    var graphNames: [String] { catalog.names }
    func isBuiltIn(_ name: String) -> Bool { MaterialLibrary.names.contains(name) }
    var isDirty: Bool { catalog != saved || assignments != savedAssignments }
    func isDirty(_ name: String) -> Bool { catalog.graphs[name] != saved.graphs[name] }

    /// The shown graph: the catalog's, else the built-in one. Setting it is an edit.
    var graph: MaterialGraph {
        get { catalog.graph(selectedGraph) ?? MaterialGraph(selectedGraph) }
        set { edit { $0 = newValue } }
    }

    /// The function shown (a pixel processor's), if one is.
    var function: MatFunction? { editingFunction.flatMap { graph.node($0)?.function } }

    /// An edit of the shown graph (one undo step; while dragging, part of the drag's).
    func edit(_ change: (inout MaterialGraph) -> Void) {
        var g = graph
        change(&g)
        var c = catalog
        c.graphs[selectedGraph] = g
        commit(c)
    }

    /// An edit of the function shown.
    func editFunction(_ change: (inout MatFunction) -> Void) {
        guard let id = editingFunction else { return }
        edit { g in
            guard let k = g.index(id) else { return }
            var f = g.nodes[k].function ?? .passThrough
            change(&f)
            g.nodes[k].function = f
        }
    }

    func beginDrag() {
        guard !dragging else { return }
        dragging = true
        dragStart = catalog
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        if let start = dragStart, start != catalog { registerUndo(start) }
        dragStart = nil
        push(final: true)
    }

    private func commit(_ c: MaterialCatalog) {
        guard c != catalog else { return }
        if !dragging { registerUndo(catalog) }
        catalog = c
        if dragging { pushLive() } else { push(final: true) }
    }

    private func registerUndo(_ old: MaterialCatalog) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.restore(old) }
        undo.endUndoGrouping()
    }

    private func restore(_ old: MaterialCatalog) {
        let now = catalog
        undo.registerUndo(withTarget: self) { m in m.restore(now) }
        catalog = old
        if !graphNames.contains(selectedGraph) { select(graphNames[0]) }
        if let f = editingFunction, graph.node(f)?.function == nil { editingFunction = nil }
        prune()
        push(final: true)
    }

    // MARK: - Baking, and to the renderer

    /// At most 30 a second while dragging, the last always.
    private func pushLive() {
        let now = CACurrentMediaTime()
        if now - liveSent >= 1 / 30 {
            liveSent = now
            push(final: false)
        } else if pendingLive == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingLive = nil
                self?.liveSent = CACurrentMediaTime()
                self?.push(final: false)
            }
            pendingLive = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 / 30, execute: work)
        }
    }

    /// The registry key of the edited catalog ("" when it is what was loaded at launch).
    var key: String {
        if let k = keyMade, k.catalog == catalog { return k.key }
        let key = catalog == MaterialCatalog.launch ? "" : MaterialCatalog.register(catalog)
        keyMade = (catalog, key)
        return key
    }
    private var keyMade: (catalog: MaterialCatalog, key: String)?

    private func push(final: Bool) {
        if final { pendingLive?.cancel(); pendingLive = nil; saveDraft() }
        bake()
        let key = self.key
        guard controller.settings.scene.materials != key else { return }
        controller.update { $0.scene.materials = key }
    }

    /// Bakes the shown graph: its nodes' thumbnails (those not seen yet), the outputs; given to MaterialBake under the
    /// graph's key, so the renderer's bake of it finds it done.
    func bake() {
        let g = graph, c = catalog
        let plan: MatPlan
        do {
            plan = try MatPlan(g, library: { c.graph($0) })
            planError = nil
        } catch {
            planError = "\(error)"
            return
        }
        guard let engine else { return }
        let key = MaterialBake.key(g, catalog: c)
        let device = engine.device
        engine.evaluate(plan, known: Set(thumbsByHash.keys)) { [weak self] r in
            MaterialBake.shared(device).adopt(r, key: key)
            guard let self else { return }
            for (h, image) in r.thumbnails { self.thumbsByHash[h] = image }
            if self.thumbsByHash.count > 2048 {   // images of hashes no plan has any more
                let live = Set(r.plan.steps.map(\.hash))
                self.thumbsByHash = self.thumbsByHash.filter { live.contains($0.key) }
            }
            guard r.plan.name == self.selectedGraph else { return }
            var thumbs: [String: CGImage] = [:]
            for s in r.plan.steps where !s.id.contains("/") { thumbs[s.id] = self.thumbsByHash[s.hash] }
            self.thumbnails = thumbs
            self.errors = r.errors
            self.result = r
        }
    }

    private func received(_ s: RenderSettings) {
        if s.scene != scene { scene = s.scene }
        if !dragging, s.scene.materials != key { push(final: true) }   // a scene loaded with the saved ones
    }

    /// The step of the bake that is node `id` of the shown graph (its image: the 2D view's).
    func step(_ id: String) -> MatPlan.Step? {
        guard let r = result, let k = r.plan.index[id] else { return nil }
        return r.plan.steps[k]
    }

    /// The node the 2D view shows.
    var previewNodeID: String? {
        if let p = pinned, graph.node(p) != nil { return p }
        if editingFunction == nil, let f = focus, graph.node(f) != nil { return f }
        if let f = editingFunction { return f }
        return graph.channels[.baseColor] ?? graph.nodes.last?.id
    }

    // MARK: - The material workshop

    var inWorkshop: Bool { scene.kind == .materials }

    /// To the material workshop, showing the shown graph.
    func showInWorkshop() {
        let name = selectedGraph, key = self.key, defaults = controller.defaultSettings
        controller.update { s in
            s.scene.materials = key
            s.scene.materialWorkshop.graph = name
            guard s.scene.kind != .materials else { return }
            s.scene.kind = .materials
            s.scene.extraModels = []
            s.applySceneDefaults(from: defaults)
        }
    }

    func setLayout(_ l: MaterialWorkshopSettings.Layout) { controller.update { $0.scene.materialWorkshop.layout = l } }
    func setBackdrop(_ b: MaterialWorkshopSettings.Backdrop) { controller.update { $0.scene.materialWorkshop.backdrop = b } }

    /// Shows `name`: in the workshop too, if it shows another.
    func select(_ name: String) {
        guard name != selectedGraph else { return }
        selectedGraph = name
        editingFunction = nil
        selection = []
        focus = nil
        pinned = nil
        search = nil
        thumbnails = [:]
        errors = [:]
        result = nil
        frameAll(in: canvasSize)
        bake()
        if inWorkshop, scene.materialWorkshop.graph != name { showInWorkshop() }
    }

    // MARK: - Graphs

    /// A new graph: `base`'s copy (or a plain one), under a name of its own.
    func newGraph(from base: MaterialGraph? = nil) {
        var g = base ?? MaterialEditorModel.template
        g.name = uniqueName(base.map { "\($0.name) copy" } ?? "Material")
        var c = catalog
        c.graphs[g.name] = g
        commit(c)
        select(g.name)
    }

    func duplicate() { newGraph(from: graph) }

    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while graphNames.contains(name) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// Renames a graph of its own (a built-in one keeps its name: scenes name it by it); its subgraph nodes elsewhere
    /// follow.
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !isBuiltIn(selectedGraph), !trimmed.isEmpty, trimmed != selectedGraph, !graphNames.contains(trimmed) else { return }
        let old = selectedGraph
        var c = catalog
        var g = graph
        g.name = trimmed
        c.graphs[old] = nil
        c.graphs[trimmed] = g
        for (n, var other) in c.graphs {
            var changed = false
            for k in other.nodes.indices where other.nodes[k].kind == .subgraph && other.nodes[k].text("graph") == old {
                other.nodes[k].params["graph"] = .text(trimmed)
                changed = true
            }
            if changed { c.graphs[n] = other }
        }
        selectedGraph = trimmed
        commit(c)
        if inWorkshop, scene.materialWorkshop.graph == old { showInWorkshop() }
    }

    /// Removes a graph of its own, or a built-in one's edits.
    func deleteGraph() {
        var c = catalog
        c.graphs[selectedGraph] = nil
        let custom = !isBuiltIn(selectedGraph)
        commit(c)
        if custom { select(graphNames[0]) }
        prune()
    }

    /// Uniform grey into the base colour, a flat normal: what a new graph starts as.
    static var template: MaterialGraph {
        var b = MatBuilder("Material")
        b.output(.baseColor, b.node(.uniformColor, ["color": .color([0.6, 0.6, 0.6, 1])]))
        b.output(.roughness, b.node(.uniform, ["value": .float(0.5)]))
        return b.graph
    }

    // MARK: - Saving

    /// Writes every graph that differs from what is saved (a built-in one as built in: its file goes), and removes the
    /// files of deleted ones.
    func save() {
        guard let folder else {
            message = "METALRENDERER_MATERIALS=builtin: nothing is saved"
            return
        }
        do {
            for (name, g) in catalog.graphs where g != saved.graphs[name] {
                if let builtIn = MaterialLibrary.named(name), builtIn == g { try MaterialStore.remove(name, in: folder) } else { try MaterialStore.save(g, in: folder) }
            }
            for name in saved.graphs.keys where catalog.graphs[name] == nil { try MaterialStore.remove(name, in: folder) }
            saved = catalog
            if assignments != savedAssignments, let url = assignmentsURL {
                try assignments.save(to: url)
                savedAssignments = assignments
            }
            if keepsDraft { MaterialEditorModel.saveDraft(nil) }
            message = "Saved to \(folder.path)"
            push(final: true)
        } catch {
            message = "Not saved: \(error.localizedDescription)"
        }
    }

    /// The shown graph as it is saved (or built in).
    func revert() {
        var c = catalog
        c.graphs[selectedGraph] = saved.graphs[selectedGraph]
        commit(c)
        if !graphNames.contains(selectedGraph) { select(graphNames[0]) }
        prune()
    }

    func revertAll() {
        commit(saved)
        if !graphNames.contains(selectedGraph) { select(graphNames[0]) }
        prune()
    }

    /// The shown graph as Swift (MatSwiftSource), on the clipboard.
    func copyAsSwift() {
        pasteboard.clearContents()
        pasteboard.setString(graph.swiftSource, forType: .string)
        message = "\(selectedGraph) copied as Swift"
    }

    /// The bake's outputs as image files in `folder`.
    func export(to folder: URL, format: MatExport.Format) {
        guard let engine, let r = result else { message = "Nothing baked to export"; return }
        do {
            let files = try MatExport.write(r, engine: engine, to: folder, format: format)
            message = "Exported \(files.count) files to \(folder.path)"
        } catch {
            message = "Not exported: \(error)"
        }
    }

    func clearMessage() { message = nil }

    private func saveDraft() {
        guard keepsDraft else { return }
        draftSave?.cancel()
        let draft = catalog == saved ? nil : catalog
        let work = DispatchWorkItem { MaterialEditorModel.saveDraft(draft) }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func saveDraft(_ c: MaterialCatalog?) {
        guard let c, let data = try? JSONEncoder().encode(c.graphs.keys.sorted().map { c.graphs[$0]! }) else {
            UserDefaults.standard.removeObject(forKey: draftKey)
            return
        }
        UserDefaults.standard.set(data, forKey: draftKey)
    }

    private static func loadDraft() -> MaterialCatalog? {
        guard let data = UserDefaults.standard.data(forKey: draftKey),
              let graphs = try? JSONDecoder().decode([MaterialGraph].self, from: data) else { return nil }
        return MaterialCatalog(graphs: Dictionary(graphs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    // MARK: - The graph's edits

    /// The ids the canvas shows (the function's nodes while one is edited).
    private var shownIDs: Set<String> {
        if let f = function { return Set(f.nodes.map(\.id)) }
        return graph.allIDs
    }

    /// The selection without what is gone.
    private func prune() {
        let ids = shownIDs
        selection = selection.filter { ids.contains($0) }
        if let f = focus, !ids.contains(f) { focus = nil }
        if let p = pinned, graph.node(p) == nil { pinned = nil }
    }

    func click(_ id: String, extend: Bool = false) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if !selection.contains(id) {
            selection = [id]
        }
        focus = id
    }

    func clearSelection() {
        selection = []
        focus = nil
    }

    func selectAll() { selection = shownIDs }

    /// Adds a node at `at` (the graph's coordinates), selected.
    @discardableResult
    func addNode(_ kind: MatOpKind, at: SIMD2<Float>, params: [String: MatParam] = [:]) -> String {
        var id = ""
        edit { g in
            g = MatLayout.arranged(g)
            id = VFXEffect.unique(kind.rawValue, g.allIDs)
            g.nodes.append(MatNode(kind, params, id: id, at: at))
        }
        selection = [id]
        focus = id
        search = nil
        return id
    }

    /// Adds another graph as a node.
    @discardableResult
    func addSubgraph(_ name: String, at: SIMD2<Float>) -> String? {
        guard name != selectedGraph else { return nil }
        return addNode(.subgraph, at: at, params: ["graph": .text(name)])
    }

    /// Adds an output node of channel `c` (unless the graph has one).
    func addOutput(_ c: MatChannel, at: SIMD2<Float>) {
        guard graph.channels[c] == nil else { return }
        addNode(.output, at: at, params: ["usage": .choice(c.rawValue), "name": .text(c.rawValue)])
    }

    /// Adds a function node (the function shown), selected.
    @discardableResult
    func addFunctionNode(_ kind: MatFnKind, at: SIMD2<Float>) -> String {
        var id = ""
        editFunction { f in
            id = VFXEffect.unique(kind.rawValue, Set(f.nodes.map(\.id)))
            f.nodes.append(MatFnNode(kind, id: id, at: at))
        }
        selection = [id]
        focus = id
        search = nil
        return id
    }

    /// Removes the selected nodes and their wires (a function's Result stays).
    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let gone = selection
        if editingFunction != nil {
            editFunction { f in
                let removed = Set(f.nodes.filter { gone.contains($0.id) && $0.kind != .result }.map(\.id))
                f.nodes.removeAll { removed.contains($0.id) }
                f.links.removeAll { removed.contains($0.from) || removed.contains($0.to) }
            }
        } else {
            edit { g in
                g.nodes.removeAll { gone.contains($0.id) }
                g.links.removeAll { gone.contains($0.from) || gone.contains($0.to) }
            }
            if let p = pinned, gone.contains(p) { pinned = nil }
        }
        clearSelection()
    }

    func moveSelection(by delta: SIMD2<Float>, ids: Set<String>? = nil) {
        let moving = ids ?? selection
        if editingFunction != nil {
            editFunction { f in for i in f.nodes.indices where moving.contains(f.nodes[i].id) { f.nodes[i].at += delta } }
        } else {
            edit { g in
                g = MatLayout.arranged(g)
                for i in g.nodes.indices where moving.contains(g.nodes[i].id) { g.nodes[i].at += delta }
            }
        }
    }

    func wire(into owner: String, _ input: String) -> (from: String, output: String)? {
        if let f = function { return f.link(into: owner, input).map { ($0.from, $0.output) } }
        return graph.link(into: owner, input).map { ($0.from, $0.output) }
    }

    /// Wires `from`'s output into `to`'s input (replacing what was wired there), if that can be: both are pins, and the
    /// wire makes no loop.
    @discardableResult
    func link(_ from: String, _ output: String, to: String, _ input: String) -> Bool {
        if let f = function {
            guard from != to, let a = f.node(from), let b = f.node(to), a.kind != .result, b.kind.spec.pin(input)?.type != nil || b.kind.spec.pin(input)?.generic == true,
                  !f.upstream(of: from).contains(to) else { return false }
            editFunction { f in
                f.links.removeAll { $0.to == to && $0.input == input }
                f.links.append(MatLink(from, output, to: to, input))
            }
            return true
        }
        let c = catalog
        guard graph.canLink(from, output, to: to, input, library: { c.graph($0) }) else { return false }
        edit { g in
            g.links.removeAll { $0.to == to && $0.input == input }
            g.links.append(MatLink(from, output, to: to, input))
        }
        return true
    }

    func unlink(_ to: String, _ input: String) {
        if editingFunction != nil {
            editFunction { f in f.links.removeAll { $0.to == to && $0.input == input } }
        } else {
            edit { g in g.links.removeAll { $0.to == to && $0.input == input } }
        }
    }

    func setParam(_ id: String, _ name: String, _ value: MatParam) {
        if editingFunction != nil {
            editFunction { f in if let k = f.nodes.firstIndex(where: { $0.id == id }) { f.nodes[k].params[name] = value } }
        } else {
            edit { g in if let k = g.index(id) { g.nodes[k].params[name] = value } }
        }
    }

    func setSize(_ id: String, _ size: MatSize) { edit { g in if let k = g.index(id) { g.nodes[k].size = size } } }
    func setBits(_ id: String, _ bits: MatBits) { edit { g in if let k = g.index(id) { g.nodes[k].bits = bits } } }

    /// Exposes node `id`'s parameter `name` as a graph input (named after it, its value the input's default), or binds
    /// it back to its own value.
    func expose(_ id: String, _ name: String, _ on: Bool) {
        edit { g in
            guard let k = g.index(id) else { return }
            if on {
                let spec = g.nodes[k].kind.spec.param(name)
                let input = VFXEffect.unique(name, Set(g.inputs.map(\.name)))
                g.inputs.append(MatGraphInput(input, spec?.title ?? name, g.nodes[k].param(name), span: spec?.span))
                g.nodes[k].exposed[name] = input
            } else if let input = g.nodes[k].exposed[name] {
                if let v = g.inputs.first(where: { $0.name == input })?.value { g.nodes[k].params[name] = v }
                g.nodes[k].exposed[name] = nil
                if !g.nodes.contains(where: { $0.exposed.values.contains(input) }) { g.inputs.removeAll { $0.name == input } }
            }
        }
    }

    func setInput(_ name: String, _ value: MatParam) {
        edit { g in if let k = g.inputs.firstIndex(where: { $0.name == name }) { g.inputs[k].value = value } }
    }

    func setSurface(_ change: @escaping (inout MatSurface) -> Void) { edit { change(&$0.surface) } }

    // MARK: - Copy and paste (nodes, and the wires between them)

    private struct Clip: Codable {
        var matNodes: [MatNode] = []
        var fnNodes: [MatFnNode] = []
        var links: [MatLink]
    }

    func copySelection() {
        var clip = Clip(links: [])
        if let f = function {
            clip.fnNodes = f.nodes.filter { selection.contains($0.id) && $0.kind != .result }
            let ids = Set(clip.fnNodes.map(\.id))
            clip.links = f.links.filter { ids.contains($0.from) && ids.contains($0.to) }
        } else {
            let g = MatLayout.arranged(graph)
            clip.matNodes = g.nodes.filter { selection.contains($0.id) }
            let ids = Set(clip.matNodes.map(\.id))
            clip.links = g.links.filter { ids.contains($0.from) && ids.contains($0.to) }
        }
        guard !clip.matNodes.isEmpty || !clip.fnNodes.isEmpty,
              let data = try? JSONEncoder().encode(clip), let text = String(data: data, encoding: .utf8) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var canPaste: Bool { clipboard() != nil }

    private func clipboard() -> Clip? {
        guard let text = pasteboard.string(forType: .string), let data = text.data(using: .utf8),
              let clip = try? JSONDecoder().decode(Clip.self, from: data) else { return nil }
        return editingFunction != nil ? (clip.fnNodes.isEmpty ? nil : clip) : (clip.matNodes.isEmpty ? nil : clip)
    }

    /// The clipboard's nodes, 30 units down and right of where they were, under ids of their own; selected.
    func paste() {
        guard let clip = clipboard() else { return }
        var pasted: Set<String> = []
        var renamed: [String: String] = [:]
        if editingFunction != nil {
            editFunction { f in
                var used = Set(f.nodes.map(\.id))
                for var n in clip.fnNodes {
                    let id = VFXEffect.unique(n.kind.rawValue, used)
                    used.insert(id)
                    renamed[n.id] = id
                    n.id = id
                    n.at += [30, 30]
                    f.nodes.append(n)
                    pasted.insert(id)
                }
                for l in clip.links { f.links.append(MatLink(renamed[l.from]!, l.output, to: renamed[l.to]!, l.input)) }
            }
        } else {
            edit { g in
                g = MatLayout.arranged(g)
                var used = g.allIDs
                for var n in clip.matNodes {
                    let id = VFXEffect.unique(n.kind.rawValue, used)
                    used.insert(id)
                    renamed[n.id] = id
                    n.id = id
                    n.at += [30, 30]
                    g.nodes.append(n)
                    pasted.insert(id)
                }
                for l in clip.links { g.links.append(MatLink(renamed[l.from]!, l.output, to: renamed[l.to]!, l.input)) }
            }
        }
        selection = pasted
        focus = pasted.count == 1 ? pasted.first : nil
    }

    // MARK: - Click-to-pick (P7: assignments)

    /// Arms a pick: the next click in the renderer's view names the material there.
    func pick() {
        picking = true
        controller.pickMaterial { [weak self] p in
            self?.picking = false
            self?.picked = p
        }
    }

    func cancelPick() {
        picking = false
        controller.cancelPick()
    }

    func clearPick() { picked = nil }

    /// This scene's assignments.
    var sceneAssignments: [MaterialAssignments.Entry] { assignments.scenes[MaterialAssignments.scope(scene)] ?? [] }

    /// Gives `graph` to the picked material: the scene is made again with it (its material procedural).
    func assign(_ graph: String, to pick: MaterialPick) {
        var a = assignments
        let scope = MaterialAssignments.scope(scene)
        var list = a.scenes[scope] ?? []
        list.removeAll { $0.material == pick.material }
        list.append(.init(material: pick.material, fingerprint: pick.fingerprint, graph: graph))
        a.scenes[scope] = list.sorted { $0.material < $1.material }
        setAssignments(a)
        message = "\(graph) is material \(pick.material)'s now (the scene is made again)"
    }

    /// The scene's material `material` as the scene makes it again.
    func unassign(_ material: Int) {
        var a = assignments
        let scope = MaterialAssignments.scope(scene)
        a.scenes[scope]?.removeAll { $0.material == material }
        if a.scenes[scope]?.isEmpty == true { a.scenes[scope] = nil }
        setAssignments(a)
    }

    private func setAssignments(_ a: MaterialAssignments) {
        assignments = a
        let key = a == MaterialAssignments.launch ? "" : MaterialAssignments.register(a)
        let materials = self.key
        controller.update { s in
            s.scene.materialAssignments = key
            s.scene.materials = materials
        }
    }

    // MARK: - The canvas's view (GraphCanvasModel)

    var searchAt: SIMD2<Float>? { search }
    func openSearch() { search = graphPoint(hover) }
    func closeSearch() { search = nil }

    /// The whole graph (or function) in a canvas of `size`.
    func frameAll(in size: CGSize) { frame(MatCanvasLayout(self).bounds, in: size) }
}
