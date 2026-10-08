// ---------------------------------------------------------------------------------------------
// 1a. Liquids (LIQUID scenes: instances with MASK_LIQUID, a liquid's surface, FluidSurface.swift): a dielectric that
//     absorbs. Its material: albedo.rgb = absorption (1/m, Beer-Lambert), albedo.a = index of refraction,
//     emission.a = roughness (Scene.addLiquidMaterial).
//
//     liquidKernel runs before traceKernel: it follows the camera ray into the liquid, bending it at each surface it
//     crosses (Snell; total internal reflection turns it back in) and absorbing along the way inside (up to 4
//     crossings), and leaves traceKernel the ray that comes out: what the trace then finds, lights and filters as any
//     surface (the floor under the water, a box inside it), is what is seen through the liquid. What came through
//     (Fresnel's share at each crossing, the absorption) and what the entry reflects (the scene in its mirror
//     direction, the lights' highlights) liquidApplyKernel folds into the G-buffer, as glassKernel does a pane's.
//     To shadow and GI rays the liquid isn't there (as window glass isn't): no caustics, no light absorbed on its way in.
// ---------------------------------------------------------------------------------------------

// The share a dielectric surface reflects (unpolarized): cosI from the side the ray comes from, eta = n_from / n_to.
inline float liquidFresnel(float cosI, float eta) {
    float sinT2 = eta * eta * (1.0f - cosI * cosI);
    if (sinT2 >= 1.0f) return 1.0f;
    float cosT = sqrt(1.0f - sinT2);
    float rs = (eta * cosI - cosT) / (eta * cosI + cosT);
    float rp = (cosI - eta * cosT) / (cosI + eta * cosT);
    return 0.5f * (rs * rs + rp * rp);
}

// A liquid's material (absorption, index of refraction, roughness), from the instance its surface is.
inline float4 liquidMaterial(thread const SceneData& s, uint instance, thread float& roughness) {
    Material m = s.materials[instanceRecord(s.instances, instance).materialIndex];
    roughness = m.emission.a;
    return m.albedo;
}

// The lights' highlights on a liquid's surface at p (normal n, toward the eye v), unshadowed.
inline float3 liquidHighlights(thread const SceneData& s, float3 p, float3 n, float3 v, float f0, float roughness) {
    float3 sum = float3(0.0f);
    for (uint i = 0; i < min(s.lightCount, 8u); ++i) sum += lightSpecular(s.lights[i], p, n, n, v, float3(f0), roughness);
    return sum;
}

