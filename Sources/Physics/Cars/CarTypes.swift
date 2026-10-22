import EngineCore
import Foundation
import simd

/// A beam between two of a car's nodes (Physics+Cars.swift): an XPBD distance constraint that bends for good past its
/// yield (its rest length flows) and breaks past its strength. What the substeps read: 32 bytes.
package struct CarBeam {
    /// Its two nodes (the world's particles).
    package var nodes = SIMD2<UInt32>()
    package var rest: Float = 0
    /// 1 / stiffness (m/N); damping (N s/m).
    package var compliance: Float = 0
    package var damping: Float = 0
    /// The force (N) it flows at, and its load (N, + pulled) averaged over a few substeps (what flows it).
    package var yield: Float = .infinity
    package var load: Float = 0
    /// Its kind (CarBeamKind) in the low byte, `brokenBit`, its zone (CarBeamZone) in the second byte, `hullBit`.
    package var info: UInt32 = 0

    package static let brokenBit: UInt32 = 1 << 7
    /// On the body's outside: its middle meets the world too (a pole between two nodes).
    package static let hullBit: UInt32 = 1 << 16

    @inline(__always) package var kind: UInt32 { info & 0x7F }
}

/// CarBeam.info's low byte.
package enum CarBeamKind: UInt32 {
    /// Bends past its yield and breaks past its strength.
    case plastic = 0
    /// Never bends nor breaks (a knuckle's, an engine's).
    case rigid
    /// Only pushes (a bump stop), only pulls (a rebound strap).
    case compression, tension
    /// A suspension spring with its damper: elastic.
    case spring
    /// A steering tie rod: its rest length is the steering's (CarBeamLimit.steer).
    case steer
}

/// Where a beam is, for its strengths (CarBlueprint): the crumple zones front and rear, the cabin, the floor's rails,
/// the engine, the suspension.
package enum CarBeamZone: UInt32 {
    case crumple = 0, cabin, roof, rail, cabinRail, bumper, engine, suspension, bend
}

/// What a beam breaks at, and its rest at the start: read at the step's end, and by the steering.
package struct CarBeamLimit {
    package var rest0: Float = 0
    /// The load (N) averaged over a step it breaks at; its rest's change as a share of rest0 it breaks at.
    package var strength: Float = .infinity
    package var strainLimit: Float = .infinity
    /// How much its yield grows with its flow: yield x (1 + hardening x flow / rest0).
    package var hardening: Float = 0
    /// A steering tie rod's change of length (m) at full lock to the left (sin of the angle).
    package var steer: Float = 0
    package var pad = SIMD3<Float>()
}

/// One of a car's wheels: a rigid body (a rim) held by its axle to two hub nodes of the car's knuckle, turned by the
/// drivetrain and the brakes, carried by its tyre (CarTires.swift).
package struct CarWheel {
    package var body: Int32 = -1
    /// Its hub nodes (in and out along its axle), the knuckle's steering arm node (the brakes' reaction).
    package var hubIn: UInt32 = 0
    package var hubOut: UInt32 = 0
    package var arm: UInt32 = 0
    /// Flags: driven, steered, braked by the handbrake, front.
    package var flags: UInt32 = 0
    /// Its tie rod (a beam of CarSystem.beams; -1: none), which the steering lengthens.
    package var tie: Int32 = -1
    /// Its axle in the body's space (unit), the outer hub's point along it from the centre (m; the inner hub's is
    /// minus it).
    package var axle = SIMD3<Float>()
    package var hubOffset: Float = 0
    package var radius: Float = 0
    package var width: Float = 0
    /// Its brake's torque (N m) at full brake.
    package var brake: Float = 0
    /// What the last substep found: its spin about the axle (rad/s), its tyre's load (N), slip (m/s, along and across),
    /// whether it touches.
    package var spin: Float = 0
    package var load: Float = 0
    package var slip = SIMD2<Float>()

    package static let driven: UInt32 = 1, steered: UInt32 = 2, handbraked: UInt32 = 4, front: UInt32 = 8
}

