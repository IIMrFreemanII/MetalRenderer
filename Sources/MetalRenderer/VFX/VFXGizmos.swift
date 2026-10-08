import Foundation
import simd

/// What the VFX editor draws over the frame for the effect it shows (Shaders/Gizmo.metal): each of its emitters'
/// spawn shape and the axis its velocity spreads about, the fields they move in, the colliders they meet; and on the
/// selected emitter, a handle of three arrows to drag its shape along (Renderer.mouseDown).
enum VFXGizmos {
    /// MSL GizmoSegment.
    struct Segment: Equatable {
        var a: SIMD4<Float>
        var b: SIMD4<Float>
        var color: SIMD4<Float>
    }

    /// MSL GizmoView.
    struct View {
        var position: SIMD4<Float>
        var right: SIMD4<Float>
        var up: SIMD4<Float>
        var forward: SIMD4<Float>
        var size: SIMD2<Float>
        var tanY: Float
        var aspect: Float
        var count: UInt32
        var samples: UInt32
        var pad = SIMD2<UInt32>.zero
    }

    /// What is shown: the effect (by name), and the selected emitter (by name), which gets the handle.
    struct Target: Equatable {
        var effect: String
        var emitter: String?
    }

    static let samples: UInt32 = 2048
    static let handleLength: Float = 0.6
    static let shape = SIMD4<Float>(0.35, 0.85, 1, 1)
    static let selectedShape = SIMD4<Float>(1, 0.75, 0.25, 1)
    static let field = SIMD4<Float>(0.45, 0.9, 0.45, 1)
    static let collider = SIMD4<Float>(0.9, 0.45, 0.9, 1)
    static let axes: [SIMD4<Float>] = [[1, 0.25, 0.25, 1], [0.35, 1, 0.35, 1], [0.35, 0.55, 1, 1]]

    /// The segments for `target`'s emitters in `system` (`owners`: each emitter's effect), and the handle's origin.
    static func segments(_ system: ParticleSystem, owners: [String], target: Target) -> (segments: [Segment], handle: SIMD3<Float>?) {
        var out: [Segment] = [], handle: SIMD3<Float>?
        var fields = Set<Int>(), colliders: UInt32 = 0
        for (i, e) in system.emitters.enumerated() where owners[safe: i] == target.effect {
            let selected = e.name == target.emitter
            let color = selected ? selectedShape : shape
            out += shapeSegments(e, color: color, width: selected ? 2 : 1)
            if let f = e.field?.index { fields.insert(f) }
            colliders |= e.colliders
            if selected { handle = e.position }
        }
        for f in fields.sorted() where f < system.fields.count {
            let g = system.fields[f]
            out += box(g.lo + g.size / 2, g.size / 2, field, 1)
        }
        for (k, c) in system.colliders.enumerated() where colliders & (1 << UInt32(k)) != 0 {
            switch c {
            case .plane(let n, let p):
                let u = normalize(n), (t, b) = basis(u)
                let corners = [t + b, t - b, -t - b, -t + b].map { p + $0 * 1.5 }
                for j in 0..<4 { out.append(line(corners[j], corners[(j + 1) % 4], collider, 1)) }
                out += arrow(p, u * 0.5, collider, 1)
            case .sphere(let center, let r): out += sphere(center, r, collider, 1)
            case .box(let center, let h): out += box(center, h, collider, 1)
            case .shape: break   // an SDF shape's instance: the scene draws it
            }
        }
        if let h = handle {
            for (k, axis) in [SIMD3<Float>(1, 0, 0), [0, 1, 0], [0, 0, 1]].enumerated() {
                out += arrow(h, axis * handleLength, axes[k], 3)
            }
        }
        return (out, handle)
    }

    static func shapeSegments(_ e: ParticleEmitter, color: SIMD4<Float>, width: Float) -> [Segment] {
        let p = e.position, axis = simd_length(e.direction) > 0 ? normalize(e.direction) : SIMD3<Float>(0, 1, 0)
        var out: [Segment] = []
        switch e.shape {
        case .point:
            let s: Float = 0.08
            for d in [SIMD3<Float>(1, 0, 0), [0, 1, 0], [0, 0, 1]] { out.append(line(p - d * s, p + d * s, color, width)) }
        case .sphere(let r, _): out += sphere(p, r, color, width)
        case .disc(let r): out += circle(p, axis, r, color, width) + [line(p, p + basis(axis).0 * r, color, width)]
        case .ring(let r): out += circle(p, axis, r, color, width) + circle(p, axis, r * 0.92, color, width)
        case .box(let h): out += box(p, h, color, width)
        }
        out += arrow(p, axis * 0.4, color, width)
        return out
    }

