import AppKit
import EngineCore
import Foundation
import Modeling
import simd

/// The viewport's input: keys through the keymap, the mouse to the running operator, the tool, navigation or
/// selection, as Blender's left-click-select keymap does.
extension ModelingModel {
    enum Button: Int { case left = 0, right = 1, middle = 2 }

    /// What a press began, to finish when it ends.
    enum Gesture {
        case none
        case navigate(orbit: Bool, pan: Bool, zoom: Bool, last: SIMD2<Float>)
        case pending(start: SIMD2<Float>, flags: NSEvent.ModifierFlags, clickCount: Int)   // a click, unless it moves
        case sculpting
    }

    // MARK: Keys

    /// A key: the running operator's first, then the keymap. False if nothing used it.
    @discardableResult
    func keyDown(_ k: KeyChord) -> Bool {
        if let m = modal {
            handle(m.key(self, k), of: m)
            return true
        }
        if mode == .sculpt, let s = sculpt, s.key(k, model: self) { return true }
        guard let action = ModelingKeymap.action(for: k, mode: mode) else { return false }
        perform(action)
        return true
    }

    func handle(_ result: ModalResult, of m: ModalOperator) {
        switch result {
        case .running: refreshStatus(); redraw()
        case .finished:
            modal = nil
            m.finish(self)
        case .cancelled:
            modal = nil
            m.cancel(self)
        case .pass: break
        }
        redraw()
    }

    func start(_ m: ModalOperator?) {
        guard let m else { return }
        cancelModal()
        modal = m
        _ = m.mouseMoved(self, to: mouse, flags: [])
        refreshStatus()
        redraw()
    }

    /// The running operator gives way to another without finishing or cancelling (G G: grab to edge slide).
    func replaceModal(with m: ModalOperator) {
        modal = m
        _ = m.mouseMoved(self, to: mouse, flags: [])
        refreshStatus()
        redraw()
    }

    func cancelModal() {
        guard let m = modal else { return }
        modal = nil
        m.cancel(self)
    }

    // MARK: Mouse

    func mouseDown(_ button: Button, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags, clickCount: Int = 1, pressure: Float = 1) {
        mouse = p
        let emulatedMiddle = emulateMiddleButton && button == .left && flags.contains(.option)
        if button == .middle || emulatedMiddle {
            if let m = modal, m.mouseDown(self, button: 2, at: p, flags: flags) != .pass { handle(.running, of: m); return }
            gesture = .navigate(orbit: !flags.contains(.shift) && !flags.contains(.control), pan: flags.contains(.shift),
                                zoom: flags.contains(.control), last: p)
            return
        }
        if let m = modal {
            let r = m.mouseDown(self, button: button.rawValue, at: p, flags: flags)
            if r != .pass { handle(r, of: m) }
            return
        }
        if button == .right {
            // Shift-right-click: the 3D cursor; right-click: the context menu.
            if flags.contains(.shift) { placeCursor(at: p) } else { presentMenu(contextMenu(), p) }
            return
        }
        // Left.
        if mode == .sculpt {
            if sculpt?.beginStroke(at: p, flags: flags, pressure: pressure, model: self) == true { gesture = .sculpting }
            return
        }
        if let handle = gizmoHandle(at: p) {
            beginGizmoDrag(handle)
            return
        }
        switch tool {
        case .cursor:
            placeCursor(at: p)
        case .loopCut where mode == .edit:
            start(LoopCutModal(self))
            if let m = modal { handle(m.mouseDown(self, button: 0, at: p, flags: flags), of: m) }
        case .knife where mode == .edit:
            start(KnifeModal(self))
            if let m = modal { handle(m.mouseDown(self, button: 0, at: p, flags: flags), of: m) }
        default:
            gesture = .pending(start: p, flags: flags, clickCount: clickCount)
        }
    }

