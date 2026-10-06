import Foundation
import simd

/// The hair scene: in the studio, `furBodies` furry bodies (balls, a rounded box, a capsule) dropped at the top of a
/// ramp to roll and tumble down it, and a ragdoll with long hair hanging by its back from a hook, swinging; a breeze
/// blows across. The strands are curves (Scene.addCurves), which only Metal's ray tracer draws.
extension Scene {
    /// How a body's hair grows: its guides (simulated) and the strands drawn around each.
    struct HairStyle {
        var guides: Int                  // over the whole body (fewer where `grows` says no)
        var vertices: Int                // a guide's
        var length: Float                // m
        var lengthJitter: Float = 0.2    // +/- this share
        var lean: Float                  // how far it bends toward `comb` (0...1)...
        var settle: Float = 1            // ...by this share of its length (long hair lies down on the scalp at once)
        var comb: SIMD3<Float>           // world (normalised): the way it lies
        var rootRadius: Float            // drawn strands' (m)
        var tipRadius: Float
        var globalRoot: Float            // the guides' stiffness, rad/s (PhysicsWorld.addStrand)
        var globalTip: Float
        var local: Float
        var perGuide: Int                // drawn strands a guide
        var clump: Float = 0.3
        var curl: Float = 0
        var friction: Float = 0.3
    }

