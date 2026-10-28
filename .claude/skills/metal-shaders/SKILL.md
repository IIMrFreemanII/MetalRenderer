---
name: metal-shaders
description: Write, review, debug and port Metal Shading Language (MSL) in MetalRenderer - a new kernel or pass, an edit to a piece in Sources/MetalRenderer/Shaders/, MaterialShaders/, the VFX or Modeller viewport shaders, a struct shared between GPUTypes.swift and Types.metal, the Swift that binds and dispatches a kernel, a shader compile error (after R or in a benchmark run), wrong or black pixels, NaNs, a GPU hang, or a port from GLSL/HLSL/CUDA/Shadertoy. Also for Metal outside this engine - SwiftUI [[stitchable]] effects, MLX metal_kernel, Metal 4 / TensorOps, vertex/fragment/mesh shaders. Use it even when only "a GPU kernel" or "the shader" is mentioned. For making a kernel faster, the performance skill.
---

# Metal shaders in MetalRenderer

Most Metal bugs are not in the math. They are mismatches between the shader and the code that binds it: a struct's
layout, a buffer or texture index, a usage flag or pixel format, a threadgroup size, a coordinate convention. Treat
the kernel and its Swift binding as one change, and compile it before calling it done.

The engine is compute only: ray queries through Metal's acceleration structures, G-buffer textures and full-screen
kernels, through Metal 4's command model (`Metal4Frame`). Only the Modeller's viewport rasterizes. The generic advice
in the references (build-time metallibs, a shared C header, raster pipelines, TBDR render passes) is for Metal
elsewhere; where it disagrees with this file, this file is how it's done here.

## References: read the one the task needs

| Task | Read |
|---|---|
| Syntax, address spaces, types and their sizes, attributes, textures, function constants, argument buffers | [references/msl-essentials.md](references/msl-essentials.md) |
| What to get right for speed while writing (half, registers, memory); measuring is the `performance` skill | [references/performance.md](references/performance.md) |
| Reductions, scans, histograms, tiled filters, matrix multiply, atomics, MLX kernels | [references/compute-patterns.md](references/compute-patterns.md) |
| Vertex/fragment, mesh shaders, SwiftUI effects, post-processing; where this engine's versions are | [references/rendering-patterns.md](references/rendering-patterns.md) |
| Metal 4 host API (compiler, argument tables, residency sets, barriers) and MSL tensors / TensorOps | [references/metal4-and-tensors.md](references/metal4-and-tensors.md) |
| Won't compile, wrong output, NaNs, hangs; porting from GLSL / HLSL / CUDA / Shadertoy | [references/debugging-and-porting.md](references/debugging-and-porting.md) |

GPU speed (bandwidth, occupancy, kernel variants, threadgroup sweeps, A/B) is the `performance` skill and its
[gpu-metal.md](../performance/references/gpu-metal.md). Its §9 lists the shader helpers to reuse before writing new
ones (sampling, light picks, reprojection, edge stopping).

## Where the code goes

Shaders are compiled at runtime (MSL 3.2, `Pipelines.compile` in `Sources/EngineCore/GPU/Pipelines.swift`, through
`MTL4Compiler`). Each library has an entry file that `#include`s its pieces in the order they build on each other;
`ShaderSource` splices them in with `#line` markers, so a compile error names the piece and its line. A new piece is
one `#include` line in its entry and needs no Swift rebuild. Saved shaders hot-reload in the dev build, and **R**
recompiles them; a failed compile keeps the pipelines that work.

| Library | Entry | Pieces | Compiled by |
|---|---|---|---|
| The renderer's kernels | `Sources/MetalRenderer/Shaders.metal` | `Shaders/*.metal` | `Pipelines` (`Kernel` cases) |
| Particle effects | `Sources/MetalRenderer/ShadersVFX.metal` | the same pieces it needs, plus generated code | `VFXCompiler` |
| Material graph bakes | `Sources/MetalRenderer/ShadersMaterial.metal` | `MaterialShaders/*.metal` | `MatCompiler` |
| Pixel processors, Code nodes | `Sources/MetalRenderer/ShadersMaterialCode.metal` | `MaterialShaders/MatCommon.metal` + generated | `MatCompiler` |
| The Modeller's viewport | `Sources/Modeling/Shaders/Viewport.metal` | none | `ViewportRenderer` |

Put a kernel in the piece of its subject (the comments in `Shaders.metal` say what each holds). A piece may use only
what pieces above it declare. If `ShadersVFX.metal` lists the piece you change, the VFX library compiles it too.

Something that *textures a surface* (a pattern, a noise, a Shadertoy) is not a renderer kernel: it is a material graph
node, usually a **Code node** (below). Something that changes the *whole frame* is a kernel in Post.metal or
Output.metal.

### Material graph Code nodes

A Code node's text (Material Designer, Advanced; `MatNodes.swift`) is the **body** of a function
`float4 f(float2 uv)` (`MatCompiler.codeSource`). The node's image is baked by `mat_generated`, and a graph that runs
as shader code evaluates the same text per shading point (`MatShaderCode`), so it must compile in both.

