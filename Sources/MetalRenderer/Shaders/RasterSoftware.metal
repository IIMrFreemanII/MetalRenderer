// ---------------------------------------------------------------------------------------------
// The raster clusters' software rasterizer (RasterVirtual.software), as Nanite's: a cluster whose screen box is small
// (RasterVGParams.softwareSide) is not drawn but rasterized here, a threadgroup a cluster and a thread a triangle, into
// a buffer of 64-bit words, one a pixel: the reversed depth's bits << 32 | the triangle's visibility-buffer y, kept by
// atomic max, so the nearest wins whatever the order. The trace meets its primary ray with the named triangle
// (visibilityHit), so depth and the id are all it needs: no attributes. The depth pyramids take the larger of its depths
// and the draws' (hzbInitKernel), and after the second pass rasterSWResolveKernel writes its pixels that are in front of
// the draws' into the visibility buffer.
//
// 64-bit atomic max on device buffers needs an Apple8 GPU (M2) or later: RASTER_SOFTWARE (Pipelines.compile) is 0 on
// the others, where the kernels do nothing (Capabilities.atomics64 keeps the mode off there).
// ---------------------------------------------------------------------------------------------

constant int RSW_BITS = 8;                       // sub-pixel bits of the snapped vertices
constant int RSW_SCALE = 1 << RSW_BITS;
constant int RSW_HALF = RSW_SCALE / 2;           // a pixel's centre

// Twice the signed area of (a, b, p) in snapped units, exact: > 0 when p is left of a -> b with y down.
inline long rswEdge(int2 a, int2 b, int2 p) {
    return long(b.x - a.x) * long(p.y - a.y) - long(b.y - a.y) * long(p.x - a.x);
}

// A sample exactly on edge a -> b counts for the triangle on one side only (as a top-left rule does), so two triangles
// that share the edge leave no gap and no overlap: 0 to keep it, -1 to drop it.
inline long rswTie(int2 a, int2 b) {
    int2 d = b - a;
    return (d.y > 0 || (d.y == 0 && d.x < 0)) ? 0 : -1;
}

// Pass 1, before the cut: nothing drawn in software yet.
kernel void rasterSWClearKernel(constant Uniforms& u      [[buffer(0)]],
                                device uint*       sw     [[buffer(7)]],
                                device ulong*      depths [[buffer(8)]],
                                uint i [[thread_position_in_grid]])
{
    if (i < RSW_ENTRIES) sw[i] = 0u;
    if (i < u.width * u.height) depths[i] = 0ul;
}

// After each pass's cut or retest: its software clusters' threadgroups (pass 1's are the entries before pass 2's).
kernel void rasterSWArgsKernel(constant RasterParams&   rp [[buffer(9)]],
                               constant RasterVGParams& p  [[buffer(21)]],
                               device uint*             sw [[buffer(7)]])
{
    uint n = min(sw[RSW_COUNT], p.capacity);
    if (rp.pass == 0u) sw[RSW_BASE] = n;
    uint first = rp.pass == 0u ? 0u : sw[RSW_BASE];
    sw[RSW_ARGS + 4u * rp.pass] = n - first;
    sw[RSW_ARGS + 4u * rp.pass + 1u] = 1u;
    sw[RSW_ARGS + 4u * rp.pass + 2u] = 1u;
}

