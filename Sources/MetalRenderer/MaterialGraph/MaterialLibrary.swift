import Foundation
import simd

/// Builds a material graph in Swift: nodes added with their parameters and what is wired into them, outputs named
/// by channel; `graph` lays the nodes out in columns (each right of what feeds it).
///
///     var b = MatBuilder("Red Bricks")
///     let bricks = b.node(.bricks, ["rows": .int(10)])
///     b.output(.normal, b.node(.normal, ["intensity": .float(6)], ["in": bricks]))
struct MatBuilder {
    /// A node's output, to wire: `ref` is its "out", `ref["random"]` another.
    struct Ref {
        let id: String
        var output = "out"
        subscript(_ output: String) -> Ref { Ref(id: id, output: output) }
    }

    private var g: MaterialGraph

    init(_ name: String, size: Int = 10) { g = MaterialGraph(name, size: size) }

    @discardableResult
    mutating func node(_ kind: MatOpKind, _ params: [String: MatParam] = [:], _ inputs: [String: Ref] = [:], id: String? = nil) -> Ref {
        let id = VFXEffect.unique(id ?? kind.rawValue, g.allIDs)
        g.nodes.append(MatNode(kind, params, id: id))
        for (pin, r) in inputs.sorted(by: { $0.key < $1.key }) { g.links.append(MatLink(r.id, r.output, to: id, pin)) }
        return Ref(id: id)
    }

    /// An output node of channel `c`, fed by `from`.
    mutating func output(_ c: MatChannel, _ from: Ref) {
        node(.output, ["usage": .choice(c.rawValue), "name": .text(c.rawValue)], ["in": from], id: c.rawValue)
    }

    mutating func set(_ change: (inout MaterialGraph) -> Void) { change(&g) }

    var graph: MaterialGraph { MatLayout.arranged(g) }
}

/// The built-in graphs: the Material Designer's starters, and what a scene can name before anything is saved.
enum MaterialLibrary {
    static let all: [MaterialGraph] = [redBricks()]
    static var names: [String] { all.map(\.name) }
    static func named(_ name: String) -> MaterialGraph? { all.first { $0.name == name } }

    /// Colours as sRGB values (what the graph works in), alpha 1.
    static func rgb(_ r: Float, _ g: Float, _ b: Float) -> MatParam { .color([r, g, b, 1]) }
    static func gradient(_ keys: (Float, SIMD3<Float>)...) -> MatParam {
        .gradient(VFXGradient(keys.map { VFXGradient.Key($0.0, SIMD4($0.1, 1)) }))
    }

    /// Red bricks in pale mortar, each brick its own shade and height, dirt in the joints.
    static func redBricks() -> MaterialGraph {
        var b = MatBuilder("Red Bricks")
        let bricks = b.node(.bricks, ["columns": .int(4), "rows": .int(10), "gap": .float(0.008), "bevel": .float(0.3),
                                      "heightRandom": .float(0.25)])
        let noise = b.node(.fractalSum, ["scale": .int(8), "octaves": .int(7), "roughness": .float(0.55)])
        let pits = b.node(.levels, ["inLow": .float(0.25), "inHigh": .float(0.75), "outLow": .float(0.82)], ["in": noise])
        let height = b.node(.blend, ["mode": .choice("multiply")], ["fg": pits, "bg": bricks])
        let mortar = b.node(.histogramScan, ["position": .float(0.97), "contrast": .float(0.95), "invert": .bool(true)], ["in": bricks])
        let shade = b.node(.gradientMap, ["gradient": gradient((0, [0.42, 0.13, 0.08]), (0.5, [0.58, 0.2, 0.12]), (1, [0.68, 0.32, 0.2]))],
                           ["in": bricks["random"]])
        let speckle = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.5)], ["fg": noise, "bg": shade])
        let mortarColor = b.node(.uniformColor, ["color": rgb(0.62, 0.58, 0.52)])
        let color = b.node(.blend, ["mode": .choice("copy")], ["fg": mortarColor, "bg": speckle, "mask": mortar])
        let ao = b.node(.ambientOcclusion, ["radius": .float(0.03)], ["in": height])
        let dirty = b.node(.blend, ["mode": .choice("multiply"), "opacity": .float(0.6)], ["fg": ao, "bg": color])
        let rough = b.node(.levels, ["outLow": .float(0.95), "outHigh": .float(0.72)], ["in": height])
        b.output(.baseColor, dirty)
        b.output(.normal, b.node(.normal, ["intensity": .float(5)], ["in": height]))
        b.output(.roughness, rough)
        b.output(.ambientOcclusion, ao)
        b.output(.height, height)
        return b.graph
    }
}

/// Where the editor draws a graph's nodes, in the graph's units: a node a box of its header, its thumbnail, its
/// inputs (left) and outputs (right). A graph never laid out (every node at the origin: the built-in ones) is
/// arranged in columns by how far each node is from the graph's sources.
enum MatLayout {
    static let nodeWidth: CGFloat = 150
    static let header: CGFloat = 22
    static let thumb: CGFloat = 112
    static let row: CGFloat = 16
    static let gap: CGFloat = 6
    static let columnSpacing: Float = 210

    static func height(inputs: Int, outputs: Int) -> CGFloat { header + thumb + CGFloat(max(inputs, outputs, 1)) * row + gap }

    /// `g` with its nodes placed, if it was never laid out.
    static func arranged(_ g: MaterialGraph) -> MaterialGraph {
        guard g.nodes.count > 1, g.nodes.allSatisfy({ $0.at == .zero }) else { return g }
        var out = g
        var depth: [String: Int] = [:]
        func d(_ id: String, _ seen: Set<String>) -> Int {
            if let k = depth[id] { return k }
            let feeds = g.links.filter { $0.to == id }.map(\.from).filter { !seen.contains($0) }
            let k = feeds.isEmpty ? 0 : 1 + (feeds.map { d($0, seen.union([id])) }.max() ?? 0)
            depth[id] = k
            return k
        }
        var columnY: [Int: Float] = [:]
        for i in out.nodes.indices {
            let k = d(out.nodes[i].id, [])
            let y = columnY[k] ?? 0
            out.nodes[i].at = SIMD2(Float(k) * columnSpacing, y)
            let spec = out.nodes[i].kind.spec
            columnY[k] = y + Float(height(inputs: spec.inputs.count, outputs: spec.outputs.count)) + 24
        }
        return out
    }
}
