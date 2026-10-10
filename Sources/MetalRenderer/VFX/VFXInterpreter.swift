import Foundation
import simd

/// The particles' step on the CPU, in the GPU's order (begin, emit, simulate): the reference ParticleTests and
/// VFXTests check the kernels against. The fixed emitters' maths (ParticleMath, Shaders/ParticleSim.metal's twin) and,
/// for an emitter with a program (VFXProgram), its graph's: the plans the program's Metal was written from, run on
/// the CPU. The same pool, dead lists and alive lists; the alive lists' order is the CPU's (the GPU's is whatever its
/// atomics give), so the two are compared as sets, by emitter and spawn id.
final class VFXInterpreter {
    let system: ParticleSystem
    private let emitters: [GPUParticleEmitter]
    private let colliders: [GPUParticleCollider]
    private let fields: [GPUParticleField]
    private let samples: [SIMD4<Float>]
    private(set) var particles: [GPUParticle] = []
    /// Each slot's attributes (ParticleSystem.attributeStride a slot).
    private(set) var attributes: [SIMD4<Float>] = []
    private(set) var deadList: [UInt32] = []
    private(set) var deadCount: [Int] = []
    private(set) var alive: [[UInt32]] = [[], []]
    /// Per parity, per emitter: the events its particles left.
    private(set) var events: [[[ParticleEvent]]] = []
    private(set) var emitted: [UInt32] = []
    private(set) var stepIndex = 0
    private let env = VFXEnv()

    init(_ system: ParticleSystem) {
        self.system = system
        emitters = system.gpuEmitters
        colliders = system.gpuColliders
        (fields, samples) = system.gpuFields
        env.fields = fields
        env.samples = samples
        reset()
    }

