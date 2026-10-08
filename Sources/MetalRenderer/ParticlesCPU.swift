import Foundation
import simd

/// The particles' maths (Shaders/Particles.metal's twin, line for line): the hash, the random stream, gradient noise
/// and its curl, a particle's birth and step, the colliders.
enum ParticleMath {
    @inline(__always) static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    /// MSL pcgHash.
    @inline(__always) static func hash(_ v: UInt32) -> UInt32 {
        let state = v &* 747796405 &+ 2891336453
        let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
        return (word >> 22) ^ word
    }

    /// MSL Rng.
    struct Rng {
        var state: UInt32
        mutating func next() -> Float {
            state = ParticleMath.hash(state)
            return Float(state) * (1.0 / 4294967296.0)
        }
    }

    /// A root particle's seed: its emitter's and its spawn id's (MSL particleSeed).
    static func seed(emitter: UInt32, spawn: UInt32) -> UInt32 { hash(spawn &+ hash(emitter &* 0x9E3779B9 &+ 0x7F4A7C15)) }
    /// A child's: its parent's and which child it is (MSL particleChildSeed).
    static func childSeed(parent: UInt32, k: UInt32) -> UInt32 { hash(parent ^ hash(k &+ 0x632BE5AB)) }

    /// An orthonormal basis about unit `n` (Duff et al. 2017; MSL particleBasis).
    static func basis(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let sign: Float = n.z >= 0 ? 1 : -1
        let a = -1 / (sign + n.z), b = n.x * n.y * a
        return (SIMD3(1 + sign * n.x * n.x * a, sign * b, -sign * n.x), SIMD3(b, sign + n.y * n.y * a, -n.y))
    }

    // MARK: Curl noise

    /// The gradient at lattice point `i` of noise channel `salt` (MSL particleGradient).
    @inline(__always) static func gradient(_ i: SIMD3<Int32>, _ salt: UInt32) -> SIMD3<Float> {
        let h = hash(UInt32(bitPattern: i.x) &+ hash(UInt32(bitPattern: i.y) &+ hash(UInt32(bitPattern: i.z) &+ salt)))
        return SIMD3(Float(h & 1023), Float((h >> 10) & 1023), Float((h >> 20) & 1023)) * (1.0 / 511.5) - 1
    }

    /// Gradient noise with its analytic derivatives (quintic; Quilez's "noised"): x = value, yzw = gradient
    /// (MSL particleNoise).
    static func noise(_ x: SIMD3<Float>, _ salt: UInt32) -> SIMD4<Float> {
        let i = floor(x), f = x - i
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        let du = 30 * f * f * (f * (f - 2) + 1)
        let c = SIMD3<Int32>(Int32(i.x), Int32(i.y), Int32(i.z))
        let ga = gradient(c, salt), gb = gradient(c &+ SIMD3(1, 0, 0), salt)
        let gc = gradient(c &+ SIMD3(0, 1, 0), salt), gd = gradient(c &+ SIMD3(1, 1, 0), salt)
        let ge = gradient(c &+ SIMD3(0, 0, 1), salt), gf = gradient(c &+ SIMD3(1, 0, 1), salt)
        let gg = gradient(c &+ SIMD3(0, 1, 1), salt), gh = gradient(c &+ SIMD3(1, 1, 1), salt)
        let va = dot(ga, f), vb = dot(gb, f - SIMD3(1, 0, 0)), vc = dot(gc, f - SIMD3(0, 1, 0)), vd = dot(gd, f - SIMD3(1, 1, 0))
        let ve = dot(ge, f - SIMD3(0, 0, 1)), vf = dot(gf, f - SIMD3(1, 0, 1)), vg = dot(gg, f - SIMD3(0, 1, 1)), vh = dot(gh, f - SIMD3(1, 1, 1))
        let k0 = va - vb - vc + vd, k1 = va - vc - ve + vg, k2 = va - vb - ve + vf, k3 = -va + vb + vc - vd + ve - vf - vg + vh
        let value = va + u.x * (vb - va) + u.y * (vc - va) + u.z * (ve - va) + u.x * u.y * k0 + u.y * u.z * k1 + u.z * u.x * k2
            + u.x * u.y * u.z * k3
        let yzx = SIMD3(u.y, u.z, u.x), zxy = SIMD3(u.z, u.x, u.y)
        var g = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.z * (ge - ga)
        g += u.x * u.y * (ga - gb - gc + gd) + u.y * u.z * (ga - gc - ge + gg) + u.z * u.x * (ga - gb - ge + gf)
        g += u.x * u.y * u.z * (-ga + gb + gc - gd + ge - gf - gg + gh)
        g += du * (SIMD3(vb, vc, ve) - va + yzx * SIMD3(k0, k1, k2) + zxy * SIMD3(k2, k0, k1) + yzx * zxy * k3)
        return SIMD4(value, g.x, g.y, g.z)
    }

