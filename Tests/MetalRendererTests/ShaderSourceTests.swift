import XCTest
import Metal
@testable import MetalRenderer

/// ShaderSource.swift: Shaders.metal lists the pieces in Shaders/, and the loader splices them in.
final class ShaderSourceTests: XCTestCase {
    private let entry = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")

    /// A scratch folder with an entry file and its pieces.
    private func scratch(entry text: String, pieces: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShaderSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Shaders"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for (name, body) in pieces {
            try body.write(to: folder.appendingPathComponent("Shaders/\(name)"), atomically: true, encoding: .utf8)
        }
        let url = folder.appendingPathComponent("Shaders.metal")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEveryPieceIsIncludedOnce() throws {
        let listed = try ShaderSource.pieces(of: entry)
        let folder = entry.deletingLastPathComponent().appendingPathComponent("Shaders")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".metal") }
        XCTAssertEqual(Set(listed), Set(files.map { "Shaders/\($0)" }), "Shaders.metal must include every file in Shaders/")
        XCTAssertEqual(listed.count, Set(listed).count)
        XCTAssertFalse(listed.isEmpty)
    }

    func testIncludeLines() {
        XCTAssertEqual(ShaderSource.includePath(in: "#include \"Shaders/Fog.metal\"   // fog"), "Shaders/Fog.metal")
        XCTAssertEqual(ShaderSource.includePath(in: "  #include   \"A.metal\""), "A.metal")
        XCTAssertNil(ShaderSource.includePath(in: "#include <metal_stdlib>"))
        XCTAssertNil(ShaderSource.includePath(in: "// #include \"A.metal\""))
    }

    func testSplicingAndLineMarkers() throws {
        let url = try scratch(entry: "a\n#include \"Shaders/One.metal\"  // first\nb\n#include \"Shaders/Two.metal\"\n",
                              pieces: ["One.metal": "one\n", "Two.metal": "two"])   // Two has no final newline
        XCTAssertEqual(try ShaderSource.load(url, lineMarkers: false), "a\none\nb\ntwo\n")
        XCTAssertEqual(try ShaderSource.load(url), """
            #line 1 "Shaders.metal"
            a
            #line 1 "Shaders/One.metal"
            one
            #line 3 "Shaders.metal"
            b
            #line 1 "Shaders/Two.metal"
            two
            #line 5 "Shaders.metal"

            """)
    }

    func testBadPiecesAreRefused() throws {
        func message(_ entry: String, _ pieces: [String: String]) throws -> String {
            let url = try scratch(entry: entry, pieces: pieces)
            do { _ = try ShaderSource.load(url); return "" } catch { return "\(error)" }
        }
        XCTAssertEqual(try message("#include \"Shaders/Gone.metal\"\n", [:]), "Shaders.metal:1: Shaders/Gone.metal not found")
        XCTAssertEqual(try message("x\n#include \"Shaders/A.metal\"\n#include \"Shaders/A.metal\"\n", ["A.metal": "a\n"]),
                       "Shaders.metal:3: Shaders/A.metal is included twice")
        XCTAssertEqual(try message("#include \"Shaders/A.metal\"\n", ["A.metal": "a\n#include \"Shaders/B.metal\"\n", "B.metal": ""]),
                       "Shaders/A.metal:2: a piece cannot include another; list it in the entry file")
        XCTAssertEqual(try message("#include \"Shaders/A.metal\"\n", ["A.metal": "#if X\na\n"]),
                       "Shaders/A.metal: an #if is not closed in this piece")
        XCTAssertEqual(try message("#include \"Shaders/A.metal\"\n", ["A.metal": "a\n#endif\n"]),
                       "Shaders/A.metal:2: #endif without an #if in this piece")
        XCTAssertEqual(try message("#include \"Shaders/A.metal\"\n", ["A.metal": "#ifndef X\n#define X 1\n#else\n#endif\n"]), "")
    }

    /// The point of the markers: the compiler reports an error at the piece's own file and line.
    func testCompileErrorsNameThePiece() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let url = try scratch(entry: "#include <metal_stdlib>\nusing namespace metal;\n#include \"Shaders/Good.metal\"\n"
                                  + "#include \"Shaders/Broken.metal\"\nfloat late() { return alsoMissing; }\n",
                              pieces: ["Good.metal": "inline float one() { return 1.0f; }\n",
                                       "Broken.metal": "inline float two() {\n    return missing;\n}\n"])
        XCTAssertThrowsError(try device.makeLibrary(source: try ShaderSource.load(url), options: nil)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("Shaders/Broken.metal:2:"), text)
            XCTAssertTrue(text.contains("Shaders.metal:5:"), text)
        }
    }
}
