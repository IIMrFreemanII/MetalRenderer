import XCTest
import simd
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

    /// A model placed again (the storeroom's copies) shares the first placement's meshes and materials, and brings its
    /// own instances and lights.
    func testAModelPlacedTwiceSharesItsMeshesAndMaterials() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tools/test-assets/punctual-lights.gltf")
        let model = try GLTFLoader.load(url)
        let scene = Scene()
        func counts() -> (meshes: Int, materials: Int, instances: Int, lights: Int) {
            (scene.meshes.count, scene.materials.count, scene.instances.count, scene.lights.count)
        }
        let before = counts()
        scene.addModel(model, url: url, transform: matrix_identity_float4x4)
        let once = counts()
        XCTAssertGreaterThan(once.meshes, before.meshes)
        XCTAssertGreaterThan(once.instances, before.instances)
        scene.addModel(model, url: url, transform: translate([3, 0, 0]))
        let twice = counts()
        XCTAssertEqual(twice.meshes, once.meshes)
        // (each light's proxy brings a material of its own; the model's, and its fallback, come once)
        XCTAssertEqual(twice.materials - once.materials, once.materials - before.materials - (model.materials.count + 1))
        XCTAssertEqual(twice.instances - once.instances, once.instances - before.instances)
        XCTAssertEqual(twice.lights - once.lights, once.lights - before.lights)
        XCTAssertEqual(scene.instances[once.instances].mesh, scene.instances[before.instances].mesh)
    }
}
