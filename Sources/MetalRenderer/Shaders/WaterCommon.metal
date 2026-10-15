// ---------------------------------------------------------------------------------------------
// Water (WATER scenes: Scene+Water.swift): what every kernel that meets it needs. The
// frame's WaterScene (Renderer+Water.swift) holds the looks, the water map around the camera (where the water is,
// how deep and how it flows: WaterMap.swift) and the waves: the FFT ocean's cascades (waterFFT*Kernel, Water.metal),
// or, until they are drawn, a few analytic waves.
// ---------------------------------------------------------------------------------------------

struct WaterLook {
    float4 absorption;   // rgb = per metre, w = index of refraction
    float4 scattering;   // rgb = per metre, w = phase g
    float4 waves;        // x = share of the wind's sea, y = chop, z = ripples, w = roughness
    float4 foam;         // x = crest foam, y = shore foam width (m), z = white water, w = flow speed (m/s)
};

struct WaterScene {
    float4 time;         // x = now (s), y = last frame's, z = dt, w = the highest any water's surface reaches
    float4 wind;         // xy = toward where it blows (x, z), z = speed (m/s)
    float4 cascades;     // xyz = the FFT cascades' tile sides (m), w = how many
    float4 phase0;       // where the scene's origin is in each cascade's tile (m): xy = 0th, zw = 1st
    float4 phase1;       // xy = 2nd
    float4 map0;         // near level: xy = scene x, z of texel (0, 0)'s corner, z = metres a texel, w = texels a side
    float4 map1;         // far level
    float4 near;         // xyz = the near patch's centre, w = its radius (0: none)
    uint4  counts;       // x = looks, y = WATER_* flags, w = METALRENDERER_WATER_DEBUG
    device const WaterLook* looks;
    texture2d_array<float>  level;           // map: [0] near, [1] far; r = surface (WATER_DRY: none), g = ground
    texture2d_array<float>  info;            // map: rg = flow (v / 8 + 0.5), b = look / 255, a = turbulence
    texture2d_array<float>  waves;           // FFT: per cascade, xyz = displacement (m), w = foam
    texture2d_array<float>  slopes;          // FFT: per cascade, xy = the height's slope (x, z), zw = d(push x)/dx, d(push z)/dz
    texture2d<float>        caustics;        // the sun's caustics a few metres down, tiled as cascade 1
    primitive_acceleration_structure surfaces;   // the still surfaces' own structure (the scene's coordinates)
    device const float4*    surfaceVertices;
    device const uint*      surfaceIndices;
    device const uchar*     surfaceLooks;    // per triangle
    primitive_acceleration_structure nearPatch;  // WATER_NEAR: the near patch, its vertices moved by the waves
    device const float4*    nearVertices;    // w = the look
    device const uint*      nearIndices;
    device const float2*    nearRest;        // where each vertex is at rest (x, z)
};
static_assert(sizeof(WaterScene) == 256, "WaterScene: GPUWaterScene");

constant uint WATER_FFT = 1, WATER_NEAR = 2, WATER_CAUSTICS = 4, WATER_MAPPED = 8;
constant float WATER_DRY = -1e8f;

// What the camera's ray through water (waterKernel) leaves the trace and waterApplyKernel in the liquid's targets:
// the bent ray's w = 2 + these flags (1 is a liquid's).
constant uint WATER_RAY_BENT = 1;      // the trace goes on from the bent ray
constant uint WATER_RAY_UNDER = 2;     // ...under the water: what it finds is seen through so much of it

// The share a dielectric surface reflects (unpolarized): cosI from the side the ray comes from, eta = n_from / n_to.
inline float waterFresnel(float cosI, float eta) {
    float sinT2 = eta * eta * (1.0f - cosI * cosI);
    if (sinT2 >= 1.0f) return 1.0f;
    float cosT = sqrt(1.0f - sinT2);
    float rs = (eta * cosI - cosT) / (eta * cosI + cosT);
    float rp = (cosI - eta * cosT) / (cosI + eta * cosT);
    return 0.5f * (rs * rs + rp * rp);
}

// The water map at a place (the scene's x, z).
struct WaterPlace {
    bool   wet;          // some of the four texels around it are water
    float  level;        // its surface (the wet texels' mean)
    float  ground;       // the ground under it
    float2 flow;         // m/s
    uint   look;
    float  turbulence;   // white water, 0...1
};

