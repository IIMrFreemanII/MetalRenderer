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

## M4 Max results (2026-10-07, after main was merged in at `0d1cc14`)
Capability line: `Metal ray tracing: hardware, MetalFX denoiser: yes, Metal 4: yes (ray tracing: yes)`.

- **Tests**: 69 tests in 11 suites pass (PlantTracing, VGCut, VGStreamer, Capabilities, SettingsTable, Foliage,
  Forest, FoliageRuntime, ShaderSource, KernelVariants, Hair). New: `SettingsTableTests.testRemovedKeysDoNotResetSavedSettings`
  (saved JSON with `"rayTracer"` loads, other fields kept): to-do 6 is done.
- **Metal 3 vs Metal 4 images**: `shot` of cornell, stress, gallery, city, forest; all of `vgdebug` (18) and
  `forestcheck` (15, `GI_REFS=0`): bit-identical (max 0), except `backlit lumen` (max 1/255) and the world (RMS 0.35;
  Metal 3 against itself: RMS 0.48, so run-to-run noise).
- **Long runs**: 1000-frame `shot`s on Metal 4 with `METALRENDERER_RESIDENCY_LIFE=16` in gallery, forest, forest with
  `METALRENDERER_FOLIAGE="wind=0.4"` and world: no faults.
- **Timing** (whole frame, `METALRENDERER_BENCH_SPLIT=0`, median of 5 alternating rounds, `shot` unless named):

| Scene | Metal 3 | Metal 4 |
|---|---|---|
| Cornell | 2.30 | 2.50 |
| Stress | 3.82 | 3.99 |
| Gallery (VG) | 3.11 | 3.31 |
| City | 2.74 | 3.03 |
| Forest (`shot`) | 15.93 | 16.38 |
| Forest moving, wind 0.4 (`-m forest`) | 15.61 | 15.89 |
| World | 3.74 | 3.99 |
| forestcheck `assemblies` / `cards` | 4.36 / 11.29 | 4.49 / 11.36 |
| Gallery, `METALRENDERER_VG_MODE=clusters` | ~275 | ~278 |

  Metal 4 is 0.13–0.45 ms (3–10%) slower than Metal 3 in every scene, the same sign in every round.
- **What the numbers say about to-do 4**:
  - Forest: the `wind` pass (posing + refits) is **11.1–11.3 ms of a ~16 ms frame** on the M4 too (M1: 11.6), and it
    costs that in the default forest `shot` as well, not only with `wind=0.4`. Hardware RT doesn't make refits cheaper:
    this is the forest's cost.
    **Done for Metal 4 (2026-10-07):** the plants' refits (231 variants, 28,605 instances) moved from the Metal 3
    interlude into the frame's Metal 4 encoder with no barriers between them (`PlantTracing.Refit.encode4`): wind
    pass 11.1 → 0.13 ms, forest moving in wind 0.4 16.40 → 5.08 ms (5 rounds, whole frame), image identical, 1000
    frames without faults. Through Metal 3 the refits run one after another whatever the batching (1, 2, 16 or all
    231 to an encoder: ~11 ms; building instead of refitting: the same); Metal 3 still costs 11.7 ms. Left for
    Metal 3: refit fewer variants a frame, or fewer phases.
  - Leaf cards: 2.6× the assemblies (11.3 vs 4.4 ms), about the M1's ratio.
  - Clusters mode: ~90× the BLAS mode in the gallery (M1: ~6×). Split: lightmap 37 ms, trace 47, many lights 97,
    mesh lights 15, cascades 27 + 47, reflections 54; the per-frame box structure (`vg`) only 1.7 ms. The cost is the
    software cluster walk in every ray query, so its relative cost grew as hardware RT made everything else fast.

## Where the M4 Max's frame goes (2026-10-17, main at `b229576`)
The passes on their own (split mode, release, one run each, ms; Metal 3 / Metal 4 where they differ):

| Setting | Frame | Biggest passes |
|---|---|---|
| `shot` (default look, MetalFX 640×400 → 1920×1200) | 2.27 | MetalFX 1.76, trace 0.19, rc trace 0.17 |
| `showcase` Android Battle Maiden camera (3x) | 4.42 | MetalFX 1.66, many lights 0.45, reflections 0.40, rc probes 0.39, particles 0.27 |
| `forest static` (960×600) | 8.18 / 7.38 | trace 2.88, rc trace 1.53, reflections 0.83 / 0.66, fog 0.53 / 0.33 |
| `forest moving 3x` | 8.69 / 6.61 | wind 1.91 / 0.13, MetalFX 1.64, trace 1.55, rc trace 1.00 |
| `world start` (960×600) | 5.61 / 4.64 | reflections 0.83 / 0.73, trace 0.74, rc trace 0.66, glass 0.61 |
| `world woods` | 6.54 / 4.39 | trace 1.59 / 1.20, rc trace 0.94 / 0.71, reflections 0.50 / 0.29 |
| `world flight 3x` | 7.01 / 6.85 | trace 1.62, MetalFX 1.50, rc trace 0.85, water 0.55 |

- **With MetalFX on, it is most of the frame:** 77% of the default look, 38% of the showcase. Nothing in our own
  passes moves those frames much. MetalFX's frame interpolation came next (`FrameInterpolator`, README "Frame
  interpolation"): +1.21 ms a rendered frame, twice the frames shown. It is only worth it below half the display's
  rate (Auto); this Mac's display is 120 Hz.
- **At native resolution, the ray-tracing passes are about half the frame:** trace, rc trace, reflections and glass.
- **Traversal is already cheap.** `METALRENDERER_RT_STATS=1` counts the triangles Metal hands the queries (all of
  them non-opaque in that build):
  - forest: 0.7 triangle candidates a ray (camera 1.3, shadow 0.5, GI 0.2);
  - world: 0.2–0.3 a ray;
  - no box candidates in either.
  So these passes pay for shading (materials, textures, light sampling), not for finding hits.
- **Leaf cards (forestcheck `cards`, 11.3 ms against 4.4)** only cost that where cards are switched on: the default
  forest and world have none.
- **No GPU counters:** `xctrace record --template 'Metal System Trace'` records them with "Counter Set: (null)", so a
  pass's limiter (ALU, texture, occupancy) needs a capture with a counter set chosen in Instruments or Xcode.
- **Fast math against relaxed math:** forest static's trace passes within 1%. `METALRENDERER_MATH=safe` doesn't start
  here: the compiler service drops its connection compiling the shaders ("XPC_ERROR_CONNECTION_INTERRUPTED").
- **Split mode's per-pass sums aren't whole frames.** Metal 4's sums seem to leave out the mips in its interludes
  (water waves 0.30 → 0.15). So its lower totals here aren't a Metal 4 win: whole frames are 3–10% slower on it (above).

## To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above)
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
