// ---------------------------------------------------------------------------------------------
// 1c. Water (WATER scenes: Scene+Water.swift; the shared pieces in WaterCommon.metal).
//
//     waterKernel runs before traceKernel, after liquidKernel (a pixel a liquid bent stays the liquid's). It meets the
//     camera's ray with the water's surfaces (nothing solid in front: a ray tells), takes the
//     surface there from the waves, the ripples and the flow (waterSurfaceAt), and leaves the trace the ray bent
//     into the water (Snell): what the trace then finds, lights and filters as any surface (the bed, a stone, a
//     drowned trunk) is what is seen through it. What the surface reflects (the scene in its mirror direction: one
//     ray, as window glass's; the sun's glint), its foam (the crests', the shore's line, a river's white water) and
//     the light the water itself scatters toward the eye, waterApplyKernel folds into the G-buffer: what is seen
//     under the water dimmed by how far through it it is (Beer-Lambert, per colour) and by how deep it lies (the
//     light that came down to it), the water's own glow over it, the reflection and the foam on top.
//     The soft shore: where the water is a few centimetres deep its surface fades out (no bend, no reflection).
//     To shadow rays the water isn't there (its bed is lit, then dimmed by its depth).
// ---------------------------------------------------------------------------------------------

// The water's own light toward the eye along a ray in it, from `startDepth` under its surface (`dir` the ray's way
// in the water): the sun's and the sky's light it scatters, A x (1 - exp(-sigma_t m t)) after t metres, A in rgb
// and m in alpha (the light coming down dims with depth: a ray going down gathers less of it the farther it goes,
// one going up more).
inline float4 waterInscatter(WaterLook look, float3 dir, float3 sunDir, float3 sunLight, float3 skyLight, float startDepth) {
    float3 sigmaT = look.absorption.rgb + look.scattering.rgb;
    float g = look.scattering.w, ior = look.absorption.w;
    // The sun's way in the water: bent down at the surface.
    float cosI = saturate(sunDir.y);
    float sinT = sqrt(saturate(1.0f - cosI * cosI)) / ior, cosT = max(sqrt(saturate(1.0f - sinT * sinT)), 0.2f);
    float3 sunIn = normalize(float3(-sunDir.x / ior, -cosT, -sunDir.z / ior));   // travelling down
    float cosTheta = dot(sunIn, dir);
    // Forward scattering (Henyey-Greenstein), and a share of it spread every way: the light scattered many times
    // over, which is most of what comes back up out of deep water.
    float phase = 0.7f * (1.0f - g * g) / (12.5663706f * pow(max(1.0f + g * g - 2.0f * g * cosTheta, 1e-4f), 1.5f)) + 0.3f / 12.5663706f;
    float m = 1.0f - dir.y / cosT;
    if (abs(m) < 0.05f) m = m < 0.0f ? -0.05f : 0.05f;
    float3 source = (phase * sunLight + 0.25f * skyLight) * exp(-sigmaT * max(startDepth, 0.0f) / cosT);
    return float4(look.scattering.rgb * source / (sigmaT * m + 1e-5f), m);
}

// The glow `waterInscatter` gives over `d` metres of its ray.
inline float3 waterGlow(float4 a, WaterLook look, float d) {
    float3 sigmaT = look.absorption.rgb + look.scattering.rgb;
    return a.rgb * (1.0f - exp(min(-sigmaT * a.a * d, float3(20.0f))));
}

// What the water reflects along `dir` from `p` on it: the sky, or the surface its mirror ray meets, lit by the sky
// (a stand-in for its indirect light) and the lights: the sun's shadow traced only for what is near (far hills in the
// water are blurred by its ripples), the others' (a few) unshadowed; with many lights, one light sample (glass's).
float3 waterReflection(constant Uniforms& u, SCENE_ACCEL accel, thread const SceneData& s, float3 p, float3 dir, thread Sampler& rng,
                       bool shadows) {
    if (LIGHT_TABLE) return glassReflection(u, accel, s, p, dir, rng);
    Surface h = traceSurface(makeRay(p, dir, 0.0f, INFINITY), rayMask(MASK_GEOMETRY, RAY_SPECULAR), accel, s, GI_RAY_SPREAD);
    if (!h.hit) return skyRadiance(u, s, dir, 0.0f);
    float3 hng, hn;
    orientNormals(h, dir, hng, hn);
    float3 hp = h.position + hng * RAY_EPSILON;
    float3 albedo = hitAlbedo(h);
    float3 L = skyAmbient(u, s) * 0.5f;
    bool near = shadows && distance(hp, p) < 150.0f;
    for (uint i = 0; i < min(u.lightCount, 8u); ++i) {
        Light l = s.lights[i];
        float3 e = lightUnshadowed(l, hp, hn, hng);
        if (all(e <= 0.0f)) continue;
        if (lightType(l) == LIGHT_SUN) {
            e *= cloudShadow(s, hp);
            if (near && !isVisible(hp, hp + l.axis.xyz * 1e4f, accel)) e = float3(0.0f);
        }
        L += e;
    }
    return h.emission + albedo * L;
}

