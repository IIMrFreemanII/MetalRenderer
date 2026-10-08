import Foundation
import simd

/// The crowd scene: a square under the sun where `characters` of the characters in Assets/Characters walk, run and
/// stand, animated by `poses` pose slots (Crowd). Rows run across the square; a row is one character in one motion
/// at one size, so the members of a walking row keep their distances, and each takes one of the motion's slots, so
/// they are out of step with their neighbours. Seeded: every run builds the same crowd.
extension Scene {
    /// The character catalog's people (the one `key` names, SceneSettings.characterCatalog), made from their DNA.
    static func generatedPeople(_ key: String) -> CharacterLibrary {
        guard let kit = CharacterKit.shared() else { return CharacterLibrary() }
        let dna = CharacterCatalog.resolve(key).characters
        var built = [SkinnedCharacter](repeating: kit.base.character, count: dna.count)
        built.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: dna.count) { out[$0] = CharacterBuilder.build(dna[$0], kit: kit) }
        }
        // The workshop's still poses aren't motions a crowd plays.
        let still = Set(CharacterKit.poseClips(kit.base.character).map(\.name))
        for i in built.indices { built[i].clips.removeAll { still.contains($0.name) } }
        return CharacterLibrary(characters: built)
    }

    func buildCrowd(characters count: Int, poses: Int, detail: Int) {
        let quad = addMesh(Scene.quadMesh())
        let cube = addMesh(Scene.cubeMesh())
        let paving = addMaterial(albedo: [0.42, 0.4, 0.37])
        let stone = addMaterial(albedo: [0.7, 0.66, 0.6])

        // The square: lanes along x, `perRow` members to a lane, a row every `rowSpacing` in z.
        let count = max(count, 1)
        let lane = min(max(2.4 * Float(count).squareRoot(), 24), 400)
        let perRow = max(Int(lane / 2), 1), rows = (count + perRow - 1) / perRow
        let rowSpacing: Float = 1.15
        let depth = Float(rows) * rowSpacing
        addInstance(quad, paving, scale([lane + 80, 1, depth + 80]))
        // Blocks along the far side and at the ends, for scale and long shadows.
        var rng = SplitMix64(seed: 0xC0_FFEE)
        for i in 0..<max(Int(lane / 9), 2) {
            let w = rng.range(4, 7), h = rng.range(5, 14)
            let x = -lane / 2 + (Float(i) + 0.5) * lane / Float(max(Int(lane / 9), 2))
            addInstance(cube, stone, translate([x, h / 2, -depth / 2 - 8 - rng.range(0, 4)]) * scale([w, h, w]))
        }
        for side: Float in [-1, 1] {
            addInstance(cube, stone, translate([side * (lane / 2 + 6), 1.5, 0]) * scale([1.2, 3, min(depth, 30)]))
        }

        // The sun, high and to the side so the crowd throws shadows across the lanes; its colour is the atmosphere's.
        let elevation: Float = 48 * .pi / 180, azimuth: Float = 0.7
        let toward = SIMD3<Float>(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth))
        addLight(.sun(angularRadius: 0.27 * .pi / 180), color: [1, 1, 1]) { _ in LightPose(position: .zero, direction: toward) }

        var camera = Camera()
        camera.position = [0, 3.6, depth / 2 + 6.5]
        camera.pitch = -0.26
        defaultCamera = camera

        let library = settings.crowdBodies == .generated ? Scene.generatedPeople(settings.characterCatalog) : CharacterLibrary.load()
        guard !library.characters.isEmpty else { return }
        let crowd = Crowd(characters: library.characters, poses: poses, level: detail)
        adopt(crowd)
        let states = crowd.liveStates
        guard !states.isEmpty else { return }

        // Tints: each character in its own colour and a few others.
        let hues: [SIMD3<Float>] = [[0.75, 0.2, 0.15], [0.85, 0.6, 0.15], [0.2, 0.5, 0.25], [0.2, 0.3, 0.7], [0.55, 0.25, 0.6],
                                    [0.75, 0.75, 0.75], [0.12, 0.12, 0.14]]
        let tints: [[Int]] = library.characters.map { c in
            // Generated people in their own skin (shades of it, until they have clothes), mannequins in colours.
            let colors = settings.crowdBodies == .generated ? (0...hues.count).map { c.color * (0.85 + 0.3 * Float($0) / Float(hues.count)) }
                                                            : [c.color] + hues
            return colors.map { addMaterial(albedo: $0) }
        }

        // Rows: two in three walk or run, the rest stand.
        let moving = states.filter { crowd.states[$0].travels }, standing = states.filter { !crowd.states[$0].travels }
        var placed = 0
        for row in 0..<rows {
            let z = (Float(row) + 0.5) * rowSpacing - depth / 2
            let pool = !moving.isEmpty && (standing.isEmpty || rng.next() < 0.67) ? moving : standing
            let state = pool[rng.int(pool.count)]
            let travels = crowd.states[state].travels
            let slots = crowd.states[state].slots
            let size = rng.range(0.92, 1.08)
            let direction: Float = rng.next() < 0.5 ? 1 : -1
            for i in 0..<min(perRow, count - placed) {
                let along = (Float(i) + rng.range(0.3, 0.7)) * lane / Float(perRow)
                let slot = slots[rng.int(slots.count)]
                let material = tints[crowd.states[state].character][rng.int(hues.count + 1)]
                // A character faces +z: a walker is turned to face along its lane, one who stands any way.
                let yaw = travels ? direction * .pi / 2 : rng.range(0, 2 * .pi)
                let rotation = rotate(yaw, [0, 1, 0])
                let origin = SIMD3<Float>(travels ? -direction * lane / 2 : along - lane / 2, 0, z + (travels ? 0 : rng.range(-0.2, 0.2)))
                let instance = addInstance(crowd.slots[slot].mesh, material, translate(origin) * rotation * scale(size))
                setSkinned(instance, travels: travels)
                if travels {
                    func column(_ c: SIMD4<Float>) -> SIMD3<Float> { SIMD3(c.x, c.y, c.z) / size }
                    crowd.walkers.append(Crowd.Walker(instance: instance, slot: slot, origin: origin,
                                                      forward: [direction, 0, 0], start: along, lane: lane, scale: size,
                                                      inverse0: column(rotation.columns.0), inverse1: column(rotation.columns.1),
                                                      inverse2: column(rotation.columns.2)))
                }
                placed += 1
            }
        }
        crowd.memberCount = placed
        print("Crowd: \(placed) characters (\(crowd.walkers.count) walking) on \(crowd.slots.count) poses, "
              + "\(crowd.states.filter { !$0.slots.isEmpty }.count) motions, "
              + crowd.parts.indices.map { "\(crowd.geometry(part: $0).triangleCount)" }.joined(separator: " / ") + " triangles a pose")
    }
}
