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
// what they meet (particleTransmittance; the camera's layer, ParticleLight.metal).

// ParticleEmitter.Flags as the rays get them (ParticleRender.info.x >> 24): the low three, then the orientation.
constant uint PARTICLE_EMISSIVE = 1u, PARTICLE_SHADOWS = 2u, PARTICLE_FRAME_BLEND = 4u, PARTICLE_SIXWAY = 32u, PARTICLE_MOTION = 64u;
constant uint PARTICLE_ORIENT_SHIFT = 3u;   // 0 ray-facing, 1 velocity, 2 axis, 3 world
constant uint PARTICLE_GRID = 8;             // ParticleTextures.grid: frames per row of an atlas layer
constant uint PARTICLE_KINDS = 8;            // ParticleTextures.Kind: the aux layers follow (Aux)
constant float PARTICLE_MOTION_RANGE = 0.1f; // ParticleTextures.motionRange
constant uint PARTICLES_REFLECTED = 1u;      // TraceScene.particleFlags: reflection rays see them

struct ParticleRender {
    float4 centerRadius;   // w = radius (0: none)
    float4 axis;           // velocity / axis: the long axis's half; world: the normal; w = spin
    half4  color;          // rgb: albedo (lit) or emitted light (emissive), a: opacity
    half4  radiance;       // rgb: the light it scatters (particleLightKernel)
    uint4  info;           // pool slot | flags << 24; frames (first | second << 6 | blend << 12);
                           // soft distance (half) | shadow density x 255 << 16 | atlas layer << 24; seed
    half4  keyLight;       // rgb: the light of its brightest light, apart from `radiance` (six-way smoke)
    half4  keyDir;         // xyz: where that light comes from (unit)
};
static_assert(sizeof(ParticleRender) == 80, "ParticleRender: GPUParticleRender");

// A trail's look this frame (particleTrailPoseKernel); its control points are TraceScene.trailPoints.
struct ParticleTrail {
    half4 color;           // rgb: albedo (lit) or emitted light (emissive), a: opacity (at its head)
    half4 radiance;        // lit: the light its particle scatters
    uint4 info;            // flags (the low three of ParticleRender's), alive, the particle's slot
};
static_assert(sizeof(ParticleTrail) == 32, "ParticleTrail: ParticlesGPU.trailRecordSize");

inline uint particleFlags(ParticleRender r) { return r.info.x >> 24; }
inline float particleSoft(ParticleRender r) { return float(as_type<half>(ushort(r.info.z & 0xFFFFu))); }
inline float particleShadowDensity(ParticleRender r) { return float((r.info.z >> 16) & 0xFFu) * (1.0f / 255.0f); }

// Two unit vectors across unit n, turned by `spin`.
inline void particleAcross(float3 n, float spin, thread float3& u, thread float3& v) {
    float3 helper = abs(n.y) < 0.999f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 u0 = normalize(cross(helper, n)), v0 = cross(n, u0);
    float c = cos(spin), s = sin(spin);
    u = u0 * c + v0 * s;
    v = v0 * c - u0 * s;
}

// Where the ray o + d t meets particle r's billboard: t (in d's units, as every ray's) and uv, in [-1, 1] across
// it (y up its long axis). False if the ray runs along its plane. `widen`: its half-size at least this x t (the
// camera's: about a texel of the layer, so a spark thinner than that isn't hit by one ray and missed by the next),
// its opacity then times `cover`, the share of the widened billboard the real one covers (the same light overall).
inline bool particleBillboard(ParticleRender r, float3 o, float3 d, float widen, thread float& t, thread float2& uv, thread float& cover,
                              thread float3& u, thread float3& v) {
    float3 c = r.centerRadius.xyz;
    float radius = r.centerRadius.w;
    uint orient = (particleFlags(r) >> PARTICLE_ORIENT_SHIFT) & 3u;
    float3 n;
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
    float2 wide = max(size, float2(widen * abs(t)));
    cover = (size.x / wide.x) * (size.y / wide.y);
    uv = float2(dot(p, u), dot(p, v)) / wide;
    return true;
}

inline bool particleBillboard(ParticleRender r, float3 o, float3 d, float widen, thread float& t, thread float2& uv, thread float& cover) {
    float3 u, v;
    return particleBillboard(r, o, d, widen, t, uv, cover, u, v);
}

