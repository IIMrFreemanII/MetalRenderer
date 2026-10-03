// ---------------------------------------------------------------------------------------------
// Virtual geometry: this frame's cut through every virtual mesh's cluster DAG (VirtualGeometry.swift).
// ---------------------------------------------------------------------------------------------
#if CUSTOM_RT

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
    float4 lo;             // the mesh's bounds (object space), for Morton keys
    float4 hi;
};
static_assert(sizeof(VGInstance) == 48, "VGInstance: VirtualGeometry writes three 16-byte rows");

struct VGParams {
    float4 camPos;         // xyz, w = pixels per unit of error at distance 1 (traced height / (2 tan(fovY / 2)))
    float  tau;            // allowed projected error, in traced pixels
    uint   workCount;
    uint   instanceCount;
    uint   capacity;       // most selected clusters
    uint   frame;
    uint   requestCapacity;
    uint   nodeBase;       // the cluster tree's first node in the top-level node buffer
    uint   pad;
};
static_assert(sizeof(VGParams) == 48, "VGParams: VirtualGeometry's Params");

kernel void vgResetKernel(device uint* counters [[buffer(0)]]) {   // selected, requests, overflow
    counters[0] = 0; counters[1] = 0; counters[2] = 0;
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
                        device uint*                 keys        [[buffer(13)]],
                        device uint*                 values      [[buffer(14)]],
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
    selected[idx] = uint2(vi.instance, page + c.pageOffset / 16);
    // Object-space box (vgFitKernel moves it to world space above the instance's subtree), and a key that sorts by
    // virtual instance first (8 bits), then along a Morton curve inside the mesh's bounds (22 bits).
    leafBoxes[2 * idx]     = float4(c.lo.xyz, as_type<float>(RT_CLUSTER | idx));
    leafBoxes[2 * idx + 1] = float4(c.hi.xyz, as_type<float>(inst.pad0));
    float3 q = clamp(((c.lo.xyz + c.hi.xyz) * 0.5f - vi.lo.xyz) / max(vi.hi.xyz - vi.lo.xyz, float3(1e-6f)), 0.0f, 1.0f) * 1023.0f;
    uint3 qi = uint3(q);
    uint morton = (rtExpandBits(qi.x) << 2) | (rtExpandBits(qi.y) << 1) | rtExpandBits(qi.z);
    keys[idx] = (min(lo, 255u) << 22) | (morton >> 8);
    values[idx] = idx;
}

// After the cut: the leaf count and sort size for the cluster tree's build, and its root ref.
kernel void vgFinishKernel(constant VGParams&  p        [[buffer(0)]],
                           device const uint*  counters [[buffer(5)]],
                           device uint2*       counts   [[buffer(11)]],   // x = leaves, y = padded sort size
                           device uint*        roots    [[buffer(12)]])
{
    uint n = min(counters[0], p.capacity);
    uint padded = 2;
    while (padded < n) padded <<= 1;
    counts[0] = uint2(n, padded);
    if (n < 2) roots[0] = n == 0 ? RT_NONE : (RT_LEAF | RT_CLUSTER);   // 2+: vgHierarchyKernel writes it
}

// Fills the sort input past the leaf count with keys that sort last.
kernel void vgPadKernel(device const uint2* counts [[buffer(11)]],
                        device uint*        keys   [[buffer(13)]],
                        device uint*        values [[buffer(14)]],
                        uint gid [[thread_position_in_grid]])
{
    uint2 c = counts[0];
    if (gid < c.x || gid >= c.y) return;
    keys[gid] = 0xFFFFFFFFu;
    values[gid] = gid;
}

inline bool vgSameInstance(device const uint* keys, int a, int b) { return (keys[a] >> 22) == (keys[b] >> 22); }