kernel void waterKernel(constant Uniforms&               u          [[buffer(0)]],
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
                        texture2d<float, access::read_write> outRay     [[texture(0)]],   // xyz = the bent ray's origin, w = 2 + WATER_RAY_*
                        texture2d<float, access::write>  outDir      [[texture(1)]],   // xyz = its direction, w = the surface's distance
                        texture2d<float, access::write>  outThrough  [[texture(2)]],   // rgb = what comes through, a = the look
                        texture2d<float, access::write>  outReflect  [[texture(3)]],   // rgb = reflection, glint and foam
                        texture2d<float, access::read>   blueNoise   [[texture(4)]],
                        texture2d<float, access::write>  outScatter  [[texture(5)]],   // the water's own light (waterInscatter)
                        texture2d<float, access::read>   lastReflections [[texture(6)]],   // the last frame's (rgb, a = the surface's distance)
                        texture2d<float, access::write>  outReflections  [[texture(7)]],   // this frame's
                        uint2 tid [[thread_position_in_grid]])
{
    if (!WATER || tid.x >= u.width || tid.y >= u.height) return;
    // (A liquid in front: the pixel is the liquid's.)
    if (LIQUID && outRay.read(tid).w == 1.0f) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    device const WaterScene* w = shading.water;
    float3 dir = primaryDirection(u, tid), origin = u.camPos.xyz;
    const uint solid = MASK_ALL & ~(MASK_GLASS | MASK_LIQUID);
    if (w == nullptr) { outRay.write(float4(0.0f), tid); return; }
    // Whether this ray starts under the water: its first centimetres under the waves' surface there (the waterline
    // can cross the picture when the camera is at it).
    float3 start = origin + dir * 0.06f;
    WaterPlace atCamera = waterAt(w, start.xz);
    bool under = false;
    if (atCamera.wet) {
        float surfaceY = atCamera.level;
        if ((w->counts.y & WATER_FFT) != 0u) {
            float fade = smoothstep(0.0f, 3.0f, atCamera.level - atCamera.ground);
            surfaceY += waterDisplacement(w, w->looks[atCamera.look], start.xz).y * fade;
        }
        under = start.y < surfaceY;
    }
    // The water's surface (its own structures: a cheap ray), unless something solid is in front of it: a ray's up to it.
    // (A ray that never comes down to the highest water there is meets none; one that does meets it between where
    // it crosses the highest water's height and the lowest's: where the map has no water along that stretch, none
    // either. No ray needed to tell: a ray, even into the water's own small structure, costs far more.)
    bool reaches = under || dir.y < 0.0f || origin.y < w->time.w;
    if (reaches && !under && dir.y < -1e-3f && origin.y > w->time.w && (w->counts.y & WATER_MAPPED) != 0u) {
        float t0 = (w->time.w - origin.y) / dir.y, t1 = (w->near.y - origin.y) / dir.y;
        float span = (t1 - t0) * length(dir.xz);
        uint n = clamp(uint(span / 2.0f) + 2u, 2u, 24u);
        bool wet = false;
        for (uint k = 0; k < n && !wet; ++k) wet = waterAt(w, (origin + dir * mix(t0, t1, float(k) / float(n - 1u))).xz).wet;
        reaches = wet || span > 48.0f * 2.0f;
    }
    WaterHit first;
    first.hit = false;
    if (reaches && (w->counts.w & 256u) == 0u) first = waterIntersect(w, origin, dir, INFINITY);
    // Water the map says is under the ground there (a sea's sheet under an island, the swamp's under its banks):
    // the ground hides it, no ray needed to tell.
    if (first.hit && (w->counts.y & WATER_MAPPED) != 0u) {
        WaterPlace there = waterAt(w, first.rest);
        if (!there.wet && there.ground > (origin + dir * first.distance).y + 0.05f) first.hit = false;
    }
    if (first.hit && (w->counts.w & 32u) == 0u) {
        float t;
        if (intersectAny(makeRay(origin, dir, 0.0f, first.distance), rayMask(solid, RAY_CAMERA), accel, t)) first.hit = false;
    }
    outReflections.write(float4(0.0f), tid);
    if (!first.hit && !under) {
        outRay.write(float4(0.0f), tid);
        return;
    }
    float3 sky = skyAmbient(u, s);
    // The sun (its direction and light, the clouds' shadow; its shadow is traced where it matters).
    float3 sunDir = float3(0.0f, 1.0f, 0.0f), sunLight = float3(0.0f);
    Light sun;
    bool hasSun = false;
    for (uint k = 0; k < sunDiscCount(u); ++k) {
        Light l = lights[sunDiscLight(u, k)];
        if (lightType(l) != LIGHT_SUN) continue;
        sun = l;
        hasSun = true;
        sunDir = l.axis.xyz;
        if (sunDir.y > 0.0f) sunLight = l.color.rgb * cloudShadow(s, origin);
        break;
    }

    if (under) {
        // The camera's ray in the water: dimmed and lit by it up to the surface it looks up at (Snell's window: out
        // into the air, or past the critical angle turned back down, a mirror of the water below), or all the way to
        // what it finds.
        WaterLook look = w->looks[atCamera.look];
        float ior = look.absorption.w;
        float3 sigmaT = look.absorption.rgb + look.scattering.rgb;
        float3 sunInto = sunLight * (1.0f - waterFresnel(saturate(sunDir.y), 1.0f / ior));
        float cameraDepth = max(atCamera.level - origin.y, 0.0f);
        float4 scatter = waterInscatter(look, dir, sunDir, sunInto, sky, cameraDepth);
        if (!first.hit) {
            // Straight on in the water to what is there.
            outRay.write(float4(origin, 2.0f + float(WATER_RAY_UNDER)), tid);
            outDir.write(float4(dir, 0.0f), tid);
            outThrough.write(float4(1.0f, 1.0f, 1.0f, float(atCamera.look)), tid);
            outReflect.write(float4(0.0f), tid);
            outScatter.write(scatter, tid);
            return;
        }
        float3 p = origin + dir * first.distance;
        float3 dim = exp(-sigmaT * first.distance);
        float3 glow = waterGlow(scatter, look, first.distance);
        float footprint = first.distance * 2.0f * u.camUp.w / float(u.height);
        WaterPlace place = waterAt(w, first.rest);
        WaterSurface surface = waterSurfaceAt(w, look, first.rest, place.flow, footprint);
        float3 n = surface.normal, facing = -n;   // seen from below
        if (dot(dir, facing) > -0.02f) facing = normalize(facing - dir * 0.05f);
        float cosI = saturate(dot(-dir, facing));
        float fresnel = waterFresnel(cosI, ior);   // water to air
        float3 out = refract(dir, facing, ior);
        float3 into, origin2;
        uint flags;
        float3 through, added;
        float4 scatter2 = float4(0.0f);
        if (fresnel >= 1.0f || length_squared(out) == 0.0f) {
            // Turned back down into the water: what it shows is under the water too.
            into = reflect(dir, facing);
            origin2 = p + facing * 2e-3f;
            flags = WATER_RAY_BENT | WATER_RAY_UNDER;
            through = dim;
            added = glow;
            scatter2 = waterInscatter(look, into, sunDir, sunInto, sky, 0.0f);
        } else {
            into = normalize(out);
            origin2 = p - facing * 2e-3f;
            flags = WATER_RAY_BENT;
            through = dim * (1.0f - fresnel);
            // What the surface reflects back down: the deep water's own light.
            float4 down = waterInscatter(look, reflect(dir, facing), sunDir, sunInto, sky, 0.0f);
            added = glow + dim * fresnel * down.rgb;
        }
        outRay.write(float4(origin2, 2.0f + float(flags)), tid);
        outDir.write(float4(into, first.distance), tid);
        outThrough.write(float4(through, float(atCamera.look)), tid);
        outReflect.write(float4(added, 0.0f), tid);
        outScatter.write(scatter2, tid);
        return;
    }

    float3 p = origin + dir * first.distance;
    uint lookIndex = first.look;
    WaterPlace place = waterAt(w, first.rest);
    if (place.wet) lookIndex = place.look;
    WaterLook look = w->looks[lookIndex];
    float depth = place.wet ? place.level - place.ground : 50.0f;
    float shore = smoothstep(0.0f, 0.25f, depth);   // the soft shore: a few centimetres of water barely show
    float footprint = first.distance * 2.0f * u.camUp.w / float(u.height);
    WaterSurface surface = waterSurfaceAt(w, look, first.rest, place.flow, footprint);
    float3 n = normalize(mix(float3(0.0f, 1.0f, 0.0f), surface.normal, shore));
    // (Facing the eye: a wave's back seen at a grazing angle would turn it over.)
    if (dot(n, -dir) < 0.02f) n = normalize(n + float3(0.0f, 0.02f - dot(n, -dir), 0.0f) * 1.5f);
    float ior = look.absorption.w, cosI = saturate(dot(-dir, n));
    float fresnel = waterFresnel(cosI, 1.0f / ior) * shore;

    Sampler rng = makeSampler(blueNoise, u, tid, 57, pcgHash(tid.x * 7919u + pcgHash(tid.y + pcgHash(u.frameIndex * 67u + 11u))));
    float3 at = p + n * RAY_EPSILON;
    float3 mirror = reflect(dir, n);
    mirror.y = abs(mirror.y);
    // The scene in its mirror direction: traced where the water reflects much of it (a grazing look), else the sky
    // there stands in (a look down into it reflects a few percent). Traced at a quarter of the pixels a frame (one
    // 8 x 8 block in four, the others in the next three): the others take what the last frame found where this surface
    // was, if it was this surface there (its distance from that frame's camera), else trace too.
    float3 mirrorLight;
    if (fresnel > 0.06f && (w->counts.w & 16u) == 0u) {
        // (By blocks of 8 x 8 pixels, not single ones: a SIMD group's threads trace together or not at all.)
        bool fresh = ((tid.x / 8u + 2u * (tid.y / 8u) + u.frameIndex) & 3u) == 0u || !flagOn(u.flags, FLAG_HISTORY_VALID);
        bool reused = false;
        if (!fresh) {
            float depthBefore;
            float2 px = projectToPixel(p - u.prevCamPos.xyz, u.prevCamRight, u.prevCamUp, u.prevCamForward, float2(u.width, u.height), depthBefore);
            if (depthBefore > 0.0f && all(px >= 0.0f) && px.x < float(u.width) && px.y < float(u.height)) {
                float4 last = lastReflections.read(uint2(px));
                float was = distance(p, u.prevCamPos.xyz);
                if (last.a > 0.0f && abs(last.a - was) < 0.03f * was + 0.05f) { mirrorLight = last.rgb; reused = true; }
            }
        }
        if (!reused) mirrorLight = waterReflection(u, accel, s, at, normalize(mirror), rng, (w->counts.w & 128u) == 0u);
        outReflections.write(float4(mirrorLight, first.distance), tid);
    } else {
        mirrorLight = skyRadiance(u, s, normalize(mirror), 0.0f);
    }
    float3 reflected = fresnel * mirrorLight;

    // Foam: the crests', a line along the shore that washes up and back, white water where a river runs fast.
    float shoreFoam = 0.0f;
    if (look.foam.y > 0.0f && place.wet) {
        float band = 1.0f - smoothstep(0.0f, look.foam.y, depth);
        float wash = 0.5f + 0.5f * sin(w->time.x * 0.9f - depth * 6.0f / max(look.foam.y, 0.1f) + waterNoise(first.rest * 0.05f).x * 6.0f);
        shoreFoam = 0.65f * band * mix(0.3f, 1.0f, wash) * smoothstep(0.0f, 0.03f, depth);
    }
    float foamAmount = saturate(surface.foam + shoreFoam + place.turbulence * 0.9f);
    float foam = waterFoamPattern(first.rest, w->time.x, place.flow, foamAmount, footprint);

    // The sun on it: its glint, and what reaches into it (the water's own light, the foam's). Its shadow is traced
    // where it matters to the eye (a glint, foam), else only the clouds' is taken.
    if (hasSun && sunDir.y > 0.0f) {
        sunLight = sun.color.rgb * cloudShadow(s, at);
        float f0 = (ior - 1.0f) * (ior - 1.0f) / ((ior + 1.0f) * (ior + 1.0f));
        float3 glint = shore * lightSpecular(sun, at, n, n, -dir, float3(f0), max(surface.roughness, 0.015f)) * sunLight / max(sun.color.rgb, float3(1e-6f));
        bool matters = luminance(glint) > 0.02f * luminance(sky) + 1e-4f || foam > 0.02f;
        if (matters && (w->counts.w & 64u) == 0u && !isVisible(at, at + sunDir * 1e4f, accel)) { sunLight = float3(0.0f); glint = float3(0.0f); }
        reflected += glint;
    }
    // Other lights' highlights, unshadowed, in a scene of a few.
    if (!LIGHT_TABLE && u.lightCount <= 8u) {
        float f0 = (ior - 1.0f) * (ior - 1.0f) / ((ior + 1.0f) * (ior + 1.0f));
        for (uint i = 0; i < u.lightCount; ++i) {
            if (lightType(lights[i]) == LIGHT_SUN) continue;
            reflected += shore * lightSpecular(lights[i], at, n, n, -dir, float3(f0), max(surface.roughness, 0.02f));
        }
    }
    float3 foamLight = 0.8f * (sunLight * saturate(dot(n, sunDir)) / 3.14159265f + sky);

    // Into the water.
    float3 bent = refract(dir, n, 1.0f / ior);
    float3 into = length_squared(bent) > 0.0f ? normalize(mix(dir, normalize(bent), shore)) : dir;
    float3 through = float3((1.0f - fresnel) * (1.0f - foam));
    // METALRENDERER_WATER_DEBUG: 1 = the map (red: wet, green: depth / 4 m, blue: flow / 3 m/s), 2 = the normal,
    // 3 = which surface (orange: the near patch, blue: the still ones).
    if ((w->counts.w & 15u) != 0u && (w->counts.w & 15u) <= 3u) {
        uint mode = w->counts.w & 15u;
        float3 shown = mode == 1u ? float3(place.wet ? 1.0f : 0.0f, saturate(depth / 4.0f), saturate(length(place.flow) / 3.0f))
                     : mode == 3u ? (first.near ? float3(1.0f, 0.3f, 0.1f) : float3(0.1f, 0.3f, 1.0f)) * (0.5f + 0.5f * first.normal.y)
                                  : n * 0.5f + 0.5f;
        outRay.write(float4(p + into * 2e-3f, 2.0f + float(WATER_RAY_BENT)), tid);
        outDir.write(float4(into, first.distance), tid);
        outThrough.write(float4(0.0f, 0.0f, 0.0f, float(lookIndex)), tid);
        outReflect.write(float4(shown, 0.0f), tid);
        return;
    }
    outRay.write(float4(p + into * 2e-3f, 2.0f + float(WATER_RAY_BENT | WATER_RAY_UNDER)), tid);
    outDir.write(float4(into, first.distance), tid);
    outThrough.write(float4(through, float(lookIndex)), tid);
    outReflect.write(float4(reflected * (1.0f - foam) + foam * foamLight, 0.0f), tid);
    outScatter.write(waterInscatter(look, into, sunDir, sunLight * (1.0f - waterFresnel(saturate(sunDir.y), 1.0f / ior)), sky, 0.0f), tid);
}