/// A car's state (Physics+Cars.swift): its ranges in the shared arrays, its tuning, its input and its drivetrain.
package struct CarState {
    // Ranges.
    package var firstNode: Int32 = 0
    package var nodeCount: Int32 = 0
    package var firstBeam: Int32 = 0
    package var beamCount: Int32 = 0
    package var firstWheel: Int32 = 0
    package var wheelCount: Int32 = 0
    /// The engine's nodes (its torque's reaction), in `CarSystem.reactionNodes`.
    package var firstReaction: Int32 = 0
    package var reactionCount: Int32 = 0
    /// The nodes its frame is measured from: the floor's middle at the rear, at the front, and the left sill.
    package var frame = SIMD3<UInt32>()
    /// The step's candidates (`CarSystem.candidates`): statics (staticBit set), then bodies.
    package var firstCandidate: Int32 = 0
    package var candidateCount: Int32 = 0
    /// Its mass (kg, wheels included), the world's at the start.
    package var mass: Float = 0

    // Input, as the last command left it, and as the car has it now (ramped).
    package var input = CarInput()
    package var throttle: Float = 0
    package var brake: Float = 0
    package var handbrake: Float = 0
    package var steer: Float = 0

    // Drivetrain.
    /// Engine speed (rad/s); running.
    package var engine: Float = 0
    package var running = true
    /// -1 reverse, 0 neutral, 1... forward; seconds left of a shift (the clutch is out meanwhile); the clutch's
    /// engagement (0...1).
    package var gear: Int32 = 1
    package var shifting: Float = 0
    package var clutch: Float = 0
    /// Seconds since the last shift (an automatic gearbox doesn't shift back at once).
    package var sinceShift: Float = 0
    /// Moving at all in its last step (the wheels are kept awake while it does).
    package var awake = true
    /// Its plastic beams bent for good (their rest length 1% or more off) and broken, as of its last step's end
    /// (breakBeams).
    package var bent: Int32 = 0
    package var broken: Int32 = 0
}

/// A car's input (a `car` command's: Physics+Cars.swift): the pedals' and the wheel's targets, from -1 to 1 for the
/// steering (+ left). `accelerate` and `decelerate` are W and S: throttle and brake, or the other way round in reverse.
package struct CarInput: Equatable {
    package var accelerate: Float = 0
    package var decelerate: Float = 0
    package var steer: Float = 0
    package var handbrake: Float = 0
    /// Manual gears (shifts asked for with `shiftUp` / `shiftDown`); otherwise automatic.
    package var manual = false
    /// An autopilot: round a circle centred on `lap.xy` (x, z) of radius `lap.z` at `lap.w` m/s (anticlockwise seen from
    /// above), for the benchmark's laps.
    package var autopilot = false
    package var lap = SIMD4<Float>()

    package init() {}
}

/// What a frame shows of a car (PhysicsStepper.Drawn.cars): where it is, how it goes.
package struct CarTelemetry {
    /// Its frame: the middle of its floor, its forward and up (unit, the world).
    package var position = SIMD3<Float>()
    package var forward = SIMD3<Float>(0, 0, 1)
    package var up = SIMD3<Float>(0, 1, 0)
    /// Speed along its forward (m/s), engine rpm, gear (-1 reverse, 0 neutral), the pedals, the steering (rad).
    package var speed: Float = 0
    package var rpm: Float = 0
    package var gear: Int32 = 0
    package var throttle: Float = 0
    package var brake: Float = 0
    package var steer: Float = 0
    /// Beams bent and broken so far.
    package var bent: Int32 = 0
    package var broken: Int32 = 0

    package init() {}
}

/// A push a car's node gave a body this substep (the body's share: solveCars collects them per car, applyCarReactions
/// applies them in the cars' order).
package struct CarPush {
    package var body: Int32 = 0
    /// The impulses, their turns about the body's centre, how many contacts gave them (more than one once the car's
    /// list is full: nodeContacts adds to the last push to the same body).
    package var impulse = SIMD3<Float>()
    package var twist = SIMD3<Float>()
    package var count: Float = 0
}

