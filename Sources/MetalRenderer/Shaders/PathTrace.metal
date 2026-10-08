// ---------------------------------------------------------------------------------------------
// Reference "Path traced" (Settings: Reference; README "Reference rendering"): the whole picture from one kernel,
// as a debugging ground truth. Per pixel, paths from a jittered camera ray: Lambert + GGX (the frame's own material
// model, Surface.metal), window glass as a thin dielectric (reflected or passed through, tinted), emitters, the sky
// and the suns' discs, and the volumetric fog as a participating medium: free-flight sampling (delta tracking)
// through the fog's density field (Fog.metal fogMedium) inside the scene's sphere on every segment, scattering by
// its phase function, shadow rays dimmed through it (ratio tracking). Next-event estimation at every scattering point, each light
// sampled by solid angle; bounce rays also meet the analytic lights (but the suns, met on a miss), and the two are
// combined by multiple importance sampling (power heuristic). Up to PT_LIGHT_HITS lights each is weighed at every
// point and the rays test each one; above, the light tree (MegaLights.metal) draws them and the rays meet them at
// their visible shapes (the light-proxy map). Emissive-mesh lights split the work instead: next-event estimation
// lights the diffuse lobe, the specular lobe meets them. Samples are Owen-scrambled Sobol points per pixel
// (Sampling.metal) for the first bounces. Russian roulette after 3 bounces, no firefly clamp. Each frame's paths
// join a running mean (rgba32Float), which the renderer restarts when the picture would change.
// Liquids (LIQUID: Liquid.metal's material) as exact dielectrics: a path reflects off one with Fresnel's probability or
// refracts into it (total internal reflection turns it back), and inside absorbs along its way (Beer-Lambert); shadow
// rays go through them straight, (1 - Fresnel) at each crossing and the absorption inside (no caustics).
// Not here: refraction through thick glass (the panes are thin), the fog's haze (a realtime stand-in).
// ---------------------------------------------------------------------------------------------

// With up to this many lights each is weighed at every point and bounce rays test them one by one (Renderer
// .pathTraceLightHits); above, the light tree.
constant uint PT_LIGHT_HITS = LIGHT_CANDIDATES;

struct PathTraceParams {
    uint4 samples;   // x = paths in the mean so far, y = paths to add, z = bounces, w = light-tree nodes (0: none)
    uint4 config;    // x = PT_* flags, y = instances the light-proxy map covers, z = the average's seed (a new one
                     //   each time it starts over, so frames that each start over draw new samples)
    float4 bounds;   // the scene's sphere: the fog is inside it (the sun's and the sky's light is what reaches the scene)
};
static_assert(sizeof(PathTraceParams) == 48, "PathTraceParams: GPUPathTraceParams");
constant uint PT_SOBOL = 1;   // Owen-scrambled Sobol samples (else white noise)
constant uint PT_FOG   = 2;   // the fog's medium is there

// The light-proxy map's entries other than a light's index.
constant uint PT_GEOMETRY    = 0xFFFFFFFFu;
constant uint PT_CAMERA_ONLY = 0xFFFFFFFEu;   // a camera-only shape (maskLights) that is no light: rays pass through

// The fog: how far a ray that meets nothing goes through it, and the free-flight steps' cap.
constant float PT_FOG_FAR = 1e4f;
constant uint PT_FOG_STEPS = 1024;

inline float ptPowerHeuristic(float a, float b) {
    a *= a; b *= b;
    return a + b > 0.0f ? a / (a + b) : 0.0f;
}

// 1 - cos of the half angle of the cone a sphere of radius r subtends at distance d (stable for small cones).
inline float ptOneMinusCos(float r, float d) {
    float s2 = saturate(r * r / (d * d));
    return s2 / (1.0f + sqrt(1.0f - s2));
}
inline float ptOneMinusCosAngle(float theta) { float s = sin(0.5f * theta); return 2.0f * s * s; }

// Uniform direction in the cone around unit `axis` whose half angle has 1 - cos = oneMinusCos.
inline float3 ptSampleCone(float3 axis, float oneMinusCos, float2 r) {
    float cosT = 1.0f - r.x * oneMinusCos, sinT = sqrt(max(0.0f, 1.0f - cosT * cosT));
    float phi = 2.0f * M_PI_F * r.y;
    float3 t, b;
    tangentFrame(axis, t, b);
    return normalize(axis * cosT + (t * cos(phi) + b * sin(phi)) * sinT);
}

// ---------------------------------------------------------------------------------------------
// Samples: the first PT_SOBOL_BOUNCES bounces draw Owen-scrambled Sobol points, a pair of dimensions per use
// (dimension 0: the camera's; then PT_SLOTS per bounce), the rest white noise. The index is the path's in the mean.
// ---------------------------------------------------------------------------------------------

constant uint PT_SOBOL_BOUNCES = 6;
constant uint PT_SLOTS = 4;
constant uint PT_SLOT_PICK = 0;        // x = the light pick, y = the lobe
constant uint PT_SLOT_LIGHT = 1;       // the point on the light
constant uint PT_SLOT_DIRECTION = 2;   // the next direction (BSDF or phase function)
constant uint PT_SLOT_ROULETTE = 3;    // x = Russian roulette

struct PTSampler {
    uint index;     // the path's index in the pixel's mean
    uint seed;      // the pixel's
    bool sobol;
};

inline float2 ptRandom(thread const PTSampler& smp, uint dim, thread Rng& rng) {
    if (!smp.sobol || dim >= 1 + PT_SOBOL_BOUNCES * PT_SLOTS) return rng.next2();
    return owenSobol2(smp.index, smp.seed ^ pcgHash(dim * 0x9E3779B9u + 1u));
}
inline float2 ptRandom(thread const PTSampler& smp, uint bounce, uint slot, thread Rng& rng) {
    return ptRandom(smp, 1 + bounce * PT_SLOTS + slot, rng);
}

// ---------------------------------------------------------------------------------------------
// Lights: a sample toward a light, and a bounce ray meeting one. Radiance from each type's parameters (Types.metal
// Light): sphere and spot I / (pi r^2) (spots x their falloff toward the shaded point), rect its radiance, tube
// 2 I / (pi r length) (it emits what a sphere light of intensity I does), sun E / (its disc's solid angle), mesh
// its material's emission. lightUnshadowed (Lights.metal) is the same light integrated over the light.
// ---------------------------------------------------------------------------------------------

