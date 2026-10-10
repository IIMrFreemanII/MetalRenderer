// The patterns (MatNodes: Patterns): shapes, gradients, checkers, bricks, waves and the tile sampler.

// A shape at r (-1...1 its extent): square, disc, polygon, star, bell, cone, pyramid, paraboloid, hemisphere, ring;
// `soft` the edge's width in the same units.
inline float matShape(int kind, float2 r, int sides, float soft) {
    soft = max(soft, 1e-4);
    float n = float(max(sides, 3)), sector = MAT_TAU / n;
    switch (kind) {
        case 0: return 1.0 - smoothstep(1.0 - soft, 1.0, max(abs(r.x), abs(r.y)));
        case 1: return 1.0 - smoothstep(1.0 - soft, 1.0, length(r));
        case 2: {
            float t = atan2(r.y, r.x) + MAT_TAU;
            float d = length(r) * cos(fmod(t, sector) - sector * 0.5) / cos(sector * 0.5);
            return 1.0 - smoothstep(1.0 - soft, 1.0, d);
        }
        case 3: {
            float t = atan2(r.y, r.x) + MAT_TAU;
            float k = abs(fract(t / sector) * 2.0 - 1.0);
            float d = length(r) / mix(0.45, 1.0, k * k);
            return 1.0 - smoothstep(1.0 - soft, 1.0, d);
        }
        case 4: return exp(-dot(r, r) * 4.0) * (1.0 - smoothstep(0.9, 1.0, length(r)));
        case 5: return saturate(1.0 - length(r));
        case 6: return saturate(1.0 - max(abs(r.x), abs(r.y)));
        case 7: return saturate(1.0 - dot(r, r));
        case 8: return sqrt(saturate(1.0 - dot(r, r)));
        default: return 1.0 - smoothstep(0.15 - soft, 0.15, abs(length(r) - 0.8));
    }
}

template <typename P> inline float matShapeAt(float2 uv, P p) {
    int tiling = max(int(p[5].x), 1);
    float size = max(p[1].x, 1e-4);
    float2 x = matRotate(fract(uv * float(tiling)) - 0.5, -p[4].x) / (size * 0.5);
    return matShape(int(p[0].x), x, int(p[2].x), p[3].x / (size * 0.5));
}

template <typename P> inline float matGradientAt(float2 uv, P p) {
    float2 c = matRotate(uv - 0.5, -p[1].x);
    float repeats = max(p[2].x, 1.0);
    float t;
    switch (int(p[0].x)) {
        case 0: t = c.x + 0.5; break;
        case 1: t = 1.0 - saturate(length(c) * 2.0); break;
        case 2: t = atan2(c.y, c.x) / MAT_TAU + 0.5; break;
        case 3: t = 1.0 - saturate(abs(c.x) + abs(c.y)) ; break;
        default: t = 1.0 - abs(c.x * 2.0); break;
    }
    return repeats > 1.0 ? fract(t * repeats - 1e-5) : saturate(t);
}

template <typename P> inline float matCheckerAt(float2 uv, P p) {
    int2 c = int2(floor(uv * max(p[0].x, 1.0)));
    return float((c.x + c.y) & 1);
}

// Bricks: rows of `columns` bricks, every row shifted by `offset`; the height (1 inside, bevelled to 0 at the gap,
// each brick lower by up to `heightRandom`) and a random grey a brick (0 in the gaps).
template <typename P> inline float2 matBricksAt(float2 uv, P p, uint seed) {
    float cols = max(p[0].x, 1.0), rows = max(p[1].x, 1.0);
    float y = uv.y * rows, row = floor(y);
    float x = uv.x * cols + p[2].x * row;
    float col = floor(x);
    int2 id = matWrap(int2(int(col), int(row)), int2(int(cols), int(rows)));
    float2 f = float2(fract(x), fract(y));
    // Distance in from the brick's edge, in UV.
    float2 edge = min(f, 1.0 - f) / float2(cols, rows) - p[3].x * 0.5;
    // Rounded corners: within `corner` of both edges, the distance to the corner's arc.
    float corner = p[6].x * min(1.0 / cols, 1.0 / rows) * 0.5;
    float d = any(edge < corner) ? corner - length(max(corner - edge, 0.0)) : min(edge.x, edge.y);
    if (d <= 0) return float2(0, 0);
    float bevel = max(p[4].x * min(1.0 / cols, 1.0 / rows) * 0.5, 1e-5);
    float r = matRand(uint2(id), seed);
    float h = (1.0 - p[5].x * matRand(uint2(id), seed ^ 0xb5297a4du)) * smoothstep(0.0, bevel, d);
    return float2(h, max(r, 1.0 / 255.0));
}

