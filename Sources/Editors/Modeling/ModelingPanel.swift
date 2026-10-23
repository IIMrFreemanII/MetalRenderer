import AppKit
import Modeling
import SwiftUI

/// The modelling window (the Modeller): a window of its own beside the main one, Shift-Cmd-L or Shift-M in the main
/// view. Cmd-Z undoes its edits; Cmd-S saves its model into the asset library.
final class ModelingPanel: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: ModelingModel
    private static let visibleKey = "modeller.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(host: ModelingHost?) {
        model = ModelingModel(host: host)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Modeller"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.094, alpha: 1)
        window.minSize = NSSize(width: 900, height: 560)
        window.setFrameAutosaveName("Modeller")
        window.contentView = NSHostingView(rootView: ModelingView().environmentObject(model))
    }

    var isVisible: Bool { window.isVisible }

    func show(nextTo main: NSWindow) {
        if !window.setFrameUsingName("Modeller") {
            let visible = main.screen?.visibleFrame ?? main.frame
            window.setFrame(visible.insetBy(dx: visible.width * 0.06, dy: visible.height * 0.06), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: ModelingPanel.visibleKey)
        model.redraw()
    }

    func toggle(nextTo main: NSWindow) {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: ModelingPanel.visibleKey)
        } else {
            show(nextTo: main)
        }
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: ModelingPanel.visibleKey)
        model.cancelModal()
        if model.mode == .sculpt { model.leaveSculpt() }
        if model.shading.mode == .rendered { model.shading.mode = .solid }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the model before closing?"
        alert.informativeText = "\(model.document.name) has changes that aren't in the asset library."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.save(); return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
}
