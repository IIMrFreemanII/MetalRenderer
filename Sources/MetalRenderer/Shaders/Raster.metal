// ---------------------------------------------------------------------------------------------
// Raster visibility buffer (PrimaryVisibility.raster, RasterScene.swift): the camera's triangles drawn by the
// hardware rasterizer instead of traced, GPU driven and culled the way Unreal's Nanite does it.
//
// The scene's triangles are drawn in chunks of up to RASTER_CHUNK consecutive triangles of an instance's mesh (a
// cluster, but for the order: the mesh's own). Each frame:
//   1. rasterCullKernel, pass 1: instances in the view that were visible last frame are kept, as groups of 64
//      chunks; rasterChunksKernel culls each chunk against the view and appends it to the pass's draw list, which
//      one indirect draw rasterizes (rasterVertex / rasterFragment): instance and triangle ids, and depth.
//   2. hzbInitKernel / hzbReduceKernel: the depth's hierarchical-Z pyramid (the farthest depth of each texel).
//   3. rasterCullKernel, pass 2: every instance in the view is tested against it. Those not drawn in pass 1 that
//      pass go through the chunks (tested too) and a second draw over the same targets; and every instance's
//      result is what the next frame's pass 1 starts from.
// traceKernel then meets each pixel's triangle with its primary ray (visibilityHit) instead of tracing it, so the
// G-buffer is the one a traced ray would make, bar the pixels on a triangle's edge.
// What isn't drawn (leaf cards, an assembly's parts, swaying ground cover, an instance finer than the pixels) draws its
// bounding box instead, with RASTER_TRACE_ID: the pixels where the box is in front trace their primary ray (all it
// covers, when it reaches the camera). When the draw lists are full, every primary ray traces too (RasterTraced).
// ---------------------------------------------------------------------------------------------

constant uint RASTER_CHUNK = 128;              // triangles a chunk
constant uint RASTER_CHUNK_VERTICES = 3 * RASTER_CHUNK;
constant uint RASTER_GROUP = 64;               // chunks a group (rasterChunksKernel's threadgroup)
constant uint RASTER_NO_ID = 0xFFFFFFFFu;      // the visibility buffer's clear value: nothing drawn
constant uint RASTER_TRACE_ID = 0xFFFFFFFEu;   // a box around what isn't drawn: trace the primary ray here
// The visibility buffer's y for a cluster's triangle: this | its entry in the frame's cluster list << 7 | the triangle
// (a cluster has at most 128).
constant uint RASTER_CLUSTER_ID = 0x80000000u;
// RasterClusters' per-frame state (uints): RVG_HEADER words of counters, then per virtual instance its RasterInstance
// (16 words) as rasterCullKernel left it, then per virtual instance 1 if it is in view.
constant uint RVG_HEADER = 16;
// A heavy instance (more than RASTER_HEAVY triangles) with more than RASTER_MAX_DENSITY of them per pixel its bounds
// cover is traced, not drawn: there's no level of detail to draw it at (a far crowd, Metal's tracer's baked plants),
// and past that the box's traced pixels cost less than the triangles (the crowd: 16 a pixel 13.2 ms a frame, 4 12.2,
// 1 12.4, on an M1 Max in split mode).
constant uint RASTER_HEAVY = 4096;
constant float RASTER_MAX_DENSITY = 4.0f;

// RasterMesh.kind: how a mesh's triangles are read, if they are drawn (RasterScene.Kind).
constant uint RASTER_SKIP    = 0;              // traced instead (its box is drawn): leaf cards, swaying ground cover...
constant uint RASTER_ARRAYS  = 1;              // the scene's arrays (MeshData.firstIndex, vertexOffset)
constant uint RASTER_BLOCK   = 2;              // a mesh in a buffer of its own (MeshData.block)
constant uint RASTER_VIRTUAL = 3;              // virtual geometry: its instance's BLAS over this frame's cut (VGBlas)
constant uint RASTER_BOX     = 4;              // (a draw's) the instance's bounding box, as 12 triangles, RASTER_TRACE_ID
constant uint RASTER_CLUSTERS = 5;             // virtual geometry as clusters (RasterClusters.metal): a draw is one cluster
constant uint RASTER_KIND    = 0xFu;
constant uint RASTER_DEFORMS = 16;             // a crowd's pose slot: no chunk bounds (they move), loose instance bounds
constant uint RASTER_NEAR    = 32;             // (a box's draw) it reaches the camera: drawn in front of everything

