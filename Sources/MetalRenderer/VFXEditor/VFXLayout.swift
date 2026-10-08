import CoreGraphics
import simd

/// Where the VFX editor's canvas draws an effect's graph, in the graph's units (a point at zoom 1): each emitter a
/// column of its four contexts' blocks (a row a block, and a row more for each of its pins a wire can go into), each
/// operator node a box of its inputs (left) and outputs (right); and every pin's place, which the wires join. An
/// effect never laid out (the built-in ones: every emitter, or every node, at the origin) is arranged: its nodes in
/// columns by how far they are from the blocks they feed, its emitters side by side to their right.
struct VFXLayout {
    static let emitterWidth: CGFloat = 250
    static let emitterSpacing: Float = 290
    static let nodeWidth: CGFloat = 176
    static let header: CGFloat = 30
    static let contextHeader: CGFloat = 22
    static let blockTitle: CGFloat = 22
    static let row: CGFloat = 18
    static let nodeHeader: CGFloat = 24
    static let gap: CGFloat = 6

    struct Pin: Hashable {
        var owner: String
        var name: String
    }

    /// The effect with every emitter and node where it is drawn.
    let arranged: VFXEffect
    private(set) var emitters: [String: CGRect] = [:]
    /// Per emitter, its contexts' header rows.
    private(set) var contexts: [String: [VFXContext: CGRect]] = [:]
    private(set) var blocks: [String: CGRect] = [:]
    private(set) var nodes: [String: CGRect] = [:]
    /// Inputs (blocks' and nodes') and outputs (nodes'): the pins' centres.
    private(set) var inputs: [Pin: CGPoint] = [:]
    private(set) var outputs: [Pin: CGPoint] = [:]
    /// Around everything.
    private(set) var bounds = CGRect.zero

    init(_ effect: VFXEffect) {
        arranged = VFXLayout.arrange(effect)
        for e in arranged.emitters { place(e) }
        for n in arranged.nodes { place(n) }
        bounds = (Array(emitters.values) + Array(nodes.values)).reduce(CGRect.null) { $0.union($1) }
        if bounds.isNull { bounds = .zero }
    }

    /// The pins of a block drawn as rows: those a wire can go into.
    static func rows(_ b: VFXBlock) -> [VFXPinSpec] { b.kind.spec.pins.filter { $0.wire != nil } }

    static func height(_ b: VFXBlock) -> CGFloat { blockTitle + CGFloat(rows(b).count) * row }

    static func height(_ e: VFXEmitter) -> CGFloat {
        header + VFXContext.allCases.reduce(0) { h, c in
            h + contextHeader + (e[c].isEmpty ? row : e[c].reduce(0) { $0 + height($1) }) + gap
        } + gap
    }

    static func height(_ n: VFXNode) -> CGFloat {
        let spec = n.kind.spec
        return nodeHeader + CGFloat(max(spec.inputs.count, spec.outputs.count)) * row + gap
    }

    private mutating func place(_ e: VFXEmitter) {
        let origin = CGPoint(x: CGFloat(e.canvas.x), y: CGFloat(e.canvas.y))
        let w = VFXLayout.emitterWidth
        emitters[e.id] = CGRect(x: origin.x, y: origin.y, width: w, height: VFXLayout.height(e))
        var y = origin.y + VFXLayout.header
        var rects: [VFXContext: CGRect] = [:]
        for c in VFXContext.allCases {
            rects[c] = CGRect(x: origin.x, y: y, width: w, height: VFXLayout.contextHeader)
            y += VFXLayout.contextHeader
            if e[c].isEmpty { y += VFXLayout.row }
            for b in e[c] {
                blocks[b.id] = CGRect(x: origin.x + 6, y: y, width: w - 12, height: VFXLayout.height(b))
                var r = y + VFXLayout.blockTitle
                for p in VFXLayout.rows(b) {
                    inputs[Pin(owner: b.id, name: p.name)] = CGPoint(x: origin.x, y: r + VFXLayout.row / 2)
                    r += VFXLayout.row
                }
                y += VFXLayout.height(b)
            }
            y += VFXLayout.gap
        }
        contexts[e.id] = rects
    }

    private mutating func place(_ n: VFXNode) {
        let origin = CGPoint(x: CGFloat(n.canvas.x), y: CGFloat(n.canvas.y))
        let spec = n.kind.spec
        nodes[n.id] = CGRect(x: origin.x, y: origin.y, width: VFXLayout.nodeWidth, height: VFXLayout.height(n))
        for (i, p) in spec.inputs.enumerated() where p.wire != nil {
            inputs[Pin(owner: n.id, name: p.name)] = CGPoint(x: origin.x, y: origin.y + VFXLayout.nodeHeader + (CGFloat(i) + 0.5) * VFXLayout.row)
        }
        for (i, o) in spec.outputs.enumerated() {
            outputs[Pin(owner: n.id, name: o.name)] = CGPoint(x: origin.x + VFXLayout.nodeWidth,
                                                              y: origin.y + VFXLayout.nodeHeader + (CGFloat(i) + 0.5) * VFXLayout.row)
        }
    }

    /// The input pin nearest `p` within `radius`, if one is.
    func input(near p: CGPoint, radius: CGFloat) -> Pin? {
        let near = inputs.filter { hypot($0.value.x - p.x, $0.value.y - p.y) <= radius }
        return near.min { hypot($0.value.x - p.x, $0.value.y - p.y) < hypot($1.value.x - p.x, $1.value.y - p.y) }?.key
    }

    /// The ids whose boxes meet `r` (nodes, emitters).
    func items(in r: CGRect) -> Set<String> {
        Set(nodes.filter { $0.value.intersects(r) }.keys).union(emitters.filter { $0.value.intersects(r) }.keys)
    }

    // MARK: - Arranging

    /// `effect` with its emitters, or its nodes, arranged if they were never laid out (all at the origin).
    static func arrange(_ effect: VFXEffect) -> VFXEffect {
        var fx = effect
        let nodesUnplaced = fx.nodes.count > 1 && fx.nodes.allSatisfy { $0.canvas == .zero }
        if nodesUnplaced {
            // Columns by depth: a node feeding only blocks is next to them; one feeding it, a column further left.
            var depth: [String: Int] = [:]
            func d(_ id: String, _ seen: Set<String>) -> Int {
                if let k = depth[id] { return k }
                let consumers = fx.links.filter { $0.from == id }.compactMap { fx.node($0.to)?.id }.filter { !seen.contains($0) }
                let k = 1 + (consumers.map { d($0, seen.union([id])) }.max() ?? 0)
                depth[id] = k
                return k
            }
            var columnY: [Int: Float] = [:]
            for i in fx.nodes.indices {
                let k = d(fx.nodes[i].id, [])
                let y = columnY[k] ?? 0
                fx.nodes[i].canvas = SIMD2(-Float(k) * 210, y)
                columnY[k] = y + Float(height(fx.nodes[i])) + 16
            }
        }
        if fx.emitters.count > 0 && fx.emitters.allSatisfy({ $0.canvas == .zero }) {
            let right = fx.nodes.map { $0.canvas.x + Float(nodeWidth) }.max().map { max($0 + 80, 0) } ?? 0
            for i in fx.emitters.indices { fx.emitters[i].canvas = SIMD2(right + Float(i) * emitterSpacing, 0) }
        }
        return fx
    }
}
