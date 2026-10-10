// The Material Painter's kernels (Painter/PainterSession.swift): a painted object's texel map (each texel's triangle
// and barycentrics, drawn in UV space and dilated into the gutters), its tiles' bounds, the brush's dabs into a
// stroke and the stroke into a layer's channels, and the layers composited into the texture set the renderer reads.

// Swift: PaintObjectArgs.
struct PaintObjectArgs {
    float4x4 transform;      // object -> world (now)
    float4x4 normalMatrix;   // its inverse transpose
    uint firstIndex;         // the mesh's first index in the scene's index buffer
    uint vertexOffset;       // a pose slot's vertices (0 else)
    uint size;               // the texture set's side
    uint triangles;
    float texelsPerMetre;    // object space, at `size`
    float heightDepth;       // metres from height 0.5 to 1
    float normalStrength;
    uint layerCount;
    uint aoTexture;          // the table's occlusion bake (~0: none)
    uint mirror;             // dabs: 0 none, 1 + axis (object space x, y, z)
    uint instance;           // the painted instance (surfacePos.w - 1)
    float level;             // paintBakeOriginal: the level its textures are read at
};

// A texel's place on the mesh: its triangle + 1 (0: none) and its barycentrics (two halves).
inline bool paintTexel(texture2d<uint, access::read> map, uint2 p, thread uint& tri, thread float3& w) {
    uint2 m = map.read(p).xy;
    if (m.x == 0u) return false;
    tri = m.x - 1u;
    float2 b = float2(as_type<half2>(m.y));
    w = float3(1.0f - b.x - b.y, b.x, b.y);
    return true;
}

// A texel's object-space point and normal (the vertices as they are now: a pose slot's own).
inline void paintPoint(constant PaintObjectArgs& a, device const uint* indices, device const float3* positions,
                       device const float3* normals, uint tri, float3 w, thread float3& p, thread float3& n) {
    p = float3(0.0f); n = float3(0.0f);
    for (uint k = 0; k < 3u; ++k) {
        uint v = indices[a.firstIndex + 3u * tri + k] + a.vertexOffset;
        p += w[k] * positions[v];
        n += w[k] * normals[v];
    }
    n = length(n) > 0.0f ? normalize(n) : float3(0.0f, 1.0f, 0.0f);
}

// MARK: - Texel map

struct PaintTexelOut {
    float4 position [[position]];
    uint triangle [[flat]];
    float2 bary;
};

vertex PaintTexelOut paintTexelVertex(uint vid [[vertex_id]], device const float2* corners [[buffer(0)]]) {
    PaintTexelOut o;
    float2 uv = corners[vid];
    o.position = float4(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f, 0.0f, 1.0f);
    o.triangle = vid / 3u;
    uint k = vid % 3u;
    o.bary = k == 1u ? float2(1.0f, 0.0f) : k == 2u ? float2(0.0f, 1.0f) : float2(0.0f);
    return o;
}

fragment uint2 paintTexelFragment(PaintTexelOut in [[stage_in]]) {
    return uint2(in.triangle + 1u, as_type<uint>(half2(in.bary)));
}

// The gutter grown by a texel: an empty texel takes a neighbour's triangle (the nearest first), its barycentrics
// extended to its own place on that triangle's plane (clamped not to run off far), and is marked as gutter (bit 31).
kernel void paintDilate(texture2d<uint, access::read> src [[texture(0)]], texture2d<uint, access::write> dst [[texture(1)]],
                        device const float2* corners [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint size = src.get_width();
    if (gid.x >= size || gid.y >= size) return;
    uint2 m = src.read(gid).xy;
    if (m.x != 0u) { dst.write(uint4(m, 0u, 0u), gid); return; }
    const int2 order[8] = {int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1), int2(1, 1), int2(-1, 1), int2(1, -1), int2(-1, -1)};
    for (uint i = 0; i < 8u; ++i) {
        int2 q = int2(gid) + order[i];
        if (q.x < 0 || q.y < 0 || q.x >= int(size) || q.y >= int(size)) continue;
        uint2 n = src.read(uint2(q)).xy;
        if (n.x == 0u) continue;
        uint tri = (n.x - 1u) & 0x7FFFFFFFu;
        float2 c0 = corners[3u * tri], c1 = corners[3u * tri + 1u], c2 = corners[3u * tri + 2u];
        float2 p = (float2(gid) + 0.5f) / float(size);
        float2 e1 = c1 - c0, e2 = c2 - c0, d = p - c0;
        float det = e1.x * e2.y - e1.y * e2.x;
        float2 b = abs(det) > 1e-14f ? float2(d.x * e2.y - d.y * e2.x, e1.x * d.y - e1.y * d.x) / det
                                     : float2(as_type<half2>(n.y));
        b = clamp(b, -1.0f, 2.0f);
        dst.write(uint4((tri + 1u) | 0x80000000u, as_type<uint>(half2(b)), 0u, 0u), gid);
        return;
    }
    dst.write(uint4(0u), gid);
}

