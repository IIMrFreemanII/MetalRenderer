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
    private static let leastWidth: CGFloat = 820        // (what the workshop bar's rows and a usable inspector need)
    private var compareKeys: Any?
    private var comparing = false
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
        // Hold C here as in the main window, wherever the keys are, but in a text field.
        compareKeys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self.panel, event.charactersIgnoringModifiers?.lowercased() == "c",
                  !event.modifierFlags.contains(.command), !(self.panel.firstResponder is NSText) else { return event }
            if !event.isARepeat {
                self.comparing = event.type == .keyDown
                self.model.compare(self.comparing)
            }
            return nil
        }
    }

    deinit { compareKeys.map(NSEvent.removeMonitor) }

    var isVisible: Bool { panel.isVisible }

    /// Shows the window to the left of `window` the first time, or at the screen's left where there's no room, narrower
    /// if it must be to stay clear of the floating panels on the right (Render Settings), which would cover its inspector.
    func show(nextTo window: NSWindow) {
        if !panel.setFrameUsingName(PlantEditorPanel.frameName) {
            let frame = window.frame, visible = window.screen?.visibleFrame ?? frame
            var size = panel.frame.size
            var origin = NSPoint(x: frame.minX - size.width - 8, y: frame.maxY - size.height)
            if origin.x < visible.minX {
                let panels = NSApp.windows.filter { ($0 as? NSPanel)?.isFloatingPanel == true && $0.isVisible }.map(\.frame.minX)
                origin.x = visible.minX
                size.width = max(min(size.width, (panels.min() ?? visible.maxX) - 8 - origin.x), PlantEditorPanel.leastWidth)
            }
            origin.y = max(origin.y, visible.minY)
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        model.frameAll(in: model.canvasSize)
        UserDefaults.standard.set(true, forKey: PlantEditorPanel.visibleKey)
    }

    func toggle(nextTo window: NSWindow) {
        if panel.isVisible { panel.orderOut(nil); UserDefaults.standard.set(false, forKey: PlantEditorPanel.visibleKey) }
        else { show(nextTo: window) }
    }

    func windowWillClose(_ notification: Notification) { UserDefaults.standard.set(false, forKey: PlantEditorPanel.visibleKey) }

    /// (C's key-up won't come here now.)
    func windowDidResignKey(_ notification: Notification) {
        if comparing {
            comparing = false
            model.compare(false)
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
