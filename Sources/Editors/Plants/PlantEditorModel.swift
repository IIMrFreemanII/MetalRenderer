import AppKit
import Buildings
import Characters
import Combine
import Effects
import EngineCore
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants
import QuartzCore

/// What the plant editor needs of the renderer (RendererController; a stand-in in the tests).
protocol PlantEditorHost: AnyObject {
    var settings: RenderSettings { get }
    var defaultSettings: RenderSettings { get }
    var plantStats: PlantStats? { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void)
    func observeTick(_ observer: @escaping () -> Void)
    func frameWorkshop()
    /// The Manual Edit tool in the view.
    func setPlantTool(_ tool: PlantToolOverlay?)
    var onPlantTool: ((PlantToolEvent) -> Void)? { get set }
}

extension RendererController: PlantEditorHost {
    var plantStats: PlantStats? { status?.plantStats }
}

/// The plant editor's state, on the main thread: the species being edited (a whole catalog, PlantCatalog), the saved
/// one, what is selected, and the workshop's settings as the renderer reports them.
///
/// An edit goes to the renderer as the catalog's registry key (`SceneSettings.plantCatalog`): while a slider is
/// dragged only the workshop follows it, the graph run stage by stage (it is made again in about 20 ms); when the slider
/// is let go, or on any other edit, the forest, the valley and the world follow too, and the species' Swift compiles
/// behind them. Unsaved edits are a draft (PlantStore) until saved or reverted. One undo step per edit; a drag is one edit.
final class PlantEditorModel: ObservableObject {
    let controller: PlantEditorHost
    let undo = UndoManager()
    /// Where Save writes (nil: nowhere), and whether unsaved edits are kept as a draft.
    private let folder: URL?
    private let keepsDraft: Bool
    /// Where Copy and Paste go (the tests' own one, not the user's).
    var pasteboard = NSPasteboard.general

    // The canvas (GraphCanvasModel, PlantEditorModel+Graph.swift).
    @Published var pan = CGPoint(x: 60, y: 60)
    @Published var zoom: CGFloat = 1
    /// The canvas's size. A view still as it was framed is framed again in the new one (the window settling as it opens, a
    /// resize); one the user has panned or zoomed stays.
    var canvasSize = CGSize(width: 800, height: 600) {
        didSet {
            if canvasSize != oldValue, let framed, framed.pan == pan, framed.zoom == zoom { frameAll(in: canvasSize) }
        }
    }
    var framed: (pan: CGPoint, zoom: CGFloat)?
    static let minimapWidth: CGFloat = 192      // (GraphCanvas's, with its margin)
    var canvasOrigin = CGPoint.zero
    var hover = CGPoint(x: 200, y: 200)
    var focusCanvas: (() -> Void)?
    @Published var selection: Set<String> = []
    @Published var focus: String? { didSet { if focus != oldValue { showStage() } } }
    /// The node the workshop stays on whatever is selected (PlantEditorModel+Graph.swift).
    @Published var pinned: Int32? { didSet { if pinned != oldValue { showStage() } } }
    /// What the nodes show of themselves.
    let thumbnails = PlantThumbnails()
    var thumbnailsWanted = false
    /// The stage whose scene is to be framed when it's in (a twig's is far smaller than the plant's).
    var frameStage: Int?
    @Published var searchAt: SIMD2<Float>?
    /// How the selected species' file stands: PlantCompileStatus.
    @Published var compile = PlantCompileStatus.idle
    /// Its file, while it is shown.
    @Published var showsSwift = false
    var compileSoon: DispatchWorkItem?
    /// The built-in species' files, read as graphs.
    var builtInGraphs: [String: PlantGraph] = [:]

    // A Manual Edit node's tool (PlantEditorModel+ManualEdit.swift).
    @Published var editNode: Int32?
    @Published var editTool: PlantEditTool?
    @Published var editSpread = PlantEditing.Spread()
    /// What's picked, and how much each point takes of its move.
    @Published var editPick: PlantEditing.Pick?
    var editWeights: [Float] = []
    var hoverPick: PlantEditing.Pick?
    var editing: PlantEditing?
    var editUpstream: [PlantNode] = []
    var editingView: PlantSceneSettings.View?

