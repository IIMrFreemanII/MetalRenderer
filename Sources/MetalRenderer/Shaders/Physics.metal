// ---------------------------------------------------------------------------------------------
// Rigid-body physics (Physics.swift): the GPU's step, one thread per body, as PhysicsCPU.swift runs it
// ---------------------------------------------------------------------------------------------

// The stages are PhysicsCPU.swift's, in its order, with the same arithmetic: the CPU's step is this one's reference.
// A stage that reads other bodies reads them from the buffer the stage before wrote and writes the other one (Jacobi),
// and every sum is a gather over a body's own list in a fixed order, so a run is the same every time: no float atomics.
// The only atomics build the hash grid's buckets, whose order nothing depends on (a body keeps its lowest partners).

constant uint PHYS_STATIC = 0x80000000u, PHYS_NONE = 0xFFFFFFFFu, PHYS_ASLEEP = 1u;
constant uint PHYS_PAIRS = 16, PHYS_CONTACTS = 4;   // PhysicsWorld.maxPairs, maxContacts
constant uint PHYS_COLOURS = 32, PHYS_ROUNDS = 64;  // PhysicsWorld.maxColours, maxRounds
constant uint PHYS_LEFTOVER = 0xFFFFFFFEu;          // PhysicsWorld.leftover
constant uint PHYS_SDF = 0, PHYS_SPHERE = 1, PHYS_CAPSULE = 2, PHYS_BOX = 3, PHYS_PLANE = 4;   // PhysicsShapeKind
constant uint PHYS_REFINE_STEPS = 6;
constant float PHYS_GRADIENT_STEP = 1e-3f;
constant float PHYS_PUSH_SPEED = 3.0f;              // PhysicsWorld.pushSpeed
constant float PHYS_GYRATION = 0.15f;               // PhysicsWorld.gyration

struct PhysicsBody {
    float4 position;       // centre of mass; w = inverse mass
    float4 rotation;       // body -> world
    float4 velocity;       // w = friction
    float4 angular;        // w = restitution
    float4 prevPosition;   // w = how long it has been still
    float4 prevRotation;
    float4 invInertia;     // w = bounding radius
    uint4  info;           // x = shape, y = flags, z = instance, w = the body a joint hangs it from + 1 (0: none)
};
static_assert(sizeof(PhysicsBody) == 128, "PhysicsBody: GPUPhysicsBody");

// A joint between two bodies: GPUPhysicsJoint (PhysicsCPU.solveJoint).
struct PhysicsJoint {
    float4 anchorA, anchorB;
    float4 axisA;          // w = lo
    float4 axisB;          // w = hi
    float4 referenceA;     // w = a ball joint's swing
    float4 referenceB;     // w = damping
    uint4  info;           // x = A, y = B, z = kind
};
static_assert(sizeof(PhysicsJoint) == 112, "PhysicsJoint: GPUPhysicsJoint");
constant uint PHYS_HINGE = 1;   // PhysicsJointKind.hinge
constant uint PHYS_JOINT_ITERATIONS = 2;   // PhysicsWorld.jointIterations

struct PhysicsShape {
    float4 comPosition;    // w = bounding radius
    float4 comRotation;
    float4 params;
    uint4  info;           // x = kind, y = first sample, z = samples, w = SDF shape
};
static_assert(sizeof(PhysicsShape) == 64, "PhysicsShape: GPUPhysicsShape");

struct PhysicsPair {
    uint partner;
    uint contacts;
    uint link;
    uint pad;
};
static_assert(sizeof(PhysicsPair) == 16, "PhysicsPair: GPUPhysicsPair");

struct PhysicsContact {
    float4 normal;         // w = separation found at
    float4 anchorA;        // w = A's radius
    float4 anchorB;        // w = B's radius
    float4 lambda;         // x = lambda, y = normal speed before
};
static_assert(sizeof(PhysicsContact) == 64, "PhysicsContact: GPUPhysicsContact");

struct PhysicsParams {
    float4 gravity;        // w = substep
    uint4  counts;         // bodies, statics, pairs per body, hash buckets
    float4 grid;           // cell, margin, top speed, step
    float4 sleep;          // still speed, still turn rate, time to sleep, cell speed
    uint4  particles;      // particles, their hash buckets, neighbours each, colliders each
    float4 particleGrid;   // their cell size, the speed their reach allows for, a cloth's air drag, rest speed
    uint4  cloth;          // constraints, their colours, the joints' colours, ragdolls
    float4 rolling;        // rolling resistance, spinning resistance, wake speed, wake turn rate
};
static_assert(sizeof(PhysicsParams) == 128, "PhysicsParams: GPUPhysicsParams");

constant uint PHYS_CLOTH = 1u;   // PhysicsParticle.info.y: a cloth's vertex (PhysicsWorld.clothBit)

struct PhysicsConstraint {
    uint  a, b;
    float rest;
    float compliance;
};
static_assert(sizeof(PhysicsConstraint) == 16, "PhysicsConstraint: GPUPhysicsConstraint");

// A body held by the mouse: GPUPhysicsGrab.
struct PhysicsGrab {
    float4 target;   // w = 1 while held
    float4 anchor;   // the body's space
    uint   body, pad0, pad1, pad2;
};
static_assert(sizeof(PhysicsGrab) == 48, "PhysicsGrab: GPUPhysicsGrab");
constant float PHYS_HOLD_PULL = 0.03f, PHYS_HOLD_DAMPING = 8.0f;   // PhysicsWorld.holdPull, holdDamping

struct PhysicsParticle {
    float4 position;       // w = radius
    float4 velocity;       // w = friction
    float4 prevPosition;   // w = inverse mass
    uint4  info;           // x = instance (none: a cloth's vertex), y = flags, z = a cloth vertex's place in the vertex buffer
};
static_assert(sizeof(PhysicsParticle) == 64, "PhysicsParticle: GPUPhysicsParticle");

// MARK: - Math (PhysicsMath)

inline float4 physConj(float4 q) { return float4(-q.xyz, q.w); }
inline float4 physNormalize(float4 q) { float l = length(q); return l > 0.0f ? q / l : float4(0, 0, 0, 1); }
inline float4 physTurn(float4 q, float3 theta) { return physNormalize(q + 0.5f * quatMul(float4(theta, 0.0f), q)); }
inline float3 physInvInertia(float4 q, float3 inv, float3 v) { return quatRotate(q, inv * quatRotate(physConj(q), v)); }
inline float3 physDirection(float3 v) { float l = length(v); return l > 1e-12f ? v / l : float3(0, 1, 0); }

inline float physBox(float3 q, float3 b, float r) {
    float3 e = abs(q) - (b - r);
    return length(max(e, 0.0f)) + min(max(e.x, max(e.y, e.z)), 0.0f) - r;
}
inline float3 physBoxGradient(float3 q, float3 b, float r) {
    float3 e = abs(q) - (b - r);
    float3 s = float3(q.x >= 0.0f ? 1.0f : -1.0f, q.y >= 0.0f ? 1.0f : -1.0f, q.z >= 0.0f ? 1.0f : -1.0f);
    if (e.x > 0.0f || e.y > 0.0f || e.z > 0.0f) return physDirection(max(e, 0.0f) * s);
    if (e.x >= e.y && e.x >= e.z) return float3(s.x, 0, 0);
    return e.y >= e.z ? float3(0, s.y, 0) : float3(0, 0, s.z);
}

// What the narrow phase reads.
struct PhysicsShapes {
    device const PhysicsShape* shapes;
    device const float4*       samples;
    SDFScene                   sdf;
};

inline float physDistance(PhysicsShapes w, uint s, float3 p) {
    PhysicsShape shape = w.shapes[s];
    float4 k = shape.params;
    switch (shape.info.x) {
    case PHYS_SPHERE: return length(p) - k.x;
    case PHYS_CAPSULE: return length(float3(p.x, p.y - min(max(p.y, -k.x), k.x), p.z)) - k.y;
    case PHYS_BOX: return physBox(p, k.xyz, k.w);
    case PHYS_PLANE: return p.y;
    default: {
        float3 q = quatRotate(shape.comRotation, p) + shape.comPosition.xyz;
        return sdfEval(w.sdf, w.sdf.shapes[shape.info.w], q);
    }
    }
}

inline float3 physGradient(PhysicsShapes w, uint s, float3 p) {
    PhysicsShape shape = w.shapes[s];
    float4 k = shape.params;
    switch (shape.info.x) {
    case PHYS_PLANE: return float3(0, 1, 0);
    case PHYS_SPHERE: return physDirection(p);
    case PHYS_CAPSULE: return physDirection(float3(p.x, p.y - min(max(p.y, -k.x), k.x), p.z));
    case PHYS_BOX: return physBoxGradient(p, k.xyz, k.w);
    default: break;
    }
    const float3 taps[4] = {float3(1, -1, -1), float3(-1, -1, 1), float3(-1, 1, -1), float3(1, 1, 1)};
    float3 g = float3(0.0f);
    for (uint t = 0; t < 4; ++t) g += taps[t] * physDistance(w, s, p + taps[t] * PHYS_GRADIENT_STEP);
    float l = length(g);
    return l > 0.0f ? g / l : float3(0, 1, 0);
}

struct PhysPose {
    float3 position;
    float4 rotation;
    float3 toBody(float3 p) const { return quatRotate(physConj(rotation), p - position); }
    float3 toWorld(float3 p) const { return position + quatRotate(rotation, p); }
    float3 direction(float3 v) const { return quatRotate(rotation, v); }
};
inline PhysPose physPose(PhysicsBody b) { PhysPose p; p.position = b.position.xyz; p.rotation = b.rotation; return p; }

// MARK: - Manifold (PhysicsManifold)

struct PhysCandidate {
    float3 pa, pb, n;
    float  separation, ra, rb;
    float3 middle() const { return (pa - n * ra + pb + n * rb) * 0.5f; }
};

inline float physArea(float3 p0, float3 p1, float3 p2, float3 p3) {
    float a = length_squared(cross(p0 - p1, p2 - p3));
    float b = length_squared(cross(p0 - p2, p1 - p3));
    float c = length_squared(cross(p0 - p3, p1 - p2));
    return max(a, max(b, c));
}

struct PhysManifold {
    PhysCandidate p[4];
    uint count;
    float3 normalSum;
};

inline void physAdd(thread PhysManifold& m, PhysCandidate c, float merge, float margin) {
    m.normalSum += c.n * (margin - c.separation);
    float3 cm = c.middle();
    for (uint i = 0; i < m.count; ++i) {
        if (length_squared(m.p[i].middle() - cm) < merge * merge) {
            if (c.separation < m.p[i].separation) m.p[i] = c;
            return;
        }
    }
    if (m.count < 4) { m.p[m.count++] = c; return; }
    int deepest = -1;
    float depth = c.separation;
    for (int i = 0; i < 4; ++i) if (m.p[i].separation < depth) { depth = m.p[i].separation; deepest = i; }
    float3 q[4] = {m.p[0].middle(), m.p[1].middle(), m.p[2].middle(), m.p[3].middle()};
    int best = -1;
    float bestArea = deepest < 0 ? -1.0f : physArea(q[0], q[1], q[2], q[3]);
    for (int i = 0; i < 4; ++i) {
        if (i == deepest) continue;
        float3 r[4] = {q[0], q[1], q[2], q[3]};
        r[i] = cm;
        float a = physArea(r[0], r[1], r[2], r[3]);
        if (a > bestArea) { bestArea = a; best = i; }
    }
    if (best >= 0) m.p[best] = c;
}

