import AppKit
import SwiftUI
import simd

/// What the node-graph editors share (the VFX editor, the Material Designer): the canvas's view, its selection, its
/// wires' edits and the keys the panel's view takes. Ids name the graph's items (nodes; the VFX editor's emitters and
/// blocks too); points are canvas points (top-down, in the canvas) or the graph's units (a point at zoom 1).
protocol GraphCanvasModel: ObservableObject {
    /// Where the graph's origin is in the canvas (points), and its scale.
    var pan: CGPoint { get set }
    var zoom: CGFloat { get set }
    /// The canvas's size, and its top left in the window (top-down points): the window's scrolls over it pan it.
    var canvasSize: CGSize { get set }
    var canvasOrigin: CGPoint { get set }
    /// The pointer's place on the canvas: where Tab and a right-click add.
    var hover: CGPoint { get set }
    /// Makes the canvas take the keys (Delete, Tab, Cmd-C) from a text field that had them.
    var focusCanvas: (() -> Void)? { get set }

    var selection: Set<String> { get set }
    /// What the inspector shows.
    var focus: String? { get set }
    func click(_ id: String, extend: Bool)
    func clearSelection()
    func selectAll()
    func deleteSelection()
    func copySelection()
    func paste()

    /// A drag (of a node, a wire, a slider) is one undo step from beginDrag to endDrag.
    func beginDrag()
    func endDrag()
    func moveSelection(by delta: SIMD2<Float>, ids: Set<String>?)

    /// What is wired into `owner`'s input `input`, if anything is.
    func wire(into owner: String, _ input: String) -> (from: String, output: String)?
    @discardableResult func link(_ from: String, _ output: String, to: String, _ input: String) -> Bool
    func unlink(_ to: String, _ input: String)

    /// Tab's search: where it adds (the graph's units; nil: closed).
    var searchAt: SIMD2<Float>? { get }
    func openSearch()
    func closeSearch()
    func frameAll(in size: CGSize)
}

extension GraphCanvasModel {
    /// The graph's point at canvas point `p`, and back.
    func graphPoint(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float((p.x - pan.x) / zoom), Float((p.y - pan.y) / zoom)) }
    func viewPoint(_ g: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(g.x) * zoom + pan.x, y: CGFloat(g.y) * zoom + pan.y) }

    /// Zooms by `factor` about canvas point `about`.
    func zoom(by factor: CGFloat, about: CGPoint) {
        let g = graphPoint(about)
        zoom = min(max(zoom * factor, 0.25), 2)
        pan = CGPoint(x: about.x - CGFloat(g.x) * zoom, y: about.y - CGFloat(g.y) * zoom)
    }

    /// `bounds` (the graph's units) in a canvas of `size`, with a margin.
    func frame(_ bounds: CGRect, in size: CGSize) {
        let bounds = bounds.insetBy(dx: -40, dy: -40)
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return }
        zoom = min(max(min(size.width / bounds.width, size.height / bounds.height), 0.25), 1.2)
        pan = CGPoint(x: (size.width - bounds.width * zoom) / 2 - bounds.minX * zoom,
                      y: (size.height - bounds.height * zoom) / 2 - bounds.minY * zoom)
    }
}

/// The graph editors' colours: the dark canvas, the chrome around it, the nodes, the selection.
enum GraphColors {
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
}

/// An input pin: its node's (or block's) id and its name.
struct GraphPin: Hashable {
    var owner: String
    var name: String
}

/// A wire being dragged: from a node's output, to where the pointer is (the graph's units).
struct GraphWireDrag {
    var from: String
    var output: String
    var to: CGPoint
}

/// The canvas: a dark grid; the graph (the editor's nodes and wires) panned and zoomed over it; a box dragged on the
/// grid selects; the minimap; Tab's search where it adds. Scroll pans, pinch or Cmd-scroll zooms (GraphHostingView);
/// a right-click opens `menu`.
struct GraphCanvas<Model: GraphCanvasModel, Graph: View, Menu: View, Search: View>: View {
    @ObservedObject var model: Model
    /// Around the graph (its units), and the minimap's boxes.
    let bounds: CGRect
    let minimap: [GraphMinimap<Model>.Box]
    /// The ids whose boxes meet a rectangle (the graph's units), and the input pin near a point.
    let items: (CGRect) -> Set<String>
    let inputNear: (CGPoint) -> GraphPin?
    @ViewBuilder let graph: (GraphDrags<Model>) -> Graph
    @ViewBuilder let menu: (SIMD2<Float>) -> Menu
    @ViewBuilder let search: () -> Search

