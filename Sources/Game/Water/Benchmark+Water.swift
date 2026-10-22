import Characters
import EngineCore
import Foundation
import Physics
import Plants
import simd
import MetalRenderer

/// The water's benchmark modes (Shaders/Water.metal): the workshop's terrains with a sea, a lake and a river, seen
/// close from their shores and from above; the camera under the water; the open world's; and what water costs a frame.
extension Benchmark {
    static let waterModes: [String: () -> [Config]] = [
        "water": waterShots, "waterunder": waterUnder, "waterperf": waterPerf, "waterscenes": waterScenes,
    ]

    /// Each scene's own water, seen from near it: the Forest's pond and stream, the valley's lake, the city's canal,
    /// the workshops' and squares' pools (cameras from the same generators, so they follow the seed).
    private static func waterScenes() -> [Config] {
        var out: [Config] = []
        // The Forest's pond, from its far side toward the clearing.
        let seed: UInt64 = 1
        let hills = NoiseTerrainBase(size: 320, cells: 320, seed: seed, relief: 9, flat: (center: [0, 0], inner: 12, outer: 55))
        let (shapes, _) = Scene.forestWater(hills, seed: seed)
        if let pond = shapes.bowls.first {
            let c = SIMD3(pond.center.x, pond.level, pond.center.y), away = simd_normalize(SIMD3(c.x, 0, c.z))
            var forest = Config("forest pond", gi: .radianceCascades, scene: SceneSettings(kind: .forest)).still().frames(60)
            var eye = c + away * (pond.radii.x + 10)
            eye.y = SceneWaterMaker.height(hills, Double(eye.x), Double(eye.z)) + 2.5
            forest.camera = lookAt(eye, c - away * 4)
            out.append(forest)
        }
        // The valley's lake by the village, and its stream coming down the western hill.
        let valley = Config("valley lake", gi: .radianceCascades, scene: SceneSettings(kind: .valley)).still().frames(60)
        out.append(valley.from(lookAt([-8, 3.5, 44], [-34, 0, 22])))
        out.append(valley.named("valley stream").from(lookAt([-95, 6, 60], [-150, 8, 40])))
        // The city's canal, along it from above a quay, by day and by night.
        if let canal = CityPlan(CitySettings(), seed: 1).canal {
            let w = canal.water, eye = SIMD3<Float>(w.lo.x + 30, 4, w.lo.y - 2), at = SIMD3<Float>(w.lo.x + 110, -1, w.center.y)
            out.append(Config("city canal", gi: .radianceCascades, scene: SceneSettings(kind: .city)).still().frames(60).from(lookAt(eye, at)))
            out.append(Config("city canal night", gi: .radianceCascades, scene: SceneSettings(kind: .cityNight)).still().frames(60).from(lookAt(eye, at)))
        }
        // The terrain workshop as it starts: hills with a sea round them, from its own camera.
        out.append(Config("workshop sea", gi: .pathTraced, scene: SceneSettings(kind: .terrain)).still(at: 2))
        // The plant and building workshops on their ground (the plants' pond behind them), from their own cameras.
        out.append(Config("plant workshop", gi: .radianceCascades, scene: SceneSettings(kind: .plants)).still().frames(60))
        out.append(Config("plant workshop pond", gi: .radianceCascades, scene: SceneSettings(kind: .plants)).still().frames(60)
            .from(lookAt([-10, 6, -4], [5, -0.5, -30])))
        out.append(Config("building workshop", gi: .radianceCascades, scene: SceneSettings(kind: .buildings)).still().frames(60))
        out.append(Config("building workshop ground", gi: .radianceCascades, scene: SceneSettings(kind: .buildings)).still().frames(60)
            .from(lookAt([-90, 30, 120], [0, 0, 0])))
        // The crowd's fountain and the courtyard's pool, from their scenes' cameras, and the courtyard's from near it.
        out.append(Config("crowd fountain", gi: .radianceCascades, scene: SceneSettings(kind: .crowd)).still().frames(60))
        var few = SceneSettings(kind: .crowd)
        few.characters = 40
        out.append(Config("crowd fountain near", gi: .radianceCascades, scene: few).still().frames(60).from(lookAt([6, 2.4, 0], [0, 0.3, -6])))
        out.append(Config("sun pool", gi: .radianceCascades, scene: SceneSettings(kind: .sun)).still().frames(60))
        out.append(Config("sun pool near", gi: .radianceCascades, scene: SceneSettings(kind: .sun)).still().frames(60)
            .from(lookAt([1.5, 1.8, 5.5], [-3, 0.4, 0.5])))
        return out
    }

    /// What water costs a frame with everything moving: the waves, the camera flying low along the coast (the near
    /// patch following it, half the reflections taken from the frame before), and the camera under the waves.
    private static func waterPerf() -> [Config] {
        var flying = waterWorkshop("water-flying", bodies: [WaterBody(name: "Sea", kind: .sea, level: 3)]).moving().flying([4, 0, -3])
        flying.camera = lookAt([-60, 7, 40], [80, 2, -60])
        flying.capturePrevious = true
        var waves = waterWorkshop("water-waves", bodies: [WaterBody(name: "Sea", kind: .sea, level: 3)]).moving()
        waves.camera = lookAt([-30, 6, 10], [60, 3.2, -60])
        var off = waves
        off.name = "water-off"
        off.settings.scene.terrainWorkshop.document = "bench-water-off"
        off.events = []
        return [flying, waves, off]
    }

