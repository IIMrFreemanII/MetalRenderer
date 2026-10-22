import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// The FFT ocean's starting spectrum (Tessendorf, "Simulating Ocean Water"; JONSWAP with a cos² spread about the
/// wind): per cascade, 256 x 256 complex amplitudes h0(k) and conj(h0(-k)), each wave number with its own random
/// Gaussian pair (seeded: the same sea every run). The GPU (waterSpectrumKernel) turns them in time, ω = √(g k),
/// and the inverse FFT makes the heights, the sideways pushes and their slopes. Each cascade holds the waves of its
/// band of wave numbers only, so the three tiles add up to one sea without counting a wave twice.
enum WaterSpectrum {
    static let gravity = 9.81
    /// The open sea's fetch (m): a sea grown over a long way.
    static let fetch = 300_000.0

    /// The band of wave numbers (rad/m) cascade `c` holds.
    static func band(_ c: Int) -> ClosedRange<Double> {
        let lengths = WaterWaves.lengths.map(Double.init)
        let lo = c == 0 ? 0 : 2 * .pi / lengths[c] * 6
        let hi = c + 1 < lengths.count ? 2 * .pi / lengths[c + 1] * 6 : .infinity
        return lo...hi
    }

    /// JONSWAP's energy at angular frequency ω for a wind of `wind` m/s, over the fetch (no longer than the sea
    /// grows over: past it, it is fully developed and the fetch-limited fit overshoots).
    static func jonswap(_ omega: Double, wind: Double) -> Double {
        let g = gravity, U = max(wind, 0.5), F = min(fetch, 1e4 * U * U / g)
        let peak = 22 * pow(g * g / (U * F), 1.0 / 3)
        let alpha = 0.076 * pow(U * U / (F * g), 0.22)
        let sigma = omega <= peak ? 0.07 : 0.09
        let r = exp(-(omega - peak) * (omega - peak) / (2 * sigma * sigma * peak * peak))
        return alpha * g * g / pow(omega, 5) * exp(-1.25 * pow(peak / omega, 4)) * pow(3.3, r)
    }

    /// Cascade `c`'s texels: (h0(k).re, h0(k).im, conj(h0(-k)).re, conj(h0(-k)).im), rows along z.
    static func amplitudes(cascade c: Int, wind: Double, direction: Double, seed: UInt64 = 0x5EA) -> [SIMD4<Float>] {
        let n = WaterWaves.size, L = Double(WaterWaves.lengths[c]), dk = 2 * .pi / L
        let band = band(c), g = gravity
        var h0 = [SIMD2<Float>](repeating: .zero, count: n * n)
        var rng = SplitMix64(seed: seed &+ UInt64(c) &* 0x9E37_79B9)
        for m in 0..<n {
            for i in 0..<n {
                // (Two Gaussians from four uniforms, Box-Muller: drawn for every wave number, kept or not, so a
                // cascade's waves don't depend on its band.)
                let u1 = max(Double(rng.next()), 1e-7), u2 = Double(rng.next())
                let r = (-2 * log(u1)).squareRoot()
                let gauss = SIMD2(r * cos(2 * .pi * u2), r * sin(2 * .pi * u2))
                let kx = Double(i < n / 2 ? i : i - n) * dk, kz = Double(m < n / 2 ? m : m - n) * dk
                let k = (kx * kx + kz * kz).squareRoot()
                guard k > 1e-6, band.contains(k) else { continue }
                let omega = (g * k).squareRoot()
                // Spread: cos² about the wind, a little every way (the short waves', the swell's from elsewhere).
                let theta = atan2(kz, kx) - direction
                let c2 = max(cos(theta), 0)
                let spread = 0.85 * (2 / .pi) * c2 * c2 + 0.15 / (2 * .pi)
                // S(kx, kz) = S(ω) D(θ) dω/dk / k; the shortest ripples damped (capillary range).
                let jacobian: Double = g / (2 * omega) / k
                let damping: Double = exp(-k * k * 0.0001)
                let s: Double = jonswap(omega, wind: wind) * spread * jacobian * damping
                // (Each wave number's complex pair and its opposite make one real wave: a quarter of S dk² each
                // keeps the heights' variance ∫S.)
                let amplitude: Double = (s * dk * dk).squareRoot() / 2
                h0[m * n + i] = SIMD2<Float>(gauss * amplitude)
            }
        }
        var out = [SIMD4<Float>](repeating: .zero, count: n * n)
        for m in 0..<n {
            for i in 0..<n {
                let mi = (n - i) % n, mm = (n - m) % n
                let plus: SIMD2<Float> = h0[m * n + i], minus: SIMD2<Float> = h0[mm * n + mi]
                out[m * n + i] = SIMD4<Float>(plus.x, plus.y, minus.x, -minus.y)
            }
        }
        return out
    }
}
