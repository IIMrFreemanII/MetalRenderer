# MegaLights-style direct lighting (new `DirectLightMode.megalights`)

## Context
ReSTIR DI is the default above 256 lights. It costs too much: 8.9–12.8 ms of a
17–26 ms frame in the night city, and about 4.4 ms more than Grouped at 1
light. It also looks worse: 2.3–2.9 dB below Grouped on still frames and
4.2–5.7 dB below in motion. It traces 4 shadow rays per pixel, and its reuse
correlates samples, so SVGF has to blur them.

The user chose a MegaLights-style replacement (UE 5.5), built in this order:
1. Cull lights into screen tiles.
2. Draw a few light samples per pixel, at half resolution in the end, steered by
   which lights were visible last frame.
3. Trace one shadow ray per sample.
4. Shade each full-res pixel from its own and its neighbours' samples.
5. Denoise.

The target is about 1 shadow ray per full-res pixel instead of 4, with no
reservoir reuse chain.

The new mode sits next to ReSTIR and does not replace it. `auto` changes only if
the benchmarks below say so.

**Known risk.** The noise is still in the radiance, as with ReSTIR, so the
quality gain over ReSTIR is not guaranteed. It has to be measured. Grouped wins
because its unshadowed term is exact. The tile light lists built here would also
let Grouped scale, which is a possible follow-up and not part of this plan.

## Design

### Light influence range (new; nothing in the codebase has a cutoff)
- Compute it in the shader from the light record, so `Light` stays at 64 B:
  - Sphere, spot and tube: `r = sqrt(lum(I) / (π·E_cut))`.
  - Rect: intensity ≈ `lum·w·h`, plus a half-space test, because rects are
    one-sided.
  - Mesh light: `lum(color)/π` as intensity, plus the bounding-sphere radius.
  - Spot: sphere test first; add a cone test later if the lists are too long.
  - Suns stay out of the lists, keeping today's separate sun candidate
    (`LightSampling.metal:60`).
- **Unbiased by construction.** The range steers sampling only and never cuts
  light off. Of the N samples per pixel, one is always drawn from the global
  alias table (`sampleLightTable`, `Lights.metal:501`). The samples are then
  combined with multi-sample MIS (balance heuristic,
  `1/(n_local·p_local + n_global·p_global)`).
  - A light is "in" the local distribution when it is in the tile's sorted
    list (binary search) **and** passes the per-pixel range test. So
    `p_local` can be computed for any light, including lights lost to list
    overflow.
  - `E_cut` therefore trades only variance against cost, never brightness.

### Pass 1: tile cull (`megaLightsCullKernel`)
- One 16×16 threadgroup per 16×16 render-res tile.
- **Depth range:** reduce min/max view depth in threadgroup memory, from
  `normalDepth[cur].w`, skipping sky (`surfacePos.w == 0`).
- **Frustum:** build the tile frustum from `camPos`, `camRight`, `camUp`,
  `camForward` and their tan(fov/2) (there are no matrices,
  `Types.metal:5-28`).
- **Test:** loop over all non-sun lights, strided over 256 threads. Test each
  influence sphere against the tile frustum and depth range, and append to a
  threadgroup list.
- **Write:** bitonic-sort the indices, then write `count` + up to `capacity`
  uint16 indices to a device buffer. Overflow is safe because of the global
  fallback.
- Size at 640×400: 1000 tiles × 256 × 2 B = 512 KB.

### Pass 2: sample + trace (`megaLightsSampleKernel`)
- Phase 1 runs it at full res; phase 3 moves it to half res.
- **Inputs:** load `ShadingPoint` with `restirSurface` (`RestirDI.metal:50`).
- **Local samples:** run a streaming weighted-reservoir pick over the tile list,
  drawing N−1 samples (default N = 4, fixed lanes; no dynamically indexed local
  arrays, because ReSTIR is already short of registers).
  - Weight = `lightSampleTarget(evalLightSample(...))` (`LightSampling.metal:20-48`)
    × guide factor × per-pixel range test.
  - Mesh lights: pick the light, then a triangle by its CDF
    (`sampleMeshLightPoint`, `Lights.metal:305`).
- **Global sample:** draw one more from the table.
- **Sun:** one sun sample, as today.
- **Shadow ray:** `isVisibleBlocker` / `isVisible` (`Lights.metal:30-44`), with
  the sun's `sunVisibilityScale`.
- **Output:** an rgba32Uint `texture2d_array`, one slice per sample: light
  index (16 bit) and visible bit, uv (2×16 bit), and the MIS-weighted 1/pdf.
- **Guide feedback:** for visible samples, `atomic_or` into this frame's
  per-tile 128-bit visible-light hash (4 × uint, ping-pong buffers).
  - Next frame, lights whose bit is clear get weight × `guideWeight`.
  - The factor is never 0, and global samples see the same factor, so it stays
    unbiased.
  - The hash is looked up at the same tile; reprojecting it is a later tweak.
- **Seed:** new `SEED_MEGALIGHTS` salt, with a new blue-noise dimension range
  after 128 (`Sampling.metal`).

