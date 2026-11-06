// =============================================================================================
// World cache (WorldRadianceCache.swift): irradiance probes in world space around the camera, DDGI-style, for the
// radiance cascades' hidden hits. A cascade ray's hit that wasn't on screen last frame (off screen, occluded) has no
// last-frame light of its own; it took the mean light of all the probes, one number for the whole frame, which reads
// too bright in a forest's later bounces and too dark in a courtyard's (plan rc-emitters-and-world-cache, A0). Here it
// takes the light of the probes around it.
//
// Levels (up to 3) of 32 x 16 x 32 probes, level l's spacing 3^l times level 0's, each centred on the camera in whole
// cells and stored toroidally (a cell's slot is its position mod the grid), so a step of the camera keeps every probe
// still inside where it is. A probe is valid while its state holds its own cell and this epoch: a probe a scroll gave
// a new cell, or a reset (a new epoch), is invalid until traced again, and the lookups skip it.
// Each frame a slice of every level's probes (WorldCacheGrid.updateRange) traces 64 rays, shaded as a cascade's hit
// (with the cache's own light at the hit: more bounces each update), and blends them into the probe's 6x6 octahedral
// irradiance (cosine-weighted mean radiance, E / pi: the units of a cascade hit's `light`) and distance moments, each
// in an 8x8 tile with a border that copies the octahedral neighbours, for hardware bilinear filtering.
// =============================================================================================

struct WorldCacheParams {
    float4 level[3];   // w = spacing (m)
    int4   origin[3];  // xyz = the grid's min-corner cell
    uint4  update;     // x = the first slot traced this frame, y = how many per level, z = levels, w = epoch
    float4 blend;      // x = hysteresis, y = the distance moments' range in spacings, z = 1: sun rays at hits
};
static_assert(sizeof(WorldCacheParams) == 128, "WorldCacheParams must match GPUTypes.swift");

constant int3 WRC_SIZE = int3(32, 16, 32);
constant uint WRC_PROBES = 16384u;
constant uint WRC_RAYS = 64u;
constant int WRC_TILE = 8;              // 6x6 octahedral texels and a 1-texel border
constant int WRC_INNER = 6;
constant float WRC_INSIDE = 0.25f;      // a probe with more of its rays on back faces is inside something
constant float WRC_DEPTH_SHARPNESS = 50.0f;
constant float WRC_CHEB_FLOOR = 0.05f;       // least visibility weight of a probe a wall hides (0 changed nothing, Nov 6)
constant float WRC_NORMAL_BIAS = 0.25f;      // the lookup point off the surface, in spacings (0.05 changed nothing)
constant float WRC_FEEDBACK = 1.0f;          // the cache's own light at its rays' hits (bounces); 0: one bounce only

// Toroidal slot of a cell, and the cell in the window origin ..< origin + size that has a slot (WorldCacheGrid).
inline uint wrcSlot(int3 cell) {
    int3 m = ((cell % WRC_SIZE) + WRC_SIZE) % WRC_SIZE;
    return uint(m.x + WRC_SIZE.x * (m.y + WRC_SIZE.y * m.z));
}
inline int3 wrcCell(uint slot, int3 origin) {
    int3 m = int3(int(slot) % WRC_SIZE.x, (int(slot) / WRC_SIZE.x) % WRC_SIZE.y, int(slot) / (WRC_SIZE.x * WRC_SIZE.y));
    int3 o = ((origin % WRC_SIZE) + WRC_SIZE) % WRC_SIZE;
    return origin + (m - o + WRC_SIZE) % WRC_SIZE;
}
// A slot's tile in the atlases (4096 x 256 texels) and its texel in the state texture (512 x 32).
inline uint2 wrcStateTexel(uint slot) { return uint2(slot % 512u, slot / 512u); }
inline float3 wrcProbePosition(int3 cell, float spacing) { return (float3(cell) + 0.5f) * spacing; }

