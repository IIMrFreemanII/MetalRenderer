// ---------------------------------------------------------------------------------------------
// Lights. Every type answers the same questions, so the kernels never look at a light's shape:
//   lightUnshadowed     diffuse light at p if nothing is in the way (albedo divided out); also every pick's weight
//   lightShadowTarget   a random point of the light for a soft-shadow ray (the sun: a far point inside its disc)
//   lightSpecular       GGX specular light, unshadowed (representative point, Karis 2013)
//   penumbraWidth       half width of the penumbra an occluder at distance d casts (sizes the shadow filter)
//   lightMapVisibility  visibility from the light's light map (secondary hits)
// Emissive-mesh lights answer lightUnshadowed and the light map with a proxy (their bounding sphere and mean
// normal), for picking and GI; their direct light is sampled per triangle (sampleMeshLight).
// ---------------------------------------------------------------------------------------------

inline uint lightType(Light light) {
    return (LIGHT_TYPES & (LIGHT_TYPES - 1u)) == 0 ? ctz(LIGHT_TYPES) : uint(light.color.w) >> 2;   // one type: known
}
inline uint lightGroup(Light light) { return uint(light.color.w) & 3u; }
// 1 in group g's channel: `v += groupMask(g) * x` and `dot(v, groupMask(g))` in place of v[g], which indexes a vector
// by a run-time value.
inline float4 groupMask(uint g) { return float4(uint4(g) == uint4(0u, 1u, 2u, 3u)); }
inline uint groupElement(uint4 v, uint g) { uint4 m = select(uint4(0u), v, uint4(g) == uint4(0u, 1u, 2u, 3u)); return m.x | m.y | m.z | m.w; }

// What multiplies a light's ray-traced visibility at p: the clouds' shadow for the sun, 1 for every other light.
// Every sun visibility test goes through this (shadow rays, light maps, the fog), so all paths see the same clouds.
inline float sunVisibilityScale(Light light, float3 p, thread const SceneData& s) {
    return lightType(light) == LIGHT_SUN ? cloudShadow(s, p) : 1.0f;
}
inline float sunVisibilityScale(Light light, float3 p, constant SceneShading& shading) {
    return lightType(light) == LIGHT_SUN ? cloudShadowAt(shading.cloudShadow, shading.skyParams, p) : 1.0f;
}

// Shadow ray from `from` to `to`: true if nothing (but light spheres) is in the way. `blocker` = distance to an
// occluder (any one, not necessarily the nearest), 0 if visible: the shadow denoiser estimates penumbrae from it.
bool isVisibleBlocker(float3 from, float3 to, SCENE_ACCEL accel, thread float& blocker) {
    float3 d = to - from;
    float dist = length(d);
    float t;
    bool hit = intersectAny(makeRay(from, d / dist, 0.0f, max(dist - RAY_EPSILON, 0.0f)), MASK_GEOMETRY, accel, t);
    blocker = hit ? max(t, 1e-3f) : 0.0f;
    return !hit;
}

bool isVisible(float3 from, float3 to, SCENE_ACCEL accel) {
    float b;
    return isVisibleBlocker(from, to, accel, b);
}

// Spot lights: smooth falloff from the inner to the outer cone, for the unit direction from the light to a point.
inline float spotFactor(Light light, float3 fromLight) {
    return smoothstep(light.params.x, light.params.y, dot(fromLight, light.axis.xyz));
}

// Rect lights: corners, counter-clockwise seen from the emitting side.
struct RectCorners { float3 c[4]; };
inline RectCorners rectCorners(Light light) {
    float3 U = light.params.xyz;
    float3 V = normalize(cross(light.axis.xyz, U)) * light.params.w;
    float3 o = light.positionRadius.xyz;
    RectCorners r;
    r.c[0] = o - U - V; r.c[1] = o + U - V; r.c[2] = o + U + V; r.c[3] = o - U + V;
    return r;
}

