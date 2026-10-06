// ---------------------------------------------------------------------------------------------
// Virtual Shadow Maps (ShadowMethod.virtualMaps, VSM.swift), in the manner of Unreal's: each mapped light has a huge
// virtual depth map seen from it, of which only the pages of 128 x 128 texels that the frame's shadow samples looked
// at are held, in a pool of physical pages (one slice each of a depth array), and drawn by the raster's chunks.
//   * A sun has a clipmap: `levels` orthographic views around the camera, 16 m wide at level 0 and doubling, each
//     128 x 128 pages (16k texels a side); its pages are named by where they are in the light's space, so the camera's
//     moves keep them.
//   * A spot light has one perspective view over its cone, 128 x 128 pages at mip 0 and its mips down to 1 x 1.
//   * A sphere light has a cube: 6 perspective faces of 32 x 32 pages, and their mips.
// Each frame, ahead of the trace: the pages last frame's samples asked for get physical pages (vsmFreeKernel frees the
// ones nobody asked for in a while, vsmAllocKernel hands out the free ones), the instances and chunks in front of the
// pages that need drawing are culled into a draw list (vsmCullKernel, vsmChunksKernel), and one render pass clears and
// draws them (vsmClearVertex, vsmVertex), each triangle into its page's slice.
// A shadow sample (vsmVisibility) marches the segment from the surface toward its point on the light through the map,
// a few steps, the way Unreal's shadow-map ray tracing does: occluded where a step lies behind what the map holds.
// What the raster doesn't draw (MASK_SHADOW_TRACED) is traced as well; a sample whose pages aren't ready traces it all.
// ---------------------------------------------------------------------------------------------

constant uint VSM_PAGE = 128;                    // texels a page side
constant uint VSM_RESIDENT = 0x80000000u;        // a page-table entry: a physical page holds it
constant uint VSM_RENDERED = 0x40000000u;        // ...and it is drawn and up to date
constant uint VSM_PHYSICAL = 0xFFFFu;            // ...its physical page
constant uint VSM_NONE = 0xFFFFFFFFu;

// A view's kind (VSMView.kind; VSM.swift VSMKind).
constant uint VSM_SUN = 0, VSM_SPOT = 1, VSM_SPHERE = 2;
constant uint VSM_VIEW_STALE = 1;                // VSMView.flags: its drawn pages are out of date (the light moved)

// A view of a light's map (GPUVSMView): a sun's clipmap level, a spot's mip, a sphere's face at a mip.
struct VSMView {
    float4 x, y, z, w;   // world, relative to `origin`, to the clip position over the whole view; z / w is the stored
                         // depth, larger nearer the light (the sun: linear over its depth range; else NEAR / distance)
    float4 origin;       // xyz
    float4 params;       // x = texel size (the sun; else at 1 m from the light), y = the sun: metres a unit of depth,
                         // z = perspective: the near distance
    int2 window;         // the sun: the absolute page (in the light's space) of the view's first; entry = page mod pages
    uint table;          // its first page-table entry
    uint pages;          // pages a side
    uint light;          // the light's index
    uint kind;           // VSM_SUN, VSM_SPOT, VSM_SPHERE
    uint level;          // clipmap level, or mip
    uint flags;          // VSM_VIEW_*
};
static_assert(sizeof(VSMView) == 128, "VSMView: GPUVSMView");

// A mapped light (GPUVSMLight), by its index among the lights: its views, the first of them + 1 (0: not mapped).
struct VSMLight {
    uint firstView;      // + 1
    uint levels;         // the sun's clipmap levels; the mips of a spot's view, or of each of a sphere's faces
    uint kind;
    uint pad;
};

// What a shadow sample reads (SceneShading.vsm, written every frame by VSMTargets.writeScene).
struct VSMScene {
    device const VSMView*  views;
    device const VSMLight* lights;
    device const uint*     table;       // per page-table entry: VSM_RESIDENT | VSM_RENDERED | physical page
    device const uint*     tags;        // per entry, the sun's: the absolute page it holds (x | y << 16)
    device uint*           requests;    // per entry: 1 = a sample wanted it this frame (vsmAllocKernel reads them)
    depth2d_array<float>   pool;        // the physical pages
    uint                   lightCount;  // `lights` entries
    uint                   steps;       // the march's
    float                  bias;        // in texels
    uint                   flags;       // VSM_S_*
    float4                 camera;      // xyz = the camera's position, w = a pixel's size 1 m in front of it
    float4                 forward;     // xyz = its view direction
};
static_assert(sizeof(VSMScene) == 96, "VSMScene: VSMTargets.writeScene");

constant uint VSM_S_TRACED = 1;         // the scene has geometry the raster doesn't draw (MASK_SHADOW_TRACED)

// A pixel's size at p (what vsmPickView sizes texels by).
inline float vsmFootprint(device const VSMScene& vs, float3 p) {
    return max(dot(p - vs.camera.xyz, vs.forward.xyz), 1e-3f) * vs.camera.w;
}

// A view's clip position of the world point q.
inline float4 vsmClip(VSMView v, float3 q) {
    float4 p = float4(q - v.origin.xyz, 1.0f);
    return float4(dot(v.x, p), dot(v.y, p), dot(v.z, p), dot(v.w, p));
}

inline uint vsmTag(int2 page) { return (uint(page.x) & 0xFFFFu) | (uint(page.y) << 16); }

