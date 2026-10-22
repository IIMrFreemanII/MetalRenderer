import EngineCore
import Foundation
import Metal
import simd

/// Swift scripts in the running app (README, "Scripts"): the runner, the socket the tools reach, the scripts' closures
/// every frame, the next frame's picture, and the state the tools read.
extension Renderer {
    /// Starts the script runner, and its socket in the window's app (a benchmark only with
    /// `METALRENDERER_SCRIPT_SERVER=1`, or in the `serve` mode, so other runs never take it). `METALRENDERER_SCRIPTS=0`:
    /// neither. Main thread, before the render thread starts.
    package func startScripts() {
        let env = ProcessInfo.processInfo.environment
        guard env["METALRENDERER_SCRIPTS"] != "0", scripts == nil else { return }
        let runner = ScriptRunner(renderer: self)
        scripts = runner
        guard benchmark == nil || env["METALRENDERER_SCRIPT_SERVER"] == "1" || env["METALRENDERER_BENCH"] == "serve" else { return }
        scriptServer = ScriptServer(renderer: self, scratch: runner.scratch)
        if let server = scriptServer { print("Scripts: Tools/script.py reaches this app at \(server.socketPath)") }
    }

    /// The socket goes (at quit).
    package func stopScripts() { scriptServer?.stop() }

    /// The scripts' closures this frame (ScriptRun.onFrame).
    package func runScriptHooks(dt: Float) {
        for hook in scriptHooks { hook.run(self, dt) }
    }

    /// The scene the settings ask for is in: nothing loading, no remake or scene-file edit waiting (ScriptRun.waitForScene).
    package var sceneSettled: Bool {
        loading == nil && sceneRemake == nil && placedPending == nil && settings.scene == scene.settings && settings.api == builtAPI
    }

    // MARK: - Pictures

    /// The next frame's picture as a PNG at `url`, `scale` times its size; `done` says whether it was written (on the
    /// thread that completes the frame). Render thread.
    package func captureFrame(to url: URL, scale: Double = 1, done: @escaping (Bool) -> Void) {
        frameCaptures.append(FrameCapture(url: url, scale: scale, done: done))
    }

    /// The pictures asked for, copied from this frame's `output` as `passes` encode it; what writes them once the frame
    /// is done.
    func encodeFrameCaptures(of output: FrameOutput, passes: FrameEncoder) -> (() -> Void)? {
        guard !frameCaptures.isEmpty else { return nil }
        let texture = output.texture, w = texture.width, h = texture.height
        guard let buffer = device.makeBuffer(length: w * 4 * h, options: .storageModeShared) else { return nil }
        let asked = frameCaptures
        frameCaptures = []
        passes.capture(texture, into: buffer)
        return {
            for a in asked { a.done(Benchmark.writeImage(buffer, width: w, height: h, to: a.url, scale: a.scale)) }
        }
    }

    // MARK: - State

    /// What the tools read of the app (`{"state": true}`): the scene asked for and the one in, the scenes there are,
    /// the camera, the clock, the scene's sizes, its file's objects and lights, the named materials and prefabs a file
    /// can use, and every setting by its `METALRENDERER_*` list and key. Render thread.
    package func scriptState() -> [String: Any] {
        func xyz(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }
        var lists: [String: [String: String]] = [:]
        for spec in SettingsTable.named where spec.exported {
            let list = String(spec.variable.rawValue.dropFirst("METALRENDERER_".count)).lowercased()
            lists[list, default: [:]][spec.key ?? "value"] = spec.text(settings)
        }
        var state: [String: Any] = [
            "scene": settings.scene.kind.envName,
            "title": settings.scene.kind.title,
            "sceneIn": scene.settings.kind.envName,
            "settled": sceneSettled,
            "scenes": SceneRegistry.kinds.map(\.envName),
            "camera": ["position": xyz(camera.position), "yaw": Double(camera.yaw), "pitch": Double(camera.pitch),
                       "forward": xyz(camera.forward), "fovDegrees": Double(settings.fovDegrees)],
            "time": Double(animTime),
            "paused": settings.paused,
            "frame": Int(frameIndex),
            "gpuMs": smoothedGPUMs,
            "meshes": scene.meshes.count,
            "instances": scene.instances.count,
            "lights": scene.lights.count,
            "materials": scene.materials.count,
            "namedMaterials": scene.namedMaterials.keys.filter { !$0.isEmpty }.sorted(),
            "prefabs": SceneFile.prefabNames,
            "settings": lists,
        ]
        let file = placedPending ?? scene.placed?.file
        state["sceneFile"] = [
            "path": SceneFile.url(for: settings.scene.kind).path,
            "objects": (file?.objects ?? []).map { o -> [String: Any] in
                ["name": o.name, "asset": o.asset, "parent": o.parent, "position": xyz(o.position),
                 "rotation": [Double(o.rotation.imag.x), Double(o.rotation.imag.y), Double(o.rotation.imag.z), Double(o.rotation.real)],
                 "scale": xyz(o.scale), "material": o.material]
            },
            "lights": (file?.lights ?? []).map { l -> [String: Any] in
                ["name": l.name, "kind": "\(l.kind)", "position": xyz(l.position), "direction": xyz(l.direction), "color": xyz(l.color),
                 "size": [Double(l.size.x), Double(l.size.y), Double(l.size.z), Double(l.size.w)]]
            },
        ] as [String: Any]
        if let benchmark, !benchmark.isFinished { state["benchmark"] = benchmark.current.name }
        return state
    }
}