// Irradiance at p (normal n) from a rect of unit radiance: Lambert's polygon formula, the sum over the edges of the
// angle each subtends times the cosine between n and the normal of its plane through p. Exact while the whole
// rect is above p's horizon; clamped at 0 (the usual approximation) when it crosses it.
inline float rectIrradiance(thread const RectCorners& r, float3 p, float3 center, float3 n) {
    float3 F = float3(0.0f);
    for (uint k = 0; k < 4; ++k) {
        float3 a = normalize(r.c[k] - p), b = normalize(r.c[(k + 1) & 3] - p);
        float3 c = cross(a, b);
        float s = length(c);
        if (s > 1e-7f) F += c * (atan2(s, dot(a, b)) / s);
    }
    if (dot(F, center - p) < 0.0f) F = -F;   // F points toward the rect, whichever way its winding looks from p
    return max(0.5f * dot(F, n), 0.0f);
}

// Tube lights: a thin cylinder of uniform radiance, so a length ds of it has intensity proportional to its
// projected width, sin(angle to the axis) = D / |w| (D = the receiver's distance to the line, w = point - receiver).
// Returns the integral of (n.w) D / |w|^4 along the segment a -> b, exact (Lambert's cylinder), with D clamped to the
// tube radius; irradiance = that x the intensity per unit length at sin = 1.
inline float tubeIrradiance(float3 a, float3 b, float3 n, float radius) {
    float3 d = b - a;
    float len = length(d);
    if (len < 1e-6f) return 0.0f;
    float3 t = d / len;
    float c = dot(a, t);
    float D2 = max(dot(a, a) - c * c, radius * radius), D = sqrt(D2);
    // With x = s + c: n.w = alpha + beta x, |w|^2 = x^2 + D^2.
    float alpha = dot(n, a) - c * dot(n, t), beta = dot(n, t);
    float x0 = c, x1 = c + len;
    float r0 = x0 * x0 + D2, r1 = x1 * x1 + D2;
    float i0 = (x1 / r1 - x0 / r0) / (2.0f * D2) + (atan(x1 / D) - atan(x0 / D)) / (2.0f * D2 * D);   // int dx / (x^2+D^2)^2
    float i1 = 0.5f * (1.0f / r0 - 1.0f / r1);                                                         // int x dx / (x^2+D^2)^2
    return max(D * (alpha * i0 + beta * i1), 0.0f);
}

// Clips segment a -> b (relative to the receiver) to the half space in front of plane normal n.
inline bool clipSegment(thread float3& a, thread float3& b, float3 n) {
    float ha = dot(n, a), hb = dot(n, b);
    if (ha <= 0.0f && hb <= 0.0f) return false;
    if (ha < 0.0f) a = mix(a, b, ha / (ha - hb));
    else if (hb < 0.0f) b = mix(b, a, hb / (hb - ha));
    return true;
}

// Diffuse lighting from one light if nothing is in the way, with albedo divided out:
//   outgoing radiance = albedo * returned value * visibility.
// n = shading normal, ng = geometric normal (both oriented); a light behind the surface contributes nothing.
// Emissive-mesh lights' proxy: intensity sum(L A) / 4 if round, sum(L A) |cos| along the mean normal if flat
// (two-sided); the cosine at the receiver widened by the bounding sphere's angular size, so no part of the emitter
// is given zero weight. For picking and for GI (light maps); direct light samples the triangles.
inline float3 meshLightUnshadowed(Light light, float3 p, float3 n, float3 ng) {
    float3 toLight = light.positionRadius.xyz - p;
    float radius = light.positionRadius.w;
    float dist2 = max(dot(toLight, toLight), radius * radius);
    float d = sqrt(dot(toLight, toLight));
    float3 l = toLight / max(d, 1e-6f);
    float sinA = saturate(radius / max(d, 1e-6f));
    float cosTheta = saturate((dot(n, l) + sinA) / (1.0f + sinA));
    if (cosTheta <= 0.0f || dot(ng, l) + sinA <= 0.0f) return float3(0.0f);
    float flat = light.params.z;
    float intensity = (1.0f - flat) * 0.25f + flat * abs(dot(light.axis.xyz, l));
    return light.color.rgb * (intensity * cosTheta / (M_PI_F * dist2));
}

float3 lightUnshadowedOther(Light light, float3 p, float3 n, float3 ng);

