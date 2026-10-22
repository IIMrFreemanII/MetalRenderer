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

/// Placing objects: the selected object of the scene's file (Scene.placed; a click selects, as everywhere) gets three
/// arrows. Dragging one moves the object along it, Option-dragging turns it about it, Control-dragging scales it along
/// it. End drops it onto the ground (the terrain, or y = 0), Delete takes it out, Command-J makes a copy beside it,
/// Command-N puts a box in front of the camera. Every change is written to the scene's file at once
/// (SceneFile.write): what was placed needs no build. A move is applied live (Scene.moveInstances); a new or deleted
/// object makes the scene again.
extension Renderer {
    /// The arrows' drag: its axis, the object, where along the axis the cursor was, and what it does.
    package struct PlacementDrag {
        enum Mode { case move, turn, scale }
        var axis: Int
        var object: Int
        var last: Float
        var mode: Mode
    }

    /// The placed object the selection is, if it is one.
    package var placedSelection: Int? {
        guard let placed = scene.placed, let i = selection?.target.instances.first else { return nil }
        return placed.object(of: i)
    }

    /// The selected object's handle: where it stands, and how long its arrows are (a tenth of the way to the camera).
    private func placementHandle() -> (origin: SIMD3<Float>, length: Float)? {
        guard let k = placedSelection, let placed = scene.placed else { return nil }
        let t = placed.file.objects[k].world(in: placed.file.objects)
        let origin = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        return (origin, max(simd_distance(origin, camera.position) * 0.1, 0.05))
    }

    /// The arrows (x red, y green, z blue), drawn with the gizmos.
    package func placementSegments() -> [VFXGizmos.Segment] {
        guard let (origin, length) = placementHandle() else { return [] }
        let colors: [SIMD4<Float>] = [[1, 0.3, 0.25, 1], [0.35, 0.95, 0.35, 1], [0.35, 0.55, 1, 1]]
        return (0..<3).flatMap { k -> [VFXGizmos.Segment] in
            var axis = SIMD3<Float>.zero
            axis[k] = 1
            return VFXGizmos.arrow(origin, axis * length, colors[k], 3)
        }
    }

    /// A press on an arrow starts its drag (Option: turn, Control: scale); true when it did.
    package func placementMouseDown(at cursor: SIMD2<Float>) -> Bool {
        guard let k = placedSelection, let (origin, length) = placementHandle(),
              let axisIndex = VFXGizmos.pick(handle: origin, cursor: cursor, camera: camera, aspect: viewAspect, size: gizmoViewSize,
                                             pixels: 10 * max(length, 1)) else { return false }
        var axis = SIMD3<Float>.zero
        axis[axisIndex] = 1
        let s = VFXGizmos.along(origin: origin, axis: axis, from: camera.position, dir: cursorRay(cursor))
        placementDrag = PlacementDrag(axis: axisIndex, object: k, last: s, mode: optionHeld ? .turn : controlHeld ? .scale : .move)
        return true
    }

    /// The drag: the object (and what hangs from it) moved, turned or scaled as far as the cursor went along the axis.
    package func placementMouseDragged(at cursor: SIMD2<Float>) -> Bool {
        guard var drag = placementDrag, var placed = scene.placed, placed.file.objects.indices.contains(drag.object) else { return false }
        var axis = SIMD3<Float>.zero
        axis[drag.axis] = 1
        let origin = placementHandle()?.origin ?? .zero
        let s = VFXGizmos.along(origin: origin, axis: axis, from: camera.position, dir: cursorRay(cursor))
        let step = min(max(s - drag.last, -5), 5)
        drag.last = s
        placementDrag = drag
        guard step != 0 else { return true }
        var o = placed.file.objects[drag.object]
        switch drag.mode {
        case .move: o.position += axis * step
        case .turn: o.rotation = simd_normalize(simd_quatf(angle: step * .pi / 2, axis: axis) * o.rotation)
        case .scale: o.scale[drag.axis] = max(o.scale[drag.axis] * exp(step), 0.01)
        }
        placed.file.objects[drag.object] = o
        scene.placed = placed
        movePlaced(drag.object)
        return true
    }

    /// The drag let go: the file written. True when there was one.
    package func placementMouseUp() -> Bool {
        guard placementDrag != nil else { return false }
        placementDrag = nil
        savePlaced()
        return true
    }

    /// Object `k`'s instances, and those of what hangs from it, where the file now puts them.
    private func movePlaced(_ k: Int) {
        guard let placed = scene.placed else { return }
        var moves: [(Int, float4x4)] = []
        var queue = [k], seen = Set<Int>()
        var worlds = placed.worlds
        while let j = queue.popLast(), seen.insert(j).inserted {
            // Its instances by the change of its world transform (what its asset put under it stays as it was).
            let world = placed.file.objects[j].world(in: placed.file.objects), change = world * worlds[j].inverse
            for i in placed.instances[j] { moves.append((i, change * scene.instances[i].transform)) }
            worlds[j] = world
            queue += placed.file.objects.indices.filter { placed.file.objects[$0].parent == j }
        }
        scene.placed?.worlds = worlds
        scene.moveInstances(moves, record: true)
    }

