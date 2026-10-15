import SwiftUI
import simd

/// The Material Designer's colours: the pins' by type, the nodes' headers by family.
enum MatColors {
    static func pin(_ t: MatPinType) -> Color {
        switch t {
        case .grey: return Color(white: 0.72)
        case .color: return Color(red: 0.95, green: 0.72, blue: 0.3)
        case .any: return Color(red: 0.55, green: 0.75, blue: 0.95)
        }
    }
    static func pin(_ t: MatType) -> Color { pin(t == .grey ? MatPinType.grey : .color) }
    static func fn(_ t: MatFnType?) -> Color {
        switch t {
        case .float?: return Color(red: 0.45, green: 0.85, blue: 0.6)
        case .vec2?: return Color(red: 0.55, green: 0.75, blue: 0.95)
        case .vec3?: return Color(red: 0.95, green: 0.8, blue: 0.35)
        case .vec4?: return Color(red: 0.92, green: 0.5, blue: 0.85)
        case nil: return Color(white: 0.6)
        }
    }

    static func family(_ f: MatFamily) -> Color {
        switch f {
        case .graph: return Color(red: 0.38, green: 0.39, blue: 0.42)
        case .noise: return Color(red: 0.22, green: 0.52, blue: 0.58)
        case .pattern: return Color(red: 0.25, green: 0.45, blue: 0.75)
        case .adjust: return Color(red: 0.24, green: 0.52, blue: 0.4)
        case .blend: return Color(red: 0.6, green: 0.5, blue: 0.22)
        case .filter: return Color(red: 0.48, green: 0.34, blue: 0.66)
        case .height: return Color(red: 0.7, green: 0.42, blue: 0.2)
        case .advanced: return Color(red: 0.62, green: 0.3, blue: 0.3)
        }
    }

    static func function(_ family: String) -> Color {
        switch family {
        case "Inputs": return Color(red: 0.25, green: 0.45, blue: 0.75)
        case "Sampling": return Color(red: 0.7, green: 0.42, blue: 0.2)
        case "Math": return Color(red: 0.24, green: 0.52, blue: 0.4)
        case "Vector": return Color(red: 0.6, green: 0.5, blue: 0.22)
        case "Logic": return Color(red: 0.62, green: 0.3, blue: 0.3)
        case "Random": return Color(red: 0.22, green: 0.52, blue: 0.58)
        default: return Color(red: 0.48, green: 0.34, blue: 0.66)
        }
    }
}

/// Where the canvas draws the shown graph's nodes (or the function's), in the graph's units: a node a box of its
/// header, its thumbnail (a graph's node), its pins' rows (inputs left, outputs right); every pin's place.
struct MatCanvasLayout {
    static let fnWidth: CGFloat = 150

    struct Box {
        var id: String
        var rect: CGRect
        var inputs: [(name: String, title: String, type: MatPinType, fnType: MatFnType?)]
        var outputs: [(name: String, type: MatPinType)]
    }

    private(set) var boxes: [Box] = []
    private(set) var inputs: [GraphPin: CGPoint] = [:]
    private(set) var outputs: [GraphPin: CGPoint] = [:]
    private(set) var bounds = CGRect.zero
    let function: Bool

    init(_ model: MaterialEditorModel) {
        let c = model.catalog
        if let f = model.function {
            function = true
            let types = MatCanvasLayout.fnTypes(f)
            for n in f.nodes {
                let spec = n.kind.spec
                let ins = spec.inputs.filter { $0.type != nil }.map { p in
                    (name: p.name, title: p.name, type: MatPinType.any, fnType: Optional(p.generic ? (types[n.id] ?? .float) : p.type ?? .float))
                }
                let outs: [(name: String, type: MatPinType)] = n.kind == .result ? [] : [("out", .any)]
                add(Box(id: n.id, rect: CGRect(x: CGFloat(n.at.x), y: CGFloat(n.at.y), width: MatCanvasLayout.fnWidth,
                                               height: MatLayout.header + CGFloat(max(ins.count, outs.count, 1)) * MatLayout.row + MatLayout.gap),
                        inputs: ins, outputs: outs))
            }
        } else {
            function = false
            let g = MatLayout.arranged(model.graph)
            for n in g.nodes {
                let pins = g.pins(n, library: { c.graph($0) })
                let ins = pins.inputs.map { (name: $0.name, title: $0.title, type: $0.type, fnType: MatFnType?.none) }
                let resolved = model.step(n.id)?.outputs
                let outs = pins.outputs.enumerated().map { k, o -> (name: String, type: MatPinType) in
                    (o.name, resolved.flatMap { $0.indices.contains(k) ? ($0[k] == .grey ? MatPinType.grey : .color) : nil } ?? o.type)
                }
                add(Box(id: n.id, rect: CGRect(x: CGFloat(n.at.x), y: CGFloat(n.at.y), width: MatLayout.nodeWidth,
                                               height: MatLayout.height(inputs: ins.count, outputs: outs.count)),
                        inputs: ins, outputs: outs))
            }
        }
        bounds = boxes.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        if bounds.isNull { bounds = .zero }
    }

