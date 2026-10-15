import Foundation

/// One number of a plant's definition, described once: its title, range, step and how it is shown, and how far a
/// mutation may move it. The plant editor's rows, Mutate (PlantMutate.swift) and the tests are all built from these
/// tables, in the spirit of SettingsTable.
struct PlantParam<Root> {
    let title: String
    let range: ClosedRange<Double>
    let step: Double                    // 1: a whole number
    let digits: Int                     // shown with this many decimals
    let unit: String
    /// The most a mutation moves it, as a share of its range (0: never).
    let mutation: Double
    let get: (Root) -> Double
    let set: (inout Root, Double) -> Void

    var isInteger: Bool { step == 1 && digits == 0 }

    func text(_ v: Double) -> String { String(format: "%.\(digits)f", v) + (unit.isEmpty ? "" : " \(unit)") }

    /// `v` stepped and clamped into the range.
    func clamp(_ v: Double) -> Double {
        let stepped = step > 0 ? (v / step).rounded() * step : v
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    static func float(_ title: String, _ path: WritableKeyPath<Root, Float>, _ range: ClosedRange<Double>, step: Double = 0,
                      digits: Int = 2, unit: String = "", mutation: Double = 0.12) -> PlantParam {
        PlantParam(title: title, range: range, step: step, digits: digits, unit: unit, mutation: mutation,
                   get: { Double($0[keyPath: path]) }, set: { $0[keyPath: path] = Float($1) })
    }

    static func int(_ title: String, _ path: WritableKeyPath<Root, Int>, _ range: ClosedRange<Int>, mutation: Double = 0.12) -> PlantParam {
        PlantParam(title: title, range: Double(range.lowerBound)...Double(range.upperBound), step: 1, digits: 0, unit: "",
                   mutation: mutation, get: { Double($0[keyPath: path]) }, set: { $0[keyPath: path] = Int($1.rounded()) })
    }

    static func double(_ title: String, _ path: WritableKeyPath<Root, Double>, _ range: ClosedRange<Double>, digits: Int = 1,
                       unit: String = "", mutation: Double = 0) -> PlantParam {
        PlantParam(title: title, range: range, step: 0, digits: digits, unit: unit, mutation: mutation,
                   get: { $0[keyPath: path] }, set: { $0[keyPath: path] = $1 })
    }
}

enum PlantParams {
    typealias L = Foliage.Level
    private static let pi = Double.pi

    /// Level 0, the stems from the ground: its length is metres, its angle one from `up`.
    static let trunk: [PlantParam<L>] = [
        .int("Stems", \.count, 1...40, mutation: 0.05),
        .float("Height", \.length, 0.1...40, digits: 2, unit: "m", mutation: 0.08),
        .float("Height variation", \.lengthV, 0...0.6),
        .float("Lean variation", \.downAngleV, 0...1),
        .float("Turn between stems", \.rotate, 0...pi, mutation: 0.05),
        .float("Turn variation", \.rotateV, 0...1),
        .float("Bend", \.curve, -3...3),
        .float("Wander", \.curveV, 0...2),
        .float("Tropism", \.tropism, -2...2),
        .int("Segments", \.segments, 1...24, mutation: 0),
        .int("Sides", \.radial, 1...16, mutation: 0),
    ]

    /// The levels above: lengths are shares of the parent's.
    static let level: [PlantParam<L>] = [
        .int("Count", \.count, 0...60),
        .float("Length", \.length, 0.02...1.5, digits: 2),
        .float("Length variation", \.lengthV, 0...0.6),
        .float("Angle variation", \.downAngleV, 0...1),
        .float("Turn between", \.rotate, 0...pi, mutation: 0.08),
        .float("Turn variation", \.rotateV, 0...1),
        .float("First at", \.start, 0...0.95),
        .float("Bend", \.curve, -3...3),
        .float("Wander", \.curveV, 0...2),
        .float("Tropism", \.tropism, -2...2),
        .int("Segments", \.segments, 1...24, mutation: 0),
        .int("Sides", \.radial, 1...16, mutation: 0),
    ]

    static let recipe: [PlantParam<Foliage.Recipe>] = [
        .float("Radius ratio", \.ratio, 0.002...0.08, digits: 3),
        .float("Radius power", \.ratioPower, 0.5...2),
        .float("Flare", \.flare, 0...2),
        .float("Spread", \.spread, 0...2, unit: "m"),
    ]

    static let leaf: [PlantParam<Foliage.LeafRecipe>] = [
        .float("Length", \.length, 0.01...0.5, digits: 3, unit: "m"),
        .float("Width", \.width, 0.005...0.3, digits: 3, unit: "m"),
        .float("Size variation", \.sizeV, 0...0.6),
        .float("Per metre", \.perMetre, 0...300, step: 1, digits: 0),
        .float("First at", \.start, 0...0.9),
        .float("Angle", \.angle, 0...pi),
        .float("Angle variation", \.angleV, 0...1),
        .float("Fold", \.fold, 0...0.5),
        .float("Flutter", \.flutter, 0...1.5),
        .int("From level", \.fromLevel, 0...5, mutation: 0),
    ]

    static let graft: [PlantParam<Foliage.Graft>] = [
        .float("Spacing", \.spacing, 0.1...2, unit: "m"),
        .int("From level", \.fromLevel, 0...5, mutation: 0),
        .float("First at", \.start, 0...0.95),
        .float("First at (last level)", \.lastStart, 0...0.95),
        .float("Angle", \.angle, 0...pi),
        .float("Angle variation", \.angleV, 0...1),
        .float("Turn between", \.rotate, 0...pi, mutation: 0.05),
        .float("Droop", \.droop, -1...1),
        PlantParam(title: "Smallest", range: 0.1...3, step: 0, digits: 2, unit: "", mutation: 0.08,
                   get: { Double($0.scale.lowerBound) },
                   set: { $0.scale = Float($1)...max(Float($1), $0.scale.upperBound) }),
        PlantParam(title: "Largest", range: 0.1...3, step: 0, digits: 2, unit: "", mutation: 0.08,
                   get: { Double($0.scale.upperBound) },
                   set: { $0.scale = min(Float($1), $0.scale.lowerBound)...Float($1) }),
    ]

    static let palette: [PlantParam<Foliage.Palette>] = [
        .int("Boughs", \.count, 1...12, mutation: 0),
        .float("Short boughs", \.short, 0.3...1),
    ]

    static let age: [PlantParam<Foliage.AgeRule>] = [
        .float("Height", \.trunkLength, 0.05...1, mutation: 0),
        .float("Radius ratio", \.ratio, 0.3...1.5, mutation: 0),
        .float("Bough size", \.boughScale, 0.2...1.5, mutation: 0),
    ]

    static let look: [PlantParam<Foliage.Look>] = [
        .float("Translucency", \.translucency, 0...1, mutation: 0),
    ]

    static let tree: [PlantParam<Foliage.Habitat>] = [
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

    static let cover: [PlantParam<Foliage.Habitat.Cover>] = [
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
    static let lineEnds = -pi...pi
    static let taperRange = 0.0...1.0
}
