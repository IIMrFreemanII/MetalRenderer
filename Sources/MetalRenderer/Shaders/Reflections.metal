// ---------------------------------------------------------------------------------------------
// 2d. Reflections (specular materials only): one GGX visible-normal ray per pixel for the indirect specular light,
//     divided by the specular albedo so the denoiser filters a smooth signal (the composite multiplies it back).
//     Hits are lit by one light sample (one shadow ray) plus this frame's diffuse GI where the hit is on screen
//     (a dim sky ambient elsewhere); references (FLAG_REFERENCE) follow full paths instead. Without the shadow
//     denoiser, which otherwise adds direct specular analytically, one sampled light's direct specular is added.
//     Rougher than REFLECTION_MAX_ROUGHNESS: no ray, the composite uses the diffuse GI.
// ---------------------------------------------------------------------------------------------

// Light arriving along a reflection ray that hit `h`: emission, one light sample and the diffuse GI (see above).
float3 reflectionHitRadiance(constant Uniforms& u, SCENE_ACCEL accel, thread const SceneData& s, Surface h, float3 dir,
                             thread Sampler& rng, texture2d<float, access::read> normalDepth,
                             texture2d<float, access::read> indirect) {
    if (!h.hit) return skyRadiance(u, s, dir, 0.0f);
    float3 L = float3(0.0f), throughput = float3(1.0f);
    bool reference = flagOn(u.flags, FLAG_REFERENCE);
    uint bounces = reference ? u.bounces : 0;
    for (uint b = 0; ; ++b) {
        float3 hng, hn;
        orientNormals(h, dir, hng, hn);
        float3 hp = h.position + hng * RAY_EPSILON;
        float3 albedo = hitAlbedo(h);
        L += throughput * (b == 0 ? h.emission : giEmission(h));   // the reflection ray itself sees emitters
        if (LIGHT_TABLE) {
            Rng r;
            r.state = pcgHash(as_type<uint>(rng.next()) + b * 977u);
            L += throughput * albedo * sampleLightsRIS(s.lights, u.lightCount, u.lightTable, hp, hn, hng, 4, r, accel, s);
        } else if (u.lightCount > 0) {
            float pdf;
            float uPick = rng.next();
            float uSubset = u.lightCount > LIGHT_CANDIDATES ? rng.next() : 0.0f;
            uint li = pickLight(s.lights, u.lightCount, hp, hn, hng, uPick, uSubset, pdf);
            float2 r = rng.next2();
            if (li < u.lightCount) L += throughput * albedo * sampleLight(s.lights[li], hp, hn, hng, r, accel, s) / pdf;
        }
        if (!reference) {
            // Diffuse GI at the hit: this frame's indirect light where the hit point is visible on screen.
            float depth;
            float2 px = projectToPixel(h.position - u.camPos.xyz, u.camRight, u.camUp, u.camForward, float2(u.width, u.height), depth);
            float3 gi = skyAmbient(u, s) * 0.3f;
            if (depth > 0.0f && all(px >= 0.0f) && px.x < float(u.width) && px.y < float(u.height)) {
                uint2 q = uint2(px);
                float4 nd = normalDepth.read(q);
                if (nd.w > 0.0f && abs(nd.w - depth) < 0.03f * depth && dot(nd.xyz, hn) > 0.7f) gi = indirect.read(q).rgb;
            }
            return L + throughput * albedo * gi;
        }
        if (b >= bounces) return L;
        float3 d = cosineSampleHemisphere(hn, rng.next2());
        if (dot(d, hng) <= 0.0f) d -= 2.0f * dot(d, hng) * hng;
        throughput *= albedo;
        h = traceSurface(makeRay(hp, d, 0.0f, INFINITY), MASK_GEOMETRY, accel, s, GI_RAY_SPREAD);
        dir = d;
        if (!h.hit) return L + throughput * skyRadiance(u, s, dir, 2.0f);
    }
}

constant uint REFLECT_FOG = 1;   // reflectionKernel's own flag: the reflection rays are fogged (FOG_ENABLED and FOG_REFLECTIONS)

