import EngineCore
import Foundation
import simd

/// Cars (BeamNG's way, on the CPU): a body of nodes and beams that bends where it is hit and keeps the dent, on four
/// rigid wheels turned by an engine through a clutch, a gearbox and differentials, steered, braked, carried by tyres.
///
/// A car's nodes are particles of the world (`carBit`), but the substeps' particle stages pass them by: the cars' own
/// stages move them (Physics+Cars.swift, CarBeams.swift, CarDrivetrain.swift, CarTires.swift), each car on a worker of
/// its own, its beams one after another in a fixed order (Gauss-Seidel), so the
/// numbers don't depend on the cores. Each substep:
///
/// * `carForces`, before the bodies move: the input ramped, the steering's tie rods, the engine, clutch, gearbox and
///   differentials turning the driven wheels, the brakes, the tyres (a radial spring under each wheel and a combined-
///   slip Magic Formula), the air's drag; then the nodes move by their velocities and gravity.
/// * `solveCars`, after the bodies moved: the wheels' axles (each wheel held at two points to its two hub nodes, free
///   to spin), the beams (plastic past their yield, CarBeams.swift), the nodes and the hull beams' middles pushed out of
///   the statics, the nodes pushed out of the bodies (the bodies' share kept as pushes), the nodes' velocities.
/// * `applyCarReactions`: those pushes on the bodies, in the cars' order.
///
/// At the step's end (`endCarStep`) a beam whose load over the step passed its strength, or that flowed past its
/// strain limit, breaks; and what a frame shows of each car is taken (CarTelemetry).
///
/// The input is a `car` command (Physics+Fracture.swift's list, stamped with its step), kept by the car until the
/// next: a replay drives the same. The GPU's step knows none of it (a world with cars steps on the CPU).
extension PhysicsWorld {
    /// A particle's flag: a car's node. A body's: a car's wheel (its tyre is the car's, not a contact's).
    package static let carBit: UInt32 = 8
    package static let wheelBit: UInt32 = 128
    /// A car's wheels' axles: their bushing's compliance (m/N), passes a substep.
    package static let axleCompliance: Float = 1e-9
    package static let axlePasses = 2
    /// The fastest a car's node may go (m/s): the world's top speed is a body's.
    package static let carTopSpeed: Float = 90
    /// Air density (kg/m^3).
    package static let airDensity: Float = 1.2

    package var hasCars: Bool { !carSystem.isEmpty }

    // MARK: Building

    /// A car made of `blueprint`, placed by `transform` (a rotation and a translation), moving at `velocity` (its
    /// wheels rolling with it); its wheels are bodies of SDF shape `rimSDF` (`CarBlueprint.rimShape`), moving
    /// `wheelInstances` (one per corner, in the blueprint's order). Returns the car.
    @discardableResult
    package func addCar(_ blueprint: CarBlueprint, transform: float4x4, rimSDF: Int, wheelInstances: [Int], velocity: SIMD3<Float> = .zero) -> Int {
        let spec = blueprint.spec, rim = blueprint.rimShape
        let r = spec.wheelRadius - CarBlueprint.tyreDepth
        let density = spec.wheelMass / (.pi * r * r * spec.wheelWidth)
        // A wheel's shape stands along y: turned to lie along the car's x.
        let turn = float4x4(simd_quatf(angle: -.pi / 2, axis: [0, 0, 1]))
        var wheels: [Int] = []
        for (corner, instance) in zip(blueprint.corners, wheelInstances) {
            let i = addBody(sdf: rimSDF, rim, transform: transform * translate(corner.centre) * turn, instance: instance, density: density,
                            friction: 0, restitution: 0)
            // Its inertia about its axle the tyre's and rim's (a solid cylinder's is less: the mass is at the rim).
            let solid = 0.5 * spec.wheelMass * r * r
            bodies[i].invInertia = SIMD4(PhysicsMath.xyz(bodies[i].invInertia) * (solid / spec.wheelInertia), bodies[i].invInertia.w)
            wheels.append(i)
        }
        return addCar(blueprint, transform: transform, wheels: wheels, velocity: velocity)
    }

