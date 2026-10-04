import Foundation
import simd

/// Generated plants in a scene (Foliage.swift), and the forest: rolling ground with a clearing, trees of four
/// species and three ages scattered by slope, height and stand, bushes and ferns under them, grass in the clearing.
extension Scene {
    /// A scene's plants: the library for its seed, with a plant's meshes added to the scene when it is first placed.
    /// A plant with boughs is an assembly where the scene has them (`usesAssemblies`: its trunk and limbs, and the
    /// species' few bough meshes placed hundreds of times); otherwise it is baked into a wood mesh and a leaf mesh.
    final class Flora {
        private unowned let scene: Scene
        private let sets: [Foliage.SpeciesSet?]                 // by species
        private enum Placed {
            case flat(wood: Int, leaves: Int)                   // meshes, -1 for none
            case assembly(Int)
        }
        private var placed: [[Placed?]]                         // by species, then plant
        private var palettes: [[Int]]                           // by species: its bough meshes in the scene
        private var shades: [[Int]]                             // by species: wood materials, each followed by a leaf material

        init(_ scene: Scene, seed: UInt64, species: [Foliage.Species] = Foliage.Species.allCases) {
            self.scene = scene
            var bySpecies = [Foliage.SpeciesSet?](repeating: nil, count: Foliage.Species.allCases.count)
            for set in Foliage.library(seed: seed, species: species) { bySpecies[set.species.rawValue] = set }
            sets = bySpecies
            placed = bySpecies.map { [Placed?](repeating: nil, count: $0?.plants.count ?? 0) }
            palettes = [[Int]](repeating: [], count: bySpecies.count)
            shades = [[Int]](repeating: [], count: bySpecies.count)
            scene.notePlants()
        }

        private static func barkColor(_ species: Foliage.Species) -> SIMD3<Float> {
            switch species {
            case .oak: return [0.2, 0.15, 0.11]
            case .birch: return [0.72, 0.7, 0.65]
            case .conifer: return [0.19, 0.13, 0.09]
            case .dead: return [0.36, 0.33, 0.29]
            default: return [0.22, 0.16, 0.11]
            }
        }

        private static func leafColors(_ species: Foliage.Species) -> [SIMD3<Float>] {
            switch species {
            case .oak: return [[0.11, 0.22, 0.05], [0.14, 0.25, 0.06], [0.09, 0.19, 0.05], [0.16, 0.24, 0.05]]
            case .birch: return [[0.19, 0.31, 0.07], [0.23, 0.34, 0.08], [0.16, 0.28, 0.07]]
            case .conifer: return [[0.045, 0.11, 0.055], [0.055, 0.13, 0.06], [0.04, 0.1, 0.06]]
            case .bush: return [[0.12, 0.24, 0.07], [0.1, 0.2, 0.06], [0.15, 0.25, 0.06]]
            case .fern: return [[0.13, 0.28, 0.07], [0.16, 0.3, 0.08]]
            case .grass: return [[0.19, 0.32, 0.09], [0.23, 0.34, 0.1], [0.27, 0.33, 0.12]]
            case .dead: return [[0.3, 0.27, 0.2]]
            }
        }

        /// What a species' leaves turn to in autumn (nil: they stay as they are), and how much light they let through.
        private static func autumn(_ species: Foliage.Species) -> SIMD3<Float>? {
            switch species {
            case .oak: return [0.3, 0.14, 0.035]
            case .birch: return [0.42, 0.33, 0.04]
            case .bush: return [0.36, 0.09, 0.04]
            case .fern: return [0.27, 0.17, 0.06]
            case .grass: return [0.3, 0.27, 0.11]
            case .conifer, .dead: return nil
            }
        }

        private static func translucency(_ species: Foliage.Species) -> Float {
            switch species {
            case .oak, .birch, .bush, .fern: return 0.35
            case .grass: return 0.3
            case .conifer: return 0.12
            case .dead: return 0
            }
        }

