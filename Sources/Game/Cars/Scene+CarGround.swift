import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Physics
import Plants
import simd
import MetalRenderer

/// The car scene: a test ground to drive and crash node-beam cars on (Physics+Cars.swift; the player is CarPlayer):
/// a wide asphalt plain with a concrete wall at the end of the run-up, a row of steel poles, a line of jersey barriers,
/// two ramps, speed bumps leading to a brick wall and a concrete one that break (fractured objects: Scene+Fracture.swift),
/// a slalom of cones, barrels and a stack of crates (loose bodies), and the other styles parked in a lot behind barriers.
extension Scene {
    /// Where the wall's face is (z), and how far the panels can get.
    static let carWallZ: Float = 40
    static let carGroundBounds = AABB(lo: [-250, -5, -250], hi: [250, 40, 250])
    /// The autopilot laps' centre (x, z), and the first lap's radius and the room between laps (m).
    static let carLapCentre = SIMD2<Float>(0, -90), carLapRadius: Float = 24, carLapSpacing: Float = 7

    func buildCarGround(_ settings: CarSettings) {
        let kit = Kit(self)
        let world = physicsWorld()
        let asphalt = addPBRMaterial(baseColor: [0.11, 0.11, 0.115], metallic: 0, roughness: 0.85)
        let paint = addPBRMaterial(baseColor: [0.85, 0.82, 0.7], metallic: 0, roughness: 0.6)
        let concrete = addPBRMaterial(baseColor: [0.52, 0.51, 0.48], metallic: 0, roughness: 0.9)
        let steel = addPBRMaterial(baseColor: [0.6, 0.6, 0.62], metallic: 0.9, roughness: 0.35)
        let barrier = addPBRMaterial(baseColor: [0.75, 0.74, 0.7], metallic: 0, roughness: 0.8)
        let stripe = addPBRMaterial(baseColor: [0.8, 0.12, 0.08], metallic: 0, roughness: 0.6)

        section("Ground")
        addInstance(kit.quad, asphalt, scale([500, 1, 500]))
        addStaticPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        // The run-up's lines, and the lap circle's centre mark.
        for x: Float in [-3.5, 3.5] { addInstance(kit.quad, paint, translate([x, 0.002, 10]) * scale([0.12, 1, 60])) }

        section("Obstacles")
        // The wall: concrete, 16 m across, 2.5 m high, 1 m thick.
        let wallHalf = SIMD3<Float>(8, 1.25, 0.5)
        kit.box([0, wallHalf.y, Scene.carWallZ + wallHalf.z], wallHalf * 2, concrete)
        addStaticBox([-wallHalf.x, 0, Scene.carWallZ], [wallHalf.x, 2 * wallHalf.y, Scene.carWallZ + 2 * wallHalf.z])
        // Steel poles along the left of the run-up.
        let poleShape = addSDFShape(SDFShape(.cylinder(halfHeight: 1.5, radius: 0.15)))
        for k in 0..<6 {
            let at = SIMD3<Float>(-12, 1.5, 4 + Float(k) * 7)
            addInstance(sdf: poleShape, steel, translate(at))
            addStaticCollider(sdf: poleShape, translate(at), friction: 0.5, restitution: 0.1)
        }
        // Jersey barriers along the right, and round the parking lot.
        let barrierShape = addSDFShape(SDFShape(.box(halfExtents: [0.3, 0.4, 1.6], rounding: 0.12)))
        func barrierAt(_ x: Float, _ z: Float, yaw: Float = 0) {
            let m = translate([x, 0.4, z]) * float4x4(simd_quatf(angle: yaw, axis: [0, 1, 0]))
            addInstance(sdf: barrierShape, barrier, m)
            addStaticCollider(sdf: barrierShape, m, friction: 0.6, restitution: 0.1)
        }
        for k in 0..<8 { barrierAt(12, -2 + Float(k) * 3.3) }
        // Ramps: 10 and 20 degrees, 4 m wide, up to a lip.
        let rampShape = addSDFShape(SDFShape(.box(halfExtents: [2, 0.15, 3.5])))
        for (z, degrees) in [(Float(5), Float(10)), (25, 20)] {
            let angle = degrees * .pi / 180
            let m = translate([-30, 3.5 * sin(angle) - 0.15 * cos(angle), z]) * float4x4(simd_quatf(angle: -angle, axis: [1, 0, 0]))
            addInstance(sdf: rampShape, concrete, m)
            addStaticCollider(sdf: rampShape, m, friction: 0.7, restitution: 0.05)
            addInstance(kit.cube, stripe, m * translate([0, 0.151, 3.3]) * scale([4, 0.002, 0.3]))
        }
        // Speed bumps across a lane on the right: half-buried cylinders.
        let bumpShape = addSDFShape(SDFShape(.cylinder(halfHeight: 2, radius: 0.3)))
        for k in 0..<3 {
            let m = translate([22, -0.22, 6 + Float(k) * 9]) * float4x4(simd_quatf(angle: .pi / 2, axis: [0, 0, 1]))
            addInstance(sdf: bumpShape, stripe, m)
            addStaticCollider(sdf: bumpShape, m, friction: 0.7, restitution: 0.05)
        }

        section("Breakables")
        // At the end of the speed bumps' lane: a brick wall, then a concrete one, standing on the ground (anchored: they
        // move only once broken).
        let brick = addPBRMaterial(baseColor: [0.46, 0.17, 0.1], metallic: 0, roughness: 0.82)
        let brickInside = addPBRMaterial(baseColor: [0.55, 0.28, 0.18], metallic: 0, roughness: 0.95)
        let wallConcrete = addPBRMaterial(baseColor: [0.34, 0.33, 0.31], metallic: 0, roughness: 0.88)
        let concreteInside = addPBRMaterial(baseColor: [0.5, 0.48, 0.44], metallic: 0, roughness: 0.97)
        var bricks = FractureRecipe.defaults(.brick)
        bricks.seed = 21
        bricks.brick = [0.4, 0.16, 0.22]
        _ = addFractured("Brick wall", shape: SDFShape(.box(halfExtents: [1.6, 0.88, 0.11])), recipe: bricks, transform: translate([22, 0.88, 34]),
                         material: brick, interior: brickInside, anchor: .ground(0))
        var slab = FractureRecipe.defaults(.concrete)
        slab.seed = 11
        _ = addFractured("Concrete wall", shape: SDFShape(.box(halfExtents: [1.7, 1.25, 0.15])), recipe: slab, transform: translate([22, 1.25, 46]),
                         material: wallConcrete, interior: concreteInside, anchor: .ground(0))

        section("Props")
        // A slalom of cones up the middle, barrels by the run-up's end, a stack of crates on the left.
        let orange = addPBRMaterial(baseColor: [0.9, 0.32, 0.06], metallic: 0, roughness: 0.55)
        let drum = addPBRMaterial(baseColor: [0.12, 0.25, 0.55], metallic: 0.6, roughness: 0.4)
        let wood = addPBRMaterial(baseColor: [0.55, 0.4, 0.22], metallic: 0, roughness: 0.8)
        let cone = addSDFShape(SDFShape(.cone(halfHeight: 0.35, bottom: 0.18, top: 0.03)))
        let barrel = addSDFShape(SDFShape(.cylinder(halfHeight: 0.44, radius: 0.29, rounding: 0.02)))
        let crate = addSDFShape(SDFShape(.box(halfExtents: [0.4, 0.4, 0.4], rounding: 0.02)))
        for k in 0..<8 { addBody(sdf: cone, orange, translate([6 + (k % 2 == 0 ? -0.6 : 0.6), 0.35, 8 + Float(k) * 3]), density: 300, friction: 0.8, restitution: 0.1) }
        for k in 0..<6 {
            addBody(sdf: barrel, drum, translate([5 + Float(k % 3) * 0.62, 0.44, 32 + Float(k / 3) * 0.62]), density: 400, friction: 0.5, restitution: 0.1)
        }
        for k in 0..<6 {
            let (row, column) = (k < 3 ? 0 : 1, k < 3 ? k : k - 3)
            addBody(sdf: crate, wood, translate([-6 + Float(column) * 0.82 + Float(row) * 0.41, 0.4 + Float(row) * 0.8, 30]), density: 500, friction: 0.6,
                    restitution: 0.05)
        }

        // Two paint samples by the start: clear-coated (the cars': addPaintMaterial) and plain metallic.
        let sample = addSDFShape(SDFShape(.sphere(radius: 0.6)))
        for (z, material) in [(Float(-5), addPaintMaterial(colour: [0.62, 0.05, 0.04])),
                              (-7, addPBRMaterial(baseColor: [0.62, 0.05, 0.04], metallic: 0.45, roughness: 0.22))] {
            addInstance(sdf: sample, material, translate([-3.2, 0.6, z]))
            addStaticCollider(sdf: sample, translate([-3.2, 0.6, z]), friction: 0.5, restitution: 0.1)
        }

        // The cars: the player's at the start of the run-up (or on the first lap), the others parked in the lot (or on
        // laps further out).
        let styles = CarStyle.allCases
        var rig = CarRig()
        for k in 0..<max(settings.cars, 1) {
            var spec = Scene.carSpec(styles[(settings.style.rawValue + k) % styles.count])
            spec.assists = settings.assists
            var place = translate([Float(k / 4) * 7 + 30, 0, -18 - Float(k % 4) * 6]) * float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
            var velocity = SIMD3<Float>()
            switch settings.demo {
            case .none:
                if k == 0 { place = translate([0, 0, -8]) }
            case .wall:
                if k == 0 {
                    // Far enough back to be at speed and settled, near enough to hit the wall a second after the start.
                    place = translate([0, 0, Scene.carWallZ - spec.frontOverhang - spec.wheelbase / 2 - 14])
                    velocity = [0, 0, settings.demoSpeed / 3.6]
                }
            case .headOn:
                // The two on the run-up's line, 28 m apart, toward each other: they meet about 0.8 s after the start.
                if k == 0 { place = translate([0, 0, -6]) }
                if k == 1 { place = translate([0, 0, 22]) * float4x4(simd_quatf(angle: .pi, axis: [0, 1, 0])) }
                if k < 2 { velocity = (k == 0 ? 1 : -1) * SIMD3(0, 0, settings.demoSpeed / 3.6) }
            case .breakables:
                // In the speed bumps' lane past the last bump, toward the brick wall (the concrete one behind it).
                if k == 0 {
                    place = translate([22, 0, 27])
                    velocity = [0, 0, settings.demoSpeed / 3.6]
                }
            case .props:
                // Toward the stack of crates on the left.
                if k == 0 {
                    place = translate([-5.6, 0, 20])
                    velocity = [0, 0, settings.demoSpeed / 3.6]
                }
            case .laps:
                let radius = Scene.carLapRadius + Float(k) * Scene.carLapSpacing
                let angle = Float(k) * 0.9
                let at = Scene.carLapCentre + SIMD2(cos(angle), sin(angle)) * radius
                let tangent = SIMD2(-sin(angle), cos(angle))
                place = translate([at.x, 0, at.y]) * float4x4(simd_quatf(angle: atan2(tangent.x, tangent.y), axis: [0, 1, 0]))
            }
            guard let car = addCar(spec, place, velocity: velocity, bounds: Scene.carGroundBounds, name: "\(spec.style.title) \(k + 1)") else {
                print("Cars: no model for \(spec.style.title): \(CarPack.entry(spec.style).file) in Assets (Git LFS) isn't there")
                continue
            }
            rig.cars.append(car)
            if settings.demo == .laps {
                var input = CarInput()
                input.autopilot = true
                input.lap = SIMD4(Scene.carLapCentre.x, Scene.carLapCentre.y, Scene.carLapRadius + Float(k) * Scene.carLapSpacing, 15)
                world.add(PhysicsWorld.carCommand(car.car, input, at: 0))
            }
        }
        // The lot's fence (in front of the parked cars).
        if settings.demo != .laps && settings.cars > 1 {
            for k in 0..<7 { barrierAt(25, -14 - Float(k) * 3.3) }
            for k in 0..<5 { barrierAt(27 + Float(k) * 3.3, -11.5, yaw: .pi / 2) }
        }
        world.keepBuiltCommands()
        rig.player = 0
        rig.packTextures = carRig.packTextures
        // The walls' dust (by material: CarRig.breakProxies' first 8) and the cars' (from CarEvent.firstSlot), one system.
        var emitters: [ParticleEmitter] = []
        var proxies = destructionDust(kit, interiors: [.brick: brickInside, .concrete: concreteInside], into: &emitters)
        proxies += [UInt32](repeating: ParticleSystem.none, count: Int(CarEvent.firstSlot) - proxies.count)
        proxies += carDust(kit, into: &emitters)
        addParticles(ParticleSystem(emitters: emitters))
        rig.breakProxies = proxies
        carRig = rig

        section("Sun")
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1.0, 0.95, 0.88]) { _ in
            let e = Scene.degrees(42), az: Float = 0.7
            return LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)], scale: SIMD3(repeating: 1.5))
        }
        skyAnimation = { _ in SIMD3<Float>(0.3, 0.45, 0.8) * 0.24 }
        defaultCamera = settings.demo == .laps ? Scene.camera([0, 38, -30], pitch: -0.75) : Scene.camera([7, 3.2, -16], yaw: -0.35, pitch: -0.12)
    }
}
