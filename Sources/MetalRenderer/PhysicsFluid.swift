import Foundation
import simd

/// Liquids: water, blood and honey poured from nozzles, each in a box of its own (its domain: the box's walls hold it),
/// splashing over the static colliders and the bodies there, and pushing the bodies back (two-way: a light box floats,
/// a heavy one sinks, slowly in honey). Two solvers:
///
/// - **PBF** (position based fluids, Macklin & Müller 2013): particles kept at their rest density by a constraint each,
///   solved Jacobi a few iterations a substep, with s_corr against clumping, XSPH viscosity and vorticity confinement.
///   Neighbours come from a grid sorted by cell every substep (a counting sort; a cell's particles in the order they had,
///   so that every sum runs in the same order on the GPU and the CPU).
/// - **MLS-MPM** (Hu et al. 2018): particles carry their velocity and its gradient (APIC) to a grid and back each
///   substep; the grid's nodes take the stress (Tait's pressure on how dense the grid sees the particles about each,
///   and a viscous one from the velocity's gradient, Carreau's shear thinning for blood) and the colliders, whose
///   nodes count as full in that density (boundary particles' role). Honey's viscosity (10 Pa s) is inside what an
///   explicit step at 1 cm and 1/720 s holds (2.4 ms).
///
/// Every sum that many threads add to (MPM's grid, the bodies' impulses) is in fixed point, as integers: the same
/// numbers whatever order the threads come in, so a GPU run is the same every time and the CPU's (PhysicsFluidCPU.swift,
/// the reference) adds the same integers.
///
/// A liquid steps in groups of `PhysicsWorld.contactRefresh` substeps of the bodies' (1/240 s): before each group's
/// narrow phase, against the bodies where they are, it pours what its nozzle has poured by then (a function of the
/// group's clock alone), runs its own substeps, and leaves the impulses it gave each body to be applied before the
/// bodies' substeps (`applyFluidImpulses`).
enum LiquidKind: Int, CaseIterable {
    case water, blood, honey

    var name: String { ["water", "blood", "honey"][rawValue] }

    /// How it moves.
    struct Physics {
        var density: Float                   // kg/m^3
        var viscosity: SIMD4<Float>          // Carreau: mu0, mu infinity (Pa s), lambda (s), n (Newtonian: mu0 = mu inf)
        var bulk: Float                      // MPM: Tait's bulk modulus (Pa)
        var friction: Float                  // against walls and colliders
        var stickiness: Float                // 0...1: how much of its slide along a wall it keeps off (1: no slip)
        var xsph: Float                      // PBF: XSPH viscosity
        var vorticity: Float                 // PBF: vorticity confinement (m/s)
        var nozzleRadius: Float              // m
        var speed: Float                     // m/s out of the nozzle
    }

    /// How it looks (Shaders/Liquid.metal): a dielectric that absorbs (Beer-Lambert) on the way through.
    struct Look {
        var absorption: SIMD3<Float>         // 1/m, per channel
        var ior: Float
        var roughness: Float
    }

    var physics: Physics {
        switch self {
        case .water:
            return Physics(density: 1000, viscosity: SIMD4(1e-3, 1e-3, 0, 1), bulk: 1.2e4, friction: 0.1, stickiness: 0,
                           xsph: 0.02, vorticity: 0.02, nozzleRadius: 0.035, speed: 1.4)
        case .blood:   // Cho & Kensey's Carreau fit
            return Physics(density: 1060, viscosity: SIMD4(0.056, 0.00345, 3.313, 0.3568), bulk: 1.2e4, friction: 0.3, stickiness: 0.2,
                           xsph: 0.08, vorticity: 0.005, nozzleRadius: 0.03, speed: 1.2)
        case .honey:
            return Physics(density: 1420, viscosity: SIMD4(10, 10, 0, 1), bulk: 1.6e4, friction: 0.6, stickiness: 1,
                           xsph: 0.5, vorticity: 0, nozzleRadius: 0.03, speed: 0.8)
        }
    }

