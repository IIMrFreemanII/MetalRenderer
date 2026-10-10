import XCTest
import simd
@testable import MetalRenderer

/// The Material Painter's UV check and unwrap (Painter/UVCheck, UVUnwrap, UVPack): every texel at one place of the
/// mesh, no fold, gutters between the charts, the area kept, the same answer every time, and in time.
final class PainterUnwrapTests: XCTestCase {
    private func cube() -> PaintMesh {
        var b = MeshBuilder()
        Scene.tiledBox(&b, half: 0.75)
        return PaintMesh(positions: b.positions, normals: b.normals, uvs: b.uvs, indices: b.indices)
    }
    private func sphere() -> PaintMesh {
        let g = Scene.uvSphere()
        return PaintMesh(positions: g.positions, normals: g.normals, uvs: Scene.uvSphereUVs(), indices: g.indices)
    }
    private func cylinder() -> PaintMesh {
        let (g, uvs) = Scene.uvCylinder(radius: 0.7, height: 1.6)
        return PaintMesh(positions: g.positions, normals: g.normals, uvs: uvs, indices: g.indices)
    }
    private func character() throws -> PaintMesh {
        guard let kit = CharacterKit.shared() else { throw XCTSkip("no characters in \(CharacterLibrary.directory.path)") }
        let c = kit.base.character
        return PaintMesh(positions: c.positions, normals: c.normals, uvs: c.uvs, indices: c.indices)
    }
    private func model() throws -> PaintMesh {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/fiery demon 3d model.glb")
        guard FileManager.default.fileExists(atPath: url.path), let m = try? GLTFLoader.load(url), let mesh = m.meshes.max(by: { $0.indices.count < $1.indices.count })
        else { throw XCTSkip("no \(url.lastPathComponent)") }
        return PaintMesh(positions: mesh.positions, normals: mesh.normals, uvs: mesh.uvs, indices: mesh.indices)
    }