// MARK: - Tiles

// Each 32 x 32 tile's object-space bounds (its texels' points as the vertices are now): min in xyz of [2t], max in
// [2t + 1]; empty tiles get min > max. One threadgroup a tile, 8 x 8 threads of 4 x 4 texels.
kernel void paintTileBounds(texture2d<uint, access::read> map [[texture(0)]], constant PaintObjectArgs& a [[buffer(0)]],
                            device const uint* indices [[buffer(1)]], device const float3* positions [[buffer(2)]],
                            device const float3* normals [[buffer(3)]], device float4* bounds [[buffer(4)]],
                            uint2 tg [[threadgroup_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]],
                            uint li [[thread_index_in_threadgroup]]) {
    threadgroup float3 lo[64], hi[64];
    float3 l = float3(INFINITY), h = float3(-INFINITY);
    for (uint y = 0; y < 4u; ++y) {
        for (uint x = 0; x < 4u; ++x) {
            uint2 p = tg * 32u + lid * 4u + uint2(x, y);
            if (p.x >= a.size || p.y >= a.size) continue;
            uint tri; float3 w;
            if (!paintTexel(map, p, tri, w)) continue;
            float3 q, n;
            paintPoint(a, indices, positions, normals, tri & 0x7FFFFFFFu, w, q, n);
            l = min(l, q); h = max(h, q);
        }
    }
    lo[li] = l; hi[li] = h;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 32u; s > 0u; s >>= 1) {
        if (li < s) { lo[li] = min(lo[li], lo[li + s]); hi[li] = max(hi[li], hi[li + s]); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (li == 0u) {
        uint t = tg.y * ((a.size + 31u) / 32u) + tg.x;
        bounds[2u * t] = float4(lo[0], 0.0f);
        bounds[2u * t + 1u] = float4(hi[0], 0.0f);
    }
}

// MARK: - Brush

// Swift: PaintDab. A dab of the brush on the screen (the render's pixels): where, how big, how it falls off, its stamp.
struct PaintDab {
    float2 centre;
    float radius;
    float hardness;
    float opacity;
    float flow;
    float angle;             // the stamp's turn (radians)
    int stamp;               // its layer of the stamps (-1: round)
    float aspect;            // the stamp squashed along its turn (1: round)
    float pad0, pad1, pad2;
};

// Swift: PaintDabArgs.
struct PaintDabArgs {
    float4x4 viewProjection; // world -> clip (this frame's, unjittered)
    float4 camera;           // xyz = the eye
    float2 screen;           // the render's size (surfacePos's)
    uint dabs;
    uint stencil;            // 1: the stencil's colour is taken (strokeColor)
    float3x3 stencilFrame;   // screen pixels -> stencil UV (affine, row 2 = 0 0 1)
    float tolerance;         // world distance a texel's point may be from what the screen shows there, to count as seen
    uint fill;               // 1: a fill (every texel of a selected triangle, at full weight)
    float pad0, pad1;
};

inline float2 paintScreen(constant PaintDabArgs& d, float3 w, thread float& depth) {
    float4 c = d.viewProjection * float4(w, 1.0f);
    depth = c.w;
    float2 ndc = c.xy / max(c.w, 1e-6f);
    return float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * d.screen;
}

constexpr sampler paintLinear(filter::linear, address::clamp_to_edge);

// This frame's dabs into the stroke (the share of the stroke's paint each texel has, approaching each dab's opacity
// by its flow), texel by texel of the tiles they touch (one threadgroup a tile, `tiles`' list): a texel takes a dab
// where its point, as the object is now, shows on the screen under it (its own point is what the render has at that
// pixel: not hidden; and it faces the eye), and its mirror image's too with symmetry. With a stencil, the colour
// under it is taken too (strokeColor, premultiplied by the share it adds).
kernel void paintDab(texture2d<uint, access::read> map [[texture(0)]], texture2d<float, access::read_write> stroke [[texture(1)]],
                     texture2d<float, access::read> surfacePos [[texture(2)]], texture2d_array<float> stamps [[texture(3)]],
                     texture2d<float> stencil [[texture(4)]], texture2d<float, access::read_write> strokeColor [[texture(5)]],
                     constant PaintObjectArgs& a [[buffer(0)]], constant PaintDabArgs& d [[buffer(1)]],
                     device const PaintDab* dabs [[buffer(2)]], device const uint* indices [[buffer(3)]],
                     device const float3* positions [[buffer(4)]], device const float3* normals [[buffer(5)]],
                     device const uint* tiles [[buffer(6)]], device const uchar* selected [[buffer(7)]],
                     uint2 group [[threadgroup_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]]) {
    uint tile = tiles[group.x], across = (a.size + 31u) / 32u;
    uint2 origin = uint2(tile % across, tile / across) * 32u;
    for (uint y = 0; y < 4u; ++y) {
        for (uint x = 0; x < 4u; ++x) {
            uint2 p = origin + lid * 4u + uint2(x, y);
            if (p.x >= a.size || p.y >= a.size) continue;
            uint tri; float3 bw;
            if (!paintTexel(map, p, tri, bw)) continue;
            tri &= 0x7FFFFFFFu;
            float s = stroke.read(p).r;
            float4 sc = d.stencil != 0u ? strokeColor.read(p) : float4(0.0f);
            if (d.fill != 0u) {
                if (selected[tri] != 0u) s = max(s, dabs[0].opacity);
                stroke.write(float4(s), p);
                continue;
            }
            float3 op, on;
            paintPoint(a, indices, positions, normals, tri, bw, op, on);
            uint mirrors = a.mirror != 0u ? 2u : 1u;
            for (uint m = 0; m < mirrors; ++m) {
                float3 q = op, qn = on;
                if (m == 1u) { uint ax = a.mirror - 1u; q[ax] = -q[ax]; qn[ax] = -qn[ax]; }
                float3 w = (a.transform * float4(q, 1.0f)).xyz;
                float3 wn = normalize((a.normalMatrix * float4(qn, 0.0f)).xyz);
                float depth;
                float2 px = paintScreen(d, w, depth);
                if (depth <= 0.0f || px.x < 0.0f || px.y < 0.0f || px.x >= d.screen.x || px.y >= d.screen.y) continue;
                float3 toEye = normalize(d.camera.xyz - w);
                float facing = smoothstep(0.02f, 0.15f, dot(wn, toEye));
                if (facing <= 0.0f) continue;
                float4 shown = surfacePos.read(uint2(px));
                if (uint(shown.w + 0.5f) != a.instance + 1u || distance(shown.xyz, w) > d.tolerance * max(depth, 1.0f)) continue;
                for (uint k = 0; k < d.dabs; ++k) {
                    PaintDab b = dabs[k];
                    float2 off = px - b.centre;
                    float c = cos(b.angle), sn = sin(b.angle);
                    float2 local = float2(c * off.x + sn * off.y, -sn * off.x + c * off.y) / b.radius;
                    local.y *= b.aspect;
                    float r = length(local);
                    if (r >= 1.0f) continue;
                    float wgt = 1.0f - smoothstep(b.hardness, 1.0f, r);
                    if (b.stamp >= 0) wgt *= stamps.sample(paintLinear, local * 0.5f + 0.5f, uint(b.stamp), level(0.0f)).r;
                    wgt *= facing;
                    if (wgt <= 0.0f) continue;
                    float add = (b.opacity - s) * b.flow * wgt;
                    if (add <= 0.0f) continue;
                    s += add;
                    if (d.stencil != 0u) {
                        float2 suv = (d.stencilFrame * float3(px, 1.0f)).xy;
                        float4 col = stencil.sample(paintLinear, suv, level(0.0f));
                        sc = sc * (1.0f - add / max(s, 1e-6f)) + float4(col.rgb, 1.0f) * (add / max(s, 1e-6f));
                    }
                }
            }
            stroke.write(float4(s), p);
            if (d.stencil != 0u) strokeColor.write(sc, p);
        }
    }
}

// Swift: PaintApplyArgs. The stroke into one channel of a layer (or its painted mask): what the channel was when the
// stroke began (`base`) under the brush's value at the stroke's share (premultiplied: rgb x coverage, coverage), or
// the coverage taken away (the eraser).
struct PaintApplyArgs {
    float4 value;            // the brush's value: rgb (a colour channel) or x (a scalar's)
    uint erase;
    uint colour;             // 1: a colour channel (rgba16f: rgb x cov, cov); 0: a scalar's (rg16f: v x cov, cov)
    uint stencil;            // 1: the colour is the stroke's (strokeColor), not `value`
    uint size;
};

kernel void paintApply(texture2d<float, access::read> stroke [[texture(0)]], texture2d<float, access::read> base [[texture(1)]],
                       texture2d<float, access::write> target [[texture(2)]], texture2d<float, access::read> strokeColor [[texture(3)]],
                       constant PaintApplyArgs& a [[buffer(0)]], device const uint* tiles [[buffer(1)]],
                       uint2 group [[threadgroup_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]]) {
    uint tile = tiles[group.x], across = (a.size + 31u) / 32u;
    uint2 origin = uint2(tile % across, tile / across) * 32u;
    for (uint y = 0; y < 4u; ++y) {
        for (uint x = 0; x < 4u; ++x) {
            uint2 p = origin + lid * 4u + uint2(x, y);
            if (p.x >= a.size || p.y >= a.size) continue;
            float s = stroke.read(p).r;
            float4 b = base.read(p);
            float4 o;
            if (a.erase != 0u) {
                o = b * (1.0f - s);
            } else if (a.colour != 0u) {
                float3 v = a.value.rgb;
                if (a.stencil != 0u) { float4 c = strokeColor.read(p); v = c.a > 0.0f ? c.rgb : v; }
                o = b * (1.0f - s) + float4(v, 1.0f) * s;
            } else {
                o = float4(b.xy * (1.0f - s) + float2(a.value.x, 1.0f) * s, 0.0f, 0.0f);
            }
            target.write(o, p);
        }
    }
}

// MARK: - Composite

// Swift: PaintLayerRecord. One layer as the composite reads it (the table's textures by index, ~0: none).
struct PaintLayerRecord {
    uint4 paint0;            // paint layer: colour, roughness, metallic, height
    uint4 paint1;            // emissive, opacity, the mask's painted part, its generated part
    uint4 graph0;            // fill of a graph: base colour, orm, normal, emissive
    uint4 graph1;            // height, opacity
    uint4 info;              // x = 0 fill, 1 paint; y = channels (PaintChannel bits); z = colour blend; w = height blend
    float4 colour;           // a fill's rgb (linear), w = the layer's opacity
    float4 values;           // roughness, metallic, height, opacity
    float4 emissive;         // rgb (linear), w = the mask's base (where nothing is generated or painted)
    float4 projection;       // x = 0 triplanar, 1 UV; y = tiles per metre (UV: tiles across the set); z = the graph's
                             // normal strength; w = the level its texels are about the set's at
};

struct PaintTexture {
    texture2d<float> t;
};

constexpr sampler paintRepeat(filter::linear, mip_filter::linear, address::repeat);

inline float3 paintFromSRGB(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}
inline float3 paintToSRGB(float3 c) {
    c = saturate(c);
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c * 12.92f, c <= 0.0031308f);
}

