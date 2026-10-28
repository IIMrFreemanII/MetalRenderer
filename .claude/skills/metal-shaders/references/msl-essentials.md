# MSL Essentials

MSL is C++ (C++14 for MSL 2.x–3.x, C++17 for MSL 4) with GPU address spaces, attributes and a vector/matrix standard library. No exceptions, RTTI, virtual functions, recursion (except via function pointers/visible functions on newer GPUs), `new`/`delete`, or the C++ standard library.

## Contents
1. Function qualifiers
2. Address spaces
3. Scalar, vector and matrix types
4. Struct layout and CPU/GPU sharing
5. Built-in attributes (inputs)
6. Textures and samplers
7. Function constants
8. Argument buffers and bindless
9. Compiling and language versions

## 1. Function qualifiers

| Qualifier | Stage |
|---|---|
| `kernel` | compute |
| `vertex` | vertex |
| `fragment` | fragment |
| `[[object]]`, `[[mesh]]` | mesh pipeline stages (Metal 3) |
| `kernel` used in a tile pass | tile shader |
| `[[visible]]` | function callable via function pointer / visible function table |
| `[[stitchable]]` | SwiftUI shader effects and stitched functions |
| `[[intersection(...)]]` | ray-tracing intersection function |

## 2. Address spaces

Every pointer/reference argument must carry one.

| Space | Use | Notes |
|---|---|---|
| `device` | Large read/write buffers | `const device T*` for read-only — helps the compiler. |
| `constant` | Small, read-only data read uniformly by all threads (uniforms, LUTs indexed uniformly) | Cached and can be prefetched. Size must be known; avoid divergent indexing into large `constant` arrays. |
| `thread` | Per-thread locals | Default for locals. |
| `threadgroup` | Shared scratch inside a threadgroup | Declare in kernel body (fixed size) or as `threadgroup T* p [[threadgroup(n)]]` with `setThreadgroupMemoryLength`. Max typically 32 KB. |
| `threadgroup_imageblock` | Tile-memory imageblocks (tile shaders) | Apple GPUs only. |
| `object_data` | Payload from object to mesh stage | Mesh pipeline. |
| `ray_data` | Ray payload in intersection functions | Ray tracing. |

Rule of thumb: uniforms → `constant`; vertex/instance arrays and anything indexed by thread id → `device`.

## 3. Types

- Scalars: `bool`, `char/uchar` (8), `short/ushort` (16), `int/uint` (32), `long/ulong` (64, limited), `half` (16-bit float), `float`, `bfloat` (MSL 3.1+).
- Vectors: `float2/3/4`, `half4`, `uint2`, … Swizzles `.xyzw`/`.rgba`; `.xxyy` etc. Literals: `1.0h` (half), `1.0f`, `1u`.
- Packed vectors: `packed_float3` (12 bytes, 4-byte aligned) vs `float3` (16 bytes, 16-byte aligned).
- Matrices: `float4x4`, `float3x3`, `half3x3`; column-major; `m[col][row]`; `m * v` multiplies column vector.
- Conversions: implicit narrowing between vectors is an error — write `half3(v)`, `float4(h, 1.0)`. `as_type<uint>(f)` reinterprets bits.
- `size_t` and pointers are 64-bit on the GPU.

## 4. Struct layout and CPU/GPU sharing

| MSL type | Size | Align | Swift equivalent |
|---|---|---|---|
| `float` | 4 | 4 | `Float` |
| `float2` | 8 | 8 | `SIMD2<Float>` |
| `float3` | 16 | 16 | `SIMD3<Float>` |
| `packed_float3` | 12 | 4 | `(Float, Float, Float)` / `MTLPackedFloat3` |
| `float4` | 16 | 16 | `SIMD4<Float>` |
| `half4` | 8 | 8 | `SIMD4<Float16>` |
| `float3x3` | 48 | 16 | `simd_float3x3` |
| `float4x4` | 64 | 16 | `simd_float4x4` |

