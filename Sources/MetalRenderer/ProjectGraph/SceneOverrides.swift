import Characters
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// The Project Graph's edits of scenes, per scene (MaterialAssignments.scope): things hidden, things duplicated, and
/// what only the graph shows (names, folders, where its nodes are pinned). Things are named by their outline ids
/// (SceneOutline), each with its fingerprint as the scene made it: an edit of something the builder has changed since is
/// stale and dropped, with a warning.
///
/// Saved as Assets/Scenes/Overrides/<scene>.json, one file per kind of scene. The hidden and duplicated things change
/// the scene: a registry key of them is `SceneSettings.sceneOverrides` ("" the saved ones), and a scene applies its own
/// when it is made (Scene.applySceneOverrides). The rest never makes the scene again.
package struct SceneOverrides: Codable, Equatable {
    package struct Ref: Codable, Equatable, Hashable {
        package var id: String
        package var fingerprint: String

        /// (As the memberwise initializer, for the modules above this one.)
        package init(id: String, fingerprint: String) {
            self.id = id
            self.fingerprint = fingerprint
        }
    }

    /// A copy of `source` moved by `offset` (in the world: the copy is `offset` times where the source is).
    package struct Duplicate: Codable, Equatable {
        package var id: String
        package var name: String
        package var source: Ref
        package var offset: [Float]

        package var matrix: float4x4 {
            guard offset.count == 16 else { return matrix_identity_float4x4 }
            return float4x4(SIMD4(offset[0], offset[1], offset[2], offset[3]), SIMD4(offset[4], offset[5], offset[6], offset[7]),
                            SIMD4(offset[8], offset[9], offset[10], offset[11]), SIMD4(offset[12], offset[13], offset[14], offset[15]))
        }

        package static func flat(_ m: float4x4) -> [Float] {
            [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }

        /// (As the memberwise initializer, for the modules above this one.)
        package init(id: String, name: String, source: Ref, offset: [Float]) {
            self.id = id
            self.name = name
            self.source = source
            self.offset = offset
        }
    }

    /// One scene's.
    package struct Scope: Codable, Equatable {
        package var renames: [String: String] = [:]
        /// A node's folder in the graph (a path, "Props/Crates"), instead of where the scene has it.
        package var folders: [String: String] = [:]
        package var hidden: [Ref] = []
        package var duplicates: [Duplicate] = []
        /// The force layout's pinned nodes: x, y.
        package var pins: [String: [Float]] = [:]

        package var isEmpty: Bool { renames.isEmpty && folders.isEmpty && hidden.isEmpty && duplicates.isEmpty && pins.isEmpty }
        /// What changes the scene.
        package var structural: Scope { Scope(hidden: hidden, duplicates: duplicates) }
    }

    package var scopes: [String: Scope] = [:]

    package subscript(scope: String) -> Scope {
        get { scopes[scope] ?? Scope() }
        set { scopes[scope] = newValue.isEmpty ? nil : newValue }
    }

    /// Only what changes scenes (the settings' key).
    package var structural: SceneOverrides {
        SceneOverrides(scopes: scopes.compactMapValues { $0.structural.isEmpty ? nil : $0.structural })
    }

    // MARK: - Files

    /// Assets/Scenes (outlines and overrides); `METALRENDERER_SCENES`: another folder, or "none" for no files.
    package static var folder: URL? {
        switch ProcessInfo.processInfo.environment["METALRENDERER_SCENES"] {
        case "none": return nil
        case let path? where !path.isEmpty: return URL(fileURLWithPath: path)
        default: return Scene.assetsDirectory.appendingPathComponent("Scenes")
        }
    }

    /// The file a scope's edits are in: its kind's.
    package static func fileName(scope: String) -> String {
        String(scope.split(separator: ",").first ?? Substring(scope)) + ".json"
    }

    private struct File: Codable {
        package var format = 1
        package var scopes: [String: Scope]
    }

    package static func load(from folder: URL?) -> SceneOverrides {
        guard let dir = folder?.appendingPathComponent("Overrides"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return SceneOverrides() }
        var out = SceneOverrides()
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let file = try? JSONDecoder().decode(File.self, from: data) else {
                print("Project Graph: can't read Scenes/Overrides/\(name)")
                continue
            }
            for (scope, s) in file.scopes { out.scopes[scope] = s }
        }
        return out
    }

    /// Writes the files of the scopes' kinds that differ from `saved` (a kind left without edits: its file goes).
    package func save(to folder: URL, comparedTo saved: SceneOverrides?) throws {
        let dir = folder.appendingPathComponent("Overrides")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = Set((scopes.keys.map(SceneOverrides.fileName) + (saved?.scopes.keys.map(SceneOverrides.fileName) ?? [])))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for name in files {
            let mine = scopes.filter { SceneOverrides.fileName(scope: $0.key) == name }
            if let saved, mine == saved.scopes.filter({ SceneOverrides.fileName(scope: $0.key) == name }) { continue }
            let url = dir.appendingPathComponent(name)
            if mine.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try encoder.encode(File(scopes: mine)).write(to: url, options: .atomic)
            }
        }
    }

    package static let launch = SceneOverrides.load(from: folder)

    // MARK: - Registry

    private static let registry = CatalogRegistry<SceneOverrides>()

    /// `a`'s scene edits under a key for the settings (`a` holding only those: `structural`).
    package static func register(_ a: SceneOverrides) -> String {
        let s = a.structural
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var h = Hasher64()
        h.add(String(data: (try? encoder.encode(s)) ?? Data(), encoding: .utf8) ?? "")
        let key = "o" + String(h.value, radix: 36)
        registry.register(s, key: key)
        return key
    }

    package static func resolve(_ key: String) -> SceneOverrides {
        key.isEmpty ? launch : registry.registered(key) ?? launch
    }
}

