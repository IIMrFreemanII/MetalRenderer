// ---------------------------------------------------------------------------------------------
// Sky and clouds. With FLAG_SKY_MAP every sky lookup (camera, GI and reflection misses, the fog's ambient light)
// reads the sky texture (see "Sky lookups"), which skyKernel keeps up to date, a sixteenth of its texels a frame:
//   * the atmosphere: single scattering of the sun's light (Rayleigh, Mie, ozone; Hillaire 2020's constants), or
//   * an HDR image (equirectangular), its sun cut out on the CPU (the sun light carries it);
//   * in front of either, a volumetric cloud layer: a spherical shell of Perlin-Worley noise shaped by a coverage
//     field and a height profile, eroded by Worley detail (Schneider 2015), lit by the sun through a short march
//     toward it with a multiple-scattering approximation (Wrenninge's octaves) and by the sky around.
// cloudShadowKernel traces the clouds' transmittance toward the sun over a square of ground around the scene; every
// sun visibility test multiplies by it (sunVisibilityScale), so the clouds' shadows drift over the scene.
// Atmosphere.swift computes the same atmosphere on the CPU for the sun light's colour and the sky's mean radiance.
// ---------------------------------------------------------------------------------------------

constant float ATMO_GROUND = 6360e3f;   // planet radius (m)
constant float ATMO_TOP    = 6460e3f;   // top of the atmosphere
constant float3 RAYLEIGH_SCATTER = float3(5.802e-6f, 13.558e-6f, 33.1e-6f);
constant float  RAYLEIGH_HEIGHT  = 8000.0f;
constant float  MIE_SCATTER = 3.996e-6f, MIE_EXTINCTION = 4.440e-6f, MIE_HEIGHT = 1200.0f, MIE_G = 0.8f;
constant float3 OZONE_ABSORPTION = float3(0.650e-6f, 1.881e-6f, 0.085e-6f);   // tent around 25 km, 30 km wide

constexpr sampler cloudSampler(filter::linear, address::repeat);

// Extinction at altitude h, with Rayleigh and Mie scattering.
inline float3 atmosphereExtinction(float h, thread float3& rayleigh, thread float& mie) {
    float dR = exp(-h / RAYLEIGH_HEIGHT), dM = exp(-h / MIE_HEIGHT), dO = max(0.0f, 1.0f - abs(h - 25000.0f) / 15000.0f);
    rayleigh = RAYLEIGH_SCATTER * dR;
    mie = MIE_SCATTER * dM;
    return RAYLEIGH_SCATTER * dR + MIE_EXTINCTION * dM + OZONE_ABSORPTION * dO;
}

// Distances along unit d from o (both relative to the planet's centre) to a sphere of radius R: x = near, y = far
// (x < 0 from inside); y < x when it misses.
inline float2 raySphere(float3 o, float3 d, float R) {
    float b = dot(o, d), c = dot(o, o) - R * R, disc = b * b - c;
    if (disc < 0.0f) return float2(1.0f, -1.0f);
    float q = sqrt(disc);
    return float2(-b - q, -b + q);
}

// Transmittance along unit d from p (relative to the planet's centre) to the top of the atmosphere, integrated in
// `steps` steps (the ground ignored). For the lookup table and the CPU check; shading reads the table.
float3 atmosphereTransmittanceMarch(float3 p, float3 d, uint steps) {
    float t = raySphere(p, d, ATMO_TOP).y;
    if (t <= 0.0f) return float3(1.0f);
    float dt = t / float(steps);
    float3 tau = float3(0.0f);
    for (uint i = 0; i < steps; ++i) {
        float3 r; float m;
        tau += atmosphereExtinction(length(p + d * ((float(i) + 0.5f) * dt)) - ATMO_GROUND, r, m) * dt;
    }
    return exp(-tau);
}