// Where particle r's flipbook is read at uv: its frame and the next, and how far it is between them. With motion
// (PARTICLE_MOTION) each is read where its picture's motion puts uv at that point between them (frame f0's moved on
// by `blend` of a frame, f1's back by the rest), so the blend doesn't cross-fade two copies of a moving lick.
struct ParticleFrames {
    float2 a, b;     // atlas coordinates in frame f0's cell and f1's
    float  blend;    // 0: only a
};

// Kind `layer`'s motion layer (ParticleTextures.motionLayer), 0: none.
inline uint particleMotionLayer(uint layer) { return layer == 1u ? PARTICLE_KINDS + 1u : layer == 2u ? PARTICLE_KINDS + 2u : 0u; }

// `motion`: follow it (the camera's rays; a shadow's or a reflection's don't: it doesn't show there).
inline ParticleFrames particleFrames(ParticleRender r, float2 uv, texture2d_array<float> atlas, bool motion = true) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    uint frames = r.info.y, flags = particleFlags(r);
    uint f0 = frames & 63u, f1 = (frames >> 6) & 63u;
    ParticleFrames f;
    f.blend = (flags & PARTICLE_FRAME_BLEND) != 0u ? float(frames >> 12) * (1.0f / 65535.0f) : 0.0f;
    float2 st = float2(uv.x, -uv.y) * 0.5f + 0.5f;   // the picture's top at uv.y = 1
    const float cell = 1.0f / float(PARTICLE_GRID);
    float2 c0 = float2(float(f0 % PARTICLE_GRID), float(f0 / PARTICLE_GRID)), c1 = float2(float(f1 % PARTICLE_GRID), float(f1 / PARTICLE_GRID));
    f.a = (c0 + st) * cell;
    f.b = (c1 + st) * cell;
    uint layer = particleMotionLayer(r.info.z >> 24);
    if (motion && (flags & PARTICLE_MOTION) != 0u && layer != 0u && f.blend > 0.0f) {
        // The motion is in the picture's units (-1...1 across, y up) a frame: half that across a cell, y down.
        float2 m0 = (atlas.sample(linear, f.a, layer, level(0.0f)).ba - 0.5f) * (2.0f * PARTICLE_MOTION_RANGE);
        float2 m1 = (atlas.sample(linear, f.b, layer, level(0.0f)).ba - 0.5f) * (2.0f * PARTICLE_MOTION_RANGE);
        f.a = (c0 + saturate(st - float2(m0.x, -m0.y) * (0.5f * f.blend))) * cell;
        f.b = (c1 + saturate(st + float2(m1.x, -m1.y) * (0.5f * (1.0f - f.blend)))) * cell;
    }
    return f;
}

// Layer `layer` at those places, blended.
inline float4 particleSample(ParticleFrames f, uint layer, texture2d_array<float> atlas) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float4 s = atlas.sample(linear, f.a, layer, level(0.0f));
    return f.blend > 0.0f ? mix(s, atlas.sample(linear, f.b, layer, level(0.0f)), f.blend) : s;
}

// Particle r's flipbook at uv: its frame, blended into the next (the atlas's linear filter within each).
inline float4 particleTexel(ParticleRender r, float2 uv, texture2d_array<float> atlas, bool motion = true) {
    return particleSample(particleFrames(r, uv, atlas, motion), r.info.z >> 24, atlas);
}

