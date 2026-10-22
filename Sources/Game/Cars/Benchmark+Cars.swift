import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import Physics
import Plants
import simd
import MetalRenderer

/// The car scene's benchmark modes (Scene+CarGround.swift): the wall demo paused before, at and after the hit in the solid
/// look and in the full one; what the cars' steps cost on autopilot laps (the `cpu` column).
extension Benchmark {
    static let carModes: [String: () -> [Config]] = [
        "cars": cars, "carsfull": carsFull, "carscpu": carsCPU, "carspaint": carsPaint,
    ]

    /// The wall demo's moments: running up, the hit, crushed and stopped.
    static let carMoments: [Float] = [0.5, 1.1, 1.4, 3]

    private static func carBase(_ name: String) -> Config {
        Config(name, scale: 0.5, upscale: 3, gi: .radianceCascades, scene: SceneSettings(kind: .cars)) {
            $0.scene.cars.demo = .wall
            $0.scene.cars.cars = 1
            $0.solid = true
        }
    }

    /// The wall demo paused at each of its moments in the solid look, from beside the wall, then moving.
    private static func cars() -> [Config] {
        let side = Scene.camera([7.5, 2.4, Scene.carWallZ - 6.5], yaw: -2.25, pitch: -0.16)
        return carMoments.map { t in carBase(String(format: "t%03.1f", t)).from(side).still(at: t) } + [carBase("moving").from(side)]
    }

    /// ...in the full look (GI, reflections, the glass).
    private static func carsFull() -> [Config] {
        let side = Scene.camera([7.5, 2.4, Scene.carWallZ - 6.5], yaw: -2.25, pitch: -0.16)
        return [Float(0.5), 3].map { t in carBase(String(format: "full t%03.1f", t)).with { $0.solid = false }.from(side).still(at: t) }
    }

    /// The player's car standing, close, in the full look: its clear-coated paint (Scene.addPaintMaterial) and glass,
    /// from its front three-quarters and from above its hood, the paint samples beside it (coated in front, plain
    /// metallic behind).
    private static func carsPaint() -> [Config] {
        let front = Scene.camera([3.6, 1.5, -2.6], yaw: -0.62, pitch: -0.12), above = Scene.camera([1.2, 2.6, -3.4], yaw: -0.25, pitch: -0.42)
        return [("paint front", front), ("paint hood", above)].map { name, camera in
            carBase(name).with {
                $0.scene.cars.demo = .none
                $0.solid = false
            }.from(camera).still(at: 2)
        }
    }

    /// The cars' steps moving: 1, 4 and 8 cars on autopilot laps.
    private static func carsCPU() -> [Config] {
        [1, 4, 8].map { n in
            carBase("\(n) car\(n == 1 ? "" : "s") laps").with {
                $0.scene.cars.demo = .laps
                $0.scene.cars.cars = n
            }
        }
    }
}
