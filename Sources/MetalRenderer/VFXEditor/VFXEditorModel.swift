import AppKit
import Combine
import QuartzCore
import simd

/// What the VFX editor needs of the renderer (RendererController; a stand-in in the tests).
protocol VFXEditorHost: AnyObject {
    var settings: RenderSettings { get }
    var defaultSettings: RenderSettings { get }
    var effectsStatus: VFXStatus? { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void)
    func observeTick(_ observer: @escaping () -> Void)
}

extension RendererController: VFXEditorHost {
    var effectsStatus: VFXStatus? { status?.effects }
}

/// The VFX editor's state, on the main thread: the effects as edited (a catalog: the built-in ones edited, and new
/// ones), as saved, which one is shown, what of it is selected, and the canvas's view.
///
/// An edit goes to the renderer as the catalog's registry key (`SceneSettings.effects`): every scene that places an
/// effect of that name (the VFX stage, the particles scene, the showcase) runs the edited one, in place if only its
/// values changed, after a compile if its code did, or made again (Renderer.editEffects). Unsaved edits are a draft
/// until saved or reverted. One undo step per edit; a drag (a slider's, a node's) is one edit.
final class VFXEditorModel: ObservableObject {
    let controller: VFXEditorHost
    let undo = UndoManager()
    /// Where Save writes (nil: nowhere), and whether unsaved edits are kept as a draft.
    private let folder: URL?
    private let keepsDraft: Bool
    var pasteboard = NSPasteboard.general
    private static let draftKey = "vfxEditor.draft"

    @Published private(set) var catalog: VFXCatalog
    @Published private(set) var saved: VFXCatalog
    @Published var selectedEffect: String
    /// The selected emitters, blocks and nodes (their ids); the inspector shows `focus`.
    @Published var selection: Set<String> = []
    @Published var focus: String?
    /// The canvas's view: where the graph's origin is in the canvas (points), and its scale.
    @Published var pan = CGPoint(x: 360, y: 40)
    @Published var zoom: CGFloat = 0.9
    /// The node search (Tab): open, where it adds (the graph's coordinates), and for which context (nil: a node).
    @Published var search: Search?
    @Published private(set) var status: VFXStatus?
    @Published private(set) var scene: SceneSettings
    @Published private(set) var message: String?
    /// The canvas's size and the pointer's place on it (canvas points): where Tab adds, what Frame All fits.
    var canvasSize = CGSize(width: 800, height: 600)
    /// The canvas's top left in the window (top-down points): the window's scrolls over it pan it.
    var canvasOrigin = CGPoint(x: 0, y: 33)
    var hover = CGPoint(x: 200, y: 200)
    /// Makes the canvas take the keys (Delete, Tab, Cmd-C) from a text field that had them (the panel's).
    var focusCanvas: (() -> Void)?

    struct Search: Equatable {
        var at: SIMD2<Float>
        var context: (emitter: String, context: VFXContext)?
        static func == (a: Search, b: Search) -> Bool {
            a.at == b.at && a.context?.emitter == b.context?.emitter && a.context?.context == b.context?.context
        }
    }

    private var dragging = false
    private var dragStart: VFXCatalog?
    private var liveSent = 0.0
    private var pendingLive: DispatchWorkItem?
    private var draftSave: DispatchWorkItem?

    init(controller: VFXEditorHost, saved: VFXCatalog = VFXCatalog.launch, folder: URL? = VFXStore.folder, draft: Bool = true) {
        self.controller = controller
        self.saved = saved
        self.folder = folder
        keepsDraft = draft
        undo.groupsByEvent = false
        catalog = (draft ? VFXEditorModel.loadDraft() : nil) ?? saved
        scene = controller.settings.scene
        let stage = controller.settings.scene.stage.effects.first ?? "fireworks"
        selectedEffect = stage
        if effectNames.firstIndex(of: stage) == nil { selectedEffect = "fireworks" }
        controller.observeSettings { [weak self] s in self?.received(s) }
        controller.observeTick { [weak self, unowned controller] in
            guard let self, controller.effectsStatus != self.status else { return }
            self.status = controller.effectsStatus
        }
        if catalog != saved { push(final: true) }
    }