// The light a lit particle sends the eye a unit of its albedo, at a point of its billboard (across it `u`, up it
// `v`) seen along `d`: its light (particleLightKernel). Six-way smoke (PARTICLE_SIXWAY) takes it apart: what comes
// from all round through the six maps' mean, its brightest light through the maps of the directions it comes from
// (in the billboard's frame, each weighed by the square of its share: they sum to one), so a dense puff is dark on
// its far side and glows lit from behind. A thin one passes on all of each: the isotropic answer. `full`: the
// camera's rays (a reflection's take the isotropic answer: cheaper, and blurred anyway).
inline float3 particleLit(ParticleRender r, ParticleFrames f, float3 u, float3 v, float3 d, texture2d_array<float> atlas, bool full) {
    float3 around = float3(r.radiance.rgb), key = float3(r.keyLight.rgb);
    if (!full || (particleFlags(r) & PARTICLE_SIXWAY) == 0u) return around + key;
    float4 side = particleSample(f, PARTICLE_KINDS, atlas);
    float2 fb = particleSample(f, PARTICLE_KINDS + 1u, atlas).rg;
    float3 l = float3(r.keyDir.xyz);
    float lx = dot(l, u), ly = dot(l, v), lz = -dot(l, d);   // z: toward the eye (the front)
    float response = lx * lx * (lx > 0.0f ? side.x : side.y) + ly * ly * (ly > 0.0f ? side.z : side.w)
                   + lz * lz * (lz > 0.0f ? fb.x : fb.y);
    return around * ((side.x + side.y + side.z + side.w + fb.x + fb.y) * (1.0f / 6.0f)) + key * response;
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
        float t, cover;
        float2 uv;
        if (!particleBillboard(r, o, d, 0.0f, t, uv, cover) || t <= tmin || t >= tmax || any(abs(uv) > 1.0f)) continue;
        float alpha = float(r.color.a) * particleTexel(r, uv, sc.particleAtlas, false).a * particleShadowDensity(r);
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
// `detail` (> 0): a particle narrower than this x its distance (half-size) that shows sets `thin` and is left out (the
// camera's layer: one its texels are too coarse for, which the overlay traces again at the output's size, where
// only its own pixels show it: in the layer, the upsampling would spread it round them as a blurred halo).
// `full`: the camera's (motion-vector frames, six-way smoke); a reflection's go without.
template <uint K>
inline void particleCollect(primitive_acceleration_structure structure, uint base, float3 o, float3 d, float tmax, bool soft,
                            float widen, float detail, bool full, SCENE_ACCEL sc, thread ParticleFragment* k, thread uint& n, thread bool& thin) {
    intersection_query<> q;
    intersection_params params;
    params.assume_geometry_type(geometry_type::bounding_box);
    q.reset(ray(o, d, 0.0f, tmax), structure, params);
    while (q.next()) {
        ParticleRender r = sc.particleRender[base + q.get_candidate_primitive_id()];
        if (r.centerRadius.w <= 0.0f) continue;
        float t, cover;
        float2 uv;
        float3 bu, bv;
        if (!particleBillboard(r, o, d, widen, t, uv, cover, bu, bv) || t <= 0.0f || t >= tmax || any(abs(uv) > 1.0f)) continue;
        ParticleFrames frames = particleFrames(r, uv, sc.particleAtlas, full);
        float4 tex = particleSample(frames, r.info.z >> 24, sc.particleAtlas);
        float distance = particleSoft(r);
        float fade = soft && distance > 0.0f ? saturate((tmax - t) / distance) : 1.0f;
        fade *= saturate((t - 0.05f) / 0.25f) * cover;
        ParticleFragment f;
        f.t = t;
        f.alpha = saturate(float(r.color.a) * tex.a) * fade;
        if (f.alpha < 1.0f / 255.0f && (particleFlags(r) & PARTICLE_EMISSIVE) == 0u) continue;
        f.rgb = (particleFlags(r) & PARTICLE_EMISSIVE) != 0u ? float3(r.color.rgb) * tex.rgb * (tex.a * fade)
                                                           : f.alpha * float3(r.color.rgb) * tex.rgb * particleLit(r, frames, bu, bv, d, sc.particleAtlas, full);
        if (f.alpha < 1.0f / 255.0f && all(f.rgb < 1e-4f)) continue;
        // Too thin for these rays (and showing: an invisible one isn't worth tracing again): the overlay's.
        if (detail > 0.0f && (cover < 1.0f || r.centerRadius.w < detail * t)) { thin = true; continue; }
        particleInsert<K>(k, n, f);
    }
}

// A uniform Catmull-Rom segment between c1 and c2 at u (Metal's curve_basis::catmull_rom).
inline float3 particleCatmullRom(float3 c0, float3 c1, float3 c2, float3 c3, float u) {
    float u2 = u * u, u3 = u2 * u;
    return 0.5f * ((2.0f * c1) + (c2 - c0) * u + (2.0f * c0 - 5.0f * c1 + 4.0f * c2 - c3) * u2 + (3.0f * c1 - c0 - 3.0f * c2 + c3) * u3);
}

// The trails' ribbons along o + d t into the k-buffer: flat curves that face the ray (TraceScene.particleTrails), each
// hit softened across the ribbon (by its distance from the curve's axis there) and faded along it, from nothing at
// its end to the particle's opacity at its head; as particleCollect, `widen` and `detail`.
template <uint K>
inline void particleCollectTrails(float3 o, float3 d, float tmax, float widen, float detail, SCENE_ACCEL sc,
                                  thread ParticleFragment* k, thread uint& n, thread bool& thin) {
    intersection_query<curve_data> q;
    intersection_params params;
    params.assume_geometry_type(geometry_type::curve);
    params.assume_curve_type(curve_type::flat);
    params.assume_curve_basis(curve_basis::catmull_rom);
    params.assume_curve_control_point_count(4);
    q.reset(ray(o, d, 0.0f, tmax), sc.particleTrails, params);
    uint m = sc.trailShape.y, per = m - 3u;
    while (q.next()) {
        if (q.get_candidate_intersection_type() != intersection_type::curve) continue;
        uint seg = q.get_candidate_primitive_id();
        float t = q.get_candidate_curve_distance(), u = q.get_candidate_curve_parameter();
        if (t <= 0.0f || t >= tmax) continue;
        uint trail = seg / per, j = seg % per;
        ParticleTrail r = sc.trailRecords[trail];
        if (r.info.y == 0u) continue;
        device const float4* c = sc.trailPoints + trail * m + j;
        float real = mix(c[1].w, c[2].w, u);
        float wide = max(real, widen * t);
        if (wide <= 0.0f) continue;
        float across = length(o + d * t - particleCatmullRom(c[0].xyz, c[1].xyz, c[2].xyz, c[3].xyz, u)) / wide;
        if (across >= 1.0f) continue;
        if (detail > 0.0f && real < detail * t) { thin = true; continue; }
        float along = (float(j) + u + 1.0f) / float(per + 1u);   // its end to its head
        ParticleFragment f;
        f.t = t;
        f.alpha = saturate(float(r.color.a) * along * (1.0f - across * across)) * (real / wide) * saturate((t - 0.05f) / 0.25f);
        f.rgb = (r.info.x & PARTICLE_EMISSIVE) != 0u ? float3(r.color.rgb) * f.alpha
                                                      : f.alpha * float3(r.color.rgb) * float3(r.radiance.rgb);
        if (f.alpha < 1.0f / 255.0f) continue;
        particleInsert<K>(k, n, f);
    }
}

// What the ray o + d t (d unit) sees of the particles in (0, tmax), front to back: rgb = the light they send, a = how
// much of what is behind them they hide. `soft`: tmax is a surface they fade in front of (soft particles); they fade
// right in front of the ray's origin too. `meanT`: their distance weighted by what each hides (x a). `widen`:
// particleBillboard's (0: as they are). The trails' ribbons too.
template <uint K>
inline float4 particleGather(float3 o, float3 d, float tmax, bool soft, SCENE_ACCEL sc, thread float& meanT, float widen,
                             float detail, thread bool& thin, bool full = true) {
    ParticleFragment k[K];
    uint n = 0;
    thin = false;
    if (sc.particleCounts.x > 0u) particleCollect<K>(sc.particleCasters, 0u, o, d, tmax, soft, widen, detail, full, sc, k, n, thin);
    if (sc.particleCounts.y > 0u) particleCollect<K>(sc.particleOthers, sc.particleCounts.x, o, d, tmax, soft, widen, detail, full, sc, k, n, thin);
    if (sc.trailShape.x > 0u) particleCollectTrails<K>(o, d, tmax, widen, detail, sc, k, n, thin);
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

template <uint K>
inline float4 particleGather(float3 o, float3 d, float tmax, bool soft, SCENE_ACCEL sc, thread float& meanT) {
    bool thin;
    return particleGather<K>(o, d, tmax, soft, sc, meanT, 0.0f, 0.0f, thin, false);
}

// The layer at `uv` for a pixel whose surface is at `depth` (0: the sky): its four nearest texels bilinearly, each
// weighed by how near its own surface's depth is to this one's, so particles behind an edge don't bleed over what
// stands in front of them (nor the reverse) when the layer is coarser than the picture. Plain bilinear where none is
// near.
// The cubic B-spline's four weights at fraction f: smooth, so a texel magnified threefold comes out a round blob,
// not bilinear's square. (Catmull-Rom, sharper, rings on the sparks' bright cores; clamped, it is blocky again.)
inline float4 particleSpline(float f) {
    float g = 1.0f - f;
    return float4(g * g * g, 4.0f - 6.0f * f * f + 3.0f * f * f * f, 4.0f - 6.0f * g * g + 3.0f * g * g * g, f * f * f) * (1.0f / 6.0f);
}

// `thin`: a texel near it (of the four it lies between) has particles too thin for the layer's texels.
inline float4 particleUpsample(texture2d<float, access::read> layer, texture2d<float, access::read> layerDepth, float2 uv, float depth,
                               thread bool& thin) {
    int2 size = int2(layer.get_width(), layer.get_height());
    float2 p = uv * float2(size) - 0.5f;
    int2 i0 = int2(floor(p)) - 1;
    float2 f = p - floor(p);
    float4 wx = particleSpline(f.x), wy = particleSpline(f.y);
    float d = depth > 0.0f ? depth : 1.0e5f;
    float4 sum = float4(0.0f), plain = float4(0.0f);
    float total = 0.0f;
    thin = false;
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            int2 q = clamp(i0 + int2(x, y), int2(0), size - 1);
            float w = wx[x] * wy[y];
            float4 v = layer.read(uint2(q));
            float2 dt = layerDepth.read(uint2(q)).xy;
            if ((x == 1 || x == 2) && (y == 1 || y == 2) && dt.y > 0.0f) thin = true;
            float dq = dt.x;
            dq = dq > 0.0f ? dq : 1.0e5f;
            float near = exp(-abs(dq - d) / (0.03f * min(d, dq) + 0.02f));
            sum += v * (w * near);
            total += w * near;
            plain += v * w;
        }
    }
    return total > 1e-3f ? sum / total : plain;
}