// Ray i of a probe's 64 this frame: a spherical Fibonacci set, turned by a rotation drawn per frame (the same for every
// probe and in both kernels), so the updates cover the sphere over frames.
inline float3x3 wrcRotation(uint frame) {
    uint h1 = pcgHash(frame * 0x9E3779B9u + 17u), h2 = pcgHash(h1), h3 = pcgHash(h2);
    float u1 = float(h1 >> 8) * (1.0f / 16777216.0f), u2 = float(h2 >> 8) * (1.0f / 16777216.0f) * 2.0f * M_PI_F,
          u3 = float(h3 >> 8) * (1.0f / 16777216.0f) * 2.0f * M_PI_F;
    float4 q = float4(sqrt(1.0f - u1) * sin(u2), sqrt(1.0f - u1) * cos(u2), sqrt(u1) * sin(u3), sqrt(u1) * cos(u3));
    float x = q.x, y = q.y, z = q.z, w = q.w;
    return float3x3(float3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
                    float3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
                    float3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)));
}
inline float3 wrcRayDirection(uint i, float3x3 rotation) {
    float phi = 2.0f * M_PI_F * fract(float(i) * 0.6180339887f);
    float cosTheta = 1.0f - (2.0f * float(i) + 1.0f) / float(WRC_RAYS);
    float sinTheta = sqrt(saturate(1.0f - cosTheta * cosTheta));
    return rotation * float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
}

// The texel of a probe's tile in direction `dir`, as normalized coordinates for a bilinear sample.
inline float2 wrcTileUV(uint slot, float3 dir) {
    uint tile = slot % 512u, row = slot / 512u;
    float2 inner = (equalAreaOctEncode(dir) * 0.5f + 0.5f) * float(WRC_INNER) + 1.0f;
    return (float2(tile * WRC_TILE, row * WRC_TILE) + inner) / float2(512 * WRC_TILE, 32 * WRC_TILE);
}

constexpr sampler wrcSampler(coord::normalized, filter::linear, address::clamp_to_edge);

// Irradiance at p with normal n from the probes around it (rgb, E / pi), w = 1 where some valid probe gave it, else 0.
// The finest level whose interior holds p; trilinear over its 8 probes, weighted DDGI's way (probes behind the surface
// count less, probes a wall hides from p by their distance moments count almost nothing). Invalid probes, and probes
// inside something, are left out; if none is left the next level is asked.
inline float4 wrcIrradiance(float3 p, float3 n, constant WorldCacheParams& c,
                            texture2d_array<float> irradiance, texture2d_array<float> distance,
                            texture2d_array<float, access::read> state) {
    for (uint l = 0; l < c.update.z; ++l) {
        float spacing = c.level[l].w;
        float3 q = p + n * (WRC_NORMAL_BIAS * spacing);   // off the surface, as DDGI's normal bias
        float3 g = q / spacing - 0.5f;
        int3 base = int3(floor(g));
        int3 o = c.origin[l].xyz;
        if (any(base < o) || any(base + 1 > o + WRC_SIZE - 1)) continue;
        float3 f = g - float3(base);
        float3 sum = float3(0.0f);
        float wsum = 0.0f;
        for (uint k = 0; k < 8u; ++k) {
            int3 corner = int3(k & 1u, (k >> 1) & 1u, k >> 2);
            int3 cell = base + corner;
            uint slot = wrcSlot(cell);
            float4 st = state.read(wrcStateTexel(slot), l);
            if (any(int3(st.xyz) != cell) || uint(st.w) != c.update.w) continue;
            float4 e = irradiance.sample(wrcSampler, wrcTileUV(slot, n), l, level(0.0f));
            if (e.a > WRC_INSIDE) continue;
            float3 toProbe = wrcProbePosition(cell, spacing) - q;
            float d = length(toProbe);
            float3 v = d > 1e-4f ? toProbe / d : n;
            float facing = (dot(v, n) + 1.0f) * 0.5f;
            float w = facing * facing + 0.2f;
            float2 m = distance.sample(wrcSampler, wrcTileUV(slot, -v), l, level(0.0f)).rg;
            if (d > m.x) {
                float variance = abs(m.y - m.x * m.x);
                float cheb = variance / (variance + (d - m.x) * (d - m.x));
                w *= max(cheb * cheb * cheb, WRC_CHEB_FLOOR);
            }
            float3 t = mix(1.0f - f, f, float3(corner));
            w = max(w, 1e-6f) * t.x * t.y * t.z;
            sum += e.rgb * w;
            wsum += w;
        }
        if (wsum > 1e-4f) return float4(sum / wsum, 1.0f);
    }
    return float4(0.0f);
}

