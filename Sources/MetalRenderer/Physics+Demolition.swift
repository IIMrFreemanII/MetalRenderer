import Foundation
import simd

/// The demolition scene's weapons and walker in the physics (Scene+Demolition.swift): what the CPU's step does for
/// them, at its start, after the step's commands (Physics+Fracture.swift's `beginFractureStep`), one after another.
///
/// A bullet (`hit`) breaks the piece it meets a level, the children by the hit taking over enough of it to come free:
/// a burst chips a wall. A rocket (`rocket`) is a ball sent like a shot that goes off where it meets something: the
/// step it would, it is gone, and a blast pushes and breaks what is round it over the next steps. The walker is a
/// capsule that never turns over: each step its speed over what it stands on is brought toward what the input asks,
/// so it walks up the flights' slopes, rides what falls under it and falls where nothing is; contacts push it as they
/// push anything (but it breaks nothing it lands on).
///
/// All of it is the world's state, set by stamped commands: a replay does it again, on any number of cores. The GPU's
/// step knows none of it (the scene steps on the CPU).
struct DemolitionState {
    /// A rocket of the pool (bodies made at the scene's build, disabled until fired).
    struct Rocket {
        var body: Int32
        /// In flight since `launched` (a step), at `speed` then; its blast's radius.
        var armed = false
        var launched: UInt32 = 0
        var speed: Float = 0
        var radius: Float = 0
    }

    struct Walker {
        /// Its body (-1: no walker), enabled while walking.
        var body: Int32 = -1
        var on = false
        /// What the input asks: speed over the ground (m/s, x and z), a jump's speed (once, when it stands).
        var speed = SIMD2<Float>()
        var jump: Float = 0
        /// A teleport asked for (where to), switching it on or off.
        var place: SIMD3<Float>?
        var enable = false, disable = false
        /// What the last step found under it.
        var grounded = false
        var ground: Int32 = -1
        /// Where it last stood (a fall out of the world, or stuck in rubble, comes back here), and steps stuck.
        var safe = SIMD3<Float>()
        var stuck = 0

        /// Drive command flags (GPUFractureCommand.info.z).
        static let enableFlag: UInt32 = 1, disableFlag: UInt32 = 2, placeFlag: UInt32 = 4

        /// Command `c` (a drive), at its step.
        mutating func take(_ c: GPUFractureCommand, clock: UInt32) {
            guard c.info.x == clock else { return }
            speed = SIMD2(c.direction.x, c.direction.z)
            if c.direction.y > 0 { jump = c.direction.y }
            if c.info.z & Walker.placeFlag != 0 { place = PhysicsWorld.xyz(c.origin) }
            if c.info.z & Walker.enableFlag != 0 { enable = true }
            if c.info.z & Walker.disableFlag != 0 { disable = true }
        }
    }

    var rockets: [Rocket] = []
    /// Blasts rockets set off, going on (as blast commands: start step, steps).
    var blasts: [GPUFractureCommand] = []
    /// Where rockets went off (xyz, the blast's radius) and at which steps: the fireballs (the last `logLength`).
    var detonations: [SIMD4<Float>] = []
    var detonationSteps: [Int] = []
    var walker = Walker()
    /// The walker as built (`reset` puts it back).
    var startWalker = Walker()
    /// Bodies near the walker this step (scratch).
    var near: [Int32] = []

    var active: Bool { !rockets.isEmpty || walker.body >= 0 }
    static let logLength = 32

    mutating func reset() {
        for i in rockets.indices { rockets[i].armed = false }
        blasts.removeAll()
        detonations.removeAll()
        detonationSteps.removeAll()
        walker = startWalker
    }
}

extension PhysicsWorld {
    /// A rocket's ball (it goes off where it meets something) and the walker: bodies the rest of the world isn't.
    static let fuseBit: UInt32 = 32
    static let walkerBit: UInt32 = 64
    /// A rocket's blast: its push (m/s at the middle) over its steps.
    static let rocketPush: Float = 16
    static let rocketSteps = 6
    /// A rocket that has flown this long (steps) goes off where it is.
    static let rocketLife: UInt32 = 240
    /// The walker's capsule (m): half the length of its middle, its radius; its eyes above its centre.
    static let walkerHalf: Float = 0.6, walkerRadius: Float = 0.3
    /// How fast the walker gets to the speed asked for (m/s^2), standing and in the air.
    static let walkerGrip: Float = 25, walkerAir: Float = 4

    // MARK: Building

    /// Body `i` a rocket of the pool (disabled until fired).
    func addRocket(_ i: Int) {
        bodies[i].info.y |= PhysicsWorld.fuseBit | PhysicsWorld.disabledBit
        demolition.rockets.append(DemolitionState.Rocket(body: Int32(i)))
    }

