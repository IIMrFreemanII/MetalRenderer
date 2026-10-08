---
name: offscreen
description: Render MetalRenderer offscreen, without a window, to see or check what a change does. Use whenever you would run the app to look at a frame, take a screenshot, check a shader, lighting, denoiser, upscaler or other visual change, compare images before and after, run a benchmark or a quality mode and score it, or reproduce a rendering bug. Never open the app's window for this; the user keeps working on the same Mac.
---

# Offscreen rendering in MetalRenderer

Every run you make renders offscreen. The user works on this Mac while you iterate, so a window must never pop up or
take the focus. Any run with `METALRENDERER_BENCH` set is headless: no window, no Dock icon, no menu, and the app
never becomes active. Frames go into offscreen textures the size of the app's window on a Retina screen (1280×800
points, backing 2), so the pixels and timings are the same as in the window. Each run prints a table, writes PNGs to
`METALRENDERER_BENCH_DIR` and quits by itself.

## Rules

`$SCRATCH` below is your scratchpad directory.

* **Never launch `.build/*/MetalRenderer` without `METALRENDERER_BENCH`.** Without it you get the interactive app,
  with its window and the focus. The same goes for `swift run` and `open`.
* **Never set `METALRENDERER_WINDOW=1`** (it shows the frames in a window) unless the user asks to watch.
* If something can only be checked in the interactive app (input, panels, the Debug window, launch time with a
  window), ask the user before you launch it.
* Write PNGs and logs to the scratchpad, not the repo. Look at a PNG with the Read tool.
* Run anything longer than about 30 s with `run_in_background`, then wait for the notification.
* Don't rebuild, and don't edit `Shaders.metal` or `Shaders/`, while a run is launching: it compiles the shaders it
  finds at launch.
* Swift edits need `swift build -c release`; shader edits don't (the binary compiles the shaders at launch).
  `render.sh` rebuilds when a Swift source is newer than the binary.

## Render something: `scripts/render.sh`

```bash
.claude/skills/offscreen/scripts/render.sh -o "$SCRATCH/shot" METALRENDERER_SCENE=sun
```
* `-m <mode>` picks the benchmark mode. The default is `shot`: one picture of the app's default look (radiance
  cascades, MetalFX denoiser 3× from 640×400 to 1920×1200), paused at t = 5 s, after 60 warm-up frames and 30 more
  (`METALRENDERER_SHOT_FRAMES=<n>`). It takes about 1–2 s.
