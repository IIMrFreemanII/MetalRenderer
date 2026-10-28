// Garments (GarmentSolverGPU, Sources/Physics/Garment): the designer's cloth, small-step XPBD over a garment's
// triangle meshes. A substep: garmentPredict, then garmentSolve once per colour (no two constraints of a colour share
// a particle), then garmentCollide (the floor, spheres and capsules, the body's distance field, the mouse's pull; the
// new velocities). Then the frame's garmentMesh writes the scene's vertices and normals. GarmentSolver.swift is the
// same on the CPU, line for line: keep the two together.

struct GarmentConstraint {
    uint4 v;       // its particles (GarmentConstraintKind's comment, GarmentGPUTypes.swift)
    uint4 info;    // x = kind, y = colour
    float4 a;
    float4 b;
};
static_assert(sizeof(GarmentConstraint) == 64, "GarmentConstraint: GPUGarmentConstraint");

struct GarmentParams {
    float4 gravity;    // w = a substep's dt
    uint4 counts;      // x = particles, y = constraints
    float4 collide;    // x = thickness, y = friction, z = the body's margin, w = damping (per second)
    float4 seams;      // x = the seams' compliance now, y = self-collision distance, z = bending across seams' scale
    float4 grab;       // the held particle's target; w = 1 while one is held
    uint4 grabInfo;    // x = the held particle, y = 1: the body has a distance field, z = 1: a skinned body's triangles
    float4 sdfLo;      // the field's box (w = its cell)
    float4 sdfHi;
    float4 floorPlane; // y = the floor's height
    uint4 spheres;     // x = how many
};
static_assert(sizeof(GarmentParams) == 160, "GarmentParams: GPUGarmentParams");

struct GarmentSphere {
    float4 a;   // one end, w = radius
    float4 b;   // the other, w = friction
};
static_assert(sizeof(GarmentSphere) == 32, "GarmentSphere: GPUGarmentSphere");

#define GARMENT_TRI  0u
#define GARMENT_BEND 1u
#define GARMENT_SEAM 2u
#define GARMENT_LINK 3u

kernel void garmentPredictKernel(constant GarmentParams& params [[buffer(0)]],
                                 device const float4*    x      [[buffer(1)]],
                                 device const float4*    v      [[buffer(2)]],
                                 device float4*          p      [[buffer(3)]],
                                 uint i [[thread_position_in_grid]])
{
    if (i >= params.counts.x) return;
    float4 q = x[i];
    if (q.w <= 0) { p[i] = q; return; }
    float h = params.gravity.w;
    float3 vel = (v[i].xyz + params.gravity.xyz * h) * max(0.0f, 1.0f - params.collide.w * h);
    p[i] = float4(q.xyz + vel * h, q.w);
}

// The signed angle across edge x3-x4 between the triangles with far corners x1 and x2, and its gradient (Bridson
// et al. 2003, negated: GarmentStep.dihedral). False when a triangle has no area.
static bool garmentDihedral(float3 x1, float3 x2, float3 x3, float3 x4, thread float& theta,
                            thread float3& g1, thread float3& g2, thread float3& g3, thread float3& g4)
{
    float3 e = x4 - x3;
    float le = length(e);
    float3 n1 = cross(x1 - x3, x1 - x4), n2 = cross(x2 - x4, x2 - x3);
    float l1 = dot(n1, n1), l2 = dot(n2, n2);
    if (le <= 1e-9f || l1 <= 1e-18f || l2 <= 1e-18f) return false;
    float3 a = n1 * rsqrt(l1), b = n2 * rsqrt(l2);
    theta = atan2(dot(cross(a, b), e / le), dot(a, b));
    float3 q1 = n1 / l1, q2 = n2 / l2;
    g1 = -q1 * le;
    g2 = -q2 * le;
    g3 = -(q1 * (dot(x1 - x4, e) / le) + q2 * (dot(x2 - x4, e) / le));
    g4 = q1 * (dot(x1 - x3, e) / le) + q2 * (dot(x2 - x3, e) / le);
    return true;
}

