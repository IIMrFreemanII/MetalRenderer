// ---------------------------------------------------------------------------------------------
// Volumetric fog: single scattering in a participating medium, exponential height fog plus local fog volumes
// (soft-edged boxes and spheres), both modulated by a drifting 3D noise, lit by every light type with ray-traced
// shadows and an ambient sky term.
//   Camera view: a froxel grid (camera-frustum voxels: 8x8 traced pixels x 64 slices, exponential in view depth).
//   fogInjectKernel lights one jittered point per froxel per frame (one light picked by importance, one shadow ray)
//   and blends it into last frame's grid, reprojected; fogIntegrateKernel accumulates in-scatter and transmittance
//   front to back; the composite applies them at each pixel's depth, before tonemapping.
//   Reflection rays: a one-sample estimate along the ray (fogAlongRay). References march each camera ray instead of
//   using the grid (fogReferenceKernel), so the grid's approximation can be measured against them.
// Light reaching the fog is dimmed by the fog in between (analytic optical depth, without the noise).
// ---------------------------------------------------------------------------------------------

constexpr sampler fogNoiseSampler(filter::linear, address::repeat);
constexpr sampler fogGridSampler(filter::linear, address::clamp_to_edge);

// Drifting noise, ~0.5 on average: two octaves of the tiling 64^3 texture (FogNoise.swift).
inline float fogNoise(texture3d<float> noise, float3 p, constant FogParams& f) {
    float3 q = (p - f.wind.xyz * f.noise.z) / f.noise.y;
    return 0.7f * noise.sample(fogNoiseSampler, q).r + 0.3f * noise.sample(fogNoiseSampler, q * 2.71f + 0.37f).r;
}

// Density multiplier for noise value n: 1 on average, from ~0 to ~2 at amount 1.
inline float fogNoiseFactor(float n, float amount) { return max(0.0f, 1.0f + amount * 3.0f * (n - 0.5f)); }

// Bottom of a fog volume, where its height falloff starts.
inline float fogVolumeBottom(FogVolume v) {
    return v.centerShape.y - (v.centerShape.w < 0.5f ? v.extentDensity.y : v.extentDensity.x);
}

// Volume v's density at p relative to its bottom extinction: 0 outside, ramping to 1 over the edge width inside.
inline float fogVolumeWeight(FogVolume v, float3 p) {
    float3 q = p - v.centerShape.xyz;
    float3 e = v.extentDensity.xyz;
    float depth = v.centerShape.w < 0.5f ? min(min(e.x - abs(q.x), e.y - abs(q.y)), e.z - abs(q.z)) : e.x - length(q);
    if (depth <= 0.0f) return 0.0f;
    return smoothstep(0.0f, max(v.albedoEdge.w, 1e-3f), depth) * exp(-v.params.y * max(p.y - fogVolumeBottom(v), 0.0f));
}

// The medium at p: rgb = scattering coefficient, a = extinction (1/m). n = noise value (0.5 = none).
float4 fogMedium(float3 p, constant FogParams& f, float n) {
    float4 m = float4(0.0f);
    if (f.medium.x > 0.0f) {
        float rho = f.medium.x * exp(-f.medium.y * max(p.y - f.medium.z, 0.0f)) * fogNoiseFactor(n, f.noise.x);
        m += float4(f.albedo.rgb * rho, rho);
    }
    for (uint i = 0; i < f.counts.z; ++i) {
        FogVolume v = f.volumes[i];
        float w = fogVolumeWeight(v, p);
        if (w <= 0.0f) continue;
        float rho = v.extentDensity.w * w * fogNoiseFactor(n, v.params.x);
        m += float4(v.albedoEdge.rgb * rho, rho);
    }
    return m;
}

