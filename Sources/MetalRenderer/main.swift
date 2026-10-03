import AppKit
import MetalKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var renderer: Renderer!
    private var settingsPanel: SettingsPanel?
    private var debugPanel: DebugPanel?
    private var offscreen: OffscreenSurface?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }
        guard device.supportsRaytracing else {
            fatalError("This GPU does not support Metal ray tracing")
        }
        print("GPU: \(device.name)")

        if Headless.isEnabled {
            // No window, no menu, no panels: the benchmark draws into offscreen textures and quits when done.
            let surface = OffscreenSurface(device: device)
            offscreen = surface
            do {
                renderer = try Renderer(device: device, surface: surface)
            } catch {
                fatalError("Renderer failed to start:\n\(error)")
            }
            return
        }

        buildMenu()

        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "MetalRenderer"
        window.center()

        // The window first, the renderer on the next turn of the run loop: its start (the scene, the textures) then
        // happens with the window on screen.
        let view = RenderView(frame: rect, device: device)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        Launch.mark("window")
        DispatchQueue.main.async { [self] in start(view) }
    }

    private func start(_ view: RenderView) {
        view.configureForRenderer()
        do {
            renderer = try Renderer(device: view.device!, surface: view)
        } catch {
            fatalError("Renderer failed to start:\n\(error)")
        }
        view.delegate = renderer
        view.inputHandler = renderer
        view.onDropModels = { [weak self] urls in self?.renderer.addModels(urls) }

        if !Benchmark.isEnabled {
            // The panels after the first frame: laying out the settings panel takes about 0.35 s of the main thread,
            // which would otherwise come before it. (And after three seconds without one, so they are there when the
            // shaders failed to compile.)
            renderer.onFirstFrame = { [weak self] in self?.showPanels() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showPanels() }
        }

        print("""
        MetalRenderer controls
          Drag mouse   look around          W A S D / Q E   move (hold Shift = faster)
          Space        pause animation      G               toggle global illumination
          B            toggle blue-noise sampling   M   GI method: path traced, radiance cascades, ReSTIR GI
          N            toggle denoiser      [ / ]           fewer / more GI bounces (path traced, ReSTIR GI)
          - / =        lower / raise render resolution   U   MetalFX upscaling: off, 1.5x, 2x, 3x
          1-6          view: final, raw direct, raw indirect, normals, albedo, history length
          R            hot-reload the shaders (edit Shaders/*.metal while the app runs)
          Tab / Cmd-,  show or hide the Render Settings panel
          I / Cmd-I    show or hide the Debug window (frame graph, pass timings, virtual geometry, ...)
          Cmd-O        add glTF models (.glb / .gltf) in front of the camera, or an HDR sky (.hdr / .exr); or drop them
        """)
    }

    private func showPanels() {
        guard settingsPanel == nil else { return }
        let panel = SettingsPanel(renderer: renderer)
        panel.show(nextTo: window)
        settingsPanel = panel
        renderer.onTogglePanel = { [weak self] in self?.toggleSettings(nil) }
        debugPanel = DebugPanel(renderer: renderer)
        if DebugPanel.wasVisible { debugPanel?.show(nextTo: window, below: panel.panel) }
        renderer.onToggleDebug = { [weak self] in self?.toggleDebug(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { SettingsStore.flush() }

    /// File > Open…: glTF models, placed in front of the camera, or an HDR environment image for the sky.
    @objc private func openModels(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RenderView.modelTypes
        panel.allowsMultipleSelection = true
        panel.directoryURL = Scene.assetsDirectory
        panel.message = "Choose glTF models (.glb or .gltf) to add to the scene, or an HDR image (.hdr or .exr) for the sky"
        guard panel.runModal() == .OK else { return }
        renderer.addModels(panel.urls)
    }

    @objc private func toggleSettings(_ sender: Any?) {
        settingsPanel?.toggle(nextTo: window)
    }

    @objc private func toggleDebug(_ sender: Any?) {
        debugPanel?.toggle(nextTo: window, below: settingsPanel?.panel)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Render Settings…", action: #selector(toggleSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Debug Window", action: #selector(toggleDebug(_:)), keyEquivalent: "i").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MetalRenderer",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openModels(_:)), keyEquivalent: "o").target = self
        fileItem.submenu = fileMenu
        NSApp.mainMenu = mainMenu
    }
}

/// `METALRENDERER_VG_TEST=<model.glb>`: builds the model's virtual geometry, checks the DAG, round-trips the cache file
/// and exits (no window).
if let path = ProcessInfo.processInfo.environment["METALRENDERER_VG_TEST"] {
    let url = URL(fileURLWithPath: path)
    do {
        let model = try GLTFLoader.load(url)
        var built: [(index: Int, mesh: VirtualMesh)] = []
        for (i, m) in model.meshes.enumerated() where m.indices.count / 3 >= (Int(ProcessInfo.processInfo.environment["METALRENDERER_VG_MIN"] ?? "") ?? VirtualGeometryBuilder.minTriangles) {
            let mesh = VirtualGeometryBuilder.build(positions: m.positions, normals: m.normals, uvs: m.uvs, indices: m.indices,
                                                    name: "\(model.name)#\(i)")
            let problems = VirtualGeometryBuilder.check(mesh)
            print(problems.isEmpty ? "  DAG check: ok" : "  DAG check: \(problems.count) problems\n    " + problems.joined(separator: "\n    "))
            let levels = Dictionary(grouping: mesh.clusters, by: { mesh.groups[Int($0.group)].level })
            for l in levels.keys.sorted() {
                let cs = levels[l]!
                print(String(format: "    level %2d: %6d clusters, %8d triangles, error %.5f", l, cs.count,
                             cs.reduce(0) { $0 + Int($1.triangles) }, cs.map(\.lo.w).max() ?? 0))
            }
            built.append((i, mesh))
        }
        let cache = VirtualGeometryBuilder.cacheURL(for: url)
        try VirtualGeometryBuilder.write(built, to: cache)
        let back = try VirtualGeometryBuilder.read(cache)
        for (i, m) in built {
            let r = back[i]!
            let same = r.clusters.count == m.clusters.count && r.groups.count == m.groups.count && r.pageData == m.pageData
            print("  cache round trip mesh \(i): \(same ? "ok" : "MISMATCH") (\(cache.lastPathComponent))")
        }
    } catch {
        print("VG test failed: \(error)")
    }
    exit(0)
}

setlinebuf(stdout)   // whole lines also into a pipe or a file: a log is complete when the app is stopped
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Headless: no Dock icon, and the app never becomes active, so the focus stays where it was.
app.setActivationPolicy(Headless.isEnabled ? .prohibited : .regular)
app.run()
