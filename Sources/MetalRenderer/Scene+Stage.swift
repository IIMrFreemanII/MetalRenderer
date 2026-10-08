import Foundation
import simd

/// The VFX stage: effects lined up in a dark studio (`SceneSettings.stage.effects`, by name: VFXLibrary's built-in
/// ones, or the effects catalog's), 4 m apart, each at its own height over a glossy floor they bounce off ("floor")
/// and in which they show; a key light from the front and above, a cool light over them. Where the VFX editor shows what
/// it edits.
extension Scene {
    func buildVFXStage() {
        let kit = Kit(self)
        skyColor = [0.01, 0.012, 0.018]
        let floor = addPBRMaterial(baseColor: [0.07, 0.07, 0.08], metallic: 0, roughness: 0.22)
        let wall = addMaterial(albedo: [0.3, 0.3, 0.32])
        kit.room(width: 28, height: 12, depth: 18, floor: floor, walls: wall, ceiling: false)
        addLight(.rect(width: 4, height: 2), color: SIMD3<Float>(1, 0.95, 0.9) * 8, motion: .constant) { _ in
            LightPose(position: [0, 8, 5], direction: normalize(SIMD3<Float>(0, -1, -0.5)), tangent: [1, 0, 0])
        }
        addLight(.rect(width: 6, height: 1.5), color: SIMD3<Float>(0.6, 0.75, 1) * 5, motion: .constant) { _ in
            LightPose(position: [0, 10.5, 0], direction: [0, -1, 0], tangent: [1, 0, 0])   // over them: out of the camera's view
        }
        let rock = addMesh(Scene.rock(seed: 7))
        let stone = addPBRMaterial(baseColor: [0.5, 0.48, 0.45], metallic: 0, roughness: 0.7)
        addParticleCollider("floor", .plane(normal: [0, 1, 0], point: [0, 0.001, 0]))
        let names = settings.stage.effects
        for (i, name) in names.enumerated() {
            guard let fx = stageEffect(name) else {
                effectNotes.append("the stage has no effect \"\(name)\"")
                continue
            }
            let x = (Float(i) - Float(names.count - 1) / 2) * 4
            addEffect(fx, at: VFXPlacement(offset: [x - fx.origin.x, 0, -fx.origin.z]), meshes: ["rock": (rock, stone)])
        }
        let missing = effectNotes
        addEffects()
        effectNotes = missing + effectNotes
        defaultCamera = Scene.demoCamera(.vfxStage)!
    }

    /// The effect of that name: the catalog's (a saved file's, the editor's), else the built-in one.
    func stageEffect(_ name: String) -> VFXEffect? {
        VFXCatalog.resolve(settings.effects).effects[name] ?? VFXLibrary.named(name)
    }
}
