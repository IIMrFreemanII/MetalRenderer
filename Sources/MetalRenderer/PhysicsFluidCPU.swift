import Foundation
import simd

/// The liquids' step on the CPU: the reference Shaders/Fluid.metal is checked against, kernel by kernel, in its order.
/// The sums many GPU threads add to are integers here too (FluidWorld's fixed point), added in whatever order: the
/// same numbers.
extension PhysicsWorld {
    /// One group's liquids (before the group's narrow phase), then their impulses on the bodies.
    func stepFluids() {
        guard let fluid, !fluid.systems.isEmpty else { return }
        for s in fluid.systems.indices { stepFluid(s) }
        applyFluidImpulses()
    }

    private func stepFluid(_ s: Int) {
        var system = fluid!.systems[s]
        let p = system.params
        let clock = system.clock
        system.clock += 1
        let poured = system.poured(clock: clock)
        for i in system.particles.count..<max(poured, system.particles.count) {
            system.particles.append(PhysicsWorld.pour(p, layer: system.layer, i, clock: clock))
        }
        let near = fluidBodies(p)
        for _ in 0..<Int(p.counts.y) {
            if system.solver == .mpm { mpmSubstep(&system, bodies: near) } else { pbfSubstep(&system, bodies: near) }
        }
        fluid!.systems[s] = system
    }

    /// Particle `i` as the nozzle pours it in group `clock`: its layer's place in the stream, as far along as the
    /// time since its layer left (MSL fluidPourKernel).
    static func pour(_ p: GPUFluidParams, layer: [SIMD4<Float>], _ i: Int, clock: UInt32) -> GPUFluidParticle {
        let per = Int(p.emission.x), k = UInt32(i / per), j = i % per
        let ticks = Float((clock - p.emission.z) &* 256 &- k &* p.emission.y) / 256
        let d = PhysicsMath.xyz(p.direction)
        var x = PhysicsMath.xyz(p.nozzle) + PhysicsMath.xyz(layer[j]) + d * (p.direction.w * ticks * p.extra.w)
        let margin = p.counts.w == 1 ? 2 * p.lo.w : p.extra.x   // (MPM's grid reaches two cells past the walls)
        x = simd_clamp(x, PhysicsMath.xyz(p.lo) + margin, PhysicsMath.xyz(p.hi) - margin)
        return GPUFluidParticle(position: SIMD4(x, 1), velocity: SIMD4(d * p.direction.w, 0))
    }

    // MARK: Colliders

    /// Collider `code` (a static's index | staticBit, or a body's), as MSL fluidCollider reads it.
    @inline(__always) private func fluidCollider(_ code: UInt32) -> GPUPhysicsBody {
        code & PhysicsWorld.staticBit != 0 ? statics[Int(code & ~PhysicsWorld.staticBit)] : bodies[Int(code)]
    }

    /// Whether `x` may be within `r` of collider `code`: its box (a plane: its half space), a body's sphere.
    @inline(__always) private func fluidNear(_ code: UInt32, _ x: SIMD3<Float>, _ r: Float) -> Bool {
        if code & PhysicsWorld.staticBit != 0 { return touchesStatic(Int(code & ~PhysicsWorld.staticBit), centre: x, radius: r) }
        let b = bodies[Int(code)], reach = b.invInertia.w + r
        return length_squared(x - PhysicsMath.xyz(b.position)) < reach * reach
    }

    /// The colliders a liquid's particle meets this group: its statics, then the bodies near it.
    private func fluidColliders(_ system: FluidSystem, bodies near: [UInt32]) -> [UInt32] {
        system.statics.map { $0 | PhysicsWorld.staticBit } + near
    }

