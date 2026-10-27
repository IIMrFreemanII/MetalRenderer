import EngineCore
import Foundation
import simd

/// An expression compiled against its node: everything that doesn't vary per element folded to a constant there and
/// then (variables, channels, geometry functions with constant arguments), what does run as flat postfix code over a
/// stack of floats, once per element on every core. The loop is the data-oriented fast subset: the code, the columns it
/// reads and the stack are buffers; no strings, dictionaries or reference counting in it.
package struct ProcExprProgram {
    enum Unary: UInt8 {
        case neg, not, abs, sign, floor, ceil, round, frac, int, sqrt, exp, log, log10, sin, cos, tan, asin, acos, atan, deg, rad
    }
    enum Binary: UInt8 { case add, sub, mul, div, mod, lt, gt, le, ge, eq, ne, and, or, min, max, pow, atan2 }
    /// `select` is `if(c, a, b)`; `fit01(v, a, b)` and the rest take the value first, as hscript's do.
    enum Ternary: UInt8 { case select, clamp, lerp, smooth, fit01, fit10, fit11 }

    enum Op {
        case constant(Float)
        /// The element's row of a column: `flat[offset + element]`.
        case column(Int)
        /// A row of a table of `count` (the index popped): `flat[offset + index]`, 0 outside it.
        case gather(Int, Int)
        case element
        case unary(Unary)
        case binary(Binary)
        case ternary(Ternary)
        /// fit(v, omin, omax, nmin, nmax), clamped.
        case fit
        case rand
        case noise
    }

    /// What an expression compiles to: a constant, or code that pushes one value per element.
    enum Code {
        case constant(Float)
        /// The code, and the most it pushes at once.
        case ops([Op], Int)
    }

    let ops: [Op]
    let flat: [Float]
    let depth: Int
    /// How many elements it runs over.
    package let count: Int

    /// The constant it folded to, if it did.
    package let constant: Float?

    init(_ code: Code, flat: [Float], count: Int) {
        switch code {
        case .constant(let v): ops = []; depth = 0; constant = v
        case .ops(let o, let d): ops = o; depth = d; constant = nil
        }
        self.flat = flat
        self.count = count
    }

    /// Its value for each element.
    package func run() -> [Float] {
        if let constant { return [Float](repeating: constant, count: count) }
        var out = [Float](repeating: 0, count: count)
        let n = count, depth = max(depth, 1), grain = 4096
        // Every part's stack, made before the parts run: nothing is allocated in them.
        var stacks = [Float](repeating: 0, count: depth * ((n + grain - 1) / grain))
        ops.withUnsafeBufferPointer { ops in
            flat.withUnsafeBufferPointer { flat in
                stacks.withUnsafeMutableBufferPointer { stacks in
                    out.withUnsafeMutableBufferPointer { out in
                        parallelChunks(n, grain: grain) { range in
                            let stack = stacks.baseAddress! + range.lowerBound / grain * depth
                            for e in range { out[e] = ProcExprProgram.evaluate(e, ops, flat, stack) }
                        }
                    }
                }
            }
        }
        return out
    }

    @inline(__always)
    static func evaluate(_ e: Int, _ ops: UnsafeBufferPointer<Op>, _ flat: UnsafeBufferPointer<Float>, _ s: UnsafeMutablePointer<Float>) -> Float {
        var sp = 0
        for k in 0..<ops.count {
            switch ops[k] {
            case .constant(let v): s[sp] = v; sp += 1
            case .column(let o): s[sp] = flat[o + e]; sp += 1
            case .gather(let o, let n):
                let f = s[sp - 1]
                let i = f.isFinite ? Int(f.rounded()) : -1
                s[sp - 1] = i >= 0 && i < n ? flat[o + i] : 0
            case .element: s[sp] = Float(e); sp += 1
            case .unary(let u): s[sp - 1] = apply(u, s[sp - 1])
            case .binary(let b): s[sp - 2] = apply(b, s[sp - 2], s[sp - 1]); sp -= 1
            case .ternary(let t): s[sp - 3] = apply(t, s[sp - 3], s[sp - 2], s[sp - 1]); sp -= 2
            case .fit: s[sp - 5] = fit(s[sp - 5], s[sp - 4], s[sp - 3], s[sp - 2], s[sp - 1]); sp -= 4
            case .rand: s[sp - 1] = rand(s[sp - 1])
            case .noise: s[sp - 3] = ProcNoise.perlin(SIMD3(s[sp - 3], s[sp - 2], s[sp - 1])); sp -= 2
            }
        }
        return s[0]
    }

    // MARK: The functions (the same code folds constants and runs per element: the same bits either way)

    private static let toRadians = Float.pi / 180

    @inline(__always) static func apply(_ u: Unary, _ a: Float) -> Float {
        switch u {
        case .neg: -a
        case .not: a == 0 ? 1 : 0
        case .abs: Swift.abs(a)
        case .sign: a > 0 ? 1 : (a < 0 ? -1 : 0)
        case .floor: a.rounded(.down)
        case .ceil: a.rounded(.up)
        case .round: a.rounded()
        case .frac: a - a.rounded(.down)
        case .int: a.rounded(.towardZero)
        case .sqrt: a.squareRoot()
        case .exp: Foundation.exp(a)
        case .log: Foundation.log(a)
        case .log10: Foundation.log10(a)
        case .sin: Foundation.sin(a * toRadians)
        case .cos: Foundation.cos(a * toRadians)
        case .tan: Foundation.tan(a * toRadians)
        case .asin: Foundation.asin(a) / toRadians
        case .acos: Foundation.acos(a) / toRadians
        case .atan: Foundation.atan(a) / toRadians
        case .deg: a / toRadians
        case .rad: a * toRadians
        }
    }

    @inline(__always) static func apply(_ b: Binary, _ x: Float, _ y: Float) -> Float {
        switch b {
        case .add: x + y
        case .sub: x - y
        case .mul: x * y
        case .div: x / y
        case .mod: x.truncatingRemainder(dividingBy: y)
        case .lt: x < y ? 1 : 0
        case .gt: x > y ? 1 : 0
        case .le: x <= y ? 1 : 0
        case .ge: x >= y ? 1 : 0
        case .eq: x == y ? 1 : 0
        case .ne: x != y ? 1 : 0
        case .and: x != 0 && y != 0 ? 1 : 0
        case .or: x != 0 || y != 0 ? 1 : 0
        case .min: Swift.min(x, y)
        case .max: Swift.max(x, y)
        case .pow: Foundation.pow(x, y)
        case .atan2: Foundation.atan2(x, y) / toRadians
        }
    }

    @inline(__always) static func apply(_ t: Ternary, _ a: Float, _ b: Float, _ c: Float) -> Float {
        switch t {
        case .select: a != 0 ? b : c
        case .clamp: Swift.min(Swift.max(a, b), c)
        case .lerp: a + (b - a) * c
        case .smooth: smooth(a, b, c)
        case .fit01: fit(a, 0, 1, b, c)
        case .fit10: fit(a, 1, 0, b, c)
        case .fit11: fit(a, -1, 1, b, c)
        }
    }

    /// smooth(min, max, value): Hermite from 0 at min to 1 at max.
    @inline(__always) static func smooth(_ a: Float, _ b: Float, _ v: Float) -> Float {
        if v <= a { return 0 }
        if v >= b { return 1 }
        let t = (v - a) / (b - a)
        return t * t * (3 - 2 * t)
    }

    @inline(__always) static func fit(_ v: Float, _ omin: Float, _ omax: Float, _ nmin: Float, _ nmax: Float) -> Float {
        guard omax != omin else { return nmin }
        let t = Swift.min(Swift.max((v - omin) / (omax - omin), 0), 1)
        return nmin + (nmax - nmin) * t
    }

    /// hscript's rand(seed): 0..<1, a different number for each float seed.
    @inline(__always) static func rand(_ seed: Float) -> Float {
        ProcNoise.random(Int(seed.bitPattern), seed: 0)
    }
}

