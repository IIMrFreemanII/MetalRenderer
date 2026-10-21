import EngineCore
import Foundation
import Plants

/// The scenes' outlines on disk: Assets/Scenes/Outlines/<scene>.json, one per kind of scene (its last one made), so the
/// Project Graph knows the scenes that aren't loaded. The renderer writes a scene's when it installs it (off its thread);
/// `METALRENDERER_BENCH=outlines` makes every scene once, headless, to write them all.
package enum OutlineStore {
    package static var folder: URL? { SceneOverrides.folder?.appendingPathComponent("Outlines") }

    /// This run writes outlines: the app, or the indexing benchmark (`METALRENDERER_INDEX_OUTLINES=1` makes any
    /// benchmark write them too).
    package static let writes: Bool = !Benchmark.isEnabled || indexing
    package static let indexing = ProcessInfo.processInfo.environment["METALRENDERER_BENCH"] == "outlines"
        || ProcessInfo.processInfo.environment["METALRENDERER_INDEX_OUTLINES"] == "1"

    private static let queue = DispatchQueue(label: "outlines", qos: .utility)
    private static var written: [String: Data] = [:]     // by file, what is in it (the queue's)

    package static func url(kind: String) -> URL? { folder?.appendingPathComponent(kind + ".json") }

    /// Writes `outline` unless its file has it already. `wait`: before returning (a benchmark quits when done).
    package static func save(_ outline: SceneOutline, wait: Bool = false) {
        guard writes, let url = url(kind: outline.kind) else { return }
        var o = outline
        o.buildMs = 0   // (not part of what changes the file)
        let work = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(o) else { return }
            if written[url.path] == data { return }
            if written[url.path] == nil, let old = try? Data(contentsOf: url), old == data { written[url.path] = data; return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                written[url.path] = data
                if indexing { print("Outline: \(outline.title): \(outline.nodes.count) nodes, \(outline.instanceCount) instances") }
            } catch {
                print("Outline: can't write \(url.lastPathComponent): \(error)")
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Every saved outline, by kind (SceneKind.envName).
    package static func loadAll(from folder: URL? = OutlineStore.folder) -> [String: SceneOutline] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var out: [String: SceneOutline] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let o = try? JSONDecoder().decode(SceneOutline.self, from: data), o.format == SceneOutline.currentFormat else {
                print("Outline: \(name) doesn't read (made by an older build?)")
                continue
            }
            out[o.kind] = o
        }
        return out
    }
}
