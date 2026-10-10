#if !MAT_EVAL_ONLY
// The advanced nodes' passes (MatNodes: Advanced), which the engine runs in sequence (MatEngine.encodeGlobal):
// Distance and Bevel by jump flooding, Flood Fill by labels propagated and jumped, Auto Levels by a min and max.
// All wrap: a shape across the tile's edge is one shape.

// The shortest pixel offset from b to a on the tiled image.
inline float2 matTorus(float2 d, float2 n) { return d - n * round(d / n); }

// Jump flooding, seeds: a pixel of the mask (above `data.x`; below it when `data.y` is 1) is its own seed (its pixel
// coordinates), any other has none (-1). Output: an RG32Float image.
kernel void mat_jfaSeed(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    bool on = IN(0, uv).r > a.data.x;
    if (a.data.y != 0) on = !on;
    out0.write(on ? float4(float2(gid), 0, 0) : float4(-1, -1, 0, 0), gid);
}

// A jump of `data.x` pixels: each pixel keeps the nearest seed of its own and its 8 neighbours' at that distance.
kernel void mat_jfaStep(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    int k = int(a.data.x);
    float2 n = float2(a.size), here = float2(gid);
    float2 best = in0.read(gid).xy;
    float bestD = best.x < 0 ? 1e20 : length(matTorus(best - here, n));
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            if (i == 0 && j == 0) continue;
            int2 q = matWrap(int2(gid) + int2(i, j) * k, int2(a.size));
            float2 s = in0.read(uint2(q)).xy;
            if (s.x < 0) continue;
            float d = length(matTorus(s - here, n));
            if (d < bestD) { bestD = d; best = s; }
        }
    }
    out0.write(float4(best, 0, 0), gid);
}

inline float matSeedDistance(texture2d<float> seeds, uint2 gid, uint2 size) {
    float2 s = seeds.read(gid).xy;
    if (s.x < 0) return 1e20;
    return length(matTorus(s - float2(gid), float2(size))) / float(size.x);
}

// Distance: white on the mask, black `distance` (UV) away.
kernel void mat_distanceOut(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float d = matSeedDistance(in0, gid, a.size);
    out0.write(float4(saturate(1.0 - d / max(p[0].x, 1e-5))), gid);
}

// Bevel: in the mask, the distance to its edge (the seeds are outside it) over `distance`, smoothed; 0 outside.
kernel void mat_bevelOut(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    bool inside = IN(1, uv).r > p[2].x;
    float d = matSeedDistance(in0, gid, a.size);
    float v = inside ? saturate(d / max(p[0].x, 1e-5)) : 0.0;
    v = mix(v, smoothstep(0.0, 1.0, v), p[1].x);
    out0.write(float4(v), gid);
}

// MARK: - Flood fill

constant uint MAT_NONE = 0xffffffffu;

// Each pixel of the mask its own label (its index); the rest none.
kernel void mat_ffInit(MAT_KERNEL_ARGS, device uint* labels [[buffer(4)]]) {
    MAT_PIXEL
    labels[gid.y * a.size.x + gid.x] = IN(0, uv).r > p[0].x ? gid.y * a.size.x + gid.x : MAT_NONE;
}