/// Compiles an expression against a context (ProcExprContext.swift says what names mean there).
struct ProcExprCompiler {
    typealias Code = ProcExprProgram.Code
    typealias Op = ProcExprProgram.Op

    let context: ProcExprContext
    /// The elements it runs over (nil: none; an element variable is then an error).
    let elements: ProcExprElements?
    /// The columns and tables the code reads, one after another.
    var flat: [Float] = []
    private var columns: [String: Int] = [:]

    init(_ context: ProcExprContext, elements: ProcExprElements?) {
        self.context = context
        self.elements = elements
    }

    static func compile(_ e: ProcExpr, _ context: ProcExprContext, elements: ProcExprElements?) throws -> ProcExprProgram {
        var c = ProcExprCompiler(context, elements: elements)
        let code = try c.compile(e)
        return ProcExprProgram(code, flat: c.flat, count: elements?.count ?? 1)
    }

    private func error(_ m: String) -> ProcExprError { ProcExprError(m) }

    mutating func compile(_ e: ProcExpr) throws -> Code {
        switch e {
        case .number(let v): return .constant(v)
        case .string(let s): throw error("\"\(s)\" is a string where a number goes")
        case .name(let n): throw error("\(n) means nothing here (a function's constant, such as bbox's D_XMIN, goes in its call)")
        case .variable(let v):
            if ProcExpr.elementVariables.contains(v) { return try element(variable: v) }
            return .constant(try context.variable(v))
        case .attribute(let n, let k): return try attribute(n, k ?? 0)
        case .unary(let op, let a):
            return combine(op == "-" ? .neg : .not, try compile(a))
        case .binary(let op, let a, let b):
            let ops: [String: ProcExprProgram.Binary] = ["+": .add, "-": .sub, "*": .mul, "/": .div, "%": .mod, "<": .lt, ">": .gt,
                                                         "<=": .le, ">=": .ge, "==": .eq, "!=": .ne, "&&": .and, "||": .or]
            return combine(ops[op]!, try compile(a), try compile(b))
        case .call(let f, let args): return try call(f, args)
        }
    }

