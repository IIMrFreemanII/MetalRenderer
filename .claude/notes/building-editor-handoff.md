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
   edit; if the night frames are still over ~15 ms, try ReSTIR for interiors at night and fewer lights per room.
2. **Metal 4:** never run with interiors. Moving doors and lifts (animated instances, top level refit only on frames
   that move), the city's interior swaps (named meshes kept, `isSameCity`), the workshop's fast rebuilds, the
   physics props (CPU-stepped bodies drawn as meshes). `METALRENDERER_API=metal4 -m buildings`, compare with Metal 3.
3. **The open world's interiors are still** (doors open, no switches, lifts parked, no physics): its instance groups
   need a still scene (`SceneBuffers` guard). Lifting that (per-slot instance tables with groups) would give the
   world what the city has.
4. **Interiors on demand in the city:** time the swap (background prepare + install) in a 10×10 city on the M4 Max
   (it regenerates every building; a cache of built buildings would make it cheaper).

## Interior lighting (Oct 15)
Interiors looked flat by day: radiance cascades lit their hits by the sun's light map, one orthographic map over the
scene (the workshop's 20 km ground made its texels ~220 m), which saw no wall or ceiling, so every room glowed
evenly with sunlight. Now:
- **`Scene.interiorBox`** (set by `BuildingKit.addInterior`, passed as `Uniforms` / `GPUFogParams` `interiorLo/Hi`):
  inside it GI's hits trace a ray toward the sun's centre (`giSunVisibility`, 32 m or 4 map texels, then the map),
  the cascades' intervals overlap by half (fewer leaks through walls), and the fog's sky light is occluded by one
  ray up (`fogSkyAmbient`; it lit closed rooms with a haze). Outside the box everything renders and costs as before:
  through the forest's leaves the rays cost +35 ms (fog +18, cascades +14) on the M1 Max.
- **Lights by day** in rooms with no window of their own and an office's work rooms (`RoomType.litByDay`,
  `Interior.Light.day`; the open world's stay on by day).
- **The city has auto exposure** (`PostSettings.preset`): a room lit by its windows was black at the street's.
- **Interiors were different every launch**: storey keys and wall paints were seeded by Swift's per-process
  `Hasher`. Now FNV (`Hasher64`); `BuildingPlanTests.testInteriorsAreTheSameOnEveryLaunch` pins a fingerprint.
- **Against path-traced GI** (bench `buildings`, `METALRENDERER_GI=mode=pt`, before the day lights): RMS by day
  living room 52 → 21, stair 87 → 3, office floor 48 → 26, city interior 67 → 4, world interior 64 → 33.
- **Cheaper lights (same day):**
  - **Pieces:** a room's ceiling panels are one rect light per 8 m piece (`Interior.Light.panels`, drawn as its proxy
    mesh at the panels' own radiance, `Scene.addLight(proxyEmission:)`). A house has 46 lights by day (was 66), the
    office tower 189 (was 423, so no ReSTIR).
  - **Reach:** a rect light lights only its storey under it (`Scene.Light.reach`, GPULight `axis.w`, `rectReaches` in
    the diffuse, specular and fog evaluations; not in the reference path tracer), so the street and the other storeys
    spend no shadow rays on it.
  - **Fewer repeat picks:** GI's cached lighting lights a light picked several times once (by day the sun takes most
    picks: 4 sun rays a hit before).
  - **Two shadow rays a group** in scenes with interiors (`FramePlan.manyLightRays`): an open office speckled with
    one; two cost ~0.4 ms, ReSTIR ~6 ms.
- **Cost (release, whole frames; before the fix, after it, now):**
  - house outside 9.6 → 16.9 → 13.5 ms;
  - living room by day 9.0 → 18.1 → 13.7 ms;
  - office floor 10.0 → 26.5 → 19.1 ms;
  - city interior 9.9 → 21.8 → 16.4 ms;
  - world interior 25.4 → 35.2 → 29.9 ms;
  - nights back to before (21.0, 25.0 ms).
- **No blotches:** a room lit by a small bright patch (the sun on a sofa) showed blotches on its walls: the cascades'
  fixed rays caught the patch or missed it, probe by probe. In the interiors' box each probe's rays now take a new
  place inside their bins every frame and the resolve averages the frames (reprojected, 10% a frame:
  `RC_INTERIOR_BLEND`); elsewhere the rays stay fixed and history-free. About 0.3 ms. The indirect light now settles
  over ~20 frames after a light switch or a door; not looked at in motion in the window.
- **Still to do:** the fog's lamp light (`FogSettings.lights` off saves 0.3–0.8 ms but drops the lamps'
  glow in the haze). Check in the window and on the M4 Max.

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