// Optical depth of the height fog along o + d s, s in [0, t] (d unit, t may be INFINITY), in closed form:
// constant density below the base height, exponential above.
float heightFogDepth(float3 o, float3 d, float t, constant FogParams& f) {
    float rho = f.medium.x, b = f.medium.y, h = o.y - f.medium.z;
    if (rho <= 0.0f || t <= 0.0f) return 0.0f;
    if (abs(d.y) < 1e-4f) return isFar(t) ? INFINITY : rho * exp(-b * max(h, 0.0f)) * t;
    float base = clamp(-h / d.y, 0.0f, t);   // where the ray crosses the base height, within [0, t]
    // Below the base: [0, base] going up, [base, t] going down. Above: the rest.
    float below = d.y > 0.0f ? base : t - base;
    float a0 = d.y > 0.0f ? base : 0.0f, a1 = d.y > 0.0f ? t : base;
    float tau = rho * below;
    if (a1 > a0) {
        if (b < 1e-5f) return tau + rho * (a1 - a0);
        float e0 = exp(-b * max(h + d.y * a0, 0.0f));
        float e1 = isFar(a1) ? 0.0f : exp(-b * max(h + d.y * a1, 0.0f));
        tau += rho * (e0 - e1) / (b * d.y);
    }
    return tau;
}

// Optical depth of the fog volumes along the same segment: each one's overlap with the ray (its shape shrunk by
// half the edge width) times its density at the overlap's middle height.
float volumeFogDepth(float3 o, float3 d, float t, constant FogParams& f) {
    float tau = 0.0f;
    for (uint i = 0; i < f.counts.z; ++i) {
        FogVolume v = f.volumes[i];
        float3 q = o - v.centerShape.xyz;
        float shrink = 0.5f * v.albedoEdge.w, t0, t1;
        if (v.centerShape.w < 0.5f) {
            float3 e = max(v.extentDensity.xyz - shrink, 0.0f);
            float3 inv = 1.0f / d;
            float3 ta = (-e - q) * inv, tb = (e - q) * inv;
            float3 lo = min(ta, tb), hi = max(ta, tb);
            t0 = max(max(lo.x, lo.y), lo.z);
            t1 = min(min(hi.x, hi.y), hi.z);
        } else {
            float r = max(v.extentDensity.x - shrink, 0.0f);
            float bq = dot(q, d), c = dot(q, q) - r * r, disc = bq * bq - c;
            if (disc <= 0.0f) continue;
            float sq = sqrt(disc);
            t0 = -bq - sq;
            t1 = -bq + sq;
        }
        t0 = max(t0, 0.0f);
        t1 = min(t1, t);
        if (!(t1 > t0)) continue;
        float y = o.y + d.y * 0.5f * (t0 + t1);
        tau += v.extentDensity.w * (t1 - t0) * exp(-v.params.y * max(y - fogVolumeBottom(v), 0.0f));
    }
    return tau;
}

inline float fogOpticalDepth(float3 o, float3 d, float t, constant FogParams& f) {
    return heightFogDepth(o, d, t, f) + volumeFogDepth(o, d, t, f);
}

// Henyey-Greenstein phase function; cosTheta between the light's travel direction and the scattered one.
inline float phaseHG(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0f - g2) / (4.0f * M_PI_F * pow(max(1.0f + g2 - 2.0f * g * cosTheta, 1e-4f), 1.5f));
}

// Light reaching a point in the fog from one light, unshadowed, as irradiance from one direction (no receiver
// cosine), with `l` toward the light's centre: the light-picking weight. Exact for spheres, spots and the sun;
// rects, tubes and mesh lights as points (with the distance clamped to their size).
float3 lightVolumeWeight(Light light, float3 p, thread float3& l) {
    uint type = lightType(light);
    if (type == LIGHT_SUN) { l = light.axis.xyz; return light.color.rgb; }
    float3 toLight = light.positionRadius.xyz - p;
    float d2 = dot(toLight, toLight);
    l = toLight * rsqrt(max(d2, 1e-12f));
    float r = light.positionRadius.w;
    if (type == LIGHT_RECT) {
        float cosL = -dot(light.axis.xyz, l);
        if (cosL <= 0.0f) return float3(0.0f);
        float area = 4.0f * length(light.params.xyz) * light.params.w;
        return light.color.rgb * (area * cosL / max(d2, area / M_PI_F));
    }
    if (type == LIGHT_TUBE) return light.color.rgb / max(d2, max(dot(light.axis.xyz, light.axis.xyz), r * r));
    if (type == LIGHT_MESH) {
        float flat = light.params.z;
        return light.color.rgb * (((1.0f - flat) * 0.25f + flat * abs(dot(light.axis.xyz, l))) / max(d2, r * r));
    }
    float3 e = light.color.rgb / max(d2, r * r);
    if (type == LIGHT_SPOT) e *= spotFactor(light, -l);
    return e;
}

