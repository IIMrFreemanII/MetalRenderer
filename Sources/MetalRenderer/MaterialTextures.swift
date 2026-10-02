import Foundation
import ImageIO
import Metal

/// Decodes the scene's material images into mipmapped textures. Images are decoded at no more than `maxSize`
/// pixels on a side (ImageIO thumbnails, decoded in parallel), so 4K maps cost a quarter of the memory.
/// Pixels are drawn into RGBA8 in the image's own colour space, so data maps (normals, metallic-roughness) keep
/// their raw values; colour maps get an sRGB texture format and are linearized by the sampler.
enum MaterialTextures {
    static let maxSize = Int(ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_SIZE"] ?? "") ?? 2048

    static func load(_ sources: [Scene.TextureSource], device: MTLDevice, queue: MTLCommandQueue) throws -> [MTLTexture] {
        guard !sources.isEmpty else { return [] }
        let start = CFAbsoluteTimeGetCurrent()
        var decoded = [(pixels: MTLBuffer, width: Int, height: Int)?](repeating: nil, count: sources.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sources.count) { i in
            guard let src = CGImageSourceCreateWithData(sources[i].data as CFData, nil) else { return }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxSize,
                                            kCGImageSourceCreateThumbnailWithTransform: false]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return }
            let w = image.width, h = image.height
            guard let buffer = device.makeBuffer(length: w * h * 4, options: .storageModeShared) else { return }
            var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }   // e.g. greyscale images
            guard let ctx = CGContext(data: buffer.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // memory order R G B x
            lock.lock(); decoded[i] = (buffer, w, h); lock.unlock()
        }

        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else {
            throw RendererError.resourceCreation("texture upload command buffer")
        }
        var textures: [MTLTexture] = []
        var bytes = 0
        for (i, source) in sources.enumerated() {
            guard let d = decoded[i] else { throw RendererError.resourceCreation("decoding texture \(source.name)") }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
                                                                width: d.width, height: d.height, mipmapped: true)
            desc.usage = .shaderRead
            desc.storageMode = .private
            guard let texture = device.makeTexture(descriptor: desc) else {
                throw RendererError.resourceCreation("texture \(source.name)")
            }
            texture.label = source.name
            blit.copy(from: d.pixels, sourceOffset: 0, sourceBytesPerRow: d.width * 4, sourceBytesPerImage: d.width * d.height * 4,
                      sourceSize: MTLSize(width: d.width, height: d.height, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: texture)
            textures.append(texture)
            bytes += d.width * d.height * 4 * 4 / 3
        }
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        print(String(format: "Textures: %d decoded (max %d px), %.0f MB, in %.1f s", textures.count, maxSize,
                     Double(bytes) / 1_048_576, CFAbsoluteTimeGetCurrent() - start))
        return textures
    }
}
