import AppKit
import EngineCore
import Foundation
import Modeling
import simd

/// What the panels change: objects' names, transforms and visibility, modifiers, material slots, the 3D cursor. A
/// field dragged makes one undo step (edits of the same thing within a moment of each other are one).
extension ModelingModel {
    /// One undo step for a run of edits of the same thing (a field being dragged).
    func editCoalesced(_ name: String, key: String, _ change: (inout ModelingDocument) -> Void) {
        let now = Date()
        if key == coalesceKey, now.timeIntervalSince(coalesceTime) < 1.0 {
            var d = document
            change(&d)
            setDocument(d, coarse: true)
            dirty(true)
        } else {
            edit(name, change)
        }
        coalesceKey = key
        coalesceTime = now
    }

    func dirty(_ on: Bool) { if on { documentChanged(dirty: true) } }

    // MARK: Objects

    func selectObject(_ id: UUID, extend: Bool) {
        guard mode == .object || !extend else { return }
        guard let i = document.index(of: id) else { return }
        if mode != .object && i != activeIndex { setMode(.object) }
        edit("Select") { d in
            if extend {
                if d.selection.contains(id) && d.active == i { d.selection.remove(id) } else { d.selection.insert(id); d.active = i }
            } else {
                d.selection = [id]
                d.active = i
            }
        }
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = document.index(of: id), !name.isEmpty, name != document.objects[i].name else { return }
        edit("Rename") { d in d.objects[i].name = d.uniqueName(name) }
    }

    func setVisible(_ id: UUID, _ on: Bool) {
        guard let i = document.index(of: id) else { return }
        edit(on ? "Show" : "Hide") { d in
            d.objects[i].visible = on
            if !on { d.selection.remove(id) }
        }
    }

    func setRenders(_ id: UUID, _ on: Bool) {
        guard let i = document.index(of: id) else { return }
        edit("Render Visibility") { d in d.objects[i].renders = on }
    }

    /// The active object's transform in Blender's terms (Z up), as the panels show it.
    var blenderTransform: (location: SIMD3<Float>, rotation: SIMD3<Float>, scale: SIMD3<Float>, dimensions: SIMD3<Float>)? {
        guard let o = activeObject else { return nil }
        let t = o.transform
        let b = o.mesh.bounds
        let size = b.lo.x <= b.hi.x ? (b.hi - b.lo) * t.scale : .zero
        return (BlenderAxes.toBlender(t.location), BlenderAxes.eulerInBlender(t.rotationMatrix) * 180 / .pi,
                BlenderAxes.scaleToBlender(t.scale), BlenderAxes.scaleToBlender(size))
    }

    func setBlenderLocation(_ v: SIMD3<Float>) {
        guard let i = activeIndex else { return }
        editCoalesced("Location", key: "loc\(i)") { d in d.objects[i].transform.location = BlenderAxes.fromBlender(v) }
    }

    func setBlenderRotation(_ degrees: SIMD3<Float>) {
        guard let i = activeIndex else { return }
        editCoalesced("Rotation", key: "rot\(i)") { d in
            let r = BlenderAxes.rotation(fromBlenderEuler: degrees * .pi / 180)
            d.objects[i].transform.rotation = ObjectTransform.euler(r)
        }
    }

    func setBlenderScale(_ v: SIMD3<Float>) {
        guard let i = activeIndex else { return }
        editCoalesced("Scale", key: "scale\(i)") { d in d.objects[i].transform.scale = BlenderAxes.scaleFromBlender(v) }
    }

    /// The median of the selected vertices (edit mode's Item panel), in Blender's terms, global.
    var selectionMedian: SIMD3<Float>? {
        guard mode == .edit, let o = activeObject, let c = o.mesh.selectionCentre() else { return nil }
        let w = o.transform.matrix * SIMD4(c, 1)
        return BlenderAxes.toBlender(SIMD3(w.x, w.y, w.z))
    }

