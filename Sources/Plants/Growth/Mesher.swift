import EngineCore
import simd

extension Growth {
    /// How a grown skeleton becomes wood (Unreal's Mesh Builder, its profile and noise): each branch thinner than the
    /// one it grows on, every axis wandering a little, the trunk lobed and flared at its foot.
    package struct Wood: Codable, Equatable {
        package var thinning: Float = 0.72          // each generation's radius, of its parent generation's
        package var noise: Float = 0.05             // how far the axes wander (m, the trunk's; branches half)
        package var noiseScale: Float = 0.7         // ...in waves of about 1 / this metres
        package var flare: Float = 0.45             // the foot's extra girth
        package var flareHeight: Float = 1.4        // ...fading out by this height (m)
        package var lobes = 5                       // the trunk's buttresses round it
        package var lobeDepth: Float = 0.22         // ...how deep the hollows between them are (of the radius)
        package var ribbon = false                  // flat stems (a fern's fronds), meshed as ribbons with their leaves

        package init() {}
    }

    // MARK: - Noise (deterministic, smooth)

    @inline(__always) static func lattice(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6B343 ^ UInt32(bitPattern: y) &* 0xD8163841 ^ UInt32(bitPattern: z) &* 0xCB1AB31F ^ seed
        h ^= h >> 13
        h &*= 0x5BD1E995
        h ^= h >> 15
        return Float(h & 0xFFFF) / 32767.5 - 1
    }

    /// Value noise in -1...1, smooth (trilinear over a hashed lattice, smoothstepped).
    static func noise(_ p: SIMD3<Float>, _ seed: UInt32) -> Float {
        let f = floor(p), t = p - f
        let s = t * t * (3 - 2 * t)
        let x = Int32(f.x), y = Int32(f.y), z = Int32(f.z)
        func l(_ i: Int32, _ j: Int32, _ k: Int32) -> Float { lattice(x + i, y + j, z + k, seed) }
        let a = simd_mix(l(0, 0, 0), l(1, 0, 0), s.x), b = simd_mix(l(0, 1, 0), l(1, 1, 0), s.x)
        let c = simd_mix(l(0, 0, 1), l(1, 0, 1), s.x), d = simd_mix(l(0, 1, 1), l(1, 1, 1), s.x)
        return simd_mix(simd_mix(a, b, s.y), simd_mix(c, d, s.y), s.z)
    }

    // MARK: - The trunk's profile

    /// The trunk's girth at angle `a` round it, of its radius: lobes with hollows between, the deepest 1 - depth, the
    /// fullest 1 (a second, finer wave and a turn by the seed make no two trunks alike).
    static func profile(_ a: Float, _ w: Wood, _ seed: UInt32) -> Float {
        let turn = Float(seed & 0xFFFF) / 65536 * 2 * .pi
        let main = 0.5 + 0.5 * cos(Float(w.lobes) * a + turn)
        let fine = 0.5 + 0.5 * cos(Float(w.lobes * 2 + 1) * a + turn * 1.7)
        return 1 - w.lobeDepth * (1 - (0.75 * main + 0.25 * fine))
    }

    // MARK: - Meshing

    /// The size of `stems`' wood: a ring at each node but the last, which is one vertex (a pointed tip).
    static func woodSize(_ s: Foliage.Skeleton, _ stems: [Int], relief: Bool = false) -> Foliage.MeshSize {
        var size = Foliage.MeshSize()
        for i in stems {
            let stem = s.stems[i], rings = Int(stem.count) - 1, sides = sideCount(stem, s, relief: relief)
            size.vertices += rings * sides + 1
            size.indices += (rings - 1) * sides * 6 + sides * 3
        }
        return size
    }

    /// The wood of `stems` (all of them if nil) of a grown skeleton: tubes with UVs round them (mirrored, no seam;
    /// plus the stem's generation, 0 the trunk, so a material can tell trunk from branch) and along them in turns of
    /// their girth there (square texels as they taper).
    /// A stem's sides: its own (a ribbon's three here), twice as many on thick wood with bark relief.
    static func sideCount(_ stem: Foliage.Stem, _ s: Foliage.Skeleton, relief: Bool) -> Int {
        let sides = max(Int(stem.radial), 3)
        return relief && s.nodes[Int(stem.first)].w > 0.03 ? sides * 2 : sides
    }

