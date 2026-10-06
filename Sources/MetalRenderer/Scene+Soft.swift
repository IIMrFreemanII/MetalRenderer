import Foundation
import simd

/// The soft body scene: a landing at the back of the studio and steps down from it, pegs at their foot and a ring on
/// the floor beyond; `softBodies` soft bodies (PhysicsSoft.swift), jellies and a few stiffer rubber ones, thrown onto
/// the landing in layers to flop down the steps, squeeze past the pegs and pile up.
extension Scene {
    func buildSoftBodies(_ physics: PhysicsSettings) {
        let kit = Kit(self)
        skyColor = [0.02, 0.02, 0.025]
        let floor = addPBRMaterial(baseColor: [0.16, 0.16, 0.17], metallic: 0, roughness: 0.35)
        let wall = addMaterial(albedo: [0.62, 0.62, 0.64])
        kit.room(width: 14, height: 6, depth: 14, floor: floor, walls: wall, ceiling: true)
        addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        for (point, normal) in [(SIMD3<Float>(-7, 0, 0), SIMD3<Float>(1, 0, 0)), ([7, 0, 0], [-1, 0, 0]), ([0, 0, -7], [0, 0, 1]),
                                ([0, 0, 7], [0, 0, -1])] {
            addStaticPlane(point: point, normal: normal)
        }
        func fixed(_ shape: SDFShape, _ material: Int, _ transform: float4x4) {
            let s = addSDFShape(shape)
            addInstance(sdf: s, material, transform)
            addStaticCollider(sdf: s, transform, friction: 0.7, restitution: 0.1)
        }

        // The landing, 1.4 m up at the back, and four steps down toward the camera.
        let stone = addPBRMaterial(baseColor: [0.55, 0.52, 0.48], metallic: 0, roughness: 0.6)
        let width: Float = 5, rise: Float = 0.35, run: Float = 0.6, steps = 4, back: Float = -6, landing: Float = -4.5
        let top = rise * Float(steps)
        fixed(SDFShape(.box(halfExtents: [width / 2, top / 2, (landing - back) / 2], rounding: 0.02)), stone,
              translate([0, top / 2, (back + landing) / 2]))
        for k in 1..<steps {
            let height = top - rise * Float(k)
            fixed(SDFShape(.box(halfExtents: [width / 2, height / 2, run / 2], rounding: 0.02)), stone,
                  translate([0, height / 2, landing + run * (Float(k) - 0.5)]))
        }
        let foot = landing + run * Float(steps - 1)
        // Pegs past the foot of the steps, and a ring lying on the floor beyond them.
        let wood = addPBRMaterial(baseColor: [0.75, 0.55, 0.35], metallic: 0, roughness: 0.6)
        let peg = SDFShape(.cylinder(halfHeight: 0.3, radius: 0.1, rounding: 0.03))
        for x: Float in [-1.6, -0.55, 0.55, 1.6] { fixed(peg, wood, translate([x, 0.3, foot + 0.9 + 0.25 * abs(x)])) }
        let rim = addPBRMaterial(baseColor: [0.3, 0.42, 0.6], metallic: 0, roughness: 0.3)
        fixed(SDFShape(.torus(major: 1.0, minor: 0.12)), rim, translate([0, 0.12, foot + 2.3]))

        // The soft bodies: a few shapes (each lattice made once), jelly colours, and every fifth one rubber.
        let shapes = [
            SDFShape(.sphere(radius: 0.24)),
            SDFShape(.box(halfExtents: [0.2, 0.2, 0.2], rounding: 0.06)),
            SDFShape(.capsule(halfLength: 0.16, radius: 0.15)),
            SDFShape(.cylinder(halfHeight: 0.13, radius: 0.24, rounding: 0.06)),
        ]
        let models = shapes.map { SoftModel($0, cells: physics.softCells, volumes: sdfVolumes) }
        let colours: [SIMD3<Float>] = [[0.85, 0.1, 0.12], [0.98, 0.55, 0.05], [0.95, 0.85, 0.15], [0.2, 0.7, 0.25],
                                       [0.1, 0.45, 0.9], [0.55, 0.2, 0.75], [0.95, 0.4, 0.65]]
        let looks = colours.map { addPBRMaterial(baseColor: $0, metallic: 0, roughness: 0.25) }
        let room = AABB(lo: [-7, -0.1, -7], hi: [7, 6, 7])
        var random = SplitMix(seed: 5)
        for n in 0..<physics.softBodies {
            let layer = n / 8, cell = n % 8
            let x = -1.65 + 1.1 * Float(cell % 4) + 0.15 * (random.float() - 0.5)
            let z = back + 0.45 + 0.65 * Float(cell / 4) + 0.1 * (random.float() - 0.5)
            let y = top + 0.4 + 0.6 * Float(layer)
            let throwing = SIMD3<Float>(0.4 * (random.float() - 0.5), 0, 1.6 + 0.8 * random.float())
            let k = Int(random.next() % UInt64(models.count))
            let turn = rotate(random.float() * 2 * .pi, [0, 1, 0]) * rotate(0.6 * (random.float() - 0.5), [1, 0, 0])
            let rubber = n % 5 == 4
            addSoftBody(models[k], looks[Int(random.next() % UInt64(looks.count))], translate([x, y, z]) * turn, bounds: room,
                        velocity: throwing, density: rubber ? 1100 : 1000, edge: rubber ? 2e-5 : 4e-3, friction: rubber ? 0.8 : 0.6)
        }

        addLight(.rect(width: 5, height: 2), color: SIMD3<Float>(1.0, 0.96, 0.9) * 4, motion: .constant) { _ in
            LightPose(position: [0, 5.97, -1.5], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        for (colour, position) in [(SIMD3<Float>(1.0, 0.8, 0.6), SIMD3<Float>(-4.5, 3.2, 3)), (SIMD3<Float>(0.7, 0.85, 1.0), SIMD3<Float>(4.5, 3.5, -3))] {
            addLight(.sphere(radius: 0.1), color: colour * 5, proxyMesh: kit.sphere, motion: .constant) { _ in LightPose(position: position) }
        }
        defaultCamera = Scene.demoCamera(.softBodies)!
    }
}
