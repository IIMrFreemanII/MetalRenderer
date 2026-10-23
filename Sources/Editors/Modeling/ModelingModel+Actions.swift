import AppKit
import EngineCore
import Foundation
import Modeling
import simd

/// What the keymap's actions and the menus do.
extension ModelingModel {
    func perform(_ action: ModelingAction) {
        if case .undo = action { cancelModal(); if undo.canUndo { undo.undo() }; return }
        if case .redo = action { cancelModal(); if undo.canRedo { undo.redo() }; return }
        if mode == .sculpt, let s = sculpt, s.perform(action, model: self) { return }
        switch action {
        case .undo, .redo: break
        case .save: save()
        case .toggleEditMode: setMode(mode == .edit ? .object : .edit)
        case .modeMenu: presentMenu(modeMenu(), mouse)
        case .setSelectMode(let s): setSelectMode(s)
        case .toggleToolbar: showToolbar.toggle()
        case .toggleSidebar: showSidebar.toggle()
        case .addMenu: presentMenu(addMenu(), mouse)
        case .snapMenu: presentMenu(snapMenu(), mouse)
        case .shadingMenu: presentMenu(shadingMenu(), mouse)
        case .viewMenu: presentMenu(viewMenu(), mouse)
        case .contextMenu: presentMenu(contextMenu(), mouse)
        case .toggleXray: shading.xray.toggle()
        case .toggleWireframe: shading.mode = shading.mode == .wireframe ? .solid : .wireframe
        case .view(let v): camera.align(v)
        case .toggleOrtho: camera.toggleOrthographic()
        case .orbitStep(let y, let p): camera.step(yaw: y, pitch: p)
        case .zoomStep(let f): camera.dolly(f)
        case .frameSelected: frameSelected()
        case .frameAll: if let b = documentBounds() { camera.frame(b, aspect: viewSize.x / max(viewSize.y, 1)) }
        case .cursorReset:
            var d = document
            d.cursor = .zero
            setDocument(d)
            perform(.frameAll)
        case .selectAll: selectAll(true)
        case .deselectAll: selectAll(false)
        case .invertSelection: invertSelection()
        case .boxSelect: start(BoxSelectModal(self, op: .add))
        case .circleSelect: start(CircleSelectModal(self))
        case .grab: start(TransformModal(self, kind: .translate))
        case .rotate: start(TransformModal(self, kind: .rotate))
        case .scale: start(TransformModal(self, kind: .scale))
        case .clearLocation: clearTransform("Clear Location") { $0.location = .zero }
        case .clearRotation: clearTransform("Clear Rotation") { $0.rotation = .zero }
        case .clearScale: clearTransform("Clear Scale") { $0.scale = .one }
        case .delete(let menu):
            if mode == .object {
                if menu { presentMenu(ModelingMenu(title: "Delete", items: [.init(title: "Delete", action: { [weak self] in self?.deleteObjects() })]), mouse) }
                else { deleteObjects() }
            } else if menu {
                presentMenu(deleteMenu(), mouse)
            } else {
                editMesh("Delete") { $0.delete(self.selectMode == .vertex ? .vertices : self.selectMode == .edge ? .edges : .faces) }
            }
        case .duplicate: duplicate()
        case .hide(let selected): hide(selected: selected)
        case .reveal: reveal()
        case .search: openSearch()
        case .join: join()
        case .applyMenu: presentMenu(applyMenu(), mouse)
        case .subdivisionLevel(let n): setSubdivision(levels: n)
        case .shadeSmooth: shade(smooth: true)
        case .shadeFlat: shade(smooth: false)
        case .extrude: extrudeAndMove()
        case .extrudeMenu: presentMenu(extrudeMenu(), mouse)
        case .inset: start(AmountModal(self, kind: .inset))
        case .bevel(let v): start(AmountModal(self, kind: .bevel(vertices: v)))
        case .loopCut: start(LoopCutModal(self))
        case .knife: start(KnifeModal(self))
        case .slide:
            guard mode == .edit else { break }
            if let m = EdgeSlideModal(self) { start(m) } else { report("Slide: select vertices, or edges that make loops or paths") }
        case .bridge: bridgeEdgeLoops()
        case .spin:
            guard mode == .edit else { break }
            if let m = SpinModal(self) { start(m) } else { report("Spin: select something to spin") }
        case .fill: editMesh("Make Edge/Face") { $0.fill() }
        case .connect: editMesh("Connect Vertex Path") { $0.connectVertices() }
        case .merge: presentMenu(mergeMenu(), mouse)
        case .separate: presentMenu(separateMenu(), mouse)
        case .splitFaces: editMesh("Split") { $0.splitSelection() }
        case .selectLinked(let pick):
            if pick {
                guard let element = elementUnder(mouse) else { return }
                editMesh("Select Linked") { m in
                    let v: Int
                    switch element {
                    case .vertex(let x): v = x
                    case .edge(let e): v = Int(m.edges[e].x)
                    case .face(let f): v = Int(m.cornerVerts[m.corners(f).lowerBound])
                    }
                    m.selectLinked(fromVertices: [v], mode: self.selectMode)
                    m.flushSelection(from: .vertex)
                    if self.selectMode != .vertex { m.convertSelection(from: .vertex, to: self.selectMode) }
                }
            } else {
                editMesh("Select Linked All") { $0.selectLinked(mode: self.selectMode) }
            }
        case .selectMore: editMesh("Select More") { $0.growSelection(true, mode: self.selectMode) }
        case .selectLess: editMesh("Select Less") { $0.growSelection(false, mode: self.selectMode) }
        case .edgeMenu: presentMenu(edgeMenu(), mouse)
        case .faceMenu: presentMenu(faceMenu(), mouse)
        case .vertexMenu: presentMenu(vertexMenu(), mouse)
        case .normalsMenu: presentMenu(normalsMenu(), mouse)
        case .recalcNormals: editMesh("Recalculate Outside") { $0.recalculateNormals() }
        case .uvMenu: presentMenu(uvMenu(), mouse)
        case .triangulate: editMesh("Triangulate Faces") { $0.triangulate() }
        case .trisToQuads: editMesh("Tris to Quads") { $0.trianglesToQuads() }
        case .toggleProportional: proportional.toggle()
        case .brush, .brushRadius, .brushStrength, .brushSize, .toggleDyntopo, .voxelRemesh, .voxelSize, .maskMenu, .clearMask,
             .invertMask, .faceSetsMenu, .toggleMaskEdit:
            break
        }
    }