// The transmittance table's coordinates for a point at radius r looking at cos zenith mu (Bruneton 2017: the
// distance to the top between its extremes, and the height as the distance to the horizon, so the horizon gets
// the resolution).
constant float ATMO_HORIZON = 1132255.0f;   // sqrt(ATMO_TOP^2 - ATMO_GROUND^2)
inline float2 transmittanceUV(float r, float mu) {
    float rho = sqrt(max(r * r - ATMO_GROUND * ATMO_GROUND, 0.0f));
    float d = max(-r * mu + sqrt(max(r * r * (mu * mu - 1.0f) + ATMO_TOP * ATMO_TOP, 0.0f)), 0.0f);
    float dMin = ATMO_TOP - r, dMax = rho + ATMO_HORIZON;
    return float2((d - dMin) / max(dMax - dMin, 1.0f), rho / ATMO_HORIZON);
}

constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);

// Transmittance from p toward unit d to the top of the atmosphere, from the table; 0 if the planet is in the way.
inline float3 atmosphereTransmittance(texture2d<float> lut, float3 p, float3 d) {
    float r = length(p), mu = dot(p, d) / r;
    if (mu < -sqrt(max(1.0f - (ATMO_GROUND / r) * (ATMO_GROUND / r), 0.0f))) return float3(0.0f);
    return lut.sample(lutSampler, transmittanceUV(r, mu), level(0)).rgb;
}

kernel void transmittanceLUTKernel(texture2d<float, access::write> outLUT [[texture(0)]],
                                   uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= outLUT.get_width() || tid.y >= outLUT.get_height()) return;
    float2 x = (float2(tid) + 0.5f) / float2(outLUT.get_width(), outLUT.get_height());
    float rho = ATMO_HORIZON * x.y, r = sqrt(rho * rho + ATMO_GROUND * ATMO_GROUND);
    float dMin = ATMO_TOP - r, dMax = rho + ATMO_HORIZON, d = dMin + x.x * (dMax - dMin);
    float mu = d <= 0.0f ? 1.0f : clamp((ATMO_HORIZON * ATMO_HORIZON - rho * rho - d * d) / (2.0f * r * d), -1.0f, 1.0f);
    outLUT.write(float4(atmosphereTransmittanceMarch(float3(0.0f, r, 0.0f), float3(sqrt(1.0f - mu * mu), mu, 0.0f), 40), 1.0f), tid);
}

// Multiple scattering (Hillaire 2020): for altitude and the sun's cos zenith, the isotropic light of all higher
// scattering orders per unit of sun irradiance, from the second order over 64 directions and the fraction f the
// medium passes on (a geometric series: L2 / (1 - f)). x = sun cos zenith (-1 ... 1), y = altitude.
kernel void multiScatterLUTKernel(texture2d<float>                transmittance [[texture(0)]],
                                  texture2d<float, access::write> outLUT        [[texture(1)]],
                                  uint2 tid [[thread_position_in_grid]])
{
    uint2 size = uint2(outLUT.get_width(), outLUT.get_height());
    if (any(tid >= size)) return;
    float2 x = (float2(tid) + 0.5f) / float2(size);
    float muS = x.x * 2.0f - 1.0f;
    float3 p = float3(0.0f, ATMO_GROUND + 50.0f + x.y * (ATMO_TOP - ATMO_GROUND - 100.0f), 0.0f);
    float3 sun = float3(sqrt(max(1.0f - muS * muS, 0.0f)), muS, 0.0f);
    constexpr uint dirs = 64, steps = 20;
    constexpr float albedo = 0.3f;
    float3 L2 = float3(0.0f), f = float3(0.0f);
    for (uint k = 0; k < dirs; ++k) {   // Fibonacci sphere
        float z = 1.0f - 2.0f * (float(k) + 0.5f) / float(dirs), phi = float(k) * 2.39996323f, rr = sqrt(max(1.0f - z * z, 0.0f));
        float3 w = float3(rr * cos(phi), z, rr * sin(phi));
        float2 g = raySphere(p, w, ATMO_GROUND);
        bool ground = g.x > 0.0f && g.y > g.x;
        float tMax = ground ? g.x : raySphere(p, w, ATMO_TOP).y, dt = tMax / float(steps);
        float3 L = float3(0.0f), fl = float3(0.0f), T = float3(1.0f);
        for (uint i = 0; i < steps; ++i) {
            float3 q = p + w * ((float(i) + 0.5f) * dt);
            float3 sR; float sM;
            float3 ext = atmosphereExtinction(length(q) - ATMO_GROUND, sR, sM);
            float3 scatter = sR + sM, tr = exp(-ext * dt), integral = (1.0f - tr) / max(ext, float3(1e-12f));
            L += T * scatter * atmosphereTransmittance(transmittance, q, sun) * (integral / (4.0f * M_PI_F));
            fl += T * scatter * integral;
            T *= tr;
        }
        if (ground) {
            float3 q = p + w * tMax, n = normalize(q);
            L += T * atmosphereTransmittance(transmittance, q + n, sun) * (albedo / M_PI_F * max(dot(n, sun), 0.0f));
        }
        L2 += L / float(dirs);
        f += fl / float(dirs);
    }
    outLUT.write(float4(L2 / max(1.0f - f, float3(1e-3f)), 1.0f), tid);
}

