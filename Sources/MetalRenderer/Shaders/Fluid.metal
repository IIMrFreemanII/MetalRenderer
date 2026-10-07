// ---------------------------------------------------------------------------------------------
// Liquids (PhysicsFluid.swift): PBF and MLS-MPM, a liquid's group of substeps before each of the bodies' groups
// ---------------------------------------------------------------------------------------------

// The stages are PhysicsFluidCPU.swift's, in its order. Every sum many threads add to is an integer (fixed point:
// FluidWorld's scales): MPM's grid, the bodies' impulses, the cells' counts. PBF's particles are sorted by cell every
// substep, each cell's in the order they had (a count, a scan, a scatter, then each cell sorted): every neighbour sum
// runs in the order the CPU's does, and a run is the same every time.

struct FluidParticle {
    float4 position;    // w = MPM: J
    float4 velocity;
    float4 affine0, affine1, affine2;   // MPM: C by rows; PBF: affine0 = vorticity
};
static_assert(sizeof(FluidParticle) == 80, "FluidParticle: GPUFluidParticle");

struct FluidParams {
    float4 gravity;     // w = substep
    float4 lo;          // w = cell
    float4 hi;          // w = 1 / cell
    uint4  dims;        // cells (PBF) or nodes (MPM) along x, y, z; w = all
    uint4  counts;      // capacity, substeps a group, static colliders, solver (1: MPM)
    float4 material;    // rest density, a particle's mass, bulk modulus (PBF: how far under rest density it pulls), gamma
    float4 viscosity;   // Carreau mu0, mu inf, lambda, n
    float4 pbf;         // h, relaxation, s_corr k, 1 / W(dq); MPM: tension (a share of K), bulk viscosity (Pa s)
    float4 pbf2;        // XSPH, vorticity confinement, friction, stickiness
    float4 fixed;       // scales: mass, momentum, impulse; top speed
    float4 nozzle;      // w = radius
    float4 direction;   // w = speed
    uint4  emission;    // a layer's particles, ticks between layers x 256, the first tick, PBF iterations
    float4 extra;       // a particle's radius, spacing, volume, the group's length
};
static_assert(sizeof(FluidParams) == 224, "FluidParams: GPUFluidParams");

constant uint FLUID_MAX_BODIES = 64;   // FluidWorld.maxBodies
// A liquid's state: the group's clock (groups run, this one's included), particles poured, poured before this
// group, bodies near; then the bodies near (their indices).
struct FluidState {
    uint4 counts;
    uint  bodies[FLUID_MAX_BODIES];
};

// The colliders a liquid meets: the physics' bodies and statics.
struct FluidColliders {
    device const PhysicsBody* bodies;
    device const PhysicsBody* statics;
    device const float4*      bounds;
    device const uint*        staticList;
    uint                      staticCount;
    PhysicsShapes             w;
};

inline int fluidFixed(float v, float s) { return int(rint(clamp(v * s, -1073741824.0f, 1073741824.0f))); }

// FluidSystem.poured.
inline uint fluidPoured(constant FluidParams& p, uint clock) {
    if (clock < p.emission.z) return 0;
    uint layers = (clock - p.emission.z) * 256u / p.emission.y + 1u;
    return min(layers * p.emission.x, p.counts.x);
}

inline PhysicsBody fluidCollider(FluidColliders c, uint code) {
    return (code & PHYS_STATIC) != 0 ? c.statics[code & ~PHYS_STATIC] : c.bodies[code];
}

// PhysicsFluidCPU.fluidNear.
inline bool fluidNear(FluidColliders c, uint code, float3 x, float r) {
    if ((code & PHYS_STATIC) != 0) {
        uint s = code & ~PHYS_STATIC;
        PhysicsBody st = c.statics[s];
        if (c.w.shapes[st.info.x].info.x == PHYS_PLANE) return dot(x - st.position.xyz, quatRotate(st.rotation, float3(0, 1, 0))) < r;
        float3 nearest = clamp(x, c.bounds[2 * s].xyz, c.bounds[2 * s + 1].xyz);
        return length_squared(x - nearest) < r * r;
    }
    PhysicsBody b = c.bodies[code];
    float reach = b.invInertia.w + r;
    return length_squared(x - b.position.xyz) < reach * reach;
}

// The collider list's code number k: the statics, then the bodies near.
inline uint fluidCode(FluidColliders c, device const FluidState& st, uint k) {
    return k < c.staticCount ? (c.staticList[k] | PHYS_STATIC) : st.bodies[k - c.staticCount];
}

// PhysicsFluidCPU.fluidImpulse.
inline void fluidImpulse(FluidColliders c, device atomic_int* impulses, uint code, float3 j, float3 x, float scale) {
    if ((code & PHYS_STATIC) != 0) return;
    PhysicsBody b = c.bodies[code];
    if (!(b.position.w > 0.0f) || (b.info.y & PHYS_KINEMATIC) != 0) return;
    float3 l = cross(x - b.position.xyz, j);
    device atomic_int* at = impulses + 8 * code;
    atomic_fetch_add_explicit(at + 0, fluidFixed(j.x, scale), memory_order_relaxed);
    atomic_fetch_add_explicit(at + 1, fluidFixed(j.y, scale), memory_order_relaxed);
    atomic_fetch_add_explicit(at + 2, fluidFixed(j.z, scale), memory_order_relaxed);
    atomic_fetch_add_explicit(at + 4, fluidFixed(l.x, scale), memory_order_relaxed);
    atomic_fetch_add_explicit(at + 5, fluidFixed(l.y, scale), memory_order_relaxed);
    atomic_fetch_add_explicit(at + 6, fluidFixed(l.z, scale), memory_order_relaxed);
}

