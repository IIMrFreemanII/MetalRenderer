import XCTest
import simd
@testable import MetalRenderer

final class WorldCacheGridTests: XCTestCase {
    private let size = WorldCacheGrid.size

    func testSlotCellRoundTrip() {
        for origin in [SIMD3<Int32>(0, 0, 0), SIMD3<Int32>(-17, -5, -40), SIMD3<Int32>(100, -3, 33), SIMD3<Int32>(-32, -16, -32)] {
            var seen = Set<Int>()
            for slot in 0..<WorldCacheGrid.probesPerLevel {
                let c = WorldCacheGrid.cell(slot: slot, origin: origin)
                XCTAssertTrue(all(c .>= origin) && all(c .< origin &+ size))
                XCTAssertEqual(WorldCacheGrid.slot(cell: c), slot)
                seen.insert(slot)
            }
            XCTAssertEqual(seen.count, WorldCacheGrid.probesPerLevel)
        }
    }

    func testMovingKeepsSlots() {
        let o0 = SIMD3<Int32>(-20, -8, 5)
        for k in [SIMD3<Int32>(1, 0, 0), SIMD3<Int32>(-3, 2, -7), SIMD3<Int32>(40, -1, 0)] {
            let o1 = o0 &+ k
            for slot in 0..<WorldCacheGrid.probesPerLevel {
                let c = WorldCacheGrid.cell(slot: slot, origin: o0)
                if all(c .>= o1) && all(c .< o1 &+ size) {
                    XCTAssertEqual(WorldCacheGrid.cell(slot: WorldCacheGrid.slot(cell: c), origin: o1), c)
                }
            }
        }
    }

    func testFollowNegative() {
        var g = WorldCacheGrid(levels: 3, spacing: 2)
        let cam = SIMD3<Float>(-5.5, -0.1, -100)
        g.follow(camera: cam)
        for l in 0..<3 {
            let f = (cam / g.spacing[l]).rounded(.down)
            let cell = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z))
            XCTAssertEqual(cell, g.origin[l] &+ size / 2)
        }
        XCTAssertEqual(g.spacing, [2, 6, 18])
        XCTAssertEqual(g.origin[0].y, -1 - 8)
    }

    func testUpdateRangeCoversOnce() {
        for frames in [32, 7, 128] {
            var hits = [Int](repeating: 0, count: WorldCacheGrid.probesPerLevel)
            for f in 0..<frames {
                let r = WorldCacheGrid.updateRange(frame: UInt32(f), updateFrames: frames)
                XCTAssertLessThanOrEqual(r.first + r.count, WorldCacheGrid.probesPerLevel)
                for s in r.first..<(r.first + r.count) { hits[s] += 1 }
            }
            XCTAssertTrue(hits.allSatisfy { $0 == 1 }, "frames \(frames)")
        }
    }
}
