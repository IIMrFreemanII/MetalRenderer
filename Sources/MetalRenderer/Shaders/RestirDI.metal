// ---------------------------------------------------------------------------------------------
// 1f. ReSTIR DI (Bitterli et al. 2020; MIS weights after Lin et al. 2022): direct light from every light, analytic and
//     emissive-mesh, at a cost that depends on the resolution, not on the light count. Each pixel keeps a reservoir:
//     one light sample (element, uv), its confidence M and its contribution weight W, so that f(y) W estimates the
//     pixel's direct light. Per frame:
//       restirTemporalKernel  `candidates` draws from the light table (by power) and one per sun, resampled by the
//                             target function (the sample's unshadowed luminance here); optionally a shadow ray to the
//                             pick (visibility reuse: an occluded pick gets W = 0, so occluded samples don't spread);
//                             then last frame's reservoir, reprojected, combined with the generalized balance
//                             heuristic (last frame's target uses last frame's lights, so moving lights stay unbiased).
//       restirSpatialKernel   0-2 passes, each combining `spatialSamples` neighbours on the same surface (pairwise MIS
//                             with confidence weights); the last pass shades: one shadow ray (none if the pixel kept its
//                             own already-tested pick) and writes diffuse light (albedo divided out) to `direct` and
//                             specular light for the reflection pass. Its reservoir is next frame's history.
//     SVGF then denoises the direct light as radiance; the composite needs no loop over the lights.
// ---------------------------------------------------------------------------------------------

struct RestirParams {
    uint4  config;   // x = candidates, y = max M, z = RESTIR_* flags, w = spatial samples
    float4 tuning;   // x = spatial radius (pixels), y = spatial pass index, z = firefly clamp (0 = off), w = chains
};

constant uint RESTIR_TEMPORAL_VALID = 1, RESTIR_VISIBILITY = 2, RESTIR_SHADE = 4, RESTIR_SPLIT = 8;
constant uint RESTIR_MAX_SPATIAL = 8;

struct Reservoir {
    uint   element;   // ELEMENT_NONE = no sample
    float2 uv;
    float  W;         // contribution weight
    float  M;         // confidence (samples' worth, capped)
    bool   visible;   // this frame: its point's shadow ray was traced from this pixel, and it was visible
};

inline Reservoir emptyReservoir() {
    Reservoir r;
    r.element = ELEMENT_NONE; r.uv = float2(0.0f); r.W = 0.0f; r.M = 0.0f; r.visible = false;
    return r;
}
inline uint4 packReservoir(Reservoir r) {
    return uint4(r.element, pack_float_to_unorm2x16(r.uv), as_type<uint>(r.W),
                 min(uint(r.M + 0.5f), 0xFFFFu) | (r.visible ? 0x10000u : 0u));
}
inline Reservoir unpackReservoir(uint4 v) {
    Reservoir r;
    r.element = v.x; r.uv = unpack_unorm2x16_to_float(v.y); r.W = as_type<float>(v.z); r.M = float(v.w & 0xFFFFu);
    r.visible = (v.w & 0x10000u) != 0;
    return r;
}
// The surface at pixel q (false: sky or an emitter, nothing to light).
inline bool restirSurface(uint2 q, constant Uniforms& u, texture2d<float, access::read> surfacePos,
                          texture2d<float, access::read> normalDepth, texture2d<float, access::read> geoNormal,
                          texture2d<float, access::read> albedo, texture2d<float, access::read> material,
                          thread ShadingPoint& sp, thread float& depth) {
    float4 pos = surfacePos.read(q);
    if (pos.w <= 0.0f) return false;
    float4 nd = normalDepth.read(q);
    sp.n = nd.xyz;
    depth = nd.w;
    sp.ng = geoNormal.read(q).xyz;
    sp.p = pos.xyz + sp.ng * RAY_EPSILON;
    sp.v = normalize(u.camPos.xyz - pos.xyz);
    sp.albedo = max(albedo.read(q).rgb, float3(0.05f));
    sp.f0 = float3(0.0f);
    sp.roughness = 1.0f;
    sp.specular = false;
    if (flagOn(u.flags, FLAG_SPECULAR)) {
        float4 m = material.read(q);
        sp.f0 = m.rgb; sp.roughness = m.a; sp.specular = any(m.rgb > 0.0f);
    }
    return true;
}

inline float restirTarget(Reservoir r, thread const ShadingPoint& sp, thread const SceneData& s, device const Light* lights,
                          device const TriangleInfo* tris, bool prev) {
    if (r.element == ELEMENT_NONE) return 0.0f;
    return lightSampleTarget(evalLightSample(r.element, r.uv, sp, s, lights, tris, prev, false), sp);
}

