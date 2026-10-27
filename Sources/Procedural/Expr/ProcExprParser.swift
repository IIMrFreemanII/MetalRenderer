import Foundation

/// A parameter expression's syntax, as Houdini's hscript writes it: numbers, "strings", `$VAR`, `@attr` (`@P.y`,
/// `@Cd[2]`), bare names (`D_XMIN`), calls (`ch("../box1/sizex")`), unary `- !`, and `* / %`, `+ -`,
/// `< > <= >= == !=`, `&&`, `||` from tightest to loosest. ProcExprContext gives the names their meaning.
package indirect enum ProcExpr: Equatable {
    case number(Float)
    case string(String)
    /// A bare name: a constant such as `D_XMIN`.
    case name(String)
    case variable(String)
    /// An attribute and its component (nil: the first).
    case attribute(String, Int?)
    case call(String, [ProcExpr])
    case unary(String, ProcExpr)
    case binary(String, ProcExpr, ProcExpr)

    package static func parse(_ source: String) throws -> ProcExpr {
        var p = ProcExprParser(source)
        let e = try p.or()
        p.skipSpace()
        if p.i < p.c.count { throw ProcExprError("Unexpected \"\(p.c[p.i])\"", column: p.i) }
        return e
    }
}

/// Why an expression didn't parse or evaluate, and where (a character offset; nil: the whole of it).
package struct ProcExprError: Error, Equatable, CustomStringConvertible {
    package var message: String
    package var column: Int?
    package init(_ message: String, column: Int? = nil) { self.message = message; self.column = column }
    package var description: String { message }
}

/// Recursive descent over the characters.
struct ProcExprParser {
    let c: [Character]
    var i = 0
    init(_ s: String) { c = Array(s) }

    mutating func skipSpace() { while i < c.count, c[i].isWhitespace { i += 1 } }

    /// The next characters, if they are `s` (taken).
    mutating func take(_ s: String) -> Bool {
        skipSpace()
        let t = Array(s)
        guard i + t.count <= c.count, Array(c[i..<(i + t.count)]) == t else { return false }
        // `<` isn't `<=`, `!` isn't `!=`, `=`... alone is nothing.
        if t.count == 1, i + 1 < c.count, "<>!=".contains(t[0]), c[i + 1] == "=" { return false }
        i += t.count
        return true
    }

    mutating func or() throws -> ProcExpr {
        var e = try and()
        while take("||") { e = .binary("||", e, try and()) }
        return e
    }

    mutating func and() throws -> ProcExpr {
        var e = try equality()
        while take("&&") { e = .binary("&&", e, try equality()) }
        return e
    }

    mutating func equality() throws -> ProcExpr {
        var e = try comparison()
        while true {
            if take("==") { e = .binary("==", e, try comparison()) } else if take("!=") { e = .binary("!=", e, try comparison()) } else { return e }
        }
    }

    mutating func comparison() throws -> ProcExpr {
        var e = try sum()
        while true {
            if take("<=") { e = .binary("<=", e, try sum()) } else if take(">=") { e = .binary(">=", e, try sum()) }
            else if take("<") { e = .binary("<", e, try sum()) } else if take(">") { e = .binary(">", e, try sum()) } else { return e }
        }
    }

    mutating func sum() throws -> ProcExpr {
        var e = try product()
        while true {
            if take("+") { e = .binary("+", e, try product()) } else if take("-") { e = .binary("-", e, try product()) } else { return e }
        }
    }

    mutating func product() throws -> ProcExpr {
        var e = try unary()
        while true {
            if take("*") { e = .binary("*", e, try unary()) } else if take("/") { e = .binary("/", e, try unary()) }
            else if take("%") { e = .binary("%", e, try unary()) } else { return e }
        }
    }

    mutating func unary() throws -> ProcExpr {
        if take("-") { return .unary("-", try unary()) }
        if take("+") { return try unary() }
        if take("!") { return .unary("!", try unary()) }
        return try primary()
    }

    private func isNameStart(_ ch: Character) -> Bool { ch.isLetter || ch == "_" }
    private func isName(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }

    private mutating func name() -> String {
        let start = i
        while i < c.count, isName(c[i]) { i += 1 }
        return String(c[start..<i])
    }

