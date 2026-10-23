import AppKit
import EngineCore
import Foundation
import Modeling
import simd

// MARK: - Edge slide (G G, Shift-V)

/// Edge slide (G pressed again while grabbing, or Shift-V): the selected edges' vertices slide along the edges that
/// leave them, toward one side or the other as the mouse goes; lone vertices slide along the edge the mouse points
/// down (vertex slide). Typed values are the factor (−1…1).
final class EdgeSlideModal: ModalOperator {
    private let before: ModelingDocument
    private let undoName: String
    private let index: Int
    private let mesh: EditMesh
    private var slide: EdgeSlide
    private let axes: (a: SIMD2<Float>, b: SIMD2<Float>)
    private let project: (SIMD3<Float>) -> SIMD2<Float>?
    private let start: SIMD2<Float>
    private var factor: Float = 0
    private var toward = SIMD2<Float>.zero
    private var numeric = NumericInput()

    var name: String { slide.chains > 0 ? "Edge Slide" : "Vertex Slide" }
    var hints: [(String, String)] { [("LMB", "Confirm"), ("RMB", "Cancel"), ("0-9", "Factor")] }

    /// On the active mesh's selection as it is now; `before` and `undoName`: the step it finishes (a grab's G G: the
    /// document from before the grab).
    init?(_ m: ModelingModel, before: ModelingDocument? = nil, undoName: String? = nil) {
        guard let i = m.activeIndex, m.mode == .edit, let s = EdgeSlide(m.document.objects[i].mesh) else { return nil }
        let o = m.document.objects[i]
        let om = o.transform.matrix, camera = m.camera, size = m.viewSize
        project = { p in
            let w = om * SIMD4(p, 1)
            return camera.project(SIMD3(w.x, w.y, w.z), size: size).map { SIMD2($0.x, $0.y) }
        }
        slide = s
        axes = slide.alignSides(project)
        index = i
        mesh = o.mesh
        self.before = before ?? m.document
        self.undoName = undoName ?? (s.chains > 0 ? "Edge Slide" : "Vertex Slide")
        start = m.mouse
    }

    func status(_ m: ModelingModel) -> String {
        (numeric.isActive ? "[\(numeric.text)|] " : "") + String(format: "%@: %.3f", name, factor)
    }

    private func apply(_ m: ModelingModel) {
        if let typed = numeric.values { factor = max(-1, min(1, typed.x)) }
        var doc = m.document
        doc.objects[index].mesh = mesh
        slide.apply(to: &doc.objects[index].mesh, factor: factor, toward: toward, project: project)
        m.setDocument(doc)
        m.refreshStatus()
    }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        guard !numeric.isActive else { return .running }
        let d = p - start
        toward = d
        let la = simd_length_squared(axes.a), lb = simd_length_squared(axes.b)
        let ta = la > 1e-6 ? simd_dot(d, axes.a) / la : 0
        if ta >= 0 && la > 1e-6 {
            factor = min(1, ta)
        } else {
            factor = lb > 1e-6 ? -min(1, max(0, simd_dot(d, axes.b) / lb)) : 0
        }
        if flags.contains(.control) { factor = (factor * 10).rounded() / 10 }
        apply(m)
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        button == 0 ? .finished : button == 1 ? .cancelled : .pass
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult {
        switch k.key {
        case "esc": return .cancelled
        case "return", "space", "numpadenter": return .finished
        case "backspace": numeric.type("\u{7f}")
        default:
            let key = k.key.hasPrefix("numpad") && k.key.count == 7 ? String(k.key.last!) : k.key == "numpad." ? "." : k.key
            if !numeric.type(key) { return .running }
        }
        apply(m)
        return .running
    }

    func finish(_ m: ModelingModel) {
        m.registerUndo(undoName, before: before)
        m.documentChanged(dirty: true)
    }

    func cancel(_ m: ModelingModel) {
        var doc = m.document
        doc.objects[index].mesh = mesh
        m.setDocument(doc)
        // (After a duplicate's G G: the copy stays, as its own step.)
        let kept = undoName != name
        if kept { m.registerUndo(undoName, before: before) }
        m.documentChanged(dirty: kept)
    }
}

// MARK: - Spin