struct PTLightSample {
    float3 dir;      // from the shaded point toward the light
    float  dist;     // how far the shadow ray goes
    float3 Le;       // radiance toward the point (a point light: irradiance at normal incidence)
    float  pdf;      // solid angle (0: no sample; a point light: 1)
    bool   delta;    // a point light (radius 0): no ray meets it
    bool   mesh;     // an emissive-mesh light: at a surface it lights the diffuse lobe only
};

PTLightSample ptSampleLight(Light light, float3 p, float2 r, thread const SceneData& s, uint flags) {
    PTLightSample ls;
    ls.dir = float3(0.0f, 1.0f, 0.0f); ls.dist = 0.0f; ls.Le = float3(0.0f); ls.pdf = 0.0f; ls.delta = false; ls.mesh = false;
    uint type = lightType(light);
    float3 c = light.positionRadius.xyz;
    float radius = light.positionRadius.w;
    if (type == LIGHT_SUN) {
        float omc = ptOneMinusCosAngle(radius);
        ls.dir = ptSampleCone(light.axis.xyz, omc, r);
        ls.dist = PT_FOG_FAR;
        // The disc's radiance as a bounce ray that meets it sees it (limb darkening; the clouds come from the shadow
        // map at the point, sunVisibilityScale, for both).
        ls.Le = sunDisc(light, ls.dir, flags, 1.0f);
        ls.pdf = 1.0f / (2.0f * M_PI_F * max(omc, 1e-9f));
        return ls;
    }
    if (type == LIGHT_SPHERE || type == LIGHT_SPOT) {
        float3 w = c - p;
        float d2 = dot(w, w), d = sqrt(d2);
        if (d <= max(radius, 1e-6f)) return ls;   // inside the light
        float3 axis = w / d;
        float spot = type == LIGHT_SPOT ? spotFactor(light, -axis) : 1.0f;
        if (spot <= 0.0f) return ls;
        if (radius < 1e-4f) {
            ls.delta = true; ls.dir = axis; ls.dist = d; ls.Le = light.color.rgb * (spot / d2); ls.pdf = 1.0f;
            return ls;
        }
        float omc = ptOneMinusCos(radius, d);
        ls.dir = ptSampleCone(axis, omc, r);
        float b = dot(ls.dir, w), disc = b * b - (d2 - radius * radius);
        ls.dist = b - sqrt(max(disc, 0.0f));
        ls.Le = light.color.rgb * (spot / (M_PI_F * radius * radius));
        ls.pdf = 1.0f / (2.0f * M_PI_F * max(omc, 1e-9f));
        return ls;
    }
    if (type == LIGHT_RECT) {
        float3 N = light.axis.xyz;
        if (dot(p - c, N) <= 0.0f) return ls;   // behind the emitting side
        float3 U = light.params.xyz, V = normalize(cross(N, U)) * light.params.w;
        float area = 4.0f * length(U) * light.params.w;
        float3 w = c + U * (2.0f * r.x - 1.0f) + V * (2.0f * r.y - 1.0f) - p;
        float d2 = dot(w, w), d = sqrt(d2);
        ls.dir = w / d;
        float cosL = -dot(N, ls.dir);
        if (cosL <= 0.0f || area <= 0.0f) return ls;
        ls.dist = d; ls.Le = light.color.rgb; ls.pdf = d2 / (area * cosL);
        return ls;
    }
    if (type == LIGHT_TUBE) {
        float3 ax = light.axis.xyz;
        float halfLen = length(ax), rr = max(radius, 1e-3f);
        if (halfLen <= 0.0f) return ls;
        float3 t, b;
        tangentFrame(ax / halfLen, t, b);
        float phi = 2.0f * M_PI_F * r.y;
        float3 radial = t * cos(phi) + b * sin(phi);
        float3 w = c + ax * (2.0f * r.x - 1.0f) + radial * rr - p;
        float d2 = dot(w, w), d = sqrt(d2);
        ls.dir = w / d;
        float cosL = -dot(radial, ls.dir);
        if (cosL <= 0.0f) return ls;
        float len = 2.0f * halfLen;
        ls.dist = d;
        ls.Le = light.color.rgb * (2.0f / (M_PI_F * rr * len));
        ls.pdf = d2 / (2.0f * M_PI_F * rr * len * cosL);
        return ls;
    }
    if (type == LIGHT_MESH) {
        MeshLightPoint mp = sampleMeshLightPoint(light, r, s);
        if (!mp.valid) return ls;
        float3 w = mp.x - p;
        float d2 = dot(w, w), d = sqrt(d2);
        if (d <= 0.0f) return ls;
        ls.dir = w / d;
        float cosL = abs(dot(mp.cr, ls.dir)) / mp.area2;   // emission is two-sided
        if (cosL <= 0.0f) return ls;
        ls.dist = 0.99f * d;   // short of the emitter (as sampleMeshLight): one traced coarser doesn't shadow itself
        ls.Le = meshLightPointEmission(mp, s);
        ls.pdf = d2 / cosL * (mp.prob / (0.5f * mp.area2));
        ls.mesh = true;
        return ls;
    }
    return ls;
}

