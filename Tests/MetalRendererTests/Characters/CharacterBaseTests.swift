import XCTest
import Metal
import QuartzCore
import simd
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import MetalRenderer
@testable import Physics
@testable import Plants

/// The base body (CharacterBase), its morphs (CharacterMorphs) and characters made from DNA (CharacterBuilder).
/// Skipped where Assets/Characters isn't there.
final class CharacterBaseTests: XCTestCase {
    private func kit() throws -> CharacterKit {
        guard let kit = CharacterKit.shared() else { throw XCTSkip("no characters in \(CharacterLibrary.directory.path)") }
        return kit
    }

    /// Closed surfaces: the skin, and the eyeballs, teeth and tongue (welded by position: a vertex where two materials
    /// meet is one for each).
    func testTheBaseIsOneClosedSurface() throws {
        let c = try kit().base.character
        var welded: [SIMD3<Float>: UInt64] = [:]
        let id = c.positions.map { p -> UInt64 in
            if let w = welded[p] { return w }
            welded[p] = UInt64(welded.count)
            return UInt64(welded.count - 1)
        }
        var edges: [UInt64: Int] = [:]
        for t in stride(from: 0, to: c.indices.count, by: 3) {
            for k in 0..<3 {
                let a = id[Int(c.indices[t + k])], b = id[Int(c.indices[t + (k + 1) % 3])]
                edges[min(a, b) << 32 | max(a, b), default: 0] += 1
            }
        }
        let border = edges.values.filter { $0 == 1 }.count, crowded = edges.values.filter { $0 > 2 }.count
        for (e, n) in edges where n != 2 { print("Character base edge of \(n) triangles at \(c.positions[id.firstIndex(of: e >> 32)!])") }
        XCTAssertEqual(border, 0, "no edge with a triangle on one side only")
        // (Surface nets pinch two sheets together where a feature is thinner than a cell: the bottom of an ear's bowl.)
        XCTAssertLessThanOrEqual(crowded, 4, "no edge between more than two triangles, but for a pinch at each ear")
        XCTAssertGreaterThan(c.triangleCount, 40_000)
    }

    /// Where the body is sewn to the head round the neck, no vertex faces against its neighbours (a fold, dark in the
    /// light).
    func testTheNecksSeamHasNoFolds() throws {
        let base = try kit().base, c = base.character
        let ring = CharacterBase.neighbours(c.positions.count, c.indices)
        var folded: [SIMD3<Float>] = []
        for v in c.positions.indices where base.regions[v] < CharacterBase.Region.leftEye.rawValue {
            let p = c.positions[v]
            guard (1.50...1.60).contains(p.y), simd_length(SIMD2(p.x, p.z + 0.02)) < 0.1 else { continue }
            let around = ring[v].reduce(SIMD3<Float>()) { $0 + c.normals[Int($1)] }
            if simd_length(around) > 0 && simd_dot(simd_normalize(around), c.normals[v]) < 0.5 { folded.append(p) }
        }
        XCTAssertEqual(folded.count, 0, "folds at \(folded.prefix(8))")
    }

    func testWeightsAreWholeOnFourJoints() throws {
        let c = try kit().base.character
        for s in c.skin {
            XCTAssertGreaterThanOrEqual(s.w0, s.w1)
            XCTAssertGreaterThanOrEqual(1 - s.w0 - s.w1 - s.w2, -1e-4)
            XCTAssertLessThan(Int(s.joints & 0xFF), c.joints.count)
        }
    }

    /// The share of edges (99.9%) whose length any key of any clip keeps within `ratio` of the bind pose's, and where
    /// the worst are: a measure of how well the skin's weights follow its bones.
    private func stretch(_ c: SkinnedCharacter) -> (p999: Float, worst: String) {
        func lengths(_ p: [SIMD3<Float>]) -> [Float] {
            stride(from: 0, to: c.indices.count, by: 3).flatMap { t in
                (0..<3).map { simd_distance(p[Int(c.indices[t + $0])], p[Int(c.indices[t + ($0 + 1) % 3])]) }
            }
        }
        let rest = lengths(c.positions)
        var ratios: [Float] = []
        var byJoint: [String: Int] = [:]
        for (i, clip) in c.clips.enumerated() {
            for key in stride(from: 0, to: clip.loopKeys, by: max(clip.loopKeys / 6, 1)) {
                let posed = lengths(c.skin(c.palette(clipA: i, timeA: Float(key))).positions)
                for e in rest.indices where rest[e] > 1e-4 {
                    let r = max(posed[e] / rest[e], rest[e] / max(posed[e], 1e-6))
                    ratios.append(r)
                    if r > 3 { byJoint[c.jointNames[Int(c.skin[Int(c.indices[e / 3 * 3 + e % 3])].joints & 0xFF)], default: 0] += 1 }
                }
            }
        }
        ratios.sort()
        return (ratios[ratios.count * 999 / 1000], "\(byJoint.sorted { $0.value > $1.value }.prefix(6))")
    }