// One-sample estimate of the same, with a shadow-ray end `target` and the direction `l` the light arrives from:
// spheres, spots and the sun as above; a uniform point of the emitter for rects, tubes (along the axis, intensity
// per unit length 4 I / (pi length) broadside) and mesh lights (one triangle point).
float3 lightVolumeSample(Light light, float3 p, float2 u, thread const SceneData& s, thread float3& target, thread float3& l) {
    uint type = lightType(light);
    if (type == LIGHT_MESH) {
        MeshLightPoint mp = sampleMeshLightPoint(light, u, s);
        if (!mp.valid) return float3(0.0f);
        float3 w = mp.x - p;
        float d2 = dot(w, w);
        l = w * rsqrt(max(d2, 1e-12f));
        target = p + w * 0.99f;
        float cosL = abs(dot(mp.cr, l)) / mp.area2;
        return meshLightPointEmission(mp, s) * (cosL / max(d2, 1e-4f) * (0.5f * mp.area2 / mp.prob));
    }
    target = lightShadowTarget(light, p, u);
    if (type == LIGHT_RECT) {
        float3 w = target - p;
        float d2 = dot(w, w);
        l = w * rsqrt(max(d2, 1e-12f));
        float cosL = -dot(light.axis.xyz, l);
        if (cosL <= 0.0f) return float3(0.0f);
        float area = 4.0f * length(light.params.xyz) * light.params.w;
        return light.color.rgb * (area * cosL / max(d2, 1e-4f));
    }
    if (type == LIGHT_TUBE) {
        float3 w = light.positionRadius.xyz + light.axis.xyz * (2.0f * u.x - 1.0f) - p;   // the axis point
        float d2 = max(dot(w, w), light.positionRadius.w * light.positionRadius.w);
        float len = 2.0f * length(light.axis.xyz);
        float sinA = length(cross(light.axis.xyz, w)) / max(0.5f * len * sqrt(dot(w, w)), 1e-12f);
        l = normalize(target - p);
        return light.color.rgb * (4.0f / M_PI_F * sinA / d2);   // (4 I / (pi len)) x sin / d^2 / pdf (1 / len)
    }
    return lightVolumeWeight(light, p, l);
}

// A light-table element's light at a fog point p (as lightVolumeSample: irradiance from one direction, no receiver
// cosine): an analytic light's one-sample estimate, or an emissive triangle's point at uv (its mean luminance for the
// weight, `exact` = its textured emission for the shade).
float3 fogSampleElement(uint element, float2 uv, float3 p, thread const SceneData& s, device const TriangleInfo* tris,
                        bool exact, thread float3& target, thread float3& l) {
    uint index = element & ELEMENT_INDEX;
    if ((element & ELEMENT_TYPE) != ELEMENT_TRIANGLE) return lightVolumeSample(s.lights[index], p, uv, s, target, l);
    MeshLightPoint mp = triangleLightPoint(s, s.lights, tris, index, uv, false);
    float3 w = mp.x - p;
    float d2 = dot(w, w);
    l = w * rsqrt(max(d2, 1e-12f));
    target = p + w * 0.99f;
    if (mp.area2 <= 0.0f) return float3(0.0f);
    float g = abs(dot(mp.cr, l)) / mp.area2 / max(d2, 1e-4f) * (0.5f * mp.area2);   // two-sided; uniform point: pdf = 1 / area
    if (!exact) return float3(tris[index].radianceLum * g);
    return meshLightPointEmission(mp, s) * g;
}

// Picks one light for a fog point: mostly in proportion to its weight x the phase function toward the viewer (v), as
// pickLight does for surfaces, and FOG_UNIFORM_PICKS of the time uniformly among the lights that reach p. The uniform
// share keeps a light from being picked too rarely where the weights mislead (an unshadowed sun outweighs a lamp
// even where walls hide the sun), which would make its samples rare, huge and speckled. (A larger share costs more
// than it saves: the rarer light paths diverge within SIMD groups.) u = (pick, subset, mix). Returns lightCount if
// none reaches p.
constant float FOG_UNIFORM_PICKS = 0.1f;

