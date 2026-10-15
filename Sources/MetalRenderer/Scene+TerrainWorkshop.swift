import Foundation
import simd

/// The terrain workshop (`SceneSettings.terrainWorkshop`): a terrain of its own to make with the Terrain Editor, from
/// half a kilometre to four across, on level ground or rolling hills (with a sea round their lowest third, unless
/// `sea` is off), under the valley's sky and day. Its document is
/// `TerrainWorkshopSettings.document` (TerrainDocuments), kept apart from every other scene's terrain.
extension Scene {
    func buildTerrainWorkshop() {
        let w = settings.terrainWorkshop
        let size = Float(w.size.metres), cell = w.size.cell, cells = Int(size / cell)
        let base: TerrainBase
        switch w.base {
        case .flat:
            base = FlatTerrainBase(grid: .square(size: size, cells: cells))
        case .hills:
            base = NoiseTerrainBase(size: size, cells: cells, seed: UInt64(max(w.seed, 0)), relief: 6 + size / 64, featureSize: size / 5,
                                    octaves: 7)
        }
        let entry = Scene.openTerrain(TerrainWorkshopSettings.terrainName(w), base: base)
        section("Terrain")
        let ground = addMaterial(albedo: [0.2, 0.24, 0.13])
        let grid = entry.field.grid
        // The hills' sea: at the height a third of the ground is under (on a grid of 64 x 64 of the base's samples).
        var water: [WaterBody] = []
        if w.sea && w.base == .hills, let hi = grid.hi {
            var heights: [Float] = []
            for j in stride(from: 0, through: hi.y, by: max(hi.y / 64, 1)) {
                for i in stride(from: 0, through: hi.x, by: max(hi.x / 64, 1)) { heights.append(base.height(i, j)) }
            }
            heights.sort()
            var sea = WaterBody(name: "Sea", kind: .sea, level: heights[heights.count * 3 / 10])
            sea.look = .preset(.ocean)
            water.append(sea)
        }
        addTerrain(name: entry.document.name, field: entry.field, tiles: grid.tiles!.map { ($0, 0) },
                   style: TerrainMeshStyle(uvOrigin: grid.origin, uvScale: 1), material: ground, generatedWater: water)
        // The realistic look: earth and dry grass under the rules' layers, sand along the sea.
        let seaLevel = water.first?.level, shore = entry.field.snapshot()
        let sandSeed = UInt32(truncatingIfNeeded: max(w.seed, 0))
        addGroundLook(GroundLook(
            layers: [.init(set: "ground", color: [0.2, 0.24, 0.13], contrast: 1), .init(set: "dry-grass", color: [0.33, 0.29, 0.14], contrast: 0.7),
                     .init(set: "sand", color: [0.52, 0.45, 0.3], metres: 4, contrast: 0.6), .init(set: "rock", color: [0.31, 0.28, 0.24], metres: 6, contrast: 1.4)],
            rock: 3, slope: [0.6, 0.78], lo: [-size / 2, -size / 2], size: [size, size], texels: 2048,
            key: "\(entry.document.name) \(w.seed) \(size) \(seaLevel ?? -1e9) \(shore.editsFingerprint) v1") { x, z in
            let p = SIMD2(x, z)
            let dry = GroundLook.smooth(0.1, 0.6, Terrain.noise(p / 37, seed: sandSeed &+ 5)) * 0.7
            var out: [Float] = [1 - dry, dry, 0, 0]
            if let seaLevel {
                let h = shore.height(x: Double(x), z: Double(z))
                let sand = 1 - GroundLook.smooth(seaLevel + 1, seaLevel + 3 + 1.5 * Terrain.noise(p / 17, seed: sandSeed &+ 6), h)
                out = out.map { $0 * (1 - sand) }
                out[2] += sand
            }
            return out
        })
        if w.bodies > 0 { dropBodies(w.bodies, on: entry.field.snapshot(), seed: UInt64(max(w.seed, 0))) }
        section("Sun")
        addDaySun()
        // From a corner, high over the ground's middle third.
        let snapshot = entry.field.snapshot(), corner = SIMD2<Float>(-0.32, 0.32) * size
        let h = snapshot.height(x: Double(corner.x), z: Double(corner.y))
        defaultCamera = Scene.camera([corner.x, h + 25 + size / 25, corner.y], yaw: .pi / 4, pitch: -0.18)
        focus = AABB(lo: [-size / 2, -50, -size / 2], hi: [size / 2, 200, size / 2])
    }
}

extension Scene {
    /// `count` rigid bodies (balls, boxes, rounded blocks) dropped from a few metres over the middle of the ground: they
    /// roll down its slopes and come to rest on it (the terrain's heightfield colliders: addTerrainColliders).
    func dropBodies(_ count: Int, on s: TerrainSnapshot, seed: UInt64) {
        section("Bodies")
        var rng = SplitMix64(seed: seed ^ 0xB0D1E5)
        let shapes = [addSDFShape(SDFShape(.sphere(radius: 0.6))), addSDFShape(SDFShape(.box(halfExtents: [0.5, 0.5, 0.5], rounding: 0.06))),
                      addSDFShape(SDFShape(.box(halfExtents: [0.9, 0.35, 0.6], rounding: 0.15)))]
        let colours: [SIMD3<Float>] = [[0.75, 0.2, 0.15], [0.9, 0.7, 0.2], [0.2, 0.45, 0.8], [0.85, 0.85, 0.82]]
        let materials = colours.map { addPBRMaterial(baseColor: $0, metallic: 0, roughness: 0.45) }
        let side = Int(Float(count).squareRoot().rounded(.up))
        for k in 0..<count {
            let x = (Float(k % side) - Float(side) / 2) * 3 + rng.range(-0.8, 0.8), z = (Float(k / side) - Float(side) / 2) * 3 + rng.range(-0.8, 0.8)
            let y = s.height(x: Double(x), z: Double(z)) + 3 + rng.range(0, 4)
            let turn = simd_quatf(angle: rng.range(0, .pi), axis: simd_normalize(SIMD3(rng.range(-1, 1), 1, rng.range(-1, 1))))
            addBody(sdf: shapes[k % shapes.count], materials[k % materials.count], translate([x, y, z]) * float4x4(turn), density: 600,
                    friction: 0.6, restitution: 0.15)
        }
    }
}

/// The terrain workshop's settings: how big its terrain is (and so how fine), what it starts from, and the document it
/// is edited into.
struct TerrainWorkshopSettings: Equatable, Codable {
    var size = Size.km1
    var base = Base.hills
    var seed = 1
    var document = "Workshop"
    /// Rigid bodies dropped onto it (0: none).
    var bodies = 0
    /// The hills with a sea round their lowest third (the flat ground never).
    var sea = true

    /// How far across (`metres`); each at most 1024 cells a side.
    enum Size: Int, Codable, CaseIterable {
        case m512, km1, km2, km4
        var metres: Int { 512 << rawValue }
        var cell: Float { Float(max(metres / 1024, 1)) }
        var title: String { metres < 1024 ? "\(metres) m" : "\(metres / 1024) km (\(Int(cell)) m cells)" }
    }
    enum Base: String, Codable, CaseIterable {
        case flat, hills
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// The terrain's document: its own name, its size and base and seed (another of any is another ground).
    static func terrainName(_ w: TerrainWorkshopSettings) -> String {
        "workshop-\(w.document)-\(w.size.metres)-\(w.base.rawValue)" + (w.base == .hills ? "-\(w.seed)" : "")
    }
}
