import Foundation
import simd

/// A scene's realistic ground (SceneSettings.realism): its terrain's layer 0, the ground wherever nothing is painted,
/// made of up to eight scanned layers (TextureSet) that a map the scene draws mixes (a weight per layer a texel), rock
/// where the ground is steep, each layer's height deciding where it shows through the others (Shaders/Surface.metal
/// `terrainRealistic`, UE's height lerp). What it would be in the Terrain Editor's terms: an automatic material.
struct GroundLook {
    struct Layer {
        var set: String
        /// Without the scan: its plain colour over the generated detail texture.
        var color: SIMD3<Float>
        /// The scan's albedo times this.
        var tint: SIMD3<Float> = .one
        /// One repeat, metres (nil: the scan's own size).
        var metres: Float? = nil
        /// How strongly its height wins over its neighbours' where they mix (0: a plain blend).
        var contrast: Float = 1
        var roughness: Float = 1
    }
    var layers: [Layer]
    /// The layer steep ground is (nil: none), and the normals' y between which it comes in (all of it under `slope.x`).
    var rock: Int? = nil
    var slope = SIMD2<Float>(0.62, 0.82)
    /// The map's rectangle (scene x, z) and its texels a side.
    var lo: SIMD2<Float>
    var size: SIMD2<Float>
    var texels: Int
    /// What the map's pixels depend on (the caches' key: change it with anything `weights` reads).
    var key: String
    /// Each layer's weight at a place (scene x, z): `layers.count` of them, normalised where they're drawn.
    var weights: (Float, Float) -> [Float]

    static let maxLayers = 8

    /// Rolling grassland: grass with patches of dry grass and bare earth, mud round water (`water`'s, within 3 m) and
    /// pebbles under it, rock where it is steep. `bare` adds earth (0...1) where a scene wants it (a path, a yard).
    static func meadow(lo: SIMD2<Float>, size: SIMD2<Float>, texels: Int, key: String, seed: UInt32, water: WaterField? = nil,
                       bare: @escaping (Float, Float) -> Float = { _, _ in 0 }) -> GroundLook {
        GroundLook(
            layers: [.init(set: "grass", color: [0.2, 0.3, 0.1], contrast: 0.6),
                     .init(set: "dry-grass", color: [0.33, 0.29, 0.14], contrast: 0.7),
                     .init(set: "ground", color: [0.27, 0.215, 0.145], tint: [0.9, 0.86, 0.8], contrast: 0.9),
                     .init(set: "mud", color: [0.12, 0.09, 0.06], contrast: 0.7),
                     .init(set: "rock", color: [0.24, 0.23, 0.21], metres: 5, contrast: 1.4),
                     .init(set: "pebbles", color: [0.42, 0.4, 0.37], metres: 1.4, contrast: 0.8)],
            rock: 4, slope: [0.48, 0.66], lo: lo, size: size, texels: texels, key: "\(key) meadow v2") { x, z in
            let p = SIMD2(x, z)
            let dry = smooth(0.1, 0.7, Terrain.noise(p / 31, seed: seed &+ 1) + 0.35 * Terrain.noise(p / 4, seed: seed &+ 2)) * 0.55
            let earth = max(smooth(0.45, 0.8, Terrain.noise(p / 6, seed: seed &+ 3) + 0.3 * Terrain.noise(p / 1.7, seed: seed &+ 5)) * 0.4,
                            min(max(bare(x, z), 0), 1))
            var w: [Float] = [1 - dry, dry, 0, 0, 0, 0]
            func over(_ k: Int, _ amount: Float) {
                guard amount > 0 else { return }
                for i in w.indices { w[i] *= 1 - amount }
                w[k] += amount
            }
            over(2, earth)
            if let water {
                let bed = water.wet(Double(x), Double(z), margin: 0)
                let bank: Float = (water.wet(Double(x), Double(z), margin: 1.5) ? 0.6 : 0) + (water.wet(Double(x), Double(z), margin: 3.5) ? 0.4 : 0)
                let stones = smooth(0, 0.5, Terrain.noise(p / 3, seed: seed &+ 4))
                over(3, bed ? 1 : bank)
                if bed { over(5, stones * 0.7) }
            }
            return w
        }
    }

    /// The map's pixels, both textures' (layers 0...3 in the first's RGBA, 4...7 in the second's), drawn on every core.
    func draw() -> (FoliageTextures.Image, FoliageTextures.Image) {
        let n = texels, count = min(layers.count, Self.maxLayers)
        var a = [UInt8](repeating: 0, count: n * n * 4), b = [UInt8](repeating: 0, count: n * n * 4)
        a.withUnsafeMutableBufferPointer { pa in
            b.withUnsafeMutableBufferPointer { pb in
                DispatchQueue.concurrentPerform(iterations: n) { j in
                    for i in 0..<n {
                        let x = lo.x + (Float(i) + 0.5) / Float(n) * size.x, z = lo.y + (Float(j) + 0.5) / Float(n) * size.y
                        var w = weights(x, z)
                        if w.count < count { w += [Float](repeating: 0, count: count - w.count) }
                        let total = max(w.prefix(count).reduce(0) { $0 + max($1, 0) }, 1e-6)
                        for k in 0..<count {
                            let v = UInt8(min(max(w[k] / total, 0), 1) * 255 + 0.5)
                            if k < 4 { pa[(j * n + i) * 4 + k] = v } else { pb[(j * n + i) * 4 + k - 4] = v }
                        }
                    }
                }
            }
        }
        return (FoliageTextures.Image(width: n, height: n, pixels: a), FoliageTextures.Image(width: n, height: n, pixels: b))
    }

