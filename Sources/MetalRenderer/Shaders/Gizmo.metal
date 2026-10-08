// The VFX editor's gizmos (Renderer.encodeGizmos, VFX/VFXGizmos.swift): line segments in the world drawn over the
// finished frame, a thread a point along one of them, its pixels (`a.w` wide) written in the segment's colour. Not
// depth tested: they show what is behind the effect too, as an editor's handles do.

struct GizmoSegment {
    float4 a;       // xyz, w: the width in pixels
    float4 b;
    float4 color;
};

struct GizmoView {
    float4 position;
    float4 right;
    float4 up;
    float4 forward;
    float2 size;     // the output's, in pixels
    float  tanY;     // tan(fovY / 2)
    float  aspect;
    uint   count;
    uint   samples;  // points a segment
    uint2  pad;
};

kernel void gizmoLinesKernel(constant GizmoView&          v        [[buffer(0)]],
                             device const GizmoSegment*   segments [[buffer(1)]],
                             texture2d<half, access::write> out    [[texture(0)]],
                             uint2                        id       [[thread_position_in_grid]]) {
    if (id.y >= v.count || id.x >= v.samples) return;
    GizmoSegment g = segments[id.y];
    float t = float(id.x) / float(max(v.samples - 1, 1u));
    float3 p = mix(g.a.xyz, g.b.xyz, t) - v.position.xyz;
    float z = dot(p, v.forward.xyz);
    if (z < 0.05f) return;
    float x = dot(p, v.right.xyz) / (z * v.tanY * v.aspect), y = dot(p, v.up.xyz) / (z * v.tanY);
    float2 px = float2((x * 0.5f + 0.5f) * v.size.x, (0.5f - y * 0.5f) * v.size.y);
    int w = max(int(g.a.w), 1), lo = -(w - 1) / 2;
    for (int dy = lo; dy < lo + w; dy++) {
        for (int dx = lo; dx < lo + w; dx++) {
            int2 q = int2(px) + int2(dx, dy);
            if (q.x < 0 || q.y < 0 || q.x >= int(v.size.x) || q.y >= int(v.size.y)) continue;
            out.write(half4(g.color), uint2(q));
        }
    }
}
