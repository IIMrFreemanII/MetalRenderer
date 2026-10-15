// ---------------------------------------------------------------------------------------------
// 1g. ReSTIR GI (Ouyang et al. 2021): indirect light from one path per pixel (or per 2x2 block), whose first bounce is
//     reused over time (and optionally across neighbouring pixels). A sample is the path's first hit x_s (its normal
//     n_s, toward the side the path came from) and the light Lo leaving x_s. Secondary hits shade as diffuse (hitAlbedo
//     doesn't depend on the direction), so Lo is the same toward any pixel and reconnecting another pixel to x_s is
//     exact. Samples live in area measure on x_s, like a virtual point light: a pixel's integrand is
//     Lo k(w) cos_s / d^2 V, where k is the path tracer's own direction pdf (cosine about the shading normal, mirrored
//     above the triangle), so a fresh sample's estimate is exactly the path tracer's. A sky miss is a direction
//     (solid-angle measure). Per frame:
//       restirGIInitialKernel   the path (bounces, next-event estimation and sky as traceKernel's), as a reservoir
//                               with M = 1, W = 1 / pdf. Multi-bounce feedback: the path's last hit adds last frame's
//                               indirect light where it was on screen, else last frame's mean (as the radiance
//                               cascades). Quarter budget: one thread per 2x2 block traces a rotating pixel.
//       restirGITemporalKernel  last frame's reservoir (reprojected, nearest pixel), combined by confidence (both
//                               targets at this frame's surface), M capped; samples older than maxAge of the pixel's
//                               fresh paths are dropped (their Lo was lit by old lights).
//       restirGISpatialKernel   0-2 passes, each combining `spatialSamples` neighbours on the same surface (pairwise MIS
//                               with confidence weights; unbiased: visibility in the targets, two rays per neighbour);
//                               the last pass traces one visibility ray to the pick (none if it's known visible) and
//                               writes `indirect` (albedo divided out).
//     Without feedback, accumulated frames match the path tracer's (METALRENDERER_BENCH=restirgicheck). SVGF then
//     denoises `indirect`.
// ---------------------------------------------------------------------------------------------

struct RestirGIParams {
    uint4  config;   // x = RGI_* flags, y = max M, z = spatial samples, w = spatial pass index
    float4 tuning;   // x = spatial radius (pixels), y = minimum distance in the target (m), z = firefly clamp (0 = off)
    uint4  extra;    // x = 1: quarter budget, y = bounces, z = max sample age (frames)
};

constant uint RGI_TEMPORAL_VALID = 1, RGI_SHADE = 2, RGI_LIGHT_MAPS = 4, RGI_FEEDBACK = 8, RGI_UNBIASED = 16,
              RGI_KEEP_FEEDBACK = 32, RGI_FALLBACK = 64;
// FEEDBACK is off on a history's first frame; FEEDBACK_SET is the setting, the same every frame (so it can be compiled in).
constant uint RGI_FEEDBACK_SET = 128;
// Made from `extra`, for restirGIInitialKernel's compiled-in flags (GPURestirGIParams.initialPassFlags makes the same word).
constant uint RGI_QUARTER = 256, RGI_ONE_BOUNCE = 512;
constant uint RGI_AMBIENT_SCALE = 256;   // fixed point of the mean-indirect-light sums (rgb), RGI_AMBIENT_STRIDE^2 apart
constant uint RGI_AMBIENT_STRIDE = 8;
constant uint RGI_MAX_SPATIAL = 8;
// VISIBLE: known visible from this reservoir's pixel this frame (its own path found it, or a ray tested it).
constant uint GI_SAMPLE_SKY = 1, GI_SAMPLE_VISIBLE = 2;

struct GIReservoir {
    float3 pos;     // x_s (GI_SAMPLE_SKY: the direction)
    float3 n;       // n_s
    float3 Lo;      // light leaving x_s toward the pixels (x_s's albedo included)
    float  W;       // contribution weight
    float  M;       // confidence; 0 = empty
    uint   age;     // its pixel's fresh paths since its own (frames, with the full budget)
    uint   flags;
};

