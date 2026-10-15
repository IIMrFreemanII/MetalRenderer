import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// A generated, tiling surface: what a building's wall, a roof or a pavement is made of.
enum SurfaceKind: Int, CaseIterable, Hashable {
    case brick, plaster, concrete, rooftile, asphalt, paving, metalpanel

    /// The side of one repeat of its texture, in metres.
    var tile: Float {
        switch self {
        case .brick: return 2.0         // 8 bricks x 24 courses
        case .plaster: return 3.0
        case .concrete: return 4.0      // 2 x 2 formwork panels
        case .rooftile: return 2.0      // 8 x 6 tiles
        case .asphalt: return 5.0
        case .paving: return 2.4        // 4 x 4 slabs
        case .metalpanel: return 2.4    // 6 standing seams
        }
    }

    /// Its maps' side in pixels: the ones with fine, regular detail are bigger.
    var size: Int {
        switch self {
        case .brick, .rooftile, .paving: return 1024
        case .plaster, .concrete, .asphalt, .metalpanel: return 512
        }
    }

    /// How deep its relief is, in metres (the height map's 1): the normal map's strength.
    var relief: Float {
        switch self {
        case .brick: return 0.008
        case .plaster: return 0.003
        case .concrete: return 0.004
        case .rooftile: return 0.03
        case .asphalt: return 0.004
        case .paving: return 0.006
        case .metalpanel: return 0.02
        }
    }

    /// It has a roughness map too (the others are plain diffuse surfaces, where one would do nothing).
    var hasRoughness: Bool { self == .metalpanel }
}

/// Written by name (building styles' files).
extension SurfaceKind: Codable {
    init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let found = SurfaceKind.allCases.first(where: { "\($0)" == name }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no surface \(name)"))
        }
        self = found
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode("\(self)")
    }
}

/// The city's textures, made on the CPU: for each `SurfaceKind` a base-colour map, a normal map and, for the one
/// with a specular lobe, a roughness map, all tiling. The base colours are near white, so a material's own colour
/// tints them and the buildings of a street share a few textures. Seeded and pure: the same pixels every time.
///
/// `sources` hands them to the scene as PNGs that are made once and kept in the user's cache folder (a new
/// `version` or size makes new files); each kind's maps name its base PNG as their model, so the texture streamer
/// keeps a mip-chain cache per kind next to it and later launches only read.
enum ProceduralTextures {
    /// Bump this when what `generate` draws changes.
    static let version = 1

    /// One kind's maps, `size` x `size` RGBA bytes each, rows from the top.
    struct Maps {
        var size: Int
        var base: [UInt8]           // sRGB
        var normal: [UInt8]         // tangent space, +Y = +V (down the image)
        var roughness: [UInt8]?     // G = roughness, B = metallic (both scale the material's), as glTF's
    }

    // MARK: - Noise

    private static func hash(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 0x9E37_79B1 ^ UInt32(truncatingIfNeeded: y) &* 0x85EB_CA77 ^ seed &* 0xC2B2_AE3D
        h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12; h = h &* 0x297A_2D39; h ^= h >> 15
        return Float(h >> 8) / Float(1 << 24)
    }

    /// Value noise in [0, 1] that repeats every `period` cells.
    private static func noise(_ p: SIMD2<Float>, period: Int, seed: UInt32) -> Float {
        let cell = SIMD2(p.x.rounded(.down), p.y.rounded(.down)), f = p - cell
        let s = f * f * (SIMD2(repeating: 3) - 2 * f)
        func at(_ dx: Int, _ dy: Int) -> Float {
            let x = (Int(cell.x) + dx) % period, y = (Int(cell.y) + dy) % period
            return hash(x < 0 ? x + period : x, y < 0 ? y + period : y, seed)
        }
        let a = at(0, 0) + (at(1, 0) - at(0, 0)) * s.x, b = at(0, 1) + (at(1, 1) - at(0, 1)) * s.x
        return a + (b - a) * s.y
    }

    /// `octaves` of it, the first with `cells` cells across the tile: in [0, 1], tiling.
    private static func fbm(_ uv: SIMD2<Float>, cells: Int, octaves: Int, seed: UInt32) -> Float {
        var sum: Float = 0, weight: Float = 0.5, total: Float = 0, c = cells
        for o in 0..<octaves {
            sum += weight * noise(uv * Float(c), period: c, seed: seed &+ UInt32(o) &* 131)
            total += weight
            weight *= 0.5
            c *= 2
        }
        return sum / total
    }

    // MARK: - The surfaces

    /// A point of a surface: its height (0...1, x `relief`), base colour, roughness.
    private typealias Sample = (height: Float, color: SIMD3<Float>, roughness: Float)

    /// How far `t` (0...1 across a cell) is inside the cell, 0 in a joint of width `joint` at its edges and 1 a
    /// joint's width further in: the joints' rounded shoulders.
    private static func inside(_ t: Float, joint: Float) -> Float {
        let d = min(t, 1 - t)
        return simd_smoothstep(joint * 0.5, joint * 1.5, d)
    }

