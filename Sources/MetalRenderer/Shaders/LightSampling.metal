// The surface a light sample lights.
struct ShadingPoint {
    float3 p, n, ng, v;   // p already offset along ng
    float3 albedo;        // weighs diffuse against specular in the target function (floored, so black surfaces still pick)
    float3 f0;
    float  roughness;
    bool   specular;      // F0 > 0 (with FLAG_SPECULAR)
};

// A light sample at a surface, unshadowed: diffuse light (albedo divided out, like lightUnshadowed), specular light,
// and the shadow ray's end point. The clouds' shadow is in for the sun.
struct LightSampleEval {
    float3 diffuse;
    float3 specular;
    float3 target;
};

// `lights` = this frame's or (prev) last frame's: a triangle then uses its instance's last transform.
// `exact` = textured emission (shading); otherwise the triangle's mean luminance (the target function: no textures).
LightSampleEval evalLightSample(uint element, float2 uv, thread const ShadingPoint& sp, thread const SceneData& s,
                                device const Light* lights, device const TriangleInfo* tris, bool prev, bool exact) {
    LightSampleEval e;
    e.diffuse = e.specular = float3(0.0f);
    uint index = element & ELEMENT_INDEX;
    if ((element & ELEMENT_TYPE) == ELEMENT_TRIANGLE) {
        MeshLightPoint mp = triangleLightPoint(s, lights, tris, index, uv, prev);
        float3 w = mp.x - sp.p;
        float d2 = dot(w, w);
        float3 l = w * rsqrt(max(d2, 1e-12f));
        e.target = sp.p + w * 0.99f;   // pulled toward p: an emitter traced at a coarser level of detail doesn't shadow itself
        float cosP = dot(sp.n, l), cosL = abs(dot(mp.cr, l)) / max(mp.area2, 1e-12f);   // emission is two-sided
        if (cosP <= 0.0f || dot(sp.ng, l) <= 0.0f || mp.area2 <= 0.0f) return e;
        float g = cosP * cosL / max(d2, 1e-6f) * (0.5f * mp.area2) / M_PI_F;   // uniform point: pdf = 1 / area
        e.diffuse = exact ? meshLightPointEmission(mp, s) * g : float3(tris[index].radianceLum * g);
        return e;
    }
    Light light = lights[index];
    e.target = lightShadowTarget(light, sp.p, uv);
    float cloud = sunVisibilityScale(light, sp.p, s);
    e.diffuse = lightUnshadowed(light, sp.p, sp.n, sp.ng) * cloud;
    if (sp.specular) e.specular = lightSpecular(light, sp.p, sp.n, sp.ng, sp.v, sp.f0, sp.roughness) * cloud;
    return e;
}

// ReSTIR's target function: the sample's unshadowed luminance as the pixel would show it.
inline float lightSampleTarget(thread const LightSampleEval& e, thread const ShadingPoint& sp) {
    return luminance(sp.albedo * e.diffuse + e.specular);
}

// Candidate k of a sampler's RIS over the lights at p: the first Mg come from the light grid, the rest of the M from
// the light table, then each sun once. W = 1 / the pdf of its source (the suns: 1). False for an empty grid slot.
// (ReSTIR DI's initial candidates are drawn in their own order, with quantised uv: restirTemporalKernel.)
struct LightCandidate { uint element; float2 uv; float W; };
inline bool lightCandidate(uint k, uint Mg, uint M, uint4 table, device const LightTableEntry* entries, float3 p,
                           thread const SceneData& s, thread Rng& rng, thread LightCandidate& c) {
    c.W = 1.0f;
    if (k < Mg) return regirDraw(s, p, rng, c.element, c.uv, c.W);
    float pdf = 1.0f;
    uint h0 = rng.nextUint(), h1 = rng.nextUint();
    c.element = k < M ? sampleLightTable(entries, table.x, h0, h1, pdf) : ELEMENT_SUN | (k == M ? table.z : table.w);
    c.uv = rng.next2();
    c.W = 1.0f / pdf;
    return true;
}
// Its RIS weight for the target t: the grid's and the table's M candidates share one strategy (t W / M), a sun is
// its own (t).
inline float lightCandidateWeight(uint k, uint M, float t, float W) { return k < M ? t * W / float(M) : t; }