    func buildHair(_ settings: PhysicsSettings) {
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
        let room = AABB(lo: [-7, 0, -7], hi: [7, 6, 7])
        func fixed(_ shape: SDFShape, _ material: Int, _ transform: float4x4, friction: Float = 0.7) {
            let s = addSDFShape(shape)
            addInstance(sdf: s, material, transform)
            addStaticCollider(sdf: s, transform, friction: friction, restitution: 0.1)
        }

        // The ramp: from 1.4 m up at the back down to the floor, between low walls, and a kerb across its foot.
        let stone = addPBRMaterial(baseColor: [0.55, 0.52, 0.48], metallic: 0, roughness: 0.6)
        let rail = addPBRMaterial(baseColor: [0.3, 0.42, 0.6], metallic: 0, roughness: 0.3)
        let rampX: Float = 1.2, top: Float = 1.4, back: Float = -3.6, foot: Float = 0.4
        let slope = atan(top / (foot - back)), rampLength = (foot - back) / cos(slope)
        let ramp = translate([rampX, top / 2 - 0.06, (back + foot) / 2]) * rotate(slope, [1, 0, 0])
        fixed(SDFShape(.box(halfExtents: [0.9, 0.06, rampLength / 2], rounding: 0.01)), stone, ramp)
        for side: Float in [-1, 1] {
            fixed(SDFShape(.box(halfExtents: [0.05, 0.16, rampLength / 2], rounding: 0.02)), rail,
                  ramp * translate([side * 0.95, 0.1, 0]))
        }
        fixed(SDFShape(.box(halfExtents: [1.2, 0.08, 0.08], rounding: 0.02)), rail, translate([rampX, 0.08, 2.6]))

        // The furry bodies, dropped at the top of the ramp one after another, rolling down it.
        let skins: [SIMD3<Float>] = [[0.45, 0.3, 0.2], [0.3, 0.3, 0.32], [0.6, 0.45, 0.3]]
        let furs: [SIMD3<Float>] = [[0.75, 0.5, 0.28], [0.12, 0.1, 0.09], [0.9, 0.85, 0.75], [0.55, 0.25, 0.12], [0.4, 0.4, 0.42]]
        let furMaterials = furs.map { addHairMaterial(color: $0) }
        let skinMaterials = skins.map { addPBRMaterial(baseColor: $0, metallic: 0, roughness: 0.7) }
        let shapes = [SDFShape(.sphere(radius: 0.2)), SDFShape(.box(halfExtents: [0.15, 0.15, 0.15], rounding: 0.06)),
                      SDFShape(.capsule(halfLength: 0.12, radius: 0.13)), SDFShape(.sphere(radius: 0.26))].map { addSDFShape($0) }
        var random = SplitMix(seed: 23)
        let groups = max(1, settings.hair)
        for k in 0..<settings.furBodies {
            let x = rampX + 0.45 * (random.float() - 0.5)
            let z = back + 0.4 + 0.15 * Float(k % 2)
            let y = top + 0.5 + 0.7 * Float(k)
            let turn = rotate(random.float() * 2 * .pi, normalize(SIMD3(random.float() - 0.5, 1, random.float() - 0.5)))
            let shape = shapes[k % shapes.count]
            let body = self.physics!.bodies.count
            addBody(sdf: shape, skinMaterials[k % skinMaterials.count], translate([x, y, z]) * turn, density: 300, friction: 0.7,
                    restitution: 0.15, velocity: [0, 0, 0.6], spin: [2 * (random.float() - 0.5), 0, 2 * (random.float() - 0.5)])
            let style = HairStyle(guides: 700, vertices: 6, length: 0.07, lean: 0.55, comb: normalize([0, -1, 0.4]),
                                  rootRadius: 0.0011, tipRadius: 0.0003, globalRoot: 80, globalTip: 30, local: 40,
                                  perGuide: groups, clump: 0.25, curl: 0.002)
            addHair(body: body, style: style, material: furMaterials[k % furMaterials.count], bounds: room, seed: UInt32(100 + k))
        }

        // The ragdoll with long hair, a mannequin on a stand: its pelvis held on a pole by a ball joint, its feet just
        // off the floor, swaying (pushed off sideways).
        let parts = RagdollShapes(self)
        let shirt = addPBRMaterial(baseColor: [0.12, 0.3, 0.75], metallic: 0, roughness: 0.6)
        let trousers = addPBRMaterial(baseColor: [0.2, 0.2, 0.22], metallic: 0, roughness: 0.7)
        let skin = addPBRMaterial(baseColor: [0.85, 0.65, 0.5], metallic: 0, roughness: 0.5)
        let feet = SIMD3<Float>(-1.1, 0.06, 0.4)
        let ragdoll = addRagdoll(parts, translate(feet), skin: skin, top: shirt, bottom: trousers, velocity: [0.6, 0, 0])
        let pelvis = ragdoll.lowerBound, chest = ragdoll.lowerBound + 1, head = ragdoll.lowerBound + 2
        // Held at the pelvis's back and the chest's by ball joints to two mounts that never move: upright, turning a
        // little about the stand; its head and arms swing.
        let steel = addPBRMaterial(baseColor: [0.35, 0.35, 0.38], metallic: 0, roughness: 0.4)
        let mountShape = addSDFShape(SDFShape(.sphere(radius: 0.03)))
        let world = self.physics!
        func mount(_ at: SIMD3<Float>, _ body: Int, swing: Float) {
            let m = world.bodies.count
            addBody(sdf: mountShape, steel, translate(at), density: 1000)
            world.bodies[m].position.w = 0   // held where it is
            world.bodies[m].invInertia = SIMD4(.zero, world.bodies[m].invInertia.w)
            world.addJoint(body, m, at: at, axis: [0, 1, 0], reference: [1, 0, 0], .ball(swing: swing, twist: -0.3...0.3))
        }
        let seat = feet + SIMD3(0, 0.98, -0.12), upper = feet + SIMD3(0, 1.3, -0.14)
        mount(seat, pelvis, swing: 0.3)
        mount(upper, chest, swing: 0.3)
        // The stand: a pole from a base on the floor up behind it, an arm out to each mount (drawn only: the mounts,
        // held as the pole is, mustn't touch it).
        let poleZ = feet.z - 0.24, poleTop = upper.y + 0.05
        fixed(SDFShape(.capsule(halfLength: poleTop / 2, radius: 0.025)), steel, translate([feet.x, poleTop / 2, poleZ]))
        fixed(SDFShape(.cylinder(halfHeight: 0.02, radius: 0.25, rounding: 0.01)), steel, translate([feet.x, 0.02, poleZ]))
        for at in [seat, upper] {
            let reach = at.z - 0.03 - poleZ
            addInstance(sdf: addSDFShape(SDFShape(.capsule(halfLength: reach / 2, radius: 0.012))), steel,
                        translate([feet.x, at.y, poleZ + reach / 2]) * rotate(.pi / 2, [1, 0, 0]))
        }
        let hair = HairStyle(guides: 1400, vertices: 12, length: 0.42, lengthJitter: 0.12, lean: 0.95, settle: 0.15,
                             comb: normalize([0, -1, -0.35]),
                             rootRadius: 0.0008, tipRadius: 0.0004, globalRoot: 10, globalTip: 0, local: 4,
                             perGuide: max(1, groups * 3 / 2), clump: 0.35, curl: 0.003, friction: 0.2)
        addHair(body: head, style: hair, material: addHairMaterial(color: [0.32, 0.17, 0.08]), bounds: room, seed: 7) { n in
            n.y > -0.25 && n.z < 0.35   // the scalp: not the face, not under the chin
        }

        world.wind = SIMD4(0.9, 0, 0.35, 0.6)

        addLight(.rect(width: 5, height: 2), color: SIMD3<Float>(1.0, 0.96, 0.9) * 4, motion: .constant) { _ in
            LightPose(position: [0, 5.97, -1.5], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        for (colour, position) in [(SIMD3<Float>(1.0, 0.8, 0.6), SIMD3<Float>(-4.5, 2.8, 2.5)), (SIMD3<Float>(0.7, 0.85, 1.0), SIMD3<Float>(4.0, 3.2, -2.5))] {
            addLight(.sphere(radius: 0.1), color: colour * 5, proxyMesh: kit.sphere, motion: .constant) { _ in LightPose(position: position) }
        }
        defaultCamera = Scene.demoCamera(.hair)!
    }

    /// Hair on body `body` (the physics' index), growing as `style` says where `grows` (its normal, in the body's
    /// space) says yes: guide strands from roots spread over its surface, and around each guide `perGuide` strands
    /// drawn as curves of `material` (a hair material) within `bounds`.
    func addHair(body: Int, style: HairStyle, material: Int, bounds: AABB, seed: UInt32,
                 grows: (SIMD3<Float>) -> Bool = { _ in true }) {
        let world = self.physics!
        let b = world.bodies[body], pose = PhysicsWorld.Pose(b), shape = Int(b.info.x)
        let reach = b.invInertia.w
        var random = SplitMix(seed: UInt64(seed))
        let firstGuide = world.hairStrands.count
        var area: Float = 0
        for g in 0..<style.guides {
            // A root: along a Fibonacci direction from the centre, marched in to the surface.
            let y = 1 - 2 * (Float(g) + 0.5) / Float(style.guides), r = (max(1 - y * y, 0)).squareRoot()
            let a = Float(g) * 2.399963
            let d = SIMD3<Float>(r * cos(a), y, r * sin(a))
            var p = d * (reach + 0.01)
            for _ in 0..<64 { p -= d * world.distance(shape: shape, p) }
            let normal = world.gradient(shape: shape, p)
            guard grows(normal) else { continue }
            area += 1
            // Grown out along its normal, bending toward the comb, kept out of the body as it goes.
            let length = style.length * (1 + style.lengthJitter * (2 * random.float() - 1))
            let segment = length / Float(style.vertices - 1)
            let comb = PhysicsMath.qrot(PhysicsMath.qconj(pose.rotation), style.comb)
            var points = [p + normal * 0.001]
            for i in 1..<style.vertices {
                let f = Float(i) / Float(style.vertices - 1)
                let bend = style.lean * min(f / style.settle, 1)
                let dir = normalize(normal * (1 - bend) + comb * bend + 1e-4)
                var q = points[i - 1] + dir * segment
                let gap = world.distance(shape: shape, q) - 0.002
                if gap < 0 { q -= world.gradient(shape: shape, q) * gap }
                points.append(points[i - 1] + normalize(q - points[i - 1]) * segment)
            }
            let across = normalize(cross(normal, abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)))
            world.addStrand(body: body, points: points.map { pose.toWorld($0) }, radius: 0.002, globalRoot: style.globalRoot,
                            globalTip: style.globalTip, local: style.local, friction: style.friction, across: pose.direction(across))
        }
        let guides = firstGuide..<world.hairStrands.count
        guard !guides.isEmpty else { return }
        // Spread: about the distance between neighbouring guides, so that the drawn strands fill the gaps.
        let surface = 4 * Float.pi * reach * reach * area / Float(style.guides)
        let spread = 0.6 * (surface / Float(guides.count)).squareRoot()
        let group = world.addHairGroup(guides: guides, perGuide: style.perGuide, spread: spread, clump: style.clump, curl: style.curl,
                                       seed: seed)
        let n = style.vertices
        var points: [SIMD3<Float>] = [], radii: [Float] = []
        points.reserveCapacity(guides.count * style.perGuide * (n + 2))
        let taper = (0..<n).map { style.rootRadius + (style.tipRadius - style.rootRadius) * Float($0) / Float(n - 1) }
        let strandRadii = [taper[0]] + taper + [taper[n - 1]]
        for r in 0..<(guides.count * style.perGuide) {
            points += world.drawnStrand(group: world.hairGroups[group], r)
            radii += strandRadii
        }
        let mesh = addCurves(points: points, perStrand: n + 2, radii: radii, bounds: bounds)
        addDeformingInstance(mesh, material)
        hairMeshes.append((group, mesh))
    }
}
