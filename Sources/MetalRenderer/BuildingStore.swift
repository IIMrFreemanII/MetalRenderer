import Foundation

/// The building styles that scenes are built with: the built-in ones (one per district, BuiltInBuildings) with any
/// saved over them, then the custom ones; and single buildings' own plans (LotOverride, BuildingOverrides.swift).
struct BuildingCatalog: Equatable {
    var styles: [BuildingStyleDef]
    var overrides: [LotOverride] = []

    static let builtIn = BuildingCatalog(styles: BuiltInBuildings.all)

    func style(id: String) -> BuildingStyleDef? { styles.first { $0.id == id } }
    func isBuiltIn(_ id: String) -> Bool { BuiltInBuildings.all.contains { $0.id == id } }

    /// The style a lot of `district` is built in: its district's own style, or now and then a custom style whose
    /// `districts` name that district, by the lot's seed.
    func style(for district: CityStyle, seed: UInt64) -> BuildingStyleDef {
        let own = style(id: BuiltInBuildings.style(district).id) ?? BuiltInBuildings.style(district)
        let others = styles.filter { !isBuiltIn($0.id) && ($0.districts[district.name] ?? 0) > 0 }
        guard !others.isEmpty else { return own }
        let total = others.reduce(1) { $0 + ($1.districts[district.name] ?? 0) }
        var g = SplitMix64(seed: seed ^ 0x5717_1E5E_1EC7)
        var u = g.next() * total - 1
        guard u >= 0 else { return own }
        for s in others {
            u -= s.districts[district.name] ?? 0
            if u < 0 { return s }
        }
        return own
    }

    /// The built-in styles (in their order, any of them replaced by a definition of its id) and then the others.
    func merging(_ defs: [BuildingStyleDef]) -> BuildingCatalog {
        var out = self
        for def in defs {
            if let i = out.styles.firstIndex(where: { $0.id == def.id }) { out.styles[i] = def } else { out.styles.append(def) }
        }
        return out.sanitized()
    }

    /// Every style made safe to build: ids unique and not empty, numbers in reason.
    func sanitized() -> BuildingCatalog {
        var out = self
        var ids = Set<String>()
        for i in out.styles.indices {
            var d = out.styles[i].sanitized()
            while ids.contains(d.id) || d.id.isEmpty { d.id += "-\(i)" }
            ids.insert(d.id)
            out.styles[i] = d
        }
        return out
    }

    // MARK: - Fingerprints and the registry

    /// Names the catalog's every detail.
    var fingerprint: String { BuildingCatalog.hash(Fingerprinted(styles: styles, overrides: overrides)) }
    private struct Fingerprinted: Encodable {
        var styles: [BuildingStyleDef]
        var overrides: [LotOverride]
    }

    private static func hash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hasher = GeneratedCache.Hasher()
        hasher.add((try? encoder.encode(value)).map { [UInt8]($0) } ?? [])
        return String(hasher.name().prefix(12))
    }

    private static let lock = NSLock()
    private static let registry = CatalogRegistry<BuildingCatalog>()
    private static var launchCatalog: BuildingCatalog?

    /// What scenes are built with unless the editor says otherwise: the built-in styles with the saved files.
    static var launch: BuildingCatalog {
        lock.lock()
        defer { lock.unlock() }
        if let made = launchCatalog { return made }
        let made = BuildingStore.load()
        launchCatalog = made
        return made
    }

    static func setLaunch(_ catalog: BuildingCatalog) {
        lock.lock()
        launchCatalog = catalog
        lock.unlock()
    }

    /// Keeps the catalog for scenes to build with, by the key returned (SceneSettings.buildingCatalog).
    @discardableResult
    static func register(_ catalog: BuildingCatalog) -> String {
        let key = catalog.fingerprint
        registry.register(catalog, key: key)
        return key
    }

    static func registered(_ key: String) -> BuildingCatalog? { registry.registered(key) }

    /// The catalog a scene's settings name: "" the launch one, "builtin" the built-in styles, otherwise a registered
    /// one (the launch one if it is no longer kept).
    static func resolve(_ key: String) -> BuildingCatalog {
        switch key {
        case "": return launch
        case "builtin": return .builtIn
        default:
            if let found = registry.registered(key) { return found }
            print("Buildings: catalog \(key) is not kept; the saved one instead")
            return launch
        }
    }
}

extension BuildingStyleDef {
    /// Made safe to build (what a hand-edited file or a slider at its end could give).
    func sanitized() -> BuildingStyleDef {
        var d = self
        func span(_ s: inout Span, _ range: ClosedRange<Float>) {
            s.lo = min(max(s.lo.isFinite ? s.lo : range.lowerBound, range.lowerBound), range.upperBound)
            s.hi = min(max(s.hi.isFinite ? s.hi : s.lo, s.lo), range.upperBound)
        }
        span(&d.proportions.groundHeight, 2.6...8)
        span(&d.proportions.floorHeight, 2.5...6)
        span(&d.proportions.bay, 1.2...8)
        if d.proportions.pier.options.isEmpty { d.proportions.pier.options = [0.5] }
        span(&d.window.height, 0.5...6)
        if var g = d.groundWindow { span(&g.height, 0.5...6); d.groundWindow = g }
        if d.massing.shapes.isEmpty { d.massing.shapes = [.rect] }
        if var f = d.massing.floors { span(&f, 1...80); d.massing.floors = f }
        let p = d.programme
        d.programme.outerWall = min(max(p.outerWall, 0.2), 0.8)
        d.programme.partition = min(max(p.partition, 0.06), 0.4)
        d.programme.slab = min(max(p.slab, 0.12), 0.6)
        d.programme.stairWidth = min(max(p.stairWidth, 0.8), 2)
        d.programme.corridor = min(max(p.corridor, 1.1), 4)
        span(&d.programme.unitWidth, 3...30)
        return d
    }
}

