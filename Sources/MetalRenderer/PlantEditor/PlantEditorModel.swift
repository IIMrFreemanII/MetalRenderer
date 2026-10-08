import AppKit
import Combine
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
}

extension RendererController: PlantEditorHost {
    var plantStats: PlantStats? { status?.plantStats }
}

/// The plant editor's state, on the main thread: the species being edited (a whole catalog, PlantCatalog), the saved
/// one, what is selected, and the workshop's settings as the renderer reports them.
///
/// An edit goes to the renderer as the catalog's registry key (`SceneSettings.plantCatalog`): while a slider is
/// dragged only the workshop follows it (it is made again in about 20 ms); when the slider is let go, or on any other
/// edit, the forest, the valley and the world follow too. Unsaved edits are a draft (PlantStore) until saved or
/// reverted. One undo step per edit; a drag is one edit.
final class PlantEditorModel: ObservableObject {
    enum Tab: String, CaseIterable { case stems = "Stems", leaves = "Leaves", boughs = "Boughs", look = "Look", habitat = "Habitat", ages = "Ages" }

    let controller: PlantEditorHost
    let undo = UndoManager()
    /// Where Save writes (nil: nowhere), and whether unsaved edits are kept as a draft.
    private let folder: URL?
    private let keepsDraft: Bool
    /// Where Copy and Paste go (the tests' own one, not the user's).
    var pasteboard = NSPasteboard.general

    @Published private(set) var catalog: PlantCatalog
    @Published private(set) var saved: PlantCatalog
    @Published var selected: String
    @Published var tab = Tab.stems
    @Published var level = 1
    @Published private(set) var stats: PlantStats?
    /// The renderer's: the scene, the workshop's settings, the wind.
    @Published private(set) var scene: SceneSettings
    @Published private(set) var foliage: FoliageSettings
    /// The last Mutate's variations (the workshop shows them beside the species).
    @Published private(set) var mutants: [Foliage.SpeciesDef] = []
    @Published private(set) var message: String?

    private var dragging = false
    private var dragStart: PlantCatalog?
    private var liveSent = 0.0
    private var pendingLive: DispatchWorkItem?
    private var draftSave: DispatchWorkItem?

    init(controller: PlantEditorHost, saved: PlantCatalog = PlantCatalog.launch, folder: URL? = PlantStore.folder, draft: Bool = true) {
        self.controller = controller
        self.saved = saved
        self.folder = folder
        keepsDraft = draft
        undo.groupsByEvent = false   // an edit is a step, whatever the run loop
        catalog = (draft ? PlantStore.loadDraft() : nil).map { PlantCatalog.builtIn.merging($0.species) } ?? saved
        scene = controller.settings.scene
        foliage = controller.settings.foliage
        selected = controller.settings.scene.plants.species
        if catalog.species(id: selected) == nil { selected = catalog.species[0].id }
        controller.observeSettings { [weak self] s in self?.received(s) }
        controller.observeTick { [weak self, unowned controller] in self?.stats = controller.plantStats }
        if catalog != saved { push(final: true) }
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
            var c = catalog
            c.species[species.rawValue] = newValue
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
    }

    private func commit(_ c: PlantCatalog, undoable: Bool = true) {
        guard c != catalog else { return }
        if !dragging && undoable { registerUndo(catalog) }
        catalog = c
        if dragging { pushLive() } else { push(final: true) }
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
    private var key: String { catalog == saved && saved == PlantCatalog.launch ? "" : PlantCatalog.register(catalog) }

    /// Tells the renderer. `final`: every scene with plants; otherwise only the workshop (scenes without plants are
    /// told when they become a scene with them: `received`).
    private func push(final: Bool) {
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
        if s.scene != scene { scene = s.scene }
        if s.foliage != foliage { foliage = s.foliage }
        // A scene with plants now: it is to have the edited ones.
        if s.scene.kind.hasPlants && !dragging, s.scene.plantCatalog != key { push(final: true) }
    }

    // MARK: - The workshop

    var inWorkshop: Bool { scene.kind == .plants }

    func workshop(_ change: @escaping (inout PlantSceneSettings) -> Void) {
        controller.update { change(&$0.scene.plants) }
    }

    func select(_ id: String) {
        selected = id
        level = min(level, max(def.recipe.levels.count - 1, 0))
        if inWorkshop, scene.plants.species != id {
            workshop { $0.species = id; $0.layout = $0.layout == .mutate ? .single : $0.layout; $0.mutants = "" }
        }
    }

    /// To the workshop, showing the selected species (a scene of its own: its sky and wind).
    func goToWorkshop() { go(to: .plants) }
    func goToForest() { go(to: .forest) }

    private func go(to kind: SceneKind) {
        let id = selected, key = self.key, defaults = controller.defaultSettings
        controller.update { s in
            s.scene.plants.species = id
            s.scene.plantCatalog = key
            guard s.scene.kind != kind else { return }
            s.scene.kind = kind
            s.scene.extraModels = []
            s.applySceneDefaults(from: defaults)
        }
    }

    func frame() { controller.frameWorkshop() }

    func randomizeSeed() { workshop { $0.seed = Int.random(in: SceneSettings.seedRange) } }

    func setWind(_ change: @escaping (inout FoliageSettings) -> Void) { controller.update { change(&$0.foliage) } }

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
            if folder == PlantStore.folder { PlantCatalog.setLaunch(catalog) }
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

    /// Every unsaved edit dropped.
    func revertAll() {
        guard isDirty else { return }
        commit(saved)
        if catalog.species(id: selected) == nil { select(catalog.species[0].id) }
    }

    // MARK: - Copy and paste

    enum Clip: String, Codable { case level, leaves, graft, look, habitat }
    private struct Clipboard: Codable {
        var plantClip: Clip
        var level: Foliage.Level?
        var leaves: Foliage.LeafRecipe?
        var graft: Foliage.Graft?
        var look: Foliage.Look?
        var habitat: Foliage.Habitat?
    }

    func copy(_ clip: Clip, bough: Bool = false) {
        let recipe = bough ? def.bough : def.recipe
        var c = Clipboard(plantClip: clip)
        switch clip {
        case .level: c.level = recipe?.levels[safe: level]
        case .leaves: c.leaves = recipe?.leaf
        case .graft: c.graft = def.recipe.graft
        case .look: c.look = def.look
        case .habitat: c.habitat = def.habitat
        }
        guard let data = try? JSONEncoder().encode(c), let text = String(data: data, encoding: .utf8) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// What is on the clipboard, if it is that kind of the editor's.
    func canPaste(_ clip: Clip) -> Bool { clipboard()?.plantClip == clip }

    private func clipboard() -> Clipboard? {
        guard let text = pasteboard.string(forType: .string), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Clipboard.self, from: data)
    }

    func paste(_ clip: Clip, bough: Bool = false) {
        guard let c = clipboard(), c.plantClip == clip else { return }
        var d = def
        func into(_ r: inout Foliage.Recipe) {
            switch clip {
            case .level: if let l = c.level, r.levels.indices.contains(level) { r.levels[level] = l }
            case .leaves: if let l = c.leaves { r.leaf = l }
            default: break
            }
        }
        switch clip {
        case .level, .leaves:
            if bough { if var b = d.bough { into(&b); d.bough = b } } else { into(&d.recipe) }
        case .graft: if let g = c.graft { d.recipe.graft = g }
        case .look: if let l = c.look { d.look = l }
        case .habitat: if let h = c.habitat { d.habitat = h }
        }
        def = d.sanitized()
    }

    func clearMessage() { message = nil }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
