import XCTest
@testable import MetalRenderer

/// The blue-noise tile's cache file (BlueNoise.swift, CacheFile.swift).
final class CacheTests: XCTestCase {
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
