import Foundation
import simd

/// One edge of a panel as a curve: a cubic Bézier from one point to the next (a line when neither has a handle), and
/// its polyline measured along its length, so that a fraction of an edge (a seam's `t`) is a fraction of its length.
package struct EdgeCurve {
    package let p0: SIMD2<Float>, p1: SIMD2<Float>, p2: SIMD2<Float>, p3: SIMD2<Float>
    package let straight: Bool
    /// The flattened curve and the length up to each of its points.
    package let points: [SIMD2<Float>]
    package let lengths: [Float]
    package var length: Float { lengths.last ?? 0 }

    package init(_ a: PathPoint, _ b: PathPoint, steps: Int = 48) {
        p0 = a.p; p1 = a.p + a.handleOut; p2 = b.p + b.handleIn; p3 = b.p
        straight = a.handleOut == .zero && b.handleIn == .zero
        let n = straight ? 1 : steps
        var pts: [SIMD2<Float>] = [], lens: [Float] = []
        pts.reserveCapacity(n + 1)
        lens.reserveCapacity(n + 1)
        var total: Float = 0
        for i in 0...n {
            let q = EdgeCurve.bezier(p0, p1, p2, p3, Float(i) / Float(n))
            if let last = pts.last { total += simd_distance(last, q) }
            pts.append(q)
            lens.append(total)
        }
        points = pts
        lengths = lens
    }

    package static func bezier(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        let u = 1 - t
        return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
    }

    /// The point `f` of the way along the edge's length.
    package func point(at f: Float) -> SIMD2<Float> {
        let target = max(0, min(1, f)) * length
        guard length > 0 else { return p0 }
        var lo = 0, hi = lengths.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lengths[mid] < target { lo = mid } else { hi = mid }
        }
        let span = lengths[hi] - lengths[lo]
        let w = span > 0 ? (target - lengths[lo]) / span : 0
        return simd_mix(points[lo], points[hi], SIMD2(repeating: w))
    }

    /// The edge's direction `f` of the way along (unit).
    package func tangent(at f: Float) -> SIMD2<Float> {
        let a = point(at: max(0, f - 0.01)), b = point(at: min(1, f + 0.01))
        let d = b - a
        let l = simd_length(d)
        return l > 0 ? d / l : SIMD2(1, 0)
    }

    /// The fraction of the length nearest `q`, and the distance to it.
    package func nearest(_ q: SIMD2<Float>) -> (f: Float, distance: Float) {
        var best = (f: Float(0), distance: Float.infinity)
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1], d = b - a
            let l2 = simd_length_squared(d)
            let s = l2 > 0 ? max(0, min(1, simd_dot(q - a, d) / l2)) : 0
            let dist = simd_distance(q, a + d * s)
            if dist < best.distance {
                let along = lengths[i] + s * (lengths[i + 1] - lengths[i])
                best = (length > 0 ? along / length : 0, dist)
            }
        }
        return best
    }
}

extension Panel {
    /// Edge `e` (from point e to the next) as a curve.
    package func edge(_ e: Int) -> EdgeCurve { EdgeCurve(points[e], points[(e + 1) % points.count]) }
    package var edges: [EdgeCurve] { points.indices.map(edge) }

    /// The outline flattened: every edge's polyline but its last point, in order round the panel.
    package var outline: [SIMD2<Float>] { edges.flatMap { $0.points.dropLast() } }