// One colour's constraints: `range` = (its first, its count).
kernel void garmentSolveKernel(constant GarmentParams&          params      [[buffer(0)]],
                               device const GarmentConstraint*  constraints [[buffer(1)]],
                               device float4*                   p           [[buffer(2)]],
                               constant uint2&                  range       [[buffer(3)]],
                               uint t [[thread_position_in_grid]])
{
    if (t >= range.y) return;
    GarmentConstraint c = constraints[range.x + t];
    float h2 = params.gravity.w * params.gravity.w;
    uint kind = c.info.x;
    if (kind == GARMENT_TRI) {
        float4 p0 = p[c.v.x], p1 = p[c.v.y], p2 = p[c.v.z];
        float3 x0 = p0.xyz, x1 = p1.xyz, x2 = p2.xyz;
        float w0 = p0.w, w1 = p1.w, w2 = p2.w;
        float4 m = c.a;
        float area = c.b.w;
        float3 cu = float3(-(m.x + m.z), m.x, m.z), cv = float3(-(m.y + m.w), m.y, m.w);
        for (int k = 0; k < 3; k++) {
            float3 fu = (x1 - x0) * m.x + (x2 - x0) * m.z, fv = (x1 - x0) * m.y + (x2 - x0) * m.w;
            float C, alpha;
            float3 g0, g1, g2;
            if (k < 2) {
                float3 f = k == 0 ? fu : fv;
                float3 cc = k == 0 ? cu : cv;
                float l = length(f);
                if (l <= 1e-9f) continue;
                float3 n = f / l;
                C = l - 1;
                g0 = n * cc.x; g1 = n * cc.y; g2 = n * cc.z;
                alpha = k == 0 ? c.b.x : c.b.y;
            } else {
                C = dot(fu, fv);
                g0 = fv * cu.x + fu * cv.x; g1 = fv * cu.y + fu * cv.y; g2 = fv * cu.z + fu * cv.z;
                alpha = c.b.z;
            }
            float denom = w0 * dot(g0, g0) + w1 * dot(g1, g1) + w2 * dot(g2, g2) + alpha / (area * h2);
            if (denom <= 1e-12f) continue;
            float dl = -C / denom;
            x0 += g0 * (w0 * dl); x1 += g1 * (w1 * dl); x2 += g2 * (w2 * dl);
        }
        p[c.v.x] = float4(x0, w0); p[c.v.y] = float4(x1, w1); p[c.v.z] = float4(x2, w2);
    } else if (kind == GARMENT_BEND) {
        float4 p1 = p[c.v.x], p2 = p[c.v.y], p3 = p[c.v.z], p4 = p[c.v.w];
        float theta;
        float3 g1, g2, g3, g4;
        if (!garmentDihedral(p1.xyz, p2.xyz, p3.xyz, p4.xyz, theta, g1, g2, g3, g4)) return;
        float C = theta - c.a.y;
        if (C > M_PI_F) C -= 2 * M_PI_F; else if (C < -M_PI_F) C += 2 * M_PI_F;
        float denom = p1.w * dot(g1, g1) + p2.w * dot(g2, g2) + p3.w * dot(g3, g3) + p4.w * dot(g4, g4)
                      + c.a.x * (c.b.x > 0 ? params.seams.z : 1.0f) / h2;
        if (denom <= 1e-12f) return;
        float dl = -C / denom;
        p[c.v.x] = float4(p1.xyz + g1 * (p1.w * dl), p1.w);
        p[c.v.y] = float4(p2.xyz + g2 * (p2.w * dl), p2.w);
        p[c.v.z] = float4(p3.xyz + g3 * (p3.w * dl), p3.w);
        p[c.v.w] = float4(p4.xyz + g4 * (p4.w * dl), p4.w);
    } else {
        bool seam = kind == GARMENT_SEAM;
        uint ia = c.v.x, ib0 = c.v.y, ib1 = seam ? c.v.z : c.v.y;
        float w = seam ? c.a.x : 0, rest = seam ? c.a.y : c.a.x;
        float alpha = seam ? params.seams.x : c.a.y;
        float4 pa = p[ia], pb0 = p[ib0], pb1 = p[ib1];
        float3 q = pb0.xyz * (1 - w) + pb1.xyz * w;
        float3 d = pa.xyz - q;
        float l = length(d);
        if (l <= 1e-9f) return;
        float3 n = d / l;
        float C = l - rest, k0 = 1 - w, k1 = w;
        float denom = pa.w + pb0.w * k0 * k0 + (ib1 != ib0 ? pb1.w * k1 * k1 : 0) + alpha / h2;
        if (denom <= 1e-12f) return;
        float dl = -C / denom;
        p[ia] = float4(pa.xyz + n * (pa.w * dl), pa.w);
        if (ib1 == ib0) {
            p[ib0] = float4(pb0.xyz - n * (pb0.w * dl), pb0.w);
        } else {
            p[ib0] = float4(pb0.xyz - n * (pb0.w * k0 * dl), pb0.w);
            p[ib1] = float4(pb1.xyz - n * (pb1.w * k1 * dl), pb1.w);
        }
    }
}

