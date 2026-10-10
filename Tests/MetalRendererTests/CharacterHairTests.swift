import Metal
import QuartzCore
import XCTest
import simd
@testable import MetalRenderer

/// Hair (CharacterHair, CharacterHairCap): where it roots, that it stays off the head, that the brows and lashes ride
/// the face's expressions, the caps, and how quickly the workshop is made again with it. Skipped where
/// Assets/Characters isn't there.
final class CharacterHairTests: XCTestCase {
    private func kit() throws -> CharacterKit {
        guard let kit = CharacterKit.shared() else { throw XCTSkip("no characters in \(CharacterLibrary.directory.path)") }
        return kit
    }

    private func dna(_ style: String, beard: String = "none") -> CharacterDNA {
        var d = CharacterDNA()
        d.hair.style = style
        d.hair.beard = beard
        return d
    }

    /// Every style's scalp hair roots on the scalp (not the face, not the ears) and keeps off the head: its points
    /// outside the sculpt (but for the roots' first millimetre), the long styles' tips cut where the style says.
    func testScalpHairRootsOnTheScalpAndStaysOffTheHead() throws {
        let k = try kit()
        let c = k.base.character
        let sculpt = FaceSculpt(c)!
        for style in CharacterHair.styles where style.density > 0 {
            guard let g = CharacterHair.grooms(dna(style.id), kit: k, density: 0.3).first(where: { $0.kind == .scalp }) else {
                return XCTFail("\(style.id): no scalp hair")
            }
            XCTAssertGreaterThan(g.strandCount, 1000, style.id)
            XCTAssertTrue(g.followsHead)
            let points = CharacterHair.place(g, indices: c.indices, positions: c.positions, head: matrix_identity_float3x3, scale: 1)
            let n = g.perStrand
            var inside = 0, total = 0, lowest: Float = .infinity
            for s in 0..<g.strandCount {
                let root = sculpt.local(points[s * (n + 2) + 1])
                XCTAssertGreaterThan(CharacterHair.scalpDistance(root, recede: style.recede, crown: style.crown), -0.004, "\(style.id): a root off the scalp")
                for i in 2...n {
                    let q = sculpt.local(points[s * (n + 2) + i])
                    total += 1
                    if FaceSculpt.field(q) < -0.0005 { inside += 1 }
                    lowest = min(lowest, q.y)
                }
            }
            XCTAssertLessThan(Float(inside) / Float(total), 0.005, "\(style.id): points inside the head")
            if let cut = style.cut { XCTAssertGreaterThan(lowest, cut - 0.01, "\(style.id): cut") }
        }
    }

    /// The beard grows where a beard does, the brows over the eyes, the lashes on the lids' edges; all three ride their
    /// triangles, so a blink takes the upper lashes down with the lid.
    func testFaceHairFollowsTheFace() throws {
        let k = try kit()
        let c = k.base.character
        let sculpt = FaceSculpt(c)!
        let grooms = CharacterHair.grooms(dna("bald", beard: "full"), kit: k)
        let kinds = Set(grooms.map(\.kind))
        XCTAssertEqual(kinds, [.beard, .brows, .lashes], "a bald man with a beard: no scalp hair")
        for g in grooms {
            XCTAssertFalse(g.followsHead, "\(g.kind)")
            let points = CharacterHair.place(g, indices: c.indices, positions: c.positions, head: matrix_identity_float3x3, scale: 1)
            let roots = (0..<g.strandCount).map { sculpt.local(points[$0 * (g.perStrand + 2) + 1]) }
            switch g.kind {
            case .beard: XCTAssert(roots.allSatisfy { $0.y < 1.66 && $0.y > 1.5 && $0.z > -0.03 }, "the beard on the jaw and chin")
            case .brows: XCTAssert(roots.allSatisfy { abs($0.y - 1.705) < 0.012 && abs($0.x) > 0.01 }, "the brows over the eyes")
            case .lashes: XCTAssert(roots.allSatisfy { r in FaceSculpt.eyeCentres.contains { simd_distance(r, $0) < 0.02 } }, "the lashes round the eyes")
            case .scalp: XCTFail()
            }
        }
        // A blink: the upper lashes' tips go down with the lid.
        guard let upper = grooms.first(where: { $0.kind == .lashes }) else { return XCTFail() }
        let eyes = (0..<2).map { k.face.eye($0, in: c.positions).centre }
        var state = FacePlayer.state(at: 0, seed: 1, expression: .neutral, expressive: true, eyes: eyes, gaze: nil)
        for g in [FaceRig.Group.leftUpperLid, .rightUpperLid] { state.turns[g.rawValue - 1].axisAngle.w = FaceRig.blinkUpper }
        var p = c.positions, n = c.normals
        k.face.apply(state, scale: 1, source: nil, positions: &p, normals: &n)
        let open = CharacterHair.place(upper, indices: c.indices, positions: c.positions, head: matrix_identity_float3x3, scale: 1)
        let shut = CharacterHair.place(upper, indices: c.indices, positions: p, head: matrix_identity_float3x3, scale: 1)
        let tip = upper.perStrand
        let drop = (0..<upper.strandCount).map { open[$0 * (tip + 2) + tip].y - shut[$0 * (tip + 2) + tip].y }.sorted()
        XCTAssertGreaterThan(drop[drop.count / 2], 0.004, "the upper lashes come down with the lid")
    }