// One per mesh index of the instances' records (RasterScene.meshes): ordinary meshes, the virtual ones, the assemblies.
struct RasterMesh {
    float4 lo;       // xyz = object-space bounds, w = (bits) its first chunk among the chunks' bounds
    float4 hi;       // xyz, w = (bits) RASTER_* kind | flags
};
static_assert(sizeof(RasterMesh) == 32, "RasterMesh: GPURasterMesh");

// GPURasterParams.
struct RasterParams {
    uint instanceCount;   // the instances' records, counted through (the blocks' after the scene's own)
    uint meshCount;       // RasterMesh records
    uint chunkCount;      // chunks with bounds (rasterBoundsKernel)
    uint flags;           // RASTER_P_*
    uint maxDraws;        // per pass
    uint maxGroups;       // per pass
    uint hzbLevels;
    uint pass;            // 0 or 1
    uint2 hzbSize;        // level 0: half the frame's size, rounded up to a power of two
    uint firstAssembly;   // the assemblies' first RasterMesh
    uint virtualCount;    // virtual instances drawn as clusters (their state's places), else 0
};
static_assert(sizeof(RasterParams) == 48, "RasterParams: GPURasterParams");

constant uint RASTER_P_IDS = 1;        // a table maps an instance's place to its id (Metal's tracer with blocks: TILED)
constant uint RASTER_P_HZB = 2;        // pass 2 tests against the pyramid (off on a target's first frame)

constant uint RASTER_ASSEMBLY = 0x80000000u;   // a block's record's meshIndex: this | its assembly (InstanceBlock.assembly)

// RasterScene.visible, per instance: drawn (pass 2's verdict, which the next frame's pass 1 starts from), and between
// the passes whether pass 1 found it in view (pass 2 looks again at those only).
constant uint RASTER_VISIBLE = 1;
constant uint RASTER_IN_VIEW = 2;

// Per pass: the draw's indirect arguments, then rasterChunksKernel's. After both passes' comes one more word,
// RasterTraced: set when something in view isn't drawn (no room in the lists), so traceKernel traces its primary rays too.
struct RasterCounters {
    atomic_uint vertexCount;     // MTLDrawPrimitivesIndirectArguments
    uint instanceCount;
    uint vertexStart;
    uint baseInstance;
    atomic_uint groupsX;         // MTLDispatchThreadgroupsIndirectArguments
    uint groupsY;
    uint groupsZ;
    atomic_uint groups;          // groups appended
};
static_assert(sizeof(RasterCounters) == 32, "RasterCounters: Renderer.rasterCountersStride");
inline device atomic_uint* rasterTraced(device RasterCounters* counters) { return (device atomic_uint*)(counters + 2); }

// A virtual instance's BLAS over its current cut (VirtualBLAS.Entry; the custom tracer's VGBlas): its triangles as
// v0, e1, e2. Bound on either tracer (Metal's has no virtual instances).
struct VGBlasEntry {
    ulong                 nodes;
    device const float4*  tris;
    device const uint*    attrs;
    uint                  triangles;
    uint                  pad;
};
static_assert(sizeof(VGBlasEntry) == 32, "VGBlasEntry: VirtualBLAS.Entry");

// A drawn instance, as its pass's rasterCullKernel wrote it (at the place of its first group): all its vertices need,
// so a vertex reads this, an index and a position rather than the instance's and its mesh's records.
struct RasterInstance {
    float4 x, y, w;                  // object space to clip x, y and w (rasterClip; z is NEAR_PLANE)
    device const float3* corners;    // the corners: positions (arrays, block), v0 e1 e2 (virtual, float4), lo hi (box, float4)
    device const uint*   indices;    // arrays, block: the mesh's first index
};
static_assert(sizeof(RasterInstance) == 64, "RasterInstance: RasterTargets.recordSize");

// The frame's clip position of an instance's points, as the primary rays see them: the ray through pixel
// p + 0.5 + jitter lands on pixel p's centre (raster samples at centres), and z / w is the reversed depth
// NEAR_PLANE / view depth. Its rows for clip x, y and w, from the object space (`m` to world), relative to the camera.
inline RasterInstance rasterProjection(float4x4 m, constant Uniforms& u) {
    float4x4 rel = m;
    rel[3].xyz -= u.camPos.xyz;
    float3 f = u.camForward.xyz;
    float3 a = u.camRight.xyz / u.camRight.w - 2.0f * u.jitter.x / float(u.width) * f;
    float3 b = u.camUp.xyz / u.camUp.w + 2.0f * u.jitter.y / float(u.height) * f;
    RasterInstance r;
    r.x = float4(a, 0.0f) * rel;     // (transpose(rel) * a: a's dot with the camera-relative world point)
    r.y = float4(b, 0.0f) * rel;
    r.w = float4(f, 0.0f) * rel;
    r.corners = nullptr;
    r.indices = nullptr;
    return r;
}

