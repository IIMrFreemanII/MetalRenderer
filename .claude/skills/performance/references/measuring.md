# Measuring MetalRenderer

Everything runs from the repo root with a release build. The binary loads `Shaders.metal` from the source folder it
was built from (`#filePath`, Renderer.swift:242).

```bash
swift build -c release
METALRENDERER_BENCH=<mode> .build/release/MetalRenderer
```

A benchmark renders 60 warm-up frames and then 240 measured frames per setting, back to back without vsync. It prints
a table and quits. The lists of settings are in `Benchmark.configs(for:)` (Benchmark.swift ~415). Benchmarks never
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
| `gi` | `Tools/eval/gi.py` |
| `shadow` | `Tools/eval/shadow.py` |
| `upscale` | `Tools/eval/upscale.py` |
| `noise` (references) + `denoise` | `Tools/eval/noise.py` |
| `gallery` | `Tools/eval/gallery.py` |
| `quality`, `fogcheck`, `skycheck`, `lightcheck`, `vgdebug` | inspect the PNGs; `pngdiff.py` between runs |

Scorers print PSNR in dB (higher is better) and flicker in 8-bit levels. References live in `Tools/eval/refs/<mode>/`.
A run that renders the "ref …" settings refreshes them. Skip them with `METALRENDERER_GI_REFS=0` once they exist.
Re-render them only when the ground truth changes (the scene, lights, materials or light transport), never for a
pure speed change.

## Narrowing and overriding

* `METALRENDERER_BENCH_ONLY="32 lights|camera"` keeps only the settings whose names contain one of these substrings.
* `METALRENDERER_SCENE="stress,objects=400,lights=32"` loads that scene in every setting.
* Override strings, parsed in Benchmark.swift (~95–330), apply to every setting:
  * `METALRENDERER_GI="mode=pt|cascades|restir,bounces=…,scale=…,factor=…,upscaler=metalfx|custom|spatial,on=0,…"`;
  * `METALRENDERER_DENOISE`, `_RESTIR`, `_RESTIR_GI`, `_FOG_SET`, `_SKY_SET`, `_VIEW`.
* Plain defaults: `METALRENDERER_RT=metal|custom`, `_DIRECT`, `_VG`, `_VG_TAU`, `_VG_POOL`, `_SPECULAR`,
  `_TEXTURE_BUDGET`, `_FOG`, `_SKY`.
* Performance knobs:
  * `METALRENDERER_TG="trace=16x8,atrous=16x16"` sets threadgroup sizes;
  * `METALRENDERER_TLAS=<frames>` sets Metal's TLAS rebuild interval;
  * `METALRENDERER_RT_BUILD=cpu` builds the custom tracer's moving tree on the CPU with SAH;
  * `METALRENDERER_RT_STATS=1` turns on the traversal counters, printed per setting;
  * `METALRENDERER_VG_SYNC=0|1` forces background or synchronous cut updates.
* To reproduce an interactive state, use **Copy as Env** in the Settings panel. It puts the `METALRENDERER_*` lines
  that differ from the defaults on the clipboard.
* To compare two launches' settings, use `METALRENDERER_DUMP_SETTINGS=1`.

## A/B protocol

1. **Env against env:**
   ```bash
   .claude/skills/performance/scripts/ab.sh -n 3 -- METALRENDERER_BENCH=stress METALRENDERER_BENCH_ONLY="32 lights" METALRENDERER_TG=trace=8x8 -- METALRENDERER_BENCH=stress METALRENDERER_BENCH_ONLY="32 lights"
   ```
2. **Code against code:** build the baseline in a worktree, so each binary uses its own `Shaders.metal`:
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