    var look: Look {
        switch self {
        case .water: return Look(absorption: SIMD3(2.0, 0.35, 0.12), ior: 1.333, roughness: 0.02)
        case .blood: return Look(absorption: SIMD3(35, 600, 800), ior: 1.36, roughness: 0.04)
        case .honey: return Look(absorption: SIMD3(2, 9, 45), ior: 1.49, roughness: 0.03)
        }
    }

    /// The Carreau viscosity at shear rate `shear` (1/s).
    static func viscosity(_ k: SIMD4<Float>, shear: Float) -> Float {
        k.x == k.y ? k.x : k.y + (k.x - k.y) * pow(1 + k.z * k.z * shear * shear, (k.w - 1) / 2)
    }
}

/// A liquid in the world (PhysicsWorld.addLiquid): what its kernels are told, its nozzle's layer of particles, the
/// static colliders inside its domain, and (the CPU's) its state.
struct FluidSystem {
    var kind: LiquidKind
    var solver: PhysicsSettings.Solver
    var params: GPUFluidParams
    /// The nozzle's layer: each particle's offset from the nozzle (world).
    var layer: [SIMD4<Float>]
    /// The static colliders (PhysicsWorld.statics) whose box meets the domain.
    var statics: [UInt32]
    /// The CPU's state: the particles poured so far (sorted by cell after every PBF substep), and the groups run.
    var particles: [GPUFluidParticle] = []
    var clock: UInt32 = 0
    /// Its drawn surface's grid and mesh (FluidSurface.swift; the scene fills in where the mesh is).
    var surface = GPUFluidSurface()

    var capacity: Int { Int(params.counts.x) }
    var domain: AABB { AABB(lo: PhysicsMath.xyz(params.lo), hi: PhysicsMath.xyz(params.hi)) }
    var cell: Float { params.lo.w }
    var dims: SIMD3<Int> { SIMD3(Int(params.dims.x), Int(params.dims.y), Int(params.dims.z)) }
    /// A particle's mass (kg) and spacing (m).
    var mass: Float { params.material.y }
    var spacing: Float { params.extra.y }

    /// The particles poured by the group `clock` (its start): layers of `emission.x`, one every `emission.y` / 256
    /// ticks from tick `emission.z`, up to the capacity. Integers: the GPU's count is the same.
    static func poured(_ p: GPUFluidParams, clock: UInt32) -> Int {
        guard clock >= p.emission.z else { return 0 }
        let layers = Int((clock - p.emission.z) &* 256 / p.emission.y) + 1
        return min(layers * Int(p.emission.x), Int(p.counts.x))
    }
    func poured(clock: UInt32) -> Int { FluidSystem.poured(params, clock: clock) }

    /// The most particles a group can pour (what the GPU's pour is dispatched for).
    var mostPouredInAGroup: Int { Int(params.emission.x) * (255 / Int(params.emission.y) + 2) }
}

/// The world's liquids and what they push the bodies by.
struct FluidWorld {
    var systems: [FluidSystem] = []
    /// Per dynamic body, the impulse the liquids gave it this group (fixed point: `GPUFluidParams.fixed.z` per N s):
    /// linear then angular (about its centre of mass), as the GPU's int4 pairs.
    var impulses: [SIMD4<Int32>] = []
    /// Bodies held still (asleep) until the group whose tick is `y`, then let go (body `x`): boxes dropped into a
    /// pool once it is there (`PhysicsWorld.hold`).
    var drops: [SIMD2<UInt32>] = []

