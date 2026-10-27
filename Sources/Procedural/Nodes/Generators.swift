import Foundation
import Modeling
import simd

/// The nodes that make geometry from nothing: Box, Grid, Sphere, Tube, Torus, Circle, Line, Add, File.
enum Generators {
    /// The plane's two axes and its normal for an orientation menu (`ZX`: the ground, facing up).
    static func plane(_ orient: String) -> (u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>) {
        switch orient {
        case "XY": ([1, 0, 0], [0, 1, 0], [0, 0, 1])
        case "YZ": ([0, 1, 0], [0, 0, 1], [1, 0, 0])
        default: ([1, 0, 0], [0, 0, 1], [0, 1, 0])
        }
    }

    /// Turns every polygon's front to `normal`'s side if the first one's isn't.
    static func face(_ g: inout ProcGeo, toward normal: SIMD3<Float>) {
        guard g.primCount > 0, simd_dot(g.primNormal(0), normal) < 0 else { return }
        let starts = g.primStart
        func reverse<T>(_ a: inout [T]) {
            a.withUnsafeMutableBufferPointer { a in
                for p in 0..<(starts.count - 1) {
                    var lo = Int(starts[p]), hi = Int(starts[p + 1]) - 1
                    while lo < hi { a.swapAt(lo, hi); lo += 1; hi -= 1 }
                }
            }
        }
        reverse(&g.vertexPoint)
        if case .vector2(var uv)? = g.vertices["uv"] {
            reverse(&uv)
            g.vertices.set("uv", .vector2(uv))
        }
    }

    static func box(_ c: ProcCook) -> ProcGeo {
        let size = c.vec3("size") * c.float("scale"), t = c.vec3("t")
        let n = SIMD3<Int>(simd_max(SIMD3<Float>(1, 1, 1), c.vec3("divs").rounded(.toNearestOrAwayFromZero)))
        // Points on the surface of a lattice of n cells a side, shared where sides meet.
        var index: [SIMD3<Int32>: Int32] = [:]
        var g = ProcGeo()
        func point(_ l: SIMD3<Int32>) -> Int32 {
            if let i = index[l] { return i }
            let f = SIMD3<Float>(l) / SIMD3<Float>(n) - 0.5
            g.P.append(t + f * size)
            index[l] = Int32(g.P.count - 1)
            return Int32(g.P.count - 1)
        }
        for axis in 0..<3 {
            let u = (axis + 1) % 3, v = (axis + 2) % 3
            for side in [0, 1] {
                for i in 0..<n[u] {
                    for j in 0..<n[v] {
                        var corners: [Int32] = []
                        for (di, dj) in [(0, 0), (1, 0), (1, 1), (0, 1)] {
                            var l = SIMD3<Int32>(0, 0, 0)
                            l[axis] = Int32(side * n[axis])
                            l[u] = Int32(i + di)
                            l[v] = Int32(j + dj)
                            corners.append(point(l))
                        }
                        // e_u × e_v = e_axis: counter-clockwise from the + side.
                        if side == 0 { corners.reverse() }
                        g.vertexPoint += corners
                        g.primStart.append(Int32(g.vertexPoint.count))
                        g.primClosed.append(true)
                    }
                }
            }
        }
        g.syncCounts()
        return g
    }

    static func grid(_ c: ProcCook) -> ProcGeo {
        let (u, v, n) = plane(c.string("orient"))
        let size = c.vec2("size"), t = c.vec3("t")
        let rows = max(2, c.int("rows")), cols = max(2, c.int("cols"))
        var g = ProcGeo()
        g.P.reserveCapacity(rows * cols)
        for r in 0..<rows {
            for k in 0..<cols {
                let a = Float(k) / Float(cols - 1) - 0.5, b = Float(r) / Float(rows - 1) - 0.5
                g.P.append(t + u * (a * size.x) + v * (b * size.y))
            }
        }
        let quads = (rows - 1) * (cols - 1)
        var uv: [SIMD2<Float>] = []
        uv.reserveCapacity(quads * 4)
        g.vertexPoint.reserveCapacity(quads * 4)
        g.primStart.reserveCapacity(quads + 1)
        g.primClosed.reserveCapacity(quads)
        for r in 0..<(rows - 1) {
            for k in 0..<(cols - 1) {
                let i = Int32(r * cols + k)
                g.vertexPoint.append(i); g.vertexPoint.append(i + 1)
                g.vertexPoint.append(i + 1 + Int32(cols)); g.vertexPoint.append(i + Int32(cols))
                g.primStart.append(Int32(g.vertexPoint.count))
                g.primClosed.append(true)
                let u0 = Float(k) / Float(cols - 1), u1 = Float(k + 1) / Float(cols - 1)
                let v0 = Float(r) / Float(rows - 1), v1 = Float(r + 1) / Float(rows - 1)
                uv.append([u0, v0]); uv.append([u1, v0]); uv.append([u1, v1]); uv.append([u0, v1])
            }
        }
        g.syncCounts()
        g.vertices.set("uv", .vector2(uv))
        face(&g, toward: n)
        return g
    }

    static func sphere(_ c: ProcCook) -> ProcGeo {
        let m: EditMesh
        switch c.string("type") {
        case "ico": m = Primitives.icoSphere(subdivisions: max(0, c.int("freq")), radius: 1)
        case "quad": m = Primitives.quadSphere(n: max(1, c.int("freq") + 1), radius: 1)
        default: m = Primitives.uvSphere(segments: max(3, c.int("cols")), rings: max(2, c.int("rows") - 1), radius: 1)
        }
        var g = ProcGeo(m)
        let s = c.vec3("rad") * c.float("scale"), t = c.vec3("t")
        for i in 0..<g.pointCount { g.P[i] = t + g.P[i] * s }
        return g
    }

