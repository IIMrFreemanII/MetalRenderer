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

## Next (toward bigger worlds)

1. Compact lists of moving bodies: most stages visit every body, asleep or disabled.
2. A broad-phase grid not sized by the largest body (one big root makes every cell huge), and a parallel grid build
   (sorted cell keys).
3. Spin and power tuning: a shorter spin, or none when a stage is tiny.
4. With 3 buildings the frame thread's remaining 5 ms is the renderer's per-instance work (`useResources`,
   `_arrayForceCast` in the instance writer), not physics.

## Traps

- Never touch a world array through `self` inside a stage. Swift swaps the array out while its buffer is lent, so the
  read sees an empty array or races.
- Retain/release on a shared array's buffer from ten threads costs more than the work. Keep shared reads in raw
  buffers or trivial structs, and check with `hotcalls.py`.
- Keep a sum's order fixed. Use integers or a per-item value; never add floats across chunks.
- `related.sh` maps a `Package.swift` change to the whole suite. Give it the suite list instead.
