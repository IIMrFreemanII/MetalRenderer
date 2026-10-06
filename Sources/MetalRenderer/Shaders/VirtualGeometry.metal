// ---------------------------------------------------------------------------------------------
// Virtual geometry: this frame's cut through every virtual mesh's cluster DAG (VirtualGeometry.swift), and its
// clusters as boxes for Metal's structure over them (METALRENDERER_VG_MODE=clusters).
// ---------------------------------------------------------------------------------------------

struct VGCluster {
    float4 selfSphere;     // xyz = centre, w = radius (object space)
    float4 parentSphere;
    float4 lo;             // xyz = bounds min, w = selfError
    float4 hi;             // xyz = bounds max, w = parentError (infinity for roots)
    uint group;            // its page
    uint childGroup;       // the finer group it was made from, ~0 at the finest level
    uint pageOffset;       // bytes into the page
    uint triangles;
};
static_assert(sizeof(VGCluster) == 80, "VGCluster: VirtualGeometryBuilder.VGCluster (also the on-disk format)");

struct VGInstance {
    uint instance;         // scene instance
    uint clusterBase;      // into the cluster records
    uint clusterCount;
    uint workBase;         // first work item (one per cluster of each virtual instance)
};
static_assert(sizeof(VGInstance) == 16, "VGInstance: VirtualGeometry's table");

struct VGParams {
    float4 camPos;         // xyz, w = pixels per unit of error at distance 1 (traced height / (2 tan(fovY / 2)))
    float  tau;            // allowed projected error, in traced pixels
    uint   workCount;
    uint   instanceCount;
    uint   capacity;       // most selected clusters
    uint   frame;
    uint   requestCapacity;
    uint   pad0, pad1;
};
static_assert(sizeof(VGParams) == 48, "VGParams: VirtualGeometry's Params");

kernel void vgResetKernel(device uint* counters [[buffer(0)]]) {   // selected, requests, overflow, triangles
    counters[0] = 0; counters[1] = 0; counters[2] = 0; counters[3] = 0;
}

// Projected error in traced pixels of `error` (object space) over `sphere` (object space) seen from the camera.
inline float vgProjected(float4 sphere, float error, float4x4 m, float scale, float4 camPos) {
    float3 c = (m * float4(sphere.xyz, 1.0f)).xyz;
    float d = length(c - camPos.xyz) - sphere.w * scale;
    return d <= 1e-4f ? INFINITY : error * scale * camPos.w / d;
}

