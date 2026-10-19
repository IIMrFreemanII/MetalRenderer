import Foundation
import CPhysicsAtomics

/// The CPU physics step's workers (PhysicsCPU.swift): a pool of threads that, while a step runs, spin waiting for the
/// next stage, and run its items in fixed chunks with the stepping thread. A step has hundreds of stages (a colour of
/// contact pairs is one, and each substep has dozens): handing a stage out costs a store and the workers' next load,
/// not a thread's wake-up (DispatchQueue.concurrentPerform's cost, which over a step was milliseconds).
///
/// The same numbers on any count of threads: a stage's items are independent (each writes only its own body, entry,
/// particle; a colour's pairs share no body), chunks are fixed by the stage's grain, and no stage sums floats across
/// chunks. Between steps the workers sleep, and within one a worker that has had nothing to do for a while (a serial
/// stage: the colouring, a liquid's sort) parks until the next stage wakes it: spinning on every core slowed the
/// stepping thread's own serial work, and starved anything else that wanted the cores.
final class PhysicsPool {
    static let shared = PhysicsPool()

    /// Threads besides the stepping one (METALRENDERER_PHYSICS_THREADS: all of them, the stepping one included; 1:
    /// none, every stage on the stepping thread).
    let workers: Int
    /// While false (tests, A/Bs), every stage runs on the calling thread, in chunk order.
    var enabled = true

    /// Words the threads share: the ticket (a stage's generation << 48 | its chunks << 24 | the next chunk), the
    /// chunks done, whether the workers spin (a step is running), whether a stage is out (a stage's items that hand
    /// out a stage themselves run it inline), and which thread holds the pool (one stepper at a time).
    private let words: UnsafeMutablePointer<Int>
    private var ticket: UnsafeMutablePointer<Int> { words }
    private var done: UnsafeMutablePointer<Int> { words + 1 }
    private var awake: UnsafeMutablePointer<Int> { words + 2 }
    private var busy: UnsafeMutablePointer<Int> { words + 3 }
    private var held: UnsafeMutablePointer<Int> { words + 4 }
    private var parked: UnsafeMutablePointer<Int> { words + 5 }
    /// The stage out: chunk index -> its items. Written before the ticket that publishes it, read only by a thread
    /// that claimed one of its chunks (so it never changes under one).
    private var stage: ((Int) -> Void)?
    private let wake = DispatchSemaphore(value: 0)

    private static let mask = (1 << 24) - 1
    /// How long a worker spins on the ticket before it parks (pause loops: about 50 µs).
    private static let spins = 20_000

    private init() {
        let asked = Int(ProcessInfo.processInfo.environment["METALRENDERER_PHYSICS_THREADS"] ?? "") ?? 0
        let all = asked > 0 ? asked : ProcessInfo.processInfo.activeProcessorCount
        workers = max(min(all, 64) - 1, 0)
        words = .allocate(capacity: 8)
        words.initialize(repeating: 0, count: 8)
        for k in 0..<workers {
            let t = Thread { [unowned self] in self.work() }
            t.name = "MetalRenderer.physics.\(k)"
            t.qualityOfService = .userInteractive
            t.stackSize = 1 << 20
            t.start()
        }
    }

    /// Runs `body` (a step, or several) with the workers spinning, ready for its stages. Nested calls, or a second
    /// thread's while one holds the pool, run as they would without it (their stages inline).
    func run<R>(_ body: () throws -> R) rethrows -> R {
        guard workers > 0, enabled, cpa_cas(held, 0, 1) else {
            return try body()
        }
        defer {
            cpa_store(awake, 0)
            cpa_store(held, 0)
        }
        cpa_store(parked, 0)   // (every worker is waiting: these wake them all)
        cpa_store(awake, 1)
        for _ in 0..<workers { wake.signal() }
        return try body()
    }