    func mouseDragged(to p: SIMD2<Float>, flags: NSEvent.ModifierFlags, pressure: Float = 1) {
        let last = mouse
        mouse = p
        switch gesture {
        case .navigate(let orbit, let pan, let zoom, let previous):
            let d = p - previous
            if orbit { camera.orbit(dx: d.x, dy: d.y) }
            if pan { camera.pan(dx: d.x, dy: d.y, viewHeight: viewSize.y) }
            if zoom { camera.dolly(pow(1.005, d.y)) }
            gesture = .navigate(orbit: orbit, pan: pan, zoom: zoom, last: p)
            return
        case .sculpting:
            sculpt?.continueStroke(to: p, flags: flags, pressure: pressure, model: self)
            return
        case .pending(let start, let f, _) where simd_distance(start, p) > 3:
            gesture = .none
            beginToolDrag(from: start, flags: f)
        default: break
        }
        if let m = modal {
            handle(m.mouseMoved(self, to: p, flags: flags), of: m)
        }
        _ = last
    }

    func mouseMoved(to p: SIMD2<Float>, flags: NSEvent.ModifierFlags) {
        mouse = p
        if let m = modal {
            handle(m.mouseMoved(self, to: p, flags: flags), of: m)
        } else if mode == .sculpt {
            sculpt?.hover(p, model: self)
            redraw()
        } else if [.move, .rotate, .scale].contains(tool) {
            updateHover(p)
        }
    }

    func mouseUp(_ button: Button, at p: SIMD2<Float>, flags: NSEvent.ModifierFlags) {
        mouse = p
        switch gesture {
        case .navigate:
            gesture = .none
            return
        case .sculpting:
            gesture = .none
            sculpt?.endStroke(model: self)
            return
        case .pending(_, let f, let clicks):
            gesture = .none
            click(at: p, flags: f, clickCount: clicks)
            return
        default: break
        }
        if let m = modal { handle(m.mouseUp(self, button: button.rawValue, at: p), of: m) }
    }

    /// A scroll: the wheel zooms; a trackpad's two fingers orbit (Shift pans, Ctrl zooms), as Blender's trackpad
    /// navigation. The running operator gets the wheel's steps first.
    func scroll(dx: Float, dy: Float, precise: Bool, flags: NSEvent.ModifierFlags) {
        if let m = modal {
            let steps = precise ? 0 : (dy > 0 ? 1 : dy < 0 ? -1 : 0)
            if steps != 0, m.scroll(self, steps: steps) != .pass { handle(.running, of: m); return }
        }
        if mode == .sculpt, flags.contains(.option) == false, let s = sculpt, s.scroll(dy: dy, precise: precise, model: self) { return }
        if precise {
            if flags.contains(.control) { camera.dolly(pow(1.01, -dy)) }
            else if flags.contains(.shift) { camera.pan(dx: -dx, dy: -dy, viewHeight: viewSize.y) }
            else { camera.orbit(dx: -dx * 0.8, dy: -dy * 0.8) }
        } else {
            camera.dolly(dy > 0 ? 1 / 1.15 : 1.15)
        }
    }

    /// A pinch: zoom.
    func magnify(_ amount: Float) {
        camera.dolly(max(0.2, 1 - amount))
    }

    // MARK: Clicks

