// ---------------------------------------------------------------------------------------------
// Custom ray tracer: per-frame build of the dynamic top-level tree (LBVH, Karras 2012) over the moving instances
// (CustomRayTracer.encodeBuild). prep -> Morton keys -> bitonic sort -> hierarchy -> bottom-up boxes.
// ---------------------------------------------------------------------------------------------
#if CUSTOM_RT

// A box (lo, hi) moved by m: the box of the moved box (centre + |M| x half extent).
inline void boxToWorld(thread float3& lo, thread float3& hi, float4x4 m) {
    float3 c = (lo + hi) * 0.5f, e = (hi - lo) * 0.5f;
    float3 wc = (m * float4(c, 1.0f)).xyz;
    float3 we = abs(m[0].xyz) * e.x + abs(m[1].xyz) * e.y + abs(m[2].xyz) * e.z;
    lo = wc - we;
    hi = wc + we;
}

// Every instance's RTInstance (world -> object rows = the first three columns of the inverse-transpose), and each
// moving instance's world box: leafBoxes[2k] = (min, instance id bits), leafBoxes[2k + 1] = (max, mask bits).
kernel void rtPrepKernel(constant uint&             instanceCount [[buffer(0)]],
                         device const InstanceData* instances  [[buffer(1)]],
                         device const float4*       meshInfo   [[buffer(2)]],   // per mesh: (box min, BLAS root bits), (box max, 0)
                         device const uint*         dynSlot    [[buffer(3)]],   // per instance: index among the moving ones, or ~0
                         device RTInstance*         out        [[buffer(4)]],
                         device float4*             leafBoxes  [[buffer(5)]],
                         device const RTVoxels*     voxelGrids [[buffer(6)]],   // per assembly (FOLIAGE)
                         constant float4&           lodView    [[buffer(7)]],   // xyz = the camera, w = a traced pixel's angle
                                                                                //   x the LOD bias (0 = triangles always)
                         uint i [[thread_position_in_grid]])
{
    if (i >= instanceCount) return;
    InstanceData inst = instances[i];
    float4 lo = meshInfo[2 * inst.meshIndex], hi = meshInfo[2 * inst.meshIndex + 1];   // virtual meshes too (bounds)
    RTInstance r;
    r.row0 = inst.normalMatrix[0];
    r.row1 = inst.normalMatrix[1];
    r.row2 = inst.normalMatrix[2];
    r.blasRoot = as_type<uint>(lo.w);
    r.mask = inst.pad0;
    r.pad0 = inst.pad1;   // virtual instance + 1 (its BLAS in RTScene.vgBlas), or 0
    r.pad1 = as_type<uint>(hi.w);   // assembly + 1 (the root above is then its tree of parts) or RT_SWAYS, or 0
    if (FOLIAGE && (r.pad1 & RT_ASSEMBLY) != 0 && lodView.w > 0.0f) {
        // A plant far from the camera is traced as its voxels: the level whose voxels are about `bias` traced pixels
        // there, + 1, in the top byte. Every ray sees a plant the same way (it goes by the camera, not the ray), and
        // each plant changes over at a distance of its own, so no line of them does at once.
        float size = voxelGrids[r.pad1 - 1].lo.w * length(inst.transform[0].xyz);
        float lod = log2(distance(inst.transform[3].xyz, lodView.xyz) * lodView.w / size) + float(pcgHash(i) & 0xFFu) * (0.5f / 255.0f) - 0.25f;
        if (lod >= 0.0f) r.pad1 |= (min(uint(lod), VOXEL_LEVELS - 1u) + 1u) << 24;
    }
    out[i] = r;
    uint k = dynSlot[i];
    if (k == RT_NONE) return;
    float3 worldLo = lo.xyz, worldHi = hi.xyz;
    boxToWorld(worldLo, worldHi, inst.transform);   // the mesh box's world box
    leafBoxes[2 * k]     = float4(worldLo, as_type<float>(i));
    leafBoxes[2 * k + 1] = float4(worldHi, as_type<float>(inst.pad0));
}

inline uint rtExpandBits(uint v) {   // 10 bits -> every third bit
    v = (v * 0x00010001u) & 0xFF0000FFu;
    v = (v * 0x00000101u) & 0x0F00F00Fu;
    v = (v * 0x00000011u) & 0xC30C30C3u;
    v = (v * 0x00000005u) & 0x49249249u;
    return v;
}