    /// A style's cap: closed enough to draw, over the scalp, larger for longer hair, with its levels of detail.
    func testCapsFollowTheStyle() throws {
        let k = try kit()
        let sculpt = FaceSculpt(k.base.character)!
        var heights: [String: Float] = [:]
        for style in ["buzz", "bob", "long", "curly", "sidePart", "short", "receding", "slicked"] {
            guard let cap = CharacterHairCap.cap(dna(style), kit: k) else { return XCTFail(style) }
            XCTAssertEqual(cap.levels.count, CharacterLibrary.coarserLevels + 1)
            let top = cap.levels[0]
            XCTAssertGreaterThan(top.indices.count / 3, 1000, style)
            XCTAssert(top.positions.allSatisfy { sculpt.local($0).y > 1.3 }, style)
            // Every level round the head: no vertex thrown off by the simplifier (a long triangle across the scene).
            for level in cap.levels {
                XCTAssert(level.positions.allSatisfy { simd_distance(sculpt.local($0), [0, 1.6, 0]) < 0.6 }, "\(style): a vertex off the head")
                var longest: Float = 0
                for t in 0..<(level.indices.count / 3) {
                    let p = (0..<3).map { level.positions[Int(level.indices[3 * t + $0])] }
                    longest = max(longest, max(simd_distance(p[0], p[1]), max(simd_distance(p[1], p[2]), simd_distance(p[0], p[2]))))
                }
                XCTAssertLessThan(longest, 0.45, "\(style): a triangle across the scene (long hair's coarse levels are 0.36 m)")
            }
            heights[style] = top.positions.map { sculpt.local($0).y }.max()! - top.positions.map { sculpt.local($0).y }.min()!
        }
        XCTAssertLessThan(heights["buzz"]!, heights["bob"]!)   // (the others: no vertex off)
        XCTAssertLessThan(heights["bob"]!, heights["long"]!)
        XCTAssertNil(CharacterHairCap.cap(dna("bald"), kit: k))
        // On a character: a cap of material `hair` on every level, its vertices on the head's bone.
        let c = CharacterBuilder.build(dna("bob"), kit: k, cap: true)
        XCTAssert(c.materials.contains(FaceParts.Material.hair.rawValue))
        for level in c.coarser {
            XCTAssertEqual(level.materials.count, level.triangleCount)
            XCTAssertEqual(level.source.count, level.positions.count)
            XCTAssert(level.materials.contains(FaceParts.Material.hair.rawValue))
        }
    }

    /// The workshop made again at an edit, with hair as strands and as caps, one character and everyone.
    func testRemakingWithHairIsQuick() throws {
        _ = try kit()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard device.supportsRaytracing else { throw XCTSkip("no Metal ray tracing") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for (name, change) in [("one, strands", { (w: inout CharacterSceneSettings) in w.hair = .strands }),
                               ("one, caps", { $0.hair = .caps }), ("one, none", { $0.hair = .none }),
                               ("everyone, strands", { $0.layout = .lineup; $0.hair = .strands })]
                as [(String, (inout CharacterSceneSettings) -> Void)] {
            var best = Double.infinity, sceneMs = 0.0
            for round in 0..<3 {
                var s = SceneSettings(kind: .characters)
                s.characterCatalog = "builtin"
                change(&s.characterWorkshop)
                if round > 0 { s.characterWorkshop.expression = round == 1 ? .smile : .neutral }   // (another scene, the same people)
                let start = CACurrentMediaTime()
                let scene = Scene(s)
                let built = CACurrentMediaTime()
                _ = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(api: .metal3, slots: 3))
                let total = (CACurrentMediaTime() - start) * 1000
                if round > 0, total < best { best = total; sceneMs = (built - start) * 1000 }   // (the first fills the caches)
            }
            print(String(format: "Character workshop %@: %.1f ms (scene %.1f, buffers %.1f)", name, best, sceneMs, best - sceneMs))
            XCTAssertLessThan(best, 2000, name)
        }
    }
}
