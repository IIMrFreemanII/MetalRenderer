import simd

/// Small geometry and colour helpers every module's builders use (Scene's statics of the same names forward here).
package enum Geo {
    /// Degrees in radians.
    package static func degrees(_ d: Float) -> Float { d * .pi / 180 }

    /// Unit-luminance colour.
    package static func hue(_ c: SIMD3<Float>) -> SIMD3<Float> { c / dot(c, [0.2126, 0.7152, 0.0722]) }

    /// A unit vector perpendicular to `n` (unit).
    package static func perpendicular(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let h = cross(SIMD3<Float>(0, 1, 0), n)
        return length(h) > 1e-4 ? normalize(h) : normalize(cross(SIMD3<Float>(1, 0, 0), n))
    }

    /// Rotation taking +Y to `d` (unit).
    package static func alignY(_ d: SIMD3<Float>) -> float4x4 {
        if dot(d, [0, 1, 0]) < -0.9999 { return rotate(.pi, [1, 0, 0]) }
        return float4x4(simd_quatf(from: [0, 1, 0], to: d))
    }
}
