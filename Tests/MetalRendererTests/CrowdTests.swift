import XCTest
import simd
@testable import MetalRenderer

/// The crowd's description and clock (Crowd.swift) and the scene built around it (Scene+Crowd.swift). The GPU's
/// skinning and refits are checked in a run: `METALRENDERER_BENCH=crowd METALRENDERER_CROWD_CHECK=1`.
/// Skipped where Assets/Characters isn't there.
final class CrowdTests: XCTestCase {
    private static let library = CharacterLibrary.load(cache: false)

    private func characters() throws -> [SkinnedCharacter] {
        guard !CrowdTests.library.characters.isEmpty else { throw XCTSkip("no characters in \(CharacterLibrary.directory.path)") }
        return CrowdTests.library.characters
    }

    func testLevelsOfDetail() throws {
        for c in try characters() {
            XCTAssertEqual(c.coarser.count, CharacterLibrary.coarserLevels)
            let full = Set(c.positions)
            var triangles = c.triangleCount
            for level in c.coarser {
                XCTAssertLessThan(level.triangleCount, triangles * 6 / 10, "\(c.name): a level has about half the triangles of the one before")
                triangles = level.triangleCount
                XCTAssertEqual(level.skin.count, level.positions.count)
                XCTAssertEqual(level.normals.count, level.positions.count)
                XCTAssertTrue(level.indices.allSatisfy { Int($0) < level.positions.count })
                XCTAssertTrue(level.positions.allSatisfy(full.contains), "\(c.name): a level's vertices are some of the full mesh's")
            }
            XCTAssertEqual(c.level(0).triangleCount, c.triangleCount)
            XCTAssertEqual(c.level(99).triangleCount, c.coarser.last?.triangleCount)
        }
    }

    func testSlotsAreDealtOverTheMotions() throws {
        let characters = try characters()
        for poses in [1, 7, 64] {
            let crowd = Crowd(characters: characters, poses: poses, level: 3)
            XCTAssertEqual(crowd.slots.count, poses)
            XCTAssertEqual(crowd.parts.reduce(0) { $0 + $1.slotCount }, poses)
            for (p, part) in crowd.parts.enumerated() {
                for i in part.firstSlot..<(part.firstSlot + part.slotCount) { XCTAssertEqual(crowd.slots[i].part, p, "a part's slots are consecutive") }
            }
            XCTAssertEqual(Set(crowd.liveStates.flatMap { crowd.states[$0].slots }).count, poses)
        }
        // Enough slots: every clip of every character plays, and the two that travel are cross-faded.
        let crowd = Crowd(characters: characters, poses: 64)
        XCTAssertEqual(crowd.liveStates.count, characters.count * (characters[0].clips.count + 1))
        XCTAssertEqual(crowd.states.filter { $0.motion.isBlend }.count, characters.count)
    }

    func testPosesStayInsideTheirLoops() throws {
        let characters = try characters()
        let crowd = Crowd(characters: characters, poses: 40)
        var blended = false
        for t in stride(from: Float(0), through: 600, by: 0.37) {
            crowd.pose(at: t)
            for slot in crowd.slots {
                let state = crowd.states[slot.state], c = characters[state.character]
                XCTAssertTrue(slot.record.timeA >= 0 && slot.record.timeA < Float(c.clips[state.motion.clipA].loopKeys))
                XCTAssertTrue(slot.record.timeB >= 0 && slot.record.timeB < Float(c.clips[state.motion.clipB].loopKeys))
                XCTAssertTrue(slot.record.blend >= 0 && slot.record.blend <= 1)
                XCTAssertGreaterThanOrEqual(slot.distance, slot.previousDistance - 1e-6, "nobody walks backwards")
                blended = blended || slot.record.blend > 0.5
            }
        }
        XCTAssertTrue(blended)
        // The same time twice: nothing moved in between.
        crowd.pose(at: 600)
        crowd.pose(at: 600)
        for slot in crowd.slots { XCTAssertEqual(slot.distance, slot.previousDistance) }
    }

    /// The scene: every member is an instance of a pose slot's mesh, walkers move at their clip's speed, their
    /// matrices stay consistent, and a walker that wraps around its lane doesn't seem to have crossed the scene.
    func testCrowdScene() throws {
        _ = try characters()
        let scene = Scene(SceneSettings(kind: .crowd, characters: 300, poses: 24, detail: 4))
        let crowd = try XCTUnwrap(scene.crowd)
        XCTAssertEqual(crowd.memberCount, 300)
        let members = scene.instances.filter(\.deforms)
        XCTAssertEqual(members.count, 300)
        let poseMeshes = Set(crowd.slots.map(\.mesh))
        for inst in members {
            XCTAssertFalse(inst.isStatic)
            XCTAssertTrue(poseMeshes.contains(inst.mesh))
        }
        for slot in crowd.slots {
            let mesh = scene.meshes[slot.mesh], range = crowd.vertexRange(slot: crowd.slots.firstIndex { $0.mesh == slot.mesh }!)
            XCTAssertNotEqual(mesh.prevOffset, 0)
            XCTAssertEqual(Int(mesh.vertexOffset), range.current - crowd.parts[slot.part].bindVertex)
            XCTAssertEqual(Int(mesh.prevOffset), range.previous - range.current)
            XCTAssertLessThanOrEqual(range.previous + range.count, scene.positions.count)
            XCTAssertLessThanOrEqual(range.current + range.count, scene.normals.count)
        }
        // Other meshes are untouched by the offsets.
        for (m, mesh) in scene.meshes.enumerated() where !poseMeshes.contains(m) {
            XCTAssertEqual(mesh.vertexOffset, 0)
            XCTAssertEqual(mesh.prevOffset, 0)
        }

        let dt: Float = 1 / 60
        var wrapped = 0
        for frame in 1...900 {
            scene.update(time: Float(frame) * dt)
            for w in crowd.walkers {
                let inst = scene.instances[w.instance]
                let p = inst.transform.columns.3, q = inst.prevTransform.columns.3
                let step = simd_distance(p, q), slot = crowd.slots[w.slot]
                XCTAssertEqual(step, w.scale * Float(slot.distance - slot.previousDistance), accuracy: 1e-3)
                XCTAssertLessThan(step, 0.2, "a frame's step, not a jump across the lane")
                if frame % 300 == 0 {
                    let expected = inst.transform.inverse.transpose
                    for c in 0..<4 { XCTAssertLessThan(simd_reduce_max(simd_abs(inst.normalMatrix[c] - expected[c])), 2e-3) }
                }
            }
            if frame > 1, let w = crowd.walkers.first {
                // (its position along the lane dropped: it wrapped)
                let now = simd_dot(SIMD3(scene.instances[w.instance].transform.columns.3.x, 0, 0), w.forward)
                let before = simd_dot(SIMD3(scene.instances[w.instance].prevTransform.columns.3.x, 0, 0), w.forward)
                if now < before - 1 { wrapped += 1 }
            }
        }
        XCTAssertEqual(wrapped, 0, "the previous position is taken back along the lane, never from the far end")
    }
}
