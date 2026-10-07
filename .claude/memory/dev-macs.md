---
name: dev-macs
description: "The dev Macs: an M1 Max (no hardware ray tracing, Metal 4 RT path untestable) and, from Oct 2026, an M4 Max"
metadata:
  node_type: memory
  type: project
  originSessionId: e96b741b-87d3-4fd4-9106-0c9f11fba77d
  modified: 2026-10-06T22:23:26.243Z
---

Two Macs have been used for this project:

- **M1 Max** (macOS 27), where the work up to 2026-10-05 was done. Capability line: Metal ray tracing: software,
  Metal 4: yes (ray tracing: no). So `METALRENDERER_RT=metal METALRENDERER_API=metal4` is skipped by every benchmark
  mode ("needs Metal 4 ray tracing", Apple9 GPUs and later); code for that combination (for example
  `Metal4Frame.refitPrimitives`) was built but never run. A dataset reference (Tools/neural) took ~70 s there.
- **M4 Max**, from 2026-10-05, chosen to render the neural denoiser's dataset faster. Capability line: Metal ray
  tracing: hardware, MetalFX denoiser: yes, Metal 4: yes (ray tracing: yes). Checked there on 2026-10-05: `-m api`
  runs all four tracer x API settings (stress pt: custom 6.2 ms, Metal 4.0 ms on Metal 3 / 4.1 ms on Metal 4), and
  Metal 4 frames match Metal 3 bit for bit (also with the Metal tracer); 1000-frame `shot`s on Metal 4 + Metal RT
  with `METALRENDERER_RESIDENCY_LIFE=16` in cornell, market, forest, gallery, showcase, stress ran without faults.
  Dataset references with `METALRENDERER_RT=metal` (same image as the custom tracer, 92 dB apart): Cornell ~6 s,
  random room ~19 s, stress building ~26 s, forest ~31 s, showcase ~32 s, market ~54 s (custom tracer: Cornell ~10 s).

On 2026-10-07 the Metal-only tracer (custom tracer removed, PR #41) was checked on the M4 Max: Metal 3 and Metal 4
render the same images, 1000-frame Metal 4 runs had no faults, and Metal 4 frames are 3–10% slower than Metal 3. The
forest's wind pass (posing and refitting the plants) still takes ~11 ms of its ~16 ms frame. Results are in
`.claude/notes/metal-tracer-handoff.md`. `METALRENDERER_RT` no longer exists.

**Why:** the M1 Max couldn't verify the Metal 4 ray-tracing path, and its GPU was the bottleneck for the dataset.
**How to apply:** on the M1 Max, say a Metal-tracer + Metal 4 change wasn't run there, and don't count a "skipped"
benchmark as a pass. On the M4 Max, render dataset references with `METALRENDERER_RT=metal`. See [[feedback-render-offscreen]] for how runs are made.