    private mutating func add(_ b: Box) {
        boxes.append(b)
        let top = b.rect.minY + MatLayout.header + (function ? 0 : MatLayout.thumb)
        for (i, p) in b.inputs.enumerated() {
            inputs[GraphPin(owner: b.id, name: p.name)] = CGPoint(x: b.rect.minX, y: top + (CGFloat(i) + 0.5) * MatLayout.row)
        }
        for (i, o) in b.outputs.enumerated() {
            outputs[GraphPin(owner: b.id, name: o.name)] = CGPoint(x: b.rect.maxX, y: top + (CGFloat(i) + 0.5) * MatLayout.row)
        }
    }

    func box(_ id: String) -> Box? { boxes.first { $0.id == id } }

    func input(near p: CGPoint, radius: CGFloat) -> GraphPin? {
        let near = inputs.filter { hypot($0.value.x - p.x, $0.value.y - p.y) <= radius }
        return near.min { hypot($0.value.x - p.x, $0.value.y - p.y) < hypot($1.value.x - p.x, $1.value.y - p.y) }?.key
    }

    func items(in r: CGRect) -> Set<String> { Set(boxes.filter { $0.rect.intersects(r) }.map(\.id)) }

    /// A function's generic nodes' types: their wired inputs' widest.
    static func fnTypes(_ f: MatFunction) -> [String: MatFnType] {
        var memo: [String: MatFnType] = [:]
        func type(_ id: String, _ seen: Set<String>) -> MatFnType {
            if let t = memo[id] { return t }
            guard let n = f.node(id), !seen.contains(id) else { return .float }
            let spec = n.kind.spec
            if let t = spec.output { memo[id] = t; return t }
            var t = MatFnType.float
            for p in spec.inputs where p.generic {
                if let l = f.link(into: id, p.name) { t = .wider(t, type(l.from, seen.union([id]))) }
                else if case .color = n.param(p.name) { t = .wider(t, .vec4) }
                else if case .vec2 = n.param(p.name) { t = .wider(t, .vec2) }
            }
            memo[id] = t
            return t
        }
        for n in f.nodes { _ = type(n.id, []) }
        return memo
    }
}

/// The graph on the graph editors' canvas (GraphCanvas): each node its header (its family's colour), its thumbnail,
/// its pins; wires coloured by what they carry. Tab or a right-click adds a node; double-click a pixel processor to
/// edit its function (the breadcrumb above goes back).
struct MaterialCanvasView: View {
    @EnvironmentObject var model: MaterialEditorModel

