// =============================================================================================
// Lumen's distance fields (LumenScene.swift, MeshSDFBuilder.swift): each mesh's field in its own space, as 8³ bricks
// of r8Snorm samples (distance / (band x voxel)) in one 3D atlas, found through the mesh's brick table (or empty:
// all outside, all inside). Rays near a probe sphere-trace the fields of the instances around its tile.
// =============================================================================================

struct LumenMeshSDF {
    float4 lo;       // bricks: xyz = the volume's first sample (mesh space), w = voxel; heights: x, z = the first
                     // sample, w = the cell
    uint4  bricks;   // bricks: xyz = bricks per axis, w = its first entry in the brick table; heights: x = samples a
                     // side (x = 0: not baked)
    float4 info;     // x = 1 if two-sided, y = its coarse grid's or heights' first value (a uint's bits), z = 1 for
                     // heights (a flat mesh: terrain, a ground, a quad), w = their slope factor
    float4 plant;    // x = a plant's leaf share (its colour mixes its wood's and its leaves'), -1: not a plant
};

struct LumenSDFInstance {
    float4 lo;       // world box, w = the instance's smallest scale
    float4 hi;       // world box, w = its mesh's field (a uint's bits)
    uint   id;       // the instance's id
    uint3  pad;
};

constant uint  LUMEN_SDF_ATLAS_BRICKS = 32;
constant uint  LUMEN_SDF_OUTSIDE = 0xffffffffu, LUMEN_SDF_INSIDE = 0xfffffffeu;
constant float LUMEN_SDF_BAND = 4.0f;
constant uint  LUMEN_SDF_COARSE = 16;    // MeshSDF.coarseSide
constant uint  LUMEN_TILE_PROBES = 4;    // a culling tile is 4x4 probes
constant uint  LUMEN_TILE_LIST = 64;     // its list: a count, then up to 63 instances

// The field at `po` (mesh space, in its units): trilinear in the bricks, and where they saturate (past the band) the
// coarse grid's unclamped distance less half its cell's diagonal; outside the volume, from its edge: √(outside² +
// edge²), the surface being inside. A lower bound of the distance past the band, which is what a sphere tracer needs.
inline float lumenMeshDistance(LumenMeshSDF m, device const uint* bricks, device const float* coarse, texture3d<float> atlas,
                               float3 po) {
    if (m.info.z > 0.5f) {
        // Heights: the height above the surface (solid below) x the slope factor; off the grid, from its edge.
        uint side = m.bricks.x;
        float2 lo = float2(m.lo.x, m.lo.z), hi = lo + float(side - 1u) * m.lo.w;
        float2 q = clamp(po.xz, lo, hi);
        float2 g = (q - lo) / m.lo.w;
        uint2 i = min(uint2(g), uint2(side - 2u));
        float2 f = g - float2(i);
        device const float* h = coarse + as_type<uint>(m.info.y) + i.y * side + i.x;
        float height = mix(mix(h[0], h[1], f.x), mix(h[side], h[side + 1u], f.x), f.y);
        float d = (po.y - height) * m.info.w;
        float outside = length(po.xz - q);
        return outside > 0.0f ? sqrt(outside * outside + max(d, 0.0f) * max(d, 0.0f)) : d;
    }
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    float voxel = m.lo.w;
    float3 cells = float3(m.bricks.xyz * 7u);
    float3 g = (po - m.lo.xyz) / voxel;
    float3 gc = clamp(g, float3(0.0f), cells);
    float outside = length(g - gc) * voxel;
    uint3 b = min(uint3(gc / 7.0f), m.bricks.xyz - 1u);
    float3 local = gc - float3(b * 7u);
    uint entry = bricks[m.bricks.w + (b.z * m.bricks.y + b.y) * m.bricks.x + b.x];
    float band = LUMEN_SDF_BAND * voxel, d;
    if (entry == LUMEN_SDF_OUTSIDE) d = band;
    else if (entry == LUMEN_SDF_INSIDE) d = -band;
    else {
        uint3 slot = uint3(entry % LUMEN_SDF_ATLAS_BRICKS, (entry / LUMEN_SDF_ATLAS_BRICKS) % LUMEN_SDF_ATLAS_BRICKS,
                           entry / (LUMEN_SDF_ATLAS_BRICKS * LUMEN_SDF_ATLAS_BRICKS));
        float3 size = float3(atlas.get_width(), atlas.get_height(), atlas.get_depth());
        d = atlas.sample(bilinear, (float3(slot * 8u) + local + 0.5f) / size).r * band;
    }
    if (d >= 0.99f * band) {
        const float n = float(LUMEN_SDF_COARSE - 1u);
        float3 c = gc / cells * n;
        uint3 i = min(uint3(c), uint3(LUMEN_SDF_COARSE - 2u));
        float3 f = c - float3(i);
        device const float* grid = coarse + as_type<uint>(m.info.y);
        float dc = 0.0f;
        for (uint k = 0; k < 8u; ++k) {
            uint3 o = uint3(k & 1u, (k >> 1) & 1u, k >> 2);
            float w = (o.x ? f.x : 1.0f - f.x) * (o.y ? f.y : 1.0f - f.y) * (o.z ? f.z : 1.0f - f.z);
            uint3 q = i + o;
            dc += w * grid[(q.z * LUMEN_SDF_COARSE + q.y) * LUMEN_SDF_COARSE + q.x];
        }
        d = max(d, dc - 0.5f * length(cells * voxel) / n);
    }
    return outside > 0.0f ? sqrt(outside * outside + max(d, 0.0f) * max(d, 0.0f)) : d;
}

