// ---------------------------------------------------------------------------------------------
// MegaLights-style direct light (after Unreal Engine 5.5's MegaLights; DirectLightMode.megalights): direct light from
// every light at a cost set by the samples per pixel and how many lights reach a tile, not by the light count. Per
// frame:
//   megaLightsCullKernel    one threadgroup per 16x16-pixel tile: the tile's depth range, then every light whose reach
//                           (megaLightReach: where its unshadowed light falls below the cutoff) touches the tile's
//                           frustum slice, sorted by index, into the tile's list (`capacity` at most).
//   megaLightsSampleKernel  per pixel, light samples with one shadow ray each: some picked from the tile's list in
//                           proportion to their unshadowed luminance here (lights the tile saw lit last frame weigh 1,
//                           the others `guide weight`), the others drawn from the light tree (LightTree.metal: the far
//                           field, which the lists leave out), and each sun once. With ML_PARTITION the list owns its
//                           lights in reach and the tree the rest; otherwise the balance heuristic combines them. The
//                           tree reaches every light either way: the cutoff, a full list or the guiding change the
//                           noise, never the expected light. Writes diffuse light (albedo divided out) to `direct` and
//                           specular light for the reflection pass, as sampledLightsKernel does, and marks the lights it
//                           found visible in the tile's hash for the next frame.
// The frame then treats it as sampled direct light: SVGF or MetalFX's denoiser on `direct`.
// ---------------------------------------------------------------------------------------------

struct MegaLightsParams {
    uint4  config;   // x = list samples per pixel, y = list capacity (a power of two), z = ML_* flags, w = tiles across
    uint4  tree;     // x = tree samples per pixel, y = light tree nodes (the lights' paths follow them in its buffer)
    float4 tuning;   // x = cutoff (unshadowed light where a light's reach ends), y = guide weight, z = firefly clamp (0 = off)
};
static_assert(sizeof(MegaLightsParams) == 48, "MegaLightsParams: GPUMegaLightsParams");

constant uint ML_GUIDE_VALID = 1;   // GPUMegaLightsParams.guideValid: last frame's visible-light hashes steer the picks
constant uint ML_PARTITION = 2;     // GPUMegaLightsParams.partition: the list owns its lights in reach, the tree the rest
constant uint ML_TILE = 16;
constant uint ML_MAX_CAPACITY = 256;
constant uint ML_MAX_SAMPLES = 8;   // list or tree samples per pixel

// A tile's list in the lists buffer: [count, lights that reached it (may exceed the capacity), sorted light indices].
inline uint megaLightsTileStride(uint capacity) { return capacity + 2u; }

// How far a light's unshadowed diffuse light (lightUnshadowed, albedo divided out) stays above `cutoff`, from `center`:
// its intensity / (pi d^2), plus the light's own size. False for the suns, which reach everywhere. Spots are bounded
// by their sphere (the cone only dims them), rects (one-sided) by theirs too.
// `intensity` (luminance) and `size` (the bounding sphere's radius about `center`) are what the list's weight uses.
inline bool megaLightReach(Light light, float cutoff, thread float3& center, thread float& reach, thread float& intensity,
                           thread float& size) {
    uint type = lightType(light);
    if (type == LIGHT_SUN) return false;
    center = light.positionRadius.xyz;
    intensity = luminance(light.color.rgb);
    size = light.positionRadius.w;
    if (type == LIGHT_RECT) {
        // Radiance x area: params.xyz is the half-width vector, params.w the half height.
        float hw = length(light.params.xyz), hh = light.params.w;
        intensity *= 4.0f * hw * hh;
        size = sqrt(hw * hw + hh * hh);
    } else if (type == LIGHT_TUBE) {
        intensity *= 4.0f / M_PI_F;   // broadside, as lightUnshadowed's tube
        size += length(light.axis.xyz);
    } else if (type == LIGHT_MESH) {
        float flat = light.params.z;
        intensity *= (1.0f - flat) * 0.25f + flat;   // meshLightUnshadowed's proxy at its brightest
    }
    reach = size + sqrt(max(intensity, 0.0f) / (M_PI_F * max(cutoff, 1e-12f)));
    return true;
}
inline bool megaLightReach(Light light, float cutoff, thread float3& center, thread float& reach) {
    float intensity, size;
    return megaLightReach(light, cutoff, center, reach, intensity, size);
}

