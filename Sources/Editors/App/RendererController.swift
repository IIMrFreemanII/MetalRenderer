import AppKit
import Characters
import EngineCore
import Metal
import MetalRenderer
import Physics
import Plants

/// The main thread's side of the renderer. The window's input, the menus and the panels talk to this, never to the
/// `Renderer`, which belongs to the render thread: edits go to it as work (`Renderer.perform`), and its settings and
/// stats come back as values. So the main thread never waits for a frame. Main thread only.
final class RendererController: InputHandler {
    private let renderer: Renderer
    /// The window's view (a scene's HUD captures the mouse in it: the demolition's).
    weak var renderView: RenderView?

    /// The settings as the renderer last reported them, with the edits sent since then applied on top.
    private(set) var settings: RenderSettings
    /// What "Reset to Defaults" restores (differs from RenderSettings() on GPUs without MetalFX).
    let defaultSettings: RenderSettings
    /// MetalFX factors this GPU supports, with 0 meaning off.
    let upscaleSteps: [CGFloat]
    let passProfilingSupported: Bool
    /// The last stats tick's report; nil before the first.
    private(set) var status: RendererStatus?
    /// The ray queries' counters (RT_STATS) are on.
    private(set) var traversalCounters: Bool
    private var sentUpdate = 0                  // the number of the last settings edit sent to the renderer

    private var settingsObservers: [(RenderSettings) -> Void] = []
    private var tickObservers: [() -> Void] = []
    var onPassTimes: (([(name: String, ms: Double)]) -> Void)?
    /// Every frame once its GPU work is done, while `debugActive`: the CPU time since the previous frame started and
    /// the GPU time, both in ms.
    var onFrameTime: ((_ cpuMs: Double, _ gpuMs: Double) -> Void)?
    /// Called once, when the first frame has been drawn.
    var onFirstFrame: (() -> Void)?
    var onTogglePanel: (() -> Void)?            // Tab key
    var onToggleDebug: (() -> Void)?            // I key
    var onToggleLoading: (() -> Void)?          // P key
    var onTogglePlants: (() -> Void)?           // K key
    var onToggleVFX: (() -> Void)?              // X key
    var onToggleBuildings: (() -> Void)?        // J key
    var onToggleCharacters: (() -> Void)?       // H key
    var onToggleMaterials: (() -> Void)?        // O key
    var onTogglePainter: (() -> Void)?          // V key (Shift-V walks)
    var onToggleProjectGraph: (() -> Void)?     // Y key
    var onToggleDayBar: (() -> Void)?           // Z key
    /// The time on the scene's day clock as the day runs (the day bar).
    var onDayTime: ((Float) -> Void)?
    /// The last scene's outline (the Project Graph's), and who wants them.
    private(set) var lastOutline: SceneOutline?
    private var outlineObservers: [(SceneOutline) -> Void] = []
    /// The painter's status as the renderer last sent it, and who wants it.
    private(set) var painterStatus = PainterStatus()
    private var painterObservers: [(PainterStatus) -> Void] = []
    /// The Terrain Editor's status as the renderer last sent it, and who wants it.
    private(set) var terrainStatus = TerrainStatus()
    private var terrainObservers: [(TerrainStatus) -> Void] = []
    var onToggleTerrain: (() -> Void)?          // Shift-T
    var onToggleFracture: (() -> Void)?         // Shift-F
    /// An armed pick's answer (the Material Designer's).
    var onMaterialPicked: ((MaterialPick?) -> Void)?
    /// Who wants to know what a click in the view selected (its instance; nil: nothing).
    private var viewSelectionObservers: [(Int?) -> Void] = []
    /// The camera's yaw and pitch as they change (the scene gizmo).
    var onCameraTurned: ((_ yaw: Float, _ pitch: Float) -> Void)?
    /// C held down (true) and let go (false) in the plant workshop: the saved plant in place of the edited one.
    var onCompare: ((Bool) -> Void)?
    /// ...and in the character workshop: the saved character.
    var onCompareCharacter: ((Bool) -> Void)?
    /// What loads in the background, for the loading overlay (thread-safe, so the main thread reads it directly).
    let loadActivity: LoadActivity

    /// The Debug window is open: the stats tick brings `debugInfo`, and every frame `onFrameTime`.
    var debugActive = false {
        didSet { let on = debugActive; renderer.perform { $0.debugActive = on } }
    }
    /// GPU pass timings (`onPassTimes`).
    var profilePasses = false {
        didSet { let on = profilePasses; renderer.perform { $0.profilePasses = on } }
    }
    /// What the Debug window shows, as of the last stats tick.
    var debugInfo: DebugInfo { status?.debugInfo ?? DebugInfo() }

