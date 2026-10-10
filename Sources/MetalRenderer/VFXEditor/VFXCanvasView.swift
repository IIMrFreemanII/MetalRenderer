import SwiftUI
import simd

/// The VFX editor's colours: the dark canvas, the pins' by type, the nodes' headers by family, the contexts'.
enum VFXColors {
    static let canvas = Color(red: 0.105, green: 0.11, blue: 0.122)
    /// The toolbar's, the inspector's and the status line's.
    static let chrome = Color(red: 0.15, green: 0.155, blue: 0.165)
    static let gridMinor = Color.white.opacity(0.035)
    static let gridMajor = Color.white.opacity(0.075)
    static let node = Color(red: 0.17, green: 0.175, blue: 0.19)
    static let block = Color(red: 0.215, green: 0.22, blue: 0.235)
    static let text = Color(white: 0.88)
    static let dim = Color(white: 0.55)
    static let selected = Color(red: 0.98, green: 0.72, blue: 0.25)

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

/// The graph: a dark grid, the emitters' columns of blocks and the operator nodes, wired pin to pin. Drag a node or an
/// emitter by its header to move it (the selection with it); drag from an output to an input to wire them (from a
/// wired input to take its wire elsewhere); drag on the grid to select a box. Scroll pans, pinch or Cmd-scroll zooms
/// (the panel's view: VFXEditorPanel); Tab or a right-click adds a node.
struct VFXCanvasView: View {
    @EnvironmentObject var model: VFXEditorModel
    /// A wire being dragged: from a node's output, to where the pointer is (the graph's units).
    @State private var wire: (from: String, output: String, to: CGPoint)?
    /// A box being dragged on the grid (canvas points).
    @State private var box: (start: CGPoint, end: CGPoint)?
    /// What a header drag moves, and where it was last (the graph's units).
    @State private var moving: (ids: Set<String>, last: CGPoint)?
    /// Where the pointer is (canvas points): where Tab and a right-click add.
    @State private var hover = CGPoint(x: 200, y: 200)

