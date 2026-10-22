import CoreGraphics
import EngineCore
import Foundation
import ImageIO
import Physics
import Plants
import UniformTypeIdentifiers

/// A photo-scanned material from a download (a Poly Haven or ambientCG .zip, or its folder of maps) as a Material
/// Designer graph of Bitmap nodes. The maps are found by their file names (`rock_wall_17_nor_gl_4k.exr`,
/// `Rock030_4K-JPG_NormalGL.jpg`: the names Tools/textures/fetch.py knows), copied into `Assets/Textures/<slug>/` as
/// `albedo`, `normal`, `roughness`… with an `info.json`; an EXR becomes a 16-bit PNG on the way (EXRImage reads the
/// compressions macOS can't, Poly Haven's DWA). What is missing is made from the height: the normal, the occlusion.
/// The Designer's "Import Scanned Material…" (MaterialEditorModel.importScan); the built-in scans
/// (MaterialLibrary+Scans.swift) are graphs of the same shape.
package enum ScanMaterial {
    package enum Map: String, CaseIterable { case albedo, normal, roughness, height, ao, metallic, opacity, arm }

    /// The maps found in a download: each one's file, and whether the normal is DirectX's (green flipped).
    package struct Maps: Equatable {
        var files: [Map: URL] = [:]
        var normalDirectX = false
    }

    /// File name words (lower case; two words joined too: `nor_gl` is "norgl") naming each map. A name's last such word
    /// decides (`metal_plate_diff`: the colour).
    private static let words: [String: Map] = {
        var w: [String: Map] = [:]
        let table: [(Map, [String])] = [
            (.albedo, ["diff", "diffuse", "albedo", "color", "colour", "basecolor", "basecolour", "col"]),
            (.normal, ["norgl", "normalgl", "nor", "normal", "nrm", "nordx", "normaldx"]),
            (.roughness, ["rough", "roughness"]),
            (.height, ["disp", "displacement", "height"]),
            (.ao, ["ao", "ambientocclusion", "occlusion"]),
            (.metallic, ["metal", "metallic", "metalness"]),
            (.opacity, ["opacity", "alpha"]),
            (.arm, ["arm"]),
        ]
        for (m, names) in table { for n in names { w[n] = m } }
        return w
    }()
    package static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "exr", "tif", "tiff"]

    /// The map a file is, and whether it is a DirectX normal (nil: not a map: a preview, the .blend).
    package static func map(of file: URL) -> (Map, directX: Bool)? {
        guard imageExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        let t = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for i in t.indices.reversed() {
            let pair = i > 0 ? t[i - 1] + t[i] : ""
            for w in [pair, t[i]] where !w.isEmpty {
                if let m = words[w] { return (m, w.hasSuffix("dx")) }
            }
        }
        return nil
    }

    /// The maps in `folder` and below. Of two files for one map: the OpenGL normal before the DirectX one, then PNG,
    /// EXR, TIFF, JPEG (the most bits first).
    package static func detect(in folder: URL) -> Maps {
        let rank = ["png": 0, "exr": 1, "tif": 2, "tiff": 2, "jpg": 3, "jpeg": 3]
        var best: [Map: (URL, directX: Bool, rank: Int)] = [:]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }.sorted { $0.path < $1.path } ?? []
        for f in files {
            guard let (m, dx) = map(of: f) else { continue }
            let r = (dx ? 10 : 0) + (rank[f.pathExtension.lowercased()] ?? 9)
            if let b = best[m], b.rank <= r { continue }
            best[m] = (f, dx, r)
        }
        var maps = Maps()
        for (m, b) in best { maps.files[m] = b.0 }
        maps.normalDirectX = best[.normal]?.directX ?? false
        return maps
    }

    /// A download's name as a material's: `rock_wall_17_4k.blend.zip` is "Rock Wall 17".
    package static func suggestedName(for source: URL) -> String {
        var name = source.lastPathComponent
        while let dot = name.lastIndex(of: "."), ["zip", "blend", "gltf", "usdc", "usda"].contains(name[name.index(after: dot)...].lowercased()) {
            name = String(name[..<dot])
        }
        let words = name.split { !$0.isLetter && !$0.isNumber }.filter { w in
            let l = w.lowercased()
            return !["jpg", "png", "exr", "blend", "gltf"].contains(l) && !(l.hasSuffix("k") && Int(l.dropLast()) != nil)
        }
        return words.isEmpty ? "Scan" : words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The side of one repeat a download says (an `info.json` with "metres", as Tools/textures/fetch.py writes), if any.
    package static func metres(in folder: URL) -> Float? {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for f in files where f.lastPathComponent == "info.json" {
            if let data = try? Data(contentsOf: f), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let m = info["metres"] as? Double, m > 0 { return Float(m) }
        }
        return nil
    }

    // MARK: - The graph

    /// Bitmap nodes into the outputs: `paths` each map's file (relative to Assets/, or absolute). Without a normal map,
    /// the normal is made from the height; without an occlusion map, the occlusion. A packed ARM map (glTF's: occlusion,
    /// roughness, metallic) fills what has no map of its own. `metres`: the side of one repeat.
    package static func graph(name: String, paths: [Map: String], normalDirectX: Bool = false, metres: Float, size: Int) -> MaterialGraph {
        var b = MatBuilder(name, size: size)
        func bitmap(_ m: Map, grey: Bool) -> MatBuilder.Ref? {
            paths[m].map { b.node(.bitmap, ["path": .text($0), "channel": .choice(grey ? "luminance" : "color")], id: m.rawValue) }
        }
        let color = bitmap(.albedo, grey: false)
        let height = bitmap(.height, grey: true)
        let needsARM = paths[.ao] == nil || paths[.roughness] == nil || paths[.metallic] == nil
        let arm = needsARM ? bitmap(.arm, grey: false).map { b.node(.rgbaSplit, [:], ["in": $0]) } : nil
        if let color { b.output(.baseColor, color) }
        if let height { b.output(.height, height) }
        if let n = bitmap(.normal, grey: false) {
            b.output(.normal, n)
        } else if let height {
            b.output(.normal, b.node(.normal, ["intensity": .float(4)], ["in": height]))
        }
        if let r = bitmap(.roughness, grey: true) ?? arm?["g"] { b.output(.roughness, r) }
        if let m = bitmap(.metallic, grey: true) ?? arm?["b"] { b.output(.metallic, m) }
        if let o = bitmap(.opacity, grey: true) { b.output(.opacity, o) }
        let depth: Float = 0.04
        if let ao = bitmap(.ao, grey: true) ?? arm?["r"] {
            b.output(.ambientOcclusion, ao)
        } else if let height {
            b.output(.ambientOcclusion, b.node(.ambientOcclusion, ["radius": .float(0.02), "depth": .float(depth)], ["in": height]))
        }
        b.set {
            $0.surface.uvScale = 1 / max(metres, 0.01)
            $0.surface.normalDirectX = normalDirectX && paths[.normal] != nil
            $0.surface.heightDepth = height != nil ? depth : 0
            // Real displacement a twentieth of the repeat, black to white (Rock Wall 17: 9 cm over its 1.8 m).
            if height != nil { $0.surface.displacement = 0.05 * metres }
        }
        return b.graph
    }

    // MARK: - Importing

    package struct Imported {
        package let graph: MaterialGraph
        /// The folder the maps were copied into.
        package let folder: URL
        /// What was found but not used (a map that couldn't be read), to say.
        package let skipped: [String]
    }

    /// Copies the maps of `source` (a .zip, or a folder) into `texturesRoot/<slug of name>/` (a new folder: an earlier
    /// import's stays as it is, so no bake's cache of it goes stale) and makes their graph. Throws if no colour map is
    /// found. Bitmap paths are relative to Assets/ when the folder is in it.
    package static func install(from source: URL, name: String, metres: Float, texturesRoot: URL) throws -> Imported {
        let fm = FileManager.default
        var folder = source
        var unpacked: URL?
        defer { if let unpacked { try? fm.removeItem(at: unpacked) } }
        if source.pathExtension.lowercased() == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("scan-import-\(UUID().uuidString)")
            try unzip(source, into: tmp)
            unpacked = tmp
            folder = tmp
        }
        let maps = detect(in: folder)
        guard maps.files[.albedo] != nil else {
            throw MatError("no colour map (…_diff…, …_Color…, albedo…) in \(source.lastPathComponent)")
        }
        let slug = VFXEffect.slug(name)
        var dest = texturesRoot.appendingPathComponent(slug)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = texturesRoot.appendingPathComponent("\(slug)-\(n)"); n += 1 }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            var paths: [Map: String] = [:]
            var skipped: [String] = []
            var sources: [String: String] = [:]
            for m in Map.allCases {
                guard let file = maps.files[m] else { continue }
                let ext = file.pathExtension.lowercased()
                let out = dest.appendingPathComponent(m.rawValue + "." + (ext == "exr" ? "png" : ext == "jpeg" ? "jpg" : ext))
                do {
                    if ext == "exr" { try convertEXR(file, to: out, srgb: m == .albedo) } else { try fm.copyItem(at: file, to: out) }
                } catch {
                    if m == .albedo { throw error }
                    skipped.append("\(file.lastPathComponent) (\((error as? MatError)?.description ?? error.localizedDescription))")
                    continue
                }
                paths[m] = assetPath(out)
                sources[m.rawValue] = file.lastPathComponent
            }
            let info: [String: Any] = ["source": "import", "from": source.lastPathComponent, "metres": Double(metres), "maps": sources]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                .write(to: dest.appendingPathComponent("info.json"))
            let width = imageWidth(dest.appendingPathComponent(URL(fileURLWithPath: paths[.albedo]!).lastPathComponent)) ?? 1024
            let size = min(max(Int(log2(Double(width)).rounded()), 8), 12)
            let g = graph(name: name, paths: paths, normalDirectX: maps.normalDirectX, metres: metres, size: size)
            return Imported(graph: g, folder: dest, skipped: skipped)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// `url`'s path as a Bitmap node names it: relative to Assets/ when it is in it.
    package static func assetPath(_ url: URL) -> String {
        let root = Scene.assetsDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private static func unzip(_ zip: URL, into folder: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let why = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MatError("\(zip.lastPathComponent) couldn't be unpacked: \(why.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func imageWidth(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyPixelWidth] as? Int
    }

    /// An EXR as a 16-bit PNG (values clamped to 0…1): its R, G, B as a colour, or its one channel (Y, or whichever) as a
    /// grey; `srgb`: the values are linear colours, written as sRGB (a colour map: the graph works in sRGB values).
    package static func convertEXR(_ exr: URL, to png: URL, srgb: Bool) throws {
        let image = try EXRImage.read(exr)
        let w = image.width, h = image.height
        let rgb = ["R", "G", "B"].compactMap { image.channel($0) }
        let planes = rgb.count == 3 ? rgb : [image.channel("Y") ?? image.channels.values.first!]
        let channels = planes.count
        var words = [UInt16](repeating: 0, count: w * h * channels)
        for c in 0..<channels {
            let p = planes[c]
            for i in 0..<(w * h) {
                var v = min(max(p[i], 0), 1)
                if srgb { v = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
                words[i * channels + c] = UInt16((v * 65535).rounded())
            }
        }
        let space = channels == 1 ? CGColorSpace(name: CGColorSpace.linearGray)! : CGColorSpace(name: srgb ? CGColorSpace.sRGB : CGColorSpace.linearSRGB)!
        guard let provider = CGDataProvider(data: words.withUnsafeBytes { Data($0) } as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16 * channels, bytesPerRow: w * channels * 2, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MatError("\(png.lastPathComponent) couldn't be made")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw MatError("\(png.lastPathComponent) wasn't written") }
    }
}
