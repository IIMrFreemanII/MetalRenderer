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

/// The film look (ToneMap.film) against Unreal 5.8's own output, captured from an emissive plane with its default
/// post process, exposure fixed at 1, no bloom and no vignette: the real shader's function, in sRGB levels of 255.
final class FilmLookTests: XCTestCase {
    private static let grey: [(Float, Float)] = [
        (0.022097, 0.00652), (0.044194, 0.02069), (0.088388, 0.06464), (0.17678, 0.17896), (0.35355, 0.39648),
        (0.70711, 0.62891), (1.4142, 0.80029), (2.8284, 0.90869), (5.6569, 0.96973),
    ]
    private static let colours: [(SIMD3<Float>, SIMD3<Float>)] = [
        ([0.5, 0, 0], [0.44995, 0.00016, 0.00090]), ([2, 0, 0], [1.00000, 0.04120, 0.00627]), ([8, 0, 0], [1.00000, 0.30469, 0.01897]),
        ([0, 0.5, 0], [0.00016, 0.54688, 0.00016]), ([0, 2, 0], [0.16187, 0.97754, 0.03900]), ([0, 8, 0], [0.71387, 1.00000, 0.46509]),
        ([0, 0, 0.5], [0.00016, 0.00016, 0.49683]), ([0, 0, 2], [0.06635, 0.14014, 0.89111]), ([0, 0, 8], [0.37988, 0.65576, 1.00000]),
        ([0.5, 0.175, 0.025], [0.52832, 0.18408, 0.01507]), ([2, 0.7, 0.1], [0.96338, 0.66260, 0.12915]), ([8, 2.8, 0.4], [1.00000, 0.93652, 0.58447]),
        ([0.15, 0.25, 0.5], [0.15405, 0.28394, 0.51123]), ([0.6, 1, 2], [0.57031, 0.74219, 0.87451]), ([2.4, 4, 8], [0.88721, 0.95117, 0.99316]),
        ([0.4, 0.25, 0.175], [0.42700, 0.28149, 0.19019]), ([1.6, 1, 0.7], [0.83252, 0.72803, 0.64600]), ([6.4, 4, 2.8], [0.98193, 0.94580, 0.91553]),
        ([0.075, 0.175, 0.025], [0.04926, 0.16992, 0.01091]), ([0.3, 0.7, 0.1], [0.35278, 0.66064, 0.12280]), ([1.2, 2.8, 0.4], [0.77148, 0.94189, 0.55518]),
        ([0.4, 0.1, 0.1], [0.39331, 0.08813, 0.08545]), ([1.6, 0.4, 0.4], [0.90967, 0.46997, 0.46924]), ([6.4, 1.6, 1.6], [0.99902, 0.83496, 0.83887]),
    ]

