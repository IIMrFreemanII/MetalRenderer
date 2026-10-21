import AppKit
import Characters
import EngineCore
import MetalRenderer
import Physics
import Plants
import SwiftUI

/// The Fracture Editor's window (FractureEditorView), beside the main one: Shift-F or Shift-Cmd-F.
final class FractureEditorPanel: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: FractureEditorModel
    private static let visibleKey = "fractureEditor.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    package init(host: FractureEditorHost) {
        model = FractureEditorModel(host: host)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Fracture Editor"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("FractureEditor")
        window.contentView = NSHostingView(rootView: FractureEditorView().environmentObject(model))
    }

    var isVisible: Bool { window.isVisible }

    func show(nextTo main: NSWindow) {
        if !window.setFrameUsingName("FractureEditor") {
            window.setFrameOrigin(NSPoint(x: main.frame.maxX + 8, y: main.frame.maxY - window.frame.height))
        }
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: FractureEditorPanel.visibleKey)
    }

    func toggle(nextTo main: NSWindow) {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: FractureEditorPanel.visibleKey)
        } else {
            show(nextTo: main)
        }
    }

    func windowWillClose(_ notification: Notification) { UserDefaults.standard.set(false, forKey: FractureEditorPanel.visibleKey) }
}
