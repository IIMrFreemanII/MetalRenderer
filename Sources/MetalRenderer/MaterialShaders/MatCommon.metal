// The material graph's kernels (MatEngine): what they share. A node's kernel bakes its image: one thread a pixel of
// its output (or outputs, textures 8 to 11), reading its inputs (textures 0 to 3, sampled with wrapping: every image
// tiles) and its parameters (buffer 1: a float4 each, in its spec's order, MatNodes.swift; curves and gradients are
// 256-entry tables in buffer 2). The per-pixel maths of the nodes the shading can also run as code (MatShaderCode) are
// functions of the values they read, templated on where the parameters are (`constant` here, `device` there).

#if !MAT_EVAL_ONLY
// One node's dispatch (Swift: MatArgs, the same layout).
struct MatArgs {
    uint2 size;      // the output's pixels
    uint wired;      // bit i: input i is wired
    uint greyIn;     // bit i: input i is a grey image (its R is its value)
    uint lumIn;      // bit i: input i is a colour wired into a grey pin (its luminance is its value)
    uint greyOut;    // bit k: output k is grey
    uint seed;
    uint pass;       // a multi-pass node's pass
    float4 data;     // the pass's own values (a jump's step, a blur's direction)
};

#endif

// (MAT_EVAL_ONLY: the shading's procedural materials, MatShaderCode, take the functions alone: no kernels, no macros.)
constexpr sampler matSampler(filter::linear, address::repeat, coord::normalized);
constant float3 MAT_LUMA = float3(0.2126, 0.7152, 0.0722);
constant float MAT_TAU = 6.28318530718;

#if !MAT_EVAL_ONLY

#define MAT_KERNEL_ARGS \
    texture2d<float> in0 [[texture(0)]], texture2d<float> in1 [[texture(1)]], \
    texture2d<float> in2 [[texture(2)]], texture2d<float> in3 [[texture(3)]], \
    texture2d<float, access::write> out0 [[texture(8)]], \
    constant MatArgs& a [[buffer(0)]], constant float4* p [[buffer(1)]], device const float4* lut [[buffer(2)]], \
    uint2 gid [[thread_position_in_grid]]

#define MAT_KERNEL_ARGS4 MAT_KERNEL_ARGS, \
    texture2d<float, access::write> out1 [[texture(9)]], texture2d<float, access::write> out2 [[texture(10)]], \
    texture2d<float, access::write> out3 [[texture(11)]]

// The pixel's UV (its centre) and the size of a pixel in UV; a thread past the image does nothing.
#define MAT_PIXEL \
    if (gid.x >= a.size.x || gid.y >= a.size.y) return; \
    float2 texel = 1.0 / float2(a.size); \
    float2 uv = (float2(gid) + 0.5) * texel;

inline bool matWired(constant MatArgs& a, uint i) { return (a.wired >> i) & 1u; }

// Input i at `uv`: a grey image's value in R, G and B (alpha 1); a colour into a grey pin, its luminance.
inline float4 matIn(texture2d<float> t, uint i, constant MatArgs& a, float2 uv) {
    float4 v = t.sample(matSampler, uv, level(0));
    if ((a.greyIn >> i) & 1u) return float4(v.rrr, 1);
    if ((a.lumIn >> i) & 1u) { float l = dot(v.rgb, MAT_LUMA); return float4(l, l, l, 1); }
    return v;
}
#define IN(k, at) matIn(in##k, k, a, at)
#define INOR(k, at, otherwise) (matWired(a, k) ? matIn(in##k, k, a, at) : (otherwise))

// A pixel processor's or Code node's input i (sampleInput in their code).
inline float4 matInput4(texture2d<float> in0, texture2d<float> in1, texture2d<float> in2, texture2d<float> in3,
                        constant MatArgs& a, int i, float2 uv) {
    if (!matWired(a, uint(i))) return float4(0, 0, 0, 1);
    switch (i) {
        case 0: return matIn(in0, 0, a, uv);
        case 1: return matIn(in1, 1, a, uv);
        case 2: return matIn(in2, 2, a, uv);
        default: return matIn(in3, 3, a, uv);
    }
}
#endif

// MARK: - Random

