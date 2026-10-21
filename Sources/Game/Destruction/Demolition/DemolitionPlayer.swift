import Foundation
import MetalRenderer
import simd

/// What the left button does in the demolition scene (keys 1 to 4).
enum DemolitionTool: Int, CaseIterable {
    case machineGun, rocket, tnt, grab

    var title: String { ["Machine gun", "Rocket launcher", "TNT", "Grab"][rawValue] }
    var help: String {
        ["hold to fire: bullets chip what they hit", "click: a rocket that goes off where it hits",
         "click: a charge on what you aim at; right click sets them all off", "drag a piece about (the cursor is free)"][rawValue]
    }
}

/// The demolition scene's player (Scene+Demolition.swift; its physics is Physics+Demolition.swift's): the tool in hand,
/// the walker, the captured mouse. What it does goes to the physics as commands (Scene.physicsCommand: with the next
/// frame's steps, without waiting for those running), so a replay does them again; aiming reads the poses drawn this
/// frame. Made with the scene (SceneDefinition.behaviour), on the render thread after.
final class DemolitionPlayer: SceneBehaviour {
    /// The scene it plays (its rig: the charges stuck).
    private weak var scene: Scene?
    var tool = DemolitionTool.machineGun
    /// The mouse turns the camera (RenderView.captured); the crosshair aims.
    var captured = false {
        didSet { if !captured { firing = false } }
    }
    /// Walking: the camera is the walker's eyes (Physics+Demolition.swift's capsule).
    var walking = false
    var firing = false
    /// Seconds to the machine gun's next bullet, and the spread's random state.
    var reload: Float = 0
    var random: UInt64 = 0x5EED_DE40
    /// The walker's input last sent (its speed over the ground, x and z), a jump asked for, where its eyes were.
    var sentSpeed = SIMD2<Float>(repeating: .nan)
    var jump = false
    var eye: SIMD3<Float>?
    var message: String?

    /// The machine gun's rate (bullets a second), a bullet's push (N s) and spread (radians); a rocket's speed (m/s)
    /// and blast (m); TNT's blast (m, m/s at its middle), and how many charges stay stuck at once.
    static let fireRate: Float = 12, bulletImpulse: Float = 25, spread: Float = 0.007
    static let rocketSpeed: Float = 28, rocketBlast: Float = 2.5
    static let tntRadius: Float = 1.8, tntPush: Float = 18
    /// The walker's speeds (m/s) and its eyes above its middle (m).
    static let walkSpeed: Float = 3, runSpeed: Float = 5.5, jumpSpeed: Float = 4.5, eyeHeight: Float = 0.78

    init(_ scene: Scene) { self.scene = scene }

    func mouseUp(_ r: Renderer) { firing = false }

    /// The right button, the mouse captured: every charge goes off.
    func rightMouseDown(_ r: Renderer) -> Bool {
        guard captured else { return false }
        detonateCharges(r)
        return true
    }

    /// The captured mouse turns the camera (the walker's head, or the flying camera).
    func look(_ r: Renderer, dx: Float, dy: Float) {
        r.camera.yaw += dx * Camera.turnRate
        r.camera.pitch = min(max(r.camera.pitch - dy * Camera.turnRate, -1.5), 1.5)
    }

    /// The crosshair while the mouse is captured, and a box in the bottom-left corner with the tools (the one in hand
    /// lit), the charges stuck, walking or flying, and the keys. A click captures the mouse but with Grab.
    var hud: SceneHUD? {
        let charges = scene?.demolitionRig?.placed.count ?? 0
        var lines = DemolitionTool.allCases.map { t in "\(t == tool ? "▶" : " ") \(t.rawValue + 1) \(t.title)" }
        lines.append("")
        lines.append(tool.help)
        if charges > 0 { lines.append("TNT stuck: \(charges)  (right click: off, Delete: take off)") }
        lines.append(walking ? "Walking  (Shift-V: fly)" : "Flying  (Shift-V: walk)")
        lines.append(captured ? "Esc: free the mouse   R: restart" : "Click in the view to aim   R: restart")
        if let m = message { lines.append(m) }
        return SceneHUD(lines: lines, corner: .bottomLeft, monospaced: true, crosshair: captured, capturesMouse: tool != .grab)
    }

