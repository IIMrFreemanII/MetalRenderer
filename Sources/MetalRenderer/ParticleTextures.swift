import Foundation
import Metal
import simd

/// The particles' flipbooks (ParticleTrace.metal's `particleTexel`): one layer of a texture array per kind, `grid` x
/// `grid` frames of `cell` pixels, frame k at column k % grid, row k / grid. Generated at load, no assets to ship:
/// the layers are made once and kept in the user's cache folder as raw RGBA (a new `version` makes new files).
/// Every frame's picture fades to nothing a few pixels inside its cell, so the linear filter never reaches the next.
enum ParticleTextures {
    enum Kind: Int, CaseIterable {
        /// A soft round dot (motes, glows).
        case dot
        /// A puff of smoke that billows over its frames.
        case smoke
        /// A flame licking upward (unlit: its colour is the heat's, white to red).
        case flame
        /// A hot point and its glow.
        case spark
        /// A thin streak along the quad (rain, tracers: the velocity orientation).
        case streak
        /// A ring that spreads and fades (splashes, shockwaves).
        case ring
        /// 64 glyphs of strokes in a circle (a frame each).
        case rune
        /// A bubble: its rim and a highlight.
        case bubble
    }
    static let grid = 8
    static let frames = grid * grid
    static let cell = 64
    static var size: Int { grid * cell }
    static let version = 5

    /// How far a kind's picture reaches from its cell's centre (0...1 of the half cell), over all its frames: the
    /// particle's box is trimmed to it (GPUParticleEmitter.flip.w). ParticleTests checks it covers the pictures.
    static func trim(_ k: Kind) -> Float {
        switch k {
        case .dot: return 0.8
        case .spark: return 0.75
        case .smoke: return 0.97
        case .flame: return 0.97
        case .streak: return 1
        case .ring: return 1
        case .rune: return 0.97
        case .bubble: return 0.97
        }
    }

    // MARK: - Noise