inline float3 lumenMeshGradient(LumenMeshSDF m, device const uint* bricks, device const float* coarse, texture3d<float> atlas,
                                 float3 po) {
    float h = 0.5f * m.lo.w;
    return float3(lumenMeshDistance(m, bricks, coarse, atlas, po + float3(h, 0, 0)) - lumenMeshDistance(m, bricks, coarse, atlas, po - float3(h, 0, 0)),
                  lumenMeshDistance(m, bricks, coarse, atlas, po + float3(0, h, 0)) - lumenMeshDistance(m, bricks, coarse, atlas, po - float3(0, h, 0)),
                  lumenMeshDistance(m, bricks, coarse, atlas, po + float3(0, 0, h)) - lumenMeshDistance(m, bricks, coarse, atlas, po - float3(0, 0, h)));
}

struct LumenSDFHit {
    bool   hit;
    float  t;
    uint   id;        // the instance's id
    float3 position;  // world
    float3 normal;    // world, from the field's gradient
    float3 local;     // mesh space (for last frame's position)
};

// The nearest hit of the ray o + t d, t in [tMin, tMax], on the fields of `count` instances (`list[candidates[k]]`, or
// list[k] without candidates). Each is sphere-traced in its mesh's space, stepping by the field x the instance's
// smallest scale. On instance `self` (the probe's own: the ray starts on it) a hit needs the ray to have been off the
// surface first, so it doesn't stop at once where it starts.
inline LumenSDFHit lumenTraceMeshSDFs(float3 o, float3 d, float tMin, float tMax, uint self, device const LumenSDFInstance* list,
                                      device const uint* candidates, uint count, device const InstanceData* instances,
                                      device const LumenMeshSDF* meshes, device const uint* bricks, device const float* coarse,
                                      texture3d<float> atlas) {
    LumenSDFHit best;
    best.hit = false; best.t = tMax; best.id = 0; best.position = best.normal = best.local = float3(0.0f);
    float3 inv = 1.0f / d;
    LumenMeshSDF bestMesh;
    bestMesh.lo = bestMesh.info = float4(0.0f);
    bestMesh.bricks = uint4(0u);
    float3 bestO = float3(0.0f), bestD = float3(0.0f);
    float4x4 bestNormalMatrix = float4x4(1.0f);
    for (uint k = 0; k < count; ++k) {
        LumenSDFInstance si = list[candidates != nullptr ? candidates[k] : k];
        float3 t0 = (si.lo.xyz - o) * inv, t1 = (si.hi.xyz - o) * inv;
        float enter = max(max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z)), tMin);
        float exit = min(min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z)), best.t);
        if (enter >= exit) continue;
        InstanceData inst = instanceRecord(instances, si.id);
        LumenMeshSDF m = meshes[as_type<uint>(si.hi.w)];
        float3 oo = (float4(o, 1.0f) * inst.normalMatrix).xyz, dd = (float4(d, 0.0f) * inst.normalMatrix).xyz;
        float scale = si.lo.w, voxel = (m.info.z > 0.5f ? min(m.lo.w, 0.1f / scale) : m.lo.w) * scale;   // heights: fine hits
        float threshold = 0.25f * voxel;
        float t = enter;
        bool off = si.id != self;
        for (int step = 0; step < 64 && t < exit; ++step) {
            float dist = lumenMeshDistance(m, bricks, coarse, atlas, oo + dd * t) * scale;
            if (off && dist < threshold) {
                // Onto the surface: two more steps by the field (backward where it is negative).
                for (int r = 0; r < 2; ++r) t = clamp(t + lumenMeshDistance(m, bricks, coarse, atlas, oo + dd * t) * scale, enter, exit);
                best.hit = true;
                best.t = t;
                best.id = si.id;
                bestMesh = m; bestO = oo; bestD = dd; bestNormalMatrix = inst.normalMatrix;
                best.position = o + d * t;
                break;
            }
            if (dist > 2.0f * threshold) off = true;
            t += max(dist, threshold);
        }
    }
    if (best.hit) {
        best.local = bestO + bestD * best.t;
        float3 g = lumenMeshGradient(bestMesh, bricks, coarse, atlas, best.local);
        float3 n = normalize((bestNormalMatrix * float4(g, 0.0f)).xyz);
        best.normal = all(isfinite(n)) ? n : -d;
        if (dot(best.normal, d) > 0.0f && bestMesh.info.x > 0.0f) best.normal = -best.normal;   // two-sided: face the ray
    }
    return best;
}

