import Foundation
import simd

/// The ragdoll scene: a staircase in the studio, from a landing at the back down to the floor, with posts and a bench
/// at its foot; `ragdolls` ragdolls (Scene.addRagdoll) dropped over the landing and the top steps, layer on layer, to
/// tumble down it and pile up.
extension Scene {
    func buildRagdolls(_ physics: PhysicsSettings) {
        let kit = Kit(self)
        skyColor = [0.02, 0.02, 0.025]
        let floor = addPBRMaterial(baseColor: [0.16, 0.16, 0.17], metallic: 0, roughness: 0.35)
        let wall = addMaterial(albedo: [0.62, 0.62, 0.64])
        kit.room(width: 14, height: 6, depth: 14, floor: floor, walls: wall, ceiling: true)
        addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.8, restitution: 0.1)
        for (point, normal) in [(SIMD3<Float>(-7, 0, 0), SIMD3<Float>(1, 0, 0)), ([7, 0, 0], [-1, 0, 0]), ([0, 0, -7], [0, 0, 1]),
                                ([0, 0, 7], [0, 0, -1])] {
            addStaticPlane(point: point, normal: normal)
        }
        // Grippy: the stairs rise at 34 degrees (tan 0.67), and a ragdoll lying across their edges at 0.6 slid on down.
        func fixed(_ shape: SDFShape, _ material: Int, _ transform: float4x4) {
            let s = addSDFShape(shape)
            addInstance(sdf: s, material, transform)
            addStaticCollider(sdf: s, transform, friction: 0.8, restitution: 0.1)
        }

        // The stairs: a landing at the back, 2.4 m up, and 8 steps down towards the camera, each a block to the floor.
        let stone = addPBRMaterial(baseColor: [0.55, 0.52, 0.48], metallic: 0, roughness: 0.6)
        let width: Float = 4.4, rise: Float = 0.3, run: Float = 0.45, steps = 8, back: Float = -6.9
        let landing = back + 2.4
        fixed(SDFShape(.box(halfExtents: [width / 2, Float(steps) * rise / 2, (landing - back) / 2], rounding: 0.01)), stone,
              translate([0, Float(steps) * rise / 2, (back + landing) / 2]))
        for k in 0..<steps {
            let top = Float(steps - k) * rise - rise   // the k-th step down
            guard top > 0 else { continue }
            let z = landing + run * (Float(k) + 0.5)
            fixed(SDFShape(.box(halfExtents: [width / 2, top / 2, run / 2], rounding: 0.01)), stone, translate([0, top / 2, z]))
        }
        // Low walls along both sides, down the stairs' slope, and posts and a bench at the foot.
        let rail = addPBRMaterial(baseColor: [0.3, 0.42, 0.6], metallic: 0, roughness: 0.3)
        let slope = atan(rise / run), foot = landing + run * Float(steps)   // the steps' edges run from the landing to here
        let length = (foot - landing) / cos(slope)
        for side: Float in [-1, 1] {
            fixed(SDFShape(.box(halfExtents: [0.08, 0.4, length / 2], rounding: 0.02)), rail,
                  translate([side * (width / 2 + 0.08), Float(steps) * rise / 2 + 0.3, (landing + foot) / 2]) * rotate(slope, [1, 0, 0]))
        }
        let post = SDFShape(.cylinder(halfHeight: 0.5, radius: 0.16, rounding: 0.03))
        let wood = addPBRMaterial(baseColor: [0.75, 0.55, 0.35], metallic: 0, roughness: 0.6)
        for x: Float in [-1.4, 0.2, 1.6] { fixed(post, wood, translate([x, 0.5, 1.6 + 0.3 * abs(x)])) }
        fixed(SDFShape(.box(halfExtents: [1.3, 0.22, 0.3], rounding: 0.03)), wood, translate([-0.3, 0.22, 3.2]) * rotate(0.2, [0, 1, 0]))

