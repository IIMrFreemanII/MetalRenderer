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
    uint4  ids3;       // a mesh emitter's first instance (PARTICLE_NONE: billboards), a trail's places (0: none), its
                       // first trail, steps between its places
    float4 extra;      // collision radius, a trail's width (of the particle's)
    float4 field;      // its vector field (-1: none), strength, 1: a velocity it follows, the baked curl's field (-1: none)
};
static_assert(sizeof(ParticleEmitter) == 352, "ParticleEmitter: GPUParticleEmitter");

// A vector field (ParticleField): its nodes from dims.w in the fields' samples.
struct ParticleFieldInfo {
    float4 lo;         // the box's corner; w = 1: periodic (a tile, the size its period)
    float4 size;
    uint4  dims;       // nodes along x, y, z; where they start
};
static_assert(sizeof(ParticleFieldInfo) == 48, "ParticleFieldInfo: GPUParticleField");

struct ParticleCollider {
    float4 a;          // plane: normal, offset; sphere: centre, radius; box: centre
    float4 b;          // box: half extents; w = kind (0 plane, 1 sphere, 2 box, 3 an SDF shape's instance: a.x its
                       // instance, a.y its shape, as uints)
};
static_assert(sizeof(ParticleCollider) == 32, "ParticleCollider: GPUParticleCollider");

struct ParticleStep {
    float4 wind;       // the air's velocity; w = the curl noise's clock
    float  time, dt;
    uint   step, parity, emitters, colliders, capacity;
    float  gravity;
    uint   casters, casterBound, othersBound, pose;   // the pose's (GPUParticleStep); its wind: the camera's position and
                                                      // how far its billboards widen a unit away
};
static_assert(sizeof(ParticleStep) == 64, "ParticleStep: GPUParticleStep");

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
    atomic_uint posed[2][2];                    // per pose parity, the casters' and the others' posed so far
};
static_assert(sizeof(ParticleCounts) == 1056, "ParticleCounts: ParticlesGPU.countsSize");

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

