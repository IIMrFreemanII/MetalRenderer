import EngineCore
import Foundation
import MetalRenderer
import SwiftUI

/// What the Fracture Editor needs of the renderer (RendererController).
protocol FractureEditorHost: AnyObject {
    var settings: RenderSettings { get }
    var defaultSettings: RenderSettings { get }
    var destructionStatus: DestructionStatus? { get }
    func update(_ change: @escaping (inout RenderSettings) -> Void)
    func observeTick(_ observer: @escaping () -> Void)
}

extension RendererController: FractureEditorHost {
    var destructionStatus: DestructionStatus? { status?.destruction }
}

/// The Fracture Editor's state, on the main thread (UE's Fracture Mode, for the destruction scene's objects): the
/// objects as the scene made them, the one selected and its recipe as edited, and the preview. An edit goes to the
/// renderer as the scene's settings (DestructionSettings.recipes: the scene is built again with it); Save writes every
/// edited recipe into the store (FractureStore), which the scene reads from then on.
final class FractureEditorModel: ObservableObject {
    private weak var host: FractureEditorHost?
    @Published private(set) var objects: [FractureObjectInfo] = []
    @Published var selected: String? { didSet { if selected != oldValue { loadSelected() } } }
    /// The selected object's recipe as edited, and whether that differs from what the scene has.
    @Published var recipe = FractureRecipe.defaults(.concrete)
    @Published private(set) var edited = false
    /// The preview: the selected object's pieces at `level`, `explode` apart.
    @Published var previewing = false
    @Published var level = 1
    @Published var explode: Float = 0.4
    @Published private(set) var message = ""

    var inScene: Bool { host.map { SceneRegistry.kind(for: .fracture) == $0.settings.scene.kind } ?? false }
    var info: FractureObjectInfo? { objects.first { $0.name == selected } }

    package init(host: FractureEditorHost) {
        self.host = host
        host.observeTick { [weak self] in self?.tick() }
        tick()
    }

    private func tick() {
        let now = host?.destructionStatus?.objects ?? []
        guard now != objects else { return }
        objects = now
        if selected == nil || !objects.contains(where: { $0.name == selected }) { selected = objects.first?.name }
        else if !edited { loadSelected() }
    }

    private func loadSelected() {
        guard let info else { return }
        recipe = info.recipe
        edited = false
        level = min(level, max(info.levels - 1, 1))
    }

    /// The recipe was changed in the form.
    func changed() { edited = recipe != info?.recipe }

    /// Opens the destruction scene (with its defaults), if this build has one.
    func openScene() {
        guard let host, let kind = SceneRegistry.kind(for: .fracture) else { return }
        let defaults = host.defaultSettings
        host.update { s in
            s.scene.kind = kind
            s.applySceneDefaults(from: defaults)
        }
    }

    /// The edit to the scene: it is built again with it.
    func apply() {
        guard let name = selected else { return }
        let r = recipe
        host?.update { $0.scene.destruction.recipes[name] = r }
        edited = false
        message = "Applied to \(name)."
    }

    /// Back to the saved recipe (or the scene's default).
    func revert() {
        guard let name = selected else { return }
        host?.update { $0.scene.destruction.recipes[name] = nil }
        edited = false
        message = "\(name): the saved recipe."
    }

    /// A new seed, applied.
    func reseed() {
        recipe.seed = UInt64.random(in: 1...999_999)
        apply()
    }

    /// The preview to the scene (it is built again, its pieces held apart and nothing breaking).
    func updatePreview() {
        let p = previewing ? selected.map { FracturePreview(object: $0, level: level, explode: explode) } : nil
        host?.update { $0.scene.destruction.preview = p }
    }

    /// Every edited recipe into the store, over what it had.
    func save() {
        guard let host else { return }
        var all = FractureStore.load()
        for (name, r) in host.settings.scene.destruction.recipes { all[name] = r }
        if let name = selected, edited { all[name] = recipe }
        do {
            try FractureStore.save(all)
            message = "Saved \(all.count) recipe\(all.count == 1 ? "" : "s") to Assets/Fracture/recipes.json."
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