// One thread per (virtual instance, cluster). Nanite's rule (see VGCluster in VirtualGeometryBuilder.swift): drawn
// if resident, its group's coarser version is too coarse, and it is fine enough itself or its finer group isn't
// resident (then that group is requested). Detail follows distance only: off-screen geometry still casts shadows
// and shows in reflections, and every ray type sees the same cut.
kernel void vgCutKernel(constant VGParams&           p           [[buffer(0)]],
                        device const VGInstance*     vinstances  [[buffer(1)]],
                        device const VGCluster*      clusters    [[buffer(2)]],
                        device const uint*           groupPage   [[buffer(3)]],   // per group: pool offset (float4s) or ~0
                        device const InstanceData*   instances   [[buffer(4)]],
                        device atomic_uint*          counters    [[buffer(5)]],
                        device uint2*                selected    [[buffer(6)]],   // (instance, pool offset of the cluster)
                        device float4*               leafBoxes   [[buffer(7)]],
                        device uint2*                requests    [[buffer(8)]],   // (group, priority bits)
                        device atomic_uint*          requestStamp [[buffer(9)]],  // per group: last frame it was requested
                        device uint*                 lastUsed    [[buffer(10)]],  // per group: last frame it was drawn
                        uint gid [[thread_position_in_grid]])
{
    if (gid >= p.workCount) return;
    uint lo = 0, hi = p.instanceCount - 1;   // the instance whose work range holds gid
    while (lo < hi) {
        uint mid = (lo + hi + 1) / 2;
        if (vinstances[mid].workBase <= gid) lo = mid; else hi = mid - 1;
    }
    VGInstance vi = vinstances[lo];
    uint local = gid - vi.workBase;
    if (local >= vi.clusterCount) return;
    VGCluster c = clusters[vi.clusterBase + local];
    uint page = groupPage[c.group];
    if (page == 0xFFFFFFFFu) return;   // not resident

    InstanceData inst = instances[vi.instance];
    float4x4 m = inst.transform;
    float scale = max(length(m[0].xyz), max(length(m[1].xyz), length(m[2].xyz)));
    if (!isFar(c.hi.w) && vgProjected(c.parentSphere, c.hi.w, m, scale, p.camPos) <= p.tau) return;   // coarser is enough
    if (c.childGroup != 0xFFFFFFFFu) {
        float own = vgProjected(c.selfSphere, c.lo.w, m, scale, p.camPos);
        if (own > p.tau) {
            if (groupPage[c.childGroup] != 0xFFFFFFFFu) return;   // the finer clusters are drawn instead
            if (atomic_exchange_explicit(&requestStamp[c.childGroup], p.frame, memory_order_relaxed) != p.frame) {
                uint r = atomic_fetch_add_explicit(&counters[1], 1u, memory_order_relaxed);
                if (r < p.requestCapacity) requests[r] = uint2(c.childGroup, as_type<uint>(own));
            }
        }
    }
    lastUsed[c.group] = p.frame;
    uint idx = atomic_fetch_add_explicit(&counters[0], 1u, memory_order_relaxed);
    if (idx >= p.capacity) { atomic_store_explicit(&counters[2], 1u, memory_order_relaxed); return; }
    atomic_fetch_add_explicit(&counters[3], c.triangles, memory_order_relaxed);   // for the Debug window
    selected[idx] = uint2(vi.instance, page + c.pageOffset / 16);
    leafBoxes[2 * idx]     = float4(c.lo.xyz, 0.0f);   // object space: vgBoxesKernel places it
    leafBoxes[2 * idx + 1] = float4(c.hi.xyz, 0.0f);
}

// Metal's box (MTLAxisAlignedBoundingBox: min, max) and its primitive data (ClusterBox) for every slot of the cut:
// a selected cluster's box in world space with its instance's world -> object rows, an empty slot a point far away
// (the structure is built over all `capacity` of them every frame: its size is set when the build is encoded).
kernel void vgBoxesKernel(constant VGParams&          p          [[buffer(0)]],
                          device const InstanceData*  instances  [[buffer(4)]],
                          device const uint*          counters   [[buffer(5)]],
                          device const uint2*         selected   [[buffer(6)]],
                          device const float4*        leafBoxes  [[buffer(7)]],
                          device float*               boxes      [[buffer(11)]],
                          device ClusterBox*          boxData    [[buffer(12)]],
                          uint gid [[thread_position_in_grid]])
{
    if (gid >= p.capacity) return;
    float3 lo = float3(1.0e30f), hi = float3(1.0e30f);
    ClusterBox b;
    b.index = gid;
    b.mask = 0u;   // an empty slot: no ray's mask meets it
    b.pad0 = b.pad1 = 0;
    if (gid < min(counters[0], p.capacity)) {
        InstanceData inst = instances[selected[gid].x];
        lo = leafBoxes[2 * gid].xyz;
        hi = leafBoxes[2 * gid + 1].xyz;
        float3 c = (inst.transform * float4((lo + hi) * 0.5f, 1.0f)).xyz, e = (hi - lo) * 0.5f;
        float3 r = abs(inst.transform[0].xyz) * e.x + abs(inst.transform[1].xyz) * e.y + abs(inst.transform[2].xyz) * e.z;
        lo = c - r;
        hi = c + r;
        b.row0 = inst.normalMatrix[0];
        b.row1 = inst.normalMatrix[1];
        b.row2 = inst.normalMatrix[2];
        b.mask = inst.pad0;
    }
    boxData[gid] = b;
    for (uint k = 0; k < 3; ++k) { boxes[6 * gid + k] = lo[k]; boxes[6 * gid + 3 + k] = hi[k]; }
}
