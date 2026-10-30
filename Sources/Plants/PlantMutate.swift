import EngineCore
import Foundation

/// Variations of a species for the plant editor's Mutate: each one the species with a few of its numbers moved a
/// little (PlantParams' `mutation` shares), at random but the same for the same seed. Shown side by side in the
/// workshop (its layout `mutate`); the one picked replaces the species' shape.
package enum PlantMutate {
    /// `count` variations of `def`, ids "<id>~1"... (they grow from its seeds, so only the numbers differ).
    package static func mutants(of def: Foliage.SpeciesDef, count: Int = 6, seed: UInt64) -> [Foliage.SpeciesDef] {
        (1...max(count, 1)).map { k in
            var rng = SplitMix64(seed: seed &+ UInt64(k) &* 0x9E37_79B9_7F4A_7C15)
            var m = def
            m.id = "\(def.id)~\(k)"
            m.name = "\(def.name) \(k)"
            let changes = 3 + rng.int(4)
            for _ in 0..<changes { mutate(&m, &rng) }
            m = m.sanitized()
            if let graph = m.graph { m.setGraph(graph.applying(m)) }
            return m
        }
    }

    /// The parts of a definition a mutation may change, with their weights: a grown species' growth, shoots, light,
    /// wood and twigs; the leaves on its own stems; a grass patch's blades.
    private static func mutate(_ m: inout Foliage.SpeciesDef, _ rng: inout SplitMix64) {
        var targets: [(Int, (inout Foliage.SpeciesDef, inout SplitMix64) -> Void)] = []
        if let g = m.growth {
            targets.append((2, { d, r in move(&d.growth!, PlantParams.growth, &r) }))
            targets.append((2, { d, r in move(&d.growth!, PlantParams.hormones, &r) }))
            targets.append((3, { d, r in move(&d.growth!.trunk, PlantParams.shoot, &r) }))
            if g.branch != nil { targets.append((4, { d, r in move(&d.growth!.branch!, PlantParams.shoot, &r) })) }
            targets.append((1, { d, r in move(&d.growth!.light, PlantParams.light, &r) }))
            if g.senescence != nil { targets.append((1, { d, r in move(&d.growth!.senescence!, PlantParams.senescence, &r) })) }
            if g.bifurcation != nil { targets.append((1, { d, r in move(&d.growth!.bifurcation!, PlantParams.bifurcation, &r) })) }
            if g.gravity > 0 { targets.append((1, { d, r in move(&d.growth!, PlantParams.gravity, &r) })) }
            targets.append((1, { d, r in move(&d.growth!.wood, PlantParams.wood, &r) }))
        }
        if m.twigs != nil {
            targets.append((3, { d, r in move(&d.twigs!, PlantParams.twigs, &r) }))
            targets.append((3, { d, r in move(&d.twigs!.leaf, PlantParams.leaf, &r) }))
            targets.append((2, { d, r in move(&d.twigs!.growth.trunk, PlantParams.shoot, &r) }))
        }
        if m.leaf != nil { targets.append((3, { d, r in move(&d.leaf!, PlantParams.leaf, &r) })) }
        if m.grass != nil { targets.append((1, { d, r in move(&d.grass!, PlantParams.grass, &r) })) }
        let total = targets.reduce(0) { $0 + $1.0 }
        guard total > 0 else { return }
        var pick = rng.int(total)
        for (weight, change) in targets {
            if pick < weight { change(&m, &rng); return }
            pick -= weight
        }
    }

    /// One of the table's numbers that mutate, moved by up to its share of the range either way.
    private static func move<Root>(_ root: inout Root, _ table: [PlantParam<Root>], _ rng: inout SplitMix64) {
        let mutable = table.filter { $0.mutation > 0 }
        guard !mutable.isEmpty else { return }
        let p = mutable[rng.int(mutable.count)]
        let span = (p.range.upperBound - p.range.lowerBound) * p.mutation
        var delta = Double(rng.range(-1, 1)) * span
        if p.isInteger { delta = delta.rounded(); if delta == 0 { delta = rng.int(2) == 0 ? -1 : 1 } }
        p.set(&root, p.clamp(p.get(root) + delta))
    }

    /// `def` shaped as `mutant`: its growth, twigs, leaves and ages; still itself (its id, name, seeds, look, habitat).
    package static func pick(_ mutant: Foliage.SpeciesDef, into def: Foliage.SpeciesDef) -> Foliage.SpeciesDef {
        var d = def
        d.growth = mutant.growth
        d.twigs = mutant.twigs
        d.leaf = mutant.leaf
        d.grass = mutant.grass
        d.ages = mutant.ages
        d.graph = mutant.graph
        return d
    }
}
