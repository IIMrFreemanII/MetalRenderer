// =============================================================================================
// Lumen-style GI (GI mode "Lumen"): the screen-probe final gather.
//
// A probe sits on the G-buffer in every tile of `spacing` pixels, on a pixel picked afresh every frame. It traces
// spacing^2 rays, one per equal-area octahedral direction bin (the probe's tile of the atlas, so the atlas is the
// frame's size), each jittered inside its bin by an offset that changes every frame and is the same for every probe.
// Rays first march the screen (lumenScreenTrace): a hit there takes last frame's lit surface from the composite
// (FLAG_GI_RADIANCE). Rays that leave the screen, or pass behind something, go on in the world from the last point
// known to be in front of the depth. World ray hits are lit as the radiance cascades light theirs: the light-visibility maps plus, where the hit was on screen
// last frame, last frame's indirect light (multi-bounce). The probes' radiance is filtered across neighbouring probes
// (same direction, plane-weighted, rejected where the neighbour's hit would be seen at another angle), projected onto
// L1 SH, resolved per pixel from the nearest probes, and accumulated over frames.
// =============================================================================================

struct LumenParams {
    uint4  grid;     // xy = probe grid, z = spacing in pixels (also the direction tile's side), w = frame
    float4 tuning;   // x = 1 for multi-bounce feedback, y = history length (frames), z = 1 if history is valid,
                     // w = 1 to filter across probes
    uint4  options;  // x = debug view (0 probes, 1 trace kinds, 2 card albedo, 3 card light), y = screen-trace steps
                     // (0 = no screen traces), z = instances with cards (0 = no surface cache), w = 1: the cards
                     // hold indirect light (radiosity), so card hits take no multi-bounce feedback
    float4 screen;   // x = screen-trace thickness (fraction of the depth), y = its reach (m), z = the mesh fields' reach (m)
    uint4  sdf;      // x = 1: rays trace the mesh fields out to screen.z, then the global field (or triangles without
                     // one), y = the fields' instances, z = culling tiles across, w = the global field's levels (0: none)
};

// What answered a probe ray (the rayKind atlas, for the trace-kind debug view).
constant float LUMEN_KIND_NONE = 0.0f, LUMEN_KIND_SCREEN = 0.25f, LUMEN_KIND_WORLD = 0.5f, LUMEN_KIND_CARD = 0.625f,
                LUMEN_KIND_SDF = 0.75f, LUMEN_KIND_GLOBAL = 0.8125f, LUMEN_KIND_SKY = 1.0f;

// The closest-depth pyramid's level 0: the G-buffer's view depth, the sky far away (hzbReduceKernel builds the rest).
kernel void lumenHZBKernel(texture2d<float, access::read>  normalDepth [[texture(0)]],
                           texture2d<float, access::write> hzb         [[texture(1)]],
                           uint2 t [[thread_position_in_grid]])
{
    if (t.x >= hzb.get_width() || t.y >= hzb.get_height()) return;
    float d = normalDepth.read(t).w;
    hzb.write(float4(d > 0.0f ? d : 1e30f), t);
}

struct LumenScreenHit {
    bool  hit;
    uint2 pixel;   // the hit's pixel
    float t;       // the hit's distance along the ray
    float tSafe;   // how far the ray is known to be in front of the depth (where a world trace may start)
};