kernel void restirTemporalKernel(constant Uniforms&               u          [[buffer(0)]],
                                 SCENE_ACCEL                      accel      [[buffer(1)]],
                                 device const InstanceData*       instances  [[buffer(6)]],
                                 constant SceneShading&           shading    [[buffer(7)]],
                                 device const Light*              lights     [[buffer(8)]],   // + the light table
                                 constant RestirParams&           rp         [[buffer(9)]],
                                 device const Light*              prevLights [[buffer(10)]],  // last frame's lights
                                 device const RegirReservoir*     regirGrid  [[buffer(11)]],  // the light grid (ReGIR)
                                 constant RegirParams&            regir      [[buffer(12)]],
                                 texture2d<float, access::read>   surfacePos [[texture(0)]],
                                 texture2d<float, access::read>   normalDepth [[texture(1)]],
                                 texture2d<float, access::read>   geoNormal  [[texture(2)]],
                                 texture2d<float, access::read>   albedo     [[texture(3)]],
                                 texture2d<float, access::read>   material   [[texture(4)]],
                                 texture2d<float, access::read>   motion     [[texture(5)]],
                                 texture2d<float, access::read>   prevND     [[texture(6)]],
                                 texture2d_array<uint, access::read>  history  [[texture(7)]],   // one slice per chain
                                 texture2d_array<uint, access::write> outReservoir [[texture(8)]],
                                 uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    uint chains = uint(rp.tuning.w);
    ShadingPoint sp;
    float depth;
    if (!restirSurface(tid, u, surfacePos, normalDepth, geoNormal, albedo, material, sp, depth)) {
        for (uint c = 0; c < chains; ++c) outReservoir.write(packReservoir(emptyReservoir()), tid, c);
        return;
    }
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    device const LightTableEntry* entries = lightTableEntries(lights, u.lightCount);
    device const TriangleInfo* tris = lightTableTriangles(lights, u.lightCount, u.lightTable.x);
    Rng rng;
    rng.state = pixelSeed(tid, u.frameIndex, SEED_RESTIR_DI);

    // Last frame's pixel (nearest, same surface), shared by the chains.
    int2 q = passOn(rp.config.z, RESTIR_TEMPORAL_VALID) ? reprojectNearest(u, motion.read(tid), sp.n, prevND) : int2(-1);

    uint M = u.lightTable.x > 0 ? rp.config.x : 0u;
    // The light grid's cell (ReGIR): Mg of the M candidates come from it, each with its reservoir's W in place of
    // 1 / pdf. The same constant 1 / M weight for both sources keeps the mix unbiased; the table draws cover what the
    // cell's slots missed. Outside the grid (or with it off) every candidate is a table draw, as before.
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    RegirCell cell = regirLookup(regir, sp.p);
    uint Mg = cell.valid ? min(regir.consume.x, M) : 0u;
    for (uint chain = 0; chain < chains; ++chain) {
        // Initial candidates (each chain its own: shared ones made the chains alike, -1.5 dB at 1024 lights): grid
        // slots and table draws by power (each weighed target x W / M), and each sun once (target / 1).
        Reservoir r = emptyReservoir();
        float wSum = 0.0f, target = 0.0f;
        float3 point = float3(0.0f);
        for (uint k = 0; k < M + u.lightTable.y; ++k) {
            float Wsrc = 1.0f;
            uint element;
            float2 uv;
            if (k < Mg) {
                if (!regirDraw(s, sp.p, rng, element, uv, Wsrc)) continue;
            } else if (k < M) {
                float pdf = 1.0f;
                uint h0 = rng.nextUint(), h1 = rng.nextUint();
                element = sampleLightTable(entries, u.lightTable.x, h0, h1, pdf);
                Wsrc = 1.0f / pdf;
                uv = quantizeUV(rng.next2());
            } else {
                element = ELEMENT_SUN | (k == M ? u.lightTable.z : u.lightTable.w);
                uv = quantizeUV(rng.next2());
            }
            LightSampleEval e = evalLightSample(element, uv, sp, s, lights, tris, false, false);
            float t = lightSampleTarget(e, sp);
            float w = lightCandidateWeight(k, M, t, Wsrc);
            if (w <= 0.0f) continue;
            wSum += w;
            if (rng.next() * wSum < w) { r.element = element; r.uv = uv; target = t; point = e.target; }
        }
        r.M = 1.0f;
        r.W = target > 0.0f ? wSum / target : 0.0f;
        if (r.element != ELEMENT_NONE && passOn(rp.config.z, RESTIR_VISIBILITY)) {
            if (isVisible(sp.p, point, accel)) r.visible = true; else r.W = 0.0f;
        }
        if (q.x >= 0) {
            Reservoir h = unpackReservoir(history.read(uint2(q), chain));
            h.M = min(h.M, float(rp.config.y));
            if (h.M > 0.0f) {
                // Generalized balance heuristic over the two domains (this frame; last frame, whose target is
                // approximated at this surface with last frame's lights).
                float cc = target, hc = restirTarget(h, sp, s, lights, tris, false);
                float ch = restirTarget(r, sp, s, prevLights, tris, true), hh = restirTarget(h, sp, s, prevLights, tris, true);
                float mc = r.M * cc / max(r.M * cc + h.M * ch, 1e-30f);
                float mh = h.M * hh / max(h.M * hh + r.M * hc, 1e-30f);
                float wc = mc * cc * r.W, wh = mh * hc * h.W;
                float sum = wc + wh;
                if (sum > 0.0f && rng.next() * sum < wh) {
                    r.element = h.element; r.uv = h.uv; target = hc; r.visible = false;
                }
                r.W = target > 0.0f ? sum / target : 0.0f;
                r.M = min(r.M + h.M, float(rp.config.y));
            }
        }
        outReservoir.write(packReservoir(r), tid, chain);
    }
}

