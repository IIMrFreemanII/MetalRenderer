import XCTest
import AppKit
import Metal
import SwiftUI
import simd
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Plants

/// The Project Graph: scenes' outlines (Scene+Outline.swift), their edits (SceneOverrides), the project's graph
/// (ProjectGraph) and its layouts.
final class ProjectGraphTests: XCTestCase {
    private func outline(_ s: SceneSettings) -> SceneOutline {
        var o = Scene(s).makeOutline()
        o.buildMs = 0
        return o
    }

    private func node(_ o: SceneOutline, _ id: String) -> SceneOutline.Node? { o.nodes.first { $0.id == id } }

    private final class Host: ProjectGraphHost {
        var settings = RenderSettings()
        var metalDevice: MTLDevice?
        var updates = 0
        var frames: [FrameTarget] = []
        var picked: ((MaterialPick?) -> Void)?
        private var observers: [(RenderSettings) -> Void] = []
        private var outlineObservers: [(SceneOutline) -> Void] = []
        func update(_ change: @escaping (inout RenderSettings) -> Void) {
            change(&settings)
            updates += 1
            observers.forEach { $0(settings) }
        }
        func observeSettings(_ observer: @escaping (RenderSettings) -> Void) { observers.append(observer) }
        func observeOutline(_ observer: @escaping (SceneOutline) -> Void) { outlineObservers.append(observer) }
        func send(_ o: SceneOutline) { outlineObservers.forEach { $0(o) } }
        func frame(_ target: FrameTarget) { frames.append(target) }
        var selected: [FrameTarget?] = []
        private var viewObservers: [(Int?) -> Void] = []
        func select(_ target: FrameTarget?) { selected.append(target) }
        func observeViewportSelection(_ observer: @escaping (Int?) -> Void) { viewObservers.append(observer) }
        func click(_ instance: Int?) { viewObservers.forEach { $0(instance) } }
        func pickMaterial(_ picked: @escaping (MaterialPick?) -> Void) { self.picked = picked }
        func cancelPick() { picked?(nil); picked = nil }
    }

    private func model(folder: URL? = nil) -> (ProjectGraphModel, Host) {
        let host = Host()
        host.settings.scene.kind = .cornell
        let outlines = ["cornell": outline(SceneSettings(kind: .cornell)), "physics": outline(SceneSettings(kind: .physics))]
        let m = ProjectGraphModel(host: host, folder: folder, outlines: outlines, saved: SceneOverrides(),
                                  library: [AssetKey(kind: .vfxGraph, name: "campfire")], loadSource: false)
        return (m, host)
    }

    // MARK: - Outlines

    func testOutlineIsStable() {
        for kind in [SceneKind.cornell, .physics] {
            let a = outline(SceneSettings(kind: kind)), b = outline(SceneSettings(kind: kind))
            XCTAssertEqual(a, b, "\(kind): the same builder makes the same outline")
            XCTAssertEqual(Set(a.nodes.map(\.id)).count, a.nodes.count, "\(kind): ids are unique")
            for (n, node) in a.nodes.enumerated() where n > 0 {
                XCTAssertLessThan(node.parent, n, "\(kind): \(node.id)'s parent comes before it")
            }
        }
    }

    func testNamedObjects() throws {
        let o = outline(SceneSettings(kind: .cornell))
        XCTAssertEqual(o.nodes[0].kind, .scene)
        let floor = try XCTUnwrap(node(o, "t:Room/Floor"))
        XCTAssertEqual(floor.kind, .object)
        XCTAssertEqual(floor.members.count, 1)
        XCTAssertEqual(o.nodes[floor.parent].id, "t:Room", "a path's folders are made for it")
        XCTAssertNotNil(floor.fingerprint)
        let warm = try XCTUnwrap(node(o, "t:Lights/Warm"))
        XCTAssertEqual(warm.kind, .light, "an object of one light is that light")
        XCTAssertNotNil(warm.bounds)
        // The lights' shapes are their lights', not objects of their own.
        XCTAssertNil(o.nodes.first { $0.kind == .system && $0.name == "Meshes" })
        XCTAssertEqual(o.nodes[0].count, 13, "10 objects and 3 lights")
        let spinning = try XCTUnwrap(node(o, "t:Spinning cube"))
        XCTAssertEqual(spinning.info["Moves"], "animated")
        XCTAssertTrue(spinning.assets.contains(AssetKey(kind: .mesh, name: "box", local: true)))
    }

