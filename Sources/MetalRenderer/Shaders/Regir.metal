// ---------------------------------------------------------------------------------------------
// Light grid (ReGIR, Boksansky et al. 2021): a camera-centred world-space grid of light reservoirs, rebuilt every frame
// from the current lights (regirBuildKernel), so ReSTIR DI's candidates come from the lights near the pixel instead of
// the whole table by power. Each cell keeps `slots` reservoirs; each is the RIS pick of `candidates` table draws by an
// orientation-free target (intensity toward the cell centre over the clamped squared distance: positive for every
// element with power, so a cell covers the whole light domain and a draw from it stays unbiased), with W = 1 / its
// effective pdf. Cascaded levels (cell size x levelScale per level) give fine cells near the camera; a point outside
// every level falls back to the table. The levels' origins move with the camera and are jittered per frame.
// ---------------------------------------------------------------------------------------------

constant uint REGIR_MAX_LEVELS = 4;

struct RegirParams {
    float4 origin[REGIR_MAX_LEVELS];   // xyz = the level's (jittered) origin, w = its cell size
    uint4  config;                     // x = cells per axis, y = levels, z = slots per cell, w = candidates per slot
    uint4  consume;                    // x = grid candidates per pixel (0 = grid off), y = frame seed
};

static_assert(sizeof(RegirParams) == 96, "RegirParams: GPURegirParams");

struct RegirReservoir { uint element; uint uv; float W; float target; };   // uv packed unorm2x16; target = the cell's
static_assert(sizeof(RegirReservoir) == 16, "RegirReservoir: GPURegirReservoir");

struct RegirCell { uint base; bool valid; };   // base = the first slot of the point's cell

// The cell of p in the finest level that contains it, moved by `jitter` cells (in [-0.5, 0.5)^3, clamped to the
// level): drawing each candidate from a jittered cell blends the neighbouring cells' reservoirs in, so a pixel's
// candidates come from up to 8 cells and the cell boundaries don't show.
inline RegirCell regirLookup(constant RegirParams& gp, float3 p, float3 jitter = float3(0.0f)) {
    uint cells = gp.config.x, perLevel = cells * cells * cells * gp.config.z;
    for (uint level = 0; level < gp.config.y; ++level) {
        float3 q = (p - gp.origin[level].xyz) / gp.origin[level].w;
        if (all(q >= 0.0f) && all(q < float(cells))) {
            uint3 c = uint3(clamp(q + jitter, 0.0f, float(cells) - 0.001f));
            return { level * perLevel + ((c.z * cells + c.y) * cells + c.x) * gp.config.z, true };
        }
    }
    return { 0u, false };
}

// How many of a sampler's M candidates come from the grid at p (the rest from the table): all but one, when the
// kernel bound the grid and p is inside it. The secondary hits, the reflections and the fog have no reuse, so this
// is where better candidates show most.
inline uint regirShare(thread const SceneData& s, float3 p, uint M, thread RegirCell& cell) {
    if (s.regir == nullptr || s.regir->consume.x == 0 || M < 2) return 0u;
    cell = regirLookup(*s.regir, p);
    return cell.valid ? M - 1 : 0u;
}

// One grid candidate at p: a reservoir of p's cell, the cell jittered by up to half a cell so the neighbouring cells
// blend in. W is its 1 / effective pdf. False for an empty reservoir.
inline bool regirDraw(thread const SceneData& s, float3 p, thread Rng& rng, thread uint& element, thread float2& uv,
                      thread float& W) {
    float3 jitter = float3(rng.next(), rng.next(), rng.next()) - 0.5f;
    RegirReservoir g = s.regirGrid[regirLookup(*s.regir, p, jitter).base + mulhi(rng.nextUint(), s.regir->config.z)];
    element = g.element; uv = unpack_unorm2x16_to_float(g.uv); W = g.W;
    return element != ELEMENT_NONE && W > 0.0f;
}

