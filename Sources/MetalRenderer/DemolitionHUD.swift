import AppKit

/// The demolition scene's HUD (Renderer+Demolition.swift): a crosshair in the view's middle while the mouse is captured,
/// and a box in the bottom-left corner with the tools (the one in hand lit), the charges stuck, walking or flying, and
/// the keys. A view over the render: the frames never have it, and clicks go through it to the render view.
final class DemolitionHUD: NSView {
    private let cross = CAShapeLayer()
    private let panel = NSView()
    private let label = NSTextField(labelWithString: "")
    private var shown: DemolitionStatus?

    init() {
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
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 0
        panel.addSubview(label)
        addSubview(panel)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 11), label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 7), label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -7),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

    /// The renderer's tick: the player's state, or nothing (another scene).
    func show(_ status: DemolitionStatus?) {
        guard status != shown else { return }
        shown = status
        isHidden = status == nil
        guard let status else { return }
        cross.isHidden = !status.captured
        var lines = DemolitionTool.allCases.map { t in
            "\(t == status.tool ? "▶" : " ") \(t.rawValue + 1) \(t.title)"
        }
        lines.append("")
        lines.append(status.tool.help)
        if status.charges > 0 { lines.append("TNT stuck: \(status.charges)  (right click: off, Delete: take off)") }
        lines.append(status.walking ? "Walking  (Shift-V: fly)" : "Flying  (Shift-V: walk)")
        lines.append(status.captured ? "Esc: free the mouse   R: restart" : "Click in the view to aim   R: restart")
        if let m = status.message { lines.append(m) }
        label.stringValue = lines.joined(separator: "\n")
    }
}