    /// Items `0..<count` in chunks of `grain`, `body` called with each chunk's range, on the workers and the calling
    /// thread, back when all are done. Inline (in chunk order) when there are no workers, outside `run`, for a
    /// stage within a stage, or when it is a chunk or two.
    func parallel(_ count: Int, grain: Int, _ body: (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let chunks = (count + grain - 1) / grain
        guard chunks > 1, workers > 0, cpa_load(awake) != 0, cpa_cas(busy, 0, 1) else {
            var start = 0
            while start < count {
                body(start..<min(start + grain, count))
                start += grain
            }
            return
        }
        withoutActuallyEscaping(body) { body in
            stage = { c in body(c * grain..<min((c + 1) * grain, count)) }
            cpa_store(done, 0)
            let generation = ((cpa_load(ticket) >> 48) + 1) & 0xFFFF
            cpa_store(ticket, generation << 48 | chunks << 24)
            // (Parked workers woken: as many as parked, each one's count taken back here.)
            let sleeping = min(cpa_load(parked), chunks - 1)
            if sleeping > 0 {
                _ = cpa_add(parked, -sleeping)
                for _ in 0..<sleeping { wake.signal() }
            }
            drain(generation)
            while cpa_load(done) < chunks { cpa_pause() }
            stage = nil
        }
        cpa_store(busy, 0)
    }

    /// Claims and runs generation `generation`'s chunks until none are left.
    @inline(__always) private func drain(_ generation: Int) {
        while true {
            let t = cpa_load(ticket)
            let next = t & PhysicsPool.mask
            guard t >> 48 == generation, next < (t >> 24) & PhysicsPool.mask else { return }
            guard cpa_cas(ticket, t, t + 1) else { continue }
            stage!(next)
            _ = cpa_add(done, 1)
        }
    }

    /// A worker: asleep between steps; within one, spinning on the ticket and draining each new stage, parked after
    /// a while without one (the next stage's hand-out, or the next step's, wakes it).
    private func work() {
        var seen = 0, idle = 0
        while true {
            if cpa_load(awake) == 0 {
                wake.wait()
                idle = 0
                continue
            }
            let generation = cpa_load(ticket) >> 48
            if generation != seen {
                seen = generation
                drain(generation)
                idle = 0
                continue
            }
            idle += 1
            if idle < PhysicsPool.spins {
                cpa_pause()
                continue
            }
            // Park, unless a stage came out (or the step ended) while counting itself in. (A wake-up meant for
            // another, or one left over, only spins it round again.)
            _ = cpa_add(parked, 1)
            if cpa_load(ticket) >> 48 != seen || cpa_load(awake) == 0 {
                _ = cpa_add(parked, -1)
            } else {
                wake.wait()
            }
            idle = 0
        }
    }
}

/// The step's arrays as the stages' loops on the workers read and write them: raw buffers, taken once around a stage
/// (PhysicsWorld.withStepBuffers). An item writes only its own elements (or, in a colour, its pair's two bodies);
/// nothing reads the world's arrays through the world inside (Swift moves an array out while its buffer is lent).
struct StepBuffers {
    let bodies: UnsafeMutableBufferPointer<GPUPhysicsBody>
    let pairs: UnsafeMutableBufferPointer<GPUPhysicsPair>
    let pairCounts: UnsafeMutableBufferPointer<UInt32>
    let contacts: UnsafeMutableBufferPointer<GPUPhysicsContact>
    let fractureState: UnsafeMutableBufferPointer<GPUFractureState>
    let welds: UnsafeMutableBufferPointer<GPUFractureWeld>
    let statics: UnsafeBufferPointer<GPUPhysicsBody>
    let weldStarts: UnsafeBufferPointer<UInt32>
    let weldList: UnsafeBufferPointer<SIMD2<UInt32>>

