import Foundation
import simd

/// The physics scene (Physics.swift): an arena in a studio, a tower of blocks on its right, a ramp in its back left
/// and a baked torus knot on a pedestal in front, and `bodies` SDF shapes of every kind dropped in over them, layer
/// on layer, to tumble down the ramp, knock the tower over and pile up; in front on the left a bin that `particles`
/// balls are poured into, heaping up and spilling over its rim; and in front in the middle a cloth hung by two
/// corners from a rod, falling over a ball.
extension Scene {
    func buildPhysics(_ physics: PhysicsSettings) {
        let kit = Kit(self)
        skyColor = [0.02, 0.02, 0.025]
        let floor = addPBRMaterial(baseColor: [0.16, 0.16, 0.17], metallic: 0, roughness: 0.35)
        let wall = addMaterial(albedo: [0.62, 0.62, 0.64])
        let rim = addPBRMaterial(baseColor: [0.85, 0.85, 0.82], metallic: 0, roughness: 0.5)
        kit.room(width: 14, height: 6, depth: 14, floor: floor, walls: wall, ceiling: true)
        addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.6, restitution: 0.3)
        for (point, normal) in [(SIMD3<Float>(-7, 0, 0), SIMD3<Float>(1, 0, 0)), ([7, 0, 0], [-1, 0, 0]), ([0, 0, -7], [0, 0, 1]),
                                ([0, 0, 7], [0, 0, -1])] {
            addStaticPlane(point: point, normal: normal)   // the room's walls, and one across its open front
        }

