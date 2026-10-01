// MetalGI shaders: ray traced direct light + path traced global illumination + SVGF-style denoiser.
// Compiled at runtime by Renderer.swift — press R in the app to hot-reload after editing.

#include <metal_stdlib>
using namespace metal;

// CUSTOM_RT (set by Renderer.loadShaders): 1 = this file's own BVH traversal (see "Ray queries" below),
// 0 = Metal's acceleration structures and intersector.
#ifndef CUSTOM_RT
#define CUSTOM_RT 1
#endif
#if !CUSTOM_RT
#include <metal_raytracing>
using namespace metal::raytracing;
#endif

// ---------------------------------------------------------------------------------------------
// Shared types — layouts must match GPUTypes.swift exactly.
// ---------------------------------------------------------------------------------------------

struct Uniforms {
    float4 camPos;          // xyz
    float4 camRight;        // xyz, w = tan(fovX/2)
    float4 camUp;           // xyz, w = tan(fovY/2)
    float4 camForward;      // xyz
    float4 prevCamPos;
    float4 prevCamRight;
    float4 prevCamUp;
    float4 prevCamForward;
    float4 skyColor;
    uint width;
    uint height;
    uint frameIndex;
    uint lightCount;
    uint bounces;
    uint flags;
    uint viewMode;
    uint instanceCount;
    float4 jitter;          // xy = this frame's sub-pixel jitter, zw = previous frame's (pixels)
    float4 denoise;         // x = luminance sigma, y = max history frames, z = anti-lag strength (0 = off)
    uint4 lightGroupEnd;    // lights are sorted by shadow-denoiser group: group g = [end[g - 1], end[g])
};

struct MeshData {
    uint firstIndex;
    uint indexCount;
    uint pad0;
    uint pad1;
};

struct InstanceData {
    float4x4 transform;
    float4x4 prevTransform;
    float4x4 normalMatrix;
    uint meshIndex;
    uint materialIndex;
    uint pad0;
    uint pad1;
};

struct Material {
    float4 albedo;      // rgb = base colour, a = metallic
    float4 emission;    // rgb = emitted radiance, a = roughness
    float4 params;      // x = specular weight (0 = diffuse only, the generated scenes), y = normal scale,
                        // z = 1: its emission is sampled as an emissive-mesh light
    uint4  textures;    // base colour, metallic-roughness (G = roughness, B = metallic), normal, emissive; ~0 = none
};

// Bindless material textures (Renderer: an array of MTLResourceIDs).
struct MaterialTexture {
    texture2d<float> t;
};

struct EmissiveTriangle;

// Buffer 7 of every kernel that shades ray hits: materials, per-vertex UVs and the texture table.
struct SceneShading {
    device const Material*        materials;
    device const float2*          uvs;
    device const MaterialTexture* textures;
    device const float*           minLod;      // per texture: finest resident mip level (texture streaming)
    device atomic_uint*           feedback;    // per texture: 16 counters, samples wanting each mip level this frame
    device const EmissiveTriangle* emissive;   // emissive-mesh lights' triangles
};

constant uint NO_TEXTURE = 0xFFFFFFFFu;

// One light (GPUTypes.swift GPULight). Analytic lights come first, sorted by shadow-denoiser group
// (u.lightGroupEnd.w of them); emissive-mesh lights follow, up to u.lightCount.
struct Light {
    float4 positionRadius;  // xyz = centre (unused by the sun), w = radius (sphere, spot, tube; mesh: bounding sphere),
                            //   angular radius in radians (sun)
    float4 color;           // rgb = intensity (sphere, spot, tube), irradiance (sun), radiance (rect),
                            //   sum of radiance x area (mesh); w = shadow-denoiser group + 4 x type (LIGHT_*), so
                            //   the per-light weight loops read only the first 32 bytes of a sphere light
    float4 axis;            // xyz = spot axis, rect normal (it emits along it), direction toward the sun,
                            //   tube half axis (centre +- axis), mesh mean normal
    float4 params;          // spot: cos outer, cos inner | rect: half-width tangent xyz, half height
                            // sun: light-map bounds centre xyz, radius | mesh: first triangle, triangle count,
                            //   flatness, instance (uints bit cast, but flatness)
};

constant uint LIGHT_SPHERE = 0;
constant uint LIGHT_SPOT   = 1;
constant uint LIGHT_SUN    = 2;
constant uint LIGHT_RECT   = 3;
constant uint LIGHT_TUBE   = 4;
constant uint LIGHT_MESH   = 5;

// One bit per LIGHT_* type the scene has (function constant 0). The renderer specialises the pipelines per scene,
// so the per-light loops of a scene with only sphere lights compile to exactly the sphere code; without the constant
// (e.g. a pipeline made without it) every type is handled.
constant uint lightTypesConstant [[function_constant(0)]];
constant uint LIGHT_TYPES = is_function_constant_defined(lightTypesConstant) ? lightTypesConstant : 0x3Fu;
constant bool POINT_LIGHTS_ONLY = (LIGHT_TYPES & ~3u) == 0;   // spheres and spots

// One triangle of an emissive-mesh light (GPUTypes.swift GPUEmissiveTriangle), object space.
struct EmissiveTriangle {
    float4 v0;    // xyz = vertex 0, w = cumulative selection probability within its light (last = 1)
    float4 e1;    // xyz = v1 - v0, w = uv0.x
    float4 e2;    // xyz = v2 - v0, w = uv0.y
    float4 uv12;  // uv1, uv2
};

constant uint FLAG_HISTORY_VALID = 1;
constant uint FLAG_DENOISE       = 2;
constant uint FLAG_UPSCALE       = 4;   // MetalFX on: write depth + motion for it, composite outputs linear color
constant uint FLAG_BLUE_NOISE    = 8;   // sample with the blue-noise texture instead of the hash RNG
constant uint FLAG_SEPARATE      = 16;  // direct and indirect light were denoised separately
constant uint FLAG_NO_CLAMP      = 32;  // no firefly clamp (reference images)
constant uint FLAG_LIGHT_MAPS    = 64;  // path tracer: bounce lighting from light-visibility maps
constant uint FLAG_SHADOW_DENOISER = 128;  // direct light = exact unshadowed light x denoised per-group visibility
constant uint FLAG_ALL_LIGHTS    = 256; // one shadow ray per light even with more than SHADOW_GROUPS lights (references)
constant uint FLAG_SPECULAR      = 512; // specular materials present: material G-buffer, reflection pass, specular composite
constant uint FLAG_REFERENCE     = 1024; // accumulated reference: reflections follow full paths
constant uint FLAG_MESH_LIGHTS   = 2048; // with the shadow denoiser: the composite adds the denoised mesh-light direct light
constant uint SHADOW_GROUPS      = 4;   // light groups the shadow denoiser handles (one rgba channel each);
                                        // up to 4 lights, each light is its own group (Light.color.w = group)
constant uint CACHED_LIGHT_SAMPLES = 4; // lightIllumCached: light-map lookups per hit with more than 8 lights

constant uint MASK_GEOMETRY = 1;     // see Scene.maskGeometry
constant uint MASK_ALL      = 0xFF;

constant float RAY_EPSILON  = 1e-3f;
constant float FIREFLY_CLAMP = 10.0f;
constant float NEAR_PLANE   = 0.05f; // only used to encode the reversed-Z depth MetalFX reads

// ---------------------------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------------------------

inline float luminance(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

// Round to the nearest half before writing a half-float texture. The texture write itself may round
// toward zero, and the denoiser's history feedback amplifies that bias into visible darkening.
inline float4 roundToHalf(float4 v) { return float4(half4(v)); }

inline uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Simple per-pixel random stream (white noise).
struct Rng {
    uint state;
    float next() {
        state = pcgHash(state);
        return float(state) * (1.0f / 4294967296.0f);
    }
    float2 next2() { return float2(next(), next()); }
};

constant uint BLUE_NOISE_SIZE = 128;   // must match BlueNoise.size

// Per-pixel sample stream. With blue noise, every random dimension reads the tiled blue-noise texture at
// its own offset, so neighboring pixels get well-spread values and the error is high-frequency (which the
// a-trous filter removes far better than white noise). Each frame shifts the values by the golden ratio
// (1D) or the R2 sequence (2D), so each pixel's samples over time are also evenly spread.
struct Sampler {
    texture2d<float, access::read> blueNoise;
    uint2 pixel;
    uint frame;
    uint dimension;
    bool useBlueNoise;
    Rng rng;

    float blueValue() {
        // R2-sequence offsets give every dimension a different, far-apart window into the tile.
        float2 r2 = fract(float(dimension + 1) * float2(0.7548776662f, 0.5698402910f));
        dimension++;
        uint2 q = (pixel + uint2(r2 * float(BLUE_NOISE_SIZE))) % BLUE_NOISE_SIZE;
        return blueNoise.read(q).r;
    }
    // Adds frame * step (step = fraction * 2^32) in 32-bit fixed point, so there is no drift over time.
    float shift(float v, uint step) {
        uint x = (uint(v * 16777216.0f) << 8) + frame * step;
        return float(x >> 8) * (1.0f / 16777216.0f);
    }
    float next() {
        if (!useBlueNoise) return rng.next();
        return shift(blueValue(), 2654435769u);                       // golden ratio
    }
    float2 next2() {
        if (!useBlueNoise) return rng.next2();
        float a = blueValue(), b = blueValue();
        return float2(shift(a, 3242174889u), shift(b, 2447445414u));  // R2 sequence
    }
};


// Cosine-weighted hemisphere sample around n (pdf = cos / pi).
inline float3 cosineSampleHemisphere(float3 n, float2 u) {
    float r = sqrt(u.x);
    float phi = 2.0f * M_PI_F * u.y;
    float3 local = float3(r * cos(phi), r * sin(phi), sqrt(max(0.0f, 1.0f - u.x)));
    // Orthonormal basis (Duff et al. 2017)
    float s = n.z >= 0.0f ? 1.0f : -1.0f;
    float a = -1.0f / (s + n.z);
    float b = n.x * n.y * a;
    float3 t  = float3(1.0f + s * n.x * n.x * a, s * b, -s * n.x);
    float3 bt = float3(b, s + n.y * n.y * a, -n.y);
    return normalize(t * local.x + bt * local.y + n * local.z);
}

// ---------------------------------------------------------------------------------------------
// Scene access + ray queries
// ---------------------------------------------------------------------------------------------

// Ray queries. Every kernel reaches the scene through these three functions, implemented twice:
//   CUSTOM_RT = 0: Metal's instance acceleration structure and intersector;
//   CUSTOM_RT = 1: this file's two-level BVH (see "Custom BVH traversal").
struct Ray {
    float3 origin;
    float3 direction;   // need not be normalized; distances are in units of its length
    float  tmin;
    float  tmax;
};
inline Ray makeRay(float3 origin, float3 direction, float tmin, float tmax) {
    Ray r;
    r.origin = origin; r.direction = direction; r.tmin = tmin; r.tmax = tmax;
    return r;
}

constant uint HIT_NO_CLUSTER = 0xFFFFFFFFu;

struct Hit {
    bool   hit;
    float  distance;
    float2 barycentrics;   // weights of the triangle's 2nd and 3rd vertices
    uint   instance;
    uint   primitive;      // triangle index within the instance's mesh (or within its virtual-geometry cluster)
    uint   cluster;        // custom tracer: this frame's selected virtual-geometry cluster, or HIT_NO_CLUSTER
};

#if !CUSTOM_RT

#define SCENE_ACCEL instance_acceleration_structure

Hit intersectClosest(Ray r, uint mask, SCENE_ACCEL accel) {
    intersector<triangle_data, instancing> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), accel, mask);
    Hit h;
    h.hit = res.type == intersection_type::triangle;
    h.distance = res.distance;
    h.barycentrics = res.triangle_barycentric_coord;
    h.instance = res.instance_id;
    h.primitive = res.primitive_id;
    h.cluster = HIT_NO_CLUSTER;
    return h;
}

// Closest hit distance only (INFINITY if none).
float intersectDistance(Ray r, uint mask, SCENE_ACCEL accel) {
    intersector<instancing> isect;   // no triangle_data: barycentrics aren't needed
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), accel, mask);
    return res.type == intersection_type::none ? INFINITY : res.distance;
}

// Any hit (shadow rays): true if something is in the way; `t` = its distance.
bool intersectAny(Ray r, uint mask, SCENE_ACCEL accel, thread float& t) {
    intersector<instancing> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    isect.accept_any_intersection(true);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), accel, mask);
    t = res.distance;
    return res.type != intersection_type::none;
}

#else

// Custom BVH traversal (layouts: BVH.swift / CustomRayTracer.swift). Two top-level trees (static instances, built
// once; moving instances, rebuilt every frame) over per-mesh bottom-level trees. Nodes hold both children's boxes;
// a child ref with bit 31 set is a leaf: an instance (top level) or (count - 1) << 28 | first triangle (bottom).
struct BVHNode {
    float4 lo0;   // xyz = child 0 box min, w = child 0 ref (bits)
    float4 hi0;   // xyz = child 0 box max, w = instance masks under child 0 (bits, top level only)
    float4 lo1;
    float4 hi1;
};

struct RTInstance {
    float4 row0;  // world -> object rows
    float4 row1;
    float4 row2;
    uint blasRoot;
    uint mask;
    uint pad0;
    uint pad1;
};

struct RTScene {
    device const BVHNode*    tlas;        // static top-level nodes, then this frame's dynamic and cluster trees
    device const BVHNode*    blas;
    device const float4*     tris;        // 3 per triangle: v0 (w = triangle index in its mesh), e1, e2
    device const RTInstance* instances;
    device const uint2*      clusters;    // this frame's selected virtual-geometry clusters: (instance, pool offset)
    device const float4*     pool;        // streamed virtual-geometry pages (VirtualGeometry.swift)
    device const uint*       roots;       // [0] = the cluster tree's root ref, written on the GPU every frame
    device const uint*       nodeInstance; // per cluster-tree node: the scene instance it lies in (see RT_ENTER)
    device atomic_uint*      stats;       // RT_STATS builds: rays, top nodes, bottom nodes, instance entries,
                                          // cluster entries, triangle tests
    device const struct VGBlas* vgBlas;   // per virtual instance: its current cut's BLAS (VirtualBLAS.swift)
    uint staticRoot;                      // root refs; RT_NONE = empty tree
    uint dynamicRoot;
    uint virtualBase;                     // the cluster tree's first node
    uint pad;
};

#ifndef RT_STATS
#define RT_STATS 0
#endif
#if RT_STATS
#define RT_STAT(i, n) atomic_fetch_add_explicit(&sc.stats[i], (n), memory_order_relaxed)
#else
#define RT_STAT(i, n)
#endif
// Counters (RT_STATS: global; COST traversals: per ray, for the "Traversal cost" view): 0 rays, 1 top nodes,
// 2 bottom nodes, 3 instance entries, 4 cluster entries, 5 triangle tests, 6 nodes inside virtual instances.
#define RT_COUNT(i, n) { if (COST) cost[i] += (n); RT_STAT(i, n); }

// A virtual instance's BLAS over its current cut (VirtualBLAS.swift): nodes, triangles (v0 e1 e2, w = index), and per
// triangle 3 octahedral normals + 3 half2 UVs.
struct VGBlas {
    device const BVHNode* nodes;
    device const float4*  tris;
    device const uint*    attrs;
    uint                  triangles;   // 0 = no BLAS yet (the instance is skipped)
    uint                  pad;
};

// A virtual-geometry cluster's data in the pool (VirtualGeometryBuilder.clusterBlob): header (2 x uint4), BVH
// nodes, vertices (position + octahedral normal), UVs (half2), triangles (three 8-bit local indices).
struct VGClusterView {
    device const BVHNode* nodes;
    device const float4*  positions;   // xyz, w = octahedral normal bits
    device const uint*    uvs;
    device const uint*    tris;
};
inline VGClusterView vgClusterView(device const float4* blob) {
    uint4 offsets = ((device const uint4*)blob)[1];   // bytes: nodes, positions, UVs, triangles
    device const uchar* base = (device const uchar*)blob;
    VGClusterView v;
    v.nodes = (device const BVHNode*)(base + offsets.x);
    v.positions = (device const float4*)(base + offsets.y);
    v.uvs = (device const uint*)(base + offsets.z);
    v.tris = (device const uint*)(base + offsets.w);
    return v;
}
inline float3 octDecode(uint bits) {
    float2 e = float2(as_type<short2>(bits)) / 32767.0f;
    float3 n = float3(e, 1.0f - abs(e.x) - abs(e.y));
    if (n.z < 0.0f) n.xy = (1.0f - abs(n.yx)) * select(float2(-1.0f), float2(1.0f), n.xy >= 0.0f);
    return normalize(n);
}

#define SCENE_ACCEL constant RTScene&

constant uint RT_LEAF  = 0x80000000u;
constant uint RT_NONE  = 0xFFFFFFFFu;
constant uint RT_STACK = 64;   // top-level depth + bottom-level depth must fit

// Slab test of a box against [tmin, tmax]; tnear = entry distance.
inline bool rtSlab(float3 lo, float3 hi, float3 inv, float3 oi, float tmin, float tmax, thread float& tnear) {
    float3 t0 = fma(lo, inv, oi), t1 = fma(hi, inv, oi);
    float3 tn = min(t0, t1), tf = max(t0, t1);
    tnear = max(max(tn.x, tn.y), max(tn.z, tmin));
    return tnear <= min(min(tf.x, tf.y), min(tf.z, tmax));
}

inline float3 rtSafeInverse(float3 d) {
    return 1.0f / select(d, copysign(float3(1e-12f), d), abs(d) < 1e-12f);
}

// Möller-Trumbore, both faces. Updates h (closest so far) and returns true on a nearer hit.
inline bool rtTriangle(float3 o, float3 d, float4 v0, float4 e1, float4 e2, float tmin, thread Hit& h) {
    float3 pv = cross(d, e2.xyz);
    float det = dot(e1.xyz, pv);
    if (det == 0.0f) return false;
    float inv = 1.0f / det;
    float3 tv = o - v0.xyz;
    float u = dot(tv, pv) * inv;
    if (u < 0.0f || u > 1.0f) return false;
    float3 qv = cross(tv, e1.xyz);
    float v = dot(d, qv) * inv;
    if (v < 0.0f || u + v > 1.0f) return false;
    float t = dot(e2.xyz, qv) * inv;
    if (t < tmin || t > h.distance) return false;
    h.hit = true;
    h.distance = t;
    h.barycentrics = float2(u, v);
    h.primitive = as_type<uint>(v0.w);
    return true;
}

constant uint RT_INSTANCE_EXIT = 0xFFFFFFFEu;   // stack marker: back to the top level (world space) below here
constant uint RT_CLUSTER = 0x40000000u;         // top-level leaf flag: a virtual-geometry cluster, not an instance
constant uint RT_ENTER   = 0x40000000u;         // internal-node ref flag: the subtree holds one virtual instance's
                                                // clusters, in its object space (enter the instance here)
constant uint RT_OBJECT_EXIT = 0xFFFFFFFDu;     // stack marker: back from a cluster's BVH to its instance's subtree

// All levels in one loop: entering an instance switches the ray to object space and pushes a marker; popping the
// marker switches back. Every SIMD lane then runs the same node-fetch code whichever level it is in, instead of
// lanes in a top-level loop waiting for lanes inside a nested bottom-level loop.
// Three top-level trees: static instances, moving instances, and this frame's cut of the virtual meshes. The cut's
// tree splits by instance first: a ref flagged RT_ENTER is one instance's subtree, in its object space, whose leaves
// are clusters with their own small BVHs in the streaming pool. Levels: 0 = world, 1 = inside a virtual instance's
// subtree, 2 = inside a BLAS or a cluster's BVH. Returns true on a hit when ANY.
template <bool ANY, bool COST = false>
inline bool rtTraverse(constant RTScene& sc, Ray r, uint mask, thread Hit& h, thread uint* cost = nullptr) {
    uint stack[RT_STACK];
    uint sp = 0;
    uint ref = RT_NONE;
    uint roots[3] = {sc.roots[0], sc.dynamicRoot, sc.staticRoot};   // the last one found is traversed first
    for (uint i = 0; i < 3; ++i) {
        if (roots[i] == RT_NONE) continue;
        if (ref != RT_NONE) stack[sp++] = ref;
        ref = roots[i];
    }
    if (ref == RT_NONE) return false;
    RT_COUNT(0, 1u);

    float3 worldInv = rtSafeInverse(r.direction), worldOi = -r.origin * worldInv;
    float3 o = r.origin, d = r.direction, inv = worldInv, oi = worldOi;
    uint level = 0;
    uint instance = 0;
    device const BVHNode* bottomNodes = sc.blas;
    device const float4* bottomTris = sc.tris;
    uint cluster = HIT_NO_CLUSTER;
    VGClusterView view;
    while (true) {
        if ((ref & RT_LEAF) == 0) {
            if ((ref & RT_ENTER) != 0) {   // a virtual instance's subtree: into its object space (from the world)
                ref &= ~RT_ENTER;
                uint id = sc.nodeInstance[ref - sc.virtualBase];
                RTInstance inst = sc.instances[id];
                if ((inst.mask & mask) != 0 && sp < RT_STACK) {
                    float4 o4 = float4(r.origin, 1.0f), d4 = float4(r.direction, 0.0f);
                    o = float3(dot(inst.row0, o4), dot(inst.row1, o4), dot(inst.row2, o4));
                    d = float3(dot(inst.row0, d4), dot(inst.row1, d4), dot(inst.row2, d4));
                    inv = rtSafeInverse(d);
                    oi = -o * inv;
                    level = 1;
                    instance = id;
                    stack[sp++] = RT_INSTANCE_EXIT;
                    continue;
                }
            } else {
                BVHNode n = level == 2 ? bottomNodes[ref] : sc.tlas[ref];
                bool top = level < 2;
                RT_COUNT(top ? 1 : 2, 1u);
                RT_COUNT(6, level == 1 ? 1u : 0u);   // inside a virtual instance's subtree
                float t0, t1;
                bool b0 = (!top || (as_type<uint>(n.hi0.w) & mask) != 0) && rtSlab(n.lo0.xyz, n.hi0.xyz, inv, oi, r.tmin, h.distance, t0);
                bool b1 = (!top || (as_type<uint>(n.hi1.w) & mask) != 0) && rtSlab(n.lo1.xyz, n.hi1.xyz, inv, oi, r.tmin, h.distance, t1);
                uint c0 = as_type<uint>(n.lo0.w), c1 = as_type<uint>(n.lo1.w);
                if (b0 && b1) {
                    bool swap = t1 < t0;
                    if (sp < RT_STACK) stack[sp++] = swap ? c0 : c1;
                    ref = swap ? c1 : c0;
                    continue;
                }
                if (b0 || b1) { ref = b0 ? c0 : c1; continue; }
            }
        } else if (level < 2) {
            uint id = ref & ~RT_LEAF;
            if ((id & RT_CLUSTER) != 0) {   // a cluster: into its BVH (already in object space inside a subtree)
                cluster = id & ~RT_CLUSTER;
                uint2 rc = sc.clusters[cluster];
                bool enter = level == 0;    // a lone cluster in the world-space part of the tree
                RTInstance inst;
                if (enter) inst = sc.instances[rc.x];
                if ((!enter || (inst.mask & mask) != 0) && sp < RT_STACK) {
                    if (enter) {
                        float4 o4 = float4(r.origin, 1.0f), d4 = float4(r.direction, 0.0f);
                        o = float3(dot(inst.row0, o4), dot(inst.row1, o4), dot(inst.row2, o4));
                        d = float3(dot(inst.row0, d4), dot(inst.row1, d4), dot(inst.row2, d4));
                        inv = rtSafeInverse(d);
                        oi = -o * inv;
                        instance = rc.x;
                    }
                    view = vgClusterView(sc.pool + rc.y);
                    bottomNodes = view.nodes;
                    RT_COUNT(4, 1u);
                    stack[sp++] = enter ? RT_INSTANCE_EXIT : RT_OBJECT_EXIT;
                    level = 2;
                    ref = 0;
                    continue;
                }
            } else {                         // an ordinary instance (or a virtual mesh's cut): into its BLAS
                RTInstance inst = sc.instances[id];
                device const BVHNode* nodes = sc.blas;
                device const float4* tris = sc.tris;
                uint root = inst.blasRoot;
                bool present = true;
                if (inst.pad0 != 0) {
                    VGBlas e = sc.vgBlas[inst.pad0 - 1];
                    nodes = e.nodes; tris = e.tris; root = 0;
                    present = e.triangles != 0;
                }
                if (present && (inst.mask & mask) != 0 && sp < RT_STACK) {
                    float4 o4 = float4(r.origin, 1.0f), d4 = float4(r.direction, 0.0f);
                    o = float3(dot(inst.row0, o4), dot(inst.row1, o4), dot(inst.row2, o4));
                    d = float3(dot(inst.row0, d4), dot(inst.row1, d4), dot(inst.row2, d4));   // not normalized: t is shared
                    inv = rtSafeInverse(d);
                    oi = -o * inv;
                    level = 2;
                    instance = id;
                    cluster = HIT_NO_CLUSTER;
                    bottomNodes = nodes;
                    bottomTris = tris;
                    RT_COUNT(3, 1u);
                    stack[sp++] = RT_INSTANCE_EXIT;
                    ref = root;
                    continue;
                }
            }
        } else if (ref != RT_NONE) {   // RT_NONE: the empty child of a single-leaf mesh
            uint first = ref & 0x0FFFFFFFu, end = first + ((ref >> 28) & 7u) + 1u;
            RT_COUNT(5, end - first);
            if (cluster != HIT_NO_CLUSTER) {
                for (uint t = first; t < end; ++t) {
                    uint packed = view.tris[t];
                    float3 p0 = view.positions[packed & 0xFFu].xyz, p1 = view.positions[(packed >> 8) & 0xFFu].xyz;
                    float3 p2 = view.positions[(packed >> 16) & 0xFFu].xyz;
                    if (rtTriangle(o, d, float4(p0, as_type<float>(t)), float4(p1 - p0, 0.0f), float4(p2 - p0, 0.0f), r.tmin, h)) {
                        h.instance = instance;
                        h.cluster = cluster;
                        if (ANY) return true;
                    }
                }
            } else {
                for (uint t = first; t < end; ++t) {
                    if (rtTriangle(o, d, bottomTris[3 * t], bottomTris[3 * t + 1], bottomTris[3 * t + 2], r.tmin, h)) {
                        h.instance = instance;
                        h.cluster = HIT_NO_CLUSTER;
                        if (ANY) return true;
                    }
                }
            }
        }
        while (true) {
            if (sp == 0) return false;
            ref = stack[--sp];
            if (ref == RT_INSTANCE_EXIT) {
                level = 0;
                o = r.origin; d = r.direction; inv = worldInv; oi = worldOi;
                continue;
            }
            if (ref == RT_OBJECT_EXIT) {
                level = 1;
                continue;
            }
            break;
        }
    }
}

Hit intersectClosest(Ray r, uint mask, SCENE_ACCEL sc) {
    Hit h;
    h.hit = false;
    h.distance = r.tmax;
    h.barycentrics = float2(0.0f);
    h.instance = 0;
    h.primitive = 0;
    h.cluster = HIT_NO_CLUSTER;
    rtTraverse<false>(sc, r, mask, h);
    return h;
}

// Closest hit, counting the traversal's work into cost[0..6] (see RT_COUNT): the "Traversal cost" view only.
Hit intersectClosestCost(Ray r, uint mask, SCENE_ACCEL sc, thread uint* cost) {
    Hit h;
    h.hit = false;
    h.distance = r.tmax;
    h.barycentrics = float2(0.0f);
    h.instance = 0;
    h.primitive = 0;
    h.cluster = HIT_NO_CLUSTER;
    rtTraverse<false, true>(sc, r, mask, h, cost);
    return h;
}

float intersectDistance(Ray r, uint mask, SCENE_ACCEL sc) {
    Hit h = intersectClosest(r, mask, sc);
    return h.hit ? h.distance : INFINITY;
}

bool intersectAny(Ray r, uint mask, SCENE_ACCEL sc, thread float& t) {
    Hit h;
    h.hit = false;
    h.distance = r.tmax;
    h.cluster = HIT_NO_CLUSTER;
    bool hit = rtTraverse<true>(sc, r, mask, h);
    t = h.distance;
    return hit;
}

#endif

struct SceneData {
    device const float3*       positions;
    device const float3*       normals;
    device const uint*         indices;
    device const MeshData*     meshes;
    device const InstanceData* instances;
    device const Material*     materials;
    device const float2*       uvs;
    device const MaterialTexture* textures;
    device const float*        minLod;
    device atomic_uint*        feedback;
    device const EmissiveTriangle* emissive;
    device const Light*        lights;
    uint                       lightCount;
};