// The tile's lights, as the sample kernel holds them in threadgroup memory (one threadgroup a tile): its sorted list,
// where each listed light's reach ends (xyz centre, w = reach squared: megaLightReach), its bound (x = intensity x the
// guide's weight: 1, or `guide weight` if the tile didn't see it lit last frame; y = its size; zw = a spot's cos outer
// and inner) and its shape (xyz = a spot's axis or a rect's normal, w = ML_SHAPE_*).
struct MegaLightsTile {
    threadgroup const ushort* list;
    threadgroup const float4* reach;
    threadgroup const float4* bound;
    threadgroup const float4* shape;
    uint count;

    // Where light l is in the list, or `count` if it isn't listed.
    uint find(uint l) const {
        uint lo = 0, hi = count;
        while (lo < hi) {
            uint mid = (lo + hi) / 2;
            if (uint(list[mid]) < l) lo = mid + 1; else hi = mid;
        }
        return lo < count && uint(list[lo]) == l ? lo : count;
    }
    bool reaches(uint j, float3 p) const { return distance_squared(p, reach[j].xyz) < reach[j].w; }
};

// The lights the list strategy owns at a pixel (ML_PARTITION): its tile's listed lights that reach it. The tree then
// never draws them (the light tree's Owner: their leaves weigh 0), so each light comes from one strategy and neither
// needs the other's pdf.
struct MegaLightsOwned {
    MegaLightsTile tile;
    bool active;
    bool exactLeaves() const { return false; }   // the leaves' bounds: an exact rect or tube there cost as much as a list
    bool owns(uint l, float3 p, device const Light*) const {
        if (!active) return false;
        uint j = tile.find(l);
        return j < tile.count && tile.reaches(j, p);
    }
};

// The visible-light hash: 128 bits per tile, light l's bit at pcgHash(l) mod 128.
inline uint megaLightsHashBit(uint l) { return pcgHash(l) & 127u; }
inline bool megaLightsSeen(uint4 seen, uint l) {
    uint b = megaLightsHashBit(l);
    return (groupElement(seen, b >> 5) & (1u << (b & 31u))) != 0;
}
inline uint4 megaLightsMark(uint4 mask, uint l) {
    uint b = megaLightsHashBit(l);
    return mask | select(uint4(0u), uint4(1u << (b & 31u)), uint4(b >> 5) == uint4(0u, 1u, 2u, 3u));
}

// The side planes of a tile's frustum (through the camera, normals inward), from its corners' view directions.
inline float3 inwardPlane(float3 a, float3 b, float3 inside) {
    float3 n = normalize(cross(a, b));
    return dot(n, inside) < 0.0f ? -n : n;
}

