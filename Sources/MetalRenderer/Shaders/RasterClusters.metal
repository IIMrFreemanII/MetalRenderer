// ---------------------------------------------------------------------------------------------
// The raster clusters (RasterClusters.swift): virtual geometry in the visibility buffer as Nanite draws it. In each of
// the raster's passes, rasterCullKernel leaves every virtual instance it draws a RasterInstance and notes its place in
// the state (per pass and virtual instance); rasterVGCutKernel then walks those instances' cluster groups, picks the cut
// (vgCutKernel's rule, against the raster clusters' own pool), culls each picked cluster's box against the view (and in
// the second pass the depth pyramid), and appends it to the pass's draw list as a RASTER_CLUSTERS draw: y = its entry
// in the frame's cluster list, which holds its pool offset for the vertices (rasterVertex) and the trace
// (fetchHitVertices reads the list as the selected clusters).
// ---------------------------------------------------------------------------------------------
#if CUSTOM_RT

// RasterClusters.Params.
struct RasterVGParams {
    float4 lodCam;         // xyz = where detail is chosen for, w = pixels per unit of error at distance 1
    float  tau;            // allowed projected error, in traced pixels
    uint   workCount;      // (virtual instance, group) pairs
    uint   instanceCount;  // virtual instances
    uint   capacity;       // the cluster list's entries
    uint   frame;
    uint   requestCapacity;
    uint   flags;          // RVG_P_*
    uint   pad;
};
static_assert(sizeof(RasterVGParams) == 48, "RasterVGParams: RasterClusters.Params");

// Per virtual instance (its rank, InstanceData.pad1 - 1).
struct VGRasterInstance {
    uint instance;         // scene instance
    uint groupBase;        // its mesh's first global group
    uint groupCount;
    uint workBase;         // its first (instance, group) pair
};

// Per global group: what its clusters share (the parent sphere and error), and where they are.
struct VGGroupRecord {
    float4 sphere;
    float  error;          // infinity for roots
    uint   clusterStart;   // global cluster
    uint   clusterCount;
    uint   pad;
};
static_assert(sizeof(VGGroupRecord) == 32, "VGGroupRecord: RasterClusters.groupRecords");

// RasterClusters' per-frame state (RVG_HEADER: Raster.metal): its counters' places.
constant uint RVG_DRAWN = 0, RVG_REQUESTS = 1, RVG_OVERFLOW = 2, RVG_TRIANGLES = 3, RVG_RETESTS = 4;
constant uint RVG_P_PREV = 1;   // RasterVGParams.flags: the last frame's pyramid holds what it drew (this size, this scene)
constant uint RVG_P_MESH = 2;   // drawn by rasterClusterMesh (a threadgroup an entry) rather than in the draw lists' slots
// Mesh shaders: the first entry of pass 2's clusters (pass 1's are the ones before it), then each pass's threadgroups
// (MTLDispatchThreadgroupsIndirectArguments) at RVG_MESH_ARGS + 3 x pass.
constant uint RVG_MESH_BASE = 8, RVG_MESH_ARGS = 9;

// Mesh shaders: after the list's entries, each entry's virtual instance.
inline device uint* rvgOwners(device uint2* list, constant RasterVGParams& p) { return (device uint*)(list + p.capacity); }

inline device RasterInstance* rvgRecords(device atomic_uint* state) { return (device RasterInstance*)(state + RVG_HEADER); }
// After the requests: the clusters pass 1 held back for pass 2 (virtual instance, cluster, page, own error | wants finer).
inline device uint4* rvgRetests(device uint2* requests, constant RasterVGParams& p) {
    return (device uint4*)(requests + p.requestCapacity);
}