    /// Fixed point: a particle's weight on a node (MPM's mass, in particles), its momentum (particles x m/s), and an
    /// impulse (N s). 2^22 holds 512 particles' weight on a node, 2^18 x 512 x the top speed fits in 31 bits.
    static let massScale: Float = 4_194_304          // 2^22
    static let momentumScale: Float = 262_144        // 2^18
    static let impulseScale: Float = 1_048_576       // 2^20
    static let topSpeed: Float = 5
    /// A body's velocity change from the liquids in a group is at most this (m/s), and wakes it above this beyond what
    /// gravity would have given it.
    static let kickCap: Float = 2
    static let wakeKick: Float = 0.03
    /// Bodies a liquid can meet at once.
    static let maxBodies = 64
    static let maxStatics = 32
    /// PBF's cohesion: how far under its rest density a particle's constraint pulls it back. Without it a falling
    /// stream only stretches (it stayed 3.5 cm wide and thinned to a fifth); at 0.05 it necks down as MPM's does
    /// (1.8 cm from a 3.5 cm nozzle) and stays whole; 0.2 began to fling particles.
    static let pbfTension: Float = 0.05
    /// MPM's grid: 1 cm cells, a particle each, 3 substeps a group (1/720 s: sound, sqrt(K / rho) = 3.5 m/s, crosses
    /// half a cell).
    static let mpmCell: Float = 0.01
    static let mpmSpacing: Float = 0.01
    static let mpmSubsteps: UInt32 = 3
    /// MPM's artificial bulk viscosity, a share of rho c dx: 0.1 brings a pour in a box to rest (0.44 m/s at 2.5 s
    /// without; J at least 0.995); 1 went unstable.
    static let mpmBulkViscosity: Float = 0.1

    /// MPM's: none. With J from the density (mpmSubstep), any (0.01 of K) fed a pool's sloshing (0.55 to 0.83 m/s over
    /// 8 s; without, 0.38 to 0.21).
    static let mpmTension: Float = 0
}

