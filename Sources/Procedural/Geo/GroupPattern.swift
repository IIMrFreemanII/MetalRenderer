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
///
/// The cells that hold points are an open-addressed table, a power of two long (no Dictionary: a query reads a few
/// dozen cells, and relaxing a million points asks a hundred million times).
package struct PointGrid {
    private let cell: Float
    private let origin: SIMD3<Float>
    private var order: [Int32] = []
    /// Each slot's cell key (`PointGrid.empty`: none) and its run of `order`.
    private var slotKey: [UInt64] = []
    private var slotStart: [Int32] = []
    private var slotEnd: [Int32] = []
    private var shift: UInt64 = 61
    private let points: [SIMD3<Float>]
    private static let empty = UInt64.max   // (a key has 63 bits)

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
        // The points by cell, those of a cell in their own order.
        var keyed = [(key: UInt64, index: Int32)](unsafeUninitializedCapacity: points.count) { out, n in
            for i in 0..<points.count { (out.baseAddress! + i).initialize(to: (key(coords(points[i])), Int32(i))) }
            n = points.count
        }
        keyed.sort { $0.key != $1.key ? $0.key < $1.key : $0.index < $1.index }
        order = keyed.map(\.index)
        var cells = 0
        for i in keyed.indices where i == 0 || keyed[i].key != keyed[i - 1].key { cells += 1 }
        var bits: UInt64 = 3
        while (1 << bits) < cells * 2 { bits += 1 }
        shift = 64 - bits
        let size = 1 << Int(bits)
        slotKey = [UInt64](repeating: PointGrid.empty, count: size)
        slotStart = [Int32](repeating: 0, count: size)
        slotEnd = [Int32](repeating: 0, count: size)
        var i = 0
        while i < keyed.count {
            var j = i
            while j < keyed.count && keyed[j].key == keyed[i].key { j += 1 }
            let s = slot(keyed[i].key)
            slotKey[s] = keyed[i].key
            slotStart[s] = Int32(i)
            slotEnd[s] = Int32(j)
            i = j
        }
    }

    @inline(__always) private func coords(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        let f = ((p - origin) / cell).rounded(.down)
        return SIMD3(Int32(f.x), Int32(f.y), Int32(f.z))   // (SIMD3's own conversion isn't specialised: 10× slower)
    }

    @inline(__always) private func key(_ c: SIMD3<Int32>) -> UInt64 {
        UInt64(UInt32(bitPattern: c.x &+ (1 << 20)) & 0x1F_FFFF) << 42
            | UInt64(UInt32(bitPattern: c.y &+ (1 << 20)) & 0x1F_FFFF) << 21
            | UInt64(UInt32(bitPattern: c.z &+ (1 << 20)) & 0x1F_FFFF)
    }

    /// The slot of `key`: where it is, or the empty one it would go in.
    @inline(__always) private func slot(_ key: UInt64) -> Int {
        let mask = slotKey.count - 1
        var s = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> shift) & mask
        while slotKey[s] != key && slotKey[s] != PointGrid.empty { s = (s + 1) & mask }
        return s
    }

    /// The grid's arrays as buffers, for the queries that look at many cells: no retain, release or exclusivity check
    /// per cell (unoptimised, those were most of a query, and every core contended for the same counts).
    private struct Tables {
        let order, starts, ends: UnsafeBufferPointer<Int32>
        let points: UnsafeBufferPointer<SIMD3<Float>>
        let keys: UnsafeBufferPointer<UInt64>
        let shift: UInt64

        /// The run of `order` in the cell of `key` (empty if it has no points), found as `slot` finds it.
        @inline(__always) func run(_ key: UInt64) -> (start: Int, end: Int) {
            let mask = keys.count - 1, empty = UInt64.max   // (PointGrid.empty)
            var s = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> shift) & mask
            while keys[s] != key && keys[s] != empty { s = (s + 1) & mask }
            return (Int(starts[s]), Int(ends[s]))
        }
    }

    @inline(__always) private func withTables<R>(_ body: (Tables) -> R) -> R {
        order.withUnsafeBufferPointer { order in
        points.withUnsafeBufferPointer { points in
        slotKey.withUnsafeBufferPointer { keys in
        slotStart.withUnsafeBufferPointer { starts in
        slotEnd.withUnsafeBufferPointer { ends in
            body(Tables(order: order, starts: starts, ends: ends, points: points, keys: keys, shift: shift))
        } } } } }
    }

    /// The nearest point to `p` (-1 if there are none or none within `maxDistance`), skipping `except`.
    package func nearest(_ p: SIMD3<Float>, maxDistance: Float = .infinity, except: Int32 = -1) -> Int32 {
        guard !points.isEmpty else { return -1 }
        let c = coords(p), cell = cell
        let limit = maxDistance.isFinite ? Int32(min(Float(1 << 19), (maxDistance / cell).rounded(.up))) + 1 : Int32(1 << 19)
        return withTables { t in
        var best: Int32 = -1, bestD = maxDistance * maxDistance
        var ring: Int32 = 0
        while ring <= limit {
            // The shell of cells `ring` away.
            var dx = -ring
            while dx <= ring {
                var dy = -ring
                while dy <= ring {
                    var dz = -ring
                    while dz <= ring {
                        // (Inside the shell: only its two faces along z.)
                        if max(abs(dx), abs(dy), abs(dz)) == ring {
                            var (k, end) = t.run(key(c &+ SIMD3(dx, dy, dz)))
                            while k < end {
                                let i = t.order[k]
                                k += 1
                                if i == except { continue }
                                let d = simd_distance_squared(t.points[Int(i)], p)
                                if d < bestD || (d == bestD && best >= 0 && i < best) { bestD = d; best = i }
                            }
                        }
                        dz += abs(dx) == ring || abs(dy) == ring || dz == ring ? 1 : 2 * ring
                    }
                    dy += 1
                }
                dx += 1
            }
            // Done once the next shell is farther than the best.
            if best >= 0 {
                let reach = Float(ring) * cell
                if reach * reach >= bestD { break }
            }
            ring += 1
            if ring > 3 && best < 0 && !maxDistance.isFinite {   // far from every point: look at all of them
                var i = 0
                while i < t.points.count {
                    let d = simd_distance_squared(t.points[i], p)
                    if Int32(i) != except && d < bestD { bestD = d; best = Int32(i) }
                    i += 1
                }
                break
            }
        }
        return best
        }
    }

    /// Calls `body` with every point within `radius` of `p` (by cell, x then y then z, each cell's in their order).
    @inline(__always) package func forEach(within radius: Float, of p: SIMD3<Float>, _ body: (Int32) -> Void) {
        let lo = coords(p - radius), hi = coords(p + radius)
        let r2 = radius * radius
        withTables { t in
            var x = lo.x
            while x <= hi.x {
                var y = lo.y
                while y <= hi.y {
                    var z = lo.z
                    while z <= hi.z {
                        var (k, end) = t.run(key(SIMD3(x, y, z)))
                        while k < end {
                            let i = t.order[k]
                            if simd_distance_squared(t.points[Int(i)], p) <= r2 { body(i) }
                            k += 1
                        }
                        z += 1
                    }
                    y += 1
                }
                x += 1
            }
        }
    }

    /// Every point within `radius` of `p`, into `out` (cleared first).
    package func within(_ p: SIMD3<Float>, radius: Float, into out: inout [Int32]) {
        out.removeAll(keepingCapacity: true)
        forEach(within: radius, of: p) { out.append($0) }
    }
}
