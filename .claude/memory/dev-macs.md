---
name: dev-macs
description: "The dev Macs: an M1 Max (no hardware ray tracing, Metal 4 RT path untestable) and, from Oct 2026, an M4 Max"
metadata:
  type: project
---

Two Macs have been used for this project:

- **M1 Max** (macOS 27), where the work up to 2026-10-05 was done. Capability line: Metal ray tracing: software,
  Metal 4: yes (ray tracing: no). So `METALRENDERER_RT=metal METALRENDERER_API=metal4` is skipped by every benchmark
  mode ("needs Metal 4 ray tracing", Apple9 GPUs and later); code for that combination (for example
  `Metal4Frame.refitPrimitives`) was built but never run. A dataset reference (Tools/neural) took ~70 s there.
- **M4 Max**, from 2026-10-05, chosen to render the neural denoiser's dataset faster. It has hardware ray tracing,
  so the Metal tracer + Metal 4 path should run there: check the capability line on the first run, then run the
  benchmark modes that were skipped on the M1 Max and say what they show.

**Why:** the M1 Max couldn't verify the Metal 4 ray-tracing path, and its GPU was the bottleneck for the dataset.
**How to apply:** on the M1 Max, say a Metal-tracer + Metal 4 change wasn't run there, and don't count a "skipped"
benchmark as a pass. On the M4 Max, time a dataset reference with `METALRENDERER_RT=metal` before the long run
(Tools/neural/README.md). See [[feedback-render-offscreen]] for how runs are made.