// What came through the water, its own light and its surface's, into the G-buffer of what the trace found under it.
kernel void waterApplyKernel(constant Uniforms&                   u           [[buffer(0)]],
                             constant SceneShading&               shading     [[buffer(7)]],
                             texture2d<float, access::read_write> albedo      [[texture(0)]],
                             texture2d<float, access::read_write> emission    [[texture(1)]],
                             texture2d<float, access::read_write> material    [[texture(2)]],   // with FLAG_SPECULAR
                             texture2d<float, access::read>       ray         [[texture(3)]],
                             texture2d<float, access::read>       through     [[texture(4)]],
                             texture2d<float, access::read>       reflect     [[texture(5)]],
                             texture2d<float, access::read>       scatter     [[texture(6)]],
                             texture2d<float, access::read>       normalDepth [[texture(7)]],
                             texture2d<float, access::read>       surfacePos  [[texture(8)]],
                             uint2 tid [[thread_position_in_grid]])
{
    if (!WATER || tid.x >= u.width || tid.y >= u.height) return;
    float4 r = ray.read(tid);
    if (r.w < 2.0f) return;
    uint flags = uint(r.w) - 2u;
    device const WaterScene* w = shading.water;
    float4 thr = through.read(tid);
    float3 t = thr.rgb, glow = float3(0.0f), dim = float3(1.0f), down = float3(1.0f);
    if ((flags & WATER_RAY_UNDER) != 0u && w != nullptr) {
        WaterLook look = w->looks[min(uint(thr.a), max(w->counts.x, 1u) - 1u)];
        float3 sigmaT = look.absorption.rgb + look.scattering.rgb;
        bool miss = normalDepth.read(tid).w < 0.0f;
        float3 sp = surfacePos.read(tid).xyz;
        float d = miss ? 1e4f : distance(sp, r.xyz);
        dim = exp(-sigmaT * d);
        // The light that reaches what is down there came through the water above it.
        if (!miss) {
            WaterPlace place = waterAt(w, sp.xz);
            float deep = place.wet ? place.level - sp.y : r.y - sp.y;
            down = exp(-(look.absorption.rgb + 0.3f * look.scattering.rgb) * max(deep, 0.0f));
        }
        glow = waterGlow(scatter.read(tid), look, d);
    }
    float4 a = albedo.read(tid);
    albedo.write(float4(a.rgb * t * dim * down, a.a), tid);
    emission.write(float4((emission.read(tid).rgb * dim + glow) * t + reflect.read(tid).rgb, 1.0f), tid);
    if (flagOn(u.flags, FLAG_SPECULAR)) {
        float4 m = material.read(tid);
        material.write(float4(m.rgb * t * dim * down, m.a), tid);
    }
}

