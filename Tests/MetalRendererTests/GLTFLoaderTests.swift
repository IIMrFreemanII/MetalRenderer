import XCTest
@testable import MetalRenderer

/// The glTF loader (GLTFLoader.swift).
final class GLTFLoaderTests: XCTestCase {
    /// A model checked out without git-lfs is the pointer's text: the error says so, not that the JSON is invalid.
    func testLFSPointerIsNamed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GLTFLoaderTests-\(UUID().uuidString).glb")
        defer { try? FileManager.default.removeItem(at: url) }
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "0", count: 64))\nsize 1234\n"
        try Data(pointer.utf8).write(to: url)
        XCTAssertThrowsError(try GLTFLoader.load(url)) { error in
            XCTAssertTrue("\(error)".contains("Git LFS"), "\(error)")
        }
    }
}