    var body: some View {
        let layout = MatCanvasLayout(model)
        ZStack(alignment: .topLeading) {
            GraphCanvas(model: model, bounds: layout.bounds, minimap: minimap(layout), items: layout.items(in:),
                        inputNear: { layout.input(near: $0, radius: 14) }) { drags in
                graph(layout, drags)
            } menu: { g in
                addMenu(at: g)
            } search: {
                MatNodeSearch()
            }
            if let f = model.editingFunction {
                HStack(spacing: 6) {
                    Button { model.editingFunction = nil } label: { Label(model.selectedGraph, systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Text("›").foregroundColor(GraphColors.dim)
                    Text("\(f) function").foregroundColor(GraphColors.text)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(8)
            }
        }
    }

    private func minimap(_ layout: MatCanvasLayout) -> [GraphMinimap<MaterialEditorModel>.Box] {
        layout.boxes.map { b in
            let color: Color = layout.function ? MatColors.function(model.function?.node(b.id)?.kind.spec.family ?? "")
                : MatColors.family(model.graph.node(b.id)?.kind.spec.family ?? .graph)
            return .init(rect: b.rect, color: color.opacity(0.8))
        }
    }

    private func graph(_ layout: MatCanvasLayout, _ drags: GraphDrags<MaterialEditorModel>) -> some View {
        let area = layout.bounds.insetBy(dx: -400, dy: -400)
        return ZStack(alignment: .topLeading) {
            wires(layout, area: area, dragged: drags.wire)
            ForEach(layout.boxes, id: \.id) { b in
                MatNodeView(box: b, function: layout.function, drags: drags)
                    .offset(x: b.rect.minX, y: b.rect.minY)
            }
        }
    }

    private func wires(_ layout: MatCanvasLayout, area: CGRect, dragged: GraphWireDrag?) -> some View {
        let links = model.function?.links ?? model.graph.links
        func color(_ from: String, _ output: String) -> Color {
            if layout.function { return MatColors.fn(MatCanvasLayout.fnTypes(model.function!)[from]) }
            return MatColors.pin(layout.box(from)?.outputs.first { $0.name == output }?.type ?? .any)
        }
        let wires: [GraphWires.Wire] = links.compactMap { l in
            guard let a = layout.outputs[GraphPin(owner: l.from, name: l.output)], let b = layout.inputs[GraphPin(owner: l.to, name: l.input)] else { return nil }
            return .init(from: a, to: b, color: color(l.from, l.output), selected: model.selection.contains(l.from) || model.selection.contains(l.to))
        }
        let drag = dragged.flatMap { w in
            layout.outputs[GraphPin(owner: w.from, name: w.output)].map { GraphWires.Wire(from: $0, to: w.to, color: color(w.from, w.output), selected: true) }
        }
        return GraphWires(area: area, wires: wires, dragged: drag)
    }

    @ViewBuilder
    private func addMenu(at g: SIMD2<Float>) -> some View {
        if model.editingFunction != nil {
            ForEach(["Inputs", "Sampling", "Math", "Vector", "Logic", "Random"], id: \.self) { family in
                Menu(family) {
                    ForEach(MatFnKind.allCases.filter { $0.spec.family == family }, id: \.self) { k in
                        Button(k.spec.title) { model.addFunctionNode(k, at: g) }
                    }
                }
            }
        } else {
            ForEach(MatFamily.allCases, id: \.self) { family in
                Menu(family.rawValue) {
                    ForEach(MatOpKind.allCases.filter { $0.spec.family == family && $0 != .subgraph && $0 != .output }, id: \.self) { k in
                        Button(k.spec.title) { model.addNode(k, at: g) }
                    }
                }
            }
            Menu("Output") {
                ForEach(MatChannel.allCases, id: \.self) { c in
                    Button(c.title) { model.addOutput(c, at: g) }.disabled(model.graph.channels[c] != nil)
                }
            }
            Menu("Subgraph") {
                ForEach(model.graphNames.filter { $0 != model.selectedGraph }, id: \.self) { n in
                    Button(n) { model.addSubgraph(n, at: g) }
                }
            }
        }
        Divider()
        Button("Paste") { model.paste() }.disabled(!model.canPaste)
        Button("Frame All") { model.frameAll(in: model.canvasSize) }
    }
}

/// A node: its header, its thumbnail (a graph's node: its image as last baked, its error if it failed), its pins.
struct MatNodeView: View {
    let box: MatCanvasLayout.Box
    let function: Bool
    let drags: GraphDrags<MaterialEditorModel>
    @EnvironmentObject var model: MaterialEditorModel

    var body: some View {
        let selected = model.selection.contains(box.id)
        VStack(alignment: .leading, spacing: 0) {
            header
            if !function { thumbnail }
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) { ForEach(box.inputs, id: \.name) { p in input(p) } }
                VStack(alignment: .trailing, spacing: 0) { ForEach(box.outputs, id: \.name) { o in output(o) } }
                    .frame(width: box.rect.width, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .frame(width: box.rect.width, height: box.rect.height, alignment: .topLeading)
        .background(GraphColors.node)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? GraphColors.selected : model.errors[box.id] != nil ? Color.red : Color.white.opacity(0.08),
                                                         lineWidth: selected ? 2 : 1))
        .contextMenu { menu }
        .onTapGesture(count: 2) { open() }
    }

    private var title: String {
        if function { return model.function?.node(box.id)?.kind.spec.title ?? box.id }
        guard let n = model.graph.node(box.id) else { return box.id }
        switch n.kind {
        case .output: return MatChannel(rawValue: n.choice("usage"))?.title ?? "Output \(n.text("name"))"
        case .input: return "Input \(n.text("name"))"
        case .subgraph: return n.text("graph")
        default: return n.kind.spec.title
        }
    }

    private var headerColor: Color {
        if function { return MatColors.function(model.function?.node(box.id)?.kind.spec.family ?? "") }
        return MatColors.family(model.graph.node(box.id)?.kind.spec.family ?? .graph)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            Spacer(minLength: 2)
            if !function, let s = model.step(box.id) {
                Text(verbatim: "\(s.pixels) \(s.bits == .b8 ? "8" : s.bits == .b16 ? "16" : "32f")")
                    .font(.system(size: 9).monospacedDigit()).foregroundColor(.white.opacity(0.7))
            }
            if model.pinned == box.id { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.white) }
        }
        .padding(.horizontal, 8)
        .frame(width: box.rect.width, height: MatLayout.header, alignment: .leading)
        .background(headerColor)
        .contentShape(Rectangle())
        .gesture(drags.header(box.id))
    }