inline float3 lightUnshadowed(Light light, float3 p, float3 n, float3 ng) {
    uint type = lightType(light);
    if (!POINT_LIGHTS_ONLY && type > LIGHT_SPOT) return lightUnshadowedOther(light, p, n, ng);
    float3 toLight = light.positionRadius.xyz - p;
    float radius = light.positionRadius.w;
    float dist2 = max(dot(toLight, toLight), radius * radius);
    float cosTheta = dot(n, normalize(toLight));
    if (cosTheta <= 0.0f || dot(toLight, ng) <= 0.0f) return float3(0.0f);
    float3 e = light.color.rgb * cosTheta / (M_PI_F * dist2);
    if (type == LIGHT_SPOT) e *= spotFactor(light, -normalize(toLight));
    return e;
}

// The other types: sun, rect, tube and the mesh lights' proxy.
float3 lightUnshadowedOther(Light light, float3 p, float3 n, float3 ng) {
    uint type = lightType(light);
    if (type == LIGHT_SUN) {
        float3 l = light.axis.xyz;
        float cosTheta = dot(n, l);
        if (cosTheta <= 0.0f || dot(ng, l) <= 0.0f) return float3(0.0f);
        return light.color.rgb * (cosTheta / M_PI_F);
    }
    if (type == LIGHT_RECT) {
        float3 center = light.positionRadius.xyz;
        if (dot(p - center, light.axis.xyz) <= 0.0f) return float3(0.0f);   // behind the emitting side
        RectCorners r = rectCorners(light);
        float above = max(max(dot(ng, r.c[0] - p), dot(ng, r.c[1] - p)), max(dot(ng, r.c[2] - p), dot(ng, r.c[3] - p)));
        if (above <= 0.0f) return float3(0.0f);
        return light.color.rgb * (rectIrradiance(r, p, center, n) / M_PI_F);
    }
    if (type == LIGHT_TUBE) {
        float3 a = light.positionRadius.xyz - light.axis.xyz - p, b = light.positionRadius.xyz + light.axis.xyz - p;
        if (!clipSegment(a, b, ng) || !clipSegment(a, b, n)) return float3(0.0f);
        // Intensity per unit length broadside: 4 I / (pi length), so the tube emits what a sphere light of
        // intensity I does (power 4 pi I).
        float len = 2.0f * length(light.axis.xyz);
        float perLength = 4.0f / (M_PI_F * max(len, 1e-6f));
        return light.color.rgb * (perLength * tubeIrradiance(a, b, n, light.positionRadius.w) / M_PI_F);
    }
    if (type == LIGHT_MESH) return meshLightUnshadowed(light, p, n, ng);
    return float3(0.0f);
}

// A light's unshadowed light at a point in a medium (no surface, so no receiver cosine): lightUnshadowed with the
// normal toward the light's centre (the sun: its direction). The weight a light is picked by there.
inline float lightVolumeWeight(Light light, float3 p) {
    float3 nl = lightType(light) == LIGHT_SUN ? light.axis.xyz : normalize(light.positionRadius.xyz - p);
    return luminance(lightUnshadowed(light, p, nl, nl));
}

// The suns whose discs camera rays see: the light table's (at most 2), or among the analytic lights.
inline uint sunDiscCount(constant Uniforms& u) { return LIGHT_TABLE ? u.lightTable.y : u.lightGroupEnd.w; }
inline uint sunDiscLight(constant Uniforms& u, uint k) { return LIGHT_TABLE ? (k == 0 ? u.lightTable.z : u.lightTable.w) : k; }

// A sun's disc seen along unit `dir`: its irradiance over its solid angle; 0 off the disc, or for a light that isn't a
// sun. With the sky texture the disc darkens toward its limb and clouds in front of it dim it (skyAlpha: the sky
// texture's alpha along dir).
inline float3 sunDisc(Light light, float3 dir, uint flags, float skyAlpha) {
    float theta = light.positionRadius.w;
    float c = dot(dir, light.axis.xyz);
    if (lightType(light) != LIGHT_SUN || c < cos(theta)) return float3(0.0f);
    float3 disc = light.color.rgb / (4.0f * M_PI_F * sin(0.5f * theta) * sin(0.5f * theta));   // irradiance / solid angle
    if (flagOn(flags, FLAG_SKY_MAP)) {
        float x = sqrt(max(1.0f - c * c, 0.0f)) / sin(theta), mu = sqrt(max(1.0f - x * x, 0.0f));
        disc *= skyAlpha * (1.0f - 0.6f * (1.0f - mu)) / 0.8f;   // limb darkening (u = 0.6), mean 1
    }
    return disc;
}