    /// A smooth step from 0 at `a` to 1 at `b`.
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// What the shader reads of a scene's realistic ground, after its layer table (SceneTerrain.table).
struct GroundRows {
    var materials: [Int] = []
    var metres: [Float] = []
    var contrast: [Float] = []
    var mapA: UInt32 = .max, mapB: UInt32 = .max
    var rock = -1
    var slope = SIMD2<Float>(0.62, 0.82)
    var lo = SIMD2<Float>.zero, size = SIMD2<Float>(1, 1)
}

extension Scene {
    /// The realistic ground's tiling noise (brightness, hue, roughness, break-up: RGBA), shared by every terrain.
    func terrainMacroTexture() -> UInt32 {
        addGeneratedTexture(name: "terrain-macro", width: 512, height: 512, key: "v1", srgb: false) {
            var pixels = [UInt8](repeating: 0, count: 512 * 512 * 4)
            for j in 0..<512 {
                for i in 0..<512 {
                    let u = Float(i) / 512, v = Float(j) / 512
                    for c in 0..<4 {
                        let s = UInt32(71 + 13 * c)
                        let n = 0.6 * FoliageTextures.noise(u * 4, v * 4, 4, 4, s) + 0.3 * FoliageTextures.noise(u * 11, v * 11, 11, 11, s + 1)
                            + 0.15 * FoliageTextures.noise(u * 29, v * 29, 29, 29, s + 2)
                        pixels[(j * 512 + i) * 4 + c] = UInt8(min(max(0.5 + 0.5 * n, 0), 1) * 255)
                    }
                }
            }
            return FoliageTextures.Image(width: 512, height: 512, pixels: pixels)
        }
    }

    /// A material for a realistic layer: its scan, or without it its colour over the generated detail.
    func groundLayerMaterial(set: String, color: SIMD3<Float>, tint: SIMD3<Float> = .one, roughness: Float = 1, detail: UInt32) -> Int {
        if let m = addScanMaterial(set, tint: tint, roughness: roughness) { return m }
        var m = GPUMaterial(albedo: SIMD4(color / FoliageTextures.mean, 0), emission: SIMD4(.zero, 0.95 * roughness))
        m.textures.x = detail
        return addMaterial(m)
    }

    /// The scene's terrain's ground as `look` says (with the realistic look on; after `addTerrain`, before
    /// `finishTerrainLayers`).
    func addGroundLook(_ look: GroundLook) {
        guard settings.realism != .off, let t = terrain else { return }
        let detail = t.detail != .max ? t.detail : terrainDetailTexture()
        var rows = GroundRows()
        for l in look.layers.prefix(GroundLook.maxLayers) {
            rows.materials.append(groundLayerMaterial(set: l.set, color: l.color, tint: l.tint, roughness: l.roughness, detail: detail))
            rows.metres.append(l.metres ?? TextureSet.find(l.set)?.metres ?? 3)
            rows.contrast.append(l.contrast)
        }
        final class Drawn { var maps: (FoliageTextures.Image, FoliageTextures.Image)? }
        let drawn = Drawn(), n = look.texels, key = look.key
        func maps() -> (FoliageTextures.Image, FoliageTextures.Image) {
            if let m = drawn.maps { return m }
            let m = look.draw()
            drawn.maps = m
            return m
        }
        rows.mapA = addGeneratedTexture(name: "ground-map-a", width: n, height: n, key: key, srgb: false) { maps().0 }
        if look.layers.count > 4 {
            rows.mapB = addGeneratedTexture(name: "ground-map-b", width: n, height: n, key: key, srgb: false) { maps().1 }
        }
        rows.rock = look.rock ?? -1
        rows.slope = look.slope
        rows.lo = look.lo
        rows.size = look.size
        t.ground = rows
    }

    /// The realistic look's grass on the scene's terrain round `center` (Flora.meadow), where `density` says, with its own
    /// flora (the built-in grass) unless the scene's has grass. How many patches.
    @discardableResult
    func addMeadowGrass(center: SIMD2<Float>, reach: Float, seed: UInt64, flora given: Flora? = nil, density: (Float, Float) -> Float) -> Int {
        guard settings.realism != .off, let t = terrain else { return 0 }
        let flora = given ?? Flora(self, seed: seed, catalog: .builtIn, species: [.grass])
        func ground(_ x: Float, _ z: Float) -> (Float, SIMD3<Float>) {
            let h = t.height(x, z), dx = t.height(x + 0.5, z) - t.height(x - 0.5, z), dz = t.height(x, z + 0.5) - t.height(x, z - 0.5)
            return (h, simd_normalize(SIMD3(-dx, 1, -dz)))
        }
        return flora.meadow(center: center, reach: reach, seed: seed, ground: ground, density: density)
    }

    /// The generated detail texture the plain layers' colours are multiplied by.
    func terrainDetailTexture() -> UInt32 {
        addGeneratedTexture(name: "terrain-detail", width: 512, height: 512, key: "v\(FoliageTextures.version)") {
            FoliageTextures.image(512, 512, normalized: true) { u, v in
                let clumps = FoliageTextures.noise(u * 6, v * 6, 6, 6, 41) + 0.6 * FoliageTextures.noise(u * 17, v * 17, 17, 17, 42)
                let specks = FoliageTextures.noise(u * 60, v * 60, 60, 60, 43)
                return SIMD3(repeating: max(0.75 + 0.3 * clumps + 0.22 * specks, 0.1))
            }
        }
    }
}