    static func tube(_ c: ProcCook) -> ProcGeo {
        let rad = c.vec2("rad"), h = c.float("height"), t = c.vec3("t")
        let rows = max(2, c.int("rows")), cols = max(3, c.int("cols"))
        var g = ProcGeo()
        // Rings from the bottom up; a ring of radius 0 is one point (a cone's tip).
        var ring: [[Int32]] = []
        for r in 0..<rows {
            let f = Float(r) / Float(rows - 1)
            let radius = rad.y + (rad.x - rad.y) * f
            let y = t.y + h * (f - 0.5)
            if radius == 0 {
                g.P.append([t.x, y, t.z])
                ring.append([Int32](repeating: Int32(g.P.count - 1), count: cols))
                continue
            }
            var ids: [Int32] = []
            for k in 0..<cols {
                let a = 2 * Float.pi * Float(k) / Float(cols)
                g.P.append(t + SIMD3(sin(a) * radius, y - t.y, cos(a) * radius))
                ids.append(Int32(g.P.count - 1))
            }
            ring.append(ids)
        }
        func add(_ pts: [Int32]) {
            var unique: [Int32] = []
            for p in pts where unique.last != p { unique.append(p) }
            while unique.count > 1 && unique.first == unique.last { unique.removeLast() }
            guard unique.count >= 3 else { return }
            g.vertexPoint += unique
            g.primStart.append(Int32(g.vertexPoint.count))
            g.primClosed.append(true)
        }
        for r in 0..<(rows - 1) {
            for k in 0..<cols {
                let k1 = (k + 1) % cols
                // Seen from outside, counter-clockwise: round the ring the way the angle grows, then up.
                add([ring[r][k], ring[r][k1], ring[r + 1][k1], ring[r + 1][k]])
            }
        }
        if c.bool("caps") {
            if rad.y > 0 { add(ring[0].reversed()) }
            if rad.x > 0 { add(ring[rows - 1]) }
        }
        g.syncCounts()
        // The walls' fronts outward: test one against the way out from the axis.
        if g.primCount > 0 {
            let out = g.primCenter(0) - SIMD3(t.x, g.primCenter(0).y, t.z)
            if simd_dot(g.primNormal(0), out) < 0 {
                for p in 0..<g.primCount { g.vertexPoint[g.vertexRange(p)].reverse() }
            }
        }
        return g
    }

    static func torus(_ c: ProcCook) -> ProcGeo {
        let rad = c.vec2("rad"), t = c.vec3("t")
        var g = ProcGeo(Primitives.torus(major: max(3, c.int("cols")), minor: max(3, c.int("rows")), majorRadius: rad.x, minorRadius: rad.y))
        for i in 0..<g.pointCount { g.P[i] += t }
        return g
    }

    static func circle(_ c: ProcCook) -> ProcGeo {
        let (u, v, n) = plane(c.string("orient"))
        let rad = c.vec2("rad"), t = c.vec3("t"), divs = max(3, c.int("divs"))
        let a0 = c.float("beginangle") * .pi / 180, a1 = c.float("endangle") * .pi / 180
        let full = abs(a1 - a0) >= 2 * .pi - 1e-4
        let arc = c.string("arc")
        let count = full ? divs : divs + 1
        var g = ProcGeo()
        for i in 0..<count {
            let a = a0 + (a1 - a0) * Float(i) / Float(divs)
            g.P.append(t + u * (cos(a) * rad.x) + v * (sin(a) * rad.y))
        }
        var pts = (0..<Int32(count)).map { $0 }
        if arc == "sliced" && !full {
            g.P.append(t)
            pts.append(Int32(g.P.count - 1))
        }
        if arc == "open" && full { pts.append(0) }
        g.vertexPoint = pts
        g.primStart = [0, Int32(pts.count)]
        g.primClosed = [arc != "open"]
        g.syncCounts()
        if arc != "open" { face(&g, toward: n) }
        return g
    }

    static func line(_ c: ProcCook) -> ProcGeo {
        let o = c.vec3("origin"), d = c.vec3("dir"), len = c.float("dist"), n = max(2, c.int("points"))
        let dir = simd_length(d) > 0 ? simd_normalize(d) : SIMD3<Float>(0, 1, 0)
        let P = (0..<n).map { o + dir * (len * Float($0) / Float(n - 1)) }
        return ProcGeo(P: P, prims: [(0..<Int32(n)).map { $0 }], closed: [false])
    }

    static func add(_ c: ProcCook) -> ProcGeo {
        var g = c.inputs.first.flatMap { $0 } ?? ProcGeo()
        let pts = c.param("points").points
        let first = Int32(g.pointCount)
        g.P += pts
        g.syncCounts()
        let connect = c.string("connect")
        if connect != "none", pts.count >= 2 {
            g.addPrim((0..<Int32(pts.count)).map { first + $0 }, closed: connect == "closed" && pts.count >= 3)
        }
        return g
    }

    static func file(_ c: ProcCook) throws -> ProcGeo {
        let name = c.string("file")
        guard !name.isEmpty else { throw ProcCookError("No geometry named: set mesh:<slug> or object:<name>") }
        guard let g = c.environment.file(name) else { throw ProcCookError("Can't read \(name)") }
        return g
    }
}
