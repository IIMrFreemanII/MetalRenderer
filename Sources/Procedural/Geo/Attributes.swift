import Foundation
import simd

/// Where an attribute lives, as Houdini's classes: one value per point, per vertex (a corner of a primitive), per
/// primitive, or one for the whole geometry (the detail).
package enum AttributeClass: String, Codable, CaseIterable, Identifiable {
    case point, vertex, primitive, detail
    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .point: "Points"
        case .vertex: "Vertices"
        case .primitive: "Primitives"
        case .detail: "Detail"
        }
    }
}

/// An attribute's type: a float, an integer, a vector of 2, 3 or 4 floats, or a string.
package enum AttributeType: String, Codable, CaseIterable, Identifiable {
    case float, int, vector2, vector3, vector4, string
    package var id: String { rawValue }

    package var components: Int {
        switch self {
        case .float, .int, .string: 1
        case .vector2: 2
        case .vector3: 3
        case .vector4: 4
        }
    }

    /// Houdini's prefix for the type in a wrangle (`f@mass`, `v@up`).
    package var prefix: String {
        switch self {
        case .float: "f"
        case .int: "i"
        case .vector2: "u"
        case .vector3: "v"
        case .vector4: "p"
        case .string: "s"
        }
    }
}

/// One attribute's values: a flat array of its type. Strings are indices into a table of the distinct ones, whose
/// first entry is the empty string (so a new row's zero index is "").
package enum AttributeValues: Equatable {
    case float([Float])
    case int([Int32])
    case vector2([SIMD2<Float>])
    case vector3([SIMD3<Float>])
    case vector4([SIMD4<Float>])
    case string([Int32], table: [String])

    package var type: AttributeType {
        switch self {
        case .float: .float
        case .int: .int
        case .vector2: .vector2
        case .vector3: .vector3
        case .vector4: .vector4
        case .string: .string
        }
    }

    package var count: Int {
        switch self {
        case .float(let a): a.count
        case .int(let a): a.count
        case .vector2(let a): a.count
        case .vector3(let a): a.count
        case .vector4(let a): a.count
        case .string(let a, _): a.count
        }
    }

    /// `count` rows of the type's default (zero, the empty string).
    package static func zeros(_ type: AttributeType, count: Int) -> AttributeValues {
        filled(type, count: count, with: .zero, string: "")
    }

    /// `count` rows of one value: a float or int type takes `value.x`, a vector its first components.
    package static func filled(_ type: AttributeType, count: Int, with value: SIMD4<Float>, string: String = "") -> AttributeValues {
        switch type {
        case .float: .float([Float](repeating: value.x, count: count))
        case .int: .int([Int32](repeating: Int32(value.x.rounded()), count: count))
        case .vector2: .vector2([SIMD2<Float>](repeating: SIMD2(value.x, value.y), count: count))
        case .vector3: .vector3([SIMD3<Float>](repeating: SIMD3(value.x, value.y, value.z), count: count))
        case .vector4: .vector4([SIMD4<Float>](repeating: value, count: count))
        case .string:
            string.isEmpty ? .string([Int32](repeating: 0, count: count), table: [""])
                           : .string([Int32](repeating: 1, count: count), table: ["", string])
        }
    }

    /// The rows `rows` names, in its order; a row of -1 is the default.
    package func gathered(_ rows: [Int32]) -> AttributeValues {
        switch self {
        case .float(let a): .float(gather(a, rows, 0))
        case .int(let a): .int(gather(a, rows, 0))
        case .vector2(let a): .vector2(gather(a, rows, .zero))
        case .vector3(let a): .vector3(gather(a, rows, .zero))
        case .vector4(let a): .vector4(gather(a, rows, .zero))
        case .string(let a, let t): .string(gather(a, rows, 0), table: t)
        }
    }

    /// Rows made of others: row `r` is the sum of `weights[k] * self[sources[k]]` over `k` in `start[r]..<start[r+1]`.
    /// An integer or a string takes the value of the source with the largest weight.
    package func blended(start: [Int32], sources: [Int32], weights: [Float]) -> AttributeValues {
        switch self {
        case .float(let a): .float(blend(a, start, sources, weights))
        case .vector2(let a): .vector2(blend(a, start, sources, weights))
        case .vector3(let a): .vector3(blend(a, start, sources, weights))
        case .vector4(let a): .vector4(blend(a, start, sources, weights))
        case .int, .string:
            gathered(AttributeValues.strongest(start: start, sources: sources, weights: weights))
        }
    }

    static func strongest(start: [Int32], sources: [Int32], weights: [Float]) -> [Int32] {
        var rows = [Int32](repeating: -1, count: max(0, start.count - 1))
        for r in 0..<rows.count {
            var best: Float = -.infinity
            for k in Int(start[r])..<Int(start[r + 1]) where weights[k] > best {
                best = weights[k]
                rows[r] = sources[k]
            }
        }
        return rows
    }

    /// Another attribute's rows after this one's: of the same type, else converted to it.
    ///
    /// Each case (here and in the setters) takes its array out of `self` before changing it (`self = .placeholder`):
    /// otherwise `self` still holds it, and every call copies the whole column (quadratic in a merge loop, or row by
    /// row in an unoptimised build).
    package mutating func append(_ other: AttributeValues) {
        let o = other.type == type ? other : other.converted(to: type)
        switch self {
        case .float(var a): self = .placeholder; if case .float(let b) = o { a += b }; self = .float(a)
        case .int(var a): self = .placeholder; if case .int(let b) = o { a += b }; self = .int(a)
        case .vector2(var a): self = .placeholder; if case .vector2(let b) = o { a += b }; self = .vector2(a)
        case .vector3(var a): self = .placeholder; if case .vector3(let b) = o { a += b }; self = .vector3(a)
        case .vector4(var a): self = .placeholder; if case .vector4(let b) = o { a += b }; self = .vector4(a)
        case .string(var a, var t):
            self = .placeholder
            guard case .string(let b, let u) = o else { self = .string(a, table: t); return }
            // The other's table's strings into this one's.
            var map = [Int32](repeating: 0, count: u.count)
            var index = [String: Int32](uniqueKeysWithValues: t.enumerated().map { ($1, Int32($0)) })
            for (i, s) in u.enumerated() {
                if let k = index[s] { map[i] = k } else { index[s] = Int32(t.count); map[i] = Int32(t.count); t.append(s) }
            }
            a.reserveCapacity(a.count + b.count)
            for v in b { a.append(map[Int(v)]) }
            self = .string(a, table: t)
        }
    }

    /// An empty value `self` holds while a case's array is out of it.
    private static var placeholder: AttributeValues { .int([]) }

    /// `n` more rows of the default.
    package mutating func appendDefaults(_ n: Int) {
        guard n > 0 else { return }
        append(AttributeValues.zeros(type, count: n))
    }

    /// The values as another type: numbers pad or drop components, strings parse (or print) numbers.
    package func converted(to t: AttributeType) -> AttributeValues {
        if t == type { return self }
        let n = count
        if t == .string {
            var table = [""], index = ["": Int32(0)], rows = [Int32](repeating: 0, count: n)
            for r in 0..<n {
                let s = string(r)
                if let k = index[s] { rows[r] = k } else { index[s] = Int32(table.count); rows[r] = Int32(table.count); table.append(s) }
            }
            return .string(rows, table: table)
        }
        // As `set(_:_:)` writes each row of `vector(_:)`, a whole column at a time.
        switch t {
        case .float: return .float(mapped { $0.x })
        case .int: return .int(mapped { Int32($0.x.rounded()) })
        case .vector2: return .vector2(mapped { SIMD2($0.x, $0.y) })
        case .vector3: return .vector3(mapped { SIMD3($0.x, $0.y, $0.z) })
        case .vector4: return .vector4(mapped { $0 })
        case .string: fatalError("handled above")
        }
    }

    /// `f` of every row as `vector(_:)` gives it (a string table's numbers parsed once).
    private func mapped<T>(_ f: (SIMD4<Float>) -> T) -> [T] {
        switch self {
        case .float(let a): return a.map { f(SIMD4($0, 0, 0, 0)) }
        case .int(let a): return a.map { f(SIMD4(Float($0), 0, 0, 0)) }
        case .vector2(let a): return a.map { f(SIMD4($0.x, $0.y, 0, 0)) }
        case .vector3(let a): return a.map { f(SIMD4($0.x, $0.y, $0.z, 0)) }
        case .vector4(let a): return a.map(f)
        case .string(let a, let t):
            let parsed = t.map { SIMD4<Float>(Float($0) ?? 0, 0, 0, 0) }
            return a.map { f(parsed[Int($0)]) }
        }
    }

    /// The rows `rows` marks negative taken from `other` (of as many rows), as `set(i, other.vector(i))` would.
    package mutating func fill(_ rows: [Int32], from other: AttributeValues) {
        if type == .string {
            for i in 0..<rows.count where rows[i] < 0 { set(i, other.vector(i)) }
            return
        }
        let o = other.type == type ? other : other.converted(to: type)
        switch self {
        case .float(var a): self = .placeholder; if case .float(let b) = o { fillRows(&a, rows, b) }; self = .float(a)
        case .int(var a): self = .placeholder; if case .int(let b) = o { fillRows(&a, rows, b) }; self = .int(a)
        case .vector2(var a): self = .placeholder; if case .vector2(let b) = o { fillRows(&a, rows, b) }; self = .vector2(a)
        case .vector3(var a): self = .placeholder; if case .vector3(let b) = o { fillRows(&a, rows, b) }; self = .vector3(a)
        case .vector4(var a): self = .placeholder; if case .vector4(let b) = o { fillRows(&a, rows, b) }; self = .vector4(a)
        case .string: break
        }
    }

    // MARK: Rows, one at a time (the spreadsheet, patterns, tests: not loops over many)

    /// Row `r` as four floats (a string: its number, if it is one).
    package func vector(_ r: Int) -> SIMD4<Float> {
        switch self {
        case .float(let a): SIMD4(a[r], 0, 0, 0)
        case .int(let a): SIMD4(Float(a[r]), 0, 0, 0)
        case .vector2(let a): SIMD4(a[r].x, a[r].y, 0, 0)
        case .vector3(let a): SIMD4(a[r].x, a[r].y, a[r].z, 0)
        case .vector4(let a): a[r]
        case .string(let a, let t): SIMD4(Float(t[Int(a[r])]) ?? 0, 0, 0, 0)
        }
    }

    package func component(_ r: Int, _ c: Int) -> Float { vector(r)[min(c, 3)] }

    package func string(_ r: Int) -> String {
        switch self {
        case .string(let a, let t): return t[Int(a[r])]
        case .int(let a): return String(a[r])
        default:
            let v = vector(r)
            let n = type.components
            return (0..<n).map { String(format: "%g", v[$0]) }.joined(separator: n > 1 ? ", " : "")
        }
    }

    /// Sets row `r` from four floats (a string: its printed number).
    package mutating func set(_ r: Int, _ v: SIMD4<Float>) {
        switch self {
        case .float(var a): self = .placeholder; a[r] = v.x; self = .float(a)
        case .int(var a): self = .placeholder; a[r] = Int32(v.x.rounded()); self = .int(a)
        case .vector2(var a): self = .placeholder; a[r] = SIMD2(v.x, v.y); self = .vector2(a)
        case .vector3(var a): self = .placeholder; a[r] = SIMD3(v.x, v.y, v.z); self = .vector3(a)
        case .vector4(var a): self = .placeholder; a[r] = v; self = .vector4(a)
        case .string: setString(r, String(format: "%g", v.x))
        }
    }

    package mutating func setString(_ r: Int, _ s: String) {
        guard case .string(var a, var t) = self else { set(r, SIMD4(Float(s) ?? 0, 0, 0, 0)); return }
        self = .placeholder
        if let k = t.firstIndex(of: s) { a[r] = Int32(k) } else { a[r] = Int32(t.count); t.append(s) }
        self = .string(a, table: t)
    }

    package var byteSize: Int {
        switch self {
        case .float(let a): a.count * 4
        case .int(let a): a.count * 4
        case .vector2(let a): a.count * 8
        case .vector3(let a): a.count * 16
        case .vector4(let a): a.count * 16
        case .string(let a, let t): a.count * 4 + t.reduce(0) { $0 + $1.utf8.count + 16 }
        }
    }
}

