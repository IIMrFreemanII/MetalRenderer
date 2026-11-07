import XCTest
import simd
@testable import EngineCore
@testable import Game
@testable import MetalRenderer

/// The light lab's catalog and layout (Sources/Game/Scene/Builders/LightLab).
final class LightLabTests: XCTestCase {
    func testBookmarksAreTheTwentySixBooths() {
        let bookmarks = LightLab.bookmarks()
        XCTAssertEqual(bookmarks.count, 26)
        let numbers = bookmarks.map { Int($0.name.prefix(while: \.isNumber)) }
        XCTAssertEqual(numbers.compactMap { $0 }.sorted(), Array(1...26))
        XCTAssertEqual(Set(bookmarks.map(\.name)).count, 26)
        for n in 1...26 {
            XCTAssertEqual(SceneDefinition.resolve(String(n), in: bookmarks).map { Int($0.name.prefix(while: \.isNumber)) }, n)
        }
        XCTAssertEqual(LightLab.booths.map(\.number), Array(1...26))
    }

    func testHallBoothsAreInsideTheHallAndApart() {
        let hall = Array((1...22).map { $0 }) + [26]
        let frames = hall.map { LightLab.frame($0) }
        for f in frames {
            let box = f.outer
            XCTAssertGreaterThanOrEqual(box.lo.x, 0, "booth \(f.number)")
            XCTAssertLessThanOrEqual(box.hi.x, LabKit.corridorEnd, "booth \(f.number)")
            XCTAssertEqual(f.p(0, 0, 0).y, 0)
        }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let (x, y) = (a.outer, b.outer)
                let overlap = all(x.lo + 1e-3 .< y.hi) && all(y.lo + 1e-3 .< x.hi)
                XCTAssertFalse(overlap, "booths \(a.number) and \(b.number) overlap")
            }
        }
    }

    func testDoorFacesTheCorridor() {
        for n in [1, 2, 26] {
            let f = LightLab.frame(n)
            let door = f.p(0, 1, 0)
            XCTAssertEqual(abs(door.z), 1.8, accuracy: 1e-4)
            XCTAssertLessThan(abs(f.p(0, 1, 4).z), 6.0 + 1e-4)
            XCTAssertGreaterThan(abs(f.p(0, 1, 4).z), 5.7)
        }
    }

    func testBuildsWithAllBoothsAndAlone() {   // Scene.init builds the settings' scene
        let all = Scene(SceneSettings(kind: .lightLab))
        var one = SceneSettings(kind: .lightLab)
        one.lightLab.only = 3
        let alone = Scene(one)
        XCTAssertGreaterThan(all.instances.count, alone.instances.count)
        // The yard's sun and booth 25's second: MegaLights' most (LightTable.maxSuns); a booth alone keeps the yard's.
        XCTAssertEqual(suns(all), 2)
        XCTAssertEqual(suns(alone), 1)
        var three = SceneSettings(kind: .lightLab)
        three.lightLab.variant = .threeSuns
        XCTAssertEqual(suns(Scene(three)), 3)
    }

    /// The normal variant stays under the light table's threshold, so its references trace every light.
    func testNormalVariantStaysUnderTheLightTable() {
        XCTAssertLessThan(Scene(SceneSettings(kind: .lightLab)).lights.count, Scene.lightTableThreshold)
    }

    private func suns(_ scene: Scene) -> Int { scene.lights.filter { if case .sun = $0.kind { true } else { false } }.count }
}
