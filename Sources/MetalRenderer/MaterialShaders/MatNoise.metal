// The noises (MatNodes: Noises). Every one tiles: its lattice wraps at its scale, a whole number of cells across.

// Value noise: a random grey a lattice point, smooth (quintic) between.
inline float matValueNoise(float2 x, int2 period, uint seed, float smooth) {
    float2 i = floor(x), f = x - i;
    float2 u = mix(step(0.5, f), matQuintic(f), smooth);
    int2 c = int2(i);
    float v00 = matRand(uint2(matWrap(c, period)), seed);
    float v10 = matRand(uint2(matWrap(c + int2(1, 0), period)), seed);
    float v01 = matRand(uint2(matWrap(c + int2(0, 1), period)), seed);
    float v11 = matRand(uint2(matWrap(c + int2(1, 1), period)), seed);
    return mix(mix(v00, v10, u.x), mix(v01, v11, u.x), u.y);
}

inline float2 matGradient(int2 c, int2 period, uint seed) {
    float t = matRand(uint2(matWrap(c, period)), seed) * MAT_TAU;
    return float2(cos(t), sin(t));
}

// Perlin (gradient) noise, about -1...1.
inline float matPerlin(float2 x, int period, uint seed) {
    float2 i = floor(x), f = x - i, u = matQuintic(f);
    int2 c = int2(i), n = int2(period);
    float a = dot(matGradient(c, n, seed), f);
    float b = dot(matGradient(c + int2(1, 0), n, seed), f - float2(1, 0));
    float d = dot(matGradient(c + int2(0, 1), n, seed), f - float2(0, 1));
    float e = dot(matGradient(c + int2(1, 1), n, seed), f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(d, e, u.x), u.y) * 1.414;
}

// Octaves of Perlin noise: fbm (0...1 about 0.5), ridged, turbulence, billow (mode 0 to 3).
inline float matFractal(float2 uv, int scale, int octaves, float roughness, int mode, uint seed) {
    float sum = 0, amp = 1, norm = 0;
    int period = max(scale, 1);
    for (int o = 0; o < octaves; o++) {
        float n = matPerlin(uv * float(period), period, seed + uint(o) * 1013u);
        if (mode == 1) { n = 1.0 - abs(n); n *= n; }
        else if (mode == 2) n = abs(n);
        else if (mode == 3) n = abs(n) * 2.0 - 1.0;
        sum += n * amp;
        norm += amp;
        amp *= roughness;
        period *= 2;
    }
    float v = sum / max(norm, 1e-4);
    return mode == 0 || mode == 3 ? saturate(0.5 + 0.5 * v * 1.3) : saturate(v * (mode == 1 ? 1.0 : 1.6));
}

// Worley noise at `x` (cells of a grid `period` across): the nearest and second nearest points' distances and the
// nearest point's cell and offset.
struct MatCells { float f1; float f2; int2 cell; float2 offset; };
inline MatCells matCells(float2 x, int period, float jitter, uint seed) {
    MatCells r = { 9.0, 9.0, int2(0), float2(0) };
    int2 c = int2(floor(x));
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            int2 k = c + int2(i, j);
            int2 w = matWrap(k, int2(period));
            float2 at = float2(k) + 0.5 + (matRand2(uint2(w), seed) - 0.5) * jitter;
            float2 d = at - x;
            float dd = length(d);
            if (dd < r.f1) { r.f2 = r.f1; r.f1 = dd; r.cell = w; r.offset = d; }
            else if (dd < r.f2) r.f2 = dd;
        }
    }
    return r;
}

template <typename P>
inline float matCellsValue(float2 uv, P p, uint seed) {
    int scale = max(int(p[0].x), 1);
    int mode = int(p[2].x);
    MatCells c = matCells(uv * float(scale), scale, p[1].x, seed);
    switch (mode) {
        case 0: return saturate(c.f1 * 1.25);
        case 1: return saturate(c.f2 * 0.9);
        case 2: return saturate((c.f2 - c.f1) * 2.5);
        case 3: return matRand(uint2(c.cell), seed ^ 0x51ed270bu);
        default: {   // crystal: a tilted facet a cell
            float2 tilt = (matRand2(uint2(c.cell), seed ^ 0x68e31da4u) - 0.5) * 1.2;
            return saturate(0.5 + (matRand(uint2(c.cell), seed ^ 0x51ed270bu) - 0.5) * 0.6 + dot(tilt, -c.offset));
        }
    }
}

// MARK: - The nodes' values

