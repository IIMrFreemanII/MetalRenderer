# Rendering Patterns

**MetalRenderer doesn't draw this way.** Its frame is compute kernels: camera rays through Metal's acceleration
structures write a G-buffer (`traceKernel`, Shaders/Trace.metal), lighting and GI are more kernels (ReSTIR, the
cascades, the path tracer), the denoiser and the post chain are full-screen kernels (Denoise.metal, Output.metal,
Post.metal), and the result is written to a `bgra8Unorm_srgb` drawable. Shadows are shadow rays, not shadow maps.
Only the Modeller's viewport (`Sources/Modeling/Shaders/Viewport.metal`, `ViewportRenderer`) is a vertex/fragment
pipeline. The patterns below are for that viewport, SwiftUI effects, and Metal work outside this engine; for the
engine's own post-processing see §9.

## Contents
1. Vertex fetch: stage_in vs programmable
2. Lit vertex/fragment pair (Blinn-Phong, half precision)
3. Instancing
4. Shadow mapping with PCF
5. Programmable blending and single-pass deferred
6. Tile shaders and imageblocks (brief)
7. Mesh shaders
8. SwiftUI shader effects
9. Common post-processing snippets

## 1. Vertex fetch

**stage_in** (needs `MTLVertexDescriptor` on the pipeline; the hardware does format conversion, e.g. `uchar4` normalized → `half4`):
```metal
// check: skip (fragment: the types are §2's)
struct VertexIn {
    float3 position [[attribute(0)]];
    half3  normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};
vertex VertexOut vmain(VertexIn in [[stage_in]], constant Uniforms& u [[buffer(BufferIndexUniforms)]]) { ... }
```

**Programmable vertex pulling** (no vertex descriptor; flexible layouts, bindless meshes):
```metal
// check: skip (fragment: the types are §2's)
struct Vertex { packed_float3 position; packed_half3 normal; half2 uv; };   // 12 + 6 (+2 pad for half2 alignment) + 4 = 24-byte stride
vertex VertexOut vmain(uint vid [[vertex_id]],
                       const device Vertex* verts [[buffer(BufferIndexVertices)]],
                       constant Uniforms& u [[buffer(BufferIndexUniforms)]]) {
    Vertex v = verts[vid];
    ...
}
```
Pick one and make the host match: vertex descriptor offsets/strides for stage_in, or the shared struct's stride for pulling.

## 2. Lit vertex/fragment pair

```metal
#include <metal_stdlib>
using namespace metal;

// Normally in the shared header (ShaderTypes.h), included by Swift too.
enum { BufferIndexVertices = 0, BufferIndexUniforms = 1 };
enum { TextureIndexColor = 0 };
struct Uniforms {
    float4x4 modelViewProjection;
    float4x4 model;
    float3x3 normalMatrix;
    float3   cameraPos;
    float3   lightDir;
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPos;
    half3  normal;
    float2 uv;
};

vertex VertexOut litVertex(VertexIn in [[stage_in]],
                           constant Uniforms& u [[buffer(BufferIndexUniforms)]])
{
    VertexOut out;
    float4 world = u.model * float4(in.position, 1.0);
    out.position = u.modelViewProjection * float4(in.position, 1.0);
    out.worldPos = world.xyz;
    out.normal   = half3(u.normalMatrix * in.normal);
    out.uv       = in.uv;
    return out;
}

fragment half4 litFragment(VertexOut in [[stage_in]],
                           constant Uniforms& u [[buffer(BufferIndexUniforms)]],
                           texture2d<half> albedo [[texture(TextureIndexColor)]])
{
    constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
    half3 base = albedo.sample(s, in.uv).rgb;
    half3 N = normalize(in.normal);                      // re-normalize after interpolation
    half3 L = half3(normalize(-u.lightDir));
    half3 V = half3(normalize(u.cameraPos - in.worldPos));
    half3 H = normalize(L + V);
    half  diff = saturate(dot(N, L));
    half  spec = powr(saturate(dot(N, H)), 64.0h) * half(diff > 0.0h);
    half3 color = base * (0.05h + diff) + spec * 0.3h;
    return half4(color, 1.0h);
}
```
`powr` is `pow` for non-negative bases — cheaper and avoids NaN handling. Compute `worldPos`/`V` in float to avoid precision loss at large world coordinates.

## 3. Instancing

