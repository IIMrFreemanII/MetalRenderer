// ---------------------------------------------------------------------------------------------
// Reference "Path traced" (Settings: Reference; README "Reference rendering"): the whole picture from one kernel,
// as a debugging ground truth. Per pixel, paths from a jittered camera ray: Lambert + GGX (the frame's own material
// model, Surface.metal), window glass as a thin dielectric (reflected or passed through, tinted), emitters, the sky
// and the suns' discs. Next-event estimation at every hit, each light sampled by solid angle; the analytic lights
// (but the suns, which are met on a miss) are also met by the bounce rays, and the two are combined by multiple
// importance sampling (power heuristic). Emissive-mesh lights split the work instead: next-event estimation lights
// the diffuse lobe, the specular lobe meets them. Russian roulette after 3 bounces, no firefly clamp. Each frame's
// paths join a running mean (rgba32Float), which the renderer restarts when the picture would change.
// Not here: the volumetric fog, refraction through thick glass, the analytic lights' reflections with more than
// PT_LIGHT_HITS lights (next-event estimation alone lights the glossy lobe then; camera rays see the lights' spheres).
// ---------------------------------------------------------------------------------------------

// With up to this many lights the bounce rays look for the analytic ones (a loop over them at every bounce).
constant uint PT_LIGHT_HITS = LIGHT_CANDIDATES;

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
    bool   mesh;     // an emissive-mesh light: lights the diffuse lobe only
};

