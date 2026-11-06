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
        if (cosL <= 0.0f || !rectReaches(light, p)) return float3(0.0f);
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

// A mesh light's in-scatter at p from one of FOG_MESH_CANDIDATES triangle points, picked by resampling (RIS) in
// proportion to cosL / d^2, a fifth as likely on triangles facing away from p (one point alone swings with 1/d^2,
// and near a closed emitter half of them lie on its hidden side). The candidates are the R2 lattice rotated by u
// (stratified, no more random numbers); the pick's own random number is a hash of u. Unbiased (the target is
// positive wherever the light is: two-sided and open emitters still count); the caller traces the shadow ray.
// (Emissive scene, orb close up, M4 Max: 4 candidates against 1 took the error near the neon sign from 3.1 to 2.6 RMS
// for 0.07 ms of fog and 0.06 of reflections; 8 gained nothing more.)
constant uint FOG_MESH_CANDIDATES = 4;

float3 meshLightAreaSample(Light light, float3 p, float2 u, thread const SceneData& s, thread float3& target, thread float3& l) {
    const float2 r2 = float2(0.7548776662f, 0.5698402910f);
    StreamPick pick = streamPick(float(pcgHash(as_type<uint>(u.x) ^ pcgHash(as_type<uint>(u.y)))) * (1.0f / 4294967296.0f));
    MeshLightPoint chosen;
    chosen.valid = false;
    float chosenTarget = 0.0f;
    for (uint k = 0; k < FOG_MESH_CANDIDATES; ++k) {
        MeshLightPoint mp = sampleMeshLightPoint(light, fract(u + float(k) * r2), s);
        if (!mp.valid) continue;
        float3 w = mp.x - p;
        float d2 = max(dot(w, w), 1e-4f);
        float t = abs(dot(mp.cr, w)) * rsqrt(d2) / (mp.area2 * d2) * (dot(mp.cr, w) < 0.0f ? 1.0f : 0.2f);
        float weight = t * (0.5f * mp.area2 / mp.prob);   // target / pdf (the point's pdf: prob / area)
        if (weight > 0.0f && pick.offer(weight)) { chosen = mp; chosenTarget = t; }
    }
    if (!chosen.valid || chosenTarget <= 0.0f) return float3(0.0f);
    float3 w = chosen.x - p;
    float d2 = dot(w, w);
    l = w * rsqrt(max(d2, 1e-12f));
    target = p + w * 0.99f;
    float cosL = abs(dot(chosen.cr, l)) / chosen.area2;
    return meshLightPointEmission(chosen, s) * (cosL / max(d2, 1e-4f) / chosenTarget * (pick.total / float(FOG_MESH_CANDIDATES)));
}

// A compact mesh light seen from outside its bounding sphere: a direction uniform in the cone the sphere subtends,
// traced to the first surface; this light's emission there over the cone's pdf if the ray hits one of its
// triangles, nothing if it hits anything else (the ray is the shadow ray: `traced`). Compact: its surface fills at
// least FOG_CONE_FILL of the cone (a convex body's mean silhouette is a quarter of its area, so area / (4 pi r^2),
// the area from its power and its material's emission): an orb's rays nearly all hit it, so the estimate barely
// varies. Triangle points left each froxel near the Emissive scene's orb with its own error (half of the points on
// its hidden side, the rest swinging with 1/d^2), which MetalFX's denoiser smeared into blotches. Thin and flat
// emitters (neon bars, screens), whose cones the rays would mostly miss, and points inside the sphere, keep
// meshLightAreaSample. Either estimate is unbiased, so choosing per light and point is too.
constant float FOG_CONE_FILL = 0.5f;

