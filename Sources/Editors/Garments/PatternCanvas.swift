import AppKit
import Garments
import SwiftUI
import simd

/// The 2D pattern window: the sheet (a grid every 10 cm, every metre brighter), the panels filled in their fabrics'
/// colours with their outlines, points and handles, internal lines, grain lines, seam allowances and edge lengths,
/// the seams as pairs of coloured edges (a seam's sides a colour of its own, red where their lengths differ), and the
/// tool's draft. The mouse edits by tool (GarmentModel.Tool); scroll pans, pinch or Cmd-scroll zooms.
struct PatternCanvas: NSViewRepresentable {
    @ObservedObject var model: GarmentModel

    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ view: CanvasView, context: Context) { view.needsDisplay = true }
}

final class CanvasView: NSView {
    let model: GarmentModel
    private enum Drag {
        case panels(start: SIMD2<Float>, rotate: Bool)
        case point(panel: Int, point: Int, handle: Int, start: SIMD2<Float>)
        case rect(start: SIMD2<Float>, circle: Bool)
        case pan(start: CGPoint, pan: SIMD2<Float>)
        case box(start: SIMD2<Float>)
    }
    private var drag: Drag?
    private var mouse = SIMD2<Float>.zero
    private var dragNow = SIMD2<Float>.zero

