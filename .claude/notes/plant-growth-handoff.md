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
- Species: `PlantSpecies.swift` (`SpeciesDef`: `growth`, `twigs`, `leaf` for own-stem leaves, `ages.variants`, `graph`),
  the built-in ones `Programs/*.swift`; saved as Swift (`PlantStore.swift`, `PlantSwift`), JSON format 2 still read
  (format 1 files are skipped with a message; the draft key is `plantDraft2`). `Foliage.version` 2 renames every plant
  cache.
- Editor: `Sources/Editors/Plants/` (`PlantGraphView`, `PlantEditorModel+Graph`, `PlantNodeInspector`,
  `PlantSpeciesInspector`), `PlantParams.swift` (every slider; Mutate reads it), `PlantMutate.swift`.

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
  4, a 40 m slab (`Scene.previewFloorReach`). The oak was then matched to the same capture (Programs/Oak.swift
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

## The oak's leaves as the Mega Plants tree's (2026-10-29)

The vegetation editor's tree (PVE_MyMegaTree) is dressed in `DeciduousTree_01/Instances/Leaf_Twig_01..05`.
- **Twigs:** 30–56 cm long, about 1,100 triangles each, with around 13 alternate leaves.
- **Leaves:** elliptic, smooth-edged, pointed, 10–15 cm.
- **Material:** `MI_LeafTree_01_Foliage`.
  - Roughness about 0.5, with a rougher backside; specular 0.3–0.55.
  - Backside tinted 0.82 and desaturated.
  - Translucency tint 0.5/0.5/0.13.
  - Health and season overlays turn some leaves brown.
- **Texture:** its colour texture's mean is 0.10/0.12/0.04 linear.

Ours, up close, were broad beech leaves with polygonal edges, matte, all one green, on brown twigs.

Now:
- **Leaves:**
  - **Oak's own sheet:** `leaves-oak` (LeafSet022, CC0, 3 by 2, 0.25 m); leaf length 0.15 m.
  - **Outline rows:** 4 → 6 (24 triangles a leaf), and edges 0.75 tracer px inside the leaf.
- **Prepared sheets:** `TextureSet.sheetAlbedo` (all sheets with an opacity map) fills the card by push-pull and flattens hue 65% toward the mean.
  - Without it, the lime sheet tinted to the oak's olive turned midribs and edges purple. The tint is per-channel: target/mean.
- **Gloss:** `addLeafSheetMaterial` minimum roughness 0.62 → 0.35. Leaves now average about 0.6 roughness, under REFLECTION_MAX_ROUGHNESS, so they get a sun highlight.
  - The reflection kernel skips rays on leaf pixels: `geoNormal.w <= -3.5` is a leaf code. It adds the diffuse GI instead.
  - Without that skip, the forest's reflections took 0.38 → 1.75 ms. With it, 0.32.
- **Colour:**
  - `LEAF_BROWN_SHARE` 0.14 of leaves turn olive-brown, and undersides are 20% greyer.
  - Oak look colours are about a third darker and toward UE's hue. Workshop crown mid-tones: 80/83/57 sRGB, against UE's 80/83/66 (before: 77/79/55).
- **Twig wood:** `Growth.twigWood` = 8 is added to a twig's wood U (`TWIG_WOOD` in Surface.metal). It shades as yellow-green young stems, `TWIG_WOOD_TINT`, without the trunk's moss.
- **Forest shot:** 7.9–8.0 ms against 7.6–7.9 before (trace +0.05 ms from the extra leaf triangles).

## The oak grown as Unreal's Mega Plants sample tree (2026-10-30)

The tree editor's tree (PVE_MyMegaTree, the sample DeciduousTree_01 graph) still looked different: a dense conical
crown on a leader, against our broad oak of few limbs with sprays at their ends. Its graph was read from the editor
(PCGToolset GetGraphStructure on `PVE_MyMegaTree:ProceduralVegetationGraph`; the node values, compact, in the session's
scratchpad `pve_params.txt`) and the plugin's source (`ProceduralVegetationEditor/Source/ProceduralVegetation`) read
for what each value does. The graph: Grower (45 cycles) → Graft Distributor (3-cycle grafts on generations 3–4) →
Grower (3 more cycles) → Carve (outer 4%) → Manual Edit → Carve (bottom 10%) → Gravity → Mesh Builder → Bone
Reduction → Foliage Distributor (hormone mode) → Export. Its tree: 12.15 m tall, 9.5 by 8.9 m, 385 branches, 846 twigs.

Taken, in original code (Grower.swift, Programs/Oak.swift):
- Its Grower values: target length 20 m, 0.4 m internodes (branches' 0.34), its four priority curves as our apical and
  axillary ramps (the same basis: length from the root over the target), trunk axil 55° (Unreal's 35° is up from the
  level), branches alternate at 45°, no apical dominance, radius 0.0035 a cycle (a 0.15 m trunk), ethylene 0.15.
- New, as Unreal's grower: `Shoot.requirement` (its trunk's buds ask nearly open sky, its branches' none),
  `Shoot.sproutLight` (axillary phototropism), `Params.bareNodes` (radical auxin: the first nodes bare), `Params.spurs`
  (the grafts grown on: a 0.25 m shoot at each node of the last generations' branches), `Params.carve` (Carve from the
  bottom: the trunk's foot cut, the plant lowered). All optional: saved species decode, and every other species is
  bit-identical (the workshop's shots byte for byte).
- Not taken: its light's strength. Unreal's phototropism (0.49 a step toward a light that is straight up in the open)
  is offset by its grower's heavy sag of young tips (about 16° a cycle); ours pulls toward a light that is mostly up
  and sags little, so its values stood every branch upright (crowns 0.5 m wide). The oak's turns are weaker (branch
  phototropism 0.08, trunk sproutLight 0.15) and its shade lighter (`light.shadow` 16), chosen by sweeping them for
  Unreal's counts: 20 primaries, about 500 branches and spurs, 916 twigs, 12.2 m by 12 by 10.5 (the width set by one
  long low branch: the seed's).
- Twigs (hormone mode): every 0.3 m back from each tip while ethylene < 0.9, from the trunk on (`fromGeneration` 1),
  alternate and level (`Twigs.alternate`: Alternate phyllotaxy with reset, then BranchUpFlatten), 83° from the branch,
  scale 2.3 × lerp(0.75, 1) from tip to foot (`tipScale` 1, `alongScale` 0.333). The twig itself as Leaf_Twig: a
  0.42 m shoot of 8 to 15 alternate leaves (13 cm, scaled to 22–30), its wood half as thick (it is hung at twice its size).
- The forest shot (dev build, one run): 8.0 → 6.7 ms (fewer leaf triangles: 916 twigs of ~14 leaves against 433 of ~80).
- Not done: Unreal's mesh builder (generation radius ramps, its trunk profile's 2.4× lobed foot over the bottom 15%,
  bark displacement), its Gravity node, the outer carve, the manual edit; the new fields have no sliders in the plant
  editor yet (Mutate doesn't touch them).

### Then: grafts, clumps, the crown's shape and colour (2026-10-30)

Side by side with the editor's capture (ffmpeg `hstack` of the PVE crop and the workshop's oak), it still differed:
broad and triangular on near-level limbs, its twigs flat level fronds strung along them like fishbones, darker and
more saturated.
- **Grafts** (`Params.grafts`, Unreal's graft distributor, parametric mode): 2 a branch on generations 3 and up where
  the plant's gradient (length from the root over the longest) is past 0.51; 3 internodes of 0.25 m, scaled 2 inside
  to 0.2 at the tips, 10° from the branch inside to 80° at the tips (Unreal's axil angle there is measured from the
  perpendicular), 135° round from the last. New wood: twigs deep in the crown. (Unreal sets 3 a branch at plant
  gradient levels 0.51, 0.76 and 1; on outer branches only the last lands, at the tip; 2 here.)
- **Clumped twigs**: the twig a 0.34 m shoot of leaves set round it (spiral, 43° forward), not a frond; hung
  alternate in a plane of each branch's own (`Twigs.roll` 60° from the level; Unreal resets the phyllotaxy to the
  bud's frame, which is no more level than the branch); `Twigs.sparse` 0.85 (Unreal's palette picks at random, all
  as leafy).
- **Shape**: the trunk's `sproutLight` at Unreal's own value, 0.44: the first branches climb and the crown rounds,
  8.4–9.7 m by 11.2–12.2 m over seeds 5 and 9 (Unreal's 9.5 by 8.9, 12.15).
- **Colour**: leaves lighter and greyer (crown 88/92/63 sRGB against Unreal's 93/96/77; it was 63/69/42), bark greyer
  and darker (Unreal's trunk 86/79/69; ours was 115/98/86). Unreal's grey is likely its leaves' specular sky sheen,
  which our camera leaves skip (reflections: the diffuse GI stands in); the albedo stands in for it here.
- Every other species is byte-identical in the workshop's shots (an unset roll draws no random number).
- Forest shot (dev build, one run): 8.1 ms, about where it was before this work (the grafts' twigs back up from 916 to
  about 1,200).

## Plants as programs, the graph as Swift (2026-10-30)

- `Program/`: `PlantProgram` (a species' two functions, `twig` and `plant`), `PlantContext` (the stages; `Mode.trace` writes
  down what's called without growing), `PlantGraph` (the same as data; `run`, `standard`/`project`/`applying` to and from
  the recipe), `PlantPrograms` (`runner(for:)`: a compiled program, the graph, the built-in program, the recipe),
  `PlantCompiler` (over `EngineCore/Util/SwiftBundleCompiler`, which the wrangles use too).
- `Program/Swift/`: `PlantSwift.emit`/`parse`, the file's shape. A stage is `let name = p.stage(wires) { $0.a.b = literal }`,
  a line only for what differs from the stage's preset (`.standard`, `.twig`), in the fields' order (Mirror). Reading applies
  the lines to the preset's JSON tree (`PlantTree`), numbers as written, Swift's way through `?.`. Anything else is a
  `.statement` node, kept verbatim. `PlantLiteral.float` keeps a literal exact by way of a Double, which is how the
  compiler reads it.
- The random numbers' order is what keeps the goldens: a plant draws its growth seed in `grow`, its root bone's phase in
  `skeleton` (so a fern's and a dead tree's come at the same place as a tree's), the leaves in `output` or `twig` (not in
  `leaves`), limbs' phases then per twig `int(3)`, roll, phase in `output`. A twig grows from its seed and draws its leaves
  from `seed ^ 0x51ED_2701`.
- The fingerprint is in the scenes' mesh names: `SpeciesDef.fingerprintForm` takes a standard graph out, so a built-in's
  stays what it was (`PlantProgramTests`, `Fixtures/builtin-species-v2.json`) and a node moved regrows nothing.
- `Programs/*.swift` are the emitter's output: after changing the emitter, write them again or `testTheBuiltInFilesRoundTrip`
  fails (parse then emit each and write it back). Not done: a graph's node previews.

## Gravity and Bone Reduction nodes (2026-10-30)

Read from the plugin's source (`Private/Implementations/PVGravity.cpp`, `Private/Facades/PVBoneFacade.cpp`), in original
code. No built-in uses either, so a graph with one isn't `isStandard`, and its fingerprint is its canonical graph's.
- **Gravity** (`p.gravity`, on the growing wire; `Growth.Gravity`, `Plant.bend`): `GrowerTests.testGravityIsUnrealsGravity`
  runs Unreal's loop, written out line by line, against it. Unreal's is the same on a branch: lerp(tangent, pull,
  strength / 10 × (1 − radius gradient) × angle term), the turns composed along the branch and into its children; the trunk
  bends too. Differences: a nil `direction` is away from the plant's sky, so a twig's "down" is its -Z (Unreal's is
  world -Z); the phototropic pull is each point's `lightDirection`, not Unreal's mix of the two bud light vectors with a
  hidden bias. Its tooltip says angle correction 1 is no bend; its code gives a tenth of the bend along the pull, and
  this follows the code. `Params.gravity`'s sag stays in the Grower, so the built-ins don't change, and Unreal has both.
  The defaults' strength is the sample tree's (0.329 there), Unreal's default being 0.
- **Bone Reduction** (`p.boneReduction`, on the skeleton wire between the Mesh Builder and the Output, where Unreal has it
  between its Mesh Builder and its Foliage Distributor; `Growth.keptBones`): Unreal keeps lerp(n, 1, s) bones between a
  branch's joints, and its bones run along the wood. Ours are a root, one for each limb and one for each twig, so the
  twigs of a stem are what's reduced, and the limbs always stay: strength 1 is 1 + limbs + stems with twigs. The draws
  are the same at any strength, so meshes and transforms don't change; a kept bone keeps the bone it was. A group turns
  about its footmost twig; `Bone.swing` keeps its far twigs from flying (only `Scene+Forest` reads it, ×1 when not shared).
- **What it doesn't do:** make a frame cheaper. Unreal's skinning cost goes with its bones; the forest copies a bone's
  pivot, axis, angle and phase into each part (`Assembly.Part.bough`), one per part however many share it. Worth doing
  only with a palette of bones in the wind pass.

## Manual Edit (2026-10-30)

Read from `PVManualEditSettings.cpp`, `PVManualEditTool.cpp`, `PVSkeletonPointsSelection.cpp`, in original code.
- **One hero plant, the user's choice:** Unreal has one plant; a species here has many, and a plant's seed goes with the
  scene's (`Foliage.seed`). The node holds an age, a variant and a seed. `SpeciesDef.plantSeed` (the library and the workshop's
  skeleton) grows that age and variant from it; the stage edits only a context of that seed. Twigs hang in the same places;
  the palette's own twig meshes still go with the scene's seed.
- **Unlike Unreal's storage:** it keeps a dense absolute offset for each bud, so a rotation near the foot writes every
  point. Here (`Plant.edit`) each edit is local to the tree's frames: a point's internode longer by `moves[k]`, it and all
  beyond it turned by `turns[k]` about its parent. A rotation is one entry for each thing on the point, and a soft move
  is `weight - parent's weight` per internode, so the file stays small and a compiled file's array literals stay cheap.
  Unreal's tool writes its rotation only into a point's own branch and two levels of children; this carries everything.
- **Differences:** a move carries what's beyond by default (Unreal's leaves a kink; off is its behaviour); a cut thins all
  that's left on the branch, not its nearest children only; the first axis keeps its first internode, so a plant always has
  a trunk. An unedited point stays to the bit (`touched`).
- **Stale edits:** point numbers are the grower's, and an edit of an earlier stage can renumber them. `grown` holds the
  count; the inspector warns if it changed, and numbers past the end are skipped. It can't see a change that keeps the count.
- **Where things are:** `Program/PlantManualEdit.swift` (the settings, `Plant.edit`, `plantSeed`, `PlantEditing`: picks,
  weights, tools, lines), `MetalRenderer/Plants/Renderer+PlantTool.swift` (overlay, handle, mouse), and
  `Editors/Plants/PlantEditorModel+ManualEdit.swift`, `ManualEditInspector`. A drag runs the workshop as a slider does.
- **Checked:** `PlantManualEditTests`, `PlantEditorTests.testManualEditTool` (the model with a stand-in host), the
  renderer's mouse through a script on a headless app (arrows, rings, clicks, Option, hover), and the real window:
  `METALRENDERER_PLANT_EDIT_SCRIPT=<folder>` (`PlantManualEditScript`) sends mouse events to the inspector's tool and the
  view, with pictures and a line for each check. Run it as a copy of the binary under another name with
  `METALRENDERER_PLANTS=builtin`, and `defaults delete` that name after: the copy's draft is otherwise there next time.
  Not checked with a person's hand: Option-drag and the Clear buttons in the window (their actions were called directly).
  Highlights ignore the wood's noise (`Plant.placed`), so they can sit up to its amount off the tubes.
