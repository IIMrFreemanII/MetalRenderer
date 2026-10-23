import XCTest
import simd
@testable import EngineCore
@testable import Modeling

/// G, R and S: constraints, typed values, snapping, the mouse's travel; proportional weights; the knife.
final class ModelingTransformTests: XCTestCase {
    private let size = SIMD2<Float>(800, 600)

    private func apply(_ m: float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4(p, 1)
        return SIMD3(q.x, q.y, q.z)
    }

    func testNumericInput() {
        var n = NumericInput()
        XCTAssertNil(n.values)
        for k in ["2", ".", "5"] { n.type(k) }
        XCTAssertEqual(n.values?.x, 2.5)
        n.type("-")
        XCTAssertEqual(n.values?.x, -2.5)
        n.type("\t")
        for k in ["3", "*", "2"] { n.type(k) }
        XCTAssertEqual(n.values, SIMD3(-2.5, 6, 0))
        n.type("\u{7f}")
        XCTAssertEqual(n.values?.y, 3)
        XCTAssertEqual(NumericInput.evaluate("(1+2)*3/2"), 4.5)
        XCTAssertEqual(NumericInput.evaluate("-0.5"), -0.5)
        XCTAssertNil(NumericInput.evaluate(""))
        XCTAssertFalse(n.type("q"))
    }