// The page-table entry of a view's page (window coordinates, 0 ..< pages): the sun's views wrap around by absolute page.
inline uint vsmEntry(thread const VSMView& v, uint2 page) {
    if (v.kind == VSM_SUN) {
        int2 a = v.window + int2(page);
        return v.table + (uint(a.y) & (v.pages - 1u)) * v.pages + (uint(a.x) & (v.pages - 1u));
    }
    return v.table + page.y * v.pages + page.x;
}

// The view of light map `m` that the point q at `footprint` metres a pixel samples: the sun's coarsest clipmap level
// whose texels are no larger (or the first whose window holds q); a spot's or a sphere face's mip whose texels are about
// that size.
inline uint vsmPickView(device const VSMScene& vs, VSMLight m, float3 q, float footprint, float3 lightPos) {
    uint first = m.firstView - 1u;
    if (m.kind == VSM_SUN) {
        // Level l's texel: 16 m x 2^l / 16384; the coarsest no larger than the pixel (larger loses a facade's recesses).
        int l = clamp(int(floor(log2(max(footprint, 1e-6f) * 1024.0f))), 0, int(m.levels) - 1);
        for (; l < int(m.levels) - 1; ++l) {
            float4 c = vsmClip(vs.views[first + uint(l)], q);
            if (all(abs(c.xy) < 0.98f)) break;
        }
        return first + uint(l);
    }
    float3 d = q - lightPos;
    uint face = 0u;
    if (m.kind == VSM_SPHERE) {
        float3 a = abs(d);
        face = a.x >= a.y && a.x >= a.z ? (d.x >= 0.0f ? 0u : 1u) : a.y >= a.z ? (d.y >= 0.0f ? 2u : 3u) : (d.z >= 0.0f ? 4u : 5u);
    }
    uint base = first + face * m.levels;
    VSMView v0 = vs.views[base];
    float dist = max(vsmClip(v0, q).w, 1e-3f);
    int mip = clamp(int(round(log2(max(footprint, 1e-6f) / (v0.params.x * dist)))), 0, int(m.levels) - 1);
    return base + uint(mip);
}

// What view v's map says of the point q: how much nearer the light than q its occluder there is (metres; <= 0: none),
// or -INFINITY when the page isn't ready (asked for, for the next frame). `texel`: the texel's size at q.
inline float vsmGap(device const VSMScene& vs, uint view, float3 q, thread float& texel) {
    VSMView v = vs.views[view];
    float4 c = vsmClip(v, q);
    if (!(c.w > 0.0f)) return -INFINITY;
    float2 ndc = c.xy / c.w;
    if (any(abs(ndc) >= 1.0f)) return -INFINITY;
    float2 at = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * float(v.pages);   // in pages
    uint2 page = min(uint2(at), uint2(v.pages - 1u));
    uint entry = vsmEntry(v, page);
    if (vs.requests[entry] == 0u) vs.requests[entry] = 1u;   // keep it, or draw it for the next frame
    uint e = vs.table[entry];
    if ((e & (VSM_RESIDENT | VSM_RENDERED)) != (VSM_RESIDENT | VSM_RENDERED)) return -INFINITY;
    if (v.kind == VSM_SUN && vs.tags[entry] != vsmTag(v.window + int2(page))) return -INFINITY;
    uint2 t = min(uint2((at - float2(page)) * float(VSM_PAGE)), uint2(VSM_PAGE - 1u));
    float stored = vs.pool.read(t, e & VSM_PHYSICAL);
    if (v.kind == VSM_SUN) {
        texel = v.params.x;
        return (stored - c.z) * v.params.y;
    }
    texel = v.params.x * c.w;
    return stored > 0.0f ? c.w - v.params.z / stored : 0.0f;
}

// Light `li`'s visibility from p toward `target` (lightShadowTarget's point) through its virtual shadow map: 1 or 0,
// with `blocker` the occluder's distance; -1 when a page it needs isn't ready, or the light has no map (trace the ray).
// `n`: the surface's normal (the bias grows with the slope), `footprint`: a pixel's size at p.
inline float vsmVisibility(device const VSMScene& vs, uint li, Light light, float3 p, float3 n, float3 target, float footprint,
                           thread float& blocker) {
    blocker = 0.0f;
    if (li >= vs.lightCount) return -1.0f;
    VSMLight m = vs.lights[li];
    if (m.firstView == 0u) return -1.0f;
    float3 d = target - p;
    float len = length(d);
    float3 dir = d / len;
    // The sun's march: as far as an occluder could widen the penumbra by a few texels; a local light's: to the light.
    float reach = m.kind == VSM_SUN ? min(len, 64.0f) : len * 0.95f;
    float NoL = saturate(dot(n, dir));
    float slope = min(sqrt(max(1.0f - NoL * NoL, 0.0f)) / max(NoL, 0.1f), 8.0f);
    float3 lightPos = light.positionRadius.xyz;
    uint view = vsmPickView(vs, m, p, footprint, lightPos);
    for (uint k = 0; k < vs.steps; ++k) {
        float f = float(k) / float(vs.steps);
        float t = reach * f * f;
        float3 q = p + dir * t;
        if (m.kind == VSM_SPHERE && k > 0u) view = vsmPickView(vs, m, q, footprint, lightPos);   // (its face)
        float texel;
        float gap = vsmGap(vs, view, q, texel);
        if (gap == -INFINITY) return -1.0f;
        if (gap > vs.bias * texel * (1.0f + slope)) {
            blocker = max(t + gap, 1e-3f);
            return 0.0f;
        }
    }
    return 1.0f;
}