/// The cars of a world (Physics+Cars.swift): their nodes are among its particles, their wheels among its bodies; the
/// rest is here, in flat arrays the cars index by range.
package struct CarSystem {
    package var cars: [CarState] = []
    package var beams: [CarBeam] = []
    package var limits: [CarBeamLimit] = []
    /// Per beam, this step's load summed over its substeps (what breaks it), and its lambda this substep (XPBD's,
    /// summed over the iterations).
    package var loads: [Float] = []
    package var lambdas: [Float] = []
    package var wheels: [CarWheel] = []
    package var reactionNodes: [UInt32] = []
    /// Per car its engine's torque curve (eight rpm points, then their torques), gears and the rest of its tuning.
    package var tunes: [CarTune] = []
    /// The step's candidates for each car's nodes (statics with PhysicsWorld.staticBit, bodies), by range.
    package var candidates: [UInt32] = []
    /// Per car `maxPushes` pushes on bodies a substep, and how many.
    package var pushes: [CarPush] = []
    package var pushCounts: [Int32] = []
    /// Per body, the pushes the cars gave it this substep summed (w: how many), and their turns (applyCarReactions).
    package var bodyPushes: [SIMD4<Float>] = []
    package var bodyTwists: [SIMD3<Float>] = []
    package var telemetry: [CarTelemetry] = []
    /// As built (reset puts them back).
    package var initialCars: [CarState] = []
    package var initialBeams: [CarBeam] = []
    package var initialWheels: [CarWheel] = []

    package static let maxPushes = 256

    package var isEmpty: Bool { cars.isEmpty }

    package mutating func reset() {
        cars = initialCars
        beams = initialBeams
        wheels = initialWheels
        for i in loads.indices { loads[i] = 0 }
    }
}

/// A car's tuning, as its spec gave it (the substeps read it): the engine, the gears, the tyres, the brakes, the
/// steering.
package struct CarTune {
    package var rpm = SIMD8<Float>()
    package var torque = SIMD8<Float>()
    /// Forward gears (up to 7), then 0s.
    package var gears = SIMD8<Float>()
    package var gearCount: Int32 = 0
    package var reverse: Float = 0
    package var finalDrive: Float = 0
    package var idle: Float = 0          // rad/s
    package var limiter: Float = 0       // rad/s
    package var engineInertia: Float = 0
    package var clutchTorque: Float = 0
    package var limitedSlip: Float = 0
    package var handbrake: Float = 0
    package var steer: Float = 0
    package var steerRate: Float = 0
    package var dragArea: Float = 0
    package var grip: Float = 0
    package var tyreStiffness: Float = 0
    package var tyreDamping: Float = 0
    package var wheelMass: Float = 0
    /// Traction control and ABS: the throttle eased off while a driven wheel spins, a brake while its wheel locks.
    package var assists = true

    package init() {}

    package init(_ s: CarSpec) {
        let curve = s.torqueCurve.prefix(8)
        for (k, p) in curve.enumerated() {
            rpm[k] = p.x
            torque[k] = p.y
        }
        for k in curve.count..<8 {
            rpm[k] = rpm[curve.count - 1] + Float(k - curve.count + 1)
            torque[k] = 0
        }
        for (k, g) in s.gears.prefix(7).enumerated() { gears[k] = g }
        gearCount = Int32(min(s.gears.count, 7))
        reverse = s.reverse
        finalDrive = s.finalDrive
        idle = s.idle * .pi / 30
        limiter = s.limiter * .pi / 30
        engineInertia = s.engineInertia
        clutchTorque = 1.6 * s.peakTorque
        limitedSlip = s.limitedSlip
        handbrake = s.handbrake
        steer = s.steer
        steerRate = s.steerRate
        dragArea = s.dragArea
        grip = s.grip
        tyreStiffness = s.tyreStiffness
        tyreDamping = s.tyreDamping
        wheelMass = s.wheelMass
        assists = s.assists
    }

    /// The torque (N m) at engine speed `w` (rad/s) on the curve, full throttle.
    @inline(__always) package func torque(at w: Float) -> Float {
        let r = w * 30 / .pi
        if r <= rpm[0] { return torque[0] * max(r, 0) / rpm[0] }
        for k in 1..<8 where r <= rpm[k] {
            return torque[k - 1] + (torque[k] - torque[k - 1]) * (r - rpm[k - 1]) / (rpm[k] - rpm[k - 1])
        }
        return 0
    }
}

/// The cars' substep stages and their helpers (CarBeams.swift, CarDrivetrain.swift, CarTires.swift): static functions
/// on a namespace rather than on PhysicsWorld, a class, whose metadata each call from the stages' closures would look
/// up (Tools/perf/hotcalls.py).
package enum CarSolver {}
