import Foundation
import simd

/// Where a generated character's skin is in its textures (SkinTextures): the head and neck unrolled round the head's
/// upright axis, one side over the other. u is the angle from the front (0) round to the back (1) on either side, so
/// the two halves share their texels (the textures are symmetric) and there is no seam to split vertices at: the map
/// folds, at the face's middle and the back of the head, where it is continuous. v runs from the crown (0) down the
/// neck (1); everything below, the body, is on the last row, where the textures are plain.
///
/// Numbers are in FaceSculpt's space (the Y Bot's head), so the base's UVs and the textures' points agree.
enum SkinAtlas {
    /// The axis (x, z) and the heights the map spans.
    static let axis = SIMD2<Float>(0, -0.01)
    static let top: Float = 1.815, bottom: Float = 1.44

    static func uv(_ q: SIMD3<Float>) -> SIMD2<Float> {
        let a = atan2(abs(q.x - axis.x), q.z - axis.y)
        return SIMD2(min(max(a / .pi, 0), 1), min(max((top - q.y) / (top - bottom), 0), 1))
    }
}

/// The base's head as the textures see it: for each texel of the atlas (SkinAtlas, `size` square), the point of the
/// head's surface it shows and its normal, in FaceSculpt's space, and how far apart neighbouring texels are on it
/// (metres per texel along u and v). Made by drawing the base's triangles into the atlas, the outermost surface
/// (furthest from the axis) kept where several fall on one texel (the lips' inside behind their outside).
struct SkinChart {
    static let defaultSize = 1024
    let size: Int
    var points: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var covered: [Bool]
    var spacing: [SIMD2<Float>]

    static func make(_ base: CharacterBase, size: Int = SkinChart.defaultSize) -> SkinChart {
        let c = base.character
        let sculpt = FaceSculpt(c) ?? FaceSculpt()
        var chart = SkinChart(size: size, points: [SIMD3<Float>](repeating: .zero, count: size * size),
                              normals: [SIMD3<Float>](repeating: [0, 0, 1], count: size * size),
                              covered: [Bool](repeating: false, count: size * size),
                              spacing: [SIMD2<Float>](repeating: SIMD2(repeating: 0.0004), count: size * size))
        var depth = [Float](repeating: -1, count: size * size)
        let surface = Set([CharacterBase.Region.head.rawValue, CharacterBase.Region.neck.rawValue, CharacterBase.Region.trunk.rawValue])
        let local = c.positions.map { sculpt.local($0) }
        let s = Float(size)
        for t in 0..<(c.indices.count / 3) {
            let v = (0..<3).map { Int(c.indices[3 * t + $0]) }
            guard v.allSatisfy({ surface.contains(base.regions[$0]) && local[$0].y > SkinAtlas.bottom - 0.02 }) else { continue }
            let q = v.map { local[$0] }
            let uv = q.map { SkinAtlas.uv($0) * s - 0.5 }
            // (A triangle across the face's middle has its corners on both sides of the fold: each half is drawn.)
            let lo = simd_max(simd_min(simd_min(uv[0], uv[1]), uv[2]).rounded(.up), .zero)
            let hi = simd_min(simd_max(simd_max(uv[0], uv[1]), uv[2]).rounded(.down), SIMD2(repeating: s - 1))
            guard lo.x <= hi.x, lo.y <= hi.y else { continue }
            let e1 = uv[1] - uv[0], e2 = uv[2] - uv[0]
            let det = e1.x * e2.y - e1.y * e2.x
            guard abs(det) > 1e-9 else { continue }
            let n = v.map { simd_normalize(c.normals[$0]) }
            for y in Int(lo.y)...Int(hi.y) {
                for x in Int(lo.x)...Int(hi.x) {
                    let d = SIMD2(Float(x), Float(y)) - uv[0]
                    let b1 = (d.x * e2.y - d.y * e2.x) / det, b2 = (e1.x * d.y - e1.y * d.x) / det, b0 = 1 - b1 - b2
                    guard b0 >= -1e-4, b1 >= -1e-4, b2 >= -1e-4 else { continue }
                    let p = q[0] * b0 + q[1] * b1 + q[2] * b2
                    let r = simd_length(SIMD2(p.x, p.z) - SkinAtlas.axis)
                    let i = y * size + x
                    guard r > depth[i] else { continue }
                    depth[i] = r
                    chart.points[i] = p
                    chart.normals[i] = simd_normalize(n[0] * b0 + n[1] * b1 + n[2] * b2)
                    chart.covered[i] = true
                }
            }
        }
        // Texels no triangle reached (where the map squeezes a surface) take a neighbour's.
        for _ in 0..<4 {
            var filled = chart
            for y in 0..<size {
                for x in 0..<size where !chart.covered[y * size + x] {
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < size, ny < size, chart.covered[ny * size + nx] else { continue }
                        filled.points[y * size + x] = chart.points[ny * size + nx]
                        filled.normals[y * size + x] = chart.normals[ny * size + nx]
                        filled.covered[y * size + x] = true
                        break
                    }
                }
            }
            chart = filled
        }
        // Spacing: how far the next texel's point is (the larger of the two sides').
        for y in 0..<size {
            for x in 0..<size {
                let i = y * size + x, p = chart.points[i]
                func gap(_ j: Int?) -> Float? { j.flatMap { chart.covered[$0] ? simd_distance(chart.points[$0], p) : nil } }
                let du = [gap(x > 0 ? i - 1 : nil), gap(x < size - 1 ? i + 1 : nil)].compactMap { $0 }.max() ?? 0.0004
                let dv = [gap(y > 0 ? i - size : nil), gap(y < size - 1 ? i + size : nil)].compactMap { $0 }.max() ?? 0.0004
                chart.spacing[i] = SIMD2(min(max(du, 1e-5), 0.01), min(max(dv, 1e-5), 0.01))
            }
        }
        return chart
    }
}

