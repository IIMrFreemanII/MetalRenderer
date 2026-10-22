import AppKit
import EngineCore
import MetalRenderer
import Plants

/// A scene's HUD (SceneHUD, from its behaviour: the destruction's tools, the demolition's player): a box of text in a
/// corner of the render view, and a crosshair in its middle while the mouse is captured. A view over the render: the
/// frames never have it, and clicks go through it to the render view.
final class SceneHUDView: NSView {
    private let cross = CAShapeLayer()
    private let panel = NSView()
    private let label = NSTextField(labelWithString: "")
    private var shown: SceneHUD?
    private var corner: [NSLayoutConstraint] = []

    package init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        cross.strokeColor = NSColor(white: 1, alpha: 0.95).cgColor
        cross.lineWidth = 2
        cross.shadowColor = NSColor.black.cgColor
        cross.shadowOpacity = 0.9
        cross.shadowRadius = 1.5
        cross.shadowOffset = .zero
        cross.fillColor = nil
        layer?.addSublayer(cross)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        panel.layer?.cornerRadius = 8
        panel.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        panel.layer?.borderWidth = 1
        panel.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 0
        panel.addSubview(label)
        addSubview(panel)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 11), label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 7), label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -7),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        ])
        isHidden = true
    }
    package required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mouse and keys go to the render view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func attach(to view: NSView) {
        view.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor), trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topAnchor.constraint(equalTo: view.topAnchor), bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        // Two short bars each way with a gap in the middle.
        let c = CGPoint(x: bounds.midX, y: bounds.midY), gap: CGFloat = 4, arm: CGFloat = 9
        let path = CGMutablePath()
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] as [(CGFloat, CGFloat)] {
            path.move(to: CGPoint(x: c.x + dx * gap, y: c.y + dy * gap))
            path.addLine(to: CGPoint(x: c.x + dx * (gap + arm), y: c.y + dy * (gap + arm)))
        }
        cross.path = path
    }

    /// The renderer's tick: the scene's HUD, or nothing.
    func show(_ hud: SceneHUD?) {
        guard hud != shown else { return }
        let moved = hud?.corner != shown?.corner
        shown = hud
        isHidden = hud == nil
        guard let hud else { return }
        cross.isHidden = !hud.crosshair
        label.font = hud.monospaced ? .monospacedSystemFont(ofSize: 11.5, weight: .medium) : .systemFont(ofSize: 12, weight: .medium)
        label.stringValue = hud.lines.joined(separator: "\n")
        if moved {
            NSLayoutConstraint.deactivate(corner)
            corner = [hud.corner == .topLeft ? panel.topAnchor.constraint(equalTo: topAnchor, constant: 12)
                                             : panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)]
            NSLayoutConstraint.activate(corner)
        }
    }
}
