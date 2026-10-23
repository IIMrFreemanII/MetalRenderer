import Foundation
import Metal
import simd

/// A document as the viewport draws it: each object's buffers kept between frames (made again when its evaluated
/// mesh or its cage changes) and the frame's draw list.
package final class ViewportScene {
    package let device: MTLDevice
    package let modifiers = ModifierCache()
    private var meshes: [UUID: ViewportMesh] = [:]
    /// What draws instead of an object's buffers (sculpt mode's mesh, written in place).
    package var overrides: [UUID: ViewportMesh] = [:]

    package init(device: MTLDevice) { self.device = device }

    /// The evaluated mesh the viewport shows for an object.
    package func evaluated(_ doc: ModelingDocument, _ o: ModelObject, editing: Bool) -> EditMesh {
        modifiers.evaluate(o, for: editing ? .editMode : .viewport) { id in doc.objects.first { $0.id == id } }
    }

    /// The draw list for `doc` in `mode`: edit mode shows the active object's cage (`selectMode`) over its evaluated
    /// faces; objects hidden in the outliner aren't drawn.
    package func objects(_ doc: ModelingDocument, mode: EditorMode, selectMode: SelectMode,
                         active elements: (vertex: Int?, edge: Int?, face: Int?) = (nil, nil, nil),
                         wire: Bool) -> [ViewportObjectDraw] {
        var out: [ViewportObjectDraw] = []
        var live = Set<UUID>()
        for (i, o) in doc.objects.enumerated() where o.visible {
            live.insert(o.id)
            let isActive = doc.active == i
            let editing = mode == .edit && isActive
            let vm = meshes[o.id] ?? ViewportMesh(device: device)
            meshes[o.id] = vm
            if let override = overrides[o.id], mode == .sculpt && isActive {
                var d = ViewportObjectDraw(mesh: override, transform: o.transform.matrix, color: [0.8, 0.8, 0.8], materialColors: [])
                d.sculpt = true
                d.active = true
                d.selected = true
                d.objectID = UInt32(i)
                out.append(d)
                continue
            }
            let shown = evaluated(doc, o, editing: editing)
            // Edit mode without modifiers that change it: the faces are the cage's, so they can show its selection.
            let sameAsCage = shown.generation == o.mesh.generation
            let key = ViewportMesh.FacesKey(generation: shown.generation, edit: editing && sameAsCage,
                                            activeFace: editing ? elements.face : nil)
            if vm.facesKey != key { vm.setFaces(shown, activeFace: key.activeFace, edit: key.edit) }
            if editing {
                let cage = ViewportMesh.CageKey(generation: o.mesh.generation, vertex: elements.vertex, edge: elements.edge, face: elements.face)
                if vm.cageKey != cage { vm.setCage(o.mesh, active: elements) }
            } else if wire {
                let cage = ViewportMesh.CageKey(generation: shown.generation, vertex: nil, edge: nil, face: nil)
                if vm.cageKey != cage { vm.setCage(shown) }
            } else if vm.cageKey != nil {
                vm.clearCage()
            }
            var d = ViewportObjectDraw(mesh: vm, transform: o.transform.matrix, color: [0.8, 0.8, 0.8],
                                       materialColors: o.materials.map(\.baseColor))
            d.selected = doc.selection.contains(o.id) || editing
            d.active = isActive
            d.edit = editing
            d.selectMode = selectMode
            d.objectID = UInt32(i)
            out.append(d)
        }
        for id in meshes.keys where !live.contains(id) { meshes[id] = nil; modifiers.forget(id) }
        return out
    }

    /// The buffers of an object (made if new).
    package func mesh(of id: UUID) -> ViewportMesh? { meshes[id] }

    /// Everything made again at the next frame (after an undo that brought old generations back, say).
    package func invalidate() {
        for m in meshes.values { m.facesKey = nil; m.cageKey = nil }
    }
}
