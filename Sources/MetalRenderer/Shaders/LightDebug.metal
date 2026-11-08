// ---------------------------------------------------------------------------------------------
// 2g. The light bounds view (VIEW_LIGHT_BOUNDS, RenderSettings.viewModes): each light's shape and where its light ends,
//     drawn as lines over the frame. Only while the view is shown: lightBoundsClearKernel empties the debug texture,
//     then lightBoundsKernel, one thread a light, draws its lines into it (rgb, a = opacity; behind a surface they are
//     faint). The composite lays them over the lit frame. The other light views (tiles, picked light) are written by
//     the sampling kernels themselves (FLAG_LIGHT_DEBUG).
//       sphere  yellow: its three great circles, and its reach (megaLightReach) as a circle facing the camera
//       spot    orange: its sphere, the outer cone's edges and ring at its reach, the inner ring fainter
//       rect    cyan: its outline, and a tick along the side it lights
//       tube    green: its capsule's outline, facing the camera
//       mesh    grey: its bounding sphere
//     The suns, which reach everywhere, have none.
// ---------------------------------------------------------------------------------------------

struct LightBoundsParams {
    float4 tuning;   // x = the reach's cutoff (MegaLights' unshadowed light where a light ends), y = lines behind surfaces' opacity
};

kernel void lightBoundsClearKernel(constant Uniforms&               u       [[buffer(0)]],
                                   texture2d<float, access::write>  overlay [[texture(0)]],
                                   uint2 tid [[thread_position_in_grid]])
{
    if (tid.x >= u.width || tid.y >= u.height) return;
    overlay.write(float4(0.0f), tid);
}

// Where `p` lands on the screen (pixels, as primaryDirection's inverse) and its view depth; false behind the camera.
inline bool lightDebugProject(constant Uniforms& u, float3 p, thread float2& px, thread float& z) {
    float3 d = p - u.camPos.xyz;
    z = dot(d, u.camForward.xyz);
    if (z <= 1e-3f) return false;
    float x = dot(d, u.camRight.xyz) / (z * u.camRight.w), y = dot(d, u.camUp.xyz) / (z * u.camUp.w);
    px = float2(0.5f * (x + 1.0f), 0.5f * (1.0f - y)) * float2(u.width, u.height) - 0.5f - u.jitter.xy;
    return true;
}

// The segment a-b (world space), cut at the near plane, one write a pixel along it. Behind the G-buffer's surface it is
// `behind` as opaque.
inline void lightDebugSegment(constant Uniforms& u, texture2d<float, access::read> nd, texture2d<float, access::write> overlay,
                              float3 a, float3 b, float3 color, float behind) {
    const float nearZ = 0.05f;
    float za = dot(a - u.camPos.xyz, u.camForward.xyz), zb = dot(b - u.camPos.xyz, u.camForward.xyz);
    if (za < nearZ && zb < nearZ) return;
    if (za < nearZ) a = mix(a, b, (nearZ - za) / (zb - za));
    else if (zb < nearZ) b = mix(b, a, (nearZ - zb) / (za - zb));
    float2 pa, pb;
    float z;
    if (!lightDebugProject(u, a, pa, z) || !lightDebugProject(u, b, pb, z)) return;
    float2 lo = min(pa, pb), hi = max(pa, pb);
    if (hi.x < 0.0f || hi.y < 0.0f || lo.x >= float(u.width) || lo.y >= float(u.height)) return;
    uint steps = uint(clamp(2.0f * max(abs(pb.x - pa.x), abs(pb.y - pa.y)), 1.0f, 4096.0f));
    for (uint i = 0; i <= steps; ++i) {
        float3 p = mix(a, b, float(i) / float(steps));
        float2 px;
        if (!lightDebugProject(u, p, px, z)) continue;
        int2 q = int2(round(px));
        if (q.x < 0 || q.y < 0 || q.x >= int(u.width) || q.y >= int(u.height)) continue;
        float depth = nd.read(uint2(q)).w;
        bool hidden = depth > 0.0f && z > depth * 1.002f + 0.01f;
        overlay.write(float4(color, hidden ? behind : 1.0f), uint2(q));
    }
}

// A circle about `c` of radius `r` in the plane through c spanned by `x` and `y` (unit, at right angles).
inline void lightDebugCircle(constant Uniforms& u, texture2d<float, access::read> nd, texture2d<float, access::write> overlay,
                             float3 c, float3 x, float3 y, float r, float3 color, float behind) {
    const uint segments = 32;
    float3 prev = c + r * x;
    for (uint k = 1; k <= segments; ++k) {
        float a = 2.0f * M_PI_F * float(k) / float(segments);
        float3 p = c + r * (cos(a) * x + sin(a) * y);
        lightDebugSegment(u, nd, overlay, prev, p, color, behind);
        prev = p;
    }
}

// Two unit vectors at right angles to `n` (and to each other).
inline void lightDebugBasis(float3 n, thread float3& x, thread float3& y) {
    x = normalize(abs(n.y) < 0.99f ? cross(n, float3(0.0f, 1.0f, 0.0f)) : cross(n, float3(1.0f, 0.0f, 0.0f)));
    y = cross(n, x);
}

