import EngineCore
import simd

/// Gradient (Perlin) noise in 3D and its fractal sum, seeded: Attribute Noise's, and the wrangles' `noise`.
@usableFromInline package enum ProcNoise {
    @inlinable @inline(__always)
    static func hash(_ c: SIMD3<Int32>, _ seed: UInt32) -> UInt32 {
        pcgHash(UInt32(bitPattern: c.x) &* 73_856_093 ^ UInt32(bitPattern: c.y) &* 19_349_663
                ^ UInt32(bitPattern: c.z) &* 83_492_791 ^ seed &* 2_654_435_761)
    }

    /// One of the 12 directions to a cube's edge centres, and four more, picked by a hash.
    @inlinable @inline(__always)
    static func gradient(_ h: UInt32, _ d: SIMD3<Float>) -> Float {
        switch h & 15 {
        case 0: d.x + d.y
        case 1: -d.x + d.y
        case 2: d.x - d.y
        case 3: -d.x - d.y
        case 4: d.x + d.z
        case 5: -d.x + d.z
        case 6: d.x - d.z
        case 7: -d.x - d.z
        case 8: d.y + d.z
        case 9: -d.y + d.z
        case 10: d.y - d.z
        case 11: -d.y - d.z
        case 12: d.x + d.y
        case 13: -d.x + d.y
        case 14: -d.y + d.z
        default: -d.y - d.z
        }
    }

    /// Noise at `p`, about -1...1, smooth, 0 on the lattice's points.
    @inlinable
    package static func perlin(_ p: SIMD3<Float>, seed: UInt32 = 0) -> Float {
        let f = p.rounded(.down)
        let c = SIMD3<Int32>(f)
        let d = p - f
        let u = d * d * d * (d * (d * 6 - 15) + 10)
        let g000 = gradient(hash(c, seed), d)
        let g100 = gradient(hash(c &+ SIMD3(1, 0, 0), seed), d - [1, 0, 0])
        let g010 = gradient(hash(c &+ SIMD3(0, 1, 0), seed), d - [0, 1, 0])
        let g110 = gradient(hash(c &+ SIMD3(1, 1, 0), seed), d - [1, 1, 0])
        let g001 = gradient(hash(c &+ SIMD3(0, 0, 1), seed), d - [0, 0, 1])
        let g101 = gradient(hash(c &+ SIMD3(1, 0, 1), seed), d - [1, 0, 1])
        let g011 = gradient(hash(c &+ SIMD3(0, 1, 1), seed), d - [0, 1, 1])
        let g111 = gradient(hash(c &+ SIMD3(1, 1, 1), seed), d - [1, 1, 1])
        let x00 = g000 + (g100 - g000) * u.x, x10 = g010 + (g110 - g010) * u.x
        let x01 = g001 + (g101 - g001) * u.x, x11 = g011 + (g111 - g011) * u.x
        let y0 = x00 + (x10 - x00) * u.y, y1 = x01 + (x11 - x01) * u.y
        return (y0 + (y1 - y0) * u.z) * 0.9
    }

    /// `octaves` of noise, each twice the frequency of the last and `roughness` times its amplitude.
    @inlinable
    package static func fbm(_ p: SIMD3<Float>, octaves: Int, roughness: Float, seed: UInt32 = 0) -> Float {
        var sum: Float = 0, amp: Float = 1, q = p, total: Float = 0
        for o in 0..<max(1, octaves) {
            sum += perlin(q, seed: seed &+ UInt32(o) &* 1013) * amp
            total += amp
            amp *= roughness
            q *= 2
        }
        return sum / max(total, 1e-6)
    }

    /// Three uncorrelated noises: a vector.
    @inlinable
    package static func fbm3(_ p: SIMD3<Float>, octaves: Int, roughness: Float, seed: UInt32 = 0) -> SIMD3<Float> {
        SIMD3(fbm(p, octaves: octaves, roughness: roughness, seed: seed),
              fbm(p + [31.4, 17.7, 9.2], octaves: octaves, roughness: roughness, seed: seed &+ 7),
              fbm(p + [-12.1, 44.6, 23.9], octaves: octaves, roughness: roughness, seed: seed &+ 13))
    }

    /// A random number in 0..<1 for an element and a seed (and a component).
    @inlinable @inline(__always)
    package static func random(_ i: Int, seed: Int, _ component: Int = 0) -> Float {
        let h = pcgHash(UInt32(truncatingIfNeeded: i) &* 2_654_435_761 ^ pcgHash(UInt32(truncatingIfNeeded: seed) &+ UInt32(component) &* 97))
        return Float(h >> 8) / Float(1 << 24)
    }
}
