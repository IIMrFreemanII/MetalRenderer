import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// A baked graph's textures as files: each output channel a PNG (8 or 16 bits a channel) or an EXR (32-bit float),
/// named `<graph>_<channel>`; and the packed occlusion-roughness-metallic too (`_orm`, glTF's layout). Read back from
/// the engine's images at the graph's size.
enum MatExport {
    enum Format: String, CaseIterable {
        case png8 = "PNG 8-bit", png16 = "PNG 16-bit", exr = "EXR 32-bit"
        var suffix: String { self == .exr ? "exr" : "png" }
    }

    /// Writes the outputs of `result` into `folder`; the files written.
    @discardableResult
    static func write(_ result: MatResult, engine: MatEngine, to folder: URL, format: Format, packedORM: Bool = true) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plan = result.plan
        let base = VFXEffect.slug(plan.name)
        var written: [URL] = []
        for c in MatChannel.allCases {
            guard let k = plan.channels[c], let t = engine.texture(plan.steps[k].hash) else { continue }
            let url = folder.appendingPathComponent("\(base)_\(c.rawValue).\(format.suffix)")
            try write(engine.read(t), side: t.width, grey: plan.steps[k].outputs[0] == .grey, srgb: c == .baseColor || c == .emissive,
                      format: format, to: url)
            written.append(url)
        }
        if packedORM, let orm = result.outputs.orm {
            let url = folder.appendingPathComponent("\(base)_orm.\(format.suffix)")
            try write(engine.read(orm), side: orm.width, grey: false, srgb: false, format: format, to: url)
            written.append(url)
        }
        return written
    }

    /// `pixels` (side × side, RGBA floats, values as the graph has them) as an image file.
    static func write(_ pixels: [SIMD4<Float>], side: Int, grey: Bool, srgb: Bool, format: Format, to url: URL) throws {
        let channels = grey ? 1 : 4
        let space = grey ? CGColorSpace(name: CGColorSpace.linearGray)! : CGColorSpace(name: srgb ? CGColorSpace.sRGB : CGColorSpace.linearSRGB)!
        let image: CGImage?
        switch format {
        case .png8:
            var bytes = [UInt8](repeating: 0, count: side * side * channels)
            for (i, p) in pixels.enumerated() { for c in 0..<channels { bytes[i * channels + c] = UInt8((min(max(p[c], 0), 1) * 255).rounded()) } }
            image = make(Data(bytes), side: side, bits: 8, channels: channels, space: space,
                         info: CGBitmapInfo(rawValue: grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.last.rawValue))
        case .png16:
            var words = [UInt16](repeating: 0, count: side * side * channels)
            for (i, p) in pixels.enumerated() { for c in 0..<channels { words[i * channels + c] = UInt16((min(max(p[c], 0), 1) * 65535).rounded()) } }
            image = make(words.withUnsafeBytes { Data($0) }, side: side, bits: 16, channels: channels, space: space,
                         info: CGBitmapInfo(rawValue: (grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.last.rawValue) | CGBitmapInfo.byteOrder16Little.rawValue))
        case .exr:
            var floats = [Float](repeating: 0, count: side * side * 4)
            for (i, p) in pixels.enumerated() { for c in 0..<4 { floats[i * 4 + c] = grey && c < 3 ? p.x : p[c] } }
            image = make(floats.withUnsafeBytes { Data($0) }, side: side, bits: 32, channels: 4, space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                         info: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        }
        guard let image else { throw MatError("\(url.lastPathComponent): the image couldn't be made") }
        let type = format == .exr ? "com.ilm.openexr-image" : UTType.png.identifier
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw MatError("\(url.lastPathComponent): \(format.rawValue) can't be written here")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MatError("\(url.lastPathComponent) wasn't written") }
    }

    private static func make(_ data: Data, side: Int, bits: Int, channels: Int, space: CGColorSpace, info: CGBitmapInfo) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: bits, bitsPerPixel: bits * channels, bytesPerRow: side * channels * bits / 8,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
