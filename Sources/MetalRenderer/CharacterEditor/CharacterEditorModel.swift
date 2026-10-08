import AppKit
import Combine
import QuartzCore

/// What the character editor needs of the renderer (RendererController; a stand-in in the tests).
protocol CharacterEditorHost: AnyObject {
    var settings: RenderSettings { get }
    var defaultSettings: RenderSettings { get }
    var characterStats: CharacterStats? { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void)
    func observeTick(_ observer: @escaping () -> Void)
    func frameWorkshop()
}

extension RendererController: CharacterEditorHost {
    var characterStats: CharacterStats? { status?.characterStats }
}

/// The character editor's state, on the main thread: the characters being edited (a whole catalog, CharacterCatalog),
/// the saved ones, which is selected, the locked sliders, and the workshop's settings as the renderer reports them.
///
/// As in the plant editor, an edit goes to the renderer as the catalog's registry key (`SceneSettings.characterCatalog`),
/// at most 30 times a second while a slider is dragged; unsaved edits are a draft (CharacterStore) until saved or
/// reverted; one undo step per edit, a drag being one edit.
final class CharacterEditorModel: ObservableObject {
    enum Tab: String, CaseIterable { case body = "Body", face = "Face", proportions = "Proportions", skin = "Skin" }

    let controller: CharacterEditorHost
    let undo = UndoManager()
    private let folder: URL?
    private let keepsDraft: Bool

    @Published private(set) var catalog: CharacterCatalog
    @Published private(set) var saved: CharacterCatalog
    @Published var selected: String
    @Published var tab = Tab.body
    /// Sliders Randomize and Mutate leave alone (CharacterParam.id).
    @Published var locked: Set<String> = []
    @Published private(set) var stats: CharacterStats?
    @Published private(set) var scene: SceneSettings
    @Published private(set) var mutants: [CharacterDNA] = []
    @Published private(set) var message: String?

    private var dragging = false
    private var dragStart: CharacterCatalog?
    private var liveSent = 0.0
    private var pendingLive: DispatchWorkItem?
    private var draftSave: DispatchWorkItem?

    init(controller: CharacterEditorHost, saved: CharacterCatalog = CharacterCatalog.launch, folder: URL? = CharacterStore.folder,
         draft: Bool = true) {
        self.controller = controller
        self.saved = saved
        self.folder = folder
        keepsDraft = draft
        undo.groupsByEvent = false
        catalog = (draft ? CharacterStore.loadDraft() : nil).map { CharacterCatalog.builtIn.merging($0.characters) } ?? saved
        scene = controller.settings.scene
        selected = controller.settings.scene.characterWorkshop.character
        if catalog.character(id: selected) == nil { selected = catalog.characters[0].id }
        controller.observeSettings { [weak self] s in self?.received(s) }
        controller.observeTick { [weak self, unowned controller] in self?.stats = controller.characterStats }
        if catalog != saved { push(final: true) }
    }

    // MARK: - What is edited

    private var index: Int { catalog.characters.firstIndex { $0.id == selected } ?? 0 }
    var isBuiltIn: Bool { index < BuiltInCharacters.all.count }
    var isDirty: Bool { catalog != saved }
    func isDirty(_ id: String) -> Bool { catalog.character(id: id) != saved.character(id: id) }
    var savedDNA: CharacterDNA? { saved.character(id: selected) }

