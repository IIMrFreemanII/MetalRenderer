# Cars: handoff

Branch `claude/car-physics-deformation-7275c3`. Node-beam (BeamNG-style) cars that drive and dent. The plan is
`/Users/ndiahovets/.claude/plans/add-car-physics-and-tender-wadler.md`; the design is in the README's "Cars" section.

## The user's choices

- **Deformation:** node-beam soft bodies.
- **Driving:** full simulation (rigid wheels, suspension, Magic Formula tyres, engine, clutch, gearbox, differentials).
- **Scene:** a new test ground; procedural cars in four styles (sedan, hatchback, pickup, coupe).
- **Breaking:** parts fall off, wheels and suspension break, glass shatters, the engine takes damage.
- **What it hits:** statics, other soft cars, fractured breakables, rigid props.
- **Controls:** keyboard + chase cam, more cameras on C, slow motion + replay, scripted crash demos.
- **Look:** full by default, solid too; clear coat in P1; damage shows as scraped paint, scratches and dirt, and broken
  lights.
- **Scale:** 4–8 cars, about 300 nodes each.
- **Backend:** CPU first, GPU later.
- **Delivery:** phased, one PR each.

## Phase 1: done (this branch)

- `Sources/Physics/Cars/`:
  - `CarSpec` (styles, profile);
  - `CarBlueprint` (nodes, beams, suspension, mirrored beam order);
  - `CarSurface` (panels, embedding);
  - `CarTypes`;
  - `Physics+Cars` (building, broad phase, stages, telemetry, `car` command);
  - `CarBeams` (axles, beams, contacts, breaking);
  - `CarDrivetrain` (input, engine, clutch, gearbox, diffs, brakes, assists);
  - `CarTires` (tyre).
- Hooks:
  - `PhysicsCPU.stepStages`: `carBroadPhase`, `carForces` before `integrate`, `solveCars` and `applyCarReactions`
    before `solvePositions`, `endCarStep`.
  - `beginFractureStep`'s command loop factored into `runCommands`.
  - `carBit` particles skipped by the particle stages.
  - `wheelBit` bodies skip the world's speed cap.
  - `Drawn.cars`.
- Engine:
  - `Scene+Cars.swift`: `addCar`, `addCarMaterials`, the wheel mesh, `CarRig`.
  - `addDeformingInstance(mask:)`.
  - `SceneBehaviour.drawn(_:_:)` now takes the whole `Drawn`; new `keyUp` hook.
- Game:
  - `Scene+CarGround.swift`: wall, poles, barriers, ramps, bumps, parked lot.
  - `CarPlayer.swift`: keys, chase cam, HUD.
  - `Benchmark+Cars.swift`: `cars`, `carsfull`, `carscpu`.
  - Settings rows: `carstyle`, `carcount`, `cardemo`, `carspeed`, `carassists`.
- Tests: `Tests/MetalRendererTests/Cars/CarTests.swift` (9). `related.sh` maps `Cars/` to CarTests and
  PhysicsThreadsTests.

## Traps found (keep them)

- **Alternating Gauss-Seidel order.** Solving a car's beams forward, then backward, each substep made a two-substep
  rhythm that grew until the nodes hit the 90 m/s cap. Keep one fixed order.
- **Weak floor.** Hanging the engine and the suspension mounts from the floor's middle (a flat sheet of beams) sagged
  the car 2–7 cm. Mounts are a subframe tied to the sides; the engine is held from the sides.
- **Tyre impulse vs the wheel's mass.** A tyre impulse sized for the car's share of the weight, applied to the 20 kg
  wheel, overshot. The slip across flipped every substep and used up the longitudinal grip: launches at 0.06 g. Clamp
  it to stop the slip of the wheel and its hubs only.
- **Open differential and wheelspin.** One spinning wheel yawed launches by up to 24°. Traction control brakes the
  spinning wheel.
- **Automatic gearbox.** Shifting up on engine rpm during wheelspin, then straight back down with the clutch out, looped
  for ever. It now shifts on the gearbox's speed, and waits 0.8 s between shifts.
- **Beam order bias.** Beams solved in their build order (the left side first) pulled launches to one side. They are
  now paired with their mirrors.

## Numbers (M1 Max, dev build)

- `carscpu`, `cpu` column: 1 / 4 / 8 cars → 1.06 / 1.82 / 2.60 ms a frame.
- BLAS refit: 0.13 / 0.56 / 1.14 ms of GPU.
- Wall at 50 km/h: front crushed 0.37 m, cabin floor −1.4 cm, 178 beams bent, 2 broken. At 100 km/h: 1.01 m, cabin
  −32 cm.

## Not done in P1

- **The paint's flakes have no highlight of their own.** The clear coat (done here: `addPaintMaterial`, specular weight
  >= 2) is the renderer's one specular lobe. The flakes' GGX lobe is folded into the paint's colour as its split-sum
  albedo. A true second lobe needs a G-buffer channel and a second highlight in the composite, `LightSampling`, ReSTIR
  and the path tracer.
- **Window outlines are rough.** A paint triangle shows at the C pillar (`CarSurface.look`).
- **No hand test in the window:** keys, HUD, captured-mouse orbit.
- **`hotcalls.py` not run.** The hot loops (`solveCar`, `carForces`, `tyre`, `solveBeam`) need to go into
  `Tools/perf/hot-functions.txt` after a release profile.

## Next phases

- **P2 — breaking and the damage look:**
  - parts table, attachment beams, detached node islands;
  - glass shatter (break events → dust and shards);
  - axle and arm breaks;
  - engine damage and smoke;
  - per-vertex damage channel (scrape, dirt, primer) and broken lamps.
- **P3 — car against car and the world:**
  - car vs car (node vs hull triangles);
  - node pushes into fractured pieces with `strike`;
  - rigid props;
  - tyres on bodies.
- **P4 — cameras, slow motion, replay, demos:** hood/cockpit/orbit cams on C, slow motion, instant replay ring, crash
  demo modes with video.
