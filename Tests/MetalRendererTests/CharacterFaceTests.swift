import XCTest
import simd
@testable import MetalRenderer

/// The face (FaceSculpt, FaceParts, FaceRig, the face sliders): its parts, how its lids, eyes and jaw move, and what
/// its sliders touch. Skipped where Assets/Characters isn't there.
final class CharacterFaceTests: XCTestCase {
    private func kit() throws -> CharacterKit {
        guard let kit = CharacterKit.shared() else { throw XCTSkip("no characters in \(CharacterLibrary.directory.path)") }
        return kit
    }

    private func regions(_ k: CharacterKit) -> [CharacterBase.Region] { k.base.regions.map { CharacterBase.Region(rawValue: $0)! } }

    /// The base's face has its parts and every material: two eyeballs with their irises and pupils, both rows of
    /// teeth, a tongue, the lips, brows and the inside of the mouth.
    func testTheFaceHasItsParts() throws {
        let k = try kit()
        let r = regions(k)
        for part in [CharacterBase.Region.leftEye, .rightEye, .upperTeeth, .lowerTeeth, .tongue] {
            XCTAssertGreaterThan(r.filter { $0 == part }.count, 100, "\(part)")
        }
        let c = k.base.character
        XCTAssertEqual(c.materials.count, c.triangleCount)
        XCTAssertEqual(Set(c.materials), Set(FaceParts.Material.allCases.filter { $0 != .hair }.map(\.rawValue)), "every material but a cap's")
        for level in c.coarser { XCTAssertEqual(level.materials.count, level.triangleCount) }
        // The eyes where the sculpt has them, as big as it says.
        for e in 0..<2 {
            let (centre, scale) = k.face.eye(e, in: c.positions)
            XCTAssertLessThan(simd_distance(centre, FaceSculpt(c)!.eyes[e]), 1e-4)
            XCTAssertEqual(scale, 1, accuracy: 1e-3)
        }
    }

    /// A blink closes the lids over the eye, edge to edge, and no lid goes into the eyeball.
    func testABlinkClosesTheLidsWithoutTouchingTheEye() throws {
        let k = try kit()
        let c = k.base.character
        let eyes = (0..<2).map { k.face.eye($0, in: c.positions).centre }
        var state = FacePlayer.state(at: 0, seed: 1, expression: .neutral, expressive: true, eyes: eyes, gaze: nil)
        for g in [FaceRig.Group.leftUpperLid, .rightUpperLid] { state.turns[g.rawValue - 1].axisAngle.w = FaceRig.blinkUpper }
        for g in [FaceRig.Group.leftLowerLid, .rightLowerLid] { state.turns[g.rawValue - 1].axisAngle.w = FaceRig.blinkLower }
        var p = c.positions, n = c.normals
        k.face.apply(state, scale: 1, source: nil, positions: &p, normals: &n)
        let r = regions(k)
        for (e, centre) in eyes.enumerated() {
            let upper = (e == 0 ? FaceRig.Group.leftUpperLid : .rightUpperLid).rawValue, lower = upper + 1
            // The lids' edges (their vertices that turn all the way).
            let upperEdge = c.positions.indices.filter { k.face.groups[$0] == UInt32(upper) | 255 << 8 }
            let lowerEdge = c.positions.indices.filter { k.face.groups[$0] == UInt32(lower) | 255 << 8 }
            XCTAssertFalse(upperEdge.isEmpty)
            XCTAssertFalse(lowerEdge.isEmpty)
            let upperLowest = upperEdge.map { p[$0].y }.min()!, lowerHighest = lowerEdge.map { p[$0].y }.max()!
            print(String(format: "Blink, eye %d: upper lid's edge down to %.1f mm, lower's up to %.1f mm (from the eye's middle)", e,
                         (upperLowest - centre.y) * 1000, (lowerHighest - centre.y) * 1000))
            XCTAssertLessThan(upperLowest, lowerHighest + 0.0015, "the lids meet")
            // Nothing of the skin inside the eyeball.
            let closest = p.indices.filter { r[$0] != .leftEye && r[$0] != .rightEye }.map { simd_distance(p[$0], centre) }.min()!
            XCTAssertGreaterThan(closest, FaceSculpt.eyeRadius)
        }
    }

    /// The eyes turn toward what they look at (and no further than eyes turn).
    func testTheEyesFollowTheGaze() throws {
        let k = try kit()
        let c = k.base.character
        let eyes = (0..<2).map { k.face.eye($0, in: c.positions).centre }
        let target = eyes[0] + SIMD3(0.25, 0.12, 1)
        let state = FacePlayer.state(at: 0, seed: 1, expression: .neutral, expressive: true, eyes: eyes, gaze: target)
        var p = c.positions, n = c.normals
        k.face.apply(state, scale: 1, source: nil, positions: &p, normals: &n)
        for e in 0..<2 {
            let apex = p[Int(k.face.eyePoles[e].x)]
            let looking = simd_normalize(apex - eyes[e]), wanted = simd_normalize(target - eyes[e])
            XCTAssertGreaterThan(simd_dot(looking, wanted), 0.998, "eye \(e)")
        }
        let far = FacePlayer.state(at: 0, seed: 1, expression: .neutral, expressive: true, eyes: eyes, gaze: eyes[0] + SIMD3(1, 0, 0.05))
        XCTAssertLessThanOrEqual(far.turns[FaceRig.Group.leftEye.rawValue - 1].axisAngle.w, 0.61)
    }