// The cluster tree's hierarchy (Karras, as rtHierarchyKernel). Keys start with the virtual instance, so the tree
// splits by instance first; a node whose leaves all share one instance is that instance's (part of the) subtree:
// nodeInstance records it, and the ref to it from a node spanning several instances carries RT_ENTER.
kernel void vgHierarchyKernel(constant uint2&       params       [[buffer(0)]],   // y = index of node 0 in the buffer
                              device const uint*    keys         [[buffer(1)]],
                              device const uint*    values       [[buffer(2)]],
                              device const float4*  leafBoxes    [[buffer(3)]],
                              device BVHNode*       nodes        [[buffer(4)]],
                              device uint*          nodeParent   [[buffer(5)]],
                              device uint*          leafParent   [[buffer(6)]],
                              device atomic_uint*   counters     [[buffer(7)]],
                              constant uint2&       counts       [[buffer(8)]],
                              device const uint2*   selected     [[buffer(9)]],
                              device uint*          nodeInstance [[buffer(10)]],
                              device uint*          roots        [[buffer(12)]],
                              uint gid [[thread_position_in_grid]])
{
    int n = int(counts.x), i = int(gid);
    if (i >= n - 1) return;
    KarrasRange range = karrasRange(keys, n, i);
    int first = range.first, last = range.last, split = range.split;
    bool mine = vgSameInstance(keys, first, last);
    nodeInstance[i] = mine ? selected[values[first]].x : 0xFFFFFFFFu;
    if (i == 0) roots[0] = params.y | (mine ? RT_ENTER : 0u);

    uint left, right;
    if (first == split) {
        left = RT_LEAF | as_type<uint>(leafBoxes[2 * values[split]].w);
        leafParent[split] = uint(i);
    } else {
        left = params.y + uint(split) | (!mine && vgSameInstance(keys, first, split) ? RT_ENTER : 0u);
        nodeParent[split] = uint(i);
    }
    if (last == split + 1) {
        right = RT_LEAF | as_type<uint>(leafBoxes[2 * values[split + 1]].w);
        leafParent[split + 1] = uint(i) | 0x80000000u;
    } else {
        right = params.y + uint(split + 1) | (!mine && vgSameInstance(keys, split + 1, last) ? RT_ENTER : 0u);
        nodeParent[split + 1] = uint(i) | 0x80000000u;
    }
    nodes[i].lo0.w = as_type<float>(left);
    nodes[i].lo1.w = as_type<float>(right);
    atomic_store_explicit(&counters[i], 0u, memory_order_relaxed);
}

// Bottom-up boxes for the cluster tree (as rtFitKernel): boxes stay in their instance's object space up to the node
// where the subtree meets other instances, and are moved to world space there.
kernel void vgFitKernel(constant uint2&                  counts       [[buffer(8)]],
                        device const uint*               values       [[buffer(2)]],
                        device const float4*             leafBoxes    [[buffer(3)]],
                        coherent(device) device BVHNode* nodes        [[buffer(4)]],
                        device const uint*               nodeParent   [[buffer(5)]],
                        device const uint*               leafParent   [[buffer(6)]],
                        device atomic_uint*              counters     [[buffer(7)]],
                        device const uint2*              selected     [[buffer(9)]],
                        device const uint*               nodeInstance [[buffer(10)]],
                        device const InstanceData*       instances    [[buffer(15)]],
                        uint gid [[thread_position_in_grid]])
{
    uint n = counts.x;
    if (gid >= n) return;
    uint leaf = values[gid];
    float3 lo = leafBoxes[2 * leaf].xyz;
    float4 hi = leafBoxes[2 * leaf + 1];   // w = mask bits
    uint inst = selected[leaf].x;          // the box is in this instance's object space (~0: world space)
    if (n == 1) return;
    uint link = leafParent[gid];
    while (true) {
        uint p = link & 0x7FFFFFFFu;
        if (inst != 0xFFFFFFFFu && nodeInstance[p] == 0xFFFFFFFFu) {   // the parent spans several instances
            float3 h3 = hi.xyz;
            boxToWorld(lo, h3, instances[inst].transform);
            hi.xyz = h3;
        }
        if ((link >> 31) != 0) { nodes[p].lo1.xyz = lo; nodes[p].hi1 = hi; }
        else                   { nodes[p].lo0.xyz = lo; nodes[p].hi0 = hi; }
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device);
        if (atomic_fetch_add_explicit(&counters[p], 1u, memory_order_relaxed) == 0) return;
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device);
        BVHNode node = nodes[p];
        lo = min(node.lo0.xyz, node.lo1.xyz);
        hi = float4(max(node.hi0.xyz, node.hi1.xyz), as_type<float>(as_type<uint>(node.hi0.w) | as_type<uint>(node.hi1.w)));
        inst = nodeInstance[p];
        if (p == 0) return;
        link = nodeParent[p];
    }
}

#endif