        /// The species' plants of an age (indices for `place`); the mature ones if it has none that young.
        func plants(_ species: Foliage.Species, _ age: Foliage.Age) -> [Int] {
            guard let set = sets[species.rawValue] else { return [] }
            let some = set.plants(of: age)
            return some.isEmpty ? set.plants(of: .mature) : some
        }

        func height(_ species: Foliage.Species, _ plant: Int) -> Float { sets[species.rawValue]?.plants[plant].height ?? 0 }

        /// The plant as the scene holds it, added on first use.
        private func add(_ set: Foliage.SpeciesSet, _ index: Int) -> Placed {
            let plant = set.plants[index], s = set.species.rawValue
            guard scene.usesAssemblies, plant.parts.count > 1 else {
                let baked = Foliage.flatten(plant, palette: set.palette)
                return .flat(wood: baked.wood.indices.isEmpty ? -1 : scene.addMesh(baked.wood),
                             leaves: baked.leaves.indices.isEmpty ? -1 : scene.addMesh(baked.leaves))
            }
            if palettes[s].isEmpty { palettes[s] = set.palette.map { scene.addMesh($0) } }
            let own = plant.meshes.map { scene.addMesh($0) }
            /// The wind's bone for a limb or a bough: it bobs about a level axis across it, and a little sideways.
            /// A long thin limb swings further than a short thick one.
            func bone(_ b: Foliage.Bone, limb: Bool) -> Assembly.Bone {
                var rng = SplitMix64(seed: UInt64(b.phase * 1e6) &+ 77)
                let level = cross(SIMD3<Float>(0, 1, 0), b.axis)
                let axis = (length_squared(level) > 1e-6 ? normalize(level) : SIMD3<Float>(1, 0, 0)) + Foliage.randomUnit(&rng) * 0.6
                let angle = limb ? 0.03 * min(max(b.length / (max(b.radius, 0.01) * 90), 0.5), 1.6) : 0.09 * (0.7 + 0.6 * b.phase)
                return Assembly.Bone(pivot: b.pivot, angle: angle, axis: normalize(axis), phase: b.phase * 2 * .pi)
            }
            /// The furthest a box's corner is from a point: times a turn's angle, how far the turn moves it at most.
            func reach(_ box: AABB, _ p: SIMD3<Float>) -> Float { length(simd_max(abs(box.lo - p), abs(box.hi - p))) }

            var bounds = AABB()
            let parts = plant.parts.map { part -> Assembly.Part in
                let mesh = part.shared ? set.palette[part.mesh] : plant.meshes[part.mesh]
                // The placed vertices' own bounds: a bough's box, turned, would be far looser.
                var box = AABB()
                let c = part.transform.columns
                let x = Foliage.xyz(c.0), y = Foliage.xyz(c.1), z = Foliage.xyz(c.2), origin = Foliage.xyz(c.3)
                mesh.positions.withUnsafeBufferPointer { for p in $0 { box.grow(x * p.x + y * p.y + z * p.z + origin) } }
                var placed = Assembly.Part(mesh: part.shared ? palettes[s][part.mesh] : own[part.mesh], transform: part.transform,
                                           firstLeaf: UInt32(mesh.leafIndex / 3),
                                           leafCount: set.species == .conifer ? 0 : UInt32(mesh.leafTriangles), bone: part.bone, bounds: box)
                if part.bone > 0 {   // part 0, the trunk, only leans with the whole plant
                    let own = plant.bones[part.bone]
                    if part.shared {
                        placed.bough = bone(own, limb: false)
                        if own.parent > 0 { placed.limb = bone(plant.bones[Int(own.parent)], limb: true) }
                    } else {
                        placed.limb = bone(own, limb: true)
                    }
                    // Room for the turns: the bough's, then its limb's on top of that.
                    placed.windPad = 1.1 * (placed.bough.angle * reach(box, placed.bough.pivot) + placed.limb.angle * reach(box, placed.limb.pivot))
                }
                bounds.grow(AABB(lo: box.lo - SIMD3(repeating: placed.windPad), hi: box.hi + SIMD3(repeating: placed.windPad)))
                return placed
            }
            let sway = 1.1 * Assembly.rootSway * reach(bounds, .zero)
            bounds.lo -= SIMD3(repeating: sway)
            bounds.hi += SIMD3(repeating: sway)
            return .assembly(scene.addAssembly(Assembly(parts: parts, bounds: bounds, evergreen: set.species == .conifer)))
        }

