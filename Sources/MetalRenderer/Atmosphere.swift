import CoreGraphics
import Foundation
import ImageIO
import simd

/// The sky's atmosphere on the CPU, with the constants of Shaders/Sky.metal ("Sky and clouds"): the sun light's colour,
/// its irradiance through the atmosphere. (The sky itself is drawn on the GPU.)
enum Atmosphere {
    static let ground: Float = 6360e3, top: Float = 6460e3
    static let rayleigh = SIMD3<Float>(5.802e-6, 13.558e-6, 33.1e-6), rayleighHeight: Float = 8000
    static let mieScatter: Float = 3.996e-6, mieExtinction: Float = 4.440e-6, mieHeight: Float = 1200, mieG: Float = 0.8
    static let ozone = SIMD3<Float>(0.650e-6, 1.881e-6, 0.085e-6)
    /// The sun's irradiance above the atmosphere, in the renderer's units (noon sun on the ground ~2.5).
    static let solarIrradiance = SIMD3<Float>(1.0, 0.96, 0.9) * 3.2
    static let observerAltitude: Float = 2

    private static func extinction(_ h: Float) -> (SIMD3<Float>, SIMD3<Float>, Float) {
        let dR = exp(-h / rayleighHeight), dM = exp(-h / mieHeight), dO = max(0, 1 - abs(h - 25000) / 15000)
        return (rayleigh * dR + mieExtinction * dM + ozone * dO, rayleigh * dR, mieScatter * dM)
    }

    private static func raySphere(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ r: Float) -> (Float, Float)? {
        let b = dot(o, d), c = dot(o, o) - r * r, disc = b * b - c
        guard disc >= 0 else { return nil }
        return (-b - disc.squareRoot(), -b + disc.squareRoot())
    }

    /// Transmittance from p (relative to the planet's centre) toward unit d, to the top of the atmosphere.
    static func transmittance(from p: SIMD3<Float>, toward d: SIMD3<Float>, steps: Int = 32) -> SIMD3<Float> {
        if let g = raySphere(p, d, ground), g.0 > 0 { return .zero }
        guard let t = raySphere(p, d, top)?.1, t > 0 else { return SIMD3(repeating: 1) }
        let dt = t / Float(steps)
        var tau = SIMD3<Float>(repeating: 0)
        for i in 0..<steps { tau += extinction(length(p + d * ((Float(i) + 0.5) * dt)) - ground).0 * dt }
        return SIMD3(exp(-tau.x), exp(-tau.y), exp(-tau.z))
    }

    /// The sun's irradiance at the ground toward unit `sun`: the sun light's colour.
    static func sunIrradiance(toward l: SIMD3<Float>) -> SIMD3<Float> {
        transmittance(from: SIMD3(0, ground + observerAltitude, 0), toward: l) * solarIrradiance
    }
}

/// An equirectangular HDR environment (.hdr, .exr) for the sky, with its sun cut out: the sun light carries it.
struct SkyImage {
    let width: Int, height: Int
    let pixels: [SIMD4<Float>]          // linear radiance, the sun replaced by the sky around it, scaled (see `load`)
    let sunDirection: SIMD3<Float>?     // toward the sun, if the image has one
    let sunIrradiance: SIMD3<Float>
    let sunAngularRadius: Float

    static let fileExtensions: Set<String> = ["hdr", "exr"]

    /// Direction of texel (x, y): u = 0.5 faces -z, v = 0 is straight up (as equirectSample in Shaders/Sky.metal).
    static func direction(u: Float, v: Float) -> SIMD3<Float> {
        let phi = (u - 0.5) * 2 * Float.pi, theta = v * Float.pi
        return SIMD3(sin(theta) * sin(phi), cos(theta), -sin(theta) * cos(phi))
    }

    enum LoadError: Error { case unreadable(String) }

