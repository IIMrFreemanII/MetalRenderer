import CoreGraphics
import Plants
import simd

/// Where a plant's nodes are on the canvas: top to bottom in the order they run, as Unreal's vegetation graph flows,
/// the twig's stages a column left of the plant's.
enum PlantGraphLayout {
    static let size = SIMD2<Float>(212, 56)
    static let rowGap: Float = 92
    static let columnGap: Float = 268

    static func rect(_ n: PlantNode) -> CGRect {
        let at = n.at ?? .zero
        return CGRect(x: CGFloat(at.x), y: CGFloat(at.y), width: CGFloat(size.x), height: CGFloat(size.y))
    }

    /// How many input pins it shows.
    static func pinCount(_ n: PlantNode) -> Int { n.kind == .statement ? n.inputs.count : n.kind.pins.count }

    static func input(_ n: PlantNode, _ i: Int) -> CGPoint {
        let at = n.at ?? .zero
        return CGPoint(x: CGFloat(at.x + size.x * Float(i + 1) / Float(pinCount(n) + 1)), y: CGFloat(at.y))
    }

    static func output(_ n: PlantNode) -> CGPoint {
        let at = n.at ?? .zero
        return CGPoint(x: CGFloat(at.x + size.x / 2), y: CGFloat(at.y + size.y))
    }

    static func bounds(_ g: PlantGraph) -> CGRect {
        var r = CGRect.null
        for n in g.nodes { r = r.union(rect(n).insetBy(dx: 0, dy: -10)) }
        return r.isNull ? CGRect(x: 0, y: 0, width: 200, height: 100) : r
    }

    static func items(in r: CGRect, of g: PlantGraph) -> Set<String> {
        Set(g.nodes.filter { rect($0).intersects(r) }.map { "\($0.id)" })
    }

    static func input(near p: CGPoint, in g: PlantGraph, radius: CGFloat = 14) -> GraphPin? {
        var best: (GraphPin, CGFloat)?
        for n in g.nodes where n.kind != .statement {
            for i in 0..<pinCount(n) {
                let q = input(n, i), d = hypot(q.x - p.x, q.y - p.y)
                if d < radius, d < best?.1 ?? .infinity { best = (GraphPin(owner: "\(n.id)", name: "\(i)"), d) }
            }
        }
        return best?.0
    }

    /// `g` with its nodes that have no place given one; with `all`, every one.
    static func laidOut(_ g: PlantGraph, all: Bool = false) -> PlantGraph {
        guard all || g.nodes.contains(where: { $0.at == nil }) else { return g }
        var out = g
        var row: [Int32: Int] = [:]
        for n in g.nodes { row[n.id] = (n.inputs.compactMap { row[$0] }.max() ?? -1) + 1 }
        var taken: [SIMD2<Int>: Int] = [:]
        for i in out.nodes.indices where all || out.nodes[i].at == nil {
            let n = out.nodes[i]
            let column = n.side == .twig ? 0 : 1, y = row[n.id] ?? 0
            let k = taken[SIMD2(column, y), default: 0]
            taken[SIMD2(column, y)] = k + 1
            out.nodes[i].at = [Float(column) * columnGap + Float(k) * 28, Float(y) * rowGap + Float(k) * 28]
        }
        return out
    }
}
