import Characters
import EngineCore
import Foundation
import Plants
import simd

/// The plant workshop's lights' turn about the plant (degrees): its behaviour (PlantPreviewPlayer) sets it each frame
/// from the settings, the sun's pose reads it.
package final class PlantPreviewRig {
    package var yaw: Float = 0

    /// The sun's height and the side it shines from at no turn: 40° up (Unreal's preview light), from the camera's
    /// left and in front.
    package static let elevation = Scene.degrees(40), azimuth = Scene.degrees(235)
    /// How fast the lights turn by themselves (degrees a second).
    package static let spinRate: Float = 10

    package init() {}

    /// Toward the sun, turned by `yaw` degrees.
    package static func sun(yaw: Float) -> SIMD3<Float> {
        let e = elevation, a = azimuth + Scene.degrees(yaw)
        return [cos(e) * cos(a), sin(e), -cos(e) * sin(a)]
    }
}

/// The plant workshop's behaviour: it turns the lights as `RenderSettings.previewLightYaw` and `previewSpin` say,
/// live (a setting of the scene would make it again).
package final class PlantPreviewPlayer: SceneBehaviour {
    let rig: PlantPreviewRig?
    package var captured = false

    package init(_ scene: Scene) { rig = scene.previewRig }

    package func update(_ renderer: Renderer, dt: Float) -> Bool {
        if renderer.settings.previewSpin {
            renderer.session.previewSpin = PlantPreviewPlayer.spun(renderer.session.previewSpin, dt: dt)
        }
        rig?.yaw = renderer.settings.previewLightYaw + renderer.session.previewSpin
        return false
    }

    /// `turned` a frame of `dt` s later, within a turn.
    package static func spun(_ turned: Float, dt: Float) -> Float {
        (turned + PlantPreviewRig.spinRate * dt).truncatingRemainder(dividingBy: 360)
    }
}

extension Scene {
    /// Unreal's preview lighting in this renderer's units: its viewport's fixed exposure (EV100 -0.2, so ×0.957), the
    /// 0.6 that the ACES fit here wants on its input to be ACES's curve (Narkowicz 2015), and 1.17 more, measured
    /// against the vegetation editor's own picture (its backdrop and floor, lit and in shade, all came out that much
    /// brighter there: Unreal's filmic curve sits above the fit in the mid-tones).
    package static let previewUnits: Float = 0.957 * 0.6 * 1.17
    /// The vegetation editor's profile, Unreal's "Grey Ambient" (AssetViewerSettings.h): a white sun of 4 lux...
    package static let previewSun = SIMD3<Float>(repeating: 4 * previewUnits)
    /// ...and a sky light of 2 times its grey studio cubemap (T_GreyAmbient), here its upper half's mean (as a floor
    /// sees it), a little cool: the editor's floor is bluer in its picture than a white light makes it...
    package static let previewSky = SIMD3<Float>(0.55, 0.56, 0.59) * 2 * previewUnits
    /// ...whose picture is hidden: a camera ray sees the viewport's clear colour (its EnvironmentColor, 0.2 grey).
    package static let previewBackdrop = SIMD3<Float>(repeating: 0.2 * previewUnits)
    /// Unreal's preview floor: its Floor_Mesh (10 m square, 1 m thick) at its profile's scale 4, so 20 m about the
    /// origin each way; its edge shows against the backdrop.
    package static let previewFloorReach: Float = 20

    /// The plant workshop's stage, as Unreal's tree preview (the vegetation editor, its Grey Ambient profile): its grid
    /// floor, a slab 40 m square (wider if `plants` reach further) under a dark grey backdrop, a grey sky
    /// (SceneDefinition's `previewSky`, a constant colour) lighting it, a white sun 40° up that its rig turns.
    package func addPreviewStage(_ kit: Kit, around plants: AABB = AABB()) {
        let floor = addGridMaterial(.previewFloor)
        var reach = Scene.previewFloorReach
        if !plants.isEmpty { reach = max(reach, max(-plants.lo.x, plants.hi.x, -plants.lo.z, plants.hi.z) + 5) }
        object("Floor") { kit.slab([-reach, -1, -reach], [reach, 0, reach], floor) }
        backdrop = Scene.previewBackdrop
        skyColor = Scene.previewSky
        let rig = PlantPreviewRig()
        previewRig = rig
        addLight(.sun(angularRadius: Scene.degrees(0.27)), color: Scene.previewSun) { _ in
            LightPose(position: .zero, direction: PlantPreviewRig.sun(yaw: rig.yaw))
        }
    }

