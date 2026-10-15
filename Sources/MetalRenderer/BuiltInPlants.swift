import Foundation
import simd

/// The built-in species: what the grower, the foliage distributor and the graft distributor are told for each plant,
/// at each age, and for the boughs of its palette; their colours. Lengths are metres, angles radians.
extension Foliage {
    static let builtInSpecies: [SpeciesDef] = [oakDef, birchDef, coniferDef, deadDef, bushDef, fernDef, grassDef]

    /// How the built-in trees age: a young tree at 58% of the height, three quarters of the limbs; a sapling at 24%,
    /// two levels, less than half the limbs, on a thicker trunk mesh.
    private static let young = AgeRule(trunkLength: 0.58, counts: [CountRule(level: 1, factor: 0.75, minimum: 3),
                                                                   CountRule(level: 2, factor: 0.7, minimum: 2)], boughScale: 0.9)
    private static let sapling = AgeRule(trunkLength: 0.24, counts: [CountRule(level: 1, factor: 0.45, minimum: 3)], maxLevels: 2,
                                         trunkSegments: 6, trunkRadial: 6, limbRadial: 4, ratio: 0.8, boughScale: 0.7)

    private static func bough(_ levels: [Level], ratio: Float, leaf: LeafRecipe) -> Recipe {
        Recipe(levels: levels, ratio: ratio, flare: 0, up: [0, 0, 1], leaf: leaf)
    }

    private static let oakDef = SpeciesDef(
        id: "oak", name: "Oak", seedIndex: 0, role: .tree,
        recipe: Recipe(levels: [
            Level(count: 1, length: 13, lengthV: 0.12, downAngleV: 0.05, curveV: 0.35, segments: 10, radial: 10, taper: 0.85),
            Level(count: 14, length: 0.42, lengthV: 0.15, downAngle: 1.15, downAngleEnd: 0.45, downAngleV: 0.15, start: 0.28,
                  curve: 0.5, curveV: 0.7, segments: 6, radial: 6, taper: 0.85),
            Level(count: 5, length: 0.5, lengthV: 0.2, downAngle: 0.85, downAngleV: 0.25, start: 0.25, curve: 0.2, curveV: 0.8,
                  segments: 4, radial: 4, taper: 0.9)],
                       ratio: 0.033, ratioPower: 1.15, flare: 0.6, crown: .hemispherical,
                       graft: Graft(spacing: 0.5, start: 0.55, lastStart: 0.2, angle: 0.75, scale: 0.85...1.25, droop: 0.1)),
        // Broad leaves on twigs spreading roughly in one plane.
        bough: bough([
            Level(count: 1, length: 1.2, lengthV: 0.15, downAngleV: 0.1, curve: -0.25, curveV: 0.4, segments: 5, radial: 4, taper: 0.9),
            Level(count: 9, length: 0.42, lengthV: 0.25, downAngle: 0.9, downAngleV: 0.3, rotate: .pi, rotateV: 0.5, start: 0.12,
                  curve: 0.2, curveV: 0.6, segments: 3, radial: 3, taper: 0.85)],
                     ratio: 0.012, leaf: LeafRecipe(shape: .blade, length: 0.13, width: 0.085, perMetre: 40, angle: 0.9, fold: 0.12, flutter: 0.6)),
        ages: Ages(young: young, sapling: sapling, variants: [2, 2, 3]),
        look: Look(bark: [0.2, 0.15, 0.11], leaves: [[0.11, 0.22, 0.05], [0.14, 0.25, 0.06], [0.09, 0.19, 0.05], [0.16, 0.24, 0.05]],
                   autumn: [0.3, 0.14, 0.035]),
        habitat: Habitat(order: 1, base: 0.9, elevation: .init(gain: -0.7, from: 0, to: 0.7), stand: -1.6))