// Marches the ray from `origin` (a surface point on screen) along `dir` in this frame's depth, up to `reach` metres,
// to where it leaves the screen. Samples are spaced quadratically in screen space (fine near the start), each tested
// first against the closest-depth pyramid at the level of its step (in front of the cell's nearest surface: nothing
// there to hit), then against the pixel's depth. A sample behind the depth is refined by bisection and is a hit when
// it lies within `thickness` x the depth behind a surface that faces the ray; behind a thicker one the screen can't
// say what the ray meets, and the march stops.
inline LumenScreenHit lumenScreenTrace(constant Uniforms& u, float3 origin, float3 dir, float reach, uint steps, float jitter,
                                       float thickness, texture2d<float, access::read> hzb,
                                       texture2d<float, access::read> normalDepth)
{
    LumenScreenHit r;
    r.hit = false; r.pixel = uint2(0); r.t = 0.0f; r.tSafe = 0.0f;
    float2 size = float2(u.width, u.height);
    float3 v0 = origin - u.camPos.xyz;
    float dd = dot(dir, u.camForward.xyz);
    float d0, d1;
    float2 p0 = projectToPixel(v0, u.camRight, u.camUp, u.camForward, size, d0);
    if (!(d0 > 0.05f)) return r;
    float tEnd = dd < 0.0f ? min(reach, (d0 - 0.05f) / -dd) : reach;   // stop short of the near plane
    float2 p1 = projectToPixel(v0 + dir * tEnd, u.camRight, u.camUp, u.camForward, size, d1);
    float2 delta = p1 - p0;
    float sMax = 1.0f;
    if (delta.x > 0.0f) sMax = min(sMax, (size.x - 0.5f - p0.x) / delta.x);
    else if (delta.x < 0.0f) sMax = min(sMax, (0.5f - p0.x) / delta.x);
    if (delta.y > 0.0f) sMax = min(sMax, (size.y - 0.5f - p0.y) / delta.y);
    else if (delta.y < 0.0f) sMax = min(sMax, (0.5f - p0.y) / delta.y);
    float len = length(delta);
    float sStart = 1.5f / max(len, 1e-6f);   // past the probe's own pixel
    if (len * sMax < 2.0f || sStart >= sMax) return r;
    float invD0 = 1.0f / d0, invD1 = 1.0f / d1;
    uint maxLevel = hzb.get_num_mip_levels() - 1u;
    float prevS = sStart;
    for (uint i = 0; i < steps; ++i) {
        float f = (float(i) + jitter) / float(steps);
        float s = mix(sStart, sMax, f * f);
        float2 px = p0 + delta * s;
        float invD = mix(invD0, invD1, s);
        float rayD = 1.0f / invD;
        float t = tEnd * s * invD1 / invD;   // perspective: s is linear on screen, 1/depth is linear in s
        uint level = min(uint(max(log2(max(len * (s - prevS), 1.0f)), 0.0f)), maxLevel);
        uint2 q = uint2(px);
        if (rayD < hzb.read(q >> level, level).x) { prevS = s; r.tSafe = t; continue; }
        float sceneD = normalDepth.read(q).w;
        if (sceneD <= 0.0f || rayD <= sceneD) { prevS = s; r.tSafe = t; continue; }
        float lo = prevS, hi = s;
        for (int k = 0; k < 4; ++k) {
            float m = 0.5f * (lo + hi);
            float sd = normalDepth.read(uint2(p0 + delta * m)).w;
            if (sd > 0.0f && 1.0f / mix(invD0, invD1, m) > sd) hi = m; else lo = m;
        }
        q = uint2(p0 + delta * hi);
        float4 nd = normalDepth.read(q);
        invD = mix(invD0, invD1, hi);
        if (nd.w > 0.0f && 1.0f / invD - nd.w < thickness * nd.w + 0.01f && dot(nd.xyz, dir) < 0.0f) {
            r.hit = true;
            r.pixel = q;
            r.t = tEnd * hi * invD1 / invD;
        }
        return r;
    }
    return r;
}

// This frame's offset inside every direction bin (R2 sequence): the same for all probes, so a bin is one direction
// across the screen and the filter compares like with like.
inline float2 lumenDirectionJitter(uint frame) {
    return fract(float2(0.7548776662f, 0.5698402910f) * float(frame % 4096u) + 0.5f);
}

inline float3 lumenDirection(uint2 bin, uint side, float2 jitter) {
    return equalAreaOctDecode((float2(bin) + jitter) / float(side) * 2.0f - 1.0f);
}