    private static func hash(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> Float {
        let h = ParticleMath.hash(UInt32(bitPattern: x) &+ ParticleMath.hash(UInt32(bitPattern: y) &+ ParticleMath.hash(UInt32(bitPattern: z) &+ seed)))
        return Float(h) * (1.0 / 4294967296.0)
    }

    /// Value noise in 3D, smooth (quintic), 0...1.
    private static func noise(_ p: SIMD3<Float>, _ seed: UInt32) -> Float {
        let i = floor(p), f = p - i
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        let x = Int32(i.x), y = Int32(i.y), z = Int32(i.z)
        func h(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float { hash(x + dx, y + dy, z + dz, seed) }
        let x00 = h(0, 0, 0) + (h(1, 0, 0) - h(0, 0, 0)) * u.x, x10 = h(0, 1, 0) + (h(1, 1, 0) - h(0, 1, 0)) * u.x
        let x01 = h(0, 0, 1) + (h(1, 0, 1) - h(0, 0, 1)) * u.x, x11 = h(0, 1, 1) + (h(1, 1, 1) - h(0, 1, 1)) * u.x
        let y0 = x00 + (x10 - x00) * u.y, y1 = x01 + (x11 - x01) * u.y
        return y0 + (y1 - y0) * u.z
    }

    private static func fbm(_ p: SIMD3<Float>, octaves: Int, _ seed: UInt32) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, q = p, total: Float = 0
        for o in 0..<octaves {
            sum += noise(q, seed &+ UInt32(o) &* 0x9E3779B9) * amplitude
            total += amplitude
            amplitude *= 0.5
            q = q * 2.03 + SIMD3(17.1, 9.3, 4.7)
        }
        return sum / total
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - The pictures

    /// A flame's colour by its heat (0...1): red at the edges, orange, yellow, a white core. The emitter's colour
    /// multiplies it.
    private static func flameColour(_ heat: Float) -> SIMD3<Float> {
        let red = SIMD3<Float>(0.7, 0.12, 0.03), orange = SIMD3<Float>(1, 0.55, 0.12), yellow = SIMD3<Float>(1, 0.95, 0.75)
        if heat > 0.66 { return yellow + (SIMD3<Float>(1, 1, 1) - yellow) * ((heat - 0.66) / 0.34) }
        if heat > 0.33 { return orange + (yellow - orange) * ((heat - 0.33) / 0.33) }
        return red + (orange - red) * (heat / 0.33)
    }

    /// Kind `kind`'s frame at `phase` (0...1 over the frames; `frame` its number) at `st` (-1...1, y up): linear RGB
    /// and alpha.
    private static func texel(_ kind: Kind, frame: Int, phase: Float, _ st: SIMD2<Float>) -> SIMD4<Float> {
        let r = length(st)
        switch kind {
        case .dot:
            return SIMD4(1, 1, 1, exp(-6 * r * r) * smoothstep(0.8, 0.55, r))
        case .spark:
            return SIMD4(1, 1, 1, min(exp(-40 * r * r) + 0.4 * exp(-7 * r * r), 1) * smoothstep(0.75, 0.5, r))
        case .smoke:
            // A puff that grows a little and churns: noise drifting through a soft ball, its edge eaten away.
            let grow = 0.82 + 0.15 * phase
            let n = fbm(SIMD3(st.x * 1.7, st.y * 1.7 - phase * 1.2, phase * 2.5), octaves: 4, 0x5EED)
            let ball = smoothstep(1, 0.15, r / grow)
            let density = ball * (0.35 + 1.3 * (n - 0.3))
            let a = min(max(density * 1.6, 0), 1) * smoothstep(0.97, 0.85, r)
            let shade = 0.8 + 0.2 * smoothstep(-1, 1, st.y) + 0.15 * (n - 0.5)
            return SIMD4(shade, shade, shade, a)
        case .flame:
            // A soft tongue of flame: wide and dense low down, thinning to a wisp, its sides shaken by noise rising
            // through it. Many of them overlapping make a fire.
            let h = st.y * 0.5 + 0.5   // 0 at the bottom
            let wobble = (fbm(SIMD3(st.x * 1.2, st.y * 1.2 - phase * 4, phase * 2), octaves: 3, 0xF1A) - 0.5) * 0.7 * h
            let width = 0.5 * pow(max(1 - h, 0), 0.5) + 0.14
            let across = (st.x - wobble) / width
            let envelope = smoothstep(-1, -0.25, st.y) * smoothstep(0.95, -0.1, st.y)
            let body = exp(-2.5 * across * across) * envelope
            let lick = fbm(SIMD3(st.x * 2.5, st.y * 2.5 - phase * 7, phase * 3), octaves: 4, 0xF1B)
            let heat = min(max(body * (0.3 + 1.2 * lick) * (1.2 - 0.5 * h), 0), 1)
            return SIMD4(flameColour(heat), smoothstep(0.03, 0.75, heat) * smoothstep(1, 0.93, max(abs(st.x), abs(st.y))))
        case .streak:
            let a = exp(-pow(st.x / 0.12, 2)) * smoothstep(1, 0.55, abs(st.y)) * smoothstep(1, 0.9, abs(st.x) * 4)
            return SIMD4(1, 1, 1, a)
        case .ring:
            let radius = 0.12 + 0.72 * phase, width = 0.05 + 0.05 * phase
            let a = exp(-pow((r - radius) / width, 2)) * (1 - 0.85 * phase) * smoothstep(0.98, 0.9, r)
            return SIMD4(1, 1, 1, a)
        case .rune:
            // A faint tablet, a circle and a few strokes between points of a 3 x 3 grid inside it, chosen by the frame's
            // hash: bold enough to read a few pixels across.
            var a = max(0.3 * smoothstep(0.92, 0.8, r), exp(-pow((r - 0.8) / 0.06, 2)))
            var h = ParticleMath.hash(UInt32(frame) &* 2654435761 &+ 0xBEEF)
            func point(_ k: UInt32) -> SIMD2<Float> { SIMD2(Float(k % 3) - 1, Float(k / 3) - 1) * 0.42 }
            for _ in 0..<5 {
                h = ParticleMath.hash(h)
                let p = point(h % 9), q = point((h >> 8) % 9)
                if p == q { continue }
                let d = q - p, t = min(max(dot(st - p, d) / dot(d, d), 0), 1)
                a = max(a, exp(-pow(length(st - (p + d * t)) / 0.09, 2)))
            }
            return SIMD4(1, 1, 1, a * smoothstep(0.97, 0.9, r))
        case .bubble:
            let rim = smoothstep(0.62, 0.9, r) * smoothstep(0.95, 0.88, r)
            let glint = exp(-length_squared((st - SIMD2(-0.32, 0.34)) / 0.14))
            let a = min(rim * 0.85 + 0.06 * smoothstep(0.92, 0.85, r) + glint * 0.9, 1)
            return SIMD4(1, 1, 1, a)
        }
    }

    /// Kind `kind`'s layer: RGBA8, `size` x `size`, its frames in their cells.
    static func generate(_ kind: Kind) -> [UInt8] {
        let n = size, c = cell
        var out = [UInt8](repeating: 0, count: n * n * 4)
        out.withUnsafeMutableBufferPointer { px in
            DispatchQueue.concurrentPerform(iterations: frames) { frame in
                let cx = frame % grid, cy = frame / grid, phase = Float(frame) / Float(frames - 1)
                for y in 0..<c {
                    for x in 0..<c {
                        let st = SIMD2((Float(x) + 0.5) / Float(c) * 2 - 1, 1 - (Float(y) + 0.5) / Float(c) * 2)
                        let v = texel(kind, frame: frame, phase: phase, st)
                        let i = ((cy * c + y) * n + cx * c + x) * 4
                        for k in 0..<4 { px[i + k] = UInt8(min(max(v[k], 0), 1) * 255 + 0.5) }
                    }
                }
            }
        }
        return out
    }

    static let folder: URL = {
        let folder = CacheFile.userFolder.appendingPathComponent("textures")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Every kind's layer, from the cache folder or made (and written there) first.
    static func layers(in folder: URL = ParticleTextures.folder) -> [[UInt8]] {
        let start = CFAbsoluteTimeGetCurrent()
        var made: [Kind] = []
        let layers = Kind.allCases.map { kind -> [UInt8] in
            let url = folder.appendingPathComponent("particles-\(kind)-\(cell)-g\(version).rgba")
            if let data = try? Data(contentsOf: url), data.count == size * size * 4 { return [UInt8](data) }
            let pixels = generate(kind)
            try? CacheFile.write(Data(pixels), to: url)
            made.append(kind)
            return pixels
        }
        if !made.isEmpty {
            print(String(format: "Particle flipbooks: %@ generated in %.2f s (%@)", made.map { "\($0)" }.joined(separator: ", "),
                         CFAbsoluteTimeGetCurrent() - start, folder.path))
        }
        return layers
    }

    /// The flipbooks as a texture array, a layer a kind (ParticleRender's layer: Kind.rawValue).
    static func atlas(device: MTLDevice) throws -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .rgba8Unorm
        d.width = size
        d.height = size
        d.arrayLength = Kind.allCases.count
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("the particle flipbooks") }
        texture.label = "particleAtlas"
        for (i, pixels) in layers().enumerated() {
            pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: i, withBytes: $0.baseAddress!,
                                bytesPerRow: size * 4, bytesPerImage: size * size * 4)
            }
        }
        return texture
    }
}