    /// Adds impulse `j` at `x` to body `code`'s accumulator, if it is a dynamic body (fixed point).
    @inline(__always) private func fluidImpulse(_ code: UInt32, _ j: SIMD3<Float>, at x: SIMD3<Float>) {
        guard code & PhysicsWorld.staticBit == 0 else { return }
        let b = bodies[Int(code)]
        guard b.position.w > 0, b.info.y & PhysicsWorld.kinematicBit == 0 else { return }
        let l = cross(x - PhysicsMath.xyz(b.position), j)
        let i = Int(code)
        fluid!.impulses[2 * i] &+= SIMD4(PhysicsWorld.fixed(j, FluidWorld.impulseScale), 0)
        fluid!.impulses[2 * i + 1] &+= SIMD4(PhysicsWorld.fixed(l, FluidWorld.impulseScale), 0)
    }

    /// `v` x `scale` in fixed point (MSL fluidFixed): rounded to the nearest even, held to 2^30.
    @inline(__always) static func fixed(_ v: SIMD3<Float>, _ scale: Float) -> SIMD3<Int32> {
        let c = simd_clamp(v * scale, SIMD3(repeating: -1_073_741_824), SIMD3(repeating: 1_073_741_824))
        return SIMD3<Int32>(c.rounded(.toNearestOrEven))
    }
    @inline(__always) static func fixed(_ v: Float, _ scale: Float) -> Int32 {
        Int32(min(max(v * scale, -1_073_741_824), 1_073_741_824).rounded(.toNearestOrEven))
    }

