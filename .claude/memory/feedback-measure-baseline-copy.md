---
name: feedback-measure-baseline-copy
description: How to A/B code against code in MetalGI when the working tree has uncommitted work, and two measurement traps found on 2026-10-03
metadata:
  type: feedback
---

For code-vs-code A/B with uncommitted changes in the tree, copy `Sources`, `Tests`, `Package.swift`, `Tools` to the scratchpad, build there, and pass it to `ab.sh --bin-a` (or `render.sh -b`). Without `Tests/MetalRendererTests` the build fails ("invalid custom path"), and a `swift build | tail` in the background still exits 0, so check that the binary exists before comparing (found 2026-10-04: a first pngdiff printed nothing because the baseline had never built). Set `METALRENDERER_ASSETS=<repo>/Assets` for that copy: a symlinked `Assets` folder is not enumerated and the gallery loads 0 models.

**Why:** `git worktree` of HEAD would lack the uncommitted work; a first gallery image diff looked like a huge regression only because the baseline rendered no models.
**How to apply:** also never rebuild or edit `Shaders.metal` while a background benchmark loop is still launching the binary (it reads the shader at launch). And check the stress hall as well as the market: a CPU-side change (writing records straight into shared MTLBuffers) slowed the GPU by 0.35 ms only with 16384 moving lights. See [[audit-backlog-2026-10]].
