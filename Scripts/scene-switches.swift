// Scene switches as the window makes them: every scene once, the heavy pairs back and forth, a switch while another
// loads, scenes made again in place, a jump in time, and pictures of a scene before and after a detour (stale state).
// The scene-switching skill's `scripts/switches.sh` runs it in a headless app and reads the app's log for failures;
// this prints a `STEP` line per step and a `FAIL` line for what it checks itself, `SHOT` lines for the pictures.
//
//   Tools/script.py Scripts/scene-switches.swift [tour|pairs|midload|remake|jump|slow|stale ...] [out=<folder>]
//                                                [settings=<RenderSettings JSON>]
import Foundation

func run(_ run: ScriptRun) {
    func value(_ key: String) -> String? { run.arguments.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } }
    let out = value("out") ?? NSTemporaryDirectory()
    var steps = run.arguments.filter { !$0.contains("=") }
    if steps.isEmpty { steps = ["tour", "pairs", "midload", "remake", "jump", "stale"] }
    // The app's own settings (switches.py --saved: the window's saved copy), unpaused.
    if let path = value("settings") {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var s = try? JSONDecoder().decode(RenderSettings.self, from: data) else { run.fail("can't read settings \(path)"); return }
        s.paused = false
        run.render { $0.settings = s }
        run.waitForScene()
        print("settings from \(path)")
    }

    // The settings a switch to `name` asks for, as the panel's scene popup sets them.
    func ask(_ name: String, _ edit: (inout SceneSettings) -> Void = { _ in }) -> Bool {
        guard let kind = SceneRegistry.kind(named: name) else { run.fail("no scene \(name)"); return false }
        run.render { renderer in
            var s = renderer.settings
            s.scene.kind = kind
            s.scene.extraModels = []
            s.applySceneDefaults(from: renderer.defaultSettings)
            edit(&s.scene)
            renderer.settings = s
        }
        return true
    }
    func go(_ name: String, frames: Int = 60, _ edit: (inout SceneSettings) -> Void = { _ in }) {
        let start = Date()
        guard ask(name, edit) else { return }
        run.waitForScene()
        let shown = run.render { $0.scene.settings.kind.envName }
        if shown != name { print("FAIL \(name): \(shown) drawn instead") }
        run.wait(frames: frames)
        print("  \(name) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }
    func drawn() -> String { run.render { $0.scene.settings.kind.envName } }

    for step in steps {
        print("STEP \(step)")
        switch step {
        case "tour":
            // (The modeller's stage and the painter need their editors; the world and the city are in "pairs".)
            for kind in SceneRegistry.kinds where !["world", "city", "citynight"].contains(kind.envName) {
                go(kind.envName, frames: 120)
            }
        case "pairs":
            for _ in 0..<5 { go("fluids"); go("muscles") }
            for _ in 0..<3 { go("destruction") { $0.destruction.massive = true }; go("cars"); go("stage") }
            for _ in 0..<2 { go("world", frames: 120); go("city", frames: 120) }
        case "midload":
            // Another scene asked for while one loads, then the one drawn asked for again: the loads are dropped.
            go("cornell")
            for (a, b) in [("muscles", "fluids"), ("cars", "showcase"), ("forest", "particles")] {
                _ = ask(a); run.wait(frames: 2)
                _ = ask(b); run.wait(frames: 2)
                _ = ask("cornell")
                run.waitForScene()
                run.wait(frames: 30)
                let now = drawn()
                if now != "cornell" { print("FAIL midload \(a) -> \(b) -> cornell: \(now) drawn") }
                let loading = run.render { $0.loading != nil }
                if loading { print("FAIL midload \(a) -> \(b) -> cornell: still loading") }
            }
            // ...and a third scene asked for during two loads: only it is put in.
            _ = ask("muscles"); run.wait(frames: 2)
            _ = ask("fluids"); run.wait(frames: 2)
            go("cars")
        case "remake":
            // Made again in place well into the scene's clock: a hot reload's remake and a setting of the scene.
            // (The procedural scene: its assets cooked again, as a hot reload of Assets/Procedural or an inspector's edit.)
            for name in ["muscles", "fluids", "softbodies", "procedural"] {
                go(name)
                run.wait(seconds: 15)
                run.render { $0.remakeScene(because: "the switch harness") }
                run.waitForScene()
                run.wait(frames: 60)
                print("  \(name) made again")
            }
            go("cars")
            run.wait(seconds: 15)
            run.render { $0.settings.scene.cars.cars = $0.settings.scene.cars.cars == 4 ? 3 : 4 }
            run.waitForScene()
            run.wait(frames: 60)
            print("  cars made again with another count")
        case "jump":
            // The clock moved far at once (the VFX editor's timeline): the steps catch up over frames.
            for name in ["muscles", "softbodies", "physics", "ragdolls"] {
                go(name)
                run.render { $0.setTime(60) }
                run.wait(frames: 240)
                print("  \(name) after a jump to 60 s")
            }
        case "slow":
            // Physics passes of seconds (switches.py --env METALRENDERER_STEPS_PER_FRAME=500: about 3.7 s a frame in the
            // muscles, past the 2 s the interludes used to wait): the interludes after them wait, none times out.
            go("muscles")
            run.render { $0.setTime(60) }
            run.wait(frames: 60, timeout: 120)
            go("cornell")
            go("muscles", frames: 120)
            print("  muscles after a pass of seconds")
        case "stale":
            // A scene paused at its clock's zero, pictured, then pictured again after a detour through another scene:
            // the two must be the same picture (nothing of the other scene left in it). switches.sh compares them.
            for (name, detour) in [("cornell", "showcase"), ("muscles", "fluids"), ("cars", "destruction"), ("market", "forest")] {
                for pass in ["before", "after"] {
                    if pass == "after" { go(detour) }
                    go(name, frames: 1)
                    run.render { r in r.settings.paused = true; r.setTime(0) }
                    run.wait(frames: 90)
                    let url = run.capture("\(out)/stale-\(name)-\(pass).png", scale: 0.5)
                    print("SHOT \(name) \(pass) \(url?.path ?? "none")")
                    run.render { $0.settings.paused = false }
                }
            }
        default:
            print("FAIL unknown step \(step)")
        }
    }
    print("STEP done")
}
