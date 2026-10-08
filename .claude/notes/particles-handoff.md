# Particles: handoff (branch claude/init-branch-94ae07)

Ray-traced GPU particle effects (README "Particles"). Phase 1 (the core, commit 8e46917) and phase 2 (the extras) are
built and checked on the M1 Max. The plan: ~/.claude/plans/implement-modern-particle-system-typed-origami.md.

## Built

Phase 1:
- Emitters, pools, dead lists, alive lists, begin/emit/simulate, events and children, curl noise, colliders (analytic
  and the scene's by a ray a step): `Particles.swift`, `ParticlesGPU.swift`, `Shaders/ParticleSim.metal`; the CPU
  reference `ParticlesCPU.swift`.
- Rays: two primitive structures of boxes a frame (shadow casters, others), billboards per ray, a k-buffer of 4 for
  the camera's layer, 2 for reflections, stochastic transmittance in `isVisibleBlocker`, a light pass a particle, the
  path tracer's particles: `Shaders/ParticleTrace.metal`.
- Flipbooks generated at load: `ParticleTextures.swift`.
- The Particles scene, the showcase's motes, `METALRENDERER_BENCH=particles`, settings `budget`, `particleshadows`,
  `particlereflections`.

Phase 2:
- Compacted builds: the pose packs the alive particles at the front of each structure's range; the builds take the
  CPU's bound on how many can be alive (`ParticleSystem.aliveBounds`: births telescope, so O(1) a window).
- Mesh particles (`ParticleEmitter.mesh`): reserved TLAS instances (`Scene.addParticles`), posed every frame before
  the TLAS update from the last frame's steps (`particleMeshPoseKernel`): a frame behind the billboards. The rubble.
- Trails (`ParticleEmitter.trail`): a ring of past places a particle, flat Catmull-Rom curves (ray-facing ribbons)
  in a third structure; the camera's k-buffer and the path tracer take them. The wisps.
- The camera's layer goes over MetalFX's output (`particleOverlayKernel`), not as its transparency overlay (that
  smeared moving sparks into faint streaks); billboards widened to half a texel; particles too thin for the layer
  (under 2 texels) are traced again at the output's size; the rest upsampled by depth (B-spline). `particlescale`
  0.5 makes the layer half size.
- Six-way smoke lighting (aux atlas layers; the light pass keeps the key light apart) with a multiple-scattering
  lift; motion-vector flipbooks (smoke, flame) for the camera's rays.
- Vector fields (`ParticleField`, `ParticleEmitter.field`) and the baked curl tile (`bakedCurl`); SDF shape colliders
  (`ParticleCollider.shape`), GPU only.
- `ParticleTests` (21).
- The rain under a spot light in the ceiling (denser, wider streaks, brighter splashes), and `METALRENDERER_BENCH=particlesdemo`:
  a 24 s camera track recorded for the demo video (`video.sh`; crop the 1920×1200 frames to 1080 for Full HD).
- Heat haze over the fire: distortion particles (`ParticleEmitter.distortion`), their slots between the billboards'
  and the meshes' (`distortRange`, never boxes); `particleDistortDiscsKernel` then `particleDistortKernel` bend the
  frame's light before post (0.24 ms). `ParticleTests` 22.
- The grinder's wheel faces the room with a steel bar on its rim; the sparks leave the contact along the rim, with a
  glow of short-lived emissive dots there. No light at the contact: a fifth light takes the scene to the many-lights
  path (about 2 ms more, and its particle light pass leaves lit particles only the sky's).
- The fire's hot air: `ParticleField.plume`, a push up a widening column (drawn in low, spread out high), which the
  smoke and the heat haze both ride.

## To do on the M4 Max

1. `METALRENDERER_BENCH=particles METALRENDERER_BENCH_ONLY=metal4`: never run (no Metal 4 RT on the M1 Max). Check
   the builds (boxes and the trails' curves) go through `PrimitiveWork4.encode4` in the frame's encoder, and pngdiff
   metal3 against metal4.
2. Re-time the mode with hardware RT. On the M1 Max the cost is the shader's work on box and curve candidates (the
   trails' curve build is ~0.7 ms for 1,260 segments in software).
3. `ParticleTests` there.

## Traps found

- Parameters that share a place in the steps' buffer: the pose's once took the first step's (a burst at step 0
  vanished), then the reset's (its pool size the billboards': the mesh slots' dead list was never set, so the rubble
  took slot 0). Each has a place of its own now (`resetParams`, `poseParams`); a test guards both.
- MetalFX's transparency overlay filters the overlay over time with the scene's motion: fine for still frames, but
  moving sparks, motes and rain became faint grey streaks. The overlay pass replaced it.
- One sample a texel can't draw a spark thinner than a texel: widening alone gives fat blobs, sharper upsampling
  (Catmull-Rom, clamped) gives blocks. Tracing those pixels again at the output's size is what works; leave them out
  of the layer, or the upsampling spreads a halo round them.
- A billboard's shadow at full opacity: a column of smoke shadowed itself black. `shadowDensity` (smoke 0.12).
- Shadow rays through every particle's box: rain (4000 non-casting streaks) made the trace 8.7 ms. Hence the casters'
  structure apart.
- A mesh particle's collision ray starts inside its own instance: it skips its own hits (`instanceId`).
- Clipping at the traced frame's nearest depth: with MetalFX its samples are jittered, so on a floor seen at a
  grazing angle the splash rings (a millimetre over it) were hidden in some frames and shown in others. The layer's
  steady rays and the overlay's clip at the farthest of the 3x3 depths round them on one surface
  (`particleClipDepth`).
- The baked curl tile is a different noise from the analytic one (its lattice wraps): the same statistics, another
  plume.
