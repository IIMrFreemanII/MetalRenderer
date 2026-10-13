import SwiftUI
import simd

/// The VFX editor's colours: the graph editors' (GraphColors), the pins' by type, the nodes' headers by family, the
/// contexts'.
enum VFXColors {
    static let canvas = GraphColors.canvas
    static let chrome = GraphColors.chrome
    static let node = GraphColors.node
    static let block = GraphColors.block
    static let text = GraphColors.text
    static let dim = GraphColors.dim
    static let selected = GraphColors.selected

    static func pin(_ t: VFXType) -> Color {
        switch t {
        case .float: return Color(red: 0.45, green: 0.85, blue: 0.6)
        case .vec3: return Color(red: 0.95, green: 0.8, blue: 0.35)
        case .color: return Color(red: 0.92, green: 0.5, blue: 0.85)
        case .bool: return Color(red: 0.95, green: 0.42, blue: 0.4)
        }
    }

    static func family(_ f: VFXFamily) -> Color {
        switch f {
        case .input: return Color(red: 0.25, green: 0.45, blue: 0.75)
        case .value: return Color(red: 0.38, green: 0.39, blue: 0.42)
        case .math: return Color(red: 0.24, green: 0.52, blue: 0.4)
        case .vector: return Color(red: 0.6, green: 0.5, blue: 0.22)
        case .logic: return Color(red: 0.62, green: 0.3, blue: 0.3)
        case .curve: return Color(red: 0.48, green: 0.34, blue: 0.66)
        case .noise: return Color(red: 0.22, green: 0.52, blue: 0.58)
        case .attribute: return Color(red: 0.7, green: 0.42, blue: 0.2)
        }
    }

    static func context(_ c: VFXContext) -> Color {
        switch c {
        case .spawn: return Color(red: 0.82, green: 0.52, blue: 0.22)
        case .initialize: return Color(red: 0.33, green: 0.66, blue: 0.4)
        case .update: return Color(red: 0.3, green: 0.52, blue: 0.85)
        case .output: return Color(red: 0.62, green: 0.42, blue: 0.82)
        }
    }
}

/// The graph: the emitters' columns of blocks and the operator nodes, wired pin to pin, on the graph editors' canvas
/// (GraphCanvas). Drag a node or an emitter by its header to move it (the selection with it); drag from an output to an
/// input to wire them (from a wired input to take its wire elsewhere); drag on the grid to select a box. Scroll pans,
/// pinch or Cmd-scroll zooms (the panel's view: GraphHostingView); Tab or a right-click adds a node.
struct VFXCanvasView: View {
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        let layout = VFXLayout(model.effect)
        GraphCanvas(model: model, bounds: layout.bounds, minimap: minimap(layout), items: layout.items(in:),
                    inputNear: { layout.input(near: $0, radius: 14) }) { drags in
            graph(layout, drags)
        } menu: { g in
            addMenu(at: g)
        } search: {
            if let search = model.search { VFXNodeSearch(search: search) }
        }
    }

    private func minimap(_ layout: VFXLayout) -> [GraphMinimap<VFXEditorModel>.Box] {
        layout.emitters.values.map { .init(rect: $0, color: Color.white.opacity(0.25), rounded: true) }
            + layout.nodes.map { id, r in .init(rect: r, color: VFXColors.family(layout.arranged.node(id)?.kind.spec.family ?? .value).opacity(0.8)) }
    }

    // MARK: - The graph

    private func graph(_ layout: VFXLayout, _ drags: GraphDrags<VFXEditorModel>) -> some View {
        let fx = layout.arranged
        let area = layout.bounds.insetBy(dx: -400, dy: -400)
        return ZStack(alignment: .topLeading) {
            wires(layout, area: area, dragged: drags.wire)
            ForEach(fx.emitters) { e in
                VFXEmitterView(emitter: e, effect: fx, layout: layout, drags: drags)
                    .offset(x: CGFloat(e.canvas.x), y: CGFloat(e.canvas.y))
            }
            ForEach(fx.nodes) { n in
                VFXNodeView(node: n, effect: fx, layout: layout, drags: drags)
                    .offset(x: CGFloat(n.canvas.x), y: CGFloat(n.canvas.y))
            }
        }
    }

    private func wires(_ layout: VFXLayout, area: CGRect, dragged: GraphWireDrag?) -> some View {
        let fx = layout.arranged
        let wires: [GraphWires.Wire] = fx.links.compactMap { l in
            guard let a = layout.outputs[.init(owner: l.from, name: l.output)], let b = layout.inputs[.init(owner: l.to, name: l.input)] else { return nil }
            return .init(from: a, to: b, color: VFXColors.pin(fx.outputType(l.from, l.output)),
                         selected: model.selection.contains(l.from) || model.selection.contains(l.to))
        }
        let drag = dragged.flatMap { w in
            layout.outputs[.init(owner: w.from, name: w.output)].map { GraphWires.Wire(from: $0, to: w.to, color: VFXColors.pin(fx.outputType(w.from, w.output)), selected: true) }
        }
        return GraphWires(area: area, wires: wires, dragged: drag)
    }

    // MARK: - Adding

    @ViewBuilder
    private func addMenu(at g: SIMD2<Float>) -> some View {
        ForEach(VFXFamily.allCases, id: \.self) { family in
            Menu(family.rawValue) {
                ForEach(VFXOpKind.allCases.filter { $0.spec.family == family }, id: \.self) { k in
                    Button(k.spec.title) { model.addNode(k, at: g) }
                }
            }
        }
        Divider()
        Button("Add Emitter") { model.addEmitter(at: g) }
        Button("Paste") { model.paste() }.disabled(!model.canPaste)
        Button("Frame All") { model.frameAll(in: model.canvasSize) }
    }
}

