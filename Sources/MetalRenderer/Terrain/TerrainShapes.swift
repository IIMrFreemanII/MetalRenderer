import Characters
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// Shapes a scene gives its ground over its base, as a function of the place alone (never added to what is there:
/// asked again, the same): level flats (a lot, a square, a courtyard, a canal's bed), bowls (ponds and lakes, a rim
/// round them) and channels (a river's bed along its line). A scene's generated water is shaped into its base
/// (ShapedTerrainBase) rather than carved into its edits, so the user's edits keep only what the user did, and a
/// scene made again shapes no deeper.
package struct TerrainShapes {
    /// A rounded rectangle of the world's x, z made level at `level`, blending back into the ground over `blend`
    /// metres beyond its edge. `protect`: the brushes leave it as it is.
    package struct Flat {
        var lo: SIMD2<Float>, hi: SIMD2<Float>
        var corner: Float = 0
        var level: Float
        var blend: Float
        var protect = false

        /// (As the memberwise initializer, for the modules above this one.)
        package init(lo: SIMD2<Float>, hi: SIMD2<Float>, corner: Float = 0, level: Float, blend: Float, protect: Bool = false) {
            self.lo = lo
            self.hi = hi
            self.corner = corner
            self.level = level
            self.blend = blend
            self.protect = protect
        }
    }
    /// A pond or lake: an ellipse's bowl `depth` under its water's `level` in the middle, a rim a little over the water
    /// round it (out to 1.6 radii), blending back into the ground.
    package struct Bowl {
        package var center: SIMD2<Float>
        package var radii: SIMD2<Float>
        package var level: Float
        var depth: Float
    }
    /// A river's bed along its line (the world's x, z), its height at each point (kept: TerrainWater.bed), within half
    /// its width a rounded channel, then a bank back to the ground over another half width.
    package struct Channel {
        var points: [SIMD2<Double>]
        var beds: [Float]
        var half: Float
        var depth: Float
    }

    package var flats: [Flat] = []
    package var bowls: [Bowl] = []
    var channels: [Channel] = []

    var isEmpty: Bool { flats.isEmpty && bowls.isEmpty && channels.isEmpty }

    /// What the shapes are, in a few characters (part of the base's fingerprint, and of a terrain's name).
    package var fingerprint: String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ f: Float) { h = (h ^ UInt64(f.bitPattern)) &* 0x100_0000_01B3 }
        for f in flats { [f.lo.x, f.lo.y, f.hi.x, f.hi.y, f.corner, f.level, f.blend, f.protect ? 1 : 0].forEach(mix) }
        for b in bowls { [b.center.x, b.center.y, b.radii.x, b.radii.y, b.level, b.depth].forEach(mix) }
        for c in channels {
            for p in c.points { mix(Float(p.x)); mix(Float(p.y)) }
            c.beds.forEach(mix)
            mix(c.half); mix(c.depth)
        }
        return isEmpty ? "" : String(h, radix: 16)
    }

    @inline(__always) private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The ground `h` at (x, z) shaped: the water's beds and banks, then the flats over them (in their order: a later
    /// one over an earlier).
    func shape(_ x: Double, _ z: Double, _ h: Float) -> Float {
        var out = h
        if !channels.isEmpty || !bowls.isEmpty {
            var bed = Float.infinity, bank = Float.infinity
            let p = SIMD2(x, z), q = SIMD2(Float(x), Float(z))
            for c in channels where c.points.count > 1 {
                let half = Double(c.half)
                for k in 0..<(c.points.count - 1) {
                    let a = c.points[k], ab = c.points[k + 1] - a
                    let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
                    let d = simd_distance(p, a + ab * t)
                    guard d < half * 2 else { continue }
                    let floor = c.beds[k] + (c.beds[k + 1] - c.beds[k]) * Float(t)
                    if d <= half {
                        let u = Float(d / half)
                        bed = min(bed, floor + c.depth * u * u)
                    } else {
                        let top = floor + c.depth, f = TerrainShapes.smoothstep(0, 1, Float((d - half) / half))
                        bank = min(bank, top + (h - top) * f)
                    }
                }
            }
            for b in bowls {
                let u = simd_length((q - b.center) / b.radii)
                guard u < 1.6 else { continue }
                if u <= 1 {
                    bed = min(bed, b.level - b.depth * (1 - u * u) - 0.05)
                } else {
                    let top = b.level + 0.3, f = TerrainShapes.smoothstep(1, 1.6, u)
                    bank = min(bank, top + (h - top) * f)
                }
            }
            out = bed.isFinite ? bed : bank.isFinite ? bank : h
        }
        for f in flats {
            let q = SIMD2(Float(x), Float(z)), centre = (f.lo + f.hi) / 2, halfSize = (f.hi - f.lo) / 2
            // Signed distance to the rounded rectangle (negative inside).
            let d = simd_abs(q - centre) - halfSize + f.corner
            let outside = simd_length(simd_max(d, .zero)) + min(max(d.x, d.y), 0) - f.corner
            if outside <= 0 { out = f.level; continue }
            guard f.blend > 0, outside < f.blend else { continue }
            out = f.level + (out - f.level) * TerrainShapes.smoothstep(0, f.blend, outside)
        }
        return out
    }

    /// Whether the brushes leave (x, z) as it is (a protected flat's).
    func protects(_ x: Double, _ z: Double) -> Bool {
        flats.contains { $0.protect && Float(x) >= $0.lo.x && Float(x) <= $0.hi.x && Float(z) >= $0.lo.y && Float(z) <= $0.hi.y }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(flats: [Flat] = [], bowls: [Bowl] = [], channels: [Channel] = []) {
        self.flats = flats
        self.bowls = bowls
        self.channels = channels
    }
}

