import Characters
import Effects
import EngineCore
import Metal
import MetalFX
import Physics
import Plants
import QuartzCore

/// MetalFX's frame interpolator (macOS 26): from this frame's picture and the last one's, with the traced depth and
/// motion that the denoising scaler took, it makes the picture halfway between them. Two drawables are presented, that
/// one and the frame's own, each held for half a frame, so a view rendering below the display's rate moves twice as
/// often (a frame later than without it). Only with MetalFX's upscaling: the native path writes no device depth or
/// pixel motion.
///
/// The frame's picture goes into `color` (one of two, this frame's and the last one's) instead of the drawable;
/// `encode` copies it into a slot's `shown` and puts the in-between picture in its `between`, and the gizmos go over
/// both (they are drawn, not interpolated). The frame takes no drawable: once it is done on the GPU, `Presenter` copies
/// the slot into two drawables and presents them. Taken during the frame, as the frames without interpolation take
/// theirs, the drawables held the frame up: two of the layer's three were still on their way to the screen, so the
/// GPU waited for a picture to be shown before it started the next frame (a 40 ms frame came every 70 ms).
package final class FrameInterpolator {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    private let interpolator: AnyObject      // MTLFXFrameInterpolator
    private let colors: [MTLTexture]         // the frames' pictures, this one's and the last one's, in turn
    /// A frame's two pictures with the gizmos over them, till they are in the drawables: one slot a frame in flight.
    /// MetalFX writes only private textures, so it can't write a drawable.
    let shown: [MTLTexture], between: [MTLTexture]
    /// Free once the presenter has copied the slot out (a frame waits for its slot: `claim`).
    private let free: [DispatchSemaphore]
    private var current = 0
    /// The projection has no far plane (Camera.viewToClip); MetalFX asks for one: farther than anything traced.
    static let farPlane: Float = 1_000_000
    /// Whether `color`'s other texture holds the last frame's picture (false at first, after a reset, or after frames
    /// without interpolation): this frame then presents only its own.
    private(set) var hasHistory = false

    /// This frame's picture, for the tone map (or the lens's finish) to write.
    var color: MTLTexture { colors[current] }

    /// `upscaler`: the frame's denoising scaler, whose depth and motion this reads; made again with it.
    package init(device: MTLDevice, upscaler: Upscaler, slots: Int) throws {
        inputWidth = upscaler.inputWidth
        inputHeight = upscaler.inputHeight
        outputWidth = upscaler.outputWidth
        outputHeight = upscaler.outputHeight
        guard #available(macOS 26.0, *) else { throw RendererError.resourceCreation("MetalFX frame interpolator (needs macOS 26)") }
        let d = MTLFXFrameInterpolatorDescriptor()
        d.colorTextureFormat = Renderer.drawableFormat
        d.outputTextureFormat = Renderer.drawableFormat
        d.depthTextureFormat = RenderTargets.upscaleDepthFormat
        d.motionTextureFormat = RenderTargets.upscaleMotionFormat
        (d.inputWidth, d.inputHeight, d.outputWidth, d.outputHeight) = (inputWidth, inputHeight, outputWidth, outputHeight)
        d.scaler = upscaler.metal4 ? nil : upscaler.scaler as? MTLFXFrameInterpolatableScaler   // (a Metal 3 interpolator)
        guard let interpolator = d.makeFrameInterpolator(device: device) else {
            throw RendererError.resourceCreation("MetalFX frame interpolator \(inputWidth)×\(inputHeight) → \(outputWidth)×\(outputHeight)")
        }
        interpolator.motionVectorScaleX = 1   // motion is in input pixels, as for the scaler
        interpolator.motionVectorScaleY = 1
        interpolator.isDepthReversed = true
        self.interpolator = interpolator

        let (width, height) = (outputWidth, outputHeight)
        func texture(_ usage: MTLTextureUsage, _ label: String) throws -> MTLTexture {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.drawableFormat, width: width,
                                                             height: height, mipmapped: false)
            t.usage = usage
            t.storageMode = .private
            guard let texture = device.makeTexture(descriptor: t) else { throw RendererError.resourceCreation("texture \(label)") }
            texture.label = label
            return texture
        }
        // The tone map writes the pictures and MetalFX reads them; the gizmos go over the slots' copies, which blits
        // copy into the drawables (and a benchmark's capture).
        colors = try (0..<2).map { try texture(interpolator.colorTextureUsage.union([.shaderRead, .shaderWrite]), "interpolated color \($0)") }
        shown = try (0..<slots).map { try texture([.shaderRead, .shaderWrite], "shown \($0)") }
        between = try (0..<slots).map { try texture(interpolator.outputTextureUsage.union([.shaderRead, .shaderWrite]), "in-between \($0)") }
        free = (0..<slots).map { _ in DispatchSemaphore(value: 1) }
    }

    /// Waits until the presenter is done with `slot`, which the frame then writes; `release` hands it back.
    func claim(_ slot: Int) { free[slot].wait() }
    func release(_ slot: Int) { free[slot].signal() }

    /// The next frame writes the other picture. `kept`: this frame's picture is the history of the next one (false
    /// when the frame presented without interpolation).
    func advance(kept: Bool) {
        hasHistory = kept
        current = 1 - current
    }

    /// Forgets the last frame's picture (a new scene, a cut): the next frame presents only its own.
    func reset() { hasHistory = false }

    /// This frame's picture into `shown[slot]` and, when there is a last frame's picture, the in-between one into
    /// `between[slot]`. Returns whether it made one.
    @discardableResult
    func encode(into cmd: MTLCommandBuffer, _ inputs: InterpolateInputs, slot: Int) -> Bool {
        guard #available(macOS 26.0, *), let fi = interpolator as? MTLFXFrameInterpolator else { return false }
        if hasHistory {
            fi.colorTexture = color
            fi.prevColorTexture = colors[1 - current]
            fi.depthTexture = inputs.targets.deviceDepth
            fi.motionTexture = inputs.targets.pixelMotion
            fi.deltaTime = inputs.deltaTime
            fi.nearPlane = Camera.nearPlane
            fi.farPlane = FrameInterpolator.farPlane
            fi.fieldOfView = inputs.fovDegrees
            fi.aspectRatio = Float(outputWidth) / Float(outputHeight)
            if #available(macOS 27.0, *) {
                fi.worldToViewMatrix = inputs.view.worldToView
                fi.viewToClipMatrix = inputs.view.viewToClip
            }
            fi.jitterOffsetX = -inputs.jitter.x   // as for the scaler: the offset back to the pixel's center
            fi.jitterOffsetY = -inputs.jitter.y
            fi.shouldResetHistory = false
            fi.outputTexture = between[slot]
            fi.encode(commandBuffer: cmd)
        }
        guard let blit = cmd.makeBlitCommandEncoder() else { return hasHistory }
        blit.copy(from: color, to: shown[slot])
        blit.endEncoding()
        return hasHistory
    }

    /// Copies finished frames' slots into the layer's drawables and presents them, off the render thread: it waits for
    /// the drawables there, while the next frame renders. Its own (Metal 3) queue: a blit and the presents.
    package final class Presenter {
        private let queue: MTLCommandQueue
        private let layer: CAMetalLayer
        private let thread = DispatchQueue(label: "frame interpolation presenter")

        package init?(device: MTLDevice, layer: CAMetalLayer) {
            guard let queue = device.makeCommandQueue() else { return nil }
            queue.label = "frame interpolation presenter"
            self.queue = queue
            self.layer = layer
        }

        /// Once the frame that filled `slot` is done on the GPU: its in-between picture (if `withBetween`) and then its
        /// own, each held `hold` seconds; `done` once they are copied out of the slot.
        func present(_ interpolator: FrameInterpolator, slot: Int, withBetween: Bool, hold: CFTimeInterval) {
            thread.async { [queue, layer] in
                let pictures = (withBetween ? [interpolator.between[slot]] : []) + [interpolator.shown[slot]]
                guard let cb = queue.makeCommandBuffer() else { interpolator.release(slot); return }
                for picture in pictures {
                    guard let drawable = layer.nextDrawable() else { continue }
                    let t = drawable.texture
                    guard t.width == picture.width, t.height == picture.height, let blit = cb.makeBlitCommandEncoder() else { continue }
                    blit.copy(from: picture, to: t)
                    blit.endEncoding()
                    if withBetween { cb.present(drawable, afterMinimumDuration: hold) } else { cb.present(drawable) }
                }
                cb.addCompletedHandler { _ in interpolator.release(slot) }
                cb.commit()
            }
        }

        /// Waits until what was handed over is committed, ahead of a frame that presents its own drawable.
        func drain() { thread.sync {} }
    }
}

