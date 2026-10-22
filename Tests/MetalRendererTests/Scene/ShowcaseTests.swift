import XCTest
import simd
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Plants

/// The showcase (Showcase.swift, Scene+Showcase.swift): every model of Assets/ has a look of its own, a setting names
/// its model, and the lens effects are the showcase's and, outdoors, the realistic look's alone.
final class ShowcaseTests: XCTestCase {
    func testEveryAssetHasItsOwnLook() throws {
        let files = Scene.galleryFiles()
        try XCTSkipIf(files.isEmpty, "no models in \(Scene.assetsDirectory.path)")
        for url in files {
            let name = Scene.showcaseKey(url.lastPathComponent)
            XCTAssertNotNil(ShowcaseLook.looks.first { name.contains($0.match) }, "\(url.lastPathComponent) has no look of its own")
        }
    }

    func testModelsAreFoundByTheirNames() throws {
        let files = Scene.galleryFiles()
        try XCTSkipIf(files.isEmpty, "no models in \(Scene.assetsDirectory.path)")
        XCTAssertEqual(Scene.showcaseFile(""), files.first)
        for url in files {
            XCTAssertEqual(Scene.showcaseFile(Scene.showcaseName(url)), url, "\(Scene.showcaseName(url)) finds another model")
            XCTAssertEqual(Scene.showcaseFile(Scene.showcaseName(url).uppercased()), url)
        }
        XCTAssertNil(Scene.showcaseFile("no such model"))
    }

    func testNames() {
        XCTAssertEqual(Scene.showcaseName(URL(fileURLWithPath: "/a/steampunk owl 3d model.glb")), "steampunk owl")
        XCTAssertEqual(Scene.showcaseName(URL(fileURLWithPath: "/a/Winged_Harpy_Warrior.glb.glb")), "Winged Harpy Warrior")
        XCTAssertEqual(Scene.showcaseKey("Winged_Harpy_Warrior.glb.glb"), "winged harpy warrior.glb.glb")
    }

    func testUnknownModelGetsTheStudio() {
        XCTAssertEqual(ShowcaseLook.look(forFile: URL(fileURLWithPath: "/a/teapot.glb")).stage, .studio)
        XCTAssertEqual(ShowcaseLook.look(for: "no such model").stage, .studio)
    }

    /// The realistic look (Realism) gives the outdoor scenes a camera's lens (auto exposure, a grade, bloom and
    /// vignette) and haze in their fog; every other scene, and every scene with the look off, has no lens and its kind's fog.
    func testLensIsTheShowcasesAndTheRealisticLooksAlone() {
        for kind in SceneKind.allCases where kind != .showcase {
            var scene = SceneSettings(kind: kind)
            scene.realism = .off
            XCTAssertFalse(PostSettings.preset(for: scene).isOn, "\(kind) has lens effects with the realistic look off")
            XCTAssertEqual(FogSettings.preset(for: scene), FogSettings.preset(for: kind), "\(kind)")
            for realism in Realism.allCases where realism != .off {
                scene.realism = realism
                let post = PostSettings.preset(for: scene), fog = FogSettings.preset(for: scene)
                XCTAssertEqual(post.isOn, kind.hasRealisticLook, "\(kind), realism \(realism)")
                if kind.hasRealisticLook {
                    XCTAssertTrue(post.autoExposure, "\(kind)")
                    XCTAssertGreaterThan(fog.haze, FogSettings.preset(for: kind).haze, "\(kind)'s aerial perspective")
                } else {
                    XCTAssertEqual(fog, FogSettings.preset(for: kind), "\(kind)")
                }
            }
        }
        var s = RenderSettings()
        s.applySceneDefaults(from: RenderSettings())
        XCTAssertFalse(s.post.isOn)
    }

    func testShowcaseDefaultsFollowTheModel() throws {
        try XCTSkipIf(Scene.showcaseFile("submarine") == nil, "no submarine in \(Scene.assetsDirectory.path)")
        var s = RenderSettings()
        s.scene.kind = .showcase
        s.scene.showcase = "submarine"
        s.applySceneDefaults(from: RenderSettings())
        let look = ShowcaseLook.look(for: "submarine")
        XCTAssertEqual(look.stage, .underwater)
        XCTAssertEqual(s.post, look.post)
        XCTAssertTrue(s.fog.enabled || FogSettings.override == false)
        XCTAssertNotEqual(s.fog, FogSettings.preset(for: .showcase), "the look's fog")
    }

    func testCylinderMesh() {
        let m = Scene.cylinderMesh(segments: 8)
        XCTAssertEqual(m.positions.count, m.normals.count)
        XCTAssertEqual(m.indices.count, 8 * 6 + 8 * 3)
        XCTAssertTrue(m.indices.allSatisfy { Int($0) < m.positions.count })
        XCTAssertTrue(m.positions.allSatisfy { $0.y >= 0 && $0.y <= 1 && simd_length(SIMD2($0.x, $0.z)) <= 1.0001 })
    }
}