    @State private var wire: GraphWireDrag?
    /// A box being dragged on the grid (canvas points).
    @State private var box: (start: CGPoint, end: CGPoint)?
    /// What a header drag moves, and where it was last (the graph's units).
    @State private var moving: (ids: Set<String>, last: CGPoint)?
    @State private var hover = CGPoint(x: 200, y: 200)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                GraphGrid(pan: model.pan, zoom: model.zoom)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(backgroundDrag)
                    .contextMenu { menu(model.graphPoint(hover)) }
                graph(GraphDrags(model: model, inputNear: inputNear, wire: $wire, moving: $moving))
                    .coordinateSpace(name: "graph")
                    .scaleEffect(model.zoom, anchor: .topLeading)
                    .offset(x: model.pan.x, y: model.pan.y)
                if let box {
                    let r = CGRect(x: min(box.start.x, box.end.x), y: min(box.start.y, box.end.y),
                                   width: abs(box.end.x - box.start.x), height: abs(box.end.y - box.start.y))
                    Rectangle().fill(GraphColors.selected.opacity(0.08))
                        .overlay(Rectangle().stroke(GraphColors.selected.opacity(0.7), lineWidth: 1))
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
                GraphMinimap(model: model, bounds: bounds, boxes: minimap, size: geo.size)
                    .frame(width: 180, height: 120)
                    .offset(x: geo.size.width - 192, y: geo.size.height - 132)
                if let at = model.searchAt {
                    search()
                        .offset(x: min(max(model.viewPoint(at).x, 8), max(geo.size.width - 288, 8)),
                                y: min(max(model.viewPoint(at).y, 8), max(geo.size.height - 330, 8)))
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
        .background(GraphColors.canvas)
    }

    /// A click on the grid clears the selection; a drag selects a box (Shift: adds to it).
    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { g in
                model.focusCanvas?()
                if model.searchAt != nil { model.closeSearch() }
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
                let found = items(r)
                model.selection = NSEvent.modifierFlags.contains(.shift) ? model.selection.union(found) : found
                model.focus = found.count == 1 ? found.first : nil
            }
    }
}

/// The grid: minor lines every 24 units, a major one every fifth.
struct GraphGrid: View {
    let pan: CGPoint
    let zoom: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let step = 24 * zoom
            guard step > 4 else { return }
            var minor = Path(), major = Path()
            let x0 = pan.x.truncatingRemainder(dividingBy: step), y0 = pan.y.truncatingRemainder(dividingBy: step)
            var i = Int(((x0 - pan.x) / step).rounded())
            var x = x0
            while x < size.width {
                let line = Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }
                if i % 5 == 0 { major.addPath(line) } else { minor.addPath(line) }
                x += step; i += 1
            }
            var j = Int(((y0 - pan.y) / step).rounded())
            var y = y0
            while y < size.height {
                let line = Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }
                if j % 5 == 0 { major.addPath(line) } else { minor.addPath(line) }
                y += step; j += 1
            }
            ctx.stroke(minor, with: .color(GraphColors.gridMinor), lineWidth: 1)
            ctx.stroke(major, with: .color(GraphColors.gridMajor), lineWidth: 1)
        }
    }
}

/// The wires, drawn over `area` (the graph's units): each from an output to an input, with its colour and whether it
/// is highlighted; and the one being dragged, dashed.
struct GraphWires: View {
    struct Wire {
        var from: CGPoint
        var to: CGPoint
        var color: Color
        var selected: Bool
    }

    let area: CGRect
    let wires: [Wire]
    let dragged: Wire?