// PhysicsFluidCPU.fluidPushOut.
inline float3 fluidPushOut(FluidColliders c, device const FluidState& st, device atomic_int* impulses, float3 x, float3 start,
                           float r, float h, float friction, float mass, constant FluidParams& p) {
    float3 y = x;
    float cap = p.fixed.w * h;
    uint count = c.staticCount + st.counts.w;
    for (uint k = 0; k < count; ++k) {
        uint code = fluidCode(c, st, k);
        if (!fluidNear(c, code, y, r)) continue;
        PhysicsBody b = fluidCollider(c, code);
        PhysPose pose = physPose(b);
        float3 local = pose.toBody(y);
        float depth = physDistance(c.w, b.info.x, local) - r;
        if (!(depth < 0.0f)) continue;
        float3 n = pose.direction(physGradient(c.w, b.info.x, local));
        float3 surface = b.velocity.xyz + cross(b.angular.xyz, y - pose.position);
        float3 push = physParticlePush(n, min(-depth, cap), (y - start) - surface * h, friction);
        y += push;
        if (mass > 0.0f) fluidImpulse(c, impulses, code, -push * (mass / h), y, p.fixed.z);
    }
    return y;
}

#define FLUID_WORLD \
    constant PhysicsParams&    world      [[buffer(19)]], \
    device const PhysicsBody*  bodies     [[buffer(20)]], \
    device const PhysicsBody*  statics    [[buffer(21)]], \
    device const float4*       bounds     [[buffer(22)]], \
    device const PhysicsShape* shapes     [[buffer(23)]], \
    device const float4*       samples    [[buffer(24)]], \
    device const SDFScene&     sdf        [[buffer(25)]], \
    device const uint*         staticList [[buffer(26)]], \
    device atomic_int*         impulses   [[buffer(27)]]
#define FLUID_COLLIDERS FluidColliders c = {bodies, statics, bounds, staticList, p.counts.z, {shapes, samples, sdf}}

// MARK: - The group

