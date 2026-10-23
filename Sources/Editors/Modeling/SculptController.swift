import AppKit
import EngineCore
import Foundation
import Modeling
import simd

/// Sculpt mode in the window: the active object's sculpt mesh and how it draws, the brush's strokes from the mouse
/// or the pen, the cursor ring, and its undo steps (one per stroke, swapping the leaves it changed).
final class SculptController {
    let mesh: SculptMesh
    let objectID: UUID
    let drawing: SculptDrawing?
    private var stroke: SculptStroke?
    private var lastHit: SIMD3<Float>?           // object space
    private var hover: (point: SIMD3<Float>, normal: SIMD3<Float>)?
    private var smoothing = false
    private var inverted = false
    /// Multires: the level being sculpted (nil: the base mesh).
    var multiresLevel: Int?

    var vertexCount: Int { mesh.vertexCount }
    var triangleCount: Int { mesh.triangleCount }

    init?(model m: ModelingModel) {
        guard let o = m.activeObject else { return nil }
        objectID = o.id
        mesh = SculptController.makeMesh(o)
        multiresLevel = SculptController.level(o)
        drawing = m.renderer.map { SculptDrawing(device: $0.device) }
        if !o.sculptMasks.isEmpty, o.sculptMasks.count == o.mesh.vertexCount { mesh.setMasks(o.sculptMasks) }
    }

    /// The multires level sculpt mode works on, if the object has levels that fit its mesh.
    static func level(_ o: ModelObject) -> Int? {
        guard let r = o.multires, r.levels > 0, r.sculptLevel > 0, Multires.fits(o.mesh, r) else { return nil }
        return r.sculptLevel
    }

    /// What sculpt mode works on: the object's multires level if it has one, else its mesh.
    static func makeMesh(_ o: ModelObject) -> SculptMesh {
        if let r = o.multires, r.levels > 0, let level = Multires.sculptMesh(o.mesh, r) { return level }
        return SculptMesh(o.mesh)
    }

    // MARK: Drawing

    /// The viewport's buffers for the mesh, up to date (called before each frame).
    func prepare(_ m: ModelingModel) {
        guard let drawing else { return }
        m.scene?.overrides[objectID] = drawing.prepare(mesh)
    }

    /// The brush's ring where the mouse is over the surface.
    func cursorLines(_ m: ModelingModel) -> [OverlayLine] {
        prepare(m)
        guard let h = hover, let o = m.document.objects.first(where: { $0.id == objectID }) else { return [] }
        let om = o.transform.matrix
        let wp = om * SIMD4(h.point, 1)
        let centre = SIMD3(wp.x, wp.y, wp.z)
        let wn4 = om * SIMD4(h.normal, 0)
        var n = simd_normalize(SIMD3(wn4.x, wn4.y, wn4.z))
        if !n.x.isFinite { n = -m.camera.forward }
        let r = worldRadius(m, at: centre)
        let u = simd_normalize(abs(n.y) < 0.9 ? simd_cross(n, [0, 1, 0]) : simd_cross(n, [1, 0, 0])), v = simd_cross(n, u)
        var out: [OverlayLine] = []
        let k = 48
        for i in 0..<k {
            let a0 = Float(i) / Float(k) * 2 * .pi, a1 = Float(i + 1) / Float(k) * 2 * .pi
            out.append(OverlayLine(centre + (u * cos(a0) + v * sin(a0)) * r, centre + (u * cos(a1) + v * sin(a1)) * r,
                                   color: SIMD4(1, 1, 1, 0.85), width: 1.5))
        }
        // Strength: a smaller ring.
        let s = r * (0.2 + 0.8 * min(1, m.sculptBrush.strength))
        for i in 0..<k where i % 2 == 0 {
            let a0 = Float(i) / Float(k) * 2 * .pi, a1 = Float(i + 1) / Float(k) * 2 * .pi
            out.append(OverlayLine(centre + (u * cos(a0) + v * sin(a0)) * s, centre + (u * cos(a1) + v * sin(a1)) * s,
                                   color: SIMD4(1, 1, 1, 0.35), width: 1))
        }
        return out
    }