/// The styles saved as JSON: `Assets/Buildings/Styles/<id>.json`, `{"format": 1, "style": {...}}`, and single
/// buildings' plans in `Assets/Buildings/overrides.json`. A file with a built-in style's id replaces that style
/// everywhere; any other id adds one. The folder is `METALRENDERER_BUILDINGS` if set (`builtin`: none), or
/// `Buildings` in the assets folder.
enum BuildingStore {
    static let format = 1

    struct File: Codable {
        var format = BuildingStore.format
        var style: BuildingStyleDef
    }

    struct OverridesFile: Codable {
        var format = BuildingStore.format
        var buildings: [LotOverride]
    }

    static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_BUILDINGS"] {
        case "builtin": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Scene.assetsDirectory.appendingPathComponent("Buildings")
        }
    }

    static func url(_ id: String, in folder: URL) -> URL { folder.appendingPathComponent("Styles").appendingPathComponent("\(id).json") }
    static func overridesURL(in folder: URL) -> URL { folder.appendingPathComponent("overrides.json") }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func encode(_ def: BuildingStyleDef) throws -> Data { try encoder.encode(File(style: def)) }

    /// A style file read over a plain style's defaults: a field added since it was written keeps its default (and
    /// one that is gone is ignored), as with the app's settings (SettingsStore).
    static func decode(_ data: Data) throws -> File {
        guard var file = try JSONSerialization.jsonObject(with: data) as? [String: Any], let style = file["style"] as? [String: Any],
              let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BuildingStyleDef(id: "", name: ""))) as? [String: Any] else {
            return try JSONDecoder().decode(File.self, from: data)
        }
        file["style"] = SettingsStore.merge(base, style)
        return try JSONDecoder().decode(File.self, from: JSONSerialization.data(withJSONObject: file))
    }

    /// The built-in styles with the folder's files laid over them, and its single buildings.
    static func load(from folder: URL? = BuildingStore.folder) -> BuildingCatalog {
        guard let folder else { return .builtIn }
        var defs: [BuildingStyleDef] = []
        let styles = folder.appendingPathComponent("Styles")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: styles.path)) ?? []).sorted() where name.hasSuffix(".json") {
            do {
                let file = try decode(Data(contentsOf: styles.appendingPathComponent(name)))
                guard file.format <= format else { print("Buildings: \(name) is of a newer format (\(file.format)), skipped"); continue }
                defs.append(file.style)
            } catch {
                print("Buildings: \(name) doesn't read: \(error)")
            }
        }
        var catalog = BuildingCatalog.builtIn.merging(defs)
        if let data = try? Data(contentsOf: overridesURL(in: folder)) {
            do {
                catalog.overrides = try JSONDecoder().decode(OverridesFile.self, from: data).buildings
            } catch {
                print("Buildings: overrides.json doesn't read: \(error)")
            }
        }
        if !defs.isEmpty || !catalog.overrides.isEmpty {
            print("Buildings: \(defs.map(\.id).joined(separator: ", ")) and \(catalog.overrides.count) single buildings from \(folder.path)")
        }
        return catalog
    }

    /// Writes the style's file (in place of the one there).
    static func save(_ def: BuildingStyleDef, in folder: URL) throws {
        let file = url(def.id, in: folder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(def).write(to: file, options: .atomic)
    }

    /// Deletes the style's file: a built-in style is itself again; a custom one is gone.
    static func remove(_ id: String, in folder: URL) throws {
        let file = url(id, in: folder)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Writes the single buildings (none: the file goes).
    static func saveOverrides(_ overrides: [LotOverride], in folder: URL) throws {
        let file = overridesURL(in: folder)
        if overrides.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(OverridesFile(buildings: overrides)).write(to: file, options: .atomic)
    }

    // MARK: - The editor's draft

    private static let draftKey = "buildingDraft"

    private struct Draft: Codable {
        var styles: [BuildingStyleDef]
        var overrides: [LotOverride]
    }

    static func loadDraft() -> BuildingCatalog? {
        guard let data = UserDefaults.standard.data(forKey: draftKey),
              let draft = try? JSONDecoder().decode(Draft.self, from: data) else { return nil }
        return BuildingCatalog(styles: draft.styles, overrides: draft.overrides).sanitized()
    }

    /// nil: no draft (everything is saved).
    static func saveDraft(_ catalog: BuildingCatalog?) {
        guard let catalog, let data = try? JSONEncoder().encode(Draft(styles: catalog.styles, overrides: catalog.overrides)) else {
            UserDefaults.standard.removeObject(forKey: draftKey)
            return
        }
        UserDefaults.standard.set(data, forKey: draftKey)
    }
}