// One thread per (traced probe, ray): this frame's slice of every level. rays[] = rgb radiance, w = the hit's distance
// (negative: a back face; a miss: a large distance).
kernel void wrcTraceKernel(constant Uniforms&               u          [[buffer(0)]],
                           SCENE_ACCEL                      accel      [[buffer(1)]],
                           device const float3*             positions  [[buffer(2)]],
                           device const float3*             normals    [[buffer(3)]],
                           device const uint*               indices    [[buffer(4)]],
                           device const MeshData*           meshes     [[buffer(5)]],
                           device const InstanceData*       instances  [[buffer(6)]],
                           constant SceneShading&           shading    [[buffer(7)]],
                           device const Light*              lights     [[buffer(8)]],
                           constant WorldCacheParams&       c          [[buffer(9)]],
                           device float4*                   rays       [[buffer(10)]],
                           device const RegirReservoir*     regirGrid  [[buffer(11)]],
                           constant RegirParams&            regir      [[buffer(12)]],
                           texture2d_array<float, access::read> lightMap [[texture(0)]],
                           texture2d_array<float>           irradiance [[texture(1)]],
                           texture2d_array<float>           distance   [[texture(2)]],
                           texture2d_array<float, access::read> state  [[texture(3)]],
                           uint gid [[thread_position_in_grid]])
{
    uint perLevel = c.update.y;
    if (gid >= c.update.z * perLevel * WRC_RAYS) return;
    uint ray = gid % WRC_RAYS, traced = gid / WRC_RAYS;
    uint l = traced / perLevel, slot = c.update.x + traced % perLevel;
    if (slot >= WRC_PROBES) return;
    float spacing = c.level[l].w;
    float3 origin = wrcProbePosition(wrcCell(slot, c.origin[l].xyz), spacing);
    float3 dir = wrcRayDirection(ray, wrcRotation(u.frameIndex));

    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, lights, u.lightCount);
    bindLightSampling(s, u.lightTable, regirGrid, regir);
    Ray r = makeRay(origin, dir, 0.0f, INFINITY);
    Surface h = traceSurface(r, rayMask(MASK_GEOMETRY, RAY_GI), accel, s, GI_RAY_SPREAD);
    float4 result;
    if (h.hit) {
        float t = length(h.position - origin);
        // A back face by the surface's own normal, not the triangle's: geomNormal follows the winding, which no other
        // pass needs consistent (surfaces are two-sided), and the courtyard's ground faced down: every probe above it
        // was "inside" and the cache had no light over 44% of the frame.
        if (dot(dir, h.normal) > 0.0f && !h.backlit) {
            result = float4(0.0f, 0.0f, 0.0f, -t);   // inside something: no light, and it counts toward WRC_INSIDE
        } else {
            float3 hng, hns;
            orientNormals(h, dir, hng, hns);
            float3 hp = h.position + hng * RAY_EPSILON;
            bool emitters = flagOn(u.flags, FLAG_CASCADE_EMITTERS);
            float3 light = giLightIllum(lights, u, lightMap, hp, hns, hng, pcgHash(gid + pcgHash(u.frameIndex + 7u)), accel, s,
                                        c.blend.z > 0.0f, emitters);
            light += WRC_FEEDBACK * wrcIrradiance(h.position, hns, c, irradiance, distance, state).rgb;   // last updates' light: bounces
            float3 radiance = hitAlbedo(h, flagOn(u.flags, FLAG_ENERGY)) * light;
            if (emitters) radiance += cascadeEmission(h, origin);
            result = float4(radiance, t);
        }
    } else {
        result = float4(skyRadiance(u, s, dir, 2.0f), 1e4f);
    }
    rays[traced * WRC_RAYS + ray] = result;
}