/// The skin's textures, drawn per texel of the atlas (SkinAtlas) from the point of the head it shows (SkinChart),
/// so a feature is placed by the face's landmarks (FaceSculpt) and comes out where they are on every character:
/// - colour (a multiplier about 1, stored over `colourScale`): a blotchy mottle, the redder cheeks, nose, ears and
///   chin, the darker hollows under the eyes, a man's beard shadow, freckles, age spots, moles, and makeup (blush,
///   eye shadow, lipstick);
/// - roughness (a multiplier, in green): the oilier forehead and nose, the wet lips;
/// - normals (tangent space): pores (wider on the nose and cheeks), the fine lines across the lips, and the wrinkles
///   age brings (across the forehead, between the brows, the crow's feet, under the eyes, beside the mouth, on the neck).
/// Plain (a multiplier of 1, a flat normal) from the neck down.
enum SkinTextures {
    /// In the caches' keys, with the kit's (the chart is the base's).
    static let version = 3
    static var versionKey: String { "v\(version)k\(CharacterKit.version)" }
    /// A colour texel holds the multiplier times this (so the multiplier can go above 1); materials divide by it.
    static let colourScale: Float = 0.8
    static let roughnessScale: Float = 0.9

    /// What the colour texture depends on, beside the chart.
    struct Marks: Equatable {
        var redness: Float, melanin: Float, freckles: Float, blush: Float, eyeShadow: Float, lipstick: Float
        var age: Float, sex: Float, stubble: Float, seed: UInt64

        init(_ dna: CharacterDNA) {
            let l = dna.look
            redness = l.redness; melanin = l.melanin; freckles = l.freckles; blush = l.blush; eyeShadow = l.eyeShadow
            lipstick = l.lipstick; age = dna.macro.age; sex = dna.macro.sex
            stubble = (1 - dna.macro.sex) * (dna.hair.beard == "none" ? 0.35 : dna.hair.beard == "stubble" ? 1 : 0.6)
            seed = dna.seed
        }

        /// Quantised (a slider's drag remakes the texture a few dozen times, not at every step) for the cache's key.
        var key: String {
            let q = [redness, melanin, freckles, blush, eyeShadow, lipstick, sex, stubble].map { Int(($0 * 24).rounded()) }
            return SkinTextures.versionKey + "-" + q.map(String.init).joined(separator: ".") + "-a\(Int(age / 4))-s\(seed % 1024)"
        }
    }

