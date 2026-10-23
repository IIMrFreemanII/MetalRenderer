import AppKit
import EngineCore
import Foundation
import Modeling
import simd

/// What a modal operator says after an event: keep running, done (keep the result), or cancelled (put things back);
/// `pass` lets the viewport have the event (navigation while it runs).
enum ModalResult { case running, finished, cancelled, pass }

/// An operator that runs across events, as Blender's modal operators: G, R, S, extrude-and-move, inset, bevel, loop
/// cut, knife, box and circle select, the sculpt brush's radius. It previews its result in the document (without an
/// undo step) and registers one step when it finishes.
protocol ModalOperator: AnyObject {
    var name: String { get }
    var hints: [(String, String)] { get }
    func status(_ m: ModelingModel) -> String
    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult
    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult
    func mouseUp(_ m: ModelingModel, button: Int, at p: SIMD2<Float>) -> ModalResult
    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult
    func scroll(_ m: ModelingModel, steps: Int) -> ModalResult
    func finish(_ m: ModelingModel)
    func cancel(_ m: ModelingModel)
}

extension ModalOperator {
    func mouseUp(_ m: ModelingModel, button: Int, at p: SIMD2<Float>) -> ModalResult { .running }
    func scroll(_ m: ModelingModel, steps: Int) -> ModalResult { .pass }
}

// MARK: - Transform (G, R, S)

final class TransformModal: ModalOperator {
    private var op: TransformOperation
    private let before: ModelingDocument
    private let undoName: String
    /// Released mouse confirms (a tool's drag, a gizmo handle).
    private let releaseConfirms: Bool
    private let startTransforms: [UUID: float4x4]
    private let startPositions: [SIMD3<Float>]
    private var weights: [Float]
    private let edit: Bool

    var name: String { op.kind.title }
    var hints: [(String, String)] {
        [("LMB", "Confirm"), ("RMB", "Cancel"), ("X Y Z", "Axis"), ("Shift X Y Z", "Plane"), ("Ctrl", "Snap"), ("Shift", "Precision"),
         ("G R S", "Switch"), ("0-9", "Type a value")]
    }

    /// Starts on the model's selection; `before` is the document the undo step goes back to (an extrude's, from before
    /// it made its faces).
    init?(_ m: ModelingModel, kind: TransformOperation.Kind, constraint: TransformOperation.Constraint = .none,
          axes: float3x3? = nil, releaseConfirms: Bool = false, undoName: String? = nil, before: ModelingDocument? = nil) {
        let doc = m.document
        edit = m.mode == .edit
        var pivot: SIMD3<Float>
        var transforms: [UUID: float4x4] = [:]
        var positions: [SIMD3<Float>] = []
        var w: [Float] = []
        if edit {
            guard let o = m.activeObject, o.mesh.hasSelection else { return nil }
            positions = o.mesh.positions
            let local = o.mesh.selectionCentre()!
            let wp = o.transform.matrix * SIMD4(local, 1)
            pivot = SIMD3(wp.x, wp.y, wp.z)
            w = m.proportional ? o.mesh.proportionalWeights(radius: m.proportionalSize, falloff: m.proportionalFalloff, connected: m.proportionalConnected)
                : o.mesh.vertFlags.map { $0 & EditMesh.Flag.select != 0 ? 1 : 0 }
        } else {
            let sel = doc.objects.filter { doc.selection.contains($0.id) }
            guard !sel.isEmpty else { return nil }
            pivot = sel.reduce(SIMD3<Float>.zero) { $0 + $1.transform.location } / Float(sel.count)
            for o in sel { transforms[o.id] = o.transform.matrix }
        }
        if m.pivotMode == .cursor { pivot = doc.cursor }
        if m.pivotMode == .active, let a = m.activeObject, !edit { pivot = a.transform.location }
        op = TransformOperation(kind: kind, pivot: pivot, mouse: m.mouse)
        op.constraint = constraint
        op.globalAxes = BlenderAxes.basis
        op.localAxes = axes ?? BlenderAxes.local(m.activeObject?.transform.rotationMatrix ?? matrix_identity_float3x3)
        startTransforms = transforms
        startPositions = positions
        weights = w
        self.releaseConfirms = releaseConfirms
        self.before = before ?? doc
        self.undoName = undoName ?? kind.title
    }