// The blend modes (MatBlendMode's order, PaintBlend).
inline float3 paintBlend(float3 a, float3 b, uint mode) {
    switch (mode) {
    case 1u: return a * b;
    case 2u: return 1.0f - (1.0f - a) * (1.0f - b);
    case 3u: return select(1.0f - 2.0f * (1.0f - a) * (1.0f - b), 2.0f * a * b, a < 0.5f);
    case 4u: return a + b;
    case 5u: return max(a - b, 0.0f);
    case 6u: return min(a, b);
    case 7u: return max(a, b);
    case 8u: return (1.0f - 2.0f * b) * a * a + 2.0f * b * a;
    default: return b;
    }
}

// A graph's texture at a texel: at its atlas UV x tiling (UV), or projected along the object's axes, blended by the
// normal (triplanar). `normal`: a tangent-space normal map, brought into the object's space per plane.
inline float4 paintGraphSample(device const PaintTexture* tex, uint t, float3 p, float3 n, float2 uv, float4 proj, bool normal,
                               thread float3& objectNormal) {
    texture2d<float> tx = tex[t].t;
    if (proj.x > 0.5f) {
        float2 at = uv * proj.y;
        float4 v = tx.sample(paintRepeat, at, level(proj.w));
        objectNormal = float3(0.0f);
        return v;
    }
    float3 wts = pow(abs(n), 4.0f);
    wts /= max(wts.x + wts.y + wts.z, 1e-6f);
    float3 q = p * proj.y;
    float4 sx = tx.sample(paintRepeat, float2(q.z * sign(n.x), -q.y), level(proj.w));
    float4 sy = tx.sample(paintRepeat, float2(q.x, q.z * sign(n.y)), level(proj.w));
    float4 sz = tx.sample(paintRepeat, float2(-q.x * sign(n.z), -q.y), level(proj.w));
    if (normal) {
        float3 tx3 = sx.xyz * 2.0f - 1.0f, ty3 = sy.xyz * 2.0f - 1.0f, tz3 = sz.xyz * 2.0f - 1.0f;
        // Each plane's tangent (u), bitangent (v, up the picture: -y for the sides) and normal, in object space.
        float3 nx = float3(0.0f, 0.0f, sign(n.x)) * tx3.x + float3(0.0f, 1.0f, 0.0f) * tx3.y + float3(sign(n.x), 0.0f, 0.0f) * tx3.z;
        float3 ny = float3(1.0f, 0.0f, 0.0f) * ty3.x + float3(0.0f, 0.0f, -sign(n.y)) * ty3.y + float3(0.0f, sign(n.y), 0.0f) * ty3.z;
        float3 nz = float3(-sign(n.z), 0.0f, 0.0f) * tz3.x + float3(0.0f, 1.0f, 0.0f) * tz3.y + float3(0.0f, 0.0f, sign(n.z)) * tz3.z;
        objectNormal = normalize(nx * wts.x + ny * wts.y + nz * wts.z);
    }
    return sx * wts.x + sy * wts.y + sz * wts.z;
}

