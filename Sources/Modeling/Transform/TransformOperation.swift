import Foundation
import simd

/// G, R and S as Blender's: the mouse moves, rotates or scales the selection round a pivot; X, Y, Z constrain to an
/// axis (again: the local axis; Shift: the plane without it), typing gives the value, Ctrl snaps to increments, Shift
/// moves finely; proportional editing (O) takes what is near along. The operation only says what the transform is
/// (`matrix`); the editor applies it to the positions it had when it began, every time the mouse moves, so it never
/// drifts, and Esc or right-click puts them back.
package struct TransformOperation {
    package enum Kind: String { case translate, rotate, scale
        package var title: String { self == .translate ? "Move" : self == .rotate ? "Rotate" : "Resize" }
    }
    package enum Constraint: Equatable {
        case none
        case axis(Int, local: Bool)
        case plane(Int, local: Bool)   // the plane without this axis
    }

    package var kind: Kind
    package var constraint: Constraint = .none
    /// Where it turns and scales round (world).
    package var pivot: SIMD3<Float>
    /// The global axes X, Y and Z name (Blender's Z up is the engine's Y: the editor gives that mapping).
    package var globalAxes = matrix_identity_float3x3
    /// The local axes (the object's rotation of the global ones): what a second X, Y or Z constrains to.
    package var localAxes = matrix_identity_float3x3
    /// A fixed direction to move along (extrude's normal): the start's constraint, until X, Y or Z.
    package var startMouse: SIMD2<Float>
    package var mouse: SIMD2<Float>
    package var numeric = NumericInput()
    package var snap = false
    package var precise = false
    /// Mouse travel while Shift was held counts a tenth (accumulated, so pressing Shift doesn't jump).
    private var preciseOffset = SIMD2<Float>.zero
    private var lastMouse: SIMD2<Float>

    package init(kind: Kind, pivot: SIMD3<Float>, mouse: SIMD2<Float>) {
        self.kind = kind
        self.pivot = pivot
        startMouse = mouse
        self.mouse = mouse
        lastMouse = mouse
    }

    /// The mouse moved to `p` (points, top-left origin).
    package mutating func move(to p: SIMD2<Float>) {
        if precise { preciseOffset += (p - lastMouse) * -0.9 }
        lastMouse = p
        mouse = p
    }

    private var effectiveMouse: SIMD2<Float> { mouse + preciseOffset }

    /// X, Y or Z pressed (with Shift: the plane): global, then local, then none.
    package mutating func press(axis: Int, plane: Bool) {
        switch constraint {
        case .axis(axis, false) where !plane, .plane(axis, false) where plane:
            constraint = plane ? .plane(axis, local: true) : .axis(axis, local: true)
        case .axis(axis, true) where !plane, .plane(axis, true) where plane:
            constraint = .none
        default:
            constraint = plane ? .plane(axis, local: false) : .axis(axis, local: false)
        }
    }

    package func axisVector(_ i: Int, local: Bool) -> SIMD3<Float> {
        simd_normalize(local ? localAxes[i] : globalAxes[i])
    }

    /// What the operation is now, given the view.
    package func matrix(camera: ViewportCamera, viewSize: SIMD2<Float>) -> float4x4 {
        switch kind {
        case .translate: return translation(delta(camera: camera, viewSize: viewSize))
        case .rotate:
            let (axis, angle) = rotation(camera: camera, viewSize: viewSize)
            let r = float4x4(simd_quatf(angle: angle, axis: axis))
            return translation(pivot) * r * translation(-pivot)
        case .scale:
            let s = scaleVector(camera: camera, viewSize: viewSize)
            // Scale along the constraint's frame.
            let frame = constraintFrame
            let f4 = float4x4(columns: (SIMD4(frame.columns.0, 0), SIMD4(frame.columns.1, 0), SIMD4(frame.columns.2, 0), SIMD4(0, 0, 0, 1)))
            let sm = float4x4(diagonal: SIMD4(s, 1))
            return translation(pivot) * f4 * sm * f4.transpose * translation(-pivot)
        }
    }

    private func translation(_ t: SIMD3<Float>) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    private var constraintFrame: float3x3 {
        switch constraint {
        case .axis(_, let local), .plane(_, let local):
            let a = local ? localAxes : globalAxes
            return float3x3(simd_normalize(a[0]), simd_normalize(a[1]), simd_normalize(a[2]))
        case .none: return globalAxes
        }
    }

    // MARK: Translate

    /// The move (world).
    package func delta(camera: ViewportCamera, viewSize: SIMD2<Float>) -> SIMD3<Float> {
        if let typed = numeric.values {
            switch constraint {
            case .axis(let i, let local): return axisVector(i, local: local) * typed.x
            case .plane(let i, let local):
                let a = axisVector((i + 1) % 3, local: local), b = axisVector((i + 2) % 3, local: local)
                return a * typed.x + b * typed.y
            case .none: return globalAxes * SIMD3(typed.x, typed.y, typed.z)
            }
        }
        let m = effectiveMouse
        var d: SIMD3<Float>
        switch constraint {
        case .axis(let i, let local):
            let axis = axisVector(i, local: local)
            d = axis * along(axis, camera: camera, viewSize: viewSize, mouse: m)
        case .plane(let i, let local):
            let n = axisVector(i, local: local)
            d = onPlane(n, camera: camera, viewSize: viewSize, mouse: m)
        case .none:
            let k = camera.metresPerPoint(depth: depth(camera), viewHeight: viewSize.y)
            let dm = m - startMouse
            d = (camera.right * dm.x - camera.up * dm.y) * k
        }
        if snap {
            let step: Float = precise ? 0.1 : 1
            d = (d / step).rounded(.toNearestOrAwayFromZero) * step
        }
        return d
    }

    private func depth(_ camera: ViewportCamera) -> Float { max(simd_dot(pivot - camera.eye, camera.forward), camera.near) }

    /// How far along `axis` the mouse has gone: its travel projected on the axis as the screen shows it.
    private func along(_ axis: SIMD3<Float>, camera: ViewportCamera, viewSize: SIMD2<Float>, mouse m: SIMD2<Float>) -> Float {
        guard let p0 = camera.project(pivot, size: viewSize), let p1 = camera.project(pivot + axis, size: viewSize) else { return 0 }
        let screen = SIMD2(p1.x - p0.x, p1.y - p0.y)
        let len2 = simd_length_squared(screen)
        // Seen end on: fall back to the view plane's scale.
        if len2 < 4 {
            let k = camera.metresPerPoint(depth: depth(camera), viewHeight: viewSize.y)
            return simd_length(m - startMouse) * k * ((m - startMouse).x >= 0 ? 1 : -1)
        }
        return simd_dot(m - startMouse, screen) / len2
    }

    /// The move within the plane through the pivot with normal `n`: where the mouse's ray meets it, from where the
    /// start's did.
    private func onPlane(_ n: SIMD3<Float>, camera: ViewportCamera, viewSize: SIMD2<Float>, mouse m: SIMD2<Float>) -> SIMD3<Float> {
        func hit(_ p: SIMD2<Float>) -> SIMD3<Float>? {
            let r = camera.ray(at: p, size: viewSize)
            let den = simd_dot(r.direction, n)
            guard abs(den) > 1e-4 else { return nil }
            let t = simd_dot(pivot - r.origin, n) / den
            return r.origin + r.direction * t
        }
        guard let a = hit(startMouse), let b = hit(m) else { return .zero }
        let d = b - a
        return d - n * simd_dot(d, n)
    }

    // MARK: Rotate

    /// The axis and angle (radians).
    package func rotation(camera: ViewportCamera, viewSize: SIMD2<Float>) -> (SIMD3<Float>, Float) {
        var axis = -camera.forward
        switch constraint {
        case .axis(let i, let local), .plane(let i, let local):
            axis = axisVector(i, local: local)
            // Turn the same way on screen as the mouse whichever way the axis faces.
            if simd_dot(axis, camera.forward) > 0 { axis = -axis }
        case .none: break
        }
        if let typed = numeric.values { return (axis, typed.x * .pi / 180) }
        guard let c = camera.project(pivot, size: viewSize) else { return (axis, 0) }
        let centre = SIMD2(c.x, c.y)
        let a0 = startMouse - centre, a1 = effectiveMouse - centre
        // Screen y is down: a counter-clockwise turn on screen is negative in these coordinates.
        var angle = -(atan2(a1.y, a1.x) - atan2(a0.y, a0.x))
        while angle > .pi { angle -= 2 * .pi }
        while angle < -.pi { angle += 2 * .pi }
        if snap { angle = (angle / (5 * .pi / 180)).rounded() * (5 * .pi / 180) }
        return (axis, angle)
    }

    // MARK: Scale

    package func scaleVector(camera: ViewportCamera, viewSize: SIMD2<Float>) -> SIMD3<Float> {
        var s: Float
        if let typed = numeric.values { s = typed.x } else {
            guard let c = camera.project(pivot, size: viewSize) else { return .one }
            let centre = SIMD2(c.x, c.y)
            let r0 = max(simd_distance(startMouse, centre), 1)
            s = simd_distance(effectiveMouse, centre) / r0
            if snap { s = (s / (precise ? 0.01 : 0.1)).rounded() * (precise ? 0.01 : 0.1) }
        }
        switch constraint {
        case .none: return SIMD3(repeating: s)
        case .axis(let i, _): var v = SIMD3<Float>.one; v[i] = s; return v
        case .plane(let i, _): var v = SIMD3<Float>(repeating: s); v[i] = 1; return v
        }
    }

    // MARK: Text

    /// The header's text while it runs: "Move  D: 0.5 (0.5)  along global X".
    package func status(camera: ViewportCamera, viewSize: SIMD2<Float>) -> String {
        var text: String
        switch kind {
        case .translate:
            let d = delta(camera: camera, viewSize: viewSize)
            switch constraint {
            case .axis(let i, let local):
                text = String(format: "D: %.4f (%.4f) along %@ %@", simd_dot(d, axisVector(i, local: local)), simd_length(d), local ? "local" : "global", ["X", "Y", "Z"][i])
            default: text = String(format: "Dx: %.4f  Dy: %.4f  Dz: %.4f (%.4f)", d.x, d.y, d.z, simd_length(d))
            }
        case .rotate:
            let (_, a) = rotation(camera: camera, viewSize: viewSize)
            text = String(format: "Rot: %.2f°", a * 180 / .pi)
        case .scale:
            let s = scaleVector(camera: camera, viewSize: viewSize)
            text = String(format: "Scale X: %.4f  Y: %.4f  Z: %.4f", s.x, s.y, s.z)
        }
        if numeric.isActive { text = "[\(numeric.text)|] " + text }
        return text
    }
}