/// A base with shapes over it (TerrainShapes): its heights shaped, its kinds and protection its own (and the
/// protected flats'). The fingerprint says both, so edits saved over the plain base aren't taken for edits of this.
package final class ShapedTerrainBase: TerrainBase {
    let inner: TerrainBase
    let shapes: TerrainShapes
    package var grid: TerrainGrid { inner.grid }

    package init(_ inner: TerrainBase, shapes: TerrainShapes) {
        self.inner = inner
        self.shapes = shapes
    }

    package var fingerprint: String { shapes.isEmpty ? inner.fingerprint : inner.fingerprint + " shaped \(shapes.fingerprint)" }

    package func height(_ i: Int, _ j: Int) -> Float {
        let h = inner.height(i, j)
        guard !shapes.isEmpty else { return h }
        let p = grid.place(i, j)
        return shapes.shape(p.x, p.y, h)
    }

    package func kind(_ i: Int, _ j: Int, step: Int) -> UInt8? { inner.kind(i, j, step: step) }

    package func protection(_ i: Int, _ j: Int) -> Float {
        let p = grid.place(i, j)
        return shapes.protects(p.x, p.y) ? 1 : inner.protection(i, j)
    }
}

/// A scene's generated water (made from its seed, shaped into its base): rivers and ponds as water bodies (the same
/// as the Terrain Editor's, TerrainWater makes their surfaces) and the shapes that hold them.
package enum SceneWaterMaker {
    /// The base's height at the world's (x, z), between its samples.
    package static func height(_ base: TerrainBase, _ x: Double, _ z: Double) -> Float {
        let g = base.grid.coordinates(x, z)
        let i = Int(g.x.rounded(.down)), j = Int(g.y.rounded(.down))
        let u = Float(g.x - Double(i)), v = Float(g.y - Double(j))
        let a = base.height(i, j) + (base.height(i + 1, j) - base.height(i, j)) * u
        let b = base.height(i, j + 1) + (base.height(i + 1, j + 1) - base.height(i, j + 1)) * u
        return a + (b - a) * v
    }

    /// A river from `from` to `to` (the world's x, z), wandering `meander` metres to either side of the straight way
    /// (the seed's), a point every 6 m: its bed `depth` under the lowest ground on the way so far (it never runs
    /// uphill), the water at most of its depth over it.
    package static func river(name: String, base: TerrainBase, from: SIMD2<Double>, to: SIMD2<Double>, width: Float, depth: Float,
                      meander: Double, seed: UInt64, look: WaterLook = .preset(.river)) -> (body: WaterBody, channel: TerrainShapes.Channel) {
        let length = simd_distance(from, to), count = max(Int(length / 6), 2)
        let along = (to - from) / max(length, 1e-6), side = SIMD2(-along.y, along.x)
        let phase = Double(seed % 997) * 0.37
        var points: [SIMD2<Double>] = []
        for k in 0...count {
            let t = Double(k) / Double(count), envelope = sin(t * .pi)   // (its ends where they are asked for)
            let wander = meander * envelope * (0.65 * sin(t * 5.3 + phase) + 0.35 * sin(t * 13.1 + phase * 1.7))
            points.append(from + (to - from) * t + side * wander)
        }
        var beds: [Float] = [], lowest = Float.infinity
        for p in points {
            lowest = min(lowest, height(base, p.x, p.y) - depth)
            beds.append(lowest)
        }
        var body = WaterBody(name: name, kind: .river, points: points, width: width, depth: depth)
        body.bed = beds
        body.bedPoints = points
        body.look = look
        return (body, TerrainShapes.Channel(points: points, beds: beds, half: width / 2, depth: depth))
    }

    /// A pond at `center` (radii in x and z): its water at `level`, a bowl `depth` deep under it.
    package static func pond(name: String, center: SIMD2<Float>, radii: SIMD2<Float>, level: Float, depth: Float,
                     look: WaterLook = .preset(.lake)) -> (body: WaterBody, bowl: TerrainShapes.Bowl) {
        var body = WaterBody(name: name, kind: .lake, level: level, seed: SIMD2(Double(center.x), Double(center.y)))
        body.look = look
        return (body, TerrainShapes.Bowl(center: center, radii: radii, level: level, depth: depth))
    }

    /// Where a river's water surface is at its last point (to fill the pond it runs into to that height).
    package static func endLevel(_ river: WaterBody) -> Float { (river.bed?.last ?? 0) + river.depth * 0.8 }
}
