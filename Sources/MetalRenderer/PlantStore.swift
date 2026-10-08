import Foundation

/// The species saved as JSON: `Assets/Plants/<id>.json`, one species to a file, `{"format": 1, "species": {...}}`.
/// A file with a built-in species' id replaces that species everywhere; any other id adds a species. The folder is
/// `METALRENDERER_PLANTS` if set (`builtin`: none, the built-in species only), or `Plants` in the assets folder.
///
/// The plant editor's unsaved edits are a draft in UserDefaults, kept between launches until saved or reverted.
enum PlantStore {
    static let format = 1

    struct File: Codable {
        var format = PlantStore.format
        var species: Foliage.SpeciesDef
    }

    static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_PLANTS"] {
        case "builtin": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Scene.assetsDirectory.appendingPathComponent("Plants")
        }
    }

    static func url(_ id: String, in folder: URL) -> URL { folder.appendingPathComponent("\(id).json") }

    static func encode(_ def: Foliage.SpeciesDef) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(species: def))
    }

    /// The built-in species with the folder's files laid over them.
    static func load(from folder: URL? = PlantStore.folder) -> PlantCatalog {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return .builtIn }
        var defs: [Foliage.SpeciesDef] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            do {
                let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
                guard file.format <= format else { print("Plants: \(name) is of a newer format (\(file.format)), skipped"); continue }
                defs.append(file.species)
            } catch {
                print("Plants: \(name) doesn't read: \(error)")
            }
        }
        let catalog = PlantCatalog.builtIn.merging(defs)
        if !defs.isEmpty { print("Plants: \(defs.map(\.id).joined(separator: ", ")) from \(folder.path)") }
        return catalog
    }

    /// Writes the species' file (in place of the one there).
    static func save(_ def: Foliage.SpeciesDef, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encode(def).write(to: url(def.id, in: folder), options: .atomic)
    }

    /// Deletes the species' file: a built-in species is itself again; a custom one is gone.
    static func remove(_ id: String, in folder: URL) throws {
        let file = url(id, in: folder)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    // MARK: - The editor's draft

    private static let draftKey = "plantDraft"

    static func loadDraft() -> PlantCatalog? {
        guard let data = UserDefaults.standard.data(forKey: draftKey),
              let defs = try? JSONDecoder().decode([Foliage.SpeciesDef].self, from: data) else { return nil }
        return PlantCatalog(species: defs).sanitized()
    }

    /// nil: no draft (everything is saved).
    static func saveDraft(_ catalog: PlantCatalog?) {
        guard let catalog, let data = try? JSONEncoder().encode(catalog.species) else {
            UserDefaults.standard.removeObject(forKey: draftKey)
            return
        }
        UserDefaults.standard.set(data, forKey: draftKey)
    }
}

extension PlantCatalog {
    /// The built-in species (in their order, any of them replaced by a definition of its id) and then the others,
    /// in the order of their seeds.
    func merging(_ defs: [Foliage.SpeciesDef]) -> PlantCatalog {
        var out = self
        var custom: [Foliage.SpeciesDef] = []
        for def in defs {
            if let i = out.species.firstIndex(where: { $0.id == def.id }), i < Foliage.Species.allCases.count {
                var d = def
                d.seedIndex = PlantCatalog.builtIn.species[i].seedIndex   // a built-in species keeps its seeds
                out.species[i] = d
            } else {
                custom.removeAll { $0.id == def.id }
                custom.append(def)
            }
        }
        out.species.removeSubrange(Foliage.Species.allCases.count...)
        out.species += custom.sorted { $0.seedIndex < $1.seedIndex }
        return out.sanitized()
    }

    /// Every definition made safe to grow: at least one level and one shade, counts and sizes in reason, custom
    /// species' seeds their own (from 100) and their ids unique.
    func sanitized() -> PlantCatalog {
        var out = self
        var seeds = Set<Int>(), ids = Set<String>()
        for i in out.species.indices {
            var d = out.species[i].sanitized()
            if i >= Foliage.Species.allCases.count {
                if d.seedIndex < 100 || seeds.contains(d.seedIndex) { d.seedIndex = max(100, (seeds.max() ?? 99) + 1) }
                while ids.contains(d.id) || d.id.isEmpty { d.id += "-\(i)" }
            }
            seeds.insert(d.seedIndex)
            ids.insert(d.id)
            out.species[i] = d
        }
        return out
    }

    // MARK: - Fingerprints and the registry

    /// Names the catalog's every detail: two catalogs of the same fingerprint grow the same plants in the same places.
    var fingerprint: String { PlantCatalog.hash(species) }