inline WaterPlace waterAt(device const WaterScene* w, float2 xz) {
    WaterPlace r;
    r.wet = false; r.level = WATER_DRY; r.ground = 0.0f; r.flow = float2(0.0f); r.look = 0u; r.turbulence = 0.0f;
    if (w == nullptr || (w->counts.y & WATER_MAPPED) == 0u) return r;
    for (uint k = 0; k < 2u; ++k) {
        float4 m = k == 0u ? w->map0 : w->map1;
        float2 g = (xz - m.xy) / m.z - 0.5f;   // texel centres at whole numbers
        float n = m.w;
        if (any(g < 0.0f) || any(g > n - 2.0f)) continue;
        uint2 c = uint2(g);
        float2 f = g - float2(c);
        float4 wts = float4((1.0f - f.x) * (1.0f - f.y), f.x * (1.0f - f.y), (1.0f - f.x) * f.y, f.x * f.y);
        float2 s0 = w->level.read(c, k).rg, s1 = w->level.read(c + uint2(1, 0), k).rg;
        float2 s2 = w->level.read(c + uint2(0, 1), k).rg, s3 = w->level.read(c + uint2(1, 1), k).rg;
        float4 lv = float4(s0.x, s1.x, s2.x, s3.x);
        float4 wet = float4(lv > WATER_DRY);
        float share = dot(wts, wet);
        r.ground = dot(wts, float4(s0.y, s1.y, s2.y, s3.y));
        if (share <= 0.0f) return r;
        r.wet = true;
        r.level = dot(wts * wet, lv) / share;
        // The wettest texel's flow and look (nearest of the wet ones).
        uint best = 0u;
        float most = -1.0f;
        for (uint q = 0; q < 4u; ++q) if (wet[q] > 0.0f && wts[q] > most) { most = wts[q]; best = q; }
        float4 info = w->info.read(c + uint2(best & 1u, best >> 1), k);
        r.flow = (info.rg - 0.5f) * 8.0f;
        r.look = min(uint(info.b * 255.0f + 0.5f), max(w->counts.x, 1u) - 1u);
        r.turbulence = info.a;
        return r;
    }
    return r;
}

// A ray's meeting with the water's surfaces (their own structures, not the scene's: a ray that only looks for water
// doesn't walk the scene's): how far, the surface's normal (facing up), its look, and where the surface met was at
// rest (x, z: the near patch's waves moved it; the waves' slopes are read there).
struct WaterHit { bool hit; float distance; float3 normal; uint look; float2 rest; bool near; };

inline WaterHit waterIntersect(device const WaterScene* w, float3 o, float3 d, float tmax) {
    WaterHit h;
    h.hit = false; h.distance = tmax; h.normal = float3(0.0f, 1.0f, 0.0f); h.look = 0u; h.rest = float2(0.0f); h.near = false;
    if (w == nullptr) return h;
    intersector<triangle_data> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    isect.accept_any_intersection(false);
    // The near patch first: the camera is in its middle, so whatever it meets of it is nearer than anything outside
    // its square. (Its dry triangles are sunk under the ground: what is in front of the water hides them.)
    if ((w->counts.y & WATER_NEAR) != 0u) {
        auto r = isect.intersect(ray(o, d, 0.0f, tmax), w->nearPatch);
        if (r.type == intersection_type::triangle) {
            uint t = r.primitive_id;
            uint a = w->nearIndices[3u * t], b = w->nearIndices[3u * t + 1u], c = w->nearIndices[3u * t + 2u];
            float2 bc = r.triangle_barycentric_coord;
            float4 va = w->nearVertices[a], vb = w->nearVertices[b], vc = w->nearVertices[c];
            float3 n = normalize(cross(vb.xyz - va.xyz, vc.xyz - va.xyz));
            h.hit = true;
            h.near = true;
            h.distance = r.distance;
            h.normal = n.y < 0.0f ? -n : n;
            float look = va.w < 254.0f ? va.w : vb.w < 254.0f ? vb.w : vc.w;
            h.look = min(uint(look), max(w->counts.x, 1u) - 1u);
            h.rest = w->nearRest[a] * (1.0f - bc.x - bc.y) + w->nearRest[b] * bc.x + w->nearRest[c] * bc.y;
            return h;
        }
    }
    // The still surfaces (inside the near patch's square the patch is the water: what they show there is not).
    auto r = isect.intersect(ray(o, d, 0.0f, tmax), w->surfaces);
    if (r.type != intersection_type::triangle) return h;
    float3 p = o + d * r.distance;
    if ((w->counts.y & WATER_NEAR) != 0u && all(abs(p.xz - w->near.xz) < w->near.w * 0.97f)) return h;
    uint t = r.primitive_id;
    float3 a = w->surfaceVertices[w->surfaceIndices[3u * t]].xyz, b = w->surfaceVertices[w->surfaceIndices[3u * t + 1u]].xyz,
           c = w->surfaceVertices[w->surfaceIndices[3u * t + 2u]].xyz;
    float3 n = normalize(cross(b - a, c - a));
    h.hit = true;
    h.distance = r.distance;
    h.normal = n.y < 0.0f ? -n : n;
    h.look = min(uint(w->surfaceLooks[t]), max(w->counts.x, 1u) - 1u);
    h.rest = p.xz;
    return h;
}

