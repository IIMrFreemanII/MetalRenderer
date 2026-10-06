import Foundation
import simd

/// The muscles scene: flesh, muscles and skin (PhysicsFlesh.swift) on two kinds of skeleton. A character (the crowd's
/// Y Bot) whose bones are kinematic bodies its clips move (PhysicsRig.swift) idles, walks, runs and walks again round a
/// circle, kicking the balls on its way; `muscleRagdolls` ragdolls with flesh are thrown down steps at the back. The
/// flesh jiggles and squashes, the muscles bulge as the elbows and knees bend.
extension Scene {
    func buildMuscles(_ physics: PhysicsSettings) {
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
        let room = AABB(lo: [-7, -0.1, -7], hi: [7, 6, 7])
        var options = PhysicsWorld.FleshOptions()
        options.spacing = physics.fleshCell / 100
        options.muscleGain = physics.muscleGain

        // The character, round its circle, and the balls on the circle ahead of it.
        let centre = SIMD3<Float>(1.2, 0, 0.4)
        if physics.muscleCharacter, let radius = addFleshCharacter(centre: centre, options: options, sliding: physics.skin == .sliding, bounds: room) {
            let ball = addSDFShape(SDFShape(.sphere(radius: 0.11)))
            let colours: [SIMD3<Float>] = [[0.85, 0.15, 0.12], [0.95, 0.6, 0.1], [0.2, 0.6, 0.85], [0.3, 0.7, 0.3]]
            let looks = colours.map { addPBRMaterial(baseColor: $0, metallic: 0, roughness: 0.3) }
            for k in 0..<12 {
                let phi = 0.45 + Float(k) * 0.48, r = radius + (k % 2 == 0 ? -0.12 : 0.12)
                addBody(sdf: ball, looks[k % looks.count], translate(centre + [r * sin(phi), 0.11, r * cos(phi)]), density: 250,
                        friction: 0.5, restitution: 0.3)
            }
        }

        // The steps at the back on the left, from a landing 1.5 m up, and the ragdolls thrown down them.
        func fixed(_ shape: SDFShape, _ material: Int, _ transform: float4x4) {
            let s = addSDFShape(shape)
            addInstance(sdf: s, material, transform)
            addStaticCollider(sdf: s, transform, friction: 0.8, restitution: 0.1)
        }
        let stone = addPBRMaterial(baseColor: [0.55, 0.52, 0.48], metallic: 0, roughness: 0.6)
        let width: Float = 3, rise: Float = 0.3, run: Float = 0.45, steps = 5, back: Float = -6.9, x: Float = -4.6
        let landing = back + 1.8, top = Float(steps) * rise
        fixed(SDFShape(.box(halfExtents: [width / 2, top / 2, (landing - back) / 2], rounding: 0.01)), stone,
              translate([x, top / 2, (back + landing) / 2]))
        for k in 1..<steps {
            let height = top - rise * Float(k)
            fixed(SDFShape(.box(halfExtents: [width / 2, height / 2, run / 2], rounding: 0.01)), stone,
                  translate([x, height / 2, landing + run * (Float(k) - 0.5)]))
        }
        let parts = RagdollShapes(self)
        let skins: [SIMD3<Float>] = [[0.85, 0.62, 0.5], [0.62, 0.42, 0.32], [0.95, 0.76, 0.64], [0.45, 0.3, 0.22]]
        let skinLooks = skins.map { addPBRMaterial(baseColor: $0, metallic: 0, roughness: 0.45) }
        var random = SplitMix(seed: 7)
        for n in 0..<physics.muscleRagdolls {
            let layer = n / 3, cell = n % 3
            let at = SIMD3<Float>(x + 0.9 * (Float(cell) - 1) + 0.1 * (random.float() - 0.5), top + 0.4 + 0.45 * Float(layer),
                                  landing - 0.35 + 0.1 * (random.float() - 0.5))   // at its edge (friction stops a throw in 0.6 m)
            // Lying across the landing, face up or down, its head left or right.
            let yaw = 0.3 * (random.float() - 0.5) + (random.next() % 2 == 0 ? 0 : .pi)
            let face: Float = random.next() % 2 == 0 ? -.pi / 2 : .pi / 2
            let pose = translate(at) * rotate(yaw + .pi / 2, [0, 1, 0]) * rotate(face, [1, 0, 0]) * translate([0, -0.85, 0])
            let look = skinLooks[Int(random.next() % UInt64(skinLooks.count))]
            addFleshRagdoll(parts, pose, skin: look, velocity: [0.2 * (random.float() - 0.5), 0, 2.5 + random.float()], options: options,
                            bounds: room)
        }

        addLight(.rect(width: 5, height: 2), color: SIMD3<Float>(1.0, 0.96, 0.9) * 4, motion: .constant) { _ in
            LightPose(position: [0, 5.97, -0.5], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        for (colour, position) in [(SIMD3<Float>(1.0, 0.8, 0.6), SIMD3<Float>(-4.5, 3.2, 3)), (SIMD3<Float>(0.7, 0.85, 1.0), SIMD3<Float>(4.5, 3.5, -3))] {
            addLight(.sphere(radius: 0.1), color: colour * 5, proxyMesh: kit.sphere, motion: .constant) { _ in LightPose(position: position) }
        }
        defaultCamera = Scene.demoCamera(.muscles)!
    }

    /// The crowd's Y Bot as a figure (FleshFigure): its bones kinematic bodies its programme moves round a circle about
    /// `centre` (PhysicsRig.swift), its flesh, and its own mesh drawn on the flesh (its head, hands and feet on their
    /// bones). Returns the circle's radius; nil if there is no character to load.
    /// `sliding`: its mesh rides a skin of its own over the flesh (PhysicsSkin.swift), not the flesh itself.
    private func addFleshCharacter(centre: SIMD3<Float>, options: PhysicsWorld.FleshOptions, sliding: Bool, bounds: AABB) -> Float? {
        let library = CharacterLibrary.load()
        guard let character = library.characters.first(where: { $0.name.contains("Y Bot") }) ?? library.characters.first,
              let rig = CharacterRig(character) else { return nil }
        let material = addPBRMaterial(baseColor: [0.86, 0.66, 0.54], metallic: 0, roughness: 0.45)
        // The bones, where they are at rest (bind space), then the table their poses come from, and its first row.
        let bodies = rig.bones.indices.map { b in
            addKinematicBody(sdf: addSDFShape(rig.bones[b].shape), material, rig.restPlacement(b), mask: 0)
        }
        let world = physics!
        let rest = rig.bones.indices.map { world.bodyPose(bodies[$0], rig.restPlacement($0)) }
        let (table, radius) = rig.table(centre: centre) { b, placed in world.bodyPose(bodies[b], placed) }
        world.kinematicTable = table
        for (b, i) in bodies.enumerated() {
            let x = PhysicsMath.xyz(table[2 * b]), q = table[2 * b + 1]
            world.bodies[i].position = SIMD4(x, 0)
            world.bodies[i].rotation = q
            world.bodies[i].prevPosition = SIMD4(x, 0)
            world.bodies[i].prevRotation = q
        }
        let figure = FleshFigure(bones: rig.bones.indices.map { b in
            let bone = rig.bones[b]
            return FleshFigure.Bone(role: bone.role, body: bodies[b], shape: bone.shape, rest: rig.restPlacement(b), restPose: rest[b],
                                    from: bone.from, to: bone.to, thickness: bone.thickness, rigid: bone.rigid, parent: bone.parent)
        })
        // Its thighs, fitted to the mesh, meet between its legs: a slab cut out there keeps each leg's flesh its own
        // below the hips (one lattice across the legs bridged them, and stretched as they parted). 5 cm: wider than a
        // cube's diagonal once the lattice is shrunk by a particle's radius, so no corner is shared across it.
        var shape = fleshShape(figure)
        if let left = figure.bone(.thigh(1)), let right = figure.bone(.thigh(-1)) {
            let top = min(left.from.y, right.from.y) - 0.03, x = (left.from.x + right.from.x) / 2
            shape.nodes.append(SDFShape.Node(.box(halfExtents: [0.025, top / 2, 0.4]), .subtract, at: [x, top / 2, (left.from.z + right.from.z) / 2]))
        }
        let flesh = world.addFlesh(SoftModel(shape, spacing: options.spacing), figure: figure, muscles: MuscleSpec.limbs, options)
        // The sliding skin: a surface of the flesh's shape, 2.5 cm apart.
        var skin: SkinShell?
        if sliding {
            let box = shape.bounds()
            let surface = shape.triangles(cells: Int((box.hi - box.lo).max() / 0.025), push: 0)
            let normals = surface.positions.map { p -> SIMD3<Float> in
                let g = shape.gradient(p, h: 0.002)
                return dot(g, g) > 1e-12 ? normalize(g) : SIMD3(0, 1, 0)
            }
            skin = world.addSkin((surface.positions, normals, surface.indices), over: flesh, figure: figure)
        }
        // Its mesh (half detail), each vertex in the flesh, or on its bone where that is a head, a hand or a foot.
        let level = character.level(1)
        var own: [Int] = [], rigid: [Int] = []
        for (p, s) in zip(level.positions, level.skin) {
            let bone = rig.boneOf[Int(s.joints & 0xFF)]
            rigid.append(bone)
            own.append(rig.bones[bone].rigid ? -1 : flesh.model.locate(p)?.tet ?? -1)
        }
        addFleshMesh(flesh, figure: figure, mesh: (level.positions, level.normals, level.indices), uvs: level.uvs, own: own, rigid: rigid,
                     weld: true, material: material, bounds: bounds, skin: skin)
        return radius
    }

    /// A ragdoll (`addRagdoll`) with flesh over all but its head, which stays drawn: built in its standing pose (its
    /// own space before `pose`), where the muscles find their sides, and starting where `pose` puts it.
    private func addFleshRagdoll(_ parts: RagdollShapes, _ pose: float4x4, skin: Int, velocity: SIMD3<Float>,
                                 options: PhysicsWorld.FleshOptions, bounds: AABB) {
        let range = addRagdoll(parts, pose, skin: skin, top: skin, bottom: skin, velocity: velocity, drawn: false)
        let world = physics!
        let unpose = pose.inverse
        // The bodies' parts, in addRagdoll's order: pelvis, chest, head, then each side's upper arm, forearm, thigh, shin.
        var roles: [FleshFigure.Role] = [.pelvis, .chest, .head]
        for s: Float in [-1, 1] { roles += [.upperArm(s), .forearm(s), .thigh(s), .shin(s)] }
        // Each hangs from: the chest from the pelvis, the head from the chest, an upper arm from the chest, a forearm
        // from its upper arm, a thigh from the pelvis, a shin from its thigh (figure bones, in this order).
        let parents = [-1, 0, 1, 1, 3, 0, 5, 1, 7, 0, 9]
        let figure = FleshFigure(bones: zip(range, roles).enumerated().map { k, part in
            let (i, role) = part
            let rest = unpose * world.transform(i)
            let shape = sdfShapes[instances[Int(world.bodies[i].info.z)].sdf]
            var half: Float = 0, radius: Float = 0.1
            switch shape.nodes[0].primitive {
            case .capsule(let h, let r): (half, radius) = (h, r)
            case .sphere(let r): radius = r
            default: break
            }
            // Its length: a limb from its upper end (they hang at rest), the trunk's from its -x end.
            let ends = [SIMD3<Float>(0, -half, 0), SIMD3<Float>(0, half, 0)].map { PhysicsMath.xyz(rest * SIMD4($0, 1)) }
            let trunk = role == .pelvis || role == .chest
            let from = trunk ? (ends[0].x < ends[1].x ? ends[0] : ends[1]) : (ends[0].y > ends[1].y ? ends[0] : ends[1])
            let to = from == ends[0] ? ends[1] : ends[0]
            return FleshFigure.Bone(role: role, body: i, shape: shape, rest: rest, restPose: world.bodyPose(i, rest), from: from, to: to,
                                    thickness: radius, rigid: role == .head, parent: parents[k])
        })
        let shape = fleshShape(figure, inflate: 0.01)
        let flesh = world.addFlesh(SoftModel(shape, spacing: options.spacing), figure: figure, muscles: MuscleSpec.limbs, options)
        let surface = shape.triangles(cells: 64, push: 0)
        let normals = surface.positions.map { p -> SIMD3<Float> in
            let g = shape.gradient(p, h: 0.002)
            return dot(g, g) > 1e-12 ? normalize(g) : SIMD3(0, 1, 0)
        }
        let own = surface.positions.map { flesh.model.locate($0)?.tet ?? -1 }
        addFleshMesh(flesh, figure: figure, mesh: (surface.positions, normals, surface.indices), own: own,
                     rigid: [Int](repeating: 0, count: own.count), weld: false, material: skin, bounds: bounds)
    }

    /// The flesh's volume (rest space): its figure's bones that aren't rigid, each grown by `inflate`, blended together
    /// a little (a ragdoll's legs hang 3 cm apart: blended more, or grown more, one lattice would bind them).
    private func fleshShape(_ figure: FleshFigure, inflate: Float = 0) -> SDFShape {
        SDFShape(figure.bones.filter { !$0.rigid }.map { bone in
            var primitive = bone.shape.nodes[0].primitive
            switch primitive {
            case .capsule(let h, let r): primitive = .capsule(halfLength: h, radius: r + inflate)
            case .sphere(let r): primitive = .sphere(radius: r + inflate)
            case .box(let half, let rounding): primitive = .box(halfExtents: half + inflate, rounding: rounding + inflate)
            default: break
            }
            let rotation = simd_quatf(simd_float3x3(columns: (PhysicsMath.xyz(bone.rest.columns.0), PhysicsMath.xyz(bone.rest.columns.1),
                                                              PhysicsMath.xyz(bone.rest.columns.2))))
            return SDFShape.Node(primitive, .union, smooth: 0.01, at: PhysicsMath.xyz(bone.rest.columns.3), rotation: rotation)
        })
    }
}