// A ray from `o` along `dir` meeting an analytic light (sphere, spot, rect, tube) before tmax: its distance, the
// radiance it sees and the solid-angle pdf ptSampleLight has for that direction from `from` (the last scattering
// point, which the ray left from or passed window panes since).
bool ptHitLight(Light light, float3 o, float3 dir, float tmax, float3 from, thread float& t, thread float3& Le, thread float& pdf) {
    uint type = lightType(light);
    float3 c = light.positionRadius.xyz;
    float radius = light.positionRadius.w;
    if (type == LIGHT_SPHERE || type == LIGHT_SPOT) {
        if (radius < 1e-4f) return false;
        float3 oc = o - c;
        float b = dot(oc, dir), cc = dot(oc, oc) - radius * radius;
        if (cc <= 0.0f) return false;
        float disc = b * b - cc;
        if (disc < 0.0f) return false;
        t = -b - sqrt(disc);
        if (t <= 0.0f || t >= tmax) return false;
        float3 w = c - from;
        float d = length(w);
        float spot = type == LIGHT_SPOT ? spotFactor(light, -w / d) : 1.0f;
        Le = light.color.rgb * (spot / (M_PI_F * radius * radius));
        pdf = 1.0f / (2.0f * M_PI_F * max(ptOneMinusCos(radius, d), 1e-9f));
        return spot > 0.0f;
    }
    if (type == LIGHT_RECT) {
        float3 N = light.axis.xyz;
        float denom = dot(dir, N);
        if (denom >= 0.0f || dot(o - c, N) <= 0.0f) return false;   // only its emitting side, from in front
        t = dot(c - o, N) / denom;
        if (t <= 0.0f || t >= tmax) return false;
        float3 U = light.params.xyz;
        float hw = length(U), hh = light.params.w;
        float3 x = o + dir * t, q = x - c;
        if (abs(dot(q, U / hw)) > hw || abs(dot(q, normalize(cross(N, U)))) > hh) return false;
        float d2 = distance_squared(x, from);
        Le = light.color.rgb;
        pdf = d2 / (4.0f * hw * hh * -denom);
        return true;
    }
    if (type == LIGHT_TUBE) {
        float3 ax = light.axis.xyz;
        float halfLen = length(ax), rr = max(radius, 1e-3f);
        if (halfLen <= 0.0f) return false;
        float3 a = ax / halfLen, oc = o - c;
        float3 dp = dir - a * dot(dir, a), op = oc - a * dot(oc, a);
        float A = dot(dp, dp), B = dot(dp, op), C = dot(op, op) - rr * rr;
        if (C <= 0.0f || A <= 1e-12f) return false;   // inside it, or along its axis
        float disc = B * B - A * C;
        if (disc < 0.0f) return false;
        t = (-B - sqrt(disc)) / A;
        if (t <= 0.0f || t >= tmax || abs(dot(oc + dir * t, a)) > halfLen) return false;
        float3 radial = normalize(op + dp * t);
        float cosL = -dot(radial, dir);
        if (cosL <= 0.0f) return false;
        float len = 2.0f * halfLen;
        float d2 = distance_squared(o + dir * t, from);
        Le = light.color.rgb * (2.0f / (M_PI_F * rr * len));
        pdf = d2 / (2.0f * M_PI_F * rr * len * cosL);
        return true;
    }
    return false;
}

