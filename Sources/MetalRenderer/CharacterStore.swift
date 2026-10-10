import Foundation

/// The characters scenes are made with: the built-in ones (BuiltInCharacters), any of them replaced by a saved file
/// of its id, then the saved ones of other ids. Kept by fingerprint in a registry, as the plants' and buildings'
/// catalogs are: a scene's settings carry only the key (SceneSettings.characterCatalog).
struct CharacterCatalog: Equatable, Codable {
    var characters: [CharacterDNA]

    static let builtIn = CharacterCatalog(characters: BuiltInCharacters.all)

    func character(id: String) -> CharacterDNA? { characters.first { $0.id == id } }

    /// The built-in characters (in their order, any replaced by a definition of its id), then the others by id.
    func merging(_ defs: [CharacterDNA]) -> CharacterCatalog {
        var out = self
        var custom: [CharacterDNA] = []
        for def in defs {
            if let i = out.characters.firstIndex(where: { $0.id == def.id }), i < BuiltInCharacters.all.count {
                out.characters[i] = def
            } else {
                custom.removeAll { $0.id == def.id }
                custom.append(def)
            }
        }
        out.characters.removeSubrange(min(BuiltInCharacters.all.count, out.characters.count)...)
        out.characters += custom.sorted { $0.id < $1.id }
        return out.sanitized()
    }

    /// Every character in range, ids unique and not empty.
    func sanitized() -> CharacterCatalog {
        var out = self
        var ids = Set<String>()
        for i in out.characters.indices {
            var d = out.characters[i].sanitized()
            if d.id.isEmpty { d.id = "character" }
            while ids.contains(d.id) { d.id += "-\(i)" }
            ids.insert(d.id)
            out.characters[i] = d
        }
        return out
    }

    var fingerprint: String { String(CharacterDNA.fingerprint(characters).prefix(12)) }

    private static let lock = NSLock()
    private static let registry = CatalogRegistry<CharacterCatalog>()
    private static var launchCatalog: CharacterCatalog?

    /// What scenes are made with unless the editor says otherwise: the built-in characters with the saved files.
    static var launch: CharacterCatalog {
        lock.lock()
        defer { lock.unlock() }
        if let made = launchCatalog { return made }
        let made = CharacterStore.load()
        launchCatalog = made
        return made
    }

    static func setLaunch(_ catalog: CharacterCatalog) {
        lock.lock()
        launchCatalog = catalog
        lock.unlock()
    }

    @discardableResult
    static func register(_ catalog: CharacterCatalog) -> String {
        let key = catalog.fingerprint
        registry.register(catalog, key: key)
        return key
    }

    static func registered(_ key: String) -> CharacterCatalog? { registry.registered(key) }

    /// The catalog a scene's settings name: "" the launch one, "builtin" the built-in characters, otherwise a
    /// registered one (the launch one if it is no longer kept).
    static func resolve(_ key: String) -> CharacterCatalog {
        switch key {
        case "": return launch
        case "builtin": return .builtIn
        default:
            if let found = registry.registered(key) { return found }
            print("Characters: catalog \(key) is not kept; the saved one instead")
            return launch
        }
    }
}

/// The characters saved as JSON: `Assets/CharacterDefs/<id>.json`, `{"format": 1, "character": {...}}`. The folder is
/// `METALRENDERER_CHARACTERS` if set (`builtin`: none), or `CharacterDefs` in the assets folder. The character editor's
/// unsaved edits are a draft in UserDefaults.
enum CharacterStore {
    static let format = 1

    struct File: Codable {
        var format = CharacterStore.format
        var character: CharacterDNA
    }

    static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_CHARACTERS"] {
        case "builtin": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Scene.assetsDirectory.appendingPathComponent("CharacterDefs")
        }
    }

    static func url(_ id: String, in folder: URL) -> URL { folder.appendingPathComponent("\(id).json") }

    static func encode(_ def: CharacterDNA) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(character: def))
    }

    static func load(from folder: URL? = CharacterStore.folder) -> CharacterCatalog {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return .builtIn }
        var defs: [CharacterDNA] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            do {
                let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
                guard file.format <= format else { print("Characters: \(name) is of a newer format (\(file.format)), skipped"); continue }
                defs.append(file.character)
            } catch {
                print("Characters: \(name) doesn't read: \(error)")
            }
        }
        if !defs.isEmpty { print("Characters: \(defs.map(\.id).joined(separator: ", ")) from \(folder.path)") }
        return CharacterCatalog.builtIn.merging(defs)
    }

    static func save(_ def: CharacterDNA, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encode(def).write(to: url(def.id, in: folder), options: .atomic)
    }

    static func remove(_ id: String, in folder: URL) throws {
        let file = url(id, in: folder)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    // MARK: - The editor's draft

    private static let draftKey = "characterDraft"

    static func loadDraft() -> CharacterCatalog? {
        guard let data = UserDefaults.standard.data(forKey: draftKey),
              let defs = try? JSONDecoder().decode([CharacterDNA].self, from: data) else { return nil }
        return CharacterCatalog(characters: defs).sanitized()
    }

    static func saveDraft(_ catalog: CharacterCatalog?) {
        guard let catalog, let data = try? JSONEncoder().encode(catalog.characters) else {
            UserDefaults.standard.removeObject(forKey: draftKey)
            return
        }
        UserDefaults.standard.set(data, forKey: draftKey)
    }
}

/// The characters that come with the app: a few people far enough apart to show what the sliders reach.
enum BuiltInCharacters {
    static let all: [CharacterDNA] = [
        make("man", "Man", sex: 0, age: 32, hair: "short", hairColour: 0.62),
        make("woman", "Woman", sex: 1, age: 30, melanin: 0.25, hair: "bob", hairColour: 0.45) { $0.look.lipstick = 0.2; $0.hair.brows = 0.45 },
        make("athlete", "Athlete", sex: 0, age: 26, weight: -0.3, muscle: 0.9, height: 0.4, melanin: 0.55, hair: "buzz", hairColour: 0.95),
        make("heavy", "Heavy man", sex: 0, age: 48, weight: 0.9, muscle: -0.1, height: -0.2, melanin: 0.2, hair: "sidePart", hairColour: 0.5) {
            $0.hair.beard = "full"; $0.look.hairRed = 0.35
        },
        make("elder", "Elder", sex: 0.15, age: 78, weight: 0.1, muscle: -0.5, height: -0.4, melanin: 0.12, hair: "receding", hairColour: 0.5),
        make("dancer", "Dancer", sex: 1, age: 24, weight: -0.4, muscle: 0.35, height: 0.3, proportions: 0.6, melanin: 0.85, hair: "curly",
             hairColour: 0.97) { $0.hair.brows = 0.5 },
    ]

    static func make(_ id: String, _ name: String, sex: Float, age: Float, weight: Float = 0, muscle: Float = 0, height: Float = 0,
                     proportions: Float = 0, melanin: Float = 0.3, hair: String = "short", hairColour: Float = 0.6,
                     _ change: (inout CharacterDNA) -> Void = { _ in }) -> CharacterDNA {
        var d = CharacterDNA()
        d.id = id
        d.name = name
        d.macro = CharacterDNA.Macro(sex: sex, age: age, weight: weight, muscle: muscle, height: height, proportions: proportions)
        d.look.melanin = melanin
        d.look.hairMelanin = hairColour
        d.hair.style = hair
        change(&d)
        return d
    }
}