    func reset() {
        particles = Array(repeating: GPUParticle(), count: system.capacity)
        attributes = Array(repeating: .zero, count: system.capacity * system.attributeStride)
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
                if let program = system.programs[i], let r = program.rate {
                    want = Int(ParticleSystem.requests(e, s, curve: Array(program.params[r...])))
                } else {
                    want = Int(ParticleSystem.requests(e, s))
                }
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
                for k in 0..<system.attributeStride { attributes[Int(slot) * system.attributeStride + k] = .zero }
                if e.ids.z == ParticleSystem.none {
                    let id = first[i] &+ UInt32(j)
                    particles[Int(slot)] = spawn(i, e, slot: slot, seed: ParticleMath.seed(emitter: e.extra.w.bitPattern, spawn: id), spawn: id,
                                                 at: ParticleMath.xyz(e.origin), parentVelocity: .zero, s)
                } else {
                    let per = Int(e.ids2.x), ev = consumed[Int(e.ids.z)][j / per], k = UInt32(j % per)
                    particles[Int(slot)] = spawn(i, e, slot: slot, seed: ParticleMath.childSeed(parent: ev.seed, k: k), spawn: ev.spawn &* 8 &+ k,
                                                 at: ParticleMath.xyz(ev.a), parentVelocity: ParticleMath.xyz(ev.b), s)
                }
                alive[p].append(slot)
            }
        }
        // simulate
        var out: [UInt32] = []
        for slot in alive[p] {
            var q = particles[Int(slot)]
            let ei = Int(q.info.z), e = emitters[ei]
            let (keep, event): (Bool, Bool)
            if let program = system.programs[ei], program.hooks.contains(.step) {
                (keep, event) = step(program, &q, e, slot: slot, s)
            } else {
                (keep, event) = ParticleMath.step(&q, e, colliders, s, fields: fields, samples: samples)
            }
            if event && events[p][ei].count < Int(e.ids.y) {
                var ev = ParticleEvent(q)
                // A program's condition can hold for many steps: each step's children are seeded apart (MSL simulate).
                if let program = system.programs[ei], program.hooks.contains(.step) {
                    ev.a.w = Float(bitPattern: q.info.y ^ ParticleMath.hash(s.step &+ 0x2545F491))
                }
                events[p][ei].append(ev)
            }
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

    /// A particle's size (before the pose's widening) and colour (before emission) as the pose has them (MSL
    /// particlePoseKernel, and its program's look).
    func look(_ q: GPUParticle, slot: Int) -> (size: Float, color: SIMD4<Float>) {
        let ei = Int(q.info.z), e = emitters[ei]
        let x = min(max(q.position.w / max(q.velocity.w, 1e-6), 0), 1)
        var size = (e.size.x + (e.size.y - e.size.x) * x) * (1 - e.size.z * ParticleMath.random(q.info.y, 1))
        let m = min(max(e.look.x, 1e-4), 1 - 1e-4)
        var color = x < m ? e.color0 + (e.color1 - e.color0) * (x / m) : e.color1 + (e.color2 - e.color1) * ((x - m) / (1 - m))
        if let program = system.programs[ei], program.hooks.contains(.output) {
            load(program, slot: slot)
            env.x = ParticleMath.xyz(q.position)
            env.v = ParticleMath.xyz(q.velocity)
            env.age = q.position.w
            env.share = x
            env.life = q.velocity.w
            env.seed = q.info.y
            env.id = q.info.x
            env.time = Float(stepIndex) * ParticleSystem.stepLength
            env.dt = ParticleSystem.stepLength
            env.origin = ParticleMath.xyz(e.origin)
            if let s = program.outputPlan.size { size = s.f(env) * (1 - e.size.z * ParticleMath.random(q.info.y, 1)) }
            if let c = program.outputPlan.color { color = c.c(env) }
        }
        return (size, color)
    }

    // MARK: - Programs

    /// The env reads `program`'s parameters and slot `slot`'s attributes.
    private func load(_ program: VFXProgram, slot: UInt32) { load(program, slot: Int(slot)) }
    private func load(_ program: VFXProgram, slot: Int) {
        env.params = program.params
        let n = system.attributeStride
        env.attributes = n > 0 ? Array(attributes[(slot * n)..<(slot * n + n)]) : []
    }
    private func store(slot: UInt32) {
        let n = system.attributeStride
        for k in 0..<n { attributes[Int(slot) * n + k] = env.attributes[k] }
    }

    /// A newborn (MSL emit: particleSpawn, or the program's vfxSpawn).
    private func spawn(_ i: Int, _ e: GPUParticleEmitter, slot: UInt32, seed: UInt32, spawn: UInt32, at: SIMD3<Float>,
                       parentVelocity: SIMD3<Float>, _ s: GPUParticleStep) -> GPUParticle {
        guard let program = system.programs[i], program.hooks.contains(.spawn) else {
            return ParticleMath.spawn(e, emitter: UInt32(i), seed: seed, spawn: spawn, at: at, parentVelocity: parentVelocity, dt: s.dt)
        }
        var b = ParticleMath.birth(e, seed: seed, spawn: spawn, parentVelocity: parentVelocity, dt: s.dt)
        load(program, slot: slot)
        env.seed = seed
        env.id = spawn
        env.time = s.time
        env.dt = s.dt
        env.origin = ParticleMath.xyz(e.origin)
        env.age = 0
        env.share = 0
        for (op, expr) in program.initPlan.ops {
            env.x = at + b.offset
            env.v = b.v
            env.life = b.life
            switch op {
            case .lifetime: b.life = min(max(expr.f(env), 1e-4), e.life.y)
            case .position: b.offset = expr.v3(env)
            case .velocity: b.v = expr.v3(env)
            case .attribute(let k): env.attributes[k] = expr.c(env)
            }
        }
        store(slot: slot)
        return GPUParticle(position: SIMD4(at + b.offset + b.v * b.pre, b.pre), velocity: SIMD4(b.v, b.life),
                           info: SIMD4(spawn, seed, UInt32(i), ParticleSystem.alive))
    }

    /// A program's step (MSL vfxStepN; ParticleMath.step with the graph's shares, forces, velocities, attributes,
    /// kills and triggers).
    private func step(_ program: VFXProgram, _ p: inout GPUParticle, _ e: GPUParticleEmitter, slot: UInt32,
                      _ s: GPUParticleStep) -> (keep: Bool, event: Bool) {
        let plan = program.stepPlan
        let flags = ParticleEmitter.Flags(rawValue: e.ids.w)
        let age = p.position.w + s.dt
        if age >= p.velocity.w { return (false, flags.contains(.eventsOnDeath)) }
        load(program, slot: slot)
        env.x = ParticleMath.xyz(p.position)
        env.v = ParticleMath.xyz(p.velocity)
        env.age = age
        env.life = p.velocity.w
        env.share = age / max(p.velocity.w, 1e-6)
        env.seed = p.info.y
        env.id = p.info.x
        env.time = s.time
        env.dt = s.dt
        env.origin = ParticleMath.xyz(e.origin)
        var a = SIMD3<Float>(0, -s.gravity * (plan.gravity?.f(env) ?? e.forces.x), 0)
        let curl = plan.curl?.f(env) ?? e.forces.w
        if curl != 0 {
            if e.field.w >= 0 {
                let q = env.x * e.noise.x + SIMD3(0, s.wind.w * e.noise.y, 0)
                a += ParticleMath.field(fields[Int(e.field.w)], samples, q) * (e.noise.x * curl)
            } else {
                a += ParticleMath.curl(env.x, frequency: e.noise.x, time: s.wind.w * e.noise.y) * curl
            }
        }
        if e.field.x >= 0 && e.field.z == 0 {
            a += ParticleMath.field(fields[Int(e.field.x)], samples, env.x) * (plan.field?.f(env) ?? e.field.y)
        }
        let swirl = plan.swirl?.f(env) ?? e.noise.z, pull = plan.attraction?.f(env) ?? e.noise.w
        if swirl != 0 || pull != 0 {
            let r = env.x - ParticleMath.xyz(e.attractor), axis = ParticleMath.xyz(e.axis)
            let rp = r - axis * dot(r, axis), lp = length(rp), lr = length(r)
            if lp > 1e-4 { a += cross(axis, rp) * (swirl / lp) }
            if lr > 1e-4 { a -= r * (pull / lr) }
        }
        for force in plan.forces { a += force.v3(env) }
        env.v += a * s.dt
        let drag = plan.drag?.f(env) ?? e.forces.y
        if drag > 0 {
            let air = ParticleMath.xyz(s.wind) * (plan.wind?.f(env) ?? e.forces.z)
            env.v = air + (env.v - air) * exp(-drag * s.dt)
        }
        if e.field.x >= 0 && e.field.z != 0 {
            let air = ParticleMath.field(fields[Int(e.field.x)], samples, env.x)
            env.v = air + (env.v - air) * exp(-(plan.field?.f(env) ?? e.field.y) * s.dt)
        }
        for velocity in plan.velocities { env.v = velocity.v3(env) }
        env.x += env.v * s.dt
        var impact: Float = 0
        var x = env.x, v = env.v
        for (i, c) in colliders.enumerated() where (e.ids2.y >> UInt32(i)) & 1 != 0 {
            impact = max(impact, ParticleMath.collide(c, &x, &v, restitution: e.attractor.w, friction: e.lock.w, radius: e.extra.x))
        }
        env.x = x
        env.v = v
        p.position = SIMD4(x, age)
        p.velocity = SIMD4(v, p.velocity.w)
        for (k, value) in plan.attributes { env.attributes[k] = value.c(env) }
        store(slot: slot)
        let hit = impact > 0.3
        if hit && flags.contains(.killOnCollision) {
            return (false, flags.contains(.eventsOnCollision) || flags.contains(.eventsOnDeath))
        }
        var event = hit && flags.contains(.eventsOnCollision)
        for kill in plan.kills where kill.b(env) { return (false, flags.contains(.eventsOnDeath)) }
        for trigger in plan.triggers where trigger.b(env) { event = true }
        return (true, event)
    }
}