    /// Names what decides where plants stand (an open world's tiles hold their trees): which species there are, what
    /// they are to the scenes, where they grow and how many variants each has.
    var placementFingerprint: String {
        struct Placing: Encodable { var id: String; var role: Foliage.Role; var habitat: Foliage.Habitat; var variants: [Int] }
        return PlantCatalog.hash(species.map { Placing(id: $0.id, role: $0.role, habitat: $0.habitat, variants: $0.ages.variants) })
    }

    /// (Catalog-sized comparisons: the default scenes' keys stay what they were with the built-in species.)
    var placesAsBuiltIn: Bool { self == .builtIn || placementFingerprint == PlantCatalog.builtIn.placementFingerprint }

    private static func hash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hasher = GeneratedCache.Hasher()
        hasher.add((try? encoder.encode(value)).map { [UInt8]($0) } ?? [])
        return String(hasher.name().prefix(12))
    }

    private static let lock = NSLock()
    private static var registry: [String: PlantCatalog] = [:]
    private static var registered: [String] = []          // oldest first
    private static var launchCatalog: PlantCatalog?

    /// What scenes are built with unless the editor says otherwise: the built-in species with the saved files.
    static var launch: PlantCatalog {
        lock.lock()
        defer { lock.unlock() }
        if let made = launchCatalog { return made }
        let made = PlantStore.load()
        launchCatalog = made
        return made
    }

    /// The saved files changed (the editor saved or reverted): `launch` is this now.
    static func setLaunch(_ catalog: PlantCatalog) {
        lock.lock()
        launchCatalog = catalog
        lock.unlock()
    }

    /// Keeps the catalog for scenes to build with, by the key returned (SceneSettings.plantCatalog).
    @discardableResult
    static func register(_ catalog: PlantCatalog) -> String {
        let key = catalog.fingerprint
        lock.lock()
        if registry[key] == nil {
            registry[key] = catalog
            registered.append(key)
            if registered.count > 64 { registry[registered.removeFirst()] = nil }
        }
        lock.unlock()
        return key
    }

    /// The registered catalog of `key`, if it is still kept ("" or another: nil).
    static func registered(_ key: String) -> PlantCatalog? {
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return registry[key]
    }

    /// The catalog a scene's settings name: "" the launch one, "builtin" the built-in species, otherwise a registered
    /// one (the launch one if it is no longer kept).
    static func resolve(_ key: String) -> PlantCatalog {
        switch key {
        case "": return launch
        case "builtin": return .builtIn
        default:
            lock.lock()
            let found = registry[key]
            lock.unlock()
            if let found { return found }
            print("Plants: catalog \(key) is not kept; the saved one instead")
            return launch
        }
    }
}

extension Foliage.SpeciesDef {
    /// Made safe to grow (what a hand-edited file or a slider at its end could give).
    func sanitized() -> Foliage.SpeciesDef {
        var d = self
        func clean(_ r: inout Foliage.Recipe) {
            if r.levels.isEmpty { r.levels = [Foliage.Level()] }
            if r.levels.count > 6 { r.levels.removeLast(r.levels.count - 6) }
            for i in r.levels.indices {
                r.levels[i].count = min(max(r.levels[i].count, 0), 200)
                r.levels[i].segments = min(max(r.levels[i].segments, 1), 64)
                r.levels[i].radial = min(max(r.levels[i].radial, 1), 32)
                r.levels[i].length = max(r.levels[i].length, 0.001)
            }
            r.levels[0].count = max(r.levels[0].count, 1)
            if var leaf = r.leaf {
                leaf.perMetre = min(max(leaf.perMetre, 0), 1000)
                leaf.length = max(leaf.length, 0.001)
                leaf.width = max(leaf.width, 0.0005)
                if case .whorled(let n) = leaf.phyllotaxis, n < 1 { leaf.phyllotaxis = .whorled(1) }
                r.leaf = leaf
            }
            if var graft = r.graft {
                graft.spacing = max(graft.spacing, 0.05)
                if !(graft.scale.lowerBound > 0) { graft.scale = 0.01...max(graft.scale.upperBound, 0.01) }
                r.graft = graft
            }
        }
        clean(&d.recipe)
        if var bough = d.bough { clean(&bough); d.bough = bough }
        d.palette.count = min(max(d.palette.count, 1), 16)
        while d.ages.variants.count < 3 { d.ages.variants.insert(0, at: 0) }
        d.ages.variants = d.ages.variants.prefix(3).map { min(max($0, 0), 8) }
        d.ages.variants[2] = max(d.ages.variants[2], 1)
        if d.look.leaves.isEmpty { d.look.leaves = [[0.12, 0.24, 0.07]] }
        if let grass = d.grass { d.grass = Foliage.GrassPatch(size: max(grass.size, 0.1), blades: min(max(grass.blades, 1), 5000)) }
        return d
    }
}
