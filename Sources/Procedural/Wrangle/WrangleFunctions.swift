import EngineCore
import simd

// What a wrangle's snippet calls besides simd's (`length`, `normalize`, `dot`, `cross`, `distance`, `clamp`, `mix`)
// and Foundation's (`sin`, `pow` …): Houdini's names. Inlinable: a compiled snippet runs them per element.

/// A random number in 0..<1 for a seed (the same seed, the same number).
@inlinable package func rand(_ seed: Float) -> Float {
    Float(pcgHash(seed.bitPattern &* 2_654_435_761 ^ 0x9E37_79B9) >> 8) / Float(1 << 24)
}

@inlinable package func rand(_ seed: Int) -> Float { ProcNoise.random(seed, seed: 7) }

/// Three random numbers in 0..<1.
@inlinable package func vrand(_ seed: Int) -> SIMD3<Float> {
    SIMD3(ProcNoise.random(seed, seed: 7, 0), ProcNoise.random(seed, seed: 7, 1), ProcNoise.random(seed, seed: 7, 2))
}

/// Perlin noise, about -1...1; with `octaves`, fractal.
@inlinable package func noise(_ p: SIMD3<Float>, octaves: Int = 1, roughness: Float = 0.5) -> Float {
    octaves <= 1 ? ProcNoise.perlin(p) : ProcNoise.fbm(p, octaves: octaves, roughness: roughness)
}

@inlinable package func vnoise(_ p: SIMD3<Float>, octaves: Int = 1, roughness: Float = 0.5) -> SIMD3<Float> {
    ProcNoise.fbm3(p, octaves: octaves, roughness: roughness)
}

/// Curl of a noise field: a flow without sources or sinks.
@inlinable package func curlnoise(_ p: SIMD3<Float>) -> SIMD3<Float> {
    let e: Float = 1e-2
    func n(_ q: SIMD3<Float>) -> SIMD3<Float> { ProcNoise.fbm3(q, octaves: 1, roughness: 0.5) }
    let dx = (n(p + [e, 0, 0]) - n(p - [e, 0, 0])) / (2 * e)
    let dy = (n(p + [0, e, 0]) - n(p - [0, e, 0])) / (2 * e)
    let dz = (n(p + [0, 0, e]) - n(p - [0, 0, e])) / (2 * e)
    return SIMD3(dy.z - dz.y, dz.x - dx.z, dx.y - dy.x)
}

/// `v` from `omin...omax` to `nmin...nmax`, clamped.
@inlinable package func fit(_ v: Float, _ omin: Float, _ omax: Float, _ nmin: Float, _ nmax: Float) -> Float {
    let t = omax != omin ? min(max((v - omin) / (omax - omin), 0), 1) : 0
    return nmin + (nmax - nmin) * t
}

@inlinable package func fit01(_ v: Float, _ nmin: Float, _ nmax: Float) -> Float { fit(v, 0, 1, nmin, nmax) }

@inlinable package func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inlinable package func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

/// Hermite 0→1 between `lo` and `hi`.
@inlinable package func smooth(_ lo: Float, _ hi: Float, _ v: Float) -> Float {
    let t = hi != lo ? min(max((v - lo) / (hi - lo), 0), 1) : 0
    return t * t * (3 - 2 * t)
}

@inlinable package func radians(_ d: Float) -> Float { d * .pi / 180 }
@inlinable package func degrees(_ r: Float) -> Float { r * 180 / .pi }

/// A quaternion (x, y, z, w) turning `angle` radians about `axis`; `qrotate` turns a vector by one.
@inlinable package func quaternion(_ angle: Float, _ axis: SIMD3<Float>) -> SIMD4<Float> {
    simd_quatf(angle: angle, axis: simd_length(axis) > 0 ? simd_normalize(axis) : [0, 1, 0]).vector
}

@inlinable package func qrotate(_ q: SIMD4<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> { simd_quatf(vector: q).act(v) }

/// A quaternion facing +Z along `dir` with +Y toward `up` (copies turned to a direction).
@inlinable package func dihedral(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD4<Float> {
    simd_quatf(from: simd_normalize(a), to: simd_normalize(b)).vector
}