// The same rows for the last frame: its transform, camera and jitter (what the last frame's depth pyramid saw).
inline RasterInstance rasterProjectionPrev(float4x4 m, constant Uniforms& u) {
    float4x4 rel = m;
    rel[3].xyz -= u.prevCamPos.xyz;
    float3 f = u.prevCamForward.xyz;
    float3 a = u.prevCamRight.xyz / u.prevCamRight.w - 2.0f * u.jitter.z / float(u.width) * f;
    float3 b = u.prevCamUp.xyz / u.prevCamUp.w + 2.0f * u.jitter.w / float(u.height) * f;
    RasterInstance r;
    r.x = float4(a, 0.0f) * rel;
    r.y = float4(b, 0.0f) * rel;
    r.w = float4(f, 0.0f) * rel;
    r.corners = nullptr;
    r.indices = nullptr;
    return r;
}

inline float4 rasterClip(float3 local, thread const RasterInstance& r) {
    float4 p = float4(local, 1.0f);
    return float4(dot(r.x, p), dot(r.y, p), NEAR_PLANE, dot(r.w, p));
}

// A mesh's triangle's corner `k`, object space (the vertices fetchHitVertices reads).
inline float3 rasterCorner(uint kind, MeshData mesh, uint prim, uint k, device const float3* positions, device const uint* indices) {
    if (kind == RASTER_BLOCK) {
        device const uint* own = (device const uint*)((device const float2*)(mesh.block + 2u * mesh.vertexCount) + mesh.vertexCount);
        return mesh.block[own[prim * 3u + k]];
    }
    return positions[indices[mesh.firstIndex + prim * 3u + k] + mesh.vertexOffset];
}

// Corner `corner` of triangle `prim` of a drawn mesh, object space: its index and position (arrays, block), or v0 + e1
// / e2 (virtual geometry's BLAS triangles; `corners` is then its float4s).
inline float3 rasterTriangleCorner(uint kind, device const float3* corners, device const uint* indices, uint prim, uint corner) {
    if ((kind & RASTER_KIND) == RASTER_VIRTUAL) {
        device const float4* tris = (device const float4*)corners;
        return tris[3u * prim].xyz + (corner == 0u ? float3(0.0f) : tris[3u * prim + corner].xyz);
    }
    return corners[indices[prim * 3u + corner]];
}

// Whether a box (object space, `r` to clip) may show: false when it is outside the view, or (with `hzb`) behind
// what the pyramid holds at every pixel it covers. `pixels`: how many its screen rectangle covers (infinite when it
// crosses the near plane).
inline bool rasterBoxVisible(float3 lo, float3 hi, thread const RasterInstance& r, constant Uniforms& u, constant RasterParams& rp,
                             texture2d<float, access::read> hzb, bool occlusion, thread float& pixels) {
    uint all = 0x1Fu;                 // the planes every corner is outside of
    bool crossesNear = false;
    float2 pmin = float2(INFINITY), pmax = float2(-INFINITY);
    float nearest = 0.0f;             // the largest reversed depth
    for (uint c = 0; c < 8; ++c) {
        float3 corner = float3((c & 1u) ? hi.x : lo.x, (c & 2u) ? hi.y : lo.y, (c & 4u) ? hi.z : lo.z);
        float4 p = rasterClip(corner, r);
        uint out = (p.x < -p.w ? 1u : 0u) | (p.x > p.w ? 2u : 0u) | (p.y < -p.w ? 4u : 0u) | (p.y > p.w ? 8u : 0u)
                 | (p.w < NEAR_PLANE ? 16u : 0u);
        all &= out;
        if (p.w < NEAR_PLANE) { crossesNear = true; continue; }
        float2 ndc = p.xy / p.w;
        float2 px = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * float2(u.width, u.height);
        pmin = min(pmin, px);
        pmax = max(pmax, px);
        nearest = max(nearest, NEAR_PLANE / p.w);
    }
    pixels = INFINITY;
    if (all != 0u) return false;
    if (crossesNear) return true;
    float2 extent = min(pmax, float2(u.width, u.height)) - max(pmin, float2(0.0f));
    pixels = max(extent.x, 1.0f) * max(extent.y, 1.0f);
    if (!occlusion) return true;
    // The pyramid's level where the box's pixels span at most 2 x 2 texels (a level-l texel covers 2^(l+1) pixels).
    int2 a = int2(clamp(pmin, float2(0.0f), float2(u.width - 1, u.height - 1)));
    int2 b = int2(clamp(pmax, float2(0.0f), float2(u.width - 1, u.height - 1)));
    uint span = uint(max(b.x - a.x, b.y - a.y)) + 1u;
    uint level = min(span <= 2u ? 0u : 31u - clz(span - 1u), rp.hzbLevels - 1u);
    uint2 size = max(rp.hzbSize >> level, uint2(1u));
    uint2 t0 = min(uint2(a) >> (level + 1u), size - 1u), t1 = min(uint2(b) >> (level + 1u), size - 1u);
    float farthest = min(min(hzb.read(t0, level).x, hzb.read(uint2(t1.x, t0.y), level).x),
                         min(hzb.read(uint2(t0.x, t1.y), level).x, hzb.read(t1, level).x));
    return nearest >= farthest;
}

