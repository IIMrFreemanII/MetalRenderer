# Realistic look (terrain, plants, lighting): handoff

On branch `claude/terrain-editor`, on top of the scenes' water and terrain (04dc0e1). Uncommitted. Built and checked
offscreen on the M1 Max. The user asked for terrain and plants "like in UE".

**The user's choices:**
- photo-scanned textures plus procedural fallbacks;
- all of terrain materials, terrain detail, the plants' look, and lighting and post;
- the Forest, the valley, the open world and the workshops;
- "look first": measure the cost, but don't let it block.

## What exists

### The setting

`SceneSettings.realism`:
- values: `Realism` off, on (the default) or high;
- environment: `METALRENDERER_SCENE=realism=off|on|high`;
- panel: "Realistic look".

The settings export compares against the realistic presets (`SettingsEnv.export`).

### Scans

`Tools/textures/fetch.py` and `manifest.json` hold 15 CC0 sets: Poly Haven, and ambientCG for grass, moss and the beech leaf sheet `LeafSet024`. They are stored in `Assets/Textures/<set>/` (Git LFS):
- maps: albedo, normal (GL), roughness, AO, height;
- `info.json` with the repeat in metres, and `LICENSE.txt`.

`TextureSets.swift`:
- **`TextureSet`** finds a set; it is disabled with `METALRENDERER_SCANS=0`.
- **Mip-chain cache:** `Assets/Textures/<set>/.metalrenderer-cache` (gitignored).
- **`addScanMaterial`** creates the material:
  - albedo and normal are streamed;
  - an ORMH map (R occlusion, G roughness raised to at least 0.5, A height) is packed on the CPU;
  - each scan's textures are added once per scene (`Scene.scanTextures`).

  The ambientCG grass roughness averaged 0.26, which made glossy blobs.
- **`addLeafSheetMaterial`:** the leaf sheet.
- **`markRealisticLeaf`:** grass, needles and fronds.

### Ground

`Terrain/GroundLook.swift`. A scene's layer 0 is made of up to 8 scanned layers mixed by a map it draws (two RGBA textures).

- **Rock:** where the normal's y falls below `slope`.
- **`GroundLook.meadow`:** grass, dry grass, earth, mud by water, pebbles in it, rock.
- **Per scene:**
  - Forest: litter, moss, clearing grass, the trail in forest-ground, mud and pebbles at the water.
  - Valley: the fields and roads are in the map, and the slabs are gone with realism on.
  - Plant workshop, terrain workshop (sand by the sea), crowd, sun courtyard, building workshop: their own maps.
  - Open world: its 8 grounds are scans on the tiles' UVs, plus a 2 km map round the middle tile that fades to them.
- **Painted layers:** they wear their name's scan (`TerrainLayer.scanSet` / `textureSet`).

### Terrain shader

`terrainRealistic` in `Shaders/Surface.metal`, used when the table header is 16 or 17:
- height lerp (`TERRAIN_BLEND_DEPTH`) between map layers, rock and the 3 strongest painted layers;
- triplanar on steep ground, with UDN normals;
- two scales, ×1 near and ×0.25 far;
- macro noise for tint, brightness and roughness (`terrain-macro`);
- layer AO;
- High: parallax 6 cm deep for footprints under 4 mm (`TERRAIN_PARALLAX_DEPTH`).

The old `terrainLayers` path is untouched with realism off.

### Plants

`Scene+Forest.swift` `addMaterials`:
- **Bark:** scanned oak bark, or pine bark for conifers, tinted to the species' colour. Birch keeps its generated bark.
- **Broad leaves:** the scanned beech sheet. Each leaf shows one of its 9 leaves, mirrored at random, cropped inside the outline (Surface.metal `sheetLeaf`).
- **Every realistic leaf:**
  - its own colour;
  - flutter on the shading normal;
  - **two-sided where the camera sees it**:
    - `LEAF_TRANSMIT` (bit 10), with `Hair.metal` `leafUnshadowed` / `leafPoint` / `leafCode`;
    - G-buffer code 4 + share, plus 2 if flipped;
    - one shadow ray, from the light's side.
  - GI still sees the old per-leaf flip share, so crowns from below keep their sky light.

