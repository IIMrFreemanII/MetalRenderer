import XCTest
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// What a GPU can't run (Capabilities.swift): the settings fall back, and the benchmark skips the settings that need it.
/// Metal ray tracing has no stand-in: without it nothing runs.
final class CapabilitiesTests: XCTestCase {
    private var none: Capabilities {
        var c = Capabilities()
        c.metalRayTracing = false; c.hardwareRayTracing = false
        c.metalFXDenoiser = false; c.frameInterpolator = false; c.metal4 = false; c.metal4RayTracing = false
        return c
    }

    private func settings(_ change: (inout RenderSettings) -> Void) -> RenderSettings {
        var s = RenderSettings()
        s.api = .metal3
        change(&s)
        return s
    }

    func testSupportedSettingsStayAsTheyAre() {
        let s = settings { $0.upscaleFactor = 3; $0.api = .metal4 }
        XCTAssertNil(s.missing(in: Capabilities()))
        let (clamped, notes) = s.clamped(to: Capabilities())
        XCTAssertEqual(clamped, s)
        XCTAssertTrue(notes.isEmpty)
        var rt = none
        rt.metalRayTracing = true
        XCTAssertNil(settings { $0.upscaleFactor = 0 }.missing(in: rt), "the defaults without upscaling run wherever Metal ray tracing does")
        XCTAssertEqual(settings { $0.upscaleFactor = 0 }.missing(in: none), "Metal ray tracing")
    }

    func testEachMissingCapabilityFallsBack() {
        var caps = Capabilities()
        caps.metalFXDenoiser = false
        var (c, notes) = settings { $0.upscaleFactor = 3; $0.api = .metal4 }.clamped(to: caps)
        XCTAssertEqual(c.upscaleFactor, 0, "no upscaling: SVGF denoises")
        XCTAssertEqual(c.api, .metal4, "only what is missing changes")
        XCTAssertEqual(notes.count, 1)

        caps = Capabilities()
        caps.metal4 = false
        (c, notes) = settings { $0.api = .metal4 }.clamped(to: caps)
        XCTAssertEqual(c.api, .metal3)
        XCTAssertEqual(notes.count, 1)
    }

    func testMetalRayTracingOnMetal4NeedsItsOwnSupport() {
        var caps = Capabilities()
        caps.metal4RayTracing = false   // M1 Max: Metal 4 and Metal ray tracing, but not together
        let s = settings { $0.api = .metal4 }
        XCTAssertEqual(s.missing(in: caps), "Metal 4 ray tracing")
        let (c, notes) = s.clamped(to: caps)
        XCTAssertEqual(c.api, .metal3)
        XCTAssertEqual(notes.count, 1)
    }

    func testTheDenoiserIsOnlyNeededWhileUpscaling() {
        var caps = Capabilities()
        caps.metalFXDenoiser = false
        XCTAssertNotNil(settings { $0.upscaleFactor = 3 }.missing(in: caps))
        XCTAssertNil(settings { $0.upscaleFactor = 0 }.missing(in: caps))
        XCTAssertTrue(settings { $0.upscaleFactor = 3 }.neuralDenoiser)
        XCTAssertFalse(settings { $0.upscaleFactor = 0 }.neuralDenoiser)
    }

    func testTheBenchmarkSkipsWhatTheGPUCantRun() {
        let list = [Benchmark.Config("plain", scale: 0.5) { $0.api = .metal3 },
                    Benchmark.Config("metal4", scale: 0.5) { $0.api = .metal4 },
                    Benchmark.Config("neural", scale: 0.5, upscale: 3) { $0.api = .metal3 }]
        let all = Benchmark.supported(list, on: Capabilities())
        XCTAssertEqual(all.run.map(\.name), ["plain", "metal4", "neural"])
        XCTAssertTrue(all.skipped.isEmpty)
        var rt = none
        rt.metalRayTracing = true
        let few = Benchmark.supported(list, on: rt)
        XCTAssertEqual(few.run.map(\.name), ["plain"])
        XCTAssertEqual(few.skipped.count, 2)
        XCTAssertTrue(few.skipped[1].contains("MetalFX denoiser"))
    }

    func testFrameInterpolationFallsBackQuietlyUnlessAskedFor() {
        var caps = Capabilities()
        caps.frameInterpolator = false
        XCTAssertNil(settings { $0.upscaleFactor = 3; $0.frameInterpolation = .auto }.missing(in: caps), "Auto needs nothing")
        XCTAssertNotNil(settings { $0.upscaleFactor = 3; $0.frameInterpolation = .on }.missing(in: caps))
        XCTAssertNil(settings { $0.upscaleFactor = 0; $0.frameInterpolation = .on }.missing(in: caps), "only with MetalFX's upscaling")
        var (c, notes) = settings { $0.upscaleFactor = 3; $0.frameInterpolation = .auto }.clamped(to: caps)
        XCTAssertEqual(c.frameInterpolation, .off)
        XCTAssertTrue(notes.isEmpty)
        (c, notes) = settings { $0.upscaleFactor = 3; $0.frameInterpolation = .on }.clamped(to: caps)
        XCTAssertEqual(c.frameInterpolation, .off)
        XCTAssertEqual(notes.count, 1)
    }

    func testAutoInterpolatesOnlyWhereItCostsNoFrames() {
        let refresh = 1000.0 / 120
        XCTAssertFalse(FrameInterpolation.autoOn(frameMs: 20, refreshMs: refresh, was: false), "over 40 fps: two pictures would cost frames")
        XCTAssertTrue(FrameInterpolation.autoOn(frameMs: 30, refreshMs: refresh, was: false))
        XCTAssertTrue(FrameInterpolation.autoOn(frameMs: 24, refreshMs: refresh, was: true), "stays on a little below where it came on")
        XCTAssertFalse(FrameInterpolation.autoOn(frameMs: 20, refreshMs: refresh, was: true))
    }

    func testEachPictureIsHeldWholeRefreshes() {
        let refresh = 1000.0 / 120
        // A 30 ms frame: two pictures of two refreshes each (a little under, for a late refresh).
        XCTAssertEqual(FrameInterpolation.hold(frameMs: 30, refreshMs: refresh), (2 * refresh - 2) / 1000, accuracy: 1e-9)
        XCTAssertEqual(FrameInterpolation.hold(frameMs: 5, refreshMs: refresh), (refresh - 2) / 1000, accuracy: 1e-9, "at least one")
        XCTAssertEqual(FrameInterpolation.hold(frameMs: 40, refreshMs: refresh), (3 * refresh - 2) / 1000, accuracy: 1e-9)
        XCTAssertEqual(FrameInterpolation.hold(frameMs: 30, refreshMs: nil), 0.015, accuracy: 1e-9, "no display: half a frame")
    }

    func testAPINamesReadBack() {
        XCTAssertEqual(RenderAPI(envText: "metal4"), .metal4)
    }
}
