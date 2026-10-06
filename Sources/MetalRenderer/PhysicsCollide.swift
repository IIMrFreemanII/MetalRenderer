import Foundation
import simd

/// What a physics shape's distance is (GPUPhysicsShape.info.x): exact formulas for the simple primitives, the SDF
/// shape's field for everything else, and a plane (static colliders only) whose body-space y is the distance.
enum PhysicsShapeKind: UInt32 {
    case sdf = 0, sphere, capsule, box, plane
}

/// The collision code the CPU step runs, written as Shaders/Physics.metal has it (same steps, same order), so that
/// the two backends find the same contacts.
///
/// Every shape is a distance in its body's space plus surface samples: points, each a small sphere (w = its radius,
/// 0 on the surface). A sphere is one sample (its centre, its radius), a capsule a few along its core, a box its corner
/// and edge spheres (its rounding), an SDF shape points of its surface. A pair's contacts are each side's samples
/// against the other's distance (exact for a sphere or a capsule against anything), and for two flat-sided shapes two
/// more points found by descending one's field along the other's surface (edge against edge, face against face): one
/// path for every pair, which the GPU takes without branching on the pair's kinds.
enum PhysicsMath {
    @inline(__always) static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
    @inline(__always) static func qmul(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        let av = xyz(a), bv = xyz(b)
        return SIMD4(a.w * bv + b.w * av + cross(av, bv), a.w * b.w - dot(av, bv))
    }
    @inline(__always) static func qrot(_ q: SIMD4<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let u = xyz(q)
        let t = 2 * cross(u, v)
        return v + q.w * t + cross(u, t)
    }
    @inline(__always) static func qconj(_ q: SIMD4<Float>) -> SIMD4<Float> { SIMD4(-q.x, -q.y, -q.z, q.w) }
    @inline(__always) static func qnormalize(_ q: SIMD4<Float>) -> SIMD4<Float> {
        let l = length(q)
        return l > 0 ? q / l : SIMD4(0, 0, 0, 1)
    }
    /// `q` turned by the small rotation vector `theta` (q + 0.5 (theta, 0) q, renormalised).
    @inline(__always) static func qturn(_ q: SIMD4<Float>, _ theta: SIMD3<Float>) -> SIMD4<Float> {
        qnormalize(q + 0.5 * qmul(SIMD4(theta, 0), q))
    }
    static func quat(_ q: simd_quatf) -> SIMD4<Float> { SIMD4(q.imag, q.real) }
    static func simdQuat(_ q: SIMD4<Float>) -> simd_quatf { simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w) }

    /// The inverse inertia (principal moments `inv`, body -> world `q`) times `v`, in world space.
    @inline(__always) static func applyInvInertia(_ q: SIMD4<Float>, _ inv: SIMD3<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        qrot(q, inv * qrot(qconj(q), v))
    }

    // MARK: Distances

    /// A rounded box's distance (SDF.metal's sdfPrimitive, box).
    @inline(__always) static func box(_ q: SIMD3<Float>, _ b: SIMD3<Float>, _ r: Float) -> Float {
        let e = abs(q) - (b - r)
        return length(simd_max(e, .zero)) + min(max(e.x, max(e.y, e.z)), 0) - r
    }
    @inline(__always) static func capsule(_ q: SIMD3<Float>, _ h: Float, _ r: Float) -> Float {
        length(SIMD3(q.x, q.y - min(max(q.y, -h), h), q.z)) - r
    }
    /// `v` made unit length (up, if it has none).
    @inline(__always) static func direction(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = length(v)
        return l > 1e-12 ? v / l : SIMD3(0, 1, 0)
    }
    /// A rounded box's gradient: outside its inner box, away from the nearest point of it; inside, its nearest face's
    /// normal (the first of equals: x, then y, then z).
    @inline(__always) static func boxGradient(_ q: SIMD3<Float>, _ b: SIMD3<Float>, _ r: Float) -> SIMD3<Float> {
        let e = abs(q) - (b - r)
        let s = SIMD3<Float>(q.x >= 0 ? 1 : -1, q.y >= 0 ? 1 : -1, q.z >= 0 ? 1 : -1)
        if e.x > 0 || e.y > 0 || e.z > 0 { return direction(simd_max(e, .zero) * s) }
        if e.x >= e.y && e.x >= e.z { return SIMD3(s.x, 0, 0) }
        return e.y >= e.z ? SIMD3(0, s.y, 0) : SIMD3(0, 0, s.z)
    }
    /// The four taps of the tetrahedral gradient (as sdfMarch takes its normal).
    static let taps: [SIMD3<Float>] = [SIMD3(1, -1, -1), SIMD3(-1, -1, 1), SIMD3(-1, 1, -1), SIMD3(1, 1, 1)]
    static let gradientStep: Float = 1e-3
}