uint pickFogLight(device const Light* lights, uint lightCount, float3 p, float3 v, float g, float3 u, bool sunsOnly,
                  thread float& pdf) {
    float weighted = 0.0f, uniform = 0.0f;
    uint pickW = lightCount, pickU = lightCount;
    bool useUniform = u.z < FOG_UNIFORM_PICKS;
    // Two picks side by side: by weight, and uniform (every light that reaches p offered with weight 1, so its total
    // is their count). u.z / FOG_UNIFORM_PICKS is uniform again within its branch.
    StreamPick byWeight = streamPick(u.x), evenly = streamPick(u.z / FOG_UNIFORM_PICKS);
    LightSubset ls = lightSubset(lightCount, u.y);
    for (uint j = 0; j < ls.count; ++j) {
        uint i = lightSubsetIndex(ls, j, lightCount);
        if (sunsOnly && lightType(lights[i]) != LIGHT_SUN) continue;
        float3 l;
        float w = luminance(lightVolumeWeight(lights[i], p, l)) * phaseHG(-dot(l, v), g);
        if (w <= 0.0f) continue;
        if (byWeight.offer(w)) { pickW = i; weighted = w; }
        if (evenly.offer(1.0f)) { pickU = i; uniform = w; }
    }
    if (byWeight.total <= 0.0f) { pdf = 0.0f; return lightCount; }
    float w = useUniform ? uniform : weighted;
    pdf = ((1.0f - FOG_UNIFORM_PICKS) * w / byWeight.total + FOG_UNIFORM_PICKS / evenly.total) / ls.scale;
    return useUniform ? pickU : pickW;
}

// How far toward the sun the fog dims its light: to the edge of the scene's bounding sphere (Light.params), where
// the sun's irradiance is defined. (Surfaces get it undimmed; this keeps fog and surfaces lit alike.)
inline float sunFogDistance(Light light, float3 p) {
    float3 q = p - light.params.xyz;
    float b = dot(q, light.axis.xyz), c = dot(q, q) - light.params.w * light.params.w;
    return max(-b + sqrt(max(b * b - c, 0.0f)), 0.0f);
}

// Light scattered toward v (unit, toward the viewer) at p, per unit scattering coefficient: the ambient term plus
// one light picked by importance, its sample shadowed by one ray and dimmed by the fog on the way.
// u = (pick, subset, sample xy), uMix = pickFogLight's mix.
constant uint FOG_GRID_CANDIDATES = 4;   // with the light grid: 3 from the grid + 1 from the table (+ the suns)

float3 fogInscatter(float3 p, float3 v, float4 u, float uMix, SCENE_ACCEL accel, thread const SceneData& s,
                    constant FogParams& f, float3 ambient, thread Rng& rng) {
    float g = f.medium.w, pdf;
    // With the light grid (ReGIR, scenes with many lights): RIS over a few grid and table candidates by their
    // unshadowed in-scatter, then one shadow ray to the pick, in place of the weighted loop over a light subset.
    // With FOG_SKY_LIGHT the suns are the only candidates (a city's thousands of lamps and windows, one sample a
    // froxel, scatter in blotches).
    RegirCell cell;
    bool sunsOnly = (f.counts.w & FOG_SKY_LIGHT) != 0;
    uint M = s.lightTable.x > 0 && !sunsOnly ? FOG_GRID_CANDIDATES : 0u, Mg = regirShare(s, p, M, cell);
    if (Mg > 0 || (sunsOnly && s.lightTable.y > 0)) {
        device const LightTableEntry* entries = lightTableEntries(s.lights, s.lightCount);
        device const TriangleInfo* tris = lightTableTriangles(s.lights, s.lightCount, s.lightTable.x);
        uint picked = ELEMENT_NONE;
        float2 pickedUV = float2(0.0f);
        float wSum = 0.0f, pickedTarget = 0.0f;
        for (uint k = 0; k < M + s.lightTable.y; ++k) {
            LightCandidate c;
            if (!lightCandidate(k, Mg, M, s.lightTable, entries, p, s, rng, c)) continue;
            float3 target, l;
            float t = luminance(fogSampleElement(c.element, c.uv, p, s, tris, false, target, l)) * phaseHG(-dot(l, v), g);
            float w = lightCandidateWeight(k, M, t, c.W);
            if (w <= 0.0f) continue;
            wSum += w;
            if (rng.next() * wSum < w) { picked = c.element; pickedUV = c.uv; pickedTarget = t; }
        }
        if (picked == ELEMENT_NONE || pickedTarget <= 0.0f) return ambient;
        float3 target, l;
        float3 E = fogSampleElement(picked, pickedUV, p, s, tris, true, target, l);
        if (all(E <= 0.0f)) return ambient;
        bool sun = (picked & ELEMENT_TYPE) == ELEMENT_SUN;
        Light light = s.lights[picked & ELEMENT_INDEX];
        float T = exp(-fogOpticalDepth(p, l, sun ? sunFogDistance(light, p) : length(target - p), f))
                * (sun ? sunVisibilityScale(light, p, s) : 1.0f);
        if (T < 1e-4f || !isVisible(p, target, accel, RAY_GI)) return ambient;
        return ambient + E * (T * phaseHG(-dot(l, v), g) * (wSum / pickedTarget));
    }
    uint li = pickFogLight(s.lights, s.lightCount, p, v, g, float3(u.xy, uMix), sunsOnly, pdf);
    if (li >= s.lightCount || pdf <= 0.0f) return ambient;
    Light light = s.lights[li];
    float3 target, l;
    float3 E = lightVolumeSample(light, p, u.zw, s, target, l);
    if (all(E <= 0.0f)) return ambient;
    float T = exp(-fogOpticalDepth(p, l, lightType(light) == LIGHT_SUN ? sunFogDistance(light, p) : length(target - p), f))
            * sunVisibilityScale(light, p, s);
    if (T < 1e-4f || !isVisible(p, target, accel, RAY_GI)) return ambient;
    return ambient + E * (T * phaseHG(-dot(l, v), g) / pdf);
}