    /// A person standing on the floor beside `plant` (its bounds), for its size, as Unreal's mannequin: the characters'
    /// base body in its bind pose (a T), or a figure of boxes 1.8 m tall without the character library. Its bounds.
    @discardableResult
    package func addPlantFigure(beside plant: AABB, _ kit: Kit) -> AABB {
        let grey = addPBRMaterial(baseColor: [0.55, 0.55, 0.57], metallic: 0, roughness: 0.5)
        var body = AABB()
        let base = CharacterKit.shared()?.base.character
        if let base { for p in base.positions { body.grow(p) } }
        // To the camera's right (the sun shines from its left), half again the gap of their two half-widths away.
        let half: Float = body.isEmpty ? 0.25 : (body.hi.x - body.lo.x) / 2
        let x = plant.centroid.x + ((plant.hi.x - plant.lo.x) / 2 + half) * 1.5, z = plant.centroid.z
        object("Scale figure") {
            if let base, !body.isEmpty {
                let mesh = addMesh((base.positions, base.normals, base.indices), uvs: base.uvs, name: "plant workshop/figure")
                addInstance(mesh, grey, translate([x - body.centroid.x, -body.lo.y, z - body.centroid.z]))
            } else {
                body = AABB(lo: [-0.25, 0, -0.15], hi: [0.25, 1.8, 0.15])
                kit.box([x - 0.1, 0.42, z], [0.14, 0.84, 0.16], grey)
                kit.box([x + 0.1, 0.42, z], [0.14, 0.84, 0.16], grey)
                kit.box([x, 1.15, z], [0.42, 0.62, 0.22], grey)
                kit.ball([x, 1.68, z], 0.12, grey)
            }
        }
        let size = body.hi - body.lo
        return AABB(lo: [x - size.x / 2, 0, z - size.z / 2], hi: [x + size.x / 2, size.y, z + size.z / 2])
    }

    /// `box`'s width, depth and height drawn beside it and written in metres, as Unreal's scale view: red along X at
    /// its front, green along Z at its left (its label past the far end), blue up its front left corner. Glowing bars only the camera sees (no
    /// shadows, not lights), the labels in strokes of the same (a little smaller than Unreal's, which its framing leaves
    /// out), upright and facing the default camera. What they cover.
    @discardableResult
    package func addSizeRuler(_ box: AABB, _ kit: Kit) -> AABB {
        let size = box.hi - box.lo, extent = (size.x + size.y + size.z) / 2
        let text = max(extent * 0.05, 0.08), thick = max(extent * 0.004, 0.008), gap = text * 0.6
        func glow(_ c: SIMD3<Float>) -> Int { addMaterial(albedo: c * 0.2, emission: c * 2) }
        let red = glow([1, 0.12, 0.1]), green = glow([0.2, 1, 0.2]), blue = glow([0.2, 0.45, 1])
        var covered = box
        func bar(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ width: Float, _ material: Int) {
            covered.grow(a); covered.grow(b)
            addInstance(kit.cube, material, Scene.bar(a, b, width), mask: Scene.maskLights)
        }
        func label(_ s: String, _ at: SIMD3<Float>, alignRight: Bool, _ material: Int) {
            let w = Scene.strokeWidth(s) * text
            let left = at + SIMD3(alignRight ? -w : -w / 2, 0, 0)
            for (a, b) in Scene.strokes(s) {
                bar(left + SIMD3(a.x, a.y, 0) * text, left + SIMD3(b.x, b.y, 0) * text, text * 0.12, material)
            }
        }
        let front = box.hi.z + gap, left = box.lo.x - gap, lift = thick / 2
        object("Size ruler") {
            bar([box.lo.x, lift, front], [box.hi.x, lift, front], thick, red)
            label(Scene.metres(size.x), [box.centroid.x, gap * 0.5, front], alignRight: false, red)
            bar([left, lift, box.lo.z], [left, lift, front], thick, green)
            // (Past the bar's far end: a bar through it reads as another digit's stroke.)
            label(Scene.metres(size.z), [left, gap * 0.25, box.lo.z - gap], alignRight: false, green)
            bar([left, 0, front], [left, size.y + box.lo.y, front], thick, blue)
            label(Scene.metres(size.y), [left - gap * 0.5, box.hi.y - text, front], alignRight: true, blue)
        }
        return covered
    }

