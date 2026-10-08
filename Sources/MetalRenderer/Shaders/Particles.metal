// ---------------------------------------------------------------------------------------------
// Particle effects (Particles.swift, ParticlesGPU.swift): a fixed pool, a dead list per emitter, two alive lists
// ---------------------------------------------------------------------------------------------

// A step is three dispatches (ParticlesGPU.encodeSteps), ParticlesCPU's in its order:
//   begin     one SIMD group, a thread an emitter: what each asks for (its rate and bursts over the step, or its
//             parent's events), clamped to its dead count; its pops off its dead list; the indirect arguments.
//   emit      a thread a newborn: its slot off its emitter's dead list, its birth, its place in the alive list.
//   simulate  a thread an alive particle: aged, moved, collided; the dead pushed back on their emitter's dead list,
//             the rest appended to the other alive list (one atomic a SIMD group), which the next step reads.
// The CPU never reads a count: begin writes the emit and simulate dispatches' sizes. Pops need no atomics (begin
// knows each emitter's top and how many it takes); pushes and appends do, so the lists' order is the GPU's own, and
// a run differs from another only in which slot a particle has. What a particle is depends only on its emitter and
// spawn id (its seed), and a child's on its parent's.

constant uint PARTICLE_EMITTERS = 32;   // ParticleSystem.maxEmitters
constant uint PARTICLE_NONE = 0xFFFFFFFFu;
constant uint PARTICLE_ALIVE = 1;       // Particle.info.w

// ParticleEmitter.Flags (the low three in ParticleTrace.metal).
constant uint PARTICLE_KILL_ON_COLLISION = 1u << 8, PARTICLE_EVENTS_ON_DEATH = 1u << 9, PARTICLE_EVENTS_ON_COLLISION = 1u << 10;
constant uint PARTICLE_SCENE_COLLISIONS = 1u << 11;
constant uint PARTICLE_STEP_SCENE = 2u;   // ParticleStep.parity: the scene is bound (its collisions can run)

struct Particle {
    float4 position;   // w = age
    float4 velocity;   // w = lifetime
    uint4  info;       // spawn id, seed, emitter, flags
};
static_assert(sizeof(Particle) == 48, "Particle: GPUParticle");

struct ParticleEmitter {
    float4 origin;     // w = shape radius
    float4 axis;       // w = spread (rad)
    float4 extent;     // w = shape: 0 point, 1 sphere, 2 sphere's surface, 3 disc, 4 box, 5 ring
    float4 velocity;   // w = a child's share of its parent's
    float4 speed;      // min, max, radial, the step it starts at
    float4 life;       // min, max, particles a step, the step it stops at
    float4 burst;      // the step it bursts at, how many, every (steps), bursts
    float4 forces;     // gravity's share, drag, wind's share, curl noise
    float4 noise;      // curl frequency, curl scroll, vortex, attraction
    float4 attractor;  // w = restitution
    float4 size;       // radius at birth, at death, random shrink, stretch
    float4 color0, color1, color2;
    float4 look;       // color1's place, emitted light's scale, soft distance, most spin
    float4 flip;       // frames, fps (0: over the life), random first frame, trim
    float4 lock;       // axis or normal; w = friction
    uint4  ids;        // first slot, capacity, parent, flags
    uint4  ids2;       // children an event, colliders, orientation, atlas layer | shadow density x 255 << 8
};
static_assert(sizeof(ParticleEmitter) == 304, "ParticleEmitter: GPUParticleEmitter");

struct ParticleCollider {
    float4 a;          // plane: normal, offset; sphere: centre, radius; box: centre
    float4 b;          // box: half extents; w = kind (0 plane, 1 sphere, 2 box)
};
static_assert(sizeof(ParticleCollider) == 32, "ParticleCollider: GPUParticleCollider");

struct ParticleStep {
    float4 wind;       // the air's velocity; w = the curl noise's clock
    float  time, dt;
    uint   step, parity, emitters, colliders, capacity;
    float  gravity;
};
static_assert(sizeof(ParticleStep) == 48, "ParticleStep: GPUParticleStep");

// What a particle leaves its emitter's children: where, its seed (bits); its velocity, its spawn id (bits).
struct ParticleEvent {
    float4 a;
    float4 b;
};