// Fog along a traced ray o + d s (reflections): the radiance L arriving from distance t is dimmed by the analytic
// transmittance, and in-scatter is added from one point at a uniform distance up to min(t, far), with the noise.
float3 fogAlongRay(float3 o, float3 d, float t, float3 L, float2 uDistMix, float4 u, SCENE_ACCEL accel,
                   thread const SceneData& s, constant FogParams& f, float3 ambient, texture3d<float> noise, thread Rng& rng) {
    float3 result = L * exp(-fogOpticalDepth(o, d, t, f));
    float tm = min(t, f.grid.y);
    float ts = uDistMix.x * tm;
    float3 p = o + d * ts;
    float4 m = fogMedium(p, f, fogNoise(noise, p, f));
    if (m.w > 0.0f)
        result += m.rgb * fogInscatter(p, -d, u, uDistMix.y, accel, s, f, ambient, rng) * (exp(-fogOpticalDepth(o, d, ts, f)) * tm);
    return result;
}

// The froxel grid's slices <-> view depth (exponential).
inline float froxelDepth(constant FogParams& f, float slice) { return f.grid.x * exp(f.grid.z * slice / f.grid.w); }
inline float froxelSlice(constant FogParams& f, float depth) { return log(max(depth, 1e-4f) / f.grid.x) / f.grid.z * f.grid.w; }

// Last frame's froxel grid where this frame's froxel `tid` centre was (or `fallback` if it was outside the grid).
inline float4 fogHistory(constant Uniforms& u, constant FogParams& f, texture3d<float> history, uint3 tid, uint3 dims,
                         float4 fallback) {
    float3 c = u.camPos.xyz + viewDirection(u, (float2(tid.xy) + 0.5f) / float2(dims.xy)) * froxelDepth(f, float(tid.z) + 0.5f);
    float3 q = c - u.prevCamPos.xyz;
    float depth = dot(q, u.prevCamForward.xyz);
    if (depth <= f.grid.x) return fallback;
    float2 ndc = float2(dot(q, u.prevCamRight.xyz) / (depth * u.prevCamRight.w), dot(q, u.prevCamUp.xyz) / (depth * u.prevCamUp.w));
    float3 tc = float3(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f, froxelSlice(f, depth) / f.grid.w);
    return all(tc >= 0.0f) && all(tc <= 1.0f) ? history.sample(fogGridSampler, tc) : fallback;
}

