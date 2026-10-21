import EngineCore
import Foundation
import MetalRenderer
import simd

/// What a click does in the destruction scene (keys 1, 2, 3): grab a body, shoot a ball from the camera, or blast
/// where the cursor points.
enum DestructionTool: Int, CaseIterable {
    case grab, shoot, blast

    var title: String { ["Grab", "Shoot", "Blast"][rawValue] }
    var help: String {
        ["drag a piece about", "click: a ball from the camera", "click: a blast where you point"][rawValue]
    }
}

/// The destruction scene's tools (Physics+Fracture.swift's commands: they are kept with the step they start at, so
/// scrubbing time back does them again). Made with the scene (SceneDefinition.behaviour), on the render thread after.
final class DestructionPlayer: SceneBehaviour {
    var tool = DestructionTool.grab
    var captured = false

    /// Keys 1, 2 and 3 (elsewhere they are view modes).
    func keyDown(_ r: Renderer, _ key: String, isRepeat: Bool) -> Bool {
        guard let n = Int(key), (1...3).contains(n) else { return false }
        if !isRepeat { tool = DestructionTool(rawValue: n - 1)! }
        return true
    }

    /// The tool isn't Grab: a press doesn't take a body (the click fires on release).
    var grabs: Bool { tool == .grab }

    /// A click with Shoot or Blast at `cursor`.
    func click(_ r: Renderer, at cursor: SIMD2<Float>) -> Bool {
        guard tool != .grab else { return false }
        guard r.scene.physics != nil, var rig = r.scene.destructionRig, !rig.shots.isEmpty else { return true }
        // (With the steps on their own thread: once those asked for are done, so the command lands on its step.)
        r.scene.withPhysics { physics in fire(r, physics, &rig, direction: r.cursorRayForPainter(cursor)) }
        r.scene.destructionRig = rig
        return true
    }

    /// A small box in the top-left corner naming the tool a click uses.
    var hud: SceneHUD? {
        let keys = DestructionTool.allCases.map { "\($0.rawValue + 1) \($0.title)" }.joined(separator: "   ")
        return SceneHUD(lines: ["\(tool.title): \(tool.help)", keys])
    }

    private func fire(_ r: Renderer, _ physics: PhysicsWorld, _ rig: inout Scene.DestructionRig, direction: SIMD3<Float>) {
        switch tool {
        case .grab:
            return
        case .shoot:
            // The pool's balls in turn (after the demo's), from just in front of the camera.
            let pool = Array(rig.shots.dropFirst(Scene.DestructionRig.scripted))
            guard !pool.isEmpty else { return }
            let body = pool[rig.nextShot % pool.count]
            rig.nextShot += 1
            physics.command(.shoot, body: body, origin: r.camera.position + direction * 0.6, direction: direction,
                            magnitude: Scene.DestructionRig.shotSpeed)
        case .blast:
            // On the piece under the cursor, or the ground there.
            var point: SIMD3<Float>?
            if let hit = physics.pick(origin: r.camera.position, direction: direction, pieces: true) {
                point = r.camera.position + direction * hit.distance
            } else if direction.y < -1e-3 {
                point = r.camera.position + direction * (-r.camera.position.y / direction.y)
            }
            guard let point else { return }
            physics.command(.blast, origin: point, radius: 1.3, magnitude: 10, steps: 6)
        }
    }
}
