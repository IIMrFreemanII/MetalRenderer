// The Material Painter's mesh bakes (Painter/PaintBake.swift) and mask generators: per texel of a painted object's
// texture set, ambient occlusion and thickness (rays against the object alone, Metal RT), curvature (the welded
// vertices' own, and the creases near: convex edges up, concave down), and the generated masks they drive.

#include <metal_raytracing>

// Swift: PaintBakeArgs.
struct PaintBakeArgs {
    uint size;
    uint rays;
    uint seed;
    uint cellsX;
    float maxDistance;       // occlusion's reach (metres)
    float radius;            // a crease's reach (metres)
    float curvatureScale;    // a vertex's curvature x this, before clamping
    uint cellsY;
    float4 gridOrigin;       // xyz, w = a cell's side
    uint cellsZ;
    float thicknessScale;    // metres of thickness that read as 1
    uint pad0, pad1;
};

inline uint paintHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
inline float paintRandom(thread uint& s) { s = paintHash(s); return float(s & 0xFFFFFFu) / 16777216.0f; }

inline float3 paintCosineDirection(float3 n, float u1, float u2) {
    float r = sqrt(u1), phi = 2.0f * M_PI_F * u2;
    float3 t = abs(n.x) < 0.9f ? normalize(cross(float3(1, 0, 0), n)) : normalize(cross(float3(0, 1, 0), n));
    float3 b = cross(n, t);
    return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0f, 1.0f - u1)));
}

// Occlusion (the share of a cosine hemisphere's rays that leave within `maxDistance`) and thickness (how far rays
// into the object go before they leave it, x thicknessScale), each texel.
kernel void paintBakeOcclusion(texture2d<uint, access::read> map [[texture(0)]], texture2d<float, access::write> occlusion [[texture(1)]],
                               texture2d<float, access::write> thickness [[texture(2)]], constant PaintObjectArgs& a [[buffer(0)]],
                               constant PaintBakeArgs& b [[buffer(1)]], device const uint* indices [[buffer(2)]],
                               device const float3* positions [[buffer(3)]], device const float3* normals [[buffer(4)]],
                               metal::raytracing::primitive_acceleration_structure accel [[buffer(5)]],
                               uint2 px [[thread_position_in_grid]]) {
    if (px.x >= b.size || px.y >= b.size) return;
    uint tri; float3 bw;
    if (!paintTexel(map, px, tri, bw)) { occlusion.write(float4(1.0f), px); thickness.write(float4(0.0f), px); return; }
    tri &= 0x7FFFFFFFu;
    float3 p, n;
    paintPoint(a, indices, positions, normals, tri, bw, p, n);
    // The triangle's own normal decides the side (a smooth normal may lean under the surface at a silhouette).
    float3 p0 = positions[indices[a.firstIndex + 3u * tri]], p1 = positions[indices[a.firstIndex + 3u * tri + 1u]],
           p2 = positions[indices[a.firstIndex + 3u * tri + 2u]];
    float3 ng = cross(p1 - p0, p2 - p0);
    ng = length(ng) > 0.0f ? normalize(ng) : n;
    if (dot(ng, n) < 0.0f) ng = -ng;
    float eps = 1e-4f + 1e-3f * b.radius;
    metal::raytracing::intersector<metal::raytracing::triangle_data> hits;
    hits.assume_geometry_type(metal::raytracing::geometry_type::triangle);
    uint seed = paintHash(px.x * 7919u + px.y * 104729u + b.seed);
    float open = 0.0f, through = 0.0f;
    for (uint i = 0; i < b.rays; ++i) {
        float u1 = paintRandom(seed), u2 = paintRandom(seed);
        metal::raytracing::ray r;
        r.origin = p + ng * eps;
        r.direction = paintCosineDirection(n, u1, u2);
        if (dot(r.direction, ng) <= 0.0f) r.direction = reflect(r.direction, ng);
        r.min_distance = 0.0f;
        r.max_distance = b.maxDistance;
        hits.accept_any_intersection(true);
        auto h = hits.intersect(r, accel);
        if (h.type == metal::raytracing::intersection_type::none) open += 1.0f;
        // Into the object: how far to its other side.
        metal::raytracing::ray in;
        in.origin = p - ng * eps;
        in.direction = paintCosineDirection(-n, u1, u2);
        in.min_distance = 0.0f;
        in.max_distance = b.thicknessScale * 4.0f;
        hits.accept_any_intersection(false);
        auto t = hits.intersect(in, accel);
        through += t.type == metal::raytracing::intersection_type::none ? in.max_distance : t.distance;
    }
    occlusion.write(float4(open / float(max(b.rays, 1u))), px);
    thickness.write(float4(saturate(through / float(max(b.rays, 1u)) / b.thicknessScale)), px);
}

