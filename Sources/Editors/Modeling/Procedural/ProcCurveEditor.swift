import AppKit
import Procedural
import SwiftUI
import simd

/// The pane under the parameters: the network, or the curve editor (Houdini's pane tabs).
struct ProcLowerPane: View {
    @ObservedObject var session: ProceduralSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                tab("Network", .network)
                tab("Curves", .curves)
                Spacer()
            }
            .background(ProcTheme.paneHeader)
            switch session.lowerTab {
            case .network: ProcNetworkHost(session: session)
            case .curves: ProcCurveEditor(session: session)
            }
        }
    }

    private func tab(_ title: String, _ t: ProceduralSession.LowerTab) -> some View {
        Button { session.lowerTab = t } label: {
            Text(title).font(ProcTheme.font)
                .foregroundColor(session.lowerTab == t ? ProcTheme.text : ProcTheme.dim)
                .padding(.horizontal, 12).frame(height: 20)
                .background(session.lowerTab == t ? ProcTheme.pane : ProcTheme.paneHeader)
        }
        .buttonStyle(.plain)
    }
}

/// Houdini's Animation Editor: the current node's keyed channels (or the ones a parameter's "Show in Curve Editor"
/// picked) as curves over the frames. Click or box-select keys (Shift adds), drag them (frames snap to whole ones),
/// drag a spline key's handles to set its slopes (both sides, or the one with Option), double-click a curve to key it
/// there, Delete removes the selected keys, F frames them all; scroll pans, Control-scroll zooms the frames (Shift too:
/// the values), pinch zooms both. Right-click: interpolation, automatic slopes, extrapolation.
struct ProcCurveEditor: View {
    @ObservedObject var session: ProceduralSession

    /// A key: its channel and frame (indices change as keys move).
    struct Pick: Hashable {
        var node: String
        var channel: String
        var frame: Float
    }

    private enum Drag {
        case keys(start: [(node: String, channel: String, curve: ProcCurve)], at: CGPoint)
        case slope(Pick, out: Bool, start: [(node: String, channel: String, curve: ProcCurve)])
        case box(from: CGPoint, to: CGPoint)
    }

    /// The frames and values in view (nil: fitted to the keys, until a pan or a zoom).
    @State private var view: (frames: ClosedRange<Float>, values: ClosedRange<Float>)?
    @State private var selected: Set<Pick> = []
    @State private var hidden: Set<String> = []
    @State private var drag: Drag?
    /// The canvas's size, as its geometry last gave it (set while the body is made: a first frame draws with it).
    private final class Measure { var size = CGSize.zero }
    @State private var measure = Measure()
    private var size: CGSize { measure.size }
    @State private var hovering = false
    @State private var monitor: Any?
    @State private var zoomStart: (ClosedRange<Float>, ClosedRange<Float>)?
    @FocusState private var focused: Bool

    private var curves: [(node: String, channel: String, curve: ProcCurve)] {
        session.shownCurves.filter { !hidden.contains("\($0.node)/\($0.channel)") }
    }

    var body: some View {
        HStack(spacing: 0) {
            channelList.frame(width: 130)
            Rectangle().fill(Color.black.opacity(0.6)).frame(width: 1)
            GeometryReader { geo in
                let _ = (measure.size = geo.size)
                canvas
            }
        }
        .background(ProcTheme.network)
        .onAppear { installMonitor() }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .onChange(of: session.currentNode) { _, _ in selected = []; frameAll() }
    }

    // MARK: Channels

