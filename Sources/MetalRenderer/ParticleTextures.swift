import Foundation
import Metal
import simd

/// The particles' flipbooks (ParticleTrace.metal's `particleTexel`): one layer of a texture array per kind, `grid` x
/// `grid` frames of `cell` pixels, frame k at column k % grid, row k / grid. Generated at load, no assets to ship:
/// the layers are made once and kept in the user's cache folder as raw RGBA (a new `version` makes new files).
/// Every frame's picture fades to nothing a few pixels inside its cell, so the linear filter never reaches the next.
///
/// After the kinds' layers, three of what lights and moves them (`Aux`), frame for frame in the same cells: smoke's
/// six-way light maps (how much of a light from each of six directions its puff passes on to the eye: right, left,
/// top, bottom in one layer; front, back in the next) and the motion of smoke's and flame's pictures from a frame to
/// the next (the generator's own drift), which the frame blending follows (ParticleTrace.metal).
enum ParticleTextures {
    /// The layers after the kinds'.
    enum Aux: Int, CaseIterable {
        case smokeLight     // rgba: a light from the right, the left, the top, the bottom
        case smokeBack      // r: from the front (behind the eye), g: from behind the puff; ba: smoke's motion
        case flameMotion    // ba: flame's motion
        var layer: Int { Kind.allCases.count + rawValue }
    }
    static var layerCount: Int { Kind.allCases.count + Aux.allCases.count }
    /// The kinds with six-way maps, and with motion (MSL PARTICLE_MOTION_LAYER).
    static func hasSixWay(_ k: Kind) -> Bool { k == .smoke }
    static func motionLayer(_ k: Kind) -> Int? {
        switch k {
        case .smoke: return Aux.smokeBack.layer
        case .flame: return Aux.flameMotion.layer
        default: return nil
        }
    }
    /// The largest motion a frame the motion channels hold (cell units, -1...1 across it): 0.5 is ± this.
    static let motionRange: Float = 0.1
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
    static let version = 7

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
            let (a, n) = smokeDensity(phase: phase, st)
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

    /// A smoke puff's opacity at `st` of the frame at `phase`, and the noise it churns with: a puff that grows a little
    /// and churns, noise drifting up through a soft ball, its edge eaten away.
    private static func smokeDensity(phase: Float, _ st: SIMD2<Float>) -> (Float, Float) {
        let r = length(st), grow = 0.82 + 0.15 * phase
        let n = fbm(SIMD3(st.x * 1.7, st.y * 1.7 - phase * 1.2, phase * 2.5), octaves: 4, 0x5EED)
        let ball = smoothstep(1, 0.15, r / grow)
        let density = ball * (0.35 + 1.3 * (n - 0.3))
        return (min(max(density * 1.6, 0), 1) * smoothstep(0.97, 0.85, r), n)
    }

    /// How the pictures move from a frame to the next (cell units, -1...1 across, a frame), from the generator's own
    /// drift: smoke's noise rises 1.2 / 1.7 a unit of phase and its ball grows by 0.15 / grow; flame's licks rise 7 / 2.5.
    private static func motion(_ kind: Kind, phase: Float, _ st: SIMD2<Float>) -> SIMD2<Float> {
        let perFrame = 1 / Float(frames - 1)
        switch kind {
        case .smoke: return (SIMD2(0, 1.2 / 1.7) + st * (0.15 / (0.82 + 0.15 * phase))) * perFrame
        case .flame: return SIMD2(0, 7 / 2.5) * perFrame
        default: return .zero
        }
    }

    /// Writes every frame's cell of a layer: `texel(frame, phase, st)` is its RGBA there (0...1).
    private static func layer(_ texel: @escaping (Int, Float, SIMD2<Float>) -> SIMD4<Float>) -> [UInt8] {
        let n = size, c = cell
        var out = [UInt8](repeating: 0, count: n * n * 4)
        out.withUnsafeMutableBufferPointer { px in
            DispatchQueue.concurrentPerform(iterations: frames) { frame in
                let cx = frame % grid, cy = frame / grid, phase = Float(frame) / Float(frames - 1)
                for y in 0..<c {
                    for x in 0..<c {
                        let st = SIMD2((Float(x) + 0.5) / Float(c) * 2 - 1, 1 - (Float(y) + 0.5) / Float(c) * 2)
                        let v = texel(frame, phase, st)
                        let i = ((cy * c + y) * n + cx * c + x) * 4
                        for k in 0..<4 { px[i + k] = UInt8(min(max(v[k], 0), 1) * 255 + 0.5) }
                    }
                }
            }
        }
        return out
    }

    /// Kind `kind`'s layer: RGBA8, `size` x `size`, its frames in their cells.
    static func generate(_ kind: Kind) -> [UInt8] {
        layer { frame, phase, st in texel(kind, frame: frame, phase: phase, st) }
    }

