import AppKit
import Metal
import QuartzCore

/// Where a frame ends up: the window's layer, or offscreen textures (benchmarks, which run without a window unless
/// `METALRENDERER_WINDOW=1`).
protocol RenderSurface: AnyObject {
    /// The size in points; the render resolution is this times the render scale.
    var pointSize: CGSize { get }
    /// Physical pixels per point: the upscaled output is capped at `pointSize * backingScale`.
    var backingScale: CGFloat { get }
    /// The size of the textures `nextOutput` hands out.
    var outputSize: CGSize { get set }
    /// This frame's output texture (the drawable's, with the drawable to present), nil if there is none.
    func nextOutput() -> FrameOutput?
    /// The window title; ignored offscreen.
    var title: String? { get set }
    /// False while nothing would show the frames (the window hidden or minimized): the renderer then draws none.
    var isVisible: Bool { get }
}

struct FrameOutput {
    let texture: MTLTexture
    let drawable: CAMetalDrawable?
}

/// The window's surface: its view's CAMetalLayer, drawn into from the render thread. The view (main thread) tells it
/// its size; the render thread reads that and sets the drawable's size, which the layer stretches to the view.
final class LayerSurface: RenderSurface {
    let layer = CAMetalLayer()
    private let lock = NSLock()
    private var points = CGSize(width: 1280, height: 800)
    private var scale: CGFloat = 2
    private var visible = true
    private var titleText: String?
    /// The window whose title `title` sets. Main thread.
    weak var window: NSWindow?

    init(device: MTLDevice) {
        layer.device = device
        layer.pixelFormat = Renderer.drawableFormat
        layer.framebufferOnly = false   // the composite or the tone map kernel writes to the drawable
        layer.maximumDrawableCount = Renderer.maxFramesInFlight
        layer.isOpaque = true
        if Benchmark.isEnabled {
            // Benchmark (METALRENDERER_WINDOW=1): the renderer draws back to back without vsync, so the GPU never idles
            // between frames and its clock stays steady (idle gaps let it clock down and inflate the timings of short
            // passes unevenly).
            layer.displaySyncEnabled = false
        }
    }

    /// The view's size and its screen's scale (main thread, on every change).
    func setSize(_ points: CGSize, backingScale: CGFloat) {
        lock.lock(); self.points = points; scale = backingScale; lock.unlock()
    }
    var pointSize: CGSize { lock.lock(); defer { lock.unlock() }; return points }
    // Not the layer's contentsScale: the drawable has the render size, and the layer stretches it.
    var backingScale: CGFloat { lock.lock(); defer { lock.unlock() }; return scale }
    /// Whether the window is on screen (main thread sets it): frames stop while it is hidden or minimized.
    var isVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return visible }
        set { lock.lock(); visible = newValue; lock.unlock() }
    }
    var outputSize: CGSize {
        get { layer.drawableSize }
        set {
            guard layer.drawableSize != newValue else { return }
            // Off the main thread a layer change needs a transaction of its own.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.drawableSize = newValue
            CATransaction.commit()
        }
    }
    func nextOutput() -> FrameOutput? { layer.nextDrawable().map { FrameOutput(texture: $0.texture, drawable: $0) } }
    var title: String? {
        get { lock.lock(); defer { lock.unlock() }; return titleText }
        set {
            guard let newValue else { return }
            lock.lock(); titleText = newValue; lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.window?.title = newValue }
        }
    }
}

/// Benchmarks run without a window, so they neither show up in the Dock nor take the focus from whatever is in front.
/// `METALRENDERER_WINDOW=1` shows the frames in the app's window instead.
enum Headless {
    static let isEnabled = Benchmark.isEnabled && ProcessInfo.processInfo.environment["METALRENDERER_WINDOW"] != "1"
}

/// Frames without a window: a ring of textures in the drawable's format, one per frame in flight. Its size is that of
/// the app's window on a Retina screen, so a run renders the same pixels with or without a window.
final class OffscreenSurface: RenderSurface {
    let pointSize: CGSize
    let backingScale: CGFloat
    var outputSize: CGSize = .zero
    var title: String?
    let isVisible = true
    private let device: MTLDevice
    private var ring: [MTLTexture] = []
    private var next = 0
    private let count: Int

    init(device: MTLDevice, pointSize: CGSize = CGSize(width: 1280, height: 800), backingScale: CGFloat = 2, count: Int = 3) {
        self.device = device
        self.pointSize = pointSize
        self.backingScale = backingScale
        self.count = count
    }

    func nextOutput() -> FrameOutput? {
        let width = Int(outputSize.width), height = Int(outputSize.height)
        guard width > 0, height > 0 else { return nil }
        if ring.first.map({ $0.width != width || $0.height != height }) ?? true {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.drawableFormat, width: width, height: height,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]   // the composite and the tone map write it, the capture blit
            d.storageMode = .private
            ring = (0..<count).compactMap { _ in device.makeTexture(descriptor: d) }
            guard ring.count == count else { ring = []; return nil }
        }
        next = (next + 1) % count
        return FrameOutput(texture: ring[next], drawable: nil)
    }
}
