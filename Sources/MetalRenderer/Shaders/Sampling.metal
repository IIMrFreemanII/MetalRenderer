// ---------------------------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------------------------

inline float luminance(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

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