template <typename P> inline float matWhiteNoiseAt(float2 uv, float2 size, P p, uint seed) {
    return matRand(uint2(floor(uv * size)), seed);
}
template <typename P> inline float matValueNoiseAt(float2 uv, P p, uint seed) {
    int s = max(int(p[0].x), 1);
    return matValueNoise(uv * float(s), int2(s), seed, 1.0);
}
template <typename P> inline float matPerlinAt(float2 uv, P p, uint seed) {
    int s = max(int(p[0].x), 1);
    float2 x = uv * float(s);
    float disorder = p[1].x;
    if (disorder > 0) x += disorder * float2(matPerlin(x + 17.3, s, seed ^ 0xa5u), matPerlin(x + 41.7, s, seed ^ 0x5au));
    return saturate(0.5 + 0.5 * matPerlin(x, s, seed));
}
template <typename P> inline float matFractalAt(float2 uv, P p, uint seed) {
    return matFractal(uv, int(p[0].x), clamp(int(p[1].x), 1, 10), p[2].x, int(p[3].x), seed);
}
template <typename P> inline float matAnisotropicAt(float2 uv, P p, uint seed) {
    int2 s = max(int2(p[0].x, p[1].x), int2(1));
    float smooth = p[2].x;
    float a = matValueNoise(uv * float2(s), s, seed, smooth);
    float b = matValueNoise(uv * float2(s * 2), s * 2, seed ^ 0x3cu, smooth);
    return saturate(a * 0.65 + b * 0.35);
}

// Scratches: in each cell of a grid, `count` segments (a random centre, length and angle); a pixel the brightest
// segment it is on, its ends faded.
template <typename P> inline float matScratchesAt(float2 uv, P p, uint seed) {
    int count = clamp(int(p[0].x), 1, 16);
    int cells = max(int(p[6].x), 1);
    float halfLength = p[1].x * float(cells) * 0.5, width = p[2].x * float(cells);
    int reach = clamp(int(ceil(halfLength)), 1, 3);
    float2 x = uv * float(cells);
    int2 c = int2(floor(x));
    float best = 0;
    for (int j = -reach; j <= reach; j++) {
        for (int i = -reach; i <= reach; i++) {
            int2 k = c + int2(i, j);
            uint2 w = uint2(matWrap(k, int2(cells)));
            for (int s = 0; s < count; s++) {
                uint sd = seed + uint(s) * 7919u;
                float2 centre = float2(k) + matRand2(w, sd);
                float turn = p[3].x + (matRand(w, sd ^ 0x1234u) - 0.5) * p[4].x;
                float2 dir = float2(cos(turn * MAT_TAU), sin(turn * MAT_TAU));
                float len = halfLength * (0.5 + 0.5 * matRand(w, sd ^ 0x777u));
                float t = clamp(dot(x - centre, dir), -len, len);
                float d = length(x - (centre + dir * t));
                float fade = 1.0 - pow(t / max(len, 1e-4), 2.0);
                float v = (1.0 - smoothstep(width * 0.5, width, d)) * fade * (1.0 - p[5].x * matRand(w, sd ^ 0x999u));
                best = max(best, v);
            }
        }
    }
    return saturate(best);
}

// Grunge: fractal noise, darkened in its cells' borders and broken by spots.
template <typename P> inline float matGrungeAt(float2 uv, P p, uint seed) {
    int s = max(int(p[0].x), 1);
    float n = matFractal(uv, s, 7, 0.6, 0, seed);
    MatCells c = matCells(uv * float(s * 3), s * 3, 1.0, seed ^ 0x2468u);
    float cracks = smoothstep(0.0, 0.12, c.f2 - c.f1);
    float spots = smoothstep(0.55, 0.7, matFractal(uv, s * 2, 4, 0.5, 0, seed ^ 0x1357u));
    float g = n * mix(0.7, 1.0, cracks) * (1.0 - spots * p[2].x * 0.8);
    return saturate((g - 0.5) * (1.0 + p[1].x * 4.0) + 0.5);
}

kernel void mat_whiteNoise(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matWhiteNoiseAt(uv, float2(a.size), p, a.seed)), gid); }
kernel void mat_valueNoise(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matValueNoiseAt(uv, p, a.seed)), gid); }
kernel void mat_perlinNoise(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matPerlinAt(uv, p, a.seed)), gid); }
kernel void mat_fractalSum(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matFractalAt(uv, p, a.seed)), gid); }
kernel void mat_cells(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matCellsValue(uv, p, a.seed)), gid); }
kernel void mat_anisotropicNoise(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matAnisotropicAt(uv, p, a.seed)), gid); }
kernel void mat_scratches(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matScratchesAt(uv, p, a.seed)), gid); }
kernel void mat_grunge(MAT_KERNEL_ARGS) { MAT_PIXEL; out0.write(float4(matGrungeAt(uv, p, a.seed)), gid); }