// ---------------------------------------------------------------------------------------------
// The pages' upkeep and drawing, ahead of the frame's trace.
// ---------------------------------------------------------------------------------------------

// GPUVSMParams.
struct VSMParams {
    uint entries;        // page-table entries, every view's
    uint pool;           // physical pages
    uint budget;         // pages drawn a frame at most
    uint frame;
    uint keep;           // frames a page nobody asks for is kept
    uint instanceCount;  // as RasterParams'
    uint meshCount;
    uint maxDraws;
    uint maxGroups;
    uint flags;          // VSM_P_*
    uint views;
    uint moving;         // instances that move or deform (RasterScene.moving)
};
static_assert(sizeof(VSMParams) == 48, "VSMParams: GPUVSMParams");

constant uint VSM_P_IDS = 1;         // RasterScene.ids maps an instance's place to its id (TILED)
constant uint VSM_P_CACHE = 2;       // drawn pages stay drawn until something invalidates them (else every frame)

// The pass's counters (VSMTargets.counters).
struct VSMCounters {
    atomic_uint vertexCount;     // the chunks' draw: MTLDrawPrimitivesIndirectArguments
    uint instanceCount;
    uint vertexStart;
    uint baseInstance;
    atomic_uint groupsX;         // vsmChunksKernel's MTLDispatchThreadgroupsIndirectArguments
    uint groupsY;
    uint groupsZ;
    atomic_uint groups;          // groups appended
    uint clearVertexCount;       // the pages' clear: 6 vertices an instance, an instance a page drawn
    atomic_uint drawn;           // pages to draw (clamped to the budget by vsmSettleKernel)
    uint clearVertexStart;
    uint clearBaseInstance;
    uint cullX;                  // vsmCullKernel's threadgroups: instances / 64, active views, 1
    atomic_uint cullY;
    uint cullZ;
    atomic_uint taken;           // free pages handed out by vsmAllocKernel
    atomic_uint freeCount;       // the free list's
    uint pad0, pad1, pad2;
};
static_assert(sizeof(VSMCounters) == 80, "VSMCounters: VSMTargets.countersSize");

// A drawn instance in a view (as RasterInstance, for a view): its rows to the view's clip space, where its corners
// are, its view and mesh, and the window pages it covers that are drawn this frame.
struct VSMInstance {
    float4 x, y, z, w;
    device const float3* corners;
    device const uint*   indices;
    uint view;
    uint meshIndex;
    uint4 pages;                 // x0, y0, x1, y1 (inclusive)
};
static_assert(sizeof(VSMInstance) == 112, "VSMInstance: VSMTargets.recordSize");

// Virtual geometry drawn as the raster's clusters (RasterClusters.shadowArgs; all null without them): vsmCullKernel
// leaves each (active view, virtual instance) a record, vsmVGCutKernel (RasterClusters.metal) picks and culls the
// clusters for its pages at a level of detail of the view's texels, and vsmVertex reads their vertices in the pool.
struct VSMClusterArgs {
    device VSMInstance*  records;       // per (active view, virtual instance): meshIndex = the frame + 1 it is from
    device const uint*   changed;       // per virtual instance: its mesh got groups this frame (its pages go stale)
    device atomic_uint*  requests;      // a count, 3 words, then (group, priority) pairs
    device const float4* pool;
    device const uint4*  vinstances;    // VGRasterInstance
    device const float4* groups;        // VGGroupRecord
    device const float4* clusters;      // VGCluster
    device const uint*   groupPage;
    device atomic_uint*  requestStamp;
    device uint*         lastUsed;
    uint  instanceCount;                // virtual instances
    uint  workCount;                    // (virtual instance, group) pairs
    uint  requestCapacity;
    float tau;                          // allowed projected error, in the view's texels
};
static_assert(sizeof(VSMClusterArgs) == 96, "VSMClusterArgs: RasterClusters.shadowArgs");

// The pages to draw this frame (VSMTargets.renderList): x = page-table entry, y = physical page, z = window page
// (x | y << 16), w = its view's pages a side.

// A view's rows for an instance: its clip position of an object-space point.
inline VSMInstance vsmProjection(float4x4 m, thread const VSMView& v) {
    float4x4 rel = m;
    rel[3].xyz -= v.origin.xyz;
    VSMInstance r;
    r.x = v.x * rel;
    r.y = v.y * rel;
    r.z = v.z * rel;
    r.w = v.w * rel;
    r.corners = nullptr;
    r.indices = nullptr;
    return r;
}

inline float4 vsmClipLocal(float3 local, thread const VSMInstance& r) {
    float4 p = float4(local, 1.0f);
    return float4(dot(r.x, p), dot(r.y, p), dot(r.z, p), dot(r.w, p));
}