        /// Adds one plant to the scene. `shade` picks among the species' leaf colours.
        func place(_ species: Foliage.Species, _ plant: Int, _ transform: float4x4, shade: Int) {
            let s = species.rawValue
            guard let set = sets[s] else { return }
            if shades[s].isEmpty {
                shades[s] = Flora.leafColors(species).enumerated().map { i, leaf in
                    let wood = scene.addMaterial(albedo: Flora.barkColor(species))
                    let leaves = scene.addMaterial(albedo: leaf, translucency: Flora.translucency(species))
                    if let autumn = Flora.autumn(species) {   // each shade turns at its own time, and to its own shade of it
                        scene.addSeasonal(SeasonalMaterial(material: leaves, summer: leaf, autumn: autumn * (0.8 + 0.2 * Float(i)),
                                                           turn: 0.52 + 0.07 * Float(i)))
                    }
                    return wood
                }
            }
            let known = placed[s][plant] ?? add(set, plant)
            placed[s][plant] = known
            let wood = shades[s][shade % shades[s].count]
            switch known {
            case .assembly(let assembly):
                scene.addInstance(assembly: assembly, wood, transform)
            case .flat(let woodMesh, let leafMesh):
                if woodMesh >= 0 { scene.addInstance(woodMesh, wood, transform) }
                if leafMesh >= 0 { scene.addInstance(leafMesh, wood + 1, transform) }
            }
        }

        func place(_ species: Foliage.Species, _ plant: Int, at position: SIMD3<Float>, yaw: Float, size: Float, shade: Int) {
            place(species, plant, translate(position) * rotate(yaw, [0, 1, 0]) * scale(size), shade: shade)
        }
    }

    // MARK: - Forest

    /// The trail from the clearing into the forest (north, -z): its x at depth z.
    private static func trail(_ z: Float) -> Float { 9 * sin(z / 31) + 4 * sin(z / 13 + 1) }