/// Per pair, from body A's side: A is the pair's owner (the lower body, or the body against a static collider).
struct PhysicsCandidate {
    var pointA: SIMD3<Float>      // A's anchor point, world (a sample's centre: `radiusA` from the surface)
    var pointB: SIMD3<Float>
    var normal: SIMD3<Float>      // out of B
    var separation: Float
    var radiusA: Float
    var radiusB: Float
    /// Where it touches, for choosing the manifold's spread.
    var middle: SIMD3<Float> { (pointA - normal * radiusA + pointB + normal * radiusB) * 0.5 }
}

/// Up to four contacts, kept as Bullet keeps a persistent manifold: the deepest always, the rest to cover the most
/// area. Points are added one at a time (the GPU has no room for a pair's every candidate).
struct PhysicsManifold {
    static let capacity = 4
    var points: [PhysicsCandidate] = []
    /// Every candidate's normal, weighted by how deep it is (margin - separation): what most of them say.
    var normalSum = SIMD3<Float>()

    /// Twice the largest area of a quad of these four points (Bullet's calcArea4Points).
    static func area(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>) -> Float {
        let a = length_squared(cross(p0 - p1, p2 - p3))
        let b = length_squared(cross(p0 - p2, p1 - p3))
        let c = length_squared(cross(p0 - p3, p1 - p2))
        return max(a, max(b, c))
    }

    /// `merge`: closer than this to a point it has, the deeper of the two stays.
    mutating func add(_ c: PhysicsCandidate, merge: Float, margin: Float) {
        normalSum += c.normal * (margin - c.separation)
        for i in points.indices where length_squared(points[i].middle - c.middle) < merge * merge {
            if c.separation < points[i].separation { points[i] = c }
            return
        }
        if points.count < PhysicsManifold.capacity { points.append(c); return }
        // Full: the deepest of the five stays; of the others, replace the one whose place the new point covers more.
        var deepest = -1   // -1: the new one
        var depth = c.separation
        for i in 0..<4 where points[i].separation < depth { depth = points[i].separation; deepest = i }
        let m = points.map(\.middle)
        var best = -1
        var bestArea: Float = deepest < 0 ? -1 : PhysicsManifold.area(m[0], m[1], m[2], m[3])   // (no infinities: the GPU's fast math)
        for i in 0..<4 where i != deepest {
            var q = m
            q[i] = c.middle
            let a = PhysicsManifold.area(q[0], q[1], q[2], q[3])
            if a > bestArea { bestArea = a; best = i }
        }
        if best >= 0 { points[best] = c }
    }

    /// One normal for the contacts that roughly agree: the candidates' weighted mean. A corner against a corner or
    /// an edge has a normal halfway between faces, which would push the two sideways; where the rest of the patch
    /// says otherwise, it takes theirs (and its separation along it). Contacts far off it (another patch) keep theirs.
    mutating func agree() {
        let l = length(normalSum)
        guard l > 0 else { return }
        let n = normalSum / l
        for i in points.indices where dot(points[i].normal, n) > 0.5 {
            var c = points[i]
            c.normal = n
            c.separation = dot(c.pointA - c.pointB, n) - c.radiusA - c.radiusB
            points[i] = c
        }
    }
}

extension PhysicsWorld {
    // MARK: - A shape's distance

