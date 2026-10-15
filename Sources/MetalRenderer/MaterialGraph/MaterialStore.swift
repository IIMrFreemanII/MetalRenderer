import Foundation

/// Material graphs saved as JSON: `Assets/Materials/<name>.mat.json`, a graph a file, `{"format": 1, "graph": {...}}`.
/// A file named as a built-in graph (MaterialLibrary) replaces it. The folder is `METALRENDERER_MATERIALS` if set
/// (`builtin`: none, the built-in graphs only), or `Materials` in the assets folder.
enum MaterialStore {
    static let format = 1
    static let suffix = ".mat.json"

    struct File: Codable {
        var format = MaterialStore.format
        var graph: MaterialGraph
    }

    static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_MATERIALS"] {
        case "builtin": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Scene.assetsDirectory.appendingPathComponent("Materials")
        }
    }

    static func url(_ name: String, in folder: URL) -> URL { folder.appendingPathComponent(VFXEffect.slug(name) + suffix) }

    static func encode(_ graph: MaterialGraph) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(File(graph: graph))
    }

    static func decode(_ data: Data) throws -> MaterialGraph {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let file = try decoder.decode(File.self, from: data)
        guard file.format <= format else { throw MatError("of a newer format (\(file.format))") }
        var g = file.graph
        g.normalizeIDs()
        return g
    }

    /// The folder's graphs, by name.
    static func load(from folder: URL? = MaterialStore.folder) -> MaterialCatalog {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return MaterialCatalog() }
        var catalog = MaterialCatalog()
        for name in names.sorted() where name.hasSuffix(suffix) {
            do {
                let graph = try decode(Data(contentsOf: folder.appendingPathComponent(name)))
                catalog.graphs[graph.name] = graph
            } catch {
                print("Materials: \(name) doesn't read: \(error)")
            }
        }
        if !catalog.graphs.isEmpty { print("Materials: \(catalog.graphs.keys.sorted().joined(separator: ", ")) from \(folder.path)") }
        return catalog
    }

    static func save(_ graph: MaterialGraph, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encode(graph).write(to: url(graph.name, in: folder), options: .atomic)
    }

    static func remove(_ name: String, in folder: URL) throws {
        let file = url(name, in: folder)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

/// Material graphs by name that the built-in ones (MaterialLibrary) give way to: the saved files', or the Material
/// Designer's as it edits them. A scene's settings name one (SceneSettings.materials): "" the saved ones (loaded once,
/// at launch), "builtin" none, otherwise a key of the registry the editor fills.
struct MaterialCatalog: Equatable {
    var graphs: [String: MaterialGraph] = [:]

    static let launch = MaterialStore.load()

    /// `name`'s graph: the catalog's, else the built-in one.
    func graph(_ name: String) -> MaterialGraph? { graphs[name] ?? MaterialLibrary.named(name) }

    /// Every graph's name: the built-in ones, then the others.
    var names: [String] { MaterialLibrary.names + graphs.keys.filter { !MaterialLibrary.names.contains($0) }.sorted() }

    private static let registry = CatalogRegistry<MaterialCatalog>()

    /// A key for `catalog` (its content's), kept among the last 64.
    static func register(_ catalog: MaterialCatalog) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(catalog.graphs.keys.sorted().map { catalog.graphs[$0]! })) ?? Data()
        var h: UInt64 = 14_695_981_039_346_656_037
        for b in data { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        let key = String(h, radix: 36)
        registry.register(catalog, key: key)
        return key
    }

    static func resolve(_ key: String) -> MaterialCatalog {
        switch key {
        case "": return launch
        case "builtin": return MaterialCatalog()
        default: return registry.registered(key) ?? launch
        }
    }
}
