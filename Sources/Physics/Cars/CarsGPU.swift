import EngineCore
import Metal
import simd

/// A car as the GPU steps it (CarState's, without Swift's Bools and nested input): MSL PhysicsCar.
package struct GPUCar {
    package var lo = SIMD4<Float>()          // its box this step; w = its mass (kg)
    package var hi = SIMD4<Float>()
    package var momentum = SIMD4<Float>()    // as the step began (PhysicsWorld.carsGiveWay)
    package var input = SIMD4<Float>()       // accelerate, decelerate, steer, handbrake
    package var lap = SIMD4<Float>()
    package var controls = SIMD4<Float>()    // throttle, brake, handbrake, steer (ramped)
    package var firstNode: Int32 = 0, nodeCount: Int32 = 0, ringNodes: Int32 = 0, firstBeam: Int32 = 0
    package var beamCount: Int32 = 0, firstCorner: Int32 = 0, firstColour: Int32 = 0, colourCount: Int32 = 0
    package var cornerColour: Int32 = 0, cornerColours: Int32 = 0, firstWheel: Int32 = 0, wheelCount: Int32 = 0
    package var firstReaction: Int32 = 0, reactionCount: Int32 = 0, frame0: UInt32 = 0, frame1: UInt32 = 0
    package var frame2: UInt32 = 0, firstPart: Int32 = 0, partCount: Int32 = 0, firstPane: Int32 = 0
    package var paneCount: Int32 = 0, firstRadiator: Int32 = 0, radiatorCount: Int32 = 0, firstTriangle: Int32 = 0
    package var triangleCount: Int32 = 0, candidateCount: Int32 = 0, flags: UInt32 = 0, gear: Int32 = 0
    package var engine: Float = 0, shifting: Float = 0, clutch: Float = 0, sinceShift: Float = 0
    package var still: Float = 0, frontCrush: Float = 0, coolant: Float = 1, heat: Float = 0
    package var engineDamage: Float = 0, bent: Int32 = 0, broken: Int32 = 0, partsOff: Int32 = 0
    package var wheelsOff: Int32 = 0, panesBroken: Int32 = 0, sinceSmoke: Int32 = 0, eventCount: Int32 = 0
    package var hitCount: Int32 = 0, pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0

    /// MSL PHYS_CAR_MANUAL...
    package static let manual: UInt32 = 1, autopilot: UInt32 = 2, running: UInt32 = 4, awake: UInt32 = 8, asleep: UInt32 = 16
}

/// A car's tuning as the GPU reads it (CarTune's): MSL PhysicsCarTune.
package struct GPUCarTune {
    package var rpm0 = SIMD4<Float>(), rpm1 = SIMD4<Float>()
    package var torque0 = SIMD4<Float>(), torque1 = SIMD4<Float>()
    package var gears0 = SIMD4<Float>(), gears1 = SIMD4<Float>()
    package var gearCount: Int32 = 0
    package var reverse: Float = 0, finalDrive: Float = 0, idle: Float = 0, limiter: Float = 0, engineInertia: Float = 0
    package var clutchTorque: Float = 0, limitedSlip: Float = 0, handbrake: Float = 0, steer: Float = 0, steerRate: Float = 0
    package var dragArea: Float = 0, grip: Float = 0, tyreStiffness: Float = 0, tyreDamping: Float = 0, wheelMass: Float = 0
    package var assists: UInt32 = 0
    package var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0

    init(_ t: CarTune) {
        (rpm0, rpm1) = (t.rpm.lowHalf, t.rpm.highHalf)
        (torque0, torque1) = (t.torque.lowHalf, t.torque.highHalf)
        (gears0, gears1) = (t.gears.lowHalf, t.gears.highHalf)
        gearCount = t.gearCount
        (reverse, finalDrive, idle, limiter, engineInertia) = (t.reverse, t.finalDrive, t.idle, t.limiter, t.engineInertia)
        (clutchTorque, limitedSlip, handbrake, steer, steerRate) = (t.clutchTorque, t.limitedSlip, t.handbrake, t.steer, t.steerRate)
        (dragArea, grip, tyreStiffness, tyreDamping, wheelMass) = (t.dragArea, t.grip, t.tyreStiffness, t.tyreDamping, t.wheelMass)
        assists = t.assists ? 1 : 0
    }
}