    /// A left click that didn't move: select what is under it, as Blender's click select (Shift toggles, Alt loops,
    /// Ctrl-Alt rings; nothing under it deselects all).
    func click(at p: SIMD2<Float>, flags: NSEvent.ModifierFlags, clickCount: Int) {
        let extend = flags.contains(.shift)
        let loop = flags.contains(.option) && !emulateMiddleButton || (emulateMiddleButton && clickCount == 2)
        switch mode {
        case .object:
            let hit = pick(at: p, radius: 3, edit: false).first { $0.id != 0 && $0.id < 0x0FFF_FFFE }
            let index = hit.map { Int($0.id) - 1 }
            let before = document
            var d = document
            if let i = index, i < d.objects.count {
                let id = d.objects[i].id
                if extend {
                    if d.selection.contains(id) && d.active == i { d.selection.remove(id) } else { d.selection.insert(id); d.active = i }
                } else {
                    d.selection = [id]
                    d.active = i
                }
            } else if !extend {
                d.selection = []
            }
            guard d.selection != before.selection || d.active != before.active else { return }
            setDocument(d, coarse: true)
            registerUndo("Select", before: before)
            documentChanged()
        case .edit:
            guard let i = activeIndex else { return }
            if loop {
                guard let e = edgeUnder(p) else { return }
                let ring = flags.contains(.control)
                editMesh(ring ? "Select Ring" : "Select Loop") { mesh in
                    if self.selectMode == .face {
                        // A face loop: the faces of the edge ring.
                        let faces = mesh.edgeRing(from: e).faces
                        if !extend { mesh.selectAll(false) }
                        for f in faces { mesh.setSelected(face: f, true) }
                        mesh.flushSelection(from: .face)
                    } else {
                        mesh.selectLoop(e, ring: ring, extend: extend)
                    }
                }
                activeElement = (nil, e, nil)
                return
            }
            guard let element = elementUnder(p) else {
                if !extend {
                    editMesh("Deselect All") { $0.selectAll(false) }
                    activeElement = (nil, nil, nil)
                }
                return
            }
            let mesh = document.objects[i].mesh
            editMesh("Select") { m in
                switch element {
                case .vertex(let v):
                    let on = !(extend && m.isSelected(vertex: v) && self.activeElement.vertex == v)
                    if !extend { m.selectAll(false) }
                    m.setSelected(vertex: v, on)
                    m.flushSelection(from: .vertex)
                case .edge(let e):
                    let on = !(extend && m.isSelected(edge: e) && self.activeElement.edge == e)
                    if !extend { m.selectAll(false) }
                    m.setSelected(edge: e, on)
                    m.flushSelection(from: .edge)
                case .face(let f):
                    let on = !(extend && m.isSelected(face: f) && self.activeElement.face == f)
                    if !extend { m.selectAll(false) }
                    m.setSelected(face: f, on)
                    m.flushSelection(from: .face)
                }
            }
            _ = mesh
            switch element {
            case .vertex(let v): activeElement = (v, nil, nil)
            case .edge(let e): activeElement = (nil, e, nil)
            case .face(let f): activeElement = (nil, nil, f)
            }
            redraw()
        case .sculpt:
            break
        }
    }

    enum Element: Equatable { case vertex(Int), edge(Int), face(Int) }

    /// The ids under a point of the viewport (points), nearest first.
    func pick(at p: SIMD2<Float>, radius: Float, edit: Bool) -> [(id: UInt32, distance: Float)] {
        guard let renderer else { return [] }
        let px = SIMD2<Int>(Int(p.x * pixelScale), Int(p.y * pixelScale))
        return renderer.pick(frame(), at: px, radius: Int(radius * pixelScale), edit: edit)
    }

    /// The edited mesh's element of the select mode nearest a point (vertices and edges within a few points; a face
    /// under it or its dot).
    func elementUnder(_ p: SIMD2<Float>) -> Element? {
        let hits = pick(at: p, radius: 12, edit: true)
        func first(_ kind: UInt32) -> Int? { hits.first { $0.id >> 28 == kind }.map { Int($0.id & 0x0FFF_FFFF) - 1 } }
        switch selectMode {
        case .vertex: return first(3).map { .vertex($0) }
        case .edge: return first(2).map { .edge($0) }
        case .face:
            if let f = hits.first(where: { $0.id >> 28 == 1 && $0.distance < 1.5 }) { return .face(Int(f.id & 0x0FFF_FFFF) - 1) }
            return first(4).map { .face($0) }
        }
    }