    /// The curl of three noise channels taken as a vector potential at `p` (frequency `frequency`, scrolled by
    /// `time` along y): a divergence-free velocity field, of about unit size (MSL particleCurl).
    static func curl(_ p: SIMD3<Float>, frequency: Float, time: Float) -> SIMD3<Float> {
        let q = p * frequency + SIMD3(0, time, 0)
        let x = noise(q, 0x1B873593), y = noise(q + SIMD3(31.416, 47.853, 12.679), 0xCC9E2D51)
        let z = noise(q + SIMD3(-23.137, 11.719, 59.311), 0xE6546B64)
        // ∇×ψ, each derivative times the frequency (d/dp = f d/dq).
        return SIMD3(z.z - y.w, x.w - z.y, y.y - x.z) * frequency
    }

    // MARK: A particle's life

    /// A newborn of emitter `e` (number `emitter`): `spawn` its id, `at` where (a child: its parent's event, else the
    /// emitter's origin), `parentVelocity` a child's parent's. Born somewhere in the step: moved and aged by a random
    /// share of it (MSL particleSpawn).
    static func spawn(_ e: GPUParticleEmitter, emitter: UInt32, seed: UInt32, spawn: UInt32, at: SIMD3<Float>,
                      parentVelocity: SIMD3<Float>, dt: Float) -> GPUParticle {
        var r = Rng(state: seed)
        let u0 = r.next(), u1 = r.next(), u2 = r.next(), u3 = r.next(), u4 = r.next(), u5 = r.next(), u6 = r.next(), u7 = r.next()
        let axis = xyz(e.axis)
        let (t, b) = basis(axis)
        let shape = e.extent.w, radius = e.origin.w
        var offset = SIMD3<Float>.zero
        if shape == 1 || shape == 2 {
            let z = 2 * u0 - 1, phi = 2 * Float.pi * u1, s = (max(1 - z * z, 0)).squareRoot()
            let d = SIMD3(s * cos(phi), s * sin(phi), z)
            offset = d * (shape == 2 ? radius : radius * pow(u2, 1.0 / 3.0))
        } else if shape == 3 {
            let rr = radius * u0.squareRoot(), phi = 2 * Float.pi * u1
            offset = t * (rr * cos(phi)) + b * (rr * sin(phi))
        } else if shape == 4 {
            offset = (SIMD3(u0, u1, u2) * 2 - 1) * xyz(e.extent)
        } else if shape == 5 {
            // Spaced by spawn id along the golden ratio, so any number of them spread round it evenly.
            let g = Float(spawn % 4096) * 0.618034 + u1 * 0.05
            let phi = 2 * Float.pi * (g - g.rounded(.down))
            offset = t * (radius * cos(phi)) + b * (radius * sin(phi))
        }
        var dir: SIMD3<Float>
        if e.speed.z > 0 {
            let l = length(offset)
            dir = l > 1e-6 ? offset / l : axis
        } else {
            let cosT = 1 - u3 * (1 - cos(e.axis.w)), sinT = (max(1 - cosT * cosT, 0)).squareRoot(), phi = 2 * Float.pi * u4
            dir = axis * cosT + (t * cos(phi) + b * sin(phi)) * sinT
        }
        let speed = e.speed.x + (e.speed.y - e.speed.x) * u5
        let v = dir * speed + xyz(e.velocity) + parentVelocity * e.velocity.w
        let life = e.life.x + (e.life.y - e.life.x) * u6
        let pre = u7 * dt
        return GPUParticle(position: SIMD4(at + offset + v * pre, pre), velocity: SIMD4(v, life),
                           info: SIMD4(spawn, seed, emitter, ParticleSystem.alive))
    }