// Curvature: 0.5 flat, toward 1 convex, toward 0 concave: the vertices' own (interpolated) and, within `radius` of a
// crease (an edge whose faces meet at an angle: Painter/PaintBake.swift), its sign, falling off with the distance.
kernel void paintBakeCurvature(texture2d<uint, access::read> map [[texture(0)]], texture2d<float, access::write> out [[texture(1)]],
                               constant PaintObjectArgs& a [[buffer(0)]], constant PaintBakeArgs& b [[buffer(1)]],
                               device const uint* indices [[buffer(2)]], device const float3* positions [[buffer(3)]],
                               device const float3* normals [[buffer(4)]], device const float* vertexCurvature [[buffer(5)]],
                               device const float4* segments [[buffer(6)]], device const uint2* cells [[buffer(7)]],
                               device const uint* items [[buffer(8)]], uint2 px [[thread_position_in_grid]]) {
    if (px.x >= b.size || px.y >= b.size) return;
    uint tri; float3 bw;
    if (!paintTexel(map, px, tri, bw)) { out.write(float4(0.5f), px); return; }
    tri &= 0x7FFFFFFFu;
    float3 p, n;
    paintPoint(a, indices, positions, normals, tri, bw, p, n);
    float k = 0.0f;
    for (uint i = 0; i < 3u; ++i) k += bw[i] * vertexCurvature[indices[a.firstIndex + 3u * tri + i]];
    k = clamp(k * b.curvatureScale, -1.0f, 1.0f);
    float convex = 0.0f, concave = 0.0f;
    float cell = b.gridOrigin.w;
    if (cell > 0.0f) {
        int3 c = int3(floor((p - b.gridOrigin.xyz) / cell));
        for (int z = c.z - 1; z <= c.z + 1; ++z) {
            for (int y = c.y - 1; y <= c.y + 1; ++y) {
                for (int x = c.x - 1; x <= c.x + 1; ++x) {
                    if (x < 0 || y < 0 || z < 0 || x >= int(b.cellsX) || y >= int(b.cellsY) || z >= int(b.cellsZ)) continue;
                    uint2 range = cells[(uint(z) * b.cellsY + uint(y)) * b.cellsX + uint(x)];
                    for (uint j = range.x; j < range.x + range.y; ++j) {
                        uint s = items[j];
                        float4 s0 = segments[2u * s], s1 = segments[2u * s + 1u];
                        float3 ab = s1.xyz - s0.xyz;
                        float t = saturate(dot(p - s0.xyz, ab) / max(dot(ab, ab), 1e-12f));
                        float d = distance(p, s0.xyz + ab * t);
                        if (d >= b.radius) continue;
                        float w = (1.0f - d / b.radius) * s1.w;   // s1.w: how sharp the crease is (0...1)
                        if (s0.w > 0.0f) convex = max(convex, w); else concave = max(concave, w);
                    }
                }
            }
        }
    }
    float v = clamp(k + convex - concave, -1.0f, 1.0f);
    out.write(float4(0.5f + 0.5f * v), px);
}

// MARK: - Generators

inline float paintHash3(int3 c, uint seed) {
    uint h = paintHash(uint(c.x) * 0x8da6b343u ^ uint(c.y) * 0xd8163841u ^ uint(c.z) * 0xcb1ab31fu ^ seed);
    return float(h & 0xFFFFu) / 65535.0f;
}
inline float paintNoise3(float3 p, uint seed) {
    int3 i = int3(floor(p));
    float3 f = p - floor(p), u = f * f * (3.0f - 2.0f * f);
    float n000 = paintHash3(i, seed), n100 = paintHash3(i + int3(1, 0, 0), seed);
    float n010 = paintHash3(i + int3(0, 1, 0), seed), n110 = paintHash3(i + int3(1, 1, 0), seed);
    float n001 = paintHash3(i + int3(0, 0, 1), seed), n101 = paintHash3(i + int3(1, 0, 1), seed);
    float n011 = paintHash3(i + int3(0, 1, 1), seed), n111 = paintHash3(i + int3(1, 1, 1), seed);
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y), mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}
inline float paintFbm3(float3 p, uint seed) {
    float v = 0.0f, amp = 0.5f;
    for (int o = 0; o < 5; ++o) { v += amp * paintNoise3(p, seed + uint(o) * 101u); p *= 2.03f; amp *= 0.5f; }
    return v;
}

// Swift: PaintGenerateArgs.
struct PaintGenerateArgs {
    uint kind;               // PaintGenerator.Kind's order
    float amount;
    float contrast;
    float scale;
    uint seed;
    uint invert;
    uint size;
    uint hasGraph;
    float4 boundsLo;
    float4 boundsHi;
};