    // MARK: - What is edited

    /// The effects there are: the built-in ones, then the catalog's others.
    var effectNames: [String] {
        VFXLibrary.names + catalog.effects.keys.filter { !VFXLibrary.names.contains($0) }.sorted()
    }
    func isBuiltIn(_ name: String) -> Bool { VFXLibrary.names.contains(name) }
    var isDirty: Bool { catalog != saved }
    func isDirty(_ name: String) -> Bool { catalog.effects[name] != saved.effects[name] }
    /// It differs from the built-in one of its name (an edit or a saved file).
    func isEdited(_ name: String) -> Bool { catalog.effects[name] != nil && isBuiltIn(name) }

    /// The shown effect: the catalog's, else the built-in one. Setting it is an edit.
    var effect: VFXEffect {
        get { catalog.effects[selectedEffect] ?? VFXLibrary.named(selectedEffect) ?? VFXEffect(selectedEffect) }
        set { edit { $0 = newValue } }
    }

    /// An edit of the shown effect (one undo step; while dragging, part of the drag's).
    func edit(_ change: (inout VFXEffect) -> Void) {
        var fx = effect
        change(&fx)
        var c = catalog
        c.effects[selectedEffect] = fx
        commit(c)
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

    private func commit(_ c: VFXCatalog) {
        guard c != catalog else { return }
        if !dragging { registerUndo(catalog) }
        catalog = c
        if dragging { pushLive() } else { push(final: true) }
    }

    private func registerUndo(_ old: VFXCatalog) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.restore(old) }
        undo.endUndoGrouping()
    }

    private func restore(_ old: VFXCatalog) {
        let now = catalog
        undo.registerUndo(withTarget: self) { m in m.restore(now) }
        catalog = old
        push(final: true)
        if !effectNames.contains(selectedEffect) { select(effectNames[0]) }   // the stage too, if it showed it
        prune()
    }

    // MARK: - To the renderer

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
        let key = catalog == VFXCatalog.launch ? "" : VFXCatalog.register(catalog)
        keyMade = (catalog, key)
        return key
    }
    private var keyMade: (catalog: VFXCatalog, key: String)?

    private func push(final: Bool) {
        if final { pendingLive?.cancel(); pendingLive = nil; saveDraft() }
        let key = self.key
        guard controller.settings.scene.effects != key else { return }
        controller.update { $0.scene.effects = key }
    }

    private func received(_ s: RenderSettings) {
        if s.scene != scene { scene = s.scene }
        if !dragging, s.scene.effects != key { push(final: true) }   // a scene loaded with the saved ones
    }

    // MARK: - The preview

    /// The shown effect runs in the scene (its emitters are among its particles').
    var inScene: Bool { status?.emitters.contains { $0.effect == selectedEffect } == true }
    var onStage: Bool { scene.kind == .vfxStage }

    /// To the VFX stage, showing the selected effect (alone).
    func showOnStage() {
        let name = selectedEffect, key = self.key, defaults = controller.defaultSettings
        controller.update { s in
            s.scene.stage.effects = [name]
            s.scene.effects = key
            guard s.scene.kind != .vfxStage else { return }
            s.scene.kind = .vfxStage
            s.scene.extraModels = []
            s.applySceneDefaults(from: defaults)
        }
    }

    /// Shows `name`: on the stage too, if it is shown there.
    func select(_ name: String) {
        guard name != selectedEffect else { return }
        selectedEffect = name
        selection = []
        focus = nil
        search = nil
        frameAll(in: canvasSize)
        if onStage, scene.stage.effects != [name] { showOnStage() }
    }

    // MARK: - Effects

    /// A new effect: `base`'s copy (or a small spray of sparks), under a name of its own.
    func newEffect(from base: VFXEffect? = nil) {
        var fx = base ?? VFXEditorModel.template
        fx.name = uniqueName(base.map { "\($0.name) copy" } ?? "effect")
        var c = catalog
        c.effects[fx.name] = fx
        commit(c)
        select(fx.name)
    }

    func duplicate() { newEffect(from: effect) }

    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while effectNames.contains(name) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// Renames a custom effect (a built-in one keeps its name: scenes place it by it).
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !isBuiltIn(selectedEffect), !trimmed.isEmpty, trimmed != selectedEffect, !effectNames.contains(trimmed) else { return }
        var fx = effect
        let old = selectedEffect
        fx.name = trimmed
        var c = catalog
        c.effects[old] = nil
        c.effects[trimmed] = fx
        selectedEffect = trimmed
        commit(c)
        if onStage, scene.stage.effects.contains(old) { showOnStage() }
    }

    /// Removes a custom effect, or a built-in one's edits.
    func deleteEffect() {
        var c = catalog
        c.effects[selectedEffect] = nil
        let custom = !isBuiltIn(selectedEffect)
        commit(c)
        if custom { select(effectNames[0]) }
        prune()
    }

    /// The selected built-in effect as it is built in.
    func resetToBuiltIn() {
        guard isBuiltIn(selectedEffect) else { return }
        deleteEffect()
    }

    /// A spray of sparks: what a new effect starts from.
    static var template: VFXEffect {
        VFXEffect("effect", origin: [0, 0.1, 0], emitters: [
            VFXEmitter("sparks", capacity: 400,
                       spawn: [.rate(60)],
                       initialize: [.shape("disc", at: [0, 0.1, 0], radius: 0.1), .velocity(speed: 2...4, spread: 0.4), .lifetime(1...1.6)],
                       update: [.gravity(1), .drag(0.3)],
                       output: [.billboard(), .size(0.03, 0.01), .color(VFXGradient([1, 0.8, 0.4, 1], [1, 0.5, 0.2, 1], [1, 0.2, 0.1, 0]), emission: 8),
                                .flipbook(.spark), .orient("velocity", stretch: 0.03), .lighting(soft: 0.02, shadows: false)]),
        ])
    }

    // MARK: - Saving

    /// Writes every effect that differs from what is saved (a built-in one as built in: its file goes), and removes the
    /// files of deleted ones.
    func save() {
        guard let folder else {
            message = "METALRENDERER_EFFECTS=builtin: nothing is saved"
            return
        }
        do {
            for (name, fx) in catalog.effects where fx != saved.effects[name] {
                if let builtIn = VFXLibrary.named(name), builtIn == fx { try VFXStore.remove(name, in: folder) } else { try VFXStore.save(fx, in: folder) }
            }
            for name in saved.effects.keys where catalog.effects[name] == nil { try VFXStore.remove(name, in: folder) }
            saved = catalog
            if keepsDraft { VFXEditorModel.saveDraft(nil) }
            message = "Saved to \(folder.path)"
            push(final: true)
        } catch {
            message = "Not saved: \(error.localizedDescription)"
        }
    }

    /// The shown effect as it is saved (or built in).
    func revert() {
        var c = catalog
        c.effects[selectedEffect] = saved.effects[selectedEffect]
        commit(c)
        if !effectNames.contains(selectedEffect) { select(effectNames[0]) }
        prune()
    }

    func revertAll() {
        commit(saved)
        if !effectNames.contains(selectedEffect) { select(effectNames[0]) }
        prune()
    }

    /// The shown effect as Swift (VFXBuilder.swift), on the clipboard.
    func copyAsSwift() {
        pasteboard.clearContents()
        pasteboard.setString(effect.swiftSource, forType: .string)
        message = "\(selectedEffect) copied as Swift"
    }

    func clearMessage() { message = nil }

    private func saveDraft() {
        guard keepsDraft else { return }
        draftSave?.cancel()
        let draft = catalog == saved ? nil : catalog
        let work = DispatchWorkItem { VFXEditorModel.saveDraft(draft) }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func saveDraft(_ c: VFXCatalog?) {
        guard let c, let data = try? JSONEncoder().encode(c.effects.keys.sorted().map { c.effects[$0]! }) else {
            UserDefaults.standard.removeObject(forKey: draftKey)
            return
        }
        UserDefaults.standard.set(data, forKey: draftKey)
    }

    private static func loadDraft() -> VFXCatalog? {
        guard let data = UserDefaults.standard.data(forKey: draftKey),
              let effects = try? JSONDecoder().decode([VFXEffect].self, from: data) else { return nil }
        return VFXCatalog(effects: Dictionary(effects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    // MARK: - The graph

    /// The selection without what is gone.
    private func prune() {
        let ids = effect.allIDs
        selection = selection.filter { ids.contains($0) }
        if let f = focus, !ids.contains(f) { focus = nil }
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

    /// Adds an operator at `at` (the graph's coordinates), selected.
    @discardableResult
    func addNode(_ kind: VFXOpKind, at: SIMD2<Float>) -> String {
        var id = ""
        edit { fx in
            fx = VFXLayout(fx).arranged
            id = VFXEffect.unique(kind.rawValue, fx.allIDs)
            fx.nodes.append(VFXNode(kind, id: id, at: at))
        }
        selection = [id]
        focus = id
        search = nil
        return id
    }

    /// Adds a block to an emitter's context (at its end, or at `index`), selected.
    @discardableResult
    func addBlock(_ kind: VFXBlockKind, to emitter: String, _ context: VFXContext, at index: Int? = nil) -> String? {
        guard kind.spec.contexts.contains(context), let e = effect.emitters.firstIndex(where: { $0.id == emitter }) else { return nil }
        var id = ""
        edit { fx in
            id = VFXEffect.unique("\(emitter).\(kind.rawValue)", fx.allIDs)
            var block = VFXBlock(kind, id: id)
            if kind == .event, let parent = fx.emitters.first(where: { $0.id != emitter }) { block.params["parent"] = .choice(parent.id) }
            let list = fx.emitters[e][context]
            fx.emitters[e][context].insert(block, at: min(index ?? list.count, list.count))
        }
        selection = [id]
        focus = id
        search = nil
        return id
    }

    /// Adds an emitter (a template's copy) at `at`.
    @discardableResult
    func addEmitter(at: SIMD2<Float>? = nil) -> String {
        var id = ""
        edit { fx in
            fx = VFXLayout(fx).arranged
            var e = VFXEditorModel.template.emitters[0]
            e.name = VFXEffect.unique("emitter", Set(fx.emitters.map(\.name)))
            id = VFXEffect.unique(VFXEffect.slug(e.name), fx.allIDs)
            e.id = id
            for c in VFXContext.allCases { for k in e[c].indices { e[c][k].id = "" } }
            e.canvas = at ?? SIMD2((fx.emitters.map(\.canvas.x).max() ?? -VFXLayout.emitterSpacing) + VFXLayout.emitterSpacing, 0)
            fx.emitters.append(e)
            fx.normalizeIDs()
        }
        selection = [id]
        focus = id
        return id
    }

    /// Removes the selected nodes, blocks and emitters, and their wires.
    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let gone = selection
        edit { fx in fx.remove(gone) }
        clearSelection()
    }

    /// Moves the selected nodes and emitters by `delta` (the graph's units): a drag, one undo step from beginDrag.
    func moveSelection(by delta: SIMD2<Float>, ids: Set<String>? = nil) {
        let moving = ids ?? selection
        edit { fx in
            fx = VFXLayout(fx).arranged
            for i in fx.nodes.indices where moving.contains(fx.nodes[i].id) { fx.nodes[i].canvas += delta }
            for i in fx.emitters.indices where moving.contains(fx.emitters[i].id) { fx.emitters[i].canvas += delta }
        }
    }

    /// Moves a block up or down in its context.
    func moveBlock(_ id: String, by offset: Int) {
        edit { fx in
            for e in fx.emitters.indices {
                for c in VFXContext.allCases {
                    guard let k = fx.emitters[e][c].firstIndex(where: { $0.id == id }) else { continue }
                    let to = k + offset
                    guard fx.emitters[e][c].indices.contains(to) else { return }
                    fx.emitters[e][c].swapAt(k, to)
                    return
                }
            }
        }
    }

    /// Wires `from`'s output into `to`'s input (replacing what was wired there), if that can be: the pin takes a
    /// wire, and the wire makes no loop.
    @discardableResult
    func link(_ from: String, _ output: String, to: String, _ input: String) -> Bool {
        guard effect.canLink(from, output, to: to, input) else { return false }
        edit { fx in
            fx.links.removeAll { $0.to == to && $0.input == input }
            fx.links.append(VFXLink(from, output, to: to, input))
        }
        return true
    }

    func unlink(_ to: String, _ input: String) {
        edit { fx in fx.links.removeAll { $0.to == to && $0.input == input } }
    }

    /// A block's or a node's parameter.
    func param(_ owner: String, _ name: String) -> VFXParam? {
        if let n = effect.node(owner) { return n.param(name) }
        return effect.block(owner)?.block.param(name)
    }

    func setParam(_ owner: String, _ name: String, _ value: VFXParam) {
        edit { fx in fx.setParam(owner, name, value) }
    }

    // MARK: - Copy and paste (nodes, and the wires between them)

    private struct Clip: Codable {
        var vfxNodes: [VFXNode]
        var links: [VFXLink]
    }

    func copySelection() {
        let fx = VFXLayout(effect).arranged
        let nodes = fx.nodes.filter { selection.contains($0.id) }
        guard !nodes.isEmpty else { return }
        let ids = Set(nodes.map(\.id))
        let clip = Clip(vfxNodes: nodes, links: fx.links.filter { ids.contains($0.from) && ids.contains($0.to) })
        guard let data = try? JSONEncoder().encode(clip), let text = String(data: data, encoding: .utf8) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var canPaste: Bool { clipboard() != nil }

    private func clipboard() -> Clip? {
        guard let text = pasteboard.string(forType: .string), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Clip.self, from: data)
    }

    /// The clipboard's nodes, 30 units down and right of where they were, under ids of their own; selected.
    func paste() {
        guard let clip = clipboard() else { return }
        var pasted: Set<String> = []
        edit { fx in
            fx = VFXLayout(fx).arranged
            var used = fx.allIDs, renamed: [String: String] = [:]
            for var n in clip.vfxNodes {
                let id = VFXEffect.unique(n.kind.rawValue, used)
                used.insert(id)
                renamed[n.id] = id
                n.id = id
                n.canvas += [30, 30]
                fx.nodes.append(n)
                pasted.insert(id)
            }
            for l in clip.links { fx.links.append(VFXLink(renamed[l.from]!, l.output, to: renamed[l.to]!, l.input)) }
        }
        selection = pasted
        focus = pasted.count == 1 ? pasted.first : nil
    }

    /// Tab: the search, adding where the pointer is (to the context under it, if it is over an emitter's).
    func openSearch() {
        let g = graphPoint(hover)
        let layout = VFXLayout(effect)
        let p = CGPoint(x: CGFloat(g.x), y: CGFloat(g.y))
        var target: (emitter: String, context: VFXContext)?
        for (id, rect) in layout.emitters where rect.contains(p) {
            // The context whose header is above the pointer, nearest.
            let above = (layout.contexts[id] ?? [:]).filter { $0.value.minY <= p.y }
            if let c = above.max(by: { $0.value.minY < $1.value.minY })?.key { target = (id, c) }
        }
        search = Search(at: g, context: target)
    }

    // MARK: - The canvas's view

    /// The graph's point at canvas point `p`, and back.
    func graphPoint(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float((p.x - pan.x) / zoom), Float((p.y - pan.y) / zoom)) }
    func viewPoint(_ g: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(g.x) * zoom + pan.x, y: CGFloat(g.y) * zoom + pan.y) }

    /// Zooms by `factor` about canvas point `about`.
    func zoom(by factor: CGFloat, about: CGPoint) {
        let g = graphPoint(about)
        zoom = min(max(zoom * factor, 0.25), 2)
        pan = CGPoint(x: about.x - CGFloat(g.x) * zoom, y: about.y - CGFloat(g.y) * zoom)
    }

    /// The whole graph in a canvas of `size`.
    func frameAll(in size: CGSize) {
        let bounds = VFXLayout(effect).bounds.insetBy(dx: -40, dy: -40)
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return }
        zoom = min(max(min(size.width / bounds.width, size.height / bounds.height), 0.25), 1.2)
        pan = CGPoint(x: (size.width - bounds.width * zoom) / 2 - bounds.minX * zoom,
                      y: (size.height - bounds.height * zoom) / 2 - bounds.minY * zoom)
    }
}

