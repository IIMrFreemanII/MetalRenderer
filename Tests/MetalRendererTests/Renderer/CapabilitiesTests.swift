import XCTest
import Metal
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

/// What a GPU can't run (Capabilities.swift): the settings fall back, and the benchmark skips the settings that need it.
/// Metal ray tracing and Metal 4's have no stand-in: without them nothing runs (the renderer refuses the GPU).
final class CapabilitiesTests: XCTestCase {
    private var none: Capabilities {
        var c = Capabilities()
        c.metalRayTracing = false; c.hardwareRayTracing = false
        c.metalFXDenoiser = false; c.frameInterpolator = false; c.metal4 = false; c.metal4RayTracing = false
        return c
    }

    private func settings(_ change: (inout RenderSettings) -> Void) -> RenderSettings {
        var s = RenderSettings()
        change(&s)
        return s
    }

    func testSupportedSettingsStayAsTheyAre() {
        let s = settings { $0.upscaleFactor = 3 }
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
        let (c, notes) = settings { $0.upscaleFactor = 3; $0.frameInterpolation = .on }.clamped(to: caps)
        XCTAssertEqual(c.upscaleFactor, 0, "no upscaling: SVGF denoises")
        XCTAssertEqual(c.frameInterpolation, .on, "only what is missing changes")
        XCTAssertEqual(notes.count, 1)
    }

    /// The M1 Max's case: Metal 4 and Metal ray tracing, but not together. Every frame goes through Metal 4, so the
    /// renderer refuses it; a setting has nothing to fall back to.
    func testWithoutMetal4RayTracingTheRendererRefusesTheGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let saved = Capabilities.current
        defer { Capabilities.current = saved }
        Capabilities.current.metal4RayTracing = false
        XCTAssertThrowsError(try Renderer(device: device, surface: OffscreenSurface(device: device), benchmarked: false)) {
            XCTAssertTrue("\($0)".contains("Metal 4 ray tracing"))
        }
        XCTAssertNil(settings { $0.upscaleFactor = 3 }.clamped(to: Capabilities.current).notes.first, "no setting stands in for it")
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
        let list = [Benchmark.Config("plain", scale: 0.5), Benchmark.Config("neural", scale: 0.5, upscale: 3)]
        let all = Benchmark.supported(list, on: Capabilities())
        XCTAssertEqual(all.run.map(\.name), ["plain", "neural"])
        XCTAssertTrue(all.skipped.isEmpty)
        var rt = none
        rt.metalRayTracing = true
        let few = Benchmark.supported(list, on: rt)
        XCTAssertEqual(few.run.map(\.name), ["plain"])
        XCTAssertEqual(few.skipped.count, 1)
        XCTAssertTrue(few.skipped[0].contains("MetalFX denoiser"))
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
}
