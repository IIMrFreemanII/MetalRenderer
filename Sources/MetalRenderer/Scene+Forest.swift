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
        /// What `add` needs of a plant that takes a loop over its vertices: its parts' boxes, placed (an assembly),
        /// or the plant baked into a wood and a leaf mesh. Made for every plant at once by `init`, in parallel.
        private enum Prepared {
            case boxes([AABB])
            case flat(wood: Foliage.Mesh, leaves: Foliage.Mesh)
        }
        private let prepared: [[Prepared]]                      // by species, then plant
        private var palettes: [[Int]]                           // by species: its bough meshes in the scene
        private var shades: [[Int]]                             // by species: wood materials, each followed by a leaf material
        private var textures = [UInt32?](repeating: nil, count: FoliageTextures.Kind.allCases.count)   // made on first use
        private var sheets: [(texture: UInt32, layer: Int)?]    // by species: its leaf cards' colours and alpha layer
        private let library: String                             // what the plants' meshes are named by (Scene.meshNames)
        private let borrows: Bool                               // the baked plants' meshes stay here (Scene.BorrowedMesh)
        /// The species the plants are of.
        let catalog: PlantCatalog

        /// The last library made and what `add` needs of its plants (200 MB of meshes where they are baked): a scene
        /// made again with the same plants, as the open world's is around every tile the camera comes to, takes them
        /// as they are.
        private static var last: (key: String, sets: [Foliage.SpeciesSet?], prepared: [[Prepared]])?
        private static let lastLock = NSLock()

        /// Lets go of the kept library (a scene without plants has been made).
        static func forget() {
            lastLock.lock()
            last = nil
            lastLock.unlock()
        }

        /// `borrowing`: the scene borrows the baked plants' meshes instead of copying them into its arrays.
        /// `keep`: the library is kept for the next scene made with the same plants (not the workshop's, made anew at
        /// every edit: it would push out the forest's).
        init(_ scene: Scene, seed: UInt64, catalog: PlantCatalog = .builtIn, species: [Foliage.Species]? = nil, borrowing: Bool = false,
             keep: Bool = true) {
            self.scene = scene
            self.catalog = catalog
            borrows = borrowing
            let species = species ?? catalog.all
            // (Edited species name what they are: no cache then holds plants of other recipes under their names.)
            library = "plants v\(Foliage.version) seed \(seed) of \(species.map(\.rawValue)) cards \(scene.usesCards)"
                + (catalog == .builtIn ? "" : " recipes \(catalog.fingerprint)")
            palettes = [[Int]](repeating: [], count: catalog.count)
            shades = [[Int]](repeating: [], count: catalog.count)
            sheets = [(texture: UInt32, layer: Int)?](repeating: nil, count: catalog.count)
            let key = "\(library) assemblies \(scene.usesAssemblies)"
            Flora.lastLock.lock()
            let known = keep ? Flora.last : nil
            Flora.lastLock.unlock()
            if let known, known.key == key {
                (sets, prepared) = (known.sets, known.prepared)
                placed = sets.map { [Placed?](repeating: nil, count: $0?.plants.count ?? 0) }
                scene.notePlants()
                return
            }
            var bySpecies = [Foliage.SpeciesSet?](repeating: nil, count: catalog.count)
            for set in Foliage.library(seed: seed, catalog: catalog, species: species, cards: scene.usesCards) { bySpecies[set.species.rawValue] = set }
            sets = bySpecies
            placed = bySpecies.map { [Placed?](repeating: nil, count: $0?.plants.count ?? 0) }
            let jobs = bySpecies.enumerated().flatMap { s, set in (set?.plants.indices ?? 0..<0).map { (species: s, plant: $0) } }
            let assemblies = scene.usesAssemblies
            var made = [Prepared](repeating: .boxes([]), count: jobs.count)
            made.withUnsafeMutableBufferPointer { slots in
                DispatchQueue.concurrentPerform(iterations: jobs.count) { j in   // a plant each: its own slot
                    let set = bySpecies[jobs[j].species]!, plant = set.plants[jobs[j].plant]
                    guard assemblies, Flora.hasVoxels(plant, catalog[set.species]) else {
                        let baked = Foliage.flatten(plant, palette: set.palette)
                        slots[j] = .flat(wood: baked.wood, leaves: baked.leaves)
                        return
                    }
                    slots[j] = .boxes(plant.parts.map { part in
                        // The placed vertices' own bounds: a bough's box, turned, would be far looser.
                        let mesh = part.shared ? set.palette[part.mesh] : plant.meshes[part.mesh]
                        var box = AABB()
                        let c = part.transform.columns
                        let x = Foliage.xyz(c.0), y = Foliage.xyz(c.1), z = Foliage.xyz(c.2), origin = Foliage.xyz(c.3)
                        mesh.positions.withUnsafeBufferPointer { for p in $0 { box.grow(x * p.x + y * p.y + z * p.z + origin) } }
                        return box
                    })
                }
            }
            var next = 0
            prepared = bySpecies.map { set in
                defer { next += set?.plants.count ?? 0 }
                return Array(made[next..<(next + (set?.plants.count ?? 0))])
            }
            if keep {
                Flora.lastLock.lock()
                Flora.last = (key, sets, prepared)
                Flora.lastLock.unlock()
            }
            scene.notePlants()
        }

        private func texture(_ kind: FoliageTextures.Kind) -> UInt32 {
            if let made = textures[kind.rawValue] { return made }
            let size = FoliageTextures.size(kind)
            let made = scene.addGeneratedTexture(name: kind.name, width: size.width, height: size.height, key: "v\(FoliageTextures.version)") {
                FoliageTextures.make(kind)
            }
            textures[kind.rawValue] = made
            return made
        }

        /// The species' card sheet, if its leaves are cards here: made on first use.
        private func sheet(_ species: Foliage.Species) -> (texture: UInt32, layer: Int)? {
            let def = catalog[species]
            guard scene.usesCards, def.paletteSize > 0, let leaf = def.boughRecipe(variant: 0)?.leaf else { return nil }
            if let made = sheets[species.rawValue] { return made }
            let sheet = FoliageTextures.cardSheet(leaf, twig: Foliage.cardTwig, seed: 0xCA2D &+ UInt64(def.seedIndex))
            let made = (scene.addGeneratedTexture(sheet.image, name: "cards-\(def.id)"), scene.addCutout(alpha: sheet.alpha, coverage: sheet.coverage))
            sheets[species.rawValue] = made
            return made
        }

        /// The species' plants of an age (indices for `place`); the mature ones if it has none that young.
        func plants(_ species: Foliage.Species, _ age: Foliage.Age) -> [Int] {
            guard let set = sets[species.rawValue] else { return [] }
            let some = set.plants(of: age)
            return some.isEmpty ? set.plants(of: .mature) : some
        }

        func height(_ species: Foliage.Species, _ plant: Int) -> Float { sets[species.rawValue]?.plants[plant].height ?? 0 }

        /// The species' palette and plants, as the library grew them.
        func set(_ species: Foliage.Species) -> Foliage.SpeciesSet? { sets[species.rawValue] }

        /// The vertices and indices of every plant here that go into the scene's arrays (for `reserveGeometry`): each
        /// baked plant, unless they are lent, and for the others a species' boughs once and each plant's own meshes.
        var geometry: (vertices: Int, indices: Int) {
            var vertices = 0, indices = 0
            func count(_ mesh: Foliage.Mesh) { vertices += mesh.positions.count; indices += mesh.indices.count }
            for (s, set) in sets.enumerated() {
                guard let set else { continue }
                var boughs = false
                for (p, plant) in set.plants.enumerated() {
                    switch prepared[s][p] {
                    case .flat(let wood, let leaves): if !borrows { count(wood); count(leaves) }
                    case .boxes: boughs = true; plant.meshes.forEach(count)
                    }
                }
                if boughs { set.palette.forEach(count) }
            }
            return (vertices, indices)
        }

        /// A plant that is an assembly where the scene has them, and voxels when far: one with
        /// boughs, or a dead tree (an assembly only for the wind to lean it). Ferns and grass are meshes that lean by
        /// themselves (`sways`), close to the ground: always triangles.
        static func hasVoxels(_ plant: Foliage.Plant, _ def: Foliage.SpeciesDef) -> Bool { plant.parts.count > 1 || def.role == .tree }

        /// What the plant's voxels are made of (FoliageVoxels): its parts, as its assembly places them.
        private func voxelPlant(_ set: Foliage.SpeciesSet, _ index: Int) -> FoliageVoxels.Plant {
            let plant = set.plants[index]
            return FoliageVoxels.Plant(key: "\(library): \(catalog[set.species].id) \(index)", pieces: plant.parts.map { part in
                let mesh = part.shared ? set.palette[part.mesh] : plant.meshes[part.mesh]
                // A card is only there where its picture is (the shared boughs' leaves are the cards).
                let coverage = part.shared && mesh.cutout ? sheet(set.species).map { scene.cutouts[$0.layer].coverage } ?? 1 : 1
                return FoliageVoxels.Piece(mesh: mesh, transform: part.transform, firstLeaf: UInt32(mesh.leafIndex / 3), leafCoverage: coverage)
            }, evergreen: catalog[set.species].look.evergreen)
        }

        /// The library's plants by species and age, for the open world's placing (World.swift).
        var index: World.Flora { World.Flora(sets.compactMap { $0 }, catalog: catalog) }

        /// The plant as the scene holds it, added on first use.
        private func add(_ set: Foliage.SpeciesSet, _ index: Int) -> Placed {
            let plant = set.plants[index], s = set.species.rawValue, def = catalog[set.species]
            let boxes: [AABB]
            switch prepared[s][index] {
            case .flat(let wood, let leaves):
                let sways = scene.usesAssemblies && def.role == .groundCover
                let name = "\(library): \(def.id) \(index)"
                let layer = leaves.cutout ? sheet(set.species)?.layer : nil
                // A baked plant is its finest level; one with boughs is voxels when far (VoxelLOD).
                func finest(_ m: Int) -> Int { scene.setDetailLevel(m, 0); return m }
                func flat(wood w: Int, leaves l: Int) -> Placed {
                    if scene.usesVoxelBoxes, w >= 0, Flora.hasVoxels(plant, def) {
                        let voxels = scene.addVoxelPlant(voxelPlant(set, index))
                        scene.setMeshVoxels(w, plant: voxels, leaves: false)
                        scene.setMeshVoxels(l, plant: voxels, leaves: true)
                    }
                    return .flat(wood: w, leaves: l)
                }
                guard borrows else {
                    return flat(wood: wood.indices.isEmpty ? -1 : finest(scene.addMesh(wood, sways: sways, name: name + " wood")),
                                leaves: leaves.indices.isEmpty ? -1 : finest(scene.addMesh(leaves, sways: sways, cutout: layer, name: name + " leaves")))
                }
                // The meshes stay the library's (arrays share their storage): the renderer copies them from here.
                func lend(_ mesh: Foliage.Mesh, _ name: String, cutout: Int? = nil) -> Int {
                    guard !mesh.indices.isEmpty else { return -1 }
                    return scene.addMesh(borrowing: BorrowedMesh(positions: .made(mesh.positions), normals: .made(mesh.normals), uvs: .made(mesh.uvs),
                                                                 indices: .made(mesh.indices)),
                                         bounds: mesh.bounds, name: name, sways: sways,
                                         cutout: cutout.map { UInt32($0 + 1) << 24 | UInt32(mesh.leafIndex / 3) } ?? 0)
                }
                return flat(wood: finest(lend(wood, name + " wood")), leaves: finest(lend(leaves, name + " leaves", cutout: layer)))
            case .boxes(let placed):
                boxes = placed
            }
            if palettes[s].isEmpty { palettes[s] = set.palette.map { scene.addMesh($0, cutout: $0.cutout ? sheet(set.species)?.layer : nil) } }
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
            let parts = plant.parts.enumerated().map { p, part -> Assembly.Part in
                let mesh = part.shared ? set.palette[part.mesh] : plant.meshes[part.mesh]
                let box = boxes[p]
                var placed = Assembly.Part(mesh: part.shared ? palettes[s][part.mesh] : own[part.mesh], transform: part.transform,
                                           firstLeaf: UInt32(mesh.leafIndex / 3),
                                           leafCount: def.look.evergreen ? 0 : UInt32(mesh.leafTriangles), bone: part.bone, bounds: box)
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
            let assembly = scene.addAssembly(Assembly(parts: parts, bounds: bounds, evergreen: def.look.evergreen))
            let voxels = scene.addVoxelPlant(voxelPlant(set, index))
            precondition(voxels == assembly, "an assembly's grid is the voxel plant of its number")
            return .assembly(assembly)
        }

        /// The species' materials and their textures. `place` adds a species' with its first plant; a scene whose
        /// plants come in an order of its own (the open world's: tile by tile) adds them all first, so that every
        /// scene of it has the same textures in the same order.
        func addMaterials(of species: [Foliage.Species]? = nil) {
            for species in species ?? catalog.all where sets[species.rawValue] != nil && shades[species.rawValue].isEmpty {
                let look = catalog[species].look
                // A material's colour is the plant's over its texture's mean: the texture is detail on top of it.
                let gain = 1 / FoliageTextures.mean
                let bark = texture(look.barkTexture), blade = sheet(species)?.texture ?? texture(look.leafTexture)
                shades[species.rawValue] = look.leaves.enumerated().map { i, leaf in
                    let wood = scene.addMaterial(albedo: look.bark * gain, texture: bark)
                    let leaves = scene.addMaterial(albedo: leaf * gain, translucency: look.translucency, texture: blade)
                    // Each shade turns at its own time, and to its own shade of autumn.
                    scene.addLeafMaterial(LeafMaterial(material: leaves, summer: leaf, autumn: look.autumn.map { $0 * (0.8 + 0.2 * Float(i)) },
                                                       turn: 0.52 + 0.07 * Float(i), translucency: look.translucency, gain: gain))
                    return wood
                }
            }
        }

        /// Adds one plant to the scene. `shade` picks among the species' leaf colours.
        func place(_ species: Foliage.Species, _ plant: Int, _ transform: float4x4, shade: Int) {
            let s = species.rawValue
            guard let set = sets[s] else { return }
            if shades[s].isEmpty { addMaterials(of: [species]) }
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

        /// Every plant of the library, in its order, whether one is placed or not: the scenes of an open world then
        /// have the same meshes, assemblies and materials under the same numbers, which the instances a group keeps
        /// from scene to scene count on (`Scene.InstanceGroup`).
        func addAll() {
            addMaterials()
            for (s, set) in sets.enumerated() {
                guard let set else { continue }
                for plant in set.plants.indices where placed[s][plant] == nil { placed[s][plant] = add(set, plant) }
            }
        }

        /// The library and how the scene holds its plants: what a group of these instances is named by.
        var name: String { "\(library) assemblies \(scene.usesAssemblies)" }

        /// How many instances a plant is (after `addAll`): one, or where plants are baked its wood and its leaves.
        func instanceCount(_ species: Foliage.Species, _ plant: Int) -> Int {
            switch placed[species.rawValue][plant] {
            case .assembly: return 1
            case .flat(let wood, let leaves): return (wood >= 0 ? 1 : 0) + (leaves >= 0 ? 1 : 0)
            case nil: return 0
            }
        }

        /// A plant's instances (one, or its wood and its leaves) for a group, after `addAll`: what `place` adds to the
        /// scene. Reads only: any thread.
        func instances(_ species: Foliage.Species, _ plant: Int, at position: SIMD3<Float>, yaw: Float, size: Float, shade: Int,
                       into out: inout [Instance]) {
            let s = species.rawValue
            guard let known = placed[s][plant], !shades[s].isEmpty else { return }
            let transform = translate(position) * rotate(yaw, [0, 1, 0]) * scale(size), normal = transform.inverse.transpose
            let wood = shades[s][shade % shades[s].count]
            func instance(mesh: Int, assembly: Int, _ material: Int) -> Instance {
                Instance(mesh: mesh, material: material, mask: scene.instanceMask(Scene.maskGeometry, mesh: mesh, assembly: assembly >= 0),
                         transform: transform, prevTransform: transform,
                         animation: nil, assembly: assembly, normalMatrix: normal)
            }
            switch known {
            case .assembly(let assembly):
                out.append(instance(mesh: -1, assembly: assembly, wood))
            case .flat(let woodMesh, let leafMesh):
                if woodMesh >= 0 { out.append(instance(mesh: woodMesh, assembly: -1, wood)) }
                if leafMesh >= 0 { out.append(instance(mesh: leafMesh, assembly: -1, wood + 1)) }
            }
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
        let colors = addGeneratedTexture(name: "ground", width: 1024, height: 1024, key: "seed \(seed) v\(FoliageTextures.version)") {
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
        addInstance(addMesh(terrain.mesh()), ground, matrix_identity_float4x4)

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
                guard chance < likely, !trunks[lotIndex(x, z)] else { continue }
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
                    guard chance < likely else { continue }
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

        addDaySun(half: 90)
        defaultCamera = Scene.demoCamera(.forest)!
    }
}
