# MetalGI: the rest of the audit backlog, in seven batches

## Context

The audit's safety fixes, the frame outline, the settings table, the benchmark registry, kernel variants and two specular fixes are done and pushed (`41cec73`). The user asked for the remaining list in the order proposed: shader file split, shader duplication, launch time, small GPU items, per-frame CPU, load time, housekeeping. Exploration on 2026-10-03 re-located every item (line numbers below are current) and changed three assumptions:

- A warm launch already gets the shader library from Metal's cache in about 2 ms; only a launch after a shader edit pays the compile (about 1.9 s library, 0.5 s pipelines). The every-launch cost is blue noise (about 0.5 s inside the first frame).
- With virtual geometry on (the default) big meshes never reach the CPU BLAS build, so a BLAS disk cache only pays for the custom tracer with virtual geometry off.
- `#line N "file"` works in `makeLibrary(source:)` and errors then name the file; a plain `#include "x"` does not resolve, so Swift must splice the files.

## Rules for every batch

- **Baseline:** `git archive HEAD` of the previous batch's commit into the scratchpad, `swift build -c release` there, run with `METALRENDERER_ASSETS=<repo>/Assets`, pass as `ab.sh --bin-a`. Never edit shaders or rebuild while a benchmark runs.
- **Measure:** `.claude/skills/performance/scripts/ab.sh`, 3 alternating rounds for GPU columns, 5 with `-c cpu` for CPU items. A speed item is kept only if it is beyond noise (0.2 ms or 1% of the pass); otherwise it is reverted and logged under the README's "what didn't help".
- **Image check:** refactors must give `Tools/eval/pngdiff.py` max 0 on the custom tracer. Where codegen may differ, run both sides with `METALRENDERER_MATH=safe`. Same `METALRENDERER_BENCH_ONLY` on both sides when references are compared.
- **Close-out:** `swift build -c release`, `swift test`, README and performance-skill notes where numbers or instructions change, `graphify update .`, memory file `audit-backlog-2026-10.md`.
- **Commits:** one commit per batch on `main`, pushed when its checks pass. Approving this plan is the go-ahead for those seven commits and pushes. Message trailer as usual.

## Batch 1: shader file split

Files: new `Sources/MetalRenderer/ShaderSource.swift`, `Shaders.metal` (becomes the entry), new `Sources/MetalRenderer/Shaders/*.metal`, `Pipelines.swift:192-209`, `Package.swift:13`, `Tests/MetalRendererTests/KernelVariantsTests.swift:8-23`.

1. `ShaderSource.load(_ entry: URL, lineMarkers: Bool = true) throws -> String`: resolves lines of the form `#include "…"` relative to the entry's folder (system `<…>` includes untouched). Emits `#line 1 "Shaders.metal"`, and per include on entry line n: `#line 1 "Shaders/X.metal"`, the text, a newline if the file lacks one, `#line n+1 "Shaders.metal"`. Throws on a missing file, a duplicate include, a quoted include inside a piece, or unbalanced `#if`/`#endif` in a piece.
2. `Pipelines.compile` reads through `ShaderSource.load`. The three callers (init, `makePipelines`, `reloadShaders`) do not change; R picks up new files without a Swift rebuild.
3. `Package.swift`: `exclude: ["Shaders.metal", "Shaders"]`.
4. Split by exact line ranges, order kept. The entry keeps lines 1-16 plus the include list. Pieces (current line ranges):

   | File | Lines | Holds |
   |---|---|---|
   | Types | 17-221 | structs, flags, `flagOn`/`passOn`, forward declarations |
   | Sampling | 222-347 | hashes, `Rng`, `Sampler`, `Ray`, `Hit` |
   | Intersect | 348-718 | Metal intersector and custom traversal (one `#if` block, kept whole) |
   | Surface | 720-1050 | `SceneData`, sky lookups, BRDF, materials, `traceSurface` |
   | Lights | 1051-1545 | light evaluation, picks, light table |
   | Regir | 1546-1676 | light grid |
   | LightSampling | 1676-1971 | `evalLightSample`, RIS, octahedral mapping, light maps, view directions |
   | Fog | 1972-2463 | |
   | Sky | 2464-2863 | atmosphere, clouds, noise |
   | Trace | 2864-3371 | trace, many lights, reuse, mesh lights |
   | RestirDI | 3372-3695 | |
   | RestirGI | 3696-4145 | |
   | Reflections | 4146-4334 | |
   | Denoise | 4335-4709 | SVGF temporal, à-trous, shadow denoiser |
   | Output | 4710-5222 | geometry debug, composite, accumulate, TAAU |
   | RadianceCascades | 5223-5504 | |
   | BVHBuild | 5505-5734 | plus an added `#endif` |
   | VirtualGeometry | 5735-5984 | with its own added `#if CUSTOM_RT` |

5. Tests: `KernelVariantsTests` parses `ShaderSource.load(...)`; new tests: every file in `Shaders/` is included exactly once; a broken snippet's error names its file.
6. Docs: README (80, 93, 197, 652-653, 756), `main.swift` help, shader header comment (says `Renderer.loadShaders`), Swift doc comments naming the file only where wrong, `.claude/skills/performance/**` (replace `Shaders.metal:NNNN` references with kernel names, since they drifted already).