    /// Pushes `x` out of collider `c` and bounces `v` off it: the speed it hit at (0: it didn't) (MSL particleCollide).
    static func collide(_ c: GPUParticleCollider, _ x: inout SIMD3<Float>, _ v: inout SIMD3<Float>, restitution: Float,
                        friction: Float) -> Float {
        var n = SIMD3<Float>.zero
        var inside = false
        if c.b.w == 0 {
            n = xyz(c.a)
            let d = dot(n, x) - c.a.w
            if d < 0 { x -= n * d; inside = true }
        } else if c.b.w == 1 {
            let q = x - xyz(c.a), l = length(q)
            if l < c.a.w && l > 1e-6 { n = q / l; x = xyz(c.a) + n * c.a.w; inside = true }
        } else {
            let q = x - xyz(c.a), o = abs(q) - xyz(c.b)
            if o.x < 0 && o.y < 0 && o.z < 0 {
                let k = o.x > o.y ? (o.x > o.z ? 0 : 2) : (o.y > o.z ? 1 : 2)
                let s: Float = q[k] >= 0 ? 1 : -1
                n[k] = s
                x[k] = c.a[k] + s * c.b[k]
                inside = true
            }
        }
        if !inside { return 0 }
        let vn = dot(v, n)
        if vn >= 0 { return 0 }
        v = (v - n * vn) * (1 - friction) - n * (vn * restitution)
        return -vn
    }

    /// A particle's step: ages it, then (if it lives) the forces, the drag toward the air, semi-implicit Euler and the
    /// colliders. `keep`: it lives on; `event`: it leaves its children an event (MSL particleStep).
    static func step(_ p: inout GPUParticle, _ e: GPUParticleEmitter, _ colliders: [GPUParticleCollider], _ s: GPUParticleStep)
        -> (keep: Bool, event: Bool) {
        let flags = ParticleEmitter.Flags(rawValue: e.ids.w)
        let age = p.position.w + s.dt
        if age >= p.velocity.w { return (false, flags.contains(.eventsOnDeath)) }
        var x = xyz(p.position), v = xyz(p.velocity)
        var a = SIMD3<Float>(0, -s.gravity * e.forces.x, 0)
        if e.forces.w != 0 { a += curl(x, frequency: e.noise.x, time: s.wind.w * e.noise.y) * e.forces.w }
        if e.noise.z != 0 || e.noise.w != 0 {
            let r = x - xyz(e.attractor), axis = xyz(e.axis)
            let rp = r - axis * dot(r, axis), lp = length(rp), lr = length(r)
            if lp > 1e-4 { a += cross(axis, rp) * (e.noise.z / lp) }
            if lr > 1e-4 { a -= r * (e.noise.w / lr) }
        }
        v += a * s.dt
        if e.forces.y > 0 {
            let air = xyz(s.wind) * e.forces.z
            v = air + (v - air) * exp(-e.forces.y * s.dt)
        }
        x += v * s.dt
        var impact: Float = 0
        for (i, c) in colliders.enumerated() where (e.ids2.y >> UInt32(i)) & 1 != 0 {
            impact = max(impact, collide(c, &x, &v, restitution: e.attractor.w, friction: e.lock.w))
        }
        p.position = SIMD4(x, age)
        p.velocity = SIMD4(v, p.velocity.w)
        let hit = impact > 0.3   // a touch, not a particle at rest on it
        if hit && flags.contains(.killOnCollision) {
            return (false, flags.contains(.eventsOnCollision) || flags.contains(.eventsOnDeath))
        }
        return (true, hit && flags.contains(.eventsOnCollision))
    }
}

