# GPU (Metal / MSL) practices for MetalRenderer

Apple-silicon GPUs here: a unified memory architecture (no managed storage, no PCIe copies), 32-wide simdgroups, tile
memory, and counters that can be sampled only at encoder boundaries. M1/M2 have no ray-tracing hardware, so Metal's
intersector, the only tracer since the project's own BVH was removed (October 2026), runs in software there; M3 and
later traverse in hardware. A cost that comes from handing work back to the shader (boxes, non-opaque triangles)
looks very different on the two: measure on both before choosing (`METALRENDERER_BENCH=hwrt` for the plain cost).

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
  * preprocessor macros: `RT_STATS` (`Pipelines.compile`).

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
* **Lay data out for one fetch per decision.** The node of a cluster's tree (`BVHNode`, BVH.swift), which the ray
  queries walk in `METALRENDERER_VG_MODE=clusters` (`clusterWalk`), is 64 bytes and holds both children's boxes, so
  one load tests two. Instance masks let Metal's traversal skip whole instances. Apply the same thinking to new
  structures: pack what's tested together, and keep cold data elsewhere.
* Access 2D textures in 2D tiles (`dispatchThreads` with 2D threadgroups) for cache locality. Avoid scattered reads
  driven by per-pixel indirection unless that is the algorithm (ReSTIR spatial neighbours: few, bounded).
* Use RT_STATS (`METALRENDERER_RT_STATS=1`, or the Debug window toggle) to quantify traversal: the triangle and box
  candidates Metal's traversal hands the ray queries, per ray. Metal can't count its nodes, so those builds make every
  triangle non-opaque to count it (and trace slower). A change to what the structures hold (boxes, leaf cards,
  cluster boxes) should move these numbers; view 13 ("Traversal cost") shows them per pixel.

## 5. Reductions, atomics and threadgroup memory

* Atomics are relaxed throughout (`memory_order_relaxed`). Keep it that way unless ordering is needed. (The
  bottom-up tree fits that needed device-scope fences went with the custom tracer.)
* **Simdgroup intrinsics** (`simd_sum`, `simd_min` / `simd_max`, `simd_all`, `simd_is_first`,
  `simd_prefix_exclusive_sum`, `simd_ballot`) replace threadgroup-memory round-trips and barriers. In use:
  `shadowTemporalKernel` (`simd_all` to mark settled tiles). Every thread of a group must reach the call: no early
  `return` above it.
  * Don't expect a gain from them on a small pass. `rcSHKernel` adds four atomics per probe to one 16-byte buffer;
    with `simd_sum` and one add per SIMD group the frame measured the same (0.00 ± 0.02 ms, October 2026), so it
    kept its simple form. `restirGISpatialKernel`'s ambient sums are already 1 pixel in 64.
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

* Every ray goes through Metal's structures (`TraceScene.swift`: the kernels get the TLAS and what a hit reads at
  buffer 1). Per-mesh structures are built once with the scene, for fast intersection and compacted
  (`METALRENDERER_BLAS=default` turns that off).
