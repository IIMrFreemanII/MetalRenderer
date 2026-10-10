import Foundation
import Metal
import simd

/// The Material Painter's brush: how big, hard and strong its dabs are, how far apart along a stroke, what tip they
/// have (round, or a stamp: built-in, or a Material Designer graph's), how they jitter, what a pen's pressure does,
/// and what it paints with (its values, or a stencil's colour). `PaintStrokeDabs` turns a stroke's points into dabs.
struct PaintBrush: Codable, Equatable {
    var size: Float = 40               // radius, in the view's points
    var hardness: Float = 0.6          // 0: soft all the way in, 1: a hard edge
    var opacity: Float = 1             // the most a stroke lays down
    var flow: Float = 0.6              // what each dab adds of what is left to that
    var spacing: Float = 0.15          // between dabs, a share of the diameter
    var stamp = -1                     // PaintStamps' layer; -1 round
    var angle: Float = 0               // the stamp's turn (degrees)
    var followStroke = false           // ...along the stroke's direction
    var angleJitter: Float = 0         // degrees either way
    var sizeJitter: Float = 0          // a share of the size, less
    var scatter: Float = 0             // dabs moved off the stroke by up to this share of the diameter
    var aspect: Float = 1              // the tip squashed (1 round)
    var pressureSize = true
    var pressureOpacity = false
    var symmetry = Symmetry.none
    var values = PaintValues()
    var channels: Set<PaintChannel> = [.color, .roughness, .metallic]
    var eraser = false
    /// A stencil laid over the view: its colour is what is painted (and its alpha masks it).
    var stencil = Stencil()

    enum Symmetry: Int, Codable, CaseIterable, Identifiable {
        case none, x, y, z
        var id: Int { rawValue }
        var title: String { self == .none ? "Off" : "\(self)".uppercased() }
    }

    struct Stencil: Codable, Equatable {
        var enabled = false
        var image = ""                 // a file's path, or "graph:<name>" (its base colour)
        var offset = SIMD2<Float>(0, 0)   // the view's share
        var scale: Float = 1
        var rotation: Float = 0        // degrees
        var opacity: Float = 0.5       // shown over the view

        /// Screen pixels to the stencil's UV for a view of `screen` pixels: centred, as wide as the view x scale.
        func frame(screen: SIMD2<Float>) -> simd_float3x3 {
            let s = max(scale, 1e-3) * screen.x
            let c = cos(rotation * .pi / 180), n = sin(rotation * .pi / 180)
            let centre = screen / 2 + offset * screen
            // uv = R^-1 (p - centre) / s + 0.5
            let r = simd_float3x3(rows: [SIMD3(c / s, n / s, 0), SIMD3(-n / s, c / s, 0), SIMD3(0, 0, 1)])
            let t = simd_float3x3(rows: [SIMD3(1, 0, -centre.x), SIMD3(0, 1, -centre.y), SIMD3(0, 0, 1)])
            let h = simd_float3x3(rows: [SIMD3(1, 0, 0.5), SIMD3(0, 1, 0.5), SIMD3(0, 0, 1)])
            return h * r * t
        }
    }
}

/// A stroke's dabs: each point the pointer reaches (screen pixels, its pressure) gives the dabs between it and the
/// last at the brush's spacing, jittered as the brush says (the same stroke, the same dabs: seeded).
struct PaintStrokeDabs {
    var brush: PaintBrush
    /// Points per pixel of the render (the view's points are larger on a Retina screen at a render scale of 1).
    var scale: Float
    private var last: SIMD2<Float>?
    private var carried: Float = 0
    private var rng: UInt64
    private var direction: Float = 0

    init(brush: PaintBrush, scale: Float, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.brush = brush
        self.scale = scale
        rng = seed
    }

    private mutating func random() -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(rng >> 40) / Float(1 << 24)
    }

    /// The dabs from the last point to `p` (the first point: one dab at it).
    mutating func move(to p: SIMD2<Float>, pressure: Float) -> [PaintDab] {
        let radius = brush.size * scale
        let step = max(1, brush.spacing * 2 * radius)
        var out: [PaintDab] = []
        guard let from = last else {
            last = p
            out.append(dab(at: p, pressure: pressure, radius: radius))
            return out
        }
        let d = p - from
        let length = simd_length(d)
        guard length > 0 else { return out }
        direction = atan2(d.y, d.x)
        var t = step - carried
        while t <= length {
            out.append(dab(at: from + d * (t / length), pressure: pressure, radius: radius))
            t += step
        }
        carried = length - (t - step)
        last = p
        return out
    }

    private mutating func dab(at p: SIMD2<Float>, pressure: Float, radius: Float) -> PaintDab {
        let pressure = min(max(pressure, 0.05), 1)
        var r = radius * (brush.pressureSize ? pressure : 1) * (1 - brush.sizeJitter * random())
        r = max(r, 0.5)
        var at = p
        if brush.scatter > 0 {
            let a = random() * 2 * .pi, s = random() * brush.scatter * 2 * radius
            at += SIMD2(cos(a), sin(a)) * s
        }
        var angle = brush.angle * .pi / 180 + (random() * 2 - 1) * brush.angleJitter * .pi / 180
        if brush.followStroke { angle += direction }
        return PaintDab(centre: at, radius: r, hardness: min(max(brush.hardness, 0), 0.999),
                        opacity: brush.opacity * (brush.pressureOpacity ? pressure : 1), flow: brush.flow, angle: angle,
                        stamp: Int32(brush.stamp), aspect: max(brush.aspect, 0.05))
    }
}