float3 meshLightVolumeSample(Light light, float3 p, float2 u, SCENE_ACCEL accel, thread const SceneData& s,
                             thread float3& target, thread float3& l, thread bool& traced) {
    traced = false;
    float3 toCentre = light.positionRadius.xyz - p;
    float r = light.positionRadius.w, D2 = dot(toCentre, toCentre);
    if (D2 <= 1.0001f * r * r) return meshLightAreaSample(light, p, u, s, target, l);   // inside its sphere
    uint instance = as_type<uint>(light.params.w);
    InstanceData inst = instanceRecord(s.instances, instance);
    uint material = inst.materialIndex + uint(light.axis.w);
    Material m = s.materials[material];
    float le = luminance(m.emission.rgb);
    float fill = le > 0.0f ? luminance(light.color.rgb) / (le * 4.0f * M_PI_F * r * r) : 0.0f;
    if (fill < FOG_CONE_FILL) return meshLightAreaSample(light, p, u, s, target, l);

    traced = true;
    float D = sqrt(D2), sin2 = r * r / D2, cosMax = sqrt(max(1.0f - sin2, 0.0f));
    float oneMinusCos = sin2 / (1.0f + cosMax);   // 1 - cosMax without the cancellation
    float cosT = 1.0f - u.x * oneMinusCos, sinT = sqrt(max(0.0f, 1.0f - cosT * cosT)), phi = 2.0f * M_PI_F * u.y;
    float3 axis = toCentre / D, t, b;
    tangentFrame(axis, t, b);
    l = axis * cosT + (t * cos(phi) + b * sin(phi)) * sinT;
    Hit h = intersectClosest(makeRay(p, l, 0.0f, D + r), rayMask(MASK_GEOMETRY, RAY_GI), accel);
    if (!h.hit || h.instance != instance || (SDF_SHAPES && h.part == HIT_SDF) || (VOXELS && h.part == HIT_VOXEL)
        || (HAIR_CURVES && h.part == HIT_CURVE)) return float3(0.0f);
    float3 Le = m.emission.rgb;
    bool textured = m.textures.w != NO_TEXTURE;
    if (!textured && !MULTI_MATERIAL && !STREAMED && h.part == HIT_NO_PART) {
        // One material, no texture: the hit's material is the instance's, no vertices to read.
        if (inst.materialIndex != material) return float3(0.0f);
    } else {
        HitVertices hv = fetchHitVertices(h, inst, accel, s);
        uint hitMaterial = inst.materialIndex + (hv.leaf ? 1u : 0u);   // as hitMaterialIndex (Surface.metal)
        if (MULTI_MATERIAL && hv.triangle != ~0u) hitMaterial += s.triangleMaterials[hv.triangle];
        if (STREAMED) hitMaterial += hv.material;
        if (hitMaterial != material) return float3(0.0f);   // another material of its mesh: not this light
        if (textured) {
            float2 bc = h.barycentrics, d1 = hv.t[1] - hv.t[0], d2uv = hv.t[2] - hv.t[0];
            float2 uv = hv.t[0] + d1 * bc.x + d2uv * bc.y;
            float uvArea = abs(d1.x * d2uv.y - d1.y * d2uv.x);   // the texel footprint meshLightPointEmission takes
            Le *= sampleMaterial(s, m.textures.w, uv, 0.5f * log2(max(uvArea, 1e-12f)) - 2.0f, false).rgb;
        }
    }
    target = p + l * h.distance;
    float T = PARTICLES ? particleTransmittance(p, l, 0.0f, h.distance, accel) : 1.0f;   // isVisible's particles, averaged
    return Le * (T * 2.0f * M_PI_F * oneMinusCos);
}

