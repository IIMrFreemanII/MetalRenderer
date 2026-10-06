// ---------------------------------------------------------------------------------------------
// 1. Trace kernel: G-buffer + direct light + path traced indirect light (1 sample per pixel)
// ---------------------------------------------------------------------------------------------

// traceKernel's own flags, made from the uniforms (Uniforms.tracePassFlags in GPUTypes.swift makes the same word to compile in).
constant uint TRACE_BOUNCES = 1;       // the path tracer's indirect light (Uniforms.bounces > 0)
constant uint TRACE_MANY_LIGHTS = 2;   // more analytic lights than SHADOW_GROUPS
inline uint tracePassFlags(constant Uniforms& u) {
    return (u.bounces > 0 ? TRACE_BOUNCES : 0u) | (u.lightGroupEnd.w > SHADOW_GROUPS ? TRACE_MANY_LIGHTS : 0u);
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
                        device RasterCounters*      rasterCounters [[buffer(13)]],  // with FLAG_VIS_BUFFER: RasterTraced
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
                        texture2d<float, access::write>  outVisibility  [[texture(12)]],  // per light group: visibility
                        texture2d<float, access::write>  outBlocker     [[texture(13)]],  // per light group: penumbra half width, 0 = none
                        texture2d<float, access::write>  outMaterial    [[texture(14)]],  // with FLAG_SPECULAR: rgb = F0, a = roughness
                        texture2d<uint, access::read>    visBuffer      [[texture(15)]],  // with FLAG_VIS_BUFFER: instance, triangle
                        uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;

    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    bool specular = flagOn(u.flags, FLAG_SPECULAR);

    Sampler rng = makeSampler(blueNoise, u, tid, 0, pixelSeed(tid, u.frameIndex, SEED_TRACE));

    // Primary ray: traced, or with FLAG_VIS_BUFFER met with the triangle the raster drew at this pixel (Raster.metal),
    // and traced as well, up to that triangle, when something in view wasn't drawn (RasterTraced: the lists were full).
    float2 size = float2(u.width, u.height);
    float3 dir = primaryDirection(u, tid);
    Ray primary = makeRay(u.camPos.xyz, dir, 0.0f, INFINITY);
    // A rotating eighth of the pixels tells the texture streamer which mip levels they need.
    bool recordTextures = ((tid.x + 3u * tid.y + u.frameIndex) & 7u) == 0u;
    // Window glass isn't met here: glassKernel adds it over the surface behind it.
    uint primaryMask = GLASS ? MASK_ALL & ~MASK_GLASS : MASK_ALL;
    Hit hit;
    if (!flagOn(u.flags, FLAG_VIS_BUFFER) || !visibilityHit(visBuffer.read(tid).xy, primary, accel, s, hit)) {
        hit = intersectClosest(primary, primaryMask, accel);
    } else if (atomic_load_explicit(rasterTraced(rasterCounters), memory_order_relaxed) != 0u) {
        Ray nearer = primary;
        nearer.tmax = hit.distance;
        Hit traced = intersectClosest(nearer, primaryMask, accel);
        if (traced.hit) hit = traced;
    }
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
        float4 skyHere = skySample(u.flags, u.skyColor.rgb, s, dir, 0.0f);
        float3 sky = skyHere.rgb;
        for (uint k = 0; k < sunDiscCount(u); ++k) sky += sunDisc(lights[sunDiscLight(u, k)], dir, u.flags, skyHere.a);
        outEmission.write(float4(sky, 1.0f), tid);
        outMotion.write(float4(0.0f), tid);
        outDirect.write(float4(0.0f), tid);
        outIndirect.write(float4(0.0f), tid);
        outSurfacePos.write(float4(0.0f), tid);
        outGeoNormal.write(float4(0.0f), tid);
        outVisibility.write(float4(0.0f), tid);
        outBlocker.write(float4(0.0f), tid);
        if (specular) outMaterial.write(float4(0.0f), tid);
        return;
    }

    float3 ng, n;
    orientNormals(sf, dir, ng, n);
    if (specular) outMaterial.write(float4(sf.f0, max(sf.roughness, MIN_ROUGHNESS)), tid);
    float viewDepth = dot(sf.position - u.camPos.xyz, u.camForward.xyz);
    outNormalDepth.write(float4(n, viewDepth), tid);
    outGeoNormal.write(float4(ng, 0.0f), tid);
    outAlbedo.write(float4(sf.albedo, 1.0f), tid);
    outEmission.write(float4(sf.emission, 1.0f), tid);

    // Motion vector: project where this surface point was last frame into last frame's camera.
    // The denoiser wants the index of the previous frame's pixel, whose sample was taken at its center + that frame's jitter.
    float prevDepth;
    float2 prevPixel = projectToPixel(sf.prevPosition - u.prevCamPos.xyz, u.prevCamRight, u.prevCamUp, u.prevCamForward, size, prevDepth);
    outMotion.write(float4(prevPixel - 0.5f - u.jitter.zw, prevDepth, prevDepth > 0.0f ? 1.0f : 0.0f), tid);
    if (upscale) {
        // MetalFX wants unjittered motion in pixels, from this pixel to where it was last frame.
        float curDepth;
        float2 curPixel = projectToPixel(sf.position - u.camPos.xyz, u.camRight, u.camUp, u.camForward, size, curDepth);
        outDeviceDepth.write(float4(NEAR_PLANE / max(viewDepth, NEAR_PLANE)), tid);
        outPixelMotion.write(float4(prevDepth > 0.0f ? prevPixel - curPixel : float2(0.0f), 0.0f, 0.0f), tid);
    }

    // Emissive surfaces (the light spheres) are not lit.
    if (any(sf.emission > 0.0f)) {
        outDirect.write(float4(0.0f), tid);
        outIndirect.write(float4(0.0f), tid);
        outSurfacePos.write(float4(sf.position, 0.0f), tid);
        outVisibility.write(float4(0.0f), tid);
        outBlocker.write(float4(0.0f), tid);
        return;
    }
    // A raster cluster's triangle (RasterClusters) is from the raster's cut, not the BLAS the rays meet. With
    // METALRENDERER_RASTER_VG_BIAS (camForward.w; off by default) every ray from here, this kernel's and the later
    // passes' (they start at surfacePos), leaves that many times the cluster's simplification error in front of it.
    if (hit.cluster != HIT_NO_CLUSTER && u.camForward.w > 0.0f) {
        float4x4 m = instanceRecord(s.instances, hit.instance).transform;
        float scale = max(length(m[0].xyz), max(length(m[1].xyz), length(m[2].xyz)));
        sf.position += ng * (u.camForward.w * scale * as_type<float>(accel.clusters[hit.cluster].x));
    }
    outSurfacePos.write(float4(sf.position, float(sf.instanceId + 1)), tid);

    float3 p = sf.position + ng * RAY_EPSILON;   // offset along the true normal so the origin is never below the triangle

    // Direct light. The shadow denoiser filters visibility per light group (one rgba channel each; up to 4 lights,
    // each light is its own group) and multiplies it back onto the group's exact unshadowed light in the composite
    // pass. Each channel also gets the penumbra half width of its occluded samples, which sizes the filter.
    float3 direct = float3(0.0f);
    float4 visibility = float4(0.0f), blocker = float4(0.0f);
    // Analytic lights only (the first lightGroupEnd.w): meshLightsKernel samples the emissive-mesh lights.
    uint analyticLights = u.lightGroupEnd.w;
    uint own = tracePassFlags(u);
    bool manyLights = (passOn(own, TRACE_MANY_LIGHTS) || flagOn(u.flags, FLAG_RESTIR)) && !flagOn(u.flags, FLAG_ALL_LIGHTS);
    if (!manyLights) {
        // One shadow ray per light. A channel shared by several lights gets their luminance-weighted visibility.
        float4 unshadowedSum = float4(0.0f), blockerWeight = float4(0.0f);
        for (uint i = 0; i < analyticLights; ++i) {
            float2 r = rng.next2();
            float3 unshadowed = lightUnshadowed(lights[i], p, n, ng);
            if (all(unshadowed <= 0.0f)) continue;   // light behind the surface: it shadows itself
            float b;
            float v = shadowVisible(u.flags, s.vsm, i, lights[i], p, ng, lightShadowTarget(lights[i], p, r), accel, b)
                    ? sunVisibilityScale(lights[i], p, s) : 0.0f;
            direct += unshadowed * v;
            uint g = lightGroup(lights[i]);
            float w = luminance(unshadowed);
            unshadowedSum[g] += w;
            visibility[g] += w * v;
            if (b > 0.0f) { blocker[g] += w * penumbraWidth(lights[i], p, b); blockerWeight[g] += w; }
        }
        visibility = select(float4(0.0f), visibility / unshadowedSum, unshadowedSum > 0.0f);
        blocker = select(float4(0.0f), blocker / blockerWeight, blockerWeight > 0.0f);
    }
    // With more lights, manyLightsKernel computes direct light, visibility and penumbrae after this kernel (ReSTIR:
    // restirSpatialKernel the direct light).
    if (!manyLights) {
        outVisibility.write(visibility, tid);
        outBlocker.write(roundToHalf(blocker), tid);
    }

    // Indirect light: a short diffuse path with next-event estimation at every bounce.
    float3 indirect = float3(0.0f);
    if (passOn(own, TRACE_BOUNCES)) {
        float3 throughput = float3(1.0f);
        float3 origin = p;
        float3 normal = n, geomNormal = ng;
        for (uint b = 0; b < u.bounces; ++b) {
            float3 d = sampleBounce(normal, geomNormal, rng.next2());
            Ray r = makeRay(origin, d, 0.0f, INFINITY);
            Surface h = traceSurface(r, MASK_GEOMETRY, accel, s, GI_RAY_SPREAD);
            if (!h.hit) {
                indirect += throughput * skyRadiance(u, s, d, 2.0f);
                break;
            }
            float3 hng, hn;
            orientNormals(h, d, hng, hn);
            indirect += throughput * giEmission(h);
            throughput *= hitAlbedo(h);   // Lambert BRDF * cos / cosine pdf = albedo (+ specular, as diffuse)
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
// 1c. Direct light with many lights (more than SHADOW_GROUPS, unless FLAG_ALL_LIGHTS), after traceKernel, from
//     its G-buffer. Per light group (one shadow-denoiser channel each): one light picked by unshadowed luminance
//     over all the group's lights (weighted reservoir, no rays), and one shadow ray to it, so the cost is 4 rays
//     per pixel whatever the light count. The 0/1 visibility is an unbiased estimate of the group's luminance-
//     weighted visibility, which is what the denoiser filters (the composite multiplies it onto the group's exact
//     unshadowed light); the raw direct light is the one-sample estimate unshadowed * visibility / pdf.
//     raysPerGroup = 2 picks two lights per group (8 rays): half the variance, half the flicker, ~4 ms more here.
//     Every light is weighed (a subset of candidates under-represents each pixel's dominant light, which biased
//     the filtered visibility by 7 dB at 128 lights). Its own kernel because inside traceKernel, whose register
//     use limits occupancy, the same loop cost 4x as much.
// ---------------------------------------------------------------------------------------------

constant uint MAX_RAYS_PER_GROUP = 2;

kernel void manyLightsKernel(constant Uniforms&               u          [[buffer(0)]],
                             SCENE_ACCEL                      accel      [[buffer(1)]],
                             constant SceneShading&           shading    [[buffer(7)]],   // the sky: cloud shadows
                             device const Light*              lights     [[buffer(8)]],
                             texture2d<float, access::read>   surfacePos [[texture(0)]],   // w = instance + 1, 0 = unlit
                             texture2d<float, access::read>   normalDepth [[texture(1)]],
                             texture2d<float, access::read>   geoNormal  [[texture(2)]],
                             texture2d<float, access::read>   blueNoise  [[texture(3)]],
                             texture2d<float, access::write>  outDirect  [[texture(4)]],
                             texture2d<float, access::write>  outVisibility [[texture(5)]],
                             texture2d<float, access::write>  outBlocker [[texture(6)]],
                             constant uint&                   raysPerGroup [[buffer(9)]],   // 1 or 2
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    if (sp.w <= 0.0f) return;   // sky and emitters: traceKernel wrote zeros
    float3 n = normalDepth.read(tid).xyz, ng = geoNormal.read(tid).xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;

    // Other blue-noise windows than traceKernel's.
    Sampler rng = makeSampler(blueNoise, u, tid, 64, pixelSeed(tid, u.frameIndex, SEED_MANY_LIGHTS));

    // The two rays' picks ride in the lanes of float2 / uint2 (one ray leaves the second lane unused): arrays indexed by
    // the ray would sit in memory, inside the loop over the lights.
    uint rays = clamp(raysPerGroup, 1u, MAX_RAYS_PER_GROUP);
    float4 sel0 = float4(rng.next2(), rng.next2()), sel1 = float4(0.0f);
    if (rays > 1) sel1 = float4(rng.next2(), rng.next2());
    float3 direct = float3(0.0f);
    float4 visibility = float4(0.0f), blocker = float4(0.0f), blockerCount = float4(0.0f);
    uint start = 0;
    for (uint g = 0; g < SHADOW_GROUPS; ++g) {
        uint end = u.lightGroupEnd[g];
        float4 channel = groupMask(g);
        float total = 0.0f;
        float2 s = min(float2(dot(sel0, channel), dot(sel1, channel)), 0.99999f), pickedWeight = float2(0.0f);
        uint2 picked = uint2(end);
        for (uint i = start; i < end; ++i) {
            float w = luminance(lightUnshadowed(lights[i], p, n, ng));
            if (w <= 0.0f) continue;
            total += w;
            float q = w / total;
            bool2 take = s < q;
            picked = select(picked, uint2(i), take);
            pickedWeight = select(pickedWeight, float2(w), take);
            s = select((s - q) / (1.0f - q), s / q, take);
        }
        for (uint k = 0; k < rays; ++k) {
            float2 r = rng.next2();   // drawn even for empty groups, so the sample dimensions stay fixed
            uint pick = k == 0 ? picked.x : picked.y;
            if (pick >= end) continue;
            Light light = lights[pick];
            float b;
            bool visible = shadowVisible(u.flags, shading.vsm, pick, light, p, ng, lightShadowTarget(light, p, r), accel, b);
            float cloud = visible ? sunVisibilityScale(light, p, shading) : 0.0f;
            visibility += channel * (cloud / float(rays));
            if (b > 0.0f) { blocker += channel * penumbraWidth(light, p, b); blockerCount += channel; }
            if (visible) direct += lightUnshadowed(light, p, n, ng) * (cloud * total / ((k == 0 ? pickedWeight.x : pickedWeight.y) * float(rays)));
        }
        start = end;
    }
    blocker = select(float4(0.0f), blocker / blockerCount, blockerCount > 0.0f);
    outDirect.write(float4(direct, 1.0f), tid);
    outVisibility.write(visibility, tid);
    outBlocker.write(roundToHalf(blocker), tid);
}

// 1d. The same with light reuse (RenderSettings.manyLightReuse, ReSTIR-style temporal resampling): each group keeps
//     last frame's pick in a reservoir (light, confidence M, contribution weight W), reprojected with the motion
//     vectors. This frame's exact pick and the reservoir's light (re-weighed here, where the lights are now) are
//     resampled in proportion to their weights, and the winner gets the shadow ray. Every pick already follows the
//     unshadowed light exactly, so reuse can't sharpen the distribution; what it does is keep a pixel's pick from
//     changing every frame, so a still image flickers less: a third less at 4 frames, for about 0.7 dB of accuracy on
//     still frames (stress scene). Its own kernel because merged into manyLightsKernel the extra state cost 0.75 ms
//     with reuse off. Visibility reuse (storing occluded picks with W = 0, so reservoirs drift toward visible lights)
//     cut flicker as much but darkened penumbrae and lagged: -3 dB still, -5 dB moving.
// ---------------------------------------------------------------------------------------------

kernel void manyLightsReuseKernel(constant Uniforms&               u          [[buffer(0)]],
                             SCENE_ACCEL                      accel      [[buffer(1)]],
                             constant SceneShading&           shading    [[buffer(7)]],   // the sky: cloud shadows
                             device const Light*              lights     [[buffer(8)]],
                             texture2d<float, access::read>   surfacePos [[texture(0)]],   // w = instance + 1, 0 = unlit
                             texture2d<float, access::read>   normalDepth [[texture(1)]],
                             texture2d<float, access::read>   geoNormal  [[texture(2)]],
                             texture2d<float, access::read>   blueNoise  [[texture(3)]],
                             texture2d<float, access::write>  outDirect  [[texture(4)]],
                             texture2d<float, access::write>  outVisibility [[texture(5)]],
                             texture2d<float, access::write>  outBlocker [[texture(6)]],
                             texture2d<float, access::read>   motion     [[texture(7)]],
                             texture2d<float, access::read>   prevND     [[texture(8)]],
                             texture2d<uint, access::read>    prevReservoir [[texture(9)]],
                             texture2d<float, access::read>   prevReservoirW [[texture(10)]],
                             texture2d<uint, access::write>   outReservoir [[texture(11)]],
                             texture2d<float, access::write>  outReservoirW [[texture(12)]],
                             constant uint4&                  config     [[buffer(9)]],   // y = reuse frames, z = 1 if last frame stored picks
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    uint maxM = max(config.y, 1u);
    if (sp.w <= 0.0f) {   // sky and emitters: traceKernel wrote zeros
        outReservoir.write(uint4(0xFFFFu), tid);
        return;
    }
    float4 nd = normalDepth.read(tid);
    float3 n = nd.xyz, ng = geoNormal.read(tid).xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;

    // Other blue-noise windows than traceKernel's.
    Sampler rng = makeSampler(blueNoise, u, tid, 64, pixelSeed(tid, u.frameIndex, SEED_MANY_LIGHTS));

    float3 direct = float3(0.0f);
    float4 visibility = float4(0.0f), blocker = float4(0.0f);

    uint4 prevPick = uint4(0xFFFFu);
    float4 prevW = float4(0.0f);
    int2 q = config.z != 0 ? reprojectNearest(u, motion.read(tid), n, prevND) : int2(-1);
    if (q.x >= 0) {
        prevPick = prevReservoir.read(uint2(q));
        prevW = prevReservoirW.read(uint2(q));
    }
    float4 sel = float4(rng.next2(), rng.next2());
    float4 reuseSel = float4(rng.next2(), rng.next2());
    uint4 outPick = uint4(0xFFFFu);
    float4 outW = float4(0.0f);
    uint start = 0;
    for (uint g = 0; g < SHADOW_GROUPS; ++g) {
        uint end = u.lightGroupEnd[g];
        float4 channel = groupMask(g);
        bool4 here = uint4(g) == uint4(0u, 1u, 2u, 3u);
        float2 r = rng.next2();
        // This frame's candidate: exact pick over the group's lights (pdf = weight / total, so W = total / weight).
        float pickedWeight = 0.0f;
        StreamPick pick = streamPick(dot(sel, channel));
        uint picked = end;
        for (uint i = start; i < end; ++i) {
            float w = luminance(lightUnshadowed(lights[i], p, n, ng));
            if (w <= 0.0f) continue;
            if (pick.offer(w)) { picked = i; pickedWeight = w; }
        }
        float weightSum = picked < end ? pick.total : 0.0f;   // M = 1 * target(pick) * W
        float M = 1.0f;
        uint y = picked;
        float targetY = pickedWeight;
        // Last frame's pick, re-weighed at this pixel with the lights where they are now.
        uint prevG = groupElement(prevPick, g);
        uint prevLight = prevG & 0xFFFFu;
        if (prevLight >= start && prevLight < end) {
            float Mp = min(float(prevG >> 16), float(maxM));
            float targetP = luminance(lightUnshadowed(lights[prevLight], p, n, ng));
            float wp = Mp * targetP * dot(prevW, channel);
            M += Mp;
            if (wp > 0.0f) {
                weightSum += wp;
                if (dot(reuseSel, channel) * weightSum < wp) { y = prevLight; targetY = targetP; }
            }
        }
        start = end;
        if (y >= end || targetY <= 0.0f || weightSum <= 0.0f) {
            outPick = select(outPick, uint4(y < end ? (y | (uint(min(M, 65535.0f)) << 16)) : 0xFFFFu), here);
            continue;
        }
        float W = weightSum / (M * targetY);
        Light light = lights[y];
        float b;
        bool visible = shadowVisible(u.flags, shading.vsm, y, light, p, ng, lightShadowTarget(light, p, r), accel, b);
        float cloud = visible ? sunVisibilityScale(light, p, shading) : 0.0f;
        // Estimate of the group's luminance-weighted visibility: target * V * W / total (= V for a fresh pick).
        visibility = select(visibility, float4(visible && pick.total > 0.0f ? saturate(cloud * targetY * W / pick.total) : 0.0f), here);
        blocker = select(blocker, float4(penumbraWidth(light, p, b)), here);
        if (visible) direct += lightUnshadowed(light, p, n, ng) * (cloud * W);
        outPick = select(outPick, uint4(y | (uint(min(M, float(maxM))) << 16)), here);
        outW = select(outW, float4(W), here);
    }
    outReservoir.write(outPick, tid);
    outReservoirW.write(outW, tid);

    outDirect.write(float4(direct, 1.0f), tid);
    outVisibility.write(visibility, tid);
    outBlocker.write(roundToHalf(blocker), tid);
}

// ---------------------------------------------------------------------------------------------
// 1e. Emissive-mesh lights (the lights after lightGroupEnd.w), after the analytic direct light: one light picked by
//     its proxy's unshadowed luminance, one point on one of its triangles picked by emitted power, one shadow ray.
//     The estimate is unbiased but noisy, so it doesn't go through the shadow denoiser (whose exact unshadowed
//     light a mesh doesn't have): with it, SVGF denoises outMeshDirect on its own and the composite adds it; without
//     it (addToDirect = 1), the estimate is added to the direct light, which SVGF or accumulation then handle.
// ---------------------------------------------------------------------------------------------

kernel void meshLightsKernel(constant Uniforms&                    u          [[buffer(0)]],
                             SCENE_ACCEL                           accel      [[buffer(1)]],
                             device const InstanceData*            instances  [[buffer(6)]],
                             constant SceneShading&                shading    [[buffer(7)]],
                             device const Light*                   lights     [[buffer(8)]],
                             constant uint&                        addToDirect [[buffer(9)]],
                             texture2d<float, access::read>        surfacePos [[texture(0)]],   // w = instance + 1, 0 = unlit
                             texture2d<float, access::read>        normalDepth [[texture(1)]],
                             texture2d<float, access::read>        geoNormal  [[texture(2)]],
                             texture2d<float, access::read>        blueNoise  [[texture(3)]],
                             texture2d<float, access::read_write>  direct     [[texture(4)]],
                             texture2d<float, access::write>       outMeshDirect [[texture(5)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    uint first = u.lightGroupEnd.w, count = u.lightCount - first;
    if (sp.w <= 0.0f || count == 0) { outMeshDirect.write(float4(0.0f), tid); return; }   // sky and emitters
    float3 n = normalDepth.read(tid).xyz, ng = geoNormal.read(tid).xyz;
    float3 p = sp.xyz + ng * RAY_EPSILON;

    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    // Other blue-noise windows than the trace and many-lights kernels'.
    Sampler rng = makeSampler(blueNoise, u, tid, 96,
                              pcgHash(tid.x * 31u + pcgHash(tid.y + pcgHash(u.frameIndex ^ 0x5bd1e995u))));

    // One light by its proxy's luminance (weighted reservoir over all of them: there are few).
    float pickedWeight = 0.0f;
    StreamPick pick = streamPick(rng.next());
    uint picked = count;
    for (uint i = 0; i < count; ++i) {
        float w = luminance(meshLightUnshadowed(lights[first + i], p, n, ng));
        if (w <= 0.0f) continue;
        if (pick.offer(w)) { picked = i; pickedWeight = w; }
    }
    float2 r = rng.next2();
    float3 result = float3(0.0f);
    if (picked < count) {
        float3 target;
        result = sampleMeshLight(lights[first + picked], p, n, ng, r, s, target) * (pick.total / pickedWeight);
        if (any(result > 0.0f) && !isVisible(p, target, accel)) result = float3(0.0f);
    }
    result *= fireflyScale(u, luminance(result), 4.0f * FIREFLY_CLAMP);
    outMeshDirect.write(roundToHalf(float4(result, 1.0f)), tid);
    if (addToDirect != 0) direct.write(direct.read(tid) + float4(result, 0.0f), tid);
}