// One thread per instance record. Pass 1 keeps what was visible last frame; pass 2 tests what is in view against the
// pyramid of pass 1's depth and notes every instance's visibility for the next frame. Kept instances are appended as
// groups of RASTER_GROUP chunks: x = id, y = first chunk, z = the instance's triangles, w = its mesh's kind; and
// their RasterInstance at the place of their first group.
kernel void rasterCullKernel(constant Uniforms&            u         [[buffer(0)]],
                             device const float3*          positions [[buffer(2)]],
                             device const uint*            indices   [[buffer(4)]],
                             device const MeshData*        meshes    [[buffer(5)]],
                             device const InstanceData*    instances [[buffer(6)]],
                             constant RasterParams&        rp        [[buffer(9)]],
                             device const uint*            ids       [[buffer(10)]],
                             device uint*                  visible   [[buffer(11)]],
                             device uint4*                 groups    [[buffer(12)]],
                             device RasterCounters*        counters  [[buffer(13)]],
                             device const RasterMesh*      rmeshes   [[buffer(14)]],
                             device const VGBlasEntry*     vgTable   [[buffer(16)]],
                             device RasterInstance*        records   [[buffer(19)]],
                             device uint*                  vgState   [[buffer(26)]],   // RasterClusters' (RVG_PLACES on)
                             texture2d<float, access::read> hzb      [[texture(0)]],
                             uint i [[thread_position_in_grid]])
{
    if (i >= rp.instanceCount) return;
    uint was = visible[i];
    if (rp.pass == 1 && (was & RASTER_IN_VIEW) == 0u) return;   // (most of a large scene's instances: one read)
    uint id = (rp.flags & RASTER_P_IDS) != 0u ? ids[i] : i;
    InstanceData inst = instanceRecord(instances, id);
    // Camera-visible solid geometry and light proxies; glass has its own pass, voxel boxes are traced.
    if ((inst.pad0 & (MASK_GEOMETRY | 2u)) == 0u || (inst.pad0 & (MASK_GLASS | MASK_VOXELS)) != 0u) return;
    uint meshIndex = (inst.meshIndex & RASTER_ASSEMBLY) != 0u ? rp.firstAssembly + (inst.meshIndex & ~RASTER_ASSEMBLY) : inst.meshIndex;
    if (meshIndex >= rp.meshCount) {   // (no bounds: as if in view)
        if (rp.pass == 0) atomic_store_explicit(rasterTraced(counters), 1u, memory_order_relaxed);
        return;
    }
    RasterMesh rm = rmeshes[meshIndex];
    uint kind = as_type<uint>(rm.hi.w);
    bool clusters = (kind & RASTER_KIND) == RASTER_CLUSTERS;   // (its cut picks what it draws: rasterVGCutKernel)

    uint triangles = (kind & RASTER_KIND) == RASTER_SKIP ? 12u : clusters ? 1u
                   : (kind & RASTER_KIND) == RASTER_VIRTUAL ? vgTable[inst.pad1 - 1u].triangles : meshes[meshIndex].indexCount / 3u;
    if (triangles == 0u) return;
    RasterInstance r = rasterProjection(inst.transform, u);
    float pixels;
    bool before = (was & RASTER_VISIBLE) != 0u;
    bool draw;
    if (rp.pass == 0) {
        bool inView = rasterBoxVisible(rm.lo.xyz, rm.hi.xyz, r, u, rp, hzb, false, pixels);
        visible[i] = inView ? was | RASTER_IN_VIEW : 0u;
        draw = inView && before;
        // Virtual geometry as clusters: in view is enough, its cut tests each cluster (rasterVGCutKernel), against
        // the last frame's pyramid, and pass 2 tests again what that hid (rasterVGRetestKernel).
        if (clusters) {
            if (inView) {
                device RasterInstance* vgRecords = (device RasterInstance*)(vgState + RVG_HEADER);
                vgRecords[inst.pad1 - 1u] = r;
                vgState[RVG_HEADER + 16u * rp.virtualCount + inst.pad1 - 1u] = 1u;
            }
            return;
        }
    } else {
        bool now = rasterBoxVisible(rm.lo.xyz, rm.hi.xyz, r, u, rp, hzb, (rp.flags & RASTER_P_HZB) != 0u, pixels);
        visible[i] = now ? RASTER_VISIBLE : 0u;
        draw = now && !before && !clusters;   // (what pass 1 drew is in the depth already)
    }
    if (!draw) return;
    // Not drawn: a kind the raster skips, or finer than the pixels (not virtual geometry: its cut is already about a
    // triangle a pixel). Its box instead; in front of everything when it reaches the camera, as its far side would
    // hide what is in front of the instance (every pixel the box covers sees the box, the inside of it too).
    if ((kind & RASTER_KIND) == RASTER_SKIP
        || ((kind & RASTER_KIND) != RASTER_VIRTUAL && !clusters && triangles > RASTER_HEAVY && float(triangles) > RASTER_MAX_DENSITY * pixels)) {
        kind = RASTER_BOX | (isinf(pixels) ? RASTER_NEAR : 0u);
        triangles = 12u;
    }
    device RasterCounters& c = counters[rp.pass];
    uint chunks = (triangles + RASTER_CHUNK - 1u) / RASTER_CHUNK, n = (chunks + RASTER_GROUP - 1u) / RASTER_GROUP;
    uint first = atomic_fetch_add_explicit(&c.groups, n, memory_order_relaxed);
    uint end = min(first + n, rp.maxGroups);
    for (uint g = first; g < end; ++g) groups[g] = uint4(id, (g - first) * RASTER_GROUP, triangles, kind);
    if (end > first) {
        atomic_fetch_max_explicit(&c.groupsX, end, memory_order_relaxed);
        if ((kind & RASTER_KIND) == RASTER_BOX) {
            r.corners = (device const float3*)(rmeshes + meshIndex);
        } else if ((kind & RASTER_KIND) == RASTER_VIRTUAL) {
            r.corners = (device const float3*)vgTable[inst.pad1 - 1u].tris;
        } else {
            MeshData mesh = meshes[meshIndex];
            if ((kind & RASTER_KIND) == RASTER_BLOCK) {
                r.corners = mesh.block;
                r.indices = (device const uint*)((device const float2*)(mesh.block + 2u * mesh.vertexCount) + mesh.vertexCount);
            } else {
                r.corners = positions + mesh.vertexOffset;
                r.indices = indices + mesh.firstIndex;
            }
        }
        records[first] = r;
    }
    if (end < first + n) atomic_store_explicit(rasterTraced(counters), 1u, memory_order_relaxed);
}