// Appends a picked, visible cluster to the frame's list and the pass's draws, asking for its finer group if it wants it.
inline void rvgDraw(VGCluster cl, uint page, uint vi, uint instance, float own, bool wantFiner, constant RasterVGParams& p,
                    constant RasterParams& rp, device RasterCounters* counters, device uint4* draws, device atomic_uint* state,
                    device uint2* list, device uint2* requests, device atomic_uint* requestStamp) {
    if (wantFiner && atomic_exchange_explicit(&requestStamp[cl.childGroup], p.frame, memory_order_relaxed) != p.frame) {
        uint q = atomic_fetch_add_explicit(&state[RVG_REQUESTS], 1u, memory_order_relaxed);
        if (q < p.requestCapacity) requests[q] = uint2(cl.childGroup, as_type<uint>(own));
    }
    uint k = atomic_fetch_add_explicit(&state[RVG_DRAWN], 1u, memory_order_relaxed);
    if (k >= p.capacity) {   // no room in the list: the primary rays trace
        atomic_store_explicit(&state[RVG_OVERFLOW], 1u, memory_order_relaxed);
        atomic_store_explicit(rasterTraced(counters), 1u, memory_order_relaxed);
        return;
    }
    atomic_fetch_add_explicit(&state[RVG_TRIANGLES], cl.triangles, memory_order_relaxed);
    list[k] = uint2(as_type<uint>(cl.lo.w), page + cl.pageOffset / 16u);   // (its error: traceKernel's offset)
    if ((p.flags & RVG_P_MESH) != 0u) { rvgOwners(list, p)[k] = vi; return; }
    uint d = atomic_fetch_add_explicit(&counters[rp.pass].vertexCount, RASTER_CHUNK_VERTICES, memory_order_relaxed) / RASTER_CHUNK_VERTICES;
    if (d < rp.maxDraws) draws[d] = uint4(vi, k, cl.triangles | RASTER_CLUSTERS << 16, instance);
    else atomic_store_explicit(rasterTraced(counters), 1u, memory_order_relaxed);
}

// Pass 1, one thread per (virtual instance, group) of the instances in view: the cut, each picked cluster's box against
// the view and then the last frame's pyramid (where that frame's camera saw it). What the pyramid hides waits for pass 2.
kernel void rasterVGCutKernel(constant Uniforms&             u            [[buffer(0)]],
                              device const InstanceData*     instances    [[buffer(6)]],
                              constant RasterParams&         rp           [[buffer(9)]],
                              device RasterCounters*         counters     [[buffer(13)]],
                              device uint4*                  draws        [[buffer(17)]],
                              constant RasterVGParams&       p            [[buffer(21)]],
                              device const VGRasterInstance* vinstances   [[buffer(22)]],
                              device const VGGroupRecord*    groups       [[buffer(23)]],
                              device const VGCluster*        clusters     [[buffer(24)]],
                              device const uint*             groupPage    [[buffer(25)]],   // pool offset (float4s) or ~0
                              device atomic_uint*            state        [[buffer(26)]],
                              device uint2*                  list         [[buffer(27)]],   // (selfError bits, pool offset)
                              device uint2*                  requests     [[buffer(28)]],   // (group, priority bits), then retests
                              device atomic_uint*            requestStamp [[buffer(29)]],
                              device uint*                   lastUsed     [[buffer(30)]],
                              texture2d<float, access::read> hzb          [[texture(0)]],   // (this frame's: unused here)
                              texture2d<float, access::read> hzbPrev      [[texture(1)]],
                              uint gid [[thread_position_in_grid]])
{
    if (gid >= p.workCount) return;
    uint lo = 0, hi = p.instanceCount - 1;   // the virtual instance whose work range holds gid
    while (lo < hi) {
        uint mid = (lo + hi + 1) / 2;
        if (vinstances[mid].workBase <= gid) lo = mid; else hi = mid - 1;
    }
    VGRasterInstance vi = vinstances[lo];
    uint local = gid - vi.workBase;
    if (local >= vi.groupCount) return;
    if (atomic_load_explicit(&state[RVG_HEADER + 16u * p.instanceCount + lo], memory_order_relaxed) == 0u) return;   // out of view
    uint g = vi.groupBase + local;
    uint page = groupPage[g];
    if (page == 0xFFFFFFFFu) return;   // not resident

    VGGroupRecord grp = groups[g];
    InstanceData inst = instanceRecord(instances, vi.instance);
    float4x4 m = inst.transform;
    float scale = max(length(m[0].xyz), max(length(m[1].xyz), length(m[2].xyz)));
    if (!isFar(grp.error) && vgProjected(grp.sphere, grp.error, m, scale, p.lodCam) <= p.tau) return;   // coarser is enough

    RasterInstance r = rvgRecords(state)[lo];
    bool prev = (p.flags & RVG_P_PREV) != 0u;
    RasterInstance last = rasterProjectionPrev(inst.prevTransform, u);
    bool used = false;
    for (uint j = 0; j < grp.clusterCount; ++j) {
        uint ci = grp.clusterStart + j;
        VGCluster cl = clusters[ci];
        bool wantFiner = false;
        float own = 0.0f;
        if (cl.childGroup != 0xFFFFFFFFu) {
            own = vgProjected(cl.selfSphere, cl.lo.w, m, scale, p.lodCam);
            if (own > p.tau) {
                if (groupPage[cl.childGroup] != 0xFFFFFFFFu) continue;   // the finer clusters are drawn instead
                wantFiner = true;
            }
        }
        float pixels;
        if (!rasterBoxVisible(cl.lo.xyz, cl.hi.xyz, r, u, rp, hzb, false, pixels)) continue;   // out of view
        used = true;
        // Hidden last frame (or out of its view): pass 2 tests it against this frame's pyramid.
        if (prev && !rasterBoxVisible(cl.lo.xyz, cl.hi.xyz, last, u, rp, hzbPrev, true, pixels)) {
            uint q = atomic_fetch_add_explicit(&state[RVG_RETESTS], 1u, memory_order_relaxed);
            if (q < p.capacity) {
                rvgRetests(requests, p)[q] = uint4(lo, ci, page, (as_type<uint>(own) & ~1u) | (wantFiner ? 1u : 0u));
                continue;
            }
        }
        rvgDraw(cl, page, lo, vi.instance, own, wantFiner, p, rp, counters, draws, state, list, requests, requestStamp);
    }
    if (used) lastUsed[g] = p.frame;
}

