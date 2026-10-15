// Adjustments and blending (MatNodes: Adjustments, Blending): point-wise, each pixel from its inputs' at the same place.
// Colours keep their alpha; a grey's is 1.

template <typename P> inline float4 matLevels(float4 x, P p) {
    float3 v = saturate((x.rgb - p[0].x) / max(p[1].x - p[0].x, 1e-5));
    v = pow(v, 1.0 / max(p[2].x, 1e-3));
    return float4(mix(float3(p[3].x), float3(p[4].x), v), x.a);
}

template <typename P, typename L> inline float4 matCurve(float4 x, P p, L lut) {
    return float4(matLut(lut, p[0].x, x.r).r, matLut(lut, p[0].x, x.g).r, matLut(lut, p[0].x, x.b).r, x.a);
}

template <typename P, typename L> inline float4 matGradientMap(float4 x, P p, L lut) { return matLut(lut, p[0].x, x.r); }

inline float3 matRGBtoHSL(float3 c) {
    float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
    float l = (hi + lo) * 0.5, d = hi - lo;
    if (d < 1e-6) return float3(0, 0, l);
    float s = l > 0.5 ? d / (2.0 - hi - lo) : d / (hi + lo);
    float h = hi == c.r ? (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0) : hi == c.g ? (c.b - c.r) / d + 2.0 : (c.r - c.g) / d + 4.0;
    return float3(h / 6.0, s, l);
}
inline float matHue(float p, float q, float t) {
    t = fract(t);
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}
inline float3 matHSLtoRGB(float3 h) {
    if (h.y < 1e-6) return float3(h.z);
    float q = h.z < 0.5 ? h.z * (1.0 + h.y) : h.z + h.y - h.z * h.y, p = 2.0 * h.z - q;
    return float3(matHue(p, q, h.x + 1.0 / 3.0), matHue(p, q, h.x), matHue(p, q, h.x - 1.0 / 3.0));
}

template <typename P> inline float4 matHSL(float4 x, P p) {
    float3 h = matRGBtoHSL(saturate(x.rgb));
    h.x = fract(h.x + p[0].x);
    h.y = saturate(h.y * (1.0 + p[1].x));
    h.z = saturate(h.z + p[2].x * (p[2].x > 0 ? 1.0 - h.z : h.z));
    return float4(matHSLtoRGB(h), x.a);
}

template <typename P> inline float4 matGrayscale(float4 x, P p) {
    float v;
    switch (int(p[0].x)) {
        case 0: v = dot(x.rgb, MAT_LUMA); break;
        case 1: v = (x.r + x.g + x.b) / 3.0; break;
        case 2: v = x.r; break;
        case 3: v = x.g; break;
        case 4: v = x.b; break;
        default: v = x.a; break;
    }
    return float4(v, v, v, 1);
}

template <typename P> inline float4 matHistogramScan(float4 x, P p) {
    float w = (1.0 - p[1].x) * 0.5 + 1e-3, t = 1.0 - p[0].x;
    float v = smoothstep(t - w, t + w, x.r);
    if (p[2].x != 0) v = 1.0 - v;
    return float4(v, v, v, 1);
}

template <typename P> inline float4 matPosterize(float4 x, P p) {
    float n = max(p[0].x, 2.0);
    return float4(saturate(floor(x.rgb * n) / (n - 1.0)), x.a);
}

// MARK: - Blending

// Blend mode `mode` (MatBlendMode's order) of foreground f over background b, per channel.
inline float3 matBlendMode(int mode, float3 f, float3 b) {
    switch (mode) {
        case 0: return f;
        case 1: return f + b;
        case 2: return b - f;
        case 3: return f * b;
        case 4: return 1.0 - (1.0 - f) * (1.0 - b);
        case 5: return select(1.0 - 2.0 * (1.0 - f) * (1.0 - b), 2.0 * f * b, b < 0.5);
        case 6: return (1.0 - 2.0 * f) * b * b + 2.0 * f * b;
        case 7: return select(1.0 - 2.0 * (1.0 - f) * (1.0 - b), 2.0 * f * b, f < 0.5);
        case 8: return min(f, b);
        case 9: return max(f, b);
        case 10: return abs(f - b);
        case 11: return b / max(f, 1e-4);
        case 12: return b / max(1.0 - f, 1e-4);
        case 13: return 1.0 - (1.0 - b) / max(f, 1e-4);
        case 14: return b + 2.0 * f - 1.0;
        default: return f + b - 2.0 * f * b;
    }
}

