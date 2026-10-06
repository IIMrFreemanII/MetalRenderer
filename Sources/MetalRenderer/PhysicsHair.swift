import Foundation
import simd

/// Hair and fur: guide strands, each a chain of vertices whose root a body holds (or the world), simulated after the
/// bodies' substeps (the strands never push a body back, as the particles don't), and strands drawn around each guide
/// as curves (Scene.addCurves; Physics.metal's physicsHairCurvesKernel).
///
/// A step's substeps, per strand, root to tip (TressFX; Müller et al. 2012's follow-the-leader):
/// - the root follows its body, its pose between where the step started and where it ended;
/// - the other vertices move by their velocity, which the air pulls toward the breeze (gravity too);
/// - global shape: each is pulled a share of the way back to where it rests on its body (stiff at the root, less so
///   toward the tip: fur keeps its shape, long hair little of it);
/// - local shape: each segment is turned about its middle toward its rest direction as the segment before it has
///   turned (carried along, so curls stay curls as hair hangs);
/// - length: each vertex is kept at its length from the one before (inextensible), and pushed out of the bodies and
///   static colliders near the strand (with friction);
/// - velocities from how far they went, less a share (`damping`, 0.5) of how far the next vertex was moved after it
///   to keep its length (DFTL's correction: without it the shortcut adds energy, and a loose strand never settles;
///   at Müller's 0.9 a tilted fur strand held by both shapes kept a zigzag at half a metre a second).
/// A strand is one thread's on the GPU, its vertices one after another: no colouring, and the same numbers every run.
/// Strands on a sleeping body stop once they have come to rest.
extension PhysicsWorld {
    static let maxHairVertices = 16
    static let maxHairColliders = 8
    /// How fast the air takes a strand's velocity to the breeze's (1/s).
    static let hairDrag: Float = 2
    /// A strand on a sleeping body stops once no vertex went further than this over a step, a second's worth (m/s):
    /// what it moved, not its velocities, which one pressed against what it lies on keeps wobbling.
    static let hairRest: Float = 0.02
    /// The most a collider pushes a vertex in a substep (m).
    static let hairPush: Float = 0.01
    /// Strands reach this far beyond their length in a step (m): which colliders they may meet.
    static let hairReach: Float = 0.15

    /// A guide strand through `points` (world, where its body is now; the first is its root), which `body` holds (nil:
    /// the world). `radius`: how thick it is to the colliders. Its stiffness: the global shape's at the root and at the
    /// tip, and the local shape's, each as how fast it springs back (rad/s): a substep pulls (omega h)^2 of the way
    /// back, so gravity bends it g / omega^2 (fur at 60 rad/s: 3 mm; long hair at 4: as far as it can) whatever the
    /// substeps. (A share of the way a substep, as TressFX has it, would make 1% hold against gravity to a millimetre
    /// at 16 substeps.) `across`: a direction across it at the root (the drawn strands' frame). Returns its index.
    @discardableResult
    func addStrand(body: Int?, points: [SIMD3<Float>], radius: Float, globalRoot: Float, globalTip: Float, local: Float,
                   damping: Float = 0.5, friction: Float = 0.3, across: SIMD3<Float>) -> Int {
        precondition(points.count >= 2 && points.count <= PhysicsWorld.maxHairVertices, "2 to \(PhysicsWorld.maxHairVertices) vertices")
        let pose = body.map { Pose(bodies[$0]) }
        let h = PhysicsWorld.stepLength / Float(substeps)
        func share(_ omega: Float) -> Float { min(omega * h * omega * h, 1) }
        func rest(_ p: SIMD3<Float>) -> SIMD3<Float> { pose?.toBody(p) ?? p }
        let first = hairVertices.count
        var length: Float = 0
        for (i, p) in points.enumerated() {
            let segment = i == 0 ? 0 : simd.length(p - points[i - 1])
            length += segment
            let f = Float(i) / Float(points.count - 1)
            let global = i == 0 ? 1 : share(globalRoot + (globalTip - globalRoot) * f)
            hairVertices.append(GPUHairVertex(position: SIMD4(p, radius), previous: SIMD4(p, segment), velocity: SIMD4(.zero, friction),
                                              rest: SIMD4(rest(p), global)))
        }
        let a = pose.map { PhysicsMath.qrot(PhysicsMath.qconj($0.rotation), across) } ?? across
        hairStrands.append(GPUHairStrand(info: SIMD4(body.map { UInt32($0) } ?? PhysicsWorld.none, UInt32(first), UInt32(points.count), 0),
                                         stiffness: SIMD4(share(globalRoot), share(globalTip), share(local), damping), across: SIMD4(a, length)))
        return hairStrands.count - 1
    }

