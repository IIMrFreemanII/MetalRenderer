import Foundation
import simd

/// What a character's DNA asks of the base body: each morph target's weight, and each joint's reshaping (how its
/// children's offsets and the skin round it scale). The macro sliders drive many of both at once, in the manner of
/// MakeHuman's macros; the DNA's own morph and bone offsets go on top.
struct CharacterShape {
    var weights: [String: Float] = [:]
    /// Per joint, in the bind pose's (world) space: what the offsets of its children, and the skin it moves, are
    /// multiplied by.
    var scales: [simd_float3x3]
    /// How far toward the X Bot's skeleton (0...1).
    var sex: Float = 0
}

enum MacroRig {
    /// The bone groups the DNA's `bones` offsets lengthen, each with how far an offset of 1 goes and whether it scales
    /// a whole part (a head, the hands, the feet) or its bones' length.
    static let boneGroups: [(name: String, title: String, joints: [String], range: Float, uniform: Bool)] = [
        ("legs", "Legs", ["LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg"], 0.12, false),
        ("torso", "Torso", ["Spine", "Spine1", "Spine2"], 0.12, false),
        ("arms", "Arms", ["LeftArm", "LeftForeArm", "RightArm", "RightForeArm"], 0.12, false),
        ("shoulders", "Shoulder width", ["LeftShoulder", "RightShoulder"], 0.2, false),
        ("hipWidth", "Hip width", ["Hips"], 0.15, false),
        ("neck", "Neck length", ["Neck"], 0.3, false),
        ("head", "Head size", ["Head"], 0.1, true),
        ("hands", "Hand size", ["LeftHand", "RightHand"], 0.12, true),
        ("feet", "Foot size", ["LeftFoot", "RightFoot"], 0.12, true),
    ]

    static func shape(_ dna: CharacterDNA, character c: SkinnedCharacter) -> CharacterShape {
        let m = dna.macro
        var s = CharacterShape(scales: [simd_float3x3](repeating: matrix_identity_float3x3, count: c.joints.count))
        s.sex = m.sex
        var w: [String: Float] = ["sex": m.sex]
        if m.weight > 0 {
            w["fatMale"] = (1 - m.sex) * m.weight
            w["fatFemale"] = m.sex * m.weight
        } else {
            w["thin"] = -m.weight
        }
        let aged = min(max((m.age - 35) / 45, 0), 1)
        w["age"] = aged
        if m.muscle > 0 { w["muscle"] = m.muscle * (1 - 0.4 * m.sex) * (1 - 0.5 * aged) } else { w["slight"] = -m.muscle }
        w["slight", default: 0] += 0.4 * aged
        for (name, value) in dna.morphs { w[name, default: 0] += value }
        s.weights = w

        // Bones: along and across each joint's bone (to its first child), or the whole part alike.
        let bind = CharacterBase.bindPositions(c)
        let names = c.jointNames.map { $0.replacingOccurrences(of: "mixamorig:", with: "") }
        var firstChild = [Int](repeating: -1, count: c.joints.count)
        for (j, joint) in c.joints.enumerated().reversed() where joint.parent >= 0 { firstChild[joint.parent] = j }
        // Height: the bones' lengths, the skin across them less; parts (head, hands, feet) in between.
        let shrink: Float = m.age > 60 ? 1 - 0.03 * (m.age - 60) / 30 : 1
        // (A woman 7% shorter than a man: the X Bot's skeleton isn't.)
        let height = (1 + 0.1 * m.height) * (1 - 0.07 * m.sex) * shrink
        var along = [Float](repeating: height, count: c.joints.count)
        let across = [Float](repeating: height.squareRoot(), count: c.joints.count)
        var uniform = [Float?](repeating: nil, count: c.joints.count)
        func joints(_ group: [String]) -> [Int] { group.compactMap { names.firstIndex(of: $0) } }
        let p = m.proportions
        for j in joints(["LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg"]) { along[j] *= 1 + 0.06 * p }
        for j in joints(["LeftArm", "LeftForeArm", "RightArm", "RightForeArm"]) { along[j] *= 1 + 0.05 * p }
        for j in joints(["Spine", "Spine1", "Spine2"]) { along[j] *= 1 - 0.05 * p }
        for j in joints(["Neck"]) { along[j] *= 1 + 0.08 * p }
        var hipWidth: Float = 1
        for g in boneGroups {
            let f = 1 + g.range * dna.bone(g.name)
            for j in joints(g.joints) {
                if g.name == "hipWidth" { hipWidth = f } else if g.uniform { uniform[j] = f } else { along[j] *= f }
            }
        }
        // A part scaled whole: every joint below the part's own too.
        var partScale = [Float?](repeating: nil, count: c.joints.count)
        for (j, joint) in c.joints.enumerated() {
            if let u = uniform[j] { partScale[j] = u * height.squareRoot() * pow(height, 0.2) }
            else if joint.parent >= 0, let up = partScale[joint.parent] { partScale[j] = up }
        }
        for j in c.joints.indices {
            if let u = partScale[j] {
                s.scales[j] = simd_float3x3(diagonal: SIMD3(repeating: u))
            } else if names[j] == "Hips" {
                s.scales[j] = simd_float3x3(diagonal: SIMD3(hipWidth * across[j], along[j], across[j]))
            } else if firstChild[j] >= 0 {
                let a = simd_normalize(bind[firstChild[j]] - bind[j])
                let aa = simd_float3x3(columns: (a * a.x, a * a.y, a * a.z))
                s.scales[j] = simd_float3x3(diagonal: SIMD3(repeating: across[j])) + aa * (along[j] - across[j])
            } else {
                s.scales[j] = simd_float3x3(diagonal: SIMD3(repeating: along[j]))
            }
        }
        // Parts scaled whole start at their joint: the head's joint itself doesn't move off its neck.
        return s
    }
}