// One probe per tile, on a pixel of the tile that has a surface with GI (picked from a different start every frame).
// probeNs.w = the pixel's index in the tile.
kernel void lumenProbeKernel(constant Uniforms&               u           [[buffer(0)]],
                             constant LumenParams&            p           [[buffer(9)]],
                             texture2d<float, access::read>   surfacePos  [[texture(0)]],
                             texture2d<float, access::read>   normalDepth [[texture(1)]],
                             texture2d<float, access::read>   geoNormal   [[texture(2)]],
                             texture2d<float, access::write>  probePos    [[texture(3)]],   // xyz, w = view depth (-1 = none)
                             texture2d<float, access::write>  probeNs     [[texture(4)]],   // shading normal, w = pixel in tile
                             texture2d<float, access::write>  probeNg     [[texture(5)]],   // geometric normal, w = id + 1
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= p.grid.x || tid.y >= p.grid.y) return;
    uint side = p.grid.z, count = side * side;
    uint start = pcgHash(tid.x + tid.y * 65521u + pcgHash(p.grid.w)) % count;
    for (uint k = 0; k < count; ++k) {
        uint i = (start + k * 37u) % count;   // 37 is odd and count a power of two: every pixel once
        uint2 px = tid * side + uint2(i % side, i / side);
        if (px.x >= u.width || px.y >= u.height) continue;
        float4 sp = surfacePos.read(px);
        if (sp.w <= 0.0f) continue;
        float4 nd = normalDepth.read(px);
        probePos.write(float4(sp.xyz, nd.w), tid);
        probeNs.write(float4(nd.xyz, float(i)), tid);
        probeNg.write(float4(geoNormal.read(px).xyz, TILED ? 0.0f : sp.w), tid);   // surfacePos.w: the instance's id + 1
        return;
    }
    probePos.write(float4(0.0f, 0.0f, 0.0f, -1.0f), tid);
}