    // MARK: Selection

    func selectAll(_ on: Bool) {
        if mode == .edit {
            editMesh(on ? "Select All" : "Deselect All") { $0.selectAll(on) }
        } else {
            edit(on ? "Select All" : "Deselect All") { d in d.selection = on ? Set(d.objects.filter(\.visible).map(\.id)) : [] }
        }
    }

    func invertSelection() {
        if mode == .edit {
            editMesh("Invert Selection") { $0.invertSelection(mode: self.selectMode) }
        } else {
            edit("Invert Selection") { d in d.selection = Set(d.objects.filter { $0.visible && !d.selection.contains($0.id) }.map(\.id)) }
        }
    }

    func frameSelected() {
        if mode == .edit, let o = activeObject {
            var b = AABB()
            let m = o.transform.matrix
            for v in o.mesh.selectedVertices {
                let q = m * SIMD4(o.mesh.positions[v], 1)
                b.grow(SIMD3(q.x, q.y, q.z))
            }
            if b.lo.x <= b.hi.x { camera.frame(b, aspect: viewSize.x / max(viewSize.y, 1)); return }
        }
        if mode == .sculpt, let b = documentBounds(selectedOnly: false) { camera.frame(b, aspect: viewSize.x / max(viewSize.y, 1)); return }
        if let b = documentBounds(selectedOnly: true) ?? documentBounds() { camera.frame(b, aspect: viewSize.x / max(viewSize.y, 1)) }
    }

    // MARK: Objects

    /// Adds a primitive at the 3D cursor: an object in object mode (selected alone, active), new geometry in the
    /// edited mesh in edit mode.
    func add(_ p: Primitive) {
        if mode == .edit, let i = activeIndex {
            let o = document.objects[i]
            var shift = matrix_identity_float4x4
            shift.columns.3 = SIMD4(document.cursor, 1)
            let local = o.transform.matrix.inverse * shift
            editMesh("Add \(p.title)") { $0.add(p.mesh().transformed(by: local)) }
            return
        }
        edit("Add \(p.title)") { d in
            var o = ModelObject(name: p.title, mesh: p.mesh())
            o.transform.location = d.cursor
            d.add(o)
        }
    }

