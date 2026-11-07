// ---------------------------------------------------------------------------------------------
// 1. Trace kernel: G-buffer + direct light + path traced indirect light (1 sample per pixel)
// ---------------------------------------------------------------------------------------------

// traceKernel's own flags, made from the uniforms (Uniforms.tracePassFlags in GPUTypes.swift makes the same word to compile in).
constant uint TRACE_BOUNCES = 1;       // the path tracer's indirect light (Uniforms.bounces > 0)
inline uint tracePassFlags(constant Uniforms& u) {
    return u.bounces > 0 ? TRACE_BOUNCES : 0u;
}

kernel void traceKernel(constant Uniforms&               u          [[buffer(0)]],
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
                        texture2d<float, access::write>  outNormalDepth [[texture(0)]],
                        texture2d<float, access::write>  outAlbedo      [[texture(1)]],
                        texture2d<float, access::write>  outEmission    [[texture(2)]],
                        texture2d<float, access::write>  outMotion      [[texture(3)]],
                        texture2d<float, access::write>  outDirect      [[texture(4)]],
                        texture2d<float, access::write>  outIndirect    [[texture(5)]],
                        texture2d<float, access::write>  outDeviceDepth [[texture(6)]],  // MetalFX: reversed-Z depth
                        texture2d<float, access::write>  outPixelMotion [[texture(7)]],  // MetalFX: prev pixel - this pixel
                        texture2d<float, access::read>   blueNoise      [[texture(8)]],
                        texture2d<float, access::write>  outSurfacePos  [[texture(9)]],   // xyz world, w = instance + 1 (0 = no GI)
                        texture2d<float, access::write>  outGeoNormal   [[texture(10)]],  // oriented geometric normal
                        texture2d_array<float, access::read> lightMap   [[texture(11)]],  // with FLAG_LIGHT_MAPS
                        texture2d<float, access::write>  outMaterial    [[texture(14)]],  // with FLAG_SPECULAR: rgb = F0, a = roughness
                        texture2d<float, access::read>   liquidRay      [[texture(16)]],  // LIQUID: the camera ray bent through
                        texture2d<float, access::read>   liquidDir      [[texture(17)]],  // a liquid (liquidKernel)
                        texture2d<float, access::write>  outSheen       [[texture(18)]],  // MATERIAL_LOBES: Surface.sheen
                        texture2d<float, access::write>  outAnisotropy  [[texture(19)]],  // ...xyz = its tangent, w = how much
                        uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;

    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    bool specular = flagOn(u.flags, FLAG_SPECULAR);

    Sampler rng = makeSampler(blueNoise, u, tid, 0, pixelSeed(tid, u.frameIndex, SEED_TRACE));

    // Primary ray.
    float2 size = float2(u.width, u.height);
    float3 dir = primaryDirection(u, tid);
    Ray primary = makeRay(u.camPos.xyz, dir, 0.0f, INFINITY);
    // A rotating eighth of the pixels tells the texture streamer which mip levels they need.
    bool recordTextures = ((tid.x + 3u * tid.y + u.frameIndex) & 7u) == 0u;
    // Window glass isn't met here: glassKernel adds it over the surface behind it. Nor a liquid: where one is in view,
    // the ray goes on from where liquidKernel bent it, and liquidApplyKernel adds the liquid over what it finds.
    // Water isn't in the scene's structure: waterKernel bends the ray into it the same way (Water.metal), and
    // waterApplyKernel adds its surface.
    uint primaryMask = (GLASS ? MASK_ALL & ~MASK_GLASS : MASK_ALL) & (LIQUID ? ~MASK_LIQUID : MASK_ALL);
    float liquidEntry = -1.0f;
    float3 eye = dir;   // the camera's ray (dir: the ray that reaches what this pixel shows)
    if (LIQUID || WATER) {
        // w: 1 = bent by a liquid, 2 + WATER_RAY_* by water (bent where WATER_RAY_BENT is set).
        float4 bent = liquidRay.read(tid);
        if (bent.w == 1.0f || (bent.w >= 2.0f && ((uint(bent.w) - 2u) & 1u) != 0u)) {
            float4 along = liquidDir.read(tid);
            liquidEntry = along.w;
            dir = along.xyz;
            primary = makeRay(bent.xyz, dir, 0.0f, INFINITY);
        }
    }
    Hit hit = intersectClosest(primary, primaryMask, accel);
    Surface sf = surfaceFromHit(hit, primary, accel, s, 2.0f * u.camUp.w / float(u.height), recordTextures);   // pixel angle

    bool upscale = flagOn(u.flags, FLAG_UPSCALE);
    if (!sf.hit) {
        if (upscale) {
            // Sky: a point at infinity only moves with camera rotation.
            float dCur, dPrev;
            float2 cur  = projectToPixel(dir, u.camRight, u.camUp, u.camForward, size, dCur);
            float2 prev = projectToPixel(dir, u.prevCamRight, u.prevCamUp, u.prevCamForward, size, dPrev);
            outDeviceDepth.write(float4(0.0f), tid);
            outPixelMotion.write(float4(dPrev > 0.0f ? prev - cur : float2(0.0f), 0.0f, 0.0f), tid);
        }
        outNormalDepth.write(float4(0.0f, 0.0f, 0.0f, -1.0f), tid);
        outAlbedo.write(float4(0.0f), tid);
        // Sky, plus the discs of the suns (camera rays only: GI rays get the sun from next-event estimation). With the
        // sky texture the disc darkens toward its limb and clouds in front of it dim it (the texture's alpha).
        // A backdrop in its place: no sky, no sun disc.
        float3 sky;
        if (backdropOn(u)) {
            sky = backdropSample(u, dir);
        } else {
            float4 skyHere = skySample(u.flags, u.skyColor.rgb, s, dir, 0.0f);
            sky = skyHere.rgb;
            for (uint k = 0; k < sunDiscCount(u); ++k) sky += sunDisc(lights[sunDiscLight(u, k)], dir, u.flags, skyHere.a);
        }
        outEmission.write(float4(sky, 1.0f), tid);
        outMotion.write(float4(0.0f), tid);
        outDirect.write(float4(0.0f), tid);
        outIndirect.write(float4(0.0f), tid);
        outSurfacePos.write(float4(0.0f), tid);
        outGeoNormal.write(float4(0.0f), tid);
        if (specular) outMaterial.write(float4(0.0f), tid);
        if (MATERIAL_LOBES) {
            outSheen.write(float4(0.0f), tid);
            outAnisotropy.write(float4(0.0f), tid);
        }
        return;
    }

    float3 ng, n;
    orientNormals(sf, dir, ng, n);
    if (specular) outMaterial.write(float4(sf.f0, max(sf.roughness, MIN_ROUGHNESS)), tid);
    if (MATERIAL_LOBES) {
        outSheen.write(sf.sheen, tid);
        outAnisotropy.write(float4(sf.lobeTangent, sf.anisotropy), tid);
    }
    float viewDepth = dot(sf.position - u.camPos.xyz, u.camForward.xyz);
    outNormalDepth.write(float4(n, viewDepth), tid);
    // A strand's (Hair.metal): its tangent in the alphas. Skin: minus its strength (Hair.metal hairFromGBuffer).
    float2 tangentOct = sf.hair ? hairOctEncode(sf.tangent)
                      : float2(1.0f, -2.0f - (LEAF_TRANSMIT && sf.leaf > 0.0f ? leafCode(sf.leaf, sf.backlit) : SKIN ? sf.skin : 0.0f));
    outGeoNormal.write(float4(ng, tangentOct.y + 2.0f), tid);
    outAlbedo.write(float4(sf.albedo, tangentOct.x), tid);
    outEmission.write(float4(sf.emission, 1.0f), tid);

    // Motion vector: project where this surface point was last frame into last frame's camera.
    // The denoiser wants the index of the previous frame's pixel, whose sample was taken at its center + that frame's jitter.
    float prevDepth;
    float2 prevPixel = projectToPixel(sf.prevPosition - u.prevCamPos.xyz, u.prevCamRight, u.prevCamUp, u.prevCamForward, size, prevDepth);
    // Seen through a liquid, the surface isn't where this pixel looks: the pixel moves as the liquid's surface it looks
    // through does (taken as still), its depth as the surface's.
    float3 seen = sf.position;
    if ((LIQUID || WATER) && liquidEntry > 0.0f) {
        seen = u.camPos.xyz + eye * liquidEntry;
        float ignored;
        prevPixel = projectToPixel(seen - u.prevCamPos.xyz, u.prevCamRight, u.prevCamUp, u.prevCamForward, size, ignored);
    }
    outMotion.write(float4(prevPixel - 0.5f - u.jitter.zw, prevDepth, prevDepth > 0.0f ? 1.0f : 0.0f), tid);
    if (upscale) {
        // MetalFX wants unjittered motion in pixels, from this pixel to where it was last frame.
        float curDepth;
        float2 curPixel = projectToPixel(seen - u.camPos.xyz, u.camRight, u.camUp, u.camForward, size, curDepth);
        outDeviceDepth.write(float4(NEAR_PLANE / max(viewDepth, NEAR_PLANE)), tid);
        outPixelMotion.write(float4(prevDepth > 0.0f ? prevPixel - curPixel : float2(0.0f), 0.0f, 0.0f), tid);
    }

    // Emissive surfaces (the light spheres) are not lit.
    if (any(sf.emission > 0.0f)) {
        outDirect.write(float4(0.0f), tid);
        outIndirect.write(float4(0.0f), tid);
        outSurfacePos.write(float4(sf.position, 0.0f), tid);
        return;
    }
    outSurfacePos.write(float4(sf.position, float(sf.instanceId + 1)), tid);

    float3 p = sf.position + ng * RAY_EPSILON;   // offset along the true normal so the origin is never below the triangle
    HairPoint hp = noHair();
    if (sf.hair) {
        hp.on = true;
        hp.tangent = sf.tangent;
        hp.view = -dir;
        hp.h = sf.hairH;
        hp.albedo = sf.albedo;
    } else if (SKIN && sf.skin > 0.0f) {
        hp = skinPoint(sf.skin);
    } else if (LEAF_TRANSMIT && sf.leaf > 0.0f) {
        hp = leafPoint(sf.leaf, sf.backlit);
    }

    // Direct light. Only accumulated references (FLAG_ALL_LIGHTS) trace it here: one shadow ray per analytic light (the
    // first lightGroupEnd.w; meshLightsKernel adds the emissive-mesh lights). Every other frame's comes from
    // sampledLightsKernel or MegaLights after this kernel.
    float3 direct = float3(0.0f);
    if (flagOn(u.flags, FLAG_ALL_LIGHTS)) {
        for (uint i = 0; i < u.lightGroupEnd.w; ++i) {
            float2 r = rng.next2();
            float3 unshadowed = litUnshadowed(lights[i], p, n, ng, hp);
            if (all(unshadowed <= 0.0f)) continue;   // light behind the surface: it shadows itself
            float3 target = lightShadowTarget(lights[i], p, r);
            float3 origin = hairOrSurface(hp, sf.position, n, p, target);
            if (isVisible(origin, target, accel))
                direct += unshadowed * sunVisibilityScale(lights[i], p, s) * glassShadowTint(origin, target, accel, s, u.flags);
        }
    }
    uint own = tracePassFlags(u);

    // Indirect light: a short diffuse path with next-event estimation at every bounce.
    float3 indirect = float3(0.0f);
    if (passOn(own, TRACE_BOUNCES)) {
        float3 throughput = float3(1.0f);
        float3 origin = p;
        float3 normal = n, geomNormal = ng;
        for (uint b = 0; b < u.bounces; ++b) {
            float3 d = sampleBounce(normal, geomNormal, rng.next2());
            Ray r = makeRay(origin, d, 0.0f, INFINITY);
            Surface h = traceSurface(r, rayMask(MASK_GEOMETRY, RAY_GI), accel, s, GI_RAY_SPREAD);
            if (!h.hit) {
                indirect += throughput * skyRadiance(u, s, d, 2.0f);
                break;
            }
            float3 hng, hn;
            orientNormals(h, d, hng, hn);
            indirect += throughput * giEmission(h);
            throughput *= hitAlbedo(h, flagOn(u.flags, FLAG_ENERGY));   // Lambert BRDF * cos / cosine pdf = albedo (+ specular, as diffuse)
            float3 hp = h.position + hng * RAY_EPSILON;
            if (flagOn(u.flags, FLAG_LIGHT_MAPS)) {
                uint seed = pcgHash(tid.x + pcgHash(tid.y + pcgHash(u.frameIndex * 8u + b)));
                indirect += throughput * giLightIllum(lights, u, lightMap, hp, hn, hng, seed, accel, s);   // no rays (but LIGHT_TABLE)
            } else if (LIGHT_TABLE) {
                // Next-event estimation with many lights: RIS over light-table draws.
                Rng r;
                r.state = pcgHash(tid.x + pcgHash(tid.y + pcgHash(u.frameIndex * 8u + b + 0x51ED27u)));
                indirect += throughput * sampleLightsRIS(lights, u.lightCount, u.lightTable, hp, hn, hng, 4, r, accel, s);
            } else if (u.lightCount > 0) {
                // Next-event estimation: one light, picked by its unshadowed luminance here.
                float pdf;
                float uPick = rng.next();
                float uSubset = u.lightCount > LIGHT_CANDIDATES ? rng.next() : 0.0f;   // keeps few-light sequences unchanged
                uint li = pickLight(lights, u.lightCount, hp, hn, hng, uPick, uSubset, pdf);
                float2 r = rng.next2();
                if (li < u.lightCount) indirect += throughput * sampleLight(lights[li], hp, hn, hng, r, accel, s) / pdf;
            }
            if (all(throughput < 0.01f)) break;
            origin = hp;
            normal = hn;
            geomNormal = hng;
        }
        indirect *= fireflyScale(u, luminance(indirect));
    }

    outDirect.write(float4(direct, 1.0f), tid);
    outIndirect.write(float4(indirect, 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 1e. Emissive-mesh lights (the lights after lightGroupEnd.w) in accumulated references (FLAG_ALL_LIGHTS), after
//     traceKernel's analytic lights: one light picked by its proxy's unshadowed luminance, one point on one of its
//     triangles picked by emitted power, one shadow ray, added to the direct light. (Sampled lights and MegaLights
//     sample the emitters' triangles themselves.)
// ---------------------------------------------------------------------------------------------

kernel void meshLightsKernel(constant Uniforms&                    u          [[buffer(0)]],
                             SCENE_ACCEL                           accel      [[buffer(1)]],
                             device const InstanceData*            instances  [[buffer(6)]],
                             constant SceneShading&                shading    [[buffer(7)]],
                             device const Light*                   lights     [[buffer(8)]],
                             texture2d<float, access::read>        surfacePos [[texture(0)]],   // w = instance + 1, 0 = unlit
                             texture2d<float, access::read>        normalDepth [[texture(1)]],
                             texture2d<float, access::read>        geoNormal  [[texture(2)]],
                             texture2d<float, access::read>        blueNoise  [[texture(3)]],
                             texture2d<float, access::read_write>  direct     [[texture(4)]],
                             texture2d<float, access::read>        albedo     [[texture(5)]],   // a strand's tangent (Hair.metal)
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    uint first = u.lightGroupEnd.w, count = u.lightCount - first;
    if (sp.w <= 0.0f || count == 0) return;   // sky and emitters
    float3 n = normalDepth.read(tid).xyz;
    float4 g = geoNormal.read(tid);
    float3 ng = g.xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;
    HairPoint hp = hairFromGBuffer(albedo.read(tid), g.w, n, normalize(u.camPos.xyz - sp.xyz));

    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    // Other blue-noise windows than the trace kernel's.
    Sampler rng = makeSampler(blueNoise, u, tid, 96,
                              pcgHash(tid.x * 31u + pcgHash(tid.y + pcgHash(u.frameIndex ^ 0x5bd1e995u))));

    // One light by its proxy's luminance (weighted reservoir over all of them: there are few).
    float pickedWeight = 0.0f;
    StreamPick pick = streamPick(rng.next());
    uint picked = count;
    // With FLAG_CASCADE_EMITTERS the cascades light an emitter within its reach (cascadeEmitterReach): a light wholly
    // within it is left out here, and a sample point within it counts nothing (the cascades' rays carry that part).
    bool cascadeEmitters = flagOn(u.flags, FLAG_CASCADE_EMITTERS);
    for (uint i = 0; i < count; ++i) {
        if (cascadeEmitters) {
            Light l = lights[first + i];
            float reach = cascadeLitReach(l, s);
            if (reach >= 0.0f && length(p - l.positionRadius.xyz) + l.positionRadius.w <= reach) continue;
        }
        float3 l = hp.on ? hairLightDirection(lights[first + i], p) : n;   // a strand: as a surface facing the light
        float w = luminance(meshLightUnshadowed(lights[first + i], p, hp.on ? l : n, hp.on ? l : ng));
        if (w <= 0.0f) continue;
        if (pick.offer(w)) { picked = i; pickedWeight = w; }
    }
    float2 r = rng.next2();
    float3 result = float3(0.0f);
    if (picked < count) {
        float3 target;
        Light light = lights[first + picked];
        if (hp.on) {
            // A strand: the light a surface facing the light would get, through the hair's BSDF toward the sample.
            float3 l = hairLightDirection(light, p);
            result = sampleMeshLight(light, p, l, l, r, s, target) * (pick.total / pickedWeight);
            float3 wi = normalize(target - p);
            result *= M_PI_F * (hairScatter(hp, wi) + hairMultiple(hp, wi)) / hp.albedo;
        } else {
            result = sampleMeshLight(light, p, n, ng, r, s, target) * (pick.total / pickedWeight);
        }
        if (cascadeEmitters) {
            float reach = cascadeLitReach(light, s);
            if (reach >= 0.0f && length(target - p) <= 0.99f * reach) result = float3(0.0f);   // the cascades' part
        }
        if (any(result > 0.0f) && !isVisible(hairOrSurface(hp, sp.xyz, n, p, target), target, accel)) result = float3(0.0f);
    }
    result *= fireflyScale(u, luminance(result), 4.0f * FIREFLY_CLAMP);
    direct.write(direct.read(tid) + float4(result, 0.0f), tid);
}