inline GIReservoir emptyGIReservoir() {
    GIReservoir r;
    r.pos = float3(0.0f); r.n = float3(0.0f, 1.0f, 0.0f); r.Lo = float3(0.0f); r.W = 0.0f; r.M = 0.0f; r.age = 0; r.flags = 0;
    return r;
}
// A: rgba32F = x_s, W. B: rgba32Uint = octahedral n_s, half Lo, M (12 bits) | age (8 bits) << 12 | flags << 20.
inline uint4 packGIReservoirB(GIReservoir r) {
    float3 lo = min(r.Lo, float3(65000.0f));   // half range
    return uint4(pack_float_to_unorm2x16(equalAreaOctEncode(r.n) * 0.5f + 0.5f), as_type<uint>(half2(lo.rg)),
                 as_type<uint>(half2(half(lo.b), 0.0h)), min(uint(r.M + 0.5f), 0xFFFu) | (min(r.age, 0xFFu) << 12) | (r.flags << 20));
}
inline GIReservoir unpackGIReservoir(float4 a, uint4 b) {
    GIReservoir r;
    r.pos = a.xyz; r.W = a.w;
    r.n = equalAreaOctDecode(unpack_unorm2x16_to_float(b.x) * 2.0f - 1.0f);
    half2 rg = as_type<half2>(b.y), bl = as_type<half2>(b.z);
    r.Lo = float3(float(rg.x), float(rg.y), float(bl.x));
    r.M = float(b.w & 0xFFFu); r.age = (b.w >> 12) & 0xFFu; r.flags = b.w >> 20;
    return r;
}
inline GIReservoir readGIReservoir(texture2d<float, access::read> a, texture2d<uint, access::read> b, uint2 q) {
    return unpackGIReservoir(a.read(q), b.read(q));
}
inline void writeGIReservoir(texture2d<float, access::write> a, texture2d<uint, access::write> b, uint2 q, GIReservoir r) {
    a.write(float4(r.pos, r.W), q);
    b.write(packGIReservoirB(r), q);
}
// The stored precision, so a sample is evaluated the same wherever it is reused (including where it was made).
inline GIReservoir quantizeGIReservoir(GIReservoir r) { return unpackGIReservoir(float4(r.pos, r.W), packGIReservoirB(r)); }

// The receiving surface at pixel q (false: sky or an emitter, no GI). p is the paths' origin (offset off the triangle).
struct GIReceiver {
    float3 p, n, ng;
    float  depth;
};
inline bool giReceiver(uint2 q, texture2d<float, access::read> surfacePos, texture2d<float, access::read> normalDepth,
                       texture2d<float, access::read> geoNormal, thread GIReceiver& rc) {
    float4 pos = surfacePos.read(q);
    if (pos.w <= 0.0f) return false;
    float4 nd = normalDepth.read(q);
    rc.n = normalize(nd.xyz);
    rc.depth = nd.w;
    rc.ng = geoNormal.read(q).xyz;
    rc.p = pos.xyz + rc.ng * RAY_EPSILON;
    return true;
}

// The path tracer's pdf of bounce direction w: cosine about the shading normal n, with directions below the triangle
// (geometric normal ng) mirrored above it. ReSTIR GI weighs Lo by it in place of cos / pi, so it estimates exactly what
// traceKernel's paths do.
inline float giLobe(float3 n, float3 ng, float3 w) {
    float c = dot(w, ng);
    if (c <= 0.0f) return 0.0f;
    return (max(dot(n, w), 0.0f) + max(dot(n, w - 2.0f * c * ng), 0.0f)) * M_1_PI_F;
}

// k(w) cos_s / d^2 of sample r at receiver rc (a sky sample: k(w)). dMin2 floors d^2 (the target's; 0 = the estimate's).
inline float giGeometry(GIReservoir r, thread const GIReceiver& rc, float dMin2) {
    if ((r.flags & GI_SAMPLE_SKY) != 0) return giLobe(rc.n, rc.ng, r.pos);
    float3 v = r.pos - rc.p;
    float d2 = dot(v, v);
    if (d2 <= 0.0f) return 0.0f;
    float3 w = v * rsqrt(d2);
    return giLobe(rc.n, rc.ng, w) * max(-dot(r.n, w), 0.0f) / max(d2, dMin2);
}
inline float giTarget(GIReservoir r, thread const GIReceiver& rc, float dMin2) {
    return r.M > 0.0f ? luminance(r.Lo) * giGeometry(r, rc, dMin2) : 0.0f;
}
// Shadow ray from receiver point p to sample r.
inline bool giSampleVisible(float3 p, GIReservoir r, SCENE_ACCEL accel) {
    if ((r.flags & GI_SAMPLE_SKY) == 0) return isVisible(p, r.pos + r.n * RAY_EPSILON, accel, RAY_GI);
    float t;
    return !intersectAny(makeRay(p, r.pos, 0.0f, INFINITY), rayMask(MASK_GEOMETRY, RAY_GI), accel, t);
}