    /// `Output.metal`'s film functions on `inputs`, at Unreal's default parameters.
    private func film(_ inputs: [SIMD3<Float>]) throws -> [SIMD3<Float>] {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let url = SourceTree.packageRoot.appendingPathComponent("Sources/MetalRenderer/Shaders/Output.metal")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "// The film look (ToneMap.film)")), end = try XCTUnwrap(text.range(of: "/// Whether view mode"))
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        \(text[start.lowerBound..<end.lowerBound])
        kernel void run(device float4* io [[buffer(0)]], uint i [[thread_position_in_grid]]) {
            io[i] = float4(saturate(filmFilm(io[i].rgb, float4(0.88f, 0.55f, 0.26f, 0.0f), 0.04f)), 1.0f);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "run")))
        var data = inputs.map { SIMD4<Float>($0, 1) }
        let buffer = try XCTUnwrap(device.makeBuffer(bytes: &data, length: data.count * 16, options: .storageModeShared))
        let commands = try XCTUnwrap(queue.makeCommandBuffer()), encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: data.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return (0..<data.count).map { i in
            let v = buffer.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
            return SIMD3(v.x, v.y, v.z)
        }
    }

    private func level(_ linear: Float) -> Float {
        255 * (linear <= 0.0031308 ? 12.92 * max(linear, 0) : 1.055 * pow(linear, 1 / 2.4) - 0.055)
    }

    func testGreysMatchUnreal() throws {
        let out = try film(Self.grey.map { SIMD3(repeating: $0.0) })
        for (i, reference) in Self.grey.enumerated() {
            XCTAssertEqual(level(out[i].y), level(reference.1), accuracy: 2, "grey \(reference.0)")
        }
    }

    func testColoursMatchUnreal() throws {
        let out = try film(Self.colours.map(\.0))
        var worst: Float = 0
        for (i, reference) in Self.colours.enumerated() {
            for c in 0..<3 { worst = max(worst, abs(level(out[i][c]) - level(reference.1[c]))) }
        }
        XCTAssertLessThan(worst, 8, "the worst channel's difference in sRGB levels")
    }

    /// The film look's meter: a uniform frame settles at Unreal's 0.36, at once on the first measure, then by its speeds.
    func testExposureSettlesLikeUnreal() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let m = AutoExposure(device: device, framesInFlight: 2)
        for _ in 0..<4 { _ = m.next() }
        func meter(at l: Float, dt: Float = 1.0 / 60) -> Float {
            let bin = Int((l - AutoExposure.logMin) / (AutoExposure.logMax - AutoExposure.logMin) * Float(AutoExposure.bins))
            let h = m.peekNext().contents().bindMemory(to: UInt32.self, capacity: AutoExposure.bins)
            h[bin] = 1000
            return m.next(dt: dt)
        }
        let step = (AutoExposure.logMax - AutoExposure.logMin) / Float(AutoExposure.bins)
        func centre(_ l: Float) -> Float { AutoExposure.logMin + (floor((l - AutoExposure.logMin) / step) + 0.5) * step }
        let first = meter(at: -2)
        XCTAssertEqual(log2(first), log2(AutoExposure.filmKey) - centre(-2), accuracy: 1e-3)
        // Far from the target it moves at a constant speed: 3 stops a second closing down, 1 opening up.
        let down = log2(meter(at: 4, dt: 0.1)) - log2(first)
        XCTAssertEqual(down, -AutoExposure.filmClose * 0.1, accuracy: 1e-3)
        let before = log2(meter(at: -8, dt: 0))
        XCTAssertEqual(log2(meter(at: -8, dt: 0.1)) - before, AutoExposure.filmOpen * 0.1, accuracy: 1e-3)
    }

    /// New defaults reach a saved copy once: its look goes and the app opens where a first launch does; its other
    /// settings stay, and a copy saved since keeps its choices.
    func testAnOldSavedLookIsResetOnce() throws {
        let defaults = RenderSettings()
        var old = defaults
        old.scene.kind = .forest
        old.toneMap = .agx
        old.exposure = 2
        old.moveSpeed = 7
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["lookVersion"] = nil
        let migrated = try XCTUnwrap(SettingsStore.decode(saved: JSONSerialization.data(withJSONObject: json), over: defaults))
        XCTAssertEqual(migrated.toneMap, .film)
        XCTAssertEqual(migrated.exposure, 0)
        XCTAssertEqual(migrated.scene.kind, RenderSettings.firstLaunch(defaults).scene.kind)
        XCTAssertEqual(migrated.post, PostSettings.preset(for: migrated.scene))
        XCTAssertEqual(migrated.moveSpeed, 7, "not part of the look")
        let again = try XCTUnwrap(SettingsStore.decode(saved: JSONEncoder().encode(old), over: defaults))
        XCTAssertEqual(again.toneMap, .agx, "saved under the current look: left alone")
        XCTAssertEqual(again.scene.kind, .forest)
    }

    /// The benchmarks keep the look of their scores' history unless they ask for the app's.
    func testBenchmarksKeepTheClassicLook() {
        let config = Benchmark.Config("t", scene: SceneSettings(kind: .forest))
        XCTAssertEqual(config.settings.toneMap, .aces)
        XCTAssertTrue(config.settings.post.classic)
        XCTAssertEqual(config.settings.post.bloom, 0.035)
        let app = config.appLook()
        XCTAssertEqual(app.settings.toneMap, .film)
        XCTAssertEqual(app.settings.post, .unreal)
    }
}
