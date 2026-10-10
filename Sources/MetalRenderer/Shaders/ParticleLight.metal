// MARK: - Light

// The light a lit particle scatters, once per particle per frame (rays per pixel would cost far more): from each of
// the first lights (PARTICLE_LIGHTS), scattered isotropically (E / 4 pi per unit albedo, as the path tracer's
// particles do), its visibility the opaque scene's and the particles' transmittance between (so smoke shades
// itself), plus the sky's mean (what an isotropic scatterer sends in a uniform sky). Averaged
// over the frames (the shadow rays aim at random points of the lights): each frame weighs in at a third, a newborn's
// first frame alone. `lighting`: per slot three: that average of the light from all round (rgb) and whose it is (w:
// the particle's seed); of its brightest light (which six-way smoke shades apart: particleLit); where that comes from
// (summed by its brightness, so the average leans toward the brighter frames').
constant uint PARTICLE_LIGHTS = 8;

kernel void particleLightKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      accel      [[buffer(1)]],
                                device const float3*             positions  [[buffer(2)]],
                                device const float3*             normals    [[buffer(3)]],
                                device const uint*               indices    [[buffer(4)]],
                                device const MeshData*           meshes     [[buffer(5)]],
                                device const InstanceData*       instances  [[buffer(6)]],
                                constant SceneShading&           shading    [[buffer(7)]],
                                device const Light*              lights     [[buffer(8)]],
                                device ParticleRender*           render     [[buffer(13)]],
                                device float4*                   lighting   [[buffer(14)]],
                                constant uint&                   capacity   [[buffer(15)]],
                                uint i [[thread_position_in_grid]])
{
    if (i >= capacity) return;
    ParticleRender r = render[i];
    if (r.centerRadius.w <= 0.0f || (particleFlags(r) & PARTICLE_EMISSIVE) != 0u) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    float3 p = r.centerRadius.xyz;
    float3 sum = skyAmbient(u, s), key = float3(0.0f), keyDir = float3(0.0f);
    float keyLum = 0.0f;
    Rng rng;
    rng.state = pcgHash(r.info.w ^ pcgHash(u.frameIndex * 0x9E3779B9u + 0x2545F491u));
    uint count = LIGHT_TABLE ? 0u : min(u.lightCount, PARTICLE_LIGHTS);
    for (uint l = 0; l < count; ++l) {
        Light light = lights[l];
        float3 toward = lightType(light) == LIGHT_SUN ? light.axis.xyz : normalize(light.positionRadius.xyz - p);
        float3 e = lightUnshadowed(light, p, toward, toward);
        if (all(e <= 0.0f)) continue;
        float3 target = lightShadowTarget(light, p, rng.next2());
        float3 d = target - p;
        float dist = length(d);
        float t;
        if (intersectAny(makeRay(p, d / dist, RAY_EPSILON, max(dist - RAY_EPSILON, 0.0f)), rayMask(MASK_GEOMETRY, RAY_SHADOW), accel, t)) continue;
        // lightUnshadowed facing the light is its irradiance / pi: a quarter of it is E / 4 pi. Through the particles
        // between, light scattered on inside a dense column gets further than single scattering lets it: octaves of
        // weaker extinction (Wrenninge's multiple-scattering approximation), the same through thin smoke.
        float T = particleTransmittance(p, d / dist, r.centerRadius.w * 0.5f, dist, accel);
        float through = (T + 0.5f * sqrt(T) + 0.25f * sqrt(sqrt(T))) * (1.0f / 1.75f);
        float3 c = 0.25f * e * through * sunVisibilityScale(light, p, s);
        float lum = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        if (lum > keyLum) {
            sum += key;   // the brightest so far is the key; the one before joins the rest
            key = c;
            keyLum = lum;
            keyDir = toward;
        } else {
            sum += c;
        }
    }
    uint slot = min(r.info.x & 0xFFFFFFu, capacity - 1u);
    float4 last = lighting[3u * slot], lastKey = lighting[3u * slot + 1u], lastDir = lighting[3u * slot + 2u];
    bool same = as_type<uint>(last.w) == r.info.w;
    float3 now = same ? mix(last.rgb, sum, 1.0f / 3.0f) : sum;
    float3 keyNow = same ? mix(lastKey.rgb, key, 1.0f / 3.0f) : key;
    float3 dirNow = same ? mix(lastDir.xyz, keyDir * keyLum, 1.0f / 3.0f) : keyDir * keyLum;
    lighting[3u * slot] = float4(now, as_type<float>(r.info.w));
    lighting[3u * slot + 1u] = float4(keyNow, 0.0f);
    lighting[3u * slot + 2u] = float4(dirNow, 0.0f);
    float l = length(dirNow);
    render[i].radiance = half4(half3(min(now, 65000.0f)), 1.0h);
    render[i].keyLight = half4(half3(min(keyNow, 65000.0f)), 1.0h);
    render[i].keyDir = half4(half3(l > 1e-8f ? dirNow / l : float3(0.0f, 1.0f, 0.0f)), 0.0h);
}

