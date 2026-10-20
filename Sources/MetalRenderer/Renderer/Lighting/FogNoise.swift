import Foundation
import simd

/// Tiling 3D noise for the volumetric fog's density (fogNoise in Shaders/Fog.metal): three octaves of gradient noise
/// (Perlin) whose lattices repeat every `size` voxels, normalised to mean 0.5 with values in [0, 1].
enum FogNoise {
    static let size = 64

    static func generate() -> [UInt8] {
        let n = size
        let gradients: [SIMD3<Float>] = [[1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0], [1, 0, 1], [-1, 0, 1],
                                         [1, 0, -1], [-1, 0, -1], [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]]
        func hash(_ x: Int, _ y: Int, _ z: Int, _ seed: Int) -> Int {
            var h = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ z &* 83492791 ^ seed &* 2654435761)
            h ^= h >> 13; h = h &* 1274126177; h ^= h >> 16
            return Int(h % 12)
        }
        func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
        /// Gradient noise at p (in lattice cells) with a lattice of `period` cells per axis.
        func perlin(_ p: SIMD3<Float>, period: Int, seed: Int) -> Float {
            let i = SIMD3<Int>(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z)))
            let f = p - SIMD3<Float>(Float(i.x), Float(i.y), Float(i.z))
            var corners = SIMD8<Float>()
            for c in 0..<8 {
                let o = SIMD3<Int>(c & 1, (c >> 1) & 1, c >> 2)
                let q = i &+ o
                let g = gradients[hash((q.x % period + period) % period, (q.y % period + period) % period,
                                       (q.z % period + period) % period, seed)]
                corners[c] = dot(g, f - SIMD3<Float>(Float(o.x), Float(o.y), Float(o.z)))
            }
            let u = SIMD3<Float>(fade(f.x), fade(f.y), fade(f.z))
            func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
            let x00 = lerp(corners[0], corners[1], u.x), x10 = lerp(corners[2], corners[3], u.x)
            let x01 = lerp(corners[4], corners[5], u.x), x11 = lerp(corners[6], corners[7], u.x)
            return lerp(lerp(x00, x10, u.y), lerp(x01, x11, u.y), u.z)
        }

        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: n * n * n)
        defer { buffer.deallocate() }
        DispatchQueue.concurrentPerform(iterations: n) { z in
            for y in 0..<n {
                for x in 0..<n {
                    var v: Float = 0, amplitude: Float = 1
                    for (octave, period) in [4, 8, 16].enumerated() {
                        let p = SIMD3<Float>(Float(x), Float(y), Float(z)) * (Float(period) / Float(n))
                        v += amplitude * perlin(p, period: period, seed: octave)
                        amplitude *= 0.5
                    }
                    buffer[(z * n + y) * n + x] = v
                }
            }
        }
        let values = Array(buffer)
        let mean = values.reduce(0, +) / Float(values.count)
        let deviation = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)).squareRoot()
        // +-2.5 standard deviations span [0, 1].
        return values.map { UInt8(max(0, min(255, (0.5 + ($0 - mean) / (5 * max(deviation, 1e-6))) * 255 + 0.5))) }
    }
}
