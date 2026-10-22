import XCTest
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

/// The OpenEXR reader (EXRImage.swift) against what the OpenEXR library itself decodes from the same files: the
/// fixtures in Tools/test-assets/exr, which make.py there writes (with the library's Python package) together with
/// the library's decodes.
final class EXRImageTests: XCTestCase {
    private static let folder = SourceTree.packageRoot.appendingPathComponent("Tools/test-assets/exr")
    private static let width = 37, height = 41
    /// Each fixture image's channels, in name order (the order of the reference files).
    private static let images = ["color": ["A", "B", "G", "R", "Z", "id"], "gray": ["Y"], "floatrgb": ["B", "G", "R"]]

    private func fixture(_ name: String) throws -> URL {
        let url = Self.folder.appendingPathComponent(name)
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 20) ?? Data()
        if head.starts(with: Data("version https://git-lfs".utf8)) { throw XCTSkip("\(name) is a Git LFS pointer: git lfs pull") }
        return url
    }

    /// A reference file: each channel's floats, in name order.
    private func reference(_ name: String, _ channels: [String]) throws -> [String: [Float]] {
        let data = try Data(contentsOf: fixture("ref_\(name).bin"))
        let n = Self.width * Self.height
        XCTAssertEqual(data.count, channels.count * n * 4, name)
        let floats = data.withUnsafeBytes { bytes in
            (0..<data.count / 4).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        var result: [String: [Float]] = [:]
        for (c, channel) in channels.enumerated() { result[channel] = Array(floats[c * n..<(c + 1) * n]) }
        return result
    }

    /// How far two halves are apart, in steps of the half grid (0: the same half).
    private func halfSteps(_ a: Float, _ b: Float) -> Int {
        func ordered(_ x: Float) -> Int {
            let bits = Int(Float16(x).bitPattern)
            return bits & 0x8000 != 0 ? -(bits & 0x7fff) : bits
        }
        return abs(ordered(a) - ordered(b))
    }

    private func read(_ file: String, against expected: [String: [Float]], maxHalfSteps: Int = 0,
                      line: UInt = #line) throws -> (different: Int, steps: Int) {
        let image = try EXRImage.read(fixture(file))
        XCTAssertEqual(image.width, Self.width, file, line: line)
        XCTAssertEqual(image.height, Self.height, file, line: line)
        XCTAssertEqual(image.channels.keys.sorted(), expected.keys.sorted(), file, line: line)
        var different = 0, steps = 0
        for (name, values) in expected {
            let got = try XCTUnwrap(image.channel(name), "\(file) \(name)", line: line)
            XCTAssertEqual(got.count, values.count, line: line)
            for (g, v) in zip(got, values) where g.bitPattern != v.bitPattern && !(g.isNaN && v.isNaN) {
                different += 1
                steps = max(steps, halfSteps(g, v))
            }
        }
        if maxHalfSteps == 0 {
            XCTAssertEqual(different, 0, "\(file): \(different) values differ (up to \(steps) half steps)", line: line)
        } else {
            XCTAssertLessThanOrEqual(steps, maxHalfSteps, "\(file): \(different) values differ", line: line)
        }
        return (different, steps)
    }

    /// The lossless compressions give back the very values written.
    func testLosslessCompressionsDecodeExactly() throws {
        for (image, channels) in Self.images {
            let expected = try reference(image, channels)
            for compression in ["none", "rle", "zips", "zip", "piz"] {
                _ = try read("\(image)_\(compression).exr", against: expected)
            }
        }
    }

    /// DWAA and DWAB decode to the library's halves (and floats from them) bit for bit: the decoder is a port of
    /// the library's, with its float arithmetic as clang builds it for arm64.
    func testDWADecodesAsOpenEXRDoes() throws {
        for (image, channels) in Self.images {
            for compression in ["dwaa", "dwab"] {
                let expected = try reference("\(image)_\(compression)", channels)
                let (different, steps) = try read("\(image)_\(compression).exr", against: expected)
                if different > 0 { print("\(image)_\(compression): \(different) values differ, up to \(steps) half steps") }
            }
        }
    }

    /// Layers: DWA makes a colour set of left.R, left.G, left.B, and codes right.Y on its own.
    func testDWALayers() throws {
        let channels = ["left.B", "left.G", "left.R", "right.Y"]
        _ = try read("layers_dwaa.exr", against: try reference("layers_dwaa", channels))
    }

    /// A PIZ chunk with more than 2^14 distinct values (the 16-bit wavelet): halves counting up, pixel i holding half i.
    func testPIZWithManyValues() throws {
        let image = try EXRImage.read(fixture("ramp_piz.exr"))
        XCTAssertEqual(image.width, 540)
        XCTAssertEqual(image.height, 32)
        let y = try XCTUnwrap(image.channel("Y"))
        let mismatches = y.indices.filter { y[$0].bitPattern != Float(Float16(bitPattern: UInt16($0))).bitPattern }
        XCTAssertEqual(mismatches.count, 0)
    }

    /// Chunks that don't compress are stored as they are: hashed uints, 2654435761 i mod 2^32 for pixel i.
    func testStoredChunks() throws {
        let image = try EXRImage.read(fixture("hash_zips.exr"))
        let id = try XCTUnwrap(image.channel("id"))
        XCTAssertEqual(id.count, 256)
        for (i, v) in id.enumerated() { XCTAssertEqual(v, Float(UInt32(truncatingIfNeeded: UInt64(i) * 2654435761)), "\(i)") }
    }

    /// The lossy channels are near what was written; the RLE (A) and zlib (Z, id) channels of DWA are exact.
    func testDWAKeepsTheImage() throws {
        let written = try reference("color", Self.images["color"]!)
        let image = try EXRImage.read(fixture("color_dwaa.exr"))
        for name in ["A", "Z", "id"] { XCTAssertEqual(image.channel(name), written[name], name) }
        for name in ["R", "G", "B"] {
            let error = zip(image.channel(name)!, written[name]!).map { abs($0 - $1) / max(1, abs($1)) }.max()!
            XCTAssertLessThan(error, 0.05, name)
        }
    }

    /// DWA's curve back to linear light, against entries of OpenEXR's own table (dwaLookups.h in OpenEXR 3.3.2:
    /// runs of 12 from 32 places, among them 0x24f8, the one half where x^2.2 in float and double round apart).
    func testToLinearTableMatchesOpenEXR() {
        let samples: [(UInt16, [UInt16])] = [
            (0x0000, [0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000]),
            (0x03f0, [0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000]),
            (0x0fff, [0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001]),
            (0x13f8, [0x0004, 0x0004, 0x0004, 0x0004, 0x0004, 0x0004, 0x0004, 0x0004, 0x0004, 0x0004, 0x0004, 0x0004]),
            (0x1ffe, [0x0183, 0x0184, 0x0184, 0x0185, 0x0186, 0x0187, 0x0187, 0x0188, 0x0189, 0x018a, 0x018b, 0x018c]),
            (0x24f2, [0x098e, 0x0990, 0x0993, 0x0995, 0x0998, 0x099a, 0x099c, 0x099f, 0x09a1, 0x09a4, 0x09a6, 0x09a9]),
            (0x2bfb, [0x1892, 0x1893, 0x1894, 0x1896, 0x1897, 0x1898, 0x189b, 0x189d, 0x18a0, 0x18a2, 0x18a5, 0x18a7]),
            (0x33ff, [0x2a0e, 0x2a10, 0x2a13, 0x2a17, 0x2a1a, 0x2a1d, 0x2a21, 0x2a24, 0x2a28, 0x2a2b, 0x2a2e, 0x2a32]),
            (0x37f8, [0x32e8, 0x32ea, 0x32eb, 0x32ed, 0x32ef, 0x32f1, 0x32f3, 0x32f5, 0x32f7, 0x32fb, 0x32ff, 0x3302]),
            (0x3be8, [0x3bcc, 0x3bce, 0x3bd0, 0x3bd2, 0x3bd4, 0x3bd6, 0x3bd9, 0x3bdb, 0x3bdd, 0x3bdf, 0x3be1, 0x3be4]),
            (0x3ffc, [0x4879, 0x487c, 0x487e, 0x4881, 0x4883, 0x4888, 0x488d, 0x4892, 0x4897, 0x489c, 0x48a1, 0x48a6]),
            (0x41fd, [0x5507, 0x550c, 0x5512, 0x5517, 0x551d, 0x5522, 0x5528, 0x552e, 0x5534, 0x5539, 0x553f, 0x5545]),
            (0x43fe, [0x61b2, 0x61b8, 0x61be, 0x61cb, 0x61d8, 0x61e5, 0x61f2, 0x61ff, 0x620c, 0x6219, 0x6227, 0x6234]),
            (0x45ff, [0x7b3f, 0x7b4f, 0x7b5f, 0x7b70, 0x7b80, 0x7b91, 0x7ba1, 0x7bb2, 0x7bc3, 0x7bd4, 0x7be6, 0x7bf7]),
            (0x4800, [0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00]),
            (0x49f8, [0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00]),
            (0x4cfe, [0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00]),
            (0x4eff, [0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00]),
            (0x53fd, [0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00]),
            (0x57ff, [0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00]),
            (0x7bed, [0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00, 0x7c00]),
            (0x7e00, [0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000]),
            (0x7ff8, [0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x8000, 0x8000, 0x8000]),
            (0x83fa, [0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000]),
            (0xa4f2, [0x898e, 0x8990, 0x8993, 0x8995, 0x8998, 0x899a, 0x899c, 0x899f, 0x89a1, 0x89a4, 0x89a6, 0x89a9]),
            (0xaffe, [0xa144, 0xa146, 0xa147, 0xa14a, 0xa14d, 0xa150, 0xa153, 0xa156, 0xa159, 0xa15c, 0xa15f, 0xa161]),
            (0xb7f9, [0xb2ea, 0xb2eb, 0xb2ed, 0xb2ef, 0xb2f1, 0xb2f3, 0xb2f5, 0xb2f7, 0xb2fb, 0xb2ff, 0xb302, 0xb306]),
            (0xbbfb, [0xbbf5, 0xbbf7, 0xbbf9, 0xbbfc, 0xbbfe, 0xbc00, 0xbc02, 0xbc04, 0xbc07, 0xbc09, 0xbc0b, 0xbc0d]),
            (0xbffd, [0xc87c, 0xc87e, 0xc881, 0xc883, 0xc888, 0xc88d, 0xc892, 0xc897, 0xc89c, 0xc8a1, 0xc8a6, 0xc8ac]),
            (0xc3ff, [0xe1b8, 0xe1be, 0xe1cb, 0xe1d8, 0xe1e5, 0xe1f2, 0xe1ff, 0xe20c, 0xe219, 0xe227, 0xe234, 0xe242]),
            (0xc7f8, [0xfc00, 0xfc00, 0xfc00, 0xfc00, 0xfc00, 0xfc00, 0xfc00, 0xfc00, 0xfc00, 0xfc00, 0xfc00, 0xfc00]),
            (0xfc00, [0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000]),
        ]
        let table = EXRImage.dwaToLinear
        XCTAssertEqual(table.count, 65536)
        var checked = 0
        for (start, values) in samples {
            for (i, v) in values.enumerated() {
                XCTAssertEqual(table[Int(start) + i], v, String(format: "entry 0x%04x", Int(start) + i))
                checked += 1
            }
        }
        XCTAssertEqual(checked, 378)
    }

    /// A tiled file goes to ImageIO, which reads it as linear RGB(A).
    func testTiledFilesGoToImageIO() throws {
        let written = try reference("color", Self.images["color"]!)
        let image = try EXRImage.read(fixture("tiled_zip.exr"))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
        for name in ["R", "G", "B"] {
            let got = try XCTUnwrap(image.channel(name), name)
            let error = zip(got, written[name]!).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(error, 1e-3, name)
        }
    }

    /// Files that aren't EXRs, or are cut short, throw a MatError.
    func testDamagedFilesThrow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EXRImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let whole = try Data(contentsOf: fixture("color_dwaa.exr"))
        for (name, data) in [("text.exr", Data("not an image".utf8)), ("cut.exr", whole.prefix(whole.count * 2 / 3)),
                             ("header.exr", whole.prefix(200))] {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertThrowsError(try EXRImage.read(url), name) { XCTAssertTrue($0 is MatError, "\(name): \($0)") }
        }
    }

    /// Outside the suite's normal runs: EXR_CHECK=<file.exr> EXR_CHECK_REF=<floats.bin> (the library's decode, each
    /// channel's floats in name order) times the reader on a real file and compares.
    func testCheckFile() throws {
        guard let path = ProcessInfo.processInfo.environment["EXR_CHECK"] else { throw XCTSkip("EXR_CHECK not set") }
        var read: EXRImage?
        var times: [Double] = []   // the first read also maps the file in and computes the DWA curve table
        for _ in 0..<4 {
            let start = Date()
            read = try EXRImage.read(URL(fileURLWithPath: path))
            times.append(Date().timeIntervalSince(start))
        }
        let image = try XCTUnwrap(read)
        print(String(format: "EXR_CHECK %@: %d x %d, channels %@, decoded in %.3f s first, %.3f s best of 3 more",
                     path, image.width, image.height, image.channels.keys.sorted().joined(separator: ","), times[0],
                     times.dropFirst().min()!))
        guard let ref = ProcessInfo.processInfo.environment["EXR_CHECK_REF"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: ref))
        let n = image.width * image.height
        for (c, name) in image.channels.keys.sorted().enumerated() {
            let got = image.channel(name)!
            var maxError: Float = 0, different = 0, steps = 0
            data.withUnsafeBytes { bytes in
                for i in 0..<n {
                    let v = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: (c * n + i) * 4, as: UInt32.self)))
                    if v.bitPattern != got[i].bitPattern {
                        different += 1
                        maxError = max(maxError, abs(v - got[i]))
                        steps = max(steps, halfSteps(v, got[i]))
                    }
                }
            }
            print("EXR_CHECK \(name): \(different) of \(n) values differ, max abs error \(maxError), max \(steps) half steps")
            XCTAssertEqual(different, 0, name)
        }
    }
}
