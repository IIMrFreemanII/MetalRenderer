import Foundation

/// Which of a scene's materials a Material Designer graph replaces (click-to-pick, then Assign): per scene — its kind
/// and what decides its materials' order (its seed; the showcase's model) — the materials by their index, each with a
/// fingerprint of the material as the scene made it (a scene whose builder changed since gets no stale assignment:
/// it is dropped, with a warning) and the graph's name. Saved as Assets/Materials/assignments.json; the editor's
/// edits are a registry key (`SceneSettings.materialAssignments`), as the catalogs' are: "" the saved ones.
/// A scene applies its own when it is made (Scene.applyMaterialAssignments): the material becomes a procedural one.
/// Not the open world's tiles (their materials stream in with them).
struct MaterialAssignments: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var material: Int
        var fingerprint: String
        var graph: String
    }
    var scenes: [String: [Entry]] = [:]

    static let file = "assignments.json"

    static var url: URL? { MaterialStore.folder?.appendingPathComponent(file) }

    static let launch: MaterialAssignments = {
        guard let url, let data = try? Data(contentsOf: url) else { return MaterialAssignments() }
        return (try? JSONDecoder().decode(MaterialAssignments.self, from: data)) ?? MaterialAssignments()
    }()

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The scene `s` is: its kind, and what its materials' order depends on.
    static func scope(_ s: SceneSettings) -> String {
        switch s.kind {
        case .city, .cityNight: return "\(s.kind.envName),seed=\(s.seed),style=\(s.city.style.envName)"
        case .forest, .valley: return "\(s.kind.envName),seed=\(s.seed)"
        case .showcase: return "showcase,model=\(s.showcase)"
        case .materials: return "materials"
        default: return s.kind.envName
        }
    }

    /// A material's fingerprint: its values as the scene made it.
    static func fingerprint(_ m: GPUMaterial) -> String {
        var h = Hasher64()
        withUnsafeBytes(of: m) { h.add($0) }
        return String(h.value, radix: 36)
    }

    private static let registry = CatalogRegistry<MaterialAssignments>()

    static func register(_ a: MaterialAssignments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var h = Hasher64()
        h.add(String(data: (try? encoder.encode(a)) ?? Data(), encoding: .utf8) ?? "")
        let key = String(h.value, radix: 36)
        registry.register(a, key: key)
        return key
    }

    static func resolve(_ key: String) -> MaterialAssignments {
        key.isEmpty ? launch : registry.registered(key) ?? launch
    }
}

extension Scene {
    /// The scene's assignments (SceneSettings.materialAssignments): each material whose fingerprint still matches
    /// becomes the procedural material of its graph. Warnings for the stale ones.
    func applyMaterialAssignments() {
        guard settings.kind != .world else { return }
        let entries = MaterialAssignments.resolve(settings.materialAssignments).scenes[MaterialAssignments.scope(settings)] ?? []
        guard !entries.isEmpty else { return }
        let catalog = MaterialCatalog.resolve(settings.materials)
        for e in entries {
            guard e.material < materials.count, MaterialAssignments.fingerprint(materials[e.material]) == e.fingerprint else {
                print("Materials: the assignment of \(e.graph) to material \(e.material) is stale (the scene's materials changed)")
                continue
            }
            makeProcedural(e.material, graph: e.graph, catalog: catalog)
        }
    }
}