    /// Shape `s`'s distance at `p` (its body's space).
    func distance(shape s: Int, _ p: SIMD3<Float>) -> Float {
        let shape = shapes[s]
        let k = shape.params
        switch PhysicsShapeKind(rawValue: shape.info.x)! {
        case .sphere: return length(p) - k.x
        case .capsule: return PhysicsMath.capsule(p, k.x, k.y)
        case .box: return PhysicsMath.box(p, PhysicsMath.xyz(k), k.w)
        case .plane: return p.y
        case .sdf:
            let q = PhysicsMath.qrot(shape.comRotation, p) + PhysicsMath.xyz(shape.comPosition)
            return sdfShapes[Int(shape.info.w)].distance(q, volumes: sdfVolumes).d
        }
    }

    /// The distance's direction of increase at `p`, unit length: exact for the simple primitives (a box's inside
    /// takes its nearest face's, where a field's differences would blend two faces near a corner), otherwise the
    /// tetrahedral gradient (four taps).
    func gradient(shape s: Int, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let k = shapes[s].params
        switch PhysicsShapeKind(rawValue: shapes[s].info.x)! {
        case .plane: return SIMD3(0, 1, 0)
        case .sphere: return PhysicsMath.direction(p)
        case .capsule: return PhysicsMath.direction(SIMD3(p.x, p.y - min(max(p.y, -k.x), k.x), p.z))
        case .box: return PhysicsMath.boxGradient(p, PhysicsMath.xyz(k), k.w)
        case .sdf: break
        }
        var g = SIMD3<Float>()
        for k in PhysicsMath.taps { g += k * distance(shape: s, p + k * PhysicsMath.gradientStep) }
        let l = length(g)
        return l > 0 ? g / l : SIMD3(0, 1, 0)
    }

    // MARK: - Narrow phase

    /// A body's pose: its centre of mass and rotation (`b` is a body, or a static collider's record).
    struct Pose {
        var position: SIMD3<Float>
        var rotation: SIMD4<Float>
        init(_ b: GPUPhysicsBody) { position = PhysicsMath.xyz(b.position); rotation = b.rotation }
        func toBody(_ p: SIMD3<Float>) -> SIMD3<Float> { PhysicsMath.qrot(PhysicsMath.qconj(rotation), p - position) }
        func toWorld(_ p: SIMD3<Float>) -> SIMD3<Float> { position + PhysicsMath.qrot(rotation, p) }
        func direction(_ v: SIMD3<Float>) -> SIMD3<Float> { PhysicsMath.qrot(rotation, v) }
    }