// A random point of the light, for a soft-shadow ray from p.
inline float3 lightShadowTarget(Light light, float3 p, float2 u) {
    uint type = lightType(light);
    if (type == LIGHT_SUN) {
        // Uniform in the sun's cone, far away.
        float cosMax = cos(light.positionRadius.w);
        float cosT = 1.0f - u.x * (1.0f - cosMax), sinT = sqrt(max(0.0f, 1.0f - cosT * cosT));
        float phi = 2.0f * M_PI_F * u.y;
        float3 t, b;
        tangentFrame(light.axis.xyz, t, b);
        return p + (light.axis.xyz * cosT + (t * cos(phi) + b * sin(phi)) * sinT) * 1e4f;
    }
    if (type == LIGHT_RECT) {
        float3 U = light.params.xyz, V = normalize(cross(light.axis.xyz, U)) * light.params.w;
        return light.positionRadius.xyz + U * (2.0f * u.x - 1.0f) + V * (2.0f * u.y - 1.0f);
    }
    if (type == LIGHT_TUBE) {
        float3 t, b;
        tangentFrame(normalize(light.axis.xyz), t, b);
        float phi = 2.0f * M_PI_F * u.y;
        return light.positionRadius.xyz + light.axis.xyz * (2.0f * u.x - 1.0f)
             + (t * cos(phi) + b * sin(phi)) * light.positionRadius.w;
    }
    if (type == LIGHT_MESH) return light.positionRadius.xyz;   // not used: mesh lights sample triangles
    // Sphere and spot: uniform on the sphere.
    float z = 1.0f - 2.0f * u.x;
    float rr = sqrt(max(0.0f, 1.0f - z * z));
    float phi = 2.0f * M_PI_F * u.y;
    return light.positionRadius.xyz + light.positionRadius.w * float3(rr * cos(phi), rr * sin(phi), z);
}

// GGX light from one direction l carrying illuminance E, widened by Karis's energy normalisation.
inline float3 ggxFromDirection(float3 E, float3 l, float normalisation, float3 n, float3 v, float3 f0, float a) {
    float3 h = normalize(l + v);
    float NoL = saturate(dot(n, l)), NoV = max(dot(n, v), 1e-4f), NoH = saturate(dot(n, h)), VoH = saturate(dot(v, h));
    float3 F = schlick(f0, specularF90(f0), VoH);
    return E * (ggxD(NoH, a) * smithVisibility(NoV, NoL, a) * NoL * normalisation) * F;
}