    /// What every layout must be: in the square, no triangle folded over, no texel covered twice, the charts at least
    /// a gutter apart, and the area at about the same scale everywhere (90% of triangles within 2x of the mean).
    private func check(_ mesh: PaintMesh, _ atlas: UVAtlas, _ name: String, minCoverage: Float = 0.6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(atlas.corners.count, mesh.indices.count, name, file: file, line: line)
        XCTAssertTrue(atlas.corners.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x <= 1 && $0.y <= 1 }, "\(name): in 0...1", file: file, line: line)
        var flipped = 0, ratios: [Float] = []
        var uvTotal: Float = 0, worldTotal: Float = 0
        // (Triangles of next to no area, a pole's fan, are neither way.)
        let meanArea = (0..<mesh.triangleCount).reduce(Float(0)) { $0 + mesh.area($1) } / Float(max(mesh.triangleCount, 1))
        var kept: [UInt32] = []
        for t in 0..<mesh.triangleCount {
            let a = atlas.corners[3 * t], b = atlas.corners[3 * t + 1], c = atlas.corners[3 * t + 2]
            let uv = UVCheck.cross2(b - a, c - a) / 2, world = mesh.area(t)
            guard world > 1e-4 * meanArea else { continue }
            kept += [UInt32(3 * t), UInt32(3 * t + 1), UInt32(3 * t + 2)]
            if uv <= 0 { flipped += 1 }
            uvTotal += uv; worldTotal += world
            ratios.append(uv / world)
        }
        XCTAssertEqual(flipped, 0, "\(name): folded triangles", file: file, line: line)
        let mean = uvTotal / worldTotal
        let spread = ratios.map { max($0 / mean, mean / max($0, 1e-20)) }.sorted()
        XCTAssertLessThan(spread[spread.count * 9 / 10], 2, "\(name): area stretched", file: file, line: line)
        // The layout as a mesh of its own: no texel covered twice.
        let flat = PaintMesh(positions: atlas.corners.map { SIMD3($0, 0) }, normals: [SIMD3<Float>](repeating: [0, 0, 1], count: atlas.corners.count),
                             uvs: atlas.corners, indices: kept)
        XCTAssertEqual(UVCheck.verdict(flat), .good, "\(name): overlaps", file: file, line: line)
        if !atlas.own { XCTAssertGreaterThan(atlas.coverage, minCoverage, "\(name): the square used", file: file, line: line) }
    }

    func testOwnUVsAreJudged() throws {
        XCTAssertEqual(UVCheck.verdict(sphere()), .tiled, "U twice round")
        XCTAssertNotEqual(UVCheck.verdict(cube()), .good, "every face on the same tile")
        let quad = PaintMesh(positions: [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]], normals: [SIMD3<Float>](repeating: [0, 0, 1], count: 4),
                             uvs: [[0, 0], [1, 0], [1, 1], [0, 1]], indices: [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(UVCheck.verdict(quad), .good)
        XCTAssertEqual(UVCheck.verdict(PaintMesh(positions: quad.positions, normals: quad.normals, indices: quad.indices)), .missing)
        let atlas = UVUnwrap.atlas(quad, resolution: 1024)
        XCTAssertTrue(atlas.own)
        XCTAssertEqual(atlas.texelsPerMetre, 1024, accuracy: 1, "a metre square over the whole square")
        XCTAssertEqual(atlas.chartCount, 1)
    }

    func testShapesUnwrap() {
        for (name, mesh) in [("cube", cube()), ("sphere", sphere()), ("cylinder", cylinder())] {
            let atlas = UVUnwrap.unwrap(mesh, resolution: 2048)
            check(mesh, atlas, name)
            print("Painter unwrap: \(name): \(mesh.triangleCount) triangles, \(atlas.chartCount) charts, coverage \(atlas.coverage)")
        }
        // A cube is six charts (its faces meet at right angles: past the cone).
        XCTAssertEqual(UVUnwrap.unwrap(cube(), resolution: 1024).chartCount, 6)
    }

    func testTheUnwrapIsTheSameEveryTime() {
        let a = UVUnwrap.unwrap(sphere(), resolution: 1024), b = UVUnwrap.unwrap(sphere(), resolution: 1024)
        XCTAssertEqual(a, b)
    }

    func testGuttersKeepChartsApart() {
        for (name, mesh) in [("cube", cube()), ("cylinder", cylinder()), ("sphere", sphere())] {
            let atlas = UVUnwrap.unwrap(mesh, resolution: 256)
            let pad = Float(UVUnwrap.padding(256))
            let tri = (0..<atlas.corners.count / 3).map { t in (0..<3).map { atlas.corners[3 * t + $0] * 256 } }
            for p in tri.joined() {
                XCTAssertGreaterThanOrEqual(min(p.x, p.y), pad - 1e-3, "\(name): the border's gutter")
                XCTAssertLessThanOrEqual(max(p.x, p.y), 256 - pad + 1e-3, "\(name): the border's gutter")
            }
            // Any two triangles of different charts at least 2 x padding apart (outlines interlock: their boxes may not).
            let gap = 2 * pad - 1e-2
            let order = tri.indices.sorted { tri[$0].map(\.x).min()! < tri[$1].map(\.x).min()! }
            var closest = Float.infinity
            for (n, a) in order.enumerated() {
                let aHi = tri[a].map(\.x).max()!
                for b in order[(n + 1)...] {
                    if tri[b].map(\.x).min()! > aHi + gap { break }
                    guard atlas.chartOfTriangle[a] != atlas.chartOfTriangle[b] else { continue }
                    closest = min(closest, distance(tri[a], tri[b]))
                }
            }
            XCTAssertGreaterThanOrEqual(closest, gap, "\(name): charts' gutters")
        }
    }

    /// Two triangles' distance apart (0 if they cross): a corner of one to an edge of the other, nearest.
    private func distance(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Float {
        func toSegment(_ p: SIMD2<Float>, _ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float {
            let d = v - u, l = simd_length_squared(d)
            let s = l > 0 ? min(max(simd_dot(p - u, d) / l, 0), 1) : 0
            return simd_distance(p, u + s * d)
        }
        func crosses(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Bool {
            let d1 = UVCheck.cross2(q - p, u - p), d2 = UVCheck.cross2(q - p, v - p)
            let d3 = UVCheck.cross2(v - u, p - u), d4 = UVCheck.cross2(v - u, q - u)
            return d1 * d2 < 0 && d3 * d4 < 0
        }
        var best = Float.infinity
        for i in 0..<3 {
            for j in 0..<3 {
                if crosses(a[i], a[(i + 1) % 3], b[j], b[(j + 1) % 3]) { return 0 }
                best = min(best, toSegment(a[i], b[j], b[(j + 1) % 3]), toSegment(b[j], a[i], a[(i + 1) % 3]))
            }
        }
        return best
    }

    func testModelAndCharacterUnwrap() throws {
        for (name, make) in [("character", character), ("model", model)] {
            let mesh: PaintMesh
            do { mesh = try make() } catch { print("Painter unwrap: \(name) skipped: \(error)"); continue }
            let start = Date()
            let atlas = UVUnwrap.unwrap(mesh, resolution: 2048)
            let seconds = Date().timeIntervalSince(start)
            print("Painter unwrap: \(name): \(mesh.triangleCount) triangles, \(atlas.chartCount) charts, coverage \(atlas.coverage), \(String(format: "%.2f", seconds)) s; own UVs \(UVCheck.verdict(mesh))")
            // (Many charts of uneven outline, packed by their outlines: two fifths of the square.)
            check(mesh, atlas, name, minCoverage: 0.36)
            XCTAssertLessThan(seconds / Double(max(mesh.triangleCount, 1)) * 50_000, 1.5, "\(name): 50k triangles in 1.5 s")
        }
    }
}

extension PainterUnwrapTests {
    /// Where an unwrap's square goes: its charts' triangles, their boxes (the rest is their shapes' waste), the boxes
    /// with their gutters (the rest is the packing's).
    func testUnwrapStats() throws {
        guard ProcessInfo.processInfo.environment["PAINTER_UNWRAP_STATS"] != nil else { throw XCTSkip("PAINTER_UNWRAP_STATS=1") }
        for (name, make) in [("model", model), ("character", character)] {
            guard let mesh = try? make() else { continue }
            let atlas = UVUnwrap.unwrap(mesh, resolution: 2048)
            var lo = [SIMD2<Float>](repeating: SIMD2(repeating: .infinity), count: atlas.chartCount), hi = lo.map { -$0 }
            var area = [Float](repeating: 0, count: atlas.chartCount), count = [Int](repeating: 0, count: atlas.chartCount)
            for t in 0..<atlas.corners.count / 3 {
                let c = Int(atlas.chartOfTriangle[t])
                for k in 0..<3 { lo[c] = simd_min(lo[c], atlas.corners[3 * t + k]); hi[c] = simd_max(hi[c], atlas.corners[3 * t + k]) }
                area[c] += abs(UVCheck.cross2(atlas.corners[3 * t + 1] - atlas.corners[3 * t], atlas.corners[3 * t + 2] - atlas.corners[3 * t])) / 2
                count[c] += 1
            }
            let pad = Float(UVUnwrap.padding(2048)) / 2048
            var boxes: Float = 0, padded: Float = 0
            for c in 0..<atlas.chartCount {
                let s = hi[c] - lo[c]
                boxes += s.x * s.y
                padded += (s.x + 2 * pad) * (s.y + 2 * pad)
            }
            let sizes = count.sorted()
            print("Painter stats: \(name): \(atlas.chartCount) charts (triangles: median \(sizes[sizes.count / 2]), max \(sizes.last ?? 0)); "
                  + "triangles \(area.reduce(0, +)), boxes \(boxes), padded \(padded)")
        }
    }
}