    init(model: GarmentModel) {
        self.model = model
        super.init(frame: .zero)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // MARK: Mapping

    private func view(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: bounds.midX + CGFloat((p.x - model.pan.x) * model.zoom), y: bounds.midY + CGFloat((p.y - model.pan.y) * model.zoom))
    }
    private func sheet(_ v: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(v.x - bounds.midX) / model.zoom + model.pan.x, Float(v.y - bounds.midY) / model.zoom + model.pan.y)
    }
    private func sheet(_ e: NSEvent) -> SIMD2<Float> { sheet(convert(e.locationInWindow, from: nil)) }
    /// A few pixels, in metres.
    private func px(_ n: Float) -> Float { n / model.zoom }

    /// `p` snapped: to another panel's point within 8 px, or to the centimetre grid.
    private func snapped(_ p: SIMD2<Float>, except: (panel: Int, point: Int)? = nil) -> SIMD2<Float> {
        guard model.snap else { return p }
        for panel in model.garment.panels {
            for (k, q) in panel.points.enumerated() where !(except?.panel == panel.id && except?.point == k) {
                if simd_distance(q.p, p) < px(8) { return q.p }
            }
        }
        return CanvasView.centimetre(p)
    }

    private static func centimetre(_ p: SIMD2<Float>) -> SIMD2<Float> { (p * 100).rounded(.toNearestOrAwayFromZero) / 100 }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        model.canvasSize = bounds.size
        GarmentTheme.canvas.setFill()
        ctx.fill(bounds)
        drawGrid(ctx)
        let g = model.garment
        for p in g.panels { drawPanel(ctx, p, g) }
        drawSeams(ctx, g)
        drawDraft(ctx)
        drawBox(ctx)
    }

    private func drawGrid(_ ctx: CGContext) {
        let lo = sheet(CGPoint(x: 0, y: 0)), hi = sheet(CGPoint(x: bounds.maxX, y: bounds.maxY))
        let step: Float = model.zoom > 150 ? 0.1 : 0.5
        ctx.setLineWidth(1)
        var x = (lo.x / step).rounded(.down) * step
        while x <= hi.x {
            let major = abs(x - x.rounded()) < 1e-4
            ctx.setStrokeColor((major ? GarmentTheme.gridMajor : GarmentTheme.grid).cgColor)
            let a = view(SIMD2(x, lo.y)), b = view(SIMD2(x, hi.y))
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            x += step
        }
        var y = (lo.y / step).rounded(.down) * step
        while y <= hi.y {
            let major = abs(y - y.rounded()) < 1e-4
            ctx.setStrokeColor((major ? GarmentTheme.gridMajor : GarmentTheme.grid).cgColor)
            let a = view(SIMD2(lo.x, y)), b = view(SIMD2(hi.x, y))
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            y += step
        }
    }

    private func path(_ pts: [SIMD2<Float>], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let f = pts.first else { return path }
        path.move(to: view(f))
        for q in pts.dropFirst() { path.addLine(to: view(q)) }
        if closed { path.closeSubpath() }
        return path
    }

    private func drawPanel(_ ctx: CGContext, _ p: Panel, _ g: Garment) {
        let outline = p.outline
        let selected = model.selection.contains(p.id)
        let fabric = g.fabric(of: p)
        let base = NSColor(red: CGFloat(fabric.color.x), green: CGFloat(fabric.color.y), blue: CGFloat(fabric.color.z), alpha: 1)
        let fill = base.blended(withFraction: 0.55, of: .white) ?? base
        ctx.addPath(path(outline, closed: true))
        ctx.setFillColor(fill.withAlphaComponent(p.hidden ? 0.15 : (p.frozen ? 0.45 : 0.82)).cgColor)
        ctx.fillPath()
        if p.frozen {
            // Frozen: hatched.
            ctx.saveGState()
            ctx.addPath(path(outline, closed: true))
            ctx.clip()
            ctx.setStrokeColor(GarmentTheme.frozen.cgColor)
            ctx.setLineWidth(1)
            let b = p.bounds
            var x = b.lo.x - (b.hi.y - b.lo.y)
            while x < b.hi.x { ctx.move(to: view(SIMD2(x, b.lo.y))); ctx.addLine(to: view(SIMD2(x + (b.hi.y - b.lo.y), b.hi.y))); x += 0.03 }
            ctx.strokePath()
            ctx.restoreGState()
        }
        if model.showAllowance && model.allowance > 0 {
            ctx.addPath(path(p.allowance(model.allowance), closed: true))
            ctx.setStrokeColor(GarmentTheme.allowance.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.addPath(path(outline, closed: true))
        ctx.setStrokeColor((selected ? GarmentTheme.accent : GarmentTheme.outline).cgColor)
        ctx.setLineWidth(selected ? 2.2 : 1.2)
        ctx.strokePath()
        // Internal lines: folds dashed, elastics dotted, topstitch fine dashes.
        for l in p.lines {
            ctx.addPath(path(l.points, closed: false))
            ctx.setStrokeColor(GarmentTheme.internalLine.cgColor)
            ctx.setLineWidth(1.4)
            switch l.kind {
            case .fold: ctx.setLineDash(phase: 0, lengths: [7, 4])
            case .elastic: ctx.setLineDash(phase: 0, lengths: [2, 3])
            case .topstitch: ctx.setLineDash(phase: 0, lengths: [3, 2])
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // The grain: an arrow through the middle.
        let c = p.centre, size = min(0.12, simd_length(p.bounds.hi - p.bounds.lo) * 0.18)
        let d = SIMD2<Float>(cos(p.grain), sin(p.grain)) * size, side = SIMD2(-d.y, d.x) * 0.2
        ctx.setStrokeColor(GarmentTheme.grain.cgColor)
        ctx.setLineWidth(1.2)
        ctx.move(to: view(c - d)); ctx.addLine(to: view(c + d))
        ctx.move(to: view(c + d)); ctx.addLine(to: view(c + d * 0.75 + side))
        ctx.move(to: view(c + d)); ctx.addLine(to: view(c + d * 0.75 - side))
        ctx.strokePath()
        label(p.name + (p.mirrorOf != nil ? " ⇋" : ""), at: view(c - SIMD2(0, size + px(14))), color: GarmentTheme.text, size: 11, centred: true)
        // Points (and handles) of the selected panels, edge lengths.
        if selected || model.tool == .editPoint {
            for (k, q) in p.points.enumerated() {
                let v = view(q.p)
                let isSel = model.selectedPoint?.panel == p.id && model.selectedPoint?.point == k
                if isSel || (selected && q.isCurved && model.tool == .editPoint) {
                    ctx.setStrokeColor(GarmentTheme.handle.cgColor)
                    ctx.setLineWidth(1)
                    for h in [q.handleIn, q.handleOut] where h != .zero {
                        ctx.move(to: v); ctx.addLine(to: view(q.p + h)); ctx.strokePath()
                        ctx.setFillColor(GarmentTheme.handle.cgColor)
                        ctx.fillEllipse(in: CGRect(x: view(q.p + h).x - 3, y: view(q.p + h).y - 3, width: 6, height: 6))
                    }
                }
                ctx.setFillColor((isSel ? GarmentTheme.accent : GarmentTheme.point).cgColor)
                ctx.fill(CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6))
            }
        }
        if model.showLengths && (selected || model.selection.isEmpty && model.zoom > 250) {
            for e in p.points.indices {
                let curve = p.edge(e)
                let mid = curve.point(at: 0.5), t = curve.tangent(at: 0.5)
                let out = SIMD2<Float>(t.y, -t.x) * px(10)
                label(String(format: "%.1f", curve.length * 100), at: view(mid + out), color: GarmentTheme.dim, size: 9, centred: true)
            }
        }
        for b in model.garment.buttons where b.panel == p.id {
            let v = view(b.at), r = CGFloat(max(3, b.radius * model.zoom))
            ctx.setStrokeColor(GarmentTheme.outline.cgColor)
            ctx.strokeEllipse(in: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r))
        }
    }

    private func drawSeams(_ ctx: CGContext, _ g: Garment) {
        let bad = Set(model.mismatchedSeams.map(\.seam))
        for (n, s) in g.seams.enumerated() {
            let colour = bad.contains(s.id) ? GarmentTheme.warning : GarmentTheme.seamColour(n)
            let selected = model.selectedSeam == s.id
            var mids: [CGPoint] = []
            for side in [s.a, s.b] {
                for e in side {
                    guard let p = g.panel(id: e.panel), p.points.indices.contains(e.edge) else { continue }
                    let curve = p.edge(e.edge)
                    let n = 16
                    let pts = (0...n).map { curve.point(at: e.t0 + (e.t1 - e.t0) * Float($0) / Float(n)) }
                    ctx.addPath(path(pts, closed: false))
                    ctx.setStrokeColor(colour.cgColor)
                    ctx.setLineWidth(selected ? 5 : 3)
                    ctx.strokePath()
                    // Its start: a tick (sides meet start to start).
                    let start = view(pts[0])
                    ctx.setFillColor(colour.cgColor)
                    ctx.fillEllipse(in: CGRect(x: start.x - 3.5, y: start.y - 3.5, width: 7, height: 7))
                    mids.append(view(curve.point(at: (e.t0 + e.t1) / 2)))
                }
            }
            if selected, mids.count >= 2 {
                ctx.setStrokeColor(colour.withAlphaComponent(0.6).cgColor)
                ctx.setLineDash(phase: 0, lengths: [3, 4])
                ctx.setLineWidth(1)
                ctx.move(to: mids[0])
                for m in mids.dropFirst() { ctx.addLine(to: m) }
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        // The seam being made.
        for (k, side) in [model.seamDraft.a, model.seamDraft.b].enumerated() {
            for e in side {
                guard let p = g.panel(id: e.panel), p.points.indices.contains(e.edge) else { continue }
                let curve = p.edge(e.edge)
                ctx.addPath(path((0...16).map { curve.point(at: e.t0 + (e.t1 - e.t0) * Float($0) / 16) }, closed: false))
                ctx.setStrokeColor((k == 0 ? GarmentTheme.accent : GarmentTheme.seamColour(3)).cgColor)
                ctx.setLineWidth(5)
                ctx.strokePath()
            }
        }
    }

    private func drawDraft(_ ctx: CGContext) {
        if !model.draft.isEmpty {
            ctx.addPath(path(model.draft + [mouse], closed: false))
            ctx.setStrokeColor(GarmentTheme.accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
            for q in model.draft { let v = view(q); ctx.setFillColor(GarmentTheme.accent.cgColor); ctx.fill(CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6)) }
            if let last = model.draft.last {
                label(String(format: "%.1f cm", simd_distance(last, mouse) * 100), at: view(mouse + SIMD2(px(10), px(10))), color: GarmentTheme.text, size: 10, centred: false)
            }
        }
        if case .rect(let start, let circle) = drag {
            let lo = simd_min(start, dragNow), hi = simd_max(start, dragNow)
            let r = CGRect(x: view(lo).x, y: view(lo).y, width: CGFloat((hi.x - lo.x) * model.zoom), height: CGFloat((hi.y - lo.y) * model.zoom))
            ctx.setStrokeColor(GarmentTheme.accent.cgColor)
            if circle { ctx.strokeEllipse(in: r) } else { ctx.stroke(r) }
            label(String(format: "%.1f × %.1f cm", (hi.x - lo.x) * 100, (hi.y - lo.y) * 100), at: view(hi + SIMD2(px(6), 0)), color: GarmentTheme.text, size: 10, centred: false)
        }
    }

    private func drawBox(_ ctx: CGContext) {
        guard case .box(let start) = drag else { return }
        let lo = simd_min(start, dragNow), hi = simd_max(start, dragNow)
        let r = CGRect(x: view(lo).x, y: view(lo).y, width: CGFloat((hi.x - lo.x) * model.zoom), height: CGFloat((hi.y - lo.y) * model.zoom))
        ctx.setStrokeColor(GarmentTheme.accent.withAlphaComponent(0.8).cgColor)
        ctx.setFillColor(GarmentTheme.accent.withAlphaComponent(0.08).cgColor)
        ctx.fill(r)
        ctx.stroke(r)
    }

    private func label(_ s: String, at p: CGPoint, color: NSColor, size: CGFloat, centred: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color]
        let text = NSAttributedString(string: s, attributes: attrs)
        let w = text.size()
        text.draw(at: CGPoint(x: centred ? p.x - w.width / 2 : p.x, y: p.y - w.height / 2))
    }

    // MARK: Hits

    private func panelAt(_ q: SIMD2<Float>) -> Panel? { model.garment.panels.last { $0.contains(q) } }

    private func pointAt(_ q: SIMD2<Float>) -> (panel: Int, point: Int, handle: Int)? {
        for p in model.garment.panels.reversed() where model.selection.contains(p.id) || model.tool == .editPoint {
            for (k, pt) in p.points.enumerated() {
                if pt.handleIn != .zero, simd_distance(pt.p + pt.handleIn, q) < px(6) { return (p.id, k, 1) }
                if pt.handleOut != .zero, simd_distance(pt.p + pt.handleOut, q) < px(6) { return (p.id, k, 2) }
                if simd_distance(pt.p, q) < px(7) { return (p.id, k, 0) }
            }
        }
        return nil
    }

    private func edgeAt(_ q: SIMD2<Float>) -> (panel: Int, edge: Int, f: Float)? {
        var best: (panel: Int, edge: Int, f: Float, d: Float)?
        for p in model.garment.panels {
            if let n = p.nearestEdge(q), n.distance < px(8), best == nil || n.distance < best!.d { best = (p.id, n.edge, n.f, n.distance) }
        }
        return best.map { ($0.panel, $0.edge, $0.f) }
    }

    private func seamAt(_ q: SIMD2<Float>) -> Int? {
        for s in model.garment.seams {
            for e in s.a + s.b {
                guard let p = model.garment.panel(id: e.panel), p.points.indices.contains(e.edge) else { continue }
                let n = p.edge(e.edge).nearest(q)
                if n.distance < px(5) && n.f >= min(e.t0, e.t1) - 0.01 && n.f <= max(e.t0, e.t1) + 0.01 { return s.id }
            }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) {
        mouse = snapped(sheet(e))
        if !model.draft.isEmpty { needsDisplay = true }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let q = sheet(e), shift = e.modifierFlags.contains(.shift)
        dragNow = q
        if e.modifierFlags.contains(.option) || e.buttonNumber == 2 { drag = .pan(start: convert(e.locationInWindow, from: nil), pan: model.pan); return }
        switch model.tool {
        case .select:
            if let s = seamAt(q), panelAt(q) == nil || e.clickCount == 1 && !shift, edgeAt(q) != nil {
                model.selectedSeam = s
                model.selection = []
                model.tab = .seam
                return
            }
            if let p = panelAt(q) {
                if shift { if model.selection.contains(p.id) { model.selection.remove(p.id) } else { model.selection.insert(p.id) } }
                else if !model.selection.contains(p.id) { model.selection = [p.id] }
                model.selectedSeam = nil
                model.tab = .panel
                model.beginDrag()
                drag = .panels(start: q, rotate: e.modifierFlags.contains(.command))
            } else {
                if !shift { model.selection = []; model.selectedSeam = nil }
                drag = .box(start: q)
            }
        case .editPoint:
            if let hit = pointAt(q) {
                model.selectedPoint = (hit.panel, hit.point)
                model.selection = [hit.panel]
                model.beginDrag()
                drag = .point(panel: hit.panel, point: hit.point, handle: hit.handle, start: q)
            } else if let edge = edgeAt(q) {
                // Double-click an edge: a point there (curved edges keep their shape: a smooth point with handles).
                if e.clickCount == 2 { insertPoint(edge) } else { model.selection = [edge.panel]; model.selectedPoint = nil }
            } else if let p = panelAt(q) {
                model.selection = [p.id]; model.selectedPoint = nil
            } else {
                model.selection = []; model.selectedPoint = nil
            }
        case .polygon:
            let s = snapped(q)
            if let first = model.draft.first, model.draft.count >= 3, simd_distance(first, s) < px(9) || e.clickCount == 2 { closePolygon(); return }
            model.draft.append(s)
        case .rectangle, .circle:
            drag = .rect(start: snapped(q), circle: model.tool == .circle)
        case .line:
            let s = snapped(q)
            if e.clickCount == 2 { finishLine(); return }
            model.draft.append(s)
        case .dart:
            if let edge = edgeAt(q) { model.addDart(panel: edge.panel, edge: edge.edge, at: edge.f) }
        case .seam:
            if let edge = edgeAt(q) { model.seamClick(panel: edge.panel, edge: edge.edge, at: edge.f, extend: shift) }
        case .freeze:
            if let p = panelAt(q) { let id = p.id; model.edit(p.frozen ? "Unfreeze" : "Freeze") { g in if let i = g.panelIndex(id: id) { g.panels[i].frozen.toggle() } } }
        case .trace:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let q = sheet(e)
        defer { dragNow = q; needsDisplay = true }
        switch drag {
        case .panels(let start, let rotate):
            let ids = model.selection
            if rotate {
                // Cmd-drag turns the selection about its middle.
                var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
                for p in model.garment.panels where ids.contains(p.id) { lo = simd_min(lo, p.bounds.lo); hi = simd_max(hi, p.bounds.hi) }
                let c = (lo + hi) / 2
                let a0 = atan2(dragNow.y - c.y, dragNow.x - c.x), a1 = atan2(q.y - c.y, q.x - c.x)
                model.dragEdit { g in for i in g.panels.indices where ids.contains(g.panels[i].id) { g.panels[i].rotate(a1 - a0, about: c) } }
            } else {
                var d = q - dragNow
                if model.snap {
                    let now: SIMD2<Float> = CanvasView.centimetre(q - start), before: SIMD2<Float> = CanvasView.centimetre(dragNow - start)
                    d = now - before
                }
                model.dragEdit { g in for i in g.panels.indices where ids.contains(g.panels[i].id) { g.panels[i].translate(d) } }
            }
        case .point(let panel, let point, let handle, _):
            let s = handle == 0 ? snapped(q, except: (panel, point)) : q
            model.dragEdit { g in
                guard let i = g.panelIndex(id: panel) else { return }
                var pt = g.panels[i].points[point]
                switch handle {
                case 1:
                    pt.handleIn = s - pt.p
                    if pt.smooth { pt.handleOut = -simd_normalize(pt.handleIn) * simd_length(pt.handleOut) }
                case 2:
                    pt.handleOut = s - pt.p
                    if pt.smooth { pt.handleIn = -simd_normalize(pt.handleOut) * simd_length(pt.handleIn) }
                default: pt.p = s
                }
                g.panels[i].points[point] = pt
            }
        case .pan(let start, let pan):
            let v = convert(e.locationInWindow, from: nil)
            model.pan = pan - SIMD2(Float(v.x - start.x), Float(v.y - start.y)) / model.zoom
        default: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        let q = sheet(e)
        switch drag {
        case .panels(_, let rotate): model.endDrag(rotate ? "Rotate" : "Move")
        case .point: model.endDrag("Edit Point")
        case .rect(let start, let circle):
            let end = snapped(q), lo = simd_min(start, end), hi = simd_max(start, end)
            if hi.x - lo.x > 0.02 && hi.y - lo.y > 0.02 {
                if circle {
                    let c = (lo + hi) / 2, r = (hi - lo) / 2, k: Float = 0.5523
                    model.addPanel("Circle", [
                        PathPoint(c + SIMD2(r.x, 0), handleIn: SIMD2(0, -r.y * k), handleOut: SIMD2(0, r.y * k), smooth: true),
                        PathPoint(c + SIMD2(0, r.y), handleIn: SIMD2(r.x * k, 0), handleOut: SIMD2(-r.x * k, 0), smooth: true),
                        PathPoint(c - SIMD2(r.x, 0), handleIn: SIMD2(0, r.y * k), handleOut: SIMD2(0, -r.y * k), smooth: true),
                        PathPoint(c - SIMD2(0, r.y), handleIn: SIMD2(-r.x * k, 0), handleOut: SIMD2(r.x * k, 0), smooth: true)])
                } else {
                    model.addPanel("Rectangle", [PathPoint(lo), PathPoint(SIMD2(hi.x, lo.y)), PathPoint(hi), PathPoint(SIMD2(lo.x, hi.y))])
                }
            }
        case .box(let start):
            let lo = simd_min(start, q), hi = simd_max(start, q)
            if hi.x - lo.x > px(4) {
                let inside = model.garment.panels.filter { let b = $0.bounds; return b.lo.x >= lo.x && b.hi.x <= hi.x && b.lo.y >= lo.y && b.hi.y <= hi.y }
                model.selection.formUnion(inside.map(\.id))
            }
        default: break
        }
        drag = nil
        needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) { drag = .pan(start: convert(e.locationInWindow, from: nil), pan: model.pan) }
    override func rightMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func rightMouseUp(with e: NSEvent) { drag = nil }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            zoom(by: exp(Float(e.scrollingDeltaY) * 0.01), at: convert(e.locationInWindow, from: nil))
        } else {
            let k: Float = e.hasPreciseScrollingDeltas ? 1 : 10
            model.pan -= SIMD2(Float(-e.scrollingDeltaX), Float(e.scrollingDeltaY)) * k / model.zoom
        }
        needsDisplay = true
    }

    override func magnify(with e: NSEvent) { zoom(by: Float(1 + e.magnification), at: convert(e.locationInWindow, from: nil)) }

    private func zoom(by f: Float, at v: CGPoint) {
        let before = sheet(v)
        model.zoom = max(30, min(5000, model.zoom * f))
        let after = sheet(v)
        model.pan += before - after
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 36, 76:   // Return
            if model.tool == .polygon { closePolygon() } else if model.tool == .line { finishLine() } else if model.tool == .seam { model.finishSeam() }
        case 53:       // Escape
            model.draft = []; model.seamDraft = ([], []); model.selection = []; model.selectedSeam = nil; model.selectedPoint = nil
        case 51, 117:  // Delete
            model.deleteSelection()
        default:
            if !GarmentKeys.handle(e, model: model) { super.keyDown(with: e) }
        }
        needsDisplay = true
    }

    // MARK: Tools' ends

    private func closePolygon() {
        let pts = model.draft
        model.draft = []
        guard pts.count >= 3 else { return }
        model.addPanel("Panel", pts.map { PathPoint($0) })
        model.tool = .select
    }

    private func finishLine() {
        let pts = model.draft
        model.draft = []
        guard pts.count >= 2, let p = panelAt((pts[0] + pts[pts.count - 1]) / 2) ?? panelAt(pts[0]) else { return }
        model.addLine(panel: p.id, points: pts)
    }

    private func insertPoint(_ edge: (panel: Int, edge: Int, f: Float)) {
        model.edit("Add Point") { g in
            guard let i = g.panelIndex(id: edge.panel) else { return }
            let p = g.panels[i]
            let curve = p.edge(edge.edge)
            let q = curve.point(at: edge.f), t = curve.tangent(at: edge.f) * curve.length * 0.15
            var pt = PathPoint(q)
            if !curve.straight { pt.handleIn = -t; pt.handleOut = t; pt.smooth = true }
            g.panels[i].points.insert(pt, at: edge.edge + 1)
            for s in g.seams.indices {
                for k in g.seams[s].a.indices where g.seams[s].a[k].panel == edge.panel && g.seams[s].a[k].edge > edge.edge { g.seams[s].a[k].edge += 1 }
                for k in g.seams[s].b.indices where g.seams[s].b[k].panel == edge.panel && g.seams[s].b[k].edge > edge.edge { g.seams[s].b[k].edge += 1 }
            }
        }
    }
}

/// The designer's keys, in either view: the tools' letters, Space (simulate), Cmd-D (duplicate), Shift-Cmd-D (a
/// linked mirror), F (frame the pattern).
enum GarmentKeys {
    static func handle(_ e: NSEvent, model: GarmentModel) -> Bool {
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        if chars == " " { model.toggleSimulation(); return true }
        if cmd && chars == "d" { model.duplicateSelection(mirrored: shift); return true }
        if cmd { return false }
        if chars == "f" && shift { model.frame(); return true }
        if let tool = GarmentModel.Tool.allCases.first(where: { $0.key == chars }) { model.tool = tool; return true }
        return false
    }
}
