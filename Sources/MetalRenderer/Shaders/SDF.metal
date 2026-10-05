// ---------------------------------------------------------------------------------------------
// SDF shapes (SDFShapes.swift): geometry given by a signed distance field, sphere-traced in its instance's space
// ---------------------------------------------------------------------------------------------

// A shape is its nodes joined one after the other: ((n0 op1 n1) op2 n2) ... Each node is a primitive placed in the
// shape by a rotation, a translation and a uniform scale (so its distances stay distances), or a baked grid. Both
// tracers march a shape here (the custom one in rtTraverse, Metal's in its intersection queries' loop), which gives
// the hit its normal and material: nothing after the hit needs the shapes (traceSurface).

constant uint SDF_SPHERE = 0, SDF_BOX = 1, SDF_TORUS = 2, SDF_CAPSULE = 3, SDF_CYLINDER = 4, SDF_CONE = 5, SDF_VOLUME = 6;
constant uint SDF_UNION = 0, SDF_SUBTRACT = 1, SDF_INTERSECT = 2;

struct SDFNode {
    float4 row0;       // shape space -> the primitive's, as rows
    float4 row1;
    float4 row2;
    float4 params;     // sphere: r | box: half extents, rounding | torus: major, minor | capsule: half length, r |
                       // cylinder: half height, r, rounding | cone: half height, r at the bottom, r at the top
    uint   kind;       // SDF_SPHERE ...
    uint   op;         // SDF_UNION ...: how it joins the nodes before it (the first node's is not read)
    float  k;          // the blend's radius (0 = sharp)
    float  scale;      // its distances are the primitive's x this
    uint   material;   // offset from the instance's material
    uint   volume;     // SDF_VOLUME: its grid
    uint   pad0, pad1;
};
static_assert(sizeof(SDFNode) == 96, "SDFNode: GPUSDFNode");

struct SDFShape {
    float4 lo;         // xyz = its box (shape space), w = the march's step scale (1: exact distances)
    float4 hi;         // xyz = the box's max, w = 0
    uint4  range;      // x = its first node, y = how many
};
static_assert(sizeof(SDFShape) == 48, "SDFShape: GPUSDFShape");

struct SDFVolume {
    float4 lo;         // xyz = the first sample's place, w = the samples' spacing
    float4 hi;         // xyz = the last's, w = the least sample on the grid's faces
    uint4  dims;       // xyz = samples per axis, w = where its samples start in SDFScene.cells
};
static_assert(sizeof(SDFVolume) == 48, "SDFVolume: GPUSDFVolume");

// Every shape of the scene (SDFBuffers.swift writes the addresses).
struct SDFScene {
    device const SDFShape*  shapes;
    device const SDFNode*   nodes;
    device const SDFVolume* volumes;
    device const half*      cells;
};

constant uint  SDF_MAX_STEPS = 128;
// A march stops this near the surface: 0.1 mm, and 0.1 mm more per metre along the ray (the hit lies within it,
// well inside RAY_EPSILON, the 1 mm a ray from the hit starts off the surface).
constant float SDF_EPSILON = 1e-4f;

// A baked grid at `p` (its space): trilinear inside; outside, the distance to it plus the least of its face samples,
// which nothing out there can be nearer to the surface than.
inline float sdfVolume(SDFScene sc, device const SDFVolume& v, float3 p) {
    float3 q = clamp(p, v.lo.xyz, v.hi.xyz);
    float outside = length(p - q);
    uint3 dims = v.dims.xyz;
    float3 g = (q - v.lo.xyz) / v.lo.w;
    uint3 i = min(uint3(g), dims - 2u);
    float3 f = g - float3(i);
    uint sy = dims.x, sz = dims.x * dims.y;
    device const half* c = sc.cells + v.dims.w + (i.z * dims.y + i.y) * dims.x + i.x;
    float inside = mix(mix(mix(float(c[0]), float(c[1]), f.x), mix(float(c[sy]), float(c[sy + 1]), f.x), f.y),
                       mix(mix(float(c[sz]), float(c[sz + 1]), f.x), mix(float(c[sz + sy]), float(c[sz + sy + 1]), f.x), f.y), f.z);
    return outside > 0.0f ? outside + min(v.hi.w, inside) : inside;
}

// The node's primitive at `q` (its own space).
inline float sdfPrimitive(SDFScene sc, device const SDFNode& n, float3 q) {
    float4 a = n.params;
    switch (n.kind) {
        case SDF_SPHERE:
            return length(q) - a.x;
        case SDF_BOX: {
            float3 e = abs(q) - (a.xyz - a.w);
            return length(max(e, 0.0f)) + min(max(e.x, max(e.y, e.z)), 0.0f) - a.w;
        }
        case SDF_TORUS:
            return length(float2(length(q.xz) - a.x, q.y)) - a.y;
        case SDF_CAPSULE:
            return length(float3(q.x, q.y - clamp(q.y, -a.x, a.x), q.z)) - a.y;
        case SDF_CYLINDER: {
            float2 e = float2(length(q.xz) - (a.y - a.z), abs(q.y) - (a.x - a.z));
            return min(max(e.x, e.y), 0.0f) + length(max(e, 0.0f)) - a.z;
        }
        case SDF_CONE: {
            float2 p = float2(length(q.xz), q.y);
            float2 k1 = float2(a.z, a.x), k2 = float2(a.z - a.y, 2.0f * a.x);
            float2 ca = float2(p.x - min(p.x, p.y < 0.0f ? a.y : a.z), abs(p.y) - a.x);
            float2 cb = p - k1 + k2 * saturate(dot(k1 - p, k2) / dot(k2, k2));
            float s = cb.x < 0.0f && ca.y < 0.0f ? -1.0f : 1.0f;
            return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
        }
        default:
            return sdfVolume(sc, sc.volumes[n.volume], q);
    }
}

