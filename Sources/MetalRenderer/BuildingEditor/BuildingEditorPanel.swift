import AppKit
import SwiftUI

/// The building editor's floating panels: the editor (BuildingEditorView) beside the main window, and its Floor Plan
/// window (FloorPlanView). Both answer Cmd-Z / Shift-Cmd-Z with the editor's undo; neither takes the keyboard from
/// the main window (W A S D walk there).
final class BuildingEditorPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let planPanel: NSPanel
    let model: BuildingEditorModel
    private static let visibleKey = "buildingEditor.visible", planKey = "buildingPlan.visible"
    /// Whether each has a place of its own yet (a frame saved by an earlier run, or placed in this one): naming a
    /// window's autosave saves its frame at once, so `setFrameUsingName` can't tell.
    private var panelPlaced: Bool, planPlaced: Bool

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(controller: RendererController) {
        model = BuildingEditorModel(controller: controller)
        func make(_ title: String, _ size: NSSize, _ name: String) -> NSPanel {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = title
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = true
            p.setFrameAutosaveName(name)
            return p
        }
        func saved(_ name: String) -> Bool { UserDefaults.standard.object(forKey: "NSWindow Frame \(name)") != nil }
        (panelPlaced, planPlaced) = (saved("BuildingEditor"), saved("BuildingFloorPlan"))
        panel = make("Building Editor", NSSize(width: 450, height: 780), "BuildingEditor")
        planPanel = make("Floor Plan", NSSize(width: 520, height: 520), "BuildingFloorPlan")
        super.init()
        panel.delegate = self
        planPanel.delegate = self
        let drag = EditorDrag(begin: model.beginDrag, end: model.endDrag)
        panel.contentView = NSHostingView(rootView: BuildingEditorView(showPlan: { [weak self] in self?.showPlan() })
            .environmentObject(model).environment(\.editorDrag, drag))
        planPanel.contentView = NSHostingView(rootView: FloorPlanView().environmentObject(model).environment(\.editorDrag, drag))
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the editor to the left of `window` (Render Settings is on its right), or inside it if there is no room.
    func show(nextTo window: NSWindow) {
        if !panelPlaced {
            panelPlaced = true
            let frame = window.frame, size = panel.frame.size
            let visible = window.screen?.visibleFrame ?? frame
            var origin = NSPoint(x: frame.minX - size.width - 8, y: frame.maxY - size.height)
            if origin.x < visible.minX { origin.x = frame.minX + 12; origin.y -= 28 }
            origin.y = max(origin.y, visible.minY)
            panel.setFrameOrigin(origin)
        }
        panel.orderFront(nil)
        UserDefaults.standard.set(true, forKey: BuildingEditorPanel.visibleKey)
        if UserDefaults.standard.bool(forKey: BuildingEditorPanel.planKey) { showPlan() }
    }

    /// The Floor Plan window (or where it was): under the editor, or else beside it, wherever the screen has room for
    /// it clear of the editor (over the editor's buttons, it would take their clicks).
    func showPlan() {
        if !planPlaced {
            planPlaced = true
            let f = panel.frame, size = planPanel.frame.size
            let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? f
            let candidates = [NSPoint(x: f.minX, y: f.minY - size.height - 8),
                              NSPoint(x: f.maxX + 8, y: f.maxY - size.height),
                              NSPoint(x: f.minX - size.width - 8, y: f.maxY - size.height)]
            let fits = candidates.first { visible.contains(NSRect(origin: $0, size: size)) }
            planPanel.setFrameOrigin(fits ?? NSPoint(x: min(f.maxX + 8, visible.maxX - size.width), y: max(f.maxY - size.height, visible.minY)))
        }
        planPanel.orderFront(nil)
        UserDefaults.standard.set(true, forKey: BuildingEditorPanel.planKey)
    }

    func toggle(nextTo window: NSWindow) {
        if panel.isVisible {
            panel.orderOut(nil)
            planPanel.orderOut(nil)
            UserDefaults.standard.set(false, forKey: BuildingEditorPanel.visibleKey)
        } else {
            show(nextTo: window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSPanel) === planPanel {
            UserDefaults.standard.set(false, forKey: BuildingEditorPanel.planKey)
        } else {
            UserDefaults.standard.set(false, forKey: BuildingEditorPanel.visibleKey)
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
