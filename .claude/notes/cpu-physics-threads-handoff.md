# Multithreaded CPU physics: handoff

Branch `claude/cpu-physics-threads`, cut from main at 05a2deb (PR #90's destruction and its shots fix). Built and
checked on the M1 Max (10 cores). The design is in the README's "CPU physics on every core" section; this note covers
where things stand and what to do next.

## Done

- `PhysicsPool` (`PhysicsThreads.swift`, C11 atomics in the `CPhysicsAtomics` target):
  - persistent workers;
  - packed ticket `gen<<48 | chunks<<24 | next`;
  - workers spin about 50 µs, then park on a semaphore;
  - an `inside` count keeps a stage's closure alive until every thread has let go of it (without it the closure
    escaped `withoutActuallyEscaping` and crashed).
- Every CPU stage runs on the pool, bit for bit:
  - rigid bodies: broad phase, wake, link, narrow phase, colouring rounds, integrate, joint and contact colours,
    velocities, settle;
  - fracture verdict and apply;
  - particles, cloth, tets and fibres, flesh, skin;
  - hair;
  - PBF and MPM liquids, whose fixed-point sums are atomic `cpa_add32` adds.
- The serial parts stay serial: the colouring's extra-colour greedy pass and its rest segment, ragdoll settling,
  `breakWelds`, commands.
- Allocation-free shape reads: `PhysicsShapeTable` / `PhysicsShapes` (`PhysicsCollide.swift`) and `PhysicsSDFNode`,
  which copies `SDFShape.primitive`'s expressions exactly. It is cached in `shapeView` and dropped when `shapes`,
  `samples`, `sdfShapes` or `sdfVolumes` is set.
- `PhysicsCellGrid` is the broad phases' flat grid (open addressing; each cell's items in insertion order).
- `stepStrand` is static, on `HairBuffers` with stack scratch.
- `Tools/perf/hot-functions.txt` lists the stages, and `hotcalls.py` passes.
- `PhysicsStepper` steps the world behind the frame:
  - a FIFO of (time, grab), at most 2 queued;
  - `sync` for picks, shots and blasts (`Scene.withPhysics`);
  - copy-on-write `Drawn` snapshots;
  - when paused or on a still, the frame waits for its steps.
- Wiring:
  - `Scene.physicsAsync` is set in `Renderer`'s install;
  - benchmarks step in the frame unless `METALRENDERER_PHYSICS_ASYNC=1`;
  - settings rows "CPU physics behind the frame" (`physicsasync`) and "CPU physics on every core" (`physicscores`).
- `DestructionSettings.buildings` (1 to 3 massive buildings) and bench mode `destructioncpu`:
  - courtyard, massive and 3 buildings on the CPU;
  - 3 buildings on the GPU.

## Checked

- `PhysicsThreadsTests`:
  - one thread against all, in 8 worlds;
  - the stepper against stepping in the frame;
  - digests (`PHYSICS_DIGEST=1`) equal to main's single-threaded build in all 8 worlds.
- Main's digests, kept in this session's scratchpad (redo them from a `git archive` of main if needed):

  | World | Digest |
  |---|---|
  | physics | 8376219435fddb6c |
  | ragdolls | cf494d53f6af2e71 |
  | hair | 6b6387beb6a16167 |
  | soft bodies | a0ba67abc9ad6589 |
  | muscles | 1380dbae43f70e38 |
  | fluids | 935db933f06c9358 |
  | destruction | 51920c0b0adf9f39 |
  | massive | ddd80465606fa8f1 |
  | 3 buildings (7 s; added on `claude/cpu-physics-big-worlds`, from main at 58d9774) | bc8fb68c4820d793 |

  On `claude/island-sleep` the three destruction worlds sleep differently (by design), so their digests changed:
  destruction ad62f99b2283e8ec, massive b82dacdd35e4458a, 3 buildings d39bc03a98fa0a7a. The other six are as above.

- Related suites in release pass: BuildingWorkshop, Fluid, Destruction, Hair, Muscle, PhysicsThreads, Physics, Ragdoll,
  ProjectGraph, SettingsTable, SoftBody, Terrain, KernelVariants.
- `CharacterHairTests.testCapsFollowTheStyle` fails, as it already does on main.
- CPU-backend stills are not byte-compared: the destruction still differs between two runs of main's own binary by the
  same amount (rms 0.53). The digests are the proof.

