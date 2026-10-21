import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// What a scene's terrain carries on it: its document's scatter rules' things (TerrainScatter: every candidate of a
/// rule's cells an instance, hidden where the rule leaves it out, so that a stroke re-scatters by moving instances, not
/// by making the scene again), and the things its builder stood on the ground (anchors: they follow the ground when a
/// brush moves it).
final class SceneScatter {
    struct Slot {
        var candidate: TerrainScatter.Candidate
        /// Its instances, and each one's transform from the candidate's own (a plant's wood and leaves, a building's
        /// parts).
        var instances: [Int]
        var relative: [float4x4]
    }
    struct Anchor {
        var instance: Int
        /// Where it stands (the world's x, z), and its height over the ground there.
        var place: SIMD2<Double>
        var lift: Float
        var transform: float4x4
    }
    var rules: [ScatterRule] = []
    var slots: [Slot] = []
    var anchors: [Anchor] = []
    /// The water the rules keep out of, and the layers they read.
    var water: [WaterBody] = []
    var layers: [TerrainLayer] = []
}

extension Scene {
    /// After the builder: the terrain's scatter rules' things on the ground it shows (a finite terrain whole, the open
    /// world's tiles next to the camera), and anchors for what the builder stood on it.
    package func finishTerrainScatter() {
        guard let t = terrain, let doc = TerrainDocuments.shared.document(t.name) else { return }
        let sc = SceneScatter()
        sc.rules = doc.scatter
        sc.water = doc.water + t.generatedWater
        sc.layers = doc.layers
        t.scatter = sc
        let s = t.field.snapshot()
        anchorToTerrain(t, sc, snapshot: s)
        guard doc.scatter.contains(where: \.enabled) else { return }
        let grid = t.field.grid
        let near = t.parts.filter { $0.sector.level == 0 }.map(\.sector)
        guard !near.isEmpty else { return }
        let lo = near.map(\.first).reduce(SIMD2(Int.max, Int.max), simd_min), hi = near.map(\.last).reduce(SIMD2(Int.min, Int.min), simd_max)
        let a = grid.place(lo.x, lo.y), b = grid.place(hi.x, hi.y)
        section("Scatter")
        var flora: Flora?
        var rocks: [Int: (mesh: Int, material: Int)] = [:]
        let rockMaterial = addPBRMaterial(baseColor: [0.32, 0.3, 0.27], metallic: 0, roughness: 0.85)
        for (r, rule) in doc.scatter.enumerated() where rule.enabled {
            let candidates = TerrainScatter.candidates(rule, index: r, lo: a, hi: b)
            if case .plant = rule.source, flora == nil { flora = Flora(self, seed: UInt64(max(settings.seed, 0)), catalog: PlantCatalog.resolve(settings.plantCatalog)) }
            var buildings: BuildingKit?
            for c in candidates {
                let placed = TerrainScatter.placement(c, rule: rule, snapshot: s, layers: doc.layers, water: doc.water)
                let ground = SIMD3(c.x, Double(s.height(x: c.x, z: c.z)), c.z)
                let canonical = TerrainScatter.transform(c, rule: rule, position: placed?.position ?? ground, normal: placed?.normal ?? [0, 1, 0],
                                                         offset: t.offset)
                let first = instances.count
                switch rule.source {
                case .rock(let roughness):
                    let variant = Int(c.pick * 4)
                    if rocks[variant] == nil {
                        let (g, uv) = TerrainScatter.rock(roughness: roughness, seed: rule.seed &* 10 &+ variant)
                        rocks[variant] = (addMesh(g, uvs: uv, label: "\(rule.name) rock"), rockMaterial)
                    }
                    addInstance(rocks[variant]!.mesh, rockMaterial, canonical)
                case .plant(let id):
                    guard let flora, let species = flora.catalog.species(id: id) else { continue }
                    let count = flora.plantCount(species)
                    guard count > 0 else { continue }
                    flora.place(species, min(Int(c.pick * Float(count)), count - 1), canonical, shade: c.shade)
                case .mesh(let name):
                    guard let k = instances.firstIndex(where: { $0.mesh >= 0 && meshLabels[$0.mesh]?.name == name }) else { continue }
                    addInstance(instances[k].mesh, instances[k].material, canonical)
                case .building(let style):
                    if buildings == nil { buildings = BuildingKit(self, textures: true) }
                    var spec = BuildingSpec(size: SIMD2(10 + 6 * c.pick, 9 + 5 * c.chance))
                    spec.def = BuildingCatalog.resolve(settings.buildingCatalog).style(id: style) ?? BuiltInBuildings.residential
                    spec.seed = UInt64(bitPattern: Int64(c.cell.x &* 92_821 ^ c.cell.y &* 68_917)) ^ UInt64(rule.seed)
                    spec.floors = 1 + Int(c.pick * 3)
                    buildings?.addBuilding(BuildingGenerator.generate(spec), at: canonical)
                }
                let made = Array(first..<instances.count)
                guard !made.isEmpty else { continue }
                let inverse = canonical.inverse
                sc.slots.append(SceneScatter.Slot(candidate: c, instances: made, relative: made.map { inverse * instances[$0].transform }))
                if placed == nil { hideScattered(made, at: canonical) }
            }
        }
        print("Terrain: \(sc.slots.count) scattered by \(doc.scatter.filter(\.enabled).count) rules, \(sc.anchors.count) things anchored")
    }

