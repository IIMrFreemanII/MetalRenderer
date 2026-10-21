import Foundation
import simd
import MetalRenderer

/// The destruction scene (Physics+Fracture.swift): a paved courtyard under an afternoon sun with fractured objects of
/// every material, each broken its own way: a concrete wall a wrecking ball swings into, a brick wall, two concrete
/// pillars with a wooden beam across them, two glass panes in wooden frames, a concrete tower a weight falls on, a
/// stone bust. The scripted demo (`DestructionSettings.demo`) wakes the ball at 2 s and the weight at 6 s, and fires
/// cannonballs at a pane, the brick wall and a pillar; the tools (Shoot, Blast) fire the pool of balls kept for them.
extension Scene {
    /// The massive setting's buildings' centres along x (DestructionSettings.buildings): side by side in the lot.
    static func buildingCentres(_ count: Int) -> [Float] {
        switch min(max(count, 1), 3) {
        case 1: return [0]
        case 2: return [-4.5, 4.5]
        default: return [-8, 0, 8]
        }
    }
}

extension Scene {
    func buildDestruction(_ settings: DestructionSettings) {
        let kit = Kit(self)
        var made: [Fractured] = [], bases: [String: FractureRecipe] = [:]
        let saved = FractureStore.load()
        /// Object `name`'s recipe: the editor's edit, the saved one, or `fallback` (its scene's default), its pieces
        /// scaled by the Pieces setting; the unscaled one kept for the editor.
        func chosen(_ name: String, _ fallback: FractureRecipe) -> FractureRecipe {
            let base = settings.recipes[name] ?? saved[name] ?? fallback
            bases[name] = base
            return base.scaled(settings.pieces)
        }
        func fractured(_ name: String, shape: SDFShape, recipe fallback: FractureRecipe, transform: float4x4, material: Int, interior: Int,
                       anchor: FractureAnchor, mask: UInt32 = Scene.maskGeometry, toughness: Float, strength: Float) {
            made.append(addFractured(name, shape: shape, recipe: chosen(name, fallback), transform: transform, material: material,
                                     interior: interior, anchor: anchor, mask: mask, toughness: toughness, strength: strength))
        }
        let world = physicsWorld()
        world.fractureTuning.x = settings.fade ? 6 : 1e9
        let tough = settings.toughness, strong = settings.strength

        // Materials, each object's outside then its broken inside (FractureMaterial's looks).
        let paving = addPBRMaterial(baseColor: [0.36, 0.34, 0.31], metallic: 0, roughness: 0.85)
        let plaster = addPBRMaterial(baseColor: [0.55, 0.5, 0.43], metallic: 0, roughness: 0.9)
        let concrete = addPBRMaterial(baseColor: [0.34, 0.33, 0.31], metallic: 0, roughness: 0.88)
        let concreteInside = addPBRMaterial(baseColor: [0.5, 0.48, 0.44], metallic: 0, roughness: 0.97)
        let brick = addPBRMaterial(baseColor: [0.46, 0.17, 0.1], metallic: 0, roughness: 0.82)
        let brickInside = addPBRMaterial(baseColor: [0.62, 0.3, 0.18], metallic: 0, roughness: 0.95)
        let wood = addPBRMaterial(baseColor: [0.42, 0.27, 0.15], metallic: 0, roughness: 0.65)
        let woodInside = addPBRMaterial(baseColor: [0.74, 0.58, 0.38], metallic: 0, roughness: 0.85)
        let glass = addGlassMaterial(tint: [0.9, 0.97, 0.95])
        let glassInside = addGlassMaterial(tint: [0.85, 0.95, 0.92])
        let marble = addPBRMaterial(baseColor: [0.62, 0.6, 0.56], metallic: 0, roughness: 0.35)
        let marbleInside = addPBRMaterial(baseColor: [0.7, 0.68, 0.64], metallic: 0, roughness: 0.8)
        let steel = addPBRMaterial(baseColor: [0.32, 0.32, 0.34], metallic: 1, roughness: 0.35)
        let iron = addPBRMaterial(baseColor: [0.12, 0.12, 0.13], metallic: 0.8, roughness: 0.5)

        section("Courtyard")
        addInstance(kit.quad, paving, scale([60, 1, 60]))
        addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        // (Massive: the back wall gives way to a building's lot behind it.)
        let backWall: Float = settings.massive ? -22 : -9
        kit.slab([-12, 0, backWall - 0.4], [12, 5, backWall], plaster)
        kit.slab([-12.4, 0, backWall - 0.4], [-12, 5, 6], plaster)
        kit.slab([12, 0, backWall - 0.4], [12.4, 5, 6], plaster)
        for (point, normal) in [(SIMD3<Float>(0, 0, backWall), SIMD3<Float>(0, 0, 1)), ([-12, 0, 0], [1, 0, 0]), ([12, 0, 0], [-1, 0, 0])] {
            addStaticPlane(point: point, normal: normal, friction: 0.6, restitution: 0.1)
        }
        func fixed(_ shape: SDFShape, _ material: Int, _ transform: float4x4) {
            let s = addSDFShape(shape)
            addInstance(sdf: s, material, transform)
            addStaticCollider(sdf: s, transform, friction: 0.6, restitution: 0.1)
        }
        func recipe(_ material: FractureMaterial, seed: UInt64) -> FractureRecipe {
            var r = FractureRecipe.defaults(material)
            r.seed = seed
            return r
        }

        // A concrete wall on the left, the wrecking ball's.
        section("Concrete wall")
        let wallAt = SIMD3<Float>(-4.6, 1.25, -3)
        fractured("Concrete wall", shape: SDFShape(.box(halfExtents: [1.7, 1.25, 0.15])), recipe: recipe(.concrete, seed: 11),
                     transform: translate(wallAt), material: concrete, interior: concreteInside, anchor: .ground(0),
                     toughness: tough, strength: strong)

        // A brick wall at the back.
        section("Brick wall")
        var bricks = recipe(.brick, seed: 21)
        bricks.brick = [0.4, 0.16, 0.22]
        fractured("Brick wall", shape: SDFShape(.box(halfExtents: [1.4, 0.88, 0.11])), recipe: bricks,
                     transform: translate([1.5, 0.88, -5.2]), material: brick, interior: brickInside, anchor: .ground(0),
                     toughness: tough, strength: strong)

        // Two concrete pillars on the right, a wooden beam across their tops.
        section("Pillars and beam")
        let pillar = SDFShape(.cylinder(halfHeight: 1.3, radius: 0.3, rounding: 0.02))
        for (k, x) in [Float(3.4), 5.4].enumerated() {
            var r = recipe(.concrete, seed: 31 + UInt64(k))
            r.counts = [10, 4]
            fractured("Pillar \(k + 1)", shape: pillar, recipe: r, transform: translate([x, 1.3, -2.2]), material: concrete,
                         interior: concreteInside, anchor: .ground(0), toughness: tough, strength: strong)
        }
        fractured("Beam", shape: SDFShape(.box(halfExtents: [1.35, 0.1, 0.12])), recipe: recipe(.wood, seed: 41),
                     transform: translate([4.4, 2.71, -2.2]), material: wood, interior: woodInside, anchor: .none,
                     toughness: tough, strength: strong)

        // Two glass panes in wooden frames in the middle.
        section("Glass panes")
        let paneHalf = SIMD3<Float>(0.6, 0.8, 0.006)
        for (k, x) in [Float(-1.9), -0.5].enumerated() {
            let centre = SIMD3<Float>(x, 1.15, -0.6)
            var r = recipe(.glass, seed: 51 + UInt64(k))
            r.centre = [0.08 * Float(k == 0 ? 1 : -1), -0.12, 0]
            fractured("Pane \(k + 1)", shape: SDFShape(.box(halfExtents: paneHalf)), recipe: r, transform: translate(centre),
                         material: glass, interior: glassInside, anchor: .rim, mask: Scene.maskGlass, toughness: tough, strength: strong)
            // The frame round it, and its legs.
            let t: Float = 0.05, d: Float = 0.05
            fixed(SDFShape(.box(halfExtents: [paneHalf.x + t, t / 2, d])), wood, translate(centre + [0, paneHalf.y + t / 2, 0]))
            fixed(SDFShape(.box(halfExtents: [paneHalf.x + t, t / 2, d])), wood, translate(centre - [0, paneHalf.y + t / 2, 0]))
            for side: Float in [-1, 1] {
                fixed(SDFShape(.box(halfExtents: [t / 2, (centre.y + paneHalf.y + t) / 2, d])), wood,
                      translate([centre.x + side * (paneHalf.x + t / 2), (centre.y + paneHalf.y + t) / 2, centre.z]))
            }
        }

        // A concrete tower at the back right, the weight's.
        section("Tower")
        var towerRecipe = recipe(.concrete, seed: 61)
        towerRecipe.counts = [16, 6]
        fractured("Tower", shape: SDFShape(.box(halfExtents: [0.5, 2, 0.5])), recipe: towerRecipe, transform: translate([7.4, 2, -5.4]),
                     material: concrete, interior: concreteInside, anchor: .ground(0), toughness: tough, strength: strong)

        // A stone bust on a plinth in front on the left.
        section("Bust")
        let bust = SDFShape([
            SDFShape.Node(.box(halfExtents: [0.32, 0.3, 0.32], rounding: 0.03), at: [0, 0.3, 0]),
            SDFShape.Node(.box(halfExtents: [0.26, 0.24, 0.16], rounding: 0.08), smooth: 0.05, at: [0, 0.84, 0]),
            SDFShape.Node(.capsule(halfLength: 0.06, radius: 0.07), smooth: 0.06, at: [0, 1.12, 0]),
            SDFShape.Node(.sphere(radius: 0.16), smooth: 0.05, at: [0, 1.32, 0.01]),
        ])
        var bustRecipe = recipe(.stone, seed: 71)
        bustRecipe.counts = [12, 4]
        fractured("Bust", shape: bust, recipe: bustRecipe, transform: translate([-6.6, 0, 0.6]), material: marble,
                     interior: marbleInside, anchor: .ground(0), toughness: tough, strength: strong)

        // Statues (Assets' models, their meshes cut piece by piece): the golem in front on the right.
        if settings.statues {
            section("Statues")
            let files = Scene.assetsDirectory.appendingPathComponent("grim dark armored golem 3d model.glb")
            if FileManager.default.fileExists(atPath: files.path) {
                var r = recipe(.stone, seed: 81)
                r.counts = [10, 4]
                if let f = addFracturedModel("Golem", url: files, height: 1.7, transform: translate([2.6, 0, 1.4]) * rotate(-0.5, [0, 1, 0]),
                                             recipe: chosen("Golem", r), interior: [0.55, 0.53, 0.5], anchor: .ground(0), toughness: tough, strength: strong) {
                    made.append(f)
                }
            }
        }

        // Massive: a three-storey concrete building behind the courtyard, its walls and floors each fractured (4,000
        // pieces and more with the courtyard's: offline runs).
        if settings.massive {
            section("Building")
            let w: Float = 3.2, d: Float = 2.8, storey: Float = 3, t: Float = 0.2
            // Its welds a twentieth of the courtyard's: blasted at the corners, its ground floor gives way and the storeys
            // come down. (At full strength what is left of each wall holds them up; they once came down only because a
            // weld's anchors were metres off and it snapped at the first turn.)
            let buildingStrength: Float = 0.05
            for (n, x) in Scene.buildingCentres(settings.buildings).enumerated() {
            let centre = SIMD3<Float>(x, 0, -15), name = settings.buildings == 1 ? "Building" : "Building \(n + 1)"
            var panel = recipe(.concrete, seed: 101 + UInt64(n) * 1000)
            panel.counts = [24, 8]
            for floor in 0..<3 {
                let y = Float(floor) * (storey + t)   // (each storey on the slab under it)
                let walls: [(String, SIMD3<Float>, SIMD3<Float>)] = [
                    ("front", [0, y + storey / 2, d], [w, storey / 2, t / 2]), ("back", [0, y + storey / 2, -d], [w, storey / 2, t / 2]),
                    ("left", [-w + t / 2, y + storey / 2, 0], [t / 2, storey / 2, d - t / 2]),
                    ("right", [w - t / 2, y + storey / 2, 0], [t / 2, storey / 2, d - t / 2]),
                ]
                for (k, (side, at, half)) in walls.enumerated() {
                    panel.seed = 101 + UInt64(n) * 1000 + UInt64(floor * 8 + k)
                    fractured("\(name)/Floor \(floor + 1) \(side)", shape: SDFShape(.box(halfExtents: half)), recipe: panel,
                              transform: translate(centre + at - [0, 0.001, 0]), material: concrete, interior: concreteInside,
                              anchor: floor == 0 ? .ground(0) : .none, toughness: tough, strength: strong * buildingStrength)
                }
                var slab = panel
                slab.seed = 201 + UInt64(n) * 1000 + UInt64(floor)
                fractured("\(name)/Floor \(floor + 1) slab", shape: SDFShape(.box(halfExtents: [w, t / 2, d + t / 2])), recipe: slab,
                          transform: translate(centre + [0, y + storey + t / 2, 0]), material: concrete, interior: concreteInside,
                          anchor: .none, toughness: tough, strength: strong * buildingStrength)
            }
            }
        }

        // The wrecking ball: a steel ball on a rod, hinged under a gantry, held back toward the camera (asleep) until
        // the demo wakes it.
        section("Wrecking ball")
        let mountAt = SIMD3<Float>(wallAt.x, 6.8, -2.55), rope: Float = 4.7
        fixed(SDFShape(.box(halfExtents: [1.6, 0.12, 0.12])), iron, translate(mountAt + [0, 0.15, 0]))
        for side: Float in [-1, 1] {
            fixed(SDFShape(.box(halfExtents: [0.1, (mountAt.y + 0.27) / 2, 0.1])), iron,
                  translate([mountAt.x + side * 1.5, (mountAt.y + 0.27) / 2, mountAt.z + 1.4]))
            fixed(SDFShape(.box(halfExtents: [0.08, 0.08, 0.75])), iron, translate([mountAt.x + side * 1.5, mountAt.y + 0.15, mountAt.z + 0.7]))
        }
        let mount = world.bodies.count
        addBody(sdf: addSDFShape(SDFShape(.sphere(radius: 0.03))), iron, translate(mountAt), density: 1000)
        world.bodies[mount].position.w = 0   // held where it is
        world.bodies[mount].invInertia = SIMD4(.zero, world.bodies[mount].invInertia.w)
        let ballShape = SDFShape([SDFShape.Node(.sphere(radius: 0.48)),
                                  SDFShape.Node(.capsule(halfLength: rope / 2, radius: 0.025), at: [0, rope / 2, 0])])
        let back: Float = -1.05   // radians toward the camera
        let ball = world.bodies.count
        addBody(sdf: addSDFShape(ballShape), steel, translate(mountAt) * rotate(back, [1, 0, 0]) * translate([0, -rope, 0]),
                density: 1800, friction: 0.4, restitution: 0.05)
        world.addJoint(mount, ball, at: mountAt, axis: [1, 0, 0], reference: [0, 0, 1], .hinge(-2.2...2.2), damping: 0.05)
        world.startAsleep(ball)

        // The weight over the tower, held up asleep.
        section("Weight")
        let weight = world.bodies.count
        addBody(sdf: addSDFShape(SDFShape(.box(halfExtents: [0.3, 0.3, 0.3], rounding: 0.03))), iron, translate([7.3, 7.2, -5.4]),
                density: 2600, friction: 0.5, restitution: 0.05)
        world.startAsleep(weight)

        // Cannonballs for the demo, and the pool of balls the Shoot tool fires: disabled until they are.
        section("Shots")
        let shot = addSDFShape(SDFShape(.sphere(radius: 0.17)))
        var rig = DestructionRig()
        rig.objects = made
        rig.recipes = bases
        // The Fracture Editor's preview: one object's pieces held apart, nothing else breaking.
        let preview = settings.preview.flatMap { p in made.first { $0.name == p.object }.map { (p, $0) } }
        if let (p, f) = preview { world.preview(f.tree, first: f.firstBody, level: p.level, explode: p.explode) }
        for _ in 0..<(DestructionRig.scripted + DestructionRig.poolSize) {
            let b = world.bodies.count
            addBody(sdf: shot, iron, translate([0, -50, 0]), density: 7000, friction: 0.4, restitution: 0.1)
            world.disable(b)
            rig.shots.append(b)
        }
        destructionRig = rig

        if settings.demo && preview == nil && settings.massive {
            // The building's ground floor blasted at its corners, the front left and the back right first, then the
            // others: the storeys above lose their footing and come down.
            let step = { (t: Float) in Int(t / PhysicsWorld.stepLength) }
            for centre in Scene.buildingCentres(settings.buildings) {
                for (x, z, t) in [(Float(-3), Float(-12.2), Float(2.5)), (3, -17.8, 2.5), (3, -12.2, 3.5), (-3, -17.8, 3.5)] {
                    world.command(.blast, origin: [centre + x, 1, z], radius: 2.2, magnitude: 14, at: step(t), steps: 6)
                }
            }
        }
        if settings.demo && preview == nil {
            let step = { (t: Float) in Int(t / PhysicsWorld.stepLength) }
            world.command(.wake, body: ball, at: step(2))
            world.command(.wake, body: weight, at: step(6))
            let from = SIMD3<Float>(0.5, 1.6, 8)
            for (k, (t, target)) in [(Float(3.4), SIMD3<Float>(-1.8, 1.05, -0.6)), (4.6, [1.7, 0.8, -5.2]), (8.2, [5.4, 1.2, -2.2]), (10.5, [2.6, 1.1, 1.4])].enumerated() {
                let (dir, speed) = Scene.aim(from: from, at: target, speed: DestructionRig.shotSpeed, gravity: world.gravity.y)
                world.command(.shoot, body: rig.shots[k], origin: from, direction: dir, magnitude: speed, at: step(t))
            }
        }
        destructionRig?.nextShot = 0

        if settings.dust {
            destructionRig?.dustProxies = addDestructionDust(kit, interiors: [.concrete: concreteInside, .stone: marbleInside,
                                                                              .brick: brickInside, .wood: woodInside, .glass: glassInside])
        }

        // The afternoon sun from the front left, a blue sky.
        section("Sun")
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1.0, 0.95, 0.88]) { _ in
            let e = Scene.degrees(38), az: Float = -0.55
            return LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)], scale: SIMD3(repeating: 1.5))
        }
        skyAnimation = { _ in SIMD3<Float>(0.3, 0.45, 0.8) * 0.24 }
        defaultCamera = Scene.demoCamera(.destruction)!
        if settings.massive { defaultCamera = Scene.camera([0, 5.5, 15], pitch: -0.14) }
    }

    /// Dust and debris where pieces break (Physics+Fracture.swift's break events, ParticlesGPU.breakRing): per material
    /// a proxy emitter that spawns nothing of its own, whose events are the breaks, and its children: a puff of dust
    /// (none for glass) and chunks of the broken inside that tumble and bounce. Returns the proxies by material.
    func addDestructionDust(_ kit: Kit, interiors: [FractureMaterial: Int]) -> [UInt32] {
        var emitters: [ParticleEmitter] = []
        var proxies = [UInt32](repeating: ParticleSystem.none, count: FractureMaterial.allCases.count)
        for material in FractureMaterial.allCases {
            guard let inside = interiors[material] else { continue }
            var proxy = ParticleEmitter("\(material.title) breaks", capacity: 128, at: .zero)
            proxy.lifetime = 0.01...0.01
            proxy.castsShadows = false
            proxies[material.rawValue] = UInt32(emitters.count)
            let p = emitters.count
            emitters.append(proxy)
            let (colour, amount) = material.dust
            if amount > 0 {
                var dust = ParticleEmitter("\(material.title) dust", capacity: Int(2400 * amount), at: .zero)
                dust.parent = p
                dust.trigger = .condition   // (raised by the physics: as many as its pool, not a parent's deaths)
                dust.perEvent = 8
                dust.inherit = 0.15
                dust.shape = .sphere(radius: 0.3)
                dust.speed = 0.2...0.9
                dust.radial = true
                dust.lifetime = 2.5...5
                dust.gravity = -0.03
                dust.drag = 1.4
                dust.curl = 0.25
                dust.curlFrequency = 0.8
                dust.curlSpeed = 0.3
                dust.bakedCurl = true
                dust.size = (0.18, 0.9)
                dust.sizeJitter = 0.4
                let light = simd_min(colour * 1.6, SIMD3(repeating: 1))   // (a cloud of it scatters light: paler than the stone)
                dust.colors = (SIMD4(light, 0.45 * amount), SIMD4(light, 0.3 * amount), SIMD4(light, 0))
                dust.midpoint = 0.25
                dust.atlas = .smoke
                dust.frames = 64
                dust.randomFrame = true
                dust.spin = 0.5
                dust.soft = 0.15
                dust.shadowDensity = 0.35
                emitters.append(dust)
            }
            var debris = ParticleEmitter("\(material.title) debris", capacity: material == .glass ? 900 : 1500, at: .zero)
            debris.parent = p
            debris.trigger = .condition
            debris.perEvent = 8
            debris.inherit = 0.6
            debris.shape = .sphere(radius: 0.15)
            debris.speed = material == .glass ? 1...3 : 1.2...3.8
            debris.radial = true
            debris.velocity = [0, 1, 0]
            debris.lifetime = 3.5...6
            debris.collidesWithScene = true
            debris.restitution = material == .glass ? 0.25 : 0.2
            debris.friction = 0.6
            debris.mesh = (kit.cube, inside)
            let chunk: Float = material == .glass ? 0.02 : 0.035
            debris.size = (chunk, chunk)
            debris.sizeJitter = 0.6
            debris.collisionRadius = chunk * 0.5
            debris.spin = 9
            emitters.append(debris)
        }
        addParticles(ParticleSystem(emitters: emitters))
        return proxies
    }
}
