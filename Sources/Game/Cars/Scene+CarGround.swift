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
/// two ramps, speed bumps, and the other styles parked in a lot fenced off by barriers (cars don't meet cars yet).
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

        // Two paint samples by the start: clear-coated (the cars': addPaintMaterial) and plain metallic.
        let sample = addSDFShape(SDFShape(.sphere(radius: 0.6)))
        for (z, material) in [(Float(-5), addPaintMaterial(colour: [0.62, 0.05, 0.04])),
                              (-7, addPBRMaterial(baseColor: [0.62, 0.05, 0.04], metallic: 0.45, roughness: 0.22))] {
            addInstance(sdf: sample, material, translate([-3.2, 0.6, z]))
            addStaticCollider(sdf: sample, translate([-3.2, 0.6, z]), friction: 0.5, restitution: 0.1)
        }

        // The cars: the player's at the start of the run-up (or on the first lap), the others parked in the lot (or on
        // laps further out).
        let colours: [SIMD3<Float>] = [[0.62, 0.05, 0.04], [0.05, 0.16, 0.42], [0.85, 0.85, 0.82], [0.08, 0.08, 0.09], [0.9, 0.55, 0.06],
                                       [0.12, 0.35, 0.18], [0.45, 0.47, 0.5], [0.55, 0.1, 0.35]]
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
            case .laps:
                let radius = Scene.carLapRadius + Float(k) * Scene.carLapSpacing
                let angle = Float(k) * 0.9
                let at = Scene.carLapCentre + SIMD2(cos(angle), sin(angle)) * radius
                let tangent = SIMD2(-sin(angle), cos(angle))
                place = translate([at.x, 0, at.y]) * float4x4(simd_quatf(angle: atan2(tangent.x, tangent.y), axis: [0, 1, 0]))
            }
            let car = addCar(spec, paint: colours[k % colours.count], place, velocity: velocity, bounds: Scene.carGroundBounds, name: "\(spec.style.title) \(k + 1)")
            rig.cars.append(car)
            if settings.demo == .laps {
                var input = CarInput()
                input.autopilot = true
                input.lap = SIMD4(Scene.carLapCentre.x, Scene.carLapCentre.y, Scene.carLapRadius + Float(k) * Scene.carLapSpacing, 15)
                world.add(PhysicsWorld.carCommand(car.car, input, at: 0))
            }
        }
        // The lot's fence (behind it the parked cars: they don't meet the player's).
        if settings.demo != .laps && settings.cars > 1 {
            for k in 0..<7 { barrierAt(25, -14 - Float(k) * 3.3) }
            for k in 0..<5 { barrierAt(27 + Float(k) * 3.3, -11.5, yaw: .pi / 2) }
        }
        world.keepBuiltCommands()
        rig.player = 0
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