kernel void fogInjectKernel(constant Uniforms&                u          [[buffer(0)]],
                            SCENE_ACCEL                       accel      [[buffer(1)]],
                            device const InstanceData*        instances  [[buffer(6)]],
                            constant SceneShading&            shading    [[buffer(7)]],
                            device const Light*               lights     [[buffer(8)]],
                            device const RegirReservoir* regirGrid [[buffer(11)]],  // the light grid (ReGIR)
                            constant RegirParams&       regir     [[buffer(12)]],
                            constant FogParams&               f          [[buffer(9)]],
                            texture2d<float, access::read>    blueNoise  [[texture(0)]],
                            texture3d<float>                  noise      [[texture(1)]],
                            texture3d<float>                  history    [[texture(2)]],   // last frame's froxels
                            texture3d<float, access::write>   outScatter [[texture(3)]],   // rgb = in-scatter / m, a = extinction
                            texture2d<float, access::read>    normalDepth [[texture(4)]],  // this frame's G-buffer depth
                            uint3 tid [[thread_position_in_grid]])
{
    uint3 dims = uint3(f.counts.x, f.counts.y, uint(f.grid.w));
    if (any(tid >= dims)) return;
    bool historyValid = (f.counts.w & FOG_HISTORY_VALID) != 0;
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);

    // A different blue-noise window per slice.
    Sampler rng = makeSampler(blueNoise, u, tid.xy + uint2(37u, 71u) * tid.z, 0,
                              pcgHash(tid.x + pcgHash(tid.y + pcgHash(tid.z + pcgHash(u.frameIndex)))));

    // A random point of the froxel that the camera sees: in front of the surface of the pixel it projects to. Points
    // no pixel sees (behind a wall, above a ceiling) would leak their light into the froxels that straddle the
    // surface. A froxel behind this frame's pixel keeps what it had (it's hidden there, or seen elsewhere next time).
    float3 j = float3(rng.next2(), rng.next());
    float2 uv = (float2(tid.xy) + j.xy) / float2(dims.xy);
    float pixelDepth = normalDepth.read(min(uint2(uv * float2(u.width, u.height)), uint2(u.width - 1, u.height - 1))).w;
    float z0 = froxelDepth(f, float(tid.z)), z1 = min(froxelDepth(f, float(tid.z + 1)), pixelDepth > 0.0f ? pixelDepth : f.grid.y);
    if (z1 <= z0) {
        outScatter.write(historyValid ? fogHistory(u, f, history, tid, dims, float4(0.0f)) : float4(0.0f), tid);
        return;
    }
    float3 dir = viewDirection(u, uv);
    float3 p = u.camPos.xyz + dir * mix(z0, z1, j.z);
    float4 m = fogMedium(p, f, fogNoise(noise, p, f));
    float4 sample = float4(0.0f, 0.0f, 0.0f, m.w);
    if (m.w > 0.0f) {
        float4 r = float4(rng.next2(), rng.next2());
        sample.rgb = m.rgb * fogInscatter(p, -normalize(dir), r, rng.next(), accel, s, f, skyAmbient(u, s) * f.albedo.w, rng.rng);
    }
    // Blend into last frame's grid, sampled where this froxel's centre was.
    if (historyValid) sample = mix(fogHistory(u, f, history, tid, dims, sample), sample, f.noise.w);
    outScatter.write(roundToHalf(sample), tid);
}

// Front-to-back accumulation along each froxel column, with the energy-conserving step of Hillaire 2015 (the
// in-scatter integrated over each slice under its transmittance). Slice k's texel = everything up to its far side.
kernel void fogIntegrateKernel(constant Uniforms&               u             [[buffer(0)]],
                               constant FogParams&              f             [[buffer(9)]],
                               texture3d<float, access::read>   scatter       [[texture(0)]],
                               texture3d<float, access::write>  outIntegrated [[texture(1)]],   // rgb = in-scatter, a = transmittance
                               uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= f.counts.x || tid.y >= f.counts.y) return;
    float rayScale = length(viewDirection(u, (float2(tid) + 0.5f) / float2(f.counts.xy)));   // view depth -> ray length
    float3 S = float3(0.0f);
    float T = 1.0f, z0 = f.grid.x;
    uint slices = uint(f.grid.w);
    for (uint k = 0; k < slices; ++k) {
        float z1 = froxelDepth(f, float(k + 1));
        float4 m = scatter.read(uint3(tid, k));
        float sigma = max(m.w, 1e-6f), tr = exp(-sigma * (z1 - z0) * rayScale);
        S += T * m.rgb * ((1.0f - tr) / sigma);
        T *= tr;
        outIntegrated.write(float4(S, T), uint3(tid, k));
        z0 = z1;
    }
}