* `KEY=VALUE` arguments are any `METALRENDERER_*` overrides (the list is in the performance skill's
  `references/measuring.md`, "Narrowing and overriding"):
  * scene: `METALRENDERER_SCENE=cornell|stress|gallery|spots|sun|area|tubes|emissive|mixed|fog|valley|market|crowd|city|citynight|showcase|shapes|physics`,
    plus `,objects=…,lights=…` (the crowd: `,characters=…,poses=…,detail=…`; the city: `,seed=…,blocks=…,style=…,lit=…,rooms=…,textures=…`;
    the showcase: `,showcase=owl`, a part of a model's file name; the physics scene, `physics`:
    `,bodies=…,particles=…,cloth=…,substeps=…,physics=gpu|cpu`);
    the plant workshop, `plants`: `,species=oak|birch|…,age=…,variant=…,plantseed=…,layout=single|lineup|mutate,view=plant|skeleton`
    (`-m plants` renders seven of them);
  * plants: `METALRENDERER_PLANTS=builtin` leaves out the species saved in `Assets/Plants` (the plant editor's), for
    comparisons between builds; `=<folder>` reads another folder;
  * lens: `METALRENDERER_POST="bloom=…,aperture=…,focus=…,vignette=…,grain=…,ca=…"` (`-m showcase` renders every model);
  * GI: `METALRENDERER_GI="mode=pt|cascades|restir,bounces=2,scale=0.75,factor=0"` (factor 0 means native, no
    upscaling);
  * also `_DENOISE`, `_RESTIR`, `_RESTIR_GI`, `_FOG_SET`, `_SKY_SET`, `_VIEW="exposure=…,tod=…"`, `_API`, `_DIRECT`.
* It prints the timing table, the log path and the new PNG paths. Override typos are printed too ("unknown key"); a
  typo doesn't stop the run.
* `-q` prints only the PNG paths. `-b <binary>` runs another build, from its own folder, with its own shaders.
* A setting with `.recording()` (Benchmark.swift) also saves every other measured frame as a JPEG in a folder of its
  own: a 30 fps sequence for ffmpeg. `-m showcasevideo` records every showcase model orbited for 6 s.

Not settable from the environment:
* the camera pose: each scene's default camera is used, or a `Config.camera` / `.cameraMove()` in a mode;
* debug views (`view=` in `_VIEW` is ignored in benchmarks): use a mode that has them (`quality`, `vgdebug`), or add a
  config with `.view(n)` to `Benchmark+Modes.swift`.

For a picture the existing modes don't cover, add a mode next to `shot` and register it in `Benchmark.modes`. Its
settings' names become the PNG names.

## Recipes

**Look at a change.** Render before and after into two folders, Read both PNGs, then diff them:
```bash
python3 Tools/eval/pngdiff.py "$SCRATCH/before" "$SCRATCH/after"
```
`pngdiff.py` prints, per image, the max difference, the RMS and the share of pixels more than 8 levels off.
* A shader-only change needs only one binary: copy `Sources/MetalRenderer/Shaders.metal` and `Shaders/` to the
  scratchpad, then run the copy with `METALRENDERER_SHADERS=<copy>/Shaders.metal` on one side.
* A Swift change needs the baseline built in the scratchpad (`git archive HEAD Sources Package.swift Tools | tar -x
  -C "$SCRATCH/base"`, then `swift build -c release` there). Run it with `-b "$SCRATCH/base/.build/release/MetalRenderer"`
  and `METALRENDERER_ASSETS=<repo>/Assets`.
* An image that must not change: max 0.0 everywhere. Fast-math variants can flip a few stochastic pixels; see
  measuring.md, "Kernel variants".

**Score quality.** Run a quality mode into a folder, then its scorer:
```bash
.claude/skills/offscreen/scripts/render.sh -m stressq -o "$SCRATCH/q" METALRENDERER_GI_REFS=0
python3 Tools/eval/stress.py "$SCRATCH/q"
```
The mode-to-scorer table is in measuring.md. Narrow long modes with `METALRENDERER_BENCH_ONLY="name|other"`.

**Make a video.** A mode whose settings record (`.recording()`, see the note above; `.track(...)` gives a setting a
camera track of its own) becomes an mp4 with `scripts/video.sh`, which runs `render.sh` and then ffmpeg on each
setting's frames:
```bash
.claude/skills/offscreen/scripts/video.sh -m shapesdemo -o "$SCRATCH/shapes-demo.mp4"
```
`-m stressdemo` tours the stress building the same way (58 s).
It takes minutes (every frame of the track is rendered), so run it with `run_in_background`. To tune a track, look
along it first: run the mode with `render.sh` and Read a few of the JPEGs.

**Time it.** Timings belong to the `performance` skill (`ab.sh`, alternating rounds). Its runs are headless too.

## What headless changes, and what it doesn't

* The same pixels: a `quick` run with and without the window matched bit for bit in 6 of 7 settings. The first
  setting differed by RMS 0.06/255, with no pixel more than 8 levels off.
* The same GPU times, within noise. Per-frame CPU is about 0.05 ms lower without a drawable to wait for, and the first
  frame comes about 110 ms sooner.
* The GPU is still shared with the user's apps. Prefer narrowed runs (`BENCH_ONLY`, `shot`) to whole sweeps.

The mechanism: `RenderSurface` (RenderSurface.swift) is either the window's `LayerSurface` (its view's CAMetalLayer) or
an `OffscreenSurface` (a ring of textures in the drawable's format). Either way the frames are drawn on the render
thread (RenderThread.swift). `Headless.isEnabled` picks the surface in main.swift, and the app runs with the
`.prohibited` activation policy.