Check: `load(entry, lineMarkers: false)` diffed against `git show HEAD:Sources/MetalRenderer/Shaders.metal` shows exactly the two added preprocessor lines; first launch prints a long source compile and a short pipeline build (compiled code unchanged); `stressq` and `gi` images identical to the baseline. Commit before building the next baseline, because `git archive` omits untracked files.

## Batch 2: shader duplication

All helpers must leave the arithmetic and the random-number draw order untouched. Check: `METALRENDERER_MATH=safe` on both builds, suites `stressq`, `restirq`, `gi`, `fog`, `marketq`, `speccheck`, `restirgicheck`, `vgdebug`: images identical. Then `ab.sh` whole frame on `restir`, `stress`, `gi`, `fog`: within noise, or the helper that costs is reverted.

| Helper | Replaces (current lines) |
|---|---|
| `makeSceneData(...)` full and lights-only forms, unset fields explicitly null | 12 hand-built `SceneData` (1648, 2333, 2430, 2905, 3338, 3478, 3594, 3867, 4232, 4750, 5277, 5347) |
| `makeSampler(pixel, frame, dimension, seed, …)` | 7 six-line `Sampler` blocks (2344, 2917, 3128, 3222, 3340, 3872, 4236); seeds unchanged, the ad hoc ones become named `SEED_*` constants with the same values |
| `clampFirefly(c, limit)` | 3086, 3367, 3951, 4331, 3686, 4134 |
| `sampleBounce(n, ng, u)` (cosine + mirror above the triangle) | 3050, 3884, 3940, 4194 |
| `trianglePoint(tri, transform, uv)` (point, unnormalised normal, area) | 1348, 1389, 1612, 1700, 2160 |
| `surfacesMatch(nd, nd, depthTol, normalTol)` + named thresholds (`REUSE_*` 0.1/0.9, `FEEDBACK_*` 0.05/0.8, `REFLECT_*` 0.03/0.7) and `reprojectNearest(...)` | 3235, 3487, 3984; tests at 3611, 4066, 3930, 5372, 4189 |
| `StreamPick` (the `u /= q` rescaling pick, scalar form) | 2189, 3258, 3349; the vectorised picks (1928, 3150) stay |
| `risCandidate(...)` step shared by the candidate loops | 1749, 2232, 3496 (grid share, table, suns), only as far as the draw order allows |
| `edgeWeights(...)` (depth gradient, depth and normal weights; power as argument) | `atrousKernel` 4496-4516, `shadowFilterKernel` 4680-4700 |
| `karrasSplit(...)`, `fitWalkUp` shared pieces, `boxToWorld` | `rtHierarchyKernel` 5664 / `vgHierarchyKernel` 5890; `vgToWorld` 5933 / `rtPrepKernel` 5536 |
| `pairwiseMIS` weights | 3626 / 4076, only if it stays bit-identical |

Also: drop the unused geometry bindings 2-5 from both fog kernels and `lights` from `rcProbeKernel` (shader side only).

Left alone on purpose, and written down in the README as observations: the three next-event branches differ in order, candidate count (4 vs 8) and clamp; the ambient fixed-point scale is 1024 in cascades and 256 in ReSTIR GI; fog uses a `1e-4` distance floor where surfaces use `1e-6`. Unifying any of these changes images, so it is not part of a refactor.

## Batch 3: launch time

Files: `main.swift:20-53`, `Renderer.swift` (init 424-470, `fillBlueNoiseTextureIfNeeded` 767, `fogNoise` 804, `skyImageFor` 911, `planFrame` 1500-1518, `bind` 1906, `draw` 1241, `reloadShaders` 2599), `BlueNoise.swift`, new `CacheFile.swift` (location helper only here; batch 6 adds the rest).

