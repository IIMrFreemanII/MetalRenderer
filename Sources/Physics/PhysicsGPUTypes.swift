import Metal
import simd

// The physics' structs shared with the shaders (Shaders/Physics.metal and its pieces). Their memory layout MUST match
// the MSL structs of the same name exactly (validateGPULayouts, in the engine, checks every one).

/// A rigid body's state: MSL PhysicsBody. Rotations are quaternions, xyz then the real part in w. A body's space is
/// its principal axes about its centre of mass (its shape's `comPosition` / `comRotation` place it in shape space).
package struct GPUPhysicsBody {
    package var position = SIMD4<Float>()            // centre of mass, world; w = inverse mass (0: it never moves)
    package var rotation = SIMD4<Float>(0, 0, 0, 1)  // body -> world
    package var velocity = SIMD4<Float>()            // w = friction
    package var angular = SIMD4<Float>()             // angular velocity, world; w = restitution
    package var prevPosition = SIMD4<Float>()        // at the substep's start; w = how long it has been still (s)
    package var prevRotation = SIMD4<Float>(0, 0, 0, 1)
    package var invInertia = SIMD4<Float>()          // inverse principal moments; w = bounding radius about the centre of mass
    package var info = SIMD4<UInt32>()               // x = shape, y = flags (PhysicsWorld.asleep), z = the instance it moves,
                                             // w = the body a joint hangs it from + 1 (0: none): the two never collide
}

/// A collision shape: MSL PhysicsShape. `samples`: its surface points (and their count), in body space.
package struct GPUPhysicsShape {
    package var comPosition = SIMD4<Float>()         // the body's origin in shape space; w = bounding radius about it
    package var comRotation = SIMD4<Float>(0, 0, 0, 1)   // body space -> shape space
    package var params = SIMD4<Float>()              // sphere: (r); capsule: (half length, r) along y; box: (half extents, rounding)
    package var info = SIMD4<UInt32>()               // x = kind (PhysicsShapeKind), y = first sample, z = samples, w = SDF shape
}

/// One entry of a body's list of what it may touch this step: MSL PhysicsPair.
package struct GPUPhysicsPair {
    package var partner: UInt32 = 0                  // a body, or a static collider | PhysicsWorld.staticBit
    package var contacts: UInt32 = 0                 // in the owner's manifold
    package var link: UInt32 = 0                     // the owner's entry for the pair (the owner's own: itself); none: ~0
    package var pad: UInt32 = 0                      // its colour this step (PhysicsCPU.colourPairs); none, or the leftover mark
}

/// A contact point, from body B to body A: MSL PhysicsContact. A's point is A's anchor less `normal` x A's radius,
/// B's is B's anchor plus `normal` x B's radius (a sphere's anchor is its centre: it stays under it as it rolls).
package struct GPUPhysicsContact {
    package var normal = SIMD4<Float>()              // world, out of B; w = the separation it was found at
    package var anchorA = SIMD4<Float>()             // A's space; w = A's radius
    package var anchorB = SIMD4<Float>()             // B's space; w = B's radius
    package var lambda = SIMD4<Float>()              // x = this substep's normal lambda, y = normal speed before it, zw = 0
}

/// A body held by the mouse (PhysicsWorld.grab): its point `anchor` pulled towards `target`. MSL PhysicsGrab.
package struct GPUPhysicsGrab {
    package var target = SIMD4<Float>()              // world; w = 1 while held, 0 when nothing is
    package var anchor = SIMD4<Float>()              // the body's space (its centre of mass's); w = 0
    package var body: UInt32 = 0
    package var pad0: UInt32 = 0
    package var pad1: UInt32 = 0
    package var pad2: UInt32 = 0

    /// (As the memberwise initializer, for the modules above this one.)
    package init(target: SIMD4<Float> = SIMD4<Float>(), anchor: SIMD4<Float> = SIMD4<Float>(), body: UInt32 = 0, pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0) {
        self.target = target
        self.anchor = anchor
        self.body = body
        self.pad0 = pad0
        self.pad1 = pad1
        self.pad2 = pad2
    }
}

