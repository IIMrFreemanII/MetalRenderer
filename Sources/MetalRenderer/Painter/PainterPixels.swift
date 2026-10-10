import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd

/// A painted object's pixels on disk (PainterStore's package): each paint layer's channels and painted masks as 16-bit
/// PNGs (`layers/<layer id>-<channel>.png`: premultiplied value(s), then coverage), and the finished texture set
/// (`final/`: base colour and emissive sRGB, the rest linear; 8 bits but the height's 16). Read back from the GPU
/// with a kernel into a shared buffer (the textures are private).
enum PainterPixels {
    /// `t`'s pixels as floats, now (waits for the GPU).
    static func read(_ t: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) -> [SIMD4<Float>] {
        let n = t.width * t.height
        guard let state = try? MatCompiler.shared.state("paintReadback", device: device),
              let out = device.makeBuffer(length: n * 16, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return [] }
        enc.setComputePipelineState(state)
        enc.setTexture(t, index: 0)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: SIMD4<Float>.self, capacity: n), count: n))
    }

    /// `t` as a picture `side` squared (8 bits; its values as they are: the base colour's sRGB, a grey's grey, a
    /// paint channel's premultiplied value).
    static func picture(_ t: MTLTexture, side: Int, device: MTLDevice, queue: MTLCommandQueue) -> CGImage? {
        guard let state = try? MatCompiler.shared.state("paintThumbnail", device: device),
              let out = device.makeBuffer(length: side * side * 16, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        var n = UInt32(side)
        enc.setComputePipelineState(state)
        enc.setTexture(t, index: 0)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.setBytes(&n, length: 4, index: 1)
        enc.dispatchThreads(MTLSize(width: side, height: side, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let px = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: side * side)
        let grey = t.pixelFormat == .r8Unorm || t.pixelFormat == .r16Float
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            var v = px[i]
            if grey { v = SIMD4(v.x, v.x, v.x, 1) }
            if t.pixelFormat == .rg16Float { v = SIMD4(v.x, v.x, v.x, 1) }
            for c in 0..<3 { bytes[i * 4 + c] = UInt8(min(max(v[c], 0), 1) * 255) }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func layerFile(_ layer: UUID, _ part: String) -> String { "\(layer.uuidString.lowercased())-\(part).png" }

    /// The session's paint layers' pixels and its texture set into `package` (layers/, final/).
    static func save(_ s: PainterSession, to package: URL, device: MTLDevice, queue: MTLCommandQueue) throws {
        let layers = package.appendingPathComponent("layers"), final = package.appendingPathComponent("final")
        try? FileManager.default.removeItem(at: layers)
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        for layer in s.document.layers {
            guard let t = s.layers[layer.id] else { continue }
            for (c, tex) in t.channels {
                try MatExport.write(read(tex, device: device, queue: queue), side: tex.width, grey: false, srgb: false, format: .png16,
                                    to: layers.appendingPathComponent(layerFile(layer.id, c.rawValue)))
            }
            if let m = t.mask {
                try MatExport.write(read(m, device: device, queue: queue), side: m.width, grey: false, srgb: false, format: .png16,
                                    to: layers.appendingPathComponent(layerFile(layer.id, "mask")))
            }
        }
        try export(s, to: final, name: nil, format: .png8, device: device, queue: queue)
    }

    /// The texture set as files in `folder` (`<name>_<channel>`, or the channel alone): base colour, ORM (glTF's
    /// occlusion-roughness-metallic), normal (OpenGL), emissive, height, opacity. The files written.
    @discardableResult
    static func export(_ s: PainterSession, to folder: URL, name: String?, format: MatExport.Format, device: MTLDevice,
                       queue: MTLCommandQueue) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        let parts: [(String, MTLTexture, Bool, Bool)] = [("basecolor", s.base, false, true), ("orm", s.orm, false, false),
                                                         ("normal", s.normal, false, false), ("emissive", s.emissive, false, true),
                                                         ("height", s.height, true, false), ("opacity", s.opacity, true, false)]
        var all = parts
        // The mesh maps too, if baked (curvature, occlusion, thickness: for other tools' smart masks).
        if let b = s.bake { all += [("curvature", b.curvature, true, false), ("occlusion", b.occlusion, true, false), ("thickness", b.thickness, true, false)] }
        for (part, t, grey, srgb) in all {
            if part == "emissive" && !s.document.emissive { continue }
            if part == "opacity" && !s.document.opacity { continue }
            let url = folder.appendingPathComponent((name.map { "\($0)_" } ?? "") + part + "." + format.suffix)
            let f: MatExport.Format = part == "height" && format == .png8 ? .png16 : format
            try MatExport.write(read(t, device: device, queue: queue), side: t.width, grey: grey, srgb: srgb, format: f, to: url)
            written.append(url)
        }
        return written
    }

    /// A PNG's pixels as floats 0...1 (its 8 or 16 bits as they are, no colour conversion), or nil.
    static func image(_ url: URL) -> (pixels: [SIMD4<Float>], width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let w = img.width, h = img.height, bpc = img.bitsPerComponent, channels = img.bitsPerPixel / max(bpc, 1), row = img.bytesPerRow
        let little = img.bitmapInfo.contains(.byteOrder16Little)
        var out = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var p = SIMD4<Float>(0, 0, 0, 1)
                for c in 0..<min(channels, 4) {
                    if bpc == 16 {
                        let o = y * row + (x * channels + c) * 2
                        let v = little ? UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 : UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1])
                        p[c] = Float(v) / 65535
                    } else {
                        p[c] = Float(bytes[y * row + x * channels + c]) / 255
                    }
                }
                if channels == 1 { p = SIMD4(p.x, p.x, p.x, 1) }
                if channels == 2 { p = SIMD4(p.x, p.x, p.x, p.y) }
                out[y * w + x] = p
            }
        }
        return (out, w, h)
    }

    /// A paint texture's pixels, as its format holds them (half floats; rg16f: r, g).
    static func bytes(_ pixels: [SIMD4<Float>], format: MTLPixelFormat) -> (bytes: [UInt8], bytesPerRow: Int)? {
        switch format {
        case .rgba16Float:
            var halves = [Float16](repeating: 0, count: pixels.count * 4)
            for (i, p) in pixels.enumerated() { for c in 0..<4 { halves[i * 4 + c] = Float16(p[c]) } }
            return (halves.withUnsafeBytes { Array($0) }, 0)
        case .rg16Float:
            var halves = [Float16](repeating: 0, count: pixels.count * 2)
            for (i, p) in pixels.enumerated() { halves[i * 2] = Float16(p.x); halves[i * 2 + 1] = Float16(p.y) }
            return (halves.withUnsafeBytes { Array($0) }, 0)
        default: return nil
        }
    }

    /// The saved pixels of `document`'s paint layers and masks, for the session's next frame.
    static func load(_ s: PainterSession, document: PaintDocument) {
        guard let package = PainterStore.package(document.name) else { return }
        let folder = package.appendingPathComponent("layers")
        for layer in document.layers {
            var parts: [(String, PaintChannel?)] = layer.kind == .paint ? layer.channels.map { ($0.rawValue, $0) } : []
            if layer.mask?.painted == true { parts.append(("mask", nil)) }
            for (part, channel) in parts {
                let url = folder.appendingPathComponent(layerFile(layer.id, part))
                guard let img = image(url), img.width == s.size, img.height == s.size else { continue }
                let format: MTLPixelFormat = channel?.isColor == true ? .rgba16Float : .rg16Float
                guard let (bytes, _) = bytes(img.pixels, format: format) else { continue }
                s.upload(layer: layer, channel: channel, bytes: bytes, bytesPerRow: s.size * (format == .rgba16Float ? 8 : 4), format: format)
            }
        }
    }
}