inline void physAgree(thread PhysManifold& m) {
    float l = length(m.normalSum);
    if (!(l > 0.0f)) return;
    float3 n = m.normalSum / l;
    for (uint i = 0; i < m.count; ++i) {
        if (dot(m.p[i].n, n) > 0.5f) {
            m.p[i].n = n;
            m.p[i].separation = dot(m.p[i].pa - m.p[i].pb, n) - m.p[i].ra - m.p[i].rb;
        }
    }
}

inline bool physFlat(uint kind) { return kind == PHYS_BOX || kind == PHYS_SDF; }

// One sample's candidate (PhysicsWorld.collide's first two loops): sample `s` of the body at `on` against the
// distance of the body at `into` (shape `shape`, bounding radius `radius`). `fromA`: the sample is A's.
inline bool physSampleCandidate(PhysicsShapes w, float4 s, PhysPose on, PhysPose into, uint shape, float radius, bool skipReach,
                                float margin, bool fromA, thread PhysCandidate& c) {
    float3 x = on.toWorld(s.xyz);
    float reach = radius + s.w + margin;
    if (!skipReach && length_squared(x - into.position) > reach * reach) return false;
    float3 q = into.toBody(x);
    float d = physDistance(w, shape, q) - s.w;
    if (d >= margin) return false;
    float3 g = into.direction(physGradient(w, shape, q));
    c = fromA ? PhysCandidate{x, x - g * (d + s.w), g, d, s.w, 0.0f} : PhysCandidate{x - g * (d + s.w), x, -g, d, 0.0f, s.w};
    return true;
}

// Every lane takes the candidates the lanes found, in lane order (the samples' order), into its copy of the manifold.
inline void physAddFound(thread PhysManifold& m, bool found, PhysCandidate c, float merge, float margin) {
    ulong bits = ulong(simd_vote::vote_t(simd_ballot(found)));
    while (bits != 0) {
        ushort l = ushort(ctz(bits));
        bits &= bits - 1;
        PhysCandidate x = {simd_broadcast(c.pa, l), simd_broadcast(c.pb, l), simd_broadcast(c.n, l),
                           simd_broadcast(c.separation, l), simd_broadcast(c.ra, l), simd_broadcast(c.rb, l)};
        physAdd(m, x, merge, margin);
    }
}

// The contacts between a and b closer than `margin` (PhysicsWorld.collide), by a SIMD group: its lanes test 32
// samples at a time, and the manifold takes what they found in the samples' order, as the CPU's does one by one.
inline PhysManifold physCollide(PhysicsShapes w, PhysicsBody a, PhysicsBody b, float margin, ushort lane, ushort lanes) {
    uint sa = a.info.x, sb = b.info.x;
    PhysPose pa = physPose(a), pb = physPose(b);
    float ra = a.invInertia.w, rb = b.invInertia.w;
    float merge = 0.05f * min(ra, rb > 0.0f ? rb : ra);
    PhysicsShape shapeA = w.shapes[sa], shapeB = w.shapes[sb];
    bool plane = shapeB.info.x == PHYS_PLANE;
    PhysManifold m;
    m.count = 0;
    m.normalSum = float3(0.0f);

    for (uint base = 0; base < shapeA.info.z; base += lanes) {
        PhysCandidate c;
        bool found = base + lane < shapeA.info.z
            && physSampleCandidate(w, w.samples[shapeA.info.y + base + lane], pa, pb, sb, rb, plane, margin, true, c);
        physAddFound(m, found, c, merge, margin);
    }
    for (uint base = 0; base < shapeB.info.z; base += lanes) {
        PhysCandidate c;
        bool found = base + lane < shapeB.info.z
            && physSampleCandidate(w, w.samples[shapeB.info.y + base + lane], pb, pa, sa, ra, false, margin, false, c);
        physAddFound(m, found, c, merge, margin);
    }
    if (physFlat(shapeA.info.x) && physFlat(shapeB.info.x)) {
        float3 start = (pa.position + pb.position) * 0.5f;
        if (m.count > 0) {
            uint deepest = 0;
            for (uint i = 1; i < m.count; ++i) if (m.p[i].separation < m.p[deepest].separation) deepest = i;
            start = m.p[deepest].middle();
        }
        // Lane 0 steps along A's surface into B, lane 1 along B's into A; then they are added in that order.
        PhysCandidate c;
        bool found = false;
        if (lane < 2) {
            uint side = lane;
            PhysPose px = side == 0 ? pa : pb, py = side == 0 ? pb : pa;
            uint sx = side == 0 ? sa : sb, sy = side == 0 ? sb : sa;
            float3 p = start;
            float stepLength = 0.25f * min(ra, rb);
            for (uint k = 0; k < PHYS_REFINE_STEPS; ++k) {
                float3 qx = px.toBody(p);
                p -= px.direction(physGradient(w, sx, qx)) * physDistance(w, sx, qx);
                float3 qy = py.toBody(p);
                p -= py.direction(physGradient(w, sy, qy)) * stepLength;
                stepLength *= 0.6f;
            }
            float3 qx = px.toBody(p);
            p -= px.direction(physGradient(w, sx, qx)) * physDistance(w, sx, qx);
            float3 qy = py.toBody(p);
            float d = physDistance(w, sy, qy);
            if (d < margin) {
                float3 g = py.direction(physGradient(w, sy, qy));
                c = side == 0 ? PhysCandidate{p, p - g * d, g, d, 0.0f, 0.0f} : PhysCandidate{p - g * d, p, -g, d, 0.0f, 0.0f};
                found = true;
            }
        }
        physAddFound(m, found, c, merge, margin);
    }
    physAgree(m);
    return m;
}

// MARK: - Broad phase

inline float physReach(PhysicsBody b, constant PhysicsParams& p) {
    return b.invInertia.w + min(length(b.velocity.xyz), p.sleep.w) * p.grid.w + p.grid.y;
}
inline int3 physCell(float3 x, float size) { return int3(floor(x / size)); }
inline uint physHash(int3 c, uint buckets) {
    return ((uint(c.x) * 73856093u) ^ (uint(c.y) * 19349663u) ^ (uint(c.z) * 83492791u)) & (buckets - 1u);
}

// The start: a scene's first step, or a replay from it.
kernel void physicsResetKernel(constant PhysicsParams&       p                [[buffer(0)]],
                               device const PhysicsBody*     initial          [[buffer(1)]],
                               device PhysicsBody*           bodies           [[buffer(2)]],
                               device uint*                  wake             [[buffer(3)]],
                               device float4*                lastPose         [[buffer(4)]],
                               device const PhysicsParticle* initialParticles [[buffer(5)]],
                               device PhysicsParticle*       particles        [[buffer(6)]],
                               device float4*                lastParticle     [[buffer(7)]],
                               uint i [[thread_position_in_grid]])
{
    if (i < p.counts.x) {
        bodies[i] = initial[i];
        wake[i] = 0;
        lastPose[2 * i] = float4(initial[i].position.xyz, 0.0f);
        lastPose[2 * i + 1] = initial[i].rotation;
    }
    if (i < p.particles.x) {
        particles[i] = initialParticles[i];
        lastParticle[i] = float4(initialParticles[i].position.xyz, 0.0f);
    }
}

kernel void physicsClearKernel(constant PhysicsParams& p          [[buffer(0)]],
                               device atomic_uint*     heads      [[buffer(1)]],
                               device atomic_uint*     particleHeads [[buffer(3)]],
                               uint h [[thread_position_in_grid]])
{
    if (h < p.counts.w) atomic_store_explicit(&heads[h], PHYS_NONE, memory_order_relaxed);
    if (h < p.particles.y) atomic_store_explicit(&particleHeads[h], PHYS_NONE, memory_order_relaxed);
}

kernel void physicsInsertKernel(constant PhysicsParams&   p      [[buffer(0)]],
                                device const PhysicsBody* bodies [[buffer(1)]],
                                device atomic_uint*       heads  [[buffer(2)]],
                                device uint*              next   [[buffer(3)]],
                                uint i [[thread_position_in_grid]])
{
    if (i >= p.counts.x) return;
    uint h = physHash(physCell(bodies[i].position.xyz, p.grid.x), p.counts.w);
    next[i] = atomic_exchange_explicit(&heads[h], i, memory_order_relaxed);
}

// Into a particle's colliders, kept sorted (statics first), the lowest `capacity` of them.
inline void physKeep(thread uint* keys, thread uint& count, uint partner, uint capacity = PHYS_PAIRS) {
    uint key = partner ^ PHYS_STATIC;
    if (count == capacity && key >= keys[count - 1]) return;
    uint at = count;
    while (at > 0 && keys[at - 1] > key) --at;
    if (at > 0 && keys[at - 1] == key) return;   // met through two cells of the same bucket
    uint end = min(count, capacity - 1);
    for (uint k = end; k > at; --k) keys[k] = keys[k - 1];
    keys[at] = key;
    count = min(count + 1, capacity);
}

// PhysicsWorld.distance2: fused the same way, so the partners sort the same on both.
inline float physDistance2(float3 a, float3 b) {
    float3 d = a - b;
    return fma(d.z, d.z, fma(d.y, d.y, d.x * d.x));
}

// Into a body's partners, kept nearest first (statics, at -1, before all; the lower first of equals), the nearest
// PHYS_PAIRS of them (PhysicsCPU.broadPhase).
inline void physKeepNearest(thread float* d2s, thread uint* ids, thread uint& count, float d2, uint id) {
    if (count == PHYS_PAIRS && !(d2 < d2s[count - 1] || (d2 == d2s[count - 1] && id < ids[count - 1]))) return;
    uint at = count;
    while (at > 0 && (d2 < d2s[at - 1] || (d2 == d2s[at - 1] && id < ids[at - 1]))) --at;
    if (at > 0 && d2s[at - 1] == d2 && ids[at - 1] == id) return;   // met through two cells of the same bucket
    for (uint k = min(count, PHYS_PAIRS - 1); k > at; --k) { d2s[k] = d2s[k - 1]; ids[k] = ids[k - 1]; }
    d2s[at] = d2;
    ids[at] = id;
    count = min(count + 1, PHYS_PAIRS);
}

kernel void physicsPairsKernel(constant PhysicsParams&   p        [[buffer(0)]],
                               device const PhysicsBody* bodies   [[buffer(1)]],
                               device const PhysicsBody* statics  [[buffer(2)]],
                               device const float4*      bounds   [[buffer(3)]],   // per static: lo, hi
                               device const PhysicsShape* shapes  [[buffer(4)]],
                               device const uint*        heads    [[buffer(5)]],
                               device const uint*        next     [[buffer(6)]],
                               device PhysicsPair*       pairs    [[buffer(7)]],
                               device uint*              counts   [[buffer(8)]],
                               uint i [[thread_position_in_grid]])
{
    if (i >= p.counts.x) return;
    PhysicsBody b = bodies[i];
    float3 x = b.position.xyz;
    float r = physReach(b, p);
    float d2s[PHYS_PAIRS];
    uint ids[PHYS_PAIRS];
    uint count = 0;
    for (uint s = 0; s < p.counts.y; ++s) {
        PhysicsBody st = statics[s];
        bool touches;
        if (shapes[st.info.x].info.x == PHYS_PLANE) {
            touches = dot(x - st.position.xyz, quatRotate(st.rotation, float3(0, 1, 0))) < r;
        } else {
            float3 nearest = clamp(x, bounds[2 * s].xyz, bounds[2 * s + 1].xyz);
            touches = length_squared(x - nearest) < r * r;
        }
        if (touches) physKeepNearest(d2s, ids, count, -1.0f, s | PHYS_STATIC);
    }
    int3 c = physCell(x, p.grid.x);
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                for (uint j = heads[physHash(c + int3(dx, dy, dz), p.counts.w)]; j != PHYS_NONE; j = next[j]) {
                    if (j == i) continue;
                    PhysicsBody o = bodies[j];
                    if (b.info.w == j + 1 || o.info.w == i + 1) continue;   // joined: PhysicsWorld.joined
                    float reach = r + physReach(o, p);
                    float d2 = physDistance2(o.position.xyz, x);
                    if (d2 < reach * reach) physKeepNearest(d2s, ids, count, d2, j);
                }
            }
        }
    }
    counts[i] = count;
    for (uint k = 0; k < count; ++k) {
        PhysicsPair pair = {ids[k], 0, 0, 0};
        pairs[i * PHYS_PAIRS + k] = pair;
    }
}

