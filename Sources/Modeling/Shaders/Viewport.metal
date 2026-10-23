// The modelling window's viewport: a small forward rasteriser of its own (the path tracer is the Rendered view's).
// Reverse Z (near 1, far 0), 4× MSAA for the colour pass. Structs match Viewport/ViewportGPUTypes.swift byte for byte.
#include <metal_stdlib>
using namespace metal;

struct ViewUniforms {
    float4x4 viewProj;
    float4x4 view;
    float4x4 invViewProj;
    float4 eye;            // xyz; w: 1 orthographic
    float4 viewDir;        // xyz toward what the camera looks at; w: grid plane (0 floor, 1 x, 2 y, 3 z)
    float2 viewport;       // pixels
    float pixelScale;      // backing pixels per point
    float gridScale;       // metres between the grid's finest lines that show
    float4 background;     // linear
    uint4 flags;           // x: show grid, y: show axes, z: x-ray, w: -
};

struct ViewVertex {        // 24 bytes
    packed_float3 position;
    uint normal;           // octahedral, two snorm16
    float mask;
    uint faceSet;          // RGBA8 colour of its face set (0: none)
};

struct ObjectUniforms {
    float4x4 model;
    float4x4 normalMatrix;
    float4 color;          // linear; a: alpha (x-ray)
    float4 wire;           // linear: the object's wire colour in wireframe / wire overlay
    uint shading;          // 0 solid, 1 matcap, 2 flat colour (ids), 3 wire only
    uint flags;            // 1 selected, 2 active, 4 edit, 8 sculpt (mask, face sets), 16 material colours, 32 backface cull, 64 face orientation, 128 wire overlay
    uint matcap;
    uint objectID;
};

struct EditEdge { uint a; uint b; uint flags; uint pad; };   // flags: 1 select, 2 hide, 4 seam, 8 sharp, 16 crease, 32 active

struct OverlayLine {       // a 3D segment
    float4 a;              // xyz; w: width in points
    float4 b;              // xyz; w: 1 dashed
    float4 color;          // linear, alpha
};

/// Overlays drawn over the faces they lie on: nudged toward the camera by a share of their depth (`k` of 0.2% in
/// perspective; in orthographic `background.w` says what that share of the view's distance is in depth).
inline float biasedZ(float4 c, float k, constant ViewUniforms& u) {
    if (u.flags.z != 0) return c.z + 0.9 * c.w;            // x-ray: over everything
    if (u.eye.w > 0.5) return c.z + u.background.w * k * c.w;
    return c.z * (1.0 + 0.002 * k);
}

inline float3 octDecode(uint packed) {
    float2 e = float2(as_type<short2>(packed)) / 32767.0;
    float3 n = float3(e, 1.0 - abs(e.x) - abs(e.y));
    if (n.z < 0) n.xy = (1.0 - abs(n.yx)) * select(float2(-1), float2(1), n.xy >= 0);
    return normalize(n);
}

inline float3 unpackColor(uint c) {
    return float3(c & 255u, (c >> 8) & 255u, (c >> 16) & 255u) / 255.0;
}

// MARK: - Background and grid

struct FullOut { float4 position [[position]]; float2 ndc; };

vertex FullOut fullscreenVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    FullOut o;
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    o.ndc = p * 2.0 - 1.0;
    return o;
}

struct GridOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };

/// How much of a grid line of spacing `s` covers the pixel.
inline float gridLine(float2 uv, float2 deriv, float s) {
    float2 g = abs(fract(uv / s - 0.5) - 0.5) / max(deriv / s, 1e-9);
    return 1.0 - saturate(min(g.x, g.y));
}

