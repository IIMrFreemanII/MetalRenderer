import EngineCore

/// The renderer's state that names what is in the scene (by its place in the scene's tables or its file) or that was
/// begun in it: `Renderer.install` keeps of it only what its `SceneChange` allows (`after`), so a pick, a drag, an edit
/// or a script's closure begun in one scene never lands in another. State of that kind belongs here; outside it, every
/// install would have to remember to drop it (the scene-switching skill).
package struct SceneSession {
    // Named by their place in the scene's instance table: dropped at every install, the same world's next tile too.
    /// The frame slot whose pick (encodePick) is still to be read.
    package var pickPending: Int?
    /// The instances moved for good, per frame slot, still to be written (Renderer+ProceduralMaterials).
    package var pendingInstanceEdits: [Set<Int>] = []
    package var stillRefitPending = false

    // Begun in the scene: dropped when another is put in, or the same one made again.
    /// The placed object's arrow dragged (Renderer+Placement.swift): object `k` of the scene's file.
    package var placementDrag: Renderer.PlacementDrag?
    /// The VFX gizmo's arrow dragged.
    package var gizmoDrag: (axis: SIMD3<Float>, origin: SIMD3<Float>, last: Float)?
    /// The camera flying (0.6 s, eased) to what the Project Graph showed or F framed, or (`about`) turning about the
    /// pivot to the scene gizmo's view; where it turns about when there.
    package var flight: (from: Camera, to: Camera, target: SIMD3<Float>, distance: Float, start: Double, seconds: Double, about: Bool)?
    /// Whether the physics was behind its clock last frame (Renderer.stepsPerFrame): said once, when it falls behind.
    package var physicsBehind = false
    /// The interior the camera asks for in the city and since when (Renderer+Interiors), kept while the city is.
    package var interiorWanted: (key: String?, since: Double)?
    /// How far the plant workshop's lights have turned by themselves (degrees, RenderSettings.previewSpin): kept while
    /// the editor makes the workshop again.
    package var previewSpin: Float = 0
    /// The scripts' per-frame closures (ScriptRun.onFrame): another scene drops them (they name its objects); the same
    /// one made again keeps them (a script that edits the scene file makes it again). A script sets them again after
    /// `waitForScene()`.
    package var scriptHooks: [ScriptHook] = []

    package init() {}

    /// What of this a scene put in by `change` keeps.
    package func after(_ change: SceneChange) -> SceneSession {
        switch change {
        case .switched:
            return SceneSession()
        case .remade:
            var next = SceneSession()
            next.scriptHooks = scriptHooks
            return next
        case .continued:
            var next = self
            (next.pickPending, next.pendingInstanceEdits, next.stillRefitPending) = (nil, [], false)
            return next
        }
    }
}
