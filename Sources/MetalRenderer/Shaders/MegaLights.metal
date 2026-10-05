// ---------------------------------------------------------------------------------------------
// 1g. MegaLights-style direct light (after Unreal Engine 5.5's MegaLights): direct light from every light at a cost set
//     by the samples per pixel and how many lights reach a tile, not by the light count. Per frame:
//       megaLightsCullKernel    one threadgroup per 16x16-pixel tile: the tile's depth range, then every light whose
//                               reach (megaLightReach: where its unshadowed light falls below the cutoff) touches the
//                               tile's frustum slice, sorted by index, into the tile's list (`capacity` at most).
//       megaLightsSampleKernel  per pixel, light samples with one shadow ray each: some picked from the tile's list in
//                               proportion to their unshadowed luminance here (lights the tile saw lit last frame weigh
//                               1, the others `guide weight`), the others drawn from the light tree (LightTree.swift:
//                               the far field, which the lists leave out), and each sun once. The two strategies are
//                               combined with the balance heuristic (multi-sample MIS), and the tree reaches every
//                               light: the cutoff, a full list or the guiding change the noise, never the expected
//                               light. Writes diffuse light (albedo divided out) to `direct` and specular light for the
//                               reflection pass, as ReSTIR's last pass does, and marks the lights it found visible in
//                               the tile's hash for the next frame.
//     SVGF then denoises the direct light as radiance.
// ---------------------------------------------------------------------------------------------

struct MegaLightsParams {
    uint4  config;   // x = list samples per pixel, y = list capacity (a power of two), z = ML_* flags, w = tiles across
    uint4  tree;     // x = tree samples per pixel, y = light tree nodes (the lights' paths follow them in its buffer)
    float4 tuning;   // x = cutoff (unshadowed light where a light's reach ends), y = guide weight, z = firefly clamp (0 = off)
};

constant uint ML_GUIDE_VALID = 1;   // last frame's visible-light hashes are there to steer the picks
constant uint ML_PARTITION = 2;     // the list owns its lights in reach and the tree the others (else MIS between them)
constant uint ML_TILE = 16;
constant uint ML_MAX_CAPACITY = 256;
constant uint ML_MAX_SAMPLES = 8;   // list or tree samples per pixel

// A tile's list in the lists buffer: [count, lights that reached it (may exceed the capacity), sorted light indices].
inline uint megaLightsTileStride(uint capacity) { return capacity + 2u; }