inline float4 particleUpsample(texture2d<float, access::read> layer, texture2d<float, access::read> layerDepth, float2 uv, float depth) {
    bool thin;
    return particleUpsample(layer, layerDepth, uv, depth, thin);
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
        ParticleRender r = sc.particleRender[base + q.get_candidate_primitive_id()];
        if (r.centerRadius.w <= 0.0f) continue;
        float t, cover;
        float2 uv;
        if (!particleBillboard(r, o, d, 0.0f, t, uv, cover) || t <= 0.0f || t >= tmax || any(abs(uv) > 1.0f)) continue;
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
        float u = float(pcgHash(seed ^ pcgHash(r.info.w * 0x9E3779B9u + 0x7F4A7C15u)) >> 8) * (1.0f / 16777216.0f);
        if (u < alpha && t < e.t) {
            e.hit = true;
            e.t = t;
            e.emissive = emissive;
            e.albedo = float3(r.color.rgb) * tex.rgb;
        }
    }
}

// The trails' ribbons as particleScatterPass takes the boxes' (a ribbon is a fragment as particleCollectTrails has it:
// faded along it and across it; its chance from the path's seed and its segment).
inline void particleScatterTrails(uint pass, float3 o, float3 d, float tmax, uint seed, SCENE_ACCEL sc, thread ParticleScatter& e) {
    intersection_query<curve_data> q;
    intersection_params params;
    params.assume_geometry_type(geometry_type::curve);
    params.assume_curve_type(curve_type::flat);
    params.assume_curve_basis(curve_basis::catmull_rom);
    params.assume_curve_control_point_count(4);
    q.reset(ray(o, d, 0.0f, pass == 0u ? tmax : min(tmax, e.t * 1.0001f)), sc.particleTrails, params);
    uint m = sc.trailShape.y, per = m - 3u;
    while (q.next()) {
        if (q.get_candidate_intersection_type() != intersection_type::curve) continue;
        uint seg = q.get_candidate_primitive_id();
        float t = q.get_candidate_curve_distance(), u = q.get_candidate_curve_parameter();
        if (t <= 0.0f || t >= tmax) continue;
        uint trail = seg / per, j = seg % per;
        ParticleTrail r = sc.trailRecords[trail];
        if (r.info.y == 0u) continue;
        device const float4* c = sc.trailPoints + trail * m + j;
        float real = mix(c[1].w, c[2].w, u);
        if (real <= 0.0f) continue;
        float across = length(o + d * t - particleCatmullRom(c[0].xyz, c[1].xyz, c[2].xyz, c[3].xyz, u)) / real;
        if (across >= 1.0f) continue;
        float along = (float(j) + u + 1.0f) / float(per + 1u);
        float alpha = saturate(float(r.color.a) * along * (1.0f - across * across)) * saturate((t - 0.05f) / 0.25f);
        bool emissive = (r.info.x & PARTICLE_EMISSIVE) != 0u;
        if (pass == 1u) {
            if (emissive && t <= e.t) e.emission += float3(r.color.rgb) * alpha;
            continue;
        }
        float chance = float(pcgHash(seed ^ pcgHash(seg * 0x2C1B3C6Du + 0x297A2D39u)) >> 8) * (1.0f / 16777216.0f);
        if (chance < alpha && t < e.t) {
            e.hit = true;
            e.t = t;
            e.emissive = emissive;
            e.albedo = float3(r.color.rgb);
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
        if (sc.trailShape.x > 0u) particleScatterTrails(pass, o, d, tmax, seed, sc, e);
    }
    return e;
}
