import AppKit
import Procedural
import SwiftUI

/// Houdini's playbar, across the bottom of the Procedural workspace: to the start, play, the frame, the network's
/// range, and a ruler. Drag the ruler to scrub; the current node's keys are ticks on it: drag one to move the keys on
/// its frame (to whole frames), right-click it for their interpolation or to delete them.
struct ProcTimeline: View {
    @ObservedObject var session: ProceduralSession
    /// A drag of the keys on `from`: the curves as they were, and the frames moved by.
    @State private var moving: (from: Float, start: [(node: String, channel: String, curve: ProcCurve)])?
    @State private var hover: Float?

    var body: some View {
        let r = session.graph.frames
        HStack(spacing: 6) {
            Button { session.playing = false; session.frame = Float(r.lowerBound) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(.borderless).help("To the first frame")
            Button { session.playing.toggle() } label: { Image(systemName: session.playing ? "pause.fill" : "play.fill") }
                .buttonStyle(.borderless).help(session.playing ? "Stop" : "Play (24 frames a second, round again)")
            ProcNumberField(value: Double(session.frame)) { session.frame = Float($0) }.frame(width: 48).help("The frame ($F)")
            ProcNumberField(value: Double(r.lowerBound), integer: true) { v in
                session.setFrameRange(Int(v.rounded())...max(Int(v.rounded()), r.upperBound))
            }
            .frame(width: 40).help("The network's first frame")
            ruler(r)
            ProcNumberField(value: Double(r.upperBound), integer: true) { v in
                session.setFrameRange(min(r.lowerBound, Int(v.rounded()))...Int(v.rounded()))
            }
            .frame(width: 40).help("The network's last frame")
            Button("Range to Keys") {
                let spans = session.graph.nodes.flatMap { $0.curves.values.compactMap(\.span) }
                guard let lo = spans.map(\.lowerBound).min(), let hi = spans.map(\.upperBound).max() else { return }
                session.setFrameRange(Int(lo.rounded(.down))...max(Int(lo.rounded(.down)) + 1, Int(hi.rounded(.up))))
            }
            .buttonStyle(.borderless).font(ProcTheme.small)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(ProcTheme.paneHeader)
    }

    /// The frames on the current node's keys.
    private var keyFrames: [Float] {
        Array(Set(session.shownCurves.flatMap { $0.curve.keys.map(\.frame) })).sorted()
    }

    private func ruler(_ r: ClosedRange<Int>) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, lo = Float(r.lowerBound), hi = Float(max(r.upperBound, r.lowerBound + 1))
            let x = { (f: Float) in CGFloat((f - lo) / (hi - lo)) * w }
            let frame = { (px: CGFloat) in lo + Float(px / max(w, 1)) * (hi - lo) }
            let keys = keyFrames
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ProcTheme.field))
                // Ticks: a step that leaves room for the labels.
                let steps = [1, 2, 5, 10, 12, 24, 48, 120, 240, 480, 1200]
                let step = steps.first { CGFloat($0) * w / CGFloat(hi - lo) >= 36 } ?? 2400
                var f = (r.lowerBound / step) * step
                while f <= r.upperBound {
                    if f >= r.lowerBound {
                        let px = x(Float(f))
                        ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: size.height - 6)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                                   with: .color(ProcTheme.dim), lineWidth: 1)
                        ctx.draw(Text("\(f)").font(ProcTheme.small).foregroundColor(ProcTheme.dim), at: CGPoint(x: px + 2, y: 7), anchor: .leading)
                    }
                    f += step
                }
                for k in keys {
                    let px = x(k)
                    ctx.fill(Path(CGRect(x: px - 1.5, y: 3, width: 3, height: size.height - 6)), with: .color(ProcTheme.keyOn))
                }
                let px = x(session.frame)
                ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(ProcTheme.display))
                ctx.draw(Text(ProcExprContext.format(session.frame)).font(ProcTheme.small).foregroundColor(ProcTheme.text),
                         at: CGPoint(x: px + 3, y: size.height - 7), anchor: .leading)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = keys.first { abs(x($0) - p.x) < 4 } } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if moving == nil, let k = keys.first(where: { abs(x($0) - g.startLocation.x) < 4 }), g.translation != .zero {
                    session.beginDrag()
                    moving = (k, session.shownCurves)
                }
                if let m = moving {
                    let d = (frame(g.location.x) - m.from).rounded()
                    session.setCurvesLive(ProcTimeline.moved(m.start, from: m.from, by: d))
                } else {
                    session.frame = min(hi, max(lo, frame(g.location.x).rounded()))
                }
            }.onEnded { _ in
                if moving != nil { session.endDrag("Move Keys") }
                moving = nil
            })
            .contextMenu {
                if let k = hover {
                    Menu("Interpolation") {
                        ForEach(ProcInterpolation.allCases, id: \.self) { m in
                            Button(m.title) { session.setCurves(ProcTimeline.edited(session.shownCurves, on: k) { $0.interpolation = m }, "Interpolation") }
                        }
                    }
                    Button("Delete Keys") {
                        session.setCurves(session.shownCurves.compactMap { c in
                            guard c.curve.index(at: k) != nil else { return nil }
                            var curve = c.curve
                            curve.remove(at: k)
                            return (c.node, c.channel, curve.keys.isEmpty ? nil : curve)
                        }, "Delete Keys")
                    }
                } else {
                    Text("Right-click a key for its menu")
                }
            }
        }
        .frame(height: 20)
    }

    /// The curves with their keys on `frame` moved `d` frames (onto another key: it replaces it).
    static func moved(_ curves: [(node: String, channel: String, curve: ProcCurve)], from frame: Float, by d: Float)
        -> [(node: String, channel: String, curve: ProcCurve?)] {
        curves.map { c in
            var curve = c.curve
            if d != 0, let i = curve.index(at: frame) { curve.update(i) { $0.frame += d } }
            return (c.node, c.channel, curve)
        }
    }

    /// The curves with their keys on `frame` changed by `body`.
    static func edited(_ curves: [(node: String, channel: String, curve: ProcCurve)], on frame: Float, _ body: (inout ProcKey) -> Void)
        -> [(node: String, channel: String, curve: ProcCurve?)] {
        curves.compactMap { c in
            guard let i = c.curve.index(at: frame) else { return nil }
            var curve = c.curve
            curve.update(i, body)
            return (c.node, c.channel, curve)
        }
    }
}
