import AppKit
import SwiftUI

/// The Object inspector's floating panel (ObjectInspectorView). Option-Cmd-I shows or hides it; selecting a procedural
/// asset's copy shows it, unless it was closed. Like the other panels it never takes the keyboard from the main
/// window but for its fields.
final class ObjectInspectorPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let model: ObjectInspectorModel
    private static let visibleKey = "objectInspector.visible"
    private var placed: Bool
    private weak var window: NSWindow?

    /// Shown at the last launch; nil: never shown or closed (it shows itself for a procedural asset).
    static var wasVisible: Bool? { UserDefaults.standard.object(forKey: visibleKey) as? Bool }

    init(host: ObjectInspectorHost, editAsset: @escaping (String) -> Void) {
        model = ObjectInspectorModel(host: host)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Object"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.setFrameAutosaveName("ObjectInspector")
        placed = UserDefaults.standard.object(forKey: "NSWindow Frame ObjectInspector") != nil
        super.init()
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ObjectInspectorView(model: model, editAsset: editAsset))
        model.onSelect = { [weak self] p in
            guard let self, let window = self.window, !self.panel.isVisible, p.object.asset.hasPrefix("proc:"),
                  ObjectInspectorPanel.wasVisible != false else { return }
            self.show(nextTo: window)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// The main window it opens beside (for showing itself when a procedural asset is selected).
    func attach(to window: NSWindow) { self.window = window }

    /// Shows the inspector at the main window's right edge, low down (Render Settings is at its top).
    func show(nextTo window: NSWindow) {
        if !placed {
            placed = true
            let frame = window.frame, size = panel.frame.size
            let visible = window.screen?.visibleFrame ?? frame
            var origin = NSPoint(x: frame.maxX + 8, y: frame.minY)
            if origin.x + size.width > visible.maxX { origin.x = frame.maxX - size.width - 12; origin.y += 12 }
            origin.y = max(origin.y, visible.minY)
            panel.setFrameOrigin(origin)
        }
        panel.orderFront(nil)
        UserDefaults.standard.set(true, forKey: ObjectInspectorPanel.visibleKey)
    }

    func toggle(nextTo window: NSWindow) {
        if panel.isVisible {
            panel.orderOut(nil)
            UserDefaults.standard.set(false, forKey: ObjectInspectorPanel.visibleKey)
        } else {
            show(nextTo: window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: ObjectInspectorPanel.visibleKey)
    }
}