// MARK: - The camera's layer

// The camera's billboards' least half-size, in texels of the layer (ParticlesGPU.widen).
constant float PARTICLE_WIDEN = 0.5f;
// ...and under how many texels across (half-size) a particle is too thin for them: the overlay traces it again.
constant float PARTICLE_DETAIL = 2.0f;

// The layer's size and how its rays leave the camera (Renderer.particleLayerStages): `jitter`, as the frame's (the
// layer is the frame's size, composited pixel for pixel); otherwise through its own texels' centres, steady from frame
// to frame (it goes over MetalFX's output, which doesn't filter it over time, or is smaller than the frame).
// `detail`: the overlay traces the thin particles again (particleLayerRay leaves them out).
struct ParticleLayerParams {
    uint2 size;
    uint  jitter;
    uint  detail;
};

// What the camera's ray along `dir` (through `uv` of the view) sees of the particles in front of the surface at
// `depth` (0: none): rgb = the light they send (fogged), a = how much of what is behind them they hide. Soft where
// they near that surface, and faded right in front of the camera. `footprint`: the ray's pixel across, a unit away
// (radians): the billboards are at least about that wide. `detail`: the ones under PARTICLE_DETAIL of them are left
// out, and set `thin` (particleCollect).
inline float4 particleLayerRay(constant Uniforms& u, SCENE_ACCEL sc, constant FogParams& fog, texture3d<float> fogGrid, float3 dir,
                               float2 uv, float depth, float footprint, bool detail, thread bool& thin) {
    float along = dot(dir, u.camForward.xyz);
    float tOpaque = depth > 0.0f ? depth / max(along, 1e-4f) : 1.0e5f;
    float meanT;
    float4 gathered = particleGather<4>(u.camPos.xyz, dir, tOpaque, depth > 0.0f, sc, meanT, PARTICLE_WIDEN * footprint,
                                        detail ? PARTICLE_DETAIL * footprint : 0.0f, thin);
    float3 c = gathered.rgb;
    float hidden = gathered.a;
    if (hidden > 1e-4f && flagOn(u.flags, FLAG_FOG) && !flagOn(u.flags, FLAG_FOG_REFERENCE)) {
        // The fog in front of them, at their mean distance: what they send dims, and the fog's own light takes the
        // share of the view they hide (the composite fogs the rest to the surface).
        float tMean = meanT / hidden;
        float4 fogged = fogFromGrid(fog, fogGrid, uv, tMean * along);
        c = c * fogged.a + hidden * fogged.rgb;
    }
    return float4(c, hidden);
}