inline bool physMoves(PhysicsBody b) { return b.position.w > 0.0f && (b.info.y & PHYS_ASLEEP) == 0; }

// PhysicsCPU.stirs: body b moves fast enough to wake what it touches.
inline bool physStirs(PhysicsBody b, constant PhysicsParams& p) {
    if (!physMoves(b)) return false;
    if (length(b.velocity.xyz) > p.rolling.z) return true;
    float rate = length(b.angular.xyz);
    if (!(rate > 1e-9f)) return false;
    float3 k = b.angular.xyz / rate;
    float w = dot(k, physInvInertia(b.rotation, b.invInertia.xyz, k));   // physTurnWeight, for a body that moves
    return w > 0.0f && rate * min(sqrt(b.position.w / w), PHYS_GYRATION) > p.rolling.w;
}

// Each entry's owner (PhysicsCPU.link), and whether the body wakes (PhysicsCPU.wake): something it touches stirs.
kernel void physicsLinkKernel(constant PhysicsParams&   p      [[buffer(0)]],
                              device const PhysicsBody* bodies [[buffer(1)]],
                              device PhysicsPair*       pairs  [[buffer(2)]],
                              device const uint*        counts [[buffer(3)]],
                              device uint*              wake   [[buffer(4)]],
                              uint i [[thread_position_in_grid]])
{
    if (i >= p.counts.x) return;
    bool asleep = (bodies[i].info.y & PHYS_ASLEEP) != 0, wakes = false;
    for (uint n = 0; n < counts[i]; ++n) {
        uint e = i * PHYS_PAIRS + n, partner = pairs[e].partner;
        if (asleep && !wakes && (partner & PHYS_STATIC) == 0) wakes = physStirs(bodies[partner], p);
        if ((partner & PHYS_STATIC) != 0) { pairs[e].link = e; continue; }
        if (partner > i) {   // the owner keeps it only if the partner has it too (PhysicsCPU.link)
            uint link = PHYS_NONE;
            for (uint m = 0; m < counts[partner]; ++m) {
                if (pairs[partner * PHYS_PAIRS + m].partner == i) { link = e; break; }
            }
            pairs[e].link = link;
            continue;
        }
        uint link = PHYS_NONE;
        for (uint m = 0; m < counts[partner]; ++m) {
            if (pairs[partner * PHYS_PAIRS + m].partner == i) { link = partner * PHYS_PAIRS + m; break; }
        }
        pairs[e].link = link;
    }
    wake[i] = wakes ? 1u : 0u;
}

inline PhysicsBody physPartner(uint code, device const PhysicsBody* bodies, device const PhysicsBody* statics) {
    return (code & PHYS_STATIC) != 0 ? statics[code & ~PHYS_STATIC] : bodies[code];
}

// MARK: - Particles' broad phase

constant uint PHYS_NEIGHBOURS = 16, PHYS_COLLIDERS = 8;   // PhysicsWorld.maxNeighbours, maxColliders

inline float physParticleReach(PhysicsParticle q, constant PhysicsParams& p) {
    return q.position.w + min(length(q.velocity.xyz), p.particleGrid.y) * p.grid.w + p.grid.y;
}

kernel void physicsParticleInsertKernel(constant PhysicsParams&       p         [[buffer(0)]],
                                        device const PhysicsParticle* particles [[buffer(1)]],
                                        device atomic_uint*           heads     [[buffer(2)]],
                                        device uint*                  next      [[buffer(3)]],
                                        uint i [[thread_position_in_grid]])
{
    if (i >= p.particles.x) return;
    uint h = physHash(physCell(particles[i].position.xyz, p.particleGrid.x), p.particles.y);
    next[i] = atomic_exchange_explicit(&heads[h], i, memory_order_relaxed);
}

// PhysicsCPU.particleBroadPhase: the nearest neighbours (the lower first of equals), and the colliders through the
// bodies' grid (whose cells hold any body a particle's reach can meet in the 27 around it) and the statics.
kernel void physicsParticleNeighboursKernel(constant PhysicsParams&       p          [[buffer(0)]],
                                            device const PhysicsParticle* particles  [[buffer(1)]],
                                            device const uint*            heads      [[buffer(2)]],
                                            device const uint*            next       [[buffer(3)]],
                                            device uint*                  neighbours [[buffer(4)]],
                                            device uint*                  counts     [[buffer(5)]],
                                            device const PhysicsBody*     bodies     [[buffer(6)]],
                                            device const PhysicsBody*     statics    [[buffer(7)]],
                                            device const float4*          bounds     [[buffer(8)]],
                                            device const PhysicsShape*    shapes     [[buffer(9)]],
                                            device const uint*            bodyHeads  [[buffer(10)]],
                                            device const uint*            bodyNext   [[buffer(11)]],
                                            device uint*                  colliders  [[buffer(12)]],
                                            device uint*                  colliderCounts [[buffer(13)]],
                                            uint i [[thread_position_in_grid]])
{
    if (i >= p.particles.x) return;
    PhysicsParticle q = particles[i];
    float3 x = q.position.xyz;
    float r = physParticleReach(q, p);
    float d2s[PHYS_NEIGHBOURS];
    uint ids[PHYS_NEIGHBOURS];
    uint count = 0;
    int3 c = physCell(x, p.particleGrid.x);
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                for (uint j = heads[physHash(c + int3(dx, dy, dz), p.particles.y)]; j != PHYS_NONE; j = next[j]) {
                    if (j == i) continue;
                    PhysicsParticle o = particles[j];
                    if (((q.info.y | o.info.y) & PHYS_CLOTH) != 0) continue;   // cloths only meet colliders
                    float reach = r + physParticleReach(o, p);
                    float d2 = length_squared(o.position.xyz - x);
                    if (!(d2 < reach * reach)) continue;
                    if (count == PHYS_NEIGHBOURS && !(d2 < d2s[count - 1] || (d2 == d2s[count - 1] && j < ids[count - 1]))) continue;
                    uint at = count;
                    while (at > 0 && (d2 < d2s[at - 1] || (d2 == d2s[at - 1] && j < ids[at - 1]))) --at;
                    if (at > 0 && d2s[at - 1] == d2 && ids[at - 1] == j) continue;   // through two cells of one bucket
                    for (uint k = min(count, PHYS_NEIGHBOURS - 1); k > at; --k) { d2s[k] = d2s[k - 1]; ids[k] = ids[k - 1]; }
                    d2s[at] = d2;
                    ids[at] = j;
                    count = min(count + 1, PHYS_NEIGHBOURS);
                }
            }
        }
    }
    counts[i] = count;
    for (uint k = 0; k < count; ++k) neighbours[i * PHYS_NEIGHBOURS + k] = ids[k];

    uint keys[PHYS_COLLIDERS];
    uint touching = 0;
    for (uint s = 0; s < p.counts.y; ++s) {
        PhysicsBody st = statics[s];
        bool touches;
        if (shapes[st.info.x].info.x == PHYS_PLANE) {
            touches = dot(x - st.position.xyz, quatRotate(st.rotation, float3(0, 1, 0))) < r;
        } else {
            float3 nearest = clamp(x, bounds[2 * s].xyz, bounds[2 * s + 1].xyz);
            touches = length_squared(x - nearest) < r * r;
        }
        if (touches) physKeep(keys, touching, s | PHYS_STATIC, PHYS_COLLIDERS);
    }
    if (p.counts.x > 0) {
        int3 cb = physCell(x, p.grid.x);
        for (int dz = -1; dz <= 1; ++dz) {
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    for (uint j = bodyHeads[physHash(cb + int3(dx, dy, dz), p.counts.w)]; j != PHYS_NONE; j = bodyNext[j]) {
                        PhysicsBody b = bodies[j];
                        float reach = r + physReach(b, p);
                        if (length_squared(b.position.xyz - x) < reach * reach) physKeep(keys, touching, j, PHYS_COLLIDERS);
                    }
                }
            }
        }
    }
    colliderCounts[i] = touching;
    for (uint k = 0; k < touching; ++k) colliders[i * PHYS_COLLIDERS + k] = keys[k] ^ PHYS_STATIC;
}

// A run of a step's substeps (PhysicsGPU.Group): the narrow phase runs before each.
struct PhysicsGroup {
    uint first, count;   // its substeps
    uint last;           // 1: the step's last run, which settles
    uint pad;
};

// A SIMD group per entry: an owned entry's contacts (PhysicsCPU.narrowPhase), at the start of a step and again every
// PhysicsWorld.contactRefresh substeps. The entry is the same for all of a
// group's lanes, so a group that has nothing to do leaves together.
kernel void physicsNarrowKernel(constant PhysicsParams&    p        [[buffer(0)]],
                                device const PhysicsBody*  bodies   [[buffer(1)]],
                                device const PhysicsBody*  statics  [[buffer(2)]],
                                device const PhysicsShape* shapes   [[buffer(3)]],
                                device const float4*       samples  [[buffer(4)]],
                                device const SDFScene&     sdf      [[buffer(5)]],
                                device PhysicsPair*        pairs    [[buffer(6)]],
                                device const uint*         counts   [[buffer(7)]],
                                device PhysicsContact*     contacts [[buffer(8)]],
                                constant PhysicsGroup&     group    [[buffer(9)]],
                                uint t [[thread_position_in_grid]],
                                ushort lane [[thread_index_in_simdgroup]],
                                ushort lanes [[threads_per_simdgroup]])
{
    uint e = t / lanes, i = e / PHYS_PAIRS, n = e % PHYS_PAIRS;
    if (i >= p.counts.x || n >= counts[i] || pairs[e].link != e) return;
    PhysicsBody a = bodies[i], b = physPartner(pairs[e].partner, bodies, statics);
    // A refresh: the coloured pairs (with contacts at the step's start) of which a body moves.
    if (group.first > 0 && (pairs[e].pad == PHYS_NONE || (!physMoves(a) && !physMoves(b)))) return;
    float closing = (length(a.velocity.xyz) + length(b.velocity.xyz) + length(a.angular.xyz) * a.invInertia.w
                     + length(b.angular.xyz) * b.invInertia.w) * p.grid.w;
    PhysicsShapes w = {shapes, samples, sdf};
    PhysManifold m = physCollide(w, a, b, p.grid.y + closing, lane, lanes);
    if (lane != 0) return;
    PhysPose pa = physPose(a), pb = physPose(b);
    pairs[e].contacts = m.count;
    for (uint c = 0; c < m.count; ++c) {
        PhysicsContact out;
        out.normal = float4(m.p[c].n, m.p[c].separation);
        out.anchorA = float4(pa.toBody(m.p[c].pa), m.p[c].ra);
        out.anchorB = float4(pb.toBody(m.p[c].pb), m.p[c].rb);
        out.lambda = float4(0.0f);
        contacts[e * PHYS_CONTACTS + c] = out;
    }
}