    /// Posed by every clip, almost no edge of the skin grows or shrinks more than four times (the Y Bot's panels, each on
    /// one bone, stretch less; a skin in one piece folds at the groin and the armpits).
    func testTheSkinStretchesNoMoreThanTheYBots() throws {
        let k = try kit()
        guard let ybot = CharacterLibrary.load().characters.first(where: { $0.name == "Y Bot" }) else { throw XCTSkip("no Y Bot") }
        let mine = stretch(CharacterBuilder.build(BuiltInCharacters.all[0], kit: k)), theirs = stretch(ybot)
        print("Character skin stretch: 99.9% under \(mine.p999) (the Y Bot's \(theirs.p999)); over 3x by joint: \(mine.worst)")
        XCTAssertLessThan(mine.p999, 4)
    }

    func testTargetsAreSymmetric() throws {
        let k = try kit()
        let c = k.base.character
        // Each vertex's mirror: the nearest to its reflection that faces the reflected way (not the other lip across
        // the mouth's parting, or the far wall of a fold).
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (v, p) in c.positions.enumerated() { grid[SIMD3<Int32>((p / 0.02).rounded(.down)), default: []].append(v) }
        func mirror(_ v0: Int) -> Int {
            let p = c.positions[v0], n = c.normals[v0]
            let q = SIMD3(-p.x, p.y, p.z), facing = SIMD3(-n.x, n.y, n.z), cell = SIMD3<Int32>((q / 0.02).rounded(.down))
            var best = (d: Float.infinity, v: 0), nearest = (d: Float.infinity, v: 0)
            for z in -1...1 { for y in -1...1 { for x in -1...1 {
                for v in grid[cell &+ SIMD3(Int32(x), Int32(y), Int32(z))] ?? [] {
                    let d = simd_distance(c.positions[v], q)
                    if d < nearest.d { nearest = (d, v) }
                    if d < best.d && simd_dot(c.normals[v], facing) > 0.3 { best = (d, v) }
                }
            } } }
            return best.d < 0.004 ? best.v : nearest.v
        }
        for t in k.morphs.targets where t.name != "sex" {
            var dense = [SIMD3<Float>](repeating: .zero, count: c.positions.count)
            for (v, d) in zip(t.vertices, t.deltas) { dense[Int(v)] = d }
            var error: Float = 0, size: Float = 0
            for v in stride(from: 0, to: c.positions.count, by: 7) {
                let m = dense[mirror(v)]
                error = max(error, simd_distance(dense[v], SIMD3(-m.x, m.y, m.z)))
                size = max(size, simd_length(dense[v]))
            }
            // (The mesh isn't exactly symmetric: a vertex's mirror is the nearest one to its reflection, up to a cm away.)
            if t.name == "neckThickness" { print("Target neckThickness: asymmetry \(error / (size * 0.45 + 0.001)) of its bound") }
            XCTAssertLessThan(error, size * 0.45 + 0.001, "\(t.name): the left side's deltas mirror the right's")
            if error >= size * 0.45 + 0.001 { print("Asymmetric target \(t.name): \(error) against \(size)") }
        }
    }

    /// The neck's weights mirror (the Y Bot's do): where its neck's panel overlaps the chest's and the head's, and over
    /// the seam to the finer head, the left side of the neck moves with its bones as the right does.
    func testTheNecksWeightsAreSymmetric() throws {
        let base = try kit().base, c = base.character
        let names = c.jointNames.map { $0.replacingOccurrences(of: "mixamorig:", with: "") }
        let joints = ["Spine2", "Neck", "Head"].compactMap { names.firstIndex(of: $0) }
        XCTAssertEqual(joints.count, 3)
        func weights(_ v: Int) -> [Float] {
            let s = c.skin[v], ws = [s.w0, s.w1, s.w2, 1 - s.w0 - s.w1 - s.w2]
            return joints.map { j in (0..<4).reduce(0) { Int((s.joints >> UInt32(8 * $1)) & 0xFF) == j ? $0 + ws[$1] : $0 } }
        }
        let skin = (0..<c.skin.count).filter { base.regions[$0] < CharacterBase.Region.leftEye.rawValue }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for v in skin { grid[SIMD3<Int32>((c.positions[v] / 0.02).rounded(.down)), default: []].append(v) }
        // Pairs: a vertex and the nearest to its reflection (within 4 mm) that faces the reflected way.
        var differences: [Float] = []
        for v in skin where (1.45...1.65).contains(c.positions[v].y) && c.positions[v].x > 0.002 {
            let p = c.positions[v], n = c.normals[v]
            let q = SIMD3(-p.x, p.y, p.z), facing = SIMD3(-n.x, n.y, n.z), cell = SIMD3<Int32>((q / 0.02).rounded(.down))
            var best = (d: Float(0.004), v: -1)
            for z in -1...1 { for y in -1...1 { for x in -1...1 {
                for u in grid[cell &+ SIMD3(Int32(x), Int32(y), Int32(z))] ?? [] {
                    let d = simd_distance(c.positions[u], q)
                    if d < best.d && simd_dot(c.normals[u], facing) > 0.3 { best = (d, u) }
                }
            } } }
            guard best.v >= 0 else { continue }
            let a = weights(v), b = weights(best.v)
            differences.append(zip(a, b).map { abs($0 - $1) }.max()!)
        }
        differences.sort()
        let worst = differences.last ?? 0, p99 = differences[differences.count * 99 / 100]
        print("Character neck weights: \(differences.count) mirror pairs, 99% within \(p99), worst \(worst)")
        XCTAssertGreaterThan(differences.count, 1000)
        // (A pair's vertices are up to 4 mm apart: where the jaw goes over to the head's bone the weights change by
        // about 0.03 a mm.)
        XCTAssertLessThan(p99, 0.05)
        XCTAssertLessThan(worst, 0.15)
    }