    // MARK: Folding

    private func combine(_ u: ProcExprProgram.Unary, _ a: Code) -> Code {
        switch a {
        case .constant(let x): .constant(ProcExprProgram.apply(u, x))
        case .ops(let o, let d): .ops(o + [.unary(u)], d)
        }
    }

    private func combine(_ b: ProcExprProgram.Binary, _ x: Code, _ y: Code) -> Code {
        if case .constant(let p) = x, case .constant(let q) = y { return .constant(ProcExprProgram.apply(b, p, q)) }
        return join([x, y], .binary(b))
    }

    /// The arguments' code one after another, then `op`.
    private func join(_ args: [Code], _ op: Op) -> Code {
        var ops: [Op] = []
        var depth = 0
        for (k, a) in args.enumerated() {
            switch a {
            case .constant(let v): ops.append(.constant(v)); depth = max(depth, k + 1)
            case .ops(let o, let d): ops += o; depth = max(depth, k + d)
            }
        }
        ops.append(op)
        return .ops(ops, depth)
    }

    private func constants(_ args: [Code]) -> [Float]? {
        var out: [Float] = []
        for a in args { guard case .constant(let v) = a else { return nil }; out.append(v) }
        return out
    }

    // MARK: Calls

    private mutating func call(_ f: String, _ args: [ProcExpr]) throws -> Code {
        func arity(_ n: Int) throws {
            guard args.count == n else { throw error("\(f)() takes \(n) argument\(n == 1 ? "" : "s"), not \(args.count)") }
        }
        let unary: [String: ProcExprProgram.Unary] = [
            "abs": .abs, "sign": .sign, "floor": .floor, "ceil": .ceil, "round": .round, "frac": .frac, "int": .int, "sqrt": .sqrt,
            "exp": .exp, "log": .log, "log10": .log10, "sin": .sin, "cos": .cos, "tan": .tan, "asin": .asin, "acos": .acos,
            "atan": .atan, "deg": .deg, "rad": .rad,
        ]
        let binary: [String: ProcExprProgram.Binary] = ["min": .min, "max": .max, "pow": .pow, "atan2": .atan2]
        let ternary: [String: ProcExprProgram.Ternary] = ["if": .select, "clamp": .clamp, "lerp": .lerp, "smooth": .smooth,
                                                          "fit01": .fit01, "fit10": .fit10, "fit11": .fit11]
        if let u = unary[f] { try arity(1); return combine(u, try compile(args[0])) }
        if let b = binary[f] { try arity(2); return combine(b, try compile(args[0]), try compile(args[1])) }
        if let t = ternary[f] {
            try arity(3)
            let c = try args.map { try compile($0) }
            if let v = constants(c) { return .constant(ProcExprProgram.apply(t, v[0], v[1], v[2])) }
            return join(c, .ternary(t))
        }
        switch f {
        case "fit":
            try arity(5)
            let c = try args.map { try compile($0) }
            if let v = constants(c) { return .constant(ProcExprProgram.fit(v[0], v[1], v[2], v[3], v[4])) }
            return join(c, .fit)
        case "rand":
            try arity(1)
            let c = try compile(args[0])
            if case .constant(let v) = c { return .constant(ProcExprProgram.rand(v)) }
            return join([c], .rand)
        case "noise":
            try arity(3)
            let c = try args.map { try compile($0) }
            if let v = constants(c) { return .constant(ProcNoise.perlin(SIMD3(v[0], v[1], v[2]))) }
            return join(c, .noise)
        case "ch", "chf", "chi":
            try arity(1)
            let v = try context.channel(try path(f, args[0]))
            return .constant(f == "chi" ? v.rounded(.towardZero) : v)
        case "chs": throw error("chs() gives a string: use it in a text field's `backticks`")
        case "opdigits":
            try arity(1)
            return .constant(try context.opdigits(try path(f, args[0])))
        case "npoints", "nprims", "nvertices":
            try arity(1)
            let g = try context.geometry(try input(f, args[0]))
            return .constant(Float(f == "npoints" ? g.pointCount : f == "nprims" ? g.primCount : g.vertexCount))
        case "bbox", "centroid":
            try arity(2)
            let g = try context.geometry(try input(f, args[0]))
            guard case .name(let which) = args[1], let v = ProcExprContext.bounds(g, which, centroid: f == "centroid") else {
                throw error(f == "bbox" ? "bbox()'s second argument is D_XMIN, D_XMAX … D_ZMAX or D_XSIZE … D_ZSIZE"
                                        : "centroid()'s second argument is D_X, D_Y or D_Z")
            }
            return .constant(v)
        case "detail":
            try arity(3)
            let g = try context.geometry(try input(f, args[0]))
            let name = try string(f, args[1])
            guard case .constant(let k) = try compile(args[2]) else { throw error("detail()'s component is a constant") }
            return .constant(try ProcExprContext.column(g, .detail, name, Int(k)).first ?? 0)
        case "point", "prim":
            try arity(4)
            let g = try context.geometry(try input(f, args[0]))
            let name = try string(f, args[1])
            guard case .constant(let k) = try compile(args[3]) else { throw error("\(f)()'s component is a constant") }
            let cls: AttributeClass = f == "point" ? .point : .primitive
            let index = try compile(args[2])
            let table = try ProcExprContext.column(g, cls, name, Int(k))
            if case .constant(let i) = index {
                let r = Int(i.rounded())
                return .constant(r >= 0 && r < table.count ? table[r] : 0)
            }
            let offset = flat.count
            flat += table
            return join([index], .gather(offset, table.count))
        default:
            throw error("\(f)() isn't a function here")
        }
    }

