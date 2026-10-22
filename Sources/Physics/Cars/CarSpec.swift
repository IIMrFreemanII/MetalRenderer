import EngineCore
import Foundation
import simd

/// A car's body style (CarSpec.preset).
package enum CarStyle: Int, CaseIterable, Codable {
    case sedan, hatchback, pickup, coupe, wagon, compact, minivan, sport, suv, offroad

    package var title: String {
        ["Sedan", "Hatchback", "Pickup", "Coupe", "Wagon", "Compact", "Minivan", "Sports car", "SUV", "Off-roader"][rawValue]
    }
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
    /// The body's shape measured from a model (`fitted`), in place of the key heights' lines: nil, the procedural one.
    package var profile: CarProfile?

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
        case .wagon:
            var s = CarSpec(style: style, length: 4.38, width: 1.8, wheelbase: 2.63, track: 1.4, frontOverhang: 0.86, sill: 0.18, belt: 0.91,
                            roof: 1.38, deckFront: 0.78, cowl: 0.95, deckRear: 1.0, windshieldBase: 0.75, roofFront: -0.1, roofRear: -1.75,
                            rearWindowBase: -1.95, mass: 1450)
            s.wheelRadius = 0.304
            s.wheelWidth = 0.215
            s.drive = .front
            s.torqueCurve = s.torqueCurve.map { SIMD2($0.x, $0.y * 1.05) }
            s.spring = 33_000
            s.damper = 2_000
            s.dragArea = 0.72
            return s
        case .compact:
            var s = CarSpec(style: style, length: 3.26, width: 1.6, wheelbase: 2.08, track: 1.13, frontOverhang: 0.66, sill: 0.16, belt: 0.85,
                            roof: 1.32, deckFront: 0.75, cowl: 0.92, deckRear: 0.95, windshieldBase: 0.55, roofFront: -0.15, roofRear: -1.1,
                            rearWindowBase: -1.45, mass: 980)
            s.engineMass = 100
            s.drive = .front
            s.torqueCurve = s.torqueCurve.map { SIMD2($0.x, $0.y * 0.7) }
            s.wheelRadius = 0.243
            s.wheelWidth = 0.175
            s.wheelMass = 16
            s.wheelInertia = 0.65
            s.spring = 22_000
            s.damper = 1_500
            s.frontBrake = 1_300
            s.rearBrake = 550
            s.dragArea = 0.6
            return s
        case .minivan:
            var s = CarSpec(style: style, length: 4.61, width: 1.85, wheelbase: 2.84, track: 1.41, frontOverhang: 0.82, sill: 0.21, belt: 1.13,
                            roof: 1.76, deckFront: 0.9, cowl: 1.1, deckRear: 1.15, windshieldBase: 0.95, roofFront: 0.35, roofRear: -2.0,
                            rearWindowBase: -2.2, mass: 1800)
            s.roofShare = 0.85
            s.engineMass = 170
            s.drive = .front
            s.torqueCurve = s.torqueCurve.map { SIMD2($0.x, $0.y * 1.05) }
            s.wheelRadius = 0.318
            s.wheelWidth = 0.215
            s.wheelMass = 23
            s.wheelInertia = 1.1
            s.spring = 40_000
            s.damper = 2_600
            s.travel = 0.13
            s.tyreStiffness = 250_000
            s.frontBrake = 2_300
            s.rearBrake = 1_100
            s.dragArea = 0.95
            return s
        case .sport:
            var s = CarSpec(style: style, length: 3.91, width: 1.77, wheelbase: 2.45, track: 1.37, frontOverhang: 0.85, sill: 0.13, belt: 0.7,
                            roof: 1.05, deckFront: 0.62, cowl: 0.78, deckRear: 0.82, windshieldBase: 0.45, roofFront: -0.25, roofRear: -0.75,
                            rearWindowBase: -1.35, mass: 1300)
            s.roofShare = 0.7
            s.drive = .rear
            s.limitedSlip = 0.4
            s.torqueCurve = [[1000, 250], [2000, 340], [3000, 420], [4500, 480], [5500, 470], [6500, 440], [7500, 390], [8200, 150]]
            s.limiter = 8_000
            s.gears = [3.1, 2.2, 1.65, 1.3, 1.05, 0.85]
            s.finalDrive = 3.5
            s.wheelRadius = 0.308
            s.wheelWidth = 0.255
            s.wheelMass = 22
            s.wheelInertia = 1.1
            s.spring = 60_000
            s.damper = 3_000
            s.travel = 0.08
            s.tyreStiffness = 260_000
            s.grip = 1.2
            s.frontBrake = 2_700
            s.rearBrake = 1_500
            s.dragArea = 0.58
            return s
        case .suv:
            var s = CarSpec(style: style, length: 4.61, width: 1.95, wheelbase: 2.73, track: 1.46, frontOverhang: 0.87, sill: 0.24, belt: 1.19,
                            roof: 1.73, deckFront: 1.0, cowl: 1.15, deckRear: 1.15, windshieldBase: 0.85, roofFront: 0.2, roofRear: -1.8,
                            rearWindowBase: -2.0, mass: 1950)
            s.roofShare = 0.85
            s.engineMass = 200
            s.drive = .all
            s.torqueCurve = [[1000, 280], [1500, 330], [2500, 380], [3500, 375], [4500, 340], [5200, 290], [5800, 220], [6200, 100]]
            s.idle = 750
            s.limiter = 5_800
            s.engineInertia = 0.22
            s.gears = [3.8, 2.3, 1.5, 1.1, 0.85]
            s.finalDrive = 3.6
            s.wheelRadius = 0.376
            s.wheelWidth = 0.255
            s.wheelMass = 26
            s.wheelInertia = 1.5
            s.spring = 45_000
            s.damper = 3_000
            s.travel = 0.15
            s.tyreStiffness = 270_000
            s.tyreDamping = 550
            s.frontBrake = 2_600
            s.rearBrake = 1_400
            s.handbrake = 2_000
            s.dragArea = 1.0
            return s
        case .offroad:
            var s = CarSpec(style: style, length: 3.94, width: 1.9, wheelbase: 2.32, track: 1.47, frontOverhang: 0.75, sill: 0.23, belt: 1.12,
                            roof: 1.57, deckFront: 1.0, cowl: 1.1, deckRear: 1.1, windshieldBase: 0.7, roofFront: 0.3, roofRear: -1.45,
                            rearWindowBase: -1.6, mass: 2050)
            s.roofShare = 0.88
            s.engineMass = 220
            s.drive = .all
            s.limitedSlip = 0.3
            s.torqueCurve = [[1000, 330], [1500, 390], [2500, 420], [3500, 400], [4200, 350], [4800, 280], [5200, 200], [5600, 100]]
            s.idle = 700
            s.limiter = 5_000
            s.engineInertia = 0.28
            s.gears = [4.2, 2.5, 1.6, 1.15, 0.9]
            s.finalDrive = 3.7
            s.wheelRadius = 0.358
            s.wheelWidth = 0.265
            s.wheelMass = 28
            s.wheelInertia = 1.6
            s.spring = 40_000
            s.damper = 3_000
            s.travel = 0.18
            s.tyreStiffness = 260_000
            s.tyreDamping = 600
            s.frontBrake = 2_600
            s.rearBrake = 1_500
            s.handbrake = 2_000
            s.dragArea = 1.1
            return s
        }
    }

    // MARK: The profile

    /// The top of the body at `z`: the bumpers', hood's, roof's and trunk's heights joined by straight lines, rounded
    /// over `round` (each side) by averaging the lines over it.
    package func topHeight(_ z: Float) -> Float {
        if let profile { return profile.sample(profile.top, z) }
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
        if let profile { return profile.sample(profile.half, z) }
        let toEnd = min(z - rearEnd, frontEnd - z)
        let taper = 1 - 0.12 * (1 - smoothstep(0, 0.45, toEnd))
        return width / 2 * taper
    }

    /// How much of the top at `z` is the roof (0 at the belt line, 1 at the roof's height): what narrows it.
    package func roofness(_ z: Float) -> Float { simd_clamp((topHeight(z) - belt) / max(roof - belt, 0.05), 0, 1) }

    /// The top's edge (its half width) at `z`.
    package func topHalfWidth(_ z: Float) -> Float {
        if let profile { return min(profile.sample(profile.topHalf, z), halfWidth(z)) }
        return halfWidth(z) * (0.92 + (roofShare - 0.92) * roofness(z))
    }

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