kernel void restirSpatialKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      accel      [[buffer(1)]],
                                device const InstanceData*       instances  [[buffer(6)]],
                                constant SceneShading&           shading    [[buffer(7)]],
                                device const Light*              lights     [[buffer(8)]],
                                constant RestirParams&           rp         [[buffer(9)]],
                                texture2d<float, access::read>   surfacePos [[texture(0)]],
                                texture2d<float, access::read>   normalDepth [[texture(1)]],
                                texture2d<float, access::read>   geoNormal  [[texture(2)]],
                                texture2d<float, access::read>   albedo     [[texture(3)]],
                                texture2d<float, access::read>   material   [[texture(4)]],
                                texture2d_array<uint, access::read>  inReservoir [[texture(5)]],
                                texture2d_array<uint, access::write> outReservoir [[texture(6)]],
                                texture2d<float, access::write>  outDirect  [[texture(7)]],   // with RESTIR_SHADE
                                texture2d<float, access::write>  outSpecular [[texture(8)]],  // with RESTIR_SHADE and FLAG_SPECULAR
                                texture2d<float, access::write>  outVisibility [[texture(9)]], // with RESTIR_SPLIT
                                texture2d<float, access::write>  outBlocker [[texture(10)]],   // with RESTIR_SPLIT
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    bool shade = passOn(rp.config.z, RESTIR_SHADE), specular = flagOn(u.flags, FLAG_SPECULAR);
    bool split = passOn(rp.config.z, RESTIR_SPLIT);
    uint chains = uint(rp.tuning.w);
    ShadingPoint sp;
    float depth;
    if (!restirSurface(tid, u, surfacePos, normalDepth, geoNormal, albedo, material, sp, depth)) {
        for (uint c = 0; c < chains; ++c) outReservoir.write(packReservoir(emptyReservoir()), tid, c);
        if (shade) {
            outDirect.write(float4(0.0f), tid);
            if (specular) outSpecular.write(float4(0.0f), tid);
            if (split) { outVisibility.write(float4(0.0f), tid); outBlocker.write(float4(0.0f), tid); }
        }
        return;
    }
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    device const TriangleInfo* tris = lightTableTriangles(lights, u.lightCount, u.lightTable.x);
    Rng rng;
    rng.state = pcgHash(tid.x * 9781u + pcgHash(tid.y + pcgHash(u.frameIndex * 7u + uint(rp.tuning.y) + 0x68E31DA4u)));

    // Neighbours on the same surface, in a disk (shared by the chains).
    uint wanted = min(rp.config.w, RESTIR_MAX_SPATIAL), count = 0;
    uint2 nq[RESTIR_MAX_SPATIAL];
    ShadingPoint nsp[RESTIR_MAX_SPATIAL];
    for (uint i = 0; i < wanted; ++i) {
        int2 q;
        if (!diskNeighbour(tid, rp.tuning.x, u, rng, q)) continue;
        ShadingPoint qp;
        float qd;
        if (!restirSurface(uint2(q), u, surfacePos, normalDepth, geoNormal, albedo, material, qp, qd)) continue;
        if (abs(qd - depth) > REUSE_DEPTH * depth || dot(qp.n, sp.n) < REUSE_NORMAL) continue;
        nq[count] = uint2(q);
        nsp[count] = qp;
        count++;
    }

    float3 diffuse = float3(0.0f), spec = float3(0.0f);
    float visibility = 0.0f, penumbra = 0.0f, occluded = 0.0f;
    for (uint chain = 0; chain < chains; ++chain) {
        Reservoir r = unpackReservoir(inReservoir.read(tid, chain));
        // Pairwise MIS with confidence weights: each neighbour's technique is weighed against the canonical one's share
        // M_c / n (n = neighbours with a reservoir); every sample's weights sum to 1, so the result stays unbiased (for
        // the target).
        // Each chain takes its own share of the neighbours (j = chain, chain + chains, ...): the chains together see
        // them all for a third of the target evaluations.
        Reservoir nb[RESTIR_MAX_SPATIAL];
        uint n = 0;
        float Msum = r.M;
        for (uint j = 0; j < count; ++j) {
            Reservoir qr = emptyReservoir();
            if (j % chains == chain % max(min(count, chains), 1u)) qr = unpackReservoir(inReservoir.read(nq[j], chain));
            nb[j] = qr;
            if (qr.M > 0.0f) { n++; Msum += qr.M; }
        }
        if (n > 0) {
            float cShare = r.M / float(n);
            float cc = restirTarget(r, sp, s, lights, tris, false);
            float mc = 0.0f, wSum = 0.0f, target = cc;
            Reservoir picked = r;
            for (uint j = 0; j < count; ++j) {
                if (nb[j].M <= 0.0f) continue;
                float jc = restirTarget(r, nsp[j], s, lights, tris, false);    // the canonical sample at the neighbour
                float jj = restirTarget(nb[j], nsp[j], s, lights, tris, false);
                float cj = restirTarget(nb[j], sp, s, lights, tris, false);    // the neighbour's sample here
                float2 mis = pairwiseMIS(nb[j].M, cShare, Msum, cc, jc, jj, cj);
                mc += mis.x;
                float w = mis.y * cj * nb[j].W;
                if (w <= 0.0f) continue;
                wSum += w;
                if (rng.next() * wSum < w) { picked = nb[j]; picked.visible = false; target = cj; }
            }
            float wc = mc * cc * r.W;
            wSum += wc;
            if (wc > 0.0f && rng.next() * wSum < wc) { picked = r; target = cc; }
            r = picked;
            r.W = target > 0.0f && wSum > 0.0f ? wSum / target : 0.0f;
            r.M = min(Msum, float(rp.config.y));
        }
        if (shade) {
            // One shadow ray per chain (none if it kept its own already-tested pick). RESTIR_SPLIT: `direct` gets the
            // unshadowed diffuse light and `visibility` the visibility (and `blocker` the penumbra), which the shadow
            // denoiser filters; the composite multiplies the two back. (An occluded pick keeps its weight for reuse:
            // zeroing it here as well as at the initial pick let confident zeros spread through the reuse.)
            if (r.element != ELEMENT_NONE && r.W > 0.0f) {
                LightSampleEval e = evalLightSample(r.element, r.uv, sp, s, lights, tris, false, true);
                float b = 0.0f;
                float v = r.visible || isVisibleBlocker(sp.p, e.target, accel, b) ? 1.0f : 0.0f;
                if (b > 0.0f) {
                    penumbra += (r.element & ELEMENT_TYPE) != ELEMENT_TRIANGLE ? penumbraWidth(lights[r.element & ELEMENT_INDEX], sp.p, b)
                                                                               : max(0.1f * b, 1e-4f);
                    occluded += 1.0f;
                }
                visibility += v;
                diffuse += e.diffuse * (r.W * (split ? 1.0f : v));
                spec += e.specular * (r.W * v);
            }
            r.visible = false;
        }
        outReservoir.write(packReservoir(r), tid, chain);
    }
    if (shade) {
        float inv = 1.0f / float(chains);
        diffuse *= inv; spec *= inv;
        float clampScale = fireflyScale(luminance(diffuse) + luminance(spec), rp.tuning.z);
        diffuse *= clampScale; spec *= clampScale;
        if (split) {
            outVisibility.write(float4(visibility * inv, 0.0f, 0.0f, 0.0f), tid);
            outBlocker.write(roundToHalf(float4(occluded > 0.0f ? penumbra / occluded : 0.0f, 0.0f, 0.0f, 0.0f)), tid);
        }
        outDirect.write(roundToHalf(float4(diffuse, 1.0f)), tid);
        if (specular) outSpecular.write(roundToHalf(float4(spec, 1.0f)), tid);
    }
}