kernel void fluidResetKernel(device FluidState& st [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    if (i == 0) st.counts = uint4(0);
}

// The group's start (one thread): the clock, what is poured by now, the bodies near (PhysicsWorld.fluidBodies).
kernel void fluidBeginKernel(constant FluidParams&     p      [[buffer(0)]],
                             device FluidState&        st     [[buffer(1)]],
                             constant PhysicsParams&   world  [[buffer(19)]],
                             device const PhysicsBody* bodies [[buffer(20)]])
{
    uint clock = st.counts.x;
    uint near = 0;
    for (uint i = 0; i < world.counts.x && near < FLUID_MAX_BODIES; ++i) {
        PhysicsBody b = bodies[i];
        float r = b.invInertia.w + p.lo.w;
        float3 nearest = clamp(b.position.xyz, p.lo.xyz, p.hi.xyz);
        if (length_squared(b.position.xyz - nearest) < r * r) st.bodies[near++] = i;
    }
    st.counts = uint4(clock + 1, fluidPoured(p, clock), st.counts.y, near);
}

// PhysicsWorld.pour: the particles poured this group.
kernel void fluidPourKernel(constant FluidParams&    p         [[buffer(0)]],
                            device const FluidState& st        [[buffer(1)]],
                            device FluidParticle*    particles [[buffer(2)]],
                            device const float4*     layer     [[buffer(13)]],
                            uint t [[thread_position_in_grid]])
{
    uint i = st.counts.z + t;
    if (i >= st.counts.y) return;
    uint clock = st.counts.x - 1, k = i / p.emission.x, j = i % p.emission.x;
    float ticks = float((clock - p.emission.z) * 256u - k * p.emission.y) / 256.0f;
    float3 x = p.nozzle.xyz + layer[j].xyz + p.direction.xyz * (p.direction.w * ticks * p.extra.w);
    float margin = p.counts.w == 1 ? 2.0f * p.lo.w : p.extra.x;
    x = clamp(x, p.lo.xyz + margin, p.hi.xyz - margin);
    FluidParticle q;
    q.position = float4(x, 1.0f);
    q.velocity = float4(p.direction.xyz * p.direction.w, 0.0f);
    q.affine0 = q.affine1 = q.affine2 = float4(0.0f);
    particles[i] = q;
}

// fluidApply: PhysicsWorld.applyFluidImpulses, a thread a body.
kernel void fluidApplyKernel(constant FluidParams&    p        [[buffer(0)]],
                             device const FluidState& st       [[buffer(1)]],   // the first liquid's
                             device const uint4*      drops    [[buffer(2)]],   // x = how many; then (body, tick) pairs
                             constant PhysicsParams&  world    [[buffer(19)]],
                             device PhysicsBody*      moving   [[buffer(20)]],
                             device atomic_int*       impulses [[buffer(27)]],
                             uint i [[thread_position_in_grid]])
{
    if (i >= world.counts.x) return;
    // FluidWorld.drops: let go this group.
    device const uint2* pairs = (device const uint2*)(drops + 1);
    bool held = false;   // (a held body waits for its drop, whatever splashes it)
    for (uint k = 0; k < drops[0].x; ++k) {
        if (pairs[k].x == i && pairs[k].y > st.counts.x - 1) held = true;
        if (pairs[k].x != i || pairs[k].y != st.counts.x - 1) continue;
        PhysicsBody d = moving[i];
        d.info.y &= ~PHYS_ASLEEP;
        d.prevPosition.w = 0.0f;
        moving[i] = d;
    }
    device atomic_int* at = impulses + 8 * i;
    int3 jl = int3(atomic_load_explicit(at, memory_order_relaxed), atomic_load_explicit(at + 1, memory_order_relaxed),
                   atomic_load_explicit(at + 2, memory_order_relaxed));
    int3 ja = int3(atomic_load_explicit(at + 4, memory_order_relaxed), atomic_load_explicit(at + 5, memory_order_relaxed),
                   atomic_load_explicit(at + 6, memory_order_relaxed));
    for (uint k = 0; k < 8; ++k) atomic_store_explicit(at + k, 0, memory_order_relaxed);
    PhysicsBody b = moving[i];
    if (held || !(b.position.w > 0.0f) || (b.info.y & PHYS_KINEMATIC) != 0 || (all(jl == 0) && all(ja == 0))) return;
    float3 j = float3(jl) / p.fixed.z, l = float3(ja) / p.fixed.z;
    float3 dv = j * b.position.w;
    float speed = length(dv);
    if (speed > 2.0f) dv *= 2.0f / speed;   // FluidWorld.kickCap
    float3 dw = physInvInertia(b.rotation, b.invInertia.xyz, l);
    if ((b.info.y & PHYS_ASLEEP) != 0) {
        if (!(length(dv + world.gravity.xyz * p.extra.w) > 0.03f)) return;   // FluidWorld.wakeKick
        b.info.y &= ~PHYS_ASLEEP;
        b.prevPosition.w = 0.0f;
    }
    b.velocity = float4(b.velocity.xyz + dv, b.velocity.w);
    b.angular = float4(b.angular.xyz + dw, b.angular.w);
    moving[i] = b;
}

// MARK: - The scan (an exclusive prefix sum of `size.x` uints, the total after them)

constant uint FLUID_SCAN_BLOCK = 1024;   // a threadgroup of 256 threads, 4 each

kernel void fluidScanBlocksKernel(constant uint4& size [[buffer(16)]], device const uint* in [[buffer(8)]], device uint* out [[buffer(9)]],
                                  device uint* partials [[buffer(15)]],
                                  uint t [[thread_index_in_threadgroup]], uint g [[threadgroup_position_in_grid]],
                                  uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]])
{
    threadgroup uint sums[8];
    uint base = g * FLUID_SCAN_BLOCK + 4 * t;
    uint v[4];
    uint total = 0;
    for (uint k = 0; k < 4; ++k) { v[k] = base + k < size.x ? in[base + k] : 0u; total += v[k]; }
    uint before = simd_prefix_exclusive_sum(total);
    if (lane == 31) sums[sg] = before + total;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint offset = 0;
    for (uint s = 0; s < sg; ++s) offset += sums[s];
    uint running = offset + before;
    for (uint k = 0; k < 4; ++k) {
        if (base + k < size.x) out[base + k] = running;
        running += v[k];
    }
    if (t == 255) partials[g] = running;
}

// The blocks' totals (up to 4096: 4M elements), in one threadgroup of 256 threads, 16 each; the total at out[size].
kernel void fluidScanTopKernel(constant uint4& size [[buffer(16)]], device uint* out [[buffer(9)]], device uint* partials [[buffer(15)]],
                               uint t [[thread_index_in_threadgroup]],
                               uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]])
{
    threadgroup uint sums[8];
    uint blocks = (size.x + FLUID_SCAN_BLOCK - 1) / FLUID_SCAN_BLOCK;
    uint v[16];
    uint total = 0;
    for (uint k = 0; k < 16; ++k) { uint b = 16 * t + k; v[k] = b < blocks ? partials[b] : 0u; total += v[k]; }
    uint before = simd_prefix_exclusive_sum(total);
    if (lane == 31) sums[sg] = before + total;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint offset = 0;
    for (uint s = 0; s < sg; ++s) offset += sums[s];
    uint running = offset + before;
    for (uint k = 0; k < 16; ++k) {
        uint b = 16 * t + k;
        if (b < blocks) partials[b] = running;
        running += v[k];
    }
    if (t == 255) out[size.x] = running;
}

kernel void fluidScanAddKernel(constant uint4& size [[buffer(16)]], device uint* out [[buffer(9)]], device const uint* partials [[buffer(15)]],
                               uint e [[thread_position_in_grid]])
{
    if (e < size.x) out[e] += partials[e / FLUID_SCAN_BLOCK];
}

