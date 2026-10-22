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
/// The camera chases the car on a spring; with the mouse captured, it turns round it.
final class CarPlayer: SceneBehaviour {
    private weak var scene: Scene?
    var captured = false
    var handbrake = false
    var manual = false
    /// The input last sent, and shifts asked for since.
    var sent = CarInput()
    var shiftUp = false, shiftDown = false
    /// The chase camera: turned round the car (yaw, pitch, radians) by the captured mouse; where it is (smoothed).
    var orbit = SIMD2<Float>(0, 0)
    var eye: SIMD3<Float>?
    var message: String?

    /// The chase camera's place behind and above the car (m), what it looks at above the car's middle (its body's
    /// rings' nodes': CarTelemetry.centre), how fast it follows (s).
    static let behind: Float = 6.5, above: Float = 2.2, target: Float = 0.4, lag: Float = 0.12

    init(_ scene: Scene) { self.scene = scene }

    private var player: Int? {
        guard let rig = scene?.carRig, rig.cars.indices.contains(rig.player) else { return nil }
        return rig.cars[rig.player].car
    }

    func keyDown(_ r: Renderer, _ key: String, isRepeat: Bool) -> Bool {
        switch key {
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
        orbit.x -= dx * Camera.turnRate
        orbit.y = min(max(orbit.y - dy * Camera.turnRate, -0.3), 1.1)
    }

    /// The scene as built: the player's commands dropped, time back to 0 (the world replays from its start).
    func restart(_ r: Renderer) {
        r.scene.withPhysics { $0.dropPlayerCommands() }
        sent = CarInput()
        eye = nil
        r.setTime(0)
        message = "Restarted"
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

    /// The chase camera, after the scene has moved: behind the car as this frame draws it.
    func lateUpdate(_ r: Renderer, dt: Float) {
        guard let car = player, r.benchmark?.current.camera == nil, let drawn = r.scene.drawnPhysics, drawn.cars.indices.contains(car) else { return }
        let t = drawn.cars[car]
        // Behind the car (its heading on the ground), turned by the mouse, a little above; easing after it.
        var ahead = SIMD3<Float>(t.forward.x, 0, t.forward.z)
        ahead = length(ahead) > 1e-3 ? normalize(ahead) : [0, 0, 1]
        let turn = simd_quatf(angle: orbit.x, axis: [0, 1, 0])
        let back = turn.act(-ahead)
        let target = t.centre + SIMD3(0, CarPlayer.target, 0)
        let wanted = target + back * (CarPlayer.behind * cos(orbit.y)) + SIMD3(0, CarPlayer.above + CarPlayer.behind * sin(orbit.y), 0)
        let k = 1 - exp(-dt / CarPlayer.lag)
        let smooth = eye.map { $0 + (wanted - $0) * k } ?? wanted
        eye = smooth
        let look = normalize(target - smooth)
        r.camera.position = smooth
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
        lines.append("W/S throttle, brake   A/D steer   Space handbrake")
        lines.append("\(manual ? "Q/E shift   " : "")M \(manual ? "automatic" : "manual")   R restart   \(captured ? "Esc: free the mouse" : "click: turn the camera")")
        if let m = message { lines.append(m) }
        return SceneHUD(lines: lines, corner: .bottomLeft, monospaced: true, capturesMouse: true)
    }
}
