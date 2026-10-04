import XCTest
import simd
@testable import MetalRenderer

/// The city's layout (CityPlan.swift) and the city scenes built from it (Scene+City.swift), on the CPU: scenes are
/// built with flat colours, so nothing is generated into the texture cache.
final class CityTests: XCTestCase {
    private func settings(_ change: (inout CitySettings) -> Void = { _ in }) -> CitySettings {
        var c = CitySettings()
        c.blocks = 2
        c.textures = false
        change(&c)
        return c
    }

    private func scene(night: Bool = false, _ change: (inout CitySettings) -> Void = { _ in }) -> Scene {
        Scene(SceneSettings(kind: night ? .cityNight : .city, city: settings(change)))
    }

    // MARK: - The plan

    func testLotsStandInsideTheirBlocksAndApart() {
        for seed in 0..<12 {
            for style in CityStyle.allCases {
                let plan = CityPlan(settings { $0.seed = seed; $0.blocks = 1 + seed % 4; $0.style = style })
                XCTAssertEqual(plan.blocks.count, plan.settings.blocks * plan.settings.blocks)
                for lot in plan.lots {
                    let block = plan.blocks[lot.block]
                    XCTAssertFalse(block.park, "a park has no lots")
                    XCTAssertTrue(block.rect.inset(CityPlan.sidewalk).contains(lot.rect), "seed \(seed) \(style): a lot leaves its block")
                    XCTAssertGreaterThan(simd_reduce_min(lot.rect.size), 4, "seed \(seed) \(style): a sliver of a lot")
                    XCTAssertNotEqual(lot.style, .mixed)
                    XCTAssertGreaterThan(lot.floors, 0)
                    XCTAssertEqual(lot.edges.count, 4)
                }
                for (i, a) in plan.lots.enumerated() {
                    for b in plan.lots[(i + 1)...] where a.block == b.block {
                        XCTAssertFalse(a.rect.overlaps(b.rect), "seed \(seed) \(style): two lots overlap")
                    }
                }
                for block in plan.blocks {
                    XCTAssertTrue(plan.extent.contains(block.rect))
                    for street in plan.streets { XCTAssertFalse(street.rect.overlaps(block.rect), "a block stands in a road") }
                }
            }
        }
    }

    func testALotsFrontLooksOntoAStreetOrOpenGround() {
        let plan = CityPlan(settings { $0.blocks = 4 })
        XCTAssertFalse(plan.lots.isEmpty)
        for lot in plan.lots {
            XCTAssertNotEqual(lot.edges[0], .party, "a building's front is against a neighbour")
            // Its front edge is the one its yaw says: for a street front, that side of the lot lies on the block's edge.
            if lot.edges[0] == .street {
                let site = plan.blocks[lot.block].rect.inset(CityPlan.sidewalk), f = lot.front
                let edge = f.x > 0 ? lot.rect.hi.x - site.hi.x : f.x < 0 ? lot.rect.lo.x - site.lo.x
                    : f.y > 0 ? lot.rect.hi.y - site.hi.y : lot.rect.lo.y - site.lo.y
                XCTAssertEqual(edge, 0, accuracy: 1e-2)
            }
        }
    }

    func testThePlanIsSeeded() {
        let a = CityPlan(settings()), b = CityPlan(settings()), c = CityPlan(settings { $0.seed = 2 })
        XCTAssertEqual(a.lots.map(\.rect), b.lots.map(\.rect))
        XCTAssertEqual(a.lots.map(\.seed), b.lots.map(\.seed))
        XCTAssertNotEqual(a.lots.map(\.rect), c.lots.map(\.rect))
        XCTAssertEqual(Set(a.lots.map(\.seed)).count, a.lots.count, "every lot has its own seed")
    }

    func testEveryStyleIsBuiltInAMixedCity() {
        let styles = Set((0..<4).flatMap { seed in CityPlan(self.settings { $0.seed = seed; $0.blocks = 6 }).lots.map(\.style) })
        XCTAssertEqual(styles, Set(CityStyle.allCases).subtracting([.mixed]))
        XCTAssertTrue(CityPlan(settings { $0.blocks = 4 }).blocks.contains { $0.park })
    }

    // MARK: - The scenes

    func testTheSameSettingsBuildTheSameCity() {
        let a = scene(), b = scene(), c = scene { $0.seed = 7 }
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertEqual(a.indices, b.indices)
        XCTAssertEqual(a.instances.map(\.transform), b.instances.map(\.transform))
        XCTAssertNotEqual(a.positions, c.positions)
    }

    func testTheCityIsStaticAndItsGeometryValid() {
        for night in [false, true] {
            let s = scene(night: night)
            XCTAssertGreaterThan(s.instances.count, 20)
            XCTAssertTrue(s.instances.allSatisfy(\.isStatic))
            XCTAssertEqual(s.positions.count, s.normals.count)
            XCTAssertEqual(s.positions.count, s.uvs.count)
            XCTAssertTrue(s.indices.allSatisfy { Int($0) < s.positions.count })
            XCTAssertTrue(s.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            XCTAssertTrue(s.normals.allSatisfy { abs(length($0) - 1) < 1e-3 })
            XCTAssertTrue(s.textures.isEmpty, "flat colours: no textures")
        }
    }

    func testGlassAndMeshesOfSeveralMaterials() {
        let s = scene()
        let glass = s.instances.filter { $0.mask == Scene.maskGlass }
        XCTAssertGreaterThan(glass.count, 5)
        XCTAssertTrue(glass.allSatisfy { s.materials[$0.material].params.w == 1 }, "glass has a glass material")
        XCTAssertTrue(s.instances.allSatisfy { $0.mask == Scene.maskGlass || s.materials[$0.material].params.w == 0 })
        XCTAssertTrue(s.hasGlass)
        XCTAssertEqual(s.lightTypeMask & 0x3000_0000, 0x3000_0000, "the shaders are told of the glass and the materials per triangle")
        XCTAssertEqual(Scene().lightTypeMask & 0x3000_0000, 0, "...and of neither in a scene without them")
        // One offset per triangle, and none past the scene's materials.
        XCTAssertEqual(s.triangleMaterials.count, s.indices.count / 3)
        XCTAssertTrue(Scene().triangleMaterials.isEmpty)
        var several = 0
        for inst in s.instances {
            let mesh = s.meshes[inst.mesh]
            let offsets = s.triangleMaterials[Int(mesh.firstIndex) / 3 ..< Int(mesh.firstIndex + mesh.indexCount) / 3]
            XCTAssertLessThan(inst.material + Int(offsets.max() ?? 0), s.materials.count)
            if offsets.max() ?? 0 > 0 { several += 1 }
        }
        XCTAssertGreaterThan(several, 5, "a building is one mesh of several materials")
        // Fewer instances than a mesh per material would make: at most opaque + glass per building, and the streets.
        XCTAssertLessThanOrEqual(s.instances.count, 2 * CityPlan(settings()).lots.count + 1)
    }

    func testDayHasOneLightAndNightItsLamps() {
        let day = scene()
        XCTAssertEqual(day.lights.count, 1)
        XCTAssertTrue(day.lights[0].kind.isSun)
        XCTAssertTrue(day.materials.allSatisfy { $0.emission.x + $0.emission.y + $0.emission.z == 0 }, "nothing glows by day")

        let night = scene(night: true)
        XCTAssertTrue(night.usesLightTable)
        XCTAssertGreaterThan(night.meshLights.count, 0)
        XCTAssertGreaterThan(night.lightTypeMask & 0x8000_0000, 0)
    }
}