/// What a frame shows of a car, as the GPU's step leaves it (CarTelemetry's): MSL PhysicsCarTelemetry.
package struct GPUCarTelemetry {
    package var position = SIMD4<Float>()    // w = speed (m/s)
    package var centre = SIMD4<Float>()      // w = rpm
    package var forward = SIMD4<Float>()     // w = throttle
    package var up = SIMD4<Float>()          // w = brake
    package var steer: Float = 0
    package var gear: Int32 = 0, bent: Int32 = 0, broken: Int32 = 0
    package var frontCrush: Float = 0, coolant: Float = 0, heat: Float = 0, engineDamage: Float = 0
    package var flags: UInt32 = 0            // GPUCar.running, asleep
    package var partsOff: Int32 = 0, wheelsOff: Int32 = 0, panesBroken: Int32 = 0

    package var telemetry: CarTelemetry {
        var t = CarTelemetry()
        t.position = PhysicsMath.xyz(position)
        t.centre = PhysicsMath.xyz(centre)
        t.forward = PhysicsMath.xyz(forward)
        t.up = PhysicsMath.xyz(up)
        t.speed = position.w
        t.rpm = centre.w
        t.gear = gear
        t.throttle = forward.w
        t.brake = up.w
        t.steer = steer
        t.bent = bent
        t.broken = broken
        t.frontCrush = frontCrush
        t.coolant = coolant
        t.heat = heat
        t.engineDamage = engineDamage
        t.running = flags & GPUCar.running != 0
        t.partsOff = partsOff
        t.wheelsOff = wheelsOff
        t.panesBroken = panesBroken
        return t
    }
}