// The pool's counters (ParticlesGPU.counts; the tests read them at these offsets).
struct ParticleCounts {
    atomic_uint alive[2];                       // the alive lists' lengths
    uint        emits;                          // this step's newborns
    uint        emitBase;                       // where they start in the alive list
    atomic_uint dead[PARTICLE_EMITTERS];        // each emitter's dead list's length
    atomic_uint events[2][PARTICLE_EMITTERS];   // per parity, each emitter's events
    uint        emitted[PARTICLE_EMITTERS];     // each emitter's spawn ids so far
    uint        spawnFirst[PARTICLE_EMITTERS];  // this step's first
    uint        emitFirst[PARTICLE_EMITTERS];   // where its newborns start among this step's
    uint        emitCount[PARTICLE_EMITTERS];
    uint        deadTop[PARTICLE_EMITTERS];     // its dead list's length before this step's pops
};
static_assert(sizeof(ParticleCounts) == 1040, "ParticleCounts: ParticlesGPU.countsSize");

// MARK: - The maths (ParticleMath in ParticlesCPU.swift, line for line)

inline uint particleSeed(uint emitter, uint spawn) { return pcgHash(spawn + pcgHash(emitter * 0x9E3779B9u + 0x7F4A7C15u)); }
inline uint particleChildSeed(uint parent, uint k) { return pcgHash(parent ^ pcgHash(k + 0x632BE5ABu)); }

// An orthonormal basis about unit n (Duff et al. 2017).
inline void particleBasis(float3 n, thread float3& t, thread float3& b) {
    float sign = n.z >= 0.0f ? 1.0f : -1.0f;
    float a = -1.0f / (sign + n.z), c = n.x * n.y * a;
    t = float3(1.0f + sign * n.x * n.x * a, sign * c, -sign * n.x);
    b = float3(c, sign + n.y * n.y * a, -n.y);
}

inline float3 particleGradient(int3 i, uint salt) {
    uint h = pcgHash(as_type<uint>(i.x) + pcgHash(as_type<uint>(i.y) + pcgHash(as_type<uint>(i.z) + salt)));
    return float3(float(h & 1023u), float((h >> 10) & 1023u), float((h >> 20) & 1023u)) * (1.0f / 511.5f) - 1.0f;
}

// Gradient noise and its analytic derivatives (quintic; Quilez's "noised"): x = value, yzw = gradient.
inline float4 particleNoise(float3 x, uint salt) {
    float3 i = floor(x), f = x - i;
    float3 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float3 du = 30.0f * f * f * (f * (f - 2.0f) + 1.0f);
    int3 c = int3(i);
    float3 ga = particleGradient(c, salt), gb = particleGradient(c + int3(1, 0, 0), salt);
    float3 gc = particleGradient(c + int3(0, 1, 0), salt), gd = particleGradient(c + int3(1, 1, 0), salt);
    float3 ge = particleGradient(c + int3(0, 0, 1), salt), gf = particleGradient(c + int3(1, 0, 1), salt);
    float3 gg = particleGradient(c + int3(0, 1, 1), salt), gh = particleGradient(c + int3(1, 1, 1), salt);
    float va = dot(ga, f), vb = dot(gb, f - float3(1, 0, 0)), vc = dot(gc, f - float3(0, 1, 0)), vd = dot(gd, f - float3(1, 1, 0));
    float ve = dot(ge, f - float3(0, 0, 1)), vf = dot(gf, f - float3(1, 0, 1)), vg = dot(gg, f - float3(0, 1, 1)), vh = dot(gh, f - float3(1, 1, 1));
    float k0 = va - vb - vc + vd, k1 = va - vc - ve + vg, k2 = va - vb - ve + vf, k3 = -va + vb + vc - vd + ve - vf - vg + vh;
    float value = va + u.x * (vb - va) + u.y * (vc - va) + u.z * (ve - va) + u.x * u.y * k0 + u.y * u.z * k1 + u.z * u.x * k2
        + u.x * u.y * u.z * k3;
    float3 g = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.z * (ge - ga);
    g += u.x * u.y * (ga - gb - gc + gd) + u.y * u.z * (ga - gc - ge + gg) + u.z * u.x * (ga - gb - ge + gf);
    g += u.x * u.y * u.z * (-ga + gb + gc - gd + ge - gf - gg + gh);
    g += du * (float3(vb, vc, ve) - va + u.yzx * float3(k0, k1, k2) + u.zxy * float3(k2, k0, k1) + u.yzx * u.zxy * k3);
    return float4(value, g);
}

// The curl of three noise channels taken as a vector potential: a divergence-free velocity field of about unit size.
inline float3 particleCurl(float3 p, float frequency, float time) {
    float3 q = p * frequency + float3(0.0f, time, 0.0f);
    float4 x = particleNoise(q, 0x1B873593u), y = particleNoise(q + float3(31.416f, 47.853f, 12.679f), 0xCC9E2D51u);
    float4 z = particleNoise(q + float3(-23.137f, 11.719f, 59.311f), 0xE6546B64u);
    return float3(z.z - y.w, x.w - z.y, y.y - x.z) * frequency;
}