    func status(_ m: ModelingModel) -> String { op.status(camera: m.camera, viewSize: m.viewSize) }

    private func apply(_ m: ModelingModel) {
        let mat = op.matrix(camera: m.camera, viewSize: m.viewSize)
        var doc = m.document
        if edit, let i = m.activeIndex {
            let om = doc.objects[i].transform.matrix
            let local = om.inverse * mat * om
            doc.objects[i].mesh.apply(local, weights: weights, from: startPositions)
        } else {
            for (k, o) in doc.objects.enumerated() {
                guard let start = startTransforms[o.id] else { continue }
                doc.objects[k].transform = ObjectTransform(matrix: mat * start, keeping: o.transform)
            }
        }
        m.setDocument(doc)
        m.refreshStatus()
    }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        op.snap = flags.contains(.control)
        op.precise = flags.contains(.shift)
        op.move(to: p)
        apply(m)
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        if button == 0 { return .finished }
        if button == 1 { return .cancelled }
        return .pass
    }

    func mouseUp(_ m: ModelingModel, button: Int, at p: SIMD2<Float>) -> ModalResult {
        releaseConfirms && button == 0 ? .finished : .running
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult {
        switch k.key {
        case "esc": return .cancelled
        case "return", "space", "numpadenter": return .finished
        case "x", "y", "z":
            op.press(axis: ["x": 0, "y": 1, "z": 2][k.key]!, plane: k.shift)
        case "g": op.kind = .translate
        case "r": op.kind = .rotate
        case "s": op.kind = .scale
        case "o" where edit:
            m.proportional.toggle()
            recomputeWeights(m)
        case "pageup", "pagedown":
            m.proportionalSize *= k.key == "pageup" ? 1.1 : 1 / 1.1
            recomputeWeights(m)
        default:
            let typed: String
            switch k.key {
            case "backspace": typed = "\u{7f}"
            case "tab": typed = "\t"
            case "numpad.": typed = "."
            case "numpad-": typed = "-"
            case "numpad+": typed = "+"
            case "numpad*": typed = "*"
            case "numpad/": typed = "/"
            case let s where s.hasPrefix("numpad") && s.count == 7: typed = String(s.last!)
            case "=": typed = k.shift ? "+" : "="
            case "8" where k.shift: typed = "*"
            case "9" where k.shift: typed = "("
            case "0" where k.shift: typed = ")"
            default: typed = k.key
            }
            if !op.numeric.type(typed) { return .running }
        }
        apply(m)
        return .running
    }

    func scroll(_ m: ModelingModel, steps: Int) -> ModalResult {
        guard edit && m.proportional else { return .pass }
        m.proportionalSize *= pow(1.1, Float(steps))
        recomputeWeights(m)
        apply(m)
        return .running
    }

    private func recomputeWeights(_ m: ModelingModel) {
        guard edit, let o = m.activeObject else { return }
        var mesh = o.mesh
        mesh.positions = startPositions
        weights = m.proportional ? mesh.proportionalWeights(radius: m.proportionalSize, falloff: m.proportionalFalloff, connected: m.proportionalConnected)
            : mesh.vertFlags.map { $0 & EditMesh.Flag.select != 0 ? 1 : 0 }
    }

    func finish(_ m: ModelingModel) {
        m.registerUndo(undoName, before: before)
        m.documentChanged(dirty: true)
    }

    func cancel(_ m: ModelingModel) {
        // Back to where it started (an extrude keeps its new faces where they were made, as Blender's).
        var doc = m.document
        if edit, let i = m.activeIndex {
            doc.objects[i].mesh.apply(matrix_identity_float4x4, weights: weights, from: startPositions)
        } else {
            for (k, o) in doc.objects.enumerated() where startTransforms[o.id] != nil {
                doc.objects[k].transform = before.objects.first { $0.id == o.id }?.transform ?? o.transform
            }
        }
        m.setDocument(doc)
        if undoName != op.kind.title {
            // An extrude: the geometry stays, as its own step.
            m.registerUndo(undoName, before: before)
        }
        m.documentChanged(dirty: undoName != op.kind.title)
    }
}