/// The cars on the GPU (Shaders/PhysicsCars.metal), for PhysicsGPU: the world's cars' state in buffers, and their
/// stages encoded among the world's. A car is a threadgroup: its step's start (its commands, box and candidates), each
/// group of its substeps in one dispatch (its beams a colour at a time, `colours`), its step's end (bends, breaks,
/// damage, telemetry, sleep), then the step's events into the ring of breaks in the cars' order.
///
/// A car's nodes are the world's last particles: the world's particle stages are told only of the others
/// (`worldParticles`). Its wheels are the world's bodies, kinematic and of no mass to the world (`prepare`): the car's
/// kernels move them, the world's bodies meet them as they would a moving wall.
package final class CarsGPU {
    /// A car's static candidates this step, at most (MSL PHYS_CAR_CANDIDATES).
    static let maxCandidates = 256
    /// Threads a car's threadgroup.
    static let width = 256
    /// The most nodes a car has (its substeps keep them in threadgroup memory: MSL PHYS_CAR_NODES).
    static let maxNodes = 448
    /// ...and corners' beams (their passes in threadgroup memory: MSL PHYS_CAR_CORNERS).
    static let maxCorners = 288

    let count: Int
    /// The world's particles before the cars' nodes (its particle stages' count).
    let worldParticles: Int
    /// What a reset puts back (the cars, their beams, limits, wheels, parts, panes: one block), and what it clears (the
    /// beams' loads and lambdas, the nodes' wear and pushes, the clock).
    private let state: MTLBuffer, initialState: MTLBuffer, scratch: MTLBuffer
    private let carsAt: Int, beamsAt: Int, limitsAt: Int, wheelsAt: Int, partsAt: Int, panesAt: Int
    private let loadsAt: Int, lambdasAt: Int, wearAt: Int, pushesAt: Int, clockAt: Int
    private let tunes: MTLBuffer, reactions: MTLBuffer, colours: MTLBuffer, colourStarts: MTLBuffer, candidates: MTLBuffer
    private let paneFrames: MTLBuffer, radiator: MTLBuffer, reach: MTLBuffer, events: MTLBuffer, telemetry: MTLBuffer
    private let carCount: MTLBuffer
    /// Per frame slot, its steps' commands (a count, then the commands), and the telemetry as its frame left it (the
    /// step, then each car's).
    private let commands: [MTLBuffer]
    private let snapshots: [MTLBuffer]
    /// The commands' slot holds this many at most.
    static let maxCommands = 256
    /// Steps encoded since the last reset: the first step a frame's commands are for.
    private var stepsEncoded = 0
    /// Its beams' colours, all and the corners' (for tests and the notes).
    package let colourCounts: [SIMD2<Int>]
    /// The CPU's beam at each of the GPU's places (a car's beams in their colours' order).
    private let beamOrder: [Int]

    /// The world's bodies as the GPU starts them: each car's wheels kinematic, of no mass (their own in CarWheel).
    package static func prepare(_ bodies: inout [GPUPhysicsBody], _ system: CarSystem) {
        for w in system.wheels where w.body >= 0 && w.flags & CarWheel.off == 0 {
            bodies[Int(w.body)].position.w = 0
            bodies[Int(w.body)].info.y |= PhysicsWorld.kinematicBit
        }
    }

    /// The first particle of the cars' nodes (they are the world's last), or nil when another kind of particle follows.
    package static func firstNode(_ world: PhysicsWorld) -> Int? {
        let first = world.carSystem.cars.map { Int($0.firstNode) }.min() ?? world.particles.count
        guard world.particles[first...].allSatisfy({ $0.info.y & PhysicsWorld.carBit != 0 }) else { return nil }
        return first
    }

    /// The beams `range` of `beams` in colours: each takes the first colour none of the beams before it on either of its
    /// nodes has (so a beam and its mirror, next in the order, share a colour unless they share a node; when they do,
    /// the one first in the order goes first, as on the CPU, which alternates the sides pair by pair).
    static func colours(_ range: Range<Int>, _ beams: [CarBeam]) -> [[UInt32]] {
        var runs: [[UInt32]] = []
        var taken: [UInt32: [UInt64]] = [:]
        func free(_ node: UInt32, _ c: Int) -> Bool {
            guard let words = taken[node], c / 64 < words.count else { return true }
            return words[c / 64] & (1 << UInt64(c % 64)) == 0
        }
        func take(_ node: UInt32, _ c: Int) {
            var words = taken[node] ?? []
            while words.count <= c / 64 { words.append(0) }
            words[c / 64] |= 1 << UInt64(c % 64)
            taken[node] = words
        }
        for k in range {
            let n = beams[k].nodes
            var c = 0
            while !(free(n.x, c) && free(n.y, c)) { c += 1 }
            take(n.x, c)
            take(n.y, c)
            while runs.count <= c { runs.append([]) }
            runs[c].append(UInt32(k))
        }
        return runs
    }

    init(device: MTLDevice, world: PhysicsWorld, firstNode: Int, slots: Int) throws {
        func buffer<T>(_ array: [T], _ label: String, length: Int? = nil) throws -> MTLBuffer {
            let size = max(length ?? array.count * MemoryLayout<T>.stride, 256)
            guard let b = device.makeBuffer(length: size, options: .storageModeShared) else { throw RendererError.resourceCreation("buffer \(label)") }
            array.withUnsafeBytes { raw in if !raw.isEmpty { b.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count) } }
            b.label = label
            return b
        }
        let system = world.carSystem
        precondition(MemoryLayout<CarWheel>.offset(of: \CarWheel.inverseMass) == 92 && MemoryLayout<CarWheel>.stride == 128,
                     "CarWheel: MSL PhysicsCarWheel")
        precondition(MemoryLayout<CarPane>.stride == 32 && MemoryLayout<GPUCar>.stride == 288 && MemoryLayout<GPUCarTune>.stride == 176
                     && MemoryLayout<GPUCarTelemetry>.stride == 112, "the cars' GPU twins: MSL")
        count = system.cars.count
        worldParticles = firstNode
        // The beams' colours. On the GPU each car's beams are in their colours' order (a colour's beams one run: its
        // `starts` are places among the beams), and what names a beam names its place there (`order`: the GPU's beam
        // at each place, the CPU's index); the corners' colours a list of those places (its `starts` places in it).
        var colourList: [UInt32] = [], starts: [UInt32] = [], counts: [SIMD2<Int>] = []
        var order = Array(0..<system.initialBeams.count), place = Array(0..<system.initialBeams.count)
        var cars: [GPUCar] = []
        var wheels = system.initialWheels
        for k in wheels.indices where wheels[k].body >= 0 { wheels[k].inverseMass = world.initialBodies[Int(wheels[k].body)].position.w }
        for s in system.initialCars {
            let all = CarsGPU.colours(Int(s.firstBeam)..<Int(s.firstBeam + s.beamCount), system.initialBeams)
            var at = Int(s.firstBeam)
            for run in all {
                for k in run {
                    order[at] = Int(k)
                    place[Int(k)] = at
                    at += 1
                }
            }
        }
        for (c, s) in system.initialCars.enumerated() {
            let all = CarsGPU.colours(Int(s.firstBeam)..<Int(s.firstBeam + s.beamCount), system.initialBeams)
            let corners = CarsGPU.colours(Int(s.firstCorner)..<Int(s.firstBeam + s.beamCount), system.initialBeams)
            var g = GPUCar()
            g.firstColour = Int32(starts.count)
            var at = UInt32(s.firstBeam)
            for run in all { starts.append(at); at += UInt32(run.count) }
            starts.append(at)
            g.colourCount = Int32(all.count)
            g.cornerColour = Int32(starts.count)
            for run in corners { starts.append(UInt32(colourList.count)); colourList += run.map { UInt32(place[Int($0)]) } }
            starts.append(UInt32(colourList.count))
            g.cornerColours = Int32(corners.count)
            counts.append(SIMD2(all.count, corners.count))
            g.lo.w = s.mass
            g.input = SIMD4(s.input.accelerate, s.input.decelerate, s.input.steer, s.input.handbrake)
            g.lap = s.input.lap
            g.controls = SIMD4(s.throttle, s.brake, s.handbrake, s.steer)
            (g.firstNode, g.nodeCount, g.ringNodes, g.firstBeam) = (s.firstNode, s.nodeCount, s.ringNodes, s.firstBeam)
            (g.beamCount, g.firstCorner) = (s.beamCount, s.firstCorner)
            (g.firstWheel, g.wheelCount, g.firstReaction, g.reactionCount) = (s.firstWheel, s.wheelCount, s.firstReaction, s.reactionCount)
            (g.frame0, g.frame1, g.frame2) = (s.frame.x, s.frame.y, s.frame.z)
            (g.firstPart, g.partCount, g.firstPane, g.paneCount) = (s.firstPart, s.partCount, s.firstPane, s.paneCount)
            (g.firstRadiator, g.radiatorCount, g.firstTriangle, g.triangleCount) = (s.firstRadiator, s.radiatorCount, s.firstTriangle, s.triangleCount)
            g.flags = (s.input.manual ? GPUCar.manual : 0) | (s.input.autopilot ? GPUCar.autopilot : 0) | (s.running ? GPUCar.running : 0)
                | (s.awake ? GPUCar.awake : 0) | (s.asleep ? GPUCar.asleep : 0)
            (g.gear, g.engine, g.shifting, g.clutch, g.sinceShift) = (s.gear, s.engine, s.shifting, s.clutch, s.sinceShift)
            (g.still, g.frontCrush, g.coolant, g.heat, g.engineDamage) = (s.still, s.frontCrush, s.coolant, s.heat, s.engineDamage)
            (g.bent, g.broken, g.partsOff, g.wheelsOff, g.panesBroken, g.sinceSmoke) = (s.bent, s.broken, s.partsOff, s.wheelsOff, s.panesBroken, s.sinceSmoke)
            precondition(Int(s.firstNode) >= firstNode && c < 256, "a car's nodes among the world's last particles")
            precondition(Int(s.nodeCount) <= CarsGPU.maxNodes, "a car of more than \(CarsGPU.maxNodes) nodes")
            precondition(Int(s.firstBeam + s.beamCount - s.firstCorner) <= CarsGPU.maxCorners, "a car of more than \(CarsGPU.maxCorners) corner beams")
            cars.append(g)
        }
        colourCounts = counts
        for k in wheels.indices {
            if wheels[k].tie >= 0 { wheels[k].tie = Int32(place[Int(wheels[k].tie)]) }
            for j in 0..<8 where wheels[k].links[j] >= 0 { wheels[k].links[j] = Int32(place[Int(wheels[k].links[j])]) }
        }
        let beamsInOrder = order.map { system.initialBeams[$0] }, limitsInOrder = order.map { system.initialLimits[$0] }
        beamOrder = order
        // The state block, as built (and again on a reset).
        func align(_ n: Int) -> Int { (n + 255) & ~255 }
        var at = 0
        func put(_ bytes: Int) -> Int { defer { at += align(bytes) }; return at }
        let offsets = [put(cars.count * MemoryLayout<GPUCar>.stride), put(beamsInOrder.count * MemoryLayout<CarBeam>.stride),
                       put(limitsInOrder.count * MemoryLayout<CarBeamLimit>.stride), put(wheels.count * MemoryLayout<CarWheel>.stride),
                       put(system.initialParts.count * MemoryLayout<CarPart>.stride), put(system.initialPanes.count * MemoryLayout<CarPane>.stride)]
        (carsAt, beamsAt, limitsAt, wheelsAt, partsAt, panesAt) = (offsets[0], offsets[1], offsets[2], offsets[3], offsets[4], offsets[5])
        let initial = try buffer([UInt8](), "carsInitialState", length: at)
        func write<T>(_ array: [T], at offset: Int) {
            array.withUnsafeBytes { raw in if !raw.isEmpty { initial.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count) } }
        }
        write(cars, at: offsets[0])
        write(beamsInOrder, at: offsets[1])
        write(limitsInOrder, at: offsets[2])
        write(wheels, at: offsets[3])
        write(system.initialParts, at: offsets[4])
        write(system.initialPanes, at: offsets[5])
        initialState = initial
        state = try buffer([UInt8](), "carsState", length: at)
        state.contents().copyMemory(from: initial.contents(), byteCount: at)
        // The scratch, cleared.
        let beams = system.initialBeams.count, particles = world.particles.count
        at = 0
        let sums = [put(beams * 4), put(beams * 4), put(particles * 8), put(particles * 16), put(16)]
        (loadsAt, lambdasAt, wearAt, pushesAt, clockAt) = (sums[0], sums[1], sums[2], sums[3], sums[4])
        scratch = try buffer([UInt8](), "carsScratch", length: at)
        memset(scratch.contents(), 0, scratch.length)
        tunes = try buffer(system.tunes.map(GPUCarTune.init), "carsTunes")
        reactions = try buffer(system.reactionNodes, "carsReactions")
        colours = try buffer(colourList, "carsColours")
        colourStarts = try buffer(starts, "carsColourStarts")
        candidates = try buffer([UInt32](), "carsCandidates", length: count * CarsGPU.maxCandidates * 4)
        paneFrames = try buffer(system.paneFrames.map { UInt32(place[Int($0)]) }, "carsPaneFrames")
        radiator = try buffer(system.radiatorNodes, "carsRadiator")
        reach = try buffer(system.radiatorReach, "carsRadiatorReach")
        events = try buffer([GPUBreakEvent](), "carsEvents", length: count * CarSystem.maxEvents * MemoryLayout<GPUBreakEvent>.stride)
        telemetry = try buffer(system.telemetry.map { _ in GPUCarTelemetry() }, "carsTelemetry")
        carCount = try buffer([UInt32(count)], "carsCount")
        commands = try (0..<slots).map { try buffer([UInt32](), "carsCommands\($0)", length: 16 + CarsGPU.maxCommands * MemoryLayout<GPUFractureCommand>.stride) }
        let n = system.cars.count
        snapshots = try (0..<slots).map { try buffer([UInt32](), "carsTelemetry\($0)", length: 16 + n * MemoryLayout<GPUCarTelemetry>.stride) }
        // (Each snapshot as the world starts: what a frame shows before the GPU's first steps are back.)
        for s in snapshots {
            s.contents().storeBytes(of: SIMD4<UInt32>(0, UInt32(n), 0, 0), as: SIMD4<UInt32>.self)
            let t = s.contents().advanced(by: 16).bindMemory(to: GPUCarTelemetry.self, capacity: n)
            for (c, car) in system.telemetry.enumerated() { t[c] = GPUCarTelemetry(car) }
        }
    }

    // MARK: - Encoding

    private func groups(_ enc: ComputePass, _ state: MTLComputePipelineState) {
        enc.dispatchThreadgroups(MTLSize(width: count, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(CarsGPU.width, state.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
    }

    /// The commands of this frame's `steps` steps (the world's `car` ones, in the order they came), for slot `slot`.
    func sendCommands(_ world: PhysicsWorld, slot: Int, steps: Int) {
        let first = UInt32(stepsEncoded), end = UInt32(stepsEncoded + steps)
        let out = commands[slot].contents()
        let list = out.advanced(by: 16).bindMemory(to: GPUFractureCommand.self, capacity: CarsGPU.maxCommands)
        var n = 0
        for k in world.commandOrder {
            let c = world.fractureCommands[Int(k)]
            guard c.info.y == PhysicsWorld.FractureCommand.car.rawValue, c.info.x >= first, c.info.x < end, n < CarsGPU.maxCommands else { continue }
            list[n] = c
            n += 1
        }
        out.storeBytes(of: SIMD4<UInt32>(UInt32(n), 0, 0, 0), as: SIMD4<UInt32>.self)
        stepsEncoded += steps
    }

    /// The cars' state as built (a replay), its sums cleared.
    func encodeReset(_ enc: ComputePass, pipelines: Pipelines) {
        stepsEncoded = 0
        let reset = pipelines[.physicsCarReset]
        enc.setComputePipelineState(reset)
        enc.setBuffer(initialState, offset: 0, index: 1)
        enc.setBuffer(state, offset: 0, index: 2)
        enc.setBuffer(scratch, offset: 0, index: 3)
        var counts = SIMD2<UInt32>(UInt32(state.length / 4), UInt32(scratch.length / 4))
        enc.setBytes(&counts, length: 8, index: 4)
        enc.dispatchThreads(MTLSize(width: 16384, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// The buffers every car kernel reads where they are (the world's: `world`).
    private func bind(_ enc: ComputePass, _ w: World) {
        enc.setBuffer(w.params, offset: 0, index: 0)
        enc.setBuffer(state, offset: carsAt, index: 1)
        enc.setBuffer(tunes, offset: 0, index: 2)
        enc.setBuffer(state, offset: beamsAt, index: 3)
        enc.setBuffer(state, offset: limitsAt, index: 4)
        enc.setBuffer(scratch, offset: loadsAt, index: 5)
        enc.setBuffer(scratch, offset: lambdasAt, index: 6)
        enc.setBuffer(state, offset: wheelsAt, index: 7)
        enc.setBuffer(reactions, offset: 0, index: 8)
        enc.setBuffer(colours, offset: 0, index: 9)
        enc.setBuffer(colourStarts, offset: 0, index: 10)
        enc.setBuffer(candidates, offset: 0, index: 11)
        enc.setBuffer(w.particles, offset: 0, index: 12)
        enc.setBuffer(w.bodies, offset: 0, index: 13)
        enc.setBuffer(w.statics, offset: 0, index: 14)
        enc.setBuffer(w.staticBounds, offset: 0, index: 15)
        enc.setBuffer(w.shapes, offset: 0, index: 16)
        enc.setBuffer(w.samples, offset: 0, index: 17)
        enc.setBuffer(w.sdfScene, offset: 0, index: 18)
        enc.setBuffer(scratch, offset: wearAt, index: 19)
        enc.setBuffer(scratch, offset: pushesAt, index: 20)
        enc.setBuffer(state, offset: partsAt, index: 22)
        enc.setBuffer(state, offset: panesAt, index: 23)
        enc.setBuffer(paneFrames, offset: 0, index: 24)
        enc.setBuffer(radiator, offset: 0, index: 25)
        enc.setBuffer(reach, offset: 0, index: 26)
        enc.setBuffer(events, offset: 0, index: 27)
        enc.setBuffer(telemetry, offset: 0, index: 28)
        enc.setBuffer(carCount, offset: 0, index: 30)
    }

    /// The world's buffers the cars' kernels read and write.
    struct World {
        let params: MTLBuffer, particles: MTLBuffer, bodies: MTLBuffer, statics: MTLBuffer, staticBounds: MTLBuffer
        let shapes: MTLBuffer, samples: MTLBuffer, sdfScene: MTLBuffer, ring: MTLBuffer
    }

    /// The step's start for every car, after the world's broad phase (its commands from slot `slot`'s list).
    func encodeBegin(_ enc: ComputePass, pipelines: Pipelines, world: World, slot: Int, barrier: () -> Void) {
        bind(enc, world)
        let begin = pipelines[.physicsCarBegin]
        enc.setComputePipelineState(begin)
        enc.setBuffer(state, offset: wheelsAt, index: 3)
        enc.setBuffer(world.particles, offset: 0, index: 4)
        enc.setBuffer(world.bodies, offset: 0, index: 5)
        enc.setBuffer(world.statics, offset: 0, index: 6)
        enc.setBuffer(world.staticBounds, offset: 0, index: 7)
        enc.setBuffer(world.shapes, offset: 0, index: 8)
        enc.setBuffer(candidates, offset: 0, index: 9)
        enc.setBuffer(commands[slot], offset: 0, index: 10)
        enc.setBuffer(scratch, offset: clockAt, index: 11)
        barrier()
        groups(enc, begin)
    }

    /// A group of the step's substeps for every car (`group`: the world's run of them, MSL PhysicsGroup, at its offset).
    func encodeSubsteps(_ enc: ComputePass, pipelines: Pipelines, world: World, groups runs: MTLBuffer, groupOffset: Int, barrier: () -> Void) {
        bind(enc, world)
        let substeps = pipelines[.physicsCarSubsteps]
        enc.setComputePipelineState(substeps)
        enc.setBuffer(runs, offset: groupOffset, index: 21)
        barrier()
        groups(enc, substeps)
    }

    /// The step's end for every car, then its events into the ring (after the fractured objects', if any).
    func encodeEnd(_ enc: ComputePass, pipelines: Pipelines, world: World, barrier: () -> Void) {
        bind(enc, world)
        let end = pipelines[.physicsCarEnd]
        enc.setComputePipelineState(end)
        barrier()
        groups(enc, end)
        let events = pipelines[.physicsCarEvents]
        enc.setComputePipelineState(events)
        enc.setBuffer(scratch, offset: clockAt, index: 11)
        enc.setBuffer(world.ring, offset: 0, index: 29)
        barrier()
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    /// The cars' telemetry into slot `slot`'s snapshot (each frame, its steps encoded or not).
    func encodeTelemetry(_ enc: ComputePass, pipelines: Pipelines, slot: Int, barrier: () -> Void) {
        let copy = pipelines[.physicsCarTelemetry]
        enc.setComputePipelineState(copy)
        enc.setBuffer(telemetry, offset: 0, index: 28)
        enc.setBuffer(scratch, offset: clockAt, index: 11)
        enc.setBuffer(snapshots[slot], offset: 0, index: 29)
        enc.setBuffer(carCount, offset: 0, index: 30)
        barrier()
        enc.dispatchThreads(MTLSize(width: max(count, 1), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(max(count, 1), 64), height: 1, depth: 1))
    }

    /// Slot `slot`'s telemetry (its frame must be done): the steps the GPU had run, and each car's.
    func telemetry(slot: Int) -> (step: Int, cars: [CarTelemetry]) {
        let raw = snapshots[slot].contents()
        let step = Int(raw.load(as: UInt32.self))
        let t = raw.advanced(by: 16).bindMemory(to: GPUCarTelemetry.self, capacity: count)
        return (step, (0..<count).map { t[$0].telemetry })
    }

    // MARK: - Reading back (tests)

    func readCars() -> [GPUCar] { read(state, at: carsAt, count) }
    func readWheels(_ n: Int) -> [CarWheel] { read(state, at: wheelsAt, n) }
    /// The beams in the CPU's order.
    func readBeams() -> [CarBeam] {
        let gpu: [CarBeam] = read(state, at: beamsAt, beamOrder.count)
        var out = gpu
        for (at, k) in beamOrder.enumerated() { out[k] = gpu[at] }
        return out
    }
    func readParts(_ n: Int) -> [CarPart] { read(state, at: partsAt, n) }
    func readTelemetry() -> [CarTelemetry] { read(telemetry, at: 0, count).map { (t: GPUCarTelemetry) in t.telemetry } }

    private func read<T>(_ b: MTLBuffer, at offset: Int, _ n: Int) -> [T] {
        Array(UnsafeBufferPointer(start: b.contents().advanced(by: offset).bindMemory(to: T.self, capacity: n), count: n))
    }
}

extension GPUCarTelemetry {
    init(_ t: CarTelemetry) {
        position = SIMD4(t.position, t.speed)
        centre = SIMD4(t.centre, t.rpm)
        forward = SIMD4(t.forward, t.throttle)
        up = SIMD4(t.up, t.brake)
        steer = t.steer
        (gear, bent, broken) = (t.gear, t.bent, t.broken)
        (frontCrush, coolant, heat, engineDamage) = (t.frontCrush, t.coolant, t.heat, t.engineDamage)
        flags = t.running ? GPUCar.running : 0
        (partsOff, wheelsOff, panesBroken) = (t.partsOff, t.wheelsOff, t.panesBroken)
    }
}