    /// The scene's keys: 1 to 4 the tools, Shift-V (as `v`) walks or flies, Space jumps while walking, Return puts the
    /// walker back where it last stood, Delete takes the charges off, R starts the office again.
    func keyDown(_ r: Renderer, _ key: String, isRepeat: Bool) -> Bool {
        switch key {
        case "1", "2", "3", "4":
            guard !isRepeat else { return true }
            tool = DemolitionTool(rawValue: Int(key)! - 1)!
            firing = false
            message = nil
            return true
        case "v":
            if !isRepeat { setWalking(r, !walking) }
            return true
        case " ":
            guard walking else { return false }
            jump = true
            return true
        case "\r":
            guard walking, !isRepeat, let rig = r.scene.demolitionRig else { return walking }
            drive(r, flags: DemolitionState.Walker.placeFlag, place: rig.spawn)
            return true
        case "\u{7f}":
            r.scene.demolitionRig?.placed.removeAll()
            return true
        case "r":
            guard !isRepeat else { return true }
            restart(r)
            return true
        default:
            return false
        }
    }

    /// The office as it was built: the player's commands dropped, time back to 0 (the world replays from its start).
    func restart(_ r: Renderer) {
        r.scene.withPhysics { $0.dropPlayerCommands() }
        r.scene.demolitionRig?.placed.removeAll()
        walking = false
        eye = nil
        sentSpeed = SIMD2(repeating: .nan)
        r.setTime(0)
        message = "Restarted"
    }

    /// A press: fires the tool (the machine gun until the release). Not with Grab, or with the cursor free.
    func mouseDown(_ r: Renderer) -> Bool {
        guard captured, tool != .grab else { return false }
        switch tool {
        case .machineGun:
            firing = true
            reload = 0
        case .rocket: fireRocket(r)
        case .tnt: placeCharge(r)
        case .grab: break
        }
        return true
    }

    /// A frame: the machine gun's bullets, the walker's input and the camera at its eyes. True when the camera is the
    /// walker's (the frame's other camera moves are off).
    func update(_ r: Renderer, dt: Float) -> Bool {
        if firing && tool == .machineGun {
            reload -= dt
            var shots = 0
            while reload <= 0 && shots < 4 {
                fireBullet(r)
                reload += 1 / DemolitionPlayer.fireRate
                shots += 1
            }
            if reload < 0 { reload = 0 }
        }
        guard walking else { return false }
        walk(r, dt)
        return true
    }

    // MARK: Aiming

    /// Where the crosshair (or, with the cursor free, the view's middle) points: a ray from the camera.
    private func aim(_ r: Renderer) -> SIMD3<Float> { r.camera.forward }

    /// What the ray along `direction` meets first, among the poses drawn this frame.
    private func aimed(_ r: Renderer, _ direction: SIMD3<Float>) -> (body: Int, point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard let physics = r.scene.physics, let drawn = r.scene.drawnPhysics else { return nil }
        let origin = r.camera.position
        let hit = physics.pick(drawn: drawn.bodies, origin: origin, direction: direction)
        // The ground (y = 0) if it is nearer.
        let ground: Float? = direction.y < -1e-4 ? -origin.y / direction.y : nil
        if let g = ground, g > 0, hit.map({ g < $0.t }) ?? true { return (-1, origin + direction * g, [0, 1, 0]) }
        return hit.map { ($0.body, origin + direction * $0.t, $0.normal) }
    }

    // MARK: The tools

    private func fireBullet(_ r: Renderer) {
        // A little spread, the same however the frames fall.
        func next() -> Float {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Float(random >> 40) / Float(1 << 24) * 2 - 1
        }
        let d = normalize(aim(r) + r.camera.right * next() * DemolitionPlayer.spread + r.camera.up * next() * DemolitionPlayer.spread)
        guard let hit = aimed(r, d), hit.body >= 0 else { return }
        r.scene.physicsCommand(GPUFractureCommand(info: SIMD4(PhysicsWorld.none, PhysicsWorld.FractureCommand.hit.rawValue, UInt32(hit.body), 1),
                                                origin: SIMD4(hit.point, 0), direction: SIMD4(d, DemolitionPlayer.bulletImpulse)))
    }

