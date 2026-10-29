import CoreGraphics
import Foundation
import ImageIO
import simd

/// A photo-scanned material's maps in `Assets/Textures/<name>/` (Tools/textures/fetch.py: CC0 sets from Poly Haven and
/// ambientCG): albedo, normal (OpenGL: +Y = +V), roughness, ambient occlusion, height, and for an atlas its opacity, with
/// `info.json` saying how many metres one repeat is. What the realistic look (SceneSettings.realism) dresses the ground,
/// the rocks and the plants in; without them (a fresh clone, the tests, METALRENDERER_SCANS=0) it falls back to the
/// generated textures.
package struct TextureSet {
    package enum Map: String, CaseIterable { case albedo, normal, roughness, ao, height, opacity }

    package let name: String
    package let folder: URL
    /// The side of one repeat, metres (what the scan covers).
    package let metres: Float
    /// A leaf sheet's grid of leaves, columns and rows (`info.json`'s "cells"; 3 by 3 if it doesn't say).
    package var cells = SIMD2(3, 3)

    /// Scans are used (METALRENDERER_SCANS=0: never, as if none were there).
    package static let enabled = ProcessInfo.processInfo.environment["METALRENDERER_SCANS"] != "0"
    package static var directory: URL { Assets.directory.appendingPathComponent("Textures") }

    private static var found: [String: TextureSet?] = [:]
    private static let lock = NSLock()

    /// The set `name` if its albedo and normal are there.
    package static func find(_ name: String) -> TextureSet? {
        guard enabled, !name.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let known = found[name] { return known }
        let folder = directory.appendingPathComponent(name)
        var set: TextureSet?
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("albedo.jpg").path),
           fm.fileExists(atPath: folder.appendingPathComponent("normal.jpg").path) {
            var metres: Float = 2, cells = SIMD2(3, 3)
            if let data = try? Data(contentsOf: folder.appendingPathComponent("info.json")),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let m = info["metres"] as? Double { metres = Float(m) }
                if let c = info["cells"] as? [Int], c.count == 2, c[0] > 0, c[1] > 0 { cells = SIMD2(c[0], c[1]) }
            }
            set = TextureSet(name: name, folder: folder, metres: metres, cells: cells)
        }
        found[name] = set
        return set
    }

    package func url(_ map: Map) -> URL? {
        let url = folder.appendingPathComponent(map.rawValue + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file the set's mip chains are cached by (TextureStreamer: one cache file per set, next to its maps).
    package var cacheModel: String { folder.appendingPathComponent("info.json").path }

    /// A map's file, memory-mapped (the streamer reads it only to build its cache, the first time).
    package func data(_ map: Map) -> Data? {
        url(map).flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
    }

    /// A map decoded to one channel (its luminance), `size` × `size` (nil: as it is; `height`: that many rows instead).
    /// Nil if there is none.
    package func gray(_ map: Map, size: Int? = nil, height rows: Int? = nil) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let url = url(map), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = size ?? image.width, h = rows ?? size ?? image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (pixels, w, h) : nil
    }

    /// A height map on the CPU (0...1), wrapping: what the meshes displaced by a scan read (the ground's relief, the
    /// bark's ridges). Sampled as the GPU samples the texture (row 0 at v = 0, texel centres at half texels).
    package struct HeightField {
        package let side: Int
        package let values: [Float]
        package func sample(_ u: Float, _ v: Float) -> Float {
            let n = Float(side)
            let x = u * n - 0.5, y = v * n - 0.5
            let x0 = x.rounded(.down), y0 = y.rounded(.down), fx = x - x0, fy = y - y0
            func at(_ i: Float, _ j: Float) -> Float {
                let a = ((Int(i) % side) + side) % side, b = ((Int(j) % side) + side) % side
                return values[b * side + a]
            }
            let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * fx
            let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * fx
            return top + (bottom - top) * fy
        }
    }
    private static var heights: [String: HeightField] = [:]

    /// Its height map at `size` a side (nil without one), decoded once.
    package func heightField(size: Int = 256) -> HeightField? {
        let key = "\(name) \(size)"
        TextureSet.lock.lock()
        if let known = TextureSet.heights[key] { TextureSet.lock.unlock(); return known }
        TextureSet.lock.unlock()
        guard let g = gray(.height, size: size) else { return nil }
        let field = HeightField(side: size, values: g.pixels.map { Float($0) / 255 })
        TextureSet.lock.lock()
        TextureSet.heights[key] = field
        TextureSet.lock.unlock()
        return field
    }

    /// Its albedo's mean colour, linear (where it is opaque, for an atlas: its leaves'), worked out once.
    package func meanColor() -> SIMD3<Float> {
        TextureSet.lock.lock()
        if let known = TextureSet.means[name] { TextureSet.lock.unlock(); return known }
        TextureSet.lock.unlock()
        var mean = SIMD3<Float>(repeating: 0.4)
        if let url = url(.albedo), let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let n = 64
            var rgba = [UInt8](repeating: 0, count: n * n * 4)
            let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
                return true
            }
            let opacity = gray(.opacity, size: n)
            if drawn {
                func linear(_ v: UInt8) -> Float { let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
                var sum = SIMD3<Float>.zero, weight: Float = 0
                for i in 0..<(n * n) {
                    let w: Float = opacity.map { $0.pixels[i] > 200 ? 1 : 0 } ?? 1
                    sum += w * SIMD3(linear(rgba[4 * i]), linear(rgba[4 * i + 1]), linear(rgba[4 * i + 2]))
                    weight += w
                }
                if weight > 0 { mean = sum / weight }
            }
        }
        TextureSet.lock.lock()
        TextureSet.means[name] = mean
        TextureSet.lock.unlock()
        return mean
    }
    private static var means: [String: SIMD3<Float>] = [:]

    /// Its occlusion, roughness and height in one texture (R = AO, G = roughness, B = metallic 0, A = height): what a
    /// material's metallic-roughness slot holds (the height rides along for the terrain's height blend). Missing maps
    /// are white AO, roughness 0.85, height 0.5. The roughness is remapped into `minRoughness`...1 (some scans' maps are
    /// far glossier than the ground looks: grass at 0.26).
    package func ormh(minRoughness: Float = 0) -> GeneratedImage? {
        guard let rough = gray(.roughness) ?? gray(.albedo) else { return nil }
        let w = rough.width, h = rough.height
        let ao = gray(.ao, size: w, height: h), height = gray(.height, size: w, height: h)
        let hasRough = url(.roughness) != nil
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[4 * i] = ao.map { $0.pixels[i] } ?? 255
            pixels[4 * i + 1] = hasRough ? UInt8(minRoughness * 255 + (1 - minRoughness) * Float(rough.pixels[i]) + 0.5) : 217
            pixels[4 * i + 2] = 0
            pixels[4 * i + 3] = height.map { $0.pixels[i] } ?? 128
        }
        return GeneratedImage(width: w, height: h, pixels: pixels)
    }
}
