import Procedural
import SwiftUI
import simd

/// Houdini's look, for the Procedural workspace only (the rest of the Modeller keeps Blender's): mid-grey panes, the
/// network's dotted grey grid, light grey nodes tinted by family, the flags' colours (bypass yellow, template pink,
/// display blue, render purple), the selection's yellow.
enum ProcTheme {
    static let network = Color(red: 0.235, green: 0.235, blue: 0.235)
    static let pane = Color(red: 0.227, green: 0.227, blue: 0.227)
    static let paneHeader = Color(red: 0.19, green: 0.19, blue: 0.19)
    static let field = Color(red: 0.15, green: 0.15, blue: 0.15)
    static let fieldBorder = Color(white: 0.11)
    static let text = Color(white: 0.85)
    static let dim = Color(white: 0.58)
    static let label = Color(white: 0.75)
    static let wire = Color(white: 0.72)
    static let selected = Color(red: 0.99, green: 0.82, blue: 0.20)
    static let current = Color(red: 1.0, green: 0.92, blue: 0.55)
    static let bypass = Color(red: 0.95, green: 0.80, blue: 0.20)
    static let template = Color(red: 0.88, green: 0.45, blue: 0.70)
    static let display = Color(red: 0.25, green: 0.56, blue: 0.95)
    static let render = Color(red: 0.62, green: 0.38, blue: 0.92)
    static let flagOff = Color(white: 0.30)
    static let error = Color(red: 0.92, green: 0.25, blue: 0.22)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.20)
    static let slider = Color(red: 0.32, green: 0.45, blue: 0.62)

    static let font = Font.system(size: 11)
    static let small = Font.system(size: 10)
    static let mono = Font.system(size: 11, design: .monospaced)

    static let canvas = GraphCanvasStyle(background: network, dots: true, minor: Color.white.opacity(0.10), major: Color.white.opacity(0.22))

    /// A node's body colour: its family's tint.
    static func body(_ kind: ProcNodeKind) -> Color {
        let c = kind.spec.family.color
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

/// Where the network view draws nodes (the graph's units): each node's body from its `at`, its inputs along its top,
/// its output under it, its name to its right.
enum ProcNetworkLayout {
    static let size = SIMD2<Float>(96, 26)
    static let flag: Float = 12
    static let rowGap: Float = 64
    static let columnGap: Float = 170
    /// Room for the name and type to the right of the body (box select, framing).
    static let label: Float = 110

    static func rect(_ n: ProcNode) -> CGRect {
        CGRect(x: CGFloat(n.at.x), y: CGFloat(n.at.y), width: CGFloat(size.x), height: CGFloat(size.y))
    }

    static func output(_ n: ProcNode) -> CGPoint {
        CGPoint(x: CGFloat(n.at.x + size.x / 2), y: CGFloat(n.at.y + size.y))
    }

    /// The input slots along the top: a node's inputs, or a multi-input node's wires and one more.
    static func inputCount(_ g: ProcGraph, _ n: ProcNode) -> Int {
        n.kind.spec.multiInput ? g.inputs(of: n.id).count + 1 : n.kind.spec.inputs.count
    }

    static func input(_ n: ProcNode, _ i: Int, of count: Int) -> CGPoint {
        let inner = size.x - 2 * flag
        let x = n.at.x + flag + inner * Float(i + 1) / Float(count + 1)
        return CGPoint(x: CGFloat(x), y: CGFloat(n.at.y))
    }

    static func bounds(_ g: ProcGraph) -> CGRect {
        var r = CGRect.null
        for n in g.nodes { r = r.union(rect(n).insetBy(dx: 0, dy: -10)).union(rect(n).offsetBy(dx: CGFloat(label), dy: 0)) }
        return r.isNull ? CGRect(x: 0, y: 0, width: 200, height: 100) : r
    }

    /// The input slot nearest `p` within `radius`, or the node under it (its first free input; a merge: a new one).
    static func input(near p: CGPoint, in g: ProcGraph, radius: CGFloat = 14) -> GraphPin? {
        var best: (GraphPin, CGFloat)?
        for n in g.nodes {
            let count = inputCount(g, n)
            for i in 0..<count {
                let q = input(n, i, of: count)
                let d = hypot(q.x - p.x, q.y - p.y)
                if d < radius, d < best?.1 ?? .infinity { best = (GraphPin(owner: n.id, name: "\(i)"), d) }
            }
        }
        if let best { return best.0 }
        for n in g.nodes where count(n) > 0 && rect(n).insetBy(dx: -4, dy: -4).contains(p) {
            return GraphPin(owner: n.id, name: "node")
        }
        return nil
    }

    private static func count(_ n: ProcNode) -> Int { n.kind.spec.inputs.count }

    static func items(in r: CGRect, of g: ProcGraph) -> Set<String> {
        Set(g.nodes.filter { rect($0).intersects(r) }.map(\.id))
    }
}
