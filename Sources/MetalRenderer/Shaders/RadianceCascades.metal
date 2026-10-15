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
    float4 interval;   // x = start, y = end (meters), z = 1 to use last frame's indirect light at hits, w = 1 if there
                       // is a last frame (the resolve's history in the interiors' box)
};

constant uint RC_MAX_CASCADES = 5;
constant float RC_INTERIOR_START = 0.1f;   // the farthest an interval starts in the interiors' box: under a partition (0.12 m)
constant float RC_INTERIOR_BLEND = 0.1f;   // this frame's least share of the indirect light in the interiors' box

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
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, nullptr, 0u);   // no lights: it only traces

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
                               device const RegirReservoir* regirGrid [[buffer(11)]],  // the light grid (ReGIR)
                               constant RegirParams&       regir     [[buffer(12)]],
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
    // In the walkable interiors' box a probe's rays take a new place inside their bins every frame (one offset for all
    // of a probe's bins, so they stay one to a bin) and the resolve averages the frames (rcResolveKernel): a room lit
    // by a small bright patch (the sun on a sofa) fell between a probe's few fixed rays or not, probe by probe, and
    // its walls showed it as blotches. Elsewhere the rays stay fixed, noise-free with no history.
    float2 offset = float2(0.5f);
    if (inInteriorBox(u.interiorLo, u.interiorHi, pos.xyz)) {
        uint h = pcgHash(probe * 9781u + p.layout.z * 6271u + pcgHash(u.frameIndex));
        offset = float2(float(h & 0xFFFFu), float(h >> 16)) * (1.0f / 65536.0f);
    }
    float3 dir = equalAreaOctDecode((float2(bc) + offset) / float(dirSide) * 2.0f - 1.0f);
    if (dot(dir, ng) < -0.05f) { merged.write(float4(0.0f), texel); return; }   // below the surface: never used

    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    bool last = p.layout.w != 0;
    // In the walkable interiors' box an interval starts halfway into the one below, and no further out than
    // RC_INTERIOR_START: a coarse probe a little off this one's place would otherwise start its rays past a wall this
    // probe's own rays missed, and bring the sunlit outside in (light leaking through walls and ceilings); halfway
    // alone still started cascade 1's 0.2 m out, past a 0.12 m partition, and a dark room's ceiling edges glowed with
    // the next room's light. Indoors the longer rays cost nothing: they meet the room's own walls first. Elsewhere
    // the intervals only meet (it costs the forest ~3 ms of rays and changes little outdoors).
    float start = inInteriorBox(u.interiorLo, u.interiorHi, pos.xyz) ? min(p.interval.x * 0.5f, RC_INTERIOR_START) : p.interval.x;
    Ray r = makeRay(pos.xyz + ng * RAY_EPSILON, dir, start, last ? INFINITY : p.interval.y);
    Surface h = traceSurface(r, rayMask(MASK_GEOMETRY, RAY_GI), accel, s, GI_RAY_SPREAD);

    float3 radiance = float3(0.0f);
    if (h.hit) {
        float3 hng, hns;
        orientNormals(h, dir, hng, hns);
        float3 hp = h.position + hng * RAY_EPSILON;
        float3 light = giLightIllum(lights, u, lightMap, hp, hns, hng,
                                    pcgHash(gid + pcgHash(u.frameIndex + p.layout.x * 7919u)), accel, s);
        if (p.interval.z > 0.0f) {
            // Multi-bounce: where this hit point was on screen last frame, add last frame's indirect light there;
            // elsewhere (off screen, occluded) fall back to last frame's average indirect light over all probes.
            uint2 q;
            bool found = lastFramePixel(u, h.prevPosition, hns, prevND, q);
            if (found) light += prevIndirect.read(q).rgb;
            if (!found && prevAmbient[3] > 0)
                light += float3(prevAmbient[0], prevAmbient[1], prevAmbient[2]) / (1024.0f * float(prevAmbient[3]));
        }
        radiance = hitAlbedo(h) * light;
    } else if (last) {
        radiance = skyRadiance(u, s, dir, 2.0f);
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

// Per atlas texel of an upper cascade (1 and up), in the walkable interiors' box: its direction's radiance averaged
// with the 3x3 neighbouring probes' in the same direction (rcProbeWeight: the same surface), `step` probes apart (two
// passes: 1, then 2, a-trous), before the cascade below merges it. There each probe's rays take one jittered offset a frame (rcTraceMergeKernel), so each probe's light had
// an error of its own, and the cascade below passed it on as blotches the size of these probes (32-64 px at cascades
// 1 and 2, where a room's light comes from) wherever the resolve's history was short: a turning camera's new view.
// The probes' offsets average out (two passes: about 25 probes); their far light barely differs. Elsewhere: a copy.
kernel void rcFilterKernel(constant Uniforms&              u        [[buffer(0)]],
                           constant RCParams&              p        [[buffer(9)]],
                           texture2d<float, access::read>  probePos [[texture(0)]],
                           texture2d<float, access::read>  probeNs  [[texture(1)]],
                           texture2d<float, access::read>  merged   [[texture(2)]],
                           texture2d<float, access::write> filtered [[texture(3)]],
                           constant int&                   step     [[buffer(10)]],   // probes apart: 1, then 2
                           uint2 tid [[thread_position_in_grid]])
{
    uint side = p.layout.y;
    uint2 pc = tid / side, bc = tid % side;
    if (pc.x >= p.grids.x || pc.y >= p.grids.y) return;
    float4 c = merged.read(tid);
    float4 pos = probePos.read(pc);
    if (pos.w <= 0.0f || !inInteriorBox(u.interiorLo, u.interiorHi, pos.xyz)) { filtered.write(c, tid); return; }
    float3 n = probeNs.read(pc).xyz;
    float3 sum = c.rgb;
    float wsum = 1.0f;
    for (int k = 0; k < 9; ++k) {
        if (k == 4) continue;
        int2 q = int2(pc) + int2(k % 3 - 1, k / 3 - 1) * step;
        if (any(q < 0) || q.x >= int(p.grids.x) || q.y >= int(p.grids.y)) continue;
        float4 qp = probePos.read(uint2(q));
        if (qp.w <= 0.0f) continue;
        float w = rcProbeWeight(qp, probeNs.read(uint2(q)).xyz, pos.xyz, n, pos.w) * ((k & 1) ? 1.0f : 0.5f);   // corners half
        sum += merged.read(uint2(q) * side + bc).rgb * w;
        wsum += w;
    }
    filtered.write(float4(sum / wsum, c.w), tid);
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

// Weighted sum (rgb) and weight (w) of the 4x4 cascade-0 probes round probe-grid point g, `stride` probes apart: a
// smooth distance falloff (bilinear-wide at stride 1) x plane/normal similarity, each probe evaluated for normal n.
inline float4 rcGather(constant RCParams& p, texture2d<float, access::read> probePos, texture2d<float, access::read> probeNs,
                       texture2d<float, access::read> shR, texture2d<float, access::read> shG,
                       texture2d<float, access::read> shB, float2 g, int stride, float3 x, float3 n, float depth) {
    int2 base = (int2(floor(g / float(stride))) - 1) * stride;   // on the stride's own lattice: no flip cell to cell
    float3 sum = float3(0.0f);
    float wsum = 0.0f;
    float scale = 0.8f / float(stride * stride);
    for (int k = 0; k < 16; ++k) {
        int2 qi = base + int2(k & 3, k >> 2) * stride;
        if (any(qi < 0) || qi.x >= int(p.grids.x) || qi.y >= int(p.grids.y)) continue;
        uint2 q = uint2(qi);
        float4 qp = probePos.read(q);
        if (qp.w <= 0.0f) continue;
        float2 d = float2(qi) - g;
        float falloff = exp(-dot(d, d) * scale);
        float w = falloff * rcProbeWeight(qp, probeNs.read(q).xyz, x, n, depth) + 1e-6f * falloff;
        sum += float3(rcEvalSH(shR.read(q), n), rcEvalSH(shG.read(q), n), rcEvalSH(shB.read(q), n)) * w;
        wsum += w;
    }
    return float4(sum, wsum);
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
                            texture2d<float, access::read>  prevND     [[texture(10)]],  // last frame's normal + depth
                            texture2d<float, access::read>  prevHistory [[texture(11)]], // last frame's outHistory
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
    float4 near = rcGather(p, probePos, probeNs, shR, shG, shB, g, 1, sp.xyz, n, nd.w);
    float wsum = near.w;
    float3 indirect = near.w > 0.0f ? near.rgb / near.w : float3(0.0f);
    // In the interiors' box the probes' rays move every frame (rcTraceMergeKernel): average them where this point was
    // on screen last frame (interval.w: there is a last frame), filtered (lastFrameHistory), over as many frames as
    // the point has been seen (alpha: up to 1 / RC_INTERIOR_BLEND), so a point just come into view settles in a few
    // frames instead of showing this frame's rays alone for ten. Until then it also takes in the probes twice as far
    // round it (fading out as its frames add up): a turning camera brings walls in at the screen's edge every frame,
    // and their few frames of jittered rays were cloudy blotches over most of the view. Elsewhere: no history.
    float frames = 1.0f;
    float4 h = float4(0.0f);
    if (p.interval.w > 0.0f && inInteriorBox(u.interiorLo, u.interiorHi, sp.xyz)) {
        bool seen = lastFrameHistory(u, sp.xyz, n, prevND, prevHistory, h);
        if (seen) frames = min(max(h.a, 1.0f) + 1.0f, 1.0f / RC_INTERIOR_BLEND);
        float young = 1.0f - (frames - 1.0f) / (1.0f / RC_INTERIOR_BLEND - 1.0f);
        if (young > 0.0f) {
            float4 wide = rcGather(p, probePos, probeNs, shR, shG, shB, g, 2, sp.xyz, n, nd.w);
            if (wide.w > 0.0f) indirect = mix(indirect, wide.rgb / wide.w, young);
        }
        if (seen) indirect = mix(h.rgb, indirect, 1.0f / frames);
    }
    outIndirect.write(float4(indirect, 1.0f), tid);
    outHistory.write(float4(indirect, frames), tid);
    // Debug: probe grid lines over the strongest weight's confidence (dark = no good probe nearby).
    bool grid = any(fmod(float2(tid), float(p.layout.x)) < 1.0f);
    giDebug.write(float4(grid ? float3(0.25f) : float3(saturate(wsum)), 1.0f), tid);
}
