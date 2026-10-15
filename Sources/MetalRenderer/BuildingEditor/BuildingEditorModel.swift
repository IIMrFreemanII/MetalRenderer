import AppKit
import simd
import Combine
import QuartzCore

/// What the building editor needs of the renderer (RendererController; a stand-in in the tests).
protocol BuildingEditorHost: AnyObject {
    var settings: RenderSettings { get }
    var defaultSettings: RenderSettings { get }
    var buildingStats: BuildingStats? { get }
    var buildingPlan: BuildingPlan? { get }
    var walker: WalkerStatus? { get }
    var cameraPosition: SIMD3<Float>? { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void)
    func observeTick(_ observer: @escaping () -> Void)
    func frameWorkshop()
}

extension RendererController: BuildingEditorHost {
    var buildingStats: BuildingStats? { status?.buildingStats }
    var buildingPlan: BuildingPlan? { status?.buildingPlan }
    var walker: WalkerStatus? { status?.walker }
    var cameraPosition: SIMD3<Float>? { status?.cameraPosition }
}

/// The building editor's state, on the main thread: the styles being edited and single buildings' own plans (a whole
/// catalog, BuildingCatalog), the saved one, what is selected, the workshop's settings as the renderer reports them.
///
/// Like the plant editor's: an edit goes to the renderer as the catalog's registry key (`SceneSettings.buildingCatalog`);
/// while a slider is dragged only the workshop follows; let go, the city and the world do too. Unsaved edits are a
/// draft (BuildingStore). One undo step per edit; a drag is one edit; a Floor Plan tool's click is one.
final class BuildingEditorModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case massing = "Massing", facade = "Facade", floors = "Floors", rooms = "Rooms", furnish = "Furnish", look = "Look", site = "Site"
    }

    let controller: BuildingEditorHost
    let undo = UndoManager()
    private let folder: URL?
    private let keepsDraft: Bool
    var pasteboard = NSPasteboard.general

    @Published private(set) var catalog: BuildingCatalog
    @Published private(set) var saved: BuildingCatalog
    @Published var selected: String
    @Published var tab = Tab.massing
    @Published private(set) var stats: BuildingStats?
    @Published private(set) var plan: BuildingPlan?
    @Published private(set) var walker: WalkerStatus?
    @Published private(set) var scene: SceneSettings
    @Published private(set) var mutants: [BuildingStyleDef] = []
    @Published private(set) var message: String?

    private var dragging = false
    private var dragStart: BuildingCatalog?
    private var liveSent = 0.0
    private var pendingLive: DispatchWorkItem?
    private var draftSave: DispatchWorkItem?

    init(controller: BuildingEditorHost, saved: BuildingCatalog = BuildingCatalog.launch, folder: URL? = BuildingStore.folder, draft: Bool = true) {
        self.controller = controller
        self.saved = saved
        self.folder = folder
        keepsDraft = draft
        undo.groupsByEvent = false
        catalog = (draft ? BuildingStore.loadDraft() : nil).map { d in
            var c = BuildingCatalog.builtIn.merging(d.styles)
            c.overrides = d.overrides
            return c
        } ?? saved
        scene = controller.settings.scene
        selected = controller.settings.scene.buildings.style
        if catalog.style(id: selected) == nil { selected = catalog.styles[0].id }
        controller.observeSettings { [weak self] s in self?.received(s) }
        controller.observeTick { [weak self, unowned controller] in
            guard let self else { return }
            if self.stats != controller.buildingStats { self.stats = controller.buildingStats }
            if self.plan != controller.buildingPlan { self.plan = controller.buildingPlan }
            if self.walker != controller.walker { self.walker = controller.walker }
        }
        if catalog != saved { push(final: true) }
    }

    // MARK: - What is edited

    var isBuiltIn: Bool { catalog.isBuiltIn(selected) }
    var isDirty: Bool { catalog != saved }
    func isDirty(_ id: String) -> Bool { catalog.style(id: id) != saved.style(id: id) }
    var savedDef: BuildingStyleDef? { saved.style(id: selected) }

    /// The selected style's definition: setting it is an edit.
    var def: BuildingStyleDef {
        get { catalog.style(id: selected) ?? catalog.styles[0] }
        set {
            var c = catalog
            if let i = c.styles.firstIndex(where: { $0.id == selected }) { c.styles[i] = newValue }
            commit(c)
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

    private func commit(_ c: BuildingCatalog, undoable: Bool = true) {
        guard c != catalog else { return }
        if !dragging && undoable { registerUndo(catalog) }
        catalog = c
        if dragging { pushLive() } else { push(final: true) }
    }

    private func registerUndo(_ old: BuildingCatalog) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.restore(old) }
        undo.endUndoGrouping()
    }

    private func restore(_ old: BuildingCatalog) {
        let now = catalog
        undo.registerUndo(withTarget: self) { m in m.restore(now) }
        catalog = old
        if catalog.style(id: selected) == nil { select(catalog.styles[0].id) }
        push(final: true)
    }

    // MARK: - To the renderer

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

    private var key: String { catalog == saved && saved == BuildingCatalog.launch ? "" : BuildingCatalog.register(catalog) }

    /// Tells the renderer. `final`: every scene with buildings; otherwise only the workshop.
    private func push(final: Bool) {
        if final { pendingLive?.cancel(); pendingLive = nil; saveDraft() }
        let key = self.key, kind = controller.settings.scene.kind
        guard kind == .buildings || (final && (kind.isCity || kind.isWorld)), controller.settings.scene.buildingCatalog != key else { return }
        controller.update { $0.scene.buildingCatalog = key }
    }

    private func saveDraft() {
        guard keepsDraft else { return }
        draftSave?.cancel()
        let draft = catalog == saved ? nil : catalog
        let work = DispatchWorkItem { BuildingStore.saveDraft(draft) }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func received(_ s: RenderSettings) {
        if s.scene != scene { scene = s.scene }
        if (s.scene.kind.isCity || s.scene.kind.isWorld || s.scene.kind == .buildings) && !dragging, s.scene.buildingCatalog != key {
            push(final: true)
        }
    }

    // MARK: - The workshop

    var inWorkshop: Bool { scene.kind == .buildings }
    var workshopSettings: BuildingSceneSettings { scene.buildings }

    func workshop(_ change: @escaping (inout BuildingSceneSettings) -> Void) {
        controller.update { s in
            let night = s.scene.buildings.night
            change(&s.scene.buildings)
            // Night or day: the sky goes with it.
            if s.scene.buildings.night != night { s.sky = SkySettings.preset(for: s.scene) }
        }
    }

    func select(_ id: String) {
        selected = id
        if inWorkshop, scene.buildings.style != id, scene.buildings.pinned == nil {
            workshop { $0.style = id; $0.layout = $0.layout == .mutate ? .single : $0.layout; $0.mutants = "" }
        }
    }

    func goToWorkshop() { go(to: .buildings) }
    func goToCity() { go(to: .city) }

    private func go(to kind: SceneKind) {
        let id = selected, key = self.key, defaults = controller.defaultSettings
        controller.update { s in
            s.scene.buildings.style = id
            s.scene.buildingCatalog = key
            guard s.scene.kind != kind else { return }
            s.scene.kind = kind
            s.scene.extraModels = []
            s.applySceneDefaults(from: defaults)
        }
    }

    func frame() { controller.frameWorkshop() }
    func randomizeSeed() { workshop { $0.seed = Int.random(in: SceneSettings.seedRange) } }

    /// Holding Compare: the saved styles and buildings in place of the edited ones.
    func compare(_ on: Bool) {
        let key = on ? BuildingCatalog.register(saved) : ""
        workshop { $0.compare = key }
    }

    // MARK: - Mutate

    func mutate() {
        mutants = BuildingMutate.mutants(of: def, seed: UInt64.random(in: 1...UInt64.max))
        let key = BuildingCatalog.register(BuildingCatalog(styles: mutants))
        if !inWorkshop { goToWorkshop() }
        workshop { $0.mutants = key; $0.layout = .mutate }
    }

    func pick(_ k: Int) {
        guard mutants.indices.contains(k) else { return }
        def = BuildingMutate.pick(mutants[k], into: def)
        mutants = []
        workshop { $0.mutants = ""; $0.layout = .single }
    }

    // MARK: - Styles

    /// A new style, a copy of the selected one, built in the selected one's district now and then.
    func newStyle() {
        var d = def
        let base = d.id
        var id = "\(base.split(separator: "-").first ?? "style")-copy", n = 2
        while catalog.style(id: id) != nil { id = "\(base)-copy\(n)"; n += 1 }
        d.id = id
        d.name = d.name + " copy"
        d.basedOn = base
        d.districts = d.districts.mapValues { _ in 0.25 }
        var c = catalog
        c.styles.append(d)
        commit(c)
        select(id)
    }

    func rename(_ name: String) {
        var d = def
        d.name = name
        if !isBuiltIn {
            var id = PlantEditorModel.slug(name), n = 2
            if id.isEmpty { id = d.id }
            let base = id
            while id != d.id, catalog.style(id: id) != nil { id = "\(base)-\(n)"; n += 1 }
            d.id = id
        }
        let old = selected
        def = d
        selected = d.id
        if inWorkshop, scene.buildings.style == old { workshop { $0.style = d.id } }
    }

    func deleteStyle() {
        guard !isBuiltIn else { return }
        var c = catalog
        c.styles.removeAll { $0.id == selected }
        let first = c.styles[0].id
        commit(c)
        select(first)
    }

    func resetToBuiltIn() {
        guard isBuiltIn, let d = BuiltInBuildings.all.first(where: { $0.id == selected }) else { return }
        def = d
    }

    // MARK: - Single buildings

    /// The building the workshop shows: the pinned one, or its own.
    var currentRef: LotRef {
        Scene.workshopSpec(scene.buildings, catalog: catalog).ref
    }
    var currentOverride: LotOverride? { catalog.override(for: currentRef) }

    /// Changes the shown building's own plan (made if it has none).
    func editOverride(_ change: (inout LotOverride) -> Void) {
        var c = catalog
        let ref = currentRef
        if let i = c.overrides.firstIndex(where: { $0.matches(ref) }) {
            change(&c.overrides[i])
            let o = c.overrides[i]
            if o.edits.isEmpty && o.style == nil && o.floors == nil && o.shape == nil && o.use == nil { c.overrides.remove(at: i) }
        } else {
            var o = LotOverride(ref: ref)
            change(&o)
            c.overrides.append(o)
        }
        commit(c)
    }

    /// A Floor Plan tool's edit of the shown building.
    func addEdit(_ edit: PlanEdit) { editOverride { $0.edits.append(edit) } }
    func removeEdit(_ k: Int) { editOverride { if $0.edits.indices.contains(k) { $0.edits.remove(at: k) } } }
    func clearEdits() { editOverride { $0.edits = [] } }

    /// Shows the city building nearest the camera in the workshop (the city's scene: its seed and settings).
    func pinNearest() {
        guard scene.kind.isCity, let camera = controller.cameraPosition else { message = "Pin a building from the city"; return }
        let plan = CityPlan(scene.city, seed: scene.seed)
        guard let (i, lot) = plan.lots.enumerated().min(by: {
            simd_distance($0.1.rect.center, SIMD2(camera.x, camera.z)) < simd_distance($1.1.rect.center, SIMD2(camera.x, camera.z))
        }) else { return }
        let ref = LotRef.city(scene.city, seed: scene.seed, lot: i, lot)
        let id = catalog.style(for: lot.style, seed: lot.seed).id
        selected = id
        go(to: .buildings)
        workshop { $0.pinned = ref; $0.style = id; $0.layout = .single }
        message = "Pinned \(ref.title)"
    }

    func unpin() { workshop { $0.pinned = nil } }

    // MARK: - Saving

    func save() {
        guard let folder else {
            message = "METALRENDERER_BUILDINGS=builtin: nothing is saved"
            return
        }
        do {
            for d in catalog.styles where d != saved.style(id: d.id) {
                if let builtIn = BuiltInBuildings.all.first(where: { $0.id == d.id }), builtIn == d {
                    try BuildingStore.remove(d.id, in: folder)
                } else {
                    try BuildingStore.save(d, in: folder)
                }
            }
            for d in saved.styles where catalog.style(id: d.id) == nil { try BuildingStore.remove(d.id, in: folder) }
            if catalog.overrides != saved.overrides { try BuildingStore.saveOverrides(catalog.overrides, in: folder) }
            saved = catalog
            if folder == BuildingStore.folder { BuildingCatalog.setLaunch(catalog) }
            if keepsDraft { BuildingStore.saveDraft(nil) }
            message = "Saved to \(folder.path)"
            push(final: true)
        } catch {
            message = "Not saved: \(error.localizedDescription)"
        }
    }

    func revert() {
        guard let savedDef else { return }
        def = savedDef
    }

    func revertAll() {
        guard isDirty else { return }
        commit(saved)
        if catalog.style(id: selected) == nil { select(catalog.styles[0].id) }
    }

    // MARK: - Copy and paste

    enum Clip: String, Codable { case massing, facade, rooms, furnish, look, plan }
    private struct Clipboard: Codable {
        var buildingClip: Clip
        var proportions: BuildingStyleDef.Proportions?
        var window: BuildingStyleDef.WindowDef?
        var facade: BuildingStyleDef.FacadeDef?
        var massing: BuildingStyleDef.MassingDef?
        var programme: Programme?
        var interior: BuildingStyleDef.InteriorDef?
        var palette: BuildingStyleDef.Palette?
        var edits: [PlanEdit]?
    }

    func copy(_ clip: Clip) {
        let d = def
        var c = Clipboard(buildingClip: clip)
        switch clip {
        case .massing: c.massing = d.massing
        case .facade: (c.proportions, c.window, c.facade) = (d.proportions, d.window, d.facade)
        case .rooms: c.programme = d.programme
        case .furnish: c.interior = d.interior
        case .look: c.palette = d.palette
        case .plan: c.edits = currentOverride?.edits ?? []
        }
        guard let data = try? JSONEncoder().encode(c), let text = String(data: data, encoding: .utf8) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func canPaste(_ clip: Clip) -> Bool { clipboard()?.buildingClip == clip }

    private func clipboard() -> Clipboard? {
        guard let text = pasteboard.string(forType: .string), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Clipboard.self, from: data)
    }

    func paste(_ clip: Clip) {
        guard let c = clipboard(), c.buildingClip == clip else { return }
        if clip == .plan {
            if let edits = c.edits { editOverride { $0.edits = edits } }
            return
        }
        var d = def
        switch clip {
        case .massing: if let m = c.massing { d.massing = m }
        case .facade:
            if let p = c.proportions { d.proportions = p }
            if let w = c.window { d.window = w }
            if let f = c.facade { d.facade = f }
        case .rooms: if let p = c.programme { d.programme = p }
        case .furnish: if let i = c.interior { d.interior = i }
        case .look: if let p = c.palette { d.palette = p }
        case .plan: break
        }
        def = d.sanitized()
    }

    func clearMessage() { message = nil }
}
