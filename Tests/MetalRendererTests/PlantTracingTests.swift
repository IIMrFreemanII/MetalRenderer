import XCTest
import Metal
import simd
@testable import MetalRenderer

/// The plants in Metal's structures (PlantTracing.swift): each plant names its assembly's variant for its phase bucket
/// and the share of leaves it keeps, and plantWindKernel poses a variant's parts as the shading turns their points.
final class PlantTracingTests: XCTestCase {
    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")

    private func forest(trees: Int = 40) -> Scene {
        var settings = SceneSettings(kind: .forest)
        settings.trees = trees
        settings.undergrowth = 10
        return Scene(settings, assemblies: true)
    }

    /// A scene's plants on the GPU, in a scene that moves (a set of variants per frame slot).
    private func plants(_ scene: Scene, device: MTLDevice, queue: MTLCommandQueue) throws -> (SceneBuffers, PlantTracing) {
        let buffers = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(api: .metal3, slots: 3))
        return (buffers, try XCTUnwrap(buffers.plants))
    }

    func testTheLayoutsAreTheShaders() throws {
        XCTAssertEqual(MemoryLayout<RTPart>.size, 128)   // RTPart's static_assert
        let text = try String(contentsOf: PlantTracingTests.shaders.deletingLastPathComponent()
            .appendingPathComponent("Shaders/Foliage.metal"), encoding: .utf8)
        XCTAssertTrue(text.contains("constant uint PLANT_PHASES = \(Wind.phases);"))
        let intersect = try String(contentsOf: PlantTracingTests.shaders.deletingLastPathComponent()
            .appendingPathComponent("Shaders/Intersect.metal"), encoding: .utf8)
        XCTAssertTrue(intersect.contains("constant uint CUTOUT_SIZE = \(FoliageTextures.cardSheetSize);"))
    }

    /// A plant moves the scene (its variants are posed every frame in the wind), but not the open world's tiles,
    /// whose instance blocks need a still scene.
    func testPlantsMoveTheScene() {
        let scene = forest()
        XCTAssertFalse(scene.assemblies.isEmpty)
        XCTAssertFalse(scene.isStill)
        XCTAssertNotEqual(scene.lightTypeMask & 0x4000_0000, 0, "FOLIAGE")
        var baked = SceneSettings(kind: .forest)
        baked.trees = 40
        baked.bakedPlants = true
        XCTAssertTrue(Scene(baked, assemblies: true).assemblies.isEmpty)
    }

    /// Plants of a bucket share their variant; a deciduous plant's share of leaves picks its prefix, an evergreen keeps
    /// them all; with no leaves down every plant names its bucket's full variant.
    func testVariantsByBucketAndShare() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let scene = forest()
        let (_, plants) = try plants(scene, device: device, queue: queue)
        let deciduous = try XCTUnwrap(scene.assemblies.indices.first { !scene.assemblies[$0].evergreen && scene.assemblies[$0].parts.contains { $0.leafCount > 0 } })
        let evergreen = try XCTUnwrap(scene.assemblies.indices.first { scene.assemblies[$0].evergreen })
        var byBucket: [Int: Int] = [:]
        for id in UInt32(0)..<200 {
            let v = plants.variant(assembly: deciduous, id: id, fall: 0)
            XCTAssertEqual(byBucket.updateValue(v, forKey: Wind.bucket(id)) ?? v, v, "a bucket's plants share their variant")
            XCTAssertEqual(plants.variant(assembly: evergreen, id: id, fall: 1), plants.variant(assembly: evergreen, id: id, fall: 0),
                           "an evergreen keeps its leaves")
        }
        XCTAssertEqual(byBucket.count, Wind.phases)
        // In winter every deciduous plant has dropped them all: the variant of the share 0, one per bucket.
        let winter = Set((UInt32(0)..<200).map { plants.variant(assembly: deciduous, id: $0, fall: 1) })
        let summer = Set((UInt32(0)..<200).map { plants.variant(assembly: deciduous, id: $0, fall: 0) })
        XCTAssertEqual(winter.count, Wind.phases)
        XCTAssertEqual(summer.count, Wind.phases)
        XCTAssertTrue(winter.isDisjoint(with: summer))
        XCTAssertEqual(Wind.keep(fall: 0, id: 5), 1)
        XCTAssertEqual(Wind.keep(fall: 1, id: 5), 0)
    }

    /// One of plantWindKernel's transforms against the bones' turns done here: a part's points posed in the plant's
    /// space for its variant's phase (the shading's partBones), where the posed instance puts them.
    func testTheKernelPosesThePartsAsTheShadingTurnsThem() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsRaytracing, "no ray tracing on this GPU")
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let scene = forest()
        let (_, plants) = try plants(scene, device: device, queue: queue)
        let library = try Pipelines.compile(device: device, source: PlantTracingTests.shaders, stats: false, compiler: nil)
        let constants = MTLFunctionConstantValues()
        var types: UInt32 = 0x3F
        constants.setConstantValue(&types, type: .uint, index: 0)
        let pipeline = try Pipelines.makeState(device: device, library: library, compiler: nil, kernel: .plantWind, constants: constants)
        var wind = WindFrame()
        wind.wind = SIMD4(0.8, 0.6, 1, 0.7)
        wind.time = 3.7
        let cmd = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cmd.makeComputeCommandEncoder())
        plants.encodeWind(Metal3Pass(enc: enc), slot: 1, pipeline: pipeline, wind: wind)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertNil(cmd.error)

        let parts = scene.assemblies.flatMap(\.parts)
        let work = plants.workItems
        let out = plants.descriptors(slot: 1).contents()
        var checked = 0, swung = 0
        for d in stride(from: 0, to: work.count, by: 7) where work[d].x != .max {
            let part = parts[Int(work[d].x)]
            let phase = (Float(work[d].y) + 0.5) * (2 * .pi / Float(Wind.phases)), gust = 1 - 0.5 * wind.wind.w
            func bones(_ p: SIMD3<Float>) -> SIMD3<Float> {
                var q = p
                for (bone, speed) in [(part.bough, Float(3.4)), (part.limb, Float(1.5))] where bone.angle != 0 {
                    let pp = bone.phase + phase
                    let f = speed * (0.75 + 0.5 * (bone.phase * 7.31 - (bone.phase * 7.31).rounded(.down)))
                    let a = wind.wind.z * bone.angle * gust * (0.65 * Wind.wave(wind.time * f + pp) + 0.35 * Wind.wave(wind.time * f * 2.37 + 1.7 * pp))
                    q = bone.pivot + Wind.turn(bone.axis, a) * (q - bone.pivot)
                }
                return q
            }
            let m = (0..<12).map { out.load(fromByteOffset: d * PlantTracing.descriptorStride + 4 * $0, as: Float.self) }
            for corner in [part.bounds.lo, part.bounds.hi] {
                let rest = part.transform.inverse * SIMD4(corner, 1)   // the part's own space
                let p = SIMD3(rest.x, rest.y, rest.z)
                let posed = SIMD3(m[0], m[1], m[2]) * p.x + SIMD3(m[3], m[4], m[5]) * p.y + SIMD3(m[6], m[7], m[8]) * p.z + SIMD3(m[9], m[10], m[11])
                let expected = bones(corner)
                XCTAssertLessThan(length(posed - expected), 1e-3 * max(1, length(expected)), "descriptor \(d)")
                if length(expected - corner) > 1e-4 { swung += 1 }
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50)
        XCTAssertGreaterThan(swung, 10, "the wind turns the boughs")
    }

    /// The root's turn and the ground cover's lean on the CPU: rigid for a plant (its foot stays), a shear by height
    /// for a patch (its foot stays, its top moves downwind); nothing without wind.
    func testTheInstancesLeanDownwind() {
        var t = translate([3, 0, -2]) * float4x4(simd_quatf(angle: 0.7, axis: [0, 1, 0]))
        t = t * float4x4(diagonal: [1.3, 1.3, 1.3, 1])
        let wind = SIMD4<Float>(1, 0, 1, 0)   // to +x, full strength, steady
        XCTAssertEqual(Wind.plant(t, wind: SIMD4(1, 0, 0, 0), time: 1, id: 3), t)
        let p = Wind.plant(t, wind: wind, time: 1.2, id: 3)
        XCTAssertEqual(SIMD3(p.columns.3.x, p.columns.3.y, p.columns.3.z), [3, 0, -2], "it turns about its foot")
        XCTAssertEqual(length(SIMD3(p.columns.0.x, p.columns.0.y, p.columns.0.z)), 1.3, accuracy: 1e-4, "rigid")
        let top = p * SIMD4(0, 10, 0, 1), restTop = t * SIMD4(0, 10, 0, 1)
        XCTAssertGreaterThan(top.x, restTop.x, "downwind")
        let c = Wind.cover(t, wind: wind, time: 1.2)
        XCTAssertEqual(c * SIMD4(0.5, 0, 0.5, 1), t * SIMD4(0.5, 0, 0.5, 1), "its foot stays")
        XCTAssertGreaterThan((c * SIMD4(0, 1, 0, 1)).x, (t * SIMD4(0, 1, 0, 1)).x, "its top leans downwind")
    }
}