// A texel's tangent frame in the texture set: its triangle's UV derivatives in object space, against its normal (as
// Surface.metal makes it from the painted corners: +Y = +V).
inline void paintFrame(constant PaintObjectArgs& a, device const uint* indices, device const float3* positions,
                       device const float2* corners, uint tri, float3 n, thread float3& T, thread float3& B) {
    float3 p0 = positions[indices[a.firstIndex + 3u * tri] + a.vertexOffset];
    float3 e1 = positions[indices[a.firstIndex + 3u * tri + 1u] + a.vertexOffset] - p0;
    float3 e2 = positions[indices[a.firstIndex + 3u * tri + 2u] + a.vertexOffset] - p0;
    float2 d1 = corners[3u * tri + 1u] - corners[3u * tri], d2 = corners[3u * tri + 2u] - corners[3u * tri];
    float det = d1.x * d2.y - d1.y * d2.x;
    if (abs(det) < 1e-20f) { T = float3(1, 0, 0); B = float3(0, 1, 0); return; }
    float inv = 1.0f / det;
    T = (e1 * d2.y - e2 * d1.y) * inv;
    B = (e2 * d1.x - e1 * d2.x) * inv;
    T = T - n * dot(n, T);
    B = B - n * dot(n, B) - T * (dot(T, B) / max(dot(T, T), 1e-12f));
    T = length(T) > 0.0f ? normalize(T) : float3(1, 0, 0);
    B = length(B) > 0.0f ? normalize(B) : float3(0, 1, 0);
}