/// Blender's floor grid: lines every unit and at each power of ten that suits the zoom, fading away; the X axis red and
/// Blender's Y (our −Z) green. Orthographic side views put the grid in the view's own plane.
fragment GridOut gridFragment(FullOut in [[stage_in]], constant ViewUniforms& u [[buffer(0)]]) {
    float4 nearH = u.invViewProj * float4(in.ndc, 1, 1);
    float4 farH = u.invViewProj * float4(in.ndc, 1e-6, 1);
    float3 p0 = nearH.xyz / nearH.w, p1 = farH.xyz / farH.w;
    float3 dir = p1 - p0;
    int plane = int(u.viewDir.w);
    float3 n = plane == 1 ? float3(1, 0, 0) : plane == 3 ? float3(0, 0, 1) : float3(0, 1, 0);
    float denom = dot(dir, n);
    GridOut o;
    o.color = float4(0);
    o.depth = 0;
    if (abs(denom) < 1e-9) { discard_fragment(); return o; }
    float t = -dot(p0, n) / denom;
    if (t < 0) { discard_fragment(); return o; }
    float3 hit = p0 + dir * t;
    float2 uv = plane == 1 ? hit.zy : plane == 3 ? hit.xy : hit.xz;
    // Two levels of lines: the finest that is at least a few pixels apart, and ten times it.
    float4 clip = u.viewProj * float4(hit, 1);
    o.depth = clip.z / clip.w;
    float2 deriv = fwidth(uv);
    float pixel = max(deriv.x, deriv.y);
    float scale = u.gridScale;
    float level = max(0.0, ceil(log10(pixel * 8.0 / scale)));
    float s0 = scale * pow(10.0, level), s1 = s0 * 10.0;
    float fade0 = saturate(1.0 - (pixel * 8.0 / s0 - 0.1) * 1.2);
    float a = u.flags.x != 0 ? max(gridLine(uv, deriv, s0) * fade0 * 0.55, gridLine(uv, deriv, s1) * 0.85) : 0.0;
    float3 color = float3(0.11);   // Blender's #545454 grid, linear
    // Axes: a line along X (red) where the other coordinate is 0, and along the other axis (green, or blue on a wall).
    if (u.flags.y != 0) {
        float2 axis = abs(uv) / max(deriv, 1e-6);
        if (plane != 1 && axis.y < 1.5) { color = float3(1.0, 0.033, 0.084); a = max(a, 1.0 - saturate(axis.y - 0.5)); }
        if (plane != 3 && axis.x < 1.5 && plane != 0) { color = float3(0.021, 0.279, 1.0); a = max(a, 1.0 - saturate(axis.x - 0.5)); }
        if (plane == 0 && axis.x < 1.5) { color = float3(0.258, 0.716, 0.0); a = max(a, 1.0 - saturate(axis.x - 0.5)); }
    }
    // Fade with distance (perspective) so the floor ends softly.
    float dist = length(hit - u.eye.xyz);
    float far = u.eye.w > 0.5 ? 1e9 : max(50.0, s1 * 40.0);
    a *= saturate(1.0 - dist / far);
    // Grazing angles alias: fade them.
    a *= saturate(abs(dot(normalize(dir), n)) * 8.0);
    if (a < 0.004) { discard_fragment(); return o; }
    o.color = float4(color * a, a);
    return o;
}

// MARK: - Meshes

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;         // world
    float3 viewNormal;
    float mask;
    float3 faceSetColor;
    float hasFaceSet;
};

vertex MeshOut meshVertex(uint vid [[vertex_id]], const device ViewVertex* vs [[buffer(0)]],
                          constant ViewUniforms& u [[buffer(1)]], constant ObjectUniforms& o [[buffer(2)]]) {
    ViewVertex v = vs[vid];
    float4 world = o.model * float4(float3(v.position), 1);
    MeshOut out;
    out.position = u.viewProj * world;
    out.world = world.xyz;
    float3 n = octDecode(v.normal);
    out.normal = normalize((o.normalMatrix * float4(n, 0)).xyz);
    out.viewNormal = normalize((u.view * float4(out.normal, 0)).xyz);
    out.mask = v.mask;
    out.faceSetColor = unpackColor(v.faceSet);
    out.hasFaceSet = v.faceSet != 0 ? 1.0 : 0.0;
    return out;
}