template <typename P> inline float matWavesAt(float2 uv, P p) {
    float t = matRotate(uv - 0.5, -p[1].x).x * max(p[0].x, 1.0);
    float f = fract(t);
    switch (int(p[2].x)) {
        case 0: return 0.5 + 0.5 * sin(t * MAT_TAU);
        case 1: return 1.0 - abs(f * 2.0 - 1.0);
        case 2: return step(f, 0.5);
        default: return f;
    }
}

#if !MAT_EVAL_ONLY
kernel void mat_shape(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matShapeAt(uv, p)), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_gradient(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matGradientAt(uv, p)), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_checker(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matCheckerAt(uv, p)), gid); }
#endif
#if !MAT_EVAL_ONLY
kernel void mat_waves(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matWavesAt(uv, p)), gid); }
#endif

#if !MAT_EVAL_ONLY
kernel void mat_bricks(MAT_KERNEL_ARGS, texture2d<float, access::write> out1 [[texture(9)]]) {
    MAT_PIXEL
    float2 v = matBricksAt(uv, p, a.seed);
    out0.write(float4(v.x), gid);
    out1.write(float4(v.y), gid);
}
#endif

// Tile Sampler: per cell of a grid an instance (moved, scaled, turned, darkened at random) of input 0 (a tile of it
// stretched over the instance), or of a shape; the 3 × 3 cells around a pixel, blended by max or added.
#if !MAT_EVAL_ONLY
constant int MAT_SAMPLER_SHAPES[5] = { 1, 0, 4, 6, 8 };   // disc, square, bell, pyramid, hemisphere
#endif

#if !MAT_EVAL_ONLY
kernel void mat_tileSampler(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float2 grid = max(float2(p[0].x, p[1].x), 1.0);
    float2 x = uv * grid;
    bool pattern = matWired(a, 0);
    bool add = p[10].x == 1.0;
    int shape = MAT_SAMPLER_SHAPES[clamp(int(p[2].x), 0, 4)];
    float4 acc = float4(0, 0, 0, 1);
    for (int j = -1; j <= 1; j++) {
        float row = floor(x.y) + float(j);
        float xs = x.x - p[9].x * row;          // the row's own x: shifted by its offset
        for (int i = -1; i <= 1; i++) {
            float col = floor(xs) + float(i);
            uint2 w = uint2(matWrap(int2(int(col), int(row)), int2(grid)));
            float2 centre = float2(col, row) + 0.5 + (matRand2(w, a.seed) - 0.5) * p[5].x;
            float size = p[3].x * (1.0 - p[4].x * matRand(w, a.seed ^ 0x1b873593u));
            float turn = p[6].x + (matRand(w, a.seed ^ 0xcc9e2d51u) - 0.5) * p[7].x;
            float lum = 1.0 - p[8].x * matRand(w, a.seed ^ 0xe6546b64u);
            float2 q = matRotate(float2(xs, x.y) - centre, -turn) / max(size, 1e-4);   // -0.5...0.5 inside
            if (any(abs(q) > 0.5)) continue;
            float4 v = pattern ? IN(0, q + 0.5) : float4(float3(matShape(shape, q * 2.0, 4, 0.02)), 1);
            v.rgb *= lum;
            acc.rgb = add ? acc.rgb + v.rgb : max(acc.rgb, v.rgb);
        }
    }
    out0.write(acc, gid);
}
#endif