**In MetalRenderer** the structs are written twice by hand, in `GPUTypes.swift` and `Shaders/Types.metal`, from 16-byte vectors and groups of four 32-bit scalars, and each MSL struct pins its size (and the offsets the CPU writes) with `static_assert(sizeof(T) == N && __builtin_offsetof(T, field) == M, "...")`. Swift sizes buffers and `setBytes` with `MemoryLayout<T>.stride`. SKILL.md, "Data layout first".

Elsewhere, the usual practice: define structs in a C header using `simd_*` types, include it from MSL and expose it to Swift via the bridging header (or a module map for Swift packages). Guard host-only code with `#ifndef __METAL_VERSION__`.

```c
// Xcode template pattern: typed enums usable from MSL, Objective-C and Swift
#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif
typedef NS_ENUM(EnumBackingType, BufferIndex) { BufferIndexVertices = 0, BufferIndexUniforms = 1 };
```

Vertex arrays: the per-element stride must match. An MSL array of `float3` has 16-byte stride; Swift `[SIMD3<Float>]` also has 16-byte stride; `[Float]` triples are 12 bytes — use `packed_float3` on the MSL side for those.

## 5. Built-in input attributes

Compute:
- `[[thread_position_in_grid]]` (uint/uint2/uint3) — global id
- `[[thread_position_in_threadgroup]]`, `[[thread_index_in_threadgroup]]` (flattened)
- `[[threadgroup_position_in_grid]]`, `[[threadgroups_per_grid]]`, `[[threads_per_threadgroup]]`, `[[threads_per_grid]]`
- `[[thread_index_in_simdgroup]]`, `[[simdgroup_index_in_threadgroup]]`, `[[threads_per_simdgroup]]`, `[[simdgroups_per_threadgroup]]`

Vertex: `[[vertex_id]]`, `[[instance_id]]`, `[[base_vertex]]`, `[[base_instance]]`, `[[stage_in]]` (with `[[attribute(n)]]` fields + `MTLVertexDescriptor`), `[[amplification_id]]`.

Vertex outputs / fragment inputs: `[[position]]` (required, float4), `[[point_size]]`, `[[clip_distance]]`, `[[render_target_array_index]]`, `[[viewport_array_index]]`; interpolation qualifiers `[[flat]]`, `[[center_perspective]]` (default), `[[center_no_perspective]]`, `[[centroid_perspective]]`, `[[sample_perspective]]`.

Fragment: `[[front_facing]]`, `[[sample_id]]`, `[[sample_mask]]`, `[[point_coord]]`, `[[barycentric_coord]]` (GPU-family dependent), `[[color(n)]]` as input = programmable blending (Apple GPUs).
Fragment outputs: return a vector, or a struct with `[[color(n)]]`, `[[depth(any|greater|less)]]`, `[[stencil]]`, `[[sample_mask]]`.

Kernel attribute: `[[max_total_threads_per_threadgroup(N)]]` lets the compiler allocate registers for at most N threads — use it when you always dispatch ≤ N.

## 6. Textures and samplers

```metal
// check: skip (declarations only: these are kernel parameters)
texture2d<float, access::sample> a;      // default access is sample
texture2d<half, access::read>    b;      // read(uint2) only, no filtering
texture2d<half, access::write>   c;      // write(value, uint2)
texture2d<float, access::read_write> d;  // needs read-write texture tier; call d.fence() between write and read in same thread
depth2d<float> shadowMap;                // sample_compare for PCF
texture2d_array<half>, texture3d<half>, texturecube<half>, texture_buffer<half>
```

- `sample(s, uv)` uses normalized coords [0,1]; `read(gid)` uses integer texel coords; `sample(s, uv, level(l))`, `bias(b)`, `gradient2d(dx, dy)`.
- `gather(s, uv)` fetches a 2x2 quad of one channel — great for blur/PCF.
- Query: `get_width(lod)`, `get_height(lod)`, `get_num_mip_levels()`.
- Samplers: prefer `constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);` in the shader. Pass a `sampler` argument when the app needs to change it at runtime (anisotropy, LOD clamp).
- The element type (`float`/`half`/`int`/`uint`) must match the pixel format family: normalized and float formats → `float` or `half`; `*Uint` → `uint`; `*Sint` → `int`.

## 7. Function constants

Specialize a single source at pipeline-creation time; dead branches are compiled out.