    /// ...with its wheels' bodies made (`wheels`, one per corner in the blueprint's order).
    @discardableResult
    package func addCar(_ blueprint: CarBlueprint, transform: float4x4, wheels wheelBodies: [Int], velocity: SIMD3<Float> = .zero) -> Int {
        precondition(wheelBodies.count == blueprint.corners.count, "a body per corner")
        let car = carSystem.cars.count, first = particles.count, spec = blueprint.spec
        for (p, m) in zip(blueprint.nodes, blueprint.masses) {
            let x = PhysicsMath.xyz(transform * SIMD4(p, 1))
            particles.append(GPUPhysicsParticle(position: SIMD4(x, CarBlueprint.radius), velocity: SIMD4(velocity, 0.7),
                                                prevPosition: SIMD4(x, 1 / m), info: SIMD4(PhysicsWorld.none, PhysicsWorld.carBit, 0, UInt32(car))))
        }
        var state = CarState()
        state.firstNode = Int32(first)
        state.nodeCount = Int32(blueprint.nodes.count)
        state.firstBeam = Int32(carSystem.beams.count)
        var tieOf: [Int: Int] = [:]
        for beam in blueprint.beams {
            let (k, c, yield, strength, hardening, strain) = CarBlueprint.strength(beam.zone)
            let rigid = beam.kind == .rigid || beam.kind == .steer
            let stiffness = beam.stiffness ?? (rigid ? 5e7 : k)
            let rest = beam.rest ?? simd_distance(blueprint.nodes[beam.a], blueprint.nodes[beam.b])
            let plastic = beam.kind == .plastic
            if beam.kind == .steer { tieOf[beam.a] = carSystem.beams.count }
            carSystem.beams.append(CarBeam(nodes: SIMD2(UInt32(first + beam.a), UInt32(first + beam.b)), rest: rest, compliance: 1 / stiffness,
                                           damping: beam.damping ?? (rigid ? 0 : c), yield: plastic ? yield : .infinity, load: 0,
                                           info: beam.kind.rawValue | beam.zone.rawValue << 8 | (beam.hull ? CarBeam.hullBit : 0)))
            carSystem.limits.append(CarBeamLimit(rest0: rest, strength: plastic ? strength : .infinity, strainLimit: plastic ? strain : .infinity,
                                                 hardening: hardening, steer: beam.steer))
        }
        state.beamCount = Int32(carSystem.beams.count) - state.firstBeam
        let rotation = simd_float3x3(columns: (PhysicsMath.xyz(transform.columns.0), PhysicsMath.xyz(transform.columns.1),
                                               PhysicsMath.xyz(transform.columns.2)))
        let across = rotation * SIMD3<Float>(1, 0, 0), ahead = rotation * SIMD3<Float>(0, 0, 1)
        state.firstWheel = Int32(carSystem.wheels.count)
        for (corner, i) in zip(blueprint.corners, wheelBodies) {
            var w = CarWheel()
            w.body = Int32(i)
            w.hubIn = UInt32(first + corner.hubIn)
            w.hubOut = UInt32(first + corner.hubOut)
            w.arm = UInt32(first + corner.arm)
            w.hubOffset = corner.hubOffset * corner.side   // (the hub in toward the car's middle: -x on its left)
            w.radius = spec.wheelRadius
            w.width = spec.wheelWidth
            w.brake = corner.front ? spec.frontBrake : spec.rearBrake
            let driven = spec.drive == .all || (spec.drive == .front) == corner.front
            w.flags = (driven ? CarWheel.driven : 0) | (corner.front ? CarWheel.steered | CarWheel.front : CarWheel.handbraked)
            w.tie = corner.front ? Int32(tieOf[corner.arm] ?? -1) : -1
            // Its axle (the car's +x, whichever side: a wheel rolling forward spins positive) in its body's space.
            bodies[i].info.y |= PhysicsWorld.wheelBit
            bodies[i].velocity = SIMD4(velocity, 0)   // (no friction of its own: its tyre's)
            bodies[i].angular = SIMD4(across * dot(velocity, ahead) / spec.wheelRadius, 0)
            w.axle = PhysicsMath.qrot(PhysicsMath.qconj(bodies[i].rotation), across)
            carSystem.wheels.append(w)
        }
        state.wheelCount = Int32(wheelBodies.count)
        state.firstReaction = Int32(carSystem.reactionNodes.count)
        carSystem.reactionNodes += blueprint.engine.map { UInt32(first + $0) }
        state.reactionCount = Int32(blueprint.engine.count)
        state.frame = SIMD3(UInt32(first + blueprint.frame.x), UInt32(first + blueprint.frame.y), UInt32(first + blueprint.frame.z))
        state.mass = blueprint.bodyMass + Float(wheelBodies.count) * spec.wheelMass
        let tune = CarTune(spec)
        state.engine = tune.idle
        carSystem.cars.append(state)
        carSystem.tunes.append(tune)
        return car
    }

