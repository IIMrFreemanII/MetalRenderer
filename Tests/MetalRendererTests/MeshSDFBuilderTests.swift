import XCTest
import simd
@testable import MetalRenderer

/// The mesh distance fields Lumen traces (MeshSDFBuilder.swift): distances against analytic shapes, the sign of
/// closed and open meshes, and the bricks' layout.
final class MeshSDFBuilderTests: XCTestCase {
    private func points(near radius: Float, within: Float, count: Int, seed: UInt64) -> [SIMD3<Float>] {
        var rng = SplitMix(seed)
        return (0..<count).map { _ in
            let d = normalize(SIMD3<Float>(rng.uniform() * 2 - 1, rng.uniform() * 2 - 1, rng.uniform() * 2 - 1) + 1e-4)
            return d * (radius + (rng.uniform() * 2 - 1) * within)
        }
    }

    /// A sphere: within the band, the field is the distance to it to half a voxel (the icosphere's facets included).
    func testSphere() throws {
        let (p, _, idx) = Scene.icosphere(subdivisions: 4)
        let sdf = try XCTUnwrap(MeshSDFBuilder.build(positions: p, indices: idx))
        XCTAssertFalse(sdf.twoSided)
        let band = MeshSDF.band * sdf.voxel
        for q in points(near: 1, within: band - sdf.voxel, count: 400, seed: 1) {
            XCTAssertEqual(sdf.distance(at: q), length(q) - 1, accuracy: sdf.voxel / 2, "\(q)")
        }
        XCTAssertLessThan(sdf.distance(at: .zero), 0, "the middle is inside")
        XCTAssertGreaterThan(sdf.distance(at: [3, 0, 0]), 0, "far away is outside")
        XCTAssertLessThan(sdf.storedBricks, sdf.table.count, "the inside and the far outside store nothing")
    }

    /// A box: its exact distance near the faces, edges and corners.
    func testCube() throws {
        let (p, _, idx) = Scene.cubeMesh()
        let sdf = try XCTUnwrap(MeshSDFBuilder.build(positions: p.map { $0 * 2 }, indices: idx))   // 2 m on a side
        func box(_ q: SIMD3<Float>) -> Float {
            let d = abs(q) - 1
            return length(simd_max(d, .zero)) + min(d.max(), 0)
        }
        var rng = SplitMix(2)
        for _ in 0..<2000 {
            let q = SIMD3<Float>(rng.uniform() * 3 - 1.5, rng.uniform() * 3 - 1.5, rng.uniform() * 3 - 1.5)
            guard abs(box(q)) < 3 * sdf.voxel else { continue }
            XCTAssertEqual(sdf.distance(at: q), box(q), accuracy: sdf.voxel / 2, "\(q)")
        }
    }

    /// An open mesh (a plane) has no inside: two-sided, the distance less half a voxel on both sides.
    func testPlaneIsTwoSided() throws {
        let (p, _, idx) = Scene.quadMesh()
        let sdf = try XCTUnwrap(MeshSDFBuilder.build(positions: p.map { $0 * 4 }, indices: idx))
        XCTAssertTrue(sdf.twoSided)
        for k: Float in [-3, -1, 1, 3] {
            let y = k * sdf.voxel
            XCTAssertEqual(sdf.distance(at: [0.3, y, -0.2]), abs(y) - sdf.voxel / 2, accuracy: sdf.voxel / 2, "y = \(y)")
        }
    }

    /// A closed mesh with a hole in it (a cube without its top) is open: two-sided as well.
    func testOpenBoxIsTwoSided() throws {
        let (p, _, idx) = Scene.cubeMesh()
        let top = (0..<idx.count / 3).filter { t in (0..<3).allSatisfy { p[Int(idx[3 * t + $0])].y > 0.49 } }
        let kept = (0..<idx.count / 3).filter { !top.contains($0) }.flatMap { t in (0..<3).map { idx[3 * t + $0] } }
        XCTAssertEqual(kept.count, idx.count - 6)
        let sdf = try XCTUnwrap(MeshSDFBuilder.build(positions: p, indices: kept))
        XCTAssertTrue(sdf.twoSided)
    }

    /// A closed box standing on an open ground (one mesh): the ground is two-sided where it is open, so a tracer finds
    /// it from above and below; the box keeps its inside.
    func testOpenGroundBesideAClosedBox() throws {
        let (cube, _, cubeIdx) = Scene.cubeMesh()
        let (quad, _, quadIdx) = Scene.quadMesh()
        let positions = cube.map { $0 + [0, 0.5, 0] } + quad.map { $0 * 8 }
        let indices = cubeIdx + quadIdx.map { $0 + UInt32(cube.count) }
        let sdf = try XCTUnwrap(MeshSDFBuilder.build(positions: positions, indices: indices))
        XCTAssertFalse(sdf.twoSided, "the box has an inside")
        XCTAssertLessThan(sdf.distance(at: [0, 0.5, 0]), 0, "inside the box")
        for y: Float in [-1, 1] {
            let d = sdf.distance(at: [2.5, y * sdf.voxel, 1.7])
            XCTAssertEqual(d, sdf.voxel / 2, accuracy: sdf.voxel / 2, "a voxel \(y > 0 ? "above" : "below") the open ground")
        }
        XCTAssertLessThan(sdf.distance(at: [2.5, 0, 1.7]), 0, "on the ground: below zero, so a tracer stops there")
    }