// ---------------------------------------------------------------------------------------------
// The FFT ocean (Tessendorf): every frame its three cascades' spectra turned to the time (waterSpectrumKernel), an
// inverse FFT along the rows and then the columns (waterFFTKernel: Stockham, radix 2, a line a threadgroup in its
// memory), and the waves' textures made of the result (waterAssembleKernel): displacement and foam, the slopes; the
// foam kept from frame to frame where the crests pinch (the Jacobian of the sideways push under 1), fading.
// Four real fields go through each complex FFT two at a time (a + i b), in two RGBA slices per cascade:
//   slice 2c:     (Dx + i Dz), (Dy + i dDx/dz)       slice 2c + 1: (dDy/dx + i dDy/dz), (dDx/dx + i dDz/dz)
// ---------------------------------------------------------------------------------------------

struct WaterFFTParams {
    float4 lengths;   // the cascades' tile sides (m)
    float  time;      // s
    float  dt;
    uint   vertical;  // waterFFTKernel: 0 along the rows, 1 along the columns
    uint   pad;
};

inline float2 waterMul(float2 a, float2 b) { return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }

kernel void waterSpectrumKernel(constant WaterFFTParams&               p    [[buffer(0)]],
                                texture2d_array<float, access::read>   h0   [[texture(0)]],
                                texture2d_array<float, access::write>  spec [[texture(1)]],
                                uint3 tid [[thread_position_in_grid]])
{
    const uint n = 256u;
    if (tid.x >= n || tid.y >= n || tid.z >= 3u) return;
    uint c = tid.z;
    float dk = 6.2831853f / p.lengths[c];
    float kx = float(tid.x < n / 2u ? int(tid.x) : int(tid.x) - int(n)) * dk;
    float kz = float(tid.y < n / 2u ? int(tid.y) : int(tid.y) - int(n)) * dk;
    float k = sqrt(kx * kx + kz * kz);
    float4 a = h0.read(tid.xy, c);
    float2 h = float2(0.0f);
    if (k > 1e-6f) {
        // (The time wrapped per wave number: its phase stays exact in float however long the clock runs.)
        float omega = sqrt(9.81f * k), period = 6.2831853f / omega;
        float phase = omega * fmod(p.time, period);
        float2 e = float2(cos(phase), sin(phase));
        h = waterMul(a.xy, e) + waterMul(a.zw, float2(e.x, -e.y));
    }
    float ik = k > 1e-6f ? 1.0f / k : 0.0f;
    float2 ih = float2(-h.y, h.x);   // i h
    float2 c0 = kx * ik * ih - kz * ik * h;            // Dx + i Dz        (Dx = i kx/k h)
    float2 c1 = h - kx * kz * ik * ih;                 // Dy + i dDx/dz    (dDx/dz = -kx kz/k h)
    float2 c2 = kx * ih - kz * h;                      // dDy/dx + i dDy/dz
    float2 c3 = -kx * kx * ik * h - kz * kz * ik * ih; // dDx/dx + i dDz/dz
    spec.write(float4(c0, c1), tid.xy, 2u * c);
    spec.write(float4(c2, c3), tid.xy, 2u * c + 1u);
}

