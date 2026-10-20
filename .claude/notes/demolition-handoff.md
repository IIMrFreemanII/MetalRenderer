# Demolition scene: handoff

Branch `claude/demolition`. A generated office to blow up: fly or walk, machine gun, rockets, TNT, in a solid look
that tells materials apart.

## What it is

- **Scene** `SceneKind.demolition` (`Scene+Demolition.swift`, settings `DemolitionSettings`, env `demfloors`,
  `demseed`, `demwidth`, `demdepth`, `dempieces`, `demtough`, `demstrength`, `demfurniture`, `demglass`, `demdust`,
  `demfade`, `demdemo`). It opens in solid shading (`applySceneDefaults`, `solidFromScene`) and always steps on the
  CPU: the new commands are the CPU's alone.
- **The building** (`DemolitionBlueprint.swift`). `BuildingGenerator`'s office, with its own plainer style
  (`DemolitionBlueprint.spec`), is cut into blocks:
  - piers, spandrels and glass in the outer walls (windows and doorways go up to the slab: no lintels);
  - slab panels of at most 4 m, cut round the stair well and the lift shaft, with slivers merged;
  - columns where the panels meet inside open rooms;
  - partitions without heads over their doorways;
  - stairs as thin sloped flights, landings and a spine;
  - furniture as one box each, from `Interior.furniture`, which the interior builder now records.

  At 5 storeys that is about 760 blocks and 10,850 bodies.
- **Welds across objects** (`Scene.weldNeighbours`). Every structural block is welded to every block it touches
  face to face, at every level of both fracture trees (`PhysicsWorld.addWeld`). The office is one connected structure,
  as Chaos's connection graph is. Without that, interior slab panels had nothing under them, and thin partitions and
  panes toppled.
- **Commands** (`Physics+Fracture.swift`, `Physics+Demolition.swift`):
  - the CPU's command list is indexed by start step (`commandOrder`, `findLiveCommands`), in the same order, so the
    digests are unchanged;
  - new kinds `hit` (a bullet), `rocket` (goes off where it meets something; `beginDemolitionStep`, serial) and
    `drive` (the walker);
  - `Scene.physicsCommand` sends a command with the stepper's next frame request: no `sync` stall per shot.
- **Walker.** A capsule body that doesn't turn (`walkerBit`). Each step its speed over what it stands on is brought
  toward the input, it jumps, and it is put back where it last stood if it falls out of the world or is stuck. Its
  contacts break nothing.
- **Player** (`Renderer+Demolition.swift`):
  - keys 1 to 4: machine gun (12/s), rocket (8 in the pool), TNT (16 charges; right click sets them all off), Grab;
  - Shift-V walks or flies (plain V is the Material Painter's);
  - Space jumps, Return goes back to where you last stood, Delete takes the charges off, R restarts (drops the
    player's commands and replays from 0).
- **Captured mouse.** `RenderView.captured` hides the cursor, holds it in the middle and sends moves as looks.
  `RendererController.setCaptured` takes the mouse on the first click and lets it go on Esc, on the Grab tool, on
  another scene, and when the window or app is left.
- **HUD.** `DemolitionHUD.swift`: a crosshair and a tools box, an AppKit view over the render (never in frames).
- **Solid look** (`RenderSettings.solidLook`, `Shaders/Output.metal`):
  - `solidTraceKernel` → `solidResolveKernel` give material colours, broken faces darker and warmer
    (`Scene.materialFlags`, `markCutFace`), a tint per object, outlines, the sun's shadow, and AO filtered over 4×4
    pixels;
  - `classic` keeps the old grey kernel;
  - `hitMaterialIndex` is shared with Pick.

## Verified (M1 Max)

- **Tests.** `DemolitionBlueprintTests` and `DemolitionTests`:
  - every block is supported and nothing starts inside anything;
  - it stands when everything is woken at once (a few cm of settling, a few light pieces jolt);
  - a blast stays local;
  - bullets chip, and a rocket goes off where it was aimed;
  - the walker falls through a blown hole and climbs a flight;
  - a replay is identical.
- **Threads.** `PhysicsThreadsTests` has a `demolition` world (1 thread and all agree).
- **Digests.** The existing worlds' digests equal main's (physics … 3 buildings).
- **Offscreen.** `METALRENDERER_BENCH=demolition` (solid), `demolitionfull`, `demolitioncpu`.

## Not verified

- **The window.** Capturing the mouse, the HUD and actually playing. The user hand-tests; no window was opened.
- **The M4 Max and Metal 4.**

## Next

- **Tuning.** How strong the welds are (the office is sturdy: corner TNT doesn't bring it down), the blast sizes,
  and the walker's feel.
- **Solid look cost.** About 7 ms at 1920×1200 with 1 AO ray (classic 2.8). If the window's size makes it too slow,
  trace at half size and resolve with a depth-aware upsample.