kernel void restirGIInitialKernel(constant Uniforms&               u          [[buffer(0)]],
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
                                  constant RestirGIParams&         gp         [[buffer(9)]],
                                  texture2d<float, access::read>   surfacePos [[texture(0)]],
                                  texture2d<float, access::read>   normalDepth [[texture(1)]],
                                  texture2d<float, access::read>   geoNormal  [[texture(2)]],
                                  texture2d<float, access::read>   blueNoise  [[texture(3)]],
                                  texture2d_array<float, access::read> lightMap [[texture(4)]],   // with RGI_LIGHT_MAPS
                                  texture2d<float, access::read>   prevND     [[texture(5)]],     // with RGI_FEEDBACK
                                  texture2d<float, access::read>   feedback   [[texture(6)]],     // with RGI_FEEDBACK: last frame's indirect
                                  device const uint*               ambient    [[buffer(10)]],     // with RGI_FALLBACK: last frame's mean
                                  texture2d<float, access::write>  outA       [[texture(7)]],
                                  texture2d<uint, access::write>   outB       [[texture(8)]],
                                  uint2 gid [[thread_position_in_grid]])
{
    uint2 tid = gid;
    uint own = gp.config.x | (gp.extra.x != 0 ? RGI_QUARTER : 0u) | (gp.extra.y <= 1 ? RGI_ONE_BOUNCE : 0u);
    bool quarter = passOn(own, RGI_QUARTER);
    if (quarter) {
        // One pixel of each 2x2 block per frame, in the order (0,0), (1,1), (1,0), (0,1).
        uint2 base = gid * 2u;
        if (base.x >= u.width || base.y >= u.height) return;
        uint k = u.frameIndex & 3u;
        tid = base + uint2(((k + 1u) >> 1) & 1u, k & 1u);
        for (uint j = 0; j < 4; ++j) {
            uint2 q = base + uint2(j & 1u, j >> 1);
            if (any(q != tid) && q.x < u.width && q.y < u.height) writeGIReservoir(outA, outB, q, emptyGIReservoir());
        }
    }
    if (tid.x >= u.width || tid.y >= u.height) return;
    GIReceiver rc;
    if (!giReceiver(tid, surfacePos, normalDepth, geoNormal, rc)) {
        writeGIReservoir(outA, outB, tid, emptyGIReservoir());
        return;
    }
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);

    // The window is per block with the quarter budget, so the traced pixels' samples stay well spread; the dimensions
    // start past traceKernel's, the reflections' and the direct-light kernels'.
    Sampler rng = makeSampler(blueNoise, u, gid, 128, pixelSeed(tid, u.frameIndex, SEED_RESTIR_GI));

    // The path, as traceKernel's: its first hit is the sample, the rest is the light leaving it.
    GIReservoir r = emptyGIReservoir();
    r.M = 1.0f;
    r.flags = GI_SAMPLE_VISIBLE;
    float3 d = sampleBounce(rc.n, rc.ng, rng.next2());
    Surface h = traceSurface(makeRay(rc.p, d, 0.0f, INFINITY), rayMask(MASK_GEOMETRY, RAY_GI), accel, s, GI_RAY_SPREAD);
    float3 Lo = float3(0.0f);
    if (!h.hit) {
        r.flags |= GI_SAMPLE_SKY;
        r.pos = d;
        Lo = skyRadiance(u, s, d, 2.0f);
    } else {
        float3 hng, hn;
        orientNormals(h, d, hng, hn);
        r.pos = h.position;
        r.n = hng;
        float3 throughput = float3(1.0f);
        uint bounces = passOn(own, RGI_ONE_BOUNCE) ? 1u : gp.extra.y;
        for (uint b = 0; ; ++b) {
            Lo += throughput * giEmission(h);
            throughput *= hitAlbedo(h);   // Lambert BRDF * cos / cosine pdf = albedo (+ specular, as diffuse)
            float3 hp = h.position + hng * RAY_EPSILON;
            if (LIGHT_TABLE) {
                Rng lr;
                lr.state = pcgHash(tid.x + pcgHash(tid.y + pcgHash(u.frameIndex * 8u + b + 0x3C6EF372u)));
                Lo += throughput * sampleLightsRIS(lights, u.lightCount, u.lightTable, hp, hn, hng, 4, lr, accel, s);
            } else if (passOn(own, RGI_LIGHT_MAPS)) {
                uint seed = pcgHash(tid.x + pcgHash(tid.y + pcgHash(u.frameIndex * 8u + b + 0x2545F491u)));
                Lo += throughput * lightIllumCached(lights, u.lightCount, lightMap, hp, hn, hng, seed, u.flags, s);   // no rays
            } else if (u.lightCount > 0) {
                float pdf;
                float uPick = rng.next();
                float uSubset = u.lightCount > LIGHT_CANDIDATES ? rng.next() : 0.0f;
                uint li = pickLight(lights, u.lightCount, hp, hn, hng, uPick, uSubset, pdf);
                float2 lu = rng.next2();
                if (li < u.lightCount) Lo += throughput * sampleLight(lights[li], hp, hn, hng, lu, accel, s) / pdf;
            }
            if (all(throughput < 0.01f)) break;
            if (b + 1 >= bounces) {
                // Multi-bounce: the path's last hit adds last frame's indirect light where it was on screen (elsewhere,
                // with RGI_FALLBACK, last frame's mean indirect light, as the radiance cascades do).
                if (passOn(own, RGI_FEEDBACK_SET) && (own & RGI_FEEDBACK) != 0) {
                    uint2 q;
                    bool found = lastFramePixel(u, h.prevPosition, hn, prevND, q);
                    if (found) Lo += throughput * feedback.read(q).rgb;
                    if (!found && passOn(own, RGI_FALLBACK) && ambient[3] > 0)
                        Lo += throughput * float3(ambient[0], ambient[1], ambient[2]) / float(RGI_AMBIENT_SCALE * ambient[3]);
                }
                break;
            }
            d = sampleBounce(hn, hng, rng.next2());
            h = traceSurface(makeRay(hp, d, 0.0f, INFINITY), rayMask(MASK_GEOMETRY, RAY_GI), accel, s, GI_RAY_SPREAD);
            if (!h.hit) {
                Lo += throughput * skyRadiance(u, s, d, 2.0f);
                break;
            }
            orientNormals(h, d, hng, hn);
        }
    }
    Lo *= fireflyScale(u, luminance(Lo));
    r.Lo = Lo;
    r = quantizeGIReservoir(r);
    // One candidate: W = 1 / pdf, the pdf in area measure (k(w) cos_s / d^2) or solid angle (sky).
    float g = giGeometry(r, rc, 0.0f);
    r.W = g > 0.0f && luminance(r.Lo) > 0.0f ? 1.0f / g : 0.0f;
    writeGIReservoir(outA, outB, tid, r);
}