    func deleteObjects() {
        guard mode == .object, !document.selection.isEmpty else { return }
        edit("Delete") { d in
            d.objects.removeAll { d.selection.contains($0.id) }
            d.selection = []
            d.active = d.objects.isEmpty ? nil : min(d.active ?? 0, d.objects.count - 1)
        }
    }

    func duplicate() {
        if mode == .edit {
            guard let i = activeIndex else { return }
            let before = document
            var d = document
            d.objects[i].mesh.duplicateSelection()
            setDocument(d)
            start(TransformModal(self, kind: .translate, undoName: "Duplicate", before: before))
            return
        }
        let before = document
        var d = document
        var copies: Set<UUID> = []
        for o in document.objects where document.selection.contains(o.id) {
            var c = o
            c.id = UUID()
            c.name = d.uniqueName(o.name)
            d.objects.append(c)
            copies.insert(c.id)
        }
        guard !copies.isEmpty else { return }
        d.selection = copies
        d.active = d.objects.count - 1
        setDocument(d, coarse: true)
        start(TransformModal(self, kind: .translate, undoName: "Duplicate Objects", before: before))
    }

    func hide(selected: Bool) {
        if mode == .edit {
            editMesh(selected ? "Hide" : "Hide Unselected") { $0.hide(selected: selected, mode: self.selectMode) }
            return
        }
        edit("Hide") { d in
            for k in d.objects.indices where d.selection.contains(d.objects[k].id) == selected { d.objects[k].visible = false }
            d.selection = d.selection.filter { id in d.objects.first { $0.id == id }?.visible == true }
        }
    }

    func reveal() {
        if mode == .edit { editMesh("Reveal") { $0.reveal() }; return }
        edit("Reveal") { d in
            for k in d.objects.indices where !d.objects[k].visible {
                d.objects[k].visible = true
                d.selection.insert(d.objects[k].id)
            }
        }
    }

    /// Ctrl-J: the selected objects into the active one.
    func join() {
        guard mode == .object, let a = activeIndex, document.selection.count > 1 else { return }
        edit("Join") { d in
            let target = d.objects[a]
            let inv = target.transform.matrix.inverse
            var meshes: [EditMesh] = []
            var slots = target.materials
            for o in d.objects where d.selection.contains(o.id) && o.id != target.id {
                var m = o.mesh.transformed(by: inv * o.transform.matrix)
                // Materials: the other's slots after the target's.
                let base = UInt16(slots.count)
                for f in 0..<m.faceCount { m.faceMaterial[f] += base }
                slots += o.materials
                meshes.append(m)
            }
            d.objects[a].mesh.join(meshes)
            d.objects[a].materials = slots
            let keep = target.id
            d.objects.removeAll { d.selection.contains($0.id) && $0.id != keep }
            d.active = d.objects.firstIndex { $0.id == keep }
            d.selection = [keep]
        }
    }

    func clearTransform(_ name: String, _ change: @escaping (inout ObjectTransform) -> Void) {
        guard mode == .object else { return }
        edit(name) { d in for k in d.objects.indices where d.selection.contains(d.objects[k].id) { change(&d.objects[k].transform) } }
    }

    /// Ctrl-A: location, rotation and scale put into the mesh (the object's transform back to none).
    func apply(location: Bool, rotation: Bool, scale: Bool) {
        guard mode == .object else { return }
        edit("Apply Transform") { d in
            for k in d.objects.indices where d.selection.contains(d.objects[k].id) {
                let t = d.objects[k].transform
                var keep = t
                if location { keep.location = .zero }
                if rotation { keep.rotation = .zero }
                if scale { keep.scale = .one }
                let bake = keep.matrix.inverse * t.matrix
                d.objects[k].mesh = d.objects[k].mesh.transformed(by: bake)
                d.objects[k].transform = keep
            }
        }
    }

    /// Ctrl-1…5: a Subdivision Surface modifier with that many levels (Ctrl-0: none shown).
    func setSubdivision(levels: Int) {
        guard mode == .object else { return }
        edit("Subdivision Set") { d in
            for k in d.objects.indices where d.selection.contains(d.objects[k].id) {
                if let i = d.objects[k].modifiers.firstIndex(where: { $0.kind == .subdivision }) {
                    d.objects[k].modifiers[i].levels = levels
                } else {
                    var m = Modifier(.subdivision)
                    m.levels = levels
                    d.objects[k].modifiers.append(m)
                }
            }
        }
    }