// How far a light's unshadowed diffuse light (lightUnshadowed, albedo divided out) stays above `cutoff`, from `center`:
// its intensity / (pi d^2), plus the light's own size. False for the suns, which reach everywhere. Spots are bounded
// by their sphere (the cone only dims them), rects (one-sided) by theirs too.
inline bool megaLightReach(Light light, float cutoff, thread float3& center, thread float& reach) {
    uint type = lightType(light);
    if (type == LIGHT_SUN) return false;
    center = light.positionRadius.xyz;
    float intensity = luminance(light.color.rgb), size = light.positionRadius.w;
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

// Is light l in the tile's sorted list?
inline bool megaLightsListed(device const ushort* list, uint count, uint l) {
    uint lo = 0, hi = count;
    while (lo < hi) {
        uint mid = (lo + hi) / 2;
        if (uint(list[mid]) < l) lo = mid + 1; else hi = mid;
    }
    return lo < count && uint(list[lo]) == l;
}

// The lights the list strategy owns at a pixel (ML_PARTITION): its tile's listed lights that reach it. The tree then
// never draws them (its leaves weigh them 0), so each light comes from one strategy and neither needs the other's pdf.
struct MegaLightsOwned {
    device const ushort* list;
    uint  count;
    float cutoff;
    bool  active;
};
inline bool megaLightsOwns(MegaLightsOwned o, uint l, float3 p, device const Light* lights) {
    if (!o.active || !megaLightsListed(o.list, o.count, l)) return false;
    float3 c;
    float r;
    return megaLightReach(lights[l], o.cutoff, c, r) && distance_squared(p, c) < r * r;
}

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

// ---------------------------------------------------------------------------------------------
// The light tree (LightTree.swift): a bounding hierarchy over every light but the suns. A light is drawn by walking
// down from the root, at each node in proportion to its children's weights at the pixel; its probability is the
// product of those choices, which lightTreePdf computes back along the light's path.
// ---------------------------------------------------------------------------------------------

struct LightTreeNode {
    float4 lo;     // xyz = bounds min, w = power (intensity luminance)
    float4 hi;     // xyz = bounds max, w = cos θo, the cone's spread (-1: every direction)
    float4 axis;   // xyz = the cone's axis, w = cos θe: how far past θo the lights still emit
    uint4  link;   // x = left child or LIGHT_TREE_LEAF | light index, y = right child, z = parent
};
constant uint LIGHT_TREE_LEAF = 1u << 31;

// cos(max(0, a - b)) from the sines and cosines of a and b.
inline float cosSubClamped(float sinA, float cosA, float sinB, float cosB) { return cosA > cosB ? 1.0f : cosA * cosB + sinA * sinB; }
inline float sinSubClamped(float sinA, float cosA, float sinB, float cosB) { return cosA > cosB ? 0.0f : sinA * cosB - cosA * sinB; }

// A node's importance at p with normal n (Conty Estevez & Kulla 2018, PBRT-v4's LightBounds::Importance, one-sided):
// a bound on its lights' unshadowed light, in lightUnshadowed's units: power / (pi d^2) x the cosine at the lights'
// cone and at the receiver, both widened by the box's angular size.
inline float lightTreeImportance(LightTreeNode node, float3 p, float3 n) {
    float power = node.lo.w;
    if (power <= 0.0f) return 0.0f;
    float3 lo = node.lo.xyz, hi = node.hi.xyz, pc = 0.5f * (lo + hi);
    float r2 = 0.25f * distance_squared(lo, hi);
    float3 w = p - pc;
    float d2 = dot(w, w);
    float sinB = 0.0f, cosB = -1.0f;   // the box's angular radius from p (inside it: every direction)
    if (d2 > r2 && !(all(p >= lo) && all(p <= hi))) { sinB = sqrt(r2 / d2); cosB = sqrt(max(1.0f - r2 / d2, 0.0f)); }
    float3 wn = w * rsqrt(max(d2, 1e-12f));
    float cosO = node.hi.w, sinO = sqrt(max(1.0f - cosO * cosO, 0.0f));
    float cosW = dot(node.axis.xyz, wn), sinW = sqrt(max(1.0f - cosW * cosW, 0.0f));
    float cosX = cosSubClamped(sinW, cosW, sinO, cosO), sinX = sinSubClamped(sinW, cosW, sinO, cosO);
    float cosP = cosSubClamped(sinX, cosX, sinB, cosB);
    if (cosP <= node.axis.w) return 0.0f;
    float cosI = -dot(n, wn), sinI = sqrt(max(1.0f - cosI * cosI, 0.0f));
    float cosIp = cosSubClamped(sinI, cosI, sinB, cosB);
    if (cosIp <= 0.0f) return 0.0f;
    return power * cosP * cosIp / (M_PI_F * max(d2, r2));
}

// A child's weight: a leaf's light's exact unshadowed diffuse light (the mesh lights' proxy; 0 if the list owns it),
// else its bound.
inline float lightTreeWeight(device const LightTreeNode* tree, uint i, thread const ShadingPoint& sp, device const Light* lights,
                             MegaLightsOwned owned) {
    LightTreeNode node = tree[i];
    if ((node.link.x & LIGHT_TREE_LEAF) != 0) {
        uint l = node.link.x & ~LIGHT_TREE_LEAF;
        return megaLightsOwns(owned, l, sp.p, lights) ? 0.0f : luminance(lightUnshadowed(lights[l], sp.p, sp.n, sp.ng));
    }
    return lightTreeImportance(node, sp.p, sp.n);
}

// A light drawn from the tree with one random number (rescaled at every choice), and its probability (0: none).
inline uint sampleLightTree(device const LightTreeNode* tree, uint nodes, float u, thread const ShadingPoint& sp,
                            device const Light* lights, MegaLightsOwned owned, thread float& pdf) {
    pdf = 0.0f;
    if (nodes == 0) return ELEMENT_NONE;
    uint i = 0;
    float p = 1.0f;
    for (uint depth = 0; depth < 33; ++depth) {
        uint2 link = tree[i].link.xy;
        if ((link.x & LIGHT_TREE_LEAF) != 0) {
            uint l = link.x & ~LIGHT_TREE_LEAF;
            if (depth == 0 && megaLightsOwns(owned, l, sp.p, lights)) return ELEMENT_NONE;   // one light, the list's
            pdf = p;
            return l;
        }
        float wl = lightTreeWeight(tree, link.x, sp, lights, owned), wr = lightTreeWeight(tree, link.y, sp, lights, owned);
        if (!(wl + wr > 0.0f)) return ELEMENT_NONE;
        float pl = wl / (wl + wr);
        if (u < pl) { u = min(u / pl, 0.99999f); p *= pl; i = link.x; }
        else { u = min((u - pl) / (1.0f - pl), 0.99999f); p *= 1.0f - pl; i = link.y; }
    }
    return ELEMENT_NONE;
}

// The probability that sampleLightTree draws light l at the pixel.
inline float lightTreePdf(device const LightTreeNode* tree, uint nodes, uint l, thread const ShadingPoint& sp,
                          device const Light* lights, MegaLightsOwned owned) {
    if (nodes == 0) return 0.0f;
    uint2 path = ((device const uint2*)(tree + nodes))[l];
    if (path.y > 32) return 0.0f;   // not in the tree (the suns)
    uint i = 0;
    float p = 1.0f;
    for (uint depth = 0; depth < path.y; ++depth) {
        uint2 link = tree[i].link.xy;
        float wl = lightTreeWeight(tree, link.x, sp, lights, owned), wr = lightTreeWeight(tree, link.y, sp, lights, owned);
        if (!(wl + wr > 0.0f)) return 0.0f;
        bool right = ((path.x >> depth) & 1u) != 0;
        p *= (right ? wr : wl) / (wl + wr);
        i = right ? link.y : link.x;
    }
    return p;
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
    // Bitonic sort, ascending (the padding last), so a pixel can tell whether a light is listed (megaLightsListed).
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

// The list strategy's weight for light l at the pixel: its unshadowed luminance (the mesh lights' proxy), 0 beyond its
// reach, scaled down if the tile didn't see it lit last frame.
inline float megaLightWeight(uint l, thread const ShadingPoint& sp, thread const SceneData& s, device const Light* lights,
                             device const TriangleInfo* tris, float cutoff, bool guided, uint4 seen, float guideWeight) {
    float3 c;
    float r;
    if (!megaLightReach(lights[l], cutoff, c, r) || distance_squared(sp.p, c) >= r * r) return 0.0f;
    float w = lightSampleTarget(evalLightSample(l, float2(0.5f), sp, s, lights, tris, false, false), sp);
    return guided && !megaLightsSeen(seen, l) ? w * guideWeight : w;
}

// A mesh light's triangle t's probability within the light (the step of its CDF).
inline float meshTriangleProb(Light light, uint t, thread const SceneData& s) {
    uint first = as_type<uint>(light.params.x);
    return s.emissive[t].v0.w - (t > first ? s.emissive[t - 1].v0.w : 0.0f);
}
// One of a mesh light's triangles by its power (binary search of the CDF): false if it has none.
inline bool pickMeshTriangle(Light light, float u, thread const SceneData& s, thread uint& t, thread float& prob) {
    uint first = as_type<uint>(light.params.x), count = as_type<uint>(light.params.y);
    if (count == 0) return false;
    uint lo = 0, hi = count - 1;
    while (lo < hi) {
        uint mid = (lo + hi) / 2;
        if (s.emissive[first + mid].v0.w > u) hi = mid; else lo = mid + 1;
    }
    t = first + lo;
    prob = meshTriangleProb(light, t, s);
    return prob > 0.0f;
}

// What the pixel adds up: diffuse and specular light, and the lights it found visible (for the tile's hash).
struct MegaLightsShade {
    float3 diffuse;
    float3 specular;
    uint4  visible;
};

// One light sample, divided by its MIS-combined density `pdf` (0: nothing): one shadow ray, if it brings any light.
inline void megaLightsShade(uint element, float2 uv, float pdf, uint light, thread const ShadingPoint& sp,
                            thread const SceneData& s, device const Light* lights, device const TriangleInfo* tris,
                            SCENE_ACCEL accel, uint flags, thread MegaLightsShade& out) {
    if (!(pdf > 0.0f)) return;
    LightSampleEval e = evalLightSample(element, uv, sp, s, lights, tris, false, true);
    if (all(e.diffuse <= 0.0f) && all(e.specular <= 0.0f)) return;
    float b;
    uint li = element & ELEMENT_INDEX;
    if ((element & ELEMENT_TYPE) != ELEMENT_TRIANGLE ? !shadowVisible(flags, s.vsm, li, lights[li], sp.p, sp.ng, e.target, accel, b)
                                                      : !isVisible(sp.p, e.target, accel)) return;
    float inv = 1.0f / pdf;
    out.diffuse += e.diffuse * inv;
    out.specular += e.specular * inv;
    out.visible = megaLightsMark(out.visible, light);
}

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
                                   uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    bool specular = flagOn(u.flags, FLAG_SPECULAR);
    ShadingPoint sp;
    float depth;
    if (!restirSurface(tid, u, surfacePos, normalDepth, geoNormal, albedo, material, sp, depth)) {
        outDirect.write(float4(0.0f), tid);
        if (specular) outSpecular.write(float4(0.0f), tid);
        return;
    }
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    device const TriangleInfo* tris = lightTableTriangles(lights, u.lightCount, u.lightTable.x);
    Rng rng;
    rng.state = pixelSeed(tid, u.frameIndex, SEED_MEGALIGHTS);

    uint t = (tid.y / ML_TILE) * mp.config.w + tid.x / ML_TILE;
    uint capacity = min(mp.config.y, ML_MAX_CAPACITY);
    device const ushort* list = tileLists + t * megaLightsTileStride(capacity);
    uint count = list[0];
    list += 2;
    bool guided = passOn(mp.config.z, ML_GUIDE_VALID);
    uint4 seen = guided ? prevGuide[t] : uint4(0u);
    float cutoff = mp.tuning.x, guideWeight = mp.tuning.y;
    uint nodes = mp.tree.y;
    uint lanes = nodes > 0 ? min(mp.config.x, ML_MAX_SAMPLES) : 0u;

    // The list samples: `lanes` independent picks in one pass (streaming weighted reservoirs, one random number each).
    float lu[ML_MAX_SAMPLES], lw[ML_MAX_SAMPLES];
    uint lp[ML_MAX_SAMPLES];
    for (uint k = 0; k < ML_MAX_SAMPLES; ++k) { lu[k] = min(rng.next(), 0.99999f); lw[k] = 0.0f; lp[k] = 0u; }
    float total = 0.0f;
    for (uint j = 0; lanes > 0 && j < count; ++j) {
        uint l = list[j];
        float w = megaLightWeight(l, sp, s, lights, tris, cutoff, guided, seen, guideWeight);
        if (w <= 0.0f) continue;
        total += w;
        float q = w / total;
        for (uint k = 0; k < ML_MAX_SAMPLES; ++k) {
            if (k >= lanes) break;
            if (lu[k] < q) { lp[k] = l; lw[k] = w; lu[k] /= q; }
            else lu[k] = (lu[k] - q) / (1.0f - q);
        }
    }

    // Each sample's estimate is f / (n_list p_list + n_tree p_tree) (the balance heuristic over both strategies), or with
    // ML_PARTITION f / (n p) of the one strategy that owns its light. A pixel no listed light reaches draws its list
    // samples from the tree too.
    bool partition = passOn(mp.config.z, ML_PARTITION);
    MegaLightsOwned owned = { list, count, cutoff, partition && lanes > 0 }, none = owned;
    none.active = false;
    float nList = total > 0.0f ? float(lanes) : 0.0f;
    uint treeSamples = nodes > 0 ? min(mp.tree.x + (total > 0.0f ? 0u : lanes), ML_MAX_SAMPLES) : 0u;
    float nTree = float(treeSamples);
    MegaLightsShade shade;
    shade.diffuse = shade.specular = float3(0.0f);
    shade.visible = uint4(0u);
    for (uint k = 0; k < ML_MAX_SAMPLES; ++k) {
        if (k >= lanes || total <= 0.0f) break;
        uint l = lp[k], element = l;
        float prob = 1.0f;
        float2 uv = rng.next2();
        float uTri = rng.next();
        Light light = lights[l];
        if (lightType(light) == LIGHT_MESH) {
            uint tri;
            if (!pickMeshTriangle(light, uTri, s, tri, prob)) continue;
            element = ELEMENT_TRIANGLE | tri;
        }
        float pTree = nTree > 0.0f && !partition ? lightTreePdf(tree, nodes, l, sp, lights, none) : 0.0f;
        megaLightsShade(element, uv, (nList * (lw[k] / total) + nTree * pTree) * prob, l, sp, s, lights, tris, accel, u.flags, shade);
    }
    for (uint k = 0; k < ML_MAX_SAMPLES; ++k) {
        // The tree samples, and their probability under the list strategy (0 if the light isn't listed or out of reach).
        if (k >= treeSamples) break;
        float pTree;
        uint l = sampleLightTree(tree, nodes, rng.next(), sp, lights, owned, pTree);
        float2 uv = rng.next2();
        float uTri = rng.next();
        if (l == ELEMENT_NONE) continue;
        uint element = l;
        float prob = 1.0f;
        Light light = lights[l];
        if (lightType(light) == LIGHT_MESH) {
            uint tri;
            if (!pickMeshTriangle(light, uTri, s, tri, prob)) continue;
            element = ELEMENT_TRIANGLE | tri;
        }
        float pList = 0.0f;
        if (nList > 0.0f && !partition && megaLightsListed(list, count, l))
            pList = megaLightWeight(l, sp, s, lights, tris, cutoff, guided, seen, guideWeight) / total;
        megaLightsShade(element, uv, (nList * pList + nTree * pTree) * prob, l, sp, s, lights, tris, accel, u.flags, shade);
    }
    for (uint k = 0; k < u.lightTable.y; ++k) {   // each sun once
        uint l = k == 0 ? u.lightTable.z : u.lightTable.w;
        megaLightsShade(ELEMENT_SUN | l, rng.next2(), 1.0f, l, sp, s, lights, tris, accel, u.flags, shade);
    }

    // The lights found visible, into the tile's hash: one atomic per word and SIMD-group (a threadgroup lies in one tile).
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
}