// A count of births in steps, floored: a whole number computed with rounding (k steps x a rate a step) stays whole.
inline float particleFloor(float x) { return floor(x + 1e-3f + x * 2e-7f); }

// What a root emitter asks for over the step: its rate's births by the step's end less those by its start (counted
// from where it starts, so a fraction carries to the next step), and the bursts that fall in it. In steps: a time in
// seconds would round to the step before or after its own.
inline uint particleRequests(ParticleEmitter e, constant ParticleStep& s) {
    float k = float(s.step);
    float n = 0.0f;
    if (e.life.z > 0.0f) {
        float span = max(e.life.w - e.speed.w, 0.0f);
        float a = clamp(k - e.speed.w, 0.0f, span), b = clamp(k + 1.0f - e.speed.w, 0.0f, span);
        n += particleFloor(b * e.life.z) - particleFloor(a * e.life.z);
    }
    if (e.burst.y > 0.0f) {
        if (e.burst.z > 0.0f) {
            float first = ceil((k - e.burst.x - 1e-3f) / e.burst.z), end = ceil((k + 1.0f - e.burst.x - 1e-3f) / e.burst.z);
            first = max(first, 0.0f);
            if (e.burst.w > 0.0f) end = min(end, e.burst.w);
            n += max(end - first, 0.0f) * e.burst.y;
        } else if (floor(e.burst.x + 1e-3f) == k) {
            n += e.burst.y;
        }
    }
    return uint(max(n, 0.0f));
}

// A newborn: born somewhere in the step (moved and aged by a random share of it).
inline Particle particleSpawn(ParticleEmitter e, uint emitter, uint seed, uint spawn, float3 at, float3 parentVelocity, float dt) {
    Rng r;
    r.state = seed;
    float u0 = r.next(), u1 = r.next(), u2 = r.next(), u3 = r.next(), u4 = r.next(), u5 = r.next(), u6 = r.next(), u7 = r.next();
    float3 axis = e.axis.xyz, t, b;
    particleBasis(axis, t, b);
    float shape = e.extent.w, radius = e.origin.w;
    float3 offset = float3(0.0f);
    if (shape == 1.0f || shape == 2.0f) {
        float z = 2.0f * u0 - 1.0f, phi = 2.0f * M_PI_F * u1, s = sqrt(max(1.0f - z * z, 0.0f));
        float3 d = float3(s * cos(phi), s * sin(phi), z);
        offset = d * (shape == 2.0f ? radius : radius * pow(u2, 1.0f / 3.0f));
    } else if (shape == 3.0f) {
        float rr = radius * sqrt(u0), phi = 2.0f * M_PI_F * u1;
        offset = t * (rr * cos(phi)) + b * (rr * sin(phi));
    } else if (shape == 4.0f) {
        offset = (float3(u0, u1, u2) * 2.0f - 1.0f) * e.extent.xyz;
    } else if (shape == 5.0f) {
        // Spaced by spawn id along the golden ratio, so any number of them spread round it evenly.
        float g = float(spawn % 4096u) * 0.618034f + u1 * 0.05f;
        float phi = 2.0f * M_PI_F * (g - floor(g));
        offset = t * (radius * cos(phi)) + b * (radius * sin(phi));
    }
    float3 dir;
    if (e.speed.z > 0.0f) {
        float l = length(offset);
        dir = l > 1e-6f ? offset / l : axis;
    } else {
        float cosT = 1.0f - u3 * (1.0f - cos(e.axis.w)), sinT = sqrt(max(1.0f - cosT * cosT, 0.0f)), phi = 2.0f * M_PI_F * u4;
        dir = axis * cosT + (t * cos(phi) + b * sin(phi)) * sinT;
    }
    float speed = e.speed.x + (e.speed.y - e.speed.x) * u5;
    float3 v = dir * speed + e.velocity.xyz + parentVelocity * e.velocity.w;
    float life = e.life.x + (e.life.y - e.life.x) * u6;
    float pre = u7 * dt;
    Particle p;
    p.position = float4(at + offset + v * pre, pre);
    p.velocity = float4(v, life);
    p.info = uint4(spawn, seed, emitter, PARTICLE_ALIVE);
    return p;
}

