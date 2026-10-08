// ---------------------------------------------------------------------------------------------
// Particles as rays meet them (PARTICLES): billboards in boxes of their own structure (TraceScene.particles)
// ---------------------------------------------------------------------------------------------

// Every particle is a box in one of two primitive structures, rebuilt every frame (ParticlesGPU.Build): the shadow
// casters' (the pool's first slots) and the others' (shadow rays don't look through those). Its slot in the pool is
// its primitive id (plus the casters' count in the others'), and an empty slot is a box far away. The structures are
// separate from the scene's TLAS,
// so rays that don't look for particles never meet them, and the queries here run up to the opaque hit's distance.
// A box holds a billboard that each ray computes for itself (particleBillboard): a disc square to the ray, or a quad
// along an axis turned to face it, or one fixed in the world. Camera, shadow and reflection rays all see the same
// particle, which a camera-facing quad wouldn't give (edge-on to the light). Nothing is committed: the loops gather
// what they meet (particleTransmittance; the camera's layer, Particles.metal).

// ParticleEmitter.Flags as the rays get them (ParticleRender.info.x >> 24): the low three, then the orientation.
constant uint PARTICLE_EMISSIVE = 1u, PARTICLE_SHADOWS = 2u, PARTICLE_FRAME_BLEND = 4u;
constant uint PARTICLE_ORIENT_SHIFT = 3u;   // 0 ray-facing, 1 velocity, 2 axis, 3 world
constant uint PARTICLE_GRID = 8;             // ParticleTextures.grid: frames per row of an atlas layer
constant uint PARTICLES_REFLECTED = 1u;      // TraceScene.particleFlags: reflection rays see them

struct ParticleRender {
    float4 centerRadius;   // w = radius (0: none)
    float4 axis;           // velocity / axis: the long axis's half; world: the normal; w = spin
    half4  color;          // rgb: albedo (lit) or emitted light (emissive), a: opacity
    half4  radiance;       // rgb: the light it scatters (particleLightKernel)
    uint4  info;           // emitter | layer << 16 | flags << 24; frames (first | second << 6 | blend << 12);
                           // half2(soft distance, shadow density); seed
};
static_assert(sizeof(ParticleRender) == 64, "ParticleRender: GPUParticleRender");

inline uint particleFlags(ParticleRender r) { return r.info.x >> 24; }
inline float particleSoft(ParticleRender r) { return float(as_type<half2>(r.info.z).x); }
inline float particleShadowDensity(ParticleRender r) { return float(as_type<half2>(r.info.z).y); }

// Two unit vectors across unit n, turned by `spin`.
inline void particleAcross(float3 n, float spin, thread float3& u, thread float3& v) {
    float3 helper = abs(n.y) < 0.999f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 u0 = normalize(cross(helper, n)), v0 = cross(n, u0);
    float c = cos(spin), s = sin(spin);
    u = u0 * c + v0 * s;
    v = v0 * c - u0 * s;
}

// Where the ray o + d t meets particle r's billboard: t (in d's units, as every ray's) and uv, in [-1, 1] across
// it (y up its long axis). False if the ray runs along its plane.
inline bool particleBillboard(ParticleRender r, float3 o, float3 d, thread float& t, thread float2& uv) {
    float3 c = r.centerRadius.xyz;
    float radius = r.centerRadius.w;
    uint orient = (particleFlags(r) >> PARTICLE_ORIENT_SHIFT) & 3u;
    float3 n, u, v;
    float2 size = float2(radius);
    if (orient == 1u || orient == 2u) {
        // A quad along the axis, turned about it to face the ray.
        float h = length(r.axis.xyz);
        float3 a = r.axis.xyz / max(h, 1e-12f);
        float3 w = cross(a, d);
        float lw = length(w);
        if (lw < 1e-6f * length(d)) return false;
        u = w / lw;
        v = a;
        n = cross(u, v);
        size.y = h;
    } else {
        n = orient == 3u ? r.axis.xyz : -normalize(d);
        particleAcross(n, r.axis.w, u, v);
    }
    float dn = dot(d, n);
    if (abs(dn) < 1e-8f) return false;
    t = dot(c - o, n) / dn;
    float3 p = o + d * t - c;
    uv = float2(dot(p, u), dot(p, v)) / size;
    return true;
}

