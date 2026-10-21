import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants

/// Which of a scene's materials a Material Designer graph replaces (click-to-pick, then Assign): per scene — its kind
/// and what decides its materials' order (its seed; the showcase's model) — the materials by their index, each with a
/// fingerprint of the material as the scene made it (a scene whose builder changed since gets no stale assignment:
/// it is dropped, with a warning) and the graph's name. Saved as Assets/Materials/assignments.json; the editor's
/// edits are a registry key (`SceneSettings.materialAssignments`), as the catalogs' are: "" the saved ones.
/// A scene applies its own when it is made (Scene.applyMaterialAssignments): the material becomes a procedural one.
/// Not the open world's tiles (their materials stream in with them).
package struct MaterialAssignments: Codable, Equatable {
    package struct Entry: Codable, Equatable {
        package var material: Int
        package var fingerprint: String
        package var graph: String

        /// (As the memberwise initializer, for the modules above this one.)
        package init(material: Int, fingerprint: String, graph: String) {
            self.material = material
            self.fingerprint = fingerprint
            self.graph = graph
        }
    }
    package var scenes: [String: [Entry]] = [:]

    package static let file = "assignments.json"

    package static var url: URL? { MaterialStore.folder?.appendingPathComponent(file) }

    package static let launch: MaterialAssignments = {
        guard let url, let data = try? Data(contentsOf: url) else { return MaterialAssignments() }
        return (try? JSONDecoder().decode(MaterialAssignments.self, from: data)) ?? MaterialAssignments()
    }()

    package func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// A material's fingerprint: its values as the scene made it.
    package static func fingerprint(_ m: GPUMaterial) -> String {
        var h = Hasher64()
        withUnsafeBytes(of: m) { h.add($0) }
        return String(h.value, radix: 36)
    }

    private static let registry = CatalogRegistry<MaterialAssignments>()

    package static func register(_ a: MaterialAssignments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var h = Hasher64()
        h.add(String(data: (try? encoder.encode(a)) ?? Data(), encoding: .utf8) ?? "")
        let key = String(h.value, radix: 36)
        registry.register(a, key: key)
        return key
    }

    package static func resolve(_ key: String) -> MaterialAssignments {
        key.isEmpty ? launch : registry.registered(key) ?? launch
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(scenes: [String: [Entry]] = [:]) {
        self.scenes = scenes
    }
}