    /// Body `i` the walker: a capsule that doesn't turn, off until a drive switches it on.
    func addWalker(_ i: Int) {
        bodies[i].info.y |= PhysicsWorld.walkerBit | PhysicsWorld.disabledBit
        bodies[i].invInertia = SIMD4(.zero, bodies[i].invInertia.w)
        demolition.walker = DemolitionState.Walker(body: Int32(i))
        demolition.startWalker = demolition.walker
    }

    // MARK: Commands

    /// A bullet: its body (or, if that broke since it was aimed at, the piece of it nearest the hit) takes the hit's
    /// impulse, and as much impact as breaks it a level (a leaf: frees it).
    func hitBody(_ c: GPUFractureCommand) {
        let point = PhysicsWorld.xyz(c.origin), dir = PhysicsWorld.xyz(c.direction), impulse = c.direction.w
        guard bodies.indices.contains(Int(c.info.z)) else { return }
        let i = livePiece(Int(c.info.z), near: point)
        guard i >= 0 else { return }
        if bodies[i].info.y & PhysicsWorld.pieceBit != 0 {
            let node = fractureNodes[i]
            let breaks = node.info.z > 0 ? node.offset.w : node.extra.y
            PhysicsWorld.strike(&fractureState[i], point, dir, max(impulse, breaks * 1.02))
        }
        guard bodies[i].position.w > 0, bodies[i].info.y & PhysicsWorld.kinematicBit == 0 else { return }
        bodies[i].info.y &= ~PhysicsWorld.asleep
        bodies[i].prevPosition.w = 0
        let r = point - PhysicsWorld.xyz(bodies[i].position)
        var b = bodies[i]
        PhysicsWorld.kick(&b, dir * impulse, r, .zero)
        bodies[i] = b
    }

    /// Body `i` if it is enabled; else, if it broke, its live descendant nearest `point`; else -1.
    func livePiece(_ i: Int, near point: SIMD3<Float>) -> Int {
        if bodies[i].info.y & PhysicsWorld.disabledBit == 0 { return i }
        guard bodies[i].info.y & PhysicsWorld.pieceBit != 0, broke(i) else { return -1 }
        let node = fractureNodes[i]
        var best = -1, nearest = Float.infinity
        for k in Int(node.info.y)..<Int(node.info.y + node.info.z)
            where bodies[k].info.y & PhysicsWorld.disabledBit == 0 || broke(k) {
            let d = length_squared(PhysicsWorld.xyz(bodies[k].position) - point)
            if d < nearest { (best, nearest) = (k, d) }
        }
        return best >= 0 ? livePiece(best, near: point) : -1
    }

    /// Whether disabled piece `i` broke (pieces of it are still there) rather than not being there yet, or gone.
    private func broke(_ i: Int) -> Bool {
        let node = fractureNodes[i]
        guard node.info.z > 0 else { return false }
        for k in Int(node.info.y)..<Int(node.info.y + node.info.z)
            where bodies[k].info.y & PhysicsWorld.disabledBit == 0 || broke(k) { return true }
        return false
    }

    /// A rocket sent (at its command's step).
    func launchRocket(_ c: GPUFractureCommand, clock: UInt32) {
        let i = Int(c.info.z)
        guard clock == c.info.x, bodies.indices.contains(i),
              let r = demolition.rockets.firstIndex(where: { $0.body == Int32(i) }) else { return }
        PhysicsWorld.launch(&bodies[i], c)
        demolition.rockets[r].armed = true
        demolition.rockets[r].launched = clock
        demolition.rockets[r].speed = c.direction.w
        demolition.rockets[r].radius = c.origin.w
    }

    // MARK: The step's start

