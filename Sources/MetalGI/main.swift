import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var renderer: Renderer!
    private var settingsPanel: SettingsPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }
        guard device.supportsRaytracing else {
            fatalError("This GPU does not support Metal ray tracing")
        }
        print("GPU: \(device.name)")

        buildMenu()

        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "MetalGI"
        window.center()

        let view = RenderView(frame: rect, device: device)
        do {
            renderer = try Renderer(view: view)
        } catch {
            fatalError("Renderer failed to start:\n\(error)")
        }
        view.delegate = renderer
        view.inputHandler = renderer

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        if !Benchmark.isEnabled {
            let panel = SettingsPanel(renderer: renderer)
            panel.show(nextTo: window)
            settingsPanel = panel
            renderer.onTogglePanel = { [weak self] in self?.toggleSettings(nil) }
        }

        print("""
        MetalGI controls
          Drag mouse   look around          W A S D / Q E   move (hold Shift = faster)
          Space        pause animation      G               toggle global illumination
          B            toggle blue-noise sampling   M   GI method: path traced, surfels, radiance cascades
          N            toggle denoiser      [ / ]           fewer / more GI bounces
          - / =        lower / raise render resolution   U   MetalFX upscaling: off, 1.5x, 2x, 3x
          1-6          view: final, raw direct, raw indirect, normals, albedo, history length
          R            hot-reload Shaders.metal (edit it while the app runs)
          Tab / Cmd-,  show or hide the Render Settings panel
        """)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func toggleSettings(_ sender: Any?) {
        settingsPanel?.toggle(nextTo: window)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Render Settings…", action: #selector(toggleSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MetalGI",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
