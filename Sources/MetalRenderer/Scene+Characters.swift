import Foundation
import QuartzCore
import simd

/// What the character workshop's character is, for the character editor: its mesh, its height, and how long the
/// workshop took to make it.
struct CharacterStats: Equatable {
    var name = ""
    var vertices = 0
    var triangles = 0
    var height: Float = 0
    var buildMs = 0.0
}

extension Scene {
    /// The character workshop: one character (or everyone, or the editor's variations of one) in a studio, in the pose
    /// `settings.characterWorkshop` asks for. The character editor makes it again at every edit (its characters from
    /// `settings.characterCatalog`): the characters are made from their DNA (CharacterBuilder) and posed by the crowd's
    /// GPU skinning, a pose slot each.
    func buildCharacterWorkshop() {
        let start = CACurrentMediaTime()
        remadeOften = true
        let w = settings.characterWorkshop
        let catalog = CharacterCatalog.resolve(settings.characterCatalog)
        var chosen = catalog.character(id: w.character) ?? catalog.characters.first ?? CharacterDNA()
        // Comparing: the definition to compare with in place of the edited one.
        if let other = CharacterCatalog.registered(w.compare), let def = other.character(id: chosen.id) { chosen = def }
        var shown = [chosen]
        switch w.layout {
        case .single: break
        case .lineup: shown = catalog.characters.map { $0.id == chosen.id ? chosen : $0 }
        case .mutate: shown += CharacterCatalog.registered(w.mutants)?.characters ?? []
        }

        // The studio: a floor to the horizon, a sun from the camera's left a little above, the sky.
        let kit = Kit(self)
        addInstance(kit.quad, addMaterial(albedo: [0.32, 0.31, 0.3]), scale([20_000, 1, 20_000]))
        addLight(.sun(angularRadius: Scene.degrees(0.6)), color: [1, 1, 1]) { _ in
            let e = Scene.degrees(34), a = Scene.degrees(240)
            return LightPose(position: .zero, direction: [cos(e) * cos(a), sin(e), -cos(e) * sin(a)])
        }
        let fallback = AABB(lo: [-0.4, 0, -0.3], hi: [0.4, 1.8, 0.3])
        guard let generator = CharacterKit.shared() else {
            focus = fallback
            defaultCamera = Camera.framing(fallback, fovY: Camera().fovY).camera
            return
        }
        var built = [SkinnedCharacter](repeating: generator.base.character, count: shown.count)
        built.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: shown.count) { out[$0] = CharacterBuilder.build(shown[$0], kit: generator) }
        }
        let clipName = w.pose.clipName ?? w.clip
        let clips = built.map { $0.clip(named: clipName) ?? $0.clip(named: "A-Pose") ?? 0 }
        let crowd = Crowd(characters: built, clips: clips)
        crowd.faces = built.map { Crowd.Face(rig: generator.face, character: $0, expressive: true) }
        crowd.expression = w.expression
        adopt(crowd)

        // In a row along x, a metre apart (wider for the wide), facing the camera.
        let gap: Float = shown.count > 1 ? 0.95 : 0
        var focus = AABB(), face = AABB()
        for (k, c) in built.enumerated() {
            let x = (Float(k) - Float(built.count - 1) / 2) * gap
            let skin = addCharacterMaterials(shown[k].look, skin: c.color)
            let instance = addInstance(crowd.slots[k].mesh, skin, translate([x, 0, 0]))
            setSkinned(instance, travels: false)
            if w.lookAt { crowd.lookers[k] = translate([x, 0, 0]) }
            let level = c.level(0)
            var box = level.positions.reduce(AABB()) { var b = $0; b.grow($1); return b }
            box = box.transformed(translate([x, 0, 0]))
            focus.grow(box)
            if k == 0 || shown.count == 1 {
                let bind = c.bindPoses
                if let head = CharacterBase.joint("Head", in: c), let top = CharacterBase.joint("HeadTop_End", in: c) {
                    // The face: from the chin to the brow, ear to ear.
                    let h = bind[head].t + [x, 0, 0], t = bind[top].t + [x, 0, 0], r = simd_distance(h, t)
                    face = AABB(lo: h + [-0.42 * r, -0.25 * r, 0], hi: h + [0.42 * r, 0.62 * r, 0.62 * r])
                    _ = t
                }
            }
        }
        if focus.isEmpty { focus = fallback }
        self.focus = w.view == .face && !face.isEmpty ? face : focus
        if w.view == .face && !face.isEmpty {
            // Close: the face filling most of the height (the framing below keeps 20 cm round anything).
            var c = Camera()
            c.pitch = -0.03
            c.position = face.centroid + [0, 0.012, 0] - c.forward * (0.19 / tan(c.fovY / 2))
            defaultCamera = c
        } else {
            defaultCamera = Camera.framing(self.focus!, fovY: Camera().fovY, pitch: -0.12).camera
        }

        if let c = built.first {
            var stats = CharacterStats(name: chosen.name, vertices: c.positions.count, triangles: c.triangleCount)
            if let top = CharacterBase.joint("HeadTop_End", in: c) { stats.height = c.bindPoses[top].t.y }
            stats.buildMs = (CACurrentMediaTime() - start) * 1000
            characterStats = stats
        }
    }
}