    /// End: the selected object stands on the ground under it (the terrain, or y = 0).
    package func dropPlaced() {
        guard let k = placedSelection, var placed = scene.placed else { return }
        let t = placed.file.objects[k].world(in: placed.file.objects)
        let x = t.columns.3.x, z = t.columns.3.z
        let ground = scene.terrain?.height(x, z) ?? 0
        // Its lowest point (its instances' boxes) on the ground.
        let low = placed.instances[k].map { scene.worldBounds(of: $0).lo.y }.min() ?? t.columns.3.y
        placed.file.objects[k].position.y += ground - low
        scene.placed = placed
        movePlaced(k)
        savePlaced()
    }

    /// Delete: the selected object out of the file (and what hangs from it), the scene made again.
    package func deletePlaced() {
        guard let k = placedSelection else { return }
        selection = nil
        editPlaced { $0.removeObjects([k]) }
    }

    /// Command-D: a copy of the selected object beside it (along x, its width away).
    package func duplicatePlaced() {
        guard let k = placedSelection, let placed = scene.placed else { return }
        var copy = placed.file.objects[k]
        let width = placed.instances[k].map { scene.worldBounds(of: $0) }.map { $0.hi.x - $0.lo.x }.max() ?? 1
        copy.position.x += width * 1.2
        copy.name += " copy"
        editPlaced { $0.objects.append(copy) }
    }

    /// Command-Shift-N: `asset` (a box) on the ground three metres in front of the camera.
    package func addPlaced(asset: String = "prefab:box") {
        let ahead = camera.position + normalize(SIMD3(camera.forward.x, 0, camera.forward.z)) * 3
        let ground = scene.terrain?.height(ahead.x, ahead.z) ?? 0
        let name = asset.split(separator: ":").last.map(String.init) ?? asset
        editPlaced { file in
            file.objects.append(SceneFile.Object(asset: asset, name: "\(name.capitalized) \(file.objects.count + 1)",
                                                 position: SIMD3(ahead.x, ground + 0.5, ahead.z)))
        }
    }

    /// The scene's file written as it is now (a move, applied live).
    package func savePlaced() {
        guard let placed = scene.placed else { return }
        do {
            try placed.file.write(to: SceneFile.url(for: scene.settings.kind))
        } catch {
            print("Scene file: \(scene.settings.kind.name) not written: \(error)")
        }
    }

    /// Edits the file of the scene the settings ask for (`edit`, from the file as it was last edited) and writes it
    /// at once: the editors' and the scripts' way to change what a scene has. Objects only moved, turned or scaled in
    /// the scene that is in move live (Scene.moveInstances); anything else makes the scene again from the file, once
    /// a load under way is in (`placedPending`). `save` false: a live move isn't written (motion every frame, a
    /// script's `onFrame`); the next edit that is writes it. Render thread.
    package func editPlaced(save: Bool = true, _ edit: (inout SceneFile) -> Void) {
        let kind = settings.scene.kind
        let live = kind == scene.settings.kind && loading == nil && placedPending == nil ? scene.placed : nil
        let before = placedPending ?? live?.file ?? SceneFile(kind) ?? SceneFile()
        var file = before
        edit(&file)
        guard !file.matches(before) else { return }
        let moves = live.map { file.onlyMoves(from: $0.file) } ?? false
        if save || !moves {
            do {
                try file.write(to: SceneFile.url(for: kind))
            } catch {
                print("Scene file: \(kind.name) not written: \(error)")
                return
            }
        }
        if var placed = live, moves {
            let moved = file.objects.indices.filter { file.objects[$0] != placed.file.objects[$0] }
            placed.file = file
            scene.placed = placed
            for k in moved { movePlaced(k) }
            return
        }
        if loading != nil || placedPending != nil {
            placedPending = file
        } else {
            remakeScene(because: "its scene file changed")
        }
    }

    /// A scene file edited while a scene loaded (editPlaced): the scene made again from it once that one is in.
    package func remakeForPendingPlaced() {
        guard placedPending != nil, loading == nil else { return }
        placedPending = nil
        remakeScene(because: "its scene file changed")
    }
}

extension SceneFile {
    /// The same objects, lights, generators and camera.
    package func matches(_ other: SceneFile) -> Bool {
        objects == other.objects && lights == other.lights && generators == other.generators && sameCamera(other)
    }

    /// Only objects' places changed from `other` (their positions, rotations, scales): the scene can move them.
    package func onlyMoves(from other: SceneFile) -> Bool {
        guard objects.count == other.objects.count, lights == other.lights, generators == other.generators, sameCamera(other) else {
            return false
        }
        return zip(objects, other.objects).allSatisfy { a, b in
            a.asset == b.asset && a.name == b.name && a.parent == b.parent && a.material == b.material && a.flags == b.flags
        }
    }

    private func sameCamera(_ other: SceneFile) -> Bool {
        switch (camera, other.camera) {
        case (nil, nil): return true
        case let (a?, b?): return a.position == b.position && a.yaw == b.yaw && a.pitch == b.pitch && a.fovY == b.fovY
        default: return false
        }
    }
}
