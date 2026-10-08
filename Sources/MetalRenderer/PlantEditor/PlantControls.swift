import SwiftUI
import simd

/// A labelled slider and its value, for one of PlantParams' numbers of `root`. Dragging is one undo step.
struct ParamRow<Root>: View {
    let param: PlantParam<Root>
    @Binding var root: Root
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        let value = Binding<Double>(get: { param.get(root) }, set: { v in var r = root; param.set(&r, param.clamp(v)); root = r })
        HStack(spacing: 8) {
            Text(param.title).frame(width: 130, alignment: .leading).lineLimit(1)
            Slider(value: value, in: param.range) { editing in editing ? model.beginDrag() : model.endDrag() }
                .controlSize(.small)
            Text(param.text(value.wrappedValue)).monospacedDigit().frame(width: 64, alignment: .trailing).foregroundColor(.secondary)
        }
        .font(.system(size: 11))
    }
}

/// Every row of a table.
struct ParamRows<Root>: View {
    let table: [PlantParam<Root>]
    @Binding var root: Root

    var body: some View {
        ForEach(table.indices, id: \.self) { i in ParamRow(param: table[i], root: $root) }
    }
}

/// A float slider not in a table (a curve preset's parameter, a colour's part).
struct ValueRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Double>
    var digits = 2
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        ParamRow(param: PlantParam<Float>(title: title, range: range, step: 0, digits: digits, unit: "", mutation: 0,
                                          get: { Double($0) }, set: { $0 = Float($1) }), root: $value)
    }
}

/// A section of rows with a title and, if given, copy and paste buttons.
struct EditorGroup<Content: View>: View {
    let title: String
    var clip: PlantEditorModel.Clip? = nil
    var bough = false
    @ViewBuilder let content: Content
    @EnvironmentObject var model: PlantEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if let clip {
                    Button("Copy") { model.copy(clip, bough: bough) }.buttonStyle(.borderless).font(.system(size: 10))
                    Button("Paste") { model.paste(clip, bough: bough) }.buttonStyle(.borderless).font(.system(size: 10))
                }
            }
            content
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// A curve over 0...1: drawn, with its preset (a line, a taper, a crown's shape) or its points. A preset shows its
/// parameters as sliders; dragging the curve itself turns it into points. Double-click adds a point, Option-click
/// removes one.
struct CurveEditor: View {
    let title: String
    @Binding var curve: Foliage.Curve
    /// The values' range shown (and a point's).
    var range: ClosedRange<Float> = 0...1.2
    /// The presets offered: a crown's shapes, a line's ends, a taper.
    var crowns = false
    var lineRange: ClosedRange<Double> = 0...Double.pi
    var xLabel = "base → tip"
    @EnvironmentObject var model: PlantEditorModel
    @State private var dragged: Int?
    /// The last click that moved nothing, to tell a double-click (SwiftUI's taps have no location on macOS 13).
    @State private var lastClick: (time: TimeInterval, at: CGPoint)?