    /// The wrinkles' depth for `age` (0 young ... 1 deep), quantised the same way.
    static func wrinkles(age: Float) -> Float { (min(max((age - 22) / 58, 0), 1) * 12).rounded() / 12 }

    // MARK: Drawing

    private static let lock = NSLock()
    private static var recent: [(key: String, image: FoliageTextures.Image)] = []

    /// The image `key` names, drawn by `make` unless one of the last few drawn is it (the disk caches keep them
    /// too, but a workshop off them, or one made again while they write, asks here).
    static func cached(_ key: String, _ make: () -> FoliageTextures.Image) -> FoliageTextures.Image {
        lock.lock()
        if let found = recent.first(where: { $0.key == key }) { lock.unlock(); return found.image }
        lock.unlock()
        let image = make()
        lock.lock()
        recent.insert((key, image), at: 0)
        if recent.count > 8 { recent.removeLast() }
        lock.unlock()
        return image
    }

    static func colour(_ chart: SkinChart, _ m: Marks) -> FoliageTextures.Image {
        draw(chart) { p, n in
            var c = SIMD3<Float>(repeating: 1)
            let face = faceMask(p, n)
            // Mottle: a soft blotchiness everywhere, a little redder or yellower here and there.
            let blotch = fbm(p * 90, seed: 11) - 0.5, hue = fbm(p * 45, seed: 12) - 0.5
            c *= 1 + 0.07 * blotch
            c *= SIMD3(1 + 0.03 * hue, 1, 1 - 0.04 * hue)
            // Where blood shows: cheeks, nose, ears, chin (more on fair skin).
            let fair = 1 - 0.7 * m.melanin
            var red = 0.75 * gauss(p, [0.043, 1.648, 0.085], 0.017, mirror: true) + 0.55 * gauss(p, [0, 1.648, 0.118], 0.012)
                + 0.5 * gauss(p, [0.016, 1.64, 0.11], 0.008, mirror: true) + 0.25 * gauss(p, [0, 1.585, 0.098], 0.014)
            red += 0.5 * gauss(p, FaceSculpt.ears[0], 0.03, mirror: true)
            red *= (0.4 + 1.2 * m.redness) * fair
            c *= SIMD3(1 - 0.02 * red, 1 - 0.12 * red, 1 - 0.1 * red)
            // Under the eyes: darker, bluer hollows; the lids a little darker.
            for e in FaceSculpt.eyeCentres {
                let under = gaussXY(p, e + [e.x > 0 ? 0.004 : -0.004, -0.0135, 0.004], SIMD2(0.012, 0.0045)) * step(p.z, 0.06)
                c *= 1 - SIMD3(0.06, 0.09, 0.05) * under * (0.6 + 0.6 * fair)
                let lid = gaussXY(p, e + [0, 0.008, 0.008], SIMD2(0.013, 0.0045)) * step(p.z, 0.06)
                c *= 1 - SIMD3(0.04, 0.06, 0.05) * lid
                // Eye shadow: over the upper lid up toward the brow, darker at the lash line.
                let shadow = gaussXY(p, e + [e.x > 0 ? 0.003 : -0.003, 0.0095, 0.006], SIMD2(0.015, 0.006)) * step(p.z, 0.06)
                c *= 1 - SIMD3(0.42, 0.5, 0.36) * shadow * m.eyeShadow
            }
            // The lash line: dark along each upper lid's edge, under the lashes.
            c *= 1 - SIMD3(0.5, 0.52, 0.5) * lashLine(p)
            // A man's beard shadow, where the beard grows (stubble: darker; shaved: a little).
            let beard = beardMask(p, n) * m.stubble
            c *= 1 - SIMD3(0.16, 0.15, 0.12) * beard * fair
            // Blush on the cheeks' apples.
            c *= 1 - SIMD3(0.0, 0.2, 0.16) * gauss(p, [0.046, 1.652, 0.083], 0.016, mirror: true) * m.blush
            // Lipstick (the lips' material takes it).
            if FaceParts.skinMaterial(p) == .lips { c *= 1 - SIMD3(0.28, 0.62, 0.55) * m.lipstick }
            // Freckles: small spots on the nose and cheeks, fewer further out.
            if m.freckles > 0 {
                let where_ = min(1, 1.3 * gauss(p, [0, 1.66, 0.1], 0.04) + 0.25 * face)
                let f = spots(p, cell: 0.0024, size: 0.0007, chance: 0.6 * m.freckles * where_, seed: 21 &+ UInt32(truncatingIfNeeded: m.seed))
                c *= 1 - SIMD3(0.22, 0.3, 0.34) * f * fair
            }
            // Age spots: larger, sparser, from fifty.
            let aged = min(max((m.age - 50) / 30, 0), 1)
            if aged > 0 {
                let f = spots(p, cell: 0.011, size: 0.0028, chance: 0.35 * aged, seed: 31 &+ UInt32(truncatingIfNeeded: m.seed))
                c *= 1 - SIMD3(0.16, 0.24, 0.3) * f * face
            }
            // A few moles.
            let mole = spots(p, cell: 0.03, size: 0.0011, chance: 0.18, seed: 41 &+ UInt32(truncatingIfNeeded: m.seed >> 10))
            c *= 1 - SIMD3(0.45, 0.52, 0.55) * mole
            let plain = neckFade(p)
            c = 1 + (c - 1) * plain
            return SIMD4(simd_clamp(c * colourScale, .zero, SIMD3(repeating: 1)), 1)
        }
    }

