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
    var hair = Hair()

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
        /// The irises: 0 = dark brown ... 0.4 hazel ... 0.65 green ... 1 = light blue.
        var eyes: Float = 0.2
        /// The skin's marks (SkinTextures), each 0...1: freckles; makeup on the cheeks, the eyelids and the lips.
        var freckles: Float = 0
        var blush: Float = 0
        var eyeShadow: Float = 0
        var lipstick: Float = 0
        /// The hair's colour: how dark (eumelanin, 0 = platinum ... 1 = black), how red (pheomelanin), and how grey
        /// beyond what age greys it.
        var hairMelanin: Float = 0.6
        var hairRed: Float = 0.15
        var grey: Float = 0
    }

    /// What grows (CharacterHair): the hair's style (CharacterHair.styles' ids, "bald" none), how much longer or
    /// shorter than the style's (-1...1), how curly (0...1); the beard (CharacterHair.beards' ids); the brows' density.
    struct Hair: Codable, Equatable {
        var style = "short"
        var length: Float = 0
        var curl: Float = 0
        var beard = "none"
        var brows: Float = 0.6
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
        d.look.eyes = min(max(d.look.eyes, 0), 1)
        for k in [\Look.freckles, \.blush, \.eyeShadow, \.lipstick, \.hairMelanin, \.hairRed, \.grey] {
            d.look[keyPath: k] = min(max(d.look[keyPath: k], 0), 1)
        }
        d.hair.length = min(max(d.hair.length, -1), 1)
        d.hair.curl = min(max(d.hair.curl, 0), 1)
        d.hair.brows = min(max(d.hair.brows, 0), 1)
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

    private enum CodingKeys: String, CodingKey { case format, id, name, basedOn, seed, macro, morphs, bones, look, hair }

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
        hair = try c.decodeIfPresent(Hair.self, forKey: .hair) ?? d.hair
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
    private enum CodingKeys: String, CodingKey {
        case melanin, redness, roughness, eyes, freckles, blush, eyeShadow, lipstick, hairMelanin, hairRed, grey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterDNA.Look()
        melanin = try c.decodeIfPresent(Float.self, forKey: .melanin) ?? d.melanin
        redness = try c.decodeIfPresent(Float.self, forKey: .redness) ?? d.redness
        roughness = try c.decodeIfPresent(Float.self, forKey: .roughness) ?? d.roughness
        eyes = try c.decodeIfPresent(Float.self, forKey: .eyes) ?? d.eyes
        freckles = try c.decodeIfPresent(Float.self, forKey: .freckles) ?? d.freckles
        blush = try c.decodeIfPresent(Float.self, forKey: .blush) ?? d.blush
        eyeShadow = try c.decodeIfPresent(Float.self, forKey: .eyeShadow) ?? d.eyeShadow
        lipstick = try c.decodeIfPresent(Float.self, forKey: .lipstick) ?? d.lipstick
        hairMelanin = try c.decodeIfPresent(Float.self, forKey: .hairMelanin) ?? d.hairMelanin
        hairRed = try c.decodeIfPresent(Float.self, forKey: .hairRed) ?? d.hairRed
        grey = try c.decodeIfPresent(Float.self, forKey: .grey) ?? d.grey
    }
}

extension CharacterDNA.Hair {
    private enum CodingKeys: String, CodingKey { case style, length, curl, beard, brows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharacterDNA.Hair()
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? d.style
        length = try c.decodeIfPresent(Float.self, forKey: .length) ?? d.length
        curl = try c.decodeIfPresent(Float.self, forKey: .curl) ?? d.curl
        beard = try c.decodeIfPresent(String.self, forKey: .beard) ?? d.beard
        brows = try c.decodeIfPresent(Float.self, forKey: .brows) ?? d.brows
    }
}