/// A pin's dot, its type's colour: filled when wired.
struct VFXPinDot: View {
    let type: VFXType
    let wired: Bool
    var body: some View { GraphPinDot(color: VFXColors.pin(type), wired: wired) }
}

/// An emitter: its header, then its four contexts, each a stack of blocks; a block's wireable pins as rows.
struct VFXEmitterView: View {
    let emitter: VFXEmitter
    let effect: VFXEffect
    let layout: VFXLayout
    let drags: GraphDrags<VFXEditorModel>
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        let selected = model.selection.contains(emitter.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(VFXColors.dim)
                Text(emitter.name).font(.system(size: 12, weight: .semibold)).foregroundColor(VFXColors.text).lineLimit(1)
                Spacer()
                Text("\(emitter.capacity)").font(.system(size: 10).monospacedDigit()).foregroundColor(VFXColors.dim)
                if let p = program, p { Text("code").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4)
                    .background(Capsule().fill(VFXColors.family(.curve).opacity(0.6))).foregroundColor(.white) }
            }
            .padding(.horizontal, 8)
            .frame(height: VFXLayout.header)
            .contentShape(Rectangle())
            .gesture(drags.header(emitter.id))
            .contextMenu {
                Button("Delete Emitter") { model.selection = [emitter.id]; model.deleteSelection() }
            }
            ForEach(VFXContext.allCases, id: \.self) { c in context(c) }
            Spacer().frame(height: VFXLayout.gap)
        }
        .frame(width: VFXLayout.emitterWidth, height: VFXLayout.height(emitter), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(VFXColors.node))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? VFXColors.selected : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1))
    }

    /// Whether it runs generated code, as the renderer reports (nil: it isn't in the scene).
    private var program: Bool? {
        model.status?.emitters.first { $0.effect == model.selectedEffect && $0.name == emitter.name }?.program
    }

    private func context(_ c: VFXContext) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Rectangle().fill(VFXColors.context(c)).frame(width: 3, height: 12)
                Text(c.title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(VFXColors.context(c))
                Spacer()
                Menu {
                    ForEach(VFXBlockKind.allCases.filter { $0.spec.contexts.contains(c) }, id: \.self) { k in
                        Button(k.spec.title) { model.addBlock(k, to: emitter.id, c) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).foregroundColor(VFXColors.dim)
            }
            .padding(.horizontal, 8)
            .frame(height: VFXLayout.contextHeader)
            if emitter[c].isEmpty {
                Text("—").font(.system(size: 10)).foregroundColor(VFXColors.dim).padding(.leading, 14).frame(height: VFXLayout.row)
            }
            ForEach(emitter[c]) { b in block(b, c) }
            Spacer().frame(height: VFXLayout.gap)
        }
    }

    private func block(_ b: VFXBlock, _ c: VFXContext) -> some View {
        let selected = model.selection.contains(b.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(b.kind.spec.title).font(.system(size: 11, weight: .medium))
                    .foregroundColor(b.enabled ? VFXColors.text : VFXColors.dim).strikethrough(!b.enabled)
                Spacer(minLength: 4)
                Text(VFXSummary.block(b, effect)).font(.system(size: 10).monospacedDigit()).foregroundColor(VFXColors.dim).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: VFXLayout.blockTitle)
            ForEach(VFXLayout.rows(b), id: \.name) { p in pinRow(b, p) }
        }
        .frame(width: VFXLayout.emitterWidth - 12, height: VFXLayout.height(b), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(VFXColors.block))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? VFXColors.selected : .clear, lineWidth: 1.5))
        .overlay(alignment: .leading) { Rectangle().fill(VFXColors.context(c).opacity(0.8)).frame(width: 2) }
        .padding(.leading, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            model.focusCanvas?()
            model.click(b.id, extend: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu {
            Button(b.enabled ? "Disable" : "Enable") { model.edit { $0.setEnabled(b.id, !b.enabled) } }
            Button("Move Up") { model.moveBlock(b.id, by: -1) }
            Button("Move Down") { model.moveBlock(b.id, by: 1) }
            Divider()
            Button("Delete") { model.selection = [b.id]; model.deleteSelection() }
        }
    }

    private func pinRow(_ b: VFXBlock, _ p: VFXPinSpec) -> some View {
        let wired = effect.link(into: b.id, p.name)
        return HStack(spacing: 2) {
            Text(p.title).font(.system(size: 10)).foregroundColor(VFXColors.dim).lineLimit(1)
            Spacer(minLength: 4)
            Text(wired.map { effect.node($0.from)?.kind.spec.title ?? $0.from } ?? VFXSummary.value(b.param(p.name)))
                .font(.system(size: 10).monospacedDigit()).foregroundColor(wired != nil ? VFXColors.pin(effect.pinType(b.id, p.name)) : VFXColors.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: VFXLayout.row)
        .overlay(alignment: .leading) {   // the dot on the emitter's edge
            VFXPinDot(type: effect.pinType(b.id, p.name), wired: wired != nil)
                .gesture(drags.fromInput(b.id, p.name))
                .offset(x: -15)
        }
    }
}

/// An operator node: its header (its family's colour), its inputs on the left and outputs on the right.
struct VFXNodeView: View {
    let node: VFXNode
    let effect: VFXEffect
    let layout: VFXLayout
    let drags: GraphDrags<VFXEditorModel>
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        let spec = node.kind.spec, selected = model.selection.contains(node.id)
        VStack(alignment: .leading, spacing: 0) {
            Text(spec.title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                .padding(.horizontal, 8)
                .frame(width: VFXLayout.nodeWidth, height: VFXLayout.nodeHeader, alignment: .leading)
                .background(VFXColors.family(spec.family))
                .contentShape(Rectangle())
                .gesture(drags.header(node.id))
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) { ForEach(spec.inputs, id: \.name) { p in input(p) } }
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(spec.outputs, id: \.name) { o in output(o.name) }
                }
                .frame(width: VFXLayout.nodeWidth, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .frame(width: VFXLayout.nodeWidth, height: VFXLayout.height(node), alignment: .topLeading)
        .background(VFXColors.node)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? VFXColors.selected : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1))
        .contextMenu {
            Button("Copy") { model.selection = [node.id]; model.copySelection() }
            Button("Delete") { model.selection = [node.id]; model.deleteSelection() }
        }
    }

    private func input(_ p: VFXPinSpec) -> some View {
        let wired = effect.link(into: node.id, p.name) != nil
        return HStack(spacing: 2) {
            if p.wire != nil {
                VFXPinDot(type: effect.pinType(node.id, p.name), wired: wired).gesture(drags.fromInput(node.id, p.name))
            } else {
                Spacer().frame(width: 18)
            }
            Text(p.title).font(.system(size: 10)).foregroundColor(VFXColors.dim).lineLimit(1)
            if !wired {
                Text(VFXSummary.value(node.param(p.name))).font(.system(size: 10).monospacedDigit()).foregroundColor(VFXColors.text.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .offset(x: -9)
        .frame(width: VFXLayout.nodeWidth * 0.72, height: VFXLayout.row, alignment: .leading)
    }

    private func output(_ name: String) -> some View {
        HStack(spacing: 2) {
            if name != "out" { Text(name).font(.system(size: 10)).foregroundColor(VFXColors.dim) }
            VFXPinDot(type: effect.outputType(node.id, name), wired: effect.links.contains { $0.from == node.id && $0.output == name })
                .gesture(drags.fromOutput(node.id, name))
        }
        .offset(x: 9)
        .frame(height: VFXLayout.row)
    }
}

/// Tab's search: what can be added there (operators; a context's blocks when one was asked), by name.
struct VFXNodeSearch: View {
    let search: VFXEditorModel.Search
    @EnvironmentObject var model: VFXEditorModel

    private var items: [GraphNodeSearch.Item] {
        if let target = search.context {
            return VFXBlockKind.allCases.filter { $0.spec.contexts.contains(target.context) }.map { k in
                GraphNodeSearch.Item(id: "b." + k.rawValue, title: k.spec.title, detail: target.context.title) { [model] in
                    model.addBlock(k, to: target.emitter, target.context)
                }
            }
        }
        return VFXOpKind.allCases.map { k in
            GraphNodeSearch.Item(id: "n." + k.rawValue, title: k.spec.title, detail: k.spec.family.rawValue) { [model, search] in
                model.addNode(k, at: search.at)
            }
        }
    }

    var body: some View {
        GraphNodeSearch(placeholder: search.context == nil ? "Add a node…" : "Add a block…", items: items) { [model] in model.search = nil }
    }
}

/// Short texts of values, for the canvas's rows.
enum VFXSummary {
    static func number(_ f: Float) -> String {
        if f >= 1e9 { return "∞" }
        if f == f.rounded() && abs(f) < 1e5 { return String(Int(f)) }
        return String(format: abs(f) < 0.01 ? "%.4g" : "%.3g", f)
    }

    static func value(_ v: VFXParam) -> String {
        switch v {
        case .float(let f): return number(f)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "on" : "off"
        case .range(let a, let b): return a == b ? number(a) : "\(number(a))–\(number(b))"
        case .vec3(let v): return "\(number(v.x)), \(number(v.y)), \(number(v.z))"
        case .color(let c): return String(format: "%.2g %.2g %.2g", c.x, c.y, c.z)
        case .choice(let s): return s.isEmpty ? "—" : s
        case .names(let n): return n.isEmpty ? "—" : n.joined(separator: ", ")
        case .curve(let c): return "curve (\(c.keys.count))"
        case .gradient(let g): return "gradient (\(g.keys.count))"
        }
    }

    /// A block's main value: its first parameter that says most.
    static func block(_ b: VFXBlock, _ fx: VFXEffect) -> String {
        switch b.kind {
        case .rate: return "\(number(b.float("rate")))/s"
        case .burst: return "\(b.int("count"))"
        case .event: return "\(b.choice("parent")) · \(b.choice("on"))"
        case .shape: return b.choice("shape")
        case .velocity: return "\(value(b.param("speed"))) m/s"
        case .lifetime: return fx.link(into: b.id, "lifetime") != nil ? "wired" : "\(value(b.param("lifetime"))) s"
        case .gravity: return fx.link(into: b.id, "share") != nil ? "" : "× \(number(b.float("share")))"
        case .drag: return fx.link(into: b.id, "drag") != nil ? "" : number(b.float("drag"))
        case .curl: return number(b.float("strength"))
        case .field: return b.choice("field")
        case .collide: return b.bool("scene") ? "scene" : b.names("colliders").joined(separator: ", ")
        case .setAttribute: return b.choice("attribute")
        case .mesh: return b.choice("mesh")
        case .trail: return "\(b.int("points"))"
        case .color: let e = b.float("emission"); return e > 0 ? "glow \(number(e))" : "lit"
        case .flipbook: return b.choice("atlas")
        case .orient: return b.choice("mode")
        default: return ""
        }
    }
}
