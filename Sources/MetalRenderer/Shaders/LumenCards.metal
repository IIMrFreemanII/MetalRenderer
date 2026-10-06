// =============================================================================================
// Lumen's surface cache (LumenCards.swift): cards on the six faces of each instance's box, in the instance's own
// space, in one atlas. A card texel is captured once by a ray from the face into the box that keeps the first
// front-facing hit on the card's own instance (others in the way are passed through), so it holds that surface's
// albedo, normal, depth and emission. Every frame the cards on the lighting list get their direct light (as GI
// rays' hits get theirs), their indirect light (radiosity: rays from the cards whose hits read the cards, so the
// bounces add up from frame to frame), and `final` = albedo x (direct + indirect) + emission, which GI rays read
// where they hit an instance: from the faces its normal looks toward, where the card's depth agrees with the hit's.
// =============================================================================================

struct LumenCard {
    uint4  atlas;   // xy = the card's first texel in the atlas, z = its side (texels), w = face | instance << 3
    float4 lo;      // the instance's box, in its own space
    float4 hi;
};

constant uint LUMEN_NO_CARD = 0xffffffffu;

// A point of the card at `uv` (0...1 across the face's two other axes) and `depth` (0...1 of the box, from the face
// inward), in the instance's space. Faces: 0 +x, 1 -x, 2 +y, 3 -y, 4 +z, 5 -z.
inline float3 lumenCardPoint(LumenCard c, float2 uv, float depth) {
    uint face = c.atlas.w & 7u, a = face >> 1, ua = (a + 1u) % 3u, va = (a + 2u) % 3u;
    float3 lo = c.lo.xyz, hi = c.hi.xyz, p;
    p[ua] = mix(lo[ua], hi[ua], uv.x);
    p[va] = mix(lo[va], hi[va], uv.y);
    p[a] = (face & 1u) == 0 ? mix(hi[a], lo[a], depth) : mix(lo[a], hi[a], depth);
    return p;
}

inline float3 lumenFaceNormal(uint face) {
    float3 n = float3(0.0f);
    n[face >> 1] = (face & 1u) == 0 ? 1.0f : -1.0f;
    return n;
}

// The texel of a card-tile thread: tiles[k] = (card, tile), a tile is 8x8 texels of the card.
inline uint2 lumenCardTexel(LumenCard c, uint tile, uint lane, thread uint2& local) {
    uint perRow = c.atlas.z / 8u;
    local = uint2(tile % perRow, tile / perRow) * 8u + uint2(lane % 8u, lane / 8u);
    return c.atlas.xy + local;
}

kernel void lumenCardCaptureKernel(constant Uniforms&               u          [[buffer(0)]],
                                   SCENE_ACCEL                      accel      [[buffer(1)]],
                                   device const float3*             positions  [[buffer(2)]],
                                   device const float3*             normals    [[buffer(3)]],
                                   device const uint*               indices    [[buffer(4)]],
                                   device const MeshData*           meshes     [[buffer(5)]],
                                   device const InstanceData*       instances  [[buffer(6)]],
                                   constant SceneShading&           shading    [[buffer(7)]],
                                   device const LumenCard*          cards      [[buffer(13)]],
                                   device const uint2*              tiles      [[buffer(14)]],
                                   constant uint&                   tileCount  [[buffer(15)]],
                                   texture2d<float, access::write>  albedo     [[texture(0)]],
                                   texture2d<float, access::write>  normalDepth [[texture(1)]],
                                   texture2d<float, access::write>  emission   [[texture(2)]],
                                   texture2d<float, access::write>  indirect   [[texture(3)]],   // a texel per 4x4 block
                                   uint gid [[thread_position_in_grid]])
{
    if (gid / 64u >= tileCount) return;
    uint2 tile = tiles[gid / 64u];
    LumenCard c = cards[tile.x];
    uint2 local;
    uint2 texel = lumenCardTexel(c, tile.y, gid % 64u, local);
    uint instance = c.atlas.w >> 3, face = c.atlas.w & 7u, a = face >> 1;
    InstanceData inst = instanceRecord(instances, instance);
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, nullptr, 0u);   // no lights: it only traces
    if (all(local % 4u == 0u)) indirect.write(float4(0.0f), texel / 4u);   // a new card's radiosity starts afresh

    float3 ext = c.hi.xyz - c.lo.xyz;
    float pad = 0.01f * max(max(ext.x, ext.y), ext.z) + 1e-3f;
    float3 outward = lumenFaceNormal(face);
    float3 start = lumenCardPoint(c, (float2(local) + 0.5f) / float(c.atlas.z), 0.0f) + outward * pad;
    float3 o = (inst.transform * float4(start, 1.0f)).xyz;
    float3 d = (inst.transform * float4(-outward, 0.0f)).xyz;
    float scale = length(d);
    d /= scale;
    float tMax = (ext[a] + 2.0f * pad) * scale;
    float spread = max(ext[(a + 1u) % 3u], ext[(a + 2u) % 3u]) * scale / float(c.atlas.z) / max(tMax, 1e-3f);
    float tMin = 0.0f;
    for (int k = 0; k < 4; ++k) {
        Surface h = traceSurface(makeRay(o, d, tMin, tMax), MASK_GEOMETRY, accel, s, spread);
        if (!h.hit) break;
        float t = dot(h.position - o, d);
        // Facing the card by its shading normal: some meshes' triangles are wound against their normals (the quads).
        if (h.instanceId == instance && dot(h.normal, d) < 0.0f) {
            float3 n = normalize((float4(h.normal, 0.0f) * inst.transform).xyz);   // M^T n: back into the instance's space
            float depth = saturate((t / scale - pad) / max(ext[a], 1e-6f));
            albedo.write(float4(hitAlbedo(h), 1.0f), texel);
            normalDepth.write(float4(equalAreaOctEncode(n) * 0.5f + 0.5f, depth, 1.0f), texel);
            emission.write(float4(giEmission(h), 0.0f), texel);
            return;
        }
        tMin = t + 1e-4f * scale + 1e-4f;
    }
    albedo.write(float4(0.0f), texel);
    normalDepth.write(float4(0.5f, 0.5f, 0.0f, 0.0f), texel);
    emission.write(float4(0.0f), texel);
}

