// ---------------------------------------------------------------------------------------------
// 6. The lens and the finish (PostSettings), on the frame's light at the output resolution: the composite's (FLAG_POST)
//    or MetalFX's denoising scaler's. In this order, each only while it is on:
//      focusKernel      autofocus: the depth at the centre of the frame, eased into a one-float buffer
//      dofKernel        depth of field: a disc gather whose taps each blur as far as their own circle of confusion
//      bloomDownKernel  glow: halvings of the light above a soft threshold (13 taps, Jimenez 2014), the first one with
//                       Karis's average so a lone bright pixel doesn't flicker into a blob
//      bloomUpKernel    ...and back up, each level plus a tent filter of the one below
//      finishKernel     chromatic aberration, the glow, the exposure and the tone curve, vignette, film grain: the drawable
//    Every kernel gets the Uniforms at buffer 0 and PostParams at buffer 1.
// ---------------------------------------------------------------------------------------------

constexpr sampler postSampler(filter::linear, address::clamp_to_edge);

constant float POST_SKY_DEPTH = 1e4f;   // what the sky (depth 0 in normalDepth) counts as

/// The view depth at output pixel `p` (normalDepth is at the traced resolution).
inline float postDepth(constant PostParams& p, texture2d<float, access::read> nd, float2 pixel) {
    uint2 at = min(uint2(pixel * float2(p.size.zw) / float2(p.size.xy)), p.size.zw - 1);
    float d = nd.read(at).w;
    return d > 0.0f ? d : POST_SKY_DEPTH;
}

/// The nearest of the four traced pixels round output pixel `p`: an edge pixel whose colour is part foreground counts as
/// the foreground, so a sharp silhouette keeps its anti-aliased edge instead of the traced pixels' steps.
inline float postNearestDepth(constant PostParams& p, texture2d<float, access::read> nd, float2 pixel) {
    float2 at = pixel * float2(p.size.zw) / float2(p.size.xy) - 0.5f;
    int2 lo = int2(floor(at)), top = int2(p.size.zw) - 1;
    float d = POST_SKY_DEPTH;
    for (int i = 0; i < 4; ++i) {
        float v = nd.read(uint2(clamp(lo + int2(i & 1, i >> 1), int2(0), top))).w;
        if (v > 0.0f) d = min(d, v);
    }
    return d;
}

/// Signed blur radius (output pixels) at view depth `d`: < 0 in front of the focus, > 0 behind.
inline float circleOfConfusion(constant PostParams& p, float focus, float d) {
    return clamp(p.lens.x * (1.0f - focus / d), -p.lens.z, p.lens.z);
}

kernel void focusKernel(constant Uniforms&               u     [[buffer(0)]],
                        constant PostParams&             p     [[buffer(1)]],
                        device float*                    focus [[buffer(2)]],
                        texture2d<float, access::read>   nd    [[texture(0)]],
                        uint2 tid [[thread_position_in_grid]])
{
    if (any(tid != 0)) return;
    float target = p.lens.y;
    if (target <= 0.0f) {
        // The median of a 3x3 patch at the centre: a thin thing crossing it doesn't pull the focus.
        float d[9];
        float2 c = float2(p.size.xy) * 0.5f, step = float2(p.size.y) * 0.02f;
        for (int i = 0; i < 9; ++i) d[i] = min(postDepth(p, nd, c + float2(i % 3 - 1, i / 3 - 1) * step), 100.0f);
        for (int i = 1; i < 9; ++i) for (int j = i; j > 0 && d[j - 1] > d[j]; --j) { float t = d[j]; d[j] = d[j - 1]; d[j - 1] = t; }
        target = d[4];
        float last = focus[0];
        if (last > 0.0f) target = mix(last, target, p.lens.w);   // eased in: a pan doesn't snap the focus
    }
    focus[0] = target;
}

