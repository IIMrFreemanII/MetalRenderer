import XCTest
import Metal
import simd
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

    /// The old default resolution moves to the new one with the look; one the user chose stays. A scene's solid look
    /// ends with the scene.
    func testAnOldSavedResolutionAndSolidLook() throws {
        let defaults = RenderSettings()
        var old = defaults
        old.renderScale = 0.5
        old.upscaleFactor = 3
        old.solid = true
        old.solidFromScene = true
        func migrated(_ s: RenderSettings) throws -> RenderSettings {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
            json["lookVersion"] = nil
            return try XCTUnwrap(SettingsStore.decode(saved: JSONSerialization.data(withJSONObject: json), over: defaults))
        }
        let moved = try migrated(old)
        XCTAssertEqual(moved.renderScale, defaults.renderScale)
        XCTAssertEqual(moved.upscaleFactor, defaults.upscaleFactor)
        XCTAssertFalse(moved.solid)
        old.renderScale = 1
        old.solidFromScene = false
        let chosen = try migrated(old)
        XCTAssertEqual(chosen.renderScale, 1)
        XCTAssertEqual(chosen.upscaleFactor, 3)
        XCTAssertTrue(chosen.solid, "turned on by the user: theirs")
    }

    /// `Surface.metal`'s lobe table against the lobe itself, and a white metal keeps its energy at any roughness and
    /// angle: the real shader's functions.
    func testSpecularKeepsItsEnergy() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no GPU") }
        let url = SourceTree.packageRoot.appendingPathComponent("Sources/MetalRenderer/Shaders/Surface.metal")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "// Hemispherical-directional specular albedo")), end = try XCTUnwrap(text.range(of: "// Albedo a secondary hit"))
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        \(text[start.lowerBound..<end.lowerBound])
        kernel void run(device float4* io [[buffer(0)]], uint i [[thread_position_in_grid]]) {
            float roughness = io[i].x, NoV = io[i].y;
            float3 e = specularShare(float3(1.0f), 1.0f, roughness, NoV, true);
            io[i] = float4(e.x, e.x * specularMultiscatter(float3(1.0f), roughness, NoV).x, specularF90(float3(0.01f)), specularF90(float3(0.04f)));
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "run")))
        let roughness: [Float] = [0.03, 0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1]
        let angles: [Float] = [0.05, 0.1, 0.25, 0.5, 0.75, 1]
        var data = roughness.flatMap { r in angles.map { SIMD4<Float>(r, $0, 0, 0) } }
        let buffer = try XCTUnwrap(device.makeBuffer(bytes: &data, length: data.count * 16, options: .storageModeShared))
        let commands = try XCTUnwrap(queue.makeCommandBuffer()), encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: data.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        for (i, input) in data.enumerated() {
            let out = buffer.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
            let lobe = Self.lobeAlbedo(roughness: input.x, NoV: input.y)
            XCTAssertEqual(out.x / lobe, 1, accuracy: 0.03, "roughness \(input.x), NoV \(input.y)")
            XCTAssertEqual(out.y, 1, accuracy: 0.001)
            XCTAssertEqual(out.z, 0.5, accuracy: 0.001)
            XCTAssertEqual(out.w, 1)
        }
    }

    /// A GGX lobe's albedo at F = 1 (visible normals: the mean of G2 / G1), by stratified samples.
    private static func lobeAlbedo(roughness: Float, NoV: Float) -> Float {
        let a = roughness * roughness, a2 = a * a, n = 128
        let v = SIMD3<Float>((1 - NoV * NoV).squareRoot(), 0, NoV)
        let g1 = 2 * NoV / (NoV + (a2 + (1 - a2) * NoV * NoV).squareRoot())
        let vh = simd_normalize(SIMD3<Float>(a * v.x, a * v.y, v.z))
        let lensq = vh.x * vh.x + vh.y * vh.y
        let t1 = lensq > 0 ? SIMD3<Float>(-vh.y, vh.x, 0) / lensq.squareRoot() : SIMD3<Float>(1, 0, 0)
        let t2 = simd_cross(vh, t1)
        var sum: Float = 0
        for i in 0..<n {
            for j in 0..<n {
                let u1 = (Float(i) + 0.5) / Float(n), u2 = (Float(j) + 0.5) / Float(n)
                let r = u1.squareRoot(), phi = 2 * Float.pi * u2
                let s = 0.5 * (1 + vh.z)
                let p1 = r * cos(phi), p2 = (1 - s) * max(0, 1 - p1 * p1).squareRoot() + s * r * sin(phi)
                let nh = p1 * t1 + p2 * t2 + max(0, 1 - p1 * p1 - p2 * p2).squareRoot() * vh
                let h = simd_normalize(SIMD3<Float>(a * nh.x, a * nh.y, max(0, nh.z)))
                let l = 2 * simd_dot(v, h) * h - v
                guard l.z > 0 else { continue }
                let gv = l.z * (NoV * NoV * (1 - a2) + a2).squareRoot(), gl = NoV * (l.z * l.z * (1 - a2) + a2).squareRoot()
                sum += (2 * l.z * NoV / max(gv + gl, 1e-7)) / g1
            }
        }
        return sum / Float(n * n)
    }

    /// Only a scene with a sheen or anisotropy compiles the lobes in, and a material graph's file from before them reads.
    func testMaterialLobes() throws {
        let scene = Scene()
        XCTAssertEqual(scene.lightTypeMask & 0x0020_0000, 0)
        _ = scene.addPBRMaterial(baseColor: [1, 1, 1], metallic: 0, roughness: 0.5, sheen: [1, 0, 0])
        XCTAssertEqual(scene.lightTypeMask & 0x0020_8000, 0x0020_8000)
        let old = try JSONDecoder().decode(MatSurface.self, from: Data("{}".utf8))
        XCTAssertEqual(old, MatSurface())
    }

    /// The benchmarks keep the look of their scores' history unless they ask for the app's.
    func testBenchmarksKeepTheClassicLook() {
        let config = Benchmark.Config("t", scene: SceneSettings(kind: .forest))
        XCTAssertEqual(config.settings.toneMap, .aces)
        XCTAssertTrue(config.settings.post.classic)
        XCTAssertEqual(config.settings.post.bloom, 0.035)
        XCTAssertEqual(config.settings.post.motionBlur, 0)
        XCTAssertEqual(config.settings.contactAO, 0)
        XCTAssertFalse(config.settings.aerialPerspective)
        XCTAssertFalse(config.settings.reflectionSkyRays)
        XCTAssertFalse(config.settings.energyConservation)
        XCTAssertFalse(config.settings.tintedShadows)
        XCTAssertEqual(config.settings.cascades.hiddenLight, 1)
        XCTAssertFalse(config.settings.cascades.plantHits)
        XCTAssertEqual(config.settings.contactAOReach, 0.5)
        let app = config.appLook()
        XCTAssertEqual(app.settings.toneMap, .film)
        XCTAssertEqual(app.settings.post, .unreal)
        XCTAssertGreaterThan(app.settings.contactAO, 0)
        XCTAssertTrue(app.settings.aerialPerspective)
        XCTAssertTrue(app.settings.reflectionSkyRays)
        XCTAssertTrue(app.settings.energyConservation)
        XCTAssertTrue(app.settings.tintedShadows)
        XCTAssertEqual(app.settings.cascades.hiddenLight, 0.25)
        XCTAssertTrue(app.settings.cascades.plantHits)
        XCTAssertEqual(app.settings.contactAOReach, 0.2)
    }

    /// Unreal's default shutter: at 60 fps a frame's motion is blurred over its own length, at 30 fps over the same time.
    func testMotionBlurDefaults() {
        XCTAssertEqual(PostSettings.unreal.motionBlur, 0.5)
        XCTAssertEqual(PostSettings.unreal.motionBlurMax, 5)
        XCTAssertEqual(PostSettings().motionBlur, 0, "off in a bare lens")
        XCTAssertTrue(PostSettings.unreal.isOn)
    }
}