    private func fireRocket(_ r: Renderer) {
        guard var rig = r.scene.demolitionRig, !rig.rockets.isEmpty, let drawn = r.scene.drawnPhysics else { return }
        // A rocket of the pool not in flight.
        let flying = Set(drawn.demolition.rockets.filter(\.armed).map { Int($0.body) })
        guard let k = (0..<rig.rockets.count).map({ (rig.nextRocket + $0) % rig.rockets.count }).first(where: { !flying.contains(rig.rockets[$0]) })
        else { message = "Reloading: every rocket is in the air"; return }
        rig.nextRocket = k + 1
        let from = r.camera.position + aim(r) * 0.8 - r.camera.up * 0.25 + r.camera.right * 0.2
        // At what the crosshair is on (its drop allowed for), or straight ahead.
        var direction = aim(r), speed = DemolitionPlayer.rocketSpeed
        if let hit = aimed(r, aim(r)), let world = r.scene.physics {
            (direction, speed) = Scene.aim(from: from, at: hit.point, speed: DemolitionPlayer.rocketSpeed, gravity: world.gravity.y)
        }
        r.scene.physicsCommand(GPUFractureCommand(info: SIMD4(PhysicsWorld.none, PhysicsWorld.FractureCommand.rocket.rawValue, UInt32(rig.rockets[k]), 1),
                                                origin: SIMD4(from, DemolitionPlayer.rocketBlast), direction: SIMD4(direction, speed)))
        r.scene.demolitionRig = rig
        message = nil
    }

    private func placeCharge(_ r: Renderer) {
        guard var rig = r.scene.demolitionRig, let drawn = r.scene.drawnPhysics else { return }
        guard let hit = aimed(r, aim(r)), hit.body >= 0, simd_distance(r.camera.position, hit.point) < 60 else {
            message = "TNT sticks to the building and its pieces"
            return
        }
        let b = drawn.bodies[hit.body], x = PhysicsMath.xyz(b.position), q = PhysicsMath.qconj(b.rotation)
        let charge = Scene.DemolitionRig.Charge(body: hit.body, local: PhysicsMath.qrot(q, hit.point - x), normal: PhysicsMath.qrot(q, hit.normal),
                                                world: hit.point, worldNormal: hit.normal)
        if rig.placed.count >= rig.charges.count { rig.placed.removeFirst() }
        rig.placed.append(charge)
        r.scene.demolitionRig = rig
        message = "\(rig.placed.count) charge\(rig.placed.count == 1 ? "" : "s"): right click sets them off"
    }

    /// Every charge set off: a blast at each.
    func detonateCharges(_ r: Renderer) {
        guard var rig = r.scene.demolitionRig, !rig.placed.isEmpty else { return }
        for c in rig.placed {
            r.scene.physicsCommand(GPUFractureCommand(info: SIMD4(PhysicsWorld.none, PhysicsWorld.FractureCommand.blast.rawValue, 0, 4),
                                                    origin: SIMD4(c.world + c.worldNormal * 0.05, DemolitionPlayer.tntRadius),
                                                    direction: SIMD4(0, 0, 0, DemolitionPlayer.tntPush)))
        }
        rig.placed.removeAll()
        r.scene.demolitionRig = rig
        message = nil
    }

    // MARK: Walking

    /// Walking on (the walker put where the camera is, its eyes there) or off (flying from where its eyes were).
    func setWalking(_ r: Renderer, _ on: Bool) {
        walking = on
        eye = nil
        sentSpeed = SIMD2(repeating: .nan)
        if on {
            drive(r, flags: DemolitionState.Walker.enableFlag | DemolitionState.Walker.placeFlag,
                  place: r.camera.position - SIMD3(0, DemolitionPlayer.eyeHeight, 0))
            message = "Walking: W A S D, Shift runs, Space jumps, Return to where you stood, Shift-V flies"
        } else {
            drive(r, flags: DemolitionState.Walker.disableFlag)
            message = "Flying: W A S D Q E"
        }
    }

    /// The walker's input as a command (`speed`: over the ground, x and z; `jump`: its speed up).
    private func drive(_ r: Renderer, flags: UInt32 = 0, place: SIMD3<Float> = .zero, speed: SIMD2<Float> = .zero, jump: Float = 0) {
        r.scene.physicsCommand(GPUFractureCommand(info: SIMD4(PhysicsWorld.none, PhysicsWorld.FractureCommand.drive.rawValue, flags, 1),
                                                origin: SIMD4(place, 0), direction: SIMD4(speed.x, jump, speed.y, 0)))
        sentSpeed = speed
    }