// The layers, bottom first, into the texture set at each texel of the listed tiles: base colour (sRGB), ORM (the
// occlusion bake, roughness, metallic), emissive (sRGB), height, opacity, and the layers' own normals (tangent space,
// before the height's: paintNormal adds that).
kernel void paintComposite(texture2d<uint, access::read> map [[texture(0)]],
                           texture2d<float, access::write> baseOut [[texture(1)]], texture2d<float, access::write> ormOut [[texture(2)]],
                           texture2d<float, access::write> emissiveOut [[texture(3)]], texture2d<float, access::write> heightOut [[texture(4)]],
                           texture2d<float, access::write> opacityOut [[texture(5)]], texture2d<float, access::write> detailOut [[texture(6)]],
                           constant PaintObjectArgs& a [[buffer(0)]], device const PaintLayerRecord* layers [[buffer(1)]],
                           device const PaintTexture* tex [[buffer(2)]], device const uint* indices [[buffer(3)]],
                           device const float3* positions [[buffer(4)]], device const float3* normals [[buffer(5)]],
                           device const float2* corners [[buffer(6)]], device const uint* tiles [[buffer(7)]],
                           uint2 group [[threadgroup_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]]) {
    uint tile = tiles[group.x], across = (a.size + 31u) / 32u;
    uint2 origin = uint2(tile % across, tile / across) * 32u;
    for (uint yy = 0; yy < 4u; ++yy) {
        for (uint xx = 0; xx < 4u; ++xx) {
            uint2 px = origin + lid * 4u + uint2(xx, yy);
            if (px.x >= a.size || px.y >= a.size) continue;
            float3 colour = float3(0.5f), emissive = float3(0.0f);
            float rough = 0.5f, metal = 0.0f, height = 0.5f, opacity = 1.0f, ao = 1.0f;
            float3 detail = float3(0.0f, 0.0f, 1.0f);
            uint tri; float3 bw;
            if (paintTexel(map, px, tri, bw)) {
                tri &= 0x7FFFFFFFu;
                float3 p, n;
                paintPoint(a, indices, positions, normals, tri, bw, p, n);
                float2 uv = (float2(px) + 0.5f) / float(a.size);
                float2 tuv = uv;
                if (a.aoTexture != 0xFFFFFFFFu) ao = tex[a.aoTexture].t.read(px).r;
                float3 T = float3(0.0f), B = float3(0.0f);
                bool frame = false;
                for (uint li = 0; li < a.layerCount; ++li) {
                    PaintLayerRecord L = layers[li];
                    // The mask: its base, or what is generated; what is painted over that.
                    float mask = L.emissive.w;
                    if (L.paint1.w != 0xFFFFFFFFu) mask = tex[L.paint1.w].t.read(px).r;
                    if (L.paint1.z != 0xFFFFFFFFu) { float2 m = tex[L.paint1.z].t.read(px).xy; mask = mask * (1.0f - m.y) + m.x; }
                    float m = saturate(mask) * L.colour.w;
                    if (m <= 0.0f) continue;
                    uint ch = L.info.y;
                    float3 c = L.colour.rgb, e = L.emissive.rgb, ln = float3(0.0f, 0.0f, 1.0f);
                    float r = L.values.x, mt = L.values.y, h = L.values.z, o = L.values.w;
                    float ac = m, ar = m, am = m, ah = m, ae = m, ao2 = m;
                    bool hasNormal = false;
                    if (L.info.x == 1u) {
                        // Paint: each channel what was painted (premultiplied by its coverage).
                        float4 v;
                        if (L.paint0.x != 0xFFFFFFFFu) { v = tex[L.paint0.x].t.read(px); c = v.rgb / max(v.a, 1e-5f); ac *= v.a; } else ac = 0.0f;
                        if (L.paint0.y != 0xFFFFFFFFu) { v = tex[L.paint0.y].t.read(px); r = v.x / max(v.y, 1e-5f); ar *= v.y; } else ar = 0.0f;
                        if (L.paint0.z != 0xFFFFFFFFu) { v = tex[L.paint0.z].t.read(px); mt = v.x / max(v.y, 1e-5f); am *= v.y; } else am = 0.0f;
                        if (L.paint0.w != 0xFFFFFFFFu) { v = tex[L.paint0.w].t.read(px); h = v.x / max(v.y, 1e-5f); ah *= v.y; } else ah = 0.0f;
                        if (L.paint1.x != 0xFFFFFFFFu) { v = tex[L.paint1.x].t.read(px); e = v.rgb / max(v.a, 1e-5f); ae *= v.a; } else ae = 0.0f;
                        if (L.paint1.y != 0xFFFFFFFFu) { v = tex[L.paint1.y].t.read(px); o = v.x / max(v.y, 1e-5f); ao2 *= v.y; } else ao2 = 0.0f;
                    } else if (L.graph0.x != 0xFFFFFFFFu || L.graph0.y != 0xFFFFFFFFu || L.graph1.x != 0xFFFFFFFFu) {
                        // A graph's bake, projected.
                        float3 on = float3(0.0f);
                        if (L.graph0.x != 0xFFFFFFFFu) c = paintFromSRGB(paintGraphSample(tex, L.graph0.x, p, n, tuv, L.projection, false, on).rgb);
                        if (L.graph0.y != 0xFFFFFFFFu) { float4 v = paintGraphSample(tex, L.graph0.y, p, n, tuv, L.projection, false, on); r = v.g; mt = v.b; }
                        if (L.graph0.w != 0xFFFFFFFFu) e = paintFromSRGB(paintGraphSample(tex, L.graph0.w, p, n, tuv, L.projection, false, on).rgb);
                        if (L.graph1.x != 0xFFFFFFFFu) h = paintGraphSample(tex, L.graph1.x, p, n, tuv, L.projection, false, on).r;
                        if (L.graph1.y != 0xFFFFFFFFu) o = paintGraphSample(tex, L.graph1.y, p, n, tuv, L.projection, false, on).r;
                        if (L.graph0.z != 0xFFFFFFFFu && (ch & 8u) != 0u) {
                            float4 v = paintGraphSample(tex, L.graph0.z, p, n, tuv, L.projection, true, on);
                            if (!frame) { paintFrame(a, indices, positions, corners, tri, n, T, B); frame = true; }
                            float3 t3 = L.projection.x > 0.5f ? v.xyz * 2.0f - 1.0f
                                                             : float3(dot(on, T), dot(on, B), dot(on, n));
                            t3.xy *= L.projection.z;
                            ln = normalize(float3(t3.xy, max(t3.z, 1e-3f)));
                            hasNormal = true;
                        }
                    }
                    if ((ch & 1u) != 0u) colour = mix(colour, paintBlend(colour, c, L.info.z), ac);
                    if ((ch & 2u) != 0u) rough = mix(rough, r, ar);
                    if ((ch & 4u) != 0u) metal = mix(metal, mt, am);
                    if ((ch & 8u) != 0u) {
                        if (L.info.w == 1u) height += (h - 0.5f) * ah;
                        else if (L.info.w == 2u) height -= (h - 0.5f) * ah;
                        else height = mix(height, h, ah);
                        if (hasNormal) detail = normalize(mix(detail, ln, ah));
                    }
                    if ((ch & 16u) != 0u) emissive = mix(emissive, e, ae);
                    if ((ch & 32u) != 0u) opacity = mix(opacity, o, ao2);
                }
            }
            baseOut.write(float4(paintToSRGB(colour), 1.0f), px);
            ormOut.write(float4(ao, saturate(rough), saturate(metal), 1.0f), px);
            emissiveOut.write(float4(paintToSRGB(emissive), 1.0f), px);
            heightOut.write(float4(saturate(height)), px);
            opacityOut.write(float4(saturate(opacity)), px);
            detailOut.write(float4(detail * 0.5f + 0.5f, 1.0f), px);
        }
    }
}

