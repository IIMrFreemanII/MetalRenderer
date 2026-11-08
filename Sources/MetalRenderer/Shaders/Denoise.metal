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
            if (abs(pnd.w - mv.z) > REUSE_DEPTH * mv.z) continue;   // depth mismatch -> disoccluded
            if (dot(pnd.xyz, nd.xyz) < REUSE_NORMAL) continue;      // normal mismatch
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

// Edge stopping on geometry, shared by the a-trous filters (illumination here, shadow visibility in 3b): the
// screen-space depth gradient at p, which makes the depth test tolerant on slanted surfaces, and a tap's weights
// (x = depth, y = normal: the cosine between the normals to `normalPower`).
inline float2 depthGradient(texture2d<float, access::read> nd, int2 p, int2 maxP, float depth) {
    float zr = nd.read(uint2(clamp(p + int2(1, 0), int2(0), maxP))).w;
    float zd = nd.read(uint2(clamp(p + int2(0, 1), int2(0), maxP))).w;
    return float2(zr > 0.0f ? zr - depth : 0.0f, zd > 0.0f ? zd - depth : 0.0f);
}
inline float2 geometryWeights(float4 cnd, float4 qnd, float2 depthGrad, float2 offset, float normalPower) {
    return float2(exp(-abs(cnd.w - qnd.w) / (abs(dot(depthGrad, offset)) + 0.01f * cnd.w + 1e-4f)),
                  pow(max(0.0f, dot(cnd.xyz, qnd.xyz)), normalPower));
}

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

    float2 depthGrad = depthGradient(nd, p, maxP, cnd.w);

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

            float2 wGeometry = geometryWeights(cnd, qnd, depthGrad, float2(dx, dy) * float(stepSize), 128.0f);
            float wLum = exp(-abs(centerLum - luminance(qc.rgb)) / phiL);
            float w = kernelWeights[abs(dx)] * kernelWeights[abs(dy)] * wGeometry.x * wGeometry.y * wLum;

            sumColor += qc.rgb * w;
            sumVariance += w * w * qc.a * qc.a;
            sumWeight += w;
        }
    }
    sumWeight = max(sumWeight, 1e-6f);
    outIllum.write(roundToHalf(float4(sumColor / sumWeight, sqrt(sumVariance) / sumWeight)), tid);
}