// Pushes x out of collider c and bounces v off it: the speed it hit at (0: it didn't).
inline float particleCollide(ParticleCollider c, thread float3& x, thread float3& v, float restitution, float friction) {
    float3 n = float3(0.0f);
    bool inside = false;
    if (c.b.w == 0.0f) {
        n = c.a.xyz;
        float d = dot(n, x) - c.a.w;
        if (d < 0.0f) { x -= n * d; inside = true; }
    } else if (c.b.w == 1.0f) {
        float3 q = x - c.a.xyz;
        float l = length(q);
        if (l < c.a.w && l > 1e-6f) { n = q / l; x = c.a.xyz + n * c.a.w; inside = true; }
    } else {
        float3 q = x - c.a.xyz, o = abs(q) - c.b.xyz;
        if (o.x < 0.0f && o.y < 0.0f && o.z < 0.0f) {
            uint k = o.x > o.y ? (o.x > o.z ? 0u : 2u) : (o.y > o.z ? 1u : 2u);
            float s = q[k] >= 0.0f ? 1.0f : -1.0f;
            n[k] = s;
            x[k] = c.a[k] + s * c.b[k];
            inside = true;
        }
    }
    if (!inside) return 0.0f;
    float vn = dot(v, n);
    if (vn >= 0.0f) return 0.0f;
    v = (v - n * vn) * (1.0f - friction) - n * (vn * restitution);
    return -vn;
}

// A particle's step: aged, then (if it lives) the forces, the drag toward the air, semi-implicit Euler, the
// colliders. True if it lives on; `event`: it leaves its children an event.
// The geometry particle p's step crossed (`from` to x): pushed back out to its near side and bounced off it (by its
// triangle's normal), as particleCollide does. A ray along the step finds it, so it is exact, off screen too (the
// chat's depth-buffer collision without the depth buffer's blind spots).
inline float particleCollideScene(float3 from, thread float3& x, thread float3& v, float restitution, float friction,
                                  SCENE_ACCEL sc, thread const SceneData& sd) {
    float3 d = x - from;
    float len = length(d);
    if (len < 1e-6f) return 0.0f;
    Surface h = traceSurface(makeRay(from, d / len, 0.0f, len + 1e-3f), rayMask(MASK_GEOMETRY, RAY_SHADOW), sc, sd, GI_RAY_SPREAD);
    if (!h.hit) return 0.0f;
    float3 n = normalize(h.geomNormal);
    if (dot(n, d) > 0.0f) n = -n;
    x = h.position + n * 2e-3f;
    float vn = dot(v, n);
    if (vn >= 0.0f) return 0.0f;
    v = (v - n * vn) * (1.0f - friction) - n * (vn * restitution);
    return -vn;
}

inline bool particleStep(thread Particle& p, ParticleEmitter e, device const ParticleCollider* colliders, constant ParticleStep& s,
                         SCENE_ACCEL sc, thread const SceneData& sd, thread bool& event) {
    uint flags = e.ids.w;
    float age = p.position.w + s.dt;
    if (age >= p.velocity.w) { event = (flags & PARTICLE_EVENTS_ON_DEATH) != 0; return false; }
    float3 x = p.position.xyz, v = p.velocity.xyz;
    float3 a = float3(0.0f, -s.gravity * e.forces.x, 0.0f);
    if (e.forces.w != 0.0f) a += particleCurl(x, e.noise.x, s.wind.w * e.noise.y) * e.forces.w;
    if (e.noise.z != 0.0f || e.noise.w != 0.0f) {
        float3 r = x - e.attractor.xyz, axis = e.axis.xyz;
        float3 rp = r - axis * dot(r, axis);
        float lp = length(rp), lr = length(r);
        if (lp > 1e-4f) a += cross(axis, rp) * (e.noise.z / lp);
        if (lr > 1e-4f) a -= r * (e.noise.w / lr);
    }
    v += a * s.dt;
    if (e.forces.y > 0.0f) {
        float3 air = s.wind.xyz * e.forces.z;
        v = air + (v - air) * exp(-e.forces.y * s.dt);
    }
    float3 from = x;
    x += v * s.dt;
    float impact = 0.0f;
    if ((flags & PARTICLE_SCENE_COLLISIONS) != 0u && (s.parity & PARTICLE_STEP_SCENE) != 0u) {
        impact = particleCollideScene(from, x, v, e.attractor.w, e.lock.w, sc, sd);
    }
    for (uint i = 0; i < s.colliders; ++i) {
        if (((e.ids2.y >> i) & 1u) == 0u) continue;
        impact = max(impact, particleCollide(colliders[i], x, v, e.attractor.w, e.lock.w));
    }
    p.position = float4(x, age);
    p.velocity = float4(v, p.velocity.w);
    bool hit = impact > 0.3f;   // a touch, not a particle at rest on it
    if (hit && (flags & PARTICLE_KILL_ON_COLLISION) != 0) {
        event = (flags & (PARTICLE_EVENTS_ON_COLLISION | PARTICLE_EVENTS_ON_DEATH)) != 0;
        return false;
    }
    event = hit && (flags & PARTICLE_EVENTS_ON_COLLISION) != 0;
    return true;
}