// A generator's mask, each texel, from the bakes (curvature, occlusion, thickness), the point and its normal (object
// space, the object's bounds), and noise: its amount the share it covers (a threshold), its contrast how hard its
// edge is.
kernel void paintGenerate(texture2d<uint, access::read> map [[texture(0)]], texture2d<float, access::read> curvature [[texture(1)]],
                          texture2d<float, access::read> occlusion [[texture(2)]], texture2d<float, access::read> thickness [[texture(3)]],
                          texture2d<float, access::write> out [[texture(4)]], texture2d<float> graph [[texture(5)]],
                          constant PaintObjectArgs& a [[buffer(0)]], constant PaintGenerateArgs& g [[buffer(1)]],
                          device const uint* indices [[buffer(2)]], device const float3* positions [[buffer(3)]],
                          device const float3* normals [[buffer(4)]], uint2 px [[thread_position_in_grid]]) {
    if (px.x >= g.size || px.y >= g.size) return;
    uint tri; float3 bw;
    if (!paintTexel(map, px, tri, bw)) { out.write(float4(0.0f), px); return; }
    tri &= 0x7FFFFFFFu;
    float3 p, n;
    paintPoint(a, indices, positions, normals, tri, bw, p, n);
    float c = curvature.read(px).r, ao = occlusion.read(px).r, th = thickness.read(px).r;
    float3 q = p * g.scale;
    // The noise spread over 0...1 (fbm keeps to about 0.25...0.75), so that `amount` is about the share covered.
    float noise = saturate((paintFbm3(q, g.seed) - 0.25f) * 2.0f);
    float h = saturate((p.y - g.boundsLo.y) / max(g.boundsHi.y - g.boundsLo.y, 1e-6f));
    float v;
    switch (g.kind) {
    case 0u: {   // edge wear: convex edges, broken by noise
        float edge = saturate((c - 0.5f) * 2.5f);
        v = edge * (0.5f + 0.7f * noise) + 0.1f * (noise - 0.5f);
        break;
    }
    case 1u: {   // dirt in cavities: concave and occluded, blotchy
        float cav = max(saturate((0.5f - c) * 2.0f), 1.0f - ao);
        v = cav * (0.5f + noise) + 0.1f * (noise - 0.5f);
        break;
    }
    case 2u: {   // dust on top: facing up, out of the open
        v = saturate(n.y) * mix(0.6f, 1.0f, ao) * (0.6f + 0.8f * noise);
        break;
    }
    case 3u: {   // rust and leaks: cavities, and streaks running down from them
        float streak = saturate((paintFbm3(float3(p.x * g.scale * 2.0f, p.y * g.scale * 0.2f, p.z * g.scale * 2.0f), g.seed + 17u) - 0.25f) * 2.0f);
        float cav = max(saturate((0.5f - c) * 2.0f), 1.0f - ao);
        v = max(cav * (0.4f + noise), streak * (0.3f + 0.7f * (1.0f - h)) * (0.6f + 0.4f * noise));
        break;
    }
    case 4u: v = c; break;
    case 5u: v = 1.0f - ao; break;
    case 6u: v = th; break;
    case 7u: v = h; break;
    default: {
        float2 uv = (float2(px) + 0.5f) / float(g.size);
        float4 s = g.hasGraph != 0u ? graph.sample(paintLinear, uv, level(0.0f)) : float4(0.5f);
        v = dot(s.rgb, float3(0.2126f, 0.7152f, 0.0722f));
        break;
    }
    }
    // The amount: how much passes (a threshold), the contrast: how hard the edge.
    float t = 1.0f - g.amount, w = mix(0.35f, 0.01f, g.contrast);
    float m = smoothstep(t - w, t + w, v);
    if (g.invert != 0u) m = 1.0f - m;
    out.write(float4(m), px);
}

// The object's point (within its bounds, 0...1 each way) and normal (x 0.5 + 0.5), each texel: the graph masks'
// Position and Normal maps.
kernel void paintBakeMaps(texture2d<uint, access::read> map [[texture(0)]], texture2d<float, access::write> position [[texture(1)]],
                          texture2d<float, access::write> normal [[texture(2)]], constant PaintObjectArgs& a [[buffer(0)]],
                          constant PaintGenerateArgs& g [[buffer(1)]], device const uint* indices [[buffer(2)]],
                          device const float3* positions [[buffer(3)]], device const float3* normals [[buffer(4)]],
                          uint2 px [[thread_position_in_grid]]) {
    if (px.x >= g.size || px.y >= g.size) return;
    uint tri; float3 bw;
    if (!paintTexel(map, px, tri, bw)) { position.write(float4(0.0f), px); normal.write(float4(0.5f, 0.5f, 1.0f, 1.0f), px); return; }
    float3 p, n;
    paintPoint(a, indices, positions, normals, tri & 0x7FFFFFFFu, bw, p, n);
    position.write(float4(saturate((p - g.boundsLo.xyz) / max(g.boundsHi.xyz - g.boundsLo.xyz, float3(1e-6f))), 1.0f), px);
    normal.write(float4(n * 0.5f + 0.5f, 1.0f), px);
}