/// Spin: the selection extruded in steps round an axis through the 3D cursor (the view's, or X Y Z), as far as the
/// mouse turns it round the cursor on screen (as R does); the wheel or Page Up / Down sets the steps, typed values
/// the angle in degrees (360 closes it), Ctrl snaps to 5°.
final class SpinModal: ModalOperator {
    private let before: ModelingDocument
    private let index: Int
    private let mesh: EditMesh
    private let centre: SIMD3<Float>          // the cursor, in the mesh's space
    private let centreOnScreen: SIMD2<Float>
    private let matrix: float4x4
    private let view: SIMD3<Float>            // toward the viewer (world)
    private var axis: Int? = nil              // a global axis, or the view's
    private var steps = 12
    private var angle: Float = 0              // radians
    private var turned: Float = 0             // the mouse's turn round the centre on screen
    private var lastMouseAngle: Float
    private var snap = false
    private var numeric = NumericInput()

    var name: String { "Spin" }
    var hints: [(String, String)] {
        [("LMB", "Confirm"), ("RMB", "Cancel"), ("Wheel", "Steps"), ("X Y Z", "Axis"), ("0-9", "Angle"), ("Ctrl", "Snap")]
    }

    init?(_ m: ModelingModel) {
        guard let i = m.activeIndex, m.mode == .edit, m.document.objects[i].mesh.hasSelection else { return nil }
        before = m.document
        index = i
        mesh = m.document.objects[i].mesh
        matrix = m.document.objects[i].transform.matrix
        let c = matrix.inverse * SIMD4(m.document.cursor, 1)
        centre = SIMD3(c.x, c.y, c.z)
        let s = m.camera.project(m.document.cursor, size: m.viewSize)
        centreOnScreen = s.map { SIMD2($0.x, $0.y) } ?? m.viewSize / 2
        view = -m.camera.forward
        lastMouseAngle = atan2(m.mouse.y - centreOnScreen.y, m.mouse.x - centreOnScreen.x)
    }

    private var worldAxis: SIMD3<Float> {
        guard let a = axis else { return view }
        var v = SIMD3<Float>.zero
        v[a] = 1
        return v
    }

    func status(_ m: ModelingModel) -> String {
        let axisName = axis.map { ["X", "Y", "Z"][$0] } ?? "View"
        return (numeric.isActive ? "[\(numeric.text)|] " : "") + String(format: "Spin %.1f°  Steps: %d  Axis: %@", angle * 180 / .pi, steps, axisName)
    }

    private func apply(_ m: ModelingModel) {
        if let typed = numeric.values {
            angle = typed.x * .pi / 180
        } else {
            // Counter-clockwise on screen about an axis toward the viewer (turned the other way for one away from it).
            let toward: Float = simd_dot(worldAxis, view) < 0 ? -1 : 1
            angle = -turned * toward
            if snap { angle = (angle / (5 * .pi / 180)).rounded() * (5 * .pi / 180) }
        }
        var doc = before
        let a4 = matrix.inverse * SIMD4(worldAxis, 0)
        doc.objects[index].mesh = mesh
        doc.objects[index].mesh.spin(steps: steps, angle: angle, centre: centre, axis: SIMD3(a4.x, a4.y, a4.z))
        m.setDocument(doc)
        m.refreshStatus()
    }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        snap = flags.contains(.control)
        let a = atan2(p.y - centreOnScreen.y, p.x - centreOnScreen.x)
        var d = a - lastMouseAngle
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        turned += d
        lastMouseAngle = a
        apply(m)
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        button == 0 ? .finished : button == 1 ? .cancelled : .pass
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult {
        switch k.key {
        case "esc": return .cancelled
        case "return", "space", "numpadenter": return .finished
        case "x", "y", "z":
            let a = ["x": 0, "y": 1, "z": 2][k.key]!
            axis = axis == a ? nil : a
        case "pageup", "=", "numpad+": steps = min(256, steps + 1)
        case "pagedown", "numpad-": steps = max(1, steps - 1)
        case "backspace": numeric.type("\u{7f}")
        default:
            let key = k.key.hasPrefix("numpad") && k.key.count == 7 ? String(k.key.last!) : k.key == "numpad." ? "." : k.key
            if !numeric.type(key) { return .running }
        }
        apply(m)
        return .running
    }

    func scroll(_ m: ModelingModel, steps s: Int) -> ModalResult {
        steps = max(1, min(256, steps + s))
        apply(m)
        return .running
    }

    func finish(_ m: ModelingModel) {
        m.registerUndo(name, before: before)
        m.documentChanged(dirty: true)
    }

    func cancel(_ m: ModelingModel) {
        m.setDocument(before)
        m.documentChanged()
    }
}