    /// The edge of the face under a point nearest it on screen (loop select, loop cut).
    func edgeUnder(_ p: SIMD2<Float>) -> Int? {
        guard let i = activeIndex else { return nil }
        let hits = pick(at: p, radius: 6, edit: true)
        let mesh = document.objects[i].mesh
        // Edges drawn in the pass (vertex and edge modes): the nearest.
        if let e = hits.first(where: { $0.id >> 28 == 2 }) { return Int(e.id & 0x0FFF_FFFF) - 1 }
        guard let f = hits.first(where: { $0.id >> 28 == 1 }).map({ Int($0.id & 0x0FFF_FFFF) - 1 }), f < mesh.faceCount else { return nil }
        let om = document.objects[i].transform.matrix
        var best: (Int, Float)?
        for c in mesh.corners(f) {
            let e = Int(mesh.cornerEdges[c])
            let a = om * SIMD4(mesh.positions[Int(mesh.edges[e].x)], 1), b = om * SIMD4(mesh.positions[Int(mesh.edges[e].y)], 1)
            guard let pa = camera.project(SIMD3(a.x, a.y, a.z), size: viewSize), let pb = camera.project(SIMD3(b.x, b.y, b.z), size: viewSize) else { continue }
            let d = distanceToSegment(p, SIMD2(pa.x, pa.y), SIMD2(pb.x, pb.y))
            if best == nil || d < best!.1 { best = (e, d) }
        }
        return best?.0
    }