// Pass 2, one thread per cluster pass 1 held back: drawn if this frame's pyramid (pass 1's depth) doesn't hide it.
kernel void rasterVGRetestKernel(constant Uniforms&             u            [[buffer(0)]],
                                 device const InstanceData*     instances    [[buffer(6)]],
                                 constant RasterParams&         rp           [[buffer(9)]],
                                 device RasterCounters*         counters     [[buffer(13)]],
                                 device uint4*                  draws        [[buffer(17)]],
                                 constant RasterVGParams&       p            [[buffer(21)]],
                                 device const VGRasterInstance* vinstances   [[buffer(22)]],
                                 device const VGCluster*        clusters     [[buffer(24)]],
                                 device atomic_uint*            state        [[buffer(26)]],
                                 device uint2*                  list         [[buffer(27)]],
                                 device uint2*                  requests     [[buffer(28)]],
                                 device atomic_uint*            requestStamp [[buffer(29)]],
                                 texture2d<float, access::read> hzb          [[texture(0)]],
                                 uint t [[thread_position_in_grid]])
{
    if (t >= min(atomic_load_explicit(&state[RVG_RETESTS], memory_order_relaxed), p.capacity)) return;
    uint4 e = rvgRetests(requests, p)[t];
    VGCluster cl = clusters[e.y];
    RasterInstance r = rvgRecords(state)[e.x];
    float pixels;
    if (!rasterBoxVisible(cl.lo.xyz, cl.hi.xyz, r, u, rp, hzb, (rp.flags & RASTER_P_HZB) != 0u, pixels)) return;
    rvgDraw(cl, e.z, e.x, vinstances[e.x].instance, as_type<float>(e.w & ~1u), (e.w & 1u) != 0u, p, rp, counters, draws, state,
            list, requests, requestStamp);
}

// Mesh shaders: the pass's threadgroups, one an entry it appended to the list (pass 1's start where pass 2's begin).
kernel void rasterVGMeshArgsKernel(constant RasterParams&   rp    [[buffer(9)]],
                                   constant RasterVGParams& p     [[buffer(21)]],
                                   device uint*             state [[buffer(26)]])
{
    uint n = min(state[RVG_DRAWN], p.capacity);
    if (rp.pass == 0u) state[RVG_MESH_BASE] = n;
    uint first = rp.pass == 0u ? 0u : state[RVG_MESH_BASE];
    state[RVG_MESH_ARGS + 3u * rp.pass] = n - first;
    state[RVG_MESH_ARGS + 3u * rp.pass + 1u] = 1u;
    state[RVG_MESH_ARGS + 3u * rp.pass + 2u] = 1u;
}

