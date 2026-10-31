import XCTest
import Metal
import simd
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Landscape
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// What virtual geometry's cuts assume of the DAG.
final class VGStreamerTests: XCTestCase {
    /// A bumpy grid of `n` x `n` quads, made into a cluster DAG of a few levels (also VGCutTests').
    static let mesh: VirtualMesh = {
        let n = 96
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        for z in 0...n {
            for x in 0...n { positions.append([Float(x), 0.3 * sin(Float(x) * 0.7) * cos(Float(z) * 0.5), Float(z)]) }
        }
        for z in 0..<n {
            for x in 0..<n {
                let a = UInt32(z * (n + 1) + x), b = a + 1, c = a + UInt32(n + 1), d = c + 1
                indices += [a, b, d, a, d, c]
            }
        }
        return VirtualGeometryBuilder.build(positions: positions, normals: Array(repeating: [0, 1, 0], count: positions.count),
                                            uvs: Array(repeating: .zero, count: positions.count), indices: indices, name: "grid") { _ in }
    }()

    /// VirtualBLAS's cut tests a group once for all its clusters (VirtualBLAS.selection): every cluster of a group must
    /// have the group's parent sphere and error.
    func testClustersShareTheirGroupsParentTest() {
        let m = VGStreamerTests.mesh
        XCTAssertGreaterThan(m.groups.count, 4)
        for g in m.groups {
            let first = m.clusters[Int(g.clusterStart)]
            for c in m.clusters[Int(g.clusterStart)..<Int(g.clusterStart + g.clusterCount)] {
                XCTAssertEqual(c.parentSphere, first.parentSphere)
                XCTAssertEqual(c.hi.w, first.hi.w)
            }
            XCTAssertEqual(first.hi.w, g.error)
        }
    }
}