```metal
// check: skip (fragment: the types are §2's)
struct InstanceData { float4x4 model; half4 tint; };
vertex VertexOut instVertex(VertexIn in [[stage_in]],
                            uint iid [[instance_id]],
                            const device InstanceData* inst [[buffer(2)]],
                            constant float4x4& viewProj [[buffer(1)]]) {
    VertexOut o;
    o.position = viewProj * inst[iid].model * float4(in.position, 1);
    ...
}
```
Host: `drawIndexedPrimitives(..., instanceCount: n)`. Use `device` (not `constant`) for per-instance arrays — they're indexed per vertex group, not uniformly.

## 4. Shadow mapping with PCF

```metal
// check: skip (fragment: the types are §2's)
fragment half4 shadowed(VertexOut in [[stage_in]],
                        depth2d<float> shadowMap [[texture(1)]],
                        constant float4x4& lightViewProj [[buffer(2)]])
{
    constexpr sampler shadowSampler(coord::normalized, filter::linear, address::clamp_to_edge,
                                    compare_func::less_equal);
    float4 ls = lightViewProj * float4(in.worldPos, 1.0);
    float3 p  = ls.xyz / ls.w;
    float2 uv = p.xy * float2(0.5, -0.5) + 0.5;           // NDC y-up → texture y-down
    float  depth = p.z - 0.0015;                          // bias; Metal z already in [0,1]
    float lit = shadowMap.sample_compare(shadowSampler, uv, depth); // hardware 2x2 PCF with linear filter
    ...
}
```
Note the y flip and no `*0.5+0.5` on z — those are the two most common porting mistakes.

## 5. Programmable blending and single-pass deferred (Apple GPUs)

Read the current attachment value in the fragment shader by declaring it as an input:
```metal
// check: skip (fragment: the types are §2's)
struct GBuffer {
    half4 albedo  [[color(1)]];
    half4 normal  [[color(2)]];
    float depth   [[color(3)]];   // r32Float attachment
};

fragment half4 customBlend(VertexOut in [[stage_in]], half4 dst [[color(0)]]) {
    half4 src = ...;
    return half4(src.rgb * src.a + dst.rgb * (1.0h - src.a), 1.0h);   // any blend equation you like
}

// Lighting pass in the same render pass: G-buffer attachments are .memoryless, never hit memory
fragment half4 deferredLight(VertexOut in [[stage_in]], GBuffer g) { ... }
```
Not supported on Intel/AMD Macs — check `device.supportsFamily(.apple1)` or newer and keep a fallback if targeting them.

## 6. Tile shaders and imageblocks (Apple4+)

Tile shaders are kernels dispatched inside a render pass (`dispatchThreadsPerTile`) that operate on the whole tile's imageblock — e.g. light culling per tile, or a tile-wide resolve. Imageblocks let fragment and tile functions share a custom per-pixel struct (`[[imageblock_data]]`) in tile memory. Use when profiling shows bandwidth from multi-pass G-buffer work; otherwise programmable blending is simpler.

## 7. Mesh shaders (Metal 3, Apple7+/M1+)

Object stage (optional, culling/amplification) → mesh stage (emits vertices + primitives) → rasterizer → fragment.

```metal
struct MeshVertex { float4 position [[position]]; half3 normal; };
struct MeshPrim   { half3 color [[flat]]; };
using MeshletMesh = metal::mesh<MeshVertex, MeshPrim, 64, 126, metal::topology::triangle>;

struct Payload { uint meshletIDs[32]; };

// The app's meshlet data and its two helpers (stand-ins here).
struct Meshlet { float4 sphere; uint vertexCount, triangleCount; uint indices[126 * 3]; float4 positions[64]; };
static bool isVisible(const device Meshlet& m) { return m.sphere.w > 0; }
static MeshVertex makeVertex(const device Meshlet& m, uint i) { return MeshVertex{ m.positions[i], half3(0, 0, 1) }; }

[[object]]
void cullObject(object_data Payload& payload [[payload]],
                mesh_grid_properties grid,
                const device Meshlet* meshlets [[buffer(0)]],
                uint tid [[thread_position_in_grid]],
                uint lane [[thread_index_in_threadgroup]])
{
    bool visible = isVisible(meshlets[tid]);                // frustum/cone culling
    uint slot = simd_prefix_exclusive_sum(uint(visible));
    if (visible) payload.meshletIDs[slot] = tid;
    uint count = simd_sum(uint(visible));
    if (lane == 0) grid.set_threadgroups_per_grid(uint3(count, 1, 1));
}

[[mesh]]
void meshletMesh(MeshletMesh output,
                 const object_data Payload& payload [[payload]],
                 const device Meshlet* meshlets [[buffer(0)]],
                 uint tg [[threadgroup_position_in_grid]],
                 uint lid [[thread_index_in_threadgroup]])
{
    const device Meshlet& m = meshlets[payload.meshletIDs[tg]];
    if (lid == 0) output.set_primitive_count(m.triangleCount);
    if (lid < m.vertexCount)   output.set_vertex(lid, makeVertex(m, lid));
    if (lid < m.triangleCount) {
        output.set_index(lid * 3 + 0, m.indices[lid * 3 + 0]);
        output.set_index(lid * 3 + 1, m.indices[lid * 3 + 1]);
        output.set_index(lid * 3 + 2, m.indices[lid * 3 + 2]);
        output.set_primitive(lid, MeshPrim{ half3(1) });
    }
}
```
(The object function above assumes a 32-thread object threadgroup so SIMD-group ops cover it.) Host: `MTLMeshRenderPipelineDescriptor`, `drawMeshThreadgroups(_:threadsPerObjectThreadgroup:threadsPerMeshThreadgroup:)`. Limits: max 256 vertices / 512 primitives per mesh threadgroup (check GPU family); payload ≤ 16 KB.

