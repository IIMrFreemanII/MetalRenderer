import Buildings
import EngineCore
import Foundation
import Physics
import Plants
import QuartzCore
import simd

/// A scene's realistic ground (SceneSettings.realism): its terrain's layer 0, the ground wherever nothing is painted,
/// made of up to eight scanned layers (TextureSet) that a map the scene draws mixes (a weight per layer a texel), rock
/// where the ground is steep, each layer's height deciding where it shows through the others (Shaders/Surface.metal
/// `terrainRealistic`, UE's height lerp). What it would be in the Terrain Editor's terms: an automatic material.
package struct GroundLook {
    package struct Layer {
        package var set: String
        /// Without the scan: its plain colour over the generated detail texture.
        package var color: SIMD3<Float>
        /// The scan's albedo times this.
        package var tint: SIMD3<Float> = .one
        /// One repeat, metres (nil: the scan's own size).
        package var metres: Float? = nil
        /// How strongly its height wins over its neighbours' where they mix (0: a plain blend).
        package var contrast: Float = 1
        package var roughness: Float = 1
        /// How far its height raises and sinks the near ground with realism high, metres (nil: its scan's own:
        /// GroundRelief.relief(of:)).
        package var relief: Float? = nil

        /// (As the memberwise initializer, for the modules above this one.)
        package init(set: String, color: SIMD3<Float>, tint: SIMD3<Float> = .one, metres: Float? = nil, contrast: Float = 1, roughness: Float = 1, relief: Float? = nil) {
            self.set = set
            self.color = color
            self.tint = tint
            self.metres = metres
            self.contrast = contrast
            self.roughness = roughness
            self.relief = relief
        }
    }
    package var layers: [Layer]
    /// The layer steep ground is (nil: none), and the normals' y between which it comes in (all of it under `slope.x`).
    package var rock: Int? = nil
    package var slope = SIMD2<Float>(0.62, 0.82)
    /// The map's rectangle (scene x, z) and its texels a side.
    package var lo: SIMD2<Float>
    package var size: SIMD2<Float>
    package var texels: Int
    /// What the map's pixels depend on (the caches' key: change it with anything `weights` reads).
    package var key: String
    /// Each layer's weight at a place (scene x, z): `layers.count` of them, normalised where they're drawn.
    package var weights: (Float, Float) -> [Float]

    package static let maxLayers = 8

    private static var drawnMaps: [(key: String, maps: (FoliageTextures.Image, FoliageTextures.Image))] = []
    private static let drawnLock = NSLock()
    package static func recent(_ key: String) -> (FoliageTextures.Image, FoliageTextures.Image)? {
        drawnLock.lock()
        defer { drawnLock.unlock() }
        return drawnMaps.first { $0.key == key }?.maps
    }
    package static func remember(_ key: String, _ maps: (FoliageTextures.Image, FoliageTextures.Image)) {
        drawnLock.lock()
        defer { drawnLock.unlock() }
        drawnMaps.removeAll { $0.key == key }
        drawnMaps.insert((key, maps), at: 0)
        if drawnMaps.count > 4 { drawnMaps.removeLast() }
    }

    /// Rolling grassland: grass with patches of dry grass and bare earth, mud round water (`water`'s, within 3 m) and
    /// pebbles under it, rock where it is steep. `bare` adds earth (0...1) where a scene wants it (a path, a yard).
    package static func meadow(lo: SIMD2<Float>, size: SIMD2<Float>, texels: Int, key: String, seed: UInt32, water: WaterField? = nil,
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
    package func draw() -> (FoliageTextures.Image, FoliageTextures.Image) {
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
    package static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(layers: [Layer], rock: Int? = nil, slope: SIMD2<Float> = SIMD2<Float>(0.62, 0.82), lo: SIMD2<Float>, size: SIMD2<Float>, texels: Int, key: String, weights: @escaping (Float, Float) -> [Float]) {
        self.layers = layers
        self.rock = rock
        self.slope = slope
        self.lo = lo
        self.size = size
        self.texels = texels
        self.key = key
        self.weights = weights
    }
}

/// What the shader reads of a scene's realistic ground, after its layer table (SceneTerrain.table).
package struct GroundRows {
    package var materials: [Int] = []
    package var metres: [Float] = []
    package var contrast: [Float] = []
    package var mapA: UInt32 = .max, mapB: UInt32 = .max
    package var rock = -1
    package var slope = SIMD2<Float>(0.62, 0.82)
    package var lo = SIMD2<Float>.zero, size = SIMD2<Float>(1, 1)

    /// (As the memberwise initializer, for the modules above this one.)
    package init(materials: [Int] = [], metres: [Float] = [], contrast: [Float] = [], mapA: UInt32 = .max, mapB: UInt32 = .max, rock: Int = -1, slope: SIMD2<Float> = SIMD2<Float>(0.62, 0.82), lo: SIMD2<Float> = SIMD2<Float>.zero, size: SIMD2<Float> = SIMD2<Float>(1, 1)) {
        self.materials = materials
        self.metres = metres
        self.contrast = contrast
        self.mapA = mapA
        self.mapB = mapB
        self.rock = rock
        self.slope = slope
        self.lo = lo
        self.size = size
    }
}
