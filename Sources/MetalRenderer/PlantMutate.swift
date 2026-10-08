import Foundation

/// Variations of a species for the plant editor's Mutate: each one the species with a few of its numbers moved a
/// little (PlantParams' `mutation` shares), at random but the same for the same seed. Shown side by side in the
/// workshop (its layout `mutate`); the one picked replaces the species' shape.
enum PlantMutate {
    /// `count` variations of `def`, ids "<id>~1"... (they grow from its seeds, so only the numbers differ).
    static func mutants(of def: Foliage.SpeciesDef, count: Int = 6, seed: UInt64) -> [Foliage.SpeciesDef] {
        (1...max(count, 1)).map { k in
            var rng = SplitMix64(seed: seed &+ UInt64(k) &* 0x9E37_79B9_7F4A_7C15)
            var m = def
            m.id = "\(def.id)~\(k)"
            m.name = "\(def.name) \(k)"
            let changes = 3 + rng.int(4)
            for _ in 0..<changes { mutate(&m, &rng) }
            return m.sanitized()
        }
    }

    /// The parts of a definition a mutation may change, with their weights.
    private static func mutate(_ m: inout Foliage.SpeciesDef, _ rng: inout SplitMix64) {
        var targets: [(Int, (inout Foliage.SpeciesDef, inout SplitMix64) -> Void)] = []
        let levels = m.recipe.levels.count
        targets.append((2, { d, r in move(&d.recipe.levels[0], PlantParams.trunk, &r) }))
        if levels > 1 {
            targets.append((5, { d, r in
                let l = 1 + r.int(d.recipe.levels.count - 1)
                move(&d.recipe.levels[l], PlantParams.level, &r)
            }))
        }
        targets.append((2, { d, r in move(&d.recipe, PlantParams.recipe, &r) }))
        if m.recipe.leaf != nil { targets.append((3, { d, r in move(&d.recipe.leaf!, PlantParams.leaf, &r) })) }
        if m.recipe.graft != nil { targets.append((3, { d, r in move(&d.recipe.graft!, PlantParams.graft, &r) })) }
        if let bough = m.bough {
            targets.append((3, { d, r in
                let l = r.int(bough.levels.count)
                move(&d.bough!.levels[l], l == 0 ? PlantParams.trunk : PlantParams.level, &r)
            }))
            if bough.leaf != nil { targets.append((3, { d, r in move(&d.bough!.leaf!, PlantParams.leaf, &r) })) }
        }
        let total = targets.reduce(0) { $0 + $1.0 }
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

    /// `def` shaped as `mutant`: its recipes, palette and ages; still itself (its id, name, seeds, look, habitat).
    static func pick(_ mutant: Foliage.SpeciesDef, into def: Foliage.SpeciesDef) -> Foliage.SpeciesDef {
        var d = def
        d.recipe = mutant.recipe
        d.bough = mutant.bough
        d.palette = mutant.palette
        d.ages = mutant.ages
        return d
    }
}