// A card texel's point and normal in the world (`local`: the texel in the card).
inline void lumenCardSurface(LumenCard c, InstanceData inst, uint2 local, float4 nd, thread float3& p, thread float3& n) {
    float3 po = lumenCardPoint(c, (float2(local) + 0.5f) / float(c.atlas.z), nd.z);
    p = (inst.transform * float4(po, 1.0f)).xyz;
    n = normalize((inst.normalMatrix * float4(equalAreaOctDecode(nd.xy * 2.0f - 1.0f), 0.0f)).xyz);
}

// Direct light on the cards of the lighting list (as GI rays' hits get theirs), and what hits read.
kernel void lumenCardLightKernel(constant Uniforms&               u          [[buffer(0)]],
                                 SCENE_ACCEL                      accel      [[buffer(1)]],
                                 device const float3*             positions  [[buffer(2)]],
                                 device const float3*             normals    [[buffer(3)]],
                                 device const uint*               indices    [[buffer(4)]],
                                 device const MeshData*           meshes     [[buffer(5)]],
                                 device const InstanceData*       instances  [[buffer(6)]],
                                 constant SceneShading&           shading    [[buffer(7)]],
                                 device const Light*              lights     [[buffer(8)]],
                                 device const RegirReservoir*     regirGrid  [[buffer(11)]],
                                 constant RegirParams&            regir      [[buffer(12)]],
                                 device const LumenCard*          cards      [[buffer(13)]],
                                 device const uint2*              tiles      [[buffer(14)]],
                                 constant uint&                   tileCount  [[buffer(15)]],
                                 texture2d<float, access::read>   albedo     [[texture(0)]],
                                 texture2d<float, access::read>   normalDepth [[texture(1)]],
                                 texture2d<float, access::read>   emission   [[texture(2)]],
                                 texture2d_array<float, access::read> lightMap [[texture(3)]],
                                 texture2d<float, access::write>  direct     [[texture(4)]],
                                 texture2d<float, access::write>  final      [[texture(5)]],
                                 uint gid [[thread_position_in_grid]])
{
    if (gid / 64u >= tileCount) return;
    uint2 tile = tiles[gid / 64u];
    LumenCard c = cards[tile.x];
    uint2 local;
    uint2 texel = lumenCardTexel(c, tile.y, gid % 64u, local);
    float4 nd = normalDepth.read(texel);
    if (nd.w < 0.5f) {
        direct.write(float4(0.0f), texel);
        final.write(float4(0.0f), texel);
        return;
    }
    InstanceData inst = instanceRecord(instances, c.atlas.w >> 3);
    float3 p, n;
    lumenCardSurface(c, inst, local, nd, p, n);
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    float3 light = giLightIllum(lights, u, lightMap, p + n * RAY_EPSILON, n, n, pcgHash(gid + pcgHash(u.frameIndex * 7919u + 3u)),
                                accel, s);
    direct.write(float4(light, 0.0f), texel);
}