    package var bounds: (lo: SIMD2<Float>, hi: SIMD2<Float>) {
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for p in outline { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }
    package var centre: SIMD2<Float> { let b = bounds; return (b.lo + b.hi) / 2 }
    /// Its area (m²; negative if the outline runs clockwise).
    package var signedArea: Float { Polygon2D.signedArea(outline) }
    package var perimeter: Float { edges.reduce(0) { $0 + $1.length } }

    package func contains(_ q: SIMD2<Float>) -> Bool { Polygon2D.contains(outline, q) }

    /// The edge nearest `q`: its index, how far along it, and the distance.
    package func nearestEdge(_ q: SIMD2<Float>) -> (edge: Int, f: Float, distance: Float)? {
        var best: (edge: Int, f: Float, distance: Float)?
        for e in points.indices {
            let n = edge(e).nearest(q)
            if best == nil || n.distance < best!.distance { best = (e, n.f, n.distance) }
        }
        return best
    }

    /// The panel moved by `d` (its points and lines).
    package mutating func translate(_ d: SIMD2<Float>) {
        for i in points.indices { points[i].p += d }
        for l in lines.indices { lines[l].points = lines[l].points.map { $0 + d } }
    }

    /// The panel turned by `angle` about `pivot` (the grain turns with it).
    package mutating func rotate(_ angle: Float, about pivot: SIMD2<Float>) {
        let c = cos(angle), s = sin(angle)
        func r(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(c * v.x - s * v.y, s * v.x + c * v.y) }
        for i in points.indices {
            points[i].p = pivot + r(points[i].p - pivot)
            points[i].handleIn = r(points[i].handleIn)
            points[i].handleOut = r(points[i].handleOut)
        }
        for l in lines.indices { lines[l].points = lines[l].points.map { pivot + r($0 - pivot) } }
        grain += angle
    }

    /// The panel mirrored across the vertical line `x = axis` (its outline reversed, so it still runs counter-clockwise).
    package func mirrored(axis: Float) -> Panel {
        var m = self
        func f(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(2 * axis - v.x, v.y) }
        func h(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(-v.x, v.y) }
        m.points = points.reversed().map { PathPoint(f($0.p), handleIn: h($0.handleOut), handleOut: h($0.handleIn), smooth: $0.smooth) }
        m.lines = lines.map { var l = $0; l.points = $0.points.map(f); return l }
        m.grain = .pi - grain
        return m
    }

    /// Edge `e` of the mirrored panel is edge `mirroredEdge(e)` of this one (the outline reversed).
    package func mirroredEdge(_ e: Int) -> Int { (2 * points.count - 2 - e) % points.count }

    /// The outline grown outwards by `d` (the seam allowance a cutter adds round the sewing line), mitred at corners
    /// up to twice `d`.
    package func allowance(_ d: Float) -> [SIMD2<Float>] { Polygon2D.offset(outline, by: d) }
}

/// Plain polygon helpers (counter-clockwise outlines on the pattern sheet).
package enum Polygon2D {
    package static func signedArea(_ p: [SIMD2<Float>]) -> Float {
        guard p.count > 2 else { return 0 }
        var a: Float = 0
        for i in p.indices {
            let u = p[i], v = p[(i + 1) % p.count]
            a += u.x * v.y - v.x * u.y
        }
        return a / 2
    }

    /// Whether `q` is inside (even-odd).
    package static func contains(_ p: [SIMD2<Float>], _ q: SIMD2<Float>) -> Bool {
        var inside = false
        var j = p.count - 1
        for i in p.indices {
            let a = p[i], b = p[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// The distance from `q` to segment `a`–`b`.
    package static func segmentDistance(_ q: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let d = b - a
        let l2 = simd_length_squared(d)
        let s = l2 > 0 ? max(0, min(1, simd_dot(q - a, d) / l2)) : 0
        return simd_distance(q, a + d * s)
    }

    /// The outline moved outwards by `d` (negative: inwards), each corner mitred, the mitre cut at twice `d`.
    package static func offset(_ p: [SIMD2<Float>], by d: Float) -> [SIMD2<Float>] {
        guard p.count > 2 else { return p }
        let ccw = signedArea(p) >= 0
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(p.count)
        for i in p.indices {
            let prev = p[(i + p.count - 1) % p.count], cur = p[i], next = p[(i + 1) % p.count]
            func outward(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
                let t = simd_normalize(b - a)
                return ccw ? SIMD2(t.y, -t.x) : SIMD2(-t.y, t.x)
            }
            guard simd_distance(prev, cur) > 1e-7, simd_distance(cur, next) > 1e-7 else { continue }
            let n0 = outward(prev, cur), n1 = outward(cur, next)
            let m = n0 + n1
            let ml = simd_length(m)
            if ml < 1e-4 { out.append(cur + n0 * d); continue }
            let mitre = m / ml
            let k = min(2, 1 / max(0.05, simd_dot(mitre, n0)))
            out.append(cur + mitre * d * k)
        }
        return out
    }
}
