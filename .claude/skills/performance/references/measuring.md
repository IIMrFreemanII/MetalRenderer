# Measuring MetalRenderer

Everything runs from the repo root with a release build. The binary loads the shaders (`Shaders.metal` and the
pieces in `Shaders/`) from the source folder it was built from (`#filePath`, `Renderer.shaderURL`).

```bash
swift build -c release
METALRENDERER_BENCH=<mode> .build/release/MetalRenderer
```

A benchmark renders 60 warm-up frames and then 240 measured frames per setting, back to back without vsync. It prints
a table and quits. It runs offscreen: no window, no Dock icon, no focus change (the `offscreen` skill). Don't add
`METALRENDERER_WINDOW=1` (a window) unless the user asks to watch. The lists of settings are in `Benchmark+Modes.swift`: one function per mode, registered in `Benchmark.modes`. A
setting is a `Benchmark.Config`: real `RenderSettings` plus how the run goes, built with `.still()`,
`.reference(frames:)`, `.cameraMove()`, `.with { … }`. Setting names are PNG names the scorers look up: keep them. Benchmarks never
read or write the saved UI settings.

## Reading the table

```
setting  res  tlas  lightmap  trace  composite  MetalFX  rc probes  rc resolve  rc sh  rc trace  shadow filter  shadow temporal  GPU total  p95  max fps  span  cpu
```
(the `quick` table with radiance cascades)

* Columns appear only for passes that ran: `Benchmark.passOrder` (`tlas lightmap trace temporal atrous composite
  upscale`→`MetalFX`) first, then the GI/technique passes by name (`rc …`, `shadow …`, ReSTIR, fog…).
* Pass columns show the median ms over the measured frames. A pass that runs in several command buffers reports
  their sum.
* `GPU total` is the median of the summed passes, `p95` is that sum's 95th percentile, and `max fps` = 1000 /
  median.
* `span` runs from the first pass start to the last pass end, including the gaps between command buffers.
* `cpu` (the last column) is the CPU's own work per frame in `draw` (animation, uploads, encoding), without its waits
  for a frame slot and the drawable. Judge per-frame CPU changes by it: the frame interval is GPU-bound and hides them.
  The Debug window shows the same number as "encode".
  Read it in split mode. With `METALRENDERER_BENCH_SPLIT=0` a whole run lands at either 1× or 2× the value, for the
  same binary, so an A/B of `cpu` there needs five rounds or more to mean anything.
  * It resolves about 0.1 ms. For a change of tens of microseconds, time the code itself: in a scratch copy of each
    build, add two static accumulators around the function (`CACurrentMediaTime()` at its start, a `defer` that adds
    the difference), print "µs per frame" every 100 frames from `commit`, and compare the two builds' lines. That is
    how the scene binds (34 → 18 µs) and clusters mode's bookkeeping (50 → 1.2 µs) were measured.
* **Split mode** (the default) runs each pass in its own command buffer, so the frame is serialized and there's no
  overlap.
* **`METALRENDERER_BENCH_SPLIT=0`** encodes frames exactly as the app does, with one command buffer. It reports only
  a `frame` column. Quote this number for whole-frame claims.
* `METALRENDERER_OVERLAP=0` turns off the radiance cascades / denoiser overlap, for an A/B.
* To pull out columns:
  ```bash
  … | python3 Tools/eval/columns.py trace atrous "GPU total"
  ```

## Modes

**Timing:**
| Mode | What it times |
|---|---|
| `1` | the default list: GI bounces, denoiser, render scale, MetalFX |
| `quick` | the default setting, MetalFX temporal/spatial, camera moves, path traced, 0.75× native: fast smoke tests |
| `stress` | the stress hall against light count (1–256), object count (0–2000) and GI method |
| `restir` | 1 to 16384 lights for each direct-light method, plus the Night market |
| `rt` | custom BVH against Metal's intersector, alternating per setting |
| `gallery` | glTF gallery: full meshes against virtual geometry at 0.5/1/2 px, plus a fly-through (warm the caches first) |
| `gi` | each GI method (plus the path-traced references, unless `GI_REFS=0`) |
| `lights`, `fog`, `sky` | the light demo, fog and sky scenes, paused at t = 5 s and moving |

