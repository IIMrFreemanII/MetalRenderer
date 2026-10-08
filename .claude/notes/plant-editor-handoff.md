# Plant editor: handoff to the M4 Max (2026-10-08)

Merged into `main` (PR #52, merge `9aeb9ad`). Species as data, the plant workshop scene and the SwiftUI Plant Editor
(K / ⌘E). Built and measured on the **M1 Max (software RT, no Metal 4 ray tracing)** only. The README's "The plant
editor" section has the design and how to use it.

## Where things are
- Species as data: `PlantSpecies.swift` (`SpeciesDef`, age rules, looks, `PlantCatalog`), `BuiltInPlants.swift`,
  `PlantCurve.swift` (curves; the old formulas are presets), `PlantHabitat.swift` (`TreePicker`, covers),
  `PlantStore.swift` (`Assets/Plants/<id>.json`, the draft, the catalog registry, `METALRENDERER_PLANTS`).
- The workshop: `Scene+Plants.swift` (`SceneKind.plants`, layouts, the skeleton view, `PlantStats`, `Camera.framing`).
  `Scene.remadeOften` makes its structures quick to build: one leaf-keep level (`PlantTracing`), no compaction and
  fast-build mesh BLAS (`SceneBuffers`). The orbit camera, `frameWorkshop` and the fast reload (kept textures, GI
  kept, one load in flight, no overlay job: `SceneSettings.isSameWorkshop`) are in `Renderer.swift`.
- The editor: `PlantEditor/` (model behind `PlantEditorHost`, panel, views, `CurveEditor`), `PlantParams.swift` (every
  slider's range; Mutate reads it), `PlantMutate.swift`.
- Bench mode `plants`; tests `PlantGoldenTests` (the built-in plants, forest, valley and world placement as they were
  before the editor: any change of them must change these hashes on purpose), `PlantCatalogTests`,
  `PlantWorkshopTests` (prints reload times), `PlantEditorTests`.

## M1 Max numbers
Workshop reload, scene + buffers (`PlantWorkshopTests.testRemakingIsQuick`): one oak 18 ms, birch ages and variants
59 ms, conifer skeleton 10 ms (before `remadeOften`: 66 / 282 ms). Nearly all of it is the plants' structures; the
scene is about 2 ms.

## To do on the M4 Max
1. **Re-time the reloads** there (`swift test -c release -Xswiftc -enable-testing --filter PlantWorkshopTests`, read the
   `Workshop ...` lines). Hardware RT builds should make them shorter; if the lineup is still over ~50 ms, the
   next knob is fewer wind phases while editing (`Wind.phases` is 8 per assembly).
2. **Metal 4**: never run with the workshop. `METALRENDERER_API=metal4` with `-m plants`, and in the window drag a
   slider: each edit is a scene load (`startLoadingScene` → `install`), so check `Metal4Frame.noteSceneChange` and
   the residency sets keep up with ~30 reloads a second, and compare the shots with Metal 3 (`pngdiff.py`).
3. **`fastIntersection` off in the workshop**: its mesh BLAS are `.preferFastBuild` (macOS 26 would otherwise use
   `.preferFastIntersection`). Check the workshop's frame time doesn't suffer for it on hardware RT.
4. **Kept GI history across edits** (`install`, `sameWorkshop`): on the M4 Max look for ghosting after a big shape
   change (Count to 0 and back). If it shows, reset GI for workshop edits too.
5. **Goldens on the M4 Max**: run `PlantGoldenTests`. They hash CPU-built geometry and placement, so they should
   match bit for bit; if not, something in the Float maths differs between the machines (not expected on Apple
   silicon), and it is worth knowing before anyone trusts them there.

## Not checked anywhere
- Picking a colour in the system colour panel (the Look tab's colour wells open it).
- The open world with an edited habitat in the window (covered by tests and placement hashes only).
