import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Landscape
import Materials
import MetalRenderer
import Physics
import Plants
import simd

/// The car scene's player (Scene+CarGround.swift; the car's physics is Physics+Cars.swift): W and S throttle and brake
/// (reverse from a stop), A and D steer, Space the handbrake, Q and E shift down and up (M: manual or automatic), R the
/// scene again from the start. The keys go to the physics as `car` commands (Scene.physicsCommand: with the next
/// frame's steps), sent when they change, so a replay drives the same; the physics ramps the pedals and the steering.
/// The camera chases the car on a spring; with the mouse captured, it turns round it; C goes round the others
/// (CarCameras.swift). T slows time (1×, ½, ¼, 1/10).
final class CarPlayer: SceneBehaviour {
    private weak var scene: Scene?
    var captured = false
    var handbrake = false
    var manual = false
    /// The input last sent, and shifts asked for since.
    var sent = CarInput()
    var shiftUp = false, shiftDown = false
    /// The camera, and each style's spec (fitted to its model: where the hood's and the driver's eyes are).
    var camera = CarCameraRig()
    private var specs: [CarStyle: CarSpec] = [:]
    /// The slow motion (an index into `speeds`).
    var speed = 0
    var message: String?

    /// The crash demos' director (CarDirector.swift), until a key is pressed.
    var director: CarDirector?

    static let speeds: [Float] = [1, 0.5, 0.25, 0.1]

    init(_ scene: Scene) {
        self.scene = scene
        director = scene.settings.cars.demo.crashes ? CarDirector() : nil
    }

    private var player: Int? {
        guard let rig = scene?.carRig, rig.cars.indices.contains(rig.player) else { return nil }
        return rig.cars[rig.player].car
    }

    var timeScale: Float { director?.timeScale ?? CarPlayer.speeds[speed] }

    func keyDown(_ r: Renderer, _ key: String, isRepeat: Bool) -> Bool {
        if key != "r" { director = nil }   // (the player's from now on; R plays the demo again, directed)
        switch key {
        case "c":
            if !isRepeat {
                camera.next()
                r.cut()
                message = "Camera: \(camera.mode.title)"
            }
            return true
        case "t":
            if !isRepeat {
                speed = (speed + 1) % CarPlayer.speeds.count
                message = speed == 0 ? "Real time" : "Slow motion: \(speedTitle)"
            }
            return true
        case " ":
            handbrake = true
            return true
        case "q", "e":
            guard !isRepeat else { return true }
            if manual {
                if key == "e" { shiftUp = true } else { shiftDown = true }
            } else {
                message = "Automatic: M for manual gears"
            }
            return true
        case "m":
            if !isRepeat {
                manual.toggle()
                message = manual ? "Manual: Q down, E up" : "Automatic"
            }
            return true
        case "r":
            if !isRepeat { restart(r) }
            return true
        default:
            return false   // (W A S D into the held keys)
        }
    }

    func keyUp(_ r: Renderer, _ key: String) {
        if key == " " { handbrake = false }
    }

    func look(_ r: Renderer, dx: Float, dy: Float) {
        camera.orbit.x -= dx * Camera.turnRate
        camera.orbit.y = min(max(camera.orbit.y - dy * Camera.turnRate, -0.3), 1.1)
    }

    /// The scene as built: the player's commands dropped, time back to 0 (the world replays from its start).
    func restart(_ r: Renderer) {
        r.scene.withPhysics { $0.dropPlayerCommands() }
        sent = CarInput()
        camera = CarCameraRig()
        director = r.scene.settings.cars.demo.crashes ? CarDirector() : nil
        r.setTime(0)
        message = "Restarted"
    }

    private var speedTitle: String { ["1×", "½×", "¼×", "1/10×"][speed] }

    /// Style `style`'s spec as its cars are built (once a style).
    private func spec(_ style: CarStyle) -> CarSpec {
        if let s = specs[style] { return s }
        let s = Scene.carSpec(style)
        specs[style] = s
        return s
    }

