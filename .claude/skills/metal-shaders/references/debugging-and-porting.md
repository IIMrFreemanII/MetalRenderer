# Debugging and Porting

## In MetalRenderer first

Every run here is headless (`METALRENDERER_BENCH`, the `offscreen` skill); never open the app's window to debug.

* **A compile error** names the piece and its line (`Shaders/Trace.metal:412`), through `ShaderSource`'s `#line`
  markers. `check_shader.sh --repo` reproduces it in seconds without the app. A Code node's error says `code:<line>`.
  A failed hot reload keeps the old pipelines, so a picture that didn't change after R may be a compile error in the
  log.
* **Wrong pixels:** the debug views (`viewMode`: Raw direct, Raw indirect, Normals, Albedo, History length, …;
  `RenderSettings.viewModes`) show a kernel's inputs; render one with the `offscreen` skill. Compare against the
  reference path tracer before blaming a denoiser.
* **NaNs or infinities:** `METALRENDERER_MATH=relaxed` (exact infinities and NaNs) rules fast math out;
  `METALRENDERER_MATH=safe` also keeps every operation's order, so a variant and its general pipeline must then match
  bit for bit (`Tools/eval/pngdiff.py`).
* **A variant differs from the general pipeline:** `METALRENDERER_VARIANTS=0` runs the general pipelines; `=log`
  prints each variant as it is made.
* **Out-of-bounds or hangs:** `MTL_SHADER_VALIDATION=1` on a benchmark run reports the shader line (slow).
* **Works for a while, then faults:** a resource reached through a pointer that no frame declares drops out of
  Metal 4's residency set after 600 frames (`METALRENDERER_RESIDENCY_LIFE=16` shows it at once; see
  `metal4-and-tensors.md`).
* **Numbers:** a test against a CPU reference, run through `Metal3Pass` (the `MipKernelTests` pattern).
* **Frame captures:** `MTL_CAPTURE_ENABLED=1` from Xcode (open `Package.swift`, Release scheme); the `performance`
  skill's gpu-metal.md §10.

## Contents
1. Debugging toolkit
2. Symptom → likely cause
3. Common compiler errors
4. Porting from GLSL / HLSL / CUDA

## 1. Debugging toolkit

- **API validation** (Xcode scheme → Diagnostics → Metal API Validation, or `MTL_DEBUG_LAYER=1`): catches wrong indices, missing bindings, usage-flag and format mismatches. Turn it on first.
- **Shader validation** (scheme → Shader Validation, or `MTL_SHADER_VALIDATION=1`): catches out-of-bounds device memory access, null texture use, infinite loops/timeouts — reports the shader line. Slow; use while debugging.
- **GPU frame capture** (Xcode debug bar, or `MTLCaptureManager` programmatically for compute-only tools): inspect every bound buffer/texture, step through a shader for a chosen pixel/thread, view per-line cost and limiter counters. Compile with debug info (`-gline-tables-only` / *Produce Debugging Information*) to map to source.
- **Shader logging** (MSL 3.2+, iOS 18/macOS 15): `#include <metal_logging>` and `os_log_default.log("v=%f id=%u", v, gid);`. Enable it at compile time (`MTLCompileOptions.enableLogging = true`, or `-fmetal-enable-logging`) and attach an `MTLLogState` to the command queue / command buffer descriptor to receive messages. Log only from a few threads (`if (all(gid == uint2(100, 100)))`) — logging every thread floods the buffer.
- **Debug output buffer** (any version): add a `device float4* debug [[buffer(15)]]` argument, write intermediate values for chosen threads, read back on the CPU.
- **Visualize** intermediate values as color: `return half4(half3(n * 0.5h + 0.5h), 1);` for normals, `fract(uv)` for UVs, a heat ramp for iteration counts.
- **Compare against CPU**: for compute, run a small input through a straightforward CPU reference and diff with a tolerance (`half`/fast-math results differ in the last bits).

## 2. Symptom → likely cause