/// A body's shape measured from a model (CarSpec.fitted): at stations evenly spaced from its rear end (`rear`) to its
/// front (`front`), the top's height, the body's half width (below its belt line: not its mirrors) and the top's.
package struct CarProfile: Equatable {
    package var rear: Float
    package var front: Float
    package var top: [Float]
    package var half: [Float]
    package var topHalf: [Float]

    /// `values` at `z`, between its stations (its ends' beyond them).
    package func sample(_ values: [Float], _ z: Float) -> Float {
        let t = simd_clamp((z - rear) / max(front - rear, 1e-4), 0, 1) * Float(values.count - 1)
        let k = min(Int(t), values.count - 2), f = t - Float(k)
        return values[k] + (values[k + 1] - values[k]) * f
    }
}

extension CarSpec {
    /// Stations a fitted profile measures, and how far along the body each takes its vertices from.
    package static let profileStations = 48
    package static let profileReach: Float = 0.1

    /// This spec's mechanics in `model`'s body and wheels: its size, wheelbase, track, overhang and wheels taken from
    /// the model, its body's shape measured from it (`profile`), its belt line where its side windows begin, its
    /// windows' ends (the crumple zones' ends) where the greenhouse rises from the hood and falls to the trunk.
    package func fitted(to model: CarModel) -> CarSpec {
        var s = self
        let body = model.paint.positions + model.lamps.positions, all = body + model.glass.positions
        guard !body.isEmpty, model.wheels.count == 4 else { return s }
        let lo = all.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let hi = all.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        let w = model.wheels
        s.wheelbase = (w[0].centre.z + w[1].centre.z - w[2].centre.z - w[3].centre.z) / 2
        s.track = w.reduce(0) { $0 + abs($1.centre.x) } / 2
        s.wheelRadius = w.reduce(0) { $0 + $1.radius } / 4
        s.wheelWidth = w.reduce(0) { $0 + $1.width } / 4
        s.length = hi.z - lo.z
        s.frontOverhang = hi.z - s.wheelbase / 2
        s.sill = max(body.map(\.y).min()! + 0.04, 0.12)
        // The belt line: where the glass begins (most of it above), not below the sill's reach or the roof's.
        let glass = model.glass.positions.map(\.y).sorted()
        let roof = hi.y
        s.roof = roof
        s.belt = simd_clamp(glass.isEmpty ? s.belt : glass[glass.count * 15 / 100], s.sill + 0.4, roof - 0.25)
        // The profile.
        let n = CarSpec.profileStations
        var top = [Float](repeating: -1, count: n), half = top, topHalf = top
        for k in 0..<n {
            let z = lo.z + (hi.z - lo.z) * Float(k) / Float(n - 1)
            let near = all.filter { abs($0.z - z) < CarSpec.profileReach }
            guard let t = near.map(\.y).max() else { continue }
            top[k] = t
            let low = body.filter { abs($0.z - z) < CarSpec.profileReach && $0.y < s.belt - 0.03 }.map { abs($0.x) }
            half[k] = low.max() ?? near.map { abs($0.x) }.max()!
            topHalf[k] = near.filter { $0.y > t - 0.08 }.map { abs($0.x) }.max()!
        }
        // Stations no vertex was near: their neighbours'.
        func fill(_ v: inout [Float]) {
            for k in v.indices where v[k] < 0 {
                let before = v[..<k].last { $0 >= 0 }, after = v[(k + 1)...].first { $0 >= 0 }
                v[k] = before.map { b in after.map { (b + $0) / 2 } ?? b } ?? after ?? 0
            }
        }
        fill(&top)
        fill(&half)
        fill(&topHalf)
        s.profile = CarProfile(rear: lo.z, front: hi.z, top: top, half: half, topHalf: topHalf)
        s.width = 2 * half.max()!
        // The greenhouse: where the top is well above the belt line; the windows end where it does.
        let rise = s.belt + 0.35 * (roof - s.belt)
        let zs = (0..<n).map { lo.z + (hi.z - lo.z) * Float($0) / Float(n - 1) }
        let cabin = zs.indices.filter { top[$0] > rise }
        if let first = cabin.first, let last = cabin.last {
            s.windshieldBase = zs[last]
            s.rearWindowBase = zs[first]
            let roofline = zs.indices.filter { top[$0] > roof - 0.06 }
            s.roofFront = zs[roofline.last ?? last]
            s.roofRear = zs[roofline.first ?? first]
        }
        s.cowl = s.topHeight(min(s.windshieldBase + 0.15, hi.z))
        s.deckFront = top[n - 2]
        s.deckRear = top[1]
        return s
    }
}
