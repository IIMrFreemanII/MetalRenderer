import XCTest
import simd
@testable import MetalRenderer

/// The demolition scene's office as blocks (DemolitionBlueprint): there for every size, nothing inside anything, each
/// block standing on something, and few enough bodies for the CPU's step.
final class DemolitionBlueprintTests: XCTestCase {
    func testItIsMadeOfEveryKind() {
        let b = DemolitionBlueprint(DemolitionSettings())
        var counts = [Int](repeating: 0, count: DemolitionBlueprint.Kind.allCases.count)
        for block in b.blocks { counts[block.kind.rawValue] += 1 }
        print("blocks", b.blocks.count, zip(DemolitionBlueprint.Kind.allCases.map(\.title), counts).map { "\($0) \($1)" }.joined(separator: ", "),
              "floors", b.floors)
        XCTAssertEqual(b.floors.count, DemolitionSettings().floors)
        for kind in DemolitionBlueprint.Kind.allCases where kind != .doorHead && kind != .lintel {
            XCTAssertGreaterThan(counts[kind.rawValue], 0, "\(kind)")
        }
    }

    func testNothingStartsInsideAnything() {
        for (floors, seed) in [(4, 1), (5, 7), (6, 3)] {
            var s = DemolitionSettings()
            s.floors = floors
            s.seed = seed
            let b = DemolitionBlueprint(s)
            let overlaps = b.overlaps()
            for (i, j) in overlaps.prefix(5) {
                print("overlap", b.blocks[i].kind, b.blocks[i].storey, b.blocks[i].lo, b.blocks[i].hi, "-", b.blocks[j].kind, b.blocks[j].storey,
                      b.blocks[j].lo, b.blocks[j].hi)
            }
            XCTAssertEqual(overlaps.count, 0, "\(floors) storeys, seed \(seed)")
        }
    }

    /// Every block's foot is on the ground or within a few millimetres over another block's top.
    func testEveryBlockStandsOnSomething() {
        let b = DemolitionBlueprint(DemolitionSettings())
        var floating = 0
        for (i, a) in b.blocks.enumerated() where a.lo.y > 0.01 && a.kind != .stair && a.kind != .slab {   // (the stair's lanes stand on the ones below by construction; a slab's panels hold each other)
            let under = b.blocks.indices.contains { j in
                let c = b.blocks[j]
                return j != i && abs(c.hi.y - a.lo.y) < 0.004 && c.lo.x < a.hi.x && a.lo.x < c.hi.x && c.lo.z < a.hi.z && a.lo.z < c.hi.z
            }
            if !under {
                floating += 1
                if floating <= 5 { print("floating", a.kind, a.storey, a.lo, a.hi) }
            }
        }
        XCTAssertEqual(floating, 0)
    }
}

extension DemolitionBlueprintTests {
    /// How many blocks each one touches (its box within 2 cm of theirs): a body keeps PhysicsWorld.maxPairs pairs.
    func testFewNeighbours() {
        let b = DemolitionBlueprint(DemolitionSettings())
        var worst: [DemolitionBlueprint.Kind: Int] = [:], over = 0
        for (i, a) in b.blocks.enumerated() {
            var n = 0
            for (j, c) in b.blocks.enumerated() where j != i {
                if all(a.lo .< c.hi + 0.02) && all(c.lo .< a.hi + 0.02) { n += 1 }
            }
            worst[a.kind] = max(worst[a.kind] ?? 0, n)
            if n > PhysicsWorld.maxPairs { over += 1 }
        }
        print("neighbours", over, "over", PhysicsWorld.maxPairs, worst.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key) \($0.value)" })
        XCTAssertEqual(over, 0)
    }
}

extension DemolitionBlueprintTests {
    func testPrintBlocks() throws {
        guard let list = ProcessInfo.processInfo.environment["DEMOLITION_BLOCKS"] else { throw XCTSkip("print") }
        let b = DemolitionBlueprint(DemolitionSettings())
        for k in list.split(separator: ",").compactMap({ Int($0) }) {
            let x = b.blocks[k]
            print("block", k, x.kind, "storey", x.storey, x.lo, x.hi, "size", x.hi - x.lo)
        }
    }
}