| Symptom | Check first |
|---|---|
| Black / all-zero output | Texture lacks `.shaderWrite`/`.renderTarget` usage; wrong binding index; kernel returns early for all threads (bounds check against wrong size); pipeline never dispatched / command buffer never committed; reading `.private` buffer from CPU. |
| Garbage or stripes in the last row/column | Missing bounds check with `dispatchThreadgroups`; grid rounded up. |
| Geometry exploded / random vertices | CPU/GPU struct stride mismatch (`float3` 16 vs 12 bytes); vertex descriptor offsets wrong; index type `uint16` vs `uint32` mismatch. |
| Everything clipped / depth always fails | GL-style projection (z in [−1,1]) — use a Metal [0,1] projection; depth compare function vs clear value (reverse-Z needs clear 0 and `.greater`); depth attachment format/pixel format not set on pipeline. |
| Image upside down | Texture origin top-left vs GL bottom-left; flip `uv.y = 1 - uv.y` in one place only. |
| Colors washed out or too dark | sRGB applied twice or not at all (`_srgb` format + manual gamma, or linear data in an sRGB texture); premultiplied vs straight alpha mismatch. |
| Dark fringes around transparent edges | Straight-alpha texture blended as premultiplied (or vice versa); filtering unpremultiplied colors. |
| NaN / black pixels sporadically | `normalize(0)`, `pow` with negative base (use `powr` on clamped input), `half` overflow > 65504, division by zero, `sqrt` of negative from rounding (`sqrt(max(x, 0))`). |
| Results flicker frame to frame | Data race: missing `threadgroup_barrier`; CPU writing a buffer the GPU still reads (use triple-buffering with a semaphore); missing barrier between Metal 4 passes. |
| Compute result slightly differs from CPU | Expected with fast math / `half` / different summation order. Use `precise::` functions or `-fmetal-math-mode=safe` only if exactness matters. |
| GPU hang / "Execution of the command buffer was aborted due to an error" | Infinite loop, out-of-bounds write, missing residency for indirectly-referenced resources, barrier inside divergent code. Run with shader validation. |
| Very slow first frame | Pipeline compiled on demand; runtime source compilation. Precompile and create PSOs at load. |
| Works on Apple silicon, broken on Intel/AMD Mac | SIMD width 64 assumptions, programmable blending, memoryless, `half` precision paths, non-uniform threadgroups. |

## 3. Common compiler errors

- *"parameter ... must have an address space"* → add `device`/`constant`/`threadgroup` to the pointer/reference.
- *"type 'float3' is not valid for attribute 'buffer'"* → buffer arguments must be pointers or references: `constant float3& v [[buffer(0)]]`.
- *"cannot initialize ... of type 'half4' with an rvalue of type 'float4'"* → explicit conversion: `half4(x)`.
- *"call to 'sample' is ambiguous / no matching function"* → texture access must be `sample` (default) to call `sample`; coordinate type must be `float2` for normalized/`coord::pixel` sampling, `uint2` for `read`.
- *"threadgroup variables must be declared in kernel function scope"* → move `threadgroup` arrays into the kernel body or pass via `[[threadgroup(n)]]`.
- *"'xyz' attribute requires Metal 3.x"* → raise `-std=` / deployment target, or avoid the feature.
- *"use of undeclared identifier 'simd_sum'"* → requires MSL 2.1+ and a GPU family with SIMD-group functions; include `<metal_stdlib>`.
- *Linker: "function ... not found in library"* → function name typo, function not `kernel`/`vertex`/`fragment`, or `.metal` file not in the target.

## 4. Porting from GLSL / HLSL / CUDA

