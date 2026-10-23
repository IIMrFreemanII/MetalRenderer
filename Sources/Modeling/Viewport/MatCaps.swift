import Foundation
import Metal
import simd

/// MatCaps made here, not read from files: each a lit sphere seen head on (a material's look under a fixed light),
/// that a surface samples by its view-space normal. Blender ships images; these are their likes, computed.
package enum MatCaps {
    package static let names = ["Clay", "Clay Brown", "Red Wax", "Jade", "Metal", "Skin", "Toon", "Normals"]
    package static let size = 256

    /// All of them as a texture array, one slice each (sRGB-encoded RGBA8, sampled as linear).
    package static func texture(_ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .rgba8Unorm_srgb
        d.width = size
        d.height = size
        d.arrayLength = names.count
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        for (i, _) in names.enumerated() {
            let pixels = image(i)
            pixels.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: i,
                          withBytes: raw.baseAddress!, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
            }
        }
        return t
    }

    /// One matcap's pixels (RGBA8, sRGB).
    package static func image(_ index: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size) * 2 - 1, v = 1 - (Float(y) + 0.5) / Float(size) * 2
                let r2 = u * u + v * v
                let n = r2 < 1 ? SIMD3(u, v, (1 - r2).squareRoot()) : simd_normalize(SIMD3(u, v, 0.001))
                let c = shade(index, n)
                let o = (y * size + x) * 4
                out[o] = encode(c.x); out[o + 1] = encode(c.y); out[o + 2] = encode(c.z); out[o + 3] = 255
            }
        }
        return out
    }

    private static func encode(_ c: Float) -> UInt8 {
        let l = max(0, min(1, c))
        let s = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255).rounded())))
    }

    /// The colour of a material under the matcaps' light, for a view-space normal.
    private static func shade(_ index: Int, _ n: SIMD3<Float>) -> SIMD3<Float> {
        let key = simd_normalize(SIMD3<Float>(-0.45, 0.6, 0.66)), fill = simd_normalize(SIMD3<Float>(0.8, -0.2, 0.55))
        let view = SIMD3<Float>(0, 0, 1)
        func spec(_ shininess: Float, _ light: SIMD3<Float>) -> Float {
            pow(max(0, simd_dot(n, simd_normalize(light + view))), shininess)
        }
        let diffuse = max(0, simd_dot(n, key)), back = max(0, simd_dot(n, fill))
        let rim = pow(1 - max(0, n.z), 3)
        switch index {
        case 1:   // clay brown
            let a = SIMD3<Float>(0.42, 0.24, 0.15)
            return a * (0.15 + 0.85 * diffuse + 0.25 * back) + SIMD3(repeating: 0.08 * spec(20, key)) + a * rim * 0.3
        case 2:   // red wax: subsurface-like wrap and a sharp highlight
            let wrap = max(0, (simd_dot(n, key) + 0.5) / 1.5)
            let a = SIMD3<Float>(0.55, 0.05, 0.03)
            return a * (0.12 + 0.9 * wrap) + SIMD3(repeating: 0.45 * spec(90, key)) + SIMD3(0.3, 0.05, 0.03) * rim
        case 3:   // jade
            let wrap = max(0, (simd_dot(n, key) + 0.7) / 1.7)
            let a = SIMD3<Float>(0.1, 0.38, 0.22)
            return a * (0.2 + 0.85 * wrap) + SIMD3(repeating: 0.35 * spec(70, key)) + SIMD3(0.2, 0.5, 0.35) * rim * 0.5
        case 4:   // metal: a reflected studio of bands
            let r = 2 * n.z * n - view
            let band = 0.5 + 0.5 * tanh((r.y - 0.1) * 6)
            let env = SIMD3<Float>(0.05, 0.05, 0.06) + band * SIMD3<Float>(0.85, 0.85, 0.9) + max(0, r.x) * 0.15
            return env * 0.9 + SIMD3(repeating: 0.6 * spec(120, key))
        case 5:   // skin
            let wrap = max(0, (simd_dot(n, key) + 0.35) / 1.35)
            let a = SIMD3<Float>(0.75, 0.45, 0.35)
            return a * (0.12 + 0.88 * wrap) + SIMD3(0.5, 0.15, 0.08) * rim * 0.4 + SIMD3(repeating: 0.12 * spec(30, key))
        case 6:   // toon: three steps
            let s: Float = diffuse > 0.6 ? 1 : diffuse > 0.2 ? 0.6 : 0.3
            return SIMD3<Float>(0.75, 0.75, 0.78) * s + SIMD3(repeating: spec(60, key) > 0.5 ? 0.3 : 0)
        case 7:   // normals
            return (n * 0.5 + 0.5) * (n * 0.5 + 0.5)
        default:  // clay: Blender's grey studio
            let a = SIMD3<Float>(repeating: 0.6)
            return a * (0.12 + 0.75 * diffuse + 0.25 * back) + SIMD3(repeating: 0.06 * spec(16, key)) + SIMD3(repeating: 0.12) * rim
        }
    }
}
