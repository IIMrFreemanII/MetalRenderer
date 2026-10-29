import XCTest
import simd
@testable import EngineCore
@testable import Plants

/// The bud-based grower (Growth): what its plants must be whatever its parameters, and what its parts do.
final class GrowerTests: XCTestCase {
    private var tree: Growth.Params {
        var p = Growth.Params()
        p.cycles = 24
        p.targetHeight = 8
        p.maxGeneration = 3
        p.trunk.segment = 0.4
        var b = Growth.Shoot()
        b.segment = 0.3
        b.axillaryRamp = .linear(0.3, 1)
        p.branch = b
        return p
    }

    private func height(_ s: Foliage.Skeleton) -> Float { s.nodes.map(\.y).max() ?? 0 }

    func testTheSameSeedGrowsTheSamePlant() {
        let a = Growth.grow(tree, seed: 9), b = Growth.grow(tree, seed: 9), c = Growth.grow(tree, seed: 10)
        XCTAssertEqual(a.nodes, b.nodes)
        XCTAssertEqual(a.stems.count, b.stems.count)
        XCTAssertNotEqual(a.nodes, c.nodes)
    }

    func testStemsHangOnEarlierStemsAndStartOnThem() {
        let s = Growth.grow(tree, seed: 3)
        XCTAssertGreaterThan(s.stems.count, 5)
        XCTAssertEqual(s.stems[0].level, 0)
        XCTAssertEqual(s.stems[0].parent, -1)
        for (i, stem) in s.stems.enumerated().dropFirst() {
            XCTAssertGreaterThanOrEqual(stem.parent, 0)
            XCTAssertLessThan(Int(stem.parent), i)
            let parent = s.stems[Int(stem.parent)]
            XCTAssertEqual(Int(stem.level), Int(parent.level) + (stem.level == parent.level ? 0 : 1))
            // Its first node is one of its parent's.
            let foot = Foliage.xyz(s.nodes[Int(stem.first)])
            let onParent = (0..<Int(parent.count)).contains { distance(Foliage.xyz(s.nodes[Int(parent.first) + $0]), foot) < 1e-4 }
            XCTAssertTrue(onParent, "stem \(i) does not start on its parent")
            XCTAssertTrue(s.nodes[Int(stem.first)..<Int(stem.first + stem.count)].allSatisfy { $0.w > 0 && $0.w.isFinite })
        }
    }

    func testOlderPlantsAreTallerAndStopAtTheirHeight() {
        let p = tree
        let sapling = Growth.grow(Growth.aged(p, .sapling), seed: 1)
        let young = Growth.grow(Growth.aged(p, .young), seed: 1)
        let mature = Growth.grow(p, seed: 1)
        XCTAssertLessThan(height(sapling), height(young))
        XCTAssertLessThan(height(young), height(mature))
        var long = p
        long.cycles = 120
        // (The trunk's last internode may start just under the target, and the branches sag or reach a little.)
        XCTAssertLessThan(height(Growth.grow(long, seed: 1)), p.targetHeight + 2 * p.trunk.segment + 1)
    }

    func testWoodIsThickestAtTheFoot() {
        let s = Growth.grow(tree, seed: 4)
        let trunk = s.stems[0]
        let foot = s.nodes[Int(trunk.first)].w, tip = s.nodes[Int(trunk.first + trunk.count - 1)].w
        XCTAssertGreaterThan(foot, tip * 5)
        // A child is never thicker than the point it grows from.
        for stem in s.stems.dropFirst() {
            let parent = s.stems[Int(stem.parent)]
            let thickest = (0..<Int(parent.count)).map { s.nodes[Int(parent.first) + $0].w }.max()!
            XCTAssertLessThanOrEqual(s.nodes[Int(stem.first) + 1].w, thickest + 1e-5)
        }
    }

    func testDominanceKeepsBudsDormant() {
        var free = tree, dominant = tree
        free.apicalDominance = 0
        dominant.apicalDominance = 0.95
        dominant.auxinFalloff = 0.05
        XCTAssertLessThan(Growth.grow(dominant, seed: 2).stems.count, Growth.grow(free, seed: 2).stems.count)
    }

    func testOpenSkyIsLitAndACanopyShades() {
        var field = Growth.LightField(height: 8, cell: 0.4)
        var points = [Growth.Point]()
        func point(_ p: SIMD3<Float>) -> Growth.Point {
            Growth.Point(position: p, direction: [0, 1, 0], lateral: [1, 0, 0], parent: -1, branch: 0, segment: 0.4,
                         radius: 0.01, fromRoot: 0, lightDirection: [0, 1, 0])
        }
        points.append(point([0, 1, 0]))                 // under the canopy
        points.append(point([3, 1, 0]))                 // beside it, in the open
        for x in -2...2 { for z in -2...2 { points.append(point([Float(x) * 0.4, 3, Float(z) * 0.4])) } }
        field.measure(&points, Growth.Light(), up: [0, 1, 0])
        XCTAssertGreaterThan(points[1].light, 0.95)
        XCTAssertLessThan(points[0].light, 0.5)
        // The shaded bud's light leads out from under the canopy.
        XCTAssertGreaterThan(points[0].lightDirection.y, 0)
    }

    func testTheGrownOakBuildsASoundPlant() {
        let def = PlantCatalog.builtIn[.oak]
        XCTAssertNotNil(def.growth)
        let palette = (0..<def.paletteSize).map { Growth.twig(def.twigs!, variant: $0, seed: UInt64($0)) }
        let plant = Foliage.plant(.oak, age: .mature, seed: 5, palette: palette)
        XCTAssertGreaterThan(plant.height, 6)
        XCTAssertGreaterThan(plant.parts.count, 50)
        for mesh in plant.meshes { XCTAssertEqual(Foliage.problems(mesh), []) }
    }
}