**Quality and correctness** (save PNGs with `METALRENDERER_BENCH_DIR=<dir>`, then score them):
| Mode | Scorer |
|---|---|
| `stressq` | `Tools/eval/stress.py` |
| `restirq`, `restircheck` | `Tools/eval/restir.py` |
| `restirgicheck` | `Tools/eval/restirgi.py` (mean brightness ratios should be 1.00) |
| `speccheck` | `Tools/eval/specular.py` (direct light with specular materials; mean should be 1.00) |
| `gi` | `Tools/eval/gi.py` |
| `shadow` | `Tools/eval/shadow.py` |
| `upscale` | `Tools/eval/upscale.py` |
| `noise` (references) + `denoise` | `Tools/eval/noise.py` |
| `gallery` | `Tools/eval/gallery.py` |
| `quality`, `fogcheck`, `skycheck`, `lightcheck`, `vgdebug` | inspect the PNGs; `pngdiff.py` between runs |

Scorers print PSNR in dB (higher is better) and flicker in 8-bit levels. References live in `Tools/eval/refs/<mode>/`.
A run that renders the "ref …" settings refreshes them. Skip them with `METALRENDERER_GI_REFS=0` once they exist.
A reference's noise depends on the settings rendered before it in the same run (the frame counter, which seeds the
samples, runs on): two builds render the same reference bit for bit only with the same `METALRENDERER_BENCH_ONLY`.
Re-render them only when the ground truth changes (the scene, lights, materials or light transport), never for a
pure speed change.

## Narrowing and overriding

* `METALRENDERER_BENCH_ONLY="32 lights|camera"` keeps only the settings whose names contain one of these substrings.
* `METALRENDERER_SCENE="stress,objects=400,lights=32"` loads that scene in every setting.
* Override strings apply to every setting. Their keys are the env names in `SettingsTable.swift` (one line per
  setting: add a setting there and it gets its key, its Copy as Env entry and its panel row); `SettingsEnv.apply`
  reads them and reports unknown keys:
  * `METALRENDERER_GI="mode=pt|cascades|restir,bounces=…,scale=…,factor=…,upscaler=metalfx|custom|spatial,on=0,…"`;
  * `METALRENDERER_DENOISE`, `_RESTIR`, `_RESTIR_GI`, `_FOG_SET`, `_SKY_SET`, `_VIEW`.
* Plain defaults: `METALRENDERER_RT=metal|custom`, `_DIRECT`, `_VG`, `_VG_TAU`, `_VG_POOL`, `_SPECULAR`,
  `_TEXTURE_BUDGET`, `_FOG`, `_SKY`.
* Performance knobs:
  * `METALRENDERER_TG="trace=16x8,atrous=16x16"` sets threadgroup sizes (a kernel by its `Kernel` case in
    Pipelines.swift, capitals and spaces aside);
  * `METALRENDERER_TLAS=<frames>` sets Metal's TLAS rebuild interval;
  * `METALRENDERER_RT_BUILD=cpu` builds the custom tracer's moving tree on the CPU with SAH;
  * `METALRENDERER_RT_STATS=1` turns on the traversal counters, printed per setting;
  * `METALRENDERER_VARIANTS=0` runs every kernel's general pipeline (no compiled-in flags), `=log` prints each variant
    as it is made;
  * `METALRENDERER_MATH=relaxed|safe` compiles the shaders without fast math (see "Kernel variants" below);
  * `METALRENDERER_VG_SYNC=0|1` forces background or synchronous cut updates.
* To reproduce an interactive state, use **Copy as Env** in the Settings panel. It puts the `METALRENDERER_*` lines
  that differ from the defaults on the clipboard.
* To compare two launches' settings, use `METALRENDERER_DUMP_SETTINGS=1`.

## Kernel variants

The big kernels run as variants with the configuration's flags compiled in (gpu-metal.md, section 3). What that
means for measuring:

* Benchmarks wait for a variant the first time a setting needs it, so every measured frame runs the same code. The
  app compiles them in the background and runs the general pipeline until they are ready: time a change in a
  benchmark, not in the first second after a settings change in the app.
* A variant is new code to Metal's shader cache. After an edit to a shader file, a setting's first frame takes a few
  hundred ms longer per variant (inside the 60 warm-up frames; the table is not affected).