// One threadgroup per group, a thread per chunk: chunks in the view (and in pass 2 in front of the pyramid) are
// appended to the pass's draw list: x = the instance's RasterInstance, y = first triangle, z = triangles | kind << 16,
// w = instance id.
kernel void rasterChunksKernel(constant Uniforms&            u         [[buffer(0)]],
                               device const InstanceData*    instances [[buffer(6)]],
                               constant RasterParams&        rp        [[buffer(9)]],
                               device const uint4*           groups    [[buffer(12)]],
                               device RasterCounters*        counters  [[buffer(13)]],
                               device const RasterMesh*      rmeshes   [[buffer(14)]],
                               device const float4*          bounds    [[buffer(15)]],
                               device uint4*                 draws     [[buffer(17)]],
                               device const RasterInstance*  records   [[buffer(19)]],
                               texture2d<float, access::read> hzb      [[texture(0)]],
                               uint g [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]])
{
    uint4 group = groups[g];
    uint chunk = group.y + lane, triangles = group.z, kind = group.w;
    if (chunk * RASTER_CHUNK >= triangles) return;
    uint record = g - group.y / RASTER_GROUP;   // (the instance's first group)
    if (((kind & RASTER_KIND) == RASTER_ARRAYS || (kind & RASTER_KIND) == RASTER_BLOCK) && (kind & RASTER_DEFORMS) == 0u) {
        uint at = as_type<uint>(rmeshes[instanceRecord(instances, group.x).meshIndex].lo.w) + chunk;
        RasterInstance r = records[record];
        float pixels;
        if (!rasterBoxVisible(bounds[2u * at].xyz, bounds[2u * at + 1u].xyz, r, u, rp, hzb,
                              rp.pass == 1 && (rp.flags & RASTER_P_HZB) != 0u, pixels)) return;
    }
    device RasterCounters& c = counters[rp.pass];
    uint k = atomic_fetch_add_explicit(&c.vertexCount, RASTER_CHUNK_VERTICES, memory_order_relaxed) / RASTER_CHUNK_VERTICES;
    if (k < rp.maxDraws) draws[k] = uint4(record, chunk * RASTER_CHUNK, min(triangles - chunk * RASTER_CHUNK, RASTER_CHUNK) | kind << 16, group.x);
    else atomic_store_explicit(rasterTraced(counters), 1u, memory_order_relaxed);   // no room: its pixels are traced
}