    /// The contacts between `a` (shape `sa`) and `b` (shape `sb`) closer than `margin` (negative: overlapping).
    func collide(_ a: GPUPhysicsBody, _ b: GPUPhysicsBody, margin: Float) -> PhysicsManifold {
        let sa = Int(a.info.x), sb = Int(b.info.x)
        let pa = Pose(a), pb = Pose(b)
        let ra = a.invInertia.w, rb = b.invInertia.w
        let merge = 0.05 * min(ra, rb > 0 ? rb : ra)
        let plane = shapes[sb].info.x == PhysicsShapeKind.plane.rawValue
        var manifold = PhysicsManifold()

        // A's samples against B's distance.
        let sampleA = shapes[sa].info
        for i in Int(sampleA.y)..<Int(sampleA.y + sampleA.z) {
            let s = samples[i]
            let w = pa.toWorld(PhysicsMath.xyz(s))
            if !plane && length_squared(w - pb.position) > (rb + s.w + margin) * (rb + s.w + margin) { continue }
            let q = pb.toBody(w)
            let d = distance(shape: sb, q) - s.w
            if d >= margin { continue }
            let n = pb.direction(gradient(shape: sb, q))
            manifold.add(PhysicsCandidate(pointA: w, pointB: w - n * (d + s.w), normal: n, separation: d, radiusA: s.w, radiusB: 0),
                         merge: merge, margin: margin)
        }
        // B's samples against A's distance (a plane has none).
        let sampleB = shapes[sb].info
        for i in Int(sampleB.y)..<Int(sampleB.y + sampleB.z) {
            let s = samples[i]
            let w = pb.toWorld(PhysicsMath.xyz(s))
            if length_squared(w - pa.position) > (ra + s.w + margin) * (ra + s.w + margin) { continue }
            let q = pa.toBody(w)
            let d = distance(shape: sa, q) - s.w
            if d >= margin { continue }
            let g = pa.direction(gradient(shape: sa, q))
            manifold.add(PhysicsCandidate(pointA: w - g * (d + s.w), pointB: w, normal: -g, separation: d, radiusA: 0, radiusB: s.w),
                         merge: merge, margin: margin)
        }
        // Two flat-sided shapes: the deepest point of each one's surface inside the other, found by stepping down the
        // other's field and back onto the surface. It catches what corners miss: an edge across an edge, a face on a face.
        if PhysicsWorld.flat(shapes[sa].info.x) && PhysicsWorld.flat(shapes[sb].info.x) {
            var start = (pa.position + pb.position) * 0.5
            if let deepest = manifold.points.min(by: { $0.separation < $1.separation }) { start = deepest.middle }
            let step0 = 0.25 * min(ra, rb)
            for side in 0..<2 {
                let (onX, intoY) = side == 0 ? ((pa, sa), (pb, sb)) : ((pb, sb), (pa, sa))
                var p = start
                var stepLength = step0
                for _ in 0..<PhysicsWorld.refineSteps {
                    let qx = onX.0.toBody(p)
                    p -= onX.0.direction(gradient(shape: onX.1, qx)) * distance(shape: onX.1, qx)   // onto X's surface
                    let qy = intoY.0.toBody(p)
                    p -= intoY.0.direction(gradient(shape: intoY.1, qy)) * stepLength                   // deeper into Y
                    stepLength *= 0.6
                }
                let qx = onX.0.toBody(p)
                p -= onX.0.direction(gradient(shape: onX.1, qx)) * distance(shape: onX.1, qx)
                let qy = intoY.0.toBody(p)
                let d = distance(shape: intoY.1, qy)
                if d >= margin { continue }
                let g = intoY.0.direction(gradient(shape: intoY.1, qy))
                let c = side == 0 ? PhysicsCandidate(pointA: p, pointB: p - g * d, normal: g, separation: d, radiusA: 0, radiusB: 0)
                                  : PhysicsCandidate(pointA: p - g * d, pointB: p, normal: -g, separation: d, radiusA: 0, radiusB: 0)
                manifold.add(c, merge: merge, margin: margin)
            }
        }
        manifold.agree()
        return manifold
    }

    static let refineSteps = 6
    /// Shapes with flat faces and edges (their samples alone miss edge-to-edge contacts).
    static func flat(_ kind: UInt32) -> Bool { kind == PhysicsShapeKind.box.rawValue || kind == PhysicsShapeKind.sdf.rawValue }
}

// MARK: - Building shapes

extension PhysicsWorld {
    /// A shape for SDF shape `sdf`: its kind, its body frame (centre of mass, principal axes), its surface samples,
    /// and its mass properties per unit density (volume, principal moments).
    struct ShapeBuild {
        var shape: GPUPhysicsShape
        var samples: [SIMD4<Float>]
        var volume: Float
        var moments: SIMD3<Float>   // per unit density
    }

    static let maxSamples = 64

