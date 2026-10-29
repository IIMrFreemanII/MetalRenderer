import XCTest
import simd
@testable import EngineCore
@testable import Plants

/// The grown wood's mesher (Growth.wood): sound meshes, a flared and lobed foot, generations in the UVs.
final class MesherTests: XCTestCase {
    private var params: Growth.Params { PlantCatalog.builtIn[.oak].growth! }

    func testTheWoodIsSoundAndCountedRight() {
        let s = Growth.grow(params, seed: 21)
        let mesh = Growth.wood(s, stems: nil, params.wood, up: [0, 1, 0], seed: 21)
        XCTAssertEqual(Foliage.problems(mesh), [])
        let size = Growth.woodSize(s, Array(s.stems.indices))
        XCTAssertEqual(mesh.positions.count, size.vertices)
        XCTAssertEqual(mesh.indices.count, size.indices)
        XCTAssertEqual(mesh.leafTriangles, 0)
    }

    func testTheFootIsFlaredAndLobed() {
        let s = Growth.grow(params, seed: 21)
        let mesh = Growth.wood(s, stems: [0], params.wood, up: [0, 1, 0], seed: 21)
        let r = s.nodes[Int(s.stems[0].first)].w
        let sides = Int(s.stems[0].radial)
        let foot = (0..<sides).map { length(SIMD2(mesh.positions[$0].x, mesh.positions[$0].z)) }
        XCTAssertGreaterThan(foot.max()!, r * 1.2)                                // flared
        XCTAssertGreaterThan(foot.max()! / foot.min()!, 1.08)                     // lobed
        XCTAssertTrue(mesh.normals.allSatisfy { abs(length($0) - 1) < 1e-3 })
    }

    func testUVsCarryTheGeneration() {
        let s = Growth.grow(params, seed: 21)
        for (i, stem) in s.stems.enumerated() where i % 7 == 0 {
            let mesh = Growth.wood(s, stems: [i], params.wood, up: [0, 1, 0], seed: 21)
            XCTAssertTrue(mesh.uvs.allSatisfy { Int($0.x.rounded(.down)) == Int(stem.level) }, "stem \(i)")
        }
    }

    func testNoiseKeepsBranchesOn() {
        var p = params
        p.wood.noise = 0.3
        let s = Growth.grow(p, seed: 8)
        for stem in s.stems.dropFirst() {
            let parent = s.stems[Int(stem.parent)]
            let foot = Foliage.xyz(s.nodes[Int(stem.first)])
            let gap = (0..<Int(parent.count)).map { distance(Foliage.xyz(s.nodes[Int(parent.first) + $0]), foot) }.min()!
            XCTAssertLessThan(gap, 1e-4)
        }
    }
}