    /// The brush's radius in the world at a point (its radius on screen is in points).
    private func worldRadius(_ m: ModelingModel, at p: SIMD3<Float>) -> Float {
        let depth = max(simd_dot(p - m.camera.eye, m.camera.forward), m.camera.near)
        return m.sculptBrush.radius * m.camera.metresPerPoint(depth: depth, viewHeight: m.viewSize.y)
    }

    // MARK: Rays

    private func objectRay(_ m: ModelingModel, _ p: SIMD2<Float>) -> (origin: SIMD3<Float>, dir: SIMD3<Float>, matrix: float4x4)? {
        guard let o = m.document.objects.first(where: { $0.id == objectID }) else { return nil }
        let ray = m.camera.ray(at: p, size: m.viewSize)
        let om = o.transform.matrix, inv = om.inverse
        let lo = inv * SIMD4(ray.origin, 1), ld = inv * SIMD4(ray.direction, 0)
        return (SIMD3(lo.x, lo.y, lo.z), SIMD3(ld.x, ld.y, ld.z), om)
    }

    /// Where a point's ray meets the mesh (object space), and the normal there.
    private func hit(_ m: ModelingModel, _ p: SIMD2<Float>) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard let r = objectRay(m, p), let h = mesh.raycast(origin: r.origin, direction: r.dir) else { return nil }
        let t = h.triangle
        let a = mesh.position[Int(mesh.indices[3 * t])], b = mesh.position[Int(mesh.indices[3 * t + 1])], c = mesh.position[Int(mesh.indices[3 * t + 2])]
        let n = simd_normalize(simd_cross(SIMD3(b.x - a.x, b.y - a.y, b.z - a.z), SIMD3(c.x - a.x, c.y - a.y, c.z - a.z)))
        return (r.origin + r.dir * h.t, n)
    }

    /// Where a point's ray meets the plane facing the view through `through` (object space): off the surface.
    private func onViewPlane(_ m: ModelingModel, _ p: SIMD2<Float>, through q: SIMD3<Float>) -> SIMD3<Float>? {
        guard let r = objectRay(m, p) else { return nil }
        let inv = r.matrix.inverse
        let f4 = inv * SIMD4(m.camera.forward, 0)
        let n = simd_normalize(SIMD3(f4.x, f4.y, f4.z))
        let den = simd_dot(r.dir, n)
        guard abs(den) > 1e-8 else { return nil }
        let t = simd_dot(q - r.origin, n) / den
        return r.origin + r.dir * t
    }

    /// Object-space radius for a world radius (the object's mean scale).
    private func objectRadius(_ m: ModelingModel, _ world: Float) -> Float {
        guard let o = m.document.objects.first(where: { $0.id == objectID }) else { return world }
        let s = o.transform.scale
        return world / max((abs(s.x) + abs(s.y) + abs(s.z)) / 3, 1e-6)
    }

    // MARK: Strokes

    func hover(_ p: SIMD2<Float>, model m: ModelingModel) {
        hover = hit(m, p)
    }

    func beginStroke(at p: SIMD2<Float>, flags: NSEvent.ModifierFlags, pressure: Float, model m: ModelingModel) -> Bool {
        guard let h = hit(m, p) else { return false }
        smoothing = flags.contains(.shift)
        inverted = flags.contains(.control)
        var brush = m.sculptBrush
        if inverted { brush.subtract.toggle() }
        stroke = SculptStroke(mesh: mesh, brush: brush)
        // Dynamic topology changes the triangles: its undo step is the whole mesh.
        if m.dyntopo && dyntopoApplies(brush.kind) { stroke?.record.whole = mesh.snapshot() }
        lastHit = h.point
        hover = h
        apply(h.point, pressure: pressure, model: m)
        return true
    }

    func continueStroke(to p: SIMD2<Float>, flags: NSEvent.ModifierFlags, pressure: Float, model m: ModelingModel) {
        guard let stroke else { return }
        var point: SIMD3<Float>?
        if stroke.brush.kind == .grab, let start = stroke.grabStart {
            point = onViewPlane(m, p, through: start)
        } else if let h = hit(m, p) {
            point = h.point
            hover = h
        } else if let last = lastHit {
            point = onViewPlane(m, p, through: last)
        }
        guard let q = point else { return }
        lastHit = q
        apply(q, pressure: pressure, model: m)
    }

    private func apply(_ q: SIMD3<Float>, pressure: Float, model m: ModelingModel) {
        guard let stroke, let o = m.document.objects.first(where: { $0.id == objectID }) else { return }
        let b = stroke.brush
        let wp = o.transform.matrix * SIMD4(q, 1)
        var radius = objectRadius(m, worldRadius(m, at: SIMD3(wp.x, wp.y, wp.z)))
        if b.pressureRadius { radius *= max(0.05, pressure) }
        var strength = b.strength * (b.pressureStrength ? pressure : 1)
        if b.subtract { strength = -strength }
        stroke.move(to: q, radius: radius, strength: smoothing ? b.strength : strength, smooth: smoothing)
        if m.dyntopo && dyntopoApplies(b.kind) {
            // Detail in pixels on screen, as Blender's relative detail.
            let depth = max(simd_dot(SIMD3(wp.x, wp.y, wp.z) - m.camera.eye, m.camera.forward), m.camera.near)
            let detail = objectRadius(m, m.dyntopoDetail * m.camera.metresPerPoint(depth: depth, viewHeight: m.viewSize.y))
            for mirror in stroke.mirrors {
                if let refined = DynTopo.refine(mesh, centre: q * mirror, radius: radius, detail: detail) {
                    mesh.replace(with: refined)
                }
            }
        }
        drawing?.markDirty(stroke.dirty)
        if b.kind == .drawFaceSets { drawing?.markTrianglesDirty(mesh) }
        stroke.dirty.removeAll(keepingCapacity: true)
        m.redraw()
    }

    private func dyntopoApplies(_ k: SculptBrushKind) -> Bool { k != .grab && k != .mask && k != .drawFaceSets }

    func endStroke(model m: ModelingModel) {
        guard let stroke else { return }
        self.stroke = nil
        lastHit = nil
        register(stroke.record, name: smoothing ? "Smooth" : stroke.brush.kind.title, model: m)
        m.documentChanged(dirty: true)
    }

    /// One undo step that swaps the record's leaves back (and forth).
    func register(_ record: SculptUndoRecord, name: String, model m: ModelingModel) {
        guard !record.isEmpty else { return }
        m.undo.beginUndoGrouping()
        m.undo.registerUndo(withTarget: m) { [weak self] model in self?.swap(record, name: name, model: model) }
        m.undo.setActionName(name)
        m.undo.endUndoGrouping()
    }

    private func swap(_ record: SculptUndoRecord, name: String, model m: ModelingModel) {
        guard m.sculpt === self else { return }
        let changed = record.swap(into: mesh)
        if record.whole != nil { drawing?.markTrianglesDirty(mesh) } else {
            drawing?.markDirty(changed)
            if !record.faceSets.isEmpty { drawing?.markTrianglesDirty(mesh) }
        }
        m.undo.registerUndo(withTarget: m) { [weak self] model in self?.swap(record, name: name, model: model) }
        m.undo.setActionName(name)
        m.redraw()
    }

    // MARK: Into the document

    /// The sculpted shape into the object's mesh (or its multires level), without an undo step of its own.
    func commit(into m: ModelingModel) {
        guard let i = m.document.objects.firstIndex(where: { $0.id == objectID }) else { return }
        var d = m.document
        let o = d.objects[i]
        if let level = multiresLevel, var r = o.multires {
            Multires.store(mesh, level: level, base: o.mesh, into: &r)
            d.objects[i].multires = r
        } else if mesh.matches(o.mesh) {
            mesh.write(into: &d.objects[i].mesh)
        } else {
            d.objects[i].mesh = mesh.editMesh()
            d.objects[i].multires = nil
        }
        d.objects[i].sculptMasks = multiresLevel == nil ? mesh.masks(count: d.objects[i].mesh.vertexCount) : []
        m.setDocument(d)
    }

    /// The document changed under sculpt mode (an undo of an older step): the mesh again from it.
    func reload(from d: ModelingDocument, model m: ModelingModel) {
        guard let o = d.objects.first(where: { $0.id == objectID }) else { return }
        mesh.replace(with: SculptController.makeMesh(o))
        multiresLevel = SculptController.level(o)
        drawing?.markTrianglesDirty(mesh)
        m.redraw()
    }

    // MARK: Keys and actions

    func key(_ k: KeyChord, model m: ModelingModel) -> Bool { false }

    /// The wheel over the viewport with Ctrl: the radius (as Blender's F, quicker).
    func scroll(dy: Float, precise: Bool, model m: ModelingModel) -> Bool { false }

    func perform(_ action: ModelingAction, model m: ModelingModel) -> Bool {
        switch action {
        case .brush(let name):
            if let kind = SculptBrushKind(rawValue: name) { m.selectBrush(kind) }
        case .brushRadius: m.start(BrushSizeModal(m, strength: false))
        case .brushStrength: m.start(BrushSizeModal(m, strength: true))
        case .brushSize(let f): m.sculptBrush.radius = max(2, min(1000, m.sculptBrush.radius * f)); m.redraw()
        case .maskMenu: m.presentMenu(maskMenu(model: m), m.mouse)
        case .clearMask: maskOp("Clear Mask", model: m) { $0.setMask({ _ in 0 }, record: $1) }
        case .invertMask: maskOp("Invert Mask", model: m) { $0.setMask({ 1 - $0 }, record: $1) }
        case .faceSetsMenu: m.presentMenu(faceSetsMenu(model: m), m.mouse)
        case .hide(selected: true):
            let t = hit(m, m.mouse).flatMap { _ in objectRay(m, m.mouse).flatMap { mesh.raycast(origin: $0.origin, direction: $0.dir)?.triangle } }
            maskOp("Hide Face Sets", model: m, triangles: true) { $0.isolateFaceSet(of: t, record: $1) }
        case .reveal: maskOp("Reveal Face Sets", model: m, triangles: true) { $0.isolateFaceSet(of: nil, record: $1) }
        case .toggleDyntopo: m.toggleDyntopo()
        case .voxelRemesh: m.voxelRemesh()
        case .voxelSize: m.start(VoxelSizeModal(m))
        case .grab, .rotate, .scale, .selectAll, .deselectAll, .boxSelect, .circleSelect, .delete, .duplicate: return true
        default: return false
        }
        return true
    }

    /// A mask or face set operation on the whole mesh, as one undo step.
    func maskOp(_ name: String, model m: ModelingModel, triangles: Bool = false, _ op: (SculptMesh, SculptUndoRecord) -> Void) {
        let record = SculptUndoRecord(topology: mesh.topologyGeneration)
        op(mesh, record)
        if triangles { drawing?.markTrianglesDirty(mesh) } else { drawing?.markDirty(mesh.leaves.indices) }
        register(record, name: name, model: m)
        m.redraw()
    }

    func maskMenu(model m: ModelingModel) -> ModelingMenu {
        ModelingMenu(title: "Mask", items: [
            .init(title: "Invert Mask", shortcut: "Ctrl I", action: { [weak self, weak m] in
                guard let m else { return }
                self?.maskOp("Invert Mask", model: m) { $0.setMask({ 1 - $0 }, record: $1) }
            }),
            .init(title: "Fill Mask", action: { [weak self, weak m] in
                guard let m else { return }
                self?.maskOp("Fill Mask", model: m) { $0.setMask({ _ in 1 }, record: $1) }
            }),
            .init(title: "Clear Mask", shortcut: "Alt M", action: { [weak self, weak m] in
                guard let m else { return }
                self?.maskOp("Clear Mask", model: m) { $0.setMask({ _ in 0 }, record: $1) }
            }),
            .separator,
            .init(title: "Grow Mask", action: { [weak self, weak m] in
                guard let m else { return }
                self?.maskOp("Grow Mask", model: m) { $0.growMask(true, record: $1) }
            }),
            .init(title: "Shrink Mask", action: { [weak self, weak m] in
                guard let m else { return }
                self?.maskOp("Shrink Mask", model: m) { $0.growMask(false, record: $1) }
            }),
        ])
    }

    func faceSetsMenu(model m: ModelingModel) -> ModelingMenu {
        ModelingMenu(title: "Face Sets", items: [
            .init(title: "Face Set from Masked", action: { [weak self, weak m] in
                guard let m else { return }
                self?.maskOp("Face Set from Mask", model: m, triangles: true) { $0.faceSetsFromMask(record: $1) }
            }),
            .init(title: "Initialize by Loose Parts", action: { [weak self, weak m] in
                guard let m else { return }
                self?.maskOp("Face Sets by Loose Parts", model: m, triangles: true) { $0.faceSetsByLooseParts(record: $1) }
            }),
            .separator,
            .init(title: "Hide Others", shortcut: "H", action: { [weak m] in m?.perform(.hide(selected: true)) }),
            .init(title: "Show All", shortcut: "Alt H", action: { [weak m] in m?.perform(.reveal) }),
        ])
    }

    func menu(model m: ModelingModel) -> ModelingMenu {
        ModelingMenu(title: "Sculpt", items: [
            .init(title: "Mask", submenu: maskMenu(model: m)),
            .init(title: "Face Sets", submenu: faceSetsMenu(model: m)),
            .separator,
            .init(title: "Voxel Remesh", shortcut: "Ctrl R", action: { [weak m] in m?.voxelRemesh() }),
            .init(title: "Dynamic Topology", shortcut: "Ctrl D", action: { [weak m] in m?.toggleDyntopo() }),
        ])
    }
}