    private static func sample(_ kind: SurfaceKind, _ uv: SIMD2<Float>) -> Sample {
        switch kind {
        case .brick:
            // Running bond: 24 courses of 8 bricks, every other course half a brick along.
            let row = (uv.y * 24).rounded(.down), shift: Float = Int(row) % 2 == 0 ? 0 : 0.5
            let x = uv.x * 8 + shift, column = x.rounded(.down)
            let face = min(inside(x - column, joint: 0.04), inside(uv.y * 24 - row, joint: 0.13))
            let tone = hash(Int(column) % 8, Int(row), 7), grain = fbm(uv, cells: 64, octaves: 3, seed: 11)
            let brick = SIMD3<Float>(1, 0.93, 0.88) * (0.72 + 0.22 * tone + 0.1 * (grain - 0.5))
            let mortar = SIMD3<Float>(0.86, 0.98, 1.0) * (0.86 + 0.1 * grain)
            return (face * (0.85 + 0.15 * grain), mortar + (brick - mortar) * face, 0.9)
        case .plaster:
            let coarse = fbm(uv, cells: 4, octaves: 4, seed: 21), fine = fbm(uv, cells: 48, octaves: 3, seed: 23)
            return (0.6 * fine + 0.4 * coarse, SIMD3(repeating: 0.86 + 0.1 * coarse + 0.06 * (fine - 0.5)), 0.95)
        case .concrete:
            // 2 x 2 formwork panels with their seams and tie holes, and stains running down.
            let p = uv * 2, cell = SIMD2(p.x.rounded(.down), p.y.rounded(.down)), f = p - cell
            let seam = min(inside(f.x, joint: 0.006), inside(f.y, joint: 0.006))
            let hole = [SIMD2<Float>(0.2, 0.25), SIMD2(0.8, 0.25), SIMD2(0.2, 0.75), SIMD2(0.8, 0.75)]
                .map { simd_smoothstep(0.012, 0.02, distance(f, $0)) }.min()!
            let stain = fbm(SIMD2(uv.x * 4, uv.y), cells: 8, octaves: 4, seed: 31), fine = fbm(uv, cells: 64, octaves: 3, seed: 33)
            let tone = 0.84 + 0.05 * hash(Int(cell.x), Int(cell.y), 37) + 0.1 * (stain - 0.5) + 0.05 * (fine - 0.5)
            return (seam * hole * (0.8 + 0.2 * fine), SIMD3(repeating: tone * (0.8 + 0.2 * seam * hole)), 0.85)
        case .rooftile:
            // 6 rows of 8 tiles, each row over the one below it and half a tile along: a tile is round across and
            // rises toward its lower edge.
            let rows = uv.y * 6, row = rows.rounded(.down), down = rows - row
            let x = uv.x * 8 + (Int(row) % 2 == 0 ? 0 : 0.5), column = x.rounded(.down)
            let round = sin((x - column) * .pi)
            let tone = hash(Int(column) % 8, Int(row), 41), grain = fbm(uv, cells: 32, octaves: 3, seed: 43)
            let lip = simd_smoothstep(0, 0.06, down)   // the step up from the row above
            return ((0.35 + 0.65 * down) * (0.55 + 0.45 * round) * lip, SIMD3<Float>(1, 0.95, 0.92) * (0.74 + 0.2 * tone + 0.08 * (grain - 0.5))
                    * (0.75 + 0.25 * lip), 0.7 + 0.3 * grain)
        case .asphalt:
            let grit = fbm(uv, cells: 128, octaves: 2, seed: 51), patch = fbm(uv, cells: 3, octaves: 4, seed: 53)
            return (grit, SIMD3(repeating: 0.72 + 0.2 * (grit - 0.5) + 0.2 * (patch - 0.5)), 0.95)
        case .paving:
            // 4 x 4 slabs.
            let p = uv * 4, cell = SIMD2(p.x.rounded(.down), p.y.rounded(.down)), f = p - cell
            let slab = min(inside(f.x, joint: 0.02), inside(f.y, joint: 0.02))
            let tone = hash(Int(cell.x), Int(cell.y), 61), fine = fbm(uv, cells: 64, octaves: 3, seed: 63)
            return (slab * (0.85 + 0.15 * fine), SIMD3(repeating: (0.82 + 0.12 * tone + 0.08 * (fine - 0.5)) * (0.6 + 0.4 * slab)), 0.9)
        case .metalpanel:
            // Sheets with 6 standing seams, and a faint streaking along them.
            let x = uv.x * 6, t = x - x.rounded(.down)
            let seam = 1 - simd_smoothstep(0.03, 0.07, min(t, 1 - t))
            let streak = fbm(SIMD2(uv.x * 8, uv.y), cells: 8, octaves: 3, seed: 71)
            return (seam, SIMD3(repeating: 0.88 + 0.1 * (streak - 0.5)), 0.75 + 0.25 * streak)
        }
    }

