import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// The plants' textures, generated: bark that tiles around and along a stem, a leaf with its veins, a needle, a
/// blade of grass. Each is detail on top of its material's colour, which the seasons change: its mean is `mean`
/// (linear), and the material's colour is divided by that, so a plant keeps the brightness its colour gives it,
/// and its far voxels, which take the colour alone, match its triangles.
enum FoliageTextures {
    /// RGBA8 pixels, sRGB-encoded, rows from v = 0.
    struct Image {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    /// Every detail texture's mean, linear (GENERATED_TEXTURE_MEAN in Shaders/Surface.metal).
    static let mean: Float = 0.7

    enum Kind: Int, CaseIterable {
        case roughBark, birchBark, leaf, needle, grass
        var name: String { "\(self)" }
    }

    /// Of what `make` and the scenes' own generated textures draw (the forest's ground): the caches name a texture
    /// by this, not by its pixels, so that a cached one is never drawn at all. Whoever changes a pattern changes this
    /// (FoliageTests holds each texture's hash and fails otherwise).
    static let version = 1

    static func size(_ kind: Kind) -> (width: Int, height: Int) {
        switch kind {
        case .roughBark, .birchBark: return (256, 256)
        case .leaf: return (128, 128)
        case .needle: return (16, 32)
        case .grass: return (32, 64)
        }
    }

    static func make(_ kind: Kind) -> Image {
        let (w, h) = size(kind)
        switch kind {
        case .roughBark:
            // Plates with dark furrows between them, running along the stem, and a crack across now and then.
            return image(w, h, normalized: true) { u, v in
                let warp = 1.3 * noise(u * 3, v * 2, 3, 2, 5) + 0.5 * noise(u * 7, v * 6, 7, 6, 9)
                let edge = min(abs(noise(u * 9 + warp, v * 2, 9, 2, 1)), abs(noise(u * 14 - warp, v * 3, 14, 3, 11)) * 1.4)
                let furrow = 1 - min(edge / 0.07, 1)
                let crack = max(0, noise(u * 7, v * 30, 7, 30, 3) - 0.3) * 5
                let plate = 0.8 + 0.5 * noise(u * 30, v * 10, 30, 10, 2) + 0.4 * noise(u * 4, v * 3, 4, 3, 12)
                let shade = plate * (1 - 0.85 * furrow * furrow.squareRoot()) - crack
                return SIMD3(1, 0.93, 0.84) * max(shade, 0.05)
            }
        case .birchBark:
            // Pale and smooth, with dark dashes across it and a dark, rough patch here and there.
            return image(w, h, normalized: true) { u, v in
                let dash = max(0, noise(u * 3, v * 44, 3, 44, 4) - 0.14) * max(0, noise(u * 2, v * 7, 2, 7, 5) + 0.3)
                let patch = max(0, noise(u * 3, v * 2.5, 3, 3, 6) - 0.2)
                let shade = 0.95 + 0.1 * noise(u * 20, v * 20, 20, 20, 7) - 22 * dash - 4.5 * patch
                return SIMD3(repeating: min(max(shade, 0.06), 1))
            }
        case .leaf:
            // u across (the midrib at 0.5), v from the base to the tip: the midrib and side veins paler, the edge darker.
            return image(w, h, normalized: true) { u, v in leafShade(u, v) + SIMD3(repeating: 0.35 * noise(u * 4, v * 4, 4, 4, 8)) }
        case .needle:
            return image(w, h, normalized: true) { _, v in SIMD3(repeating: 0.6 + 0.4 * v) }
        case .grass:
            // Darker where it leaves the ground, with a pale midrib.
            return image(w, h, normalized: true) { u, v in
                let rib = max(0, 1 - abs(u - 0.5) / 0.12)
                let shade = 0.45 + 0.55 * v + 0.12 * rib
                return SIMD3(shade, shade, shade * (0.75 + 0.25 * v))
            }
        }
    }

    /// A leaf's detail at u across it (the midrib at 0.5) and v from its base to its tip.
    static func leafShade(_ u: Float, _ v: Float) -> SIMD3<Float> {
        let side = abs(u - 0.5) * 2
        let rib = max(0, 1 - side / 0.08)
        let along = (v * 6 - side * 2.2 + 8).truncatingRemainder(dividingBy: 1)
        let vein = max(0, 1 - abs(along - 0.5) / 0.1) * (1 - 0.5 * side)
        let shade = 0.62 - 0.3 * side * side + 0.5 * rib + 0.3 * vein
        return SIMD3(shade * (1 + 0.15 * rib), shade, shade * (1 - 0.25 * rib))
    }

    // MARK: - Cards