kernel void restirGITemporalKernel(constant Uniforms&                 u          [[buffer(0)]],
                                   constant RestirGIParams&           gp         [[buffer(9)]],
                                   texture2d<float, access::read>     surfacePos [[texture(0)]],
                                   texture2d<float, access::read>     normalDepth [[texture(1)]],
                                   texture2d<float, access::read>     geoNormal  [[texture(2)]],
                                   texture2d<float, access::read>     motion     [[texture(3)]],
                                   texture2d<float, access::read>     prevND     [[texture(4)]],
                                   texture2d<float, access::read>     initialA   [[texture(5)]],
                                   texture2d<uint, access::read>      initialB   [[texture(6)]],
                                   texture2d<float, access::read>     historyA   [[texture(7)]],
                                   texture2d<uint, access::read>      historyB   [[texture(8)]],
                                   texture2d<float, access::write>    outA       [[texture(9)]],
                                   texture2d<uint, access::write>     outB       [[texture(10)]],
                                   device atomic_uint*                ambient    [[buffer(10)]],   // this frame's mean: cleared here
                                   uint2 tid [[thread_position_in_grid]])
{
    if (all(tid == uint2(0))) for (uint i = 0; i < 4; ++i) atomic_store_explicit(&ambient[i], 0u, memory_order_relaxed);
    if (tid.x >= u.width || tid.y >= u.height) return;
    GIReceiver rc;
    if (!giReceiver(tid, surfacePos, normalDepth, geoNormal, rc)) {
        writeGIReservoir(outA, outB, tid, emptyGIReservoir());
        return;
    }
    GIReservoir r = readGIReservoir(initialA, initialB, tid);
    // Last frame's pixel (nearest, same surface).
    int2 c = passOn(gp.config.x, RGI_TEMPORAL_VALID) ? reprojectNearest(u, motion.read(tid), rc.n, prevND) : int2(-1);
    if (c.x >= 0) {
        GIReservoir h = readGIReservoir(historyA, historyB, uint2(c));
        h.M = min(h.M, float(gp.config.y));
        h.flags &= ~GI_SAMPLE_VISIBLE;
        // Age counts the pixel's fresh paths since the sample's (the quarter budget's come every 4th frame).
        // Too old (lit by old lights): replaced by this frame's path. Dropping long-lived samples is biased
        // (they are the bright ones that keep winning), so maxAge is a compromise with moving lights.
        if (r.M > 0.0f) {
            h.age += 1;
            if (h.age > gp.extra.z) h.M = 0.0f;
        }
        if (h.M > 0.0f) {
            // Generalized balance heuristic over the two domains, last frame's target approximated at this
            // frame's surface: the weights reduce to the confidences.
            Rng rng;
            rng.state = pixelSeed(tid, u.frameIndex, SEED_RESTIR_GI_HISTORY);
            float dMin2 = gp.tuning.y * gp.tuning.y;
            float cc = giTarget(r, rc, dMin2), hc = giTarget(h, rc, dMin2);
            float Msum = r.M + h.M;
            float wc = r.M / Msum * cc * r.W, wh = h.M / Msum * hc * h.W;
            float sum = wc + wh, target = cc;
            if (sum > 0.0f && rng.next() * sum < wh) {
                r = h;
                target = hc;
            }
            r.W = target > 0.0f ? sum / target : 0.0f;
            r.M = min(Msum, float(gp.config.y));
        }
    }
    writeGIReservoir(outA, outB, tid, r);
}

