import XCTest
import Metal
import simd
@testable import MetalRenderer

/// Virtual geometry's streaming (VGStreamer) and what the raster clusters' cut assumes of the DAG.
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

    /// The raster clusters' cut tests a group once for all its clusters (VGGroupRecord): every cluster of a group must
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

    /// Roots are resident from the start; a requested group comes in with every group above it, and nothing is left
    /// to do afterwards.
    func testARequestBringsItsAncestors() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let m = VGStreamerTests.mesh
        let streamer = try VGStreamer(device: device, meshes: [m], poolMB: 64, slots: 1)
        func resident() -> [Bool] {
            let table = streamer.bindPages(slot: 0).contents().bindMemory(to: UInt32.self, capacity: m.groups.count)
            return (0..<m.groups.count).map { table[$0] != .max }
        }
        XCTAssertEqual(resident(), m.groups.map(\.isRoot))
        XCTAssertTrue(streamer.isSettled)

        // A finest-level group (one no cluster was simplified from) that isn't a root.
        guard let leaf = m.groups.indices.first(where: { m.groups[$0].level == 0 && !m.groups[$0].isRoot }) else {
            throw XCTSkip("the DAG has one level")
        }
        var request = SIMD2<UInt32>(UInt32(leaf), Float(2).bitPattern)
        streamer.addRequests(&request, count: 1, frame: 1)
        XCTAssertFalse(streamer.isSettled)
        streamer.update(frame: 1, framesInFlight: 1)
        streamer.waitForCopies()
        streamer.update(frame: 2, framesInFlight: 1)
        XCTAssertTrue(streamer.isSettled)

        var wanted = Set([leaf]), stack = [leaf]
        while let g = stack.popLast() {
            let rec = m.groups[g]
            for p in m.parents[Int(rec.parentStart)..<Int(rec.parentStart + rec.parentCount)] where wanted.insert(Int(p)).inserted {
                stack.append(Int(p))
            }
        }
        let now = resident()
        for g in wanted { XCTAssertTrue(now[g], "group \(g), above the requested one, isn't resident") }
        XCTAssertEqual(streamer.stats.residentGroups, now.filter { $0 }.count)
    }
}