kernel void liquidKernel(constant Uniforms&               u          [[buffer(0)]],
                         SCENE_ACCEL                      accel      [[buffer(1)]],
                         device const float3*             positions  [[buffer(2)]],
                         device const float3*             normals    [[buffer(3)]],
                         device const uint*               indices    [[buffer(4)]],
                         device const MeshData*           meshes     [[buffer(5)]],
                         device const InstanceData*       instances  [[buffer(6)]],
                         constant SceneShading&           shading    [[buffer(7)]],
                         device const Light*              lights     [[buffer(8)]],
                         device const RegirReservoir* regirGrid [[buffer(11)]],
                         constant RegirParams&       regir     [[buffer(12)]],
                         texture2d<float, access::write>  outRay      [[texture(0)]],   // xyz = the bent ray's origin, w = 1: bent
                         texture2d<float, access::write>  outDir      [[texture(1)]],   // xyz = its direction, w = the entry's distance
                         texture2d<float, access::write>  outThrough  [[texture(2)]],   // rgb = what comes through
                         texture2d<float, access::write>  outReflect  [[texture(3)]],   // rgb = the entry's reflection
                         texture2d<float, access::read>   blueNoise   [[texture(4)]],
                         uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    float3 dir = primaryDirection(u, tid), origin = u.camPos.xyz;
    // The liquid, unless something is in front of it.
    const uint solid = (MASK_ALL & ~(MASK_GLASS | MASK_LIQUID));
    Hit first = intersectClosest(makeRay(origin, dir, 0.0f, INFINITY), rayMask(MASK_LIQUID, RAY_CAMERA), accel);
    if (first.hit) {
        Hit block = intersectClosest(makeRay(origin, dir, 0.0f, first.distance), rayMask(solid, RAY_CAMERA), accel);
        if (block.hit) first.hit = false;
    }
    if (!first.hit) {
        outRay.write(float4(0.0f), tid);
        return;
    }
    float3 through = float3(1.0f), reflected = float3(0.0f);
    float entry = first.distance;
    bool inside = false;
    float4 medium = float4(0.0f);   // the liquid the ray is in: absorption, index
    for (uint crossing = 0; crossing < 4; ++crossing) {
        // The next surface: a liquid's, or something solid (which ends the walk: the trace takes it from here).
        Surface h = traceSurface(makeRay(origin, dir, 0.0f, INFINITY), rayMask(inside ? (MASK_LIQUID | solid) : MASK_LIQUID | solid,
                                                                                 RAY_SPECULAR), accel, s, GI_RAY_SPREAD);
        bool liquid = h.hit && (instanceRecord(s.instances, h.instanceId).pad0 & MASK_LIQUID) != 0;
        float d = h.hit ? distance(h.position, origin) : 1.0f;
        if (inside) through *= exp(-medium.rgb * d);
        if (!liquid) break;
        float roughness;
        float4 m = liquidMaterial(s, h.instanceId, roughness);
        float3 n = normalize(h.normal);        // outward (FluidSurface: the field falls outward)
        bool entering = dot(dir, n) < 0.0f;
        float3 facing = entering ? n : -n;     // toward where the ray comes from
        float eta = entering ? 1.0f / m.a : m.a;
        float cosI = saturate(dot(-dir, facing));
        float fresnel = liquidFresnel(cosI, eta);
        if (crossing == 0) {
            // The entry's reflection: the scene in its mirror direction, and the lights' highlights.
            Sampler rng = makeSampler(blueNoise, u, tid, 56, pcgHash(tid.x * 5113u + pcgHash(tid.y + pcgHash(u.frameIndex * 61u + 7u))));
            float3 p = h.position + facing * RAY_EPSILON, mirror = reflect(dir, facing);
            float f0 = (m.a - 1.0f) * (m.a - 1.0f) / ((m.a + 1.0f) * (m.a + 1.0f));
            reflected = fresnel * glassReflection(u, accel, s, p, mirror, rng)
                      + liquidHighlights(s, p, facing, -dir, f0, roughness);
        }
        float3 bent = refract(dir, facing, eta);
        if (fresnel >= 1.0f || length_squared(bent) == 0.0f) {
            // Turned back: it stays on the side it came from.
            dir = reflect(dir, facing);
            origin = h.position + facing * RAY_EPSILON;
            continue;
        }
        through *= 1.0f - fresnel;
        dir = normalize(bent);
        origin = h.position - facing * RAY_EPSILON;
        inside = entering;
        medium = entering ? m : float4(0.0f);
    }
    outRay.write(float4(origin, 1.0f), tid);
    outDir.write(float4(dir, entry), tid);
    outThrough.write(float4(through, 0.0f), tid);
    outReflect.write(float4(reflected, 0.0f), tid);
}

// What came through the liquid and its reflection, into the G-buffer of what the trace found behind it.
kernel void liquidApplyKernel(constant Uniforms&                   u        [[buffer(0)]],
                              texture2d<float, access::read_write> albedo   [[texture(0)]],
                              texture2d<float, access::read_write> emission [[texture(1)]],
                              texture2d<float, access::read_write> material [[texture(2)]],   // with FLAG_SPECULAR
                              texture2d<float, access::read>       ray      [[texture(3)]],
                              texture2d<float, access::read>       through  [[texture(4)]],
                              texture2d<float, access::read>       reflect  [[texture(5)]],
                              uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height || ray.read(tid).w == 0.0f) return;
    float3 t = through.read(tid).rgb;
    float4 a = albedo.read(tid);
    albedo.write(float4(a.rgb * t, a.a), tid);
    emission.write(float4(emission.read(tid).rgb * t + reflect.read(tid).rgb, 1.0f), tid);
    if (flagOn(u.flags, FLAG_SPECULAR)) {
        float4 m = material.read(tid);
        material.write(float4(m.rgb * t, m.a), tid);
    }
}