/// Makes a character from its DNA: the base body plus its weighted morphs, its skeleton reshaped (bones lengthened,
/// moved toward the X Bot's), the skin carried by the joints it hangs on, normals made again, and the clips with their
/// root's travel scaled to the new hips.
enum CharacterBuilder {
    /// The new bind positions of every joint for `shape`.
    static func bind(_ shape: CharacterShape, base c: SkinnedCharacter, morphs: CharacterMorphs) -> [SIMD3<Float>] {
        let old = CharacterBase.bindPositions(c)
        var out = old
        for (j, joint) in c.joints.enumerated() where joint.parent >= 0 {
            let p = joint.parent
            let offset = old[j] - old[p] + morphs.sexOffsets[j] * shape.sex
            out[j] = out[p] + shape.scales[p] * offset
        }
        return out
    }

    /// The mesh for `shape`: positions and normals (and each level of detail's, gathered from them).
    static func mesh(_ shape: CharacterShape, base c: SkinnedCharacter, morphs: CharacterMorphs, bind newBind: [SIMD3<Float>])
        -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        var p = c.positions
        for t in morphs.targets {
            guard let w = shape.weights[t.name], w != 0 else { continue }
            for (v, d) in zip(t.vertices, t.deltas) { p[Int(v)] += d * w }
        }
        let old = CharacterBase.bindPositions(c)
        p.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: (out.count + 4095) / 4096) { chunk in
                for v in (chunk * 4096)..<min(out.count, chunk * 4096 + 4096) {
                    let s = c.skin[v], p = out[v]
                    let ws = (s.w0, s.w1, s.w2, 1 - s.w0 - s.w1 - s.w2)
                    func moved(_ k: Int, _ w: Float) -> SIMD3<Float> {
                        let j = Int((s.joints >> UInt32(8 * k)) & 0xFF)
                        return (newBind[j] + shape.scales[j] * (p - old[j])) * w
                    }
                    var q = moved(0, ws.0)
                    if ws.1 != 0 { q += moved(1, ws.1) }
                    if ws.2 != 0 { q += moved(2, ws.2) }
                    if ws.3 != 0 { q += moved(3, ws.3) }
                    out[v] = q
                }
            }
        }
        return (p, CharacterBase.vertexNormals(p, c.indices))
    }

    /// The character `dna` describes, made from `kit`'s base, with `kit`'s clips.
    static func build(_ dna: CharacterDNA, kit: CharacterKit) -> SkinnedCharacter {
        let base = kit.base.character
        let shape = MacroRig.shape(dna, character: base)
        let newBind = bind(shape, base: base, morphs: kit.morphs)
        let (positions, normals) = mesh(shape, base: base, morphs: kit.morphs, bind: newBind)
        var c = base
        c.name = dna.name
        c.positions = positions
        c.normals = normals
        c.coarser = base.coarser.map { level in
            var l = level
            l.positions = level.source.map { positions[Int($0)] }
            l.normals = level.source.map { normals[Int($0)] }
            return l
        }
        c.joints = joints(base, bind: newBind)
        // The clips: the root's translation (the hips' height and sway) and travel scaled by the new hips' height.
        let hips = c.joints.firstIndex { $0.parent < 0 } ?? 0
        let old = CharacterBase.bindPositions(base)
        let ratio = old[hips].y > 1e-3 ? newBind[hips].y / old[hips].y : 1
        c.clips = kit.clips.map { clip in
            var k = clip
            k.root = clip.root.map { $0 * ratio }
            k.velocity = clip.velocity * ratio
            return k
        }
        c.color = CharacterBuilder.skinColor(dna.look)
        (c.boundsMin, c.boundsMax) = CharacterImporter.bounds(of: c)
        return c
    }

    /// `base`'s joints with their bind positions at `bind` (rotations unchanged): local offsets and inverse binds.
    static func joints(_ base: SkinnedCharacter, bind: [SIMD3<Float>]) -> [GPUJoint] {
        let poses = base.bindPoses
        return base.joints.enumerated().map { j, joint in
            var out = joint
            let local: SIMD3<Float>
            if joint.parent < 0 {
                local = bind[j]
            } else {
                local = poses[joint.parent].q.inverse.act(bind[j] - bind[joint.parent])
            }
            out.local = SIMD4(local, joint.local.w)
            let ib = simd_quatf(vector: joint.inverseBindRotation)
            out.inverseBindTranslation = SIMD4(-ib.act(bind[j]), 0)
            return out
        }
    }

    /// The skin's diffuse colour: a mix of a pale and a dark skin by melanin, made redder by `redness` (linear RGB).
    static func skinColor(_ look: CharacterDNA.Look) -> SIMD3<Float> {
        let pale = SIMD3<Float>(0.82, 0.6, 0.5), dark = SIMD3<Float>(0.13, 0.065, 0.04)
        let m = look.melanin
        var c = pale * pow(dark / pale, SIMD3(repeating: m))
        c *= SIMD3(1 + 0.12 * (look.redness - 0.35), 1 - 0.08 * (look.redness - 0.35), 1 - 0.1 * (look.redness - 0.35))
        return simd_clamp(c, SIMD3(repeating: 0.01), SIMD3(repeating: 0.95))
    }
}