// The normal map: the layers' normals with the height's slope added (central differences, in metres a texel:
// heightDepth x 2 a unit of height over 1 / texelsPerMetre), OpenGL (+Y = +V).
kernel void paintNormal(texture2d<float, access::read> height [[texture(0)]], texture2d<float, access::read> detail [[texture(1)]],
                        texture2d<float, access::write> normalOut [[texture(2)]], constant PaintObjectArgs& a [[buffer(0)]],
                        device const uint* tiles [[buffer(1)]],
                        uint2 group [[threadgroup_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]]) {
    uint tile = tiles[group.x], across = (a.size + 31u) / 32u;
    uint2 origin = uint2(tile % across, tile / across) * 32u;
    int last = int(a.size) - 1;
    float k = 2.0f * a.heightDepth * a.texelsPerMetre * 0.5f * a.normalStrength;
    for (uint yy = 0; yy < 4u; ++yy) {
        for (uint xx = 0; xx < 4u; ++xx) {
            uint2 px = origin + lid * 4u + uint2(xx, yy);
            if (px.x >= a.size || px.y >= a.size) continue;
            int2 q = int2(px);
            float hl = height.read(uint2(max(q.x - 1, 0), q.y)).r, hr = height.read(uint2(min(q.x + 1, last), q.y)).r;
            float hu = height.read(uint2(q.x, max(q.y - 1, 0))).r, hd = height.read(uint2(q.x, min(q.y + 1, last))).r;
            float3 hn = normalize(float3(-(hr - hl) * k, -(hd - hu) * k, 1.0f));
            float3 d = detail.read(px).xyz * 2.0f - 1.0f;
            float3 n = normalize(float3(d.xy + hn.xy, d.z * hn.z));
            normalOut.write(float4(n * 0.5f + 0.5f, 1.0f), px);
        }
    }
}

