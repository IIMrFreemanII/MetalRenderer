import AppKit
import Metal
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

    init(frame: CGRect, device: MTLDevice) {
        self.device = device
        surface = LayerSurface(device: device)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes([.fileURL])
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
        surface.setSize(bounds.size, backingScale: window?.backingScaleFactor ?? 2)
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

    override func mouseDown(with event: NSEvent) { inputHandler?.mouseDown(at: cursor(event)) }
    override func mouseUp(with event: NSEvent) { inputHandler?.mouseUp() }
    override func mouseDragged(with event: NSEvent) {
        inputHandler?.mouseDragged(dx: Float(event.deltaX), dy: Float(event.deltaY), at: cursor(event))
    }
    override func scrollWheel(with event: NSEvent) {
        // A trackpad's deltas are in points, a wheel's in lines.
        inputHandler?.scrolled(dy: Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.1 : 1))
    }
}