extension PhysicsWorld {
    /// A liquid of `kind`, stepped by `solver`, held in `domain` (its walls), poured from `nozzle` along `direction`
    /// from `start` (s) until it has `capacity` particles.
    func addLiquid(_ kind: LiquidKind, solver: PhysicsSettings.Solver, domain: AABB, nozzle: SIMD3<Float>,
                   direction: SIMD3<Float> = SIMD3(0, -1, 0), start: Float = 0.3, capacity: Int) {
        let k = kind.physics
        // MPM: 1 cm cells, a particle a cell; PBF: 1.2 cm apart, h twice that. (MPM's quadratic kernel spans three
        // cells: at 2 cm cells and 8 particles each, a pool 3 cm deep looked half as dense as it was, had no pressure
        // and sank flat onto the floor.)
        let spacing: Float = solver == .mpm ? FluidWorld.mpmSpacing : 0.012
        let cell: Float = solver == .mpm ? FluidWorld.mpmCell : 2 * spacing
        // MPM's grid reaches two cells past the walls, where its boundary's three nodes each side are (the wall's and
        // the cell inside it: mpmNodeVelocity): its particles stay inside the walls, two cells in from its ends.
        let domain = solver == .mpm ? AABB(lo: domain.lo - 2 * cell, hi: domain.hi + 2 * cell) : domain
        let size = domain.hi - domain.lo
        let dims = solver == .mpm ? SIMD3<Int>((size / cell).rounded(.up)) &+ 1 : SIMD3<Int>((size / cell).rounded(.up))
        // A group's share of the step (the last of the bodies' groups may have fewer substeps: the liquid's are even).
        let group = PhysicsWorld.stepLength / Float(fluidGroups)
        let substeps: UInt32 = solver == .mpm ? FluidWorld.mpmSubsteps : 1
        var p = GPUFluidParams()
        p.gravity = SIMD4(gravity, group / Float(substeps))
        p.lo = SIMD4(domain.lo, cell)
        p.hi = SIMD4(domain.hi, 1 / cell)
        p.dims = SIMD4(UInt32(dims.x), UInt32(dims.y), UInt32(dims.z), UInt32(dims.x * dims.y * dims.z))
        p.counts = SIMD4(UInt32(capacity), substeps, 0, solver == .mpm ? 1 : 0)
        p.viscosity = k.viscosity
        p.pbf2 = SIMD4(k.xsph, k.vorticity, k.friction, k.stickiness)
        p.fixed = SIMD4(FluidWorld.massScale, FluidWorld.momentumScale, FluidWorld.impulseScale, FluidWorld.topSpeed)
        let volume = spacing * spacing * spacing
        if solver == .mpm {
            p.material = SIMD4(k.density, k.density * volume, k.bulk, 7)
            // (pbf.x: its tension; y: an artificial bulk viscosity, zeta = share x rho c dx, as SPH's.)
            p.pbf.x = FluidWorld.mpmTension
            p.pbf.y = FluidWorld.mpmBulkViscosity * k.density * (k.bulk / k.density).squareRoot() * cell
        } else {
            let h = cell
            let lattice = PBF.restSums(h: h, spacing: spacing)
            // (z: how far under its rest density a particle's constraint pulls it back, the liquid's cohesion: without
            // it a falling stream only stretches, and thins to nothing.)
            p.material = SIMD4(lattice.density, k.density * volume, FluidWorld.pbfTension, 0)
            // The relaxation and s_corr's k in lambda's units (m^2: one over the constraint's squared gradients at
            // rest), so that they mean the same at any spacing: Macklin's k = 0.1 as is pushes a particle a spacing
            // away at 1.2 cm.
            let dq = 0.2 * h
            p.pbf = SIMD4(h, 0.05 * lattice.gradients, 0.1 / lattice.gradients, 1 / PBF.poly6(dq * dq, h: h))
        }
        // The nozzle's layer: a hexagonal disc across the direction, layers 2/sqrt(3) spacings apart (a spacing^3 each).
        let d = normalize(direction)
        let u = normalize(abs(d.y) < 0.9 ? cross(d, SIMD3(0, 1, 0)) : cross(d, SIMD3(1, 0, 0))), v = cross(d, u)
        var layer: [SIMD4<Float>] = []
        let rows = Int(k.nozzleRadius / (spacing * 0.866)) + 1
        for b in -rows...rows {
            for a in -2 * rows...2 * rows {
                let x = (Float(a) + 0.5 * Float(b)) * spacing, y = Float(b) * spacing * 0.866
                if x * x + y * y <= k.nozzleRadius * k.nozzleRadius { layer.append(SIMD4(u * x + v * y, 0)) }
            }
        }
        let between = spacing * 2 / Float(3).squareRoot() / k.speed   // s between layers
        p.nozzle = SIMD4(nozzle, k.nozzleRadius)
        p.direction = SIMD4(d, k.speed)
        p.emission = SIMD4(UInt32(layer.count), UInt32((between / group * 256).rounded()), UInt32((start / group).rounded(.up)), 4)
        p.extra = SIMD4(0.5 * spacing, spacing, volume, group)
        // The static colliders it can meet: those whose box (a plane: its half space) meets the domain.
        var near: [UInt32] = []
        for s in statics.indices {
            let st = statics[s]
            let meets: Bool
            if shapes[Int(st.info.x)].info.x == PhysicsShapeKind.plane.rawValue {
                let n = PhysicsMath.qrot(st.rotation, SIMD3(0, 1, 0)), o = PhysicsMath.xyz(st.position)
                let corners = (0..<8).map { c in SIMD3<Float>(c & 1 == 0 ? domain.lo.x : domain.hi.x, c & 2 == 0 ? domain.lo.y : domain.hi.y,
                                                              c & 4 == 0 ? domain.lo.z : domain.hi.z) }
                meets = corners.contains { dot($0 - o, n) < spacing }
            } else {
                let b = staticBounds[s]
                meets = all(b.lo .<= domain.hi + spacing) && all(b.hi .>= domain.lo - spacing)
            }
            if meets { near.append(UInt32(s)) }
        }
        precondition(near.count <= FluidWorld.maxStatics, "a liquid meets more than \(FluidWorld.maxStatics) static colliders")
        p.counts.z = UInt32(near.count)
        if fluid == nil { fluid = FluidWorld() }
        var system = FluidSystem(kind: kind, solver: solver, params: p, layer: layer, statics: near)
        system.surface = system.surfaceGrid()
        let room = system.surfaceCapacity
        system.surface.mesh.w = UInt32(room.vertices)
        system.surface.triangles.x = UInt32(room.triangles)
        fluid!.systems.append(system)
    }