/// F / Shift-F in sculpt mode: the brush's radius (or strength) follows the mouse's distance from where it began.
final class BrushSizeModal: ModalOperator {
    private let strength: Bool
    private let centre: SIMD2<Float>
    private let before: Float

    var name: String { strength ? "Brush Strength" : "Brush Radius" }
    var hints: [(String, String)] { [("LMB", "Confirm"), ("RMB", "Cancel")] }

    init(_ m: ModelingModel, strength: Bool) {
        self.strength = strength
        before = strength ? m.sculptBrush.strength : m.sculptBrush.radius
        // The ring's edge under the mouse.
        centre = m.mouse - SIMD2(strength ? before * 100 : before, 0)
    }

    func status(_ m: ModelingModel) -> String {
        strength ? String(format: "Strength: %.3f", m.sculptBrush.strength) : String(format: "Radius: %.0f px", m.sculptBrush.radius)
    }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        let d = max(1, simd_distance(p, centre))
        if strength { m.sculptBrush.strength = min(1, d / 100) } else { m.sculptBrush.radius = min(1000, d) }
        m.selectionCircle = (centre, strength ? 100 * m.sculptBrush.strength : m.sculptBrush.radius)
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        button == 1 ? .cancelled : .finished
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult {
        k.key == "esc" ? .cancelled : (k.key == "return" || k.key == "space") ? .finished : .running
    }

