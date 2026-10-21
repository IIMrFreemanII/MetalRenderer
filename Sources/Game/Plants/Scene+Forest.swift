import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd
import MetalRenderer

extension Scene {
    // MARK: - Forest

    /// The Forest's water: a stream from the hills on the north side down to a pond in a hollow beyond the clearing,
    /// on the side of the trail the seed picks (it never crosses it), shaped into `hills`. The pond fills to a little
    /// under the lowest ground round its rim, so it stays in its bowl.
    static func forestWater(_ hills: TerrainBase, seed: UInt64) -> (TerrainShapes, [WaterBody]) {
        var rng = SplitMix64(seed: seed &* 0x9E37_79B9_7F4A_7C15 ^ 0x57EA)
        let side: Float = rng.next() < 0.5 ? -1 : 1
        let pondCenter = SIMD2<Float>(side * rng.range(70, 95), rng.range(-10, 25)), radii = SIMD2(rng.range(13, 18), rng.range(9, 13))
        let source = SIMD2<Double>(Double(side * rng.range(45, 110)), -148)
        // The stream ends at the pond's near rim.
        let towards = simd_normalize(SIMD2<Double>(pondCenter) - source)
        let mouth = SIMD2<Double>(pondCenter) - towards * Double(min(radii.x, radii.y) * 0.8)
        let stream = SceneWaterMaker.river(name: "Stream", base: hills, from: source, to: mouth, width: 5, depth: 1.1, meander: 14, seed: seed)
        var rim = Float.infinity
        for k in 0..<24 {
            let a = Float(k) / 24 * 2 * .pi, p = pondCenter + SIMD2(cos(a), sin(a)) * radii * 1.25
            rim = min(rim, SceneWaterMaker.height(hills, Double(p.x), Double(p.y)))
        }
        let level = min(SceneWaterMaker.endLevel(stream.body), rim - 0.25)
        let pond = SceneWaterMaker.pond(name: "Pond", center: pondCenter, radii: radii, level: level, depth: 2.2)
        print(String(format: "Forest water: a stream from (%.0f, %.0f), a pond at (%.0f, %.0f), %.0f x %.0f m, its water at %.2f m",
                     source.x, source.y, pondCenter.x, pondCenter.y, radii.x * 2, radii.y * 2, level))
        return (TerrainShapes(bowls: [pond.bowl], channels: [stream.channel]), [stream.body, pond.body])
    }

    /// The trail from the clearing into the forest (north, -z): its x at depth z.
    static func trail(_ z: Float) -> Float { 9 * sin(z / 31) + 4 * sin(z / 13 + 1) }