    /// The rockets that meet something this step gone off, the blasts going on pushing, the walker driven.
    func beginDemolitionStep(_ clock: UInt32) {
        let h = PhysicsWorld.stepLength
        for r in demolition.rockets.indices where demolition.rockets[r].armed {
            let rocket = demolition.rockets[r], i = Int(rocket.body)
            let x = PhysicsWorld.xyz(bodies[i].position), v = PhysicsWorld.xyz(bodies[i].velocity)
            let speed = length(v), radius = bodies[i].invInertia.w
            // Where it will be by the step's end (and a little more): anything there, the ground, a hit that slowed
            // it (one the look ahead missed), or old age.
            var goes = clock - rocket.launched > PhysicsWorld.rocketLife || x.y < radius * 1.5 || speed < rocket.speed * 0.5
                || !(x.x.isFinite && x.y.isFinite && x.z.isFinite)
            if !goes && speed > 1e-3 {
                goes = probe(x, v / speed, length: speed * h + radius * 2, skipping: PhysicsWorld.fuseBit | PhysicsWorld.walkerBit) != nil
            }
            guard goes else { continue }
            demolition.rockets[r].armed = false
            bodies[i].info.y |= PhysicsWorld.disabledBit
            bodies[i].velocity = SIMD4(.zero, bodies[i].velocity.w)
            bodies[i].angular = SIMD4(.zero, bodies[i].angular.w)
            let at = x.x.isFinite && x.y.isFinite && x.z.isFinite ? x : PhysicsWorld.xyz(bodies[i].prevPosition)
            demolition.blasts.append(GPUFractureCommand(info: SIMD4(clock, FractureCommand.blast.rawValue, 0, UInt32(PhysicsWorld.rocketSteps)),
                                                        origin: SIMD4(at, rocket.radius), direction: SIMD4(0, 0, 0, PhysicsWorld.rocketPush)))
            demolition.detonations.append(SIMD4(at, rocket.radius))
            demolition.detonationSteps.append(Int(clock))
            if demolition.detonations.count > DemolitionState.logLength {
                demolition.detonations.removeFirst()
                demolition.detonationSteps.removeFirst()
            }
        }
        if !demolition.blasts.isEmpty {
            for c in demolition.blasts where c.info.x <= clock && clock < c.info.x + c.info.w {
                for i in bodies.indices { PhysicsWorld.blast(&bodies[i], &fractureState[i], fractureNodes[i], c) }
            }
            demolition.blasts.removeAll { clock + 1 >= $0.info.x + $0.info.w }
        }
        if demolition.walker.body >= 0 { driveWalker() }
    }

    /// The walker this step: switched on or off, put somewhere; then what is under it, and its speed over that
    /// brought toward what the input asks (and a jump).
    private func driveWalker() {
        let h = PhysicsWorld.stepLength
        var w = demolition.walker
        defer { demolition.walker = w }
        let i = Int(w.body)
        if w.disable {
            w.disable = false
            w.on = false
            bodies[i].info.y |= PhysicsWorld.disabledBit
            bodies[i].velocity = SIMD4(.zero, bodies[i].velocity.w)
        }
        if w.enable || w.place != nil {
            let x = w.place ?? PhysicsWorld.xyz(bodies[i].position)
            if w.enable { w.on = true }
            w.enable = false
            w.place = nil
            place(i, at: x)
            w.safe = x
            w.stuck = 0
        }
        guard w.on else { return }
        var b = bodies[i]
        b.info.y &= ~PhysicsWorld.asleep
        b.prevPosition.w = 0
        var x = PhysicsWorld.xyz(b.position)
        if !(x.x.isFinite && x.y.isFinite && x.z.isFinite) || x.y < -10 {
            bodies[i] = b
            place(i, at: w.safe)
            return
        }
        // What is round it: the bodies whose spheres come within reach of its capsule.
        let reach = PhysicsWorld.walkerHalf + PhysicsWorld.walkerRadius + 0.4
        demolition.near.removeAll(keepingCapacity: true)
        for k in bodies.indices where k != i {
            let o = bodies[k]
            guard o.info.y & (PhysicsWorld.disabledBit | PhysicsWorld.fuseBit) == 0 else { continue }
            let d = PhysicsWorld.xyz(o.position) - x
            let r = o.invInertia.w + reach
            if dot(d, d) < r * r { demolition.near.append(Int32(k)) }
        }
        // Inside something (rubble fell onto it): out upward, a little a step.
        var inside = false
        for k in demolition.near {
            let o = bodies[Int(k)]
            let local = PhysicsMath.qrot(PhysicsMath.qconj(o.rotation), x - PhysicsWorld.xyz(o.position))
            if distance(shape: Int(o.info.x), local) < -0.1 { inside = true; break }
        }
        w.stuck = inside ? w.stuck + 1 : 0
        if w.stuck > 20 {
            x.y += 0.5
            b.position = SIMD4(x, b.position.w)
            b.prevPosition = SIMD4(x, 0)
        }
        // What it stands on: rays down from its middle and round it, to just under its feet.
        let foot = PhysicsWorld.walkerHalf + PhysicsWorld.walkerRadius
        var ground: (body: Int, t: Float)?
        var groundNormal = SIMD3<Float>(0, 1, 0)
        let around: [SIMD2<Float>] = [.zero, [0.18, 0], [-0.18, 0], [0, 0.18], [0, -0.18]]
        for o in around {
            let from = x + SIMD3(o.x, 0, o.y)
            guard let hit = probeNear(from, [0, -1, 0], length: foot + 0.12) else { continue }
            let j = hit.body, oj = bodies[j]
            let local = PhysicsMath.qrot(PhysicsMath.qconj(oj.rotation), from + SIMD3(0, -hit.t, 0) - PhysicsWorld.xyz(oj.position))
            let n = PhysicsMath.qrot(oj.rotation, gradient(shape: Int(oj.info.x), local))
            let ln = length(n)
            guard ln > 1e-6, n.y / ln > 0.55 else { continue }
            if ground == nil || hit.t < ground!.t { (ground, groundNormal) = (hit, n / ln) }
        }
        _ = groundNormal
        let onFloor = x.y - foot < 0.12   // (the ground plane)
        var under = SIMD3<Float>()
        if let g = ground {
            let o = bodies[g.body]
            let point = x - SIMD3(0, g.t, 0)
            if PhysicsWorld.moves(o) {
                under = PhysicsWorld.xyz(o.velocity) + cross(PhysicsWorld.xyz(o.angular), point - PhysicsWorld.xyz(o.position))
            }
        }
        w.grounded = ground != nil || onFloor
        w.ground = Int32(ground?.body ?? -1)
        // Its speed over the ground toward what is asked, as fast as its grip allows.
        var v = PhysicsWorld.xyz(b.velocity)
        let want = SIMD2(under.x, under.z) + w.speed
        var dv = want - SIMD2(v.x, v.z)
        let most = (w.grounded ? PhysicsWorld.walkerGrip : PhysicsWorld.walkerAir) * h
        let l = length(dv)
        if l > most { dv *= most / l }
        v.x += dv.x
        v.z += dv.y
        if w.jump > 0 {
            if w.grounded { v.y = max(v.y, under.y) + w.jump }
            w.jump = 0
        }
        b.velocity = SIMD4(v, b.velocity.w)
        b.angular = SIMD4(.zero, b.angular.w)
        bodies[i] = b
        if w.grounded && !inside && ground.map({ PhysicsWorld.moves(bodies[$0.body]) == false }) ?? true { w.safe = x }
    }

