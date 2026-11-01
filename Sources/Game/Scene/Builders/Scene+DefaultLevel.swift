import EngineCore
import MetalRenderer
import simd

extension Scene {
    /// A furnace test: in a sky of 0.5 everywhere with no lights, a surface that reflects all the light it gets is as
    /// bright as the sky whatever its roughness. Rows of white metal, of white dielectric and of grey metal (0.5: half the sky),
    /// from mirror-like on the left to fully rough on the right.
    func buildFurnace() {
        let kit = Kit(self)
        skyColor = [0.5, 0.5, 0.5]
        let ground = addPBRMaterial(baseColor: [1, 1, 1], metallic: 0, roughness: 1)
        object("Floor") { addInstance(kit.quad, ground, translate([0, -3, 0]) * scale([20_000, 1, 20_000])) }
        let rows: [(String, SIMD3<Float>, Float)] = [("White metal", [1, 1, 1], 1), ("White", [1, 1, 1], 0), ("Grey metal", [0.5, 0.5, 0.5], 1)]
        for (row, kind) in rows.enumerated() {
            for column in 0..<9 {
                let roughness = max(Float(column) / 8, 0.03)
                let material = addPBRMaterial(baseColor: kind.1, metallic: kind.2, roughness: roughness)
                object("\(kind.0) \(column)") { kit.ball([Float(column - 4) * 1.6, Float(1 - row) * 1.6, 0], 0.5, material) }
            }
        }
    }

    /// Cloth, brushed metal and glass on a floor under the sun: velvet and cotton (a sheen), brushed steel its two ways with
    /// plain steel between them, clear, frosted and green glass that bend what is behind them, and a tinted window pane.
    func buildMaterialLobes() {
        let kit = Kit(self)
        let floor = addGridMaterial(GridLook(tile: [0.2, 0.19, 0.17], subgrid: 0))
        object("Floor") { addInstance(kit.quad, floor, scale([20_000, 1, 20_000])) }
        let toSun = normalize(SIMD3<Float>(0.1162, 0.7604, 0.6395))
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1]) { _ in LightPose(position: .zero, direction: toSun) }
        let steel: SIMD3<Float> = [0.75, 0.75, 0.77]
        let opaque: [(String, Int)] = [
            ("Velvet", addPBRMaterial(baseColor: [0.2, 0.01, 0.02], metallic: 0, roughness: 0.8, sheen: [1, 0.3, 0.3], sheenRoughness: 0.4)),
            ("Cotton", addPBRMaterial(baseColor: [0.35, 0.38, 0.5], metallic: 0, roughness: 0.9, sheen: [0.7, 0.7, 0.7], sheenRoughness: 0.7)),
            ("Brushed steel", addPBRMaterial(baseColor: steel, metallic: 1, roughness: 0.3, sheen: .zero, anisotropy: 0.8)),
            ("Plain steel", addPBRMaterial(baseColor: steel, metallic: 1, roughness: 0.3)),
            ("Brushed, turned", addPBRMaterial(baseColor: steel, metallic: 1, roughness: 0.3, sheen: .zero, anisotropy: 0.8, anisotropyRotation: .pi / 2)),
        ]
        for (i, material) in opaque.enumerated() {
            object(material.0) { kit.ball([-5.25 + Float(i) * 1.5, 0.5, -6], 0.5, material.1) }
        }
        let bodies: [(String, Int)] = [
            ("Glass", addSolidGlassMaterial()),
            ("Frosted glass", addSolidGlassMaterial(roughness: 0.3)),
            ("Green glass", addSolidGlassMaterial(tint: [0.15, 0.6, 0.25])),
        ]
        for (i, body) in bodies.enumerated() {
            object(body.0) { addInstance(kit.sphere, body.1, translate([2.25 + Float(i) * 1.5, 0.5, -6]) * scale(0.5), mask: Scene.maskLiquid) }
        }
        // Behind the glass, for it to bend; and a pane that lets the sun through tinted.
        let stripes = addPBRMaterial(baseColor: [0.9, 0.5, 0.1], metallic: 0, roughness: 0.6)
        for i in 0..<4 {
            object("Post \(i)") { addInstance(kit.cube, stripes, translate([2.6 + Float(i) * 1.2, 0.75, -7.5]) * scale([0.15, 1.5, 0.15])) }
        }
        let pane = addGlassMaterial(tint: [0.9, 0.35, 0.3])
        object("Pane") { addInstance(kit.cube, pane, translate([-3.5, 1, -4]) * scale([1.6, 2, 0.02]), mask: Scene.maskGlass) }
    }

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
