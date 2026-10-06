import Foundation
import simd

/// Shaders/Hair.metal's hair BSDF on the CPU (Chiang et al. 2016, as pbrt-v3's HairBSDF), for the tests: the same
/// constants and arithmetic.
enum HairBSDF {
    static let betaM: Float = 0.3
    static let betaN: Float = 0.3
    static let alpha: Float = 0.0349
    static let eta: Float = 1.55

    static func i0(_ x: Float) -> Float {
        var val: Float = 0, x2i: Float = 1, ifact: Float = 1, i4: Float = 1
        for i in 0..<10 {
            if i > 1 { ifact *= Float(i) }
            val += x2i / (i4 * ifact * ifact)
            x2i *= x * x
            i4 *= 4
        }
        return val
    }
    static func logI0(_ x: Float) -> Float {
        x > 12 ? x + 0.5 * (-log(2 * .pi) + log(1 / x) + 1 / (8 * x)) : log(i0(x))
    }
    static func mp(_ cosThetaI: Float, _ cosThetaO: Float, _ sinThetaI: Float, _ sinThetaO: Float, _ v: Float) -> Float {
        let a = cosThetaI * cosThetaO / v, b = sinThetaI * sinThetaO / v
        return v <= 0.1 ? exp(logI0(a) - b - 1 / v + 0.6931 + log(1 / (2 * v))) : exp(-b) * i0(a) / (sinh(1 / v) * 2 * v)
    }
    static func fresnel(_ cosI: Float, _ eta: Float) -> Float {
        let c = min(max(cosI, -1), 1)
        let sinI = (max(1 - c * c, 0)).squareRoot(), sinT = sinI / eta
        if sinT >= 1 { return 1 }
        let cosT = (max(1 - sinT * sinT, 0)).squareRoot()
        let par = (eta * c - cosT) / (eta * c + cosT), perp = (c - eta * cosT) / (c + eta * cosT)
        return 0.5 * (par * par + perp * perp)
    }
    static func logistic(_ x: Float, _ s: Float) -> Float {
        let e = exp(-abs(x) / s)
        return e / (s * (1 + e) * (1 + e))
    }
    static func logisticCDF(_ x: Float, _ s: Float) -> Float { 1 / (1 + exp(-x / s)) }
    static func np(_ phi: Float, _ p: Float, _ s: Float, _ gammaO: Float, _ gammaT: Float) -> Float {
        var dphi = phi - (2 * p * gammaT - 2 * gammaO + p * .pi)
        dphi -= 2 * .pi * (((dphi + .pi) / (2 * .pi)).rounded(.down))
        return logistic(dphi, s) / (logisticCDF(.pi, s) - logisticCDF(-.pi, s))
    }
    static func sigmaA(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let b = betaN, b2 = b * b
        let d = 5.969 - 0.215 * b + 2.532 * b2 - 10.73 * b2 * b + 5.574 * b2 * b2 + 0.245 * b2 * b2 * b
        let l = SIMD3<Float>(log(max(c.x, 1e-4)), log(max(c.y, 1e-4)), log(max(c.z, 1e-4))) / d
        return l * l
    }

    /// Hair.metal's stand-in for the light scattered between strands (Kajiya-Kay's diffuse), HAIR_MULTIPLE of a
    /// Lambert surface's.
    static let multiple: Float = 0.7
    static func multiple(tangent: SIMD3<Float>, wi: SIMD3<Float>, color: SIMD3<Float>) -> SIMD3<Float> {
        let c = dot(wi, tangent)
        return color * (multiple * (max(1 - c * c, 0)).squareRoot() / .pi)
    }

    /// What a strand along `tangent`, seen from `view` at `h` across it, sends toward the viewer of light from `wi`
    /// that would light a surface facing it with irradiance 1 (pbrt's f x |cos theta_i|). `sigma`: the pigment's
    /// absorption (nil: from `color`).
    static func scatter(tangent x: SIMD3<Float>, view: SIMD3<Float>, h: Float, wi: SIMD3<Float>, color: SIMD3<Float>,
                        sigma: SIMD3<Float>? = nil) -> SIMD3<Float> {
        var y = view - x * dot(view, x)
        y = length_squared(y) > 1e-10 ? normalize(y) : normalize(cross(x, abs(x.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
        let z = cross(x, y)
        let sinThetaO = min(max(dot(view, x), -1), 1), cosThetaO = (max(1 - sinThetaO * sinThetaO, 0)).squareRoot()
        let sinThetaI = min(max(dot(wi, x), -1), 1), cosThetaI = (max(1 - sinThetaI * sinThetaI, 0)).squareRoot()
        let phi = atan2(dot(wi, z), dot(wi, y))
        let gammaO = asin(min(max(h, -1), 1))
        let sinThetaT = sinThetaO / eta, cosThetaT = (max(1 - sinThetaT * sinThetaT, 0)).squareRoot()
        let etap = (max(eta * eta - sinThetaO * sinThetaO, 0)).squareRoot() / max(cosThetaO, 1e-4)
        let sinGammaT = min(max(h / etap, -1), 1), cosGammaT = (max(1 - sinGammaT * sinGammaT, 0)).squareRoot()
        let gammaT = asin(sinGammaT)
        let sa = sigma ?? sigmaA(color)
        let path = 2 * cosGammaT / max(cosThetaT, 1e-4)
        let t = SIMD3<Float>(exp(-sa.x * path), exp(-sa.y * path), exp(-sa.z * path))
        let f = fresnel(cosThetaO * (max(1 - h * h, 0)).squareRoot(), eta)
        let a0 = SIMD3<Float>(repeating: f), a1 = (1 - f) * (1 - f) * t, a2 = a1 * t * f
        let a3 = a2 * f * t / simd_max(SIMD3<Float>(repeating: 1) - t * f, SIMD3(repeating: 1e-4))
        let bm = betaM
        var v0 = 0.726 * bm + 0.812 * bm * bm + 3.7 * pow(bm, 20)
        v0 *= v0
        let bn = betaN
        let s: Float = 0.626657069 * (0.265 * bn + 1.194 * bn * bn + 5.372 * pow(bn, 22))
        let s1 = sin(alpha), c1 = (1 - s1 * s1).squareRoot()
        let s2 = 2 * c1 * s1, c2 = c1 * c1 - s1 * s1
        let s4 = 2 * c2 * s2, c4 = c2 * c2 - s2 * s2
        let sinR = sinThetaO * c2 - cosThetaO * s2, cosR = abs(cosThetaO * c2 + sinThetaO * s2)
        let sinTT = sinThetaO * c1 + cosThetaO * s1, cosTT = abs(cosThetaO * c1 - sinThetaO * s1)
        let sinTRT = sinThetaO * c4 + cosThetaO * s4, cosTRT = abs(cosThetaO * c4 - sinThetaO * s4)
        var sum = mp(cosThetaI, cosR, sinThetaI, sinR, v0) * a0 * np(phi, 0, s, gammaO, gammaT)
        sum += mp(cosThetaI, cosTT, sinThetaI, sinTT, 0.25 * v0) * a1 * np(phi, 1, s, gammaO, gammaT)
        sum += mp(cosThetaI, cosTRT, sinThetaI, sinTRT, 4 * v0) * a2 * np(phi, 2, s, gammaO, gammaT)
        sum += mp(cosThetaI, cosThetaO, sinThetaI, sinThetaO, 4 * v0) * a3 / (2 * .pi)
        return simd_max(sum, .zero)
    }
}
