# Plants grown bud by bud: handoff (2026-10-29)

Branch `claude/foliage-ue-look`. The plants were rebuilt to grow the way Unreal 5.8's Mega Plants (the Procedural
Vegetation Editor) grows them, in original code: no Unreal assets, nothing ported. It replaces the level-by-level
grower (Weber–Penn: `Recipe`, `Level`, `Graft`, `AgeRule`, boughs), its JSON and its editor tabs. The README's
"Generated plants" and "The plant editor" sections have the design and how to use it. Built and measured on the
**M4 Max** only.

## Where things are
- `Sources/Plants/Growth/`:
  - `Grower.swift`: `Growth.Params` (trunk and branch `Shoot`s, `Light`, `Senescence`, `Bifurcation`, `Wood`, ages),
    the simulation (`Plant.cycle`: light, senescence, sprouting and extension, radius, hormones, sag), `grow`,
    `grown` (with the twigs' places), `lit` (per-stem light for the workshop's Light view), `twig` (a palette mesh),
    `Twigs`, `aged`.
  - `LightField.swift`: the shadow grid (cones of shadow cast down; the cell above a point gives its light).
  - `Mesher.swift`: `Growth.Wood`, tubes with flared, lobed feet, generation in U's whole part, bark relief.
  - `LeafOutline.swift`: the scanned leaf sheet's leaves traced into 10-vertex outlines; leaf number in V, twig
    health in U.
