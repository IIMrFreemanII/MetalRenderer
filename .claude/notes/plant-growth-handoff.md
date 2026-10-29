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