// The body's distance at `q` (metres, negative inside), from its field (trilinear), and the field's gradient.
static float garmentBodyDistance(texture3d<float> sdf, constant GarmentParams& params, float3 q, thread float3& gradient)
{
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float3 size = params.sdfHi.xyz - params.sdfLo.xyz;
    float3 uvw = (q - params.sdfLo.xyz) / size;
    if (any(uvw < 0.0f) || any(uvw > 1.0f)) { gradient = 0; return 1e9f; }
    float3 e = params.sdfLo.w / size;
    float d = sdf.sample(s, uvw).r;
    gradient = float3(sdf.sample(s, uvw + float3(e.x, 0, 0)).r - sdf.sample(s, uvw - float3(e.x, 0, 0)).r,
                      sdf.sample(s, uvw + float3(0, e.y, 0)).r - sdf.sample(s, uvw - float3(0, e.y, 0)).r,
                      sdf.sample(s, uvw + float3(0, 0, e.z)).r - sdf.sample(s, uvw - float3(0, 0, e.z)).r);
    return d;
}

// The particle out of the floor, the spheres and capsules and the body, with friction (GarmentStep.collide); the
// mouse's particle pulled to its target; then the substep's velocity and the particle's new place.
kernel void garmentCollideKernel(constant GarmentParams&      params  [[buffer(0)]],
                                 device float4*               x       [[buffer(1)]],
                                 device float4*               v       [[buffer(2)]],
                                 device const float4*         p       [[buffer(3)]],
                                 device const GarmentSphere*  spheres [[buffer(4)]],
                                 texture3d<float>             sdf     [[texture(0)]],
                                 uint i [[thread_position_in_grid]])
{
    if (i >= params.counts.x) return;
    float4 q = p[i], prevQ = x[i];
    float h = params.gravity.w;
    if (q.w <= 0) { v[i] = float4(0); return; }
    float thickness = params.collide.x, friction = params.collide.y;
    float3 pos = q.xyz, prev = prevQ.xyz;
    // (A push and its friction: the move since the substep began, along the surface, shortened.)
    #define GARMENT_PUSH(n, depth, mu) { \
        pos += (n) * (depth); \
        float3 move = pos - prev, tangent = move - (n) * dot(move, (n)); \
        float tl = length(tangent); \
        if (tl > 1e-9f) pos -= tangent * min(1.0f, (mu) * (depth) / tl); }
    if (pos.y < params.floorPlane.y + thickness) GARMENT_PUSH(float3(0, 1, 0), params.floorPlane.y + thickness - pos.y, friction)
    for (uint k = 0; k < params.spheres.x; k++) {
        float3 a = spheres[k].a.xyz, ab = spheres[k].b.xyz - a;
        float l2 = dot(ab, ab);
        float t = l2 > 0 ? clamp(dot(pos - a, ab) / l2, 0.0f, 1.0f) : 0.0f;
        float3 d = pos - (a + ab * t);
        float l = length(d), r = spheres[k].a.w + thickness;
        if (l < r && l > 1e-9f) GARMENT_PUSH(d / l, r - l, spheres[k].b.w)
    }
    if (params.grabInfo.y != 0) {
        float3 g;
        float d = garmentBodyDistance(sdf, params, pos, g);
        float margin = params.collide.z;
        if (d < margin + thickness && dot(g, g) > 1e-12f) GARMENT_PUSH(normalize(g), margin + thickness - d, friction)
    }
    #undef GARMENT_PUSH
    if (params.grab.w > 0 && i == params.grabInfo.x) pos = mix(pos, params.grab.xyz, 0.5f);
    // No faster than 6 m/s: a tangle pushed apart doesn't fling the cloth away.
    float3 vel = (pos - prev) / h;
    float speed = length(vel);
    if (speed > 6.0f) { vel *= 6.0f / speed; pos = prev + vel * h; }
    v[i] = float4(vel, 0);
    x[i] = float4(pos, prevQ.w);
}