// One threadgroup of RASTER_CHUNK threads per software cluster of the pass: its vertices projected and snapped once,
// then a thread per triangle over the pixel centres of its box. (The cut keeps the box at most softwareSide pixels a
// side, which bounds the loops, and in front of the near plane.)
kernel void rasterSWKernel(constant Uniforms&       u       [[buffer(0)]],
                           device const uint*       sw      [[buffer(7)]],
                           device ulong*            depths  [[buffer(8)]],
                           constant RasterParams&   rp      [[buffer(9)]],
                           device const float4*     vgPool  [[buffer(20)]],
                           constant RasterVGParams& p       [[buffer(21)]],
                           device const uint*       state   [[buffer(26)]],
                           device const uint2*      list    [[buffer(27)]],
                           uint tg [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]])
{
#if RASTER_SOFTWARE && defined(__HAVE_ATOMIC_ULONG_MIN_MAX__)
    threadgroup int2  screen[256];   // a cluster has at most 255 vertices
    threadgroup float depth[256];
    uint k = sw[RSW_ENTRIES + (rp.pass == 0u ? 0u : sw[RSW_BASE]) + tg];
    device const float4* blob = vgPool + list[k].y;
    uint4 header = ((device const uint4*)blob)[0];    // nodes, vertices, triangles
    uint4 offsets = ((device const uint4*)blob)[1];   // bytes: nodes, positions, UVs, triangles
    device const uchar* base = (device const uchar*)blob;
    uint2 owner = list[p.capacity + k];               // virtual instance, scene instance (rvgOwners)
    RasterInstance r = ((device const RasterInstance*)(state + RVG_HEADER))[owner.x];
    device const float4* positions = (device const float4*)(base + offsets.y);
    float2 size = float2(u.width, u.height);
    for (uint v = lane; v < header.y; v += RASTER_CHUNK) {
        float4 c = rasterClip(positions[v].xyz, r);   // (where the draw puts it: pixel centres at + 0.5)
        float2 ndc = c.xy / c.w;
        screen[v] = int2(rint(float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * size * float(RSW_SCALE)));
        depth[v] = NEAR_PLANE / c.w;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane >= header.z) return;

    uint packed = ((device const uint*)(base + offsets.w))[lane];
    uint i0 = packed & 0xFFu, i1 = (packed >> 8) & 0xFFu, i2 = (packed >> 16) & 0xFFu;
    int2 a = screen[i0], b = screen[i1], c = screen[i2];
    float za = depth[i0], zb = depth[i1], zc = depth[i2];
    long area = rswEdge(a, b, c);
    if (area == 0) return;   // edge-on
    if (area < 0) {          // both windings are drawn (the draws cull nothing): turn it to positive area
        int2 t = b; b = c; c = t;
        float tz = zb; zb = zc; zc = tz;
        area = -area;
    }
    int2 lo = min(a, min(b, c)), hi = max(a, max(b, c));
    // The pixels whose centres (x + 0.5) lie in the box: ceil((lo - half) / scale) to floor((hi - half) / scale).
    int2 first = max((lo - RSW_HALF + RSW_SCALE - 1) >> RSW_BITS, int2(0));
    int2 last = min((hi - RSW_HALF) >> RSW_BITS, int2(u.width, u.height) - 1);
    long t0 = rswTie(b, c), t1 = rswTie(c, a), t2 = rswTie(a, b);
    float inv = 1.0f / float(area);
    ulong id = ulong(RASTER_CLUSTER_ID | k << 7 | lane);
    for (int y = first.y; y <= last.y; ++y) {
        for (int x = first.x; x <= last.x; ++x) {
            int2 s = int2(x, y) * RSW_SCALE + RSW_HALF;
            long w0 = rswEdge(b, c, s), w1 = rswEdge(c, a, s), w2 = rswEdge(a, b, s);
            if (w0 + t0 < 0 || w1 + t1 < 0 || w2 + t2 < 0) continue;
            float z = (float(w0) * za + float(w1) * zb + float(w2) * zc) * inv;   // reversed depth: affine on screen
            ulong word = ulong(as_type<uint>(z)) << 32 | id;
            atomic_max_explicit((device atomic_ulong*)&depths[uint(y) * u.width + uint(x)], word, memory_order_relaxed);
        }
    }
#endif
}

