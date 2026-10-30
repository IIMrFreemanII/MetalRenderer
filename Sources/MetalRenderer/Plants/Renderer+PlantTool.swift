import Effects
import EngineCore
import Foundation
import simd

/// What the plant editor's Manual Edit draws in the view, and the handle it moves and turns a point with.
package struct PlantToolOverlay: Equatable {
    package var lines: [VFXGizmos.Segment] = []
    package var handle: SIMD3<Float>? = nil         // three arrows here
    package var rings = true                        // and three rings (a branch's tip has nothing beyond it to turn)

    package init(lines: [VFXGizmos.Segment] = [], handle: SIMD3<Float>? = nil, rings: Bool = true) {
        self.lines = lines
        self.handle = handle
        self.rings = rings
    }
}

/// What the mouse did with it, on the render thread. A phase: 0 begins, 1 moves, 2 ends.
package enum PlantToolEvent {
    case hover(origin: SIMD3<Float>, direction: SIMD3<Float>)
    case click(origin: SIMD3<Float>, direction: SIMD3<Float>)
    case moved(delta: SIMD3<Float>, phase: Int)
    case turned(axis: SIMD3<Float>, angle: Float, phase: Int)
}

/// The handle's shape and what's under a ray, apart from the renderer.
package enum PlantToolHandle {
    package enum Part: Equatable {
        case arrow(Int)
        case ring(Int)
    }

    static let axes: [SIMD3<Float>] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    static let colors: [SIMD4<Float>] = [[1, 0.3, 0.25, 1], [0.35, 0.95, 0.35, 1], [0.35, 0.55, 1, 1]]

    /// How long its arrows are: a tenth of the way to the camera, a constant size on screen.
    package static func size(_ handle: SIMD3<Float>, from eye: SIMD3<Float>) -> Float { max(simd_distance(handle, eye) * 0.1, 0.05) }
    static func ringRadius(_ size: Float) -> Float { size * 0.7 }

    package static func segments(_ handle: SIMD3<Float>, size: Float, rings: Bool = true) -> [VFXGizmos.Segment] {
        axes.indices.flatMap { k in
            VFXGizmos.arrow(handle, axes[k] * size, colors[k], 3) + (rings ? VFXGizmos.circle(handle, axes[k], ringRadius(size), colors[k], 2) : [])
        }
    }

    /// Where the ray meets the plane through `handle` across `axis`.
    static func hit(_ handle: SIMD3<Float>, axis: SIMD3<Float>, origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        let along = dot(direction, axis)
        guard abs(along) > 1e-3 else { return nil }
        let t = dot(handle - origin, axis) / along
        return t > 0 ? origin + direction * t : nil
    }

    /// What's under the ray, the arrows before the rings; what's within `tolerance` (radians from the eye) of it.
    package static func part(_ handle: SIMD3<Float>, size: Float, origin: SIMD3<Float>, direction: SIMD3<Float>, rings: Bool = true, tolerance: Float = 0.012) -> Part? {
        var best: (part: Part, miss: Float)?
        for (k, axis) in axes.enumerated() {
            let a = handle - origin, b = handle + axis * size - origin
            // Nearest on the arrow, across the ray.
            let ab = b - a, ad = dot(ab, direction), wa = dot(a, ab), wd = dot(a, direction), aa = dot(ab, ab)
            let denominator = aa - ad * ad
            let s = denominator > 1e-9 ? min(max((ad * wd - wa) / denominator, 0), 1) : 0
            let p = a + ab * s, t = dot(p, direction)
            guard t > 0 else { continue }
            let miss = simd_length(p - direction * t) / t
            if miss < tolerance, miss < best?.miss ?? .infinity { best = (.arrow(k), miss) }
        }
        if let best { return best.part }
        guard rings else { return nil }
        for (k, axis) in axes.enumerated() {
            guard let at = hit(handle, axis: axis, origin: origin, direction: direction) else { continue }
            let t = max(simd_distance(at, origin), 1e-3)
            let miss = abs(simd_distance(at, handle) - ringRadius(size)) / t
            if miss < tolerance, miss < best?.miss ?? .infinity { best = (.ring(k), miss) }
        }
        return best?.part
    }
}