- `Foliage.plant`: a species' plant, its trunk and limbs as parts, its twigs as shared parts on bones of their own.
- `Surface.metal`: bark by generation (U's whole part) with moss, leaf health tint, outline-leaf detection.
- Species: `PlantSpecies.swift` (`SpeciesDef`: `growth`, `twigs`, `leaf` for own-stem leaves, `ages.variants`),
  `BuiltInPlants.swift`; JSON format 2 (`PlantStore.swift`; format 1 files are skipped with a message; the draft key
  is `plantDraft2`). `Foliage.version` 2 renames every plant cache.
- Editor: `Sources/Editors/Plants/PlantTabs.swift` (Growth, Branching, Light, Twigs, Leaves, Bark, Look, Habitat,
  Ages), `PlantParams.swift` (every slider; Mutate reads it), `PlantMutate.swift`.

## Kept on purpose
- **Leaf cards** (`cards=1`, `Foliage.cards`, `cardSheet`, `rtCutout`): a user-facing setting; grown twigs have a card
  path (`Growth.twig(cards:)`). Only plants use the cutouts. Remove the setting, the shader's alpha test and
  `Scene.cutouts` together if they are no longer wanted.
- The wind's second bone is still named `bough` (`Scene.Assembly.Part.bough`, `RTPart`, `Foliage.metal`): it is
  each twig's bone now.
- No disk cache of grown skeletons: the whole library takes ~21 ms on one thread (`METALRENDERER_FOLIAGE_TEST=1`),
  about what reading it back would.

## Checked
- 161 tests (`Tools/build.sh test --filter 'Twig|Grower|Mesher|Foliage|Plant|Forest|Realism|World|ProjectGraph|SceneSwitch|Cache|ShaderSource|KernelVariants'`).
  The golden hashes changed at each milestone on purpose (noted in `PlantGoldenTests`); the last change only renamed
  (`plants v2`): with `Foliage.version` 1 they pass unchanged.
- Cornell, market and stress shots bit-identical to the base commit.
- `forestcheck`: assemblies and baked meshes within 1% (94.1 against 93.9 from the clearing, 102.3 against 102.5 from
  the air); path tracing, cascades and ReSTIR GI within 1% of each other in the backlit view (92.3, 92.5, 92.2). The
  512-frame path-traced reference does not match them, here (108.7) or on the base commit (67.3 against 93.4): its
  haze round the sun differs, the trees are the same. Not from this work; worth a look.
- Forest GPU time, release, against the base commit (`ab.sh -n 2`, `METALRENDERER_BENCH=forest`, medians): static
  8.38 → 8.23 ms, aerial 9.61 → 10.04, closeup 9.46 → 9.53, 10k trees 10.86 → 10.58, moving 8.80 → 8.57, moving 3x
  7.46 → 7.33: the same within the noise, aerial a little slower.

## Not done
- The growth's loops aren't in the fast subset (`Tools/perf/hotcalls.py` with `Growth.Plant.cycle()`,
  `LightField.measure`, `Plant.sag`, `Plant.twigs`, `Growth.tube`, `Foliage.leaves`): copy-on-write checks on the
  point and branch arrays, `SplitMix64` called across modules. Load-time only (~21 ms for the library); not listed in
  `hot-functions.txt` until they are clean.
- Side-by-side with the Unreal capture (`/tmp/claude-501/megaplants_leaves.png`) in a `megaplants` benchmark setting.
- The plant editor's panel itself was not opened in the app: its model is tested, its views only built.
- Distant trunks look slightly purple in the default look's forest (seen before the shading milestone).

## The preview stage (Unreal's tree preview)
- The workshop's meadow (hills, pond, meadow grass) is gone: `Scene+PlantPreview.swift` makes Unreal's grid floor (`GridLook.previewFloor`, material extra kind 3, drawn by
  Surface.metal `previewGrid`; Unreal's roughness noise was left out: it showed as waves in the far floor), lit as the vegetation editor's
  Grey Ambient profile (SPVEditorViewport.cpp picks it, not "Default": a constant grey sky, `Scene.previewSky`, from
  T_GreyAmbient's thumbnail; a white sun of 4; both in `Scene.previewUnits`). Calibrated 2026-10-29 against a capture
  of the editor's viewport (PVE_MyMegaTree, SlateInspector `Screenshot` with an empty ref; CaptureEditorImage and
  `screencapture` both failed): everything there was 1.17× brighter than the fit predicts (the units carry it), the
  floor 8% more (tile 0.18), the sky cool rather than warm, no subgrid visible, and the floor is Floor_Mesh at scale
  4, a 40 m slab (`Scene.previewFloorReach`). The oak was then matched to the same capture (BuiltInPlants
  `oakTwigs`, `oakDef.look`): muted olive leaves (the path tracer's mid-tone leaves 78/82/54 sRGB against Unreal's
  80/83/66) and open, half-flattened sprays (twigs every 0.34 m, 22 leaves a metre), whose shadow has sunflecks in
  the path tracer. The realtime path (640×400, MetalFX denoiser ×3) blurred that shadow back into a blob (MetalFX:
  with our denoisers off it was the same; with MetalFX off, sharp), until MetalFX's diffuse guide got the sun's raw
  shadow in it (Output.metal `sunShadowGuide`, `RenderTargets.diffuseGuide`). The realtime leaves then came out a third
  darker than path traced, from the radiance cascades alone (ReSTIR GI and the path tracer through MetalFX matched):
  a crown's coarse probes sit on other leaves deeper in, so the sky through its gaps was mostly lost in the merge.
  The workshop's definition sets `cascadeSkyGaps` (RadianceCascades.metal `RC_SKY_GAPS`): such rays ask whether they
  reach the sky. Mid-tones 78/81/57 against the path tracer's 79/82/54, for 0.04 ms; off elsewhere (the forest
  matched already and would pay 0.8 ms). The stage has a sun 40°
  up on a rig its behaviour (`PlantPreviewPlayer`) turns live from `RenderSettings.previewLightYaw` / `previewSpin`
  (the spin's angle in `SceneSession.previewSpin`, kept across the editor's remakes), the scale figure (the characters'
  base body, T pose) and the size ruler (`maskLights` bars and a stroke font).
- `Scene.backdrop` → `Uniforms.backdrop`: camera rays that miss see grey in the G-buffer pass and the path tracer
  (`cameraRay`); every lighting miss keeps the sky. `Uniforms` is 320 bytes now (`validateGPULayouts`).
- The plants definition: `previewSky` (atmosphere, no clouds), `realisticAir = false` (no aerial fog), its own `post`
  (fixed exposure, a mild grade). Exposure at EV 0 matched the meadow's auto exposure, so no per-scene exposure field.
- A first launch (nothing saved) opens the workshop: `RenderSettings.firstLaunch`; `SceneSettings()` stays Cornell.
- Not done: the overlay labels Unreal draws as text are strokes in the scene here; the solid look's sky is its own.

## Measured against Unreal's sample trees (2026-10-29)
- `ProceduralVegetationEditor/Content/SampleAssets/Tree_*/Instances/*.json` (UE 5.8): grown skeletons of a beech, a
  quaking aspen, a hazel and a Norway maple (points: `positions`, `pscale` the radius; primitives: `branchGeneration`,
  `instancer_name` its twigs). Measured, not used: the README's table. Their twig meshes (Aspen_Twig_*, CH_Branch_*,
  Maple_*, Leaves_*) are Quixel assets that aren't installed.