| GLSL | HLSL | CUDA | MSL |
|---|---|---|---|
| `vec2/3/4`, `mat4` | `float2/3/4`, `float4x4` | `float2/3/4` | `float2/3/4`, `float4x4` |
| `mediump float` | `min16float` / `half` | `__half` | `half` |
| `mix` | `lerp` | — | `mix` |
| `fract` | `frac` | — | `fract` |
| `mod(x,y)` (floored) | `fmod` (truncated) | `fmodf` | `fmod` (truncated) — write `x - y * floor(x / y)` for GLSL semantics |
| `inversesqrt` | `rsqrt` | `rsqrtf` | `rsqrt` |
| `atan(y, x)` | `atan2(y, x)` | `atan2f` | `atan2(y, x)` |
| `dFdx/dFdy` | `ddx/ddy` | — | `dfdx/dfdy` |
| `texture(s, uv)` | `tex.Sample(s, uv)` | `tex2D` | `tex.sample(s, uv)` |
| `texelFetch(t, p, 0)` | `tex.Load(int3(p, 0))` | — | `tex.read(uint2(p))` |
| `uniform` block | `cbuffer` | `__constant__` | `constant T& u [[buffer(n)]]` |
| SSBO `buffer` | `RWStructuredBuffer` | global pointer | `device T* p [[buffer(n)]]` |
| `shared` | `groupshared` | `__shared__` | `threadgroup` |
| `barrier()` | `GroupMemoryBarrierWithGroupSync()` | `__syncthreads()` | `threadgroup_barrier(mem_flags::mem_threadgroup)` |
| `gl_GlobalInvocationID` | `SV_DispatchThreadID` | `blockIdx*blockDim+threadIdx` | `[[thread_position_in_grid]]` |
| `gl_LocalInvocationID` | `SV_GroupThreadID` | `threadIdx` | `[[thread_position_in_threadgroup]]` |
| `gl_WorkGroupID` | `SV_GroupID` | `blockIdx` | `[[threadgroup_position_in_grid]]` |
| `subgroupAdd` | `WaveActiveSum` | `__shfl_down_sync` loop / `__reduce_add_sync` | `simd_sum` |
| `subgroupShuffle` | `WaveReadLaneAt` | `__shfl_sync` | `simd_shuffle` |
| `subgroupBallot` | `WaveActiveBallot` | `__ballot_sync` | `simd_ballot` |
| `atomicAdd` | `InterlockedAdd` | `atomicAdd` | `atomic_fetch_add_explicit(p, v, memory_order_relaxed)` |
| `gl_FragCoord` | `SV_Position` | — | `[[position]]` (float4; origin top-left, pixel centers at .5) |
| `gl_VertexID` | `SV_VertexID` | — | `[[vertex_id]]` |
| `discard` | `discard`/`clip` | — | `discard_fragment()` |
| `m * v` (column-major) | `mul(v, m)` (row-major convention) | — | `m * v` (column-major) |

Porting checklist:
1. Clip-space z: GL [−1,1] → Metal [0,1]. Fix the projection matrix (or remap `z = 0.5 * (z + w)` in the vertex shader as a stopgap).
2. Y direction: framebuffer/texture origin is top-left in Metal (same as D3D, opposite of GL). GL shaders that compute UVs from `gl_FragCoord` need `uv.y = 1 - uv.y`.
3. Matrix layout: HLSL with `row_major` or `mul(v, M)` → transpose or reverse multiplication order. Upload `simd_float4x4` from Swift without transposing.
4. GLSL `mod` vs MSL `fmod` sign behavior differs for negative inputs.
5. Shadertoy ports: `iResolution`, `iTime`, `iMouse` become uniforms; `fragCoord` = `in.position.xy` (flip y: `fragCoord.y = res.y - fragCoord.y`); `mainImage` body moves into a fragment or compute kernel.
6. HLSL → Metal for large codebases: Apple's **Metal shader converter** (DXIL → metallib) or SPIRV-Cross (`spirv-cross --msl`) for GLSL/SPIR-V. Hand-port hot shaders for best performance.
7. Shadertoy into MetalRenderer: a pattern or a noise that textures a surface is a material graph **Code node**
   (SKILL.md, "Material graph Code nodes", has the rules: a function body, names already taken, sRGB values, tiling).
   A full-screen effect becomes a kernel in
   `Shaders/Post.metal` or `Output.metal` over the frame's textures (`fragCoord` = `float2(tid) + 0.5`, already
   top-left; `iTime` from a time the stage passes in its params, as `Uniforms` carries only `frameIndex`),
   dispatched as a stage (SKILL.md, "Bind and dispatch it").
8. CUDA warp size 32 = Metal SIMD-group 32 on Apple GPUs; CUDA's `__syncwarp` has no direct need (SIMD-groups execute in lockstep) but use `simdgroup_barrier` when sharing through threadgroup memory within a SIMD-group.
