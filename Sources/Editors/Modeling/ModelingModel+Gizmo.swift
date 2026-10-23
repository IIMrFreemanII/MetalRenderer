import AppKit
import EngineCore
import Foundation
import Modeling
import simd

/// A handle of the Move, Rotate or Scale tool's gizmo: an axis's arrow, ring or box (Blender's X red, Y green, Z
/// blue), or the centre (free).
enum GizmoHandle: Equatable { case axis(Int), centre }

extension ModelingModel {
    /// The selection's pivot in the world, if there is a selection.
    var selectionPivot: SIMD3<Float>? {
        if pivotMode == .cursor { return document.cursor }
        if mode == .edit, let o = activeObject, let c = o.mesh.selectionCentre() {
            let w = o.transform.matrix * SIMD4(c, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        if mode == .object {
            let sel = document.objects.filter { document.selection.contains($0.id) }
            guard !sel.isEmpty else { return nil }
            if pivotMode == .active, let a = activeObject { return a.transform.location }
            return sel.reduce(SIMD3<Float>.zero) { $0 + $1.transform.location } / Float(sel.count)
        }
        return nil
    }

    private var gizmoTool: Bool { [.move, .rotate, .scale].contains(tool) && mode != .sculpt && modal == nil }

    /// The gizmo's size in metres at the pivot (a constant size on screen).
    private func gizmoScale(_ pivot: SIMD3<Float>) -> Float {
        let depth = max(simd_dot(pivot - camera.eye, camera.forward), camera.near)
        return camera.metresPerPoint(depth: depth, viewHeight: viewSize.y) * 75
    }

    private static let axisColors = [linearColor(0xFF3352), linearColor(0x8BDC00), linearColor(0x2890FF)]

    /// The tool's gizmo as lines.
    func toolGizmoLines() -> [OverlayLine] {
        guard gizmoTool, let p = selectionPivot else { return [] }
        let s = gizmoScale(p)
        var out: [OverlayLine] = []
        for i in 0..<3 {
            let axis = BlenderAxes.basis[i]
            let hot = hoveredHandle == .axis(i)
            let color = hot ? linearColor(0xFFFFFF) : Self.axisColors[i]
            switch tool {
            case .rotate:
                let u = simd_normalize(BlenderAxes.basis[(i + 1) % 3]), v = simd_normalize(BlenderAxes.basis[(i + 2) % 3])
                let n = 48
                for k in 0..<n {
                    let a0 = Float(k) / Float(n) * 2 * .pi, a1 = Float(k + 1) / Float(n) * 2 * .pi
                    out.append(OverlayLine(p + (u * cos(a0) + v * sin(a0)) * s, p + (u * cos(a1) + v * sin(a1)) * s, color: color, width: hot ? 3 : 2))
                }
            default:
                let tip = p + axis * s
                out.append(OverlayLine(p + axis * s * 0.2, tip, color: color, width: hot ? 3 : 2))
                // An arrowhead (move) or a small square (scale).
                let side = simd_normalize(simd_cross(axis, camera.forward)) * s * 0.07
                if tool == .move {
                    out.append(OverlayLine(tip, tip - axis * s * 0.15 + side, color: color, width: 2))
                    out.append(OverlayLine(tip, tip - axis * s * 0.15 - side, color: color, width: 2))
                } else {
                    let up = simd_normalize(simd_cross(side, axis)) * s * 0.07
                    for (a, b) in [(side + up, side - up), (side - up, -side - up), (-side - up, -side + up), (-side + up, side + up)] {
                        out.append(OverlayLine(tip + a, tip + b, color: color, width: 2))
                    }
                }
            }
        }
        // The centre: a white ring (free move or uniform scale).
        let r = s * 0.12, n = 24
        for k in 0..<n {
            let a0 = Float(k) / Float(n) * 2 * .pi, a1 = Float(k + 1) / Float(n) * 2 * .pi
            out.append(OverlayLine(p + (camera.right * cos(a0) + camera.up * sin(a0)) * r, p + (camera.right * cos(a1) + camera.up * sin(a1)) * r,
                                   color: hoveredHandle == .centre ? linearColor(0xFFFF80) : linearColor(0xDDDDDD), width: 1.5))
        }
        return out
    }

    /// The handle under a point, if the tool has a gizmo.
    func gizmoHandle(at q: SIMD2<Float>) -> GizmoHandle? {
        guard gizmoTool, let p = selectionPivot, let c = camera.project(p, size: viewSize) else { return nil }
        let s = gizmoScale(p)
        let centre = SIMD2(c.x, c.y)
        func screen(_ w: SIMD3<Float>) -> SIMD2<Float>? { camera.project(w, size: viewSize).map { SIMD2($0.x, $0.y) } }
        func toSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let ab = b - a
            let t = max(0, min(1, simd_dot(q - a, ab) / max(simd_length_squared(ab), 1e-6)))
            return simd_distance(q, a + ab * t)
        }
        var best: (GizmoHandle, Float)?
        for i in 0..<3 {
            let axis = BlenderAxes.basis[i]
            var d = Float.infinity
            if tool == .rotate {
                let u = simd_normalize(BlenderAxes.basis[(i + 1) % 3]), v = simd_normalize(BlenderAxes.basis[(i + 2) % 3])
                var prev: SIMD2<Float>?
                for k in 0...32 {
                    let a = Float(k) / 32 * 2 * .pi
                    guard let sp = screen(p + (u * cos(a) + v * sin(a)) * s) else { prev = nil; continue }
                    if let pv = prev { d = min(d, toSegment(pv, sp)) }
                    prev = sp
                }
            } else if let a = screen(p + axis * s * 0.2), let b = screen(p + axis * s * 1.05) {
                d = toSegment(a, b)
            }
            if d < 8, best == nil || d < best!.1 { best = (.axis(i), d) }
        }
        if best == nil, simd_distance(q, centre) < 12 { return .centre }
        return best?.0
    }

    /// A drag on a handle: the tool's transform along it, confirmed when the button goes up.
    func beginGizmoDrag(_ h: GizmoHandle) {
        let kind: TransformOperation.Kind = tool == .rotate ? .rotate : tool == .scale ? .scale : .translate
        let constraint: TransformOperation.Constraint
        switch h {
        case .axis(let i): constraint = .axis(i, local: false)
        case .centre: constraint = .none
        }
        start(TransformModal(self, kind: kind, constraint: constraint, releaseConfirms: true))
    }

    /// Hover: which handle lights up.
    func updateHover(_ p: SIMD2<Float>) {
        let h = gizmoHandle(at: p)
        if h != hoveredHandle { hoveredHandle = h; redraw() }
    }
}