    private var channelList: some View {
        let shown = session.shownCurves
        return VStack(alignment: .leading, spacing: 2) {
            if shown.isEmpty {
                Text("No keys on this node: ⌥-click a parameter's label").font(ProcTheme.small).foregroundColor(ProcTheme.dim)
                    .padding(6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown.indices, id: \.self) { i in
                        let c = shown[i]
                        let id = "\(c.node)/\(c.channel)"
                        Button {
                            if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
                        } label: {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(color(c.node, c.channel)).frame(width: 8, height: 8)
                                    .opacity(hidden.contains(id) ? 0.25 : 1)
                                Text(label(c.node, c.channel)).font(ProcTheme.small)
                                    .foregroundColor(hidden.contains(id) ? ProcTheme.dim : ProcTheme.text).lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            if !session.curveSolo.isEmpty {
                Button("Show the Node's") { session.curveSolo = []; frameAll() }.buttonStyle(.borderless).font(ProcTheme.small).padding(6)
            }
        }
        .background(ProcTheme.pane)
    }

    private func label(_ node: String, _ channel: String) -> String {
        node == session.currentNode ? channel : "\(session.graph.node(node)?.name ?? node)/\(channel)"
    }

    /// x y z w (r g b a) red, green, blue, white, as Houdini colours them; a number's yellow.
    private func color(_ node: String, _ channel: String) -> Color {
        guard let pn = session.graph.node(node), let k = ProcExprContext.locate(channel, in: pn)?.component else { return ProcTheme.keyOn }
        return [Color(red: 0.95, green: 0.35, blue: 0.32), Color(red: 0.45, green: 0.85, blue: 0.40),
                Color(red: 0.40, green: 0.60, blue: 1.0), Color(white: 0.9)][k]
    }

    // MARK: Space

    private func x(_ f: Float) -> CGFloat { CGFloat((f - frames.lowerBound) / (frames.upperBound - frames.lowerBound)) * size.width }
    private func y(_ v: Float) -> CGFloat { size.height - CGFloat((v - values.lowerBound) / (values.upperBound - values.lowerBound)) * size.height }
    private func frame(_ px: CGFloat) -> Float { frames.lowerBound + Float(px / max(size.width, 1)) * (frames.upperBound - frames.lowerBound) }
    private func value(_ py: CGFloat) -> Float {
        values.lowerBound + Float((size.height - py) / max(size.height, 1)) * (values.upperBound - values.lowerBound)
    }
    private func point(_ k: ProcKey) -> CGPoint { CGPoint(x: x(k.frame), y: y(k.value)) }

    private var frames: ClosedRange<Float> { view?.frames ?? fitted().frames }
    private var values: ClosedRange<Float> { view?.values ?? fitted().values }

    /// Back to the keys in view.
    private func frameAll() { view = nil }

    /// The keys (or the network's range) with a margin.
    private func fitted() -> (frames: ClosedRange<Float>, values: ClosedRange<Float>) {
        let keys = curves.flatMap(\.curve.keys)
        var f0 = keys.map(\.frame).min() ?? Float(session.graph.frames.lowerBound)
        var f1 = keys.map(\.frame).max() ?? Float(session.graph.frames.upperBound)
        if f1 - f0 < 2 { f0 -= 12; f1 += 12 }
        var v0 = keys.map(\.value).min() ?? -1, v1 = keys.map(\.value).max() ?? 1
        if v1 - v0 < 1e-3 { v0 -= 1; v1 += 1 }
        let mf = (f1 - f0) * 0.08, mv = (v1 - v0) * 0.15
        return ((f0 - mf)...(f1 + mf), (v0 - mv)...(v1 + mv))
    }

    /// A tick step of 1, 2 or 5 times a power of ten that leaves `minimum` points between ticks.
    private func step(_ span: Float, _ pixels: CGFloat, minimum: CGFloat) -> Float {
        var s = pow(10, (log10(max(span, 1e-6) * Float(minimum / max(pixels, 1)))).rounded(.down))
        for m: Float in [1, 2, 5, 10] where CGFloat(s * m / span) * pixels >= minimum { s *= m; break }
        return s
    }

    // MARK: Drawing

    private var canvas: some View {
        Canvas { ctx, size in
            let r = session.graph.frames
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(0.25)))
            let inRange = CGRect(x: x(Float(r.lowerBound)), y: 0, width: x(Float(r.upperBound)) - x(Float(r.lowerBound)), height: size.height)
            ctx.fill(Path(inRange), with: .color(ProcTheme.network))
            // The grid and its labels.
            let fs = max(1, step(frames.upperBound - frames.lowerBound, size.width, minimum: 48))
            var f = (frames.lowerBound / fs).rounded(.down) * fs
            while f <= frames.upperBound {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(f), y: 0)); $0.addLine(to: CGPoint(x: x(f), y: size.height)) },
                           with: .color(Color.white.opacity(0.07)), lineWidth: 1)
                ctx.draw(Text(ProcExprContext.format(f)).font(ProcTheme.small).foregroundColor(ProcTheme.dim),
                         at: CGPoint(x: x(f) + 2, y: size.height - 8), anchor: .leading)
                f += fs
            }
            let vs = step(values.upperBound - values.lowerBound, size.height, minimum: 28)
            var v = (values.lowerBound / vs).rounded(.down) * vs
            while v <= values.upperBound {
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(v))); $0.addLine(to: CGPoint(x: size.width, y: y(v))) },
                           with: .color(Color.white.opacity(abs(v) < vs * 0.01 ? 0.2 : 0.07)), lineWidth: 1)
                ctx.draw(Text(ProcExprContext.format(v)).font(ProcTheme.small).foregroundColor(ProcTheme.dim),
                         at: CGPoint(x: 3, y: y(v) - 7), anchor: .leading)
                v += vs
            }
            // The frame.
            ctx.fill(Path(CGRect(x: x(session.frame) - 1, y: 0, width: 2, height: size.height)), with: .color(ProcTheme.display.opacity(0.8)))
            // The curves, a sample every two points, and their keys.
            for c in curves {
                let col = color(c.node, c.channel)
                var path = Path()
                var px: CGFloat = 0
                while px <= size.width + 2 {
                    let p = CGPoint(x: px, y: y(c.curve.value(at: frame(px))))
                    if px == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    px += 2
                }
                ctx.stroke(path, with: .color(col), lineWidth: 1.5)
                for (i, k) in c.curve.keys.enumerated() {
                    let p = point(k)
                    let on = selected.contains(Pick(node: c.node, channel: c.channel, frame: k.frame))
                    if on, k.interpolation == .spline || (i > 0 && c.curve.keys[i - 1].interpolation == .spline) {
                        for (a, b) in handles(c.curve, i) {
                            ctx.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(ProcTheme.text.opacity(0.7)), lineWidth: 1)
                            ctx.fill(Path(ellipseIn: CGRect(x: b.x - 3, y: b.y - 3, width: 6, height: 6)), with: .color(ProcTheme.text))
                        }
                    }
                    let box = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                    ctx.fill(Path(box), with: .color(on ? ProcTheme.selected : col))
                    ctx.stroke(Path(box), with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
            }
            if case .box(let a, let b)? = drag {
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                ctx.fill(Path(rect), with: .color(ProcTheme.selected.opacity(0.08)))
                ctx.stroke(Path(rect), with: .color(ProcTheme.selected.opacity(0.7)), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onContinuousHover { phase in if case .active = phase { hovering = true } else { hovering = false } }
        .gesture(dragGesture)
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { addKey(at: $0.location) })
        .simultaneousGesture(MagnifyGesture().onChanged { g in
            if zoomStart == nil { zoomStart = (frames, values) }
            guard let (f, v) = zoomStart else { return }
            view = (ProcCurveEditor.scaled(f, around: frame(g.startLocation.x), by: Float(1 / g.magnification)),
                    ProcCurveEditor.scaled(v, around: value(g.startLocation.y), by: Float(1 / g.magnification)))
        }.onEnded { _ in zoomStart = nil })
        .onKeyPress(.delete) { deleteSelected(); return .handled }
        .onKeyPress(.deleteForward) { deleteSelected(); return .handled }
        .onKeyPress("f") { frameAll(); return .handled }
        .contextMenu { menu }
    }

    /// A spline key's handle lines: from the key, 40 points along its slopes (in, out).
    private func handles(_ c: ProcCurve, _ i: Int) -> [(CGPoint, CGPoint)] {
        let k = c.keys[i], s = c.slopes(i), p = point(k)
        func along(_ slope: Float, _ sign: CGFloat) -> CGPoint {
            let d = CGVector(dx: x(k.frame + 1) - x(k.frame), dy: y(k.value + slope) - y(k.value))
            let n = max(hypot(d.dx, d.dy), 1e-6)
            return CGPoint(x: p.x + sign * d.dx / n * 40, y: p.y + sign * d.dy / n * 40)
        }
        var out: [(CGPoint, CGPoint)] = []
        if i > 0 { out.append((p, along(s.x, -1))) }
        if i < c.keys.count - 1 { out.append((p, along(s.y, 1))) }
        return out
    }

    static func scaled(_ r: ClosedRange<Float>, around c: Float, by s: Float) -> ClosedRange<Float> {
        let lo = c + (r.lowerBound - c) * s, hi = c + (r.upperBound - c) * s
        return hi - lo > 1e-4 ? lo...hi : r
    }

    // MARK: Editing

    private func hitKey(_ p: CGPoint) -> Pick? {
        for c in curves.reversed() {
            if let k = c.curve.keys.first(where: { abs(point($0).x - p.x) < 6 && abs(point($0).y - p.y) < 6 }) {
                return Pick(node: c.node, channel: c.channel, frame: k.frame)
            }
        }
        return nil
    }

    private func hitHandle(_ p: CGPoint) -> (Pick, out: Bool)? {
        for c in curves {
            for (i, k) in c.curve.keys.enumerated() where selected.contains(Pick(node: c.node, channel: c.channel, frame: k.frame)) {
                for (a, b) in handles(c.curve, i) where hypot(b.x - p.x, b.y - p.y) < 6 {
                    return (Pick(node: c.node, channel: c.channel, frame: k.frame), b.x > a.x)
                }
            }
        }
        return nil
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0).onChanged { g in
            if drag == nil {
                focused = true
                let shift = NSEvent.modifierFlags.contains(.shift)
                if let (pick, out) = hitHandle(g.startLocation) {
                    session.beginDrag()
                    drag = .slope(pick, out: out, start: curves)
                } else if let pick = hitKey(g.startLocation) {
                    if !selected.contains(pick) { selected = shift ? selected.union([pick]) : [pick] }
                    session.beginDrag()
                    drag = .keys(start: curves, at: g.startLocation)
                } else {
                    if !shift { selected = [] }
                    drag = .box(from: g.startLocation, to: g.startLocation)
                }
            }
            switch drag {
            case .keys(let start, let at)?:
                let df = (frame(g.location.x) - frame(at.x)).rounded(), dv = value(g.location.y) - value(at.y)
                session.setCurvesLive(ProcCurveEditor.moving(start, selected, df, dv))
            case .slope(let pick, let out, let start)?:
                guard let c = start.first(where: { $0.node == pick.node && $0.channel == pick.channel }), let i = c.curve.index(at: pick.frame) else { return }
                let k = c.curve.keys[i]
                let df = frame(g.location.x) - k.frame
                guard abs(df) > 1e-3, (df > 0) == out else { return }
                let slope = (value(g.location.y) - k.value) / df
                var curve = c.curve
                let both = !NSEvent.modifierFlags.contains(.option), was = c.curve.slopes(i)
                curve.update(i) { $0.slopes = both ? SIMD2(repeating: slope) : out ? SIMD2(was.x, slope) : SIMD2(slope, was.y) }
                session.setCurvesLive([(c.node, c.channel, curve)])
            case .box(let from, _)?:
                drag = .box(from: from, to: g.location)
            case nil: break
            }
        }.onEnded { g in
            switch drag {
            case .keys(_, let at)?:
                let df = (frame(g.location.x) - frame(at.x)).rounded()
                selected = Set(selected.map { Pick(node: $0.node, channel: $0.channel, frame: $0.frame + df) })
                session.endDrag("Move Keys")
            case .slope?:
                session.endDrag("Slopes")
            case .box(let a, let b)?:
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                for c in curves {
                    for k in c.curve.keys where rect.contains(point(k)) { selected.insert(Pick(node: c.node, channel: c.channel, frame: k.frame)) }
                }
            case nil: break
            }
            drag = nil
        }
    }

    /// `start`'s selected keys moved `df` frames and `dv` up (onto another key: it replaces it).
    static func moving(_ start: [(node: String, channel: String, curve: ProcCurve)], _ selected: Set<Pick>, _ df: Float, _ dv: Float)
        -> [(node: String, channel: String, curve: ProcCurve?)] {
        start.compactMap { c in
            let picked = c.curve.keys.map { selected.contains(Pick(node: c.node, channel: c.channel, frame: $0.frame)) }
            guard picked.contains(true) else { return nil }
            // The keys that stay first, so a moved key on their frame replaces them.
            let stay = zip(c.curve.keys, picked).filter { !$0.1 }.map(\.0)
            let moved = zip(c.curve.keys, picked).filter { $0.1 }.map { k, _ in
                var k = k
                k.frame += df
                k.value += dv
                return k
            }
            return (c.node, c.channel, ProcCurve(stay + moved, before: c.curve.before, after: c.curve.after))
        }
    }

    /// The selected keys' curves changed by `body` on each selected key, as one undo step.
    private func editSelected(_ name: String, _ body: (inout ProcKey) -> Void) {
        let changes = curves.compactMap { c -> (String, String, ProcCurve?)? in
            var curve = c.curve
            var any = false
            for i in curve.keys.indices where selected.contains(Pick(node: c.node, channel: c.channel, frame: curve.keys[i].frame)) {
                curve.update(i, body)
                any = true
            }
            return any ? (c.node, c.channel, curve) : nil
        }
        session.setCurves(changes, name)
    }

    /// The curves the extrapolation menus change: the selected keys', else every one shown.
    private func extrapolate(before: Bool, _ e: ProcExtrapolation) {
        let some = curves.filter { c in c.curve.keys.contains { selected.contains(Pick(node: c.node, channel: c.channel, frame: $0.frame)) } }
        session.setCurves((some.isEmpty ? curves : some).map { c in
            var curve = c.curve
            if before { curve.before = e } else { curve.after = e }
            return (c.node, c.channel, curve)
        }, "Extrapolation")
    }

    private func deleteSelected() {
        guard !selected.isEmpty else { return }
        let changes = curves.compactMap { c -> (String, String, ProcCurve?)? in
            var curve = c.curve
            for k in c.curve.keys where selected.contains(Pick(node: c.node, channel: c.channel, frame: k.frame)) { curve.remove(at: k.frame) }
            return curve == c.curve ? nil : (c.node, c.channel, curve.keys.isEmpty ? nil : curve)
        }
        selected = []
        session.setCurves(changes, "Delete Keys")
    }

    /// A double-click on (or near) a curve: a key on the whole frame there, of the curve's value.
    private func addKey(at p: CGPoint) {
        let f = frame(p.x).rounded()
        guard let c = curves.min(by: { abs(y($0.curve.value(at: f)) - p.y) < abs(y($1.curve.value(at: f)) - p.y) }),
              abs(y(c.curve.value(at: f)) - p.y) < 10 else { return }
        var curve = c.curve
        curve.set(f, c.curve.value(at: f))
        selected = [Pick(node: c.node, channel: c.channel, frame: f)]
        session.setCurves([(c.node, c.channel, curve)], "Add Key")
    }

    @ViewBuilder private var menu: some View {
        if !selected.isEmpty {
            Menu("Interpolation") {
                ForEach(ProcInterpolation.allCases, id: \.self) { m in Button(m.title) { editSelected("Interpolation") { $0.interpolation = m } } }
            }
            Button("Automatic Slopes") { editSelected("Slopes") { $0.slopes = nil } }
            Button("Delete Keys") { deleteSelected() }
            Divider()
        }
        Menu("Before the First Key") {
            ForEach(ProcExtrapolation.allCases, id: \.self) { e in Button(e.title) { extrapolate(before: true, e) } }
        }
        Menu("After the Last Key") {
            ForEach(ProcExtrapolation.allCases, id: \.self) { e in Button(e.title) { extrapolate(before: false, e) } }
        }
        Divider()
        Button("Frame All  F") { frameAll() }
    }

    // MARK: Scrolling

    /// Scroll wheel and trackpad scrolls while the pointer is over the curves: pan; with Control, zoom the frames
    /// (with Shift too, the values).
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] e in
            guard hovering, session.lowerTab == .curves else { return e }
            let dx = Float(e.scrollingDeltaX), dy = Float(e.scrollingDeltaY)
            if e.modifierFlags.contains(.control) {
                let s = Float(exp(Double(dy) * -0.01))
                let mid = (frames.lowerBound + frames.upperBound) / 2, vmid = (values.lowerBound + values.upperBound) / 2
                view = (ProcCurveEditor.scaled(frames, around: mid, by: s),
                        e.modifierFlags.contains(.shift) ? ProcCurveEditor.scaled(values, around: vmid, by: s) : values)
            } else {
                let fpp = (frames.upperBound - frames.lowerBound) / Float(max(size.width, 1))
                let vpp = (values.upperBound - values.lowerBound) / Float(max(size.height, 1))
                view = ((frames.lowerBound - dx * fpp)...(frames.upperBound - dx * fpp),
                        (values.lowerBound + dy * vpp)...(values.upperBound + dy * vpp))
            }
            return nil
        }
    }
}
