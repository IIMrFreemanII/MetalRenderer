# Destruction (Chaos-style fracture): handoff

Branch `claude/chaos-physics-destruction-7f39ee`. Built and checked on the M1 Max (Metal 3; no hardware RT, no Metal 4).
README's "Destruction" section is the design; this is where things stand and what to do next.

## Done

- Fracture trees (`Fracture/`): convex cells, Voronoi / splinters / bricks / radial glass, up to 3 levels, welds at any
  level between neighbours neither holding the other.
- `.cell` SDF primitive (CPU and `SDF_CELL` on the GPU, planes after the nodes in the nodes buffer).
- Physics (`Physics+Fracture.swift`, `Shaders/Physics.metal`): dormant bodies (`disabledBit`), impact strain (both passes'
  normal impulses over 1 m/s), verdict / apply kernels, freeing, anchors (`Scene.foundation` = 25 cm), welds as marked
  pair contacts, weld break by step-averaged load plus a 3 mm / 0.03 rad snap, commands (shoot / blast / wake / release)
  replayed with their step, fading, break events into a 64-step ring.
- Dust and debris: `particleInjectKernel` turns the ring's events into a proxy emitter's per material.
- glTF models cut piece by piece (`MeshCutter`), colliders = baked grid ∩ cell.
- Scene, settings, tools (1/2/3 + `DestructionOverlay`), Fracture Editor (Shift-F), `FractureStore`, bench modes
  `destruction`, `destructiontimes`, `destructionpreview`, `destructionmassive`, `destructiondemo`.
- Scenes without fractures are bit-identical to before (physics, ragdolls, shapes checked against a baseline build): keep
  fracture code in its own kernels/functions. A branch inside `physPushPair` or the pose kernel changed the GPU's rounding.
- Heaps settle (Oct 19, after "the building video looks unstable": its rubble never settled): no edge walk in the narrow
  phase between pieces, partners by box overlap (`physicsFracturePairsKernel`, `shapeBoxes`), one-sided pairs kept
  (`physicsFractureLinkKernel`) and the left-over pairs coloured into extra colours by thread 0
  (`physColourPairs`, `extra`). The building demo blasts all four ground-floor corners (two no longer brought it down:
  part of the old collapse was pieces sinking through each other's dropped contacts). Measure with
  `DESTRUCTION_SETTLE=1 swift test ... --filter DestructionTests/testTheBuildingSettles` (and `testALooseHeapSettles`).
- Shots knock pieces out (Oct 19): a projectile whose hardest hit of a step was on a held piece that broke or came free
  keeps its speed from the step's start (`giveWay`, `startProjectile`, `hitHeld`; the projectile's own fracture state
  holds the speed and the hit); a held piece's children that weren't freed stay held for 0.25 s (`holdAfterBreak`,
  `GPUFractureState.hold`), then stand on their welds. And a real bug: weld anchors were computed from the weld centre in
  shape space against world body positions (`addFracture` now takes the transform), so every weld of an object away
  from the origin snapped at the first small turn after a break. With welds that hold, the massive building stood after
  its corner blasts, so its welds are 0.05x (`buildingStrength` in Scene+Destruction.swift): down by 8 s, steady reach
  7.5 m and height ~1 m from 8 s. Brick wall test: 14 of 103 moved, a hole (it was 0); shot test: 3 knocked out.

## Not done / not checked

- Window hand test: the tools (1/2/3, click to shoot / blast), the overlay, the Fracture Editor (every control, Save).
- Metal 4 and the M4 Max (hardware RT): the `destruction` mode's metal4 still, timings.
- The plan's winding-number sign for model grids: kept the existing three-axis parity vote.
- Dust from CPU-stepped scenes (the ring is the GPU's).

## Tuning knobs that mattered

- `FractureMaterial.toughness` (N s per m² of volume^2/3), `breakSpeed` (the floor: mass x speed, ≤ 4x the toughness
  term, pieces only), `strength` (N per m² of weld face).
- `PhysicsWorld.fractureTuning`: fade delay/length, damage reach (0.18 m x cube root of the excess), freed push (0.15).
- Traps found: XPBD weld forces from one substep are huge (λ/h²), so loads are averaged; welds snapped shut from a cm
  flung pieces; a wall anchored by one course of bricks slid off as a slab; position-pass impulses alone cap at
  pushSpeed (3 m/s), so the velocity pass's impulse counts too.
- Heap traps: the SDF edge walk rocked flat cells (a loose heap of 196 slept 20 % → 100 % without it); rolling
  resistance, damping slow pieces, a lower push cap, looser sleep and denser edge samples did nothing; a slab's full
  pair list dropped the pieces on it (one-sided: about 1,600 a step); solving those one after another on thread 0 took
  0.4 s a step, and scanning every entry on one thread for them 10 ms.
- Knock-out traps (Oct 19): with the ball given its speed back, the welded rest took its push and toppled; what did NOT
  fix that: a piece tearing its welds mid-step once its strain passed its threshold, counting what a struck piece's welds
  pass on as strain, counting a projectile's every contact impulse, capping friction's normal speed between pieces,
  welds in the velocity pass, more substeps (32, 64), no gap snap. Giving back a fraction of the speed is chaotic (0.25
  passed, 0.4 and 0.6 toppled). Holding the rest briefly did it. Debug with a per-piece CSV of the brick test and an
  ASCII front view (rows x columns of displacement) - far quicker than reading counters.

## Next

- Hand test, then M4 Max timings (`METALRENDERER_BENCH=destruction`, `destructionmassive`).
- Glass cracking at the hit point (a runtime radial pattern into the pre-made pool) if wanted.
- A broad phase that doesn't size its grid from the biggest root (the tower's 2 m): leaves pay for it.