// ---------------------------------------------------------------------------------------------
// The global distance field (LumenGlobalSDF.swift): levels of 128³ cells around the camera, toroidal, one above the
// other in z. A cell holds the nearest mesh field's distance (up to the level's band) and that instance (its owner).
// ---------------------------------------------------------------------------------------------

struct LumenClipLevel {
    int4   origin;   // xyz = the window's first cell (this level's voxels, from the world's origin)
    float4 voxel;    // x = voxel (m), y = band (m)
};

constant int  LUMEN_CLIP = 128;
constant uint LUMEN_BIN = 128;           // a dirty brick's instances: a count, then up to 127

inline uint3 lumenClipTexel(int3 cell, uint level) {
    int3 w = ((cell % LUMEN_CLIP) + LUMEN_CLIP) % LUMEN_CLIP;
    return uint3(uint(w.x), uint(w.y), uint(w.z) + level * uint(LUMEN_CLIP));
}

// Whether a level's window has p, with its neighbours for the trilinear filter.
inline bool lumenClipContains(LumenClipLevel lv, float3 p) {
    float3 g = p / lv.voxel.x - 0.5f - float3(lv.origin.xyz);
    return all(g >= 1.0f) && all(g < float(LUMEN_CLIP) - 2.0f);
}

// Trilinear between cell centres, by hand: the window wraps around the texture.
inline float lumenClipDistance(texture3d<float, access::read> field, LumenClipLevel lv, uint level, float3 p) {
    float3 g = p / lv.voxel.x - 0.5f;
    int3 i = int3(floor(g));
    float3 f = g - float3(i);
    float d = 0.0f;
    for (int k = 0; k < 8; ++k) {
        int3 o = int3(k & 1, (k >> 1) & 1, k >> 2);
        float w = (o.x ? f.x : 1.0f - f.x) * (o.y ? f.y : 1.0f - f.y) * (o.z ? f.z : 1.0f - f.z);
        d += w * field.read(lumenClipTexel(i + o, level)).r;
    }
    return d;
}

struct LumenGlobalHit {
    bool   hit;
    float  t;
    uint   owner;      // the instance nearest the hit (~0: none)
    float3 position;
    float3 normal;
};

