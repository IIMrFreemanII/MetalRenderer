import XCTest
@testable import MetalRenderer

/// What a GPU can't run (Capabilities.swift): the settings fall back, and the benchmark skips the settings that need it.
final class CapabilitiesTests: XCTestCase {
    private var none: Capabilities {
        var c = Capabilities()
        c.metalRayTracing = false; c.hardwareRayTracing = false
        c.metalFXDenoiser = false; c.metal4 = false; c.metal4RayTracing = false
        return c
    }

    private func settings(_ change: (inout RenderSettings) -> Void) -> RenderSettings {
        var s = RenderSettings()
        s.rayTracer = .custom
        s.api = .metal3
        change(&s)
        return s
    }

    func testSupportedSettingsStayAsTheyAre() {
        let s = settings { $0.rayTracer = .metal; $0.upscaleFactor = 3; $0.api = .metal4 }
        XCTAssertNil(s.missing(in: Capabilities()))
        let (clamped, notes) = s.clamped(to: Capabilities())
        XCTAssertEqual(clamped, s)
        XCTAssertTrue(notes.isEmpty)
        XCTAssertNil(settings { $0.upscaleFactor = 0 }.missing(in: none), "the defaults without upscaling run everywhere")
    }

    func testEachMissingCapabilityFallsBack() {
        var caps = Capabilities()
        caps.metalRayTracing = false
        var (c, notes) = settings { $0.rayTracer = .metal }.clamped(to: caps)
        XCTAssertEqual(c.rayTracer, .custom)
        XCTAssertEqual(notes.count, 1)

        caps = Capabilities()
        caps.metalFXDenoiser = false
        (c, notes) = settings { $0.upscaleFactor = 3; $0.rayTracer = .metal }.clamped(to: caps)
        XCTAssertEqual(c.upscaleFactor, 0, "no upscaling: SVGF denoises")
        XCTAssertEqual(c.rayTracer, .metal, "only what is missing changes")
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
        let s = settings { $0.rayTracer = .metal; $0.api = .metal4 }
        XCTAssertEqual(s.missing(in: caps), "Metal 4 ray tracing")
        let (c, notes) = s.clamped(to: caps)
        XCTAssertEqual(c.api, .metal3)
        XCTAssertEqual(c.rayTracer, .metal, "the ray tracer stays")
        XCTAssertEqual(notes.count, 1)
        XCTAssertNil(settings { $0.rayTracer = .custom; $0.api = .metal4 }.missing(in: caps), "the custom BVH runs on Metal 4")
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
        let list = [Benchmark.Config("plain", scale: 0.5) { $0.rayTracer = .custom; $0.api = .metal3 },
                    Benchmark.Config("hardware", scale: 0.5) { $0.rayTracer = .metal; $0.api = .metal3 },
                    Benchmark.Config("neural", scale: 0.5, upscale: 3) { $0.rayTracer = .custom; $0.api = .metal3 }]
        let all = Benchmark.supported(list, on: Capabilities())
        XCTAssertEqual(all.run.map(\.name), ["plain", "hardware", "neural"])
        XCTAssertTrue(all.skipped.isEmpty)
        let few = Benchmark.supported(list, on: none)
        XCTAssertEqual(few.run.map(\.name), ["plain"])
        XCTAssertEqual(few.skipped.count, 2)
        XCTAssertTrue(few.skipped[1].contains("MetalFX denoiser"))
    }

    func testAPINamesReadBack() {
        XCTAssertEqual(RenderAPI(envText: "metal4"), .metal4)
    }
}