// After the second pass: each pixel the software rasterizer drew in front of the draws' takes its triangle.
kernel void rasterSWResolveKernel(device const ulong*             depths [[buffer(8)]],
                                  constant RasterVGParams&        p      [[buffer(21)]],
                                  device const uint2*             list   [[buffer(27)]],
                                  depth2d<float, access::read>    depth  [[texture(0)]],
                                  texture2d<uint, access::write>  vis    [[texture(1)]],
                                  uint2 tid [[thread_position_in_grid]])
{
    uint width = depth.get_width();
    if (tid.x >= width || tid.y >= depth.get_height()) return;
    ulong word = depths[tid.y * width + tid.x];
    if (word == 0ul) return;
    if (!(as_type<float>(uint(word >> 32)) > depth.read(tid))) return;   // the draws' is nearer (or the same)
    uint y = uint(word);
    vis.write(uint4(list[p.capacity + ((y >> 7) & 0xFFFFFFu)].y, y, 0u, 0u), tid);
}

// ---------------------------------------------------------------------------------------------
// The shadow maps' software rasterizer (VSMSettings.software): a cluster of the shadow views' cut whose box covers at
// most VSMSoftwareParams.side texels of a page is rasterized here for each page to draw it covers, instead of drawn.
// The pages are a depth array, which a kernel can't write, so it rasterizes into a word a texel of each page drawn
// this frame (Renderer.vsmSoftware: the render list's places), the largest reversed depth by 32-bit atomic max (no id:
// the shadow maps keep depth alone, so it needs no 64-bit atomics), and in the pages' draw a quad a page writes those
// depths through the depth test (vsmMergeFragment), as the draws' own.
// ---------------------------------------------------------------------------------------------

constant uint VSW_TEXELS = VSM_PAGE * VSM_PAGE;

// After vsmSettleKernel (the pages to draw are known), one thread: the list empty, and vsmSWWipeKernel's threadgroups
// (64 threads each) for the pages to draw this frame alone, at VSW_WIPE.
constant uint VSW_WIPE = 8;
kernel void vsmSWClearKernel(constant VSMParams&  vp       [[buffer(9)]],
                             device VSMCounters*  counters [[buffer(13)]],
                             device uint*         sw       [[buffer(1)]])
{
    for (uint i = 0; i < VSW_ENTRIES; ++i) sw[i] = 0u;
    uint drawn = min(atomic_load_explicit(&counters->drawn, memory_order_relaxed), vp.budget);
    sw[VSW_WIPE] = drawn * (VSW_TEXELS / 64u);
    sw[VSW_WIPE + 1u] = 1u;
    sw[VSW_WIPE + 2u] = 1u;
}

// Those pages' software depths at 0 (nothing drawn).
kernel void vsmSWWipeKernel(device uint* depths [[buffer(3)]], uint i [[thread_position_in_grid]]) { depths[i] = 0u; }

// After the cut: the list's threadgroups, one a (cluster, page).
kernel void vsmSWArgsKernel(constant VSMSoftwareParams& swp [[buffer(8)]],
                            device uint*                sw  [[buffer(1)]])
{
    sw[VSW_ARGS] = min(sw[VSW_COUNT], swp.capacity);
    sw[VSW_ARGS + 1u] = 1u;
    sw[VSW_ARGS + 2u] = 1u;
}

