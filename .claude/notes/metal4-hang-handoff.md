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

What isn't: with virtual geometry on, a few runs in a hundred still hang, and that is not Metal 3 work running beside
the frames (below).

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
| particle shadows off (main) | 2 of 30 | |

Particle shadows make it about eight times as likely (every shadow ray then also walks the particles' box
structure), but aren't needed for it.

## Still open
- **With virtual geometry on**, 3 to 4 runs in 60 still hang (VG off: 0 of 60), in the same ray-tracing passes (mesh
  lights, trace, the cascades). It is not VG's Metal 3 queue: committing its builds only with the Metal 4 queue empty
  left 4 of 60, and building its cuts' structures in the Metal 4 frame itself (the worker only gathering; the frame's
  encoder building them ahead of the top-level structure, like `PrimitiveWork4`; the stills stayed byte-identical)
  left 4 of 60 overlapping and 3 of 30 waited for. That change was reverted. What VG does that the rest doesn't: a new
  cut makes new structures and triangle buffers every few frames while the camera moves, each added to the residency
  set (and kept there until the 600-frame sweep), and the top-level structure is rebuilt over them. Next to try:
  recycle the cuts' structures as their buffers are (no new allocations once warm), or PR #70's release of retired
  ones at once (cb55f03), and count the hangs again; a run with `METALRENDERER_VG_TAU` raised (fewer new cuts) would
  say whether the hangs follow the rebuilds.
- **Scene loads** build their BLASes on a Metal 3 queue in the background (`SceneBuffers`, `VirtualTracing`'s
  placeholder, `MaterialTextures`). VG's case says Metal 3 work beside the frames isn't enough to hang them, so this may
  be fine; untested.

## Reproducing
The scratchpad patch `metal4-hang-experiments.patch` (saved in the session) had the temporary mode and switches; the
mode is short to write again:

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
has `ErrorHang`. Frames overlap if the benchmark doesn't wait for each (`passes.commit(..., wait:)` in `Renderer`).