    /// Car `car`'s panels `part` drawn (CarSurface), their vertices from `vertexBase` in the scene's vertex buffer: as a
    /// soft body's surface (PhysicsSoft.swift), each vertex on the node hull's triangles (GPUSoftEmbed.triangleKind).
    /// Returns its soft body (Scene.softMeshes' index).
    @discardableResult
    package func addCarSurface(_ part: CarSurface.Part, car: Int, hull: [SIMD3<Int32>], vertexBase: Int) -> Int {
        let body = softBodies.count, s = carSystem.cars[car], base = Int32(s.firstNode)
        for (v, follows) in part.embedding.enumerated() {
            let ring = UInt32(softRings.count) << 5 | UInt32(part.rings[v].count)
            precondition(part.rings[v].count < 32 && softRings.count < 1 << 27, "a ring of 32 triangles or more")
            softRings += part.rings[v].map { $0 &+ UInt32(vertexBase) }
            softVertices.append(GPUSoftVertex(info: SIMD4(UInt32(vertexBase + v), 0, UInt32(body), ring),
                                              embeds: SIMD4(UInt32(softEmbeds.count), UInt32(follows.count), 0, 0)))
            let share = 1 / Float(follows.count)
            softEmbeds += follows.map { f in
                let t = hull[f.triangle] &+ base
                return GPUSoftEmbed(bary: SIMD4(f.bary, share), ids: SIMD4(UInt32(t.x), UInt32(t.y), UInt32(t.z), GPUSoftEmbed.triangleKind))
            }
        }
        softBodies.append(SIMD2(UInt32(s.firstNode), UInt32(s.nodeCount)))
        return body
    }

    /// Once every car is in (PhysicsWorld.finish): their start, and the step's scratch.
    func finishCars() {
        guard hasCars else { return }
        carSystem.loads = [Float](repeating: 0, count: carSystem.beams.count)
        carSystem.lambdas = [Float](repeating: 0, count: carSystem.beams.count)
        carSystem.pushes = [CarPush](repeating: CarPush(), count: carSystem.cars.count * CarSystem.maxPushes)
        carSystem.pushCounts = [Int32](repeating: 0, count: carSystem.cars.count)
        carSystem.telemetry = [CarTelemetry](repeating: CarTelemetry(), count: carSystem.cars.count)
        carSystem.bodyPushes = [SIMD4<Float>](repeating: .zero, count: bodies.count)
        carSystem.bodyTwists = [SIMD3<Float>](repeating: .zero, count: bodies.count)
        carSystem.initialCars = carSystem.cars
        carSystem.initialBeams = carSystem.beams
        carSystem.initialWheels = carSystem.wheels
        for c in carSystem.cars.indices { carSystem.telemetry[c] = carTelemetry(c) }
    }

    /// The cars as built (PhysicsWorld.reset, after the particles are): their state, and what a frame shows of them
    /// from there (not from nowhere, until the first step's end).
    func resetCars() {
        carSystem.reset()
        for c in carSystem.cars.indices { carSystem.telemetry[c] = carTelemetry(c) }
    }

    // MARK: Input

    /// GPUFractureCommand.info.z's flags above the car's index (its low byte).
    package static let carShiftUp: UInt32 = 1 << 8, carShiftDown: UInt32 = 2 << 8, carManual: UInt32 = 4 << 8, carAutopilot: UInt32 = 8 << 8

    /// Car `car`'s input from the step it is added at (PhysicsWorld.none: the next) on: a `car` command.
    package static func carCommand(_ car: Int, _ input: CarInput, shiftUp: Bool = false, shiftDown: Bool = false, at step: UInt32 = PhysicsWorld.none)
        -> GPUFractureCommand {
        let flags = (shiftUp ? carShiftUp : 0) | (shiftDown ? carShiftDown : 0) | (input.manual ? carManual : 0)
            | (input.autopilot ? carAutopilot : 0)
        return GPUFractureCommand(info: SIMD4(step, FractureCommand.car.rawValue, UInt32(car) | flags, 1),
                                  origin: SIMD4(input.accelerate, input.decelerate, input.steer, input.handbrake), direction: input.lap)
    }

