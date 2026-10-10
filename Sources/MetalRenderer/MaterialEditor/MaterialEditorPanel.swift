import AppKit
import SwiftUI

/// The Material Designer's window (MaterialEditorView), beside the main one. It takes the keys when clicked: Delete
/// removes the selection, Tab adds a node, F frames the graph, Escape leaves a function (or clears the selection),
/// Cmd-C / Cmd-V copy and paste nodes, Cmd-Z undoes.
final class MaterialEditorPanel: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: MaterialEditorModel
    private static let visibleKey = "materialDesigner.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(controller: MaterialEditorHost) {
        model = MaterialEditorModel(controller: controller)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Material Designer"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("MaterialDesigner")
        let host = GraphHostingView(rootView: AnyView(MaterialEditorView().environmentObject(model)
            .environment(\.editorDrag, EditorDrag(begin: { [weak model] in model?.beginDrag() }, end: { [weak model] in model?.endDrag() }))))
        host.model = model
        host.keys = { [weak model] event in
            // Escape in a function: back to the graph.
            guard let model, event.keyCode == 53, model.editingFunction != nil, model.search == nil, model.selection.isEmpty else { return false }
            model.editingFunction = nil
            return true
        }
        window.contentView = host
        model.focusCanvas = { [weak window, weak host] in
            guard let window, let host, window.firstResponder !== host else { return }
            window.makeFirstResponder(host)
        }
    }

    var isVisible: Bool { window.isVisible }

    /// Shows the window (below the main one's left edge the first time).
    func show(nextTo main: NSWindow) {
        if !window.setFrameUsingName("MaterialDesigner") {
            let visible = main.screen?.visibleFrame ?? main.frame
            window.setFrameOrigin(NSPoint(x: max(main.frame.minX - 160, visible.minX), y: max(main.frame.minY - 200, visible.minY)))
        }
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: MaterialEditorPanel.visibleKey)
        DispatchQueue.main.async { [model] in model.frameAll(in: model.canvasSize) }
    }

    func toggle(nextTo main: NSWindow) {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: MaterialEditorPanel.visibleKey)
        } else {
            show(nextTo: main)
        }
    }

    func windowWillClose(_ notification: Notification) { UserDefaults.standard.set(false, forKey: MaterialEditorPanel.visibleKey) }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