// Field f at p (trilinear between its nodes; outside its box nothing, unless it tiles). ParticleMath.field.
inline float3 particleField(ParticleFieldInfo f, device const float4* samples, float3 p) {
    int3 n = int3(f.dims.xyz);
    bool periodic = f.lo.w > 0.0f;
    float3 nf = float3(n), steps = periodic ? nf : nf - 1.0f;
    float3 g = (p - f.lo.xyz) / f.size.xyz * steps;
    if (periodic) {
        g = g - floor(g / nf) * nf;
    } else if (any(g < 0.0f) || any(g > steps)) {
        return float3(0.0f);
    }
    int3 i0 = min(int3(floor(g)), periodic ? n - 1 : n - 2);
    float3 t = g - float3(i0);
    int3 i1 = periodic ? (i0 + 1) % n : i0 + 1;
    device const float4* c = samples + f.dims.w;
    #define PARTICLE_AT(I, J, K) c[((K) * n.y + (J)) * n.x + (I)].xyz
    float3 c00 = PARTICLE_AT(i0.x, i0.y, i0.z) + (PARTICLE_AT(i1.x, i0.y, i0.z) - PARTICLE_AT(i0.x, i0.y, i0.z)) * t.x;
    float3 c10 = PARTICLE_AT(i0.x, i1.y, i0.z) + (PARTICLE_AT(i1.x, i1.y, i0.z) - PARTICLE_AT(i0.x, i1.y, i0.z)) * t.x;
    float3 c01 = PARTICLE_AT(i0.x, i0.y, i1.z) + (PARTICLE_AT(i1.x, i0.y, i1.z) - PARTICLE_AT(i0.x, i0.y, i1.z)) * t.x;
    float3 c11 = PARTICLE_AT(i0.x, i1.y, i1.z) + (PARTICLE_AT(i1.x, i1.y, i1.z) - PARTICLE_AT(i0.x, i1.y, i1.z)) * t.x;
    #undef PARTICLE_AT
    float3 c0 = c00 + (c10 - c00) * t.y, c1 = c01 + (c11 - c01) * t.y;
    return c0 + (c1 - c0) * t.z;
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

// Pushes a ball of `radius` at x out of collider c and bounces v off it: the speed it hit at (0: it didn't).
inline float particleCollide(ParticleCollider c, thread float3& x, thread float3& v, float restitution, float friction, float radius) {
    float3 n = float3(0.0f);
    bool inside = false;
    if (c.b.w == 0.0f) {
        n = c.a.xyz;
        float d = dot(n, x) - c.a.w - radius;
        if (d < 0.0f) { x -= n * d; inside = true; }
    } else if (c.b.w == 1.0f) {
        float3 q = x - c.a.xyz;
        float l = length(q), r = c.a.w + radius;
        if (l < r && l > 1e-6f) { n = q / l; x = c.a.xyz + n * r; inside = true; }
    } else {
        float3 h = c.b.xyz + radius;
        float3 q = x - c.a.xyz, o = abs(q) - h;
        if (o.x < 0.0f && o.y < 0.0f && o.z < 0.0f) {
            uint k = o.x > o.y ? (o.x > o.z ? 0u : 2u) : (o.y > o.z ? 1u : 2u);
            float s = q[k] >= 0.0f ? 1.0f : -1.0f;
            n[k] = s;
            x[k] = c.a[k] + s * h[k];
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
// chat's depth-buffer collision without the depth buffer's blind spots). A ball of `radius` (a mesh particle) looks
// that much further and stays that far out; `self`: its own instance, which the ray starts inside and passes.
inline float particleCollideScene(float3 from, thread float3& x, thread float3& v, float restitution, float friction, float radius,
                                  uint self, SCENE_ACCEL sc, thread const SceneData& sd) {
    float3 d = x - from;
    float len = length(d);
    if (len < 1e-6f) return 0.0f;
    float3 dir = d / len;
    float tmin = 0.0f;
    Surface h;
    for (uint k = 0; k < 3u; ++k) {
        h = traceSurface(makeRay(from, dir, tmin, len + radius + 1e-3f), rayMask(MASK_GEOMETRY, RAY_SHADOW), sc, sd, GI_RAY_SPREAD);
        if (!h.hit || h.instanceId != self) break;
        tmin = dot(h.position - from, dir) + 1e-4f;
        h.hit = false;
    }
    if (!h.hit) return 0.0f;
    float3 n = normalize(h.geomNormal);
    if (dot(n, d) > 0.0f) n = -n;
    x = h.position + n * max(radius, 2e-3f);
    float vn = dot(v, n);
    if (vn >= 0.0f) return 0.0f;
    v = (v - n * vn) * (1.0f - friction) - n * (vn * restitution);
    return -vn;
}

// Instance c.a.x of SDF shape c.a.y (the scene's): a ball of `radius` at x pushed out of it along its distance's
// gradient and bounced off it there, as particleCollide does. Its distance in its own space, scaled to the world's
// (its instances are turned and uniformly scaled).
inline float particleCollideShape(ParticleCollider c, thread float3& x, thread float3& v, float restitution, float friction, float radius,
                                  thread const SceneData& sd, device const SDFScene& sdf) {
    InstanceData inst = sd.instances[as_type<uint>(c.a.x)];
    SDFShape shape = sdf.shapes[as_type<uint>(c.a.y)];
    float4x4 toObject = transpose(inst.normalMatrix);   // the normal matrix is the inverse's transpose
    float3 q = (toObject * float4(x, 1.0f)).xyz;
    float scale = length(inst.transform[0].xyz);
    float d = sdfEval(sdf, shape, q) * scale - radius;
    if (d >= 0.0f) return 0.0f;
    float h = 1e-3f / max(scale, 1e-6f);
    float3 g = float3(sdfEval(sdf, shape, q + float3(h, 0, 0)) - sdfEval(sdf, shape, q - float3(h, 0, 0)),
                      sdfEval(sdf, shape, q + float3(0, h, 0)) - sdfEval(sdf, shape, q - float3(0, h, 0)),
                      sdfEval(sdf, shape, q + float3(0, 0, h)) - sdfEval(sdf, shape, q - float3(0, 0, h)));
    float3 n = (inst.normalMatrix * float4(g, 0.0f)).xyz;
    float l = length(n);
    if (l < 1e-12f) return 0.0f;
    n /= l;
    x -= n * d;
    float vn = dot(v, n);
    if (vn >= 0.0f) return 0.0f;
    v = (v - n * vn) * (1.0f - friction) - n * (vn * restitution);
    return -vn;
}

inline bool particleStep(thread Particle& p, uint slot, ParticleEmitter e, device const ParticleCollider* colliders, constant ParticleStep& s,
                         device const ParticleFieldInfo* fields, device const float4* samples, SCENE_ACCEL sc,
                         thread const SceneData& sd, device const SDFScene& sdf, thread bool& event) {
    uint flags = e.ids.w;
    float age = p.position.w + s.dt;
    if (age >= p.velocity.w) { event = (flags & PARTICLE_EVENTS_ON_DEATH) != 0; return false; }
    float3 x = p.position.xyz, v = p.velocity.xyz;
    float3 a = float3(0.0f, -s.gravity * e.forces.x, 0.0f);
    if (e.forces.w != 0.0f) {
        if (e.field.w >= 0.0f) {   // the baked tile: at the noise's own place, its curl in the same units
            float3 q = x * e.noise.x + float3(0.0f, s.wind.w * e.noise.y, 0.0f);
            a += particleField(fields[uint(e.field.w)], samples, q) * (e.noise.x * e.forces.w);
        } else {
            a += particleCurl(x, e.noise.x, s.wind.w * e.noise.y) * e.forces.w;
        }
    }
    if (e.field.x >= 0.0f && e.field.z == 0.0f) a += particleField(fields[uint(e.field.x)], samples, x) * e.field.y;
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
    if (e.field.x >= 0.0f && e.field.z != 0.0f) {   // a field of air it takes the velocity of, as drag does the wind's
        float3 air = particleField(fields[uint(e.field.x)], samples, x);
        v = air + (v - air) * exp(-e.field.y * s.dt);
    }
    float3 from = x;
    x += v * s.dt;
    float impact = 0.0f;
    if ((flags & PARTICLE_SCENE_COLLISIONS) != 0u && (s.parity & PARTICLE_STEP_SCENE) != 0u) {
        uint self = e.ids3.x == PARTICLE_NONE ? PARTICLE_NONE : e.ids3.x + (slot - e.ids.x);
        impact = particleCollideScene(from, x, v, e.attractor.w, e.lock.w, e.extra.x, self, sc, sd);
    }
    for (uint i = 0; i < s.colliders; ++i) {
        if (((e.ids2.y >> i) & 1u) == 0u) continue;
        ParticleCollider c = colliders[i];
        if (c.b.w == 3.0f) {
            if ((s.parity & PARTICLE_STEP_SCENE) != 0u) impact = max(impact, particleCollideShape(c, x, v, e.attractor.w, e.lock.w, e.extra.x, sd, sdf));
            continue;
        }
        impact = max(impact, particleCollide(c, x, v, e.attractor.w, e.lock.w, e.extra.x));
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
                               device float4*                  history   [[buffer(23)]],   // the trails' places
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
    // A trail starts where it is born: every place there.
    for (uint k = 0, n = em.ids3.y; k < n; ++k) history[(em.ids3.z + slot - em.ids.x) * n + k] = float4(q.position.xyz, 0.0f);
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
                                   device float4*                  history   [[buffer(23)]],  // the trails' places
                                   device const ParticleFieldInfo* fields    [[buffer(24)]],
                                   device const float4*            samples   [[buffer(25)]],
                                   device const SDFScene&          sdf       [[buffer(26)]],  // with PARTICLE_STEP_SCENE
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
        keep = particleStep(q, slot, em, colliders, s, fields, samples, sc, sd, sdf, event);
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
            // A trail's place every so many steps, round its ring (ParticleTrail: the oldest follows the newest).
            uint n = em.ids3.y, every = max(em.ids3.w, 1u);
            if (n > 0u && s.step % every == 0u) history[(em.ids3.z + slot - em.ids.x) * n + (s.step / every) % n] = float4(q.position.xyz, 0.0f);
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

// The alive particles' records and boxes for this frame's structures (`render`, `boxes`: the frame slot's), packed
// at the front of each structure's range: the casters' from 0, the others' from s.casterBound, so a build takes only
// the CPU's bound on how many can be alive (ParticleSystem.aliveBounds), not the pool. A thread a pool slot; the
// order within a range is the GPU's (one atomic a SIMD group), and particlePoseTailKernel empties the rest.
kernel void particlePoseKernel(constant ParticleStep&          s         [[buffer(0)]],
                               device const ParticleEmitter*   emitters  [[buffer(13)]],
                               device ParticleCounts&          c         [[buffer(14)]],
                               device const Particle*          particles [[buffer(16)]],
                               device ParticleRender*          render    [[buffer(23)]],
                               device float*                   boxes     [[buffer(24)]],
                               uint i [[thread_position_in_grid]])
{
    Particle q = particles[min(i, s.capacity - 1u)];
    bool alive = i < s.capacity && (q.info.w & PARTICLE_ALIVE) != 0u;
    bool caster = i < s.casters;
    uint mineC = alive && caster ? 1u : 0u, mineO = alive && !caster ? 1u : 0u;
    uint beforeC = simd_prefix_exclusive_sum(mineC), totalC = simd_sum(mineC);
    uint beforeO = simd_prefix_exclusive_sum(mineO), totalO = simd_sum(mineO);
    uint baseC = 0u, baseO = 0u;
    if (simd_is_first()) {
        if (totalC > 0u) baseC = atomic_fetch_add_explicit(&c.posed[s.pose][0], totalC, memory_order_relaxed);
        if (totalO > 0u) baseO = atomic_fetch_add_explicit(&c.posed[s.pose][1], totalO, memory_order_relaxed);
    }
    baseC = simd_broadcast_first(baseC);
    baseO = simd_broadcast_first(baseO);
    if (!alive) return;
    uint k = caster ? baseC + beforeC : baseO + beforeO;
    if (k >= (caster ? s.casterBound : s.othersBound)) return;   // past the bound (it holds): not drawn
    uint dst = caster ? k : s.casterBound + k;

    ParticleEmitter e = emitters[min(q.info.z, s.emitters - 1u)];
    uint seed = q.info.y, flags = e.ids.w, orient = e.ids2.z;
    float x = saturate(q.position.w / max(q.velocity.w, 1e-6f));
    float size = mix(e.size.x, e.size.y, x) * (1.0f - e.size.z * particleRandom(seed, 1u));
    float4 color = particleColor(e, x);
    if ((flags & PARTICLE_EMISSIVE) != 0u) color.rgb *= e.look.y;
    float spin = particleRandom(seed, 2u) * 2.0f * M_PI_F + (particleRandom(seed, 3u) * 2.0f - 1.0f) * e.look.w * q.position.w;
    // The box holds the billboard as the camera's rays widen it too (s.wind: the camera, how much a unit away).
    float3 cen = q.position.xyz, reach = float3(size * e.flip.w);
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
    ParticleRender r;
    r.centerRadius = float4(cen, size);
    r.axis = axis;
    r.color = half4(min(color, 65000.0f));
    r.radiance = half4(1.0h);
    r.keyLight = half4(0.0h);
    r.keyDir = half4(0.0h, 1.0h, 0.0h, 0.0h);
    r.info = uint4(i | ((flags & 0x67u) | orient << 3) << 24, f0 | f1 << 6 | blend << 12,
                   uint(as_type<ushort>(half(e.look.z))) | (((e.ids2.w >> 8) & 0xFFu) << 16) | ((e.ids2.w & 0xFFu) << 24), seed);
    render[dst] = r;
    reach += s.wind.w * length(cen - s.wind.xyz);
    float3 lo = cen - reach, hi = cen + reach;
    device float* b = boxes + 6 * dst;
    b[0] = lo.x; b[1] = lo.y; b[2] = lo.z;
    b[3] = hi.x; b[4] = hi.y; b[5] = hi.z;
}

// After the pose: every record and box it didn't fill holds nothing (a box far away), up to the pool's size, so
// what an earlier frame left isn't lit or met. Clears the other pair of counters for the next pose.
kernel void particlePoseTailKernel(constant ParticleStep&          s         [[buffer(0)]],
                                   device ParticleCounts&          c         [[buffer(14)]],
                                   device ParticleRender*          render    [[buffer(23)]],
                                   device float*                   boxes     [[buffer(24)]],
                                   uint i [[thread_position_in_grid]])
{
    if (i == 0u) {
        atomic_store_explicit(&c.posed[1u - s.pose][0], 0u, memory_order_relaxed);
        atomic_store_explicit(&c.posed[1u - s.pose][1], 0u, memory_order_relaxed);
    }
    if (i >= s.capacity) return;
    uint casters = min(atomic_load_explicit(&c.posed[s.pose][0], memory_order_relaxed), s.casterBound);
    uint others = min(atomic_load_explicit(&c.posed[s.pose][1], memory_order_relaxed), s.othersBound);
    if (i < casters || (i >= s.casterBound && i < s.casterBound + others)) return;
    render[i].centerRadius = float4(0.0f);
    device float* b = boxes + 6 * i;
    b[0] = 1.0e30f; b[1] = 1.0e30f; b[2] = 1.0e30f;
    b[3] = 1.0e30f; b[4] = 1.0e30f; b[5] = 1.0e30f;
}

// MARK: - Trails

// The trails' pose's parameters (ParticlesGPU.encodePose).
struct ParticleTrailPose {
    float4 camera;     // where the camera is; w = how far its ribbons widen a unit away (as the billboards: PARTICLE_WIDEN)
    uint   trails;     // trails in all
    uint   points;     // places each keeps (its curve has them and the head)
    uint   step;       // steps run
    uint   emitters;
};

// Every trail's control points, oldest place to the head, each with its radius (tapering from the head's to nothing,
// and widened as the camera's rays widen the billboards: `radii`, the structure's; `points`.w the trail's own), and
// its record (a thread its first point). A dead particle's trail is nothing at its emitter. A thread a point.
kernel void particleTrailPoseKernel(constant ParticleTrailPose&     p          [[buffer(0)]],
                                    device const ParticleEmitter*   emitters   [[buffer(13)]],
                                    device const Particle*          particles  [[buffer(16)]],
                                    device const float4*            history    [[buffer(17)]],
                                    device const float4*            lighting   [[buffer(18)]],
                                    device float4*                  points     [[buffer(19)]],
                                    device float*                   radii      [[buffer(20)]],
                                    device ParticleTrail*           trails     [[buffer(21)]],
                                    uint i [[thread_position_in_grid]])
{
    uint n = p.points, m = n + 1u, trail = i / m, j = i % m;
    if (trail >= p.trails) return;
    uint e = 0u;
    for (uint k = 0; k < p.emitters; ++k) {
        ParticleEmitter c = emitters[k];
        if (c.ids3.y > 0u && trail >= c.ids3.z && trail < c.ids3.z + c.ids.y) { e = k; break; }
    }
    ParticleEmitter em = emitters[e];
    uint slot = em.ids.x + (trail - em.ids3.z);
    Particle q = particles[slot];
    bool alive = (q.info.w & PARTICLE_ALIVE) != 0u && q.info.z == e;
    float3 x = em.origin.xyz;
    float r = 0.0f;
    float life = saturate(q.position.w / max(q.velocity.w, 1e-6f));
    if (alive) {
        float size = mix(em.size.x, em.size.y, life) * (1.0f - em.size.z * particleRandom(q.info.y, 1u));
        uint every = max(em.ids3.w, 1u), last = p.step > 0u ? ((p.step - 1u) / every) % n : 0u;
        x = j == n ? q.position.xyz : history[trail * n + (last + 1u + j) % n].xyz;
        r = size * em.extra.y * float(j) / float(n);
    }
    points[i] = float4(x, r);
    radii[i] = r > 0.0f ? max(r, p.camera.w * length(x - p.camera.xyz)) : 0.0f;
    if (j != 0u) return;
    ParticleTrail t;
    float4 color = particleColor(em, life);
    if ((em.ids.w & PARTICLE_EMISSIVE) != 0u) color.rgb *= em.look.y;
    t.color = half4(min(color, 65000.0f));
    t.radiance = half4(half3(min(lighting[3u * slot].rgb + lighting[3u * slot + 1u].rgb, 65000.0f)), 1.0h);
    t.info = uint4(em.ids.w & 7u, alive ? 1u : 0u, slot, 0u);
    trails[trail] = t;
}

// MARK: - Mesh particles

// The mesh pose's parameters (ParticlesGPU.encodeMeshPose).
struct ParticleMeshPose {
    uint4  range;      // the meshes' first pool slot, their slots, the descriptors' stride (0: none), emitters
    float4 lag;        // x = the time since the last pose (s): last frame's place, for motion vectors
};

// A turn of `angle` about unit `axis` (Rodrigues).
inline float3x3 particleTurn(float3 axis, float angle) {
    float c = cos(angle), s = sin(angle), t = 1.0f - c;
    float3 a = axis;
    return float3x3(float3(t * a.x * a.x + c, t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y),
                    float3(t * a.x * a.y - s * a.z, t * a.y * a.y + c, t * a.y * a.z + s * a.x),
                    float3(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c));
}

// A mesh particle's transform at `age`: its size then, turned about its own axis from its own start, at x.
inline float4x4 particleMeshTransform(ParticleEmitter e, uint seed, float life, float age, float3 x) {
    float z = particleRandom(seed, 5u) * 2.0f - 1.0f, phi = particleRandom(seed, 6u) * 2.0f * M_PI_F;
    float r = sqrt(max(1.0f - z * z, 0.0f));
    float3 axis = float3(r * cos(phi), r * sin(phi), z);
    float angle = particleRandom(seed, 2u) * 2.0f * M_PI_F + (particleRandom(seed, 3u) * 2.0f - 1.0f) * e.look.w * age;
    float size = mix(e.size.x, e.size.y, saturate(age / max(life, 1e-6f))) * (1.0f - e.size.z * particleRandom(seed, 1u));
    float3x3 m = particleTurn(axis, angle) * max(size, 1e-4f);
    return float4x4(float4(m[0], 0.0f), float4(m[1], 0.0f), float4(m[2], 0.0f), float4(x, 1.0f));
}

// Every mesh slot's instance (and Metal's descriptor) in the frame slot's records: an alive particle where it is, a
// dead one shrunk to nothing at its emitter. Ahead of the top-level structure's update, which takes them; from where
// the last frame's steps left the pool (this frame's run after the structure: their scene collisions trace it), so
// the meshes are a frame behind the billboards. A thread a mesh slot.
kernel void particleMeshPoseKernel(constant ParticleMeshPose&      m           [[buffer(0)]],
                                   device const ParticleEmitter*   emitters    [[buffer(13)]],
                                   device const Particle*          particles   [[buffer(16)]],
                                   device InstanceData*            instances   [[buffer(25)]],
                                   device uchar*                   descriptors [[buffer(26)]],
                                   uint i [[thread_position_in_grid]])
{
    if (i >= m.range.y) return;
    uint slot = m.range.x + i, e = 0u;
    for (uint k = 0; k < m.range.w; ++k) {
        ParticleEmitter c = emitters[k];
        if (c.ids3.x != PARTICLE_NONE && slot >= c.ids.x && slot < c.ids.x + c.ids.y) { e = k; break; }
    }
    ParticleEmitter em = emitters[e];
    uint instance = em.ids3.x + (slot - em.ids.x);
    Particle q = particles[slot];
    float4x4 now, before;
    if ((q.info.w & PARTICLE_ALIVE) != 0u && q.info.z == e) {
        float age = q.position.w, lag = min(m.lag.x, age);
        now = particleMeshTransform(em, q.info.y, q.velocity.w, age, q.position.xyz);
        before = particleMeshTransform(em, q.info.y, q.velocity.w, age - lag, q.position.xyz - q.velocity.xyz * lag);
    } else {
        now = float4x4(float4(1e-4f, 0, 0, 0), float4(0, 1e-4f, 0, 0), float4(0, 0, 1e-4f, 0), float4(em.origin.xyz, 1));
        before = now;
    }
    // The inverse of s R and t: R^T / s and -(R^T t) / s; the normal matrix is its transpose.
    float3x3 r = float3x3(now[0].xyz, now[1].xyz, now[2].xyz);
    float s2 = max(length_squared(r[0]), 1e-12f);
    float3x3 inv = transpose(r) * (1.0f / s2);
    float3 it = -(inv * now[3].xyz);
    float4x4 inverse = float4x4(float4(inv[0], 0), float4(inv[1], 0), float4(inv[2], 0), float4(it, 1));
    instances[instance].transform = now;
    instances[instance].prevTransform = before;
    instances[instance].normalMatrix = transpose(inverse);
    if (m.range.z != 0u) {
        device float* d = (device float*)(descriptors + instance * m.range.z);
        for (uint c = 0; c < 4; ++c) {
            for (uint row = 0; row < 3; ++row) d[c * 3 + row] = now[c][row];
        }
    }
}

// MARK: - Light

// The light a lit particle scatters, once per particle per frame (rays per pixel would cost far more): from each of
// the first lights (PARTICLE_LIGHTS), scattered isotropically (E / 4 pi per unit albedo, as the path tracer's
// particles do), its visibility the opaque scene's and the particles' transmittance between (so smoke shades
// itself), plus the sky's mean (what an isotropic scatterer sends in a uniform sky). Averaged
// over the frames (the shadow rays aim at random points of the lights): each frame weighs in at a third, a newborn's
// first frame alone. `lighting`: per slot three: that average of the light from all round (rgb) and whose it is (w:
// the particle's seed); of its brightest light (which six-way smoke shades apart: particleLit); where that comes from
// (summed by its brightness, so the average leans toward the brighter frames').
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
    float3 sum = skyAmbient(u, s), key = float3(0.0f), keyDir = float3(0.0f);
    float keyLum = 0.0f;
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
        // lightUnshadowed facing the light is its irradiance / pi: a quarter of it is E / 4 pi. Through the particles
        // between, light scattered on inside a dense column gets further than single scattering lets it: octaves of
        // weaker extinction (Wrenninge's multiple-scattering approximation), the same through thin smoke.
        float T = particleTransmittance(p, d / dist, r.centerRadius.w * 0.5f, dist, accel);
        float through = (T + 0.5f * sqrt(T) + 0.25f * sqrt(sqrt(T))) * (1.0f / 1.75f);
        float3 c = 0.25f * e * through * sunVisibilityScale(light, p, s);
        float lum = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        if (lum > keyLum) {
            sum += key;   // the brightest so far is the key; the one before joins the rest
            key = c;
            keyLum = lum;
            keyDir = toward;
        } else {
            sum += c;
        }
    }
    uint slot = min(r.info.x & 0xFFFFFFu, capacity - 1u);
    float4 last = lighting[3u * slot], lastKey = lighting[3u * slot + 1u], lastDir = lighting[3u * slot + 2u];
    bool same = as_type<uint>(last.w) == r.info.w;
    float3 now = same ? mix(last.rgb, sum, 1.0f / 3.0f) : sum;
    float3 keyNow = same ? mix(lastKey.rgb, key, 1.0f / 3.0f) : key;
    float3 dirNow = same ? mix(lastDir.xyz, keyDir * keyLum, 1.0f / 3.0f) : keyDir * keyLum;
    lighting[3u * slot] = float4(now, as_type<float>(r.info.w));
    lighting[3u * slot + 1u] = float4(keyNow, 0.0f);
    lighting[3u * slot + 2u] = float4(dirNow, 0.0f);
    float l = length(dirNow);
    render[i].radiance = half4(half3(min(now, 65000.0f)), 1.0h);
    render[i].keyLight = half4(half3(min(keyNow, 65000.0f)), 1.0h);
    render[i].keyDir = half4(half3(l > 1e-8f ? dirNow / l : float3(0.0f, 1.0f, 0.0f)), 0.0h);
}

// MARK: - The camera's layer

// The camera's billboards' least half-size, in texels of the layer (ParticlesGPU.widen).
constant float PARTICLE_WIDEN = 0.5f;
// ...and under how many texels across (half-size) a particle is too thin for them: the overlay traces it again.
constant float PARTICLE_DETAIL = 2.0f;

// The layer's size and how its rays leave the camera (Renderer.particleLayerStages): `jitter`, as the frame's (the
// layer is the frame's size, composited pixel for pixel); otherwise through its own texels' centres, steady from frame
// to frame (it goes over MetalFX's output, which doesn't filter it over time, or is smaller than the frame).
// `detail`: the overlay traces the thin particles again (particleLayerRay leaves them out).
struct ParticleLayerParams {
    uint2 size;
    uint  jitter;
    uint  detail;
};

// What the camera's ray along `dir` (through `uv` of the view) sees of the particles in front of the surface at
// `depth` (0: none): rgb = the light they send (fogged), a = how much of what is behind them they hide. Soft where
// they near that surface, and faded right in front of the camera. `footprint`: the ray's pixel across, a unit away
// (radians): the billboards are at least about that wide. `detail`: the ones under PARTICLE_DETAIL of them are left
// out, and set `thin` (particleCollect).
inline float4 particleLayerRay(constant Uniforms& u, SCENE_ACCEL sc, constant FogParams& fog, texture3d<float> fogGrid, float3 dir,
                               float2 uv, float depth, float footprint, bool detail, thread bool& thin) {
    float along = dot(dir, u.camForward.xyz);
    float tOpaque = depth > 0.0f ? depth / max(along, 1e-4f) : 1.0e5f;
    float meanT;
    float4 gathered = particleGather<4>(u.camPos.xyz, dir, tOpaque, depth > 0.0f, sc, meanT, PARTICLE_WIDEN * footprint,
                                        detail ? PARTICLE_DETAIL * footprint : 0.0f, thin);
    float3 c = gathered.rgb;
    float hidden = gathered.a;
    if (hidden > 1e-4f && flagOn(u.flags, FLAG_FOG) && !flagOn(u.flags, FLAG_FOG_REFERENCE)) {
        // The fog in front of them, at their mean distance: what they send dims, and the fog's own light takes the
        // share of the view they hide (the composite fogs the rest to the surface).
        float tMean = meanT / hidden;
        float4 fogged = fogFromGrid(fog, fogGrid, uv, tMean * along);
        c = c * fogged.a + hidden * fogged.rgb;
    }
    return float4(c, hidden);
}

// A pixel's footprint at `uv` of a view `height` pixels high (radians across it, a unit away).
inline float particleFootprint(constant Uniforms& u, float2 uv, float height) {
    return length(normalize(viewDirection(u, uv + float2(0.0f, 1.0f / height))) - normalize(viewDirection(u, uv)));
}

// The camera's layer (particleLayerRay a texel): the composite puts it over the scene, or particleOverlayKernel over
// MetalFX's output. `layerDepth`: x = the depth of the surface each texel's particles stand in front of, which the
// upsampling weighs by (particleUpsample); y = 1 where some are too thin for its texels.
kernel void particleLayerKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      sc         [[buffer(1)]],
                                constant FogParams&              fog        [[buffer(9)]],
                                constant ParticleLayerParams&    lp         [[buffer(10)]],
                                texture2d<float, access::read>   nd         [[texture(0)]],
                                texture2d<float, access::write>  layer      [[texture(1)]],
                                texture3d<float>                 fogGrid    [[texture(2)]],
                                texture2d<float, access::write>  layerDepth [[texture(3)]],
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= lp.size.x || tid.y >= lp.size.y) return;
    float2 uv = (float2(tid) + 0.5f) / float2(lp.size);
    uint2 pixel = min(uint2(uv * float2(u.width, u.height)), uint2(u.width - 1, u.height - 1));
    float3 dir = lp.jitter != 0u ? primaryDirection(u, pixel) : normalize(viewDirection(u, uv));
    float depth = nd.read(pixel).w;
    bool thin;
    float4 c = particleLayerRay(u, sc, fog, fogGrid, dir, uv, depth, particleFootprint(u, uv, float(lp.size.y)), lp.detail != 0u, thin);
    layer.write(c, tid);
    layerDepth.write(float4(depth, thin ? 1.0f : 0.0f, 0.0f, 0.0f), tid);
}

// The particles' layer over MetalFX's output (at its size, in place), before the lens and the tone curve: MetalFX
// would filter it over time with the scene's motion, which isn't theirs (sparks smeared into streaks), so it takes
// only the scene. Upsampled (particleUpsample; `nd`: the traced frame's depths, for its weights), but where the
// layer's texels are too coarse for the particles there (sparks, rain, motes: `thin`) traced again for the pixel.
kernel void particleOverlayKernel(constant Uniforms&                   u          [[buffer(0)]],
                                  SCENE_ACCEL                          sc         [[buffer(1)]],
                                  constant FogParams&                  fog        [[buffer(9)]],
                                  texture2d<float, access::read_write> out        [[texture(0)]],
                                  texture2d<float, access::read>       layer      [[texture(1)]],
                                  texture2d<float, access::read>       layerDepth [[texture(2)]],
                                  texture2d<float, access::read>       nd         [[texture(3)]],
                                  texture3d<float>                     fogGrid    [[texture(4)]],
                                  uint2 tid [[thread_position_in_grid]])
{
    uint2 size = uint2(out.get_width(), out.get_height());
    if (tid.x >= size.x || tid.y >= size.y) return;
    float2 uv = (float2(tid) + 0.5f) / float2(size);
    uint2 ndSize = uint2(nd.get_width(), nd.get_height());
    float depth = nd.read(min(uint2(uv * float2(ndSize)), ndSize - 1u)).w;
    bool thin;
    float4 l = particleUpsample(layer, layerDepth, uv, depth, thin);
    if (thin) {
        bool again;
        l = particleLayerRay(u, sc, fog, fogGrid, normalize(viewDirection(u, uv)), uv, depth, particleFootprint(u, uv, float(size.y)),
                             false, again);
    }
    float4 c = out.read(tid);
    out.write(float4(l.rgb + (1.0f - l.a) * c.rgb, c.a), tid);
}