    func shade(smooth: Bool, autoAngle: Float? = nil) {
        if mode == .edit { editMesh(smooth ? "Shade Smooth" : "Shade Flat") { $0.setSmooth(smooth) }; return }
        edit(smooth ? "Shade Smooth" : "Shade Flat") { d in
            for k in d.objects.indices where d.selection.contains(d.objects[k].id) {
                if let a = autoAngle { d.objects[k].mesh.autoSmooth(angle: a) } else {
                    d.objects[k].mesh.setSmooth(smooth, onlySelected: false)
                    if smooth { for e in 0..<d.objects[k].mesh.edgeCount { d.objects[k].mesh.edgeFlags[e] &= ~EditMesh.Flag.sharp } }
                }
            }
        }
    }

    // MARK: Edit mode

    /// E: extrude, then move along the region's normal (constrained to it, as Blender's normal orientation).
    func extrudeAndMove(releaseConfirms: Bool = false, individual: Bool = false) {
        guard let i = activeIndex, mode == .edit, document.objects[i].mesh.hasSelection else { return }
        let before = document
        var d = document
        let n = d.objects[i].mesh.extrude(individual: individual)
        setDocument(d)
        let rotation = d.objects[i].transform.rotationMatrix
        if n != .zero {
            let wn = simd_normalize(rotation * n)
            let t = simd_normalize(abs(wn.y) < 0.9 ? simd_cross(wn, [0, 1, 0]) : simd_cross(wn, [1, 0, 0]))
            let frame = float3x3(t, simd_cross(wn, t), wn)
            start(TransformModal(self, kind: .translate, constraint: .axis(2, local: true), axes: frame, releaseConfirms: releaseConfirms,
                                 undoName: individual ? "Extrude Individual Faces" : "Extrude Region and Move", before: before))
        } else {
            start(TransformModal(self, kind: .translate, releaseConfirms: releaseConfirms, undoName: "Extrude and Move", before: before))
        }
    }

    /// Bridge Edge Loops, as one undo step (none if it couldn't: why is reported).
    func bridgeEdgeLoops() {
        guard mode == .edit, let i = activeIndex else { return }
        var mesh = document.objects[i].mesh
        if let problem = mesh.bridgeEdgeLoops() { report(problem); return }
        editMesh("Bridge Edge Loops") { $0 = mesh }
    }

    // MARK: Menus

    func modeMenu() -> ModelingMenu {
        ModelingMenu(title: "Mode", items: EditorMode.allCases.map { m in
            .init(title: m.title, action: { [weak self] in self?.setMode(m) })
        })
    }

    func addMenu() -> ModelingMenu {
        ModelingMenu(title: "Add", items: [
            .init(title: "Mesh", submenu: ModelingMenu(title: "Mesh", items: Primitive.allCases.map { p in
                .init(title: p.title, action: { [weak self] in self?.add(p) })
            })),
        ] + Primitive.allCases.map { p in .init(title: p.title, action: { [weak self] in self?.add(p) }) })
    }

    func snapMenu() -> ModelingMenu {
        ModelingMenu(title: "Snap", items: [
            .init(title: "Cursor to Selected", action: { [weak self] in self?.cursorToSelected() }),
            .init(title: "Cursor to World Origin", action: { [weak self] in
                guard let self else { return }
                var d = self.document
                d.cursor = .zero
                self.setDocument(d)
            }),
            .init(title: "Selection to Cursor", action: { [weak self] in self?.selectionToCursor() }),
            .init(title: "Cursor to Active", action: { [weak self] in
                guard let self, let a = self.activeObject else { return }
                var d = self.document
                d.cursor = a.transform.location
                self.setDocument(d)
            }),
        ])
    }

    func cursorToSelected() {
        var d = document
        if mode == .edit, let o = activeObject, let c = o.mesh.selectionCentre() {
            let w = o.transform.matrix * SIMD4(c, 1)
            d.cursor = SIMD3(w.x, w.y, w.z)
        } else {
            let sel = document.objects.filter { document.selection.contains($0.id) }
            guard !sel.isEmpty else { return }
            d.cursor = sel.reduce(SIMD3<Float>.zero) { $0 + $1.transform.location } / Float(sel.count)
        }
        setDocument(d)
    }

