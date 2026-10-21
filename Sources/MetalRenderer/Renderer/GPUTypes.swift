import EngineCore
import Metal
import simd

// Structs shared with the shaders (Shaders/Types.metal unless a comment names another piece).
// Their memory layout MUST match the MSL structs of the same name exactly,
// so every struct is built from 16-byte vectors/matrices plus groups of four 32-bit scalars.

/// The reference path tracer's parameters (MSL PathTraceParams in Shaders/PathTrace.metal), passed with setBytes.
struct GPUPathTraceParams {
    var samples = SIMD4<UInt32>()   // x = paths in the mean so far, y = paths to add, z = bounces, w = light-tree nodes
    var config = SIMD4<UInt32>()    // x = flags (below), y = instances the light-proxy map covers, z = the average's seed
    var bounds = SIMD4<Float>()     // the scene's sphere (Scene.sceneSphere): the fog is inside it (the sun's and the sky's
                                    // light is what reaches the scene)

    static let sobol: UInt32 = 1    // Owen-scrambled Sobol samples (else white noise)
    static let fog: UInt32 = 2      // the fog's medium (FogParams at buffer 9, its noise at texture 1)
}

/// The lens and the finish (MSL PostParams), passed with setBytes to the kernels of Shaders/Post.metal.
struct GPUPostParams {
    var bloom = SIMD4<Float>()     // x = strength (0 = none), y = threshold, z = exposure (linear scale), w = levels
    var lens = SIMD4<Float>()      // x = aperture (output pixels), y = focus distance (m, 0 = auto), z = largest blur
                                   // radius (output pixels), w = autofocus easing per frame
    var finish = SIMD4<Float>()    // x = vignette, y = grain, z = chromatic aberration
    var size = SIMD4<UInt32>()     // xy = output size, zw = traced size
    var frame = SIMD4<UInt32>()    // x = frame index, y = bloom level being made
}

/// The light grid's parameters (MSL RegirParams): per level its jittered origin (xyz) and cell size (w).
package struct GPURegirParams {
    var origin0 = SIMD4<Float>(), origin1 = SIMD4<Float>(), origin2 = SIMD4<Float>(), origin3 = SIMD4<Float>()
    var config = SIMD4<UInt32>()   // x = cells per axis, y = levels, z = slots per cell, w = candidates per slot
    var consume = SIMD4<UInt32>()  // x = grid candidates per pixel (0 = off), y = frame seed
}

/// One reservoir of the light grid (MSL RegirReservoir), for its byte count.
struct GPURegirReservoir {
    var element: UInt32 = 0, uv: UInt32 = 0
    var W: Float = 0, target: Float = 0
}

/// The sky (MSL SkyParams): the per-slot copy lives in the shading arguments (SceneShading), the sky kernels get it directly.
package struct GPUSkyParams {
    var sun = SIMD4<Float>()          // xyz = toward the sun (unit), w = its angular radius. (The open world's night: the moon.)
    var sunTop = SIMD4<Float>()       // rgb = sun irradiance above the atmosphere (atmosphere mode)
    var sunGround = SIMD4<Float>()    // rgb = sun irradiance at the ground (the sun light's colour)
    var glow = SIMD4<Float>()         // xyz = toward what else lights the atmosphere: the sun under the horizon, once the
    var glowTop = SIMD4<Float>()      // moon is the light; rgb = its irradiance above the atmosphere (0 = nothing else)
                                      // glow.w = how bright the stars are (0 = none: by day)
    var cloudLayer = SIMD4<Float>()   // x = cloud base altitude (m), y = top (m), z = coverage (0...1), w = extinction (1/m)
    var cloudShape = SIMD4<Float>()   // x = shape noise tile (m), y = detail erosion, z = time (s), w = shadow strength
    var wind = SIMD4<Float>()         // xyz = wind (m/s), w = weight of a new cloud sample in a texel (1 = replace)
    var shadowMap = SIMD4<Float>()    // xy = centre (x, z) of the cloud-shadow square, z = its half size (m), w = ground height
    var ground = SIMD4<Float>()       // rgb = ground albedo below the horizon, w = the sky's observer altitude (m)
    var flags = SIMD4<UInt32>()       // x = mode (GPUSkyParams.atmosphere / .image), y = feature bits, z = update phase 0...15,
                                      // w = frame (jitters the cloud march)
    var place = SIMD4<Float>()        // xy = where the scene's origin is in the world (x, z), zw = the sky's observer in
                                      // the scene (x, z): the clouds are the world's

    static let atmosphere: UInt32 = 1, image: UInt32 = 2
    static let clouds: UInt32 = 1, shadows: UInt32 = 2, updateAll: UInt32 = 4, cloudsOverImage: UInt32 = 8
}

/// A skinned vertex's joints and weights (MSL SkinVertex, Shaders/Crowd.metal).
package struct GPUSkinVertex: Equatable {
    package var joints: UInt32 = 0     // four joint indices, a byte each (the first in the low byte)
    var w0: Float = 1          // the first three joints' weights; the fourth's is what is left of 1
    var w1: Float = 0
    var w2: Float = 0
}

/// A skeleton's joint (MSL CrowdJoint): where it sits in its parent, and its inverse bind transform (a rotation,
/// then a translation), which takes a bind-pose vertex into the joint's space.
struct GPUJoint: Equatable {
    var local: SIMD4<Float>      // xyz = translation in the parent's space (m), w = the parent's index + 1 (bits; 0 = root)
    var inverseBindRotation: SIMD4<Float>      // quaternion, xyzw
    var inverseBindTranslation: SIMD4<Float>   // xyz

    var parent: Int { Int(local.w.bitPattern) - 1 }
}

/// A joint's skinning matrix in a pose (MSL JointMatrix): the three rows of bind space -> posed space.
struct GPUJointMatrix: Equatable {
    var row0 = SIMD4<Float>(1, 0, 0, 0), row1 = SIMD4<Float>(0, 1, 0, 0), row2 = SIMD4<Float>(0, 0, 1, 0)

