# Metal 4 GPU hangs: handoff (2026-10-16)

Branch `claude/metal4-showcase-hang`, from main at `8c01bcd`. Measured on the M4 Max (macOS 26.5). Metal 3 never hung in
any of these runs.

## What it was
An intermittent `kIOGPUCommandBufferCallbackErrorHang` under Metal 4, in whichever ray-tracing pass was running
(fog, mesh lights, many lights, particle layer, cascades, trace, lightmap, reflections); the passes after it fail as
"innocent victims". The app's log names the frame's one command buffer after its first pass (`tlas` in the showcase),
which says nothing about where it hung. A benchmark splits the frame into a command buffer per pass, so its log does.

Not the cause (each checked with a control): scene loads and rebuilds (it hangs as often with none), virtual geometry
(it hangs without it), texture streaming, the structures' sizes under Metal 4's descriptors, the residency releases
alone, descriptors and transforms (an earlier session).

What is fixed: every Metal 4 frame has one Metal 3 command buffer in the middle (MetalFX's denoising scaler,
`interlude`; sky and water mipmaps are others), which waited on the GPU for the Metal 4 work before it through a shared
event. Committed while that work was still queued, it hung one of the ray-tracing passes now and then. Committing it
only once that work is done (`Metal4Frame.commit`, the render thread waiting on the event) removes those hangs. It
looks like a driver bug; nothing in our ordering is missing that we could find.

And the rest, with virtual geometry on: a few runs in a hundred still hung, and that wasn't Metal 3 work beside the
frames. It was the residency set: every new cut adds a structure and a triangle buffer to it while the camera moves,
and the retired ones stayed there, alive, until the sweep every 256 frames. PR #70's `cb55f03`, now on this branch,
lets them out as soon as no frame uses them (`VirtualBLAS.takeReleased`, `FrameEncoder.release`): 0 of 120 runs.

## Results (showcase, its realism toggled or held, 12 settings of 90 frames a run; runs with a hang of our own)

| Variant | Frames waited for (benchmark) | Frames overlapping (as the app) |
|---|---|---|
| main | 16 of 30 | 1 of 30, VG off: 4 of 60 |
| every Metal 4 command buffer waited for in turn | 0 of 30 | |
| only around the interlude (before and after) | 0 of 30 | |
| the interlude committed from an event listener (render thread free) | 0 of 30 | 3 of 30 |
| **the interlude committed once the Metal 4 queue is past it (this branch)** | 1 of 60 | 4 of 60, VG off: **0 of 60** |
| ...and virtual geometry's BLAS builds committed only with the Metal 4 queue empty | | 4 of 60 |
| ...and virtual geometry's BLAS builds in the Metal 4 frame instead (no Metal 3 work from it at all) | 3 of 30 | 4 of 60 |
| **...and retired virtual geometry let out of the residency set at once (`cb55f03`, this branch)** | **0 of 30** | **0 of 120** |
| particle shadows off (main) | 2 of 30 | |

Particle shadows make it about eight times as likely (every shadow ray then also walks the particles' box
structure), but aren't needed for it.

