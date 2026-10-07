// ---------------------------------------------------------------------------------------------
// 3c. Geometry debug views (view modes 8-13), a pass of their own that runs only while one is shown: re-traces the
//     primary rays and colours each pixel by what it hit. Virtual triangles carry their cluster, group, DAG level and
//     index within the cluster (VirtualBLAS packs them into the free w components of e1 / e2; in cluster mode the
//     cluster's pool header holds group and level, VirtualGeometry.upload). Other geometry with levels of detail
//     carries its level in its mesh record (GPUMesh.lod), on both tracers.
// ---------------------------------------------------------------------------------------------

constant uint VIEW_TRIANGLES = 8, VIEW_CLUSTERS = 9, VIEW_GROUPS = 10, VIEW_LOD = 11, VIEW_TRIANGLE_SIZE = 12, VIEW_COST = 13;

inline float3 debugHashColor(uint h) {
    h = pcgHash(h);
    return 0.15f + 0.85f * float3(h & 0xFFu, (h >> 8) & 0xFFu, (h >> 16) & 0xFFu) / 255.0f;
}

// Turbo colour map (polynomial fit, Mikhailov 2019): 0 = dark blue, 0.5 = green, 1 = dark red.
inline float3 debugHeat(float x) {
    x = saturate(x);
    const float4 r4 = float4(0.13572138f, 4.61539260f, -42.66032258f, 132.13108234f);
    const float4 g4 = float4(0.09140261f, 2.19418839f, 4.84296658f, -14.18503333f);
    const float4 b4 = float4(0.10667330f, 12.64194608f, -60.58204836f, 110.36276771f);
    const float2 r2 = float2(-152.94239396f, 59.28637943f);
    const float2 g2 = float2(4.27729857f, 2.82956604f);
    const float2 b2 = float2(-89.90310912f, 27.34824973f);
    float4 v4 = float4(1.0f, x, x * x, x * x * x);
    float2 v2 = v4.zw * v4.z;
    return saturate(float3(dot(v4, r4) + dot(v2, r2), dot(v4, g4) + dot(v2, g2), dot(v4, b4) + dot(v2, b2)));
}

kernel void geometryDebugKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      accel      [[buffer(1)]],
                                device const float3*             positions  [[buffer(2)]],
                                device const float3*             normals    [[buffer(3)]],
                                device const uint*               indices    [[buffer(4)]],
                                device const MeshData*           meshes     [[buffer(5)]],
                                device const InstanceData*       instances  [[buffer(6)]],
                                constant SceneShading&           shading    [[buffer(7)]],
                                texture2d<float, access::write>  output     [[texture(0)]],
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, nullptr, 0u);   // no lights

    float3 dir = primaryDirection(u, tid);
    Ray r = makeRay(u.camPos.xyz, dir, 0.0f, INFINITY);
#if CUSTOM_RT
    uint cost[7] = {0, 0, 0, 0, 0, 0, 0};
    Hit res = intersectClosestCost(r, MASK_ALL, accel, cost);
    // Work of the ray: node visits (both levels) plus triangle tests at half weight, log scale up to ~500.
    float work = float(cost[1] + cost[2]) + 0.5f * float(cost[5]);
    float3 costColor = debugHeat(log2(1.0f + work) / 9.0f);
#else
    Hit res = intersectClosest(r, MASK_ALL, accel);
    float3 costColor = float3(1.0f, 0.0f, 1.0f);   // Metal's traversal can't be counted