    @Published private(set) var catalog: PlantCatalog {
        didSet {
            refreshThumbnails()
            catalogChangedUnderTool()
        }
    }
    @Published private(set) var saved: PlantCatalog
    @Published var selected: String { didSet { if selected != oldValue { refreshThumbnails() } } }
    @Published private(set) var stats: PlantStats?
    /// The renderer's: the scene, the workshop's settings, the wind.
    @Published private(set) var scene: SceneSettings
    @Published private(set) var foliage: FoliageSettings
    /// The workshop's lights' turn (degrees) and whether they turn by themselves (RenderSettings.previewLightYaw, previewSpin).
    @Published private(set) var lightYaw: Float
    @Published private(set) var lightSpin: Bool
    /// The last Mutate's variations (the workshop shows them beside the species).
    @Published private(set) var mutants: [Foliage.SpeciesDef] = []
    @Published private(set) var message: String?

    private var dragging = false
    private var dragStart: PlantCatalog?
    private var liveSent = 0.0
    private var pendingLive: DispatchWorkItem?
    private var draftSave: DispatchWorkItem?
    private var reloads: NSObjectProtocol?

    package init(controller: PlantEditorHost, saved: PlantCatalog = PlantCatalog.launch, folder: URL? = PlantStore.folder, draft: Bool = true) {
        self.controller = controller
        self.saved = saved
        self.folder = folder
        keepsDraft = draft
        undo.groupsByEvent = false   // an edit is a step, whatever the run loop
        catalog = (draft ? PlantStore.loadDraft() : nil).map { PlantCatalog.builtIn.merging($0.species) } ?? saved
        scene = controller.settings.scene
        foliage = controller.settings.foliage
        lightYaw = controller.settings.previewLightYaw
        lightSpin = controller.settings.previewSpin
        selected = controller.settings.scene.plants.species
        if catalog.species(id: selected) == nil { selected = catalog.species[0].id }
        controller.observeSettings { [weak self] s in self?.received(s) }
        controller.observeTick { [weak self, unowned controller] in self?.tick(controller.plantStats) }
        controller.onPlantTool = { [weak self] event in self?.plantToolEvent(event) }
        if catalog != saved { push(final: true) }
        compileLater()
        reloads = NotificationCenter.default.addObserver(forName: DevReload.plantsReloaded, object: nil, queue: .main) { [weak self] _ in
            guard let self, PlantStore.isFolder(self.folder) else { return }
            self.savedChanged(PlantCatalog.launch)
        }
    }

    deinit { reloads.map(NotificationCenter.default.removeObserver) }

    private func tick(_ now: PlantStats?) {
        if now != stats { stats = now }
        if let wanted = frameStage, now?.stage == wanted {
            frameStage = nil
            frame()
        }
    }

    // MARK: - What is edited

    var species: Foliage.Species { catalog.species(id: selected) ?? .oak }
    var isBuiltIn: Bool { species.rawValue < Foliage.Species.allCases.count }
    var isDirty: Bool { catalog != saved }
    func isDirty(_ id: String) -> Bool {
        catalog.species.first { $0.id == id } != saved.species.first { $0.id == id }
    }
    /// The saved definition of the species (nil: a new one, never saved).
    var savedDef: Foliage.SpeciesDef? { saved.species.first { $0.id == selected } }

    /// The selected species' definition: setting it is an edit.
    var def: Foliage.SpeciesDef {
        get { catalog[species] }
        set {
            var d = newValue
            // An edit of the recipe (Mutate, a slider of the species) goes to the graph that holds it.
            if let graph = d.graph {
                var said = d
                graph.project(into: &said)
                if !said.sameRecipe(as: d) { d.setGraph(graph.applying(d)) }
            }
            var c = catalog
            c.species[species.rawValue] = d
            commit(c)
        }
    }