// Both passes' counters, ahead of the frame's pass 1.
kernel void rasterResetKernel(constant RasterParams&  rp       [[buffer(9)]],
                              device RasterCounters* counters [[buffer(13)]],
                              device uint*           vgState  [[buffer(26)]],   // RasterClusters': counters, places
                              uint i [[thread_position_in_grid]]) {
    if (i < RVG_HEADER) vgState[i] = 0u;
    if (i < rp.virtualCount) vgState[RVG_HEADER + 16u * rp.virtualCount + i] = 0u;   // (in view)
    if (i >= 2u) return;
    if (i == 0u) atomic_store_explicit(rasterTraced(counters), 0u, memory_order_relaxed);
    atomic_store_explicit(&counters[i].vertexCount, 0u, memory_order_relaxed);
    counters[i].instanceCount = 1u;
    counters[i].vertexStart = 0u;
    counters[i].baseInstance = 0u;
    atomic_store_explicit(&counters[i].groupsX, 0u, memory_order_relaxed);
    counters[i].groupsY = 1u;
    counters[i].groupsZ = 1u;
    atomic_store_explicit(&counters[i].groups, 0u, memory_order_relaxed);
}

// The chunks' bounds (object space), once a scene: a thread per chunk of the meshes that have them. `chunkMeshes`:
// each chunk's mesh index.
kernel void rasterBoundsKernel(device const float3*       positions   [[buffer(2)]],
                               device const uint*         indices     [[buffer(4)]],
                               device const MeshData*     meshes      [[buffer(5)]],
                               constant RasterParams&     rp          [[buffer(9)]],
                               device const RasterMesh*   rmeshes     [[buffer(14)]],
                               device float4*             bounds      [[buffer(15)]],
                               device const uint*         chunkMeshes [[buffer(18)]],
                               uint c [[thread_position_in_grid]])
{
    if (c >= rp.chunkCount) return;
    uint m = chunkMeshes[c];
    MeshData mesh = meshes[m];
    uint kind = as_type<uint>(rmeshes[m].hi.w) & RASTER_KIND;
    uint first = (c - as_type<uint>(rmeshes[m].lo.w)) * RASTER_CHUNK, end = min(first + RASTER_CHUNK, mesh.indexCount / 3u);
    float3 lo = float3(INFINITY), hi = float3(-INFINITY);
    for (uint t = first; t < end; ++t) {
        for (uint k = 0; k < 3; ++k) {
            float3 p = rasterCorner(kind, mesh, t, k, positions, indices);
            lo = min(lo, p);
            hi = max(hi, p);
        }
    }
    bounds[2u * c] = float4(lo, 0.0f);
    bounds[2u * c + 1u] = float4(hi, 0.0f);
}

// The pyramid's level 0 from the depth: each texel the farthest (smallest reversed) depth of its 2 x 2 pixels; the
// pixels past the frame's edge count as the sky.
kernel void hzbInitKernel(depth2d<float, access::read>     depth [[texture(0)]],
                          texture2d<float, access::write>  hzb   [[texture(1)]],
                          uint2 t [[thread_position_in_grid]])
{
    if (t.x >= hzb.get_width() || t.y >= hzb.get_height()) return;
    uint2 size = uint2(depth.get_width(), depth.get_height());
    float d = INFINITY;
    for (uint k = 0; k < 4; ++k) {
        uint2 p = 2u * t + uint2(k & 1u, k >> 1);
        d = min(d, all(p < size) ? depth.read(p) : 0.0f);
    }
    hzb.write(float4(d), t);
}