// A cluster as a mesh shader draws it: each vertex transformed once (rasterVertex does each corner of each triangle).
struct RasterMeshVertex {
    float4 position [[position]];
};
struct RasterMeshPrimitive {
    uint2 ids [[flat]];          // instance id, RASTER_CLUSTER_ID | entry << 7 | triangle (rasterFragment's input)
};
using RasterClusterMeshOut = metal::mesh<RasterMeshVertex, RasterMeshPrimitive, 256, RASTER_CHUNK, metal::topology::triangle>;

// One threadgroup of RASTER_CHUNK threads per entry the pass appended: a thread's vertices (a cluster has at most 255)
// and its triangle.
[[mesh]] void rasterClusterMesh(RasterClusterMeshOut                out,
                                constant RasterParams&              rp         [[buffer(9)]],
                                device const float4*                vgPool     [[buffer(20)]],
                                constant RasterVGParams&            p          [[buffer(21)]],
                                device const VGRasterInstance*      vinstances [[buffer(22)]],
                                device uint*                        state      [[buffer(26)]],
                                device uint2*                       list       [[buffer(27)]],
                                uint tg [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]])
{
    uint k = (rp.pass == 0u ? 0u : state[RVG_MESH_BASE]) + tg;
    device const float4* blob = vgPool + list[k].y;
    uint4 header = ((device const uint4*)blob)[0];    // nodes, vertices, triangles
    uint4 offsets = ((device const uint4*)blob)[1];   // bytes: nodes, positions, UVs, triangles
    device const uchar* base = (device const uchar*)blob;
    uint vi = rvgOwners(list, p)[k];
    RasterInstance r = ((device const RasterInstance*)(state + RVG_HEADER))[vi];
    device const float4* positions = (device const float4*)(base + offsets.y);
    for (uint v = lane; v < header.y; v += RASTER_CHUNK) {
        RasterMeshVertex o;
        o.position = rasterClip(positions[v].xyz, r);
        out.set_vertex(v, o);
    }
    if (lane < header.z) {
        uint packed = ((device const uint*)(base + offsets.w))[lane];
        out.set_index(3u * lane, packed & 0xFFu);
        out.set_index(3u * lane + 1u, (packed >> 8) & 0xFFu);
        out.set_index(3u * lane + 2u, (packed >> 16) & 0xFFu);
        RasterMeshPrimitive prim;
        prim.ids = uint2(vinstances[vi].instance, RASTER_CLUSTER_ID | k << 7 | lane);
        out.set_primitive(lane, prim);
    }
    if (lane == 0u) out.set_primitive_count(header.z);
}

// Projected error in view v's texels of `error` over `sphere` (object space, `r` the instance's rows): a sun's texels
// are the same size everywhere, a spot's or a sphere face's grow with the distance from the light.
inline float vsmTexels(thread const VSMView& v, thread const VSMInstance& r, float4 sphere, float error, float scale) {
    float size = v.params.x;
    if (v.kind != VSM_SUN) {
        float d = vsmClipLocal(sphere.xyz, r).w - sphere.w * scale;
        if (d <= 1e-4f) return INFINITY;
        size *= d;
    }
    return error * scale / size;
}

