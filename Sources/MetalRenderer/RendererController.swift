import AppKit

/// What the renderer reports on its stats tick, twice a second, besides the settings.
struct RendererStatus {
    /// This frame's direct-light method with Auto resolved, for the settings panel's denoiser caption.
    var directMode: DirectLightMode
    /// The ray queries' counters are compiled in (RT_STATS).
    var traversalCounters: Bool
    /// What the Debug window shows; only while it is open (`RendererController.debugActive`).
    var debugInfo: DebugInfo?
    /// The GPU pass timings averaged since the last tick, if passes are being profiled.
    var passTimes: [(name: String, ms: Double)]?
}

/// The main thread's side of the renderer. The window's input, the menus and the panels talk to this, never to the
/// `Renderer`, which belongs to the render thread: edits go to it as work (`Renderer.perform`), and its settings and
/// stats come back as values. So the main thread never waits for a frame. Main thread only.
final class RendererController: InputHandler {
    private let renderer: Renderer

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
    init(renderer: Renderer) {
        self.renderer = renderer
        settings = renderer.settings
        defaultSettings = renderer.defaultSettings
        upscaleSteps = renderer.upscaleSteps
        passProfilingSupported = renderer.passProfilingSupported
        traversalCounters = renderer.traversalCounters
        renderer.onSettings = { [weak self] settings, update, persist in
            DispatchQueue.main.async { self?.received(settings, update: update, persist: persist) }
        }
        renderer.onTick = { [weak self] status in
            DispatchQueue.main.async { self?.ticked(status) }
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
        traversalCounters = s.traversalCounters
        for observer in tickObservers { observer() }
        if let times = s.passTimes { onPassTimes?(times) }
    }

    // MARK: - Work for the renderer

    /// Adds glTF models in front of the camera, or an HDR image as the sky (Renderer.addModels).
    func addModels(_ urls: [URL]) { renderer.perform { $0.addModels(urls) } }

    /// Turns the traversal counters on or off: that recompiles the shaders, in the background; `done` when ready.
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
        // The panels' keys work here, so they answer however slow the frames are.
        if key == "\t" || key == "i" {
            if !event.isARepeat { (key == "\t" ? onTogglePanel : onToggleDebug)?() }
            return
        }
        let isRepeat = event.isARepeat
        renderer.perform { $0.keyDown(key, isRepeat: isRepeat) }
    }

    func keyUp(_ event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        renderer.perform { $0.keyUp(key) }
    }

    func flagsChanged(_ event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        renderer.perform { $0.setShift(shift) }
    }

    func mouseDown(at cursor: SIMD2<Float>) {
        renderer.perform { $0.mouseDown(at: cursor) }
    }

    func mouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>) {
        renderer.perform { $0.mouseDragged(dx: dx, dy: dy, at: cursor) }
    }

    func mouseUp() {
        renderer.perform { $0.mouseUp() }
    }

    func scrolled(dy: Float) {
        renderer.perform { $0.scrolled(dy: dy) }
    }
}