// The window pages an object-space box covers in a view (`pages` a side): false when it is outside.
inline bool vsmBoxPages(float3 lo, float3 hi, thread const VSMInstance& r, uint pages, thread uint4& rect) {
    float2 a = float2(INFINITY), b = float2(-INFINITY);
    uint outside = 0x1Fu;
    bool behind = false;
    for (uint c = 0; c < 8; ++c) {
        float4 p = vsmClipLocal(float3((c & 1u) ? hi.x : lo.x, (c & 2u) ? hi.y : lo.y, (c & 4u) ? hi.z : lo.z), r);
        outside &= (p.x < -p.w ? 1u : 0u) | (p.x > p.w ? 2u : 0u) | (p.y < -p.w ? 4u : 0u) | (p.y > p.w ? 8u : 0u)
                 | (p.w <= 0.0f ? 16u : 0u);   // (not by depth: the draw clamps it)
        if (p.w <= 1e-6f) { behind = true; continue; }
        float2 ndc = p.xy / p.w;
        a = min(a, ndc);
        b = max(b, ndc);
    }
    if (outside != 0u) return false;
    if (behind) { a = float2(-1.0f); b = float2(1.0f); }   // around the light: the whole view
    // ndc -> window pages: x right, y down.
    float n = float(pages);
    float2 lo2 = float2(a.x * 0.5f + 0.5f, 0.5f - b.y * 0.5f) * n, hi2 = float2(b.x * 0.5f + 0.5f, 0.5f - a.y * 0.5f) * n;
    int2 p0 = int2(floor(lo2)), p1 = int2(floor(hi2));
    p0 = max(p0, int2(0)); p1 = min(p1, int2(int(pages) - 1));
    if (any(p0 > p1)) return false;
    rect = uint4(uint2(p0), uint2(p1));
    return true;
}

// The views' bookkeeping for this frame: each view's rectangle of pages to draw (empty) and its activity.
kernel void vsmViewResetKernel(constant VSMParams& vp     [[buffer(9)]],
                               device uint4*       rects  [[buffer(20)]],
                               device atomic_uint* active [[buffer(21)]],
                               uint v [[thread_position_in_grid]])
{
    if (v >= vp.views) return;
    rects[v] = uint4(0xFFFFu, 0xFFFFu, 0u, 0u);
    atomic_store_explicit(&active[v], 0u, memory_order_relaxed);
}

// One thread per page-table entry: pages nobody asked for in `keep` frames, and the sun's pages its window scrolled
// past, go back to the free list; with the light moved (or without the cache), drawn pages are to be drawn again.
kernel void vsmFreeKernel(constant VSMParams&      vp        [[buffer(9)]],
                          device const VSMView*    views     [[buffer(22)]],
                          device const ushort*     entryView [[buffer(23)]],
                          device atomic_uint*      table     [[buffer(24)]],
                          device const uint*       tags      [[buffer(25)]],
                          device uint2*            pages     [[buffer(26)]],   // per physical page: its entry, the frame it was last asked for
                          device uint*             freeList  [[buffer(27)]],
                          device VSMCounters*      counters  [[buffer(13)]],
                          uint i [[thread_position_in_grid]])
{
    if (i >= vp.entries) return;
    uint e = atomic_load_explicit(&table[i], memory_order_relaxed);
    if ((e & VSM_RESIDENT) == 0u) return;
    VSMView v = views[entryView[i]];
    uint physical = e & VSM_PHYSICAL;
    bool drop = vp.frame - pages[physical].y > vp.keep;
    if (v.kind == VSM_SUN) {
        // The window page this entry stands for now; its page is another one if the window has moved past it.
        uint s = i - v.table, n = v.pages;
        int2 slot = int2(int(s % n), int(s / n));
        int2 first = v.window, page = first + ((slot - first) % int(n) + int(n)) % int(n);
        drop = drop || tags[i] != vsmTag(page);
    }
    if (drop) {
        atomic_store_explicit(&table[i], 0u, memory_order_relaxed);
        pages[physical].x = VSM_NONE;
        freeList[atomic_fetch_add_explicit(&counters->freeCount, 1u, memory_order_relaxed)] = physical;
    } else if ((v.flags & VSM_VIEW_STALE) != 0u || (vp.flags & VSM_P_CACHE) == 0u) {
        atomic_store_explicit(&table[i], e & ~VSM_RENDERED, memory_order_relaxed);
    }
}