    /// `bark`: the realistic look's relief (realism high), each vertex of thick wood pushed out by the bark's height
    /// at its UV, at most 15% of the radius either way.
    package static func wood(_ s: Foliage.Skeleton, stems: [Int]?, _ w: Wood, up: SIMD3<Float>, seed: UInt64,
                             bark: Foliage.Bark? = nil) -> Foliage.Mesh {
        let stems = stems ?? Array(s.stems.indices)
        let lobeSeed = UInt32(truncatingIfNeeded: seed ^ (seed >> 32))
        return Foliage.build(woodSize(s, stems, relief: bark != nil)) { m in
            s.nodes.withUnsafeBufferPointer { nodes in
                for i in stems {
                    tube(s.stems[i], nodes.baseAddress!, w, up: normalize(up), lobeSeed: lobeSeed,
                         sides: sideCount(s.stems[i], s, relief: bark != nil), bark: bark, into: &m)
                }
            }
            return (m.vertices, m.written)
        }
    }

    private static func tube(_ stem: Foliage.Stem, _ nodes: UnsafePointer<SIMD4<Float>>, _ w: Wood, up: SIMD3<Float>,
                             lobeSeed: UInt32, sides: Int, bark: Foliage.Bark?, into m: inout Foliage.MeshWriter) {
        let n = Int(stem.count), rings = n - 1
        let node = nodes + Int(stem.first)
        let first = UInt32(m.vertices)
        let trunk = stem.level == 0
        let generation = Float(stem.level)
        let step = 2 * Float.pi / Float(sides)
        var across = SIMD3<Float>(), v: Float = 0
        for i in 0..<rings {
            let p = Foliage.xyz(node[i]), r = max(node[i].w, 0.0015)
            let t = normalize(Foliage.xyz(node[min(i + 1, n - 1)]) - Foliage.xyz(node[max(i - 1, 0)]))
            // The frame carried along the stem (no twist), starting across `up`.
            across -= t * dot(across, t)
            across = i == 0 || length_squared(across) < 1e-6 ? Foliage.perpendicular(t, up: up) : normalize(across)
            let other = cross(t, across)
            if i > 0 { v += length(p - Foliage.xyz(node[i - 1])) / (2 * .pi * r) }
            // The trunk's foot: flared, and lobed, both fading out with height.
            let fade = trunk ? pow(max(1 - p.y / max(w.flareHeight, 1e-3), 0), 2) : 0
            let girth = r * (1 + w.flare * fade)
            for k in 0..<sides {
                let a = Float(k) * step
                let d = across * cos(a) + other * sin(a)
                var out = girth, normal = d
                if fade > 0 {
                    let shape = 1 + (profile(a, w, lobeSeed) - 1) * fade
                    let slope = (profile(a + 0.01, w, lobeSeed) - profile(a - 0.01, w, lobeSeed)) / 0.02 * fade
                    out = girth * shape
                    // The outward normal of r(a): r d - r'(a) along the turn.
                    let tangent = -across * sin(a) + other * cos(a)
                    normal = normalize(d * shape - tangent * slope)
                }
                let around = (1 - abs(2 * Float(k) / Float(sides) - 1)) * 0.998
                if let bark, girth > 0.03 {
                    out += min(max(bark.relief * (bark.height.sample(around, v) - 0.5), -0.15 * girth), 0.15 * girth)
                }
                m.vertex(p + d * out, normal, SIMD2(around + generation, v))
            }
        }
        let end = Foliage.xyz(node[n - 1]), before = Foliage.xyz(node[n - 2])
        let tip = m.vertex(end, normalize(end - before), SIMD2(0.5 + generation, v + length(end - before) / (2 * .pi * max(node[n - 2].w, 0.0015))))
        let per = UInt32(sides)
        for i in 0..<UInt32(rings - 1) {
            let a = first + i * per, b = a + per
            for k in 0..<per {
                let k1 = k + 1 == per ? 0 : k + 1
                m.triangle(a + k, a + k1, b + k1)
                m.triangle(a + k, b + k1, b + k)
            }
        }
        let last = first + UInt32(rings - 1) * per
        for k in 0..<per { m.triangle(last + k, last + (k + 1 == per ? 0 : k + 1), tip) }
    }
}
