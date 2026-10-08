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
        setenv("METALRENDERER_DATASET", "scenes=cornell,clips=1,frames=2,spp=8,pausedclips=0", 1)
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

    /// denoisedemo records each scene's camera move three times, alike but for what upscales and denoises: the net's
    /// input (no upscaler, no denoiser), MetalFX's and ours.
    func testDenoiseDemoSettingsDifferOnlyInTheUpscaler() {
        let configs = Benchmark.modes["denoisedemo"]!()
        XCTAssertEqual(configs.count % 3, 0)
        XCTAssertTrue(configs.allSatisfy(\.record))
        for i in stride(from: 0, to: configs.count, by: 3) {
            let (noisy, metalfx, neural) = (configs[i], configs[i + 1], configs[i + 2])
            let tag = String(noisy.name.dropLast(" noisy".count))
            XCTAssertEqual([noisy.name, metalfx.name, neural.name], ["\(tag) noisy", "\(tag) metalfx", "\(tag) neural"])
            for c in [metalfx, neural] {
                XCTAssertEqual(c.frames, noisy.frames, tag)
                XCTAssertEqual(c.startTime, noisy.startTime, tag)
                XCTAssertEqual(c.cameraPath, noisy.cameraPath, tag)
                XCTAssertEqual(c.cameraPan, noisy.cameraPan, tag)
                XCTAssertEqual(c.track?.camera(at: 1).position, noisy.track?.camera(at: 1).position, tag)
                XCTAssertEqual(c.settings.scene, noisy.settings.scene, tag)
                XCTAssertEqual(c.settings.giMode, noisy.settings.giMode, tag)
            }
            XCTAssertTrue(noisy.settings.upscaleFactor == 0 && !noisy.settings.denoiser.enabled, tag)
            XCTAssertEqual(metalfx.settings.upscaler, RenderSettings().upscaler, tag)
            XCTAssertEqual(neural.settings.upscaler, .neural, tag)
            XCTAssertTrue(metalfx.settings.upscaleFactor == 3 && neural.settings.upscaleFactor == 3, tag)
        }
    }

    /// cameraMove(pan:) turns the path's view from right to left: none halfway, the path's own pose without a pan.
    func testCameraPanTurnsAcrossThePath() {
        let still = Benchmark.Config("").cameraMove(), panned = Benchmark.Config("").cameraMove(pan: 0.5)
        let camera = Camera()
        for p: Float in [0, 0.5, 1] {
            XCTAssertEqual(panned.pathPose(progress: p, scene: .cornell, sceneCamera: camera).yaw,
                           still.pathPose(progress: p, scene: .cornell, sceneCamera: camera).yaw + 0.5 * (1 - 2 * p), accuracy: 1e-6)
        }
        XCTAssertEqual(still.pathPose(progress: 0.3, scene: .cornell, sceneCamera: camera).yaw,
                       Benchmark.cameraPose(progress: 0.3, scene: .cornell, sceneCamera: camera).yaw)
    }

    /// neuralq scores both upscalers against references traced as deep as the neural dataset's, not the app's 2 bounces.
    func testNeuralQualityReferencesTraceTheDatasetsBounces() {
        let configs = Benchmark.modes["neuralq"]!()
        let refs = configs.filter(\.accumulate)
        XCTAssertEqual(refs.map(\.name), ["cornell ref neural", "stress ref neural"])
        XCTAssertTrue(refs.allSatisfy { $0.settings.bounces == Benchmark.DatasetSpec().bounces && $0.supersample })
        XCTAssertNotEqual(Benchmark.DatasetSpec().bounces, RenderSettings().bounces, "the point of having its own references")
        let shown = configs.filter { !$0.accumulate }
        XCTAssertEqual(shown.filter { $0.settings.upscaler == .neural }.count, 6)
        XCTAssertTrue(shown.allSatisfy { $0.settings.bounces == RenderSettings().bounces })
        XCTAssertTrue(shown.allSatisfy { $0.settings.giMode == RenderSettings().giMode }, "the app's GI, as the dataset's frames")
    }

    /// Paused clips: a still camera on a paused scene, as long as `pausedframes=`, at a moment of their own, after the
    /// scene's moving clips (which they leave as they were); the reference pass renders only their first frame's.
    func testDatasetPausedClips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dataset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("METALRENDERER_DATASET_DIR"); unsetenv("METALRENDERER_DATASET") }
        setenv("METALRENDERER_DATASET_DIR", dir.path, 1)
        setenv("METALRENDERER_DATASET", "scenes=cornell|stress,clips=2,frames=20,pausedframes=50,pausedclips=1", 1)
        let clips = Benchmark.DatasetSpec().clipList
        XCTAssertEqual(clips.map(\.name), ["cornell-1-0", "cornell-1-1", "cornell-1-p0", "stress-1-0", "stress-1-1", "stress-1-p0"])
        let paused = clips.filter(\.paused)
        XCTAssertTrue(paused.allSatisfy { $0.drift == nil && $0.frames == 50 })
        XCTAssertTrue(clips.filter { !$0.paused }.allSatisfy { $0.drift != nil && $0.frames == 20 })
        XCTAssertNotEqual(paused[0].startTime, clips[0].startTime, "a moment of its own")
        setenv("METALRENDERER_DATASET", "scenes=cornell|stress,clips=2,frames=20,pausedclips=0", 1)
        XCTAssertEqual(Benchmark.DatasetSpec().clipList.map(\.startTime), clips.filter { !$0.paused }.map(\.startTime),
                       "the moving clips are as they were without paused ones")

        setenv("METALRENDERER_DATASET", "scenes=stress,clips=0,pausedclips=3", 1)
        let stress = Benchmark.DatasetSpec().clipList
        XCTAssertEqual(stress.map(\.name), ["stress-1-p0", "stress-1-p1", "stress-1-p2"])
        XCTAssertEqual(stress[0].camera?.position, Benchmark.DatasetSpec.stressViews[1].position, "p0 as it was")
        XCTAssertNil(stress[2].camera, "the building's own camera over the aisle")

        setenv("METALRENDERER_DATASET", "scenes=cornell,clips=0,pausedframes=3,pausedclips=1,spp=8", 1)
        let noisy = Benchmark.dataset()
        XCTAssertEqual(noisy.map(\.name), ["cornell-1-p0"])
        XCTAssertTrue(noisy[0].settings.paused && noisy[0].drift == nil && noisy[0].frames == 3)
        let clip = dir.appendingPathComponent("cornell-1-p0")
        try FileManager.default.createDirectory(at: clip, withIntermediateDirectories: true)
        for f in 0..<3 {
            let row = Benchmark.DatasetFrame(frame: f, time: 7, camera: [1, 2, 3, 0.5, -0.1, 1], jitter: [0, 0],
                                             prevJitter: [0, 0], exposure: 1, size: [640, 400], outSize: [1920, 1200])
            try JSONEncoder().encode(row).write(to: clip.appendingPathComponent(Benchmark.datasetFileName(frame: f, buffer: nil)))
        }
        XCTAssertEqual(Benchmark.datasetReferences().map(\.name), ["cornell-1-p0 f0"], "one reference for the clip")
    }

    /// The showcase gives the dataset a clip per model, each on its own set; the model scenes' clips trace full-detail
    /// meshes and have no lens, in both runs.
    func testDatasetShowcaseClips() {
        defer { unsetenv("METALRENDERER_DATASET"); unsetenv("METALRENDERER_GALLERY"); unsetenv("METALRENDERER_DATASET_DIR") }
        setenv("METALRENDERER_DATASET_DIR", emptyDatasetDirectory(), 1)   // not ./dataset, whose saved clips dataset() skips
        setenv("METALRENDERER_DATASET", "scenes=showcase|randomroom|cornell,clips=1,rooms=1,frames=1,pausedclips=0", 1)
        setenv("METALRENDERER_GALLERY", "owl|demon", 1)
        let clips = Benchmark.DatasetSpec().clipList
        let showcase = clips.filter { $0.scene.kind == .showcase }
        XCTAssertEqual(showcase.map(\.scene.showcase), Scene.galleryFiles().map(Scene.showcaseName))
        XCTAssertEqual(showcase.count, 2)
        for clip in clips {
            var s = RenderSettings()
            s.post.bloom = 0.5
            clip.shared(&s)
            XCTAssertFalse(s.post.isOn, clip.name)
            XCTAssertEqual(s.virtualGeometry.enabled, clip.scene.kind == .cornell ? RenderSettings().virtualGeometry.enabled : false, clip.name)
        }
        let noisy = Benchmark.dataset().filter { $0.settings.scene.kind == .showcase }
        XCTAssertEqual(noisy.map(\.settings.scene.showcase), showcase.map(\.scene.showcase))
        XCTAssertTrue(noisy.allSatisfy { !$0.settings.post.isOn && !$0.settings.virtualGeometry.enabled })
        XCTAssertTrue(showcase.allSatisfy { $0.frames == 1 }, "the showcase's clips are as long as the others")
        XCTAssertEqual(clips.first { $0.scene.kind == .cornell }?.frames, 1)
        setenv("METALRENDERER_DATASET", "scenes=showcase|cornell,clips=1,frames=20,showcaseframes=8,pausedclips=0", 1)
        let short = Benchmark.DatasetSpec().clipList
        XCTAssertTrue(short.filter { $0.scene.kind == .showcase }.allSatisfy { $0.frames == 8 }, "showcaseframes= cuts them")
        XCTAssertEqual(short.first { $0.scene.kind == .cornell }?.frames, 20)
    }

    /// A dataset folder that doesn't exist (so holds no saved clips).
    private func emptyDatasetDirectory() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("dataset-\(UUID().uuidString)").path
    }

    /// The stress building's clips start in its four zones, one each, and are as long as the others unless
    /// `stressframes=` cuts them.
    func testDatasetStressClips() {
        defer { unsetenv("METALRENDERER_DATASET"); unsetenv("METALRENDERER_DATASET_DIR") }
        setenv("METALRENDERER_DATASET_DIR", emptyDatasetDirectory(), 1)
        setenv("METALRENDERER_DATASET", "scenes=stress|cornell,clips=4,frames=20,pausedclips=0", 1)
        let clips = Benchmark.DatasetSpec().clipList
        let stress = clips.filter { $0.scene.kind == .stress }
        XCTAssertEqual(stress.count, 4)
        XCTAssertEqual(Set(stress.compactMap { $0.camera.map { "\($0.position)" } }).count, 4, "one zone each")
        for clip in stress {
            let p = clip.camera!.position, f = clip.camera!.forward
            XCTAssertGreaterThan(min(abs(p.x), abs(p.z)), 2, "inside a zone, past its partitions")
            XCTAssertGreaterThan(p.x * f.x, 0, "looking further into the zone")
            XCTAssertGreaterThan(p.z * f.z, 0)
            XCTAssertEqual(clip.frames, 20)
        }
        XCTAssertTrue(clips.filter { $0.scene.kind == .cornell }.allSatisfy { $0.camera == nil && $0.frames == 20 })
        setenv("METALRENDERER_DATASET", "scenes=stress|cornell,clips=4,frames=20,stressframes=8,pausedclips=0", 1)
        let short = Benchmark.DatasetSpec().clipList
        XCTAssertTrue(short.filter { $0.scene.kind == .stress }.allSatisfy { $0.frames == 8 })
        XCTAssertTrue(short.filter { $0.scene.kind == .cornell }.allSatisfy { $0.frames == 20 })
        setenv("METALRENDERER_DATASET", "scenes=stress|cornell,clips=4,frames=20,pausedclips=0", 1)
        let noisy = Benchmark.dataset().filter { $0.settings.scene.kind == .stress }
        XCTAssertEqual(noisy.compactMap { $0.camera?.position }, stress.map { $0.camera!.position })
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
