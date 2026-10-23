import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// The modifier stack: each modifier's counts and shapes, the cache, booleans both ways.
final class ModelingModifierTests: XCTestCase {
    private func volume(_ m: EditMesh) -> Float {
        let (tri, _) = m.triangles()
        var v: Float = 0
        for t in 0..<(tri.count / 3) {
            v += simd_dot(m.positions[Int(m.cornerVerts[Int(tri[3 * t])])],
                          simd_cross(m.positions[Int(m.cornerVerts[Int(tri[3 * t + 1])])], m.positions[Int(m.cornerVerts[Int(tri[3 * t + 2])])])) / 6
        }
        return v
    }

    private func object(_ m: EditMesh, _ mods: [Modifier]) -> ModelObject {
        var o = ModelObject(name: "O", mesh: m)
        o.modifiers = mods
        return o
    }

    func testCatmullClark() {
        let cube = Primitive.cube.mesh()
        let s1 = CatmullClark.subdivide(cube)
        XCTAssertNil(s1.validate())
        XCTAssertEqual(s1.faceCount, 24)
        XCTAssertEqual(s1.vertexCount, 26)
        XCTAssertEqual(s1.edgeCount, 48)
        XCTAssertTrue(s1.isClosedManifold())
        XCTAssertGreaterThan(volume(s1), 0)
        // Level 3: rounder and smaller than the cube, all quads.
        let s3 = CatmullClark.subdivide(cube, levels: 3)
        XCTAssertEqual(s3.faceCount, 6 * 64)
        XCTAssertTrue(s3.isClosedManifold())
        XCTAssertLessThan(volume(s3), 8)
        XCTAssertGreaterThan(volume(s3), 2)   // the limit surface: a rounded ball inside the cube
        // Full creases keep the cube's corners.
        var creased = cube
        for e in 0..<creased.edgeCount { creased.edgeCrease[e] = 1 }
        let c3 = CatmullClark.subdivide(creased, levels: 3)
        XCTAssertEqual(volume(c3), 8, accuracy: 1e-3)
        // A plane's boundary stays where it was (the curve rule).
        let plane = CatmullClark.subdivide(Primitive.plane.mesh(), levels: 2)
        let b = plane.bounds
        XCTAssertEqual(b.hi.x, 1, accuracy: 1e-5)
    }

    func testMirror() {
        // Half a cube (its +x side at x = 0 after a move) mirrored on X: a closed box.
        var half = Primitive.cube.mesh()
        let side = (0..<half.faceCount).first { half.faceNormal($0).x < -0.9 }!
        half.select(faces: [side])
        half.delete(.faces)
        for v in 0..<half.vertexCount { half.positions[v].x += 1 }   // the open side on x = 0
        let o = object(half, [Modifier(.mirror)])
        let m = ModifierStack.evaluate(o, for: .viewport)
        XCTAssertNil(m.validate())
        XCTAssertEqual(m.vertexCount, 12)
        XCTAssertEqual(m.faceCount, 10)
        XCTAssertTrue(m.isClosedManifold())
        XCTAssertEqual(volume(m), 16, accuracy: 1e-3)
        // Blender's Z (the engine's Y): the copy goes below.
        var mz = Modifier(.mirror)
        mz.axes = [false, false, true]
        var lifted = Primitive.cube.mesh()
        for v in 0..<lifted.vertexCount { lifted.positions[v].y += 2 }
        let z = ModifierStack.evaluate(object(lifted, [mz]), for: .viewport)
        XCTAssertEqual(z.bounds.lo.y, -3, accuracy: 1e-5)
        XCTAssertEqual(z.faceCount, 12)
    }

