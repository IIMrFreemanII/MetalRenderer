import Foundation
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

/// The demolition scene's player as the HUD shows it (DemolitionHUD).
struct DemolitionStatus: Equatable {
    var tool: DemolitionTool
    var captured: Bool
    var walking: Bool
    var charges: Int
    var message: String?
}

/// The player's state on the render thread.
package struct DemolitionPlayer {
    var tool = DemolitionTool.machineGun
    /// The mouse turns the camera (RenderView.captured); the crosshair aims.
    var captured = false
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
    package static let tntRadius: Float = 1.8, tntPush: Float = 18
    /// The walker's speeds (m/s) and its eyes above its middle (m).
    static let walkSpeed: Float = 3, runSpeed: Float = 5.5, jumpSpeed: Float = 4.5, eyeHeight: Float = 0.78
}

/// The demolition scene's tools and walker (Scene+Demolition.swift, Physics+Demolition.swift). What they do goes to the
/// physics as commands (Scene.physicsCommand: with the next frame's steps, without waiting for those running), so a
/// replay does them again; aiming reads the poses drawn this frame.
extension Renderer {
    var inDemolition: Bool { scene.demolitionRig != nil }

    var demolitionStatus: DemolitionStatus? {
        guard inDemolition else { return nil }
        return DemolitionStatus(tool: demolition.tool, captured: demolition.captured, walking: demolition.walking,
                                charges: scene.demolitionRig?.placed.count ?? 0, message: demolition.message)
    }

    /// The scene's keys: 1 to 4 the tools, Shift-V (as `v`) walks or flies, Space jumps while walking, Return puts the
    /// walker back where it last stood, Delete takes the charges off, R starts the office again.
    func demolitionKey(_ key: String, isRepeat: Bool) -> Bool {
        guard inDemolition else { return false }
        switch key {
        case "1", "2", "3", "4":
            guard !isRepeat else { return true }
            demolition.tool = DemolitionTool(rawValue: Int(key)! - 1)!
            demolition.firing = false
            demolition.message = nil
            return true
        case "v":
            if !isRepeat { setDemolitionWalking(!demolition.walking) }
            return true
        case " ":
            guard demolition.walking else { return false }
            demolition.jump = true
            return true
        case "\r":
            guard demolition.walking, !isRepeat, let rig = scene.demolitionRig else { return demolition.walking }
            drive(flags: DemolitionState.Walker.placeFlag, place: rig.spawn)
            return true
        case "\u{7f}":
            scene.demolitionRig?.placed.removeAll()
            return true
        case "r":
            guard !isRepeat else { return true }
            restartDemolition()
            return true
        default:
            return false
        }
    }

    /// The office as it was built: the player's commands dropped, time back to 0 (the world replays from its start).
    func restartDemolition() {
        scene.withPhysics { $0.dropPlayerCommands() }
        scene.demolitionRig?.placed.removeAll()
        demolition.walking = false
        demolition.eye = nil
        demolition.sentSpeed = SIMD2(repeating: .nan)
        setTime(0)
        demolition.message = "Restarted"
    }

    /// The captured mouse turns the camera (the walker's head, or the flying camera).
    func demolitionLook(dx: Float, dy: Float) {
        camera.yaw += dx * Camera.turnRate
        camera.pitch = min(max(camera.pitch - dy * Camera.turnRate, -1.5), 1.5)
    }

    /// A press: fires the tool (the machine gun until the release). Not with Grab, or with the cursor free.
    func demolitionMouseDown() -> Bool {
        guard inDemolition, demolition.captured, demolition.tool != .grab else { return false }
        switch demolition.tool {
        case .machineGun:
            demolition.firing = true
            demolition.reload = 0
        case .rocket: fireRocket()
        case .tnt: placeCharge()
        case .grab: break
        }
        return true
    }

    /// A frame: the machine gun's bullets, the walker's input and the camera at its eyes. True when the camera is the
    /// walker's (the frame's other camera moves are off).
    func updateDemolition(_ dt: Float) -> Bool {
        guard inDemolition else {
            demolition.walking = false
            return false
        }
        if demolition.firing && demolition.tool == .machineGun {
            demolition.reload -= dt
            var shots = 0
            while demolition.reload <= 0 && shots < 4 {
                fireBullet()
                demolition.reload += 1 / DemolitionPlayer.fireRate
                shots += 1
            }
            if demolition.reload < 0 { demolition.reload = 0 }
        }
        guard demolition.walking else { return false }
        walkDemolition(dt)
        return true
    }