// Level `level` from the one above it (the same texture, bound twice: read and write).
kernel void hzbReduceKernel(texture2d<float, access::read>   src   [[texture(0)]],
                            texture2d<float, access::write>  dst   [[texture(1)]],
                            constant uint&                   level [[buffer(0)]],
                            uint2 t [[thread_position_in_grid]])
{
    if (t.x >= dst.get_width(level) || t.y >= dst.get_height(level)) return;
    uint2 last = uint2(src.get_width(level - 1u), src.get_height(level - 1u)) - 1u;
    float d = INFINITY;
    for (uint k = 0; k < 4; ++k) d = min(d, src.read(min(2u * t + uint2(k & 1u, k >> 1), last), level - 1u).x);
    dst.write(float4(d), t, level);
}

// A box's 12 triangles (2 a face), its corners numbered by bits x, y, z.
constant uchar RASTER_BOX_CORNERS[36] = {0, 1, 3, 0, 3, 2,  4, 6, 7, 4, 7, 5,  0, 4, 5, 0, 5, 1,
                                         2, 3, 7, 2, 7, 6,  0, 2, 6, 0, 6, 4,  1, 5, 7, 1, 7, 3};

struct RasterVertex {
    float4 position [[position]];
    uint2  ids [[flat]];          // instance id, triangle
};

// A vertex of the pass's draw list: chunk k's triangle t (vertex_id = k x RASTER_CHUNK_VERTICES + 3 t + corner). A
// chunk's lanes past its triangles fold to a point, which draws nothing.
vertex RasterVertex rasterVertex(constant RasterParams&          rp      [[buffer(9)]],
                                 device const uint4*             draws   [[buffer(17)]],
                                 device const RasterInstance*    records [[buffer(19)]],
                                 device const float4*            vgPool  [[buffer(20)]],   // the raster clusters' pool,
                                 device const uint*              vgState [[buffer(26)]],   // their instances' records,
                                 device const uint2*             vgList  [[buffer(27)]],   // and the frame's cluster list
                                 uint vid [[vertex_id]])
{
    RasterVertex out;
    uint k = vid / RASTER_CHUNK_VERTICES, t = (vid % RASTER_CHUNK_VERTICES) / 3u, corner = vid % 3u;
    uint4 draw = k < rp.maxDraws ? draws[k] : uint4(0u);
    uint kind = draw.z >> 16;
    if (t >= (draw.z & 0xFFFFu)) {
        out.position = float4(0.0f, 0.0f, 0.0f, 1.0f);
        out.ids = uint2(RASTER_NO_ID);
        return out;
    }
    uint prim = draw.y + t;
    RasterInstance r = (kind & RASTER_KIND) == RASTER_CLUSTERS   // (x: a cluster's virtual instance)
        ? ((device const RasterInstance*)(vgState + RVG_HEADER))[draw.x] : records[draw.x];
    float3 p;
    if ((kind & RASTER_KIND) == RASTER_BOX) {
        device const float4* box = (device const float4*)r.corners;   // lo, hi
        uint c = RASTER_BOX_CORNERS[3u * prim + corner];
        p = select(box[0].xyz, box[1].xyz, bool3((c & 1u) != 0u, (c & 2u) != 0u, (c & 4u) != 0u));
        out.ids = uint2(RASTER_TRACE_ID, 0u);
    } else if ((kind & RASTER_KIND) == RASTER_CLUSTERS) {
        // A cluster's triangle t: its corner's 8-bit index into the cluster's positions (vgClusterView's layout).
        device const float4* blob = vgPool + vgList[draw.y].y;
        uint4 offsets = ((device const uint4*)blob)[1];   // bytes: nodes, positions, UVs, triangles
        device const uchar* base = (device const uchar*)blob;
        uint packed = ((device const uint*)(base + offsets.w))[t];
        p = ((device const float4*)(base + offsets.y))[(packed >> (8u * corner)) & 0xFFu].xyz;
        out.ids = uint2(draw.w, RASTER_CLUSTER_ID | draw.y << 7 | t);
    } else {
        p = rasterTriangleCorner(kind, r.corners, r.indices, prim, corner);
        out.ids = uint2(draw.w, prim);
    }
    out.position = rasterClip(p, r);
    if ((kind & RASTER_NEAR) != 0u) out.position.z = out.position.w;   // reversed depth 1: the nearest (clipped behind the camera)
    return out;
}

