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
        let host = GraphHostingView(rootView: AnyView(VFXEditorView().environmentObject(model)))
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