    /// The pictures a species' leaf cards show (Foliage.cards): `cells` x `cells` twigs with their leaves, each in
    /// its own square of the sheet, the twig running up the middle from the bottom edge. `alpha`: one byte per pixel,
    /// 255 where there is leaf or twig; the traversal tests it (Shaders/Intersect.metal), and the colours are an
    /// ordinary texture.
    struct CardSheet {
        var image: Image
        var alpha: [UInt8]
        var coverage: Float                 // the share of a card that is there
    }
    static let cardCells = 2
    static let cardSheetSize = 512          // CUTOUT_SIZE in Shaders/Intersect.metal

    /// A card's width and height (metres) for a twig `twig` long with these leaves: what one square of the sheet shows.
    static func cardSize(_ leaf: Foliage.LeafRecipe, twig: Float) -> SIMD2<Float> {
        SIMD2(2 * leaf.length * sin(min(leaf.angle, 1.25)) + leaf.width, twig + 0.9 * leaf.length)
    }

    static func cardSheet(_ leaf: Foliage.LeafRecipe, twig: Float, seed: UInt64) -> CardSheet {
        struct Leaf { var base: SIMD2<Float>; var along: SIMD2<Float>; var length: Float; var half: Float }
        let size = cardSize(leaf, twig: twig), cell = cardSheetSize / cardCells
        // Each square's leaves, in metres: x across from the twig, y up it. Left and right in turn; some point toward
        // or away from the viewer, and show shorter.
        var rng = SplitMix64(seed: seed)
        var cells: [[Leaf]] = []
        var bends: [SIMD2<Float>] = []
        for _ in 0..<cardCells * cardCells {
            let bend = SIMD2(rng.range(-0.06, 0.06), rng.range(0, 2 * .pi))
            func twigX(_ y: Float) -> Float { bend.x * twig * sin(y / twig * 2.2 + bend.y) * (y / twig) }
            var leaves: [Leaf] = []
            let count = max(Int(twig * (1 - leaf.start) * leaf.perMetre * 0.6), 2)
            for k in 0..<count {
                let y = twig * (leaf.start + (1 - leaf.start) * (Float(k) + 0.5) / Float(count))
                let angle = max(0.2, leaf.angle + rng.range(-1, 1) * leaf.angleV) * (k & 1 == 0 ? 1 : -1)
                let length = leaf.length * (1 + rng.range(-1, 1) * leaf.sizeV) * rng.range(0.6, 1)
                leaves.append(Leaf(base: SIMD2(twigX(y), y), along: SIMD2(sin(angle), cos(angle)), length: length,
                                   half: 0.5 * leaf.width * rng.range(0.75, 1)))
            }
            leaves.append(Leaf(base: SIMD2(twigX(twig), twig), along: SIMD2(rng.range(-0.2, 0.2), 1), length: leaf.length * 0.85,
                               half: 0.5 * leaf.width))
            cells.append(leaves)
            bends.append(bend)
        }
        // How wide a leaf is along it (0...1), as a share of its half width.
        func outline(_ s: Float) -> Float {
            switch leaf.shape {
            case .needle: return 1 - s
            case .kite: return s < 0.4 ? (s / 0.4).squareRoot() : (1 - s) / 0.6
            case .blade: return (sin(.pi * s)).squareRoot() * (0.85 + 0.15 * sin(s * 5 * .pi))
            }
        }
        let twigHalf = max(0.0035, 0.9 * size.y / Float(cell))
        let n = cardSheetSize
        var linear = [SIMD3<Float>](repeating: .zero, count: n * n)
        var alpha = [UInt8](repeating: 0, count: n * n)
        linear.withUnsafeMutableBufferPointer { colors in
            alpha.withUnsafeMutableBufferPointer { mask in
                DispatchQueue.concurrentPerform(iterations: n) { row in   // a row each: disjoint slots
                    let cy = row / cell, y = (Float(row % cell) + 0.5) / Float(cell) * size.y
                    for column in 0..<n {
                        let which = cy * cardCells + column / cell
                        let p = SIMD2(((Float(column % cell) + 0.5) / Float(cell) - 0.5) * size.x, y)
                        var color: SIMD3<Float>? = nil
                        for l in cells[which] {   // the last one found is on top
                            let q = p - l.base, scale = 1 / simd_length(l.along)
                            let s = dot(q, l.along) * scale / l.length, t = (q.x * l.along.y - q.y * l.along.x) * scale
                            if s > 0, s < 1, abs(t) < l.half * outline(s) { color = leafShade(0.5 + 0.5 * t / l.half, s) }
                        }
                        if color == nil, y < twig {
                            let bend = bends[which]
                            if abs(p.x - bend.x * twig * sin(y / twig * 2.2 + bend.y) * (y / twig)) < twigHalf { color = SIMD3(0.5, 0.42, 0.3) }
                        }
                        if let color {
                            colors[row * n + column] = color
                            mask[row * n + column] = 255
                        }
                    }
                }
            }
        }
        // The covered pixels' mean brought to `mean`; the rest take that colour, so that coarse mip levels keep it.
        var sum = SIMD3<Float>.zero, covered = 0
        for i in 0..<n * n where alpha[i] != 0 { sum += linear[i]; covered += 1 }
        let gain = mean / max((sum.x + sum.y + sum.z) / Float(3 * max(covered, 1)), 1e-6)
        let fill = sum / Float(max(covered, 1)) * gain
        var pixels = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<n * n {
            let c = simd_min(alpha[i] != 0 ? linear[i] * gain : fill, SIMD3(repeating: 1))
            pixels[4 * i] = encode(c.x); pixels[4 * i + 1] = encode(c.y); pixels[4 * i + 2] = encode(c.z)
        }
        return CardSheet(image: Image(width: n, height: n, pixels: pixels), alpha: alpha, coverage: Float(covered) / Float(n * n))
    }

