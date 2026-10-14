import AppKit
import simd

/// The scene gizmo (Unity's): in the render view's top-right corner, the world's axes as the camera sees them, with
/// the view's name under them. A click on an axis's cone views from that side (Top, Front, ...); a drag turns the view
/// in 45° steps. The renderer turns the camera about the pivot (Renderer.snapView, stepView). A view over the render:
/// the frames themselves never have it.
final class SceneGizmo: NSView {
    /// An axis's arm as the camera sees it: where its end is (in arm lengths from the centre, y up), and how far it
    /// points away from the view (-1: straight at it).
    struct Arm {
        var axis: ViewAxis
        var point: SIMD2<Float>
        var depth: Float
    }

    static let width: CGFloat = 96, labelHeight: CGFloat = 16
    /// An arm's length, and its cone's radius, in points.
    static let reach: Float = 27, coneRadius: Float = 7

    /// A cone was clicked; the gizmo was dragged so many 45° steps (right, up).
    var onSnap: ((ViewAxis) -> Void)?
    var onStep: ((_ yawSteps: Int, _ pitchSteps: Int) -> Void)?

    private(set) var yaw: Float = 0, pitch: Float = -0.06
    private var dragged = SIMD2<Float>.zero
    private var dragging = false

    /// The six arms as the camera at `yaw`, `pitch` sees them, back to front.
    static func layout(yaw: Float, pitch: Float) -> [Arm] {
        var c = Camera()
        c.yaw = yaw
        c.pitch = pitch
        let r = c.right, u = c.up, f = c.forward
        return ViewAxis.allCases
            .map { Arm(axis: $0, point: SIMD2(dot($0.direction, r), dot($0.direction, u)), depth: dot($0.direction, f)) }
            .sorted { $0.depth > $1.depth }
    }

    /// The axis whose cone is at `p` (points from the gizmo's centre, y up): of those there, the one nearest the view.
    static func hit(_ p: SIMD2<Float>, yaw: Float, pitch: Float) -> ViewAxis? {
        layout(yaw: yaw, pitch: pitch)
            .filter { simd_distance($0.point * reach, p) <= coneRadius + 3 }
            .min { $0.depth < $1.depth }?.axis
    }

