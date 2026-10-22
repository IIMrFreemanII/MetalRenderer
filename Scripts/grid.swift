// A grid of boxes and balls on the stage, in the stage's colours: the short form (plain statements, run on the render
// thread with `renderer`, `scene` and `run` in scope).
//
//   Tools/script.py Scripts/grid.swift [size]
//
// What it places goes into the stage's scene file (Assets/Scenes/stage.scene). It takes out what it placed before, so
// running it again replaces the grid.
let size = run.arguments.first.flatMap { Int($0) } ?? 5
guard let stage = SceneRegistry.kind(named: "stage") else { run.fail("no stage scene"); return }
if renderer.settings.scene.kind != stage { renderer.settings.scene.kind = stage }
let colours = ["red", "orange", "yellow", "green", "blue", "purple", "white", "metal", "gold"]
renderer.editPlaced { file in
    file.objects.removeAll { $0.name.hasPrefix("Grid ") }
    for x in 0..<size {
        for z in 0..<size {
            let k = x * size + z
            let position = SIMD3<Float>(Float(x) * 2 - Float(size - 1), 0.5, Float(z) * 2 - Float(size - 1))
            file.objects.append(SceneFile.Object(asset: k % 2 == 0 ? "prefab:box" : "prefab:ball", name: "Grid \(x),\(z)",
                                                 position: position, material: colours[k % colours.count]))
        }
    }
}
renderer.camera.position = [0, Float(size) * 1.4, Float(size) * 2.6]
renderer.camera.yaw = 0
renderer.camera.pitch = -0.45
print("placed \(size * size) objects")