// MARK: - PBF

// PhysicsWorld.fluidCell, fluidCellIndex.
inline int3 fluidCell(float3 x, constant FluidParams& p) {
    int3 c = int3(floor((x - p.lo.xyz) * p.hi.w));
    return clamp(c, int3(0), int3(p.dims.xyz) - 1);
}
inline uint fluidCellIndex(int3 c, constant FluidParams& p) { return uint(c.x) + p.dims.x * (uint(c.y) + p.dims.y * uint(c.z)); }
inline int3 fluidCellOf(uint k, constant FluidParams& p) {
    return int3(k % p.dims.x, (k / p.dims.x) % p.dims.y, k / (p.dims.x * p.dims.y));
}

// PBF.wall: the share of poly6's weight beyond a plane d from its centre, and its derivative.
inline float2 fluidWall(float d, float h) {
    float t = clamp(d / h, -1.0f, 1.0f), t2 = t * t;
    float g = t * (1.0f + t2 * (-4.0f / 3.0f + t2 * (6.0f / 5.0f + t2 * (-4.0f / 7.0f + t2 / 9.0f))));
    float one = 1.0f - t2;
    return float2(315.0f / 256.0f * (0.40634921f - g), -315.0f / 256.0f * one * one * one * one / h);
}

// PBF.poly6, PBF.spiky.
inline float fluidPoly6(float r2, float h) {
    float h2 = h * h;
    if (!(r2 < h2)) return 0.0f;
    float d = h2 - r2;
    return 315.0f / (64.0f * M_PI_F * pow(h, 9.0f)) * d * d * d;
}
inline float3 fluidSpiky(float3 r, float h) {
    float l = length(r);
    if (!(l < h) || !(l > 1e-9f)) return float3(0.0f);
    float d = h - l;
    return r * (-45.0f / (M_PI_F * pow(h, 6.0f)) * d * d / l);
}

constant uint FLUID_CELL_MOST = 96;   // PhysicsWorld.fluidCellMost: a cell's particles a neighbour sum reads at most

// The 27 cells about c (z, then y, then x), each cell's particles in order: PhysicsWorld.forNeighbours.
#define FLUID_NEIGHBOURS(c, j, body) \
    for (int dz = -1; dz <= 1; ++dz) for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) { \
        int3 n_ = c + int3(dx, dy, dz); \
        if (any(n_ < 0) || any(n_ >= int3(p.dims.xyz))) continue; \
        uint k_ = fluidCellIndex(n_, p); \
        for (uint j = starts[k_], e_ = min(starts[k_ + 1], starts[k_] + FLUID_CELL_MOST); j < e_; ++j) { body } \
    }

// Predicted positions (gravity, then where the velocity takes them, in the domain) and their cells.
kernel void fluidPredictKernel(constant FluidParams&       p         [[buffer(0)]],
                               device const FluidState&    st        [[buffer(1)]],
                               device const FluidParticle* particles [[buffer(2)]],
                               device float4*              predicted [[buffer(4)]],
                               device uint*                keys      [[buffer(6)]],
                               uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    float dt = p.gravity.w, r = p.extra.x;
    float3 v = particles[i].velocity.xyz + p.gravity.xyz * dt;
    float speed = length(v);
    if (speed > p.fixed.w) v *= p.fixed.w / speed;
    float3 x = clamp(particles[i].position.xyz + v * dt, p.lo.xyz + r, p.hi.xyz - r);
    predicted[i] = float4(x, 0.0f);
    keys[i] = fluidCellIndex(fluidCell(x, p), p);
}

kernel void fluidCellsClearKernel(constant FluidParams& p [[buffer(0)]], device uint* counts [[buffer(8)]], device uint* cursor [[buffer(10)]],
                                  uint c [[thread_position_in_grid]])
{
    if (c > p.dims.w) return;
    counts[c] = 0;
    cursor[c] = 0;
}

kernel void fluidCellCountKernel(device const FluidState& st [[buffer(1)]], device const uint* keys [[buffer(6)]],
                                 device atomic_uint* counts [[buffer(8)]], uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    atomic_fetch_add_explicit(&counts[keys[i]], 1u, memory_order_relaxed);
}

kernel void fluidScatterKernel(device const FluidState& st [[buffer(1)]], device const uint* keys [[buffer(6)]],
                               device const uint* starts [[buffer(9)]], device atomic_uint* cursor [[buffer(10)]],
                               device uint* order [[buffer(11)]], uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    uint k = keys[i];
    order[starts[k] + atomic_fetch_add_explicit(&cursor[k], 1u, memory_order_relaxed)] = i;
}

// Each cell's particles in the order they had (insertion sort: a cell holds a few).
kernel void fluidCellSortKernel(constant FluidParams& p [[buffer(0)]], device const uint* starts [[buffer(9)]], device uint* order [[buffer(11)]],
                                uint c [[thread_position_in_grid]])
{
    if (c >= p.dims.w) return;
    uint b = starts[c], e = starts[c + 1];
    for (uint s = b + 1; s < e; ++s) {
        uint v = order[s], at = s;
        while (at > b && order[at - 1] > v) { order[at] = order[at - 1]; --at; }
        order[at] = v;
    }
}

