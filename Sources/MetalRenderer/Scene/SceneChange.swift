/// What a scene put in is to the one before it (`Renderer.install`), which decides what of the renderer's state it
/// keeps. Every install is one of the three; the scene-switching skill says what each keeps and why.
package enum SceneChange: Equatable {
    /// Another kind of scene: its own camera, its clock from zero, nothing of the scene before kept.
    case switched
    /// The same kind made again: its settings changed, a hot reload, a placed file, virtual geometry or the season, or
    /// a load that failed and put the old one back. Its simulations are new, so its clock starts from zero (a world
    /// stepped to the old clock replays all of it in one frame: past the GPU's watchdog); the camera stays.
    case remade
    /// The same world around another tile, the same city with another interior, or a workshop's edit: what the frames
    /// gathered, the clock and the camera all hold.
    case continued

    /// From the scene before (`old`) to the one put in (`new`); `remade`: made again on purpose (`Renderer.remakeScene`).
    package init(from old: SceneSettings, to new: SceneSettings, remade: Bool) {
        if old.kind != new.kind {
            self = .switched
        } else if !remade && (new.isSameWorld(as: old) || new.isSameCity(as: old) || new.isSameWorkshop(as: old)) {
            self = .continued
        } else {
            self = .remade
        }
    }

    /// Whether the scene's clock starts again from zero (unless a benchmark's config sets it).
    package var restartsClock: Bool { self != .continued }
    /// Whether the camera goes to the scene's own (unless a benchmark's config sets it).
    package var resetsCamera: Bool { self == .switched }
}
