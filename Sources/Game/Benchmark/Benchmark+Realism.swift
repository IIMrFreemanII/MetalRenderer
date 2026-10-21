import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd
import MetalRenderer

/// The realistic look's benchmark modes (SceneSettings.realism): the outdoor scenes from near their ground and their
/// plants, with the look on (`METALRENDERER_SCENE=realism=off` shows the same views without it).
extension Benchmark {
    static let realismModes: [String: () -> [Config]] = ["realism": realism]

    /// The Forest along its trail, under its trees, at its pond's bank and from its clearing; the valley's hills and
    /// stream; the plant and terrain workshops; the open world's woods and start.
    private static func realism() -> [Config] {
        func on(_ name: String, _ kind: SceneKind, gi: GIMode = .radianceCascades) -> Config {
            var scene = SceneSettings(kind: kind)
            scene.realism = .on
            return Config(name, gi: gi, scene: scene).still().frames(60)
        }
        var out: [Config] = []
        let seed: UInt64 = 1
        let hills = NoiseTerrainBase(size: 320, cells: 320, seed: seed, relief: 9, flat: (center: [0, 0], inner: 12, outer: 55))
        func ground(_ x: Float, _ z: Float) -> Float { SceneWaterMaker.height(hills, Double(x), Double(z)) }
        func eye(_ x: Float, _ z: Float, up: Float) -> SIMD3<Float> { [x, ground(x, z) + up, z] }
        out.append(on("forest clearing", .forest))
        // Down the trail, low.
        let t0: Float = -14, t1: Float = -34
        let a = eye(Scene.trail(t0), t0, up: 1.6), b = eye(Scene.trail(t1), t1, up: 0)
        out.append(on("forest trail", .forest).from(lookAt(a, b)))
        // Among the trees, looking down the slope at the litter.
        let c = eye(-60, -70, up: 1.7), d = eye(-48, -84, up: 0)
        out.append(on("forest floor", .forest).from(lookAt(c, d)))
        // The pond's bank.
        let (shapes, _) = Scene.forestWater(hills, seed: seed)
        if let pond = shapes.bowls.first {
            let p = SIMD3(pond.center.x, pond.level, pond.center.y), away = simd_normalize(SIMD3(p.x, 0, p.z))
            let e = eye(p.x + away.x * (pond.radii.x + 6), p.z + away.z * (pond.radii.x + 6), up: 1.7)
            out.append(on("forest pond bank", .forest).from(lookAt(e, p - away * 2)))
        }
        out.append(on("forest closeup", .forest).from({ var c = Camera(); c.position = [-6, 1.6, -9]; c.yaw = -0.5; c.pitch = 0.35; return c }()))
        out.append(on("valley hills", .valley).from(lookAt([-60, 4, 10], [-150, 20, -120])))
        out.append(on("valley stream", .valley).from(lookAt([-95, 6, 60], [-150, 8, 40])))
        out.append(on("plant workshop", .plants))
        // Under the workshop tree's crown looking up into it (the sun through its leaves), and at its trunk.
        out.append(on("plant crown", .plants).from(lookAt([2.2, 1.7, 2.6], [0, 6.5, 0])))
        out.append(on("plant bark", .plants).from(lookAt([0.9, 1.4, 1.1], [0, 1.2, 0])))
        out.append(on("terrain workshop", .terrain, gi: .pathTraced).still(at: 2))
        let w = worldOfRun(), begin = w.start
        var woods = begin.place.x
        while w.woods(woods, begin.place.z) < 0.95 && woods < begin.place.x + 3000 { woods += 16 }
        // (The scene made round the woods' own tile, as the renderer makes it once the camera is there.)
        let side = Double(World.tileSize), tile = SIMD2(Int(((woods + 40) / side).rounded(.down)), Int((begin.place.z / side).rounded(.down)))
        out.append(on("world woods", .world).with { $0.scene.worldTile = tile }
            .from(worldCamera(w, woods + 40, begin.place.z, up: 1.7, yaw: .pi / 2, pitch: -0.1)))
        let meadow = w.start.place.x + 300
        out.append(on("world meadow", .world).with { $0.scene.worldTile = SIMD2(Int((meadow / side).rounded(.down)), tile.y) }
            .from(worldCamera(w, meadow, begin.place.z + 20, up: 1.7, yaw: .pi / 2, pitch: -0.08)))
        out.append(on("world start", .world))
        return out
    }
}
