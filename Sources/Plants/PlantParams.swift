import EngineCore
import Foundation

/// The plant editor's numbers (and Mutate's, PlantMutate.swift), by what they belong to: a grown species' growth
/// (Growth.Params), its trunk's and branches' shoots, its light, senescence and forks, its wood, its twigs.
package enum PlantParams {
    private static let pi = Double.pi

    /// The plant as a whole: how long it grows and toward what height, from how many stems.
    package static let growth: [PlantParam<Growth.Params>] = [
        .int("Cycles", \.cycles, 2...90, mutation: 0.06),
        .float("Height", \.targetHeight, 0.2...40, digits: 2, unit: "m", mutation: 0.08),
        .int("Generations", \.maxGeneration, 1...6, mutation: 0),
        .int("Stems", \.stems, 1...24, mutation: 0.05),
        .float("Stem spread", \.stemSpread, 0...1.5),
        .float("Seed radius", \.seedRadius, 0.0005...0.05, digits: 4, unit: "m", mutation: 0),
        .float("Radius growth", \.radiusGrowth, 0...0.03, digits: 4, unit: "m", mutation: 0.08),
    ]

    /// Its hormones: the tips' hold over the buds below them, and how wood ages.
    package static let hormones: [PlantParam<Growth.Params>] = [
        .float("Apical dominance", \.apicalDominance, 0...1),
        .float("Auxin falloff", \.auxinFalloff, 0...1),
        .float("Ethylene build-up", \.ethyleneBuildup, 0...0.5, digits: 3),
    ]

    package static let gravity: [PlantParam<Growth.Params>] = [
        .float("Gravity", \.gravity, 0...2),
    ]

    /// An axis's growth: the trunk's, or every branch's.
    package static let shoot: [PlantParam<Growth.Shoot>] = [
        .float("Internode", \.segment, 0.01...1.5, digits: 3, unit: "m", mutation: 0.06),
        .float("Internode scale", \.lengthScale, 0.2...2),
        .float("Tip growth", \.apicalGrowth, 0...1),
        .float("Bud growth", \.axillaryGrowth, 0...1),
        .float("Axil angle", \.axilAngle, 0...pi),
        .float("Random turn", \.randomAngle, 0...0.6),
        .float("Flatten", \.flatten, 0...1),
        .float("Phototropism", \.phototropism, 0...1),
        .float("Gravitropism", \.gravitropism, -0.5...0.5, digits: 3),
    ]

    package static let light: [PlantParam<Growth.Light>] = [
        .float("Light needed", \.requirement, 0...0.8),
        .float("Shade shortens", \.lengthImpact, 0...1),
        .float("Shadow", \.shadow, 0.2...10),
        .float("Leaf shadow", \.leafDensity, 0...6),
    ]

    package static let senescence: [PlantParam<Growth.Senescence>] = [
        .float("Shed below light", \.threshold, 0...0.8),
        .int("For cycles", \.cycles, 1...20),
        .int("From generation", \.fromGeneration, 1...6, mutation: 0),
    ]

    package static let bifurcation: [PlantParam<Growth.Bifurcation>] = [
        .float("Chance", \.chance, 0...1),
        .float("Fork angle", \.angle, 0...1.5),
        .int("Forks", \.count, 2...4, mutation: 0),
        .int("Ripens in", \.cycles, 1...12),
    ]

    /// The mesher's: thinning by generation, the axes' wander, the trunk's foot.
    package static let wood: [PlantParam<Growth.Wood>] = [
        .float("Thinning", \.thinning, 0.3...1),
        .float("Wander", \.noise, 0...0.3, digits: 3, unit: "m"),
        .float("Wander waves", \.noiseScale, 0.1...4),
        .float("Flare", \.flare, 0...2),
        .float("Flare height", \.flareHeight, 0.1...5, unit: "m"),
        .int("Buttresses", \.lobes, 0...12, mutation: 0),
        .float("Buttress depth", \.lobeDepth, 0...0.6),
    ]

    /// Where the twigs hang and how many kinds of them there are.
    package static let twigs: [PlantParam<Growth.Twigs>] = [
        .int("Kinds", \.palette, 1...12, mutation: 0),
        .float("Spacing", \.spacing, 0.04...1.5, digits: 3, unit: "m"),
        .float("Young wood below", \.ethylene, 0...1),
        .int("From generation", \.fromGeneration, 1...6, mutation: 0),
        .float("Size", \.scale, 0.1...3),
        .float("Size variation", \.scaleV, 0...0.8),
        .float("Angle", \.angle, 0...pi),
        .float("Toward the light", \.lightAim, 0...1),
    ]

    /// A younger age, of the mature plant.
    package static let age: [PlantParam<Growth.AgeShare>] = [
        .float("Cycles", \.cycles, 0.05...1, mutation: 0),
        .float("Height", \.height, 0.05...1, mutation: 0),
    ]

    package static let grass: [PlantParam<Foliage.GrassPatch>] = [
        .float("Size", \.size, 0.5...6, digits: 1, unit: "m"),
        .int("Blades", \.blades, 50...3000),
    ]

    package static let leaf: [PlantParam<Foliage.LeafRecipe>] = [
        .float("Length", \.length, 0.01...0.5, digits: 3, unit: "m"),
        .float("Width", \.width, 0.005...0.3, digits: 3, unit: "m"),
        .float("Size variation", \.sizeV, 0...0.6),
        .float("Per metre", \.perMetre, 0...300, step: 1, digits: 0),
        .float("First at", \.start, 0...0.9),
        .float("Angle", \.angle, 0...pi),
        .float("Angle variation", \.angleV, 0...1),
        .float("Fold", \.fold, 0...0.5),
        .float("Flutter", \.flutter, 0...1.5),
        .int("From generation", \.fromLevel, 0...6, mutation: 0),
    ]

    package static let look: [PlantParam<Foliage.Look>] = [
        .float("Translucency", \.translucency, 0...1, mutation: 0),
    ]

    package static let tree: [PlantParam<Foliage.Habitat>] = [
        .float("Frequency", \.frequency, 0...5, mutation: 0),
        .float("Base weight", \.base, 0...3, mutation: 0),
        .float("Height gain", \.elevation.gain, -3...3, mutation: 0),
        .float("Height from", \.elevation.from, -1...1.5, mutation: 0),
        .float("Height to", \.elevation.to, -1...1.5, mutation: 0),
        .float("Slope", \.slope, -5...5, mutation: 0),
        .float("Stand", \.stand, -3...3, mutation: 0),
        .float("Light", \.light, -3...3, mutation: 0),
        .float("At least", \.floor, 0...1, mutation: 0),
        .float("Saplings below", \.ages.x, 0...1, mutation: 0),
        .float("Young below", \.ages.y, 0...1, mutation: 0),
    ]

    package static let cover: [PlantParam<Foliage.Habitat.Cover>] = [
        .float("Forest count", \.count, 0...12000, step: 50, digits: 0, mutation: 0),
        .double("World cell", \.cell, 1...20, unit: "m"),
        .float("Patch size", \.patch, 2...100, step: 1, digits: 0, unit: "m", mutation: 0),
        PlantParam(title: "Smallest", range: 0.2...3, step: 0, digits: 2, unit: "", mutation: 0,
                   get: { Double($0.size.lowerBound) }, set: { $0.size = Float($1)...max(Float($1), $0.size.upperBound) }),
        PlantParam(title: "Largest", range: 0.2...3, step: 0, digits: 2, unit: "", mutation: 0,
                   get: { Double($0.size.upperBound) }, set: { $0.size = min(Float($1), $0.size.lowerBound)...Float($1) }),
        .float("Sink", \.sink, 0...0.5, digits: 2, unit: "m", mutation: 0),
    ]

    /// A curve's preset parameters: for a line its two ends, for a taper its taper.
    package static let lineEnds = -pi...pi
    package static let taperRange = 0.0...1.0
}
