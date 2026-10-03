import XCTest
@testable import MetalRenderer

/// The benchmark modes (Benchmark+Modes.swift) and the `Benchmark.Config` modifiers they are built with.
final class BenchmarkModesTests: XCTestCase {
    func testEveryModeHasNamedSettings() {
        XCTAssertGreaterThan(Benchmark.modes.count, 20)
        for (mode, build) in Benchmark.modes {
            let list = build()
            XCTAssertFalse(list.isEmpty, mode)
            for c in list {
                XCTAssertFalse(c.name.isEmpty, "\(mode): a setting has no name")
                if c.accumulate { XCTAssertTrue(c.settings.paused, "\(mode) \(c.name): a reference must be paused") }
            }
        }
        XCTAssertFalse(Benchmark.configs(for: "1").isEmpty)
    }

    func testBenchmarkDefaultsDifferFromTheApps() {
        let c = Benchmark.Config("x")
        XCTAssertEqual(c.settings.renderScale, 0.75)
        XCTAssertEqual(c.settings.upscaleFactor, 0)
        XCTAssertEqual(c.settings.giMode, .pathTraced)
        XCTAssertTrue(c.settings.giEnabled)
        XCTAssertFalse(Benchmark.Config("x", gi: nil).settings.giEnabled)
    }

    func testModifiers() {
        let base = Benchmark.Config("base", scale: 0.5)
        let still = base.still(previous: true)
        XCTAssertTrue(still.settings.paused)
        XCTAssertEqual(still.startTime, 5)
        XCTAssertTrue(still.capturePrevious)
        XCTAssertFalse(base.settings.paused, "modifiers return copies")

        let ref = base.reference(frames: 64, at: 40, supersample: true)
        XCTAssertTrue(ref.accumulate && ref.settings.paused && ref.supersample)
        XCTAssertEqual(ref.frames, 64)
        XCTAssertEqual(ref.startTime, 40)

        let moving = still.frames(30).moving()
        XCTAssertFalse(moving.settings.paused)
        XCTAssertNil(moving.frames)
        XCTAssertFalse(moving.capturePrevious)
        XCTAssertEqual(moving.startTime, 5, "it keeps its start time")

        XCTAssertEqual(base.named("other").view(4).settings.viewMode, 4)
        XCTAssertTrue(base.cameraMove().cameraPath)
    }

    func testEnvListsOverrideASetting() {
        let c = Benchmark.Config("x", scale: 0.5).direct(.grouped)
        let s = c.resolvedSettings(env: ["METALRENDERER_GI": "mode=cascades,bounces=3", "METALRENDERER_VIEW": "paused=1,fov=70",
                                         "METALRENDERER_DENOISE": "on=0"])
        XCTAssertEqual(s.giMode, .radianceCascades)
        XCTAssertEqual(s.bounces, 3)
        XCTAssertEqual(s.fovDegrees, 70)
        XCTAssertFalse(s.paused, "benchmarks choose the pause themselves")
        XCTAssertFalse(s.denoiser.enabled)
        XCTAssertEqual(s.directLight, .grouped)
        // References keep their own GI settings.
        let ref = c.reference(frames: 8).resolvedSettings(env: ["METALRENDERER_GI": "mode=cascades,bounces=3"])
        XCTAssertEqual(ref.giMode, .pathTraced)
        XCTAssertEqual(ref.bounces, 2)
    }

    /// METALRENDERER_SCENE loads its scene in every setting: with that scene's fog and sky, unless the setting set its own.
    func testASceneOverrideBringsItsPresets() {
        let env = ["METALRENDERER_SCENE": "valley"]
        let plain = Benchmark.Config("x").resolvedSettings(env: env)
        XCTAssertEqual(plain.scene.kind, .valley)
        XCTAssertEqual(plain.fog, FogSettings.preset(for: .valley))
        XCTAssertEqual(plain.sky, SkySettings.preset(for: .valley))
        let own = Benchmark.Config("x").fog { $0.density = 0.2 }.sky { $0 = SkySettings() }.resolvedSettings(env: env)
        XCTAssertEqual(own.fog.density, 0.2)
        XCTAssertEqual(own.sky, SkySettings())
        // Without an override, a scene's own presets.
        let market = Benchmark.Config("x", scene: SceneSettings(kind: .market)).resolvedSettings(env: [:])
        XCTAssertEqual(market.fog, FogSettings.preset(for: .market))
    }
}
