import AppKit
import SwiftUI

/// The VFX editor's window (VFXEditorView), a window of its own beside the main one. It takes the keys when clicked:
/// Delete removes the selection, Tab adds a node, F frames the graph, Cmd-C / Cmd-V copy and paste nodes, Cmd-Z undoes.
final class VFXEditorPanel: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: VFXEditorModel
    private static let visibleKey = "vfxEditor.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(controller: VFXEditorHost) {
        model = VFXEditorModel(controller: controller)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "VFX Editor"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("VFXEditor")
        let host = VFXHostingView(rootView: AnyView(VFXEditorView().environmentObject(model)))
        host.model = model
        window.contentView = host
        model.focusCanvas = { [weak window, weak host] in
            guard let window, let host, window.firstResponder !== host else { return }
            window.makeFirstResponder(host)
        }
    }

    var isVisible: Bool { window.isVisible }

    /// Shows the window (below the main one's left edge the first time).
    func show(nextTo main: NSWindow) {
        if !window.setFrameUsingName("VFXEditor") {
            let visible = main.screen?.visibleFrame ?? main.frame
            window.setFrameOrigin(NSPoint(x: max(main.frame.minX - 120, visible.minX), y: max(main.frame.minY - 180, visible.minY)))
        }
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: VFXEditorPanel.visibleKey)
        DispatchQueue.main.async { [model] in model.frameAll(in: model.canvasSize) }
    }

    func toggle(nextTo main: NSWindow) {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: VFXEditorPanel.visibleKey)
        } else {
            show(nextTo: main)
        }
    }

    func windowWillClose(_ notification: Notification) { UserDefaults.standard.set(false, forKey: VFXEditorPanel.visibleKey) }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}

/// The editor's view: its keys and the canvas's scrolling and pinching (SwiftUI on macOS 13 has neither), and the
/// Edit menu's Copy, Paste, Cut, Delete and Select All for the graph.
final class VFXHostingView: NSHostingView<AnyView> {
    weak var model: VFXEditorModel?

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
        switch event.keyCode {
        case 51, 117: model.deleteSelection()                        // Delete, Forward Delete
        case 48: model.openSearch()                                  // Tab
        case 53: if model.search != nil { model.search = nil } else { model.clearSelection() }   // Escape
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" { model.frameAll(in: model.canvasSize) } else { super.keyDown(with: event) }
        }
    }

    @objc func copy(_ sender: Any?) { model?.copySelection() }
    @objc func paste(_ sender: Any?) { model?.paste() }
    @objc func cut(_ sender: Any?) { model?.copySelection(); model?.deleteSelection() }
    @objc func delete(_ sender: Any?) { model?.deleteSelection() }
    override func selectAll(_ sender: Any?) {
        guard let model else { return }
        model.selection = Set(model.effect.nodes.map(\.id)).union(model.effect.emitters.map(\.id))
    }
}
