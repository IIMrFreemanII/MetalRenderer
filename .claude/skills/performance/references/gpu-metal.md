# GPU (Metal / MSL) practices for MetalRenderer

Apple-silicon GPUs here: a unified memory architecture (no managed storage, no PCIe copies), 32-wide simdgroups, tile
memory, and counters that can be sampled only at encoder boundaries. M1/M2 have no ray-tracing hardware, so Metal's
intersector is software and the project's own BVH (`CUSTOM_RT`) can beat it. On M3 and later, re-check with
`METALRENDERER_BENCH=rt`.

The shaders are compiled at runtime (MSL 3.2, `Pipelines.compile`) from `Sources/MetalRenderer/Shaders.metal`, the
entry file, and the pieces it lists in `Sources/MetalRenderer/Shaders/` (one per subject; `ShaderSource.swift` joins
them with `#line` markers, so a compile error names the piece and its line; a new piece needs one `#include` line in
the entry, in the order the pieces build on each other, and no Swift rebuild). So
press **R** in the app to hot-reload them. The whole set of pipelines is built in the background before the swap, so
frames keep flowing during a compile and a failed reload keeps the old ones. Keep it that way.

## 1. Frame structure and submission

* **One command buffer per frame** in normal mode. Benchmarks split passes into separate command buffers only for
  timing (`Benchmark.splitPasses`). The Debug window's timings give each pass its own encoder, fenced
  (`GPUProfiler`). Both serialize the frame and add overhead, so never ship either on the normal path.
* **Overlap is real performance.** Radiance cascades overlap the denoiser in normal mode (`METALRENDERER_OVERLAP=0`
  turns this off for an A/B). Don't add fences or encoder splits between independent passes without a reason.
  Measure whole-frame time with `METALRENDERER_BENCH_SPLIT=0`.
* **CPU writes go to per-slot buffers.** Three frames are in flight, and `slot = frameIndex % 3` indexes ring buffers
  (`tables[slot]`, `minLodBuffer(slot:)`, `feedbackBuffer(slot:)`). Writing a buffer the GPU may still be reading is
  a race, not just a slowdown.
* **Small constants go through `setBytes`** (`Uniforms`, denoise uniforms): under 4 KB and no buffer to manage.
* **Bind resources the GPU reaches indirectly** (argument tables, TLAS → BLAS) with one batched `useResources(_:usage:)`
  or `useHeap` per encoder (`Renderer.bindScene`), not one call per resource.

## 2. Memory bandwidth: the default suspect for screen-space passes

Temporal, à-trous, composite, fog injection and integration, and the upscalers read and write several full-screen
textures per pixel and do little math. To speed them up:

* **Shrink formats.** `rgba16Float` is the norm (34 uses). The remaining `rgba32Float` / `rgba32Uint` textures are
  motion, surfacePos, moments, the ReSTIR reservoirs and the RC probe positions (Renderer.swift:63–212,
  RadianceCascades.swift:68). Each is worth questioning:
  * Can positions be reconstructed from depth?
  * Can motion be stored as `rg16Float`?
  * Can a reservoir's fields be packed?

  Check every precision change with the matching quality mode.
* **Read only the channels you need.** Split rarely-read channels into their own texture rather than widening a hot
  one.
* **Use `.read(tid)` for exact texels.** `sample` is only for filtering (bilinear reprojection, upscaling).
* **Fuse.** A new per-pixel pass costs at least one full-screen write and one read. Fold it into the kernel that
  already reads the same inputs, as the composite does.
* **Lower the rate.** Use a lower resolution (render scale, ReSTIR GI's quarter budget), fewer passes (à-trous pass
  count), or temporal accumulation.
* **Texture usage flags:** request `.shaderWrite` only where the texture really is written. Read-only textures can
  stay losslessly compressed. For private textures uploaded once (material textures, sky maps), call
  `blit.optimizeContentsForGPUAccess(texture:)` after the upload. This is unused so far and needs an A/B.
* **Streaming:** sparse textures in an `MTLHeap` with GPU mip feedback (TextureStreamer.swift) keep memory bounded.
  Feedback writes use relaxed atomics (`sampleMaterial`, Shaders/Surface.metal). Keep them sparse.

## 3. Occupancy and registers: the default suspect for big kernels

`traceKernel`, the ReSTIR DI and GI kernels and the path tracer carry a lot of live state. When registers run out,
fewer threads run at once and memory latency stops being hidden.

* Keep live variables few and short-lived. Recompute cheap values instead of carrying them across a trace call.
* Avoid dynamically indexed local arrays and run-time vector indices (`v[g]`) **inside a loop over many items**:
  they become stack memory traffic per iteration. Use vector lanes with `select`, and `dot(v, groupMask(g))` /
  `v += groupMask(g) * x` for a channel picked at run time (`groupMask`). Measured (stress hall, 1024
  lights): manyLightsKernel −8% with one ray, −14% with two; composite −12%.