    /// Opening the jaw parts the lips by a centimetre or more and takes the lower teeth and tongue with it; the upper
    /// teeth stay.
    func testTheJawOpensTheMouth() throws {
        let k = try kit()
        let c = k.base.character
        let r = regions(k)
        guard let jaw = FaceRig.targetNames.firstIndex(of: "jawOpen") else { return XCTFail() }
        var state = FaceState()
        state.weights[jaw] = 1
        var p = c.positions, n = c.normals
        k.face.apply(state, scale: 1, source: nil, positions: &p, normals: &n)
        let sculpt = FaceSculpt(c)!
        // The lips' middles: the skin straight ahead of the mouth just above and below its line.
        func middle(above: Bool) -> Int {
            c.positions.indices.filter { v in
                let q = sculpt.local(c.positions[v])
                return r[v] == .head && abs(q.x) < 0.003 && q.z > 0.095 && (above ? q.y > 1.6146 && q.y < 1.62 : q.y < 1.6144 && q.y > 1.608)
            }.max { c.positions[$0].z < c.positions[$1].z }!
        }
        let top = middle(above: true), bottom = middle(above: false)
        let before = c.positions[top].y - c.positions[bottom].y, after = p[top].y - p[bottom].y
        print(String(format: "Jaw open: the lips part from %.1f to %.1f mm", before * 1000, after * 1000))
        XCTAssertGreaterThan(after - before, 0.01)
        for v in c.positions.indices where r[v] == .upperTeeth { XCTAssertEqual(p[v], c.positions[v]) }
        let lowered = c.positions.indices.filter { r[$0] == .lowerTeeth }.map { c.positions[$0].y - p[$0].y }
        XCTAssertGreaterThan(lowered.min()!, 0.004)
    }

    /// Every expression moves only the face, both sides alike.
    func testExpressionsMoveOnlyTheFaceAndBothSides() throws {
        let k = try kit()
        let c = k.base.character
        let sculpt = FaceSculpt(c)!
        for t in k.face.targets {
            XCTAssertFalse(t.vertices.isEmpty, t.name)
            // (The most each side moves: the vertices aren't spread alike on both sides.)
            var left: Float = 0, right: Float = 0
            for (i, v) in t.vertices.enumerated() {
                let q = sculpt.local(c.positions[Int(v)])
                XCTAssertGreaterThan(q.y, 1.54, "\(t.name) moves no more than the head")
                let d = simd_length(t.deltas[i])
                if q.x > 0.002 { left = max(left, d) } else if q.x < -0.002 { right = max(right, d) }
            }
            XCTAssertEqual(left, right, accuracy: 0.1 * max(left, right), t.name)
        }
    }

    /// A face slider changes the head and nothing else; the eyeballs move whole with it.
    func testFaceSlidersShapeOnlyTheHead() throws {
        let k = try kit()
        let r = regions(k)
        let plain = CharacterBuilder.build(BuiltInCharacters.all[0], kit: k)
        for s in CharacterMorphs.faceSliders {
            var d = BuiltInCharacters.all[0]
            d.morphs[s.name] = 1
            let shaped = CharacterBuilder.build(d, kit: k)
            var most: Float = 0
            for v in plain.positions.indices {
                let moved = simd_distance(plain.positions[v], shaped.positions[v])
                most = max(most, moved)
                if moved > 1e-5 { XCTAssertGreaterThan(plain.positions[v].y, 1.5, "\(s.name) moves vertex \(v)") }
            }
            XCTAssertGreaterThan(most, 0.001, s.name)
            // The eyeballs: each vertex moved alike.
            for eye in [CharacterBase.Region.leftEye, .rightEye] {
                let moves = plain.positions.indices.filter { r[$0] == eye }.map { shaped.positions[$0] - plain.positions[$0] }
                let spread = moves.map { simd_distance($0, moves[0]) }.max()!
                XCTAssertLessThan(spread, 2e-4, "\(s.name): \(eye) keeps its shape")
            }
        }
    }

    /// Blinks come every few seconds, are short, and leave the eyes open at time 0.
    func testBlinksAreShortAndSeeded() {
        XCTAssertEqual(FacePlayer.blink(0, seed: 7), 0)
        var closed = 0, blinks = 0, wasClosed = false
        for frame in 0..<(60 * 120) {
            let b = FacePlayer.blink(Float(frame) / 60, seed: 7)
            if b > 0.5 { closed += 1; if !wasClosed { blinks += 1 } }
            wasClosed = b > 0.5
        }
        XCTAssertGreaterThan(blinks, 20)
        XCTAssertLessThan(blinks, 40)
        XCTAssertLessThan(Float(closed) / Float(60 * 120), 0.03, "eyes are shut a small share of the time")
        XCTAssertNotEqual((0..<600).map { FacePlayer.blink(Float($0) / 60, seed: 7) }, (0..<600).map { FacePlayer.blink(Float($0) / 60, seed: 8) })
    }
}