    /// Loads an image (downsampled to at most 2048 wide), finds the sun (the brightest compact spot, far brighter
    /// than the sky) and replaces it by the ring around it, then scales everything so that the light on a level
    /// floor (sun + sky) is about 4 renderer units, times 2^exposure.
    static func load(path: String, exposure: Float = 0) throws -> SkyImage {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
            throw LoadError.unreadable(path)
        }
        let width = min(image.width, 2048), height = max(1, image.height * width / max(image.width, 1))
        var data = [Float](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw LoadError.unreadable(path) }
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                      bytesPerRow: width * 16, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LoadError.unreadable(path) }
        var px = (0..<width * height).map { SIMD4<Float>(data[$0 * 4], data[$0 * 4 + 1], data[$0 * 4 + 2], 1) }
        func lum(_ p: SIMD4<Float>) -> Float { 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z }
        func solidAngle(_ y: Int) -> Float {
            (2 * Float.pi / Float(width)) * (Float.pi / Float(height)) * sin((Float(y) + 0.5) / Float(height) * Float.pi)
        }
        func dir(_ i: Int) -> SIMD3<Float> {
            direction(u: (Float(i % width) + 0.5) / Float(width), v: (Float(i / width) + 0.5) / Float(height))
        }

        // The sun: the brightest texel, if it outshines the sky's median 50 times; its spot is every texel within
        // 4 degrees of it brighter than 10x the ring (4-6 degrees) around.
        let lums = px.map(lum)
        let peak = lums.indices.max { lums[$0] < lums[$1] } ?? 0
        let median = lums.sorted()[lums.count / 2]
        var sunDirection: SIMD3<Float>?
        var sunIrradiance = SIMD3<Float>(repeating: 0)
        var sunRadius: Float = 0.27 * .pi / 180
        if lums[peak] > 50 * max(median, 1e-6) {
            let p = dir(peak)
            let inner = cos(Float(4) * .pi / 180), outer = cos(Float(6) * .pi / 180)
            var ring = SIMD3<Float>(repeating: 0), ringCount: Float = 0
            for i in px.indices {
                let c = dot(dir(i), p)
                if c < inner && c >= outer { ring += SIMD3(px[i].x, px[i].y, px[i].z); ringCount += 1 }
            }
            ring /= max(ringCount, 1)
            var centroid = SIMD3<Float>(repeating: 0), area: Float = 0
            for i in px.indices where dot(dir(i), p) >= inner && lums[i] > 10 * lum(SIMD4(ring, 1)) {
                let excess = SIMD3(px[i].x, px[i].y, px[i].z) - ring
                let w = solidAngle(i / width)
                sunIrradiance += simd_max(excess, .zero) * w
                centroid += dir(i) * max(lum(SIMD4(excess, 1)), 0) * w
                area += w
                px[i] = SIMD4(ring, 1)
            }
            if area > 0, length(centroid) > 0 {
                sunDirection = normalize(centroid)
                sunRadius = min(max((area / .pi).squareRoot(), 0.2 * .pi / 180), 2 * .pi / 180)
            }
        }
        // Cosine-weighted mean radiance of the upper hemisphere (for the scale).
        var ambient = SIMD3<Float>(repeating: 0), weight: Float = 0
        for i in px.indices {
            let d = dir(i)
            guard d.y > 0 else { continue }
            let w = d.y * solidAngle(i / width)
            ambient += SIMD3(px[i].x, px[i].y, px[i].z) * w
            weight += w
        }
        ambient /= max(weight, 1e-6)
        // Scale: sun on a level floor + sky = 4 units (x 2^exposure).
        let floorLight = (sunIrradiance * max(sunDirection?.y ?? 0, 0) + ambient * .pi)
        let scale = 4 / max(0.2126 * floorLight.x + 0.7152 * floorLight.y + 0.0722 * floorLight.z, 1e-6) * pow(2, exposure)
        return SkyImage(width: width, height: height, pixels: px.map { SIMD4(SIMD3($0.x, $0.y, $0.z) * scale, 1) },
                        sunDirection: sunDirection, sunIrradiance: sunIrradiance * scale, sunAngularRadius: sunRadius)
    }
}
