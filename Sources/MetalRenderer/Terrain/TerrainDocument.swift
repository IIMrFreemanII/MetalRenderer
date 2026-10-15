import Foundation
import simd

/// What a terrain's ground is made of where it isn't painted: a layer's own weight from the ground's height and slope
/// (and some noise, so its edge isn't a contour line). Off, the layer is only where it is painted.
struct TerrainRule: Codable, Equatable {
    var enabled = false
    /// Metres (the world's y): the layer is there from `heightMin` to `heightMax`, fading over `heightFade` either side.
    var heightMin: Float = -10_000
    var heightMax: Float = 10_000
    var heightFade: Float = 2
    /// Degrees from level: from `slopeMin` to `slopeMax`, fading over `slopeFade`.
    var slopeMin: Float = 0
    var slopeMax: Float = 90
    var slopeFade: Float = 5
    /// Noise over the edges: features per 100 m, and how much of the weight it moves (0...1).
    var noiseScale: Float = 4
    var noiseAmount: Float = 0
    /// Its weight where every condition holds (0...1).
    var strength: Float = 1

    /// The rule's weight at a place of height `y` and slope `degrees`, with the noise there `noise` (-1...1).
    func weight(height y: Float, slope degrees: Float, noise: Float) -> Float {
        guard enabled else { return 0 }
        func band(_ v: Float, _ lo: Float, _ hi: Float, _ fade: Float) -> Float {
            let f = max(fade, 1e-4)
            return min(max((v - lo) / f + 0.5, 0), 1) * min(max((hi - v) / f + 0.5, 0), 1)
        }
        let shift = noise * noiseAmount
        return strength * band(y + shift * heightFade * 2, heightMin, heightMax, heightFade)
            * band(degrees + shift * slopeFade * 2, slopeMin, slopeMax, slopeFade)
    }
}

/// One of a terrain's 16 ground layers: a material (a Material Designer graph by name, or plain values), how large
/// its texture is on the ground, and where it is without paint (`rule`).
struct TerrainLayer: Codable, Equatable {
    var name: String
    /// A Material Designer graph's name (MaterialCatalog); empty: the plain values below.
    var material = ""
    var color = SIMD3<Float>(0.3, 0.3, 0.3)
    var roughness: Float = 0.9
    /// The size of one repeat of its texture on the ground, metres.
    var tileMetres: Float = 4
    var rule = TerrainRule()
    /// Where the open world's ground already has a material of its own (World.groundMaterials), its index: what the
    /// layer is before anyone gives it another.
    var builtIn: Int? = nil
    /// The scanned material it wears in the realistic look (TextureSet's name): nil, the one its name says
    /// (`scanSet`), "" none.
    var textureSet: String? = nil

    /// The scan it wears in the realistic look: its own, or by its name.
    var scanSet: String? {
        if let textureSet { return textureSet.isEmpty ? nil : textureSet }
        switch name.lowercased() {
        case "grass", "meadow", "crop": return "grass"
        case "rock": return "rock"
        case "snow": return "snow"
        case "sand": return "sand"
        case "mud": return "mud"
        case "gravel": return "gravel"
        case "moss": return "moss"
        case "earth", "ploughed": return "earth"
        case "dry grass", "wheat": return "dry-grass"
        case "pebbles": return "pebbles"
        case "litter": return "forest-floor"
        case "ground": return "ground"
        default: return nil
        }
    }
}

/// A step of a terrain's generator: a shape of noise, or an operation on what the steps before made.
struct GeneratorNode: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case fbm, ridged, billow, cellular, warp, terrace, plateau, curve, smooth, constant
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fbm: return "Rolling hills (fBm)"
            case .ridged: return "Ridged mountains"
            case .billow: return "Billows"
            case .cellular: return "Cells (Voronoi)"
            case .warp: return "Domain warp"
            case .terrace: return "Terraces"
            case .plateau: return "Plateau / clamp"
            case .curve: return "Height curve"
            case .smooth: return "Smooth"
            case .constant: return "Constant"
            }
        }
        /// It makes heights of its own (combined with what was before by `blend`), rather than changing them.
        var isSource: Bool { [.fbm, .ridged, .billow, .cellular, .constant].contains(self) }
    }
    enum Blend: String, Codable, CaseIterable, Identifiable {
        case add, subtract, multiply, max, min, replace, lerp
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    var kind = Kind.fbm
    var blend = Blend.add
    var enabled = true
    /// Sources: metres of height, metres per feature, octaves, each octave's scale and weight, a seed.
    var amplitude: Float = 40
    var scale: Float = 400
    var octaves = 5
    var lacunarity: Float = 2
    var gain: Float = 0.5
    var seed = 1
    /// Warp: how far (metres) places are pushed by a noise of `scale`. Terraces: `steps` steps of `amplitude` metres
    /// with `sharpness` (0 smooth...1 hard). Plateau: heights above `level` pulled to it by `amount`. Curve:
    /// height = level + (h - level) x amount. Smooth: `amount` passes. Lerp: `amount` of the new.
    var amount: Float = 0.5
    var level: Float = 0
    var steps = 8
    var sharpness: Float = 0.7
}