/// A joint between two bodies (a ragdoll's): their anchors meet, and they turn about each other within limits. Its
/// axis and reference (a direction across it) are in each body's space, the same in the world when it was made: then
/// its angles are 0. A ball joint keeps the axes within a cone (`swing`) and their twist about them within
/// [lo, hi]; a hinge keeps the axes together and the turn about them within [lo, hi]. MSL PhysicsJoint.
package struct GPUPhysicsJoint {
    package var anchorA = SIMD4<Float>()             // A's space; w = 0
    package var anchorB = SIMD4<Float>()             // B's space; w = 0
    package var axisA = SIMD4<Float>()               // A's space; w = lo (rad)
    package var axisB = SIMD4<Float>()               // B's space; w = hi (rad)
    package var referenceA = SIMD4<Float>()          // A's space, across the axis; w = swing (rad, a ball joint's)
    package var referenceB = SIMD4<Float>()          // B's space; w = damping (1/s): how fast the two's relative turning fades
    package var info = SIMD4<UInt32>()               // x = A, y = B, z = kind (PhysicsJointKind), w = 0
}

/// A fractured object's node as the body it is (FractureTree.Node, Physics+Fracture.swift): MSL PhysicsFractureNode.
/// Every node of a fractured object is a body from the start, its children's bodies one after another; all but the
/// root are disabled (PhysicsWorld.disabledBit) until their parent breaks.
package struct GPUFractureNode {
    package var info = SIMD4<UInt32>(~0, 0, 0, 0)   // x = its parent's body (none: a root), y = its first child's body, z = how
                                             // many children, w = flags (PhysicsWorld.anchoredNode ...)
    package var offset = SIMD4<Float>()              // its centre of mass in its parent's body space at rest; w = the impact (N s)
                                             // that breaks it into its children (0: it has none)
    package var rotation = SIMD4<Float>(0, 0, 0, 1)  // its body's rotation in its parent's (q = q_parent q_rel)
    package var extra = SIMD4<Float>()               // x = its inverse mass once free (an anchored piece has 0 until then),
                                             // y = the impact (N s) that frees it (its welds broken, its anchor let go),
                                             // z = its bounding radius if it fades away at rest (a small leaf), else 0,
                                             // w = its material (FractureMaterial)
}

/// A weld between two pieces that share a face (FractureTree.Weld): their anchors held together and their turn
/// about each other kept, until the force it takes passes its strength. Solved as its pair's contact (the narrow
/// phase marks a welded pair's one contact: Physics+Fracture.swift). MSL PhysicsFractureWeld.
package struct GPUFractureWeld {
    package var anchorA = SIMD4<Float>()             // A's body space; w = the force it holds (N)
    package var anchorB = SIMD4<Float>()             // B's body space; w = its lever (m), the shared face's radius: the moment it
                                             // holds is the force x this
    package var rest = SIMD4<Float>(0, 0, 0, 1)      // B's rotation in A's at rest (q_b = q_a rest)
    package var info = SIMD4<UInt32>()               // x = A, y = B, z = 0 holding, 1 broken, 2 loose (the CPU's only:
                                             // PhysicsWorld.loose), w = its load lately (a float's bits: PhysicsWorld.weld)
    package var loose = SIMD4<Float>()               // once loose: x = its fatigue (load s), y = how long it has left (s),
                                                     // z = why it let go (PhysicsWorld.looseLink); w = half
                                                     // the shared face's width (m: its hinge, from the start)
}