    func testTypedValues() {
        let cam = ViewportCamera()
        var g = TransformOperation(kind: .translate, pivot: .zero, mouse: [400, 300])
        g.press(axis: 0, plane: false)
        g.numeric.type("2")
        XCTAssertEqual(apply(g.matrix(camera: cam, viewSize: size), [1, 1, 1]), [3, 1, 1])
        // Second X: the local axis (here turned 90° round Y: local X is world −Z).
        g.localAxes = float3x3(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        g.press(axis: 0, plane: false)
        XCTAssertEqual(g.constraint, .axis(0, local: true))
        let moved = apply(g.matrix(camera: cam, viewSize: size), .zero)
        XCTAssertEqual(simd_distance(moved, [0, 0, -2]), 0, accuracy: 1e-5)
        g.press(axis: 0, plane: false)
        XCTAssertEqual(g.constraint, .none)

        var r = TransformOperation(kind: .rotate, pivot: [1, 0, 0], mouse: [400, 300])
        r.press(axis: 1, plane: false)
        r.numeric.type("9"); r.numeric.type("0")
        // 90° round the Y axis through (1, 0, 0), as seen from above (the axis turned toward the camera): (2, 0, 0) → (1, 0, −1).
        let p = apply(r.matrix(camera: cam, viewSize: size), [2, 0, 0])
        XCTAssertEqual(simd_distance(p, [1, 0, -1]), 0, accuracy: 1e-4)

        var s = TransformOperation(kind: .scale, pivot: .zero, mouse: [400, 300])
        s.numeric.type("2")
        XCTAssertEqual(apply(s.matrix(camera: cam, viewSize: size), [1, 2, 3]), [2, 4, 6])
        s.press(axis: 2, plane: true)   // Shift-Z: X and Y only
        XCTAssertEqual(apply(s.matrix(camera: cam, viewSize: size), [1, 2, 3]), [2, 4, 3])
    }

    func testMouseTravel() {
        var cam = ViewportCamera()
        cam.align(.front)   // looking along −Z: screen right is +X, up is +Y
        let start = SIMD2<Float>(400, 300)
        let pivot = SIMD3<Float>.zero
        var g = TransformOperation(kind: .translate, pivot: pivot, mouse: start)
        // A point at the pivot's depth moves under the mouse.
        g.move(to: start + [100, -50])
        let d = g.delta(camera: cam, viewSize: size)
        let k = cam.metresPerPoint(depth: cam.distance, viewHeight: size.y)
        XCTAssertEqual(d.x, 100 * k, accuracy: 1e-4)
        XCTAssertEqual(d.y, 50 * k, accuracy: 1e-4)
        XCTAssertEqual(d.z, 0, accuracy: 1e-5)
        // Constrained to Y: only up.
        g.press(axis: 1, plane: false)
        let dy = g.delta(camera: cam, viewSize: size)
        XCTAssertEqual(dy.x, 0)
        XCTAssertEqual(dy.y, 50 * k, accuracy: 1e-3)
        // Snapped to whole units.
        g.snap = true
        g.move(to: start + [0, -1.6 / k])
        XCTAssertEqual(g.delta(camera: cam, viewSize: size).y, 2)
        // Rotation: a quarter turn of the mouse round the pivot's place on screen is a quarter turn.
        var r = TransformOperation(kind: .rotate, pivot: pivot, mouse: start + [100, 0])
        r.move(to: start + [0, -100])   // up on screen: counter-clockwise
        let (axis, angle) = r.rotation(camera: cam, viewSize: size)
        XCTAssertEqual(angle, .pi / 2, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(axis, [0, 0, 1]), 0, accuracy: 1e-5)
        // Scale: twice as far from the pivot, twice the size.
        var s = TransformOperation(kind: .scale, pivot: pivot, mouse: start + [50, 0])
        s.move(to: start + [100, 0])
        XCTAssertEqual(s.scaleVector(camera: cam, viewSize: size).x, 2, accuracy: 1e-4)
    }

    func testProportionalWeights() {
        var m = Primitive.grid.mesh()
        let centre = (0..<m.vertexCount).min { simd_length(m.positions[$0]) < simd_length(m.positions[$1]) }!
        m.select(vertices: [centre])
        let w = m.proportionalWeights(radius: 0.5, falloff: .linear, connected: false)
        XCTAssertEqual(w[centre], 1)
        for v in 0..<m.vertexCount where v != centre {
            let dist = simd_length(m.positions[v])
            XCTAssertEqual(w[v], max(0, 1 - dist / 0.5), accuracy: 1e-5)
        }
        let c = m.proportionalWeights(radius: 0.5, falloff: .linear, connected: true)
        // Straight: 21 vertices within 0.5 of the centre (spacing 0.2); along edges only 13 (two edges to a diagonal).
        XCTAssertEqual(w.filter { $0 > 0 }.count, 21)
        XCTAssertEqual(c.filter { $0 > 0 }.count, 13)
        // Applying: the selected vertex moves all the way, a neighbour part way.
        let start = m.positions
        var up = matrix_identity_float4x4
        up.columns.3 = [0, 1, 0, 1]
        m.apply(up, weights: w, from: start)
        XCTAssertEqual(m.positions[centre].y, 1)
        let neighbour = (0..<m.vertexCount).first { abs(simd_length(start[$0]) - 0.2) < 1e-4 }!
        XCTAssertEqual(m.positions[neighbour].y, 0.6, accuracy: 1e-4)
    }

    func testKnifeCutsAcrossTheCube() {
        var cube = Primitive.cube.mesh()
        var cam = ViewportCamera()
        cam.align(.front)
        // A vertical stroke through the middle of the front face, from above it to below it.
        let top = cam.project([0, 1.5, 1], size: size)!, bottom = cam.project([0, -1.5, 1], size: size)!
        let split = cube.knife([SIMD2(top.x, top.y), SIMD2(bottom.x, bottom.y)], camera: cam, viewSize: size, objectMatrix: matrix_identity_float4x4)
        XCTAssertEqual(split, 1, "only the front face (the others face away or edge on)")
        XCTAssertEqual(cube.faceCount, 7)
        XCTAssertEqual(cube.vertexCount, 10)
        XCTAssertNil(cube.validate())
        XCTAssertTrue(cube.isClosedManifold())
        // Through everything: the back face too, and top and bottom.
        var all = Primitive.cube.mesh()
        all.knife([SIMD2(top.x, top.y), SIMD2(bottom.x, bottom.y)], camera: cam, viewSize: size, objectMatrix: matrix_identity_float4x4, throughAll: true)
        XCTAssertEqual(all.faceCount, 10)
        XCTAssertTrue(all.isClosedManifold())
    }
}
