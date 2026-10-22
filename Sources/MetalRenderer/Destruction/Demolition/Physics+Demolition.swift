import EngineCore
import Foundation
import Plants
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
package struct DemolitionState {
    /// A rocket of the pool (bodies made at the scene's build, disabled until fired).
    package struct Rocket {
        package var body: Int32
        /// In flight since `launched` (a step), at `speed` then; its blast's radius.
        package var armed = false
        var launched: UInt32 = 0
        var speed: Float = 0
        var radius: Float = 0
    }

    package struct Walker {
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
        package static let enableFlag: UInt32 = 1, disableFlag: UInt32 = 2, placeFlag: UInt32 = 4

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

    package var rockets: [Rocket] = []
    /// Blasts rockets set off, going on (as blast commands: start step, steps).
    var blasts: [GPUFractureCommand] = []
    /// Where rockets went off (xyz, the blast's radius) and at which steps: the fireballs (the last `logLength`).
    package var detonations: [SIMD4<Float>] = []
    package var detonationSteps: [Int] = []
    var walker = Walker()
    /// The walker as built (`reset` puts it back).
    var startWalker = Walker()
    /// Bodies near the walker this step (scratch).
    var near: [Int32] = []
    /// How many of the world's commands its build made (PhysicsWorld.keepBuiltCommands).
    var builtCommands = 0

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
    package static let walkerHalf: Float = 0.6, walkerRadius: Float = 0.3
    /// How fast the walker gets to the speed asked for (m/s^2), standing and in the air.
    static let walkerGrip: Float = 25, walkerAir: Float = 4
    /// A bullet's impact on a piece: this many times what breaks (or frees) it.
    static let bulletBreak: Float = 3
    /// How fast a piece a bullet knocks out goes (m/s).
    static let chipSpeed: Float = 3.5

    // MARK: Building

    /// Body `i` a rocket of the pool (disabled until fired).
    package func addRocket(_ i: Int) {
        bodies[i].info.y |= PhysicsWorld.fuseBit | PhysicsWorld.disabledBit
        demolition.rockets.append(DemolitionState.Rocket(body: Int32(i)))
    }

    /// Body `i` the walker: a capsule that doesn't turn, off until a drive switches it on.
    package func addWalker(_ i: Int) {
        bodies[i].info.y |= PhysicsWorld.walkerBit | PhysicsWorld.disabledBit
        bodies[i].invInertia = SIMD4(.zero, bodies[i].invInertia.w)
        demolition.walker = DemolitionState.Walker(body: Int32(i))
        demolition.startWalker = demolition.walker
    }

    /// The commands the scene was built with (its demo's), and the player's after them: dropped by `dropPlayerCommands`.
    package func keepBuiltCommands() { demolition.builtCommands = fractureCommands.count }

    /// The player's commands dropped (a restart: the world replays its build's alone from the start).
    package func dropPlayerCommands() {
        let n = demolition.builtCommands
        guard fractureCommands.count > n else { return }
        fractureCommands.removeLast(fractureCommands.count - n)
        commandOrder.removeAll { Int($0) >= n }
        longestCommand = max(1, fractureCommands.map(\.info.w).max() ?? 1)
    }

    /// The nearest body of `drawn` (a stepper's latest poses: any thread), but disabled ones, rockets and the walker,
    /// that the ray from `origin` along `direction` (unit) meets within `limit`: it, how far, and its surface's normal
    /// there (the world).
    package func pick(drawn: [GPUPhysicsBody], origin: SIMD3<Float>, direction: SIMD3<Float>, limit: Float = 500)
        -> (body: Int, t: Float, normal: SIMD3<Float>)? {
        var best: (body: Int, t: Float)?
        let skip = PhysicsWorld.disabledBit | PhysicsWorld.fuseBit | PhysicsWorld.walkerBit
        drawn.withUnsafeBufferPointer { b in
            for i in b.indices where b[i].info.y & skip == 0 {
                let x = PhysicsWorld.xyz(b[i].position), q = b[i].rotation, radius = b[i].invInertia.w, oc = origin - x
                let p = dot(oc, direction), c = dot(oc, oc) - radius * radius, disc = p * p - c
                guard disc >= 0 else { continue }
                var t = max(-p - sqrt(disc), 0)
                let end = min(-p + sqrt(disc), best?.t ?? limit)
                for _ in 0..<64 where t < end {
                    let d = distance(shape: Int(b[i].info.x), PhysicsMath.qrot(PhysicsMath.qconj(q), origin + direction * t - x))
                    if d < 1e-3 { best = (i, t); break }
                    t += max(d, 1e-4)
                }
            }
        }
        guard let best else { return nil }
        let o = drawn[best.body]
        let local = PhysicsMath.qrot(PhysicsMath.qconj(o.rotation), origin + direction * best.t - PhysicsWorld.xyz(o.position))
        var n = PhysicsMath.qrot(o.rotation, gradient(shape: Int(o.info.x), local))
        n = length(n) > 1e-6 ? normalize(n) : -direction
        return (best.body, best.t, n)
    }

    // MARK: Commands

    /// A bullet: its body (or, if that broke since it was aimed at, the piece of it nearest the hit) takes the hit's
    /// impulse, and as much impact as breaks it a level (a leaf: frees it).
    func hitBody(_ c: GPUFractureCommand) {
        let point = PhysicsWorld.xyz(c.origin), dir = PhysicsWorld.xyz(c.direction), impulse = c.direction.w
        guard bodies.indices.contains(Int(c.info.z)) else { return }
        let i = livePiece(Int(c.info.z), near: point)
        guard i >= 0 else { return }
        var push = impulse
        if bodies[i].info.y & PhysicsWorld.pieceBit != 0 {
            let node = fractureNodes[i]
            if node.info.z > 0 {
                // Well past what breaks it: its pieces by the hit take over a share of it.
                PhysicsWorld.strike(&fractureState[i], point, dir, max(impulse, node.offset.w * PhysicsWorld.bulletBreak))
            } else if node.info.x != PhysicsWorld.none {
                // The smallest piece: knocked out at once (its welds broken now, not at the step's end, where they
                // would have held the push back), and away along the bullet.
                breakWelds(i)
                PhysicsWorld.free(&bodies[i], node)
                fractureState[i].hold.x = 0
                if bodies[i].position.w > 0 { push = max(impulse, PhysicsWorld.chipSpeed / bodies[i].position.w) }
            }
        }
        guard bodies[i].position.w > 0, bodies[i].info.y & PhysicsWorld.kinematicBit == 0 else { return }
        bodies[i].info.y &= ~PhysicsWorld.asleep
        bodies[i].prevPosition.w = 0
        let r = point - PhysicsWorld.xyz(bodies[i].position)
        var b = bodies[i]
        PhysicsWorld.kick(&b, dir * push, r, .zero)
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
                let shapes = shapeData
                goes = bodies.withUnsafeBufferPointer { b in
                    PhysicsWorld.nearest(b, shapes, list: nil, x, v / speed, length: speed * h + radius * 2,
                                         skipping: PhysicsWorld.fuseBit | PhysicsWorld.walkerBit).body >= 0
                }
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
                bodies.withUnsafeMutableBufferPointer { b in
                    fractureState.withUnsafeMutableBufferPointer { s in
                        fractureNodes.withUnsafeBufferPointer { PhysicsWorld.blastAll(c, b, s, $0) }
                    }
                }
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
        let reach = PhysicsWorld.walkerHalf + PhysicsWorld.walkerRadius + 0.4, shapes = shapeData
        if demolition.near.count != bodies.count { demolition.near = [Int32](repeating: 0, count: bodies.count) }
        let near = bodies.withUnsafeBufferPointer { b in
            demolition.near.withUnsafeMutableBufferPointer { PhysicsWorld.gather(b, around: x, reach: reach, skip: i, into: $0) }
        }
        // Inside something (rubble fell onto it): out upward, a little a step.
        let inside = bodies.withUnsafeBufferPointer { b in
            demolition.near.withUnsafeBufferPointer { PhysicsWorld.inside(b, shapes, UnsafeBufferPointer(rebasing: $0[0..<near]), x, by: 0.1) }
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
        for k in 0..<5 {
            // (Its middle, then a little to each side.)
            let o = k == 0 ? SIMD2<Float>() : SIMD2<Float>(k == 1 ? 0.18 : k == 2 ? -0.18 : 0, k == 3 ? 0.18 : k == 4 ? -0.18 : 0)
            let from = x + SIMD3(o.x, 0, o.y)
            let hit = bodies.withUnsafeBufferPointer { b in
                demolition.near.withUnsafeBufferPointer {
                    PhysicsWorld.nearest(b, shapes, list: UnsafeBufferPointer(rebasing: $0[0..<near]), from, [0, -1, 0], length: foot + 0.12, skipping: 0)
                }
            }
            guard hit.body >= 0 else { continue }
            let j = hit.body, oj = bodies[j]
            let local = PhysicsMath.qrot(PhysicsMath.qconj(oj.rotation), from + SIMD3(0, -hit.t, 0) - PhysicsWorld.xyz(oj.position))
            let n = PhysicsMath.qrot(oj.rotation, gradient(shape: Int(oj.info.x), local))
            let ln = length(n)
            guard ln > 1e-6, n.y / ln > 0.55 else { continue }
            if ground == nil || hit.t < ground!.t { ground = (hit.body, hit.t) }
        }
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

    // MARK: Over the bodies (buffers, nothing allocated: Tools/perf/hot-functions.txt)

    /// The bodies of `b` whose spheres come within `reach` of `x` (but `skip`, disabled ones and rockets): their indices
    /// into `out`, and how many.
    static func gather(_ b: UnsafeBufferPointer<GPUPhysicsBody>, around x: SIMD3<Float>, reach: Float, skip: Int,
                       into out: UnsafeMutableBufferPointer<Int32>) -> Int {
        var n = 0
        for k in 0..<b.count where k != skip && b[k].info.y & (disabledBit | fuseBit) == 0 {
            let d = xyz(b[k].position) - x, r = b[k].invInertia.w + reach
            if dot(d, d) < r * r && n < out.count {
                out[n] = Int32(k)
                n += 1
            }
        }
        return n
    }

    /// Whether `x` is deeper than `by` inside any of `list`'s bodies.
    static func inside(_ b: UnsafeBufferPointer<GPUPhysicsBody>, _ shapes: PhysicsShapes, _ list: UnsafeBufferPointer<Int32>, _ x: SIMD3<Float>,
                       by depth: Float) -> Bool {
        for k in list {
            let o = b[Int(k)]
            if shapes.distance(shape: Int(o.info.x), PhysicsMath.qrot(PhysicsMath.qconj(o.rotation), x - xyz(o.position))) < -depth { return true }
        }
        return false
    }

    /// The nearest of `b`'s bodies (those of `list`, or every enabled one but those with a flag of `skipping`) the ray
    /// from `origin` along `direction` (unit) meets within `length`, and how far along (body -1: none).
    static func nearest(_ b: UnsafeBufferPointer<GPUPhysicsBody>, _ shapes: PhysicsShapes, list: UnsafeBufferPointer<Int32>?,
                        _ origin: SIMD3<Float>, _ direction: SIMD3<Float>, length: Float, skipping: UInt32) -> (body: Int, t: Float) {
        var best = (body: -1, t: length)
        if let list {
            for k in list {
                let t = trace(b[Int(k)], shapes, origin, direction, until: best.t)
                if t >= 0 { best = (Int(k), t) }
            }
        } else {
            for i in 0..<b.count where b[i].info.y & (disabledBit | skipping) == 0 {
                let t = trace(b[i], shapes, origin, direction, until: best.t)
                if t >= 0 { best = (i, t) }
            }
        }
        return best
    }

    /// How far along the ray body `o`'s surface is, if before `end` (else -1): sphere-traced through its distance from
    /// where the ray enters its bounding sphere.
    @inline(__always) static func trace(_ o: GPUPhysicsBody, _ shapes: PhysicsShapes, _ origin: SIMD3<Float>, _ direction: SIMD3<Float>,
                                        until end: Float) -> Float {
        let x = xyz(o.position), q = PhysicsMath.qconj(o.rotation)
        let radius = o.invInertia.w, oc = origin - x
        let b = dot(oc, direction), c = dot(oc, oc) - radius * radius, disc = b * b - c
        guard disc >= 0 else { return -1 }
        var t = max(-b - sqrt(disc), 0)
        let last = min(-b + sqrt(disc), end)
        for _ in 0..<48 where t < last {
            let d = shapes.distance(shape: Int(o.info.x), PhysicsMath.qrot(q, origin + direction * t - x))
            if d < 1e-3 { return t }
            t += max(d, 1e-4)
        }
        return -1
    }

    /// Blast `c`'s push on every body this step (as beginFractureStep's).
    static func blastAll(_ c: GPUFractureCommand, _ b: UnsafeMutableBufferPointer<GPUPhysicsBody>, _ s: UnsafeMutableBufferPointer<GPUFractureState>,
                         _ nodes: UnsafeBufferPointer<GPUFractureNode>) {
        for i in 0..<b.count { blast(&b[i], &s[i], nodes[i], c) }
    }
}
