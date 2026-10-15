import AppKit
import SwiftUI

/// The Material Painter's window (PainterView), beside the main one: V or Shift-Cmd-P. Tab in it toggles paint mode;
/// Cmd-Z undoes its edits and strokes.
final class PainterPanel: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: PainterModel
    private static let visibleKey = "materialPainter.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(host: PainterHost) {
        model = PainterModel(host: host)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 800),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Material Painter"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("MaterialPainter")
        window.contentView = NSHostingView(rootView: PainterView().environmentObject(model))
    }

    var isVisible: Bool { window.isVisible }

    func show(nextTo main: NSWindow) {
        if !window.setFrameUsingName("MaterialPainter") {
            let visible = main.screen?.visibleFrame ?? main.frame
            window.setFrameOrigin(NSPoint(x: max(main.frame.minX - 120, visible.minX), y: max(main.frame.minY - 160, visible.minY)))
        }
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: PainterPanel.visibleKey)
        model.refreshPictures()
    }

    func toggle(nextTo main: NSWindow) {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: PainterPanel.visibleKey)
        } else {
            show(nextTo: main)
        }
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: PainterPanel.visibleKey)
        model.setPaintMode(false)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
