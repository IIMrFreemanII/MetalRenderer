import AppKit
import MetalKit

/// Where a frame ends up: the window's MTKView, or offscreen textures (benchmarks, which run without a window unless
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
}

struct FrameOutput {
    let texture: MTLTexture
    let drawable: CAMetalDrawable?
}

extension MTKView: RenderSurface {
    var pointSize: CGSize { bounds.size }
    // Not convertToBacking: MTKView scales its layer to match drawableSize, so that returns the render size.
    var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }
    var outputSize: CGSize {
        get { drawableSize }
        set { if drawableSize != newValue { drawableSize = newValue } }
    }
    func nextOutput() -> FrameOutput? { currentDrawable.map { FrameOutput(texture: $0.texture, drawable: $0) } }
    var title: String? {
        get { window?.title }
        set { if let newValue { window?.title = newValue } }
    }

    /// What the renderer needs of the view it draws into.
    func configureForRenderer() {
        colorPixelFormat = Renderer.drawableFormat
        framebufferOnly = false        // the composite kernel or MetalFX writes to the drawable
        autoResizeDrawable = false     // the renderer picks the render resolution itself
        preferredFramesPerSecond = 120
        if Benchmark.isEnabled {
            // Benchmark (METALRENDERER_WINDOW=1): the renderer draws back to back without vsync, so the GPU never idles
            // between frames and its clock stays steady (idle gaps let it clock down and inflate the timings of short
            // passes unevenly).
            (layer as? CAMetalLayer)?.displaySyncEnabled = false
            isPaused = true
            enableSetNeedsDisplay = false
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
            d.usage = [.shaderRead, .shaderWrite]   // the composite and TAAU write it, MetalFX and the capture blit
            d.storageMode = .private
            ring = (0..<count).compactMap { _ in device.makeTexture(descriptor: d) }
            guard ring.count == count else { ring = []; return nil }
        }
        next = (next + 1) % count
        return FrameOutput(texture: ring[next], drawable: nil)
    }
}
