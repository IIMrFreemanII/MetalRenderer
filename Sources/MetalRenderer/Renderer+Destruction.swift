import Foundation
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

/// The destruction scene's tools for the overlay (DestructionOverlay).
struct DestructionStatus: Equatable {
    var tool: DestructionTool
}

/// The destruction scene's tools (Physics+Fracture.swift's commands: they are kept with the step they start at, so
/// scrubbing time back does them again).
extension Renderer {
    /// Keys 1, 2 and 3 in the destruction scene (elsewhere they are view modes).
    func destructionKey(_ key: String) -> Bool {
        guard scene.settings.kind == .destruction, let n = Int(key), (1...3).contains(n) else { return false }
        destructionTool = DestructionTool(rawValue: n - 1)!
        return true
    }

    /// The tool isn't Grab: a press doesn't take a body (the click fires on release).
    var destructionFires: Bool { scene.settings.kind == .destruction && destructionTool != .grab }

    /// A click with Shoot or Blast at `cursor`.
    func fireDestruction(at cursor: SIMD2<Float>) {
        guard let physics = scene.physics, var rig = scene.destructionRig, !rig.shots.isEmpty else { return }
        let direction = cursorRayForPainter(cursor)
        switch destructionTool {
        case .grab:
            return
        case .shoot:
            // The pool's balls in turn (after the demo's), from just in front of the camera.
            let pool = Array(rig.shots.dropFirst(Scene.DestructionRig.scripted))
            guard !pool.isEmpty else { return }
            let body = pool[rig.nextShot % pool.count]
            rig.nextShot += 1
            physics.command(.shoot, body: body, origin: camera.position + direction * 0.6, direction: direction,
                            magnitude: Scene.DestructionRig.shotSpeed)
        case .blast:
            // On the piece under the cursor, or the ground there.
            var point: SIMD3<Float>?
            if let hit = physics.pick(origin: camera.position, direction: direction, pieces: true) {
                point = camera.position + direction * hit.distance
            } else if direction.y < -1e-3 {
                point = camera.position + direction * (-camera.position.y / direction.y)
            }
            guard let point else { return }
            physics.command(.blast, origin: point, radius: 1.3, magnitude: 10, steps: 6)
        }
        scene.destructionRig = rig
    }
}