// MARK: - The graph's edits and checks

extension VFXEffect {
    /// Every emitter's, block's and node's id.
    var allIDs: Set<String> {
        var ids = Set(nodes.map(\.id))
        for e in emitters {
            ids.insert(e.id)
            for c in VFXContext.allCases { for b in e[c] { ids.insert(b.id) } }
        }
        return ids
    }

    /// The emitters, blocks and nodes of `ids` gone, and the wires to and from them.
    mutating func remove(_ ids: Set<String>) {
        var gone = ids
        for e in emitters where ids.contains(e.id) {
            for c in VFXContext.allCases { for b in e[c] { gone.insert(b.id) } }
        }
        emitters.removeAll { ids.contains($0.id) }
        for i in emitters.indices { for c in VFXContext.allCases { emitters[i][c].removeAll { gone.contains($0.id) } } }
        nodes.removeAll { gone.contains($0.id) }
        links.removeAll { gone.contains($0.from) || gone.contains($0.to) }
    }

    mutating func setParam(_ owner: String, _ name: String, _ value: VFXParam) {
        if let k = nodes.firstIndex(where: { $0.id == owner }) {
            nodes[k].params[name] = value
            return
        }
        for e in emitters.indices {
            for c in VFXContext.allCases {
                if let k = emitters[e][c].firstIndex(where: { $0.id == owner }) { emitters[e][c][k].params[name] = value; return }
            }
        }
    }