    static func buildShape(_ sdf: SDFShape, index: Int, volumes: [SDFVolume]) -> ShapeBuild {
        let node = sdf.nodes[0]
        let identity = abs(node.rotation.real) > 0.99999
        if sdf.nodes.count == 1 && node.scale == 1 && identity {
            let c = node.position
            switch node.primitive {
            case .sphere(let r):
                let v = 4 / 3 * Float.pi * r * r * r
                return ShapeBuild(shape: analytic(.sphere, c, r, SIMD4(r, 0, 0, 0)), samples: [SIMD4(0, 0, 0, r)], volume: v,
                                  moments: SIMD3(repeating: 0.4 * v * r * r))
            case .capsule(let h, let r):
                // A cylinder of 2h and two half balls (their moments about the centre: parallel axes).
                let vc = Float.pi * r * r * 2 * h, vs = 4 / 3 * Float.pi * r * r * r
                let iy = vc * r * r / 2 + vs * 0.4 * r * r
                let ix = vc * (3 * r * r + 4 * h * h) / 12 + vs * (0.4 * r * r + h * h + 0.75 * h * r)
                let core = (0..<5).map { SIMD4<Float>(0, -h + 2 * h * Float($0) / 4, 0, r) }
                return ShapeBuild(shape: analytic(.capsule, c, h + r, SIMD4(h, r, 0, 0)), samples: core, volume: vc + vs,
                                  moments: SIMD3(ix, iy, ix))
            case .box(let b, let r):
                let v = 8 * b.x * b.y * b.z
                let s = 4 * b * b   // full extents squared
                return ShapeBuild(shape: analytic(.box, c, length(b), SIMD4(b, r)), samples: boxSamples(b, r), volume: v,
                                  moments: SIMD3(s.y + s.z, s.x + s.z, s.x + s.y) * (v / 12))
            default: break
            }
        }
        return sampled(sdf, index: index, volumes: volumes)
    }

    private static func analytic(_ kind: PhysicsShapeKind, _ centre: SIMD3<Float>, _ radius: Float, _ params: SIMD4<Float>) -> GPUPhysicsShape {
        GPUPhysicsShape(comPosition: SIMD4(centre, radius), params: params, info: SIMD4(kind.rawValue, 0, 0, 0))
    }

    /// A rounded box's corner spheres and three spheres along each edge (`r` its rounding).
    static func boxSamples(_ b: SIMD3<Float>, _ r: Float) -> [SIMD4<Float>] {
        let e = b - r
        var out: [SIMD4<Float>] = []
        for c in 0..<8 {
            out.append(SIMD4(c & 1 == 0 ? -e.x : e.x, c & 2 == 0 ? -e.y : e.y, c & 4 == 0 ? -e.z : e.z, r))
        }
        for axis in 0..<3 {
            for c in 0..<4 {
                for t: Float in [-0.5, 0, 0.5] {
                    var p = SIMD3<Float>()
                    let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
                    p[axis] = t * e[axis]
                    p[u] = c & 1 == 0 ? -e[u] : e[u]
                    p[v] = c & 2 == 0 ? -e[v] : e[v]
                    out.append(SIMD4(p, r))
                }
            }
        }
        return out
    }