## 8. SwiftUI shader effects (iOS 17+/macOS 14+)

```metal
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// .colorEffect — per-pixel color transform
[[ stitchable ]] half4 tint(float2 position, half4 color, half4 tintColor, float amount) {
    return half4(mix(color.rgb, tintColor.rgb * color.a, half(amount)), color.a);  // colors are premultiplied
}

// .distortionEffect — return the source position to sample from
[[ stitchable ]] float2 wave(float2 position, float time, float2 size) {
    return position + float2(0, sin(time * 3 + position.x / 20) * 6);
}

// .layerEffect — sample the whole layer (blurs, pixelation, chromatic aberration)
[[ stitchable ]] half4 pixellate(float2 position, SwiftUI::Layer layer, float cell) {
    float2 p = (floor(position / cell) + 0.5) * cell;
    return layer.sample(p);
}
```
```swift
Image("photo")
    .colorEffect(ShaderLibrary.tint(.color(.orange), .float(0.4)))
    .distortionEffect(ShaderLibrary.wave(.float(t), .float2(size)), maxSampleOffset: CGSize(width: 0, height: 6))
    .layerEffect(ShaderLibrary.pixellate(.float(8)), maxSampleOffset: .zero)
```
Rules: the first parameters are fixed by the effect type (`position`, `color` / `layer`); extra parameters map in order to the Swift arguments (`.float`, `.float2`, `.color` → `half4`, `.image`, `.floatArray` → `device const float* p, int count`). `position` is in points in the view's local space, not normalized — pass `size` if you need UVs. Colors are premultiplied alpha. Set `maxSampleOffset` large enough for distortion/layer effects or edges clip. Animate via `TimelineView(.animation)` passing elapsed time. Use `.visualEffect { content, proxy in ... }` to access the view size.

## 9. Post-processing snippets

In MetalRenderer these already exist; extend them rather than adding copies. The tone curves (ACES, AgX, Reinhard,
chosen by `Uniforms.post.y`), exposure and the colour grade are in `Shaders/Output.metal` (`tonemapKernel`,
`compositeKernel`); depth of field, bloom, vignette, grain and chromatic aberration are in `Shaders/Post.metal`
(`PostParams`), and so is the temporal AA (`taaResolveKernel`). No kernel converts to sRGB: the drawable's
`_srgb` format does, so `linearToSRGB` below is for targets without one.

```metal
// ACES filmic approximation (Narkowicz), input linear HDR
half3 acesApprox(half3 x) {
    x *= 0.6h;
    return saturate((x * (2.51h * x + 0.03h)) / (x * (2.43h * x + 0.59h) + 0.14h));
}
// Linear → sRGB (only when the target is NOT an _srgb format)
half3 linearToSRGB(half3 c) {
    return select(1.055h * powr(c, 1.0h / 2.4h) - 0.055h, c * 12.92h, c <= 0.0031308h);
}
// Vignette
half vignette(float2 uv, half strength) { float2 d = uv - 0.5; return half(1.0 - dot(d, d) * strength); }
// Luma
half luma(half3 c) { return dot(c, half3(0.2126h, 0.7152h, 0.0722h)); }
```