* Outside such loops the same rewrite is neutral: don't bother. A small array written once and read a few times is
  cheaper than reading its contents again from textures: ReSTIR's spatial kernels keep ~1 KB of neighbour surfaces
  and reservoirs in arrays, and re-reading them instead cost +0.1–0.2 ms (DI) and +11% (GI spatial).
* **Pick a sample by what it estimates.** A sample's value / pdf is only bounded when the pdf follows the integrand.
  reflectionKernel picked its direct-specular light by diffuse light and then clamped the bright samples that made:
  highlights 2–6% dark and noisy. Picked by specular light (`pickLightSpecular`), no clamp is needed (+5 to +16 dB
  on `speccheck`'s SVGF rows). A firefly clamp downstream of a mismatched pdf is a bias, not a fix.
* Kernel timings shift by ±0.3 ms with unrelated edits to the same kernel (the compiler lays it out differently).
  Trust only alternating A/B rounds of the pass's own column (`ab.sh -c "<pass>"`).
* **Compile out what's off.** Copy these patterns:
  * kernel variants, for anything a configuration fixes for every frame. Test a bit of `Uniforms.flags` with
    `flagOn(u.flags, FLAG_X)` and a bit of the kernel's own flag word with `passOn(word, X)` (Shaders/Types.metal), and name
    the bit in `Kernel.fixedFlags` / `fixedPassFlags` (Pipelines.swift). `bind(enc, kernel, uniforms, pass:)` then
    picks the variant with those bits as function constants; it is compiled in the background on first use and the
    general pipeline (run-time tests) runs until it is ready. A bit left out of the masks is still correct, only
    not compiled in. A fact that is not a flag becomes one in a word made twice, in MSL and in Swift
    (`tracePassFlags`, `initialPassFlags`): keep the two identical, `swift test` checks the constants and
    measuring.md's safe-math diff checks the result.
  * function constants: `lightTypesConstant` / `LIGHT_SPEC` strips unused light types per scene;
  * preprocessor macros: `CUSTOM_RT`, `RT_STATS` (`Pipelines.compile`).

  A runtime `if (feature)` on a uniform is cheap for divergence, but both paths stay in the kernel. Measured
  (variants against general pipelines): what pays is a path with a **ray cast** in it. traceKernel with the bounce
  loop and the per-light shadow rays compiled out −24%; restirTemporalKernel without its visibility ray and
  restirSpatialKernel's merge-only passes −8% together; reflectionKernel without the references' second bounce −7%;
  restirGIInitialKernel with one bounce −13%. A flag that guards a texture read, a clamp or the blue-noise sampler
  is worth 0–2%: restirGISpatialKernel, rcTraceMergeKernel and meshLightsKernel got no variants for that reason, and
  a compiled-in bounce count measured the same as the uniform's. Don't give a bit that flips on a history's first
  frame (`*_VALID`) to the masks: its variant would be compiled for one frame.
* **Threadgroup size.** `Renderer.threadgroupSizes`. The defaults are 8×8, `trace` 16×8 (+2%)
  and `atrous` 16×16 (+5%). Sweep with `METALRENDERER_TG="trace=32x4,atrous=8x8"` and keep winners only if they hold
  across alternating runs.
* Use `half` where the range allows: denoiser weights, colours in filters, G-buffer normals. It halves register and
  bandwidth use. Write through `roundToHalf` when the target is 16F, as the existing kernels do.

## 4. Divergence and memory access patterns

* A simdgroup runs as slowly as its slowest lane. Keep loop trip counts uniform: fixed sample counts per pixel, and
  bounded traversal stacks. Variable-length work (traversal, many-light loops) is where divergence lives.
* Branch on data that's uniform across the simdgroup (`Uniforms`, the scene config) where possible.
* **Lay data out for one fetch per decision.** The BVH node (`BVHNode`, BVH.swift:6) is 64 bytes and holds both
  children's boxes, so one load tests two. The TLAS `hi.w` carries an OR of instance masks so rays skip whole
  subtrees. Apply the same thinking to new structures: pack what's tested together, and keep cold data elsewhere.
* Access 2D textures in 2D tiles (`dispatchThreads` with 2D threadgroups) for cache locality. Avoid scattered reads
  driven by per-pixel indirection unless that is the algorithm (ReSTIR spatial neighbours: few, bounded).
* Use RT_STATS (`METALRENDERER_RT_STATS=1`, or the Debug window toggle) to quantify traversal: nodes, instance
  entries, cluster entries and triangle tests per ray. A tree-quality change should move these numbers.

## 5. Reductions, atomics and threadgroup memory

* Atomics are relaxed throughout (`memory_order_relaxed`). Keep it that way unless ordering is needed: MSL 3.2
  device-scope fences are used in `rtFitKernel` for the bottom-up LBVH fit.
* **Simdgroup intrinsics aren't used yet.** `simd_sum`, `simd_prefix_exclusive_sum`, `simd_ballot`, `simd_shuffle`
  and `quad_*` replace threadgroup-memory round-trips and barriers in:
  * `skyMeanKernel` (threadgroup reduction of `sums[64]`);
  * `rtKeysKernel` (centroid bounds);
  * the LBVH sort (`rtSortLocalKernel`);
  * the ambient accumulations in `restirGISpatialKernel` (sparse grid) and `rcSHKernel` (per probe).
    These use one global atomic per thread: reduce per simdgroup, then let lane 0 add.

  Only worth it when the pass shows up in timings.
* **Threadgroup tiles:** `shadowTemporalKernel` (Shaders/Denoise.metal) loads a tile with an apron into `threadgroup
  half4` arrays, then filters from them. Use `half` in tiles, as few barriers as possible
  (`threadgroup_barrier(mem_flags::mem_threadgroup)`), and stay well below 32 KB per group so several groups stay
  resident.
* Prefix sums and compaction: do them in simdgroup → threadgroup → global order. Avoid a global atomic counter per
  element.

## 6. Math

* Precompute per-frame constants on the CPU and pass them in `Uniforms`: matrices, reciprocal sizes, sun and sky
  terms (`Atmosphere.swift` mirrors shader constants for this).
* Avoid integer `/` and `%` by non-constant divisors in hot code. Use powers of two with shifts and masks, or
  precomputed reciprocals.
* Prefer `select`, `mix`, `fma` and `saturate` over branches for small, value-dependent choices.
* Fast math is Metal's default. Be deliberate where precision matters: the closed-form area lights and the sky
  integrals are checked by `lightcheck` and `skycheck`. Re-run those after touching their math.

## 7. Acceleration structures and ray tracing

* Static geometry: build once (the static TLAS, per-mesh BLAS with binned SAH).
* Moving instances: the custom tracer rebuilds an LBVH on the GPU every frame (`CustomRayTracer.swift`). Metal's TLAS
  refits, with a full rebuild every `METALRENDERER_TLAS` frames (16 by default). Compare tree quality against
  build cost with `METALRENDERER_RT_BUILD=cpu` (binned SAH, a better tree).
* Virtual geometry swaps per-instance BLAS on a background thread. Keep cut changes rare (`slack` in
  VirtualBLAS.swift), because every rebuild costs CPU and memory churn.
* Shadow rays: they are any-hit and terminate early. Many-light sampling replaces one ray per light; ReSTIR reuses
  samples. Ray count is the main budget on M1/M2.

## 8. Pipelines and resources

* Compile off the frame path and off the main thread. `Pipelines` (Pipelines.swift) is the whole set as one value:
  a scene load (`prepareScene`) or a hot reload (`reloadShaders`) builds the next set on a background queue, all
  kernels in parallel, and the renderer swaps it in between two frames. A new kernel is one `Kernel` case named
  after its function (`trace` ↔ `traceKernel`).
* The set is keyed by tracer and light types (`Pipelines.kind`, `.lightTypes`). Its library is reused when only the
  light types change.
* Metal caches compiled pipelines on disk, shared by every build of the app: a warm build of all 47 takes 2–6 ms.
  Cold, the source compile takes 1.9 s and the pipelines 0.5–0.7 s in parallel (0.9–1.2 s one by one: the compiler
  service gives less than 2× for 47 at once). To measure a compile change, edit a constant in a scratch copy of the
  shader so it misses the cache, with a different edit for each side of the A/B.
* Use private storage for GPU-only buffers and textures (scratch, intermediate targets), and shared storage for
  CPU-written data. There is no managed storage on Apple silicon.
* Untracked hazard tracking with explicit fences can remove driver overhead, but it's unused here and easy to get
  wrong. Adopt it only with an A/B that shows a win, plus `pngdiff.py` proof that the frames are identical.

## 9. GPU tools

* **Debug window** (I or ⌘I):
  * frame graph (blue = GPU ms, orange = CPU frame interval);
  * GPU pass timings, averaged over half a second, with fenced encoders and "other" = MetalFX, its drawable copy and
    texture streaming;
  * memory, texture streaming, virtual geometry and ray-traversal counters.
* **Xcode GPU frame capture:** run with `MTL_CAPTURE_ENABLED=1` from Xcode (open `Package.swift`, Release scheme),
  then capture a frame. It shows per-kernel occupancy, limiter counters (ALU, texture, buffer read/write), register
  counts and memory traffic. This is the tool for "why", after the benchmark has said "where".
* **Instruments Metal System Trace** shows CPU/GPU overlap, stalls and command buffer gaps:
  ```bash
  xcrun xctrace record --template 'Metal System Trace' --time-limit 10s --launch -- .build/release/MetalRenderer
  ```
