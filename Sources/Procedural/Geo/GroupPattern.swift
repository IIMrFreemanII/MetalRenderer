import Foundation
import simd

/// A node's group field, as Houdini's: space-separated parts, each adding to what it picks or, after `^` or `!`,
/// taking away from it. A part is
/// - `*` (everything), or a group name, with `*` and `?` wildcards (`side*`);
/// - an element number `7` or a range `0-9`, with a step `0-9:2`;
/// - an attribute test `@name==1`, `@P.y>0.5`, `@Cd.x<=0.2`, `@name!=wall` (`=`, `==`, `!=`, `<`, `>`, `<=`, `>=`).
/// An empty field picks everything.
package enum GroupPattern {
    package struct Failure: Error, CustomStringConvertible {
        package var description: String
    }

    /// Which elements of class `c` the pattern picks.
    package static func evaluate(_ pattern: String, in geo: ProcGeo, _ c: AttributeClass) throws -> [Bool] {
        let n = geo.count(c)
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [Bool](repeating: true, count: n) }
        let table = geo.table(c)
        var picked = [Bool](repeating: false, count: n)
        for raw in trimmed.split(separator: " ") {
            var token = Substring(raw)
            var remove = false
            if token.first == "^" || token.first == "!" { remove = true; token = token.dropFirst() }
            let part = try pick(String(token), table: table, geo: geo, c, n)
            for i in 0..<n where part[i] { picked[i] = !remove }
        }
        return picked
    }

    /// Does the field pick everything (so a node needn't evaluate it)?
    package static func isEverything(_ pattern: String) -> Bool {
        let t = pattern.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "*"
    }

    private static func pick(_ token: String, table: AttributeTable, geo: ProcGeo, _ c: AttributeClass, _ n: Int) throws -> [Bool] {
        if token == "*" { return [Bool](repeating: true, count: n) }
        if token.hasPrefix("@") { return try test(String(token.dropFirst()), table: table, geo: geo, c, n) }
        if let first = token.first, first.isNumber { return try range(token, n) }
        var out = [Bool](repeating: false, count: n)
        for g in table.groups where globMatches(token, g.name) {
            for i in 0..<n where g.members[i] { out[i] = true }
        }
        return out
    }

    private static func range(_ token: String, _ n: Int) throws -> [Bool] {
        var out = [Bool](repeating: false, count: n)
        let stepParts = token.split(separator: ":")
        let step = stepParts.count > 1 ? max(1, Int(stepParts[1]) ?? 1) : 1
        let ends = stepParts[0].split(separator: "-")
        guard let a = Int(ends[0]) else { throw Failure(description: "\"\(token)\" isn't a number or a range") }
        let b = ends.count > 1 ? (Int(ends[1]) ?? a) : a
        var i = min(a, b)
        while i <= max(a, b) {
            if i >= 0 && i < n { out[i] = true }
            i += step
        }
        return out
    }

    private static let operators = ["==", "!=", "<=", ">=", "=", "<", ">"]

    private static func test(_ expr: String, table: AttributeTable, geo: ProcGeo, _ c: AttributeClass, _ n: Int) throws -> [Bool] {
        guard let op = operators.first(where: { expr.contains($0) }), let r = expr.range(of: op) else {
            throw Failure(description: "\"@\(expr)\" has no comparison (==, !=, <, >, <=, >=)")
        }
        var name = String(expr[..<r.lowerBound])
        let rhs = String(expr[r.upperBound...])
        var component = 0
        if let dot = name.firstIndex(of: ".") {
            let comp = name[name.index(after: dot)...]
            component = ["x": 0, "y": 1, "z": 2, "w": 3, "r": 0, "g": 1, "b": 2, "a": 3][String(comp)] ?? Int(comp) ?? 0
            name = String(name[..<dot])
        }
        let values: AttributeValues
        if name == "P" && c == .point {
            values = .vector3(geo.P)
        } else if name == "ptnum" || name == "primnum" || name == "vtxnum" {
            values = .int((0..<n).map { Int32($0) })
        } else if let v = table[name] {
            values = v
        } else {
            throw Failure(description: "no \(c.rawValue) attribute \"\(name)\"")
        }
        var out = [Bool](repeating: false, count: n)
        if case .string = values {
            for i in 0..<n {
                let s = values.string(i)
                switch op {
                case "==", "=": out[i] = globMatches(rhs, s)
                case "!=": out[i] = !globMatches(rhs, s)
                default: out[i] = false
                }
            }
            return out
        }
        guard let k = Float(rhs) else { throw Failure(description: "\"\(rhs)\" isn't a number") }
        for i in 0..<n {
            let v = values.component(i, component)
            switch op {
            case "==", "=": out[i] = abs(v - k) <= 1e-5 * max(1, abs(k))
            case "!=": out[i] = abs(v - k) > 1e-5 * max(1, abs(k))
            case "<": out[i] = v < k
            case ">": out[i] = v > k
            case "<=": out[i] = v <= k
            default: out[i] = v >= k
            }
        }
        return out
    }

    /// Points a primitive pick makes (every point of a picked primitive), or primitives a point pick makes (those whose
    /// points are all picked).
    package static func points(ofPrims picked: [Bool], in geo: ProcGeo) -> [Bool] {
        var out = [Bool](repeating: false, count: geo.pointCount)
        for p in 0..<geo.primCount where picked[p] { for v in geo.vertexRange(p) { out[Int(geo.vertexPoint[v])] = true } }
        return out
    }

    package static func prims(ofPoints picked: [Bool], in geo: ProcGeo) -> [Bool] {
        (0..<geo.primCount).map { p in
            let r = geo.vertexRange(p)
            return !r.isEmpty && r.allSatisfy { picked[Int(geo.vertexPoint[$0])] }
        }
    }
}