/// Studio light as Blender's default solid shading roughly is: a key from above left, a soft fill, a rim, a little
/// specular; in view space, so it turns with the camera.
inline float3 studio(float3 n, float3 albedo) {
    float3 key = normalize(float3(-0.5, 0.75, 0.55)), fill = normalize(float3(0.7, 0.1, 0.7)), rim = normalize(float3(0.2, -0.8, -0.3));
    float k = saturate(dot(n, key)) * 0.75, f = saturate(dot(n, fill)) * 0.3, r = saturate(dot(n, rim)) * 0.15;
    float ambient = 0.18 + 0.12 * n.y;
    float3 h = normalize(key + float3(0, 0, 1));
    float spec = pow(saturate(dot(n, h)), 40.0) * 0.12;
    return albedo * (ambient + k + f + r) + spec;
}

fragment float4 meshFragment(MeshOut in [[stage_in]], bool front [[front_facing]], uint prim [[primitive_id]],
                             constant ViewUniforms& u [[buffer(0)]], constant ObjectUniforms& o [[buffer(1)]],
                             const device uchar* faceFlags [[buffer(2)]], const device uint* triangleFace [[buffer(3)]],
                             const device ushort* triangleMaterial [[buffer(4)]], const device float4* materialColors [[buffer(5)]],
                             texture2d_array<float> matcaps [[texture(0)]]) {
    if ((o.flags & 32u) && !front) discard_fragment();
    float3 n = normalize(in.viewNormal);
    float3 nw = normalize(in.normal);
    if (!front) { n = -n; nw = -nw; }
    float3 albedo = o.color.rgb;
    if (o.flags & 16u) albedo = materialColors[triangleMaterial[prim]].rgb;
    float3 color;
    if (o.shading == 1) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        color = matcaps.sample(s, n.xy * float2(0.5, -0.5) + 0.5, o.matcap).rgb;
        if (o.flags & 16u) color *= albedo / 0.8;
    } else if (o.shading == 2) {
        color = albedo;
    } else {
        color = studio(n, albedo);
    }
    if (o.flags & 64u) color = front ? float3(0.1, 0.25, 0.85) * (0.4 + 0.6 * n.z) : float3(0.85, 0.12, 0.1) * (0.4 + 0.6 * n.z);
    if (o.flags & 8u) {
        if (in.hasFaceSet > 0.5) color *= mix(float3(1), in.faceSetColor, 0.65);
        color *= 1.0 - saturate(in.mask) * 0.7;
    }
    if (o.flags & 4u) {
        uint face = triangleFace[prim];
        uchar ff = faceFlags[face];
        if (ff & 1u) color = mix(color, float3(1.0, 0.45, 0.0), 0.28);   // selected
        if (ff & 32u) color = mix(color, float3(1.0, 1.0, 1.0), 0.15);   // active
    }
    return float4(color * o.color.a, o.color.a);
}

/// Object ids (object + 1) and, in edit mode, the face under each pixel: what picking and the selection outline read.
struct IDOut { uint id [[color(0)]]; };

fragment IDOut objectIDFragment(MeshOut in [[stage_in]], constant ObjectUniforms& o [[buffer(1)]]) {
    IDOut out;
    out.id = o.objectID + 1;
    return out;
}

fragment IDOut faceIDFragment(MeshOut in [[stage_in]], uint prim [[primitive_id]], const device uint* triangleFace [[buffer(3)]]) {
    IDOut out;
    out.id = (1u << 28) | (triangleFace[prim] + 1);
    return out;
}

/// The outline of selected objects (dark orange; the active one light orange), where their ids meet another's.
fragment float4 outlineFragment(FullOut in [[stage_in]], texture2d<uint> ids [[texture(0)]], const device uchar* selected [[buffer(0)]],
                                constant ViewUniforms& u [[buffer(1)]]) {
    uint2 p = uint2(in.position.xy);
    uint2 size = uint2(ids.get_width(), ids.get_height());
    uint c = ids.read(min(p, size - 1)).r;
    int r = max(1, int(round(u.pixelScale)));
    uint best = 0;
    for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
            int2 q = clamp(int2(p) + int2(dx, dy), int2(0), int2(size) - 1);
            uint id = ids.read(uint2(q)).r;
            if (id == c) continue;
            uint inner = c != 0 ? selected[c - 1] : 0;
            uint outer = id != 0 ? selected[id - 1] : 0;
            best = max(best, max(inner, outer));
        }
    }
    if (best == 0) discard_fragment();
    float3 color = best >= 2 ? float3(1.0, 0.6, 0.15) : float3(0.88, 0.25, 0.0);
    return float4(color, 1);
}