// MARK: - Substeps

// A sleeping body woken this step wakes (first substep), then a moving body goes by its velocity and gravity.
// (The held body, `held`, is woken and slowed too: PhysicsCPU.integrate.)
inline void physIntegrate(constant PhysicsParams& p, device PhysicsBody* bodies, device uint* wake, uint i, bool held) {
    PhysicsBody b = bodies[i];
    if (wake[i] != 0 || held) {
        b.info.y &= ~PHYS_ASLEEP;
        b.prevPosition.w = 0.0f;
        wake[i] = 0;
    }
    if (physMoves(b)) {
        float h = p.gravity.w;
        b.prevPosition = float4(b.position.xyz, b.prevPosition.w);
        b.prevRotation = b.rotation;
        float decay = held ? max(1.0f - PHYS_HOLD_DAMPING * h, 0.0f) : 1.0f;
        b.angular = float4(b.angular.xyz * decay, b.angular.w);
        float3 v = b.velocity.xyz * decay + p.gravity.xyz * h;
        float speed = length(v);
        if (speed > p.grid.z) v *= p.grid.z / speed;
        b.velocity = float4(v, b.velocity.w);
        b.position = float4(b.position.xyz + v * h, b.position.w);
        b.rotation = physTurn(b.rotation, b.angular.xyz * h);
    }
    bodies[i] = b;
}

struct PhysPoints { float3 pa, pb, ra, rb; };

inline PhysPoints physPoints(PhysicsContact c, PhysicsBody a, PhysicsBody b, bool previous) {
    float3 n = c.normal.xyz;
    bool am = previous && physMoves(a), bm = previous && physMoves(b);
    float3 xa = am ? a.prevPosition.xyz : a.position.xyz, xb = bm ? b.prevPosition.xyz : b.position.xyz;
    PhysPoints out;
    out.ra = quatRotate(am ? a.prevRotation : a.rotation, c.anchorA.xyz) - n * c.anchorA.w;
    out.rb = quatRotate(bm ? b.prevRotation : b.rotation, c.anchorB.xyz) + n * c.anchorB.w;
    out.pa = xa + out.ra;
    out.pb = xb + out.rb;
    return out;
}

inline float physWeight(PhysicsBody b, float3 r, float3 n) {
    if (!physMoves(b)) return 0.0f;
    float3 rn = cross(r, n);
    return b.position.w + dot(rn, physInvInertia(b.rotation, b.invInertia.xyz, rn));
}

struct PhysPush { float3 impulse; float lambda, speed; float3 ra, rb; };

// PhysicsCPU.contactPush.
inline PhysPush physContactPush(PhysicsContact c, PhysicsBody a, PhysicsBody b, float h) {
    float3 n = c.normal.xyz;
    PhysPoints q = physPoints(c, a, b, false);
    float3 va = a.velocity.xyz + cross(a.angular.xyz, q.ra), vb = b.velocity.xyz + cross(b.angular.xyz, q.rb);
    PhysPush out = {float3(0.0f), 0.0f, dot(va - vb, n), q.ra, q.rb};
    float depth = max(dot(q.pa - q.pb, n), -PHYS_PUSH_SPEED * h);
    if (!(depth < 0.0f)) return out;
    float w = physWeight(a, q.ra, n) + physWeight(b, q.rb, n);
    if (!(w > 0.0f)) return out;
    float lambda = -depth / w;
    float3 impulse = n * lambda;
    PhysPoints o = physPoints(c, a, b, true);
    float3 slide = (q.pa - o.pa) - (q.pb - o.pb);
    float3 tangent = slide - n * dot(slide, n);
    float l = length(tangent);
    if (l > 1e-7f) {
        float3 t = tangent / l;
        float wt = physWeight(a, q.ra, t) + physWeight(b, q.rb, t);
        float friction = sqrt(a.velocity.w * b.velocity.w);
        if (wt > 0.0f && l / wt < friction * lambda) impulse -= t * (l / wt);
    }
    out.impulse = impulse;
    out.lambda = lambda;
    return out;
}

// PhysicsCPU.shove: body b (if it moves) by impulse at lever arm r.
inline void physShove(thread PhysicsBody& b, float3 impulse, float3 r) {
    if (!physMoves(b)) return;
    b.position = float4(b.position.xyz + impulse * b.position.w, b.position.w);
    b.rotation = physTurn(b.rotation, physInvInertia(b.rotation, b.invInertia.xyz, cross(r, impulse)));
}

// PhysicsCPU.kick: body b's velocities (if it moves) by impulse at lever arm r and angular impulse twist.
inline void physKick(thread PhysicsBody& b, float3 impulse, float3 r, float3 twist) {
    if (!physMoves(b)) return;
    b.velocity = float4(b.velocity.xyz + impulse * b.position.w, b.velocity.w);
    b.angular = float4(b.angular.xyz + physInvInertia(b.rotation, b.invInertia.xyz, cross(r, impulse) + twist), b.angular.w);
}

// PhysicsCPU.solvePositions for pair e: its contacts one after the other, each pushing both bodies.
inline void physPushPair(constant PhysicsParams& p, device PhysicsBody* bodies, device const PhysicsBody* statics,
                         device const PhysicsPair* pairs, device PhysicsContact* contacts, uint e) {
    uint i = e / PHYS_PAIRS, code = pairs[e].partner;
    PhysicsBody a = bodies[i], b = physPartner(code, bodies, statics);
    for (uint c = 0; c < pairs[e].contacts; ++c) {
        uint ci = e * PHYS_CONTACTS + c;
        PhysPush push = physContactPush(contacts[ci], a, b, p.gravity.w);
        contacts[ci].lambda = float4(push.lambda, push.speed, 0.0f, 0.0f);
        if (!(push.lambda > 0.0f)) continue;
        physShove(a, push.impulse, push.ra);
        physShove(b, -push.impulse, push.rb);
    }
    bodies[i] = a;
    if ((code & PHYS_STATIC) == 0) bodies[code] = b;
}

// PhysicsCPU.hold: the held body i, right after it is integrated (by its thread).
inline void physHold(device PhysicsBody* bodies, constant PhysicsGrab& g, uint i) {
    PhysicsBody b = bodies[i];
    if (!physMoves(b)) return;
    float3 r = quatRotate(b.rotation, g.anchor.xyz);
    float3 gap = g.target.xyz - (b.position.xyz + r);
    float l = length(gap);
    if (!(l > 1e-7f)) return;
    float3 n = gap / l;
    float w = physWeight(b, r, n);
    if (!(w > 0.0f)) return;
    physShove(b, n * (l * PHYS_HOLD_PULL / w), r);
    bodies[i] = b;
}

// The end of PhysicsCPU.solvePositions for body i: its velocities from how far the substep took it.
inline void physTakeVelocities(constant PhysicsParams& p, device PhysicsBody* bodies, uint i) {
    PhysicsBody b = bodies[i];
    if (!physMoves(b)) return;
    float h = p.gravity.w;
    b.velocity = float4((b.position.xyz - b.prevPosition.xyz) / h, b.velocity.w);
    float4 dq = quatMul(b.rotation, physConj(b.prevRotation));
    if (dq.w < 0.0f) dq = -dq;
    b.angular = float4(2.0f * dq.xyz / h, b.angular.w);
    bodies[i] = b;
}

// PhysicsCPU.turnWeight.
inline float physTurnWeight(PhysicsBody b, float3 k) {
    return physMoves(b) ? dot(k, physInvInertia(b.rotation, b.invInertia.xyz, k)) : 0.0f;
}

struct PhysKick { bool valid; float3 impulse, twist, ra, rb; };

// PhysicsCPU.contactKick.
inline PhysKick physContactKick(PhysicsContact c, PhysicsBody a, PhysicsBody b, constant PhysicsParams& p) {
    PhysKick out = {false, float3(0.0f), float3(0.0f), float3(0.0f), float3(0.0f)};
    float lambda = c.lambda.x;
    if (!(lambda > 0.0f)) return out;
    float3 n = c.normal.xyz;
    float h = p.gravity.w;
    PhysPoints q = physPoints(c, a, b, false);
    float3 va = a.velocity.xyz + cross(a.angular.xyz, q.ra), vb = b.velocity.xyz + cross(b.angular.xyz, q.rb);
    float3 v = va - vb;
    float vn = dot(v, n);
    float3 vt = v - n * vn;
    float3 dv = float3(0.0f);
    float slide = length(vt);
    if (slide > 1e-6f) {
        float friction = sqrt(a.velocity.w * b.velocity.w);
        float pushed = lambda * (physWeight(a, q.ra, n) + physWeight(b, q.rb, n)) / h;
        dv -= vt / slide * min(friction * pushed, slide);
    }
    float before = c.lambda.y;
    float e = abs(before) <= 2.0f * length(p.gravity.xyz) * h ? 0.0f : max(a.angular.w, b.angular.w);
    dv += n * (-vn + max(-e * before, 0.0f));
    float l = length(dv);
    if (l > 1e-7f) {
        float w = physWeight(a, q.ra, dv / l) + physWeight(b, q.rb, dv / l);
        if (w > 0.0f) out.impulse = dv / w;
    }
    float3 spin = a.angular.xyz - b.angular.xyz, about = n * dot(spin, n);
    for (uint k = 0; k < 2; ++k) {
        float3 part = k == 0 ? spin - about : about;
        float resistance = k == 0 ? p.rolling.x : p.rolling.y;
        float speed = length(part);
        if (!(speed > 1e-6f)) continue;
        float3 axis = part / speed;
        float w = physTurnWeight(a, axis) + physTurnWeight(b, axis);
        if (!(w > 0.0f)) continue;
        out.twist -= axis * min(speed / w, resistance * lambda / h);
    }
    out.valid = any(out.impulse != 0.0f) || any(out.twist != 0.0f);
    out.ra = q.ra;
    out.rb = q.rb;
    return out;
}

// PhysicsCPU.solveVelocities for pair e.
inline void physKickPair(constant PhysicsParams& p, device PhysicsBody* bodies, device const PhysicsBody* statics,
                         device const PhysicsPair* pairs, device const PhysicsContact* contacts, uint e) {
    uint i = e / PHYS_PAIRS, code = pairs[e].partner;
    PhysicsBody a = bodies[i], b = physPartner(code, bodies, statics);
    for (uint c = 0; c < pairs[e].contacts; ++c) {
        PhysKick kick = physContactKick(contacts[e * PHYS_CONTACTS + c], a, b, p);
        if (!kick.valid) continue;
        physKick(a, kick.impulse, kick.ra, kick.twist);
        physKick(b, -kick.impulse, kick.rb, -kick.twist);
    }
    bodies[i] = a;
    if ((code & PHYS_STATIC) == 0) bodies[code] = b;
}

// MARK: - Joints

// PhysicsCPU.swivel.
inline void physSwivel(thread PhysicsBody& a, thread PhysicsBody& b, float3 correction) {
    float angle = length(correction);
    if (!(angle > 1e-7f)) return;
    float3 k = correction / angle;
    float w = physTurnWeight(a, k) + physTurnWeight(b, k);
    if (!(w > 0.0f)) return;
    float3 impulse = k * (angle / w);
    if (physMoves(a)) a.rotation = physTurn(a.rotation, physInvInertia(a.rotation, a.invInertia.xyz, impulse));
    if (physMoves(b)) b.rotation = physTurn(b.rotation, -physInvInertia(b.rotation, b.invInertia.xyz, impulse));
}