/// The parts every generated character is made from: the base body, its morph targets, and the clips (the Y Bot's,
/// with a T pose and an A pose). Made once from the character library (built, or read from a cache file next to
/// the library's) and shared.
final class CharacterKit {
    let base: CharacterBase
    let morphs: CharacterMorphs
    let clips: [SkinnedCharacter.Clip]

    init(base: CharacterBase, morphs: CharacterMorphs, clips: [SkinnedCharacter.Clip]) {
        self.base = base
        self.morphs = morphs
        self.clips = clips
    }

    private static let lock = NSLock()
    private static var cached: CharacterKit??

    /// The shared kit (nil if the library has no Y Bot): made the first time it is asked for.
    static func shared() -> CharacterKit? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let kit = load()
        cached = .some(kit)
        return kit
    }

    static let version: UInt32 = 11
    private static let magic: UInt32 = 0x4B43_474D   // "MGCK"

    static func load(_ directory: URL = CharacterLibrary.directory, cache: Bool = true, options: CharacterBase.Options = .init()) -> CharacterKit? {
        let library = CharacterLibrary.load(directory, cache: cache)
        guard let male = library.characters.first(where: { $0.name == "Y Bot" }) ?? library.characters.first else { return nil }
        let female = library.characters.first { $0.name == "X Bot" }
        let clips = poseClips(male) + male.clips
        let start = CFAbsoluteTimeGetCurrent()
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "fbx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let url = CharacterLibrary.cacheURL(for: files, in: directory, prefix: "character-kit-\(Int(options.cell * 10000))",
                                            version: version)
        if cache, let (base, morphs) = try? read(url), base.character.joints.count == male.joints.count {
            print(String(format: "Character kit: from the cache in %.1f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000))
            return CharacterKit(base: base, morphs: morphs, clips: clips)
        }
        guard var base = CharacterBase.build(male, options: options) else { return nil }
        base.character.coarser = CharacterImporter.coarser(base.character, levels: CharacterLibrary.coarserLevels)
        let morphs = CharacterMorphs.build(base, female: female)
        print(String(format: "Character kit: built in %.0f ms (%d targets)", (CFAbsoluteTimeGetCurrent() - start) * 1000, morphs.targets.count))
        if cache {
            do { try CacheFile.write(encoded(base, morphs), to: url) } catch { print("Character kit: could not write \(url.path): \(error)") }
        }
        return CharacterKit(base: base, morphs: morphs, clips: clips)
    }

    /// A still clip of the bind pose (the T pose), and one with the arms down at 45 degrees (the A pose).
    static func poseClips(_ c: SkinnedCharacter) -> [SkinnedCharacter.Clip] {
        let world = c.bindPoses
        let names = c.jointNames.map { $0.replacingOccurrences(of: "mixamorig:", with: "") }
        func clip(_ name: String, turn: (Int) -> simd_quatf?) -> SkinnedCharacter.Clip {
            // Each joint's world rotation: its parent's (as turned) times its own bind rotation in its parent's space,
            // then its own turn (world space); its key is that in its turned parent's space.
            let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            var turned = [simd_quatf](), local = [SIMD4<Float>]()
            for (j, joint) in c.joints.enumerated() {
                let parentBind = joint.parent >= 0 ? world[joint.parent].q : identity
                let parentTurned = joint.parent >= 0 ? turned[joint.parent] : identity
                let q = (turn(j) ?? identity) * parentTurned * (parentBind.inverse * world[j].q)
                turned.append(q)
                local.append(simd_normalize(parentTurned.inverse * q).vector)
            }
            let root = c.joints.firstIndex { $0.parent < 0 } ?? 0
            let rootKey = SIMD4(c.joints[root].local.x, c.joints[root].local.y, c.joints[root].local.z, 0)
            return SkinnedCharacter.Clip(name: name, keyCount: 2, rate: 1, rotations: local + local, root: [rootKey, rootKey],
                                         velocity: .zero)
        }
        let tPose = clip("T-Pose") { _ in nil }
        let aPose = clip("A-Pose") { j in
            switch names[j] {
            case "LeftArm": return simd_quatf(angle: -.pi / 4, axis: [0, 0, 1])
            case "RightArm": return simd_quatf(angle: .pi / 4, axis: [0, 0, 1])
            default: return nil
            }
        }
        return [tPose, aPose]
    }

    // MARK: Cache file

    static func encoded(_ base: CharacterBase, _ morphs: CharacterMorphs) -> Data {
        var w = BlobWriter()
        w.put(magic)
        w.put(version)
        let c = base.character
        w.put(c.positions); w.put(c.normals); w.put(c.uvs); w.put(c.indices); w.put(c.skin); w.put(c.joints)
        w.put(UInt32(c.jointNames.count))
        for n in c.jointNames { w.put(n) }
        w.put(UInt32(c.coarser.count))
        for l in c.coarser { w.put(l.indices); w.put(l.skin); w.put(l.uvs); w.put(l.source) }
        w.put(base.regions)
        w.put(UInt32(morphs.targets.count))
        for t in morphs.targets { w.put(t.name); w.put(t.vertices); w.put(t.deltas) }
        w.put(morphs.sexOffsets)
        return w.data
    }

    static func read(_ url: URL) throws -> (CharacterBase, CharacterMorphs) {
        var r = BlobReader(try Data(contentsOf: url, options: .alwaysMapped))
        guard try r.get(UInt32.self) == magic, try r.get(UInt32.self) == version else { throw FBXError.invalid("not a character kit cache") }
        var c = SkinnedCharacter(name: "Generated", positions: try r.array(), normals: try r.array(), uvs: try r.array(),
                                 indices: try r.array(), skin: try r.array(), joints: try r.array(), jointNames: [],
                                 color: [0.8, 0.62, 0.52], boundsMin: .zero, boundsMax: .zero, clips: [])
        for _ in 0..<Int(try r.get(UInt32.self)) { c.jointNames.append(try r.string()) }
        for _ in 0..<Int(try r.get(UInt32.self)) {
            let indices: [UInt32] = try r.array(), skin: [GPUSkinVertex] = try r.array(), uvs: [SIMD2<Float>] = try r.array()
            let source: [UInt32] = try r.array()
            guard source.count == skin.count, source.allSatisfy({ Int($0) < c.positions.count }),
                  indices.allSatisfy({ Int($0) < source.count }) else { throw FBXError.invalid("a character kit cache that doesn't add up") }
            c.coarser.append(SkinnedCharacter.Level(positions: source.map { c.positions[Int($0)] }, normals: source.map { c.normals[Int($0)] },
                                                    uvs: uvs, indices: indices, skin: skin, source: source))
        }
        let regions: [UInt8] = try r.array()
        var targets: [CharacterMorphs.Target] = []
        for _ in 0..<Int(try r.get(UInt32.self)) {
            let t = CharacterMorphs.Target(name: try r.string(), vertices: try r.array(), deltas: try r.array())
            guard t.vertices.count == t.deltas.count, t.vertices.allSatisfy({ Int($0) < c.positions.count }) else {
                throw FBXError.invalid("a character kit cache that doesn't add up")
            }
            targets.append(t)
        }
        let offsets: [SIMD3<Float>] = try r.array()
        guard c.normals.count == c.positions.count, c.skin.count == c.positions.count, regions.count == c.positions.count,
              offsets.count == c.joints.count, c.indices.allSatisfy({ Int($0) < c.positions.count }) else {
            throw FBXError.invalid("a character kit cache that doesn't add up")
        }
        (c.boundsMin, c.boundsMax) = CharacterImporter.bounds(of: c)
        return (CharacterBase(character: c, regions: regions), CharacterMorphs(targets: targets, sexOffsets: offsets))
    }
}