extension ObjectTransform {
    /// A matrix as location, rotation and scale (a shear it can't say is dropped). The rotation is taken near
    /// `keeping`'s where the matrix says the same turn (so angles past 180° don't jump).
    init(matrix m: float4x4, keeping old: ObjectTransform) {
        let c0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), c1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        var s = SIMD3(simd_length(c0), simd_length(c1), simd_length(c2))
        if simd_dot(simd_cross(c0, c1), c2) < 0 { s.x = -s.x }
        let r = float3x3(c0 / max(abs(s.x), 1e-12) * (s.x < 0 ? -1 : 1), c1 / max(s.y, 1e-12), c2 / max(s.z, 1e-12))
        var e = ObjectTransform.euler(r)
        // Unwrap toward the old angles.
        for i in 0..<3 {
            while e[i] - old.rotation[i] > .pi { e[i] -= 2 * .pi }
            while e[i] - old.rotation[i] < -.pi { e[i] += 2 * .pi }
        }
        self.init(location: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), rotation: e, scale: s)
    }
}

// MARK: - Inset and bevel (sized with the mouse)

/// Inset (I) and Bevel (Ctrl-B): the amount follows the mouse's distance from the selection's centre on screen;
/// typed values, I (individual), V (vertices), the wheel (segments).
final class AmountModal: ModalOperator {
    enum Kind { case inset, bevel(vertices: Bool) }
    private var kind: Kind
    private let before: ModelingDocument
    private let mesh: EditMesh
    private let index: Int
    private let centre: SIMD2<Float>
    private let startDistance: Float
    private let metres: Float
    private var amount: Float = 0
    private var depth: Float = 0
    private var segments = 1
    private var individual = false
    private var numeric = NumericInput()
    private let releaseConfirms: Bool

    var name: String {
        switch kind {
        case .inset: "Inset Faces"
        case .bevel(let v): v ? "Bevel Vertices" : "Bevel"
        }
    }
    var hints: [(String, String)] {
        switch kind {
        case .inset: [("LMB", "Confirm"), ("RMB", "Cancel"), ("I", "Individual"), ("Ctrl", "Depth"), ("0-9", "Thickness")]
        case .bevel: [("LMB", "Confirm"), ("RMB", "Cancel"), ("Wheel", "Segments"), ("V", "Vertices"), ("0-9", "Width")]
        }
    }

    init?(_ m: ModelingModel, kind: Kind, releaseConfirms: Bool = false) {
        guard let i = m.activeIndex, m.mode == .edit else { return nil }
        let o = m.document.objects[i]
        guard o.mesh.hasSelection else { return nil }
        if case .inset = kind, o.mesh.selectedFaces.isEmpty { return nil }
        if case .bevel(false) = kind, o.mesh.selectedEdges.isEmpty { return nil }
        self.kind = kind
        before = m.document
        mesh = o.mesh
        index = i
        let c = o.transform.matrix * SIMD4(o.mesh.selectionCentre()!, 1)
        let world = SIMD3(c.x, c.y, c.z)
        let s = m.camera.project(world, size: m.viewSize) ?? SIMD3(m.viewSize.x / 2, m.viewSize.y / 2, m.camera.distance)
        centre = SIMD2(s.x, s.y)
        startDistance = max(simd_distance(m.mouse, centre), 20)
        metres = m.camera.metresPerPoint(depth: max(s.z, m.camera.near), viewHeight: m.viewSize.y)
        self.releaseConfirms = releaseConfirms
    }

    func status(_ m: ModelingModel) -> String {
        let typed = numeric.isActive ? "[\(numeric.text)|] " : ""
        switch kind {
        case .inset: return typed + String(format: "Thickness: %.4f  Depth: %.4f%@", amount, depth, individual ? "  Individual" : "")
        case .bevel: return typed + String(format: "Width: %.4f  Segments: %d", amount, segments)
        }
    }

