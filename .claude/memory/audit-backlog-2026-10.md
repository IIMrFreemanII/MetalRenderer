---
name: audit-backlog-2026-10
description: Codebase audit of 2026-10-03: what was done (safety + market CPU batch) and what is still open, with the plan file that lists every finding
metadata:
  type: project
---

A whole-codebase audit was done on 2026-10-03. The full findings (sections C GPU, B per-frame CPU, D structure, E load time, F housekeeping, each with file:line) are in `.claude/memory/plans/audit-backlog.md` under "Backlog".

Done on 2026-10-03 (uncommitted at the time): scene-loading data races, per-kernel seeds, threadgroup-size attributes, layout asserts, static light proxies (`Scene.LightMotion`), staging arrays for per-frame uploads, per-slot material buffers, the `cpu` benchmark column.

Also done on 2026-10-03: the shader spill items. C2 helped only where a loop over the lights surrounds the array or run-time vector index (manyLightsKernel, manyLightsReuseKernel, composite; `groupMask`). C1 (re-reading neighbours instead of arrays in the ReSTIR spatial kernels) was slower and was reverted; do not retry it.

Also done on 2026-10-03: D1 and D5. `Renderer.draw()` is an outline (59 lines): `planFrame` resolves a `FramePlan` once, stage builders read only the plan, `FramePasses` owns the encoders, `finishFrame` is the one place that sets next-frame flags. Every pipeline lives in `Pipelines` (Pipelines.swift, `Kernel` enum), built in parallel on a background queue by scene loads and by `reloadShaders` (now asynchronous, with a completion).

Also done on 2026-10-03: D2. `SettingsTable.swift` lists every setting once (key path, env name, panel row); `SettingsEnv` (export and parser) and `SettingsPanel` are built from it. The repo now has a test target (`swift test`, Tests/MetalRendererTests) with the env round trip.

Also done on 2026-10-03: D3. Benchmark modes are functions in `Benchmark+Modes.swift`, registered in `Benchmark.modes`; `Benchmark.Config` holds real `RenderSettings` (no mirrored fields) with modifiers (`still`, `reference`, `cameraMove`, `fog`, `sky`), and `resolvedSettings()` is a pure function with tests.

Also done on 2026-10-03: C4. Kernel variants: `flagOn` / `passOn` in Shaders.metal, `Kernel.fixedFlags` / `fixedPassFlags` and `KernelVariants` in Pipelines.swift (function constants 1 to 4, compiled in the background on first use, general pipeline until ready, benchmarks wait). Whole frames 1–7% faster (Night market with ReSTIR 19.2 to 17.8 ms). What pays is compiling a ray cast out of a kernel; flags that guard a texture read or a clamp are worth 0–2%, so ReSTIR GI spatial, the cascades' trace and mesh lights have no variants. Variants and general pipelines match bit for bit only under `METALRENDERER_MATH=safe`; that diff is the check after touching a flag.

Found while doing C4 and fixed on 2026-10-03: reflectionKernel never got `FLAG_SHADOW_DENOISER`, so with the shadow denoiser direct specular from analytic lights was counted twice. `planFrame` now sets the flag on the frame's uniforms. `METALRENDERER_BENCH=speccheck` + `Tools/eval/specular.py` check it (brightness over an accumulated reference = 1.00). The same check showed the SVGF direct-light path (shadow denoiser off) 2–6% dark: the reflection pass picked its direct-specular light by diffuse light and its firefly clamp cut the resulting bright samples. Fixed the same day with `pickLightSpecular` (pick by specular light, direct term unclamped). Trap found on the way: a benchmark reference's noise depends on the settings rendered before it in the run, so compare references across builds only with the same `METALRENDERER_BENCH_ONLY`.

On 2026-10-03 the user approved doing the rest in seven batches, one commit and push per batch (plan file, top section): shader split, shader duplication, launch time, small GPU items, per-frame CPU, load time, housekeeping.

Batch 1 done (D7): `Shaders.metal` is the entry file with `#include "Shaders/X.metal"` lines; `ShaderSource.load` splices the 18 pieces with `#line` markers (errors name the piece). Images identical, pipelines recompiled in 3 ms (compiled code unchanged).

Batch 2 done (D4): shared shader helpers (list in gpu-metal.md section 9), 224 images bit-identical under safe math. Timing lesson: any shader edit moves unrelated kernels by about 1% (the module compiles as one; a dead call in a kernel that doesn't run cost ReSTIR GI frames 0.1 ms), so a refactor's small delta needs a control edit and whole-frame 5-round A/Bs, not per-helper chasing.

Batch 3 done (E1, E5): first frame after 0.24 s instead of 1.15 s (after a shader edit: window at 0.15 s instead of 2.66 s). Blue-noise tile cached in ~/Library/Caches/MetalRenderer, settings panel built after the first frame (its layout costs 0.35 s), shaders compiled in the background at launch (`pipelines` is nil until then; `draw` returns early), fog noise and HDR sky image made in the background; benchmarks do everything up front. Tools added: the `Launch:` line, `METALRENDERER_SHADERS=<Shaders.metal>` (another copy of the shaders with the same binary), line-buffered stdout.

Batch 4 done (C3, C5, C6, C7): nothing kept but a stack-overflow counter (RT_STATS counter 7, none in any scene). Measured nil at whole-frame level: RT_STACK 48/128 (32 is 20% slower), skipping trace's overwritten writes, a constant sky ambient (upper bound), simd_sum in rcSHKernel, squarings for pow in the filters, half colour sums, removing the temporal fallback (upper bound). Do not retry these. Method that worked: shader variants in scratch copies run with `METALRENDERER_SHADERS` and the same binary, whole frame, 5 rounds.

Batch 5 done (B5, B7; B6 measured nil and dropped): scene resources declared once per encoder (34 to 18 us a frame in the market), clusters-mode page table copied per slot only on change (50 to 1.2 us), threadgroup sizes by `Kernel`. The texture streamer's per-slot staging buffer measured no gain: do not retry. The `cpu` column resolves only 0.1 ms; smaller changes need a scratch timer around the function in both builds.

Batch 6 partly done (E4, E6's parser, E3's builder), committed when the user asked to commit mid-batch: glTF parse 0.7 to 0.4 s, BLAS build 2.1 to 1.5 s (one binning pass for three axes, parallel emit, lock-free slots, parallel halves above 32768 primitives), same BLAS byte for byte. Tried and removed: an exact split for small nodes (no gain). Not done from batch 6: the BLAS disk cache (its condition holds: 1.5 s, most of the load with virtual geometry off) and the shared `CacheFile` reader/writer for `.mgv` / `.mgt`. Batch 7 (housekeeping: tests for layouts / alias table / BLAS check / VG check, pad0/pad1 renames, dead fields incl. `TextureStreamer.staging`, stale docs, panel redraws) is not started.

Still open after the batches: D6, D8, D9, B8's stage closures, the simplifier's heap, the grouped composite.

**Why:** the user asked "what needs refactoring, optimisations?" and chose the safety + market CPU batch first; the rest was explicitly left as backlog.
**How to apply:** when the user asks for more refactoring or optimisation, start from the plan file's backlog instead of re-auditing; verify line numbers, they drift. For refactors of data (settings lists, tables), the method that worked: build a scratch copy of the old code with a dump hook, dump the same thing from the new code, and diff, under several environments. The Metal ray tracer (`METALRENDERER_RT=metal`) is not bit-reproducible run to run, so `pngdiff.py` checks of a refactor only mean something with the custom tracer.
