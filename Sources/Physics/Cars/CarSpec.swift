import EngineCore
import Foundation
import simd

/// A car (CarSpec.preset; drawn as its model: CarPack.entries).
package enum CarStyle: Int, CaseIterable, Codable {
    case civic, karoq, panamera, santaFe

    package var title: String { ["Honda Civic Type R", "Skoda Karoq", "Porsche Panamera", "Hyundai Santa Fe"][rawValue] }
}

/// Which wheels the engine turns.
package enum CarDrive: Int, Codable {
    case front, rear, all
}

/// What a car is made of (CarBlueprint builds its nodes and beams from it): its body's profile and its mechanics.
///
/// Car space: x across (+x is the car's left), y up, z forward (the front bumper at +z), the origin on the ground
/// midway between the axles. The body's profile is measured from its model (`fitted`: CarProfile); a preset's own is a
/// few key heights along z (the bumpers', the hood's, the roof's, the trunk's), joined by straight lines and rounded
/// (`topHeight`): its crash frame alone, for the tests (the scene draws a car only as its model).
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
    /// Where the model's left mirror is (its middle; the right one's is across), if it has them: a part of its own
    /// (CarBlueprint.addMirror).
    package var mirror: SIMD3<Float>?
    /// Where the model's named parts are (`fitted`), nil without them: CarBlueprint.buildParts places the doors, the hood
    /// and the trunk lid where they are, in place of the stations' rules.
    package var spans: CarSpans?

    package var frontAxle: Float { wheelbase / 2 }
    package var rearAxle: Float { -wheelbase / 2 }
    package var frontEnd: Float { wheelbase / 2 + frontOverhang }
    package var rearEnd: Float { frontEnd - length }
    package var peakTorque: Float { torqueCurve.map(\.y).max() ?? 0 }

    /// Each car's mechanics (as its maker gives them, about), and a crash frame of key heights for the tests that have
    /// no model (a scene's car is fitted to its model: `fitted`).
    package static func preset(_ style: CarStyle) -> CarSpec {
        switch style {
        case .civic:
            // Honda Civic Type R (FL5): 2.0 turbo, 235 kW, 420 N m, six speeds, front-wheel drive with a limited-slip
            // differential, 19-inch wheels.
            var s = CarSpec(style: style, length: 4.59, width: 1.89, wheelbase: 2.735, track: 1.62, frontOverhang: 0.93, sill: 0.2, belt: 0.95,
                            roof: 1.41, deckFront: 0.82, cowl: 0.98, deckRear: 1.0, windshieldBase: 0.95, roofFront: 0.05, roofRear: -1.2,
                            rearWindowBase: -1.75, mass: 1430)
            s.engineMass = 140
            s.drive = .front
            s.limitedSlip = 0.35
            s.torqueCurve = [[1000, 250], [2000, 380], [2600, 420], [4000, 420], [5500, 390], [6500, 350], [7000, 300], [7500, 150]]
            s.limiter = 7_000
            s.gears = [3.63, 2.12, 1.53, 1.13, 0.92, 0.75]
            s.finalDrive = 4.11
            s.wheelRadius = 0.33
            s.wheelWidth = 0.265
            s.wheelMass = 22
            s.wheelInertia = 1.1
            s.spring = 42_000
            s.damper = 2_400
            s.travel = 0.1
            s.tyreStiffness = 250_000
            s.grip = 1.15
            s.frontBrake = 2_600
            s.rearBrake = 1_200
            s.dragArea = 0.68
            return s
        case .karoq:
            // Skoda Karoq 1.5 TSI: 110 kW, 250 N m, front-wheel drive, 17-inch wheels.
            var s = CarSpec(style: style, length: 4.39, width: 1.84, wheelbase: 2.638, track: 1.52, frontOverhang: 0.89, sill: 0.25, belt: 1.05,
                            roof: 1.6, deckFront: 0.95, cowl: 1.1, deckRear: 1.15, windshieldBase: 1.0, roofFront: 0.3, roofRear: -1.6,
                            rearWindowBase: -1.85, mass: 1350)
            s.engineMass = 120
            s.drive = .front
            s.torqueCurve = [[1000, 180], [1500, 250], [3500, 250], [4500, 235], [5500, 205], [6000, 185], [6300, 150], [6800, 80]]
            s.limiter = 6_300
            s.gears = [3.77, 2.12, 1.36, 1.03, 0.84, 0.69]
            s.finalDrive = 4.17
            s.wheelRadius = 0.35
            s.wheelWidth = 0.215
            s.wheelMass = 20
            s.wheelInertia = 1.0
            s.spring = 32_000
            s.damper = 2_100
            s.travel = 0.14
            s.frontBrake = 1_900
            s.rearBrake = 900
            s.dragArea = 0.85
            return s
        case .panamera:
            // Porsche Panamera 4S: 2.9 V6 twin turbo, 324 kW, 550 N m, eight speeds, all-wheel drive, 19-inch wheels.
            var s = CarSpec(style: style, length: 5.05, width: 1.94, wheelbase: 2.95, track: 1.65, frontOverhang: 0.95, sill: 0.17, belt: 0.9,
                            roof: 1.42, deckFront: 0.72, cowl: 0.92, deckRear: 1.0, windshieldBase: 0.85, roofFront: 0.0, roofRear: -1.0,
                            rearWindowBase: -1.8, mass: 2000)
            s.engineMass = 190
            s.drive = .all
            s.limitedSlip = 0.3
            s.torqueCurve = [[1000, 300], [1750, 550], [5500, 550], [6000, 500], [6500, 440], [6800, 380], [7000, 300], [7300, 150]]
            s.limiter = 6_800
            s.gears = [5.0, 3.2, 2.14, 1.72, 1.31, 1.0, 0.82, 0.64]
            s.finalDrive = 2.86
            s.wheelRadius = 0.34
            s.wheelWidth = 0.275
            s.wheelMass = 25
            s.wheelInertia = 1.3
            s.spring = 48_000
            s.damper = 3_000
            s.travel = 0.11
            s.tyreStiffness = 270_000
            s.grip = 1.15
            s.frontBrake = 3_200
            s.rearBrake = 1_700
            s.handbrake = 2_000
            s.dragArea = 0.68
            return s
        case .santaFe:
            // Hyundai Santa Fe 2.5T (2024): 207 kW, 422 N m, eight speeds, all-wheel drive, 20-inch wheels.
            var s = CarSpec(style: style, length: 4.83, width: 1.9, wheelbase: 2.815, track: 1.64, frontOverhang: 0.93, sill: 0.27, belt: 1.15,
                            roof: 1.78, deckFront: 1.1, cowl: 1.22, deckRear: 1.3, windshieldBase: 1.1, roofFront: 0.45, roofRear: -2.0,
                            rearWindowBase: -2.25, mass: 1900)
            s.roofShare = 0.88
            s.engineMass = 170
            s.drive = .all
            s.torqueCurve = [[1000, 250], [1700, 422], [4000, 422], [5000, 390], [5800, 350], [6000, 300], [6300, 200], [6600, 100]]
            s.idle = 750
            s.limiter = 6_000
            s.gears = [4.81, 2.94, 1.94, 1.45, 1.0, 0.85, 0.68, 0.58]
            s.finalDrive = 3.2
            s.wheelRadius = 0.38
            s.wheelWidth = 0.255
            s.wheelMass = 27
            s.wheelInertia = 1.6
            s.spring = 45_000
            s.damper = 3_000
            s.travel = 0.16
            s.tyreStiffness = 270_000
            s.tyreDamping = 550
            s.frontBrake = 2_800
            s.rearBrake = 1_400
            s.handbrake = 2_000
            s.dragArea = 1.0
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

/// Where a model's parts are along its body (z): its front and rear doors' ends (nil: no rear doors), the hood's rear
/// edge, the trunk lid's (or tailgate's) front edge (nil: none).
package struct CarSpans: Equatable {
    package var frontDoor: SIMD2<Float>?
    package var rearDoor: SIMD2<Float>?
    package var hood: Float?
    package var trunk: Float?
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
        // (Its shape: all of it, its glass's own aside; the interior and the engine are inside it. Its sill: the paint's.)
        let all = model.positions { $0 != .glass }, glassAll = model.positions { $0 == .window }
        let paint = model.positions { $0 == .paint }
        guard !paint.isEmpty, model.wheels.count == 4 else { return s }
        let body = model.positions { $0 != .glass && $0 != .window }
        let lo = all.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let hi = all.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        let w = model.wheels
        s.wheelbase = (w[0].centre.z + w[1].centre.z - w[2].centre.z - w[3].centre.z) / 2
        s.track = w.reduce(0) { $0 + abs($1.centre.x) } / 2
        s.wheelRadius = w.reduce(0) { $0 + $1.radius } / 4
        s.wheelWidth = w.reduce(0) { $0 + $1.width } / 4
        s.length = hi.z - lo.z
        s.frontOverhang = hi.z - s.wheelbase / 2
        s.sill = max(paint.map(\.y).min()! + 0.04, 0.12)
        // The belt line: where the glass begins (most of it above), not below the sill's reach or the roof's.
        let glass = glassAll.map(\.y).sorted()
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
        let mirror = model.positions(of: .mirror, side: 1)
        if mirror.isEmpty {
            s.mirror = CarSpec.mirror(paint, s)
        } else {
            let lo = mirror.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }, hi = mirror.reduce(-lo) { simd_max($0, $1) }
            s.mirror = (lo + hi) / 2
        }
        s.spans = CarSpec.spans(model)
        return s
    }

    /// Where `model`'s named parts are (nil: it names no doors).
    package static func spans(_ model: CarModel) -> CarSpans? {
        func span(_ kind: CarPartKind) -> SIMD2<Float>? {
            let z = model.positions(of: kind).map(\.z)
            guard let a = z.min(), let b = z.max() else { return nil }
            return SIMD2(a, b)
        }
        guard let front = span(.frontDoor) else { return nil }
        return CarSpans(frontDoor: front, rearDoor: span(.rearDoor), hood: span(.hood)?.x, trunk: span(.trunk)?.y)
    }

    /// The left mirror's middle in `paint`: what sticks out past the body's side (`halfWidth`, below the belt line) a
    /// little above the belt line, near the windshield's base.
    package static func mirror(_ paint: [SIMD3<Float>], _ s: CarSpec) -> SIMD3<Float>? {
        let out = paint.filter { p in
            p.x > s.halfWidth(p.z) + 0.03 && p.y > s.belt - 0.05 && p.y < s.belt + 0.3 && abs(p.z - s.windshieldBase - 0.1) < 0.5
        }
        guard out.count >= 12 else { return nil }
        let lo = out.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }, hi = out.reduce(-lo) { simd_max($0, $1) }
        // (Its body: the half of it farthest out, not the stalk.)
        return SIMD3((lo.x + hi.x) / 2 + 0.02, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
    }
}
