// Filters (MatNodes: Filters): resampling (transform, mirror, warps) and neighbourhoods (blurs, edges).

// Where Transform reads its input for `uv`: about the middle, turned, tiled, then moved (it wraps).
template <typename P> inline float2 matTransformUV(float2 uv, P p) {
    return matRotate(uv - 0.5, -p[1].x) * p[2].xy + 0.5 - p[0].xy;
}

template <typename P> inline float2 matMirrorUV(float2 uv, P p) {
    int axis = int(p[0].x);
    float2 m = uv;
    if (axis != 1 && m.x > 0.5) m.x = 1.0 - m.x;
    if (axis != 0 && m.y > 0.5) m.y = 1.0 - m.y;
    return m;
}

// Warp: the input moved along the slope of a height (its change per UV, along U and V).
template <typename P> inline float2 matWarpUV(float2 uv, float2 slope, P p) { return uv - slope * p[0].x * 0.1; }

// Directional Warp: moved one way by `amount` × the intensity image.
template <typename P> inline float2 matDirectionalWarpUV(float2 uv, float intensity, P p) {
    return uv - float2(cos(p[1].x * MAT_TAU), sin(p[1].x * MAT_TAU)) * p[0].x * intensity;
}

#if !MAT_EVAL_ONLY
kernel void mat_transform(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(IN(0, matTransformUV(uv, p)), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_mirror(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(IN(0, matMirrorUV(uv, p)), gid); }
#endif

#if !MAT_EVAL_ONLY
kernel void mat_warp(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float2 t = 1.0 / float2(in1.get_width(), in1.get_height());
    float dx = INOR(1, uv + float2(t.x, 0), float4(0)).r - INOR(1, uv - float2(t.x, 0), float4(0)).r;
    float dy = INOR(1, uv + float2(0, t.y), float4(0)).r - INOR(1, uv - float2(0, t.y), float4(0)).r;
    out0.write(IN(0, matWarpUV(uv, float2(dx, dy) / (2.0 * t), p)), gid);
}
#endif

#if !MAT_EVAL_ONLY
kernel void mat_directionalWarp(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    out0.write(IN(0, matDirectionalWarpUV(uv, INOR(1, uv, float4(1)).r, p)), gid);
}
#endif

// Blur: a separable Gaussian, `radius` pixels (σ = radius / 2): pass 0 along X, 1 along Y (the engine's temporary
// between them). Past 24 pixels it steps two at a time, between pixels (the bilinear filter averages each pair).
#if !MAT_EVAL_ONLY
kernel void mat_blur(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float radius = p[0].x;
    if (radius < 0.5) { out0.write(IN(0, uv), gid); return; }
    float2 dir = a.pass == 0 ? float2(texel.x, 0) : float2(0, texel.y);
    float sigma = radius * 0.5;
    int taps = int(ceil(radius));
    float stride = taps > 24 ? 2.0 : 1.0;
    int n = int(ceil(float(taps) / stride));
    float4 sum = 0;
    float total = 0;
    for (int i = -n; i <= n; i++) {
        float o = float(i) * stride + (stride > 1.0 ? 0.5 * sign(float(i)) : 0.0);
        float w = exp(-o * o / (2.0 * sigma * sigma));
        sum += IN(0, uv + dir * o) * w;
        total += w;
    }
    out0.write(sum / total, gid);
}
#endif

template <typename P> inline float2 matDirection(P p) { return float2(cos(p[1].x * MAT_TAU), sin(p[1].x * MAT_TAU)); }

#if !MAT_EVAL_ONLY
kernel void mat_directionalBlur(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float2 d = matDirection(p) * p[0].x;
    float4 sum = 0;
    for (int i = 0; i < 16; i++) sum += IN(0, uv + d * ((float(i) + 0.5) / 16.0 - 0.5));
    out0.write(sum / 16.0, gid);
}
#endif

// Slope Blur: from the pixel, `samples` steps down (intensity < 0: up) the slope's height, averaging the input
// along the way (or keeping its min or max).
#if !MAT_EVAL_ONLY
kernel void mat_slopeBlur(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    int n = clamp(int(p[0].x), 1, 32);
    int mode = int(p[2].x);
    float2 t = 1.0 / float2(in1.get_width(), in1.get_height());
    float step = p[1].x / float(n);
    float2 at = uv;
    float4 first = IN(0, at), acc = first;
    for (int i = 0; i < n; i++) {
        float dx = INOR(1, at + float2(t.x, 0), float4(0)).r - INOR(1, at - float2(t.x, 0), float4(0)).r;
        float dy = INOR(1, at + float2(0, t.y), float4(0)).r - INOR(1, at - float2(0, t.y), float4(0)).r;
        float2 g = float2(dx, dy);
        float l = length(g);
        if (l > 1e-6) at -= g / l * step;
        float4 v = IN(0, at);
        acc = mode == 1 ? min(acc, v) : mode == 2 ? max(acc, v) : acc + v;
    }
    out0.write(mode == 0 ? acc / float(n + 1) : acc, gid);
}
#endif

// Edge Detect: a mask's edges, `width` pixels wide (the thresholded mask differs within that reach).
#if !MAT_EVAL_ONLY
kernel void mat_edgeDetect(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float w = p[0].x, th = p[1].x;
    float c = step(th, IN(0, uv).r), e = 0;
    for (int k = 0; k < 8; k++) {
        float t = float(k) / 8.0 * MAT_TAU;
        float s = step(th, IN(0, uv + float2(cos(t), sin(t)) * texel * w).r);
        e = max(e, abs(s - c));
    }
    out0.write(float4(e), gid);
}
#endif