    /// A frame: the keys as the car's input (sent when they change); true while the chase camera has the view.
    func update(_ r: Renderer, dt: Float) -> Bool {
        guard let car = player else { return false }
        var input = CarInput()
        let up = Renderer.arrowKeys[0], down = Renderer.arrowKeys[1], left = Renderer.arrowKeys[2], right = Renderer.arrowKeys[3]
        input.accelerate = r.heldKeys.contains("w") || r.heldKeys.contains(up) ? 1 : 0
        input.decelerate = r.heldKeys.contains("s") || r.heldKeys.contains(down) ? 1 : 0
        input.steer = (r.heldKeys.contains("a") || r.heldKeys.contains(left) ? 1 : 0) - (r.heldKeys.contains("d") || r.heldKeys.contains(right) ? 1 : 0)
        input.handbrake = handbrake ? 1 : 0
        input.manual = manual
        if input != sent || shiftUp || shiftDown {
            r.scene.physicsCommand(PhysicsWorld.carCommand(car, input, shiftUp: shiftUp, shiftDown: shiftDown))
            sent = input
            shiftUp = false
            shiftDown = false
        }
        // (A benchmark's fixed camera stays where it is.) The chase camera itself once the scene has moved: lateUpdate.
        return r.benchmark?.current.camera == nil
    }

    /// The camera, after the scene has moved: on the car as this frame draws it.
    func lateUpdate(_ r: Renderer, dt: Float) {
        guard let player, r.benchmark?.current.camera == nil, let drawn = r.scene.drawnPhysics, drawn.cars.indices.contains(player),
              let rig = scene?.carRig, rig.cars.indices.contains(rig.player) else { return }
        let t = drawn.cars[player], spec = spec(rig.cars[rig.player].style)
        director?.update(t, time: Float(drawn.stepIndex) * PhysicsWorld.stepLength)
        let (eye, look) = camera.place(t, spec: spec, dt: dt)
        r.camera.position = eye
        r.camera.yaw = atan2(look.x, -look.z)
        r.camera.pitch = asin(simd_clamp(look.y, -1, 1))
    }

    /// Speed, gear and revs in the bottom-left corner, the damage, and the keys.
    var hud: SceneHUD? {
        guard let car = player, let drawn = scene?.drawnPhysics, drawn.cars.indices.contains(car) else { return nil }
        let t = drawn.cars[car]
        let gear = t.gear < 0 ? "R" : t.gear == 0 ? "N" : "\(t.gear)"
        var lines = [String(format: "%3.0f km/h   %@   %4.0f rpm", abs(t.speed) * 3.6, gear, t.rpm)]
        if t.bent > 0 || t.broken > 0 { lines.append("damage: \(t.bent) beams bent, \(t.broken) broken") }
        var off: [String] = []
        if t.partsOff > 0 { off.append("\(t.partsOff) part\(t.partsOff == 1 ? "" : "s") off") }
        if t.wheelsOff > 0 { off.append("\(t.wheelsOff) wheel\(t.wheelsOff == 1 ? "" : "s") off") }
        if t.panesBroken > 0 { off.append("\(t.panesBroken) glass broken") }
        if !off.isEmpty { lines.append(off.joined(separator: ", ")) }
        if !t.running {
            lines.append("engine: seized")
        } else if t.coolant < 1 || t.engineDamage > 0 {
            lines.append(String(format: "engine: coolant %.0f%%, heat %.0f%%, damage %.0f%%", t.coolant * 100, t.heat * 100, t.engineDamage * 100))
        }
        if director?.stage == .slow {
            lines.insert("SLOW MOTION \(CarDirector.slow)×", at: 0)
        } else if speed != 0 {
            lines.insert("SLOW MOTION \(speedTitle)", at: 0)
        }
        lines.append("W/S throttle, brake   A/D steer   Space handbrake")
        lines.append("\(manual ? "Q/E shift   " : "")M \(manual ? "automatic" : "manual")   R restart   \(captured ? "Esc: free the mouse" : "click: turn the camera")")
        lines.append("C camera: \(camera.mode.title)   T slow motion")
        if director != nil { lines.append("Demo: any key to take the wheel") }
        if let m = message { lines.append(m) }
        return SceneHUD(lines: lines, corner: .bottomLeft, monospaced: true, capturesMouse: true)
    }
}
