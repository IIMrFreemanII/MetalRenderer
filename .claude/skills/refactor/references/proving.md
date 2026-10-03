# Proving a refactor changed nothing

The baseline is the feature as it was before the pass, built in its own worktree (`scripts/baseline.sh`), so it
loads its own `Shaders.metal`. Every proof compares the current tree with it. How the benchmark works, its modes
and its noise are in the `performance` skill's [measuring.md](../../performance/references/measuring.md).

## Images

```bash
.claude/skills/refactor/scripts/same.sh <mode> ["<filter>"] [-- KEY=VALUE …]
```

It rebuilds the current tree, runs the mode on both binaries with `METALRENDERER_BENCH_DIR` and
`METALRENDERER_GI_REFS=0`, and compares the PNGs by name. It prints the count and exits 0 when all are identical.
The benchmark steps time by a fixed 1/60 s, so animated settings are comparable too.

Pick the modes by what the change touched. Start with `quick`, then narrow the longer ones with a filter (an
unmatched `METALRENDERER_BENCH_ONLY` prints the mode's setting names):

| Touched | Modes |
|---|---|
| Anything in the frame loop | `quick` |
| GI (path traced, cascades, ReSTIR GI), the denoiser | `gi`, `denoise`, `restirgicheck` |
| Direct light, many lights, ReSTIR DI, the light grid | `stressq`, `restircheck`, `shadow`, `lightcheck` |
| Fog, sky, clouds | `fogcheck`, `skycheck` |
| Upscalers, the output path | `upscale`, `quality`, `hwrtq` |
| Tracers, acceleration structures | `rt`, `hwrtq`, and any mode with `-- METALRENDERER_RT=metal` (see below: Metal's tracer isn't repeatable) |
| Metal 3 / Metal 4 encoding | `api`, and any mode with `-- METALRENDERER_API=metal4` |
| Virtual geometry, glTF, texture streaming | `vgdebug`, `gallery` (needs the LFS models in both trees) |
| Capability fallbacks | any mode with `-- METALRENDERER_CAPS=rt` and the like |

When images differ:
* **Run `same.sh --self <mode> "<filter>"`.** It compares the baseline with itself. A setting that differs there
  differs from run to run and can't prove anything: Metal's own tracer does (a few rays hit the other of two
  coplanar triangles), and so may MetalFX. Prove those paths with the custom tracer and the custom upscaler, and
  score the rest (`Tools/eval/hwrt.py` and the other scorers) instead of diffing.
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

`swift test` runs without a GPU and takes seconds once built. It guards:
* `SettingsTableTests`: env names are unique, every setting and random panel states round-trip, bad input is
  skipped, sliders show what they set.
* `BenchmarkModesTests`: every mode builds named settings, the modifiers, env overrides, scene presets.
* `CapabilitiesTests`: fallbacks for each missing capability, the benchmark's skips, upscaler names.

Green tests prove the tables. They say nothing about the frame: that takes images.

## Timings

"As fast as before" is an A/B against the baseline binary, in alternating rounds:

```bash
.claude/skills/performance/scripts/ab.sh -n 3 --bin-a ../MetalGI-base/.build/release/MetalRenderer -- METALRENDERER_BENCH=quick -- METALRENDERER_BENCH=quick
```

Add `-c "GPU total,cpu"` when the pass touched per-frame CPU work. Read the medians; a delta below about 0.4 ms
without the same sign in every round is noise (measuring.md, "A/B protocol"). For whole-frame claims add
`METALRENDERER_BENCH_SPLIT=0` to both sides, and `METALRENDERER_BENCH_PRESENT=0` where the display paces the frame.

## What could not be run

Say it, under "Not run": the gallery without the models, Metal 4 or the MetalFX denoiser on a system without them,
older macOS versions. `METALRENDERER_CAPS` can stand in for a GPU that lacks a capability, not for one that has it.
An unproven path named in the report is fine. One passed over in silence reads as proven.