    /// Instances shrunk to nothing where they stand (a scatter rule's candidate left out).
    private func hideScattered(_ list: [Int], at place: float4x4) {
        let hidden = translate(SIMD3(place.columns.3.x, place.columns.3.y, place.columns.3.z)) * scale(1e-4)
        moveInstances(list.map { ($0, hidden) }, record: false)
    }

    /// The builder's things that stand on the ground (an instance of a mesh or a plant, small enough to stand on one
    /// place: its origin within a metre of the ground there, or its foot): they keep their height over it.
    private func anchorToTerrain(_ t: SceneTerrain, _ sc: SceneScatter, snapshot s: TerrainSnapshot) {
        let own = Set(t.parts.map(\.instance))
        for (i, inst) in instances.enumerated() where !own.contains(i) && inst.isStatic && inst.isGeometry && (inst.mesh >= 0 || inst.assembly >= 0) {
            let b = localBounds(of: inst)
            guard b.0.x <= b.1.x else { continue }
            let box = AABB(lo: b.0, hi: b.1).transformed(inst.transform)
            let size = box.hi - box.lo
            guard max(size.x, size.z) < 40 else { continue }
            let p = SIMD3(inst.transform.columns.3.x, inst.transform.columns.3.y, inst.transform.columns.3.z)
            let place = SIMD2(Double(p.x) + t.offset.x, Double(p.z) + t.offset.y)
            let ground = s.height(x: place.x, z: place.y)
            guard abs(p.y - ground) < 1 || abs(box.lo.y - ground) < 1 else { continue }
            sc.anchors.append(SceneScatter.Anchor(instance: i, place: place, lift: p.y - ground, transform: inst.transform))
        }
    }

    /// After the terrain changed in the world's square `lo`...`hi` (x, z): its scatter rules' things there placed
    /// again (shown, hidden or moved), what stands on it moved up or down with it. The instances that moved.
    @discardableResult
    package func rescatter(lo: SIMD2<Double>, hi: SIMD2<Double>) -> Int {
        guard let t = terrain, let sc = t.scatter else { return 0 }
        let s = t.field.snapshot()
        var moves: [(Int, float4x4)] = []
        func inside(_ x: Double, _ z: Double) -> Bool { x >= lo.x && x <= hi.x && z >= lo.y && z <= hi.y }
        for slot in sc.slots where inside(slot.candidate.x, slot.candidate.z) {
            let c = slot.candidate, rule = sc.rules[c.rule]
            if let placed = TerrainScatter.placement(c, rule: rule, snapshot: s, layers: sc.layers, water: sc.water) {
                let canonical = TerrainScatter.transform(c, rule: rule, position: placed.position, normal: placed.normal, offset: t.offset)
                for (k, i) in slot.instances.enumerated() { moves.append((i, canonical * slot.relative[k])) }
            } else {
                let ground = SIMD3<Float>(Float(c.x - t.offset.x), s.height(x: c.x, z: c.z), Float(c.z - t.offset.y))
                for i in slot.instances { moves.append((i, translate(ground) * scale(1e-4))) }
            }
        }
        for a in sc.anchors where inside(a.place.x, a.place.y) {
            var m = a.transform
            m.columns.3.y = s.height(x: a.place.x, z: a.place.y) + a.lift
            moves.append((a.instance, m))
        }
        moveInstances(moves, record: true)
        return moves.count
    }
}