    private func apply(_ m: ModelingModel) {
        var doc = before
        var mm = mesh
        if let typed = numeric.values { amount = typed.x }
        switch kind {
        case .inset: mm.inset(thickness: amount, depth: depth, individual: individual)
        case .bevel(let v): if v { mm.bevelVertices(width: amount, segments: segments) } else { mm.bevelEdges(width: amount, segments: segments) }
        }
        doc.objects[index].mesh = mm
        m.setDocument(doc)
        m.refreshStatus()
    }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        guard !numeric.isActive else { return .running }
        let d = simd_distance(p, centre)
        switch kind {
        case .inset:
            // Toward the centre: thicker; Ctrl: the depth instead.
            if flags.contains(.control) { depth = (startDistance - d) * metres * 0.5 } else { amount = max(0, startDistance - d) * metres }
        case .bevel:
            amount = max(0, d - startDistance * 0.5) * metres * 0.5
        }
        if flags.contains(.shift) { amount = (amount / 0.01).rounded() * 0.01 }
        apply(m)
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        button == 0 ? .finished : button == 1 ? .cancelled : .pass
    }

    func mouseUp(_ m: ModelingModel, button: Int, at p: SIMD2<Float>) -> ModalResult {
        releaseConfirms && button == 0 ? .finished : .running
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult {
        switch k.key {
        case "esc": return .cancelled
        case "return", "space", "numpadenter": return .finished
        case "i": individual.toggle()
        case "v": if case .bevel(let v) = kind { kind = .bevel(vertices: !v) }
        case "pageup", "=": segments = min(64, segments + 1)
        case "pagedown", "-" where !numeric.isActive: segments = max(1, segments - 1)
        case "backspace": numeric.type("\u{7f}")
        default:
            let key = k.key.hasPrefix("numpad") && k.key.count == 7 ? String(k.key.last!) : k.key == "numpad." ? "." : k.key
            if !numeric.type(key) { return .running }
        }
        apply(m)
        return .running
    }

    func scroll(_ m: ModelingModel, steps: Int) -> ModalResult {
        guard case .bevel = kind else { return .pass }
        segments = max(1, min(64, segments + steps))
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

// MARK: - Loop cut

/// Ctrl-R / the Loop Cut tool: the ring under the mouse previewed (yellow); the wheel sets the cuts; a click cuts,
/// then the mouse slides a single cut along the ring until a second click (right-click: in the middle).
final class LoopCutModal: ModalOperator {
    private let before: ModelingDocument
    private let index: Int
    private var edge: Int?
    private var cuts = 1
    private var sliding = false
    private var slide: Float = 0
    private var slideStart = SIMD2<Float>.zero
    private var slideAxis = SIMD2<Float>(1, 0)
    private var cutMesh: EditMesh?

    var name: String { "Loop Cut and Slide" }
    var hints: [(String, String)] {
        sliding ? [("LMB", "Confirm"), ("RMB", "Centre")] : [("LMB", "Cut"), ("Wheel", "Number of Cuts"), ("RMB", "Cancel")]
    }

    init?(_ m: ModelingModel) {
        guard let i = m.activeIndex, m.mode == .edit else { return nil }
        before = m.document
        index = i
        hover(m, m.mouse)
    }

    func status(_ m: ModelingModel) -> String { sliding ? String(format: "Edge Slide %.3f", slide) : "Number of Cuts: \(cuts)" }

    private func hover(_ m: ModelingModel, _ p: SIMD2<Float>) {
        edge = m.edgeUnder(p)
        preview(m)
    }

    private func preview(_ m: ModelingModel) {
        guard let e = edge else { m.previewLines = []; m.redraw(); return }
        var mesh = before.objects[index].mesh
        mesh.selectAll(false)
        mesh.loopCut(e, cuts: cuts)
        // The new loops' edges: both ends new.
        let old = before.objects[index].mesh.vertexCount
        let om = before.objects[index].transform.matrix
        var lines: [OverlayLine] = []
        for (k, ed) in mesh.edges.enumerated() where Int(ed.x) >= old && Int(ed.y) >= old && mesh.isSelected(edge: k) {
            let a = om * SIMD4(mesh.positions[Int(ed.x)], 1), b = om * SIMD4(mesh.positions[Int(ed.y)], 1)
            lines.append(OverlayLine(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z), color: linearColor(0xFFFF00), width: 1.5))
        }
        m.previewLines = lines
        m.redraw()
    }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        if sliding, let e = edge {
            slide = max(-1, min(1, simd_dot(p - slideStart, slideAxis) / max(simd_length(slideAxis) * simd_length(slideAxis), 1) * 2))
            var doc = before
            doc.objects[index].mesh.selectAll(false)
            doc.objects[index].mesh.loopCut(e, cuts: 1, slide: slide)
            m.setDocument(doc)
            m.refreshStatus()
        } else {
            hover(m, p)
        }
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        if button == 1 {
            if sliding { slide = 0; return .finished }
            return .cancelled
        }
        guard button == 0 else { return .pass }
        if sliding { return .finished }
        guard let e = edge else { return .running }
        var doc = before
        doc.objects[index].mesh.selectAll(false)
        doc.objects[index].mesh.loopCut(e, cuts: cuts)
        m.setDocument(doc)
        m.previewLines = []
        if cuts > 1 { return .finished }
        // Slide along the edge as the screen shows it.
        let mesh = before.objects[index].mesh, om = before.objects[index].transform.matrix
        let a = om * SIMD4(mesh.positions[Int(mesh.edges[e].x)], 1), b = om * SIMD4(mesh.positions[Int(mesh.edges[e].y)], 1)
        if let pa = m.camera.project(SIMD3(a.x, a.y, a.z), size: m.viewSize), let pb = m.camera.project(SIMD3(b.x, b.y, b.z), size: m.viewSize) {
            slideAxis = SIMD2(pb.x - pa.x, pb.y - pa.y)
        }
        slideStart = p
        sliding = true
        m.refreshStatus()
        return .running
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult {
        switch k.key {
        case "esc": return sliding ? .finished : .cancelled
        case "return", "space": return sliding ? .finished : .running
        case "pageup", "=", "numpad+": cuts = min(64, cuts + 1); preview(m)
        case "pagedown", "-", "numpad-": cuts = max(1, cuts - 1); preview(m)
        default: break
        }
        m.refreshStatus()
        return .running
    }

    func scroll(_ m: ModelingModel, steps: Int) -> ModalResult {
        guard !sliding else { return .pass }
        cuts = max(1, min(64, cuts + steps))
        preview(m)
        m.refreshStatus()
        return .running
    }

    func finish(_ m: ModelingModel) {
        if sliding && slide == 0, let e = edge {
            var doc = before
            doc.objects[index].mesh.selectAll(false)
            doc.objects[index].mesh.loopCut(e, cuts: 1)
            m.setDocument(doc)
        }
        m.previewLines = []
        m.registerUndo(name, before: before)
        m.documentChanged(dirty: true)
    }

    func cancel(_ m: ModelingModel) {
        m.previewLines = []
        m.setDocument(before)
        m.documentChanged()
    }
}

// MARK: - Knife

/// K: clicks make a line over the view, Return or Space cuts along it; Z cuts through the back too; Backspace takes
/// the last point back.
final class KnifeModal: ModalOperator {
    private let before: ModelingDocument
    private let index: Int
    private var points: [SIMD2<Float>] = []
    private var throughAll = false
    private var mouse: SIMD2<Float>

    var name: String { "Knife" }
    var hints: [(String, String)] { [("LMB", "Add Point"), ("Return", "Confirm"), ("Esc", "Cancel"), ("Z", "Cut Through"), ("Backspace", "Undo Point")] }

    init?(_ m: ModelingModel) {
        guard let i = m.activeIndex, m.mode == .edit else { return nil }
        before = m.document
        index = i
        mouse = m.mouse
    }

    func status(_ m: ModelingModel) -> String { "Knife: \(points.count) points\(throughAll ? ", cutting through" : "")" }

    private func preview(_ m: ModelingModel) {
        let path = points + [mouse]
        var lines: [OverlayLine] = []
        for i in 0..<max(0, path.count - 1) {
            // On a plane in front of the camera (the line is drawn without depth).
            let a = m.camera.ray(at: path[i], size: m.viewSize), b = m.camera.ray(at: path[i + 1], size: m.viewSize)
            let d = m.camera.near * 20
            lines.append(OverlayLine(a.origin + a.direction * d, b.origin + b.direction * d, color: linearColor(0x80FF40), width: 1.5, dashed: i == path.count - 2))
        }
        m.previewLines = lines
        m.redraw()
    }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        mouse = p
        preview(m)
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        if button == 1 { return points.count >= 2 ? .finished : .cancelled }
        guard button == 0 else { return .pass }
        points.append(p)
        preview(m)
        m.refreshStatus()
        return .running
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult {
        switch k.key {
        case "esc": return .cancelled
        case "return", "space", "numpadenter": return .finished
        case "z": throughAll.toggle()
        case "backspace": if !points.isEmpty { points.removeLast() }
        default: break
        }
        preview(m)
        m.refreshStatus()
        return .running
    }

    func finish(_ m: ModelingModel) {
        m.previewLines = []
        guard points.count >= 2 else { cancel(m); return }
        var doc = before
        let o = doc.objects[index]
        doc.objects[index].mesh.knife(points, camera: m.camera, viewSize: m.viewSize, objectMatrix: o.transform.matrix, throughAll: throughAll)
        m.setDocument(doc)
        m.registerUndo(name, before: before)
        m.documentChanged(dirty: true)
    }

    func cancel(_ m: ModelingModel) {
        m.previewLines = []
        m.setDocument(before)
        m.documentChanged()
    }
}

// MARK: - Box and circle select

/// B or a drag of the select tool: a rectangle; what is inside is selected (Shift adds, Ctrl takes away).
final class BoxSelectModal: ModalOperator {
    enum Op { case set, add, subtract }
    private var start: SIMD2<Float>?
    private var op: Op
    private let dragging: Bool

    var name: String { "Box Select" }
    var hints: [(String, String)] { [("LMB", "Select"), ("Shift", "Extend"), ("Ctrl", "Subtract"), ("RMB", "Cancel")] }

    init(_ m: ModelingModel, startingAt p: SIMD2<Float>? = nil, op: Op) {
        start = p
        self.op = op
        dragging = p != nil
    }

    func status(_ m: ModelingModel) -> String { "Box Select" }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        if let s = start { m.selectionRect = CGRect(x: CGFloat(min(s.x, p.x)), y: CGFloat(min(s.y, p.y)), width: CGFloat(abs(p.x - s.x)), height: CGFloat(abs(p.y - s.y))) }
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        if button == 1 { return .cancelled }
        if start == nil {
            start = p
            if button == 2 || flags.contains(.shift) && !dragging { op = .subtract }
            return .running
        }
        return .running
    }

    func mouseUp(_ m: ModelingModel, button: Int, at p: SIMD2<Float>) -> ModalResult {
        guard start != nil else { return .running }
        return .finished
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult { k.key == "esc" ? .cancelled : .running }

    func finish(_ m: ModelingModel) {
        defer { m.selectionRect = nil }
        guard let r = m.selectionRect, r.width > 1 || r.height > 1 else { return }
        m.select(inside: r, op: op)
    }

    func cancel(_ m: ModelingModel) { m.selectionRect = nil }
}

/// C: a circle that selects what it passes over while the left button is down (middle or Shift: deselects); the
/// wheel sizes it; right-click, Esc or Return ends it.
final class CircleSelectModal: ModalOperator {
    private var radius: Float
    private var painting: Bool?
    private let before: ModelingDocument

    var name: String { "Circle Select" }
    var hints: [(String, String)] { [("LMB", "Select"), ("MMB", "Deselect"), ("Wheel", "Radius"), ("RMB", "Done")] }

    init(_ m: ModelingModel) {
        radius = 25
        before = m.document
        m.selectionCircle = (m.mouse, radius)
    }

    func status(_ m: ModelingModel) -> String { "Circle Select" }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        m.selectionCircle = (p, radius)
        if let on = painting { m.select(inCircle: p, radius: radius, on: on) }
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        if button == 1 { return .finished }
        painting = !(button == 2 || flags.contains(.shift))
        m.select(inCircle: p, radius: radius, on: painting!)
        return .running
    }

    func mouseUp(_ m: ModelingModel, button: Int, at p: SIMD2<Float>) -> ModalResult {
        painting = nil
        return .running
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult {
        ["esc", "return", "space"].contains(k.key) ? .finished : .running
    }

    func scroll(_ m: ModelingModel, steps: Int) -> ModalResult {
        radius = max(4, min(400, radius * pow(1.15, Float(-steps))))
        m.selectionCircle = (m.mouse, radius)
        return .running
    }

    func finish(_ m: ModelingModel) {
        m.selectionCircle = nil
        m.registerUndo("Circle Select", before: before)
        m.documentChanged()
    }

    func cancel(_ m: ModelingModel) { finish(m) }
}