    /// Takes `renderer` before its render thread starts: reads what doesn't change and sets its callbacks.
    package init(renderer: Renderer) {
        self.renderer = renderer
        settings = renderer.settings
        defaultSettings = renderer.defaultSettings
        upscaleSteps = renderer.upscaleSteps
        passProfilingSupported = renderer.passProfilingSupported
        traversalCounters = renderer.traversalCounters
        loadActivity = renderer.loadActivity
        renderer.onSettings = { [weak self] settings, update, persist in
            DispatchQueue.main.async { self?.received(settings, update: update, persist: persist) }
        }
        renderer.onTick = { [weak self] status in
            DispatchQueue.main.async { self?.ticked(status) }
        }
        renderer.onPainter = { [weak self] status in self?.painterChanged(status) }
        renderer.onTerrain = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.terrainStatus = status
                for o in self.terrainObservers { o(status) }
            }
        }
        renderer.onOutline = { [weak self] outline in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastOutline = outline
                for o in self.outlineObservers { o(outline) }
            }
        }
        renderer.onSelectedInView = { [weak self] instance in
            DispatchQueue.main.async {
                guard let self else { return }
                for o in self.viewSelectionObservers { o(instance) }
            }
        }
        renderer.onCameraTurned = { [weak self] yaw, pitch in
            DispatchQueue.main.async { self?.onCameraTurned?(yaw, pitch) }
        }
        renderer.onDayTime = { [weak self] t in
            DispatchQueue.main.async { self?.onDayTime?(t) }
        }
        renderer.onGizmoMoved = { [weak self] effect, emitter, delta, phase in
            DispatchQueue.main.async { self?.onGizmoMoved?(effect, emitter, delta, phase) }
        }
        renderer.onFrameTime = { [weak self] cpu, gpu in
            DispatchQueue.main.async { self?.onFrameTime?(cpu, gpu) }
        }
        renderer.onFirstFrame = { [weak self] in
            DispatchQueue.main.async {
                let first = self?.onFirstFrame
                self?.onFirstFrame = nil
                first?()
            }
        }
    }

    // MARK: - Settings

    /// Calls `observer` with the settings after every change (panel edits, keyboard shortcuts, scene loads).
    func observeSettings(_ observer: @escaping (RenderSettings) -> Void) { settingsObservers.append(observer) }
    /// Calls `observer` twice a second, when the stats are refreshed (`status`).
    func observeTick(_ observer: @escaping () -> Void) { tickObservers.append(observer) }

    /// Edits the settings: here at once, and in the renderer before its next frame. An edit, not the edited value, goes
    /// to the renderer, so it doesn't undo what the renderer changed meanwhile (the open world's tile, fallbacks).
    /// `change` runs on the render thread too: it must take what it needs from the controls before, not read them.
    func update(_ change: @escaping (inout RenderSettings) -> Void) {
        let before = settings
        change(&settings)
        sentUpdate += 1
        let update = sentUpdate
        renderer.perform { $0.applySettings(update: update, change) }
        if settings != before { notifySettings() }
    }

    private func received(_ s: RenderSettings, update: Int, persist: Bool) {
        // Sent before the renderer had the latest edits: the settings here have them already (a slider being dragged
        // would jump back). The renderer reports again once it has them.
        guard update >= sentUpdate else { return }
        if persist { SettingsStore.save(s) }
        guard s != settings else { return }
        settings = s
        notifySettings()
    }

    private func notifySettings() {
        for observer in settingsObservers { observer(settings) }
    }

    private func ticked(_ s: RendererStatus) {
        status = s
        // Another scene, a tool that leaves the cursor free, or the window in the background: the mouse let go.
        if s.hud?.capturesMouse != true || !(NSApp.isActive && renderView?.window?.isKeyWindow == true) { setCaptured(false) }
        traversalCounters = s.traversalCounters
        for observer in tickObservers { observer() }
        if let times = s.passTimes { onPassTimes?(times) }
    }

    // MARK: - Work for the renderer

    /// Adds glTF models in front of the camera, or an HDR image as the sky (Renderer.addModels).
    func addModels(_ urls: [URL]) { renderer.perform { $0.addModels(urls) } }

    /// Turns the traversal counters on or off: that recompiles the shaders, in the background; `done` when ready.
    /// The plant workshop's camera at its plants again (F).
    func frameWorkshop() { renderer.perform { $0.frameWorkshop() } }

    /// The scene gizmo: the view from `axis`'s side, or 45° steps on, turning about the pivot.
    func snapView(_ axis: ViewAxis) { renderer.perform { $0.snapView(axis) } }
    func stepView(yawSteps: Int, pitchSteps: Int) { renderer.perform { $0.stepView(yawSteps: yawSteps, pitchSteps: pitchSteps) } }

    /// The VFX editor's: the scene's clock at `t` (s), and what its gizmos show (nil: none).
    func setTime(_ t: Float) { renderer.perform { $0.setTime(t) } }
    func setGizmos(_ target: VFXGizmos.Target?) { renderer.perform { $0.setGizmos(target) } }
    /// A gizmo's handle dragged in the view (Renderer.onGizmoMoved), on the main thread.
    var onGizmoMoved: ((_ effect: String, _ emitter: String, _ delta: SIMD3<Float>, _ phase: Int) -> Void)?

    func setTraversalCounters(_ on: Bool, then done: @escaping () -> Void) {
        renderer.perform { [weak self] r in
            r.setTraversalCounters(on) {
                let counters = r.traversalCounters
                DispatchQueue.main.async {
                    self?.traversalCounters = counters
                    done()
                }
            }
        }
    }

    // MARK: - InputHandler

    func keyDown(_ event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        // The mouse captured (the demolition scene): Escape lets it go. (A tool that leaves the cursor free lets it go
        // at the next tick: SceneHUD.capturesMouse.)
        if renderView?.captured == true && event.keyCode == 53 { setCaptured(false); return }
        // A menu's shortcut (Cmd-Z with nothing to undo): not the plain key. Command-J copies the selected placed object,
        // Command-N puts a box in front of the camera (Renderer+Placement.swift).
        if event.modifierFlags.contains(.command) {
            if key == "j" && !event.isARepeat { renderer.perform { $0.duplicatePlaced() } }
            if key == "n" && !event.isARepeat { renderer.perform { $0.addPlaced() } }
            return
        }
        // The panels' keys work here, so they answer however slow the frames are.
        if key == "\t" || key == "i" || key == "p" || key == "k" || key == "j" || key == "h" || key == "x" || key == "o" || key == "y"
            || key == "z" {
            if !event.isARepeat {
                (key == "\t" ? onTogglePanel : key == "i" ? onToggleDebug : key == "p" ? onToggleLoading : key == "k" ? onTogglePlants
                    : key == "h" ? onToggleCharacters : key == "x" ? onToggleVFX : key == "o" ? onToggleMaterials
                    : key == "y" ? onToggleProjectGraph : key == "z" ? onToggleDayBar : onToggleBuildings)?()
            }
            return
        }
        // Shift-F: the Fracture Editor's window.
        if key == "f" && event.modifierFlags.contains(.shift) {
            if !event.isARepeat { onToggleFracture?() }
            return
        }
        // Shift-T: the Terrain Editor's window (T alone is Reference mode).
        if key == "t" && event.modifierFlags.contains(.shift) {
            if !event.isARepeat { onToggleTerrain?() }
            return
        }
        // Sculpt mode: [ ] the brush's size, { } (Shift) its strength, Escape leaves it.
        if terrainStatus.active {
            if key == "[" || key == "]" || key == "{" || key == "}" {
                let step = key == "[" || key == "{" ? -1 : 1, strength = key == "{" || key == "}"
                renderer.perform { $0.resizeTerrainBrush(step, strength: strength) }
                return
            }
            if event.keyCode == 53 {
                renderer.perform { $0.setTerrainMode(false) }
                return
            }
        }
        // V: the Material Painter's window (Shift-V walks, as V did).
        if key == "v" && !event.modifierFlags.contains(.shift) {
            if !event.isARepeat { onTogglePainter?() }
            return
        }
        // Paint mode: [ ] the brush's size, Escape leaves it.
        if painterStatus.active != nil {
            if key == "[" || key == "]" {
                let step = key == "[" ? -1 : 1
                renderer.perform { $0.resizeBrush(step) }
                return
            }
            if event.keyCode == 53 {
                renderer.perform { $0.setPaintMode(nil) }
                return
            }
        }
        if key == "c", settings.scene.kind == .plants || settings.scene.kind == .characters {
            if !event.isARepeat { (settings.scene.kind == .plants ? onCompare : onCompareCharacter)?(true) }
            return
        }
        let isRepeat = event.isARepeat
        renderer.perform { $0.keyDown(key, isRepeat: isRepeat) }
    }

    func keyUp(_ event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        if key == "c", settings.scene.kind == .plants { onCompare?(false) }
        if key == "c", settings.scene.kind == .characters { onCompareCharacter?(false) }
        renderer.perform { $0.keyUp(key) }
    }

    func flagsChanged(_ event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift), control = event.modifierFlags.contains(.control)
        let option = event.modifierFlags.contains(.option), command = event.modifierFlags.contains(.command)
        renderer.perform { $0.setShift(shift); $0.setControl(control); $0.setOption(option); $0.setCommand(command) }
    }

    func mouseDown(at cursor: SIMD2<Float>) {
        // A scene whose HUD captures the mouse (the demolition): the first click takes it (and doesn't fire).
        if status?.hud?.capturesMouse == true && !(renderView?.captured ?? true) {
            setCaptured(true)
            return
        }
        renderer.perform { $0.mouseDown(at: cursor) }
    }

    /// The mouse captured for the scene's aim, or let go (the window's view and the scene's behaviour both told).
    func setCaptured(_ on: Bool) {
        guard let view = renderView, view.captured != on else { return }
        view.captured = on
        renderer.perform { r in r.scene.behaviour?.captured = on }
    }

    func mouseLook(dx: Float, dy: Float) { renderer.perform { r in r.scene.behaviour?.look(r, dx: dx, dy: dy) } }

    func mouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>) {
        renderer.perform { $0.mouseDragged(dx: dx, dy: dy, at: cursor) }
    }

    func mouseUp() {
        renderer.perform { $0.mouseUp() }
    }

    func scrolled(dy: Float) {
        renderer.perform { $0.scrolled(dy: dy) }
    }

    func rightMouseDown(at cursor: SIMD2<Float>) { renderer.perform { $0.rightMouseDown(at: cursor) } }
    func rightMouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>) { renderer.perform { $0.rightMouseDragged(dx: dx, dy: dy, at: cursor) } }
    func rightMouseUp() { renderer.perform { $0.rightMouseUp() } }
    func otherMouseDown(at cursor: SIMD2<Float>) { renderer.perform { $0.otherMouseDown(at: cursor) } }
    func otherMouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>) { renderer.perform { $0.otherMouseDragged(dx: dx, dy: dy, at: cursor) } }
    func mouseMoved(at cursor: SIMD2<Float>) {
        if painterStatus.active != nil { renderer.perform { $0.paintMouseMoved(at: cursor) } }
        if terrainStatus.active { renderer.perform { $0.terrainMouseMoved(at: cursor) } }
    }
    func pressure(_ p: Float) { renderer.perform { $0.penPressure = p } }
}