    /// A particle at `x` (radius `r`, from `start` this substep) pushed out of the colliders it is inside, one after
    /// another, sliding with `friction` against their surfaces' motion (MSL fluidPushOut). `mass` > 0: what it pushes
    /// back on each dynamic body over `h`.
    private func fluidPushOut(_ x: SIMD3<Float>, start: SIMD3<Float>, r: Float, h: Float, friction: Float, mass: Float,
                              colliders: [UInt32]) -> SIMD3<Float> {
        var y = x
        let cap = FluidWorld.topSpeed * h
        for code in colliders where fluidNear(code, y, r) {
            let b = fluidCollider(code), pose = Pose(b), shape = Int(b.info.x)
            let local = pose.toBody(y)
            let depth = distance(shape: shape, local) - r
            guard depth < 0 else { continue }
            let n = pose.direction(gradient(shape: shape, local))
            let surface = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), y - pose.position)
            let push = PhysicsWorld.particlePush(n, min(-depth, cap), (y - start) - surface * h, friction)
            y += push
            if mass > 0 { fluidImpulse(code, -push * (mass / h), at: y) }
        }
        return y
    }

    /// Body impulses from the liquids this group, applied (MSL fluidApplyKernel): a sleeping body wakes only when
    /// they move it more than gravity would have (a box floating at rest stays asleep), then they are cleared.
    func applyFluidImpulses() {
        guard fluid != nil else { return }
        let group = PhysicsWorld.stepLength / Float(fluidGroups)
        // The bodies dropped this group (the first liquid's clock: its groups run, this one's included).
        let tick = (fluid!.systems.first?.clock ?? 1) &- 1
        for d in fluid!.drops where d.y == tick {
            bodies[Int(d.x)].info.y &= ~PhysicsWorld.asleep
            bodies[Int(d.x)].prevPosition.w = 0
        }
        for i in bodies.indices {
            let jl = fluid!.impulses[2 * i], ja = fluid!.impulses[2 * i + 1]
            fluid!.impulses[2 * i] = .zero
            fluid!.impulses[2 * i + 1] = .zero
            var b = bodies[i]
            guard b.position.w > 0, b.info.y & PhysicsWorld.kinematicBit == 0, jl != .zero || ja != .zero else { continue }
            // A held body waits for its drop, whatever splashes it.
            if fluid!.drops.contains(where: { $0.x == UInt32(i) && $0.y > tick }) { continue }
            let j = SIMD3<Float>(Float(jl.x), Float(jl.y), Float(jl.z)) / FluidWorld.impulseScale
            let l = SIMD3<Float>(Float(ja.x), Float(ja.y), Float(ja.z)) / FluidWorld.impulseScale
            var dv = j * b.position.w
            let speed = length(dv)
            if speed > FluidWorld.kickCap { dv *= FluidWorld.kickCap / speed }
            let dw = PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), l)
            if b.info.y & PhysicsWorld.asleep != 0 {
                guard length(dv + gravity * group) > FluidWorld.wakeKick else { continue }
                b.info.y &= ~PhysicsWorld.asleep
                b.prevPosition.w = 0
            }
            b.velocity = SIMD4(PhysicsMath.xyz(b.velocity) + dv, b.velocity.w)
            b.angular = SIMD4(PhysicsMath.xyz(b.angular) + dw, b.angular.w)
            bodies[i] = b
        }
    }

    // MARK: PBF

    /// Particle `x`'s grid cell (MSL fluidCell), its coordinates held to the grid.
    @inline(__always) static func fluidCell(_ x: SIMD3<Float>, _ p: GPUFluidParams) -> SIMD3<Int32> {
        let c = SIMD3<Int32>(((x - PhysicsMath.xyz(p.lo)) * p.hi.w).rounded(.down))
        return simd_clamp(c, .zero, SIMD3<Int32>(Int32(p.dims.x) - 1, Int32(p.dims.y) - 1, Int32(p.dims.z) - 1))
    }
    @inline(__always) static func fluidCellIndex(_ c: SIMD3<Int32>, _ p: GPUFluidParams) -> Int {
        Int(c.x) + Int(p.dims.x) * (Int(c.y) + Int(p.dims.y) * Int(c.z))
    }

    /// A cell's particles a neighbour search reads at most (MSL FLUID_CELL_MOST): a cell at rest holds about 8.
    static let fluidCellMost: UInt32 = 96
    /// A particle's neighbours at most (MSL FLUID_NEIGHBOURS_MOST), and how far they are looked for, in h (FLUID_REACH):
    /// about 45 at rest.
    static let fluidNeighboursMost = 64
    static let fluidReach: Float = 1.1

    /// The neighbours of a particle in cell `c`, in the order the GPU visits them: the 27 cells about it (z, then y,
    /// then x), each cell's particles in order.
    @inline(__always) private static func forNeighbours(_ c: SIMD3<Int32>, _ p: GPUFluidParams, _ starts: [UInt32], _ body: (Int) -> Void) {
        for dz: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dx: Int32 in -1...1 {
                    let n = c &+ SIMD3(dx, dy, dz)
                    guard all(n .>= .zero), n.x < Int32(p.dims.x), n.y < Int32(p.dims.y), n.z < Int32(p.dims.z) else { continue }
                    let k = fluidCellIndex(n, p)
                    for j in Int(starts[k])..<Int(min(starts[k + 1], starts[k] + fluidCellMost)) { body(j) }
                }
            }
        }
    }

    private func pbfSubstep(_ system: inout FluidSystem, bodies near: [UInt32]) {
        let p = system.params, n = system.particles.count
        guard n > 0 else { return }
        let dt = p.gravity.w, h = p.pbf.x, r = p.extra.x, rho0 = p.material.x, volume = 1 / rho0
        let lo = PhysicsMath.xyz(p.lo) + r, hi = PhysicsMath.xyz(p.hi) - r
        let colliders = fluidColliders(system, bodies: near)
        // Predict (fluidPredictKernel).
        var predicted = system.particles.map { q -> SIMD3<Float> in
            var v = PhysicsMath.xyz(q.velocity) + PhysicsMath.xyz(p.gravity) * dt
            let speed = length(v)
            if speed > p.fixed.w { v *= p.fixed.w / speed }
            return simd_clamp(PhysicsMath.xyz(q.position) + v * dt, lo, hi)
        }
        // Sort by cell: a counting sort, each cell's particles in the order they had (fluidCellCount ... fluidReorder).
        let cellCount = Int(p.dims.w)
        let keys = predicted.map { PhysicsWorld.fluidCellIndex(PhysicsWorld.fluidCell($0, p), p) }
        var starts = [UInt32](repeating: 0, count: cellCount + 1)
        for k in keys { starts[k + 1] += 1 }
        for c in 0..<cellCount { starts[c + 1] += starts[c] }
        var cursor = starts
        var order = [Int](repeating: 0, count: n)
        for (i, k) in keys.enumerated() { order[Int(cursor[k])] = i; cursor[k] += 1 }
        var particles = order.map { system.particles[$0] }
        predicted = order.map { predicted[$0] }
        // Each particle's neighbours as sorted, for the rest of the substep (fluidPbfNeighboursKernel).
        let cells = predicted.map { PhysicsWorld.fluidCell($0, p) }
        let reach = PhysicsWorld.fluidReach * h
        let neighbours = (0..<n).map { i -> [Int] in
            var list: [Int] = []
            PhysicsWorld.forNeighbours(cells[i], p, starts) { j in
                if list.count < PhysicsWorld.fluidNeighboursMost && length_squared(predicted[i] - predicted[j]) < reach * reach { list.append(j) }
            }
            return list
        }
        let start = particles.map { PhysicsMath.xyz($0.position) }
        // The constraints, `emission.w` Jacobi iterations (fluidPbfLambdaKernel, fluidPbfDeltaKernel).
        var lambdas = [Float](repeating: 0, count: n)
        for _ in 0..<Int(p.emission.w) {
            for i in 0..<n {
                let x = predicted[i]
                var density: Float = 0, own = SIMD3<Float>(), squares: Float = 0
                for j in neighbours[i] {
                    let d = x - predicted[j]
                    density += PBF.poly6(length_squared(d), h: h)
                    guard j != i else { continue }
                    let g = PBF.spiky(d, h: h) * volume
                    own += g
                    squares += length_squared(g)
                }
                // The walls' and colliders' boundary density, and its gradient.
                pbfBoundary(x, p, colliders: colliders) { _, share, slope in
                    density += share * rho0
                    own += slope
                }
                let c = max(density / rho0 - 1, -p.material.z)
                lambdas[i] = -c / (squares + length_squared(own) + p.pbf.y)
            }
            var next = predicted
            for i in 0..<n {
                let x = predicted[i]
                var delta = SIMD3<Float>()
                for j in neighbours[i] {
                    guard j != i else { continue }
                    let d = x - predicted[j], r2 = length_squared(d)
                    guard r2 < h * h else { continue }
                    let w = PBF.poly6(r2, h: h) * p.pbf.w
                    let corr = -p.pbf.z * (w * w) * (w * w)
                    delta += PBF.spiky(d, h: h) * ((lambdas[i] + lambdas[j] + corr) * volume)
                }
                // Off the walls and colliders as the boundary density pushes (and a body pushed back as much).
                pbfBoundary(x, p, colliders: colliders) { code, _, slope in
                    let push = slope * lambdas[i]
                    delta += push
                    if let code { fluidImpulse(code, -push * (p.material.y / dt), at: x) }
                }
                let y = simd_clamp(x + delta, lo, hi)
                next[i] = simd_clamp(fluidPushOut(y, start: start[i], r: r, h: dt, friction: p.pbf2.z, mass: p.material.y,
                                                  colliders: colliders), lo, hi)
            }
            predicted = next
        }
        // Velocities from how far they went, then vorticity, XSPH and confinement (fluidPbfVelocity ... Viscosity).
        for i in 0..<n {
            particles[i].velocity = SIMD4((predicted[i] - start[i]) / dt, 0)
            particles[i].position = SIMD4(predicted[i], 1)
        }
        var vorticity = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            let x = predicted[i], v = PhysicsMath.xyz(particles[i].velocity)
            var w = SIMD3<Float>()
            for j in neighbours[i] {
                guard j != i else { continue }
                w += cross(PBF.spiky(x - predicted[j], h: h), PhysicsMath.xyz(particles[j].velocity) - v) * volume
            }
            vorticity[i] = w
        }
        var out = particles
        for i in 0..<n {
            let x = predicted[i], v = PhysicsMath.xyz(particles[i].velocity), w = vorticity[i], wl = length(w)
            var smooth = SIMD3<Float>(), eta = SIMD3<Float>()
            for j in neighbours[i] {
                guard j != i else { continue }
                let d = x - predicted[j]
                smooth += (PhysicsMath.xyz(particles[j].velocity) - v) * (PBF.poly6(length_squared(d), h: h) * volume)
                eta += PBF.spiky(d, h: h) * ((length(vorticity[j]) - wl) * volume)
            }
            var u = v + smooth * p.pbf2.x
            let el = length(eta)
            if el > 1e-6 && wl > 1e-6 { u += cross(eta / el, w) * (p.pbf2.y * dt) }
            out[i].velocity = SIMD4(u, 0)
            out[i].affine0 = SIMD4(w, 0)
        }
        system.particles = out
    }

    /// Each wall of the domain and collider within h of a particle at `x` (MSL fluidPbfBoundary): the collider (nil:
    /// a wall), its boundary density's share of the rest density (PBF.wall) and its gradient.
    private func pbfBoundary(_ x: SIMD3<Float>, _ p: GPUFluidParams, colliders: [UInt32],
                             _ body: (UInt32?, Float, SIMD3<Float>) -> Void) {
        let h = p.pbf.x, lo = PhysicsMath.xyz(p.lo), hi = PhysicsMath.xyz(p.hi)
        for a in 0..<3 {
            for (d, sign) in [(x[a] - lo[a], Float(1)), (hi[a] - x[a], Float(-1))] where d < h {
                let w = PBF.wall(d, h: h)
                var n = SIMD3<Float>()
                n[a] = sign
                body(nil, w.share, n * w.slope)
            }
        }
        for code in colliders where fluidNear(code, x, h) {
            let b = fluidCollider(code), pose = Pose(b), shape = Int(b.info.x)
            let local = pose.toBody(x)
            let d = distance(shape: shape, local)
            guard d < h else { continue }
            let w = PBF.wall(d, h: h)
            body(code, w.share, pose.direction(gradient(shape: shape, local)) * w.slope)
        }
    }

    // MARK: MPM

    /// The quadratic B-spline's weights about grid point `xg` (in cells): the first node's coordinates and, per axis,
    /// the three weights (MSL fluidSpline).
    @inline(__always) static func spline(_ xg: SIMD3<Float>) -> (base: SIMD3<Int32>, fx: SIMD3<Float>, w: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) {
        let base = SIMD3<Int32>((simd_clamp(xg, SIMD3(repeating: 1), SIMD3(repeating: 1e6)) - 0.5).rounded(.down))
        let fx = xg - SIMD3<Float>(base)
        let a = 1.5 - fx, b = fx - 1, c = fx - 0.5
        return (base, fx, (0.5 * a * a, 0.75 - b * b, 0.5 * c * c))
    }

    @inline(__always) private static func pick(_ w: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), _ k: Int) -> SIMD3<Float> {
        k == 0 ? w.0 : k == 1 ? w.1 : w.2
    }

    /// The node index of grid node `n`.
    @inline(__always) static func mpmNode(_ n: SIMD3<Int32>, _ p: GPUFluidParams) -> Int {
        let c = simd_clamp(n, .zero, SIMD3<Int32>(Int32(p.dims.x) - 1, Int32(p.dims.y) - 1, Int32(p.dims.z) - 1))
        return Int(c.x) + Int(p.dims.x) * (Int(c.y) + Int(p.dims.y) * Int(c.z))
    }

    private func mpmSubstep(_ system: inout FluidSystem, bodies near: [UInt32]) {
        let p = system.params, n = system.particles.count
        guard n > 0 else { return }
        let dt = p.gravity.w, dx = p.lo.w, inv = p.hi.w, lo = PhysicsMath.xyz(p.lo)
        let colliders = fluidColliders(system, bodies: near)
        var grid = [SIMD4<Int32>](repeating: .zero, count: Int(p.dims.w))
        // Particles to grid (fluidMpmP2GKernel).
        for q in system.particles {
            let x = PhysicsMath.xyz(q.position), (base, fx, w) = PhysicsWorld.spline((x - lo) * inv)
            let a = PhysicsWorld.mpmAffine(q, p)
            let v = PhysicsMath.xyz(q.velocity)
            for k in 0..<27 {
                let o = SIMD3<Int32>(Int32(k % 3), Int32(k / 3 % 3), Int32(k / 9))
                let weight = PhysicsWorld.pick(w, Int(o.x)).x * PhysicsWorld.pick(w, Int(o.y)).y * PhysicsWorld.pick(w, Int(o.z)).z
                let dpos = (SIMD3<Float>(o) - fx) * dx
                let momentum = (v + SIMD3(dot(a.0, dpos), dot(a.1, dpos), dot(a.2, dpos))) * weight
                let node = PhysicsWorld.mpmNode(base &+ o, p)
                grid[node] &+= SIMD4(PhysicsWorld.fixed(momentum, p.fixed.y), PhysicsWorld.fixed(weight, p.fixed.x))
            }
        }
        // The grid's velocities, gravity, walls and colliders (fluidMpmGridKernel).
        var velocity = [SIMD4<Float>](repeating: .zero, count: grid.count)
        for z in 0..<Int32(p.dims.z) {
            for y in 0..<Int32(p.dims.y) {
                for x in 0..<Int32(p.dims.x) {
                    let node = SIMD3(x, y, z), k = PhysicsWorld.mpmNode(node, p)
                    velocity[k] = mpmNodeVelocity(grid[k], node, p, colliders: colliders)
                }
            }
        }
        // Grid to particles (fluidMpmG2PKernel).
        let top = PhysicsMath.xyz(p.hi) - 2 * dx, bottom = lo + 2 * dx
        for i in 0..<n {
            var q = system.particles[i]
            let x = PhysicsMath.xyz(q.position), (base, fx, w) = PhysicsWorld.spline((x - lo) * inv)
            var v = SIMD3<Float>(), b0 = SIMD3<Float>(), b1 = SIMD3<Float>(), b2 = SIMD3<Float>(), density: Float = 0
            for k in 0..<27 {
                let o = SIMD3<Int32>(Int32(k % 3), Int32(k / 3 % 3), Int32(k / 9))
                let weight = PhysicsWorld.pick(w, Int(o.x)).x * PhysicsWorld.pick(w, Int(o.y)).y * PhysicsWorld.pick(w, Int(o.z)).z
                let dpos = (SIMD3<Float>(o) - fx) * dx
                let node = velocity[PhysicsWorld.mpmNode(base &+ o, p)]
                let vi = PhysicsMath.xyz(node) * weight
                density += node.w * weight
                v += vi
                b0 += vi.x * dpos
                b1 += vi.y * dpos
                b2 += vi.z * dpos
            }
            let s = 4 * inv * inv
            let c0 = b0 * s, c1 = b1 * s, c2 = b2 * s
            // J from how many particles the grid sees about it, against the rest's (MSL fluidMpmG2PKernel): carried
            // along by the velocity's divergence, it missed what a pool one or two cells deep does (a pour sank into
            // a layer four times as dense as water, its J still 1.07), and it drifts.
            let j = min(max(dx * dx * dx / p.extra.z / max(density, 1e-6), 0.5), 1.5)
            let speed = length(v)
            if speed > p.fixed.w { v *= p.fixed.w / speed }
            var y = x + v * dt
            (y, v) = mpmPushOut(y, v, p, colliders: colliders)
            (y, v) = PhysicsWorld.mpmHold(y, v, bottom, top, p)
            q.position = SIMD4(y, j)
            q.velocity = SIMD4(v, 0)
            q.affine0 = SIMD4(c0, 0)
            q.affine1 = SIMD4(c1, 0)
            q.affine2 = SIMD4(c2, 0)
            system.particles[i] = q
        }
    }

    /// A particle at `x` going at `v` pushed out of the colliders it is inside (MSL fluidMpmPushOut), and its velocity
    /// with them as a node's is (mpmContact): moved out but still going in, gravity would add to its speed every substep
    /// (a pool on a step slid at the top speed and never left it).
    private func mpmPushOut(_ x: SIMD3<Float>, _ v: SIMD3<Float>, _ p: GPUFluidParams, colliders: [UInt32]) -> (SIMD3<Float>, SIMD3<Float>) {
        var y = x, u = v
        let r = p.extra.x
        for code in colliders where fluidNear(code, y, r) {
            let b = fluidCollider(code), pose = Pose(b), shape = Int(b.info.x)
            let local = pose.toBody(y)
            let depth = distance(shape: shape, local) - r
            guard depth < 0 else { continue }
            let n = pose.direction(gradient(shape: shape, local))
            let surface = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), y - pose.position)
            y += n * -depth
            u = PhysicsWorld.mpmContact(u, n, surface, p.pbf2.z, p.pbf2.w)
        }
        return (y, u)
    }

    /// A particle at `x` going at `v` held inside the walls (MSL fluidMpmHold), its velocity into a wall it is held
    /// at as a node's (mpmContact): held there by its position alone, a pour sank onto the floor at gravity's pace
    /// and packed into a layer four times as dense, which J never saw.
    @inline(__always) static func mpmHold(_ x: SIMD3<Float>, _ v: SIMD3<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>,
                                          _ p: GPUFluidParams) -> (SIMD3<Float>, SIMD3<Float>) {
        var u = v
        for a in 0..<3 {
            var n = SIMD3<Float>()
            if x[a] < lo[a] { n[a] = 1 } else if x[a] > hi[a] { n[a] = -1 } else { continue }
            u = mpmContact(u, n, .zero, p.pbf2.z, p.pbf2.w)
        }
        return (simd_clamp(x, lo, hi), u)
    }

    /// A particle's affine momentum per unit mass (MSL fluidMpmAffine): the stress's push over the substep (Tait's
    /// pressure from how its volume has changed, the viscous stress from its velocity's gradient) plus APIC's C.
    static func mpmAffine(_ q: GPUFluidParticle, _ p: GPUFluidParams) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let j = q.position.w, k = p.material.z, gamma = p.material.w
        let pressure = max(k / gamma * (pow(j, -gamma) - 1), -p.pbf.x * k)
        let c0 = PhysicsMath.xyz(q.affine0), c1 = PhysicsMath.xyz(q.affine1), c2 = PhysicsMath.xyz(q.affine2)
        // D = sym(C), and its deviatoric part.
        let third = (c0.x + c1.y + c2.z) / 3
        let d0 = SIMD3(c0.x - third, 0.5 * (c0.y + c1.x), 0.5 * (c0.z + c2.x))
        let d1 = SIMD3(d0.y, c1.y - third, 0.5 * (c1.z + c2.y))
        let d2 = SIMD3(d0.z, d1.z, c2.z - third)
        let shear = (2 * (dot(d0, d0) + dot(d1, d1) + dot(d2, d2))).squareRoot()
        let mu = LiquidKind.viscosity(p.viscosity, shear: shear)
        // -dt (J / rho) 4/dx^2 sigma, sigma = -pressure I + 2 mu D' + zeta tr(D) I (an artificial bulk viscosity, pbf.y:
        // what damps the particles' jitter about their rest density).
        let s = -p.gravity.w * (j / p.material.x) * 4 * p.hi.w * p.hi.w
        let q = pressure - p.pbf.y * 3 * third
        return (c0 + (d0 * (2 * mu) - SIMD3(q, 0, 0)) * s,
                c1 + (d1 * (2 * mu) - SIMD3(0, q, 0)) * s,
                c2 + (d2 * (2 * mu) - SIMD3(0, 0, q)) * s)
    }

    /// Grid node `node`'s velocity from what the particles gave it, with gravity, the walls and the colliders (and their
    /// impulses on the bodies); w = its weight (MSL fluidMpmGridKernel).
    private func mpmNodeVelocity(_ g: SIMD4<Int32>, _ node: SIMD3<Int32>, _ p: GPUFluidParams, colliders: [UInt32]) -> SIMD4<Float> {
        // An empty node is read by no particle (each reads the nodes it gave mass to), so it stays empty: most of the
        // grid, which skips the colliders.
        guard g.w > 0 else { return .zero }
        // A node past a wall or inside a collider weighs a rest cell's particles in the density J is taken from (as SPH's
        // boundary particles do): a particle at the floor saw half the grid empty and took itself for half as dense.
        let solid = mpmSolid(node, p, colliders: colliders)
        let rest = p.lo.w * p.lo.w * p.lo.w / p.extra.z
        let m = Float(g.w) / p.fixed.x
        var v = SIMD3<Float>(Float(g.x), Float(g.y), Float(g.z)) / p.fixed.y / m + PhysicsMath.xyz(p.gravity) * p.gravity.w
        let friction = p.pbf2.z, stick = p.pbf2.w
        // The domain's walls: the three nodes at each end (as Taichi's mpm88 holds), past the walls.
        for a in 0..<3 {
            let last = Int32(a == 0 ? p.dims.x : a == 1 ? p.dims.y : p.dims.z) - 4
            if node[a] < 3 && v[a] < 0 {
                var n = SIMD3<Float>(); n[a] = 1
                v = PhysicsWorld.mpmContact(v, n, .zero, friction, stick)
            } else if node[a] > last && v[a] > 0 {
                var n = SIMD3<Float>(); n[a] = -1
                v = PhysicsWorld.mpmContact(v, n, .zero, friction, stick)
            }
        }
        let x = PhysicsMath.xyz(p.lo) + SIMD3<Float>(node) * p.lo.w
        // The colliders, the same: a node inside one or within half a cell of it.
        let band = 0.5 * p.lo.w
        for code in colliders where fluidNear(code, x, band) {
            let b = fluidCollider(code), pose = Pose(b), shape = Int(b.info.x)
            let local = pose.toBody(x)
            guard distance(shape: shape, local) < band else { continue }
            let n = pose.direction(gradient(shape: shape, local))
            let surface = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), x - pose.position)
            let before = v
            v = PhysicsWorld.mpmContact(v, n, surface, friction, stick)
            fluidImpulse(code, (before - v) * (m * p.material.y), at: x)
        }
        let speed = length(v)
        if speed > p.fixed.w { v *= p.fixed.w / speed }
        return SIMD4(v, solid ? max(m, rest) : m)
    }

    /// Whether grid node `node` is past the domain's walls or inside a collider (MSL fluidMpmSolid). A body's too:
    /// the liquid pressed against it is then as dense as it is, and the push the contact takes off it goes to the body
    /// (without, a light box dropped into honey sank slowly through it).
    private func mpmSolid(_ node: SIMD3<Int32>, _ p: GPUFluidParams, colliders: [UInt32]) -> Bool {
        let dims = SIMD3<Int32>(Int32(p.dims.x), Int32(p.dims.y), Int32(p.dims.z))
        if any(node .< 2) || any(node .> dims &- 3) { return true }
        let x = PhysicsMath.xyz(p.lo) + SIMD3<Float>(node) * p.lo.w
        for code in colliders where fluidNear(code, x, 0) {
            let b = fluidCollider(code)
            if distance(shape: Int(b.info.x), Pose(b).toBody(x)) < 0 { return true }
        }
        return false
    }

    /// A node's velocity against a surface of normal `n` moving at `surface` (MSL fluidContact): going into it, it loses
    /// its normal part and slides with `friction` (Coulomb), less `stick` of the slide.
    @inline(__always) static func mpmContact(_ v: SIMD3<Float>, _ n: SIMD3<Float>, _ surface: SIMD3<Float>, _ friction: Float,
                                             _ stick: Float) -> SIMD3<Float> {
        let rel = v - surface, vn = dot(rel, n)
        guard vn < 0 else { return v }
        var t = rel - n * vn
        let l = length(t)
        t *= l > 1e-9 ? max(1 + friction * vn / l, 0) * (1 - stick) : 0
        return t + surface
    }
}
