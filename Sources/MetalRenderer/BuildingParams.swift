import Foundation

/// The building editor's numbers (BuildingStyleDef's), described once like the plant editor's (PlantParams): the
/// rows of its tabs, Mutate (BuildingMutate) and the tests read these tables. A range (Span) is two rows, its least
/// and most.
enum BuildingParams {
    typealias P = PlantParam<BuildingStyleDef>
    typealias D = BuildingStyleDef

    /// A span's two rows.
    private static func span(_ title: String, _ path: WritableKeyPath<D, Span>, _ range: ClosedRange<Double>, digits: Int = 2,
                             unit: String = "m", mutation: Double = 0.1) -> [P] {
        [.float("\(title), least", path.appending(path: \Span.lo), range, digits: digits, unit: unit, mutation: mutation),
         .float("\(title), most", path.appending(path: \Span.hi), range, digits: digits, unit: unit, mutation: mutation)]
    }

    static let proportions: [P] = span("Ground floor height", \.proportions.groundHeight, 2.6...8)
        + span("Floor height", \.proportions.floorHeight, 2.5...6)
        + span("Bay width", \.proportions.bay, 1.2...8)

    static let window: [P] = [
        .float("Narrowest", \.window.minWidth, 0.4...4, unit: "m"),
        .float("Widest", \.window.maxWidth, 0.4...8, unit: "m"),
        .float("Frame width", \.window.frame, 0.03...0.2, digits: 3, unit: "m", mutation: 0),
        .float("Transom (chance)", \.window.transom, 0...1, mutation: 0.3),
        .float("Sill trim (chance)", \.window.sillTrim, 0...1, mutation: 0.3),
        .float("Lintel (chance)", \.window.lintel, 0...1, mutation: 0.3),
        .float("Shutters (chance)", \.window.shutters, 0...1, mutation: 0.3),
    ] + span("Height", \.window.height, 0.5...6)

    static let facade: [P] = [
        .float("Shops on the street", \.facade.shops, 0...1, mutation: 0.2),
        .float("Awnings over them", \.facade.awnings, 0...1, mutation: 0.2),
        .float("Ledge over the ground floor", \.facade.ledge, 0...1, mutation: 0.3),
        .float("Ledges at every floor", \.facade.floorLedges, 0...1, mutation: 0.3),
        .float("Pilasters", \.facade.pilasters, 0...1, mutation: 0.3),
        .float("Room boxes' depth (no interior)", \.facade.roomDepth, 2...8, unit: "m", mutation: 0),
    ] + span("Cornice", \.facade.cornice, 0...0.8)

    static let massing: [P] = [
        .int("Tower from (floors, 0 never)", \.massing.tower, 0...60, mutation: 0),
        .float("Podium (chance)", \.massing.podium, 0...1, mutation: 0.3),
        .float("Penthouse (chance)", \.massing.penthouse, 0...1, mutation: 0.3),
        .float("Chimneys (chance)", \.massing.chimneys, 0...1, mutation: 0.3),
        .float("Water tank (chance)", \.massing.waterTank, 0...1, mutation: 0.3),
        .float("Mast (chance)", \.massing.mast, 0...1, mutation: 0.3),
    ] + span("Setback", \.massing.setback, 0...6) + span("Pitch (rise over run)", \.massing.roofPitch, 0.1...1.5, unit: "")

    static let walls: [P] = [
        .float("Outer walls", \.programme.outerWall, 0.2...0.8, digits: 2, unit: "m", mutation: 0),
        .float("Partitions", \.programme.partition, 0.06...0.4, digits: 2, unit: "m", mutation: 0),
        .float("Slabs", \.programme.slab, 0.12...0.6, digits: 2, unit: "m", mutation: 0),
    ]

    static let core: [P] = [
        .float("Stair flight width", \.programme.stairWidth, 0.8...2, unit: "m", mutation: 0.1),
        .int("Lift from (floors, 0 never)", \.programme.liftFrom, 0...40, mutation: 0),
        .float("Corridor width", \.programme.corridor, 1.1...4, unit: "m", mutation: 0.1),
    ]

    static let rooms: [P] = [
        .float("Living room, narrowest", \.programme.living, 2.4...8, unit: "m"),
        .float("Bedroom, narrowest", \.programme.bedroom, 2...6, unit: "m"),
        .float("Kitchen, narrowest", \.programme.kitchen, 1.6...5, unit: "m"),
        .float("Bathroom, narrowest", \.programme.bath, 1.4...4, unit: "m"),
        .float("Hall band depth", \.programme.innerBand, 1.6...4, unit: "m"),
        .float("Open kitchens (chance)", \.programme.openKitchen, 0...1, mutation: 0.3),
        .float("Offices' own rooms (share)", \.programme.cellular, 0...0.8, mutation: 0.2),
    ] + span("Flat frontage", \.programme.unitWidth, 3...30)

    static let furnish: [P] = [
        .float("Clutter", \.interior.clutter, 0...1, mutation: 0.2),
        .float("House plants (chance)", \.interior.plants, 0...1, mutation: 0.2),
        .float("Ceiling lights' brightness", \.interior.lightPower, 0...60, digits: 1, mutation: 0.1),
    ]

    static let glow: [P] = span("Lit blinds' brightness", \.palette.glowScale, 0...3, unit: "")

    /// Every table, for Mutate and the tests.
    static let all: [P] = proportions + window + facade + massing + walls + core + rooms + furnish + glow
}

/// Variations of a style (the editor's Mutate): a few of its numbers moved within their ranges, by a seed.
enum BuildingMutate {
    static func mutants(of def: BuildingStyleDef, count: Int = 6, seed: UInt64) -> [BuildingStyleDef] {
        var rng = SplitMix64(seed: seed)
        let table = BuildingParams.all.filter { $0.mutation > 0 }
        return (0..<count).map { k in
            var d = def
            d.id = "\(def.id)~\(k + 1)"
            for _ in 0..<(3 + rng.int(4)) {
                let p = table[rng.int(table.count)]
                let span = p.range.upperBound - p.range.lowerBound
                p.set(&d, p.clamp(p.get(d) + Double(rng.range(-1, 1)) * span * p.mutation))
            }
            // A span's least stays under its most.
            return d.sanitized()
        }
    }

    /// Variation `m` as the style's: its numbers, the style's own id and name.
    static func pick(_ m: BuildingStyleDef, into def: BuildingStyleDef) -> BuildingStyleDef {
        var d = m
        (d.id, d.name, d.basedOn, d.districts) = (def.id, def.name, def.basedOn, def.districts)
        return d
    }
}
