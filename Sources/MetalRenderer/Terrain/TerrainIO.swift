import Characters
import CoreGraphics
import Effects
import EngineCore
import Foundation
import ImageIO
import Materials
import Physics
import Plants
import UniformTypeIdentifiers
import simd

/// Heightmaps and splat maps in and out of a terrain: 16-bit grey PNGs and 32-bit float EXRs (what World Machine,
/// Gaea and the like read and write), and RGBA PNGs of the layers' weights (four layers a picture). A region of the
/// terrain's samples is a picture's pixels, corner to corner; a picture of another size is resampled onto it.
package enum TerrainIO {
    package enum Format: String, CaseIterable, Codable {
        case png16, exr
        package var fileExtension: String { self == .png16 ? "png" : "exr" }
    }

    /// How imported heights become the ground: the picture's 0...1 as `low`...`high` metres (absolute), added to the
    /// ground times `scale` metres (additive, mid-grey 0), or blended with it by `amount` (absolute heights, mixed).
    package enum ImportMode: Equatable {
        case absolute(low: Float, high: Float)
        case additive(scale: Float)
        case blend(low: Float, high: Float, amount: Float)
    }

    /// A region of samples, `lo`...`hi` (inclusive).
    package struct Region: Equatable, Codable {
        package var lo: SIMD2<Int>
        package var hi: SIMD2<Int>
        package var size: SIMD2<Int> { hi &- lo &+ 1 }

        /// The whole terrain if it has an edge; else these tiles.
        package static func of(_ grid: TerrainGrid, tiles: [SIMD2<Int>]) -> Region? {
            if let lo = grid.lo, let hi = grid.hi, tiles.isEmpty { return Region(lo: lo, hi: hi) }
            guard let first = tiles.first else { return nil }
            var lo = grid.firstSample(first), hi = lo &+ grid.tileCells
            for t in tiles {
                lo = simd_min(lo, grid.firstSample(t))
                hi = simd_max(hi, grid.firstSample(t) &+ grid.tileCells)
            }
            if let glo = grid.lo, let ghi = grid.hi { lo = simd_max(lo, glo); hi = simd_min(hi, ghi) }
            return Region(lo: lo, hi: hi)
        }
    }

    /// What is written beside an exported heightmap: where its pixels are and what their values mean.
    package struct Sidecar: Codable {
        var terrain: String
        var region: Region
        var cell: Float
        var origin: SIMD2<Double>          // the world's place of the region's first sample
        var low: Float, high: Float        // metres that 0 and 1 (16-bit: 0 and 65535) are; EXR holds metres as they are
        var format: Format
    }

    package enum Failure: Error, CustomStringConvertible {
        case unreadable(String), unwritable(String), empty
        package var description: String {
            switch self {
            case .unreadable(let s): return "can't read \(s)"
            case .unwritable(let s): return "can't write \(s)"
            case .empty: return "nothing to export"
            }
        }
    }

    // MARK: - Out

    /// The region's heights as a picture (and its sidecar, `<name>.json`): a 16-bit PNG spans its lowest to its highest
    /// height, an EXR holds metres.
    @discardableResult
    package static func exportHeights(_ s: TerrainSnapshot, terrain: String, region r: Region, to url: URL, format: Format) throws -> Sidecar {
        let size = r.size
        guard size.x > 0, size.y > 0 else { throw Failure.empty }
        let h = s.heights(from: r.lo, count: size, step: 1)
        let low = h.min() ?? 0, high = max(h.max() ?? 1, low + 1e-3)
        switch format {
        case .png16:
            var px = [UInt16](repeating: 0, count: h.count)
            for k in h.indices { px[k] = UInt16((min(max((h[k] - low) / (high - low), 0), 1) * 65535).rounded()).bigEndian }
            try write(px.withUnsafeBytes { Data($0) }, width: size.x, height: size.y, bits: 16, components: 1, float: false,
                      type: UTType.png, to: url)
        case .exr:
            try write(h.withUnsafeBytes { Data($0) }, width: size.x, height: size.y, bits: 32, components: 1, float: true,
                      type: UTType("com.ilm.openexr-image") ?? .png, to: url)
        }
        let side = Sidecar(terrain: terrain, region: r, cell: s.grid.cell, origin: s.grid.place(r.lo.x, r.lo.y), low: low, high: high,
                           format: format)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(side).write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        return side
    }

    /// The region's layer weights as they show (the rules' with the paint over them): four RGBA PNGs, layers 0-3, 4-7,
    /// 8-11 and 12-15, `<stem>-layers-0-3.png` and on.
    package static func exportWeights(_ s: TerrainSnapshot, layers: [TerrainLayer], region r: Region, to stem: URL) throws -> [URL] {
        let size = r.size
        guard size.x > 0, size.y > 0 else { throw Failure.empty }
        let h = s.heights(from: r.lo &- 1, count: size &+ 2, step: 1), w = size.x + 2
        var maps = [[UInt8]](repeating: [UInt8](repeating: 0, count: size.x * size.y * 4), count: 4)
        for j in 0..<size.y {
            for i in 0..<size.x {
                let c = (j + 1) * w + i + 1
                let dx = h[c + 1] - h[c - 1], dz = h[c + w] - h[c - w]
                let slope = atan((dx * dx + dz * dz).squareRoot() / (2 * s.grid.cell)) * 180 / .pi
                let wt = TerrainPaint.weights(s, layers: layers, r.lo.x + i, r.lo.y + j, height: h[c], slope: slope)
                for l in 0..<16 { maps[l / 4][(j * size.x + i) * 4 + l % 4] = UInt8((min(max(wt[l], 0), 1) * 255).rounded()) }
            }
        }
        var urls: [URL] = []
        for m in 0..<4 {
            let url = URL(fileURLWithPath: stem.path + "-layers-\(m * 4)-\(m * 4 + 3).png")
            try write(Data(maps[m]), width: size.x, height: size.y, bits: 8, components: 4, float: false, type: UTType.png, to: url,
                      alpha: true)
            urls.append(url)
        }
        return urls
    }

    private static func write(_ data: Data, width: Int, height: Int, bits: Int, components: Int, float: Bool, type: UTType, to url: URL,
                              alpha: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = components == 1 ? CGColorSpace(name: CGColorSpace.linearGray)! : CGColorSpace(name: CGColorSpace.sRGB)!
        var info: UInt32 = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
        if float { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
        else if bits == 16 { info |= CGBitmapInfo.byteOrder16Big.rawValue }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * components,
                                  bytesPerRow: width * bits * components / 8, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.unwritable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unwritable(url.lastPathComponent) }
    }

    // MARK: - In

    /// A picture's first channel as floats 0...1 (EXR: as stored), rows top to bottom, and its size.
    package static func read(_ url: URL) throws -> (values: [Float], width: Int, height: Int, float: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let w = image.width, h = image.height, float = image.bitmapInfo.contains(.floatComponents)
        // A grey picture of 16 or 8 bits: its own values, exactly.
        if image.colorSpace?.model == .monochrome, !float, image.bitsPerPixel == image.bitsPerComponent,
           image.bitsPerComponent == 16 || image.bitsPerComponent == 8, let data = image.dataProvider?.data as Data? {
            let row = image.bytesPerRow, big = image.bitmapInfo.contains(.byteOrder16Big)
            var out = [Float](repeating: 0, count: w * h)
            data.withUnsafeBytes { raw in
                for y in 0..<h {
                    for x in 0..<w {
                        if image.bitsPerComponent == 8 {
                            out[y * w + x] = Float(raw[y * row + x]) / 255
                        } else {
                            let a = UInt16(raw[y * row + 2 * x]), b = UInt16(raw[y * row + 2 * x + 1])
                            let v = big ? a << 8 | b : b << 8 | a
                            out[y * w + x] = Float(v) / 65535
                        }
                    }
                }
            }
            return (out, w, h, false)
        }
        // Floats (an EXR): its first colour channel as stored, metres beyond 0...1 too.
        if float, image.bitsPerComponent == 32 || image.bitsPerComponent == 16, let data = image.dataProvider?.data as Data? {
            let bpc = image.bitsPerComponent / 8, components = image.bitsPerPixel / image.bitsPerComponent, row = image.bytesPerRow
            let first = image.alphaInfo == .first || image.alphaInfo == .premultipliedFirst || image.alphaInfo == .noneSkipFirst ? 1 : 0
            let channel = min(first, components - 1)
            var out = [Float](repeating: 0, count: w * h)
            data.withUnsafeBytes { raw in
                for y in 0..<h {
                    for x in 0..<w {
                        let at = y * row + (x * components + channel) * bpc
                        if bpc == 4 {
                            out[y * w + x] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                        } else {
                            out[y * w + x] = Float(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
                        }
                    }
                }
            }
            return (out, w, h, true)
        }
        // Drawn into one float channel: 16-bit greys keep their precision, colours become their luminance.
        var out = [Float](repeating: 0, count: w * h)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.linearGray)!,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw Failure.unreadable(url.lastPathComponent) }
        return (out, w, h, float)
    }

    /// A picture's RGBA as bytes, rows top to bottom.
    package static func readRGBA(_ url: URL) throws -> (bytes: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        // 8-bit RGBA with its alpha not premultiplied (as this writes them): its bytes as they are.
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .last, let data = image.dataProvider?.data as Data? {
            let row = image.bytesPerRow
            data.withUnsafeBytes { raw in
                for y in 0..<h { for x in 0..<(w * 4) { out[y * w * 4 + x] = raw[y * row + x] } }
            }
            return (out, w, h)
        }
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw Failure.unreadable(url.lastPathComponent) }
        return (out, w, h)
    }

    /// Bilinear sample of a picture (rows top to bottom as read; the region's first row is the picture's first) at
    /// `u`, `v` 0...1 across and down.
    @inline(__always) package static func sample(_ p: [Float], _ w: Int, _ h: Int, _ u: Float, _ v: Float) -> Float {
        let x = min(max(u * Float(w - 1), 0), Float(w - 1)), y = min(max(v * Float(h - 1), 0), Float(h - 1))
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1), fx = x - Float(x0), fy = y - Float(y0)
        let a = p[y0 * w + x0] + (p[y0 * w + x1] - p[y0 * w + x0]) * fx
        let b = p[y1 * w + x0] + (p[y1 * w + x1] - p[y1 * w + x0]) * fx
        return a + (b - a) * fy
    }

    /// Heights from a picture over the region (as `mode` says), kept for undo in `record`; protected ground stays.
    package static func importHeights(_ s: inout TerrainSnapshot, picture: (values: [Float], width: Int, height: Int, float: Bool), region r: Region,
                              mode: ImportMode, record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        let size = r.size, reading = s
        guard picture.width > 1, picture.height > 1, size.x > 1, size.y > 1 else { return [] }
        return TerrainSculpt.forEach(&s, lo: r.lo, hi: r.hi, record: &record) { i, j, base, delta in
            let u = Float(i - r.lo.x) / Float(size.x - 1), v = Float(j - r.lo.y) / Float(size.y - 1)
            let x = sample(picture.values, picture.width, picture.height, u, v)
            let now = base + delta
            var next: Float
            switch mode {
            case .absolute(let low, let high): next = picture.float ? x : low + (high - low) * x
            case .additive(let scale): next = now + (picture.float ? x : x - 0.5) * scale
            case .blend(let low, let high, let amount): next = now + ((picture.float ? x : low + (high - low) * x) - now) * amount
            }
            let keep = reading.protection(i, j)
            delta += (next - now) * (1 - keep)
        }
    }

    /// Layer weights from up to four RGBA pictures (layers 0-3, 4-7, ...; a missing one leaves its layers out),
    /// painted over the region as they say.
    package static func importWeights(_ s: inout TerrainSnapshot, pictures: [(bytes: [UInt8], width: Int, height: Int)?], region r: Region,
                              record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        let grid = s.grid, n = grid.tileCells, size = r.size
        guard size.x > 1, size.y > 1 else { return [] }
        var touched = Set<SIMD2<Int>>()
        for t in grid.tiles(from: r.lo, to: r.hi) {
            let first = grid.firstSample(t)
            let a = simd_max(r.lo, first), c = simd_min(r.hi, first &+ (n - 1))
            guard a.x <= c.x, a.y <= c.y else { continue }
            if record.before[t] == nil { record.before[t] = .some(s.tiles[t]) }
            var tile = s.tiles[t] ?? TerrainTile(cells: n)
            s.tiles[t] = nil
            if tile.paint == nil || tile.mask == nil {
                tile.paint = [UInt8](repeating: 0, count: n * n * TerrainTile.layers)
                tile.mask = [UInt8](repeating: 0, count: n * n)
            }
            for j in a.y...c.y {
                for i in a.x...c.x {
                    let u = Float(i - r.lo.x) / Float(size.x - 1), v = Float(j - r.lo.y) / Float(size.y - 1)
                    var w = SIMD16<Float>()
                    for (m, p) in pictures.enumerated() where m < 4 {
                        guard let p else { continue }
                        let x = min(Int((u * Float(p.width - 1)).rounded()), p.width - 1), y = min(Int((v * Float(p.height - 1)).rounded()), p.height - 1)
                        for ch in 0..<4 { w[m * 4 + ch] = Float(p.bytes[(y * p.width + x) * 4 + ch]) / 255 }
                    }
                    let sum = w.sum()
                    if sum <= 1e-4 { w[0] = 1 } else { w /= sum }
                    let k = (j - first.y) * n + (i - first.x)
                    for l in 0..<16 { tile.paint![k * 16 + l] = UInt8((w[l] * 255).rounded()) }
                    tile.mask![k] = 255
                }
            }
            tile.changed(a &- first, c &- first, cells: n)
            s.tiles[t] = tile
            touched.insert(t)
        }
        return touched
    }
}