        // The ragdolls, in layers of 2 x 3 over the landing's edge and the top steps, lying across the stairs on their
        // backs or fronts (heads left or right), turned a little, thrown forward down them.
        let parts = RagdollShapes(self)
        let palette: [(top: SIMD3<Float>, bottom: SIMD3<Float>)] = [
            ([0.8, 0.12, 0.08], [0.12, 0.16, 0.3]), ([0.95, 0.6, 0.1], [0.2, 0.2, 0.22]), ([0.15, 0.5, 0.25], [0.35, 0.25, 0.15]),
            ([0.12, 0.3, 0.75], [0.6, 0.55, 0.45]), ([0.85, 0.85, 0.82], [0.1, 0.1, 0.12]), ([0.55, 0.2, 0.6], [0.25, 0.3, 0.35]),
        ]
        let skins: [SIMD3<Float>] = [[0.85, 0.65, 0.5], [0.6, 0.42, 0.3], [0.95, 0.78, 0.65], [0.4, 0.28, 0.2]]
        let looks = palette.map { (addPBRMaterial(baseColor: $0.top, metallic: 0, roughness: 0.6),
                                   addPBRMaterial(baseColor: $0.bottom, metallic: 0, roughness: 0.7)) }
        let skinMaterials = skins.map { addPBRMaterial(baseColor: $0, metallic: 0, roughness: 0.5) }
        var random = SplitMix(seed: 11)
        for n in 0..<physics.ragdolls {
            let layer = n / 6, cell = n % 6
            let x = (cell % 2 == 0 ? -1.0 : 1.0) + 0.1 * (random.float() - 0.5)
            let z = landing - 0.3 + 0.78 * Float(cell / 2)
            let y = Float(steps) * rise + 0.45 + 0.5 * Float(layer)
            // Standing, its height along y; laid down along x (head left or right), face up or down, turned a little.
            let yaw = 0.2 * (random.float() - 0.5) + (random.next() % 2 == 0 ? 0 : .pi)
            let face: Float = random.next() % 2 == 0 ? -.pi / 2 : .pi / 2   // on its back (its height along -z), or front
            let pose = translate([x, y, z]) * rotate(yaw + .pi / 2, [0, 1, 0]) * rotate(face, [1, 0, 0]) * translate([0, -0.85, 0])
            let look = looks[Int(random.next() % UInt64(looks.count))]
            addRagdoll(parts, pose, skin: skinMaterials[Int(random.next() % UInt64(skinMaterials.count))], top: look.0, bottom: look.1,
                       velocity: [0.3 * (random.float() - 0.5), 0, 1.5 + random.float()])
        }