    var body: some View {
        GeometryReader { geo in
            let layout = VFXLayout(model.effect)
            ZStack(alignment: .topLeading) {
                grid(geo.size)
                    .gesture(backgroundDrag(layout))
                    .contextMenu { addMenu(at: model.graphPoint(hover)) }
                graph(layout)
                    .scaleEffect(model.zoom, anchor: .topLeading)
                    .offset(x: model.pan.x, y: model.pan.y)
                if let box {
                    let r = CGRect(x: min(box.start.x, box.end.x), y: min(box.start.y, box.end.y),
                                   width: abs(box.end.x - box.start.x), height: abs(box.end.y - box.start.y))
                    Rectangle().fill(VFXColors.selected.opacity(0.08))
                        .overlay(Rectangle().stroke(VFXColors.selected.opacity(0.7), lineWidth: 1))
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
                VFXMinimap(layout: layout, size: geo.size)
                    .frame(width: 180, height: 120)
                    .offset(x: geo.size.width - 192, y: geo.size.height - 132)
                if let search = model.search {
                    VFXNodeSearch(search: search)
                        .offset(x: min(max(model.viewPoint(search.at).x, 8), max(geo.size.width - 288, 8)),
                                y: min(max(model.viewPoint(search.at).y, 8), max(geo.size.height - 330, 8)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(name: "canvas")
            .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
                if case .active(let p) = phase { hover = p; model.hover = p }
            }
            .onAppear { model.canvasSize = geo.size; model.canvasOrigin = geo.frame(in: .global).origin }
            .onChange(of: geo.frame(in: .global)) { f in model.canvasSize = f.size; model.canvasOrigin = f.origin }
        }
        .background(VFXColors.canvas)
    }

    // MARK: - The grid

    private func grid(_ size: CGSize) -> some View {
        Canvas { ctx, size in
            let step = 24 * model.zoom
            guard step > 4 else { return }
            var minor = Path(), major = Path()
            let x0 = model.pan.x.truncatingRemainder(dividingBy: step), y0 = model.pan.y.truncatingRemainder(dividingBy: step)
            var i = Int(((x0 - model.pan.x) / step).rounded())
            var x = x0
            while x < size.width {
                let line = Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }
                if i % 5 == 0 { major.addPath(line) } else { minor.addPath(line) }
                x += step; i += 1
            }
            var j = Int(((y0 - model.pan.y) / step).rounded())
            var y = y0
            while y < size.height {
                let line = Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }
                if j % 5 == 0 { major.addPath(line) } else { minor.addPath(line) }
                y += step; j += 1
            }
            ctx.stroke(minor, with: .color(VFXColors.gridMinor), lineWidth: 1)
            ctx.stroke(major, with: .color(VFXColors.gridMajor), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
    }

    /// A click on the grid clears the selection; a drag selects a box (Shift: adds to it).
    private func backgroundDrag(_ layout: VFXLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { g in
                model.focusCanvas?()
                if model.search != nil { model.search = nil }
                if hypot(g.translation.width, g.translation.height) > 3 { box = (g.startLocation, g.location) }
            }
            .onEnded { g in
                defer { box = nil }
                guard let b = box else {
                    if !NSEvent.modifierFlags.contains(.shift) { model.clearSelection() }
                    return
                }
                let a = model.graphPoint(b.start), c = model.graphPoint(b.end)
                let r = CGRect(x: CGFloat(min(a.x, c.x)), y: CGFloat(min(a.y, c.y)), width: CGFloat(abs(c.x - a.x)), height: CGFloat(abs(c.y - a.y)))
                let found = layout.items(in: r)
                model.selection = NSEvent.modifierFlags.contains(.shift) ? model.selection.union(found) : found
                model.focus = found.count == 1 ? found.first : nil
            }
    }

    // MARK: - The graph

    private func graph(_ layout: VFXLayout) -> some View {
        let fx = layout.arranged
        let area = layout.bounds.insetBy(dx: -400, dy: -400)
        return ZStack(alignment: .topLeading) {
            wires(layout, area: area)
            ForEach(fx.emitters) { e in
                VFXEmitterView(emitter: e, effect: fx, layout: layout, wire: $wire, moving: $moving)
                    .offset(x: CGFloat(e.canvas.x), y: CGFloat(e.canvas.y))
            }
            ForEach(fx.nodes) { n in
                VFXNodeView(node: n, effect: fx, layout: layout, wire: $wire, moving: $moving)
                    .offset(x: CGFloat(n.canvas.x), y: CGFloat(n.canvas.y))
            }
        }
        .coordinateSpace(name: "graph")
    }

    private func wires(_ layout: VFXLayout, area: CGRect) -> some View {
        let fx = layout.arranged
        return Canvas { ctx, _ in
            ctx.translateBy(x: -area.minX, y: -area.minY)
            for l in fx.links {
                guard let a = layout.outputs[.init(owner: l.from, name: l.output)], let b = layout.inputs[.init(owner: l.to, name: l.input)] else { continue }
                let selected = model.selection.contains(l.from) || model.selection.contains(l.to)
                ctx.stroke(VFXCanvasView.curve(a, b), with: .color(VFXColors.pin(fx.outputType(l.from, l.output)).opacity(selected ? 1 : 0.75)),
                           lineWidth: selected ? 2.6 : 1.8)
            }
            if let w = wire, let a = layout.outputs[.init(owner: w.from, name: w.output)] {
                ctx.stroke(VFXCanvasView.curve(a, w.to), with: .color(VFXColors.pin(fx.outputType(w.from, w.output))),
                           style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .frame(width: area.width, height: area.height)
        .offset(x: area.minX, y: area.minY)
        .allowsHitTesting(false)
    }

    /// A wire from an output to an input: a curve leaving right, arriving from the left.
    static func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        Path { p in
            let dx = max(abs(b.x - a.x) * 0.5, 50)
            p.move(to: a)
            p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        }
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

/// A pin's dot: filled when wired.
struct VFXPinDot: View {
    let type: VFXType
    let wired: Bool
    var body: some View {
        ZStack {
            Circle().fill(wired ? VFXColors.pin(type) : VFXColors.node)
            Circle().stroke(VFXColors.pin(type), lineWidth: 1.6)
        }
        .frame(width: 9, height: 9)
        .frame(width: 18, height: 18)   // easier to hit
        .contentShape(Rectangle())
    }
}

/// Drags that start on a pin or a header, shared by the emitters' and the nodes' views.
private struct GraphDrags {
    let model: VFXEditorModel
    let layout: VFXLayout
    @Binding var wire: (from: String, output: String, to: CGPoint)?
    @Binding var moving: (ids: Set<String>, last: CGPoint)?

    /// From an output: a wire, joined to the input it is let go over.
    func fromOutput(_ owner: String, _ output: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("graph"))
            .onChanged { g in wire = (owner, output, g.location) }
            .onEnded { g in
                defer { wire = nil }
                if let pin = layout.input(near: g.location, radius: 14) { model.link(owner, output, to: pin.owner, pin.name) }
            }
    }

    /// From a wired input: its wire, taken off and dragged from its output (let go over nothing: gone).
    func fromInput(_ owner: String, _ input: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("graph"))
            .onChanged { g in
                if wire == nil, let l = model.effect.link(into: owner, input) {
                    model.beginDrag()
                    model.unlink(owner, input)
                    wire = (l.from, l.output, g.location)
                } else if let w = wire {
                    wire = (w.from, w.output, g.location)
                }
            }
            .onEnded { g in
                defer { wire = nil; model.endDrag() }
                guard let w = wire, let pin = layout.input(near: g.location, radius: 14) else { return }
                model.link(w.from, w.output, to: pin.owner, pin.name)
            }
    }

    /// From a header: the item (with the selection, if it is in it) moved; a click selects it.
    func header(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("graph"))
            .onChanged { g in
                model.focusCanvas?()
                if moving == nil {
                    let extend = NSEvent.modifierFlags.contains(.shift)
                    model.click(id, extend: extend)
                    moving = (model.selection.contains(id) ? model.selection : [id], g.startLocation)
                    model.beginDrag()
                }
                guard let m = moving else { return }
                let d = SIMD2(Float(g.location.x - m.last.x), Float(g.location.y - m.last.y))
                if d != .zero { model.moveSelection(by: d, ids: m.ids) }
                moving = (m.ids, g.location)
            }
            .onEnded { _ in
                moving = nil
                model.endDrag()
            }
    }
}

/// An emitter: its header, then its four contexts, each a stack of blocks; a block's wireable pins as rows.
struct VFXEmitterView: View {
    let emitter: VFXEmitter
    let effect: VFXEffect
    let layout: VFXLayout
    @Binding var wire: (from: String, output: String, to: CGPoint)?
    @Binding var moving: (ids: Set<String>, last: CGPoint)?
    @EnvironmentObject var model: VFXEditorModel

    private var drags: GraphDrags { GraphDrags(model: model, layout: layout, wire: $wire, moving: $moving) }

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
    @Binding var wire: (from: String, output: String, to: CGPoint)?
    @Binding var moving: (ids: Set<String>, last: CGPoint)?
    @EnvironmentObject var model: VFXEditorModel

    private var drags: GraphDrags { GraphDrags(model: model, layout: layout, wire: $wire, moving: $moving) }

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

/// The graph in small, and the view's part of it; a click or a drag there moves the view.
struct VFXMinimap: View {
    let layout: VFXLayout
    let size: CGSize
    @EnvironmentObject var model: VFXEditorModel

    var body: some View {
        GeometryReader { geo in
            let world = layout.bounds.insetBy(dx: -60, dy: -60)
            let s = min(geo.size.width / max(world.width, 1), geo.size.height / max(world.height, 1))
            let toMap = { (r: CGRect) in CGRect(x: (r.minX - world.minX) * s, y: (r.minY - world.minY) * s, width: r.width * s, height: r.height * s) }
            Canvas { ctx, _ in
                for r in layout.emitters.values { ctx.fill(Path(roundedRect: toMap(r), cornerRadius: 2), with: .color(Color.white.opacity(0.25))) }
                for (id, r) in layout.nodes {
                    let f = layout.arranged.node(id)?.kind.spec.family ?? .value
                    ctx.fill(Path(toMap(r)), with: .color(VFXColors.family(f).opacity(0.8)))
                }
                let a = model.graphPoint(.zero), b = model.graphPoint(CGPoint(x: size.width, y: size.height))
                let view = toMap(CGRect(x: CGFloat(a.x), y: CGFloat(a.y), width: CGFloat(b.x - a.x), height: CGFloat(b.y - a.y)))
                ctx.stroke(Path(view), with: .color(VFXColors.selected.opacity(0.8)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                // The view centred where the map is clicked.
                let gx = g.location.x / s + world.minX, gy = g.location.y / s + world.minY
                model.pan = CGPoint(x: size.width / 2 - gx * model.zoom, y: size.height / 2 - gy * model.zoom)
            })
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
    }
}

/// Tab's search: what can be added there (operators; a context's blocks when one was asked), by name.
struct VFXNodeSearch: View {
    let search: VFXEditorModel.Search
    @EnvironmentObject var model: VFXEditorModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let add: () -> Void
    }

    private var items: [Item] {
        var all: [Item] = []
        if let target = search.context {
            for k in VFXBlockKind.allCases where k.spec.contexts.contains(target.context) {
                all.append(Item(id: "b." + k.rawValue, title: k.spec.title, detail: target.context.title) { [model] in
                    model.addBlock(k, to: target.emitter, target.context)
                })
            }
        } else {
            for k in VFXOpKind.allCases {
                all.append(Item(id: "n." + k.rawValue, title: k.spec.title, detail: k.spec.family.rawValue) { [model, search] in
                    model.addNode(k, at: search.at)
                })
            }
        }
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
            .sorted { ($0.title.lowercased().hasPrefix(q) ? 0 : 1) < ($1.title.lowercased().hasPrefix(q) ? 0 : 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(search.context == nil ? "Add a node…" : "Add a block…", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { items.first?.add() }
                .onExitCommand { model.search = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        Button(action: item.add) {
                            HStack {
                                Text(item.title).foregroundColor(VFXColors.text)
                                Spacer()
                                Text(item.detail).foregroundColor(VFXColors.dim)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(8)
        .frame(width: 270)
        .background(RoundedRectangle(cornerRadius: 8).fill(VFXColors.node))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))
        .shadow(radius: 10)
        .onAppear { focused = true }
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