/// What the frame interpolator reads besides its own pictures.
package struct InterpolateInputs {
    let targets: RenderTargets
    let view: Upscaler.View
    let jitter: SIMD2<Float>
    let deltaTime: Float
    let fovDegrees: Float
}

/// When the frame interpolator runs (RenderSettings.frameInterpolation).
package enum FrameInterpolation: Int, CaseIterable, Codable {
    case off
    case on        // every frame
    case auto      // while a frame's GPU work takes over three of the display's refreshes

    var title: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return "Auto"
        }
    }

    /// Auto's switch, with room between on and off: on once a frame takes `onAt` refreshes, off again under `offAt`.
    /// Each picture shows a whole number of refreshes, so a frame of 3 to 4 refreshes (under 40 fps at 120 Hz), which
    /// shows for 4 without interpolation, shows as two pictures of 2: twice as often, and as many frames as before.
    /// Faster, the two pictures would cost frames (a frame of 2.5 refreshes shows every 3, interpolated every 4).
    static let onAt = 3.0, offAt = 2.7

    /// Whether auto interpolates the next frame, from a frame's GPU time (ms, smoothed), the display's refresh
    /// interval (ms) and whether it interpolated the last one.
    static func autoOn(frameMs: Double, refreshMs: Double, was: Bool) -> Bool {
        frameMs > refreshMs * (was ? offAt : onAt)
    }

    /// How long each of a frame's two pictures is held (seconds), from a frame's GPU time (ms): as many whole refreshes
    /// as half a frame takes (a little under, so a late refresh doesn't add another), so both show evenly. Without a
    /// display, half a frame.
    static func hold(frameMs: Double, refreshMs: Double?) -> CFTimeInterval {
        guard let refreshMs, refreshMs > 0 else { return frameMs / 2000 }
        let refreshes = max(1, (frameMs / 2 / refreshMs).rounded(.up))
        return (refreshes * refreshMs - min(2, refreshMs / 4)) / 1000
    }
}
