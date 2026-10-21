import AppKit
import Characters
import Effects
import EngineCore
import Metal
import MetalRenderer
import Physics
import Plants
import SwiftUI
import simd

/// What the Project Graph asks of the renderer (RendererController; the tests' stand-in).
protocol ProjectGraphHost: AnyObject {
    var settings: RenderSettings { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void)
    /// Every scene installed: its outline.
    func observeOutline(_ observer: @escaping (SceneOutline) -> Void)
    /// The camera flies to `target` (in the scene now, or once its scene is in).
    func frame(_ target: FrameTarget)
    /// `target` is selected in the view (its box drawn, F frames it); nil: nothing.
    func select(_ target: FrameTarget?)
    /// Every click in the view: the instance it selected (nil: nothing).
    func observeViewportSelection(_ observer: @escaping (Int?) -> Void)
    /// Click-to-pick: the next click in the view (MaterialPick: its instance).
    func pickMaterial(_ picked: @escaping (MaterialPick?) -> Void)
    func cancelPick()
    var metalDevice: MTLDevice? { get }
}

/// What double-clicking a thing opens.
enum EditorTarget: Equatable {
    case material(String), effect(String), plant(String), building(String), character(String), painter(String)

    package init?(_ key: AssetKey) {
        switch key.kind {
        case .materialGraph: self = .material(key.name)
        case .vfxGraph: self = .effect(key.name)
        case .species: self = .plant(key.name)
        case .buildingStyle: self = .building(key.name)
        case .character: self = .character(key.name)
        case .painterDoc: self = .painter(key.name)
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .material: return "Material Designer"
        case .effect: return "VFX Editor"
        case .plant: return "Plant Editor"
        case .building: return "Building Editor"
        case .character: return "Character Editor"
        case .painter: return "Material Painter"
        }
    }
}

/// The Project Graph window's state (ProjectGraphView): the project's graph (ProjectGraph) made from the scenes'
/// outlines and the graph's edits, what of it is shown and where (the layouts), the selection, and the edits, which
/// are undo steps and are saved (SceneOverrides). Main thread only.
final class ProjectGraphModel: ObservableObject, GraphCanvasModel {
    enum Scope: String, CaseIterable, Identifiable {
        case project, scene
        var id: String { rawValue }
        var title: String { self == .project ? "Project" : "Current scene" }
    }

    let host: ProjectGraphHost
    let undo = UndoManager()
    private let folder: URL?

    // MARK: What the graph is made from

    private(set) var outlines: [String: SceneOutline]
    @Published private(set) var overrides: SceneOverrides
    private var saved: SceneOverrides
    private let library: [AssetKey]
    @Published private(set) var source: SourceIndex?
    @Published private(set) var graph = ProjectGraph()

    // MARK: What is shown

    @Published var layout = GraphLayout.force { didSet { if layout != oldValue { relayout(keep: false) } } }
    @Published var scope = Scope.project { didSet { if scope != oldValue { refresh(keep: false) } } }
    @Published var edgeKinds: Set<ProjectGraph.EdgeKind> = [.child, .sharedAsset, .generatedFrom, .runtime] {
        didSet { if edgeKinds != oldValue { refresh(keep: true) } }
    }
    /// The open nodes (their children are shown), and how many pages of an open aggregate's members.
    @Published private(set) var open: Set<String> = ["project"]
    @Published private(set) var pages: [String: Int] = [:]
    @Published private(set) var visible = ProjectGraph.Visible()
    /// Each shown node's place (the graph's units, about the middle) and radius; the cone's places.
    @Published private(set) var positions: [SIMD2<Float>] = []
    @Published private(set) var radii: [Float] = []
    @Published private(set) var cone: [SIMD3<Float>] = []
    private var force: ForceLayout?
    private var forceTimer: Timer?
    @Published var currentScene: String

    // MARK: GraphCanvasModel

    @Published var pan = CGPoint(x: 400, y: 300)
    @Published var zoom: CGFloat = 0.8
    var canvasSize = CGSize(width: 800, height: 600)
    var canvasOrigin = CGPoint.zero
    var hover = CGPoint.zero
    var focusCanvas: (() -> Void)?
    var zoomLimits: ClosedRange<CGFloat> { 0.03...3 }
    @Published var selection: Set<String> = []
    @Published var focus: String?
    @Published var hovered: String?
    let searchAt: SIMD2<Float>? = nil

    // MARK: Search, picking, opening

