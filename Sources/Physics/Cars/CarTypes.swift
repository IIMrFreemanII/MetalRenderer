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
    /// Its kind (CarBeamKind) in the low byte, `brokenBit`, its zone (CarBeamZone) in the second byte, `hullBit`,
    /// `cornerBit`, `attachBit`, and its part (1 + its place in the car's parts, 0: the body's) from `partShift`.
    package var info: UInt32 = 0

    package static let brokenBit: UInt32 = 1 << 7
    /// On the body's outside: its middle meets the world too (a pole between two nodes).
    package static let hullBit: UInt32 = 1 << 16
    /// A wheel's corner's (its knuckle, wishbones, tie rod, spring, mounts): solved again (CarSolver.cornerPasses).
    package static let cornerBit: UInt32 = 1 << 17
    /// What holds a part on (a hinge, a latch, a clip): the part comes off when all of its are broken.
    package static let attachBit: UInt32 = 1 << 18
    package static let partShift: UInt32 = 24

    @inline(__always) package var kind: UInt32 { info & 0x7F }
    /// 1 + its part's place among its car's, 0 for the body's.
    @inline(__always) package var part: Int { Int(info >> CarBeam.partShift) }
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
    /// What a part rests on its body by (CarBlueprint.addPart): it holds both ways and bends past its yield, as a
    /// plastic beam does, but never breaks; it lets go when its part comes off (CarSolver.letGo).
    case support
}

/// Where a beam is, for its strengths (CarBlueprint): the crumple zones front and rear, the cabin, the floor's rails,
/// the engine, the suspension, a wheel's arms (its wishbones and tie rods: they bend and break), a part's panel, what
/// holds a part on.
package enum CarBeamZone: UInt32 {
    case crumple = 0, cabin, roof, rail, cabinRail, bumper, engine, suspension, bend, arm, panel, attach
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
    /// A tie rod's bend (m): how far its flow has moved its length from the steering's (rest0 + steer x turn).
    package var bend: Float = 0
    package var pad = SIMD2<Float>()
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
    /// The hardest knock its axle took this step: its pull on its hubs along the ground (level, the world's) in one
    /// substep (N; its XPBD lambdas / h^2). Past `axleStrength` (a curb's, not a bump's, which mostly lifts), it comes
    /// off, as it does when its knuckle's links break (`links`). And the hardest so far.
    package var axleKnock: Float = 0
    package var knockPeak: Float = 0
    /// What holds its knuckle (its corner's links: CarBlueprint.Corner.links; beams of CarSystem.beams, -1 none).
    package var links = SIMD8<Int32>(repeating: -1)

    package static let driven: UInt32 = 1, steered: UInt32 = 2, handbraked: UInt32 = 4, front: UInt32 = 8
    /// Off its axle: a body of its own (it has its friction back and rolls away).
    package static let off: UInt32 = 16
}

/// A part of a car's body that can come off (CarBlueprint.Part): its own nodes (`nodeCount` of the car's particles
/// from `firstNode`) and panel beams, on the body's by its attachments (CarBeam.attachBit) and by supports that only
/// push. Off, it is a free island of nodes; still for a second, it is frozen (its nodes held: no mass) until a body
/// comes near.
package struct CarPart {
    package var firstNode: Int32 = 0
    package var nodeCount: Int32 = 0
    /// Its nodes' inverse mass (they weigh the same), for when it wakes.
    package var inverseMass: Float = 0
    /// CarPartKind.
    package var kind: UInt32 = 0
    /// `off`, `frozen`.
    package var flags: UInt32 = 0
    /// How long (s) it has been still, off.
    package var still: Float = 0
    /// Its attachments not yet broken, as of its car's last step, and at the start: with less than half of them
    /// left, the rest tear off too (`CarSolver.tornBelow`).
    package var holding: Int32 = 0
    package var attachments: Int32 = 0

    package static let off: UInt32 = 1, frozen: UInt32 = 2
}

/// What a car's part is (CarBlueprint.Part).
package enum CarPartKind: UInt32, CaseIterable {
    case hood, trunk, frontBumper, rearBumper, frontDoor, rearDoor, mirror

    package var title: String { ["hood", "trunk lid", "front bumper", "rear bumper", "front door", "rear door", "mirror"][Int(rawValue)] }
}

/// A pane of a car's glass, or a lamp (CarSurface.Pane): it breaks when the beams of its frame strain past
/// `glassStrain` (or, a lamp, bend past `lampStrain`), or when the part it is on comes off; its drawn vertices then
/// fold away (a pane) or go dark (a lamp), and it scatters shards.
package struct CarPane {
    /// Its frame's beams (`CarSystem.paneFrames` from `firstFrame`).
    package var firstFrame: Int32 = 0
    package var frameCount: Int32 = 0
    /// The part it is on (1 + its place among its car's parts), 0: the body.
    package var part: Int32 = 0
    /// A lamp's (its glass breaks and its light goes out), not a window's.
    package var lamp: Bool = false
    package var broken: Bool = false
    /// Four nodes round it: where its shards fly from.
    package var corners = SIMD4<UInt32>()
}