    func testSystemsAndAggregates() throws {
        let o = outline(SceneSettings(kind: .physics))
        // The dropped shapes are bodies: grouped by what they are, many of one shape an aggregate.
        let dropped = try XCTUnwrap(node(o, "t:Dropped shapes"))
        let d = try XCTUnwrap(o.nodes.firstIndex(of: dropped))
        let children = o.nodes.filter { $0.parent == d }
        let leaves = o.nodes.filter { $0.parent == d || ($0.parent >= 0 && o.nodes[$0.parent].parent == d) }.filter { !$0.members.isEmpty }
        XCTAssertFalse(leaves.isEmpty)
        XCTAssertTrue(leaves.allSatisfy { $0.locked != nil }, "bodies can't be hidden: the physics moves them")
        let total = children.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, dropped.count)
        for c in children where c.kind == .aggregate {
            XCTAssertGreaterThan(c.members.count, Scene.outlineGroupLimit)
        }
        // Every instance has one node at most.
        var seen = Set<Int>()
        for n in o.nodes { for i in n.members { XCTAssertTrue(seen.insert(i).inserted, "instance \(i) is in one node") } }
    }

    func testTagsNest() throws {
        let scene = Scene(SceneSettings(kind: .cornell)) { s in
            let cube = s.addMesh(Scene.cubeMesh())
            let m = s.addMaterial(albedo: [0.5, 0.5, 0.5])
            s.label(mesh: cube, "cube")
            s.object("Harbor") {
                s.addInstance(cube, m, matrix_identity_float4x4)
                s.object("Crane/Arm") {
                    for k in 0..<3 { s.addInstance(cube, m, translate([Float(k), 0, 0])) }
                }
            }
            s.object("Harbor") { s.addInstance(cube, m, translate([0, 5, 0])) }
            for k in 0..<30 { s.addInstance(cube, m, translate([0, 0, Float(k)])) }
        }
        let o = scene.makeOutline()
        let arm = try XCTUnwrap(node(o, "t:Harbor/Crane/Arm"))
        XCTAssertEqual(arm.kind, .object)
        XCTAssertEqual(arm.count, 3)
        XCTAssertEqual(o.nodes[arm.parent].id, "t:Harbor/Crane")
        let group = try XCTUnwrap(node(o, "t:Harbor/Crane/Arm|cube"))
        XCTAssertEqual(group.kind, .group, "a few of one thing: a group of them")
        XCTAssertNotNil(node(o, "t:Harbor/Crane/Arm|cube#2"))
        XCTAssertEqual(node(o, "t:Harbor")?.count, 4, "the harbor's own cube and the arm's three")
        XCTAssertEqual(node(o, "t:Harbor (2)")?.members.count, 1, "a second object of one name is told apart")
        let loose = try XCTUnwrap(node(o, "s:Meshes|cube"))
        XCTAssertEqual(loose.kind, .aggregate)
        XCTAssertEqual(loose.members.count, 30)
        XCTAssertEqual(loose.members[29], 34)
        XCTAssertEqual(loose.members.position(of: 34), 29)
    }

    func testCityAndForest() throws {
        var c = CitySettings()
        c.blocks = 2
        c.textures = false
        let city = SceneSettings(kind: .city, city: c, seed: 1)
        let a = outline(city), b = outline(city)
        XCTAssertEqual(a, b, "the city's outline is seeded")
        let lots = a.nodes.filter { $0.id.hasPrefix("t:Buildings/Lot ") && a.nodes[$0.parent].id == "t:Buildings" }
        XCTAssertGreaterThan(lots.count, 4)
        XCTAssertTrue(lots.allSatisfy { $0.assets.contains { $0.kind == .buildingStyle } }, "a building names its style")

        var forest = SceneSettings(kind: .forest)
        forest.trees = 150
        forest.undergrowth = 25
        let scene = Scene(forest), o = scene.makeOutline()
        print("ProjectGraph: forest of \(scene.instances.count) instances: \(o.nodes.count) nodes in \(String(format: "%.1f", o.buildMs)) ms")
        let plants = try XCTUnwrap(node(o, "s:Plants"))
        XCTAssertGreaterThan(plants.count, 150)
        let species = Set(o.nodes.filter { $0.parent == o.nodes.firstIndex(of: plants)! }.flatMap(\.assets).filter { $0.kind == .species }.map(\.name))
        XCTAssertFalse(species.isEmpty, "the plants are their species")
        XCTAssertTrue(species.allSatisfy { !$0.hasPrefix("plant ") }, "named by the species' ids: \(species)")
    }

    // MARK: - Edits

    private func ref(_ o: SceneOutline, _ id: String) throws -> SceneOverrides.Ref {
        SceneOverrides.Ref(id: id, fingerprint: try XCTUnwrap(node(o, id)).fingerprint ?? "")
    }

    func testHideAndDuplicate() throws {
        var settings = SceneSettings(kind: .cornell)
        let before = Scene(settings), o = before.makeOutline()
        var edits = SceneOverrides()
        let scope = o.scope
        edits[scope].hidden = [try ref(o, "t:Blue ball"), try ref(o, "t:Lights/Warm")]
        edits[scope].duplicates = [SceneOverrides.Duplicate(id: "copy:1", name: "Tall box 2", source: try ref(o, "t:Tall box"),
                                                             offset: SceneOverrides.Duplicate.flat(translate([3, 0, 0])))]
        settings.sceneOverrides = SceneOverrides.register(edits)
        let after = Scene(settings), edited = after.makeOutline()

        XCTAssertEqual(after.instances.count, before.instances.count + 1, "the copy is an instance more")
        XCTAssertEqual(after.lights.filter { !$0.isMesh }.count, before.lights.filter { !$0.isMesh }.count - 1, "the hidden light is out")
        let ball = try XCTUnwrap(node(edited, "t:Blue ball"))
        XCTAssertTrue(ball.hidden, "a hidden thing stays in the outline")
        XCTAssertEqual(after.instances[ball.members.first!].mask, 0)
        XCTAssertEqual(ball.bounds, try XCTUnwrap(node(o, "t:Blue ball")).bounds, "where it was")
        XCTAssertTrue(try XCTUnwrap(node(edited, "t:Lights/Warm")).hidden)
        let copy = try XCTUnwrap(node(edited, "copy:1"))
        XCTAssertEqual(copy.copyOf, "t:Tall box")
        XCTAssertEqual(edited.nodes[copy.parent].id, "scene", "beside what it copies")
        let tall = try XCTUnwrap(node(edited, "t:Tall box"))
        XCTAssertEqual(copy.bounds!.center.x, tall.bounds!.center.x + 3, accuracy: 1e-4)
        XCTAssertEqual(edited.nodes[0].count, o.nodes[0].count + 1)
        // The ids of everything else hold.
        XCTAssertEqual(Set(o.nodes.map(\.id)).subtracting(edited.nodes.map(\.id)), [])
    }

    func testStaleAndLockedEditsAreDropped() throws {
        var settings = SceneSettings(kind: .physics)
        let o = Scene(settings).makeOutline()
        var edits = SceneOverrides()
        edits[o.scope].hidden = [SceneOverrides.Ref(id: "t:Knot on a pedestal", fingerprint: "stale")]
        let body = try XCTUnwrap(o.nodes.first { $0.locked != nil && !$0.members.isEmpty })
        edits[o.scope].hidden.append(SceneOverrides.Ref(id: body.id, fingerprint: body.fingerprint ?? ""))
        settings.sceneOverrides = SceneOverrides.register(edits)
        let scene = Scene(settings)
        XCTAssertTrue(scene.sceneOverrides.hidden.isEmpty)
        XCTAssertEqual(scene.sceneOverrides.notes.count, 2)
    }

    func testOnlySceneEditsMakeTheSceneAgain() {
        var a = SceneOverrides()
        a["cornell"].renames["t:Blue ball"] = "Ball"
        a["cornell"].pins["t:Room"] = [1, 2]
        a["cornell"].folders["t:Blue ball"] = "Props"
        XCTAssertEqual(SceneOverrides.register(a), SceneOverrides.register(SceneOverrides()))
        var b = a
        b["cornell"].hidden = [SceneOverrides.Ref(id: "t:Room", fingerprint: "")]
        XCTAssertNotEqual(SceneOverrides.register(b), SceneOverrides.register(a))
        XCTAssertEqual(SceneOverrides.resolve(SceneOverrides.register(b))["cornell"].hidden.count, 1)
    }

    func testOverridesFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectGraphTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var a = SceneOverrides()
        a["cornell"].renames["t:Blue ball"] = "Ball"
        a["city,seed=1,style=mixed"].hidden = [SceneOverrides.Ref(id: "t:Buildings/Lot 3", fingerprint: "")]
        a["city,seed=2,style=mixed"].pins["s:Meshes"] = [4, 5]
        try a.save(to: folder, comparedTo: nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Overrides").path).sorted()
        XCTAssertEqual(names, ["city.json", "cornell.json"], "one file per kind of scene")
        XCTAssertEqual(SceneOverrides.load(from: folder), a)
        var b = a
        b["cornell"] = SceneOverrides.Scope()
        try b.save(to: folder, comparedTo: a)
        XCTAssertEqual(SceneOverrides.load(from: folder), b, "a kind without edits loses its file")
    }

    // MARK: - The project's graph

    private func project(_ overrides: SceneOverrides = SceneOverrides(), source: SourceIndex? = nil) -> (ProjectGraph, [String: SceneOutline]) {
        let outlines = ["cornell": outline(SceneSettings(kind: .cornell)), "physics": outline(SceneSettings(kind: .physics))]
        return (ProjectGraph.build(outlines: outlines, overrides: overrides,
                                   library: [AssetKey(kind: .species, name: "oak"), AssetKey(kind: .vfxGraph, name: "campfire")],
                                   source: source, kinds: [.cornell, .physics, .forest]), outlines)
    }

    func testMergeScenes() throws {
        let (g, outlines) = project()
        XCTAssertEqual(g.nodes[0].kind, .project)
        let cornell = try XCTUnwrap(g["scene:cornell"])
        XCTAssertTrue(cornell.indexed)
        XCTAssertEqual(cornell.count, outlines["cornell"]!.nodes[0].count)
        let forest = try XCTUnwrap(g["scene:forest"])
        XCTAssertFalse(forest.indexed, "a scene without an outline is one node")
        XCTAssertEqual(g.children[g.index["scene:forest"]!], [])
        let floor = try XCTUnwrap(g["cornell:t:Room/Floor"])
        XCTAssertEqual(g.nodes[floor.parent].id, "cornell:t:Room")
        XCTAssertEqual(ProjectGraph.split("cornell:t:Room/Floor")?.outlineID, "t:Room/Floor")
        // The box is the Cornell room's own (local) mesh, used by four things: one node they all link to.
        let cube = try XCTUnwrap(g.index["asset:cornell|mesh|box"])
        let users = g.edges.filter { $0.b == cube && $0.kind == .sharedAsset }
        XCTAssertGreaterThanOrEqual(users.count, 3)
        // The library's assets are there, used or not.
        XCTAssertNotNil(g["asset:species|oak"])
        XCTAssertNotNil(g["asset:vfxGraph|campfire"])
        // Jointed or hanging bodies: none in this physics scene, but its links resolve when there are.
        XCTAssertTrue(g.edges.allSatisfy { g.nodes.indices.contains($0.a) && g.nodes.indices.contains($0.b) })
    }

    func testRenamesAndFolders() throws {
        var edits = SceneOverrides()
        edits["cornell"].renames["t:Blue ball"] = "Ball"
        edits["cornell"].folders["t:Blue ball"] = "Props/Small"
        edits["cornell"].folders["t:Short box"] = "@t:Room"
        edits["cornell"].folders["t:Room"] = "@t:Room/Floor"   // into its own child: refused
        let (g, _) = project(edits)
        let ball = try XCTUnwrap(g["cornell:t:Blue ball"])
        XCTAssertEqual(ball.name, "Ball")
        XCTAssertEqual(ball.info["Named in the scene"], "Blue ball")
        XCTAssertEqual(g.path(g.index["cornell:t:Blue ball"]!).map { g.nodes[$0].name }, ["Project", "Cornell room", "Props", "Small", "Ball"])
        XCTAssertEqual(g.nodes[g["cornell:t:Short box"]!.parent].id, "cornell:t:Room")
        XCTAssertEqual(g.nodes[g["cornell:t:Room"]!.parent].id, "scene:cornell")
        XCTAssertEqual(g["cornell:folder:Props"]?.count, 1)
    }

    func testVisibleGraph() throws {
        let (g, _) = project()
        let closed = g.visible(open: [])
        XCTAssertEqual(closed.nodes.map(\.id).sorted(), (["project"] + g.children[0].map { g.nodes[$0].id }).sorted(), "the project's children only")
        // Edges into closed branches go to their top shown nodes: the scenes link to the assets' branch.
        XCTAssertTrue(closed.edges.contains { closed.nodes[$0.a].id == "scene:cornell" && closed.nodes[$0.b].id == "assets" })
        let open = g.visible(open: ["scene:physics", "physics:t:Dropped shapes"])
        let dropped = try XCTUnwrap(open.index["physics:t:Dropped shapes"])
        XCTAssertFalse(open.children[dropped].isEmpty)
        let aggregate = try XCTUnwrap(g.nodes.first { $0.kind == .aggregate })
        let members = g.visible(open: Set(g.path(g.index[aggregate.id]!).map { g.nodes[$0].id }))
        let shown = members.nodes.filter { $0.member != nil && $0.node == g.index[aggregate.id] }
        XCTAssertEqual(shown.count, min(aggregate.members.count, ProjectGraph.memberPage))
        XCTAssertTrue(g.visible(open: [], kinds: [.child]).edges.isEmpty)
    }

    func testSearch() throws {
        let (g, _) = project()
        XCTAssertEqual(g.search("blue ball").first, "cornell:t:Blue ball")
        XCTAssertTrue(g.search("room").contains("cornell:t:Room"))
        let aggregate = try XCTUnwrap(g.nodes.first { $0.kind == .aggregate })
        XCTAssertEqual(g.search("\(aggregate.name) #3").first, SceneOutline.memberID(aggregate.id, 3), "an aggregate's member by its number")
    }

    func testSourceIndex() throws {
        let nodes: [[String: Any]] = [
            ["id": "b", "label": ".buildCornell()", "source_file": "Sources/MetalRenderer/Scene.swift", "source_location": "L1065"],
            ["id": "m", "label": ".addMesh()", "source_file": "Sources/MetalRenderer/Scene.swift", "source_location": "L1100"],
            ["id": "q", "label": ".quadMesh()", "source_file": "Sources/MetalRenderer/Meshes.swift", "source_location": "L10"],
            ["id": "p", "label": "PhysicsWorld", "source_file": "Sources/MetalRenderer/Physics.swift", "source_location": "L20"],
        ]
        let links: [[String: Any]] = [["source": "b", "target": "m", "relation": "calls"], ["source": "b", "target": "q", "relation": "calls"],
                                      ["source": "b", "target": "q", "relation": "references"]]
        var index = SourceIndex(nodes: nodes, links: links)
        XCTAssertEqual(index.scenes["cornell"], [SourceIndex.File(path: "Sources/MetalRenderer/Scene.swift", line: 1065),
                                                 SourceIndex.File(path: "Sources/MetalRenderer/Meshes.swift", line: nil)])
        XCTAssertEqual(index.systems["Physics"]?.first?.path, "Sources/MetalRenderer/Physics.swift")
        let (g, _) = project(source: index)
        let file = try XCTUnwrap(g.index["src:Sources/MetalRenderer/Meshes.swift"])
        XCTAssertTrue(g.edges.contains { $0.b == file && $0.a == g.index["scene:cornell"] && $0.kind == .source })
        // A system's files: those of a scene of untagged things.
        let loose = Scene(SceneSettings(kind: .cornell)) { s in s.addInstance(s.addMesh(Scene.cubeMesh()), s.addMaterial(albedo: .one), matrix_identity_float4x4) }
            .makeOutline()
        let system = try XCTUnwrap(loose.nodes.first { $0.kind == .system })
        index.systems[system.name] = index.systems["Physics"]
        let h = ProjectGraph.build(outlines: ["cornell": loose], source: index, kinds: [.cornell])
        XCTAssertTrue(h.edges.contains { $0.kind == .source && h.nodes[$0.a].id == "cornell:\(system.id)" })
    }

    func testTheRepositorysSourceIndex() throws {
        let start = Date()
        guard let index = SourceIndex.load() else { throw XCTSkip("no graphify-out/graph.json") }
        print(String(format: "ProjectGraph: source index read in %.2f s: %d scenes, %d systems", Date().timeIntervalSince(start),
                     index.scenes.count, index.systems.count))
        print("ProjectGraph: cornell:", index.scenes["cornell"]?.map { "\($0.path):\($0.line ?? 0)" } ?? [])
        XCTAssertNotNil(index.scenes["cornell"], "the builders are in the graph")
    }

    func testOutlineFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectGraphTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let o = outline(SceneSettings(kind: .cornell))
        let encoder = JSONEncoder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(o).write(to: folder.appendingPathComponent("cornell.json"))
        try Data("not an outline".utf8).write(to: folder.appendingPathComponent("broken.json"))
        XCTAssertEqual(OutlineStore.loadAll(from: folder), ["cornell": o])
    }

    // MARK: - Layouts

    /// A tree of `n` nodes, each node's parent one of those before it (seeded).
    private func tree(_ n: Int, seed: UInt64 = 1) -> LayoutTree {
        var rng = SplitMix(seed: seed)
        let parent = (0..<n).map { $0 == 0 ? -1 : Int(rng.next() % UInt64(min($0, 1 + $0 / 3))) }
        return LayoutTree(parent: parent, radius: (0..<n).map { _ in 6 + 6 * rng.float() }, links: [(3, n - 1), (5, n / 2)])
    }

    func testLayoutsAreDeterministic() {
        let t = tree(300)
        XCTAssertEqual(RadialLayout.place(t), RadialLayout.place(t))
        XCTAssertEqual(TidyTreeLayout.place(t), TidyTreeLayout.place(t))
        XCTAssertEqual(ConeTreeLayout.place(t), ConeTreeLayout.place(t))
        var a = ForceLayout(t, start: RadialLayout.place(t)), b = ForceLayout(t, start: RadialLayout.place(t))
        for _ in 0..<50 { a.step(); b.step() }
        XCTAssertEqual(a.positions, b.positions)
    }

    func testTidyTreeDoesNotOverlap() {
        let t = tree(400, seed: 3)
        let p = TidyTreeLayout.place(t)
        let depths = t.depths
        for d in Set(depths) {
            let row = (0..<t.count).filter { depths[$0] == d }.sorted { p[$0].x < p[$1].x }
            XCTAssertTrue(row.allSatisfy { p[$0].y == Float(d) * 110 })
            for (a, b) in zip(row, row.dropFirst()) {
                XCTAssertGreaterThanOrEqual(p[b].x - p[a].x, t.radius[a] + t.radius[b] - 1e-3, "depth \(d): \(a) and \(b) apart")
            }
        }
        for n in 0..<t.count where !t.children[n].isEmpty {
            let xs = t.children[n].map { p[$0].x }
            XCTAssertEqual(p[n].x, (xs.min()! + xs.max()!) / 2, accuracy: 1e-3, "a parent over its children")
        }
    }

    func testRadialRings() {
        let t = tree(200, seed: 5)
        let p = RadialLayout.place(t), depths = t.depths
        XCTAssertEqual(p[0], .zero)
        for d in Set(depths) where d > 0 {
            let radii = (0..<t.count).filter { depths[$0] == d }.map { length(p[$0]) }
            XCTAssertEqual(radii.min()!, radii.max()!, accuracy: 1e-2, "a depth is a ring")
        }
    }

    func testConeRingsHoldTheirChildren() {
        let t = tree(300, seed: 7)
        let p = ConeTreeLayout.place(t)
        for n in 0..<t.count {
            let cs = t.children[n]
            for c in cs { XCTAssertEqual(p[c].y, p[n].y - 120, accuracy: 1e-3, "a level below its parent") }
            // Siblings' cones don't meet: their centres are further apart than their own radii.
            for (a, b) in zip(cs, cs.dropFirst()) {
                let flat = SIMD2(p[a].x - p[b].x, p[a].z - p[b].z)
                XCTAssertGreaterThan(length(flat), t.radius[a] + t.radius[b] - 1e-3)
            }
        }
    }

    func testForceSettles() {
        // Three children a node: one that can lay out with every link near its length.
        let t = LayoutTree(parent: (0..<200).map { $0 == 0 ? -1 : ($0 - 1) / 3 }, radius: [Float](repeating: 8, count: 200), links: [(5, 150)])
        var f = ForceLayout(t, start: RadialLayout.place(t))
        f.pinned[0] = .zero
        var steps = 0
        while f.step() { steps += 1 }
        XCTAssertTrue(f.isSettled)
        XCTAssertLessThan(steps, 400)
        let stretch = (1..<t.count).map { k in length(f.positions[k] - f.positions[t.parent[k]]) / (70 + 16) }
        XCTAssertLessThan(stretch.reduce(0, +) / Float(stretch.count), 2.5, "children settle near their parents")
        XCTAssertGreaterThan(stretch.min()!, 0.5, "...not on top of them")
        XCTAssertEqual(f.positions[0], .zero, "a pinned node stays")
        XCTAssertTrue(f.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // Nodes don't sit on each other.
        var close = 0
        for a in 0..<t.count { for b in (a + 1)..<t.count where length(f.positions[a] - f.positions[b]) < 8 { close += 1 } }
        XCTAssertLessThan(close, 3)
    }

    // MARK: - The window's model

    func testEditsAreUndoStepsAndReachTheScene() throws {
        let (m, host) = model()
        let ball = "cornell:t:Blue ball"
        XCTAssertTrue(m.canHide(ball))
        m.setHidden([ball], true)
        XCTAssertTrue(m.isHidden(ball))
        XCTAssertEqual(host.updates, 1, "the current scene is made again")
        let key = host.settings.scene.sceneOverrides
        XCTAssertEqual(SceneOverrides.resolve(key)["cornell"].hidden.map(\.id), ["t:Blue ball"])
        m.rename(ball, to: "Ball")
        XCTAssertEqual(m.graph[ball]?.name, "Ball")
        XCTAssertEqual(host.updates, 1, "a name doesn't make the scene again")
        m.undo.undo()
        XCTAssertEqual(m.graph[ball]?.name, "Blue ball")
        m.undo.undo()
        XCTAssertFalse(m.isHidden(ball))
        XCTAssertEqual(host.updates, 2)
        m.undo.redo()
        XCTAssertTrue(m.isHidden(ball))
    }

    func testDuplicateAndDeleteACopy() throws {
        let (m, host) = model()
        let made = m.duplicate(["cornell:t:Tall box"])
        XCTAssertEqual(made, ["cornell:copy:t:Tall box~1"])
        XCTAssertEqual(SceneOverrides.resolve(host.settings.scene.sceneOverrides)["cornell"].duplicates.count, 1)
        // The scene made again: its outline has the copy.
        var settings = host.settings.scene
        settings.kind = .cornell
        var edited = Scene(settings).makeOutline()
        edited.buildMs = 0
        host.send(edited)
        XCTAssertEqual(m.graph[made[0]]?.copyOf, "cornell:t:Tall box")
        m.delete(Set(made))
        XCTAssertTrue(SceneOverrides.resolve(host.settings.scene.sceneOverrides)["cornell"].duplicates.isEmpty, "deleting a copy removes it")
        let body = try XCTUnwrap(m.graph.nodes.first { $0.scene == "physics" && $0.locked != nil })
        XCTAssertFalse(m.canHide(body.id), "a body is locked")
    }

    func testEditsOfAnotherSceneWaitForIt() throws {
        let (m, host) = model()
        let knot = "physics:t:Knot on a pedestal"
        XCTAssertTrue(m.canHide(knot))
        m.setHidden([knot], true)
        XCTAssertEqual(host.updates, 0, "the current scene isn't made again for another's edit")
        m.showInViewport(knot)
        XCTAssertEqual(host.settings.scene.kind, .physics, "showing it loads its scene")
        XCTAssertEqual(SceneOverrides.resolve(host.settings.scene.sceneOverrides)["physics"].hidden.count, 1, "with the edit")
        XCTAssertEqual(host.frames.last?.kind, .physics)
        XCTAssertFalse(try XCTUnwrap(host.frames.last).instances.isEmpty)
    }

    func testFoldersAndPins() throws {
        let (m, _) = model()
        m.move(["cornell:t:Blue ball"], toFolder: "Props")
        XCTAssertEqual(m.graph.nodes[m.graph["cornell:t:Blue ball"]!.parent].id, "cornell:folder:Props")
        m.move(["cornell:t:Short box"], into: "cornell:folder:Props")
        XCTAssertEqual(m.graph["cornell:folder:Props"]?.count, 2)
        m.move(["cornell:t:Short box"], into: "scene:cornell")
        XCTAssertEqual(m.graph.nodes[m.graph["cornell:t:Short box"]!.parent].id, "scene:cornell")
        m.setPin("cornell:t:Room", [10, 20])
        XCTAssertEqual(m.pin("cornell:t:Room"), [10, 20])
        m.setPin("asset:vfxGraph|campfire", [1, 2])
        XCTAssertEqual(m.overrides["project"].pins["asset:vfxGraph|campfire"], [1, 2])
    }

    func testSearchSelectPickAndOpen() throws {
        let (m, host) = model()
        m.query = "spinning"
        XCTAssertEqual(m.results.first, "cornell:t:Spinning cube")
        m.select("physics:t:Tower")
        XCTAssertTrue(m.isOpen("scene:physics"), "selecting opens what is above it")
        XCTAssertNotNil(m.visible.index["physics:t:Tower"])
        m.pick()
        let floor = try XCTUnwrap(m.graph["cornell:t:Room/Floor"]?.members.first)
        host.picked?(MaterialPick(instance: floor, material: 0, fingerprint: "", graph: nil, albedo: .zero, position: .zero))
        XCTAssertEqual(m.focus, "cornell:t:Room/Floor", "a click in the view selects its thing")
        var opened: [EditorTarget] = []
        m.openEditor = { opened.append($0) }
        m.activate("asset:vfxGraph|campfire")
        XCTAssertEqual(opened, [.effect("campfire")])
        m.activate("scene:physics")
        XCTAssertFalse(m.isOpen("scene:physics"), "a double-click closes a branch")
    }

    func testSelectionWithTheView() throws {
        let (m, host) = model()
        // A click in the view selects the thing's node here, and its whole object in the view.
        let floor = try XCTUnwrap(m.graph["cornell:t:Room/Floor"])
        host.click(floor.members.first)
        XCTAssertEqual(m.focus, "cornell:t:Room/Floor")
        XCTAssertEqual(host.selected.last??.instances, Array(floor.members))
        // A node selected here is selected in the view; another scene's or an asset isn't.
        m.select("cornell:t:Spinning cube")
        XCTAssertEqual(host.selected.last??.kind, .cornell)
        XCTAssertFalse(try XCTUnwrap(host.selected.last ?? nil).instances.isEmpty)
        m.select("physics:t:Tower")
        XCTAssertNil(host.selected.last ?? nil, "another scene's thing: nothing in the view")
        m.select("asset:vfxGraph|campfire")
        XCTAssertNil(host.selected.last ?? nil)
        // A click on nothing deselects.
        host.click(nil)
        XCTAssertNil(m.focus)
        XCTAssertTrue(m.selection.isEmpty)
    }

    func testEditsAreSaved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectGraphTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (m, _) = model(folder: folder)
        m.rename("cornell:t:Blue ball", to: "Ball")
        m.save()
        XCTAssertEqual(SceneOverrides.load(from: folder)["cornell"].renames["t:Blue ball"], "Ball")
    }

    func testLayoutsOfTheModel() {
        let (m, _) = model()
        for layout in GraphLayout.allCases {
            m.layout = layout
            m.settle()
            XCTAssertEqual(m.positions.count, m.visible.nodes.count, "\(layout)")
            XCTAssertTrue(m.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
        XCTAssertEqual(m.cone.count, m.visible.nodes.count)
        m.layout = .tree
        let tree = m.positions
        m.settle()
        XCTAssertEqual(m.positions, tree, "settling is the force layout's alone")
    }

    /// PROJECT_GRAPH_PNG=<folder>: the window drawn offscreen, each layout; the cone rendered into a texture.
    func testPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["PROJECT_GRAPH_PNG"] else { throw XCTSkip("PROJECT_GRAPH_PNG not set") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let host = Host()
        host.settings.scene.kind = .physics
        host.metalDevice = MTLCreateSystemDefaultDevice()
        // The repository's outlines (the indexer's), else two made here.
        var outlines = OutlineStore.loadAll()
        if outlines.isEmpty { outlines = ["cornell": outline(SceneSettings(kind: .cornell)), "physics": outline(SceneSettings(kind: .physics))] }
        let m = ProjectGraphModel(host: host, folder: nil, outlines: outlines, saved: SceneOverrides(), loadSource: true)
        let size = NSSize(width: 1400, height: 860)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: ProjectGraphView().environmentObject(m))
        window.contentView = view
        func shoot(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            m.settle()
            m.frameAll(in: m.canvasSize)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
        let deadline = Date().addingTimeInterval(5)
        while m.source == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        try shoot("1-force-project")
        for id in ["physics:t:Dropped shapes", "scene:gallery", "gallery:t:Exhibits", "assets", "assets:mesh", "assets:species"] { m.setOpen(id, true) }
        m.select("physics:t:Tower")
        try shoot("2-force-open")
        m.layout = .radial
        try shoot("3-radial")
        m.layout = .tree
        try shoot("4-tree")
        m.scope = .scene
        m.layout = .force
        m.edgeKinds.insert(.source)
        m.select("physics:t:Heavy ball")
        try shoot("5-scene-sources")
        m.scope = .project
        m.layout = .cone
        try shoot("6-cone-window")
        // The cone itself, which the window's picture leaves black (a Metal view).
        let device = try XCTUnwrap(host.metalDevice)
        let renderer = ConeTreeRenderer(device: device)
        let w = 1600, h = 1000
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = samples > 1 || format == ConeTreeRenderer.depthFormat ? .private : .shared
            return device.makeTexture(descriptor: d)
        }
        let color = try XCTUnwrap(texture(ConeTreeRenderer.colorFormat, samples: ConeTreeRenderer.samples, usage: .renderTarget))
        let resolved = try XCTUnwrap(texture(ConeTreeRenderer.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead]))
        let depth = try XCTUnwrap(texture(ConeTreeRenderer.depthFormat, samples: ConeTreeRenderer.samples, usage: .renderTarget))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.105, green: 0.11, blue: 0.122, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        m.zoom = 1
        m.pan = CGPoint(x: m.canvasSize.width / 2, y: m.canvasSize.height / 2)
        let orbit = ConeOrbit()
        let buffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        renderer.encode(ConeTreeRenderer.Scene(m, orbit: orbit, aspect: Float(w) / Float(h)), pass: pass, buffer: buffer, size: SIMD2(Float(w), Float(h)))
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        resolved.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(i, i + 2) }   // BGRA to RGBA
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32))
        pixels.withUnsafeBytes { rep.bitmapData!.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: pixels.count) }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("7-cone-metal.png"))
    }

    func testIndexRuns() throws {
        var r = IndexRuns([3, 4, 5, 9, 10, 20])
        XCTAssertEqual(Array(r), [3, 4, 5, 9, 10, 20])
        XCTAssertEqual(r.count, 6)
        XCTAssertEqual(r[3], 9)
        XCTAssertNil(r[6])
        XCTAssertEqual(r.position(of: 10), 4)
        r.append(21)
        let back = try JSONDecoder().decode(IndexRuns.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertEqual(String(data: try JSONEncoder().encode(r), encoding: .utf8), "[3,3,9,2,20,2]")
    }

    func testOutlineRoundTrips() throws {
        let o = outline(SceneSettings(kind: .cornell))
        let back = try JSONDecoder().decode(SceneOutline.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back, o)
    }
}