// Direct light at a point from one light sample picked by RIS among `candidates` table draws and the suns (one each),
// by unshadowed luminance, with one shadow ray: an unbiased estimate of the light from every light. For GI's hits and
// the path tracer's next-event estimation in scenes with many lights (LIGHT_TABLE), in place of per-light loops.
float3 sampleLightsRIS(device const Light* lights, uint lightCount, uint4 table, float3 p, float3 n, float3 ng,
                       uint candidates, thread Rng& rng, SCENE_ACCEL accel, thread const SceneData& s) {
    ShadingPoint sp;
    sp.p = p; sp.n = n; sp.ng = ng; sp.v = n; sp.albedo = float3(1.0f); sp.f0 = float3(0.0f); sp.roughness = 1.0f;
    sp.specular = false;
    device const LightTableEntry* entries = lightTableEntries(lights, lightCount);
    device const TriangleInfo* tris = lightTableTriangles(lights, lightCount, table.x);
    uint M = table.x > 0 ? candidates : 0u;
    RegirCell cell;
    uint Mg = regirShare(s, p, M, cell);   // from the light grid, then the table, then the suns
    uint picked = ELEMENT_NONE;
    float2 pickedUV = float2(0.0f);
    float wSum = 0.0f, pickedTarget = 0.0f;
    for (uint k = 0; k < M + table.y; ++k) {
        LightCandidate c;
        if (!lightCandidate(k, Mg, M, table, entries, p, s, rng, c)) continue;
        float t = lightSampleTarget(evalLightSample(c.element, c.uv, sp, s, lights, tris, false, false), sp);
        float w = lightCandidateWeight(k, M, t, c.W);
        if (w <= 0.0f) continue;
        wSum += w;
        if (rng.next() * wSum < w) { picked = c.element; pickedUV = c.uv; pickedTarget = t; }
    }
    if (picked == ELEMENT_NONE || pickedTarget <= 0.0f) return float3(0.0f);
    LightSampleEval e = evalLightSample(picked, pickedUV, sp, s, lights, tris, false, true);
    if (!isVisible(p, e.target, accel)) return float3(0.0f);
    return e.diffuse * (wSum / pickedTarget);
}

// Is `nd` (a G-buffer's normal and view depth, depth <= 0 = nothing there) the surface with normal n expected at
// `depth`? The tolerances (relative depth, cosine between the normals), by what the match is used for:
constant float REUSE_DEPTH = 0.1f, REUSE_NORMAL = 0.9f;             // history and neighbours reused as the pixel's own
constant float FEEDBACK_DEPTH = 0.05f, FEEDBACK_NORMAL = 0.8f;      // last frame's light at a path's hit
constant float REFLECTION_DEPTH = 0.03f, REFLECTION_NORMAL = 0.7f;  // this frame's GI at a reflection ray's hit
inline bool sameSurface(float4 nd, float depth, float3 n, float depthTolerance, float minCos) {
    return nd.w > 0.0f && abs(nd.w - depth) < depthTolerance * depth && dot(nd.xyz, n) > minCos;
}

// Last frame's pixel for a pixel with motion vector mv (xy = where it was, in pixels; z = the depth expected there;
// w > 0 = valid) and normal n: the nearest pixel if it shows the same surface, else -1.
inline int2 reprojectNearest(constant Uniforms& u, float4 mv, float3 n, texture2d<float, access::read> prevND) {
    if (!(mv.w > 0.0f)) return int2(-1);
    int2 c = int2(floor(mv.xy + 0.5f));
    if (c.x >= 0 && c.y >= 0 && c.x < int(u.width) && c.y < int(u.height)
        && sameSurface(prevND.read(uint2(c)), mv.z, n, REUSE_DEPTH, REUSE_NORMAL)) return c;
    return int2(-1);
}

// Continuous pixel coordinate (no jitter, y down) of camera-relative vector v, for a camera given as
// right/up/forward with tan(fov/2) in .w. Returns the view depth along forward in `depth`.
inline float2 projectToPixel(float3 v, float4 right, float4 up, float4 forward, float2 size, thread float& depth) {
    depth = dot(v, forward.xyz);
    float2 ndc = float2(dot(v, right.xyz) / (depth * right.w), dot(v, up.xyz) / (depth * up.w));
    return float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * size;
}

// The pixel that shows a surface point (v = the point - the camera, n = its normal) in a frame's G-buffer, for that
// frame's camera: false when the point is off screen or another surface covers it.
inline bool surfacePixel(float3 v, float3 n, float4 right, float4 up, float4 forward, constant Uniforms& u,
                         texture2d<float, access::read> normalDepth, float depthTolerance, float minCos,
                         thread uint2& q) {
    float depth;
    float2 px = projectToPixel(v, right, up, forward, float2(u.width, u.height), depth);
    if (!(depth > 0.0f && all(px >= 0.0f) && px.x < float(u.width) && px.y < float(u.height))) return false;
    q = uint2(px);
    return sameSurface(normalDepth.read(q), depth, n, depthTolerance, minCos);
}
// The same in last frame's G-buffer, for a point where it was last frame: where a path's hit reads last frame's light.
inline bool lastFramePixel(constant Uniforms& u, float3 prevPosition, float3 n, texture2d<float, access::read> prevND,
                           thread uint2& q) {
    return surfacePixel(prevPosition - u.prevCamPos.xyz, n, u.prevCamRight, u.prevCamUp, u.prevCamForward, u, prevND,
                        FEEDBACK_DEPTH, FEEDBACK_NORMAL, q);
}