// One ray per (probe, direction bin). Threads are direction-major (neighbouring threads = neighbouring probes, same
// direction) so rays stay coherent. Writes radiance and the hit distance (w; -1 = no ray: no probe, or below it).
kernel void lumenTraceKernel(constant Uniforms&               u           [[buffer(0)]],
                             SCENE_ACCEL                      accel       [[buffer(1)]],
                             device const float3*             positions   [[buffer(2)]],
                             device const float3*             normals     [[buffer(3)]],
                             device const uint*               indices     [[buffer(4)]],
                             device const MeshData*           meshes      [[buffer(5)]],
                             device const InstanceData*       instances   [[buffer(6)]],
                             constant SceneShading&           shading     [[buffer(7)]],
                             device const Light*              lights      [[buffer(8)]],
                             device const RegirReservoir*     regirGrid   [[buffer(11)]],
                             constant RegirParams&            regir       [[buffer(12)]],
                             constant LumenParams&            p           [[buffer(9)]],
                             device const uint*               prevAmbient [[buffer(10)]],   // rgb sums (x1024) + count
                             texture2d<float, access::read>   probePos    [[texture(0)]],
                             texture2d<float, access::read>   probeNg     [[texture(1)]],
                             texture2d<float, access::write>  radiance    [[texture(2)]],
                             texture2d_array<float, access::read> lightMap [[texture(3)]],
                             texture2d<float, access::read>   prevND      [[texture(4)]],
                             texture2d<float, access::read>   prevIndirect [[texture(5)]],
                             texture2d<float, access::read>   hzb         [[texture(6)]],    // closest depth, this frame
                             texture2d<float, access::read>   normalDepth [[texture(7)]],
                             texture2d<float, access::read>   motion      [[texture(8)]],
                             texture2d<float, access::read>   prevRadiance [[texture(9)]],  // the composite's, last frame
                             texture2d<float, access::write>  rayKind     [[texture(10)]],
                             device const LumenCard*          cards       [[buffer(13)]],
                             device const uint*               cardTable   [[buffer(14)]],
                             texture2d<float, access::read>   cardND      [[texture(11)]],
                             texture2d<float, access::read>   cardFinal   [[texture(12)]],
                             device const LumenMeshSDF*       sdfMeshes   [[buffer(15)]],
                             device const uint*               sdfBricks   [[buffer(16)]],
                             device const LumenSDFInstance*   sdfList     [[buffer(17)]],
                             device const uint*               tileLists   [[buffer(18)]],
                             device const float*              sdfCoarse   [[buffer(25)]],
                             texture3d<float>                 sdfAtlas    [[texture(13)]],
                             device const LumenClipLevel*     clipLevels  [[buffer(22)]],
                             texture3d<float, access::read>   globalField [[texture(14)]],
                             texture3d<uint, access::read>    globalOwner [[texture(15)]],
                             uint gid [[thread_position_in_grid]])
{
    uint probeCount = p.grid.x * p.grid.y, side = p.grid.z;
    if (gid >= probeCount * side * side) return;
    uint probe = gid % probeCount, bin = gid / probeCount;
    uint2 pc = uint2(probe % p.grid.x, probe / p.grid.x), bc = uint2(bin % side, bin / side);
    uint2 texel = pc * side + bc;

    float4 pos = probePos.read(pc);
    float4 probeNormal = probeNg.read(pc);
    float3 ng = probeNormal.xyz;
    uint self = probeNormal.w > 0.0f ? uint(probeNormal.w) - 1u : ~0u;   // the probe's own instance (~0: not known)
    float3 dir = lumenDirection(bc, side, lumenDirectionJitter(p.grid.w));
    if (pos.w <= 0.0f || dot(dir, ng) <= 0.0f) {
        radiance.write(float4(0.0f, 0.0f, 0.0f, -1.0f), texel);
        rayKind.write(float4(LUMEN_KIND_NONE), texel);
        return;
    }
    float3 origin = pos.xyz + ng * RAY_EPSILON;

    float tMin = 0.0f;
    if (p.options.y > 0) {
        float jitter = float(pcgHash(gid ^ pcgHash(p.grid.w + 17u)) & 0xffffu) / 65536.0f;
        LumenScreenHit sh = lumenScreenTrace(u, origin + ng * (0.002f * pos.w), dir, p.screen.y, p.options.y, jitter,
                                             p.screen.x, hzb, normalDepth);
        if (sh.hit) {
            int2 q = reprojectNearest(u, motion.read(sh.pixel), normalDepth.read(sh.pixel).xyz, prevND);
            if (q.x >= 0) {
                radiance.write(float4(prevRadiance.read(uint2(q)).rgb, sh.t), texel);
                rayKind.write(float4(LUMEN_KIND_SCREEN), texel);
                return;
            }
        }
        tMin = sh.tSafe;
    }

    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    // The mesh fields near the probe (the instances around its tile), then triangles beyond.
    Surface h;
    h.hit = false;
    bool sdfHit = false, globalHit = false;
    if (p.sdf.x != 0 && tMin < p.screen.z) {
        uint2 ct = pc / LUMEN_TILE_PROBES;
        uint tile = ct.y * p.sdf.z + ct.x;
        LumenSDFHit sh = lumenTraceMeshSDFs(origin, dir, tMin, p.screen.z, self, sdfList, tileLists + tile * LUMEN_TILE_LIST + 1u,
                                            tileLists[tile * LUMEN_TILE_LIST], instances, sdfMeshes, sdfBricks, sdfCoarse, sdfAtlas);
        if (sh.hit) {
            // The hit as a surface: no material but the instance's colour (the cards have the rest).
            InstanceData inst = instanceRecord(instances, sh.id);
            h.hit = sdfHit = true;
            h.position = sh.position;
            h.prevPosition = (inst.prevTransform * float4(sh.local, 1.0f)).xyz;
            h.normal = h.geomNormal = sh.normal;
            h.albedo = lumenFieldAlbedo(sdfMeshes[inst.meshIndex], s.materials, s.textures, inst.materialIndex);
            h.emission = h.f0 = float3(0.0f);
            h.metallic = h.specular = 0.0f;
            h.roughness = 1.0f;
            h.instanceId = sh.id;
            h.lightEmitter = h.backlit = false;
        }
        tMin = max(tMin, p.screen.z);
    }
    if (!sdfHit && p.sdf.x != 0 && p.sdf.w > 0) {
        // Beyond: the global field, then the sky. Its hit is lit through the instance nearest it.
        LumenGlobalHit gh = lumenTraceGlobalSDF(origin, dir, tMin, 1e4f, clipLevels, p.sdf.w, globalField, globalOwner);
        if (gh.hit) {
            h = lumenGlobalSurface(gh, instances, s.materials, s.textures, sdfMeshes, sdfBricks, sdfCoarse, sdfAtlas);
            globalHit = true;
        }
    } else if (!sdfHit) {
        h = traceSurface(makeRay(origin, dir, tMin, INFINITY), rayMask(MASK_GEOMETRY, RAY_GI), accel, s, GI_RAY_SPREAD);
    }

    float3 L;
    float dist;
    bool fromCard = false;
    if (h.hit) {
        float3 hng, hns;
        orientNormals(h, dir, hng, hns);
        float3 hp = h.position + hng * RAY_EPSILON;
        // The surface cache where its cards have the hit, else the hit's own direct light.
        float3 cached = float3(0.0f), light = float3(0.0f);
        fromCard = p.options.z > 0 && lumenCardRadiance(cards, cardTable, p.options.z, h.instanceId,
                                                        instanceRecord(instances, h.instanceId), h.position, hns, cardND,
                                                        cardFinal, cached);
        if (!fromCard)
            light = giLightIllum(lights, u, lightMap, hp, hns, hng, pcgHash(gid + pcgHash(u.frameIndex * 7919u)), accel, s);
        // (Not on leaves: in a canopy, last frame's light on screen near the hit is often another leaf's.)
        bool foliage = p.options.z > 0 && h.instanceId < p.options.z && (cardTable[h.instanceId * 8u + 6u] & 1u) != 0;
        if (p.tuning.x > 0.0f && !(fromCard && p.options.w != 0) && !foliage) {
            // Multi-bounce, as the cascades: last frame's indirect light where the hit was on screen, else its mean.
            uint2 q;
            bool found = lastFramePixel(u, h.prevPosition, hns, prevND, q);
            if (found) light += prevIndirect.read(q).rgb;
            if (!found && prevAmbient[3] > 0)
                light += float3(prevAmbient[0], prevAmbient[1], prevAmbient[2]) / (1024.0f * float(prevAmbient[3]));
        }
        L = cached + hitAlbedo(h) * light;
        dist = distance(h.position, pos.xyz);
    } else {
        L = skyRadiance(u, s, dir, 2.0f);
        dist = 1e4f;
    }
    radiance.write(float4(L, dist), texel);
    rayKind.write(float4(!h.hit ? LUMEN_KIND_SKY : sdfHit ? LUMEN_KIND_SDF : globalHit ? LUMEN_KIND_GLOBAL
                         : fromCard ? LUMEN_KIND_CARD : LUMEN_KIND_WORLD), texel);
}

