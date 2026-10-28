import XCTest
import simd
@testable import Characters
@testable import EngineCore
@testable import Garments
@testable import Physics

/// The garment solver on the CPU (GarmentSim, the reference Garment.metal follows): its gradients, a hanging sheet,
/// seams that close, a drape over a ball.
final class GarmentSolverTests: XCTestCase {
    /// The dihedral's gradient is the angle's (finite differences).
    func testTheBendingGradientIsTheAngles() throws {
        let x: [SIMD3<Float>] = [[0.5, 1, 0.3], [0.4, -1, 0.2], [0, 0, 0], [1, 0.1, 0]]
        let (theta, g) = try XCTUnwrap(GarmentStep.dihedral(x[0], x[1], x[2], x[3]))
        XCTAssertEqual(theta, -0.4982, accuracy: 1e-3)
        let grads = [g.0, g.1, g.2, g.3]
        for i in 0..<4 {
            for k in 0..<3 {
                var a = x, b = x
                a[i][k] += 1e-3; b[i][k] -= 1e-3
                let da = GarmentStep.dihedral(a[0], a[1], a[2], a[3])!.0, db = GarmentStep.dihedral(b[0], b[1], b[2], b[3])!.0
                XCTAssertEqual((da - db) / 2e-3, grads[i][k], accuracy: 2e-2, "particle \(i) axis \(k)")
            }
        }
        // Flat is 0.
        XCTAssertEqual(GarmentStep.dihedral([0.5, 1, 0], [0.5, -1, 0], [0, 0, 0], [1, 0, 0])!.0, 0, accuracy: 1e-6)
    }

    private func sheet(_ w: Float, _ h: Float, fabric: Fabric = .preset(.cotton)) -> (Garment, GarmentBuild) {
        var g = Garment(name: "Sheet")
        g.fabrics = [fabric]
        g.particleDistance = 0.025
        g.panels = [Panel(id: 0, name: "Sheet", points: [PathPoint([0, 0]), PathPoint([w, 0]), PathPoint([w, h]), PathPoint([0, h])])]
        return (g, GarmentBuild.make(g))
    }

    /// A sheet hung by its top edge stretches by under 2% and swings down under it.
    func testAHangingSheetKeepsItsSize() {
        let (_, b) = sheet(0.4, 0.4)
        var mass = b.invMass
        let top = b.rest2D.map(\.y).max()!
        for i in mass.indices where b.rest2D[i].y > top - 1e-4 { mass[i] = 0 }
        // Hung horizontally first: it falls and swings down.
        let start = b.rest2D.map { SIMD3($0.x, 1.5, -$0.y) }
        var sim = GarmentSim(positions: start, invMass: mass, constraints: b.constraints, colourStarts: b.colourStarts)
        for _ in 0..<180 { sim.step(dt: 1 / 60, substeps: 15) }
        let p = sim.positions
        XCTAssertTrue(p.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        // The bottom corner below the top, near the sheet's length.
        let lowest = p.map(\.y).min()!
        XCTAssertLessThan(lowest, 1.5 - 0.36)
        XCTAssertGreaterThan(lowest, 1.5 - 0.42)
        // Its edges as long as they were cut.
        var worst: Float = 0
        for t in stride(from: 0, to: b.triangles.count, by: 3) {
            for k in 0..<3 {
                let i = Int(b.triangles[t + k]), j = Int(b.triangles[t + (k + 1) % 3])
                let rest = simd_distance(b.rest2D[i], b.rest2D[j])
                worst = max(worst, simd_distance(p[i], p[j]) / rest - 1)
            }
        }
        XCTAssertLessThan(worst, 0.03)
    }

    /// Two panels side by side, their edges sewn, come together.
    func testSeamsClose() {
        var g = Garment(name: "Two")
        g.particleDistance = 0.025
        let square = [PathPoint([0, 0]), PathPoint([0.2, 0]), PathPoint([0.2, 0.2]), PathPoint([0, 0.2])]
        g.panels = [Panel(id: 0, name: "A", points: square), Panel(id: 1, name: "B", points: square.map { PathPoint($0.p + [0.4, 0]) })]
        g.seams = [Seam(id: 0, a: [SeamEnd(panel: 0, edge: 1)], b: [SeamEnd(panel: 1, edge: 3, t0: 1, t1: 0)])]
        let b = GarmentBuild.make(g)
        let start = b.rest2D.map { SIMD3($0.x, $0.y, 0) }
        var sim = GarmentSim(positions: start, invMass: b.invMass, constraints: b.constraints, colourStarts: b.colourStarts)
        sim.params.gravity = .zero
        sim.params.seams.x = 1e-6
        for _ in 0..<120 { sim.step(dt: 1 / 60, substeps: 10) }
        let p = sim.positions
        let gaps = b.stitches.map { simd_distance(p[Int($0.0)], p[Int($0.1)]) }
        XCTAssertFalse(gaps.isEmpty)
        XCTAssertLessThan(gaps.max()!, 0.004)
    }

    /// A sheet dropped on a ball drapes over it: nothing inside the ball, the middle on top of it.
    func testASheetDrapesOverABall() {
        let (_, b) = sheet(0.6, 0.6)
        let start = b.rest2D.map { SIMD3($0.x - 0.3, 1.0, $0.y - 0.3) }
        var sim = GarmentSim(positions: start, invMass: b.invMass, constraints: b.constraints, colourStarts: b.colourStarts)
        sim.spheres = [GPUGarmentSphere(a: [0, 0.6, 0, 0.2], b: [0, 0.6, 0, 0.5])]
        for _ in 0..<120 { sim.step(dt: 1 / 60, substeps: 15) }
        let p = sim.positions
        let inside = p.map { simd_distance($0, [0, 0.6, 0]) }.min()!
        XCTAssertGreaterThan(inside, 0.2 - 0.005)
        let middle = p.indices.min { simd_length(SIMD2(p[$0].x, p[$0].z)) < simd_length(SIMD2(p[$1].x, p[$1].z)) }!
        XCTAssertEqual(p[middle].y, 0.8, accuracy: 0.02)
    }
}