    /// The view's name: the axis it looks along, or "Persp".
    static func title(yaw: Float, pitch: Float) -> String {
        var c = Camera()
        c.yaw = yaw
        c.pitch = pitch
        return ViewAxis.snapped(c.forward)?.title ?? "Persp"
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: SceneGizmo.width, height: SceneGizmo.width + SceneGizmo.labelHeight))
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Puts it in `view`'s top-right corner.
    func attach(to view: NSView) {
        view.addSubview(self)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            widthAnchor.constraint(equalToConstant: SceneGizmo.width),
            heightAnchor.constraint(equalToConstant: SceneGizmo.width + SceneGizmo.labelHeight),
        ])
    }

    /// The camera turned.
    func show(yaw: Float, pitch: Float) {
        guard yaw != self.yaw || pitch != self.pitch else { return }
        self.yaw = yaw
        self.pitch = pitch
        needsDisplay = true
    }

    private var centre: CGPoint { CGPoint(x: bounds.midX, y: SceneGizmo.labelHeight + SceneGizmo.width / 2) }

    private static func colour(_ axis: ViewAxis) -> NSColor {
        guard axis.isPositive else { return NSColor(white: 0.72, alpha: 1) }
        switch axis.letter {
        case "X": return NSColor(srgbRed: 0.92, green: 0.3, blue: 0.24, alpha: 1)
        case "Y": return NSColor(srgbRed: 0.52, green: 0.82, blue: 0.27, alpha: 1)
        default: return NSColor(srgbRed: 0.27, green: 0.52, blue: 0.96, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let c = centre
        g.setFillColor(NSColor(white: 0.08, alpha: 0.45).cgColor)
        g.fillEllipse(in: CGRect(x: c.x - 46, y: c.y - 46, width: 92, height: 92))
        let arms = SceneGizmo.layout(yaw: yaw, pitch: pitch)
        // The centre's cube goes in among the arms: after those pointing away, before those pointing at the view.
        var cubeDrawn = false
        for arm in arms {
            if !cubeDrawn && arm.depth < 0 { drawCube(g, c); cubeDrawn = true }
            drawArm(g, arm, c)
        }
        if !cubeDrawn { drawCube(g, c) }
        // The view's name.
        let title = SceneGizmo.title(yaw: yaw, pitch: pitch) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                         .foregroundColor: NSColor(white: 0.92, alpha: 0.9)]
        let size = title.size(withAttributes: attributes)
        title.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: 1), withAttributes: attributes)
    }

    private func drawCube(_ g: CGContext, _ c: CGPoint) {
        let rect = CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
        g.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        g.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
        g.fillPath()
    }

    /// An arm: a cone from near the centre to its end, its base an ellipse as the arm leans (end on: a disc).
    private func drawArm(_ g: CGContext, _ arm: Arm, _ c: CGPoint) {
        let colour = SceneGizmo.colour(arm.axis).withAlphaComponent(arm.depth > 0.2 ? 0.75 : 1)
        let r = CGFloat(SceneGizmo.coneRadius)
        let end = CGPoint(x: c.x + CGFloat(arm.point.x * SceneGizmo.reach), y: c.y + CGFloat(arm.point.y * SceneGizmo.reach))
        let tip = CGPoint(x: c.x + CGFloat(arm.point.x * SceneGizmo.reach * 0.3), y: c.y + CGFloat(arm.point.y * SceneGizmo.reach * 0.3))
        let along = SIMD2<Double>(Double(arm.point.x), Double(arm.point.y))
        let length = simd_length(along)
        g.setFillColor(colour.cgColor)
        if length > 0.05 {
            let d = along / length, n = SIMD2(-d.y, d.x)
            // The base's ellipse: its radius across the arm, and the arm's lean along it.
            let lean = CGFloat(max(abs(Double(arm.depth)), 0.15)) * r
            let base = CGRect(x: -lean, y: -r, width: lean * 2, height: r * 2)
            g.beginPath()
            g.move(to: tip)
            g.addLine(to: CGPoint(x: end.x + n.x * r, y: end.y + n.y * r))
            g.addLine(to: CGPoint(x: end.x - n.x * r, y: end.y - n.y * r))
            g.closePath()
            g.fillPath()
            g.saveGState()
            g.translateBy(x: end.x, y: end.y)
            g.rotate(by: atan2(d.y, d.x))
            g.fillEllipse(in: base)
            g.restoreGState()
        } else {
            g.fillEllipse(in: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2))
        }
        // The positive axes' letters, past their cones.
        guard arm.axis.isPositive else { return }
        let label = arm.axis.letter as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attributes)
        // 11 points past the cone's end, on the way out (end on: on the disc).
        let out = length > 0.05 ? along / length * 11 : .zero
        let at = CGPoint(x: end.x + CGFloat(out.x) - size.width / 2, y: end.y + CGFloat(out.y) - size.height / 2)
        label.draw(at: at, withAttributes: attributes)
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only the disc takes the mouse; the rest of the corner is the render view's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return hypot(p.x - centre.x, p.y - centre.y) <= 48 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragged = .zero
        dragging = false
    }

    /// A drag: a 45° step each 24 points (right: the view turns right; up: it tips up).
    override func mouseDragged(with event: NSEvent) {
        dragged += SIMD2(Float(event.deltaX), Float(event.deltaY))
        if simd_length(dragged) > 3 { dragging = true }
        let step: Float = 24
        let yawSteps = Int(dragged.x / step), pitchSteps = Int(-dragged.y / step)
        guard yawSteps != 0 || pitchSteps != 0 else { return }
        dragged -= SIMD2(Float(yawSteps) * step, Float(-pitchSteps) * step)
        onStep?(yawSteps, pitchSteps)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragging = false }
        guard !dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let axis = SceneGizmo.hit(SIMD2(Float(p.x - centre.x), Float(p.y - centre.y)), yaw: yaw, pitch: pitch) { onSnap?(axis) }
    }
}
