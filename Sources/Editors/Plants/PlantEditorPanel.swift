import AppKit
import Buildings
import Characters
import Effects
import EngineCore
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants
import SwiftUI

/// The plant editor's window (PlantEditorView), beside the main one. It takes the keys when clicked: Delete removes the
/// selected nodes, Tab adds one, F frames the graph, L lays it out, Cmd-C / Cmd-V copy and paste nodes, and it answers
/// Cmd-Z / Shift-Cmd-Z with the editor's undo.
final class PlantEditorPanel: NSObject, NSWindowDelegate {
    let panel: NSWindow
    let model: PlantEditorModel
    private static let visibleKey = "plantEditor.visible"
    private static let frameName = "PlantGraphEditor"   // (not "PlantEditor": that one's size was the slider panel's)

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    package init(controller: RendererController) {
        model = PlantEditorModel(controller: controller)
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Plant Editor"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setFrameAutosaveName(PlantEditorPanel.frameName)
        panel.contentView = NSHostingView(rootView: PlantEditorView().environmentObject(model)
            .environment(\.editorDrag, EditorDrag(begin: model.beginDrag, end: model.endDrag)))
        controller.onCompare = { [weak self] on in self?.model.compare(on) }
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel to the left of `window` (Render Settings is on its right), or inside it if there is no room.
    func show(nextTo window: NSWindow) {
        if !panel.setFrameUsingName(PlantEditorPanel.frameName) {
            let frame = window.frame, size = panel.frame.size
            let visible = window.screen?.visibleFrame ?? frame
            var origin = NSPoint(x: frame.minX - size.width - 8, y: frame.maxY - size.height)
            if origin.x < visible.minX { origin.x = frame.minX + 12; origin.y -= 28 }
            origin.y = max(origin.y, visible.minY)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [model] in model.frameAll(in: model.canvasSize) }
        UserDefaults.standard.set(true, forKey: PlantEditorPanel.visibleKey)
    }

    func toggle(nextTo window: NSWindow) {
        if panel.isVisible { panel.orderOut(nil); UserDefaults.standard.set(false, forKey: PlantEditorPanel.visibleKey) }
        else { show(nextTo: window) }
    }

    func windowWillClose(_ notification: Notification) { UserDefaults.standard.set(false, forKey: PlantEditorPanel.visibleKey) }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
