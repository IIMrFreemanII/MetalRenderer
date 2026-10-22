// A tower built a storey at a time, each storey on screen before the next: the full form (`func run`, on its own
// thread, so it can wait between its steps). Then a ball circles it, moved every frame (`run.onFrame`) until the
// script runs again.
//
//   Tools/script.py Scripts/build-up.swift [storeys]
func run(_ run: ScriptRun) {
    let storeys = run.arguments.first.flatMap { Int($0) } ?? 6
    run.render { renderer in
        if let stage = SceneRegistry.kind(named: "stage") { renderer.settings.scene.kind = stage }
        renderer.camera.position = [0, 6, 16]
        renderer.camera.yaw = 0
        renderer.camera.pitch = -0.25
    }
    run.waitForScene()
    run.render { renderer in renderer.editPlaced { $0.objects.removeAll { $0.name.hasPrefix("Tower ") } } }
    run.waitForScene()
    for storey in 0..<storeys {
        let started = Date()
        run.render { renderer in
            renderer.editPlaced { file in
                for (k, corner) in [SIMD2<Float>(-1, -1), [1, -1], [1, 1], [-1, 1]].enumerated() {
                    file.objects.append(SceneFile.Object(asset: "prefab:box", name: "Tower \(storey) post \(k)",
                                                         position: SIMD3(corner.x * 1.5, Float(storey) * 1.2 + 0.5, corner.y * 1.5),
                                                         scale: [0.3, 1, 0.3], material: "stone"))
                }
                file.objects.append(SceneFile.Object(asset: "prefab:box", name: "Tower \(storey) floor",
                                                     position: [0, Float(storey) * 1.2 + 1.1, 0], scale: [3.6, 0.2, 3.6],
                                                     material: storey % 2 == 0 ? "wood" : "white"))
            }
        }
        run.waitForScene()
        print("storey \(storey + 1) of \(storeys) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }
    // The ball: placed once, then moved live every frame (a move needs no new scene).
    run.render { renderer in
        renderer.editPlaced { $0.objects.append(SceneFile.Object(asset: "prefab:ball", name: "Tower ball", position: [4, 1, 0], material: "gold")) }
    }
    run.waitForScene()
    var angle: Float = 0
    run.onFrame { renderer, dt in
        angle += dt
        let height = Float(storeys) * 0.6
        renderer.editPlaced(save: false) { file in   // moved live, not written every frame
            guard let k = file.objects.firstIndex(where: { $0.name == "Tower ball" }) else { return }
            file.objects[k].position = [4 * cos(angle), height + sin(angle * 2), 4 * sin(angle)]
        }
    }
    print("the ball circles the tower until this script runs again")
}