// Per atlas texel: the probe's radiance in this direction averaged with its 3x3 neighbours' in the same direction.
// A neighbour counts by rcProbeWeight (same surface) and only where its hit, seen from this probe, is in about the
// same direction (else the light came from a different place: parallax at near hits).
kernel void lumenFilterKernel(constant LumenParams&            p        [[buffer(9)]],
                              texture2d<float, access::read>   probePos [[texture(0)]],
                              texture2d<float, access::read>   probeNs  [[texture(1)]],
                              texture2d<float, access::read>   radiance [[texture(2)]],
                              texture2d<float, access::write>  filtered [[texture(3)]],
                              uint2 tid [[thread_position_in_grid]])
{
    uint side = p.grid.z;
    uint2 pc = tid / side, bc = tid % side;
    if (pc.x >= p.grid.x || pc.y >= p.grid.y) return;
    float4 c = radiance.read(tid);
    if (c.w < 0.0f || p.tuning.w == 0.0f) { filtered.write(c, tid); return; }
    float4 pos = probePos.read(pc);
    float3 n = probeNs.read(pc).xyz;
    float3 dir = lumenDirection(bc, side, lumenDirectionJitter(p.grid.w));
    float3 sum = c.rgb;
    float wsum = 1.0f;
    for (int k = 0; k < 9; ++k) {
        if (k == 4) continue;
        int2 q = int2(pc) + int2(k % 3 - 1, k / 3 - 1);
        if (any(q < 0) || q.x >= int(p.grid.x) || q.y >= int(p.grid.y)) continue;
        float4 r = radiance.read(uint2(q) * side + bc);
        if (r.w < 0.0f) continue;
        float4 qp = probePos.read(uint2(q));
        float3 seen = qp.xyz + dir * r.w - pos.xyz;
        float angle = dot(seen, dir) * rsqrt(max(dot(seen, seen), 1e-12f));
        float w = rcProbeWeight(qp, probeNs.read(uint2(q)).xyz, pos.xyz, n, pos.w) * saturate((angle - 0.97f) / 0.02f);
        sum += r.rgb * w;
        wsum += w;
    }
    filtered.write(float4(sum / wsum, c.w), tid);
}

