import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

extension ViewportRenderer {
    /// The frame drawn offscreen and read back as an image: what the tests and the benchmark's shots look at (the
    /// window is never shown for them).
    package func snapshot(_ f: ViewportFrame) -> CGImage? {
        let bytes = pixels(f)
        guard !bytes.isEmpty else { return nil }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: f.size.x, height: f.size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.size.x * 4, space: space,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The pixels of a snapshot (BGRA8), for tests that look at colours.
    package func pixels(_ f: ViewportFrame) -> [UInt8] {
        guard let queue = commandQueue, let cb = queue.makeCommandBuffer() else { return [] }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: f.size.x, height: f.size.y, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return [] }
        encode(f, target: target, into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: f.size.x * f.size.y * 4)
        target.getBytes(&bytes, bytesPerRow: f.size.x * 4, from: MTLRegionMake2D(0, 0, f.size.x, f.size.y), mipmapLevel: 0)
        return bytes
    }

    package static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