// PhysicsCPU.limitAngle.
inline float3 physLimitAngle(float3 n, float3 n1, float3 n2, float lo, float hi) {
    float phi = atan2(dot(cross(n1, n2), n), dot(n1, n2));
    return n * (phi - min(max(phi, lo), hi));
}

// PhysicsCPU.across.
inline float3 physAcross(float3 v, float3 n) {
    float3 u = v - n * dot(v, n);
    float l = length(u);
    return l > 1e-6f ? u / l : float3(0.0f);
}

// PhysicsCPU.solveJoint, by the thread that has joint k (no other of its colour shares a body).
inline void physSolveJoint(device PhysicsBody* bodies, PhysicsJoint j) {
    PhysicsBody a = bodies[j.info.x], b = bodies[j.info.y];
    if (!physMoves(a) && !physMoves(b)) return;
    float lo = j.axisA.w, hi = j.axisB.w;
    float3 axisA = quatRotate(a.rotation, j.axisA.xyz), axisB = quatRotate(b.rotation, j.axisB.xyz);
    float3 bend = cross(axisA, axisB);
    float sine = length(bend);
    if (j.info.z == PHYS_HINGE) {
        if (sine > 1e-6f) physSwivel(a, b, bend / sine * atan2(sine, dot(axisA, axisB)));
        axisA = quatRotate(a.rotation, j.axisA.xyz);
        float3 n1 = physAcross(quatRotate(a.rotation, j.referenceA.xyz), axisA);
        float3 n2 = physAcross(quatRotate(b.rotation, j.referenceB.xyz), axisA);
        physSwivel(a, b, physLimitAngle(axisA, n1, n2, lo, hi));
    } else {
        float swing = atan2(sine, dot(axisA, axisB));
        if (sine > 1e-6f && swing > j.referenceA.w) physSwivel(a, b, bend / sine * (swing - j.referenceA.w));
        axisA = quatRotate(a.rotation, j.axisA.xyz);
        axisB = quatRotate(b.rotation, j.axisB.xyz);
        float3 mid = axisA + axisB;
        float l = length(mid);
        if (l > 1e-6f) {
            float3 n = mid / l;
            float3 n1 = physAcross(quatRotate(a.rotation, j.referenceA.xyz), n);
            float3 n2 = physAcross(quatRotate(b.rotation, j.referenceB.xyz), n);
            physSwivel(a, b, physLimitAngle(n, n1, n2, lo, hi));
        }
    }
    float3 ra = quatRotate(a.rotation, j.anchorA.xyz), rb = quatRotate(b.rotation, j.anchorB.xyz);
    float3 gap = (b.position.xyz + rb) - (a.position.xyz + ra);
    float l = length(gap);
    if (l > 1e-7f) {
        float3 n = gap / l;
        float w = physWeight(a, ra, n) + physWeight(b, rb, n);
        if (w > 0.0f) {
            physShove(a, n * (l / w), ra);
            physShove(b, -n * (l / w), rb);
        }
    }
    bodies[j.info.x] = a;
    bodies[j.info.y] = b;
}

// PhysicsCPU.anchorTurnWeight.
inline float physAnchorTurnWeight(PhysicsBody b, float3 k, float3 r) {
    float w = physTurnWeight(b, k);
    if (!(w > 0.0f)) return 0.0f;
    return 1.0f / (1.0f / w + length_squared(cross(k, r)) / b.position.w);
}

// PhysicsCPU.dampJoint.
inline void physDampJoint(device PhysicsBody* bodies, PhysicsJoint j, float h) {
    PhysicsBody a = bodies[j.info.x], b = bodies[j.info.y];
    float3 relative = b.angular.xyz - a.angular.xyz;
    float speed = length(relative);
    if (!(speed > 1e-6f)) return;
    float3 k = relative / speed;
    float3 ra = quatRotate(a.rotation, j.anchorA.xyz), rb = quatRotate(b.rotation, j.anchorB.xyz);
    float wa = physAnchorTurnWeight(a, k, ra), wb = physAnchorTurnWeight(b, k, rb);
    if (!(wa + wb > 0.0f)) return;
    float impulse = speed * min(j.referenceB.w * h, 1.0f) / (wa + wb);
    if (wa > 0.0f) {
        float3 turn = k * (impulse * wa);
        a.angular = float4(a.angular.xyz + turn, a.angular.w);
        a.velocity = float4(a.velocity.xyz - cross(turn, ra), a.velocity.w);
    }
    if (wb > 0.0f) {
        float3 turn = -k * (impulse * wb);
        b.angular = float4(b.angular.xyz + turn, b.angular.w);
        b.velocity = float4(b.velocity.xyz - cross(turn, rb), b.velocity.w);
    }
    bodies[j.info.x] = a;
    bodies[j.info.y] = b;
}

// MARK: - Colours

// PhysicsCPU.priority (the high half; the entry is the low).
inline uint physPairPriority(uint e) {
    uint x = e * 0x9E3779B1u;
    x ^= x >> 16;
    x *= 0x85EBCA6Bu;
    x ^= x >> 13;
    return x;
}

// Whether entry e is a pair the substeps solve: an owned one with contacts.
inline bool physLive(device const PhysicsPair* pairs, device const uint* counts, uint e) {
    return e % PHYS_PAIRS < counts[e / PHYS_PAIRS] && pairs[e].link == e && pairs[e].contacts > 0;
}

// Whether uncoloured pair e outranks every other uncoloured pair with contacts body i is in.
inline bool physOutranks(device const PhysicsPair* pairs, device const uint* counts, uint i, uint e) {
    uint mine = physPairPriority(e);
    for (uint n = 0; n < counts[i]; ++n) {
        uint q = pairs[i * PHYS_PAIRS + n].link;
        if (q == PHYS_NONE || q == e || pairs[q].contacts == 0 || pairs[q].pad != PHYS_NONE) continue;
        uint theirs = physPairPriority(q);
        if (theirs > mine || (theirs == mine && q > e)) return false;
    }
    return true;
}

// The colours the pairs with contacts body i is in have.
inline uint physColoursAround(device const PhysicsPair* pairs, device const uint* counts, uint i, uint e) {
    uint used = 0;
    for (uint n = 0; n < counts[i]; ++n) {
        uint q = pairs[i * PHYS_PAIRS + n].link;
        if (q == PHYS_NONE || q == e || pairs[q].contacts == 0 || pairs[q].pad >= PHYS_COLOURS) continue;
        used |= 1u << pairs[q].pad;
    }
    return used;
}