// The garment's particles into the scene's vertex buffer, from `base` on: last frame's place first (motion vectors),
// then this frame's, and its normal: the sum of its triangles' (area weighted), from `corners` (each particle's
// triangles from `starts[i]` to `starts[i + 1]`, each a triangle's first index in `indices`).
kernel void garmentMeshKernel(constant uint4&        info      [[buffer(0)]],   // x = particles, y = base, z = prevOffset
                              device const float4*   x         [[buffer(1)]],
                              device const uint*     starts    [[buffer(2)]],
                              device const uint*     corners   [[buffer(3)]],
                              device const uint*     indices   [[buffer(4)]],
                              device float3*         positions [[buffer(5)]],
                              device float3*         normals   [[buffer(6)]],
                              uint i [[thread_position_in_grid]])
{
    if (i >= info.x) return;
    float3 n = 0;
    for (uint k = starts[i]; k < starts[i + 1]; k++) {
        uint t = corners[k];
        float3 a = x[indices[t]].xyz, b = x[indices[t + 1]].xyz, c = x[indices[t + 2]].xyz;
        n += cross(b - a, c - a);
    }
    uint at = info.y + i;
    positions[at + info.z] = positions[at];
    positions[at] = x[i].xyz;
    float l = length(n);
    normals[at] = l > 1e-12f ? n / l : float3(0, 1, 0);
}

// What the CPU changed, in the GPU's order (GarmentSolverGPU.load): every particle's place, its velocity zeroed
// (info.y = 0), or only its inverse mass (info.y = 1: a panel frozen or let go).
kernel void garmentLoadKernel(constant uint4&       info    [[buffer(0)]],   // x = particles, y = 1: masses only
                              device const float4*  staging [[buffer(1)]],
                              device float4*        x       [[buffer(2)]],
                              device float4*        v       [[buffer(3)]],
                              uint i [[thread_position_in_grid]])
{
    if (i >= info.x) return;
    if (info.y == 1) { x[i].w = staging[i].w; if (staging[i].w <= 0) v[i] = float4(0); return; }
    x[i] = staging[i];
    v[i] = float4(0);
}

// Self-collision (GarmentSolverGPU.encodeSelf): the cloth's particles binned by a hashed grid of `selfInfo.x` cells, then
// each pushed from the others within the self distance (params.seams.y): a Jacobi step into `out`, which the collision
// then reads. Not a particle's neighbours in its cloth (the same panel, near on the sheet) nor its seam partners. An
// outer layer's particle (Panel.layer) against an inner one's moves alone, out of the body: the inner stays inside.
#define GARMENT_TABLE 32768u

inline uint garmentCell(int3 c) {
    return ((uint(c.x) * 73856093u) ^ (uint(c.y) * 19349663u) ^ (uint(c.z) * 83492791u)) & (GARMENT_TABLE - 1u);
}

kernel void garmentHashClearKernel(device atomic_uint* counts [[buffer(0)]], uint i [[thread_position_in_grid]])
{
    if (i < GARMENT_TABLE) atomic_store_explicit(&counts[i], 0u, memory_order_relaxed);
}

kernel void garmentHashCountKernel(constant GarmentParams& params [[buffer(0)]],
                                   device const float4*    p      [[buffer(1)]],
                                   device atomic_uint*     counts [[buffer(2)]],
                                   device uint*            cellOf [[buffer(3)]],
                                   uint i [[thread_position_in_grid]])
{
    if (i >= params.counts.x) return;
    float h = max(params.seams.y, 0.004f);
    uint c = garmentCell(int3(floor(p[i].xyz / h)));
    cellOf[i] = c;
    atomic_fetch_add_explicit(&counts[c], 1u, memory_order_relaxed);
}

