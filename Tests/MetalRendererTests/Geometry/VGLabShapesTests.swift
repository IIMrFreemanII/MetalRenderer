import XCTest
import Metal
import simd
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Landscape
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// The VG lab's procedural shapes: valid meshes, closed where they say so, deterministic.
final class VGLabShapesTests: XCTestCase {
    /// Each shape built once, with the time it took.
    static let built: [(shape: VGLabShape, mesh: VGMeshArrays, seconds: Double)] = VGLabShapes.all.map { shape in
        let t0 = Date()
        let mesh = shape.build()
        return (shape, mesh, Date().timeIntervalSince(t0))
    }

    func testReport() {
        for b in Self.built {
            print("VGLab \(b.shape.name): \(b.mesh.triangleCount) triangles, \(String(format: "%.2f", b.seconds)) s")
        }
    }

    func testValidMeshes() {
        for b in Self.built {
            let m = b.mesh, name = b.shape.name
            XCTAssertGreaterThanOrEqual(m.triangleCount, VirtualGeometryBuilder.minTriangles, name)
            XCTAssertEqual(m.indices.count % 3, 0, name)
            XCTAssertEqual(m.normals.count, m.positions.count, name)
            XCTAssertEqual(m.uvs.count, m.positions.count, name)
            XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.positions.count }, "\(name) index range")
            XCTAssertTrue(m.normals.allSatisfy { n in
                n.x.isFinite && n.y.isFinite && n.z.isFinite && abs(simd_length(n) - 1) < 1e-3
            }, "\(name) normals")
            XCTAssertTrue(m.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, name)
            var degenerate = 0
            for t in 0..<m.triangleCount {
                let a = SIMD3<Double>(m.positions[Int(m.indices[3 * t])])
                let b = SIMD3<Double>(m.positions[Int(m.indices[3 * t + 1])])
                let c = SIMD3<Double>(m.positions[Int(m.indices[3 * t + 2])])
                if simd_length(simd_cross(b - a, c - a)) < 1e-10 { degenerate += 1 }
            }
            XCTAssertEqual(degenerate, 0, "\(name) degenerate triangles")
        }
    }

    func testWatertightShapesAreClosedAndOutward() {
        for b in Self.built where b.shape.watertight {
            let m = b.mesh, name = b.shape.name
            // Weld positions quantised to 1e-5 (the needles' tips are finer than that: 1e-7 there).
            let q: Float = b.shape.name == "Needle comb" ? 1e-7 : 1e-5
            var welded: [SIMD3<Int32>: UInt32] = [:]
            var remap = [UInt32](repeating: 0, count: m.positions.count)
            for (i, p) in m.positions.enumerated() {
                let key = SIMD3<Int32>((p / q).rounded(.toNearestOrAwayFromZero), rounding: .towardZero)
                if let w = welded[key] { remap[i] = w } else { welded[key] = UInt32(i); remap[i] = UInt32(i) }
            }
            var directed: [UInt64: Int] = [:]
            directed.reserveCapacity(m.indices.count)
            for t in 0..<m.triangleCount {
                let v = (0..<3).map { remap[Int(m.indices[3 * t + $0])] }
                for e in 0..<3 {
                    directed[(UInt64(v[e]) << 32) | UInt64(v[(e + 1) % 3]), default: 0] += 1
                }
            }
            var bad = 0
            for (key, count) in directed {
                let reverse = ((key & 0xFFFF_FFFF) << 32) | (key >> 32)
                if count != 1 || directed[reverse] != 1 { bad += 1 }
            }
            XCTAssertEqual(bad, 0, "\(name): edges not used exactly twice with opposite directions")
            var volume = 0.0
            for t in 0..<m.triangleCount {
                let a = SIMD3<Double>(m.positions[Int(m.indices[3 * t])])
                let b = SIMD3<Double>(m.positions[Int(m.indices[3 * t + 1])])
                let c = SIMD3<Double>(m.positions[Int(m.indices[3 * t + 2])])
                volume += simd_dot(a, simd_cross(b, c)) / 6
            }
            XCTAssertGreaterThan(volume, 0, "\(name) signed volume")
        }
    }

    func testDeterministic() {
        // The big plane and icosphere are the slow ones; the others are enough to catch a stray random source.
        for shape in [VGLabShapes.torusKnot(), VGLabShapes.needleComb(), VGLabShapes.thinSheet()] {
            let a = shape.build(), b = shape.build()
            XCTAssertEqual(a.positions, b.positions, shape.name)
            XCTAssertEqual(a.normals, b.normals, shape.name)
            XCTAssertEqual(a.uvs, b.uvs, shape.name)
            XCTAssertEqual(a.indices, b.indices, shape.name)
        }
    }

    func testUniqueCacheKeys() {
        let keys = VGLabShapes.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}