// The interior texel of a probe's 6x6 tile that border texel i (-1...6) copies: an octahedral map's edges fold onto
// themselves mirrored, its corners onto the opposite corner.
inline int2 wrcBorderSource(int2 i) {
    bool bx = i.x < 0 || i.x >= WRC_INNER, by = i.y < 0 || i.y >= WRC_INNER;
    if (bx && by) return int2(i.x < 0 ? WRC_INNER - 1 : 0, i.y < 0 ? WRC_INNER - 1 : 0);
    if (bx) return int2(clamp(i.x, 0, WRC_INNER - 1), WRC_INNER - 1 - i.y);
    if (by) return int2(WRC_INNER - 1 - i.x, clamp(i.y, 0, WRC_INNER - 1));
    return i;
}

// One threadgroup (64 threads) per traced probe, a thread per texel of its 8x8 tiles: the rays into threadgroup memory,
// then each texel's cosine-weighted mean radiance and distance moments, blended with what the probe held if it was
// valid (this cell, this epoch) or taken whole if not; then thread 0 marks the probe valid.
kernel void wrcBlendKernel(constant Uniforms&               u          [[buffer(0)]],
                           constant WorldCacheParams&       c          [[buffer(9)]],
                           device const float4*             rays       [[buffer(10)]],
                           texture2d_array<float, access::read_write> irradiance [[texture(1)]],
                           texture2d_array<float, access::read_write> distance   [[texture(2)]],
                           texture2d_array<float, access::read_write> state      [[texture(3)]],
                           uint traced [[threadgroup_position_in_grid]],
                           uint texel [[thread_index_in_threadgroup]])
{
    threadgroup float4 shared[WRC_RAYS];
    threadgroup float3 directions[WRC_RAYS];
    uint perLevel = c.update.y;
    uint l = traced / perLevel, slot = c.update.x + traced % perLevel;
    bool live = traced < c.update.z * perLevel && slot < WRC_PROBES;
    float3x3 rotation = wrcRotation(u.frameIndex);
    if (live) {
        shared[texel] = rays[traced * WRC_RAYS + texel];
        directions[texel] = wrcRayDirection(texel, rotation);
    }
    int3 cell = live ? wrcCell(slot, c.origin[l].xyz) : int3(0);
    uint2 st = wrcStateTexel(slot);
    float4 old = live ? state.read(st, l) : float4(0.0f);
    bool valid = live && all(int3(old.xyz) == cell) && uint(old.w) == c.update.w;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (!live) return;

    int2 t = int2(texel % uint(WRC_TILE), texel / uint(WRC_TILE));
    int2 src = wrcBorderSource(t - 1);
    float3 n = equalAreaOctDecode((float2(src) + 0.5f) / float(WRC_INNER) * 2.0f - 1.0f);
    float range = c.blend.y * c.level[l].w;
    float3 e = float3(0.0f);
    float ew = 0.0f, back = 0.0f, d1 = 0.0f, d2 = 0.0f, dw = 0.0f;
    for (uint i = 0; i < WRC_RAYS; ++i) {
        float4 r = shared[i];
        float cosine = dot(n, directions[i]);
        back += r.w < 0.0f ? 1.0f : 0.0f;
        if (cosine <= 0.0f) continue;
        e += r.rgb * cosine;
        ew += cosine;
        float d = min(abs(r.w), range);
        float w = pow(cosine, WRC_DEPTH_SHARPNESS);
        d1 += d * w;
        d2 += d * d * w;
        dw += w;
    }
    float4 newE = float4(ew > 0.0f ? e / ew : float3(0.0f), back / float(WRC_RAYS));
    float2 newD = dw > 0.0f ? float2(d1, d2) / dw : float2(range, range * range);
    uint2 at = uint2(slot % 512u, slot / 512u) * uint(WRC_TILE) + uint2(t);
    if (valid) {
        float h = c.blend.x;
        newE = mix(newE, irradiance.read(at, l), h);
        newD = mix(newD, distance.read(at, l).rg, h);
    }
    irradiance.write(newE, at, l);
    distance.write(float4(newD, 0.0f, 0.0f), at, l);
    threadgroup_barrier(mem_flags::mem_texture);
    if (texel == 0) state.write(float4(float3(cell), float(c.update.w)), st, l);
}
