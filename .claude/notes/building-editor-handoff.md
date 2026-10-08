# Building editor: handoff (2026-10-08)

Walkable procedural buildings, the Building Editor (J / ⌘B, with its Floor Plan window) and the building workshop
scene. Built and measured on the **M1 Max (software RT, no Metal 4 ray tracing)** only. The README's "The building
editor" section has the design and how to use it.

## Where things are
- **Styles as data:** `BuildingStyleDef.swift` (ranges and choices; `BuildingStyle.draw`, each value from its own
  stream of the seed), `BuiltInBuildings.swift`, `BuildingStore.swift` (`BuildingCatalog`, `Assets/Buildings/Styles`,
  `overrides.json`, the draft, the registry: `CatalogRegistry.swift`, shared with the plants).
- **Plans first:** `BuildingPlan.swift` (rooms, doors, the stair), `BuildingPlanner.swift` (core, layouts per use,
  the door connector), `PlanEdits.swift` (hand edits by position, `LotOverride`, `LotRef`). The facades
  (`Building+Facade.swift`) follow the plan; fill slots (`Building.Slot.isFill`) are dropped with an interior.
- **Interiors:** `Building+Interior.swift` (walls, partitions, floors, ceilings, stairs, doors' leaves and lifts
  as data, colliders), `FurnitureKit.swift` + `BuildingFurnish.swift` (furniture, lights, switches, loose props),
  `PropLibrary.swift` (glTF props).
- **Scenes:** `Scene+Interiors.swift` (`BuildingKit`: buildings into any scene, interiors, doors, lights, lifts,
  props as physics bodies, `still` for the open world), `Scene+Buildings.swift` (the workshop), `Scene+City.swift`
  (named shells, the interior lot), `Scene+World.swift` / `WorldTile.swift` (the tile without the interior lot,
  `World.version` 7).
- **Walking:** `Walker.swift` (+ `ColliderGrid`), `InteriorControls.swift`, `InteriorLifts.swift`; the renderer's
  walk mode, `chooseInterior` and the motion-gated top-level refit (`lastMotionFrame`) are in `Renderer.swift`.
- **Editor:** `BuildingEditor/` (model behind `BuildingEditorHost`, panel, tabs, Floor Plan window),
  `BuildingParams.swift` (+ `BuildingMutate`). Shared slider rows: `PlantEditor/PlantControls.swift` (`EditorDrag`).
- Bench mode `buildings`; tests `BuildingPlanTests`, `BuildingEditorTests`, `BuildingWorkshopTests`, `WalkerTests`,
  and new cases in `CityTests` and `WorldTests`.

## M1 Max numbers
- Workshop rebuild, scene + buffers (`BuildingWorkshopTests.testRemakingIsQuick`): house 8 ms, six storeys of flats
  39 ms, twelve-storey office tower 57 ms.
- Frames (bench `buildings`, 640×400 → 3×, cascades): outside or a room by day 6–8 ms; at night 18–21 ms (190–420
  rect lights: ReSTIR DI 9–11 ms of it); a city building from inside 9.7 ms.
- Plans: under 3 ms a building with its facades; an interior 7 ms.

## To do on the M4 Max
1. **Re-time** the workshop rebuilds and the bench (`-m buildings`). Hardware RT should shorten the BLAS builds of an
   edit; if the night frames are still over ~15 ms, try MegaLights for interiors at night and fewer lights per room.
2. **Metal 4:** never run with interiors. Moving doors and lifts (animated instances, top level refit only on frames
   that move), the city's interior swaps (named meshes kept, `isSameCity`), the workshop's fast rebuilds, the
   physics props (CPU-stepped bodies drawn as meshes). `METALRENDERER_API=metal4 -m buildings`, compare with Metal 3.
3. **Light leaks:** Lumen's mesh SDFs are coarser than 0.12 m partitions. Look at the bench's rooms with Lumen; if
   they leak, split interior storey meshes into ~12 m pieces when Lumen is on, or say it is not for interiors.
4. **The open world's interiors are still** (doors open, no switches, lifts parked, no physics): its instance groups
   need a still scene (`SceneBuffers` guard). Lifting that (per-slot instance tables with groups) would give the
   world what the city has.
5. **Interiors on demand in the city:** time the swap (background prepare + install) in a 10×10 city on the M4 Max
   (it regenerates every building; a cache of built buildings would make it cheaper).

## Checked in the window (M1 Max, Oct 8)
Every tab; Whole / Cutaway / Dollhouse; Night (40-420 rect lights); the Floor Plan's tools (Split, Type, Merge, Door,
Wall), undo, the edits list; style switching, Seed, Mutate + Use, Compare (hold), Save, Revert, Revert All; walking
(V): doors that open as you come and with E, a light switch, the flashlight, a lift called with E at its landing door
and ridden to floor 3 with the number key, the plan's you-are-here following the floor; the City button, the city's
interior swapped in near the walker (glass holds), Pin of the nearest city building.

Fixed on the way: a rebuilt scene's loose furniture stepped from the app's clock's zero (minutes of CPU physics: the
office tower hung; `Scene.physicsFromInstall`, `PhysicsWorld.advance(to:atMost:)`); flats without a bathroom, a
house-style lot as wide as a block of flats (now flats), office floors without toilets, an all-lobby office ground
floor; full-height glass (shopfronts, curtain walls, balcony doors) let the walker through (`WallOpening.glass` now
decides); a level cab wasn't the walker's platform (number keys did nothing); a lift's landing door is now two
parting leaves and stays open for someone in its doorway; E at a landing door calls the lift; the Floor Plan window
opened over the editor's buttons (it now opens beside it); long slider labels wrap; the lot sliders say metres.

## Not checked anywhere
- Pushing furniture by hand in the window (the boxes may have moved a little; the shove is tested in
  `BuildingWorkshopTests`), jump and crouch by hand, the open world's interiors in the window.
- glTF props with a real furniture model (tested with a generated quad).