// MARK: - The step's kernels

// Every slot free (on its emitter's dead list), nothing alive, no events, no spawn ids used. A thread a slot.
kernel void particleResetKernel(constant ParticleStep&          s         [[buffer(0)]],
                                device const ParticleEmitter*   emitters  [[buffer(13)]],
                                device ParticleCounts&          c         [[buffer(14)]],
                                device Particle*                particles [[buffer(16)]],
                                device uint*                    deadList  [[buffer(17)]],
                                uint i [[thread_position_in_grid]])
{
    if (i < s.capacity) {
        deadList[i] = i;
        particles[i].info = uint4(0u);
    }
    if (i < PARTICLE_EMITTERS) {
        atomic_store_explicit(&c.dead[i], i < s.emitters ? emitters[i].ids.y : 0u, memory_order_relaxed);
        atomic_store_explicit(&c.events[0][i], 0u, memory_order_relaxed);
        atomic_store_explicit(&c.events[1][i], 0u, memory_order_relaxed);
        c.emitted[i] = 0u;
    }
    if (i == 0) {
        atomic_store_explicit(&c.alive[0], 0u, memory_order_relaxed);
        atomic_store_explicit(&c.alive[1], 0u, memory_order_relaxed);
        c.emits = 0u;
    }
}

// One SIMD group, a thread an emitter.
kernel void particleBeginKernel(constant ParticleStep&          s         [[buffer(0)]],
                                device const ParticleEmitter*   emitters  [[buffer(13)]],
                                device ParticleCounts&          c         [[buffer(14)]],
                                device uint*                    args      [[buffer(15)]],
                                uint e [[thread_position_in_grid]])
{
    uint p = s.parity & 1u, n = 0u;
    if (e < s.emitters) {
        ParticleEmitter em = emitters[e];
        uint want;
        if (em.ids.z == PARTICLE_NONE) {
            want = particleRequests(em, s);
        } else {
            uint events = min(atomic_load_explicit(&c.events[1u - p][em.ids.z], memory_order_relaxed), emitters[em.ids.z].ids.y);
            want = events * em.ids2.x;
        }
        uint dead = atomic_load_explicit(&c.dead[e], memory_order_relaxed);
        n = min(want, dead);
        c.deadTop[e] = dead;
        atomic_store_explicit(&c.dead[e], dead - n, memory_order_relaxed);
        c.emitCount[e] = n;
        c.spawnFirst[e] = c.emitted[e];
        c.emitted[e] += n;
    }
    uint first = simd_prefix_exclusive_sum(n), total = simd_sum(n);
    if (e < s.emitters) c.emitFirst[e] = first;
    if (e < PARTICLE_EMITTERS) atomic_store_explicit(&c.events[p][e], 0u, memory_order_relaxed);   // this step's, from none
    if (e == 0u) {
        uint in = atomic_load_explicit(&c.alive[p], memory_order_relaxed);
        c.emitBase = in;
        c.emits = total;
        atomic_store_explicit(&c.alive[p], in + total, memory_order_relaxed);
        atomic_store_explicit(&c.alive[1u - p], 0u, memory_order_relaxed);
        args[0] = (total + 63u) / 64u; args[1] = 1u; args[2] = 1u;            // emit
        args[4] = (in + total + 63u) / 64u; args[5] = 1u; args[6] = 1u;       // simulate
    }
}