inline void bindShading(thread SceneData& s, constant SceneShading& shading) {
    s.materials = shading.materials;
    s.uvs = shading.uvs;
    s.textures = shading.textures;
    s.minLod = shading.minLod;
    s.feedback = shading.feedback;
    s.emissive = shading.emissive;
}

struct Surface {
    bool   hit;
    float3 position;      // world space, this frame
    float3 prevPosition;  // same surface point, previous frame (for motion vectors)
    float3 normal;        // smooth shading normal (interpolated vertex normals), world space, not face-forwarded
    float3 geomNormal;    // the triangle's true normal, world space, not face-forwarded
    float3 albedo;        // base colour (diffuse reflectance; metals get their colour from specular in a later step)
    float3 emission;
    float  metallic;
    float  roughness;
    float  specular;      // specular weight: 0 = diffuse-only material
    float3 f0;            // specular reflectance at normal incidence (0 for diffuse-only materials)
    uint   instanceId;
    bool   lightEmitter;  // its emission is sampled as an emissive-mesh light (Material.params.z)
};

// Emission a GI or bounce ray picks up at a hit: none from emissive-mesh lights, whose light next-event estimation
// and the light maps already deliver (as the light spheres, which GI rays don't even see).
inline float3 giEmission(thread const Surface& h) { return h.lightEmitter ? float3(0.0f) : h.emission; }

// ---------------------------------------------------------------------------------------------
// Specular BRDF: GGX with height-correlated Smith visibility and Schlick Fresnel (F90 = specular weight).
// ---------------------------------------------------------------------------------------------

constant float MIN_ROUGHNESS = 0.03f;     // perceptual; keeps highlights of small lights finite
constant float REFLECTION_MAX_ROUGHNESS = 0.75f;   // rougher: indirect specular from the diffuse GI (no ray)

inline float ggxD(float NoH, float a) {
    float a2 = a * a, d = NoH * NoH * (a2 - 1.0f) + 1.0f;
    return a2 / (M_PI_F * d * d);
}
inline float smithVisibility(float NoV, float NoL, float a) {   // G2 / (4 NoL NoV), height-correlated
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0f - a2) + a2), gl = NoV * sqrt(NoL * NoL * (1.0f - a2) + a2);
    return 0.5f / max(gv + gl, 1e-7f);
}
inline float3 schlick(float3 f0, float f90, float VoH) {
    float f = pow(1.0f - saturate(VoH), 5.0f);
    return f0 + (f90 - f0) * f;
}
// Hemispherical-directional specular albedo, analytic fit (Karis, "Physically Based Shading on Mobile").
inline float3 specularAlbedo(float3 f0, float f90, float roughness, float NoV) {
    const float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f), c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28f * NoV)) * r.x + r.y;
    float2 ab = float2(-1.04f, 1.04f) * a004 + r.zw;
    return f0 * ab.x + f90 * ab.y;
}
inline float specularF90(float3 f0) { return any(f0 > 0.0f) ? 1.0f : 0.0f; }   // glTF materials 1, generated ones 0

// Albedo a secondary hit (GI rays, path bounces, reflection hits) reflects with: diffuse plus, as a diffuse
// approximation, the specular albedo at normal incidence, so metals don't turn black in indirect light.
inline float3 hitAlbedo(thread const struct Surface& sf) {
    return sf.albedo + (sf.specular > 0.0f ? specularAlbedo(sf.f0, sf.specular, max(sf.roughness, MIN_ROUGHNESS), 1.0f) : float3(0.0f));
}

// GGX visible-normal sampling (Heitz 2018), in the frame where the normal is +z.
inline float3 sampleGGXVNDF(float3 ve, float a, float2 u) {
    float3 vh = normalize(float3(a * ve.x, a * ve.y, ve.z));
    float lensq = vh.x * vh.x + vh.y * vh.y;
    float3 t1 = lensq > 0.0f ? float3(-vh.y, vh.x, 0.0f) * rsqrt(lensq) : float3(1.0f, 0.0f, 0.0f);
    float3 t2 = cross(vh, t1);
    float r = sqrt(u.x), phi = 2.0f * M_PI_F * u.y;
    float p1 = r * cos(phi), p2 = r * sin(phi);
    float sv = 0.5f * (1.0f + vh.z);
    p2 = (1.0f - sv) * sqrt(max(0.0f, 1.0f - p1 * p1)) + sv * p2;
    float3 nh = p1 * t1 + p2 * t2 + sqrt(max(0.0f, 1.0f - p1 * p1 - p2 * p2)) * vh;
    return normalize(float3(a * nh.x, a * nh.y, max(0.0f, nh.z)));
}
inline void tangentFrame(float3 n, thread float3& t, thread float3& b) {   // Duff et al. 2017
    float s = n.z >= 0.0f ? 1.0f : -1.0f;
    float a = -1.0f / (s + n.z), c = n.x * n.y * a;
    t = float3(1.0f + s * n.x * n.x * a, s * c, -s * n.x);
    b = float3(c, s + n.y * n.y * a, -n.y);
}

constexpr sampler materialSampler(filter::linear, mip_filter::linear, address::repeat);

// Samples a material texture at the level of a footprint: lodBase = log2 of the footprint in UV units (see
// traceSurface); the texture's resolution is added here.
// Streamed textures: sampled hits (`record`: a rotating eighth of the pixels' primary rays)
// count the level they need in a per-texture histogram; the streamer serves the finest level a meaningful share of
// samples needs (single bad estimates, from degenerate UVs, don't pull in 4K mips). Every sample is clamped to the
// finest level that is resident.
inline float4 sampleMaterial(thread const struct SceneData& s, uint index, float2 uv, float lodBase, bool record) {
    texture2d<float> t = s.textures[index].t;
    float lod = max(lodBase + 0.5f * log2(float(t.get_width()) * float(t.get_height())), 0.0f);
    if (record) atomic_fetch_add_explicit(&s.feedback[16 * index + min(uint(lod), 15u)], 1u, memory_order_relaxed);
    return t.sample(materialSampler, uv, level(max(lod, s.minLod[index])));
}

// Orients a hit's normals toward the side the ray came from. The geometric normal decides the side; the smooth
// shading normal is flipped onto that side. Face-forwarding the smooth normal alone flips it inward at
// silhouettes, where it can face away from the ray even though the triangle faces it, which put ray origins
// inside the sphere and caused black dots along its edges.
inline void orientNormals(thread const Surface& sf, float3 rayDir, thread float3& ng, thread float3& ns) {
    ng = dot(sf.geomNormal, rayDir) > 0.0f ? -sf.geomNormal : sf.geomNormal;
    ns = dot(sf.normal, ng) < 0.0f ? -sf.normal : sf.normal;
}

// Pixel-footprint spreads for texture filtering (ray cones without curvature): radians of spread per unit distance.
// Primary rays pass their pixel's angle; GI rays a coarse fixed spread, since their hits get integrated anyway.
constant float GI_RAY_SPREAD = 0.05f;

// The hit triangle's vertices (object space): from a cluster in the streaming pool, a virtual instance's BLAS over
// its cut, or the indexed mesh buffers.
struct HitVertices {
    float3 p[3];
    float3 n[3];
    float2 t[3];
};
inline HitVertices fetchHitVertices(Hit res, InstanceData inst, SCENE_ACCEL accel, thread const SceneData& s) {
    HitVertices v;
#if CUSTOM_RT
    if (res.cluster != HIT_NO_CLUSTER) {
        // Virtual geometry: the hit cluster's vertices, in the streaming pool.
        VGClusterView view = vgClusterView(accel.pool + accel.clusters[res.cluster].y);
        uint packed = view.tris[res.primitive];
        uint3 i = uint3(packed & 0xFFu, (packed >> 8) & 0xFFu, (packed >> 16) & 0xFFu);
        for (uint k = 0; k < 3; ++k) {
            float4 q = view.positions[i[k]];
            v.p[k] = q.xyz;
            v.n[k] = octDecode(as_type<uint>(q.w));
            v.t[k] = float2(as_type<half2>(view.uvs[i[k]]));
        }
        return v;
    }
    if (inst.pad1 != 0) {
        // Virtual geometry, per-instance BLAS over the cut: positions from its triangles, attributes alongside.
        VGBlas e = accel.vgBlas[inst.pad1 - 1];
        float4 v0 = e.tris[3 * res.primitive], e1 = e.tris[3 * res.primitive + 1], e2 = e.tris[3 * res.primitive + 2];
        v.p[0] = v0.xyz; v.p[1] = v0.xyz + e1.xyz; v.p[2] = v0.xyz + e2.xyz;
        device const uint* a = e.attrs + 6 * res.primitive;
        for (uint k = 0; k < 3; ++k) {
            v.n[k] = octDecode(a[k]);
            v.t[k] = float2(as_type<half2>(a[3 + k]));
        }
        return v;
    }
#endif
    MeshData mesh = s.meshes[inst.meshIndex];
    uint base = mesh.firstIndex + res.primitive * 3;
    for (uint k = 0; k < 3; ++k) {
        uint i = s.indices[base + k];
        v.p[k] = s.positions[i];
        v.n[k] = s.normals[i];
        v.t[k] = s.uvs[i];
    }
    return v;
}

Surface traceSurface(Ray r, uint mask, SCENE_ACCEL accel, thread const SceneData& s, float spread, bool record = false) {
    Hit res = intersectClosest(r, mask, accel);

    Surface sf;
    sf.hit = false;
    sf.position = sf.prevPosition = sf.normal = sf.geomNormal = sf.albedo = sf.emission = float3(0.0f);
    sf.metallic = sf.specular = 0.0f;
    sf.roughness = 1.0f;
    sf.f0 = float3(0.0f);
    sf.instanceId = 0;
    sf.lightEmitter = false;
    if (!res.hit) return sf;

    InstanceData inst = s.instances[res.instance];
    float2 bc = res.barycentrics;
    float w0 = 1.0f - bc.x - bc.y;
    HitVertices hv = fetchHitVertices(res, inst, accel, s);
    float3 p0 = hv.p[0], p1 = hv.p[1], p2 = hv.p[2], n0 = hv.n[0], n1 = hv.n[1], n2 = hv.n[2];
    float2 t0 = hv.t[0], t1 = hv.t[1], t2 = hv.t[2];
    float3 objPos = p0 * w0 + p1 * bc.x + p2 * bc.y;
    float3 objN   = n0 * w0 + n1 * bc.x + n2 * bc.y;
    float3 objNg  = cross(p1 - p0, p2 - p0);

    Material mat = s.materials[inst.materialIndex];
    sf.hit = true;
    sf.position = (inst.transform * float4(objPos, 1.0f)).xyz;
    sf.prevPosition = (inst.prevTransform * float4(objPos, 1.0f)).xyz;
    sf.normal = normalize((inst.normalMatrix * float4(objN, 0.0f)).xyz);
    sf.geomNormal = normalize((inst.normalMatrix * float4(objNg, 0.0f)).xyz);
    sf.albedo = mat.albedo.rgb;
    sf.emission = mat.emission.rgb;
    sf.metallic = mat.albedo.a;
    sf.roughness = mat.emission.a;
    sf.specular = mat.params.x;
    sf.instanceId = res.instance;
    sf.lightEmitter = mat.params.z > 0.0f;

    if (any(mat.textures != uint4(NO_TEXTURE))) {
        float2 uv = t0 * w0 + t1 * bc.x + t2 * bc.y;
        // Texture level from the ray's footprint: width = distance x spread, stretched by the incidence angle,
        // converted to UV units by the triangle's UV-to-world area ratio.
        float3 e1 = (inst.transform * float4(p1 - p0, 0.0f)).xyz, e2 = (inst.transform * float4(p2 - p0, 0.0f)).xyz;
        float2 d1 = t1 - t0, d2 = t2 - t0;
        float worldArea = length(cross(e1, e2));
        float uvArea = abs(d1.x * d2.y - d1.y * d2.x);
        float cosTheta = max(abs(dot(normalize(r.direction), sf.geomNormal)), 0.2f);
        float footprint = res.distance * length(r.direction) * spread / cosTheta;
        // UV units per world unit along the triangle's most stretched edge (like the hardware's larger derivative):
        // the area ratio would call a sliver in UV space "magnified" and ask for the finest mip.
        float3 e3 = e2 - e1;
        float2 d3 = d2 - d1;
        float stretch = max(length(d1) / max(length(e1), 1e-12f),
                            max(length(d2) / max(length(e2), 1e-12f), length(d3) / max(length(e3), 1e-12f)));
        float lodBase = worldArea > 0.0f && stretch > 0.0f ? log2(max(footprint, 1e-8f) * stretch) : 0.0f;

        if (mat.textures.x != NO_TEXTURE) sf.albedo *= sampleMaterial(s, mat.textures.x, uv, lodBase, record).rgb;
        if (mat.textures.y != NO_TEXTURE) {
            float4 mr = sampleMaterial(s, mat.textures.y, uv, lodBase, record);
            sf.roughness *= mr.g;
            sf.metallic *= mr.b;
        }
        if (mat.textures.w != NO_TEXTURE) sf.emission *= sampleMaterial(s, mat.textures.w, uv, lodBase, record).rgb;
        if (mat.textures.z != NO_TEXTURE && uvArea > 0.0f) {
            // Tangent frame from the triangle's UV derivatives (no stored tangents), Gram-Schmidt against the
            // shading normal; normal maps are tangent space, +Y = +V.
            float invDet = 1.0f / (d1.x * d2.y - d1.y * d2.x);
            float3 T = (e1 * d2.y - e2 * d1.y) * invDet, B = (e2 * d1.x - e1 * d2.x) * invDet;
            float3 N = sf.normal;
            T = T - N * dot(N, T);
            B = B - N * dot(N, B) - T * (dot(T, B) / max(dot(T, T), 1e-12f));
            if (dot(T, T) > 1e-12f && dot(B, B) > 1e-12f) {
                float3 m = sampleMaterial(s, mat.textures.z, uv, lodBase, record).xyz * 2.0f - 1.0f;
                m.xy *= mat.params.y;
                sf.normal = normalize(normalize(T) * m.x + normalize(B) * m.y + N * max(m.z, 1e-3f));
            }
        }
    }
    if (sf.specular > 0.0f) {   // metallic-roughness: metals reflect their base colour, dielectrics 4% (x weight)
        sf.f0 = mix(float3(0.04f * sf.specular), sf.albedo, sf.metallic);
        sf.albedo *= 1.0f - sf.metallic;
    }
    return sf;
}

// ---------------------------------------------------------------------------------------------
// Lights. Every type answers the same questions, so the kernels never look at a light's shape:
//   lightUnshadowed     diffuse light at p if nothing is in the way (albedo divided out); also every pick's weight
//   lightShadowTarget   a random point of the light for a soft-shadow ray (the sun: a far point inside its disc)
//   lightSpecular       GGX specular light, unshadowed (representative point, Karis 2013)
//   penumbraWidth       half width of the penumbra an occluder at distance d casts (sizes the shadow filter)
//   lightMapVisibility  visibility from the light's light map (secondary hits)
// Emissive-mesh lights answer lightUnshadowed and the light map with a proxy (their bounding sphere and mean
// normal), for picking and GI; their direct light is sampled per triangle (sampleMeshLight).
// ---------------------------------------------------------------------------------------------

inline uint lightType(Light light) {
    return (LIGHT_TYPES & (LIGHT_TYPES - 1u)) == 0 ? ctz(LIGHT_TYPES) : uint(light.color.w) >> 2;   // one type: known
}
inline uint lightGroup(Light light) { return uint(light.color.w) & 3u; }

// Shadow ray from `from` to `to`: true if nothing (but light spheres) is in the way. `blocker` = distance to an
// occluder (any one, not necessarily the nearest), 0 if visible: the shadow denoiser estimates penumbrae from it.
bool isVisibleBlocker(float3 from, float3 to, SCENE_ACCEL accel, thread float& blocker) {
    float3 d = to - from;
    float dist = length(d);
    float t;
    bool hit = intersectAny(makeRay(from, d / dist, 0.0f, max(dist - RAY_EPSILON, 0.0f)), MASK_GEOMETRY, accel, t);
    blocker = hit ? max(t, 1e-3f) : 0.0f;
    return !hit;
}

bool isVisible(float3 from, float3 to, SCENE_ACCEL accel) {
    float b;
    return isVisibleBlocker(from, to, accel, b);
}

// Spot lights: smooth falloff from the inner to the outer cone, for the unit direction from the light to a point.
inline float spotFactor(Light light, float3 fromLight) {
    return smoothstep(light.params.x, light.params.y, dot(fromLight, light.axis.xyz));
}

// Rect lights: corners, counter-clockwise seen from the emitting side.
struct RectCorners { float3 c[4]; };
inline RectCorners rectCorners(Light light) {
    float3 U = light.params.xyz;
    float3 V = normalize(cross(light.axis.xyz, U)) * light.params.w;
    float3 o = light.positionRadius.xyz;
    RectCorners r;
    r.c[0] = o - U - V; r.c[1] = o + U - V; r.c[2] = o + U + V; r.c[3] = o - U + V;
    return r;
}

// Irradiance at p (normal n) from a rect of unit radiance: Lambert's polygon formula, the sum over the edges of the
// angle each subtends times the cosine between n and the normal of its plane through p. Exact while the whole
// rect is above p's horizon; clamped at 0 (the usual approximation) when it crosses it.
inline float rectIrradiance(thread const RectCorners& r, float3 p, float3 center, float3 n) {
    float3 F = float3(0.0f);
    for (uint k = 0; k < 4; ++k) {
        float3 a = normalize(r.c[k] - p), b = normalize(r.c[(k + 1) & 3] - p);
        float3 c = cross(a, b);
        float s = length(c);
        if (s > 1e-7f) F += c * (atan2(s, dot(a, b)) / s);
    }
    if (dot(F, center - p) < 0.0f) F = -F;   // F points toward the rect, whichever way its winding looks from p
    return max(0.5f * dot(F, n), 0.0f);
}

// Tube lights: a thin cylinder of uniform radiance, so a length ds of it has intensity proportional to its
// projected width, sin(angle to the axis) = D / |w| (D = the receiver's distance to the line, w = point - receiver).
// Returns the integral of (n.w) D / |w|^4 along the segment a -> b, exact (Lambert's cylinder), with D clamped to the
// tube radius; irradiance = that x the intensity per unit length at sin = 1.
inline float tubeIrradiance(float3 a, float3 b, float3 n, float radius) {
    float3 d = b - a;
    float len = length(d);
    if (len < 1e-6f) return 0.0f;
    float3 t = d / len;
    float c = dot(a, t);
    float D2 = max(dot(a, a) - c * c, radius * radius), D = sqrt(D2);
    // With x = s + c: n.w = alpha + beta x, |w|^2 = x^2 + D^2.
    float alpha = dot(n, a) - c * dot(n, t), beta = dot(n, t);
    float x0 = c, x1 = c + len;
    float r0 = x0 * x0 + D2, r1 = x1 * x1 + D2;
    float i0 = (x1 / r1 - x0 / r0) / (2.0f * D2) + (atan(x1 / D) - atan(x0 / D)) / (2.0f * D2 * D);   // int dx / (x^2+D^2)^2
    float i1 = 0.5f * (1.0f / r0 - 1.0f / r1);                                                         // int x dx / (x^2+D^2)^2
    return max(D * (alpha * i0 + beta * i1), 0.0f);
}

// Clips segment a -> b (relative to the receiver) to the half space in front of plane normal n.
inline bool clipSegment(thread float3& a, thread float3& b, float3 n) {
    float ha = dot(n, a), hb = dot(n, b);
    if (ha <= 0.0f && hb <= 0.0f) return false;
    if (ha < 0.0f) a = mix(a, b, ha / (ha - hb));
    else if (hb < 0.0f) b = mix(b, a, hb / (hb - ha));
    return true;
}

// Diffuse lighting from one light if nothing is in the way, with albedo divided out:
//   outgoing radiance = albedo * returned value * visibility.
// n = shading normal, ng = geometric normal (both oriented); a light behind the surface contributes nothing.
// Emissive-mesh lights' proxy: intensity sum(L A) / 4 if round, sum(L A) |cos| along the mean normal if flat
// (two-sided); the cosine at the receiver widened by the bounding sphere's angular size, so no part of the emitter
// is given zero weight. For picking and for GI (light maps); direct light samples the triangles.
inline float3 meshLightUnshadowed(Light light, float3 p, float3 n, float3 ng) {
    float3 toLight = light.positionRadius.xyz - p;
    float radius = light.positionRadius.w;
    float dist2 = max(dot(toLight, toLight), radius * radius);
    float d = sqrt(dot(toLight, toLight));
    float3 l = toLight / max(d, 1e-6f);
    float sinA = saturate(radius / max(d, 1e-6f));
    float cosTheta = saturate((dot(n, l) + sinA) / (1.0f + sinA));
    if (cosTheta <= 0.0f || dot(ng, l) + sinA <= 0.0f) return float3(0.0f);
    float flat = light.params.z;
    float intensity = (1.0f - flat) * 0.25f + flat * abs(dot(light.axis.xyz, l));
    return light.color.rgb * (intensity * cosTheta / (M_PI_F * dist2));
}

float3 lightUnshadowedOther(Light light, float3 p, float3 n, float3 ng);

inline float3 lightUnshadowed(Light light, float3 p, float3 n, float3 ng) {
    uint type = lightType(light);
    if (!POINT_LIGHTS_ONLY && type > LIGHT_SPOT) return lightUnshadowedOther(light, p, n, ng);
    float3 toLight = light.positionRadius.xyz - p;
    float radius = light.positionRadius.w;
    float dist2 = max(dot(toLight, toLight), radius * radius);
    float cosTheta = dot(n, normalize(toLight));
    if (cosTheta <= 0.0f || dot(toLight, ng) <= 0.0f) return float3(0.0f);
    float3 e = light.color.rgb * cosTheta / (M_PI_F * dist2);
    if (type == LIGHT_SPOT) e *= spotFactor(light, -normalize(toLight));
    return e;
}

// The other types: sun, rect, tube and the mesh lights' proxy.
float3 lightUnshadowedOther(Light light, float3 p, float3 n, float3 ng) {
    uint type = lightType(light);
    if (type == LIGHT_SUN) {
        float3 l = light.axis.xyz;
        float cosTheta = dot(n, l);
        if (cosTheta <= 0.0f || dot(ng, l) <= 0.0f) return float3(0.0f);
        return light.color.rgb * (cosTheta / M_PI_F);
    }
    if (type == LIGHT_RECT) {
        float3 center = light.positionRadius.xyz;
        if (dot(p - center, light.axis.xyz) <= 0.0f) return float3(0.0f);   // behind the emitting side
        RectCorners r = rectCorners(light);
        float above = max(max(dot(ng, r.c[0] - p), dot(ng, r.c[1] - p)), max(dot(ng, r.c[2] - p), dot(ng, r.c[3] - p)));
        if (above <= 0.0f) return float3(0.0f);
        return light.color.rgb * (rectIrradiance(r, p, center, n) / M_PI_F);
    }
    if (type == LIGHT_TUBE) {
        float3 a = light.positionRadius.xyz - light.axis.xyz - p, b = light.positionRadius.xyz + light.axis.xyz - p;
        if (!clipSegment(a, b, ng) || !clipSegment(a, b, n)) return float3(0.0f);
        // Intensity per unit length broadside: 4 I / (pi length), so the tube emits what a sphere light of
        // intensity I does (power 4 pi I).
        float len = 2.0f * length(light.axis.xyz);
        float perLength = 4.0f / (M_PI_F * max(len, 1e-6f));
        return light.color.rgb * (perLength * tubeIrradiance(a, b, n, light.positionRadius.w) / M_PI_F);
    }
    if (type == LIGHT_MESH) return meshLightUnshadowed(light, p, n, ng);
    return float3(0.0f);
}

// A random point of the light, for a soft-shadow ray from p.
inline float3 lightShadowTarget(Light light, float3 p, float2 u) {
    uint type = lightType(light);
    if (type == LIGHT_SUN) {
        // Uniform in the sun's cone, far away.
        float cosMax = cos(light.positionRadius.w);
        float cosT = 1.0f - u.x * (1.0f - cosMax), sinT = sqrt(max(0.0f, 1.0f - cosT * cosT));
        float phi = 2.0f * M_PI_F * u.y;
        float3 t, b;
        tangentFrame(light.axis.xyz, t, b);
        return p + (light.axis.xyz * cosT + (t * cos(phi) + b * sin(phi)) * sinT) * 1e4f;
    }
    if (type == LIGHT_RECT) {
        float3 U = light.params.xyz, V = normalize(cross(light.axis.xyz, U)) * light.params.w;
        return light.positionRadius.xyz + U * (2.0f * u.x - 1.0f) + V * (2.0f * u.y - 1.0f);
    }
    if (type == LIGHT_TUBE) {
        float3 t, b;
        tangentFrame(normalize(light.axis.xyz), t, b);
        float phi = 2.0f * M_PI_F * u.y;
        return light.positionRadius.xyz + light.axis.xyz * (2.0f * u.x - 1.0f)
             + (t * cos(phi) + b * sin(phi)) * light.positionRadius.w;
    }
    if (type == LIGHT_MESH) return light.positionRadius.xyz;   // not used: mesh lights sample triangles
    // Sphere and spot: uniform on the sphere.
    float z = 1.0f - 2.0f * u.x;
    float rr = sqrt(max(0.0f, 1.0f - z * z));
    float phi = 2.0f * M_PI_F * u.y;
    return light.positionRadius.xyz + light.positionRadius.w * float3(rr * cos(phi), rr * sin(phi), z);
}

// GGX light from one direction l carrying illuminance E, widened by Karis's energy normalisation.
inline float3 ggxFromDirection(float3 E, float3 l, float normalisation, float3 n, float3 v, float3 f0, float a) {
    float3 h = normalize(l + v);
    float NoL = saturate(dot(n, l)), NoV = max(dot(n, v), 1e-4f), NoH = saturate(dot(n, h)), VoH = saturate(dot(v, h));
    float3 F = schlick(f0, specularF90(f0), VoH);
    return E * (ggxD(NoH, a) * smithVisibility(NoV, NoL, a) * NoL * normalisation) * F;
}