// The object as it was (its materials' textures at its own UVs, or their values) into a paint layer's colour,
// roughness, metallic and emissive (coverage 1), texel by texel, its textures read at `level`. Swift: PaintOriginal, one
// per material of its run.
struct PaintOriginal {
    float4 albedo;           // rgb, a = metallic
    float4 emission;         // rgb, a = roughness
    uint4 textures;          // base colour, metallic-roughness, normal, emissive: the table's (~0 none)
};

kernel void paintBakeOriginal(texture2d<uint, access::read> map [[texture(0)]],
                              texture2d<float, access::write> colourOut [[texture(1)]], texture2d<float, access::write> roughOut [[texture(2)]],
                              texture2d<float, access::write> metalOut [[texture(3)]], texture2d<float, access::write> emissiveOut [[texture(4)]],
                              constant PaintObjectArgs& a [[buffer(0)]], device const PaintOriginal* originals [[buffer(1)]],
                              device const PaintTexture* tex [[buffer(2)]], device const uint* indices [[buffer(3)]],
                              device const float2* uvs [[buffer(4)]], device const uchar* materialOf [[buffer(5)]],
                              uint2 px [[thread_position_in_grid]]) {
    if (px.x >= a.size || px.y >= a.size) return;
    uint tri; float3 bw;
    if (!paintTexel(map, px, tri, bw)) {
        colourOut.write(float4(0.0f), px); roughOut.write(float4(0.0f), px);
        metalOut.write(float4(0.0f), px); emissiveOut.write(float4(0.0f), px);
        return;
    }
    tri &= 0x7FFFFFFFu;
    PaintOriginal o = originals[materialOf[tri]];
    float2 uv = float2(0.0f);
    for (uint k = 0; k < 3u; ++k) uv += bw[k] * uvs[indices[a.firstIndex + 3u * tri + k]];
    float3 c = o.albedo.rgb, e = o.emission.rgb;
    float r = o.emission.a, m = o.albedo.a;
    if (o.textures.x != 0xFFFFFFFFu) c *= tex[o.textures.x].t.sample(paintRepeat, uv, level(a.level)).rgb;
    if (o.textures.y != 0xFFFFFFFFu) { float4 v = tex[o.textures.y].t.sample(paintRepeat, uv, level(a.level)); r *= v.g; m *= v.b; }
    if (o.textures.w != 0xFFFFFFFFu) e *= tex[o.textures.w].t.sample(paintRepeat, uv, level(a.level)).rgb;
    colourOut.write(float4(c, 1.0f), px);
    roughOut.write(float4(r, 1.0f, 0.0f, 0.0f), px);
    metalOut.write(float4(m, 1.0f, 0.0f, 0.0f), px);
    emissiveOut.write(float4(e, 1.0f), px);
}