kernel void particleEmitKernel(constant ParticleStep&          s         [[buffer(0)]],
                               device const ParticleEmitter*   emitters  [[buffer(13)]],
                               device ParticleCounts&          c         [[buffer(14)]],
                               device Particle*                particles [[buffer(16)]],
                               device const uint*              deadList  [[buffer(17)]],
                               device uint*                    alive0    [[buffer(18)]],
                               device uint*                    alive1    [[buffer(19)]],
                               device const ParticleEvent*     events0   [[buffer(20)]],
                               device const ParticleEvent*     events1   [[buffer(21)]],
                               uint i [[thread_position_in_grid]])
{
    if (i >= c.emits) return;
    uint e = 0u;
    for (uint k = 0; k < s.emitters; ++k) {
        if (i >= c.emitFirst[k] && i < c.emitFirst[k] + c.emitCount[k]) { e = k; break; }
    }
    ParticleEmitter em = emitters[e];
    uint j = i - c.emitFirst[e];
    uint slot = deadList[em.ids.x + c.deadTop[e] - 1u - j];
    Particle q;
    if (em.ids.z == PARTICLE_NONE) {
        uint id = c.spawnFirst[e] + j;
        q = particleSpawn(em, e, particleSeed(e, id), id, em.origin.xyz, float3(0.0f), s.dt);
    } else {
        uint per = em.ids2.x, k = j % per;
        ParticleEvent ev = ((s.parity & 1u) == 0u ? events1 : events0)[emitters[em.ids.z].ids.x + j / per];
        q = particleSpawn(em, e, particleChildSeed(as_type<uint>(ev.a.w), k), as_type<uint>(ev.b.w) * 8u + k, ev.a.xyz, ev.b.xyz, s.dt);
    }
    particles[slot] = q;
    ((s.parity & 1u) == 0u ? alive0 : alive1)[c.emitBase + i] = slot;
}

kernel void particleSimulateKernel(constant ParticleStep&          s         [[buffer(0)]],
                                   device const ParticleEmitter*   emitters  [[buffer(13)]],
                                   device ParticleCounts&          c         [[buffer(14)]],
                                   device Particle*                particles [[buffer(16)]],
                                   device uint*                    deadList  [[buffer(17)]],
                                   device uint*                    alive0    [[buffer(18)]],
                                   device uint*                    alive1    [[buffer(19)]],
                                   device ParticleEvent*           events0   [[buffer(20)]],
                                   device ParticleEvent*           events1   [[buffer(21)]],
                                   device const ParticleCollider*  colliders [[buffer(22)]],
                                   SCENE_ACCEL                     sc        [[buffer(1)]],   // with PARTICLE_STEP_SCENE
                                   device const float3*            positions [[buffer(2)]],
                                   device const float3*            normals   [[buffer(3)]],
                                   device const uint*              indices   [[buffer(4)]],
                                   device const MeshData*          meshes    [[buffer(5)]],
                                   device const InstanceData*      instances [[buffer(6)]],
                                   constant SceneShading&          shading   [[buffer(7)]],
                                   device const Light*             lights    [[buffer(8)]],
                                   uint i [[thread_position_in_grid]])
{
    // (Built only with the scene bound: it reads the shading's buffer.)
    SceneData sd;
    if ((s.parity & PARTICLE_STEP_SCENE) != 0u) sd = sceneData(positions, normals, indices, meshes, instances, shading, lights, 0u);
    uint p = s.parity & 1u;
    uint count = atomic_load_explicit(&c.alive[p], memory_order_relaxed);
    uint slot = 0u;
    bool keep = false;
    if (i < count) {
        slot = (p == 0u ? alive0 : alive1)[i];
        Particle q = particles[slot];
        uint e = q.info.z;
        ParticleEmitter em = emitters[e];
        bool event = false;
        keep = particleStep(q, em, colliders, s, sc, sd, event);
        if (event) {
            uint k = atomic_fetch_add_explicit(&c.events[p][e], 1u, memory_order_relaxed);
            if (k < em.ids.y) {
                ParticleEvent ev;
                ev.a = float4(q.position.xyz, as_type<float>(q.info.y));
                ev.b = float4(q.velocity.xyz, as_type<float>(q.info.x));
                (p == 0u ? events0 : events1)[em.ids.x + k] = ev;
            }
        }
        if (keep) {
            particles[slot] = q;
        } else {
            particles[slot].info.w = 0u;
            uint d = atomic_fetch_add_explicit(&c.dead[e], 1u, memory_order_relaxed);
            deadList[em.ids.x + d] = slot;
        }
    }
    // The survivors onto the other list: one atomic a SIMD group.
    uint mine = keep ? 1u : 0u;
    uint before = simd_prefix_exclusive_sum(mine), total = simd_sum(mine);
    uint base = 0u;
    if (simd_is_first() && total > 0u) base = atomic_fetch_add_explicit(&c.alive[1u - p], total, memory_order_relaxed);
    base = simd_broadcast_first(base);
    if (keep) (p == 0u ? alive1 : alive0)[base + before] = slot;
}

// MARK: - What the rays meet

// A particle's colour at `x` of its life: three keys, the middle one at look.x.
inline float4 particleColor(ParticleEmitter e, float x) {
    float m = clamp(e.look.x, 1e-4f, 1.0f - 1e-4f);
    return x < m ? mix(e.color0, e.color1, x / m) : mix(e.color1, e.color2, (x - m) / (1.0f - m));
}

