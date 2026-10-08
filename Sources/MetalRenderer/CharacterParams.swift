import Foundation

/// One number of a character's DNA as the character editor shows it: PlantParam's row (title, range, how far a
/// mutation moves it) with an id (what a lock keeps), the group it is randomized with, and how a random value is
/// drawn for it.
struct CharacterParam {
    let id: String
    let group: Group
    let param: PlantParam<CharacterDNA>
    /// A random value's spread around the middle of the range, as a share of half the range (1: uniform over it).
    var spread: Double = 0.45
    /// The part of the face it shapes (the Face tab's sections, each randomized on its own); "" elsewhere.
    var section = ""

    enum Group: String, CaseIterable {
        case macro = "Body", shape = "Shape", face = "Face", bones = "Proportions", skin = "Skin"
    }
}

enum CharacterParams {
    /// The macro sliders: each drives many morphs and bone lengths (MacroRig).
    static let macro: [CharacterParam] = [
        CharacterParam(id: "sex", group: .macro, param: .float("Male … female", \.macro.sex, 0...1, mutation: 0.05), spread: 1),
        CharacterParam(id: "age", group: .macro, param: .float("Age", \.macro.age, 18...90, step: 1, digits: 0, unit: "years", mutation: 0.08),
                       spread: 0.8),
        CharacterParam(id: "weight", group: .macro, param: .float("Thin … heavy", \.macro.weight, -1...1, mutation: 0.15)),
        CharacterParam(id: "muscle", group: .macro, param: .float("Slight … muscular", \.macro.muscle, -1...1, mutation: 0.15)),
        CharacterParam(id: "height", group: .macro, param: .float("Height", \.macro.height, -1...1, mutation: 0.12)),
        CharacterParam(id: "proportions", group: .macro, param: .float("Stocky … long-limbed", \.macro.proportions, -1...1, mutation: 0.12)),
    ]

    /// Morph offsets on top of the macros', by CharacterMorphs' target names.
    static let shapes: [(name: String, title: String)] = [
        ("chest", "Chest"), ("belly", "Belly"), ("waist", "Waist"), ("hips", "Hips"), ("buttocks", "Seat"),
        ("shoulders", "Shoulders"), ("neckThickness", "Neck"), ("arms", "Arms"), ("thighs", "Thighs"), ("calves", "Calves"),
    ]

    static let shape: [CharacterParam] = shapes.map { s in
        CharacterParam(id: "morph." + s.name, group: .shape,
                       param: PlantParam(title: s.title, range: -1...1, step: 0, digits: 2, unit: "", mutation: 0.15,
                                         get: { Double($0.morph(s.name)) }, set: { $0.morphs[s.name] = Float($1) }), spread: 0.35)
    }

    /// The face's sliders (CharacterMorphs.faceSliders), in sections: the eyes, brows, nose, mouth, jaw and cheeks, ears.
    /// Each moves both sides alike.
    static let face: [CharacterParam] = CharacterMorphs.faceSliders.map { s in
        CharacterParam(id: "morph." + s.name, group: .face,
                       param: PlantParam(title: s.title, range: -1...1, step: 0, digits: 2, unit: "", mutation: 0.15,
                                         get: { Double($0.morph(s.name)) }, set: { $0.morphs[s.name] = Float($1) }), spread: 0.4,
                       section: s.group)
    }
    static var faceSections: [String] { face.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } } }

    /// Bone group lengths (MacroRig.boneGroups).
    static let bones: [CharacterParam] = MacroRig.boneGroups.map { g in
        CharacterParam(id: "bone." + g.name, group: .bones,
                       param: PlantParam(title: g.title, range: -1...1, step: 0, digits: 2, unit: "", mutation: 0.12,
                                         get: { Double($0.bone(g.name)) }, set: { $0.bones[g.name] = Float($1) }), spread: 0.3)
    }

    static let skin: [CharacterParam] = [
        CharacterParam(id: "melanin", group: .skin, param: .float("Fair … dark", \.look.melanin, 0...1, mutation: 0.05), spread: 1),
        CharacterParam(id: "redness", group: .skin, param: .float("Redness", \.look.redness, 0...1, mutation: 0.08)),
        CharacterParam(id: "roughness", group: .skin, param: .float("Roughness", \.look.roughness, 0.2...0.9, mutation: 0.05)),
        CharacterParam(id: "eyes", group: .skin, param: .float("Eyes: brown … blue", \.look.eyes, 0...1, mutation: 0.05), spread: 1),
    ]

    static let all: [CharacterParam] = macro + shape + face + bones + skin

    static func group(_ g: CharacterParam.Group) -> [CharacterParam] { all.filter { $0.group == g } }

    /// `dna` with the unlocked numbers of `groups` drawn at random (from the middle of their ranges, as far as their
    /// spread says), by `seed`.
    /// `only`: just these sliders of the groups (a section of the face).
    static func randomized(_ dna: CharacterDNA, groups: [CharacterParam.Group], only: Set<String>? = nil, locked: Set<String>,
                           seed: UInt64) -> CharacterDNA {
        var rng = SplitMix64(seed: seed)
        var d = dna
        for p in all where groups.contains(p.group) && !locked.contains(p.id) && (only?.contains(p.id) ?? true) {
            let lo = p.param.range.lowerBound, hi = p.param.range.upperBound
            // Near-normal (the mean of three uniforms) around the middle, wide by its spread.
            let u = (Double(rng.next()) + Double(rng.next()) + Double(rng.next())) / 3 * 2 - 1
            let v = p.spread >= 1 ? lo + Double(rng.next()) * (hi - lo) : (lo + hi) / 2 + u * p.spread * (hi - lo) / 2 * 1.7
            p.param.set(&d, p.param.clamp(v))
        }
        return d.sanitized()
    }

    /// `count` variations of `dna`: every unlocked number moved by up to its mutation share of its range.
    static func mutants(of dna: CharacterDNA, count: Int = 5, locked: Set<String>, seed: UInt64) -> [CharacterDNA] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { k in
            var d = dna
            for p in all where !locked.contains(p.id) && p.param.mutation > 0 {
                let span = p.param.range.upperBound - p.param.range.lowerBound
                let v = p.param.get(d) + (Double(rng.next()) * 2 - 1) * p.param.mutation * span * 2
                p.param.set(&d, p.param.clamp(v))
            }
            d.id = "\(dna.id)-variation-\(k + 1)"
            d.name = "\(dna.name) \(k + 1)"
            return d.sanitized()
        }
    }
}
