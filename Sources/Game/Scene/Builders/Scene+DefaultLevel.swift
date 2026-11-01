import EngineCore
import MetalRenderer
import simd

extension Scene {
    /// What the app opens first, as Unreal's default level (Engine/Maps/Templates/Template_Default): a grid floor out to
    /// the horizon under a sun, the atmosphere, clouds and height fog, its sun where that level's is. On the floor stands
    /// a row of test spheres at the places of the reference captures: greys, black, a mirror, rough metal, gold and red.
    func buildDefaultLevel() {
        let kit = Kit(self)
        let floor = addGridMaterial(GridLook(tile: [0.2, 0.19, 0.17], subgrid: 0))
        object("Floor") { addInstance(kit.quad, floor, scale([20_000, 1, 20_000])) }
        let spheres: [(String, SIMD3<Float>, Float, Float)] = [
            ("Grey 18%", [0.18, 0.18, 0.18], 0, 0.5), ("Grey 50%", [0.5, 0.5, 0.5], 0, 0.5), ("White", [0.9, 0.9, 0.9], 0, 0.5),
            ("Black", [0.04, 0.04, 0.04], 0, 0.5), ("Mirror", [0.95, 0.95, 0.95], 1, 0.05), ("Rough metal", [0.95, 0.95, 0.95], 1, 0.6),
            ("Gold", [1, 0.78, 0.34], 1, 0.3), ("Red", [0.7, 0.05, 0.05], 0, 0.4),
        ]
        for (i, sphere) in spheres.enumerated() {
            let material = addPBRMaterial(baseColor: sphere.1, metallic: sphere.2, roughness: sphere.3)
            object(sphere.0) { kit.ball([-5.25 + Float(i) * 1.5, 0.5, -6], 0.5, material) }
        }
        // That level's sun: pitch -49.5, yaw -10.3, here with its +x as -z and its +y as +x. (The atmosphere sets its colour.)
        let toSun = normalize(SIMD3<Float>(0.1162, 0.7604, 0.6395))
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1]) { _ in LightPose(position: .zero, direction: toSun) }
    }
}