/// What the user types during a transform: a number or a small expression (+ − × ÷, parentheses) per component;
/// Tab goes to the next component, Backspace removes a character, − at the start negates.
package struct NumericInput: Equatable {
    package var components: [String] = [""]
    package var current = 0

    package init() {}

    package var isActive: Bool { components.contains { !$0.isEmpty } }
    package var text: String { components[current] }

    /// The typed values (an empty component: 0, as Blender), nil while nothing is typed.
    package var values: SIMD3<Float>? {
        guard isActive else { return nil }
        var v = SIMD3<Float>.zero
        for i in 0..<min(3, components.count) { v[i] = NumericInput.evaluate(components[i]) ?? 0 }
        return v
    }

    /// A key typed: true if it was for this.
    @discardableResult
    package mutating func type(_ key: String) -> Bool {
        switch key {
        case "\t":
            current = (current + 1) % 3
            while components.count <= current { components.append("") }
            return true
        case "\u{7f}", "\u{8}":
            if !components[current].isEmpty { components[current].removeLast() }
            return true
        default:
            guard key.count == 1, let ch = key.first, "0123456789.-+*/()".contains(ch) else { return false }
            // A minus with nothing before it, or after a value: negate the whole (as Blender's toggling).
            if ch == "-" && (components[current].isEmpty || Double(components[current]) != nil) {
                if components[current].hasPrefix("-") { components[current].removeFirst() } else { components[current] = "-" + components[current] }
                return true
            }
            components[current].append(ch)
            return true
        }
    }

    /// A small expression's value (numbers, + − * /, parentheses), nil if it doesn't parse.
    package static func evaluate(_ s: String) -> Float? {
        let chars = Array(s.filter { !$0.isWhitespace })
        if chars.isEmpty { return nil }
        if chars == ["-"] { return nil }
        var i = 0
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func number() -> Double? {
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return Double(String(chars[start..<i]))
        }
        func factor() -> Double? {
            if peek() == "-" { i += 1; return factor().map { -$0 } }
            if peek() == "+" { i += 1; return factor() }
            if peek() == "(" {
                i += 1
                let v = expression()
                if peek() == ")" { i += 1 }
                return v
            }
            return number()
        }
        func term() -> Double? {
            guard var v = factor() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let r = factor() else { return v }
                v = c == "*" ? v * r : (r == 0 ? v : v / r)
            }
            return v
        }
        func expression() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return v }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        // Trailing operators ("2*"): what parses before them counts.
        return expression().map { Float($0) }
    }
}