PTLightSample ptSampleLight(Light light, float3 p, float2 r, thread const SceneData& s) {
    PTLightSample ls;
    ls.dir = float3(0.0f, 1.0f, 0.0f); ls.dist = 0.0f; ls.Le = float3(0.0f); ls.pdf = 0.0f; ls.delta = false; ls.mesh = false;
    uint type = lightType(light);
    float3 c = light.positionRadius.xyz;
    float radius = light.positionRadius.w;
    if (type == LIGHT_SUN) {
        float omc = ptOneMinusCosAngle(radius);
        ls.dir = ptSampleCone(light.axis.xyz, omc, r);
        ls.dist = 1e4f;
        float omega = 2.0f * M_PI_F * max(omc, 1e-9f);
        ls.Le = light.color.rgb / omega;
        ls.pdf = 1.0f / omega;
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

// pickLight's probability of light j at p (lightCount <= LIGHT_CANDIDATES: every light is a candidate).
inline float ptPickPdf(device const Light* lights, uint lightCount, uint j, float3 p, float3 n, float3 ng) {
    float total = 0.0f, wj = 0.0f;
    for (uint i = 0; i < lightCount; ++i) {
        float w = luminance(lightUnshadowed(lights[i], p, n, ng));
        total += w;
        if (i == j) wj = w;
    }
    return total > 0.0f ? wj / total : 0.0f;
}

// What gets from `from` to `to`: nothing behind geometry, else through the window panes on the way (up to 4)
// (1 - Fresnel) x tint each.
float3 ptTransmittance(float3 from, float3 to, SCENE_ACCEL accel, thread const SceneData& s) {
    if (!isVisible(from, to, accel)) return float3(0.0f);
    float3 T = float3(1.0f);
    if (GLASS) {
        float3 d = to - from;
        float reach = length(d);
        d /= reach;
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
// The kernel. params: x = paths in the mean so far, y = paths to add this frame, z = bounces.
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
                            device const RegirReservoir*     regirGrid  [[buffer(11)]],
                            constant RegirParams&            regir      [[buffer(12)]],
                            constant uint4&                  params     [[buffer(13)]],
                            texture2d<float, access::read_write> accum  [[texture(0)]],
                            uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    bool specular = flagOn(u.flags, FLAG_SPECULAR);
    bool lightHits = u.lightCount <= PT_LIGHT_HITS;
    uint analytic = u.lightGroupEnd.w;
    uint suns = LIGHT_TABLE ? u.lightTable.y : analytic;
    float pixelSpread = 2.0f * u.camUp.w / float(u.height);
    // A rotating eighth of the pixels tells the texture streamer which mip levels they need (as traceKernel's do).
    bool record = ((tid.x + 3u * tid.y + u.frameIndex) & 7u) == 0u;

    float3 sum = float3(0.0f);
    for (uint k = 0; k < params.y; ++k) {
        Rng rng;
        rng.state = pcgHash(tid.x + pcgHash(tid.y + pcgHash((params.x + k) ^ 0x6A09E667u)));
        float3 L = float3(0.0f), throughput = float3(1.0f);
        float3 emitterThroughput = float3(1.0f);   // what an emissive-mesh light met next counts with (its specular share)
        float3 dir = normalize(viewDirection(u, (float2(tid) + rng.next2()) / float2(u.width, u.height)));
        float3 origin = u.camPos.xyz;
        // The last scattering point, for the MIS weight of a light the next ray meets.
        float3 prevP = origin, prevN = float3(0.0f), prevNg = float3(0.0f);
        float prevPdf = 0.0f;
        bool prevDelta = true;     // camera ray, or a mirror reflection off glass: no light was sampled for it
        bool cameraRay = true;     // meets the lights' spheres and camera-only geometry, as the frame's camera rays do
        float spread = pixelSpread;
        uint bounce = 0;

        for (uint event = 0; event < params.z + 9u; ++event) {
            uint mask = cameraRay ? MASK_ALL & ~MASK_GLASS : MASK_GEOMETRY;
            Surface h = traceSurface(makeRay(origin, dir, 0.0f, INFINITY), mask, accel, s, spread, record && event == 0);
            float tHit = h.hit ? distance(origin, h.position) : INFINITY;
            // A window pane in front of it.
            Surface g;
            g.hit = false;
            if (GLASS) {
                g = traceSurface(makeRay(origin, dir, 0.0f, tHit), MASK_GLASS, accel, s, spread);
                if (g.hit) tHit = distance(origin, g.position);
            }
            // An analytic light in front of both.
            if (!cameraRay && lightHits) {
                float tl, pdfL;
                float3 Le;
                uint met = analytic;
                float3 metLe = float3(0.0f);
                float metPdf = 0.0f;
                for (uint j = 0; j < analytic; ++j) {
                    if (ptHitLight(lights[j], origin, dir, tHit, prevP, tl, Le, pdfL)) { tHit = tl; met = j; metLe = Le; metPdf = pdfL; }
                }
                if (met < analytic) {
                    float w = prevDelta ? 1.0f : ptPowerHeuristic(prevPdf, ptPickPdf(lights, u.lightCount, met, prevP, prevN, prevNg) * metPdf);
                    L += throughput * metLe * w;
                    break;
                }
            }
            if (g.hit) {
                // Thin glass: a mirror reflection (Fresnel's share of the paths) or straight on, tinted.
                float3 gng, gn;
                orientNormals(g, dir, gng, gn);
                float fresnel = 0.04f + 0.96f * pow(1.0f - saturate(dot(-dir, gn)), 5.0f);
                if (rng.next() < fresnel) {
                    dir = reflect(dir, gn);
                    origin = g.position + gng * RAY_EPSILON;
                    emitterThroughput = throughput;
                    prevDelta = true;
                    cameraRay = false;
                } else {
                    throughput *= g.albedo;
                    emitterThroughput *= g.albedo;
                    origin = g.position + dir * RAY_EPSILON;
                }
                continue;
            }
            if (!h.hit) {
                // The sky, and the suns' discs (the sky texture's alpha: the clouds in front of them).
                float4 sky = skySample(u.flags, u.skyColor.rgb, s, dir, 0.0f);
                L += throughput * sky.rgb;
                for (uint i = 0; i < suns; ++i) {
                    uint li = LIGHT_TABLE ? (i == 0 ? u.lightTable.z : u.lightTable.w) : i;
                    Light light = lights[li];
                    float theta = light.positionRadius.w, c = dot(dir, light.axis.xyz);
                    if (lightType(light) != LIGHT_SUN || c < cos(theta)) continue;
                    float omega = 2.0f * M_PI_F * max(ptOneMinusCosAngle(theta), 1e-9f);
                    float3 Le = light.color.rgb / omega;
                    if (flagOn(u.flags, FLAG_SKY_MAP)) {
                        float x = sqrt(max(1.0f - c * c, 0.0f)) / sin(theta), mu = sqrt(max(1.0f - x * x, 0.0f));
                        Le *= sky.a * (1.0f - 0.6f * (1.0f - mu)) / 0.8f;   // limb darkening, as traceKernel's
                    }
                    float w = prevDelta ? 1.0f : lightHits
                        ? ptPowerHeuristic(prevPdf, ptPickPdf(lights, u.lightCount, li, prevP, prevN, prevNg) / omega) : 0.0f;
                    L += throughput * Le * w;
                }
                break;
            }

            float3 ng, n;
            orientNormals(h, dir, ng, n);
            // Emitters aren't lit (as in the frame's passes). An emissive-mesh light's diffuse share came by next-event
            // estimation already.
            if (any(h.emission > 0.0f)) {
                L += (h.lightEmitter ? emitterThroughput : throughput) * h.emission;
                break;
            }
            float3 v = -dir;
            PTMaterial m = ptMaterial(h, max(dot(n, v), 1e-4f), specular);
            float3 p = h.position + ng * RAY_EPSILON;

            // Next-event estimation: one light, picked by its unshadowed light here.
            if (u.lightCount > 0) {
                float pick;
                float uPick = rng.next();
                float uSubset = u.lightCount > LIGHT_CANDIDATES ? rng.next() : 0.0f;
                uint li = pickLight(lights, u.lightCount, p, n, ng, uPick, uSubset, pick);
                float2 r = rng.next2();
                if (li < u.lightCount && pick > 0.0f) {
                    PTLightSample ls = ptSampleLight(lights[li], p, r, s);
                    if (ls.pdf > 0.0f && dot(ls.dir, ng) > 0.0f) {
                        float3 fd, fs;
                        float pdfB;
                        ptEval(m, n, v, ls.dir, fd, fs, pdfB);
                        float3 f = ls.mesh ? fd : fd + fs;
                        if (any(f > 0.0f)) {
                            float3 T = ptTransmittance(p, p + ls.dir * ls.dist, accel, s);
                            if (any(T > 0.0f)) {
                                float lightPdf = pick * ls.pdf;
                                float w = ls.delta || ls.mesh || !lightHits ? 1.0f : ptPowerHeuristic(lightPdf, pdfB);
                                L += throughput * f * ls.Le * T * (sunVisibilityScale(lights[li], p, s) * w / lightPdf);
                            }
                        }
                    }
                }
            }

            if (bounce >= params.z) break;
            // The next direction: a lobe, then a direction in it.
            float3 l;
            if (rng.next() < m.pSpec) {
                float3 t, b;
                tangentFrame(n, t, b);
                float3 hl = sampleGGXVNDF(float3(dot(v, t), dot(v, b), max(dot(n, v), 1e-4f)), m.a, rng.next2());
                l = reflect(-v, normalize(t * hl.x + b * hl.y + n * hl.z));
            } else {
                l = cosineSampleHemisphere(n, rng.next2());
            }
            if (dot(l, ng) <= 0.0f) break;   // below the triangle: a shading normal's leak
            float3 fd, fs;
            float pdfB;
            ptEval(m, n, v, l, fd, fs, pdfB);
            if (pdfB <= 0.0f) break;
            emitterThroughput = throughput * fs / pdfB;
            throughput *= (fd + fs) / pdfB;
            prevP = p; prevN = n; prevNg = ng; prevPdf = pdfB;
            prevDelta = false;
            cameraRay = false;
            origin = p;
            dir = l;
            spread = m.pSpec > 0.5f && m.a < 0.01f ? pixelSpread : GI_RAY_SPREAD;   // mirrors keep the textures sharp
            ++bounce;
            // Russian roulette from the third bounce on.
            if (bounce >= 3) {
                float q = min(max(throughput.x, max(throughput.y, throughput.z)), 0.95f);
                if (rng.next() >= q) break;
                throughput /= q;
                emitterThroughput /= q;
            }
        }
        if (all(isfinite(L))) sum += L;   // a NaN or infinite path counts as black
    }

    uint total = params.x + params.y;
    float3 mean = params.x > 0 ? accum.read(tid).rgb : float3(0.0f);
    mean += (sum - mean * float(params.y)) / float(max(total, 1u));
    accum.write(float4(mean, 1.0f), tid);
}