    private func path(_ f: String, _ e: ProcExpr) throws -> String {
        guard case .string(let s) = e else { throw error("\(f)() takes a path in quotes, such as \"../box1/sizex\"") }
        return s
    }

    private func string(_ f: String, _ e: ProcExpr) throws -> String {
        guard case .string(let s) = e else { throw error("\(f)() takes an attribute's name in quotes") }
        return s
    }

    private mutating func input(_ f: String, _ e: ProcExpr) throws -> ProcExprInput {
        if case .string(let s) = e { return .path(s) }
        guard case .constant(let v) = try compile(e), v >= 0, v == v.rounded() else {
            throw error("\(f)()'s first argument is an input number (0 for the first) or a node's path")
        }
        return .index(Int(v))
    }

    // MARK: Per element

    private func needElements(_ what: String) throws -> ProcExprElements {
        guard let elements else {
            throw error("\(what) varies per element: it works in Attribute Create's Value, Group Create's Expression and Sort's Expression")
        }
        return elements
    }

    private mutating func element(variable v: String) throws -> Code {
        _ = try needElements("$\(v)")
        switch v {
        case "PT": return try attribute("ptnum", 0)
        case "PR": return try attribute("primnum", 0)
        case "TX", "TY", "TZ": return try attribute("P", v == "TX" ? 0 : v == "TY" ? 1 : 2)
        case "NX", "NY", "NZ": return try attribute("N", v == "NX" ? 0 : v == "NY" ? 1 : 2)
        default: return try attribute("Cd", v == "CR" ? 0 : v == "CG" ? 1 : 2)
        }
    }

    private mutating func attribute(_ name: String, _ k: Int) throws -> Code {
        let el = try needElements("@\(name)")
        let g = el.geo, cls = el.cls
        switch name {
        case "elemnum": return .ops([.element], 1)
        case "numpt": return .constant(Float(g.pointCount))
        case "numprim": return .constant(Float(g.primCount))
        case "numvtx": return .constant(Float(g.vertexCount))
        case "ptnum" where cls == .point, "primnum" where cls == .primitive, "vtxnum" where cls == .vertex:
            return .ops([.element], 1)
        default: break
        }
        let key = "\(name).\(k)"
        if let o = columns[key] { return .ops([.column(o)], 1) }
        let column = try ProcExprContext.elementColumn(g, cls, name, k)
        if column.count == 1 && el.count != 1 { return .constant(column[0]) }   // a detail attribute
        let o = flat.count
        flat += column
        columns[key] = o
        return .ops([.column(o)], 1)
    }
}

/// The elements a per-element expression runs over: a class of a geometry.
package struct ProcExprElements {
    package let geo: ProcGeo
    package let cls: AttributeClass
    package init(_ geo: ProcGeo, _ cls: AttributeClass) { self.geo = geo; self.cls = cls }
    package var count: Int { geo.count(cls) }
}

/// Where a geometry function reads: an input of its node, or a node by path.
package enum ProcExprInput: Equatable {
    case index(Int)
    case path(String)
}