        /// A static SDF shape that is drawn and collided with.
        func fixed(_ shape: SDFShape, _ material: Int, _ transform: float4x4) {
            let s = addSDFShape(shape)
            addInstance(sdf: s, material, transform)
            addStaticCollider(sdf: s, transform)
        }
        // The arena's rim: four low walls, 9 m inside.
        let half: Float = 4.5, height: Float = 0.5, thick: Float = 0.15
        let side = SDFShape(.box(halfExtents: [half + 2 * thick, height / 2, thick], rounding: 0.03))
        for k in 0..<4 {
            let angle = Float(k) * .pi / 2
            fixed(side, rim, rotate(angle, [0, 1, 0]) * translate([0, height / 2, -(half + thick)]))
        }
        // A ramp in the back left, its top 2 m up.
        let tilt: Float = 0.42
        fixed(SDFShape(.box(halfExtents: [1.9, 0.08, 0.9], rounding: 0.02)),
              addPBRMaterial(baseColor: [0.3, 0.42, 0.6], metallic: 0, roughness: 0.25),
              translate([-2.2, 1.05, -2.6]) * rotate(-tilt, [0, 0, 1]))
        // A torus knot, baked into a distance grid, on a pedestal in front on the right.
        let knot = addSDFVolume(SDFVolume.cached(Scene.torusKnotMesh(), resolution: 64))
        fixed(SDFShape([SDFShape.Node(.volume(knot), at: [0, 0.85, 0], rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0])),
                        SDFShape.Node(.cylinder(halfHeight: 0.2, radius: 0.5, rounding: 0.04), smooth: 0.1, at: [0, 0.2, 0])]),
              addPBRMaterial(baseColor: [0.95, 0.75, 0.4], metallic: 0, roughness: 0.25), translate([2.6, 0, 2.4]))

        // The shapes the bodies are, each in a few colours. Nothing is metal: the scene's look has no reflections
        // (RenderSettings.usePhysicsLook), and a metal without them is black.
        let shapes: [SDFShape] = [
            SDFShape(.sphere(radius: 0.22)),
            SDFShape(.box(halfExtents: [0.2, 0.2, 0.2], rounding: 0.02)),
            SDFShape(.capsule(halfLength: 0.18, radius: 0.12)),
            SDFShape(.cylinder(halfHeight: 0.16, radius: 0.2, rounding: 0.03)),
            SDFShape(.cone(halfHeight: 0.2, bottom: 0.22, top: 0.06)),
            SDFShape(.torus(major: 0.18, minor: 0.07)),
            SDFShape([SDFShape.Node(.box(halfExtents: [0.21, 0.21, 0.21], rounding: 0.02)),
                      SDFShape.Node(.sphere(radius: 0.27), .subtract)]),
            SDFShape([SDFShape.Node(.sphere(radius: 0.17), at: [-0.08, 0, 0]),
                      SDFShape.Node(.sphere(radius: 0.13), smooth: 0.12, at: [0.14, 0.05, 0]),
                      SDFShape.Node(.sphere(radius: 0.1), smooth: 0.1, at: [0, 0.17, 0.04])]),
        ]
        let shapeIndices = shapes.map { addSDFShape($0) }
        let colours: [SIMD3<Float>] = [[0.8, 0.12, 0.08], [0.95, 0.6, 0.1], [0.15, 0.5, 0.25], [0.12, 0.3, 0.75],
                                       [0.85, 0.85, 0.82], [0.55, 0.2, 0.6], [0.1, 0.6, 0.65], [0.9, 0.35, 0.45]]
        let materials = colours.enumerated().map { i, c in
            addPBRMaterial(baseColor: c, metallic: 0, roughness: i % 3 == 2 ? 0.2 : 0.35)
        }

        // A tower of blocks on the right: two by two, crossed layer on layer.
        let block = addSDFShape(SDFShape(.box(halfExtents: [0.36, 0.12, 0.12], rounding: 0.015)))
        let wood = addPBRMaterial(baseColor: [0.75, 0.55, 0.35], metallic: 0, roughness: 0.6)
        let layers = min(8, physics.bodies / 12)
        var placed = 0
        for layer in 0..<layers {
            for k in 0..<3 where placed < physics.bodies {
                let offset = (Float(k) - 1) * 0.25
                let along = layer % 2 == 0
                let p = SIMD3<Float>(2.2 + (along ? 0 : offset), 0.12 + 0.24 * Float(layer), -0.6 + (along ? offset : 0))
                addBody(sdf: block, wood, translate(p) * rotate(along ? 0 : .pi / 2, [0, 1, 0]), density: 600, friction: 0.6,
                        restitution: 0.05)
                placed += 1
            }
        }

        // A heavy ball rolled in from the left at the tower's foot.
        if placed < physics.bodies {
            addBody(sdf: addSDFShape(SDFShape(.sphere(radius: 0.3))), addPBRMaterial(baseColor: [0.1, 0.1, 0.11], metallic: 0, roughness: 0.15),
                    translate([-3.8, 0.3, -0.6]), density: 3000, friction: 0.4, restitution: 0.1, velocity: [7, 0, 0])
            placed += 1
        }

        // The rest dropped in layers over the ramp and the middle, each layer a little higher and turned.
        var random = SplitMix(seed: 7)
        let columns = 8, rows = 6, spacing: Float = 0.78
        var n = 0
        while placed < physics.bodies {
            let layer = n / (columns * rows), cell = n % (columns * rows)
            let x = -3.0 + spacing * Float(cell % columns) + (layer % 2 == 0 ? 0 : spacing / 2)
            let z = -3.6 + spacing * Float(cell / columns)
            let y = 2.9 + 0.8 * Float(layer) + 0.15 * random.float()
            let axis = normalize(SIMD3<Float>(random.float() - 0.5, random.float() - 0.5, random.float() - 0.5) + 1e-3)
            let kind = Int(random.next() % UInt64(shapes.count))
            addBody(sdf: shapeIndices[kind], materials[Int(random.next() % UInt64(materials.count))],
                    translate([x, y, z]) * rotate(random.float() * 2 * .pi, axis), density: 400 + 400 * random.float(),
                    friction: 0.45, restitution: kind == 0 ? 0.5 : 0.25,
                    velocity: [0.6 * (random.float() - 0.5), 0, 0.6 * (random.float() - 0.5)])
            placed += 1
            n += 1
        }

        // A bin in front on the left, and a block of particles above it, a little off to one side so that some spill.
        let binCentre = SIMD3<Float>(-2.4, 0, 2.3), binHalf: Float = 0.6, binHeight: Float = 0.45, binWall: Float = 0.05
        let binSide = SDFShape(.box(halfExtents: [binHalf + binWall, binHeight / 2, binWall / 2], rounding: 0.01))
        let binMaterial = addPBRMaterial(baseColor: [0.6, 0.62, 0.66], metallic: 0, roughness: 0.35)
        for k in 0..<4 {
            fixed(binSide, binMaterial, translate(binCentre) * rotate(Float(k) * .pi / 2, [0, 1, 0])
                  * translate([0, binHeight / 2, binHalf + binWall / 2]))
        }
        let radius: Float = 0.035, gap = 2.2 * radius, across = 14
        let grains = (0..<physics.particles).map { i -> SIMD3<Float> in
            let layer = i / (across * across), cell = i % (across * across)
            let jitter = SIMD3<Float>(Float((i * 7919) % 97) / 97 - 0.5, 0, Float((i * 104_729) % 89) / 89 - 0.5) * 0.2 * radius
            return binCentre + SIMD3(0.25, 0.9, 0) + jitter
                + SIMD3(Float(cell % across) - Float(across - 1) / 2, Float(layer), Float(cell / across) - Float(across - 1) / 2) * gap
        }
        addParticles(addPBRMaterial(baseColor: [0.95, 0.72, 0.25], metallic: 0, roughness: 0.4), radius: radius, positions: grains,
                     friction: 0.6)

        // A cloth by two corners from a rod between two posts, over a ball.
        if physics.cloth >= 2 {
            let steel = addPBRMaterial(baseColor: [0.7, 0.7, 0.72], metallic: 0, roughness: 0.3)
            let rodY: Float = 1.5, rodZ: Float = 1.55, x0: Float = 0.9, half: Float = 0.75
            for side: Float in [-1, 1] {
                fixed(SDFShape(.cylinder(halfHeight: rodY / 2, radius: 0.03)), steel, translate([x0 + side * half, rodY / 2, rodZ]))
            }
            fixed(SDFShape(.capsule(halfLength: half, radius: 0.025)), steel, translate([x0, rodY, rodZ]) * rotate(.pi / 2, [0, 0, 1]))
            fixed(SDFShape(.sphere(radius: 0.42)), addPBRMaterial(baseColor: [0.85, 0.85, 0.82], metallic: 0, roughness: 0.25),
                  translate([x0, 0.42, 2.25]))
            let n = physics.cloth
            addCloth(addPBRMaterial(baseColor: [0.7, 0.08, 0.1], metallic: 0, roughness: 0.8), origin: [x0 - 0.65, rodY - 0.04, rodZ + 0.05],
                     across: [1.3, 0, 0], down: [0, 0, 1.3], columns: n, rows: n, pinned: [0, n - 1])
        }

        // A panel overhead and two lamps.
        addLight(.rect(width: 5, height: 2), color: SIMD3<Float>(1.0, 0.96, 0.9) * 4, motion: .constant) { _ in
            LightPose(position: [0, 5.97, -0.5], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        for (colour, position) in [(SIMD3<Float>(1.0, 0.8, 0.6), SIMD3<Float>(-4.5, 3.2, 3)), (SIMD3<Float>(0.7, 0.85, 1.0), SIMD3<Float>(4.5, 3.5, -3))] {
            addLight(.sphere(radius: 0.1), color: colour * 5, proxyMesh: kit.sphere, motion: .constant) { _ in LightPose(position: position) }
        }
        defaultCamera = Scene.demoCamera(.physics)!
    }
}

/// A small seeded generator (the scene is the same every time it is built).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// In [0, 1).
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