// PhysicsCPU.colourPairs, by the threadgroup, once a step: the pairs by colour onto `order` (in any order within one:
// its pairs share no body), into `colouring` where each colour begins, then the colours and how many pairs the rounds
// left (pad = leftover: one thread takes them in entry order). `live` holds the pairs with contacts, `won` a round's.
inline void physColourPairs(device PhysicsPair* pairs, device const uint* counts, device uint* order, device uint* won,
                            device uint* live, device uint* colouring, threadgroup atomic_uint* tally,
                            threadgroup atomic_uint* perColour, uint entries, uint t, uint width) {
    if (t == 0) atomic_store_explicit(&tally[0], 0u, memory_order_relaxed);
    for (uint c = t; c < PHYS_COLOURS; c += width) atomic_store_explicit(&perColour[c], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint e = t; e < entries; e += width) {
        pairs[e].pad = PHYS_NONE;
        if (physLive(pairs, counts, e)) live[atomic_fetch_add_explicit(&tally[0], 1u, memory_order_relaxed)] = e;
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    uint lives = atomic_load_explicit(&tally[0], memory_order_relaxed);
    for (uint round = 0; round < PHYS_ROUNDS; ++round) {
        if (t == 0) atomic_store_explicit(&tally[1], 0u, memory_order_relaxed);
        for (uint j = t; j < lives; j += width) {
            uint e = live[j], code = pairs[e].partner;
            won[e] = pairs[e].pad == PHYS_NONE && physOutranks(pairs, counts, e / PHYS_PAIRS, e)
                     && ((code & PHYS_STATIC) != 0 || physOutranks(pairs, counts, code, e)) ? 1u : 0u;
        }
        threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
        // A round's winners share no body, nor any pair beside one: each reads colours no other is writing.
        for (uint j = t; j < lives; j += width) {
            uint e = live[j], code = pairs[e].partner;
            if (won[e] != 0) {
                uint used = physColoursAround(pairs, counts, e / PHYS_PAIRS, e);
                if ((code & PHYS_STATIC) == 0) used |= physColoursAround(pairs, counts, code, e);
                pairs[e].pad = ctz(~used);
            } else if (pairs[e].pad == PHYS_NONE) {
                atomic_fetch_add_explicit(&tally[1], 1u, memory_order_relaxed);
            }
        }
        threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
        bool done = atomic_load_explicit(&tally[1], memory_order_relaxed) == 0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (done) break;
    }
    if (t == 0) atomic_store_explicit(&tally[1], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint j = t; j < lives; j += width) {
        uint e = live[j];
        if (pairs[e].pad == PHYS_NONE) {
            pairs[e].pad = PHYS_LEFTOVER;
            atomic_fetch_add_explicit(&tally[1], 1u, memory_order_relaxed);
        } else {
            atomic_fetch_add_explicit(&perColour[pairs[e].pad], 1u, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    if (t == 0) {
        uint at = 0, colours = 0;
        for (uint c = 0; c < PHYS_COLOURS; ++c) {
            colouring[c] = at;
            uint k = atomic_load_explicit(&perColour[c], memory_order_relaxed);
            if (k > 0) colours = c + 1;
            atomic_store_explicit(&perColour[c], at, memory_order_relaxed);
            at += k;
        }
        colouring[PHYS_COLOURS] = at;
        for (uint c = colours; c < PHYS_COLOURS; ++c) colouring[c] = at;
        colouring[PHYS_COLOURS + 1] = colours;
        colouring[PHYS_COLOURS + 2] = atomic_load_explicit(&tally[1], memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
    for (uint j = t; j < lives; j += width) {
        uint e = live[j], c = pairs[e].pad;
        if (c < PHYS_COLOURS) order[atomic_fetch_add_explicit(&perColour[c], 1u, memory_order_relaxed)] = e;
    }
    threadgroup_barrier(mem_flags::mem_device);
}

// The pairs the colouring left, one after another in entry order, by thread 0.
inline bool physLeftover(device const PhysicsPair* pairs, uint e) { return pairs[e].pad == PHYS_LEFTOVER; }

// PhysicsCPU.still.
inline bool physStill(PhysicsBody b, float4 position, float4 rotation, constant PhysicsParams& p) {
    float moved = length(b.position.xyz - position.xyz);
    float3 turn = quatMul(b.rotation, physConj(rotation)).xyz;
    float sine = length(turn);
    if (!(moved < p.sleep.x * p.grid.w)) return false;
    if (!(sine > 1e-9f)) return true;
    float w = physTurnWeight(b, turn / sine);
    return !(w > 0.0f) || 2.0f * sine * min(sqrt(b.position.w / w), PHYS_GYRATION) < p.sleep.y * p.grid.w;
}

// MARK: - Particles' substeps

inline void physIntegrateParticle(constant PhysicsParams& p, device PhysicsParticle* particles, uint i) {
    PhysicsParticle q = particles[i];
    if (!(q.prevPosition.w > 0.0f)) return;   // a pinned cloth vertex stays
    float h = p.gravity.w;
    q.prevPosition = float4(q.position.xyz, q.prevPosition.w);
    float drag = (q.info.y & PHYS_CLOTH) != 0 ? max(1.0f - p.particleGrid.z * h, 0.0f) : 1.0f;
    float3 v = q.velocity.xyz * drag + p.gravity.xyz * h;
    float speed = length(v);
    if (speed > p.grid.z) v *= p.grid.z / speed;
    q.velocity = float4(v, q.velocity.w);
    q.position = float4(q.position.xyz + v * h, q.position.w);
    particles[i] = q;
}

// PhysicsCPU.particlePush.
inline float3 physParticlePush(float3 n, float overlap, float3 slide, float friction) {
    float3 push = n * overlap;
    float3 tangent = slide - n * dot(slide, n);
    float l = length(tangent);
    if (l > 1e-7f) push -= tangent * min(friction * overlap / l, 1.0f);
    return push;
}

// PhysicsCPU.solveParticles for particle i: from `src`, into `dst`, against the bodies as they are now.
inline void physSolveParticle(constant PhysicsParams& p, PhysicsShapes w, device const PhysicsParticle* src,
                              device PhysicsParticle* dst, device const uint* neighbours, device const uint* counts,
                              device const uint* colliders, device const uint* colliderCounts,
                              device const PhysicsBody* bodies, device const PhysicsBody* statics, uint i) {
    float h = p.gravity.w;
    PhysicsParticle q = src[i];
    if (!(q.prevPosition.w > 0.0f)) { dst[i] = q; return; }
    float3 x = q.position.xyz, moved = x - q.prevPosition.xyz;
    float wq = q.prevPosition.w;
    float3 shared = float3(0.0f);
    float sharedCount = 0.0f;
    for (uint n = 0; n < counts[i]; ++n) {
        PhysicsParticle o = src[neighbours[i * PHYS_NEIGHBOURS + n]];
        float3 d = x - o.position.xyz;
        float dist = length(d);
        float overlap = min(q.position.w + o.position.w - dist, PHYS_PUSH_SPEED * h);
        if (!(overlap > 0.0f) || !(dist > 1e-6f)) continue;
        float share = wq / (wq + o.prevPosition.w);
        float3 slide = moved - (o.position.xyz - o.prevPosition.xyz);
        shared += physParticlePush(d / dist, overlap, slide, sqrt(q.velocity.w * o.velocity.w)) * share;
        sharedCount += 1.0f;
    }
    float3 held = float3(0.0f);
    float heldCount = 0.0f;
    bool shoved = false;
    for (uint n = 0; n < colliderCounts[i]; ++n) {
        PhysicsBody b = physPartner(colliders[i * PHYS_COLLIDERS + n], bodies, statics);
        PhysPose pose = physPose(b);
        uint shape = b.info.x;
        float3 local = pose.toBody(x);
        float depth = physDistance(w, shape, local) - q.position.w;
        if (!(depth < 0.0f)) continue;
        float3 normal = pose.direction(physGradient(w, shape, local));
        float3 surface = b.velocity.xyz + cross(b.angular.xyz, x - pose.position);
        held += physParticlePush(normal, min(-depth, PHYS_PUSH_SPEED * h), moved - surface * h, sqrt(q.velocity.w * b.velocity.w));
        heldCount += 1.0f;
        shoved = shoved || physMoves(b);
    }
    float3 y = x;
    if (sharedCount > 0.0f) y += shared / sharedCount;
    if (heldCount > 0.0f) y += held / heldCount;
    // PhysicsCPU.rests.
    if (sharedCount + heldCount > 0.0f && !shoved && (q.info.y & PHYS_CLOTH) == 0 && length(y - q.prevPosition.xyz) < p.particleGrid.w * h) {
        y = q.prevPosition.xyz;
    }
    q.position = float4(y, q.position.w);
    q.velocity = float4((y - q.prevPosition.xyz) / h, q.velocity.w);
    dst[i] = q;
}

// PhysicsCPU.solveCloth for one constraint: an XPBD distance constraint, in place (its colour's others share no vertex).
inline void physSolveConstraint(device PhysicsParticle* particles, PhysicsConstraint k, float h) {
    float wa = particles[k.a].prevPosition.w, wb = particles[k.b].prevPosition.w;
    if (!(wa + wb > 0.0f)) return;
    float3 d = particles[k.a].position.xyz - particles[k.b].position.xyz;
    float l = length(d);
    if (!(l > 1e-9f)) return;
    float lambda = -(l - k.rest) / (wa + wb + k.compliance / (h * h));
    float3 push = d / l * lambda;
    particles[k.a].position.xyz += push * wa;
    particles[k.b].position.xyz -= push * wb;
}

// A run of substeps, then (the step's last) the settling, in one threadgroup: its threads take the bodies, the
// particles or a colour's pairs in turn, and a barrier between the stages stands in for the dispatch boundary (as
// dispatches of their own, 16 substeps' stages took 6.6 ms for 96 bodies on the M1 Max). First the pairs the narrow
// phase just found are coloured (the step's first run); then each substep solves them a colour at a time, in place
// (PhysicsCPU.step).
kernel void physicsSubstepsKernel(constant PhysicsParams&   p        [[buffer(0)]],
                                  device PhysicsBody*       bodies   [[buffer(1)]],
                                  device float4*            start    [[buffer(2)]],   // per body: the step's first pose
                                  device const PhysicsBody* statics  [[buffer(3)]],
                                  device PhysicsPair*       pairs    [[buffer(4)]],
                                  device const uint*        counts   [[buffer(5)]],
                                  device PhysicsContact*    contacts [[buffer(6)]],
                                  device uint*              wake     [[buffer(7)]],
                                  constant PhysicsGroup&    group    [[buffer(8)]],
                                  device uint*              order    [[buffer(9)]],
                                  device uint*              won      [[buffer(10)]],
                                  device uint*              live     [[buffer(11)]],
                                  device uint*              colouring [[buffer(23)]],
                                  constant PhysicsGrab&     grab     [[buffer(24)]],
                                  device PhysicsParticle*   particles [[buffer(12)]],
                                  device PhysicsParticle*   particlesOut [[buffer(13)]],
                                  device const uint*        neighbours [[buffer(14)]],
                                  device const uint*        neighbourCounts [[buffer(15)]],
                                  device const uint*        colliders [[buffer(16)]],
                                  device const uint*        colliderCounts [[buffer(17)]],
                                  device const PhysicsShape* shapes [[buffer(18)]],
                                  device const float4*      samples [[buffer(19)]],
                                  device const SDFScene&    sdf [[buffer(20)]],
                                  device const PhysicsConstraint* constraints [[buffer(21)]],
                                  device const uint*        colourStarts [[buffer(22)]],
                                  device const PhysicsJoint* joints [[buffer(25)]],
                                  device const uint*        jointStarts [[buffer(26)]],
                                  device const uint2*       ragdolls [[buffer(27)]],   // first body, count
                                  uint t [[thread_index_in_threadgroup]],
                                  uint width [[threads_per_threadgroup]])
{
    uint n = p.counts.x, np = p.particles.x, entries = n * PHYS_PAIRS;
    PhysicsShapes w = {shapes, samples, sdf};
    threadgroup atomic_uint tally[2], perColour[PHYS_COLOURS];
    if (group.first == 0) physColourPairs(pairs, counts, order, won, live, colouring, tally, perColour, entries, t, width);
    uint colours = colouring[PHYS_COLOURS + 1];
    bool leftovers = colouring[PHYS_COLOURS + 2] != 0;
    device const uint* starts = colouring;
    if (group.first == 0) {
        for (uint i = t; i < n; i += width) {
            start[2 * i] = bodies[i].position;
            start[2 * i + 1] = bodies[i].rotation;
        }
        // A ragdoll wakes whole (PhysicsCPU.wake): if any of its bodies is awake, woken or held, the rest wake.
        threadgroup_barrier(mem_flags::mem_device);
        for (uint r = t; r < p.cloth.w; r += width) {
            uint first = ragdolls[r].x, end = first + ragdolls[r].y;
            bool any = false;
            for (uint i = first; i < end && !any; ++i) {
                any = physMoves(bodies[i]) || wake[i] != 0 || (grab.target.w > 0.0f && grab.body == i);
            }
            if (!any) continue;
            for (uint i = first; i < end; ++i) if ((bodies[i].info.y & PHYS_ASLEEP) != 0) wake[i] = 1;
        }
        threadgroup_barrier(mem_flags::mem_device);
    }
    // The particles take the same substeps, their stages beside the bodies' (one-way: against the bodies as this
    // substep moved them, before their contacts push them apart).
    for (uint s = 0; s < group.count; ++s) {
        for (uint i = t; i < n; i += width) {
            bool held = grab.target.w > 0.0f && grab.body == i;
            physIntegrate(p, bodies, wake, i, held);
            if (held) physHold(bodies, grab, i);
        }
        for (uint i = t; i < np; i += width) physIntegrateParticle(p, particles, i);
        threadgroup_barrier(mem_flags::mem_device);
        // The cloths' constraints, a colour at a time (PhysicsCPU.solveCloth).
        for (uint c = 0; c < p.cloth.y; ++c) {
            for (uint k = colourStarts[c] + t; k < colourStarts[c + 1]; k += width) physSolveConstraint(particles, constraints[k], p.gravity.w);
            threadgroup_barrier(mem_flags::mem_device);
        }
        for (uint i = t; i < np; i += width) {
            physSolveParticle(p, w, particles, particlesOut, neighbours, neighbourCounts, colliders, colliderCounts, bodies, statics, i);
        }
        threadgroup_barrier(mem_flags::mem_device);
        // The joints, a colour at a time, then the contacts (PhysicsCPU.solvePositions).
        for (uint pass = 0; pass < PHYS_JOINT_ITERATIONS; ++pass) {
            for (uint c = 0; c < p.cloth.z; ++c) {
                for (uint k = jointStarts[c] + t; k < jointStarts[c + 1]; k += width) physSolveJoint(bodies, joints[k]);
                threadgroup_barrier(mem_flags::mem_device);
            }
        }
        for (uint c = 0; c < colours; ++c) {
            for (uint j = starts[c] + t; j < starts[c + 1]; j += width) physPushPair(p, bodies, statics, pairs, contacts, order[j]);
            threadgroup_barrier(mem_flags::mem_device);
        }
        if (leftovers) {
            if (t == 0) {
                for (uint e = 0; e < entries; ++e) if (physLeftover(pairs, e)) physPushPair(p, bodies, statics, pairs, contacts, e);
            }
            threadgroup_barrier(mem_flags::mem_device);
        }
        for (uint i = t; i < n; i += width) physTakeVelocities(p, bodies, i);
        for (uint i = t; i < np; i += width) particles[i] = particlesOut[i];
        threadgroup_barrier(mem_flags::mem_device);
        for (uint c = 0; c < colours; ++c) {
            for (uint j = starts[c] + t; j < starts[c + 1]; j += width) physKickPair(p, bodies, statics, pairs, contacts, order[j]);
            threadgroup_barrier(mem_flags::mem_device);
        }
        if (leftovers) {
            if (t == 0) {
                for (uint e = 0; e < entries; ++e) if (physLeftover(pairs, e)) physKickPair(p, bodies, statics, pairs, contacts, e);
            }
            threadgroup_barrier(mem_flags::mem_device);
        }
        for (uint c = 0; c < p.cloth.z; ++c) {
            for (uint k = jointStarts[c] + t; k < jointStarts[c + 1]; k += width) physDampJoint(bodies, joints[k], p.gravity.w);
            threadgroup_barrier(mem_flags::mem_device);
        }
    }
    if (group.last == 0) return;
    // PhysicsCPU.settle: the timers, then who sleeps (a sleeping body's timer is past the sleep time, so a partner
    // falling asleep beside it reads the same either way).
    for (uint i = t; i < n; i += width) {
        PhysicsBody b = bodies[i];
        if (physMoves(b)) bodies[i].prevPosition.w = physStill(b, start[2 * i], start[2 * i + 1], p) ? b.prevPosition.w + p.grid.w : 0.0f;
    }
    threadgroup_barrier(mem_flags::mem_device);
    // Who may sleep, into `wake` (free until the next step's link kernel writes it)...
    for (uint i = t; i < n; i += width) {
        PhysicsBody b = bodies[i];
        bool settled = physMoves(b) && b.prevPosition.w > p.sleep.z;
        for (uint k = 0; k < counts[i] && settled; ++k) {
            uint e = i * PHYS_PAIRS + k, partner = pairs[e].partner, link = pairs[e].link;
            if ((partner & PHYS_STATIC) != 0 || link == PHYS_NONE || pairs[link].contacts == 0) continue;
            float4 o = bodies[partner].prevPosition;
            float mass = bodies[partner].position.w;
            settled = !(mass > 0.0f && o.w <= p.sleep.z * 0.5f);
        }
        wake[i] = settled ? 1u : 0u;
    }
    threadgroup_barrier(mem_flags::mem_device);
    // ...a ragdoll whole or not at all...
    for (uint r = t; r < p.cloth.w; r += width) {
        uint first = ragdolls[r].x, end = first + ragdolls[r].y;
        bool all = true;
        for (uint i = first; i < end && all; ++i) all = !physMoves(bodies[i]) || wake[i] != 0;
        if (!all) for (uint i = first; i < end; ++i) wake[i] = 0;
    }
    threadgroup_barrier(mem_flags::mem_device);
    // ...and they sleep.
    for (uint i = t; i < n; i += width) {
        PhysicsBody b = bodies[i];
        bool sleeps = wake[i] != 0;
        wake[i] = 0;
        if (!sleeps) continue;
        b.info.y |= PHYS_ASLEEP;
        b.velocity = float4(0.0f, 0.0f, 0.0f, b.velocity.w);
        b.angular = float4(0.0f, 0.0f, 0.0f, b.angular.w);
        bodies[i] = b;
    }
}

// MARK: - Drawing

struct PhysicsPoseParams {
    uint bodies;
    uint descriptorStride;   // Metal's tracer: the instance descriptors' stride (their matrix comes first); 0: none
    uint pad0, pad1;
};
static_assert(sizeof(PhysicsPoseParams) == 16, "PhysicsPoseParams: PhysicsGPU.PoseParams");

// A body's instance transform (PhysicsWorld.transform): its shape space in the world.
inline float4x4 physTransform(float3 x, float4 q, PhysicsShape shape) {
    float4 r = quatMul(q, physConj(shape.comRotation));
    float3 c0 = quatRotate(r, float3(1, 0, 0)), c1 = quatRotate(r, float3(0, 1, 0)), c2 = quatRotate(r, float3(0, 0, 1));
    float3 t = x - (c0 * shape.comPosition.x + c1 * shape.comPosition.y + c2 * shape.comPosition.z);
    return float4x4(float4(c0, 0), float4(c1, 0), float4(c2, 0), float4(t, 1));
}

// Every body's instance record for this frame (and Metal's descriptor), where the steps put it; last frame's pose is
// its previous transform. The pose also goes to the slot's snapshot, which the CPU reads once the frame is done.
kernel void physicsPoseKernel(constant PhysicsPoseParams&  pp          [[buffer(0)]],
                              device const PhysicsBody*    bodies      [[buffer(1)]],
                              device const PhysicsShape*   shapes      [[buffer(2)]],
                              device float4*               lastPose    [[buffer(3)]],   // per body: position, rotation
                              device float4*               snapshot    [[buffer(4)]],
                              device InstanceData*         instances   [[buffer(5)]],
                              device uchar*                descriptors [[buffer(6)]],
                              uint i [[thread_position_in_grid]])
{
    if (i >= pp.bodies) return;
    PhysicsBody b = bodies[i];
    PhysicsShape shape = shapes[b.info.x];
    float4x4 m = physTransform(b.position.xyz, b.rotation, shape);
    float4x4 previous = physTransform(lastPose[2 * i].xyz, lastPose[2 * i + 1], shape);
    lastPose[2 * i] = float4(b.position.xyz, 0.0f);
    lastPose[2 * i + 1] = b.rotation;
    snapshot[2 * i] = float4(b.position.xyz, 0.0f);
    snapshot[2 * i + 1] = b.rotation;
    // The inverse of a rotation R and a translation t: R^T and -R^T t; the normal matrix is its transpose.
    float3x3 r = float3x3(m[0].xyz, m[1].xyz, m[2].xyz);
    float3x3 rt = transpose(r);
    float3 it = -(rt * m[3].xyz);
    float4x4 inverse = float4x4(float4(rt[0], 0), float4(rt[1], 0), float4(rt[2], 0), float4(it, 1));
    uint instance = b.info.z;
    instances[instance].transform = m;
    instances[instance].prevTransform = previous;
    instances[instance].normalMatrix = transpose(inverse);
    if (pp.descriptorStride != 0) {
        device float* d = (device float*)(descriptors + instance * pp.descriptorStride);
        for (uint c = 0; c < 4; ++c) {
            for (uint row = 0; row < 3; ++row) d[c * 3 + row] = m[c][row];
        }
    }
}

// Every particle's instance record for the frame (a translation: a ball has no turn to show), and Metal's descriptor.
kernel void physicsParticlePoseKernel(constant PhysicsPoseParams&    pp          [[buffer(0)]],
                                      device const PhysicsParticle*  particles   [[buffer(1)]],
                                      device float4*                 lastPose    [[buffer(2)]],
                                      device InstanceData*           instances   [[buffer(3)]],
                                      device uchar*                  descriptors [[buffer(4)]],
                                      uint i [[thread_position_in_grid]])
{
    if (i >= pp.bodies) return;   // (here: the particles)
    PhysicsParticle q = particles[i];
    if (q.info.x == PHYS_NONE) return;   // a cloth's vertex: physicsClothMeshKernel draws it
    float3 x = q.position.xyz, before = lastPose[i].xyz;
    lastPose[i] = float4(x, 0.0f);
    uint instance = q.info.x;
    instances[instance].transform = float4x4(float4(1, 0, 0, 0), float4(0, 1, 0, 0), float4(0, 0, 1, 0), float4(x, 1));
    instances[instance].prevTransform = float4x4(float4(1, 0, 0, 0), float4(0, 1, 0, 0), float4(0, 0, 1, 0), float4(before, 1));
    // The inverse's transpose: identity with the negated translation along the bottom row.
    instances[instance].normalMatrix = float4x4(float4(1, 0, 0, -x.x), float4(0, 1, 0, -x.y), float4(0, 0, 1, -x.z), float4(0, 0, 0, 1));
    if (pp.descriptorStride != 0) {
        device float* d = (device float*)(descriptors + instance * pp.descriptorStride);
        d[0] = 1; d[1] = 0; d[2] = 0; d[3] = 0; d[4] = 1; d[5] = 0; d[6] = 0; d[7] = 0; d[8] = 1;
        d[9] = x.x; d[10] = x.y; d[11] = x.z;
    }
}

// A cloth's mesh (PhysicsWorld.clothTable): its first particle, its grid, its first vertex, and its last frame's
// vertices' offset.
struct PhysicsCloth {
    uint4 grid;       // first particle, columns, rows, first vertex
    uint4 previous;   // x = prevOffset
};

// Every cloth vertex into the scene's vertex buffer, as the crowd's skinning writes its poses: last frame's place
// first (motion vectors), then this frame's, and its normal across its neighbours in the grid (the mesh's winding:
// along a row, then down a column). The refits follow.
kernel void physicsClothMeshKernel(constant uint&                count     [[buffer(0)]],
                                   device const PhysicsParticle* particles [[buffer(1)]],
                                   device const PhysicsCloth*    cloths    [[buffer(2)]],
                                   device float3*                positions [[buffer(3)]],
                                   device float3*                normals   [[buffer(4)]],
                                   uint i [[thread_position_in_grid]])
{
    if (i >= count) return;
    PhysicsParticle q = particles[i];
    if ((q.info.y & PHYS_CLOTH) == 0) return;
    PhysicsCloth cloth = cloths[q.info.w];
    uint v = i - cloth.grid.x, columns = cloth.grid.y, rows = cloth.grid.z;
    uint c = v % columns, r = v / columns;
    uint first = cloth.grid.x;
    float3 left = particles[first + r * columns + (c > 0 ? c - 1 : c)].position.xyz;
    float3 right = particles[first + r * columns + min(c + 1, columns - 1)].position.xyz;
    float3 up = particles[first + (r > 0 ? r - 1 : r) * columns + c].position.xyz;
    float3 down = particles[first + min(r + 1, rows - 1) * columns + c].position.xyz;
    uint at = q.info.z;
    positions[at + cloth.previous.x] = positions[at];
    positions[at] = q.position.xyz;
    normals[at] = physDirection(cross(down - up, right - left));
}

// MARK: - Hair (PhysicsHair.swift)

struct PhysicsStrand {
    uint4  info;        // x = body (PHYS_NONE: the world's), y = first vertex, z = vertices, w = 1: still on a sleeping body
    float4 stiffness;   // global at the root, at the tip, local, DFTL damping
    float4 across;      // body space; w = length
    float4 pad;
};
static_assert(sizeof(PhysicsStrand) == 64, "PhysicsStrand: GPUHairStrand");

struct PhysicsHairVertex {
    float4 position;    // w = radius
    float4 previous;    // w = rest length of the segment before it
    float4 velocity;    // w = friction
    float4 rest;        // root body's space; w = global stiffness
};
static_assert(sizeof(PhysicsHairVertex) == 64, "PhysicsHairVertex: GPUHairVertex");

struct PhysicsHairParams {
    float4 gravity;     // w = substep
    float4 wind;        // xyz = velocity, w = gustiness
    uint4  counts;      // strands, bodies, statics, substeps
    float4 air;         // drag, rest speed, (the CPU's step time: the GPU keeps its own clock), 0
};
static_assert(sizeof(PhysicsHairParams) == 64, "PhysicsHairParams: GPUHairParams");

struct PhysicsHairGroup {
    uint4  counts;      // first guide, guides, drawn per guide, a guide's vertices
    uint4  mesh;        // first control point, last frame's offset, seed
    float4 shape;       // spread, clumping, curl
    float4 pad;
};
static_assert(sizeof(PhysicsHairGroup) == 64, "PhysicsHairGroup: GPUHairGroup");

constant uint PHYS_HAIR_VERTICES = 16, PHYS_HAIR_COLLIDERS = 8;   // PhysicsWorld.maxHairVertices, maxHairColliders
constant float PHYS_HAIR_PUSH = 0.01f, PHYS_HAIR_REACH = 0.15f;  // PhysicsWorld.hairPush, hairReach

// PhysicsWorld.breeze, transport, between.
inline float3 physBreeze(float4 wind, float3 x, float t) {
    float along = dot(x, float3(0.7f, 0.2f, 0.5f));
    float gust = 1.0f + wind.w * (0.6f * sin(1.1f * t - 1.7f * along) + 0.4f * sin(2.9f * t + 2.3f * x.y));
    return wind.xyz * gust;
}
inline float3 physTransport(float3 a, float3 b, float3 v) {
    float c = dot(a, b);
    if (!(c > -0.999f)) return v;
    float3 k = cross(a, b);
    return v * c + cross(k, v) + k * (dot(k, v) / (1.0f + c));
}
inline PhysPose physBetween(float3 p0, float4 q0, float3 p1, float4 q1, float alpha) {
    float4 q = dot(q0, q1) < 0.0f ? -q1 : q1;
    PhysPose pose;
    pose.position = p0 + (p1 - p0) * alpha;
    pose.rotation = physNormalize(q0 + (q - q0) * alpha);
    return pose;
}

// PhysicsWorld.pushOut.
inline float3 physHairPushOut(PhysicsShapes w, float3 y, PhysicsHairVertex hv, thread const uint* colliders, uint count,
                              device const PhysicsBody* bodies, device const PhysicsBody* statics, float h) {
    for (uint c = 0; c < count; ++c) {
        PhysicsBody b = physPartner(colliders[c], bodies, statics);
        PhysPose pose = physPose(b);
        uint shape = b.info.x;
        float3 local = pose.toBody(y);
        float depth = physDistance(w, shape, local) - hv.position.w;
        if (!(depth < 0.0f)) continue;
        float3 normal = pose.direction(physGradient(w, shape, local));
        float3 surface = b.velocity.xyz + cross(b.angular.xyz, y - pose.position);
        y += physParticlePush(normal, min(-depth, PHYS_HAIR_PUSH), y - hv.previous.xyz - surface * h, sqrt(hv.velocity.w * b.velocity.w));
    }
    return y;
}

// PhysicsWorld.stepStrand: a step of strand i, after the bodies' (`start`: their poses when it began), at the clock's
// time; its vertices one after another.
kernel void physicsHairKernel(constant PhysicsParams&       p          [[buffer(0)]],
                              constant PhysicsHairParams&   hp         [[buffer(1)]],
                              device PhysicsStrand*         strands    [[buffer(2)]],
                              device PhysicsHairVertex*     v          [[buffer(3)]],
                              device const PhysicsBody*     bodies     [[buffer(4)]],
                              device const float4*          start      [[buffer(5)]],
                              device const PhysicsBody*     statics    [[buffer(6)]],
                              device const float4*          bounds     [[buffer(7)]],
                              device const PhysicsShape*    shapes     [[buffer(8)]],
                              device const float4*          samples    [[buffer(9)]],
                              device const SDFScene&        sdf        [[buffer(10)]],
                              device const float*           clock      [[buffer(11)]],
                              uint s [[thread_position_in_grid]])
{
    if (s >= hp.counts.x) return;
    PhysicsShapes w = {shapes, samples, sdf};
    PhysicsStrand strand = strands[s];
    uint first = strand.info.y, n = strand.info.z, body = strand.info.x;
    bool asleep = body != PHYS_NONE && (bodies[body].info.y & PHYS_ASLEEP) != 0;
    if (asleep && strand.info.w != 0) return;
    float3 p0 = float3(0.0f), p1 = float3(0.0f);
    float4 q0 = float4(0, 0, 0, 1), q1 = q0;
    if (body != PHYS_NONE) {
        p0 = start[2 * body].xyz;
        q0 = start[2 * body + 1];
        p1 = bodies[body].position.xyz;
        q1 = bodies[body].rotation;
    }
    // The colliders near it (PhysicsWorld.hairColliders): statics, then bodies, the first PHYS_HAIR_COLLIDERS.
    PhysPose end;
    end.position = p1;
    end.rotation = q1;
    float3 centre = end.toWorld(v[first].rest.xyz);
    float reach = strand.across.w + PHYS_HAIR_REACH;
    uint colliders[PHYS_HAIR_COLLIDERS];
    uint count = 0;
    for (uint k = 0; k < hp.counts.z && count < PHYS_HAIR_COLLIDERS; ++k) {
        PhysicsBody st = statics[k];
        bool touches;
        if (shapes[st.info.x].info.x == PHYS_PLANE) {
            touches = dot(centre - st.position.xyz, quatRotate(st.rotation, float3(0, 1, 0))) < reach;
        } else {
            float3 nearest = clamp(centre, bounds[2 * k].xyz, bounds[2 * k + 1].xyz);
            touches = length_squared(centre - nearest) < reach * reach;
        }
        if (touches) colliders[count++] = k | PHYS_STATIC;
    }
    for (uint j = 0; j < hp.counts.y && count < PHYS_HAIR_COLLIDERS; ++j) {
        float r = reach + physReach(bodies[j], p);
        if (length_squared(bodies[j].position.xyz - centre) < r * r) colliders[count++] = j;
    }
    float h = hp.gravity.w;
    uint subs = hp.counts.w;
    float air = min(hp.air.x * h, 1.0f);
    float3 corrections[PHYS_HAIR_VERTICES + 1], before[PHYS_HAIR_VERTICES];
    for (uint i = 0; i < n; ++i) before[i] = v[first + i].position.xyz;
    for (uint sub = 0; sub < subs; ++sub) {
        PhysPose pose = physBetween(p0, q0, p1, q1, float(sub + 1) / float(subs));
        float t = clock[0] + h * float(sub + 1);
        float3 root = pose.toWorld(v[first].rest.xyz);
        v[first].previous = float4(v[first].position.xyz, v[first].previous.w);
        v[first].position = float4(root, v[first].position.w);
        for (uint i = first + 1; i < first + n; ++i) {
            float3 x = v[i].position.xyz;
            float3 vel = v[i].velocity.xyz;
            vel += (physBreeze(hp.wind, x, t) - vel) * air + hp.gravity.xyz * h;
            v[i].previous = float4(x, v[i].previous.w);
            float3 y = x + vel * h;
            y += (pose.toWorld(v[i].rest.xyz) - y) * v[i].rest.w;
            v[i].position = float4(y, v[i].position.w);
        }
        float3 restBefore = float3(0.0f);
        for (uint i = first + 1; i < first + n; ++i) {
            float3 a = v[i - 1].position.xyz, x = v[i].position.xyz;
            float3 restDir = physDirection(pose.direction(v[i].rest.xyz - v[i - 1].rest.xyz));
            float3 want = i == first + 1 ? restDir : physTransport(restBefore, physDirection(a - v[i - 2].position.xyz), restDir);
            float3 d = (want * length(x - a) - (x - a)) * strand.stiffness.z;
            if (i == first + 1) {
                v[i].position = float4(x + d, v[i].position.w);
            } else {
                v[i].position = float4(x + 0.5f * d, v[i].position.w);
                v[i - 1].position = float4(a - 0.5f * d, v[i - 1].position.w);
            }
            restBefore = restDir;
        }
        for (uint i = first + 1; i < first + n; ++i) {
            float3 a = v[i - 1].position.xyz, x = v[i].position.xyz;
            float3 led = a + physDirection(x - a) * v[i].previous.w;
            corrections[i - first] = led - x;
            float3 y = physHairPushOut(w, led, v[i], colliders, count, bodies, statics, h);
            y = a + physDirection(y - a) * v[i].previous.w;
            v[i].position = float4(y, v[i].position.w);
        }
        corrections[n] = float3(0.0f);
        for (uint i = first + 1; i < first + n; ++i) {
            float3 moved = v[i].position.xyz - v[i].previous.xyz;
            v[i].velocity = float4((moved - strand.stiffness.w * corrections[i - first + 1]) / h, v[i].velocity.w);
        }
        v[first].velocity = float4((root - v[first].previous.xyz) / h, v[first].velocity.w);
    }
    uint still = 0;
    if (asleep) {
        still = 1;
        for (uint i = 0; i < n; ++i) if (!(length(v[first + i].position.xyz - before[i]) < hp.air.y * h * float(subs))) still = 0;
    }
    strands[s].info.w = still;
}

// The hair's clock: a step on (after the step's hair).
kernel void physicsHairTickKernel(constant PhysicsHairParams& hp [[buffer(0)]], device float* clock [[buffer(1)]]) {
    clock[0] += hp.gravity.w * float(hp.counts.w);
}

// Back to the start: the vertices, the strands' stillness, the clock.
kernel void physicsHairResetKernel(constant PhysicsHairParams&     hp       [[buffer(0)]],
                                   device const PhysicsHairVertex* initial  [[buffer(1)]],
                                   device PhysicsHairVertex*       vertices [[buffer(2)]],
                                   device PhysicsStrand*           strands  [[buffer(3)]],
                                   device float*                   clock    [[buffer(4)]],
                                   constant uint&                  count    [[buffer(5)]],
                                   uint i [[thread_position_in_grid]])
{
    if (i < count) vertices[i] = initial[i];
    if (i < hp.counts.x) strands[i].info.w = 0;
    if (i == 0) clock[0] = 0.0f;
}

// PhysicsWorld.drawnStrand: drawn strand r of a group, into the scene's vertex buffer (last frame's first, as the cloth's
// vertices are), ahead of the refits.
kernel void physicsHairCurvesKernel(constant PhysicsHairGroup&      g         [[buffer(0)]],
                                    device const PhysicsStrand*     strands   [[buffer(1)]],
                                    device const PhysicsHairVertex* v         [[buffer(2)]],
                                    device const PhysicsBody*       bodies    [[buffer(3)]],
                                    device float3*                  positions [[buffer(4)]],
                                    uint r [[thread_position_in_grid]])
{
    uint perGuide = g.counts.z, n = g.counts.w;
    if (r >= g.counts.y * perGuide) return;
    PhysicsStrand strand = strands[g.counts.x + r / perGuide];
    uint first = strand.info.y;
    float4 rotation = strand.info.x == PHYS_NONE ? float4(0, 0, 0, 1) : bodies[strand.info.x].rotation;
    uint k = r % perGuide;
    uint h0 = pcgHash(g.mesh.z ^ pcgHash(r)), h1 = pcgHash(h0);
    float radius = k == 0 ? 0.0f : g.shape.x * sqrt(float(h0 & 0xFFFFu)) / 256.0f;
    float angle = float(h1 & 0xFFFFu) * (2.0f * M_PI_F / 65536.0f);
    float3 t = physDirection(v[first + 1].position.xyz - v[first].position.xyz);
    float3 b1 = quatRotate(rotation, strand.across.xyz);
    b1 = physDirection(b1 - t * dot(b1, t));
    uint base = g.mesh.x + r * (n + 2);
    float3 before = float3(0.0f), second = float3(0.0f), last = float3(0.0f);
    for (uint i = 0; i < n; ++i) {
        float3 x = v[first + i].position.xyz;
        if (i > 0) {
            float3 next = physDirection(v[first + min(i + 1, n - 1)].position.xyz - v[first + (i + 1 < n ? i : i - 1)].position.xyz);
            b1 = physTransport(t, next, b1);
            t = next;
        }
        float3 b2 = cross(t, b1);
        float f = float(i) / float(n - 1);
        float phase = angle + f * 12.566f;
        float offset = radius * (1.0f - g.shape.y * f);
        float curl = g.shape.z * f;
        float3 point = x + (b1 * cos(angle) + b2 * sin(angle)) * offset + (b1 * cos(phase) + b2 * sin(phase)) * curl;
        positions[base + 1 + i + g.mesh.y] = positions[base + 1 + i];
        positions[base + 1 + i] = point;
        if (i == 0) before = point;
        if (i == 1) second = point;
        if (i == n - 2) last = point;
        if (i == n - 1) {
            positions[base + n + 1 + g.mesh.y] = positions[base + n + 1];
            positions[base + n + 1] = 2.0f * point - last;
        }
    }
    positions[base + g.mesh.y] = positions[base];
    positions[base] = 2.0f * before - second;
}