    func selectionToCursor() {
        if mode == .edit, let i = activeIndex {
            let o = document.objects[i]
            let local = o.transform.matrix.inverse * SIMD4(document.cursor, 1)
            guard let c = o.mesh.selectionCentre() else { return }
            let shift = SIMD3(local.x, local.y, local.z) - c
            editMesh("Selection to Cursor") { m in for v in m.selectedVertices { m.positions[v] += shift }; m.touch() }
        } else {
            let c = document.cursor
            edit("Selection to Cursor") { d in for k in d.objects.indices where d.selection.contains(d.objects[k].id) { d.objects[k].transform.location = c } }
        }
    }

    func shadingMenu() -> ModelingMenu {
        ModelingMenu(title: "Shading", items: ViewportShading.Mode.allCases.map { s in
            .init(title: s.rawValue.capitalized, action: { [weak self] in self?.shading.mode = s })
        } + [.separator, .init(title: "Toggle X-Ray", shortcut: "Alt Z", action: { [weak self] in self?.shading.xray.toggle() })])
    }

    func viewMenu() -> ModelingMenu {
        ModelingMenu(title: "View", items: [
            .init(title: "Front", shortcut: "Numpad 1", action: { [weak self] in self?.camera.align(.front) }),
            .init(title: "Back", shortcut: "Ctrl Numpad 1", action: { [weak self] in self?.camera.align(.back) }),
            .init(title: "Right", shortcut: "Numpad 3", action: { [weak self] in self?.camera.align(.right) }),
            .init(title: "Left", shortcut: "Ctrl Numpad 3", action: { [weak self] in self?.camera.align(.left) }),
            .init(title: "Top", shortcut: "Numpad 7", action: { [weak self] in self?.camera.align(.top) }),
            .init(title: "Bottom", shortcut: "Ctrl Numpad 7", action: { [weak self] in self?.camera.align(.bottom) }),
            .separator,
            .init(title: "Perspective/Orthographic", shortcut: "Numpad 5", action: { [weak self] in self?.camera.toggleOrthographic() }),
            .init(title: "Frame Selected", shortcut: "Numpad .", action: { [weak self] in self?.frameSelected() }),
            .init(title: "Frame All", shortcut: "Home", action: { [weak self] in self?.perform(.frameAll) }),
        ])
    }

    func applyMenu() -> ModelingMenu {
        ModelingMenu(title: "Apply", items: [
            .init(title: "Location", action: { [weak self] in self?.apply(location: true, rotation: false, scale: false) }),
            .init(title: "Rotation", action: { [weak self] in self?.apply(location: false, rotation: true, scale: false) }),
            .init(title: "Scale", action: { [weak self] in self?.apply(location: false, rotation: false, scale: true) }),
            .init(title: "All Transforms", action: { [weak self] in self?.apply(location: true, rotation: true, scale: true) }),
            .init(title: "Rotation & Scale", action: { [weak self] in self?.apply(location: false, rotation: true, scale: true) }),
            .separator,
            .init(title: "Visual Geometry to Mesh", action: { [weak self] in self?.applyModifiers() }),
        ])
    }

    func deleteMenu() -> ModelingMenu {
        ModelingMenu(title: "Delete", items: DeleteKind.allCases.map { k in
            .init(title: k.title, action: { [weak self] in self?.editMesh("Delete") { $0.delete(k) } })
        } + [
            .separator,
            .init(title: "Dissolve Vertices", action: { [weak self] in self?.editMesh("Dissolve Vertices") { $0.dissolve(.vertex) } }),
            .init(title: "Dissolve Edges", action: { [weak self] in self?.editMesh("Dissolve Edges") { $0.dissolve(.edge) } }),
            .init(title: "Dissolve Faces", action: { [weak self] in self?.editMesh("Dissolve Faces") { $0.dissolve(.face) } }),
        ])
    }

    func mergeMenu() -> ModelingMenu {
        ModelingMenu(title: "Merge", items: MergeKind.allCases.map { k in
            .init(title: k.title, action: { [weak self] in
                guard let self else { return }
                var removed = 0
                let cursor = self.activeObject.map { o -> SIMD3<Float> in
                    let l = o.transform.matrix.inverse * SIMD4(self.document.cursor, 1)
                    return SIMD3(l.x, l.y, l.z)
                } ?? .zero
                self.editMesh("Merge") { removed = $0.merge(k, cursor: cursor) }
                self.report("Removed \(removed) vertice(s)")
            })
        })
    }

