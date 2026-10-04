import XCTest
import ImageIO
@testable import MetalRenderer

/// The city's generated textures (ProceduralTextures.swift), at a small size and in a folder of their own.
final class ProceduralTextureTests: XCTestCase {
    private let size = 64

    func testMapsAreSeededAndComplete() {
        for kind in SurfaceKind.allCases {
            let a = ProceduralTextures.generate(kind, size: size), b = ProceduralTextures.generate(kind, size: size)
            XCTAssertEqual(a.base, b.base, "\(kind)")
            XCTAssertEqual(a.normal, b.normal, "\(kind)")
            XCTAssertEqual(a.base.count, size * size * 4)
            XCTAssertEqual(a.normal.count, size * size * 4)
            XCTAssertEqual(a.roughness != nil, kind.hasRoughness)
            XCTAssertGreaterThan(Set(a.base).count, 8, "\(kind): a flat colour")
            // Normals lean, but point out of the surface.
            for i in stride(from: 0, to: a.normal.count, by: 4) { XCTAssertGreaterThan(a.normal[i + 2], 140, "\(kind)") }
            // Light enough for a material's colour to tint.
            let mean = stride(from: 0, to: a.base.count, by: 4).reduce(0) { $0 + Int(a.base[$1 + 1]) } / (size * size)
            XCTAssertGreaterThan(mean, 150, "\(kind) is dark")
        }
    }

    /// A tile's last column meets its first as any column meets the next (and its rows the same).
    func testMapsTile() {
        for kind in SurfaceKind.allCases {
            let m = ProceduralTextures.generate(kind, size: size)
            func step(_ x0: Int, _ x1: Int, columns: Bool) -> Double {
                (0..<size).reduce(0.0) { sum, k in
                    let a = columns ? (k * size + x0) * 4 : (x0 * size + k) * 4, b = columns ? (k * size + x1) * 4 : (x1 * size + k) * 4
                    return sum + abs(Double(m.base[a]) - Double(m.base[b]))
                } / Double(size)
            }
            for columns in [true, false] {
                let inside = (0..<size - 1).map { step($0, $0 + 1, columns: columns) }.max()!
                XCTAssertLessThanOrEqual(step(size - 1, 0, columns: columns), inside + 1, "\(kind): a seam at the tile's edge")
            }
        }
    }

    func testSourcesAreWrittenOnceAndReadBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("metalrenderer-textures-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kinds: [SurfaceKind] = [.brick, .metalpanel]
        let first = ProceduralTextures.sources(kinds, in: folder, size: size)
        XCTAssertEqual(Set(first.keys), Set(kinds))
        XCTAssertNil(first[.brick]!.roughness)
        XCTAssertNotNil(first[.metalpanel]!.roughness)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files.count, 5)
        // Each kind's maps share a model (the streamer's cache file) and differ in their keys.
        let brick = first[.brick]!
        XCTAssertEqual(brick.base.modelPath, brick.normal.modelPath)
        XCTAssertNotEqual(brick.base.cacheKey, brick.normal.cacheKey)
        XCTAssertNotEqual(brick.base.modelPath, first[.metalpanel]!.base.modelPath)
        XCTAssertTrue(brick.base.srgb)
        XCTAssertFalse(brick.normal.srgb)
        // They decode, at the size they were made.
        let image = try XCTUnwrap(CGImageSourceCreateWithData(brick.base.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, size)
        XCTAssertEqual(image.height, size)
        // A second call reads what the first wrote.
        let stamp = try FileManager.default.attributesOfItem(atPath: brick.base.modelPath)[.modificationDate] as? Date
        let second = ProceduralTextures.sources(kinds, in: folder, size: size)
        XCTAssertEqual(second[.brick]!.base.data, brick.base.data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: brick.base.modelPath)[.modificationDate] as? Date, stamp)
    }
}