// The particles, their predicted positions and their cells in the sorted order (into the other buffers).
kernel void fluidReorderKernel(device const FluidState&    st        [[buffer(1)]],
                               device const FluidParticle* from      [[buffer(2)]],
                               device FluidParticle*       to        [[buffer(3)]],
                               device const float4*        predicted [[buffer(4)]],
                               device float4*              sorted    [[buffer(5)]],
                               device const uint*          keys      [[buffer(6)]],
                               device uint*                cells     [[buffer(7)]],
                               device const uint*          order     [[buffer(11)]],
                               uint s [[thread_position_in_grid]])
{
    if (s >= st.counts.y) return;
    uint i = order[s];
    to[s] = from[i];
    sorted[s] = predicted[i];
    cells[s] = keys[i];
}

// Each particle's constraint's lambda.
// PhysicsWorld.pbfBoundary: each wall of the domain and collider within h of x, as `body(code, wall)` (code: none for
// a wall; wall = its share of the rest density, then its gradient).
#define FLUID_BOUNDARY(x, code, share, slope, body) { \
    float h_ = p.pbf.x; \
    for (int a_ = 0; a_ < 3; ++a_) { \
        for (int s_ = 0; s_ < 2; ++s_) { \
            float d_ = s_ == 0 ? x[a_] - p.lo[a_] : p.hi[a_] - x[a_]; \
            if (!(d_ < h_)) continue; \
            float2 w_ = fluidWall(d_, h_); \
            float3 n_ = float3(0.0f); n_[a_] = s_ == 0 ? 1.0f : -1.0f; \
            uint code = PHYS_NONE; float share = w_.x; float3 slope = n_ * w_.y; body \
        } \
    } \
    uint count_ = c.staticCount + st.counts.w; \
    for (uint e_ = 0; e_ < count_; ++e_) { \
        uint code = fluidCode(c, st, e_); \
        if (!fluidNear(c, code, x, h_)) continue; \
        PhysicsBody b_ = fluidCollider(c, code); \
        PhysPose pose_ = physPose(b_); \
        float3 local_ = pose_.toBody(x); \
        float d_ = physDistance(c.w, b_.info.x, local_); \
        if (!(d_ < h_)) continue; \
        float2 w_ = fluidWall(d_, h_); \
        float share = w_.x; float3 slope = pose_.direction(physGradient(c.w, b_.info.x, local_)) * w_.y; body \
    } \
}

kernel void fluidPbfLambdaKernel(constant FluidParams&    p         [[buffer(0)]],
                                 device const FluidState& st        [[buffer(1)]],
                                 device const float4*     predicted [[buffer(4)]],
                                 device const uint*       cells     [[buffer(7)]],
                                 device const uint*       starts    [[buffer(9)]],
                                 device float*            lambdas   [[buffer(12)]],
                                 FLUID_WORLD,
                                 uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    FLUID_COLLIDERS;
    float h = p.pbf.x, rho0 = p.material.x, volume = 1.0f / rho0;
    float3 x = predicted[i].xyz;
    float density = 0.0f, squares = 0.0f;
    float3 own = float3(0.0f);
    int3 cell = fluidCellOf(cells[i], p);
    FLUID_NEIGHBOURS(cell, j, {
        float3 d = x - predicted[j].xyz;
        density += fluidPoly6(length_squared(d), h);
        if (j == i) continue;
        float3 g = fluidSpiky(d, h) * volume;
        own += g;
        squares += length_squared(g);
    })
    FLUID_BOUNDARY(x, code, share, slope, { density += share * rho0; own += slope; })
    float k = max(density / rho0 - 1.0f, -p.material.z);
    lambdas[i] = -k / (squares + length_squared(own) + p.pbf.y);
}

// The pushes the constraints give (with s_corr), then the walls and the colliders: into the other buffer.
kernel void fluidPbfDeltaKernel(constant FluidParams&       p         [[buffer(0)]],
                                device const FluidState&    st        [[buffer(1)]],
                                device const FluidParticle* particles [[buffer(3)]],
                                device const float4*        predicted [[buffer(4)]],
                                device float4*              next      [[buffer(5)]],
                                device const uint*          cells     [[buffer(7)]],
                                device const uint*          starts    [[buffer(9)]],
                                device const float*         lambdas   [[buffer(12)]],
                                FLUID_WORLD,
                                uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    FLUID_COLLIDERS;
    float h = p.pbf.x, volume = 1.0f / p.material.x, r = p.extra.x;
    float3 x = predicted[i].xyz, delta = float3(0.0f);
    float li = lambdas[i];
    int3 cell = fluidCellOf(cells[i], p);
    FLUID_NEIGHBOURS(cell, j, {
        if (j == i) continue;
        float3 d = x - predicted[j].xyz;
        float r2 = length_squared(d);
        if (!(r2 < h * h)) continue;
        float w = fluidPoly6(r2, h) * p.pbf.w;
        float corr = -p.pbf.z * (w * w) * (w * w);
        delta += fluidSpiky(d, h) * ((li + lambdas[j] + corr) * volume);
    })
    FLUID_BOUNDARY(x, code, share, slope, {
        float3 push = slope * li;
        delta += push;
        if (code != PHYS_NONE) fluidImpulse(c, impulses, code, -push * (p.material.y / p.gravity.w), x, p.fixed.z);
    })
    float3 lo = p.lo.xyz + r, hi = p.hi.xyz - r;
    float3 y = clamp(x + delta, lo, hi);
    y = fluidPushOut(c, st, impulses, y, particles[i].position.xyz, r, p.gravity.w, p.pbf2.z, p.material.y, p);
    next[i] = float4(clamp(y, lo, hi), 0.0f);
}

