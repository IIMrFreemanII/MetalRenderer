import AppKit

/// The destruction scene's tools (keys 1, 2, 3: Renderer+Destruction.swift): a small box in the render view's top-left
/// corner naming the one a click uses, while that scene is up. A view over the render: the frames never have it.
final class DestructionOverlay: NSView {
    private let label = NSTextField(labelWithString: "")
    private var shown: DestructionStatus?

    package init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        isHidden = true
    }
    package required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mouse and keys go to the render view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func attach(to view: NSView) {
        view.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
    }

    /// The renderer's tick: the scene's tool, or nothing (another scene).
    func show(_ status: DestructionStatus?) {
        guard status != shown else { return }
        shown = status
        isHidden = status == nil
        guard let status else { return }
        let keys = DestructionTool.allCases.map { "\($0.rawValue + 1) \($0.title)" }.joined(separator: "   ")
        label.stringValue = "\(status.tool.title): \(status.tool.help)\n\(keys)"
    }
}