/// A fractured body's step: what hit it, and what the step's end makes of it. MSL PhysicsFractureState.
package struct GPUFractureState {
    package var strain = SIMD4<Float>()              // x = this step's impacts (N s), y = how long it has lain still (s), z = what
                                             // it took over from its parent's break (N s), w = the step's verdict
                                             // (0: nothing, 1: it breaks, 2: it comes free)
    package var impact = SIMD4<Float>()              // xyz = where the impacts were, times their impulse; w = their impulse
    package var direction = SIMD4<Float>(0, 0, 0, 1) // xyz = which way they pushed it, times their impulse; w = its drawn scale
                                             // (1; less as it fades away)
    package var hold = SIMD4<Float>()                // x = how much longer (s) it is held where it is after its parent broke,
                                             // y = how much longer it is shaken by its last impact (the CPU's loose joints)
}

/// Something done to the fractured bodies at a step (a shot, a blast, a release): kept for replays. MSL
/// PhysicsFractureCommand.
package struct GPUFractureCommand {
    package var info = SIMD4<UInt32>()               // x = its first step, y = kind (PhysicsWorld.FractureCommand), z = its body
                                             // (a shot's ball, a body woken), w = how many steps it lasts
    package var origin = SIMD4<Float>()              // world; w = a blast's radius
    package var direction = SIMD4<Float>()           // a shot's way (unit); w = its speed (m/s), or a blast's speed at its middle

    /// (As the memberwise initializer, for the modules above this one.)
    package init(info: SIMD4<UInt32> = SIMD4<UInt32>(), origin: SIMD4<Float> = SIMD4<Float>(), direction: SIMD4<Float> = SIMD4<Float>()) {
        self.info = info
        self.origin = origin
        self.direction = direction
    }
}

/// Where a piece broke, for the dust (PhysicsGPU.breakRing): MSL PhysicsBreakEvent.
package struct GPUBreakEvent {
    package var position = SIMD4<Float>()            // its centre of mass; w = its radius
    package var velocity = SIMD4<Float>()            // w = its material (FractureMaterial)
}

/// What the fracture kernels are told: MSL PhysicsFractureParams.
package struct GPUFractureParams {
    package var counts = SIMD4<UInt32>()             // x = bodies, y = welds, z = commands, w = 0
    package var tuning = SIMD4<Float>()              // x = how long a small piece lies still before it fades (s), y = how long it
                                             // fades (s), z = how far a break's damage reaches per unit of its excess
                                             // (m), w = how much of it pushes the freed pieces
}

/// A guide strand of hair (PhysicsHair.swift): a chain of vertices from a root held by a body (or the world). MSL
/// PhysicsStrand.
package struct GPUHairStrand {
    package var info = SIMD4<UInt32>()               // x = its body (PhysicsWorld.none: the world's), y = first vertex, z = vertices,
                                             // w = 1 while it lies still on a sleeping body
    package var stiffness = SIMD4<Float>()           // x = global shape at the root, y = at the tip, z = local shape (each a substep's
                                             // share of the way back to its rest), w = DFTL's damping (0...1)
    package var across = SIMD4<Float>()              // its body's space: a direction across it at the root (the drawn strands'
                                             // frame); w = its length
    package var pad = SIMD4<Float>()
}

/// A guide strand's vertex. MSL PhysicsHairVertex.
package struct GPUHairVertex {
    package var position = SIMD4<Float>()            // w = collision radius
    package var previous = SIMD4<Float>()            // at the substep's start; w = the rest length of the segment before it
    package var velocity = SIMD4<Float>()            // w = friction
    package var rest = SIMD4<Float>()                // in its root's body's space (the world's for a static root); w = global stiffness
}

/// What the hair kernel is told (per step; MSL PhysicsHairParams).
package struct GPUHairParams {
    package var gravity = SIMD4<Float>()             // w = substep length (s)
    package var wind = SIMD4<Float>()                // xyz = the breeze's velocity (m/s), w = gustiness (0...1)
    package var counts = SIMD4<UInt32>()             // x = strands, y = bodies, z = statics, w = substeps
    package var air = SIMD4<Float>()                 // x = drag (1/s), y = rest speed (m/s), z = the step's time (s), w = 0
}