// One line (a row, or with p.vertical a column) of one slice, transformed back (e^{+i...}, unnormalized: the
// amplitudes are per wave), 128 threads a line.
kernel void waterFFTKernel(constant WaterFFTParams&              p     [[buffer(0)]],
                           texture2d_array<float, access::read>  src   [[texture(0)]],
                           texture2d_array<float, access::write> dst   [[texture(1)]],
                           uint2 group [[threadgroup_position_in_grid]],
                           uint  j     [[thread_index_in_threadgroup]])
{
    threadgroup float4 a[256], b[256];
    uint line = group.x, slice = group.y;
    uint2 q0 = p.vertical != 0u ? uint2(line, j) : uint2(j, line), q1 = p.vertical != 0u ? uint2(line, j + 128u) : uint2(j + 128u, line);
    a[j] = src.read(q0, slice);
    a[j + 128u] = src.read(q1, slice);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    bool flip = false;
    for (uint ns = 1u; ns < 256u; ns <<= 1u) {
        threadgroup float4* from = flip ? b : a;
        threadgroup float4* to = flip ? a : b;
        float4 v0 = from[j], v1 = from[j + 128u];
        float angle = 6.2831853f * float(j % ns) / float(ns * 2u);
        float2 tw = float2(cos(angle), sin(angle));
        v1 = float4(waterMul(v1.xy, tw), waterMul(v1.zw, tw));
        uint d = (j / ns) * ns * 2u + (j % ns);
        to[d] = v0 + v1;
        to[d + ns] = v0 - v1;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        flip = !flip;
    }
    threadgroup float4* result = flip ? b : a;
    dst.write(result[j], q0, slice);
    dst.write(result[j + 128u], q1, slice);
}