// MARK: - Edit overlays

struct LineOut {
    float4 position [[position]];
    float4 color;
    float across;          // −1…1 across the line
    float halfWidth;       // pixels
    float along;           // pixels from its start, for dashes
    float dashed;
    uint id [[flat]];      // picking
};

/// A segment as a quad of `width` pixels round it, nudged toward the camera so it shows on the faces it lies on.
inline LineOut lineCorner(float3 a, float3 b, float width, float4 color, uint corner, constant ViewUniforms& u, float k) {
    float4 ca = u.viewProj * float4(a, 1), cb = u.viewProj * float4(b, 1);
    // Clip against the near plane (w small): pull the point in front.
    const float nearW = 1e-4;
    if (ca.w < nearW && cb.w < nearW) { LineOut o; o.position = float4(0, 0, -2, 1); o.color = 0; o.across = 0; o.halfWidth = 0; o.along = 0; o.dashed = 0; o.id = 0; return o; }
    if (ca.w < nearW) ca = mix(ca, cb, (nearW - ca.w) / (cb.w - ca.w));
    if (cb.w < nearW) cb = mix(cb, ca, (nearW - cb.w) / (ca.w - cb.w));
    float2 sa = ca.xy / ca.w * u.viewport * 0.5, sb = cb.xy / cb.w * u.viewport * 0.5;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-6 ? d / len : float2(1, 0);
    float2 side = float2(-dir.y, dir.x);
    float hw = width * 0.5 + 1.0;   // a pixel more for the smooth edge
    bool atB = corner == 1 || corner == 3;
    float s = (corner >= 2) ? 1.0 : -1.0;
    float4 c = atB ? cb : ca;
    float2 screen = (atB ? sb : sa) + side * s * hw + dir * (atB ? 1.0 : -1.0) * 1.0;
    LineOut o;
    o.position = float4(screen / (u.viewport * 0.5) * c.w, c.z, c.w);
    o.position.z = biasedZ(c, k, u);
    o.color = color;
    o.across = s;
    o.halfWidth = hw;
    o.along = atB ? len : 0;
    o.dashed = 0;
    o.id = 0;
    return o;
}

vertex LineOut editEdgeVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device EditEdge* edges [[buffer(0)]],
                              const device packed_float3* positions [[buffer(1)]], constant ViewUniforms& u [[buffer(2)]],
                              constant ObjectUniforms& o [[buffer(3)]], constant float4* theme [[buffer(4)]]) {
    EditEdge e = edges[iid];
    float3 a = (o.model * float4(float3(positions[e.a]), 1)).xyz, b = (o.model * float4(float3(positions[e.b]), 1)).xyz;
    // theme: 0 wire, 1 selected, 2 seam, 3 sharp, 4 crease, 5 active, 6 object wire (object mode / wireframe)
    float4 color = (o.flags & 4u) ? theme[0] : o.wire;
    float width = 1.0;
    if (o.flags & 4u) {
        if (e.flags & 4u) { color = theme[2]; width = 2.0; }
        else if (e.flags & 8u) { color = theme[3]; width = 2.0; }
        else if (e.flags & 16u) { color = theme[4]; width = 2.0; }
        if (e.flags & 1u) color = (e.flags & 32u) ? theme[5] : theme[1];
    }
    if (e.flags & 2u) { LineOut x; x.position = float4(0, 0, -2, 1); x.color = 0; x.across = 0; x.halfWidth = 0; x.along = 0; x.dashed = 0; x.id = 0; return x; }
    return lineCorner(a, b, width * u.pixelScale, color, vid, u, 1.0);
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    float d = abs(in.across) * in.halfWidth;
    float a = saturate(in.halfWidth - d) * in.color.a;
    if (in.dashed > 0.5 && fmod(in.along, 8.0) > 4.0) a = 0;
    if (a <= 0.003) discard_fragment();
    return float4(in.color.rgb * a, a);
}

struct PointOut {
    float4 position [[position]];
    float4 color;
    float2 local;          // −1…1
    float radius;          // pixels
    uint id [[flat]];      // picking
};