// The lowest label among a pixel's and its 4 neighbours' (wrapping), and its label's label.
kernel void mat_ffPropagate(MAT_KERNEL_ARGS, device uint* labels [[buffer(4)]]) {
    MAT_PIXEL
    uint i = gid.y * a.size.x + gid.x;
    uint m = labels[i];
    if (m == MAT_NONE) return;
    const int2 near[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    for (int k = 0; k < 4; k++) {
        uint2 q = uint2(matWrap(int2(gid) + near[k], int2(a.size)));
        uint l = labels[q.y * a.size.x + q.x];
        if (l != MAT_NONE) m = min(m, l);
    }
    m = min(m, labels[m]);
    labels[i] = m;
}

// Pointer jumping: a label's label, until each points at its shape's lowest.
kernel void mat_ffJump(MAT_KERNEL_ARGS, device uint* labels [[buffer(4)]]) {
    MAT_PIXEL
    uint i = gid.y * a.size.x + gid.x;
    uint l = labels[i];
    if (l != MAT_NONE) labels[i] = labels[l];
}

kernel void mat_ffBoundsClear(MAT_KERNEL_ARGS, device int4* bounds [[buffer(5)]]) {
    MAT_PIXEL
    bounds[gid.y * a.size.x + gid.x] = int4(2147483647, 2147483647, -2147483647 - 1, -2147483647 - 1);
}

// Each shape's bounds, about its label's pixel (wrapping: the shortest way to it), in pixels.
kernel void mat_ffBounds(MAT_KERNEL_ARGS, device uint* labels [[buffer(4)]], device atomic_int* bounds [[buffer(5)]]) {
    MAT_PIXEL
    uint l = labels[gid.y * a.size.x + gid.x];
    if (l == MAT_NONE) return;
    float2 root = float2(l % a.size.x, l / a.size.x);
    int2 rel = int2(matTorus(float2(gid) - root, float2(a.size)));
    atomic_fetch_min_explicit(&bounds[l * 4 + 0], rel.x, memory_order_relaxed);
    atomic_fetch_min_explicit(&bounds[l * 4 + 1], rel.y, memory_order_relaxed);
    atomic_fetch_max_explicit(&bounds[l * 4 + 2], rel.x, memory_order_relaxed);
    atomic_fetch_max_explicit(&bounds[l * 4 + 3], rel.y, memory_order_relaxed);
}

// The outputs: a random grey a shape, a gradient across it (a random way, up to `angleRandom` of a turn), its centre
// (RG, UV) and its size (RG, UV); 0 off the mask.
kernel void mat_ffOut(MAT_KERNEL_ARGS4, device uint* labels [[buffer(4)]], device int4* bounds [[buffer(5)]]) {
    MAT_PIXEL
    uint l = labels[gid.y * a.size.x + gid.x];
    if (l == MAT_NONE) {
        out0.write(float4(0), gid); out1.write(float4(0), gid); out2.write(float4(0, 0, 0, 1), gid); out3.write(float4(0, 0, 0, 1), gid);
        return;
    }
    float2 n = float2(a.size);
    float2 root = float2(l % a.size.x, l / a.size.x);
    int4 b = bounds[l];
    float2 lo = float2(b.xy), hi = float2(b.zw);
    float2 centre = (lo + hi) * 0.5, size = hi - lo + 1.0;
    float2 rel = matTorus(float2(gid) - root, n);
    uint2 id = uint2(l % a.size.x, l / a.size.x);
    float turn = matRand(id, a.seed ^ 0x2545f491u) * p[1].x;
    float2 dir = float2(cos(turn * MAT_TAU), sin(turn * MAT_TAU));
    float extent = 0.5 * (abs(dir.x) * size.x + abs(dir.y) * size.y);
    out0.write(float4(max(matRand(id, a.seed), 1.0 / 255.0)), gid);
    out1.write(float4(saturate(0.5 + dot(rel - centre, dir) / max(2.0 * extent, 1.0))), gid);
    out2.write(float4(fract((root + centre + 0.5) / n), 0, 1), gid);
    out3.write(float4(size / n, 0, 1), gid);
}

// MARK: - Auto levels

kernel void mat_minMaxClear(device atomic_uint* range [[buffer(4)]], uint gid [[thread_position_in_grid]]) {
    if (gid == 0) {
        atomic_store_explicit(&range[0], 0xffffffffu, memory_order_relaxed);
        atomic_store_explicit(&range[1], 0u, memory_order_relaxed);
    }
}

// The image's darkest and lightest (as their bits: for floats ≥ 0 their order).
kernel void mat_minMax(MAT_KERNEL_ARGS, device atomic_uint* range [[buffer(4)]]) {
    MAT_PIXEL
    uint v = as_type<uint>(max(IN(0, uv).r, 0.0));
    atomic_fetch_min_explicit(&range[0], v, memory_order_relaxed);
    atomic_fetch_max_explicit(&range[1], v, memory_order_relaxed);
}

kernel void mat_autoLevels(MAT_KERNEL_ARGS, device uint* range [[buffer(4)]]) {
    MAT_PIXEL
    float lo = as_type<float>(range[0]), hi = as_type<float>(range[1]);
    out0.write(float4(saturate((IN(0, uv).r - lo) / max(hi - lo, 1e-6))), gid);
}
#endif