/// What a dying (or colliding) particle leaves its emitter's children (MSL ParticleEvent): where, its seed; its
/// velocity, its spawn id.
struct ParticleEvent {
    var a = SIMD4<Float>()
    var b = SIMD4<Float>()

    init(_ p: GPUParticle) {
        a = SIMD4(ParticleMath.xyz(p.position), Float(bitPattern: p.info.y))
        b = SIMD4(ParticleMath.xyz(p.velocity), Float(bitPattern: p.info.x))
    }
    init(a: SIMD4<Float>, b: SIMD4<Float>) { self.a = a; self.b = b }
    var seed: UInt32 { a.w.bitPattern }
    var spawn: UInt32 { b.w.bitPattern }
}

/// The particles' step on the CPU, in the GPU's order (begin, emit, simulate): the reference ParticleTests check the
/// kernels against. The same pool, dead lists and alive lists; the alive lists' order is the CPU's (the GPU's is
/// whatever its atomics give), so the two are compared as sets, by emitter and spawn id.
final class ParticlesCPU {
    let system: ParticleSystem
    private let emitters: [GPUParticleEmitter]
    private let colliders: [GPUParticleCollider]
    private(set) var particles: [GPUParticle] = []
    private(set) var deadList: [UInt32] = []
    private(set) var deadCount: [Int] = []
    private(set) var alive: [[UInt32]] = [[], []]
    /// Per parity, per emitter: the events its particles left.
    private(set) var events: [[[ParticleEvent]]] = []
    private(set) var emitted: [UInt32] = []
    private(set) var stepIndex = 0

    init(_ system: ParticleSystem) {
        self.system = system
        emitters = system.gpuEmitters
        colliders = system.gpuColliders
        reset()
    }

    func reset() {
        particles = Array(repeating: GPUParticle(), count: system.capacity)
        deadList = (0..<system.capacity).map(UInt32.init)
        deadCount = emitters.map { Int($0.ids.y) }
        alive = [[], []]
        events = [Array(repeating: [], count: emitters.count), Array(repeating: [], count: emitters.count)]
        emitted = Array(repeating: 0, count: emitters.count)
        stepIndex = 0
    }

    /// The particles alive after the last step (the list the next one reads).
    var current: [GPUParticle] { alive[stepIndex & 1].map { particles[Int($0)] } }

    func step(wind: SIMD4<Float> = .zero) {
        let s = system.stepParams(stepIndex, wind: wind)
        let p = Int(s.parity & 1)
        // begin
        var counts = [Int](), tops = [Int](), first = [UInt32]()
        for (i, e) in emitters.enumerated() {
            let want: Int
            if e.ids.z == ParticleSystem.none {
                want = Int(ParticleSystem.requests(e, s))
            } else {
                want = events[1 - p][Int(e.ids.z)].count * Int(e.ids2.x)
            }
            let n = min(want, deadCount[i])
            tops.append(deadCount[i])
            deadCount[i] -= n
            counts.append(n)
            first.append(emitted[i])
            emitted[i] &+= UInt32(n)
        }
        let consumed = events[1 - p]
        events[p] = Array(repeating: [], count: emitters.count)
        // emit
        for (i, e) in emitters.enumerated() {
            let base = Int(e.ids.x)
            for j in 0..<counts[i] {
                let slot = deadList[base + tops[i] - 1 - j]
                if e.ids.z == ParticleSystem.none {
                    let id = first[i] &+ UInt32(j)
                    particles[Int(slot)] = ParticleMath.spawn(e, emitter: UInt32(i), seed: ParticleMath.seed(emitter: UInt32(i), spawn: id),
                                                              spawn: id, at: ParticleMath.xyz(e.origin), parentVelocity: .zero, dt: s.dt)
                } else {
                    let per = Int(e.ids2.x), ev = consumed[Int(e.ids.z)][j / per], k = UInt32(j % per)
                    particles[Int(slot)] = ParticleMath.spawn(e, emitter: UInt32(i), seed: ParticleMath.childSeed(parent: ev.seed, k: k),
                                                              spawn: ev.spawn &* 8 &+ k, at: ParticleMath.xyz(ev.a),
                                                              parentVelocity: ParticleMath.xyz(ev.b), dt: s.dt)
                }
                alive[p].append(slot)
            }
        }
        // simulate
        var out: [UInt32] = []
        for slot in alive[p] {
            var q = particles[Int(slot)]
            let ei = Int(q.info.z), e = emitters[ei]
            let (keep, event) = ParticleMath.step(&q, e, colliders, s)
            if event && events[p][ei].count < Int(e.ids.y) { events[p][ei].append(ParticleEvent(q)) }
            if keep {
                particles[Int(slot)] = q
                out.append(slot)
            } else {
                particles[Int(slot)].info.w = 0
                deadList[Int(e.ids.x) + deadCount[ei]] = slot
                deadCount[ei] += 1
            }
        }
        alive[1 - p] = out
        stepIndex += 1
    }

