import XCTest
import Metal
import QuartzCore
import simd
@testable import MetalRenderer

/// A character as data (CharacterDNA) and its catalog and store.
final class CharacterDNATests: XCTestCase {
    func testDNARoundTripsThroughJSON() throws {
        var d = BuiltInCharacters.all[2]
        d.morphs["belly"] = 0.4
        d.bones["legs"] = -0.3
        let data = try JSONEncoder().encode(d)
        XCTAssertEqual(try JSONDecoder().decode(CharacterDNA.self, from: data), d)
    }

    func testMissingFieldsTakeTheDefaults() throws {
        let d = try JSONDecoder().decode(CharacterDNA.self, from: Data(#"{"id": "x", "macro": {"sex": 1}}"#.utf8))
        XCTAssertEqual(d.id, "x")
        XCTAssertEqual(d.macro.sex, 1)
        XCTAssertEqual(d.macro.age, CharacterDNA.Macro().age)
        XCTAssertEqual(d.look, CharacterDNA.Look())
    }

    func testSanitizingClampsAndDropsZeros() {
        var d = CharacterDNA()
        d.macro.age = 200
        d.macro.weight = -3
        d.morphs = ["belly": 0, "chest": 4]
        let s = d.sanitized()
        XCTAssertEqual(s.macro.age, 90)
        XCTAssertEqual(s.macro.weight, -1)
        XCTAssertEqual(s.morphs, ["chest": 1])
        XCTAssertEqual(s.key, s.sanitized().key)
    }

    func testFilesLayOverTheBuiltIns() {
        var mine = BuiltInCharacters.all[0]
        mine.macro.weight = 0.5
        var other = CharacterDNA()
        other.id = "zed"
        let c = CharacterCatalog.builtIn.merging([mine, other])
        XCTAssertEqual(c.characters.count, BuiltInCharacters.all.count + 1)
        XCTAssertEqual(c.character(id: mine.id)?.macro.weight, 0.5)
        XCTAssertEqual(c.characters.last?.id, "zed")
        XCTAssertNotEqual(c.fingerprint, CharacterCatalog.builtIn.fingerprint)
    }

    func testTheStoreWritesAndReadsAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("characters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var d = CharacterDNA()
        d.id = "saved"
        d.macro.muscle = 0.7
        try CharacterStore.save(d, in: folder)
        XCTAssertEqual(CharacterStore.load(from: folder).character(id: "saved")?.macro.muscle, 0.7)
        try CharacterStore.remove("saved", in: folder)
        XCTAssertNil(CharacterStore.load(from: folder).character(id: "saved"))
    }
}