inline float3 multipleScattering(texture2d<float> lut, float h, float muS) {
    return lut.sample(lutSampler, float2(muS * 0.5f + 0.5f, saturate((h - 50.0f) / (ATMO_TOP - ATMO_GROUND - 100.0f))), level(0)).rgb;
}

inline float rayleighPhase(float c) { return 3.0f / (16.0f * M_PI_F) * (1.0f + c * c); }
inline float miePhase(float c, float g) {   // Cornette-Shanks
    float g2 = g * g;
    return 3.0f / (8.0f * M_PI_F) * (1.0f - g2) * (1.0f + c * c) / ((2.0f + g2) * pow(max(1.0f + g2 - 2.0f * g * c, 1e-4f), 1.5f));
}

// Sky radiance toward unit v for an observer near the ground: single scattering marched in 20 steps (denser near
// the observer), lit through the transmittance table, plus the multiple-scattering table; below the horizon, the
// lit ground at the end. `skyMean` = the sky's mean radiance (lights the ground from around).
float3 atmosphereRadiance(float3 v, constant SkyParams& sp, texture2d<float> transmittance, texture2d<float> multiScatter,
                          float3 skyMean) {
    float3 o = float3(0.0f, ATMO_GROUND + sp.ground.w, 0.0f), l = sp.sun.xyz;
    float2 g = raySphere(o, v, ATMO_GROUND);
    bool ground = g.x > 0.0f && g.y > g.x;
    float tMax = ground ? g.x : raySphere(o, v, ATMO_TOP).y;
    float c = dot(v, l), pR = rayleighPhase(c), pM = miePhase(c, MIE_G);
    float3 L = float3(0.0f), T = float3(1.0f), E = sp.sunTop.rgb;
    constexpr uint steps = 20;
    float t0 = 0.0f;
    for (uint i = 0; i < steps; ++i) {
        float x = float(i + 1) / float(steps), t1 = tMax * x * x;
        float dt = t1 - t0;
        float3 p = o + v * (0.5f * (t0 + t1));
        float r = length(p);
        float3 sR; float sM;
        float3 ext = atmosphereExtinction(r - ATMO_GROUND, sR, sM);
        float3 S = ((sR * pR + sM * pM) * atmosphereTransmittance(transmittance, p, l)
                    + (sR + sM) * multipleScattering(multiScatter, r - ATMO_GROUND, dot(p, l) / r)) * E;
        float3 tr = exp(-ext * dt);
        L += T * S * (1.0f - tr) / max(ext, float3(1e-12f));
        T *= tr;
        t0 = t1;
    }
    if (ground) {
        float3 pg = o + v * tMax, n = normalize(pg);
        float3 sunAtGround = atmosphereTransmittance(transmittance, pg + n, l) * E * max(dot(n, l), 0.0f);
        L += T * sp.ground.rgb / M_PI_F * (sunAtGround + M_PI_F * skyMean);
    }
    return L;
}

