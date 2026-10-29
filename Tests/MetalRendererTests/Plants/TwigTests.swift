import XCTest
import simd
@testable import EngineCore
@testable import Plants

/// A grown species' twigs: the palette (Growth.twig, outline leaves) and the distributor that hangs them.
final class TwigTests: XCTestCase {
    private var def: Foliage.SpeciesDef { PlantCatalog.builtIn[.oak] }

    func testTwigsAreSoundWithWholeLeaves() {
        let twigs = def.twigs!
        for v in 0..<twigs.palette {
            let mesh = Growth.twig(twigs, variant: v, seed: UInt64(v + 1))
            XCTAssertEqual(Foliage.problems(mesh), [], "variant \(v)")
            XCTAssertGreaterThan(mesh.leafTriangles, 100)
            XCTAssertEqual(mesh.leafTriangles % 8, 0)
            // Each leaf's triangles carry its number, the same at all their vertices.
            for t in stride(from: mesh.leafIndex, to: mesh.indices.count, by: 3) {
                let n = (0..<3).map { floor(mesh.uvs[Int(mesh.indices[t + $0])].y) }
                XCTAssertGreaterThanOrEqual(n[0], 1)
                XCTAssertEqual(n[0], n[1])
                XCTAssertEqual(n[0], n[2])
            }
            // A twig lies along +Y.
            XCTAssertGreaterThan(mesh.bounds.hi.y, 0.4)
        }
        // From sparse to dense.
        let first = Growth.twig(twigs, variant: 0, seed: 1), last = Growth.twig(twigs, variant: twigs.palette - 1, seed: 1)
        XCTAssertLessThan(first.leafTriangles, last.leafTriangles)
    }

    func testTheOakCarriesHundredsOfTwigsOnBones() {
        let palette = (0..<def.paletteSize).map { Growth.twig(def.twigs!, variant: $0, seed: UInt64($0)) }
        let plant = Foliage.plant(.oak, age: .mature, seed: 5, palette: palette)
        let twigs = plant.parts.filter(\.shared)
        XCTAssertGreaterThan(twigs.count, 300)
        XCTAssertLessThan(twigs.count, 1500)
        for part in plant.parts {
            XCTAssertTrue(plant.bones.indices.contains(part.bone))
            let parent = plant.bones[part.bone].parent
            XCTAssertLessThan(Int(parent), part.bone)
        }
    }

    func testOutlinesAreTraced() {
        XCTAssertEqual(Foliage.LeafOutline.sheet.count, 9)
        for o in Foliage.LeafOutline.sheet {
            XCTAssertGreaterThan(o.aspect, 0.15)
            XCTAssertLessThan(o.aspect, 1.5)
            for s in o.sides { XCTAssertLessThan(s.left.across, s.right.across) }
        }
    }
}