    /// Smoke's six-way maps over the frame at `phase`, a texel a cell's pixel (row by row, top first): how much of a
    /// light from the right, the left, the top, the bottom, the front and behind reaches the eye there. From a side,
    /// what the puff's density lets through from that edge to the texel (its column of it, Beer-Lambert); from the
    /// front, the lit face, dimmed a little where it is dense; from behind, what passes through its whole depth. A
    /// thin wisp passes on nearly all of each (1): the isotropic answer. Softer than single scattering would have it
    /// (`k`): light that scatters again inside the puff gets further (the path tracer's smoke, against which it was set).
    static func smokeSixWay(phase: Float) -> (side: [SIMD4<Float>], frontBack: [SIMD2<Float>]) {
        let c = cell, k: Float = 1.2, ds = 2 / Float(c)
        var d = [Float](repeating: 0, count: c * c)
        for y in 0..<c {
            for x in 0..<c {
                d[y * c + x] = smokeDensity(phase: phase, SIMD2((Float(x) + 0.5) / Float(c) * 2 - 1, 1 - (Float(y) + 0.5) / Float(c) * 2)).0
            }
        }
        var side = [SIMD4<Float>](repeating: .zero, count: c * c), frontBack = [SIMD2<Float>](repeating: .zero, count: c * c)
        for y in 0..<c {
            var sum: Float = 0
            for x in stride(from: c - 1, through: 0, by: -1) { side[y * c + x].x = exp(-k * sum); sum += d[y * c + x] * ds }   // from the right
            sum = 0
            for x in 0..<c { side[y * c + x].y = exp(-k * sum); sum += d[y * c + x] * ds }                                     // the left
        }
        for x in 0..<c {
            var sum: Float = 0
            for y in 0..<c { side[y * c + x].z = exp(-k * sum); sum += d[y * c + x] * ds }                                     // the top (row 0)
            sum = 0
            for y in stride(from: c - 1, through: 0, by: -1) { side[y * c + x].w = exp(-k * sum); sum += d[y * c + x] * ds }   // the bottom
        }
        for i in 0..<c * c { frontBack[i] = SIMD2(1 - 0.15 * d[i], exp(-1.0 * d[i])) }
        return (side, frontBack)
    }

    /// Aux layer `aux` (ParticleTextures.Aux).
    static func generate(_ aux: Aux) -> [UInt8] {
        func encode(_ m: SIMD2<Float>) -> SIMD2<Float> { m / (2 * motionRange) + 0.5 }
        switch aux {
        case .smokeLight, .smokeBack:
            let n = size, c = cell
            var out = [UInt8](repeating: 0, count: n * n * 4)
            out.withUnsafeMutableBufferPointer { px in
                DispatchQueue.concurrentPerform(iterations: frames) { frame in
                    let cx = frame % grid, cy = frame / grid, phase = Float(frame) / Float(frames - 1)
                    let maps = smokeSixWay(phase: phase)
                    for y in 0..<c {
                        for x in 0..<c {
                            let st = SIMD2((Float(x) + 0.5) / Float(c) * 2 - 1, 1 - (Float(y) + 0.5) / Float(c) * 2)
                            let m = encode(motion(.smoke, phase: phase, st)), fb = maps.frontBack[y * c + x]
                            let v = aux == .smokeLight ? maps.side[y * c + x] : SIMD4(fb.x, fb.y, m.x, m.y)
                            let i = ((cy * c + y) * n + cx * c + x) * 4
                            for k in 0..<4 { px[i + k] = UInt8(min(max(v[k], 0), 1) * 255 + 0.5) }
                        }
                    }
                }
            }
            return out
        case .flameMotion:
            return layer { _, phase, st in
                let m = encode(motion(.flame, phase: phase, st))
                return SIMD4(0, 0, m.x, m.y)
            }
        }
    }

    static let folder: URL = {
        let folder = CacheFile.userFolder.appendingPathComponent("textures")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Every layer (the kinds', then the aux ones), from the cache folder or made (and written there) first.
    static func layers(in folder: URL = ParticleTextures.folder) -> [[UInt8]] {
        let start = CFAbsoluteTimeGetCurrent()
        var made: [String] = []
        func load(_ name: String, _ make: () -> [UInt8]) -> [UInt8] {
            let url = folder.appendingPathComponent("particles-\(name)-\(cell)-g\(version).rgba")
            if let data = try? Data(contentsOf: url), data.count == size * size * 4 { return [UInt8](data) }
            let pixels = make()
            try? CacheFile.write(Data(pixels), to: url)
            made.append(name)
            return pixels
        }
        let layers = Kind.allCases.map { kind in load("\(kind)") { generate(kind) } }
            + Aux.allCases.map { aux in load("\(aux)") { generate(aux) } }
        if !made.isEmpty {
            print(String(format: "Particle flipbooks: %@ generated in %.2f s (%@)", made.joined(separator: ", "),
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
        d.arrayLength = layerCount
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