/// A group of drawn strands around their guides (PhysicsWorld.HairGroup): MSL PhysicsHairGroup.
package struct GPUHairGroup {
    package var counts = SIMD4<UInt32>()             // x = first guide, y = guides, z = drawn per guide, w = a guide's vertices
    package var mesh = SIMD4<UInt32>()               // x = its curve mesh's first control point, y = last frame's offset, z = seed
    package var shape = SIMD4<Float>()               // x = spread (m: how far from its guide a drawn strand's root may be),
                                             // y = clumping (0...1: how far toward the guide at the tip), z = curl (m), w = 0
    package var pad = SIMD4<Float>()
}

/// A particle (Physics.swift): a small ball that the bodies and the static colliders push about, and that piles up
/// against the others. MSL PhysicsParticle.
package struct GPUPhysicsParticle {
    package var position = SIMD4<Float>()            // w = radius
    package var velocity = SIMD4<Float>()            // w = friction
    package var prevPosition = SIMD4<Float>()        // at the substep's start; w = inverse mass
    package var info = SIMD4<UInt32>()               // x = its instance (none: a cloth's or a soft body's vertex), y = flags
                                             // (PhysicsWorld.clothBit, softBit), z = a cloth vertex's place in the scene's
                                             // vertex buffer, w = its cloth or soft body
}

/// A cloth's distance constraint between two of its vertices (particles): MSL PhysicsConstraint.
package struct GPUPhysicsConstraint {
    package var a: UInt32
    package var b: UInt32
    package var rest: Float
    package var compliance: Float                    // m/N: 0 holds it rigid
}

/// What every physics kernel is told: MSL PhysicsParams.
package struct GPUPhysicsParams {
    package var gravity = SIMD4<Float>()             // w = the substep's length (s)
    package var counts = SIMD4<UInt32>()             // x = bodies, y = static colliders, z = pairs a body may have, w = hash buckets
    package var grid = SIMD4<Float>()                // x = cell size, y = contact margin, z = top speed, w = the step's length
    package var sleep = SIMD4<Float>()               // x = still below this speed, y = ...and its turning moving its mass
                                             // slower than this (m/s, PhysicsWorld.sleepTurn), z = asleep after (s),
                                             // w = the speed a body's sphere reaches by (PhysicsWorld.cellSpeed)
    package var particles = SIMD4<UInt32>()          // x = particles, y = their hash buckets, z = neighbours each, w = colliders each
    package var particleGrid = SIMD4<Float>()        // x = their cell size, y = the speed a particle's reach allows for,
                                             // z = a cloth's air drag (1/s), w = a particle at rest goes slower (m/s)
    package var cloth = SIMD4<UInt32>()              // x = constraints, y = their colours, z = the joints' colours, w = ragdolls
    package var rolling = SIMD4<Float>()             // x = rolling resistance (m), y = spinning resistance (m), z = a body moving
                                             // faster than this wakes what it touches, w = ...or turning its mass faster
                                             // than this (m/s, PhysicsWorld.wakeTurn)
    package var soft = SIMD4<UInt32>()               // soft bodies (PhysicsSoft.swift): x = tets, y = their colours, z = drawn
                                             // vertices, w = soft bodies
    package var softDamping = SIMD4<Float>()         // x = their air drag (1/s), y = their links' damping (s), z = substeps a
                                             // step (a kinematic body's share of the step a substep), w = 0
}

/// A soft body's tetrahedron (PhysicsSoft.swift): its four particles and its rest volume, which an XPBD constraint
/// keeps. MSL PhysicsTet.
package struct GPUPhysicsTet {
    package var ids = SIMD4<UInt32>()                // its particles, wound so that its volume is positive
    package var rest: Float = 0                      // six times its volume at rest (m^3)
    package var compliance: Float = 0                // m^3/N: 0 keeps its volume
    package var damping: Float = 0                   // s (XPBD's beta)
    package var fibre: UInt32 = 0                    // a muscle's tet: its fibre (PhysicsWorld.fibres) + 1; 0: none
}