```metal
constant bool  kUseNormalMap [[function_constant(0)]];
constant int   kSampleCount  [[function_constant(1)]];
constant bool  kHasSampleCount = is_function_constant_defined(kSampleCount);

struct VertexOut { float4 position [[position]]; float3 normal; float2 uv; };

fragment half4 shade(VertexOut in [[stage_in]],
                     texture2d<half> normalMap [[texture(1), function_constant(kUseNormalMap)]])
{
    half3 n = half3(normalize(in.normal));
    if (kUseNormalMap) {
        constexpr sampler s(filter::linear);
        n = normalize(normalMap.sample(s, in.uv).xyz * 2.0h - 1.0h);   // the argument exists only in this variant
    }
    return half4(n * 0.5h + 0.5h, 1.0h);
}
```

In MetalRenderer, kernel code doesn't declare its own constants: it tests flag bits with `flagOn(u.flags, FLAG_X)` / `passOn(word, X)`, and the variants fold those tests through the function constants in `Shaders/Types.metal` (`fixedFlagsConstant` … `fixedPassMaskConstant`, indices 1–4; `lightTypesConstant` → `LIGHT_SPEC`, index 0). A bit is compiled in by naming it in `Kernel.fixedFlags` / `fixedPassFlags`, and `bind` picks the variant: see the `performance` skill's gpu-metal.md §3.

Host: `MTLFunctionConstantValues().setConstantValue(&flag, type: .bool, index: 0)` then `library.makeFunction(name:constantValues:)` (Metal 4: set on the function descriptor). Cache the resulting pipelines.

## 8. Argument buffers and bindless

Argument buffers group resources into one buffer. With Tier 2 (all Apple silicon) and Metal 3, the argument buffer is just a struct of GPU pointers and resource IDs:

```metal
struct VertexOut { float4 position [[position]]; float2 uv; };

struct Material {
    texture2d<half> albedo;
    texture2d<half> normal;
    constant float4* params;
};

struct Scene {
    device Material* materials;   // array of materials
    device float4x4* transforms;
};

fragment half4 shadeBindless(VertexOut in [[stage_in]],
                             constant Scene& scene [[buffer(0)]],
                             constant uint& materialID [[buffer(1)]])
{
    constexpr sampler s(filter::linear);
    device Material& m = scene.materials[materialID];
    return m.albedo.sample(s, in.uv);
}
```

Host side (Metal 3+): write `texture.gpuResourceID` and `buffer.gpuAddress` into the struct memory directly. Every indirectly referenced resource must be resident: `useResource(_:usage:)`/`useHeap(_:)` on classic encoders, or a residency set (required in Metal 4). Forgetting residency = garbage or GPU fault, not a validation error in release builds.

## 9. Compiling and language versions

**In MetalRenderer:** every library is compiled at runtime from source, MSL 3.2 (`Pipelines.compile`: `MTLCompileOptions.languageVersion = .version3_2`, the `RT_STATS` macro, `METALRENDERER_MATH=relaxed|safe` for the math mode), through `MTL4Compiler`. Nothing is in a metallib. `scripts/check_shader.sh --repo` compiles the same sources offline; since Xcode 26 the compiler is the separately downloaded Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`), which the script finds even where `xcrun` can't reach it.

- Build-time: `.metal` files in an Xcode target compile into `default.metallib`; set *Metal Compiler – Language Revision* and enable *Debug info* + *Produce debugging information* for shader debugging.
- Runtime: `device.makeLibrary(source:options:)` with `MTLCompileOptions.languageVersion` — slower startup; use for hot reload or user-authored shaders.
- CLI: `xcrun -sdk macosx metal -std=metal3.1 -c shader.metal -o shader.air && xcrun -sdk macosx metallib shader.air -o shader.metallib` (use `-sdk iphoneos` for iOS).
- `__METAL_VERSION__` macro equals e.g. `310` for MSL 3.1; use it for conditional code.
- Math mode: fast math is the default. MSL 3.2+ compilers accept `-fmetal-math-mode=fast|relaxed|safe` (older: `-fno-fast-math`). Use `precise::` functions (e.g. `precise::sin`) for individual call sites that need IEEE accuracy instead of disabling fast math globally.
