import AppKit
import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants
import SwiftUI
import simd

/// How the Project Graph shows each kind of node and edge.
enum ProjectGraphStyle {
    static func color(_ kind: ProjectGraph.Kind, asset: AssetKey.Kind? = nil) -> Color {
        switch kind {
        case .project: return Color(white: 0.85)
        case .scene: return Color(red: 0.35, green: 0.55, blue: 0.95)
        case .folder, .system: return Color(red: 0.55, green: 0.58, blue: 0.64)
        case .group: return Color(red: 0.45, green: 0.62, blue: 0.68)
        case .aggregate: return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .object, .member: return Color(red: 0.3, green: 0.72, blue: 0.68)
        case .light: return Color(red: 0.98, green: 0.82, blue: 0.3)
        case .effect: return Color(red: 0.98, green: 0.52, blue: 0.25)
        case .tiles: return Color(red: 0.5, green: 0.65, blue: 0.4)
        case .assets, .assetKind: return Color(red: 0.42, green: 0.7, blue: 0.42)
        case .asset: return asset?.isGenerator == true ? Color(red: 0.92, green: 0.6, blue: 0.35) : Color(red: 0.48, green: 0.8, blue: 0.45)
        case .sources, .source: return Color(red: 0.88, green: 0.48, blue: 0.7)
        }
    }

    static func color(_ kind: ProjectGraph.EdgeKind) -> Color {
        switch kind {
        case .child: return Color.white.opacity(0.22)
        case .sharedAsset: return Color(red: 0.48, green: 0.8, blue: 0.45)
        case .generatedFrom: return Color(red: 0.92, green: 0.6, blue: 0.35)
        case .runtime: return Color(red: 0.95, green: 0.4, blue: 0.4)
        case .source: return Color(red: 0.88, green: 0.48, blue: 0.7)
        }
    }

    static func dash(_ kind: ProjectGraph.EdgeKind) -> [CGFloat] {
        switch kind {
        case .child: return []
        case .sharedAsset: return [5, 4]
        case .generatedFrom: return [8, 4]
        case .runtime: return [2, 3]
        case .source: return [1, 4]
        }
    }

    static func symbol(_ kind: ProjectGraph.Kind) -> String {
        switch kind {
        case .project: return "folder.circle"
        case .scene: return "film"
        case .folder: return "folder"
        case .system: return "square.stack.3d.up"
        case .group: return "square.on.square"
        case .aggregate: return "square.grid.3x3"
        case .object: return "cube"
        case .member: return "cube.transparent"
        case .light: return "lightbulb"
        case .effect: return "sparkles"
        case .tiles: return "map"
        case .assets: return "shippingbox"
        case .assetKind: return "tray.full"
        case .asset: return "shippingbox.fill"
        case .sources: return "chevron.left.forwardslash.chevron.right"
        case .source: return "doc.text"
        }
    }
}

/// The graph drawn: its shown nodes where the layout put them, sized by what is under them, the tree's links and the
/// references (dashed, by kind), names where there is room. A drag on a node moves it (the force layout pins it where it
/// is let go), on the grid pans (Shift: selects a box); a double-click opens its editor, or opens it. Scroll pans and
/// pinch zooms (GraphHostingView).
struct ProjectGraphCanvas: View {
    @ObservedObject var model: ProjectGraphModel

    private enum Drag {
        case node(Int, offset: SIMD2<Float>, moved: Bool)
        case pan(CGPoint)
        case box(CGPoint, CGPoint)
    }
    @State private var drag: Drag?
    @State private var lastClick: (id: String, at: Date)?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                GraphGrid(pan: model.pan, zoom: model.zoom)
                Canvas { ctx, size in draw(&ctx, size) }
                if case .box(let a, let b) = drag {
                    let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                    Rectangle().fill(GraphColors.selected.opacity(0.08))
                        .overlay(Rectangle().stroke(GraphColors.selected.opacity(0.7), lineWidth: 1))
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
                if let id = model.hovered, let k = model.visible.index[id], model.positions.indices.contains(k) {
                    let p = model.viewPoint(model.positions[k])
                    tooltip(id).offset(x: min(p.x + 14, max(geo.size.width - 260, 0)), y: max(p.y - 34, 4)).allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .clipped()
            .coordinateSpace(name: "pg")
            .gesture(gesture)
            .onContinuousHover(coordinateSpace: .named("pg")) { phase in
                if case .active(let p) = phase {
                    model.hover = p
                    let k = model.node(at: model.graphPoint(p))
                    let id = k.map { model.visible.nodes[$0].id }
                    if id != model.hovered { model.hovered = id }
                } else if model.hovered != nil {
                    model.hovered = nil
                }
            }
            .onAppear { model.canvasSize = geo.size; model.canvasOrigin = geo.frame(in: .global).origin }
            .onChange(of: geo.frame(in: .global)) { f in model.canvasSize = f.size; model.canvasOrigin = f.origin }
        }
        .background(GraphColors.canvas)
    }

