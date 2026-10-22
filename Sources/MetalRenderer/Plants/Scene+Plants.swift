import EngineCore
import Foundation
import Plants
import QuartzCore
import simd

/// What one plant costs, for the plant editor: its triangles as stored (its own meshes and its species' boughs) and as
/// traced (baked flat), its leaves', parts and boughs, and how long the workshop took to grow and place it.
package struct PlantStats: Equatable {
    package var species = ""
    package var triangles = 0
    package var traced = 0
    package var leafTriangles = 0
    package var parts = 0
    package var boughs = 0
    package var height: Float = 0
    package var buildMs = 0.0
}

extension Camera {
    /// Looking at `box` from `yaw`, `pitch`, far enough for all of it to be in view (`aspect`: the frame's width over
    /// its height). Also the point it looks at and how far it is.
    package static func framing(_ box: AABB, fovY: Float, aspect: Float = 1.6, yaw: Float = 0, pitch: Float = -0.15)
        -> (camera: Camera, target: SIMD3<Float>, distance: Float) {
        let target = box.centroid, half = simd_max((box.hi - box.lo) / 2, SIMD3(repeating: 0.2))
        let tanY = tan(fovY / 2), across = max(half.x, half.z)
        // Its height and width in view at the depth of its front, with a margin; its front is half its depth nearer.
        let distance = max(half.y / tanY, across / (tanY * aspect)) * 1.15 + half.z
        var c = Camera()
        c.yaw = yaw
        c.pitch = pitch
        c.fovY = fovY
        c.position = target - c.forward * distance
        return (c, target, distance)
    }
}