    /// A walking frame: W A S D as a speed over the ground (sent when it changes), the camera at the walker's eyes as
    /// last drawn (eased over a few milliseconds: the steps are 60 a second, the frames maybe more).
    private func walk(_ r: Renderer, _ dt: Float) {
        let fw = r.camera.forward
        let ahead = length(SIMD2(fw.x, fw.z)) > 1e-4 ? normalize(SIMD2(fw.x, fw.z)) : SIMD2<Float>(0, -1)
        let right = SIMD2(-ahead.y, ahead.x)
        var move = SIMD2<Float>.zero
        if r.heldKeys.contains("w") { move += ahead }
        if r.heldKeys.contains("s") { move -= ahead }
        if r.heldKeys.contains("d") { move += right }
        if r.heldKeys.contains("a") { move -= right }
        let speed = length(move) > 0 ? normalize(move) * (r.shiftHeld ? DemolitionPlayer.runSpeed : DemolitionPlayer.walkSpeed) : .zero
        let quantised = (speed * Float(20)).rounded(.toNearestOrEven) / Float(20)
        if jump || !(quantised == sentSpeed) {
            drive(r, speed: quantised, jump: jump ? DemolitionPlayer.jumpSpeed : 0)
            jump = false
        }
        guard let rig = r.scene.demolitionRig, let drawn = r.scene.drawnPhysics, drawn.bodies.indices.contains(rig.walker) else { return }
        let b = drawn.bodies[rig.walker]
        guard b.info.y & PhysicsWorld.disabledBit == 0 else { return }   // (not yet switched on)
        let target = PhysicsMath.xyz(b.position) + SIMD3(0, DemolitionPlayer.eyeHeight, 0)
        let k = 1 - exp(-dt / 0.03)
        let smooth = eye.map { $0 + (target - $0) * k } ?? target
        eye = smooth
        r.camera.position = smooth
    }

    /// The TNT charges where their bodies are now (`drawn`: the poses drawn this frame), and the fireballs of the rockets
    /// that went off lately: each grows to most of its blast's radius in 0.15 s, then shrinks away by 0.45 s.
    func drawn(_ scene: Scene, bodies drawn: [GPUPhysicsBody], state: DemolitionState, step: Int) {
        guard var rig = scene.demolitionRig, let physics = scene.physics else { return }
        let hidden = translate([0, -60, 0]) * scale(PhysicsWorld.hiddenScale)
        let nodes = physics.fractureNodes
        for k in rig.placed.indices {
            var c = rig.placed[k]
            // Its body broke: onto the piece of it nearest where it was.
            while drawn.indices.contains(c.body), drawn[c.body].info.y & PhysicsWorld.disabledBit != 0, c.body < nodes.count, nodes[c.body].info.z > 0 {
                let first = Int(nodes[c.body].info.y), count = Int(nodes[c.body].info.z)
                var best = first, nearest = Float.infinity
                for j in first..<first + count {
                    let d = length_squared(PhysicsMath.xyz(drawn[j].position) - c.world)
                    if d < nearest { (best, nearest) = (j, d) }
                }
                let b = drawn[best]
                c.body = best
                c.local = PhysicsMath.qrot(PhysicsMath.qconj(b.rotation), c.world - PhysicsMath.xyz(b.position))
                c.normal = PhysicsMath.qrot(PhysicsMath.qconj(b.rotation), c.worldNormal)
            }
            if drawn.indices.contains(c.body), drawn[c.body].info.y & PhysicsWorld.disabledBit == 0 {
                let b = drawn[c.body]
                c.world = PhysicsMath.xyz(b.position) + PhysicsMath.qrot(b.rotation, c.local)
                c.worldNormal = PhysicsMath.qrot(b.rotation, c.normal)
            }
            rig.placed[k] = c
        }
        for (k, instance) in rig.charges.enumerated() {
            guard k < rig.placed.count else { scene.setTransform(instance, hidden); continue }
            let c = rig.placed[k], n = c.worldNormal
            // Lying on the surface: its thin side along the normal.
            let up = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let x = normalize(cross(up, n)), y = cross(n, x)
            let turn = float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(n, 0), SIMD4(0, 0, 0, 1)))
            scene.setTransform(instance, translate(c.world + n * 0.06) * turn * scale([0.22, 0.14, 0.12]))
        }
        var shown = 0
        for (d, s) in zip(state.detonations, state.detonationSteps).reversed() where shown < rig.fireballs.count {
            let age = Float(step - s) * PhysicsWorld.stepLength
            guard age >= 0, age < 0.45 else { continue }
            let most = d.w * 0.6
            let r = age < 0.15 ? most * (1 - pow(1 - age / 0.15, 3)) : most * (1 - (age - 0.15) / 0.3)
            scene.setTransform(rig.fireballs[shown], translate(PhysicsMath.xyz(d)) * scale(SIMD3(repeating: max(r, PhysicsWorld.hiddenScale))))
            shown += 1
        }
        for k in shown..<rig.fireballs.count { scene.setTransform(rig.fireballs[k], hidden) }
        scene.demolitionRig = rig
    }
}