    func testHeightFollowsItsSlider() throws {
        let k = try kit()
        func height(_ h: Float, sex: Float = 0) -> Float {
            var d = CharacterDNA()
            d.macro.height = h
            d.macro.sex = sex
            let c = CharacterBuilder.build(d, kit: k)
            return c.positions.map(\.y).max()! - c.positions.map(\.y).min()!
        }
        let short = height(-1), average = height(0), tall = height(1)
        XCTAssertLessThan(short, average - 0.1)
        XCTAssertGreaterThan(tall, average + 0.1)
        XCTAssertLessThan(height(0, sex: 1), average, "the X Bot's skeleton is shorter")
        XCTAssertEqual(average, 1.8, accuracy: 0.08)
    }

    func testBuildingIsRepeatable() throws {
        let k = try kit()
        var d = BuiltInCharacters.all[3]
        d.morphs["chest"] = 0.3
        XCTAssertEqual(CharacterBuilder.build(d, kit: k), CharacterBuilder.build(d, kit: k))
    }

    func testTheCacheRoundTrips() throws {
        let k = try kit()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        try CharacterKit.encoded(k.base, k.morphs, k.face).write(to: url)
        let (base, morphs, face) = try CharacterKit.read(url)
        XCTAssertEqual(base.character.positions, k.base.character.positions)
        XCTAssertEqual(base.character.skin, k.base.character.skin)
        XCTAssertEqual(base.regions, k.base.regions)
        XCTAssertEqual(base.materials, k.base.materials)
        XCTAssertEqual(base.character.materials, k.base.character.materials)
        XCTAssertEqual(base.character.coarser.map(\.source), k.base.character.coarser.map(\.source))
        XCTAssertEqual(base.character.coarser.map(\.materials), k.base.character.coarser.map(\.materials))
        XCTAssertEqual(morphs.targets.map(\.name), k.morphs.targets.map(\.name))
        XCTAssertEqual(morphs.targets.map(\.deltas), k.morphs.targets.map(\.deltas))
        XCTAssertEqual(face.targets, k.face.targets)
        XCTAssertEqual(face.groups, k.face.groups)
        XCTAssertEqual(face.eyePoles, k.face.eyePoles)
    }

    /// The workshop is made again at every edit: how long a character takes, its scene and its GPU buffers.
    func testRemakingTheWorkshopIsQuick() throws {
        _ = try kit()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard device.supportsRaytracing else { throw XCTSkip("no Metal ray tracing") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for layout in [CharacterSceneSettings.Layout.single, .lineup] {
            var best = Double.infinity, sceneMs = 0.0
            for _ in 0..<3 {
                var s = SceneSettings(kind: .characters)
                s.characterCatalog = "builtin"
                s.characterWorkshop.layout = layout
                let start = CACurrentMediaTime()
                let scene = Scene(s)
                let made = CACurrentMediaTime()
                _ = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(api: .metal3, slots: 3))
                let total = (CACurrentMediaTime() - start) * 1000
                if total < best { best = total; sceneMs = (made - start) * 1000 }
            }
            print(String(format: "Character workshop %@: %.1f ms (scene %.1f, buffers %.1f)", layout.title, best, sceneMs, best - sceneMs))
            XCTAssertLessThan(best, 2000)
        }
    }

    func testTheWorkshopShowsItsCharacters() throws {
        _ = try kit()
        var s = SceneSettings(kind: .characters)
        s.characterCatalog = "builtin"
        s.characterWorkshop.layout = .lineup
        let scene = Scene(s)
        XCTAssertEqual(scene.crowd?.slots.count, BuiltInCharacters.all.count)
        XCTAssertNotNil(scene.characterStats)
        XCTAssertNotNil(scene.focus)
    }
}