    /// The partner's record: a body, or a static collider.
    @inline(__always) func partner(_ code: UInt32) -> GPUPhysicsBody {
        code & PhysicsWorld.staticBit != 0 ? statics[Int(code & ~PhysicsWorld.staticBit)] : bodies[Int(code)]
    }
}

extension PhysicsWorld {
    /// `body` with the step's arrays lent as raw buffers (StepBuffers).
    func withStepBuffers<R>(_ body: (StepBuffers) throws -> R) rethrows -> R {
        try bodies.withUnsafeMutableBufferPointer { bodies in
            try pairs.withUnsafeMutableBufferPointer { pairs in
                try pairCounts.withUnsafeMutableBufferPointer { pairCounts in
                    try contacts.withUnsafeMutableBufferPointer { contacts in
                        try fractureState.withUnsafeMutableBufferPointer { fractureState in
                            try welds.withUnsafeMutableBufferPointer { welds in
                                try statics.withUnsafeBufferPointer { statics in
                                    try weldStarts.withUnsafeBufferPointer { weldStarts in
                                        try weldList.withUnsafeBufferPointer { weldList in
                                            try body(StepBuffers(bodies: bodies, pairs: pairs, pairCounts: pairCounts, contacts: contacts,
                                                                 fractureState: fractureState, welds: welds, statics: statics,
                                                                 weldStarts: weldStarts, weldList: weldList))
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

/// The particles' arrays as their stages' loops read and write them (PhysicsWorld.withParticleBuffers): a particle
/// writes only its own entries (a colour's links and tets share no particle); the bodies are read only.
struct ParticleBuffers {
    let particles: UnsafeMutableBufferPointer<GPUPhysicsParticle>
    /// The particles as the substep's Jacobi pass found them (solveParticles reads these, writes `particles`).
    let before: UnsafeMutableBufferPointer<GPUPhysicsParticle>
    let neighbours: UnsafeMutableBufferPointer<UInt32>
    let neighbourCounts: UnsafeMutableBufferPointer<UInt32>
    let colliders: UnsafeMutableBufferPointer<UInt32>
    let colliderCounts: UnsafeMutableBufferPointer<UInt32>
    let bodies: UnsafeBufferPointer<GPUPhysicsBody>
    let statics: UnsafeBufferPointer<GPUPhysicsBody>

    /// A collider's record: a body, or a static collider.
    @inline(__always) func partner(_ code: UInt32) -> GPUPhysicsBody {
        code & PhysicsWorld.staticBit != 0 ? statics[Int(code & ~PhysicsWorld.staticBit)] : bodies[Int(code)]
    }
}

extension PhysicsWorld {
    /// `body` with the particles' arrays lent as raw buffers (ParticleBuffers).
    func withParticleBuffers<R>(_ body: (ParticleBuffers) throws -> R) rethrows -> R {
        if particleSnapshot.count != particles.count {
            particleSnapshot = particles
        }
        return try particles.withUnsafeMutableBufferPointer { particles in
            try particleSnapshot.withUnsafeMutableBufferPointer { before in
                try neighbours.withUnsafeMutableBufferPointer { neighbours in
                    try neighbourCounts.withUnsafeMutableBufferPointer { neighbourCounts in
                        try colliders.withUnsafeMutableBufferPointer { colliders in
                            try colliderCounts.withUnsafeMutableBufferPointer { colliderCounts in
                                try bodies.withUnsafeBufferPointer { bodies in
                                    try statics.withUnsafeBufferPointer { statics in
                                        try body(ParticleBuffers(particles: particles, before: before, neighbours: neighbours,
                                                                 neighbourCounts: neighbourCounts, colliders: colliders,
                                                                 colliderCounts: colliderCounts, bodies: bodies, statics: statics))
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

/// A world stepped on a thread of its own, behind the frame (a CPU-stepped scene: Scene.update, PhysicsSettings.
/// asynchronous): each frame asks for the steps to its time, with the body the mouse holds then, and draws the bodies
/// where the steps before left them (`latest`), while these run beside the frame's own work. The same numbers as
/// stepping in the frame: the steps run in the order asked, each with its frame's grab, and anything else done to the
/// world (a pick, a shot, a blast) waits for the steps asked before it (`sync`), so it lands on the same step.
final class PhysicsStepper {
    /// What a frame draws: the world's poses as a frame's steps left them (copies on write: the steps after copy).
    struct Drawn {
        var bodies: [GPUPhysicsBody]
        var particles: [GPUPhysicsParticle]
        var hairVertices: [GPUHairVertex]
        var fractureState: [GPUFractureState]

        init(_ w: PhysicsWorld) {
            bodies = w.bodies
            particles = w.particles
            hairVertices = w.hairVertices
            fractureState = w.fractureState
        }
    }

    let world: PhysicsWorld
    /// The body the mouse holds (the render thread's, sent with each frame's steps: the world's own `grab` is the
    /// stepper's).
    var grab: GPUPhysicsGrab

    private let condition = NSCondition()
    private var times: [(time: Float, grab: GPUPhysicsGrab)] = []   // asked for, not begun
    private var busy = false
    private var stopping = false
    private var drawn: Drawn
    private let finished = DispatchSemaphore(value: 0)
    /// How many frames' steps may wait their turn before a frame waits for them (the frame then runs at the steps'
    /// pace, a frame behind).
    static let queued = 2

    init(world: PhysicsWorld) {
        self.world = world
        grab = world.grab
        drawn = Drawn(world)
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "MetalRenderer.physics.stepper"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 << 20
        thread.start()
    }

    /// The steps to `time`, with this frame's grab, after those asked before (waiting while `queued` frames' are
    /// still to run).
    func request(to time: Float) {
        condition.lock()
        while times.count >= PhysicsStepper.queued && !stopping { condition.wait() }
        times.append((time, grab))
        condition.broadcast()
        condition.unlock()
    }

    /// Waits for every step asked for.
    func waitIdle() {
        condition.lock()
        while (!times.isEmpty || busy) && !stopping { condition.wait() }
        condition.unlock()
    }

    /// `body` with the world, on this thread, once every step asked for is done (and none starts until it returns).
    func sync<R>(_ body: (PhysicsWorld) throws -> R) rethrows -> R {
        condition.lock()
        defer { condition.unlock() }
        while (!times.isEmpty || busy) && !stopping { condition.wait() }
        return try body(world)
    }

    /// The poses the latest steps left.
    var latest: Drawn {
        condition.lock()
        defer { condition.unlock() }
        return drawn
    }

    /// Ends the thread (after the step it is on); the world is the caller's again.
    func stop() {
        condition.lock()
        stopping = true
        condition.broadcast()
        condition.unlock()
        finished.wait()
    }

    private func run() {
        while true {
            condition.lock()
            while times.isEmpty && !stopping { condition.wait() }
            if stopping {
                condition.unlock()
                finished.signal()
                return
            }
            let next = times.removeFirst()
            busy = true
            condition.broadcast()   // (room for another frame's)
            condition.unlock()
            world.grab = next.grab
            world.advance(to: next.time)
            let now = Drawn(world)
            condition.lock()
            drawn = now
            busy = false
            condition.broadcast()
            condition.unlock()
        }
    }
}