    /// Body `body` held where it is (asleep) until `time` (s), then dropped: a box let go into a liquid already poured
    /// (resting on the floor as the liquid rises round it, nothing gets under it to lift it). Before `addLiquid`.
    func hold(body: Int, until time: Float) {
        if fluid == nil { fluid = FluidWorld() }
        bodies[body].info.y |= PhysicsWorld.asleep
        fluid!.drops.append(SIMD2(UInt32(body), UInt32((time / (PhysicsWorld.stepLength / Float(fluidGroups))).rounded())))
    }

    /// The groups of substeps a step runs in: the liquids step once before each.
    var fluidGroups: Int { (substeps + PhysicsWorld.contactRefresh - 1) / PhysicsWorld.contactRefresh }

    /// The liquids at their start (none poured), and the bodies' impulses cleared: `finish` and `reset`.
    func resetFluids() {
        guard fluid != nil else { return }
        for s in fluid!.systems.indices {
            fluid!.systems[s].particles = []
            fluid!.systems[s].clock = 0
        }
        fluid!.impulses = [SIMD4<Int32>](repeating: .zero, count: 2 * bodies.count)
    }

    /// The bodies a liquid in `domain` may meet this group: dynamic ones whose sphere reaches into it (a kinematic body
    /// too: it pushes, but takes nothing back), the lowest `FluidWorld.maxBodies`.
    func fluidBodies(_ p: GPUFluidParams) -> [UInt32] {
        var near: [UInt32] = []
        for (i, b) in bodies.enumerated() where near.count < FluidWorld.maxBodies {
            let c = PhysicsMath.xyz(b.position), r = b.invInertia.w + p.lo.w
            let nearest = simd_clamp(c, PhysicsMath.xyz(p.lo), PhysicsMath.xyz(p.hi))
            if length_squared(c - nearest) < r * r { near.append(UInt32(i)) }
        }
        return near
    }
}

/// PBF's kernels (Müller et al. 2003): poly6 for the density, spiky's gradient for the pushes.
enum PBF {
    @inline(__always) static func poly6(_ r2: Float, h: Float) -> Float {
        let h2 = h * h
        guard r2 < h2 else { return 0 }
        let d = h2 - r2
        return 315 / (64 * Float.pi * pow(h, 9)) * d * d * d
    }

    @inline(__always) static func spiky(_ r: SIMD3<Float>, h: Float) -> SIMD3<Float> {
        let l = length(r)
        guard l < h, l > 1e-9 else { return .zero }
        let d = h - l
        return r * (-45 / (Float.pi * pow(h, 6)) * d * d / l)
    }

    /// The share of poly6's weight beyond a plane `d` from its centre (a wall's boundary density: a half space of rest
    /// liquid behind it, Akinci et al. 2012's role), and its derivative along `d`: (315/256) (g(1) - g(t)) with
    /// t = d/h, g(t) = t - 4/3 t^3 + 6/5 t^5 - 4/7 t^7 + t^9/9 (the integral of (1 - t^2)^4).
    @inline(__always) static func wall(_ d: Float, h: Float) -> (share: Float, slope: Float) {
        let t = min(max(d / h, -1), 1), t2 = t * t
        let g = t * (1 + t2 * (-4.0 / 3 + t2 * (6.0 / 5 + t2 * (-4.0 / 7 + t2 / 9))))
        let one = 1 - t2
        return (315.0 / 256 * (0.40634921 - g), -315.0 / 256 * one * one * one * one / h)
    }

    /// Over a cubic lattice `spacing` apart, about a point of it: the density (sum of W; a particle's mass is 1) and the
    /// sum of the squared gradients of its constraint (what the relaxation is a share of).
    static func restSums(h: Float, spacing: Float) -> (density: Float, gradients: Float) {
        let n = Int(h / spacing) + 1
        var density: Float = 0, squares: Float = 0
        for z in -n...n {
            for y in -n...n {
                for x in -n...n {
                    let r = SIMD3<Float>(Float(x), Float(y), Float(z)) * spacing
                    density += poly6(length_squared(r), h: h)
                    squares += length_squared(spiky(r, h: h))
                }
            }
        }
        return (density, squares / (density * density))
    }
}