/// What a car's step leaves for the dust and debris (PhysicsWorld.breakLog's events, GPUBreakEvent.velocity.w): a
/// pane's shards, steam from a broken radiator, smoke from a burning engine, a part's bits as it comes off.
package enum CarEvent: UInt32, CaseIterable {
    case glass = 0, steam, smoke, debris

    /// Its kind of break in GPUBreakEvent.velocity.w: after the fractured objects' materials (FractureMaterial's 0...7),
    /// so a scene with both has the particles of each.
    package static let firstSlot: UInt32 = 8
    package var slot: UInt32 { CarEvent.firstSlot + rawValue }
}

/// A car's state (Physics+Cars.swift): its ranges in the shared arrays, its tuning, its input and its drivetrain.
package struct CarState {
    // Ranges.
    package var firstNode: Int32 = 0
    package var nodeCount: Int32 = 0
    package var firstBeam: Int32 = 0
    package var beamCount: Int32 = 0
    /// Its wheels' corners' beams, its last (CarBlueprint.firstCorner).
    package var firstCorner: Int32 = 0
    package var firstWheel: Int32 = 0
    package var wheelCount: Int32 = 0
    /// The engine's nodes (its torque's reaction), in `CarSystem.reactionNodes`.
    package var firstReaction: Int32 = 0
    package var reactionCount: Int32 = 0
    /// The nodes its frame is measured from: the floor's middle at the rear, at the front, and the left sill.
    package var frame = SIMD3<UInt32>()
    /// Its body's rings' nodes: its first `ringNodes` (CarBlueprint.rings, built first), whose middle a camera looks at
    /// (CarTelemetry.centre).
    package var ringNodes: Int32 = 0
    /// The step's candidates (`CarSystem.candidates`): statics (staticBit set), then bodies.
    package var firstCandidate: Int32 = 0
    package var candidateCount: Int32 = 0
    /// Its mass (kg, wheels included), the world's at the start.
    package var mass: Float = 0
    /// Its parts (`CarSystem.parts`), panes and lamps (`panes`), and its front end's nodes (`radiatorNodes`: how far
    /// they came back toward its engine is how far its front is crushed).
    package var firstPart: Int32 = 0
    package var partCount: Int32 = 0
    package var firstPane: Int32 = 0
    package var paneCount: Int32 = 0
    package var firstRadiator: Int32 = 0
    package var radiatorCount: Int32 = 0
    /// Its hull's triangles (`CarSystem.triangles`: the body's, then its parts'), what the other cars' nodes (and its
    /// own parts', off) meet (CarContacts.swift).
    package var firstTriangle: Int32 = 0
    package var triangleCount: Int32 = 0
    /// Its box this step (its nodes', grown by how far they may go): which cars it may meet.
    package var lo = SIMD3<Float>()
    package var hi = SIMD3<Float>()

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

    // Damage (CarDamage.swift), as of its last step's end.
    /// How far (m) its front is crushed in front of the engine; its radiator's coolant left (1 full), the engine's heat
    /// (0 cold, 1 seizing), how broken the engine is (1: seized, it won't run).
    package var frontCrush: Float = 0
    package var coolant: Float = 1
    package var heat: Float = 0
    package var engineDamage: Float = 0
    /// Parts come off, wheels off their axles, panes and lamps broken.
    package var partsOff: Int32 = 0
    package var wheelsOff: Int32 = 0
    package var panesBroken: Int32 = 0
    /// Steps since it last gave off steam or smoke.
    package var sinceSmoke: Int32 = 0
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
    /// The middle of its body's rings' nodes: where a camera looks (the whole body's middle, not two of its nodes').
    package var centre = SIMD3<Float>()
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
    /// Its damage (CarState's): the front's crush (m), coolant left, the engine's heat and damage, whether it runs;
    /// parts and wheels off, panes and lamps broken.
    package var frontCrush: Float = 0
    package var coolant: Float = 1
    package var heat: Float = 0
    package var engineDamage: Float = 0
    package var running = true
    package var partsOff: Int32 = 0
    package var wheelsOff: Int32 = 0
    package var panesBroken: Int32 = 0

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

/// A car's nodes' knocks on a fractured object's piece this substep (applyCarReactions strikes it: Physics+Fracture.swift's
/// `strike`, its verdict at the step's end): their impulses summed (N s), where (the impulse-weighted sum of the points),
/// which way (the pushes' directions, impulse-weighted).
package struct CarHit {
    package var body: Int32 = 0
    package var impulse: Float = 0
    package var point = SIMD3<Float>()
    package var push = SIMD3<Float>()
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
    /// Per car `maxPushes` pushes on bodies a substep, and how many; `maxHits` knocks on fractured objects' pieces.
    package var pushes: [CarPush] = []
    package var pushCounts: [Int32] = []
    package var hits: [CarHit] = []
    package var hitCounts: [Int32] = []
    /// Per wheel its tyre's impulse on the body it stands on this substep (count 0: none), CarSolver.applyTyreKicks.
    package var tyreKicks: [CarPush] = []
    /// Per body, the pushes the cars gave it this substep summed (w: how many), and their turns (applyCarReactions);
    /// how many it had the substep before (a node's push takes its mass as that many shares: CarSolver.nodeContacts).
    package var bodyPushes: [SIMD4<Float>] = []
    package var bodyTwists: [SIMD3<Float>] = []
    package var bodyShares: [Float] = []
    package var telemetry: [CarTelemetry] = []
    /// The cars' parts, panes and lamps, their panes' frames (beams), the beams in front of their engines.
    package var parts: [CarPart] = []
    package var panes: [CarPane] = []
    package var paneFrames: [UInt32] = []
    /// The cars' front ends' nodes, and how far ahead of their engine's middle each was at the start (m).
    package var radiatorNodes: [UInt32] = []
    package var radiatorReach: [Float] = []
    /// Per car `maxEvents` events its last step left (CarEvent), and how many: endCarStep logs them in the cars' order.
    package var events: [GPUBreakEvent] = []
    package var eventCounts: [Int32] = []
    /// Per particle (a car's node's), how far (m) it has slid on what it touched fast (scrapes) and at all (dirt) and
    /// not yet worn into its damage (CarSolver.wearNodes).
    package var wear: [SIMD2<Float>] = []
    /// The cars' hull triangles: their three nodes (particles) and their part (1 + its place among its car's, 0: the
    /// body's); per particle (a car's node's) its part, so.
    package var triangles: [SIMD4<UInt32>] = []
    package var nodeParts: [UInt8] = []
    /// Per car its triangles in a hash of cells (`gridBuckets` buckets: their starts in `gridStarts`, `gridBuckets + 1`
    /// a car; their triangles in `gridItems`, `gridCells` x its triangles a car from its first triangle's place x
    /// `gridCells`), made each substep for the cars that meet another (CarContacts.swift).
    package var gridStarts: [UInt32] = []
    package var gridItems: [UInt32] = []
    /// This step's pairs of cars that may meet (a car with itself: its parts that came off and its body), in colours
    /// (no car twice in one: a colour's pairs run side by side), each colour's from `pairStarts[colour]`.
    package var pairs: [SIMD2<Int32>] = []
    package var pairStarts: [Int32] = []
    /// The cars in this step's pairs, once each (their triangles hashed each substep).
    package var paired: [Int32] = []
    /// Per part: a car's node met it while it was frozen (carBroadPhase wakes it).
    package var partWake: [Int32] = []
    /// As built (reset puts them back).
    package var initialCars: [CarState] = []
    package var initialBeams: [CarBeam] = []
    package var initialLimits: [CarBeamLimit] = []
    package var initialWheels: [CarWheel] = []
    package var initialParts: [CarPart] = []
    package var initialPanes: [CarPane] = []

    package static let maxPushes = 256
    package static let maxHits = 64
    package static let maxEvents = 16
    /// The triangles' hash: its buckets a car (a power of two), its cells' size (m), the most cells a triangle is in.
    package static let gridBuckets = 1024, gridCell: Float = 0.5, gridCells = 48

    package var isEmpty: Bool { cars.isEmpty }

    package mutating func reset() {
        cars = initialCars
        beams = initialBeams
        limits = initialLimits
        wheels = initialWheels
        parts = initialParts
        panes = initialPanes
        for i in loads.indices { loads[i] = 0 }
        for i in eventCounts.indices { eventCounts[i] = 0 }
        for i in wear.indices { wear[i] = .zero }
        for i in partWake.indices { partWake[i] = 0 }
        for i in bodyShares.indices { bodyShares[i] = 0 }
    }
}

/// A car's tuning, as its spec gave it (the substeps read it): the engine, the gears, the tyres, the brakes, the
/// steering.
package struct CarTune {
    package var rpm = SIMD8<Float>()
    package var torque = SIMD8<Float>()
    /// Forward gears (up to 8), then 0s.
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
        for (k, g) in s.gears.prefix(8).enumerated() { gears[k] = g }
        gearCount = Int32(min(s.gears.count, 8))
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