// Specular light from a light, unshadowed: GGX with the representative point (Karis 2013, the point of the light
// closest to the reflection ray) and its energy normalisation. Radiance, Fresnel included, albedo-free.
inline float3 lightSpecular(Light light, float3 p, float3 n, float3 ng, float3 v, float3 f0, float roughness) {
    uint type = lightType(light);
    float a = max(roughness, MIN_ROUGHNESS); a *= a;
    float3 r = reflect(-v, n);
    if (type == LIGHT_SUN) {
        float3 w = light.axis.xyz;
        if (dot(n, w) <= 0.0f || dot(ng, w) <= 0.0f) return float3(0.0f);
        float theta = light.positionRadius.w, cosR = dot(r, w);
        float3 l = w;
        if (cosR < cos(theta)) {   // the reflection ray misses the disc: its nearest point
            float3 perp = r - w * cosR;
            float len = length(perp);
            if (len > 1e-6f) l = w * cos(theta) + perp * (sin(theta) / len);
        }
        float aPrime = saturate(a + 0.5f * theta);
        return ggxFromDirection(light.color.rgb, l, (a / aPrime) * (a / aPrime), n, v, f0, a);
    }
    if (type == LIGHT_RECT) {
        float3 c = light.positionRadius.xyz, N = light.axis.xyz;
        if (dot(p - c, N) <= 0.0f) return float3(0.0f);
        float3 U = light.params.xyz;
        float hw = length(U), hh = light.params.w;
        float3 Uh = U / hw, Vh = normalize(cross(N, U));
        // Where the reflection ray meets the light's plane (or, going away from it, the point straight ahead of
        // it), clamped into the rect.
        float denom = dot(r, N);
        float3 hitPlane = denom < -1e-4f ? p + r * (dot(c - p, N) / denom) : p + r * length(c - p);
        float3 q = hitPlane - c;
        q = c + Uh * clamp(dot(q, Uh), -hw, hw) + Vh * clamp(dot(q, Vh), -hh, hh);
        float3 L = q - p;
        float dist2 = dot(L, L), dist = sqrt(dist2);
        float3 l = L / max(dist, 1e-6f);
        if (dot(n, l) <= 0.0f || dot(ng, l) <= 0.0f) return float3(0.0f);
        float area = 4.0f * hw * hh;
        float solidAngle = min(area * max(-dot(N, l), 0.0f) / max(dist2, 1e-6f), 2.0f * M_PI_F);
        float aPrime = saturate(a + sqrt(area / M_PI_F) / (2.0f * max(dist, 1e-3f)));
        return ggxFromDirection(light.color.rgb * solidAngle, l, (a / aPrime) * (a / aPrime), n, v, f0, a);
    }
    if (type == LIGHT_TUBE) {
        float radius = light.positionRadius.w;
        float3 L0 = light.positionRadius.xyz - light.axis.xyz - p, L1 = light.positionRadius.xyz + light.axis.xyz - p;
        float3 Ld = L1 - L0;
        float len2 = dot(Ld, Ld), rLd = dot(r, Ld);
        float t = saturate((dot(r, L0) * rLd - dot(L0, Ld)) / max(len2 - rLd * rLd, 1e-6f));
        float3 L = L0 + Ld * t;                                   // the segment's point nearest the reflection ray
        float3 toRay = dot(L, r) * r - L;
        L += toRay * saturate(radius / max(length(toRay), 1e-6f));   // then the nearest point of its cross-section
        float dist2 = max(dot(L, L), radius * radius), dist = sqrt(dist2);
        float3 l = L / sqrt(max(dot(L, L), 1e-12f));
        if (dot(n, l) <= 0.0f || dot(ng, l) <= 0.0f) return float3(0.0f);
        float aSphere = saturate(a + radius / (2.0f * dist));
        float aLine = saturate(a + sqrt(len2) / (4.0f * dist));
        float normalisation = (a / aSphere) * (a / aSphere) * (a / aLine);
        return ggxFromDirection(light.color.rgb / dist2, l, normalisation, n, v, f0, a);
    }
    if (type == LIGHT_MESH) return float3(0.0f);   // reflection rays see mesh lights themselves
    // Sphere and spot.
    float3 L = light.positionRadius.xyz - p;
    float radius = light.positionRadius.w;
    float dist2 = max(dot(L, L), radius * radius), dist = sqrt(dist2);
    if (dot(n, L) <= 0.0f || dot(ng, L) <= 0.0f) return float3(0.0f);
    float3 toRay = dot(L, r) * r - L;
    float3 l = normalize(L + toRay * saturate(radius / max(length(toRay), 1e-6f)));
    float aPrime = saturate(a + radius / (2.0f * dist));
    float normalisation = (a / aPrime) * (a / aPrime);
    float3 h = normalize(l + v);
    float NoL = saturate(dot(n, l)), NoV = max(dot(n, v), 1e-4f), NoH = saturate(dot(n, h)), VoH = saturate(dot(v, h));
    float3 F = schlick(f0, specularF90(f0), VoH);
    float3 s = light.color.rgb * (ggxD(NoH, a) * smithVisibility(NoV, NoL, a) * NoL * normalisation / dist2) * F;
    if (type == LIGHT_SPOT) s *= spotFactor(light, -normalize(L));
    return s;
}

// Emissive-mesh lights: one point on one triangle, the triangle picked by its emitted power (binary search of the
// light's CDF), uniform within it.
struct MeshLightPoint {
    float3 x;                 // the point, world space
    float3 cr;                // the triangle's (unnormalised) world normal: |cr| = 2 x area
    float  area2;             // |cr|
    float  prob;              // probability of the triangle's pick
    float  b1, b2;            // barycentrics of x
    EmissiveTriangle tri;
    uint   material;
    bool   valid;
};