// The circle of the sphere (c, r) that the camera sees as its outline; none from inside it.
inline void lightDebugOutline(constant Uniforms& u, texture2d<float, access::read> nd, texture2d<float, access::write> overlay,
                              float3 c, float r, float3 color, float behind) {
    float3 v = c - u.camPos.xyz;
    float d = length(v);
    if (d <= r || r <= 0.0f) return;
    float3 x, y;
    lightDebugBasis(v / d, x, y);
    lightDebugCircle(u, nd, overlay, c, x, y, r, color, behind);
}

kernel void lightBoundsKernel(constant Uniforms&               u        [[buffer(0)]],
                              device const Light*              lights   [[buffer(8)]],
                              constant LightBoundsParams&      bp       [[buffer(9)]],
                              texture2d<float, access::read>   nd       [[texture(0)]],
                              texture2d<float, access::write>  overlay  [[texture(1)]],
                              uint id [[thread_position_in_grid]])
{
    if (id >= u.lightCount) return;
    Light light = lights[id];
    uint type = lightType(light);
    if (type == LIGHT_SUN) return;
    float behind = bp.tuning.y;
    float3 c = light.positionRadius.xyz;
    float r = light.positionRadius.w;
    float3 reachCenter;
    float reach = 0.0f;
    bool reaches = megaLightReach(light, bp.tuning.x, reachCenter, reach);
    switch (type) {
        case LIGHT_SPHERE: {
            const float3 yellow = float3(1.0f, 0.85f, 0.1f);
            lightDebugCircle(u, nd, overlay, c, float3(1, 0, 0), float3(0, 1, 0), r, yellow, behind);
            lightDebugCircle(u, nd, overlay, c, float3(0, 1, 0), float3(0, 0, 1), r, yellow, behind);
            lightDebugCircle(u, nd, overlay, c, float3(1, 0, 0), float3(0, 0, 1), r, yellow, behind);
            if (reaches) lightDebugOutline(u, nd, overlay, reachCenter, reach, yellow * 0.55f, behind);
            break;
        }
        case LIGHT_SPOT: {
            const float3 orange = float3(1.0f, 0.45f, 0.05f);
            lightDebugOutline(u, nd, overlay, c, r, orange, behind);
            float3 n = normalize(light.axis.xyz), x, y;
            lightDebugBasis(n, x, y);
            float len = reaches ? reach : 1.0f;
            float cosOuter = clamp(light.params.x, -0.999f, 0.999f), cosInner = clamp(light.params.y, -0.999f, 0.999f);
            float sinOuter = sqrt(1.0f - cosOuter * cosOuter), sinInner = sqrt(1.0f - cosInner * cosInner);
            // The cones' rings where the reach ends (on its sphere: along the axis by cos, out by sin).
            lightDebugCircle(u, nd, overlay, c + n * len * cosOuter, x, y, len * sinOuter, orange, behind);
            lightDebugCircle(u, nd, overlay, c + n * len * cosInner, x, y, len * sinInner, orange * 0.5f, behind);
            for (uint k = 0; k < 4; ++k) {
                float a = 0.5f * M_PI_F * float(k);
                lightDebugSegment(u, nd, overlay, c, c + len * (n * cosOuter + sinOuter * (cos(a) * x + sin(a) * y)), orange, behind);
            }
            break;
        }
        case LIGHT_RECT: {
            const float3 cyan = float3(0.1f, 0.9f, 1.0f);
            float3 n = normalize(light.axis.xyz);
            float3 hw = light.params.xyz;
            float3 hh = normalize(cross(n, hw)) * light.params.w;
            float3 p0 = c - hw - hh, p1 = c + hw - hh, p2 = c + hw + hh, p3 = c - hw + hh;
            lightDebugSegment(u, nd, overlay, p0, p1, cyan, behind);
            lightDebugSegment(u, nd, overlay, p1, p2, cyan, behind);
            lightDebugSegment(u, nd, overlay, p2, p3, cyan, behind);
            lightDebugSegment(u, nd, overlay, p3, p0, cyan, behind);
            lightDebugSegment(u, nd, overlay, p0, p2, cyan * 0.4f, behind);
            float tick = max(0.5f * min(length(hw), light.params.w), 0.05f);
            lightDebugSegment(u, nd, overlay, c, c + n * tick, float3(1.0f), behind);   // the side it lights
            if (reaches) lightDebugOutline(u, nd, overlay, reachCenter, reach, cyan * 0.55f, behind);
            break;
        }
        case LIGHT_TUBE: {
            const float3 green = float3(0.2f, 1.0f, 0.3f);
            float3 halfAxis = light.axis.xyz;
            float3 a = c - halfAxis, b = c + halfAxis;
            // The capsule's sides as the camera sees them: offset across the axis and the view.
            float3 side = cross(normalize(halfAxis + float3(1e-6f)), normalize(c - u.camPos.xyz));
            side = length(side) > 1e-4f ? normalize(side) * r : float3(0.0f);
            lightDebugSegment(u, nd, overlay, a + side, b + side, green, behind);
            lightDebugSegment(u, nd, overlay, a - side, b - side, green, behind);
            lightDebugOutline(u, nd, overlay, a, r, green, behind);
            lightDebugOutline(u, nd, overlay, b, r, green, behind);
            if (reaches) lightDebugOutline(u, nd, overlay, reachCenter, reach, green * 0.55f, behind);
            break;
        }
        default: {   // an emissive mesh: its bounding sphere
            lightDebugOutline(u, nd, overlay, c, r, float3(0.7f), behind);
            break;
        }
    }
}