// The surface cache's light leaving point p (normal n) of instance `id`: the cards of the faces n looks toward,
// bilinear over the texels that are covered and whose depth agrees with p's, weighted by how squarely n faces the
// card. False where no card has it (the caller lights the hit itself).
inline bool lumenCardRadiance(device const LumenCard* cards, device const uint* table, uint instanceCount, uint id,
                              InstanceData inst, float3 p, float3 n, texture2d<float, access::read> cardND,
                              texture2d<float, access::read> cardFinal, thread float3& L) {
    if (id >= instanceCount) return false;
    float3 po = (float4(p, 1.0f) * inst.normalMatrix).xyz;            // (normalMatrix^T = the inverse transform)
    float3 no = normalize((float4(n, 0.0f) * inst.transform).xyz);
    float3 sum = float3(0.0f);
    float wsum = 0.0f;
    for (uint f = 0; f < 6u; ++f) {
        uint ci = table[id * 8u + f];
        if (ci == LUMEN_NO_CARD) continue;
        uint a = f >> 1, ua = (a + 1u) % 3u, va = (a + 2u) % 3u;
        float facing = (f & 1u) == 0 ? no[a] : -no[a];
        if (facing <= 0.1f) continue;
        LumenCard c = cards[ci];
        float3 ext = max(c.hi.xyz - c.lo.xyz, float3(1e-6f));
        float3 rel = (po - c.lo.xyz) / ext;
        float depth = (f & 1u) == 0 ? 1.0f - rel[a] : rel[a];
        float size = float(c.atlas.z);
        float tolerance = (0.02f * max(max(ext.x, ext.y), ext.z) + 2.0f * max(ext[ua], ext[va]) / size) / ext[a];
        float2 tc = clamp(float2(rel[ua], rel[va]) * size - 0.5f, 0.0f, size - 1.0f);
        int2 base = int2(floor(tc));
        float2 fr = tc - float2(base);
        for (int k = 0; k < 4; ++k) {
            int2 o = int2(k & 1, k >> 1);
            uint2 texel = c.atlas.xy + uint2(min(base + o, int2(int(size) - 1)));
            float4 nd = cardND.read(texel);
            if (nd.w < 0.5f || abs(nd.z - depth) > tolerance) continue;
            float w = (o.x ? fr.x : 1.0f - fr.x) * (o.y ? fr.y : 1.0f - fr.y) * facing + 1e-4f;
            sum += cardFinal.read(texel).rgb * w;
            wsum += w;
        }
    }
    if (wsum <= 0.0f) return false;
    L = sum / wsum;
    return true;
}

struct LumenRadiosityParams {
    uint rays;            // a probe's rays a frame
    uint cardInstances;   // the card table's instances
    uint frame;
    uint on;              // 0: no radiosity (the combine adds no indirect light)
    uint levels;          // > 0: trace the global distance field (its levels), else triangles
    uint pad0, pad1, pad2;
};

