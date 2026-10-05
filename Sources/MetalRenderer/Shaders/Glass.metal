// ---------------------------------------------------------------------------------------------
// 1b. Window glass (GLASS scenes: instances with MASK_GLASS, whose material's albedo is the tint). Thin and clear or
//     tinted: camera rays see through it and see its mirror reflection; to shadow, GI and reflection rays it isn't
//     there, so light goes through windows. traceKernel doesn't meet it either: its G-buffer holds the surface
//     behind the pane, which every later pass lights and filters as usual. This kernel runs right after it and
//     finds the panes in front of that surface (at most 4): what comes through them, (1 - Fresnel) x tint each, is
//     folded into what the composite multiplies and adds (the albedo, F0 and emission, the sky's light among it),
//     and the first pane's reflection is added to the emission. A kernel of its own because traceKernel is short of
//     registers: with the panes' rays in it, every pixel of a scene with glass traced at a third of the speed, and
//     with only the ray through the panes in it (one call in a loop) the two kernels together were still slower.
//     Not here: refraction, tinted shadows, and a filter for the reflection's one light sample (the upscaler averages it).
// ---------------------------------------------------------------------------------------------

// What a pane reflects along `dir` from `p` on it: the sky, or the surface its mirror ray hits, with that surface's
// emission, one light sample and a stand-in for its indirect light (as a reflection's hit off screen gets).
float3 glassReflection(constant Uniforms& u, SCENE_ACCEL accel, thread const SceneData& s, float3 p, float3 dir,
                       thread Sampler& rng) {
    Surface h = traceSurface(makeRay(p, dir, 0.0f, INFINITY), MASK_GEOMETRY, accel, s, GI_RAY_SPREAD);
    if (!h.hit) return skyRadiance(u, s, dir, 0.0f);
    float3 hng, hn;
    orientNormals(h, dir, hng, hn);
    float3 hp = h.position + hng * RAY_EPSILON;
    float3 albedo = hitAlbedo(h);
    float3 L = albedo * skyAmbient(u, s) * 0.3f;
    if (LIGHT_TABLE) {
        Rng r;
        r.state = pcgHash(as_type<uint>(rng.next()) + 977u);
        L += albedo * sampleLightsRIS(s.lights, u.lightCount, u.lightTable, hp, hn, hng, 4, r, accel, s);
    } else if (u.lightCount > 0) {
        float pdf;
        float uPick = rng.next();
        float uSubset = u.lightCount > LIGHT_CANDIDATES ? rng.next() : 0.0f;
        uint li = pickLight(s.lights, u.lightCount, hp, hn, hng, uPick, uSubset, pdf);
        float2 r = rng.next2();
        if (li < u.lightCount) L += albedo * sampleLight(s.lights[li], hp, hn, hng, r, accel, s) / pdf;
    }
    // Nothing filters this but the upscaler: among many lights one sample is a speck on a dark pane, so it is held low.
    return h.emission + L * fireflyScale(u, luminance(L), LIGHT_TABLE ? 1.0f : FIREFLY_CLAMP);
}

kernel void glassKernel(constant Uniforms&               u          [[buffer(0)]],
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
                        texture2d<float, access::read>       normalDepth [[texture(0)]],
                        texture2d<float, access::read_write> albedo      [[texture(1)]],
                        texture2d<float, access::read_write> emission    [[texture(2)]],
                        texture2d<float, access::read_write> material    [[texture(3)]],   // with FLAG_SPECULAR
                        texture2d<float, access::read>       blueNoise   [[texture(4)]],
                        uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);

    // The camera ray again, as far as the surface the trace found (the sky: no end).
    float3 dir = primaryDirection(u, tid), origin = u.camPos.xyz;
    float viewDepth = normalDepth.read(tid).w;
    float reach = viewDepth > 0.0f ? viewDepth / dot(dir, u.camForward.xyz) - 2.0f * RAY_EPSILON : INFINITY;
    float3 through = float3(1.0f), light = float3(0.0f);
    bool glazed = false;
    for (uint pane = 0; pane < 4 && reach > 0.0f; ++pane) {
        Surface g = traceSurface(makeRay(origin, dir, 0.0f, reach), MASK_GLASS, accel, s, GI_RAY_SPREAD);
        if (!g.hit) break;
        float3 gng, gn;
        orientNormals(g, dir, gng, gn);
        float fresnel = 0.04f + 0.96f * pow(1.0f - saturate(dot(-dir, gn)), 5.0f);
        if (!glazed) {
            // Dimensions past the reflections'.
            Sampler rng = makeSampler(blueNoise, u, tid, 52, pcgHash(tid.x * 3643u + pcgHash(tid.y + pcgHash(u.frameIndex * 59u + 5u))));
            light = fresnel * glassReflection(u, accel, s, g.position + gng * RAY_EPSILON, reflect(dir, gn), rng);
        }
        glazed = true;
        through *= (1.0f - fresnel) * g.albedo;
        reach -= distance(g.position, origin) + RAY_EPSILON;
        origin = g.position + dir * RAY_EPSILON;
    }
    if (!glazed) return;
    albedo.write(float4(albedo.read(tid).rgb * through, 1.0f), tid);
    emission.write(float4(emission.read(tid).rgb * through + light, 1.0f), tid);
    if (flagOn(u.flags, FLAG_SPECULAR)) {
        float4 m = material.read(tid);
        material.write(float4(m.rgb * through, m.a), tid);
    }
}