// A level of the texture set from the one above, where the composite wrote: per threadgroup an 8x8 block of `dst`
// (its `blocks` entry, in blocks), each texel the mean of its four in `src` (as a blit's mipmaps are, but only the
// blocks over the dirty tiles).
kernel void paintDownsample(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                            device const uint2* blocks [[buffer(0)]],
                            uint2 group [[threadgroup_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]]) {
    uint2 p = blocks[group.x] * 8u + lid;
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    uint2 q = p * 2u;
    dst.write(0.25f * (src.read(q) + src.read(q + uint2(1, 0)) + src.read(q + uint2(0, 1)) + src.read(q + uint2(1, 1))), p);
}

// MARK: - Copies

// A texture cleared (a paint layer's channel: no coverage).
kernel void paintClear(texture2d<float, access::write> t [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height()) t.write(float4(0.0f), gid);
}

// Tiles from one texture into another: the threadgroup's `srcTiles` entry of `src` (tiles `c.x` across) into its
// `dstTiles` entry of `dst` (`c.y` across). A stroke's base, its undo, an undo applied.
kernel void paintTileCopy(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          constant uint4& c [[buffer(0)]], device const uint* srcTiles [[buffer(1)]], device const uint* dstTiles [[buffer(2)]],
                          uint2 group [[threadgroup_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]]) {
    uint s = srcTiles[group.x], d = dstTiles[group.x];
    uint2 from = uint2(s % c.y, s / c.y) * 32u, to = uint2(d % c.w, d / c.w) * 32u;
    for (uint y = 0; y < 4u; ++y) {
        for (uint x = 0; x < 4u; ++x) {
            uint2 o = lid * 4u + uint2(x, y);
            uint2 p = from + o, q = to + o;
            if (p.x >= src.get_width() || p.y >= src.get_height() || q.x >= dst.get_width() || q.y >= dst.get_height()) continue;
            dst.write(src.read(p), q);
        }
    }
}

// A whole texture into another of its size (a staging texture's pixels into a private one).
kernel void paintCopy(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < dst.get_width() && gid.y < dst.get_height()) dst.write(src.read(gid), gid);
}

// A texture's texels as floats into a shared buffer (saving, exporting, thumbnails).
kernel void paintReadback(texture2d<float, access::read> src [[texture(0)]], device float4* out [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < src.get_width() && gid.y < src.get_height()) out[gid.y * src.get_width() + gid.x] = src.read(gid);
}

// A texture `side` squared into a shared buffer (4 x 4 taps a texel: the window's pictures of the set, the layers).
kernel void paintThumbnail(texture2d<float> src [[texture(0)]], device float4* out [[buffer(0)]], constant uint& side [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= side || gid.y >= side) return;
    float4 sum = float4(0.0f);
    for (uint y = 0; y < 4u; ++y) {
        for (uint x = 0; x < 4u; ++x) {
            float2 uv = (float2(gid) + (float2(x, y) + 0.5f) / 4.0f) / float(side);
            sum += src.sample(paintLinear, uv, level(0.0f));
        }
    }
    out[gid.y * side + gid.x] = sum / 16.0f;
}