1. **Meter first:** print "first frame after N ms" (process start to the first frame's completion) plus init's split; record warm and cold (after a shader edit) numbers before changing anything.
2. **Window first:** order the window front, then create the renderer and panels on the next run-loop turn.
3. **Blue noise:** cache at `~/Library/Caches/MetalRenderer/bluenoise-128-s1.9-seed1-v1.bin`, read synchronously in init (64 KB). On a miss, generate on a background queue, write the cache, swap in a new filled texture on main and set `skyRefreshed = nil` (`skyKernel` reads the tile regardless of the flag). `FLAG_BLUE_NOISE` is set only when the texture is ready; while it is not, `bind` uses general pipelines so no throwaway variants compile. Benchmarks load or generate synchronously.
4. **Fog noise and the HDR sky image:** started in the background, used when ready (fog appears a few frames late; the previous sky stays while only exposure differs), benchmarks synchronous. Keep `skyImageFailed`.
5. **Asynchronous pipelines** (matters after a shader edit): `pipelines` becomes optional; init starts the build on `shaderQueue`; `draw` returns early before `frameSemaphore.wait()` while it is nil; completion assigns it and `customRT?.pipelines`; `createSceneResources` (618) and `reloadShaders` tolerate nil; benchmarks join before `applyBenchmarkConfig`; a compile failure prints the error and leaves R to retry instead of `fatalError`. The title shows "compiling shaders…".

Check: first-frame time warm and cold, before and after (table in README); `quick` and `stressq` images identical to the baseline; `METALRENDERER_VARIANTS=log` shows no variants compiled for the white-noise interval; delete the cache file and relaunch to test the miss path; a syntax error in a shader at launch shows the window and the error, and R recovers after the fix.

## Batch 4: small GPU items

Each is a hypothesis: measured alone, kept or reverted by the rule above.

| Item | Change | Measure on |
|---|---|---|
| Traversal stack | Add an overflow counter under `RT_STATS` (8th counter, `Shaders.metal:428-438`, Debug window). Try `RT_STACK` 48 and 32; keep the smallest with zero overflows on gallery, market and `vgdebug`, if it is faster. | `rt`, `stress`, `gallery` |
| Trace dead writes | Two new own-flags in `tracePassFlags` (compiled into variants): skip `outIndirect` writes when a GI technique overwrites every pixel (`rcResolveKernel`, ReSTIR GI shade pass); skip `outDirect` when ReSTIR's shade pass does, and its lit-pixel write when `manyLightsKernel` does. | `restir`, `gi` |
| Sky ambient | First bound the gain by temporarily returning a constant from `skyAmbient` (799). Only if it shows: compute once per frame and pass in `skyColor.w` + `post.zw` (free lanes) following the `skyMeanKernel` pattern. | `fog`, `sky` |
| One atomic per simdgroup | `rcSHKernel` (5436): `simd_sum` the four values, one thread per simdgroup adds. `vgCutKernel` (5832): `simd_prefix_exclusive_sum` for slots, one add per simdgroup; check `vgdebug` images and the overflow flag. The texture-feedback histogram and ReSTIR GI's ambient (already 1 in 64 pixels) stay. | `gi`, `gallery`, `vgdebug` |
| Filters | `pow(x, 128)` / `pow(x, 64)` (4516, 4700) as repeated squaring; `half` for the à-trous and shadow-filter colour math; the temporal kernel's 5×5 disocclusion fallback (4432) read once per tap. Rounding changes, so score with `Tools/eval/noise.py`, `shadow.py`, `stress.py` instead of pngdiff. | `denoise`, `shadow`, `stress` |

`rcResolveKernel`'s 80 reads per pixel are looked at only if `rc resolve` is above 10% of the `gi` frame.

## Batch 5: per-frame CPU

Judged by the `cpu` column: `ab.sh -n 5 -c cpu` on market (16384 lights, ReSTIR + reflections + fog) and gallery (streaming and virtual geometry on). Images identical.

- **Binds** (`Renderer.bindScene` 2244, `CustomRayTracer.bind` 381, `VirtualGeometry.resources` 401, `VirtualBLAS.resources` 95): per-slot `[MTLResource]` lists built once and rebuilt only when their owners change (a generation counter on the virtual BLAS set, the sky pair on sky changes).
- **Texture streamer** (`TextureStreamer.swift:43, 148-251`): the unused `staging` field becomes a per-slot staging buffer grown as needed; one resource-state encoder and one blit encoder per frame for all uploads (all maps first, then all copies).
- **Virtual geometry** (`VirtualGeometry.swift:246, 337, 377`): copy `groupPage` to a slot only when its generation is behind; keep `residentGroups` as a running count; skip the sort and scratch allocations when there are no requests.
- **Dispatch lookups** (`Renderer.swift:2505-2529`): threadgroup sizes in an array indexed by `Kernel` instead of a `[String: MTLSize]`.

Stage closures and `setTextures` literals are left unless the meter shows them after the above.

## Batch 6: load time

Measure first with `METALRENDERER_SCENE=gallery`, default and `METALRENDERER_VG=0 METALRENDERER_RT=custom`: the "Gallery: … loaded in", "Custom BVH: … built in" and "Textures: … ready in" lines, cold and warm caches.

1. **Lock-free loops:** per-slot writes through `withUnsafeMutableBufferPointer` (the pattern at `Pipelines.swift:166`) in `BVH.swift:204-218`, `VirtualGeometryBuilder.swift:163-234`, `TextureStreamer.swift:310-315`, `MaterialTextures.swift:16-33`.
2. **BLAS build:** two explicit children instead of the per-node array (`BVH.swift:176`); big meshes split into parallel subtrees below a serial top, stitched so the output is byte-identical (`build` also feeds the `.mgv` clusters, the virtual BLAS and the TLAS, so its result must not change); parallel triangle fill (231-233).
3. **glTF parsing** (`GLTFLoader.swift:252-336`): the component-type switch hoisted out of the element loop, a straight copy for float32 and for tightly packed data, primitives parsed in parallel, the second copy into SIMD arrays removed where the layout allows.
4. **BLAS disk cache**, only if step 2 leaves the build at 1 s or more and a quarter of the load in the virtual-geometry-off configuration (otherwise logged as not worth it): `meshSources` on `Scene` (set in `addModel`, `Scene.swift:858`), per-model `.mgb` with per-mesh relative nodes and triangle order plus a fingerprint (counts and a checksum of positions and indices) and a builder version, relocation shared with `VirtualBLAS.moved`, `METALRENDERER_BLAS_CACHE=verify` comparing bytes against a rebuild.
5. **Shared cache code:** `CacheFile` (location, tmp-then-move write, bounds-checked mapped reader) used by `.mgv` and `.mgt` with unchanged names and formats.

Check: `METALRENDERER_RT_CHECK=1`; `.mgv` files byte-identical after a forced rebuild; gallery benchmark images identical; load-time table before and after in the README.

## Batch 7: housekeeping

- **Tests** (no Metal device needed): GPU layout strides, also compared with the shader's `static_assert(sizeof…)` lines parsed from the joined source (`validateGPULayouts` stays as the start-up check); the light alias table (`LightTable.aliasTable`, 82-101: pdfs sum to 1 and the table reproduces them); the BLAS ray self-test moved to a static function on the builder and run on a procedural scene (`METALRENDERER_RT_CHECK` still calls it); the virtual-geometry build check and cache round trip on a procedural mesh in a temporary folder.
- **Names and dead fields:** `pad0`/`pad1` become `mask`/`virtualIndex` in `GPUInstanceData`, MSL `InstanceData` and `RTInstance` (both sides); remove `Uniforms.instanceCount` use (slot kept as reserved so the layout stays 256 bytes), the dead `padded` in `encodeLBVH` (303), the never-true `concurrent:` parameter (`GPUProfiler.swift:67`). Check the CPU-built TLAS path (`CustomRayTracer.rtInstance` 234 never sets the virtual index) with `METALRENDERER_RT_BUILD=cpu` on `vgdebug`, and fix it if virtual instances vanish.
- **Docs:** `gpu-metal.md:115` ("simdgroup intrinsics aren't used yet"), `cpu-swift.md` line references, key help in `main.swift:55-67` (keys 1-8, 9, 0, L, how to switch scenes), stage-numbering comments in `Renderer.swift:1679-1741`, the `VG_CHECK` doc comment (`VirtualGeometryBuilder.swift:307`).
- **Panels:** `FrameGraphView` redraws at most 30 times a second and draws from its ring buffers without building arrays (`DebugPanel.swift:388-446`); `SettingsPanel.update(from:)` writes a control only when its value differs, so a slider drag stops rewriting every control (343-347, 128-142).

Check: `swift test`; `stressq` images identical (the renames touch shader structs); `cpu` column unchanged with the Debug window open.

## Not in this plan

Texture-creation helpers and the à-trous chain, scene-builder cleanups, the eval scripts' manifest, stage closures and `setTextures` literals, the simplifier's heap, `.mgt` reuse for non-streamed textures, the grouped composite. They stay in the backlog below.

---

# Earlier plan (done on 2026-10-03): safety fixes + market CPU wins

## Context

A whole-codebase audit (findings kept as the backlog at the bottom) found two thread-safety bugs in background scene loading, a few latent GPU hazards, and per-frame CPU work that scales with the light count: every light proxy is treated as a moving instance, scene flags re-read the process environment several times per frame, instance/light arrays are reallocated every frame, and in the Night market the chasing bulbs force a full material upload each frame. The user chose to implement these first. Everything else stays in the backlog.

Rules in force: performance skill (measure before/after with `ab.sh`, quality scorer or `pngdiff.py`, no allocations in `draw`), `graphify update .` after code changes, README update where numbers/defaults change, nothing committed unless asked. The working tree already carries the uncommitted ReGIR work, so the A/B baseline is a copy of the current tree, not `HEAD`.

## Step 0: baseline and a CPU meter

1. Copy the tree to the scratchpad (exclude `.build`, `graphify-out`, `Assets`→symlink) and `swift build -c release` there: that binary is "A" for `ab.sh`.
2. Add `encodeMs` to `DebugInfo` (the wall time of `draw()` from `drawStart` L1299 to commit), shown in the debug panel next to `cpuMs`. The frame interval (`cpuMs`) is GPU-bound and hides CPU work that fits under three frames in flight, so this is the number the CPU items are judged by. Also make `METALRENDERER_BENCH` print it in the table as `cpu` (mean of `encodeMs`) so no Instruments run is needed.
3. Record before numbers, market at 4096 and 16384 lights, stress 32 lights:
   ```bash
   METALRENDERER_BENCH=restir METALRENDERER_BENCH_ONLY="market" .build/release/MetalRenderer      # per pass: watch `tlas`, `cpu`
   METALRENDERER_BENCH=restir METALRENDERER_BENCH_ONLY="market" METALRENDERER_BENCH_SPLIT=0 .build/release/MetalRenderer
   ```

## Step 1: safety (A-items), no image change except A3

| | Change | Where |
|---|---|---|
| A1 | Capture `settings.textureBudgetMB`, `settings.virtualGeometry.enabled`, `.poolMB` on the main thread into the `wanted`/`loading` tuple (a small `LoadRequest` struct) and pass them to `prepareScene` / `wantsVirtualGeometry`. No `settings` read on the global queue. | `Renderer.swift:618-660, 708` |
| A2 | `CustomRayTracer.init` gets an `instances: [Scene.Instance]` parameter (default `scene.instances`); `startLoadingScene` passes a copy taken on main when `reuse != nil`. The array is COW, so `scene.update` on main then copies once. The static TLAS, `dynSlot` and `virtualInstances` are built from the snapshot. | `Renderer.swift:645`, `CustomRayTracer.swift:107-175` |
| A4 | `guard raw.count > 0` around the two `baseAddress!` copies (instances, materials). | `Renderer.swift:1190, 1195` |
| A5 | `[[max_total_threads_per_threadgroup(N)]]`: shadowTemporalKernel 64, skyMeanKernel 64, rtKeysKernel 1024, rtSortLocalKernel 1024. Mention in `threadgroupSizes`' comment that `METALRENDERER_TG=shadowTemporal=…` must stay 8×8. | `Shaders.metal:4438, 2701, 5449, 5500` |
| A7 | Try `options.mathMode = .relaxed` (macOS 15+, else `fastMathEnabled = false` is too slow: skip) and A/B trace on stress 32 and market. If the cost is above noise (0.2 ms), keep fast math and replace the five `isinf`/`== INFINITY` tests with finite sentinels (`RT_MISS = 1e30f` style) instead. | `Renderer.swift:497-505`; `Shaders.metal:1779, 1785, 1965, 1974, 5711` |
| A8 | Preconditions in `validateGPULayouts`: `GPURegirParams` 96, `GPURegirReservoir` 16, `VGCluster` 80, `VirtualBLAS.Entry` 32; `MemoryLayout<Params>.stride == 48` at `VirtualGeometry.swift:245`. MSL `static_assert(sizeof(T) == N)` for RegirParams, RegirReservoir, VGCluster, VGParams, VGBlas, SceneShading (64 + 144), RTScene (96). | `GPUTypes.swift:186`, `Shaders.metal` next to each struct |
| A3 | `inline uint pixelSeed(uint2 tid, uint frame, uint salt)` plus named salts (`SEED_FOG_REF`, `SEED_TRACE`, `SEED_MANY_LIGHTS`, `SEED_RESTIR_DI`, `SEED_RESTIR_GI`, `SEED_RESTIR_GI_SPATIAL`), replacing the seven single-pixel seeds at 2373, 2847, 3057, 3148, 3400, 3790, 3917 with distinct salts (restirGIInitial currently equals manyLights). Give restirGIInitial `rng.dimension = 128` (manyLights keeps 64, meshLights 96, reflections 40). Bounce-indexed seeds (2987, 2992, 3817, 3820) stay. | `Shaders.metal:206-284` (Rng block) |

A3 changes ReSTIR GI's noise pattern: run `restirgicheck` (mean 1.00 ± 0.01) and `Tools/eval/restirgi.py`; `pngdiff.py` on a `stressq` run shows the other modes unchanged.

## Step 2: cheap per-frame and load wins

| | Change | Where |
|---|---|---|
| B1 | `usesLightTable` and `hasSpecular` become `lazy var`s (first read happens on main in `install`; builders only append during `init`). | `Scene.swift:116, 272` |
| B4 | Delete `prevLightBuffers` / `lastFrameLights`. The ReSTIR temporal stage binds `lightBuffers[(slot + maxFramesInFlight - 1) % maxFramesInFlight]` at index 10 when `restirWritten`, else the current slot (first frame after install/reset: the other slots hold stale or unsized data). The light table tail in that buffer is harmless; the kernel only indexes `lights[i]`. | `Renderer.swift:343-344, 675-676, 1154-1171, 1206-1211, 1710` |
| E2 | `lightQuadMesh` shared like `lightSphereMesh`; capsules cached in `[SIMD2<Float>: Int]` keyed by (length, radius). ~160 fewer meshes/BLASes in the market. | `Scene.swift:563-583` |

## Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6)

**B2.** Lights whose transform never changes leave the per-frame path and the dynamic TLAS.
- `Scene.Light` gains `isStatic` (transform fixed; the scale may still animate) and `scaleAnimation: ((Float) -> SIMD3<Float>)?`. New overload `addLight(_ kind:, color:, proxyMesh:, at pose: LightPose, scale: ((Float) -> SIMD3<Float>)? = nil)`: sets `current = pose`, writes the proxy transform immediately via `proxyTransform`, marks the proxy `Instance.poseAnimated = false`. The closure overload marks `poseAnimated = true` on its proxy.
- `Scene.Instance` gains `poseAnimated = false`; `addInstance` unchanged. `Scene` keeps `animatedInstances: [Int]` (animation != nil or poseAnimated) and `animatedLights: [Int]` (closure lights + suns) and `scaledLights: [Int]`, built once at the end of `init`.
- `Scene.update`: `prevTransform`/`animation` loop over `animatedInstances` only; pose loop over `animatedLights`; a scale loop over `scaledLights` that only updates `current.scale` and the proxy emission when changed.
- `CustomRayTracer.isStatic(inst)` becomes `inst.animation == nil && !inst.poseAnimated` (static light proxies join the static SAH tree with their `maskLights` mask; `staticMasks` already supports per-leaf masks). `dynSlot` therefore lists fewer moving instances and `rtPrepKernel` / the LBVH (`tlas` pass) shrink accordingly; the CPU-build path (`METALRENDERER_RT_BUILD=cpu`) picks it up through `dynamicIds`.
- Convert callers: every `addLight(` in `Scene+Lights.swift` / `Scene.swift` whose closure ignores `t` or uses it only for `scale` (market bulbs at `Scene+Lights.swift:688-703`: fixed position, chase scale; window/stall panels; Cornell-style `{ _ in pose }` lights). Lanterns, strings' sway, the stress hall and suns stay animated.
- The Metal-RT path (`writeInstanceDescriptors`) is unchanged.

**B3.** No per-frame arrays.
- `Scene.Instance.normalMatrix` cached: set in `addInstance`, recomputed in `update` only where the transform is written (`rtPrepKernel` reads it as the world→object rows, so it must stay exact).
- `gpuInstanceData()` → `writeInstanceData(into: UnsafeMutablePointer<GPUInstanceData>)` writing straight into `instanceDataBuffers[slot]`; `gpuLights()` → `writeLights(into: UnsafeMutableBufferPointer<GPULight>)` into `lightBuffers[slot]`; `updateSky(lights:)` takes the buffer pointer instead of an array. Keep `gpuInstanceData()`/`gpuLights()` as thin wrappers only if something outside the frame loop still needs arrays (LightTable builds from `scene.lights`, so probably nothing).
- `scene.instances.map(\.transform)` at `Renderer.swift:1410` → pass `scene.instances` (or a `(Int) -> float4x4`) to VirtualBLAS, which reads ≤ 256 of them.

**A6.** Per-slot material buffers with dirty ranges.
- `Scene.materialsChanged: Bool` → `materialsDirty: Range<Int>?` (merged min…max on each change; chase bulbs are contiguous so the range is ~¼ of the materials).
- `Renderer.materialBuffer` → `materialBuffers[slot]`; `shadingArgs[slot]` offset 0 points at its own; `shadingResources` lists all three. `pendingMaterialDirty: [Range<Int>?]` per slot: each frame merge the scene's range into all slots, copy this slot's pending range, clear it. Removes the in-flight race and cuts the per-frame copy from ~1 MB to the dirty range.

## Verification

```bash
swift build -c release
# GPU, whole frame, A = baseline copy, B = this tree (3 alternating rounds, medians)
.claude/skills/performance/scripts/ab.sh -n 3 -- METALRENDERER_BENCH=restir METALRENDERER_BENCH_ONLY="market" METALRENDERER_BENCH_SPLIT=0 -- <same, baseline binary>
METALRENDERER_BENCH=restir METALRENDERER_BENCH_ONLY="market" .build/release/MetalRenderer     # `tlas` and `cpu` columns before/after
METALRENDERER_BENCH=restir METALRENDERER_BENCH_ONLY="32 lights" .build/release/MetalRenderer  # stress unchanged
# Quality / unbiasedness
METALRENDERER_BENCH=restircheck .build/release/MetalRenderer && python3 Tools/eval/restir.py      # mean 1.00 ± 0.01, all rows
METALRENDERER_BENCH=marketq METALRENDERER_GI_REFS=0 .build/release/MetalRenderer && python3 Tools/eval/restir.py
METALRENDERER_BENCH=restirgicheck .build/release/MetalRenderer && python3 Tools/eval/restirgi.py   # A3
python3 Tools/eval/pngdiff.py <baseline stressq run> <new stressq run>                           # B/E items: identical images
```
Manual: run the app on the market (`METALRENDERER_SCENE=market`), switch ray tracer Metal↔custom a few times while the scene animates (A2), toggle virtual geometry (A1), check the debug panel's `encodeMs` at 16384 lights before/after. Then `graphify update .`, update README timing rows and the "How a frame works" text if `tlas`/whole-frame numbers move, note A7's outcome in a "What didn't help" line if it was reverted.

Expected: `tlas` pass and `encodeMs` drop in the market (most proxies static), whole frame within noise or better; stress unchanged; images bit-identical except A3's ReSTIR GI noise pattern.

---

# Backlog: the rest of the audit

(Findings verified in source where marked; costs are hypotheses until measured.)

### C. GPU
| # | Where | Problem | Fix |
|---|---|---|---|
| C1 | `Shaders.metal:3519-3543` (restirSpatial), `3969-3970` (restirGISpatial) | `nq[8]`, `ShadingPoint nsp[8]`, `Reservoir nb[8]` / `GIReceiver nrc[8]`, `GIReservoir nb[8]` indexed by runtime `count`: ~1 KB per thread spilled in register-bound kernels. | Keep only packed neighbour coords; re-read neighbour surfaces in the MIS loop. A/B `restir` + `restirq`. |
| C2 | `3059-3090`, `2952-2954`, `4802/4811` | Runtime trip count `rays` over `sel/s/picked/pickedWeight[MAX_RAYS_PER_GROUP]`; runtime indexing into `float4` by light group. | Fixed-length loops with guards; mask accumulation `float4(g == uint4(0,1,2,3))`. |
| C3 | `5334-5337`, `4052-4053`, `5717/5723`, `868` | One global atomic per thread (rcSH ×4 per probe, restirGISpatial, vgCut, material histogram). | `simd_sum` / prefix sum → one atomic per simdgroup. |
| C4 | trace (`FLAG_SPECULAR`, `FLAG_UPSCALE`, `FLAG_SKY_MAP`, `FLAG_BLUE_NOISE` in `Sampler::next`, `FLAG_LIGHT_MAPS`, `FLAG_NO_CLAMP`), restirTemporal (`RESTIR_*`), restirGIInitial (`RGI_*`, `quarter`), reflection, fogInject | Runtime branches on uniform flags inside register-bound kernels. | Function constants (the `LIGHT_SPEC` pattern) with a pipeline cache keyed by (kernel, mask), compiled async. After D5. |
| C5 | `764` → `2301, 2381, 4097, 4221`; `3012` | `skyAmbient` (2 sky samples) recomputed per froxel/pixel; trace zero-fills outputs another pass always overwrites (~2 MB/frame each). | Pass `skyAmbient` in `Uniforms`; skip dead writes by flag. |
| C6 | `4237-4424`, `4556-4604`, `5380-5391`, `4329-4345` | Filter passes all in `float`; `pow(x,128)`/`pow(x,64)`; temporal's disocclusion fallback up to 75 divergent reads; rcResolve 16 probes × 5 textures. | `half` filter maths; repeated squaring; a tile like shadowTemporal's; pack RC SH. |
| C7 | `rtTraverse` L495 | 64-entry dynamically indexed stack; overflow silently drops subtrees (521, 543, 557, 585). | Measure a smaller `RT_STACK`; count overflows under `RT_STATS`. |

### B. Remaining per-frame CPU
| B5 | `Renderer.swift:2076`, `CustomRayTracer.swift:355`, ×13 calls/frame | `bindScene` rebuilds `useResources` literals and `customRT.bind` concatenates arrays every call; redundant after the first per encoder (index 1 excepted). | Cache per-slot `[MTLResource]`; bind once per encoder. |
| B6 | `TextureStreamer.swift:229,43` | A new `MTLBuffer` per uploaded texture per frame (`staging` unused); one blit + one resource-state encoder per texture. | Per-slot ring staging buffer; one encoder of each kind per frame. |
| B7 | `VirtualGeometry.swift:239,335,375` | Whole `groupPage` table copied every frame; O(groups) `filter.count`; requests re-sorted every frame. | Residency generation per slot; incremental `residentGroups`. |
| B8 | draw path | ~25 `setTextures([...])` literals, 13–30 escaping `ComputeStage` closures each copying 256 B `Uniforms` (+608 B fog params), `threadgroupSizes[String]` ×25, `origins` L1517, `signals.map`, `RadianceCascades.stages` arrays. | Verify with Allocations first; cached texture lists, a `Kernel` enum, stage arrays as properties. |

### D. Structure / duplication
| D1 | `Renderer.draw()` L1298–2054, 757 lines | 14 blocks; state mutated mid-way (`restirGIWritten` L1585, `reservoirsWritten` L1681, `restirWritten` L1736, `accumCount` L1804, `fogLastFrame` L1888, `uniforms.flags |=` ×6); `activeGIMode` ~8×, `activeDirectMode` ~4× per frame. | `FramePlan` struct computed once; extract `regirStages / headStages / restirDIStages / denoiseStages / fogStages / schedule / encodeOutput / commitFrame` like `restirGIStages`; apply "written" flags at the end. |
| D2 | `Settings.swift`, `EnvExport.swift` (175-line `string`), `Benchmark.swift:100-361` (8 parsers), `SettingsPanel.swift` (68 actions, 110-control `update(from:)`) | 127 leaf settings each in 4–9 places; duplicated key strings unchecked; enum→name by `rawValue` index (`EnvExport:52,65`, `Benchmark:108,121`); fog/sky/restir parsers swallow unknown keys. | Keypath-driven `SettingSpec` table; EnvExport, parser and panel rows iterate it (~420 lines saved); round-trip test `parse(export(s)) == s`. |
| D3 | `Benchmark.configs(for:)` L423–955, 533 lines, 23 modes | 108 `Config(` literals; `paused: true, startTime: 5` ×55; refs ×26; the variant fan-out copied 4×; `Config` mirrors ~30 settings mapped back by hand (`Renderer.swift:2229-2250`). | Registry `[String: () -> [Config]]`, `.still(at:)`, `.reference(frames:)`, `variants(...)`; `Config` carries an `(inout RenderSettings) -> Void` patch. |
| D4 | Shaders | 12 hand-built `SceneData` (6 leave `lightTable`/`regirGrid` uninitialised), 7 `Sampler` setups; candidate loop ×3 (`1686, 2169, 3426`); stream pick ×6; emissive-triangle point ×4; NEE branch ×3 with different order and counts (8 vs 4); bounce mirroring ×4; reprojection ×3; spatial disk + pairwise MIS ×2; firefly clamp ×6; Karras split / fit kernels duplicated `rt*`/`vg*`; 20–26 bindings per big kernel; buffers 2–5 unused in both fog kernels. | Extend `SceneShading` (buffer 7) into a full scene argument buffer; templates `risCandidates<Target>`, `StreamPick`, `trianglePoint`, `sampleBounce`, `reprojectNearest`, `feedbackLookup`, `karrasSplit`; named thresholds (0.1/0.9, 0.05/0.8, 0.03/0.7; `1e-6` vs `1e-4`; `1024` vs `RGI_AMBIENT_SCALE`). |
| D5 | `Renderer.swift:515-584`, 32 `MTLComputePipelineState!` | `install` (L718) drains all slots then builds 47 pipelines serially on main when light types change or shaders reload. | `struct Pipelines`, built concurrently on the background queue inside `prepareScene`; `install` assigns atomically. |
| D6 | `Renderer.swift:52,146,174,203,122,896,2282,2292,691,845,941-956` | Texture creation copied >15×; size-reuse logic ~11×; à-trous chain written 4× (L1663, 1778, 1824-1826, 2126), rebuilt inside an encode closure. | `makeTexture(format:size:usage:label:)` + size-keyed cache; `atrousChain` on the targets. |
| D7 | single 5.9k-line `Shaders.metal` | No `#include` through `makeLibrary(source:)`. | `Shaders/*.metal` joined by Swift with `#line 1 "X.metal"` markers; hot reload kept. |
| D8 | Scene code | `demoCamera(.x)!` ×9; scene-kind name↔case ×3; three camera factories; `Kit` private while three builders hand-write walls; `SplitMix64` ×2; image→RGBA8 ×3; luminance weights ×7; cache-file I/O duplicated (VGBuilder/TextureStreamer); tuples `MeshGeometry`, VirtualBLAS `stats`/`current`/`finished`, `emitterSources`; `buildMarket` 123 lines, `GLTFLoader.load` 221, `MeshSimplifier.simplify` 228. | Mechanical cleanups. |
| D9 | `Tools/eval/*.py` | Run names hard-coded in 10 places vs Swift strings via the sanitiser (`Benchmark.swift:1048`); `noise.py:16`, `stress.py:41` crash on a missing capture; `CROP` ×3. | `manifest.json` from `encodeCapture`; `None`-safe helpers in `evalcommon.py`. |

### E. Load time
| E1 | `BlueNoise.swift:36-79`, `Renderer.swift:832, 870, 981` | ~0.5 s O(n²) blue noise generated inside `draw` on first use and every launch; `fogNoise()` ~50 ms; synchronous HDR `SkyImage.load`. | Disk cache (versioned); generate off the frame loop with dummies until ready. |
| E3 | `CustomRayTracer.swift:110`, `BVH.swift:202-243,176` | CPU SAH BLAS rebuilt every load (18M tris gallery), parallel across meshes only; `[n.left, n.right].enumerated()` allocates per node. | `.mgb` cache keyed like `.mgv`; parallel subtrees. |
| E4 | `BVH.swift:204,218`, `VirtualGeometryBuilder.swift:163,234`, `TextureStreamer.swift:310,314`, `MaterialTextures.swift:16,33` | `NSLock` inside `concurrentPerform`. | Disjoint preallocated slots. |
| E5 | `Renderer.swift:497-513` | 5.9k lines compiled synchronously + 47 serial pipelines per launch. | Async compile / `MTLBinaryArchive` (with D5). |
| E6 | `GLTFLoader.swift:246-279`, `MaterialTextures.swift:12-64`, simplifier/clusterizer | Serial parse, per-component type switch; textures re-mipped every launch; no heap in the simplifier. | Parallel parse, float32 fast path, `.mgt` reuse, min-heap. |

### F. Housekeeping
- Stale docs: `SKILL.md` line refs; "simdgroup intrinsics aren't used yet" is false; `SettingsPanel.swift:709` and `cpu-swift.md` mention a non-existent `encodeFrame`; `main.swift:62` help lists keys 1–6; stage numbering comments in `draw` out of order.
- `pad0`/`pad1` in `InstanceData`/`RTInstance` carry real data (mask, VG index): rename.
- Unused: `Uniforms.instanceCount`, `VGCluster.triangles`, `TextureStreamer.staging`, `padded` (`CustomRayTracer.swift:276`), `GPUProfiler.Frame.compute(concurrent:)` never `true`.
- Debug panel redraws `FrameGraphView` every frame on main; every slider tick refreshes all ~110 controls synchronously.
- No test target: layout preconditions, alias-table pdf sum, `RT_CHECK`/`VG_CHECK` self-tests and the D2 round-trip belong in XCTest.