* A still scene (`Scene.isStill`: nothing moves, no virtual geometry) builds its TLAS once, at default quality.
  Otherwise the TLAS refits each frame, with a full rebuild every `METALRENDERER_TLAS` frames (16 by default) and
  whenever a descriptor names another structure (a new virtual-geometry cut, a plant's other variant or voxel level).
  `METALRENDERER_TLAS_BUILD` picks its build quality.
* Refits are not free per structure: on the M1 Max about 0.09 ms each, whatever its size (the crowd's pose slots).
  The plants' wind refits each variant a plant names in an encoder of its own (`PlantTracing.refit`): two to an
  encoder are no faster there, and four crash the M1 Max's driver. 232 refits plus the posing are ~11.6 ms of the
  forest's frame on that GPU: fewer variants named is the lever, not tighter kernels.
* Virtual geometry swaps a per-instance BLAS (`VirtualBLAS`): the cut on the CPU, the cut's triangles gathered into a
  buffer, Metal's build on a queue of its own (so frames never wait behind it), then a TLAS rebuild. Keep cut changes
  rare (`slack` in VirtualBLAS.swift): every rebuild costs CPU, GPU and memory churn, and an uncompacted BLAS is about
  twice the custom tracer's old tree (107 vs 53 MB for 418k triangles).
* What Metal's traversal hands back to the shader is the cost to watch in software: bounding boxes (far plants'
  voxels, SDF shapes, `VG_MODE=clusters`' cluster boxes) and non-opaque triangles (leaf cards, alpha-tested by
  `rtCutout`) turn the queries into intersection-query loops. On the M1 Max leaf cards take the forest from 70 to
  223 ms, and clusters mode is ~6× the BLAS mode. Re-measure on hardware RT before drawing conclusions.
* Shadow rays: they are any-hit and terminate early. Many-light sampling replaces one ray per light; ReSTIR reuses
  samples. Ray count is the main budget on M1/M2.

## 8. Pipelines and resources

* Compile off the frame path and off the main thread. `Pipelines` (Pipelines.swift) is the whole set as one value:
  a scene load (`prepareScene`) or a hot reload (`reloadShaders`) builds the next set on a background queue, all
  kernels in parallel, and the renderer swaps it in between two frames. A new kernel is one `Kernel` case named
  after its function (`trace` ↔ `traceKernel`).
* The set is keyed by API, the counters and the light types (`Pipelines.api`, `.stats`, `.lightTypes`). Its library is reused when only the
  light types change.
* Metal caches compiled pipelines on disk, shared by every build of the app: a warm build of all 47 takes 2–6 ms.
  Cold, the source compile takes 1.9 s and the pipelines 0.5–0.7 s in parallel (0.9–1.2 s one by one: the compiler
  service gives less than 2× for 47 at once). To measure a compile change, edit a constant in a scratch copy of the
  shader so it misses the cache, with a different edit for each side of the A/B.
* Use private storage for GPU-only buffers and textures (scratch, intermediate targets), and shared storage for
  CPU-written data. There is no managed storage on Apple silicon.
* Untracked hazard tracking with explicit fences can remove driver overhead, but it's unused here and easy to get
  wrong. Adopt it only with an A/B that shows a win, plus `pngdiff.py` proof that the frames are identical.

## 9. Shader helpers: use them, don't copy

A new kernel starts from these (each replaced several hand-written copies; all are `inline` and compile to what the
copies did, checked bit for bit under `METALRENDERER_MATH=safe`):

| Need | Helper | In |
|---|---|---|
| The scene bundle from the kernel's bindings | `sceneData(...)`, `sceneLights(...)` for kernels that trace no surfaces, `bindLightSampling(s, u.lightTable, regirGrid, regir)` | Surface.metal |
| The sample stream | `makeSampler(blueNoise, u, pixel, dimension, seed)` with `pixelSeed(tid, frame, SEED_*)`; a kernel gets its own dimension range and salt | Sampling.metal |
| One item by weight, in one pass | `StreamPick` (`streamPick(u)`, `offer(w)`, `total`) | Sampling.metal |
| A diffuse bounce | `sampleBounce(n, ng, u)` | Sampling.metal |
| The firefly clamp | `x *= fireflyScale(u, luminance(x))`, or `fireflyScale(lum, limit)` for a limit that is a setting | Sampling.metal |
| A point on a light-table triangle | `triangleLightPoint(s, lights, tris, index, uv, prev)` | Lights.metal |
| RIS candidates from the grid, the table and the suns | `lightCandidate(...)`, `lightCandidateWeight(...)` | LightSampling.metal |
| "Is this the same surface?" | `sameSurface(nd, depth, n, tolerance, minCos)` with `REUSE_*`, `FEEDBACK_*`, `REFLECTION_*` | LightSampling.metal |
| Last frame's pixel of a pixel | `reprojectNearest(u, mv, n, prevND)` | LightSampling.metal |
| The pixel that shows a world point | `surfacePixel(...)`, `lastFramePixel(u, prevPosition, n, prevND, q)` | LightSampling.metal |
| Spatial reuse | `diskNeighbour(...)`, `pairwiseMIS(...)` | LightSampling.metal |
| Edge stopping on depth and normal | `depthGradient(...)`, `geometryWeights(...)` | Denoise.metal |

Rules that kept the refactor bit-identical, and keep a helper honest:

* A helper returns the factors, and the caller multiplies them in the order it always did: `a * b * c` and
  `a * (b * c)` round differently (`geometryWeights` returns depth and normal weights as two values for this reason).
* A scale of exactly 1 is free: `x *= cond ? k : 1` is what `if (cond) x *= k` computed.
* Keep the order of random draws. ReSTIR DI's initial candidates draw in another order than the other two candidate
  loops (no table numbers for the suns, quantised uv), so they share only the weight.
* Verify with safe math on both sides (`pngdiff.py`: max 0.0 on every image), then time with the default fast math.

Three things look like copies and are not, because they differ in what they compute. Next-event estimation at a
path's hit: the path tracer, ReSTIR GI and the reflections take their branches in different orders, and `giLightIllum`
(the cascades, and the path tracer's light-map branch) draws 8 candidates and clamps where the others draw 4 and
do not. The ambient fixed point: 1024 in
the cascades, `RGI_AMBIENT_SCALE` (256) in ReSTIR GI. The distance floor of a light sample: 1e-6 at surfaces, 1e-4
in fog. Making any of them alike changes images, so it is a change to measure, not a clean-up.

## 10. GPU tools

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