    /// A `car` command, at its step: the car's input from now on, and a shift asked for.
    func takeCarCommand(_ c: GPUFractureCommand, clock: UInt32) {
        guard c.info.x == clock else { return }
        let car = Int(c.info.z & 0xFF)
        guard carSystem.cars.indices.contains(car) else { return }
        var input = CarInput()
        input.accelerate = simd_clamp(c.origin.x, 0, 1)
        input.decelerate = simd_clamp(c.origin.y, 0, 1)
        input.steer = simd_clamp(c.origin.z, -1, 1)
        input.handbrake = simd_clamp(c.origin.w, 0, 1)
        input.manual = c.info.z & PhysicsWorld.carManual != 0
        input.autopilot = c.info.z & PhysicsWorld.carAutopilot != 0
        input.lap = c.direction
        var s = carSystem.cars[car]
        s.input = input
        let top = carSystem.tunes[car].gearCount
        if c.info.z & PhysicsWorld.carShiftUp != 0 && s.gear < top {
            s.gear += 1
            s.shifting = 0.2
        }
        if c.info.z & PhysicsWorld.carShiftDown != 0 && s.gear > -1 {
            s.gear -= 1
            s.shifting = 0.2
        }
        carSystem.cars[car] = s
    }

    /// A step's start in a world with cars and no fractured objects: its commands (Physics+Fracture.swift's).
    func beginCarStep() { runCommands(UInt32(stepIndex)) }

    // MARK: The step

    /// What each car's nodes may meet this step (its box grown by how far it may go): the statics, then the bodies,
    /// but the wheels. Its wheels and the bodies close to it are woken while it moves.
    func carBroadPhase(_ p: GPUPhysicsParams) {
        carSystem.candidates.removeAll(keepingCapacity: true)
        let shapes = self.shapes
        for c in carSystem.cars.indices {
            var s = carSystem.cars[c]
            var lo = SIMD3<Float>(repeating: .infinity), hi = -lo, fastest: Float = 0
            for i in Int(s.firstNode)..<Int(s.firstNode + s.nodeCount) {
                let x = PhysicsMath.xyz(particles[i].position)
                lo = simd_min(lo, x)
                hi = simd_max(hi, x)
                fastest = max(fastest, length_squared(PhysicsMath.xyz(particles[i].velocity)))
            }
            let reach = CarBlueprint.radius + fastest.squareRoot() * PhysicsWorld.stepLength + 0.15
            let centre = (lo + hi) / 2, radius = length(hi - lo) / 2 + reach
            s.firstCandidate = Int32(carSystem.candidates.count)
            for st in statics.indices where PhysicsWorld.touchesStatic(statics[st], shapes, staticBounds[st], centre: centre, radius: radius) {
                carSystem.candidates.append(UInt32(st) | PhysicsWorld.staticBit)
            }
            let active = s.awake || s.input != CarInput()
            for j in bodies.indices where bodies[j].info.y & (PhysicsWorld.disabledBit | PhysicsWorld.wheelBit) == 0 && bodies[j].position.w > 0 {
                let d = simd_distance(PhysicsMath.xyz(bodies[j].position), centre), r = bodies[j].invInertia.w
                guard d < r + radius else { continue }
                carSystem.candidates.append(UInt32(j))
                if active && d < r + radius - 0.1 {
                    bodies[j].info.y &= ~PhysicsWorld.asleep
                    bodies[j].prevPosition.w = 0
                }
            }
            s.candidateCount = Int32(carSystem.candidates.count) - s.firstCandidate
            if active {
                for w in Int(s.firstWheel)..<Int(s.firstWheel + s.wheelCount) {
                    let i = Int(carSystem.wheels[w].body)
                    bodies[i].info.y &= ~PhysicsWorld.asleep
                    bodies[i].prevPosition.w = 0
                }
            }
            carSystem.cars[c] = s
        }
    }