    mutating func primary() throws -> ProcExpr {
        skipSpace()
        guard i < c.count else { throw ProcExprError("The expression ends too soon", column: i) }
        let start = i
        let ch = c[i]
        if take("(") {
            let e = try or()
            guard take(")") else { throw ProcExprError("A \"(\" isn't closed", column: start) }
            return e
        }
        if ch.isNumber || (ch == "." && i + 1 < c.count && c[i + 1].isNumber) { return .number(try number()) }
        if ch == "\"" || ch == "'" { return .string(try string(ch)) }
        if ch == "$" {
            i += 1
            guard i < c.count, isNameStart(c[i]) else { throw ProcExprError("A variable's name follows $", column: start) }
            return .variable(name())
        }
        if ch == "@" {
            i += 1
            guard i < c.count, isNameStart(c[i]) else { throw ProcExprError("An attribute's name follows @", column: start) }
            let n = name()
            // A component: .x .y .z .w (.r .g .b .a), or [index].
            if i + 1 < c.count, c[i] == ".", let k = ProcExprParser.component(c[i + 1]), i + 2 >= c.count || !isName(c[i + 2]) {
                i += 2
                return .attribute(n, k)
            }
            if take("[") {
                let at = i
                guard case .number(let k) = try primary(), k >= 0, k < 4, k == k.rounded() else {
                    throw ProcExprError("A component index is 0, 1, 2 or 3", column: at)
                }
                guard take("]") else { throw ProcExprError("A \"[\" isn't closed", column: at) }
                return .attribute(n, Int(k))
            }
            return .attribute(n, nil)
        }
        if isNameStart(ch) {
            let n = name()
            if take("(") {
                var args: [ProcExpr] = []
                if !take(")") {
                    repeat { args.append(try or()) } while take(",")
                    guard take(")") else { throw ProcExprError("\(n)( isn't closed", column: start) }
                }
                return .call(n, args)
            }
            return .name(n)
        }
        throw ProcExprError("Unexpected \"\(ch)\"", column: i)
    }

    /// x y z w, r g b a: 0 to 3.
    static func component(_ ch: Character) -> Int? {
        switch ch {
        case "x", "r": 0
        case "y", "g": 1
        case "z", "b": 2
        case "w", "a": 3
        default: nil
        }
    }

    private mutating func number() throws -> Float {
        let start = i
        while i < c.count, c[i].isNumber || c[i] == "." { i += 1 }
        if i < c.count, c[i] == "e" || c[i] == "E" {
            var j = i + 1
            if j < c.count, c[j] == "+" || c[j] == "-" { j += 1 }
            if j < c.count, c[j].isNumber {
                i = j
                while i < c.count, c[i].isNumber { i += 1 }
            }
        }
        guard let v = Float(String(c[start..<i])) else { throw ProcExprError("\(String(c[start..<i])) isn't a number", column: start) }
        return v
    }

    private mutating func string(_ quote: Character) throws -> String {
        let start = i
        i += 1
        var s = ""
        while i < c.count, c[i] != quote {
            if c[i] == "\\", i + 1 < c.count { i += 1 }
            s.append(c[i])
            i += 1
        }
        guard i < c.count else { throw ProcExprError("A string isn't closed", column: start) }
        i += 1
        return s
    }
}

/// What an expression reads besides its node's inputs: what its node's cook key must hold.
package struct ProcExprRefs: Equatable {
    /// `ch` paths, as written.
    package var channels: [String] = []
    /// `chf(path, frame)` paths: channels read at another frame, whose whole keys the key holds.
    package var otherFrames: [String] = []
    /// Nodes a geometry function names by path (`npoints("../box1")`).
    package var nodes: [String] = []
    package var frame = false
    /// Reads its node's inputs (a geometry function by input number, a node variable such as `$CEX`).
    package var inputs = false
    /// Varies per element (`$PT`, `@P`).
    package var element = false

    package mutating func formUnion(_ o: ProcExprRefs) {
        channels += o.channels
        otherFrames += o.otherFrames
        nodes += o.nodes
        frame = frame || o.frame
        inputs = inputs || o.inputs
        element = element || o.element
    }
}

extension ProcExpr {
    package static let frameVariables: Set<String> = ["F", "FF", "T"]
    package static let nodeVariables: Set<String> = ["NPT", "NPR", "NVTX", "CEX", "CEY", "CEZ", "XMIN", "XMAX", "YMIN", "YMAX",
                                                     "ZMIN", "ZMAX", "SIZEX", "SIZEY", "SIZEZ"]
    package static let elementVariables: Set<String> = ["PT", "PR", "TX", "TY", "TZ", "NX", "NY", "NZ", "CR", "CG", "CB"]
    static let channelFunctions: Set<String> = ["ch", "chf", "chi", "chs"]
    static let geometryFunctions: Set<String> = ["npoints", "nprims", "nvertices", "point", "prim", "detail", "bbox", "centroid"]

    package var references: ProcExprRefs {
        var r = ProcExprRefs()
        switch self {
        case .number, .string, .name: break
        case .variable(let v):
            if ProcExpr.frameVariables.contains(v) { r.frame = true }
            if ProcExpr.nodeVariables.contains(v) { r.inputs = true }
            if ProcExpr.elementVariables.contains(v) { r.element = true; r.inputs = true }
        case .attribute: r.element = true; r.inputs = true
        case .call(let f, let args):
            if ProcExpr.channelFunctions.contains(f), case .string(let path)? = args.first {
                if f == "chf" && args.count == 2 { r.otherFrames.append(path) } else { r.channels.append(path) }
            }
            if ProcExpr.geometryFunctions.contains(f) {
                if case .string(let path)? = args.first { r.nodes.append(path) } else { r.inputs = true }
            }
            for a in args { r.formUnion(a.references) }
        case .unary(_, let e): r = e.references
        case .binary(_, let a, let b): r = a.references; r.formUnion(b.references)
        }
        return r
    }
}
