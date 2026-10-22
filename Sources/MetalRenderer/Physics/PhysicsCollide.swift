import EngineCore
import Foundation
import Plants
import simd

/// What a physics shape's distance is (GPUPhysicsShape.info.x): exact formulas for the simple primitives, the SDF
/// shape's field for everything else, a plane (static colliders only) whose body-space y is the distance, and a
/// heightfield (static colliders only: a terrain's sector) whose height over its ground is.
enum PhysicsShapeKind: UInt32 {
    case sdf = 0, sphere, capsule, box, plane, heightfield
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
package enum PhysicsMath {
    @inline(__always) package static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
    @inline(__always) static func qmul(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        let av = xyz(a), bv = xyz(b)
        return SIMD4(a.w * bv + b.w * av + cross(av, bv), a.w * b.w - dot(av, bv))
    }
    @inline(__always) package static func qrot(_ q: SIMD4<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let u = xyz(q)
        let t = 2 * cross(u, v)
        return v + q.w * t + cross(u, t)
    }
    @inline(__always) package static func qconj(_ q: SIMD4<Float>) -> SIMD4<Float> { SIMD4(-q.x, -q.y, -q.z, q.w) }
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
    static let none = PhysicsCandidate(pointA: .zero, pointB: .zero, normal: .zero, separation: 0, radiusA: 0, radiusB: 0)
}

/// Up to four contacts, kept as Bullet keeps a persistent manifold: the deepest always, the rest to cover the most
/// area. Points are added one at a time (the GPU has no room for a pair's every candidate). Four fixed slots, no array:
/// the narrow phase makes one a pair, on every core.
struct PhysicsManifold {
    static let capacity = 4
    private var p0 = PhysicsCandidate.none, p1 = PhysicsCandidate.none, p2 = PhysicsCandidate.none, p3 = PhysicsCandidate.none
    /// How many of the slots hold a point.
    private(set) var count = 0
    /// Every candidate's normal, weighted by how deep it is (margin - separation): what most of them say.
    var normalSum = SIMD3<Float>()

    subscript(i: Int) -> PhysicsCandidate {
        @inline(__always) get {
            switch i {
            case 0: return p0
            case 1: return p1
            case 2: return p2
            default: return p3
            }
        }
        @inline(__always) set {
            switch i {
            case 0: p0 = newValue
            case 1: p1 = newValue
            case 2: p2 = newValue
            default: p3 = newValue
            }
        }
    }

    /// The points (outside the narrow phase's loop: it reads the slots).
    var points: [PhysicsCandidate] { (0..<count).map { self[$0] } }

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
        let cm = c.middle
        for i in 0..<count where length_squared(self[i].middle - cm) < merge * merge {
            if c.separation < self[i].separation { self[i] = c }
            return
        }
        if count < PhysicsManifold.capacity {
            self[count] = c
            count += 1
            return
        }
        // Full: the deepest of the five stays; of the others, replace the one whose place the new point covers more.
        var deepest = -1   // -1: the new one
        var depth = c.separation
        for i in 0..<4 where self[i].separation < depth { depth = self[i].separation; deepest = i }
        let m0 = p0.middle, m1 = p1.middle, m2 = p2.middle, m3 = p3.middle
        var best = -1
        var bestArea: Float = deepest < 0 ? -1 : PhysicsManifold.area(m0, m1, m2, m3)   // (no infinities: the GPU's fast math)
        for i in 0..<4 where i != deepest {
            let a = PhysicsManifold.area(i == 0 ? cm : m0, i == 1 ? cm : m1, i == 2 ? cm : m2, i == 3 ? cm : m3)
            if a > bestArea { bestArea = a; best = i }
        }
        if best >= 0 { self[best] = c }
    }

    /// The deepest point (the first of equals), if any.
    var deepest: PhysicsCandidate? {
        guard count > 0 else { return nil }
        var d = p0
        for i in 1..<count where self[i].separation < d.separation { d = self[i] }
        return d
    }

    /// One normal for the contacts that roughly agree: the candidates' weighted mean. A corner against a corner or
    /// an edge has a normal halfway between faces, which would push the two sideways; where the rest of the patch
    /// says otherwise, it takes theirs (and its separation along it). Contacts far off it (another patch) keep theirs.
    mutating func agree() {
        let l = length(normalSum)
        guard l > 0 else { return }
        let n = normalSum / l
        for i in 0..<count where dot(self[i].normal, n) > 0.5 {
            var c = self[i]
            c.normal = n
            c.separation = dot(c.pointA - c.pointB, n) - c.radiusA - c.radiusB
            self[i] = c
        }
    }
}