/// A point of `size` pixels: vertices (`kind` 0) or face dots (1).
vertex PointOut editPointVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device packed_float3* positions [[buffer(0)]],
                                const device uchar* flags [[buffer(1)]], constant ViewUniforms& u [[buffer(2)]],
                                constant ObjectUniforms& o [[buffer(3)]], constant float4* theme [[buffer(4)]],
                                constant float& size [[buffer(5)]]) {
    uchar f = flags[iid];
    PointOut out;
    out.id = 0;
    if (f & 2u) { out.position = float4(0, 0, -2, 1); out.color = 0; out.local = 0; out.radius = 0; return out; }
    float4 c = u.viewProj * (o.model * float4(float3(positions[iid]), 1));
    float2 corner = float2(vid & 1 ? 1 : -1, vid & 2 ? 1 : -1);
    float r = size * u.pixelScale * 0.5 + 1.0;
    out.position = c;
    out.position.xy += corner * r / (u.viewport * 0.5) * c.w;
    out.position.z = biasedZ(c, 1.5, u);
    out.color = (f & 1u) ? ((f & 32u) ? theme[5] : theme[1]) : theme[0];
    out.local = corner;
    out.radius = r;
    return out;
}

fragment float4 pointFragment(PointOut in [[stage_in]]) {
    float d = length(in.local) * in.radius;
    float a = saturate(in.radius - 1.0 - d + 0.5) * in.color.a;
    if (a <= 0.003) discard_fragment();
    return float4(in.color.rgb * a, a);
}

// MARK: - Overlay lines (constraint axes, the brush, the knife, the 3D cursor)

vertex LineOut overlayLineVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device OverlayLine* lines [[buffer(0)]],
                                 constant ViewUniforms& u [[buffer(1)]]) {
    OverlayLine l = lines[iid];
    LineOut o = lineCorner(l.a.xyz, l.b.xyz, l.a.w * u.pixelScale, l.color, vid, u, 1.0);
    o.dashed = l.b.w;
    return o;
}

// MARK: - Picking: edges and vertices as ids

vertex LineOut edgeIDVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device EditEdge* edges [[buffer(0)]],
                            const device packed_float3* positions [[buffer(1)]], constant ViewUniforms& u [[buffer(2)]],
                            constant ObjectUniforms& o [[buffer(3)]]) {
    EditEdge e = edges[iid];
    float3 a = (o.model * float4(float3(positions[e.a]), 1)).xyz, b = (o.model * float4(float3(positions[e.b]), 1)).xyz;
    LineOut out = lineCorner(a, b, 3.0, float4(1), vid, u, 1.5);
    out.id = (2u << 28) | (iid + 1);
    if (e.flags & 2u) out.position = float4(0, 0, -2, 1);
    return out;
}

fragment IDOut lineIDFragment(LineOut in [[stage_in]]) {
    if (abs(in.across) * in.halfWidth > in.halfWidth - 0.5) discard_fragment();
    IDOut o;
    o.id = in.id;
    return o;
}

vertex PointOut pointIDVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device packed_float3* positions [[buffer(0)]],
                              const device uchar* flags [[buffer(1)]], constant ViewUniforms& u [[buffer(2)]],
                              constant ObjectUniforms& o [[buffer(3)]], constant uint& kind [[buffer(5)]]) {
    PointOut out;
    out.id = (kind << 28) | (iid + 1);
    if (flags[iid] & 2u) { out.position = float4(0, 0, -2, 1); out.color = 0; out.local = 0; out.radius = 0; return out; }
    float4 c = u.viewProj * (o.model * float4(float3(positions[iid]), 1));
    float2 corner = float2(vid & 1 ? 1 : -1, vid & 2 ? 1 : -1);
    float r = 3.0;
    out.position = c;
    out.position.xy += corner * r / (u.viewport * 0.5) * c.w;
    out.position.z = biasedZ(c, 2.0, u);
    out.color = float4(1);
    out.local = corner;
    out.radius = r;
    return out;
}

fragment IDOut pointIDFragment(PointOut in [[stage_in]]) {
    if (length(in.local) > 1.0) discard_fragment();
    IDOut o;
    o.id = in.id;
    return o;
}
