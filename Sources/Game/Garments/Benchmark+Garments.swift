import EngineCore
import Foundation
import Characters
import Garments
import simd
import MetalRenderer

/// The garment workshop's benchmark modes: every template sewn and draped on the Y Bot and the X Bot, from the front
/// and the back (`garments`); one garment and avatar from `METALRENDERER_SCENE=garments,garment=…,avatar=…` over three
/// seconds of its drape (`garmentdrape`).
extension Benchmark {
    static let garmentModes: [String: () -> [Config]] = [
        "garments": garments, "garmentdrape": garmentDrape, "garmentwalk": garmentWalk, "garmentcrowd": garmentCrowd,
    ]

    /// `kind` on `avatar` after `seconds` of draping (a frame a 60th of a second of the cloth's).
    static func garmentShot(_ name: String, garment: String, avatar: String, seconds: Float = 3, back: Bool = false) -> Config {
        var scene = SceneSettings(kind: .garmentStage)
        scene.garmentWorkshop.garment = garment
        scene.garmentWorkshop.avatar = avatar
        var c = Config("garment \(name)", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).still().frames(Int(seconds * 60) - 60)
        if back { c = viewed(c, look(from: [0, 1.35, -2.8], at: [0, 1.1, 0])) }
        return c
    }

    private static func garments() -> [Config] {
        GarmentTemplate.Kind.allCases.flatMap { kind -> [Config] in
            [garmentShot("\(kind.rawValue) y", garment: kind.rawValue, avatar: GarmentAvatar.yBot),
             garmentShot("\(kind.rawValue) x", garment: kind.rawValue, avatar: GarmentAvatar.xBot),
             garmentShot("\(kind.rawValue) y back", garment: kind.rawValue, avatar: GarmentAvatar.yBot, back: true)]
        } + [garmentShot("layered y", garment: "shirt+coat", avatar: GarmentAvatar.yBot, seconds: 4),
             garmentShot("layered x", garment: "tshirt+pants+coat", avatar: GarmentAvatar.xBot, seconds: 4)]
    }

    /// The garment on a moving avatar, recorded (30 fps JPEGs, video.sh makes them a film): sewn in the bind pose, then
    /// the avatar walks (GarmentMotion). `METALRENDERER_GARMENT` (a dress), `METALRENDERER_AVATAR` (the X Bot),
    /// `METALRENDERER_CLIP` (Walking).
    private static func garmentWalk() -> [Config] {
        var c = garmentShot("walk", garment: env["METALRENDERER_GARMENT"] ?? "dress", avatar: env["METALRENDERER_AVATAR"] ?? GarmentAvatar.xBot)
        c.settings.scene.garmentWorkshop.clip = env["METALRENDERER_CLIP"] ?? "Walking"
        // The clock runs from 0 (the avatar's motion starts with the cloth's).
        c.settings.paused = false
        c.startTime = 0
        c = viewed(c, look(from: [2.2, 1.3, 2.6], at: [0, 0.95, 0]))
        return [c.frames(7 * 60).recording()]
    }

    /// A crowd of generated people dressed (CrowdBodies.dressed: their outfits draped once on the CPU and bound, then
    /// skinned with them) against the same crowd in its skin: what the clothes cost a frame.
    private static func garmentCrowd() -> [Config] {
        [CrowdBodies.generated, .dressed].map { bodies in
            var scene = SceneSettings(kind: .crowd, characters: 200, poses: 32, detail: 1, crowdBodies: bodies)
            scene.characterCatalog = "builtin"
            return Config("crowd \(bodies == .dressed ? "dressed" : "skin")", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).still()
        }
    }

    /// The drape at moments of its first three seconds, from the front and the side: `METALRENDERER_GARMENT` (a template's
    /// kind or a saved garment, `tshirt` if unset) on `METALRENDERER_AVATAR` (the Y Bot).
    private static func garmentDrape() -> [Config] {
        let garment = env["METALRENDERER_GARMENT"] ?? "tshirt", avatar = env["METALRENDERER_AVATAR"] ?? GarmentAvatar.yBot
        return [0.02, 0.3, 0.7, 1.2, 3].flatMap { (t: Float) -> [Config] in
            var front = garmentShot(String(format: "%@ %.2f s", garment, t), garment: garment, avatar: avatar, seconds: 3)
            front.settings.scene.garmentWorkshop.stopAt = t
            return [front, viewed(front.named(front.name + " side"), look(from: [2.6, 1.4, 1.0], at: [0, 1.15, 0]))]
        }
    }
}