/// An SDF shape's node as the physics reads it (SDFShape.Node, flat: no arrays, nothing counted): its primitive's
/// kind and numbers, its op, where it is. A cell's planes are a run of PhysicsShapeTable.planes.
struct PhysicsSDFNode {
    enum Kind: UInt32 { case sphere, box, torus, capsule, cylinder, cone, volume, cell }
    var kind: Kind
    var op: UInt32            // SDFShape.Op's raw value (sdfJoin's): a plain number, read per sample
    /// sphere: (r); box: (half extents, rounding); torus: (major, minor); capsule: (half length, r); cylinder:
    /// (half height, r, rounding); cone: (half height, bottom, top); volume: (its index); cell: (first plane, planes).
    var params: SIMD4<Float>
    var first: Int, count: Int
    var position: SIMD3<Float>
    var inverse: simd_quatf   // (the node's rotation's: Node.local's)
    var scale: Float
    var smooth: Float
    /// Where it is is the shape's origin, unturned and unscaled: its space is the shape's (a fractured piece's object
    /// and its cell, most often). `sdf` skips the turn, which gives the same point back (but for a zero's sign, which
    /// no primitive's distance tells apart away from its origin): three buildings' narrow phases' distances, 32 →
    /// 23 ns each.
    var plain: Bool

    package init(_ node: SDFShape.Node, planes: inout [SIMD4<Float>]) {
        op = node.op.rawValue
        position = node.position
        inverse = node.rotation.inverse
        scale = node.scale
        smooth = node.smooth
        plain = inverse.vector == SIMD4(0, 0, 0, 1) && position == .zero && scale == 1
        first = 0
        count = 0
        switch node.primitive {
        case .sphere(let r): (kind, params) = (.sphere, SIMD4(r, 0, 0, 0))
        case .box(let b, let r): (kind, params) = (.box, SIMD4(b, r))
        case .torus(let major, let minor): (kind, params) = (.torus, SIMD4(major, minor, 0, 0))
        case .capsule(let h, let r): (kind, params) = (.capsule, SIMD4(h, r, 0, 0))
        case .cylinder(let h, let r, let rr): (kind, params) = (.cylinder, SIMD4(h, r, rr, 0))
        case .cone(let h, let r1, let r2): (kind, params) = (.cone, SIMD4(h, r1, r2, 0))
        case .volume(let v): (kind, params, first) = (.volume, .zero, v)
        case .cell(let p, _, _):
            (kind, params, first, count) = (.cell, .zero, planes.count, p.count)
            planes += p
        }
    }
}

/// The world's shapes as the steps read them, in buffers of its own (no arrays to count references to: ten threads
/// asking one shape's distance contended on its arrays' counts, and the hair scene's step took ten times as long): the
/// shapes, their samples, the SDF shapes' nodes (PhysicsSDFNode) and planes, the baked grids. Made again when the
/// world's shapes change (PhysicsWorld.shapeData).
final class PhysicsShapeTable {
    let shapes: UnsafeMutableBufferPointer<GPUPhysicsShape>
    let samples: UnsafeMutableBufferPointer<SIMD4<Float>>
    let nodes: UnsafeMutableBufferPointer<PhysicsSDFNode>
    /// Per SDF shape, its nodes: first, count.
    let sdfRanges: UnsafeMutableBufferPointer<SIMD2<Int32>>
    let planes: UnsafeMutableBufferPointer<SIMD4<Float>>
    let volumes: UnsafeMutableBufferPointer<SDFVolume>

    package init(shapes: [GPUPhysicsShape], samples: [SIMD4<Float>], sdfShapes: [SDFShape], volumes: [SDFVolume]) {
        func copy<T>(_ a: [T]) -> UnsafeMutableBufferPointer<T> {
            let b = UnsafeMutableBufferPointer<T>.allocate(capacity: max(a.count, 1))
            _ = b.initialize(from: a)
            return UnsafeMutableBufferPointer(rebasing: b[0..<a.count])
        }
        var flat: [PhysicsSDFNode] = [], ranges: [SIMD2<Int32>] = [], planes: [SIMD4<Float>] = []
        for shape in sdfShapes {
            ranges.append(SIMD2(Int32(flat.count), Int32(shape.nodes.count)))
            for node in shape.nodes { flat.append(PhysicsSDFNode(node, planes: &planes)) }
        }
        self.shapes = copy(shapes)
        self.samples = copy(samples)
        self.nodes = copy(flat)
        self.sdfRanges = copy(ranges)
        self.planes = copy(planes)
        self.volumes = copy(volumes)
    }