#endif
    if (u.viewMode == VIEW_COST) { output.write(float4(costColor, 1.0f), tid); return; }
    if (!res.hit) { output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid); return; }
    if (VOXELS && res.part == HIT_VOXEL) {
        // A far plant's voxels have no triangles to show: flat, in the plant's colour. The LOD view shows the level
        // its rays march (green, orange, red: each twice as coarse; rtVoxels leaves it in barycentrics.x).
        float3 flat = mix(float3(0.2f), debugHashColor(pcgHash(res.instance + 0x51ED27u)), 0.5f);
        if (u.viewMode == VIEW_LOD) flat = debugHeat(0.2f + 0.25f * (res.barycentrics.x + 1.0f));
        output.write(float4(flat, 1.0f), tid);
        return;
    }
    if (SDF_SHAPES && res.part == HIT_SDF) {
        // An SDF shape has no triangles either: shaded by its normal, its materials told apart in the triangles view.
        InstanceData inst = instanceRecord(s.instances, res.instance);
        float3 n = normalize((inst.normalMatrix * float4(sdfOctDecode(res.barycentrics), 0.0f)).xyz);
        float shade = 0.35f + 0.65f * abs(dot(n, dir));
        float3 c = u.viewMode == VIEW_TRIANGLES ? debugHashColor(res.primitive + pcgHash(res.instance + 0x51ED27u)) : float3(0.45f);
        output.write(float4(c * shade, 1.0f), tid);
        return;
    }

    InstanceData inst = instanceRecord(s.instances, res.instance);
    HitVertices hv = fetchHitVertices(res, inst, accel, s);
    float3 e1 = (inst.transform * float4(hv.p[1] - hv.p[0], 0.0f)).xyz, e2 = (inst.transform * float4(hv.p[2] - hv.p[0], 0.0f)).xyz;
    float3 ng = cross(e1, e2);
    float doubleArea = length(ng);
    float shade = doubleArea > 0.0f ? 0.35f + 0.65f * abs(dot(ng / doubleArea, dir)) : 0.35f;

    bool isVirtual = false;
    uint cluster = 0, local = 0, group = 0, level = 0;
#if CUSTOM_RT
    if (res.cluster != HIT_NO_CLUSTER) {
        uint2 rc = accel.clusters[res.cluster];
        uint packed = ((device const uint*)(accel.pool + rc.y))[3];   // group | level << 24
        isVirtual = true;
        cluster = rc.y;                 // its place in the pool: stable while it stays resident
        local = res.primitive;
        group = packed & 0xFFFFFFu;
        level = packed >> 24;
    } else if (inst.pad1 != 0) {
        VGBlas e = accel.vgBlas[inst.pad1 - 1];
        uint a = as_type<uint>(e.tris[3 * res.primitive + 1].w), b = as_type<uint>(e.tris[3 * res.primitive + 2].w);
        isVirtual = true;
        cluster = a & 0xFFFFFFu;        // cluster | triangle within it << 24
        local = a >> 24;
        group = b & 0xFFFFFFu;          // group | level << 24
        level = b >> 24;
    }
#endif
    // The level of detail, 0 = finest: a virtual triangle's DAG level, else its mesh's (GPUMesh.lod: an open-world
    // tile's ring, a crowd character's detail, a baked plant). A plant's parts are its finest.
    const float3 grey = float3(0.45f);  // geometry without levels; in the cluster and group views, what isn't virtual
    float3 lodColor = grey;
    if (isVirtual) lodColor = debugHeat(0.05f + float(level) / 10.0f);
#if CUSTOM_RT
    else if (FOLIAGE && res.part != HIT_NO_PART) lodColor = debugHeat(0.05f);