// Velocities from how far the substep took them.
kernel void fluidPbfVelocityKernel(constant FluidParams&    p         [[buffer(0)]],
                                   device const FluidState& st        [[buffer(1)]],
                                   device FluidParticle*    particles [[buffer(3)]],
                                   device const float4*     predicted [[buffer(4)]],
                                   uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    float3 y = predicted[i].xyz;
    particles[i].velocity = float4((y - particles[i].position.xyz) / p.gravity.w, 0.0f);
    particles[i].position = float4(y, 1.0f);
}

kernel void fluidPbfVorticityKernel(constant FluidParams&    p         [[buffer(0)]],
                                    device const FluidState& st        [[buffer(1)]],
                                    device FluidParticle*    particles [[buffer(3)]],
                                    device const uint*       cells     [[buffer(7)]],
                                    device const uint*       starts    [[buffer(9)]],
                                    uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    float h = p.pbf.x, volume = 1.0f / p.material.x;
    float3 x = particles[i].position.xyz, v = particles[i].velocity.xyz, w = float3(0.0f);
    int3 c = fluidCellOf(cells[i], p);
    FLUID_NEIGHBOURS(c, j, {
        if (j == i) continue;
        w += cross(fluidSpiky(x - particles[j].position.xyz, h), particles[j].velocity.xyz - v) * volume;
    })
    particles[i].affine0 = float4(w, 0.0f);
}

// XSPH viscosity and vorticity confinement: back into the first buffer, the particles' state for the next substep.
kernel void fluidPbfViscosityKernel(constant FluidParams&       p         [[buffer(0)]],
                                    device const FluidState&    st        [[buffer(1)]],
                                    device FluidParticle*       out       [[buffer(2)]],
                                    device const FluidParticle* particles [[buffer(3)]],
                                    device const uint*          cells     [[buffer(7)]],
                                    device const uint*          starts    [[buffer(9)]],
                                    uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    float h = p.pbf.x, volume = 1.0f / p.material.x;
    FluidParticle q = particles[i];
    float3 x = q.position.xyz, v = q.velocity.xyz, w = q.affine0.xyz;
    float wl = length(w);
    float3 smooth = float3(0.0f), eta = float3(0.0f);
    int3 c = fluidCellOf(cells[i], p);
    FLUID_NEIGHBOURS(c, j, {
        if (j == i) continue;
        float3 d = x - particles[j].position.xyz;
        smooth += (particles[j].velocity.xyz - v) * (fluidPoly6(length_squared(d), h) * volume);
        eta += fluidSpiky(d, h) * ((length(particles[j].affine0.xyz) - wl) * volume);
    })
    float3 u = v + smooth * p.pbf2.x;
    float el = length(eta);
    if (el > 1e-6f && wl > 1e-6f) u += cross(eta / el, w) * (p.pbf2.y * p.gravity.w);
    q.velocity = float4(u, 0.0f);
    out[i] = q;
}

// MARK: - MLS-MPM

// PhysicsWorld.spline.
struct FluidSpline { int3 base; float3 fx, w[3]; };
inline FluidSpline fluidSpline(float3 xg) {
    FluidSpline s;
    s.base = int3(floor(clamp(xg, 1.0f, 1e6f) - 0.5f));
    s.fx = xg - float3(s.base);
    float3 a = 1.5f - s.fx, b = s.fx - 1.0f, c = s.fx - 0.5f;
    s.w[0] = 0.5f * a * a;
    s.w[1] = 0.75f - b * b;
    s.w[2] = 0.5f * c * c;
    return s;
}
inline uint fluidNode(int3 n, constant FluidParams& p) {
    uint3 c = uint3(clamp(n, int3(0), int3(p.dims.xyz) - 1));   // (never past the grid, whatever a particle did)
    return c.x + p.dims.x * (c.y + p.dims.y * c.z);
}

// LiquidKind.viscosity.
inline float fluidViscosity(float4 k, float shear) {
    return k.x == k.y ? k.x : k.y + (k.x - k.y) * pow(1.0f + k.z * k.z * shear * shear, (k.w - 1.0f) * 0.5f);
}

kernel void fluidMpmClearKernel(constant FluidParams& p [[buffer(0)]], device int4* grid [[buffer(14)]], uint n [[thread_position_in_grid]]) {
    if (n < p.dims.w) grid[n] = int4(0);
}