    func advance(steps: Int, wind: SIMD4<Float> = .zero) { for _ in 0..<steps { step(wind: wind) } }
}

// MARK: - What rays meet (ParticleTrace.metal's twins, for the tests)

extension ParticleMath {
    /// MSL particleAcross.
    static func across(_ n: SIMD3<Float>, spin: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        let helper: SIMD3<Float> = abs(n.y) < 0.999 ? [0, 1, 0] : [1, 0, 0]
        let u0 = normalize(cross(helper, n)), v0 = cross(n, u0)
        let c = cos(spin), s = sin(spin)
        return (u0 * c + v0 * s, v0 * c - u0 * s)
    }

    /// MSL particleBillboard: where the ray o + d t meets the billboard of `r`, and the uv there (-1...1 across it).
    static func billboard(_ r: GPUParticleRender, _ o: SIMD3<Float>, _ d: SIMD3<Float>) -> (t: Float, uv: SIMD2<Float>)? {
        let c = xyz(r.centerRadius), radius = r.centerRadius.w
        let orient = (r.info.x >> 27) & 3
        var n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, size = SIMD2<Float>(radius, radius)
        if orient == 1 || orient == 2 {
            let h = length(xyz(r.axis)), a = xyz(r.axis) / max(h, 1e-12)
            let w = cross(a, d), lw = length(w)
            if lw < 1e-6 * length(d) { return nil }
            u = w / lw
            v = a
            n = cross(u, v)
            size.y = h
        } else {
            n = orient == 3 ? xyz(r.axis) : -normalize(d)
            (u, v) = across(n, spin: r.axis.w)
        }
        let dn = dot(d, n)
        if abs(dn) < 1e-8 { return nil }
        let t = dot(c - o, n) / dn
        let p = o + d * t - c
        return (t, SIMD2(dot(p, u), dot(p, v)) / size)
    }

    /// MSL ParticleFragment.
    struct Fragment: Equatable {
        var t: Float
        var alpha: Float
        var rgb: SIMD3<Float>
    }

    /// MSL particleOver.
    static func over(_ front: Fragment, _ back: Fragment) -> Fragment {
        Fragment(t: front.t, alpha: front.alpha + (1 - front.alpha) * back.alpha, rgb: front.rgb + (1 - front.alpha) * back.rgb)
    }

    /// MSL particleInsert: the k nearest sorted, the two farthest merged past that.
    static func insert(_ k: inout [Fragment], capacity: Int, _ f: Fragment) {
        if k.count == capacity && f.t >= k[capacity - 1].t {
            k[capacity - 1] = over(k[capacity - 1], f)
            return
        }
        let full = k.count == capacity
        let out = full ? k.removeLast() : nil
        let j = k.firstIndex { $0.t > f.t } ?? k.count
        k.insert(f, at: j)
        if let out { k[capacity - 1] = over(k[capacity - 1], out) }
    }

    /// The fragments front to back: rgb, and how much of what is behind they hide.
    static func composite(_ k: [Fragment]) -> SIMD4<Float> {
        var c = SIMD3<Float>.zero, transmit: Float = 1
        for f in k {
            c += transmit * f.rgb
            transmit *= 1 - f.alpha
        }
        return SIMD4(c, 1 - transmit)
    }
}