/// A soft body's drawn vertex (PhysicsSoft.swift): MSL PhysicsSoftVertex.
package struct GPUSoftVertex {
    package var info = SIMD4<UInt32>()               // x = its place in the scene's vertex buffer, y = its mesh's last-frame offset
                                             // (GPUMesh.prevOffset), z = its soft body, w = its ring of triangles: where it
                                             // starts in PhysicsWorld.softRings << 5 | how many
    package var embeds = SIMD4<UInt32>()             // x = its first place in its tets (PhysicsWorld.softEmbeds), y = how many; a
                                             // car's: z = PhysicsWorld.carVertexBit | its pane | lampBit, w = its car's first node
}

/// Where a soft body's drawn vertex is in one of the tets it follows (PhysicsSoft.swift): MSL PhysicsSoftEmbed. Or,
/// with `ids.w` = `bodyKind` or `triangleKind` (PhysicsFlesh.swift), on a body (`ids.x`; `bary.xyz` in its space) or on
/// a skin's triangle (`ids.xyz` its particles; `bary.xy` the weights of the last two, `bary.z` how far out along its
/// normal).
package struct GPUSoftEmbed {
    package var bary = SIMD4<Float>()                // its weights for the tet's last three particles (the first's is 1 - their
                                             // sum); w = this tet's share of where it goes
    package var ids = SIMD4<UInt32>()                // the tet's particles
    package static let bodyKind: UInt32 = 0x8000_0001
    package static let triangleKind: UInt32 = 0x8000_0002
}

/// The flesh's part of the physics (PhysicsFlesh.swift), packed in one buffer after this header: MSL PhysicsFleshHeader.
package struct GPUFleshHeader {
    package var counts = SIMD4<UInt32>()             // x = kinematic bodies (the pose table's columns), y = its rows (steps), z =
                                             // muscles, w = pins
    package var more = SIMD4<UInt32>()               // x = fibres, y = skin attachments, z = the clock: steps run (the GPU's), w = 0
    package var at = SIMD4<UInt32>()                 // where each part starts (16-byte words): x = the pose table, y = the
                                             // muscles, z = their activations, w = the fibres
    package var at2 = SIMD4<UInt32>()                // x = the pins, y = the skin's attachments
}

/// A flesh particle held to its bones (PhysicsFlesh.swift): MSL PhysicsFleshPin. Its target is where two bodies put a
/// point (each in its own space), blended by their weights.
package struct GPUFleshPin {
    package var restA = SIMD4<Float>()               // in body A's space; w = A's weight
    package var restB = SIMD4<Float>()               // in body B's space; w = B's weight
    package var particle: UInt32 = 0
    package var bodyA: UInt32 = 0
    package var bodyB: UInt32 = 0
    package var compliance: Float = 0                // m/N (a particle of no mass sits on its target)
}

/// A muscle's activation from the angle between two bones' axes (PhysicsFlesh.swift): MSL PhysicsMuscle.
package struct GPUMuscle {
    package var axisA = SIMD4<Float>()               // body A's axis, in its space
    package var axisB = SIMD4<Float>()               // body B's, in its space
    package var range = SIMD4<Float>()               // x = the angle it starts at, y = the one it is full at, z = how full (0...1)
    package var bodyA: UInt32 = 0
    package var bodyB: UInt32 = 0
    package var pad0: UInt32 = 0
    package var pad1: UInt32 = 0
}

/// A muscle's tet's fibre (PhysicsFlesh.swift): MSL PhysicsFleshFibre. Its direction at rest through the tet's rest
/// edges' inverse (Dm^-1 f), so that the edges now times it is the fibre now.
package struct GPUFleshFibre {
    package var g = SIMD4<Float>()                   // w = how far it shortens at full activation (a share of its length)
    package var muscle: UInt32 = 0
    package var compliance: Float = 0
    package var pad0: UInt32 = 0
    package var pad1: UInt32 = 0
}

