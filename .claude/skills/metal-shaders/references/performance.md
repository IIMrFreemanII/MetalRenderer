# Metal Shader Performance

**In MetalRenderer, speed is the `performance` skill's job.** It has the benchmarks, the alternating A/B
(`ab.sh`), the quality scorers, and [gpu-metal.md](../../performance/references/gpu-metal.md): what this renderer is
bound by (bandwidth in full-screen passes, registers in the big trace and ReSTIR kernels), the kernel variants, the
threadgroup sizes (`Renderer.threadgroupSizes`, `METALRENDERER_TG`), what was measured and what didn't help. This
file is what to get right while writing a kernel, so it doesn't need undoing later; don't claim a speedup from it
without that skill's numbers. Two of its general rules don't apply here: the libraries are compiled from source at
runtime on purpose (hot reload; Metal caches the pipelines, §10), and the frame has no render passes (§9 is for the
Modeller's viewport and other apps).

Measure before optimizing: Xcode GPU frame capture → shader cost per pipeline, and the per-draw/dispatch **limiters** (ALU, texture sample, memory read/write bandwidth, occupancy, threadgroup memory). Optimize whatever the top limiter is; the rest of this file is organized by limiter.

## Contents
1. Apple GPU mental model
2. Precision: half vs float
3. ALU tips
4. Memory and bandwidth
5. Occupancy and registers
6. Threadgroup sizing
7. Divergence and control flow
8. Textures
9. TBDR render-pass tips
10. Pipeline/compile hitches

## 1. Apple GPU mental model

- SIMD-groups of **32 threads** execute in lockstep (`threadExecutionWidth` = 32 on Apple GPUs; AMD Macs may report 64 — never hard-code).
- Register file is shared by all resident threads: fewer registers per thread → more threads in flight → better latency hiding (occupancy).
- 16-bit (`half`, `short`) arithmetic is at least as fast as 32-bit and uses half the register space.
- Unified memory: no upload copies for `.shared` storage, but bandwidth is still the scarcest resource on mobile.
- Tile-based deferred rendering (TBDR): fragments are shaded per tile in fast on-chip memory; Hidden Surface Removal skips occluded opaque fragments before shading.

## 2. Precision: half vs float

Use `half` for: colors, normals, tangents, lighting terms in [−65504, 65504] with ~3 significant digits, texture samples from 8/10/16-bit formats, blend weights.
Keep `float` for: positions (world/clip space), depth, texture coordinates into textures > ~2048 texels, time values, accumulation of many terms, anything needing exact integers > 2048.

Tips:
- Declare textures as `texture2d<half>` when the format is ≤16-bit; sampling returns `half` directly with no conversion.
- Write literals as `1.0h` in half math; a bare `1.0` is `float` and promotes the whole expression.
- Avoid ping-ponging between half and float inside hot loops — each conversion is an instruction.
- Varyings: `half` vertex outputs halve interpolation bandwidth; keep the `[[position]]` in `float4`.

## 3. ALU tips

- Use `fma(a, b, c)`, `mix`, `saturate`, `clamp`, `select`, `step`, `dot` — they map to single or few instructions. `saturate` is often free as an output modifier.
- Division: multiply by a precomputed reciprocal; `fast::divide`, `rsqrt` instead of `1/sqrt`.
- Integer `/` and `%` are expensive unless the divisor is a compile-time power of two; use shifts/masks or a function constant.
- Transcendentals (`sin`, `pow`, `exp`): use `fast::` variants (default under fast math) and consider polynomial approximations or LUTs only if profiling shows ALU-bound.
- `pow(x, 2.0)` → `x * x`; `pow(x, 5)` style Fresnel → multiply chain.
- Hoist uniform computations to the CPU or vertex shader (per-draw constants, matrix products).
- Use 16-bit indices (`ushort`) for threadgroup-local indexing.

## 4. Memory and bandwidth

- **Coalescing**: adjacent threads in a SIMD-group should access adjacent addresses. For compute data prefer Structure-of-Arrays (separate `float` arrays) over Array-of-Structures when threads read only some fields.
- Use vector loads (`float4`, `half4`) for contiguous data; pack small values (`ushort2`, `uchar4`, `packed_half3`).
- `const device` + `restrict`-like discipline: don't alias the same buffer as two arguments where one is written.
- Uniform data → `constant` address space (enables constant-buffer preloading). Large or divergently-indexed tables → `device`.
- Reuse data via threadgroup memory (tiling) when multiple threads read the same values; read once, `threadgroup_barrier`, then share.
- On TBDR, avoid writing intermediate full-screen render targets that are read immediately: use programmable blending, imageblocks or tile shaders to keep data on-chip.
- Storage modes: `.private` for GPU-only resources (enables lossless compression on Apple silicon), `.shared` for CPU-written per-frame data, `.memoryless` for transient attachments (depth, MSAA, G-buffer) that never leave the tile.

## 5. Occupancy and registers

Signs of low occupancy: GPU capture shows low "Occupancy" and high latency per instruction.

- Reduce live variables across loops and texture sample calls; recompute cheap values instead of keeping them alive.
- Use `half`/`short` to halve register footprint.
- Avoid large per-thread arrays and dynamic indexing into them (spills to device memory — "stack" in GPU capture).
- `[[max_total_threads_per_threadgroup(N)]]` lets the compiler budget registers for N threads.
- Threadgroup memory per threadgroup also limits how many threadgroups fit on a core; don't over-allocate.
- Avoid unbounded loops the compiler can't unroll when they carry a lot of state; `#pragma unroll` (or a function-constant trip count) for small fixed loops.

## 6. Threadgroup sizing

```swift
let w = pso.threadExecutionWidth                         // 32 on Apple GPUs
let h = pso.maxTotalThreadsPerThreadgroup / w            // e.g. 1024/32 = 32
let tg = MTLSize(width: w, height: h, depth: 1)
encoder.dispatchThreads(MTLSize(width: texW, height: texH, depth: 1),
                        threadsPerThreadgroup: tg)
```

- Always a multiple of the SIMD width; 256 threads is a solid default for 1D work.
- For 2D image kernels, square-ish tiles (16×16, 32×8) improve texture cache locality.
- If the kernel uses threadgroup memory with a fixed size, pin the threadgroup size to match (and use `[[max_total_threads_per_threadgroup]]`).
- `dispatchThreads` (non-uniform) avoids partial-threadgroup edge waste on supported GPUs, but the kernel still needs a bounds check when the data size isn't the grid size, and **any threadgroup-cooperative kernel must handle partially-filled threadgroups** (inactive threads still need to hit barriers: clamp loads and keep them participating rather than `return`ing before a barrier).

## 7. Divergence and control flow

- Branches whose condition is uniform across a SIMD-group are cheap; divergent branches execute both sides.
- Replace small divergent branches with `select`/`mix`/`step`.
- Use function constants for per-pipeline feature switches rather than uniform-buffer flags.
- Early-out (`return`) in compute is fine *before* any barrier; never return before a barrier other threads will wait on.
- `discard_fragment()` in fragment shaders disables some HSR optimizations — see §9.

## 8. Textures

- Generate mipmaps for minified textures (`blitEncoder.generateMipmaps`); unmipped minification thrashes the cache.
- Use compressed formats (ASTC on Apple GPUs, BC on Macs) for static assets.
- Prefer `sample` with hardware filtering over manual bilinear with 4 `read`s; use `gather` to fetch 4 values in one instruction.
- Separable filters (blur): two 1D passes, or one pass using linear-sampling tricks (sample between texels to get 2 taps per fetch).
- Avoid dependent texture reads where UVs are computed from another sample in the same shader when possible.
- Set `allowGPUOptimizedContents` (default true) and `.private` storage to enable lossless compression.

## 9. TBDR render-pass tips

- `loadAction`: `.clear` or `.dontCare` unless you truly need previous contents; `.load` costs a full-tile read.
- `storeAction`: `.dontCare` for depth/stencil and any attachment not used later; `.multisampleResolve` instead of storing MSAA samples.
- Mark transient attachments `.memoryless` (depth, MSAA color, G-buffer in a single-pass deferred renderer).
- Draw order: opaque → alpha-tested (`discard_fragment`) → blended. HSR handles opaque overdraw; alpha-test and depth writes from the fragment shader (`[[depth(any)]]`) defeat early rejection, so keep them to the geometry that needs them.
- If you must write depth in the fragment shader, use `[[depth(greater)]]`/`[[depth(less)]]` when you can guarantee the direction — preserves early-Z.
- Programmable blending (`[[color(n)]]` input) reads the current tile value for free — use it instead of sampling a copy of the framebuffer.
- Merge passes that share attachments into one render pass (deferred lighting in one pass with imageblocks or programmable blending).

## 10. Pipeline/compile hitches

- Compile `.metal` at build time into a metallib; avoid runtime `makeLibrary(source:)` in shipping code paths. (MetalRenderer compiles from source by design: a library compiles on a background queue and swaps in between frames, and Metal's on-disk pipeline cache makes a warm start take milliseconds; gpu-metal.md §8.)
- Create pipeline states at load time or asynchronously (`makeRenderPipelineState(descriptor:completionHandler:)`), never on the frame's critical path.
- Use binary archives (`MTLBinaryArchive`) or Metal 4 pipeline serialization / offline GPU binaries to skip device compilation on launch.
- Many variants: function constants + a pipeline cache keyed by constant values.