    func separateMenu() -> ModelingMenu {
        ModelingMenu(title: "Separate", items: [
            .init(title: "Selection", action: { [weak self] in self?.separate(byLooseParts: false) }),
            .init(title: "By Loose Parts", action: { [weak self] in self?.separate(byLooseParts: true) }),
        ])
    }

    /// P: the selection (or each loose part) as objects of their own.
    func separate(byLooseParts: Bool) {
        guard mode == .edit, let i = activeIndex else { return }
        edit("Separate") { d in
            let source = d.objects[i]
            if byLooseParts {
                var rest = source.mesh
                var parts: [EditMesh] = []
                while rest.vertexCount > 0 {
                    rest.selectAll(false)
                    rest.selectLinked(fromVertices: [0], mode: .vertex)
                    guard let part = rest.separateSelection() else { break }
                    parts.append(part)
                    if parts.count > 4096 { break }
                }
                guard parts.count > 1 else { return }
                d.objects[i].mesh = parts[0]
                for p in parts.dropFirst() {
                    var o = source
                    o.id = UUID()
                    o.name = d.uniqueName(source.name)
                    o.mesh = p
                    o.modifiers = source.modifiers
                    d.objects.append(o)
                }
            } else {
                guard let part = d.objects[i].mesh.separateSelection() else { return }
                var o = source
                o.id = UUID()
                o.name = d.uniqueName(source.name)
                o.mesh = part
                d.objects.append(o)
            }
        }
    }

    func extrudeMenu() -> ModelingMenu {
        ModelingMenu(title: "Extrude", items: [
            .init(title: "Extrude Region", action: { [weak self] in self?.extrudeAndMove() }),
            .init(title: "Extrude Individual Faces", action: { [weak self] in self?.extrudeAndMove(individual: true) }),
            .init(title: "Spin", action: { [weak self] in self?.perform(.spin) }),
        ])
    }

    func edgeMenu() -> ModelingMenu {
        ModelingMenu(title: "Edge", items: [
            .init(title: "Subdivide", action: { [weak self] in self?.editMesh("Subdivide") { $0.subdivide() } }),
            .init(title: "Bevel Edges", shortcut: "Ctrl B", action: { [weak self] in self?.perform(.bevel(vertices: false)) }),
            .init(title: "Loop Cut and Slide", shortcut: "Ctrl R", action: { [weak self] in self?.perform(.loopCut) }),
            .init(title: "Edge Slide", shortcut: "G G", action: { [weak self] in self?.perform(.slide) }),
            .init(title: "Bridge Edge Loops", action: { [weak self] in self?.perform(.bridge) }),
            .init(title: "Spin", action: { [weak self] in self?.perform(.spin) }),
            .separator,
            .init(title: "Mark Seam", action: { [weak self] in self?.editMesh("Mark Seam") { $0.markEdges(EditMesh.Flag.seam, true) } }),
            .init(title: "Clear Seam", action: { [weak self] in self?.editMesh("Clear Seam") { $0.markEdges(EditMesh.Flag.seam, false) } }),
            .init(title: "Mark Sharp", action: { [weak self] in self?.editMesh("Mark Sharp") { $0.markEdges(EditMesh.Flag.sharp, true) } }),
            .init(title: "Clear Sharp", action: { [weak self] in self?.editMesh("Clear Sharp") { $0.markEdges(EditMesh.Flag.sharp, false) } }),
            .init(title: "Edge Crease 1", action: { [weak self] in self?.editMesh("Edge Crease") { $0.setCrease(1) } }),
            .init(title: "Clear Crease", action: { [weak self] in self?.editMesh("Edge Crease") { $0.setCrease(0) } }),
        ])
    }

