import AppKit
import SwiftUI

/// The character editor's floating panel (CharacterEditorView in an NSPanel), beside the main window like the plant
/// editor's. It answers Cmd-Z / Shift-Cmd-Z with the editor's undo while it, or the main window, is key.
final class CharacterEditorPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let model: CharacterEditorModel
    private static let visibleKey = "characterEditor.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(controller: RendererController) {
        model = CharacterEditorModel(controller: controller)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 760),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Character Editor"
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.setFrameAutosaveName("CharacterEditor")
        panel.contentView = NSHostingView(rootView: CharacterEditorView().environmentObject(model)
            .environment(\.editorDrag, EditorDrag(begin: model.beginDrag, end: model.endDrag)))
        controller.onCompareCharacter = { [weak self] on in self?.model.compare(on) }
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel to the left of `window`, or inside it if there is no room.
    func show(nextTo window: NSWindow) {
        if !panel.setFrameUsingName("CharacterEditor") {
            let frame = window.frame, size = panel.frame.size
            let visible = window.screen?.visibleFrame ?? frame
            var origin = NSPoint(x: frame.minX - size.width - 8, y: frame.maxY - size.height)
            if origin.x < visible.minX { origin.x = frame.minX + 12; origin.y -= 28 }
            origin.y = max(origin.y, visible.minY)
            panel.setFrameOrigin(origin)
        }
        panel.orderFront(nil)
        UserDefaults.standard.set(true, forKey: CharacterEditorPanel.visibleKey)
    }

    func toggle(nextTo window: NSWindow) {
        if panel.isVisible { panel.orderOut(nil); UserDefaults.standard.set(false, forKey: CharacterEditorPanel.visibleKey) }
        else { show(nextTo: window) }
    }

    func windowWillClose(_ notification: Notification) { UserDefaults.standard.set(false, forKey: CharacterEditorPanel.visibleKey) }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
