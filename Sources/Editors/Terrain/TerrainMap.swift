import Buildings
import Characters
import CoreGraphics
import Effects
import EngineCore
import Foundation
import Materials
import MetalRenderer
import Physics
import Plants
import simd

/// The Terrain Editor's map: a picture of a terrain from above, drawn from a snapshot (any thread) — its heights in
/// colour with the light from the north-west on them, its slope, its strongest layer, or where it was edited — and
/// which part of the world it shows.
struct TerrainMap {
    enum View: String, CaseIterable, Identifiable {
        case shaded, slope, layers, edits
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shaded: return "Height"
            case .slope: return "Slope"
            case .layers: return "Layers"
            case .edits: return "Edits"
            }
        }
    }

    let image: CGImage
    /// The world's x, z of the picture's top-left corner and bottom-right one (x right, z down).
    let lo: SIMD2<Double>
    let hi: SIMD2<Double>
    /// The tiles it shows.
    let tiles: [SIMD2<Int>]
    let low: Float, high: Float

    /// The square of the world to show: a finite terrain whole, an endless one `reach` tiles around `center`.
    static func region(_ grid: TerrainGrid, around center: SIMD2<Double>, reach: Int = 3) -> (lo: SIMD2<Double>, hi: SIMD2<Double>) {
        if let lo = grid.lo, let hi = grid.hi { return (grid.place(lo.x, lo.y), grid.place(hi.x, hi.y)) }
        let g = grid.coordinates(center.x, center.y)
        let t = grid.tile(Int(g.x.rounded(.down)), Int(g.y.rounded(.down)))
        return (grid.corner(t &- reach), grid.corner(t &+ (reach + 1)))
    }

    /// Layer colours for the layers view (their own colour, a little brighter).
    static func colour(_ layers: [TerrainLayer], _ l: Int) -> SIMD3<Float> {
        guard l < layers.count else { return [0.5, 0.5, 0.5] }
        return min(layers[l].color * 1.6 + 0.05, SIMD3(repeating: 1))
    }

    static func draw(_ s: TerrainSnapshot, layers: [TerrainLayer], lo: SIMD2<Double>, hi: SIMD2<Double>, side: Int, view: View) -> TerrainMap? {
        let n = side, step = (hi - lo) / Double(n)
        var heights = [Float](repeating: 0, count: (n + 1) * (n + 1))
        heights.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n + 1) { j in
                for i in 0...n {
                    let p = lo + SIMD2(Double(i), Double(j)) * step
                    out[j * (n + 1) + i] = s.height(x: p.x, z: p.y)
                }
            }
        }
        let low = heights.min() ?? 0, high = max(heights.max() ?? 1, low + 0.01)
        var pixels = [UInt8](repeating: 255, count: n * n * 4)
        let cellX = Float(step.x), cellZ = Float(step.y)
        pixels.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: n) { j in
                for i in 0..<n {
                    let a = heights[j * (n + 1) + i], b = heights[j * (n + 1) + i + 1], c = heights[(j + 1) * (n + 1) + i]
                    let dx = (b - a) / cellX, dz = (c - a) / cellZ
                    let normal = simd_normalize(SIMD3(-dx, 1, -dz))
                    let light = max(simd_dot(normal, simd_normalize(SIMD3<Float>(-1, 1.6, -1))), 0) * 0.75 + 0.25
                    var colour: SIMD3<Float>
                    switch view {
                    case .shaded:
                        let t = (a - low) / (high - low)
                        colour = TerrainMap.hypsometric(t) * light
                    case .slope:
                        let slope = atan((dx * dx + dz * dz).squareRoot()) * 180 / .pi
                        let t = min(slope / 45, 1)
                        let flat: SIMD3<Float> = SIMD3<Float>(0.2, 0.55, 0.25) * (1 - t)
                        let steep: SIMD3<Float> = SIMD3<Float>(0.9, 0.25, 0.15) * t
                        colour = (flat + steep) * (0.6 + 0.4 * light)
                    case .layers:
                        let p = lo + SIMD2(Double(i) + 0.5, Double(j) + 0.5) * step
                        let g = s.grid.coordinates(p.x, p.y)
                        let si = s.grid.clamp(Int(g.x.rounded()), Int(g.y.rounded()))
                        let slope = atan((dx * dx + dz * dz).squareRoot()) * 180 / .pi
                        let w = TerrainPaint.weights(s, layers: layers, si.x, si.y, height: a, slope: slope)
                        var mix = SIMD3<Float>()
                        for l in 0..<16 where w[l] > 0.01 { mix += TerrainMap.colour(layers, l) * w[l] }
                        colour = mix * (0.55 + 0.45 * light)
                    case .edits:
                        let p = lo + SIMD2(Double(i) + 0.5, Double(j) + 0.5) * step
                        let g = s.grid.coordinates(p.x, p.y)
                        let si = s.grid.clamp(Int(g.x.rounded()), Int(g.y.rounded()))
                        let d = s.delta(si.x, si.y)
                        let t = min(abs(d) / 10, 1)
                        let base = SIMD3<Float>(repeating: 0.35 * light)
                        colour = base * (1 - t) + (d > 0 ? SIMD3<Float>(1, 0.55, 0.2) : SIMD3<Float>(0.25, 0.55, 1)) * t
                        if s.paint(si.x, si.y) != nil { colour = colour * 0.7 + SIMD3<Float>(0.3, 0.9, 0.3) * 0.3 }
                        if s.protection(si.x, si.y) > 0.5 { colour = colour * 0.75 + SIMD3<Float>(0.6, 0.6, 0.9) * 0.25 }
                    }
                    let k = (j * n + i) * 4
                    out[k] = UInt8(min(max(colour.x, 0), 1) * 255)
                    out[k + 1] = UInt8(min(max(colour.y, 0), 1) * 255)
                    out[k + 2] = UInt8(min(max(colour.z, 0), 1) * 255)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let g0 = s.grid.coordinates(lo.x, lo.y), g1 = s.grid.coordinates(hi.x - 1e-6, hi.y - 1e-6)
        let tiles = s.grid.tiles(from: SIMD2(Int(g0.x.rounded(.down)), Int(g0.y.rounded(.down))),
                                 to: SIMD2(Int(g1.x.rounded(.down)), Int(g1.y.rounded(.down))))
        return TerrainMap(image: image, lo: lo, hi: hi, tiles: tiles, low: low, high: high)
    }

    /// Low green, through brown, to grey and white high up.
    static func hypsometric(_ t: Float) -> SIMD3<Float> {
        let stops: [(Float, SIMD3<Float>)] = [(0, [0.16, 0.36, 0.2]), (0.35, [0.45, 0.55, 0.28]), (0.6, [0.6, 0.5, 0.33]),
                                              (0.85, [0.55, 0.52, 0.5]), (1, [0.95, 0.95, 0.97])]
        let x = min(max(t, 0), 1)
        for k in 1..<stops.count where x <= stops[k].0 {
            let (a, ca) = stops[k - 1], (b, cb) = stops[k]
            return ca + (cb - ca) * ((x - a) / max(b - a, 1e-5))
        }
        return stops.last!.1
    }
}