// Radiosity: a probe on each 4x4 block of a card's texels traces `rays` rays a frame from one of its covered texels
// (another each frame), cosine-weighted around its normal. A hit takes the cards' light (last frame's `final`, which
// holds its indirect light: the bounces add up from frame to frame), else its own direct light; a miss, the sky. The
// mean is E / pi, the units of `direct`; kept as a running mean over up to 8 frames (a = frames).
kernel void lumenCardRadiosityKernel(constant Uniforms&               u          [[buffer(0)]],
                                     SCENE_ACCEL                      accel      [[buffer(1)]],
                                     device const float3*             positions  [[buffer(2)]],
                                     device const float3*             normals    [[buffer(3)]],
                                     device const uint*               indices    [[buffer(4)]],
                                     device const MeshData*           meshes     [[buffer(5)]],
                                     device const InstanceData*       instances  [[buffer(6)]],
                                     constant SceneShading&           shading    [[buffer(7)]],
                                     device const Light*              lights     [[buffer(8)]],
                                     device const RegirReservoir*     regirGrid  [[buffer(11)]],
                                     constant RegirParams&            regir      [[buffer(12)]],
                                     device const LumenCard*          cards      [[buffer(13)]],
                                     device const uint2*              tiles      [[buffer(14)]],
                                     constant uint&                   tileCount  [[buffer(15)]],
                                     constant LumenRadiosityParams&   rp         [[buffer(16)]],
                                     device const uint*               table      [[buffer(17)]],
                                     texture2d<float, access::read>   normalDepth [[texture(1)]],
                                     texture2d_array<float, access::read> lightMap [[texture(3)]],
                                     texture2d<float, access::read>   final      [[texture(5)]],
                                     texture2d<float, access::read_write> indirect [[texture(6)]],
                                     device const LumenMeshSDF*       sdfMeshes  [[buffer(18)]],
                                     device const uint*               sdfBricks  [[buffer(19)]],
                                     device const float*              sdfCoarse  [[buffer(25)]],
                                     device const LumenClipLevel*     clipLevels [[buffer(22)]],
                                     texture3d<float>                 sdfAtlas   [[texture(7)]],
                                     texture3d<float, access::read>   globalField [[texture(8)]],
                                     texture3d<uint, access::read>    globalOwner [[texture(9)]],
                                     uint gid [[thread_position_in_grid]])
{
    if (gid / 4u >= tileCount) return;
    uint2 tile = tiles[gid / 4u];
    LumenCard c = cards[tile.x];
    uint perRow = c.atlas.z / 8u;
    uint2 blockLocal = uint2(tile.y % perRow, tile.y / perRow) * 8u + uint2(gid & 1u, (gid >> 1) & 1u) * 4u;
    uint2 block = (c.atlas.xy + blockLocal) / 4u;
    uint start = pcgHash(gid ^ pcgHash(rp.frame)) & 15u;
    float4 nd = float4(0.0f);
    uint2 local = blockLocal;
    for (uint k = 0; k < 16u && nd.w < 0.5f; ++k) {
        uint i = (start + k * 5u) & 15u;   // 5 is odd: every texel once
        local = blockLocal + uint2(i & 3u, i >> 2);
        nd = normalDepth.read(c.atlas.xy + local);
    }
    if (nd.w < 0.5f) { indirect.write(float4(0.0f), block); return; }
    InstanceData inst = instanceRecord(instances, c.atlas.w >> 3);
    float3 p, n;
    lumenCardSurface(c, inst, local, nd, p, n);
    float3 ext = c.hi.xyz - c.lo.xyz;
    p += n * (RAY_EPSILON + 1e-4f * max(max(ext.x, ext.y), ext.z));
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    Rng rng;
    rng.state = pcgHash(gid + pcgHash(rp.frame * 7919u + 11u));
    float3 sum = float3(0.0f);
    for (uint r = 0; r < rp.rays; ++r) {
        float3 d = cosineSampleHemisphere(n, float2(rng.next(), rng.next()));
        Surface h;
        if (rp.levels > 0) {
            // Through the global field, from off the card's own surface in it: a voxel of its level along the normal
            // (grazing rays too), then half one along the ray.
            uint l = 0;
            while (l + 1 < rp.levels && !lumenClipContains(clipLevels[l], p)) ++l;
            float voxel = clipLevels[l].voxel.x;
            LumenGlobalHit gh = lumenTraceGlobalSDF(p + n * voxel, d, 0.5f * voxel, 1e4f, clipLevels, rp.levels, globalField,
                                                    globalOwner);
            h.hit = false;
            if (gh.hit) h = lumenGlobalSurface(gh, instances, s.materials, s.textures, sdfMeshes, sdfBricks, sdfCoarse, sdfAtlas);
        } else {
            h = traceSurface(makeRay(p, d, 0.0f, INFINITY), MASK_GEOMETRY, accel, s, GI_RAY_SPREAD);
        }
        if (!h.hit) { sum += skyRadiance(u, s, d, 2.0f); continue; }
        float3 hng, hns;
        orientNormals(h, d, hng, hns);
        float3 cached;
        if (lumenCardRadiance(cards, table, rp.cardInstances, h.instanceId, instanceRecord(instances, h.instanceId),
                              h.position, hns, normalDepth, final, cached))
            sum += cached;
        else
            sum += hitAlbedo(h) * giLightIllum(lights, u, lightMap, h.position + hng * RAY_EPSILON, hns, hng, rng.state, accel, s);
    }
    float4 history = indirect.read(block);
    float frames = min(history.a + 1.0f, 8.0f);
    indirect.write(float4(mix(history.rgb, sum / float(max(rp.rays, 1u)), 1.0f / frames), frames), block);
}

// What hits read: albedo x (direct + indirect) + emission.
kernel void lumenCardCombineKernel(device const LumenCard*          cards      [[buffer(13)]],
                                   device const uint2*              tiles      [[buffer(14)]],
                                   constant uint&                   tileCount  [[buffer(15)]],
                                   constant LumenRadiosityParams&   rp         [[buffer(16)]],
                                   texture2d<float, access::read>   albedo     [[texture(0)]],
                                   texture2d<float, access::read>   emission   [[texture(2)]],
                                   texture2d<float, access::read>   direct     [[texture(4)]],
                                   texture2d<float, access::write>  final      [[texture(5)]],
                                   texture2d<float, access::read_write> indirect [[texture(6)]],
                                   uint gid [[thread_position_in_grid]])
{
    if (gid / 64u >= tileCount) return;
    uint2 tile = tiles[gid / 64u];
    uint2 local;
    uint2 texel = lumenCardTexel(cards[tile.x], tile.y, gid % 64u, local);
    float3 light = direct.read(texel).rgb + (rp.on != 0 ? indirect.read(texel / 4u).rgb : float3(0.0f));
    final.write(float4(albedo.read(texel).rgb * light + emission.read(texel).rgb, 0.0f), texel);
}