    /// `kind`'s maps at `size` pixels a side (its own size by default).
    static func generate(_ kind: SurfaceKind, size: Int? = nil) -> Maps {
        let n = size ?? kind.size
        var heights = [Float](repeating: 0, count: n * n)
        var maps = Maps(size: n, base: [UInt8](repeating: 255, count: n * n * 4), normal: [UInt8](repeating: 255, count: n * n * 4),
                        roughness: kind.hasRoughness ? [UInt8](repeating: 255, count: n * n * 4) : nil)
        func byte(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255 + 0.5) }
        func srgb(_ v: Float) -> UInt8 { byte(pow(min(max(v, 0), 1), 1 / 2.2)) }
        for y in 0..<n {
            for x in 0..<n {
                let s = sample(kind, (SIMD2(Float(x), Float(y)) + 0.5) / Float(n)), i = (y * n + x) * 4
                heights[y * n + x] = s.height
                (maps.base[i], maps.base[i + 1], maps.base[i + 2]) = (srgb(s.color.x), srgb(s.color.y), srgb(s.color.z))
                if maps.roughness != nil { (maps.roughness![i], maps.roughness![i + 1], maps.roughness![i + 2]) = (255, byte(s.roughness), 255) }
            }
        }
        // The normal map: the height's slope in metres per metre, across the tile's seams too.
        let scale = kind.relief / (2 * kind.tile / Float(n))
        for y in 0..<n {
            for x in 0..<n {
                let dx = heights[y * n + (x + 1) % n] - heights[y * n + (x + n - 1) % n]
                let dy = heights[((y + 1) % n) * n + x] - heights[((y + n - 1) % n) * n + x]
                let normal = normalize(SIMD3(-dx * scale, -dy * scale, 1)), i = (y * n + x) * 4
                (maps.normal[i], maps.normal[i + 1], maps.normal[i + 2]) = (byte(normal.x * 0.5 + 0.5), byte(normal.y * 0.5 + 0.5), byte(normal.z * 0.5 + 0.5))
            }
        }
        return maps
    }

    // MARK: - Files

    /// `pixels` (RGBA, `size` x `size`) as a PNG. Nil if ImageIO refuses.
    static func png(_ pixels: [UInt8], size: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Where the PNGs are kept.
    static let folder: URL = {
        let folder = CacheFile.userFolder.appendingPathComponent("textures")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// The scene's textures for `kinds`: each kind's base colour, normal and (if it has one) roughness map, read from
    /// `folder` or made and written there first (the missing kinds in parallel). A kind that can't be made or
    /// written is left out.
    static func sources(_ kinds: [SurfaceKind], in folder: URL = ProceduralTextures.folder, size: Int? = nil)
        -> [SurfaceKind: (base: Scene.TextureSource, normal: Scene.TextureSource, roughness: Scene.TextureSource?)] {
        func url(_ kind: SurfaceKind, _ map: String) -> URL {
            folder.appendingPathComponent("\(kind)-\(size ?? kind.size)-g\(version)-\(map).png")
        }
        func maps(_ kind: SurfaceKind) -> [String] { kind.hasRoughness ? ["base", "normal", "roughness"] : ["base", "normal"] }
        let missing = kinds.filter { kind in maps(kind).contains { !FileManager.default.fileExists(atPath: url(kind, $0).path) } }
        if !missing.isEmpty {
            let start = CFAbsoluteTimeGetCurrent()
            DispatchQueue.concurrentPerform(iterations: missing.count) { i in
                let kind = missing[i], made = generate(kind, size: size)
                for (map, pixels) in [("base", made.base), ("normal", made.normal), ("roughness", made.roughness ?? [])] where !pixels.isEmpty {
                    guard let data = png(pixels, size: made.size) else { continue }
                    try? CacheFile.write(data, to: url(kind, map))
                }
            }
            print(String(format: "City textures: %@ generated in %.2f s (%@)", missing.map { "\($0)" }.joined(separator: ", "),
                         CFAbsoluteTimeGetCurrent() - start, folder.path))
        }
        var out: [SurfaceKind: (base: Scene.TextureSource, normal: Scene.TextureSource, roughness: Scene.TextureSource?)] = [:]
        for kind in kinds {
            // The base PNG stands for the kind's "model": the streamer's cache file is named after it.
            let model = url(kind, "base").path
            func source(_ map: String, srgb: Bool) -> Scene.TextureSource? {
                guard let data = try? Data(contentsOf: url(kind, map), options: .alwaysMapped) else { return nil }
                return Scene.TextureSource(data: data, srgb: srgb, name: "city/\(kind) \(map)", modelPath: model, cacheKey: map)
            }
            guard let base = source("base", srgb: true), let normal = source("normal", srgb: false) else { continue }
            out[kind] = (base, normal, kind.hasRoughness ? source("roughness", srgb: false) : nil)
        }
        return out
    }
}
