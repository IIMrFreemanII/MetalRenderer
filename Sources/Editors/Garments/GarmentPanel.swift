import AppKit
import Garments
import Metal
import MetalRenderer
import SwiftUI

/// The Garment Designer: a window of its own beside the main one (Option-Cmd-G, or Dress in the Character Editor), with
/// its own renderer for the 3D view. Cmd-Z undoes its edits; Cmd-S saves the garment to Assets/Garments.
final class GarmentPanel: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: GarmentModel
    private let device: MTLDevice
    private static let visibleKey = "garmentDesigner.visible"

    /// Posted with a character's id (the Character Editor's Dress): the designer opens on that character.
    static let dressNotification = Notification.Name("GarmentDesigner.dress")

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    init(device: MTLDevice) {
        self.device = device
        model = GarmentModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Garment Designer"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = GarmentTheme.window
        window.minSize = NSSize(width: 1000, height: 600)
        window.setFrameAutosaveName("GarmentDesigner")
        model.makeStage = { [device] in GarmentStageRenderer(device: device) }
        window.contentView = NSHostingView(rootView: GarmentView(model: model))
    }

    var isVisible: Bool { window.isVisible }

    func show(nextTo main: NSWindow) {
        if !window.setFrameUsingName("GarmentDesigner") {
            let visible = main.screen?.visibleFrame ?? main.frame
            window.setFrame(visible.insetBy(dx: visible.width * 0.05, dy: visible.height * 0.05), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: GarmentPanel.visibleKey)
        model.startStage()
        DispatchQueue.main.async { self.model.frame() }
    }

    /// Opens on `avatar` (a character's id, from the Character Editor's Dress).
    func dress(_ avatar: String, nextTo main: NSWindow) {
        show(nextTo: main)
        model.setAvatar(avatar)
    }

    func toggle(nextTo main: NSWindow) {
        if window.isVisible && window.isKeyWindow {
            window.close()
        } else {
            show(nextTo: main)
        }
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: GarmentPanel.visibleKey)
        model.stopStage()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
