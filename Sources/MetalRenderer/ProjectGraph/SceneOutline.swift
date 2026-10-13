import Foundation
import simd

/// What a scene is made of, as a tree: the Project Graph's view of it (ProjectGraph.swift merges the scenes'). Made by
/// the scene itself (Scene.makeOutline, Scene+Outline.swift) when it is installed, and kept as
/// Assets/Scenes/Outlines/<scene>.json (OutlineStore), so the graph knows the scenes that aren't loaded.
///
/// The tree comes from what the builders name (`Scene.object`, the meshes' labels) and, for the rest, from what the scene
/// knows of its things: each in its system (Plants, Buildings, Lights, Physics, ...) and there by what it is an instance
/// of. Many instances of one thing are one node (`aggregate`), its members found by their place in it.
///
/// Ids are stable while the builder doesn't change: they are made of names and of places in build order, never of the
/// instances' numbers. Edits (SceneOverrides) name what they change by id, with its fingerprint to tell a stale one.
struct SceneOutline: Codable, Equatable {
    static let currentFormat = 1
    var format = SceneOutline.currentFormat
    /// SceneKind.envName, its title, and MaterialAssignments.scope (the scene with what decides its order: its seed).
    var kind: String
    var title: String
    var scope: String
    /// nodes[0] is the scene; a node's parent comes before it.
    var nodes: [Node]
    /// What holds things together while the scene runs (joints, emitters of an effect).
    var links: [Link]
    var instanceCount: Int
    var lightCount: Int
    /// How long the outline took to make (ms).
    var buildMs: Double = 0

    enum Kind: String, Codable {
        case scene, folder, system
        /// A few instances of one thing: its children are them.
        case group
        /// Many instances of one thing: its members are `members`, not nodes (ProjectGraph pages them).
        case aggregate
        case object, light, effect
        /// An open world's tile group: instances made when needed, only counted.
        case tiles
    }

    struct Node: Codable, Equatable {
        var id: String
        var parent: Int
        var kind: Kind
        var name: String
        /// The instances it stands for: an object's one (or the few of a named object), an aggregate's all.
        var members = IndexRuns()
        /// A light's `Light.order`; an effect's place in `Scene.effects`.
        var light: Int? = nil
        var effect: Int? = nil
        var assets: [AssetKey] = []
        var bounds: Box? = nil
        /// The things under it (an aggregate's members, a tile group's instances).
        var count = 0
        /// What it is as the builder made it (its mesh, its size): an edit of it made before the builder changed is stale.
        var fingerprint: String? = nil
        /// Why it can't be hidden or duplicated (the physics moves it, ...); nil: it can.
        var locked: String? = nil
        /// What the inspector shows of it.
        var info: [String: String] = [:]
    }

    struct Link: Codable, Equatable, Hashable {
        enum Kind: String, Codable { case joint, attached, emits, owner }
        var from: String
        var to: String
        var kind: Kind
    }

    /// The id of an aggregate's member `k` (its place among the members), and back.
    static func memberID(_ aggregate: String, _ k: Int) -> String { "\(aggregate)#\(k)" }
    static func member(of id: String) -> (aggregate: String, k: Int)? {
        guard let hash = id.lastIndex(of: "#"), let k = Int(id[id.index(after: hash)...]) else { return nil }
        return (String(id[..<hash]), k)
    }
}

/// Something an outline's node is made from or with: a mesh, a material, a plant species, a VFX graph. `local`: the
/// scene's own (its mesh 3); otherwise the project's (a species, a model file, a graph), shared among the scenes that use it.
struct AssetKey: Codable, Hashable, Comparable {
    enum Kind: String, Codable, CaseIterable {
        case mesh, model, material, materialGraph, painterDoc, species, building, buildingStyle, character, vfxGraph, sdfShape

        var title: String {
            switch self {
            case .mesh: return "Mesh"
            case .model: return "Model"
            case .material: return "Material"
            case .materialGraph: return "Material graph"
            case .painterDoc: return "Painted texture set"
            case .species: return "Plant species"
            case .building: return "Building"
            case .buildingStyle: return "Building style"
            case .character: return "Character"
            case .vfxGraph: return "VFX graph"
            case .sdfShape: return "SDF shape"
            }
        }
        /// Made in an editor of its own (an asset of the project), not by a builder.
        var isGenerator: Bool { self == .materialGraph || self == .painterDoc || self == .species || self == .buildingStyle
            || self == .character || self == .vfxGraph }
    }
    var kind: Kind
    var name: String
    var local = false

    /// Its id in the project graph: a scene's own are that scene's.
    func id(scope: String) -> String { local ? "asset:\(scope)|\(kind.rawValue)|\(name)" : "asset:\(kind.rawValue)|\(name)" }

    static func < (a: AssetKey, b: AssetKey) -> Bool { (a.kind.rawValue, a.name) < (b.kind.rawValue, b.name) }
}

/// An axis-aligned box that encodes as two arrays.
struct Box: Codable, Equatable {
    var lo: SIMD3<Float>
    var hi: SIMD3<Float>

    init(lo: SIMD3<Float>, hi: SIMD3<Float>) { self.lo = lo; self.hi = hi }
    init?(_ b: AABB) {
        guard !b.isEmpty, b.lo.x.isFinite, b.hi.x.isFinite else { return nil }
        lo = b.lo; hi = b.hi
    }
    var aabb: AABB { AABB(lo: lo, hi: hi) }
    var center: SIMD3<Float> { (lo + hi) / 2 }

    func union(_ o: Box?) -> Box { o.map { Box(lo: simd_min(lo, $0.lo), hi: simd_max(hi, $0.hi)) } ?? self }
}

/// Indices as runs (first, count), flat in the file: an aggregate's thousands of instances are a few numbers when they
/// were added one after the other.
struct IndexRuns: Codable, Equatable, Sequence {
    private(set) var runs: [Int] = []
    private(set) var count = 0

    init() {}
    init<S: Sequence>(_ indices: S) where S.Element == Int { for i in indices { append(i) } }

    init(from decoder: Decoder) throws {
        runs = try decoder.singleValueContainer().decode([Int].self)
        count = stride(from: 1, to: runs.count, by: 2).reduce(0) { $0 + runs[$1] }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(runs)
    }

    var isEmpty: Bool { count == 0 }
    var first: Int? { runs.first }

    mutating func append(_ i: Int) {
        if runs.count >= 2, runs[runs.count - 2] + runs[runs.count - 1] == i {
            runs[runs.count - 1] += 1
        } else {
            runs += [i, 1]
        }
        count += 1
    }

    /// The `k`th index.
    subscript(k: Int) -> Int? {
        var k = k
        for r in stride(from: 0, to: runs.count, by: 2) {
            if k < runs[r + 1] { return runs[r] + k }
            k -= runs[r + 1]
        }
        return nil
    }

    /// Where `index` is among them, if it is.
    func position(of index: Int) -> Int? {
        var k = 0
        for r in stride(from: 0, to: runs.count, by: 2) {
            if index >= runs[r] && index < runs[r] + runs[r + 1] { return k + index - runs[r] }
            k += runs[r + 1]
        }
        return nil
    }

    func makeIterator() -> AnyIterator<Int> {
        var r = 0, k = 0
        return AnyIterator {
            while r < runs.count {
                if k < runs[r + 1] { defer { k += 1 }; return runs[r] + k }
                r += 2; k = 0
            }
            return nil
        }
    }
}
