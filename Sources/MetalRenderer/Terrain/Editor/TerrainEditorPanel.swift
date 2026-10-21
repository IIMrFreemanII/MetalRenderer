import AppKit
import SwiftUI

/// The Terrain Editor's window (TerrainView), beside the main one: Shift-T or Shift-Cmd-T. Tab in it toggles sculpt
/// mode; Cmd-Z undoes its strokes and document edits; Cmd-S saves the terrain.
final class TerrainEditorPanel: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: TerrainModel
    private static let visibleKey = "terrainEditor.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    package init(host: TerrainHost) {
        model = TerrainModel(host: host)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Terrain Editor"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("TerrainEditor")
        window.contentView = NSHostingView(rootView: TerrainView().environmentObject(model))
    }

    var isVisible: Bool { window.isVisible }

    func show(nextTo main: NSWindow) {
        if !window.setFrameUsingName("TerrainEditor") {
            let visible = main.screen?.visibleFrame ?? main.frame
            window.setFrameOrigin(NSPoint(x: max(main.frame.minX - 100, visible.minX), y: max(main.frame.minY - 140, visible.minY)))
        }
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: TerrainEditorPanel.visibleKey)
        model.refreshMap()
    }

    func toggle(nextTo main: NSWindow) {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: TerrainEditorPanel.visibleKey)
        } else {
            show(nextTo: main)
        }
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: TerrainEditorPanel.visibleKey)
        model.setSculpting(false)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
