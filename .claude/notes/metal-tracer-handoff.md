# Metal-only tracer: handoff to the M4 Max (2026-10-06)

Branch `claude/graphify-update-ray-tracing-4780d7`, PR #41. The custom BVH tracer is gone and Metal's acceleration
structures are the only tracer. Everything that needed the custom tracer has been ported: virtual geometry, raster
and VSM clusters, plant assemblies with wind, leaf fall and leaf cards, far plant voxels, the traversal-cost view and
`RT_STATS`. All of it was built and measured on the **M1 Max (software RT)** only.

## Where things are
- `TraceScene.swift`: the scene as an argument buffer at buffer 1 for every ray-tracing kernel (TLAS, VG tables,
  plant parts, wind, cutouts, stats).
- `VirtualTracing.swift` + `VirtualBLAS.swift`: a Metal BLAS per virtual instance over its CPU cut.
  `METALRENDERER_VG_MODE=clusters` builds a box structure over the cut's clusters every frame; the query loop walks
  each cluster's BVH (`clusterWalk` in `Shaders/Intersect.metal`).
- `PlantTracing.swift` + `plantWindKernel` (`Shaders/Foliage.metal`): multi-level instancing. Each assembly has
  variants per (8 wind phases × 5 leaf-keep levels); a plant's instance carries its exact root lean, ground cover a
  shear. Variants in use are refitted every frame, **one encoder per refit** (2+ refits per encoder crashed the
  M1 Max driver).
- `Shaders/Intersect.metal`: `Levels<PLANTS>` picks 2- or 3-level intersection types; the query loop runs for voxel
  boxes, SDF shapes, VG clusters and leaf cards (`VG_CLUSTERS` is feature bit 21).
- Tests: `PlantTracingTests`, `VGCutTests.testTheCutsBLASHoldsTheCutsTriangles`.

## M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`)

| Scene | Metal only (this branch) | Custom (main) | Old Metal (main) |
|---|---|---|---|
| Cornell | 4.7 | 5.3 | 4.7 |
| Stress | 12.7 | 15.4 | 12.5 |
| Gallery (VG) | 10.1 | 13.7 | 12.0 (full meshes) |
| City | 6.8 | 7.5 | 6.7 |
| Forest, wind 0.4 | 53.3 | 46.7 | 26.9 (baked, still) |
| World | 14.4 | 13.7 | 11.5 |

Leaf cards (off by default): 223 vs 83 ms. Clusters mode: ~6× slower than the BLAS mode. Wind posing + refit:
~11.6 ms a frame in the forest. VG memory: ~2× the custom tracer's (BLASes not compacted).

## To do on the M4 Max, in order
1. Check the capability line (hardware RT, Metal 4 ray tracing: yes?).
2. Run the related suites (`.claude/skills/tests/scripts/related.sh --base main`) — the Metal 4 + RT path has
   never run: `Metal4Backend.updatePrimitives` (primitive work through the Metal 3 interlude), plant refits,
   VirtualBLAS builds.
3. Render offscreen with `METALRENDERER_API=metal3` and `metal4` (cornell, stress, gallery, city, forest, world,
   `vgdebug`, `forestcheck`) and compare images between the two APIs; then time them (`performance` skill, `ab.sh`).
4. Decide on the slow paths with the M4 numbers in hand:
   - Forest wind (53 vs 47 ms custom): is the per-variant refit still the cost with hardware RT? Try several refits
     per encoder again (the crash may be M1-driver only), or fewer variants.
   - Leaf cards (2.7× slower): the alpha test runs in the query loop on every non-opaque candidate.
   - Clusters mode (6×): the per-frame box structure + software cluster walk.
5. Open world plants stand still (instance blocks force a still scene): make tile plants move if wanted.
6. Quick check: saved settings with the old `"rayTracer"` key load without resetting other settings.
7. Other branches still have custom-tracer code: physics (PR #39), ragdolls, hair (uncommitted, other worktrees),
   and `claude/forest-city-scene-rendering-c4c4c9` (its plant/building optimisations were made on the custom tracer:
   ported on `claude/forest-city-metal`, 2026-10-07: flat far buildings, ray classes, window modules as rigid
   assemblies (off: slower on Metal's tracer); GI rays' plant LOD and the shader's camera voxel level measured and
   not kept, README).
   Rebasing them onto this branch means porting their custom paths, chiefly refitting deforming meshes' BLASes.

## Traps
- Metal RT isn't bit-reproducible run to run (RMS ~0.5/255): image checks need a noise threshold.
- Check for other MetalRenderer runs on the GPU before timing (other sessions share it).