// Many lights: whether a bounce ray from p along dir would meet light j (within dist), traced as the kernel's rays
// are: stopped by geometry, meeting j at its visible shape, passing through camera-only shapes and the shapes of
// lights it misses on the way. A light sample whose direction a bounce ray can't find that way (between a coarse
// shape's facets and the light's sphere, or a shape set into a wall) gets the whole of the MIS weight.
bool ptProxyReaches(float3 p, float3 dir, float dist, uint j, SCENE_ACCEL accel, device const uint* proxies, uint proxyCount,
                    device const Light* lights) {
    float3 o = p;
    for (uint step = 0; step < 4; ++step) {
        Hit hit = intersectClosest(makeRay(o, dir, 0.0f, dist * 1.05f + RAY_EPSILON), MASK_GEOMETRY | MASK_LIGHTS, accel);
        if (!hit.hit) return false;
        uint k = hit.instance < proxyCount ? proxies[hit.instance] : PT_GEOMETRY;
        if (k == j) return true;
        if (k == PT_GEOMETRY) return false;
        float tl, pdf;
        float3 Le;
        if (k != PT_CAMERA_ONLY && ptHitLight(lights[k], o, dir, FAR_DISTANCE, p, tl, Le, pdf)) return false;
        float t = hit.distance + RAY_EPSILON;
        o += dir * t;
        dist -= t;
        if (dist <= 0.0f) return false;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Which light a point picks. A point is on a surface (its normals weigh the lights: lightUnshadowed) or in the fog
// (no normal: lightVolumeWeight). Up to PT_LIGHT_HITS lights, each by its weight; with the light tree, a sun by the
// suns' share of the light (the tree has no suns) or a light down the tree. ptPickPdf gives the same probability
// back for the light a bounce ray met, for its MIS weight.
// ---------------------------------------------------------------------------------------------

struct PTVertex {
    float3 p, n, ng;   // ng: offset along it already (surfaces)
    bool   volume;
};

struct PTLights {
    device const Light*         lights;
    uint                        count;
    device const LightTreeNode* tree;
    uint                        nodes;    // 0: no tree
    uint                        suns;     // the light table's (at most 2), at sun0, sun1
    uint                        sun0, sun1;
};

inline float ptLightWeight(Light light, thread const PTVertex& x) {
    return x.volume ? lightVolumeWeight(light, x.p) : luminance(lightUnshadowed(light, x.p, x.n, x.ng));
}

inline ShadingPoint ptShadingPoint(thread const PTVertex& x) {
    ShadingPoint sp;
    sp.p = x.p; sp.n = x.n; sp.ng = x.ng; sp.v = x.n;
    sp.albedo = float3(1.0f); sp.f0 = float3(0.0f); sp.roughness = 1.0f; sp.specular = false;
    return sp;
}

// The tree's share against the suns' at x: the suns' weights and the probability of drawing a sun.
inline float ptSunShare(thread const PTLights& L, thread const PTVertex& x, thread const ShadingPoint& sp, thread float2& ws) {
    ws = float2(L.suns > 0 ? ptLightWeight(L.lights[L.sun0], x) : 0.0f, L.suns > 1 ? ptLightWeight(L.lights[L.sun1], x) : 0.0f);
    MegaLightsOwned none = { nullptr, 0, 0.0f, false };
    float wTree = lightTreeWeight(L.tree, 0, sp, L.lights, none, x.volume);
    float wSun = ws.x + ws.y;
    return wSun + wTree > 0.0f ? wSun / (wSun + wTree) : 0.0f;
}

// One light for x and its probability (L.count: none).
uint ptPickLight(thread const PTLights& L, thread const PTVertex& x, float u, float uSubset, thread float& pdf) {
    pdf = 0.0f;
    if (L.nodes > 0) {
        ShadingPoint sp = ptShadingPoint(x);
        float2 ws;
        float pSun = ptSunShare(L, x, sp, ws);
        if (u < pSun) {
            float shareFirst = ws.x / (ws.x + ws.y);
            u /= pSun;
            bool first = u < shareFirst;
            pdf = pSun * (first ? shareFirst : 1.0f - shareFirst);
            return first ? L.sun0 : L.sun1;
        }
        u = min((u - pSun) / (1.0f - pSun), 0.99999f);
        MegaLightsOwned none = { nullptr, 0, 0.0f, false };
        float pTree;
        uint l = sampleLightTree(L.tree, L.nodes, u, sp, L.lights, none, pTree, x.volume);
        if (l == ELEMENT_NONE) return L.count;
        pdf = (1.0f - pSun) * pTree;
        return l;
    }
    if (L.count <= PT_LIGHT_HITS) {
        StreamPick pick = streamPick(u);
        uint picked = L.count;
        float wPicked = 0.0f;
        for (uint i = 0; i < L.count; ++i) {
            float w = ptLightWeight(L.lights[i], x);
            if (w <= 0.0f) continue;
            if (pick.offer(w)) { picked = i; wPicked = w; }
        }
        pdf = pick.total > 0.0f ? wPicked / pick.total : 0.0f;
        return picked;
    }
    // Many lights without the tree: a surface picks among a subset (pickLight), the fog uniformly.
    if (x.volume) {
        pdf = 1.0f / float(L.count);
        return min(uint(u * float(L.count)), L.count - 1);
    }
    return pickLight(L.lights, L.count, x.p, x.n, x.ng, u, uSubset, pdf);
}

// ptPickLight's probability of light j at x (with the tree, or up to PT_LIGHT_HITS lights).
float ptPickPdf(thread const PTLights& L, thread const PTVertex& x, uint j) {
    if (L.nodes > 0) {
        ShadingPoint sp = ptShadingPoint(x);
        float2 ws;
        float pSun = ptSunShare(L, x, sp, ws);
        if (L.suns > 0 && j == L.sun0) return ws.x > 0.0f ? pSun * ws.x / (ws.x + ws.y) : 0.0f;
        if (L.suns > 1 && j == L.sun1) return ws.y > 0.0f ? pSun * ws.y / (ws.x + ws.y) : 0.0f;
        MegaLightsOwned none = { nullptr, 0, 0.0f, false };
        return (1.0f - pSun) * lightTreePdf(L.tree, L.nodes, j, sp, L.lights, none, x.volume);
    }
    float total = 0.0f, wj = 0.0f;
    for (uint i = 0; i < L.count; ++i) {
        float w = ptLightWeight(L.lights[i], x);
        total += w;
        if (i == j) wj = w;
    }
    return total > 0.0f ? wj / total : 0.0f;
}

// ---------------------------------------------------------------------------------------------
// The fog as a participating medium: Fog.metal's density field (height fog, noise, local volumes), its albedo and
// its Henyey-Greenstein phase function, on every segment of every path, without the realtime fog's far cutoff.
// ---------------------------------------------------------------------------------------------

struct PTFog {
    constant FogParams* f;
    texture3d<float>    noise;
    float4              bounds;   // the scene's sphere, which holds the fog
};

// Where the fog is along o + d t, t in [0, tMax] (x to y), and a bound on its extinction there (z): inside the
// scene's sphere, the height fog to where its density has fallen 1e4 times (going up), the volumes to where the ray
// leaves their bounding spheres. The realtime fog dims the sun only inside the same sphere (sunFogDistance).
float3 ptFogSegment(thread const PTFog& fog, float3 o, float3 d, float tMax) {
    constant FogParams& f = *fog.f;
    float3 qs = o - fog.bounds.xyz;
    float bs = dot(qs, d), cs = dot(qs, qs) - fog.bounds.w * fog.bounds.w, ds = bs * bs - cs;
    if (ds <= 0.0f) return float3(0.0f);
    float tStart = max(-bs - sqrt(ds), 0.0f);
    tMax = min(tMax, -bs + sqrt(ds));
    if (tMax <= tStart) return float3(0.0f);
    float tEnd = 0.0f, bound = 0.0f;
    // Noise multiplies the density by at most 1 + 1.5 x its amount (fogNoiseFactor, noise in [0, 1]).
    if (f.medium.x > 0.0f) {
        float hEnd = tMax;
        if (d.y > 1e-4f && f.medium.y > 1e-5f) hEnd = clamp((f.medium.z + 9.21f / f.medium.y - o.y) / d.y, 0.0f, tMax);
        if (hEnd > 0.0f) {
            float yMin = min(o.y, o.y + d.y * hEnd);
            bound += f.medium.x * exp(-f.medium.y * max(yMin - f.medium.z, 0.0f)) * (1.0f + 1.5f * abs(f.noise.x));
            tEnd = hEnd;
        }
    }
    for (uint i = 0; i < f.counts.z; ++i) {
        FogVolume v = f.volumes[i];
        float r = v.centerShape.w < 0.5f ? length(v.extentDensity.xyz) : v.extentDensity.x;
        float3 q = o - v.centerShape.xyz;
        float b = dot(q, d), disc = b * b - (dot(q, q) - r * r);
        if (disc <= 0.0f) continue;
        float tOut = -b + sqrt(disc);
        if (tOut <= tStart || -b - sqrt(disc) >= tMax) continue;
        bound += v.extentDensity.w * (1.0f + 1.5f * abs(v.params.x));
        tEnd = max(tEnd, min(tOut, tMax));
    }
    return float3(tStart, tEnd, bound);
}

// Free flight from o along d (delta tracking): the distance to the first real collision before tMax, with the
// medium there, or FAR_DISTANCE if the ray gets through.
float ptFreeFlight(thread const PTFog& fog, float3 o, float3 d, float tMax, thread Rng& rng, thread float4& medium) {
    float3 seg = ptFogSegment(fog, o, d, tMax);
    if (seg.y <= seg.x || seg.z <= 0.0f) return FAR_DISTANCE;
    float t = seg.x;
    for (uint i = 0; i < PT_FOG_STEPS; ++i) {
        t -= log(1.0f - rng.next()) / seg.z;
        if (t >= seg.y) return FAR_DISTANCE;
        float3 p = o + d * t;
        float4 m = fogMedium(p, *fog.f, fogNoise(fog.noise, p, *fog.f));
        if (rng.next() * seg.z < m.w) { medium = m; return t; }
    }
    return FAR_DISTANCE;
}

// The fog's transmittance along o + d t, t in [0, tMax] (ratio tracking; Russian roulette once it is low).
float ptFogTransmittance(thread const PTFog& fog, float3 o, float3 d, float tMax, thread Rng& rng) {
    float3 seg = ptFogSegment(fog, o, d, tMax);
    if (seg.y <= seg.x || seg.z <= 0.0f) return 1.0f;
    float T = 1.0f, t = seg.x;
    for (uint i = 0; i < PT_FOG_STEPS; ++i) {
        t -= log(1.0f - rng.next()) / seg.z;
        if (t >= seg.y) break;
        float3 p = o + d * t;
        T *= max(1.0f - fogMedium(p, *fog.f, fogNoise(fog.noise, p, *fog.f)).w / seg.z, 0.0f);
        if (T < 0.1f) {
            if (rng.next() < 0.5f) return 0.0f;
            T *= 2.0f;
        }
    }
    return T;
}

// A direction scattered by the Henyey-Greenstein phase function around the travel direction d (pdf: phaseHG of
// dot(result, d)).
inline float3 ptSampleHG(float3 d, float g, float2 r) {
    float cosT;
    if (abs(g) < 1e-3f) {
        cosT = 1.0f - 2.0f * r.x;
    } else {
        float s = (1.0f - g * g) / (1.0f - g + 2.0f * g * r.x);
        cosT = (1.0f + g * g - s * s) / (2.0f * g);
    }
    cosT = clamp(cosT, -1.0f, 1.0f);
    float sinT = sqrt(max(0.0f, 1.0f - cosT * cosT)), phi = 2.0f * M_PI_F * r.y;
    float3 t, b;
    tangentFrame(d, t, b);
    return normalize(d * cosT + (t * cos(phi) + b * sin(phi)) * sinT);
}

// What gets from `from` to `to`: nothing behind geometry, else through the window panes on the way (up to 4)
// (1 - Fresnel) x tint each, and through the fog.
float3 ptTransmittance(float3 from, float3 to, SCENE_ACCEL accel, thread const SceneData& s, bool fogOn,
                       thread const PTFog& fog, thread Rng& rng) {
    if (!isVisible(from, to, accel)) return float3(0.0f);
    float3 d = to - from;
    float dist = length(d);
    d /= dist;
    float3 T = float3(1.0f);
    if (GLASS) {
        float reach = dist;
        float3 o = from;
        for (uint pane = 0; pane < 4 && reach > 0.0f; ++pane) {
            Surface g = traceSurface(makeRay(o, d, 0.0f, reach), MASK_GLASS, accel, s, GI_RAY_SPREAD);
            if (!g.hit) break;
            float fresnel = 0.04f + 0.96f * pow(1.0f - saturate(abs(dot(d, g.normal))), 5.0f);
            T *= (1.0f - fresnel) * g.albedo;
            reach -= distance(g.position, o) + RAY_EPSILON;
            o = g.position + d * RAY_EPSILON;
        }
    }
    if (LIQUID) {
        // Each liquid's surface on the way: Fresnel's share kept out, and the absorption over the part inside it (up
        // to a crossing that leaves it: its normal faces along the ray).
        float reach = dist;
        float3 o = from;
        for (uint crossing = 0; crossing < 8 && reach > 0.0f && any(T > 0.0f); ++crossing) {
            Surface w = traceSurface(makeRay(o, d, 0.0f, reach), MASK_LIQUID, accel, s, GI_RAY_SPREAD);
            if (!w.hit) break;
            float roughness;
            float4 m = liquidMaterial(s, w.instanceId, roughness);
            float3 n = normalize(w.normal);
            float along = distance(w.position, o);
            bool leaving = dot(d, n) > 0.0f;
            if (leaving) T *= exp(-m.rgb * along);
            T *= 1.0f - liquidFresnel(abs(dot(d, n)), leaving ? m.a : 1.0f / m.a);
            reach -= along + RAY_EPSILON;
            o = w.position + d * RAY_EPSILON;
        }
    }
    if (fogOn && any(T > 0.0f)) T *= ptFogTransmittance(fog, from, d, dist, rng);
    return T;
}

// ---------------------------------------------------------------------------------------------
// The material: Lambert (albedo / pi, metals' already taken out) + GGX (F0, F90 = specular weight, alpha =
// roughness^2), as the frame's passes shade it. A sample picks a lobe by its share of the albedo.
// ---------------------------------------------------------------------------------------------

struct PTMaterial {
    float3 albedo;
    float3 f0;
    float  f90;
    float  a;       // GGX alpha
    float  pSpec;   // probability of sampling the specular lobe (0: diffuse only)
};

inline PTMaterial ptMaterial(thread const Surface& h, float NoV, bool specular) {
    PTMaterial m;
    float roughness = max(h.roughness, MIN_ROUGHNESS);
    m.albedo = h.albedo; m.f0 = h.f0; m.f90 = h.specular; m.a = roughness * roughness; m.pSpec = 0.0f;
    if (specular && h.specular > 0.0f && !h.backlit) {   // (a leaf lit from behind: the light through it is diffuse)
        float ls = luminance(specularAlbedo(m.f0, m.f90, roughness, NoV)), ld = luminance(m.albedo);
        m.pSpec = ls + ld > 0.0f ? ls / (ls + ld) : 0.0f;
    }
    return m;
}

// The two lobes times NoL toward l, and the pdf of sampling l.
inline void ptEval(thread const PTMaterial& m, float3 n, float3 v, float3 l, thread float3& fd, thread float3& fs, thread float& pdf) {
    float NoL = dot(n, l);
    fd = float3(0.0f); fs = float3(0.0f); pdf = 0.0f;
    if (NoL <= 0.0f) return;
    fd = m.albedo * (NoL / M_PI_F);
    pdf = (1.0f - m.pSpec) * NoL / M_PI_F;
    if (m.pSpec > 0.0f) {
        float NoV = max(dot(n, v), 1e-4f);
        float3 h = normalize(v + l);
        float NoH = saturate(dot(n, h)), VoH = saturate(dot(v, h));
        float D = ggxD(NoH, m.a), a2 = m.a * m.a;
        fs = D * smithVisibility(NoV, NoL, m.a) * schlick(m.f0, m.f90, VoH) * NoL;
        float G1 = 2.0f * NoV / (NoV + sqrt(a2 + (1.0f - a2) * NoV * NoV));
        pdf += m.pSpec * G1 * D / (4.0f * NoV);   // visible normals, reflected
    }
}

// ---------------------------------------------------------------------------------------------
// The kernel.
// ---------------------------------------------------------------------------------------------

kernel void pathTraceKernel(constant Uniforms&               u          [[buffer(0)]],
                            SCENE_ACCEL                      accel      [[buffer(1)]],
                            device const float3*             positions  [[buffer(2)]],
                            device const float3*             normals    [[buffer(3)]],
                            device const uint*               indices    [[buffer(4)]],
                            device const MeshData*           meshes     [[buffer(5)]],
                            device const InstanceData*       instances  [[buffer(6)]],
                            constant SceneShading&           shading    [[buffer(7)]],
                            device const Light*              lights     [[buffer(8)]],
                            constant FogParams&              fogParams  [[buffer(9)]],
                            device const RegirReservoir*     regirGrid  [[buffer(11)]],
                            constant RegirParams&            regir      [[buffer(12)]],
                            constant PathTraceParams&        params     [[buffer(13)]],
                            device const uint*               proxies    [[buffer(14)]],   // the light-proxy map
                            device const LightTreeNode*      tree       [[buffer(15)]],   // with params.samples.w nodes
                            texture2d<float, access::read_write> accum  [[texture(0)]],
                            texture3d<float>                 fogNoiseTex [[texture(1)]],
                            uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    bool specular = flagOn(u.flags, FLAG_SPECULAR);
    bool fogOn = (params.config.x & PT_FOG) != 0 && (fogParams.counts.w & FOG_ENABLED) != 0;
    PTFog fog = { &fogParams, fogNoiseTex, params.bounds };
    float g = fogParams.medium.w;
    PTLights L = { lights, u.lightCount, tree, params.samples.w, min(u.lightTable.y, 2u), u.lightTable.z, u.lightTable.w };
    bool treeLights = L.nodes > 0;                                  // bounce rays meet the lights' shapes
    bool fewLights = !treeLights && u.lightCount <= PT_LIGHT_HITS;  // bounce rays test every analytic light
    bool lightHits = treeLights || fewLights;                       // ...else only next-event estimation finds them
    uint analytic = u.lightGroupEnd.w;
    float pixelSpread = 2.0f * u.camUp.w / float(u.height);
    // A rotating eighth of the pixels tells the texture streamer which mip levels they need (as traceKernel's do).
    bool record = ((tid.x + 3u * tid.y + u.frameIndex) & 7u) == 0u;
    uint pixelSeed = pcgHash(tid.x + pcgHash(tid.y ^ pcgHash(params.config.z ^ 0x3C6EF372u)));

    float3 sum = float3(0.0f);
    for (uint k = 0; k < params.samples.y; ++k) {
        uint index = params.samples.x + k;
        PTSampler smp = { index, pixelSeed, (params.config.x & PT_SOBOL) != 0 };
        Rng rng;
        rng.state = pcgHash(pixelSeed ^ pcgHash(index ^ 0x6A09E667u));
        float3 L_ = float3(0.0f), throughput = float3(1.0f);
        float3 emitterThroughput = float3(1.0f);   // what an emissive-mesh light met next counts with (its specular share)
        float3 dir = normalize(viewDirection(u, (float2(tid) + ptRandom(smp, 0, rng)) / float2(u.width, u.height)));
        float3 origin = u.camPos.xyz;
        // The last scattering point, for the MIS weight of a light the next ray meets.
        PTVertex prev = { origin, float3(0.0f), float3(0.0f), false };
        float prevPdf = 0.0f;
        bool prevDelta = true;     // camera ray, or a mirror reflection off glass: no light was sampled for it
        bool cameraRay = true;     // meets the lights' shapes and camera-only geometry, as the frame's camera rays do
        float spread = pixelSpread;
        uint bounce = 0;
        float4 medium = float4(0.0f);   // LIQUID: the liquid the path is in (absorption, index), 0: none

        for (uint event = 0; event < 2 * params.samples.z + 16u; ++event) {
            uint mask = (cameraRay ? MASK_ALL & ~MASK_GLASS : treeLights ? MASK_GEOMETRY | MASK_LIGHTS : MASK_GEOMETRY) & ~MASK_LIQUID;
            Ray ray = makeRay(origin, dir, 0.0f, INFINITY);
            Hit hit = intersectClosest(ray, mask, accel);
            Surface h = surfaceFromHit(hit, ray, accel, s, spread, record && event == 0);
            float tNear = h.hit ? distance(origin, h.position) : FAR_DISTANCE;
            // What the ray meets first: 0 the sky, 1 a surface, 2 a light, 3 a pane, 4 a shape to pass through,
            // 5 a liquid's surface.
            uint kind = h.hit ? 1u : 0u;
            uint metLight = 0;
            float3 metLe = float3(0.0f);
            float metPdf = 0.0f;
            // Many lights: a light's visible shape, met by a bounce ray, stands for the light (or is passed through).
            if (treeLights && !cameraRay && h.hit) {
                uint j = hit.instance < params.config.y ? proxies[hit.instance] : PT_GEOMETRY;
                if (j != PT_GEOMETRY) {
                    float tl;
                    if (j != PT_CAMERA_ONLY && ptHitLight(lights[j], origin, dir, FAR_DISTANCE, prev.p, tl, metLe, metPdf)) {
                        kind = 2u; metLight = j; tNear = tl;
                    } else {
                        kind = 4u;
                    }
                }
            }
            // A window pane in front of it.
            Surface pane;
            pane.hit = false;
            if (GLASS) {
                pane = traceSurface(makeRay(origin, dir, 0.0f, tNear), MASK_GLASS, accel, s, spread);
                if (pane.hit) { tNear = distance(origin, pane.position); kind = 3u; }
            }
            // A liquid's surface in front of it.
            Surface wet;
            wet.hit = false;
            if (LIQUID) {
                wet = traceSurface(makeRay(origin, dir, 0.0f, tNear), MASK_LIQUID, accel, s, spread);
                if (wet.hit) { tNear = distance(origin, wet.position); kind = 5u; }
            }
            // Few lights: an analytic light in front of all that.
            if (fewLights && !cameraRay) {
                for (uint j = 0; j < analytic; ++j) {
                    float tl, pdfL;
                    float3 Le;
                    if (ptHitLight(lights[j], origin, dir, tNear, prev.p, tl, Le, pdfL)) {
                        tNear = tl; kind = 2u; metLight = j; metLe = Le; metPdf = pdfL;
                    }
                }
            }
            // The particles on the way (PARTICLES): the emitters' light up to the first that stops the path, and that
            // one: an emissive one ends it, a lit one is a scattering point (isotropic, as the fog's).
            ParticleScatter particle;
            particle.hit = false;
            if (PARTICLES) {
                particle = particleScatter(origin, dir, isFar(tNear) ? FAR_DISTANCE : tNear, rng.nextUint(), accel);
                L_ += throughput * particle.emission;
                if (particle.hit) {
                    tNear = particle.t;
                    kind = 6u;
                    if (particle.emissive) break;
                }
            }
            // The fog on the way: a collision there is a scattering point in the medium.
            if (fogOn) {
                float4 m;
                float tc = ptFreeFlight(fog, origin, dir, isFar(tNear) ? PT_FOG_FAR : tNear, rng, m);
                if (!isFar(tc)) {
                    float3 p = origin + dir * tc;
                    throughput *= m.rgb / m.w;   // the scattering albedo
                    PTVertex x = { p, float3(0.0f), float3(0.0f), true };
                    float2 rPick = ptRandom(smp, bounce, PT_SLOT_PICK, rng);
                    float2 rLight = ptRandom(smp, bounce, PT_SLOT_LIGHT, rng);
                    if (u.lightCount > 0) {
                        float pick;
                        uint li = ptPickLight(L, x, rPick.x, rng.next(), pick);
                        if (li < u.lightCount && pick > 0.0f) {
                            PTLightSample ls = ptSampleLight(lights[li], p, rLight, s, u.flags);
                            if (ls.pdf > 0.0f) {
                                float phase = phaseHG(dot(ls.dir, dir), g);
                                float3 T = ptTransmittance(p, p + ls.dir * ls.dist, accel, s, fogOn, fog, rng);
                                if (any(T > 0.0f)) {
                                    float lightPdf = pick * ls.pdf;
                                    bool found = lightHits && !ls.delta && !ls.mesh && (!treeLights || lightType(lights[li]) == LIGHT_SUN
                                        || ptProxyReaches(p, ls.dir, ls.dist, li, accel, proxies, params.config.y, lights));
                                    float w = found ? ptPowerHeuristic(lightPdf, phase) : 1.0f;
                                    L_ += throughput * ls.Le * T * (phase * sunVisibilityScale(lights[li], p, s) * w / lightPdf);
                                }
                            }
                        }
                    }
                    if (bounce >= params.samples.z) break;
                    float3 l = ptSampleHG(dir, g, ptRandom(smp, bounce, PT_SLOT_DIRECTION, rng));
                    prev = x;
                    prevPdf = phaseHG(dot(l, dir), g);
                    prevDelta = false;
                    cameraRay = false;
                    emitterThroughput = float3(0.0f);   // next-event estimation lit the whole phase function
                    origin = p;
                    dir = l;
                    spread = GI_RAY_SPREAD;
                    ++bounce;
                    if (bounce >= 3) {
                        float q = min(max(throughput.x, max(throughput.y, throughput.z)), 0.95f);
                        if (ptRandom(smp, bounce - 1, PT_SLOT_ROULETTE, rng).x >= q) break;
                        throughput /= q;
                    }
                    continue;
                }
            }

            if (kind == 6u) {
                // A lit particle: next-event estimation with the isotropic phase, then on in a random direction.
                float3 p = origin + dir * tNear;
                throughput *= particle.albedo;
                PTVertex x = { p, float3(0.0f), float3(0.0f), true };
                float2 rPick = ptRandom(smp, bounce, PT_SLOT_PICK, rng);
                float2 rLight = ptRandom(smp, bounce, PT_SLOT_LIGHT, rng);
                const float phase = 1.0f / (4.0f * M_PI_F);
                if (u.lightCount > 0) {
                    float pick;
                    uint li = ptPickLight(L, x, rPick.x, rng.next(), pick);
                    if (li < u.lightCount && pick > 0.0f) {
                        PTLightSample ls = ptSampleLight(lights[li], p, rLight, s, u.flags);
                        if (ls.pdf > 0.0f) {
                            float3 T = ptTransmittance(p, p + ls.dir * ls.dist, accel, s, fogOn, fog, rng);
                            if (any(T > 0.0f)) {
                                float lightPdf = pick * ls.pdf;
                                bool found = lightHits && !ls.delta && !ls.mesh && (!treeLights || lightType(lights[li]) == LIGHT_SUN
                                    || ptProxyReaches(p, ls.dir, ls.dist, li, accel, proxies, params.config.y, lights));
                                float w = found ? ptPowerHeuristic(lightPdf, phase) : 1.0f;
                                L_ += throughput * ls.Le * T * (phase * sunVisibilityScale(lights[li], p, s) * w / lightPdf);
                            }
                        }
                    }
                }
                // The sky's light, which the real-time light pass gives the particles too (skyAmbient), is found by the
                // bounce that leaves.
                if (bounce >= params.samples.z) break;
                float3 l = ptSampleHG(dir, 0.0f, ptRandom(smp, bounce, PT_SLOT_DIRECTION, rng));
                prev = x;
                prevPdf = phase;
                prevDelta = false;
                cameraRay = false;
                emitterThroughput = float3(0.0f);
                origin = p;
                dir = l;
                spread = GI_RAY_SPREAD;
                ++bounce;
                if (bounce >= 3) {
                    float q = min(max(throughput.x, max(throughput.y, throughput.z)), 0.95f);
                    if (ptRandom(smp, bounce - 1, PT_SLOT_ROULETTE, rng).x >= q) break;
                    throughput /= q;
                }
                continue;
            }
            // Inside a liquid, what it absorbed on the way here.
            if (LIQUID && medium.a > 0.0f) {
                float3 kept = exp(-medium.rgb * (isFar(tNear) ? 1e3f : tNear));
                throughput *= kept;
                emitterThroughput *= kept;
            }
            if (kind == 5u) {
                // A dielectric: reflected with Fresnel's probability (all of it past the critical angle), else bent
                // through, into the liquid or out of it.
                float roughness;
                float4 m = liquidMaterial(s, wet.instanceId, roughness);
                float3 n = normalize(wet.normal);
                bool entering = dot(dir, n) < 0.0f;
                float3 facing = entering ? n : -n;
                float eta = entering ? 1.0f / m.a : m.a;
                float fresnel = liquidFresnel(saturate(dot(-dir, facing)), eta);
                float3 bent = refract(dir, facing, eta);
                if (fresnel >= 1.0f || length_squared(bent) == 0.0f || rng.next() < fresnel) {
                    dir = reflect(dir, facing);
                    origin = wet.position + facing * RAY_EPSILON;
                    emitterThroughput = throughput;
                    cameraRay = false;
                } else {
                    dir = normalize(bent);
                    origin = wet.position - facing * RAY_EPSILON;
                    medium = entering ? m : float4(0.0f);
                }
                prevDelta = true;
                continue;
            }
            if (kind == 2u) {
                float w = prevDelta ? 1.0f : ptPowerHeuristic(prevPdf, ptPickPdf(L, prev, metLight) * metPdf);
                L_ += throughput * metLe * w;
                break;
            }
            if (kind == 4u) {   // a shape the light's exact one misses, or a camera-only one: on past it
                origin = h.position + dir * RAY_EPSILON;
                continue;
            }
            if (kind == 3u) {
                // Thin glass: a mirror reflection (Fresnel's share of the paths) or straight on, tinted.
                float3 gng, gn;
                orientNormals(pane, dir, gng, gn);
                float fresnel = 0.04f + 0.96f * pow(1.0f - saturate(dot(-dir, gn)), 5.0f);
                if (rng.next() < fresnel) {
                    dir = reflect(dir, gn);
                    origin = pane.position + gng * RAY_EPSILON;
                    emitterThroughput = throughput;
                    prevDelta = true;
                    cameraRay = false;
                } else {
                    throughput *= pane.albedo;
                    emitterThroughput *= pane.albedo;
                    origin = pane.position + dir * RAY_EPSILON;
                }
                continue;
            }
            if (kind == 0u) {
                // The sky, and the suns' discs (the sky texture's alpha: the clouds in front of them).
                float4 sky = skySample(u.flags, u.skyColor.rgb, s, dir, 0.0f);
                L_ += throughput * sky.rgb;
                for (uint i = 0; i < sunDiscCount(u); ++i) {
                    uint li = sunDiscLight(u, i);
                    // Camera and mirror rays see the disc as the frame does (the sky texture's clouds); the others as
                    // the light sample does (the cloud-shadow map at the point they left from), so the two estimates
                    // that MIS combines are of the same light.
                    float3 Le = prevDelta ? sunDisc(lights[li], dir, u.flags, sky.a)
                                          : sunDisc(lights[li], dir, u.flags, 1.0f) * sunVisibilityScale(lights[li], prev.p, s);
                    if (all(Le == 0.0f)) continue;
                    float omega = 2.0f * M_PI_F * max(ptOneMinusCosAngle(lights[li].positionRadius.w), 1e-9f);
                    float w = prevDelta ? 1.0f : lightHits ? ptPowerHeuristic(prevPdf, ptPickPdf(L, prev, li) / omega) : 0.0f;
                    L_ += throughput * Le * w;
                }
                break;
            }

            float3 ng, n;
            orientNormals(h, dir, ng, n);
            // Emitters aren't lit (as in the frame's passes). An emissive-mesh light's diffuse share came by next-event
            // estimation already.
            if (any(h.emission > 0.0f)) {
                L_ += (h.lightEmitter ? emitterThroughput : throughput) * h.emission;
                break;
            }
            float3 v = -dir;
            PTMaterial mat = ptMaterial(h, max(dot(n, v), 1e-4f), specular);
            float3 p = h.position + ng * RAY_EPSILON;
            PTVertex x = { p, n, ng, false };
            float2 rPick = ptRandom(smp, bounce, PT_SLOT_PICK, rng);

            // Next-event estimation: one light, picked by its unshadowed light here.
            if (u.lightCount > 0) {
                float pick;
                uint li = ptPickLight(L, x, rPick.x, rng.next(), pick);
                float2 r = ptRandom(smp, bounce, PT_SLOT_LIGHT, rng);
                if (li < u.lightCount && pick > 0.0f) {
                    PTLightSample ls = ptSampleLight(lights[li], p, r, s, u.flags);
                    if (ls.pdf > 0.0f && dot(ls.dir, ng) > 0.0f) {
                        float3 fd, fs;
                        float pdfB;
                        ptEval(mat, n, v, ls.dir, fd, fs, pdfB);
                        float3 f = ls.mesh ? fd : fd + fs;
                        if (any(f > 0.0f)) {
                            float3 T = ptTransmittance(p, p + ls.dir * ls.dist, accel, s, fogOn, fog, rng);
                            if (any(T > 0.0f)) {
                                float lightPdf = pick * ls.pdf;
                                bool found = lightHits && !ls.delta && !ls.mesh && (!treeLights || lightType(lights[li]) == LIGHT_SUN
                                    || ptProxyReaches(p, ls.dir, ls.dist, li, accel, proxies, params.config.y, lights));
                                float w = found ? ptPowerHeuristic(lightPdf, pdfB) : 1.0f;
                                L_ += throughput * f * ls.Le * T * (sunVisibilityScale(lights[li], p, s) * w / lightPdf);
                            }
                        }
                    }
                }
            }

            if (bounce >= params.samples.z) break;
            // The next direction: a lobe, then a direction in it.
            float3 l;
            float2 rDir = ptRandom(smp, bounce, PT_SLOT_DIRECTION, rng);
            if (rPick.y < mat.pSpec) {
                float3 t, b;
                tangentFrame(n, t, b);
                float3 hl = sampleGGXVNDF(float3(dot(v, t), dot(v, b), max(dot(n, v), 1e-4f)), mat.a, rDir);
                l = reflect(-v, normalize(t * hl.x + b * hl.y + n * hl.z));
            } else {
                l = cosineSampleHemisphere(n, rDir);
            }
            if (dot(l, ng) <= 0.0f) break;   // below the triangle: a shading normal's leak
            float3 fd, fs;
            float pdfB;
            ptEval(mat, n, v, l, fd, fs, pdfB);
            if (pdfB <= 0.0f) break;
            emitterThroughput = throughput * fs / pdfB;
            throughput *= (fd + fs) / pdfB;
            prev = x;
            prevPdf = pdfB;
            prevDelta = false;
            cameraRay = false;
            origin = p;
            dir = l;
            spread = mat.pSpec > 0.5f && mat.a < 0.01f ? pixelSpread : GI_RAY_SPREAD;   // mirrors keep the textures sharp
            ++bounce;
            // Russian roulette from the third bounce on.
            if (bounce >= 3) {
                float q = min(max(throughput.x, max(throughput.y, throughput.z)), 0.95f);
                if (ptRandom(smp, bounce - 1, PT_SLOT_ROULETTE, rng).x >= q) break;
                throughput /= q;
                emitterThroughput /= q;
            }
        }
        if (all(isfinite(L_))) sum += L_;   // a NaN or infinite path counts as black
    }

    uint total = params.samples.x + params.samples.y;
    float3 mean = params.samples.x > 0 ? accum.read(tid).rgb : float3(0.0f);
    mean += (sum - mean * float(params.samples.y)) / float(max(total, 1u));
    accum.write(float4(mean, 1.0f), tid);
}