// A random number of particle `seed`'s, for what stays the same over its life (`k`: which).
inline float particleRandom(uint seed, uint k) { return float(pcgHash(seed ^ (k * 0x9E3779B9u + 0x85EBCA6Bu))) * (1.0f / 4294967296.0f); }

// Every slot's record and box for this frame's structure (`render`, `boxes`: the frame slot's): a thread a slot. A
// dead slot is a box far away that holds nothing.
kernel void particlePoseKernel(constant ParticleStep&          s         [[buffer(0)]],
                               device const ParticleEmitter*   emitters  [[buffer(13)]],
                               device const Particle*          particles [[buffer(16)]],
                               device ParticleRender*          render    [[buffer(23)]],
                               device float*                   boxes     [[buffer(24)]],
                               uint i [[thread_position_in_grid]])
{
    if (i >= s.capacity) return;
    Particle q = particles[i];
    ParticleRender r;
    r.centerRadius = float4(0.0f);
    r.axis = float4(0.0f);
    r.color = half4(0.0h);
    r.radiance = half4(1.0h);
    r.info = uint4(0u);
    float3 lo = float3(1.0e30f), hi = float3(1.0e30f);
    if ((q.info.w & PARTICLE_ALIVE) != 0u) {
        ParticleEmitter e = emitters[min(q.info.z, s.emitters - 1u)];
        uint seed = q.info.y, flags = e.ids.w, orient = e.ids2.z;
        float x = saturate(q.position.w / max(q.velocity.w, 1e-6f));
        float size = mix(e.size.x, e.size.y, x) * (1.0f - e.size.z * particleRandom(seed, 1u));
        float4 color = particleColor(e, x);
        if ((flags & PARTICLE_EMISSIVE) != 0u) color.rgb *= e.look.y;
        float spin = particleRandom(seed, 2u) * 2.0f * M_PI_F + (particleRandom(seed, 3u) * 2.0f - 1.0f) * e.look.w * q.position.w;
        float3 c = q.position.xyz, reach = float3(size * e.flip.w);
        float4 axis = float4(0.0f, 0.0f, 0.0f, spin);
        if (orient == 1u) {
            float3 v = q.velocity.xyz;
            float speed = length(v);
            float3 dir = speed > 1e-4f ? v / speed : e.axis.xyz;
            float h = size + speed * e.size.w;
            axis.xyz = dir * h;
            reach = abs(dir) * h + size;
        } else if (orient == 2u) {
            axis.xyz = e.lock.xyz * size;
            reach = abs(e.lock.xyz) * size + size;
        } else if (orient == 3u) {
            axis.xyz = e.lock.xyz;
        }
        // The flipbook's frame: over its life, or `fps` a second looping; from a random one if asked.
        float n = e.flip.x;
        float start = e.flip.z > 0.0f ? floor(particleRandom(seed, 4u) * n) : 0.0f;
        float f;
        uint f0, f1;
        if (e.flip.y > 0.0f) {
            f = fmod(start + q.position.w * e.flip.y, n);
            f0 = min(uint(f), uint(n) - 1u);
            f1 = (f0 + 1u) % uint(n);
        } else {
            f = min(x * n, n - 1.0f);
            f = fmod(f + start, n);
            f0 = min(uint(f), uint(n) - 1u);
            f1 = min(f0 + 1u, uint(n) - 1u);
        }
        uint blend = uint(saturate(f - float(f0)) * 65535.0f);
        r.centerRadius = float4(c, size);
        r.axis = axis;
        r.color = half4(min(color, 65000.0f));
        r.info = uint4(q.info.z | (e.ids2.w & 0xFFu) << 16 | ((flags & 7u) | orient << 3) << 24,
                       f0 | f1 << 6 | blend << 12, as_type<uint>(half2(half(e.look.z), half(float((e.ids2.w >> 8) & 0xFFu) / 255.0f))), seed);
        lo = c - reach;
        hi = c + reach;
    }
    render[i] = r;
    device float* b = boxes + 6 * i;
    b[0] = lo.x; b[1] = lo.y; b[2] = lo.z;
    b[3] = hi.x; b[4] = hi.y; b[5] = hi.z;
}

// MARK: - Light

// The light a lit particle scatters, once per particle per frame (rays per pixel would cost far more): from each of
// the first lights (PARTICLE_LIGHTS), scattered isotropically (E / 4 pi per unit albedo, as the path tracer's
// particles do), its visibility the opaque scene's and the particles' transmittance between (so smoke shades
// itself), plus the sky's mean (what an isotropic scatterer sends in a uniform sky). Averaged
// over the frames (the shadow rays aim at random points of the lights): each frame weighs in at a third, a newborn's
// first frame alone. `lighting`: per slot that average (rgb) and whose it is (w: the particle's seed).
constant uint PARTICLE_LIGHTS = 8;

