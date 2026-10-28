import EngineCore
import Foundation
import simd

/// Garments saved as JSON: `Assets/Garments/<id>.garment.json`, `{"format": 1, "garment": {...}}`. The folder is
/// `METALRENDERER_GARMENTS` if set, or `Garments` in the assets folder. The dev build reloads a saved file a scene uses
/// (DevReload); the designer's own saves are told apart by their stamps.
package enum GarmentStore {
    package static let format = 1
    package static let suffix = ".garment.json"

    package struct File: Codable {
        package var format = GarmentStore.format
        package var garment: Garment
    }

    package static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["METALRENDERER_GARMENTS"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return Assets.directory.appendingPathComponent("Garments")
    }

    /// A file name for a garment's name: lower case, words joined by dashes.
    package static func id(for name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "garment" : joined
    }

    package static func url(_ id: String, in folder: URL = GarmentStore.folder) -> URL { folder.appendingPathComponent(id + suffix) }

    package static func encode(_ g: Garment) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(garment: g))
    }

    package static func decode(_ data: Data) throws -> Garment {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.format <= format else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "a newer format (\(file.format))"]) }
        return file.garment
    }

    package static func read(_ url: URL) throws -> Garment { try decode(Data(contentsOf: url)) }

    package static func save(_ g: Garment, id: String, in folder: URL = GarmentStore.folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = url(id, in: folder)
        try encode(g).write(to: url, options: .atomic)
        FileStamps.note(url)   // (the app's own save: hot reload leaves it)
        return url
    }

    /// The saved garments' ids, by name.
    package static func list(in folder: URL = GarmentStore.folder) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }.sorted()
    }

    package static func load(_ id: String, in folder: URL = GarmentStore.folder) -> Garment? {
        do { return try read(url(id, in: folder)) } catch {
            print("Garments: \(id) doesn't read: \(error)")
            return nil
        }
    }
}

/// Garments kept by fingerprint (as the catalogs are): a scene's settings name one by its key, the designer registers
/// each edit's.
package enum GarmentCatalog {
    private static let registry = CatalogRegistry<Garment>(limit: 32)

    package static func fingerprint(_ g: Garment) -> String {
        let data = (try? GarmentStore.encode(g)) ?? Data()
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in data { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    @discardableResult
    package static func register(_ g: Garment) -> String {
        let key = fingerprint(g)
        registry.register(g, key: key)
        return key
    }

    /// The garment a key names: a registered one, or a saved file of that id, or a template's kind (`tshirt` …).
    package static func resolve(_ key: String) -> Garment? {
        if let g = registry.registered(key) { return g }
        if FileManager.default.fileExists(atPath: GarmentStore.url(key).path) { return GarmentStore.load(key) }
        return nil
    }
}
