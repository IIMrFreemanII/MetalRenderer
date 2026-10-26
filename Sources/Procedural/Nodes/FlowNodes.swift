import Foundation
import simd

/// Attribute Wrangle (Swift snippets) and the For-Each loop's pieces.
enum FlowNodes {
    static func wrangle(_ c: inout ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let code = c.string("snippet")
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return g }
        let cls = c.attributeClass("class")
        let source = WrangleSource.generate(code, runClass: cls) { name in
            name == "P" ? .vector3 : g.table(cls)[name]?.type
        }
        let entry = try WrangleCompiler.shared.entry(source).get()
        let picked = cls == .detail || GroupPattern.isEverything(c.string("group")) ? nil : try c.group(in: g, cls)
        let context = WrangleContext(geo: g, inputs: c.inputs, runClass: cls, picked: picked)
        withExtendedLifetime(context) { entry(Unmanaged.passUnretained(context).toOpaque()) }
        return context.finish()
    }

    /// The geometry in pieces, for a For-Each loop: by a primitive (or point) attribute's values in the order they come,
    /// by connectivity if there is no such attribute, or a point each.
    static func pieces(_ g: ProcGeo, method: String, attribute: String) -> [ProcGeo] {
        if method == "points" {
            return (0..<g.pointCount).map { i in
                g.keeping(prims: [Bool](repeating: false, count: g.primCount), points: (0..<g.pointCount).map { $0 == i })
            }
        }
        // A key per primitive: its attribute's value (as text), or its first point's piece.
        var keys: [String]
        if let a = g.prims[attribute] {
            keys = (0..<g.primCount).map { a.string($0) }
        } else if let a = g.points[attribute] {
            keys = (0..<g.primCount).map { p in g.vertexRange(p).first.map { a.string(Int(g.vertexPoint[$0])) } ?? "" }
        } else {
            let piece = AttributeNodes.pieces(g)
            keys = (0..<g.primCount).map { p in g.vertexRange(p).first.map { String(piece[Int(g.vertexPoint[$0])]) } ?? "" }
        }
        var order: [String] = [], members: [String: [Bool]] = [:]
        for (p, k) in keys.enumerated() {
            if members[k] == nil { order.append(k); members[k] = [Bool](repeating: false, count: g.primCount) }
            members[k]![p] = true
        }
        return order.prefix(100_000).map { g.keeping(prims: members[$0]!) }
    }
}