[[max_total_threads_per_threadgroup(256)]]   // the 16x16 group is the tile
kernel void megaLightsCullKernel(constant Uniforms&               u          [[buffer(0)]],
                                 device const Light*              lights     [[buffer(8)]],
                                 constant MegaLightsParams&       mp         [[buffer(9)]],
                                 device ushort*                   tileLists  [[buffer(10)]],
                                 device atomic_uint*              guide      [[buffer(13)]],   // this frame's hashes: cleared
                                 texture2d<float, access::read>   surfacePos [[texture(0)]],
                                 texture2d<float, access::read>   normalDepth [[texture(1)]],
                                 uint2 tid  [[thread_position_in_grid]],
                                 uint2 tile [[threadgroup_position_in_grid]],
                                 uint  lid  [[thread_index_in_threadgroup]])
{
    threadgroup atomic_uint depthMin, depthMax, reached;
    threadgroup ushort list[ML_MAX_CAPACITY];
    uint capacity = min(mp.config.y, ML_MAX_CAPACITY);
    uint t = tile.y * mp.config.w + tile.x;
    if (lid == 0) {
        atomic_store_explicit(&depthMin, 0x7F7FFFFFu, memory_order_relaxed);   // FLT_MAX (positive floats order as uints)
        atomic_store_explicit(&depthMax, 0u, memory_order_relaxed);
        atomic_store_explicit(&reached, 0u, memory_order_relaxed);
    }
    if (lid < 4) atomic_store_explicit(&guide[t * 4 + lid], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid.x < u.width && tid.y < u.height && surfacePos.read(tid).w > 0.0f) {
        float d = normalDepth.read(tid).w;
        if (d > 0.0f) {
            atomic_fetch_min_explicit(&depthMin, as_type<uint>(d), memory_order_relaxed);
            atomic_fetch_max_explicit(&depthMax, as_type<uint>(d), memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float zMin = as_type<float>(atomic_load_explicit(&depthMin, memory_order_relaxed));
    float zMax = as_type<float>(atomic_load_explicit(&depthMax, memory_order_relaxed));

    // The tile's frustum, a pixel wider on each side (the primary rays' jitter, the surface offset).
    float2 size = float2(u.width, u.height);
    float2 lo = (float2(tile * ML_TILE) - 1.0f) / size, hi = (float2(tile * ML_TILE + ML_TILE) + 1.0f) / size;
    float3 d00 = viewDirection(u, lo), d10 = viewDirection(u, float2(hi.x, lo.y));
    float3 d01 = viewDirection(u, float2(lo.x, hi.y)), d11 = viewDirection(u, hi);
    float3 dc = viewDirection(u, 0.5f * (lo + hi));
    float3 p0 = inwardPlane(d00, d10, dc), p1 = inwardPlane(d10, d11, dc), p2 = inwardPlane(d11, d01, dc), p3 = inwardPlane(d01, d00, dc);
    float cutoff = mp.tuning.x;
    for (uint i = lid; zMin <= zMax && i < u.lightCount; i += ML_TILE * ML_TILE) {
        float3 c;
        float r;
        if (!megaLightReach(lights[i], cutoff, c, r)) continue;
        float3 v = c - u.camPos.xyz;
        float z = dot(v, u.camForward.xyz);
        if (z + r < zMin || z - r > zMax) continue;
        if (dot(p0, v) < -r || dot(p1, v) < -r || dot(p2, v) < -r || dot(p3, v) < -r) continue;
        uint k = atomic_fetch_add_explicit(&reached, 1u, memory_order_relaxed);
        if (k < capacity) list[k] = ushort(i);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint lit = atomic_load_explicit(&reached, memory_order_relaxed), n = min(lit, capacity);
    for (uint i = lid; i < capacity; i += ML_TILE * ML_TILE) if (i >= n) list[i] = 0xFFFF;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // Bitonic sort, ascending (the padding last), so a pixel can find a light in it (MegaLightsTile.find).
    for (uint k = 2; k <= capacity; k <<= 1) {
        for (uint j = k >> 1; j > 0; j >>= 1) {
            for (uint i = lid; i < capacity; i += ML_TILE * ML_TILE) {
                uint ixj = i ^ j;
                if (ixj <= i) continue;
                ushort a = list[i], b = list[ixj];
                if ((a > b) == ((i & k) == 0)) { list[i] = b; list[ixj] = a; }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    }
    device ushort* out = tileLists + t * megaLightsTileStride(capacity);
    if (lid == 0) { out[0] = ushort(n); out[1] = ushort(min(lit, 0xFFFFu)); }
    for (uint i = lid; i < n; i += ML_TILE * ML_TILE) out[2 + i] = list[i];
}

constant float ML_SHAPE_NONE = 0.0f, ML_SHAPE_RECT = 1.0f, ML_SHAPE_SPOT = 2.0f;

// The list strategy's weight for the tile's j-th light at the pixel: a cheap stand-in for its unshadowed light there, a
// light of its intensity at its centre, seen over its bounding sphere: intensity x the cosine widened by the sphere's
// angular size / (pi d^2), x a spot's cone (exactly as lightUnshadowed's), 0 behind a rect (as its own) and its emitting
// cosine in front. It is above 0 wherever the light's own is (no part of the sphere above the surface: none of the light
// either; hair, leaves and skin take light from behind too), so with the same weight in the pdf the estimate stays
// unbiased; it costs a few flops where the exact light (rect and tube integrals, GGX) cost the pass most of its time.
inline float megaLightWeight(MegaLightsTile tile, uint j, thread const ShadingPoint& sp) {
    float4 r = tile.reach[j];
    float3 w = r.xyz - sp.p;
    float d2 = dot(w, w);
    if (d2 >= r.w) return 0.0f;
    float4 b = tile.bound[j], shape = tile.shape[j];
    float emit = 1.0f;
    if (shape.w != ML_SHAPE_NONE) {
        float c = -dot(w, shape.xyz) * rsqrt(max(d2, 1e-12f));   // from the light toward p, along its axis
        if (shape.w == ML_SHAPE_SPOT) emit = smoothstep(b.z, b.w, c);
        else if (c <= 0.0f) return 0.0f;                          // behind the rect: none of its light
        else emit = max(c, 0.05f);                                // (near its plane, its far corners still face p)
        if (emit <= 0.0f) return 0.0f;
    }
    float cosW = 1.0f;
    if (!sp.hair.on && !(sp.hair.leaf > 0.0f) && !(sp.hair.skin > 0.0f) && d2 > b.y * b.y) {
        float invD = rsqrt(d2), sinA = b.y * invD;
        cosW = (dot(sp.n, w) * invD + sinA) / (1.0f + sinA);
        if (cosW <= 0.0f) return 0.0f;
    }
    return b.x * emit * cosW / (M_PI_F * max(d2, b.y * b.y));
}

// One of a mesh light's triangles by its power (binary search of its CDF, as sampleMeshLightPoint's): false if it has
// none. `t` indexes the emissive triangles (ELEMENT_TRIANGLE's index), `prob` is its probability within the light.
inline bool pickMeshTriangle(Light light, float u, thread const SceneData& s, thread uint& t, thread float& prob) {
    uint first = as_type<uint>(light.params.x), count = as_type<uint>(light.params.y);
    if (count == 0) return false;
    uint lo = 0, hi = count - 1;
    while (lo < hi) {
        uint mid = (lo + hi) / 2;
        if (s.emissive[first + mid].v0.w > u) hi = mid; else lo = mid + 1;
    }
    t = first + lo;
    prob = s.emissive[t].v0.w - (lo > 0 ? s.emissive[t - 1].v0.w : 0.0f);
    return prob > 0.0f;
}

// What the pixel adds up: diffuse and specular light, and the lights it found visible (for the tile's hash).
struct MegaLightsShade {
    float3 diffuse;
    float3 specular;
    uint4  visible;
};

// One light sample, divided by its (MIS-combined) density `pdf` (0: nothing): one shadow ray, if it brings any light,
// tinted by the glass on its way (glassShadowTint), the emitters' points within the cascades' reach left to them
// (FLAG_CASCADE_EMITTERS). True if the ray got through.
inline bool megaLightsShade(uint element, float2 uv, float pdf, uint light, thread const ShadingPoint& sp,
                            thread const SceneData& s, device const Light* lights, device const TriangleInfo* tris,
                            SCENE_ACCEL accel, uint flags, thread MegaLightsShade& out) {
    if (!(pdf > 0.0f)) return false;
    LightSampleEval e = evalLightSample(element, uv, sp, s, lights, tris, false, true, flagOn(flags, FLAG_CASCADE_EMITTERS));
    if (all(e.diffuse <= 0.0f) && all(e.specular <= 0.0f)) return false;
    float3 origin = shadowOrigin(sp, e.target);
    if (!isVisible(origin, e.target, accel)) return false;
    float3 w = glassShadowTint(origin, e.target, accel, s, flags) / pdf;
    out.diffuse += e.diffuse * w;
    out.specular += e.specular * w;
    out.visible = megaLightsMark(out.visible, light);
    return true;
}

// A light drawn by either strategy as the element to shade: a mesh light's triangle by power (its probability in
// `prob`), else the light itself. False: a mesh light with no triangle to light.
inline bool megaLightsElement(uint l, float uTri, thread const SceneData& s, device const Light* lights,
                              thread uint& element, thread float& prob) {
    element = l;
    prob = 1.0f;
    Light light = lights[l];
    if (lightType(light) != LIGHT_MESH) return true;
    uint tri;
    if (!pickMeshTriangle(light, uTri, s, tri, prob)) return false;
    element = ELEMENT_TRIANGLE | tri;
    return true;
}

[[max_total_threads_per_threadgroup(256)]]   // the 16x16 group is the tile
kernel void megaLightsSampleKernel(constant Uniforms&               u          [[buffer(0)]],
                                   SCENE_ACCEL                      accel      [[buffer(1)]],
                                   device const InstanceData*       instances  [[buffer(6)]],
                                   constant SceneShading&           shading    [[buffer(7)]],
                                   device const Light*              lights     [[buffer(8)]],   // + the light table
                                   constant MegaLightsParams&       mp         [[buffer(9)]],
                                   device const ushort*             tileLists  [[buffer(10)]],
                                   device atomic_uint*              guide      [[buffer(13)]],  // this frame's hashes
                                   device const uint4*              prevGuide  [[buffer(14)]],  // last frame's
                                   device const LightTreeNode*      tree       [[buffer(15)]],  // + the lights' paths
                                   texture2d<float, access::read>   surfacePos [[texture(0)]],
                                   texture2d<float, access::read>   normalDepth [[texture(1)]],
                                   texture2d<float, access::read>   geoNormal  [[texture(2)]],
                                   texture2d<float, access::read>   albedo     [[texture(3)]],
                                   texture2d<float, access::read>   material   [[texture(4)]],
                                   texture2d<float, access::write>  outDirect  [[texture(5)]],
                                   texture2d<float, access::write>  outSpecular [[texture(6)]],  // with FLAG_SPECULAR
                                   texture2d<float, access::write>  outSunVisibility [[texture(7)]],  // with FLAG_SUN_VISIBILITY
                                   texture2d<float, access::read>   anisotropyTex [[texture(8)]],  // MATERIAL_LOBES: the highlight's tangent, how much
                                   texture2d<float, access::read>   sheenTex   [[texture(9)]],     // ...and a cloth's sheen
                                   texture2d<float, access::write>  outLightDebug [[texture(10)]], // FLAG_LIGHT_DEBUG: the light debug views
                                   uint2 tid  [[thread_position_in_grid]],
                                   uint2 tile [[threadgroup_position_in_grid]],
                                   uint  lid  [[thread_index_in_threadgroup]])
{
    // The tile's lights into threadgroup memory, once for its 256 pixels: their reaches and bounds.
    threadgroup ushort tList[ML_MAX_CAPACITY];
    threadgroup float4 tReach[ML_MAX_CAPACITY];
    threadgroup float4 tBound[ML_MAX_CAPACITY];
    threadgroup float4 tShape[ML_MAX_CAPACITY];
    uint t = tile.y * mp.config.w + tile.x;
    uint capacity = min(mp.config.y, ML_MAX_CAPACITY);
    device const ushort* list = tileLists + t * megaLightsTileStride(capacity);
    uint count = min(uint(list[0]), capacity);
    bool guided = passOn(mp.config.z, ML_GUIDE_VALID);
    uint4 seen = guided ? prevGuide[t] : uint4(0u);
    float cutoff = mp.tuning.x, guideWeight = mp.tuning.y;
    for (uint j = lid; j < count; j += ML_TILE * ML_TILE) {
        uint l = list[2 + j];
        float3 c = float3(0.0f);
        float r = 0.0f, intensity = 0.0f, size = 0.0f;
        Light light = lights[l];
        bool reaches = megaLightReach(light, cutoff, c, r, intensity, size);
        uint type = lightType(light);
        tList[j] = ushort(l);
        tReach[j] = float4(c, reaches ? r * r : -1.0f);
        tBound[j] = float4(intensity * (guided && !megaLightsSeen(seen, l) ? guideWeight : 1.0f), size,
                           type == LIGHT_SPOT ? light.params.xy : float2(0.0f));
        tShape[j] = float4(light.axis.xyz, type == LIGHT_SPOT ? ML_SHAPE_SPOT : type == LIGHT_RECT ? ML_SHAPE_RECT : ML_SHAPE_NONE);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    MegaLightsTile cached = { tList, tReach, tBound, tShape, count };

    if (tid.x >= u.width || tid.y >= u.height) return;   // (after the barrier: every thread loads)
    bool specular = flagOn(u.flags, FLAG_SPECULAR);
    float4 pos = surfacePos.read(tid);
    if (pos.w <= 0.0f) {   // sky or an emitter: nothing to light
        outDirect.write(float4(0.0f), tid);
        if (specular) outSpecular.write(float4(0.0f), tid);
        if (flagOn(u.flags, FLAG_SUN_VISIBILITY)) outSunVisibility.write(float4(1.0f), tid);
        if (flagOn(u.flags, FLAG_LIGHT_DEBUG))   // nothing: black tiles, no pick
            outLightDebug.write(u.viewMode == VIEW_LIGHT_TILES ? float4(0.0f) : debugPackId(ELEMENT_NONE), tid);
        return;
    }
    // The surface, as sampledLightsKernel reads it.
    ShadingPoint sp;
    sp.n = normalDepth.read(tid).xyz;
    float4 g = geoNormal.read(tid);
    sp.ng = g.xyz;
    sp.p = pos.xyz + sp.ng * RAY_EPSILON;
    sp.v = normalize(u.camPos.xyz - pos.xyz);
    float4 a = albedo.read(tid);
    sp.albedo = max(a.rgb, float3(0.05f));
    sp.hair = hairFromGBuffer(a, g.w, sp.n, sp.v);
    sp.f0 = float3(0.0f);
    sp.roughness = 1.0f;
    sp.specular = false;
    if (specular) {
        float4 m = material.read(tid);
        sp.f0 = m.rgb; sp.roughness = m.a; sp.specular = any(m.rgb > 0.0f);
    }
    readShadingLobes(sp, anisotropyTex, sheenTex, tid);
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    device const TriangleInfo* tris = lightTableTriangles(lights, u.lightCount, u.lightTable.x);
    Rng rng;
    rng.state = pixelSeed(tid, u.frameIndex, SEED_MEGALIGHTS);
    uint nodes = mp.tree.y;
    uint lanes = nodes > 0 ? min(mp.config.x, ML_MAX_SAMPLES) : 0u;

    // The list samples: `lanes` independent picks in one pass (streaming weighted reservoirs, one random number each).
    float lu[ML_MAX_SAMPLES], lw[ML_MAX_SAMPLES];
    uint lp[ML_MAX_SAMPLES];
    for (uint k = 0; k < ML_MAX_SAMPLES; ++k) { lu[k] = min(rng.next(), 0.99999f); lw[k] = 0.0f; lp[k] = 0u; }
    float total = 0.0f;
    for (uint j = 0; lanes > 0 && j < count; ++j) {
        float w = megaLightWeight(cached, j, sp);
        if (w <= 0.0f) continue;
        total += w;
        float q = w / total;
        for (uint k = 0; k < ML_MAX_SAMPLES; ++k) {
            if (k >= lanes) break;
            if (lu[k] < q) { lp[k] = j; lw[k] = w; lu[k] /= q; }
            else lu[k] = (lu[k] - q) / (1.0f - q);
        }
    }

    // Each sample's estimate is f / (n_list p_list + n_tree p_tree) (the balance heuristic over both strategies), or with
    // ML_PARTITION f / (n p) of the one strategy that owns its light. A pixel no listed light reaches draws its list
    // samples from the tree too.
    bool partition = passOn(mp.config.z, ML_PARTITION);
    MegaLightsOwned owned = { cached, partition && lanes > 0 };
    float nList = total > 0.0f ? float(lanes) : 0.0f;
    uint treeSamples = nodes > 0 ? min(mp.tree.x + (total > 0.0f ? 0u : lanes), ML_MAX_SAMPLES) : 0u;
    float nTree = float(treeSamples);
    MegaLightsShade shade;
    shade.diffuse = shade.specular = float3(0.0f);
    shade.visible = uint4(0u);
    uint debugPick = ELEMENT_NONE;   // the picked-light view: the first sample's light (list, else tree)
    for (uint k = 0; k < ML_MAX_SAMPLES; ++k) {
        if (k >= lanes || total <= 0.0f) break;
        uint l = tList[lp[k]], element;
        float prob;
        float2 uv = rng.next2();
        float uTri = rng.next();
        if (!megaLightsElement(l, uTri, s, lights, element, prob)) continue;
        if (debugPick == ELEMENT_NONE) debugPick = l;
        float pTree = nTree > 0.0f && !partition ? lightTreePdf(tree, nodes, l, sp, lights, false, owned) : 0.0f;   // (owned is inactive: the leaves alike)
        megaLightsShade(element, uv, (nList * (lw[k] / total) + nTree * pTree) * prob, l, sp, s, lights, tris, accel, u.flags, shade);
    }
    for (uint k = 0; k < ML_MAX_SAMPLES; ++k) {
        // The tree samples, and their probability under the list strategy (0 if the light isn't listed or out of reach).
        if (k >= treeSamples) break;
        float pTree;
        uint l = sampleLightTree(tree, nodes, rng.next(), sp, lights, pTree, false, owned);
        float2 uv = rng.next2();
        float uTri = rng.next();
        uint element;
        float prob;
        if (l == ELEMENT_NONE || !megaLightsElement(l, uTri, s, lights, element, prob)) continue;
        if (debugPick == ELEMENT_NONE) debugPick = l;
        float pList = 0.0f;
        if (nList > 0.0f && !partition) {
            uint j = cached.find(l);
            if (j < count) pList = megaLightWeight(cached, j, sp) / total;
        }
        megaLightsShade(element, uv, (nList * pList + nTree * pTree) * prob, l, sp, s, lights, tris, accel, u.flags, shade);
    }
    // Each sun once. Under MetalFX their luminance-weighted visibility (with the clouds' shadow) goes to its diffuse
    // guide (FLAG_SUN_VISIBILITY, sunShadowGuide): 1 where no sun lights the pixel.
    bool sunGuide = flagOn(u.flags, FLAG_SUN_VISIBILITY);
    float sunLit = 0.0f, sunSeen = 0.0f;
    for (uint k = 0; k < u.lightTable.y; ++k) {
        uint l = k == 0 ? u.lightTable.z : u.lightTable.w;
        bool seen = megaLightsShade(ELEMENT_SUN | l, rng.next2(), 1.0f, l, sp, s, lights, tris, accel, u.flags, shade);
        if (sunGuide) {
            float w = luminance(litUnshadowed(lights[l], sp.p, sp.n, sp.ng, sp.hair));
            sunLit += w;
            if (seen) sunSeen += w * sunVisibilityScale(lights[l], sp.p, s);
        }
    }
    if (sunGuide) outSunVisibility.write(float4(sunLit > 0.0f ? sunSeen / sunLit : 1.0f), tid);

    // The lights found visible, into the tile's hash: one atomic per word and SIMD-group.
    uint4 visible = simd_or(shade.visible);
    if (simd_is_first()) {
        for (uint w = 0; w < 4; ++w) {
            uint bits = groupElement(visible, w);
            if (bits != 0) atomic_fetch_or_explicit(&guide[t * 4 + w], bits, memory_order_relaxed);
        }
    }
    float clampScale = fireflyScale(luminance(shade.diffuse) + luminance(shade.specular), mp.tuning.z);
    outDirect.write(roundToHalf(float4(shade.diffuse * clampScale, 1.0f)), tid);
    if (specular) outSpecular.write(roundToHalf(float4(shade.specular * clampScale, 1.0f)), tid);
    if (flagOn(u.flags, FLAG_LIGHT_DEBUG)) {
        // Light tiles: the lights that reached the tile against the list's capacity (g = 1: more than it holds).
        uint reached = uint(list[1]);
        if (u.viewMode == VIEW_LIGHT_TILES) outLightDebug.write(float4(saturate(float(reached) / float(capacity)), reached > capacity ? 1.0f : 0.0f, 0.0f, 1.0f), tid);
        else outLightDebug.write(debugPackId(debugPick), tid);
    }
}