@inline(__always) func fillRows<T>(_ a: inout [T], _ rows: [Int32], _ b: [T]) {
    a.withUnsafeMutableBufferPointer { a in
        for i in 0..<rows.count where rows[i] < 0 { a[i] = b[i] }
    }
}

@inline(__always) func gather<T>(_ a: [T], _ rows: [Int32], _ empty: T) -> [T] {
    [T](unsafeUninitializedCapacity: rows.count) { out, n in
        a.withUnsafeBufferPointer { src in
            rows.withUnsafeBufferPointer { idx in
                for i in 0..<idx.count {
                    let r = Int(idx[i])
                    (out.baseAddress! + i).initialize(to: r >= 0 ? src[r] : empty)
                }
            }
        }
        n = rows.count
    }
}

@inline(__always) func blend<T: SIMD>(_ a: [T], _ start: [Int32], _ sources: [Int32], _ weights: [Float]) -> [T] where T.Scalar == Float {
    let rows = max(0, start.count - 1)
    return [T](unsafeUninitializedCapacity: rows) { out, n in
        a.withUnsafeBufferPointer { src in
            for r in 0..<rows {
                var v = T()
                for k in Int(start[r])..<Int(start[r + 1]) { v += src[Int(sources[k])] * weights[k] }
                (out.baseAddress! + r).initialize(to: v)
            }
        }
        n = rows
    }
}