// Particles to grid: PhysicsWorld.mpmAffine, then each of the 27 nodes' weight and momentum, as integers.
kernel void fluidMpmP2GKernel(constant FluidParams&       p         [[buffer(0)]],
                              device const FluidState&    st        [[buffer(1)]],
                              device const FluidParticle* particles [[buffer(2)]],
                              device atomic_int*          grid      [[buffer(14)]],
                              uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    FluidParticle q = particles[i];
    float j = q.position.w, k = p.material.z, gamma = p.material.w;
    float pressure = max(k / gamma * (pow(j, -gamma) - 1.0f), -p.pbf.x * k);
    float3 c0 = q.affine0.xyz, c1 = q.affine1.xyz, c2 = q.affine2.xyz;
    float third = (c0.x + c1.y + c2.z) / 3.0f;
    float3 d0 = float3(c0.x - third, 0.5f * (c0.y + c1.x), 0.5f * (c0.z + c2.x));
    float3 d1 = float3(d0.y, c1.y - third, 0.5f * (c1.z + c2.y));
    float3 d2 = float3(d0.z, d1.z, c2.z - third);
    float shear = sqrt(2.0f * (dot(d0, d0) + dot(d1, d1) + dot(d2, d2)));
    float mu = fluidViscosity(p.viscosity, shear);
    float s = -p.gravity.w * (j / p.material.x) * 4.0f * p.hi.w * p.hi.w;
    float pq = pressure - p.pbf.y * 3.0f * third;   // (PhysicsWorld.mpmAffine: and the bulk viscosity)
    float3 a0 = c0 + (d0 * (2.0f * mu) - float3(pq, 0, 0)) * s;
    float3 a1 = c1 + (d1 * (2.0f * mu) - float3(0, pq, 0)) * s;
    float3 a2 = c2 + (d2 * (2.0f * mu) - float3(0, 0, pq)) * s;
    FluidSpline sp = fluidSpline((q.position.xyz - p.lo.xyz) * p.hi.w);
    float3 v = q.velocity.xyz;
    for (int n = 0; n < 27; ++n) {
        int3 o = int3(n % 3, n / 3 % 3, n / 9);
        float weight = sp.w[o.x].x * sp.w[o.y].y * sp.w[o.z].z;
        float3 dpos = (float3(o) - sp.fx) * p.lo.w;
        float3 momentum = (v + float3(dot(a0, dpos), dot(a1, dpos), dot(a2, dpos))) * weight;
        device atomic_int* at = grid + 4 * fluidNode(sp.base + o, p);
        atomic_fetch_add_explicit(at + 0, fluidFixed(momentum.x, p.fixed.y), memory_order_relaxed);
        atomic_fetch_add_explicit(at + 1, fluidFixed(momentum.y, p.fixed.y), memory_order_relaxed);
        atomic_fetch_add_explicit(at + 2, fluidFixed(momentum.z, p.fixed.y), memory_order_relaxed);
        atomic_fetch_add_explicit(at + 3, fluidFixed(weight, p.fixed.x), memory_order_relaxed);
    }
}

// PhysicsWorld.mpmContact.
inline float3 fluidContact(float3 v, float3 n, float3 surface, float friction, float stick) {
    float3 rel = v - surface;
    float vn = dot(rel, n);
    if (!(vn < 0.0f)) return v;
    float3 t = rel - n * vn;
    float l = length(t);
    t *= l > 1e-9f ? max(1.0f + friction * vn / l, 0.0f) * (1.0f - stick) : 0.0f;
    return t + surface;
}

// The nodes' velocities (PhysicsWorld.mpmNodeVelocity), written over their integers as float4 (v, weight).
kernel void fluidMpmGridKernel(constant FluidParams&    p    [[buffer(0)]],
                               device const FluidState& st   [[buffer(1)]],
                               device int4*             grid [[buffer(14)]],
                               FLUID_WORLD,
                               uint k [[thread_position_in_grid]])
{
    if (k >= p.dims.w) return;
    FLUID_COLLIDERS;
    int4 g = grid[k];
    int3 node = int3(k % p.dims.x, (k / p.dims.x) % p.dims.y, k / (p.dims.x * p.dims.y));
    // PhysicsWorld.mpmSolid: past the walls or inside a collider (a body's too), a node weighs a rest cell's particles in
    // the density.
    bool solid = any(node < 2) || any(node > int3(p.dims.xyz) - 3);
    float3 x = p.lo.xyz + float3(node) * p.lo.w;
    uint count = c.staticCount + st.counts.w;
    for (uint e = 0; e < count && !solid; ++e) {
        uint code = fluidCode(c, st, e);
        if (!fluidNear(c, code, x, 0.0f)) continue;
        PhysicsBody b = fluidCollider(c, code);
        solid = physDistance(c.w, b.info.x, physPose(b).toBody(x)) < 0.0f;
    }
    float rest = p.lo.w * p.lo.w * p.lo.w / p.extra.z;
    if (g.w <= 0) { grid[k] = as_type<int4>(float4(0.0f, 0.0f, 0.0f, solid ? rest : 0.0f)); return; }
    float m = float(g.w) / p.fixed.x;
    float3 v = float3(g.xyz) / p.fixed.y / m + p.gravity.xyz * p.gravity.w;
    float friction = p.pbf2.z, stick = p.pbf2.w;
    int3 last = int3(p.dims.xyz) - 4;
    for (int a = 0; a < 3; ++a) {
        if (node[a] < 3 && v[a] < 0.0f) {
            float3 n = float3(0.0f); n[a] = 1.0f;
            v = fluidContact(v, n, float3(0.0f), friction, stick);
        } else if (node[a] > last[a] && v[a] > 0.0f) {
            float3 n = float3(0.0f); n[a] = -1.0f;
            v = fluidContact(v, n, float3(0.0f), friction, stick);
        }
    }
    for (uint e = 0; e < count; ++e) {
        uint code = fluidCode(c, st, e);
        float band = 0.5f * p.lo.w;
        if (!fluidNear(c, code, x, band)) continue;
        PhysicsBody b = fluidCollider(c, code);
        PhysPose pose = physPose(b);
        float3 local = pose.toBody(x);
        if (!(physDistance(c.w, b.info.x, local) < band)) continue;
        float3 n = pose.direction(physGradient(c.w, b.info.x, local));
        float3 surface = b.velocity.xyz + cross(b.angular.xyz, x - pose.position);
        float3 before = v;
        v = fluidContact(v, n, surface, friction, stick);
        fluidImpulse(c, impulses, code, (before - v) * (m * p.material.y), x, p.fixed.z);
    }
    float speed = length(v);
    if (speed > p.fixed.w) v *= p.fixed.w / speed;
    grid[k] = as_type<int4>(float4(v, solid ? max(m, rest) : m));
}

