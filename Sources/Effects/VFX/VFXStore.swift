import EngineCore
import Foundation
import Physics

/// Effects saved as JSON: `Assets/Effects/<name>.vfx.json`, an effect a file, `{"format": 1, "effect": {...}}`. A file
/// named as a built-in effect is (campfire, rain, grinder, magic, rubble...) replaces it in every scene that places
/// it; any other is an effect of its own (the VFX stage shows it). The folder is `METALRENDERER_EFFECTS` if set
/// (`builtin`: none, the built-in effects only), or `Effects` in the assets folder.
package enum VFXStore {
    package static let format = 1
    package static let suffix = ".vfx.json"

    package struct File: Codable {
        package var format = VFXStore.format
        package var effect: VFXEffect
    }

    package static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_EFFECTS"] {
        case "builtin": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Assets.directory.appendingPathComponent("Effects")
        }
    }

    package static func url(_ name: String, in folder: URL) -> URL { folder.appendingPathComponent(VFXEffect.slug(name) + suffix) }

    package static func encode(_ effect: VFXEffect) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(File(effect: effect))
    }

    package static func decode(_ data: Data) throws -> VFXEffect {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let file = try decoder.decode(File.self, from: data)
        guard file.format <= format else { throw VFXError("of a newer format (\(file.format))") }
        return file.effect
    }

    /// The folder's effects, by name.
    package static func load(from folder: URL? = VFXStore.folder) -> VFXCatalog {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return VFXCatalog() }
        var catalog = VFXCatalog()
        for name in names.sorted() where name.hasSuffix(suffix) {
            do {
                let effect = try decode(Data(contentsOf: folder.appendingPathComponent(name)))
                catalog.effects[effect.name] = effect
            } catch {
                print("Effects: \(name) doesn't read: \(error)")
            }
        }
        if !catalog.effects.isEmpty { print("Effects: \(catalog.effects.keys.sorted().joined(separator: ", ")) from \(folder.path)") }
        return catalog
    }

    package static func save(_ effect: VFXEffect, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encode(effect).write(to: url(effect.name, in: folder), options: .atomic)
    }

    package static func remove(_ name: String, in folder: URL) throws {
        let file = url(name, in: folder)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

/// Effects by name that a scene's own (its built-in ones) give way to (Scene.effect): the saved files', or the VFX
/// editor's as it edits them. A scene's settings name one (SceneSettings.effects): "" the saved ones (loaded once, at
/// launch), "builtin" none, otherwise a key of the registry the editor fills (each edit a catalog of its own, so a
/// scene built in the background reads the one it was asked for).
package struct VFXCatalog: Equatable {
    package var effects: [String: VFXEffect] = [:]

    package static let launch = VFXStore.load()

    private static let lock = NSLock()
    private static var registry: [String: VFXCatalog] = [:]
    private static var order: [String] = []

    /// A key for `catalog` (its content's), kept among the last 64.
    package static func register(_ catalog: VFXCatalog) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys   // a block's parameters are a dictionary: the same catalog, the same key
        let data = (try? encoder.encode(catalog.effects.keys.sorted().map { catalog.effects[$0]! })) ?? Data()
        var h: UInt64 = 14_695_981_039_346_656_037
        for b in data { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        let key = String(h, radix: 36)
        lock.lock(); defer { lock.unlock() }
        if registry[key] == nil {
            registry[key] = catalog
            order.append(key)
            if order.count > 64 { registry[order.removeFirst()] = nil }
        }
        return key
    }

    package static func resolve(_ key: String) -> VFXCatalog {
        switch key {
        case "": return launch
        case "builtin": return VFXCatalog()
        default:
            lock.lock(); defer { lock.unlock() }
            return registry[key] ?? launch
        }
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(effects: [String: VFXEffect] = [:]) {
        self.effects = effects
    }
}
