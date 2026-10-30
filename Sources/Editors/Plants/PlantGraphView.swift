import AppKit
import Plants
import SwiftUI
import simd

/// The plant's graph, as Unreal's vegetation editor has it: nodes top to bottom, what each makes wired into the next.
/// Tab adds a node (wired below the selected one), a drag from an output to an input wires them, Delete removes, F
/// frames, L lays out.
struct PlantGraphView: View {
    @ObservedObject var model: PlantEditorModel

    var body: some View {
        let g = model.graph
        GraphCanvas(model: model, bounds: PlantGraphLayout.bounds(g),
                    minimap: g.nodes.map { .init(rect: PlantGraphLayout.rect($0), color: PlantNodeView.color($0.kind), rounded: true) },
                    items: { PlantGraphLayout.items(in: $0, of: model.graph) },
                    inputNear: { PlantGraphLayout.input(near: $0, in: model.graph) }) { drags in
            graph(g, drags)
        } menu: { at in
            ForEach(PlantNodeKind.adding, id: \.self) { kind in Button(kind.title) { model.addNode(kind, at: at) } }
            Divider()
            Button("Lay Out All  L") { model.layoutAll() }
            Button("Frame All  F") { model.frameAll(in: model.canvasSize) }
        } search: {
            GraphNodeSearch(placeholder: "Add a node", items: PlantNodeKind.adding.map { kind in
                .init(id: kind.rawValue, title: kind.title, detail: "") { model.addNode(kind, at: model.searchAt) }
            }, close: { model.closeSearch() })
        }
    }

    @ViewBuilder private func graph(_ g: PlantGraph, _ drags: GraphDrags<PlantEditorModel>) -> some View {
        let area = PlantGraphLayout.bounds(g).insetBy(dx: -400, dy: -400)
        ZStack(alignment: .topLeading) {
            GraphWires(area: area, wires: wires(g), dragged: drags.wire.flatMap { w in
                Int32(w.from).flatMap(g.node).map { GraphWires.Wire(from: PlantGraphLayout.output($0), to: w.to, color: GraphColors.selected, selected: true) }
            }, vertical: true)
            ForEach(g.nodes, id: \.id) { n in
                PlantNodeView(model: model, node: n, drags: drags)
            }
        }
    }

    private func wires(_ g: PlantGraph) -> [GraphWires.Wire] {
        var out: [GraphWires.Wire] = []
        for n in g.nodes {
            for (i, from) in n.inputs.enumerated() {
                guard let a = g.node(from) else { continue }
                let selected = model.selection.contains("\(n.id)") || model.selection.contains("\(a.id)")
                out.append(.init(from: PlantGraphLayout.output(a), to: PlantGraphLayout.input(n, i),
                                 color: selected ? GraphColors.selected : PlantNodeView.color(a.kind), selected: selected))
            }
        }
        return out
    }
}

/// One node: its kind and its name in the file, a line of what it does, its pins on top and its output under it.
struct PlantNodeView: View {
    @ObservedObject var model: PlantEditorModel
    let node: PlantNode
    let drags: GraphDrags<PlantEditorModel>

    static func color(_ kind: PlantNodeKind) -> Color {
        switch kind {
        case .grow, .growMore: return Color(red: 0.36, green: 0.6, blue: 0.32)
        case .grafts, .spurs, .distribute: return Color(red: 0.75, green: 0.55, blue: 0.25)
        case .carve, .gravity, .manualEdit: return Color(red: 0.7, green: 0.38, blue: 0.3)
        case .boneReduction: return Color(red: 0.8, green: 0.3, blue: 0.68)
        case .skeleton: return Color(red: 0.55, green: 0.42, blue: 0.3)
        case .leaves, .twig, .palette: return Color(red: 0.45, green: 0.68, blue: 0.5)
        case .output: return Color(red: 0.32, green: 0.52, blue: 0.78)
        case .grass: return Color(red: 0.5, green: 0.7, blue: 0.3)
        case .code, .statement: return Color(red: 0.55, green: 0.4, blue: 0.75)
        }
    }