// The counts' running sum into each cell's start (and a copy for the scatter's cursors): one threadgroup of 1024, each
// thread 32 cells.
kernel void garmentHashScanKernel(device const uint*   counts  [[buffer(0)]],
                                  device uint*         starts  [[buffer(1)]],
                                  device atomic_uint*  cursors [[buffer(2)]],
                                  uint t [[thread_position_in_threadgroup]])
{
    threadgroup uint sums[1024];
    const uint per = GARMENT_TABLE / 1024u;
    uint base = t * per, s = 0;
    for (uint k = 0; k < per; k++) s += counts[base + k];
    sums[t] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint off = 1; off < 1024u; off <<= 1) {
        uint v = t >= off ? sums[t - off] : 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        sums[t] += v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint run = sums[t] - s;
    for (uint k = 0; k < per; k++) {
        starts[base + k] = run;
        atomic_store_explicit(&cursors[base + k], run, memory_order_relaxed);
        run += counts[base + k];
    }
    if (t == 1023u) starts[GARMENT_TABLE] = run;
}

kernel void garmentHashScatterKernel(constant GarmentParams& params  [[buffer(0)]],
                                     device const uint*      cellOf  [[buffer(1)]],
                                     device atomic_uint*     cursors [[buffer(2)]],
                                     device uint*            sorted  [[buffer(3)]],
                                     uint i [[thread_position_in_grid]])
{
    if (i >= params.counts.x) return;
    sorted[atomic_fetch_add_explicit(&cursors[cellOf[i]], 1u, memory_order_relaxed)] = i;
}

kernel void garmentSelfKernel(constant GarmentParams&  params   [[buffer(0)]],
                              device const float4*     p        [[buffer(1)]],
                              device const float4*     rest     [[buffer(2)]],   // the sheet's place, panel, layer
                              device const uint4*      partners [[buffer(3)]],   // seam partners (~0: none)
                              device const uint*       starts   [[buffer(4)]],
                              device const uint*       sorted   [[buffer(5)]],
                              device float4*           out      [[buffer(6)]],
                              texture3d<float>         sdf      [[texture(0)]],
                              uint i [[thread_position_in_grid]])
{
    if (i >= params.counts.x) return;
    float4 me = p[i];
    if (me.w <= 0) { out[i] = me; return; }
    float r = max(params.seams.y, 0.004f), h = r;
    float4 rs = rest[i];
    uint4 mine = partners[i];
    int3 c = int3(floor(me.xyz / h));
    float3 push = 0;
    float n = 0;
    float myDepth = 0;
    bool body = params.grabInfo.y != 0;
    float3 g = 0;
    if (body) myDepth = garmentBodyDistance(sdf, params, me.xyz, g);
    for (int z = -1; z <= 1; z++) for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        uint cell = garmentCell(c + int3(x, y, z));
        for (uint k = starts[cell]; k < starts[cell + 1]; k++) {
            uint j = sorted[k];
            if (j == i || any(mine == j)) continue;
            float4 other = p[j], ro = rest[j];
            if (ro.z == rs.z && distance(ro.xy, rs.xy) < 2.5f * r) continue;   // its neighbours in the cloth
            float3 d = me.xyz - other.xyz;
            float l = length(d);
            if (l >= r || l < 1e-7f) continue;
            if (ro.w > rs.w) continue;                                          // it is the outer one: it moves
            if (ro.w < rs.w && body && dot(g, g) > 1e-8f) {
                // Outer against inner: out of the body, past the inner one.
                float3 gj;
                float theirs = garmentBodyDistance(sdf, params, other.xyz, gj);
                float want = theirs + r - myDepth;
                if (want > 0) { push += normalize(g) * want; n += 1; }
                continue;
            }
            push += d / l * ((r - l) * (ro.w < rs.w ? 1.0f : 0.5f));
            n += 1;
        }
    }
    float3 move = push / max(1.0f, n * 0.5f);
    float ml = length(move);
    if (ml > r) move *= r / ml;   // at most the self distance a substep
    out[i] = n > 0 ? float4(me.xyz + move, me.w) : me;
}