// One threadgroup of 1024: centroid bounds of the moving instances, then 30-bit Morton keys, padded to `padded`
// (a power of two) with keys that sort last.
[[max_total_threads_per_threadgroup(1024)]]
kernel void rtKeysKernel(constant uint2&       counts    [[buffer(0)]],   // x = moving instances, y = padded count
                         device const float4*  leafBoxes [[buffer(1)]],
                         device uint*          keys      [[buffer(2)]],
                         device uint*          values    [[buffer(3)]],
                         uint lid [[thread_position_in_threadgroup]],
                         uint simdLane [[thread_index_in_simdgroup]],
                         uint simdId [[simdgroup_index_in_threadgroup]])
{
    threadgroup float3 groupLo[32], groupHi[32];
    float3 lo = float3(INFINITY), hi = float3(-INFINITY);
    for (uint k = lid; k < counts.x; k += 1024) {
        float3 c = (leafBoxes[2 * k].xyz + leafBoxes[2 * k + 1].xyz) * 0.5f;
        lo = min(lo, c);
        hi = max(hi, c);
    }
    lo = simd_min(lo); hi = simd_max(hi);
    if (simdLane == 0) { groupLo[simdId] = lo; groupHi[simdId] = hi; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    lo = float3(INFINITY); hi = float3(-INFINITY);
    for (uint s = 0; s < 32; ++s) { lo = min(lo, groupLo[s]); hi = max(hi, groupHi[s]); }
    float3 scale = 1023.0f / max(hi - lo, float3(1e-6f));
    for (uint k = lid; k < counts.y; k += 1024) {
        uint key = 0xFFFFFFFFu;
        if (k < counts.x) {
            float3 c = (leafBoxes[2 * k].xyz + leafBoxes[2 * k + 1].xyz) * 0.5f;
            uint3 q = uint3(clamp((c - lo) * scale, 0.0f, 1023.0f));
            key = (rtExpandBits(q.x) << 2) | (rtExpandBits(q.y) << 1) | rtExpandBits(q.z);
        }
        keys[k] = key;
        values[k] = k;
    }
}

constant uint RT_SORT_BLOCK = 2048;   // keys a threadgroup sorts in threadgroup memory (1024 threads, one pair each)

inline void rtSortStep(threadgroup uint* sk, threadgroup uint* sv, uint n, uint base, uint k, uint j, uint lid) {
    for (uint t = lid; t < n / 2; t += 1024) {
        uint i = 2 * j * (t / j) + (t % j), l = i + j;
        bool ascending = ((base + i) & k) == 0;
        uint a = sk[i], b = sk[l];
        if (a != b && (a > b) == ascending) {
            sk[i] = b; sk[l] = a;
            uint v = sv[i]; sv[i] = sv[l]; sv[l] = v;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
}

// Bitonic sort of (key, value) pairs, ascending. params.y = 0: sort each 2048-key block (alternating directions,
// as bitonic merging needs); params.y = k > 2048: finish stage k inside each block (j < 2048). The padded count
// comes from `counts` (y), possibly written on the GPU: dispatches cover a capacity and skip what's beyond it.
[[max_total_threads_per_threadgroup(1024)]]
kernel void rtSortLocalKernel(constant uint2&  params [[buffer(0)]],
                              device uint*     keys   [[buffer(1)]],
                              device uint*     values [[buffer(2)]],
                              constant uint2&  counts [[buffer(3)]],   // x = leaves, y = padded count
                              uint lid [[thread_position_in_threadgroup]],
                              uint group [[threadgroup_position_in_grid]])
{
    threadgroup uint sk[RT_SORT_BLOCK], sv[RT_SORT_BLOCK];
    uint padded = counts.y;
    uint n = min(RT_SORT_BLOCK, padded), base = group * RT_SORT_BLOCK;
    if (base >= padded || params.y > padded) return;
    for (uint e = lid; e < n; e += 1024) { sk[e] = keys[base + e]; sv[e] = values[base + e]; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (params.y == 0) {
        for (uint k = 2; k <= n; k <<= 1)
            for (uint j = k >> 1; j > 0; j >>= 1) rtSortStep(sk, sv, n, base, k, j, lid);
    } else {
        for (uint j = n >> 1; j > 0; j >>= 1) rtSortStep(sk, sv, n, base, params.y, j, lid);
    }
    for (uint e = lid; e < n; e += 1024) { keys[base + e] = sk[e]; values[base + e] = sv[e]; }
}

// One bitonic step (k, j >= 2048) across blocks, one thread per pair.
kernel void rtSortGlobalKernel(constant uint2&  params [[buffer(0)]],   // x = k, y = j
                               device uint*     keys   [[buffer(1)]],
                               device uint*     values [[buffer(2)]],
                               constant uint2&  counts [[buffer(3)]],
                               uint t [[thread_position_in_grid]])
{
    uint j = params.y, i = 2 * j * (t / j) + (t % j), l = i + j;
    if (params.x > counts.y || l >= counts.y) return;
    bool ascending = (i & params.x) == 0;
    uint a = keys[i], b = keys[l];
    if (a != b && (a > b) == ascending) {
        keys[i] = b; keys[l] = a;
        uint v = values[i]; values[i] = values[l]; values[l] = v;
    }
}

inline int rtDelta(device const uint* keys, int n, int i, int j) {
    if (j < 0 || j >= n) return -1;
    uint a = keys[i], b = keys[j];
    return a != b ? int(clz(a ^ b)) : 32 + int(clz(uint(i ^ j)));   // equal keys: the index breaks the tie
}

// Karras 2012: the sorted keys [first, last] that internal node i of n - 1 covers, and where they split: the left
// child covers [first, split], the right one [split + 1, last] (a child covering one key is that leaf). Shared by
// this tree and virtual geometry's cluster tree.
struct KarrasRange { int first, last, split; };
inline KarrasRange karrasRange(device const uint* keys, int n, int i) {
    int d = rtDelta(keys, n, i, i + 1) - rtDelta(keys, n, i, i - 1) >= 0 ? 1 : -1;
    int deltaMin = rtDelta(keys, n, i, i - d);
    int lmax = 2;
    while (rtDelta(keys, n, i, i + lmax * d) > deltaMin) lmax *= 2;
    int l = 0;
    for (int t = lmax / 2; t >= 1; t /= 2)
        if (rtDelta(keys, n, i, i + (l + t) * d) > deltaMin) l += t;
    int j = i + l * d;
    int deltaNode = rtDelta(keys, n, i, j);
    int s = 0;
    for (int div = 2; ; div *= 2) {
        int t = (l + div - 1) / div;
        if (rtDelta(keys, n, i, i + (s + t) * d) > deltaNode) s += t;
        if (t <= 1) break;
    }
    int split = i + s * d + min(d, 0);
    KarrasRange range;
    range.first = min(i, j); range.last = max(i, j); range.split = split;
    return range;
}

// Internal node i of n - 1 (n = moving instances, >= 2), from the sorted keys. Writes both child refs
// and the parent links the bottom-up pass follows (bit 31 = right child), and clears the arrival counters.
kernel void rtHierarchyKernel(constant uint2&       params     [[buffer(0)]],   // y = index of node 0 in the buffer
                              device const uint*    keys       [[buffer(1)]],
                              device const uint*    values     [[buffer(2)]],
                              device const float4*  leafBoxes  [[buffer(3)]],
                              device BVHNode*       nodes      [[buffer(4)]],   // this tree's nodes (node 0 = root)
                              device uint*          nodeParent [[buffer(5)]],
                              device uint*          leafParent [[buffer(6)]],
                              device atomic_uint*   counters   [[buffer(7)]],
                              constant uint2&       counts     [[buffer(8)]],   // x = n
                              uint gid [[thread_position_in_grid]])
{
    int n = int(counts.x), i = int(gid);
    if (i >= n - 1) return;
    KarrasRange range = karrasRange(keys, n, i);
    int first = range.first, last = range.last, split = range.split;

    uint left, right;
    if (first == split) {
        left = RT_LEAF | as_type<uint>(leafBoxes[2 * values[split]].w);
        leafParent[split] = uint(i);
    } else {
        left = params.y + uint(split);
        nodeParent[split] = uint(i);
    }
    if (last == split + 1) {
        right = RT_LEAF | as_type<uint>(leafBoxes[2 * values[split + 1]].w);
        leafParent[split + 1] = uint(i) | 0x80000000u;
    } else {
        right = params.y + uint(split + 1);
        nodeParent[split + 1] = uint(i) | 0x80000000u;
    }
    nodes[i].lo0.w = as_type<float>(left);
    nodes[i].lo1.w = as_type<float>(right);
    atomic_store_explicit(&counters[i], 0u, memory_order_relaxed);
}

// Bottom-up boxes: each leaf writes its box into its parent's child slot and walks up; the second thread to reach
// a node (counters) unions its two child slots into the grandparent, so every node is finished exactly once.
kernel void rtFitKernel(constant uint2&                 counts     [[buffer(8)]],   // x = n
                        device const uint*              values     [[buffer(2)]],
                        device const float4*            leafBoxes  [[buffer(3)]],
                        coherent(device) device BVHNode* nodes     [[buffer(4)]],
                        device const uint*              nodeParent [[buffer(5)]],
                        device const uint*              leafParent [[buffer(6)]],
                        device atomic_uint*             counters   [[buffer(7)]],
                        uint gid [[thread_position_in_grid]])
{
    if (gid >= counts.x) return;
    uint leaf = values[gid];
    float3 lo = leafBoxes[2 * leaf].xyz;
    float4 hi = leafBoxes[2 * leaf + 1];   // w = mask bits
    uint link = leafParent[gid];
    while (true) {
        uint p = link & 0x7FFFFFFFu;
        if ((link >> 31) != 0) { nodes[p].lo1.xyz = lo; nodes[p].hi1 = hi; }
        else                   { nodes[p].lo0.xyz = lo; nodes[p].hi0 = hi; }
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device);
        if (atomic_fetch_add_explicit(&counters[p], 1u, memory_order_relaxed) == 0) return;   // the sibling finishes p
        atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device);
        BVHNode node = nodes[p];
        lo = min(node.lo0.xyz, node.lo1.xyz);
        hi = float4(max(node.hi0.xyz, node.hi1.xyz), as_type<float>(as_type<uint>(node.hi0.w) | as_type<uint>(node.hi1.w)));
        if (p == 0) return;
        link = nodeParent[p];
    }
}

#endif
