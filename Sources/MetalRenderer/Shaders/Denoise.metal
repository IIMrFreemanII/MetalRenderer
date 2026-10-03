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
    if (flagOn(u.flags, FLAG_HISTORY_VALID) && mv.w > 0.0f) {
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

    variance *= max(u.denoise.w, 1.0f);   // ReSTIR's reused samples are correlated: their variance looks too low
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
[[max_total_threads_per_threadgroup(64)]]   // the 8x8 group is the tile (plus its apron) below
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
            if (flagOn(u.flags, FLAG_HISTORY_VALID) && mv.w > 0.0f) {
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
