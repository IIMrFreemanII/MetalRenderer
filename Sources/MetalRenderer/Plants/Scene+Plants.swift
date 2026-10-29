import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Physics
import Plants
import QuartzCore
import simd

/// What one plant costs, for the plant editor: its triangles as stored (its own meshes and its species' twigs) and as
/// traced (baked flat), its leaves', parts and twigs, and how long the workshop took to grow and place it.
package struct PlantStats: Equatable {
    package var species = ""
    package var triangles = 0
    package var traced = 0
    package var leafTriangles = 0
    package var parts = 0
    package var twigs = 0
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
    /// The plant workshop: one species' plants on Unreal's preview stage (Scene+PlantPreview.swift), as
    /// `settings.plants` says. The plant editor rebuilds it at every edit (its species from `settings.plantCatalog`),
    /// so it is small: one species' library, a floor, a sun, and the scale figure and size ruler when asked.
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
        let skeleton = p.view != .plant
        let levelMaterials = skeleton ? Scene.skeletonColors.map { addMaterial(albedo: $0 * 0.6, emission: $0 * 0.6) } : []
        let lightMaterials = p.view == .light ? Scene.lightColors.map { addMaterial(albedo: $0 * 0.6, emission: $0 * 0.6) } : []
        var twigMeshes: [Foliage.Species: [Int]] = [:]
        for e in entries {
            guard let set = flora.set(e.species) else { continue }
            let plant = set.plants[e.plant]
            focus.grow(plant.bounds.transformed(translate([e.x, 0, e.z])))
            let def = catalog[e.species]
            guard skeleton, def.grass == nil else {
                flora.place(e.species, e.plant, at: [e.x, 0, e.z], yaw: 0, size: 1, shade: 0)
                continue
            }
            // The stems as thin tubes, a colour to a generation, and each twig's the twigs' colour.
            let age = plant.age, variant = set.plants(of: age).firstIndex(of: e.plant) ?? 0
            let growth = def.growth ?? Growth.Params(), up = normalize(growth.up)
            var rng = SplitMix64(seed: Foliage.seed(UInt64(max(p.seed, 0)), def.seedIndex, age.rawValue, variant))
            // (The plant's own skeleton: the same seed as the library's.)
            let lit = Growth.lit(Growth.aged(growth, age), seed: rng.nextUInt64())
            let stems = Scene.thinned(lit.skeleton)
            let at = translate([e.x, 0, e.z])
            if p.view == .light {
                // The light view: the stems in bands of the light they get (the twigs are left out).
                let bands = lightMaterials.count
                for band in 0..<bands {
                    let mine = stems.stems.indices.filter { min(Int(lit.light[$0] * Float(bands)), bands - 1) == band }
                    guard !mine.isEmpty else { continue }
                    let mesh = Foliage.mesh(stems, stems: mine, leaves: [], shape: .kite, fold: 0, up: up, allLeaves: false)
                    addInstance(addMesh(mesh), lightMaterials[band], at)
                }
                continue
            }
            let generations = Int(stems.stems.map(\.level).max() ?? 0) + 1
            for level in 0..<generations {
                let mine = stems.stems.indices.filter { Int(stems.stems[$0].level) == level }
                guard !mine.isEmpty else { continue }
                let mesh = Foliage.mesh(stems, stems: mine, leaves: [], shape: .kite, fold: 0, up: up, allLeaves: false)
                addInstance(addMesh(mesh), levelMaterials[min(level, levelMaterials.count - 2)], at)
            }
            if twigMeshes[e.species] == nil, let twigs = def.twigs {
                twigMeshes[e.species] = (0..<def.paletteSize).map { j in
                    let stems = Scene.thinned(Growth.grow(twigs.growth, seed: Foliage.seed(UInt64(max(p.seed, 0)), def.seedIndex, -1, j)))
                    return addMesh(Foliage.mesh(stems, stems: nil, leaves: [], shape: .kite, fold: 0, up: twigs.growth.up, allLeaves: false))
                }
            }
            let palette = twigMeshes[e.species] ?? []
            for part in plant.parts where part.shared && palette.indices.contains(part.mesh) {
                addInstance(palette[part.mesh], levelMaterials[levelMaterials.count - 1], at * part.transform)
            }
        }
        if focus.isEmpty { focus = AABB(lo: [-1, 0, -1], hi: [1, 2, 1]) }

        section("Stage")
        // Unreal's tree preview: its grid floor under a dark grey backdrop, a grey sky lighting it, a white sun 40° up; a person
        // beside the plant and its size written out when asked.
        let kit = Kit(self)
        addPreviewStage(kit)
        var framed = focus
        let edited = chosen(species).flatMap { index in entries.first { $0.species == species && $0.plant == index } }
        if let e = edited, let set = flora.set(e.species) {
            let measured = set.plants[e.plant].bounds.transformed(translate([e.x, 0, e.z]))
            if p.figure { let figure = addPlantFigure(beside: measured, kit); focus.grow(figure); framed.grow(figure) }
            if p.ruler { framed.grow(addSizeRuler(measured, kit)) }
        }
        self.focus = focus
        defaultCamera = Camera.framing(framed, fovY: Camera().fovY).camera

        // What the chosen plant costs (its age and variant, whatever the layout shows besides).
        if let index = chosen(species), let set = flora.set(species) {
            let plant = set.plants[index]
            var stats = PlantStats(species: catalog[species].id, parts: plant.parts.count, height: plant.height)
            stats.twigs = plant.parts.filter(\.shared).count
            stats.triangles = plant.meshes.reduce(0) { $0 + $1.triangles } + set.palette.reduce(0) { $0 + $1.triangles }
            let flat = Foliage.flatten(plant, palette: set.palette)
            stats.traced = flat.wood.triangles + flat.leaves.triangles
            stats.leafTriangles = flat.leaves.triangles
            stats.buildMs = (CACurrentMediaTime() - start) * 1000
            plantStats = stats
        }
    }

    /// The skeleton view's colours, by generation (the trunk white, then warm to cool), and the twigs' last.
    package static let skeletonColors: [SIMD3<Float>] = [[0.9, 0.9, 0.85], [1, 0.45, 0.1], [1, 0.85, 0.15], [0.35, 0.9, 0.3], [0.2, 0.75, 1],
                                                 [0.7, 0.4, 1], [0.15, 0.95, 0.85]]

    /// The light view's colours, from deep shade to full sun.
    package static let lightColors: [SIMD3<Float>] = [[0.05, 0.05, 0.4], [0.15, 0.2, 0.85], [0.1, 0.6, 0.8], [0.3, 0.8, 0.35],
                                               [0.85, 0.85, 0.2], [1, 0.95, 0.6]]

    /// The skeleton with thinner stems, so that the branching shows: under half their radius, never under 4 mm.
    package static func thinned(_ s: Foliage.Skeleton) -> Foliage.Skeleton {
        var out = s
        for i in out.nodes.indices { out.nodes[i].w = max(out.nodes[i].w * 0.4, 0.004) }
        return out
    }
}