// Places mp (its tri, b1, b2) with the instance transform m: the point, the triangle's normal and twice its area.
inline void placeMeshLightPoint(thread MeshLightPoint& mp, float4x4 m) {
    mp.x = (m * float4(mp.tri.v0.xyz + mp.tri.e1.xyz * mp.b1 + mp.tri.e2.xyz * mp.b2, 1.0f)).xyz;
    mp.cr = cross((m * float4(mp.tri.e1.xyz, 0.0f)).xyz, (m * float4(mp.tri.e2.xyz, 0.0f)).xyz);
    mp.area2 = length(mp.cr);
}

MeshLightPoint sampleMeshLightPoint(Light light, float2 u, thread const SceneData& s) {
    MeshLightPoint mp;
    mp.valid = false;
    uint first = as_type<uint>(light.params.x), count = as_type<uint>(light.params.y);
    if (count == 0) return mp;
    uint lo = 0, hi = count - 1;
    while (lo < hi) {   // first triangle whose cumulative probability exceeds u.x
        uint mid = (lo + hi) / 2;
        if (s.emissive[first + mid].v0.w > u.x) hi = mid; else lo = mid + 1;
    }
    mp.tri = s.emissive[first + lo];
    float prev = lo > 0 ? s.emissive[first + lo - 1].v0.w : 0.0f;
    mp.prob = mp.tri.v0.w - prev;
    if (mp.prob <= 0.0f) return mp;
    float su = sqrt(saturate((u.x - prev) / mp.prob));   // u.x rescaled within the pick: uniform again
    mp.b1 = su * (1.0f - u.y); mp.b2 = su * u.y;
    InstanceData inst = instanceRecord(s.instances, as_type<uint>(light.params.w));
    placeMeshLightPoint(mp, inst.transform);
    mp.material = inst.materialIndex + uint(light.axis.w);   // a mesh of several materials: this light's, from its first
    mp.valid = mp.area2 > 0.0f;
    return mp;
}

// Emitted radiance at a mesh-light point (the emissive texture at ~4 texels per triangle).
float3 meshLightPointEmission(thread const MeshLightPoint& mp, thread const SceneData& s) {
    Material m = s.materials[mp.material];
    float3 Le = m.emission.rgb;
    if (m.textures.w != NO_TEXTURE) {
        float2 uv0 = float2(mp.tri.e1.w, mp.tri.e2.w), d1 = mp.tri.uv12.xy - uv0, d2uv = mp.tri.uv12.zw - uv0;
        float2 uv = uv0 + d1 * mp.b1 + d2uv * mp.b2;
        float uvArea = abs(d1.x * d2uv.y - d1.y * d2uv.x);
        Le *= sampleMaterial(s, m.textures.w, uv, 0.5f * log2(max(uvArea, 1e-12f)) - 2.0f, false).rgb;
    }
    return Le;
}

// One-sample estimate of a mesh light's diffuse lighting at p, unshadowed, albedo divided out. `target` = the
// sampled point, pulled 1% toward p, for the shadow ray (so an emitter traced at a coarser level of detail doesn't
// shadow itself).
float3 sampleMeshLight(Light light, float3 p, float3 n, float3 ng, float2 u, thread const SceneData& s, thread float3& target) {
    target = light.positionRadius.xyz;
    MeshLightPoint mp = sampleMeshLightPoint(light, u, s);
    if (!mp.valid) return float3(0.0f);
    float3 w = mp.x - p;
    float d2 = dot(w, w);
    float3 l = w * rsqrt(max(d2, 1e-12f));
    target = p + w * 0.99f;
    float cosP = dot(n, l), cosL = abs(dot(mp.cr, l)) / max(mp.area2, 1e-12f);   // emission is two-sided
    if (cosP <= 0.0f || dot(ng, l) <= 0.0f) return float3(0.0f);
    float3 Le = meshLightPointEmission(mp, s);
    // Point pdf (area) = prob / area; to solid angle: d^2 / cosL.
    return Le * (cosP * cosL / max(d2, 1e-6f) * (0.5f * mp.area2 / mp.prob) / M_PI_F);
}

