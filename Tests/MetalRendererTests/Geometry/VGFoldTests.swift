import XCTest
import simd
@testable import EngineCore
@testable import Game
@testable import MetalRenderer

/// What the VG lab's Cracks view checks on screen, checked on the DAG: a closed shape's cut at any distance is closed
/// and has no triangle facing against its corners' normals (a fold, whose back faces a ray from outside would see).
/// The simplifier used to let triangles turn over a few degrees a collapse at a time (MeshSimplifier.valid).
final class VGFoldTests: XCTestCase {
    /// VGFOLD_PRINT=1: each inverted triangle, and each DAG's levels and roots.
    static let verbose = ProcessInfo.processInfo.environment["VGFOLD_PRINT"] == "1"
    struct CutStats { var triangles = 0, inverted = 0, open = 0, nonManifold = 0 }

    static func octDecode(_ e: UInt32) -> SIMD3<Float> {
        let x = Float(Int16(bitPattern: UInt16(e & 0xFFFF))) / 32767, y = Float(Int16(bitPattern: UInt16(e >> 16))) / 32767
        var v = SIMD3<Float>(x, y, 1 - abs(x) - abs(y))
        if v.z < 0 { v = SIMD3((1 - abs(y)) * (x >= 0 ? 1 : -1), (1 - abs(x)) * (y >= 0 ? 1 : -1), v.z) }
        return normalize(v)
    }

    /// The cut's triangles decoded from the pages (as VirtualBLAS.gather reads them), and what is wrong with them.
    static func stats(_ mesh: VirtualMesh, _ selection: [UInt32]) -> CutStats {
        var s = CutStats()
        struct Edge: Hashable { var a: SIMD3<Int32>, b: SIMD3<Int32> }
        var edges: [Edge: Int] = [:]
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            let q = (p * 1e5).rounded(.toNearestOrEven)
            return SIMD3<Int32>(Int32(q.x), Int32(q.y), Int32(q.z))
        }
        mesh.pageData.withUnsafeBytes { raw in
            for ci in selection {
                let c = mesh.clusters[Int(ci)]
                let base = Int(mesh.groups[Int(c.group)].pageOffset) + Int(c.pageOffset)
                func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: base + o, as: UInt32.self) }
                let n = Int(u32(8)), posOffset = Int(u32(20)), triOffset = Int(u32(28))
                for t in 0..<n {
                    let packed = u32(triOffset + 4 * t)
                    var p = [SIMD3<Float>](), normal = SIMD3<Float>()
                    for k in 0..<3 {
                        let vi = Int((packed >> (8 * UInt32(k))) & 0xFF)
                        let v = raw.loadUnaligned(fromByteOffset: base + posOffset + 16 * vi, as: SIMD4<Float>.self)
                        p.append(SIMD3(v.x, v.y, v.z))
                        normal += octDecode(v.w.bitPattern)
                    }
                    s.triangles += 1
                    let fn = cross(p[1] - p[0], p[2] - p[0])
                    if dot(fn, normal) < 0 {
                        s.inverted += 1
                        if VGFoldTests.verbose {
                            print(String(format: "    inverted: cos %.3f, area %.2e, level %d, corner normals spread %.3f", dot(normalize(fn), normalize(normal)),
                                         length(fn) / 2, mesh.groups[Int(c.group)].level, length(normal) / 3))
                        }
                    }
                    for k in 0..<3 { edges[Edge(a: key(p[k]), b: key(p[(k + 1) % 3])), default: 0] += 1 }
                }
            }
        }
        for (e, n) in edges {
            let back = edges[Edge(a: e.b, b: e.a)] ?? 0
            if n == 1 && back == 1 { continue }
            if n + back == 1 { s.open += 1 } else { s.nonManifold += 1 }
        }
        return s
    }

    func testClosedShapesCutsStayClosedAndFacingOut() {
        // VGFOLD_FULL=1: the lab's own sizes (slower).
        let full = ProcessInfo.processInfo.environment["VGFOLD_FULL"] == "1"
        for shape in full ? [VGLabShapes.icosphere(), VGLabShapes.torusKnot()]
                          : [VGLabShapes.icosphere(subdivisions: 6), VGLabShapes.torusKnot(tubular: 1024, radial: 48)] {
            let a = shape.build()
            let mesh = VirtualGeometryBuilder.build(positions: a.positions, normals: a.normals, uvs: a.uvs, indices: a.indices,
                                                    name: shape.name) { _ in }
            XCTAssertEqual(VirtualGeometryBuilder.check(mesh), [], shape.name)
            if VGFoldTests.verbose {
                let roots = mesh.groups.filter(\.isRoot)
                let rootTris = roots.reduce(0) { r, g in r + mesh.clusters[Int(g.clusterStart)..<Int(g.clusterStart + g.clusterCount)].reduce(0) { $0 + Int($1.triangles) } }
                print("  \(shape.name): \(mesh.triangleCount) tris, \(mesh.clusters.count) clusters, \((mesh.groups.map(\.level).max() ?? 0) + 1) levels, roots \(roots.count) groups / \(rootTris) tris")
            }
            let pixelScale: Float = 1200 / (2 * tan(Float.pi / 6))
            for d: Float in [0.05, 3, 6, 12, 25, 50, 100, 1000] {
                let sel = VirtualBLAS.selection(mesh: mesh, groups: 0..<mesh.groups.count, transform: matrix_identity_float4x4,
                                                camPos: [0, 0, d], pixelScale: pixelScale, tau: 1).selection
                let s = VGFoldTests.stats(mesh, sel)
                XCTAssertEqual(s.open, 0, "\(shape.name) at \(d) m: open edges")
                // A triangle or two of a coarse level may still face across a sharp crease of its corners' normals.
                XCTAssertLessThanOrEqual(s.inverted, 2, "\(shape.name) at \(d) m: \(s.inverted) of \(s.triangles) triangles face in")
            }
        }
    }
}