    // MARK: Aiming

    /// Where the crosshair (or, with the cursor free, the view's middle) points: a ray from the camera.
    private var aim: SIMD3<Float> { camera.forward }

    /// What the ray along `direction` meets first, among the poses drawn this frame.
    private func aimed(_ direction: SIMD3<Float>) -> (body: Int, point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard let physics = scene.physics, let drawn = scene.drawnPhysics else { return nil }
        let origin = camera.position
        let hit = physics.pick(drawn: drawn.bodies, origin: origin, direction: direction)
        // The ground (y = 0) if it is nearer.
        let ground: Float? = direction.y < -1e-4 ? -origin.y / direction.y : nil
        if let g = ground, g > 0, hit.map({ g < $0.t }) ?? true { return (-1, origin + direction * g, [0, 1, 0]) }
        return hit.map { ($0.body, origin + direction * $0.t, $0.normal) }
    }

    // MARK: The tools

    private func fireBullet() {
        // A little spread, the same however the frames fall.
        func next() -> Float {
            demolition.random = demolition.random &* 6364136223846793005 &+ 1442695040888963407
            return Float(demolition.random >> 40) / Float(1 << 24) * 2 - 1
        }
        let d = normalize(aim + camera.right * next() * DemolitionPlayer.spread + camera.up * next() * DemolitionPlayer.spread)
        guard let hit = aimed(d), hit.body >= 0 else { return }
        scene.physicsCommand(GPUFractureCommand(info: SIMD4(PhysicsWorld.none, PhysicsWorld.FractureCommand.hit.rawValue, UInt32(hit.body), 1),
                                                origin: SIMD4(hit.point, 0), direction: SIMD4(d, DemolitionPlayer.bulletImpulse)))
    }

    private func fireRocket() {
        guard var rig = scene.demolitionRig, !rig.rockets.isEmpty, let drawn = scene.drawnPhysics else { return }
        // A rocket of the pool not in flight.
        let flying = Set(drawn.demolition.rockets.filter(\.armed).map { Int($0.body) })
        guard let k = (0..<rig.rockets.count).map({ (rig.nextRocket + $0) % rig.rockets.count }).first(where: { !flying.contains(rig.rockets[$0]) })
        else { demolition.message = "Reloading: every rocket is in the air"; return }
        rig.nextRocket = k + 1
        let from = camera.position + aim * 0.8 - camera.up * 0.25 + camera.right * 0.2
        // At what the crosshair is on (its drop allowed for), or straight ahead.
        var direction = aim, speed = DemolitionPlayer.rocketSpeed
        if let hit = aimed(aim), let world = scene.physics {
            (direction, speed) = Scene.aim(from: from, at: hit.point, speed: DemolitionPlayer.rocketSpeed, gravity: world.gravity.y)
        }
        scene.physicsCommand(GPUFractureCommand(info: SIMD4(PhysicsWorld.none, PhysicsWorld.FractureCommand.rocket.rawValue, UInt32(rig.rockets[k]), 1),
                                                origin: SIMD4(from, DemolitionPlayer.rocketBlast), direction: SIMD4(direction, speed)))
        scene.demolitionRig = rig
        demolition.message = nil
    }

    private func placeCharge() {
        guard var rig = scene.demolitionRig, let drawn = scene.drawnPhysics else { return }
        guard let hit = aimed(aim), hit.body >= 0, simd_distance(camera.position, hit.point) < 60 else {
            demolition.message = "TNT sticks to the building and its pieces"
            return
        }
        let b = drawn.bodies[hit.body], x = PhysicsMath.xyz(b.position), q = PhysicsMath.qconj(b.rotation)
        let charge = Scene.DemolitionRig.Charge(body: hit.body, local: PhysicsMath.qrot(q, hit.point - x), normal: PhysicsMath.qrot(q, hit.normal),
                                                world: hit.point, worldNormal: hit.normal)
        if rig.placed.count >= rig.charges.count { rig.placed.removeFirst() }
        rig.placed.append(charge)
        scene.demolitionRig = rig
        demolition.message = "\(rig.placed.count) charge\(rig.placed.count == 1 ? "" : "s"): right click sets them off"
    }

