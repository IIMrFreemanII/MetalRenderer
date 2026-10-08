import AppKit
import SwiftUI

/// The plant editor's floating panel (PlantEditorView in an NSPanel), beside the main window like Render Settings.
/// It answers Cmd-Z / Shift-Cmd-Z with the editor's undo while it, or the main window, is key.
final class PlantEditorPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let model: PlantEditorModel
    private static let visibleKey = "plantEditor.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(controller: RendererController) {
        model = PlantEditorModel(controller: controller)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 760),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Plant Editor"
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true   // sliders don't need key status; the name field does
        panel.hidesOnDeactivate = true
        panel.setFrameAutosaveName("PlantEditor")
        panel.contentView = NSHostingView(rootView: PlantEditorView().environmentObject(model))
        controller.onCompare = { [weak self] on in self?.model.compare(on) }
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel to the left of `window` (Render Settings is on its right), or inside it if there is no room.
    func show(nextTo window: NSWindow) {
        if !panel.setFrameUsingName("PlantEditor") {
            let frame = window.frame, size = panel.frame.size
            let visible = window.screen?.visibleFrame ?? frame
            var origin = NSPoint(x: frame.minX - size.width - 8, y: frame.maxY - size.height)
            if origin.x < visible.minX { origin.x = frame.minX + 12; origin.y -= 28 }
            origin.y = max(origin.y, visible.minY)
            panel.setFrameOrigin(origin)
        }
        panel.orderFront(nil)
        UserDefaults.standard.set(true, forKey: PlantEditorPanel.visibleKey)
    }

    func toggle(nextTo window: NSWindow) {
        if panel.isVisible { panel.orderOut(nil); UserDefaults.standard.set(false, forKey: PlantEditorPanel.visibleKey) }
        else { show(nextTo: window) }
    }

    func windowWillClose(_ notification: Notification) { UserDefaults.standard.set(false, forKey: PlantEditorPanel.visibleKey) }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
