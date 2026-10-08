// ---------------------------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------------------------

inline float luminance(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

// The firefly clamp: the factor that brings light of luminance `lum` down to `limit` (1 below it, or with the clamp
// off: FLAG_NO_CLAMP for the built-in limit, a limit of 0 for one that is a setting).
inline float fireflyScale(constant Uniforms& u, float lum, float limit = FIREFLY_CLAMP) {
    return lum > limit && !flagOn(u.flags, FLAG_NO_CLAMP) ? limit / lum : 1.0f;
}
inline float fireflyScale(float lum, float limit) { return limit > 0.0f && lum > limit ? limit / lum : 1.0f; }

// Round to the nearest half before writing a half-float texture. The texture write itself may round
// toward zero, and the denoiser's history feedback amplifies that bias into visible darkening.
inline float4 roundToHalf(float4 v) { return float4(half4(v)); }

// "No hit" / "unbounded" distances are INFINITY. Test for them with isFar, not isinf or == INFINITY: fast math (the
// default) may assume there are no infinities and fold those away, but it can't fold a comparison with a finite number.
constant float FAR_DISTANCE = 1e30f;
inline bool isFar(float t) { return t >= FAR_DISTANCE; }

inline uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// A kernel's per-pixel, per-frame seed. Kernels that run in the same frame must not share a salt: two streams from
// one seed pick correlated samples (a light and a bounce direction, say).
constant uint SEED_TRACE             = 0u;
constant uint SEED_FOG_REFERENCE     = 0x5bd1e995u;
constant uint SEED_MANY_LIGHTS       = 0x9E3779B9u;   // manyLightsKernel / manyLightsReuseKernel: one of them runs
constant uint SEED_RESTIR_DI         = 0x2545F491u;
constant uint SEED_MEGALIGHTS        = 0x3C6EF372u;
constant uint SEED_RESTIR_GI         = 0x85EBCA6Bu;
constant uint SEED_RESTIR_GI_HISTORY = 0x7F4A7C15u;
inline uint pixelSeed(uint2 pixel, uint frame, uint salt) {
    return pcgHash(pixel.x + pcgHash(pixel.y + pcgHash(frame ^ salt)));
}

// Simple per-pixel random stream (white noise).
struct Rng {
    uint state;
    float next() {
        state = pcgHash(state);
        return float(state) * (1.0f / 4294967296.0f);
    }
    float2 next2() { return float2(next(), next()); }
    uint nextUint() { state = pcgHash(state); return state; }
};

constant uint BLUE_NOISE_SIZE = 128;   // must match BlueNoise.size

// Per-pixel sample stream. With blue noise, every random dimension reads the tiled blue-noise texture at
// its own offset, so neighboring pixels get well-spread values and the error is high-frequency (which the
// a-trous filter removes far better than white noise). Each frame shifts the values by the golden ratio
// (1D) or the R2 sequence (2D), so each pixel's samples over time are also evenly spread.
struct Sampler {
    texture2d<float, access::read> blueNoise;
    uint2 pixel;
    uint frame;
    uint dimension;
    bool useBlueNoise;
    Rng rng;

    float blueValue() {
        // R2-sequence offsets give every dimension a different, far-apart window into the tile.
        float2 r2 = fract(float(dimension + 1) * float2(0.7548776662f, 0.5698402910f));
        dimension++;
        uint2 q = (pixel + uint2(r2 * float(BLUE_NOISE_SIZE))) % BLUE_NOISE_SIZE;
        return blueNoise.read(q).r;
    }
    // Adds frame * step (step = fraction * 2^32) in 32-bit fixed point, so there is no drift over time.
    float shift(float v, uint step) {
        uint x = (uint(v * 16777216.0f) << 8) + frame * step;
        return float(x >> 8) * (1.0f / 16777216.0f);
    }
    float next() {
        if (!useBlueNoise) return rng.next();
        return shift(blueValue(), 2654435769u);                       // golden ratio
    }
    float2 next2() {
        if (!useBlueNoise) return rng.next2();
        float a = blueValue(), b = blueValue();
        return float2(shift(a, 3242174889u), shift(b, 2447445414u));  // R2 sequence
    }
};

// A kernel's sample stream: `pixel` picks the blue-noise window, `dimension` is where the kernel's dimensions start
// (kernels of one frame use ranges apart: trace 0, reflections 40, glass 52, the direct-light kernels 64, mesh lights 96,
// ReSTIR GI 128), `seed` starts the white-noise stream.
inline Sampler makeSampler(texture2d<float, access::read> blueNoise, constant Uniforms& u, uint2 pixel, uint dimension,
                           uint seed) {
    Sampler rng;
    rng.blueNoise = blueNoise;
    rng.pixel = pixel;
    rng.frame = u.frameIndex;
    rng.dimension = dimension;
    rng.useBlueNoise = flagOn(u.flags, FLAG_BLUE_NOISE);
    rng.rng.state = seed;
    return rng;
}


// Cosine-weighted hemisphere sample around n (pdf = cos / pi).
inline float3 cosineSampleHemisphere(float3 n, float2 u) {
    float r = sqrt(u.x);
    float phi = 2.0f * M_PI_F * u.y;
    float3 local = float3(r * cos(phi), r * sin(phi), sqrt(max(0.0f, 1.0f - u.x)));
    // Orthonormal basis (Duff et al. 2017)
    float s = n.z >= 0.0f ? 1.0f : -1.0f;
    float a = -1.0f / (s + n.z);
    float b = n.x * n.y * a;
    float3 t  = float3(1.0f + s * n.x * n.x * a, s * b, -s * n.x);
    float3 bt = float3(b, s + n.y * n.y * a, -n.y);
    return normalize(t * local.x + bt * local.y + n * local.z);
}

// A streaming pick of one item in proportion to its weight (weighted reservoir sampling), in one pass and from one
// random number, which is rescaled after each decision so it is uniform again for the next. The pick's probability
// is its weight / total.
struct StreamPick {
    float u;        // in [0, 1)
    float total;    // the weights offered so far
    // Offers an item of weight w > 0: true if it replaces the pick.
    bool offer(float w) {
        total += w;
        float q = w / total;
        if (u < q) { u /= q; return true; }
        u = (u - q) / (1.0f - q);
        return false;
    }
};
inline StreamPick streamPick(float u) {
    StreamPick pick;
    pick.u = min(u, 0.99999f);
    pick.total = 0.0f;
    return pick;
}

// A diffuse bounce's direction: cosine-weighted around the shading normal n, mirrored to stay above the triangle (ng).
inline float3 sampleBounce(float3 n, float3 ng, float2 u) {
    float3 d = cosineSampleHemisphere(n, u);
    if (dot(d, ng) <= 0.0f) d -= 2.0f * dot(d, ng) * ng;
    return d;
}

// ---------------------------------------------------------------------------------------------
// Owen-scrambled Sobol points (Burley 2020, "Practical Hash-based Owen Scrambling"), for estimates averaged over many
// samples (the reference path tracer): 2D points from Sobol's first two dimensions, a (0, 2)-sequence, each pair of
// dimensions with its own scramble and its own shuffle of the sample index (a "padded" sequence), so pairs don't
// correlate. Sample i of a pixel's stream is point i of its own randomised sequence: any prefix is well spread.
// ---------------------------------------------------------------------------------------------

// Laine and Karras' hash: an approximate nested uniform (Owen) scramble of x's bits, from the low bit up.
inline uint laineKarrasPermutation(uint x, uint seed) {
    x += seed;
    x ^= x * 0x6c50b47cu;
    x ^= x * 0xb82f1e52u;
    x ^= x * 0xc7afe638u;
    x ^= x * 0x8d22f6e6u;
    return x;
}
// Owen-scrambles the bits of x from the high bit down.
inline uint nestedUniformScramble(uint x, uint seed) {
    return reverse_bits(laineKarrasPermutation(reverse_bits(x), seed));
}

// Point i of Sobol's second dimension, as 32-bit fixed point: Pascal's matrix (the first is van der Corput:
// reverse_bits(i)).
inline uint sobolSecond(uint i) {
    uint y = 0u;
    for (uint v = 0x80000000u; i != 0u; i >>= 1, v ^= v >> 1) {
        if ((i & 1u) != 0u) y ^= v;
    }
    return y;
}

// The 2D point of sample `index` in the scrambled sequence `seed` (a pixel's, for one pair of dimensions), in [0, 1)^2.
inline float2 owenSobol2(uint index, uint seed) {
    uint i = nestedUniformScramble(index, pcgHash(seed));                  // the shuffled index
    uint x = reverse_bits(i);
    uint y = sobolSecond(i);
    x = nestedUniformScramble(x, pcgHash(seed ^ 0xa511e9b3u));
    y = nestedUniformScramble(y, pcgHash(seed ^ 0x63d83595u));
    return float2(uint2(x, y) >> 8u) * (1.0f / 16777216.0f);
}