    func faceMenu() -> ModelingMenu {
        ModelingMenu(title: "Face", items: [
            .init(title: "Extrude Individual Faces", action: { [weak self] in self?.extrudeAndMove(individual: true) }),
            .init(title: "Inset Faces", shortcut: "I", action: { [weak self] in self?.perform(.inset) }),
            .init(title: "Subdivide", action: { [weak self] in self?.editMesh("Subdivide") { $0.subdivide() } }),
            .init(title: "Fill", shortcut: "F", action: { [weak self] in self?.perform(.fill) }),
            .separator,
            .init(title: "Triangulate Faces", shortcut: "Ctrl T", action: { [weak self] in self?.perform(.triangulate) }),
            .init(title: "Tris to Quads", shortcut: "Alt J", action: { [weak self] in self?.perform(.trisToQuads) }),
            .separator,
            .init(title: "Shade Smooth", action: { [weak self] in self?.shade(smooth: true) }),
            .init(title: "Shade Flat", action: { [weak self] in self?.shade(smooth: false) }),
        ])
    }

    func vertexMenu() -> ModelingMenu {
        ModelingMenu(title: "Vertex", items: [
            .init(title: "Merge", shortcut: "M", action: { [weak self] in self?.perform(.merge) }),
            .init(title: "Connect Vertex Path", shortcut: "J", action: { [weak self] in self?.perform(.connect) }),
            .init(title: "Slide Vertices", shortcut: "Shift V", action: { [weak self] in self?.perform(.slide) }),
            .init(title: "Bevel Vertices", shortcut: "Ctrl Shift B", action: { [weak self] in self?.perform(.bevel(vertices: true)) }),
            .init(title: "Smooth Vertices", action: { [weak self] in self?.editMesh("Smooth Vertices") { $0.smoothVertices() } }),
            .init(title: "Separate", shortcut: "P", action: { [weak self] in self?.perform(.separate) }),
        ])
    }

    func normalsMenu() -> ModelingMenu {
        ModelingMenu(title: "Normals", items: [
            .init(title: "Flip", action: { [weak self] in self?.editMesh("Flip Normals") { $0.flipNormals() } }),
            .init(title: "Recalculate Outside", shortcut: "Shift N", action: { [weak self] in self?.perform(.recalcNormals) }),
            .init(title: "Recalculate Inside", action: { [weak self] in self?.editMesh("Recalculate Inside") { $0.recalculateNormals(inside: true) } }),
        ])
    }

    func uvMenu() -> ModelingMenu {
        ModelingMenu(title: "UV", items: [
            .init(title: "Unwrap", action: { [weak self] in self?.unwrap(smart: false) }),
            .init(title: "Smart UV Project", action: { [weak self] in self?.unwrap(smart: true) }),
            .separator,
            .init(title: "Mark Seam", action: { [weak self] in self?.editMesh("Mark Seam") { $0.markEdges(EditMesh.Flag.seam, true) } }),
            .init(title: "Clear Seam", action: { [weak self] in self?.editMesh("Clear Seam") { $0.markEdges(EditMesh.Flag.seam, false) } }),
        ])
    }

    /// The right-click menu: the mode's (and the select mode's) common operations.
    func contextMenu() -> ModelingMenu {
        switch mode {
        case .object:
            return ModelingMenu(title: "Object", items: [
                .init(title: "Shade Smooth", action: { [weak self] in self?.shade(smooth: true) }),
                .init(title: "Shade Auto Smooth", action: { [weak self] in self?.shade(smooth: true, autoAngle: 30 * .pi / 180) }),
                .init(title: "Shade Flat", action: { [weak self] in self?.shade(smooth: false) }),
                .separator,
                .init(title: "Duplicate Objects", shortcut: "Shift D", action: { [weak self] in self?.duplicate() }),
                .init(title: "Join", shortcut: "Ctrl J", action: { [weak self] in self?.join() }),
                .init(title: "Apply", shortcut: "Ctrl A", submenu: applyMenu()),
                .separator,
                .init(title: "Delete", shortcut: "X", action: { [weak self] in self?.deleteObjects() }),
            ])
        case .edit:
            var items: [ModelingMenu.Item] = []
            switch selectMode {
            case .vertex: items = vertexMenu().items
            case .edge: items = edgeMenu().items
            case .face: items = faceMenu().items
            }
            items += [.separator, .init(title: "Delete", shortcut: "X", submenu: deleteMenu())]
            return ModelingMenu(title: selectMode == .vertex ? "Vertex" : selectMode == .edge ? "Edge" : "Face", items: items)
        case .sculpt:
            return sculpt?.menu(model: self) ?? ModelingMenu(title: "Sculpt", items: [])
        }
    }
}