    /// A forest of `settings.trees` trees on 320 m of rolling ground (`settings.seed` picks the ground, the plants
    /// and where they stand), with a grassy clearing around the camera and a trail leading out of it, a stream coming
    /// down from the north to a pond on one side of it; the valley's day cycle. `settings.undergrowth` scales the
    /// bushes, ferns and grass.
    func buildForest() {
        let seed = UInt64(max(settings.seed, 0))
        // The ground: the terrain "forest-<seed>" (its edits, Terrain Editor), over the seed's rolling hills with its
        // stream's bed and its pond's bowl shaped into them.
        let hills = NoiseTerrainBase(size: 320, cells: 320, seed: seed, relief: 9, flat: (center: [0, 0], inner: 12, outer: 55))
        let (shapes, water) = Scene.forestWater(hills, seed: seed)
        let base = ShapedTerrainBase(hills, shapes: shapes)
        let entry = Scene.openTerrain("forest-\(seed)", base: base, layers: TerrainDocument.sceneLayers())
        let snapshot = entry.field.snapshot()
        let terrain = Terrain(snapshot, relief: 9)
        let half = terrain.size / 2, undergrowth = Float(settings.undergrowth) / 100
        let noiseSeed = UInt32(truncatingIfNeeded: seed) &+ 101
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        /// 0 on the trail, 1 away from it.
        func offTrail(_ x: Float, _ z: Float) -> Float { z < 4 ? smoothstep(1.5, 4.5, abs(x - Scene.trail(z))) : 1 }
        func stand(_ x: Float, _ z: Float) -> Float { Terrain.noise(SIMD2(x, z) / 55, seed: noiseSeed) }   // which species grows where

        // The ground's colours, a texel every 31 cm: leaf litter and soil under the trees, moss in patches, greener in
        // the clearing, the trail's bare earth, rock where it is steep.
        let colors = addGeneratedTexture(name: "ground", width: 1024, height: 1024,
                                         key: "seed \(seed) v\(FoliageTextures.version)\(snapshot.editsFingerprint) \(shapes.fingerprint)") {
            FoliageTextures.image(1024, 1024) { u, v in
                let x = (u - 0.5) * terrain.size, z = (v - 0.5) * terrain.size, p = SIMD2(x, z)
                var color = SIMD3<Float>(0.15, 0.13, 0.075)
                color += (SIMD3(0.085, 0.13, 0.05) - color) * smoothstep(0.05, 0.3, Terrain.noise(p / 9, seed: noiseSeed &+ 31)) * 0.7
                color += (SIMD3(0.12, 0.16, 0.06) - color) * (1 - smoothstep(34, 70, length(p))) * 0.8
                color += (SIMD3(0.24, 0.23, 0.21) - color) * (1 - smoothstep(0.7, 0.85, terrain.normal(x, z).y))
                color += (SIMD3(0.27, 0.215, 0.145) - color) * (1 - offTrail(x, z))
                return color * (1 + 0.45 * Terrain.noise(p / 2.5, seed: noiseSeed &+ 32) + 0.35 * Terrain.noise(p / 0.7, seed: noiseSeed &+ 33))
            }
        }
        let ground = addMaterial(albedo: [1, 1, 1], texture: colors)
        // Its first sector where the ground's one mesh was, the others after the plants: a plant's sway goes by its
        // instance's number, which then stays what it was.
        let sectors = base.grid.tiles!.flatMap { TerrainSector.sectors(of: $0, level: 0, grid: base.grid) }
        let style = TerrainMeshStyle(uvOrigin: base.grid.origin, uvScale: 1 / terrain.size)
        addTerrain(name: entry.document.name, field: entry.field, snapshot: snapshot, sectors: Array(sectors.prefix(1)), style: style, material: ground,
                   generatedWater: water)
        // (Nothing grows in the water or on the stream's banks.)
        let waterField = self.water?.field
        func dry(_ x: Float, _ z: Float, margin: Double = 1.5) -> Bool { !(waterField?.wet(Double(x), Double(z), margin: margin) ?? false) }
        // The realistic look: the ground of scans, leaf litter and soil under the trees with moss in patches, grass in
        // the clearing, the trail's bare earth, mud on the banks and pebbles in the stream's bed, rock where it is steep.
        addGroundLook(GroundLook(
            layers: [.init(set: "forest-floor", color: [0.15, 0.13, 0.075], tint: [0.86, 0.82, 0.76], contrast: 1),
                     .init(set: "moss", color: [0.085, 0.13, 0.05], contrast: 0.6),
                     .init(set: "grass", color: [0.12, 0.16, 0.06], contrast: 0.5),
                     .init(set: "earth", color: [0.27, 0.215, 0.145], tint: [0.78, 0.72, 0.64], contrast: 0.8),
                     .init(set: "rock", color: [0.24, 0.23, 0.21], metres: 4, contrast: 1.4),
                     .init(set: "mud", color: [0.12, 0.09, 0.06], contrast: 0.7),
                     .init(set: "pebbles", color: [0.42, 0.4, 0.37], metres: 1.4, contrast: 0.8),
                     .init(set: "ground", color: [0.16, 0.12, 0.08], tint: [0.92, 0.88, 0.84], contrast: 1)],
            rock: 4, slope: [0.64, 0.82], lo: [-half, -half], size: [terrain.size, terrain.size], texels: 1024,
            key: "forest \(seed) v3 \(snapshot.editsFingerprint) \(shapes.fingerprint)") { x, z in
            let p = SIMD2(x, z)
            let moss = GroundLook.smooth(0.05, 0.35, Terrain.noise(p / 9, seed: noiseSeed &+ 31)) * 0.85
            let soil = GroundLook.smooth(-0.25, 0.35, Terrain.noise(p / 7, seed: noiseSeed &+ 36))
            let clearing = 1 - GroundLook.smooth(26, 60, length(p) + 9 * Terrain.noise(p / 13, seed: noiseSeed &+ 35))
            let trail = 1 - offTrail(x, z)
            let bed = dry(x, z, margin: 0) ? Float(0) : 1
            let bank = (dry(x, z, margin: 1.5) ? Float(0) : 0.6) + (dry(x, z, margin: 3.5) ? Float(0) : 0.4)
            var w = [Float](repeating: 0, count: 8)
            w[0] = (1 - moss) * (1 - soil)
            w[7] = (1 - moss) * soil * 0.8
            w[1] = moss
            func over(_ k: Int, _ amount: Float) {
                guard amount > 0 else { return }
                for i in w.indices { w[i] *= 1 - amount }
                w[k] += amount
            }
            over(2, clearing * 0.9)
            over(7, trail)
            over(5, max(bank, bed))
            over(6, bed * GroundLook.smooth(0, 0.5, Terrain.noise(p / 3, seed: noiseSeed &+ 37)) * 0.7)
            return w
        })
        // ...and its rocks: boulders where it is steep and along the stream, stones scattered under the trees, none on
        // the trail or in the clearing.
        addRocks(count: 9000, lo: [-half + 6, -half + 6], hi: [half - 6, half - 6], seed: seed &+ 0x80C) { x, z in
            let r = (x * x + z * z).squareRoot()
            guard r > 16, offTrail(x, z) > 0.9 else { return (0, 0.1...0.2) }
            let steep = 1 - GroundLook.smooth(0.8, 0.93, terrain.normal(x, z).y)
            let banks = dry(x, z, margin: 0) && !dry(x, z, margin: 3) ? Float(1) : 0
            let clusters = GroundLook.smooth(0.2, 0.6, Terrain.noise(SIMD2(x, z) / 23, seed: noiseSeed &+ 38))
            return (min(0.06 + 0.6 * steep + 0.6 * banks + 0.3 * clusters, 1) * 0.6, 0.2...(0.8 + 1.8 * steep + 0.6 * clusters))
        }
        defer {
            addTerrain(name: entry.document.name, field: entry.field, snapshot: snapshot, sectors: Array(sectors.dropFirst()), style: style,
                       material: ground)
        }

        let flora = Flora(self, seed: seed, catalog: PlantCatalog.resolve(settings.plantCatalog))
        var rng = SplitMix64(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 0xF07E57)

        // Trees: one candidate per cell of a grid (jittered inside it, so no two stand too close), kept by the
        // ground's density there; of those, `trees` by a random rank.
        struct Site { var x, z, rank: Float }
        let wanted = max(settings.trees, 0)
        let side = max(1, Int((Float(wanted) * 2.6).squareRoot().rounded(.up)))
        let cell = (terrain.size - 12) / Float(side)
        var sites: [Site] = []
        sites.reserveCapacity(side * side)
        for j in 0..<side {
            for i in 0..<side {
                let x = (Float(i) + rng.range(0.15, 0.85)) * cell - half + 6, z = (Float(j) + rng.range(0.15, 0.85)) * cell - half + 6
                let chance = rng.next(), rank = rng.next()
                let density = smoothstep(11, 19, (x * x + z * z).squareRoot()) * offTrail(x, z)
                    * smoothstep(0.72, 0.86, terrain.normal(x, z).y)
                    * (0.6 + 0.6 * Terrain.noise(SIMD2(x, z) / 23, seed: noiseSeed &+ 7)) * (dry(x, z, margin: 2.5) ? 1 : 0)
                if chance < density { sites.append(Site(x: x, z: z, rank: rank)) }
            }
        }
        if sites.count > wanted {
            sites.sort { $0.rank < $1.rank }
            sites.removeLast(sites.count - wanted)
        }
        // Where the trunks are, for what grows under the trees to keep off them.
        let lot: Float = 1.5
        let lots = Int(terrain.size / lot) + 1
        var trunks = [Bool](repeating: false, count: lots * lots)
        func lotIndex(_ x: Float, _ z: Float) -> Int { min(Int((z + half) / lot), lots - 1) * lots + min(Int((x + half) / lot), lots - 1) }

        var counts = [Int](repeating: 0, count: flora.catalog.count)
        let catalog = flora.catalog, picker = Foliage.TreePicker(catalog)
        for site in sites {
            let (x, z) = (site.x, site.z)
            let y = terrain.height(x, z), slope = 1 - terrain.normal(x, z).y
            let high = y / terrain.relief, mix = stand(x, z), r = (x * x + z * z).squareRoot()
            // (Built in: conifers up the hills and on slopes, oaks on low ground, birches where the light comes in, at
            // the clearing's edge and along the trail, a dead tree now and then.)
            let light = [SIMD2<Float>(1.2, 1 - smoothstep(18, 42, r)), SIMD2<Float>(0.8, 1 - smoothstep(4, 9, abs(x - Scene.trail(z))))]
            let chosen = picker.pick(rng.next(), high: high, slope: slope, stand: mix, light: light)
            let u = rng.next()
            guard let species = chosen else { continue }
            let age = Foliage.TreePicker.age(u, catalog[species].habitat)
            let plants = flora.plants(species, age)
            trunks[lotIndex(x, z)] = true
            counts[species.rawValue] += 1
            flora.place(species, plants[rng.int(plants.count)], at: [x, y - 0.12, z], yaw: rng.range(0, 2 * .pi),
                        size: rng.range(0.85, 1.2), shade: rng.int(16))
        }

        // Bushes and ground cover, in their order: in patches (a low noise each) off the trail and the trunks, or in
        // the open; grass on a grid, laid on the ground's slope, thinning out under the trees.
        func scatter(_ species: Foliage.Species, _ cover: Foliage.Habitat.Cover, frequency: Float) {
            let ages: [Foliage.Age] = [.young, .mature]
            for _ in 0..<Int(cover.count * undergrowth) {
                let x = rng.range(-half + 4, half - 4), z = rng.range(-half + 4, half - 4)
                let chance = rng.next(), yaw = rng.range(0, 2 * .pi), s = rng.range(cover.size.lowerBound, cover.size.upperBound)
                let plants = flora.plants(species, ages[rng.int(2)])
                let plant = plants[rng.int(plants.count)], shade = rng.int(16)
                let patches = smoothstep(-0.25, 0.35, Terrain.noise(SIMD2(x, z) / cover.patch, seed: noiseSeed &+ cover.salt))
                let r = (x * x + z * z).squareRoot()
                let likely = (cover.open ? (1 - smoothstep(34, 70, r)) * (0.25 + 0.75 * offTrail(x, z)) * patches
                                         : smoothstep(7, 12, r) * offTrail(x, z) * patches) * frequency
                guard chance < likely, !trunks[lotIndex(x, z)], dry(x, z, margin: 0.5) else { continue }
                counts[species.rawValue] += 1
                flora.place(species, plant, at: [x, terrain.height(x, z) - cover.sink, z], yaw: yaw, size: s, shade: shade)
            }
        }
        func grid(_ species: Foliage.Species, _ cover: Foliage.Habitat.Cover, step: Int, frequency: Float) {
            let patches = flora.plants(species, .mature)
            guard !patches.isEmpty else { return }
            let reach = 72
            for j in stride(from: -reach, through: reach, by: max(step, 1)) {
                for i in stride(from: -reach, through: reach, by: max(step, 1)) {
                    let x = Float(i), z = Float(j)
                    let chance = rng.next(), turn = Float(rng.int(4)) * .pi / 2, patch = patches[rng.int(patches.count)], shade = rng.int(16)
                    let likely = (1 - smoothstep(34, 70, (x * x + z * z).squareRoot())) * (0.25 + 0.75 * offTrail(x, z)) * min(undergrowth, 1)
                        * frequency
                    guard chance < likely, dry(x, z, margin: 0.3) else { continue }
                    counts[species.rawValue] += 1
                    flora.place(species, patch, translate([x, terrain.height(x, z), z]) * Scene.alignY(terrain.normal(x, z))
                                * rotate(turn, [0, 1, 0]) * scale(cover.gridScale), shade: shade)
                }
            }
        }
        for species in catalog.covers {
            let habitat = catalog[species].habitat, cover = habitat.cover!
            if let step = cover.grid { grid(species, cover, step: step, frequency: habitat.frequency) } else {
                scatter(species, cover, frequency: habitat.frequency)
            }
        }
        print("Forest: " + flora.catalog.all.map { "\(counts[$0.rawValue]) \(flora.catalog[$0].id)" }.joined(separator: ", "))

        addDaySun()
        defaultCamera = Scene.demoCamera(.forest)!
    }
}