    static func roughness(_ chart: SkinChart) -> FoliageTextures.Image {
        draw(chart, size: chart.size / 2) { p, n in
            var r: Float = 1
            // The T zone shines: the forehead's middle, the nose, the chin.
            r -= 0.22 * gaussXY(p, [0, 1.735, 0.09], SIMD2(0.03, 0.02))
            r -= 0.25 * gauss(p, [0, 1.66, 0.11], 0.016)
            r -= 0.12 * gauss(p, [0, 1.582, 0.1], 0.012)
            if FaceParts.skinMaterial(p) == .lips { r = 0.85 }
            r = 1 + (r - 1) * neckFade(p)
            return SIMD4(1, r * roughnessScale, 0, 1)
        }
    }

    /// The normals: pores and fine lines always, the wrinkles at `wrinkles` (`SkinTextures.wrinkles`).
    static func normals(_ chart: SkinChart, wrinkles w: Float) -> FoliageTextures.Image {
        let size = chart.size
        // Heights (m) per texel first, then their slopes over the texels' spacing.
        var height = [Float](repeating: 0, count: size * size)
        height.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: size) { y in
                for x in 0..<size {
                    let i = y * size + x
                    guard chart.covered[i] else { continue }
                    out[i] = skinHeight(chart.points[i], chart.normals[i], wrinkles: w) * neckFade(chart.points[i])
                }
            }
        }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: size) { y in
                for x in 0..<size {
                    let i = y * size + x
                    let l = height[y * size + max(x - 1, 0)], r = height[y * size + min(x + 1, size - 1)]
                    let u = height[max(y - 1, 0) * size + x], d = height[min(y + 1, size - 1) * size + x]
                    let s = chart.spacing[i]
                    var n = SIMD3(-(r - l) / (2 * s.x), -(d - u) / (2 * s.y), 1)
                    n = simd_normalize(n)
                    out[4 * i] = UInt8(min(max((n.x * 0.5 + 0.5) * 255, 0), 255).rounded())
                    out[4 * i + 1] = UInt8(min(max((n.y * 0.5 + 0.5) * 255, 0), 255).rounded())
                    out[4 * i + 2] = UInt8(min(max((n.z * 0.5 + 0.5) * 255, 0), 255).rounded())
                    out[4 * i + 3] = 255
                }
            }
        }
        return FoliageTextures.Image(width: size, height: size, pixels: pixels)
    }

    /// The skin's relief at `p` (normal `n`), m: negative in a pore or a wrinkle.
    static func skinHeight(_ p: SIMD3<Float>, _ n: SIMD3<Float>, wrinkles w: Float) -> Float {
        let material = FaceParts.skinMaterial(p)
        var h: Float = 0
        if material == .lips {
            // Fine lines across the lips, up and down; a little lumpy.
            let a = abs(p.x) * 1650 + 2.2 * fbm(p * 700, seed: 3)
            h -= 0.00005 * pow(0.5 + 0.5 * cos(a * 2 * .pi), 6)
            h += 0.000015 * (fbm(p * 1500, seed: 4) - 0.5)
            return h
        }
        // Pores: pits on a cellular grid, wider and deeper on the nose and cheeks, finer on the lids and forehead.
        let nose = min(1, 1.4 * gauss(p, [0, 1.655, 0.112], 0.016) + 0.9 * gauss(p, [0.04, 1.648, 0.088], 0.02, mirror: true))
        let cell: Float = 0.00055 + 0.00025 * nose
        let pore = worley(p / cell, seed: 7)
        h -= (0.00004 + 0.00004 * nose) * (1 - smooth(0.0, 0.45, pore))
        // A fine crosshatch of grooves between them (finer bumps).
        h += 0.000018 * (fbm(p * 2600, seed: 5) - 0.5)
        guard w > 0 else { return h }
        let front = step(n.z, 0.25)
        // Across the forehead: wavy lines, deeper in the middle.
        let fx = abs(p.x)
        if p.y > 1.705, p.y < 1.765, fx < 0.055 {
            for k in 0..<5 {
                let y = 1.716 + Float(k) * 0.0095 + 0.0014 * sin(p.x * 70 + Float(k) * 1.7) + 0.0006 * (fbm(p * 220, seed: UInt32(60 + k)) - 0.5)
                let along = 1 - smooth(0.025, 0.052, fx + 0.006 * Float(k % 2))
                h -= 0.00025 * w * along * front * crease(p.y - y, 0.0008)
            }
        }
        // Between the brows: two short upright lines.
        if p.y > 1.688, p.y < 1.712 {
            h -= 0.0002 * w * front * crease(fx - 0.0055, 0.0007) * (1 - smooth(0.006, 0.012, abs(p.y - 1.699)))
        }
        // Crow's feet: lines fanning from each eye's outer corner.
        let corner = SIMD2<Float>(0.048, 1.681)
        let d = SIMD2(fx, p.y) - corner
        let r = simd_length(d)
        if r > 0.002, r < 0.017, p.z > 0.02 {
            let a = atan2(d.y, d.x)   // outward from the corner, up and down a little
            if abs(a) < 1.1 {
                let fan = 0.5 + 0.5 * cos(a * 14 + 0.5)
                h -= 0.00015 * w * pow(fan, 8) * (1 - smooth(0.009, 0.017, r)) * smooth(0.002, 0.004, r)
            }
        }
        // Under each eye: an arc from the inner corner out.
        for e in FaceSculpt.eyeCentres where e.x * p.x > 0 {
            let x = fx - abs(e.x)
            if abs(x) < 0.018 {
                let y = e.y - 0.0115 - 0.012 * x * x / 0.018 + 0.002 * x / 0.018
                h -= 0.00012 * w * crease(p.y - y, 0.0008) * (1 - smooth(0.01, 0.018, abs(x))) * step(p.z, 0.05)
            }
        }
        // Beside the mouth: from each nostril's wing down past the mouth's corner.
        let top = SIMD2<Float>(0.02, 1.64), bottom = SIMD2<Float>(0.032, 1.6)
        let fold = segmentDistance(SIMD2(fx, p.y), top, bottom)
        h -= 0.0004 * w * crease(fold, 0.0016) * step(p.z, 0.06)
        // Around the neck's front: a ring or two.
        for y: Float in [1.505, 1.485] {
            h -= 0.0002 * w * crease(p.y - y - 0.002 * sin(p.x * 50), 0.0014) * step(n.z, 0.2) * (1 - smooth(0.03, 0.05, fx))
        }
        return h
    }

    // MARK: Regions

    /// The face (not the scalp, ears or neck), smoothly.
    static func faceMask(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> Float {
        smooth(0.02, 0.05, p.z) * (1 - smooth(1.73, 1.76, p.y)) * smooth(1.565, 1.59, p.y)
    }

    /// Where a beard grows: the jaw, chin and upper lip, up the cheeks to a line from the ear to the mouth's corner.
    static func beardMask(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> Float {
        let fx = abs(p.x)
        // The cheek line: from in front of the ear (y 1.65) down to beside the mouth (y 1.625); over the upper lip, up
        // to the nose.
        let cheek = 1.652 - 0.03 * smooth(0.01, 0.06, p.z) - 0.004 * smooth(0.035, 0.05, fx)
        let line = 1.641 + (cheek - 1.641) * smooth(0.022, 0.034, fx)
        var m = 1 - smooth(line - 0.006, line, p.y)
        m *= smooth(1.52, 1.56, p.y)   // down the neck to under the jaw
        m *= smooth(-0.03, 0.0, p.z)   // not behind the ears
        // Not the lips (and a little gap round them), nor the nose.
        let lips = FaceParts.skinMaterial(p)
        if lips == .lips || lips == .mouth { m = 0 }
        m *= 1 - gaussXY(p, FaceSculpt.mouth, SIMD2(0.028, 0.0095)) * 0.6
        m *= 1 - gauss(p, [0, 1.643, 0.115], 0.012)
        return min(max(m, 0), 1)
    }

    /// 1 along an upper lid's edge (the eye's opening, FaceRig.lid's), 0 off it.
    static func lashLine(_ p: SIMD3<Float>) -> Float {
        for (e, centre) in FaceSculpt.eyeCentres.enumerated() {
            let r = p - centre, x = r.x * (e == 0 ? 1 : -1)
            guard x > -0.016, x < 0.018, r.z > 0.004, abs(r.y) < 0.012 else { continue }
            let inner: SIMD2<Float> = [-0.0135, -0.0006], outer: SIMD2<Float> = [0.0145, 0.0014]
            let t = (x - inner.x) / (outer.x - inner.x), tc = min(max(t, 0), 1)
            let up = inner.y + (outer.y - inner.y) * t + 0.0058 * pow(sin(.pi * pow(tc, 0.85)), 0.75)
            let along = 1 - smooth(0.85, 1.05, abs(2 * t - 1))
            return crease(r.y - up - 0.0005, 0.0006) * along
        }
        return 0
    }

    /// 1 on the face and head, fading to 0 down the neck (the body below stays plain).
    static func neckFade(_ p: SIMD3<Float>) -> Float { smooth(SkinAtlas.bottom + 0.005, SkinAtlas.bottom + 0.045, p.y) }

    // MARK: Helpers

    /// Each texel's colour from its point and normal.
    static func draw(_ chart: SkinChart, size: Int? = nil, _ f: (SIMD3<Float>, SIMD3<Float>) -> SIMD4<Float>) -> FoliageTextures.Image {
        let n = size ?? chart.size, step = chart.size / n
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n) { y in
                for x in 0..<n {
                    let i = (y * step + step / 2) * chart.size + x * step + step / 2
                    let c = f(chart.points[i], chart.normals[i])
                    for k in 0..<4 { out[4 * (y * n + x) + k] = UInt8(min(max(c[k] * 255, 0), 255).rounded()) }
                }
            }
        }
        return FoliageTextures.Image(width: n, height: n, pixels: pixels)
    }

    @inline(__always) static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { FaceSculpt.smoothstep(a, b, x) }
    @inline(__always) static func step(_ x: Float, _ edge: Float) -> Float { smooth(edge - 0.05, edge + 0.05, x) }
    /// A crease's profile across it: 1 on its line, falling off over `width`.
    @inline(__always) static func crease(_ d: Float, _ width: Float) -> Float { exp(-(d * d) / (width * width)) }

    static func gauss(_ p: SIMD3<Float>, _ c: SIMD3<Float>, _ r: Float, mirror: Bool = false) -> Float {
        var q = p
        if mirror { q.x = abs(q.x) * (c.x < 0 ? -1 : 1) }
        let d = simd_distance_squared(q, c)
        return exp(-d / (r * r))
    }

    /// An elliptic falloff in x and y about `c` (each side of the face mirrored onto c's).
    static func gaussXY(_ p: SIMD3<Float>, _ c: SIMD3<Float>, _ r: SIMD2<Float>) -> Float {
        let x = c.x == 0 ? p.x : abs(p.x) - abs(c.x)
        let d = SIMD2(x / r.x, (p.y - c.y) / r.y)
        return exp(-simd_length_squared(d))
    }

    static func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = min(max(simd_dot(p - a, ab) / simd_length_squared(ab), 0), 1)
        return simd_distance(p, a + ab * t)
    }

    @inline(__always) static func hash(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> UInt32 {
        var h = seed &* 0x9E37_79B9 ^ UInt32(bitPattern: x) &* 0x85EB_CA6B
        h ^= UInt32(bitPattern: y) &* 0xC2B2_AE35
        h ^= UInt32(bitPattern: z) &* 0x27D4_EB2F
        h ^= h >> 15
        h &*= 0x2C1B_3C6D
        h ^= h >> 12
        h &*= 0x297A_2D39
        h ^= h >> 15
        return h
    }
    @inline(__always) static func unit(_ h: UInt32) -> Float { Float(h & 0xFFFFFF) / Float(0x1000000) }

    /// Value noise in 3D, 0...1.
    static func noise(_ p: SIMD3<Float>, seed: UInt32) -> Float {
        let f = p.rounded(.down), t = p - f
        let i = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z))
        let s = t * t * (3 - 2 * t)
        func v(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float { unit(hash(i.x + dx, i.y + dy, i.z + dz, seed)) }
        let x00 = v(0, 0, 0) + (v(1, 0, 0) - v(0, 0, 0)) * s.x, x10 = v(0, 1, 0) + (v(1, 1, 0) - v(0, 1, 0)) * s.x
        let x01 = v(0, 0, 1) + (v(1, 0, 1) - v(0, 0, 1)) * s.x, x11 = v(0, 1, 1) + (v(1, 1, 1) - v(0, 1, 1)) * s.x
        let y0 = x00 + (x10 - x00) * s.y, y1 = x01 + (x11 - x01) * s.y
        return y0 + (y1 - y0) * s.z
    }

    static func fbm(_ p: SIMD3<Float>, seed: UInt32, octaves: Int = 3) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, q = p, total: Float = 0
        for o in 0..<octaves {
            sum += amplitude * noise(q, seed: seed &+ UInt32(o) &* 101)
            total += amplitude
            amplitude *= 0.5
            q *= 2.03
        }
        return sum / total
    }

    /// The distance (in cells) to the nearest of one random point per cell.
    static func worley(_ p: SIMD3<Float>, seed: UInt32) -> Float {
        let f = p.rounded(.down)
        let i = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z))
        var best: Float = 9
        for dz: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dx: Int32 in -1...1 {
                    let h = hash(i.x + dx, i.y + dy, i.z + dz, seed)
                    let o = SIMD3(unit(h), unit(h &* 0x9E37_79B9 ^ 0x5bd1e995), unit(h ^ (h >> 7) &* 0x27D4_EB2F))
                    let c = SIMD3(Float(i.x + dx), Float(i.y + dy), Float(i.z + dz)) + o
                    best = min(best, simd_distance_squared(c, p))
                }
            }
        }
        return best.squareRoot()
    }

    /// Round spots of radius about `size`, one in a `cell`-sized cell with probability `chance`: 1 inside, soft edged.
    static func spots(_ p: SIMD3<Float>, cell: Float, size: Float, chance: Float, seed: UInt32) -> Float {
        guard chance > 0 else { return 0 }
        let q = p / cell, f = q.rounded(.down)
        let i = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z))
        var most: Float = 0
        for dz: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dx: Int32 in -1...1 {
                    let h = hash(i.x + dx, i.y + dy, i.z + dz, seed)
                    guard unit(h) < chance else { continue }
                    let h2 = hash(i.x + dx, i.y + dy, i.z + dz, seed ^ 0xA5A5)
                    let o = SIMD3(unit(h2), unit(h2 &* 0x9E37_79B9), unit(h2 ^ (h2 >> 9) &* 0x85EB_CA6B))
                    let c = (SIMD3(Float(i.x + dx), Float(i.y + dy), Float(i.z + dz)) + o) * cell
                    let r = size * (0.6 + 0.8 * unit(h &* 0x2C1B_3C6D))
                    let strength = 0.5 + 0.5 * unit(h2 &* 0x297A_2D39)
                    most = max(most, strength * (1 - smooth(r * 0.6, r, simd_distance(c, p))))
                }
            }
        }
        return most
    }
}
