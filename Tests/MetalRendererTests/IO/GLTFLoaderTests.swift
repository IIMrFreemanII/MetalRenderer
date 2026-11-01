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

/// The glTF loader (GLTFLoader.swift).
final class GLTFLoaderTests: XCTestCase {
    /// The material extensions past metal and plastic: cloth, brushed metal and solid glass.
    func testMaterialExtensions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GLTFLoaderTests-\(UUID().uuidString).gltf")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"asset": {"version": "2.0"}, "materials": [
            {"extensions": {"KHR_materials_sheen": {"sheenColorFactor": [1, 0.5, 0.25], "sheenRoughnessFactor": 0.4},
                            "KHR_materials_anisotropy": {"anisotropyStrength": 0.8, "anisotropyRotation": 1.5}}},
            {"extensions": {"KHR_materials_transmission": {"transmissionFactor": 1}, "KHR_materials_ior": {"ior": 1.33},
                            "KHR_materials_volume": {"attenuationColor": [0.25, 1, 1], "attenuationDistance": 2}}}],
         "extensionsRequired": ["KHR_materials_sheen", "KHR_materials_transmission"]}
        """
        try Data(json.utf8).write(to: url)
        let materials = try GLTFLoader.load(url).materials
        XCTAssertEqual(materials[0].sheen, [1, 0.5, 0.25])
        XCTAssertEqual(materials[0].sheenRoughness, 0.4)
        XCTAssertEqual(materials[0].anisotropy, 0.8)
        XCTAssertEqual(materials[0].anisotropyRotation, 1.5)
        XCTAssertEqual(materials[0].transmission, 0)
        XCTAssertEqual(materials[1].transmission, 1)
        XCTAssertEqual(materials[1].ior, 1.33)
        XCTAssertEqual(materials[1].attenuation.x, 0.5, accuracy: 1e-5)   // 0.25 over 2 m: 0.5 a metre
    }

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