// Particle r's flipbook at uv: its frame, blended into the next (the atlas's linear filter within each).
inline float4 particleTexel(ParticleRender r, float2 uv, texture2d_array<float> atlas) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    uint layer = (r.info.x >> 16) & 0xFFu, frames = r.info.y;
    uint f0 = frames & 63u, f1 = (frames >> 6) & 63u;
    float blend = float(frames >> 12) * (1.0f / 65535.0f);
    float2 st = float2(uv.x, -uv.y) * 0.5f + 0.5f;   // the picture's top at uv.y = 1
    const float cell = 1.0f / float(PARTICLE_GRID);
    float2 a = (float2(float(f0 % PARTICLE_GRID), float(f0 / PARTICLE_GRID)) + st) * cell;
    float4 s = atlas.sample(linear, a, layer, level(0.0f));
    if ((particleFlags(r) & PARTICLE_FRAME_BLEND) != 0u && blend > 0.0f) {
        float2 b = (float2(float(f1 % PARTICLE_GRID), float(f1 / PARTICLE_GRID)) + st) * cell;
        s = mix(s, atlas.sample(linear, b, layer, level(0.0f)), blend);
    }
    return s;
}

// How much of the light along the ray o + d t, t in (tmin, tmax), gets through the particles that cast shadows: the
// product of (1 - opacity) of every one it crosses, in any order. Zero once under 1%.
inline float particleTransmittance(float3 o, float3 d, float tmin, float tmax, SCENE_ACCEL sc) {
    if (sc.particleCounts.x == 0u) return 1.0f;
    intersection_query<> q;
    intersection_params params;
    params.assume_geometry_type(geometry_type::bounding_box);
    params.accept_any_intersection(false);
    q.reset(ray(o, d, tmin, tmax), sc.particleCasters, params);
    float T = 1.0f;
    while (q.next()) {
        ParticleRender r = sc.particleRender[q.get_candidate_primitive_id()];
        if ((particleFlags(r) & PARTICLE_SHADOWS) == 0u) continue;
        float t;
        float2 uv;
        if (!particleBillboard(r, o, d, t, uv) || t <= tmin || t >= tmax || any(abs(uv) > 1.0f)) continue;
        float alpha = float(r.color.a) * particleTexel(r, uv, sc.particleAtlas).a * particleShadowDensity(r);
        T *= 1.0f - saturate(alpha);
        if (T < 0.01f) { T = 0.0f; q.abort(); break; }
    }
    return T;
}

// A fragment of what a ray sees of the particles: how far, how opaque, and the light it sends (premultiplied).
struct ParticleFragment {
    float  t;
    float  alpha;
    float3 rgb;
};

// `front` over `back`.
inline ParticleFragment particleOver(ParticleFragment front, ParticleFragment back) {
    ParticleFragment f = front;
    f.rgb = front.rgb + (1.0f - front.alpha) * back.rgb;
    f.alpha = front.alpha + (1.0f - front.alpha) * back.alpha;
    return f;
}

// Keeps the K nearest fragments sorted by distance; past that the two farthest merge (the nearer over the farther),
// so a crowd of particles costs no more registers (a k-buffer, merged as MLAB does). With at most K fragments the
// result is exact, and doesn't depend on the order the traversal hands them over.
template <uint K>
inline void particleInsert(thread ParticleFragment* k, thread uint& n, ParticleFragment f) {
    if (n == K && f.t >= k[K - 1].t) {
        k[K - 1] = particleOver(k[K - 1], f);
        return;
    }
    ParticleFragment out = k[K - 1];
    bool full = n == K;
    uint j = full ? K - 1 : n;
    while (j > 0 && k[j - 1].t > f.t) { k[j] = k[j - 1]; --j; }
    k[j] = f;
    if (full) k[K - 1] = particleOver(k[K - 1], out);
    else ++n;
}

// What the ray o + d t (d unit) sees of the particles in (0, tmax), front to back: rgb = the light they send, a = how
// much of what is behind them they hide. `soft`: tmax is a surface they fade in front of (soft particles); they fade
// right in front of the ray's origin too. `meanT`: their distance weighted by what each hides (x a).
// One structure's candidates along o + d t into the k-buffer (`base`: its first slot).
template <uint K>
inline void particleCollect(primitive_acceleration_structure structure, uint base, float3 o, float3 d, float tmax, bool soft,
                            SCENE_ACCEL sc, thread ParticleFragment* k, thread uint& n) {
    intersection_query<> q;
    intersection_params params;
    params.assume_geometry_type(geometry_type::bounding_box);
    q.reset(ray(o, d, 0.0f, tmax), structure, params);
    while (q.next()) {
        ParticleRender r = sc.particleRender[base + q.get_candidate_primitive_id()];
        if (r.centerRadius.w <= 0.0f) continue;
        float t;
        float2 uv;
        if (!particleBillboard(r, o, d, t, uv) || t <= 0.0f || t >= tmax || any(abs(uv) > 1.0f)) continue;
        float4 tex = particleTexel(r, uv, sc.particleAtlas);
        float distance = particleSoft(r);
        float fade = soft && distance > 0.0f ? saturate((tmax - t) / distance) : 1.0f;
        fade *= saturate((t - 0.05f) / 0.25f);
        ParticleFragment f;
        f.t = t;
        f.alpha = saturate(float(r.color.a) * tex.a) * fade;
        f.rgb = (particleFlags(r) & PARTICLE_EMISSIVE) != 0u ? float3(r.color.rgb) * tex.rgb * (tex.a * fade)
                                                           : f.alpha * float3(r.color.rgb) * tex.rgb * float3(r.radiance.rgb);
        if (f.alpha < 1.0f / 255.0f && all(f.rgb < 1e-4f)) continue;
        particleInsert<K>(k, n, f);
    }
}