    /// Each car's forces this substep (its drivetrain, brakes, tyres, the air), then its nodes moved: before the
    /// bodies move (its wheels with them).
    func carForces(_ p: GPUPhysicsParams, sub: Int) {
        withCarBuffers { b in
            PhysicsPool.shared.parallel(b.cars.count, grain: 1) { range in
                for c in range { CarSolver.carForces(c, b, p, sub: sub) }
            }
        }
    }

    /// Each car's constraints and contacts this substep, after the bodies moved.
    func solveCars(_ p: GPUPhysicsParams, sub: Int) {
        withCarBuffers { b in
            PhysicsPool.shared.parallel(b.cars.count, grain: 1) { range in
                for c in range { CarSolver.solveCar(c, b, p) }
            }
        }
    }

    /// The cars' pushes on the bodies this substep: each body moved by its pushes averaged (as a particle's are), and
    /// woken; summed in the cars' order, so the sums are the same every time.
    func applyCarReactions() {
        withCarBuffers { CarSolver.applyCarReactions($0) }
    }

    /// The step's end: beams that broke, and what a frame shows of each car.
    func endCarStep() {
        let substeps = Float(self.substeps)
        withCarBuffers { b in
            PhysicsPool.shared.parallel(b.cars.count, grain: 1) { range in
                for c in range { CarSolver.breakBeams(c, b, substeps: substeps) }
            }
        }
        for c in carSystem.cars.indices {
            let t = carTelemetry(c), s = carSystem.cars[c]
            carSystem.telemetry[c] = t
            carSystem.cars[c].awake = abs(t.speed) > 0.05 || s.input != CarInput() || s.throttle > 0 || s.steer != 0
        }
    }

    /// Car `c`'s frame and gauges now.
    func carTelemetry(_ c: Int) -> CarTelemetry {
        let s = carSystem.cars[c]
        let f = PhysicsWorld.carFrame(s, particles)
        var t = CarTelemetry()
        t.position = f.centre
        t.forward = f.forward
        t.up = f.up
        t.speed = dot(f.velocity, f.forward)
        t.rpm = s.engine * 30 / .pi
        t.gear = s.gear
        t.throttle = s.throttle
        t.brake = s.brake
        t.steer = s.steer
        t.bent = s.bent
        t.broken = s.broken
        return t
    }

    /// A car's frame: the middle of its floor, its forward, up and left (unit), its velocity (its floor's middle's).
    @inline(__always) package static func carFrame(_ s: CarState, _ q: UnsafeBufferPointer<GPUPhysicsParticle>)
        -> (centre: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, left: SIMD3<Float>, velocity: SIMD3<Float>) {
        let rear = PhysicsMath.xyz(q[Int(s.frame.x)].position), front = PhysicsMath.xyz(q[Int(s.frame.y)].position)
        let side = PhysicsMath.xyz(q[Int(s.frame.z)].position)
        let centre = (rear + front) / 2
        let forward = PhysicsMath.direction(front - rear)
        let up = PhysicsMath.direction(cross(forward, side - centre))
        let velocity = (PhysicsMath.xyz(q[Int(s.frame.x)].velocity) + PhysicsMath.xyz(q[Int(s.frame.y)].velocity)) / 2
        return (centre, forward, up, cross(up, forward), velocity)
    }

    package static func carFrame(_ s: CarState, _ particles: [GPUPhysicsParticle])
        -> (centre: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, left: SIMD3<Float>, velocity: SIMD3<Float>) {
        particles.withUnsafeBufferPointer { carFrame(s, $0) }
    }