        addLight(.rect(width: 5, height: 2), color: SIMD3<Float>(1.0, 0.96, 0.9) * 4, motion: .constant) { _ in
            LightPose(position: [0, 5.97, -1.5], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        for (colour, position) in [(SIMD3<Float>(1.0, 0.8, 0.6), SIMD3<Float>(-4.5, 3.2, 3)), (SIMD3<Float>(0.7, 0.85, 1.0), SIMD3<Float>(4.5, 3.5, -3))] {
            addLight(.sphere(radius: 0.1), color: colour * 5, proxyMesh: kit.sphere, motion: .constant) { _ in LightPose(position: position) }
        }
        defaultCamera = Scene.demoCamera(.ragdolls)!
    }

    /// A ragdoll's parts' SDF shapes, made once a scene: every part is a single primitive at its origin, so it
    /// collides by an exact distance (PhysicsWorld.buildShape).
    struct RagdollShapes {
        let pelvis, chest, head, upperArm, forearm, thigh, shin: Int

        init(_ scene: Scene) {
            pelvis = scene.addSDFShape(SDFShape(.capsule(halfLength: 0.09, radius: 0.11)))
            chest = scene.addSDFShape(SDFShape(.capsule(halfLength: 0.1, radius: 0.13)))
            head = scene.addSDFShape(SDFShape(.sphere(radius: 0.1)))
            upperArm = scene.addSDFShape(SDFShape(.capsule(halfLength: 0.11, radius: 0.05)))
            forearm = scene.addSDFShape(SDFShape(.capsule(halfLength: 0.11, radius: 0.045)))
            thigh = scene.addSDFShape(SDFShape(.capsule(halfLength: 0.15, radius: 0.07)))
            shin = scene.addSDFShape(SDFShape(.capsule(halfLength: 0.155, radius: 0.055)))
        }
    }

    /// A ragdoll of 11 bodies (pelvis, chest, head, upper arms, forearms, thighs, shins) standing 1.7 m tall with its
    /// feet at the origin of `transform` (a rotation and a translation), facing +z, its arms by its sides. Ball joints
    /// at the spine, neck, shoulders and hips (each with a swing cone and a twist range), hinges at the elbows and
    /// knees (bending one way). Returns its bodies. `drawn` false: only its head is (flesh covers the rest).
    @discardableResult
    func addRagdoll(_ parts: RagdollShapes, _ transform: float4x4, skin: Int, top: Int, bottom: Int, density: Float = 1000,
                    velocity: SIMD3<Float> = .zero, drawn: Bool = true) -> Range<Int> {
        let first = physics?.bodies.count ?? 0
        let across = rotate(.pi / 2, [0, 0, 1])   // a capsule along x
        func part(_ shape: Int, _ material: Int, _ at: SIMD3<Float>, _ turn: float4x4 = matrix_identity_float4x4) -> Int {
            addBody(sdf: shape, material, transform * translate(at) * turn, density: density, friction: 0.8, restitution: 0.1,
                    velocity: velocity, mask: drawn || shape == parts.head ? Scene.maskGeometry : 0)
            return physics!.bodies.count - 1
        }
        let pelvis = part(parts.pelvis, bottom, [0, 0.98, 0], across)
        let chest = part(parts.chest, top, [0, 1.3, 0], across)
        let head = part(parts.head, skin, [0, 1.6, 0])
        var arms: [(Int, Int)] = [], legs: [(Int, Int)] = []
        for side: Float in [-1, 1] {
            arms.append((part(parts.upperArm, top, [side * 0.27, 1.22, 0]), part(parts.forearm, skin, [side * 0.27, 0.9, 0])))
            legs.append((part(parts.thigh, bottom, [side * 0.1, 0.71, 0]), part(parts.shin, bottom, [side * 0.1, 0.275, 0])))
        }
        let world = physics!
        let rotation = simd_float3x3(columns: (PhysicsMath.xyz(transform.columns.0), PhysicsMath.xyz(transform.columns.1),
                                               PhysicsMath.xyz(transform.columns.2)))
        func joint(_ a: Int, _ b: Int, _ at: SIMD3<Float>, axis: SIMD3<Float>, reference: SIMD3<Float>, _ kind: PhysicsJoint,
                   cone: SIMD3<Float>? = nil) {
            world.addJoint(a, b, at: PhysicsMath.xyz(transform * SIMD4(at, 1)), axis: rotation * axis, reference: rotation * reference,
                           kind, cone: cone.map { rotation * normalize($0) })
        }
        let up = SIMD3<Float>(0, 1, 0), down = SIMD3<Float>(0, -1, 0), side = SIMD3<Float>(1, 0, 0)
        joint(pelvis, chest, [0, 1.13, 0], axis: up, reference: side, .ball(swing: 0.5, twist: -0.4...0.4), cone: [0, 1, 0.3])
        joint(chest, head, [0, 1.47, 0], axis: up, reference: side, .ball(swing: 0.7, twist: -0.9...0.9), cone: [0, 1, 0.2])
        for (k, s) in [Float(-1), 1].enumerated() {
            // Shoulders: an arm swings out, forward and up, little back; elbows bend forward. Elbows and knees go a
            // little past straight, so that the pose they are built in isn't on a limit (where float rounding
            // decides whether it is pushed back, and the GPU's steps part from the CPU's).
            joint(chest, arms[k].0, [s * 0.27, 1.37, 0], axis: down, reference: side, .ball(swing: 1.4, twist: -0.8...0.8),
                  cone: [s, -0.3, 0.5])
            joint(arms[k].0, arms[k].1, [s * 0.27, 1.06, 0], axis: side, reference: down, .hinge(-2.4...0.1))
            // Hips: a leg swings forward and out, little back; knees bend back.
            joint(pelvis, legs[k].0, [s * 0.1, 0.93, 0], axis: down, reference: side, .ball(swing: 1.0, twist: -0.5...0.5),
                  cone: [s * 0.15, -1, 0.6])
            joint(legs[k].0, legs[k].1, [s * 0.1, 0.49, 0], axis: side, reference: down, .hinge(-0.1...2.4))
        }
        let range = first..<(physics!.bodies.count)
        world.addRagdoll(range)
        return range
    }
}