    /// Every charge set off: a blast at each.
    func detonateCharges() {
        guard var rig = scene.demolitionRig, !rig.placed.isEmpty else { return }
        for c in rig.placed {
            scene.physicsCommand(GPUFractureCommand(info: SIMD4(PhysicsWorld.none, PhysicsWorld.FractureCommand.blast.rawValue, 0, 4),
                                                    origin: SIMD4(c.world + c.worldNormal * 0.05, DemolitionPlayer.tntRadius),
                                                    direction: SIMD4(0, 0, 0, DemolitionPlayer.tntPush)))
        }
        rig.placed.removeAll()
        scene.demolitionRig = rig
        demolition.message = nil
    }

    // MARK: Walking

    /// Walking on (the walker put where the camera is, its eyes there) or off (flying from where its eyes were).
    func setDemolitionWalking(_ on: Bool) {
        guard inDemolition else { return }
        demolition.walking = on
        demolition.eye = nil
        demolition.sentSpeed = SIMD2(repeating: .nan)
        if on {
            drive(flags: DemolitionState.Walker.enableFlag | DemolitionState.Walker.placeFlag,
                  place: camera.position - SIMD3(0, DemolitionPlayer.eyeHeight, 0))
            demolition.message = "Walking: W A S D, Shift runs, Space jumps, Return to where you stood, Shift-V flies"
        } else {
            drive(flags: DemolitionState.Walker.disableFlag)
            demolition.message = "Flying: W A S D Q E"
        }
    }

    /// The walker's input as a command (`speed`: over the ground, x and z; `jump`: its speed up).
    private func drive(flags: UInt32 = 0, place: SIMD3<Float> = .zero, speed: SIMD2<Float> = .zero, jump: Float = 0) {
        scene.physicsCommand(GPUFractureCommand(info: SIMD4(PhysicsWorld.none, PhysicsWorld.FractureCommand.drive.rawValue, flags, 1),
                                                origin: SIMD4(place, 0), direction: SIMD4(speed.x, jump, speed.y, 0)))
        demolition.sentSpeed = speed
    }

    /// A walking frame: W A S D as a speed over the ground (sent when it changes), the camera at the walker's eyes as
    /// last drawn (eased over a few milliseconds: the steps are 60 a second, the frames maybe more).
    private func walkDemolition(_ dt: Float) {
        let fw = camera.forward
        let ahead = length(SIMD2(fw.x, fw.z)) > 1e-4 ? normalize(SIMD2(fw.x, fw.z)) : SIMD2<Float>(0, -1)
        let right = SIMD2(-ahead.y, ahead.x)
        var move = SIMD2<Float>.zero
        if heldKeys.contains("w") { move += ahead }
        if heldKeys.contains("s") { move -= ahead }
        if heldKeys.contains("d") { move += right }
        if heldKeys.contains("a") { move -= right }
        let speed = length(move) > 0 ? normalize(move) * (shiftHeld ? DemolitionPlayer.runSpeed : DemolitionPlayer.walkSpeed) : .zero
        let quantised = (speed * Float(20)).rounded(.toNearestOrEven) / Float(20)
        if demolition.jump || !(quantised == demolition.sentSpeed) {
            drive(speed: quantised, jump: demolition.jump ? DemolitionPlayer.jumpSpeed : 0)
            demolition.jump = false
        }
        guard let rig = scene.demolitionRig, let drawn = scene.drawnPhysics, drawn.bodies.indices.contains(rig.walker) else { return }
        let b = drawn.bodies[rig.walker]
        guard b.info.y & PhysicsWorld.disabledBit == 0 else { return }   // (not yet switched on)
        let eye = PhysicsMath.xyz(b.position) + SIMD3(0, DemolitionPlayer.eyeHeight, 0)
        let k = 1 - exp(-dt / 0.03)
        let smooth = demolition.eye.map { $0 + (eye - $0) * k } ?? eye
        demolition.eye = smooth
        camera.position = smooth
    }
}