    /// Body `i` (the walker) enabled at `x`, still, upright.
    private func place(_ i: Int, at x: SIMD3<Float>) {
        bodies[i].info.y &= ~(PhysicsWorld.disabledBit | PhysicsWorld.asleep)
        bodies[i].position = SIMD4(x, bodies[i].position.w)
        bodies[i].prevPosition = SIMD4(x, 0)
        bodies[i].rotation = SIMD4(0, 0, 0, 1)
        bodies[i].prevRotation = SIMD4(0, 0, 0, 1)
        bodies[i].velocity = SIMD4(.zero, bodies[i].velocity.w)
        bodies[i].angular = SIMD4(.zero, bodies[i].angular.w)
    }

    /// The nearest enabled body (but those with a flag of `skipping`) the ray from `origin` along `direction` (unit)
    /// meets within `length`, and how far along: sphere-traced through each whose bounding sphere it crosses.
    func probe(_ origin: SIMD3<Float>, _ direction: SIMD3<Float>, length: Float, skipping: UInt32) -> (body: Int, t: Float)? {
        var best: (body: Int, t: Float)?
        for i in bodies.indices where bodies[i].info.y & (PhysicsWorld.disabledBit | skipping) == 0 {
            if let t = trace(i, origin, direction, until: best?.t ?? length) { best = (i, t) }
        }
        return best
    }

    /// ...among the walker's `near` bodies.
    private func probeNear(_ origin: SIMD3<Float>, _ direction: SIMD3<Float>, length: Float) -> (body: Int, t: Float)? {
        var best: (body: Int, t: Float)?
        for k in demolition.near {
            if let t = trace(Int(k), origin, direction, until: best?.t ?? length) { best = (Int(k), t) }
        }
        return best
    }

    /// How far along the ray body `i`'s surface is, if it is before `end`.
    @inline(__always) private func trace(_ i: Int, _ origin: SIMD3<Float>, _ direction: SIMD3<Float>, until end: Float) -> Float? {
        let x = PhysicsWorld.xyz(bodies[i].position), q = bodies[i].rotation
        let radius = bodies[i].invInertia.w, oc = origin - x
        let b = dot(oc, direction), c = dot(oc, oc) - radius * radius, disc = b * b - c
        guard disc >= 0 else { return nil }
        var t = max(-b - sqrt(disc), 0)
        let last = min(-b + sqrt(disc), end)
        for _ in 0..<48 where t < last {
            let local = PhysicsMath.qrot(PhysicsMath.qconj(q), origin + direction * t - x)
            let d = distance(shape: Int(bodies[i].info.x), local)
            if d < 1e-3 { return t }
            t += max(d, 1e-4)
        }
        return nil
    }
}