inline float remap(float x, float a, float b, float c, float d) { return c + (x - a) * (d - c) / (b - a); }

// Cloud density (extinction, 1/m) at world point p (metres, y up), h01 = height within the layer. fine = false
// skips the erosion (light and shadow marches). step = the march's step length: the noise is read at the mip level
// whose texels match it, so long steps (toward the horizon) don't alias into streaks.
float cloudDensity(float3 p, float h01, constant SkyParams& sp, texture3d<float> shape, texture3d<float> detail, bool fine,
                   float step) {
    if (h01 <= 0.0f || h01 >= 1.0f) return 0.0f;
    // Rounded bases, tops thinning toward an anvil.
    float profile = saturate(remap(h01, 0.0f, 0.1f, 0.0f, 1.0f)) * saturate(remap(h01, 0.3f, 1.0f, 1.0f, 0.0f));
    float3 q = (p + sp.wind.xyz * sp.cloudShape.z) / sp.cloudShape.x;
    // Coverage: the global amount (scaled so 1 is overcast, ~0.3 scattered cumulus), varied by a slow field (the
    // noise's lowest octave over 6 tiles).
    float field = shape.sample(cloudSampler, float3(q.x / 6.0f, 0.37f, q.z / 6.0f), level(0)).g;
    float coverage = saturate(0.55f * sp.cloudLayer.z + (field - 0.5f) * 0.3f);
    if (profile <= 1.0f - coverage) return 0.0f;   // base x profile can't reach the coverage threshold
    float lod = max(log2(step * 128.0f / sp.cloudShape.x), 0.0f);   // shape texel = tile / 128
    float4 n = shape.sample(cloudSampler, q, level(lod));
    float fbm = n.g * 0.625f + n.b * 0.25f + n.a * 0.125f;
    float base = saturate(remap(n.r, fbm - 1.0f, 1.0f, 0.0f, 1.0f)) * profile;
    float cloud = saturate(remap(base, 1.0f - coverage, 1.0f, 0.0f, 1.0f)) * coverage;
    // Erosion by the detail noise (its tile = half the shape's, texel = tile / 64), faded out where the steps are too
    // long to resolve it: a coarse tiled texture read far apart turns into a lattice of streaks.
    float detailLod = max(log2(step * 64.0f / sp.cloudShape.x), 0.0f), resolve = saturate(2.5f - detailLod);
    if (fine && cloud > 0.0f && resolve > 0.0f) {
        float3 dn = detail.sample(cloudSampler, q * 2.0f, level(detailLod)).rgb;
        float hf = dn.r * 0.625f + dn.g * 0.25f + dn.b * 0.125f;
        float erode = mix(hf, 1.0f - hf, saturate(h01 * 5.0f)) * sp.cloudShape.y * resolve;
        cloud = saturate(remap(cloud, erode, 1.0f, 0.0f, 1.0f));
    }
    return cloud * sp.cloudLayer.w;
}

// Height within the cloud layer of a point given relative to the planet's centre.
inline float cloudHeight(float3 pc, constant SkyParams& sp) {
    return (length(pc) - ATMO_GROUND - sp.cloudLayer.x) / (sp.cloudLayer.y - sp.cloudLayer.x);
}

// Cloud phase: a forward lobe (silver linings) and a back lobe; g scaled down for the higher scattering orders.
inline float cloudPhase(float c, float k) { return mix(phaseHG(c, 0.8f * k), phaseHG(c, -0.3f * k), 0.3f); }