    // MARK: - Pieces

    static func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ color: SIMD4<Float>, _ width: Float) -> Segment {
        Segment(a: SIMD4(a, width), b: SIMD4(b, width), color: color)
    }

    /// Unit vectors square to `n` and each other.
    static func basis(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let t = Scene.perpendicular(n)
        return (t, cross(n, t))
    }

    static func circle(_ c: SIMD3<Float>, _ n: SIMD3<Float>, _ r: Float, _ color: SIMD4<Float>, _ width: Float, sides: Int = 40) -> [Segment] {
        let (t, b) = basis(n)
        func at(_ k: Int) -> SIMD3<Float> { let a = Float(k) / Float(sides) * 2 * .pi; return c + (t * cos(a) + b * sin(a)) * r }
        return (0..<sides).map { line(at($0), at($0 + 1), color, width) }
    }

    static func sphere(_ c: SIMD3<Float>, _ r: Float, _ color: SIMD4<Float>, _ width: Float) -> [Segment] {
        circle(c, [1, 0, 0], r, color, width) + circle(c, [0, 1, 0], r, color, width) + circle(c, [0, 0, 1], r, color, width)
    }

    static func box(_ c: SIMD3<Float>, _ h: SIMD3<Float>, _ color: SIMD4<Float>, _ width: Float) -> [Segment] {
        var out: [Segment] = []
        for axis in 0..<3 {
            let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
            for su: Float in [-1, 1] {
                for sv: Float in [-1, 1] {
                    var a = c, b = c
                    a[axis] -= h[axis]; b[axis] += h[axis]
                    a[u] += su * h[u]; b[u] += su * h[u]
                    a[v] += sv * h[v]; b[v] += sv * h[v]
                    out.append(line(a, b, color, width))
                }
            }
        }
        return out
    }

    static func arrow(_ from: SIMD3<Float>, _ d: SIMD3<Float>, _ color: SIMD4<Float>, _ width: Float) -> [Segment] {
        let tip = from + d, len = simd_length(d)
        guard len > 0 else { return [] }
        let (t, _) = basis(d / len), back = tip - d / len * len * 0.2
        return [line(from, tip, color, width), line(tip, back + t * len * 0.08, color, width), line(tip, back - t * len * 0.08, color, width)]
    }

    // MARK: - Picking

    /// The handle's axis (0 x, 1 y, 2 z) under `cursor` (0...1 across and down), within `pixels` of its arrow on a view
    /// `size` pixels big, if one is.
    static func pick(handle: SIMD3<Float>, cursor: SIMD2<Float>, camera: Camera, aspect: Float, size: SIMD2<Float>,
                     pixels: Float = 10) -> Int? {
        func screen(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let v = p - camera.position, z = dot(v, camera.forward)
            guard z > 0.05 else { return nil }
            let t = tan(camera.fovY / 2)
            let x = dot(v, camera.right) / (z * t * aspect), y = dot(v, camera.up) / (z * t)
            return SIMD2((x * 0.5 + 0.5) * size.x, (0.5 - y * 0.5) * size.y)
        }
        let c = cursor * size
        var best: (axis: Int, d: Float)?
        for (k, axis) in [SIMD3<Float>(1, 0, 0), [0, 1, 0], [0, 0, 1]].enumerated() {
            guard let a = screen(handle), let b = screen(handle + axis * handleLength) else { continue }
            let ab = b - a, t = simd_clamp(dot(c - a, ab) / max(dot(ab, ab), 1e-6), 0, 1)
            let d = simd_length(a + ab * t - c)
            if d < pixels, d < best?.d ?? .infinity { best = (k, d) }
        }
        return best?.axis
    }

    /// Where along the line `origin + s axis` the ray `from + t dir` passes nearest.
    static func along(origin: SIMD3<Float>, axis: SIMD3<Float>, from: SIMD3<Float>, dir: SIMD3<Float>) -> Float {
        let w = origin - from, b = dot(axis, dir), d = dot(axis, w), e = dot(dir, w)
        let denom = 1 - b * b
        guard abs(denom) > 1e-5 else { return 0 }
        return (b * e - d) / denom
    }
}