// Specular light from a light, unshadowed: GGX with the representative point (Karis 2013, the point of the light
// closest to the reflection ray) and its energy normalisation. Radiance, Fresnel included, albedo-free.
inline float3 lightSpecular(Light light, float3 p, float3 n, float3 ng, float3 v, float3 f0, float roughness) {
    uint type = lightType(light);
    float a = max(roughness, MIN_ROUGHNESS); a *= a;
    float3 r = reflect(-v, n);
    if (type == LIGHT_SUN) {
        float3 w = light.axis.xyz;
        if (dot(n, w) <= 0.0f || dot(ng, w) <= 0.0f) return float3(0.0f);
        float theta = light.positionRadius.w, cosR = dot(r, w);
        float3 l = w;
        if (cosR < cos(theta)) {   // the reflection ray misses the disc: its nearest point
            float3 perp = r - w * cosR;
            float len = length(perp);
            if (len > 1e-6f) l = w * cos(theta) + perp * (sin(theta) / len);
        }
        float aPrime = saturate(a + 0.5f * theta);
        return ggxFromDirection(light.color.rgb, l, (a / aPrime) * (a / aPrime), n, v, f0, a);
    }
    if (type == LIGHT_RECT) {
        float3 c = light.positionRadius.xyz, N = light.axis.xyz;
        if (dot(p - c, N) <= 0.0f) return float3(0.0f);
        float3 U = light.params.xyz;
        float hw = length(U), hh = light.params.w;
        float3 Uh = U / hw, Vh = normalize(cross(N, U));
        // Where the reflection ray meets the light's plane (or, going away from it, the point straight ahead of
        // it), clamped into the rect.
        float denom = dot(r, N);
        float3 hitPlane = denom < -1e-4f ? p + r * (dot(c - p, N) / denom) : p + r * length(c - p);
        float3 q = hitPlane - c;
        q = c + Uh * clamp(dot(q, Uh), -hw, hw) + Vh * clamp(dot(q, Vh), -hh, hh);
        float3 L = q - p;
        float dist2 = dot(L, L), dist = sqrt(dist2);
        float3 l = L / max(dist, 1e-6f);
        if (dot(n, l) <= 0.0f || dot(ng, l) <= 0.0f) return float3(0.0f);
        float area = 4.0f * hw * hh;
        float solidAngle = min(area * max(-dot(N, l), 0.0f) / max(dist2, 1e-6f), 2.0f * M_PI_F);
        float aPrime = saturate(a + sqrt(area / M_PI_F) / (2.0f * max(dist, 1e-3f)));
        return ggxFromDirection(light.color.rgb * solidAngle, l, (a / aPrime) * (a / aPrime), n, v, f0, a);
    }
    if (type == LIGHT_TUBE) {
        float radius = light.positionRadius.w;
        float3 L0 = light.positionRadius.xyz - light.axis.xyz - p, L1 = light.positionRadius.xyz + light.axis.xyz - p;
        float3 Ld = L1 - L0;
        float len2 = dot(Ld, Ld), rLd = dot(r, Ld);
        float t = saturate((dot(r, L0) * rLd - dot(L0, Ld)) / max(len2 - rLd * rLd, 1e-6f));
        float3 L = L0 + Ld * t;                                   // the segment's point nearest the reflection ray
        float3 toRay = dot(L, r) * r - L;
        L += toRay * saturate(radius / max(length(toRay), 1e-6f));   // then the nearest point of its cross-section
        float dist2 = max(dot(L, L), radius * radius), dist = sqrt(dist2);
        float3 l = L / sqrt(max(dot(L, L), 1e-12f));
        if (dot(n, l) <= 0.0f || dot(ng, l) <= 0.0f) return float3(0.0f);
        float aSphere = saturate(a + radius / (2.0f * dist));
        float aLine = saturate(a + sqrt(len2) / (4.0f * dist));
        float normalisation = (a / aSphere) * (a / aSphere) * (a / aLine);
        return ggxFromDirection(light.color.rgb / dist2, l, normalisation, n, v, f0, a);
    }
    if (type == LIGHT_MESH) return float3(0.0f);   // reflection rays see mesh lights themselves
    // Sphere and spot.
    float3 L = light.positionRadius.xyz - p;
    float radius = light.positionRadius.w;
    float dist2 = max(dot(L, L), radius * radius), dist = sqrt(dist2);
    if (dot(n, L) <= 0.0f || dot(ng, L) <= 0.0f) return float3(0.0f);
    float3 toRay = dot(L, r) * r - L;
    float3 l = normalize(L + toRay * saturate(radius / max(length(toRay), 1e-6f)));
    float aPrime = saturate(a + radius / (2.0f * dist));
    float normalisation = (a / aPrime) * (a / aPrime);
    float3 h = normalize(l + v);
    float NoL = saturate(dot(n, l)), NoV = max(dot(n, v), 1e-4f), NoH = saturate(dot(n, h)), VoH = saturate(dot(v, h));
    float3 F = schlick(f0, specularF90(f0), VoH);
    float3 s = light.color.rgb * (ggxD(NoH, a) * smithVisibility(NoV, NoL, a) * NoL * normalisation / dist2) * F;
    if (type == LIGHT_SPOT) s *= spotFactor(light, -normalize(L));
    return s;
}

// Emissive-mesh lights: one point on one triangle (picked by the triangles' emitted power), as a one-sample estimate
// of the light's diffuse lighting at p, unshadowed, albedo divided out. `target` = the point, pulled 1% toward p,
// for the shadow ray (so an emitter traced at a coarser level of detail doesn't shadow itself).
float3 sampleMeshLight(Light light, float3 p, float3 n, float3 ng, float2 u, thread const SceneData& s, thread float3& target) {
    uint first = as_type<uint>(light.params.x), count = as_type<uint>(light.params.y);
    target = light.positionRadius.xyz;
    if (count == 0) return float3(0.0f);
    uint lo = 0, hi = count - 1;
    while (lo < hi) {   // first triangle whose cumulative probability exceeds u.x
        uint mid = (lo + hi) / 2;
        if (s.emissive[first + mid].v0.w > u.x) hi = mid; else lo = mid + 1;
    }
    EmissiveTriangle tri = s.emissive[first + lo];
    float prev = lo > 0 ? s.emissive[first + lo - 1].v0.w : 0.0f;
    float prob = tri.v0.w - prev;
    if (prob <= 0.0f) return float3(0.0f);
    float su = sqrt(saturate((u.x - prev) / prob));   // u.x rescaled within the pick: uniform again
    float b1 = su * (1.0f - u.y), b2 = su * u.y;
    InstanceData inst = s.instances[as_type<uint>(light.params.w)];
    float3 x = (inst.transform * float4(tri.v0.xyz + tri.e1.xyz * b1 + tri.e2.xyz * b2, 1.0f)).xyz;
    float3 cr = cross((inst.transform * float4(tri.e1.xyz, 0.0f)).xyz, (inst.transform * float4(tri.e2.xyz, 0.0f)).xyz);
    float area2 = length(cr);
    float3 w = x - p;
    float d2 = dot(w, w);
    float3 l = w * rsqrt(max(d2, 1e-12f));
    target = p + w * 0.99f;
    float cosP = dot(n, l), cosL = abs(dot(cr, l)) / max(area2, 1e-12f);   // emission is two-sided
    if (cosP <= 0.0f || dot(ng, l) <= 0.0f || area2 <= 0.0f) return float3(0.0f);
    Material m = s.materials[inst.materialIndex];
    float3 Le = m.emission.rgb;
    if (m.textures.w != NO_TEXTURE) {
        float2 uv0 = float2(tri.e1.w, tri.e2.w), d1 = tri.uv12.xy - uv0, d2uv = tri.uv12.zw - uv0;
        float2 uv = uv0 + d1 * b1 + d2uv * b2;
        float uvArea = abs(d1.x * d2uv.y - d1.y * d2uv.x);
        Le *= sampleMaterial(s, m.textures.w, uv, 0.5f * log2(max(uvArea, 1e-12f)) - 2.0f, false).rgb;   // ~4 texels per triangle
    }
    // Point pdf (area) = prob / area; to solid angle: d^2 / cosL.
    return Le * (cosP * cosL / max(d2, 1e-6f) * (0.5f * area2 / prob) / M_PI_F);
}

// One-sample estimate of a light's diffuse lighting at p, shadowed: lightUnshadowed x the visibility of a random
// point of the light (soft shadows); for mesh lights, one sampled triangle point.
float3 sampleLight(Light light, float3 p, float3 n, float3 ng, float2 u, SCENE_ACCEL accel, thread const SceneData& s) {
    if (lightType(light) == LIGHT_MESH) {
        float3 target;
        float3 c = sampleMeshLight(light, p, n, ng, u, s, target);
        if (all(c == 0.0f) || !isVisible(p, target, accel)) return float3(0.0f);
        return c;
    }
    float3 unshadowed = lightUnshadowed(light, p, n, ng);
    if (all(unshadowed == 0.0f)) return float3(0.0f);
    if (!isVisible(p, lightShadowTarget(light, p, u), accel)) return float3(0.0f);
    return unshadowed;
}

// The per-light weight loops (light picking, cached light at secondary hits) look at no more than
// LIGHT_CANDIDATES lights: with more, a stratified random subset, one light per stride of N / M from a random
// offset. Each light is then in the subset with probability M / N, so sums over it are scaled by N / M (`scale`),
// which keeps every estimate unbiased; the cost stops growing with the light count, the noise grows a little.
constant uint LIGHT_CANDIDATES = 32;

struct LightSubset {
    uint  count;    // lights to visit
    float stride;
    float offset;
    float scale;    // N / M (1 when every light is visited)
};

inline LightSubset lightSubset(uint lightCount, float u, uint maxCount = LIGHT_CANDIDATES) {
    LightSubset ls;
    if (lightCount <= maxCount) {
        ls.count = lightCount; ls.stride = 1.0f; ls.offset = 0.0f; ls.scale = 1.0f;
    } else {
        ls.count = maxCount;
        ls.stride = float(lightCount) / float(maxCount);
        ls.offset = min(u, 0.99999f) * ls.stride;
        ls.scale = ls.stride;
    }
    return ls;
}

inline uint lightSubsetIndex(LightSubset ls, uint j, uint lightCount) {
    return min(uint(ls.offset + float(j) * ls.stride), lightCount - 1);
}

// Picks one light with probability proportional to its unshadowed luminance at p (streaming weighted reservoir
// sampling: one pass, one random number, rescaled after each decision), among a subset of the lights if there
// are many (uSubset picks it). Returns lightCount if no light reaches p. pdf = the effective probability of the
// pick (including the subset's), so sample / pdf is unbiased.
uint pickLight(device const Light* lights, uint lightCount, float3 p, float3 n, float3 ng, float u, float uSubset,
               thread float& pdf) {
    float total = 0.0f, pickedWeight = 0.0f;
    uint picked = lightCount;
    u = min(u, 0.99999f);
    LightSubset ls = lightSubset(lightCount, uSubset);
    for (uint j = 0; j < ls.count; ++j) {
        uint i = lightSubsetIndex(ls, j, lightCount);
        float w = luminance(lightUnshadowed(lights[i], p, n, ng));
        if (w <= 0.0f) continue;
        total += w;
        float q = w / total;
        if (u < q) { picked = i; pickedWeight = w; u /= q; }
        else u = (u - q) / (1.0f - q);
    }
    pdf = total > 0.0f ? pickedWeight / (total * ls.scale) : 0.0f;
    return picked;
}

// Half width of a light's penumbra in world units, for an occluder at distance d from the receiver:
// w = r d / (D - d) for a light of radius r at distance D (as in PCSS); the sun: d tan(angular radius).
// 0 = the sample was visible.
inline float penumbraWidth(Light light, float3 p, float d) {
    if (d <= 0.0f) return 0.0f;
    uint type = lightType(light);
    if (type == LIGHT_SUN) return max(d * tan(light.positionRadius.w), 1e-4f);
    float size = light.positionRadius.w;
    if (type == LIGHT_RECT) size = sqrt(length_squared(light.params.xyz) + light.params.w * light.params.w);
    else if (type == LIGHT_TUBE) size += length(light.axis.xyz);
    float D = length(light.positionRadius.xyz - p);
    return max(size * d / max(D - d, 1e-3f), 1e-4f);
}

// Continuous pixel coordinate (no jitter, y down) of camera-relative vector v, for a camera given as
// right/up/forward with tan(fov/2) in .w. Returns the view depth along forward in `depth`.
inline float2 projectToPixel(float3 v, float4 right, float4 up, float4 forward, float2 size, thread float& depth) {
    depth = dot(v, forward.xyz);
    float2 ndc = float2(dot(v, right.xyz) / (depth * right.w), dot(v, up.xyz) / (depth * up.w));
    return float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * size;
}

// ---------------------------------------------------------------------------------------------
// Equal-area octahedral mapping (Clarberg 2008): unit vector <-> [-1, 1]^2, every texel covers the same solid
// angle. Used for the light-visibility maps and the radiance-cascade direction bins.
// ---------------------------------------------------------------------------------------------

inline float3 equalAreaOctDecode(float2 f) {
    float2 a = abs(f);
    float d = 1.0f - (a.x + a.y);                     // > 0 inside the diamond = upper hemisphere
    float r = 1.0f - abs(d);
    float phi = r > 0.0f ? (M_PI_F / 4.0f) * ((a.y - a.x) / r + 1.0f) : 0.0f;
    float z = copysign(1.0f - r * r, d);
    float sinTheta = r * sqrt(max(2.0f - r * r, 0.0f));
    return float3(copysign(cos(phi) * sinTheta, f.x), copysign(sin(phi) * sinTheta, f.y), z);
}

inline float2 equalAreaOctEncode(float3 v) {
    float3 a = abs(v);
    float r = sqrt(max(1.0f - a.z, 0.0f));
    float phi = (a.x > 0.0f || a.y > 0.0f) ? atan2(a.y, a.x) : 0.0f;
    float y = phi * (2.0f / M_PI_F) * r;
    float x = r - y;
    if (v.z < 0.0f) { float t = x; x = 1.0f - y; y = 1.0f - t; }   // fold the lower hemisphere into the corners
    return float2(copysign(x, v.x), copysign(y, v.y));
}

// ---------------------------------------------------------------------------------------------
// Light-visibility maps: for each light, the distance to the nearest geometry in every direction, traced from
// the light's centre once per frame. Secondary hits (path-tracer bounces with FLAG_LIGHT_MAPS, surfels,
// radiance-cascade intervals) look up shadowing here instead of tracing a shadow ray. Shadows are hard (from
// the light's centre), which is invisible once indirect light has been integrated over a hemisphere.
// The sun's map is orthographic instead: the depth along its direction over a square covering the scene's
// bounding sphere (Light.params). Emissive-mesh lights trace theirs from their bounding sphere's surface outward.
// Maps are 128^2 for up to 16 lights and smaller beyond (Renderer.lightMapSize), so tracing them costs the same.
// ---------------------------------------------------------------------------------------------

// Where a light's octahedral map is traced from, and how far out its rays start.
inline float3 lightMapCenter(Light light) {
    if (lightType(light) == LIGHT_RECT) return light.positionRadius.xyz + light.axis.xyz * 0.02f;
    return light.positionRadius.xyz;
}
inline float lightMapStart(Light light) {
    return lightType(light) == LIGHT_RECT ? 0.0f : light.positionRadius.w * 1.01f;   // just outside the light's own sphere
}

kernel void lightMapKernel(constant Uniforms&                     u         [[buffer(0)]],
                           SCENE_ACCEL                            accel     [[buffer(1)]],
                           device const Light*                    lights    [[buffer(8)]],
                           texture2d_array<float, access::write>  lightMap  [[texture(0)]],
                           uint3 tid [[thread_position_in_grid]])
{
    uint size = lightMap.get_width();
    if (tid.x >= size || tid.y >= size || tid.z >= u.lightCount) return;
    Light light = lights[tid.z];
    float2 f = (float2(tid.xy) + 0.5f) / float(size) * 2.0f - 1.0f;
    if (lightType(light) == LIGHT_SUN) {
        float3 w = light.axis.xyz, t, b;
        tangentFrame(w, t, b);
        float R = light.params.w;
        float3 origin = light.params.xyz + w * (R * 1.05f) + (t * f.x + b * f.y) * R;
        float d = intersectDistance(makeRay(origin, -w, 0.0f, INFINITY), MASK_GEOMETRY, accel);
        lightMap.write(float4(isinf(d) ? 1e30f : d), tid.xy, tid.z);
        return;
    }
    float3 dir = equalAreaOctDecode(f);
    float start = lightMapStart(light);
    float t = intersectDistance(makeRay(lightMapCenter(light) + dir * start, dir, 0.0f, INFINITY), MASK_GEOMETRY, accel);
    lightMap.write(float4(isinf(t) ? 1e30f : start + t), tid.xy, tid.z);
}

// 2x2 PCF of "map depth >= depth - bias" around continuous texel coordinate tc.
inline float lightMapPCF(texture2d_array<float, access::read> lightMap, uint l, float2 tc, float depth, float bias) {
    uint size = lightMap.get_width();
    int2 base = int2(floor(tc));
    float2 f = tc - float2(base);
    float vis = 0.0f;
    for (int k = 0; k < 4; ++k) {
        int2 o = int2(k & 1, k >> 1);
        uint2 texel = uint2(clamp(base + o, int2(0), int2(size - 1)));
        float w = (o.x ? f.x : 1.0f - f.x) * (o.y ? f.y : 1.0f - f.y);
        vis += w * (lightMap.read(texel, l).r >= depth - bias ? 1.0f : 0.0f);
    }
    return vis;
}

// Visibility of light l (its map in slice l) from p, with a normal offset along ng against acne.
float lightMapVisibility(Light light, uint l, texture2d_array<float, access::read> lightMap, float3 p, float3 ng) {
    uint size = lightMap.get_width();
    if (lightType(light) == LIGHT_SUN) {
        float3 w = light.axis.xyz, t, b;
        tangentFrame(w, t, b);
        float R = light.params.w, texel = 2.0f * R / float(size);
        float3 q = p + ng * (1.5f * texel) - light.params.xyz;
        float2 tc = (float2(dot(q, t), dot(q, b)) / R * 0.5f + 0.5f) * float(size) - 0.5f;
        float depth = R * 1.05f - dot(q, w);
        return lightMapPCF(lightMap, l, tc, depth, 0.02f + texel);
    }
    // Normal offset of ~1.5 map texels at this distance (a 128^2 equal-area texel spans ~0.028 rad) avoids acne.
    float3 center = lightMapCenter(light);
    float texelScale = 128.0f / float(size);
    float3 q = p + ng * (length(center - p) * 0.04f * texelScale);
    float3 v = q - center;
    float dq = length(v);
    float2 tc = (equalAreaOctEncode(v / dq) * 0.5f + 0.5f) * float(size) - 0.5f;
    return lightMapPCF(lightMap, l, tc, dq, 0.02f + 0.01f * dq * texelScale);
}

// Direct light at a secondary hit from one light, shadowed by its light map (2x2 PCF), albedo divided out.
float3 lightIllumCachedOne(Light light, uint l, texture2d_array<float, access::read> lightMap, float3 p, float3 n, float3 ng) {
    if (lightType(light) == LIGHT_SPHERE) {
        float3 center = light.positionRadius.xyz;
        float radius = light.positionRadius.w;
        float3 toLight = center - p;
        float dist2 = dot(toLight, toLight);
        float3 L = toLight * rsqrt(dist2);
        float cosTheta = dot(n, L);
        if (cosTheta <= 0.0f || dot(ng, L) <= 0.0f) return float3(0.0f);
        return light.color.rgb * (cosTheta * lightMapVisibility(light, l, lightMap, p, ng) / (M_PI_F * max(dist2, radius * radius)));
    }
    float3 unshadowed = lightUnshadowed(light, p, n, ng);
    if (all(unshadowed <= 0.0f)) return float3(0.0f);
    return unshadowed * lightMapVisibility(light, l, lightMap, p, ng);
}

// Direct light at a secondary hit from all lights, shadowed by the light maps, albedo divided out.
// n = shading normal, ng = geometric normal, both oriented toward the side being lit. Up to 8 lights are summed
// exactly; with more, CACHED_LIGHT_SAMPLES lights are picked by unshadowed luminance (one weighted reservoir each,
// seeded by `seed`) and only their maps are read, so the cost no longer grows with the light count's map reads.
float3 lightIllumCached(device const Light* lights, uint lightCount, texture2d_array<float, access::read> lightMap,
                        float3 p, float3 n, float3 ng, uint seed, uint flags) {
    float3 sum = float3(0.0f);
    if (lightCount <= 8 || (flags & FLAG_ALL_LIGHTS) != 0) {
        for (uint l = 0; l < lightCount; ++l) sum += lightIllumCachedOne(lights[l], l, lightMap, p, n, ng);
        return sum;
    }
    float4 u;
    for (uint k = 0; k < 4; ++k) { seed = pcgHash(seed + k); u[k] = min(float(seed >> 8) * (1.0f / 16777216.0f), 0.99999f); }
    LightSubset ls = lightSubset(lightCount, float(pcgHash(seed + 7u) >> 8) * (1.0f / 16777216.0f));
    float total = 0.0f;
    uint picked[CACHED_LIGHT_SAMPLES] = { 0, 0, 0, 0 };
    float4 pickedWeight = float4(0.0f);
    for (uint j = 0; j < ls.count; ++j) {
        uint i = lightSubsetIndex(ls, j, lightCount);
        float w = luminance(lightUnshadowed(lights[i], p, n, ng));
        if (w <= 0.0f) continue;
        total += w;
        float q = w / total;
        for (uint k = 0; k < CACHED_LIGHT_SAMPLES; ++k) {
            if (u[k] < q) { picked[k] = i; pickedWeight[k] = w; u[k] /= q; }
            else u[k] = (u[k] - q) / (1.0f - q);
        }
    }
    if (total <= 0.0f) return sum;
    for (uint k = 0; k < CACHED_LIGHT_SAMPLES; ++k)
        sum += lightIllumCachedOne(lights[picked[k]], picked[k], lightMap, p, n, ng) * (total / pickedWeight[k]);
    return sum * (ls.scale / float(CACHED_LIGHT_SAMPLES));
}

// ---------------------------------------------------------------------------------------------
// 1. Trace kernel: G-buffer + direct light + path traced indirect light (1 sample per pixel)
// ---------------------------------------------------------------------------------------------

// The primary ray's direction through pixel `tid` (jitter is zero unless upscaling is on).
inline float3 primaryDirection(constant Uniforms& u, uint2 tid) {
    float2 uv = (float2(tid) + 0.5f + u.jitter.xy) / float2(u.width, u.height);
    return normalize(u.camForward.xyz
                     + (2.0f * uv.x - 1.0f) * u.camRight.w * u.camRight.xyz
                     + (1.0f - 2.0f * uv.y) * u.camUp.w * u.camUp.xyz);
}

