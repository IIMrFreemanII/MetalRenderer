# Proving a refactor changed nothing

The baseline is the feature as it was before the pass, built in its own worktree (`scripts/baseline.sh`), so it
loads its own shaders (`Shaders.metal` and `Shaders/`). Every proof compares the current tree with it. How the benchmark works, its modes
and its noise are in the `performance` skill's [measuring.md](../../performance/references/measuring.md).

## Images

```bash
.claude/skills/refactor/scripts/same.sh <mode> ["<filter>"] [-- KEY=VALUE …]
```

It rebuilds the current tree, runs the mode on both binaries with `METALRENDERER_BENCH_DIR` and
`METALRENDERER_GI_REFS=0`, and compares the PNGs by name. It prints the count and exits 0 when all are identical.
The benchmark steps time by a fixed 1/60 s, so animated settings are comparable too.

Pick the modes by what the change touched. Start with `quick`, then add the ones for the area:

| Touched | Modes |
|---|---|
| Anything in the frame loop | `quick` |
| GI (path traced, cascades, ReSTIR GI), the denoiser | `gi`, `denoise`, `restirgicheck` |
| Direct light, many lights, ReSTIR DI, the light grid | `stressq`, `shadow`, `lightcheck`, `restircheck` |
| Fog, sky, clouds | `fogcheck`, `skycheck` |
| Reflections, specular light | `speccheck` |
| The upscaler (MetalFX denoiser), the output path | `quality`, `hwrtq` |
| Ray queries, acceleration structures, `TraceScene` | `quick`, `hwrt`; plants (variants, wind, leaf cards, voxels) `forestcheck`; virtual geometry `vgdebug`, `gallery`; SDF shapes `shapes` |
| Metal 3 / Metal 4 encoding | `api`, and any mode with `-- METALRENDERER_API=metal4` |
| Virtual geometry, glTF, texture streaming | `vgdebug`, `gallery`, with `-- METALRENDERER_ASSETS=<repo>/Assets` (see below) |
| Skinned characters, the crowd, deforming meshes | `crowd` with `-- METALRENDERER_CROWD_CHECK=1` (its log lines compare the GPU's vertices with the CPU's) |
| The city, the building generator, glass, meshes of several materials | `city` (its first 17 settings are stills: narrow with `"overview\|street\|facade\|night"`) |
| Capability fallbacks | any mode with `-- METALRENDERER_CAPS=rt` and the like |

What a mode costs, per run, on an M4 Max under macOS 27.0 without the references (`same.sh` runs it twice):

| Mode | Images | Seconds | | Mode | Images | Seconds |
|---|---|---|---|---|---|---|
| `shadow` | 5 | 2 | | `quality` | 8 | 16 |
| `denoise` | 7 | 4 | | `hwrtq` | 8 | ≈6-8 |
| `vgdebug` | 18 | 4 | | `gi` | 36 | ≈17 |
| `lightcheck` | 6 | 6 | | `hwrt` | 4 | ≈4 |
| `quick` | 4 | ≈4 | | `skycheck` | 20 | 28 |
| `api` | 6 | ≈4 | | | | |
| `speccheck` | 18 | 10 | | `fogcheck` | 12 | 30 |
| | | | | `stressq` | 39 | ≈37 |
| | | | | `restirgicheck` | 8 | 60 |
| | | | | `restircheck` | 36 | minutes |

≈: scaled down from the measured time when the other upscalers were removed (and, for `hwrt` and `api`, when the
custom tracer went and their settings halved), not measured again.

Narrow `restircheck` with a filter (an unmatched `METALRENDERER_BENCH_ONLY` prints the mode's setting names). The
other fifteen together take about five minutes per binary, so ten for a comparison.

`vgdebug` and `gallery` need both binaries to read the same models *and the same caches*: pass
`METALRENDERER_ASSETS=<repo>/Assets`. Left alone, the baseline builds its own cluster DAGs in its worktree, and two
builds of a DAG differ (the virtual-geometry views then differ in a fifth of their pixels, with nothing changed).

When images differ:
* **Run `same.sh --self <mode> "<filter>"`.** It compares the baseline with itself. A setting that differs there
  differs from run to run and can't prove anything. On the M4 Max every mode in the table repeated bit for bit,
  MetalFX and Metal's hardware tracer included. That isn't a given elsewhere: 9d3e661 saw Metal's tracer differ
  from itself. For a setting that doesn't repeat, score it instead (`Tools/eval/hwrt.py` and the other scorers: a
  refactor leaves the scores within the ±0.2 dB that single frames swing by). (Before October 2026 such a path was
  proven on the custom tracer, which repeated; it is gone.)
