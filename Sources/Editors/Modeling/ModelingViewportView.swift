import AppKit
import MetalKit
import Modeling
import SwiftUI
import simd

/// The modelling window's 3D view: an MTKView drawn only when the model asks (nothing changes, nothing is drawn),
/// which turns AppKit's events into the model's input (keys through the keymap, the mouse, the trackpad, the pen).
final class ModelingViewportView: MTKView, MTKViewDelegate {
    let model: ModelingModel
    private let renderer: ViewportRenderer?
    private let scene: ViewportScene?
    private var tracking: NSTrackingArea?
    /// Frames the GPU may still be reading (the sculpt buffers alternate between two).
    private let inFlight = DispatchSemaphore(value: 2)

    init(model: ModelingModel) {
        self.model = model
        let device = model.host?.metalDevice ?? MTLCreateSystemDefaultDevice()
        renderer = device.flatMap { try? ViewportRenderer(device: $0) }
        scene = device.map { ViewportScene(device: $0) }
        super.init(frame: .zero, device: device)
        colorPixelFormat = ViewportRenderer.colorFormat
        depthStencilPixelFormat = .invalid
        sampleCount = 1
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        delegate = self
        model.renderer = renderer
        model.scene = scene
        model.needsDisplay = { [weak self] in self?.needsDisplay = true }
        model.presentMenu = { [weak self] menu, at in self?.popUp(menu, at: at) }
        model.focusViewport = { [weak self] in if let self { window?.makeFirstResponder(self) } }
        if renderer == nil { model.report("The viewport's shaders didn't compile (Sources/Modeling/Shaders/Viewport.metal)") }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard let renderer, let queue = renderer.commandQueue else { return }
        model.viewSize = SIMD2(Float(bounds.width), Float(bounds.height))
        model.pixelScale = Float(window?.backingScaleFactor ?? 2)
        guard model.viewSize.x > 0, model.viewSize.y > 0 else { return }
        inFlight.wait()
        guard let drawable = currentDrawable, let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        var f = model.frame()
        f.size = SIMD2(drawable.texture.width, drawable.texture.height)
        renderer.encode(f, target: drawable.texture, into: cb)
        cb.present(drawable)
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
    }

    // MARK: Points

    private func point(_ e: NSEvent) -> SIMD2<Float> {
        let p = convert(e.locationInWindow, from: nil)
        return SIMD2(Float(p.x), Float(bounds.height - p.y))
    }

