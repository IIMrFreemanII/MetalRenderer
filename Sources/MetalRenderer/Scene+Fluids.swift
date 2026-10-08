import Foundation
import simd

/// The fluids scene: a tray on the studio floor in three lanes, water, blood and honey (`PhysicsSettings.liquids`: one
/// of them alone), each poured from a nozzle above three steps at the lane's back, down the steps and into its basin.
/// Over each basin two boxes held up and dropped once the liquid is there (a box on the floor as it rose round it
/// wouldn't float: nothing gets under it): a light one at 4 s that floats, a heavy one at 5 s that sinks (slowly in
/// honey); a heavy one on the middle step that the flow pushes; and in front of the tray a paddle to stir with (the mouse).
extension Scene {
    /// A lane's inside: 0.6 m across, 0.9 m deep (the steps take its back half), 1 m up to where its liquid can go.
    static let fluidLane = SIMD3<Float>(0.6, 1.0, 0.9)
    static let fluidWall: Float = 0.04, fluidRim: Float = 0.2, fluidTrayZ: Float = -0.45

    func buildFluids(_ physics: PhysicsSettings) {
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
            addStaticCollider(sdf: s, transform, friction: 0.6, restitution: 0.1)
        }

        let kinds: [LiquidKind] = switch physics.liquids {
        case .all: [.water, .blood, .honey]
        case .water: [.water]
        case .blood: [.blood]
        case .honey: [.honey]
        }
        let lane = Scene.fluidLane, t = Scene.fluidWall, rim = Scene.fluidRim, z0 = Scene.fluidTrayZ
        let width = Float(kinds.count) * lane.x + Float(kinds.count + 1) * t
        // The tray's walls: front, back, the two ends, and the dividers between the lanes.
        let tray = addPBRMaterial(baseColor: [0.85, 0.85, 0.83], metallic: 0, roughness: 0.4)
        let long = SDFShape(.box(halfExtents: [width / 2, rim / 2, t / 2], rounding: 0.01))
        let across = SDFShape(.box(halfExtents: [t / 2, rim / 2, lane.z / 2], rounding: 0.01))
        fixed(long, tray, translate([0, rim / 2, z0 + lane.z / 2 + t / 2]))
        fixed(long, tray, translate([0, rim / 2, z0 - lane.z / 2 - t / 2]))
        for k in 0...kinds.count {
            fixed(across, tray, translate([-width / 2 + t / 2 + Float(k) * (lane.x + t), rim / 2, z0]))
        }

        let stone = addPBRMaterial(baseColor: [0.55, 0.52, 0.48], metallic: 0, roughness: 0.6)
        let light = addPBRMaterial(baseColor: [0.95, 0.75, 0.3], metallic: 0, roughness: 0.4)
        let heavy = addPBRMaterial(baseColor: [0.25, 0.3, 0.4], metallic: 0, roughness: 0.35)
        let wood = addPBRMaterial(baseColor: [0.75, 0.55, 0.35], metallic: 0, roughness: 0.6)
        let steel = addPBRMaterial(baseColor: [0.5, 0.52, 0.55], metallic: 0, roughness: 0.3)
        let lightBox = addSDFShape(SDFShape(.box(halfExtents: [0.05, 0.05, 0.05], rounding: 0.008)))
        let heavyBox = addSDFShape(SDFShape(.box(halfExtents: [0.045, 0.045, 0.045], rounding: 0.008)))
        let paddle = addSDFShape(SDFShape(.capsule(halfLength: 0.3, radius: 0.025)))
        let rise: Float = 0.08, run: Float = 0.15, back = z0 - lane.z / 2
        for (k, kind) in kinds.enumerated() {
            let x = -width / 2 + t + lane.x / 2 + Float(k) * (lane.x + t)
            // Three steps at the back, the top one 0.24 m up.
            for s in 0..<3 {
                let height = rise * Float(3 - s)
                fixed(SDFShape(.box(halfExtents: [lane.x / 2, height / 2, run / 2], rounding: 0.005)), stone,
                      translate([x, height / 2, back + run * (Float(s) + 0.5)]))
            }
            let nozzle = SIMD3<Float>(x - 0.1, 3 * rise + 0.3, back + 0.5 * run)
            // The pipe the liquid comes out of.
            let pipe = addSDFShape(SDFShape(.cylinder(halfHeight: 1.0, radius: kind.physics.nozzleRadius + 0.012, rounding: 0.004)))
            addInstance(sdf: pipe, steel, translate(nozzle + SIMD3(0, 1.01, 0)))
            // The boxes held over the basin, a heavy one on the middle step in the flow's way, a paddle in front.
            addBody(sdf: lightBox, light, translate([x + 0.13, 0.4, z0 + 0.22]), density: 250, friction: 0.5, restitution: 0.1)
            holdBody(until: 4)
            addBody(sdf: heavyBox, heavy, translate([x - 0.12, 0.45, z0 + 0.28]), density: 2000, friction: 0.5, restitution: 0.1)
            holdBody(until: 5)
            addBody(sdf: heavyBox, heavy, translate([x + 0.05, 2 * rise + 0.046, back + 1.5 * run]), density: 2000, friction: 0.5,
                    restitution: 0.1)
            addBody(sdf: paddle, wood, translate([x, 0.026, z0 + lane.z / 2 + t + 0.15]) * rotate(.pi / 2, [0, 0, 1]), density: 600,
                    friction: 0.6, restitution: 0.1)
            let solver: PhysicsSettings.Solver = switch physics.solver {
            case .pbf: .pbf
            case .mpm: .mpm
            case .auto: kind == .water ? physics.waterSolver : kind == .blood ? physics.bloodSolver : physics.honeySolver
            }
            addLiquid(kind, solver: solver, domain: AABB(lo: [x - lane.x / 2, 0, z0 - lane.z / 2], hi: [x + lane.x / 2, lane.y, z0 + lane.z / 2]),
                      nozzle: nozzle, capacity: physics.fluidParticles)
        }

        addLight(.rect(width: 4, height: 2), color: SIMD3<Float>(1.0, 0.96, 0.9) * 4, motion: .constant) { _ in
            LightPose(position: [0, 5.97, -0.5], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        for (colour, position) in [(SIMD3<Float>(1.0, 0.8, 0.6), SIMD3<Float>(-3.5, 3.0, 3)), (SIMD3<Float>(0.7, 0.85, 1.0), SIMD3<Float>(3.5, 3.5, -2))] {
            addLight(.sphere(radius: 0.1), color: colour * 5, proxyMesh: kit.sphere, motion: .constant) { _ in LightPose(position: position) }
        }
        defaultCamera = Scene.demoCamera(.fluids)!
    }
}