## The open world and the frame rate (2026-10-17, main at `0e113e4`)
Frames overlapping as in the app (the benchmark's wait off), one command buffer a frame (`METALRENDERER_BENCH_SPLIT=0`):
- **Open world:** four flights of 1,200 frames at 60 m/s from the start (east, south, west, north), about 18 scene swaps
  a run: 0 of 30 runs hung, and 0 of 30 with the interlude gate taken out too. The open world doesn't bring this hang
  out, so it says nothing either way about the gate; its residency churn hung nothing.
- **What the gate costs:** wall-clock frame rate, 900 frames a setting, six runs each, alternating (spread under 1%):

  | Setting | Gate off | Gate on (main) | Cost |
  |---|---|---|---|
  | open world, native 960×600 | 220.0 fps | 200.4 | 9%, 0.45 ms |
  | default look, MetalFX 640×400 → 1920×1200 | 415.9 | 395.1 | 5%, 0.13 ms |
  | showcase, realism on | 75.7 | 74.6 | 1.5%, 0.2 ms |

  It's about 0.15 ms per interlude: the GPU sits idle from the end of the Metal 4 work before one until the Metal 3
  command buffer, committed only then, starts. The default look has one interlude (MetalFX). The open world has three
  (the sky's mips, the water waves' mips and the caustics' mips) and no MetalFX at native resolution.
- **Committing from a thread of its own** (the same `commit` loop on a serial queue, so the render thread encodes the
  next frame meanwhile) gained nothing: 198.8 against 199.9 fps inline in the world, within noise elsewhere. It hung
  nothing either: 0 of 60 showcase runs, 0 of 30 world runs. The time isn't the render thread's; it's the GPU's gap.
- **So the way to win it back is fewer interludes.** The three mip chains could be a Metal 4 compute downsample: a 2x2
  mean, or 2x2x2 for the sky's 3D noise, which is only made once. Metal 4's own `generateMipmaps` keeps one texel
  instead of the mean, so it can't be used. That leaves MetalFX's interlude, about 0.13 ms.

## The hang that is left (2026-10-18, main at `00126b3` with the SDF boxes' IDs fixed, as `827533b` on main)

Still there, and not found. It is not tied to scene loads: in a paused scene every frame does the same work, and a
random frame of 300 hangs. The cheapest repro is the particles scene: `METALRENDERER_BENCH=particles
METALRENDERER_BENCH_ONLY=metal4 METALRENDERER_API=metal4`, about 2 s a run, 3 of 60 runs with each frame waited for and
4-8 of 60 with frames overlapping (`.claude/notes/metal4-hang-hangrun.py` runs a setting N times and counts them; it
counts a run that never printed its results as failed). The showcase (2 of 30 runs, frames overlapping) and the
scene switches (1 of 30) hung the same way; Metal 3 hasn't, in 140 runs.

What it looks like: one ray-tracing kernel stalls until the watchdog kills its command buffer after 100-130 ms (a few
after ~200 ms), the passes after it failing as victims. With a command buffer per dispatch (`EXP_DISPATCHCB`) the
kernel was `rcTraceMergeKernel` 3 times and `reflectionKernel` once; with one per pass the first to fail was
reflections, particle light, the trace, the light map or the cascades' probes. A paused frame runs particle light,
light map, trace, the cascades, reflections, the particle layer, composite, upscale, in that order: the stall may be
a kernel that runs after the one that left something wrong.

Each row: particles, Metal 4, 60 runs (120 or 240 where said), frames overlapping unless said; the baseline is 4-8.

| Change (`.claude/notes/metal4-hang-experiments.patch` has the switches) | Runs hung |
|---|---|
| frames waited for (the benchmark's default) | 3 |
| one command buffer a frame (`METALRENDERER_BENCH_SPLIT=0`), frames waited for | 1 |
| ...frames overlapping | 2 |
| every Metal 4 command buffer waited for before the next is committed (`EXP_SERIAL`) | 0, then 1 of 34 that never finished |
| a producer barrier at each encoder's end as well (`EXP_PRODUCER`) | 5 |
| the particles' structures never traced (`EXP_NOTRACE`) | 3 |
| particle shadows off / their reflections off (the mode's settings) | 6 / 2 |
| no residency releases at all (`EXP_NORELEASE`), 120 runs | 15 |
| `requestResidency()` after each change (`EXP_REQ`) | 4 |
| Metal 3 / Metal 3 with Metal 4's indirect instance descriptors (`EXP_INDIRECT`) | 0 / 0 |
| `METALRENDERER_MATH=relaxed` | 6 |
| safe math for SDF, Intersect, ParticleTrace / for Surface to LightTree / for Fog, Sky, Mips (pragmas), 120 runs | 10 / 6 / 8 of 92 |
| every ray handed to a query checked finite (origin, direction, tmin, tmax: bit tests), 240 runs | 8 |
| ...and the GGX sample's half vector floored above 0 (a mirror's rim sample is a NaN), 240 runs | 12 |

So: not ordering between command buffers (it hangs with one a frame and nothing else on the GPU), not residency, not
the particles, not NaN rays at the queries, not the descriptor kind. Waiting for every command buffer is the one
change that came near (1 in 94).

**A trap found on the way:** `METALRENDERER_MATH=safe`, and `#pragma METAL fp math_mode(safe)` over the whole source or
over the pieces from Trace on, don't start under Metal 4 on macOS 27.0: the pipelines' compile fails with
`XPC_ERROR_CONNECTION_INTERRUPTED` (the compiler service dies) and the renderer stops in App.swift. Over the pieces up
to Sky it compiles. An earlier count of 0 hangs with safe math was those failed starts.

**The best lead:** in 3 runs the first failure was no hang but a GPU address fault
(`kIOGPUCommandBufferCallbackErrorPageFault`) in particle light, the first ray-tracing kernel of a paused frame;
faults also follow some hangs, in the upscale. A kernel that reads an address nothing maps would fault or, on Apple
GPUs, can stall: the hangs may be reads too, not loops. Particle light reads the particles' records and lighting
(bound), the scene through TraceScene (declared every frame: `sceneDeclaredIn` is cleared at each commit) and, by
their resource IDs, the BLASes the TLAS and the particles' structures name. The hang runner counts only hangs; grep
the logs for `PageFault` too.

Next to try: Metal System Trace or a GPU capture of a hung run (which kernel is resident when the watchdog fires, and
what it reads); the cascades' merge with its `traceSurface` replaced by a plain closest hit; a build of the trace,
cascades and reflections' kernels without the particle queries compiled in (PARTICLES off).

## Still open
- **Scene loads** build their BLASes on a Metal 3 queue in the background (`SceneBuffers`, `VirtualTracing`'s
  placeholder, `MaterialTextures`). Virtual geometry's case says Metal 3 work beside the frames isn't enough to hang
  them, so this is probably fine; untested beyond the realism switches above and the open world's swaps.
- ~~The mips as Metal 4 compute~~: done (2026-10-17, `Shaders/Mips.metal`): bilinear samples, the blit's bits; Metal 4
  frames 6-14% faster in the world and the Forest. MetalFX's interlude was the one left each frame; from macOS 27 it is
  gone too (MetalFX's Metal 4 scaler in the frame, 2026-10-17): an upscaled Metal 4 frame has no Metal 3 work left
  (the frame interpolator's, when it runs, aside). Not yet run against the hang repro above (no hang in the
  1000-frame and showcase runs with `METALRENDERER_RESIDENCY_LIFE=16`).
- **Metal 4's remaining gap** (whole frames 5-13% behind Metal 3 on macOS 27.0.1): in the world, the water's near
  patch refit through the Metal 3 queue (about 0.25 ms of GPU idle around it, Metal System Trace). Metal 4 refits of
  triangle structures failed here (README, "What Metal 4 still costs"); a per-frame Metal 4 build was slower. Next
  to try: a near patch whose structure Metal 4 builds at creation and refits from then on, made again with each
  scene (the stale refits came after scene changes), or the patch as a vertex-only update of a structure built once.

## Reproducing
The temporary benchmark mode (not committed):

```swift
private static func expShowcase() -> [Config] {
    (0..<12).map { i in
        var scene = SceneSettings(kind: .showcase)
        scene.realism = [Realism.on, .off, .high][i % 3]   // or .on for all: one scene, no rebuilds
        return Config("showcase \(i)", scale: 0.75, upscale: 3, gi: .radianceCascades, scene: scene).moving().frames(30)
    }
}
```

Run it 30 times (`METALRENDERER_API=metal4 METALRENDERER_VG_SYNC=0`, about 14 s each) and count the runs whose log
has `ErrorHang`. Frames overlap if the benchmark doesn't wait for each (`passes.commit(..., wait:)` in `Renderer`); with
virtual geometry the overlapping runs were the ones that still hung after the interlude fix.