inline uint matHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
inline uint matHash(uint2 v, uint seed) { return matHash(v.x ^ matHash(v.y ^ matHash(seed))); }
inline float matRand(uint2 v, uint seed) { return float(matHash(v, seed) >> 8) * (1.0 / 16777216.0); }
inline float2 matRand2(uint2 v, uint seed) {
    return float2(matRand(v, seed), matRand(v, seed ^ 0x9e3779b9u));
}
// The pixel processor's Random node (MatFunction.random, line for line).
inline float matRandom(float2 p, float salt) {
    uint h = uint(int(floor(p.x * 4096.0)));
    h = h * 0x27d4eb2du ^ uint(int(floor(p.y * 4096.0))) * 0x165667b1u;
    h ^= uint(int(floor(salt))) * 0x9e3779b9u;
    h ^= h >> 15; h *= 0x2c1b3c6du; h ^= h >> 12; h *= 0x297a2d39u; h ^= h >> 15;
    return float(h >> 8) / 16777216.0;
}

// A lattice cell wrapped into a period (every noise tiles).
inline int2 matWrap(int2 c, int2 n) { return ((c % n) + n) % n; }
inline float2 matRotate(float2 v, float turns) {
    float s = sin(turns * MAT_TAU), c = cos(turns * MAT_TAU);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}
inline float2 matQuintic(float2 f) { return f * f * f * (f * (f * 6.0 - 15.0) + 10.0); }

// The shortest way from a to b on a torus of size 1 (both in UV).
inline float2 matWrapDelta(float2 d) { return d - round(d); }

// A 256-entry table (a curve's or a gradient's), linearly between entries.
template <typename L>
inline float4 matLut(L lut, float index, float x) {
    float t = saturate(x) * 255.0;
    int i = min(int(t), 254);
    int base = int(index) * 256;
    return mix(lut[base + i], lut[base + i + 1], t - float(i));
}

// MARK: - Simple kernels

// A value everywhere (Uniform Grey, Uniform Colour, an Input's default): parameter 0.
#if !MAT_EVAL_ONLY
kernel void mat_uniform(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    out0.write(p[0], gid);
}
#endif

// Input 0 as it is (an Output; a subgraph's input wired from outside; a Bitmap's image: as luminance if p[1] is 1).
#if !MAT_EVAL_ONLY
kernel void mat_copy(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float4 v = IN(0, uv);
    if (p[1].x == 1.0 && !((a.greyOut) & 1u)) { float l = dot(v.rgb, MAT_LUMA); v = float4(l, l, l, v.a); }
    out0.write(v, gid);
}
#endif

// The editor's thumbnails: input 0 downsampled into a slot of the shared atlas (buffer 3: RGBA8, `data.x` the slot,
// `data.y` its side). Greys as greys; values as they are (colours are sRGB values already).
#if !MAT_EVAL_ONLY
kernel void mat_thumbnail(texture2d<float> in0 [[texture(0)]], constant MatArgs& a [[buffer(0)]],
                          device uchar4* atlas [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
    uint side = uint(a.data.y);
    if (gid.x >= side || gid.y >= side) return;
    float2 uv = (float2(gid) + 0.5) / float(side);
    // A few taps a thumbnail pixel: a big image doesn't alias.
    float2 d = 0.25 / float(side);
    float4 v = 0;
    for (int k = 0; k < 4; k++) v += in0.sample(matSampler, uv + d * float2(k & 1 ? 1 : -1, k & 2 ? 1 : -1), level(0));
    v *= 0.25;
    if (a.greyIn & 1u) v = float4(v.rrr, 1);
    atlas[uint(a.data.x) * side * side + gid.y * side + gid.x] = uchar4(round(saturate(v) * 255.0));
}
#endif

// MARK: - The renderer's textures (MaterialBake)

// A colour channel (base colour, emissive: sRGB values, the renderer views them as sRGB) or a grey one (height,
// opacity) as it is; a normal with its green flipped when `data.x` is 1 (a DirectX map).
#if !MAT_EVAL_ONLY
kernel void mat_packColor(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    float4 v = INOR(0, uv, p[0]);
    if (a.data.x != 0) v.g = 1.0 - v.g;
    out0.write(float4(v.rgb, 1), gid);
}
#endif

// Occlusion, roughness and metallic (glTF's layout: R, G, B), each from its channel or its fallback.
#if !MAT_EVAL_ONLY
kernel void mat_packORM(MAT_KERNEL_ARGS) {
    MAT_PIXEL
    out0.write(float4(INOR(0, uv, p[0]).r, INOR(1, uv, p[1]).r, INOR(2, uv, p[2]).r, 1), gid);
}
#endif