    private static let birchDef = SpeciesDef(
        id: "birch", name: "Birch", seedIndex: 1, role: .tree,
        recipe: Recipe(levels: [
            Level(count: 1, length: 15, lengthV: 0.1, downAngleV: 0.04, curveV: 0.25, segments: 12, radial: 8, taper: 0.9),
            Level(count: 20, length: 0.3, lengthV: 0.15, downAngle: 0.95, downAngleEnd: 0.5, downAngleV: 0.12, start: 0.3,
                  curve: 0.3, curveV: 0.5, segments: 6, radial: 5, taper: 0.9),
            Level(count: 4, length: 0.55, lengthV: 0.2, downAngle: 0.9, downAngleV: 0.2, start: 0.3, curve: -0.9, curveV: 0.5,
                  tropism: -0.4, segments: 5, radial: 3, taper: 0.9)],
                       ratio: 0.02, ratioPower: 1.2, flare: 0.3, crown: .flame,
                       graft: Graft(spacing: 0.45, start: 0.5, lastStart: 0.2, angle: 0.9, scale: 0.7...1.1, droop: 0.5)),
        // Thin, hanging twigs with small leaves.
        bough: bough([
            Level(count: 1, length: 1.1, lengthV: 0.15, downAngleV: 0.1, curve: -0.8, curveV: 0.4, tropism: -0.5, segments: 6,
                  radial: 3, taper: 0.9),
            Level(count: 7, length: 0.4, lengthV: 0.25, downAngle: 0.8, downAngleV: 0.3, start: 0.1, curve: -0.6, curveV: 0.5,
                  tropism: -0.6, segments: 4, radial: 1, taper: 0.8)],
                     ratio: 0.009, leaf: LeafRecipe(shape: .kite, length: 0.075, width: 0.055, perMetre: 46, angle: 1.0, fold: 0.12, flutter: 0.8)),
        ages: Ages(young: young, sapling: sapling, variants: [2, 2, 3]),
        look: Look(bark: [0.72, 0.7, 0.65], leaves: [[0.19, 0.31, 0.07], [0.23, 0.34, 0.08], [0.16, 0.28, 0.07]],
                   autumn: [0.42, 0.33, 0.04], barkTexture: .birchBark),
        habitat: Habitat(order: 2, base: 0.25, light: 1))

    private static let coniferDef = SpeciesDef(
        id: "conifer", name: "Conifer", seedIndex: 2, role: .tree,
        recipe: Recipe(levels: [
            Level(count: 1, length: 18, lengthV: 0.12, downAngleV: 0.02, curveV: 0.08, segments: 12, radial: 8, taper: 0.95),
            Level(count: 40, length: 0.28, lengthV: 0.12, downAngle: 1.75, downAngleEnd: 1.0, downAngleV: 0.1, start: 0.12,
                  curve: 0.45, curveV: 0.25, segments: 5, radial: 4, taper: 0.9)],
                       ratio: 0.02, ratioPower: 1.2, flare: 0.4, crown: .conical,
                       graft: Graft(spacing: 0.38, lastStart: 0.12, angle: 1.0, angleV: 0.15, rotate: .pi, scale: 0.8...1.15, droop: 0.25)),
        // A flat spray: side twigs to the left and right, needles all round them.
        bough: bough([
            Level(count: 1, length: 1.3, lengthV: 0.1, downAngleV: 0.05, curve: -0.3, curveV: 0.15, segments: 6, radial: 3, taper: 0.9),
            Level(count: 14, length: 0.42, lengthV: 0.2, downAngle: 0.95, downAngleV: 0.1, rotate: .pi, rotateV: 0, start: 0.08,
                  curve: -0.15, curveV: 0.15, segments: 3, radial: 1, taper: 0.8)],
                     ratio: 0.011, leaf: LeafRecipe(shape: .needle, length: 0.07, width: 0.016, sizeV: 0.2, perMetre: 130, start: 0.05,
                                                    angle: 1.0, angleV: 0.25, fold: 0, flutter: 0.5)),
        ages: Ages(young: young, sapling: sapling, variants: [2, 2, 3]),
        look: Look(bark: [0.19, 0.13, 0.09], leaves: [[0.045, 0.11, 0.055], [0.055, 0.13, 0.06], [0.04, 0.1, 0.06]],
                   translucency: 0.12, leafTexture: .needle, evergreen: true),
        habitat: Habitat(order: 0, base: 0.3, elevation: .init(gain: 1.1, from: -0.1, to: 0.7), slope: 3, stand: 1.6))

    private static let deadDef = SpeciesDef(
        id: "dead", name: "Dead tree", seedIndex: 3, role: .tree,
        recipe: Recipe(levels: [
            Level(count: 1, length: 9, lengthV: 0.2, downAngleV: 0.12, curveV: 0.5, segments: 9, radial: 9, taper: 0.6),
            Level(count: 7, length: 0.4, lengthV: 0.3, downAngle: 1.0, downAngleV: 0.3, start: 0.35, curve: 0.3, curveV: 1.0,
                  segments: 5, radial: 5, taper: 0.95),
            Level(count: 3, length: 0.5, lengthV: 0.3, downAngle: 0.8, downAngleV: 0.3, start: 0.3, curveV: 1.0, segments: 4, radial: 3),
            Level(count: 3, length: 0.5, lengthV: 0.3, downAngle: 0.8, downAngleV: 0.3, start: 0.3, curveV: 1.0, segments: 3, radial: 3)],
                       ratio: 0.035, ratioPower: 1.3, flare: 0.5, crown: .cylindrical),
        ages: Ages(young: young, sapling: sapling, variants: [0, 1, 2]),
        look: Look(bark: [0.36, 0.33, 0.29], leaves: [[0.3, 0.27, 0.2]], translucency: 0),
        habitat: Habitat(order: 3, share: 0.035))