    private var points: [SIMD2<Float>] {
        if case .points(let p) = curve { return p }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Menu(presetTitle) {
                    if crowns {
                        ForEach(Foliage.Crown.allCases, id: \.self) { c in Button(c.rawValue.capitalized) { set(.crown(c)) } }
                    }
                    Button("Line") { set(.linear(curve.start, curve.end)) }
                    Button("Taper") { set(.taper(min(max(1 - curve.end, 0), 1))) }
                    Button("Points") { set(curve.editable(samples: 5)) }
                }
                .menuStyle(.borderlessButton).frame(width: 120).font(.system(size: 11))
            }
            canvas.frame(height: 90)
            Text(xLabel).font(.system(size: 9)).foregroundColor(.secondary)
            switch curve {
            case .linear(let a, let b):
                ValueRow(title: "At base", value: Binding(get: { a }, set: { curve = .linear($0, b) }), range: lineRange)
                ValueRow(title: "At tip", value: Binding(get: { b }, set: { curve = .linear(a, $0) }), range: lineRange)
            case .taper(let t):
                ValueRow(title: "Taper", value: Binding(get: { t }, set: { curve = .taper($0) }), range: 0...1)
            case .crown, .points:
                EmptyView()
            }
        }
    }

    private var presetTitle: String {
        switch curve {
        case .linear: return "Line"
        case .taper: return "Taper"
        case .crown(let c): return c.rawValue.capitalized
        case .points: return "Points"
        }
    }

    private func set(_ c: Foliage.Curve) {
        curve = c
    }

    private func toView(_ p: SIMD2<Float>, _ size: CGSize) -> CGPoint {
        let y = (p.y - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(y)) * size.height)
    }

    private func fromView(_ q: CGPoint, _ size: CGSize) -> SIMD2<Float> {
        let x = Float(min(max(q.x / max(size.width, 1), 0), 1))
        let y = range.lowerBound + Float(1 - min(max(q.y / max(size.height, 1), 0), 1)) * (range.upperBound - range.lowerBound)
        return SIMD2(x, y)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor))
                Path { p in   // the grid: quarters
                    for i in 1..<4 {
                        let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                Path { p in
                    let n = 64
                    for i in 0...n {
                        let x = Float(i) / Float(n), q = toView(SIMD2(x, curve.value(x)), size)
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
                ForEach(points.indices, id: \.self) { i in
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).position(toView(points[i], size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in drag(g, size) }
                .onEnded { g in
                    dragged = nil
                    model.endDrag()
                    clicked(g, size)
                })
        }
    }

    private func drag(_ g: DragGesture.Value, _ size: CGSize) {
        var p = points
        if p.isEmpty {   // a preset dragged: its points from now on
            guard case .points(let made) = curve.editable(samples: 5) else { return }
            p = made
        }
        if dragged == nil {
            model.beginDrag()
            let at = g.startLocation
            func distance(_ i: Int) -> CGFloat { hypot(toView(p[i], size).x - at.x, toView(p[i], size).y - at.y) }
            // The point under the cursor, if one is (-1: none, the drag moves nothing).
            dragged = p.indices.min { distance($0) < distance($1) }.flatMap { distance($0) < 12 ? $0 : nil } ?? -1
            if NSEvent.modifierFlags.contains(.option), let k = dragged, k > 0, k < p.count - 1 {
                p.remove(at: k)
                dragged = -1
                curve = .points(p)
                return
            }
        }
        guard let k = dragged, k >= 0 else { return }
        var q = fromView(g.location, size)
        // The ends stay at x = 0 and 1; the others between their neighbours.
        if k == 0 { q.x = 0 } else if k == p.count - 1 { q.x = 1 } else { q.x = min(max(q.x, p[k - 1].x + 0.01), p[k + 1].x - 0.01) }
        p[k] = q
        curve = .points(p)
    }

    /// A click (a drag that went nowhere): the second one soon after and near the first adds a point there.
    private func clicked(_ g: DragGesture.Value, _ size: CGSize) {
        guard hypot(g.translation.width, g.translation.height) < 3 else { lastClick = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, now - last.time < NSEvent.doubleClickInterval,
           hypot(last.at.x - g.location.x, last.at.y - g.location.y) < 6 {
            lastClick = nil
            addPoint(g.location, size)
        } else {
            lastClick = (now, g.location)
        }
    }

    private func addPoint(_ location: CGPoint, _ size: CGSize) {
        var p = points
        if p.isEmpty, case .points(let made) = curve.editable(samples: 5) { p = made }
        let q = fromView(location, size)
        guard q.x > 0.01, q.x < 0.99, !p.contains(where: { abs($0.x - q.x) < 0.02 }) else { return }
        p.append(q)
        p.sort { $0.x < $1.x }
        curve = .points(p)
    }
}

/// A linear RGB colour as a ColorPicker (which edits sRGB).
struct LinearColorPicker: View {
    let title: String
    @Binding var color: SIMD3<Float>

    var body: some View {
        ColorPicker(title, selection: Binding(get: {
            Color(.sRGB, red: Double(LinearColorPicker.encode(color.x)), green: Double(LinearColorPicker.encode(color.y)),
                  blue: Double(LinearColorPicker.encode(color.z)))
        }, set: { c in
            guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
            color = SIMD3(LinearColorPicker.decode(Float(ns.redComponent)), LinearColorPicker.decode(Float(ns.greenComponent)),
                          LinearColorPicker.decode(Float(ns.blueComponent)))
        }), supportsOpacity: false)
        .font(.system(size: 11))
    }

    static func encode(_ c: Float) -> Float { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    static func decode(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
}
