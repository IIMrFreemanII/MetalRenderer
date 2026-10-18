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
  - **Written, not yet run on Metal 4** (2026-10-18, on the M1 Max, which has Metal 4 but not Metal 4 ray tracing:
    the validation layer stops a Metal 4 structure build with "this device does not support Metal 4 ray tracing",
    so `Capabilities.metal4RayTracing` is off there and every Metal 4 setting is skipped). `PrimitiveRefit` is now a
    PrimitiveWork4 with refits too: the first frame builds its trees in the frame's encoder (a character's other
    poses refitted from its first one's, as at load), the frames after refit them side by side; Metal 4 never refits
    a tree Metal 3 built. Its `built4` flag lives with the structures (a scene's `primitiveRefit`, the near patch's),
    and `WaterSystem.adopt` clears the near patch's when the scene changes, so it is built again then.
    `METALRENDERER_M4_REFIT=0` sends the refits back through the Metal 3 queue. Metal 3's frames are unchanged
    (the crowd bit for bit, the lake within 7 levels, RMS 0.02).
  - **To do on the M4 Max:** `render.sh -m blasrefit` with `METALRENDERER_API=metal3`, `metal4` and
    `metal4 METALRENDERER_M4_REFIT=0` (the lake, the crowd, both again after the other scene, the crowd moving), then
    `Tools/eval/pngdiff.py` between them: the near patch must be there and match after each change of scene. Then time
    the world's and the crowd's whole frames (`METALRENDERER_BENCH_SPLIT=0`) against the interlude. If the near
    patch still goes stale, try `refit(..., options: .vertexData)`, or keep only the crowd's refits in the frame.
  - The physics look's scenes (cloth, soft bodies, hair) crash on main in `SceneBuffers.writeInstanceDescriptors`
    (SceneBuffers.swift:601, `primitiveIDs[index]` out of range, Metal 3 included), so `blasrefit` leaves them out.

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
