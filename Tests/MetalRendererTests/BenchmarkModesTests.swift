import XCTest
import simd
@testable import MetalRenderer

/// The benchmark modes (Benchmark+Modes.swift) and the `Benchmark.Config` modifiers they are built with.
final class BenchmarkModesTests: XCTestCase {
    func testEveryModeHasNamedSettings() {
        XCTAssertGreaterThan(Benchmark.modes.count, 20)
        for (mode, build) in Benchmark.modes {
            let list = build()
            // datasetref lists what the saved dataset still needs, nothing without one (testDatasetModesResume).
            if mode != "datasetref" { XCTAssertFalse(list.isEmpty, mode) }
            for c in list {
                XCTAssertFalse(c.name.isEmpty, "\(mode): a setting has no name")
                if c.accumulate { XCTAssertTrue(c.settings.paused, "\(mode) \(c.name): a reference must be paused") }
            }
        }
        XCTAssertFalse(Benchmark.configs(for: "1").isEmpty)
    }

    /// The dataset runs (Benchmark+Dataset.swift) carry on where they stopped: the noisy pass skips a clip whose last
    /// frame has its row, the reference pass renders a reference for each row without one, at the row's time and camera.
    func testDatasetModesResume() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dataset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("METALRENDERER_DATASET_DIR"); unsetenv("METALRENDERER_DATASET") }
        setenv("METALRENDERER_DATASET_DIR", dir.path, 1)
        setenv("METALRENDERER_DATASET", "scenes=cornell,clips=1,frames=2,spp=8", 1)
        let clip = dir.appendingPathComponent("cornell-1-0")
        XCTAssertEqual(Benchmark.dataset().map(\.name), ["cornell-1-0"])
        XCTAssertTrue(Benchmark.datasetReferences().isEmpty, "no rows yet")

        try FileManager.default.createDirectory(at: clip, withIntermediateDirectories: true)
        for f in 0..<2 {
            let row = Benchmark.DatasetFrame(frame: f, time: 3 + Float(f), camera: [1, 2, 3, 0.5, -0.1, 1], jitter: [0, 0],
                                             prevJitter: [0, 0], exposure: 1, size: [640, 400], outSize: [1920, 1200])
            try JSONEncoder().encode(row).write(to: clip.appendingPathComponent(Benchmark.datasetFileName(frame: f, buffer: nil)))
        }
        XCTAssertTrue(Benchmark.dataset().isEmpty, "the clip's last frame has its row")
        let refs = Benchmark.datasetReferences()
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs.map(\.startTime), [3, 4])
        XCTAssertTrue(refs.allSatisfy { $0.accumulate && $0.supersample && $0.settings.paused && $0.frames == 8 })
        XCTAssertEqual(refs[0].camera?.position, SIMD3<Float>(1, 2, 3))

        try Data().write(to: clip.appendingPathComponent(Benchmark.datasetFileName(frame: 0, buffer: "reference")))
        XCTAssertEqual(Benchmark.datasetReferences().map(\.startTime), [4], "frame 0 has its reference")
    }

    /// A camera track goes through its keys, looking at their targets, and holds its first and last poses.
    func testCameraTrack() {
        let track = CameraTrack([CameraTrack.Key(time: 0, position: [0, 1, 5], target: [0, 1, 0]),
                                 CameraTrack.Key(time: 2, position: [4, 2, 4], target: [4, 2, 0]),
                                 CameraTrack.Key(time: 5, position: [5, 1, 0], target: [10, 1, 0])])
        XCTAssertEqual(track.duration, 5)
        for (t, position) in [(Float(-1), SIMD3<Float>(0, 1, 5)), (0, [0, 1, 5]), (2, [4, 2, 4]), (5, [5, 1, 0]), (9, [5, 1, 0])] {
            XCTAssertLessThan(simd_distance(track.camera(at: t).position, position), 1e-5, "t = \(t)")
        }
        let start = track.camera(at: 0), end = track.camera(at: 5)
        XCTAssertEqual(start.yaw, 0, accuracy: 1e-5, "looking down -z")
        XCTAssertEqual(start.pitch, 0, accuracy: 1e-5)
        XCTAssertEqual(end.yaw, .pi / 2, accuracy: 1e-5, "looking down +x")
        XCTAssertLessThan(simd_distance(track.camera(at: 2).forward, [0, 0, -1]), 1e-5)
        // Smooth: no jump anywhere along it.
        var last = track.camera(at: 0).position
        for i in 1...500 {
            let p = track.camera(at: Float(i) * 0.01).position
            XCTAssertLessThan(simd_distance(p, last), 0.1)
            last = p
        }
    }

    func testTrackedRecording() {
        let track = CameraTrack([CameraTrack.Key(time: 0, position: [0, 1, 5], target: .zero),
                                 CameraTrack.Key(time: 2.5, position: [1, 1, 5], target: .zero)])
        let c = Benchmark.Config("r").track(track).recording()
        XCTAssertTrue(c.record)
        XCTAssertEqual(c.frames, 151, "every 1/60 s of the track, both ends")
        let demo = Benchmark.configs(for: "shapesdemo")
        XCTAssertEqual(demo.count, 1)
        XCTAssertTrue(demo[0].record)
        XCTAssertFalse(demo[0].settings.paused)
        XCTAssertEqual(demo[0].settings.scene.kind, .shapes)
        XCTAssertNotNil(demo[0].track)
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