kernel void waterAssembleKernel(constant WaterFFTParams&                  p      [[buffer(0)]],
                                texture2d_array<float, access::read>      spec   [[texture(0)]],
                                texture2d_array<float, access::write>     waves  [[texture(1)]],
                                texture2d_array<float, access::write>     slopes [[texture(2)]],
                                texture2d_array<float, access::read_write> foam  [[texture(3)]],
                                uint3 tid [[thread_position_in_grid]])
{
    if (tid.x >= 256u || tid.y >= 256u || tid.z >= 3u) return;
    uint c = tid.z;
    float4 s0 = spec.read(tid.xy, 2u * c), s1 = spec.read(tid.xy, 2u * c + 1u);
    // (Dx, Dz, Dy, dDx/dz), (dDy/dx, dDy/dz, dDx/dx, dDz/dz)
    float jacobian = (1.0f + s1.z) * (1.0f + s1.w) - s0.w * s0.w;
    float was = foam.read(tid.xy, c).r;
    float f = max(was * exp(-p.dt * 0.4f), saturate((0.6f - jacobian) * 1.5f));
    foam.write(float4(f), tid.xy, c);
    waves.write(float4(s0.x, s0.z, s0.y, f), tid.xy, c);
    slopes.write(float4(s1.x, s1.y, s1.z, s1.w), tid.xy, c);
}

