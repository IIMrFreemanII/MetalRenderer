import Foundation
import simd

/// A graph as Swift (the Material Designer's Copy as Swift): the statements that make it, for MaterialLibrary.
extension MaterialGraph {
    var swiftSource: String {
        var lines = ["var g = MaterialGraph(\(MatSwift.string(name)), size: \(size))"]
        if bits != .inherit { lines.append("g.bits = .\(MatSwift.bits(bits))") }
        if seed != 0 { lines.append("g.seed = \(seed)") }
        let d = MatSurface()
        for (label, value, base) in [("heightDepth", surface.heightDepth, d.heightDepth), ("uvScale", surface.uvScale, d.uvScale),
                                     ("alphaCutoff", surface.alphaCutoff, d.alphaCutoff), ("aoStrength", surface.aoStrength, d.aoStrength),
                                     ("normalStrength", surface.normalStrength, d.normalStrength),
                                     ("emissiveIntensity", surface.emissiveIntensity, d.emissiveIntensity),
                                     ("displacement", surface.displacement, d.displacement), ("displacementMid", surface.displacementMid, d.displacementMid),
                                     ("displacementDetail", surface.displacementDetail, d.displacementDetail)] where value != base {
            lines.append("g.surface.\(label) = \(MatSwift.float(value))")
        }
        if surface.normalDirectX { lines.append("g.surface.normalDirectX = true") }
        if surface.shaderMode { lines.append("g.surface.shaderMode = true") }
        for i in inputs {
            lines.append("g.inputs.append(MatGraphInput(\(MatSwift.string(i.name)), \(MatSwift.string(i.title)), \(MatSwift.param(i.value))"
                         + (i.span.map { ", span: \(MatSwift.float($0.lowerBound))...\(MatSwift.float($0.upperBound))" } ?? "") + "))")
        }
        lines.append("g.nodes = [")
        for n in nodes {
            lines.append("    MatNode(.\(n.kind.rawValue)\(MatSwift.params(n.params)), id: \(MatSwift.string(n.id)), at: [\(MatSwift.float(n.at.x)), \(MatSwift.float(n.at.y))]),")
        }
        lines.append("]")
        for (k, n) in nodes.enumerated() {
            switch n.size {
            case .inherit: break
            case .relative(let r): lines.append("g.nodes[\(k)].size = .relative(\(r))")
            case .absolute(let a): lines.append("g.nodes[\(k)].size = .absolute(\(a))")
            }
            if n.bits != .inherit { lines.append("g.nodes[\(k)].bits = .\(MatSwift.bits(n.bits))") }
            if !n.exposed.isEmpty {
                lines.append("g.nodes[\(k)].exposed = [" + n.exposed.sorted { $0.key < $1.key }.map { "\(MatSwift.string($0.key)): \(MatSwift.string($0.value))" }.joined(separator: ", ") + "]")
            }
            if let f = n.function {
                lines.append("g.nodes[\(k)].function = MatFunction(nodes: [")
                for fn in f.nodes {
                    lines.append("    MatFnNode(.\(fn.kind.rawValue)\(MatSwift.params(fn.params)), id: \(MatSwift.string(fn.id)), at: [\(MatSwift.float(fn.at.x)), \(MatSwift.float(fn.at.y))]),")
                }
                lines.append("], links: [" + f.links.map(MatSwift.link).joined(separator: ", ") + "])")
            }
        }
        lines.append("g.links = [")
        for l in links { lines.append("    \(MatSwift.link(l)),") }
        lines.append("]")
        lines.append("return g")
        return lines.joined(separator: "\n")
    }
}

enum MatSwift {
    static func string(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n") + "\"" }
    static func float(_ f: Float) -> String { f == f.rounded() && abs(f) < 1e6 ? String(Int(f)) : "\(f)" }
    static func bits(_ b: MatBits) -> String { b == .b8 ? "b8" : b == .b16 ? "b16" : b == .b32 ? "b32" : "inherit" }
    static func link(_ l: MatLink) -> String { "MatLink(\(string(l.from)), \(string(l.output)), to: \(string(l.to)), \(string(l.input)))" }

    static func params(_ p: [String: MatParam]) -> String {
        guard !p.isEmpty else { return "" }
        return ", [" + p.sorted { $0.key < $1.key }.map { "\(string($0.key)): \(param($0.value))" }.joined(separator: ", ") + "]"
    }

    static func param(_ v: MatParam) -> String {
        switch v {
        case .float(let f): return ".float(\(float(f)))"
        case .int(let i): return ".int(\(i))"
        case .bool(let b): return ".bool(\(b))"
        case .vec2(let x): return ".vec2([\(float(x.x)), \(float(x.y))])"
        case .color(let c): return ".color([\(float(c.x)), \(float(c.y)), \(float(c.z)), \(float(c.w))])"
        case .choice(let s): return ".choice(\(string(s)))"
        case .text(let s): return ".text(\(string(s)))"
        case .curve(let c):
            return ".curve(VFXCurve([" + c.keys.map { "[\(float($0.x)), \(float($0.y))]" }.joined(separator: ", ") + "]\(c.smooth ? ", smooth: true" : "")))"
        case .gradient(let g):
            return ".gradient(VFXGradient([" + g.keys.map { k in
                ".init(\(float(k.t)), [\(float(k.color.x)), \(float(k.color.y)), \(float(k.color.z)), \(float(k.color.w))])"
            }.joined(separator: ", ") + "]))"
        }
    }
}