// Spatial reuse (ReSTIR DI and GI). A random pixel in the disk of `radius` around tid: false for tid itself and for a
// pixel off screen.
inline bool diskNeighbour(uint2 tid, float radius, constant Uniforms& u, thread Rng& rng, thread int2& q) {
    float r = radius * sqrt(rng.next()), angle = 2.0f * M_PI_F * rng.next();
    q = int2(tid) + int2(round(r * float2(cos(angle), sin(angle))));
    return !(all(q == int2(tid)) || q.x < 0 || q.y < 0 || q.x >= int(u.width) || q.y >= int(u.height));
}

// Pairwise MIS with confidence weights (Bitterli 2022, as in Lin et al. 2022), for one neighbour of confidence Mj
// against the canonical sample's share cShare = M_c / n (n = neighbours with a reservoir, Msum = every M). The
// targets: cc, jc = the canonical sample's here and at the neighbour; jj, cj = the neighbour's sample's there and
// here. x = what this neighbour adds to the canonical sample's weight m_c, y = the neighbour's sample's weight m_j.
// Every sample's weights sum to 1, so the result stays unbiased (for the target).
inline float2 pairwiseMIS(float Mj, float cShare, float Msum, float cc, float jc, float jj, float cj) {
    float B = (Mj + cShare) / Msum;
    return float2(B * (cShare * cc) / max(Mj * jc + cShare * cc, 1e-30f),
                  B * (Mj * jj) / max(Mj * jj + cShare * cj, 1e-30f));
}

// ---------------------------------------------------------------------------------------------
// Equal-area octahedral mapping (Clarberg 2008): unit vector <-> [-1, 1]^2, every texel covers the same solid
// angle. Used for the light-visibility maps and the radiance-cascade direction bins.
// ---------------------------------------------------------------------------------------------

inline float3 equalAreaOctDecode(float2 f) {
    float2 a = abs(f);
    float d = 1.0f - (a.x + a.y);                     // > 0 inside the diamond = upper hemisphere
    float r = 1.0f - abs(d);
    float phi = r > 0.0f ? (M_PI_F / 4.0f) * ((a.y - a.x) / r + 1.0f) : 0.0f;
    float z = copysign(1.0f - r * r, d);
    float sinTheta = r * sqrt(max(2.0f - r * r, 0.0f));
    return float3(copysign(cos(phi) * sinTheta, f.x), copysign(sin(phi) * sinTheta, f.y), z);
}

inline float2 equalAreaOctEncode(float3 v) {
    float3 a = abs(v);
    float r = sqrt(max(1.0f - a.z, 0.0f));
    float phi = (a.x > 0.0f || a.y > 0.0f) ? atan2(a.y, a.x) : 0.0f;
    float y = phi * (2.0f / M_PI_F) * r;
    float x = r - y;
    if (v.z < 0.0f) { float t = x; x = 1.0f - y; y = 1.0f - t; }   // fold the lower hemisphere into the corners
    return float2(copysign(x, v.x), copysign(y, v.y));
}

// ---------------------------------------------------------------------------------------------
// Light-visibility maps: for each light, the distance to the nearest geometry in every direction, traced from
// the light's centre once per frame. Secondary hits (path-tracer bounces with FLAG_LIGHT_MAPS and
// radiance-cascade intervals) look up shadowing here instead of tracing a shadow ray. Shadows are hard (from
// the light's centre), which is invisible once indirect light has been integrated over a hemisphere.
// The sun's map is orthographic instead: the depth along its direction over a square covering the scene's
// bounding sphere (Light.params). Emissive-mesh lights trace theirs from their bounding sphere's surface outward.
// Maps are 128^2 for up to 16 lights and smaller beyond (Renderer.lightMapSize), so tracing them costs the same.
// ---------------------------------------------------------------------------------------------

