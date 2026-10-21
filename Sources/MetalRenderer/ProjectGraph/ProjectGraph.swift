import EngineCore
import Foundation
import Plants

/// The project as one graph: the project, its scenes and what each is made of (their outlines, SceneOutline), the assets
/// they are made from and with (one node each, which every user of it links to), the source files that make them, and
/// the links between things while a scene runs. The Project Graph window draws a part of it (`visible`): what is under
/// the nodes that are open.
///
/// Ids: a scene is "scene:<kind>", a thing in it "<kind>:<its outline id>", an asset "asset:...", a source file "src:<path>".
package struct ProjectGraph {
    package enum Kind: String {
        case project, scene, folder, system, group, aggregate, object, light, effect, tiles
        /// An aggregate's member: never in `nodes`, only in a visible graph.
        case member
        /// The assets' and the sources' branches, a kind of asset's folder, an asset, a source file.
        case assets, assetKind, asset, sources, source

        package init(_ k: SceneOutline.Kind) {
            switch k {
            case .scene: self = .scene
            case .folder: self = .folder
            case .system: self = .system
            case .group: self = .group
            case .aggregate: self = .aggregate
            case .object: self = .object
            case .light: self = .light
            case .effect: self = .effect
            case .tiles: self = .tiles
            }
        }

        /// It holds others (a disclosure in the outliner).
        package var isBranch: Bool { self != .object && self != .light && self != .effect && self != .tiles && self != .member
            && self != .asset && self != .source }
    }

    package enum EdgeKind: String, CaseIterable, Codable {
        case child, sharedAsset, generatedFrom, runtime, source

        package var title: String {
            switch self {
            case .child: return "Hierarchy"
            case .sharedAsset: return "Shared assets"
            case .generatedFrom: return "Generated from"
            case .runtime: return "Runtime couplings"
            case .source: return "Source code"
            }
        }
    }

    package struct Node {
        package var id: String
        package var parent: Int
        package var kind: Kind
        package var name: String
        /// Its scene's kind (SceneKind.envName), and its id in that scene's outline.
        package var scene: String? = nil
        package var outlineID: String? = nil
        /// The things under it (an aggregate's members).
        package var count = 0
        package var hidden = false
        package var locked: String? = nil
        package var info: [String: String] = [:]
        package var assets: [AssetKey] = []
        /// An asset's node: the asset.
        package var asset: AssetKey? = nil
        package var bounds: Box? = nil
        package var members = IndexRuns()
        package var light: Int? = nil
        package var fingerprint: String? = nil
        package var copyOf: String? = nil
        package var file: SourceIndex.File? = nil
        /// A scene: its outline is known (it was made once, or indexed).
        package var indexed = true
        package var depth = 0
    }

    package struct Edge: Hashable {
        package var a: Int
        package var b: Int
        package var kind: EdgeKind
    }

    package private(set) var nodes: [Node] = []
    package private(set) var edges: [Edge] = []
    package private(set) var children: [[Int]] = []
    package private(set) var index: [String: Int] = [:]

    package static func sceneID(_ kind: String) -> String { "scene:\(kind)" }
    package static func thingID(_ kind: String, _ outlineID: String) -> String { outlineID == "scene" ? sceneID(kind) : "\(kind):\(outlineID)" }

    /// A thing's scene and outline id, from its graph id.
    package static func split(_ id: String) -> (scene: String, outlineID: String)? {
        if id.hasPrefix("scene:") { return (String(id.dropFirst(6)), "scene") }
        guard let colon = id.firstIndex(of: ":"), !id.hasPrefix("asset:"), !id.hasPrefix("src:"), !id.hasPrefix("assets") else { return nil }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }

    package subscript(id: String) -> Node? { index[id].map { nodes[$0] } }

    // MARK: - Building

    /// The graph of `kinds`' scenes (those without an outline: one node each), with the graph's edits (names, folders),
    /// the project's assets `library` (each a node, used or not: an unused one stands alone) and the scenes' and systems'
    /// source files.
    package static func build(outlines: [String: SceneOutline], overrides: SceneOverrides = SceneOverrides(), library: [AssetKey] = [],
                      source: SourceIndex? = nil, kinds: [SceneKind] = SceneKind.allCases) -> ProjectGraph {
        var g = ProjectGraph()
        g.add(Node(id: "project", parent: -1, kind: .project, name: "Project"))
        var uses: [String: (key: AssetKey, users: [Int])] = [:]
        var hubOrder: [String] = []
        func use(_ key: AssetKey, scope: String, by n: Int) {
            let id = key.id(scope: scope)
            if uses[id] == nil { uses[id] = (key, []); hubOrder.append(id) }
            uses[id]!.users.append(n)
        }
        var links: [(String, String)] = []

        for kind in kinds {
            let env = kind.envName
            let sceneNode = g.add(Node(id: sceneID(env), parent: 0, kind: .scene, name: kind.title, scene: env, outlineID: "scene"))
            guard let o = outlines[env] else {
                g.nodes[sceneNode].indexed = false
                g.nodes[sceneNode].info["Outline"] = "not made yet: open the scene, or run METALRENDERER_BENCH=outlines"
                continue
            }
            let edits = overrides[o.scope]
            g.nodes[sceneNode].info = ["Instances": "\(o.instanceCount)", "Lights": "\(o.lightCount)", "Scope": o.scope]
            g.nodes[sceneNode].bounds = o.nodes.first?.bounds
            for a in o.nodes.first?.assets ?? [] { use(a, scope: o.scope, by: sceneNode) }
            // Each thing's own count (its children's are theirs): the totals are made again after the folders.
            var childCount = [Int](repeating: 0, count: o.nodes.count)
            for n in o.nodes where n.parent >= 0 { childCount[n.parent] += n.count }
            var mapped = [Int](repeating: sceneNode, count: o.nodes.count)
            for (k, n) in o.nodes.enumerated() where k > 0 {
                let parent = n.parent > 0 ? mapped[n.parent] : sceneNode
                var node = Node(id: thingID(env, n.id), parent: parent, kind: Kind(n.kind), name: edits.renames[n.id] ?? n.name,
                                scene: env, outlineID: n.id, count: max(n.count - childCount[k], 0), hidden: n.hidden,
                                locked: n.locked, info: n.info, assets: n.assets, bounds: n.bounds, members: n.members,
                                light: n.light, fingerprint: n.fingerprint, copyOf: n.copyOf.map { thingID(env, $0) })
                if edits.renames[n.id] != nil { node.info["Named in the scene"] = n.name }
                mapped[k] = g.add(node)
                if n.kind != .group { for a in n.assets { use(a, scope: o.scope, by: mapped[k]) } }
            }
            // The graph's folders: a node moved into one (a path under the scene, or "@<id>": under that thing).
            for (id, folder) in edits.folders.sorted(by: { $0.key < $1.key }) {
                guard let n = g.index[thingID(env, id)] else { continue }
                let target: Int?
                if folder.hasPrefix("@") {
                    target = g.index[thingID(env, String(folder.dropFirst()))]
                } else if folder.isEmpty {
                    target = nil
                } else {
                    target = g.folder(folder, scene: env, under: sceneNode)
                }
                guard let t = target, !g.isAncestor(n, of: t) else { continue }
                g.nodes[n].parent = t
            }
            for l in o.links {
                links.append((g.resolve(env, l.from), g.resolve(env, l.to)))
            }
            if let files = source?.scenes[env] {
                for f in files { g.sourceEdge(from: sceneNode, f) }
            }
            if let source {
                for (k, n) in o.nodes.enumerated() where n.kind == .system {
                    for f in source.systems[n.name] ?? [] { g.sourceEdge(from: mapped[k], f) }
                }
            }
        }
        for (a, b) in links {
            guard let x = g.index[a], let y = g.index[b] else { continue }
            g.edges.append(Edge(a: x, b: y, kind: .runtime))
        }

        // The assets: the project's (used or not) and those more than one thing shares.
        for key in library {
            let id = key.id(scope: "")
            if uses[id] == nil { uses[id] = (key, []); hubOrder.append(id) }
        }
        for id in hubOrder {
            let (key, users) = uses[id]!
            // (A mesh or a material of one thing says nothing the thing doesn't: only shared ones are nodes.)
            guard key.kind.isGenerator || key.kind == .model || Set(users).count > 1 else { continue }
            let folder = g.assetFolder(key.kind)
            let hub = g.add(Node(id: id, parent: folder, kind: .asset, name: key.name, info: ["Kind": key.kind.title], asset: key))
            g.nodes[hub].info["Used by"] = "\(Set(users).count)"
            for u in Set(users).sorted() { g.edges.append(Edge(a: u, b: hub, kind: key.kind.isGenerator ? .generatedFrom : .sharedAsset)) }
        }
        g.finish()
        return g
    }

    @discardableResult
    private mutating func add(_ n: Node) -> Int {
        nodes.append(n)
        index[n.id] = nodes.count - 1
        return nodes.count - 1
    }

    /// The graph's folder `path` in a scene, made with its parents if new.
    private mutating func folder(_ path: String, scene: String, under root: Int) -> Int {
        var parent = root, sofar: [Substring] = []
        for part in path.split(separator: "/") {
            sofar.append(part)
            let id = "\(scene):folder:\(sofar.joined(separator: "/"))"
            if let f = index[id] { parent = f; continue }
            parent = add(Node(id: id, parent: parent, kind: .folder, name: String(part), scene: scene, outlineID: "folder:\(sofar.joined(separator: "/"))"))
        }
        return parent
    }

    private mutating func assetFolder(_ kind: AssetKey.Kind) -> Int {
        let root = index["assets"] ?? add(Node(id: "assets", parent: 0, kind: .assets, name: "Assets"))
        let id = "assets:\(kind.rawValue)"
        return index[id] ?? add(Node(id: id, parent: root, kind: .assetKind, name: kind.title))
    }

    private mutating func sourceEdge(from n: Int, _ f: SourceIndex.File) {
        let root = index["sources"] ?? add(Node(id: "sources", parent: 0, kind: .sources, name: "Source code"))
        let id = "src:\(f.path)"
        let file = index[id] ?? add(Node(id: id, parent: root, kind: .source, name: (f.path as NSString).lastPathComponent,
                                         info: ["File": f.path], file: SourceIndex.File(path: f.path, line: nil)))
        if nodes[file].file?.line == nil, let line = f.line, nodes[n].kind == .scene { nodes[file].info["Builder"] = "line \(line)" }
        edges.append(Edge(a: n, b: file, kind: .source))
    }

    /// An outline's id in the graph: an aggregate's member is its aggregate.
    private func resolve(_ scene: String, _ id: String) -> String {
        let full = ProjectGraph.thingID(scene, id)
        if index[full] != nil { return full }
        if let m = SceneOutline.member(of: id) { return ProjectGraph.thingID(scene, m.aggregate) }
        return full
    }

    /// `a` is `b` or above it.
    package func isAncestor(_ a: Int, of b: Int) -> Bool {
        var n = b
        while n >= 0 {
            if n == a { return true }
            n = nodes[n].parent
        }
        return false
    }

    /// Children, depths and the totals up the tree.
    private mutating func finish() {
        children = [[Int]](repeating: [], count: nodes.count)
        for (k, n) in nodes.enumerated() where n.parent >= 0 { children[n.parent].append(k) }
        // The scenes first, then the assets and the sources.
        if !children.isEmpty {
            children[0].sort { (nodes[$0].kind == .scene ? 0 : 1, $0) < (nodes[$1].kind == .scene ? 0 : 1, $1) }
        }
        var order: [Int] = [0], i = 0
        while i < order.count {
            for c in children[order[i]] { nodes[c].depth = nodes[order[i]].depth + 1; order.append(c) }
            i += 1
        }
        for n in order.reversed() where nodes[n].parent >= 0 {
            nodes[nodes[n].parent].count += nodes[n].count
        }
        edges = Array(Set(edges)).sorted { ($0.a, $0.b, $0.kind.rawValue) < ($1.a, $1.b, $1.kind.rawValue) }
    }

    /// The node's path from the project: its ancestors' names.
    package func path(_ n: Int) -> [Int] {
        var out: [Int] = [], k = n
        while k >= 0 { out.append(k); k = nodes[k].parent }
        return out.reversed()
    }

    // MARK: - What is shown

    /// Nodes are shown under open ones (and an open aggregate's members, a page at a time).
    package static let memberPage = 200

    package struct VisibleNode: Identifiable {
        package var id: String
        package var node: Int           // in `nodes` (a member's: its aggregate)
        package var member: Int?        // a member's place in its aggregate
        package var parent: Int         // in the visible graph, -1 for the project
        var depth: Int
    }

    package struct Visible {
        package var nodes: [VisibleNode] = []
        package var children: [[Int]] = []
        /// The edges between shown nodes (an edge into a closed branch goes to its top shown node), each once.
        package var edges: [(a: Int, b: Int, kind: EdgeKind)] = []
        package var index: [String: Int] = [:]

        /// (As the memberwise initializer, for the modules above this one.)
        package init(nodes: [VisibleNode] = [], children: [[Int]] = [], edges: [(a: Int, b: Int, kind: EdgeKind)] = [], index: [String: Int] = [:]) {
            self.nodes = nodes
            self.children = children
            self.edges = edges
            self.index = index
        }
    }

    /// The part of the graph under the `open` nodes: `pages` of an open aggregate's members (one page if not said), and
    /// the edges of `kinds` among them.
    /// `root`: the node it starts from (a scene, to show that scene alone).
    package func visible(open: Set<String>, pages: [String: Int] = [:], kinds: Set<EdgeKind> = Set(EdgeKind.allCases), root: Int = 0) -> Visible {
        var v = Visible()
        var shownAs = [Int](repeating: -1, count: nodes.count)
        guard nodes.indices.contains(root) else { return v }
        func add(_ vn: VisibleNode) -> Int {
            v.nodes.append(vn)
            v.children.append([])
            if vn.parent >= 0 { v.children[vn.parent].append(v.nodes.count - 1) }
            v.index[vn.id] = v.nodes.count - 1
            return v.nodes.count - 1
        }
        var queue = [(node: root, parent: -1)], q = 0
        while q < queue.count {
            let (n, parent) = queue[q]
            q += 1
            let k = add(VisibleNode(id: nodes[n].id, node: n, parent: parent, depth: parent < 0 ? 0 : v.nodes[parent].depth + 1))
            shownAs[n] = k
            guard open.contains(nodes[n].id) || n == root else { continue }
            for c in children[n] { queue.append((c, k)) }
            if nodes[n].kind == .aggregate {
                let shown = min(nodes[n].members.count, ProjectGraph.memberPage * max(pages[nodes[n].id] ?? 1, 1))
                for m in 0..<shown {
                    _ = add(VisibleNode(id: SceneOutline.memberID(nodes[n].id, m), node: n, member: m, parent: k, depth: v.nodes[k].depth + 1))
                }
            }
        }
        /// Where `n` is shown: itself, or its top shown ancestor; -1 outside the shown part.
        func shown(_ n: Int) -> Int {
            var k = n
            while k >= 0 && shownAs[k] < 0 { k = nodes[k].parent }
            return k >= 0 ? shownAs[k] : -1
        }
        // Shown from a scene: the assets and files outside it that its things link to, beside it.
        let rootShown = shownAs[root]
        func shownOrBeside(_ n: Int) -> Int {
            let k = shown(n)
            guard k < 0, nodes[n].kind == .asset || nodes[n].kind == .source else { return k }
            let made = add(VisibleNode(id: nodes[n].id, node: n, parent: rootShown, depth: 1))
            shownAs[n] = made
            return made
        }
        var seen = Set<Edge>()
        for e in edges where kinds.contains(e.kind) {
            let a = shown(e.a)
            guard a >= 0 else { continue }
            let b = shownOrBeside(e.b)
            guard b >= 0, a != b, seen.insert(Edge(a: min(a, b), b: max(a, b), kind: e.kind)).inserted else { continue }
            v.edges.append((a, b, e.kind))
        }
        return v
    }

    // MARK: - Search

    /// The ids of the nodes whose names (or ids) have `query`, the best first: an aggregate's member by "name #12".
    package func search(_ query: String, limit: Int = 200) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [(rank: Int, id: String)] = []
        // "oak #12": that member of an aggregate named so.
        if let hash = q.lastIndex(of: "#"), let k = Int(q[q.index(after: hash)...].trimmingCharacters(in: .whitespaces)) {
            let name = q[..<hash].trimmingCharacters(in: .whitespaces)
            for n in nodes where n.kind == .aggregate && n.name.lowercased().contains(name) && k < n.members.count {
                out.append((0, SceneOutline.memberID(n.id, k)))
            }
        }
        for n in nodes where n.kind != .project {
            let name = n.name.lowercased()
            if name == q { out.append((1, n.id)) }
            else if name.hasPrefix(q) { out.append((2, n.id)) }
            else if name.contains(q) { out.append((3, n.id)) }
            else if n.id.lowercased().contains(q) { out.append((4, n.id)) }
        }
        return out.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }.prefix(limit).map(\.id)
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(nodes: [Node] = [], edges: [Edge] = [], children: [[Int]] = [], index: [String: Int] = [:]) {
        self.nodes = nodes
        self.edges = edges
        self.children = children
        self.index = index
    }
}

/// The project's assets, used by a scene or not: every plant species, building style, character, VFX graph and
/// material graph the editors know (built in and saved).
package enum ProjectLibrary {
    package static func current() -> [AssetKey] {
        var out: [AssetKey] = []
        out += PlantStore.load().species.map { AssetKey(kind: .species, name: $0.id) }
        out += BuildingStore.load().styles.map { AssetKey(kind: .buildingStyle, name: $0.id) }
        out += CharacterStore.load().characters.map { AssetKey(kind: .character, name: $0.id) }
        out += Set(VFXLibrary.names + VFXCatalog.launch.effects.keys).sorted().map { AssetKey(kind: .vfxGraph, name: $0) }
        out += Set(MaterialLibrary.all.map(\.name) + MaterialCatalog.launch.graphs.keys).sorted().map { AssetKey(kind: .materialGraph, name: $0) }
        return out
    }
}