// The depth a steady ray through `uv` stops its particles at, from the traced frame's depths `nd` (jittered: its
// samples sit up to half a texel off where `uv` looks). On a surface seen at a grazing angle that is centimetres a
// texel, so the nearest sample hid what lies on it (a splash ring a millimetre over the floor) in the frames whose
// jitter put it nearer, and showed it in the rest: it flickered. On one surface (the 3x3 samples round `uv`'s texel
// within 5 % of each other: the jitter can take the next one's half a texel past `uv`) the farthest of them; across an
// edge the nearest sample, as before. 0: the sky.
inline float particleClipDepth(texture2d<float, access::read> nd, float2 uv) {
    int2 n = int2(nd.get_width(), nd.get_height());
    int2 c = min(int2(uv * float2(n)), n - 1);
    float nearest = nd.read(uint2(c)).w;
    if (nearest <= 0.0f) return nearest;
    float lo = 1.0e30f, hi = 0.0f;
    for (int k = 0; k < 9; ++k) {
        float d = nd.read(uint2(clamp(c + int2(k % 3 - 1, k / 3 - 1), int2(0), n - 1))).w;
        if (d <= 0.0f) return nearest;
        lo = min(lo, d);
        hi = max(hi, d);
    }
    return hi - lo <= 0.05f * lo ? hi : nearest;
}

// A pixel's footprint at `uv` of a view `height` pixels high (radians across it, a unit away).
inline float particleFootprint(constant Uniforms& u, float2 uv, float height) {
    return length(normalize(viewDirection(u, uv + float2(0.0f, 1.0f / height))) - normalize(viewDirection(u, uv)));
}

// The camera's layer (particleLayerRay a texel): the composite puts it over the scene, or particleOverlayKernel over
// MetalFX's output. `layerDepth`: x = the depth of the surface each texel's particles stand in front of, which the
// upsampling weighs by (particleUpsample); y = 1 where some are too thin for its texels.
kernel void particleLayerKernel(constant Uniforms&               u          [[buffer(0)]],
                                SCENE_ACCEL                      sc         [[buffer(1)]],
                                constant FogParams&              fog        [[buffer(9)]],
                                constant ParticleLayerParams&    lp         [[buffer(10)]],
                                texture2d<float, access::read>   nd         [[texture(0)]],
                                texture2d<float, access::write>  layer      [[texture(1)]],
                                texture3d<float>                 fogGrid    [[texture(2)]],
                                texture2d<float, access::write>  layerDepth [[texture(3)]],
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= lp.size.x || tid.y >= lp.size.y) return;
    float2 uv = (float2(tid) + 0.5f) / float2(lp.size);
    uint2 pixel = min(uint2(uv * float2(u.width, u.height)), uint2(u.width - 1, u.height - 1));
    float3 dir = lp.jitter != 0u ? primaryDirection(u, pixel) : normalize(viewDirection(u, uv));
    float depth = lp.jitter != 0u ? nd.read(pixel).w : particleClipDepth(nd, uv);
    bool thin;
    float4 c = particleLayerRay(u, sc, fog, fogGrid, dir, uv, depth, particleFootprint(u, uv, float(lp.size.y)), lp.detail != 0u, thin);
    layer.write(c, tid);
    layerDepth.write(float4(depth, thin ? 1.0f : 0.0f, 0.0f, 0.0f), tid);
}

// The particles' layer over MetalFX's output (at its size, in place), before the lens and the tone curve: MetalFX
// would filter it over time with the scene's motion, which isn't theirs (sparks smeared into streaks), so it takes
// only the scene. Upsampled (particleUpsample; `nd`: the traced frame's depths, for its weights), but where the
// layer's texels are too coarse for the particles there (sparks, rain, motes: `thin`) traced again for the pixel.
kernel void particleOverlayKernel(constant Uniforms&                   u          [[buffer(0)]],
                                  SCENE_ACCEL                          sc         [[buffer(1)]],
                                  constant FogParams&                  fog        [[buffer(9)]],
                                  texture2d<float, access::read_write> out        [[texture(0)]],
                                  texture2d<float, access::read>       layer      [[texture(1)]],
                                  texture2d<float, access::read>       layerDepth [[texture(2)]],
                                  texture2d<float, access::read>       nd         [[texture(3)]],
                                  texture3d<float>                     fogGrid    [[texture(4)]],
                                  uint2 tid [[thread_position_in_grid]])
{
    uint2 size = uint2(out.get_width(), out.get_height());
    if (tid.x >= size.x || tid.y >= size.y) return;
    float2 uv = (float2(tid) + 0.5f) / float2(size);
    uint2 ndSize = uint2(nd.get_width(), nd.get_height());
    float depth = nd.read(min(uint2(uv * float2(ndSize)), ndSize - 1u)).w;
    bool thin;
    float4 l = particleUpsample(layer, layerDepth, uv, depth, thin);
    if (thin) {
        bool again;
        l = particleLayerRay(u, sc, fog, fogGrid, normalize(viewDirection(u, uv)), uv, particleClipDepth(nd, uv), particleFootprint(u, uv, float(size.y)),
                             false, again);
    }
    float4 c = out.read(tid);
    out.write(float4(l.rgb + (1.0f - l.a) * c.rgb, c.a), tid);
}