// One thread per page-table entry: pages last frame's samples asked for get a physical page (from the free list, while
// it lasts) and, if not drawn and up to date, a place in this frame's list of pages to draw (while the budget lasts).
kernel void vsmAllocKernel(constant VSMParams&      vp         [[buffer(9)]],
                           device const VSMView*    views      [[buffer(22)]],
                           device const ushort*     entryView  [[buffer(23)]],
                           device atomic_uint*      table      [[buffer(24)]],
                           device uint*             tags       [[buffer(25)]],
                           device uint2*            pages      [[buffer(26)]],
                           device const uint*       freeList   [[buffer(27)]],
                           device uint*             requests   [[buffer(28)]],
                           device uint*             slots      [[buffer(29)]],   // per entry: its place in renderList
                           device uint4*            renderList [[buffer(30)]],
                           device VSMCounters*      counters   [[buffer(13)]],
                           device atomic_uint*      rects      [[buffer(20)]],   // per view: x0, y0, x1, y1
                           device atomic_uint*      active     [[buffer(21)]],
                           device uint*             activeViews [[buffer(19)]],
                           uint i [[thread_position_in_grid]])
{
    if (i >= vp.entries || requests[i] == 0u) return;
    requests[i] = 0u;
    uint e = atomic_load_explicit(&table[i], memory_order_relaxed);
    uint vi = entryView[i];
    VSMView v = views[vi];
    uint s = i - v.table, n = v.pages;
    uint2 slot = uint2(s % n, s / n);
    uint2 page = slot;   // window coordinates
    if (v.kind == VSM_SUN) {
        int2 first = v.window;
        int2 a = first + ((int2(slot) - first) % int(n) + int(n)) % int(n);
        page = uint2(a - first);
        if ((e & VSM_RESIDENT) == 0u) tags[i] = vsmTag(a);
    }
    if ((e & VSM_RESIDENT) == 0u) {
        uint free = atomic_load_explicit(&counters->freeCount, memory_order_relaxed);
        uint k = atomic_fetch_add_explicit(&counters->taken, 1u, memory_order_relaxed);
        if (k >= free) return;   // the pool is full: rays, until a page comes free
        uint physical = freeList[free - 1u - k];
        e = VSM_RESIDENT | physical;
    }
    uint physical = e & VSM_PHYSICAL;
    pages[physical] = uint2(i, vp.frame);
    if ((e & VSM_RENDERED) == 0u) {
        uint place = atomic_fetch_add_explicit(&counters->drawn, 1u, memory_order_relaxed);
        if (place < vp.budget) {
            renderList[place] = uint4(i, physical, page.x | page.y << 16, n);
            slots[i] = place;
            e |= VSM_RENDERED;
            device atomic_uint* r = rects + 4u * vi;
            atomic_fetch_min_explicit(&r[0], page.x, memory_order_relaxed);
            atomic_fetch_min_explicit(&r[1], page.y, memory_order_relaxed);
            atomic_fetch_max_explicit(&r[2], page.x, memory_order_relaxed);
            atomic_fetch_max_explicit(&r[3], page.y, memory_order_relaxed);
            if (atomic_exchange_explicit(&active[vi], 1u, memory_order_relaxed) == 0u) {
                activeViews[atomic_fetch_add_explicit(&counters->cullY, 1u, memory_order_relaxed)] = vi;
            }
        }
    }
    atomic_store_explicit(&table[i], e, memory_order_relaxed);
}

// One thread per moving instance and view (with the cache): the drawn pages its box covers where it was a frame ago
// and where it is now are drawn again, when asked for. (A view whose light moved is drawn again whole: vsmFreeKernel.)
kernel void vsmInvalidateKernel(device const InstanceData*    instances [[buffer(6)]],
                                constant VSMClusterArgs&      vg        [[buffer(7)]],
                                constant VSMParams&           vp        [[buffer(9)]],
                                device const uint*            ids       [[buffer(10)]],
                                device const uint*            moving    [[buffer(11)]],
                                device const RasterMesh*      rmeshes   [[buffer(14)]],
                                device const VSMView*         views     [[buffer(22)]],
                                device atomic_uint*           table     [[buffer(24)]],
                                uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= vp.moving || tid.y >= vp.views) return;
    VSMView v = views[tid.y];
    if ((v.flags & VSM_VIEW_STALE) != 0u) return;
    uint place = moving[tid.x];
    InstanceData inst = instanceRecord(instances, (vp.flags & VSM_P_IDS) != 0u ? ids[place] : place);
    if ((inst.pad0 & MASK_GEOMETRY) == 0u || (inst.pad0 & (MASK_GLASS | MASK_VOXELS | MASK_SHADOW_TRACED)) != 0u) return;
    if (inst.meshIndex >= vp.meshCount) return;
    RasterMesh rm = rmeshes[inst.meshIndex];
    uint kind = as_type<uint>(rm.hi.w) & RASTER_KIND;
    if (kind == RASTER_SKIP) return;
    // Still this frame (paused, or between its moves): nothing to draw again; but a virtual instance's BLAS may have
    // a new cut, and its clusters finer groups (their cut doesn't follow the camera: vsmVGCutKernel).
    bool moved = false;
    for (uint c = 0; c < 4u; ++c) moved = moved || any(inst.transform[c] != inst.prevTransform[c]);
    bool recut = kind == RASTER_VIRTUAL || (kind == RASTER_CLUSTERS && vg.changed != nullptr && vg.changed[inst.pad1 - 1u] != 0u);
    if (!moved && !recut) return;
    for (uint k = 0; k < 2u; ++k) {
        VSMInstance r = vsmProjection(k == 0u ? inst.prevTransform : inst.transform, v);
        uint4 rect;
        if (!vsmBoxPages(rm.lo.xyz, rm.hi.xyz, r, v.pages, rect)) continue;
        for (uint y = rect.y; y <= rect.w; ++y) {
            for (uint x = rect.x; x <= rect.z; ++x) {
                atomic_fetch_and_explicit(&table[vsmEntry(v, uint2(x, y))], ~VSM_RENDERED, memory_order_relaxed);
            }
        }
    }
}

// After the allocation: the free list loses what was taken, the clear draws one instance a page to draw, the cull
// runs over the instances and the active views.
kernel void vsmSettleKernel(constant VSMParams& vp       [[buffer(9)]],
                            device VSMCounters* counters [[buffer(13)]],
                            uint i [[thread_position_in_grid]])
{
    if (i != 0u) return;
    uint free = atomic_load_explicit(&counters->freeCount, memory_order_relaxed);
    uint taken = atomic_load_explicit(&counters->taken, memory_order_relaxed);
    atomic_store_explicit(&counters->freeCount, free - min(taken, free), memory_order_relaxed);
    atomic_store_explicit(&counters->taken, 0u, memory_order_relaxed);
    uint drawn = min(atomic_load_explicit(&counters->drawn, memory_order_relaxed), vp.budget);
    atomic_store_explicit(&counters->drawn, drawn, memory_order_relaxed);
    counters->clearVertexCount = 6u;
    counters->clearVertexStart = 0u;
    counters->clearBaseInstance = 0u;
    counters->cullX = (vp.instanceCount + 63u) / 64u;
    counters->cullZ = 1u;
}

