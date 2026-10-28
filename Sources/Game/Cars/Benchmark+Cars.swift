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
/// look and in the full one; what the cars' steps cost on autopilot laps (the `cpu` column), on the CPU and on the GPU (the
/// `physics` pass; `METALRENDERER_PHYSICS_PARTS=1` times the cars' kernels apart as `phys cars`).
extension Benchmark {
    static let carModes: [String: () -> [Config]] = [
        "cars": cars, "carsfull": carsFull, "carscpu": carsCPU, "carsgpu": carsGPU, "carsmanycpu": carsManyCPU, "carsmanygpu": carsManyGPU, "carspaint": carsPaint, "carsmodels": carsModels, "carsdamage": carsDamage,
        "carscrash": carsCrash, "carscams": carsCams, "carsvideo": carsVideo,
    ]

    /// Each model's cockpit (CarPack.Entry.eye), then each camera (CarCameras.swift: C goes round them) on the
    /// player's car standing, in the full look. (A scene and its player stay from one setting to the next while its
    /// settings do: a new style's starts at the chase camera, one C each after it.)
    private static func carsCams() -> [Config] {
        let base = { (name: String, style: CarStyle) in
            carBase(name).with {
                $0.scene.cars.demo = .none
                $0.scene.cars.style = style
                $0.solid = false
            }.still(at: 2)
        }
        return CarStyle.allCases.map { base("cockpit \($0)", $0).at(0, .key("c")).at(0, .key("c")) }
            + CarCamera.allCases.map { cam in
                cam == .chase ? base("camera chase", .civic) : base("camera \(cam.title.lowercased())", .civic).at(0, .key("c"))
            }
    }

    /// Phase 3's crashes and the wall as their director films them (CarDirector.swift: the run-up, the crash in slow
    /// motion from the hit, real time again), for `video.sh -m carsvideo`: one mp4 each.
    private static func carsVideo() -> [Config] {
        let demos: [(String, CarSettings.Demo, Float, Int)] = [
            ("wall", .wall, 50, 1), ("head on", .headOn, 50, 2), ("brick wall", .breakables, 50, 1), ("crates", .props, 40, 1),
        ]
        return demos.map { name, demo, kmh, cars in
            var c = carBase("video \(name)").with {
                $0.scene.cars.demo = demo
                $0.scene.cars.demoSpeed = kmh
                $0.scene.cars.cars = cars
                $0.solid = false
            }.recording().frames(480)
            c.startTime = -1   // (the warm-up's second: the clock at 0 on the first recorded frame)
            return c
        }
    }

    /// Phase 3's crashes in the full look, each before, as and after it hits: two cars head on at 50 km/h each, the
    /// player's car through the brick wall at 50 and into the crates at 40 (CarContacts.swift, Physics+Cars).
    private static func carsCrash() -> [Config] {
        let headOn = Scene.camera([9, 2.4, 8], yaw: -.pi / 2, pitch: -0.14)
        let wall = Scene.camera([16.5, 2.4, 29.5], yaw: 2.45, pitch: -0.14)
        let crates = Scene.camera([-0.5, 2.2, 25.5], yaw: -2.39, pitch: -0.14)
        let shots: [(String, CarSettings.Demo, Float, Int, Camera, [Float])] = [
            ("head on", .headOn, 50, 2, headOn, [0.6, 1.0, 3]), ("brick wall", .breakables, 50, 1, wall, [0.2, 0.6, 3]),
            ("crates", .props, 40, 1, crates, [0.5, 0.9, 3]),
        ]
        return shots.flatMap { name, demo, kmh, cars, camera, times in
            times.map { t in
                carBase(String(format: "%@ t%03.1f", name, t)).with {
                    $0.scene.cars.demo = demo
                    $0.scene.cars.demoSpeed = kmh
                    $0.scene.cars.cars = cars
                    $0.solid = false
                }.from(camera).still(at: t)
            }
        }
    }

    /// The wall demo's damage in the full look, close (CarDamage.swift): at 50 km/h just after the hit (the shards, the
    /// steam) and stopped, and at 100 km/h stopped (the smoke), from the front three-quarters by the wall.
    private static func carsDamage() -> [Config] {
        let near = Scene.camera([4.2, 1.9, Scene.carWallZ - 4.8], yaw: -2.3, pitch: -0.2)
        return [(Float(50), Float(1.4)), (50, 4), (100, 4)].map { kmh, t in
            carBase(String(format: "damage %.0f t%03.1f", kmh, t)).with {
                $0.scene.cars.demoSpeed = kmh
                $0.solid = false
            }.from(near).still(at: t)
        }
    }

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

    /// Every car (its model: CarPack) standing, in the full look: the three parked from beside the lot, then each close
    /// as the player's, from its front three-quarters and from its rear three-quarters.
    private static func carsModels() -> [Config] {
        let lot = Scene.camera([21, 4.5, -8], yaw: 0.56, pitch: -0.2), front = Scene.camera([3.6, 1.5, -2.6], yaw: -0.62, pitch: -0.12)
        let rear = Scene.camera([-3.4, 1.5, -13.2], yaw: 2.5, pitch: -0.12)
        let shots = [("lot", CarStyle.civic, lot)] + CarStyle.allCases.flatMap { style in
            [("\(style) front", style, front), ("\(style) rear", style, rear)]
        }
        return shots.map { name, style, camera in
            carBase(name).with {
                $0.scene.cars.demo = .none
                $0.scene.cars.cars = 4
                $0.scene.cars.style = style
                $0.solid = false
            }.from(camera).still(at: 2)
        }
    }

    /// ...on the GPU (CarsGPU.swift), its rows named as the CPU's (`ab.sh` puts one against the other).
    private static func carsGPU() -> [Config] {
        carsCPU().map { $0.with { $0.scene.physics.backend = .gpu } }
    }

    /// A load: 8, 16 and 32 cars on laps, alone and round a field of 24 breakable walls (standing: the cars lap round
    /// them), on the CPU and on the GPU.
    private static func carsManyCPU() -> [Config] {
        [0, 24].flatMap { walls in
            [8, 16, 32].map { n in
                carBase("\(n) cars\(walls > 0 ? " walls" : "")").with {
                    $0.scene.cars.demo = .laps
                    $0.scene.cars.cars = n
                    $0.scene.cars.walls = walls
                }
            }
        }
    }

    private static func carsManyGPU() -> [Config] {
        carsManyCPU().map { $0.with { $0.scene.physics.backend = .gpu } }
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