// What the ray o + d t (d unit) sees of the particles in (0, tmax), front to back: rgb = the light they send, a = how
// much of what is behind them they hide. `soft`: tmax is a surface they fade in front of (soft particles); they fade
// right in front of the ray's origin too. `meanT`: their distance weighted by what each hides (x a).
template <uint K>
inline float4 particleGather(float3 o, float3 d, float tmax, bool soft, SCENE_ACCEL sc, thread float& meanT) {
    ParticleFragment k[K];
    uint n = 0;
    if (sc.particleCounts.x > 0u) particleCollect<K>(sc.particleCasters, 0u, o, d, tmax, soft, sc, k, n);
    if (sc.particleCounts.y > 0u) particleCollect<K>(sc.particleOthers, sc.particleCounts.x, o, d, tmax, soft, sc, k, n);
    float3 c = float3(0.0f);
    float T = 1.0f;
    meanT = 0.0f;
    for (uint j = 0; j < n; ++j) {
        c += T * k[j].rgb;
        meanT += T * k[j].alpha * k[j].t;
        T *= 1.0f - k[j].alpha;
    }
    return float4(c, 1.0f - T);
}

// MARK: - The reference path tracer's particles (PathTrace.metal)

// What a path meets of the particles before tmax: each one in its way stops it with the chance of its opacity, and
// the nearest that does is the event (`hit`: its distance, and a lit one's albedo: it scatters, isotropically; an
// emissive one ends the path). `emission`: the light of the emissive ones up to there. On average the layer's
// front-to-back composite (particleGather), exactly, whatever the order.
struct ParticleScatter {
    bool   hit;
    bool   emissive;
    float  t;
    float3 albedo;
    float3 emission;
};

// One structure's candidates: `pass` 0 finds the nearest that stops the path, 1 adds the light of the emissive ones
// up to it. `seed`: the path's for this ray (each candidate's chance from it and its slot).
inline void particleScatterPass(primitive_acceleration_structure structure, uint base, uint pass, float3 o, float3 d, float tmax,
                                uint seed, SCENE_ACCEL sc, thread ParticleScatter& e) {
    intersection_query<> q;
    intersection_params params;
    params.assume_geometry_type(geometry_type::bounding_box);
    q.reset(ray(o, d, 0.0f, pass == 0u ? tmax : min(tmax, e.t * 1.0001f)), structure, params);
    while (q.next()) {
        uint slot = base + q.get_candidate_primitive_id();
        ParticleRender r = sc.particleRender[slot];
        if (r.centerRadius.w <= 0.0f) continue;
        float t;
        float2 uv;
        if (!particleBillboard(r, o, d, t, uv) || t <= 0.0f || t >= tmax || any(abs(uv) > 1.0f)) continue;
        float4 tex = particleTexel(r, uv, sc.particleAtlas);
        float distance = particleSoft(r);
        float fade = !isFar(tmax) && distance > 0.0f ? saturate((tmax - t) / distance) : 1.0f;
        fade *= saturate((t - 0.05f) / 0.25f);
        bool emissive = (particleFlags(r) & PARTICLE_EMISSIVE) != 0u;
        if (pass == 1u) {
            if (emissive && t <= e.t) e.emission += float3(r.color.rgb) * tex.rgb * (tex.a * fade);
            continue;
        }
        float alpha = saturate(float(r.color.a) * tex.a) * fade;
        float u = float(pcgHash(seed ^ pcgHash(slot * 0x9E3779B9u + 0x7F4A7C15u)) >> 8) * (1.0f / 16777216.0f);
        if (u < alpha && t < e.t) {
            e.hit = true;
            e.t = t;
            e.emissive = emissive;
            e.albedo = float3(r.color.rgb) * tex.rgb;
        }
    }
}

inline ParticleScatter particleScatter(float3 o, float3 d, float tmax, uint seed, SCENE_ACCEL sc) {
    ParticleScatter e;
    e.hit = false;
    e.emissive = false;
    e.t = tmax;
    e.albedo = float3(0.0f);
    e.emission = float3(0.0f);
    for (uint pass = 0; pass < 2; ++pass) {
        if (sc.particleCounts.x > 0u) particleScatterPass(sc.particleCasters, 0u, pass, o, d, tmax, seed, sc, e);
        if (sc.particleCounts.y > 0u) particleScatterPass(sc.particleOthers, sc.particleCounts.x, pass, o, d, tmax, seed, sc, e);
    }
    return e;
}
