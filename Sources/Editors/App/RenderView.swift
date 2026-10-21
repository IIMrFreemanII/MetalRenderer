import AppKit
import EngineCore
import Metal
import MetalRenderer
import Physics
import Plants
import UniformTypeIdentifiers

protocol InputHandler: AnyObject {
    func keyDown(_ event: NSEvent)
    func keyUp(_ event: NSEvent)
    func flagsChanged(_ event: NSEvent)
    /// `at`: the cursor in the view, 0...1 across and down.
    func mouseDown(at: SIMD2<Float>)
    func mouseDragged(dx: Float, dy: Float, at: SIMD2<Float>)
    func mouseUp()
    func scrolled(dy: Float)
    /// The right button (the Material Painter's paint mode orbits with it), the cursor moving with no button down,
    /// and a pen's pressure (1 for a mouse) ahead of the press or drag it comes with.
    func rightMouseDown(at: SIMD2<Float>)
    func rightMouseDragged(dx: Float, dy: Float, at: SIMD2<Float>)
    func rightMouseUp()
    /// The middle button (the scene view pans with it).
    func otherMouseDown(at: SIMD2<Float>)
    func otherMouseDragged(dx: Float, dy: Float, at: SIMD2<Float>)
    func mouseMoved(at: SIMD2<Float>)
    func pressure(_ p: Float)
    /// The mouse moved while it is captured (`RenderView.captured`): by how much (points), not where.
    func mouseLook(dx: Float, dy: Float)
}

extension InputHandler {
    func rightMouseDown(at: SIMD2<Float>) {}
    func rightMouseDragged(dx: Float, dy: Float, at: SIMD2<Float>) {}
    func rightMouseUp() {}
    func otherMouseDown(at: SIMD2<Float>) {}
    func otherMouseDragged(dx: Float, dy: Float, at: SIMD2<Float>) {}
    func mouseMoved(at: SIMD2<Float>) {}
    func pressure(_ p: Float) {}
    func mouseLook(dx: Float, dy: Float) {}
}

/// The window's view: its layer is the CAMetalLayer the render thread draws into (`surface`), and it forwards keyboard
/// and mouse input to the renderer.
final class RenderView: NSView {
    weak var inputHandler: InputHandler?
    let surface: LayerSurface
    let device: MTLDevice
    private var occlusionObserver: NSObjectProtocol?

    var onDropModels: (([URL]) -> Void)?

    /// What File > Open and drag and drop accept: glTF models, and HDR images (.hdr, .exr) for the sky.
    static let openableExtensions = ["glb", "gltf", "hdr", "exr"]
    static let modelTypes: [UTType] = openableExtensions.compactMap { UTType(filenameExtension: $0) }

    package init(frame: CGRect, device: MTLDevice) {
        self.device = device
        surface = LayerSurface(device: device)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes([.fileURL])
    }
    package required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { surface.layer }

    // The render thread reads the size at the start of each frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceSize()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        surface.window = window
        updateSurfaceSize()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        // No frames while the window is hidden or minimized. (A benchmark draws on regardless.)
        guard let window, !Benchmark.isEnabled else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.surface.isVisible = window.occlusionState.contains(.visible)
        }
    }
    private func updateSurfaceSize() {
        surface.setSize(bounds.size, backingScale: window?.backingScaleFactor ?? 2, refreshRate: window?.screen?.maximumFramesPerSecond ?? 60)
    }

    private func modelURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { RenderView.openableExtensions.contains($0.pathExtension.lowercased()) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { modelURLs(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = modelURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropModels?(urls)
        return true
    }

    /// The mouse captured (the demolition scene's aim): the cursor hidden and held in the view's middle, its moves
    /// sent as looks (InputHandler.mouseLook); clicks still come as clicks. Off: the cursor back where it was.
    var captured = false {
        didSet {
            guard captured != oldValue else { return }
            if captured {
                NSCursor.hide()
                if let window, let screen = window.screen ?? NSScreen.main {
                    let mid = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
                    // (Quartz's points: y down from the main screen's top.)
                    let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
                    CGWarpMouseCursorPosition(CGPoint(x: mid.x, y: top - mid.y))
                }
                CGAssociateMouseAndMouseCursorPosition(0)
            } else {
                CGAssociateMouseAndMouseCursorPosition(1)
                NSCursor.unhide()
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Not calling super avoids the system "beep" for unhandled keys.
    override func keyDown(with event: NSEvent) { inputHandler?.keyDown(event) }
    override func keyUp(with event: NSEvent) { inputHandler?.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { inputHandler?.flagsChanged(event) }

    /// Where `event` happened in the view: 0...1 across and down.
    private func cursor(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(p.x / max(bounds.width, 1)), Float(1 - p.y / max(bounds.height, 1)))
    }

    override func mouseDown(with event: NSEvent) {
        inputHandler?.pressure(event.subtype == .tabletPoint ? event.pressure : 1)
        inputHandler?.mouseDown(at: cursor(event))
    }
    override func mouseUp(with event: NSEvent) { inputHandler?.mouseUp() }
    override func mouseDragged(with event: NSEvent) {
        if captured { inputHandler?.mouseLook(dx: Float(event.deltaX), dy: Float(event.deltaY)); return }
        inputHandler?.pressure(event.subtype == .tabletPoint ? event.pressure : 1)
        inputHandler?.mouseDragged(dx: Float(event.deltaX), dy: Float(event.deltaY), at: cursor(event))
    }
    override func rightMouseDown(with event: NSEvent) { inputHandler?.rightMouseDown(at: cursor(event)) }
    override func rightMouseUp(with event: NSEvent) { inputHandler?.rightMouseUp() }
    override func rightMouseDragged(with event: NSEvent) {
        if captured { inputHandler?.mouseLook(dx: Float(event.deltaX), dy: Float(event.deltaY)); return }
        inputHandler?.rightMouseDragged(dx: Float(event.deltaX), dy: Float(event.deltaY), at: cursor(event))
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { inputHandler?.otherMouseDown(at: cursor(event)) }
    }
    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2 { inputHandler?.otherMouseDragged(dx: Float(event.deltaX), dy: Float(event.deltaY), at: cursor(event)) }
    }
    override func mouseMoved(with event: NSEvent) {
        if captured { inputHandler?.mouseLook(dx: Float(event.deltaX), dy: Float(event.deltaY)); return }
        inputHandler?.mouseMoved(at: cursor(event))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moves { removeTrackingArea(moves) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        moves = area
    }
    private var moves: NSTrackingArea?
    override func scrollWheel(with event: NSEvent) {
        // A trackpad's deltas are in points, a wheel's in lines.
        inputHandler?.scrolled(dy: Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.1 : 1))
    }
}