#endif
    else if (s.meshes[inst.meshIndex].lod != 0) lodColor = debugHeat(0.05f + 0.3f * float(s.meshes[inst.meshIndex].lod - 1));

    uint instanceSeed = pcgHash(res.instance + 0x51ED27u);
    float3 c = grey;
    switch (u.viewMode) {
        case VIEW_TRIANGLES:
            c = debugHashColor(isVirtual ? local + pcgHash(cluster + instanceSeed) : res.primitive + instanceSeed);
            break;
        // Geometry that isn't virtual has no clusters or groups: its level, faded.
        case VIEW_CLUSTERS: c = isVirtual ? debugHashColor(cluster + instanceSeed) : mix(grey, lodColor, 0.5f); break;
        case VIEW_GROUPS:   c = isVirtual ? debugHashColor(group * 0x9E3779B9u + instanceSeed) : mix(grey, lodColor, 0.5f); break;
        case VIEW_LOD:      c = lodColor; break;
        case VIEW_TRIANGLE_SIZE: {
            // Edge length (of a right triangle with the same area) in traced pixels: 1/8 px blue, 1 px green, 8 px red.
            float footprint = res.distance * 2.0f * u.camUp.w / float(u.height);
            float px = sqrt(doubleArea) / max(footprint, 1e-8f);
            c = debugHeat((log2(max(px, 1e-4f)) + 3.0f) / 6.0f);
            break;
        }
        default: break;
    }
    output.write(float4(c * shade, 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 4. Composite: re-apply albedo, add emission, tonemap and write to the drawable.
// ---------------------------------------------------------------------------------------------

inline float3 acesFilm(float3 x) {
    // Narkowicz 2015 ACES approximation
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}

// AgX (Troy Sobotka), with the polynomial fit of its default contrast curve by Benjamin Wrensch ("minimal AgX"):
// into the AgX working space, log2 between its EV limits, the curve, back. The curve's output is display-encoded
// (gamma 2.2), and the drawable wants linear, hence the pow at the end.
inline float3 agxFilm(float3 c) {
    const float3x3 toAgx = float3x3(0.842479062253094f, 0.0423282422610123f, 0.0423756549057051f,
                                    0.0784335999999992f, 0.878468636469772f, 0.0784336f,
                                    0.0792237451477643f, 0.0791661274605434f, 0.879142973793104f);
    const float3x3 fromAgx = float3x3(1.19687900512017f, -0.0528968517574562f, -0.0529716355144438f,
                                      -0.0980208811401368f, 1.15190312990417f, -0.0980434501171241f,
                                      -0.0990297440797205f, -0.0989611768448433f, 1.15107367264116f);
    const float minEV = -12.47393f, maxEV = 4.026069f;
    float3 x = (clamp(log2(max(toAgx * c, 1e-10f)), minEV, maxEV) - minEV) / (maxEV - minEV);
    float3 x2 = x * x, x4 = x2 * x2;
    x = 15.5f * x4 * x2 - 40.14f * x4 * x + 31.96f * x4 - 6.868f * x2 * x + 0.4298f * x2 + 0.1191f * x - 0.00232f;
    return pow(saturate(fromAgx * x), float3(2.2f));
}

/// Whether view mode `mode` shows light (tone mapped) rather than a value to read as it is (normals, albedo, ...).
inline bool viewIsHDR(uint mode) {
    return !(mode == 3 || mode == 4 || mode == 5 || (mode >= 7 && mode <= 13));
}

/// Exposure, then the selected curve (RenderSettings.toneMap).
inline float3 toneMap(float3 c, float4 post) {
    c *= post.x;
    switch (uint(post.y)) {
        case 1: return agxFilm(c);
        case 2: return c / (1.0f + dot(c, float3(0.2126f, 0.7152f, 0.0722f)));   // Reinhard on luminance: keeps hue
        case 3: return c;
        default: return acesFilm(c);
    }
}

kernel void compositeKernel(constant Uniforms&              u          [[buffer(0)]],
                            texture2d<float, access::read>  denoised   [[texture(0)]],
                            texture2d<float, access::read>  direct     [[texture(1)]],
                            texture2d<float, access::read>  indirect   [[texture(2)]],
                            texture2d<float, access::read>  albedoTex  [[texture(3)]],
                            texture2d<float, access::read>  emissionTex [[texture(4)]],
                            texture2d<float, access::read>  nd         [[texture(5)]],
                            texture2d<float, access::read>  moments    [[texture(6)]],
                            texture2d<float, access::write> output     [[texture(7)]],
                            texture2d<float, access::read>  denoisedIndirect [[texture(8)]],  // with FLAG_SEPARATE
                            texture2d<float, access::read>  giDebug    [[texture(9)]],   // written by cascade GI
                            texture2d<float, access::read>  surfacePos [[texture(10)]],  // with FLAG_SHADOW_DENOISER
                            texture2d<float, access::read>  geoNormal  [[texture(11)]],  // with FLAG_SHADOW_DENOISER
                            texture2d<float, access::read>  material   [[texture(12)]],  // with FLAG_SPECULAR: F0, roughness
                            texture2d<float, access::read>  specularTex [[texture(13)]], // with FLAG_SPECULAR: specular light / specular albedo
                            texture2d<float, access::read>  geometryDebug [[texture(14)]], // view modes 8-13 (geometryDebugKernel)
                            texture2d<float, access::read>  meshDirect [[texture(15)]],   // with FLAG_MESH_LIGHTS: denoised mesh-light direct light
                            texture3d<float>                fogGrid    [[texture(16)]],   // with FLAG_FOG: integrated froxels
                            texture2d<float, access::read>  fogReference [[texture(17)]], // with FLAG_FOG_REFERENCE
                            texture2d<float, access::write> outSpecularAlbedo [[texture(18)]], // with FLAG_HDR_OUTPUT: MetalFX's guides
                            texture2d<float, access::write> outRoughness [[texture(19)]],
                            device const Light*             lights     [[buffer(1)]],    // with FLAG_SHADOW_DENOISER
                            constant FogParams&             fog        [[buffer(2)]],    // with FLAG_FOG
                            uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    if (tid.x >= u.width || tid.y >= u.height) {
        output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid);
        return;
    }

    float3 albedo = albedoTex.read(tid).rgb;
    float3 emission = emissionTex.read(tid).rgb;
    float3 d = direct.read(tid).rgb;
    float3 i = indirect.read(tid).rgb;
    float3 illumination = d + i;
    float3 finalIndirect = i;   // what view mode 6 shows: denoised when indirect light is denoised on its own
    float3 directSpecular = float3(0.0f);
    if (flagOn(u.flags, FLAG_SHADOW_DENOISER)) {
        // `denoised` holds each light group's filtered visibility: multiply it onto the group's exact unshadowed light.
        float4 vis = denoised.read(tid);
        float4 sp = surfacePos.read(tid);
        float3 n = nd.read(tid).xyz, ng = geoNormal.read(tid).xyz;
        float3 p = sp.xyz + ng * RAY_EPSILON;
        illumination = float3(0.0f);
        if (flagOn(u.flags, FLAG_RESTIR)) {
            // ReSTIR (RESTIR_SPLIT): its denoised unshadowed light (in meshDirect's place) x its denoised visibility.
            illumination = meshDirect.read(tid).rgb * vis.r;
        } else {
        for (uint l = 0; l < u.lightGroupEnd.w; ++l) illumination += lightUnshadowed(lights[l], p, n, ng) * dot(vis, groupMask(lightGroup(lights[l])));
        if (flagOn(u.flags, FLAG_MESH_LIGHTS)) illumination += meshDirect.read(tid).rgb;   // denoised on its own
        }
        if (flagOn(u.flags, FLAG_SPECULAR) && !flagOn(u.flags, FLAG_RESTIR)) {
            // Direct specular the same way: exact unshadowed GGX light x the group's denoised visibility.
            float4 m = material.read(tid);
            if (any(m.rgb > 0.0f)) {
                float3 v = normalize(u.camPos.xyz - sp.xyz);
                for (uint l = 0; l < u.lightGroupEnd.w; ++l)
                    directSpecular += lightSpecular(lights[l], p, n, ng, v, m.rgb, m.a) * dot(vis, groupMask(lightGroup(lights[l])));
            }
        }
        if (flagOn(u.flags, FLAG_SEPARATE)) {
            finalIndirect = denoisedIndirect.read(tid).rgb;
            illumination += finalIndirect;
        }
    } else if (flagOn(u.flags, FLAG_DENOISE)) {
        illumination = denoised.read(tid).rgb;
        if (flagOn(u.flags, FLAG_SEPARATE)) {
            finalIndirect = denoisedIndirect.read(tid).rgb;
            illumination += finalIndirect;
        }
    }

    // Indirect specular: the reflection pass's result (or, on rough surfaces, the diffuse GI) x specular albedo.
    float3 specular = directSpecular;
    float3 guideSpecular = float3(0.0f);   // what MetalFX's denoiser is told the surface reflects, and how sharply
    float guideRoughness = 1.0f;
    if (flagOn(u.flags, FLAG_SPECULAR)) {
        float4 m = material.read(tid);
        float4 ndc = nd.read(tid);
        if (any(m.rgb > 0.0f) && ndc.w > 0.0f) {
            float3 v = normalize(u.camPos.xyz - surfacePos.read(tid).xyz);
            float3 sa = specularAlbedo(m.rgb, 1.0f, m.a, max(dot(ndc.xyz, v), 1e-4f));
            guideSpecular = sa;
            guideRoughness = m.a;
            float3 traced = specularTex.read(tid).rgb;
            bool tracedAll = m.a < REFLECTION_MAX_ROUGHNESS || flagOn(u.flags, FLAG_REFERENCE);
            specular += sa * (tracedAll ? traced : traced + finalIndirect);
        }
    }

    // Fog in front of the pixel: rgb = in-scattered light, a = transmittance.
    float4 fogged = float4(0.0f, 0.0f, 0.0f, 1.0f);
    if (flagOn(u.flags, FLAG_FOG)) {
        if (flagOn(u.flags, FLAG_FOG_REFERENCE)) fogged = fogReference.read(tid);
        else {
            // With temporal accumulation downstream (jittered frames: MetalFX's denoising scaler, references), the lookup
            // moves by the frame's jitter scaled up to a whole froxel, so the accumulation smooths the grid's steps.
            float depth = nd.read(tid).w;
            float2 uv = (float2(tid) + 0.5f + u.jitter.xy * 8.0f) / float2(u.width, u.height);
            fogged = fogFromGrid(fog, fogGrid, uv, depth > 0.0f ? depth : fog.grid.y);
            if (fog.wind.w > 0.0f) {
                float3 dir = primaryDirection(u, tid);
                float along = dot(dir, u.camForward.xyz);
                float tFar = fog.grid.y / along, tEnd = depth > 0.0f ? depth / along : INFINITY;
                if (tEnd > tFar) fogged = fogHaze(fog, fogGrid, uv, fogged, u.camPos.xyz, dir, tFar, tEnd);
            }
        }
    }

    float3 c;
    switch (u.viewMode) {
        case 1: c = albedo * d + emission; break;                 // raw direct
        case 2: c = albedo * i; break;                            // raw indirect
        case 3: { float4 n = nd.read(tid); c = n.w > 0.0f ? n.xyz * 0.5f + 0.5f : float3(0.0f); break; }
        case 4: c = albedo; break;
        case 5: { float h = moments.read(tid).z / u.denoise.y; c = float3(1.0f - h, h, 0.0f); break; }
        case 6: c = albedo * finalIndirect; break;                // indirect light only, as it reaches the image
        case 7: c = flagOn(u.flags, FLAG_GI_DEBUG) ? giDebug.read(tid).rgb : float3(0.0f); break;   // GI technique's debug view
        case 8: case 9: case 10: case 11: case 12: case 13: c = geometryDebug.read(tid).rgb; break;
        case 14: c = fogged.rgb; break;                           // fog scattering alone
        default: c = (albedo * illumination + specular + emission) * fogged.a + fogged.rgb; break;
    }
    if (flagOn(u.flags, FLAG_HDR_OUTPUT)) {
        // MetalFX's denoising scaler takes the light as it is: noisy, linear and unbounded (tonemapKernel follows it),
        // with what the surface reflects to guide it (next to the albedo, the normals, the depth and the motion).
        output.write(float4(max(c, 0.0f), 1.0f), tid);
        outSpecularAlbedo.write(float4(guideSpecular, 1.0f), tid);
        outRoughness.write(float4(guideRoughness), tid);
        return;
    }
    if (flagOn(u.flags, FLAG_POST)) {   // the lens effects follow (Post.metal): they want the light as it is
        output.write(float4(max(c, 0.0f), 1.0f), tid);
        return;
    }
    if (viewIsHDR(u.viewMode)) c = toneMap(c, u.post);
    // Linear either way: MetalFX's input is linear, and the drawable is an sRGB format (the GPU encodes on write).
    output.write(float4(saturate(c), 1.0f), tid);
}

// 4c. Tone map, after MetalFX's denoising scaler (FLAG_HDR_OUTPUT): its output is the denoised light at the output
//     resolution, still linear and unbounded. This applies the exposure and the tone curve the composite left out
//     and writes the drawable.
kernel void tonemapKernel(constant Uniforms&              u        [[buffer(0)]],
                          texture2d<float, access::read>  upscaled [[texture(0)]],
                          texture2d<float, access::write> output   [[texture(1)]],
                          uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    float3 c = max(upscaled.read(tid).rgb, 0.0f);
    if (viewIsHDR(u.viewMode)) c = toneMap(c, u.post);
    output.write(float4(saturate(c), 1.0f), tid);
}

// ---------------------------------------------------------------------------------------------
// 5. Accumulate (benchmark reference only): running mean of the raw illumination over many frames
//    of a paused scene, used in place of the denoiser to make a converged ground-truth image.
// ---------------------------------------------------------------------------------------------

// A frame's sample as the running means take it. References have no firefly clamp, so a rare sample overflows the
// half-float light textures to inf, and one inf turns a running mean into NaN for good (inf - inf): count it as the
// largest half instead, and a NaN sample as nothing.
static float3 finiteSample(float3 c) {
    return select(min(c, float3(65504.0f)), float3(0.0f), isnan(c));
}

kernel void accumulateKernel(constant Uniforms&                   u              [[buffer(0)]],
                             constant uint&                       sampleCount    [[buffer(1)]],
                             texture2d<float, access::read>       direct         [[texture(0)]],
                             texture2d<float, access::read>       indirect       [[texture(1)]],
                             texture2d<float, access::read_write> accumDirect    [[texture(2)]],
                             texture2d<float, access::read_write> accumIndirect  [[texture(3)]],
                             texture2d<float, access::read>       spec           [[texture(4)]],   // with FLAG_SPECULAR
                             texture2d<float, access::read_write> accumSpec      [[texture(5)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    // Running means, kept apart so the "Indirect only" view has a converged reference too.
    float w = 1.0f / float(sampleCount + 1);
    float3 d = finiteSample(direct.read(tid).rgb), i = finiteSample(indirect.read(tid).rgb);
    float3 meanD = sampleCount > 0 ? accumDirect.read(tid).rgb : float3(0.0f);
    float3 meanI = sampleCount > 0 ? accumIndirect.read(tid).rgb : float3(0.0f);
    accumDirect.write(float4(meanD + (d - meanD) * w, 1.0f), tid);
    accumIndirect.write(float4(meanI + (i - meanI) * w, 1.0f), tid);
    if (flagOn(u.flags, FLAG_SPECULAR)) {
        float3 sp = finiteSample(spec.read(tid).rgb), meanS = sampleCount > 0 ? accumSpec.read(tid).rgb : float3(0.0f);
        accumSpec.write(float4(meanS + (sp - meanS) * w, 1.0f), tid);
    }
}

// Benchmark references only: running mean of the composited (tonemapped) colour over jittered frames, i.e. a
// supersampled, anti-aliased image. params.x = frames averaged so far, y = 0 while not averaging yet.
kernel void accumulateColorKernel(constant uint2&                      params [[buffer(0)]],
                                  texture2d<float, access::read>       color  [[texture(0)]],
                                  texture2d<float, access::read_write> accum  [[texture(1)]],
                                  texture2d<float, access::write>      output [[texture(2)]],
                                  uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
    float3 c = finiteSample(color.read(tid).rgb);
    if (params.y != 0) {
        float3 m = params.x > 0 ? accum.read(tid).rgb : float3(0.0f);
        c = m + (c - m) / float(params.x + 1);
        accum.write(float4(c, 1.0f), tid);
    }
    output.write(float4(c, 1.0f), tid);
}