    /// Strands drawn around guides `guides` (`perGuide` each, the guide one of them), up to `spread` from it at the root
    /// and drawn `clump` of the way in toward it by the tip, curling `curl` about it. `mesh`: its curve mesh, whose first
    /// control point and last frame's offset Scene.setHairMeshes fills in once the meshes are done.
    func addHairGroup(guides: Range<Int>, perGuide: Int, spread: Float, clump: Float, curl: Float, seed: UInt32) -> Int {
        let n = hairStrands[guides.lowerBound].info.z
        precondition(guides.allSatisfy { hairStrands[$0].info.z == n }, "a group's guides have as many vertices")
        hairGroups.append(GPUHairGroup(counts: SIMD4(UInt32(guides.lowerBound), UInt32(guides.count), UInt32(perGuide), n),
                                       mesh: SIMD4(0, 0, seed, 0), shape: SIMD4(spread, clump, curl, 0)))
        return hairGroups.count - 1
    }

    var hairParams: GPUHairParams {
        GPUHairParams(gravity: SIMD4(gravity, PhysicsWorld.stepLength / Float(substeps)), wind: wind,
                      counts: SIMD4(UInt32(hairStrands.count), UInt32(bodies.count), UInt32(statics.count), UInt32(substeps)),
                      air: SIMD4(PhysicsWorld.hairDrag, PhysicsWorld.hairRest, time, 0))
    }

    // MARK: - Shared with Physics.metal

    /// The breeze at `x` at time `t` (s): `wind`'s velocity, gusting by `wind.w` in time and along the way it blows.
    @inline(__always) static func breeze(_ wind: SIMD4<Float>, _ x: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let w = PhysicsMath.xyz(wind)
        let along = dot(x, SIMD3(0.7, 0.2, 0.5))
        let gust = 1 + wind.w * (0.6 * sin(1.1 * t - 1.7 * along) + 0.4 * sin(2.9 * t + 2.3 * x.y))
        return w * gust
    }

    /// `v` turned by the least rotation that takes unit `a` to unit `b`.
    @inline(__always) static func transport(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let c = dot(a, b)
        guard c > -0.999 else { return v }
        let k = cross(a, b)
        return v * c + cross(k, v) + k * (dot(k, v) / (1 + c))
    }

    /// A body's pose `alpha` of the way from (`p0`, `q0`) to (`p1`, `q1`): the position lerped, the rotation nlerped.
    @inline(__always) static func between(_ p0: SIMD3<Float>, _ q0: SIMD4<Float>, _ p1: SIMD3<Float>, _ q1: SIMD4<Float>,
                                          _ alpha: Float) -> Pose {
        let q = dot(q0, q1) < 0 ? -q1 : q1
        var pose = Pose(GPUPhysicsBody())
        pose.position = p0 + (p1 - p0) * alpha
        pose.rotation = PhysicsMath.qnormalize(q0 + (q - q0) * alpha)
        return pose
    }

    /// Whether a body's or a static's sphere reaches a strand rooted at `centre` and `reach` long.
    func hairColliders(centre: SIMD3<Float>, reach: Float, _ p: GPUPhysicsParams) -> [UInt32] {
        var found: [UInt32] = []
        for s in statics.indices where found.count < PhysicsWorld.maxHairColliders && touchesStatic(s, centre: centre, radius: reach) {
            found.append(UInt32(s) | PhysicsWorld.staticBit)
        }
        for (j, b) in bodies.enumerated() where found.count < PhysicsWorld.maxHairColliders {
            let r = reach + PhysicsWorld.reach(b, p)
            if length_squared(PhysicsMath.xyz(b.position) - centre) < r * r { found.append(UInt32(j)) }
        }
        return found
    }

    // MARK: - Stepping (the CPU's)

    /// A step of every strand, after the bodies' (`start`: their poses when it began).
    func stepHair(_ start: [SIMD8<Float>]) {
        guard !hairStrands.isEmpty else { return }
        let p = params, hp = hairParams
        let strands = hairStrands
        var still = [UInt32](repeating: 0, count: strands.count)
        hairVertices.withUnsafeMutableBufferPointer { vertices in
            still.withUnsafeMutableBufferPointer { flags in
                let chunk = 64
                DispatchQueue.concurrentPerform(iterations: (strands.count + chunk - 1) / chunk) { c in
                    for s in (c * chunk)..<min((c + 1) * chunk, strands.count) {
                        flags[s] = stepStrand(strands[s], vertices.baseAddress!, start, p, hp)
                    }
                }
            }
        }
        for s in hairStrands.indices { hairStrands[s].info.w = still[s] }
    }

