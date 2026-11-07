import simd
import MetalRenderer

/// The light lab's benchmarks (Tools/eval/lightlab.py). Setting names are `lab<NN> <group> <what>` (NN: the booth's two-digit
/// number, group: `types`, `shadows`, `materials`, `counts`, `yard` or `gi`), so `METALRENDERER_BENCH_ONLY="lab09"` runs one
/// booth, `"shadows"` one group, and `"lab07|lab09"` a few.
extension Benchmark {
    /// "lab09 shadows": the prefix of booth `booth`'s settings.
    private static func labTag(_ booth: LabBooth) -> String {
        String(format: "lab%02d ", booth.number) + "\(booth.group)"
    }

    private static func labScene(_ booth: LabBooth?, motion: Bool = false) -> SceneSettings {
        var s = SceneSettings(kind: .lightLab)
        s.lightLab = LightLabSettings(variant: .normal, motion: motion, only: booth?.number)
        return s
    }

    /// Direct light (GI off, constant sky) of every booth with a direct check, built alone at its bookmark, accumulated:
    /// every light traced (the normal variant stays under 1024), Sampled and MegaLights; and the exact image of the same
    /// booth in the full hall, to find light leaking through the walls (the alone-versus-full difference must be 0).
    /// Sized as `sampledcheck`'s settings (0.75x, 1024 frames).
    static func lightlab() -> [Config] {
        LightLab.booths.filter { $0.checks.contains(.direct) }.flatMap { booth -> [Config] in
            let tag = labTag(booth)
            func accumulated(_ name: String, _ scene: SceneSettings, _ mode: DirectLightMode) -> Config {
                Config("\(tag) \(name)", gi: nil, scene: scene)
                    .sky { $0 = SkySettings() }
                    .at("\(booth.number)")
                    .reference(frames: 1024).direct(mode)
            }
            let alone = labScene(booth, motion: booth.number == 21 || booth.number == 22)
            return [accumulated("exact", alone, .exact), accumulated("sampled", alone, .sampled),
                    accumulated("megalights", alone, .megalights),
                    accumulated("exact full", labScene(nil, motion: alone.lightLab.motion), .exact)]
        }
    }

    /// A short dolly toward the booth's bookmark (0.5 m back and 0.3 m aside at the start, a second at a steady pace), still moving
    /// when the last frame is drawn at the bookmark: it scores against the still reference.
    private static func labDolly(_ booth: LabBooth) -> CameraTrack {
        let b = LightLab.bookmark(booth)
        let forward = simd_normalize(b.lookAt - b.position)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let offset = right * 0.3 - forward * 0.5
        return CameraTrack([.init(time: 0, position: b.position + offset, target: b.lookAt + right * 0.3),
                            .init(time: 1, position: b.position, target: b.lookAt)], linear: true)
    }

    /// Every booth at its bookmark in the full hall, for the realtime methods against accumulated references (GI off, 0.5x,
    /// 2048 frames; the references trace every light):
    /// * MegaLights and Sampled, under the app's MetalFX look (3x from 0.5x, its output scored at 640x400 by Python) and under
    ///   SVGF (no upscaling): a still at t = 5 s with the frame before it (flicker), and a one-second camera dolly that ends
    ///   still moving at the bookmark. The motion booths (21, 22) have their motion on and a "moving" frame (animation
    ///   running, fixed camera) as well, all ending at t = 5 s.
    /// * `.gi` booths: the app's MetalFX look with cascades GI, a still against a path-traced reference.
    /// Narrow it: `METALRENDERER_BENCH_ONLY="lab09"`, `"shadows"`.
    static func lightlabq() -> [Config] {
        let frames = 60, dollyFrames = 61
        return LightLab.booths.flatMap { booth -> [Config] in
            let tag = labTag(booth)
            let motion = booth.number == 21 || booth.number == 22
            let scene = labScene(nil, motion: motion)
            let direct = Config("", scale: 0.5, gi: nil, scene: scene).at("\(booth.number)")
            var out = references([direct.named("\(tag) ref direct").reference(frames: 2048).direct(.exact)])
            let looks: [(String, (Config) -> Config)] = [
                ("metalfx", { $0.with { $0.renderScale = 0.5; $0.upscaleFactor = 3 } }),
                ("svgf", { $0 }),
            ]
            for (method, mode) in [("megalights", DirectLightMode.megalights), ("sampled", .sampled)] {
                for (look, apply) in looks {
                    let base = apply(direct.direct(mode))
                    let name = "\(tag) \(method) \(look)"
                    out.append(base.named("\(name) static").still(previous: true).frames(frames))
                    if motion { out.append(base.named("\(name) moving").frames(nil)) }
                    // The dolly ends at t = 5 s like the still: the clock runs warm-up (60) + measured frames.
                    var camera = base.named("\(name) camera").track(labDolly(booth))
                    camera.startTime = 5 - Float(60 + dollyFrames) / 60
                    out.append(camera)
                }
            }
            if booth.checks.contains(.gi) {
                let gi = Config("", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene).at("\(booth.number)")
                out += references([Config("\(tag) ref pt", scale: 0.5, gi: .pathTraced, scene: scene) { $0.reference.mode = .pathTraced }.at("\(booth.number)")
                    .reference(frames: 1024)])
                out.append(gi.direct(.megalights).named("\(tag) megalights gi").still(previous: true).frames(frames))
            }
            return out
        }
    }
}