    private var summary: String {
        switch node.settings {
        case .grow(let p): return "\(p.cycles) cycles to \(String(format: "%g", p.targetHeight)) m"
        case .growMore(let m): return "\(m.cycles) more cycles"
        case .grafts(let g): return "\(g.perBranch) a branch"
        case .spurs(let s): return String(format: "%.2g m long", s.length)
        case .carve(let c): return String(format: "the foot's %.0f%%", c.share * 100)
        case .gravity(let g): return String(format: g.mode == .gravity ? "pull %.2g" : "to the light %.2g", g.strength)
        case .manualEdit(let e): return e.seed == 0 ? "not edited yet" : "\(e.points.count) moved, \(e.removed.count) cut"
        case .boneReduction(let b): return String(format: "strength %.2g", b.strength)
        case .skeleton(let w): return w.ribbon ? "ribbons" : String(format: "thinning %.2g", w.thinning)
        case .leaves(let l): return "\(l.shape.rawValue), \(String(format: "%g", l.perMetre)) a metre"
        case .twig: return "wood and leaves"
        case .palette(let p): return "\(p.count) twigs"
        case .distribute(let t): return String(format: "every %.2g m", t.spacing)
        case .output: return ""
        case .grass(let g): return "\(g.blades) blades"
        case .code: return "a function"
        case .statement: return "runs when compiled"
        }
    }

    var body: some View {
        let L = PlantGraphLayout.self, at = node.at ?? .zero
        let w = CGFloat(L.size.x), h = CGFloat(L.size.y)
        let selected = model.selection.contains("\(node.id)")
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Rectangle().fill(PlantNodeView.color(node.kind)).frame(width: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.kind.title).font(.system(size: 11, weight: .semibold)).foregroundColor(GraphColors.text)
                    HStack(spacing: 4) {
                        Text(node.name).foregroundColor(GraphColors.selected.opacity(0.85))
                        Text(summary).foregroundColor(GraphColors.dim)
                    }
                    .font(.system(size: 9)).lineLimit(1)
                }
                .padding(.horizontal, 7)
                Spacer(minLength: 0)
            }
            .frame(width: w, height: h)
            .background(GraphColors.node)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? GraphColors.selected : Color.black.opacity(0.55), lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .gesture(drags.header("\(node.id)"))
            .contextMenu {
                Button("Delete") { model.selection = ["\(node.id)"]; model.deleteSelection() }
            }
            ForEach(0..<L.pinCount(node), id: \.self) { i in
                let p = L.input(node, i), wired = node.inputs.indices.contains(i) && node.inputs[i] >= 0
                GraphPinDot(color: PlantNodeView.color(node.kind), wired: wired)
                    .offset(x: p.x - CGFloat(at.x) - 9, y: -9)
                    .help(node.kind.pins.indices.contains(i) ? node.kind.pins[i].name : "")
                    .gesture(drags.fromInput("\(node.id)", "\(i)"))
            }
            if node.kind != .output && node.kind != .grass {
                GraphPinDot(color: PlantNodeView.color(node.kind), wired: false)
                    .offset(x: w / 2 - 9, y: h - 9)
                    .gesture(drags.fromOutput("\(node.id)", "out"))
            }
        }
        .offset(x: CGFloat(at.x), y: CGFloat(at.y))
    }
}

/// The graph in its own hosting view inside the editor's window: its keys, scrolls and pinches (GraphHostingView).
struct PlantGraphHost: NSViewRepresentable {
    let model: PlantEditorModel

    func makeNSView(context: Context) -> GraphHostingView {
        let host = GraphHostingView(rootView: AnyView(PlantGraphView(model: model)))
        host.model = model
        host.keys = { [weak model] event in
            guard let model, model.searchAt == nil else { return false }
            if event.charactersIgnoringModifiers?.lowercased() == "l" {
                model.layoutAll()
                return true
            }
            return false
        }
        model.focusCanvas = { [weak host] in
            guard let host, let window = host.window, window.firstResponder !== host else { return }
            window.makeFirstResponder(host)
        }
        return host
    }

    func updateNSView(_ nsView: GraphHostingView, context: Context) {}
}