// Sphere-traces o + t d from tMin through the clipmap: each step in the finest level that has the point, or a coarser
// one where that one only knows "at least its band". A hit is within half the level's voxel of a surface; the ray
// ends at tMax or where the coarsest window does (the sky).
inline LumenGlobalHit lumenTraceGlobalSDF(float3 o, float3 d, float tMin, float tMax, device const LumenClipLevel* levels,
                                          uint levelCount, texture3d<float, access::read> field,
                                          texture3d<uint, access::read> owners) {
    LumenGlobalHit h;
    h.hit = false; h.t = tMax; h.owner = ~0u; h.position = h.normal = float3(0.0f);
    float t = tMin;
    for (int step = 0; step < 128 && t < tMax; ++step) {
        float3 p = o + d * t;
        uint l = 0;
        while (l < levelCount && !lumenClipContains(levels[l], p)) ++l;
        if (l == levelCount) break;
        float dist = lumenClipDistance(field, levels[l], l, p);
        while (dist >= 0.95f * levels[l].voxel.y && l + 1 < levelCount && lumenClipContains(levels[l + 1], p)) {
            ++l;
            dist = max(dist, lumenClipDistance(field, levels[l], l, p));
        }
        float voxel = levels[l].voxel.x;
        if (dist < 0.5f * voxel) {
            h.hit = true;
            h.t = t;
            h.position = p;
            h.owner = owners.read(lumenClipTexel(int3(floor(p / voxel)), l)).r;
            float e = voxel;
            float3 g = float3(lumenClipDistance(field, levels[l], l, p + float3(e, 0, 0)) - lumenClipDistance(field, levels[l], l, p - float3(e, 0, 0)),
                              lumenClipDistance(field, levels[l], l, p + float3(0, e, 0)) - lumenClipDistance(field, levels[l], l, p - float3(0, e, 0)),
                              lumenClipDistance(field, levels[l], l, p + float3(0, 0, e)) - lumenClipDistance(field, levels[l], l, p - float3(0, 0, e)));
            h.normal = length_squared(g) > 1e-12f ? normalize(g) : -d;
            return h;
        }
        t += max(dist, 0.1f * voxel);
    }
    return h;
}

// A material's colour without a point on it (a field's hit has no texture coordinates): its base colour times its
// texture's mean (the 1x1 mip).
inline float3 lumenMaterialAlbedo(device const Material* materials, device const MaterialTexture* textures, uint index) {
    Material m = materials[index];
    float3 c = m.albedo.rgb;
    if (m.textures.x != ~0u) {
        texture2d<float> t = textures[m.textures.x].t;
        c *= t.read(uint2(0), t.get_num_mip_levels() - 1u).rgb;
    }
    return c;
}

// The colour of a hit on field `m` of an instance whose material is `index`: the material's (with its texture's mean),
// or a plant's wood (`index`) and leaves (`index + 1`) mixed by its leaf share, as a far plant's voxels mix them.
inline float3 lumenFieldAlbedo(LumenMeshSDF m, device const Material* materials, device const MaterialTexture* textures,
                               uint index) {
    if (m.plant.x < 0.0f) return lumenMaterialAlbedo(materials, textures, index);
    return mix(lumenMaterialAlbedo(materials, textures, index), lumenMaterialAlbedo(materials, textures, index + 1u), m.plant.x);
}

// A global hit as a surface: on its owner's own surface (the clipmap's is up to half its voxel off: two steps down the
// owner's mesh field), with the owner's colour, so the cards and the light see the point where it is. Without an
// owner: grey, where the trace stopped.
inline Surface lumenGlobalSurface(LumenGlobalHit gh, device const InstanceData* instances, device const Material* materials,
                                  device const MaterialTexture* textures, device const LumenMeshSDF* meshes, device const uint* bricks, device const float* coarse,
                                  texture3d<float> atlas) {
    Surface h;
    h.hit = true;
    h.position = h.prevPosition = gh.position;
    h.normal = h.geomNormal = gh.normal;
    h.albedo = float3(0.5f);
    h.instanceId = gh.owner;
    h.emission = h.f0 = float3(0.0f);
    h.metallic = h.specular = 0.0f;
    h.roughness = 1.0f;
    h.lightEmitter = h.backlit = false;
    if (gh.owner == ~0u) return h;
    InstanceData inst = instanceRecord(instances, gh.owner);
    LumenMeshSDF m = meshes[inst.meshIndex];
    h.albedo = lumenFieldAlbedo(m, materials, textures, inst.materialIndex);
    float3 local = (float4(gh.position, 1.0f) * inst.normalMatrix).xyz;
    if (m.bricks.x > 0) {
        float3 g = float3(0.0f);
        for (int k = 0; k < 2; ++k) {
            g = lumenMeshGradient(m, bricks, coarse, atlas, local);
            if (length_squared(g) < 1e-12f) break;
            g = normalize(g);
            local -= g * lumenMeshDistance(m, bricks, coarse, atlas, local);
        }
        if (length_squared(g) > 0.5f) {
            h.position = (inst.transform * float4(local, 1.0f)).xyz;
            h.normal = h.geomNormal = normalize((inst.normalMatrix * float4(g, 0.0f)).xyz);
        }
    }
    h.prevPosition = (inst.prevTransform * float4(local, 1.0f)).xyz;
    return h;
}

