import AppKit
import Metal
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var renderer: Renderer!
    private var controller: RendererController!
    private var settingsPanel: SettingsPanel?
    private var debugPanel: DebugPanel?
    private var plantEditor: PlantEditorPanel?
    private var vfxEditor: VFXEditorPanel?
    private var materialEditor: MaterialEditorPanel?
    private var buildingEditor: BuildingEditorPanel?
    private var characterEditor: CharacterEditorPanel?
    private var loadingOverlay: LoadingOverlay?
    private var offscreen: OffscreenSurface?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }
        Capabilities.current = Capabilities(device: device)
        print("GPU: \(device.name). \(Capabilities.current.summary)")

        if Headless.isEnabled {
            // No window, no menu, no panels: the benchmark draws into offscreen textures and quits when done.
            let surface = OffscreenSurface(device: device)
            offscreen = surface
            do {
                renderer = try Renderer(device: device, surface: surface)
            } catch {
                fatalError("Renderer failed to start:\n\(error)")
            }
            renderer.startRenderThread()
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
        window.delegate = self

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
        do {
            renderer = try Renderer(device: view.device, surface: view.surface)
        } catch {
            fatalError("Renderer failed to start:\n\(error)")
        }
        // From here on the renderer belongs to the render thread: the main thread goes through the controller.
        controller = RendererController(renderer: renderer)
        view.inputHandler = controller
        view.onDropModels = { [weak self] urls in self?.controller.addModels(urls) }

        if !Benchmark.isEnabled {
            // The panels after the first frame: laying out the settings panel takes about 0.35 s of the main thread,
            // which would otherwise come before it. (And after three seconds without one, so they are there when the
            // shaders failed to compile.)
            controller.onFirstFrame = { [weak self] in self?.showPanels() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showPanels() }
            // What loads in the background (the launch's shader compile is already running).
            let overlay = LoadingOverlay(activity: controller.loadActivity)
            overlay.attach(to: view)
            loadingOverlay = overlay
            controller.onToggleLoading = { [weak self] in self?.toggleLoading(nil) }
        }
        renderer.startRenderThread()

        print("""
        MetalRenderer controls
          Drag mouse   look around          W A S D / Q E   move (hold Shift = faster)
          Space        pause animation      G               toggle global illumination
          B            toggle blue-noise sampling   M   GI method: path traced, radiance cascades, ReSTIR GI
          N            toggle denoiser      [ / ]           fewer / more GI bounces (path traced, ReSTIR GI)
          - / =        lower / raise render resolution   U   upscaling (MetalFX denoiser): off, 1.5x, 2x, 3x
          1-6          view: final, raw direct, raw indirect, normals, albedo, history length
          R            hot-reload the shaders (edit Shaders/*.metal while the app runs)
          Tab / Cmd-,  show or hide the Render Settings panel
          I / Cmd-I    show or hide the Debug window (frame graph, pass timings, virtual geometry, ...)
          P            show or hide the loading overlay (what loads in the background, and how far it is)
          K / Cmd-E    show or hide the Plant Editor (the plant workshop: drag orbits, scroll zooms, F frames, hold C compares)
          J / Cmd-B    show or hide the Building Editor and its Floor Plan window (the building workshop)
          H / Cmd-Y    show or hide the Character Editor (the character workshop: drag orbits, F frames, hold C compares)
          X / Shift-Cmd-E   show the VFX Editor (particle effects as node graphs; its window: Tab adds a node, Delete removes)
          O / Shift-Cmd-M   show the Material Designer (procedural materials as node graphs, baked on the GPU; the
                       material workshop shows them path traced; Pick gives a material in the view a graph)
          V            walk (in the building workshop, the city): W A S D, Shift runs, Space jumps, C or Control
                       crouches, E or a click opens a door or flips a switch, F the flashlight, 0-9 a lift's floor
          Cmd-O        add glTF models (.glb / .gltf) in front of the camera, or an HDR sky (.hdr / .exr); or drop them
        """)
    }

    private func showPanels() {
        guard settingsPanel == nil else { return }
        let panel = SettingsPanel(renderer: controller)
        panel.show(nextTo: window)
        settingsPanel = panel
        controller.onTogglePanel = { [weak self] in self?.toggleSettings(nil) }
        debugPanel = DebugPanel(renderer: controller)
        if DebugPanel.wasVisible { debugPanel?.show(nextTo: window, below: panel.panel) }
        controller.onToggleDebug = { [weak self] in self?.toggleDebug(nil) }
        let plants = PlantEditorPanel(controller: controller)
        plantEditor = plants
        if PlantEditorPanel.wasVisible || controller.settings.scene.kind == .plants { plants.show(nextTo: window) }
        controller.onTogglePlants = { [weak self] in self?.togglePlants(nil) }
        let buildings = BuildingEditorPanel(controller: controller)
        buildingEditor = buildings
        if BuildingEditorPanel.wasVisible || controller.settings.scene.kind == .buildings { buildings.show(nextTo: window) }
        controller.onToggleBuildings = { [weak self] in self?.toggleBuildings(nil) }
        let characters = CharacterEditorPanel(controller: controller)
        characterEditor = characters
        if CharacterEditorPanel.wasVisible || controller.settings.scene.kind == .characters { characters.show(nextTo: window) }
        controller.onToggleCharacters = { [weak self] in self?.toggleCharacters(nil) }
        let vfx = VFXEditorPanel(controller: controller)
        vfxEditor = vfx
        if VFXEditorPanel.wasVisible { vfx.show(nextTo: window) }
        controller.onToggleVFX = { [weak self] in self?.toggleVFX(nil) }
        VFXEditorScript.run(vfx, main: window)
        let materials = MaterialEditorPanel(controller: controller)
        materialEditor = materials
        if MaterialEditorPanel.wasVisible || controller.settings.scene.kind == .materials { materials.show(nextTo: window) }
        controller.onToggleMaterials = { [weak self] in self?.toggleMaterials(nil) }
        // The workshop is the editor's: entering it shows the editor.
        var kind = controller.settings.scene.kind
        controller.observeSettings { [weak self] s in
            guard let self, s.scene.kind != kind else { return }
            kind = s.scene.kind
            if kind == .plants, self.plantEditor?.isVisible == false { self.plantEditor?.show(nextTo: self.window) }
            if kind == .buildings, self.buildingEditor?.isVisible == false { self.buildingEditor?.show(nextTo: self.window) }
            if kind == .characters, self.characterEditor?.isVisible == false { self.characterEditor?.show(nextTo: self.window) }
            if kind == .materials, self.materialEditor?.isVisible == false { self.materialEditor?.show(nextTo: self.window) }
        }
    }

    /// The main window's undo is an editor's (their edits are what can be undone): the character editor's or the
    /// building editor's in its workshop or while only it is open, the VFX editor's while it is open outside the
    /// workshops, the plant editor's otherwise.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if controller.settings.scene.kind == .characters
            || (characterEditor?.isVisible == true && plantEditor?.isVisible != true && buildingEditor?.isVisible != true) {
            return characterEditor?.model.undo
        }
        let buildings = controller.settings.scene.kind == .buildings || (buildingEditor?.isVisible == true && plantEditor?.isVisible != true)
        if buildings { return buildingEditor?.model.undo }
        if controller.settings.scene.kind == .materials, let m = materialEditor { return m.model.undo }
        if let vfx = vfxEditor, vfx.isVisible, controller.settings.scene.kind != .plants { return vfx.model.undo }
        return plantEditor?.model.undo
    }

    @objc private func toggleVFX(_ sender: Any?) {
        vfxEditor?.toggle(nextTo: window)
    }

    @objc private func toggleMaterials(_ sender: Any?) {
        materialEditor?.toggle(nextTo: window)
    }

    @objc private func togglePlants(_ sender: Any?) {
        plantEditor?.toggle(nextTo: window)
    }

    @objc private func toggleBuildings(_ sender: Any?) {
        buildingEditor?.toggle(nextTo: window)
    }

    @objc private func toggleCharacters(_ sender: Any?) {
        characterEditor?.toggle(nextTo: window)
    }

    @objc private func showFloorPlan(_ sender: Any?) {
        if buildingEditor?.isVisible != true { buildingEditor?.show(nextTo: window) }
        buildingEditor?.showPlan()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        renderer?.stopRenderThread()   // no frame half encoded while the app exits
        SettingsStore.flush()
    }

    /// File > Open…: glTF models, placed in front of the camera, or an HDR environment image for the sky.
    @objc private func openModels(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RenderView.modelTypes
        panel.allowsMultipleSelection = true
        panel.directoryURL = Scene.assetsDirectory
        panel.message = "Choose glTF models (.glb or .gltf) to add to the scene, or an HDR image (.hdr or .exr) for the sky"
        guard panel.runModal() == .OK else { return }
        controller.addModels(panel.urls)
    }

    @objc private func toggleSettings(_ sender: Any?) {
        settingsPanel?.toggle(nextTo: window)
    }

    @objc private func toggleDebug(_ sender: Any?) {
        debugPanel?.toggle(nextTo: window, below: settingsPanel?.panel)
    }

    @objc private func toggleLoading(_ sender: Any?) {
        loadingOverlay?.toggle()
        loadingItem?.state = LoadingOverlay.isEnabled ? .on : .off
    }
    private var loadingItem: NSMenuItem?

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Render Settings…", action: #selector(toggleSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Debug Window", action: #selector(toggleDebug(_:)), keyEquivalent: "i").target = self
        appMenu.addItem(withTitle: "Plant Editor…", action: #selector(togglePlants(_:)), keyEquivalent: "e").target = self
        appMenu.addItem(withTitle: "Building Editor…", action: #selector(toggleBuildings(_:)), keyEquivalent: "b").target = self
        appMenu.addItem(withTitle: "Floor Plan", action: #selector(showFloorPlan(_:)), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Character Editor…", action: #selector(toggleCharacters(_:)), keyEquivalent: "y").target = self
        let vfx = appMenu.addItem(withTitle: "VFX Editor…", action: #selector(toggleVFX(_:)), keyEquivalent: "e")
        vfx.keyEquivalentModifierMask = [.command, .shift]
        vfx.target = self
        let materials = appMenu.addItem(withTitle: "Material Designer…", action: #selector(toggleMaterials(_:)), keyEquivalent: "m")
        materials.keyEquivalentModifierMask = [.command, .shift]
        materials.target = self
        if !Benchmark.isEnabled {
            let item = appMenu.addItem(withTitle: "Loading Progress (P)", action: #selector(toggleLoading(_:)), keyEquivalent: "")
            item.target = self
            item.state = LoadingOverlay.isEnabled ? .on : .off
            loadingItem = item
        }
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
        // Edit: the plant editor's undo, and the text fields' clipboard.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
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

/// `METALRENDERER_FOLIAGE_TEST=<seed>`: builds the procedural plants, times and checks them, and exits (no window).
if let seed = ProcessInfo.processInfo.environment["METALRENDERER_FOLIAGE_TEST"] {
    Foliage.runTest(seed: UInt64(seed) ?? 1)
    // `METALRENDERER_FOLIAGE_TEXTURES=<folder>`: the plants' generated textures as PNGs there.
    if let folder = ProcessInfo.processInfo.environment["METALRENDERER_FOLIAGE_TEXTURES"] {
        try? FoliageTextures.writePNGs(to: URL(fileURLWithPath: folder))
    }
    exit(0)
}

/// `METALRENDERER_WORLD_TEST=<seed>`: makes the open world's tiles around its first city, times them, and exits.
if let seed = ProcessInfo.processInfo.environment["METALRENDERER_WORLD_TEST"] {
    WorldTile.runTest(seed: UInt64(seed) ?? 1)
    exit(0)
}

setlinebuf(stdout)   // whole lines also into a pipe or a file: a log is complete when the app is stopped
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Headless: no Dock icon, and the app never becomes active, so the focus stays where it was.
app.setActivationPolicy(Headless.isEnabled ? .prohibited : .regular)
app.run()