* **Otherwise the change is real.** `python3 Tools/eval/pngdiff.py <a> <b>` gives the size per image in 8-bit levels
  (it needs numpy and Pillow). A difference of 1 level everywhere is usually reordered floating-point math, a few
  pixels with large differences usually a changed condition, and noise all over a changed random seed or sample
  order. Find which, then decide: restore the old behaviour, or keep the new one as a listed behaviour change with
  its scorer result.

## Settings, names and lists

Refactors of tables and registries are proven on what the tables produce, not on images alone:
* **Setting names of a mode.** A filter that matches nothing prints them to stderr and exits with status 1. Save
  the list from each binary in the scratchpad and compare the two with `diff`:
  ```bash
  METALRENDERER_BENCH=stress METALRENDERER_BENCH_ONLY="(names)" ../MetalGI-base/.build/release/MetalRenderer 2> names-base.txt
  ```
* **Resolved settings of a launch.** `METALRENDERER_DUMP_SETTINGS=1` prints the settings as sorted JSON at launch,
  after the saved settings and the env overrides are applied. The app keeps running, so quit it after the dump.
  Use it with the env lines the change could affect.
* **Larger sweeps.** For a change to how settings are resolved or exported, compare old and new over every mode or
  every table row with a temporary test or a scratch dump in both trees (46765c1 compared 3806 settings this way).
  State the count in the report.
* **The panel.** Rows, values, enabling and visibility come from the table; compare them in a test over several
  settings states rather than by eye.

## Scorers and other tools

A change to a `Tools/eval` script is proven on its output: run the old script (from `../MetalGI-base`) and the new
one on the same run folder and `diff` what they print.

## Tests

The whole `swift test` takes about 40 s (it compiles the kernel variants on the GPU), so run only the suites that
cover the change: `.claude/skills/tests/scripts/related.sh` picks them (the `tests` skill). The suites guard:
* `SettingsTableTests`: env names are unique, every setting and random panel states round-trip, bad input is
  skipped, sliders show what they set.
* `BenchmarkModesTests`: every mode builds named settings, the modifiers, env overrides, scene presets.
* `CapabilitiesTests`: fallbacks for each missing capability, the benchmark's skips, API names.
* `KernelVariantsTests`: the flag values in Swift match the shaders', and the variants compile.
* `ShaderSourceTests`: every piece in `Shaders/` is included once, and compile errors name the piece.
* `BVHTests`, `CacheTests`: the parallel BVH build equals the serial one; cache files are written whole.
* `PlantTracingTests`: the plants' layouts match the shaders', plants name the variant of their phase bucket and
  leaf share, `plantWindKernel` poses a variant's parts as the shading turns their points, and the instances lean
  downwind as `Wind.plant` / `Wind.cover` say.

Green tests prove the tables. They say nothing about the frame: that takes images.

## Timings

"As fast as before" is an A/B against the baseline binary, in alternating rounds:

```bash
.claude/skills/performance/scripts/ab.sh -n 3 --bin-a ../MetalGI-base/.build/release/MetalRenderer -- METALRENDERER_BENCH=quick -- METALRENDERER_BENCH=quick
```

Add `-c "GPU total,cpu"` when the pass touched per-frame CPU work. Read the medians; a delta below about 0.4 ms
without the same sign in every round is noise (measuring.md, "A/B protocol"). For whole-frame claims add
`METALRENDERER_BENCH_SPLIT=0` to both sides.

## What could not be run

Say it, under "Not run": the gallery without the models, Metal 4 or the MetalFX denoiser on a system without them,
older macOS versions. `METALRENDERER_CAPS` can stand in for a GPU that lacks a capability, not for one that has it.
An unproven path named in the report is fine. One passed over in silence reads as proven.