fragment uint4 rasterFragment(RasterVertex in [[stage_in]]) { return uint4(in.ids, 0u, 0u); }

// The primary ray's hit from the visibility buffer: the triangle the raster drew at this pixel, met by the ray
// itself, so its distance and barycentrics are the ones the tracer would return (on a triangle's edge they may lie
// a little outside it, where the raster's coverage and the ray part ways). False when undecided (a triangle seen
// edge-on, the box of what isn't drawn): the ray is then traced. `ids.x` RASTER_NO_ID: nothing drawn there, a miss.
inline bool visibilityHit(uint2 ids, Ray r, SCENE_ACCEL accel, thread const SceneData& s, thread Hit& h) {
    h.hit = false;
    h.cluster = HIT_NO_CLUSTER;
    h.part = HIT_NO_PART;
    h.instance = ids.x;
    h.primitive = ids.y;
    h.distance = INFINITY;
    h.barycentrics = float2(0.0f);
    if (ids.x == RASTER_NO_ID) return true;
    if (ids.x == RASTER_TRACE_ID) return false;
    if ((ids.y & RASTER_CLUSTER_ID) != 0u) {   // a raster cluster's triangle: the trace's selected cluster (RasterClusters)
        h.cluster = (ids.y >> 7) & 0xFFFFFFu;
        h.primitive = ids.y & 0x7Fu;
    }
    InstanceData inst = instanceRecord(s.instances, ids.x);
    HitVertices v = fetchHitVertices(h, inst, accel, s);
    float3 a = (inst.transform * float4(v.p[0], 1.0f)).xyz;
    float3 e1 = (inst.transform * float4(v.p[1], 1.0f)).xyz - a, e2 = (inst.transform * float4(v.p[2], 1.0f)).xyz - a;
    float3 pv = cross(r.direction, e2);
    float det = dot(e1, pv);
    if (!(abs(det) > 1e-14f)) return false;
    float inv = 1.0f / det;
    float3 tv = r.origin - a, qv = cross(tv, e1);
    float t = dot(e2, qv) * inv;
    if (!(t > r.tmin)) return false;
    h.hit = true;
    h.distance = t;
    h.barycentrics = float2(dot(tv, pv), dot(r.direction, qv)) * inv;
    return true;
}

// View "Visibility buffer": each chunk in a colour of its own, shaded by its normal; magenta where the primary ray
// traced what the raster doesn't draw, black for the sky (and everywhere with the primary visibility traced); a magenta
// frame around it when the primary rays were traced too.
kernel void rasterDebugKernel(constant Uniforms&               u           [[buffer(0)]],
                              texture2d<uint, access::read>    vis         [[texture(0)]],
                              texture2d<float, access::read>   normalDepth [[texture(1)]],
                              texture2d<float, access::write>  output      [[texture(2)]],
                              device RasterCounters*           counters    [[buffer(13)]],
                              uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    if (!flagOn(u.flags, FLAG_VIS_BUFFER)) { output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid); return; }   // traced: none
    // A magenta frame: this frame's primary rays were traced too (RasterTraced).
    uint edge = min(min(tid.x, u.width - 1u - tid.x), min(tid.y, u.height - 1u - tid.y));
    if (edge < 4u && atomic_load_explicit(rasterTraced(counters), memory_order_relaxed) != 0u) {
        output.write(float4(1.0f, 0.0f, 1.0f, 1.0f), tid);
        return;
    }
    uint2 ids = vis.read(tid).xy;
    float4 nd = normalDepth.read(tid);
    float3 c;
    if (ids.x == RASTER_NO_ID || ids.x == RASTER_TRACE_ID) {
        c = nd.w > 0.0f ? float3(1.0f, 0.0f, 1.0f) : float3(0.0f);
    } else {
        uint h = pcgHash(ids.x * 0x9E3779B9u ^ (ids.y / RASTER_CHUNK));
        float3 hue = float3(float(h & 0xFFu), float((h >> 8) & 0xFFu), float((h >> 16) & 0xFFu)) * (1.0f / 255.0f);
        c = (0.35f + 0.65f * hue) * (0.45f + 0.55f * abs(dot(nd.xyz, normalize(float3(0.4f, 0.8f, 0.45f)))));
    }
    output.write(float4(c, 1.0f), tid);
}