/// Points in a uniform grid of cells, for nearest-point and radius queries (fuse, attribute transfer, relax).
package struct PointGrid {
    private let cell: Float
    private let origin: SIMD3<Float>
    private var order: [Int32] = []
    private var cells: [UInt64: Range<Int>] = [:]
    private let points: [SIMD3<Float>]

    /// A grid over `points`; `cell` 0 picks one from their spread (about two points a cell).
    package init(_ points: [SIMD3<Float>], cell: Float = 0) {
        self.points = points
        var b = (lo: SIMD3<Float>(repeating: .infinity), hi: SIMD3<Float>(repeating: -.infinity))
        for p in points { b.lo = simd_min(b.lo, p); b.hi = simd_max(b.hi, p) }
        if points.isEmpty { b = (.zero, .zero) }
        origin = b.lo
        if cell > 0 {
            self.cell = cell
        } else {
            let e = simd_max(b.hi - b.lo, SIMD3(repeating: 1e-4))
            // Cells sized so the points' box holds about half as many cells as points (a flat set: by its area).
            let dims = [e.x, e.y, e.z].sorted()
            let flat = dims[0] < dims[2] * 1e-3
            let size = flat ? sqrt(dims[1] * dims[2] * 2 / Float(max(1, points.count)))
                            : cbrt(e.x * e.y * e.z * 2 / Float(max(1, points.count)))
            self.cell = max(size, 1e-5)
        }
        var keyed = points.indices.map { (key: key(coords(points[$0])), index: Int32($0)) }
        keyed.sort { $0.key < $1.key }
        order = keyed.map(\.index)
        var i = 0
        while i < keyed.count {
            var j = i
            while j < keyed.count && keyed[j].key == keyed[i].key { j += 1 }
            cells[keyed[i].key] = i..<j
            i = j
        }
    }

    @inline(__always) private func coords(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(((p - origin) / cell).rounded(.down))
    }

    @inline(__always) private func key(_ c: SIMD3<Int32>) -> UInt64 {
        UInt64(UInt32(bitPattern: c.x &+ (1 << 20)) & 0x1F_FFFF) << 42
            | UInt64(UInt32(bitPattern: c.y &+ (1 << 20)) & 0x1F_FFFF) << 21
            | UInt64(UInt32(bitPattern: c.z &+ (1 << 20)) & 0x1F_FFFF)
    }

    /// The nearest point to `p` (-1 if there are none or none within `maxDistance`), skipping `except`.
    package func nearest(_ p: SIMD3<Float>, maxDistance: Float = .infinity, except: Int32 = -1) -> Int32 {
        guard !points.isEmpty else { return -1 }
        let c = coords(p)
        var best: Int32 = -1, bestD = maxDistance * maxDistance
        var ring: Int32 = 0
        let limit = maxDistance.isFinite ? Int32(min(Float(1 << 19), (maxDistance / cell).rounded(.up))) + 1 : Int32(1 << 19)
        while ring <= limit {
            // The shell of cells `ring` away.
            for dx in -ring...ring { for dy in -ring...ring { for dz in -ring...ring
                where max(abs(dx), abs(dy), abs(dz)) == ring {
                guard let r = cells[key(c &+ SIMD3(dx, dy, dz))] else { continue }
                for k in r {
                    let i = order[k]
                    if i == except { continue }
                    let d = simd_distance_squared(points[Int(i)], p)
                    if d < bestD || (d == bestD && best >= 0 && i < best) { bestD = d; best = i }
                }
            } } }
            // Done once the next shell is farther than the best.
            if best >= 0 {
                let reach = Float(ring) * cell
                if reach * reach >= bestD { break }
            }
            ring += 1
            if ring > 3 && best < 0 && !maxDistance.isFinite {   // far from every point: look at all of them
                for (i, q) in points.enumerated() where Int32(i) != except {
                    let d = simd_distance_squared(q, p)
                    if d < bestD { bestD = d; best = Int32(i) }
                }
                break
            }
        }
        return best
    }

    /// Every point within `radius` of `p`, into `out` (cleared first).
    package func within(_ p: SIMD3<Float>, radius: Float, into out: inout [Int32]) {
        out.removeAll(keepingCapacity: true)
        let lo = coords(p - radius), hi = coords(p + radius)
        let r2 = radius * radius
        for x in lo.x...hi.x { for y in lo.y...hi.y { for z in lo.z...hi.z {
            guard let r = cells[key(SIMD3(x, y, z))] else { continue }
            for k in r where simd_distance_squared(points[Int(order[k])], p) <= r2 { out.append(order[k]) }
        } } }
    }
}