// MARK: - Heat haze

// Distortion particles (ParticleEmitter.distortion), never drawn: each bends the camera's rays that cross it in front
// of the surface behind, by up to its emitter's strength (radians) times its opacity over life, (1 - r^2)^2 across its
// disc. The bend's direction is curl noise rising through the air where they are met (their hits' mean, by how much
// each bends: no seam where one's edge crosses another), across the ray: hot air's shimmer, the same for every
// particle there so that overlapping ones bend together. Over the frame's linear
// light before the lens (bloom and depth of field see the bent light): `src` read where the bent ray looks, into
// `dst`; where that is nearer than the haze, the pixel's own light instead (no foreground smeared into it).
struct ParticleDistortParams {
    uint first;      // the distorters' slots (ParticleSystem.distortRange)
    uint count;
    uint emitters;
    float time;      // the particles' clock (s)
};

constant float PARTICLE_HAZE_FREQUENCY = 7.0f;   // the shimmer's noise cells a metre
constant float PARTICLE_HAZE_RISE = 1.4f;        // how fast they climb (m/s)
constant float PARTICLE_HAZE_MOST = 0.008f;      // the most bend overlapping particles add up to (rad)

// The distorters' discs for the pass, once a frame, in one threadgroup (particleDistortDiscsKernel): for each, xyz
// its centre and w its radius, then its bend (its strength times its opacity now; 0: dead); after them the part of
// the view they can cover (uv: x, y the least, z, w the most; empty when there are none), outside which the pass
// only copies.
kernel void particleDistortDiscsKernel(constant Uniforms&                u         [[buffer(0)]],
                                       constant ParticleDistortParams&   dp        [[buffer(1)]],
                                       device const ParticleEmitter*     emitters  [[buffer(13)]],
                                       device const Particle*            particles [[buffer(16)]],
                                       device float4*                    discs     [[buffer(17)]],
                                       uint i [[thread_index_in_threadgroup]], uint n [[threads_per_threadgroup]],
                                       uint lane [[thread_index_in_simdgroup]], uint group [[simdgroup_index_in_threadgroup]])
{
    float4 rect = float4(1.0f, 1.0f, 0.0f, 0.0f);
    for (uint k = i; k < dp.count; k += n) {
        Particle q = particles[dp.first + k];
        if ((q.info.w & PARTICLE_ALIVE) == 0u) {
            discs[2u * k] = float4(0.0f, -1.0e5f, 0.0f, 0.0f);
            discs[2u * k + 1u] = float4(0.0f);
            continue;
        }
        ParticleEmitter e = emitters[min(q.info.z, dp.emitters - 1u)];
        float x = saturate(q.position.w / max(q.velocity.w, 1e-6f));
        float r = mix(e.size.x, e.size.y, x) * (1.0f - e.size.z * particleRandom(q.info.y, 1u));
        discs[2u * k] = float4(q.position.xyz, r);
        discs[2u * k + 1u] = float4(particleColor(e, x).a * e.extra.z, 0.0f, 0.0f, 0.0f);
        // Where it shows: its centre's place in the view, as wide as its radius at its depth (and half again: a
        // disc off the view's axis looks wider). Close to the camera, anywhere.
        float3 p = q.position.xyz - u.camPos.xyz;
        float z = dot(p, u.camForward.xyz);
        if (z <= 1.5f * r) { rect = float4(0.0f, 0.0f, 1.0f, 1.0f); continue; }
        float2 c = float2(dot(p, u.camRight.xyz) / (z * u.camRight.w), dot(p, u.camUp.xyz) / (z * u.camUp.w));
        float2 h = 1.5f * r / z / float2(u.camRight.w, u.camUp.w);
        float2 lo = (float2(c.x - h.x, -(c.y + h.y)) + 1.0f) * 0.5f, hi = (float2(c.x + h.x, -(c.y - h.y)) + 1.0f) * 0.5f;
        rect = float4(min(rect.xy, lo), max(rect.zw, hi));
    }
    threadgroup float4 parts[32];
    rect = float4(simd_min(rect.x), simd_min(rect.y), simd_max(rect.z), simd_max(rect.w));
    if (lane == 0u) parts[group] = rect;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (i == 0u) {
        for (uint g = 1; g < (n + 31u) / 32u; ++g) rect = float4(min(rect.xy, parts[g].xy), max(rect.zw, parts[g].zw));
        discs[2u * dp.count] = rect;
    }
}