    /// The selected character's DNA: setting it is an edit.
    var dna: CharacterDNA {
        get { catalog.characters[index] }
        set {
            var c = catalog
            c.characters[index] = newValue.sanitized()
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

    private func commit(_ c: CharacterCatalog) {
        guard c != catalog else { return }
        if !dragging { registerUndo(catalog) }
        catalog = c
        if dragging { pushLive() } else { push(final: true) }
    }

    private func registerUndo(_ old: CharacterCatalog) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { m in m.restore(old) }
        undo.endUndoGrouping()
    }

    private func restore(_ old: CharacterCatalog) {
        let now = catalog
        undo.registerUndo(withTarget: self) { m in m.restore(now) }
        catalog = old
        if catalog.character(id: selected) == nil { select(catalog.characters[0].id) }
        push(final: true)
    }

    // MARK: - Locks

    func isLocked(_ id: String) -> Bool { locked.contains(id) }
    func toggleLock(_ id: String) { if locked.contains(id) { locked.remove(id) } else { locked.insert(id) } }

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

    private var key: String { catalog == saved && saved == CharacterCatalog.launch ? "" : CharacterCatalog.register(catalog) }

    private func push(final: Bool) {
        if final { pendingLive?.cancel(); pendingLive = nil; saveDraft() }
        let key = self.key
        guard controller.settings.scene.kind == .characters, controller.settings.scene.characterCatalog != key else { return }
        controller.update { $0.scene.characterCatalog = key }
    }

    private func saveDraft() {
        guard keepsDraft else { return }
        draftSave?.cancel()
        let draft = catalog == saved ? nil : catalog
        let work = DispatchWorkItem { CharacterStore.saveDraft(draft) }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func received(_ s: RenderSettings) {
        if s.scene != scene { scene = s.scene }
        if s.scene.kind == .characters && !dragging, s.scene.characterCatalog != key { push(final: true) }
    }

    // MARK: - The workshop

    var inWorkshop: Bool { scene.kind == .characters }

    func workshop(_ change: @escaping (inout CharacterSceneSettings) -> Void) {
        controller.update { change(&$0.scene.characterWorkshop) }
    }

    func select(_ id: String) {
        selected = id
        if inWorkshop, scene.characterWorkshop.character != id {
            workshop { $0.character = id; $0.layout = $0.layout == .mutate ? .single : $0.layout; $0.mutants = "" }
        }
        mutants = []
    }

    func goToWorkshop() {
        let id = selected, key = self.key, defaults = controller.defaultSettings
        controller.update { s in
            s.scene.characterWorkshop.character = id
            s.scene.characterCatalog = key
            guard s.scene.kind != .characters else { return }
            s.scene.kind = .characters
            s.scene.extraModels = []
            s.applySceneDefaults(from: defaults)
        }
    }

    func frame() { controller.frameWorkshop() }

    /// Holding Compare (or C in the workshop): the saved character in place of the edited one.
    func compare(_ on: Bool) {
        guard let saved = savedDNA ?? (isBuiltIn ? BuiltInCharacters.all[index] : nil) else { return }
        let key = on ? CharacterCatalog.register(CharacterCatalog(characters: [saved])) : ""
        workshop { $0.compare = key }
    }

    // MARK: - Randomize and Mutate

    /// The unlocked sliders of `groups` drawn again at random.
    func randomize(_ groups: [CharacterParam.Group]) {
        dna = CharacterParams.randomized(dna, groups: groups, locked: locked, seed: UInt64.random(in: 1...UInt64.max))
    }

    /// Just these sliders (CharacterParam.id) drawn again at random, the unlocked ones: one part of the face.
    func randomize(only ids: [String]) {
        dna = CharacterParams.randomized(dna, groups: CharacterParam.Group.allCases, only: Set(ids), locked: locked,
                                         seed: UInt64.random(in: 1...UInt64.max))
    }

    /// Five variations side by side in the workshop: pick one with `pick`.
    func mutate() {
        mutants = CharacterParams.mutants(of: dna, locked: locked, seed: UInt64.random(in: 1...UInt64.max))
        let key = CharacterCatalog.register(CharacterCatalog(characters: mutants))
        if !inWorkshop { goToWorkshop() }
        workshop { $0.mutants = key; $0.layout = .mutate }
    }

    /// Variation `k` (0-based) becomes the character (its id and name stay).
    func pick(_ k: Int) {
        guard mutants.indices.contains(k) else { return }
        var d = mutants[k]
        (d.id, d.name, d.basedOn) = (dna.id, dna.name, dna.basedOn)
        dna = d
        mutants = []
        workshop { $0.mutants = ""; $0.layout = .single }
    }

    // MARK: - Characters

    /// A new character, a copy of the selected one under an id of its own.
    func newCharacter() {
        var d = dna
        let base = d.id
        var id = "\(base.split(separator: "-").first ?? "character")-copy", n = 2
        while catalog.character(id: id) != nil { id = "\(base)-copy\(n)"; n += 1 }
        d.id = id
        d.name += " copy"
        d.basedOn = base
        var c = catalog
        c.characters.append(d)
        commit(c)
        select(id)
    }

    func rename(_ name: String) {
        var d = dna
        d.name = name
        if !isBuiltIn {
            var id = PlantEditorModel.slug(name), n = 2
            if id.isEmpty { id = d.id }
            let base = id
            while id != d.id, catalog.character(id: id) != nil { id = "\(base)-\(n)"; n += 1 }
            d.id = id
        }
        let old = selected
        dna = d
        selected = d.id
        if inWorkshop, scene.characterWorkshop.character == old { workshop { $0.character = d.id } }
    }

    func deleteCharacter() {
        guard !isBuiltIn else { return }
        var c = catalog
        c.characters.remove(at: index)
        let first = c.characters[0].id
        commit(c)
        select(first)
    }

    func resetToBuiltIn() {
        guard isBuiltIn else { return }
        dna = BuiltInCharacters.all[index]
    }

    // MARK: - Saving

    func save() {
        guard let folder else {
            message = "METALRENDERER_CHARACTERS=builtin: nothing is saved"
            return
        }
        do {
            for (i, d) in catalog.characters.enumerated() where d != saved.character(id: d.id) {
                if i < BuiltInCharacters.all.count && d == BuiltInCharacters.all[i].sanitized() {
                    try CharacterStore.remove(d.id, in: folder)
                } else {
                    try CharacterStore.save(d, in: folder)
                }
            }
            for d in saved.characters where catalog.character(id: d.id) == nil { try CharacterStore.remove(d.id, in: folder) }
            saved = catalog
            if folder == CharacterStore.folder { CharacterCatalog.setLaunch(catalog) }
            if keepsDraft { CharacterStore.saveDraft(nil) }
            message = "Saved to \(folder.path)"
            push(final: true)
        } catch {
            message = "Not saved: \(error.localizedDescription)"
        }
    }

    func revert() {
        guard let savedDNA else { return }
        dna = savedDNA
    }

    func revertAll() {
        guard isDirty else { return }
        commit(saved)
        if catalog.character(id: selected) == nil { select(catalog.characters[0].id) }
    }

    func clearMessage() { message = nil }
}
