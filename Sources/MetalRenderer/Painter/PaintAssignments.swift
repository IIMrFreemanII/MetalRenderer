import Foundation

/// Which scene objects the Material Painter paints, and with which document: per scene (MaterialAssignments.scope),
/// the instances by their index, each with a fingerprint of its mesh and material as the scene made them (a scene
/// whose builder changed since gets no stale paint: it is dropped, with a warning). Saved as
/// Assets/Painter/assignments.json; the painter's edits are a registry key (`SceneSettings.paintAssignments`): ""
/// the saved ones. A scene applies its own when it is made (Scene.applyPaintAssignments).
struct PaintAssignments: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var instance: Int
        var fingerprint: String
        var document: String
    }
    var scenes: [String: [Entry]] = [:]
    /// Bumped when a document's shape changes (its holes, its emission, its size): the same paint, the scene made again.
    var revision: Int? = nil

    static let file = "assignments.json"
    static var url: URL? { PainterStore.folder?.appendingPathComponent(file) }

    static let launch: PaintAssignments = {
        guard let url, let data = try? Data(contentsOf: url) else { return PaintAssignments() }
        return (try? JSONDecoder().decode(PaintAssignments.self, from: data)) ?? PaintAssignments()
    }()

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The entries of the scene `s` is.
    func entries(_ s: SceneSettings) -> [Entry] { scenes[MaterialAssignments.scope(s)] ?? [] }

    /// `s`'s instance `instance` painted with `document` (nil: not painted).
    mutating func set(_ s: SceneSettings, instance: Int, fingerprint: String, document: String?) {
        let scope = MaterialAssignments.scope(s)
        var list = scenes[scope] ?? []
        list.removeAll { $0.instance == instance }
        if let document { list.append(Entry(instance: instance, fingerprint: fingerprint, document: document)) }
        list.sort { $0.instance < $1.instance }
        scenes[scope] = list.isEmpty ? nil : list
    }

    private static let registry = CatalogRegistry<PaintAssignments>()

    static func register(_ a: PaintAssignments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var h = Hasher64()
        h.add(String(data: (try? encoder.encode(a)) ?? Data(), encoding: .utf8) ?? "")
        let key = "p" + String(h.value, radix: 36)
        registry.register(a, key: key)
        return key
    }

    static func resolve(_ key: String) -> PaintAssignments {
        key.isEmpty ? launch : registry.registered(key) ?? launch
    }
}