kernel void dofKernel(constant Uniforms&               u      [[buffer(0)]],
                      constant PostParams&             p      [[buffer(1)]],
                      device const float*              focus  [[buffer(2)]],
                      texture2d<float, access::sample> input  [[texture(0)]],
                      texture2d<float, access::read>   nd     [[texture(1)]],
                      texture2d<float, access::write>  output [[texture(2)]],
                      uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= p.size.x || tid.y >= p.size.y) return;
    float2 size = float2(p.size.xy), pixel = float2(tid) + 0.5f;
    float f = max(focus[0], 0.05f);
    float d0 = postNearestDepth(p, nd, pixel), c0 = circleOfConfusion(p, f, d0);
    float3 centre = input.sample(postSampler, pixel / size).rgb;
    // The disc that can reach this pixel: as wide as the widest blur behind (a near blur can be wider, rarely).
    float radius = min(p.lens.z, max(abs(c0), p.lens.x));
    if (radius < 0.5f) { output.write(float4(centre, 1.0f), tid); return; }
    // Each tap counts where its own circle covers this pixel, its light spread over its circle's area. A tap behind
    // this pixel can't blur over it by more than this pixel's own circle: a sharp thing in front keeps its edge.
    float w0 = 1.0f / max(c0 * c0, 1.0f);
    float3 sum = centre * w0;
    float weight = w0;
    int taps = clamp(int(radius * radius * 0.35f), 8, 64);
    const float golden = 2.39996323f;
    for (int i = 0; i < taps; ++i) {
        float r = sqrt((float(i) + 0.5f) / float(taps)) * radius, a = float(i) * golden;
        float2 offset = float2(cos(a), sin(a)) * r, at = pixel + offset;
        float d = postDepth(p, nd, at), c = abs(circleOfConfusion(p, f, d));
        if (d > d0) c = min(c, abs(c0));
        float cover = saturate(c - r + 1.0f);
        float w = cover / max(c * c, 1.0f);
        sum += input.sample(postSampler, at / size).rgb * w;
        weight += w;
    }
    output.write(float4(sum / weight, 1.0f), tid);
}

/// Bloom's soft threshold: what of `c` (exposed) glows, fading in over a knee half the threshold wide.
inline float3 bloomPrefilter(float3 c, float threshold) {
    float bright = max(c.r, max(c.g, c.b)), knee = max(threshold * 0.5f, 1e-4f);
    float soft = clamp(bright - threshold + knee, 0.0f, 2.0f * knee);
    soft = soft * soft / (4.0f * knee);
    return c * (max(soft, bright - threshold) / max(bright, 1e-4f));
}

/// `src` at `uv`, `x`, `y` of its texels away.
inline float3 postTap(texture2d<float, access::sample> src, float2 uv, float2 texel, float x, float y) {
    return src.sample(postSampler, uv + float2(x, y) * texel).rgb;
}

inline float karisWeight(float3 c) { return 1.0f / (1.0f + dot(c, float3(0.2126f, 0.7152f, 0.0722f))); }

kernel void bloomDownKernel(constant Uniforms&               u      [[buffer(0)]],
                            constant PostParams&             p      [[buffer(1)]],
                            texture2d<float, access::sample> src    [[texture(0)]],
                            texture2d<float, access::write>  dst    [[texture(1)]],
                            uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= dst.get_width() || tid.y >= dst.get_height()) return;
    float2 uv = (float2(tid) + 0.5f) / float2(dst.get_width(), dst.get_height());
    float2 t = 1.0f / float2(src.get_width(), src.get_height());
    float3 a = postTap(src, uv, t, -2, -2), b = postTap(src, uv, t, 0, -2), c = postTap(src, uv, t, 2, -2);
    float3 d = postTap(src, uv, t, -1, -1), e = postTap(src, uv, t, 1, -1);
    float3 f = postTap(src, uv, t, -2, 0), g = postTap(src, uv, t, 0, 0), h = postTap(src, uv, t, 2, 0);
    float3 i = postTap(src, uv, t, -1, 1), j = postTap(src, uv, t, 1, 1);
    float3 k = postTap(src, uv, t, -2, 2), l = postTap(src, uv, t, 0, 2), m = postTap(src, uv, t, 2, 2);
    float3 out;
    if (p.frame.y == 0) {
        // The first halving: the exposed light above the threshold, five boxes each weighed down by its brightness.
        float exposure = p.bloom.z;
        float3 box[5] = {(d + e + i + j) * 0.25f, (a + b + f + g) * 0.25f, (b + c + g + h) * 0.25f,
                         (f + g + k + l) * 0.25f, (g + h + l + m) * 0.25f};
        const float share[5] = {0.5f, 0.125f, 0.125f, 0.125f, 0.125f};
        float3 sum = 0.0f;
        float weight = 0.0f;
        for (int n = 0; n < 5; ++n) {
            float3 lit = bloomPrefilter(box[n] * exposure, p.bloom.y);
            float w = share[n] * karisWeight(lit);
            sum += lit * w;
            weight += w;
        }
        out = sum / max(weight, 1e-6f) / exposure;
    } else {
        out = (d + e + i + j) * 0.125f + (a + c + k + m) * 0.03125f + (b + f + h + l) * 0.0625f + g * 0.125f;
    }
    dst.write(float4(out, 1.0f), tid);
}