    @Published var query = "" { didSet { results = graph.search(query, limit: 60) } }
    @Published private(set) var results: [String] = []
    @Published private(set) var picking = false
    @Published var status = ""
    /// Opens an editor at an asset (the app's panels).
    var openEditor: ((EditorTarget) -> Void)?
    /// Something to rename (the inspector's field takes the focus).
    @Published var renaming: String?

    private var settingsKey: String
    /// Edits of a scene other than the current one wait for it (a key would make the current one again).
    private var pendingKey: String?
    private var saveWork: DispatchWorkItem?

    /// `folder`: where outlines and edits are (nil: nothing is read or written); `saved`: the edits as they are saved.
    package init(host: ProjectGraphHost, folder: URL? = SceneOverrides.folder, outlines: [String: SceneOutline]? = nil,
         saved: SceneOverrides? = nil, library: [AssetKey]? = nil, loadSource: Bool = true) {
        self.host = host
        self.folder = folder
        self.outlines = outlines ?? OutlineStore.loadAll(from: folder?.appendingPathComponent("Outlines"))
        let edits = saved ?? (folder == SceneOverrides.folder ? SceneOverrides.launch : SceneOverrides.load(from: folder))
        self.saved = edits
        overrides = edits
        self.library = library ?? ProjectLibrary.current()
        currentScene = host.settings.scene.kind.envName
        settingsKey = host.settings.scene.sceneOverrides
        open = ["project", ProjectGraph.sceneID(currentScene)]
        rebuild(keep: false)
        host.observeOutline { [weak self] o in self?.received(o) }
        host.observeSettings { [weak self] s in self?.settingsChanged(s) }
        host.observeViewportSelection { [weak self] i in self?.selectedInView(i) }
        if loadSource {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let index = SourceIndex.load()
                DispatchQueue.main.async {
                    self?.source = index
                    self?.rebuild(keep: true)
                }
            }
        }
    }

    deinit { forceTimer?.invalidate() }

    // MARK: - The graph

    private func received(_ outline: SceneOutline) {
        var o = outline
        o.buildMs = 0
        guard outlines[o.kind] != o else { return }
        outlines[o.kind] = o
        if status.hasPrefix("Loading") { status = "" }
        rebuild(keep: true)
    }

    private func settingsChanged(_ s: RenderSettings) {
        let kind = s.scene.kind.envName
        settingsKey = s.scene.sceneOverrides
        if kind != currentScene {
            currentScene = kind
            open.insert(ProjectGraph.sceneID(kind))
            if let pending = pendingKey, pending != settingsKey {
                pendingKey = nil
                host.update { $0.scene.sceneOverrides = pending }
            }
            if scope == .scene { refresh(keep: false) }
        }
    }

    /// The graph made again (new outlines, edits, the sources), then what is shown.
    private func rebuild(keep: Bool) {
        graph = ProjectGraph.build(outlines: outlines, overrides: overrides, library: library, source: source)
        results = graph.search(query, limit: 60)
        refresh(keep: keep)
    }

    /// What is shown made again; `keep`: the force layout goes on from where its nodes are.
    func refresh(keep: Bool) {
        let root = scope == .scene ? graph.index[ProjectGraph.sceneID(currentScene)] ?? 0 : 0
        visible = graph.visible(open: open, pages: pages, kinds: edgeKinds.union([.child]), root: root)
        relayout(keep: keep)
    }

    private func relayout(keep: Bool) {
        let tree = LayoutTree(visible, graph: graph)
        radii = tree.radius
        var start = RadialLayout.place(tree)
        if keep, !positions.isEmpty {
            // Those shown before stay where they were; new ones start by their parents.
            let before = Dictionary(zip(oldIDs, positions), uniquingKeysWith: { a, _ in a })
            for (k, n) in visible.nodes.enumerated() {
                if let p = before[n.id] { start[k] = p }
                else if n.parent >= 0 { start[k] = start[n.parent] + start[k] * 0.05 + SIMD2(Float(k % 7) - 3, Float(k % 5) - 2) * 4 }
            }
        }
        forceTimer?.invalidate()
        forceTimer = nil
        force = nil
        switch layout {
        case .radial: positions = RadialLayout.place(tree)
        case .tree: positions = TidyTreeLayout.place(tree)
        case .cone:
            cone = ConeTreeLayout.place(tree)
            positions = cone.map { SIMD2($0.x, $0.z) }
        case .force:
            var f = ForceLayout(tree, start: start)
            for (k, n) in visible.nodes.enumerated() { if let p = pin(n.id) { f.pinned[k] = p; f.positions[k] = p } }
            if keep { f.reheat(0.5) }
            force = f
            positions = f.positions
            runForce()
        }
        oldIDs = visible.nodes.map(\.id)
    }
    private var oldIDs: [String] = []

    /// Steps the force layout about 60 times a second, 4 ms of it at most, until it settles.
    private func runForce() {
        guard forceTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, var f = self.force else { t.invalidate(); return }
            let start = CACurrentMediaTime()
            var moving = true
            while moving && CACurrentMediaTime() - start < 0.004 { moving = f.step() }
            self.force = f
            self.positions = f.positions
            if !moving { t.invalidate(); self.forceTimer = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        forceTimer = timer
    }

    /// Runs the force layout to its end at once (tests, pictures).
    func settle() {
        guard layout == .force, var f = force else { return }
        while f.step() {}
        force = f
        positions = f.positions
        forceTimer?.invalidate()
        forceTimer = nil
    }

    // MARK: - Nodes

    func node(_ id: String) -> ProjectGraph.Node? {
        if let n = graph[id] { return n }
        guard let (agg, _) = SceneOutline.member(of: id) else { return nil }
        return graph[agg]
    }

    /// A shown node's name: an aggregate's member is "<its name> #k".
    func name(_ id: String) -> String {
        if let n = graph[id] { return n.name }
        if let (agg, k) = SceneOutline.member(of: id), let a = graph[agg] { return "\(a.name) #\(k)" }
        return id
    }

    func isOpen(_ id: String) -> Bool { open.contains(id) }

    func setOpen(_ id: String, _ isOpen: Bool) {
        guard self.isOpen(id) != isOpen else { return }
        if isOpen { open.insert(id) } else { open.remove(id) }
        refresh(keep: true)
    }

    /// One more page of an open aggregate's members.
    func morePages(_ id: String) {
        pages[id] = (pages[id] ?? 1) + 1
        refresh(keep: true)
    }

    /// Opens what is above `id`, so it is shown.
    func reveal(_ id: String) {
        guard let n = graph.index[id] ?? SceneOutline.member(of: id).flatMap({ graph.index[$0.aggregate] }) else { return }
        var changed = false
        var path = graph.path(n)
        if graph.index[id] != nil { path.removeLast() }   // (an aggregate's member: the aggregate opens too)
        for k in path where !open.contains(graph.nodes[k].id) { open.insert(graph.nodes[k].id); changed = true }
        if let (agg, m) = SceneOutline.member(of: id), graph.index[id] == nil {
            let need = m / ProjectGraph.memberPage + 1
            if (pages[agg] ?? 1) < need { pages[agg] = need; changed = true }
        }
        if scope == .scene, let s = graph.nodes[n].scene, s != currentScene { scope = .project }
        if changed { refresh(keep: true) }
    }

    /// Selects `id` (its node shown, the canvas moved to it if it is off the view).
    func select(_ id: String, center: Bool = true) {
        reveal(id)
        selection = [id]
        focus = id
        // In the view too: what of this scene it is (another scene's, or an asset: nothing there).
        let target = frameTarget(id)
        host.select(target?.kind.envName == currentScene ? target : nil)
        if center, let k = visible.index[id], positions.indices.contains(k) {
            let p = viewPoint(positions[k])
            if p.x < 40 || p.y < 40 || p.x > canvasSize.width - 40 || p.y > canvasSize.height - 40 {
                pan = CGPoint(x: canvasSize.width / 2 - CGFloat(positions[k].x) * zoom, y: canvasSize.height / 2 - CGFloat(positions[k].y) * zoom)
            }
        }
    }

    /// The edges of `id`'s node (shown or not): in (to it) and out (from it).
    func references(_ id: String) -> [(other: Int, kind: ProjectGraph.EdgeKind, outgoing: Bool)] {
        guard let n = graph.index[id] else { return [] }
        return graph.edges.compactMap { e in
            e.a == n ? (e.b, e.kind, true) : e.b == n ? (e.a, e.kind, false) : nil
        }
    }

    // MARK: - The viewport

    /// A click in the view selected instance `i` (nil: nothing): its node is selected here.
    private func selectedInView(_ i: Int?) {
        guard let i else {
            selection = []
            focus = nil
            return
        }
        guard let id = id(ofInstance: i) else { return }
        select(id)
    }

    /// The camera at `id`'s thing (its scene made first if it is another).
    func showInViewport(_ id: String) {
        guard let target = frameTarget(id) else { return }
        let kind = target.kind
        if kind.envName != currentScene {
            let key = pendingKey ?? settingsKey
            pendingKey = nil
            host.update { s in
                s.scene.kind = kind
                s.scene.sceneOverrides = key
            }
            status = "Loading \(kind.title)…"
        }
        host.frame(target)
    }

    /// What of its scene `id` is: its instances (and those under it, a few thousand at most) or its box. Nil: not a
    /// scene's thing.
    func frameTarget(_ id: String) -> FrameTarget? {
        guard let n = node(id), let env = n.scene, let kind = SceneKind.allCases.first(where: { $0.envName == env }) else { return nil }
        var instances: [Int] = []
        var box = n.bounds
        if let (_, k) = SceneOutline.member(of: id), graph[id] == nil, let i = n.members[k] {
            instances = [i]
            box = nil
        } else if let k = graph.index[id] {
            // Its instances, and those under it (a folder's), a few thousand at most.
            var stack = [k]
            while let m = stack.popLast(), instances.count < 4096 {
                instances += graph.nodes[m].members.prefix(4096 - instances.count)
                stack += graph.children[m]
            }
        }
        return FrameTarget(kind: kind, scope: outlines[env]?.scope ?? env, instances: instances, box: box)
    }

    /// The next click in the view selects what it meets.
    func pick() {
        guard !picking else { host.cancelPick(); picking = false; return }
        picking = true
        status = "Click something in the view"
        host.pickMaterial { [weak self] p in
            guard let self else { return }
            self.picking = false
            guard let p, let id = self.id(ofInstance: p.instance) else { self.status = p == nil ? "" : "Nothing known there"; return }
            self.status = ""
            self.select(id)
        }
    }

    /// The node of instance `i` of the current scene: its object's, or its member's of an aggregate.
    func id(ofInstance i: Int) -> String? {
        let prefix = currentScene + ":"
        for (k, n) in graph.nodes.enumerated() where n.scene == currentScene && n.id.hasPrefix(prefix) {
            guard let at = n.members.position(of: i) else { continue }
            if n.kind == .aggregate { return SceneOutline.memberID(n.id, at) }
            if n.kind == .light { return n.id }
            if graph.children[k].isEmpty || n.members.count == 1 { return n.id }
        }
        return nil
    }

    /// What double-clicking `id` opens: its editor if it is made in one.
    func editorTarget(_ id: String) -> EditorTarget? {
        guard let n = node(id) else { return nil }
        if let a = n.asset { return EditorTarget(a) }
        return n.assets.lazy.compactMap(EditorTarget.init).first
    }

    func openInEditor(_ id: String) {
        guard let t = editorTarget(id) else { return }
        openEditor?(t)
    }

    /// Double-click: its editor, or open / close it.
    func activate(_ id: String) {
        if editorTarget(id) != nil { openInEditor(id); return }
        if let n = graph[id], n.kind.isBranch { setOpen(id, !isOpen(id)) } else { showInViewport(id) }
    }

    // MARK: - Edits

    /// What can be edited of `id`: a thing of a known scene (not the scene, an asset or a file).
    private func editable(_ id: String) -> (scene: String, scope: String, outlineID: String, node: ProjectGraph.Node)? {
        guard let n = node(id), let env = n.scene, let o = outlines[env] else { return nil }
        // (An aggregate's member: its id in the outline is the aggregate's with its number.)
        let outlineID = graph[id] == nil ? ProjectGraph.split(id)?.outlineID ?? "" : n.outlineID ?? ""
        guard !outlineID.isEmpty, outlineID != "scene" else { return nil }
        return (env, o.scope, outlineID, n)
    }

    /// Why `id` can't be hidden or duplicated (nil: it can).
    func lockReason(_ id: String) -> String? {
        guard let e = editable(id) else { return "Not a thing of a scene" }
        if e.outlineID.hasPrefix("folder:") { return "A folder of the graph's own" }
        return e.node.locked
    }

    func canHide(_ id: String) -> Bool { lockReason(id) == nil }
    func isHidden(_ id: String) -> Bool { node(id)?.hidden == true || isHiddenEdit(id) }
    private func isHiddenEdit(_ id: String) -> Bool {
        guard let e = editable(id) else { return false }
        return overrides[e.scope].hidden.contains { $0.id == e.outlineID }
    }

    /// What an edit holds while it is: the thing's fingerprint (a member's: its aggregate's, the members being one thing).
    private func fingerprint(_ id: String) -> String { node(id)?.fingerprint ?? "" }

    /// An undo step: the edits before, back.
    private func edit(_ name: String, _ change: (inout SceneOverrides) -> Void) {
        let before = overrides
        var after = overrides
        change(&after)
        guard after != before else { return }
        apply(after, from: before, name: name)
    }

    private func apply(_ after: SceneOverrides, from before: SceneOverrides, name: String) {
        undo.registerUndo(withTarget: self) { m in m.apply(before, from: after, name: name) }
        undo.setActionName(name)
        overrides = after
        rebuild(keep: true)
        scheduleSave()
        // What changes a scene: the current one made again now, another when it is next made.
        let key = SceneOverrides.register(after)
        if after.structural != before.structural {
            let current = outlines[currentScene]?.scope ?? currentScene
            let changed = Set(after.structural.scopes.keys).union(before.structural.scopes.keys)
                .filter { after.structural.scopes[$0] != before.structural.scopes[$0] }
            if changed.contains(current) {
                pendingKey = nil
                host.update { $0.scene.sceneOverrides = key }
            } else {
                pendingKey = key
            }
        }
    }

    func rename(_ id: String, to name: String) {
        guard let e = editable(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        edit("Rename") { o in
            o[e.scope].renames[e.outlineID] = trimmed.isEmpty || trimmed == outlineName(e) ? nil : trimmed
        }
    }

    /// Its name as the scene has it.
    private func outlineName(_ e: (scene: String, scope: String, outlineID: String, node: ProjectGraph.Node)) -> String {
        outlines[e.scene]?.nodes.first { $0.id == e.outlineID }?.name ?? e.node.name
    }

    func setHidden(_ ids: Set<String>, _ hidden: Bool) {
        edit(hidden ? "Hide" : "Show") { o in
            for id in ids {
                guard let e = editable(id), lockReason(id) == nil else { continue }
                o[e.scope].hidden.removeAll { $0.id == e.outlineID }
                if hidden { o[e.scope].hidden.append(SceneOverrides.Ref(id: e.outlineID, fingerprint: fingerprint(id))) }
            }
        }
    }

    /// Copies of `ids` beside them (moved along x by their size).
    @discardableResult
    func duplicate(_ ids: Set<String>) -> [String] {
        var made: [String] = []
        edit("Duplicate") { o in
            for id in ids.sorted() {
                guard let e = editable(id), lockReason(id) == nil else { continue }
                let size = e.node.bounds.map { $0.hi.x - $0.lo.x } ?? 1
                let offset = SceneOverrides.Duplicate.flat(translate([max(size, 0.5) * 1.2, 0, 0]))
                var k = 1
                while o[e.scope].duplicates.contains(where: { $0.id == "copy:\(e.outlineID)~\(k)" }) { k += 1 }
                let copy = SceneOverrides.Duplicate(id: "copy:\(e.outlineID)~\(k)", name: "\(name(id)) copy\(k > 1 ? " \(k)" : "")",
                                                    source: SceneOverrides.Ref(id: e.outlineID, fingerprint: fingerprint(id)), offset: offset)
                o[e.scope].duplicates.append(copy)
                made.append(ProjectGraph.thingID(e.scene, copy.id))
            }
        }
        return made
    }

    /// Removes a duplicate (a copy the graph made), or hides a thing of the scene.
    func delete(_ ids: Set<String>) {
        var hide: Set<String> = []
        edit("Delete") { o in
            for id in ids {
                guard let e = editable(id) else { continue }
                if let k = o[e.scope].duplicates.firstIndex(where: { $0.id == e.outlineID }) {
                    o[e.scope].duplicates.remove(at: k)
                    o[e.scope].renames[e.outlineID] = nil
                    o[e.scope].folders[e.outlineID] = nil
                } else {
                    hide.insert(id)
                }
            }
        }
        if !hide.isEmpty { setHidden(hide, true) }
    }

    /// Moves `ids` into folder `path` of their scene ("" back where the scene has them), or under thing `into`.
    func move(_ ids: Set<String>, toFolder path: String) {
        edit("Move") { o in
            for id in ids {
                guard let e = editable(id) else { continue }
                o[e.scope].folders[e.outlineID] = path.isEmpty ? nil : path
            }
        }
    }

    func move(_ ids: Set<String>, into target: String) {
        // Onto a scene: back where the scene has them.
        if graph[target]?.kind == .scene { move(ids, toFolder: ""); return }
        guard let t = editable(target) else { return }
        if t.outlineID.hasPrefix("folder:") { move(ids, toFolder: String(t.outlineID.dropFirst(7))); return }
        edit("Move") { o in
            for id in ids where id != target {
                guard let e = editable(id), e.scene == t.scene,
                      let a = graph.index[id], let b = graph.index[target], !graph.isAncestor(a, of: b) else { continue }
                o[e.scope].folders[e.outlineID] = "@" + t.outlineID
            }
        }
    }

    /// Pins a node of the force layout where it is (its scene's edits, or the project's).
    func pinScope(_ id: String) -> (scope: String, key: String) {
        if let e = editable(id) { return (e.scope, e.outlineID) }
        return ("project", id)
    }

    func pin(_ id: String) -> SIMD2<Float>? {
        let (s, k) = pinScope(id)
        guard let p = overrides[s].pins[k], p.count == 2 else { return nil }
        return SIMD2(p[0], p[1])
    }

    func setPin(_ id: String, _ p: SIMD2<Float>?) {
        let (s, k) = pinScope(id)
        edit(p == nil ? "Unpin" : "Pin") { o in o[s].pins[k] = p.map { [($0.x * 10).rounded() / 10, ($0.y * 10).rounded() / 10] } }
    }

    func unpinAll() {
        edit("Unpin All") { o in for s in o.scopes.keys { o[s].pins = [:] } }
    }

    private func scheduleSave() {
        guard let folder else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(to: folder) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes the edits now (and at quit).
    func save(to folder: URL? = nil) {
        guard let folder = folder ?? self.folder, overrides != saved else { return }
        do {
            try overrides.save(to: folder, comparedTo: saved)
            saved = overrides
        } catch {
            status = "Can't save the edits: \(error.localizedDescription)"
        }
    }

    // MARK: - Dragging on the canvas

    private var dragStart: [Int: SIMD2<Float>] = [:]

    /// A shown node dragged: it moves (and in the force layout pulls its neighbours), pinned where it is let go.
    func dragNode(_ k: Int, to p: SIMD2<Float>) {
        guard positions.indices.contains(k) else { return }
        if dragStart[k] == nil { dragStart[k] = positions[k] }
        positions[k] = p
        if layout == .force, force != nil {
            force!.pinned[k] = p
            force!.positions[k] = p
            force!.reheat(0.3)
            runForce()
        }
    }

    func endDragNode(_ k: Int) {
        guard dragStart.removeValue(forKey: k) != nil, visible.nodes.indices.contains(k) else { return }
        if layout == .force { setPin(visible.nodes[k].id, positions[k]) }
    }

    /// The shown node at graph point `p`, if one is there.
    func node(at p: SIMD2<Float>) -> Int? {
        var best: (k: Int, d: Float)?
        for k in positions.indices.reversed() {
            let d = length(positions[k] - p) - radii[k]
            if d < 3 / Float(zoom), best.map({ d < $0.d }) ?? true { best = (k, d) }
        }
        return best?.k
    }

    // MARK: - GraphCanvasModel

    func click(_ id: String, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            focus = selection.count == 1 ? selection.first : focus
        } else {
            selection = [id]
            focus = id
        }
    }

    func clearSelection() { selection = []; focus = nil }
    func selectAll() { selection = Set(visible.nodes.map(\.id)) }
    func deleteSelection() { delete(selection) }
    func copySelection() {}
    func paste() { let made = duplicate(selection); if !made.isEmpty { selection = Set(made); focus = made.first } }
    func beginDrag() { undo.beginUndoGrouping() }
    func endDrag() { undo.endUndoGrouping() }
    func moveSelection(by delta: SIMD2<Float>, ids: Set<String>?) {}
    func wire(into owner: String, _ input: String) -> (from: String, output: String)? { nil }
    func link(_ from: String, _ output: String, to: String, _ input: String) -> Bool { false }
    func unlink(_ to: String, _ input: String) {}
    func openSearch() {}
    func closeSearch() {}

    /// The shown graph in the canvas.
    func frameAll(in size: CGSize) {
        guard !positions.isEmpty else { return }
        var lo = positions[0], hi = positions[0]
        for (p, r) in zip(positions, radii) { lo = simd_min(lo, p - r); hi = simd_max(hi, p + r) }
        frame(CGRect(x: CGFloat(lo.x), y: CGFloat(lo.y), width: CGFloat(hi.x - lo.x), height: CGFloat(hi.y - lo.y)), in: size)
    }

    // MARK: - Summary

    /// The scenes with no outline yet.
    var unindexed: [String] { graph.nodes.filter { $0.kind == .scene && !$0.indexed }.map(\.name) }
}