    /// One strand's step; returns 1 if it lies still on a sleeping body (it then stops), else 0.
    private func stepStrand(_ strand: GPUHairStrand, _ v: UnsafeMutablePointer<GPUHairVertex>, _ start: [SIMD8<Float>],
                            _ p: GPUPhysicsParams, _ hp: GPUHairParams) -> UInt32 {
        let first = Int(strand.info.y), n = Int(strand.info.z)
        let body = strand.info.x == PhysicsWorld.none ? nil : Int(strand.info.x)
        let asleep = body.map { bodies[$0].info.y & PhysicsWorld.asleep != 0 } ?? false
        if asleep && strand.info.w != 0 { return 1 }
        var p0 = SIMD3<Float>(), q0 = SIMD4<Float>(0, 0, 0, 1), p1 = p0, q1 = q0
        if let body {
            p0 = SIMD3(start[body][0], start[body][1], start[body][2])
            q0 = SIMD4(start[body][4], start[body][5], start[body][6], start[body][7])
            p1 = PhysicsMath.xyz(bodies[body].position)
            q1 = bodies[body].rotation
        }
        let colliders = hairColliders(centre: Pose(GPUPhysicsBody(position: SIMD4(p1, 0), rotation: q1)).toWorld(PhysicsMath.xyz(v[first].rest)),
                                      reach: strand.across.w + PhysicsWorld.hairReach, p)
        let h = hp.gravity.w, subs = Int(hp.counts.w)
        let before = (first..<(first + n)).map { PhysicsMath.xyz(v[$0].position) }
        let gravity = PhysicsMath.xyz(hp.gravity)
        var corrections = [SIMD3<Float>](repeating: .zero, count: PhysicsWorld.maxHairVertices + 1)
        for sub in 0..<subs {
            let pose = PhysicsWorld.between(p0, q0, p1, q1, Float(sub + 1) / Float(subs))
            let t = hp.air.z + h * Float(sub + 1)
            // The root, where the body holds it.
            let root = pose.toWorld(PhysicsMath.xyz(v[first].rest))
            v[first].previous = SIMD4(PhysicsMath.xyz(v[first].position), v[first].previous.w)
            v[first].position = SIMD4(root, v[first].position.w)
            // Moved by their velocities, the air taking them toward the breeze; then pulled toward their rest.
            let air = min(hp.air.x * h, 1)
            for i in (first + 1)..<(first + n) {
                let x = PhysicsMath.xyz(v[i].position)
                var vel = PhysicsMath.xyz(v[i].velocity)
                vel += (PhysicsWorld.breeze(hp.wind, x, t) - vel) * air + gravity * h
                v[i].previous = SIMD4(x, v[i].previous.w)
                var y = x + vel * h
                y += (pose.toWorld(PhysicsMath.xyz(v[i].rest)) - y) * v[i].rest.w
                v[i].position = SIMD4(y, v[i].position.w)
            }
            // Local shape, root to tip: each segment turned about its middle toward its rest direction as the
            // segment before it carries it (the first: toward its rest on the body, the root end held), both ends
            // moved alike, as TressFX does. (Turning only the far end made a stiff strand flutter.)
            var restBefore = SIMD3<Float>()
            for i in (first + 1)..<(first + n) {
                let a = PhysicsMath.xyz(v[i - 1].position), x = PhysicsMath.xyz(v[i].position)
                let restDir = PhysicsMath.direction(pose.direction(PhysicsMath.xyz(v[i].rest) - PhysicsMath.xyz(v[i - 1].rest)))
                let want = i == first + 1 ? restDir
                    : PhysicsWorld.transport(restBefore, PhysicsMath.direction(a - PhysicsMath.xyz(v[i - 2].position)), restDir)
                let d = (want * length(x - a) - (x - a)) * strand.stiffness.z
                if i == first + 1 {
                    v[i].position = SIMD4(x + d, v[i].position.w)
                } else {
                    v[i].position = SIMD4(x + 0.5 * d, v[i].position.w)
                    v[i - 1].position = SIMD4(a - 0.5 * d, v[i - 1].position.w)
                }
                restBefore = restDir
            }
            // Root to tip: at its length from the vertex before (follow the leader), out of the colliders.
            for i in (first + 1)..<(first + n) {
                let a = PhysicsMath.xyz(v[i - 1].position), x = PhysicsMath.xyz(v[i].position)
                let led = a + PhysicsMath.direction(x - a) * v[i].previous.w
                corrections[i - first] = led - x   // DFTL's d: the follow-the-leader move alone
                var y = pushOut(led, v[i], colliders, h)
                y = a + PhysicsMath.direction(y - a) * v[i].previous.w
                v[i].position = SIMD4(y, v[i].position.w)
            }
            corrections[n] = .zero
            // Velocities, less DFTL's share of the next vertex's correction.
            for i in (first + 1)..<(first + n) {
                let moved = PhysicsMath.xyz(v[i].position) - PhysicsMath.xyz(v[i].previous)
                let vel = (moved - strand.stiffness.w * corrections[i - first + 1]) / h
                v[i].velocity = SIMD4(vel, v[i].velocity.w)
            }
            v[first].velocity = SIMD4((root - PhysicsMath.xyz(v[first].previous)) / h, v[first].velocity.w)
        }
        guard asleep else { return 0 }
        for i in 0..<n where length(PhysicsMath.xyz(v[first + i].position) - before[i]) >= hp.air.y * h * Float(subs) { return 0 }
        return 1
    }

