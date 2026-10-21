import AppKit
import Characters
import EngineCore
import MetalRenderer
import Physics
import Plants
import SwiftUI

/// The Project Graph's window (ProjectGraphView), beside the main one. It takes the keys when clicked: Delete hides the
/// selection (or removes a copy), Return shows it in the view, F frames the graph, Escape clears the selection,
/// Cmd-V duplicates, Cmd-Z undoes.
final class ProjectGraphPanel: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: ProjectGraphModel
    private static let visibleKey = "projectGraph.visible"

    static var wasVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    package init(host: ProjectGraphHost, openEditor: @escaping (EditorTarget) -> Void) {
        model = ProjectGraphModel(host: host)
        model.openEditor = openEditor
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Project Graph"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("ProjectGraph")
        let host = GraphHostingView(rootView: AnyView(ProjectGraphView().environmentObject(model)))
        host.model = model
        host.keys = { [weak model] event in
            guard let model else { return false }
            switch event.keyCode {
            case 36, 76:   // Return, Enter: the selection in the view
                guard let f = model.focus else { return false }
                model.showInViewport(f)
                return true
            case 49:       // Space: open or close it
                guard let f = model.focus, model.graph[f]?.kind.isBranch == true else { return false }
                model.setOpen(f, !model.isOpen(f))
                return true
            default:
                return false
            }
        }
        window.contentView = host
        model.focusCanvas = { [weak window, weak host] in
            guard let window, let host, window.firstResponder !== host else { return }
            window.makeFirstResponder(host)
        }
    }

    var isVisible: Bool { window.isVisible }

    /// Shows the window (beside the main one's right edge the first time).
    func show(nextTo main: NSWindow) {
        if !window.setFrameUsingName("ProjectGraph") {
            let visible = main.screen?.visibleFrame ?? main.frame
            window.setFrameOrigin(NSPoint(x: min(main.frame.maxX - 200, visible.maxX - window.frame.width), y: max(main.frame.minY - 120, visible.minY)))
        }
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: ProjectGraphPanel.visibleKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [model] in model.frameAll(in: model.canvasSize) }
    }

    func toggle(nextTo main: NSWindow) {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: ProjectGraphPanel.visibleKey)
        } else {
            show(nextTo: main)
        }
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: ProjectGraphPanel.visibleKey)
        model.save()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }
}