kernel void traceKernel(constant Uniforms&               u          [[buffer(0)]],
                        SCENE_ACCEL                      accel      [[buffer(1)]],
                        device const float3*             positions  [[buffer(2)]],
                        device const float3*             normals    [[buffer(3)]],
                        device const uint*               indices    [[buffer(4)]],
                        device const MeshData*           meshes     [[buffer(5)]],
                        device const InstanceData*       instances  [[buffer(6)]],
                        constant SceneShading&           shading    [[buffer(7)]],
                        device const Light*              lights     [[buffer(8)]],
                        texture2d<float, access::write>  outNormalDepth [[texture(0)]],
                        texture2d<float, access::write>  outAlbedo      [[texture(1)]],
                        texture2d<float, access::write>  outEmission    [[texture(2)]],
                        texture2d<float, access::write>  outMotion      [[texture(3)]],
                        texture2d<float, access::write>  outDirect      [[texture(4)]],
                        texture2d<float, access::write>  outIndirect    [[texture(5)]],
                        texture2d<float, access::write>  outDeviceDepth [[texture(6)]],  // MetalFX: reversed-Z depth
                        texture2d<float, access::write>  outPixelMotion [[texture(7)]],  // MetalFX: prev pixel - this pixel
                        texture2d<float, access::read>   blueNoise      [[texture(8)]],
                        texture2d<float, access::write>  outSurfacePos  [[texture(9)]],   // xyz world, w = instance + 1 (0 = no GI)
                        texture2d<float, access::write>  outGeoNormal   [[texture(10)]],  // oriented geometric normal
                        texture2d_array<float, access::read> lightMap   [[texture(11)]],  // with FLAG_LIGHT_MAPS
                        texture2d<float, access::write>  outVisibility  [[texture(12)]],  // per light group: visibility
                        texture2d<float, access::write>  outBlocker     [[texture(13)]],  // per light group: penumbra half width, 0 = none
                        texture2d<float, access::write>  outMaterial    [[texture(14)]],  // with FLAG_SPECULAR: rgb = F0, a = roughness
                        uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;

    SceneData s;
    s.positions = positions;
    s.normals = normals;
    s.indices = indices;
    s.meshes = meshes;
    s.instances = instances;
    bindShading(s, shading);
    s.lights = lights;
    s.lightCount = u.lightCount;
    bool specular = (u.flags & FLAG_SPECULAR) != 0;

    Sampler rng;
    rng.blueNoise = blueNoise;
    rng.pixel = tid;
    rng.frame = u.frameIndex;
    rng.dimension = 0;
    rng.useBlueNoise = (u.flags & FLAG_BLUE_NOISE) != 0;
    rng.rng.state = pcgHash(tid.x + pcgHash(tid.y + pcgHash(u.frameIndex)));

    // Primary ray (traced instead of rasterized to keep the sample small; a raster G-buffer works the same way).
    float2 size = float2(u.width, u.height);
    float3 dir = primaryDirection(u, tid);
    Ray primary = makeRay(u.camPos.xyz, dir, 0.0f, INFINITY);
    // A rotating eighth of the pixels tells the texture streamer which mip levels they need.
    bool recordTextures = ((tid.x + 3u * tid.y + u.frameIndex) & 7u) == 0u;
    Surface sf = traceSurface(primary, MASK_ALL, accel, s, 2.0f * u.camUp.w / float(u.height), recordTextures);   // pixel angle

    bool upscale = (u.flags & FLAG_UPSCALE) != 0;
    if (!sf.hit) {
        if (upscale) {
            // Sky: a point at infinity only moves with camera rotation.
            float dCur, dPrev;
            float2 cur  = projectToPixel(dir, u.camRight, u.camUp, u.camForward, size, dCur);
            float2 prev = projectToPixel(dir, u.prevCamRight, u.prevCamUp, u.prevCamForward, size, dPrev);
            outDeviceDepth.write(float4(0.0f), tid);
            outPixelMotion.write(float4(dPrev > 0.0f ? prev - cur : float2(0.0f), 0.0f, 0.0f), tid);
        }
        outNormalDepth.write(float4(0.0f, 0.0f, 0.0f, -1.0f), tid);
        outAlbedo.write(float4(0.0f), tid);
        // Sky, plus the discs of the suns (camera rays only: GI rays get the sun from next-event estimation).
        float3 sky = u.skyColor.rgb;
        for (uint i = 0; i < u.lightGroupEnd.w; ++i) {
            Light light = lights[i];
            float theta = light.positionRadius.w;
            if (lightType(light) == LIGHT_SUN && dot(dir, light.axis.xyz) >= cos(theta))
                sky += light.color.rgb / (4.0f * M_PI_F * sin(0.5f * theta) * sin(0.5f * theta));   // irradiance / solid angle
        }
        outEmission.write(float4(sky, 1.0f), tid);
        outMotion.write(float4(0.0f), tid);
        outDirect.write(float4(0.0f), tid);
        outIndirect.write(float4(0.0f), tid);
        outSurfacePos.write(float4(0.0f), tid);
        outGeoNormal.write(float4(0.0f), tid);
        outVisibility.write(float4(0.0f), tid);
        outBlocker.write(float4(0.0f), tid);
        if (specular) outMaterial.write(float4(0.0f), tid);
        return;
    }

    float3 ng, n;
    orientNormals(sf, dir, ng, n);
    if (specular) outMaterial.write(float4(sf.f0, max(sf.roughness, MIN_ROUGHNESS)), tid);
    float viewDepth = dot(sf.position - u.camPos.xyz, u.camForward.xyz);
    outNormalDepth.write(float4(n, viewDepth), tid);
    outGeoNormal.write(float4(ng, 0.0f), tid);
    outAlbedo.write(float4(sf.albedo, 1.0f), tid);
    outEmission.write(float4(sf.emission, 1.0f), tid);

    // Motion vector: project where this surface point was last frame into last frame's camera.
    // The denoiser wants the index of the previous frame's pixel, whose sample was taken at its center + that frame's jitter.
    float prevDepth;
    float2 prevPixel = projectToPixel(sf.prevPosition - u.prevCamPos.xyz, u.prevCamRight, u.prevCamUp, u.prevCamForward, size, prevDepth);
    outMotion.write(float4(prevPixel - 0.5f - u.jitter.zw, prevDepth, prevDepth > 0.0f ? 1.0f : 0.0f), tid);
    if (upscale) {
        // MetalFX wants unjittered motion in pixels, from this pixel to where it was last frame.
        float curDepth;
        float2 curPixel = projectToPixel(sf.position - u.camPos.xyz, u.camRight, u.camUp, u.camForward, size, curDepth);
        outDeviceDepth.write(float4(NEAR_PLANE / max(viewDepth, NEAR_PLANE)), tid);
        outPixelMotion.write(float4(prevDepth > 0.0f ? prevPixel - curPixel : float2(0.0f), 0.0f, 0.0f), tid);
    }

    // Emissive surfaces (the light spheres) are not lit.
    if (any(sf.emission > 0.0f)) {
        outDirect.write(float4(0.0f), tid);
        outIndirect.write(float4(0.0f), tid);
        outSurfacePos.write(float4(sf.position, 0.0f), tid);
        outVisibility.write(float4(0.0f), tid);
        outBlocker.write(float4(0.0f), tid);
        return;
    }
    outSurfacePos.write(float4(sf.position, float(sf.instanceId + 1)), tid);

    float3 p = sf.position + ng * RAY_EPSILON;   // offset along the true normal so the origin is never below the triangle

    // Direct light. The shadow denoiser filters visibility per light group (one rgba channel each; up to 4 lights,
    // each light is its own group) and multiplies it back onto the group's exact unshadowed light in the composite
    // pass. Each channel also gets the penumbra half width of its occluded samples, which sizes the filter.
    float3 direct = float3(0.0f);
    float4 visibility = float4(0.0f), blocker = float4(0.0f);
    // Analytic lights only (the first lightGroupEnd.w): meshLightsKernel samples the emissive-mesh lights.
    uint analyticLights = u.lightGroupEnd.w;
    bool manyLights = analyticLights > SHADOW_GROUPS && (u.flags & FLAG_ALL_LIGHTS) == 0;
    if (!manyLights) {
        // One shadow ray per light. A channel shared by several lights gets their luminance-weighted visibility.
        float4 unshadowedSum = float4(0.0f), blockerWeight = float4(0.0f);
        for (uint i = 0; i < analyticLights; ++i) {
            float2 r = rng.next2();
            float3 unshadowed = lightUnshadowed(lights[i], p, n, ng);
            if (all(unshadowed <= 0.0f)) continue;   // light behind the surface: it shadows itself
            float b;
            float v = isVisibleBlocker(p, lightShadowTarget(lights[i], p, r), accel, b) ? 1.0f : 0.0f;
            direct += unshadowed * v;
            uint g = lightGroup(lights[i]);
            float w = luminance(unshadowed);
            unshadowedSum[g] += w;
            visibility[g] += w * v;
            if (b > 0.0f) { blocker[g] += w * penumbraWidth(lights[i], p, b); blockerWeight[g] += w; }
        }
        visibility = select(float4(0.0f), visibility / unshadowedSum, unshadowedSum > 0.0f);
        blocker = select(float4(0.0f), blocker / blockerWeight, blockerWeight > 0.0f);
    }
    // With more lights, manyLightsKernel computes direct light, visibility and penumbrae after this kernel.
    if (!manyLights) {
        outVisibility.write(visibility, tid);
        outBlocker.write(roundToHalf(blocker), tid);
    }

    // Indirect light: a short diffuse path with next-event estimation at every bounce.
    float3 indirect = float3(0.0f);
    if (u.bounces > 0) {
        float3 throughput = float3(1.0f);
        float3 origin = p;
        float3 normal = n, geomNormal = ng;
        for (uint b = 0; b < u.bounces; ++b) {
            float3 d = cosineSampleHemisphere(normal, rng.next2());
            if (dot(d, geomNormal) <= 0.0f) d -= 2.0f * dot(d, geomNormal) * geomNormal;   // keep it above the triangle
            Ray r = makeRay(origin, d, 0.0f, INFINITY);
            Surface h = traceSurface(r, MASK_GEOMETRY, accel, s, GI_RAY_SPREAD);
            if (!h.hit) {
                indirect += throughput * u.skyColor.rgb;
                break;
            }
            float3 hng, hn;
            orientNormals(h, d, hng, hn);
            indirect += throughput * giEmission(h);
            throughput *= hitAlbedo(h);   // Lambert BRDF * cos / cosine pdf = albedo (+ specular, as diffuse)
            float3 hp = h.position + hng * RAY_EPSILON;
            if ((u.flags & FLAG_LIGHT_MAPS) != 0) {
                uint seed = pcgHash(tid.x + pcgHash(tid.y + pcgHash(u.frameIndex * 8u + b)));
                indirect += throughput * lightIllumCached(lights, u.lightCount, lightMap, hp, hn, hng, seed, u.flags);   // no rays
            } else if (u.lightCount > 0) {
                // Next-event estimation: one light, picked by its unshadowed luminance here.
                float pdf;
                float uPick = rng.next();
                float uSubset = u.lightCount > LIGHT_CANDIDATES ? rng.next() : 0.0f;   // keeps few-light sequences unchanged
                uint li = pickLight(lights, u.lightCount, hp, hn, hng, uPick, uSubset, pdf);
                float2 r = rng.next2();
                if (li < u.lightCount) indirect += throughput * sampleLight(lights[li], hp, hn, hng, r, accel, s) / pdf;
            }
            if (all(throughput < 0.01f)) break;
            origin = hp;
            normal = hn;
            geomNormal = hng;
        }
        float l = luminance(indirect);
        if (l > FIREFLY_CLAMP && (u.flags & FLAG_NO_CLAMP) == 0) indirect *= FIREFLY_CLAMP / l;
    }

    outDirect.write(float4(direct, 1.0f), tid);
    outIndirect.write(float4(indirect, 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 1c. Direct light with many lights (more than SHADOW_GROUPS, unless FLAG_ALL_LIGHTS), after traceKernel, from
//     its G-buffer. Per light group (one shadow-denoiser channel each): one light picked by unshadowed luminance
//     over all the group's lights (weighted reservoir, no rays), and one shadow ray to it, so the cost is 4 rays
//     per pixel whatever the light count. The 0/1 visibility is an unbiased estimate of the group's luminance-
//     weighted visibility, which is what the denoiser filters (the composite multiplies it onto the group's exact
//     unshadowed light); the raw direct light is the one-sample estimate unshadowed * visibility / pdf.
//     raysPerGroup = 2 picks two lights per group (8 rays): half the variance, half the flicker, ~4 ms more here.
//     Every light is weighed (a subset of candidates under-represents each pixel's dominant light, which biased
//     the filtered visibility by 7 dB at 128 lights). Its own kernel because inside traceKernel, whose register
//     use limits occupancy, the same loop cost 4x as much.
// ---------------------------------------------------------------------------------------------

constant uint MAX_RAYS_PER_GROUP = 2;

kernel void manyLightsKernel(constant Uniforms&               u          [[buffer(0)]],
                             SCENE_ACCEL                      accel      [[buffer(1)]],
                             device const Light*              lights     [[buffer(8)]],
                             texture2d<float, access::read>   surfacePos [[texture(0)]],   // w = instance + 1, 0 = unlit
                             texture2d<float, access::read>   normalDepth [[texture(1)]],
                             texture2d<float, access::read>   geoNormal  [[texture(2)]],
                             texture2d<float, access::read>   blueNoise  [[texture(3)]],
                             texture2d<float, access::write>  outDirect  [[texture(4)]],
                             texture2d<float, access::write>  outVisibility [[texture(5)]],
                             texture2d<float, access::write>  outBlocker [[texture(6)]],
                             constant uint&                   raysPerGroup [[buffer(9)]],   // 1 or 2
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    if (sp.w <= 0.0f) return;   // sky and emitters: traceKernel wrote zeros
    float3 n = normalDepth.read(tid).xyz, ng = geoNormal.read(tid).xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;

    Sampler rng;
    rng.blueNoise = blueNoise;
    rng.pixel = tid;
    rng.frame = u.frameIndex;
    rng.dimension = 64;   // other blue-noise windows than traceKernel's
    rng.useBlueNoise = (u.flags & FLAG_BLUE_NOISE) != 0;
    rng.rng.state = pcgHash(tid.x + pcgHash(tid.y + pcgHash(u.frameIndex ^ 0x9E3779B9u)));

    uint rays = clamp(raysPerGroup, 1u, MAX_RAYS_PER_GROUP);
    float4 sel[MAX_RAYS_PER_GROUP];
    for (uint k = 0; k < rays; ++k) sel[k] = float4(rng.next2(), rng.next2());
    float3 direct = float3(0.0f);
    float4 visibility = float4(0.0f), blocker = float4(0.0f), blockerCount = float4(0.0f);
    uint start = 0;
    for (uint g = 0; g < SHADOW_GROUPS; ++g) {
        uint end = u.lightGroupEnd[g];
        float total = 0.0f;
        float s[MAX_RAYS_PER_GROUP], pickedWeight[MAX_RAYS_PER_GROUP];
        uint picked[MAX_RAYS_PER_GROUP];
        for (uint k = 0; k < rays; ++k) { s[k] = min(sel[k][g], 0.99999f); picked[k] = end; pickedWeight[k] = 0.0f; }
        for (uint i = start; i < end; ++i) {
            float w = luminance(lightUnshadowed(lights[i], p, n, ng));
            if (w <= 0.0f) continue;
            total += w;
            float q = w / total;
            for (uint k = 0; k < rays; ++k) {
                if (s[k] < q) { picked[k] = i; pickedWeight[k] = w; s[k] /= q; }
                else s[k] = (s[k] - q) / (1.0f - q);
            }
        }
        for (uint k = 0; k < rays; ++k) {
            float2 r = rng.next2();   // drawn even for empty groups, so the sample dimensions stay fixed
            if (picked[k] >= end) continue;
            Light light = lights[picked[k]];
            float b;
            bool visible = isVisibleBlocker(p, lightShadowTarget(light, p, r), accel, b);
            visibility[g] += visible ? 1.0f / float(rays) : 0.0f;
            if (b > 0.0f) { blocker[g] += penumbraWidth(light, p, b); blockerCount[g] += 1.0f; }
            if (visible) direct += lightUnshadowed(light, p, n, ng) * (total / (pickedWeight[k] * float(rays)));
        }
        start = end;
    }
    blocker = select(float4(0.0f), blocker / blockerCount, blockerCount > 0.0f);
    outDirect.write(float4(direct, 1.0f), tid);
    outVisibility.write(visibility, tid);
    outBlocker.write(roundToHalf(blocker), tid);
}

// 1d. The same with light reuse (RenderSettings.manyLightReuse, ReSTIR-style temporal resampling): each group keeps
//     last frame's pick in a reservoir (light, confidence M, contribution weight W), reprojected with the motion
//     vectors. This frame's exact pick and the reservoir's light (re-weighed here, where the lights are now) are
//     resampled in proportion to their weights, and the winner gets the shadow ray. Every pick already follows the
//     unshadowed light exactly, so reuse can't sharpen the distribution; what it does is keep a pixel's pick from
//     changing every frame, so a still image flickers less: a third less at 4 frames, for about 0.7 dB of accuracy on
//     still frames (stress scene). Its own kernel because merged into manyLightsKernel the extra state cost 0.75 ms
//     with reuse off. Visibility reuse (storing occluded picks with W = 0, so reservoirs drift toward visible lights)
//     cut flicker as much but darkened penumbrae and lagged: -3 dB still, -5 dB moving.
// ---------------------------------------------------------------------------------------------

kernel void manyLightsReuseKernel(constant Uniforms&               u          [[buffer(0)]],
                             SCENE_ACCEL                      accel      [[buffer(1)]],
                             device const Light*              lights     [[buffer(8)]],
                             texture2d<float, access::read>   surfacePos [[texture(0)]],   // w = instance + 1, 0 = unlit
                             texture2d<float, access::read>   normalDepth [[texture(1)]],
                             texture2d<float, access::read>   geoNormal  [[texture(2)]],
                             texture2d<float, access::read>   blueNoise  [[texture(3)]],
                             texture2d<float, access::write>  outDirect  [[texture(4)]],
                             texture2d<float, access::write>  outVisibility [[texture(5)]],
                             texture2d<float, access::write>  outBlocker [[texture(6)]],
                             texture2d<float, access::read>   motion     [[texture(7)]],
                             texture2d<float, access::read>   prevND     [[texture(8)]],
                             texture2d<uint, access::read>    prevReservoir [[texture(9)]],
                             texture2d<float, access::read>   prevReservoirW [[texture(10)]],
                             texture2d<uint, access::write>   outReservoir [[texture(11)]],
                             texture2d<float, access::write>  outReservoirW [[texture(12)]],
                             constant uint4&                  config     [[buffer(9)]],   // y = reuse frames, z = 1 if last frame stored picks
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    uint maxM = max(config.y, 1u);
    if (sp.w <= 0.0f) {   // sky and emitters: traceKernel wrote zeros
        outReservoir.write(uint4(0xFFFFu), tid);
        return;
    }
    float4 nd = normalDepth.read(tid);
    float3 n = nd.xyz, ng = geoNormal.read(tid).xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;

    Sampler rng;
    rng.blueNoise = blueNoise;
    rng.pixel = tid;
    rng.frame = u.frameIndex;
    rng.dimension = 64;   // other blue-noise windows than traceKernel's
    rng.useBlueNoise = (u.flags & FLAG_BLUE_NOISE) != 0;
    rng.rng.state = pcgHash(tid.x + pcgHash(tid.y + pcgHash(u.frameIndex ^ 0x9E3779B9u)));

    float3 direct = float3(0.0f);
    float4 visibility = float4(0.0f), blocker = float4(0.0f);

    uint4 prevPick = uint4(0xFFFFu);
    float4 prevW = float4(0.0f);
    float4 mv = motion.read(tid);
    if (config.z != 0 && mv.w > 0.0f) {
        int2 q = int2(floor(mv.xy + 0.5f));
        if (q.x >= 0 && q.y >= 0 && q.x < int(u.width) && q.y < int(u.height)) {
            float4 pnd = prevND.read(uint2(q));
            if (pnd.w > 0.0f && abs(pnd.w - mv.z) < 0.1f * mv.z && dot(pnd.xyz, n) > 0.9f) {
                prevPick = prevReservoir.read(uint2(q));
                prevW = prevReservoirW.read(uint2(q));
            }
        }
    }
    float4 sel = float4(rng.next2(), rng.next2());
    float4 reuseSel = float4(rng.next2(), rng.next2());
    uint4 outPick = uint4(0xFFFFu);
    float4 outW = float4(0.0f);
    uint start = 0;
    for (uint g = 0; g < SHADOW_GROUPS; ++g) {
        uint end = u.lightGroupEnd[g];
        float2 r = rng.next2();
        // This frame's candidate: exact pick over the group's lights (pdf = weight / total, so W = total / weight).
        float total = 0.0f, pickedWeight = 0.0f, s = min(sel[g], 0.99999f);
        uint picked = end;
        for (uint i = start; i < end; ++i) {
            float w = luminance(lightUnshadowed(lights[i], p, n, ng));
            if (w <= 0.0f) continue;
            total += w;
            float q = w / total;
            if (s < q) { picked = i; pickedWeight = w; s /= q; }
            else s = (s - q) / (1.0f - q);
        }
        float weightSum = picked < end ? total : 0.0f;   // M = 1 * target(pick) * W
        float M = 1.0f;
        uint y = picked;
        float targetY = pickedWeight;
        // Last frame's pick, re-weighed at this pixel with the lights where they are now.
        uint prevLight = prevPick[g] & 0xFFFFu;
        if (prevLight >= start && prevLight < end) {
            float Mp = min(float(prevPick[g] >> 16), float(maxM));
            float targetP = luminance(lightUnshadowed(lights[prevLight], p, n, ng));
            float wp = Mp * targetP * prevW[g];
            M += Mp;
            if (wp > 0.0f) {
                weightSum += wp;
                if (reuseSel[g] * weightSum < wp) { y = prevLight; targetY = targetP; }
            }
        }
        start = end;
        if (y >= end || targetY <= 0.0f || weightSum <= 0.0f) {
            outPick[g] = y < end ? (y | (uint(min(M, 65535.0f)) << 16)) : 0xFFFFu;
            continue;
        }
        float W = weightSum / (M * targetY);
        Light light = lights[y];
        float b;
        bool visible = isVisibleBlocker(p, lightShadowTarget(light, p, r), accel, b);
        // Estimate of the group's luminance-weighted visibility: target * V * W / total (= V for a fresh pick).
        visibility[g] = visible && total > 0.0f ? saturate(targetY * W / total) : 0.0f;
        blocker[g] = penumbraWidth(light, p, b);
        if (visible) direct += lightUnshadowed(light, p, n, ng) * W;
        outPick[g] = y | (uint(min(M, float(maxM))) << 16);
        outW[g] = W;
    }
    outReservoir.write(outPick, tid);
    outReservoirW.write(outW, tid);

    outDirect.write(float4(direct, 1.0f), tid);
    outVisibility.write(visibility, tid);
    outBlocker.write(roundToHalf(blocker), tid);
}

// ---------------------------------------------------------------------------------------------
// 1e. Emissive-mesh lights (the lights after lightGroupEnd.w), after the analytic direct light: one light picked by
//     its proxy's unshadowed luminance, one point on one of its triangles picked by emitted power, one shadow ray.
//     The estimate is unbiased but noisy, so it doesn't go through the shadow denoiser (whose exact unshadowed
//     light a mesh doesn't have): with it, SVGF denoises outMeshDirect on its own and the composite adds it; without
//     it (addToDirect = 1), the estimate is added to the direct light, which SVGF or accumulation then handle.
// ---------------------------------------------------------------------------------------------

kernel void meshLightsKernel(constant Uniforms&                    u          [[buffer(0)]],
                             SCENE_ACCEL                           accel      [[buffer(1)]],
                             device const InstanceData*            instances  [[buffer(6)]],
                             constant SceneShading&                shading    [[buffer(7)]],
                             device const Light*                   lights     [[buffer(8)]],
                             constant uint&                        addToDirect [[buffer(9)]],
                             texture2d<float, access::read>        surfacePos [[texture(0)]],   // w = instance + 1, 0 = unlit
                             texture2d<float, access::read>        normalDepth [[texture(1)]],
                             texture2d<float, access::read>        geoNormal  [[texture(2)]],
                             texture2d<float, access::read>        blueNoise  [[texture(3)]],
                             texture2d<float, access::read_write>  direct     [[texture(4)]],
                             texture2d<float, access::write>       outMeshDirect [[texture(5)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    uint first = u.lightGroupEnd.w, count = u.lightCount - first;
    if (sp.w <= 0.0f || count == 0) { outMeshDirect.write(float4(0.0f), tid); return; }   // sky and emitters
    float3 n = normalDepth.read(tid).xyz, ng = geoNormal.read(tid).xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;

    SceneData s;
    s.instances = instances; bindShading(s, shading); s.lights = lights; s.lightCount = u.lightCount;
    Sampler rng;
    rng.blueNoise = blueNoise;
    rng.pixel = tid;
    rng.frame = u.frameIndex;
    rng.dimension = 96;   // other blue-noise windows than the trace and many-lights kernels'
    rng.useBlueNoise = (u.flags & FLAG_BLUE_NOISE) != 0;
    rng.rng.state = pcgHash(tid.x * 31u + pcgHash(tid.y + pcgHash(u.frameIndex ^ 0x5bd1e995u)));

    // One light by its proxy's luminance (weighted reservoir over all of them: there are few).
    float total = 0.0f, pickedWeight = 0.0f, uPick = min(rng.next(), 0.99999f);
    uint picked = count;
    for (uint i = 0; i < count; ++i) {
        float w = luminance(meshLightUnshadowed(lights[first + i], p, n, ng));
        if (w <= 0.0f) continue;
        total += w;
        float q = w / total;
        if (uPick < q) { picked = i; pickedWeight = w; uPick /= q; }
        else uPick = (uPick - q) / (1.0f - q);
    }
    float2 r = rng.next2();
    float3 result = float3(0.0f);
    if (picked < count) {
        float3 target;
        result = sampleMeshLight(lights[first + picked], p, n, ng, r, s, target) * (total / pickedWeight);
        if (any(result > 0.0f) && !isVisible(p, target, accel)) result = float3(0.0f);
    }
    float l = luminance(result);
    if (l > 4.0f * FIREFLY_CLAMP && (u.flags & FLAG_NO_CLAMP) == 0) result *= 4.0f * FIREFLY_CLAMP / l;
    outMeshDirect.write(roundToHalf(float4(result, 1.0f)), tid);
    if (addToDirect != 0) direct.write(direct.read(tid) + float4(result, 0.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 2d. Reflections (specular materials only): one GGX visible-normal ray per pixel for the indirect specular light,
//     divided by the specular albedo so the denoiser filters a smooth signal (the composite multiplies it back).
//     Hits are lit by one light sample (one shadow ray) plus this frame's diffuse GI where the hit is on screen
//     (a dim sky ambient elsewhere); references (FLAG_REFERENCE) follow full paths instead. Without the shadow
//     denoiser, which otherwise adds direct specular analytically, one sampled light's direct specular is added.
//     Rougher than REFLECTION_MAX_ROUGHNESS: no ray, the composite uses the diffuse GI.
// ---------------------------------------------------------------------------------------------

// Light arriving along a reflection ray that hit `h`: emission, one light sample and the diffuse GI (see above).
float3 reflectionHitRadiance(constant Uniforms& u, SCENE_ACCEL accel, thread const SceneData& s, Surface h, float3 dir,
                             thread Sampler& rng, texture2d<float, access::read> normalDepth,
                             texture2d<float, access::read> indirect) {
    if (!h.hit) return u.skyColor.rgb;
    float3 L = float3(0.0f), throughput = float3(1.0f);
    bool reference = (u.flags & FLAG_REFERENCE) != 0;
    uint bounces = reference ? u.bounces : 0;
    for (uint b = 0; ; ++b) {
        float3 hng, hn;
        orientNormals(h, dir, hng, hn);
        float3 hp = h.position + hng * RAY_EPSILON;
        float3 albedo = hitAlbedo(h);
        L += throughput * (b == 0 ? h.emission : giEmission(h));   // the reflection ray itself sees emitters
        if (u.lightCount > 0) {
            float pdf;
            float uPick = rng.next();
            float uSubset = u.lightCount > LIGHT_CANDIDATES ? rng.next() : 0.0f;
            uint li = pickLight(s.lights, u.lightCount, hp, hn, hng, uPick, uSubset, pdf);
            float2 r = rng.next2();
            if (li < u.lightCount) L += throughput * albedo * sampleLight(s.lights[li], hp, hn, hng, r, accel, s) / pdf;
        }
        if (!reference) {
            // Diffuse GI at the hit: this frame's indirect light where the hit point is visible on screen.
            float depth;
            float2 px = projectToPixel(h.position - u.camPos.xyz, u.camRight, u.camUp, u.camForward, float2(u.width, u.height), depth);
            float3 gi = u.skyColor.rgb * 0.3f;
            if (depth > 0.0f && all(px >= 0.0f) && px.x < float(u.width) && px.y < float(u.height)) {
                uint2 q = uint2(px);
                float4 nd = normalDepth.read(q);
                if (nd.w > 0.0f && abs(nd.w - depth) < 0.03f * depth && dot(nd.xyz, hn) > 0.7f) gi = indirect.read(q).rgb;
            }
            return L + throughput * albedo * gi;
        }
        if (b >= bounces) return L;
        float3 d = cosineSampleHemisphere(hn, rng.next2());
        if (dot(d, hng) <= 0.0f) d -= 2.0f * dot(d, hng) * hng;
        throughput *= albedo;
        h = traceSurface(makeRay(hp, d, 0.0f, INFINITY), MASK_GEOMETRY, accel, s, GI_RAY_SPREAD);
        dir = d;
        if (!h.hit) return L + throughput * u.skyColor.rgb;
    }
}

kernel void reflectionKernel(constant Uniforms&               u          [[buffer(0)]],
                             SCENE_ACCEL                      accel      [[buffer(1)]],
                             device const float3*             positions  [[buffer(2)]],
                             device const float3*             normals    [[buffer(3)]],
                             device const uint*               indices    [[buffer(4)]],
                             device const MeshData*           meshes     [[buffer(5)]],
                             device const InstanceData*       instances  [[buffer(6)]],
                             constant SceneShading&           shading    [[buffer(7)]],
                             device const Light*              lights     [[buffer(8)]],
                             texture2d<float, access::read>   surfacePos [[texture(0)]],
                             texture2d<float, access::read>   normalDepth [[texture(1)]],
                             texture2d<float, access::read>   geoNormal  [[texture(2)]],
                             texture2d<float, access::read>   material   [[texture(3)]],
                             texture2d<float, access::read>   blueNoise  [[texture(4)]],
                             texture2d<float, access::read>   indirect   [[texture(5)]],   // this frame's diffuse GI
                             texture2d<float, access::write>  outSpecular [[texture(6)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid), m = material.read(tid);
    if (sp.w <= 0.0f || all(m.rgb <= 0.0f)) { outSpecular.write(float4(0.0f), tid); return; }

    SceneData s;
    s.positions = positions; s.normals = normals; s.indices = indices; s.meshes = meshes;
    s.instances = instances; bindShading(s, shading); s.lights = lights; s.lightCount = u.lightCount;
    Sampler rng;
    rng.blueNoise = blueNoise;
    rng.pixel = tid;
    rng.frame = u.frameIndex;
    rng.dimension = 40;   // past the trace kernel's dimensions
    rng.useBlueNoise = (u.flags & FLAG_BLUE_NOISE) != 0;
    rng.rng.state = pcgHash(tid.x * 7919u + pcgHash(tid.y + pcgHash(u.frameIndex * 31u + 17u)));

    float3 n = normalDepth.read(tid).xyz, ng = geoNormal.read(tid).xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;
    float3 v = normalize(u.camPos.xyz - sp.xyz);
    float3 f0 = m.rgb;
    float roughness = m.a, a = roughness * roughness;
    float NoV = max(dot(n, v), 1e-4f);
    float3 albedo = specularAlbedo(f0, 1.0f, roughness, NoV);
    float3 result = float3(0.0f);

    uint analyticLights = u.lightGroupEnd.w;   // mesh lights: the reflection ray sees them
    if ((u.flags & FLAG_SHADOW_DENOISER) == 0 && analyticLights > 0) {
        // Direct specular from one light (picked by its diffuse light here): spheres and spots exactly, a uniform
        // point on the sphere; other lights their analytic specular x the visibility of a random point of them.
        float pdf;
        float uPick = rng.next();
        float uSubset = analyticLights > LIGHT_CANDIDATES ? rng.next() : 0.0f;
        uint li = pickLight(lights, analyticLights, p, n, ng, uPick, uSubset, pdf);
        float2 r = rng.next2();
        if (li < analyticLights) {
            Light light = lights[li];
            uint type = lightType(light);
            float3 x = lightShadowTarget(light, p, r);
            if (type == LIGHT_SPHERE || type == LIGHT_SPOT) {
                float3 toX = x - p;
                float d2 = dot(toX, toX);
                float3 l = toX * rsqrt(d2);
                float cosX = dot(normalize(x - light.positionRadius.xyz), -l);
                float NoL = dot(n, l);
                if (cosX > 0.0f && NoL > 0.0f && dot(ng, l) > 0.0f && isVisible(p, x, accel)) {
                    float rad = light.positionRadius.w;
                    float3 Le = light.color.rgb / (M_PI_F * rad * rad);
                    if (type == LIGHT_SPOT) Le *= spotFactor(light, -l);
                    float3 h = normalize(l + v);
                    float3 F = schlick(f0, 1.0f, dot(v, h));
                    float brdf = ggxD(saturate(dot(n, h)), max(a, 1e-4f)) * smithVisibility(NoV, NoL, max(a, 1e-4f));
                    result += F * brdf * Le * (NoL * cosX * 4.0f * M_PI_F * rad * rad / d2) / pdf;
                }
            } else if (isVisible(p, x, accel)) {
                result += lightSpecular(light, p, n, ng, v, f0, roughness) / pdf;
            }
        }
    }

    if (roughness < REFLECTION_MAX_ROUGHNESS || (u.flags & FLAG_REFERENCE) != 0) {
        float3 t, b;
        tangentFrame(n, t, b);
        float3 hl = sampleGGXVNDF(float3(dot(v, t), dot(v, b), NoV), a, rng.next2());
        float3 h = t * hl.x + b * hl.y + n * hl.z;
        float3 l = reflect(-v, h);
        float NoL = dot(n, l);
        if (NoL > 0.0f && dot(l, ng) > 0.0f) {
            // VNDF sampling: f cos / pdf = F G2 / G1(v).
            float a2 = a * a;
            float g1 = 2.0f * NoV / (NoV + sqrt(a2 + (1.0f - a2) * NoV * NoV));
            float g2 = smithVisibility(NoV, NoL, a) * 4.0f * NoL * NoV;
            float3 weight = schlick(f0, 1.0f, dot(v, h)) * (g2 / max(g1, 1e-6f));
            float spread = mix(2.0f * u.camUp.w / float(u.height), GI_RAY_SPREAD * 4.0f, roughness);
            // No texture feedback from reflections: their footprint ignores curvature, so self-reflections at close
            // range would ask for the finest mips.
            Surface hit = traceSurface(makeRay(p, l, 0.0f, INFINITY), MASK_GEOMETRY, accel, s, spread);
            result += weight * reflectionHitRadiance(u, accel, s, hit, l, rng, normalDepth, indirect);
        }
    }
    result /= max(albedo, float3(1e-3f));
    float lum = luminance(result);
    if (lum > FIREFLY_CLAMP && (u.flags & FLAG_NO_CLAMP) == 0) result *= FIREFLY_CLAMP / lum;
    outSpecular.write(roundToHalf(float4(result, 1.0f)), tid);
}

// ---------------------------------------------------------------------------------------------
// 2. Temporal accumulation: reproject last frame's denoised result, reject disocclusions,
//    blend with the new noisy sample and track luminance moments for variance estimation.
// ---------------------------------------------------------------------------------------------

inline float3 readNoisy(texture2d<float, access::read> a, texture2d<float, access::read> b, uint count, uint2 p) {
    return a.read(p).rgb + (count > 1 ? b.read(p).rgb : float3(0.0f));
}

// Denoises one signal: inputA alone (inputCount = 1) or inputA + inputB (inputCount = 2).
kernel void temporalKernel(constant Uniforms&              u           [[buffer(0)]],
                           constant uint&                  inputCount  [[buffer(1)]],
                           texture2d<float, access::read>  inputA      [[texture(0)]],
                           texture2d<float, access::read>  inputB      [[texture(1)]],
                           texture2d<float, access::read>  motion      [[texture(2)]],
                           texture2d<float, access::read>  curND       [[texture(3)]],
                           texture2d<float, access::read>  prevND      [[texture(4)]],
                           texture2d<float, access::read>  history     [[texture(5)]],
                           texture2d<float, access::read>  prevMoments [[texture(6)]],
                           texture2d<float, access::write> outIllum    [[texture(7)]],
                           texture2d<float, access::write> outMoments  [[texture(8)]],
                           uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;

    float4 nd = curND.read(tid);
    float3 current = readNoisy(inputA, inputB, inputCount, tid);
    if (nd.w <= 0.0f) {
        outIllum.write(float4(current, 0.0f), tid);
        outMoments.write(float4(0.0f), tid);
        return;
    }
    float lum = luminance(current);

    // Bilinear reprojection where each of the 4 taps is validated by depth and normal.
    float3 histColor = float3(0.0f);
    float2 histMoments = float2(0.0f);
    float histSlowLum = 0.0f;
    float histLen = 0.0f;
    float weightSum = 0.0f;
    float4 mv = motion.read(tid);
    if ((u.flags & FLAG_HISTORY_VALID) != 0 && mv.w > 0.0f) {
        float2 pp = mv.xy;
        int2 base = int2(floor(pp));
        float2 f = pp - float2(base);
        float bilinear[4] = { (1 - f.x) * (1 - f.y), f.x * (1 - f.y), (1 - f.x) * f.y, f.x * f.y };
        int2 offsets[4] = { int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1) };
        for (int i = 0; i < 4; ++i) {
            int2 q = base + offsets[i];
            if (q.x < 0 || q.y < 0 || q.x >= int(u.width) || q.y >= int(u.height)) continue;
            float4 pnd = prevND.read(uint2(q));
            if (pnd.w <= 0.0f) continue;
            if (abs(pnd.w - mv.z) > 0.1f * mv.z) continue;        // depth mismatch -> disoccluded
            if (dot(pnd.xyz, nd.xyz) < 0.9f) continue;             // normal mismatch
            float w = bilinear[i];
            float4 m = prevMoments.read(uint2(q));
            histColor += history.read(uint2(q)).rgb * w;
            histMoments += m.xy * w;
            histSlowLum += m.w * w;
            histLen += m.z * w;
            weightSum += w;
        }
    }

    float len;
    float3 color;
    float2 moments;
    float slowLum;
    if (weightSum > 1e-3f) {
        histColor /= weightSum;
        histMoments /= weightSum;
        histSlowLum /= weightSum;
        histLen /= weightSum;

        // Anti-lag: moments.x is a fast (~5 frame) running mean of the raw luminance, moments.w a slow one that
        // follows the color history's blend rate. Where they differ by more than 2 standard errors, the lighting
        // has changed (a moving light or shadow), so shorten the history and let new samples take over sooner.
        if (u.denoise.z > 0.0f) {
            float sigma = sqrt(max(histMoments.y - histMoments.x * histMoments.x, 0.0f));
            float stdError = 0.36f * sigma + 1e-3f * histMoments.x + 1e-5f;   // of (fast - slow), alpha 0.2 vs ~1/32
            float excess = max(abs(histSlowLum - histMoments.x) / stdError - 2.0f, 0.0f);
            histLen /= 1.0f + u.denoise.z * excess;
        }
        len = min(histLen + 1.0f, u.denoise.y);
        float alpha = 1.0f / len;
        float alphaMoments = max(alpha, 0.2f);
        color = mix(histColor, current, alpha);
        moments = mix(histMoments, float2(lum, lum * lum), alphaMoments);
        slowLum = mix(histSlowLum, lum, alpha);
    } else {
        len = 1.0f;
        color = current;
        moments = float2(lum, lum * lum);
        slowLum = lum;
    }

    float variance;
    if (len < 4.0f) {
        // Too little history: estimate variance spatially from a 5x5 neighborhood on the same surface.
        float2 m = float2(0.0f);
        float ws = 0.0f;
        for (int dy = -2; dy <= 2; ++dy) {
            for (int dx = -2; dx <= 2; ++dx) {
                int2 q = int2(tid) + int2(dx, dy);
                if (q.x < 0 || q.y < 0 || q.x >= int(u.width) || q.y >= int(u.height)) continue;
                float4 qnd = curND.read(uint2(q));
                if (qnd.w <= 0.0f || dot(qnd.xyz, nd.xyz) < 0.8f) continue;
                float ql = luminance(readNoisy(inputA, inputB, inputCount, uint2(q)));
                m += float2(ql, ql * ql);
                ws += 1.0f;
            }
        }
        m /= max(ws, 1.0f);
        variance = max(0.0f, m.y - m.x * m.x) * (4.0f / len);
    } else {
        variance = max(0.0f, moments.y - moments.x * moments.x);
    }

    // Alpha holds the standard deviation: the variance overflows the half-float texture near the lights.
    outIllum.write(roundToHalf(float4(color, sqrt(variance))), tid);
    outMoments.write(float4(moments, len, slowLum), tid);
}

// ---------------------------------------------------------------------------------------------
// 3. A-trous wavelet filter: 5x5 B-spline kernel with growing step size,
//    weighted by depth, normal and luminance (scaled by the estimated variance).
//    Illumination alpha is the standard deviation; variance math is done in 32-bit registers.
// ---------------------------------------------------------------------------------------------

constant float kernelWeights[3] = { 3.0f / 8.0f, 1.0f / 4.0f, 1.0f / 16.0f };

kernel void atrousKernel(constant Uniforms&              u        [[buffer(0)]],
                         constant int&                   stepSize [[buffer(1)]],
                         texture2d<float, access::read>  inIllum  [[texture(0)]],
                         texture2d<float, access::read>  nd       [[texture(1)]],
                         texture2d<float, access::write> outIllum [[texture(2)]],
                         uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    int2 p = int2(tid);
    int2 maxP = int2(u.width - 1, u.height - 1);

    float4 center = inIllum.read(tid);
    float4 cnd = nd.read(tid);
    if (cnd.w <= 0.0f) {
        outIllum.write(center, tid);
        return;
    }

    // Blur the variance a little (3x3 Gaussian) so the luminance edge-stopping is stable.
    float variance = 0.0f;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float k = (dx == 0 ? 2.0f : 1.0f) * (dy == 0 ? 2.0f : 1.0f) / 16.0f;
            float sd = inIllum.read(uint2(clamp(p + int2(dx, dy), int2(0), maxP))).a;
            variance += k * sd * sd;
        }
    }

    // Screen-space depth gradient, used to make the depth test tolerant on slanted surfaces.
    float zr = nd.read(uint2(clamp(p + int2(1, 0), int2(0), maxP))).w;
    float zd = nd.read(uint2(clamp(p + int2(0, 1), int2(0), maxP))).w;
    float2 depthGrad = float2(zr > 0.0f ? zr - cnd.w : 0.0f, zd > 0.0f ? zd - cnd.w : 0.0f);

    float centerLum = luminance(center.rgb);
    float phiL = u.denoise.x * sqrt(max(variance, 0.0f)) + 1e-4f;

    float3 sumColor = float3(0.0f);
    float sumWeight = 0.0f;
    float sumVariance = 0.0f;
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            int2 q = p + int2(dx, dy) * stepSize;
            if (q.x < 0 || q.y < 0 || q.x > maxP.x || q.y > maxP.y) continue;
            float4 qc = inIllum.read(uint2(q));
            float4 qnd = nd.read(uint2(q));
            if (qnd.w <= 0.0f) continue;

            float2 offset = float2(dx, dy) * float(stepSize);
            float wDepth = exp(-abs(cnd.w - qnd.w) / (abs(dot(depthGrad, offset)) + 0.01f * cnd.w + 1e-4f));
            float wNormal = pow(max(0.0f, dot(cnd.xyz, qnd.xyz)), 128.0f);
            float wLum = exp(-abs(centerLum - luminance(qc.rgb)) / phiL);
            float w = kernelWeights[abs(dx)] * kernelWeights[abs(dy)] * wDepth * wNormal * wLum;

            sumColor += qc.rgb * w;
            sumVariance += w * w * qc.a * qc.a;
            sumWeight += w;
        }
    }
    sumWeight = max(sumWeight, 1e-6f);
    outIllum.write(roundToHalf(float4(sumColor / sumWeight, sqrt(sumVariance) / sumWeight)), tid);
}

// ---------------------------------------------------------------------------------------------
// 3b. Shadow denoiser (direct light). traceKernel's direct light is, per light, an exact unshadowed term times
//     the visibility of one random point on the light (0 or 1). Only that visibility is noisy, so only it is
//     filtered, one light per rgba channel, and compositeKernel multiplies it back onto the exact term: shading
//     falloff and normal detail are never blurred. Visibility is in [0, 1], so its variance is p(1 - p).
//     Lights and objects move every frame and motion vectors don't move shadows, so the temporal pass clamps the
//     reprojected history to what this frame's neighbourhood allows (as in TAA). The spatial passes blur no wider
//     than each light's penumbra, estimated from occluder distances (as in PCSS), and skip 8x8 tiles that are
//     fully lit or fully shadowed for every light. (After AMD FidelityFX's shadow denoiser and NVIDIA's SIGMA.)
// ---------------------------------------------------------------------------------------------

// params: x = max history frames, y = clamp width (standard deviations), z = edge-stopping width, w = step size
kernel void shadowTemporalKernel(constant Uniforms&              u          [[buffer(0)]],
                                 constant float4&                params     [[buffer(1)]],
                                 texture2d<float, access::read>  visibility [[texture(0)]],
                                 texture2d<float, access::read>  blocker    [[texture(1)]],
                                 texture2d<float, access::read>  motion     [[texture(2)]],
                                 texture2d<float, access::read>  curND      [[texture(3)]],
                                 texture2d<float, access::read>  prevND     [[texture(4)]],
                                 texture2d<float, access::read>  history    [[texture(5)]],   // last frame's filtered visibility
                                 texture2d<float, access::read>  prevMeta   [[texture(6)]],   // z = history length
                                 texture2d<float, access::write> outVis     [[texture(7)]],
                                 texture2d<float, access::write> outMeta    [[texture(8)]],
                                 texture2d<float, access::write> outPenumbra [[texture(9)]],  // per light group: radius in pixels
                                 texture2d<uint, access::write>  outTiles   [[texture(10)]],  // per 8x8 tile: 1 = nothing to filter
                                 uint2 tid   [[thread_position_in_grid]],
                                 uint2 group [[threadgroup_position_in_grid]],
                                 uint  lane  [[thread_index_in_threadgroup]],
                                 uint  simdGroup [[simdgroup_index_in_threadgroup]],
                                 uint  simdGroups [[simdgroups_per_threadgroup]])
{
    // The 8x8 tile plus a 2-pixel apron, loaded once: each pixel's 5x5 neighbourhood statistics read it 25 times.
    threadgroup half4 tileVis[144], tileBlocker[144], tileND[144];
    threadgroup bool groupSettled[32];
    int2 maxP = int2(u.width - 1, u.height - 1);
    int2 origin = int2(group * 8) - 2;
    for (uint i = lane; i < 144; i += 64) {
        uint2 q = uint2(clamp(origin + int2(i % 12, i / 12), int2(0), maxP));
        tileVis[i] = half4(visibility.read(q));
        tileBlocker[i] = half4(blocker.read(q));
        tileND[i] = half4(curND.read(q));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    bool settled = true;   // fully lit or fully shadowed here and in the 5x5 neighbourhood, for every light
    if (tid.x < u.width && tid.y < u.height) {
        int2 local = int2(tid) - origin;
        float4 nd = float4(tileND[local.y * 12 + local.x]);
        if (nd.w <= 0.0f) {
            outVis.write(float4(0.0f), tid);
            outMeta.write(float4(0.0f), tid);
            outPenumbra.write(float4(0.0f), tid);
        } else {
            float4 v = float4(tileVis[local.y * 12 + local.x]);
            // 5x5 neighbourhood on the same surface: mean visibility and mean penumbra width, per light group.
            float4 sum = float4(0.0f), blockerSum = float4(0.0f), blockerCount = float4(0.0f);
            float count = 0.0f;
            for (int dy = -2; dy <= 2; ++dy) {
                for (int dx = -2; dx <= 2; ++dx) {
                    uint i = uint((local.y + dy) * 12 + local.x + dx);
                    float4 qnd = float4(tileND[i]);
                    if (qnd.w <= 0.0f || dot(qnd.xyz, nd.xyz) < 0.8f || abs(qnd.w - nd.w) > 0.05f * nd.w) continue;
                    sum += float4(tileVis[i]);
                    float4 b = float4(tileBlocker[i]);
                    blockerSum += b;
                    blockerCount += select(float4(0.0f), float4(1.0f), b > 0.0f);
                    count += 1.0f;
                }
            }
            float4 mean = sum / max(count, 1.0f);
            float4 sigma = sqrt(max(mean * (1.0f - mean), 0.0f));

            // Validated bilinear reprojection, as in temporalKernel.
            float4 hist = float4(0.0f);
            float histLen = 0.0f, weightSum = 0.0f;
            float4 mv = motion.read(tid);
            if ((u.flags & FLAG_HISTORY_VALID) != 0 && mv.w > 0.0f) {
                int2 base = int2(floor(mv.xy));
                float2 f = mv.xy - float2(base);
                float bilinear[4] = { (1 - f.x) * (1 - f.y), f.x * (1 - f.y), (1 - f.x) * f.y, f.x * f.y };
                int2 offsets[4] = { int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1) };
                for (int i = 0; i < 4; ++i) {
                    int2 q = base + offsets[i];
                    if (q.x < 0 || q.y < 0 || q.x >= int(u.width) || q.y >= int(u.height)) continue;
                    float4 pnd = prevND.read(uint2(q));
                    if (pnd.w <= 0.0f || abs(pnd.w - mv.z) > 0.1f * mv.z || dot(pnd.xyz, nd.xyz) < 0.9f) continue;
                    hist += history.read(uint2(q)) * bilinear[i];
                    histLen += prevMeta.read(uint2(q)).z * bilinear[i];
                    weightSum += bilinear[i];
                }
            }
            float4 result;
            float len;
            if (weightSum > 1e-3f) {
                hist /= weightSum;
                histLen /= weightSum;
                // Clamp the history to this frame's neighbourhood: a shadow that moved away (or arrived) can't
                // linger. Where the clamp had to move it a lot, the history is stale: restart the average.
                float4 clamped = clamp(hist, mean - params.y * sigma, mean + params.y * sigma);
                float moved = max(max(abs(clamped.x - hist.x), abs(clamped.y - hist.y)), max(abs(clamped.z - hist.z), abs(clamped.w - hist.w)));
                if (moved > 0.25f) histLen = min(histLen, 2.0f);
                len = min(histLen + 1.0f, params.x);
                result = mix(clamped, v, 1.0f / len);
            } else {
                len = 1.0f;
                result = mean;   // no history: the spatial mean beats one binary sample
            }

            // Mean penumbra half width of the occluded samples (traceKernel: penumbraWidth), in pixels: divided by
            // the pixel footprint at this depth.
            float pixel = 2.0f * nd.w * u.camUp.w / float(u.height);
            float4 radius = select(float4(0.0f), blockerSum / max(blockerCount, 1.0f) / pixel, blockerCount > 0.0f);
            settled = all(sigma == 0.0f) && all(abs(result - v) < 0.004f);
            outVis.write(roundToHalf(result), tid);
            outMeta.write(float4(0.0f, 0.0f, len, 0.0f), tid);
            outPenumbra.write(roundToHalf(min(radius, float4(64.0f))), tid);
        }
    }
    // Tile classification: the spatial passes skip tiles where every pixel is settled.
    bool simdSettled = simd_all(settled);
    if (simd_is_first()) groupSettled[simdGroup] = simdSettled;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane == 0) {
        bool tile = true;
        for (uint i = 0; i < simdGroups; ++i) tile = tile && groupSettled[i];
        outTiles.write(uint4(tile ? 1u : 0u), group);
    }
}

// One edge-aware 3x3 a-trous pass over the denoised visibility (all lights at once).
kernel void shadowFilterKernel(constant Uniforms&              u        [[buffer(0)]],
                               constant float4&                params   [[buffer(1)]],
                               texture2d<float, access::read>  inVis    [[texture(0)]],
                               texture2d<float, access::read>  nd       [[texture(1)]],
                               texture2d<float, access::read>  penumbra [[texture(2)]],
                               texture2d<float, access::read>  meta     [[texture(3)]],
                               texture2d<uint, access::read>   tiles    [[texture(4)]],
                               texture2d<float, access::write> outVis   [[texture(5)]],
                               uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 center = inVis.read(tid);
    float4 cnd = nd.read(tid);
    if (cnd.w <= 0.0f || tiles.read(tid / 8).x != 0) {
        outVis.write(center, tid);
        return;
    }
    int step = int(params.w);
    int2 p = int2(tid);
    int2 maxP = int2(u.width - 1, u.height - 1);
    float zr = nd.read(uint2(clamp(p + int2(1, 0), int2(0), maxP))).w;
    float zd = nd.read(uint2(clamp(p + int2(0, 1), int2(0), maxP))).w;
    float2 depthGrad = float2(zr > 0.0f ? zr - cnd.w : 0.0f, zd > 0.0f ? zd - cnd.w : 0.0f);

    // Visibility edge-stopping, scaled by the standard error of the temporal average, and a per-light reach
    // factor: taps beyond the light's penumbra (step > radius) don't contribute.
    float len = max(meta.read(tid).z, 1.0f);
    float4 phi = params.z * sqrt(max(center * (1.0f - center), 0.0f) / len) + 0.02f;
    float4 reach = saturate(penumbra.read(tid) / float(step));
    float4 sum = float4(0.0f), weightSum = float4(0.0f);
    const float k[2] = { 0.5f, 0.25f };
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 q = p + int2(dx, dy) * step;
            if (q.x < 0 || q.y < 0 || q.x > maxP.x || q.y > maxP.y) continue;
            float4 qnd = nd.read(uint2(q));
            if (qnd.w <= 0.0f) continue;
            float4 qv = inVis.read(uint2(q));
            float2 offset = float2(dx, dy) * float(step);
            float wDepth = exp(-abs(cnd.w - qnd.w) / (abs(dot(depthGrad, offset)) + 0.01f * cnd.w + 1e-4f));
            float wNormal = pow(max(0.0f, dot(cnd.xyz, qnd.xyz)), 64.0f);
            float4 w = k[abs(dx)] * k[abs(dy)] * wDepth * wNormal * exp(-abs(qv - center) / phi);
            if (dx != 0 || dy != 0) w *= reach;
            sum += qv * w;
            weightSum += w;
        }
    }
    outVis.write(roundToHalf(sum / max(weightSum, 1e-6f)), tid);
}

// ---------------------------------------------------------------------------------------------
// 3c. Geometry debug views (view modes 8-13), a pass of their own that runs only while one is shown: re-traces the
//     primary rays and colours each pixel by what it hit. Virtual triangles carry their cluster, group, DAG level and
//     index within the cluster (VirtualBLAS packs them into the free w components of e1 / e2; in cluster mode the
//     cluster's pool header holds group and level, VirtualGeometry.upload).
// ---------------------------------------------------------------------------------------------

constant uint VIEW_TRIANGLES = 8, VIEW_CLUSTERS = 9, VIEW_GROUPS = 10, VIEW_LOD = 11, VIEW_TRIANGLE_SIZE = 12, VIEW_COST = 13;

inline float3 debugHashColor(uint h) {
    h = pcgHash(h);
    return 0.15f + 0.85f * float3(h & 0xFFu, (h >> 8) & 0xFFu, (h >> 16) & 0xFFu) / 255.0f;
}

// Turbo colour map (polynomial fit, Mikhailov 2019): 0 = dark blue, 0.5 = green, 1 = dark red.
inline float3 debugHeat(float x) {
    x = saturate(x);
    const float4 r4 = float4(0.13572138f, 4.61539260f, -42.66032258f, 132.13108234f);
    const float4 g4 = float4(0.09140261f, 2.19418839f, 4.84296658f, -14.18503333f);
    const float4 b4 = float4(0.10667330f, 12.64194608f, -60.58204836f, 110.36276771f);
    const float2 r2 = float2(-152.94239396f, 59.28637943f);
    const float2 g2 = float2(4.27729857f, 2.82956604f);
    const float2 b2 = float2(-89.90310912f, 27.34824973f);
    float4 v4 = float4(1.0f, x, x * x, x * x * x);
    float2 v2 = v4.zw * v4.z;
    return saturate(float3(dot(v4, r4) + dot(v2, r2), dot(v4, g4) + dot(v2, g2), dot(v4, b4) + dot(v2, b2)));
}

kernel void geometryDebugKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      accel      [[buffer(1)]],
                                device const float3*             positions  [[buffer(2)]],
                                device const float3*             normals    [[buffer(3)]],
                                device const uint*               indices    [[buffer(4)]],
                                device const MeshData*           meshes     [[buffer(5)]],
                                device const InstanceData*       instances  [[buffer(6)]],
                                constant SceneShading&           shading    [[buffer(7)]],
                                texture2d<float, access::write>  output     [[texture(0)]],
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    SceneData s;
    s.positions = positions;
    s.normals = normals;
    s.indices = indices;
    s.meshes = meshes;
    s.instances = instances;
    bindShading(s, shading);

    float3 dir = primaryDirection(u, tid);
    Ray r = makeRay(u.camPos.xyz, dir, 0.0f, INFINITY);
#if CUSTOM_RT
    uint cost[7] = {0, 0, 0, 0, 0, 0, 0};
    Hit res = intersectClosestCost(r, MASK_ALL, accel, cost);
    // Work of the ray: node visits (both levels) plus triangle tests at half weight, log scale up to ~500.
    float work = float(cost[1] + cost[2]) + 0.5f * float(cost[5]);
    float3 costColor = debugHeat(log2(1.0f + work) / 9.0f);
#else
    Hit res = intersectClosest(r, MASK_ALL, accel);
    float3 costColor = float3(1.0f, 0.0f, 1.0f);   // Metal's traversal can't be counted
#endif
    if (u.viewMode == VIEW_COST) { output.write(float4(costColor, 1.0f), tid); return; }
    if (!res.hit) { output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid); return; }

    InstanceData inst = s.instances[res.instance];
    HitVertices hv = fetchHitVertices(res, inst, accel, s);
    float3 e1 = (inst.transform * float4(hv.p[1] - hv.p[0], 0.0f)).xyz, e2 = (inst.transform * float4(hv.p[2] - hv.p[0], 0.0f)).xyz;
    float3 ng = cross(e1, e2);
    float doubleArea = length(ng);
    float shade = doubleArea > 0.0f ? 0.35f + 0.65f * abs(dot(ng / doubleArea, dir)) : 0.35f;

    bool isVirtual = false;
    uint cluster = 0, local = 0, group = 0, level = 0;