// The clouds along unit v from the sky's observer: rgb = in-scattered light, a = transmittance. 40 jittered steps
// through the layer (up to 30 km of it), each lit by the sun through a 5-step march toward it (three scattering
// orders) and by the sky around; far clouds fade into the sky.
float4 cloudMarch(float3 v, float jitter, constant SkyParams& sp, texture3d<float> shape, texture3d<float> detail,
                  float3 skyMean) {
    float3 o = float3(0.0f, ATMO_GROUND + sp.ground.w, 0.0f);
    float2 ground = raySphere(o, v, ATMO_GROUND);
    if (ground.x > 0.0f && ground.y > ground.x) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    float t0 = raySphere(o, v, ATMO_GROUND + sp.cloudLayer.x).y, t1 = raySphere(o, v, ATMO_GROUND + sp.cloudLayer.y).y;
    t1 = min(t1, t0 + 30000.0f);
    if (!(t1 > t0)) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    float3 l = sp.sun.xyz, sun = sp.sunGround.rgb;
    float c = dot(v, l);
    constexpr uint steps = 40;
    float dt = (t1 - t0) / float(steps);
    float2 observer = sp.place.xy + sp.place.zw;   // where the march's origin is in the world (x, z)
    float3 L = float3(0.0f);
    float T = 1.0f;
    for (uint i = 0; i < steps && T > 0.01f; ++i) {
        float t = t0 + (float(i) + jitter) * dt;
        float3 pc = o + v * t;
        float h01 = cloudHeight(pc, sp);
        float3 pw = float3(pc.x + observer.x, pc.y - ATMO_GROUND, pc.z + observer.y);
        float sigma = cloudDensity(pw, h01, sp, shape, detail, true, dt);
        if (sigma <= 0.0f) continue;
        // Optical depth toward the sun: 5 steps, each twice as long (40 m ... 1.2 km).
        float tauSun = 0.0f, step = 40.0f, along = 0.0f;
        for (uint k = 0; k < 5; ++k) {
            float3 q = pc + l * (along + 0.5f * step);
            tauSun += cloudDensity(float3(q.x + observer.x, q.y - ATMO_GROUND, q.z + observer.y), cloudHeight(q, sp), sp, shape, detail, false, step) * step;
            along += step;
            step *= 2.0f;
        }
        float3 S = float3(0.0f);
        float a = 1.0f, b = 1.0f, k = 1.0f;
        for (uint order = 0; order < 3; ++order) {
            S += a * sun * cloudPhase(c, k) * exp(-b * tauSun);
            a *= 0.5f; b *= 0.5f; k *= 0.5f;
        }
        float powder = 1.0f - exp(-2.0f * sigma * 60.0f);
        S = S * mix(1.0f, powder, 0.5f) + skyMean * mix(0.5f, 1.0f, h01);   // + the sky around, brighter on top
        float tr = exp(-sigma * dt);
        L += T * S * (1.0f - tr);   // scattering albedo 1: in-scatter per unit extinction
        T *= tr;
    }
    float fade = exp(-max(t0 - 4000.0f, 0.0f) / 25000.0f);   // far clouds sink into the haze
    return float4(L * fade, mix(1.0f, T, fade));
}

// Equirectangular image lookup: u = 0.5 faces -z, v = 0 is straight up.
inline float3 equirectSample(texture2d<float> image, float3 d) {
    float2 uv = float2(0.5f + atan2(d.x, -d.z) / (2.0f * M_PI_F), acos(clamp(d.y, -1.0f, 1.0f)) / M_PI_F);
    return image.sample(cloudSampler, uv, level(0)).rgb;
}

