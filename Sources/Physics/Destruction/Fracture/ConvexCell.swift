import EngineCore
import Foundation
import simd

/// A convex polytope: the intersection of half-spaces, kept as its faces (each a plane and the polygon of the polytope
/// on it). What a fracture's pieces are cut by (FracturePatterns.swift): a box clipped by Voronoi bisectors, a glass
/// pane's wedges and rings, a brick. A plane is (n, d) with n unit and the inside where n . p <= d.
package struct ConvexCell {
    package struct Face {
        package var plane: SIMD4<Float>
        /// Where the face came from: `ConvexCell.outer` for the box the cell started as, otherwise the cut's own tag
        /// (a pattern's: the neighbouring site's, a ring's...).
        package var tag: Int32
        /// Counter-clockwise seen from outside (along the normal).
        package var polygon: [SIMD3<Float>]
    }

    package static let outer: Int32 = -1

    package private(set) var faces: [Face]

    /// The box from `lo` to `hi`, its faces tagged `outer`.
    package init(box lo: SIMD3<Float>, _ hi: SIMD3<Float>) {
        let c = (0..<8).map { k in SIMD3<Float>(k & 1 == 0 ? lo.x : hi.x, k & 2 == 0 ? lo.y : hi.y, k & 4 == 0 ? lo.z : hi.z) }
        // Corner k: bit 0 x, bit 1 y, bit 2 z. Each face counter-clockwise seen from outside.
        let quads: [(SIMD3<Float>, Float, [Int])] = [
            ([-1, 0, 0], -lo.x, [0, 4, 6, 2]), ([1, 0, 0], hi.x, [1, 3, 7, 5]),
            ([0, -1, 0], -lo.y, [0, 1, 5, 4]), ([0, 1, 0], hi.y, [2, 6, 7, 3]),
            ([0, 0, -1], -lo.z, [0, 2, 3, 1]), ([0, 0, 1], hi.z, [4, 5, 7, 6]),
        ]
        faces = quads.map { n, d, k in Face(plane: SIMD4(n, d), tag: ConvexCell.outer, polygon: k.map { c[$0] }) }
    }

    package init(faces: [Face]) { self.faces = faces }

    package var isEmpty: Bool { faces.count < 4 }

    /// Every corner (each once).
    package var vertices: [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let eps = max(size * 1e-5, 1e-7)
        for f in faces {
            for p in f.polygon where !out.contains(where: { length_squared($0 - p) < eps * eps }) { out.append(p) }
        }
        return out
    }

    package var bounds: AABB {
        var box = AABB()
        for f in faces { for p in f.polygon { box.grow(p) } }
        return box
    }

    /// The longest side of its box.
    package var size: Float {
        let b = bounds
        return b.isEmpty ? 0 : simd_reduce_max(b.hi - b.lo)
    }

    /// The planes of its faces with tag `tag` (outer: the box's), or of every face that isn't (`except`).
    package func planes(where keep: (Int32) -> Bool) -> [SIMD4<Float>] { faces.filter { keep($0.tag) }.map(\.plane) }

    /// The cell less what is outside `plane` (n . p > d), its new face tagged `tag`; nil if nothing is left.
    package func clipped(by plane: SIMD4<Float>, tag: Int32) -> ConvexCell? {
        let n = SIMD3(plane.x, plane.y, plane.z), d = plane.w
        let eps = max(size * 1e-6, 1e-8)
        var anyOut = false, anyIn = false
        for f in faces {
            for p in f.polygon {
                let s = dot(n, p) - d
                if s > eps { anyOut = true } else if s < -eps { anyIn = true }
            }
        }
        if !anyOut { return self }
        if !anyIn { return nil }
        var kept: [Face] = [], cut: [SIMD3<Float>] = []
        for f in faces {
            var polygon: [SIMD3<Float>] = []
            let k = f.polygon.count
            for i in 0..<k {
                let a = f.polygon[i], b = f.polygon[(i + 1) % k]
                let sa = dot(n, a) - d, sb = dot(n, b) - d
                if sa <= eps { polygon.append(a) }
                if sa <= eps && sa >= -eps { cut.append(a) }
                if (sa < -eps && sb > eps) || (sa > eps && sb < -eps) {
                    let p = a + (b - a) * (sa / (sa - sb))
                    polygon.append(p)
                    cut.append(p)
                }
            }
            if polygon.count >= 3 { kept.append(Face(plane: f.plane, tag: f.tag, polygon: ConvexCell.dedupe(polygon, eps))) }
        }
        kept.removeAll { $0.polygon.count < 3 }
        // The new face: the cut's points round their middle, counter-clockwise about the normal.
        let ring = ConvexCell.dedupe(ConvexCell.unique(cut, eps * 10), eps)
        if ring.count >= 3 {
            let middle = ring.reduce(SIMD3<Float>(), +) / Float(ring.count)
            let (u, v) = ConvexCell.basis(n)
            let sorted = ring.sorted { atan2(dot($0 - middle, v), dot($0 - middle, u)) < atan2(dot($1 - middle, v), dot($1 - middle, u)) }
            kept.append(Face(plane: plane, tag: tag, polygon: sorted))
        }
        let out = ConvexCell(faces: kept)
        return out.isEmpty || out.volume <= 0 ? nil : out
    }

    /// Two unit vectors across `n` with u x v = n.
    package static func basis(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let a: SIMD3<Float> = abs(n.x) < 0.6 ? [1, 0, 0] : [0, 1, 0]
        let u = normalize(cross(a, n))
        return (u, cross(n, u))
    }

    private static func unique(_ points: [SIMD3<Float>], _ eps: Float) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for p in points where !out.contains(where: { length_squared($0 - p) < eps * eps }) { out.append(p) }
        return out
    }

    /// A polygon without its repeated corners (one after the other, and the last against the first).
    private static func dedupe(_ polygon: [SIMD3<Float>], _ eps: Float) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for p in polygon where out.last.map({ length_squared($0 - p) >= eps * eps }) ?? true { out.append(p) }
        while out.count > 1, length_squared(out[0] - out[out.count - 1]) < eps * eps { out.removeLast() }
        return out
    }

    // MARK: - Mass

    /// The tets of its faces' fans from a point inside.
    private func tets(_ body: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void) {
        let vs = faces.flatMap(\.polygon)
        guard !vs.isEmpty else { return }
        let o = vs.reduce(SIMD3<Float>(), +) / Float(vs.count)
        for f in faces {
            for i in 1..<(f.polygon.count - 1) { body(o, f.polygon[0], f.polygon[i], f.polygon[i + 1]) }
        }
    }

    package var volume: Float {
        var v: Double = 0
        tets { o, a, b, c in v += Double(dot(a - o, cross(b - o, c - o))) / 6 }
        return Float(v)
    }

    /// Its centre of mass (uniform).
    package var centroid: SIMD3<Float> {
        var v: Double = 0, m = SIMD3<Double>()
        tets { o, a, b, c in
            let w = Double(dot(a - o, cross(b - o, c - o))) / 6
            v += w
            m += SIMD3<Double>(o + a + b + c) / 4 * w
        }
        return v > 0 ? SIMD3<Float>(m / v) : .zero
    }

    /// Its inertia tensor about its centre of mass per unit density (trace(S) I - S, S the second moment about it):
    /// what PhysicsWorld.sampled integrates on a grid, exact here.
    package var inertia: simd_double3x3 {
        let c = SIMD3<Double>(centroid)
        var s = simd_double3x3()
        tets { o, a, b, cc in
            let p = [o, a, b, cc].map { SIMD3<Double>($0) - c }
            let v = simd_dot(p[1] - p[0], simd_cross(p[2] - p[0], p[3] - p[0])) / 6
            let sum = p[0] + p[1] + p[2] + p[3]
            // The covariance of a tet: V / 20 (sum p_i p_i^T + (sum p_i)(sum p_i)^T).
            var cov = simd_double3x3(rows: [sum * sum.x, sum * sum.y, sum * sum.z])
            for q in p { cov += simd_double3x3(rows: [q * q.x, q * q.y, q * q.z]) }
            s += cov * (v / 20)
        }
        let trace = s[0][0] + s[1][1] + s[2][2]
        return simd_double3x3(diagonal: SIMD3(repeating: trace)) - s
    }

    // MARK: - Faces together

    /// The faces two cells share: where a face of this one lies on a face of `other` facing the other way, the
    /// polygons they overlap in (this one's normal out of it), none if they share no face.
    package func shared(with other: ConvexCell) -> (normal: SIMD3<Float>, polygons: [[SIMD3<Float>]]) {
        let eps = max(max(size, other.size) * 1e-4, 1e-6)
        var polygons: [[SIMD3<Float>]] = [], normal = SIMD3<Float>()
        for f in faces {
            let n = SIMD3(f.plane.x, f.plane.y, f.plane.z)
            for g in other.faces {
                let m = SIMD3(g.plane.x, g.plane.y, g.plane.z)
                guard dot(n, m) < -0.9999, abs(f.plane.w + g.plane.w) < eps else { continue }
                // g's polygon clipped by f's edges (both convex, in f's plane).
                var poly = g.polygon
                let k = f.polygon.count
                for i in 0..<k where poly.count >= 3 {
                    let a = f.polygon[i], b = f.polygon[(i + 1) % k]
                    let inward = cross(n, b - a)   // points into f (counter-clockwise about n)
                    let len = length(inward)
                    guard len > 0 else { continue }
                    poly = ConvexCell.clip(poly, normal: -inward / len, offset: dot(-inward / len, a))
                }
                guard poly.count >= 3, ConvexCell.polygonArea(poly).0 > eps * eps else { continue }
                polygons.append(poly)
                normal = n
            }
        }
        return (normal, polygons)
    }

    /// A polygon less what is outside the plane (n . p > d).
    package static func clip(_ poly: [SIMD3<Float>], normal n: SIMD3<Float>, offset d: Float) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let sa = dot(n, a) - d, sb = dot(n, b) - d
            if sa <= 0 { out.append(a) }
            if (sa < 0 && sb > 0) || (sa > 0 && sb < 0) { out.append(a + (b - a) * (sa / (sa - sb))) }
        }
        return out
    }

    /// A planar polygon's area and centroid.
    package static func polygonArea(_ poly: [SIMD3<Float>]) -> (Float, SIMD3<Float>) {
        var area: Float = 0, centre = SIMD3<Float>()
        for i in 1..<(poly.count - 1) {
            let a = length(cross(poly[i] - poly[0], poly[i + 1] - poly[0])) / 2
            area += a
            centre += (poly[0] + poly[i] + poly[i + 1]) / 3 * a
        }
        return (area, area > 0 ? centre / area : poly[0])
    }

    /// Whether `p` is inside (within `slack`).
    package func contains(_ p: SIMD3<Float>, slack: Float = 0) -> Bool {
        faces.allSatisfy { dot(SIMD3($0.plane.x, $0.plane.y, $0.plane.z), p) - $0.plane.w <= slack }
    }

    /// The signed distance bound the GPU's cell node gives (Shaders/SDF.metal): the largest of its planes'.
    package func distance(_ p: SIMD3<Float>) -> Float {
        faces.reduce(-Float.infinity) { max($0, dot(SIMD3($1.plane.x, $1.plane.y, $1.plane.z), p) - $1.plane.w) }
    }
}

extension ConvexCell {
    /// The cell as a mesh (a convex object's piece drawn: Scene.addFractured): each face its polygon fanned into
    /// triangles, flat (its plane's normal), texture coordinates `uvScale` per metre across it (as MeshCutter's caps
    /// are), material offset 0 on the object's own faces (`outer`) and `interior` on its cuts. A brick is 12 triangles.
    package func mesh(interior: UInt8, uvScale: Float = 1) -> MeshCutter.Mesh {
        var out = MeshCutter.Mesh()
        for face in faces where face.polygon.count >= 3 {
            let n = SIMD3(face.plane.x, face.plane.y, face.plane.z)
            let (u, v) = ConvexCell.basis(n)
            let material: UInt8 = face.tag == ConvexCell.outer ? 0 : interior
            let first = UInt32(out.positions.count)
            for p in face.polygon { _ = out.add(p, n, SIMD2(dot(p, u), dot(p, v)) * uvScale) }
            for k in 1..<(face.polygon.count - 1) {
                out.indices += [first, first + UInt32(k), first + UInt32(k + 1)]
                out.materials.append(material)
            }
        }
        return out
    }
}