// One-sample estimate of the same, with a shadow-ray end `target` and the direction `l` the light arrives from:
// spheres, spots and the sun as above; a uniform point of the emitter for rects, tubes (along the axis, intensity
// per unit length 4 I / (pi length) broadside) and mesh lights (meshLightAreaSample; fogInscatter aims at compact
// ones with meshLightVolumeSample).
float3 lightVolumeSample(Light light, float3 p, float2 u, thread const SceneData& s, thread float3& target, thread float3& l) {
    uint type = lightType(light);
    if (type == LIGHT_MESH) return meshLightAreaSample(light, p, u, s, target, l);
    target = lightShadowTarget(light, p, u);
    if (type == LIGHT_RECT) {
        float3 w = target - p;
        float d2 = dot(w, w);
        l = w * rsqrt(max(d2, 1e-12f));
        float cosL = -dot(light.axis.xyz, l);
        if (cosL <= 0.0f || !rectReaches(light, p)) return float3(0.0f);
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

// In the walkable interiors' box (FogParams.interiorLo / Hi), the sky's ambient light reaches a point of the fog only
// where the sky is in sight: one cosine-weighted ray up to FOG_AMBIENT_REACH, open or not (the froxels' history and the
// reference's frames average it). Without it the fog in a closed room glowed with the sky's light, a haze over the
// whole interior. Only in the box: under a forest's leaves the rays cost a fifth of the frame on the M1 Max.
constant float FOG_AMBIENT_REACH = 40.0f;
inline float3 fogSkyAmbient(float3 p, float3 ambient, SCENE_ACCEL accel, thread Rng& rng) {
    if (all(ambient <= 0.0f)) return ambient;
    float2 xi = float2(rng.next(), rng.next());
    float t;
    bool blocked = intersectAny(makeRay(p, cosineSampleHemisphere(float3(0.0f, 1.0f, 0.0f), xi), 0.0f, FOG_AMBIENT_REACH),
                                rayMask(MASK_GEOMETRY, RAY_GI), accel, t);
    return blocked ? float3(0.0f) : ambient;
}

float3 fogInscatter(float3 p, float3 v, float4 u, float uMix, SCENE_ACCEL accel, thread const SceneData& s,
                    constant FogParams& f, float3 ambient, thread Rng& rng) {
    if (inInteriorBox(f.interiorLo, f.interiorHi, p)) ambient = fogSkyAmbient(p, ambient, accel, rng);
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
    bool traced = false;   // the sample's own ray already found it in sight (meshLightVolumeSample's cone)
    float3 E = lightType(light) == LIGHT_MESH ? meshLightVolumeSample(light, p, u.zw, accel, s, target, l, traced)
                                              : lightVolumeSample(light, p, u.zw, s, target, l);
    if (all(E <= 0.0f)) return ambient;
    float T = exp(-fogOpticalDepth(p, l, lightType(light) == LIGHT_SUN ? sunFogDistance(light, p) : length(target - p), f))
            * sunVisibilityScale(light, p, s);
    if (T < 1e-4f || (!traced && !isVisible(p, target, accel, RAY_GI))) return ambient;
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

// The centre of froxel `tid`, in the world.
inline float3 froxelCentre(constant Uniforms& u, constant FogParams& f, uint3 tid, uint3 dims) {
    return u.camPos.xyz + viewDirection(u, (float2(tid.xy) + 0.5f) / float2(dims.xy)) * froxelDepth(f, float(tid.z) + 0.5f);
}

// Where this frame's froxel `tid` centre was in last frame's grid (texture coordinates), false if outside it.
inline bool fogHistoryCoord(constant Uniforms& u, constant FogParams& f, uint3 tid, uint3 dims, thread float3& tc) {
    float3 q = froxelCentre(u, f, tid, dims) - u.prevCamPos.xyz;
    float depth = dot(q, u.prevCamForward.xyz);
    if (depth <= f.grid.x) return false;
    float2 ndc = float2(dot(q, u.prevCamRight.xyz) / (depth * u.prevCamRight.w), dot(q, u.prevCamUp.xyz) / (depth * u.prevCamUp.w));
    tc = float3(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f, froxelSlice(f, depth) / f.grid.w);
    return all(tc >= 0.0f) && all(tc <= 1.0f);
}

// The fog's light at p toward the viewer (v), unshadowed and smooth: every light's picking weight (lightVolumeWeight x
// the phase) plus the ambient. It moves with the lights the frame they move, so the froxels' history is rescaled by
// it (fogInjectKernel): with one light sample a froxel a frame and 90% of the last frames kept, a light that moved
// left its glow in the fog where it had been for ten frames (the Emissive scene's spinning cubes trailed theirs).
// Few lights only (it loops over them all, as pickFogLight does up to LIGHT_CANDIDATES); 0 = no guide (more: a city's
// lamps, the history as it was).
inline float3 fogLightGuide(constant FogParams& f, thread const SceneData& s, float3 p, float3 v, float3 ambient) {
    if (s.lightCount > LIGHT_CANDIDATES) return float3(0.0f);
    bool sunsOnly = (f.counts.w & FOG_SKY_LIGHT) != 0;
    float3 sum = ambient;
    for (uint i = 0; i < s.lightCount; ++i) {
        if (sunsOnly && lightType(s.lights[i]) != LIGHT_SUN) continue;
        float3 l;
        sum += lightVolumeWeight(s.lights[i], p, l) * phaseHG(-dot(l, v), f.medium.w);
    }
    return min(sum, float3(60000.0f));   // (stored as half)
}

constant float FOG_GUIDE_MAX_RATIO = 8.0f;   // past this the history is mostly another light's: this frame's sample takes half

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
                            texture3d<float>                  guideHistory [[texture(5)]], // last frame's fogLightGuide
                            texture3d<float, access::write>   outGuide   [[texture(6)]],   // this frame's, at the froxels' centres
                            uint3 tid [[thread_position_in_grid]])
{
    uint3 dims = uint3(f.counts.x, f.counts.y, uint(f.grid.w));
    if (any(tid >= dims)) return;
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    float3 ambient = skyAmbient(u, s) * f.albedo.w;

    // Last frame's froxels where this one's centre was, rescaled by how much the lights' unshadowed light there changed
    // since (fogLightGuide, at the centres both frames): the history keeps averaging the samples' noise (the light
    // picked, the shadows) but not the place a light was. Where the light grew past FOG_GUIDE_MAX_RATIO (a light come
    // close), this frame's sample takes half.
    float3 tc;
    bool seen = (f.counts.w & FOG_HISTORY_VALID) != 0 && fogHistoryCoord(u, f, tid, dims, tc);
    float4 last = seen ? history.sample(fogGridSampler, tc) : float4(0.0f);
    float3 centre = froxelCentre(u, f, tid, dims);
    float3 guide = fogLightGuide(f, s, centre, normalize(u.camPos.xyz - centre), ambient);
    float blend = f.noise.w;
    float3 lastGuide = seen ? guideHistory.sample(fogGridSampler, tc).rgb : float3(0.0f);
    if (luminance(guide) > 0.0f && luminance(lastGuide) > 0.0f) {
        float eps = 1e-4f * (luminance(guide) + luminance(lastGuide));
        float3 ratio = (guide + eps) / (lastGuide + eps);
        if (any(ratio > FOG_GUIDE_MAX_RATIO)) blend = max(blend, 0.5f);
        last.rgb *= min(ratio, FOG_GUIDE_MAX_RATIO);
    }
    outGuide.write(roundToHalf(float4(guide, 0.0f)), tid);

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
        outScatter.write(roundToHalf(last), tid);
        return;
    }
    float3 dir = viewDirection(u, uv);
    float3 p = u.camPos.xyz + dir * mix(z0, z1, j.z);
    float4 m = fogMedium(p, f, fogNoise(noise, p, f));
    float4 sample = float4(0.0f, 0.0f, 0.0f, m.w);
    if (m.w > 0.0f) {
        float4 r = float4(rng.next2(), rng.next2());
        sample.rgb = m.rgb * fogInscatter(p, -normalize(dir), r, rng.next(), accel, s, f, ambient, rng.rng);
    }
    // Blend into last frame's grid, sampled where this froxel's centre was.
    if (seen) sample = mix(last, sample, blend);
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
