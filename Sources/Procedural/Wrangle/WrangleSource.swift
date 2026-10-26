import EngineCore
import Foundation

/// A wrangle's Swift, as the compiler gets it: the snippet with Houdini's `@` bindings made into variables, inside a
/// function that runs it over every element of the class (in parts on every core), reading each bound attribute
/// before the snippet and writing it after.
///
/// In the snippet: `@P`, `@N`, `@Cd` … an attribute of the element (its type from a prefix — `f@` Float, `i@` Int,
/// `v@` SIMD3<Float>, `u@` SIMD2<Float>, `p@` SIMD4<Float>, `s@` String — else from the input, else Houdini's usual:
/// P, N, Cd, v, up, scale vectors, orient a vector4, id an int, name a string, others floats); `@ptnum`, `@primnum`,
/// `@vtxnum`, `@elemnum`, `@numpt`, `@numprim`, `@numvtx`. A new attribute is made when first named. `return` ends the
/// element's run. Functions: `point(input, "name", n)`, `prim(…)`, `detail(input, "name")`, `npoints(input)`,
/// `nprims(input)`, `primpoints(input, n)`, `nearpoint(input, p)`, `nearpoints(input, p, radius, max)`,
/// `addpoint(p)`, `addprim([points], closed:)`, `removepoint(n)`, `removeprim(n)`, `setgroup("name", n, on)`, and the
/// math of WrangleFunctions (`rand`, `noise`, `curlnoise`, `fit`, `lerp` …) besides simd's.
package enum WrangleSource {
    package struct Binding: Equatable {
        package var name: String
        package var type: AttributeType
    }

    /// Element numbers and counts the snippet may name with `@`.
    static let locals: Set<String> = ["ptnum", "primnum", "vtxnum", "elemnum", "numpt", "numprim", "numvtx", "numelem"]

    static let prefixes: [Character: AttributeType] = ["f": .float, "i": .int, "v": .vector3, "u": .vector2, "p": .vector4, "s": .string]

    static func standard(_ name: String) -> AttributeType {
        switch name {
        case "P", "N", "Cd", "v", "up", "scale", "rest", "force": .vector3
        case "orient": .vector4
        case "uv": .vector2
        case "id", "class", "piece", "copynum": .int
        case "name", "material": .string
        default: .float
        }
    }

    /// The snippet with its bindings replaced by variables (`_a_name`), and the bindings with their types.
    package static func rewrite(_ code: String, existing: (String) -> AttributeType?) -> (code: String, bindings: [Binding]) {
        var out = ""
        var bindings: [Binding] = []
        let chars = Array(code)
        var i = 0
        var inString = false, inComment = false
        while i < chars.count {
            let ch = chars[i]
            if inComment {
                out.append(ch)
                if ch == "\n" { inComment = false }
                i += 1
                continue
            }
            if ch == "/" && i + 1 < chars.count && chars[i + 1] == "/" && !inString { inComment = true; out.append(ch); i += 1; continue }
            if ch == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
            // A binding: an optional type letter (not part of a longer word), `@`, a name.
            var prefix: Character?
            var at = i
            if !inString, let t = prefixes[ch].map({ _ in ch }), i + 1 < chars.count, chars[i + 1] == "@",
               i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_") {
                prefix = t
                at = i + 1
            }
            if !inString, chars[at] == "@", at + 1 < chars.count, chars[at + 1].isLetter || chars[at + 1] == "_" {
                var j = at + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let name = String(chars[(at + 1)..<j])
                if locals.contains(name) {
                    out += name
                } else {
                    let type = prefix.flatMap { prefixes[$0] } ?? existing(name) ?? standard(name)
                    if !bindings.contains(where: { $0.name == name }) { bindings.append(Binding(name: name, type: type)) }
                    out += "_a_\(name)"
                }
                i = j
                continue
            }
            out.append(ch)
            i += 1
        }
        return (out, bindings)
    }

    /// Does the snippet change the geometry's shape (it then runs on one thread)?
    static func editsShape(_ code: String) -> Bool {
        ["addpoint(", "addprim(", "removepoint(", "removeprim(", "setgroup("].contains { code.contains($0) }
    }

    private static func swiftType(_ t: AttributeType) -> String {
        switch t {
        case .float: "Float"
        case .int: "Int"
        case .vector2: "SIMD2<Float>"
        case .vector3: "SIMD3<Float>"
        case .vector4: "SIMD4<Float>"
        case .string: "String"
        }
    }

    private static func accessor(_ t: AttributeType) -> String {
        switch t {
        case .float: "floats"
        case .int: "ints"
        case .vector2: "vectors2"
        case .vector3: "vectors3"
        case .vector4: "vectors4"
        case .string: "strings"
        }
    }

    /// The whole file the compiler gets, its entry point `proc_wrangle_main`.
    package static func generate(_ code: String, runClass: AttributeClass, existing: (String) -> AttributeType?) -> String {
        let (body, bindings) = rewrite(code, existing: existing)
        let serial = editsShape(code) || bindings.contains { $0.type == .string }
        let number: String = switch runClass {
        case .point: "ptnum"
        case .vertex: "vtxnum"
        case .primitive: "primnum"
        case .detail: "elemnum"
        }
        var s = """
        import Foundation
        import simd
        import Procedural

        @_cdecl("proc_wrangle_main")
        public func procWrangleMain(_ raw: UnsafeMutableRawPointer) {
            let _w = Unmanaged<WrangleContext>.fromOpaque(raw).takeUnretainedValue()
            let numpt = _w.count(.point), numprim = _w.count(.primitive), numvtx = _w.count(.vertex), numelem = _w.count
            _ = (numpt, numprim, numvtx, numelem)
            let _picked = _w.picked
            func point(_ input: Int, _ name: String, _ n: Int) -> Float { _w.pointValue(input, name, n).x }
            func point(_ input: Int, _ name: String, _ n: Int) -> Int { Int(_w.pointValue(input, name, n).x) }
            func point(_ input: Int, _ name: String, _ n: Int) -> SIMD3<Float> { let v = _w.pointValue(input, name, n); return SIMD3(v.x, v.y, v.z) }
            func point(_ input: Int, _ name: String, _ n: Int) -> SIMD4<Float> { _w.pointValue(input, name, n) }
            func prim(_ input: Int, _ name: String, _ n: Int) -> Float { _w.primValue(input, name, n).x }
            func prim(_ input: Int, _ name: String, _ n: Int) -> Int { Int(_w.primValue(input, name, n).x) }
            func prim(_ input: Int, _ name: String, _ n: Int) -> SIMD3<Float> { let v = _w.primValue(input, name, n); return SIMD3(v.x, v.y, v.z) }
            func detail(_ input: Int, _ name: String) -> Float { _w.detailValue(input, name).x }
            func detail(_ input: Int, _ name: String) -> SIMD3<Float> { let v = _w.detailValue(input, name); return SIMD3(v.x, v.y, v.z) }
            func npoints(_ input: Int) -> Int { _w.npoints(input) }
            func nprims(_ input: Int) -> Int { _w.nprims(input) }
            func primpoints(_ input: Int, _ n: Int) -> [Int] { _w.primpoints(input, n) }
            func nearpoint(_ input: Int, _ p: SIMD3<Float>, _ maxDistance: Float = .infinity) -> Int { _w.nearpoint(input, p, maxDistance: maxDistance) }
            func nearpoints(_ input: Int, _ p: SIMD3<Float>, _ radius: Float, _ maxCount: Int = 1_000_000) -> [Int] { _w.nearpoints(input, p, radius, maxCount) }
            func addpoint(_ p: SIMD3<Float>) -> Int { _w.addpoint(p) }
            func addprim(_ points: [Int], closed: Bool = true) -> Int { _w.addprim(points, closed: closed) }
            func removepoint(_ n: Int) { _w.removepoint(n) }
            func removeprim(_ n: Int) { _w.removeprim(n) }
            func setgroup(_ name: String, _ n: Int, _ on: Bool = true) { _w.setgroup(name, n, on) }

        """
        for b in bindings { s += "    let _c_\(b.name) = _w.\(accessor(b.type))(\(literal(b.name)))\n" }
        s += """
            _w.run(parallel: \(serial ? "false" : "true")) { _range in
                for _i in _range {
                    if let _picked, !_picked[_i] { continue }
                    let \(number) = _i
                    _ = \(number)

        """
        for b in bindings { s += "            var _a_\(b.name): \(swiftType(b.type)) = _c_\(b.name)[_i]\n" }
        s += "            ({ () -> Void in\n#sourceLocation(file: \"wrangle\", line: 1)\n"
        s += body
        s += "\n#sourceLocation()\n            })()\n"
        for b in bindings { s += "            _c_\(b.name)[_i] = _a_\(b.name)\n" }
        s += """
                }
            }
        }

        """
        return s
    }

    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
