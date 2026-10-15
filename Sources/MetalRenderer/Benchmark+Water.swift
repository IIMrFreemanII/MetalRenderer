import Foundation
import simd

/// The water's benchmark modes (Shaders/Water.metal): the workshop's terrains with a sea, a lake and a river, seen
/// close from their shores and from above; the camera under the water; the open world's; and what water costs a frame.
extension Benchmark {
    static let waterModes: [String: () -> [Config]] = [
        "water": waterShots, "waterunder": waterUnder, "waterperf": waterPerf,
    ]

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
        s.terrainWorkshop = TerrainWorkshopSettings(size: size, base: base, seed: seed, document: "bench-\(name)")
        var c = Config(name, scale: 0.75, gi: .pathTraced, scene: s).still(at: 2)
        c.events = [(0, .terrain([.mode(true)] + steps + [.document { $0.water = bodies }] + carve.map { .carveRiver($0) }
                                  + [.wait(2), .mode(false), .rebuild, .wait(40)]))]
        return c
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
                + Array(repeating: TerrainStep.strokeWorld((0...24).map { SIMD2(60 + 25 * cos(Double($0) / 24 * 2 * .pi), -40 + 25 * sin(Double($0) / 24 * 2 * .pi)) }),
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
                + Array(repeating: TerrainStep.strokeWorld((0...24).map { SIMD2(30 + 12 * cos(Double($0) / 24 * 2 * .pi), -30 + 12 * sin(Double($0) / 24 * 2 * .pi)) }),
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
                + [TerrainStep.strokeWorld((0...24).map { SIMD2(30 + 12 * cos(Double($0) / 24 * 2 * .pi), -30 + 12 * sin(Double($0) / 24 * 2 * .pi)) })]
            var c = waterWorkshop(name, size: .m512, base: .flat, steps: raise, bodies: [WaterBody(name: "Sea", kind: .sea, level: level)])
            c.camera = camera
            return c
        }
        return [lagoon("water-under", level: 4, lookAt([0, 1.5, 0], [20, 1.2, -20])),
                lagoon("water-window", level: 4, lookAt([0, 1, 0], [3, 6, -3])),
                lagoon("water-waterline", level: 4, lookAt([0, 4.05, 0], [20, 4, -20]))]
    }
}
