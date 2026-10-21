import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// The realistic look's relief on the CPU (realism high): how far the ground's blended scans raise or sink it at a
/// place, by the same height lerp as the shader's (Shaders/Surface.metal terrainRealistic) over the same layers (the
/// scene's own ground map's, rock on steep ground, the three strongest painted), so that the displaced mesh and its
/// texture agree. Each layer's height (its scan's, 0...1) about its middle, times its relief in metres.
package final class GroundRelief {
    package struct Layer {
        package var height: TextureSet.HeightField?
        package var scale: Float          // UV per metre, as the shader's
        package var contrast: Float
        package var relief: Float         // metres from the height's lowest to its highest
    }
    let ground: [Layer]
    /// Layers 1...15 (index l - 1): a painted layer's, nil for one without a scan.
    let painted: [Layer?]
    /// The ground map's two images (Terrain/GroundLook.swift draw), and the rectangle they cover (scene x, z).
    let maps: (FoliageTextures.Image, FoliageTextures.Image)?
    let lo: SIMD2<Float>, size: SIMD2<Float>
    let rock: Int
    let slope: SIMD2<Float>
    /// The world's place that is the scene's origin.
    let offset: SIMD2<Double>

    static let blendDepth: Float = 0.12   // TERRAIN_BLEND_DEPTH

    package init(ground: [Layer], painted: [Layer?], maps: (FoliageTextures.Image, FoliageTextures.Image)?, lo: SIMD2<Float>, size: SIMD2<Float>,
         rock: Int, slope: SIMD2<Float>, offset: SIMD2<Double>) {
        (self.ground, self.painted, self.maps, self.lo, self.size, self.rock, self.slope, self.offset) =
            (ground, painted, maps, lo, size, rock, slope, offset)
    }

    /// A scan's relief in metres, by its name: rock most, then stones and soil (clods, ruts, roots), the soft
    /// grounds least. (What the mesh's 0.25 m can hold: the parallax adds what is finer.)
    static func relief(of set: String) -> Float {
        switch set {
        case "rock": return 0.3
        case "pebbles", "gravel": return 0.1
        case "earth", "ground", "forest-floor": return 0.1
        case "mud", "sand", "snow", "moss": return 0.06
        default: return 0.04
        }
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The map's weights at scene place `p` (bilinear between texel centres, as the GPU's linear filter).
    private func mapWeights(_ p: SIMD2<Float>) -> [Float] {
        guard let (a, b) = maps else { return [] }
        let n = a.width
        let uv = simd_clamp((p - lo) / size, SIMD2(repeating: 0.0005), SIMD2(repeating: 0.9995))
        let x = uv.x * Float(n) - 0.5, y = uv.y * Float(n) - 0.5
        let x0 = max(Int(x.rounded(.down)), 0), y0 = max(Int(y.rounded(.down)), 0)
        let x1 = min(x0 + 1, n - 1), y1 = min(y0 + 1, n - 1)
        let fx = min(max(x - Float(x0), 0), 1), fy = min(max(y - Float(y0), 0), 1)
        var out = [Float](repeating: 0, count: 8)
        for k in 0..<8 {
            let img = k < 4 ? a : b, c = k & 3
            func at(_ i: Int, _ j: Int) -> Float { Float(img.pixels[(j * n + i) * 4 + c]) / 255 }
            let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * fx, bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * fx
            out[k] = top + (bottom - top) * fy
        }
        return out
    }

    /// The relief (metres, up) at the world's place (x, z), where the ground's normal's y is `up` and the vertex's
    /// layer weights are `w` (0...1; layer 0 the scene's own ground).
    func callAsFunction(x: Double, z: Double, up: Float, weights w: SIMD16<Float>) -> Float {
        var best = (0, 0, 0), strongest: (Float, Float, Float) = (0, 0, 0)
        for l in 1..<16 {
            let v = w[l]
            if v <= strongest.2 { continue }
            if v > strongest.0 {
                (strongest.2, best.2) = (strongest.1, best.1)
                (strongest.1, best.1) = (strongest.0, best.0)
                (strongest.0, best.0) = (v, l)
            } else if v > strongest.1 {
                (strongest.2, best.2) = (strongest.1, best.1)
                (strongest.1, best.1) = (v, l)
            } else {
                (strongest.2, best.2) = (v, l)
            }
        }
        let total = max(w[0] + strongest.0 + strongest.1 + strongest.2, 1e-4)
        var own = w[0] / total
        let p = SIMD2(Float(x - offset.x), Float(z - offset.y))
        var candidates: [(layer: Layer?, weight: Float)] = []
        let raw = (p - lo) / size, edge = simd_min(raw, 1 - raw)
        let mapped: Float = maps != nil && !ground.isEmpty ? min(max(min(edge.x, edge.y) / 0.03, 0), 1) : 0
        if own > 0 && mapped < 1 { candidates.append((nil, own * (1 - mapped))) }
        own *= mapped
        if own > 0 {
            var aw = mapWeights(p)
            if rock >= 0 && rock < 8 {
                let r = 1 - Self.smooth(slope.x, slope.y, up)
                for k in 0..<8 { aw[k] *= 1 - r }
                aw[rock] += r
            }
            let count = min(ground.count, 8), sum = max(aw.prefix(count).reduce(0, +), 1e-4)
            for k in 0..<count where candidates.count < 5 {
                let v = aw[k] / sum * own
                if v >= 0.02 { candidates.append((ground[k], v)) }
            }
        }
        for (l, v) in [(best.0, strongest.0), (best.1, strongest.1), (best.2, strongest.2)] {
            let share = v / total
            guard share >= 0.02, l >= 1, l - 1 < painted.count else { continue }
            candidates.append((painted[l - 1], share))
        }
        guard !candidates.isEmpty else { return 0 }
        // The height lerp: each one's height on its weight; those within blendDepth of the highest share.
        var heights = [Float](), blends = [Float]()
        for c in candidates {
            let h = c.layer.flatMap { l in l.height.map { $0.sample(Float(x) * l.scale, Float(z) * l.scale) } } ?? 0.5
            heights.append(h)
            blends.append(c.weight + h * (c.layer?.contrast ?? 0) * 0.5)
        }
        let top = blends.max()!
        var sum: Float = 0, out: Float = 0
        for i in candidates.indices {
            let b = max(blends[i] - (top - Self.blendDepth), 0)
            sum += b
            out += b * (heights[i] - 0.5) * (candidates[i].layer?.relief ?? 0)
        }
        return sum > 0 ? out / sum : 0
    }
}
