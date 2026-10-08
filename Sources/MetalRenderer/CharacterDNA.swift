import Foundation

/// A character as data: everything that makes one person different from another, and nothing else. The character
/// editor and the NPC generator only ever write it; CharacterBuilder makes the mesh, skeleton and materials from it.
///
/// Macro sliders (sex, age, weight, muscle, height, proportions) drive many morphs and bone lengths at once (MacroRig);
/// `morphs` and `bones` are the user's offsets on top of what the macros give, each -1...1. Saved as JSON
/// (CharacterStore); decoding fills what a file doesn't have with defaults, so files of older builds still load.
struct CharacterDNA: Codable, Equatable {
    static let currentFormat = 1

    var format = CharacterDNA.currentFormat
    var id = "custom"
    var name = "Custom"
    /// The built-in it was made from, if any.
    var basedOn: String?
    var seed: UInt64 = 0
    var macro = Macro()
    /// Morph offsets by name (CharacterMorphs' targets), -1...1; absent = 0.
    var morphs: [String: Float] = [:]
    /// Bone group length offsets by name (CharacterParams.boneGroups), -1...1; absent = 0.
    var bones: [String: Float] = [:]
    var look = Look()

    struct Macro: Codable, Equatable {
        /// 0 = male ... 1 = female.
        var sex: Float = 0
        /// Years, 18...90.
        var age: Float = 30
        /// -1 = thin ... 1 = heavy.
        var weight: Float = 0
        /// -1 = slight ... 1 = muscular.
        var muscle: Float = 0
        /// -1 ... 1: about -10% ... +10% of the sex's average height.
        var height: Float = 0
        /// -1 = stocky (short limbs, long trunk) ... 1 = long-limbed.
        var proportions: Float = 0
    }

    struct Look: Codable, Equatable {
        /// Skin: how dark (eumelanin, 0 = very fair ... 1 = very dark) and how red (blood, haemoglobin).
        var melanin: Float = 0.3
        var redness: Float = 0.35
        var roughness: Float = 0.5
    }

    /// The morph offset `name` (0 if unset).
    func morph(_ name: String) -> Float { morphs[name] ?? 0 }
    func bone(_ name: String) -> Float { bones[name] ?? 0 }

    /// Every value in range, zero offsets dropped (so equal characters compare and hash equal).
    func sanitized() -> CharacterDNA {
        var d = self
        d.format = CharacterDNA.currentFormat
        d.macro.sex = min(max(d.macro.sex, 0), 1)
        d.macro.age = min(max(d.macro.age, 18), 90)
        d.macro.weight = min(max(d.macro.weight, -1), 1)
        d.macro.muscle = min(max(d.macro.muscle, -1), 1)
        d.macro.height = min(max(d.macro.height, -1), 1)
        d.macro.proportions = min(max(d.macro.proportions, -1), 1)
        d.morphs = d.morphs.mapValues { min(max($0, -1), 1) }.filter { $0.value != 0 && $0.value.isFinite }
        d.bones = d.bones.mapValues { min(max($0, -1), 1) }.filter { $0.value != 0 && $0.value.isFinite }
        d.look.melanin = min(max(d.look.melanin, 0), 1)
        d.look.redness = min(max(d.look.redness, 0), 1)
        d.look.roughness = min(max(d.look.roughness, 0.2), 0.9)
        return d
    }

    /// A short fingerprint of everything in it (FNV-1a over its sorted JSON).
    var key: String { CharacterDNA.fingerprint(self) }

    static func fingerprint<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return String(format: "%016llx", hash)
    }

    // MARK: Decoding with defaults

    private enum CodingKeys: String, CodingKey { case format, id, name, basedOn, seed, macro, morphs, bones, look }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterDNA()
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? d.format
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        basedOn = try c.decodeIfPresent(String.self, forKey: .basedOn)
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? d.seed
        macro = try c.decodeIfPresent(Macro.self, forKey: .macro) ?? d.macro
        morphs = try c.decodeIfPresent([String: Float].self, forKey: .morphs) ?? [:]
        bones = try c.decodeIfPresent([String: Float].self, forKey: .bones) ?? [:]
        look = try c.decodeIfPresent(Look.self, forKey: .look) ?? d.look
    }
}

extension CharacterDNA.Macro {
    private enum CodingKeys: String, CodingKey { case sex, age, weight, muscle, height, proportions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterDNA.Macro()
        sex = try c.decodeIfPresent(Float.self, forKey: .sex) ?? d.sex
        age = try c.decodeIfPresent(Float.self, forKey: .age) ?? d.age
        weight = try c.decodeIfPresent(Float.self, forKey: .weight) ?? d.weight
        muscle = try c.decodeIfPresent(Float.self, forKey: .muscle) ?? d.muscle
        height = try c.decodeIfPresent(Float.self, forKey: .height) ?? d.height
        proportions = try c.decodeIfPresent(Float.self, forKey: .proportions) ?? d.proportions
    }
}

extension CharacterDNA.Look {
    private enum CodingKeys: String, CodingKey { case melanin, redness, roughness }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterDNA.Look()
        melanin = try c.decodeIfPresent(Float.self, forKey: .melanin) ?? d.melanin
        redness = try c.decodeIfPresent(Float.self, forKey: .redness) ?? d.redness
        roughness = try c.decodeIfPresent(Float.self, forKey: .roughness) ?? d.roughness
    }
}