    var body: some View {
        Canvas { ctx, _ in
            ctx.translateBy(x: -area.minX, y: -area.minY)
            for w in wires {
                ctx.stroke(GraphWires.curve(w.from, w.to), with: .color(w.color.opacity(w.selected ? 1 : 0.75)), lineWidth: w.selected ? 2.6 : 1.8)
            }
            if let w = dragged {
                ctx.stroke(GraphWires.curve(w.from, w.to), with: .color(w.color), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
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
}

/// A pin's dot: filled when wired.
struct GraphPinDot: View {
    let color: Color
    let wired: Bool
    var body: some View {
        ZStack {
            Circle().fill(wired ? color : GraphColors.node)
            Circle().stroke(color, lineWidth: 1.6)
        }
        .frame(width: 9, height: 9)
        .frame(width: 18, height: 18)   // easier to hit
        .contentShape(Rectangle())
    }
}

/// Drags that start on a pin or a header, shared by the graph's views.
struct GraphDrags<Model: GraphCanvasModel> {
    let model: Model
    let inputNear: (CGPoint) -> GraphPin?
    @Binding var wire: GraphWireDrag?
    @Binding var moving: (ids: Set<String>, last: CGPoint)?

    /// From an output: a wire, joined to the input it is let go over.
    func fromOutput(_ owner: String, _ output: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("graph"))
            .onChanged { g in wire = GraphWireDrag(from: owner, output: output, to: g.location) }
            .onEnded { g in
                defer { wire = nil }
                if let pin = inputNear(g.location) { model.link(owner, output, to: pin.owner, pin.name) }
            }
    }

    /// From a wired input: its wire, taken off and dragged from its output (let go over nothing: gone).
    func fromInput(_ owner: String, _ input: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("graph"))
            .onChanged { g in
                if wire == nil, let l = model.wire(into: owner, input) {
                    model.beginDrag()
                    model.unlink(owner, input)
                    wire = GraphWireDrag(from: l.from, output: l.output, to: g.location)
                } else if var w = wire {
                    w.to = g.location
                    wire = w
                }
            }
            .onEnded { g in
                defer { wire = nil; model.endDrag() }
                guard let w = wire, let pin = inputNear(g.location) else { return }
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

/// The graph in small, and the view's part of it; a click or a drag there moves the view.
struct GraphMinimap<Model: GraphCanvasModel>: View {
    struct Box {
        var rect: CGRect
        var color: Color
        var rounded = false
    }

    @ObservedObject var model: Model
    let bounds: CGRect
    let boxes: [Box]
    let size: CGSize

    var body: some View {
        GeometryReader { geo in
            let world = bounds.insetBy(dx: -60, dy: -60)
            let s = min(geo.size.width / max(world.width, 1), geo.size.height / max(world.height, 1))
            let toMap = { (r: CGRect) in CGRect(x: (r.minX - world.minX) * s, y: (r.minY - world.minY) * s, width: r.width * s, height: r.height * s) }
            Canvas { ctx, _ in
                for b in boxes {
                    ctx.fill(b.rounded ? Path(roundedRect: toMap(b.rect), cornerRadius: 2) : Path(toMap(b.rect)), with: .color(b.color))
                }
                let a = model.graphPoint(.zero), b = model.graphPoint(CGPoint(x: size.width, y: size.height))
                let view = toMap(CGRect(x: CGFloat(a.x), y: CGFloat(a.y), width: CGFloat(b.x - a.x), height: CGFloat(b.y - a.y)))
                ctx.stroke(Path(view), with: .color(GraphColors.selected.opacity(0.8)), lineWidth: 1)
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

/// Tab's search: a field and what can be added, filtered by name (those starting with it first); Return adds the first.
struct GraphNodeSearch: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let add: () -> Void
    }

    let placeholder: String
    let items: [Item]
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shown: [Item] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
            .sorted { ($0.title.lowercased().hasPrefix(q) ? 0 : 1) < ($1.title.lowercased().hasPrefix(q) ? 0 : 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { shown.first?.add() }
                .onExitCommand { close() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { item in
                        Button(action: item.add) {
                            HStack {
                                Text(item.title).foregroundColor(GraphColors.text)
                                Spacer()
                                Text(item.detail).foregroundColor(GraphColors.dim)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(GraphColors.node))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))
        .shadow(radius: 10)
        .onAppear { focused = true }
    }
}

/// A graph editor's view: its keys and the canvas's scrolling and pinching (SwiftUI on macOS 13 has neither), and the
/// Edit menu's Copy, Paste, Cut, Delete and Select All for the graph. Delete removes the selection, Tab adds a node,
/// Escape closes the search (or clears the selection), F frames the graph; `keys` takes others first.
final class GraphHostingView: NSHostingView<AnyView> {
    weak var model: (any GraphCanvasModel)?
    /// An editor's own keys (without Command): true when it took the event.
    var keys: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    /// Whether `event` is over the canvas (the inspector scrolls itself).
    private func overCanvas(_ event: NSEvent) -> CGPoint? {
        guard let model else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let top = isFlipped ? p.y : bounds.height - p.y
        let q = CGPoint(x: p.x - model.canvasOrigin.x, y: top - model.canvasOrigin.y)
        guard q.x >= 0, q.y >= 0, q.x <= model.canvasSize.width, q.y <= model.canvasSize.height else { return nil }
        return q
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model, let p = overCanvas(event) else { super.scrollWheel(with: event); return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) || !event.hasPreciseScrollingDeltas {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            model.zoom(by: exp(dy), about: p)
        } else {
            model.pan = CGPoint(x: model.pan.x + event.scrollingDeltaX, y: model.pan.y + event.scrollingDeltaY)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let model, let p = overCanvas(event) else { super.magnify(with: event); return }
        model.zoom(by: 1 + event.magnification, about: p)
    }

    override func keyDown(with event: NSEvent) {
        guard let model, !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        if keys?(event) == true { return }
        switch event.keyCode {
        case 51, 117: model.deleteSelection()                        // Delete, Forward Delete
        case 48: model.openSearch()                                  // Tab
        case 53: if model.searchAt != nil { model.closeSearch() } else { model.clearSelection() }   // Escape
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" { model.frameAll(in: model.canvasSize) } else { super.keyDown(with: event) }
        }
    }

    @objc func copy(_ sender: Any?) { model?.copySelection() }
    @objc func paste(_ sender: Any?) { model?.paste() }
    @objc func cut(_ sender: Any?) { model?.copySelection(); model?.deleteSelection() }
    @objc func delete(_ sender: Any?) { model?.deleteSelection() }
    override func selectAll(_ sender: Any?) { model?.selectAll() }
}
