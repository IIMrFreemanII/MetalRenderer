import EngineCore
import Foundation
import simd

/// A car's body style (CarSpec.preset).
package enum CarStyle: Int, CaseIterable, Codable {
    case sedan, hatchback, pickup, coupe

    package var title: String { ["Sedan", "Hatchback", "Pickup", "Sports coupe"][rawValue] }
}

/// Which wheels the engine turns.
package enum CarDrive: Int, Codable {
    case front, rear, all
}

/// What a car is made of (CarBlueprint builds its nodes and beams from it, CarSurface its panels): its body's profile
/// and its mechanics.
///
/// Car space: x across (+x is the car's left), y up, z forward (the front bumper at +z), the origin on the ground
/// midway between the axles. The body's profile is a few key heights along z (the bumpers', the hood's, the roof's,
/// the trunk's), joined by straight lines and rounded (`topHeight`): the same function places the nodes and the
/// panels, so the panels lie on the node hull they are embedded in.
package struct CarSpec: Equatable {
    package var style: CarStyle
    // The body (m).
    package var length: Float
    package var width: Float
    package var wheelbase: Float
    package var track: Float
    /// Front axle to front bumper.
    package var frontOverhang: Float
    /// The floor's height, the belt line's (where the doors meet the windows), the roof's, and the roof's width as a
    /// share of the body's.
    package var sill: Float
    package var belt: Float
    package var roof: Float
    package var roofShare: Float = 0.8
    /// The hood's height at the front bumper and at the windshield's base (the cowl), the trunk's at the rear.
    package var deckFront: Float
    package var cowl: Float
    package var deckRear: Float
    /// Where (z) the windshield starts and meets the roof, and the roof ends and the rear window does.
    package var windshieldBase: Float
    package var roofFront: Float
    package var roofRear: Float
    package var rearWindowBase: Float

    // Masses (kg): the whole car (wheels included), its engine.
    package var mass: Float
    package var engineMass: Float = 150

    // Wheels, suspension, tyres.
    package var wheelRadius: Float = 0.316
    package var wheelWidth: Float = 0.205
    package var wheelMass: Float = 20
    package var wheelInertia: Float = 0.9
    /// Spring rate at the wheel (N/m), damper (N s/m), travel each way from the ride height (m).
    package var spring: Float = 30_000
    package var damper: Float = 1_900
    package var travel: Float = 0.12
    /// The tyre's radial stiffness (N/m) and damping (N s/m), and its grip (the road's friction with it).
    package var tyreStiffness: Float = 220_000
    package var tyreDamping: Float = 400
    package var grip: Float = 1

    // Engine and drivetrain.
    /// Idle and the rev limiter (rpm); torque (N m) at rpm points, eight of them, rising.
    package var idle: Float = 850
    package var limiter: Float = 6_700
    package var torqueCurve: [SIMD2<Float>] = [[1000, 180], [2000, 220], [3000, 250], [4000, 265], [5000, 255], [6000, 230],
                                               [6500, 200], [7000, 120]]
    package var engineInertia: Float = 0.15
    package var gears: [Float] = [3.5, 2.1, 1.4, 1.0, 0.8]
    package var reverse: Float = 3.2
    package var finalDrive: Float = 3.9
    package var drive = CarDrive.rear
    /// A limited-slip differential's locking: its torque as a share of what goes through it (0: open).
    package var limitedSlip: Float = 0
    /// Brake torques (N m a wheel): front, rear, the handbrake's (rear).
    package var frontBrake: Float = 1_800
    package var rearBrake: Float = 900
    package var handbrake: Float = 1_500
    /// The front wheels' most steer (rad) and how fast the steering turns (rad/s).
    package var steer: Float = 35 * .pi / 180
    package var steerRate: Float = 3
    /// Drag coefficient x frontal area (m^2).
    package var dragArea: Float = 0.7
    /// Traction control and ABS (CarTune.assists).
    package var assists = true

    package var frontAxle: Float { wheelbase / 2 }
    package var rearAxle: Float { -wheelbase / 2 }
    package var frontEnd: Float { wheelbase / 2 + frontOverhang }
    package var rearEnd: Float { frontEnd - length }
    package var peakTorque: Float { torqueCurve.map(\.y).max() ?? 0 }

    package static func preset(_ style: CarStyle) -> CarSpec {
        switch style {
        case .sedan:
            return CarSpec(style: style, length: 4.7, width: 1.82, wheelbase: 2.75, track: 1.56, frontOverhang: 0.95, sill: 0.2, belt: 0.93,
                           roof: 1.44, deckFront: 0.8, cowl: 0.98, deckRear: 0.98, windshieldBase: 0.8, roofFront: -0.05, roofRear: -1.05,
                           rearWindowBase: -1.7, mass: 1350)
        case .hatchback:
            var s = CarSpec(style: style, length: 4.1, width: 1.76, wheelbase: 2.55, track: 1.52, frontOverhang: 0.85, sill: 0.19, belt: 0.92,
                            roof: 1.46, deckFront: 0.8, cowl: 0.97, deckRear: 1.0, windshieldBase: 0.75, roofFront: -0.1, roofRear: -1.5,
                            rearWindowBase: -1.85, mass: 1150)
            s.engineMass = 120
            s.drive = .front
            s.torqueCurve = s.torqueCurve.map { SIMD2($0.x, $0.y * 0.755) }
            s.wheelRadius = 0.3
            s.wheelWidth = 0.195
            s.spring = 26_000
            s.damper = 1_700
            s.frontBrake = 1_600
            s.rearBrake = 700
            s.dragArea = 0.66
            return s
        case .pickup:
            var s = CarSpec(style: style, length: 5.0, width: 1.95, wheelbase: 3.0, track: 1.66, frontOverhang: 0.95, sill: 0.34, belt: 1.15,
                            roof: 1.84, deckFront: 1.05, cowl: 1.2, deckRear: 1.12, windshieldBase: 0.85, roofFront: 0.15, roofRear: -0.75,
                            rearWindowBase: -0.85, mass: 2000)
            s.roofShare = 0.86
            s.engineMass = 220
            s.drive = .all
            s.torqueCurve = [[1000, 300], [1500, 360], [2500, 400], [3500, 390], [4500, 340], [5200, 280], [5600, 200], [6000, 100]]
            s.idle = 750
            s.limiter = 5_400
            s.engineInertia = 0.25
            s.gears = [3.8, 2.3, 1.5, 1.1, 0.85]
            s.finalDrive = 3.7
            s.wheelRadius = 0.38
            s.wheelWidth = 0.255
            s.wheelMass = 28
            s.wheelInertia = 1.6
            s.spring = 45_000
            s.damper = 3_000
            s.travel = 0.16
            s.tyreStiffness = 280_000
            s.tyreDamping = 600
            s.frontBrake = 2_600
            s.rearBrake = 1_400
            s.handbrake = 2_000
            s.dragArea = 1.05
            return s
        case .coupe:
            var s = CarSpec(style: style, length: 4.5, width: 1.88, wheelbase: 2.65, track: 1.6, frontOverhang: 1.0, sill: 0.15, belt: 0.85,
                            roof: 1.28, deckFront: 0.7, cowl: 0.92, deckRear: 0.92, windshieldBase: 0.6, roofFront: -0.35, roofRear: -0.95,
                            rearWindowBase: -1.75, mass: 1400)
            s.roofShare = 0.75
            s.limitedSlip = 0.35
            s.torqueCurve = [[1000, 220], [2000, 300], [3000, 370], [4500, 420], [5500, 410], [6500, 380], [7500, 330], [8000, 150]]
            s.limiter = 7_500
            s.gears = [3.2, 2.2, 1.6, 1.25, 1.0, 0.82]
            s.finalDrive = 3.6
            s.wheelRadius = 0.33
            s.wheelWidth = 0.245
            s.wheelMass = 22
            s.wheelInertia = 1.1
            s.spring = 50_000
            s.damper = 2_600
            s.travel = 0.09
            s.tyreStiffness = 250_000
            s.grip = 1.15
            s.frontBrake = 2_400
            s.rearBrake = 1_300
            s.dragArea = 0.62
            return s
        }
    }

    // MARK: The profile

    /// The top of the body at `z`: the bumpers', hood's, roof's and trunk's heights joined by straight lines, rounded
    /// over `round` (each side) by averaging the lines over it.
    package func topHeight(_ z: Float) -> Float {
        let round: Float = 0.14
        return (topLine(z - round) + topLine(z) * 2 + topLine(z + round)) / 4
    }

    /// The top's key points (z, height), rear to front.
    private var topPoints: [SIMD2<Float>] {
        [[rearEnd, deckRear - 0.12], [rearEnd + 0.18, deckRear], [rearWindowBase, deckRear + 0.02], [roofRear, roof], [roofFront, roof],
         [windshieldBase, cowl], [frontEnd - 0.2, deckFront], [frontEnd, deckFront - 0.14]]
    }

    private func topLine(_ z: Float) -> Float {
        let points = topPoints
        if z <= points[0].x { return points[0].y }
        for k in 1..<points.count where z <= points[k].x {
            let a = points[k - 1], b = points[k]
            let t = (z - a.x) / max(b.x - a.x, 1e-4)
            return a.y + (b.y - a.y) * t
        }
        return points[points.count - 1].y
    }

    /// Half the body's width at `z`: narrower toward the bumpers.
    package func halfWidth(_ z: Float) -> Float {
        let toEnd = min(z - rearEnd, frontEnd - z)
        let taper = 1 - 0.12 * (1 - smoothstep(0, 0.45, toEnd))
        return width / 2 * taper
    }

    /// How much of the top at `z` is the roof (0 at the belt line, 1 at the roof's height): what narrows it.
    package func roofness(_ z: Float) -> Float { simd_clamp((topHeight(z) - belt) / max(roof - belt, 0.05), 0, 1) }

    /// The top's edge (its half width) at `z`.
    package func topHalfWidth(_ z: Float) -> Float { halfWidth(z) * (0.92 + (roofShare - 0.92) * roofness(z)) }

    /// The belt line's height at `z` (under the hood and the trunk lid, below them).
    package func beltHeight(_ z: Float) -> Float { min(belt, topHeight(z) - 0.08) }

    /// The bottom of the body's side at `z`: the sill, or a wheel arch over a wheel.
    package func sideHeight(_ z: Float) -> Float {
        var y = sill
        let reach = wheelRadius + 0.07
        for axle in [frontAxle, rearAxle] {
            let dz = abs(z - axle)
            if dz < reach { y = max(y, wheelRadius + (reach * reach - dz * dz).squareRoot()) }
        }
        return min(y, beltHeight(z) - 0.06)
    }

    /// The floor's inner nodes' distance from the middle (inside the wheels).
    package var floorHalfWidth: Float { min(track / 2 - wheelWidth / 2 - 0.12, width / 2 - 0.12) }

    /// The torque (N m) at `rpm` on the curve (flat beyond its ends).
    package func torque(rpm: Float) -> Float { CarSpec.torque(rpm: rpm, curve: torqueCurve) }

    @inline(__always) package static func torque(rpm: Float, curve: [SIMD2<Float>]) -> Float {
        if rpm <= curve[0].x { return curve[0].y * max(rpm, 0) / curve[0].x }
        for k in 1..<curve.count where rpm <= curve[k].x {
            let a = curve[k - 1], b = curve[k]
            return a.y + (b.y - a.y) * (rpm - a.x) / (b.x - a.x)
        }
        return 0
    }
}

@inline(__always) private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = simd_clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}
