// Height and normal (MatNodes: Height & Normal). Heights are 0...1; a slope is its change per UV.

// A tangent-space normal (OpenGL: +X right, +Y up the image, +Z out; DirectX: Y down) from a height's slope along U
// and up the image (`slope.y` is up: against V), encoded 0...1.
template <typename P> inline float4 matNormalFromSlope(float2 slope, P p) {
    float k = p[0].x * 0.01;
    float3 n = normalize(float3(-slope.x * k, -slope.y * k, 1.0));
    if (p[1].x != 0) n.y = -n.y;
    return float4(n * 0.5 + 0.5, 1);
}

// Curvature from the height's Laplacian (per UV²): convex white, concave black, flat 0.5.
template <typename P> inline float matCurvatureFrom(float laplacian, P p) {
    return saturate(0.5 - laplacian * p[0].x * 1e-4);
}

kernel void mat_normal(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float2 t = 1.0 / float2(in0.get_width(), in0.get_height());
    float l = IN(0, uv - float2(t.x, 0)).r, r = IN(0, uv + float2(t.x, 0)).r;
    float up = IN(0, uv - float2(0, t.y)).r, down = IN(0, uv + float2(0, t.y)).r;
    out0.write(matNormalFromSlope(float2(r - l, up - down) / (2.0 * t), p), gid);
}

kernel void mat_curvature(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float2 t = 1.0 / float2(in0.get_width(), in0.get_height());
    float c = IN(0, uv).r;
    float lap = (IN(0, uv - float2(t.x, 0)).r + IN(0, uv + float2(t.x, 0)).r - 2.0 * c) / (t.x * t.x)
              + (IN(0, uv - float2(0, t.y)).r + IN(0, uv + float2(0, t.y)).r - 2.0 * c) / (t.y * t.y);
    out0.write(float4(matCurvatureFrom(lap, p)), gid);
}

// Ambient occlusion from a height (`depth` its range, in UV): in `quality` directions, the highest horizon within
// `radius`, eight steps out (closer ones denser); the light that comes in above the horizons, cosine weighted.
kernel void mat_ambientOcclusion(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float radius = p[0].x, depth = p[1].x;
    int dirs = clamp(int(p[2].x), 4, 16);
    float h0 = IN(0, uv).r * depth;
    float occlusion = 0;
    float twist = matRand(gid / 4, 0x5bd1e995u) * 0.5;   // the directions turned per 4 × 4 pixels (no banding)
    for (int d = 0; d < dirs; d++) {
        float t = (float(d) + twist) / float(dirs) * MAT_TAU;
        float2 dir = float2(cos(t), sin(t));
        float horizon = 0;   // sin of the highest elevation
        for (int s = 1; s <= 8; s++) {
            float r = radius * (float(s) / 8.0) * (float(s) / 8.0);
            float h = IN(0, uv + dir * r).r * depth - h0;
            float e = h / sqrt(h * h + r * r);
            horizon = max(horizon, e);
        }
        occlusion += horizon * horizon;   // cosine-weighted: the share of the hemisphere's light below the horizon
    }
    out0.write(float4(1.0 - occlusion / float(dirs)), gid);
}
