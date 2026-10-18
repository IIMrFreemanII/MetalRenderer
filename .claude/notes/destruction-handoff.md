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
- Scenes without fractures are bit-identical to before (physics scene checked against a baseline build): keep fracture
  code in its own kernels/functions. A branch inside `physPushPair` or the pose kernel changed the GPU's rounding.

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

## Next

- Hand test, then M4 Max timings (`METALRENDERER_BENCH=destruction`, `destructionmassive`).
- Glass cracking at the hit point (a runtime radial pattern into the pre-made pool) if wanted.
- A broad phase that doesn't size its grid from the biggest root (the tower's 2 m): leaves pay for it.