    func finish(_ m: ModelingModel) { m.selectionCircle = nil }

    func cancel(_ m: ModelingModel) {
        if strength { m.sculptBrush.strength = before } else { m.sculptBrush.radius = before }
        m.selectionCircle = nil
    }
}

/// R in sculpt mode: the voxel size for Voxel Remesh, from the mouse.
final class VoxelSizeModal: ModalOperator {
    private let start: SIMD2<Float>
    private let before: Float

    var name: String { "Voxel Size" }
    var hints: [(String, String)] { [("LMB", "Confirm"), ("RMB", "Cancel")] }

    init(_ m: ModelingModel) {
        start = m.mouse
        before = m.voxelSize
    }

    func status(_ m: ModelingModel) -> String { String(format: "Voxel Size: %.4f m", m.voxelSize) }

    func mouseMoved(_ m: ModelingModel, to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        m.voxelSize = max(0.001, before * pow(1.01, p.x - start.x))
        return .running
    }

    func mouseDown(_ m: ModelingModel, button: Int, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) -> ModalResult {
        button == 1 ? .cancelled : .finished
    }

    func key(_ m: ModelingModel, _ k: KeyChord) -> ModalResult { k.key == "esc" ? .cancelled : k.key == "return" ? .finished : .running }
    func finish(_ m: ModelingModel) {}
    func cancel(_ m: ModelingModel) { m.voxelSize = before }
}
