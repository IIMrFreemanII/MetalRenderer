import Foundation
import simd

/// The species' recipes: what the grower, the foliage distributor and the graft distributor are told for each
/// plant, at each age, and for the boughs of its palette. Lengths are metres, angles radians.
extension Foliage {
    /// Bough meshes per species: every tree of the species hangs these few on its limbs, turned and scaled.
    static func paletteSize(_ species: Species) -> Int { species.hasBoughs ? 6 : 0 }

    /// Seeded variants of a species at an age.
    static func variants(_ species: Species, _ age: Age) -> Int {
        switch (species, age) {
        case (.oak, .mature), (.birch, .mature), (.conifer, .mature): return 3
        case (.oak, _), (.birch, _), (.conifer, _): return 2
        case (.dead, .mature): return 2
        case (.dead, .young): return 1
        case (.bush, .mature): return 3
        case (.bush, .young): return 2
        case (.fern, .mature): return 3
        case (.grass, .mature): return 6
        default: return 0
        }
    }

    static func recipe(_ species: Species, age: Age) -> Recipe {
        var r: Recipe
        switch species {
        case .oak:
            r = Recipe(levels: [
                Level(count: 1, length: 13, lengthV: 0.12, downAngleV: 0.05, curveV: 0.35, segments: 10, radial: 10, taper: 0.85),
                Level(count: 14, length: 0.42, lengthV: 0.15, downAngle: 1.15, downAngleEnd: 0.45, downAngleV: 0.15, start: 0.28,
                      curve: 0.5, curveV: 0.7, segments: 6, radial: 6, taper: 0.85),
                Level(count: 5, length: 0.5, lengthV: 0.2, downAngle: 0.85, downAngleV: 0.25, start: 0.25, curve: 0.2, curveV: 0.8,
                      segments: 4, radial: 4, taper: 0.9)],
                       ratio: 0.033, ratioPower: 1.15, flare: 0.6, crown: .hemispherical,
                       graft: Graft(spacing: 0.5, start: 0.55, lastStart: 0.2, angle: 0.75, scale: 0.85...1.25, droop: 0.1))
        case .birch:
            r = Recipe(levels: [
                Level(count: 1, length: 15, lengthV: 0.1, downAngleV: 0.04, curveV: 0.25, segments: 12, radial: 8, taper: 0.9),
                Level(count: 20, length: 0.3, lengthV: 0.15, downAngle: 0.95, downAngleEnd: 0.5, downAngleV: 0.12, start: 0.3,
                      curve: 0.3, curveV: 0.5, segments: 6, radial: 5, taper: 0.9),
                Level(count: 4, length: 0.55, lengthV: 0.2, downAngle: 0.9, downAngleV: 0.2, start: 0.3, curve: -0.9, curveV: 0.5,
                      tropism: -0.4, segments: 5, radial: 3, taper: 0.9)],
                       ratio: 0.02, ratioPower: 1.2, flare: 0.3, crown: .flame,
                       graft: Graft(spacing: 0.45, start: 0.5, lastStart: 0.2, angle: 0.9, scale: 0.7...1.1, droop: 0.5))
        case .conifer:
            r = Recipe(levels: [
                Level(count: 1, length: 18, lengthV: 0.12, downAngleV: 0.02, curveV: 0.08, segments: 12, radial: 8, taper: 0.95),
                Level(count: 40, length: 0.28, lengthV: 0.12, downAngle: 1.75, downAngleEnd: 1.0, downAngleV: 0.1, start: 0.12,
                      curve: 0.45, curveV: 0.25, segments: 5, radial: 4, taper: 0.9)],
                       ratio: 0.02, ratioPower: 1.2, flare: 0.4, crown: .conical,
                       graft: Graft(spacing: 0.38, lastStart: 0.12, angle: 1.0, angleV: 0.15, rotate: .pi, scale: 0.8...1.15, droop: 0.25))
        case .dead:
            r = Recipe(levels: [
                Level(count: 1, length: 9, lengthV: 0.2, downAngleV: 0.12, curveV: 0.5, segments: 9, radial: 9, taper: 0.6),
                Level(count: 7, length: 0.4, lengthV: 0.3, downAngle: 1.0, downAngleV: 0.3, start: 0.35, curve: 0.3, curveV: 1.0,
                      segments: 5, radial: 5, taper: 0.95),
                Level(count: 3, length: 0.5, lengthV: 0.3, downAngle: 0.8, downAngleV: 0.3, start: 0.3, curveV: 1.0, segments: 4, radial: 3),
                Level(count: 3, length: 0.5, lengthV: 0.3, downAngle: 0.8, downAngleV: 0.3, start: 0.3, curveV: 1.0, segments: 3, radial: 3)],
                       ratio: 0.035, ratioPower: 1.3, flare: 0.5, crown: .cylindrical)
        case .bush:
            // Several stems from the ground, pruned to a rounded shape.
            r = Recipe(levels: [
                Level(count: 6, length: 1.5, lengthV: 0.25, downAngle: 0.5, downAngleV: 0.25, curve: 0.3, curveV: 0.6, segments: 5,
                      radial: 4, taper: 0.9),
                Level(count: 4, length: 0.5, lengthV: 0.2, downAngle: 0.8, downAngleV: 0.25, start: 0.3, curveV: 0.6, segments: 3, radial: 3)],
                       ratio: 0.018, flare: 0, spread: 0.15,
                       carve: Carve(center: [0, 0.8, 0], radii: [1.25, 1.1, 1.25], fromLevel: 0),
                       graft: Graft(spacing: 0.32, start: 0.35, lastStart: 0.2, angle: 0.8, scale: 0.45...0.7, droop: 0.05))
        case .fern:
            // Arching fronds from one point: ribbons with pinnae either side, shrinking to the tip.
            r = Recipe(levels: [
                Level(count: 9, length: 0.75, lengthV: 0.25, downAngle: 0.75, downAngleV: 0.25, curve: -1.3, curveV: 0.3, segments: 7,
                      radial: 1, taper: 0.7)],
                       ratio: 0.006, flare: 0, spread: 0.04,
                       leaf: LeafRecipe(shape: .kite, length: 0.13, width: 0.035, sizeV: 0.1, perMetre: 60, start: 0.12, angle: 1.3,
                                        angleV: 0.1, phyllotaxis: .distichous, fold: 0.05, tipScale: 0.12, flutter: 0.15))
        case .grass:
            r = Recipe(levels: [Level()])   // grass is patches of blades (grassPatch), not grown
        }

        switch age {
        case .mature: break
        case .young:
            r.levels[0].length *= 0.58
            if r.levels.count > 1 { r.levels[1].count = max(3, r.levels[1].count * 3 / 4) }
            if r.levels.count > 2 { r.levels[2].count = max(2, r.levels[2].count * 7 / 10) }
            if let boughs = r.graft?.scale { r.graft?.scale = scaled(boughs, 0.9) }
            if species == .bush { r.carve = Carve(center: [0, 0.5, 0], radii: [0.8, 0.7, 0.8], fromLevel: 0) }
        case .sapling:
            r.levels[0].length *= 0.24
            r.levels[0].segments = 6
            r.levels[0].radial = 6
            r.levels = Array(r.levels.prefix(2))
            if r.levels.count > 1 {
                r.levels[1].count = max(3, r.levels[1].count * 9 / 20)
                r.levels[1].radial = 4
            }
            r.ratio *= 0.8
            if let boughs = r.graft?.scale { r.graft?.scale = scaled(boughs, 0.7) }
        }
        return r
    }