// Updates the sky texture, slice z (0 = upper, 1 = lower hemisphere): the texels with (x & 3) + 4 (y & 3) = this
// frame's phase, one per thread (a sixteenth of the grid is dispatched, so no SIMD lanes idle), or every texel with
// SKY_UPDATE_ALL. Clouds blend into the texel's last value (wind.w) to smooth their march's noise; a full update
// replaces it.
kernel void skyKernel(constant SkyParams&                       sp        [[buffer(0)]],
                      device const float4*                      skyMean   [[buffer(1)]],   // skyMeanKernel, last frame
                      texture3d<float>                          shape     [[texture(0)]],
                      texture3d<float>                          detail    [[texture(1)]],
                      texture2d<float, access::read>            blueNoise [[texture(2)]],
                      texture2d<float>                          image     [[texture(3)]],   // SKY_IMAGE: equirectangular
                      texture2d_array<float, access::read_write> sky      [[texture(4)]],
                      texture2d<float>                          transmittance [[texture(5)]],
                      texture2d<float>                          multiScatter  [[texture(6)]],
                      uint3 tid [[thread_position_in_grid]])
{
    uint size = sky.get_width();
    bool full = (sp.flags.y & SKY_UPDATE_ALL) != 0;
    uint2 texel = full ? tid.xy : tid.xy * 4u + uint2(sp.flags.z & 3u, sp.flags.z >> 2);
    if (texel.x >= size || texel.y >= size || tid.z > 1) return;
    float3 dir = hemiDecode((float2(texel) + 0.5f) / float(size));
    if (tid.z == 1) dir.y = -dir.y;
    float3 mean = skyMean[0].rgb;
    float3 background = sp.flags.x == SKY_IMAGE ? equirectSample(image, dir)
                                                : atmosphereRadiance(dir, sp, transmittance, multiScatter, mean);
    float4 result = float4(background, 1.0f);
    bool clouds = (sp.flags.y & SKY_CLOUDS) != 0 && (sp.flags.x == SKY_ATMOSPHERE || (sp.flags.y & SKY_CLOUDS_OVER_IMAGE) != 0);
    if (tid.z == 0 && clouds) {
        float jitter = blueNoise.read(texel % BLUE_NOISE_SIZE).r;
        jitter = fract(jitter + float(sp.flags.w) * 0.618034f);
        float4 c = cloudMarch(dir, jitter, sp, shape, detail, mean);
        result = float4(background * c.a + c.rgb, c.a);
        if (!full) result = mix(sky.read(texel, 0), result, sp.wind.w);
    }
    sky.write(result, texel, tid.z);
}

// The clear sky's cosine-weighted mean radiance over the upper hemisphere (the atmosphere, or the image), from 64
// directions: lights the clouds and the ground from around, before this frame's skyKernel. (Not the clouded sky:
// clouds lit by their own darkness would darken each other frame after frame.)
[[max_total_threads_per_threadgroup(64)]]
kernel void skyMeanKernel(constant SkyParams&    sp            [[buffer(0)]],
                          device float4*         skyMean       [[buffer(1)]],
                          texture2d<float>       image         [[texture(0)]],
                          texture2d<float>       transmittance [[texture(1)]],
                          texture2d<float>       multiScatter  [[texture(2)]],
                          uint k [[thread_position_in_threadgroup]])
{
    threadgroup float3 sums[64];
    float r = sqrt((float(k) + 0.5f) / 64.0f), phi = float(k) * 2.39996323f;   // cosine-weighted (Malley)
    float3 dir = float3(r * cos(phi), sqrt(max(1.0f - r * r, 0.0f)), r * sin(phi));
    sums[k] = sp.flags.x == SKY_IMAGE ? equirectSample(image, dir)
                                      : atmosphereRadiance(dir, sp, transmittance, multiScatter, skyMean[0].rgb);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (k != 0) return;
    float3 sum = float3(0.0f);
    for (uint i = 0; i < 64; ++i) sum += sums[i];
    skyMean[0] = float4(sum / 64.0f, 1.0f);
}

// The clouds' transmittance toward the sun from each point of a square of ground around the scene (24 steps
// through the layer, no erosion detail).
kernel void cloudShadowKernel(constant SkyParams&             sp      [[buffer(0)]],
                              texture3d<float>                shape   [[texture(0)]],
                              texture3d<float>                detail  [[texture(1)]],
                              texture2d<float, access::write> outShadow [[texture(2)]],
                              uint2 tid [[thread_position_in_grid]])
{
    uint size = outShadow.get_width();
    if (tid.x >= size || tid.y >= size) return;
    float3 l = sp.sun.xyz;
    if (l.y <= 0.01f) { outShadow.write(float4(1.0f), tid); return; }
    float2 xz = sp.shadowMap.xy + ((float2(tid) + 0.5f) / float(size) * 2.0f - 1.0f) * sp.shadowMap.z;
    float3 o = float3(xz.x, ATMO_GROUND + sp.shadowMap.w, xz.y);
    float t0 = raySphere(o, l, ATMO_GROUND + sp.cloudLayer.x).y, t1 = raySphere(o, l, ATMO_GROUND + sp.cloudLayer.y).y;
    constexpr uint steps = 24;
    float dt = (t1 - t0) / float(steps), tau = 0.0f;
    for (uint i = 0; i < steps; ++i) {
        float3 pc = o + l * (t0 + (float(i) + 0.5f) * dt);
        tau += cloudDensity(float3(pc.x + sp.place.x, pc.y - ATMO_GROUND, pc.z + sp.place.y), cloudHeight(pc, sp), sp, shape, detail, false, dt) * dt;
    }
    outShadow.write(float4(exp(-tau * sp.cloudShape.w)), tid);
}