// Each probe's filtered radiance projected onto L1 SH (per colour channel), as rcSHKernel; also sums its mean
// irradiance into `ambient`, next frame's indirect light at ray hits that weren't on screen.
kernel void lumenSHKernel(constant LumenParams&            p        [[buffer(9)]],
                          device atomic_uint*              ambient  [[buffer(10)]],
                          texture2d<float, access::read>   probePos [[texture(0)]],
                          texture2d<float, access::read>   radiance [[texture(1)]],
                          texture2d<float, access::write>  shR      [[texture(2)]],
                          texture2d<float, access::write>  shG      [[texture(3)]],
                          texture2d<float, access::write>  shB      [[texture(4)]],
                          uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= p.grid.x || tid.y >= p.grid.y) return;
    if (probePos.read(tid).w <= 0.0f) return;
    uint side = p.grid.z;
    float2 jitter = lumenDirectionJitter(p.grid.w);
    float dOmega = 4.0f * M_PI_F / float(side * side);
    float4 r = float4(0.0f), g = float4(0.0f), b = float4(0.0f);
    for (uint k = 0; k < side * side; ++k) {
        uint2 bc = uint2(k % side, k / side);
        float4 L = radiance.read(tid * side + bc);
        if (L.w < 0.0f) continue;
        float3 dir = lumenDirection(bc, side, jitter);
        float4 basis = float4(0.282095f, 0.488603f * dir.y, 0.488603f * dir.z, 0.488603f * dir.x) * dOmega;
        r += L.r * basis; g += L.g * basis; b += L.b * basis;
    }
    shR.write(r, tid); shG.write(g, tid); shB.write(b, tid);
    float3 mean = 0.282095f * float3(r.x, g.x, b.x) * 2.0f;   // x2: only the upper hemisphere carries light
    atomic_fetch_add_explicit(&ambient[0], uint(clamp(mean.r, 0.0f, 1e5f) * 1024.0f), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambient[1], uint(clamp(mean.g, 0.0f, 1e5f) * 1024.0f), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambient[2], uint(clamp(mean.b, 0.0f, 1e5f) * 1024.0f), memory_order_relaxed);
    atomic_fetch_add_explicit(&ambient[3], 1, memory_order_relaxed);
}