kernel void bloomUpKernel(constant Uniforms&               u      [[buffer(0)]],
                          constant PostParams&             p      [[buffer(1)]],
                          texture2d<float, access::sample> lower  [[texture(0)]],   // the level below, built up
                          texture2d<float, access::read>   level  [[texture(1)]],   // this level, from the halvings
                          texture2d<float, access::write>  dst    [[texture(2)]],
                          uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= dst.get_width() || tid.y >= dst.get_height()) return;
    float2 uv = (float2(tid) + 0.5f) / float2(dst.get_width(), dst.get_height());
    float2 t = 1.0f / float2(lower.get_width(), lower.get_height());
    float3 tent = postTap(lower, uv, t, -1, -1) + postTap(lower, uv, t, 1, -1) + postTap(lower, uv, t, -1, 1) + postTap(lower, uv, t, 1, 1)
        + 2.0f * (postTap(lower, uv, t, 0, -1) + postTap(lower, uv, t, -1, 0) + postTap(lower, uv, t, 1, 0) + postTap(lower, uv, t, 0, 1))
        + 4.0f * postTap(lower, uv, t, 0, 0);
    dst.write(float4(level.read(tid).rgb + tent / 16.0f, 1.0f), tid);
}

kernel void finishKernel(constant Uniforms&               u      [[buffer(0)]],
                         constant PostParams&             p      [[buffer(1)]],
                         texture2d<float, access::sample> input  [[texture(0)]],
                         texture2d<float, access::sample> bloom  [[texture(1)]],
                         texture2d<float, access::write>  output [[texture(2)]],
                         uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    float2 size = float2(p.size.xy), uv = (float2(tid) + 0.5f) / size;
    float2 fromCentre = uv - 0.5f;
    float3 c;
    if (p.finish.z > 0.0f) {
        // Red and blue focus a little apart, more toward the corners (where they are p.finish.z of the width apart).
        float2 shift = fromCentre * float2(1.0f, size.y / size.x) * p.finish.z * 1.4142f;
        c = float3(input.sample(postSampler, uv + shift).r, input.sample(postSampler, uv).g, input.sample(postSampler, uv - shift).b);
    } else {
        c = input.sample(postSampler, uv).rgb;
    }
    c = max(c, 0.0f);
    if (p.bloom.x > 0.0f) c = mix(c, bloom.sample(postSampler, uv).rgb / p.bloom.w, p.bloom.x);
    c = toneMap(c, u.post);
    if (p.finish.x > 0.0f) {
        float r2 = dot(fromCentre * float2(size.x / size.y, 1.0f), fromCentre * float2(size.x / size.y, 1.0f)) * 2.0f;
        c *= 1.0f - p.finish.x * smoothstep(0.15f, 1.6f, r2);
    }
    if (p.finish.y > 0.0f) {
        // Triangular noise, strongest in the mid-tones, on the display's (about square-root) scale.
        uint h = pixelSeed(tid, p.frame.x, 0x68E31DA4u);
        float n = (float(h & 0xFFFFu) + float(h >> 16)) / 65535.0f - 1.0f;
        float3 s = sqrt(saturate(c));
        float luma = dot(s, float3(0.2126f, 0.7152f, 0.0722f));
        s += n * p.finish.y * (0.4f + 2.4f * luma * (1.0f - luma));
        c = max(s, 0.0f) * max(s, 0.0f);
    }
    output.write(float4(saturate(c), 1.0f), tid);
}