kernel void reflectionKernel(constant Uniforms&               u          [[buffer(0)]],
                             SCENE_ACCEL                      accel      [[buffer(1)]],
                             device const float3*             positions  [[buffer(2)]],
                             device const float3*             normals    [[buffer(3)]],
                             device const uint*               indices    [[buffer(4)]],
                             device const MeshData*           meshes     [[buffer(5)]],
                             device const InstanceData*       instances  [[buffer(6)]],
                             constant SceneShading&           shading    [[buffer(7)]],
                             device const Light*              lights     [[buffer(8)]],
                             device const RegirReservoir* regirGrid [[buffer(11)]],  // the light grid (ReGIR)
                             constant RegirParams&       regir     [[buffer(12)]],
                             texture2d<float, access::read>   surfacePos [[texture(0)]],
                             texture2d<float, access::read>   normalDepth [[texture(1)]],
                             texture2d<float, access::read>   geoNormal  [[texture(2)]],
                             texture2d<float, access::read>   material   [[texture(3)]],
                             texture2d<float, access::read>   blueNoise  [[texture(4)]],
                             texture2d<float, access::read>   indirect   [[texture(5)]],   // this frame's diffuse GI
                             texture2d<float, access::write>  outSpecular [[texture(6)]],
                             texture3d<float>                 fogNoiseTex [[texture(7)]],   // with FOG_REFLECTIONS
                             texture2d<float, access::read>   restirSpecular [[texture(8)]],  // with FLAG_RESTIR
                             constant FogParams&              fog        [[buffer(9)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid), m = material.read(tid);
    if (sp.w <= 0.0f || all(m.rgb <= 0.0f)) { outSpecular.write(float4(0.0f), tid); return; }

    SceneData s;
    s.positions = positions; s.normals = normals; s.indices = indices; s.meshes = meshes;
    s.instances = instances; bindShading(s, shading); s.lights = lights; s.lightCount = u.lightCount;
    s.lightTable = u.lightTable; s.regirGrid = regirGrid; s.regir = &regir;
    Sampler rng;
    rng.blueNoise = blueNoise;
    rng.pixel = tid;
    rng.frame = u.frameIndex;
    rng.dimension = 40;   // past the trace kernel's dimensions
    rng.useBlueNoise = flagOn(u.flags, FLAG_BLUE_NOISE);
    rng.rng.state = pcgHash(tid.x * 7919u + pcgHash(tid.y + pcgHash(u.frameIndex * 31u + 17u)));

    float3 n = normalDepth.read(tid).xyz, ng = geoNormal.read(tid).xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;
    float3 v = normalize(u.camPos.xyz - sp.xyz);
    float3 f0 = m.rgb;
    float roughness = m.a, a = roughness * roughness;
    float NoV = max(dot(n, v), 1e-4f);
    float3 albedo = specularAlbedo(f0, 1.0f, roughness, NoV);
    float3 result = float3(0.0f), direct = float3(0.0f);

    uint analyticLights = u.lightGroupEnd.w;   // mesh lights: the reflection ray sees them
    if (flagOn(u.flags, FLAG_RESTIR)) {
        direct += restirSpecular.read(tid).rgb;   // ReSTIR's direct specular (restirSpatialKernel)
    } else if (!flagOn(u.flags, FLAG_SHADOW_DENOISER) && analyticLights > 0) {
        // Direct specular from one light, with one shadow ray to a random point of it.
        float pdf;
        float uPick = rng.next();
        float uSubset = analyticLights > LIGHT_CANDIDATES ? rng.next() : 0.0f;
        float2 r = rng.next2();
        if (!flagOn(u.flags, FLAG_REFERENCE)) {
            // The light is picked by its specular light here, and that analytic specular (what the composite adds
            // with the shadow denoiser) x the ray's visibility is the sample: only the pick and the shadow are noisy.
            float3 unshadowed;
            uint li = pickLightSpecular(lights, analyticLights, p, n, ng, v, f0, roughness, uPick, uSubset, pdf, unshadowed);
            if (li < analyticLights && isVisible(p, lightShadowTarget(lights[li], p, r), accel))
                direct += unshadowed * (sunVisibilityScale(lights[li], p, s) / pdf);
        } else {
            // References: the light is picked by its diffuse light here; spheres and spots exactly, a uniform point
            // on the sphere; other lights their analytic specular x the visibility of a random point of them.
            uint li = pickLight(lights, analyticLights, p, n, ng, uPick, uSubset, pdf);
            if (li < analyticLights) {
                Light light = lights[li];
                uint type = lightType(light);
                float3 x = lightShadowTarget(light, p, r);
                if (type == LIGHT_SPHERE || type == LIGHT_SPOT) {
                    float3 toX = x - p;
                    float d2 = dot(toX, toX);
                    float3 l = toX * rsqrt(d2);
                    float cosX = dot(normalize(x - light.positionRadius.xyz), -l);
                    float NoL = dot(n, l);
                    if (cosX > 0.0f && NoL > 0.0f && dot(ng, l) > 0.0f && isVisible(p, x, accel)) {
                        float rad = light.positionRadius.w;
                        float3 Le = light.color.rgb / (M_PI_F * rad * rad);
                        if (type == LIGHT_SPOT) Le *= spotFactor(light, -l);
                        float3 h = normalize(l + v);
                        float3 F = schlick(f0, 1.0f, dot(v, h));
                        float brdf = ggxD(saturate(dot(n, h)), max(a, 1e-4f)) * smithVisibility(NoV, NoL, max(a, 1e-4f));
                        direct += F * brdf * Le * (NoL * cosX * 4.0f * M_PI_F * rad * rad / d2) / pdf;
                    }
                } else if (isVisible(p, x, accel)) {
                    direct += lightSpecular(light, p, n, ng, v, f0, roughness) * (sunVisibilityScale(light, p, s) / pdf);
                }
            }
        }
    }

    if (roughness < REFLECTION_MAX_ROUGHNESS || flagOn(u.flags, FLAG_REFERENCE)) {
        float3 t, b;
        tangentFrame(n, t, b);
        float3 hl = sampleGGXVNDF(float3(dot(v, t), dot(v, b), NoV), a, rng.next2());
        float3 h = t * hl.x + b * hl.y + n * hl.z;
        float3 l = reflect(-v, h);
        float NoL = dot(n, l);
        if (NoL > 0.0f && dot(l, ng) > 0.0f) {
            // VNDF sampling: f cos / pdf = F G2 / G1(v).
            float a2 = a * a;
            float g1 = 2.0f * NoV / (NoV + sqrt(a2 + (1.0f - a2) * NoV * NoV));
            float g2 = smithVisibility(NoV, NoL, a) * 4.0f * NoL * NoV;
            float3 weight = schlick(f0, 1.0f, dot(v, h)) * (g2 / max(g1, 1e-6f));
            float spread = mix(2.0f * u.camUp.w / float(u.height), GI_RAY_SPREAD * 4.0f, roughness);
            // No texture feedback from reflections: their footprint ignores curvature, so self-reflections at close
            // range would ask for the finest mips.
            Surface hit = traceSurface(makeRay(p, l, 0.0f, INFINITY), MASK_GEOMETRY, accel, s, spread);
            float3 radiance = reflectionHitRadiance(u, accel, s, hit, l, rng, normalDepth, indirect);
            bool fogged = (fog.counts.w & (FOG_ENABLED | FOG_REFLECTIONS)) == (FOG_ENABLED | FOG_REFLECTIONS);
            if (passOn(fogged ? REFLECT_FOG : 0u, REFLECT_FOG)) {
                float2 uDistMix = rng.next2();
                float4 r = float4(rng.next2(), rng.next2());
                radiance = fogAlongRay(p, l, hit.hit ? length(hit.position - p) : INFINITY, radiance, uDistMix, r, accel, s, fog,
                                       skyAmbient(u, s) * fog.albedo.w, fogNoiseTex, rng.rng);
            }
            result += weight * radiance;
        }
    }
    // The firefly clamp is for the reflection ray's light (a small bright emitter seen by few rays). The direct
    // specular is bounded by the lights' analytic specular (ReSTIR's by its own clamp), and clamping it darkened
    // the highlights.
    float lum = luminance(result / max(albedo, float3(1e-3f)));
    if (lum > FIREFLY_CLAMP && !flagOn(u.flags, FLAG_NO_CLAMP)) result *= FIREFLY_CLAMP / lum;
    outSpecular.write(roundToHalf(float4((result + direct) / max(albedo, float3(1e-3f)), 1.0f)), tid);
}