    private func tooltip(_ id: String) -> some View {
        let n = model.node(id)
        return VStack(alignment: .leading, spacing: 2) {
            Text(model.name(id)).font(.system(size: 11, weight: .semibold)).foregroundColor(GraphColors.text)
            if let n {
                Text("\(n.kind.rawValue)\(n.count > 1 ? " · \(n.count)" : "")\(n.hidden ? " · hidden" : "")")
                    .font(.system(size: 10)).foregroundColor(GraphColors.dim)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.75)))
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let v = model.visible, pos = model.positions, radii = model.radii
        guard pos.count == v.nodes.count, radii.count == v.nodes.count else { return }
        let zoom = model.zoom, pan = model.pan
        func at(_ k: Int) -> CGPoint { CGPoint(x: CGFloat(pos[k].x) * zoom + pan.x, y: CGFloat(pos[k].y) * zoom + pan.y) }
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -60, dy: -60)
        let selected = model.selection, focus = model.focus
        let lit: Set<Int> = {
            // The focused node's neighbours stand out.
            guard let f = focus, let k = v.index[f] else { return [] }
            var out: Set<Int> = [k]
            for e in v.edges where e.a == k || e.b == k { out.insert(e.a); out.insert(e.b) }
            if v.nodes[k].parent >= 0 { out.insert(v.nodes[k].parent) }
            out.formUnion(v.children[k])
            return out
        }()

        // The tree.
        var tree = Path(), litTree = Path()
        for (k, n) in v.nodes.enumerated() where n.parent >= 0 {
            let a = at(n.parent), b = at(k)
            guard view.contains(a) || view.contains(b) || view.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)) else { continue }
            if lit.contains(k) && lit.contains(n.parent) { litTree.move(to: a); litTree.addLine(to: b) } else { tree.move(to: a); tree.addLine(to: b) }
        }
        ctx.stroke(tree, with: .color(ProjectGraphStyle.color(.child)), lineWidth: 1)
        ctx.stroke(litTree, with: .color(Color.white.opacity(0.55)), lineWidth: 1.5)

        // The references, by kind.
        for kind in ProjectGraph.EdgeKind.allCases where kind != .child && model.edgeKinds.contains(kind) {
            var path = Path(), litPath = Path()
            for e in v.edges where e.kind == kind {
                let a = at(e.a), b = at(e.b)
                guard view.contains(a) || view.contains(b) else { continue }
                // A slight curve, so references along the tree's links show apart from them.
                let mid = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * 0.12, y: (a.y + b.y) / 2 - (b.x - a.x) * 0.12)
                if lit.contains(e.a) && lit.contains(e.b) { litPath.move(to: a); litPath.addQuadCurve(to: b, control: mid) }
                else { path.move(to: a); path.addQuadCurve(to: b, control: mid) }
            }
            let color = ProjectGraphStyle.color(kind)
            ctx.stroke(path, with: .color(color.opacity(focus == nil ? 0.5 : 0.22)), style: StrokeStyle(lineWidth: 1.2, dash: ProjectGraphStyle.dash(kind)))
            ctx.stroke(litPath, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: ProjectGraphStyle.dash(kind)))
        }

        // The nodes, by colour; then the selection's rings.
        var fills: [String: (Color, Path)] = [:]
        var dimmed = Path(), rings = Path(), closed = Path(), hiddenRings = Path()
        var labels: [(k: Int, r: CGFloat)] = []
        for (k, n) in v.nodes.enumerated() {
            let p = at(k), r = max(CGFloat(radii[k]) * zoom, 1.5)
            guard view.insetBy(dx: -r, dy: -r).contains(p) else { continue }
            let node = model.graph.nodes[n.node]
            let kind: ProjectGraph.Kind = n.member != nil ? .member : node.kind
            let disc = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            let key = "\(kind.rawValue)|\(node.asset?.kind.isGenerator == true)"
            if fills[key] == nil { fills[key] = (ProjectGraphStyle.color(kind, asset: node.asset?.kind), Path()) }
            fills[key]!.1.addPath(disc)
            if focus != nil && !lit.contains(k) { dimmed.addPath(disc) }
            if node.hidden && n.member == nil { hiddenRings.addPath(disc) }
            if selected.contains(n.id) { rings.addPath(Path(ellipseIn: CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6))) }
            // A branch that is closed: a ring inside, its things behind it.
            if n.member == nil && !model.graph.children[n.node].isEmpty && !model.isOpen(n.id) && r > 4 || node.kind == .aggregate && n.member == nil && !model.isOpen(n.id) {
                closed.addPath(Path(ellipseIn: CGRect(x: p.x - r * 0.55, y: p.y - r * 0.55, width: r * 1.1, height: r * 1.1)))
            }
            if r * 2 > 9 || selected.contains(n.id) || n.id == model.hovered { labels.append((k, r)) }
        }
        for (_, f) in fills.sorted(by: { $0.key < $1.key }) { ctx.fill(f.1, with: .color(f.0)) }
        ctx.stroke(closed, with: .color(Color.black.opacity(0.35)), lineWidth: 1.5)
        ctx.fill(dimmed, with: .color(GraphColors.canvas.opacity(0.6)))
        ctx.fill(hiddenRings, with: .color(GraphColors.canvas.opacity(0.55)))
        ctx.stroke(hiddenRings, with: .color(Color.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        ctx.stroke(rings, with: .color(GraphColors.selected), lineWidth: 2.5)

        // Names: the biggest first, as many as fit.
        let limit = 320
        for (k, r) in labels.sorted(by: { $0.r > $1.r }).prefix(limit) {
            let n = v.nodes[k]
            let p = at(k)
            let isSelected = selected.contains(n.id)
            var name = model.name(n.id)
            if name.count > 28 { name = String(name.prefix(26)) + "…" }
            let text = Text(name).font(.system(size: isSelected ? 12 : 10.5, weight: isSelected ? .semibold : .regular))
                .foregroundColor(focus != nil && !lit.contains(k) ? GraphColors.dim.opacity(0.6) : GraphColors.text)
            ctx.draw(text, at: CGPoint(x: p.x, y: p.y + r + 8), anchor: .center)
        }
    }

    // MARK: - Gestures

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("pg"))
            .onChanged { g in
                model.focusCanvas?()
                let moved = hypot(g.translation.width, g.translation.height) > 3
                switch drag {
                case nil:
                    let gp = model.graphPoint(g.startLocation)
                    if let k = model.node(at: gp) {
                        drag = .node(k, offset: model.positions[k] - gp, moved: false)
                    } else if NSEvent.modifierFlags.contains(.shift) {
                        drag = .box(g.startLocation, g.location)
                    } else {
                        drag = .pan(model.pan)
                    }
                case .node(let k, let offset, _):
                    guard moved else { return }
                    drag = .node(k, offset: offset, moved: true)
                    model.dragNode(k, to: model.graphPoint(g.location) + offset)
                case .pan(let start):
                    model.pan = CGPoint(x: start.x + g.translation.width, y: start.y + g.translation.height)
                case .box(let a, _):
                    drag = .box(a, g.location)
                }
            }
            .onEnded { g in
                defer { drag = nil }
                let moved = hypot(g.translation.width, g.translation.height) > 3
                switch drag {
                case .node(let k, _, let dragged):
                    if dragged { model.endDragNode(k); return }
                    guard model.visible.nodes.indices.contains(k) else { return }
                    let id = model.visible.nodes[k].id
                    if let last = lastClick, last.id == id, Date().timeIntervalSince(last.at) < 0.35 {
                        lastClick = nil
                        model.activate(id)
                    } else {
                        lastClick = (id, Date())
                        model.click(id, extend: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
                    }
                case .pan:
                    if !moved { model.clearSelection() }
                case .box(let a, let b):
                    let p = model.graphPoint(a), q = model.graphPoint(b)
                    let lo = simd_min(p, q), hi = simd_max(p, q)
                    let found = model.visible.nodes.indices.filter {
                        let x = model.positions[$0]
                        return x.x >= lo.x && x.y >= lo.y && x.x <= hi.x && x.y <= hi.y
                    }.map { model.visible.nodes[$0].id }
                    model.selection = model.selection.union(found)
                    model.focus = model.selection.count == 1 ? model.selection.first : model.focus
                case nil:
                    break
                }
            }
    }
}
