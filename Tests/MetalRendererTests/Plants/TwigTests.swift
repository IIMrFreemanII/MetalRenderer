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

    func testOutlineLeavesAreDomedBlades() {
        // Each leaf 4 triangles a row (its rows' midribs too), its vertex normals curving across it (not one flat facet),
        // and all its triangles wound the same way about their corners' normals (no half of it backwards; a mirrored
        // leaf is wound the other way, which two-sided shading doesn't mind).
        let mesh = Growth.twig(def.twigs!, variant: 0, seed: 1)
        let perLeaf = Foliage.LeafOutline.size.indices / 3
        XCTAssertEqual(perLeaf, 4 * Foliage.LeafOutline.rows)
        XCTAssertEqual(mesh.leafTriangles % perLeaf, 0)
        var spread: [Float: Float] = [:], facing: [Float: Set<Bool>] = [:]
        for t in stride(from: mesh.leafIndex, to: mesh.indices.count, by: 3) {
            let v = (0..<3).map { Int(mesh.indices[t + $0]) }
            let face = cross(mesh.positions[v[1]] - mesh.positions[v[0]], mesh.positions[v[2]] - mesh.positions[v[0]])
            let n = mesh.normals[v[0]] + mesh.normals[v[1]] + mesh.normals[v[2]]
            let leaf = floor(mesh.uvs[v[0]].y)
            facing[leaf, default: []].insert(dot(face, n) > 0)
            let least = v.flatMap { a in v.map { dot(mesh.normals[a], mesh.normals[$0]) } }.min()!
            spread[leaf] = min(spread[leaf] ?? 1, least)
        }
        XCTAssertFalse(spread.isEmpty)
        for (leaf, least) in spread { XCTAssertLessThan(least, 0.995, "leaf \(leaf) shades flat") }
        for (leaf, sides) in facing { XCTAssertEqual(sides.count, 1, "leaf \(leaf)") }
    }

    func testTwigWoodIsToldFromTheTree() {
        // A twig's wood carries its generation past Growth.twigWood in U (Surface.metal TWIG_WOOD tints it), its leaves don't.
        let mesh = Growth.twig(def.twigs!, variant: 2, seed: 3)
        let firstLeafVertex = Int(mesh.indices[mesh.leafIndex...].min()!)
        XCTAssertGreaterThan(firstLeafVertex, 0)
        for v in 0..<firstLeafVertex { XCTAssertGreaterThanOrEqual(mesh.uvs[v].x, Growth.twigWood) }
        for t in stride(from: mesh.leafIndex, to: mesh.indices.count, by: 1) {
            XCTAssertLessThan(mesh.uvs[Int(mesh.indices[t])].x, Growth.twigWood)
        }
    }

    func testTheBirchAndTheBushHaveLeavesOfTheirOwn() throws {
        // Their sheets' 3 by 2 leaves (info.json's "cells"), each traced inside its own cell: the birch's pointed ones
        // narrower than the bush's round ones; the oak's elliptic ones (the Mega Plants tree's) narrower still. (Without
        // the scans, a fresh clone's, they fall back to the ovate leaves.)
        let def = { (id: String) in Foliage.builtInSpecies.first { $0.id == id }!.twigs!.leaf }
        XCTAssertEqual(def("birch").sheetName, "leaves-birch")
        XCTAssertEqual(def("bush").sheetName, "leaves-bush")
        XCTAssertEqual(def("oak").sheetName, "leaves-oak")
        guard ["leaves-birch", "leaves-bush", "leaves-oak"].allSatisfy({ TextureSet.find($0) != nil }) else { throw XCTSkip("no leaf scans") }
        for name in ["leaves-birch", "leaves-bush", "leaves-oak"] {
            XCTAssertEqual(Foliage.LeafOutline.grid(name), SIMD2(3, 2))
            let sheet = Foliage.LeafOutline.sheet(name)
            XCTAssertEqual(sheet.count, 6)
            for (k, o) in sheet.enumerated() {
                let cell = SIMD2(Float(k % 3), Float(k / 3))
                for p in [o.base, o.tip] + o.sides.flatMap({ [$0.left, $0.right] }) {
                    XCTAssertEqual(floor(p.uv.x * 3), cell.x, "\(name) leaf \(k)")
                    XCTAssertEqual(floor(p.uv.y * 2), cell.y, "\(name) leaf \(k)")
                }
            }
        }
        let aspect = { (name: String) in Foliage.LeafOutline.sheet(name).map(\.aspect).reduce(0, +) / 6 }
        print("leaf width over length: oak", aspect("leaves-oak"), "birch", aspect("leaves-birch"), "bush", aspect("leaves-bush"))
        XCTAssertLessThan(aspect("leaves-birch") + 0.1, aspect("leaves-bush"))
        XCTAssertLessThan(aspect("leaves-oak"), 0.45)
    }
}