    private static func scaled(_ r: ClosedRange<Float>, _ s: Float) -> ClosedRange<Float> { r.lowerBound * s...r.upperBound * s }

    /// A bough of the species' palette: grown lying along +Y with +Z toward the sky, about a metre long. The graft
    /// distributor scales it, so its leaves shrink with it.
    static func boughRecipe(_ species: Species, variant: Int) -> Recipe {
        let long: Float = variant % 2 == 0 ? 1 : 0.8   // the palette has longer and shorter boughs
        var r: Recipe
        switch species {
        case .birch:
            // Thin, hanging twigs with small leaves.
            r = Recipe(levels: [
                Level(count: 1, length: 1.1 * long, lengthV: 0.15, downAngleV: 0.1, curve: -0.8, curveV: 0.4, tropism: -0.5, segments: 6,
                      radial: 3, taper: 0.9),
                Level(count: 7, length: 0.4, lengthV: 0.25, downAngle: 0.8, downAngleV: 0.3, start: 0.1, curve: -0.6, curveV: 0.5,
                      tropism: -0.6, segments: 4, radial: 1, taper: 0.8)],
                       ratio: 0.009, flare: 0,
                       leaf: LeafRecipe(shape: .kite, length: 0.075, width: 0.055, perMetre: 46, angle: 1.0, fold: 0.12, flutter: 0.8))
        case .conifer:
            // A flat spray: side twigs to the left and right, needles all round them.
            r = Recipe(levels: [
                Level(count: 1, length: 1.3 * long, lengthV: 0.1, downAngleV: 0.05, curve: -0.3, curveV: 0.15, segments: 6, radial: 3, taper: 0.9),
                Level(count: 14, length: 0.42, lengthV: 0.2, downAngle: 0.95, downAngleV: 0.1, rotate: .pi, rotateV: 0, start: 0.08,
                      curve: -0.15, curveV: 0.15, segments: 3, radial: 1, taper: 0.8)],
                       ratio: 0.011, flare: 0,
                       leaf: LeafRecipe(shape: .needle, length: 0.07, width: 0.016, sizeV: 0.2, perMetre: 130, start: 0.05, angle: 1.0,
                                        angleV: 0.25, fold: 0, flutter: 0.5))
        case .bush:
            r = Recipe(levels: [
                Level(count: 1, length: 1.0 * long, lengthV: 0.15, downAngleV: 0.15, curve: 0.2, curveV: 0.5, segments: 5, radial: 3, taper: 0.9),
                Level(count: 8, length: 0.45, lengthV: 0.25, downAngle: 0.85, downAngleV: 0.3, start: 0.1, curveV: 0.6, segments: 3,
                      radial: 1, taper: 0.8)],
                       ratio: 0.012, flare: 0,
                       leaf: LeafRecipe(shape: .kite, length: 0.11, width: 0.075, perMetre: 48, angle: 0.9, fold: 0.15, flutter: 0.7))
        default:
            // Oak: broad leaves on twigs spreading roughly in one plane.
            r = Recipe(levels: [
                Level(count: 1, length: 1.2 * long, lengthV: 0.15, downAngleV: 0.1, curve: -0.25, curveV: 0.4, segments: 5, radial: 4, taper: 0.9),
                Level(count: 9, length: 0.42, lengthV: 0.25, downAngle: 0.9, downAngleV: 0.3, rotate: .pi, rotateV: 0.5, start: 0.12,
                      curve: 0.2, curveV: 0.6, segments: 3, radial: 3, taper: 0.85)],
                       ratio: 0.012, flare: 0,
                       leaf: LeafRecipe(shape: .blade, length: 0.13, width: 0.085, perMetre: 40, angle: 0.9, fold: 0.12, flutter: 0.6))
        }
        r.up = [0, 0, 1]
        return r
    }
}
