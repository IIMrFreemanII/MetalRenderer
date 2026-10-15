# Realistic water: handoff

On branch `claude/terrain-editor`, on top of the terrain editor (8ca1f40), uncommitted. Built and checked on the M1 Max
(software ray tracing), offscreen only. The plan the user approved: terrain water bodies, Mireland's swamp and a
generated sea/rivers/ponds in the open world; FFT waves displaced near the camera, normals far; refraction with
Beer-Lambert colour, foam, caustics, the camera under water; flowing rivers; at most 3 ms a frame on the M1 Max.

## What exists

- **Data** (`Water/`): `WaterLook` (absorption/scattering per metre, IOR, roughness, waves/chop/ripples, crest and
  shore foam, white water, flow; presets ocean, lake, river, swamp, pool), `WaterField` (where the water is: terrain
  bodies `TerrainWaterField`, a level over a square `LevelWaterField`, the world's `WorldWaterField`), `WaterMap`
  (two 1024² levels around the camera, 1 m and 8 m: surface, ground, flow, look, white water; drawn on the CPU in
  bands, in the background as the camera goes), `WaterSpectrum` (JONSWAP h0 for 3 cascades: 233, 41.3, 7.9 m).
  `WaterBody` gained `look`, `bed`, `bedPoints` (a carved river keeps the bed it was carved to: its surface used to
  end up under the channel, and carving again dug deeper).
- **Scene** (`Scene+Water.swift`): `SceneWater` (looks, the surfaces' triangles, the field). The surfaces are **not**
  scene instances: a sea's sheet under a whole terrain made every ray of the frame 15% slower walking past it.
- **GPU** (`Renderer+Water.swift`, `WaterSystem`): the record (`GPUWaterScene`, in `SceneShading.water` at 296), the
  surfaces' own primitive structure, the near patch (192² cells, 120 m, refitted every frame: 0.17 ms on the M1 Max vs
  2 ms to rebuild, `WaterBLASSpikeTests`), the FFT (`waterSpectrum/FFT/Assemble` kernels, 0.45 ms with mips), the
  caustics (cascade 2's slopes, a bed 2 m down), the map's two copies (uploaded to the back one, swapped).
- **Shading** (`Shaders/WaterCommon.metal`, `Shaders/Water.metal`): `waterKernel` before the trace (after liquids):
  the water hit (map pre-test: no ray where the map has no water along the stretch the ray could meet it), occlusion
  (raster triangle or a ray), wave normal (FFT by ray-cone mip, flow-map ripples on rivers), Fresnel, reflection (a
  ray at a quarter of the pixels a frame in 8×8 blocks, the rest reprojected from the last frame), glint, foam (crests'
  Jacobian, shore band washing, white water), soft shore, Snell's window and total internal reflection from below,
  the camera's ray under water. Writes the bent ray into the liquid targets (w = 2 + flags) and a raster-triangle guess.
  `traceKernel` follows bent rays (skips `visibilityHit` for them, or meets the guessed pixel's triangle). `waterApply`
  folds absorption, depth dimming and the water's own scattered light into the G-buffer. The composite puts caustics
  on the sun's exact term after the shadow filter. The path tracer treats water as an exact dielectric with the same
  normals and absorption (no in-water scattering, no caustics: its deep water is darker than real time's).
- The raster primary path now stays on with liquids too (it was off for any scene with one).
- **Scenes**: terrain bodies (workshop, every terrain scene), Mireland (swamp look; duckweed moved to `Swamp Duckweed`,
  cut out, 3 mm over the water), the open world (`World+Water.swift`, `World.version` 9): sea level ≤ −14 m and 8 m under
  the origin city (cities under sea + 6 m are not built), rivers by steepest descent on a 32 m lattice of smoothed
  hills (breaching hollows up to 8 cells), ponds where they end, the ground shaped to channels/banks/ponds in
  `World.height`, sand along the sea, no trees or cover in the water.
- **Editor**: the Water tab has the look (preset menu, colours, sliders); a look's edit updates the GPU table live,
  a shape's edit makes the scene again.
- Debug: `METALRENDERER_WATER_DEBUG` 1 map, 2 normals, 3 near patch vs still surfaces, 4 caustics (composite);
  `METALRENDERER_WATER_OFF=1`, `METALRENDERER_WATER_WIND` (m/s, 7), `METALRENDERER_WATER_NEAR` (cells, 0 = none),
  `METALRENDERER_WATER_PROBE="x,z0,z1"` (prints the field along a line).

## Water and terrain in the existing scenes

- Generated water is shaped into a scene's base, never into its edits: `Terrain/TerrainShapes.swift`
  (`ShapedTerrainBase`: flats, bowls, channels; pure, its fingerprint in the base's, so old saved edits of `forest-N`,
  `valley`, `city-N` drop once with a log line) and `SceneWaterMaker` (river: a point every 6 m, beds the running
  minimum of the base; pond). The bodies go through `addTerrain(generatedWater:)` after the document's
  (`SceneTerrain.generatedWater`; scatter and `adoptTerrainDocument` count them).
- Forest: a stream from the north to a pond in a hollow (the seed's side); trees, cover and grass keep out of it
  (`dry`, after their random draws). Valley: the glossy pond slab became a lake fed by a stream off the western hill.
- City: `CitySettings.canal` (on, 4+ blocks) turns the middle x street into a canal 16 m wider (the lots and keys as
  before): quays, walls, bridge decks with parapets, water 1.5 m under the street.
- Terrain workshop: `TerrainWorkshopSettings.sea` (on with hills; the 30th-percentile height; `tsea`); the
  benchmarks' workshops turn it off.
- Plant and building workshops, crowd square, sun courtyard: their own ground terrains (`addGroundTerrain`, named by
  the bucketed flat they keep, so editing a plant or building keeps the mesh), a plain beyond. The plants' pond (the
  lowest of seven places behind them, `Scene.pond(on:)`); the crowd's round fountain (`MeshBuilder.ring`) and the
  courtyard's raised pool use `addPoolWater` (a `LevelWaterField` over a convex outline, `.pool` look).
- Mode `waterscenes` renders each from near its water.
- Whole frames, `shot`, dev build, M1 Max, vs f529a13 (`METALRENDERER_ASSETS` for the copy): plants 6.9 → 8.3 ms,
  buildings 6.7 → 8.3 (ground only, no water), crowd 15.4 → 16.7, sun 4.95 → 6.05. Forest pond's water pass
  1.3–3.8 ms, valley 0.9–1.0, city canal 1.9 by day, 2.7 by night. `shot`, `fluids`, Mireland: bit-identical.
- Tests: `PlantGoldenTests` (Forest, valley, and the world's, stale since World v9), `FoliageTests` ground hash,
  `PlantWorkshopTests` counts, `CityTests` (the terrain's detail texture, since the terrain editor), canal row in the
  settings table. `BuildingWorkshopTests.testLooseFurnitureRestsAndMoves` is flaky before and after (2 of 6 at f529a13).

## Verified

- Modes `water` (lagoon, coast, above, swell, shallow, lake, river, top), `waterunder`, `waterperf`, `terrainwater`,
  `mireland`, `world`. Whole frames at 960×600 (`waterperf`, `METALRENDERER_BENCH_SPLIT=0`): water costs 2.4–2.5 ms
  (11.6–11.7 vs 9.2 ms without). Split: water kernel ~1.9–2.3, FFT 0.49, near 0.18, apply 0.1.
- Untouched scenes vs the terrain-editor commit: `shot`, `fluids` bit-identical; city rms 0.2–0.5 (noise); fluids with
  `METALRENDERER_PRIMARY=raster` rms 0.2–0.4 (now raster).
- Tests: WaterTests (spectrum symmetry and wave height, looks/old documents, map, river bed kept, world water
  deterministic with beds going down), WaterBLASSpikeTests, and the related suites.

## Not done / next

- M4 Max and Metal 4 (`METALRENDERER_API=metal4`): the near patch's refit and the water structure's residency.
- Path tracer: in-water scattering and caustics (references are darker in deep water).
- Rivers end at a pond when no lower cell is within 8 cells; real depression filling would give lakes with outlets.
- The underwater view has no god rays; air fog still applies over under-water pixels.
- Water seen in reflections (from glass, metal) and by GI rays is not there (rays pass under it to the bed).
- The window was not hand-tested (offscreen pictures of the Water tab only).