// A small gradient noise and its slope (quintic: smooth slopes), for the ripples and the foam's pattern.
inline float2 waterHash2(int2 c) {
    uint h = pcgHash(uint(c.x) * 1597334677u ^ pcgHash(uint(c.y) + 3812015801u));
    float a = float(h >> 8) * (6.2831853f / 16777216.0f);
    return float2(cos(a), sin(a));
}
inline float3 waterNoise(float2 p) {   // x = value (about -0.7...0.7), yz = its slope
    float2 i = floor(p), f = p - i;
    int2 c = int2(i);
    float2 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float2 du = 30.0f * f * f * (f * (f - 2.0f) + 1.0f);
    float2 ga = waterHash2(c), gb = waterHash2(c + int2(1, 0)), gc = waterHash2(c + int2(0, 1)), gd = waterHash2(c + int2(1, 1));
    float va = dot(ga, f), vb = dot(gb, f - float2(1, 0)), vc = dot(gc, f - float2(0, 1)), vd = dot(gd, f - float2(1, 1));
    float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd);
    float2 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
             + du * (u.yx * (va - vb - vc + vd) + float2(vb, vc) - va);
    return float3(v, d);
}

// The ripples' slope at xz (metres): a few octaves of noise drifting with the wind, smaller ones faded out where a
// pixel covers them (`footprint`, metres).
inline float2 waterRippleSlope(float2 xz, float t, float2 wind, float footprint) {
    float2 slope = float2(0.0f);
    float scale = 0.35f, amp = 0.05f;
    for (uint o = 0; o < 4u; ++o) {
        float fade = saturate(2.0f - footprint * scale * 2.0f);
        if (fade <= 0.0f) break;
        float2 p = xz * scale + wind * t * scale * 0.3f + float2(o * 17.3f, o * 5.1f);
        slope += waterNoise(p).yz * amp * scale * fade;
        scale *= 2.13f; amp *= 0.55f;
    }
    return slope;
}

// The analytic waves (before the FFT's cascades are drawn): eight long-crested waves about the wind, their slope.
inline float2 waterAnalyticSlope(float2 xz, float t, float2 wind, float speed, float footprint) {
    float2 slope = float2(0.0f);
    float peak = max(speed * speed / 9.81f * 2.0f, 2.0f);   // the longest wave about the wind's (m)
    for (uint k = 0; k < 8u; ++k) {
        float L = peak * pow(0.62f, float(k));
        if (L < footprint * 2.0f) break;
        float a = (float(k) * 2.39996f) - 1.2f;   // spread about the wind
        float2 d = float2(wind.x * cos(a * 0.45f) - wind.y * sin(a * 0.45f), wind.x * sin(a * 0.45f) + wind.y * cos(a * 0.45f));
        float kk = 6.2831853f / L, omega = sqrt(9.81f * kk);
        float amp = 0.035f * L / 6.2831853f;   // steepness 0.035
        float phase = kk * dot(d, xz) - omega * t + float(k) * 1.7f;
        slope += d * (amp * kk * cos(phase));
    }
    return slope;
}

// Two drifts of a pattern along a flow, each restarted as the other is at its strongest (Vlachos' flow maps): the
// offsets and weights.
inline float4 waterFlowPhases(float t, float period) {
    float p0 = fract(t / period), p1 = fract(t / period + 0.5f);
    float w0 = 1.0f - abs(2.0f * p0 - 1.0f);
    return float4(p0 * period, p1 * period, w0, 1.0f - w0);
}

