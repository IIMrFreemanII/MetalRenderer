import Characters
import EngineCore
import Foundation
import simd

/// The garment workshop's settings (SceneSettings.garmentWorkshop): what is worn, by whom, and whether it moves.
package struct GarmentSceneSettings: Equatable, Codable {
    /// The garment: a key of GarmentCatalog's registry (the designer's edits), a saved garment's id, or a template's
    /// kind (`tshirt`, `pants` …: drawn for the avatar).
    package var garment = "tshirt"
    /// Who wears it: "Y Bot", "X Bot", or a character's id (CharacterCatalog).
    package var avatar = GarmentAvatar.yBot
    /// The cloth simulates (Space in the designer), or holds still.
    package var simulate = true
    /// Substeps a frame (each one iteration of every constraint).
    package var substeps = 20
    /// The avatar's clip (its name; "" the bind pose): the cloth follows it (a skinned body).
    package var clip = ""
    /// The cloth stops after this many seconds of its own (0: never): a still of the drape at that moment.
    package var stopAt: Float = 0

    package init() {}
}

/// The workshop's avatars: the character library's mannequins as they are, or a character made from its DNA, with its
/// body as the cloth meets it (BodySurface: a signed distance, kept per avatar).
package enum GarmentAvatars {
    private static let lock = NSLock()
    private static var bodies: [String: BodySurface] = [:]

    /// The character `name` names (a mannequin's name, or a character's id in `catalog`), in its bind pose.
    package static func character(_ name: String, catalog: CharacterCatalog = CharacterCatalog.launch) -> SkinnedCharacter? {
        let library = CharacterLibrary.load()
        if let c = library.characters.first(where: { $0.name == name }) { return c }
        guard let dna = catalog.character(id: name), let kit = CharacterKit.shared() else {
            return library.characters.first { $0.name == GarmentAvatar.yBot } ?? library.characters.first
        }
        return CharacterBuilder.build(dna, kit: kit, cap: true)
    }

    /// The names the designer offers: the mannequins, then the catalog's characters' ids.
    package static func names(catalog: CharacterCatalog = CharacterCatalog.launch) -> [String] {
        GarmentAvatar.mannequins + catalog.characters.map(\.id)
    }

    /// `c`'s body as a signed distance, 1 cm apart, made the first time `key` asks (about a second) and kept.
    package static func body(_ c: SkinnedCharacter, key: String) -> BodySurface {
        lock.lock()
        if let b = bodies[key] { lock.unlock(); return b }
        lock.unlock()
        let start = CFAbsoluteTimeGetCurrent()
        let level = c.level(0)
        let solids = CharacterRig(c).map { MuscleAtlas.boneSolids($0) } ?? []
        let made = BodySurface((level.positions, level.normals, level.indices), cell: 0.01, band: 0.08, smoothing: 1, solids: solids)
        print(String(format: "Garments: %@'s body in %.0f ms", key, (CFAbsoluteTimeGetCurrent() - start) * 1000))
        lock.lock()
        bodies[key] = made
        lock.unlock()
        return made
    }
}
