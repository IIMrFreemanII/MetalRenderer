import XCTest
import simd
@testable import Editors
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// The Mixamo clip library (MixamoLibrary.swift): its index, names, picks, and the clips Tools/mixamo/download.py
/// writes (skinless, 60 fps), read and retargeted onto the characters in Assets/Characters. The last test is skipped
/// where ~/MixamoAnimations (METALRENDERER_MIXAMO) or Assets/Characters isn't there.
final class MixamoLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mixamo-\(UUID().uuidString)")
        // The same motion on two characters, Y Bot's listed first whatever the names' order.
        try write("X Bot", [("c9c87b9c-0000", "2hand Idle"), ("aaaa0000-0000", "Hip Hop Dancing")])
        try write("Y Bot", [("c9c87b9c-0000", "2hand Idle"), ("bbbb0000-0000", "Hip Hop Dancing"), ("cccc0000-0000", "Breakdance Freeze Var 2"),
                            ("dddd0000-0000", "Breakdance Freeze Var 3"), ("eeee0000-0000", "180 Turn W/ Briefcase")])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ character: String, _ clips: [(id: String, name: String)]) throws {
        let dir = folder.appendingPathComponent(character)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = clips.map { ["id": $0.id, "name": $0.name, "file": "\($0.name.replacingOccurrences(of: "/", with: "_")) [\($0.id.prefix(8))].fbx"] }
        try JSONSerialization.data(withJSONObject: index).write(to: dir.appendingPathComponent("index.json"))
    }

    func testIndexListsEachMotionOnceFromYBot() {
        let library = MixamoLibrary(folder)
        XCTAssertEqual(library.entries.count, 6)
        XCTAssertEqual(library.entries.filter { $0.entry.id == "c9c87b9c-0000" }.map { $0.url.deletingLastPathComponent().lastPathComponent }, ["Y Bot"])
        XCTAssertEqual(MixamoLibrary(folder.appendingPathComponent("missing")).entries.count, 0)
    }

    func testFindsByNameCaseIdAndUniquePart() {
        let library = MixamoLibrary(folder)
        XCTAssertEqual(library.find("2hand Idle")?.entry.id, "c9c87b9c-0000")
        XCTAssertEqual(library.find("hip hop dancing")?.entry.id, "bbbb0000-0000")
        XCTAssertEqual(library.find("aaaa0000")?.entry.id, "aaaa0000-0000")
        XCTAssertEqual(library.find("briefcase")?.entry.name, "180 Turn W/ Briefcase")
        XCTAssertNil(library.find("Breakdance"), "two clips have it")
        XCTAssertEqual(library.find("dancing")?.entry.id, "bbbb0000-0000", "one name, two motions: the first")
        XCTAssertNil(library.find("Moonwalk"))
    }

    func testFilesForClipsAndRoutine() {
        let library = MixamoLibrary(folder)
        let urls = library.files(clips: "briefcase, random:3:7, 2hand idle", routine: ["Hip Hop Dancing", "Idle"], have: ["Idle"])
        XCTAssertEqual(urls.count, Set(urls).count, "each once")
        XCTAssertEqual(urls.first.map(MixamoLibrary.clipName), "Hip Hop Dancing")
        XCTAssertTrue(urls.map(MixamoLibrary.clipName).contains("180 Turn W_ Briefcase"))
        XCTAssertEqual(library.random(count: 3, seed: 7).map(\.entry.id), library.random(count: 3, seed: 7).map(\.entry.id))
        XCTAssertEqual(library.random(count: 99).count, 6)
    }

    func testRoutineAndClipNames() {
        let steps = MixamoLibrary.parseRoutine("Idle:2.5, Hip Hop Dancing ,Breakdance Freeze Var 2:4,")
        XCTAssertEqual(steps.map(\.clip), ["Idle", "Hip Hop Dancing", "Breakdance Freeze Var 2"])
        XCTAssertEqual(steps.map(\.seconds), [2.5, nil, 4])
        XCTAssertEqual(MixamoLibrary.clipName(URL(fileURLWithPath: "/a/Hip Hop Dancing [c9c8f2a1].fbx")), "Hip Hop Dancing")
        XCTAssertEqual(MixamoLibrary.clipName(URL(fileURLWithPath: "/a/Hip Hop Dancing (1).fbx")), "Hip Hop Dancing (1)")
        XCTAssertEqual(MixamoLibrary.clipName(URL(fileURLWithPath: "/a/Box [big].fbx")), "Box [big]")
    }

    /// Downloaded clips (no mesh, 60 keys a second) read and go onto both characters.
    func testDownloadedClipsImport() throws {
        let downloaded = MixamoLibrary().entries.prefix(3).map(\.url)
        let characters = ((try? FileManager.default.contentsOfDirectory(at: CharacterLibrary.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "fbx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !downloaded.isEmpty, !characters.isEmpty else { throw XCTSkip("no downloaded clips in \(MixamoLibrary.directory.path)") }
        let library = try CharacterLibrary.importFiles(characters: characters, clips: Array(downloaded))
        for c in library.characters {
            XCTAssertEqual(c.clips.map(\.name), downloaded.map(MixamoLibrary.clipName))
            for clip in c.clips {
                XCTAssertEqual(clip.rate, 60, accuracy: 0.01, clip.name)
                XCTAssertGreaterThan(clip.keyCount, 30, clip.name)
                XCTAssertTrue(clip.rotations.allSatisfy { abs(simd_length($0) - 1) < 1e-3 }, clip.name)
            }
        }
    }

    /// Every downloaded file, in every character's folder, reads as a 60 fps clip. Opt-in (a few thousand files):
    /// METALRENDERER_MIXAMO_ALL=1.
    func testEveryDownloadedClipReads() throws {
        guard ProcessInfo.processInfo.environment["METALRENDERER_MIXAMO_ALL"] == "1" else { throw XCTSkip("set METALRENDERER_MIXAMO_ALL=1") }
        let folders = ((try? FileManager.default.contentsOfDirectory(at: MixamoLibrary.directory, includingPropertiesForKeys: nil)) ?? [])
        let files = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "fbx" }
        }
        guard !files.isEmpty else { throw XCTSkip("no downloaded clips in \(MixamoLibrary.directory.path)") }
        var problems = [String?](repeating: nil, count: files.count)
        problems.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                do {
                    let clip = try CharacterImporter.clip(files[i])
                    if abs(clip.rate - 60) > 0.01 { out[i] = "\(files[i].lastPathComponent): \(clip.rate) keys/s" }
                } catch {
                    out[i] = "\(files[i].lastPathComponent): \(error)"
                }
            }
        }
        let failed = problems.compactMap { $0 }
        print("Mixamo: \(files.count - failed.count) of \(files.count) clips read")
        XCTAssertEqual(failed, [], "\(failed.count) clips")
    }
}