* `METALRENDERER_VARIANTS=0` against the default, same binary, is the A/B for "what do the variants buy here".
* **Checking that a variant computes what the general pipeline computes.** Under fast math the two differ by
  rounding (the compiler orders the arithmetic of different code differently): `pngdiff.py` shows max 1 level and RMS
  around 0.005 on most images, and a few pixels of up to 60 levels where a stochastic pick flipped. With
  `METALRENDERER_MATH=safe` on both sides they must match bit for bit:
  ```bash
  METALRENDERER_MATH=safe METALRENDERER_VARIANTS=0 METALRENDERER_BENCH=stressq METALRENDERER_GI_REFS=0 METALRENDERER_BENCH_DIR=/tmp/off .build/release/MetalRenderer
  METALRENDERER_MATH=safe METALRENDERER_BENCH=stressq METALRENDERER_GI_REFS=0 METALRENDERER_BENCH_DIR=/tmp/on .build/release/MetalRenderer
  python3 Tools/eval/pngdiff.py /tmp/off /tmp/on      # every line: max 0.0
  ```
  Run it after changing a flag, a mask in `Kernel.fixedFlags` / `fixedPassFlags`, or the Swift side of a kernel's own
  flag word (`Uniforms.tracePassFlags`, `GPURestirGIParams.initialPassFlags`, `GPUFogParams.reflectionPassFlags`).
  Safe math is slower: narrow the mode with `METALRENDERER_BENCH_ONLY` when the full one takes too long.

## A/B protocol

1. **Env against env:**
   ```bash
   .claude/skills/performance/scripts/ab.sh -n 3 -- METALRENDERER_BENCH=stress METALRENDERER_BENCH_ONLY="32 lights" METALRENDERER_TG=trace=8x8 -- METALRENDERER_BENCH=stress METALRENDERER_BENCH_ONLY="32 lights"
   ```
2. **Code against code:** build the baseline in a worktree, so each binary uses its own shader files (commit new
   ones first: `git archive` and a worktree only hold what is tracked):
   ```bash
   git worktree add ../MetalGI-base HEAD
   ```
   ```bash
   swift build -c release --package-path ../MetalGI-base
   ```
   ```bash
   .claude/skills/performance/scripts/ab.sh -n 3 --bin-a ../MetalGI-base/.build/release/MetalRenderer -- METALRENDERER_BENCH=stress METALRENDERER_BENCH_ONLY="32 lights" -- METALRENDERER_BENCH=stress METALRENDERER_BENCH_ONLY="32 lights"
   ```
   Uncommitted changes aren't in the worktree. To compare against them, stash them or commit to a branch first.
   Remove the worktree afterwards with `git worktree remove ../MetalGI-base`.
   * **LFS assets:** the worktree checks out Git LFS pointer files, not the models, so `git lfs pull` inside it is
     needed for the gallery. The Cornell and stress scenes are procedural and need no assets.
3. Read the medians across rounds, not the best run. Treat a delta below about 0.4 ms (or 2–3% on small passes) as
   noise unless it has the same sign in every round.
4. For whole-frame claims, repeat with `METALRENDERER_BENCH_SPLIT=0`.
5. **Shader against shader, one binary:** `METALRENDERER_SHADERS=<copy>/Shaders.metal` runs another copy of the shader
   files (the entry and its `Shaders/` folder), so a shader-only change needs no second build: copy the files, edit the
   copy, and give `ab.sh` the same binary with the variable set on one side.
6. **A shader edit moves kernels it doesn't touch.** The shaders compile as one module, and the compiler's decisions
   in one kernel depend on the rest of it: the previous shaders plus one never-taken call in a kernel the benchmark
   doesn't run made ReSTIR GI frames 0.1 ms (1.2%) slower, in the same way a clean refactor of other kernels did.
   Per-pass columns then mislead (a pass whose source is unchanged shows a delta), and a frame can sit in one of two
   states about 0.1 ms apart from launch to launch. So for a delta of about 1% of a frame:
   * compare whole frames (`METALRENDERER_BENCH_SPLIT=0`) with 5 rounds; the same shaders against themselves give
     0.00–0.02 ms that way;
   * run a control: the baseline with a dead edit of the same kind. If the control moves the frame as much, the
     delta is not the change's;
   * don't chase it helper by helper. Putting single helpers back by hand, or forcing them inline, moved the frame
     by another ±0.1 ms without a pattern.


## Launch time

Launch time is the interactive app's, with its window: ask the user before measuring it, since every launch takes the
focus. The app prints one line when its first frame is on screen, with the steps on the way, in ms since the process started
(`Launch` in CacheFile.swift):

```
Launch: window after 155 ms, renderer after 190 ms, shaders after 207 ms, first frame after 242 ms
```

* Launch several times and drop the first run after a build: a new binary's first start is 0.3 s slower.
* `METALRENDERER_SETTINGS=default` skips the saved settings, so every run starts the same scene.
* "After a shader edit" needs a cache miss on each run: point `METALRENDERER_SHADERS` at copies that each differ in a
  constant every kernel uses (a comment alone recompiles the source but finds the pipelines in the cache).
* Output is line-buffered, so the line is in a redirected log while the app still runs.