    mutating func setEnabled(_ block: String, _ on: Bool) {
        for e in emitters.indices {
            for c in VFXContext.allCases {
                if let k = emitters[e][c].firstIndex(where: { $0.id == block }) { emitters[e][c][k].enabled = on; return }
            }
        }
    }

    /// The pin spec of input `input` of node or block `id`.
    func pin(_ id: String, _ input: String) -> VFXPinSpec? {
        if let n = node(id) { return n.kind.spec.pin(input) }
        return block(id)?.block.kind.spec.pin(input)
    }

    /// What node `id`'s output `output` carries: its kind's, or its generic inputs' widest (what is wired into them,
    /// else their values').
    func outputType(_ id: String, _ output: String = "out", seen: Set<String> = []) -> VFXType {
        guard let n = node(id), !seen.contains(id) else { return .float }
        let spec = n.kind.spec
        if let t = spec.outputs.first(where: { $0.name == output })?.type { return t }
        var t = VFXType.bool
        for p in spec.inputs where p.generic { t = VFXType.wider(t, inputType(id, p.name, seen: seen.union([id]))) }
        return t == .bool ? .float : t
    }

    /// What input `input` of node or block `id` gets: what is wired into it, else its value's type.
    func inputType(_ id: String, _ input: String, seen: Set<String> = []) -> VFXType {
        if let l = link(into: id, input) { return outputType(l.from, l.output, seen: seen) }
        guard let p = pin(id, input) else { return .float }
        let value = node(id)?.param(input) ?? block(id)?.block.param(input) ?? p.value
        switch value {
        case .vec3: return .vec3
        case .color, .gradient: return .color
        case .bool: return .bool
        default: return p.generic ? .float : (p.wire ?? .float)
        }
    }

    /// The pin's type as drawn: a generic one's is what it gets.
    func pinType(_ id: String, _ input: String) -> VFXType {
        guard let p = pin(id, input) else { return .float }
        return p.generic ? inputType(id, input) : (p.wire ?? inputType(id, input))
    }

    /// Whether node `from`'s output can be wired into `to`'s input: the input takes a wire, the output is the node's,
    /// and `to` isn't upstream of `from` (no loop).
    func canLink(_ from: String, _ output: String, to: String, _ input: String) -> Bool {
        guard from != to, let n = node(from), n.kind.spec.outputs.contains(where: { $0.name == output }),
              pin(to, input)?.wire != nil else { return false }
        guard node(to) != nil else { return true }   // a block: nothing comes out of it
        return !upstream(of: from).contains(to)
    }

    /// The nodes whose outputs reach node `id` (through any number of wires).
    func upstream(of id: String) -> Set<String> {
        var found = Set<String>(), stack = [id]
        while let n = stack.popLast() {
            for l in links where l.to == n && !found.contains(l.from) {
                found.insert(l.from)
                stack.append(l.from)
            }
        }
        return found
    }
}