* In scope already: `uv` (pixel centre, [0,1], origin top-left), `size`, `seed`, the knobs `a b c d` (0…1, from
  `p[1..4].x`), `sampleInput(i, uv)` for the four inputs, and in the bake `p` and `args`. Don't declare those names:
  Shadertoy's `float a` or `vec2 p` won't compile, and `p` differs between the two paths.
* No function definitions in a body. Use MatCommon's helpers (`matHash`, `matRand(uint2, seed)`, `matRandom`,
  `matWrap`, `matQuintic`; MaterialShaders/MatCommon.metal), or a lambda (`auto h = [](float2 q) { ... };` compiles
  at MSL 3.2). Only MatCommon is in both paths; MatNoise's and MatPatterns' functions compile only in shading code.
* Colours are **sRGB values**, as everywhere in the graph (the renderer reads base colour through an sRGB view); keep
  a Shadertoy's colours as they are.
* Every baked image tiles: wrap lattice coordinates with `matWrap(cell, period)` at each octave, or it seams. No
  `iTime`: a knob or a constant.
* Check it with `check_shader.sh --code body.metal`: the body inside the wrapper the app uses, read from
  `MatCompiler.swift`. The wrapper's own warnings (`uv` in MatCommon, unused `b`/`c`/`d`) are expected.

## Workflow

### 1. Data layout first