    /// Any other SDF shape: mass properties from the field on a grid, its principal axes, and samples of its surface
    /// (its surface nets' vertices, spread out by farthest-point sampling, after its boxes' corners).
    private static func sampled(_ sdf: SDFShape, index: Int, volumes: [SDFVolume]) -> ShapeBuild {
        let box = sdf.bounds(volumes: volumes)
        let n = 32
        let cell = simd_reduce_max(box.hi - box.lo) / Float(n)
        let counts = SIMD3<Int>(((box.hi - box.lo) / cell).rounded(.up))
        let dv = cell * cell * cell
        var volume: Double = 0, first = SIMD3<Double>(), second = simd_double3x3()
        for z in 0..<counts.z {
            for y in 0..<counts.y {
                for x in 0..<counts.x {
                    // How much of the cell is inside: a ramp across it (exact for a flat face through it, on average).
                    let p = box.lo + (SIMD3(Float(x), Float(y), Float(z)) + 0.5) * cell
                    let inside = Double(min(max(0.5 - sdf.distance(p, volumes: volumes).d / cell, 0), 1))
                    guard inside > 0 else { continue }
                    let q = SIMD3<Double>(p), m = Double(dv) * inside
                    volume += m
                    first += q * m
                    second += simd_double3x3(rows: [q * q.x, q * q.y, q * q.z]) * m
                }
            }
        }
        precondition(volume > 0, "an SDF body has no inside")
        let com = first / volume
        // The inertia tensor about the centre of mass: trace(S) I - S, S the second moment about it.
        let s = second - simd_double3x3(rows: [com * com.x, com * com.y, com * com.z]) * volume
        let trace = s[0][0] + s[1][1] + s[2][2]
        let inertia = simd_double3x3(diagonal: SIMD3(repeating: trace)) - s
        let (moments, axes) = eigen(inertia)
        let rotation = simd_quatf(simd_float3x3(columns: (SIMD3<Float>(axes.columns.0), SIMD3<Float>(axes.columns.1),
                                                           SIMD3<Float>(axes.columns.2))))
        let centre = SIMD3<Float>(com)

        // Samples: the corners of its boxes and the rims of its cylinders where they are on the surface, then points of
        // the surface spread as far from each other as they go.
        let size = simd_reduce_max(box.hi - box.lo)
        var priority: [SIMD3<Float>] = []
        for node in sdf.nodes {
            var points: [SIMD3<Float>] = []
            switch node.primitive {
            case .box(let b, _):
                points = (0..<8).map { c in SIMD3(c & 1 == 0 ? -b.x : b.x, c & 2 == 0 ? -b.y : b.y, c & 4 == 0 ? -b.z : b.z) }
            case .cylinder(let h, let r, _):
                for k in 0..<8 {
                    let a = Float(k) * .pi / 4
                    points += [SIMD3(r * cos(a), -h, r * sin(a)), SIMD3(r * cos(a), h, r * sin(a))]
                }
            default: break
            }
            for p in points {
                let q = (node.transform * SIMD4(p, 1))
                let s = SIMD3(q.x, q.y, q.z)
                if abs(sdf.distance(s, volumes: volumes).d) < 2e-3 * size { priority.append(s) }
            }
        }
        let surface = sdf.triangles(cells: 24, push: 0, volumes: volumes).positions
        var chosen = Array(priority.prefix(maxSamples))
        var nearest = surface.map { p in chosen.map { length_squared($0 - p) }.min() ?? .infinity }
        while chosen.count < maxSamples, !surface.isEmpty {
            var far = 0
            for i in surface.indices where nearest[i] > nearest[far] { far = i }
            guard nearest[far] > 1e-8 else { break }
            chosen.append(surface[far])
            for i in surface.indices { nearest[i] = min(nearest[i], length_squared(surface[i] - surface[far])) }
        }
        let q = PhysicsMath.quat(rotation)
        let toBody = { (p: SIMD3<Float>) in PhysicsMath.qrot(PhysicsMath.qconj(q), p - centre) }
        let radius = (0..<8).map { c -> Float in
            length(toBody(SIMD3(c & 1 == 0 ? box.lo.x : box.hi.x, c & 2 == 0 ? box.lo.y : box.hi.y, c & 4 == 0 ? box.lo.z : box.hi.z)))
        }.max()!
        let shape = GPUPhysicsShape(comPosition: SIMD4(centre, radius), comRotation: q,
                                    info: SIMD4(PhysicsShapeKind.sdf.rawValue, 0, 0, UInt32(index)))
        return ShapeBuild(shape: shape, samples: chosen.map { SIMD4(toBody($0), 0) }, volume: Float(volume),
                          moments: SIMD3<Float>(moments))
    }

    /// A symmetric 3x3 matrix's eigenvalues and its eigenvectors as the columns of a rotation (Jacobi sweeps).
    static func eigen(_ m: simd_double3x3) -> (SIMD3<Double>, simd_double3x3) {
        var a = m
        var v = matrix_identity_double3x3
        for _ in 0..<32 {
            let off = abs(a[1][0]) + abs(a[2][0]) + abs(a[2][1])
            if off < 1e-14 * (abs(a[0][0]) + abs(a[1][1]) + abs(a[2][2]) + 1e-30) { break }
            for (p, q) in [(0, 1), (0, 2), (1, 2)] where abs(a[q][p]) > 0 {
                let theta = (a[q][q] - a[p][p]) / (2 * a[q][p])
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
                let c = 1 / sqrt(t * t + 1), s = t * c
                var r = matrix_identity_double3x3
                r[p][p] = c; r[q][q] = c; r[q][p] = s; r[p][q] = -s
                a = r.transpose * a * r
                v = v * r
            }
        }
        if simd_determinant(v) < 0 { v.columns.2 = -v.columns.2 }
        return (SIMD3(a[0][0], a[1][1], a[2][2]), v)
    }
}
