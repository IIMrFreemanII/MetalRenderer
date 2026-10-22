# Cars: handoff

Phase 1 on branch `claude/car-physics-deformation-7275c3` (PR #120); phase 2 on `claude/car-breaking-damage`, from
phase 1's tip. Node-beam (BeamNG-style) cars that drive, dent and break. The plan is
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

## The car pack (after phase 1, on this branch)

- The user asked for downloaded models in place of the procedural bodies. They chose Sketchfab's "Generic passenger car
  pack" by Comrade1280 (CC BY 4.0, credited in the README's "Cars"), downloaded through their Chrome as glTF:
  `Assets/Cars/generic_passenger_car_pack.glb` (26.7 MB, Git LFS).
- `CarPack.swift` reads it: each style's body node by name (`CarPack.bodies`, with which way its front is in the node's
  space), its `_Body_0` / `_Optics_0` / `_Glass_0` meshes, and the four `Wheel_` nodes in its footprint.
  `GLTFLoader` now keeps each part's node path (`partNodes`, `nodeNames`).
- The car's frame comes from its shape (the long axis of its footprint, squared with its wheels), not its node: the
  pack's coupe sits at an angle in its own.
- `CarSpec.fitted(to:)` sizes the crash frame from the model and measures its profile (`CarProfile`: the top, the width
  below the belt line, the top's width at 48 stations).
- `CarSurface(_:model:)` embeds the model's meshes. Seam copies of one place share an embedding (no cracks) and, where
  their normals agree, their rings (smooth shading).
- `Scene.addCar` adds only the materials and textures each car uses (`packTextures`: the pack has 39 textures of
  2048 x 2048). The paint is its texture under the clear coat.
- New styles: wagon, compact, minivan, sports car, SUV, off-roader. Their presets are sized from the models.
- The procedural look is gone (the user asked): the lofted panels, the built wheel, the colour paints. A car is
  drawn only as its model (`Scene.addCar` returns nil without the pack, and the scene logs it). The presets' key
  heights remain as the crash frames of the physics tests.
- `-m carsmodels` renders the lot (two shots for all ten) and two close-ups.
- **Front-wheel drive's wander: fixed.**
  - Probing a wagon's launch showed its front wheels toeing out 2.7° under front-wheel drive (0.2° under rear),
    the knuckle turning while the tie rod kept its length.
  - The pull moved the knuckle forward on its mounts (one Gauss-Seidel pass leaves them soft: two passes over all
    beams halved it), and it turned about the tie rod's end behind the axle.
  - Now, in `CarBlueprint.buildCorner`:
    - the steering arm is ahead of the axle (front steer, the steering's sign flipped);
    - a rear knuckle has a second toe link behind its axle;
    - the corners' beams (`CarBeam.cornerBit`) get `CarSolver.cornerPasses` (2) more passes a substep while under
      half their yield.
  - The toe under power is 0.1–0.3°, every style runs within 3° of straight, and the minivan is front-wheel drive again.
  - Self-aligning torque was tried and taken out: it changed nothing (10 N·m against 450).

## Traps found (keep them)

- **Toe compliance.**
  - A knuckle whose tie rod's end is behind the axle turns about it when the drive pulls the knuckle forward on its
    mounts: front-wheel drive toed out and wandered.
  - Moving only the front arms ahead of the axle, with the rear ones behind, was worse: several cars spun.
  - Solving the corners' plastic mount beams again in a crash stiffened the front: 0.30 m of crush in place of 0.35.
    They are passed again only under half their yield.

- **Hot loops on a class.** The car solver's statics live on `CarSolver` (an enum), not on `PhysicsWorld`: a call the
  stages' closures don't inline would look up the class's metadata, which `Tools/perf/hotcalls.py` refuses. The
  cars' 17 loops are in `Tools/perf/hot-functions.txt`, and the check passes.

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
- **No hand test in the window:** keys, HUD, captured-mouse orbit.

## Phase 2: breaking and the damage look (branch `claude/car-breaking-damage`)

- **Parts** (`CarBlueprint.buildParts`, `addPart`, `addMirror`): bumpers, hood, trunk lid (not a pickup's or a
  hatchback's), two or four doors, mirrors where the model has them (`CarSpec.mirror`, measured in `fitted`). A part is
  twins of the body nodes under it, 2 cm out (`partGap`), its triangles' edges and bend beams (`.panel`), compression
  supports to its body twins, and attachments (`.attach`, `CarBeam.attachBit`, the part in `info >> 24`).
  `CarSystem.parts` (`CarPart`: node range, holding, flags off/frozen). Hull tags (`hullTags`) say which body triangle
  is which panel; a bumper takes only the end below the belt line (the whole end took a pickup's tailgate, and float32
  precision on a thin twin triangle drifted its vertices 2 cm).
- **Attachments** break when the body node they are fixed to is crushed (`CarSolver.mountCrush`, 6% flow); a part with
  less than half left is torn off (`tornBelow`), its supports let go, and it is frozen once still for 1 s (inverse mass
  0), woken in `carBroadPhase` by a body coming near.
- **Wheels and arms:** wishbones, tie rods and toe links are plastic `.arm` beams (40 kN yield, 90 kN strength), their
  load from the substep's lambdas after the corners' passes (`armLoad`). A wheel comes off (`CarWheel.off`: flags
  cleared, body friction back, `wheelBit` cleared) when 3 of its `links` break or its axle's knock along the ground in
  one substep passes 32 kN (`axleKnock`).
- **Glass and lamps** (`CarSurface.panes`, `CarPane`): panes by facing and place, lamps by corner. Broken when the frame
  strains past 0.8% (lamps' flow past 3%) or the door they are in comes off. The break bit is in the car's first
  nodes' `info.z` (bit 24 + pane % 8, node first + pane / 8); `GPUSoftVertex.embeds.z` holds `carVertexBit | pane+1 |
  lampBit`, `.w` the car's first node. The kernel folds a broken pane's vertices to the first node, darkens a lamp.
- **Engine** (`CarDamage.swift`): `frontCrush` = mean of the 4 front-end nodes that came back furthest toward the
  engine (rest-length shortening measured buckled beams as 0.2 m at 100 km/h). Radiator leaks from 0.08 m; coolant →
  heat → power cut → seize; block damage from 0.5 m (1 at 0.8 m). Steam / smoke events every 6 steps.
- **Look:** node `info.z` bytes crush / scrape / dirt (`crushNode`, `wearNodes` from `CarSystem.wear`, which
  `nodeContacts` fills via `sliding`). `SceneBuffers.damage` (uchar4 per vertex, only with cars) at
  `SceneShading.damage` (offset 296, `Renderer.shadingDamageOffset`); `Surface.metal` `carDamage` (primer, bare steel,
  dirt, dark lamps), only where the material has a coat for the paint part.
- **Events → particles:** `CarSystem.events` per car, logged into `breakLog` in `endCarStep`; `CarRig.breakProxies`
  (`Scene+CarDust.swift`) wired into `ParticlesGPU.breakRing` in `Renderer+Setup` for worlds with cars.
- **Tests:** `CarDamageTests` (10); `CarTests` length now leaves parts out. `-m carsdamage` renders the wall at 50 and
  100 km/h. Hot loops: `damage`, `crushNode`, `wearNodes`, `tear`, `letGo`, `armLoad`, `flow`, `sliding`; hotcalls
  passes (a SIMD2 static constant made a swift_once: plain Floats).
- **Cost:** carscpu 1.25 / 1.9 / 2.8 ms for 1 / 4 / 8 cars (P1: 0.92 / 1.6 / 2.2), over the 2.5 ms target at 8 cars.
  The solver is inlined into one closure, so `sample` can't split it further; parts are ~25% more nodes and beams.
  Corner beams are now last (`firstCorner`) and parts' edges aren't hull beams: both small gains.

- **After the first hand test** (the user's recording: an off-roader's front wheels sideways, the camera stuttering):
  - The front steering arm was 10 cm inboard of the kingpin, 54° from the tie rod's line: steering full left then full
    right put the right wheel over centre (−102°), and centred both stayed at ±73° (the car couldn't pull away). The
    arm is straight ahead of the kingpin now (`buildCorner`); `testSteeringLeavesTheTieRodsStraight`.
  - The chase camera aimed at the latest step's car, 60 steps a second against 75–80 frames: car worlds draw their
    stepper's recent steps blended (`PhysicsStepper.recent`, `Drawn.between`, `Scene.drawnBetween`, `drawnFrame`,
    `physicsLag`, `physicsShown`). The second recording still stuttered: the camera ran in `update`, before
    `Scene.update`, so it chased the car a frame behind; it is in `SceneBehaviour.lateUpdate` now, aimed at
    `CarTelemetry.centre`. `testFramesBetweenStepsAreSmooth`: speed change from frame to frame 50% → 2%.

### Traps found in phase 2

- **Stiff beams' load from stretch.** An arm at 5e7 N/m read a millimetre of solver slack as 50 kN and bent at rest:
  the car sank and couldn't drive. Use the constraint's lambda / h² over the substep.
- **Attachment strength per beam.** Each beam of a hinge carried the whole hinge's strength: four times too strong.
- **Attachments as stiff as the body** yielded at 0.3 mm; the body's flex in a crash at the front tore off the rear
  bumper and trunk lid, and at rest bent the mirrors. They yield 3 mm out now, and break when their mount is crushed.
- **Axle loads averaged over a step** can't tell a curb from a speed bump (both ~40 kN; along the ground 19 vs 17 at
  the rear). The hardest substep's knock along the ground separates them (39 vs 23 kN).
- **ParticleSystem.maxPerEvent is 8**: more traps at launch, no message (lldb showed it).

### Not done in phase 2

- Detached parts don't meet their own car (P3's car-vs-car solver).
- A car that rebounds off a wall rolls back freely (no rolling resistance).
- No A/B against a baseline build for the other scenes: the shading reads damage only when `SceneShading.damage` is
  set (worlds with cars), and the kernel's change is behind the car vertex bit.
- 8 cars over the cost target; the window hand test (keys, HUD with damage lines, the dust in motion).

## Next phases

- **P3 — car against car and the world:**
  - car vs car (node vs hull triangles);
  - node pushes into fractured pieces with `strike`;
  - rigid props;
  - tyres on bodies.
- **P4 — cameras, slow motion, replay, demos:** hood/cockpit/orbit cams on C, slow motion, instant replay ring, crash
  demo modes with video.