extension Scene {
    /// The plant workshop: one species' plants on a lawn under a still sun, as `settings.plants` says. The plant
    /// editor rebuilds it at every edit (its species from `settings.plantCatalog`), so it is small: one species'
    /// library, a ground and a sun.
    package func buildPlantWorkshop() {
        let start = CACurrentMediaTime()
        remadeOften = true
        let p = settings.plants
        var catalog = PlantCatalog.resolve(settings.plantCatalog)
        let species = catalog.species(id: p.species) ?? .oak
        // Comparing: the definition to compare with in place of the edited one.
        if let other = PlantCatalog.registered(p.compare), let def = other.species.first(where: { $0.id == catalog[species].id }) {
            catalog.species[species.rawValue] = def
        }
        var shown = [species]
        if p.layout == .mutate, let mutants = PlantCatalog.registered(p.mutants) {
            for m in mutants.species {
                catalog.species.append(m)
                shown.append(Foliage.Species(rawValue: catalog.count - 1))
            }
        }
        let flora = Flora(self, seed: UInt64(max(p.seed, 0)), catalog: catalog, species: shown, keep: false)

        // What stands where: (species, plant, x, z).
        var entries: [(species: Foliage.Species, plant: Int, x: Float, z: Float)] = []
        func width(_ s: Foliage.Species, _ plant: Int) -> Float {
            guard let b = flora.set(s)?.plants[plant].bounds else { return 1 }
            return max(b.hi.x - b.lo.x, b.hi.z - b.lo.z)
        }
        func chosen(_ s: Foliage.Species) -> Int? {
            guard let set = flora.set(s), !set.plants.isEmpty else { return nil }
            let some = set.plants(of: p.age), pool = some.isEmpty ? set.plants(of: .mature) : some
            return pool.isEmpty ? 0 : pool[min(max(p.variant, 0), pool.count - 1)]
        }
        switch p.layout {
        case .single:
            if let plant = chosen(species) { entries.append((species, plant, 0, 0)) }
        case .lineup:
            // The ages from left to right, their variants one behind another.
            guard let set = flora.set(species) else { break }
            let rows = Foliage.Age.allCases.map { set.plants(of: $0) }.filter { !$0.isEmpty }
            let gap = (set.plants.indices.map { width(species, $0) }.max() ?? 1) * 1.1 + 0.5
            for (column, plants) in rows.enumerated() {
                for (row, plant) in plants.prefix(4).enumerated() {
                    entries.append((species, plant, (Float(column) - Float(rows.count - 1) / 2) * gap, -Float(row) * gap))
                }
            }
        case .mutate:
            let plants = shown.compactMap { s in chosen(s).map { (s, $0) } }
            let gap = (plants.map { width($0.0, $0.1) }.max() ?? 1) * 1.1 + 0.5
            for (k, plant) in plants.enumerated() {
                entries.append((plant.0, plant.1, (Float(k) - Float(plants.count - 1) / 2) * gap, 0))
            }
        }

        var focus = AABB()
        let skeleton = p.view == .skeleton
        let levelMaterials = skeleton ? Scene.skeletonColors.map { addMaterial(albedo: $0 * 0.6, emission: $0 * 0.6) } : []
        var boughMeshes: [Foliage.Species: [Int]] = [:]
        for e in entries {
            guard let set = flora.set(e.species) else { continue }
            let plant = set.plants[e.plant]
            focus.grow(plant.bounds.transformed(translate([e.x, 0, e.z])))
            let def = catalog[e.species]
            guard skeleton, def.grass == nil else {
                flora.place(e.species, e.plant, at: [e.x, 0, e.z], yaw: 0, size: 1, shade: 0)
                continue
            }
            // The stems as thin tubes, a colour to a level, and each bough's the bough's colour.
            let age = plant.age, variant = set.plants(of: age).firstIndex(of: e.plant) ?? 0
            let recipe = def.recipe(age)
            var rng = SplitMix64(seed: Foliage.seed(UInt64(max(p.seed, 0)), def.seedIndex, age.rawValue, variant))
            let stems = Scene.thinned(Foliage.grow(recipe, seed: rng.nextUInt64()))
            let at = translate([e.x, 0, e.z])
            for level in 0..<recipe.levels.count {
                let mine = stems.stems.indices.filter { Int(stems.stems[$0].level) == level }
                guard !mine.isEmpty else { continue }
                let mesh = Foliage.mesh(stems, stems: mine, leaves: [], shape: .kite, fold: 0, up: recipe.up, allLeaves: false)
                addInstance(addMesh(mesh), levelMaterials[min(level, levelMaterials.count - 2)], at)
            }
            if boughMeshes[e.species] == nil {
                boughMeshes[e.species] = (0..<def.paletteSize).compactMap { j in
                    guard let bough = def.boughRecipe(variant: j) else { return nil }
                    var rng = SplitMix64(seed: Foliage.seed(UInt64(max(p.seed, 0)), def.seedIndex, -1, j))
                    let stems = Scene.thinned(Foliage.grow(bough, seed: rng.nextUInt64()))
                    return addMesh(Foliage.mesh(stems, stems: nil, leaves: [], shape: .kite, fold: 0, up: bough.up, allLeaves: false))
                }
            }
            let palette = boughMeshes[e.species] ?? []
            for part in plant.parts where part.shared && palette.indices.contains(part.mesh) {
                addInstance(palette[part.mesh], levelMaterials[levelMaterials.count - 1], at * part.transform)
            }
        }
        if focus.isEmpty { focus = AABB(lo: [-1, 0, -1], hi: [1, 2, 1]) }
        self.focus = focus

        section("Lawn and sun")
        // The lawn: gentle ground (its own terrain, half a kilometre), level round the plants (out to their reach in
        // steps of 8 m, which the terrain's name says: an edit that keeps the plants within it keeps the ground), a pond
        // behind them; beyond it a plain to the horizon. A still sun from the camera's left, a little above the plants.
        let kit = Kit(self), lawn = addMaterial(albedo: [0.2, 0.22, 0.16])
        let reach = max((max(abs(focus.lo.x), abs(focus.hi.x), abs(focus.lo.z), abs(focus.hi.z)) / 8).rounded(.up) * 8, 8)
        let hills = NoiseTerrainBase(size: 512, cells: 256, seed: 0x9A7D, relief: 4, featureSize: 90)
        let pond = (-3...3).map { k in SIMD2<Float>(Float(k) * 12, -(reach + 24)) }
            .map { Scene.pond(on: hills, center: $0, radii: [12, 8], depth: 1.6) }
            .min { $0.body.level < $1.body.level }!
        let ground = ShapedTerrainBase(hills, shapes: TerrainShapes(flats: [TerrainShapes.Flat(lo: [-reach, -reach], hi: [reach, reach], corner: reach,
                                                                                               level: 0, blend: 16)],
                                                                    bowls: [pond.bowl]))
        addGroundTerrain("plant-workshop-\(Int(reach))", base: ground, material: lawn, water: [pond.body])
        addGroundLook(GroundLook.meadow(lo: [-256, -256], size: [512, 512], texels: 1024, key: "plant-workshop-\(Int(reach))", seed: 0x9A7D,
                                        water: water?.field) { x, z in
            // Bare earth round the plants' feet.
            (1 - GroundLook.smooth(0, 6, simd_length(SIMD2(x, z)) - 0.4 * reach + 2 * Terrain.noise(SIMD2(x, z) / 2, seed: 0x9A7E))) * 0.8
        })
        // The realistic look's grass round the bare patch, not in the pond: "high" only (the workshop is remade at every
        // edit, and the grass took its frame from 8.5 to 24 ms on the M1 Max).
        let pondField = water?.field
        if settings.realism == .high { addMeadowGrass(center: .zero, reach: 36, seed: 0x9A7F) { x, z in
            if pondField?.wet(Double(x), Double(z), margin: 1) == true { return 0 }
            return GroundLook.smooth(0.4 * reach + 1, 0.4 * reach + 5, simd_length(SIMD2(x, z)))
                * (0.75 + 0.25 * GroundLook.smooth(-0.3, 0.4, Terrain.noise(SIMD2(x, z) / 13, seed: 0x9A80)))
        } }
        addInstance(kit.quad, lawn, translate([0, -9, 0]) * scale([20_000, 1, 20_000]))
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1]) { _ in
            let e = Scene.degrees(38), a = Scene.degrees(235)
            return LightPose(position: .zero, direction: [cos(e) * cos(a), sin(e), -cos(e) * sin(a)])
        }
        defaultCamera = Camera.framing(focus, fovY: Camera().fovY).camera

        // What the chosen plant costs (its age and variant, whatever the layout shows besides).
        if let index = chosen(species), let set = flora.set(species) {
            let plant = set.plants[index]
            var stats = PlantStats(species: catalog[species].id, parts: plant.parts.count, height: plant.height)
            stats.boughs = plant.parts.filter(\.shared).count
            stats.triangles = plant.meshes.reduce(0) { $0 + $1.triangles } + set.palette.reduce(0) { $0 + $1.triangles }
            let flat = Foliage.flatten(plant, palette: set.palette)
            stats.traced = flat.wood.triangles + flat.leaves.triangles
            stats.leafTriangles = flat.leaves.triangles
            stats.buildMs = (CACurrentMediaTime() - start) * 1000
            plantStats = stats
        }
    }

    /// The skeleton view's colours, by level (level 0 white, then warm to cool), and the boughs' last.
    package static let skeletonColors: [SIMD3<Float>] = [[0.9, 0.9, 0.85], [1, 0.45, 0.1], [1, 0.85, 0.15], [0.35, 0.9, 0.3], [0.2, 0.75, 1],
                                                 [0.7, 0.4, 1], [0.15, 0.95, 0.85]]

    /// The skeleton with thinner stems, so that the branching shows: under half their radius, never under 4 mm.
    package static func thinned(_ s: Foliage.Skeleton) -> Foliage.Skeleton {
        var out = s
        for i in out.nodes.indices { out.nodes[i].w = max(out.nodes[i].w * 0.4, 0.004) }
        return out
    }
}
