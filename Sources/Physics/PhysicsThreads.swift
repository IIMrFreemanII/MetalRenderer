import EngineCore
import Foundation
import simd
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
package final class PhysicsPool {
    package static let shared = PhysicsPool()

    /// Threads besides the stepping one: one fewer than the performance cores (METALRENDERER_PHYSICS_THREADS: all of
    /// them, the stepping one included; 1: none, every stage on the stepping thread). Not the efficiency cores: a
    /// stage waits for its slowest chunk, and theirs are slow (three buildings settling, on the M1 Max's 8 + 2: the
    /// same broad and narrow phases with 8 threads as with 10, the contacts' colours faster, 27.5 → 26.4 ms a step).
    package let workers: Int
    /// While false (tests, A/Bs), every stage runs on the calling thread, in chunk order.
    package var enabled = true

    /// Words the threads share: the ticket (a stage's generation << 48 | its chunks << 24 | the next chunk), the
    /// chunks done, whether the workers spin (a step is running), whether a stage is out (a stage's items that hand
    /// out a stage themselves run it inline), and which thread holds the pool (one stepper at a time). The ticket, the
    /// chunks done and the threads inside are each on a cache line of their own (on one, every claim and every chunk
    /// done moved it between all the cores: a stage of 3,000 empty items took 150 µs).
    private let words: UnsafeMutablePointer<Int>
    private static let line = 16   // (Ints a cache line: 128 bytes on Apple's cores)
    private var ticket: UnsafeMutablePointer<Int> { words }
    private var done: UnsafeMutablePointer<Int> { words + PhysicsPool.line }
    /// Threads holding the stage out (it isn't put away until none does).
    private var inside: UnsafeMutablePointer<Int> { words + 2 * PhysicsPool.line }
    private var awake: UnsafeMutablePointer<Int> { words + 3 * PhysicsPool.line }
    private var busy: UnsafeMutablePointer<Int> { words + 3 * PhysicsPool.line + 1 }
    private var held: UnsafeMutablePointer<Int> { words + 3 * PhysicsPool.line + 2 }
    private var parked: UnsafeMutablePointer<Int> { words + 3 * PhysicsPool.line + 3 }
    /// The stage out: a run of chunks -> their items. Written before the ticket that publishes it, read only by a
    /// thread that claimed some of its chunks (so it never changes under one).
    private var stage: ((Range<Int>) -> Void)?
    /// Whether a claim is one chunk (the stage's chunks wait on chunks before them: a thread's run of them would wait
    /// on another's), not a share of what is left. Written before the ticket, as `stage` is.
    private var single = false
    private let wake = DispatchSemaphore(value: 0)

    private static let mask = (1 << 24) - 1
    /// How long a worker spins on the ticket before it parks (pause loops: about 50 µs).
    private static let spins = 20_000

    private init() {
        let asked = Int(ProcessInfo.processInfo.environment["METALRENDERER_PHYSICS_THREADS"] ?? "") ?? 0
        var performance: Int32 = 0, size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &performance, &size, nil, 0) != 0 { performance = 0 }
        let all = asked > 0 ? asked : performance > 0 ? Int(performance) : ProcessInfo.processInfo.activeProcessorCount
        workers = max(min(all, 64) - 1, 0)
        words = UnsafeMutableRawPointer.allocate(byteCount: 4 * PhysicsPool.line * MemoryLayout<Int>.stride, alignment: 128)
            .bindMemory(to: Int.self, capacity: 4 * PhysicsPool.line)
        words.initialize(repeating: 0, count: 4 * PhysicsPool.line)
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
    package func run<R>(_ body: () throws -> R) rethrows -> R {
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
    /// stage within a stage, or when it is a chunk or two. `single`: each claim is one chunk (the chunks are claimed
    /// in order either way, and each thread runs a claim's in order: PhysicsWorld.eachColour's wait on those before).
    package func parallel(_ count: Int, grain: Int, single: Bool = false, _ body: (Range<Int>) -> Void) {
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
            stage = { c in body(c.lowerBound * grain..<min(c.upperBound * grain, count)) }
            self.single = single
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
            while cpa_load(done) < chunks || cpa_load(inside) != 0 { cpa_pause() }
            stage = nil
        }
        cpa_store(busy, 0)
    }

    /// Claims and runs generation `generation`'s chunks until none are left, then counts them done (the stage read
    /// once, after the first claim: read for each chunk, its count went back and forth between the cores).
    @inline(__always) private func drain(_ generation: Int) {
        guard let first = claim(generation) else { return }
        _ = cpa_add(inside, 1)   // (before its first chunk is done: the stage can't end before this)
        do {
            let run = stage!
            var next: Range<Int>? = first, ran = 0
            while let c = next {
                run(c)
                ran += c.count
                next = claim(generation)
            }
            _ = cpa_add(done, ran)
        }
        _ = cpa_add(inside, -1)   // (the stage let go of)
    }

    /// The next run of generation `generation`'s chunks, if any are left: a share of what is left (a quarter of it
    /// over the threads, one chunk at least), so a stage is a few claims a thread and its last chunks still even out.
    /// (Which thread runs which items changes nothing: a stage's items are independent.)
    @inline(__always) private func claim(_ generation: Int) -> Range<Int>? {
        let threads = workers + 1
        while true {
            let t = cpa_load(ticket)
            let next = t & PhysicsPool.mask, chunks = (t >> 24) & PhysicsPool.mask
            guard t >> 48 == generation, next < chunks else { return nil }
            let take = single ? 1 : max((chunks - next) / (4 * threads), 1)
            if cpa_cas(ticket, t, t + take) { return next..<(next + take) }
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
package struct StepBuffers {
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
    package func withStepBuffers<R>(_ body: (StepBuffers) throws -> R) rethrows -> R {
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

/// The narrow phase's memo (PhysicsWorld.narrowPhase) as its stages read and write it: the contacts of a pair whose
/// two bodies are as they were at the last step's start (each of their bits the narrow phase reads: pose, speeds,
/// radius, shape, flags) are what `collide` found then, so they are kept, not found again. A body's entries are its
/// own to write, `changed` is written in a stage before.
package struct NarrowMemo {
    let partners: UnsafeMutableBufferPointer<UInt32>
    let counts: UnsafeMutableBufferPointer<UInt32>
    let seen: UnsafeMutableBufferPointer<SIMD16<UInt32>>
    let changed: UnsafeMutableBufferPointer<UInt8>

    /// What of body b the narrow phase reads, bit for bit.
    @inline(__always) static func key(_ b: GPUPhysicsBody) -> SIMD16<UInt32> {
        SIMD16(b.position.x.bitPattern, b.position.y.bitPattern, b.position.z.bitPattern,
               b.rotation.x.bitPattern, b.rotation.y.bitPattern, b.rotation.z.bitPattern, b.rotation.w.bitPattern,
               b.velocity.x.bitPattern, b.velocity.y.bitPattern, b.velocity.z.bitPattern,
               b.angular.x.bitPattern, b.angular.y.bitPattern, b.angular.z.bitPattern,
               b.invInertia.w.bitPattern, b.info.x, b.info.y)
    }
}

/// A body's box in the world, as PhysicsWorld.boxGap works it out: its axes, and its centre (`box`: the shape's box's
/// centre, in the body's space).
package struct PhysicsBoxFrame {
    var x = SIMD3<Float>(), y = SIMD3<Float>(), z = SIMD3<Float>(), centre = SIMD3<Float>()

    package init() {}
    @inline(__always) package init(_ b: GPUPhysicsBody, _ box: SIMD4<Float>) {
        // (Not array literals: they build an array and convert it, per pair.)
        x = PhysicsMath.qrot(b.rotation, SIMD3(1, 0, 0))
        y = PhysicsMath.qrot(b.rotation, SIMD3(0, 1, 0))
        z = PhysicsMath.qrot(b.rotation, SIMD3(0, 0, 1))
        centre = PhysicsMath.xyz(b.position) + PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(box))
    }
}

/// The bodies' samples' world points (each its pose's toWorld), worked out once a narrow phase per body, by the first
/// thread to want them (one wanting them meanwhile waits): a body is in a few pairs, and each pair worked them out
/// again, the same points. (Three buildings settling: 2.3 million samples a step, a third of them near enough the
/// other body to ask its distance.)
package struct SampleCache {
    let starts: UnsafeBufferPointer<Int32>
    let world: UnsafeMutablePointer<SIMD3<Float>>
    let states: UnsafeMutablePointer<Int>
    let epoch: Int

    /// Record i's points (`b`: body i, or past the bodies a static).
    @inline(__always) func points(_ i: Int, _ b: GPUPhysicsBody, _ shapes: PhysicsShapes) -> UnsafePointer<SIMD3<Float>> {
        let base = world + Int(starts[i]), state = states + i, ready = 2 * epoch + 1, working = 2 * epoch
        let seen = cpa_load(state)
        if seen == ready { return UnsafePointer(base) }
        if seen != working && cpa_cas(state, seen, working) {
            let info = shapes.shapes[Int(b.info.x)].info, pose = PhysicsWorld.Pose(b)
            for m in 0..<Int(info.z) { base[m] = pose.toWorld(PhysicsMath.xyz(shapes.samples[Int(info.y) + m])) }
            cpa_store(state, ready)
        } else {
            while cpa_load(state) != ready { cpa_pause() }
        }
        return UnsafePointer(base)
    }
}

extension PhysicsWorld {
    /// `body` with the samples' world points lent (SampleCache), for a narrow phase.
    package func withSampleCache<R>(_ body: (SampleCache) throws -> R) rethrows -> R {
        try sampleStarts.withUnsafeBufferPointer { starts in
            try sampleWorld.withUnsafeMutableBufferPointer { world in
                try sampleStates.withUnsafeMutableBufferPointer { states in
                    try body(SampleCache(starts: starts, world: world.baseAddress!, states: states.baseAddress!, epoch: sampleEpoch))
                }
            }
        }
    }
}

/// The broad phase's memo (PhysicsWorld.broadPhase): body i's partners as the last step found them are what this
/// step's query would find again when i is as it was then, so is each of them, and no body that isn't as it was
/// (`changed`, in a grid of their own: `cells`, `bodies`, `bigs`) reaches it now. Its partners are the nearest
/// `maxPairs` of those within reach by a total order: one that changed and kept none of its places among them, and
/// doesn't reach it now, can't make it keep others; one now within reach can.
package struct BroadMemo {
    let changed: UnsafeBufferPointer<UInt8>
    let cells: PhysicsCellGrid.View
    let used: UInt32        // (the levels the changed bodies are in)
    let bodies: UnsafeBufferPointer<Int32>
    let bigs: UnsafeBufferPointer<Int32>

    /// What of body b the broad phase reads, bit for bit (the partners' tests: PhysicsWorld.consider, touchesStatic).
    @inline(__always) static func key(_ b: GPUPhysicsBody) -> SIMD16<UInt32> {
        SIMD16(b.position.x.bitPattern, b.position.y.bitPattern, b.position.z.bitPattern, b.position.w.bitPattern,
               b.rotation.x.bitPattern, b.rotation.y.bitPattern, b.rotation.z.bitPattern, b.rotation.w.bitPattern,
               b.velocity.x.bitPattern, b.velocity.y.bitPattern, b.velocity.z.bitPattern,
               b.invInertia.w.bitPattern, b.info.x, b.info.y, b.info.z, b.info.w)
    }
}

extension PhysicsWorld {
    /// `body` with the narrow phase's memo lent as raw buffers (NarrowMemo).
    package func withNarrowMemo<R>(_ body: (NarrowMemo) throws -> R) rethrows -> R {
        try narrowPartners.withUnsafeMutableBufferPointer { partners in
            try narrowCounts.withUnsafeMutableBufferPointer { counts in
                try narrowSeen.withUnsafeMutableBufferPointer { seen in
                    try narrowChanged.withUnsafeMutableBufferPointer { changed in
                        try body(NarrowMemo(partners: partners, counts: counts, seen: seen, changed: changed))
                    }
                }
            }
        }
    }
}

/// The particles' arrays as their stages' loops read and write them (PhysicsWorld.withParticleBuffers): a particle
/// writes only its own entries (a colour's links and tets share no particle); the bodies are read only.
package struct ParticleBuffers {
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
    package func withParticleBuffers<R>(_ body: (ParticleBuffers) throws -> R) rethrows -> R {
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

/// What the hair's strands read and write as they step on the workers (PhysicsWorld.stepHair): a strand writes only
/// its own vertices; the bodies (and their poses when the step began) are read only.
package struct HairBuffers {
    let vertices: UnsafeMutablePointer<GPUHairVertex>
    let start: UnsafeBufferPointer<SIMD8<Float>>
    let bodies: UnsafeBufferPointer<GPUPhysicsBody>
    let statics: UnsafeBufferPointer<GPUPhysicsBody>
    let staticBounds: [AABB]
    let shapeKinds: [GPUPhysicsShape]
    let shapes: PhysicsShapes

    /// A collider's record: a body, or a static collider.
    @inline(__always) func partner(_ code: UInt32) -> GPUPhysicsBody {
        code & PhysicsWorld.staticBit != 0 ? statics[Int(code & ~PhysicsWorld.staticBit)] : bodies[Int(code)]
    }
}

/// The levels of the bodies' grid (PhysicsWorld.broadPhase): level l's cells are `first` x 2^l a side, and a body is
/// in the first level whose cells are twice the reach it can have in a step (its radius, the most it travels, the
/// margin) or more. `used`: a bit a level with bodies in it.
package struct PhysicsLevels {
    static let most = 12
    let first: Float
    var used: UInt32

    /// The most a body of radius r reaches in a step (PhysicsWorld.reach at the cell speed).
    @inline(__always) static func most(_ r: Float) -> Float {
        r + PhysicsWorld.cellSpeed * PhysicsWorld.stepLength + PhysicsWorld.margin
    }
    @inline(__always) func size(_ level: Int) -> Float { first * Float(1 << level) }
    /// Body b's level (`most` for one too big for the last).
    @inline(__always) func level(_ b: GPUPhysicsBody) -> Int {
        let need = 2 * PhysicsLevels.most(b.invInertia.w)
        var level = 0
        while level < PhysicsLevels.most && size(level) < need { level += 1 }
        return level
    }
}

/// The cells the broad phases' things are in (broadPhase, particleBroadPhase; the bodies' in levels of cells of
/// sizes doubling), as their queries on the workers read them: each cell's items in the order they were added (as a dictionary of arrays held them), flat, found through an
/// open-addressed table, so a lookup counts no references. Kept between steps, its arrays reused.
package struct PhysicsCellGrid {
    private var keys: [SIMD4<Int32>] = []
    private var slots: [Int32] = []
    private var starts: [Int32] = []
    private var items: [Int32] = []
    private var cellOf: [Int32] = []

    @inline(__always) static func hash(_ k: SIMD4<Int32>) -> Int {
        Int(UInt32(bitPattern: k.x &* 73_856_093 ^ k.y &* 19_349_663 ^ k.z &* 83_492_791 ^ k.w &* 1_640_531_527))
    }

    /// `a` as `count` copies of `value`, its storage kept.
    private static func reset<T>(_ a: inout [T], _ count: Int, _ value: T) {
        a.removeAll(keepingCapacity: true)
        a.append(contentsOf: repeatElement(value, count: count))
    }

    /// Items 0..<n in their cells (`key`: a cell, and the level of cells it is one of; nil for one in none).
    mutating func build(_ n: Int, _ key: (Int) -> SIMD4<Int32>?) {
        var capacity = 16
        while capacity < 2 * n { capacity *= 2 }
        let mask = capacity - 1
        PhysicsCellGrid.reset(&slots, capacity, -1)
        PhysicsCellGrid.reset(&keys, n, .zero)        // (n cells at most)
        PhysicsCellGrid.reset(&starts, n + 1, 0)
        PhysicsCellGrid.reset(&cellOf, n, -1)
        var cells = 0
        slots.withUnsafeMutableBufferPointer { slots in
        keys.withUnsafeMutableBufferPointer { keys in
        starts.withUnsafeMutableBufferPointer { starts in
        cellOf.withUnsafeMutableBufferPointer { cellOf in
            for i in 0..<n {
                guard let k = key(i) else { continue }
                var at = PhysicsCellGrid.hash(k) & mask
                while slots[at] >= 0 && keys[Int(slots[at])] != k { at = (at + 1) & mask }
                if slots[at] < 0 {
                    slots[at] = Int32(cells)
                    keys[cells] = k
                    cells += 1
                }
                let c = Int(slots[at])
                cellOf[i] = Int32(c)
                starts[c + 1] += 1
            }
            for c in 0..<cells { starts[c + 1] += starts[c] }
        }
        }
        }
        }
        PhysicsCellGrid.reset(&items, Int(starts[cells]), 0)
        items.withUnsafeMutableBufferPointer { items in
        starts.withUnsafeMutableBufferPointer { starts in
        cellOf.withUnsafeBufferPointer { cellOf in
            // (Each cell's items in order, its start moved along as they go in, then put back.)
            for i in 0..<n where cellOf[i] >= 0 {
                let c = Int(cellOf[i])
                items[Int(starts[c])] = Int32(i)
                starts[c] += 1
            }
            var at = cells
            while at > 0 { starts[at] = starts[at - 1]; at -= 1 }
            starts[0] = 0
        }
        }
        }
    }

    package struct View {
        package let keys: UnsafeBufferPointer<SIMD4<Int32>>
        package let slots: UnsafeBufferPointer<Int32>
        package let starts: UnsafeBufferPointer<Int32>
        package let items: UnsafeBufferPointer<Int32>

        /// The items in cell `k`, in the order they were added (none for an empty cell).
        @inline(__always) package func cell(_ k: SIMD4<Int32>) -> Range<Int> {
            let mask = slots.count - 1
            var at = PhysicsCellGrid.hash(k) & mask
            while slots[at] >= 0 {
                let c = Int(slots[at])
                if keys[c] == k { return Int(starts[c])..<Int(starts[c + 1]) }
                at = (at + 1) & mask
            }
            return 0..<0
        }
        @inline(__always) package func item(_ m: Int) -> Int { Int(items[m]) }
    }

    func withView<R>(_ body: (View) throws -> R) rethrows -> R {
        try keys.withUnsafeBufferPointer { keys in
            try slots.withUnsafeBufferPointer { slots in
                try starts.withUnsafeBufferPointer { starts in
                    try items.withUnsafeBufferPointer { items in
                        try body(View(keys: keys, slots: slots, starts: starts, items: items))
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
package final class PhysicsStepper {
    /// What a frame draws: the world's poses as a frame's steps left them (copies on write: the steps after copy).
    package struct Drawn {
        package var bodies: [GPUPhysicsBody]
        package var particles: [GPUPhysicsParticle]
        package var hairVertices: [GPUHairVertex]
        package var fractureState: [GPUFractureState]
        /// Where pieces broke (PhysicsWorld.breakLog, breakSteps, breakTotal), for the dust.
        package var breakLog: [GPUBreakEvent]
        package var breakSteps: [Int]
        package var breakTotal: Int
        /// The rockets, the fireballs, the walker (PhysicsWorld.demolition), and the step these are before.
        package var demolition: DemolitionState
        /// The cars' frames and gauges (Physics+Cars.swift).
        package var cars: [CarTelemetry]
        package var stepIndex: Int

        /// What a frame between `before`'s steps and `after`'s draws, `t` of the way (0...1) from one to the other: the
        /// bodies' and particles' places (and the cars' frames) blended, the rest `after`'s. (A car scene's frames come
        /// faster than its steps: drawn from the latest, the cars moved on some frames and not on others, and the chase
        /// camera stuttered.)
        package static func between(_ before: Drawn, _ after: Drawn, _ t: Float) -> Drawn {
            var d = after
            guard t < 1, before.bodies.count == after.bodies.count, before.particles.count == after.particles.count,
                  before.cars.count == after.cars.count else { return d }
            for i in d.bodies.indices {
                let a = before.bodies[i], b = after.bodies[i]
                d.bodies[i].position = SIMD4(PhysicsMath.xyz(a.position) + (PhysicsMath.xyz(b.position) - PhysicsMath.xyz(a.position)) * t, b.position.w)
                let qa = dot(a.rotation, b.rotation) < 0 ? -a.rotation : a.rotation
                d.bodies[i].rotation = normalize(qa + (b.rotation - qa) * t)
            }
            for i in d.particles.indices {
                let a = PhysicsMath.xyz(before.particles[i].position), b = after.particles[i].position
                d.particles[i].position = SIMD4(a + (PhysicsMath.xyz(b) - a) * t, b.w)
            }
            for c in d.cars.indices {
                let a = before.cars[c], b = after.cars[c]
                d.cars[c].position = a.position + (b.position - a.position) * t
                d.cars[c].centre = a.centre + (b.centre - a.centre) * t
                d.cars[c].forward = normalize(a.forward + (b.forward - a.forward) * t)
                d.cars[c].up = normalize(a.up + (b.up - a.up) * t)
            }
            return d
        }

        package init(_ w: PhysicsWorld) {
            bodies = w.bodies
            particles = w.particles
            hairVertices = w.hairVertices
            fractureState = w.fractureState
            breakLog = w.breakLog
            breakSteps = w.breakSteps
            breakTotal = w.breakTotal
            demolition = w.demolition
            cars = w.carSystem.telemetry
            stepIndex = w.stepIndex
        }
    }

    package let world: PhysicsWorld
    /// The body the mouse holds (the render thread's, sent with each frame's steps: the world's own `grab` is the
    /// stepper's).
    package var grab: GPUPhysicsGrab

    private let condition = NSCondition()
    private var times: [(time: Float, grab: GPUPhysicsGrab, commands: [GPUFractureCommand])] = []   // asked for, not begun
    /// Commands for the next frame's steps (Scene.physicsCommand), sent with them: each kept at the step the world is
    /// at when they begin (as one given to the world between frames is), without the frame waiting for its steps.
    private var commands: [GPUFractureCommand] = []
    private var busy = false
    private var stopping = false
    private var drawn: Drawn
    /// What the last few frames' steps left, oldest first, `drawn` last (only it after a restart): a frame draws the two
    /// round its time blended.
    private var history: [Drawn] = []
    package static let historyLength = 4
    private let finished = DispatchSemaphore(value: 0)
    /// How many frames' steps may wait their turn before a frame waits for them (the frame then runs at the steps'
    /// pace, a frame behind).
    package static let queued = 2

    package init(world: PhysicsWorld) {
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
    package func request(to time: Float) {
        condition.lock()
        while times.count >= PhysicsStepper.queued && !stopping { condition.wait() }
        times.append((time, grab, commands))
        commands.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    /// Command `c` (its start step PhysicsWorld.none: the step its frame's steps begin at) sent with the next frame's.
    package func command(_ c: GPUFractureCommand) {
        condition.lock()
        commands.append(c)
        condition.unlock()
    }

    /// Waits for every step asked for.
    package func waitIdle() {
        condition.lock()
        while (!times.isEmpty || busy) && !stopping { condition.wait() }
        condition.unlock()
    }

    /// `body` with the world, on this thread, once every step asked for is done (and none starts until it returns).
    package func sync<R>(_ body: (PhysicsWorld) throws -> R) rethrows -> R {
        condition.lock()
        defer { condition.unlock() }
        while (!times.isEmpty || busy) && !stopping { condition.wait() }
        return try body(world)
    }

    /// The poses the latest steps left.
    package var latest: Drawn {
        condition.lock()
        defer { condition.unlock() }
        return drawn
    }

    /// ...and those the last few frames' steps left before them, oldest first, the latest last.
    package var recent: [Drawn] {
        condition.lock()
        defer { condition.unlock() }
        return history.isEmpty ? [drawn] : history
    }

    /// Ends the thread (after the step it is on); the world is the caller's again.
    package func stop() {
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
            for c in next.commands { world.add(c) }
            world.advance(to: next.time)
            let now = Drawn(world)
            condition.lock()
            if now.stepIndex < drawn.stepIndex { history.removeAll() }
            if now.stepIndex != drawn.stepIndex || history.isEmpty {
                history.append(now)
                if history.count > PhysicsStepper.historyLength { history.removeFirst() }
            }
            drawn = now
            busy = false
            condition.broadcast()
            condition.unlock()
        }
    }
}
