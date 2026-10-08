import XCTest
import Metal
import QuartzCore
import simd
@testable import MetalRenderer

/// Scene+Plants.swift: the plant workshop shows the library's own plants, in its layouts and views, and is quick to
/// make again (the plant editor remakes it at every edit).
final class PlantWorkshopTests: XCTestCase {
    private func workshop(_ change: (inout PlantSceneSettings) -> Void = { _ in }, catalog: String = "builtin",
                          assemblies: Bool = false) -> Scene {
        var settings = SceneSettings(kind: .plants)
        settings.plantCatalog = catalog
        change(&settings.plants)
        return Scene(settings, assemblies: assemblies)
    }

    /// The one plant is the library's: the forest's oak 0 at seed 1.
    func testThePlantIsTheLibrarys() throws {
        let scene = workshop()
        let stats = try XCTUnwrap(scene.plantStats)
        let set = Foliage.library(seed: 1, species: [.oak])[0]
        let plant = set.plants[set.plants(of: .mature)[0]]
        let flat = Foliage.flatten(plant, palette: set.palette)
        XCTAssertEqual(stats.species, "oak")
        XCTAssertEqual(stats.traced, flat.wood.triangles + flat.leaves.triangles)
        XCTAssertEqual(stats.leafTriangles, flat.leaves.triangles)
        XCTAssertEqual(stats.parts, plant.parts.count)
        XCTAssertGreaterThan(stats.boughs, 50)
        XCTAssertEqual(stats.height, plant.height)
        XCTAssertEqual(scene.instances.count, 1 + 2)   // the lawn, the oak's wood and leaves
        let focus = try XCTUnwrap(scene.focus)
        XCTAssertEqual(focus.hi.y, plant.bounds.hi.y, accuracy: 1e-4)
        // Its camera sees all of it.
        let camera = scene.defaultCamera
        for corner in [focus.lo, focus.hi, SIMD3(focus.lo.x, focus.hi.y, focus.lo.z), SIMD3(focus.hi.x, focus.lo.y, focus.hi.z)] {
            let v = corner - camera.position
            let depth = dot(v, camera.forward), t = tan(camera.fovY / 2)
            XCTAssertGreaterThan(depth, 0)
            XCTAssertLessThanOrEqual(abs(dot(v, camera.up)) / depth, t * 1.001)
            XCTAssertLessThanOrEqual(abs(dot(v, camera.right)) / depth, t * 1.6 * 1.001)
        }
    }

    func testTheLineupHasEveryAgeAndVariant() {
        let scene = workshop { $0.species = "birch"; $0.layout = .lineup }
        let variants = Foliage.Age.allCases.reduce(0) { $0 + PlantCatalog.builtIn[.birch].variants($1) }
        XCTAssertEqual(variants, 7)
        XCTAssertEqual(scene.instances.count, 1 + 2 * variants)
        // No two plants stand in one place.
        let feet = Set(scene.instances.dropFirst().map { "\($0.transform.columns.3.x) \($0.transform.columns.3.z)" })
        XCTAssertEqual(feet.count, variants)
    }

    /// The skeleton: stems only, a colour to each level, and no leaf anywhere.
    func testTheSkeletonHasNoLeaves() {
        let scene = workshop { $0.species = "conifer"; $0.view = .skeleton }
        XCTAssertGreaterThan(scene.instances.count, 3)
        for inst in scene.instances {
            XCTAssertEqual(scene.materials[inst.material].params.w, 0, "a translucent (leaf) material")
        }
        let plain = workshop { $0.species = "conifer" }
        XCTAssertTrue(plain.instances.contains { plain.materials[$0.material].params.w > 0 })
    }

    /// What the editor sends while it edits keeps the scene the same workshop (its fast reload); what it shows doesn't.
    func testWhatAnEditIs() {
        var a = SceneSettings(kind: .plants), b = a
        b.plantCatalog = "x"
        b.plants.variant = 2
        b.plants.age = .young
        XCTAssertTrue(a.isSameWorkshop(as: b))
        b.plants.layout = .lineup
        XCTAssertFalse(a.isSameWorkshop(as: b))
        a.kind = .forest
        XCTAssertFalse(a.isSameWorkshop(as: a))
    }

    /// A species of a catalog of its own, and the edited one compared with the saved one.
    func testCustomAndCompared() {
        var catalog = PlantCatalog.builtIn
        var tall = catalog[.oak]
        tall.recipe.levels[0].length = 20
        catalog.species[0] = tall
        let key = PlantCatalog.register(catalog)
        let edited = workshop(catalog: key)
        XCTAssertGreaterThan(edited.plantStats!.height, workshop().plantStats!.height + 4)
        let compared = workshop({ $0.compare = PlantCatalog.register(.builtIn) }, catalog: key)
        XCTAssertEqual(compared.plantStats!.height, workshop().plantStats!.height)
    }

    /// How long a workshop takes to make again, as the renderer does it: the scene, then its buffers and structures.
    func testRemakingIsQuick() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard device.supportsRaytracing else { throw XCTSkip("no Metal ray tracing") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for (name, change) in [("oak", { (_: inout PlantSceneSettings) in }), ("birch lineup", { $0.species = "birch"; $0.layout = .lineup }),
                               ("conifer skeleton", { $0.species = "conifer"; $0.view = .skeleton })] as [(String, (inout PlantSceneSettings) -> Void)] {
            var best = Double.infinity, sceneMs = 0.0
            for seed in 1...3 {
                let start = CACurrentMediaTime()
                let scene = workshop({ change(&$0); $0.seed = seed }, assemblies: true)
                let made = CACurrentMediaTime()
                _ = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(api: .metal3, slots: 3))
                let total = (CACurrentMediaTime() - start) * 1000
                if total < best { best = total; sceneMs = (made - start) * 1000 }
            }
            print(String(format: "Workshop %@: %.1f ms (scene %.1f, buffers %.1f)", name, best, sceneMs, best - sceneMs))
            XCTAssertLessThan(best, 2000, name)
        }
    }
}