    /// A length as the ruler writes it: "4.20m".
    package static func metres(_ m: Float) -> String { String(format: "%.2fm", m) }

    /// A unit box stretched from `a` to `b`, `width` across.
    static func bar(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ width: Float) -> float4x4 {
        let d = b - a, length = simd_length(d)
        let along = length > 1e-6 ? d / length : SIMD3<Float>(1, 0, 0)
        let side = abs(along.y) < 0.9 ? normalize(simd_cross(along, [0, 1, 0])) : normalize(simd_cross(along, [1, 0, 0]))
        let other = simd_cross(side, along)
        return float4x4(SIMD4(along * (length + width), 0), SIMD4(other * width, 0), SIMD4(side * width, 0), SIMD4((a + b) / 2, 1))
    }

    // MARK: - The ruler's lettering

    /// The ruler's characters as strokes on a 0.6 × 1 cell (seven segments for the digits, a centred stroke for 1): from
    /// the baseline up, a text height to 1.
    private static let glyphs: [Character: [(SIMD2<Float>, SIMD2<Float>)]] = {
        let a = (SIMD2<Float>(0, 1), SIMD2<Float>(0.6, 1)), b = (SIMD2<Float>(0.6, 1), SIMD2<Float>(0.6, 0.5))
        let c = (SIMD2<Float>(0.6, 0.5), SIMD2<Float>(0.6, 0)), d = (SIMD2<Float>(0, 0), SIMD2<Float>(0.6, 0))
        let e = (SIMD2<Float>(0, 0), SIMD2<Float>(0, 0.5)), f = (SIMD2<Float>(0, 0.5), SIMD2<Float>(0, 1))
        let g = (SIMD2<Float>(0, 0.5), SIMD2<Float>(0.6, 0.5))
        return ["0": [a, b, c, d, e, f], "1": [(SIMD2(0.3, 0), SIMD2(0.3, 1))], "2": [a, b, g, e, d], "3": [a, b, g, c, d], "4": [f, g, b, c],
                "5": [a, f, g, c, d], "6": [a, f, g, e, d, c], "7": [a, b, c], "8": [a, b, c, d, e, f, g], "9": [a, b, c, d, f, g],
                ".": [(SIMD2(0.05, 0.03), SIMD2(0.13, 0.03))],
                "m": [(SIMD2(0, 0), SIMD2(0, 0.55)), (SIMD2(0.3, 0), SIMD2(0.3, 0.55)), (SIMD2(0.6, 0), SIMD2(0.6, 0.55)),
                      (SIMD2(0, 0.55), SIMD2(0.6, 0.55))]]
    }()

    private static func advance(_ ch: Character) -> Float { ch == "." ? 0.38 : 0.9 }

    /// `s`'s strokes laid out from x 0, in text heights.
    package static func strokes(_ s: String) -> [(SIMD2<Float>, SIMD2<Float>)] {
        var x: Float = 0, out: [(SIMD2<Float>, SIMD2<Float>)] = []
        for ch in s {
            for (a, b) in glyphs[ch] ?? [] { out.append((a + SIMD2(x, 0), b + SIMD2(x, 0))) }
            x += advance(ch)
        }
        return out
    }

    /// How wide `s` is written, in text heights (its last character without the space after it).
    package static func strokeWidth(_ s: String) -> Float {
        guard let last = s.last else { return 0 }
        return s.reduce(0) { $0 + advance($1) } - advance(last) + (last == "." ? 0.13 : 0.6)
    }
}