    /// Every kind as a PNG in `folder` (METALRENDERER_FOLIAGE_TEST with METALRENDERER_FOLIAGE_TEXTURES=<folder>), to look at.
    static func writePNGs(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var images = Kind.allCases.map { ($0.name, make($0)) }
        // The card sheets too, black where a card is cut away.
        for species in Foliage.Species.allCases where species.hasBoughs {
            guard let leaf = Foliage.boughRecipe(species, variant: 0).leaf else { continue }
            var sheet = cardSheet(leaf, twig: Foliage.cardTwig, seed: 0xCA2D &+ UInt64(species.rawValue))
            for i in sheet.alpha.indices where sheet.alpha[i] == 0 { sheet.image.pixels.replaceSubrange(4 * i..<4 * i + 3, with: [0, 0, 0]) }
            images.append(("cards-\(species)", sheet.image))
        }
        for (name, image) in images {
            guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
                  let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                   decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let out = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(name).png") as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(out, cg, nil)
            CGImageDestinationFinalize(out)
        }
    }

    /// An image of `color(u, v)` (linear, at each pixel's centre), its rows filled in parallel. `normalized`: scaled so
    /// that its mean is `mean`.
    static func image(_ width: Int, _ height: Int, normalized: Bool = false, _ color: (Float, Float) -> SIMD3<Float>) -> Image {
        var linear = [SIMD3<Float>](repeating: .zero, count: width * height)
        linear.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: height) { y in   // a row each: disjoint slots
                let v = (Float(y) + 0.5) / Float(height)
                for x in 0..<width { out[y * width + x] = simd_max(color((Float(x) + 0.5) / Float(width), v), .zero) }
            }
        }
        var gain: Float = 1
        if normalized {
            let sum = linear.reduce(SIMD3<Float>.zero, +)
            gain = mean / max((sum.x + sum.y + sum.z) / Float(3 * linear.count), 1e-6)
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            linear.withUnsafeBufferPointer { source in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for i in y * width..<(y + 1) * width {
                        let c = simd_min(source[i] * gain, SIMD3(repeating: 1))
                        out[4 * i] = encode(c.x); out[4 * i + 1] = encode(c.y); out[4 * i + 2] = encode(c.z)
                    }
                }
            }
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    @inline(__always) private static func encode(_ c: Float) -> UInt8 {
        UInt8((c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    /// Value noise, about -0.5...0.5, one lattice cell per unit, repeating every `px` cells along x and `py` along y,
    /// so that a texture of whole periods tiles.
    static func noise(_ x: Float, _ y: Float, _ px: Int, _ py: Int, _ seed: UInt32) -> Float {
        let fx = floor(x), fy = floor(y)
        let ix = Int(fx), iy = Int(fy)
        @inline(__always) func wrap(_ i: Int, _ p: Int) -> UInt32 { UInt32(truncatingIfNeeded: ((i % p) + p) % p) }
        @inline(__always) func corner(_ dx: Int, _ dy: Int) -> Float {
            var h = wrap(ix + dx, px) &* 0x85EB_CA6B ^ wrap(iy + dy, py) &* 0xC2B2_AE35 ^ seed &* 0x27D4_EB2F
            h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12; h = h &* 0x297A_2D39; h ^= h >> 15
            return Float(h & 0xFFFF) / 65535 - 0.5
        }
        var tx = x - fx, ty = y - fy
        tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
        let low = corner(0, 0) + (corner(1, 0) - corner(0, 0)) * tx, high = corner(0, 1) + (corner(1, 1) - corner(0, 1)) * tx
        return low + (high - low) * ty
    }
}
