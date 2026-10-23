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
    /// A car's drawn vertex (GPUSoftVertex.embeds.z): `carVertexBit`, its pane or lamp (1 + its place among its car's,
    /// in the low byte; 0: none) and `lampBit` (a lamp goes dark when it breaks; a pane folds away). MSL
    /// PHYS_CAR_VERTEX, PHYS_CAR_LAMP.
    package static let carVertexBit: UInt32 = 1 << 31, lampBit: UInt32 = 1 << 8
    /// The front's crush (m) a radiator starts to leak at, and how far more it leaks at its worst; the crush the
    /// engine block starts to break at, and how much more breaks it. (Floats: a SIMD constant's literal is made at run
    /// time, behind a swift_once the step's loop would call.)
    package static let radiatorCrush: Float = 0.08, radiatorSpan: Float = 0.25, blockCrush: Float = 0.5, blockSpan: Float = 0.3
    /// What a wheel's axle breaks at (N, along the ground, in a substep: CarWheel.axleKnock; a 60 km/h curb knocks
    /// 39 kN, a speed bump at 60 km/h 23 kN).
    package static let axleStrength: Float = 32_000
    /// How much a pane's frame strains before it shatters, a lamp's before it breaks.
    package static let glassStrain: Float = 0.008, lampStrain: Float = 0.03
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
    /// `wheelInstances` (one per corner, in the blueprint's order); its glass's panes and its lamps `panes` (its
    /// surface's: CarSurface.panes, whose order the drawn vertices' flags name). Returns the car.
    @discardableResult
    package func addCar(_ blueprint: CarBlueprint, transform: float4x4, rimSDF: Int, wheelInstances: [Int], velocity: SIMD3<Float> = .zero,
                        panes: [CarSurface.Pane] = []) -> Int {
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
        return addCar(blueprint, transform: transform, wheels: wheels, velocity: velocity, panes: panes)
    }

    /// ...with its wheels' bodies made (`wheels`, one per corner in the blueprint's order).
    @discardableResult
    package func addCar(_ blueprint: CarBlueprint, transform: float4x4, wheels wheelBodies: [Int], velocity: SIMD3<Float> = .zero,
                        panes: [CarSurface.Pane] = []) -> Int {
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
        var tieOf: [Int: Int] = [:], beamOf: [SIMD2<Int>: Int] = [:]
        for (k, beam) in blueprint.beams.enumerated() { beamOf[SIMD2(min(beam.a, beam.b), max(beam.a, beam.b))] = k }
        for beam in blueprint.beams {
            var (k, c, yield, strength, hardening, strain) = CarBlueprint.strength(beam.zone)
            if let s = beam.strength { (yield, strength) = (0.6 * s, s) }
            let rigid = beam.kind == .rigid || beam.kind == .steer
            let stiffness = beam.stiffness ?? (rigid ? 5e7 : k)
            let rest = beam.rest ?? simd_distance(blueprint.nodes[beam.a], blueprint.nodes[beam.b])
            if let f = beam.flowLimit { strain = f / max(rest, 1e-3) }
            // (A tie rod bends as an arm does: its flow is kept apart from the steering's length, CarBeamLimit.bend.)
            let yields = beam.kind == .plastic || beam.kind == .steer
            if beam.kind == .steer { tieOf[beam.a] = carSystem.beams.count }
            carSystem.beams.append(CarBeam(nodes: SIMD2(UInt32(first + beam.a), UInt32(first + beam.b)), rest: rest, compliance: 1 / stiffness,
                                           damping: beam.damping ?? (rigid ? 0 : c), yield: yields ? yield : .infinity, load: 0,
                                           info: beam.kind.rawValue | beam.zone.rawValue << 8 | (beam.hull ? CarBeam.hullBit : 0)
                                               | (beam.corner ? CarBeam.cornerBit : 0) | (beam.attach ? CarBeam.attachBit : 0)
                                               | UInt32(beam.part) << CarBeam.partShift))
            carSystem.limits.append(CarBeamLimit(rest0: rest, strength: yields ? strength : .infinity, strainLimit: yields ? strain : .infinity,
                                                 hardening: hardening, steer: beam.steer))
        }
        state.beamCount = Int32(carSystem.beams.count) - state.firstBeam
        state.firstCorner = state.firstBeam + Int32(blueprint.firstCorner)
        state.firstRadiator = Int32(carSystem.radiatorNodes.count)
        let engine = blueprint.engine.reduce(SIMD3<Float>()) { $0 + blueprint.nodes[$1] } / Float(max(blueprint.engine.count, 1))
        carSystem.radiatorNodes += blueprint.radiator.map { UInt32(first + $0) }
        carSystem.radiatorReach += blueprint.radiator.map { blueprint.nodes[$0].z - engine.z }
        state.radiatorCount = Int32(blueprint.radiator.count)
        state.firstPart = Int32(carSystem.parts.count)
        for (p, part) in blueprint.parts.enumerated() {
            let holding = blueprint.beams.filter { $0.attach && $0.part == p + 1 }.count
            carSystem.parts.append(CarPart(firstNode: Int32(first + part.firstNode), nodeCount: Int32(part.nodeCount),
                                           inverseMass: Float(part.nodeCount) / part.mass, kind: part.kind.rawValue, holding: Int32(holding),
                                           attachments: Int32(holding)))
        }
        state.partCount = Int32(blueprint.parts.count)
        // Its panes and lamps: each one's frame the plastic beams among the nodes of the triangles it is on.
        state.firstPane = Int32(carSystem.panes.count)
        for pane in panes {
            let on = Set(pane.hull.flatMap { t in [Int(blueprint.hull[t].x), Int(blueprint.hull[t].y), Int(blueprint.hull[t].z)] }).sorted()
            let frame = blueprint.beams.indices.filter { k in
                let beam = blueprint.beams[k]
                return beam.kind == .plastic && !beam.attach && on.contains(beam.a) && on.contains(beam.b)
            }
            guard !on.isEmpty else { continue }
            let corners = [0, on.count / 3, 2 * on.count / 3, on.count - 1].map { UInt32(first + on[$0]) }
            carSystem.panes.append(CarPane(firstFrame: Int32(carSystem.paneFrames.count), frameCount: Int32(frame.count), part: Int32(pane.part),
                                           lamp: pane.lamp, corners: SIMD4(corners[0], corners[1], corners[2], corners[3])))
            carSystem.paneFrames += frame.map { UInt32(Int(state.firstBeam) + $0) }
        }
        state.paneCount = Int32(carSystem.panes.count) - state.firstPane
        precondition(state.paneCount <= 16, "a car of more than 16 panes and lamps")
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
            for (k, l) in corner.links.prefix(8).enumerated() {
                w.links[k] = beamOf[SIMD2(min(l.x, l.y), max(l.x, l.y))].map { Int32(Int(state.firstBeam) + $0) } ?? -1
            }
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
        state.ringNodes = Int32(blueprint.rings.reduce(0) { $0 + $1.count })
        precondition(blueprint.rings.joined().max().map { $0 < Int(state.ringNodes) } ?? true, "the rings' nodes first")
        state.mass = blueprint.bodyMass + Float(wheelBodies.count) * spec.wheelMass
        let tune = CarTune(spec)
        state.engine = tune.idle
        carSystem.cars.append(state)
        carSystem.tunes.append(tune)
        return car
    }

    /// Car `car`'s panels `part` drawn (CarSurface), their vertices from `vertexBase` in the scene's vertex buffer: as a
    /// soft body's surface (PhysicsSoft.swift), each vertex on the node hull's triangles (GPUSoftEmbed.triangleKind),
    /// with its car's flags (GPUSoftVertex.embeds.z: `carVertexBit`, its pane or lamp) and first node (.w: where its
    /// damage and its panes' breaks are read, `carDamage`).
    /// Returns its soft body (Scene.softMeshes' index).
    @discardableResult
    package func addCarSurface(_ part: CarSurface.Part, car: Int, hull: [SIMD3<Int32>], vertexBase: Int) -> Int {
        let body = softBodies.count, s = carSystem.cars[car], base = Int32(s.firstNode)
        for (v, follows) in part.embedding.enumerated() {
            let ring = UInt32(softRings.count) << 5 | UInt32(part.rings[v].count)
            precondition(part.rings[v].count < 32 && softRings.count < 1 << 27, "a ring of 32 triangles or more")
            softRings += part.rings[v].map { $0 &+ UInt32(vertexBase) }
            softVertices.append(GPUSoftVertex(info: SIMD4(UInt32(vertexBase + v), 0, UInt32(body), ring),
                                              embeds: SIMD4(UInt32(softEmbeds.count), UInt32(follows.count), PhysicsWorld.carVertexBit | part.flags[v],
                                                            UInt32(s.firstNode))))
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
        carSystem.events = [GPUBreakEvent](repeating: GPUBreakEvent(), count: carSystem.cars.count * CarSystem.maxEvents)
        carSystem.eventCounts = [Int32](repeating: 0, count: carSystem.cars.count)
        carSystem.wear = [SIMD2<Float>](repeating: .zero, count: particles.count)
        carSystem.initialCars = carSystem.cars
        carSystem.initialBeams = carSystem.beams
        carSystem.initialLimits = carSystem.limits
        carSystem.initialWheels = carSystem.wheels
        carSystem.initialParts = carSystem.parts
        carSystem.initialPanes = carSystem.panes
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
            // Its parts that came off and froze, woken by a body that comes near (their nodes have their mass back).
            for p in Int(s.firstPart)..<Int(s.firstPart + s.partCount) where carSystem.parts[p].flags & CarPart.frozen != 0 {
                let part = carSystem.parts[p], x = PhysicsMath.xyz(particles[Int(part.firstNode)].position)
                let near = carSystem.candidates[Int(s.firstCandidate)...].contains { code in
                    code & PhysicsWorld.staticBit == 0 && simd_distance(PhysicsMath.xyz(bodies[Int(code)].position), x) < bodies[Int(code)].invInertia.w + 1
                }
                guard near else { continue }
                for i in Int(part.firstNode)..<Int(part.firstNode + part.nodeCount) { particles[i].prevPosition.w = part.inverseMass }
                carSystem.parts[p].flags &= ~CarPart.frozen
                carSystem.parts[p].still = 0
            }
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

    /// The step's end: beams that broke, the damage (CarDamage.swift: dents, scrapes, parts, wheels, panes, the engine),
    /// the events it left for the dust in the cars' order, and what a frame shows of each car.
    func endCarStep() {
        let substeps = Float(self.substeps)
        withCarBuffers { b in
            PhysicsPool.shared.parallel(b.cars.count, grain: 1) { range in
                for c in range {
                    CarSolver.breakBeams(c, b, substeps: substeps)
                    CarSolver.damage(c, b, substeps: substeps)
                }
            }
        }
        var logged = 0
        for c in carSystem.cars.indices {
            for k in 0..<Int(carSystem.eventCounts[c]) {
                breakLog.append(carSystem.events[c * CarSystem.maxEvents + k])
                breakSteps.append(stepIndex)
                logged += 1
            }
            carSystem.eventCounts[c] = 0
        }
        if logged > 0 {
            breakTotal += logged
            if breakLog.count > PhysicsWorld.breakLogLength {
                breakLog.removeFirst(breakLog.count - PhysicsWorld.breakLogLength)
                breakSteps.removeFirst(breakSteps.count - PhysicsWorld.breakLogLength)
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
        var centre = SIMD3<Float>()
        for i in Int(s.firstNode)..<Int(s.firstNode + s.ringNodes) { centre += PhysicsMath.xyz(particles[i].position) }
        t.centre = centre / Float(max(s.ringNodes, 1))
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
        t.frontCrush = s.frontCrush
        t.coolant = s.coolant
        t.heat = s.heat
        t.engineDamage = s.engineDamage
        t.running = s.running
        t.partsOff = s.partsOff
        t.wheelsOff = s.wheelsOff
        t.panesBroken = s.panesBroken
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
        try system.parts.withUnsafeMutableBufferPointer { parts in
        try system.panes.withUnsafeMutableBufferPointer { panes in
        try system.paneFrames.withUnsafeBufferPointer { paneFrames in
        try system.radiatorNodes.withUnsafeBufferPointer { radiator in
        try system.radiatorReach.withUnsafeBufferPointer { reach in
        try system.events.withUnsafeMutableBufferPointer { events in
        try system.eventCounts.withUnsafeMutableBufferPointer { eventCounts in
        try system.wear.withUnsafeMutableBufferPointer { wear in
        try particles.withUnsafeMutableBufferPointer { particles in
        try bodies.withUnsafeMutableBufferPointer { bodies in
        try statics.withUnsafeBufferPointer { statics in
        try staticBounds.withUnsafeBufferPointer { bounds in
            try body(CarBuffers(cars: cars, beams: beams, limits: limits, loads: loads, lambdas: lambdas, wheels: wheels, reactions: reactions,
                                tunes: tunes, candidates: candidates, pushes: pushes, pushCounts: pushCounts, bodyPushes: bodyPushes,
                                bodyTwists: bodyTwists, parts: parts, panes: panes, paneFrames: paneFrames, radiator: radiator, reach: reach, events: events,
                                eventCounts: eventCounts, wear: wear, particles: particles, bodies: bodies, statics: statics, staticBounds: bounds,
                                shapes: shapes))
        }}}}}}}}}}}}}}}}}}}}}}}}}
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
    let parts: UnsafeMutableBufferPointer<CarPart>
    let panes: UnsafeMutableBufferPointer<CarPane>
    let paneFrames: UnsafeBufferPointer<UInt32>
    let radiator: UnsafeBufferPointer<UInt32>
    let reach: UnsafeBufferPointer<Float>
    let events: UnsafeMutableBufferPointer<GPUBreakEvent>
    let eventCounts: UnsafeMutableBufferPointer<Int32>
    let wear: UnsafeMutableBufferPointer<SIMD2<Float>>
    let particles: UnsafeMutableBufferPointer<GPUPhysicsParticle>
    let bodies: UnsafeMutableBufferPointer<GPUPhysicsBody>
    let statics: UnsafeBufferPointer<GPUPhysicsBody>
    let staticBounds: UnsafeBufferPointer<AABB>
    let shapes: PhysicsShapes
}