extension Scene {
    /// What the Project Graph's edits made of the scene: the duplicates' instances and lights (by their ids), and what
    /// was hidden (the outline still lists it, as hidden, where it was).
    package struct AppliedOverrides {
        var duplicates: [(edit: SceneOverrides.Duplicate, instances: [Int], lights: [Int])] = []
        var hidden: Set<String> = []
        /// Hidden instances' transforms as they were made (they are shrunk away): the outline's bounds.
        var hiddenTransforms: [Int: float4x4] = [:]
        /// The hidden lights (taken out of `lights`).
        var hiddenLights: [Light] = []
        var notes: [String] = []
    }

    /// The scene's edits (SceneSettings.sceneOverrides): each whose thing is still what it was is applied. A hidden
    /// instance stays (other things name instances by their place) but is shrunk to nothing at its centre with no mask; a
    /// hidden light is taken out. A duplicate is a copy added after everything else, moved by its offset (an animated
    /// one moves as its source does, so far off).
    package func applySceneOverrides() {
        guard worldPlace == nil else { return }
        let scope = SceneOverrides.resolve(settings.sceneOverrides)[MaterialAssignments.scope(settings)]
        guard !scope.hidden.isEmpty || !scope.duplicates.isEmpty else { return }
        let outline = makeOutline()
        var byID: [String: Int] = [:]
        for (n, node) in outline.nodes.enumerated() { byID[node.id] = n }
        var children: [Int: [Int]] = [:]
        for (n, node) in outline.nodes.enumerated() where node.parent >= 0 { children[node.parent, default: []].append(n) }
        var applied = AppliedOverrides()

        /// The instances and lights a node stands for (its descendants' too), and its fingerprint; nil if it is gone.
        func things(_ id: String) -> (instances: [Int], lights: [Int], fingerprint: String, locked: String?)? {
            if let n = byID[id] {
                var instances: [Int] = [], lights: [Int] = [], locked: String?
                var stack = [n]
                while let m = stack.popLast() {
                    let node = outline.nodes[m]
                    if let l = node.light { lights.append(l) } else { instances += Array(node.members) }
                    if locked == nil { locked = node.locked }
                    stack += children[m] ?? []
                }
                return (instances, lights, outline.nodes[n].fingerprint ?? "", locked)
            }
            // An aggregate's member: its instance.
            guard let (agg, k) = SceneOutline.member(of: id), let n = byID[agg], outline.nodes[n].kind == .aggregate,
                  let i = outline.nodes[n].members[k] else { return nil }
            return ([i], [], outlineFingerprint(i), outline.nodes[n].locked)
        }

        let lightByOrder = Dictionary(uniqueKeysWithValues: lights.indices.map { (lights[$0].order, $0) })
        for d in scope.duplicates {
            guard let source = things(d.source.id) else { applied.notes.append("\(d.name): its source \(d.source.id) is gone"); continue }
            guard source.fingerprint == d.source.fingerprint else { applied.notes.append("\(d.name): its source changed"); continue }
            guard source.locked == nil else { applied.notes.append("\(d.name): \(source.locked!)"); continue }
            let offset = d.matrix
            var made: [Int] = [], madeLights: [Int] = []
            for i in source.instances {
                var copy = instances[i]
                copy.transform = offset * copy.transform
                copy.prevTransform = copy.transform
                copy.normalMatrix = copy.transform.inverse.transpose
                if let animation = copy.animation { copy.animation = { t in offset * animation(t) } }
                made.append(appendInstance(copy))
            }
            for order in source.lights {
                guard let l = lightByOrder[order], !lights[l].kind.isSun, !lights[l].isMesh else { continue }
                let original = lights[l], pose = original.pose
                let added = addLight(original.kind, color: original.color, motion: original.motion) { t in
                    func moved(_ v: SIMD3<Float>, _ w: Float) -> SIMD3<Float> { let q = offset * SIMD4(v, w); return SIMD3(q.x, q.y, q.z) }
                    var p = pose(t)
                    p.position = moved(p.position, 1)
                    p.direction = moved(p.direction, 0)
                    p.tangent = p.tangent.map { moved($0, 0) }
                    return p
                }
                madeLights.append(lights[added].order)
            }
            applied.duplicates.append((d, made, madeLights))
        }
        var hiddenLightOrders = Set<Int>()
        for ref in scope.hidden {
            guard let t = things(ref.id) else { applied.notes.append("hidden \(ref.id) is gone"); continue }
            guard t.fingerprint == ref.fingerprint else { applied.notes.append("hidden \(ref.id) changed since"); continue }
            guard t.locked == nil else { applied.notes.append("\(ref.id) can't be hidden: \(t.locked!)"); continue }
            applied.hidden.insert(ref.id)
            for i in t.instances { hide(i, &applied) }
            hiddenLightOrders.formUnion(t.lights)
        }
        if !hiddenLightOrders.isEmpty {
            for l in lights.indices where hiddenLightOrders.contains(lights[l].order) && !lights[l].isMesh {
                if lights[l].proxyInstance >= 0 { hide(lights[l].proxyInstance, &applied) }
                applied.hiddenLights.append(lights[l])
            }
            removeLights { hiddenLightOrders.contains($0.order) && !$0.isMesh }
        }
        for note in applied.notes { print("Project Graph: \(note)") }
        sceneOverrides = applied
    }

    private func hide(_ i: Int, _ applied: inout AppliedOverrides) {
        guard instances.indices.contains(i), applied.hiddenTransforms[i] == nil else { return }
        applied.hiddenTransforms[i] = instances[i].transform
        let centre = worldBounds(of: i).centroid
        let gone = translate(centre) * scale(1e-4)
        editInstance(i) {
            $0.mask = 0
            $0.animation = nil
            $0.poseAnimated = false
            $0.transform = gone
            $0.prevTransform = gone
            $0.normalMatrix = gone.inverse.transpose
        }
    }
}