    /// A slider is being dragged: one undo step for all of it, and only the workshop follows until it is let go.
    func beginDrag() {
        guard !dragging else { return }
        dragging = true
        dragStart = catalog
    }

    /// The drag's one undo step, if it changed anything.
    func endDrag() {
        guard dragging else { return }
        dragging = false
        if let start = dragStart, start != catalog { registerUndo(start) }
        dragStart = nil
        push(final: true)
        compileLater()
    }

    private func commit(_ c: PlantCatalog, undoable: Bool = true) {
        guard c != catalog else { return }
        message = nil       // (what the last Save said was of the plant before this)
        if !dragging && undoable { registerUndo(catalog) }
        catalog = c
        if dragging { pushLive(); compile = .waiting } else { push(final: true); compileLater() }
        showStage()
    }

    private func registerUndo(_ old: PlantCatalog) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.restore(old) }
        undo.endUndoGrouping()
    }

    private func restore(_ old: PlantCatalog) {
        let now = catalog
        undo.registerUndo(withTarget: self) { m in m.restore(now) }
        catalog = old
        if catalog.species(id: selected) == nil { select(catalog.species[0].id) }
        push(final: true)
        compileLater()
        showStage()
    }

    // MARK: - To the renderer

    /// At most 30 a second while dragging, the last one always.
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

    /// The registry key of the edited catalog ("" when it is what is saved).
    private var key: String { catalog.fingerprint == PlantCatalog.launch.fingerprint ? "" : PlantCatalog.register(catalog) }

    /// Tells the renderer. `final`: every scene with plants; otherwise only the workshop (scenes without plants are
    /// told when they become a scene with them: `received`).
    func push(final: Bool) {
        if final { pendingLive?.cancel(); pendingLive = nil; saveDraft() }
        let key = self.key, kind = controller.settings.scene.kind
        guard kind == .plants || (final && kind.hasPlants), controller.settings.scene.plantCatalog != key else { return }
        controller.update { $0.scene.plantCatalog = key }
    }

    private func saveDraft() {
        guard keepsDraft else { return }
        draftSave?.cancel()
        let draft = catalog == saved ? nil : catalog
        let work = DispatchWorkItem { PlantStore.saveDraft(draft) }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func received(_ s: RenderSettings) {
        let plantsBefore = scene.plants
        if s.scene != scene { scene = s.scene }
        if s.scene.kind != .plants { stopEditing() }
        if plantsBefore != s.scene.plants { refreshThumbnails() }
        if s.foliage != foliage { foliage = s.foliage }
        if s.previewLightYaw != lightYaw { lightYaw = s.previewLightYaw }
        if s.previewSpin != lightSpin { lightSpin = s.previewSpin }
        // A scene with plants now: it is to have the edited ones.
        if s.scene.kind.hasPlants && !dragging, s.scene.plantCatalog != key { push(final: true) }
        showStage()
    }

    // MARK: - The workshop

    var inWorkshop: Bool { scene.kind == .plants }

    func workshop(_ change: @escaping (inout PlantSceneSettings) -> Void) {
        controller.update { change(&$0.scene.plants) }
    }

    func select(_ id: String) {
        stopEditing()
        selected = id
        selection = []
        pinned = nil
        focus = nil
        compileLater()
        if inWorkshop, scene.plants.species != id {
            workshop { $0.species = id; $0.layout = $0.layout == .mutate ? .single : $0.layout; $0.mutants = "" }
        }
    }

    /// To the workshop, showing the selected species (a scene of its own: its sky and wind).
    func goToWorkshop() { go(to: .plants) }
    /// The forest, if this build has one.
    var forest: SceneKind? { SceneRegistry.kind(for: .forest) }
    func goToForest() { forest.map { go(to: $0) } }

    private func go(to kind: SceneKind) {
        let id = selected, key = self.key, defaults = controller.defaultSettings, stage = wantedStage
        controller.update { s in
            s.scene.plants.species = id
            s.scene.plantCatalog = key
            s.scene.plants.stage = stage
            guard s.scene.kind != kind else { return }
            s.scene.kind = kind
            s.scene.extraModels = []
            s.applySceneDefaults(from: defaults)
        }
    }

    func frame() { controller.frameWorkshop() }

    func randomizeSeed() { workshop { $0.seed = Int.random(in: SceneSettings.seedRange) } }

    func setWind(_ change: @escaping (inout FoliageSettings) -> Void) { controller.update { change(&$0.foliage) } }

    /// Turns the workshop's lights about the plant, live.
    func setLights(yaw: Float? = nil, spin: Bool? = nil) {
        controller.update { s in
            if let yaw { s.previewLightYaw = yaw }
            if let spin { s.previewSpin = spin }
        }
    }

    /// Holding Compare (or C in the workshop): the saved species in place of the edited one.
    func compare(_ on: Bool) {
        guard let savedDef = savedDef ?? (isBuiltIn ? PlantCatalog.builtIn[species] : nil) else { return }
        let key = on ? PlantCatalog.register(PlantCatalog(species: [savedDef])) : ""
        workshop { $0.compare = key }
    }

    // MARK: - Mutate

    func mutate() {
        mutants = PlantMutate.mutants(of: def, seed: UInt64.random(in: 1...UInt64.max))
        let key = PlantCatalog.register(PlantCatalog(species: mutants))
        if !inWorkshop { goToWorkshop() }
        workshop { $0.mutants = key; $0.layout = .mutate }
    }

    /// The variation `k` (0-based) becomes the species' shape.
    func pick(_ k: Int) {
        guard mutants.indices.contains(k) else { return }
        def = PlantMutate.pick(mutants[k], into: def)
        mutants = []
        workshop { $0.mutants = ""; $0.layout = .single }
    }

    // MARK: - Species

    /// A new species, a copy of the selected one: its own id, seeds and patches.
    func newSpecies(from base: Foliage.SpeciesDef? = nil) {
        var d = base ?? def
        let baseID = d.id
        var id = "\(baseID.split(separator: "-").first ?? "plant")-copy", n = 2
        while catalog.species(id: id) != nil { id = "\(baseID)-copy\(n)"; n += 1 }
        d.id = id
        d.name = d.name + " copy"
        d.basedOn = baseID
        d.seedIndex = max(100, (catalog.species.map(\.seedIndex).max() ?? 99) + 1)
        d.habitat.order = 100 + catalog.count
        var hash = UInt64(14_695_981_039_346_656_037)
        for b in id.utf8 { hash = (hash ^ UInt64(b)) &* 1_099_511_628_211 }
        d.habitat.cover?.salt = UInt32(truncatingIfNeeded: hash >> 7) % 997 + 1000
        d.habitat.cover?.what = hash
        var c = catalog
        c.species.append(d)
        commit(c)
        select(id)
    }

    /// Renames a custom species: its name, and its id (its file's name) from it.
    func rename(_ name: String) {
        var d = def
        d.name = name
        if !isBuiltIn {
            var id = PlantEditorModel.slug(name), n = 2
            if id.isEmpty { id = d.id }
            let base = id
            while id != d.id, catalog.species(id: id) != nil { id = "\(base)-\(n)"; n += 1 }
            d.id = id
        }
        let old = selected
        def = d
        selected = d.id
        if inWorkshop, scene.plants.species == old { workshop { $0.species = d.id } }
    }

    static func slug(_ name: String) -> String {
        let allowed = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }

    func deleteSpecies() {
        guard !isBuiltIn else { return }
        var c = catalog
        c.species.remove(at: species.rawValue)
        let first = c.species[0].id
        commit(c)
        select(first)
    }

    /// The selected built-in species as it is built in (an edit: Save then removes its file).
    func resetToBuiltIn() {
        guard isBuiltIn else { return }
        def = PlantCatalog.builtIn[species]
    }

    // MARK: - Saving

    /// Writes every species that differs from what is saved (a built-in one that is as built in: its file goes),
    /// and removes the files of deleted ones.
    func save() {
        guard let folder else {
            message = "METALRENDERER_PLANTS=builtin: nothing is saved"
            return
        }
        // (A graph with a pin not wired has no file that compiles: it stays a draft until it's whole.)
        for d in catalog.species where d != saved.species.first(where: { $0.id == d.id }) {
            if let why = d.graph?.wiring {
                message = "Not saved: \(d.name): \(why)"
                return
            }
        }
        do {
            for (i, d) in catalog.species.enumerated() where d != saved.species.first(where: { $0.id == d.id }) {
                if i < Foliage.Species.allCases.count && d == PlantCatalog.builtIn.species[i] {
                    try PlantStore.remove(d.id, in: folder)
                } else {
                    try PlantStore.save(d, in: folder)
                }
            }
            for d in saved.species where catalog.species(id: d.id) == nil { try PlantStore.remove(d.id, in: folder) }
            saved = catalog
            if PlantStore.isFolder(folder) { PlantCatalog.setLaunch(catalog) }
            if keepsDraft { PlantStore.saveDraft(nil) }
            message = "Saved to \(folder.path)"
            push(final: true)
        } catch {
            message = "Not saved: \(error.localizedDescription)"
        }
    }

    /// The selected species as it is saved (a new one: as it was made, its base's copy is kept).
    func revert() {
        guard let savedDef else { return }
        def = savedDef
    }

    /// The files changed on disk, and `new` is what they say. A species with no unsaved edits follows; one with keeps them
    /// and says so, Save replacing the file and Revert taking it. (The editor's own save reads back as what it wrote.)
    func savedChanged(_ new: PlantCatalog) {
        func same(_ a: Foliage.SpeciesDef, _ b: Foliage.SpeciesDef) -> Bool { a == b || PlantSwift.emit(a).text == PlantSwift.emit(b).text }
        func held(_ id: String) -> Foliage.SpeciesDef? { catalog.species.first { $0.id == id } }
        var nowSaved: [Foliage.SpeciesDef] = [], edited: [Foliage.SpeciesDef] = []
        var followed: [String] = [], kept: [String] = []
        for d in new.species {
            let old = saved.species.first { $0.id == d.id }
            if let old, same(old, d) {
                nowSaved.append(old)
                if let mine = held(d.id) { edited.append(mine) }
            } else {
                nowSaved.append(d)
                if let mine = held(d.id), mine != old {
                    edited.append(mine)
                    kept.append(mine.name)
                } else {
                    edited.append(d)
                    followed.append(d.name)
                }
            }
        }
        // Only here: never saved, or edited while its file went.
        for mine in catalog.species where !new.species.contains(where: { $0.id == mine.id }) {
            guard let old = saved.species.first(where: { $0.id == mine.id }) else { edited.append(mine); continue }
            if mine != old {
                edited.append(mine)
                kept.append(mine.name)
            } else {
                followed.append(mine.name)
            }
        }
        let shown = selected
        if followed.contains(def.name) {
            selection = []
            focus = nil
        }
        saved = PlantCatalog(species: nowSaved)
        commit(PlantCatalog(species: edited), undoable: false)
        if catalog.species(id: shown) == nil { select(catalog.species[0].id) }
        if !kept.isEmpty {
            message = "\(kept.joined(separator: ", ")): the file changed on disk. Your unsaved edits stay: Save replaces it, Revert takes it"
        } else if !followed.isEmpty {
            message = "Read again from disk: \(followed.joined(separator: ", "))"
        }
    }

    /// Every unsaved edit dropped.
    func revertAll() {
        guard isDirty else { return }
        commit(saved)
        if catalog.species(id: selected) == nil { select(catalog.species[0].id) }
    }

    func clearMessage() { message = nil }
}