/// Proportional editing's falloff (Blender's): how much of the transform a vertex at `x` (distance / radius, 0…1)
/// gets.
package enum ProportionalFalloff: String, CaseIterable, Codable {
    case smooth, sphere, root, inverseSquare, sharp, linear, constant

    package func weight(_ x: Float) -> Float {
        guard x < 1 else { return 0 }
        let t = max(0, 1 - x)
        switch self {
        case .smooth: return t * t * (3 - 2 * t)
        case .sphere: return (1 - (1 - t) * (1 - t)).squareRoot()
        case .root: return t.squareRoot()
        case .inverseSquare: return t * (2 - t)
        case .sharp: return t * t
        case .linear: return t
        case .constant: return 1
        }
    }
}

extension EditMesh {
    /// Each vertex's weight for proportional editing: 1 selected, the falloff of its distance to the nearest selected
    /// vertex (straight, or along edges if `connected`) within `radius`, else 0.
    package func proportionalWeights(radius: Float, falloff: ProportionalFalloff, connected: Bool) -> [Float] {
        var w = [Float](repeating: 0, count: vertexCount)
        let sel = selectedVertices
        guard !sel.isEmpty else { return w }
        for v in sel { w[v] = 1 }
        if connected {
            // Dijkstra over edges from the selection, out to the radius.
            let t = MeshTopology(self)
            var dist = [Float](repeating: .infinity, count: vertexCount)
            var heap: [(Float, Int)] = sel.map { (0, $0) }
            for v in sel { dist[v] = 0 }
            while !heap.isEmpty {
                let k = heap.indices.min { heap[$0].0 < heap[$1].0 }!
                let (d, v) = heap.remove(at: k)
                if d > dist[v] || d > radius { continue }
                for e in t.edges(ofVertex: v) {
                    let o = Int(MeshTopology.other(self, edge: Int(e), from: Int32(v)))
                    let nd = d + edgeLength(Int(e))
                    if nd < dist[o] && nd <= radius { dist[o] = nd; heap.append((nd, o)) }
                }
            }
            for v in 0..<vertexCount where !isSelected(vertex: v) && dist[v] < radius { w[v] = falloff.weight(dist[v] / radius) }
        } else {
            for v in 0..<vertexCount where !isSelected(vertex: v) && !isHidden(vertex: v) {
                var best = Float.infinity
                for s in sel { best = min(best, simd_distance(positions[v], positions[s])) }
                if best < radius { w[v] = falloff.weight(best / radius) }
            }
        }
        return w
    }

