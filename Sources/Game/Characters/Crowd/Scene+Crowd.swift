import EngineCore
import Foundation
import Plants
import simd
import MetalRenderer

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
            DispatchQueue.concurrentPerform(iterations: dna.count) { out[$0] = CharacterBuilder.build(dna[$0], kit: kit, cap: true) }
        }
        // The workshop's still poses aren't motions a crowd plays.
        let still = Set(CharacterKit.poseClips(kit.base.character).map(\.name))
        for i in built.indices { built[i].clips.removeAll { still.contains($0.name) } }
        return CharacterLibrary(characters: built)
    }

    func buildCrowd(characters count: Int, poses: Int, detail: Int) {
        let quad = addMesh(Scene.quadMesh(), label: "quad")
        let cube = addMesh(Scene.cubeMesh(), label: "box")
        let paving = addMaterial(albedo: [0.42, 0.4, 0.37])
        let stone = addMaterial(albedo: [0.7, 0.66, 0.6])

        section("Square")
        // The square: lanes along x, `perRow` members to a lane, a row every `rowSpacing` in z.
        let count = max(count, 1)
        let lane = min(max(2.4 * Float(count).squareRoot(), 24), 400)
        let perRow = max(Int(lane / 2), 1), rows = (count + perRow - 1) / perRow
        let rowSpacing: Float = 1.15
        let depth = Float(rows) * rowSpacing
        addInstance(quad, paving, scale([lane + 80, 1, depth + 80]))
        // Round the paving rolling ground (a terrain of its own, a little under the paving where it meets it: its
        // extent in steps of 8 m, which its name says), and a plain beyond to the horizon.
        let half = (SIMD2(lane + 80, depth + 80) / 2 / 8).rounded(.up) * 8
        let size = ((max(half.x, half.y) + 220) * 2 / 64).rounded(.up) * 64
        let meadow = addMaterial(albedo: [0.24, 0.3, 0.14])
        let flat = TerrainShapes.Flat(lo: -half, hi: half, level: -0.03, blend: 40)
        addGroundTerrain("crowd-\(Int(half.x))x\(Int(half.y))", base: ShapedTerrainBase(NoiseTerrainBase(size: size, cells: Int(size / 4), seed: 0xC20D,
                                                                                                        relief: 8, featureSize: 150),
                                                                                       shapes: TerrainShapes(flats: [flat])),
                         material: meadow)
        addGroundLook(GroundLook.meadow(lo: [-size / 2, -size / 2], size: [size, size], texels: 1024, key: "crowd \(Int(size))", seed: 0xC20D))
        addInstance(quad, meadow, translate([0, -14, 0]) * scale([20_000, 1, 20_000]))
        section("Fountain")
        // A round pool between the crowd and the blocks: a stone rim, a dark floor, still water a little under the rim.
        let pool = SIMD3<Float>(0, 0, -depth / 2 - 4.6)
        var rim = MeshBuilder(), basin = MeshBuilder()
        rim.ring(pool, inner: 2.65, outer: 3, height: 0.5, segments: 40)
        rim.cylinder(pool, radius: 0.22, height: 1.1, segments: 16)
        rim.cylinder(pool + [0, 0.85, 0], radius: 0.2, topRadius: 0.75, height: 0.3, segments: 24)
        let disc = (0..<40).map { k -> SIMD2<Float> in
            let a = 2 * Float.pi * Float(k) / 40
            return SIMD2(pool.x, pool.z) + SIMD2(cos(a), sin(a)) * 2.66
        }
        basin.ground(disc.map { SIMD3($0.x, 0.06, $0.y) })
        addInstance(addMesh(rim.geometry, uvs: rim.uvs, label: "fountain"), stone, matrix_identity_float4x4)
        addInstance(addMesh(basin.geometry, uvs: basin.uvs, label: "fountain floor"), addMaterial(albedo: [0.13, 0.15, 0.15]), matrix_identity_float4x4)
        addPoolWater(disc, level: 0.4, floor: 0.06, key: "crowd-fountain-\(depth)")
        section("Blocks")
        // Blocks along the far side (behind the fountain) and at the ends, for scale and long shadows.
        var rng = SplitMix64(seed: 0xC0_FFEE)
        for i in 0..<max(Int(lane / 9), 2) {
            let w = rng.range(4, 7), h = rng.range(5, 14)
            let x = -lane / 2 + (Float(i) + 0.5) * lane / Float(max(Int(lane / 9), 2))
            addInstance(cube, stone, translate([x, h / 2, -depth / 2 - 12 - rng.range(0, 4)]) * scale([w, h, w]))
        }
        for side: Float in [-1, 1] {
            addInstance(cube, stone, translate([side * (lane / 2 + 6), 1.5, 0]) * scale([1.2, 3, min(depth, 30)]))
        }

        section("Sun")
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
        if settings.crowdBodies == .generated, let kit = CharacterKit.shared() {
            crowd.faces = library.characters.map { Crowd.Face(rig: kit.face, character: $0, expressive: false) }
        }
        adopt(crowd)
        let states = crowd.liveStates
        guard !states.isEmpty else { return }

        // Tints: each character in its own colour and a few others.
        let hues: [SIMD3<Float>] = [[0.75, 0.2, 0.15], [0.85, 0.6, 0.15], [0.2, 0.5, 0.25], [0.2, 0.3, 0.7], [0.55, 0.25, 0.6],
                                    [0.75, 0.75, 0.75], [0.12, 0.12, 0.14]]
        let people = settings.crowdBodies == .generated ? CharacterCatalog.resolve(settings.characterCatalog).characters : []
        let tints: [[Int]] = library.characters.enumerated().map { k, c in
            // Generated people in their own skin (shades of it, until they have clothes) and hair, mannequins in colours.
            if settings.crowdBodies == .generated {
                let hair = k < people.count ? CharacterHair.colour(people[k].look, age: people[k].macro.age) : SIMD3<Float>(0.08, 0.05, 0.03)
                return (0...hues.count).map { (n: Int) -> Int in
                    let shade: Float = 0.85 + 0.3 * Float(n) / Float(hues.count)
                    return addCharacterMaterials(CharacterDNA.Look(), skin: c.color * shade, glossy: false, hair: hair)
                }
            }
            return ([c.color] + hues).map { addMaterial(albedo: $0) }
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
                label(mesh: crowd.slots[slot].mesh, crowd.characters[crowd.states[state].character].name)
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
        let motions: Int = crowd.states.filter { !$0.slots.isEmpty }.count
        let triangles: String = crowd.parts.indices.map { (k: Int) -> String in "\(crowd.geometry(part: k).triangleCount)" }.joined(separator: " / ")
        print("Crowd: \(placed) characters (\(crowd.walkers.count) walking) on \(crowd.slots.count) poses, \(motions) motions, \(triangles) triangles a pose")
    }
}
