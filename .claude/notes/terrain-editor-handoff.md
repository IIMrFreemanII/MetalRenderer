# Terrain Editor: handoff

Branch `claude/terrain-editor` (from main at 814a004, Oct 15 2026). Built and checked on the M1 Max, offscreen only.
Nothing here is committed unless the branch says so; the plan it follows is the one the user approved (terrain
editor: sculpt, 16-layer paint, generate + erosion, scatter, workshop + every scene, separate window, multi-km tiled,
delta over the procedural ground, live ray-traced sculpting, physics/walk/water/import-export).

## What exists

- **Data** (`Sources/MetalRenderer/Terrain/`): `TerrainGrid` (samples, 256-cell tiles, 64-cell sectors, finite or
  endless), `TerrainBase` (noise: Forest/Mireland/workshop; flat with ellipsoid hills: valley/city; `WorldTerrainBase`:
  `World.height`, kinds and heights from the tile files), `TerrainField`/`TerrainSnapshot` (per-tile delta, 16 paint
  weights + mask, protect; per-chunk revisions), `TerrainSectorMesh` (sector meshes: skirts, kinds, per-vertex layer
  weights), `TerrainStore` (`Assets/Terrains/<slug>.terrain/`, raw arrays of edited tiles only; `METALRENDERER_TERRAINS=none`
  for clean runs), `TerrainDocuments` registry, `TerrainDocument` (layers, rules, generator, erosion, scatter, water).
- **Brushes** (CPU, `TerrainBrush.swift`, `TerrainPaint.swift`, `TerrainErosion.swift` brush part): raise, lower,
  smooth, flatten, set height, ramp (on release), noise, terrace, erode (water), crumble (thermal), generator stamp,
  paint, erase, protect, unprotect. Ctrl inverts, Shift smooths. Undo records are tile snapshots (512 MB budget).
- **Scenes**: every terrain ground is borrowed sector meshes (`Scene+Terrain.swift`): Forest (first sector where the
  old ground's instance was: plant wind phase is by instance number), Mireland, valley (hills now terrain: re-baselined),
  city (flat, its streets protected), open world (tiles keep `groundKinds` + `groundHeights`, World.version 8),
  terrain workshop (`SceneKind.terrain`, `Scene+TerrainWorkshop.swift`: 0.5-4 km, flat or hills, optional bodies).
- **Live update** (`Renderer+Terrain.swift`, `Renderer.encodeTerrain`): dirty sectors by chunk revision, nearest
  first, `METALRENDERER_TERRAIN_BUDGET` (6) a frame: CPU meshing into a staging buffer, `FrameEncoder.copyBuffers`
  into the blocks, `TerrainBuild` (fast-build BLAS in place), then the TLAS (still scenes: `SceneBuffers.stillRefit`,
  others rebuilt per slot), reference reset.
- **Shading** (`Surface.metal` `terrainLayers`, bit 12 TERRAIN): per-vertex weights in the block after the materials
  (`MeshBlock.weightsOffset`), top 3 of layers 1-15 over the sector's own material (layer 0), world-space UVs from
  the layer table (in `procParams`, `SceneTerrain.table`), biplanar on steep ground. `GPUMesh`/`MeshData` grew
  `terrain` (48 bytes).
- **Generator/erosion** (`TerrainGenerator.swift`, `TerrainErosion.swift`): node stack (fbm, ridged, billow, cellular,
  warp, terrace, plateau, curve, smooth, constant); hydraulic (virtual pipes) and thermal on the CPU, background
  jobs with progress (`runTerrainJob`), faded borders, undoable.
- **Scatter** (`TerrainScatter.swift`, `Scene+TerrainScatter.swift`): one candidate a cell (deterministic), every
  candidate an instance (hidden when filtered), re-scatter = moving instances (`Scene.moveInstances`,
  `Renderer.writeInstanceEdits`); anchors re-snap builder objects; world trees/cover follow edits (groups renamed,
  scene made again at stroke end).
- **Water** (`TerrainWater.swift`): sea plane, lake flood fill, river bed carving + ribbon; surfaces made with the scene.
- **Physics**: `PhysicsShapeKind.heightfield` (CPU `PhysicsCollide.swift`, GPU `Physics.metal`), one static per
  sector (`addTerrainColliders`), refreshed when sectors are meshed again.
- **Editor** (`TerrainEditor/`): window (Shift-T, Shift-Cmd-T), tools + brush, 2D map (height/slope/layers/edits,
  tile selection, double-click flies there, brush on the map), tabs: layers, generate, erosion, scatter, water, files
  (16-bit PNG / EXR heightmaps, RGBA splat maps, JSON sidecar).

## Verified

- Untouched scenes vs main (pngdiff): forest rms 0.33 (main vs main 0.32), Mireland 0.27, city 0.89, world 0.78;
  valley changed on purpose (hills are terrain).
- Modes: `terrain`, `terrainsculpt`, `terrainedit`, `terrainundo` (redo = stroke, undo = untouched), `terrainpaint`,
  `terrainerode`, `terrainwater`, `terrainscatter` (0.0000 m off the ground after a re-scatter), `terrainphysics`,
  `terrainperf`. Tests: TerrainDocumentTests, TerrainIOTests, TerrainErosionTests, TerrainEditorTests (+ window
  pictures with `TERRAIN_EDITOR_PNG=<folder>`), TerrainBLASSpikeTests (sector 0.8 ms, tile 2.7 ms on the M1 Max).
- Sculpting: ~1 ms CPU for 6 sectors a frame; world build 0.21 s (was 0.05 s; the sectors are meshed at build).

## Not done / next

- The window was never opened in the app (offscreen pictures only): click through it with the user's OK.
- M4 Max and Metal 4 (`METALRENDERER_API=metal4`): the copy path (`Metal4Frame.copyBuffers`) and the still refit.
- Erosion runs on the CPU (a 1 km terrain takes seconds); a GPU version would be the next speed-up.
- Mireland's patches/decals and the valley's slabs don't drape when the ground moves under them.
- GPU physics with heightfields is compiled but only the CPU backend was exercised (the workshop's bodies).
- World build time: cache sector meshes on disk (SectionFile) to get back to 0.05 s.