// Where a light's octahedral map is traced from, and how far out its rays start.
inline float3 lightMapCenter(Light light) {
    if (lightType(light) == LIGHT_RECT) return light.positionRadius.xyz + light.axis.xyz * 0.02f;
    return light.positionRadius.xyz;
}
inline float lightMapStart(Light light) {
    return lightType(light) == LIGHT_RECT ? 0.0f : light.positionRadius.w * 1.01f;   // just outside the light's own sphere
}

kernel void lightMapKernel(constant Uniforms&                     u         [[buffer(0)]],
                           SCENE_ACCEL                            accel     [[buffer(1)]],
                           device const Light*                    lights    [[buffer(8)]],
                           texture2d_array<float, access::write>  lightMap  [[texture(0)]],
                           uint3 tid [[thread_position_in_grid]])
{
    uint size = lightMap.get_width();
    if (tid.x >= size || tid.y >= size || tid.z >= u.lightCount) return;
    Light light = lights[tid.z];
    float2 f = (float2(tid.xy) + 0.5f) / float(size) * 2.0f - 1.0f;
    if (lightType(light) == LIGHT_SUN) {
        float3 w = light.axis.xyz, t, b;
        tangentFrame(w, t, b);
        float R = light.params.w;
        float3 origin = light.params.xyz + w * (R * 1.05f) + (t * f.x + b * f.y) * R;
        float d = intersectDistance(makeRay(origin, -w, 0.0f, INFINITY), MASK_GEOMETRY, accel);
        lightMap.write(float4(isFar(d) ? FAR_DISTANCE : d), tid.xy, tid.z);
        return;
    }
    float3 dir = equalAreaOctDecode(f);
    float start = lightMapStart(light);
    float t = intersectDistance(makeRay(lightMapCenter(light) + dir * start, dir, 0.0f, INFINITY), MASK_GEOMETRY, accel);
    lightMap.write(float4(isFar(t) ? FAR_DISTANCE : start + t), tid.xy, tid.z);
}

// 2x2 PCF of "map depth >= depth - bias" around continuous texel coordinate tc.
inline float lightMapPCF(texture2d_array<float, access::read> lightMap, uint l, float2 tc, float depth, float bias) {
    uint size = lightMap.get_width();
    int2 base = int2(floor(tc));
    float2 f = tc - float2(base);
    float vis = 0.0f;
    for (int k = 0; k < 4; ++k) {
        int2 o = int2(k & 1, k >> 1);
        uint2 texel = uint2(clamp(base + o, int2(0), int2(size - 1)));
        float w = (o.x ? f.x : 1.0f - f.x) * (o.y ? f.y : 1.0f - f.y);
        vis += w * (lightMap.read(texel, l).r >= depth - bias ? 1.0f : 0.0f);
    }
    return vis;
}

// Visibility of light l (its map in slice l) from p, with a normal offset along ng against acne.
float lightMapVisibility(Light light, uint l, texture2d_array<float, access::read> lightMap, float3 p, float3 ng) {
    uint size = lightMap.get_width();
    if (lightType(light) == LIGHT_SUN) {
        float3 w = light.axis.xyz, t, b;
        tangentFrame(w, t, b);
        float R = light.params.w, texel = 2.0f * R / float(size);
        float3 q = p + ng * (1.5f * texel) - light.params.xyz;
        float2 tc = (float2(dot(q, t), dot(q, b)) / R * 0.5f + 0.5f) * float(size) - 0.5f;
        float depth = R * 1.05f - dot(q, w);
        return lightMapPCF(lightMap, l, tc, depth, 0.02f + texel);
    }
    // Normal offset of ~1.5 map texels at this distance (a 128^2 equal-area texel spans ~0.028 rad) avoids acne.
    float3 center = lightMapCenter(light);
    float texelScale = 128.0f / float(size);
    float3 q = p + ng * (length(center - p) * 0.04f * texelScale);
    float3 v = q - center;
    float dq = length(v);
    float2 tc = (equalAreaOctEncode(v / dq) * 0.5f + 0.5f) * float(size) - 0.5f;
    return lightMapPCF(lightMap, l, tc, dq, 0.02f + 0.01f * dq * texelScale);
}

// Direct light at a secondary hit from one light, shadowed by its light map (2x2 PCF), albedo divided out.
float3 lightIllumCachedOne(Light light, uint l, texture2d_array<float, access::read> lightMap, float3 p, float3 n, float3 ng,
                           thread const SceneData& s) {
    if (lightType(light) == LIGHT_SPHERE) {
        float3 center = light.positionRadius.xyz;
        float radius = light.positionRadius.w;
        float3 toLight = center - p;
        float dist2 = dot(toLight, toLight);
        float3 L = toLight * rsqrt(dist2);
        float cosTheta = dot(n, L);
        if (cosTheta <= 0.0f || dot(ng, L) <= 0.0f) return float3(0.0f);
        return light.color.rgb * (cosTheta * lightMapVisibility(light, l, lightMap, p, ng) / (M_PI_F * max(dist2, radius * radius)));
    }
    float3 unshadowed = lightUnshadowed(light, p, n, ng);
    if (all(unshadowed <= 0.0f)) return float3(0.0f);
    return unshadowed * (lightMapVisibility(light, l, lightMap, p, ng) * sunVisibilityScale(light, p, s));
}