/// A skin particle's hold on the flesh beneath it (PhysicsSkin.swift): MSL PhysicsSkinAttach.
package struct GPUSkinAttach {
    package var bary = SIMD4<Float>()                // where it rests in the tet (the last three particles' weights); w = how far
                                             // it may slide (m)
    package var deep = SIMD4<Float>()                // a point under it, in the same tet (its normal: from there); w = the slide's
                                             // compliance
    package var ids = SIMD4<UInt32>()                // the tet's particles
    package var particle: UInt32 = 0
    package var compliance: Float = 0                // along the normal
    package var pad0: UInt32 = 0
    package var pad1: UInt32 = 0
}

/// A liquid's particle (PhysicsFluid.swift): MSL FluidParticle.
package struct GPUFluidParticle {
    package var position = SIMD4<Float>()            // w = MPM: its volume now over its volume at rest (J)
    package var velocity = SIMD4<Float>()            // w = 0
    package var affine0 = SIMD4<Float>()             // MPM: its velocity's gradient (APIC's C), by rows; PBF: row 0 is its
    package var affine1 = SIMD4<Float>()             // vorticity
    package var affine2 = SIMD4<Float>()
}

/// What a liquid's kernels are told (PhysicsFluid.swift): MSL FluidParams. Written once.
package struct GPUFluidParams {
    package var gravity = SIMD4<Float>()             // w = the solver's substep (s)
    package var lo = SIMD4<Float>()                  // the domain's low corner; w = the grid's cell (PBF: the kernel's radius h;
                                             // MPM: dx)
    package var hi = SIMD4<Float>()                  // its high corner; w = 1 / the cell
    package var dims = SIMD4<UInt32>()               // the grid's cells (PBF) or nodes (MPM) along x, y, z; w = all of them
    package var counts = SIMD4<UInt32>()             // x = capacity (particles), y = substeps a group, z = static colliders it
                                             // meets, w = solver (0 PBF, 1 MPM)
    package var material = SIMD4<Float>()            // x = rest density (PBF: sum of W over a rest lattice, 1/m^3; MPM: kg/m^3),
                                             // y = a particle's mass (kg), z = bulk modulus K (Pa), w = Tait's gamma
    package var viscosity = SIMD4<Float>()           // Carreau: x = mu0, y = mu infinity (Pa s), z = lambda (s), w = n
    package var pbf = SIMD4<Float>()                 // x = h, y = relaxation (CFM), z = s_corr k, w = 1 / W(dq)
    package var pbf2 = SIMD4<Float>()                // x = XSPH c, y = vorticity confinement, z = wall friction, w = stickiness
    package var fixed = SIMD4<Float>()               // fixed point: x = mass, y = momentum, z = a body's impulse (per N s);
                                             // w = the top speed (m/s)
    package var nozzle = SIMD4<Float>()              // where it pours from; w = the nozzle's radius
    package var direction = SIMD4<Float>()           // which way (unit); w = how fast (m/s)
    package var emission = SIMD4<UInt32>()           // x = particles a layer, y = ticks between layers x 256, z = the tick it
                                             // starts at, w = PBF iterations
    package var extra = SIMD4<Float>()               // x = a particle's radius against colliders, y = the spacing it pours at,
                                             // z = particle volume (m^3, MPM), w = the group's length (s)
}

/// A liquid's drawn surface (FluidSurface.swift): MSL FluidSurface. Written once the scene's meshes are in.
package struct GPUFluidSurface {
    package var lo = SIMD4<Float>()                  // the grid's first node; w = its cell (m)
    package var dims = SIMD4<UInt32>()               // nodes along x, y, z; w = all of them
    package var field = SIMD4<Float>()               // x = the iso level (particles a cell), y = the splat's fixed point, z = 1 / cell
    package var mesh = SIMD4<UInt32>()               // x = its first vertex in the scene's vertex buffer, y = its first index,
                                             // z = its last-frame offset (GPUMesh.prevOffset), w = vertices it holds
    package var triangles = SIMD4<UInt32>()          // x = triangles it holds
}