    /// `y` pushed out of the colliders it is in, with friction against its slide over them.
    @inline(__always) private func pushOut(_ y: SIMD3<Float>, _ vertex: GPUHairVertex, _ colliders: [UInt32], _ h: Float) -> SIMD3<Float> {
        var y = y
        for code in colliders {
            let b = partner(code), pose = Pose(b), shape = Int(b.info.x)
            let local = pose.toBody(y)
            let depth = distance(shape: shape, local) - vertex.position.w
            guard depth < 0 else { continue }
            let normal = pose.direction(gradient(shape: shape, local))
            let surface = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), y - pose.position)
            y += PhysicsWorld.particlePush(normal, min(-depth, PhysicsWorld.hairPush), y - PhysicsMath.xyz(vertex.previous) - surface * h,
                                           (vertex.velocity.w * b.velocity.w).squareRoot())
        }
        return y
    }

    // MARK: - Drawn strands

    /// Drawn strand `r` of group `g`: its control points (a phantom before the root and after the tip, so the
    /// Catmull-Rom curve runs through every vertex), from the guides' vertices `vertices` and the bodies' poses as
    /// they are. Physics.metal's physicsHairCurvesKernel writes the same every frame.
    func drawnStrand(group g: GPUHairGroup, _ r: Int) -> [SIMD3<Float>] {
        let perGuide = Int(g.counts.z), n = Int(g.counts.w)
        let strand = hairStrands[Int(g.counts.x) + r / perGuide]
        let first = Int(strand.info.y)
        let rotation = strand.info.x == PhysicsWorld.none ? SIMD4<Float>(0, 0, 0, 1) : bodies[Int(strand.info.x)].rotation
        let k = UInt32(r % perGuide)
        let h0 = VoxelLOD.pcgHash(g.mesh.z ^ VoxelLOD.pcgHash(UInt32(r)))
        let h1 = VoxelLOD.pcgHash(h0)
        let radius = k == 0 ? 0 : g.shape.x * Float(h0 & 0xFFFF).squareRoot() / 256
        let angle = Float(h1 & 0xFFFF) * (2 * .pi / 65536)
        let x = (0..<n).map { PhysicsMath.xyz(hairVertices[first + $0].position) }
        var t = PhysicsMath.direction(x[1] - x[0])
        var b1 = PhysicsMath.qrot(rotation, PhysicsMath.xyz(strand.across))
        b1 = PhysicsMath.direction(b1 - t * dot(b1, t))
        var out: [SIMD3<Float>] = []
        for i in 0..<n {
            if i > 0 {
                let next = PhysicsMath.direction(x[min(i + 1, n - 1)] - x[i - (i + 1 < n ? 0 : 1)])
                b1 = PhysicsWorld.transport(t, next, b1)
                t = next
            }
            let b2 = cross(t, b1)
            let f = Float(i) / Float(n - 1)
            let phase = angle + f * 12.566   // two turns, root to tip
            let offset = radius * (1 - g.shape.y * f)
            let curl = g.shape.z * f
            out.append(x[i] + (b1 * cos(angle) + b2 * sin(angle)) * offset + (b1 * cos(phase) + b2 * sin(phase)) * curl)
        }
        return [2 * out[0] - out[1]] + out + [2 * out[n - 1] - out[n - 2]]
    }
}
