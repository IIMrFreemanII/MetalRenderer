import Metal
import Physics
import simd

// The particles' structs shared with the shaders (Shaders/Particle*.metal). Their memory layout MUST match the MSL
// structs of the same name exactly (validateGPULayouts, in the engine, checks every one).

/// A particle effect's particle (Particles.swift): MSL Particle. Its slot in the pool is its emitter's until it dies.
package struct GPUParticle {
    package var position = SIMD4<Float>()            // w = age (s)
    package var velocity = SIMD4<Float>()            // w = lifetime (s)
    package var info = SIMD4<UInt32>()               // x = spawn id (its emitter's count, or its parent's x 8 + which child),
                                             // y = seed, z = emitter, w = flags (ParticleSystem.alive)
}

/// What rays meet of a particle this frame (Shaders/ParticleTrace.metal): MSL ParticleRender. One per frame slot,
/// written by particlePoseKernel, its radiance by particleLightKernel.
package struct GPUParticleRender {
    package var centerRadius = SIMD4<Float>()        // w = radius (0: no particle)
    package var axis = SIMD4<Float>()                // velocity / axis: the long axis's half (its length the half length);
                                             // world: the normal; w = spin (rad)
    package var color = SIMD4<Float16>()             // rgb: albedo (lit) or emitted light (emissive), a: opacity
    package var radiance = SIMD4<Float16>()          // rgb: the light it scatters to the eye (particleLightKernel), a: unused
    package var info = SIMD4<UInt32>()               // x = pool slot | ParticleEmitter.Flags << 24, y = flipbook frames
                                             // (ParticleTrace.metal), z = soft distance (m, half) | shadow density
                                             // x 255 << 16 | atlas layer << 24, w = seed
    package var keyLight = SIMD4<Float16>()          // rgb: the light of its brightest light (particleLightKernel), apart from
    package var keyDir = SIMD4<Float16>()            // `radiance` for six-way smoke; xyz: where it comes from (unit)
}

/// An emitter as the kernels read it (Particles.swift): MSL ParticleEmitter. Written once.
package struct GPUParticleEmitter {
    package var origin = SIMD4<Float>()              // w = the shape's radius
    package var axis = SIMD4<Float>()                // the shape's and the velocity's axis (unit); w = the velocity's spread
                                             // about it (half angle, rad)
    package var extent = SIMD4<Float>()              // a box's half extents; w = the shape (ParticleEmitter.Shape.code)
    package var velocity = SIMD4<Float>()            // added to every particle's; w = a child's share of its parent's
    package var speed = SIMD4<Float>()               // x...y = speed (m/s), z = 1: outward from the origin, w = the step it starts
                                             // at (steps count from the start, ParticleSystem.stepLength each)
    package var life = SIMD4<Float>()                // x...y = lifetime (s), z = particles a step, w = the step it stops at
    package var burst = SIMD4<Float>()               // x = the step it bursts at, y = how many, z = every (steps, 0: once),
                                             // w = bursts (0: no end)
    package var forces = SIMD4<Float>()              // x = gravity's share, y = drag (1/s), z = the wind's share, w = curl noise (m/s^2)
    package var noise = SIMD4<Float>()               // x = curl noise's frequency (1/m), y = its scroll (1/s), z = vortex
                                             // (m/s^2), w = attraction (m/s^2)
    package var attractor = SIMD4<Float>()           // the vortex's and attraction's centre; w = restitution
    package var size = SIMD4<Float>()                // x = radius at birth, y = at death (m), z = random shrink (0...1),
                                             // w = stretch (velocity: s; the long axis's half grows by speed x it)
    package var color0 = SIMD4<Float>()              // rgba at birth
    package var color1 = SIMD4<Float>()              // at `look.x`
    package var color2 = SIMD4<Float>()              // at death
    package var look = SIMD4<Float>()                // x = color1's place in the life (0...1), y = emitted light's scale
                                             // (0: lit), z = soft distance (m), w = most spin (rad/s)
    package var flip = SIMD4<Float>()                // x = frames, y = frames a second (0: the whole life), z = 1: random first
                                             // frame, w = the atlas kind's trim (its picture's radius, 0...1)
    package var lock = SIMD4<Float>()                // axis: the axis (unit); world: the normal; w = friction
    package var ids = SIMD4<UInt32>()                // x = first slot, y = capacity, z = parent (ParticleSystem.none), w = flags
    package var ids2 = SIMD4<UInt32>()               // x = children an event, y = colliders (mask), z = orientation code,
                                             // w = atlas layer | shadow density x 255 << 8
    package var ids3 = SIMD4<UInt32>()               // x = a mesh emitter's first instance (ParticleSystem.none: billboards),
                                             // y = a trail's places (0: none), z = its first trail, w = steps apart
    package var extra = SIMD4<Float>()               // x = collision radius (m), y = a trail's width (of the particle's),
                                             // z = distortion (rad), w = its seeds' salt (bits: ParticleEmitter.seed)
    package var field = SIMD4<Float>()               // x = its vector field (-1: none), y = strength, z = 1: a velocity it
                                             // follows (else an acceleration), w = the baked curl's field (-1: none)
}

/// An emitter's program as the VFX library's kernels read it (VFXProgram; MSL VFXEmitterInfo).
package struct GPUVFXEmitter {
    var ids = SIMD4<UInt32>()                // x = program (0: none), y = its parameters' first float4, z = hooks
                                             // (VFXProgram.Hooks), w = its rate curve's first float4
    var attributes = SIMD4<UInt32>()         // x = the attributes a slot keeps (the system's)
}

/// A vector field as the kernels read it (ParticleField): MSL ParticleFieldInfo.
package struct GPUParticleField {
    package var lo = SIMD4<Float>()                  // the box's corner; w = 1: periodic
    package var size = SIMD4<Float>()                // its size (a periodic one's period)
    package var dims = SIMD4<UInt32>()               // nodes along x, y, z; w = where its nodes start
}

/// An analytic shape particles bounce off (Particles.swift): MSL ParticleCollider.
package struct GPUParticleCollider {
    package var a = SIMD4<Float>()                   // plane: normal, w = offset (n.x = w on it); sphere: centre, w = radius;
                                             // box: centre
    package var b = SIMD4<Float>()                   // box: half extents; w = kind (ParticleCollider.code)
}

/// One step of the particles (ParticlesGPU.encodeSteps): MSL ParticleStep, set as bytes.
package struct GPUParticleStep {
    package var wind = SIMD4<Float>()                // the air's velocity (m/s); w = the curl noise's clock (s)
    package var time: Float = 0                      // the step's start (s)
    package var dt: Float = 0
    package var step: UInt32 = 0                     // from the start
    package var parity: UInt32 = 0                   // the alive list it reads (step & 1); bit 1: the scene is bound
    package var emitters: UInt32 = 0
    package var colliders: UInt32 = 0
    package var capacity: UInt32 = 0
    package var gravity: Float = 9.81
    // The pose's (ParticlesGPU.encodePose):
    package var casters: UInt32 = 0                  // the shadow casters' slots (the pool's first)
    package var casterBound: UInt32 = 0              // the casters' structure's boxes; the others' start there in the records
    package var othersBound: UInt32 = 0              // the others' structure's boxes
    package var pose: UInt32 = 0                     // which pair of the pose's counters it counts in (the other pair it clears)
}
