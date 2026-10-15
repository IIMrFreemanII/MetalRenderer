import CoreGraphics
import Foundation
import ImageIO
import simd

/// A photo-scanned material's maps in `Assets/Textures/<name>/` (Tools/textures/fetch.py: CC0 sets from Poly Haven and
/// ambientCG): albedo, normal (OpenGL: +Y = +V), roughness, ambient occlusion, height, and for an atlas its opacity, with
/// `info.json` saying how many metres one repeat is. What the realistic look (SceneSettings.realism) dresses the ground,
/// the rocks and the plants in; without them (a fresh clone, the tests, METALRENDERER_SCANS=0) it falls back to the
/// generated textures.
struct TextureSet {
    enum Map: String, CaseIterable { case albedo, normal, roughness, ao, height, opacity }

    let name: String
    let folder: URL
    /// The side of one repeat, metres (what the scan covers).
    let metres: Float

    /// Scans are used (METALRENDERER_SCANS=0: never, as if none were there).
    static let enabled = ProcessInfo.processInfo.environment["METALRENDERER_SCANS"] != "0"
    static var directory: URL { Scene.assetsDirectory.appendingPathComponent("Textures") }

    private static var found: [String: TextureSet?] = [:]
    private static let lock = NSLock()

    /// The set `name` if its albedo and normal are there.
    static func find(_ name: String) -> TextureSet? {
        guard enabled, !name.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let known = found[name] { return known }
        let folder = directory.appendingPathComponent(name)
        var set: TextureSet?
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("albedo.jpg").path),
           fm.fileExists(atPath: folder.appendingPathComponent("normal.jpg").path) {
            var metres: Float = 2
            if let data = try? Data(contentsOf: folder.appendingPathComponent("info.json")),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let m = info["metres"] as? Double {
                metres = Float(m)
            }
            set = TextureSet(name: name, folder: folder, metres: metres)
        }
        found[name] = set
        return set
    }

    func url(_ map: Map) -> URL? {
        let url = folder.appendingPathComponent(map.rawValue + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file the set's mip chains are cached by (TextureStreamer: one cache file per set, next to its maps).
    var cacheModel: String { folder.appendingPathComponent("info.json").path }

    /// A map's file, memory-mapped (the streamer reads it only to build its cache, the first time).
    func data(_ map: Map) -> Data? {
        url(map).flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
    }

    /// A map decoded to one channel (its luminance), `size` × `size` (nil: as it is; `height`: that many rows instead).
    /// Nil if there is none.
    func gray(_ map: Map, size: Int? = nil, height rows: Int? = nil) -> (pixels: [UInt8], width: Int, height: Int)? {
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

    /// Its albedo's mean colour, linear (where it is opaque, for an atlas: its leaves'), worked out once.
    func meanColor() -> SIMD3<Float> {
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
    func ormh(minRoughness: Float = 0) -> FoliageTextures.Image? {
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
        return FoliageTextures.Image(width: w, height: h, pixels: pixels)
    }
}

extension Scene {
    /// A scanned material (TextureSet `set`): its albedo (times `tint`), normal, and occlusion-roughness-height maps,
    /// tiled every `metres` of UV (nil: the scan's own size; a mesh's UVs are metres). Nil if the set isn't there.
    /// `roughness` scales the scan's (after it is raised to at least `minRoughness`: natural surfaces stay above
    /// REFLECTION_MAX_ROUGHNESS, where a traced reflection costs much and shows little); `ao` how much its occlusion darkens it.
    func addScanMaterial(_ name: String, tint: SIMD3<Float> = .one, roughness: Float = 1, ao: Float = 1, specular: Float = 1,
                         normalScale: Float = 1, minRoughness: Float = 0.7) -> Int? {
        guard let set = TextureSet.find(name), let albedoData = set.data(.albedo), let normalData = set.data(.normal) else { return nil }
        let model = set.cacheModel, floor = Int(minRoughness * 100)
        let known = scanTextures["\(name) \(floor)"] ?? scanTextures.first { $0.key.hasPrefix("\(name) ") }.map { SIMD3($0.value.x, $0.value.y, .max) }
        let albedo = known?.x ?? addTexture(TextureSource(data: albedoData, srgb: true, name: "scan/\(name)/albedo", modelPath: model, cacheKey: "albedo"))
        let normal = known?.y ?? addTexture(TextureSource(data: normalData, srgb: false, name: "scan/\(name)/normal", modelPath: model, cacheKey: "normal"))
        let side = Self.scanSize(set)
        let ormh = known.flatMap { $0.z == .max ? nil : $0.z } ?? addTexture(TextureSource(
            data: Data(), srgb: false, name: "scan/\(name)/ormh-\(floor)", modelPath: model, cacheKey: "ormh-v2-\(side.x)x\(side.y)-\(floor)",
            raw: (side.x, side.y), pixels: { Data(set.ormh(minRoughness: minRoughness)?.pixels ?? [UInt8](repeating: 255, count: side.x * side.y * 4)) }))
        scanTextures["\(name) \(floor)"] = SIMD3(albedo, normal, ormh)
        let index = addMaterial(GPUMaterial(albedo: SIMD4(tint, 0), emission: SIMD4(.zero, roughness), params: SIMD4(specular, normalScale, 0, 0),
                                            textures: SIMD4(albedo, ormh, normal, .max)))
        var extra = GPUMaterialExtra()
        extra.textures.z = 2   // a scan's (Surface.metal: its GI hits take its colour alone)
        extra.surface = SIMD4(0, 1, 0.5, ao)
        materialExtras[index] = extra
        return index
    }

    /// A leaf sheet's material (TextureSet "leaves": cells × cells leaves): each generated leaf shows one of them
    /// (Surface.metal, its extras' parallax minus the cells), two-sided where the camera sees it (LEAF_TRANSMIT).
    /// `albedo`: its colour over the sheet's (the season changes it: LeafMaterial.gain), `translucency` as a leaf's.
    func addLeafSheetMaterial(albedo: SIMD3<Float>, translucency: Float, cells: Int = 3) -> Int? {
        guard let index = addScanMaterial("leaves", tint: albedo, roughness: 1, ao: 0, specular: 0.6, normalScale: 0.7, minRoughness: 0.62)
        else { return nil }
        var m = materials[index]
        m.params.w = translucency
        setMaterial(index, m)
        materialExtras[index]?.surface.x = -Float(cells)
        hasLeafSheets = true
        return index
    }

    /// Leaves of the realistic look that aren't a sheet's (grass, needles, fronds): each its own shade, two-sided where
    /// the camera sees it, fluttering (Surface.metal leafLook).
    func markRealisticLeaf(_ index: Int) {
        var extra = materialExtras[index] ?? GPUMaterialExtra()
        extra.surface.x = -0.25
        materialExtras[index] = extra
        hasLeafSheets = true
    }

    /// The size of a set's roughness (what its packed map is drawn at), read from the file's header.
    static func scanSize(_ set: TextureSet) -> SIMD2<Int> {
        guard let url = set.url(.roughness) ?? set.url(.albedo), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return [2048, 2048] }
        return [w, h]
    }
}
