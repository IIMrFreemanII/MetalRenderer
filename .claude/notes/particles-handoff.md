# Particles: handoff (branch claude/init-branch-94ae07)

Ray-traced GPU particle effects (README "Particles"). Phase 1 (the core) is built and checked on the M1 Max; phase 2
(the extras) is next. The plan: ~/.claude/plans/implement-modern-particle-system-typed-origami.md.

## Built (phase 1)

- Emitters, pools, dead lists, alive lists, begin/emit/simulate, events and children, curl noise, colliders (analytic
  and the scene's by a ray a step): `Particles.swift`, `ParticlesGPU.swift`, `Shaders/Particles.metal`; the CPU
  reference `ParticlesCPU.swift`.
- Rays: two primitive structures of boxes a frame (shadow casters, others), billboards per ray, a k-buffer of 4 for
  the camera's layer (composite or MetalFX's transparency overlay), 2 for reflections, stochastic transmittance in
  `isVisibleBlocker`, a light pass a particle, the path tracer's particles: `Shaders/ParticleTrace.metal`.
- Flipbooks generated at load: `ParticleTextures.swift` (cache version 5).
- The Particles scene, the showcase's motes, `METALRENDERER_BENCH=particles`, settings `budget`, `particleshadows`,
  `particlereflections`; `ParticleTests` (16).

## To do on the M4 Max

1. `METALRENDERER_BENCH=particles METALRENDERER_BENCH_ONLY=metal4`: never run (no Metal 4 RT on the M1 Max). Check
   the build goes through `PrimitiveWork4.encode4` in the frame's encoder, and pngdiff metal3 against metal4.
2. Re-time the mode with hardware RT. On the M1 Max the cost is the box candidates' shader work: particle shadows
   (trace +1.9 ms) and the reflections' gather (+2.3 ms) at 640×400; the build 1.3 ms for 5,700 slots.
3. `ParticleTests` there.

## Phase 2 (next)

Ribbons and trails (curves, order-preserving compaction), mesh particles (TLAS slots), six-way lighting,
motion-vector flipbooks, SDF collisions, baked curl / vector-field textures, a build over the alive particles only
(compacted, from a CPU bound), a half-resolution layer.

## Traps found

- The pose's (and reset's) parameters once shared offset 0 of the steps' buffer: the first step of every frame ran
  with the pose's (a burst at step 0 vanished). They have a slot of their own now (`extraParams`); a test guards it.
- A billboard's shadow at full opacity: a column of smoke shadowed itself black. `shadowDensity` (smoke 0.12).
- Shadow rays through every particle's box: rain (4000 non-casting streaks) made the trace 8.7 ms. Hence the casters'
  structure apart.