    func setSelectionMedian(_ v: SIMD3<Float>) {
        guard let i = activeIndex, let current = selectionMedian else { return }
        let o = document.objects[i]
        let deltaWorld = BlenderAxes.fromBlender(v - current)
        let d4 = o.transform.matrix.inverse * SIMD4(deltaWorld, 0)
        let delta = SIMD3(d4.x, d4.y, d4.z)
        editCoalesced("Move Median", key: "median\(i)") { d in
            for v in d.objects[i].mesh.selectedVertices { d.objects[i].mesh.positions[v] += delta }
            d.objects[i].mesh.touch()
        }
    }

    func setCursor(_ blender: SIMD3<Float>) {
        var d = document
        d.cursor = BlenderAxes.fromBlender(blender)
        setDocument(d, coarse: true)
    }

    // MARK: Modifiers

    func addModifier(_ kind: Modifier.Kind) {
        guard let i = activeIndex else { return }
        edit("Add Modifier") { d in
            var m = Modifier(kind)
            m.name = kind.title
            if kind == .boolean { m.operand = d.objects.first { $0.id != d.objects[i].id }?.id }
            d.objects[i].modifiers.append(m)
        }
        propertiesTab = .modifiers
    }

    func updateModifier(_ id: UUID, _ change: @escaping (inout Modifier) -> Void) {
        guard let i = activeIndex, let k = document.objects[i].modifiers.firstIndex(where: { $0.id == id }) else { return }
        editCoalesced("Modifier", key: "mod\(id)") { d in change(&d.objects[i].modifiers[k]) }
    }

    func removeModifier(_ id: UUID) {
        guard let i = activeIndex else { return }
        edit("Remove Modifier") { d in d.objects[i].modifiers.removeAll { $0.id == id } }
    }

    func moveModifier(_ id: UUID, by step: Int) {
        guard let i = activeIndex, let k = document.objects[i].modifiers.firstIndex(where: { $0.id == id }) else { return }
        let to = k + step
        guard to >= 0 && to < document.objects[i].modifiers.count else { return }
        edit("Move Modifier") { d in d.objects[i].modifiers.swapAt(k, to) }
    }

    // MARK: Materials

    func addMaterialSlot() {
        guard let i = activeIndex else { return }
        edit("Add Material Slot") { d in
            let n = d.objects[i].materials.count
            d.objects[i].materials.append(MaterialSlot(name: "Material.\(String(format: "%03d", n))"))
        }
    }

    func removeMaterialSlot(_ k: Int) {
        guard let i = activeIndex, document.objects[i].materials.count > 1, k < document.objects[i].materials.count else { return }
        edit("Remove Material Slot") { d in
            d.objects[i].materials.remove(at: k)
            for f in 0..<d.objects[i].mesh.faceCount {
                let s = Int(d.objects[i].mesh.faceMaterial[f])
                if s == k { d.objects[i].mesh.faceMaterial[f] = UInt16(max(0, k - 1)) } else if s > k { d.objects[i].mesh.faceMaterial[f] -= 1 }
            }
            d.objects[i].mesh.touch()
        }
    }

    func updateMaterialSlot(_ k: Int, _ change: @escaping (inout MaterialSlot) -> Void) {
        guard let i = activeIndex, k < document.objects[i].materials.count else { return }
        editCoalesced("Material", key: "mat\(i).\(k)") { d in change(&d.objects[i].materials[k]) }
    }

    /// Edit mode: the selected faces to slot `k` (Assign), or the slot's faces selected or deselected.
    func assignMaterial(_ k: Int) { editMesh("Assign Material") { $0.assignMaterial(k) } }

    func selectMaterial(_ k: Int, _ on: Bool) {
        editMesh(on ? "Select Material" : "Deselect Material") { m in
            for f in 0..<m.faceCount where Int(m.faceMaterial[f]) == k && !m.isHidden(face: f) { m.setSelected(face: f, on) }
            m.flushSelection(from: .face)
        }
    }
}