    /// `body` with the cars' arrays (and the particles', the bodies', the statics') lent as raw buffers (CarBuffers).
    /// (The car system is moved out meanwhile: its arrays are then a local's, lent side by side.)
    func withCarBuffers<R>(_ body: (CarBuffers) throws -> R) rethrows -> R {
        var system = carSystem
        carSystem = CarSystem()
        defer { carSystem = system }
        let shapes = shapeData
        return try system.cars.withUnsafeMutableBufferPointer { cars in
            try system.beams.withUnsafeMutableBufferPointer { beams in
                try system.limits.withUnsafeMutableBufferPointer { limits in
                    try system.lambdas.withUnsafeMutableBufferPointer { lambdas in
                        try system.loads.withUnsafeMutableBufferPointer { loads in
                            try system.wheels.withUnsafeMutableBufferPointer { wheels in
                                try system.reactionNodes.withUnsafeBufferPointer { reactions in
                                    try system.tunes.withUnsafeBufferPointer { tunes in
                                        try system.candidates.withUnsafeBufferPointer { candidates in
                                            try system.pushes.withUnsafeMutableBufferPointer { pushes in
                                                try system.pushCounts.withUnsafeMutableBufferPointer { pushCounts in
                                                    try system.bodyPushes.withUnsafeMutableBufferPointer { bodyPushes in
                                                        try system.bodyTwists.withUnsafeMutableBufferPointer { bodyTwists in
                                                            try particles.withUnsafeMutableBufferPointer { particles in
                                                                try bodies.withUnsafeMutableBufferPointer { bodies in
                                                                    try statics.withUnsafeBufferPointer { statics in
                                                                        try staticBounds.withUnsafeBufferPointer { bounds in
                                                                            try body(CarBuffers(cars: cars, beams: beams, limits: limits, loads: loads, lambdas: lambdas, wheels: wheels,
                                                                                                reactions: reactions, tunes: tunes, candidates: candidates, pushes: pushes,
                                                                                                pushCounts: pushCounts, bodyPushes: bodyPushes, bodyTwists: bodyTwists, particles: particles,
                                                                                                bodies: bodies, statics: statics, staticBounds: bounds, shapes: shapes))
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension CarSolver {
    /// The cars' pushes on the bodies (PhysicsWorld.applyCarReactions).
    @inline(__always) package static func applyCarReactions(_ b: CarBuffers) {
        for c in b.cars.indices {
            let first = c * CarSystem.maxPushes
            for k in first..<first + Int(b.pushCounts[c]) {
                let push = b.pushes[k], j = Int(push.body)
                b.bodyPushes[j] += SIMD4(push.impulse, push.count)
                b.bodyTwists[j] += push.twist
            }
        }
        // Each body pushed once (its sums cleared as it moves), found from the pushes rather than every body.
        for c in b.cars.indices {
            let first = c * CarSystem.maxPushes
            for k in first..<first + Int(b.pushCounts[c]) {
                let j = Int(b.pushes[k].body), total = b.bodyPushes[j], count = total.w
                guard count > 0 else { continue }
                var body = b.bodies[j]
                body.info.y &= ~PhysicsWorld.asleep
                body.prevPosition.w = 0
                if body.position.w > 0 {
                    body.position = SIMD4(PhysicsMath.xyz(body.position) + PhysicsMath.xyz(total) / count * body.position.w, body.position.w)
                    body.rotation = PhysicsMath.qturn(body.rotation, PhysicsMath.applyInvInertia(body.rotation, PhysicsMath.xyz(body.invInertia),
                                                                                               b.bodyTwists[j] / count))
                }
                b.bodies[j] = body
                b.bodyPushes[j] = .zero
                b.bodyTwists[j] = .zero
            }
        }
    }
}

/// The cars' arrays as a substep's stages read and write them (PhysicsWorld.withCarBuffers): each car writes only its
/// own nodes, beams, wheels (their bodies) and pushes.
package struct CarBuffers {
    let cars: UnsafeMutableBufferPointer<CarState>
    let beams: UnsafeMutableBufferPointer<CarBeam>
    let limits: UnsafeMutableBufferPointer<CarBeamLimit>
    let loads: UnsafeMutableBufferPointer<Float>
    let lambdas: UnsafeMutableBufferPointer<Float>
    let wheels: UnsafeMutableBufferPointer<CarWheel>
    let reactions: UnsafeBufferPointer<UInt32>
    let tunes: UnsafeBufferPointer<CarTune>
    let candidates: UnsafeBufferPointer<UInt32>
    let pushes: UnsafeMutableBufferPointer<CarPush>
    let pushCounts: UnsafeMutableBufferPointer<Int32>
    let bodyPushes: UnsafeMutableBufferPointer<SIMD4<Float>>
    let bodyTwists: UnsafeMutableBufferPointer<SIMD3<Float>>
    let particles: UnsafeMutableBufferPointer<GPUPhysicsParticle>
    let bodies: UnsafeMutableBufferPointer<GPUPhysicsBody>
    let statics: UnsafeBufferPointer<GPUPhysicsBody>
    let staticBounds: UnsafeBufferPointer<AABB>
    let shapes: PhysicsShapes
}