// Every frame's start: the draw's and the chunks' counters, and the activity (vsmSettleKernel sets the rest).
kernel void vsmResetKernel(constant VSMClusterArgs& vg       [[buffer(7)]],
                           device VSMCounters*      counters [[buffer(13)]],
                           uint i [[thread_position_in_grid]]) {
    if (i != 0u) return;
    if (vg.requests != nullptr) atomic_store_explicit(vg.requests, 0u, memory_order_relaxed);
    atomic_store_explicit(&counters->vertexCount, 0u, memory_order_relaxed);
    counters->instanceCount = 1u;
    counters->vertexStart = 0u;
    counters->baseInstance = 0u;
    atomic_store_explicit(&counters->groupsX, 0u, memory_order_relaxed);
    counters->groupsY = 1u;
    counters->groupsZ = 1u;
    atomic_store_explicit(&counters->groups, 0u, memory_order_relaxed);
    atomic_store_explicit(&counters->drawn, 0u, memory_order_relaxed);
    atomic_store_explicit(&counters->cullY, 0u, memory_order_relaxed);
}

// One thread per instance and active view: an instance in front of the view's pages to draw is appended as groups of
// RASTER_GROUP chunks (x = id, y = first chunk, z = triangles, w = kind), its VSMInstance at its first group's place.
kernel void vsmCullKernel(device const float3*          positions  [[buffer(2)]],
                          constant VSMClusterArgs&      vg         [[buffer(7)]],
                          device const uint*            indices    [[buffer(4)]],
                          device const MeshData*        meshes     [[buffer(5)]],
                          device const InstanceData*    instances  [[buffer(6)]],
                          constant VSMParams&           vp         [[buffer(9)]],
                          device const uint*            ids        [[buffer(10)]],
                          device uint4*                 groups     [[buffer(12)]],
                          device VSMCounters*           counters   [[buffer(13)]],
                          device const RasterMesh*      rmeshes    [[buffer(14)]],
                          device const VGBlasEntry*     vgTable    [[buffer(16)]],
                          device VSMInstance*           records    [[buffer(17)]],
                          device const uint*            activeViews [[buffer(19)]],
                          device const uint4*           rects      [[buffer(20)]],
                          device const VSMView*         views      [[buffer(22)]],
                          uint2 tid [[thread_position_in_grid]])
{
    uint i = tid.x;
    if (i >= vp.instanceCount) return;
    uint vi = activeViews[tid.y];
    uint id = (vp.flags & VSM_P_IDS) != 0u ? ids[i] : i;
    InstanceData inst = instanceRecord(instances, id);
    // Solid geometry the raster draws: not the light proxies, glass, voxel boxes, nor what is traced instead.
    if ((inst.pad0 & MASK_GEOMETRY) == 0u || (inst.pad0 & (MASK_GLASS | MASK_VOXELS | MASK_SHADOW_TRACED)) != 0u) return;
    uint meshIndex = inst.meshIndex;
    if (meshIndex >= vp.meshCount) return;
    RasterMesh rm = rmeshes[meshIndex];
    uint kind = as_type<uint>(rm.hi.w);
    bool clusters = (kind & RASTER_KIND) == RASTER_CLUSTERS;   // (its own cut: vsmVGCutKernel)
    if ((kind & RASTER_KIND) == RASTER_SKIP || (clusters && vg.records == nullptr)) return;
    uint triangles = clusters ? 1u
                   : (kind & RASTER_KIND) == RASTER_VIRTUAL ? vgTable[inst.pad1 - 1u].triangles : meshes[meshIndex].indexCount / 3u;
    if (triangles == 0u) return;
    VSMView v = views[vi];
    VSMInstance r = vsmProjection(inst.transform, v);
    uint4 rect;
    if (!vsmBoxPages(rm.lo.xyz, rm.hi.xyz, r, v.pages, rect)) return;
    uint4 dirty = rects[vi];
    rect = uint4(max(rect.xy, dirty.xy), min(rect.zw, dirty.zw));
    if (any(rect.xy > rect.zw)) return;
    if (clusters) {   // the record its clusters' cut reads, stamped with the frame
        r.view = vi;
        r.meshIndex = vp.frame + 1u;
        r.pages = rect;
        vg.records[tid.y * vg.instanceCount + inst.pad1 - 1u] = r;
        return;
    }
    uint chunks = (triangles + RASTER_CHUNK - 1u) / RASTER_CHUNK, n = (chunks + RASTER_GROUP - 1u) / RASTER_GROUP;
    uint first = atomic_fetch_add_explicit(&counters->groups, n, memory_order_relaxed);
    uint end = min(first + n, vp.maxGroups);
    if (end <= first) return;   // (no room: these pages miss the instance; vsmChunksKernel can't tell them apart)
    for (uint g = first; g < end; ++g) groups[g] = uint4(id, (g - first) * RASTER_GROUP, triangles, kind);
    atomic_fetch_max_explicit(&counters->groupsX, end, memory_order_relaxed);
    if ((kind & RASTER_KIND) == RASTER_VIRTUAL) {
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
    r.view = vi;
    r.meshIndex = meshIndex;
    r.pages = rect;
    records[first] = r;
}

// One threadgroup per group, a thread per chunk: for each page to draw that the chunk's bounds cover (or its
// instance's), a draw: x = the instance's VSMInstance, y = first triangle, z = triangles | kind << 16, w = the page's
// place in the render list. When the list is full, the page isn't drawn after all: its samples trace.
kernel void vsmChunksKernel(constant VSMParams&           vp         [[buffer(9)]],
                            device const uint4*           groups     [[buffer(12)]],
                            device VSMCounters*           counters   [[buffer(13)]],
                            device const RasterMesh*      rmeshes    [[buffer(14)]],
                            device const float4*          bounds     [[buffer(15)]],
                            device const VSMInstance*     records    [[buffer(17)]],
                            device uint4*                 draws      [[buffer(18)]],
                            device const VSMView*         views      [[buffer(22)]],
                            device atomic_uint*           table      [[buffer(24)]],
                            device const uint*            slots      [[buffer(29)]],
                            device const uint4*           renderList [[buffer(30)]],
                            uint g [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]])
{
    uint4 group = groups[g];
    uint chunk = group.y + lane, triangles = group.z, kind = group.w;
    if (chunk * RASTER_CHUNK >= triangles) return;
    uint record = g - group.y / RASTER_GROUP;
    VSMInstance r = records[record];
    VSMView v = views[r.view];
    uint4 rect = r.pages;
    if (((kind & RASTER_KIND) == RASTER_ARRAYS || (kind & RASTER_KIND) == RASTER_BLOCK) && (kind & RASTER_DEFORMS) == 0u) {
        uint at = as_type<uint>(rmeshes[r.meshIndex].lo.w) + chunk;
        uint4 c;
        if (!vsmBoxPages(bounds[2u * at].xyz, bounds[2u * at + 1u].xyz, r, v.pages, c)) return;
        rect = uint4(max(rect.xy, c.xy), min(rect.zw, c.zw));
        if (any(rect.xy > rect.zw)) return;
    }
    uint drawn = atomic_load_explicit(&counters->drawn, memory_order_relaxed);
    uint tris = min(triangles - chunk * RASTER_CHUNK, RASTER_CHUNK) | kind << 16;
    for (uint y = rect.y; y <= rect.w; ++y) {
        for (uint x = rect.x; x <= rect.z; ++x) {
            uint entry = vsmEntry(v, uint2(x, y));
            uint place = slots[entry];
            if (place >= drawn || renderList[place].x != entry) continue;   // not drawn this frame
            uint k = atomic_fetch_add_explicit(&counters->vertexCount, RASTER_CHUNK_VERTICES, memory_order_relaxed) / RASTER_CHUNK_VERTICES;
            if (k < vp.maxDraws) draws[k] = uint4(record, chunk * RASTER_CHUNK, tris, place);
            else atomic_fetch_and_explicit(&table[entry], ~VSM_RENDERED, memory_order_relaxed);
        }
    }
}