// One-sample estimate of a light's diffuse lighting at p, shadowed: lightUnshadowed x the visibility of a random
// point of the light (soft shadows); for mesh lights, one sampled triangle point.
float3 sampleLight(Light light, float3 p, float3 n, float3 ng, float2 u, SCENE_ACCEL accel, thread const SceneData& s) {
    if (lightType(light) == LIGHT_MESH) {
        float3 target;
        float3 c = sampleMeshLight(light, p, n, ng, u, s, target);
        if (all(c == 0.0f) || !isVisible(p, target, accel)) return float3(0.0f);
        return c;
    }
    float3 unshadowed = lightUnshadowed(light, p, n, ng);
    if (all(unshadowed == 0.0f)) return float3(0.0f);
    if (!isVisible(p, lightShadowTarget(light, p, u), accel)) return float3(0.0f);
    return unshadowed * sunVisibilityScale(light, p, s);
}

// The per-light weight loops (light picking, cached light at secondary hits) look at no more than
// LIGHT_CANDIDATES lights: with more, a stratified random subset, one light per stride of N / M from a random
// offset. Each light is then in the subset with probability M / N, so sums over it are scaled by N / M (`scale`),
// which keeps every estimate unbiased; the cost stops growing with the light count, the noise grows a little.
constant uint LIGHT_CANDIDATES = 32;

struct LightSubset {
    uint  count;    // lights to visit
    float stride;
    float offset;
    float scale;    // N / M (1 when every light is visited)
};

inline LightSubset lightSubset(uint lightCount, float u, uint maxCount = LIGHT_CANDIDATES) {
    LightSubset ls;
    if (lightCount <= maxCount) {
        ls.count = lightCount; ls.stride = 1.0f; ls.offset = 0.0f; ls.scale = 1.0f;
    } else {
        ls.count = maxCount;
        ls.stride = float(lightCount) / float(maxCount);
        ls.offset = min(u, 0.99999f) * ls.stride;
        ls.scale = ls.stride;
    }
    return ls;
}

inline uint lightSubsetIndex(LightSubset ls, uint j, uint lightCount) {
    return min(uint(ls.offset + float(j) * ls.stride), lightCount - 1);
}

// Picks one light with probability proportional to its unshadowed luminance at p (streaming weighted reservoir
// sampling: one pass, one random number, rescaled after each decision), among a subset of the lights if there
// are many (uSubset picks it). Returns lightCount if no light reaches p. pdf = the effective probability of the
// pick (including the subset's), so sample / pdf is unbiased.
uint pickLight(device const Light* lights, uint lightCount, float3 p, float3 n, float3 ng, float u, float uSubset,
               thread float& pdf) {
    float pickedWeight = 0.0f;
    uint picked = lightCount;
    StreamPick pick = streamPick(u);
    LightSubset ls = lightSubset(lightCount, uSubset);
    for (uint j = 0; j < ls.count; ++j) {
        uint i = lightSubsetIndex(ls, j, lightCount);
        float w = luminance(lightUnshadowed(lights[i], p, n, ng));
        if (w <= 0.0f) continue;
        if (pick.offer(w)) { picked = i; pickedWeight = w; }
    }
    pdf = pick.total > 0.0f ? pickedWeight / (pick.total * ls.scale) : 0.0f;
    return picked;
}

// The same pick by the lights' unshadowed specular light at p toward v (lightSpecular), for a direct specular sample:
// `specular` = the picked light's. specular / pdf is then the candidates' summed specular in the picked light's
// colour, so the estimate never exceeds what the lights can give and needs no firefly clamp. (A pick by diffuse
// light, as above, gives a light with a strong highlight but little diffuse light here a small pdf: its samples
// were bright enough to be clamped, and the highlights came out dark.)
uint pickLightSpecular(device const Light* lights, uint lightCount, float3 p, float3 n, float3 ng, float3 v, float3 f0,
                       float roughness, float u, float uSubset, thread float& pdf, thread float3& specular) {
    float pickedWeight = 0.0f;
    uint picked = lightCount;
    specular = float3(0.0f);
    StreamPick pick = streamPick(u);
    LightSubset ls = lightSubset(lightCount, uSubset);
    for (uint j = 0; j < ls.count; ++j) {
        uint i = lightSubsetIndex(ls, j, lightCount);
        float3 sp = lightSpecular(lights[i], p, n, ng, v, f0, roughness);
        float w = luminance(sp);
        if (w <= 0.0f) continue;
        if (pick.offer(w)) { picked = i; pickedWeight = w; specular = sp; }
    }
    pdf = pick.total > 0.0f ? pickedWeight / (pick.total * ls.scale) : 0.0f;
    return picked;
}