// Tiling noise for the clouds, generated once. Worley: 1 at the cell's feature point, falling to 0 a cell away.
inline float3 hash3(uint3 c) {
    uint h = pcgHash(c.x + pcgHash(c.y + pcgHash(c.z)));
    uint h2 = pcgHash(h), h3 = pcgHash(h2);
    return float3(h, h2, h3) * (1.0f / 4294967296.0f);
}
inline float worleyTile(float3 p, float period) {
    float3 c = floor(p), f = p - c;
    float d2 = 1e9f;
    for (int z = -1; z <= 1; ++z)
        for (int y = -1; y <= 1; ++y)
            for (int x = -1; x <= 1; ++x) {
                float3 o = float3(x, y, z), cell = fmod(c + o + period, period);
                float3 r = o + hash3(uint3(cell)) - f;
                d2 = min(d2, dot(r, r));
            }
    return 1.0f - saturate(sqrt(d2));
}
inline float perlinTile(float3 p, float period) {   // about -1 ... 1
    float3 c = floor(p), f = p - c, u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float v[8];
    for (uint k = 0; k < 8; ++k) {
        float3 o = float3(k & 1, (k >> 1) & 1, k >> 2);
        float3 g = hash3(uint3(fmod(c + o, period)) + 977u) * 2.0f - 1.0f;
        v[k] = dot(normalize(g + 1e-6f), f - o);
    }
    float x00 = mix(v[0], v[1], u.x), x10 = mix(v[2], v[3], u.x), x01 = mix(v[4], v[5], u.x), x11 = mix(v[6], v[7], u.x);
    return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z) * 1.6f;
}

kernel void cloudNoiseKernel(texture3d<float, access::write> outShape  [[texture(0)]],   // 128^3
                             texture3d<float, access::write> outDetail [[texture(1)]],   // 32^3
                             uint3 tid [[thread_position_in_grid]])
{
    uint n = outShape.get_width();
    if (any(tid >= n)) return;
    float3 q = (float3(tid) + 0.5f) / float(n);
    float perlin = saturate(0.5f + 0.5f * (perlinTile(q * 4.0f, 4.0f) * 0.5f + perlinTile(q * 8.0f, 8.0f) * 0.3f
                                         + perlinTile(q * 16.0f, 16.0f) * 0.2f));
    float w4 = worleyTile(q * 4.0f, 4.0f), w8 = worleyTile(q * 8.0f, 8.0f), w16 = worleyTile(q * 16.0f, 16.0f);
    float w32 = worleyTile(q * 32.0f, 32.0f);
    float worley = w4 * 0.625f + w8 * 0.25f + w16 * 0.125f;
    float perlinWorley = remap(perlin, 0.0f, 1.0f, worley, 1.0f);
    outShape.write(float4(perlinWorley, worley, w8 * 0.625f + w16 * 0.25f + w32 * 0.125f, w16 * 0.75f + w32 * 0.25f), tid);
    uint m = outDetail.get_width();
    if (all(tid < m)) {
        float3 d = (float3(tid) + 0.5f) / float(m);
        outDetail.write(float4(worleyTile(d * 2.0f, 2.0f), worleyTile(d * 4.0f, 4.0f), worleyTile(d * 8.0f, 8.0f), 1.0f), tid);
    }
}