// Direct light at a secondary hit from all lights, shadowed by the light maps, albedo divided out.
// n = shading normal, ng = geometric normal, both oriented toward the side being lit. Up to 8 lights are summed
// exactly; with more, CACHED_LIGHT_SAMPLES lights are picked by unshadowed luminance (one weighted reservoir each,
// seeded by `seed`) and only their maps are read, so the cost no longer grows with the light count's map reads.
float3 lightIllumCached(device const Light* lights, uint lightCount, texture2d_array<float, access::read> lightMap,
                        float3 p, float3 n, float3 ng, uint seed, uint flags, thread const SceneData& s) {
    float3 sum = float3(0.0f);
    if (lightCount <= 8 || flagOn(flags, FLAG_ALL_LIGHTS)) {
        for (uint l = 0; l < lightCount; ++l) sum += lightIllumCachedOne(lights[l], l, lightMap, p, n, ng, s);
        return sum;
    }
    float4 u;
    for (uint k = 0; k < 4; ++k) { seed = pcgHash(seed + k); u[k] = min(float(seed >> 8) * (1.0f / 16777216.0f), 0.99999f); }
    LightSubset ls = lightSubset(lightCount, float(pcgHash(seed + 7u) >> 8) * (1.0f / 16777216.0f));
    float total = 0.0f;
    uint picked[CACHED_LIGHT_SAMPLES] = { 0, 0, 0, 0 };
    float4 pickedWeight = float4(0.0f);
    for (uint j = 0; j < ls.count; ++j) {
        uint i = lightSubsetIndex(ls, j, lightCount);
        float w = luminance(lightUnshadowed(lights[i], p, n, ng));
        if (w <= 0.0f) continue;
        total += w;
        float q = w / total;
        for (uint k = 0; k < CACHED_LIGHT_SAMPLES; ++k) {
            if (u[k] < q) { picked[k] = i; pickedWeight[k] = w; u[k] /= q; }
            else u[k] = (u[k] - q) / (1.0f - q);
        }
    }
    if (total <= 0.0f) return sum;
    for (uint k = 0; k < CACHED_LIGHT_SAMPLES; ++k)
        sum += lightIllumCachedOne(lights[picked[k]], picked[k], lightMap, p, n, ng, s) * (total / pickedWeight[k]);
    return sum * (ls.scale / float(CACHED_LIGHT_SAMPLES));
}

// GI's direct light at a secondary hit: the light maps' cached visibility (no rays), or in scenes with many lights
// (LIGHT_TABLE, no light maps) one light sample picked by RIS from the light table, with one shadow ray.
inline float3 giLightIllum(device const Light* lights, constant Uniforms& u, texture2d_array<float, access::read> lightMap,
                           float3 p, float3 n, float3 ng, uint seed, SCENE_ACCEL accel, thread const SceneData& s) {
    if (LIGHT_TABLE) {
        // Clamped: cascades average few rays per frame, and their anti-lag takes a rare bright sample (a
        // surface right beside a bulb) for a change in the lighting, so it would stay as a coloured blotch.
        Rng r;
        r.state = seed;
        float3 e = sampleLightsRIS(lights, u.lightCount, u.lightTable, p, n, ng, 8, r, accel, s);
        float l = luminance(e);
        return l > 2.0f ? e * (2.0f / l) : e;
    }
    return lightIllumCached(lights, u.lightCount, lightMap, p, n, ng, seed, u.flags, s);
}

// View direction through screen position uv (0...1, y down), scaled so that its view depth is 1.
inline float3 viewDirection(constant Uniforms& u, float2 uv) {
    return u.camForward.xyz + (2.0f * uv.x - 1.0f) * u.camRight.w * u.camRight.xyz
                            + (1.0f - 2.0f * uv.y) * u.camUp.w * u.camUp.xyz;
}

// The primary ray's direction through pixel `tid` (jitter is zero unless upscaling is on).
inline float3 primaryDirection(constant Uniforms& u, uint2 tid) {
    return normalize(viewDirection(u, (float2(tid) + 0.5f + u.jitter.xy) / float2(u.width, u.height)));
}