// The fog in front of view depth `depth` at screen position uv: rgb = in-scatter, a = transmittance.
inline float4 fogFromGrid(constant FogParams& f, texture3d<float> integrated, float2 uv, float depth) {
    float s = min(froxelSlice(f, depth), f.grid.w);   // in slice boundaries: texel k holds boundary k + 1
    if (s <= 0.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    float4 v = integrated.sample(fogGridSampler, float3(uv, max(s - 0.5f, 0.5f) / f.grid.w));
    return s < 1.0f ? mix(float4(0.0f, 0.0f, 0.0f, 1.0f), v, s) : v;
}

// The height fog beyond the froxel grid (FogParams.wind.w > 0: it goes on at that share of its density), from the
// grid's far end at tFar along the camera ray o + dir t to tEnd (INFINITY: the sky): `fogged` with it. Its light is
// the grid's own over its far half: what was scattered in there per unit of light taken away.
inline float4 fogHaze(constant FogParams& f, texture3d<float> integrated, float2 uv, float4 fogged, float3 o, float3 dir,
                      float tFar, float tEnd) {
    float tau = f.wind.w * heightFogDepth(o + dir * tFar, dir, tEnd - tFar, f);
    if (!(tau > 0.0f)) return fogged;
    float4 far = integrated.sample(fogGridSampler, float3(uv, (f.grid.w - 0.5f) / f.grid.w));
    float4 mid = integrated.sample(fogGridSampler, float3(uv, (0.5f * f.grid.w - 0.5f) / f.grid.w));
    float3 source = max(far.rgb - mid.rgb, 0.0f) / max(mid.a - far.a, 1e-3f);
    float T = isFar(tau) ? 0.0f : exp(-tau);
    return float4(fogged.rgb + fogged.a * source * (1.0f - T), fogged.a * T);
}

// Reference (benchmarks): the fog along each camera ray, marched in 32 jittered steps up to the surface (or the
// fog's far distance), each with its own light sample and shadow ray, averaged over the frames of a paused scene:
// ground truth for the froxel grid.
kernel void fogReferenceKernel(constant Uniforms&                u          [[buffer(0)]],
                               SCENE_ACCEL                       accel      [[buffer(1)]],
                               device const InstanceData*        instances  [[buffer(6)]],
                               constant SceneShading&            shading    [[buffer(7)]],
                               device const Light*               lights     [[buffer(8)]],
                               device const RegirReservoir* regirGrid [[buffer(11)]],  // the light grid (ReGIR)
                               constant RegirParams&       regir     [[buffer(12)]],
                               constant FogParams&               f          [[buffer(9)]],
                               constant uint&                    sampleCount [[buffer(10)]],  // frames averaged so far
                               texture3d<float>                  noise      [[texture(0)]],
                               texture2d<float, access::read>    normalDepth [[texture(1)]],
                               texture2d<float, access::read_write> accumFog [[texture(2)]],  // running mean: rgb = in-scatter, a = transmittance
                               uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    Rng rng;
    rng.state = pixelSeed(tid, u.frameIndex, SEED_FOG_REFERENCE);

    float3 dir = primaryDirection(u, tid);
    float viewDepth = normalDepth.read(tid).w;
    float depth = min(viewDepth > 0.0f ? viewDepth : f.grid.y, f.grid.y);
    float t = depth / dot(dir, u.camForward.xyz);
    constexpr uint steps = 32;
    float dt = t / float(steps), jitter = rng.next();
    float3 S = float3(0.0f), ambient = skyAmbient(u, s) * f.albedo.w;
    float T = 1.0f;
    for (uint i = 0; i < steps; ++i) {
        float3 p = u.camPos.xyz + dir * ((float(i) + jitter) * dt);
        float4 m = fogMedium(p, f, fogNoise(noise, p, f));
        if (m.w <= 0.0f) continue;
        float tr = exp(-m.w * dt);
        float4 r = float4(rng.next2(), rng.next2());
        S += T * m.rgb * fogInscatter(p, -dir, r, rng.next(), accel, s, f, ambient, rng) * ((1.0f - tr) / m.w);
        T *= tr;
    }
    float4 mean = sampleCount == 0 ? float4(S, T) : mix(accumFog.read(tid), float4(S, T), 1.0f / float(sampleCount + 1));
    accumFog.write(mean, tid);
}