## Not done / not checked

- The window hand test with the stepper on: grab, shoot (2), blast (3), the Fracture Editor rebuilding a CPU scene.
- The M4 Max: thread counts, P- and E-cores, spin length.
- The interior push and terrain edits through the stepper. They go through `Scene.withPhysics` / the stepper's
  `sync`, but they were not exercised by hand.

## Big worlds (branch `claude/cpu-physics-big-worlds`)

The settling phase of three buildings (10 to 13 s, 6,049 enabled bodies) was measured stage by stage, with timers
that were taken out afterwards (one thread / ten):

| Stage | Before, 1 / 10 threads | After, 1 / 10 threads |
|---|---|---|
| Narrow phase | 214 / 29.9 ms | 212 / 27.9 ms |
| Contact positions | 75 / 19.2 ms | 72 / 14.5 ms |
| Contact velocities | 57 / 15.4 ms | 63 / 13.5 ms |
| Broad phase | 119 / 17.7 ms | 33 / 5.0 ms |
| Colouring | 11 / 4.4 ms | 11 / 4.4 ms |
| Whole step | 480 / 88 ms | 395 / 66 ms |

Done:
- **Levelled grid** (`PhysicsLevels`, `PhysicsCellGrid` keys are SIMD4 with the level in w). Cells double in size
  from level to level, and the first level is sized by the enabled bodies' mean radius. A body is in the first level
  whose cell is at least twice its most reach. A query covers each used level's cells within `r + size/2`, with a
  little slack for rounding. Bodies past the 12th level go in `bigBodies`, which every body checks.
- **Pool:**
  - The hot words (ticket, done, inside) are each on a 128-byte line.
  - Each claim takes a quarter of the remaining chunks divided over the threads.
  - `done` is added once a drain, not once a chunk.
  - Colour grain is 8.
- **Exact skips:**
  - still pairs in the solves (`PhysicsWorld.still`, never welds);
  - the narrow phase's memo (`NarrowMemo`: 16 words a body, the bits `collide` reads; invalidated on a refresh, on
    a weld, on any entry not owned at a step's start, and by the shapes' epoch);
  - `movingBodies` for integrate and the velocity pass, rebuilt after each `stepFluids`;
  - `boxGap` stops at the first separating axis.

What did nothing, or got worse:
- A colour grain of 128 or 512 was slower: a pair's cost varies from tens of ns to about 1 µs.
- Narrow and broad grains from 1 to 32 all measured the same.
- The memo and the still-pair skip barely help this world, because its rubble doesn't sleep: at 20 s, 4,605 of
  6,060 pieces are awake. They pay where heaps do sleep.

## Next (toward bigger worlds)

1. Narrow phase (28 ms, real `collide` work on the pieces' cells): cheaper sample tests that give the same bits, e.g.
   checking a piece's `.cell` node first when its join is a plain intersection, skipping the sample if that alone is
   past the margin. Check `SDFShape.join` and float max with signed zeros.
2. Colour stages: about 44 a substep, each about 5 µs to hand out. Islands, or a cheaper barrier, would help. Within
   an island the colours keep their order, and islands are independent.
3. Rubble that never slept: done on `claude/island-sleep` (README "Heaps that sleep"). Three buildings settling: CPU
   step 66 → 20 ms at 25 s; GPU physics 67 → 47 ms (its single-threadgroup substeps are the GPU's limit now).
4. Spin and power tuning: a shorter spin, or none when a stage is tiny.
5. With 3 buildings the frame thread's remaining 5 ms is the renderer's per-instance work (`useResources`,
   `_arrayForceCast` in the instance writer), not physics.

## Traps

- Never touch a world array through `self` inside a stage. Swift swaps the array out while its buffer is lent, so the
  read sees an empty array or races.
- Retain/release on a shared array's buffer from ten threads costs more than the work. Keep shared reads in raw
  buffers or trivial structs, and check with `hotcalls.py`.
- Keep a sum's order fixed. Use integers or a per-item value; never add floats across chunks.
- Measure a stage by timers around its calls in `stepStages` and a gated test; `sample <pid>` on the xctest process
  shows the hot functions. Two test runs at once slow each other: time them one after the other.
- `related.sh` maps a `Package.swift` change to the whole suite. Give it the suite list instead.