// ---------------------------------------------------------------------------------------------
// The near patch (WATER_NEAR): a grid around the camera, denser at its middle (a vertex every 0.3 m there, every 3 m
// at its rim), its vertices moved every frame by the FFT waves where the water map has water (by its look's share
// of them, fading to nothing at the rim, where the still surfaces take over, and on the way to the shore) and sunk
// under the ground where it hasn't. Its own structure is refitted after (WaterNearRefit). waterIntersect meets it
// in place of the still surfaces inside its square.
// ---------------------------------------------------------------------------------------------

struct WaterNearParams {
    float2 center;   // the scene's x, z
    float  radius;   // half its side (m)
    uint   cells;    // a side
};

// Where the grid's vertex at u (-1...1 across) is from its middle: dense in the middle, sparser out to the rim.
inline float2 waterNearOffset(float2 u, float radius) { return radius * (0.25f * u + 0.75f * u * u * u); }

kernel void waterNearKernel(constant WaterNearParams&   p        [[buffer(0)]],
                            device const WaterScene*    w        [[buffer(1)]],
                            device float4*              vertices [[buffer(2)]],
                            device float2*              rest     [[buffer(3)]],
                            uint2 tid [[thread_position_in_grid]])
{
    uint n = p.cells + 1u;
    if (tid.x >= n || tid.y >= n) return;
    float2 u = float2(tid) / float(p.cells) * 2.0f - 1.0f;
    float2 at = p.center + waterNearOffset(u, p.radius);
    WaterPlace place = waterAt(w, at);
    float4 v;
    if (!place.wet) {
        v = float4(at.x, place.ground - 1.0f, at.y, 255.0f);
    } else {
        WaterLook look = w->looks[place.look];
        float depth = place.level - place.ground;
        float rim = 1.0f - smoothstep(0.75f, 0.98f, max(abs(u.x), abs(u.y)));
        float fade = smoothstep(0.0f, 3.0f, depth) * rim;
        float3 d = waterDisplacement(w, look, at) * fade;
        v = float4(at.x + d.x, place.level + d.y, at.y + d.z, float(place.look));
    }
    vertices[tid.y * n + tid.x] = v;
    rest[tid.y * n + tid.x] = at;
}