@inline(__always) func blend(_ a: [Float], _ start: [Int32], _ sources: [Int32], _ weights: [Float]) -> [Float] {
    let rows = max(0, start.count - 1)
    return [Float](unsafeUninitializedCapacity: rows) { out, n in
        a.withUnsafeBufferPointer { src in
            for r in 0..<rows {
                var v: Float = 0
                for k in Int(start[r])..<Int(start[r + 1]) { v += src[Int(sources[k])] * weights[k] }
                (out.baseAddress! + r).initialize(to: v)
            }
        }
        n = rows
    }
}

/// A named attribute of a class.
package struct Attribute: Equatable {
    package var name: String
    package var values: AttributeValues
}

/// A named group of a class: a flag per row.
package struct ElementGroup: Equatable {
    package var name: String
    package var members: [Bool]
}

/// One class's attributes and groups, every one `count` rows long, in the order they were made. Nodes look a column
/// up by name once and loop over its array.
package struct AttributeTable: Equatable {
    package private(set) var count: Int
    package private(set) var attributes: [Attribute] = []
    package private(set) var groups: [ElementGroup] = []

    package init(count: Int = 0) { self.count = count }

    package var names: [String] { attributes.map(\.name) }
    package var groupNames: [String] { groups.map(\.name) }
    package var isEmpty: Bool { attributes.isEmpty && groups.isEmpty }

    package func index(of name: String) -> Int? { attributes.firstIndex { $0.name == name } }
    package subscript(_ name: String) -> AttributeValues? { index(of: name).map { attributes[$0].values } }

    /// Sets (or makes) an attribute; its values must be `count` long.
    package mutating func set(_ name: String, _ values: AttributeValues) {
        precondition(values.count == count, "attribute \(name): \(values.count) values for \(count) rows")
        if let i = index(of: name) { attributes[i].values = values } else { attributes.append(Attribute(name: name, values: values)) }
    }

    package mutating func remove(_ name: String) { attributes.removeAll { $0.name == name } }

    package mutating func rename(_ name: String, to new: String) {
        guard name != new, let i = index(of: name) else { return }
        var a = attributes.remove(at: i)
        a.name = new
        remove(new)
        attributes.insert(a, at: min(i, attributes.count))
    }

    // Typed reads.
    package func floats(_ name: String) -> [Float]? { if case .float(let a)? = self[name] { return a }; return nil }
    package func ints(_ name: String) -> [Int32]? { if case .int(let a)? = self[name] { return a }; return nil }
    package func vectors2(_ name: String) -> [SIMD2<Float>]? { if case .vector2(let a)? = self[name] { return a }; return nil }
    package func vectors3(_ name: String) -> [SIMD3<Float>]? { if case .vector3(let a)? = self[name] { return a }; return nil }
    package func vectors4(_ name: String) -> [SIMD4<Float>]? { if case .vector4(let a)? = self[name] { return a }; return nil }

    // MARK: Groups

    package func group(_ name: String) -> [Bool]? { groups.first { $0.name == name }?.members }

    package mutating func setGroup(_ name: String, _ members: [Bool]) {
        precondition(members.count == count, "group \(name): \(members.count) flags for \(count) rows")
        if let i = groups.firstIndex(where: { $0.name == name }) { groups[i].members = members } else { groups.append(ElementGroup(name: name, members: members)) }
    }

    package mutating func removeGroup(_ name: String) { groups.removeAll { $0.name == name } }

    // MARK: Rows

    /// The rows `rows` names (-1: defaults): what deleting, sorting and copying do.
    package func gathered(_ rows: [Int32]) -> AttributeTable {
        var t = AttributeTable(count: rows.count)
        t.attributes = attributes.map { Attribute(name: $0.name, values: $0.values.gathered(rows)) }
        t.groups = groups.map { g in ElementGroup(name: g.name, members: gather(g.members, rows, false)) }
        return t
    }

    /// Rows made of weighted others (`AttributeValues.blended`); a group takes its strongest source's flag.
    package func blended(start: [Int32], sources: [Int32], weights: [Float]) -> AttributeTable {
        var t = AttributeTable(count: max(0, start.count - 1))
        t.attributes = attributes.map { Attribute(name: $0.name, values: $0.values.blended(start: start, sources: sources, weights: weights)) }
        if !groups.isEmpty {
            let rows = AttributeValues.strongest(start: start, sources: sources, weights: weights)
            t.groups = groups.map { ElementGroup(name: $0.name, members: gather($0.members, rows, false)) }
        }
        return t
    }

    /// Another table's rows after these: attributes of both kept (the rows of one that the other lacks are defaults).
    package mutating func append(_ other: AttributeTable) {
        let before = count
        for a in other.attributes where index(of: a.name) == nil {
            attributes.append(Attribute(name: a.name, values: .zeros(a.values.type, count: before)))
        }
        for i in attributes.indices {
            if let o = other[attributes[i].name] { attributes[i].values.append(o) } else { attributes[i].values.appendDefaults(other.count) }
        }
        for g in other.groups where group(g.name) == nil { groups.append(ElementGroup(name: g.name, members: [Bool](repeating: false, count: before))) }
        for i in groups.indices {
            groups[i].members += other.group(groups[i].name) ?? [Bool](repeating: false, count: other.count)
        }
        count += other.count
    }

    /// Grows (defaults) or cuts the rows to `n`.
    package mutating func resize(_ n: Int) {
        guard n != count else { return }
        if n > count {
            for i in attributes.indices { attributes[i].values.appendDefaults(n - count) }
            for i in groups.indices { groups[i].members += [Bool](repeating: false, count: n - count) }
        } else {
            let rows = (0..<n).map { Int32($0) }
            self = gathered(rows)
        }
        count = n
    }

    /// Only the attributes (and groups) whose names pass `keep`.
    package mutating func filter(_ keep: (String) -> Bool) {
        attributes.removeAll { !keep($0.name) }
        groups.removeAll { !keep($0.name) }
    }

    package var byteSize: Int { attributes.reduce(0) { $0 + $1.values.byteSize } + groups.reduce(0) { $0 + $1.members.count } }
}

/// Matches a name against a pattern of space-separated globs (`*`, `?`), with `^name` taking matches away again:
/// Houdini's attribute and group name patterns.
package func namePatternMatches(_ pattern: String, _ name: String) -> Bool {
    var hit = false
    for token in pattern.split(separator: " ") {
        if token.hasPrefix("^") || token.hasPrefix("!") {
            if globMatches(String(token.dropFirst()), name) { hit = false }
        } else if globMatches(String(token), name) {
            hit = true
        }
    }
    return hit
}

package func globMatches(_ glob: String, _ s: String) -> Bool {
    let g = Array(glob.utf8), t = Array(s.utf8)
    var gi = 0, ti = 0, star = -1, mark = 0
    while ti < t.count {
        if gi < g.count && (g[gi] == UInt8(ascii: "?") || g[gi] == t[ti]) {
            gi += 1; ti += 1
        } else if gi < g.count && g[gi] == UInt8(ascii: "*") {
            star = gi; mark = ti; gi += 1
        } else if star >= 0 {
            gi = star + 1; mark += 1; ti = mark
        } else {
            return false
        }
    }
    while gi < g.count && g[gi] == UInt8(ascii: "*") { gi += 1 }
    return gi == g.count
}