// The cell's target for a light sample: its luminance toward the cell centre as E / pi, like lightUnshadowed, with
// every cosine, cone and facing test dropped (their maximum over orientations), so it is positive wherever the
// sample could light anything in the cell. dmin2 clamps the distance to the cell's half diagonal.
inline float regirCellTarget(uint element, float2 uv, float3 centre, float dmin2, device const Light* lights,
                             device const TriangleInfo* tris, thread const SceneData& s) {
    uint index = element & ELEMENT_INDEX;
    if ((element & ELEMENT_TYPE) == ELEMENT_TRIANGLE) {
        MeshLightPoint mp = triangleLightPoint(s, lights, tris, index, uv, false);
        float d2 = max(length_squared(mp.x - centre), dmin2);
        return tris[index].radianceLum * (0.5f * mp.area2) / (M_PI_F * d2);
    }
    // Field by field: the first 32 bytes serve every type but the rect (its area is in params).
    float4 positionRadius = lights[index].positionRadius, color = lights[index].color;
    uint type = uint(color.w) >> 2;
    float lum = luminance(color.rgb);
    if (type == LIGHT_SUN) return lum / M_PI_F;   // a third sun or more: in the table as irradiance
    float d2 = max(max(length_squared(positionRadius.xyz - centre), dmin2), positionRadius.w * positionRadius.w);
    if (type == LIGHT_RECT) { float4 params = lights[index].params; lum *= 4.0f * length(params.xyz) * params.w; }   // radiance x area
    else if (type == LIGHT_MESH) lum *= 0.25f;                                          // its proxy's mean intensity
    return lum / (M_PI_F * d2);
}

// One thread per reservoir slot: `candidates` table draws, resampled by the cell's target.
kernel void regirBuildKernel(constant Uniforms&         u         [[buffer(0)]],
                             device const InstanceData* instances [[buffer(6)]],
                             constant SceneShading&     shading   [[buffer(7)]],
                             device const Light*        lights    [[buffer(8)]],   // + the light table
                             device RegirReservoir*     grid      [[buffer(11)]],
                             constant RegirParams&      gp        [[buffer(12)]],
                             uint tid [[thread_position_in_grid]])
{
    uint cells = gp.config.x, slots = gp.config.z, perLevel = cells * cells * cells;
    uint cellIndex = tid / slots, level = cellIndex / perLevel, c = cellIndex % perLevel;
    if (level >= gp.config.y) return;
    uint3 cc = uint3(c % cells, (c / cells) % cells, c / (cells * cells));
    float cellSize = gp.origin[level].w;
    float3 centre = gp.origin[level].xyz + (float3(cc) + 0.5f) * cellSize;
    float dmin2 = 0.75f * cellSize * cellSize;
    SceneData s = sceneLights(instances, shading, lights, u.lightCount);
    device const LightTableEntry* entries = lightTableEntries(lights, u.lightCount);
    device const TriangleInfo* tris = lightTableTriangles(lights, u.lightCount, u.lightTable.x);
    Rng rng;
    rng.state = pcgHash(tid + pcgHash(gp.consume.y ^ 0x7F4A7C15u));
    uint K = gp.config.w, picked = ELEMENT_NONE;
    float2 pickedUV = float2(0.0f);
    float wSum = 0.0f, pickedTarget = 0.0f;
    for (uint k = 0; k < K; ++k) {
        float pdf = 1.0f;
        uint h0 = rng.nextUint(), h1 = rng.nextUint();
        uint element = sampleLightTable(entries, u.lightTable.x, h0, h1, pdf);
        float2 uv = quantizeUV(rng.next2());
        float t = regirCellTarget(element, uv, centre, dmin2, lights, tris, s);
        float w = t / (float(K) * pdf);
        if (w <= 0.0f) continue;
        wSum += w;
        if (rng.next() * wSum < w) { picked = element; pickedUV = uv; pickedTarget = t; }
    }
    RegirReservoir r;
    r.element = picked;
    r.uv = pack_float_to_unorm2x16(pickedUV);
    r.W = pickedTarget > 0.0f ? wSum / pickedTarget : 0.0f;
    r.target = pickedTarget;
    grid[tid] = r;
}