    func testArraySolidifyBevelTriangulateWeld() {
        var a = Modifier(.array)
        a.count = 3
        let arr = ModifierStack.evaluate(object(Primitive.cube.mesh(), [a]), for: .viewport)
        XCTAssertEqual(arr.faceCount, 18)
        XCTAssertEqual(arr.bounds.hi.x - arr.bounds.lo.x, 6, accuracy: 1e-5)
        a.mergeEnds = true
        let merged = ModifierStack.evaluate(object(Primitive.cube.mesh(), [a]), for: .viewport)
        XCTAssertLessThan(merged.vertexCount, arr.vertexCount)

        var s = Modifier(.solidify)
        s.thickness = 0.1
        let plane = ModifierStack.evaluate(object(Primitive.plane.mesh(), [s]), for: .viewport)
        XCTAssertEqual(plane.faceCount, 6)
        XCTAssertTrue(plane.isClosedManifold())
        XCTAssertEqual(plane.bounds.hi.y - plane.bounds.lo.y, 0.1, accuracy: 1e-5)

        var b = Modifier(.bevel)
        b.width = 0.1
        let bev = ModifierStack.evaluate(object(Primitive.cube.mesh(), [b]), for: .viewport)
        XCTAssertEqual(bev.faceCount, 26)
        XCTAssertTrue(bev.isClosedManifold())

        let tri = ModifierStack.evaluate(object(Primitive.cube.mesh(), [Modifier(.triangulate)]), for: .viewport)
        XCTAssertEqual(tri.faceCount, 12)
    }

    func testSubdivisionModifierLevelsAndCache() {
        var sub = Modifier(.subdivision)
        sub.levels = 2
        sub.renderLevels = 3
        let o = object(Primitive.cube.mesh(), [sub])
        XCTAssertEqual(ModifierStack.evaluate(o, for: .viewport).faceCount, 96)
        XCTAssertEqual(ModifierStack.evaluate(o, for: .render).faceCount, 384)
        // The cache keeps a stage until its input or settings change.
        let cache = ModifierCache()
        let first = cache.evaluate(o, for: .viewport)
        let again = cache.evaluate(o, for: .viewport)
        XCTAssertEqual(first.generation, again.generation)
        var moved = o
        moved.mesh.positions[0].x += 0.1
        moved.mesh.touch()
        XCTAssertNotEqual(cache.evaluate(moved, for: .viewport).generation, first.generation)
    }

    func testExactBoolean() {
        // A cube minus a cube shifted half out: the volume left is half.
        let a = Primitive.cube.mesh()
        var shift = matrix_identity_float4x4
        shift.columns.3 = [1, 0, 0, 1]
        let b = Primitive.cube.mesh().transformed(by: shift)
        let diff = BooleanOps.exact(a, b, operation: .difference)
        XCTAssertNil(diff.validate())
        XCTAssertEqual(volume(diff), 4, accuracy: 1e-3)
        let union = BooleanOps.exact(a, b, operation: .union)
        XCTAssertEqual(volume(union), 12, accuracy: 1e-3)
        let inter = BooleanOps.exact(a, b, operation: .intersect)
        XCTAssertEqual(volume(inter), 4, accuracy: 1e-3)
        // The fragments of the untouched faces came back whole: the difference is a box (six faces).
        XCTAssertEqual(diff.faceCount, 6)
    }

    func testBooleanModifierWithAnOperand() {
        var doc = ModelingDocument.startup()
        var cutter = ModelObject(name: "Cutter", mesh: Primitive.cube.mesh())
        cutter.transform.location = [1, 1, 1]
        cutter.renders = false
        doc.add(cutter)
        var mod = Modifier(.boolean)
        mod.operand = doc.objects[1].id
        doc.objects[0].modifiers = [mod]
        let result = ModifierStack.evaluate(doc.objects[0], for: .viewport) { id in doc.objects.first { $0.id == id } }
        XCTAssertEqual(volume(result), 7, accuracy: 1e-3)
    }

    func testVoxelBoolean() {
        // The cutter a little larger across, so no faces lie in one plane (a voxel boolean can't tell those apart).
        let a = Primitive.cube.mesh()
        var shift = float4x4(diagonal: [1, 1.2, 1.2, 1])
        shift.columns.3 = [1, 0, 0, 1]
        let b = Primitive.cube.mesh().transformed(by: shift)
        let diff = BooleanOps.voxelBoolean(a, b, operation: .difference, voxel: 0.05)
        XCTAssertNil(diff.validate())
        XCTAssertGreaterThan(diff.faceCount, 100)
        XCTAssertEqual(volume(diff), 4, accuracy: 0.25)
        XCTAssertEqual(diff.bounds.hi.x, 0, accuracy: 0.06)
    }
}