    /// The vertices with weights moved by `m` (in this mesh's space) from `start`: each blends from where it was to
    /// where the whole transform takes it.
    package mutating func apply(_ m: float4x4, weights: [Float], from start: [SIMD3<Float>]) {
        for v in 0..<min(vertexCount, start.count) {
            let w = weights[v]
            if w == 0 { positions[v] = start[v]; continue }
            let p = m * SIMD4(start[v], 1)
            positions[v] = simd_mix(start[v], SIMD3(p.x, p.y, p.z), SIMD3(repeating: w))
        }
        touch()
    }
}

/// Blender's axes in the engine's space: Blender is Z up, the engine Y up (as glTF: Blender's X, Y, Z are the
/// engine's X, −Z, Y). The editor shows and constrains in Blender's.
package enum BlenderAxes {
    /// Columns: Blender's X, Y and Z as engine vectors.
    package static let basis = float3x3(SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(0, 1, 0))

    /// An engine vector in Blender's coordinates, and back.
    package static func toBlender(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, -v.z, v.y) }
    package static func fromBlender(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, v.z, -v.y) }

    /// An object's local axes as Blender names them (its rotation of Blender's).
    package static func local(_ rotation: float3x3) -> float3x3 { rotation * basis }

    /// A rotation (engine space) as Blender's XYZ Euler angles in Blender's space, and back.
    package static func eulerInBlender(_ r: float3x3) -> SIMD3<Float> {
        ObjectTransform.euler(basis.transpose * r * basis)
    }
    package static func rotation(fromBlenderEuler e: SIMD3<Float>) -> float3x3 {
        basis * ObjectTransform(rotation: e).rotationMatrix * basis.transpose
    }

    /// A scale (along the object's own engine axes) as Blender's X, Y, Z: the engine's X, Z, Y.
    package static func scaleToBlender(_ s: SIMD3<Float>) -> SIMD3<Float> { SIMD3(s.x, s.z, s.y) }
    package static func scaleFromBlender(_ s: SIMD3<Float>) -> SIMD3<Float> { SIMD3(s.x, s.z, s.y) }
}
