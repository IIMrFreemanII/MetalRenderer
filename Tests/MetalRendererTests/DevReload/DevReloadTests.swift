import XCTest
@testable import EngineCore
@testable import Game
@testable import MetalRenderer

/// The dev build's hot reload (DevReload): what a saved file asks for, the watcher's batching, the app's own saves
/// left alone, and the settings panel's rows following the game's.
final class DevReloadTests: XCTestCase {
    private let root = "/repo"

    func testWhatASaveChanges() {
        XCTAssertEqual(DevChange.of("/repo/Sources/MetalRenderer/Shaders.metal", root: root), .shaders)
        XCTAssertEqual(DevChange.of("/repo/Assets/Plants/oak.swift", root: root), .plants)
        XCTAssertEqual(DevChange.of("/repo/Assets/Plants/oak.json", root: root), .plants)
        XCTAssertEqual(DevChange.of("/repo/Sources/MetalRenderer/Shaders/Lighting.metal", root: root), .shaders)
        XCTAssertEqual(DevChange.of("/repo/Sources/MetalRenderer/ShadersVFX.metal", root: root), .shaders)
        XCTAssertEqual(DevChange.of("/repo/Sources/Game/Scene/Builders/Scene+Lights.swift", root: root), .game)
        XCTAssertEqual(DevChange.of("/repo/Sources/Physics/PhysicsWorld.swift", root: root), .code("Physics"))
        XCTAssertEqual(DevChange.of("/repo/Assets/Scenes/demolition.scene", root: root), .sceneFile("/repo/Assets/Scenes/demolition.scene"))
        XCTAssertEqual(DevChange.of("/repo/Assets/Plants/oak.json", root: root), .plants)
        XCTAssertEqual(DevChange.of("/repo/Assets/Buildings/office.json", root: root), .buildings)
        // Not the outlines, editors' temporary files, other folders, or anything outside the package.
        XCTAssertNil(DevChange.of("/repo/Assets/Scenes/Outlines/demolition.json", root: root))
        XCTAssertNil(DevChange.of("/repo/Sources/Game/.Scene+Lights.swift.swp", root: root))
        XCTAssertNil(DevChange.of("/repo/Sources/Game/Scene+Lights.swift~", root: root))
        XCTAssertNil(DevChange.of("/repo/Tools/build.sh", root: root))
        XCTAssertNil(DevChange.of("/elsewhere/Sources/Game/GameScenes.swift", root: root))
        XCTAssertNil(DevChange.of("/repo/Sources/Game", root: root))
    }

    /// Saves close together come as one batch, after they settle.
    func testSavesSettleIntoOneBatch() {
        let came = expectation(description: "one batch")
        var batches: [Set<DevChange>] = []
        let watcher = SourceWatcher(root: URL(fileURLWithPath: root), settle: 0.2) { batch in
            batches.append(batch)
            came.fulfill()
        }
        watcher.report(["/repo/Sources/Game/GameScenes.swift"])
        watcher.report(["/repo/Sources/MetalRenderer/Shaders.metal", "/repo/README.md"])
        watcher.report(["/repo/Sources/Game/Settings/GameScenes+Rows.swift"])
        wait(for: [came], timeout: 2)
        XCTAssertEqual(batches, [[.game, .shaders]])
    }

    /// A file the app wrote itself isn't a change; another program's write is, once.
    func testTheAppsOwnSavesDontCount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filestamps-\(UUID().uuidString).scene")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("one".utf8).write(to: url)
        FileStamps.note(url)
        XCTAssertFalse(FileStamps.changed(url))
        try Data("two".utf8).write(to: url)
        XCTAssertTrue(FileStamps.changed(url))
        XCTAssertFalse(FileStamps.changed(url))   // the same save, reported again
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(FileStamps.changed(url))
        XCTAssertFalse(FileStamps.changed(url))
    }

    /// The game's rows, registered again by its reloaded code, are in the sections the panel is made from.
    func testSectionsFollowTheGamesRows() {
        GameScenes.register()
        let saved = SettingsTable.sceneRows
        defer { SettingsTable.sceneRows = saved }
        let titles = { SettingsTable.sections.flatMap(\.rows).map(\.title) }
        let before = titles()
        SettingsTable.sceneRows = saved + [SettingSpec.check("Reloaded row", \.paused)]
        XCTAssertEqual(titles().filter { $0 == "Reloaded row" }.count, 1)
        SettingsTable.sceneRows = saved
        XCTAssertEqual(titles(), before)
    }
}