kernel void particleDistortKernel(constant Uniforms&                u         [[buffer(0)]],
                                  constant ParticleDistortParams&   dp        [[buffer(1)]],
                                  constant float4*                  discs     [[buffer(17)]],
                                  texture2d<float, access::sample>  src       [[texture(0)]],
                                  texture2d<float, access::write>   dst       [[texture(1)]],
                                  texture2d<float, access::read>    nd        [[texture(2)]],
                                  uint2 tid [[thread_position_in_grid]])
{
    uint2 size = uint2(dst.get_width(), dst.get_height());
    if (tid.x >= size.x || tid.y >= size.y) return;
    float2 uv = (float2(tid) + 0.5f) / float2(size);
    float3 o = u.camPos.xyz, d = normalize(viewDirection(u, uv));
    float along = max(dot(d, u.camForward.xyz), 1e-4f);
    // Most pixels meet none: outside the discs' part of the view, a copy; the surface's depth only where one is met.
    float4 rect = discs[2u * dp.count];
    if (any(uv < rect.xy) || any(uv > rect.zw)) {
        dst.write(src.read(tid), tid);
        return;
    }
    float tOpaque = -1.0f;
    float amount = 0.0f, tNear = 1.0e5f, tMean = 0.0f;
    for (uint k = 0; k < dp.count; ++k) {
        float4 c = discs[2u * k];
        float t = dot(c.xyz - o, d);
        float rho2 = length_squared(o + d * t - c.xyz) / max(c.w * c.w, 1e-8f);
        if (t <= 0.05f || rho2 >= 1.0f) continue;
        if (tOpaque < 0.0f) {
            float depth = particleClipDepth(nd, uv);
            tOpaque = depth > 0.0f ? depth / along : 1.0e5f;
        }
        if (t >= tOpaque) continue;
        float w = (1.0f - rho2) * (1.0f - rho2) * discs[2u * k + 1u].x;
        amount += w;
        tMean += w * t;
        tNear = min(tNear, t);
    }
    if (amount <= 0.0f) {
        dst.write(src.read(tid), tid);
        return;
    }
    float3 n = particleCurl(o + d * (tMean / amount), PARTICLE_HAZE_FREQUENCY, -dp.time * PARTICLE_HAZE_RISE * PARTICLE_HAZE_FREQUENCY)
             * (1.0f / PARTICLE_HAZE_FREQUENCY);
    float3 bent = normalize(d + (n - d * dot(n, d)) * min(amount, PARTICLE_HAZE_MOST));
    float f = max(dot(bent, u.camForward.xyz), 1e-4f);
    float2 to = float2(dot(bent, u.camRight.xyz) / (f * u.camRight.w) + 1.0f, 1.0f - dot(bent, u.camUp.xyz) / (f * u.camUp.w)) * 0.5f;
    float there = particleClipDepth(nd, saturate(to));
    if (there > 0.0f && there < tNear * along) to = uv;
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    dst.write(src.sample(linear, to), tid);
}