// The shadow maps' clusters: one thread per (virtual instance, group) and active view whose pages to draw the instance
// covers (vsmCullKernel's record). The cut by vgCutKernel's rule, but measured in the view's texels instead of the
// camera's pixels: a page drawn stays right while the camera moves. Each picked cluster is drawn into every page to draw
// that its box covers (as vsmChunksKernel draws a chunk), from the raster clusters' pool, which it asks for finer groups.
kernel void vsmVGCutKernel(device const InstanceData*    instances  [[buffer(6)]],
                           constant VSMClusterArgs&      vg         [[buffer(7)]],
                           constant VSMParams&           vp         [[buffer(9)]],
                           device VSMCounters*           counters   [[buffer(13)]],
                           device uint4*                 draws      [[buffer(18)]],
                           device const VSMView*         views      [[buffer(22)]],
                           device atomic_uint*           table      [[buffer(24)]],
                           device const uint*            slots      [[buffer(29)]],
                           device const uint4*           renderList [[buffer(30)]],
                           uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= vg.workCount || tid.y >= atomic_load_explicit(&counters->cullY, memory_order_relaxed)) return;
    device const VGRasterInstance* vinstances = (device const VGRasterInstance*)vg.vinstances;
    uint lo = 0, hi = vg.instanceCount - 1;   // the virtual instance whose work range holds tid.x
    while (lo < hi) {
        uint mid = (lo + hi + 1) / 2;
        if (vinstances[mid].workBase <= tid.x) lo = mid; else hi = mid - 1;
    }
    VGRasterInstance vi = vinstances[lo];
    uint local = tid.x - vi.workBase;
    if (local >= vi.groupCount) return;
    uint place = tid.y * vg.instanceCount + lo;
    VSMInstance r = vg.records[place];
    if (r.meshIndex != vp.frame + 1u) return;   // not in front of this view's pages to draw this frame
    uint g = vi.groupBase + local;
    uint page = vg.groupPage[g];
    if (page == 0xFFFFFFFFu) return;   // not resident

    VSMView v = views[r.view];
    VGGroupRecord grp = ((device const VGGroupRecord*)vg.groups)[g];
    float4x4 m = instanceRecord(instances, vi.instance).transform;
    float scale = max(length(m[0].xyz), max(length(m[1].xyz), length(m[2].xyz)));
    if (!isFar(grp.error) && vsmTexels(v, r, grp.sphere, grp.error, scale) <= vg.tau) return;   // coarser is enough

    device const VGCluster* clusters = (device const VGCluster*)vg.clusters;
    uint drawn = atomic_load_explicit(&counters->drawn, memory_order_relaxed);
    bool used = false;
    for (uint j = 0; j < grp.clusterCount; ++j) {
        VGCluster cl = clusters[grp.clusterStart + j];
        bool wantFiner = false;
        float own = 0.0f;
        if (cl.childGroup != 0xFFFFFFFFu) {
            own = vsmTexels(v, r, cl.selfSphere, cl.lo.w, scale);
            if (own > vg.tau) {
                if (vg.groupPage[cl.childGroup] != 0xFFFFFFFFu) continue;   // the finer clusters are drawn instead
                wantFiner = true;
            }
        }
        uint4 rect;
        if (!vsmBoxPages(cl.lo.xyz, cl.hi.xyz, r, v.pages, rect)) continue;
        rect = uint4(max(rect.xy, r.pages.xy), min(rect.zw, r.pages.zw));
        if (any(rect.xy > rect.zw)) continue;
        used = true;
        if (wantFiner && atomic_exchange_explicit(&vg.requestStamp[cl.childGroup], vp.frame, memory_order_relaxed) != vp.frame) {
            uint q = atomic_fetch_add_explicit(vg.requests, 1u, memory_order_relaxed);
            if (q < vg.requestCapacity) ((device uint2*)(vg.requests + 4))[q] = uint2(cl.childGroup, as_type<uint>(own));
        }
        uint tris = cl.triangles | RASTER_CLUSTERS << 16, at = page + cl.pageOffset / 16u;
        for (uint y = rect.y; y <= rect.w; ++y) {
            for (uint x = rect.x; x <= rect.z; ++x) {
                uint entry = vsmEntry(v, uint2(x, y));
                uint slot = slots[entry];
                if (slot >= drawn || renderList[slot].x != entry) continue;   // not drawn this frame
                uint k = atomic_fetch_add_explicit(&counters->vertexCount, RASTER_CHUNK_VERTICES, memory_order_relaxed) / RASTER_CHUNK_VERTICES;
                if (k < vp.maxDraws) draws[k] = uint4(place, at, tris, slot);
                else atomic_fetch_and_explicit(&table[entry], ~VSM_RENDERED, memory_order_relaxed);
            }
        }
    }
    if (used) vg.lastUsed[g] = vp.frame;
}

#endif