    /// A camera at `eye` looking at `at`.
    static func lookAt(_ eye: SIMD3<Float>, _ at: SIMD3<Float>) -> Camera {
        let n = simd_normalize(at - eye)
        return Scene.camera(eye, yaw: atan2(n.x, -n.z), pitch: asin(n.y))
    }

    /// The workshop with `bodies` on it (its document `bench-<name>`), made again once they are set.
    static func waterWorkshop(_ name: String, size: TerrainWorkshopSettings.Size = .km1, base: TerrainWorkshopSettings.Base = .hills,
                              seed: Int = 1, steps: [TerrainStep] = [], bodies: [WaterBody], carve: [Int] = []) -> Config {
        var s = SceneSettings(kind: .terrain)
        s.terrainWorkshop = TerrainWorkshopSettings(size: size, base: base, seed: seed, document: "bench-\(name)", sea: false)
        var c = Config(name, scale: 0.75, gi: .pathTraced, scene: s).still(at: 2)
        c.events = [(0, .terrain([.mode(true)] + steps + [.document { $0.water = bodies }] + carve.map { .carveRiver($0) }
                                  + [.wait(2), .mode(false), .rebuild, .wait(40)]))]
        return c
    }

    /// 25 points around a circle, the first and the last the same. Spelled out with its types: as one expression in a
    /// `map` closure, `SIMD2` with literals and `cos` made the type checker take seconds over each call.
    private static func ring(_ x: Double, _ z: Double, radius: Double) -> [SIMD2<Double>] {
        (0...24).map { (k: Int) -> SIMD2<Double> in
            let a: Double = Double(k) / 24 * 2 * Double.pi
            return SIMD2<Double>(x + radius * cos(a), z + radius * sin(a))
        }
    }

    private static func waterShots() -> [Config] {
        // A sea over the hills' lowland: islands, a shore with shallows.
        func coast(_ name: String, _ camera: Camera) -> Config {
            var c = waterWorkshop(name, bodies: [WaterBody(name: "Sea", kind: .sea, level: 3)])
            c.camera = camera
            return c
        }
        // A lake dug into the flat ground, a river carved into it.
        func lake(_ name: String, _ camera: Camera) -> Config {
            let dig: [TerrainStep] = [.brush(TerrainBrush(tool: .lower, radius: 45, strength: 1))]
                + Array(repeating: TerrainStep.strokeWorld(ring(60, -40, radius: 25)),
                        count: 3)
            let river = WaterBody(name: "River", kind: .river, points: (0..<30).map { SIMD2(-200 + 260 * Double($0) / 29, -150 + 110 * Double($0) / 29) },
                                  width: 12, depth: 2.5)
            var c = waterWorkshop(name, size: .m512, base: .flat, steps: dig,
                                  bodies: [river, WaterBody(name: "Lake", kind: .lake, level: -1, seed: [60, -40])], carve: [0])
            c.camera = camera
            return c
        }
        // A lagoon: flat sand under a metre and a half of clear sea, an island raised in it.
        func lagoon(_ name: String, _ camera: Camera) -> Config {
            let raise: [TerrainStep] = [.brush(TerrainBrush(tool: .raise, radius: 30, strength: 1))]
                + Array(repeating: TerrainStep.strokeWorld(ring(30, -30, radius: 12)),
                        count: 2)
            var c = waterWorkshop(name, size: .m512, base: .flat, steps: raise, bodies: [WaterBody(name: "Sea", kind: .sea, level: 1.5)])
            c.camera = camera
            return c
        }
        return [lagoon("water-lagoon", lookAt([0, 5, 0], [10, 0, -10])), coast("water-coast", lookAt([-60, 9, 40], [80, 2, -60])), coast("water-above", lookAt([-40, 60, 60], [40, 0, -20])),
                coast("water-swell", lookAt([-30, 6, 10], [60, 3.2, -60])), coast("water-shallow", lookAt([-60, 7, 40], [-52, 2, 28])),
                lake("water-lake", lookAt([20, 4, -2], [70, -2, -45])), lake("water-river", lookAt([-120, 5, -95], [-60, -1, -75])),
                lake("water-top", Scene.camera([-40, 160, -70], yaw: 0, pitch: -1.5))]
    }

    /// The camera under the sea: looking along the lagoon's sandy bed, up at the surface (Snell's window), and with
    /// the waterline across the picture.
    private static func waterUnder() -> [Config] {
        func lagoon(_ name: String, level: Float, _ camera: Camera) -> Config {
            let raise: [TerrainStep] = [.brush(TerrainBrush(tool: .raise, radius: 30, strength: 0.5))]
                + [TerrainStep.strokeWorld(ring(30, -30, radius: 12))]
            var c = waterWorkshop(name, size: .m512, base: .flat, steps: raise, bodies: [WaterBody(name: "Sea", kind: .sea, level: level)])
            c.camera = camera
            return c
        }
        return [lagoon("water-under", level: 4, lookAt([0, 1.5, 0], [20, 1.2, -20])),
                lagoon("water-window", level: 4, lookAt([0, 1, 0], [3, 6, -3])),
                lagoon("water-waterline", level: 4, lookAt([0, 4.05, 0], [20, 4, -20]))]
    }
}