// Polynomial smooth minimum: never lower than min(a, b) - k/4.
inline float sdfSmin(float a, float b, float k) {
    if (k <= 0.0f) return min(a, b);
    float h = max(k - abs(a - b), 0.0f) / k;
    return min(a, b) - h * h * k * 0.25f;
}

// `a` op `b`; `takes`: the surface there is b's (a cut's face is the cutter's).
inline float sdfJoin(float a, float b, uint op, float k, thread bool& takes) {
    if (op == SDF_UNION) { takes = b < a; return sdfSmin(a, b, k); }
    if (op == SDF_SUBTRACT) { takes = -b > a; return -sdfSmin(-a, b, k); }
    takes = b > a;
    return -sdfSmin(-a, -b, k);
}

// The shape's distance at `p` (shape space), and the material offset of its surface nearest there.
inline float sdfEval(SDFScene sc, SDFShape s, float3 p, thread uint& material) {
    float d = 0.0f;
    float4 p4 = float4(p, 1.0f);
    for (uint i = 0; i < s.range.y; ++i) {
        device const SDFNode& n = sc.nodes[s.range.x + i];
        float3 q = float3(dot(n.row0, p4), dot(n.row1, p4), dot(n.row2, p4));
        float b = n.scale * sdfPrimitive(sc, n, q);
        if (i == 0) { d = b; material = n.material; continue; }
        bool takes;
        d = sdfJoin(d, b, n.op, n.k, takes);
        if (takes) material = n.material;
    }
    return d;
}

inline float sdfEval(SDFScene sc, SDFShape s, float3 p) {
    uint m;
    return sdfEval(sc, s, p, m);
}

// Unit normals as two floats (octahedral): a hit carries its normal in Hit.barycentrics.
inline float2 sdfOctEncode(float3 n) {
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    float2 e = n.xy;
    if (n.z < 0.0f) e = (1.0f - abs(e.yx)) * select(float2(-1.0f), float2(1.0f), e >= 0.0f);
    return e;
}
inline float3 sdfOctDecode(float2 e) {
    float3 n = float3(e, 1.0f - abs(e.x) - abs(e.y));
    if (n.z < 0.0f) n.xy = (1.0f - abs(n.yx)) * select(float2(-1.0f), float2(1.0f), n.xy >= 0.0f);
    return normalize(n);
}

// Sphere-traces shape `shape` along o + d t (the instance's space, d as the instance turned the ray's: t is the
// world ray's own) from tmin to tmax, inside the shape's box. `worldPerT`: the world ray's direction's length, which
// turns t into metres for the stopping distance. A ray that starts inside the shape meets its inside (as rays meet
// both faces of triangles). True on a hit: its t, the material offset there, and with `wantNormal` the outward
// normal (shape space, octahedral). `steps`: counts the field's evaluations (the Traversal cost view).
inline bool sdfMarch(SDFScene sc, uint shape, float3 o, float3 d, float tmin, float tmax, float worldPerT, bool wantNormal,
                     thread float& tHit, thread float2& normal, thread uint& material, thread uint& steps) {
    SDFShape s = sc.shapes[shape];
    float3 inv = 1.0f / select(d, copysign(float3(1e-12f), d), abs(d) < 1e-12f);
    float3 ta = (s.lo.xyz - o) * inv, tb = (s.hi.xyz - o) * inv;
    float3 tn = min(ta, tb), tf = max(ta, tb);
    float t = max(max(tn.x, tn.y), max(tn.z, tmin)), t1 = min(min(tf.x, tf.y), min(tf.z, tmax));
    if (t > t1) return false;
    float dl = length(d);
    float objPerWorld = dl / worldPerT;   // the instance's units per metre along the ray
    uint m = 0;
    float f = sdfEval(sc, s, o + d * t, m);
    float side = f < 0.0f ? -1.0f : 1.0f;
    bool hit = false;
    float eps = 0.0f;
    for (uint i = 0; i < SDF_MAX_STEPS; ++i) {
        ++steps;
        eps = SDF_EPSILON * (1.0f + t * worldPerT) * objPerWorld;
        float g = side * f;
        if (g < eps) { hit = true; break; }
        t += max(g * s.lo.w, 0.5f * eps) / dl;
        if (t > t1) return false;
        f = sdfEval(sc, s, o + d * t, m);
    }
    // Out of steps (a ray grazing a surface for long): a hit if it is that close by then.
    if (!hit && side * f >= 8.0f * eps) return false;
    tHit = clamp(t + side * f / dl, tmin, t1);   // onto the surface
    material = m;
    if (wantNormal) {
        float3 p = o + d * tHit;
        float h = max(eps, 1e-4f * length(s.hi.xyz - s.lo.xyz));
        const float2 k = float2(1.0f, -1.0f);
        float3 g = k.xyy * sdfEval(sc, s, p + k.xyy * h) + k.yyx * sdfEval(sc, s, p + k.yyx * h)
                 + k.yxy * sdfEval(sc, s, p + k.yxy * h) + k.xxx * sdfEval(sc, s, p + k.xxx * h);
        steps += 4;
        normal = sdfOctEncode(dot(g, g) > 0.0f ? g : -d);
    }
    return true;
}
