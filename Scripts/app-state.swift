// The app's state from a script: the scene, the look by the settings' own names (the METALRENDERER_* lists), the
// time of day, the camera; then a picture of the frame.
//
//   Tools/script.py Scripts/app-state.swift [scene]
func run(_ run: ScriptRun) {
    let name = run.arguments.first ?? "sun"
    guard let kind = SceneRegistry.kind(named: name) else {
        run.fail("no scene named \(name); the scenes: \(SceneRegistry.kinds.map(\.envName).joined(separator: ", "))")
        return
    }
    run.render { renderer in
        var s = renderer.settings
        s.scene.kind = kind
        s.applySceneDefaults(from: renderer.defaultSettings)
        renderer.settings = s
    }
    run.waitForScene()
    run.render { renderer in
        // Settings by the names the settings panel's Copy as Env writes (SettingsTable).
        SettingsEnv.apply(.view, to: &renderer.settings, interactive: true, from: ["METALRENDERER_VIEW": "solid=1"])
        renderer.settings.holdDay(hour: 18)
        renderer.camera = renderer.scene.defaultCamera
        print("\(renderer.settings.scene.kind.title): \(renderer.scene.instances.count) instances, \(renderer.scene.lights.count) lights")
    }
    run.wait(frames: 30)
    if let picture = run.capture(scale: 0.5) { print("frame: \(picture.path)") }
    run.render { renderer in
        SettingsEnv.apply(.view, to: &renderer.settings, interactive: true, from: ["METALRENDERER_VIEW": "solid=0"])
    }
}