### Meadows and rocks

- `Flora.meadow` and `Scene.addMeadowGrass`: grass patches on 2 m cells in the valley (80 m round the village), and in the plant workshop on High only (it took the workshop from 8.5 to 24 ms).
- `Scene+Rocks.swift`:
  - `boulder`: an icosphere with ridged noise and chipped plane cuts;
  - `addRocks`: rocks sunk a third and set to the slope, in the rock scan. Placed in the Forest (steep ground, banks, clusters) and the valley (water, the hills).
- **Open world** (`Scene+World.swift`), round the middle tile (out to 190 m): meadow grass on the meadows, rocks on steep ground and in the woods. Neither goes on a city's blocks, the highways or the water (the world's water field takes world places); rocks also stay off the fields and the sand. Mode `realism` builds "world woods" and "world meadow" round their own tiles. Dev build, whole frames: deep woods 110 → 124 ms, the meadow by the start 27 → 30.

### Lighting and post

- **Auto exposure:** `AutoExposure.swift`, with a histogram in `tonemapKernel` and `finishKernel` that is read back frames later and eased.
- **Grade:** `Uniforms.grade` (272 bytes now): white balance (`warmth`), saturation, contrast.
- **Realistic presets** (`PostSettings` / `FogSettings.preset(for: SceneSettings)`): bloom 0.035, vignette 0.16, and haze for aerial perspective (0.3 forest, 0.55 elsewhere). Height fog turns on where it was off.

### Checks

- Mode `realism` covers the forest (clearing, trail, floor, pond bank, closeup), the valley (hills, stream), the plant workshop (crowned, bark), the terrain workshop and the world (woods, start).
- Tests: `RealismTests` (maps, table, layer names, forest determinism, boulders, exposure meter).
- Generator tests pin realism off: `PlantGoldenTests`, `FoliageTests`, `ForestTests`, `PlantCatalogTests`, `PlantWorkshopTests`.
- `CityTests` allows scans.
- Realism off renders as the commit before: `shot` is bit-identical; `forest` and `plants` differ only as much as two runs of the baseline do (rms 0.02 and 0.3).

## Cost (M1 Max, release, whole frames, `METALRENDERER_BENCH_SPLIT=0`, mode `realism`, off → on)

| View | Off | On |
|---|---|---|
| Forest clearing | 77.8 ms | 86.7 ms |
| Forest trail | 88.0 ms | 101.6 ms |
| Valley hills | 12.9 ms | 17.3 ms |
| Terrain workshop | 13.0 ms | 15.5 ms |
| World woods | 27.3 ms | 29.0 ms |
| Plant workshop | 8.5 ms | about the same (its grass is High only) |

- High adds parallax at about +1 ms near the ground.
- The traps found:
  - Scans with specular below REFLECTION_MAX_ROUGHNESS put a 41 ms reflection pass in the Forest, so scans keep a roughness floor of 0.7 (leaves 0.62).
  - GI hits on scans take the colour alone: the terrain's two strongest layers on one axis, and the mesh path skips a scan's normal and ORMH (`MaterialExtra.textures.z == 2`).

## Not done / next

- **Real displacement** of near terrain (a finer sector level) was not built. High has parallax instead.
- **Splat maps finer than the cell** exist only as the scenes' own ground maps (0.3–1 m texels). Editor paint is still per vertex.
- **Not built:** hex/stochastic tiling (the two scales and the macro noise hide most repeats), contact AO (GTAO), a LUT, and the Material Designer's Bitmap node changes with natural graph fallbacks. Without scans the fallback is the plain colour times the detail texture.
- **To check:** the window (the panel row, auto exposure with a moving camera), the M4 Max and Metal 4.