    func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = SIMD4(p, 1)
        return SIMD3(dot(row0, v), dot(row1, v), dot(row2, v))
    }
    func direction(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let v = SIMD4(d, 0)
        return SIMD3(dot(row0, v), dot(row1, v), dot(row2, v))
    }
}

/// A pose of the crowd at one time (MSL PoseSlot): two clips of its character, each at a time in keys, and how far
/// the pose is from the first toward the second. A clip is named by where its keys start in the crowd's key tables.
struct GPUPoseSlot: Equatable {
    var rotationsA: UInt32 = 0   // clip A's first rotation key (a quaternion per joint and key)
    var rootA: UInt32 = 0        // its first root-translation key
    var rotationsB: UInt32 = 0
    var rootB: UInt32 = 0
    var timeA: Float = 0         // in keys, inside the loop
    var timeB: Float = 0
    var blend: Float = 0         // 0 = clip A alone
    var pad: Float = 0
}

package struct GPUInstanceData {
    var transform: simd_float4x4       // object -> world, this frame
    var prevTransform: simd_float4x4   // object -> world, previous frame (motion vectors)
    var normalMatrix: simd_float4x4    // inverse-transpose of transform
    var meshIndex: UInt32
    var materialIndex: UInt32
    var pad0: UInt32 = 0               // instance mask (Scene.maskGeometry / maskLights), read by the cut
    var pad1: UInt32 = 0
}

/// One light; see the MSL struct for what each field holds per type (Scene.LightKind).
package struct GPULight {
    var positionRadius: SIMD4<Float>  // xyz = centre, w = radius (sphere, spot, tube, mesh bounds), angular radius (sun)
    var color: SIMD4<Float>           // rgb = intensity / irradiance (sun) / radiance (rect) / sum of L x area (mesh),
                                      // w = shadow-denoiser group (0...3) + 4 x type (GPULight.sphere...)
    var axis: SIMD4<Float>            // xyz = spot axis, rect normal, toward the sun, tube half axis, mesh mean normal;
                                      // w = mesh: its material, from its instance's first
    var params: SIMD4<Float>          // spot: cos outer, cos inner | rect: half-width tangent, half height
                                      // sun: light-map bounds centre, radius | mesh: first triangle, count, flatness,
                                      // instance (bit cast)

    static let sphere: Float = 0, spot: Float = 1, sun: Float = 2, rect: Float = 3, tube: Float = 4, mesh: Float = 5
}

// MARK: - Physics (Physics.swift, Shaders/Physics.metal)

/// A rigid body's state: MSL PhysicsBody. Rotations are quaternions, xyz then the real part in w. A body's space is
/// its principal axes about its centre of mass (its shape's `comPosition` / `comRotation` place it in shape space).
package struct GPUPhysicsBody {
    package var position = SIMD4<Float>()            // centre of mass, world; w = inverse mass (0: it never moves)
    package var rotation = SIMD4<Float>(0, 0, 0, 1)  // body -> world
    var velocity = SIMD4<Float>()            // w = friction
    var angular = SIMD4<Float>()             // angular velocity, world; w = restitution
    package var prevPosition = SIMD4<Float>()        // at the substep's start; w = how long it has been still (s)
    package var prevRotation = SIMD4<Float>(0, 0, 0, 1)
    package var invInertia = SIMD4<Float>()          // inverse principal moments; w = bounding radius about the centre of mass
    package var info = SIMD4<UInt32>()               // x = shape, y = flags (PhysicsWorld.asleep), z = the instance it moves,
                                             // w = the body a joint hangs it from + 1 (0: none): the two never collide
}

/// A collision shape: MSL PhysicsShape. `samples`: its surface points (and their count), in body space.
struct GPUPhysicsShape {
    var comPosition = SIMD4<Float>()         // the body's origin in shape space; w = bounding radius about it
    var comRotation = SIMD4<Float>(0, 0, 0, 1)   // body space -> shape space
    var params = SIMD4<Float>()              // sphere: (r); capsule: (half length, r) along y; box: (half extents, rounding)
    var info = SIMD4<UInt32>()               // x = kind (PhysicsShapeKind), y = first sample, z = samples, w = SDF shape
}

/// One entry of a body's list of what it may touch this step: MSL PhysicsPair.
struct GPUPhysicsPair {
    var partner: UInt32 = 0                  // a body, or a static collider | PhysicsWorld.staticBit
    var contacts: UInt32 = 0                 // in the owner's manifold
    var link: UInt32 = 0                     // the owner's entry for the pair (the owner's own: itself); none: ~0
    var pad: UInt32 = 0                      // its colour this step (PhysicsCPU.colourPairs); none, or the leftover mark
}

/// A contact point, from body B to body A: MSL PhysicsContact. A's point is A's anchor less `normal` x A's radius,
/// B's is B's anchor plus `normal` x B's radius (a sphere's anchor is its centre: it stays under it as it rolls).
struct GPUPhysicsContact {
    var normal = SIMD4<Float>()              // world, out of B; w = the separation it was found at
    var anchorA = SIMD4<Float>()             // A's space; w = A's radius
    var anchorB = SIMD4<Float>()             // B's space; w = B's radius
    var lambda = SIMD4<Float>()              // x = this substep's normal lambda, y = normal speed before it, zw = 0
}

