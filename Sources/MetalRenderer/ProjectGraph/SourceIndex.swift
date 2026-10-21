import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants

/// Which source files make each scene and system, from graphify's graph of the code (graphify-out/graph.json in the
/// repository): a scene's builder (`Scene.buildCornell()`) and the files of what it calls; a system's type. Read in the
/// background when the Project Graph first wants it; nil when there is no graph.
package struct SourceIndex: Equatable {
    package struct File: Hashable, Comparable {
        package var path: String            // repository-relative
        package var line: Int?
        package static func < (a: File, b: File) -> Bool { (a.path, a.line ?? 0) < (b.path, b.line ?? 0) }
    }
    /// By SceneKind.envName.
    package var scenes: [String: [File]] = [:]
    /// By the outline's system names (Physics, Plants, ...).
    package var systems: [String: [File]] = [:]

    /// Each scene's builder, as its definition calls it.
    package static var builders: [SceneKind: String] {
        Dictionary(uniqueKeysWithValues: SceneRegistry.kinds.map { ($0, $0.definition.builder) })
    }

    /// The types each system is.
    package static let systemTypes: [String: [String]] = [
        "Physics": ["PhysicsWorld"], "Particles": ["ParticleSystem"], "Plants": ["Foliage", "PlantTracing"],
        "Characters": ["Crowd"], "SDF shapes": ["SDFShape"], "Buildings": ["Building", "BuildingGenerator"],
        "Fluids": ["FluidSurface"], "Soft bodies and cloth": ["PhysicsWorld"], "Effects": ["VFXLowering", "VFXEffect"],
        "Models": ["GLTFLoader", "VirtualMesh"], "Open world tiles": ["WorldTile"],
    ]

    /// At most this many files a scene: its builder's, then those it calls into most.
    package static let filesPerScene = 10

    package static var graphURL: URL { Scene.assetsDirectory.deletingLastPathComponent().appendingPathComponent("graphify-out/graph.json") }

    /// graphify's graph read: nil if there is none (or it doesn't read).
    package static func load(from url: URL = graphURL) -> SourceIndex? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]], let links = root["links"] as? [[String: Any]] else { return nil }
        return SourceIndex(nodes: nodes, links: links)
    }

    /// From graphify's nodes ({id, label, source_file, source_location}) and links ({source, target, relation}).
    package init(nodes: [[String: Any]], links: [[String: Any]]) {
        var file: [String: File] = [:], byLabel: [String: [String]] = [:]
        for n in nodes {
            guard let id = n["id"] as? String, let path = n["source_file"] as? String, path.hasPrefix("Sources/") else { continue }
            let line = (n["source_location"] as? String).flatMap { Int($0.drop { !$0.isNumber }) }
            file[id] = File(path: path, line: line)
            if let label = n["label"] as? String { byLabel[label, default: []].append(id) }
        }
        var calls: [String: [String: Int]] = [:]   // caller -> callee's file -> calls
        for l in links where (l["relation"] as? String) == "calls" {
            guard let a = l["source"] as? String, let b = l["target"] as? String, let f = file[b] else { continue }
            calls[a, default: [:]][f.path, default: 0] += 1
        }
        for (kind, builder) in SourceIndex.builders {
            let ids = (byLabel[".\(builder)()"] ?? []).filter { file[$0]?.path.contains("Scene") == true }
            guard let id = ids.sorted().first, let own = file[id] else { continue }
            let called = (calls[id] ?? [:]).filter { $0.key != own.path }
                .sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(SourceIndex.filesPerScene - 1)
            scenes[kind.envName] = [own] + called.map { File(path: $0.key, line: nil) }
        }
        for (system, types) in SourceIndex.systemTypes {
            let found = types.compactMap { t in (byLabel[t] ?? []).compactMap { file[$0] }.min() }
            if !found.isEmpty { systems[system] = found }
        }
    }

    package init() {}
}