    deinit {
        for b in [UnsafeMutableRawBufferPointer(shapes), UnsafeMutableRawBufferPointer(samples), UnsafeMutableRawBufferPointer(nodes),
                  UnsafeMutableRawBufferPointer(sdfRanges), UnsafeMutableRawBufferPointer(planes)] {
            b.baseAddress.map { $0.deallocate() }
        }
        _ = volumes.baseAddress.map { $0.deinitialize(count: volumes.count) }
        volumes.baseAddress.map { $0.deallocate() }
    }

    /// Its buffers, as the steps read them.
    var view: PhysicsShapes {
        PhysicsShapes(shapes: UnsafeBufferPointer(shapes), samples: UnsafeBufferPointer(samples), nodes: UnsafeBufferPointer(nodes),
                      sdfRanges: UnsafeBufferPointer(sdfRanges), planes: UnsafeBufferPointer(planes), volumes: UnsafeBufferPointer(volumes))
    }
}

/// What a body's shape is to the steps, read-only while they run (PhysicsShapeTable's buffers, valid while the world's
/// shapes don't change: take one before a stage, `PhysicsWorld.shapeData`): the distance, the gradient and a pair's
/// contacts, on any thread.
struct PhysicsShapes {
    let shapes: UnsafeBufferPointer<GPUPhysicsShape>
    let samples: UnsafeBufferPointer<SIMD4<Float>>
    let nodes: UnsafeBufferPointer<PhysicsSDFNode>
    let sdfRanges: UnsafeBufferPointer<SIMD2<Int32>>
    let planes: UnsafeBufferPointer<SIMD4<Float>>
    let volumes: UnsafeBufferPointer<SDFVolume>

    /// SDF shape `index`'s distance at `p` (SDFShape.distance's `d`, the same steps).
    @inline(__always) func sdf(_ index: Int, _ p: SIMD3<Float>) -> Float {
        let range = sdfRanges[index]
        var d = Float.infinity
        for i in 0..<Int(range.y) {
            let node = nodes[Int(range.x) + i]
            let b = node.scale * primitive(node, node.plain ? p : node.inverse.act(p - node.position) / node.scale)
            if i == 0 { d = b; continue }
            d = sdfJoin(d, b, node.op, node.smooth).0
        }
        return d
    }

    /// A node's primitive's distance at `q` (its own space): SDFShape.primitive's, case by case.
    @inline(__always) func primitive(_ node: PhysicsSDFNode, _ q: SIMD3<Float>) -> Float {
        let k = node.params
        switch node.kind {
        case .sphere:
            return length(q) - k.x
        case .box:
            let b = SIMD3(k.x, k.y, k.z), r = k.w
            let e = abs(q) - (b - r)
            return length(simd_max(e, .zero)) + min(max(e.x, max(e.y, e.z)), 0) - r
        case .torus:
            let t = SIMD2(length(SIMD2(q.x, q.z)) - k.x, q.y)
            return length(t) - k.y
        case .capsule:
            let h = k.x, r = k.y
            return length(SIMD3(q.x, q.y - min(max(q.y, -h), h), q.z)) - r
        case .cylinder:
            let h = k.x, r = k.y, rr = k.z
            let e = SIMD2(length(SIMD2(q.x, q.z)) - (r - rr), abs(q.y) - (h - rr))
            return min(max(e.x, e.y), 0) + length(simd_max(e, .zero)) - rr
        case .cone:
            let h = k.x, r1 = k.y, r2 = k.z
            let p = SIMD2(length(SIMD2(q.x, q.z)), q.y)
            let k1 = SIMD2(r2, h), k2 = SIMD2(r2 - r1, 2 * h)
            let ca = SIMD2(p.x - min(p.x, p.y < 0 ? r1 : r2), abs(p.y) - h)
            let cb = p - k1 + k2 * min(max(dot(k1 - p, k2) / dot(k2, k2), 0), 1)
            let s: Float = cb.x < 0 && ca.y < 0 ? -1 : 1
            return s * sqrt(min(dot(ca, ca), dot(cb, cb)))
        case .volume:
            return volumes[node.first].distance(q)
        case .cell:
            var d = -Float.infinity
            for j in node.first..<(node.first + node.count) {
                let plane = planes[j]
                d = max(d, dot(SIMD3(plane.x, plane.y, plane.z), q) - plane.w)
            }
            return d
        }
    }

