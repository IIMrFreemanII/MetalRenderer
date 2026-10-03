import XCTest
import simd
@testable import MetalRenderer

/// BVH.swift: the binned-SAH builder splits big ranges in parallel. A node's split depends only on its own range, so
/// the tree must be the one a single thread builds, node for node (the virtual-geometry cache files hold such trees).
final class BVHTests: XCTestCase {
    private func boxes(_ n: Int, seed: UInt64, spread: Float = 10) -> [AABB] {
        var rng = SplitMix64(seed: seed)
        return (0..<n).map { _ in
            var b = AABB()
            let c = SIMD3<Float>(rng.next(), rng.next(), rng.next()) * spread
            b.grow(c)
            b.grow(c + SIMD3<Float>(rng.next(), rng.next(), rng.next()) * 0.2)
            return b
        }
    }

    private func assertSameTree(_ a: (nodes: [BVHBuilder.Node], order: [Int]), _ b: (nodes: [BVHBuilder.Node], order: [Int]),
                                _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.order, b.order, "\(what): order", file: file, line: line)
        XCTAssertEqual(a.nodes.count, b.nodes.count, "\(what): node count", file: file, line: line)
        for (i, (x, y)) in zip(a.nodes, b.nodes).enumerated() {
            let same = x.left == y.left && x.right == y.right && x.start == y.start && x.count == y.count && x.mask == y.mask
                && x.box.lo == y.box.lo && x.box.hi == y.box.hi
            if !same { return XCTFail("\(what): node \(i) differs", file: file, line: line) }
        }
    }

    func testParallelBuildIsTheSerialBuild() {
        for (n, maxLeaf) in [(1, 4), (2, 4), (7, 1), (1000, 4), (50_000, 4), (50_000, 1)] {
            let b = boxes(n, seed: UInt64(n) &+ UInt64(maxLeaf))
            var rng = SplitMix64(seed: 7)
            let masks: [UInt32]? = maxLeaf == 1 ? (0..<n).map { _ in UInt32(1) << UInt32(rng.next() * 4) } : nil
            let serial = BVHBuilder.build(boxes: b, masks: masks, maxLeaf: maxLeaf, grain: .max)
            for grain in [1, 64, 5000] {
                assertSameTree(serial, BVHBuilder.build(boxes: b, masks: masks, maxLeaf: maxLeaf, grain: grain),
                               "\(n) boxes, leaves of \(maxLeaf), grain \(grain)")
            }
            // Every primitive is in exactly one leaf.
            XCTAssertEqual(serial.order.sorted(), Array(0..<n))
            XCTAssertEqual(serial.nodes.filter { $0.left < 0 }.reduce(0) { $0 + $1.count }, n)
        }
    }

    /// All centroids in one place: no axis to split on, so ranges are cut in half.
    func testCoincidentBoxes() {
        var one = AABB()
        one.grow(SIMD3<Float>(1, 2, 3))
        one.grow(SIMD3<Float>(2, 3, 4))
        let b = [AABB](repeating: one, count: 3000)
        assertSameTree(BVHBuilder.build(boxes: b, masks: nil, maxLeaf: 4, grain: .max),
                       BVHBuilder.build(boxes: b, masks: nil, maxLeaf: 4, grain: 100), "coincident boxes")
    }

    func testEmpty() {
        XCTAssertTrue(BVHBuilder.build(boxes: [], masks: nil, maxLeaf: 4).nodes.isEmpty)
    }
}
