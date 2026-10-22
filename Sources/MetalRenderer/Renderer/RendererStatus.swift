import Characters
import EngineCore
import Physics
import Plants
import simd

/// What the renderer reports on its stats tick, twice a second, besides the settings.
package struct RendererStatus {
    /// This frame's direct-light method with Auto resolved, for the settings panel's denoiser caption.
    package var directMode: DirectLightMode
    /// The ray queries' counters are compiled in (RT_STATS).
    package var traversalCounters: Bool
    /// What the Debug window shows; only while it is open (`RendererController.debugActive`).
    package var debugInfo: DebugInfo?
    /// The GPU pass timings averaged since the last tick, if passes are being profiled.
    package var passTimes: [(name: String, ms: Double)]?
    /// The plant workshop's plant: what it costs (Scene.plantStats).
    package var plantStats: PlantStats?
    /// The scene's particle effects as they run (the VFX editor's status line).
    package var effects: VFXStatus?
    /// The building workshop's building: what it costs, and its plan (the Floor Plan window).
    package var buildingStats: BuildingStats?
    package var buildingPlan: BuildingPlan?
    /// The character workshop's character (Scene.characterStats).
    package var characterStats: CharacterStats?
    /// What the procedural materials' displacement made of the scene's meshes (the Material Designer's inspector).
    package var displacement: String?
    /// Walking: where (the Floor Plan window's you-are-here).
    package var walker: WalkerStatus?
    /// Where the camera is (the building editor's Pin: the city's building nearest it).
    package var cameraPosition: SIMD3<Float>?
    /// The destruction scene's objects (the Fracture Editor's list).
    package var destruction: DestructionStatus?
    /// What the scene's behaviour shows over the frame (SceneHUDView): the destruction's tool, the demolition's player.
    package var hud: SceneHUD?
}

/// Where the walker is: in the world, and in the building it is in (which, its storey, its lot's frame).
package struct WalkerStatus: Equatable {
    package var position: SIMD3<Float>
    package var yaw: Float
    package var building: Int?
    package var storey: Int?
    package var local: SIMD3<Float>?
    package var message: String?
    package var flashlight: Bool
    package var crouched: Bool
}