    private var thumbnail: some View {
        ZStack {
            Checkerboard().opacity(0.25)
            if let image = model.thumbnails[box.id] {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium)
            }
            if let e = model.errors[box.id] {
                Text(e).font(.system(size: 9)).foregroundColor(.white).padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.red.opacity(0.55))
            }
        }
        .frame(width: MatLayout.thumb, height: MatLayout.thumb)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .frame(width: box.rect.width, height: MatLayout.thumb)
        .contentShape(Rectangle())
        .gesture(drags.header(box.id))
    }

    private func input(_ p: (name: String, title: String, type: MatPinType, fnType: MatFnType?)) -> some View {
        let wired = model.wire(into: box.id, p.name) != nil
        return HStack(spacing: 2) {
            GraphPinDot(color: function ? MatColors.fn(p.fnType) : MatColors.pin(p.type), wired: wired)
                .gesture(drags.fromInput(box.id, p.name))
            Text(p.title).font(.system(size: 10)).foregroundColor(GraphColors.dim).lineLimit(1)
        }
        .offset(x: -9)
        .frame(width: box.rect.width * 0.7, height: MatLayout.row, alignment: .leading)
    }

    private func output(_ o: (name: String, type: MatPinType)) -> some View {
        let types = function ? MatCanvasLayout.fnTypes(model.function!) : [:]
        return HStack(spacing: 2) {
            if o.name != "out" { Text(o.name).font(.system(size: 10)).foregroundColor(GraphColors.dim) }
            GraphPinDot(color: function ? MatColors.fn(types[box.id]) : MatColors.pin(o.type),
                        wired: (model.function?.links ?? model.graph.links).contains { $0.from == box.id && $0.output == o.name })
                .gesture(drags.fromOutput(box.id, o.name))
        }
        .offset(x: 9)
        .frame(height: MatLayout.row)
    }

    /// A pixel processor: its function on the canvas.
    private func open() {
        guard !function, model.graph.node(box.id)?.kind == .pixelProcessor else { return }
        model.editingFunction = box.id
        DispatchQueue.main.async { model.frameAll(in: model.canvasSize) }
    }

    @ViewBuilder
    private var menu: some View {
        if !function {
            Button(model.pinned == box.id ? "Unpin from 2D View" : "Pin to 2D View") { model.pinned = model.pinned == box.id ? nil : box.id }
            if model.graph.node(box.id)?.kind == .pixelProcessor { Button("Edit Function") { open() } }
        }
        Button("Copy") { model.selection = [box.id]; model.copySelection() }
        Button("Delete") { model.selection = [box.id]; model.deleteSelection() }
    }
}

/// A checkerboard behind images with alpha.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.white))
                }
            }
        }
    }
}

/// Tab's search: the nodes (or the function's), outputs and subgraphs, by name.
struct MatNodeSearch: View {
    @EnvironmentObject var model: MaterialEditorModel

    private var items: [GraphNodeSearch.Item] {
        guard let at = model.search else { return [] }
        if model.editingFunction != nil {
            return MatFnKind.allCases.filter { $0 != .result }.map { k in
                GraphNodeSearch.Item(id: "f." + k.rawValue, title: k.spec.title, detail: k.spec.family) { [model] in model.addFunctionNode(k, at: at) }
            }
        }
        var all = MatOpKind.allCases.filter { $0 != .subgraph && $0 != .output }.map { k in
            GraphNodeSearch.Item(id: "n." + k.rawValue, title: k.spec.title, detail: k.spec.family.rawValue) { [model] in model.addNode(k, at: at) }
        }
        all += MatChannel.allCases.filter { model.graph.channels[$0] == nil }.map { c in
            GraphNodeSearch.Item(id: "o." + c.rawValue, title: "\(c.title) Output", detail: "Output") { [model] in model.addOutput(c, at: at) }
        }
        all += model.graphNames.filter { $0 != model.selectedGraph }.map { n in
            GraphNodeSearch.Item(id: "g." + n, title: n, detail: "Subgraph") { [model] in model.addSubgraph(n, at: at) }
        }
        return all
    }

    var body: some View {
        GraphNodeSearch(placeholder: model.editingFunction == nil ? "Add a node…" : "Add a function node…", items: items) { [model] in model.search = nil }
    }
}