struct VSMVertex {
    float4 position [[position]];
    uint   layer [[render_target_array_index]];
};

// Page-local clip position: a view's clip position, to the 128 x 128 viewport of window page `page` of `pages`.
inline float4 vsmPageClip(float4 c, uint2 page, uint pages) {
    float n = float(pages);
    return float4(c.x * n + c.w * (n - 2.0f * float(page.x) - 1.0f), c.y * n + c.w * (1.0f - n + 2.0f * float(page.y)), c.z, c.w);
}

// The draw list's vertex (as rasterVertex): chunk k's triangle t, into the page its draw names.
vertex VSMVertex vsmVertex(constant VSMClusterArgs&    vg         [[buffer(7)]],
                           constant VSMParams&         vp         [[buffer(9)]],
                           device const VSMInstance*   records    [[buffer(17)]],
                           device const uint4*         draws      [[buffer(18)]],
                           device const uint4*         renderList [[buffer(30)]],
                           uint vid [[vertex_id]])
{
    VSMVertex out;
    uint k = vid / RASTER_CHUNK_VERTICES, t = (vid % RASTER_CHUNK_VERTICES) / 3u, corner = vid % 3u;
    uint4 draw = k < vp.maxDraws ? draws[k] : uint4(0u);
    uint kind = draw.z >> 16;
    out.layer = 0u;
    if (t >= (draw.z & 0xFFFFu)) {
        out.position = float4(0.0f, 0.0f, 0.0f, 1.0f);
        return out;
    }
    VSMInstance r;
    float3 p;
    if ((kind & RASTER_KIND) == RASTER_CLUSTERS) {   // x: its (view, virtual instance) record, y: its pool offset
        r = vg.records[draw.x];
        device const float4* blob = vg.pool + draw.y;
        uint4 offsets = ((device const uint4*)blob)[1];   // bytes: nodes, positions, UVs, triangles
        device const uchar* base = (device const uchar*)blob;
        uint packed = ((device const uint*)(base + offsets.w))[t];
        p = ((device const float4*)(base + offsets.y))[(packed >> (8u * corner)) & 0xFFu].xyz;
    } else {
        r = records[draw.x];
        p = rasterTriangleCorner(kind, r.corners, r.indices, draw.y + t, corner);
    }
    uint4 page = renderList[draw.w];
    out.position = vsmPageClip(vsmClipLocal(p, r), uint2(page.z & 0xFFFFu, page.z >> 16), page.w);
    out.layer = page.y;
    return out;
}