### Pass 3: resolve (`megaLightsResolveKernel`, full res)
- **Phase 1:** each pixel uses only its own samples.
- **Phase 3:** each pixel gathers the samples of its 2×2 nearest half-res
  pixels.
  - Weight them by `sameSurface` / `geometryWeights` (`LightSampling.metal:105`,
    `Denoise.metal:136`), normalised. Weights that do not depend on the samples
    keep it unbiased.
  - Each sample contributes `evalLightSample(exact:true)` at *this* pixel ×
    V × 1/pdf. A neighbour's pdf is a valid importance-sampling pdf here.
  - The only bias is visibility traced from the neighbour's point.
- **Firefly clamp:** `fireflyScale`.
- **Outputs:** albedo-free diffuse goes to `t.direct`. Specular goes to a
  specular texture that `reflectionStages` consumes, as `restirGrid.specular`
  is now (`Renderer.swift:2280-2286`, `Reflections.metal:98-99`).

### Denoise
- Diffuse: a new `DenoiseSignal` config in `denoiseSignals`
  (`Renderer.swift:2456-2483`), with its own σ, passes, history and
  varianceBoost.
- Specular: rides the reflection signal.
- Skipped when `plan.neuralDenoise` (MetalFX takes the raw signal).

## Integration (follow the ReSTIR wiring; refactor-skill rules)
- **Settings (`Settings.swift`):**
  - Add `DirectLightMode.megalights` as the last case. The env name comes from
    `EnvNamed`.
  - Add `MegaLightsSettings`: samples 2/4/8, list capacity, `E_cut`, guiding
    on/off, `guideWeight`, half-res on/off, neighbour resolve on/off, and
    denoise σ/passes/history/boost.
  - Add a `megalights` field on `RenderSettings`.
- **Env and settings table:**
  - `EnvVariable.megalights` (`METALRENDERER_MEGALIGHTS` list, after `.scene`).
  - Add it to `Benchmark.Config.resolvedSettings` (`Benchmark.swift:103`).
  - New rows in `SettingsTable.swift:367-403` with a `megalights` `When`.
  - `SettingsPanel.swift:377-381` caption.
- **Frame plan (`Renderer.swift`):**
  - Plan fields `megalights`, `megaLightsTargets`, `megaLightsHistory` and
    settings, set in `planFrame` (`:1797-1897`).
  - Turn off `meshLights` and `manyLights` as ReSTIR does (`:1875`, `:1879`).
  - Keep `lightGrid` built in this mode too, because secondary hits'
    `sampleLightsRIS` uses it (`:1905`).
  - `finishFrame` sets the history-written flag. Reset it where ReSTIR's is
    reset (`:739`, `:842`, `resetGIState`, target reallocation).
- **Stages:** `megaLightsStages`, plus a `FrameStages.megalights` field added to
  both the serial list and the overlap chain (`:1951-1960`, `:2015-2046`).
- **Targets:** allocate them in the plan (sample array, specular, tile lists,
  hash ping-pong). Resize like `restirTargets()` (`:2820`).
- **Flag:** `FLAG_MEGALIGHTS` in `UniformFlags` and `Types.metal`, plus the
  `KernelVariantsTests` pairing. Handle every `FLAG_RESTIR` site that means
  "direct comes from a separate pass":
  - `Trace.metal:141`
  - `Reflections.metal:98`
  - `Output.metal:214-221`
- **Kernels:** cases in `Pipelines.swift` (before `rtPrep`), a new
  `Shaders/MegaLights.metal` included after `RestirDI.metal` in
  `Shaders.metal`, and a `GPUMegaLightsParams` struct with size asserts on both
  sides (`GPUTypes.swift`).
- **Encoding:** only through `ComputePass`, so Metal 3 and Metal 4 both work.
- **`auto`:** unchanged in this plan.

## Phases
1. **Plumbing + cull + full-res sample/trace + own-sample resolve + SVGF.**
   Gate: `restircheck` mean ≈ 1.00 against exact for every light type.
2. **Guiding hash.** Gate: `restirq` and `marketq` dB do not go down.
3. **Half-res sampling (rotating 2×2 representative) + 2×2 neighbour
   resolve.** Gate: timing win, with the dB cost recorded.
4. **Tuning:** sweep N, `E_cut`, capacity and `guideWeight`. Record the results
   in the README's direct-light section. Then decide about `auto`.

## Benchmarks and eval
- Add `megalights` to the `restir` timing mode and to `restirq`, `marketq`,
  `restircheck` and `speccheck` (`Benchmark+Modes.swift`).
- Add it to the `restir.py` mode tuple.
- The ground-truth refs are unchanged, so don't re-render them.

## Verification
- **Builds and tests:** the tests skill's `scripts/related.sh`, covering
  SettingsTableTests, BenchmarkModesTests, ShaderSourceTests and
  KernelVariantsTests.
- **Headless renders only** (`METALRENDERER_BENCH`):
  `scripts/render.sh -m restirq -o $SCRATCH/q METALRENDERER_DIRECT=megalights`,
  likewise `restircheck`, `marketq` and `speccheck`, then
  `python3 Tools/eval/restir.py`.
- **Timing:** `scripts/ab.sh -n 3` on the `restir` mode against a baseline
  copy, in the stress scene at 1, 256, 4096 and 16384 lights, the market and the
  night city.
- **Other modes unchanged:** `scripts/same.sh` on `stressq`, `shadow`,
  `lightcheck` and `restircheck` with the default modes, plus a run with
  `METALRENDERER_API=metal4` (custom tracer; the Metal tracer with Metal 4 can't
  run on this M1 Max).
- Run `graphify update .` after code changes.
