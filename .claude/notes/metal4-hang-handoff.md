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

## Still open
- **Scene loads** build their BLASes on a Metal 3 queue in the background (`SceneBuffers`, `VirtualTracing`'s
  placeholder, `MaterialTextures`). Virtual geometry's case says Metal 3 work beside the frames isn't enough to hang
  them, so this is probably fine; untested beyond the realism switches above.
- The open world swaps gigabytes of scene every few seconds: its residency churn is the other place to look if a hang
  comes back (`releaseUnused(since:)` lets a replaced scene go 8 frames after the swap).
- The app's frame rate with the interlude gate when GPU-bound: benchmarks wait for each frame, so it isn't measured.

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