kernel void restirGISpatialKernel(constant Uniforms&                 u          [[buffer(0)]],
                                  SCENE_ACCEL                        accel      [[buffer(1)]],
                                  constant RestirGIParams&           gp         [[buffer(9)]],
                                  texture2d<float, access::read>     surfacePos [[texture(0)]],
                                  texture2d<float, access::read>     normalDepth [[texture(1)]],
                                  texture2d<float, access::read>     geoNormal  [[texture(2)]],
                                  texture2d<float, access::read>     inA        [[texture(3)]],
                                  texture2d<uint, access::read>      inB        [[texture(4)]],
                                  texture2d<float, access::write>    outA       [[texture(5)]],
                                  texture2d<uint, access::write>     outB       [[texture(6)]],
                                  texture2d<float, access::write>    outIndirect [[texture(7)]],   // with RGI_SHADE
                                  texture2d<float, access::write>    outDebug   [[texture(8)]],    // with RGI_SHADE, view "GI debug"
                                  texture2d<float, access::write>    outFeedback [[texture(9)]],   // with RGI_SHADE and RGI_KEEP_FEEDBACK
                                  device atomic_uint*                ambient    [[buffer(10)]],   // with RGI_SHADE and RGI_FALLBACK
                                  uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    bool shade = passOn(gp.config.x, RGI_SHADE), debug = shade && u.viewMode == 7;
    bool keepFeedback = shade && passOn(gp.config.x, RGI_KEEP_FEEDBACK), unbiased = passOn(gp.config.x, RGI_UNBIASED);
    GIReceiver rc;
    if (!giReceiver(tid, surfacePos, normalDepth, geoNormal, rc)) {
        writeGIReservoir(outA, outB, tid, emptyGIReservoir());
        if (shade) outIndirect.write(float4(0.0f), tid);
        if (debug) outDebug.write(float4(0.0f), tid);
        if (keepFeedback) outFeedback.write(float4(0.0f), tid);
        return;
    }
    float dMin2 = gp.tuning.y * gp.tuning.y, maxM = float(gp.config.y);
    Rng rng;
    rng.state = pcgHash(tid.x * 9781u + pcgHash(tid.y + pcgHash(u.frameIndex * 7u + gp.config.w + 0x1B873593u)));

    // Neighbours on the same surface, in a disk.
    uint wanted = min(gp.config.z, RGI_MAX_SPATIAL), count = 0;
    GIReceiver nrc[RGI_MAX_SPATIAL];
    GIReservoir nb[RGI_MAX_SPATIAL];
    float Msum = 0.0f;
    for (uint i = 0; i < wanted; ++i) {
        int2 q;
        if (!diskNeighbour(tid, gp.tuning.x, u, rng, q)) continue;
        GIReceiver qr;
        if (!giReceiver(uint2(q), surfacePos, normalDepth, geoNormal, qr)) continue;
        if (abs(qr.depth - rc.depth) > REUSE_DEPTH * rc.depth || dot(qr.n, rc.n) < REUSE_NORMAL) continue;
        GIReservoir qs = readGIReservoir(inA, inB, uint2(q));
        if (qs.M <= 0.0f) continue;
        nrc[count] = qr;
        nb[count] = qs;
        Msum += qs.M;
        count++;
    }

    GIReservoir r = readGIReservoir(inA, inB, tid);
    if (count > 0) {
        // Pairwise MIS with confidence weights: each neighbour's technique is weighed against the canonical one's share
        // M_c / n; every sample's weights sum to 1, so the result stays unbiased (for the target).
        Msum += r.M;
        float cShare = r.M / float(count);
        float cc = giTarget(r, rc, dMin2);
        float mc = 0.0f, wSum = 0.0f, target = cc;
        GIReservoir picked = r;
        for (uint j = 0; j < count; ++j) {
            // Unbiased: the targets include visibility. A neighbour's samples are its paths' hits, all visible from it:
            // its technique can't make samples it doesn't see, and weighing light it can't see as if it could darkens
            // (~8% in the stress hall). And here, a neighbour's sample this pixel can't see would be a wasted pick
            // (with it, spatial reuse added noise). Two rays per neighbour; samples stay visible from their pixel.
            float jc = giTarget(r, nrc[j], dMin2);       // the canonical sample at the neighbour
            if (unbiased && jc > 0.0f && !giSampleVisible(nrc[j].p, r, accel)) jc = 0.0f;
            float jj = giTarget(nb[j], nrc[j], dMin2);
            float cj = giTarget(nb[j], rc, dMin2);       // the neighbour's sample here
            if (unbiased && cj > 0.0f && !giSampleVisible(rc.p, nb[j], accel)) cj = 0.0f;
            float2 mis = pairwiseMIS(nb[j].M, cShare, Msum, cc, jc, jj, cj);
            mc += mis.x;
            float w = mis.y * cj * nb[j].W;
            if (w <= 0.0f) continue;
            wSum += w;
            if (rng.next() * wSum < w) {
                picked = nb[j];
                picked.flags = unbiased ? picked.flags | GI_SAMPLE_VISIBLE : picked.flags & ~GI_SAMPLE_VISIBLE;
                target = cj;
            }
        }
        float wc = mc * cc * r.W;
        wSum += wc;
        if (wc > 0.0f && rng.next() * wSum < wc) { picked = r; target = cc; }
        r = picked;
        r.W = target > 0.0f && wSum > 0.0f ? wSum / target : 0.0f;
        r.M = min(Msum, maxM);
    }
    // Unbiased: last frame's sample, if the surface moved, may no longer be visible from it (W = 0 then, so samples
    // stay visible from their pixel).
    bool tested = false, visible = (r.flags & GI_SAMPLE_VISIBLE) != 0;
    if (unbiased && !visible && r.W > 0.0f) {
        tested = true;
        visible = giSampleVisible(rc.p, r, accel);
        if (visible) r.flags |= GI_SAMPLE_VISIBLE; else r.W = 0.0f;
    }
    writeGIReservoir(outA, outB, tid, r);
    if (!shade) return;

    // One visibility ray to the pick (none if its pixel's own path found it, or it was tested above).
    float3 L = float3(0.0f);
    if (r.M > 0.0f && r.W > 0.0f) {
        float g = giGeometry(r, rc, 0.0f);
        if (g > 0.0f) {
            if (!visible && !tested) visible = giSampleVisible(rc.p, r, accel);
            if (visible) L = r.Lo * (g * r.W);
        }
    }
    L *= fireflyScale(luminance(L), gp.tuning.z);
    outIndirect.write(roundToHalf(float4(L, 1.0f)), tid);
    if (keepFeedback) outFeedback.write(roundToHalf(float4(L, 1.0f)), tid);
    if (passOn(gp.config.x, RGI_FALLBACK) && all(tid % RGI_AMBIENT_STRIDE == 0u)) {
        // The mean indirect light over the GI pixels (a sparse grid of them), for next frame's off-screen path ends.
        uint3 v = uint3(L * float(RGI_AMBIENT_SCALE) + 0.5f);
        for (uint i = 0; i < 3; ++i) atomic_fetch_add_explicit(&ambient[i], v[i], memory_order_relaxed);
        atomic_fetch_add_explicit(&ambient[3], 1u, memory_order_relaxed);
    }
    if (debug) outDebug.write(float4(r.M / maxM, float(r.age) / float(max(gp.extra.z, 1u)), (r.flags & GI_SAMPLE_VISIBLE) != 0 ? 1.0f : 0.0f, 1.0f), tid);
}