// Per pixel: the nearest 4x4 probes' SH evaluated for the pixel's normal, weighted by their distance on screen (from
// the pixel each probe sits on) and rcProbeWeight; then blended with the pixel's reprojected history. Output is
// "illumination" (E / pi), the units of t.indirect.
kernel void lumenResolveKernel(constant Uniforms&              u           [[buffer(0)]],
                               constant LumenParams&           p           [[buffer(9)]],
                               texture2d<float, access::read>  probePos    [[texture(0)]],
                               texture2d<float, access::read>  probeNs     [[texture(1)]],
                               texture2d<float, access::read>  shR         [[texture(2)]],
                               texture2d<float, access::read>  shG         [[texture(3)]],
                               texture2d<float, access::read>  shB         [[texture(4)]],
                               texture2d<float, access::read>  normalDepth [[texture(5)]],
                               texture2d<float, access::read>  surfacePos  [[texture(6)]],
                               texture2d<float, access::read>  motion      [[texture(7)]],
                               texture2d<float, access::read>  prevND      [[texture(8)]],
                               texture2d<float, access::read>  prevHistory [[texture(9)]],   // rgb, a = frames in it
                               texture2d<float, access::write> outIndirect [[texture(10)]],
                               texture2d<float, access::write> outHistory  [[texture(11)]],
                               texture2d<float, access::write> giDebug     [[texture(12)]],
                               texture2d<float, access::read>  rayKind     [[texture(13)]],
                               device const InstanceData*      instances   [[buffer(6)]],
                               device const LumenCard*         cards       [[buffer(13)]],
                               device const uint*              cardTable   [[buffer(14)]],
                               texture2d<float, access::read>  cardND      [[texture(14)]],
                               texture2d<float, access::read>  cardFinal   [[texture(15)]],
                               texture2d<float, access::read>  cardAlbedo  [[texture(16)]],
                               device const LumenMeshSDF*      sdfMeshes   [[buffer(15)]],
                               device const uint*              sdfBricks   [[buffer(16)]],
                               device const LumenSDFInstance*  sdfList     [[buffer(17)]],
                               device const float*             sdfCoarse   [[buffer(25)]],
                               texture3d<float>                sdfAtlas    [[texture(17)]],
                               device const LumenClipLevel*    clipLevels  [[buffer(22)]],
                               texture3d<float, access::read>  globalField [[texture(18)]],
                               texture3d<uint, access::read>   globalOwner [[texture(19)]],
                               uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    if (p.options.x >= 4) {
        // Debug: the camera's rays through the mesh fields (every instance that has one). 4: their normals; 5: for
        // Tools/eval/lumen.py, r = the distance from the G-buffer's surface (x 10 per metre), g = 1 where a field was
        // hit, b = 1 where the G-buffer has a surface; magenta (4) where no field is.
        float3 dir = primaryDirection(u, tid);
        if (p.options.x == 6) {
            // 6: the global field's normals from the camera (magenta where it has nothing).
            LumenGlobalHit gh = lumenTraceGlobalSDF(u.camPos.xyz, dir, 0.0f, 1e4f, clipLevels, p.sdf.w, globalField, globalOwner);
            giDebug.write(float4(gh.hit ? gh.normal * 0.5f + 0.5f : float3(1.0f, 0.0f, 1.0f), 1.0f), tid);
            outIndirect.write(float4(0.0f), tid);
            outHistory.write(float4(0.0f), tid);
            return;
        }
        LumenSDFHit sh = lumenTraceMeshSDFs(u.camPos.xyz, dir, 0.0f, 1e4f, ~0u, sdfList, nullptr, p.sdf.y, instances, sdfMeshes,
                                            sdfBricks, sdfCoarse, sdfAtlas);
        float3 c;
        if (p.options.x == 4) c = sh.hit ? sh.normal * 0.5f + 0.5f : float3(1.0f, 0.0f, 1.0f);
        else {
            bool surface = normalDepth.read(tid).w > 0.0f;
            float error = sh.hit && surface ? abs(sh.t - distance(sp.xyz, u.camPos.xyz)) : 0.0f;
            c = float3(saturate(error * 10.0f), sh.hit ? 1.0f : 0.0f, surface ? 1.0f : 0.0f);
        }
        giDebug.write(float4(c, 1.0f), tid);
        outIndirect.write(float4(0.0f), tid);
        outHistory.write(float4(0.0f), tid);
        return;
    }
    if (sp.w <= 0.0f) {
        outIndirect.write(float4(0.0f), tid);
        outHistory.write(float4(0.0f), tid);
        giDebug.write(float4(0.0f), tid);
        return;
    }
    float4 nd = normalDepth.read(tid);
    float3 n = nd.xyz;
    uint side = p.grid.z;
    float2 pixel = float2(tid) + 0.5f;
    int2 base = int2(floor(pixel / float(side) - 0.5f)) - 1;
    float3 sum = float3(0.0f);
    float wsum = 0.0f;
    for (int k = 0; k < 16; ++k) {
        int2 qi = base + int2(k & 3, k >> 2);
        if (any(qi < 0) || qi.x >= int(p.grid.x) || qi.y >= int(p.grid.y)) continue;
        uint2 q = uint2(qi);
        float4 qp = probePos.read(q);
        if (qp.w <= 0.0f) continue;
        float4 qn = probeNs.read(q);
        uint i = uint(qn.w);
        float2 d = (float2(q * side + uint2(i % side, i / side)) + 0.5f - pixel) / float(side);
        float falloff = exp(-dot(d, d) * 0.8f);
        float w = falloff * rcProbeWeight(qp, qn.xyz, sp.xyz, n, nd.w) + 1e-6f * falloff;
        float3 e = float3(rcEvalSH(shR.read(q), n), rcEvalSH(shG.read(q), n), rcEvalSH(shB.read(q), n));
        sum += e * w;
        wsum += w;
    }
    float3 current = wsum > 0.0f ? sum / wsum : float3(0.0f);

    float3 result = current;
    float frames = 1.0f;
    if (p.tuning.z > 0.0f) {
        int2 q = reprojectNearest(u, motion.read(tid), n, prevND);
        if (q.x >= 0) {
            float4 h = prevHistory.read(uint2(q));
            frames = min(h.a + 1.0f, p.tuning.y);
            result = mix(h.rgb, current, 1.0f / frames);
        }
    }
    outIndirect.write(float4(result, 1.0f), tid);
    outHistory.write(float4(result, frames), tid);
    uint2 tile = tid / side, at = tid % side;
    if (p.options.x >= 2) {
        // Debug: the surface cache at the pixel's own surface (albedo or light), magenta where no card has it.
        uint id = TILED ? ~0u : uint(sp.w) - 1u;
        float3 c;
        bool found = id != ~0u && lumenCardRadiance(cards, cardTable, p.options.z, id, instanceRecord(instances, id), sp.xyz, n,
                                                    cardND, p.options.x == 2 ? cardAlbedo : cardFinal, c);
        giDebug.write(float4(found ? c : float3(1.0f, 0.0f, 1.0f), 1.0f), tid);
        return;
    }
    if (p.options.x == 1) {
        // Debug: what answered the tile's probe rays, as shares of its rays: the screen (red), the mesh fields (cyan),
        // the global field (white), triangles lit by the surface cache (green) or where they are (yellow), the sky (blue).
        float3 share = float3(0.0f);
        float rays = 0.0f;
        for (uint k = 0; k < side * side; ++k) {
            float kind = rayKind.read(tile * side + uint2(k % side, k / side)).r;
            if (kind <= 0.0f) continue;
            rays += 1.0f;
            share += kind < 0.4f ? float3(1, 0, 0) : kind < 0.56f ? float3(1, 1, 0) : kind < 0.7f ? float3(0, 1, 0)
                   : kind < 0.78f ? float3(0, 1, 1) : kind < 0.9f ? float3(1, 1, 1) : float3(0, 0, 1);
        }
        giDebug.write(float4(rays > 0.0f ? share / rays : float3(0.0f), 1.0f), tid);
        return;
    }
    // Debug: this frame's probe pixels over the weight's confidence (dark = no good probe nearby).
    bool probeHere = all(tile < p.grid.xy) && probePos.read(tile).w > 0.0f && uint(probeNs.read(tile).w) == at.x + at.y * side;
    giDebug.write(float4(probeHere ? float3(1.0f, 0.6f, 0.1f) : float3(saturate(wsum)), 1.0f), tid);
}

