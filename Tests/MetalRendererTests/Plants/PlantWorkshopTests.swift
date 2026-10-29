import XCTest
import Metal
import QuartzCore
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

/// Scene+Plants.swift, Scene+PlantPreview.swift: the plant workshop shows the library's own plants, in its layouts and
/// views, on Unreal's preview stage (with its scale figure, size ruler and turning lights), and is quick to make again
/// (the plant editor remakes it at every edit).
final class PlantWorkshopTests: XCTestCase {
    private func workshop(_ change: (inout PlantSceneSettings) -> Void = { _ in }, catalog: String = "builtin",
                          assemblies: Bool = false) -> Scene {
        var settings = SceneSettings(kind: .plants)
        settings.realism = .off   // (the plants alone: no scans)
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
        XCTAssertGreaterThan(stats.twigs, 50)
        XCTAssertEqual(stats.height, plant.height)
        XCTAssertEqual(scene.instances.count, 1 + 2)   // the floor, the oak's wood and leaves
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

    /// The light view: a grown plant's stems in bands of the light they get, shaded inside the crown and lit at its
    /// top; no leaf, no twig.
    func testTheLightView() {
        let scene = workshop { $0.view = .light }
        func banded(_ m: Int) -> Bool {
            let albedo = scene.materials[m].albedo
            return Scene.lightColors.contains { simd_length(SIMD3(albedo.x, albedo.y, albedo.z) - $0 * 0.6) < 1e-5 }
        }
        let stems = scene.instances.indices.filter { banded(scene.instances[$0].material) }
        XCTAssertGreaterThanOrEqual(Set(stems.map { scene.instances[$0].material }).count, 3, "a few bands of light")
        XCTAssertEqual(stems.count + 1, scene.instances.count, "nothing but the stems and the floor")
        for inst in scene.instances { XCTAssertEqual(scene.materials[inst.material].params.w, 0) }
        // The trunk's foot is in the crown's shade, the leader's tip in the sun.
        let lit = Growth.lit(PlantCatalog.builtIn[.oak].growth!, seed: 9)
        XCTAssertEqual(lit.light.count, lit.skeleton.stems.count)
        XCTAssertLessThan(lit.light.min()!, 0.5)
        XCTAssertGreaterThan(lit.light.max()!, 0.8)
    }

    /// Unreal's preview stage: a floor and a sun 40° up, no ground or water; camera rays see the dark grey backdrop, a
    /// constant grey sky without air lights the plant (Unreal's Grey Ambient profile), the exposure is fixed.
    func testTheStage() throws {
        let scene = workshop()
        XCTAssertNil(scene.terrain)
        XCTAssertNil(scene.water)
        XCTAssertEqual(scene.backdrop, Scene.previewBackdrop)
        let suns = scene.lights.filter { $0.kind.isSun }
        XCTAssertEqual(suns.count, 1)
        let sun = try XCTUnwrap(suns.first).pose(0).direction
        XCTAssertEqual(asin(sun.y), Scene.degrees(40), accuracy: 1e-4)
        XCTAssertNotNil(scene.previewRig)
        // The floor is Unreal's preview grid: metre tiles, no textures.
        let floor = try XCTUnwrap(scene.instances.first { scene.materialExtras[$0.material]?.textures.z == GPUMaterialExtra.gridKind })
        XCTAssertEqual(scene.materialExtras[floor.material]?.surface.y, 1)
        XCTAssertEqual(scene.materials[floor.material].textures, SIMD4(repeating: .max))
        var settings = SceneSettings(kind: .plants)
        settings.realism = .on
        XCTAssertEqual(SkySettings.preset(for: .plants).mode, .constant)
        XCTAssertEqual(scene.skyColor, Scene.previewSky)
        XCTAssertEqual(try XCTUnwrap(suns.first).color, Scene.previewSun, "the profile's white sun")
        XCTAssertFalse(SkySettings.preset(for: .plants).clouds)
        XCTAssertFalse(FogSettings.preset(for: settings).enabled, "no aerial perspective on the stage")
        XCTAssertFalse(PostSettings.preset(for: settings).autoExposure)
        // Other scenes have no backdrop.
        XCTAssertNil(Scene(SceneSettings(kind: .cornell)).backdrop)
    }

    /// The lights turn about the plant: the rig's yaw turns the sun's direction about the vertical, and the spin goes on
    /// from where it was, within a turn.
    func testTheLightsTurn() throws {
        let scene = workshop()
        let rig = try XCTUnwrap(scene.previewRig), sun = try XCTUnwrap(scene.lights.first { $0.kind.isSun })
        let before = sun.pose(0).direction
        rig.yaw = 90
        let after = sun.pose(0).direction
        XCTAssertEqual(after.y, before.y, accuracy: 1e-5)
        XCTAssertEqual(dot(SIMD2(before.x, before.z), SIMD2(after.x, after.z)), 0, accuracy: 1e-5, "a quarter turn")
        XCTAssertEqual(after, PlantPreviewRig.sun(yaw: 90))
        XCTAssertEqual(PlantPreviewPlayer.spun(0, dt: 0.5), PlantPreviewRig.spinRate * 0.5, accuracy: 1e-5)
        XCTAssertEqual(PlantPreviewPlayer.spun(355, dt: 1), 5, accuracy: 1e-3)
        XCTAssertTrue(scene.behaviour is PlantPreviewPlayer)
    }

    /// The scale figure: a person 1.6-2 m tall standing on the floor beside the plant, outside its bounds, and in the
    /// camera's view.
    func testTheFigure() throws {
        let plain = workshop(), scene = workshop { $0.figure = true }
        XCTAssertGreaterThan(scene.instances.count, plain.instances.count)
        let plant = try XCTUnwrap(plain.focus), focus = try XCTUnwrap(scene.focus)
        XCTAssertGreaterThan(focus.hi.x, plant.hi.x, "the figure stands to the plant's right")
        var body = AABB()
        for inst in scene.instances[plain.instances.count...] {
            let (lo, hi) = scene.meshBounds(inst.mesh)
            body.grow(AABB(lo: lo, hi: hi).transformed(inst.transform))
        }
        XCTAssertGreaterThan(body.hi.y - body.lo.y, 1.6)
        XCTAssertLessThan(body.hi.y - body.lo.y, 2)
        XCTAssertEqual(body.lo.y, 0, accuracy: 0.02)
        XCTAssertGreaterThan(body.lo.x, plant.hi.x, "not inside the plant")
        XCTAssertLessThanOrEqual(body.hi.x, focus.hi.x + 1e-3, "in the focus the camera frames")
    }

    /// The size ruler: bars only the camera sees, of the plant's width, depth and height, and labels of its sizes.
    func testTheRuler() throws {
        let plain = workshop(), scene = workshop { $0.ruler = true }
        let plant = try XCTUnwrap(plain.focus), size = plant.hi - plant.lo
        let added = Array(scene.instances[plain.instances.count...])
        XCTAssertTrue(added.allSatisfy { $0.mask == Scene.maskLights }, "seen, not shadowing")
        let strokes = [size.x, size.z, size.y].map { Scene.strokes(Scene.metres($0)).count }.reduce(0, +)
        XCTAssertEqual(added.count, 3 + strokes, "three bars and the labels' strokes")
        // The three bars (each before its label's strokes), the plant's sizes long (and as thick again); the depth's
        // reaches the width's bar in front, the height's stands on the floor.
        let labels = [size.x, size.z].map { Scene.strokes(Scene.metres($0)).count }
        let bars = [0, 1 + labels[0], 2 + labels[0] + labels[1]].map { added[$0].transform }
        func length(_ m: float4x4, _ c: Int) -> Float { simd_length(SIMD3(m[c].x, m[c].y, m[c].z)) }
        let gap = 0.6 * max((size.x + size.y + size.z) / 2 * 0.05, 0.08)
        for (bar, want) in zip(bars, [size.x, size.z + gap, plant.hi.y]) {
            XCTAssertEqual(length(bar, 0) - length(bar, 1), want, accuracy: 1e-3)
        }
        XCTAssertEqual(Scene.metres(4.2), "4.20m")
        XCTAssertEqual(Scene.strokes("8").count, 7)
        XCTAssertEqual(Scene.strokes("1.0m").count, 1 + 1 + 6 + 4)
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
        tall.growth?.targetHeight = 20
        tall.growth?.cycles = 60
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
                _ = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(slots: 3))
                let total = (CACurrentMediaTime() - start) * 1000
                if total < best { best = total; sceneMs = (made - start) * 1000 }
            }
            print(String(format: "Workshop %@: %.1f ms (scene %.1f, buffers %.1f)", name, best, sceneMs, best - sceneMs))
            XCTAssertLessThan(best, 2000, name)
        }
    }
}