    /// Several stems from the ground, pruned to a rounded shape.
    private static let bushDef = SpeciesDef(
        id: "bush", name: "Bush", seedIndex: 4, role: .bush,
        recipe: Recipe(levels: [
            Level(count: 6, length: 1.5, lengthV: 0.25, downAngle: 0.5, downAngleV: 0.25, curve: 0.3, curveV: 0.6, segments: 5,
                  radial: 4, taper: 0.9),
            Level(count: 4, length: 0.5, lengthV: 0.2, downAngle: 0.8, downAngleV: 0.25, start: 0.3, curveV: 0.6, segments: 3, radial: 3)],
                       ratio: 0.018, flare: 0, spread: 0.15,
                       carve: Carve(center: [0, 0.8, 0], radii: [1.25, 1.1, 1.25], fromLevel: 0),
                       graft: Graft(spacing: 0.32, start: 0.35, lastStart: 0.2, angle: 0.8, scale: 0.45...0.7, droop: 0.05)),
        bough: bough([
            Level(count: 1, length: 1.0, lengthV: 0.15, downAngleV: 0.15, curve: 0.2, curveV: 0.5, segments: 5, radial: 3, taper: 0.9),
            Level(count: 8, length: 0.45, lengthV: 0.25, downAngle: 0.85, downAngleV: 0.3, start: 0.1, curveV: 0.6, segments: 3,
                  radial: 1, taper: 0.8)],
                     ratio: 0.012, leaf: LeafRecipe(shape: .kite, length: 0.11, width: 0.075, perMetre: 48, angle: 0.9, fold: 0.15, flutter: 0.7)),
        ages: Ages(young: { var r = young; r.carve = Carve(center: [0, 0.5, 0], radii: [0.8, 0.7, 0.8], fromLevel: 0); return r }(),
                   sapling: sapling, variants: [0, 2, 3]),
        look: Look(bark: [0.22, 0.16, 0.11], leaves: [[0.12, 0.24, 0.07], [0.1, 0.2, 0.06], [0.15, 0.25, 0.06]], autumn: [0.36, 0.09, 0.04]),
        habitat: Habitat(order: 10, cover: .init(count: 2600, cell: 6.1, patch: 28, salt: 31, what: 0xB05, size: 0.8...1.3, sink: 0.05)))

    /// Arching fronds from one point: ribbons with pinnae either side, shrinking to the tip.
    private static let fernDef = SpeciesDef(
        id: "fern", name: "Fern", seedIndex: 5, role: .groundCover,
        recipe: Recipe(levels: [
            Level(count: 9, length: 0.75, lengthV: 0.25, downAngle: 0.75, downAngleV: 0.25, curve: -1.3, curveV: 0.3, segments: 7,
                  radial: 1, taper: 0.7)],
                       ratio: 0.006, flare: 0, spread: 0.04,
                       leaf: LeafRecipe(shape: .kite, length: 0.13, width: 0.035, sizeV: 0.1, perMetre: 60, start: 0.12, angle: 1.3,
                                        angleV: 0.1, phyllotaxis: .distichous, fold: 0.05, tipScale: 0.12, flutter: 0.15)),
        ages: Ages(young: young, sapling: sapling, variants: [0, 0, 3]),
        look: Look(bark: [0.22, 0.16, 0.11], leaves: [[0.13, 0.28, 0.07], [0.16, 0.3, 0.08]], autumn: [0.27, 0.17, 0.06]),
        habitat: Habitat(order: 11, cover: .init(count: 6000, cell: 4, patch: 17, salt: 47, what: 0xFE2, size: 0.9...1.7, sink: 0.02)),
        stemsAreLeaves: true)

    /// Patches of blades (grassPatch), not grown.
    private static let grassDef = SpeciesDef(
        id: "grass", name: "Grass", seedIndex: 6, role: .groundCover, grass: GrassPatch(),
        recipe: Recipe(levels: [Level()]),
        ages: Ages(young: young, sapling: sapling, variants: [0, 0, 6]),
        look: Look(bark: [0.22, 0.16, 0.11], leaves: [[0.19, 0.32, 0.09], [0.23, 0.34, 0.1], [0.27, 0.33, 0.12]],
                   autumn: [0.3, 0.27, 0.11], translucency: 0.3, leafTexture: .grass),
        habitat: Habitat(order: 12, cover: .init(count: 0, cell: 2, patch: 20, what: 0x62A, size: 1.05...1.2, sink: 0, open: true, grid: 2)))
}