// One threadgroup of RASTER_CHUNK threads a (cluster, page): its vertices to the page's texels once (as vsmVertex puts
// them: vsmClipLocal, vsmPageClip), then a thread a triangle over the texel centres of its box on the page, depth
// interpolated and clamped as the draws' (clampDepth). The cut only lists boxes in front of the light (w > 0).
kernel void vsmSWKernel(constant VSMClusterArgs& vg         [[buffer(7)]],
                        device const uint*       sw         [[buffer(1)]],
                        device atomic_uint*      depths     [[buffer(3)]],
                        device const uint4*      renderList [[buffer(30)]],
                        uint tg [[threadgroup_position_in_grid]], uint lane [[thread_index_in_threadgroup]])
{
    threadgroup int2  screen[256];
    threadgroup float depth[256];
    uint4 e = ((device const uint4*)(sw + VSW_ENTRIES))[tg];   // record place, pool offset, triangles, render-list place
    VSMInstance r = vg.records[e.x];
    device const float4* blob = vg.pool + e.y;
    uint4 header = ((device const uint4*)blob)[0];    // nodes, vertices, triangles
    uint4 offsets = ((device const uint4*)blob)[1];   // bytes: nodes, positions, UVs, triangles
    device const uchar* base = (device const uchar*)blob;
    device const float4* positions = (device const float4*)(base + offsets.y);
    uint4 page = renderList[e.w];                      // entry, physical page, window page x | y << 16, pages a side
    uint2 window = uint2(page.z & 0xFFFFu, page.z >> 16);
    for (uint v = lane; v < header.y; v += RASTER_CHUNK) {
        float4 c = vsmPageClip(vsmClipLocal(positions[v].xyz, r), window, page.w);
        float2 ndc = c.xy / c.w;
        screen[v] = int2(rint(float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * float(VSM_PAGE) * float(RSW_SCALE)));
        depth[v] = c.z / c.w;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane >= min(header.z, e.z & 0xFFFFu)) return;

    uint packed = ((device const uint*)(base + offsets.w))[lane];
    uint i0 = packed & 0xFFu, i1 = (packed >> 8) & 0xFFu, i2 = (packed >> 16) & 0xFFu;
    int2 a = screen[i0], b = screen[i1], c = screen[i2];
    float za = depth[i0], zb = depth[i1], zc = depth[i2];
    long area = rswEdge(a, b, c);
    if (area == 0) return;
    if (area < 0) {
        int2 t = b; b = c; c = t;
        float tz = zb; zb = zc; zc = tz;
        area = -area;
    }
    int2 lo = min(a, min(b, c)), hi = max(a, max(b, c));
    int2 first = max((lo - RSW_HALF + RSW_SCALE - 1) >> RSW_BITS, int2(0));
    int2 last = min((hi - RSW_HALF) >> RSW_BITS, int2(int(VSM_PAGE) - 1));
    long t0 = rswTie(b, c), t1 = rswTie(c, a), t2 = rswTie(a, b);
    float inv = 1.0f / float(area);
    device atomic_uint* texels = depths + e.w * VSW_TEXELS;
    for (int y = first.y; y <= last.y; ++y) {
        for (int x = first.x; x <= last.x; ++x) {
            int2 s = int2(x, y) * RSW_SCALE + RSW_HALF;
            long w0 = rswEdge(b, c, s), w1 = rswEdge(c, a, s), w2 = rswEdge(a, b, s);
            if (w0 + t0 < 0 || w1 + t1 < 0 || w2 + t2 < 0) continue;
            float z = saturate((float(w0) * za + float(w1) * zb + float(w2) * zc) * inv);
            if (z > 0.0f) atomic_fetch_max_explicit(&texels[uint(y) * VSM_PAGE + uint(x)], as_type<uint>(z), memory_order_relaxed);
        }
    }
}

// The pages' draw, after the draws: a quad a page drawn this frame (the clear's), whose texels the software rasterizer
// reached write its depth, through the same depth test.
struct VSMMergeVertex {
    float4 position [[position]];
    uint   layer [[render_target_array_index]];
    uint   place [[flat]];       // the page's in the render list (its software depths)
};
vertex VSMMergeVertex vsmMergeVertex(device const uint4* renderList [[buffer(30)]],
                                     uint vid [[vertex_id]], uint iid [[instance_id]])
{
    VSMMergeVertex out;
    float2 c = float2((vid == 1u || vid == 2u || vid == 4u) ? 1.0f : -1.0f, (vid == 2u || vid == 4u || vid == 5u) ? 1.0f : -1.0f);
    out.position = float4(c, 0.0f, 1.0f);
    out.layer = renderList[iid].y;
    out.place = iid;
    return out;
}
struct VSMMergeDepth {
    float depth [[depth(greater)]];
};
fragment VSMMergeDepth vsmMergeFragment(VSMMergeVertex in [[stage_in]], device const uint* depths [[buffer(3)]]) {
    uint2 t = min(uint2(in.position.xy), uint2(VSM_PAGE - 1u));
    uint d = depths[in.place * VSW_TEXELS + t.y * VSM_PAGE + t.x];
    if (d == 0u) discard_fragment();
    VSMMergeDepth out;
    out.depth = as_type<float>(d);
    return out;
}