kernel void particleLightKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      accel      [[buffer(1)]],
                                device const float3*             positions  [[buffer(2)]],
                                device const float3*             normals    [[buffer(3)]],
                                device const uint*               indices    [[buffer(4)]],
                                device const MeshData*           meshes     [[buffer(5)]],
                                device const InstanceData*       instances  [[buffer(6)]],
                                constant SceneShading&           shading    [[buffer(7)]],
                                device const Light*              lights     [[buffer(8)]],
                                device ParticleRender*           render     [[buffer(13)]],
                                device float4*                   lighting   [[buffer(14)]],
                                constant uint&                   capacity   [[buffer(15)]],
                                uint i [[thread_position_in_grid]])
{
    if (i >= capacity) return;
    ParticleRender r = render[i];
    if (r.centerRadius.w <= 0.0f || (particleFlags(r) & PARTICLE_EMISSIVE) != 0u) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    float3 p = r.centerRadius.xyz;
    float3 sum = skyAmbient(u, s);
    Rng rng;
    rng.state = pcgHash(r.info.w ^ pcgHash(u.frameIndex * 0x9E3779B9u + 0x2545F491u));
    uint count = LIGHT_TABLE ? 0u : min(u.lightCount, PARTICLE_LIGHTS);
    for (uint l = 0; l < count; ++l) {
        Light light = lights[l];
        float3 toward = lightType(light) == LIGHT_SUN ? light.axis.xyz : normalize(light.positionRadius.xyz - p);
        float3 e = lightUnshadowed(light, p, toward, toward);
        if (all(e <= 0.0f)) continue;
        float3 target = lightShadowTarget(light, p, rng.next2());
        float3 d = target - p;
        float dist = length(d);
        float t;
        if (intersectAny(makeRay(p, d / dist, RAY_EPSILON, max(dist - RAY_EPSILON, 0.0f)), rayMask(MASK_GEOMETRY, RAY_SHADOW), accel, t)) continue;
        // lightUnshadowed facing the light is its irradiance / pi: a quarter of it is E / 4 pi.
        sum += 0.25f * e * particleTransmittance(p, d / dist, r.centerRadius.w * 0.5f, dist, accel) * sunVisibilityScale(light, p, s);
    }
    float4 last = lighting[i];
    float3 now = as_type<uint>(last.w) == r.info.w ? mix(last.rgb, sum, 1.0f / 3.0f) : sum;
    lighting[i] = float4(now, as_type<float>(r.info.w));
    render[i].radiance = half4(half3(min(now, 65000.0f)), 1.0h);
}

// MARK: - The camera's layer

// The particles in front of what the camera's ray hit: rgb = the light they send (fogged), a = how much of what is
// behind them they hide. Soft where they near the surface behind them, and faded right in front of the camera. The
// composite puts it over the scene (or MetalFX does, as its transparency overlay).
kernel void particleLayerKernel(constant Uniforms&               u        [[buffer(0)]],
                                SCENE_ACCEL                      sc       [[buffer(1)]],
                                constant FogParams&              fog      [[buffer(9)]],
                                texture2d<float, access::read>   nd       [[texture(0)]],
                                texture2d<float, access::write>  layer    [[texture(1)]],
                                texture3d<float>                 fogGrid  [[texture(2)]],
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float3 dir = primaryDirection(u, tid), o = u.camPos.xyz;
    float depth = nd.read(tid).w, along = dot(dir, u.camForward.xyz);
    float tOpaque = depth > 0.0f ? depth / max(along, 1e-4f) : 1.0e5f;
    float meanT;
    float4 gathered = particleGather<4>(o, dir, tOpaque, depth > 0.0f, sc, meanT);
    float3 c = gathered.rgb;
    float hidden = gathered.a;
    if (hidden > 1e-4f && flagOn(u.flags, FLAG_FOG) && !flagOn(u.flags, FLAG_FOG_REFERENCE)) {
        // The fog in front of them, at their mean distance: what they send dims, and the fog's own light takes the
        // share of the view they hide (the composite fogs the rest to the surface).
        float tMean = meanT / hidden;
        float2 uv = (float2(tid) + 0.5f) / float2(u.width, u.height);
        float4 fogged = fogFromGrid(fog, fogGrid, uv, tMean * along);
        c = c * fogged.a + hidden * fogged.rgb;
    }
    layer.write(float4(c, hidden), tid);
}