/// A terrain's generator: its steps in order, and how what they make replaces the ground (or is added to it).
struct GeneratorStack: Codable, Equatable {
    var nodes: [GeneratorNode] = [
        GeneratorNode(kind: .fbm, blend: .add, amplitude: 60, scale: 900, octaves: 6, seed: 1),
        GeneratorNode(kind: .ridged, blend: .add, amplitude: 35, scale: 500, octaves: 5, seed: 2),
    ]
    /// The generated heights replace the ground (`true`), or are added to it.
    var replaces = true
}

/// Erosion: water that rains, runs downhill carrying earth and leaves it where it slows (hydraulic, the virtual pipes
/// model), and slopes steeper than they can stand crumbling down (thermal).
struct ErosionSettings: Codable, Equatable {
    var hydraulicIterations = 400
    var rain: Float = 0.01               // metres a step
    var evaporation: Float = 0.02        // share a step
    var capacity: Float = 0.8            // earth water carries, per speed and slope
    var dissolve: Float = 0.3            // share of the shortfall taken a step
    var deposit: Float = 0.3             // share of the excess left a step
    var thermalIterations = 50
    var talus: Float = 38                // degrees: steeper crumbles
    var thermalRate: Float = 0.25        // share of the excess moved a step
}

/// What a scatter rule places, and where: plants of the Plant editor's catalog (by species id), rocks made here,
/// any mesh of the scene, or buildings of the Building editor's styles.
struct ScatterRule: Codable, Equatable {
    enum Source: Codable, Equatable {
        case plant(species: String)
        case rock(roughness: Float)
        case mesh(name: String)
        case building(style: String)

        var title: String {
            switch self {
            case .plant(let s): return "Plant: \(s)"
            case .rock: return "Rocks"
            case .mesh(let n): return "Mesh: \(n)"
            case .building(let s): return "Building: \(s)"
            }
        }
    }
    var name = "Scatter"
    var enabled = true
    var source = Source.rock(roughness: 0.5)
    /// Things per 100 m square, and the least distance between two (metres).
    var density: Float = 20
    var spacing: Float = 2
    /// Where: height (metres) and slope (degrees) ranges, a layer's weight at least `layerThreshold` (`layer` nil:
    /// anywhere), and patches of noise (`patchScale` metres, `patchCover` share of the ground).
    var heightMin: Float = -10_000
    var heightMax: Float = 10_000
    var slopeMin: Float = 0
    var slopeMax: Float = 35
    var layer: Int? = nil
    var layerThreshold: Float = 0.5
    var patchScale: Float = 60
    var patchCover: Float = 1
    /// How: standing up or along the ground's normal, turned at random, sized between `sizeMin` and `sizeMax`, sunk.
    var alignToGround: Float = 0
    var sizeMin: Float = 0.8
    var sizeMax: Float = 1.2
    var sink: Float = 0.1
    var seed = 1
    /// Kept out of water and off the roads.
    var avoidWater = true
}

/// Water on a terrain: a sea at a level (everywhere below it), a lake that fills the basin around a place up to a
/// level, or a river along a line, its bed carved into the ground.
struct WaterBody: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case sea, lake, river
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    var name = "Water"
    var kind = Kind.lake
    var level: Float = 0
    /// A lake's: where its basin is (the world's x, z).
    var seed = SIMD2<Double>.zero
    /// A river's: its line (the world's x, z), from its source down, how wide and deep its bed is (metres).
    var points: [SIMD2<Double>] = []
    var width: Float = 8
    var depth: Float = 1.5
    /// A Material Designer graph's name floating on it (duckweed, a scum), cut out by its opacity; empty for none.
    var material = ""
    /// The colour rays that meet it from elsewhere see (GI, reflections off other things).
    var color = SIMD3<Float>(0.05, 0.12, 0.1)
    /// How the water looks (WaterLook); nil: its kind's (an ocean, a lake, a river).
    var look: WaterLook? = nil
    /// A river's bed at its points as it was carved (TerrainWater.bed of the ground before), and the points it was
    /// carved along: its surface keeps to it after the carving lowered the ground (nil, or other points: worked out
    /// from the ground as it is).
    var bed: [Float]? = nil
    var bedPoints: [SIMD2<Double>]? = nil
}

/// A terrain's document: everything about it but the heights and paint (TerrainField's tiles, saved beside it):
/// its layers, its generator and erosion, its scatter rules and its water.
struct TerrainDocument: Codable, Equatable {
    var name: String
    var format = 1
    var layers: [TerrainLayer]
    var generator = GeneratorStack()
    var erosion = ErosionSettings()
    var scatter: [ScatterRule] = []
    var water: [WaterBody] = []