    /// A forest of `settings.trees` trees on 320 m of rolling ground (`settings.seed` picks the ground, the plants
    /// and where they stand), with a grassy clearing around the camera and a trail leading out of it; the valley's
    /// day cycle. `settings.undergrowth` scales the bushes, ferns and grass.
    func buildForest() {
        let seed = UInt64(max(settings.seed, 0))
        let terrain = Terrain(size: 320, cells: 320, seed: seed, relief: 9, flat: (center: [0, 0], inner: 12, outer: 55))
        let ground = addMaterial(albedo: [0.15, 0.13, 0.075])   // leaf litter and soil
        addInstance(addMesh(terrain.mesh()), ground, matrix_identity_float4x4)

        let flora = Flora(self, seed: seed)
        var rng = SplitMix64(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 0xF07E57)
        let half = terrain.size / 2, undergrowth = Float(settings.undergrowth) / 100
        let noiseSeed = UInt32(truncatingIfNeeded: seed) &+ 101
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        /// 0 on the trail, 1 away from it.
        func offTrail(_ x: Float, _ z: Float) -> Float { z < 4 ? smoothstep(1.5, 4.5, abs(x - Scene.trail(z))) : 1 }
        func stand(_ x: Float, _ z: Float) -> Float { Terrain.noise(SIMD2(x, z) / 55, seed: noiseSeed) }   // which species grows where

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
                    * (0.6 + 0.6 * Terrain.noise(SIMD2(x, z) / 23, seed: noiseSeed &+ 7))
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

        var counts = [Int](repeating: 0, count: Foliage.Species.allCases.count)
        for site in sites {
            let (x, z) = (site.x, site.z)
            let y = terrain.height(x, z), slope = 1 - terrain.normal(x, z).y
            let high = y / terrain.relief, mix = stand(x, z), r = (x * x + z * z).squareRoot()
            // Conifers up the hills and on slopes, oaks on low ground, birches at the clearing's edge and along the
            // trail (they want light), a dead tree now and then.
            let conifer = max(0.05, 0.3 + 1.1 * smoothstep(-0.1, 0.7, high) + 3 * slope + 1.6 * mix)
            let oak = max(0.05, 0.9 - 0.7 * smoothstep(0, 0.7, high) - 1.6 * mix)
            let birch = 0.25 + 1.2 * (1 - smoothstep(18, 42, r)) + 0.8 * (1 - smoothstep(4, 9, abs(x - Scene.trail(z))))
            let total = conifer + oak + birch
            var pick = rng.next() * total * 1.035
            let species: Foliage.Species
            if pick < conifer { species = .conifer } else {
                pick -= conifer
                if pick < oak { species = .oak } else { species = pick - oak < birch ? .birch : .dead }
            }
            let u = rng.next()
            let age: Foliage.Age = u < 0.12 ? .sapling : u < 0.4 ? .young : .mature
            let plants = flora.plants(species, age)
            trunks[lotIndex(x, z)] = true
            counts[species.rawValue] += 1
            flora.place(species, plants[rng.int(plants.count)], at: [x, y - 0.12, z], yaw: rng.range(0, 2 * .pi),
                        size: rng.range(0.85, 1.2), shade: rng.int(16))
        }

        // Bushes and ferns: in patches (a low noise each), off the trail and the trunks.
        func scatter(_ species: Foliage.Species, count: Int, patch: Float, noise: UInt32, size: ClosedRange<Float>, sink: Float) {
            let ages: [Foliage.Age] = [.young, .mature]
            for _ in 0..<count {
                let x = rng.range(-half + 4, half - 4), z = rng.range(-half + 4, half - 4)
                let chance = rng.next(), yaw = rng.range(0, 2 * .pi), s = rng.range(size.lowerBound, size.upperBound)
                let plants = flora.plants(species, ages[rng.int(2)])
                let plant = plants[rng.int(plants.count)], shade = rng.int(16)
                let likely = smoothstep(7, 12, (x * x + z * z).squareRoot()) * offTrail(x, z)
                    * smoothstep(-0.25, 0.35, Terrain.noise(SIMD2(x, z) / patch, seed: noise))
                guard chance < likely, !trunks[lotIndex(x, z)] else { continue }
                counts[species.rawValue] += 1
                flora.place(species, plant, at: [x, terrain.height(x, z) - sink, z], yaw: yaw, size: s, shade: shade)
            }
        }
        scatter(.bush, count: Int(2600 * undergrowth), patch: 28, noise: noiseSeed &+ 31, size: 0.8...1.3, sink: 0.05)
        scatter(.fern, count: Int(6000 * undergrowth), patch: 17, noise: noiseSeed &+ 47, size: 0.9...1.7, sink: 0.02)

        // Grass: patches on a 2 m grid, laid on the ground's slope, thinning out under the trees.
        let patches = flora.plants(.grass, .mature)
        let reach = 72
        for j in stride(from: -reach, through: reach, by: 2) {
            for i in stride(from: -reach, through: reach, by: 2) {
                let x = Float(i), z = Float(j)
                let chance = rng.next(), turn = Float(rng.int(4)) * .pi / 2, patch = patches[rng.int(patches.count)], shade = rng.int(16)
                let likely = (1 - smoothstep(34, 70, (x * x + z * z).squareRoot())) * (0.25 + 0.75 * offTrail(x, z)) * min(undergrowth, 1)
                guard chance < likely else { continue }
                counts[Foliage.Species.grass.rawValue] += 1
                flora.place(.grass, patch, translate([x, terrain.height(x, z), z]) * Scene.alignY(terrain.normal(x, z))
                            * rotate(turn, [0, 1, 0]) * scale(1.12), shade: shade)
            }
        }
        print("Forest: " + Foliage.Species.allCases.map { "\(counts[$0.rawValue]) \($0)" }.joined(separator: ", "))

        addDaySun(half: 90)
        defaultCamera = Scene.demoCamera(.forest)!
    }
}
