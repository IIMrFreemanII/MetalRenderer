import XCTest
import simd
@testable import MetalRenderer

/// The FBX reader and the character import (FBXReader.swift, SkinnedCharacter.swift), on the characters in
/// Assets/Characters. Skipped where that folder isn't there.
final class FBXTests: XCTestCase {
    private static let directory = CharacterLibrary.directory
    private static let imported: CharacterLibrary? = {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let characters = files.filter { $0.pathExtension == "fbx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let clips = ((try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Animations"),
                                                                  includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "fbx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !characters.isEmpty, !clips.isEmpty else { return nil }
        return try? CharacterLibrary.importFiles(characters: characters, clips: clips)
    }()

    private func library() throws -> CharacterLibrary {
        guard let library = FBXTests.imported else { throw XCTSkip("no characters in \(FBXTests.directory.path)") }
        return library
    }

    func testCharactersAndClips() throws {
        let library = try library()
        XCTAssertEqual(library.characters.map(\.name), ["X Bot", "Y Bot"])
        XCTAssertEqual(library.characters.map(\.triangleCount), [49112, 55320])
        for c in library.characters {
            XCTAssertEqual(c.joints.count, 65)
            XCTAssertEqual(c.jointNames[0], "mixamorig:Hips")
            XCTAssertEqual(c.joints[0].parent, -1)
            for (j, joint) in c.joints.enumerated().dropFirst() { XCTAssertTrue(joint.parent >= 0 && joint.parent < j, "parents first") }
            XCTAssertEqual(c.clips.map(\.name), ["Idle (1)", "Idle", "Running", "Walking"])
            XCTAssertEqual(c.clips.map(\.keyCount), [118, 501, 39, 63])
            XCTAssertEqual(c.clips.map(\.rate), [60, 60, 60, 60])
            XCTAssertEqual(c.normals.count, c.positions.count)
            XCTAssertEqual(c.skin.count, c.positions.count)
            XCTAssertTrue(c.indices.allSatisfy { Int($0) < c.positions.count })
            // About 1.8 m tall, standing on the ground.
            let lo = c.positions.reduce(SIMD3<Float>(repeating: .infinity), simd_min), hi = c.positions.reduce(-lo, simd_max)
            XCTAssertEqual(lo.y, 0, accuracy: 0.02)
            XCTAssertEqual(hi.y, 1.8, accuracy: 0.1)
        }
        // The same skeleton, joint for joint, whatever order the files list it in.
        XCTAssertEqual(library.characters[0].jointNames, library.characters[1].jointNames)
    }

    func testWeights() throws {
        for c in try library().characters {
            for s in c.skin {
                let w3 = 1 - s.w0 - s.w1 - s.w2
                XCTAssertTrue(s.w0 >= s.w1 && s.w1 >= s.w2 && s.w2 >= w3 - 1e-6 && w3 > -1e-5, "weights \(s)")
                for k in 0..<4 { XCTAssertLessThan(Int((s.joints >> UInt32(8 * k)) & 0xFF), c.joints.count) }
            }
        }
    }

    /// The bind pose as a clip: each joint's bind rotation in its parent's space, from the inverse bind transforms.
    private func bindClip(_ c: SkinnedCharacter) -> SkinnedCharacter.Clip {
        let world = c.joints.map { simd_quatf(vector: $0.inverseBindRotation).inverse }
        let rotations = c.joints.enumerated().map { j, joint in
            (joint.parent < 0 ? world[j] : world[joint.parent].inverse * world[j]).vector
        }
        let root = -world[0].act(SIMD3(c.joints[0].inverseBindTranslation.x, c.joints[0].inverseBindTranslation.y, c.joints[0].inverseBindTranslation.z))
        return SkinnedCharacter.Clip(name: "bind", keyCount: 2, rate: 60, rotations: rotations + rotations,
                                     root: [SIMD4(root, 0), SIMD4(root, 0)], velocity: .zero)
    }

    /// The skeleton's own offsets and the clusters' bind matrices agree: posed in the bind pose, nothing moves.
    func testBindPoseSkinsToItself() throws {
        for var c in try library().characters {
            c.clips = [bindClip(c)]
            let skinned = c.skin(c.palette(clipA: 0, timeA: 0))
            var worst: Float = 0
            for v in c.positions.indices { worst = max(worst, simd_distance(skinned.positions[v], c.positions[v])) }
            XCTAssertLessThan(worst, 1e-4, "\(c.name): the bind pose moved a vertex by \(worst) m")
            for v in c.normals.indices { XCTAssertGreaterThan(simd_dot(skinned.normals[v], c.normals[v]), 0.9999) }
        }
    }