// The water's surface at xz: its normal (from the waves of its look's share of the wind's sea, its ripples drifting
// with the wind or along its flow) and how much foam is on it there.
struct WaterSurface { float3 normal; float foam; float roughness; };

inline float waterFFTFoam(device const WaterScene* w, WaterLook look, float2 xz, float footprint);
inline float2 waterFFTSlope(device const WaterScene* w, WaterLook look, float2 xz, float footprint, thread float& lost);

// How much of each FFT cascade a look has: the open sea all of them; a lake (a short fetch) only the shorter waves, and
// less of them; a river or a swamp a little chop.
inline float3 waterCascadeWeights(WaterLook look) {
    float s = look.waves.x;
    return float3(saturate((s - 0.4f) * 1.7f), saturate(s * 4.0f), saturate(s * 8.0f));
}

inline WaterSurface waterSurfaceAt(device const WaterScene* w, WaterLook look, float2 xz, float2 flow, float footprint) {
    WaterSurface r;
    float t = w->time.x;
    float2 wind = length_squared(w->wind.xy) > 0.0f ? normalize(w->wind.xy) : float2(1.0f, 0.0f);
    float2 slope = float2(0.0f);
    float lost = 0.0f;
    r.foam = 0.0f;
    if (look.waves.x > 0.0f) {
        if ((w->counts.y & WATER_FFT) != 0u) {
            slope = waterFFTSlope(w, look, xz, footprint, lost);
            r.foam = waterFFTFoam(w, look, xz, footprint) * look.foam.x;
        } else {
            slope = waterAnalyticSlope(xz, t, wind, w->wind.z, footprint) * look.waves.x;
        }
    }
    float speed = length(flow);
    if (speed > 0.05f) {
        // Ripples carried down the flow (two drifts blended), stronger where it runs fast.
        float4 ph = waterFlowPhases(t, 1.6f);
        float2 a = waterRippleSlope(xz - flow * ph.x, t, wind, footprint), b = waterRippleSlope(xz - flow * ph.y + 3.7f, t, wind, footprint);
        slope += (a * ph.z + b * ph.w) * look.waves.z * (1.0f + speed * 0.6f);
    } else {
        slope += waterRippleSlope(xz, t, wind * max(w->wind.z, 0.5f) * 0.15f, footprint) * look.waves.z;
    }
    r.normal = normalize(float3(-slope.x, 1.0f, -slope.y));
    // What the pixel can't resolve of the waves is roughness.
    r.roughness = sqrt(look.waves.w * look.waves.w + lost * look.waves.x);
    return r;
}

// Foam's look where there is `amount` of it: a broken pattern that drifts with the flow (coverage 0...1).
inline float waterFoamPattern(float2 xz, float t, float2 flow, float amount, float footprint) {
    if (amount <= 0.001f) return 0.0f;
    float4 ph = waterFlowPhases(t, 3.0f);
    float2 p = xz * 2.4f;
    float n0 = waterNoise(p - flow * ph.x * 2.4f).x + 0.6f * waterNoise(p * 2.9f - flow * ph.x * 7.0f).x;
    float n1 = waterNoise(p - flow * ph.y * 2.4f + 9.1f).x + 0.6f * waterNoise(p * 2.9f - flow * ph.y * 7.0f + 4.4f).x;
    float n = (n0 * ph.z + n1 * ph.w) * 0.55f + 0.5f;   // about 0...1
    // Covers more of the water the more there is: a little is a lace of streaks, a lot a white sheet.
    float edge = max(0.12f, footprint * 0.6f);
    float threshold = 1.0f - 0.8f * saturate(amount);
    return smoothstep(threshold - edge, threshold + edge, n) * saturate(amount * 3.0f);
}

// The FFT cascades (Water.metal draws them): the height's slope at xz summed over the cascades a pixel resolves; what
// it can't (the finer ones' share) comes out as `lost` (to roughness).
inline float2 waterFFTSlope(device const WaterScene* w, WaterLook look, float2 xz, float footprint, thread float& lost) {
    constexpr sampler wrap(filter::linear, mip_filter::linear, address::repeat);
    float2 slope = float2(0.0f);
    lost = 0.0f;
    float3 weight = waterCascadeWeights(look);
    float chop = look.waves.y;
    uint n = uint(w->cascades.w);
    for (uint k = 0; k < min(n, 3u); ++k) {
        if (weight[k] <= 0.0f) continue;
        float L = w->cascades[k];
        float2 phase = k == 0u ? w->phase0.xy : k == 1u ? w->phase0.zw : w->phase1.xy;
        float2 uv = (xz + phase) / L;
        float texels = footprint / L * 256.0f;
        float lod = log2(max(texels, 1.0f));
        float4 s = w->slopes.sample(wrap, uv, k, level(lod));
        // (The slope as seen on the surface the sideways push moved: divided by how it stretched there.)
        slope += weight[k] * s.xy / max(float2(1.0f) + chop * s.zw, float2(0.25f));
        // What the pixel's footprint averaged away of this cascade: roughness.
        lost += weight[k] * saturate((texels - 1.0f) * 0.15f) * 0.02f;
    }
    return slope;
}

