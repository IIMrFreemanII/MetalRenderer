import Foundation
import simd

/// The nodes that make and change attributes, and the group nodes.
enum AttributeNodes {
    /// Where each element of a class is: a point's P, a vertex's point's, a primitive's centre, the detail's the
    /// geometry's centre.
    static func positions(_ g: ProcGeo, _ c: AttributeClass) -> [SIMD3<Float>] {
        switch c {
        case .point: g.P
        case .vertex: g.vertexPoint.map { g.P[Int($0)] }
        case .primitive: (0..<g.primCount).map { g.primCenter($0) }
        case .detail: [g.bounds.isEmpty ? .zero : g.bounds.centroid]
        }
    }

    static func attribcreate(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let name = c.string("name").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ProcCookError("No attribute name") }
        let cls = c.attributeClass()
        let type = AttributeType(rawValue: c.string("type")) ?? .float
        let n = g.count(cls)
        let picked = cls == .detail ? [true] : try c.group(in: g, cls)
        // Per element when its expressions say so ($PT, @P).
        let each = type == .string ? nil : try c.elementValues("value", in: g, cls)
        if name == "P" && cls == .point {
            let v = c.vec4("value")
            for i in 0..<n where picked[i] { let e = each?[i] ?? v; g.P[i] = SIMD3(e.x, e.y, e.z) }
            return g
        }
        var values = g.table(cls)[name].map { $0.type == type ? $0 : $0.converted(to: type) } ?? .zeros(type, count: n)
        if let each {
            for i in 0..<n where picked[i] { values.set(i, each[i]) }
        } else if picked.allSatisfy({ $0 }) {
            values = .filled(type, count: n, with: c.vec4("value"), string: c.string("string"))
        } else {
            for i in 0..<n where picked[i] {
                if type == .string { values.setString(i, c.string("string")) } else { values.set(i, c.vec4("value")) }
            }
        }
        g.modify(cls) { $0.set(name, values) }
        return g
    }

    static func attribdelete(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let negate = c.bool("negate")
        for (cls, param) in [(AttributeClass.point, "ptdel"), (.vertex, "vtxdel"), (.primitive, "primdel"), (.detail, "dtldel")] {
            let pattern = c.string(param)
            guard !pattern.isEmpty || negate else { continue }
            g.modify(cls) { t in
                let names = t.names
                for n in names where namePatternMatches(pattern, n) != negate { t.remove(n) }
            }
        }
        return g
    }

    static func attribrename(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let from = c.string("from"), to = c.string("to").trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else { return g }
        let cls = c.attributeClass()
        guard g.table(cls)[from] != nil else { throw ProcCookError("No \(cls.rawValue) attribute \"\(from)\"") }
        g.modify(cls) { $0.rename(from, to: to) }
        return g
    }

    static func attribrandomize(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let name = c.string("name")
        let cls = c.attributeClass()
        let dims = max(1, min(4, c.int("dims")))
        let type: AttributeType = [.float, .vector2, .vector3, .vector4][dims - 1]
        let lo = c.vec4("min"), hi = c.vec4("max"), seed = c.int("seed")
        let n = g.count(cls)
        let picked = cls == .detail ? [true] : try c.group(in: g, cls)
        var values = (name == "P" && cls == .point) ? AttributeValues.vector3(g.P)
                   : g.table(cls)[name].map { $0.type == type ? $0 : $0.converted(to: type) } ?? .zeros(type, count: n)
        for i in 0..<n where picked[i] {
            var v = SIMD4<Float>.zero
            for k in 0..<dims { v[k] = lo[k] + (hi[k] - lo[k]) * ProcNoise.random(i, seed: seed, k) }
            values.set(i, v)
        }
        if name == "P" && cls == .point, case .vector3(let p) = values { g.P = p; return g }
        g.modify(cls) { $0.set(name, values) }
        return g
    }

    static func attribnoise(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let name = c.string("name")
        let cls = c.attributeClass()
        let n = g.count(cls)
        let picked = try c.group(in: g, cls)
        let amp = c.float("amp"), freq = c.float("freq"), offset = c.vec3("offset")
        let octaves = max(1, c.int("octaves")), rough = c.float("rough"), seed = UInt32(truncatingIfNeeded: c.int("seed"))
        let op = c.string("op")
        let at = positions(g, cls)
        let isP = name == "P" && cls == .point
        let existing: AttributeValues? = isP ? .vector3(g.P) : g.table(cls)[name]
        let type = existing?.type ?? (op == "alongnormal" ? .vector3 : .float)
        let comps = type == .string ? 1 : type.components
        var values = existing ?? .zeros(type, count: n)
        // The noise, on every core.
        var noise = [SIMD4<Float>](repeating: .zero, count: n)
        noise.withUnsafeMutableBufferPointer { out in
            parallelChunks(n, grain: 2048) { range in
                for i in range where picked[i] {
                    let q = at[i] * freq + offset
                    if comps == 1 || op == "alongnormal" {
                        out[i].x = ProcNoise.fbm(q, octaves: octaves, roughness: rough, seed: seed) * amp
                    } else {
                        let v = ProcNoise.fbm3(q, octaves: octaves, roughness: rough, seed: seed) * amp
                        out[i] = SIMD4(v, ProcNoise.fbm(q + [7.3, 1.9, 4.4], octaves: octaves, roughness: rough, seed: seed &+ 29) * amp)
                    }
                }
            }
        }
        var normals: [SIMD3<Float>] = []
        if op == "alongnormal" {
            normals = (cls == .point ? g.points.vectors3("N") : g.prims.vectors3("N"))
                ?? (cls == .point ? PolygonNodes.pointNormals(g) : (0..<g.primCount).map { g.primNormal($0) })
        }
        for i in 0..<n where picked[i] {
            var v = values.vector(i)
            switch op {
            case "set": v = noise[i]
            case "multiply": v *= (noise[i] + 1)
            case "alongnormal": v += SIMD4(normals[i] * noise[i].x, 0)
            default: v += noise[i]
            }
            values.set(i, v)
        }
        if isP, case .vector3(let p) = values { g.P = p; return g }
        g.modify(cls) { $0.set(name, values) }
        return g
    }

    /// For each element of class `to`, the elements of class `from` that meet it (CSR).
    static func links(_ g: ProcGeo, from: AttributeClass, to: AttributeClass) -> (start: [Int32], rows: [Int32]) {
        var start: [Int32] = [0], rows: [Int32] = []
        func add(_ list: some Sequence<Int32>) { rows += list; start.append(Int32(rows.count)) }
        switch (from, to) {
        case (_, .detail):
            add((0..<Int32(g.count(from))).map { $0 })
        case (.detail, _):
            for _ in 0..<g.count(to) { add([0]) }
        case (.point, .vertex):
            for v in g.vertexPoint { add([v]) }
        case (.point, .primitive):
            for p in 0..<g.primCount { add(g.primPoints(p)) }
        case (.vertex, .primitive):
            for p in 0..<g.primCount { add(g.vertexRange(p).map { Int32($0) }) }
        case (.vertex, .point):
            var lists = [[Int32]](repeating: [], count: g.pointCount)
            for (v, p) in g.vertexPoint.enumerated() { lists[Int(p)].append(Int32(v)) }
            for l in lists { add(l) }
        case (.primitive, .point):
            let (s, prims) = PolygonNodes.pointPrims(g)
            for i in 0..<g.pointCount { add(prims[Int(s[i])..<Int(s[i + 1])]) }
        case (.primitive, .vertex):
            for p in g.vertexPrims() { add([p]) }
        default:
            for i in 0..<g.count(to) { add([Int32(i)]) }
        }
        return (start, rows)
    }

    static func attribpromote(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let name = c.string("name")
        let from = c.attributeClass("from"), to = c.attributeClass("to")
        guard from != to else { return g }
        guard let src = from == .point && name == "P" ? .vector3(g.P) : g.table(from)[name] else {
            throw ProcCookError("No \(from.rawValue) attribute \"\(name)\"")
        }
        let (start, rows) = links(g, from: from, to: to)
        let method = c.string("method")
        var out: AttributeValues
        switch method {
        case "average", "sum":
            var w = [Float](repeating: 1, count: rows.count)
            if method == "average" {
                for r in 0..<(start.count - 1) {
                    let k = start[r + 1] - start[r]
                    for i in Int(start[r])..<Int(start[r + 1]) { w[i] = 1 / Float(k) }
                }
            }
            out = src.blended(start: start, sources: rows, weights: w)
        case "first", "last":
            out = src.gathered((0..<(start.count - 1)).map { r in
                start[r] == start[r + 1] ? -1 : rows[Int(method == "first" ? start[r] : start[r + 1] - 1)]
            })
        default:
            out = .zeros(src.type, count: start.count - 1)
            for r in 0..<(start.count - 1) where start[r] < start[r + 1] {
                var v = src.vector(Int(rows[Int(start[r])]))
                for i in Int(start[r])..<Int(start[r + 1]) {
                    v = method == "minimum" ? simd_min(v, src.vector(Int(rows[i]))) : simd_max(v, src.vector(Int(rows[i])))
                }
                out.set(r, v)
            }
        }
        g.modify(to) { $0.set(name, out) }
        if c.bool("deleteoriginal") && !(from == .point && name == "P") { g.modify(from) { $0.remove(name) } }
        return g
    }

    /// A heat ramp: blue, cyan, green, yellow, red over 0...1.
    static func heat(_ t: Float) -> SIMD3<Float> {
        let keys: [SIMD3<Float>] = [[0.1, 0.2, 0.9], [0.1, 0.8, 0.9], [0.2, 0.85, 0.2], [0.95, 0.9, 0.15], [0.9, 0.15, 0.1]]
        let x = max(0, min(1, t)) * Float(keys.count - 1)
        let i = min(Int(x), keys.count - 2)
        return keys[i] + (keys[i + 1] - keys[i]) * (x - Float(i))
    }

    static func color(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let cls = c.attributeClass()
        let n = g.count(cls)
        let picked = cls == .detail ? [true] : try c.group(in: g, cls)
        var cd = g.table(cls).vectors3("Cd") ?? [SIMD3<Float>](repeating: [1, 1, 1], count: n)
        switch c.string("mode") {
        case "random":
            let seed = c.int("seed")
            for i in 0..<n where picked[i] {
                cd[i] = SIMD3(ProcNoise.random(i, seed: seed, 0), ProcNoise.random(i, seed: seed, 1), ProcNoise.random(i, seed: seed, 2))
            }
        case "ramp":
            let name = c.string("rampattr")
            guard let a = cls == .point && name == "P" ? .vector3(g.P) : g.table(cls)[name] else {
                throw ProcCookError("No \(cls.rawValue) attribute \"\(name)\" to ramp")
            }
            var lo = Float.infinity, hi = -Float.infinity
            for i in 0..<n { lo = min(lo, a.component(i, 0)); hi = max(hi, a.component(i, 0)) }
            for i in 0..<n where picked[i] { cd[i] = heat(hi > lo ? (a.component(i, 0) - lo) / (hi - lo) : 0) }
        default:
            let col = c.vec3("color")
            for i in 0..<n where picked[i] { cd[i] = col }
        }
        g.modify(cls) { $0.set("Cd", .vector3(cd)) }
        return g
    }

    static func measure(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let type = c.string("type")
        let name = c.string("name").isEmpty ? type : c.string("name")
        let v = (0..<g.primCount).map { type == "perimeter" ? g.primPerimeter($0) : g.primArea($0) }
        g.prims.set(name, .float(v))
        return g
    }

    /// Union-find's root of `i`, halving the path on the way.
    static func root(_ parent: inout [Int32], _ i: Int32) -> Int32 {
        var i = i
        while parent[Int(i)] != i { parent[Int(i)] = parent[Int(parent[Int(i)])]; i = parent[Int(i)] }
        return i
    }

    /// Each point's piece: points joined by a primitive are in one, numbered from 0 in the order first met.
    static func pieces(_ g: ProcGeo) -> [Int32] {
        var parent = (0..<Int32(g.pointCount)).map { $0 }
        for p in 0..<g.primCount {
            let r = g.vertexRange(p)
            guard let first = r.first else { continue }
            let a = root(&parent, g.vertexPoint[first])
            for v in r.dropFirst() {
                let b = root(&parent, g.vertexPoint[v])
                if a != b { parent[Int(b)] = a }
            }
        }
        var number = [Int32](repeating: -1, count: g.pointCount)
        var out = [Int32](repeating: 0, count: g.pointCount)
        var next: Int32 = 0
        for i in 0..<g.pointCount {
            let r = Int(root(&parent, Int32(i)))
            if number[r] < 0 { number[r] = next; next += 1 }
            out[i] = number[r]
        }
        return out
    }

    static func connectivity(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let name = c.string("name").isEmpty ? "class" : c.string("name")
        let piece = pieces(g)
        if c.attributeClass() == .primitive {
            // Numbered again in the order primitives meet them.
            var number = [Int32](repeating: -1, count: g.pointCount + 1)
            var next: Int32 = 0
            let v = (0..<g.primCount).map { p -> Int32 in
                guard let first = g.vertexRange(p).first else { return -1 }
                let k = Int(piece[Int(g.vertexPoint[first])])
                if number[k] < 0 { number[k] = next; next += 1 }
                return number[k]
            }
            g.prims.set(name, .int(v))
        } else {
            g.points.set(name, .int(piece))
        }
        return g
    }

    static func sort(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let cls = c.attributeClass()
        let n = g.count(cls)
        var order = (0..<Int32(n)).map { $0 }
        let key = c.string("key")
        let at = positions(g, cls)
        switch key {
        case "x", "y", "z":
            let k = key == "x" ? 0 : key == "y" ? 1 : 2
            order.sort { at[Int($0)][k] != at[Int($1)][k] ? at[Int($0)][k] < at[Int($1)][k] : $0 < $1 }
        case "random":
            let seed = c.int("seed")
            let r = (0..<n).map { ProcNoise.random($0, seed: seed) }
            order.sort { r[Int($0)] != r[Int($1)] ? r[Int($0)] < r[Int($1)] : $0 < $1 }
        case "attribute":
            let name = c.string("attribute")
            guard let a = g.table(cls)[name] else { throw ProcCookError("No \(cls.rawValue) attribute \"\(name)\"") }
            order.sort { a.component(Int($0), 0) != a.component(Int($1), 0) ? a.component(Int($0), 0) < a.component(Int($1), 0) : $0 < $1 }
        case "expression":
            // Its value per element (one value for all: the order stays).
            if let v = try c.elementValues("expression", in: g, cls) {
                order.sort { v[Int($0)].x != v[Int($1)].x ? v[Int($0)].x < v[Int($1)].x : $0 < $1 }
            }
        default: break
        }
        if c.bool("reverse") { order.reverse() }
        return cls == .primitive ? g.reorderedPrims(order) : g.reorderedPoints(order)
    }

    // MARK: Groups

    static func groupcreate(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let name = c.string("groupname").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ProcCookError("No group name") }
        let cls = c.attributeClass("grouptype")
        let n = g.count(cls)
        var keep = try GroupPattern.evaluate(c.string("basegroup"), in: g, cls)
        if c.bool("usebounds") {
            let lo = simd_min(c.vec3("boundmin"), c.vec3("boundmax")), hi = simd_max(c.vec3("boundmin"), c.vec3("boundmax"))
            let at = positions(g, cls)
            for i in 0..<n where keep[i] { keep[i] = all(at[i] .>= lo) && all(at[i] .<= hi) }
        }
        if c.bool("usenormal") {
            let dir = simd_length(c.vec3("dir")) > 0 ? simd_normalize(c.vec3("dir")) : SIMD3<Float>(0, 1, 0)
            let limit = cos(c.float("angle") * .pi / 180)
            let normals = cls == .primitive ? (0..<g.primCount).map { g.primNormal($0) }
                                            : g.points.vectors3("N") ?? PolygonNodes.pointNormals(g)
            for i in 0..<n where keep[i] { keep[i] = simd_dot(normals[i], dir) >= limit }
        }
        if c.bool("userandom") {
            let share = c.float("percent") / 100, seed = c.int("seed")
            for i in 0..<n where keep[i] { keep[i] = ProcNoise.random(i, seed: seed, 7) < share }
        }
        if c.bool("useexpr") {
            if let v = try c.elementValues("expression", in: g, cls) {
                for i in 0..<n where keep[i] { keep[i] = v[i].x != 0 }
            } else if c.float("expression") == 0 {
                keep = [Bool](repeating: false, count: n)
            }
        }
        let old = g.table(cls).group(name)
        if let old {
            switch c.string("mergeop") {
            case "union": for i in 0..<n { keep[i] = keep[i] || old[i] }
            case "intersect": for i in 0..<n { keep[i] = keep[i] && old[i] }
            case "subtract": for i in 0..<n { keep[i] = old[i] && !keep[i] }
            default: break
            }
        }
        g.modify(cls) { $0.setGroup(name, keep) }
        return g
    }

    static func blast(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let cls = c.attributeClass("grouptype")
        var picked = try c.group(in: g, cls)
        if c.bool("negate") { picked = picked.map { !$0 } }
        var out: ProcGeo
        if cls == .point {
            out = g.keeping(prims: [Bool](repeating: true, count: g.primCount), points: picked.map { !$0 })
        } else {
            out = g.keeping(prims: picked.map { !$0 })
        }
        if c.bool("removegrp") {
            let pattern = c.string("group")
            out.modify(cls) { t in for n in t.groupNames where namePatternMatches(pattern, n) { t.removeGroup(n) } }
        }
        return out
    }
}