    private func distanceToSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9)))
        return simd_distance(p, a + ab * t)
    }

    // MARK: Box and circle select

    func select(inside r: CGRect, op: BoxSelectModal.Op) {
        guard let renderer else { return }
        let ids = renderer.pickRegion(frame(), x: Int(Float(r.minX) * pixelScale), y: Int(Float(r.minY) * pixelScale),
                                      width: Int(Float(r.width) * pixelScale), height: Int(Float(r.height) * pixelScale), edit: mode == .edit)
        apply(ids: ids, op: op, xrayRect: shading.xray ? r : nil)
    }

    func select(inCircle c: SIMD2<Float>, radius: Float, on: Bool) {
        guard let renderer else { return }
        let r = radius * pixelScale
        let ids = renderer.pickRegion(frame(), x: Int(c.x * pixelScale - r), y: Int(c.y * pixelScale - r), width: Int(2 * r), height: Int(2 * r),
                                      edit: mode == .edit)
        let doc = document
        apply(ids: ids, op: on ? .add : .subtract, xrayRect: nil, circle: (c, radius))
        if mode == .object { _ = doc }
    }

    /// Selects the elements (or objects) with these ids: set, added or taken away. In x-ray, every vertex inside the
    /// rectangle counts, hidden or not.
    private func apply(ids: Set<UInt32>, op: BoxSelectModal.Op, xrayRect: CGRect?, circle: (SIMD2<Float>, Float)? = nil) {
        if mode == .object {
            var d = document
            let picked = ids.filter { $0 > 0 && $0 < 0x0FFF_FFFE }.map { Int($0) - 1 }.filter { $0 < d.objects.count }
            if op == .set { d.selection = [] }
            for i in picked {
                if op == .subtract { d.selection.remove(d.objects[i].id) } else { d.selection.insert(d.objects[i].id) }
            }
            if let a = d.active, !d.selection.contains(d.objects[a].id), let first = picked.first, op != .subtract { d.active = first }
            let before = document
            setDocument(d, coarse: true)
            if circle == nil { registerUndo("Box Select", before: before) }
            documentChanged()
            return
        }
        guard let i = activeIndex else { return }
        let kind: UInt32 = selectMode == .vertex ? 3 : selectMode == .edge ? 2 : 4
        var picked = Set(ids.filter { $0 >> 28 == kind }.map { Int($0 & 0x0FFF_FFFF) - 1 })
        // X-ray: by projection, not by what drew.
        if let r = xrayRect, selectMode == .vertex {
            let mesh = document.objects[i].mesh, om = document.objects[i].transform.matrix
            for v in 0..<mesh.vertexCount where !mesh.isHidden(vertex: v) {
                let w = om * SIMD4(mesh.positions[v], 1)
                if let s = camera.project(SIMD3(w.x, w.y, w.z), size: viewSize), r.contains(CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))) { picked.insert(v) }
            }
        }
        let before = document
        var d = document
        var mesh = d.objects[i].mesh
        if op == .set { mesh.selectAll(false) }
        for k in picked {
            switch selectMode {
            case .vertex: mesh.setSelected(vertex: k, op != .subtract)
            case .edge: mesh.setSelected(edge: k, op != .subtract)
            case .face: mesh.setSelected(face: k, op != .subtract)
            }
        }
        mesh.flushSelection(from: selectMode)
        d.objects[i].mesh = mesh
        setDocument(d)
        if circle == nil { registerUndo("Box Select", before: before) }
        documentChanged()
    }

    // MARK: Tools

    /// A left drag that began away from anything the tool grabs: the tool's operation (select: a box).
    private func beginToolDrag(from p: SIMD2<Float>, flags: NSEvent.ModifierFlags) {
        let op: BoxSelectModal.Op = flags.contains(.shift) ? .add : flags.contains(.control) ? .subtract : .set
        mouse = p
        switch tool {
        case .move where hasSelection: start(TransformModal(self, kind: .translate, releaseConfirms: true))
        case .rotate where hasSelection: start(TransformModal(self, kind: .rotate, releaseConfirms: true))
        case .scale where hasSelection: start(TransformModal(self, kind: .scale, releaseConfirms: true))
        case .extrude where mode == .edit: extrudeAndMove(releaseConfirms: true)
        case .inset where mode == .edit: start(AmountModal(self, kind: .inset, releaseConfirms: true))
        case .bevel where mode == .edit: start(AmountModal(self, kind: .bevel(vertices: false), releaseConfirms: true))
        default:
            let box = BoxSelectModal(self, startingAt: p, op: op)
            start(box)
        }
    }

    var hasSelection: Bool {
        mode == .edit ? (activeObject?.mesh.hasSelection ?? false) : !document.selection.isEmpty
    }

    // MARK: The 3D cursor

    /// The cursor where a point's ray meets a surface, or on the view plane through the old cursor.
    func placeCursor(at p: SIMD2<Float>) {
        let ray = camera.ray(at: p, size: viewSize)
        var best: Float = .infinity
        for o in document.objects where o.visible {
            let m = o.transform.matrix, inv = m.inverse
            let lo = inv * SIMD4(ray.origin, 1), ld = inv * SIMD4(ray.direction, 0)
            let origin = SIMD3(lo.x, lo.y, lo.z), dir = SIMD3(ld.x, ld.y, ld.z)
            let (tri, _) = o.mesh.triangles()
            for t in 0..<(tri.count / 3) {
                let a = o.mesh.positions[Int(o.mesh.cornerVerts[Int(tri[3 * t])])]
                let b = o.mesh.positions[Int(o.mesh.cornerVerts[Int(tri[3 * t + 1])])]
                let c = o.mesh.positions[Int(o.mesh.cornerVerts[Int(tri[3 * t + 2])])]
                if let h = rayTriangle(origin, dir, a, b, c), h < best { best = h }
            }
        }
        var d = document
        if best.isFinite {
            d.cursor = ray.origin + ray.direction * best
        } else {
            let depth = simd_dot(document.cursor - ray.origin, camera.forward) / max(simd_dot(ray.direction, camera.forward), 1e-6)
            d.cursor = ray.origin + ray.direction * depth
        }
        setDocument(d)
    }

    /// Möller–Trumbore: the ray's distance to a triangle (in units of `dir`), nil if it misses.
    func rayTriangle(_ o: SIMD3<Float>, _ dir: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(dir, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        let s = o - a
        let u = simd_dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(dir, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 1e-6 ? t : nil
    }
}