A struct the CPU writes and the GPU reads is written twice, by hand: in Swift in `Sources/MetalRenderer/Renderer/
GPUTypes.swift` (or the system's own `*GPUTypes.swift`, such as `Sources/Physics/PhysicsGPUTypes.swift`), and in MSL
in `Shaders/Types.metal` (or the piece a comment names). There is no shared C header. Build every such struct from
16-byte vectors and matrices (`SIMD4<Float>` ↔ `float4`, `simd_float4x4` ↔ `float4x4`) plus groups of four 32-bit
scalars, so both compilers lay it out the same way. Pin the layout on the MSL side:

```metal
// check: skip (needs Types.metal's structs)
static_assert(sizeof(MeshData) == 48, "MeshData: GPUMesh");
static_assert(sizeof(SceneShading) == 304 && __builtin_offsetof(SceneShading, extras) == 272 && ...);
```

The Swift side checks it too, in `validateGPULayouts()` (GPUTypes.swift): change both when a struct changes. A new
field goes in a free lane first (a `w` the comments say is unused) and the size stays; otherwise add a whole
16-byte vector and update both size checks. Swift's `MemoryLayout<T>.stride` must equal that size, and `setBytes` /
buffer sizes use `stride`, never `size` (a
Swift struct `{ SIMD3<Float>; Float }` has size 20 but stride 32, as its MSL twin has size 32). Keep to 4-vectors with
the w lane carrying data, as the existing structs do: a `float3` hides 4 bytes of padding, and array data written as
packed triples (12 bytes) needs `packed_float3` on the MSL side. Flags are `uint` bits, never `bool`. A flag bit that
both sides name is written twice too (`FLAG_*` in Types.metal, the constants in Swift);
`KernelVariantsTests.testFlagValuesMatchTheShader` checks them, so add a new one there.

### 2. Write the kernel

* First look for it: much already exists (a soft-knee bloom threshold is `bloomPrefilter` in Post.metal). Extend
  the kernel or helper that's there before adding a pass, and read the neighbouring kernels of the piece: match
  their argument order, guards and precision.
* `kernel void fooKernel(...)` for a renderer kernel: the `Kernel` case `foo` names it (`trace` ↔ `traceKernel`).
* Bindings: `bind(enc, .foo, uniforms)` puts `Uniforms` at `[[buffer(0)]]`; `sceneSlot:` also binds the scene (the TLAS
  and what a hit reads at buffer 1, `bindScene`). Number the rest after those, and say in a comment at each argument
  what the Swift side binds there.
* Guard the grid against what it covers, the output texture (`tid.x >= dst.get_width() || tid.y >= dst.get_height()`)
  or the element count, but never return above a `threadgroup_barrier` or a `simd_*` call that the other threads
  still reach. Clamp those threads' loads instead and let them run through.
* `half` where it holds (weights, normals, colours in filters), `float` for positions, depth, UVs into large
  textures and long sums; follow the piece (Post.metal's kernels work in `float`). A 16F texture that feeds a history
  (the denoiser's, the temporal passes') is written through `roundToHalf` (Sampling.metal): a plain write rounds
  toward zero, and the feedback turns that into darkening.
* `.read(tid)` for exact texels, `sample` only to filter. The frame's light is linear: the drawable is
  `bgra8Unorm_srgb`, so the GPU encodes sRGB on the last write. Never apply a gamma in a frame kernel. (Material
  graph images are the exception: sRGB values, read through sRGB views.)
* A feature a configuration fixes for the whole frame is a variant, not a branch (`flagOn` / `passOn`,
  `Kernel.fixedFlags`): gpu-metal.md §3 says when it pays.
* Random numbers come from `makeSampler` / `pixelSeed` with the kernel's own dimension range and salt (Sampling.metal).

### 3. Bind and dispatch it

* Add the `Kernel` case (`Sources/EngineCore/GPU/Pipelines.swift`); the whole set compiles in the background on a
  load or R, so nothing else registers it. That, and any Swift below, is a Swift change: rebuild (`Tools/build.sh`,
  or `Tools/release.sh` for timing). Only a shader-only edit hot-reloads.
* Encode it where its neighbours are encoded: find the code that dispatches the kernels next to it
  (`grep -rn "\.bloomDown" Sources`). Two shapes exist: a `ComputeStage(pass: "name") { enc in ... }` in a stage list
  (`Renderer+Stages.swift`, the `Renderer+Feature.swift` files), and a function that opens its own pass with
  `passes.compute("post", serial: true)` and dispatches in order (`encodePost` in `Renderer+Encoding.swift`, with a
  local `start(kernel)` that binds the uniforms and its params). Either way the encoder is a `ComputePass`
  (`Sources/EngineCore/GPU/ComputePass.swift`), never a raw encoder: Metal 4's argument table and residency set
  underneath, a test's Metal 3 encoder (`Tests/MetalRendererTests/Support/Metal3Pass.swift`).
* `dispatch(enc, .foo, width:height:)` takes the group size from `Renderer.threadgroupSizes`
  (`Benchmark/Renderer+Benchmark.swift`): 8×8 unless a kernel needs another; a kernel with a threadgroup tile fixes
  its own and declares `max_total_threads_per_threadgroup`.
* A setting that drives it goes through `Settings.swift` (the value and its range), `SettingsTable.swift` (its
  control) and `Renderer+FramePlan.swift` (into the frame's params).
* Small constants: `enc.setBytes` (under 4 KB). CPU-written data the GPU reads: per frame slot
  (`frameIndex % maxFramesInFlight`), never a buffer a frame in flight may still read.
* A resource the kernel reaches only through a pointer or an argument buffer must be declared (`useResources` /
  `useHeap`, once per scope in `Renderer.bindScene`), or Metal 4's residency set won't hold it.
* Textures: `.shaderWrite` only on what a kernel writes; the shader's element type matches the format family
  (`half`/`float` for float and normalized formats, `uint` for `*Uint`).

### 4. Check it

1. **Compile without the app:** `.claude/skills/metal-shaders/scripts/check_shader.sh --repo` compiles every library as
   the app does (RT_STATS off and on), in a few seconds. Today it gives 15 warnings, all unused variables (6 in
   Shaders, 8 in Material, 1 in MaterialCode); add none. Edit the real piece and run `--repo`: there's no need for a
   scratch copy of the tree. A standalone file: `check_shader.sh file.metal`; a Code node's body:
   `check_shader.sh --code body.metal`. Both compile MSL 3.2, as the app does, unless `-std=` says otherwise.
2. **Tests:** the `tests` skill's `related.sh`. A shader edit runs `ShaderSourceTests` and `KernelVariantsTests`
   (every variant compiles; the flag constants match). A kernel that computes numbers (a reduction, a mip, a
   simulation step) gets a test against a CPU reference, the way `MipKernelTests` runs `Pipelines(device:source:)`
   through `Metal3Pass` and compares. A look (post, lighting) is proven with pictures instead, step 3.
3. **Look at it:** the `offscreen` skill renders the scene headless; the debug view modes (`viewMode`: normals,
   albedo, history length, …) show the inputs. `METALRENDERER_MATH=relaxed` rules fast math out of a NaN.
4. **Speed**, if it runs every frame: the `performance` skill's A/B on the release build.
5. `graphify update .`

### 5. Say what you assumed

After the code: what each binding index expects, the dispatch size and group, the precision choices, and anything not
verified (no device test, an image not looked at).

## Review checklist

- [ ] Every `[[buffer(n)]]` / `[[texture(n)]]` matches the Swift `set*` call, and buffer 0 is the uniforms.
- [ ] A shared struct is the same in GPUTypes.swift and Types.metal, 16-byte vectors and groups of four scalars, with a
      `static_assert` of its size; lengths use `MemoryLayout.stride`; no `bool` in it.
- [ ] Out-of-range threads return early only where no barrier or `simd_*` call follows; partial threadgroups work.
- [ ] Each `threadgroup` write another thread reads is followed by `threadgroup_barrier(mem_flags::mem_threadgroup)`,
      reached by every thread.
- [ ] Threadgroup memory stays well under 32 KB; a fixed tile size matches the dispatch's group.
- [ ] `half` only where ±65504 and ~3 digits hold; 16F writes through `roundToHalf`.
- [ ] Linear light in frame kernels, no gamma; sRGB values in material graph code.
- [ ] No `normalize(0)`, `sqrt` or `pow` of a negative, or division by zero: `max(x, 1e-6)`, `powr` on clamped input.
- [ ] Flags and constants written in both languages are identical; a refactor keeps the order of random draws.
- [ ] `check_shader.sh --repo` is clean (no new warnings), or the result is marked unverified.
