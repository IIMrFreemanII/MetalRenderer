import Characters
import Effects
import EngineCore
import Foundation
import Metal
import Physics
import Plants
import simd

/// The solid look's resources (RenderSettings.solidLook; Shaders/Output.metal solidTraceKernel, solidResolveKernel).
extension Renderer {
    /// Its three targets at the output's size (made when it changes; nil if Metal can't).
    package func solidTargets(width: Int, height: Int) -> [MTLTexture]? {
        if solidTargetsStore.count == 3, solidTargetsStore[0].width == width, solidTargetsStore[0].height == height { return solidTargetsStore }
        var made: [MTLTexture] = []
        for (format, label) in [(MTLPixelFormat.rgba16Float, "solid colour"), (.rgba16Float, "solid geometry"), (.r32Uint, "solid ids")] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            t.label = label
            made.append(t)
        }
        solidTargetsStore = made
        return made
    }

    /// What the look's settings ask of its kernels.
    package func solidParams() -> GPUSolidParams {
        let l = settings.solidLook
        return GPUSolidParams(sun: SIMD4(simd_normalize(SIMD3<Float>(-0.45, 0.8, 0.4)), l.shadows ? 1 : 0),
                              look: SIMD4(l.materials ? l.tint : 0, l.cutFaces ? 1 : 0, l.aoRadius, l.ao ? Float(l.aoRays) : 0),
                              edges: SIMD4(l.edges ? 1 : 0, Float(l.edgeWidth), l.materials ? 1 : 0, 0),
                              info: SIMD4(UInt32(scene.materialFlags.count), 0, 0, 0))
    }

    /// The scene's material flags in a buffer (made again when they change: a scene built anew).
    package func solidFlagBuffer() -> MTLBuffer? {
        let flags = scene.materialFlags
        if let b = solidFlagsStore, flags == solidFlagsCopyStore { return b }
        var bytes = flags.isEmpty ? [UInt8](repeating: 0, count: 16) : flags
        bytes.append(contentsOf: repeatElement(0, count: (16 - bytes.count % 16) % 16))
        let b = bytes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        b?.label = "solid material flags"
        solidFlagsStore = b
        solidFlagsCopyStore = flags
        return b
    }
}