// Grid to particles: velocity, C, J and where they go (pushed out of the colliders, held in the domain).
kernel void fluidMpmG2PKernel(constant FluidParams&    p         [[buffer(0)]],
                              device const FluidState& st        [[buffer(1)]],
                              device FluidParticle*    particles [[buffer(2)]],
                              device const float4*     grid      [[buffer(14)]],
                              FLUID_WORLD,
                              uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    FLUID_COLLIDERS;
    FluidParticle q = particles[i];
    float dt = p.gravity.w, dx = p.lo.w, inv = p.hi.w;
    float3 x = q.position.xyz;
    FluidSpline sp = fluidSpline((x - p.lo.xyz) * inv);
    float3 v = float3(0.0f), b0 = float3(0.0f), b1 = float3(0.0f), b2 = float3(0.0f);
    float density = 0.0f;
    for (int n = 0; n < 27; ++n) {
        int3 o = int3(n % 3, n / 3 % 3, n / 9);
        float weight = sp.w[o.x].x * sp.w[o.y].y * sp.w[o.z].z;
        float3 dpos = (float3(o) - sp.fx) * dx;
        float4 node = grid[fluidNode(sp.base + o, p)];
        float3 vi = node.xyz * weight;
        density += node.w * weight;
        v += vi;
        b0 += vi.x * dpos;
        b1 += vi.y * dpos;
        b2 += vi.z * dpos;
    }
    float s = 4.0f * inv * inv;
    float3 c0 = b0 * s, c1 = b1 * s, c2 = b2 * s;
    float j = clamp(dx * dx * dx / p.extra.z / max(density, 1e-6f), 0.5f, 1.5f);   // (PhysicsWorld.mpmSubstep: J from the density)
    float speed = length(v);
    if (speed > p.fixed.w) v *= p.fixed.w / speed;
    float3 lo = p.lo.xyz + 2.0f * dx, hi = p.hi.xyz - 2.0f * dx;
    float3 y = x + v * dt;
    // PhysicsWorld.mpmPushOut: out of the colliders, and no longer going into them.
    uint count = c.staticCount + st.counts.w;
    for (uint e = 0; e < count; ++e) {
        uint code = fluidCode(c, st, e);
        if (!fluidNear(c, code, y, p.extra.x)) continue;
        PhysicsBody b = fluidCollider(c, code);
        PhysPose pose = physPose(b);
        float3 local = pose.toBody(y);
        float depth = physDistance(c.w, b.info.x, local) - p.extra.x;
        if (!(depth < 0.0f)) continue;
        float3 n = pose.direction(physGradient(c.w, b.info.x, local));
        float3 surface = b.velocity.xyz + cross(b.angular.xyz, y - pose.position);
        y += n * -depth;
        v = fluidContact(v, n, surface, p.pbf2.z, p.pbf2.w);
    }
    // PhysicsWorld.mpmHold: inside the walls, and no longer going into them.
    for (int a = 0; a < 3; ++a) {
        float3 n = float3(0.0f);
        if (y[a] < lo[a]) n[a] = 1.0f; else if (y[a] > hi[a]) n[a] = -1.0f; else continue;
        v = fluidContact(v, n, float3(0.0f), p.pbf2.z, p.pbf2.w);
    }
    y = clamp(y, lo, hi);
    q.position = float4(y, j);
    q.velocity = float4(v, 0.0f);
    q.affine0 = float4(c0, 0.0f);
    q.affine1 = float4(c1, 0.0f);
    q.affine2 = float4(c2, 0.0f);
    particles[i] = q;
}