    // MARK: - A terrain's heightfield

    /// A heightfield's height under (x, z) (its body's space): bilinear between its samples, held at its edges. Its
    /// samples are four to an entry of `samples` from `info.w`; `params` = (x, z of its first sample, its cell, its
    /// samples along x), `comPosition.x` its samples along z, `.y` its slope bound (a distance is the height over the
    /// ground times it).
    @inline(__always) func heightfieldHeight(_ shape: GPUPhysicsShape, _ x: Float, _ z: Float) -> Float {
        let k = shape.params, nx = Int(k.w), nz = Int(shape.comPosition.x), first = Int(shape.info.w)
        @inline(__always) func h(_ i: Int, _ j: Int) -> Float {
            let n = min(max(j, 0), nz - 1) * nx + min(max(i, 0), nx - 1)
            return samples[first + n / 4][n % 4]
        }
        let gx = (x - k.x) / k.z, gz = (z - k.y) / k.z
        let fx = min(max(gx, 0), Float(nx - 1)), fz = min(max(gz, 0), Float(nz - 1))
        let i = min(Int(fx), nx - 2), j = min(Int(fz), nz - 2), u = fx - Float(i), v = fz - Float(j)
        let a = h(i, j) + (h(i + 1, j) - h(i, j)) * u, b = h(i, j + 1) + (h(i + 1, j + 1) - h(i, j + 1)) * u
        return a + (b - a) * v
    }

    @inline(__always) func heightfieldDistance(_ shape: GPUPhysicsShape, _ p: SIMD3<Float>) -> Float {
        (p.y - heightfieldHeight(shape, p.x, p.z)) * shape.comPosition.y
    }