inline float waterFFTFoam(device const WaterScene* w, WaterLook look, float2 xz, float footprint) {
    constexpr sampler wrap(filter::linear, mip_filter::linear, address::repeat);
    float foam = 0.0f;
    float3 weight = waterCascadeWeights(look);
    uint n = uint(w->cascades.w);
    for (uint k = 0; k < min(n, 2u); ++k) {
        if (weight[k] <= 0.0f) continue;
        float L = w->cascades[k];
        float2 phase = k == 0u ? w->phase0.xy : w->phase0.zw;
        float lod = log2(max(footprint / L * 256.0f, 1.0f));
        foam = max(foam, weight[k] * w->waves.sample(wrap, (xz + phase) / L, k, level(lod)).w);
    }
    return foam;
}

// The FFT waves' displacement at a place at rest (x, z): where the surface there is moved to (sideways by the look's
// chop) and how high, of the cascades the look has.
inline float3 waterDisplacement(device const WaterScene* w, WaterLook look, float2 xz) {
    constexpr sampler wrap(filter::linear, address::repeat);
    float3 d = float3(0.0f);
    float3 weight = waterCascadeWeights(look);
    uint n = uint(w->cascades.w);
    for (uint k = 0; k < min(n, 3u); ++k) {
        if (weight[k] <= 0.0f) continue;
        float L = w->cascades[k];
        float2 phase = k == 0u ? w->phase0.xy : k == 1u ? w->phase0.zw : w->phase1.xy;
        d += weight[k] * w->waves.sample(wrap, (xz + phase) / L, k, level(0.0f)).xyz;
    }
    return float3(d.x * look.waves.y, d.y, d.z * look.waves.y);
}

constant float WATER_CAUSTIC_DEPTH_COMMON = 2.0f;   // = WATER_CAUSTIC_DEPTH (Water.metal)

// The sun's caustics at p under the water (a factor on its light there: 1 above the water, or where the waves are
// too small to make any): from the caustics' tile where the sun's ray to p crossed the surface, blurred the deeper
// p is (the pattern was made for WATER_CAUSTIC_DEPTH), fading in from the surface and out in deep water.
inline float waterCaustic(device const WaterScene* w, float3 p, float3 toSun, float footprint) {
    if (!WATER || w == nullptr || (w->counts.y & WATER_CAUSTICS) == 0u || toSun.y <= 0.05f) return 1.0f;
    WaterPlace place = waterAt(w, p.xz);
    float depth = place.level - p.y;
    if (!place.wet || depth <= 0.02f) return 1.0f;
    WaterLook look = w->looks[place.look];
    float strength = waterCascadeWeights(look).z;
    if (strength <= 0.0f) return 1.0f;
    float ior = look.absorption.w, cosI = toSun.y;
    float cosT = sqrt(saturate(1.0f - (1.0f - cosI * cosI) / (ior * ior)));
    float2 crossed = p.xz + toSun.xz / ior / max(cosT, 0.2f) * depth;
    constexpr sampler wrap(filter::linear, mip_filter::linear, address::repeat);
    // (Blurrier the deeper it is, and the farther: a pixel's footprint over the tile's texels.)
    float lod = clamp(max(log2(max(depth, 0.5f) / WATER_CAUSTIC_DEPTH_COMMON) * 1.5f + 0.5f,
                          log2(max(footprint * 256.0f / w->cascades.z, 1e-3f))), 0.0f, 7.0f);
    float c = w->caustics.sample(wrap, (crossed + w->phase1.xy) / w->cascades.z, level(lod)).r;
    float contrast = strength * smoothstep(0.05f, 1.2f, depth) * exp(-max(depth - 4.0f, 0.0f) / 5.0f);
    return max(1.0f + (c - 1.0f) * contrast, 0.0f);
}
