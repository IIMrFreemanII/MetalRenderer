import Metal
import MetalFX
import QuartzCore

/// MetalFX's frame interpolator (macOS 26): from this frame's picture and the last one's, with the traced depth and
/// motion that the denoising scaler took, it makes the picture halfway between them. The frame then presents two
/// drawables, that one and its own, half a frame apart, so a view rendering below the display's rate moves twice as
/// often (a frame later than without it). Only with MetalFX's upscaling: the native path writes no device depth or
/// pixel motion.
///
/// The frame's picture goes into `color` (one of two, this frame's and the last one's) instead of the drawable;
/// `encode` then copies it and the in-between picture into the frame's drawables. The gizmos go over both afterwards:
/// they are drawn, not interpolated.
final class FrameInterpolator {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    private let interpolator: AnyObject      // MTLFXFrameInterpolator
    private let colors: [MTLTexture]         // the frames' pictures, this one's and the last one's, in turn
    /// The in-between picture: MetalFX writes only private textures, so it can't write a drawable.
    let output: MTLTexture
    private var current = 0
    /// The projection has no far plane (Camera.viewToClip); MetalFX asks for one: farther than anything traced.
    static let farPlane: Float = 1_000_000
    /// Whether `color`'s other texture holds the last frame's picture (false at first, after a reset, or after frames
    /// without interpolation): this frame then presents only its own.
    private(set) var hasHistory = false

    /// This frame's picture, for the tone map (or the lens's finish) to write.
    var color: MTLTexture { colors[current] }

    /// `upscaler`: the frame's denoising scaler, whose depth and motion this reads; made again with it.
    init(device: MTLDevice, upscaler: Upscaler) throws {
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
        d.scaler = upscaler.scaler as? MTLFXFrameInterpolatableScaler
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
        // The tone map writes the pictures; MetalFX reads them; a blit copies them into the drawables.
        colors = try (0..<2).map { try texture(interpolator.colorTextureUsage.union([.shaderRead, .shaderWrite]), "interpolated color \($0)") }
        output = try texture(interpolator.outputTextureUsage.union(.shaderRead), "interpolated")
    }

    /// The next frame writes the other picture. `kept`: this frame's picture is the history of the next one (false
    /// when the frame presented without interpolation).
    func advance(kept: Bool) {
        hasHistory = kept
        current = 1 - current
    }

    /// Forgets the last frame's picture (a new scene, a cut): the next frame presents only its own.
    func reset() { hasHistory = false }

    /// The in-between picture into `between` (when there is a last frame's picture) and this frame's into `own`.
    func encode(into cmd: MTLCommandBuffer, _ inputs: InterpolateInputs, own: MTLTexture, between: MTLTexture?) {
        guard #available(macOS 26.0, *), let fi = interpolator as? MTLFXFrameInterpolator else { return }
        if hasHistory, let between {
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
            fi.outputTexture = output
            fi.encode(commandBuffer: cmd)
            copy(output, to: between, cmd)
        }
        copy(color, to: own, cmd)
    }

    private func copy(_ source: MTLTexture, to destination: MTLTexture, _ cmd: MTLCommandBuffer) {
        guard let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
    }
}

/// What the frame interpolator reads besides its own pictures.
struct InterpolateInputs {
    let targets: RenderTargets
    let view: Upscaler.View
    let jitter: SIMD2<Float>
    let deltaTime: Float
    let fovDegrees: Float
}

/// When the frame interpolator runs (RenderSettings.frameInterpolation).
enum FrameInterpolation: Int, CaseIterable, Codable {
    case off
    case on        // every frame
    case auto      // while frames take longer than two of the display's refreshes (so both pictures can show)

    var title: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return "Auto"
        }
    }

    /// Auto's switch, with room between on and off: on once frames take `onAt` refreshes, off again under `offAt`.
    static let onAt = 2.1, offAt = 1.8

    /// Whether auto interpolates the next frame, from the time between the frames (ms, smoothed), the display's
    /// refresh interval (ms) and whether it interpolated the last one.
    static func autoOn(frameMs: Double, refreshMs: Double, was: Bool) -> Bool {
        frameMs > refreshMs * (was ? offAt : onAt)
    }
}