// The pages' clear: one quad a page to draw, at the far end (depth 0).
vertex VSMVertex vsmClearVertex(device const uint4* renderList [[buffer(30)]],
                                uint vid [[vertex_id]], uint iid [[instance_id]])
{
    VSMVertex out;
    float2 c = float2((vid == 1u || vid == 2u || vid == 4u) ? 1.0f : -1.0f, (vid == 2u || vid == 4u || vid == 5u) ? 1.0f : -1.0f);
    out.position = float4(c, 0.0f, 1.0f);
    out.layer = renderList[iid].y;
    return out;
}

// Depth only (Metal 4's pipelines rasterize only with a fragment function).
fragment void vsmFragment() {}

// A camera-visible surface's shadow ray from p toward `target` (lightShadowTarget's point) of light `li` (`vsm`:
// SceneShading.vsm): with FLAG_VSM, through the light's virtual shadow map, with what the raster doesn't draw traced;
// else, or when its pages aren't ready, the ray (isVisibleBlocker). `n`: the geometric normal (the bias's slope).
inline bool shadowVisible(uint flags, device const VSMScene* vsm, uint li, Light light, float3 p, float3 n, float3 target,
                          SCENE_ACCEL accel, thread float& blocker) {
    if (flagOn(flags, FLAG_VSM) && vsm != nullptr) {
        float v = vsmVisibility(*vsm, li, light, p, n, target, vsmFootprint(*vsm, p), blocker);
        if (v == 0.0f) return false;
        if (v > 0.0f) {
            if ((vsm->flags & VSM_S_TRACED) == 0u) return true;
            float3 d = target - p;
            float dist = length(d), t;
            bool hit = intersectAny(makeRay(p, d / dist, 0.0f, max(dist - RAY_EPSILON, 0.0f)), MASK_SHADOW_TRACED, accel, t);
            blocker = hit ? max(t, 1e-3f) : 0.0f;
            return !hit;
        }
    }
    return isVisibleBlocker(p, target, accel, blocker);
}

// Whether view `view`'s page under q is drawn and up to date (vsmGap's lookup, without asking for it).
inline bool vsmPageReady(device const VSMScene& vs, uint view, float3 q) {
    VSMView v = vs.views[view];
    float4 c = vsmClip(v, q);
    if (!(c.w > 0.0f) || any(abs(c.xy / c.w) >= 1.0f)) return false;
    float2 ndc = c.xy / c.w;
    uint2 page = min(uint2(float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * float(v.pages)), uint2(v.pages - 1u));
    uint entry = vsmEntry(v, page);
    return (vs.table[entry] & (VSM_RESIDENT | VSM_RENDERED)) == (VSM_RESIDENT | VSM_RENDERED)
        && (v.kind != VSM_SUN || vs.tags[entry] == vsmTag(v.window + int2(page)));
}

// A clipmap level's or mip's colour (none of them magenta).
constant float3 VSM_LEVEL_COLORS[8] = {float3(0.3f, 0.5f, 1.0f), float3(0.2f, 0.85f, 0.85f), float3(0.3f, 0.85f, 0.3f),
                                      float3(0.9f, 0.9f, 0.25f), float3(1.0f, 0.6f, 0.2f), float3(0.85f, 0.3f, 0.25f),
                                      float3(0.95f, 0.95f, 0.95f), float3(0.55f, 0.45f, 0.35f)};

// View "Virtual shadow pages": for the first mapped light that lights the pixel, the view its shadow samples start in,
// a colour per clipmap level or mip, shaded by the normal; magenta where that page isn't ready (its samples trace),
// grey where no mapped light reaches, black without the virtual shadow maps.
kernel void vsmDebugKernel(constant Uniforms&               u           [[buffer(0)]],
                           constant SceneShading&           shading     [[buffer(7)]],
                           device const Light*              lights      [[buffer(8)]],
                           texture2d<float, access::read>   surfacePos  [[texture(0)]],
                           texture2d<float, access::read>   normalDepth [[texture(1)]],
                           texture2d<float, access::write>  output      [[texture(2)]],
                           uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    float4 sp = surfacePos.read(tid);
    if (!flagOn(u.flags, FLAG_VSM) || shading.vsm == nullptr || sp.w <= 0.0f) { output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), tid); return; }
    device const VSMScene& vs = *shading.vsm;
    float3 p = sp.xyz, n = normalDepth.read(tid).xyz;
    float shade = 0.45f + 0.55f * abs(dot(n, normalize(float3(0.4f, 0.8f, 0.45f))));
    float3 c = float3(0.5f);
    for (uint li = 0; li < min(vs.lightCount, u.lightGroupEnd.w); ++li) {
        VSMLight m = vs.lights[li];
        if (m.firstView == 0u || all(lightUnshadowed(lights[li], p, n, n) <= 0.0f)) continue;
        uint view = vsmPickView(vs, m, p, vsmFootprint(vs, p), lights[li].positionRadius.xyz);
        c = vsmPageReady(vs, view, p) ? VSM_LEVEL_COLORS[vs.views[view].level % 8u] : float3(1.0f, 0.0f, 1.0f);
        break;
    }
    output.write(float4(c * shade, 1.0f), tid);
}