    func heightfieldGradient(_ shape: GPUPhysicsShape, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let e = shape.params.z * 0.5
        let dx = heightfieldHeight(shape, p.x + e, p.z) - heightfieldHeight(shape, p.x - e, p.z)
        let dz = heightfieldHeight(shape, p.x, p.z + e) - heightfieldHeight(shape, p.x, p.z - e)
        return normalize(SIMD3(-dx, 2 * e, -dz))
    }

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
        case .heightfield: return heightfieldDistance(shape, p)
        case .sdf:
            let q = PhysicsMath.qrot(shape.comRotation, p) + PhysicsMath.xyz(shape.comPosition)
            return sdf(Int(shape.info.w), q)
        }
    }

    /// The distance's direction of increase at `p`, unit length: exact for the simple primitives (a box's inside
    /// takes its nearest face's, where a field's differences would blend two faces near a corner), otherwise the
    /// tetrahedral gradient (four taps).
    func gradient(shape s: Int, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let k = shapes[s].params
        switch PhysicsShapeKind(rawValue: shapes[s].info.x)! {
        case .plane: return SIMD3(0, 1, 0)
        case .heightfield: return heightfieldGradient(shapes[s], p)
        case .sphere: return PhysicsMath.direction(p)
        case .capsule: return PhysicsMath.direction(SIMD3(p.x, p.y - min(max(p.y, -k.x), k.x), p.z))
        case .box: return PhysicsMath.boxGradient(p, PhysicsMath.xyz(k), k.w)
        case .sdf: break
        }
        var g = SIMD3<Float>()
        // (The taps one by one, in their order: through the array, each call took a static object's lazy init.)
        let t0 = SIMD3<Float>(1, -1, -1), t1 = SIMD3<Float>(-1, -1, 1), t2 = SIMD3<Float>(-1, 1, -1), t3 = SIMD3<Float>(1, 1, 1)
        g += t0 * distance(shape: s, p + t0 * PhysicsMath.gradientStep)
        g += t1 * distance(shape: s, p + t1 * PhysicsMath.gradientStep)
        g += t2 * distance(shape: s, p + t2 * PhysicsMath.gradientStep)
        g += t3 * distance(shape: s, p + t3 * PhysicsMath.gradientStep)
        let l = length(g)
        return l > 0 ? g / l : SIMD3(0, 1, 0)
    }

    // MARK: - Narrow phase

    typealias Pose = PhysicsWorld.Pose

    /// The contacts between `a` (shape `sa`) and `b` (shape `sb`) closer than `margin` (negative: overlapping).
    func collide(_ a: GPUPhysicsBody, _ b: GPUPhysicsBody, margin: Float) -> PhysicsManifold {
        withPoints(a) { pointsA in withPoints(b) { pointsB in collide(a, b, margin: margin, pointsA: pointsA, pointsB: pointsB) } }
    }

    /// Body b's samples' world points (Pose.toWorld of each, as SampleCache works them out), for `body`.
    func withPoints<R>(_ b: GPUPhysicsBody, _ body: (UnsafePointer<SIMD3<Float>>) -> R) -> R {
        let info = shapes[Int(b.info.x)].info, pose = Pose(b)
        return withUnsafeTemporaryAllocation(of: SIMD3<Float>.self, capacity: max(Int(info.z), 1)) { points in
            for m in 0..<Int(info.z) { points[m] = pose.toWorld(PhysicsMath.xyz(samples[Int(info.y) + m])) }
            return body(UnsafePointer(points.baseAddress!))
        }
    }

    /// collide, with each body's samples' world points (`pointsA`, `pointsB`: their poses' toWorld of each).
    func collide(_ a: GPUPhysicsBody, _ b: GPUPhysicsBody, margin: Float, pointsA: UnsafePointer<SIMD3<Float>>,
                 pointsB: UnsafePointer<SIMD3<Float>>) -> PhysicsManifold {
        let sa = Int(a.info.x), sb = Int(b.info.x)
        let pa = Pose(a), pb = Pose(b)
        let ra = a.invInertia.w, rb = b.invInertia.w
        let merge = 0.05 * min(ra, rb > 0 ? rb : ra)
        // (A plane, a terrain's heightfield: no bounding sphere to reach.)
        let plane = shapes[sb].info.x == PhysicsShapeKind.plane.rawValue || shapes[sb].info.x == PhysicsShapeKind.heightfield.rawValue
        var manifold = PhysicsManifold()

        // A's samples against B's distance.
        let sampleA = shapes[sa].info
        for i in Int(sampleA.y)..<Int(sampleA.y + sampleA.z) {
            let s = samples[i]
            let w = pointsA[i - Int(sampleA.y)]
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
            let w = pointsB[i - Int(sampleB.y)]
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
        // (Not for a fractured object's pieces: on a cell's distance, the largest of its planes', whose gradient jumps at
        // every edge, the walk ended somewhere new each step with a normal off the patch's, which tipped the pair's
        // normal, and a heap of pieces rocked, crept flat and never slept. Their samples run along their edges.)
        if PhysicsWorld.flat(shapes[sa].info.x) && PhysicsWorld.flat(shapes[sb].info.x) && (a.info.y | b.info.y) & PhysicsWorld.pieceBit == 0 {
            var start = (pa.position + pb.position) * 0.5
            if let deepest = manifold.deepest { start = deepest.middle }
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

}

extension PhysicsWorld {
    /// A body's pose: its centre of mass and rotation (`b` is a body, or a static collider's record).
    package struct Pose {
        package var position: SIMD3<Float>
        package var rotation: SIMD4<Float>
        package init(_ b: GPUPhysicsBody) { position = PhysicsMath.xyz(b.position); rotation = b.rotation }
        package func toBody(_ p: SIMD3<Float>) -> SIMD3<Float> { PhysicsMath.qrot(PhysicsMath.qconj(rotation), p - position) }
        package func toWorld(_ p: SIMD3<Float>) -> SIMD3<Float> { position + PhysicsMath.qrot(rotation, p) }
        package func direction(_ v: SIMD3<Float>) -> SIMD3<Float> { PhysicsMath.qrot(rotation, v) }
    }

    /// The shapes as the steps read them (PhysicsShapes, on PhysicsShapeTable's buffers, made again after the shapes
    /// change): take one before a loop.
    var shapeData: PhysicsShapes {
        if let view = shapeView { return view }   // (raw buffers: nothing counted, from any thread)
        let table = PhysicsShapeTable(shapes: shapes, samples: samples, sdfShapes: sdfShapes, volumes: sdfVolumes)
        shapeTable = table
        shapeEpoch += 1   // (what the narrow phase kept was found on the shapes before)
        shapeView = table.view
        return table.view
    }

    func heightfieldHeight(_ shape: GPUPhysicsShape, _ x: Float, _ z: Float) -> Float { shapeData.heightfieldHeight(shape, x, z) }
    package func distance(shape s: Int, _ p: SIMD3<Float>) -> Float { shapeData.distance(shape: s, p) }
    package func gradient(shape s: Int, _ p: SIMD3<Float>) -> SIMD3<Float> { shapeData.gradient(shape: s, p) }
    func collide(_ a: GPUPhysicsBody, _ b: GPUPhysicsBody, margin: Float) -> PhysicsManifold { shapeData.collide(a, b, margin: margin) }

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