- The birch against the aspen: `light.requirement` 0 (0.01 already left the inner crown bare: the measure is a
  switch, not a slope), trunk segment 0.4, `radiusGrowth` 0.0034. The bush's stems against the hazels:
  `radiusGrowth` 0.0009. Forest shot (dev build, one run) 7.08 → 7.31 ms.
- The leaves: the oak, the birch and the bush shared one sheet, ambientCG's LeafSet024 (ovate, beech-like). Unreal's
  have a leaf of their own each (the starter tree's narrow lanceolate leaves, darker olive: sRGB about 76/86/46 against
  the sheet's 115/149/67; the aspen's, hazel's and maple's are in the missing Quixel twigs). Now the birch has
  `leaves-birch` (LeafSet014, pointed and serrated) and the bush `leaves-bush` (LeafSet009, round and toothed), both
  3 by 2 (`Tools/textures/manifest.json` "cells", into info.json; `TextureSet.cells`). `LeafRecipe.sheet` names a
  species' sheet (nil: "leaves"); `LeafOutline.sheet(_:)` traces each once; the forest gives each species its sheet's
  material; the generated look reads the grid from the leaf material's extra (`surface.z` = 16 × columns + rows,
  `markRealisticLeaf`). The library's cache name carries the catalog's fingerprint for the built-in species too (it
  didn't: a retuned built-in species kept its old far voxels on disk). LeafSet009's albedo has autumn blotches and
  holes (the holes show as leaf: outlines aren't cut out); its bushes read a little darker in the forest.

## Leaves up close (2026-10-29)

Up close the oak's leaves looked flat. There were two reasons:
- **Geometry:** `writeOutline` drew rows of left and right points only, so each leaf was a flat strip with half-tilted normals.
- **Shading:** 60% of every leaf's normal bent toward the crown's outside, at any distance.

Now:
- **Each leaf is a domed blade:** each row has a midrib vertex too (16 triangles). Its edges sit `fold`·width below the midrib and its tip `fold`·length below. The vertex normals are those of that surface.
  - Convex on purpose: the first try, a cup (edges up), cast hard triangular self-shadows inside each leaf.
- **The crown bend fades up close:** `LEAF_CROWN_FAR` / `LEAF_CROWN_NEAR` (15 mm / 3 mm pixel footprints). GI rays are wide, so they always use the crown's normals.
- **Cost:** the forest shot is the same as before (A/B 7.6–7.9 ms both, trace 1.58 ms). Twigs are shared palette meshes.
- **New shot:** `-m plants` gains "plants oak leaves", a camera in the crown's lower edge.
- **Realism switch removed:** the "Realistic look" switch is gone from the panel. The app is always realistic, and a saved copy's value is ignored. The env key `realism=` stays for benchmarks and tests.