    func testClipsLoopAndTravel() throws {
        for c in try library().characters {
            let count = c.joints.count
            for clip in c.clips {
                var worst: Float = 0
                for j in 0..<count {
                    worst = max(worst, 1 - abs(simd_dot(clip.rotations[j], clip.rotations[(clip.keyCount - 1) * count + j])))
                }
                XCTAssertLessThan(worst, 2e-3, "\(c.name) / \(clip.name): the last key doesn't repeat the first")
                XCTAssertLessThan(simd_distance(clip.root[0], clip.root[clip.keyCount - 1]), 1e-4)
                for q in clip.rotations { XCTAssertEqual(simd_length(q), 1, accuracy: 1e-4) }
            }
            let scale = c.name == "X Bot" ? Float(1.0448) : 1   // X Bot's hips are that much higher than Y Bot's
            XCTAssertEqual(c.clips[c.clip(named: "Walking")!].velocity.z, 1.63 * scale, accuracy: 0.05)
            XCTAssertEqual(c.clips[c.clip(named: "Running")!].velocity.z, 5.68 * scale, accuracy: 0.1)
            XCTAssertEqual(c.clips[c.clip(named: "Idle")!].velocity, .zero)
        }
    }

    /// Every pose stays inside the character's bounds, on its feet.
    func testPosesStandOnTheGround() throws {
        for c in try library().characters {
            for (i, clip) in c.clips.enumerated() {
                for key in stride(from: 0, to: clip.keyCount - 1, by: max(clip.keyCount / 6, 1)) {
                    let p = c.skin(c.palette(clipA: i, timeA: Float(key) + 0.5)).positions
                    let lo = p.reduce(SIMD3<Float>(repeating: .infinity), simd_min), hi = p.reduce(-lo, simd_max)
                    XCTAssertTrue(lo.y > -0.08 && lo.y < 0.25, "\(c.name) / \(clip.name) key \(key): feet at \(lo.y) m")
                    XCTAssertTrue(hi.y > 1.4 && hi.y < 2.0, "\(c.name) / \(clip.name) key \(key): head at \(hi.y) m")
                    XCTAssertTrue(simd_reduce_min(lo - c.boundsMin) >= 0 && simd_reduce_min(c.boundsMax - hi) >= 0,
                                  "\(c.name) / \(clip.name) key \(key) leaves the bounds")
                }
            }
        }
    }

    func testCacheFileRoundTrips() throws {
        let library = try library()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FBXTests-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        try CacheFile.write(library.encoded(), to: url)
        let read = try CharacterLibrary.read(url).characters
        XCTAssertEqual(read.count, library.characters.count)
        for (a, b) in zip(read, library.characters) {   // field by field: a failure names the field, not 50,000 vertices
            XCTAssertEqual(a.name, b.name)
            XCTAssertTrue(a.positions == b.positions, "positions")
            XCTAssertTrue(a.normals == b.normals, "normals")
            XCTAssertTrue(a.uvs == b.uvs, "uvs")
            XCTAssertTrue(a.indices == b.indices, "indices")
            XCTAssertTrue(a.skin == b.skin, "skin")
            XCTAssertTrue(a.joints == b.joints, "joints")
            XCTAssertTrue(a.coarser == b.coarser, "levels of detail")
            XCTAssertEqual(a.jointNames, b.jointNames)
            XCTAssertEqual(a.color, b.color)
            XCTAssertEqual(a.boundsMin, b.boundsMin)
            XCTAssertEqual(a.boundsMax, b.boundsMax)
            XCTAssertTrue(a.clips == b.clips, "clips")
        }
        // A cut-off cache file is refused.
        try library.encoded().prefix(100_000).write(to: url)
        XCTAssertThrowsError(try CharacterLibrary.read(url))
    }

    /// A clip file is read without its copy of the character's mesh.
    func testClipFilesSkipTheMesh() throws {
        _ = try library()
        let url = FBXTests.directory.appendingPathComponent("Animations/Walking.fbx")
        let clip = try FBXFile(url: url, contents: [.animation]), all = try FBXFile(url: url, contents: [.animation, .geometry, .skin])
        let objects = try XCTUnwrap(clip.top("Objects"))
        XCTAssertFalse(clip.children(objects).contains { clip.isNamed($0, "Geometry") || clip.isNamed($0, "Deformer") })
        XCTAssertTrue(all.children(try XCTUnwrap(all.top("Objects"))).contains { all.isNamed($0, "Geometry") })
        XCTAssertLessThan(clip.nodes.count, all.nodes.count)
    }

    /// Cut off or damaged files throw; they never read out of bounds.
    func testDamagedFilesThrow() throws {
        _ = try library()
        let source = try Data(contentsOf: FBXTests.directory.appendingPathComponent("Y Bot.fbx"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FBXTests-\(UUID().uuidString).fbx")
        defer { try? FileManager.default.removeItem(at: url) }
        for length in [10, 27, 300, 5_000, source.count / 2, source.count - 2_000] {
            try source.prefix(length).write(to: url)
            XCTAssertThrowsError(try CharacterImporter.character(url), "cut off at \(length) bytes")
        }
        try Data("not an FBX file, but long enough to have a header".utf8).write(to: url)
        XCTAssertThrowsError(try CharacterImporter.character(url))
        // Random damage: whatever happens, it is a thrown error or a character, not a crash.
        var rng = SplitMix64(seed: 0xFB_2026)
        for _ in 0..<40 {
            var damaged = source
            for _ in 0..<8 { damaged[27 + rng.int(source.count - 27)] = UInt8(truncatingIfNeeded: rng.nextUInt64()) }
            try damaged.write(to: url)
            _ = try? CharacterImporter.character(url)
        }
    }
}
