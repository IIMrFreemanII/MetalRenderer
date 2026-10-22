import EngineCore
import MetalRenderer
import simd

/// The stage: a wide floor under a held afternoon sun and an open sky, nothing else. What stands on it is its scene
/// file's (Assets/Scenes/stage.scene): what scripts put there (README, "Scripts") and the placement editor moves.
/// Remaking it is quick, so a script that builds a scene a step at a time sees each step at once.
extension Scene {
    /// The materials a scene file's objects can name on the stage (SceneFile.Object.material).
    static let stageColours: [(String, SIMD3<Float>)] = [
        ("white", [0.85, 0.85, 0.85]), ("grey", [0.45, 0.45, 0.45]), ("black", [0.04, 0.04, 0.04]),
        ("red", [0.75, 0.12, 0.1]), ("orange", [0.85, 0.42, 0.1]), ("yellow", [0.85, 0.72, 0.15]),
        ("green", [0.2, 0.55, 0.18]), ("blue", [0.12, 0.28, 0.75]), ("purple", [0.45, 0.2, 0.65]),
        ("wood", [0.45, 0.28, 0.14]), ("stone", [0.62, 0.58, 0.52]),
    ]

    func buildStage() {
        let kit = Kit(self)
        section("Floor")
        addInstance(kit.quad, addMaterial(albedo: [0.42, 0.42, 0.4]), scale([400, 1, 400]))
        for (name, colour) in Scene.stageColours { nameMaterial(name, addMaterial(albedo: colour)) }
        // Shiny ones: specular, a little rough; metals.
        nameMaterial("plastic", addMaterial(GPUMaterial(albedo: SIMD4([0.8, 0.8, 0.8], 0), emission: SIMD4(.zero, 0.35), params: SIMD4(1, 1, 0, 0))))
        nameMaterial("metal", addMaterial(GPUMaterial(albedo: SIMD4([0.9, 0.9, 0.9], 1), emission: SIMD4(.zero, 0.25), params: SIMD4(1, 1, 0, 0))))
        nameMaterial("gold", addMaterial(GPUMaterial(albedo: SIMD4([1.0, 0.77, 0.34], 1), emission: SIMD4(.zero, 0.2), params: SIMD4(1, 1, 0, 0))))
        nameMaterial("mirror", addMaterial(GPUMaterial(albedo: SIMD4([0.95, 0.95, 0.95], 1), emission: SIMD4(.zero, 0.02), params: SIMD4(1, 1, 0, 0))))
        nameMaterial("glow", addMaterial(albedo: .zero, emission: [6, 5.2, 4]))
        section("Sun")
        let e = Scene.degrees(40), az: Float = -0.6
        let pose = LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)], scale: [1.0, 0.95, 0.88] * 1.8)
        _ = addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1], motion: .constant) { _ in pose }
    }
}