/// A body held by the mouse (PhysicsWorld.grab): its point `anchor` pulled towards `target`. MSL PhysicsGrab.
package struct GPUPhysicsGrab {
    var target = SIMD4<Float>()              // world; w = 1 while held, 0 when nothing is
    var anchor = SIMD4<Float>()              // the body's space (its centre of mass's); w = 0
    var body: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

/// A joint between two bodies (a ragdoll's): their anchors meet, and they turn about each other within limits. Its
/// axis and reference (a direction across it) are in each body's space, the same in the world when it was made: then
/// its angles are 0. A ball joint keeps the axes within a cone (`swing`) and their twist about them within
/// [lo, hi]; a hinge keeps the axes together and the turn about them within [lo, hi]. MSL PhysicsJoint.
struct GPUPhysicsJoint {
    var anchorA = SIMD4<Float>()             // A's space; w = 0
    var anchorB = SIMD4<Float>()             // B's space; w = 0
    var axisA = SIMD4<Float>()               // A's space; w = lo (rad)
    var axisB = SIMD4<Float>()               // B's space; w = hi (rad)
    var referenceA = SIMD4<Float>()          // A's space, across the axis; w = swing (rad, a ball joint's)
    var referenceB = SIMD4<Float>()          // B's space; w = damping (1/s): how fast the two's relative turning fades
    var info = SIMD4<UInt32>()               // x = A, y = B, z = kind (PhysicsJointKind), w = 0
}

/// A fractured object's node as the body it is (FractureTree.Node, Physics+Fracture.swift): MSL PhysicsFractureNode.
/// Every node of a fractured object is a body from the start, its children's bodies one after another; all but the
/// root are disabled (PhysicsWorld.disabledBit) until their parent breaks.
package struct GPUFractureNode {
    package var info = SIMD4<UInt32>(~0, 0, 0, 0)   // x = its parent's body (none: a root), y = its first child's body, z = how
                                             // many children, w = flags (PhysicsWorld.anchoredNode ...)
    var offset = SIMD4<Float>()              // its centre of mass in its parent's body space at rest; w = the impact (N s)
                                             // that breaks it into its children (0: it has none)
    var rotation = SIMD4<Float>(0, 0, 0, 1)  // its body's rotation in its parent's (q = q_parent q_rel)
    var extra = SIMD4<Float>()               // x = its inverse mass once free (an anchored piece has 0 until then),
                                             // y = the impact (N s) that frees it (its welds broken, its anchor let go),
                                             // z = its bounding radius if it fades away at rest (a small leaf), else 0,
                                             // w = its material (FractureMaterial)
}

/// A weld between two pieces that share a face (FractureTree.Weld): their anchors held together and their turn
/// about each other kept, until the force it takes passes its strength. Solved as its pair's contact (the narrow
/// phase marks a welded pair's one contact: Physics+Fracture.swift). MSL PhysicsFractureWeld.
struct GPUFractureWeld {
    var anchorA = SIMD4<Float>()             // A's body space; w = the force it holds (N)
    var anchorB = SIMD4<Float>()             // B's body space; w = its lever (m), the shared face's radius: the moment it
                                             // holds is the force x this
    var rest = SIMD4<Float>(0, 0, 0, 1)      // B's rotation in A's at rest (q_b = q_a rest)
    var info = SIMD4<UInt32>()               // x = A, y = B, z = 1 once broken, w = its load lately (a float's bits:
                                             // PhysicsWorld.weld)
}

/// A fractured body's step: what hit it, and what the step's end makes of it. MSL PhysicsFractureState.
/// Solid shading's look (RenderSettings.solidLook): MSL SolidParams (Shaders/Output.metal).
package struct GPUSolidParams {
    var sun: SIMD4<Float>     // xyz: toward the sun when the scene has none; w: shadows (1 / 0)
    var look: SIMD4<Float>    // x: each object's tint, y: broken faces (1 / 0), z: AO's reach (m), w: AO rays (0: none)
    var edges: SIMD4<Float>   // x: outlines (1 / 0), y: their width (pixels), z: material colours (1 / 0)
    var info: SIMD4<UInt32>   // x: how many materials the flags buffer has
}

struct GPUFractureState {
    var strain = SIMD4<Float>()              // x = this step's impacts (N s), y = how long it has lain still (s), z = what
                                             // it took over from its parent's break (N s), w = the step's verdict
                                             // (0: nothing, 1: it breaks, 2: it comes free)
    var impact = SIMD4<Float>()              // xyz = where the impacts were, times their impulse; w = their impulse
    var direction = SIMD4<Float>(0, 0, 0, 1) // xyz = which way they pushed it, times their impulse; w = its drawn scale
                                             // (1; less as it fades away)
    var hold = SIMD4<Float>()                // x = how much longer (s) it is held where it is after its parent broke
}

/// Something done to the fractured bodies at a step (a shot, a blast, a release): kept for replays. MSL
/// PhysicsFractureCommand.
package struct GPUFractureCommand {
    var info = SIMD4<UInt32>()               // x = its first step, y = kind (PhysicsWorld.FractureCommand), z = its body
                                             // (a shot's ball, a body woken), w = how many steps it lasts
    var origin = SIMD4<Float>()              // world; w = a blast's radius
    var direction = SIMD4<Float>()           // a shot's way (unit); w = its speed (m/s), or a blast's speed at its middle

    /// (As the memberwise initializer, for the modules above this one.)
    package init(info: SIMD4<UInt32> = SIMD4<UInt32>(), origin: SIMD4<Float> = SIMD4<Float>(), direction: SIMD4<Float> = SIMD4<Float>()) {
        self.info = info
        self.origin = origin
        self.direction = direction
    }
}

/// Where a piece broke, for the dust (PhysicsGPU.breakRing): MSL PhysicsBreakEvent.
package struct GPUBreakEvent {
    var position = SIMD4<Float>()            // its centre of mass; w = its radius
    var velocity = SIMD4<Float>()            // w = its material (FractureMaterial)
}

/// What the fracture kernels are told: MSL PhysicsFractureParams.
struct GPUFractureParams {
    var counts = SIMD4<UInt32>()             // x = bodies, y = welds, z = commands, w = 0
    var tuning = SIMD4<Float>()              // x = how long a small piece lies still before it fades (s), y = how long it
                                             // fades (s), z = how far a break's damage reaches per unit of its excess
                                             // (m), w = how much of it pushes the freed pieces
}

/// A guide strand of hair (PhysicsHair.swift): a chain of vertices from a root held by a body (or the world). MSL
/// PhysicsStrand.
package struct GPUHairStrand {
    var info = SIMD4<UInt32>()               // x = its body (PhysicsWorld.none: the world's), y = first vertex, z = vertices,
                                             // w = 1 while it lies still on a sleeping body
    var stiffness = SIMD4<Float>()           // x = global shape at the root, y = at the tip, z = local shape (each a substep's
                                             // share of the way back to its rest), w = DFTL's damping (0...1)
    var across = SIMD4<Float>()              // its body's space: a direction across it at the root (the drawn strands'
                                             // frame); w = its length
    var pad = SIMD4<Float>()
}

/// A guide strand's vertex. MSL PhysicsHairVertex.
struct GPUHairVertex {
    var position = SIMD4<Float>()            // w = collision radius
    var previous = SIMD4<Float>()            // at the substep's start; w = the rest length of the segment before it
    var velocity = SIMD4<Float>()            // w = friction
    var rest = SIMD4<Float>()                // in its root's body's space (the world's for a static root); w = global stiffness
}

/// What the hair kernel is told (per step; MSL PhysicsHairParams).
struct GPUHairParams {
    var gravity = SIMD4<Float>()             // w = substep length (s)
    var wind = SIMD4<Float>()                // xyz = the breeze's velocity (m/s), w = gustiness (0...1)
    var counts = SIMD4<UInt32>()             // x = strands, y = bodies, z = statics, w = substeps
    var air = SIMD4<Float>()                 // x = drag (1/s), y = rest speed (m/s), z = the step's time (s), w = 0
}

/// A group of drawn strands around their guides (PhysicsWorld.HairGroup): MSL PhysicsHairGroup.
package struct GPUHairGroup {
    var counts = SIMD4<UInt32>()             // x = first guide, y = guides, z = drawn per guide, w = a guide's vertices
    var mesh = SIMD4<UInt32>()               // x = its curve mesh's first control point, y = last frame's offset, z = seed
    var shape = SIMD4<Float>()               // x = spread (m: how far from its guide a drawn strand's root may be),
                                             // y = clumping (0...1: how far toward the guide at the tip), z = curl (m), w = 0
    var pad = SIMD4<Float>()
}

/// A particle (Physics.swift): a small ball that the bodies and the static colliders push about, and that piles up
/// against the others. MSL PhysicsParticle.
package struct GPUPhysicsParticle {
    var position = SIMD4<Float>()            // w = radius
    var velocity = SIMD4<Float>()            // w = friction
    var prevPosition = SIMD4<Float>()        // at the substep's start; w = inverse mass
    var info = SIMD4<UInt32>()               // x = its instance (none: a cloth's or a soft body's vertex), y = flags
                                             // (PhysicsWorld.clothBit, softBit), z = a cloth vertex's place in the scene's
                                             // vertex buffer, w = its cloth or soft body
}

/// A cloth's distance constraint between two of its vertices (particles): MSL PhysicsConstraint.
struct GPUPhysicsConstraint {
    var a: UInt32
    var b: UInt32
    var rest: Float
    var compliance: Float                    // m/N: 0 holds it rigid
}

/// What every physics kernel is told: MSL PhysicsParams.
struct GPUPhysicsParams {
    var gravity = SIMD4<Float>()             // w = the substep's length (s)
    var counts = SIMD4<UInt32>()             // x = bodies, y = static colliders, z = pairs a body may have, w = hash buckets
    var grid = SIMD4<Float>()                // x = cell size, y = contact margin, z = top speed, w = the step's length
    var sleep = SIMD4<Float>()               // x = still below this speed, y = ...and its turning moving its mass
                                             // slower than this (m/s, PhysicsWorld.sleepTurn), z = asleep after (s),
                                             // w = the speed a body's sphere reaches by (PhysicsWorld.cellSpeed)
    var particles = SIMD4<UInt32>()          // x = particles, y = their hash buckets, z = neighbours each, w = colliders each
    var particleGrid = SIMD4<Float>()        // x = their cell size, y = the speed a particle's reach allows for,
                                             // z = a cloth's air drag (1/s), w = a particle at rest goes slower (m/s)
    var cloth = SIMD4<UInt32>()              // x = constraints, y = their colours, z = the joints' colours, w = ragdolls
    var rolling = SIMD4<Float>()             // x = rolling resistance (m), y = spinning resistance (m), z = a body moving
                                             // faster than this wakes what it touches, w = ...or turning its mass faster
                                             // than this (m/s, PhysicsWorld.wakeTurn)
    var soft = SIMD4<UInt32>()               // soft bodies (PhysicsSoft.swift): x = tets, y = their colours, z = drawn
                                             // vertices, w = soft bodies
    var softDamping = SIMD4<Float>()         // x = their air drag (1/s), y = their links' damping (s), z = substeps a
                                             // step (a kinematic body's share of the step a substep), w = 0
}

/// A soft body's tetrahedron (PhysicsSoft.swift): its four particles and its rest volume, which an XPBD constraint
/// keeps. MSL PhysicsTet.
struct GPUPhysicsTet {
    var ids = SIMD4<UInt32>()                // its particles, wound so that its volume is positive
    var rest: Float = 0                      // six times its volume at rest (m^3)
    var compliance: Float = 0                // m^3/N: 0 keeps its volume
    var damping: Float = 0                   // s (XPBD's beta)
    var fibre: UInt32 = 0                    // a muscle's tet: its fibre (PhysicsWorld.fibres) + 1; 0: none
}

/// A soft body's drawn vertex (PhysicsSoft.swift): MSL PhysicsSoftVertex.
struct GPUSoftVertex {
    var info = SIMD4<UInt32>()               // x = its place in the scene's vertex buffer, y = its mesh's last-frame offset
                                             // (GPUMesh.prevOffset), z = its soft body, w = its ring of triangles: where it
                                             // starts in PhysicsWorld.softRings << 5 | how many
    var embeds = SIMD4<UInt32>()             // x = its first place in its tets (PhysicsWorld.softEmbeds), y = how many
}

/// Where a soft body's drawn vertex is in one of the tets it follows (PhysicsSoft.swift): MSL PhysicsSoftEmbed. Or,
/// with `ids.w` = `bodyKind` or `triangleKind` (PhysicsFlesh.swift), on a body (`ids.x`; `bary.xyz` in its space) or on
/// a skin's triangle (`ids.xyz` its particles; `bary.xy` the weights of the last two, `bary.z` how far out along its
/// normal).
struct GPUSoftEmbed {
    var bary = SIMD4<Float>()                // its weights for the tet's last three particles (the first's is 1 - their
                                             // sum); w = this tet's share of where it goes
    var ids = SIMD4<UInt32>()                // the tet's particles
    static let bodyKind: UInt32 = 0x8000_0001
    static let triangleKind: UInt32 = 0x8000_0002
}

/// The flesh's part of the physics (PhysicsFlesh.swift), packed in one buffer after this header: MSL PhysicsFleshHeader.
struct GPUFleshHeader {
    var counts = SIMD4<UInt32>()             // x = kinematic bodies (the pose table's columns), y = its rows (steps), z =
                                             // muscles, w = pins
    var more = SIMD4<UInt32>()               // x = fibres, y = skin attachments, z = the clock: steps run (the GPU's), w = 0
    var at = SIMD4<UInt32>()                 // where each part starts (16-byte words): x = the pose table, y = the
                                             // muscles, z = their activations, w = the fibres
    var at2 = SIMD4<UInt32>()                // x = the pins, y = the skin's attachments
}

/// A flesh particle held to its bones (PhysicsFlesh.swift): MSL PhysicsFleshPin. Its target is where two bodies put a
/// point (each in its own space), blended by their weights.
struct GPUFleshPin {
    var restA = SIMD4<Float>()               // in body A's space; w = A's weight
    var restB = SIMD4<Float>()               // in body B's space; w = B's weight
    var particle: UInt32 = 0
    var bodyA: UInt32 = 0
    var bodyB: UInt32 = 0
    var compliance: Float = 0                // m/N (a particle of no mass sits on its target)
}

/// A muscle's activation from the angle between two bones' axes (PhysicsFlesh.swift): MSL PhysicsMuscle.
struct GPUMuscle {
    var axisA = SIMD4<Float>()               // body A's axis, in its space
    var axisB = SIMD4<Float>()               // body B's, in its space
    var range = SIMD4<Float>()               // x = the angle it starts at, y = the one it is full at, z = how full (0...1)
    var bodyA: UInt32 = 0
    var bodyB: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

/// A muscle's tet's fibre (PhysicsFlesh.swift): MSL PhysicsFleshFibre. Its direction at rest through the tet's rest
/// edges' inverse (Dm^-1 f), so that the edges now times it is the fibre now.
struct GPUFleshFibre {
    var g = SIMD4<Float>()                   // w = how far it shortens at full activation (a share of its length)
    var muscle: UInt32 = 0
    var compliance: Float = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

/// A skin particle's hold on the flesh beneath it (PhysicsSkin.swift): MSL PhysicsSkinAttach.
struct GPUSkinAttach {
    var bary = SIMD4<Float>()                // where it rests in the tet (the last three particles' weights); w = how far
                                             // it may slide (m)
    var deep = SIMD4<Float>()                // a point under it, in the same tet (its normal: from there); w = the slide's
                                             // compliance
    var ids = SIMD4<UInt32>()                // the tet's particles
    var particle: UInt32 = 0
    var compliance: Float = 0                // along the normal
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

/// A liquid's particle (PhysicsFluid.swift): MSL FluidParticle.
struct GPUFluidParticle {
    var position = SIMD4<Float>()            // w = MPM: its volume now over its volume at rest (J)
    var velocity = SIMD4<Float>()            // w = 0
    var affine0 = SIMD4<Float>()             // MPM: its velocity's gradient (APIC's C), by rows; PBF: row 0 is its
    var affine1 = SIMD4<Float>()             // vorticity
    var affine2 = SIMD4<Float>()
}

/// What a liquid's kernels are told (PhysicsFluid.swift): MSL FluidParams. Written once.
struct GPUFluidParams {
    var gravity = SIMD4<Float>()             // w = the solver's substep (s)
    var lo = SIMD4<Float>()                  // the domain's low corner; w = the grid's cell (PBF: the kernel's radius h;
                                             // MPM: dx)
    var hi = SIMD4<Float>()                  // its high corner; w = 1 / the cell
    var dims = SIMD4<UInt32>()               // the grid's cells (PBF) or nodes (MPM) along x, y, z; w = all of them
    var counts = SIMD4<UInt32>()             // x = capacity (particles), y = substeps a group, z = static colliders it
                                             // meets, w = solver (0 PBF, 1 MPM)
    var material = SIMD4<Float>()            // x = rest density (PBF: sum of W over a rest lattice, 1/m^3; MPM: kg/m^3),
                                             // y = a particle's mass (kg), z = bulk modulus K (Pa), w = Tait's gamma
    var viscosity = SIMD4<Float>()           // Carreau: x = mu0, y = mu infinity (Pa s), z = lambda (s), w = n
    var pbf = SIMD4<Float>()                 // x = h, y = relaxation (CFM), z = s_corr k, w = 1 / W(dq)
    var pbf2 = SIMD4<Float>()                // x = XSPH c, y = vorticity confinement, z = wall friction, w = stickiness
    var fixed = SIMD4<Float>()               // fixed point: x = mass, y = momentum, z = a body's impulse (per N s);
                                             // w = the top speed (m/s)
    var nozzle = SIMD4<Float>()              // where it pours from; w = the nozzle's radius
    var direction = SIMD4<Float>()           // which way (unit); w = how fast (m/s)
    var emission = SIMD4<UInt32>()           // x = particles a layer, y = ticks between layers x 256, z = the tick it
                                             // starts at, w = PBF iterations
    var extra = SIMD4<Float>()               // x = a particle's radius against colliders, y = the spacing it pours at,
                                             // z = particle volume (m^3, MPM), w = the group's length (s)
}

/// A liquid's drawn surface (FluidSurface.swift): MSL FluidSurface. Written once the scene's meshes are in.
struct GPUFluidSurface {
    var lo = SIMD4<Float>()                  // the grid's first node; w = its cell (m)
    var dims = SIMD4<UInt32>()               // nodes along x, y, z; w = all of them
    var field = SIMD4<Float>()               // x = the iso level (particles a cell), y = the splat's fixed point, z = 1 / cell
    var mesh = SIMD4<UInt32>()               // x = its first vertex in the scene's vertex buffer, y = its first index,
                                             // z = its last-frame offset (GPUMesh.prevOffset), w = vertices it holds
    var triangles = SIMD4<UInt32>()          // x = triangles it holds
}

/// A particle effect's particle (Particles.swift): MSL Particle. Its slot in the pool is its emitter's until it dies.
struct GPUParticle {
    var position = SIMD4<Float>()            // w = age (s)
    var velocity = SIMD4<Float>()            // w = lifetime (s)
    var info = SIMD4<UInt32>()               // x = spawn id (its emitter's count, or its parent's x 8 + which child),
                                             // y = seed, z = emitter, w = flags (ParticleSystem.alive)
}

/// What rays meet of a particle this frame (Shaders/ParticleTrace.metal): MSL ParticleRender. One per frame slot,
/// written by particlePoseKernel, its radiance by particleLightKernel.
struct GPUParticleRender {
    var centerRadius = SIMD4<Float>()        // w = radius (0: no particle)
    var axis = SIMD4<Float>()                // velocity / axis: the long axis's half (its length the half length);
                                             // world: the normal; w = spin (rad)
    var color = SIMD4<Float16>()             // rgb: albedo (lit) or emitted light (emissive), a: opacity
    var radiance = SIMD4<Float16>()          // rgb: the light it scatters to the eye (particleLightKernel), a: unused
    var info = SIMD4<UInt32>()               // x = pool slot | ParticleEmitter.Flags << 24, y = flipbook frames
                                             // (ParticleTrace.metal), z = soft distance (m, half) | shadow density
                                             // x 255 << 16 | atlas layer << 24, w = seed
    var keyLight = SIMD4<Float16>()          // rgb: the light of its brightest light (particleLightKernel), apart from
    var keyDir = SIMD4<Float16>()            // `radiance` for six-way smoke; xyz: where it comes from (unit)
}

/// An emitter as the kernels read it (Particles.swift): MSL ParticleEmitter. Written once.
package struct GPUParticleEmitter {
    var origin = SIMD4<Float>()              // w = the shape's radius
    var axis = SIMD4<Float>()                // the shape's and the velocity's axis (unit); w = the velocity's spread
                                             // about it (half angle, rad)
    var extent = SIMD4<Float>()              // a box's half extents; w = the shape (ParticleEmitter.Shape.code)
    var velocity = SIMD4<Float>()            // added to every particle's; w = a child's share of its parent's
    var speed = SIMD4<Float>()               // x...y = speed (m/s), z = 1: outward from the origin, w = the step it starts
                                             // at (steps count from the start, ParticleSystem.stepLength each)
    var life = SIMD4<Float>()                // x...y = lifetime (s), z = particles a step, w = the step it stops at
    var burst = SIMD4<Float>()               // x = the step it bursts at, y = how many, z = every (steps, 0: once),
                                             // w = bursts (0: no end)
    var forces = SIMD4<Float>()              // x = gravity's share, y = drag (1/s), z = the wind's share, w = curl noise (m/s^2)
    var noise = SIMD4<Float>()               // x = curl noise's frequency (1/m), y = its scroll (1/s), z = vortex
                                             // (m/s^2), w = attraction (m/s^2)
    var attractor = SIMD4<Float>()           // the vortex's and attraction's centre; w = restitution
    var size = SIMD4<Float>()                // x = radius at birth, y = at death (m), z = random shrink (0...1),
                                             // w = stretch (velocity: s; the long axis's half grows by speed x it)
    var color0 = SIMD4<Float>()              // rgba at birth
    var color1 = SIMD4<Float>()              // at `look.x`
    var color2 = SIMD4<Float>()              // at death
    var look = SIMD4<Float>()                // x = color1's place in the life (0...1), y = emitted light's scale
                                             // (0: lit), z = soft distance (m), w = most spin (rad/s)
    var flip = SIMD4<Float>()                // x = frames, y = frames a second (0: the whole life), z = 1: random first
                                             // frame, w = the atlas kind's trim (its picture's radius, 0...1)
    var lock = SIMD4<Float>()                // axis: the axis (unit); world: the normal; w = friction
    var ids = SIMD4<UInt32>()                // x = first slot, y = capacity, z = parent (ParticleSystem.none), w = flags
    var ids2 = SIMD4<UInt32>()               // x = children an event, y = colliders (mask), z = orientation code,
                                             // w = atlas layer | shadow density x 255 << 8
    var ids3 = SIMD4<UInt32>()               // x = a mesh emitter's first instance (ParticleSystem.none: billboards),
                                             // y = a trail's places (0: none), z = its first trail, w = steps apart
    var extra = SIMD4<Float>()               // x = collision radius (m), y = a trail's width (of the particle's),
                                             // z = distortion (rad), w = its seeds' salt (bits: ParticleEmitter.seed)
    var field = SIMD4<Float>()               // x = its vector field (-1: none), y = strength, z = 1: a velocity it
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
    var lo = SIMD4<Float>()                  // the box's corner; w = 1: periodic
    var size = SIMD4<Float>()                // its size (a periodic one's period)
    var dims = SIMD4<UInt32>()               // nodes along x, y, z; w = where its nodes start
}

/// An analytic shape particles bounce off (Particles.swift): MSL ParticleCollider.
package struct GPUParticleCollider {
    var a = SIMD4<Float>()                   // plane: normal, w = offset (n.x = w on it); sphere: centre, w = radius;
                                             // box: centre
    var b = SIMD4<Float>()                   // box: half extents; w = kind (ParticleCollider.code)
}

/// One step of the particles (ParticlesGPU.encodeSteps): MSL ParticleStep, set as bytes.
package struct GPUParticleStep {
    var wind = SIMD4<Float>()                // the air's velocity (m/s); w = the curl noise's clock (s)
    var time: Float = 0                      // the step's start (s)
    var dt: Float = 0
    var step: UInt32 = 0                     // from the start
    var parity: UInt32 = 0                   // the alive list it reads (step & 1); bit 1: the scene is bound
    var emitters: UInt32 = 0
    var colliders: UInt32 = 0
    var capacity: UInt32 = 0
    var gravity: Float = 9.81
    // The pose's (ParticlesGPU.encodePose):
    var casters: UInt32 = 0                  // the shadow casters' slots (the pool's first)
    var casterBound: UInt32 = 0              // the casters' structure's boxes; the others' start there in the records
    var othersBound: UInt32 = 0              // the others' structure's boxes
    var pose: UInt32 = 0                     // which pair of the pose's counters it counts in (the other pair it clears)
}

/// Catches accidental layout drift between Swift and MSL at startup.
/// One body of water's look (MSL WaterLook, WaterLook.gpu): a table of them, which the water map and the water's
/// surfaces' triangles name.
package struct GPUWaterLook {
    var absorption: SIMD4<Float>   // rgb = per metre, w = index of refraction
    var scattering: SIMD4<Float>   // rgb = per metre, w = phase g
    var waves: SIMD4<Float>        // x = share of the wind's sea, y = chop, z = ripples, w = roughness
    var foam: SIMD4<Float>         // x = crest foam, y = shore foam width (m), z = white water, w = flow speed (m/s)
}

/// The water this frame (MSL WaterScene, Shaders/WaterCommon.metal), its address in the shading arguments
/// (SceneShading.water): the time and wind of its waves, its map's two levels around the camera, the near patch, the
/// looks, and its textures (the map, the FFT cascades, the caustics) by their resource IDs.
struct GPUWaterScene {
    var time = SIMD4<Float>.zero       // x = now (s), y = the last frame's, z = dt, w = the highest any water's surface reaches (its waves too)
    var wind = SIMD4<Float>.zero       // xy = toward where it blows (unit; x, z), z = speed (m/s), w = 0
    var cascades = SIMD4<Float>.zero   // xyz = the FFT cascades' tile sides (m), w = how many (0: no waves)
    var phase0 = SIMD4<Float>.zero     // where the scene's origin is in each cascade's tile (m): xy = 0th, zw = 1st
    var phase1 = SIMD4<Float>.zero     // xy = the 2nd's
    var map0 = SIMD4<Float>.zero       // the map's near level: xy = scene x, z of texel (0, 0)'s corner, z = metres a texel, w = texels a side
    var map1 = SIMD4<Float>.zero       // ...its far level
    var near = SIMD4<Float>.zero       // xyz = the near patch's centre (scene), w = its radius (0: none)
    var counts = SIMD4<UInt32>.zero    // x = looks, y = WATER_* flags, w = METALRENDERER_WATER_DEBUG
    var looks: UInt64 = 0              // GPUWaterLook per look
    var level = MTLResourceID()        // map: 2D array [near, far], r = surface (< -1e8: dry), g = ground
    var info = MTLResourceID()         // map: rg = flow (m/s, 0.5 = still, 1/8 m/s a step: (v / 8) + 0.5), b = look / 255, a = turbulence
    var waves = MTLResourceID()        // FFT: 2D array per cascade, xyz = displacement (m), w = foam
    var slopes = MTLResourceID()       // FFT: 2D array per cascade, xy = height's slope (x, z), zw = sideways push's
    var caustics = MTLResourceID()     // the sun's caustics on a bed a few metres down, tiled as cascade 1
    var surfaces = MTLResourceID()     // the still surfaces' own structure (a primitive one, the scene's coordinates)
    var surfaceVertices: UInt64 = 0    // ...their vertices (float4), indices, and a look per triangle (a byte)
    var surfaceIndices: UInt64 = 0
    var surfaceLooks: UInt64 = 0
    var nearPatch = MTLResourceID()    // the near patch's structure (WATER_NEAR), refitted every frame
    var nearVertices: UInt64 = 0       // ...its vertices as the waves moved them (float4: w = the look)
    var nearIndices: UInt64 = 0
    var nearRest: UInt64 = 0           // ...and where each is at rest (float2: x, z)
    static let fft: UInt32 = 1, nearPatch: UInt32 = 2, causticsOn: UInt32 = 4, mapped: UInt32 = 8
}

func validateGPULayouts() {
    precondition(MemoryLayout<GPUWaterLook>.stride == 64, "GPUWaterLook layout mismatch")
    precondition(MemoryLayout<GPUWaterScene>.stride == 256, "GPUWaterScene layout mismatch")
    precondition(MemoryLayout<Uniforms>.stride == 304, "Uniforms layout mismatch")
    precondition(MemoryLayout<GPUMesh>.stride == 48 && MemoryLayout<GPUMesh>.offset(of: \.block) == 24, "GPUMesh layout mismatch")
    precondition(MemoryLayout<GPUInstanceData>.stride == 208, "GPUInstanceData layout mismatch")
    precondition(MemoryLayout<GPUSkinVertex>.stride == 16, "GPUSkinVertex layout mismatch")
    precondition(MemoryLayout<GPUJoint>.stride == 48, "GPUJoint layout mismatch")
    precondition(MemoryLayout<GPUJointMatrix>.stride == 48, "GPUJointMatrix layout mismatch")
    precondition(MemoryLayout<GPUPoseSlot>.stride == 32, "GPUPoseSlot layout mismatch")
    precondition(MemoryLayout<GPUMaterial>.stride == 64, "GPUMaterial layout mismatch")
    precondition(MemoryLayout<GPUMaterialExtra>.stride == 32, "GPUMaterialExtra layout mismatch")
    precondition(MemoryLayout<GPULight>.stride == 64, "GPULight layout mismatch")
    precondition(MemoryLayout<GPULightTableEntry>.stride == 16, "GPULightTableEntry layout mismatch")
    precondition(MemoryLayout<GPUTriangleInfo>.stride == 8, "GPUTriangleInfo layout mismatch")
    precondition(MemoryLayout<GPURestirParams>.stride == 32, "GPURestirParams layout mismatch")
    precondition(MemoryLayout<GPULightTreeNode>.stride == 64, "GPULightTreeNode layout mismatch")
    precondition(MemoryLayout<GPURestirGIParams>.stride == 48, "GPURestirGIParams layout mismatch")
    precondition(MemoryLayout<GPUEmissiveTriangle>.stride == 64, "GPUEmissiveTriangle layout mismatch")
    precondition(MemoryLayout<GPUFogVolume>.stride == 64, "GPUFogVolume layout mismatch")
    precondition(MemoryLayout<GPUPostParams>.stride == 80, "GPUPostParams layout mismatch")
    precondition(MemoryLayout<GPUPathTraceParams>.stride == 48, "GPUPathTraceParams layout mismatch")
    precondition(MemoryLayout<GPUSDFNode>.stride == 96, "GPUSDFNode layout mismatch")
    precondition(MemoryLayout<GPUSDFShape>.stride == 48, "GPUSDFShape layout mismatch")
    precondition(MemoryLayout<GPUSDFVolume>.stride == 48, "GPUSDFVolume layout mismatch")
    precondition(MemoryLayout<GPUFogParams>.stride == 128 + 64 * GPUFogParams.maxVolumes, "GPUFogParams layout mismatch")
    precondition(MemoryLayout<GPUSkyParams>.stride == 192, "GPUSkyParams layout mismatch")
    precondition(MemoryLayout<BVHNode>.stride == 64, "BVHNode layout mismatch")
    precondition(MemoryLayout<RCParams>.stride == 48, "RCParams layout mismatch")
    precondition(MemoryLayout<GPURegirParams>.stride == 96, "GPURegirParams layout mismatch")
    precondition(MemoryLayout<GPURegirReservoir>.stride == 16, "GPURegirReservoir layout mismatch")
    precondition(MemoryLayout<VGCluster>.stride == 80, "VGCluster layout mismatch")
    precondition(MemoryLayout<VirtualBLAS.Entry>.stride == 32, "VirtualBLAS.Entry (VGBlas) layout mismatch")
    precondition(MemoryLayout<VirtualGeometry.Params>.stride == 48, "VirtualGeometry.Params (VGParams) layout mismatch")
    precondition(MemoryLayout<GPUPhysicsBody>.stride == 128, "GPUPhysicsBody layout mismatch")
    precondition(MemoryLayout<GPUPhysicsShape>.stride == 64, "GPUPhysicsShape layout mismatch")
    precondition(MemoryLayout<GPUPhysicsPair>.stride == 16, "GPUPhysicsPair layout mismatch")
    precondition(MemoryLayout<GPUPhysicsContact>.stride == 64, "GPUPhysicsContact layout mismatch")
    precondition(MemoryLayout<GPUPhysicsParams>.stride == 160, "GPUPhysicsParams layout mismatch")
    precondition(MemoryLayout<GPUPhysicsTet>.stride == 32, "GPUPhysicsTet layout mismatch")
    precondition(MemoryLayout<GPUSoftVertex>.stride == 32, "GPUSoftVertex layout mismatch")
    precondition(MemoryLayout<GPUSoftEmbed>.stride == 32, "GPUSoftEmbed layout mismatch")
    precondition(MemoryLayout<GPUFleshHeader>.stride == 64, "GPUFleshHeader layout mismatch")
    precondition(MemoryLayout<GPUFleshPin>.stride == 48, "GPUFleshPin layout mismatch")
    precondition(MemoryLayout<GPUMuscle>.stride == 64, "GPUMuscle layout mismatch")
    precondition(MemoryLayout<GPUFleshFibre>.stride == 32, "GPUFleshFibre layout mismatch")
    precondition(MemoryLayout<GPUSkinAttach>.stride == 64, "GPUSkinAttach layout mismatch")
    precondition(MemoryLayout<GPUPhysicsConstraint>.stride == 16, "GPUPhysicsConstraint layout mismatch")
    precondition(MemoryLayout<GPUPhysicsParticle>.stride == 64, "GPUPhysicsParticle layout mismatch")
    precondition(MemoryLayout<GPUPhysicsGrab>.stride == 48, "GPUPhysicsGrab layout mismatch")
    precondition(MemoryLayout<GPUPhysicsJoint>.stride == 112, "GPUPhysicsJoint layout mismatch")
    precondition(MemoryLayout<GPUFractureNode>.stride == 64, "GPUFractureNode layout mismatch")
    precondition(MemoryLayout<GPUFractureWeld>.stride == 64, "GPUFractureWeld layout mismatch")
    precondition(MemoryLayout<GPUFractureState>.stride == 64, "GPUFractureState layout mismatch")
    precondition(MemoryLayout<GPUFractureCommand>.stride == 48, "GPUFractureCommand layout mismatch")
    precondition(MemoryLayout<GPUFractureParams>.stride == 32, "GPUFractureParams layout mismatch")
    precondition(MemoryLayout<GPUBreakEvent>.stride == 32, "GPUBreakEvent layout mismatch")
    precondition(MemoryLayout<GPUHairStrand>.stride == 64, "GPUHairStrand layout mismatch")
    precondition(MemoryLayout<GPUHairVertex>.stride == 64, "GPUHairVertex layout mismatch")
    precondition(MemoryLayout<GPUHairParams>.stride == 64, "GPUHairParams layout mismatch")
    precondition(MemoryLayout<GPUHairGroup>.stride == 64, "GPUHairGroup layout mismatch")
    precondition(MemoryLayout<GPUFluidParticle>.stride == 80, "GPUFluidParticle layout mismatch")
    precondition(MemoryLayout<GPUFluidParams>.stride == 224, "GPUFluidParams layout mismatch")
    precondition(MemoryLayout<GPUFluidSurface>.stride == 80, "GPUFluidSurface layout mismatch")
    precondition(MemoryLayout<GPUParticle>.stride == 48, "GPUParticle layout mismatch")
    precondition(MemoryLayout<GPUParticleRender>.stride == 80, "GPUParticleRender layout mismatch")
    precondition(MemoryLayout<GPUParticleField>.stride == 48, "GPUParticleField layout mismatch")
    precondition(MemoryLayout<GPUParticleEmitter>.stride == 352, "GPUParticleEmitter layout mismatch")
    precondition(MemoryLayout<GPUParticleCollider>.stride == 32, "GPUParticleCollider layout mismatch")
    precondition(MemoryLayout<GPUParticleStep>.stride == 64, "GPUParticleStep layout mismatch")
    precondition(MemoryLayout<SIMD3<Float>>.stride == 16, "float3 must be 16 bytes to match MSL")
}