// ---------------------------------------------------------------------------------------------
// Caustics: the sun's light bent by the waves (the short ones of cascade 2, which make their fine net) gathers into bright lines and leaves dimmer
// patches on what lies a few metres down. Each texel of the tile sends its light along the refracted ray to a bed
// WATER_CAUSTIC_DEPTH down; how the texels' spots crowd or spread there (the Jacobian of that map) is the light's
// strength (1: even). waterCaustic reads it under the water, blurred and weakened the deeper it is.
// ---------------------------------------------------------------------------------------------

constant float WATER_CAUSTIC_DEPTH = 2.0f;

struct WaterCausticParams {
    float4 sun;      // xyz = toward the sun, w = index of refraction
    float  length;   // cascade 2's tile side (m)
    float  pad0, pad1, pad2;
};

inline float2 waterCausticOffset(texture2d_array<float> slopes, int2 q, float3 sunIn) {
    // (The slopes a little blurred: the shortest ripples' focus is a haze a metre or two down, not a net.)
    constexpr sampler wrap(filter::linear, mip_filter::linear, address::repeat);
    float4 s = slopes.sample(wrap, (float2(q) + 0.5f) / 256.0f, 2u, level(1.6f));
    float3 n = normalize(float3(-s.x, 1.0f, -s.y));
    float3 t = refract(sunIn, n, 1.0f / 1.333f);
    if (t.y > -0.05f) t = float3(t.x, -0.05f, t.z);
    return t.xz / -t.y * WATER_CAUSTIC_DEPTH;
}

kernel void waterCausticsKernel(constant WaterCausticParams&           p      [[buffer(0)]],
                                texture2d_array<float>                 slopes [[texture(0)]],
                                texture2d<float, access::write>        out    [[texture(1)]],
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= 256u || tid.y >= 256u) return;
    float3 sunIn = -normalize(p.sun.xyz);
    int2 q = int2(tid);
    float texel = p.length / 256.0f;
    float2 o = waterCausticOffset(slopes, q, sunIn);
    float2 ox = waterCausticOffset(slopes, q + int2(1, 0), sunIn), oz = waterCausticOffset(slopes, q + int2(0, 1), sunIn);
    float2 dx = float2(1.0f, 0.0f) + (ox - o) / texel, dz = float2(0.0f, 1.0f) + (oz - o) / texel;
    float area = abs(dx.x * dz.y - dx.y * dz.x);
    out.write(float4(clamp(1.0f / max(area, 0.12f), 0.0f, 6.0f)), tid);
}