extension Renderer {
    /// A handle being dragged: which part, from where, and where the cursor was along its arrow or round its ring.
    package struct PlantToolDrag {
        var part: PlantToolHandle.Part
        var origin: SIMD3<Float>
        var along: Float = 0
        var from = SIMD3<Float>.zero
    }

    package func plantToolSegments() -> [VFXGizmos.Segment] {
        guard let tool = plantTool else { return [] }
        guard let handle = tool.handle else { return tool.lines }
        return tool.lines + PlantToolHandle.segments(handle, size: PlantToolHandle.size(handle, from: camera.position), rings: tool.rings)
    }

    /// A press on the handle starts its drag; true when it did. (Elsewhere it's as anywhere: a drag looks, Option orbits,
    /// a click is the tool's: `plantToolClick`.)
    package func plantToolMouseDown(at cursor: SIMD2<Float>) -> Bool {
        guard !optionHeld, let tool = plantTool, let handle = tool.handle else { return false }
        let direction = cursorRay(cursor), origin = camera.position
        guard let part = PlantToolHandle.part(handle, size: PlantToolHandle.size(handle, from: origin), origin: origin, direction: direction, rings: tool.rings) else { return false }
        var drag = PlantToolDrag(part: part, origin: handle)
        switch part {
        case .arrow(let k):
            drag.along = VFXGizmos.along(origin: handle, axis: PlantToolHandle.axes[k], from: origin, dir: direction)
            onPlantTool?(.moved(delta: .zero, phase: 0))
        case .ring(let k):
            guard let at = PlantToolHandle.hit(handle, axis: PlantToolHandle.axes[k], origin: origin, direction: direction) else { return false }
            drag.from = at - handle
            onPlantTool?(.turned(axis: PlantToolHandle.axes[k], angle: 0, phase: 0))
        }
        plantToolDrag = drag
        return true
    }

    package func plantToolMouseDragged(at cursor: SIMD2<Float>) -> Bool {
        guard var drag = plantToolDrag else { return false }
        let direction = cursorRay(cursor), origin = camera.position
        switch drag.part {
        case .arrow(let k):
            let axis = PlantToolHandle.axes[k]
            let s = VFXGizmos.along(origin: drag.origin, axis: axis, from: origin, dir: direction)
            let step = min(max(s - drag.along, -5), 5)
            drag.along = s
            if step != 0 { onPlantTool?(.moved(delta: axis * step, phase: 1)) }
        case .ring(let k):
            let axis = PlantToolHandle.axes[k]
            if let at = PlantToolHandle.hit(drag.origin, axis: axis, origin: origin, direction: direction) {
                let now = at - drag.origin
                let angle = atan2(dot(cross(drag.from, now), axis), dot(drag.from, now))
                drag.from = now
                if angle != 0 { onPlantTool?(.turned(axis: axis, angle: angle, phase: 1)) }
            }
        }
        plantToolDrag = drag
        return true
    }

    /// True when a drag of the handle ended.
    package func plantToolMouseUp() -> Bool {
        guard let drag = plantToolDrag else { return false }
        plantToolDrag = nil
        switch drag.part {
        case .arrow: onPlantTool?(.moved(delta: .zero, phase: 2))
        case .ring(let k): onPlantTool?(.turned(axis: PlantToolHandle.axes[k], angle: 0, phase: 2))
        }
        return true
    }

    /// A click (no drag) is the tool's while there is one.
    package func plantToolClick(at cursor: SIMD2<Float>) -> Bool {
        guard plantTool != nil else { return false }
        onPlantTool?(.click(origin: camera.position, direction: cursorRay(cursor)))
        return true
    }

    package func plantToolMouseMoved(at cursor: SIMD2<Float>) {
        guard plantTool != nil, plantToolDrag == nil else { return }
        onPlantTool?(.hover(origin: camera.position, direction: cursorRay(cursor)))
    }
}