// Half width of a light's penumbra in world units, for an occluder at distance d from the receiver:
// w = r d / (D - d) for a light of radius r at distance D (as in PCSS); the sun: d tan(angular radius).
// 0 = the sample was visible.
inline float penumbraWidth(Light light, float3 p, float d) {
    if (d <= 0.0f) return 0.0f;
    uint type = lightType(light);
    if (type == LIGHT_SUN) return max(d * tan(light.positionRadius.w), 1e-4f);
    float size = light.positionRadius.w;
    if (type == LIGHT_RECT) size = sqrt(length_squared(light.params.xyz) + light.params.w * light.params.w);
    else if (type == LIGHT_TUBE) size += length(light.axis.xyz);
    float D = length(light.positionRadius.xyz - p);
    return max(size * d / max(D - d, 1e-3f), 1e-4f);
}

// ---------------------------------------------------------------------------------------------
// Light table (LightTable.swift): every light but the suns, and every emissive-mesh triangle, as one alias table after
// the lights in their buffer, drawn from in O(1) in proportion to nominal power. A light sample is (element, uv):
// uv picks the point (lightShadowTarget for analytic lights and suns, sqrt-warped barycentrics for triangles) relative
// to the light's current pose, so a sample moves with its light and reusing it across frames and pixels needs no
// Jacobian. What it estimates is what the exact path computes: a light's analytic unshadowed light x the visibility of
// the sample's point (triangles: their emission x the geometry term, per point).
// ---------------------------------------------------------------------------------------------

struct LightTableEntry { float threshold; uint alias; float pdf; uint element; };
struct TriangleInfo { uint light; float radianceLum; };

constant uint ELEMENT_TRIANGLE = 1u << 30, ELEMENT_SUN = 2u << 30;   // else analytic (0)
constant uint ELEMENT_TYPE = 3u << 30, ELEMENT_INDEX = (1u << 30) - 1u, ELEMENT_NONE = 0xFFFFFFFFu;

inline device const LightTableEntry* lightTableEntries(device const Light* lights, uint lightCount) {
    return (device const LightTableEntry*)(lights + lightCount);
}
inline device const TriangleInfo* lightTableTriangles(device const Light* lights, uint lightCount, uint entries) {
    return (device const TriangleInfo*)(lightTableEntries(lights, lightCount) + entries);
}

// A light-table triangle's point at uv (uniform over the triangle: pdf = 1 / area), on its instance as it is this
// frame or (prev) was last frame. `lights` = the light buffer `tris` belongs to.
inline MeshLightPoint triangleLightPoint(thread const SceneData& s, device const Light* lights,
                                         device const TriangleInfo* tris, uint index, float2 uv, bool prev) {
    MeshLightPoint mp;
    mp.tri = s.emissive[index];
    Light light = lights[tris[index].light];
    InstanceData inst = instanceRecord(s.instances, as_type<uint>(light.params.w));
    float su = sqrt(uv.x);
    mp.b1 = su * (1.0f - uv.y); mp.b2 = su * uv.y;
    placeMeshLightPoint(mp, prev ? inst.prevTransform : inst.transform);
    mp.prob = 1.0f;
    mp.material = inst.materialIndex + uint(light.axis.w);
    mp.valid = mp.area2 > 0.0f;
    return mp;
}

// One element in proportion to the table's probabilities, from two random uints.
inline uint sampleLightTable(device const LightTableEntry* table, uint count, uint h0, uint h1, thread float& pdf) {
    LightTableEntry e = table[mulhi(h0, count)];
    if (float(h1 >> 8) * (1.0f / 16777216.0f) >= e.threshold) e = table[e.alias];
    pdf = e.pdf;
    return e.element;
}

// The stored precision of a sample's uv (ReSTIR's reservoirs, the light grid), so a sample is evaluated at the same
// point wherever it is reused.
inline float2 quantizeUV(float2 uv) { return unpack_unorm2x16_to_float(pack_float_to_unorm2x16(uv)); }