template <typename P> inline float4 matBlend(float4 f, float4 b, float mask, P p) {
    float k = saturate(p[1].x * mask);
    return float4(mix(b.rgb, matBlendMode(int(p[0].x), f.rgb, b.rgb), k), mix(b.a, max(f.a, b.a), k));
}

// Height Blend: the top height (raised by `offset`) where it is above the bottom one, softly (`contrast`); the
// height and the mask of where the top shows.
template <typename P> inline float2 matHeightBlend(float top, float bottom, float mask, P p) {
    float t = top + (p[0].x - 0.5);
    float w = (1.0 - p[1].x) * 0.5 + 1e-3;
    float k = smoothstep(-w, w, t - bottom) * mask;
    return float2(mix(bottom, t, k), k);
}

template <typename P> inline float4 matNormalCombine(float4 base, float4 detail, P p) {
    float3 n1 = base.xyz * 2.0 - 1.0, n2 = detail.xyz * 2.0 - 1.0;
    float3 n = normalize(float3(n1.xy + n2.xy, n1.z * n2.z));
    return float4(n * 0.5 + 0.5, 1);
}

#if !MAT_EVAL_ONLY
kernel void mat_levels(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(matLevels(IN(0, uv), p), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_curve(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(matCurve(IN(0, uv), p, lut), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_gradientMap(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(matGradientMap(IN(0, uv), p, lut), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_hsl(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(matHSL(IN(0, uv), p), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_invert(MAT_KERNEL_ARGS) { MAT_PIXEL; float4 v = IN(0, uv); out0.write(float4(1.0 - v.rgb, v.a), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_grayscale(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(matGrayscale(IN(0, uv), p), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_histogramScan(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(matHistogramScan(IN(0, uv), p), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_posterize(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(matPosterize(IN(0, uv), p), gid); }
#endif

#if !MAT_EVAL_ONLY
kernel void mat_rgbaSplit(MAT_KERNEL_ARGS4) {
    MAT_PIXEL
    float4 v = IN(0, uv);
    out0.write(float4(v.r), gid);
    out1.write(float4(v.g), gid);
    out2.write(float4(v.b), gid);
    out3.write(float4(v.a), gid);
}
#endif

#if !MAT_EVAL_ONLY
kernel void mat_rgbaMerge(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float4 f = p[0];
    out0.write(float4(INOR(0, uv, f.rrrr).r, INOR(1, uv, f.gggg).r, INOR(2, uv, f.bbbb).r, INOR(3, uv, f.aaaa).r), gid);
}
#endif

#if !MAT_EVAL_ONLY
kernel void mat_blend(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float4 f = INOR(0, uv, float4(0, 0, 0, 1)), b = INOR(1, uv, float4(0, 0, 0, 1));
    float m = INOR(2, uv, float4(1)).r;
    out0.write(matBlend(f, b, m, p), gid);
}
#endif

#if !MAT_EVAL_ONLY
kernel void mat_heightBlend(MAT_KERNEL_ARGS, texture2d<float, access::write> out1 [[texture(9)]]) {
    MAT_PIXEL
    float2 v = matHeightBlend(INOR(0, uv, float4(0)).r, INOR(1, uv, float4(0)).r, INOR(2, uv, float4(1)).r, p);
    out0.write(float4(v.x), gid);
    out1.write(float4(v.y), gid);
}
#endif

#if !MAT_EVAL_ONLY
kernel void mat_normalCombine(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    out0.write(matNormalCombine(INOR(0, uv, float4(0.5, 0.5, 1, 1)), INOR(1, uv, float4(0.5, 0.5, 1, 1)), p), gid);
}
#endif
