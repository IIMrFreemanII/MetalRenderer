// ---------------------------------------------------------------------------------------------
// 1f. Sampled direct light (DirectLightMode.sampled, Auto above Scene.lightTableThreshold): direct light from every light,
//     analytic and emissive-mesh, at a cost that depends on the resolution, not on the light count. Per ray a pixel picks
//     one light sample by RIS among `candidates` draws (the light grid's, then the light table's) and the suns, with one
//     shadow ray. Nothing is kept between frames or pixels: MetalFX's denoiser or SVGF averages the result, and the
//     composite needs no loop over the lights. Writes diffuse light (albedo divided out) to `direct`, and specular light
//     for the reflection pass.
// ---------------------------------------------------------------------------------------------

struct SampledLightParams {
    uint4  config;   // x = candidates, y = rays
    float4 tuning;   // x = firefly clamp (0 = off)
};

kernel void sampledLightsKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      accel      [[buffer(1)]],
                                device const InstanceData*       instances  [[buffer(6)]],
                                constant SceneShading&           shading    [[buffer(7)]],
                                device const Light*              lights     [[buffer(8)]],   // + the light table
                                constant SampledLightParams&     lp         [[buffer(9)]],
                                device const RegirReservoir*     regirGrid  [[buffer(11)]],  // the light grid (ReGIR)
                                constant RegirParams&            regir      [[buffer(12)]],
                                texture2d<float, access::read>   surfacePos [[texture(0)]],
                                texture2d<float, access::read>   normalDepth [[texture(1)]],
                                texture2d<float, access::read>   geoNormal  [[texture(2)]],
                                texture2d<float, access::read>   albedo     [[texture(3)]],
                                texture2d<float, access::read>   material   [[texture(4)]],
                                texture2d<float, access::write>  outDirect  [[texture(5)]],
                                texture2d<float, access::write>  outSpecular [[texture(6)]],  // with FLAG_SPECULAR
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    bool specular = flagOn(u.flags, FLAG_SPECULAR);
    float4 pos = surfacePos.read(tid);
    if (pos.w <= 0.0f) {   // sky or an emitter: nothing to light
        outDirect.write(float4(0.0f), tid);
        if (specular) outSpecular.write(float4(0.0f), tid);
        return;
    }
    ShadingPoint sp;
    sp.n = normalDepth.read(tid).xyz;
    float4 g = geoNormal.read(tid);
    sp.ng = g.xyz;
    sp.p = pos.xyz + sp.ng * RAY_EPSILON;
    sp.v = normalize(u.camPos.xyz - pos.xyz);
    float4 a = albedo.read(tid);
    sp.albedo = max(a.rgb, float3(0.05f));
    sp.hair = hairFromGBuffer(a, g.w, sp.n, sp.v);
    sp.f0 = float3(0.0f);
    sp.roughness = 1.0f;
    sp.specular = false;
    if (specular) {
        float4 m = material.read(tid);
        sp.f0 = m.rgb; sp.roughness = m.a; sp.specular = any(m.rgb > 0.0f);
    }
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    device const LightTableEntry* entries = lightTableEntries(lights, u.lightCount);
    device const TriangleInfo* tris = lightTableTriangles(lights, u.lightCount, u.lightTable.x);
    Rng rng;
    rng.state = pixelSeed(tid, u.frameIndex, SEED_SAMPLED_LIGHTS);

    uint M = u.lightTable.x > 0 ? lp.config.x : 0u, rays = lp.config.y;
    RegirCell cell;
    uint Mg = regirShare(s, sp.p, M, cell);   // from the light grid, then the table, then the suns
    float3 diffuse = float3(0.0f), spec = float3(0.0f);
    for (uint ray = 0; ray < rays; ++ray) {
        uint picked = ELEMENT_NONE;
        float2 pickedUV = float2(0.0f);
        float wSum = 0.0f, pickedTarget = 0.0f;
        for (uint k = 0; k < M + u.lightTable.y; ++k) {
            LightCandidate c;
            if (!lightCandidate(k, Mg, M, u.lightTable, entries, sp.p, s, rng, c)) continue;
            float t = lightSampleTarget(evalLightSample(c.element, c.uv, sp, s, lights, tris, false, false), sp);
            float w = lightCandidateWeight(k, M, t, c.W);
            if (w <= 0.0f) continue;
            wSum += w;
            if (rng.next() * wSum < w) { picked = c.element; pickedUV = c.uv; pickedTarget = t; }
        }
        if (picked == ELEMENT_NONE || pickedTarget <= 0.0f) continue;
        LightSampleEval e = evalLightSample(picked, pickedUV, sp, s, lights, tris, false, true);
        if (!isVisible(shadowOrigin(sp, e.target), e.target, accel)) continue;
        float W = wSum / pickedTarget;
        diffuse += e.diffuse * W;
        spec += e.specular * W;
    }
    float inv = 1.0f / float(max(rays, 1u));
    diffuse *= inv; spec *= inv;
    float clampScale = fireflyScale(luminance(diffuse) + luminance(spec), lp.tuning.x);
    outDirect.write(roundToHalf(float4(diffuse * clampScale, 1.0f)), tid);
    if (specular) outSpecular.write(roundToHalf(float4(spec * clampScale, 1.0f)), tid);
}
