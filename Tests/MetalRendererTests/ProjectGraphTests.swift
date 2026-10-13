import XCTest
import simd
@testable import MetalRenderer

/// The Project Graph: scenes' outlines (Scene+Outline.swift), their edits (SceneOverrides), the project's graph
/// (ProjectGraph) and its layouts.
final class ProjectGraphTests: XCTestCase {
    private func outline(_ s: SceneSettings) -> SceneOutline {
        var o = Scene(s).makeOutline()
        o.buildMs = 0
        return o
    }

    private func node(_ o: SceneOutline, _ id: String) -> SceneOutline.Node? { o.nodes.first { $0.id == id } }

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
        XCTAssertTrue(spinning.assets.contains(AssetKey(kind: .mesh, name: "cube", local: true)))
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