    init(name: String, layers: [TerrainLayer] = TerrainDocument.defaultLayers) {
        self.name = name
        self.layers = layers
    }

    /// Sixteen layers: layer 0 is the ground's own material (the scene's: what it is wherever nothing else shows),
    /// then grass, rock on steep ground and snow up high by their rules, then layers for the brushes.
    static let defaultLayers: [TerrainLayer] = {
        var out: [TerrainLayer] = [
            TerrainLayer(name: "Ground", color: [0.16, 0.12, 0.08], roughness: 0.95, tileMetres: 4),
            TerrainLayer(name: "Grass", color: [0.11, 0.2, 0.06], roughness: 0.9, tileMetres: 3,
                         rule: TerrainRule(enabled: true, slopeMax: 28, slopeFade: 6, noiseAmount: 0.4)),
            TerrainLayer(name: "Rock", color: [0.31, 0.28, 0.24], roughness: 0.8, tileMetres: 6,
                         rule: TerrainRule(enabled: true, slopeMin: 36, slopeFade: 8, noiseAmount: 0.3)),
            TerrainLayer(name: "Snow", color: [0.85, 0.87, 0.9], roughness: 0.6, tileMetres: 5,
                         rule: TerrainRule(enabled: true, heightMin: 120, heightFade: 12, slopeMax: 40, noiseAmount: 0.5)),
        ] + TerrainDocument.brushLayers
        while out.count < TerrainTile.layers { out.append(TerrainLayer(name: "Layer \(out.count)")) }
        return Array(out.prefix(TerrainTile.layers))
    }()

    /// Layers for the brushes alone (no rules): sand, mud, gravel, moss, earth, dry grass, pebbles.
    static let brushLayers: [TerrainLayer] = [
        TerrainLayer(name: "Sand", color: [0.52, 0.45, 0.3], roughness: 0.95, tileMetres: 3),
        TerrainLayer(name: "Mud", color: [0.12, 0.09, 0.06], roughness: 0.6, tileMetres: 3),
        TerrainLayer(name: "Gravel", color: [0.35, 0.33, 0.3], roughness: 0.9, tileMetres: 2),
        TerrainLayer(name: "Moss", color: [0.09, 0.135, 0.05], roughness: 0.95, tileMetres: 3),
        TerrainLayer(name: "Earth", color: [0.16, 0.12, 0.08], roughness: 0.95, tileMetres: 4),
        TerrainLayer(name: "Dry grass", color: [0.33, 0.29, 0.14], roughness: 0.95, tileMetres: 3),
        TerrainLayer(name: "Pebbles", color: [0.42, 0.4, 0.37], roughness: 0.85, tileMetres: 2),
    ]

    /// A scene's own terrain (the Forest's, Mireland's, the city's, the valley's): the same layers, no rules, so that
    /// the ground is the scene's own until it is painted.
    static func sceneLayers() -> [TerrainLayer] {
        defaultLayers.enumerated().map { k, l in
            var l = l
            l.rule.enabled = false
            if k == 0 { l.name = "Scene's ground" }
            return l
        }
    }

    /// The open world's: its own ground (each place's, by the world: layer 0), then its seven grounds to paint
    /// (World.groundMaterials), then the brushes' layers.
    static func worldLayers() -> [TerrainLayer] {
        let names = ["Litter", "Moss", "Meadow", "Rock", "Wheat", "Crop", "Ploughed", "Sand"]
        var out = [TerrainLayer(name: "World's ground", tileMetres: World.groundTile)]
        out += names.enumerated().map { k, name in
            let a = World.groundMaterials[k].albedo
            return TerrainLayer(name: name, color: SIMD3(a.x, a.y, a.z) * FoliageTextures.mean, roughness: 1, tileMetres: World.groundTile,
                                builtIn: k)
        }
        out += brushLayers.filter { !names.contains($0.name) }
        while out.count < TerrainTile.layers { out.append(TerrainLayer(name: "Layer \(out.count)")) }
        return Array(out.prefix(TerrainTile.layers))
    }

    enum CodingKeys: String, CodingKey { case name, format, layers, generator, erosion, scatter, water }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        var l = try c.decodeIfPresent([TerrainLayer].self, forKey: .layers) ?? TerrainDocument.defaultLayers
        while l.count < TerrainTile.layers { l.append(TerrainLayer(name: "Layer \(l.count + 1)")) }
        layers = Array(l.prefix(TerrainTile.layers))
        generator = try c.decodeIfPresent(GeneratorStack.self, forKey: .generator) ?? GeneratorStack()
        erosion = try c.decodeIfPresent(ErosionSettings.self, forKey: .erosion) ?? ErosionSettings()
        scatter = try c.decodeIfPresent([ScatterRule].self, forKey: .scatter) ?? []
        water = try c.decodeIfPresent([WaterBody].self, forKey: .water) ?? []
    }

    /// A file name for it.
    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let s = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return s.isEmpty ? "terrain" : s
    }
}