#if CUSTOM_RT
    if (res.cluster != HIT_NO_CLUSTER) {
        uint2 rc = accel.clusters[res.cluster];
        uint packed = ((device const uint*)(accel.pool + rc.y))[3];   // group | level << 24
        isVirtual = true;
        cluster = rc.y;                 // its place in the pool: stable while it stays resident
        local = res.primitive;
        group = packed & 0xFFFFFFu;
        level = packed >> 24;
    } else if (inst.pad1 != 0) {
        VGBlas e = accel.vgBlas[inst.pad1 - 1];
        uint a = as_type<uint>(e.tris[3 * res.primitive + 1].w), b = as_type<uint>(e.tris[3 * res.primitive + 2].w);
        isVirtual = true;
        cluster = a & 0xFFFFFFu;        // cluster | triangle within it << 24
        local = a >> 24;
        group = b & 0xFFFFFFu;          // group | level << 24
        level = b >> 24;
    }
#endif
    uint instanceSeed = pcgHash(res.instance + 0x51ED27u);
    float3 c = float3(0.45f);           // geometry that isn't virtual, in the views that are about virtual geometry
    switch (u.viewMode) {
        case VIEW_TRIANGLES:
            c = debugHashColor(isVirtual ? local + pcgHash(cluster + instanceSeed) : res.primitive + instanceSeed);
            break;
        case VIEW_CLUSTERS: if (isVirtual) c = debugHashColor(cluster + instanceSeed); break;
        case VIEW_GROUPS:   if (isVirtual) c = debugHashColor(group * 0x9E3779B9u + instanceSeed); break;
        case VIEW_LOD:      if (isVirtual) c = debugHeat(0.05f + float(level) / 10.0f); break;   // 0 = finest
        case VIEW_TRIANGLE_SIZE: {
            // Edge length (of a right triangle with the same area) in traced pixels: 1/8 px blue, 1 px green, 8 px red.
            float footprint = res.distance * 2.0f * u.camUp.w / float(u.height);
            float px = sqrt(doubleArea) / max(footprint, 1e-8f);
            c = debugHeat((log2(max(px, 1e-4f)) + 3.0f) / 6.0f);
            break;
        }
        default: break;
    }
    output.write(float4(c * shade, 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 4. Composite: re-apply albedo, add emission, tonemap and write to the drawable.
// ---------------------------------------------------------------------------------------------

inline float3 acesFilm(float3 x) {
    // Narkowicz 2015 ACES approximation
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}

kernel void compositeKernel(constant Uniforms&              u          [[buffer(0)]],
                            texture2d<float, access::read>  denoised   [[texture(0)]],
                            texture2d<float, access::read>  direct     [[texture(1)]],
                            texture2d<float, access::read>  indirect   [[texture(2)]],
                            texture2d<float, access::read>  albedoTex  [[texture(3)]],
                            texture2d<float, access::read>  emissionTex [[texture(4)]],
                            texture2d<float, access::read>  nd         [[texture(5)]],
                            texture2d<float, access::read>  moments    [[texture(6)]],
                            texture2d<float, access::write> output     [[texture(7)]],
                            texture2d<float, access::read>  denoisedIndirect [[texture(8)]],  // with FLAG_SEPARATE
                            texture2d<float, access::read>  giDebug    [[texture(9)]],   // written by surfel / cascade GI
                            texture2d<float, access::read>  surfacePos [[texture(10)]],  // with FLAG_SHADOW_DENOISER
                            texture2d<float, access::read>  geoNormal  [[texture(11)]],  // with FLAG_SHADOW_DENOISER
                            texture2d<float, access::read>  material   [[texture(12)]],  // with FLAG_SPECULAR: F0, roughness
                            texture2d<float, access::read>  specularTex [[texture(13)]], // with FLAG_SPECULAR: specular light / specular albedo
                            texture2d<float, access::read>  geometryDebug [[texture(14)]], // view modes 8-13 (geometryDebugKernel)
                            texture2d<float, access::read>  meshDirect [[texture(15)]],   // with FLAG_MESH_LIGHTS: denoised mesh-light direct light
                            device const Light*             lights     [[buffer(1)]],    // with FLAG_SHADOW_DENOISER
                            uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    if (tid.x >= u.width || tid.y >= u.height) {
        output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid);
        return;
    }

    float3 albedo = albedoTex.read(tid).rgb;
    float3 emission = emissionTex.read(tid).rgb;
    float3 d = direct.read(tid).rgb;
    float3 i = indirect.read(tid).rgb;
    float3 illumination = d + i;
    float3 finalIndirect = i;   // what view mode 6 shows: denoised when indirect light is denoised on its own
    float3 directSpecular = float3(0.0f);
    if ((u.flags & FLAG_SHADOW_DENOISER) != 0) {
        // `denoised` holds each light group's filtered visibility: multiply it onto the group's exact unshadowed light.
        float4 vis = denoised.read(tid);
        float4 sp = surfacePos.read(tid);
        float3 n = nd.read(tid).xyz, ng = geoNormal.read(tid).xyz;
        float3 p = sp.xyz + ng * RAY_EPSILON;
        illumination = float3(0.0f);
        for (uint l = 0; l < u.lightGroupEnd.w; ++l) illumination += lightUnshadowed(lights[l], p, n, ng) * vis[lightGroup(lights[l])];
        if ((u.flags & FLAG_MESH_LIGHTS) != 0) illumination += meshDirect.read(tid).rgb;   // denoised on its own
        if ((u.flags & FLAG_SPECULAR) != 0) {
            // Direct specular the same way: exact unshadowed GGX light x the group's denoised visibility.
            float4 m = material.read(tid);
            if (any(m.rgb > 0.0f)) {
                float3 v = normalize(u.camPos.xyz - sp.xyz);
                for (uint l = 0; l < u.lightGroupEnd.w; ++l)
                    directSpecular += lightSpecular(lights[l], p, n, ng, v, m.rgb, m.a) * vis[lightGroup(lights[l])];
            }
        }
        if ((u.flags & FLAG_SEPARATE) != 0) {
            finalIndirect = denoisedIndirect.read(tid).rgb;
            illumination += finalIndirect;
        }
    } else if ((u.flags & FLAG_DENOISE) != 0) {
        illumination = denoised.read(tid).rgb;
        if ((u.flags & FLAG_SEPARATE) != 0) {
            finalIndirect = denoisedIndirect.read(tid).rgb;
            illumination += finalIndirect;
        }
    }

    // Indirect specular: the reflection pass's result (or, on rough surfaces, the diffuse GI) x specular albedo.
    float3 specular = directSpecular;
    if ((u.flags & FLAG_SPECULAR) != 0) {
        float4 m = material.read(tid);
        float4 ndc = nd.read(tid);
        if (any(m.rgb > 0.0f) && ndc.w > 0.0f) {
            float3 v = normalize(u.camPos.xyz - surfacePos.read(tid).xyz);
            float3 sa = specularAlbedo(m.rgb, 1.0f, m.a, max(dot(ndc.xyz, v), 1e-4f));
            float3 traced = specularTex.read(tid).rgb;
            bool tracedAll = m.a < REFLECTION_MAX_ROUGHNESS || (u.flags & FLAG_REFERENCE) != 0;
            specular += sa * (tracedAll ? traced : traced + finalIndirect);
        }
    }

    float3 c;
    bool hdr = true;
    switch (u.viewMode) {
        case 1: c = albedo * d + emission; break;                 // raw direct
        case 2: c = albedo * i; break;                            // raw indirect
        case 3: { float4 n = nd.read(tid); c = n.w > 0.0f ? n.xyz * 0.5f + 0.5f : float3(0.0f); hdr = false; break; }
        case 4: c = albedo; hdr = false; break;
        case 5: { float h = moments.read(tid).z / u.denoise.y; c = float3(1.0f - h, h, 0.0f); hdr = false; break; }
        case 6: c = albedo * finalIndirect; break;                // indirect light only, as it reaches the image
        case 7: c = giDebug.read(tid).rgb; hdr = false; break;    // GI technique's debug view
        case 8: case 9: case 10: case 11: case 12: case 13: c = geometryDebug.read(tid).rgb; hdr = false; break;
        default: c = albedo * illumination + specular + emission; break;
    }
    if (hdr) c = acesFilm(c);
    // Linear either way: MetalFX's input is linear, and the drawable is an sRGB format (the GPU encodes on write).
    output.write(float4(saturate(c), 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 5. Accumulate (benchmark reference only): running mean of the raw illumination over many frames
//    of a paused scene, used in place of the denoiser to make a converged ground-truth image.
// ---------------------------------------------------------------------------------------------

kernel void accumulateKernel(constant Uniforms&                   u              [[buffer(0)]],
                             constant uint&                       sampleCount    [[buffer(1)]],
                             texture2d<float, access::read>       direct         [[texture(0)]],
                             texture2d<float, access::read>       indirect       [[texture(1)]],
                             texture2d<float, access::read_write> accumDirect    [[texture(2)]],
                             texture2d<float, access::read_write> accumIndirect  [[texture(3)]],
                             texture2d<float, access::read>       spec           [[texture(4)]],   // with FLAG_SPECULAR
                             texture2d<float, access::read_write> accumSpec      [[texture(5)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    // Running means, kept apart so the "Indirect only" view has a converged reference too.
    float w = 1.0f / float(sampleCount + 1);
    float3 d = direct.read(tid).rgb, i = indirect.read(tid).rgb;
    float3 meanD = sampleCount > 0 ? accumDirect.read(tid).rgb : float3(0.0f);
    float3 meanI = sampleCount > 0 ? accumIndirect.read(tid).rgb : float3(0.0f);
    accumDirect.write(float4(meanD + (d - meanD) * w, 1.0f), tid);
    accumIndirect.write(float4(meanI + (i - meanI) * w, 1.0f), tid);
    if ((u.flags & FLAG_SPECULAR) != 0) {
        float3 sp = spec.read(tid).rgb, meanS = sampleCount > 0 ? accumSpec.read(tid).rgb : float3(0.0f);
        accumSpec.write(float4(meanS + (sp - meanS) * w, 1.0f), tid);
    }
}

// ---------------------------------------------------------------------------------------------
// 6. Custom temporal upscaler (TAAU, the alternative to MetalFX): one pass per output pixel.
//    Each frame's input samples sit at jittered positions (pixel centre + jitter). An output pixel takes the
//    samples within about one *output* pixel of its centre (Gaussian weights; most frames that's none or one),
//    so over the jitter cycle it collects its own sharp samples, and blends them into its history weighted by how
//    close they landed. The history is reprojected with the closest-depth motion vector of the 3x3 input
//    neighbourhood (sharp moving edges), sampled with Catmull-Rom (little blur when it moves) and clipped to
//    the neighbourhood's YCoCg colour box (no ghosting). With no usable history it starts from a smooth
//    spatial upsample. Input and history are tonemapped, linear; output goes straight to the sRGB drawable.
// ---------------------------------------------------------------------------------------------

inline float3 rgbToYCoCg(float3 c) {
    return float3(dot(c, float3(0.25f, 0.5f, 0.25f)), dot(c, float3(0.5f, 0.0f, -0.5f)), dot(c, float3(-0.25f, 0.5f, -0.25f)));
}
inline float3 yCoCgToRgb(float3 c) { return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z); }

// Moves h toward the box centre until it's inside the box (rather than clamping each axis). `outside` returns
// how far out it was: 1 = on the box's surface.
inline float3 clipToBox(float3 h, float3 boxMin, float3 boxMax, thread float& outside) {
    float3 center = 0.5f * (boxMax + boxMin), extent = 0.5f * (boxMax - boxMin) + 1e-4f;
    float3 v = h - center;
    float3 a = abs(v / extent);
    outside = max(a.x, max(a.y, a.z));
    return outside > 1.0f ? center + v / outside : h;
}

// Lanczos-2 without trigonometry (the polynomial approximation FSR 2 uses), for x^2 < 4.
inline float lanczos2(float x) {
    float x2 = min(x * x, 4.0f);
    float a = 0.4f * x2 - 1.0f, b = 0.25f * x2 - 1.0f;
    return (1.5625f * a * a - 0.5625f) * b * b;
}

inline float lanczos3(float x) {
    x = abs(x);
    if (x < 1e-4f) return 1.0f;
    if (x >= 3.0f) return 0.0f;
    return 3.0f * sinpi(x) * sinpi(x / 3.0f) / (M_PI_F * M_PI_F * x * x);
}

// Lanczos-3 filtered sample (6x6 texels). Resampling a moving history every frame blurs it a little each time;
// Lanczos-3's flatter passband blurs it far less than Catmull-Rom (a 1D simulation of this upscaler: under half
// the edge error at 1-4 pixels of motion per frame).
inline float4 sampleLanczos3(texture2d<float, access::sample> tex, float2 uv, float2 size) {
    float2 pos = uv * size - 0.5f;
    int2 base = int2(floor(pos));
    float2 f = pos - float2(base);
    float wx[6], wy[6], sx = 0.0f, sy = 0.0f;
    for (int i = 0; i < 6; ++i) {
        wx[i] = lanczos3(f.x - float(i - 2)); sx += wx[i];
        wy[i] = lanczos3(f.y - float(i - 2)); sy += wy[i];
    }
    int2 maxP = int2(size) - 1;
    float4 sum = float4(0.0f);
    for (int j = 0; j < 6; ++j) {
        float4 row = float4(0.0f);
        for (int i = 0; i < 6; ++i) row += tex.read(uint2(clamp(base + int2(i - 2, j - 2), int2(0), maxP))) * wx[i];
        sum += row * wy[j];
    }
    return sum / (sx * sy);
}

// Catmull-Rom filtered sample from 5 bilinear taps (the 4 corner taps carry almost no weight).
inline float4 sampleCatmullRom(texture2d<float, access::sample> tex, float2 uv, float2 size) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 pos = uv * size;
    float2 p1 = floor(pos - 0.5f) + 0.5f;
    float2 f = pos - p1;
    float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
    float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
    float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
    float2 w3 = f * f * (-0.5f + 0.5f * f);
    float2 w12 = w1 + w2;
    float2 t0 = (p1 - 1.0f) / size, t3 = (p1 + 2.0f) / size, t12 = (p1 + w2 / w12) / size;
    float4 r = tex.sample(s, float2(t12.x, t0.y)) * (w12.x * w0.y) + tex.sample(s, float2(t0.x, t12.y)) * (w0.x * w12.y)
             + tex.sample(s, t12) * (w12.x * w12.y)
             + tex.sample(s, float2(t3.x, t12.y)) * (w3.x * w12.y) + tex.sample(s, float2(t12.x, t3.y)) * (w12.x * w3.y);
    return r / (w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y);
}

// params[0].xy = this frame's jitter (input pixels), z = history cut per output pixel of motion,
//   w = history cut where the clip moved it; [1] = input size xy, output size zw;
// [2] = max history weight, clip box width (standard deviations), 1 = reset, Lanczos-3 detail threshold (0 = off);
// [3] = sample kernel sharpness with a full history (Gaussian exp(-x d^2), d in output pixels), the same with none,
//   history cut per output pixel of motion at depth edges, dilation radius (input pixels, 0 = the whole 3x3)
kernel void taauKernel(constant float4*                   params     [[buffer(0)]],
                       texture2d<float, access::read>     color      [[texture(0)]],   // tonemapped, linear
                       texture2d<float, access::read>     depth      [[texture(1)]],   // reversed-Z: larger = closer
                       texture2d<float, access::read>     motion     [[texture(2)]],   // previous - current, input pixels
                       texture2d<float, access::sample>   history    [[texture(3)]],   // rgb, a = accumulated weight
                       texture2d<float, access::write>    outHistory [[texture(4)]],
                       texture2d<float, access::write>    output     [[texture(5)]],   // the drawable
                       uint2 tid [[thread_position_in_grid]])
{
    float2 jitter = params[0].xy, inSize = params[1].xy, outSize = params[1].zw;
    if (tid.x >= uint(outSize.x) || tid.y >= uint(outSize.y)) return;
    float2 toOut = outSize / inSize;
    float2 inPos = (float2(tid) + 0.5f) / toOut;   // this output pixel's centre, in input pixels
    int2 nearest = int2(floor(inPos - jitter));    // input sample q sits at q + 0.5 + jitter
    int2 maxQ = int2(inSize) - 1;

    // The 3x3 input samples around the pixel: colour, offset from the pixel centre, depth.
    float3 colors[9];
    float2 offsets[9];   // input pixels
    float depths[9];
    float zLo = 1e9f, zHi = -1.0f;
    for (int k = 0; k < 9; ++k) {
        int2 q = clamp(nearest + int2(k % 3 - 1, k / 3 - 1), int2(0), maxQ);
        colors[k] = color.read(uint2(q)).rgb;
        offsets[k] = float2(q) + 0.5f + jitter - inPos;
        depths[k] = depth.read(uint2(q)).x;
        zLo = min(zLo, depths[k]); zHi = max(zHi, depths[k]);
    }
    bool depthEdge = zHi - zLo > 0.05f * zHi;

    // Motion at this pixel: bilinear from the 4 surrounding samples (camera motion varies across the screen).
    float2 g = inPos - 0.5f - jitter;
    int2 b = int2(floor(g));   // nearest - 1 or nearest per axis: the 2x2 lies inside the 3x3 above
    float2 f = g - float2(b);
    float2 mv = float2(0.0f);
    for (int k = 0; k < 4; ++k) {
        uint2 q = uint2(clamp(b + int2(k & 1, k >> 1), int2(0), maxQ));
        mv += motion.read(q).xy * ((k & 1 ? f.x : 1.0f - f.x) * (k >> 1 ? f.y : 1.0f - f.y));
    }
    // Across a depth edge, the closest surface's motion instead (dilation, so moving edges stay sharp), among the
    // samples within params[3].w input pixels. Dilating further drags the foreground's motion into the background,
    // which then fetches stale history from where the edge used to be: a trail behind edges in camera pans.
    if (depthEdge) {
        float radius2 = params[3].w > 0.0f ? params[3].w * params[3].w : 1e9f;
        float best = -1.0f, nearestD2 = 1e9f;
        uint2 q = uint2(nearest), nearestQ = q;
        for (int k = 0; k < 9; ++k) {
            float d2 = dot(offsets[k], offsets[k]);
            uint2 qk = uint2(clamp(nearest + int2(k % 3 - 1, k / 3 - 1), int2(0), maxQ));
            if (d2 < nearestD2) { nearestD2 = d2; nearestQ = qk; }
            if (d2 <= radius2 && depths[k] > best) { best = depths[k]; q = qk; }
        }
        mv = motion.read(best < 0.0f ? nearestQ : q).xy;
    }
    float speed = length(mv * toOut);   // output pixels per frame

    // Spatial estimate (Lanczos-2, de-ringed to the neighbourhood's range) where there's no usable history, and
    // the YCoCg colour box the history is clipped to, weighted toward the nearest samples.
    float3 sumSharp = float3(0.0f), sumWide = float3(0.0f), m1 = float3(0.0f), m2 = float3(0.0f);
    float3 lo = float3(1e9f), hi = float3(-1e9f);
    float weightSharp = 0.0f, weightWide = 0.0f;
    for (int k = 0; k < 9; ++k) {
        float2 d = offsets[k];
        float3 c = colors[k];
        float wWide = exp(-2.0f * dot(d, d));
        float wSharp = lanczos2(d.x) * lanczos2(d.y);
        sumSharp += c * wSharp; weightSharp += wSharp;
        sumWide += c * wWide; weightWide += wWide;
        lo = min(lo, c); hi = max(hi, c);
        float3 y = rgbToYCoCg(c);
        m1 += y * wWide; m2 += y * y * wWide;
    }
    float3 spatial = weightSharp > 1e-3f ? clamp(sumSharp / weightSharp, lo, hi) : sumWide / max(weightWide, 1e-6f);
    float3 mean = m1 / max(weightWide, 1e-6f), sigma = sqrt(max(m2 / max(weightWide, 1e-6f) - mean * mean, 0.0f));

    float2 prevUV = (inPos + mv) / inSize;
    float maxWeight = params[2].x;
    float4 result;
    if (params[2].z > 0.0f || any(prevUV < 0.0f) || any(prevUV > 1.0f)) {
        result = float4(spatial, 1.0f);
    } else {
        // History: a pixel that didn't move reads its own texel. A moving one is resampled, which blurs it a little
        // every frame: Lanczos-3 (36 taps) blurs far less than Catmull-Rom (5 taps), so it's used wherever there's
        // detail to lose (the input neighbourhood varies more than params[2].w); flat areas lose nothing.
        bool detail = params[2].w > 0.0f && max(sigma.x, max(abs(sigma.y), abs(sigma.z))) > params[2].w;
        float4 hist = all(abs(mv) < 1e-4f) ? history.read(tid)
                    : detail ? sampleLanczos3(history, prevUV, outSize) : sampleCatmullRom(history, prevUV, outSize);
        float outside;
        float3 h = yCoCgToRgb(clipToBox(rgbToYCoCg(max(hist.rgb, 0.0f)), mean - params[2].y * sigma, mean + params[2].y * sigma, outside));
        // Trust the history less where it moves and where the clip had to move it. Near a depth edge, camera
        // translation uncovers and covers background (parallax) that the colour box can't tell from history: cut
        // the history much harder there (params[3].z) than on open surfaces (params[0].z).
        float cap = maxWeight / (1.0f + (depthEdge ? max(params[3].z, params[0].z) : params[0].z) * speed);
        float histWeight = clamp(hist.a, 0.0f, cap) / (1.0f + params[0].w * max(outside - 1.0f, 0.0f));

        // This frame's samples within about an output pixel. The kernel is sharpest where the history is long
        // (static: many frames to collect sharp samples from) and widest where it was cut (fewer, wider samples).
        float sharpness = mix(params[3].y, params[3].x, saturate(histWeight / maxWeight));
        float3 sum = float3(0.0f);
        float weight = 0.0f;
        for (int k = 0; k < 9; ++k) {
            float2 dOut = offsets[k] * toOut;
            float w = exp(-sharpness * dot(dOut, dOut));
            sum += colors[k] * w;
            weight += w;
        }
        float3 current = weight > 1e-4f ? sum / weight : spatial;
        result = histWeight + weight > 1e-3f
            ? float4((h * histWeight + current * weight) / (histWeight + weight), min(histWeight + weight, maxWeight))
            : float4(spatial, 1.0f);
    }
    outHistory.write(result, tid);
    output.write(float4(saturate(result.rgb), 1.0f), tid);
}

// Benchmark references only: running mean of the composited (tonemapped) colour over jittered frames, i.e. a
// supersampled, anti-aliased image. params.x = frames averaged so far, y = 0 while not averaging yet.
kernel void accumulateColorKernel(constant uint2&                      params [[buffer(0)]],
                                  texture2d<float, access::read>       color  [[texture(0)]],
                                  texture2d<float, access::read_write> accum  [[texture(1)]],
                                  texture2d<float, access::write>      output [[texture(2)]],
                                  uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    float3 c = color.read(tid).rgb;
    if (params.y != 0) {
        float3 m = params.x > 0 ? accum.read(tid).rgb : float3(0.0f);
        c = m + (c - m) / float(params.x + 1);
        accum.write(float4(c, 1.0f), tid);
    }
    output.write(float4(c, 1.0f), tid);
}

// =============================================================================================
// Radiance cascades (GI mode "Radiance cascades")
//
// Probes sit on visible surfaces on a screen grid. Cascade c has probes every spacing * 2^c pixels and
// (4 * 2^c)^2 equal-area octahedral direction bins per probe; it traces rays over the distance interval
// [b_c, b_c+1) with b_0 = 0, b_1 = firstInterval and each later boundary 4x further (the last interval is
// open, so it picks up the sky). Cascades are traced from the top down: each ray's radiance is
// L + visibility * (the cascade above, interpolated from its 4 nearest probes and averaged over the 4 child
// bins that subdivide this bin). Cascade 0 then holds each probe's full incoming radiance, and the resolve
// pass integrates it against each pixel's normal. No temporal accumulation is needed: rays and bins are fixed,
// so the result is noise-free and doesn't lag behind moving lights.
//
// Ray hits are lit by the light-visibility maps (no shadow rays) plus, where the hit point was visible last
// frame, last frame's indirect light (multi-bounce, one bounce per frame).
// =============================================================================================

struct RCParams {
    uint4  grids;      // xy = this cascade's probe grid, zw = the next cascade's probe grid
    uint4  layout;     // x = probe spacing in pixels, y = direction tile side, z = cascade index, w = 1 if last cascade
    float4 interval;   // x = start, y = end (meters), z = 1 to use last frame's indirect light at hits, w unused
};

constant uint RC_MAX_CASCADES = 5;

// Per cascade: xy = probe grid, z = probe spacing in pixels, w = index of its first probe in the flat dispatch.
struct RCProbeBatch {
    uint4 cascades[RC_MAX_CASCADES];
};

// One probe per cell of each cascade's grid, on the surface seen through the cell centre. Traced with its own
// unjittered ray so probes don't move with MetalFX's sub-pixel jitter. All cascades run in one flat dispatch
// (cascade 0's probes first): the coarse cascades have only a few hundred probes each, too few to fill the GPU.
kernel void rcProbeKernel(constant Uniforms&               u          [[buffer(0)]],
                          SCENE_ACCEL                      accel      [[buffer(1)]],
                          device const float3*             positions  [[buffer(2)]],
                          device const float3*             normals    [[buffer(3)]],
                          device const uint*               indices    [[buffer(4)]],
                          device const MeshData*           meshes     [[buffer(5)]],
                          device const InstanceData*       instances  [[buffer(6)]],
                          constant SceneShading&           shading    [[buffer(7)]],
                          device const Light*              lights     [[buffer(8)]],
                          constant RCProbeBatch&           batch      [[buffer(9)]],
                          constant uint&                   cascadeCount [[buffer(10)]],
                          array<texture2d<float, access::write>, RC_MAX_CASCADES> probePos [[texture(0)]],   // xyz, w = view depth (-1 = none)
                          array<texture2d<float, access::write>, RC_MAX_CASCADES> probeNs  [[texture(5)]],   // shading normal
                          array<texture2d<float, access::write>, RC_MAX_CASCADES> probeNg  [[texture(10)]],  // geometric normal
                          uint gid [[thread_position_in_grid]])
{
    uint c = 0;
    while (c + 1 < cascadeCount && gid >= batch.cascades[c + 1].w) ++c;
    uint4 k = batch.cascades[c];
    uint local = gid - k.w;
    if (local >= k.x * k.y) return;
    uint2 tid = uint2(local % k.x, local / k.x);
    SceneData s;
    s.positions = positions; s.normals = normals; s.indices = indices; s.meshes = meshes;
    s.instances = instances; bindShading(s, shading); s.lights = lights; s.lightCount = u.lightCount;

    float2 pixel = min((float2(tid) + 0.5f) * float(k.z), float2(u.width, u.height) - 0.5f);
    float2 uv = pixel / float2(u.width, u.height);
    float3 dir = normalize(u.camForward.xyz + (2.0f * uv.x - 1.0f) * u.camRight.w * u.camRight.xyz
                                            + (1.0f - 2.0f * uv.y) * u.camUp.w * u.camUp.xyz);
    Surface sf = traceSurface(makeRay(u.camPos.xyz, dir, 0.0f, INFINITY), MASK_GEOMETRY, accel, s,
                              2.0f * u.camUp.w / float(u.height) * float(k.z));   // the probe cell's angle
    if (!sf.hit) {
        probePos[c].write(float4(0.0f, 0.0f, 0.0f, -1.0f), tid);
        return;
    }
    float3 ng, ns;
    orientNormals(sf, dir, ng, ns);
    probePos[c].write(float4(sf.position, dot(sf.position - u.camPos.xyz, u.camForward.xyz)), tid);
    probeNs[c].write(float4(ns, 0.0f), tid);
    probeNg[c].write(float4(ng, 0.0f), tid);
}

// Weight of a neighbouring probe q when interpolating at a point x with normal n: probes on a different surface
// (off x's tangent plane, or facing elsewhere) get little weight, which keeps light from leaking across edges.
inline float rcProbeWeight(float4 q, float3 qn, float3 x, float3 n, float depth) {
    if (q.w <= 0.0f) return 0.0f;
    float planeDist = abs(dot(q.xyz - x, n));
    return exp(-planeDist / (0.02f * depth + 0.01f)) * pow(saturate(dot(n, qn)), 4.0f);
}

// Traces one (probe, direction) interval of cascade c and merges cascade c+1 into it. Threads are ordered
// direction-major (neighbouring threads = neighbouring probes, same direction) so rays stay coherent.
kernel void rcTraceMergeKernel(constant Uniforms&               u          [[buffer(0)]],
                               SCENE_ACCEL                      accel      [[buffer(1)]],
                               device const float3*             positions  [[buffer(2)]],
                               device const float3*             normals    [[buffer(3)]],
                               device const uint*               indices    [[buffer(4)]],
                               device const MeshData*           meshes     [[buffer(5)]],
                               device const InstanceData*       instances  [[buffer(6)]],
                               constant SceneShading&           shading    [[buffer(7)]],
                               device const Light*              lights     [[buffer(8)]],
                               constant RCParams&               p          [[buffer(9)]],
                               texture2d<float, access::read>   probePos   [[texture(0)]],
                               texture2d<float, access::read>   probeNs    [[texture(1)]],
                               texture2d<float, access::read>   probeNg    [[texture(2)]],
                               texture2d<float, access::read>   nextPos    [[texture(3)]],   // cascade c+1 probes
                               texture2d<float, access::read>   nextNs     [[texture(4)]],
                               texture2d<float, access::read>   nextMerged [[texture(5)]],   // cascade c+1 result
                               texture2d<float, access::write>  merged     [[texture(6)]],   // this cascade's result
                               texture2d_array<float, access::read> lightMap [[texture(7)]],
                               texture2d<float, access::read>   prevND     [[texture(8)]],   // last frame's normal + depth
                               texture2d<float, access::read>   prevIndirect [[texture(9)]], // last frame's indirect light
                               device const uint*               prevAmbient [[buffer(10)]],  // rgb sums (x1024) + count
                               uint gid [[thread_position_in_grid]])
{
    uint probeCount = p.grids.x * p.grids.y;
    uint dirSide = p.layout.y;
    if (gid >= probeCount * dirSide * dirSide) return;
    uint probe = gid % probeCount, bin = gid / probeCount;
    uint2 pc = uint2(probe % p.grids.x, probe / p.grids.x);
    uint2 bc = uint2(bin % dirSide, bin / dirSide);
    uint2 texel = pc * dirSide + bc;

    float4 pos = probePos.read(pc);
    if (pos.w <= 0.0f) { merged.write(float4(0.0f), texel); return; }
    float3 ng = probeNg.read(pc).xyz;
    float3 dir = equalAreaOctDecode((float2(bc) + 0.5f) / float(dirSide) * 2.0f - 1.0f);
    if (dot(dir, ng) < -0.05f) { merged.write(float4(0.0f), texel); return; }   // below the surface: never used

    SceneData s;
    s.positions = positions; s.normals = normals; s.indices = indices; s.meshes = meshes;
    s.instances = instances; bindShading(s, shading); s.lights = lights; s.lightCount = u.lightCount;
    bool last = p.layout.w != 0;
    Ray r = makeRay(pos.xyz + ng * RAY_EPSILON, dir, p.interval.x, last ? INFINITY : p.interval.y);
    Surface h = traceSurface(r, MASK_GEOMETRY, accel, s, GI_RAY_SPREAD);

    float3 radiance = float3(0.0f);
    if (h.hit) {
        float3 hng, hns;
        orientNormals(h, dir, hng, hns);
        float3 hp = h.position + hng * RAY_EPSILON;
        float3 light = lightIllumCached(lights, u.lightCount, lightMap, hp, hns, hng,
                                        pcgHash(gid + pcgHash(u.frameIndex + p.layout.x * 7919u)), u.flags);
        if (p.interval.z > 0.0f) {
            // Multi-bounce: where this hit point was on screen last frame, add last frame's indirect light there;
            // elsewhere (off screen, occluded) fall back to last frame's average indirect light over all probes.
            float prevDepth;
            float2 pp = projectToPixel(h.prevPosition - u.prevCamPos.xyz, u.prevCamRight, u.prevCamUp, u.prevCamForward,
                                       float2(u.width, u.height), prevDepth);
            bool found = false;
            if (prevDepth > 0.0f && all(pp >= 0.0f) && pp.x < float(u.width) && pp.y < float(u.height)) {
                uint2 q = uint2(pp);
                float4 nd = prevND.read(q);
                if (nd.w > 0.0f && abs(nd.w - prevDepth) < 0.05f * prevDepth && dot(nd.xyz, hns) > 0.8f) {
                    light += prevIndirect.read(q).rgb;
                    found = true;
                }
            }
            if (!found && prevAmbient[3] > 0)
                light += float3(prevAmbient[0], prevAmbient[1], prevAmbient[2]) / (1024.0f * float(prevAmbient[3]));
        }
        radiance = hitAlbedo(h) * light;
    } else if (last) {
        radiance = u.skyColor.rgb;
    } else {
        // Nothing hit in this interval: continue with the next cascade's radiance in this direction.
        float2 g = (float2(pc) + 0.5f) * 0.5f - 0.5f;   // this probe in the next cascade's (half-res) grid
        int2 base = int2(floor(g));
        float2 f = g - float2(base);
        float3 n = probeNs.read(pc).xyz;
        uint nextSide = dirSide * 2;
        float3 sum = float3(0.0f), sumPlain = float3(0.0f);
        float wsum = 0.0f, wPlain = 0.0f;
        for (int k = 0; k < 4; ++k) {
            int2 o = int2(k & 1, k >> 1);
            uint2 q = uint2(clamp(base + o, int2(0), int2(p.grids.zw) - 1));
            float4 qp = nextPos.read(q);
            if (qp.w <= 0.0f) continue;
            float bil = (o.x ? f.x : 1.0f - f.x) * (o.y ? f.y : 1.0f - f.y);
            uint2 child = q * nextSide + bc * 2;
            float3 avg = 0.25f * (nextMerged.read(child).rgb + nextMerged.read(child + uint2(1, 0)).rgb
                                + nextMerged.read(child + uint2(0, 1)).rgb + nextMerged.read(child + uint2(1, 1)).rgb);
            float w = bil * rcProbeWeight(qp, nextNs.read(q).xyz, pos.xyz, n, pos.w);
            sum += avg * w; wsum += w;
            sumPlain += avg * bil; wPlain += bil;
        }
        radiance = wsum > 1e-4f ? sum / wsum : (wPlain > 0.0f ? sumPlain / wPlain : float3(0.0f));
    }
    merged.write(float4(radiance, 0.0f), texel);
}

// Projects each cascade-0 probe's merged radiance onto L1 spherical harmonics (per colour channel: L00, L1-1,
// L10, L11), so the per-pixel resolve evaluates irradiance for any normal with a few reads instead of re-reading
// every direction bin. Also sums each probe's mean irradiance into `ambient` (fixed point), which next frame
// uses as the indirect light at ray hits that weren't on screen.
kernel void rcSHKernel(constant RCParams&               p        [[buffer(9)]],   // cascade 0
                       device atomic_uint*              ambient  [[buffer(10)]],  // rgb sums (x1024) + count
                       texture2d<float, access::read>   probePos [[texture(0)]],
                       texture2d<float, access::read>   merged   [[texture(1)]],
                       texture2d<float, access::write>  shR      [[texture(2)]],
                       texture2d<float, access::write>  shG      [[texture(3)]],
                       texture2d<float, access::write>  shB      [[texture(4)]],
                       uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= p.grids.x || tid.y >= p.grids.y) return;
    if (probePos.read(tid).w <= 0.0f) return;
    uint dirSide = p.layout.y;
    float dOmega = 4.0f * M_PI_F / float(dirSide * dirSide);
    float4 r = float4(0.0f), g = float4(0.0f), b = float4(0.0f);
    for (uint k = 0; k < dirSide * dirSide; ++k) {
        uint2 bc = uint2(k % dirSide, k / dirSide);
        float3 dir = equalAreaOctDecode((float2(bc) + 0.5f) / float(dirSide) * 2.0f - 1.0f);
        float4 basis = float4(0.282095f, 0.488603f * dir.y, 0.488603f * dir.z, 0.488603f * dir.x) * dOmega;
        float3 L = merged.read(tid * dirSide + bc).rgb;
        r += L.r * basis; g += L.g * basis; b += L.b * basis;
    }
    shR.write(r, tid); shG.write(g, tid); shB.write(b, tid);
    // Mean irradiance over the probe's hemisphere ~ L00 term (illumination units: E / pi = 0.282095 * L00).
    float3 mean = 0.282095f * float3(r.x, g.x, b.x) * 2.0f;   // x2: only the upper hemisphere carries light
    atomic_fetch_add_explicit(&ambient[0], uint(clamp(mean.r, 0.0f, 1e5f) * 1024.0f), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambient[1], uint(clamp(mean.g, 0.0f, 1e5f) * 1024.0f), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambient[2], uint(clamp(mean.b, 0.0f, 1e5f) * 1024.0f), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambient[3], 1, memory_order_relaxed);
}

kernel void rcClearAmbientKernel(device uint* ambient [[buffer(10)]]) {
    ambient[0] = ambient[1] = ambient[2] = ambient[3] = 0;
}

// Irradiance / pi from L1 SH for normal n (cosine-lobe convolution: A0 = pi, A1 = 2pi/3).
inline float rcEvalSH(float4 sh, float3 n) {
    return max(0.282095f * sh.x + (2.0f / 3.0f) * 0.488603f * (sh.y * n.y + sh.z * n.z + sh.w * n.x), 0.0f);
}

// Per pixel: weighted average over the 4x4 nearest cascade-0 probes (smooth distance falloff x plane/normal
// similarity), each evaluated for the pixel's normal from its SH. Output is "illumination" (mean incoming
// radiance under cosine weighting), the same units as the path tracer's indirect light.
kernel void rcResolveKernel(constant Uniforms&              u          [[buffer(0)]],
                            constant RCParams&              p          [[buffer(9)]],   // cascade 0
                            texture2d<float, access::read>  probePos   [[texture(0)]],
                            texture2d<float, access::read>  probeNs    [[texture(1)]],
                            texture2d<float, access::read>  shR        [[texture(2)]],
                            texture2d<float, access::read>  shG        [[texture(3)]],
                            texture2d<float, access::read>  shB        [[texture(4)]],
                            texture2d<float, access::read>  normalDepth [[texture(5)]],
                            texture2d<float, access::read>  surfacePos [[texture(6)]],
                            texture2d<float, access::write> outIndirect [[texture(7)]],
                            texture2d<float, access::write> outHistory [[texture(8)]],  // kept for next frame's multi-bounce
                            texture2d<float, access::write> giDebug    [[texture(9)]],
                            uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    if (sp.w <= 0.0f) {
        outIndirect.write(float4(0.0f), tid);
        outHistory.write(float4(0.0f), tid);
        giDebug.write(float4(0.0f), tid);
        return;
    }
    float4 nd = normalDepth.read(tid);
    float3 n = nd.xyz;
    float2 g = (float2(tid) + 0.5f + u.jitter.xy) / float(p.layout.x) - 0.5f;
    int2 base = int2(floor(g)) - 1;
    float3 sum = float3(0.0f);
    float wsum = 0.0f;
    for (int k = 0; k < 16; ++k) {
        int2 qi = base + int2(k & 3, k >> 2);
        if (any(qi < 0) || qi.x >= int(p.grids.x) || qi.y >= int(p.grids.y)) continue;
        uint2 q = uint2(qi);
        float4 qp = probePos.read(q);
        if (qp.w <= 0.0f) continue;
        float2 d = float2(qi) - g;
        float falloff = exp(-dot(d, d) * 0.8f);   // ~bilinear-width Gaussian over the 4x4 neighbourhood
        float w = falloff * rcProbeWeight(qp, probeNs.read(q).xyz, sp.xyz, n, nd.w) + 1e-6f * falloff;
        float3 e = float3(rcEvalSH(shR.read(q), n), rcEvalSH(shG.read(q), n), rcEvalSH(shB.read(q), n));
        sum += e * w;
        wsum += w;
    }
    float3 indirect = wsum > 0.0f ? sum / wsum : float3(0.0f);
    outIndirect.write(float4(indirect, 1.0f), tid);
    outHistory.write(float4(indirect, 1.0f), tid);
    // Debug: probe grid lines over the strongest weight's confidence (dark = no good probe nearby).
    bool grid = any(fmod(float2(tid), float(p.layout.x)) < 1.0f);
    giDebug.write(float4(grid ? float3(0.25f) : float3(saturate(wsum)), 1.0f), tid);
}

// =============================================================================================
// Surfel GI (GI mode "Surfels", after EA SEED's GIBS)
//
// Small disks ("surfels") are spawned on visible surfaces where coverage is low and stored in their instance's
// object space, so they ride along with moving objects. Each frame:
//   begin -> transform (world positions, alive list, grid cell counts) -> scan (cell offsets, indirect dispatch
//   args) -> scatter (grid lists) -> trace (R rays per surfel; hits are lit by the light maps plus last frame's
//   surfel irradiance there = multi-bounce; temporal blend) -> gather + spawn (per pixel: weighted average of
//   nearby surfels; one spawn per 16x16 tile at its least-covered pixel) -> lifecycle (free flagged / stale).
// Spawning pops the free stack and the lifecycle pass pushes it; they're separate dispatches, so they never race.
// =============================================================================================

constant uint SURFEL_DEAD = 0xFFFFFFFFu;

struct Surfel {
    float4 objPosRadius;   // xyz = position in the instance's object space, w = world radius
    float4 objNormal;      // shading normal, object space
    float4 objGeomNormal;  // geometric normal, object space
    uint   instance;       // SURFEL_DEAD = free slot
    uint   spawnFrame;
    uint   pad0;
    uint   pad1;
};

struct SurfelIrradiance {
    float4 longMean;       // rgb = irradiance estimate (what pixels read), w = frames accumulated
    float4 shortMean;      // rgb = fast-moving mean, w = luminance variance (anti-lag)
};

struct SurfelHeader {
    atomic_uint aliveCount;
    atomic_uint freeTop;          // free stack size
    atomic_uint spawnCount;       // this frame (stats)
    atomic_uint killCount;        // this frame (stats)
    uint        aliveDispatch[3]; // threadgroups of 64 over the alive list (indirect dispatch)
    uint        traceDispatch[3]; // threadgroups of 32 over alive x rays
    uint        pad[2];
};

struct SurfelParams {
    float4 gridMin;   // xyz = grid origin, w = cell size
    uint4  gridDims;  // xyz = cells, w = cell count
    uint4  config;    // x = max surfels, y = rays per surfel (power of two <= 32), z = frame, w unused
    float4 tuning;    // x = target radius in pixels, y = max history, z = pixel angle (2 tan(fovY/2) / height), w unused
};

inline int3 surfelCell(float3 p, constant SurfelParams& sp) {
    return clamp(int3(floor((p - sp.gridMin.xyz) / sp.gridMin.w)), int3(0), int3(sp.gridDims.xyz) - 1);
}
inline uint surfelCellIndex(int3 c, constant SurfelParams& sp) {
    return (uint(c.z) * sp.gridDims.y + uint(c.y)) * sp.gridDims.x + uint(c.x);
}

// Weighted average of the surfels covering point x (shading normal n). Returns rgb + total weight (coverage).
inline float4 surfelLookup(float3 x, float3 n, constant SurfelParams& sp,
                           device const uint* cellStart, device const uint* cellSurfels,
                           device const float4* worldPos, device const float4* worldNormal,
                           device const SurfelIrradiance* irr) {
    uint c = surfelCellIndex(surfelCell(x, sp), sp);
    float3 sum = float3(0.0f);
    float wsum = 0.0f;
    for (uint k = cellStart[c]; k < cellStart[c + 1]; ++k) {
        uint id = cellSurfels[k];
        float4 pr = worldPos[id];
        float3 d = x - pr.xyz;
        float dist = length(d);
        if (dist >= pr.w) continue;
        float3 sn = worldNormal[id].xyz;
        if (abs(dot(d, sn)) > 0.5f * pr.w) continue;   // on a different surface
        float w = (1.0f - dist / pr.w);
        w *= w * pow(saturate(dot(n, sn)), 8.0f);
        sum += w * irr[id].longMean.rgb;
        wsum += w;
    }
    return float4(sum, wsum);
}

// Buffer indices are shared by all surfel kernels: 0 = SurfelParams (or Uniforms for trace / gather, which then
// take SurfelParams at 9), 6 = instances, 10 = header, 11 = alive list, 12 = cell counts, 13-15 = world-space
// position/normal/geometric normal, 16 = cell starts, 17 = scatter cursors, 18 = cell lists, 19 / 20 = previous /
// current irradiance, 21 = last-used frame, 22 = surfels, 23 = free stack, 24 = kill flags, 25 / 26 = this /
// last frame's mean surfel irradiance (rgb sums x1024 + count), used where no surfel covers a point.
kernel void surfelClearKernel(constant SurfelParams& sp [[buffer(0)]], device Surfel* surfels [[buffer(22)]],
                              device SurfelIrradiance* irrA [[buffer(19)]], device SurfelIrradiance* irrB [[buffer(20)]],
                              device uint* freeStack [[buffer(23)]], device uint* lastUsed [[buffer(21)]],
                              device SurfelHeader& header [[buffer(10)]], device atomic_uint* cellCount [[buffer(12)]],
                              device uint* killFlag [[buffer(24)]],
                              uint gid [[thread_position_in_grid]])
{
    uint maxSurfels = sp.config.x;
    if (gid < maxSurfels) {
        surfels[gid].instance = SURFEL_DEAD;
        irrA[gid].longMean = irrA[gid].shortMean = float4(0.0f);
        irrB[gid].longMean = irrB[gid].shortMean = float4(0.0f);
        freeStack[gid] = maxSurfels - 1 - gid;   // pops hand out 0, 1, 2, ...
        lastUsed[gid] = 0;
        killFlag[gid] = 0;
    }
    if (gid < sp.gridDims.w) atomic_store_explicit(&cellCount[gid], 0, memory_order_relaxed);
    if (gid == 0) {
        atomic_store_explicit(&header.aliveCount, 0, memory_order_relaxed);
        atomic_store_explicit(&header.freeTop, maxSurfels, memory_order_relaxed);
        atomic_store_explicit(&header.spawnCount, 0, memory_order_relaxed);
        atomic_store_explicit(&header.killCount, 0, memory_order_relaxed);
    }
}

inline float3 surfelAmbient(device const uint* a) {
    return a[3] > 0 ? float3(a[0], a[1], a[2]) / (1024.0f * float(a[3])) : float3(0.0f);
}

kernel void surfelBeginKernel(device SurfelHeader& header [[buffer(10)]], device uint* ambientCur [[buffer(25)]]) {
    ambientCur[0] = ambientCur[1] = ambientCur[2] = ambientCur[3] = 0;
    atomic_store_explicit(&header.aliveCount, 0, memory_order_relaxed);
    atomic_store_explicit(&header.spawnCount, 0, memory_order_relaxed);
    atomic_store_explicit(&header.killCount, 0, memory_order_relaxed);
}

kernel void surfelTransformKernel(constant SurfelParams& sp [[buffer(0)]], device const Surfel* surfels [[buffer(22)]],
                                  device const InstanceData* instances [[buffer(6)]],
                                  device SurfelHeader& header [[buffer(10)]], device uint* aliveList [[buffer(11)]],
                                  device atomic_uint* cellCount [[buffer(12)]],
                                  device float4* worldPos [[buffer(13)]], device float4* worldNormal [[buffer(14)]],
                                  device float4* worldGeomNormal [[buffer(15)]],
                                  uint gid [[thread_position_in_grid]])
{
    if (gid >= sp.config.x) return;
    Surfel s = surfels[gid];
    if (s.instance == SURFEL_DEAD) return;
    InstanceData inst = instances[s.instance];
    float3 p = (inst.transform * float4(s.objPosRadius.xyz, 1.0f)).xyz;
    float r = s.objPosRadius.w;
    worldPos[gid] = float4(p, r);
    worldNormal[gid] = float4(normalize((inst.normalMatrix * float4(s.objNormal.xyz, 0.0f)).xyz), 0.0f);
    worldGeomNormal[gid] = float4(normalize((inst.normalMatrix * float4(s.objGeomNormal.xyz, 0.0f)).xyz), 0.0f);
    aliveList[atomic_fetch_add_explicit(&header.aliveCount, 1, memory_order_relaxed)] = gid;
    int3 lo = surfelCell(p - r, sp), hi = surfelCell(p + r, sp);
    for (int z = lo.z; z <= hi.z; ++z)
        for (int y = lo.y; y <= hi.y; ++y)
            for (int x = lo.x; x <= hi.x; ++x)
                atomic_fetch_add_explicit(&cellCount[surfelCellIndex(int3(x, y, z), sp)], 1, memory_order_relaxed);
}

// One threadgroup of 1024: exclusive prefix sum over the cell counts -> cellStart (and the scatter cursors),
// counts reset for next frame, indirect dispatch sizes from the alive count.
kernel void surfelScanKernel(constant SurfelParams& sp [[buffer(0)]], device SurfelHeader& header [[buffer(10)]],
                             device atomic_uint* cellCount [[buffer(12)]], device uint* cellStart [[buffer(16)]],
                             device atomic_uint* cellCursor [[buffer(17)]],
                             uint tid [[thread_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                             uint simd [[simdgroup_index_in_threadgroup]])
{
    threadgroup uint simdTotals[32];
    uint cells = sp.gridDims.w, perThread = (cells + 1023) / 1024, first = tid * perThread;
    uint local = 0;
    for (uint k = 0; k < perThread; ++k)
        if (first + k < cells) local += atomic_load_explicit(&cellCount[first + k], memory_order_relaxed);
    uint prefix = simd_prefix_exclusive_sum(local);
    if (lane == 31) simdTotals[simd] = prefix + local;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (simd == 0) {
        uint t = simdTotals[lane];
        simdTotals[lane] = simd_prefix_exclusive_sum(t);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint offset = simdTotals[simd] + prefix;
    for (uint k = 0; k < perThread; ++k) {
        uint c = first + k;
        if (c >= cells) break;
        uint n = atomic_load_explicit(&cellCount[c], memory_order_relaxed);
        cellStart[c] = offset;
        atomic_store_explicit(&cellCursor[c], offset, memory_order_relaxed);
        atomic_store_explicit(&cellCount[c], 0, memory_order_relaxed);
        offset += n;
    }
    if (first < cells && first + perThread >= cells) cellStart[cells] = offset;   // thread holding the last cell
    if (tid == 0) {
        uint alive = atomic_load_explicit(&header.aliveCount, memory_order_relaxed);
        header.aliveDispatch[0] = (alive + 63) / 64; header.aliveDispatch[1] = 1; header.aliveDispatch[2] = 1;
        header.traceDispatch[0] = (alive * sp.config.y + 31) / 32; header.traceDispatch[1] = 1; header.traceDispatch[2] = 1;
    }
}

kernel void surfelScatterKernel(constant SurfelParams& sp [[buffer(0)]], device SurfelHeader& header [[buffer(10)]],
                                device const uint* aliveList [[buffer(11)]], device const float4* worldPos [[buffer(13)]],
                                device atomic_uint* cellCursor [[buffer(17)]], device uint* cellSurfels [[buffer(18)]],
                                uint gid [[thread_position_in_grid]])
{
    if (gid >= atomic_load_explicit(&header.aliveCount, memory_order_relaxed)) return;
    uint id = aliveList[gid];
    float4 pr = worldPos[id];
    int3 lo = surfelCell(pr.xyz - pr.w, sp), hi = surfelCell(pr.xyz + pr.w, sp);
    for (int z = lo.z; z <= hi.z; ++z)
        for (int y = lo.y; y <= hi.y; ++y)
            for (int x = lo.x; x <= hi.x; ++x) {
                uint c = surfelCellIndex(int3(x, y, z), sp);
                cellSurfels[atomic_fetch_add_explicit(&cellCursor[c], 1, memory_order_relaxed)] = id;
            }
}

// One thread per (surfel, ray); the rays of a surfel are adjacent lanes of one SIMD group and get summed with
// shuffles, then lane 0 blends the result into the surfel's irradiance (short + long running means, with the
// long one's history cut when the two disagree beyond noise, i.e. when the lighting changes).
kernel void surfelTraceKernel(constant Uniforms&               u          [[buffer(0)]],
                              SCENE_ACCEL                      accel      [[buffer(1)]],
                              device const float3*             positions  [[buffer(2)]],
                              device const float3*             normals    [[buffer(3)]],
                              device const uint*               indices    [[buffer(4)]],
                              device const MeshData*           meshes     [[buffer(5)]],
                              device const InstanceData*       instances  [[buffer(6)]],
                              constant SceneShading&           shading    [[buffer(7)]],
                              device const Light*              lights     [[buffer(8)]],
                              constant SurfelParams&           sp         [[buffer(9)]],
                              device SurfelHeader&             header     [[buffer(10)]],
                              device const uint*               aliveList  [[buffer(11)]],
                              device const float4*             worldPos   [[buffer(13)]],
                              device const float4*             worldNormal [[buffer(14)]],
                              device const float4*             worldGeomNormal [[buffer(15)]],
                              device const uint*               cellStart  [[buffer(16)]],
                              device const uint*               cellSurfels [[buffer(18)]],
                              device const SurfelIrradiance*   irrPrev    [[buffer(19)]],
                              device SurfelIrradiance*         irrCur     [[buffer(20)]],
                              device const uint*               lastUsed   [[buffer(21)]],
                              device atomic_uint*              ambientCur [[buffer(25)]],
                              device const uint*               ambientPrev [[buffer(26)]],
                              texture2d_array<float, access::read> lightMap [[texture(0)]],
                              uint gid [[thread_position_in_grid]])
{
    uint rays = sp.config.y, frame = sp.config.z;
    uint alive = atomic_load_explicit(&header.aliveCount, memory_order_relaxed);
    uint slot = gid / rays, rayIndex = gid % rays;
    bool valid = slot < alive;
    uint id = valid ? aliveList[slot] : 0;
    // Surfels not seen for a couple of frames (off screen) only trace every 4th frame.
    bool visible = valid && frame - lastUsed[id] <= 2u;
    bool traceNow = valid && (visible || ((id + frame) & 3u) == 0u);

    float3 radiance = float3(0.0f);
    if (traceNow) {
        SceneData s;
        s.positions = positions; s.normals = normals; s.indices = indices; s.meshes = meshes;
        s.instances = instances; bindShading(s, shading); s.lights = lights; s.lightCount = u.lightCount;
        float3 p = worldPos[id].xyz, n = worldNormal[id].xyz, ng = worldGeomNormal[id].xyz;
        // Stratified over the surfel's rays, randomly rotated per surfel and frame.
        uint h = pcgHash(id * 9781u + pcgHash(frame));
        float2 jitter = float2(h & 0xFFFFu, h >> 16) * (1.0f / 65536.0f);
        float2 uv = fract(float2((float(rayIndex) + 0.5f) / float(rays), float(rayIndex) * 0.618034f) + jitter);
        float3 d = cosineSampleHemisphere(n, uv);
        if (dot(d, ng) <= 0.0f) d -= 2.0f * dot(d, ng) * ng;
        Surface hit = traceSurface(makeRay(p + ng * RAY_EPSILON, d, 0.0f, INFINITY), MASK_GEOMETRY, accel, s, GI_RAY_SPREAD);
        if (!hit.hit) {
            radiance = u.skyColor.rgb;
        } else {
            float3 hng, hns;
            orientNormals(hit, d, hng, hns);
            float3 hp = hit.position + hng * RAY_EPSILON;
            float3 light = lightIllumCached(lights, u.lightCount, lightMap, hp, hns, hng, pcgHash(h + rayIndex), u.flags);
            float4 bounce = surfelLookup(hit.position, hns, sp, cellStart, cellSurfels, worldPos, worldNormal, irrPrev);
            // Multi-bounce from last frame's surfels there; where none exist yet (e.g. never seen), their average.
            light += bounce.w > 0.0f ? bounce.rgb / bounce.w : surfelAmbient(ambientPrev);
            radiance = hitAlbedo(hit) * light;
        }
    }
    // Sum the rays of this surfel (adjacent lanes; rays is a power of two <= 32).
    for (uint offset = 1; offset < rays; offset <<= 1)
        radiance += simd_shuffle_xor(radiance, ushort(offset));
    if (!valid || rayIndex != 0) return;

    SurfelIrradiance prev = irrPrev[id];
    if (!traceNow) { irrCur[id] = prev; return; }
    float3 mean = radiance / float(rays);
    SurfelIrradiance next;
    float count = prev.longMean.w;
    if (count < 0.5f) {
        next.longMean = float4(mean, 1.0f);
        next.shortMean = float4(mean, 0.0f);
    } else {
        float3 shortMean = mix(prev.shortMean.rgb, mean, 0.25f);
        float lumDiff = luminance(mean) - luminance(shortMean);
        float variance = mix(prev.shortMean.w, lumDiff * lumDiff, 0.25f);
        // Anti-lag: when the fast and slow means disagree by more than ~3 standard errors, the light changed.
        float stdError = sqrt(variance) * 0.4f + 1e-3f * luminance(shortMean) + 1e-5f;
        float excess = max(abs(luminance(shortMean) - luminance(prev.longMean.rgb)) / stdError - 3.0f, 0.0f);
        count = min(count / (1.0f + excess) + 1.0f, sp.tuning.y);
        next.longMean = float4(mix(prev.longMean.rgb, mean, 1.0f / count), count);
        next.shortMean = float4(shortMean, variance);
    }
    irrCur[id] = next;
    float3 e = clamp(next.longMean.rgb, 0.0f, 100.0f) * 1024.0f;
    atomic_fetch_add_explicit(&ambientCur[0], uint(e.r), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambientCur[1], uint(e.g), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambientCur[2], uint(e.b), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambientCur[3], 1, memory_order_relaxed);
}

// Per pixel (16x16 threadgroups): weighted average of the surfels around the pixel -> indirect light, coverage
// bookkeeping, then the tile's least-covered pixel may spawn one surfel.
kernel void surfelGatherSpawnKernel(constant Uniforms&               u          [[buffer(0)]],
                                    device const InstanceData*       instances  [[buffer(6)]],
                                    constant SurfelParams&           sp         [[buffer(9)]],
                                    device SurfelHeader&             header     [[buffer(10)]],
                                    device const float4*             worldPos   [[buffer(13)]],
                                    device const float4*             worldNormal [[buffer(14)]],
                                    device const uint*               cellStart  [[buffer(16)]],
                                    device const uint*               cellSurfels [[buffer(18)]],
                                    device SurfelIrradiance*         irrCur     [[buffer(20)]],
                                    device uint*                     lastUsed   [[buffer(21)]],
                                    device Surfel*                   surfels    [[buffer(22)]],
                                    device const uint*               freeStack  [[buffer(23)]],
                                    device uint*                     killFlag   [[buffer(24)]],
                                    device const uint*               ambientPrev [[buffer(26)]],
                                    texture2d<float, access::read>   surfacePos [[texture(0)]],
                                    texture2d<float, access::read>   normalDepth [[texture(1)]],
                                    texture2d<float, access::read>   geoNormal  [[texture(2)]],
                                    texture2d<float, access::write>  outIndirect [[texture(3)]],
                                    texture2d<float, access::write>  giDebug    [[texture(4)]],
                                    uint2 tid [[thread_position_in_grid]], uint lid [[thread_index_in_threadgroup]],
                                    uint simd [[simdgroup_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]])
{
    threadgroup uint simdMin[8];
    uint frame = sp.config.z;
    bool inside = tid.x < u.width && tid.y < u.height;
    float4 spos = inside ? surfacePos.read(tid) : float4(0.0f);
    bool needsGI = spos.w > 0.0f;
    float coverage = 1e9f;
    float3 x = spos.xyz, n = float3(0.0f, 1.0f, 0.0f);
    float3 gathered = float3(0.0f);
    float depth = 1.0f;
    if (needsGI) {
        float4 nd = normalDepth.read(tid);
        n = nd.xyz;
        depth = nd.w;
        float rTarget = sp.tuning.x * sp.tuning.z * depth;
        uint c = surfelCellIndex(surfelCell(x, sp), sp);
        float3 sum = float3(0.0f);
        float wsum = 0.0f, best = 0.0f;
        uint bestId = 0, topHash = 0, topId = SURFEL_DEAD;
        for (uint k = cellStart[c]; k < cellStart[c + 1]; ++k) {
            uint id = cellSurfels[k];
            float4 pr = worldPos[id];
            if (pr.w > 2.0f * rTarget) killFlag[id] = 1;        // much bigger than wanted here (camera got closer)
            float r = min(pr.w, 1.5f * rTarget);
            float3 d = x - pr.xyz;
            float dist = length(d);
            if (dist >= r) continue;
            float3 sn = worldNormal[id].xyz;
            if (abs(dot(d, sn)) > 0.5f * r) continue;
            float w = 1.0f - dist / r;
            w *= w * pow(saturate(dot(n, sn)), 8.0f);
            if (w <= 0.0f) continue;
            sum += w * irrCur[id].longMean.rgb;
            wsum += w;
            lastUsed[id] = frame;
            if (w > best) { best = w; bestId = id; }
            uint hsh = pcgHash(id);
            if (hsh >= topHash) { topHash = hsh; topId = id; }
        }
        coverage = wsum;
        if (wsum > 2.0f && topId != SURFEL_DEAD) killFlag[topId] = 1;   // over-covered: all pixels pick the same one
        // Normalized average; thin coverage blends toward the scene-wide mean so holes don't show as dark spots.
        float3 ambient = surfelAmbient(ambientPrev);
        gathered = wsum > 0.0f ? mix(ambient, sum / wsum, saturate(wsum * 4.0f)) : ambient;
        float3 dbg = wsum > 0.0f ? float3((uint3(pcgHash(bestId)) >> uint3(0, 8, 16)) & 0xFFu) / 255.0f * saturate(wsum)
                                 : float3(1.0f, 0.0f, 0.0f);   // holes in red
        if (inside) giDebug.write(float4(dbg, 1.0f), tid);
    } else if (inside) {
        giDebug.write(float4(0.0f), tid);
    }
    if (inside) outIndirect.write(float4(gathered, 1.0f), tid);

    // Tile-wide minimum coverage (key = quantized coverage << 8 | pixel index in the tile).
    uint key = needsGI ? (uint(min(coverage, 15.99f) * 4096.0f) << 8) | lid : 0xFFFFFFFFu;
    key = simd_min(key);
    if (lane == 0) simdMin[simd] = key;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lid != 0) return;
    for (uint k = 1; k < 8; ++k) key = min(key, simdMin[k]);
    if (key == 0xFFFFFFFFu) return;
    float minCoverage = float(key >> 8) / 4096.0f;
    const float targetCoverage = 0.3f;   // ~2 overlapping surfels (a surfel's mean weight over its disk is 1/6)
    if (minCoverage >= targetCoverage) return;
    uint h = pcgHash((tid.x / 16u) * 73856093u ^ (tid.y / 16u) * 19349663u ^ pcgHash(frame));
    if (float(h) * (1.0f / 4294967296.0f) > 1.0f - minCoverage / targetCoverage) return;

    // Spawn at that pixel: pop a free slot.
    uint2 p = (tid / 16u) * 16u + uint2((key & 0xFFu) % 16u, (key & 0xFFu) / 16u);
    uint top = atomic_fetch_sub_explicit(&header.freeTop, 1, memory_order_relaxed);
    if (top == 0 || top > sp.config.x) { atomic_fetch_add_explicit(&header.freeTop, 1, memory_order_relaxed); return; }
    uint id = freeStack[top - 1];
    float4 ps = surfacePos.read(p);
    float4 pnd = normalDepth.read(p);
    float3 png = geoNormal.read(p).xyz;
    uint instance = uint(ps.w) - 1u;
    InstanceData inst = instances[instance];
    float4x4 toObject = transpose(inst.normalMatrix);                 // = inverse(transform)
    float3x3 linear = float3x3(inst.transform[0].xyz, inst.transform[1].xyz, inst.transform[2].xyz);
    Surfel s;
    s.objPosRadius = float4((toObject * float4(ps.xyz, 1.0f)).xyz,
                            clamp(sp.tuning.x * sp.tuning.z * pnd.w, 0.05f, 0.5f * sp.gridMin.w));
    s.objNormal = float4(normalize(transpose(linear) * pnd.xyz), 0.0f);
    s.objGeomNormal = float4(normalize(transpose(linear) * png), 0.0f);
    s.instance = instance;
    s.spawnFrame = frame;
    s.pad0 = s.pad1 = 0;
    surfels[id] = s;
    irrCur[id].longMean = float4(0.0f);   // count 0: the first traced frame replaces it
    irrCur[id].shortMean = float4(0.0f);
    lastUsed[id] = frame;
    killFlag[id] = 0;
    atomic_fetch_add_explicit(&header.spawnCount, 1, memory_order_relaxed);
}

// Frees surfels flagged by the gather (oversized / over-covered), and stale ones when the pool runs low.
kernel void surfelLifecycleKernel(constant SurfelParams& sp [[buffer(9)]], device SurfelHeader& header [[buffer(10)]],
                                  device const uint* aliveList [[buffer(11)]], device const uint* lastUsed [[buffer(21)]],
                                  device Surfel* surfels [[buffer(22)]], device uint* freeStack [[buffer(23)]],
                                  device uint* killFlag [[buffer(24)]],
                                  uint gid [[thread_position_in_grid]])
{
    if (gid >= atomic_load_explicit(&header.aliveCount, memory_order_relaxed)) return;
    uint id = aliveList[gid];
    uint freeTop = atomic_load_explicit(&header.freeTop, memory_order_relaxed);
    bool lowOnSpace = freeTop < sp.config.x / 4;
    bool stale = sp.config.z - lastUsed[id] > 120u;
    if (killFlag[id] == 0 && !(lowOnSpace && stale)) return;
    killFlag[id] = 0;
    surfels[id].instance = SURFEL_DEAD;
    freeStack[atomic_fetch_add_explicit(&header.freeTop, 1, memory_order_relaxed)] = id;
    atomic_fetch_add_explicit(&header.killCount, 1, memory_order_relaxed);
}

// ---------------------------------------------------------------------------------------------
// Custom ray tracer: per-frame build of the dynamic top-level tree (LBVH, Karras 2012) over the moving instances
// (CustomRayTracer.encodeBuild). prep -> Morton keys -> bitonic sort -> hierarchy -> bottom-up boxes.
// ---------------------------------------------------------------------------------------------
#if CUSTOM_RT

// Every instance's RTInstance (world -> object rows = the first three columns of the inverse-transpose), and each
// moving instance's world box: leafBoxes[2k] = (min, instance id bits), leafBoxes[2k + 1] = (max, mask bits).
kernel void rtPrepKernel(constant uint&             instanceCount [[buffer(0)]],
                         device const InstanceData* instances  [[buffer(1)]],
                         device const float4*       meshInfo   [[buffer(2)]],   // per mesh: (box min, BLAS root bits), (box max, 0)
                         device const uint*         dynSlot    [[buffer(3)]],   // per instance: index among the moving ones, or ~0
                         device RTInstance*         out        [[buffer(4)]],
                         device float4*             leafBoxes  [[buffer(5)]],
                         uint i [[thread_position_in_grid]])
{
    if (i >= instanceCount) return;
    InstanceData inst = instances[i];
    float4 lo = meshInfo[2 * inst.meshIndex], hi = meshInfo[2 * inst.meshIndex + 1];   // virtual meshes too (bounds)
    RTInstance r;
    r.row0 = inst.normalMatrix[0];
    r.row1 = inst.normalMatrix[1];
    r.row2 = inst.normalMatrix[2];
    r.blasRoot = as_type<uint>(lo.w);
    r.mask = inst.pad0;
    r.pad0 = inst.pad1;   // virtual instance + 1 (its BLAS in RTScene.vgBlas), or 0
    r.pad1 = 0;
    out[i] = r;
    uint k = dynSlot[i];
    if (k == RT_NONE) return;
    // World box of the mesh box: centre + |M| * half extent.
    float3 c = (lo.xyz + hi.xyz) * 0.5f, e = (hi.xyz - lo.xyz) * 0.5f;
    float3 wc = (inst.transform * float4(c, 1.0f)).xyz;
    float3 we = abs(inst.transform[0].xyz) * e.x + abs(inst.transform[1].xyz) * e.y + abs(inst.transform[2].xyz) * e.z;
    leafBoxes[2 * k]     = float4(wc - we, as_type<float>(i));
    leafBoxes[2 * k + 1] = float4(wc + we, as_type<float>(inst.pad0));
}

inline uint rtExpandBits(uint v) {   // 10 bits -> every third bit
    v = (v * 0x00010001u) & 0xFF0000FFu;
    v = (v * 0x00000101u) & 0x0F00F00Fu;
    v = (v * 0x00000011u) & 0xC30C30C3u;
    v = (v * 0x00000005u) & 0x49249249u;
    return v;
}

// One threadgroup of 1024: centroid bounds of the moving instances, then 30-bit Morton keys, padded to `padded`
// (a power of two) with keys that sort last.
kernel void rtKeysKernel(constant uint2&       counts    [[buffer(0)]],   // x = moving instances, y = padded count
                         device const float4*  leafBoxes [[buffer(1)]],
                         device uint*          keys      [[buffer(2)]],
                         device uint*          values    [[buffer(3)]],
                         uint lid [[thread_position_in_threadgroup]],
                         uint simdLane [[thread_index_in_simdgroup]],
                         uint simdId [[simdgroup_index_in_threadgroup]])
{
    threadgroup float3 groupLo[32], groupHi[32];
    float3 lo = float3(INFINITY), hi = float3(-INFINITY);
    for (uint k = lid; k < counts.x; k += 1024) {
        float3 c = (leafBoxes[2 * k].xyz + leafBoxes[2 * k + 1].xyz) * 0.5f;
        lo = min(lo, c);
        hi = max(hi, c);
    }
    lo = simd_min(lo); hi = simd_max(hi);
    if (simdLane == 0) { groupLo[simdId] = lo; groupHi[simdId] = hi; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    lo = float3(INFINITY); hi = float3(-INFINITY);
    for (uint s = 0; s < 32; ++s) { lo = min(lo, groupLo[s]); hi = max(hi, groupHi[s]); }
    float3 scale = 1023.0f / max(hi - lo, float3(1e-6f));
    for (uint k = lid; k < counts.y; k += 1024) {
        uint key = 0xFFFFFFFFu;
        if (k < counts.x) {
            float3 c = (leafBoxes[2 * k].xyz + leafBoxes[2 * k + 1].xyz) * 0.5f;
            uint3 q = uint3(clamp((c - lo) * scale, 0.0f, 1023.0f));
            key = (rtExpandBits(q.x) << 2) | (rtExpandBits(q.y) << 1) | rtExpandBits(q.z);
        }
        keys[k] = key;
        values[k] = k;
    }
}

constant uint RT_SORT_BLOCK = 2048;   // keys a threadgroup sorts in threadgroup memory (1024 threads, one pair each)

inline void rtSortStep(threadgroup uint* sk, threadgroup uint* sv, uint n, uint base, uint k, uint j, uint lid) {
    for (uint t = lid; t < n / 2; t += 1024) {
        uint i = 2 * j * (t / j) + (t % j), l = i + j;
        bool ascending = ((base + i) & k) == 0;
        uint a = sk[i], b = sk[l];
        if (a != b && (a > b) == ascending) {
            sk[i] = b; sk[l] = a;
            uint v = sv[i]; sv[i] = sv[l]; sv[l] = v;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
}

// Bitonic sort of (key, value) pairs, ascending. params.y = 0: sort each 2048-key block (alternating directions,
// as bitonic merging needs); params.y = k > 2048: finish stage k inside each block (j < 2048). The padded count
// comes from `counts` (y), possibly written on the GPU: dispatches cover a capacity and skip what's beyond it.
kernel void rtSortLocalKernel(constant uint2&  params [[buffer(0)]],
                              device uint*     keys   [[buffer(1)]],
                              device uint*     values [[buffer(2)]],
                              constant uint2&  counts [[buffer(3)]],   // x = leaves, y = padded count
                              uint lid [[thread_position_in_threadgroup]],
                              uint group [[threadgroup_position_in_grid]])
{
    threadgroup uint sk[RT_SORT_BLOCK], sv[RT_SORT_BLOCK];
    uint padded = counts.y;
    uint n = min(RT_SORT_BLOCK, padded), base = group * RT_SORT_BLOCK;
    if (base >= padded || params.y > padded) return;
    for (uint e = lid; e < n; e += 1024) { sk[e] = keys[base + e]; sv[e] = values[base + e]; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (params.y == 0) {
        for (uint k = 2; k <= n; k <<= 1)
            for (uint j = k >> 1; j > 0; j >>= 1) rtSortStep(sk, sv, n, base, k, j, lid);
    } else {
        for (uint j = n >> 1; j > 0; j >>= 1) rtSortStep(sk, sv, n, base, params.y, j, lid);
    }
    for (uint e = lid; e < n; e += 1024) { keys[base + e] = sk[e]; values[base + e] = sv[e]; }
}

// One bitonic step (k, j >= 2048) across blocks, one thread per pair.
kernel void rtSortGlobalKernel(constant uint2&  params [[buffer(0)]],   // x = k, y = j
                               device uint*     keys   [[buffer(1)]],
                               device uint*     values [[buffer(2)]],
                               constant uint2&  counts [[buffer(3)]],
                               uint t [[thread_position_in_grid]])
{
    uint j = params.y, i = 2 * j * (t / j) + (t % j), l = i + j;
    if (params.x > counts.y || l >= counts.y) return;
    bool ascending = (i & params.x) == 0;
    uint a = keys[i], b = keys[l];
    if (a != b && (a > b) == ascending) {
        keys[i] = b; keys[l] = a;
        uint v = values[i]; values[i] = values[l]; values[l] = v;
    }
}

inline int rtDelta(device const uint* keys, int n, int i, int j) {
    if (j < 0 || j >= n) return -1;
    uint a = keys[i], b = keys[j];
    return a != b ? int(clz(a ^ b)) : 32 + int(clz(uint(i ^ j)));   // equal keys: the index breaks the tie
}

// Karras 2012: internal node i of n - 1 (n = moving instances, >= 2), from the sorted keys. Writes both child refs
// and the parent links the bottom-up pass follows (bit 31 = right child), and clears the arrival counters.
kernel void rtHierarchyKernel(constant uint2&       params     [[buffer(0)]],   // y = index of node 0 in the buffer
                              device const uint*    keys       [[buffer(1)]],
                              device const uint*    values     [[buffer(2)]],
                              device const float4*  leafBoxes  [[buffer(3)]],
                              device BVHNode*       nodes      [[buffer(4)]],   // this tree's nodes (node 0 = root)
                              device uint*          nodeParent [[buffer(5)]],
                              device uint*          leafParent [[buffer(6)]],
                              device atomic_uint*   counters   [[buffer(7)]],
                              constant uint2&       counts     [[buffer(8)]],   // x = n
                              uint gid [[thread_position_in_grid]])
{
    int n = int(counts.x), i = int(gid);
    if (i >= n - 1) return;
    int d = rtDelta(keys, n, i, i + 1) - rtDelta(keys, n, i, i - 1) >= 0 ? 1 : -1;
    int deltaMin = rtDelta(keys, n, i, i - d);
    int lmax = 2;
    while (rtDelta(keys, n, i, i + lmax * d) > deltaMin) lmax *= 2;
    int l = 0;
    for (int t = lmax / 2; t >= 1; t /= 2)
        if (rtDelta(keys, n, i, i + (l + t) * d) > deltaMin) l += t;
    int j = i + l * d;
    int deltaNode = rtDelta(keys, n, i, j);
    int s = 0;
    for (int div = 2; ; div *= 2) {
        int t = (l + div - 1) / div;
        if (rtDelta(keys, n, i, i + (s + t) * d) > deltaNode) s += t;
        if (t <= 1) break;
    }
    int split = i + s * d + min(d, 0);
    int first = min(i, j), last = max(i, j);

    uint left, right;
    if (first == split) {
        left = RT_LEAF | as_type<uint>(leafBoxes[2 * values[split]].w);
        leafParent[split] = uint(i);
    } else {
        left = params.y + uint(split);
        nodeParent[split] = uint(i);
    }
    if (last == split + 1) {
        right = RT_LEAF | as_type<uint>(leafBoxes[2 * values[split + 1]].w);
        leafParent[split + 1] = uint(i) | 0x80000000u;
    } else {
        right = params.y + uint(split + 1);
        nodeParent[split + 1] = uint(i) | 0x80000000u;
    }
    nodes[i].lo0.w = as_type<float>(left);
    nodes[i].lo1.w = as_type<float>(right);
    atomic_store_explicit(&counters[i], 0u, memory_order_relaxed);
}

// Bottom-up boxes: each leaf writes its box into its parent's child slot and walks up; the second thread to reach
// a node (counters) unions its two child slots into the grandparent, so every node is finished exactly once.
kernel void rtFitKernel(constant uint2&                 counts     [[buffer(8)]],   // x = n
                        device const uint*              values     [[buffer(2)]],
                        device const float4*            leafBoxes  [[buffer(3)]],
                        coherent(device) device BVHNode* nodes     [[buffer(4)]],
                        device const uint*              nodeParent [[buffer(5)]],
                        device const uint*              leafParent [[buffer(6)]],
                        device atomic_uint*             counters   [[buffer(7)]],
                        uint gid [[thread_position_in_grid]])
{
    if (gid >= counts.x) return;
    uint leaf = values[gid];
    float3 lo = leafBoxes[2 * leaf].xyz;
    float4 hi = leafBoxes[2 * leaf + 1];   // w = mask bits
    uint link = leafParent[gid];
    while (true) {
        uint p = link & 0x7FFFFFFFu;
        if ((link >> 31) != 0) { nodes[p].lo1.xyz = lo; nodes[p].hi1 = hi; }
        else                   { nodes[p].lo0.xyz = lo; nodes[p].hi0 = hi; }
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device);
        if (atomic_fetch_add_explicit(&counters[p], 1u, memory_order_relaxed) == 0) return;   // the sibling finishes p
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device);
        BVHNode node = nodes[p];
        lo = min(node.lo0.xyz, node.lo1.xyz);
        hi = float4(max(node.hi0.xyz, node.hi1.xyz), as_type<float>(as_type<uint>(node.hi0.w) | as_type<uint>(node.hi1.w)));
        if (p == 0) return;
        link = nodeParent[p];
    }
}

// ---------------------------------------------------------------------------------------------
// Virtual geometry: this frame's cut through every virtual mesh's cluster DAG (VirtualGeometry.swift).
// ---------------------------------------------------------------------------------------------

struct VGCluster {
    float4 selfSphere;     // xyz = centre, w = radius (object space)
    float4 parentSphere;
    float4 lo;             // xyz = bounds min, w = selfError
    float4 hi;             // xyz = bounds max, w = parentError (infinity for roots)
    uint group;            // its page
    uint childGroup;       // the finer group it was made from, ~0 at the finest level
    uint pageOffset;       // bytes into the page
    uint triangles;
};

struct VGInstance {
    uint instance;         // scene instance
    uint clusterBase;      // into the cluster records
    uint clusterCount;
    uint workBase;         // first work item (one per cluster of each virtual instance)
    float4 lo;             // the mesh's bounds (object space), for Morton keys
    float4 hi;
};

struct VGParams {
    float4 camPos;         // xyz, w = pixels per unit of error at distance 1 (traced height / (2 tan(fovY / 2)))
    float  tau;            // allowed projected error, in traced pixels
    uint   workCount;
    uint   instanceCount;
    uint   capacity;       // most selected clusters
    uint   frame;
    uint   requestCapacity;
    uint   nodeBase;       // the cluster tree's first node in the top-level node buffer
    uint   pad;
};

kernel void vgResetKernel(device uint* counters [[buffer(0)]]) {   // selected, requests, overflow
    counters[0] = 0; counters[1] = 0; counters[2] = 0;
}

// Projected error in traced pixels of `error` (object space) over `sphere` (object space) seen from the camera.
inline float vgProjected(float4 sphere, float error, float4x4 m, float scale, float4 camPos) {
    float3 c = (m * float4(sphere.xyz, 1.0f)).xyz;
    float d = length(c - camPos.xyz) - sphere.w * scale;
    return d <= 1e-4f ? INFINITY : error * scale * camPos.w / d;
}

// One thread per (virtual instance, cluster). Nanite's rule (see VGCluster in VirtualGeometryBuilder.swift): drawn
// if resident, its group's coarser version is too coarse, and it is fine enough itself or its finer group isn't
// resident (then that group is requested). Detail follows distance only: off-screen geometry still casts shadows
// and shows in reflections, and every ray type sees the same cut.
kernel void vgCutKernel(constant VGParams&           p           [[buffer(0)]],
                        device const VGInstance*     vinstances  [[buffer(1)]],
                        device const VGCluster*      clusters    [[buffer(2)]],
                        device const uint*           groupPage   [[buffer(3)]],   // per group: pool offset (float4s) or ~0
                        device const InstanceData*   instances   [[buffer(4)]],
                        device atomic_uint*          counters    [[buffer(5)]],
                        device uint2*                selected    [[buffer(6)]],   // (instance, pool offset of the cluster)
                        device float4*               leafBoxes   [[buffer(7)]],
                        device uint2*                requests    [[buffer(8)]],   // (group, priority bits)
                        device atomic_uint*          requestStamp [[buffer(9)]],  // per group: last frame it was requested
                        device uint*                 lastUsed    [[buffer(10)]],  // per group: last frame it was drawn
                        device uint*                 keys        [[buffer(13)]],
                        device uint*                 values      [[buffer(14)]],
                        uint gid [[thread_position_in_grid]])
{
    if (gid >= p.workCount) return;
    uint lo = 0, hi = p.instanceCount - 1;   // the instance whose work range holds gid
    while (lo < hi) {
        uint mid = (lo + hi + 1) / 2;
        if (vinstances[mid].workBase <= gid) lo = mid; else hi = mid - 1;
    }
    VGInstance vi = vinstances[lo];
    uint local = gid - vi.workBase;
    if (local >= vi.clusterCount) return;
    VGCluster c = clusters[vi.clusterBase + local];
    uint page = groupPage[c.group];
    if (page == 0xFFFFFFFFu) return;   // not resident

    InstanceData inst = instances[vi.instance];
    float4x4 m = inst.transform;
    float scale = max(length(m[0].xyz), max(length(m[1].xyz), length(m[2].xyz)));
    if (c.hi.w != INFINITY && vgProjected(c.parentSphere, c.hi.w, m, scale, p.camPos) <= p.tau) return;   // coarser is enough
    if (c.childGroup != 0xFFFFFFFFu) {
        float own = vgProjected(c.selfSphere, c.lo.w, m, scale, p.camPos);
        if (own > p.tau) {
            if (groupPage[c.childGroup] != 0xFFFFFFFFu) return;   // the finer clusters are drawn instead
            if (atomic_exchange_explicit(&requestStamp[c.childGroup], p.frame, memory_order_relaxed) != p.frame) {
                uint r = atomic_fetch_add_explicit(&counters[1], 1u, memory_order_relaxed);
                if (r < p.requestCapacity) requests[r] = uint2(c.childGroup, as_type<uint>(own));
            }
        }
    }
    lastUsed[c.group] = p.frame;
    uint idx = atomic_fetch_add_explicit(&counters[0], 1u, memory_order_relaxed);
    if (idx >= p.capacity) { atomic_store_explicit(&counters[2], 1u, memory_order_relaxed); return; }
    selected[idx] = uint2(vi.instance, page + c.pageOffset / 16);
    // Object-space box (vgFitKernel moves it to world space above the instance's subtree), and a key that sorts by
    // virtual instance first (8 bits), then along a Morton curve inside the mesh's bounds (22 bits).
    leafBoxes[2 * idx]     = float4(c.lo.xyz, as_type<float>(RT_CLUSTER | idx));
    leafBoxes[2 * idx + 1] = float4(c.hi.xyz, as_type<float>(inst.pad0));
    float3 q = clamp(((c.lo.xyz + c.hi.xyz) * 0.5f - vi.lo.xyz) / max(vi.hi.xyz - vi.lo.xyz, float3(1e-6f)), 0.0f, 1.0f) * 1023.0f;
    uint3 qi = uint3(q);
    uint morton = (rtExpandBits(qi.x) << 2) | (rtExpandBits(qi.y) << 1) | rtExpandBits(qi.z);
    keys[idx] = (min(lo, 255u) << 22) | (morton >> 8);
    values[idx] = idx;
}

// After the cut: the leaf count and sort size for the cluster tree's build, and its root ref.
kernel void vgFinishKernel(constant VGParams&  p        [[buffer(0)]],
                           device const uint*  counters [[buffer(5)]],
                           device uint2*       counts   [[buffer(11)]],   // x = leaves, y = padded sort size
                           device uint*        roots    [[buffer(12)]])
{
    uint n = min(counters[0], p.capacity);
    uint padded = 2;
    while (padded < n) padded <<= 1;
    counts[0] = uint2(n, padded);
    if (n < 2) roots[0] = n == 0 ? RT_NONE : (RT_LEAF | RT_CLUSTER);   // 2+: vgHierarchyKernel writes it
}

// Fills the sort input past the leaf count with keys that sort last.
kernel void vgPadKernel(device const uint2* counts [[buffer(11)]],
                        device uint*        keys   [[buffer(13)]],
                        device uint*        values [[buffer(14)]],
                        uint gid [[thread_position_in_grid]])
{
    uint2 c = counts[0];
    if (gid < c.x || gid >= c.y) return;
    keys[gid] = 0xFFFFFFFFu;
    values[gid] = gid;
}

inline bool vgSameInstance(device const uint* keys, int a, int b) { return (keys[a] >> 22) == (keys[b] >> 22); }

// The cluster tree's hierarchy (Karras, as rtHierarchyKernel). Keys start with the virtual instance, so the tree
// splits by instance first; a node whose leaves all share one instance is that instance's (part of the) subtree:
// nodeInstance records it, and the ref to it from a node spanning several instances carries RT_ENTER.
kernel void vgHierarchyKernel(constant uint2&       params       [[buffer(0)]],   // y = index of node 0 in the buffer
                              device const uint*    keys         [[buffer(1)]],
                              device const uint*    values       [[buffer(2)]],
                              device const float4*  leafBoxes    [[buffer(3)]],
                              device BVHNode*       nodes        [[buffer(4)]],
                              device uint*          nodeParent   [[buffer(5)]],
                              device uint*          leafParent   [[buffer(6)]],
                              device atomic_uint*   counters     [[buffer(7)]],
                              constant uint2&       counts       [[buffer(8)]],
                              device const uint2*   selected     [[buffer(9)]],
                              device uint*          nodeInstance [[buffer(10)]],
                              device uint*          roots        [[buffer(12)]],
                              uint gid [[thread_position_in_grid]])
{
    int n = int(counts.x), i = int(gid);
    if (i >= n - 1) return;
    int d = rtDelta(keys, n, i, i + 1) - rtDelta(keys, n, i, i - 1) >= 0 ? 1 : -1;
    int deltaMin = rtDelta(keys, n, i, i - d);
    int lmax = 2;
    while (rtDelta(keys, n, i, i + lmax * d) > deltaMin) lmax *= 2;
    int l = 0;
    for (int t = lmax / 2; t >= 1; t /= 2)
        if (rtDelta(keys, n, i, i + (l + t) * d) > deltaMin) l += t;
    int j = i + l * d;
    int deltaNode = rtDelta(keys, n, i, j);
    int s = 0;
    for (int div = 2; ; div *= 2) {
        int t = (l + div - 1) / div;
        if (rtDelta(keys, n, i, i + (s + t) * d) > deltaNode) s += t;
        if (t <= 1) break;
    }
    int split = i + s * d + min(d, 0);
    int first = min(i, j), last = max(i, j);
    bool mine = vgSameInstance(keys, first, last);
    nodeInstance[i] = mine ? selected[values[first]].x : 0xFFFFFFFFu;
    if (i == 0) roots[0] = params.y | (mine ? RT_ENTER : 0u);

    uint left, right;
    if (first == split) {
        left = RT_LEAF | as_type<uint>(leafBoxes[2 * values[split]].w);
        leafParent[split] = uint(i);
    } else {
        left = params.y + uint(split) | (!mine && vgSameInstance(keys, first, split) ? RT_ENTER : 0u);
        nodeParent[split] = uint(i);
    }
    if (last == split + 1) {
        right = RT_LEAF | as_type<uint>(leafBoxes[2 * values[split + 1]].w);
        leafParent[split + 1] = uint(i) | 0x80000000u;
    } else {
        right = params.y + uint(split + 1) | (!mine && vgSameInstance(keys, split + 1, last) ? RT_ENTER : 0u);
        nodeParent[split + 1] = uint(i) | 0x80000000u;
    }
    nodes[i].lo0.w = as_type<float>(left);
    nodes[i].lo1.w = as_type<float>(right);
    atomic_store_explicit(&counters[i], 0u, memory_order_relaxed);
}

inline void vgToWorld(thread float3& lo, thread float3& hi, float4x4 m) {
    float3 c = (lo + hi) * 0.5f, e = (hi - lo) * 0.5f;
    float3 wc = (m * float4(c, 1.0f)).xyz;
    float3 we = abs(m[0].xyz) * e.x + abs(m[1].xyz) * e.y + abs(m[2].xyz) * e.z;
    lo = wc - we;
    hi = wc + we;
}

// Bottom-up boxes for the cluster tree (as rtFitKernel): boxes stay in their instance's object space up to the node
// where the subtree meets other instances, and are moved to world space there.
kernel void vgFitKernel(constant uint2&                  counts       [[buffer(8)]],
                        device const uint*               values       [[buffer(2)]],
                        device const float4*             leafBoxes    [[buffer(3)]],
                        coherent(device) device BVHNode* nodes        [[buffer(4)]],
                        device const uint*               nodeParent   [[buffer(5)]],
                        device const uint*               leafParent   [[buffer(6)]],
                        device atomic_uint*              counters     [[buffer(7)]],
                        device const uint2*              selected     [[buffer(9)]],
                        device const uint*               nodeInstance [[buffer(10)]],
                        device const InstanceData*       instances    [[buffer(15)]],
                        uint gid [[thread_position_in_grid]])
{
    uint n = counts.x;
    if (gid >= n) return;
    uint leaf = values[gid];
    float3 lo = leafBoxes[2 * leaf].xyz;
    float4 hi = leafBoxes[2 * leaf + 1];   // w = mask bits
    uint inst = selected[leaf].x;          // the box is in this instance's object space (~0: world space)
    if (n == 1) return;
    uint link = leafParent[gid];
    while (true) {
        uint p = link & 0x7FFFFFFFu;
        if (inst != 0xFFFFFFFFu && nodeInstance[p] == 0xFFFFFFFFu) {   // the parent spans several instances
            float3 h3 = hi.xyz;
            vgToWorld(lo, h3, instances[inst].transform);
            hi.xyz = h3;
        }
        if ((link >> 31) != 0) { nodes[p].lo1.xyz = lo; nodes[p].hi1 = hi; }
        else                   { nodes[p].lo0.xyz = lo; nodes[p].hi0 = hi; }
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device);
        if (atomic_fetch_add_explicit(&counters[p], 1u, memory_order_relaxed) == 0) return;
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device);
        BVHNode node = nodes[p];
        lo = min(node.lo0.xyz, node.lo1.xyz);
        hi = float4(max(node.hi0.xyz, node.hi1.xyz), as_type<float>(as_type<uint>(node.hi0.w) | as_type<uint>(node.hi1.w)));
        inst = nodeInstance[p];
        if (p == 0) return;
        link = nodeParent[p];
    }
}

#endif