    /// Neighbouring bricks store their shared face of samples alike, and samples decode to what the field says.
    func testBricksShareTheirFaces() throws {
        let (p, _, idx) = Scene.icosphere(subdivisions: 2)
        let sdf = try XCTUnwrap(MeshSDFBuilder.build(positions: p, indices: idx, voxel: 0.05))
        XCTAssertGreaterThan(sdf.bricks.x, 1)
        for bz in 0..<sdf.bricks.z { for by in 0..<sdf.bricks.y { for bx in 0..<sdf.bricks.x - 1 {
            for z in 0..<MeshSDF.brickSide { for y in 0..<MeshSDF.brickSide {
                let a = sdf.sample(brick: SIMD3(bx, by, bz), local: SIMD3(7, y, z))
                let b = sdf.sample(brick: SIMD3(bx + 1, by, bz), local: SIMD3(0, y, z))
                XCTAssertEqual(a, b, accuracy: MeshSDF.band * sdf.voxel / 127 + 1e-6)
            } }
        } } }
        XCTAssertEqual(sdf.lo + SIMD3<Float>(sdf.cells) * sdf.voxel, sdf.hi)
    }

    /// Past the band and outside the volume the field is a lower bound, and not far below the true distance (the
    /// coarse grid): the global field composes from it.
    func testPastTheBandIsALowerBound() throws {
        let (p, _, idx) = Scene.icosphere(subdivisions: 2)
        let sdf = try XCTUnwrap(MeshSDFBuilder.build(positions: p, indices: idx))
        XCTAssertEqual(sdf.coarse.count, MeshSDF.coarseSide * MeshSDF.coarseSide * MeshSDF.coarseSide)
        let slack = length(sdf.hi - sdf.lo) / Float(MeshSDF.coarseSide - 1) / 2 + 0.05   // + the icosphere's facets
        // In the volume, past the band: the coarse grid, within its slack.
        for q: SIMD3<Float> in [[1.12, 0, 0], [0, -1.15, 0], [0.7, 0.7, 0.3]] where length(q) - 1 > MeshSDF.band * sdf.voxel {
            let truth = length(q) - 1
            XCTAssertLessThanOrEqual(sdf.distance(at: q), truth + 0.02, "\(q)")
            XCTAssertGreaterThanOrEqual(sdf.distance(at: q), truth - 2 * slack, "\(q)")
        }
        // Outside it: at least the distance to the volume, never more than the true distance.
        for q: SIMD3<Float> in [[5, 0, 0], [3, 3, 3], [0, -10, 0.5]] {
            let outside = length(q - simd_clamp(q, sdf.lo, sdf.hi))
            XCTAssertLessThanOrEqual(sdf.distance(at: q), length(q) - 1 + 0.02, "\(q)")
            XCTAssertGreaterThanOrEqual(sdf.distance(at: q), outside, "\(q)")
        }
    }
}

extension MeshSDFBuilderTests {
    /// A floor quad is heights: exact above and below it, from its edge beside it.
    func testQuadIsHeights() throws {
        let (p, _, idx) = Scene.quadMesh()
        let positions = p.map { $0 * 10 }
        var bounds = AABB()
        for q in positions { bounds.grow(q) }
        XCTAssertTrue(MeshSDFBuilder.isHeightfield(bounds))
        XCTAssertFalse(MeshSDFBuilder.isHeightfield(AABB(lo: [-1, -1, -1], hi: [1, 1, 1])), "a cube is not")
        let field = try XCTUnwrap(MeshSDFBuilder.heightfield(positions: positions, indices: idx))
        XCTAssertEqual(field.slope, 1, accuracy: 1e-5)
        XCTAssertEqual(field.distance(at: [1, 0.7, -2]), 0.7, accuracy: 1e-4)
        XCTAssertEqual(field.distance(at: [1, -0.3, -2]), -0.3, accuracy: 1e-4)
        XCTAssertEqual(field.distance(at: [8, 0, 0]), 3, accuracy: 1e-4, "3 m off its edge")
    }

    /// Rolling ground: a lower bound of the distance, within its slope's factor of it.
    func testRollingGroundIsALowerBound() throws {
        let n = 40, size: Float = 20
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        func h(_ x: Float, _ z: Float) -> Float { 0.8 * sin(x * 0.5) * cos(z * 0.4) }
        for j in 0...n { for i in 0...n {
            let x = Float(i) / Float(n) * size - size / 2, z = Float(j) / Float(n) * size - size / 2
            positions.append([x, h(x, z), z])
        } }
        for j in 0..<n { for i in 0..<n {
            let a = UInt32(j * (n + 1) + i), b = a + 1, c = a + UInt32(n + 1), d = c + 1
            indices += [a, c, b, b, c, d]
        } }
        let field = try XCTUnwrap(MeshSDFBuilder.heightfield(positions: positions, indices: indices))
        XCTAssertLessThan(field.slope, 1)
        var rng = SplitMix(3)
        for _ in 0..<300 {
            let x = rng.uniform() * 16 - 8, z = rng.uniform() * 16 - 8, above = rng.uniform() * 2 + 0.05
            let q = SIMD3<Float>(x, h(x, z) + above, z)
            // The true distance is at most the height above (straight down) and at least it times the slope factor.
            XCTAssertLessThanOrEqual(field.distance(at: q), above + 0.05, "\(q)")
            XCTAssertGreaterThanOrEqual(field.distance(at: q), above * field.slope - 0.05, "\(q)")
        }
    }
}

/// A small deterministic generator for the tests' points.
private struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