extension RendererController: PainterHost {
    func observePainter(_ observer: @escaping (PainterStatus) -> Void) {
        painterObservers.append(observer)
        observer(painterStatus)
    }

    func painter(_ work: @escaping (Renderer) -> Void) { renderer.perform(work) }

    func paintInfo(_ instance: Int, _ answer: @escaping (String?) -> Void) {
        renderer.perform { r in
            let s = r.scene
            let fingerprint = s.paintable(instance) ? s.paintFingerprint(instance) : nil
            DispatchQueue.main.async { answer(fingerprint) }
        }
    }

    /// From the render thread: the painter's status changed.
    func painterChanged(_ s: PainterStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.painterStatus = s
            for o in self.painterObservers { o(s) }
        }
    }
}

extension RendererController: TerrainHost {
    /// Calls `observer` with the Terrain Editor's status now and whenever it changes.
    func observeTerrain(_ observer: @escaping (TerrainStatus) -> Void) {
        terrainObservers.append(observer)
        observer(terrainStatus)
    }

    /// Work for the renderer's terrain side, on the render thread.
    func terrain(_ work: @escaping (Renderer) -> Void) { renderer.perform(work) }
}

extension RendererController: ProjectGraphHost {
    func observeOutline(_ observer: @escaping (SceneOutline) -> Void) {
        outlineObservers.append(observer)
        if let lastOutline { observer(lastOutline) }
    }

    func frame(_ target: FrameTarget) { renderer.perform { $0.frame(target) } }

    func select(_ target: FrameTarget?) { renderer.perform { $0.select(target) } }

    func observeViewportSelection(_ observer: @escaping (Int?) -> Void) { viewSelectionObservers.append(observer) }
}

extension RendererController: MaterialEditorHost {
    var metalDevice: MTLDevice? { renderer.metalDevice }
    var displacementSummary: String? { status?.displacement }

    /// Click-to-pick: the next click in the view (not a drag) names the material there.
    func pickMaterial(_ picked: @escaping (MaterialPick?) -> Void) {
        onMaterialPicked = picked
        renderer.perform { [weak self] r in
            r.onMaterialPicked = { p in self?.materialPicked(p) }
            r.armPick()
        }
    }

    func cancelPick() {
        onMaterialPicked?(nil)
        onMaterialPicked = nil
        renderer.perform { $0.disarmPick() }
    }

    /// From the render thread: what a pick found.
    func materialPicked(_ p: MaterialPick?) {
        DispatchQueue.main.async { [weak self] in
            self?.onMaterialPicked?(p)
            self?.onMaterialPicked = nil
        }
    }
}