    private func pressure(_ e: NSEvent) -> Float {
        e.subtype == .tabletPoint || e.type == .tabletPoint ? max(0.02, e.pressure) : 1
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let chord = KeyChord(event, emulateNumpad: model.emulateNumpad) else { super.keyDown(with: event); return }
        if chord.cmd && model.modal == nil, ["z", "s", "o", "n", "w", "q", "e", "i"].contains(chord.key) {
            // The menus' shortcuts (undo, save …) through the responder chain.
            if chord.key == "z" { model.perform(chord.shift ? .redo : .undo); return }
            if chord.key == "s" { model.perform(.save); return }
            super.keyDown(with: event)
            return
        }
        if !model.keyDown(chord) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Ctrl chords and Tab reach keyDown, not the menus.
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.control) || event.keyCode == 48 {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // Ctrl and Shift change a running transform at once (snapping, precision).
        if model.modal != nil { model.mouseMoved(to: model.mouse, flags: event.modifierFlags) }
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        model.mouseDown(.left, at: point(e), flags: e.modifierFlags, clickCount: e.clickCount, pressure: pressure(e))
    }
    override func mouseDragged(with e: NSEvent) { model.mouseDragged(to: point(e), flags: e.modifierFlags, pressure: pressure(e)) }
    override func mouseUp(with e: NSEvent) { model.mouseUp(.left, at: point(e), flags: e.modifierFlags) }
    override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        model.mouseDown(.right, at: point(e), flags: e.modifierFlags)
    }
    override func rightMouseDragged(with e: NSEvent) { model.mouseDragged(to: point(e), flags: e.modifierFlags) }
    override func rightMouseUp(with e: NSEvent) { model.mouseUp(.right, at: point(e), flags: e.modifierFlags) }
    override func otherMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        model.mouseDown(.middle, at: point(e), flags: e.modifierFlags)
    }
    override func otherMouseDragged(with e: NSEvent) { model.mouseDragged(to: point(e), flags: e.modifierFlags) }
    override func otherMouseUp(with e: NSEvent) { model.mouseUp(.middle, at: point(e), flags: e.modifierFlags) }
    override func mouseMoved(with e: NSEvent) { model.mouseMoved(to: point(e), flags: e.modifierFlags) }
    override func tabletPoint(with e: NSEvent) {
        if NSEvent.pressedMouseButtons & 1 != 0 { model.mouseDragged(to: point(e), flags: e.modifierFlags, pressure: pressure(e)) }
    }

    override func scrollWheel(with e: NSEvent) {
        model.mouse = point(e)
        let precise = e.hasPreciseScrollingDeltas
        if !precise && model.modal == nil && model.mode == .sculpt && e.modifierFlags.contains(.control) {
            model.perform(.brushSize(e.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1))
            return
        }
        model.scroll(dx: Float(e.scrollingDeltaX), dy: Float(e.scrollingDeltaY), precise: precise, flags: e.modifierFlags)
    }

    override func magnify(with e: NSEvent) { model.magnify(Float(e.magnification)) }

    // MARK: Menus

    private func popUp(_ m: ModelingMenu, at p: SIMD2<Float>) {
        let menu = MenuBuilder.menu(m)
        menu.popUp(positioning: nil, at: NSPoint(x: CGFloat(p.x), y: bounds.height - CGFloat(p.y)), in: self)
    }
}

/// NSMenus from ModelingMenus: each item calls its closure.
enum MenuBuilder {
    final class Target: NSObject {
        let action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func run(_ sender: Any?) { action() }
    }

    static func menu(_ m: ModelingMenu) -> NSMenu {
        let menu = NSMenu(title: m.title)
        menu.autoenablesItems = false
        let header = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in m.items {
            if item.separator { menu.addItem(.separator()); continue }
            let title = item.shortcut.isEmpty ? item.title : "\(item.title)    \(item.shortcut)"
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let sub = item.submenu {
                mi.submenu = MenuBuilder.menu(sub)
            } else if let a = item.action {
                let t = Target(a)
                mi.target = t
                mi.action = #selector(Target.run(_:))
                mi.representedObject = t   // kept alive with the item
            }
            menu.addItem(mi)
        }
        return menu
    }
}

/// The viewport in SwiftUI. For pictures of the window (the tests), a view that draws the viewport's frame as an
/// image, which AppKit's own drawing of the window then has.
struct ModelingViewport: NSViewRepresentable {
    let model: ModelingModel
    static var pictures = false

    func makeNSView(context: Context) -> NSView {
        ModelingViewport.pictures ? ViewportPicture(model: model) : ModelingViewportView(model: model)
    }

    func updateNSView(_ view: NSView, context: Context) { view.needsDisplay = true }
}

/// The viewport's frame drawn as an image (no Metal layer): what a picture of the window shows.
final class ViewportPicture: NSView {
    let model: ModelingModel
    init(model: ModelingModel) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let scale: CGFloat = 2
        model.viewSize = SIMD2(Float(bounds.width), Float(bounds.height))
        model.pixelScale = Float(scale)
        var f = model.frame()
        f.size = SIMD2(max(1, Int(bounds.width * scale)), max(1, Int(bounds.height * scale)))
        guard let image = model.renderer?.snapshot(f), let g = NSGraphicsContext.current?.cgContext else { return }
        g.saveGState()
        g.translateBy(x: 0, y: bounds.height)
        g.scaleBy(x: 1, y: -1)
        g.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        g.restoreGState()
    }
}