// Per dirty brick (a threadgroup of 64): the fields' instances whose box, grown by the level's band, touches it.
kernel void lumenGlobalBinKernel(device const int4*               dirty      [[buffer(20)]],
                                 constant uint&                   dirtyCount [[buffer(21)]],
                                 device const LumenClipLevel*     levels     [[buffer(22)]],
                                 device const LumenSDFInstance*   list       [[buffer(17)]],
                                 constant uint&                   listCount  [[buffer(23)]],
                                 device uint*                     bins       [[buffer(24)]],
                                 uint tg   [[threadgroup_position_in_grid]],
                                 uint lane [[thread_index_in_threadgroup]])
{
    threadgroup atomic_uint found;
    if (tg >= dirtyCount) return;
    int4 b = dirty[tg];
    LumenClipLevel lv = levels[b.w];
    float size = 8.0f * lv.voxel.x;
    float3 lo = float3(b.xyz) * size - lv.voxel.y, hi = float3(b.xyz + 1) * size + lv.voxel.y;
    if (lane == 0) atomic_store_explicit(&found, 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = lane; i < listCount; i += 64u) {
        LumenSDFInstance si = list[i];
        if (any(si.lo.xyz > hi) || any(si.hi.xyz < lo)) continue;
        uint slot = atomic_fetch_add_explicit(&found, 1u, memory_order_relaxed);
        if (slot < LUMEN_BIN - 1u) bins[tg * LUMEN_BIN + 1u + slot] = i;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane == 0) bins[tg * LUMEN_BIN] = min(atomic_load_explicit(&found, memory_order_relaxed), LUMEN_BIN - 1u);
}

// Per cell of the dirty bricks: the nearest of its brick's instances' fields, and which one that is.
kernel void lumenGlobalComposeKernel(device const int4*               dirty      [[buffer(20)]],
                                     constant uint&                   dirtyCount [[buffer(21)]],
                                     device const LumenClipLevel*     levels     [[buffer(22)]],
                                     device const LumenSDFInstance*   list       [[buffer(17)]],
                                     device const uint*               bins       [[buffer(24)]],
                                     device const InstanceData*       instances  [[buffer(6)]],
                                     device const LumenMeshSDF*       meshes     [[buffer(15)]],
                                     device const uint*               bricks     [[buffer(16)]],
                                     device const float*              coarse     [[buffer(25)]],
                                     texture3d<float>                 atlas      [[texture(0)]],
                                     texture3d<float, access::write>  field      [[texture(1)]],
                                     texture3d<uint, access::write>   owners     [[texture(2)]],
                                     uint gid [[thread_position_in_grid]])
{
    uint bi = gid / 512u, k = gid % 512u;
    if (bi >= dirtyCount) return;
    int4 b = dirty[bi];
    LumenClipLevel lv = levels[b.w];
    int3 cell = b.xyz * 8 + int3(k % 8u, (k / 8u) % 8u, k / 64u);
    float3 p = (float3(cell) + 0.5f) * lv.voxel.x;
    float best = lv.voxel.y;
    uint who = ~0u;
    uint n = bins[bi * LUMEN_BIN];
    for (uint j = 0; j < n; ++j) {
        LumenSDFInstance si = list[bins[bi * LUMEN_BIN + 1u + j]];
        InstanceData inst = instanceRecord(instances, si.id);
        float3 po = (float4(p, 1.0f) * inst.normalMatrix).xyz;
        float d = lumenMeshDistance(meshes[as_type<uint>(si.hi.w)], bricks, coarse, atlas, po) * si.lo.w;
        if (d < best) { best = d; who = si.id; }
    }
    uint3 texel = lumenClipTexel(cell, uint(b.w));
    field.write(float4(best), texel);
    owners.write(uint4(who), texel);
}
