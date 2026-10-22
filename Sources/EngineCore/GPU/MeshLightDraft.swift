import simd

/// An emissive instance sampled as a light: its triangles are `emissiveTriangles[first ..< first + count]`.
package struct MeshLight {
    package var instance: Int
    package var firstTriangle: Int
    package var triangleCount: Int
    package var center: SIMD3<Float>              // object space bounding sphere of the triangles
    package var radius: Float
    package var normal: SIMD3<Float>              // object space, area-weighted mean normal (zero if closed)
    package var flatness: Float                   // |sum of area x normal| / area: 1 = flat, 0 = closed or round
    package var power: SIMD3<Float>               // sum of emitted radiance x area (object space)
    /// Its material, from its instance's: the triangles of a mesh of several materials that have this one.
    package var materialOffset = 0

    /// (As the memberwise initializer, for the modules above this one.)
    package init(instance: Int, firstTriangle: Int, triangleCount: Int, center: SIMD3<Float>, radius: Float, normal: SIMD3<Float>, flatness: Float, power: SIMD3<Float>, materialOffset: Int = 0) {
        self.instance = instance
        self.firstTriangle = firstTriangle
        self.triangleCount = triangleCount
        self.center = center
        self.radius = radius
        self.normal = normal
        self.flatness = flatness
        self.power = power
        self.materialOffset = materialOffset
    }
}

/// A mesh light's triangles as they are put together: each weighed by area x emitted luminance, and the bounding
/// sphere / mean normal the shaders weigh the whole light by.
package struct MeshLightDraft {
    package private(set) var triangles: [GPUEmissiveTriangle] = []
    private var weights: [Float] = []
    private var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
    private var areaNormal = SIMD3<Float>(repeating: 0), area: Float = 0
    private var power = SIMD3<Float>(repeating: 0)

    /// A triangle that emits `le` (its mean radiance); nothing if it has no area or emits nothing.
    package mutating func add(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, uv0: SIMD2<Float> = .zero, uv1: SIMD2<Float> = .zero,
                      uv2: SIMD2<Float> = .zero, emission le: SIMD3<Float>) {
        let e1 = p1 - p0, e2 = p2 - p0
        let cr = cross(e1, e2)
        let triArea = length(cr) / 2
        guard triArea > 0 else { return }
        let w = triArea * dot(le, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        guard w > 0 else { return }
        weights.append(w)
        triangles.append(GPUEmissiveTriangle(v0: SIMD4(p0, 0), e1: SIMD4(e1, uv0.x), e2: SIMD4(e2, uv0.y),
                                             uv12: SIMD4(uv1.x, uv1.y, uv2.x, uv2.y)))
        for p in [p0, p1, p2] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        areaNormal += cr / 2
        area += triArea
        power += le * triArea
    }

    /// The light of `instance`, its triangles from `firstTriangle` (their `v0.w` now the running share of its
    /// power); nil if nothing was added.
    package mutating func finish(instance: Int, firstTriangle: Int) -> MeshLight? {
        guard !weights.isEmpty else { return nil }
        let total = weights.reduce(0, +)
        var running: Float = 0
        for (k, w) in weights.enumerated() {
            running += w
            triangles[k].v0.w = k == weights.count - 1 ? 1 : running / total
        }
        return MeshLight(instance: instance, firstTriangle: firstTriangle, triangleCount: weights.count, center: (lo + hi) / 2,
                         radius: max(length(hi - lo) / 2, 1e-3), normal: length(areaNormal) > 0 ? normalize(areaNormal) : .zero,
                         flatness: min(length(areaNormal) / area, 1), power: power)
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(triangles: [GPUEmissiveTriangle] = []) {
        self.triangles = triangles
    }
}