/// The brush's tips (R8, `side` squared, a layer each): the built-in ones, made here, then any a graph was baked into.
final class PaintStamps {
    static let side = 256
    static let builtIn = ["Soft noise", "Scratches", "Splatter", "Leaf", "Grunge", "Dots", "Square"]

    private(set) var names: [String] = PaintStamps.builtIn
    private var pixels: [[UInt8]]
    private(set) var texture: MTLTexture?
    private var version = 0, made = -1

    init() { pixels = PaintStamps.builtIn.indices.map { PaintStamps.make($0) } }

    /// A stamp from a picture (a graph's bake read back: its luminance), as the next layer; its index.
    @discardableResult
    func add(_ name: String, grey: [UInt8]) -> Int {
        if let i = names.firstIndex(of: name) { pixels[i] = grey; version += 1; return i }
        names.append(name)
        pixels.append(grey)
        version += 1
        return names.count - 1
    }

    /// The array texture, made again after a change.
    func array(_ device: MTLDevice) -> MTLTexture? {
        if made == version, let texture { return texture }
        let n = PaintStamps.side
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .r8Unorm
        d.width = n; d.height = n
        d.arrayLength = pixels.count
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        for (i, p) in pixels.enumerated() {
            p.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, slice: i, withBytes: $0.baseAddress!,
                                          bytesPerRow: n, bytesPerImage: n * n) }
        }
        t.label = "paint stamps"
        texture = t
        made = version
        return t
    }

    /// A built-in stamp's pixels (white = paint), within its circle.
    static func make(_ kind: Int) -> [UInt8] {
        let n = side
        var out = [UInt8](repeating: 0, count: n * n)
        var rng: UInt64 = 0x1234_5678 &+ UInt64(kind) &* 0x9E37_79B9
        func random() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 40) / Float(1 << 24)
        }
        func hash(_ x: Int, _ y: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ kind &* 1442695041)
            h = (h ^ (h >> 13)) &* 1274126177
            return Float(h & 0xFFFF) / 65535
        }
        func noise(_ p: SIMD2<Float>) -> Float {
            let i = SIMD2<Int>(Int(floor(p.x)), Int(floor(p.y))), f = p - SIMD2(floor(p.x), floor(p.y))
            let u = f * f * (3 - 2 * f)
            let a = hash(i.x, i.y), b = hash(i.x + 1, i.y), c = hash(i.x, i.y + 1), d = hash(i.x + 1, i.y + 1)
            return (a * (1 - u.x) + b * u.x) * (1 - u.y) + (c * (1 - u.x) + d * u.x) * u.y
        }
        func fbm(_ p: SIMD2<Float>) -> Float {
            var v: Float = 0, a: Float = 0.5, q = p
            for _ in 0..<5 { v += a * noise(q); q *= 2.03; a *= 0.5 }
            return v
        }
        var splats: [(SIMD2<Float>, Float)] = []
        var lines: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
        switch kind {
        case 1:
            for _ in 0..<18 {
                let a = (random() - 0.5) * 0.6, c = SIMD2<Float>(random() * 1.4 - 0.7, random() * 1.4 - 0.7)
                let l = 0.2 + random() * 0.6, d = SIMD2(cos(a), sin(a)) * l
                lines.append((c - d / 2, c + d / 2, 0.006 + random() * 0.012))
            }
        case 2:
            splats.append((.zero, 0.45))
            for _ in 0..<40 {
                let a = random() * 2 * .pi, r = 0.3 + random() * 0.6
                splats.append((SIMD2(cos(a), sin(a)) * r, 0.02 + random() * 0.1 * (1 - r)))
            }
        case 5:
            for _ in 0..<60 { splats.append((SIMD2(random() * 1.8 - 0.9, random() * 1.8 - 0.9), 0.03 + random() * 0.05)) }
        default: break
        }
        for y in 0..<n {
            for x in 0..<n {
                let p = (SIMD2<Float>(Float(x), Float(y)) + 0.5) / Float(n) * 2 - 1
                let r = simd_length(p)
                var v: Float
                switch kind {
                case 0: v = (1 - smoothstep(0.3, 1, r)) * min(max(fbm(p * 3 + 7) * 1.6 - 0.25, 0), 1)
                case 1:
                    v = 0
                    for (a, b, w) in lines {
                        let ab = b - a, t = min(max(simd_dot(p - a, ab) / simd_dot(ab, ab), 0), 1)
                        let d = simd_length(p - (a + ab * t))
                        v = max(v, 1 - smoothstep(w * 0.5, w, d))
                    }
                case 2, 5:
                    v = 0
                    for (c, s) in splats { v = max(v, 1 - smoothstep(s * 0.8, s, simd_length(p - c))) }
                    if kind == 2 { v *= 0.7 + 0.3 * fbm(p * 6) }
                case 3:
                    // A leaf: a pointed ellipse along y, a midrib.
                    let q = SIMD2(p.x / 0.45, p.y / 0.92)
                    let w = (1 - q.y * q.y) * (1 - 0.25 * q.y)
                    v = abs(q.x) < w ? 1 - smoothstep(w - 0.08, w, abs(q.x)) : 0
                    v *= abs(p.x) < 0.012 ? 0.6 : 1
                case 4: v = (1 - smoothstep(0.5, 1, r)) * min(max((fbm(p * 5 + 3) - 0.45) * 4, 0), 1)
                default: v = max(abs(p.x), abs(p.y)) < 0.8 ? 1 : 0
                }
                out[y * n + x] = UInt8(min(max(v, 0), 1) * 255)
            }
        }
        return out
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
