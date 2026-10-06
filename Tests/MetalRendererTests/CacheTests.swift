import XCTest
@testable import MetalRenderer

/// The blue-noise tile's cache file (BlueNoise.swift, CacheFile.swift) and the generated scenes' section files
/// (SectionFile.swift).
final class CacheTests: XCTestCase {
    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CacheTests-\(UUID().uuidString)-\(name)")
    }

    /// What goes into a section file comes out of it, for each kind of array the caches keep; a file for another
    /// key, of another format or cut short is a miss, and so is a section read as another type.
    func testSectionFileRoundTrip() throws {
        var node = BVHNode()
        node.setChild(0, lo: [1, 2, 3], hi: [4, 5, 6], ref: BVHNode.leafBit | 7, mask: 3)
        node.setChild(1, lo: [-1, -2, -3], hi: [0, 0.5, 9], ref: 12, mask: 1)
        let nodes = [node, BVHNode(), node]
        let triangles = (0..<9).map { SIMD4<Float>(Float($0), 0.5, -2, Float(bitPattern: UInt32($0) << 20)) }
        let words: [UInt32] = [0, 1, .max, 0x8000_0001]
        let bases = [0, 3, 1 << 40]
        let grids = [FoliageVoxels.Grid(lo: [1, 2, 3, 0.25], dims: [32, 20, 31, 1], offsets: [0, 100, 120, 0])]
        let empty: [UInt32] = []
        var writer = SectionFile.Writer()
        writer.add(SectionFile.id("node"), nodes)
        writer.add(SectionFile.id("tris"), triangles)
        writer.add(SectionFile.id("word"), words)
        writer.add(SectionFile.id("base"), bases)
        writer.add(SectionFile.id("grid"), grids)
        writer.add(SectionFile.id("none"), empty)
        // A section of several arrays' bytes, one after the other (a tile's chunks): no array of them all is made.
        let parts = [words, [], [7, 8], Array(0..<20_000)].map { part in part.withUnsafeBytes { Data($0) } }
        writer.add(SectionFile.id("part"), stride: MemoryLayout<UInt32>.stride, parts: parts)
        let url = temporary("round.sect")
        defer { try? FileManager.default.removeItem(at: url) }
        try writer.write(to: url, key: "key 1")

        let file = try XCTUnwrap(SectionFile(url: url, key: "key 1"))
        let readNodes: [BVHNode] = try XCTUnwrap(file.array(SectionFile.id("node")))
        XCTAssertEqual(readNodes.map { [$0.lo0, $0.hi0, $0.lo1, $0.hi1] }.joined().map(\.w.bitPattern),
                       nodes.map { [$0.lo0, $0.hi0, $0.lo1, $0.hi1] }.joined().map(\.w.bitPattern))
        XCTAssertEqual(readNodes.map { $0.lo(0) }, nodes.map { $0.lo(0) })
        XCTAssertEqual(file.array(SectionFile.id("tris"), of: SIMD4<Float>.self)?.map(\.w.bitPattern), triangles.map(\.w.bitPattern))
        XCTAssertEqual(file.array(SectionFile.id("word")), words)
        XCTAssertEqual(file.array(SectionFile.id("base")), bases)
        XCTAssertEqual(file.array(SectionFile.id("grid"), of: FoliageVoxels.Grid.self)?.first?.dims, grids[0].dims)
        XCTAssertEqual(file.array(SectionFile.id("none")), empty)
        XCTAssertEqual(file.array(SectionFile.id("part")), words + [7, 8] + Array(0..<20_000))
        XCTAssertEqual(file.mapped(SectionFile.id("part"), of: UInt32.self)?.count, 4 * (words.count + 2 + 20_000))
        XCTAssertNil(file.array(SectionFile.id("gone"), of: UInt32.self))
        XCTAssertNil(file.array(SectionFile.id("word"), of: UInt64.self), "a section of another type's size")
        // Every section starts on a page, so a buffer can be made over it where it is mapped.
        let whole = try Data(contentsOf: url)
        XCTAssertEqual(file.withBytes(SectionFile.id("tris")) { tris in
            whole.withUnsafeBytes { all in (tris.baseAddress! - all.baseAddress!) % SectionFile.pageSize }
        } == nil, false)
        XCTAssertEqual(whole.count % SectionFile.pageSize == 0 || whole.count > SectionFile.pageSize, true)

        // Written under another name and moved into place: nothing is left beside it, and a second write replaces it.
        try writer.write(to: url, key: "key 3")
        XCTAssertNotNil(SectionFile(url: url, key: "key 3"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(url.lastPathComponent) && $0 != url.lastPathComponent }, [])
        XCTAssertNil(SectionFile(url: url, key: "key 1"), "another key")
        try writer.write(to: url, key: "key 1")
        XCTAssertNil(SectionFile(url: url, key: "key 2"), "another key")
        XCTAssertNil(SectionFile(url: temporary("missing.sect"), key: "key 1"), "no file")
        let cut = temporary("cut.sect")
        defer { try? FileManager.default.removeItem(at: cut) }
        try whole.prefix(whole.count - 8).write(to: cut)
        XCTAssertNil(SectionFile(url: cut, key: "key 1"), "cut short")
        var other = whole
        other[4] = 99   // the format's version
        try other.write(to: cut)
        XCTAssertNil(SectionFile(url: cut, key: "key 1"), "another format")
    }

    /// The cached tile is whole: every rank once, as (rank + 0.5) / count. (Generating one to compare takes a debug
    /// build 40 s; the cache's name carries the generator's parameters and a version instead.)
    func testBlueNoiseTileIsCachedWhole() {
        let tile = BlueNoise.tile()   // generates and writes the cache on a machine that never ran the app
        let count = BlueNoise.size * BlueNoise.size
        XCTAssertEqual(tile.count, count)
        XCTAssertEqual(BlueNoise.cached(), tile)
        var seen = [Bool](repeating: false, count: count)
        for v in tile {
            let rank = Int((v * Float(count)).rounded(.down))
            XCTAssertTrue(rank >= 0 && rank < count && !seen[rank], "value \(v)")
            if rank >= 0 && rank < count { seen[rank] = true }
        }
    }

    /// A virtual-geometry cache file with many meshes (the golem has dozens): its header outgrows the page it was
    /// padded to unless each mesh's record is counted at its real size. What goes in comes back.
    func testVirtualGeometryCacheWithManyMeshes() throws {
        let url = temporary("many.mgv")
        defer { try? FileManager.default.removeItem(at: url) }
        let quad = VirtualGeometryBuilder.build(positions: [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]], normals: Array(repeating: [0, 0, 1], count: 4),
                                                uvs: Array(repeating: .zero, count: 4), indices: [0, 1, 2, 0, 2, 3], name: "quad") { _ in }
        let meshes = (0..<600).map { (index: $0 * 3, mesh: quad) }
        try VirtualGeometryBuilder.write(meshes, to: url)
        let read = try VirtualGeometryBuilder.read(url)
        XCTAssertEqual(read.count, meshes.count)
        XCTAssertEqual(read[597]?.triangleCount, quad.triangleCount)
        XCTAssertEqual(read[597]?.pageData.count, quad.pageData.count)
        XCTAssertEqual(read[597]?.clusters.count, quad.clusters.count)
    }

    func testAtomicWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CacheTests-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try CacheFile.write(Data([1, 2, 3]), to: url)
        try CacheFile.write(Data([4, 5]), to: url)   // replaces
        XCTAssertEqual(try Data(contentsOf: url), Data([4, 5]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(url.lastPathComponent) && $0 != url.lastPathComponent }
        XCTAssertEqual(leftovers, [])
    }
}