// Per culling tile (4x4 probes): the fields' instances whose world box comes within `reach` of a probe of the tile.
kernel void lumenCullKernel(constant LumenParams&            p          [[buffer(9)]],
                            device const LumenSDFInstance*   list       [[buffer(17)]],
                            device uint*                     tileLists  [[buffer(18)]],
                            texture2d<float, access::read>   probePos   [[texture(0)]],
                            uint2 tg   [[threadgroup_position_in_grid]],
                            uint  lane [[thread_index_in_threadgroup]])
{
    threadgroup float3 lo, hi;
    threadgroup atomic_uint found;
    uint2 tiles = (p.grid.xy + LUMEN_TILE_PROBES - 1u) / LUMEN_TILE_PROBES;
    uint tile = tg.y * tiles.x + tg.x;
    if (lane == 0) {
        float3 a = float3(INFINITY), b = float3(-INFINITY);
        for (uint k = 0; k < LUMEN_TILE_PROBES * LUMEN_TILE_PROBES; ++k) {
            uint2 q = tg * LUMEN_TILE_PROBES + uint2(k % LUMEN_TILE_PROBES, k / LUMEN_TILE_PROBES);
            if (any(q >= p.grid.xy)) continue;
            float4 pos = probePos.read(q);
            if (pos.w <= 0.0f) continue;
            a = min(a, pos.xyz);
            b = max(b, pos.xyz);
        }
        lo = a - p.screen.z;
        hi = b + p.screen.z;
        atomic_store_explicit(&found, 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = lane; i < p.sdf.y; i += 64u) {
        LumenSDFInstance si = list[i];
        if (any(si.lo.xyz > hi) || any(si.hi.xyz < lo)) continue;
        uint slot = atomic_fetch_add_explicit(&found, 1u, memory_order_relaxed);
        if (slot < LUMEN_TILE_LIST - 1u) tileLists[tile * LUMEN_TILE_LIST + 1u + slot] = i;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane == 0) tileLists[tile * LUMEN_TILE_LIST] = min(atomic_load_explicit(&found, memory_order_relaxed), LUMEN_TILE_LIST - 1u);
}
