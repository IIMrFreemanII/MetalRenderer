import AppKit
import EngineCore
import Foundation
import Modeling
import simd

/// Sculpt mode's side of the model: entering and leaving it, the brushes, multires, dynamic topology, remeshing.
extension ModelingModel {
    func enterSculpt() {
        sculpt = SculptController(model: self)
        if sculpt == nil { report("Nothing to sculpt") }
        tool = .select
    }

    /// The sculpted shape into the document, and the viewport back to the object's own buffers.
    func leaveSculpt() {
        guard let s = sculpt else { return }
        s.commit(into: self)
        scene?.overrides[s.objectID] = nil
        sculpt = nil
        scene?.invalidate()
    }

    /// The brush: its own settings, as Blender keeps one brush per tool (the radius is shared, as Blender's
    /// unified size).
    func selectBrush(_ kind: SculptBrushKind) {
        brushes[sculptBrush.kind] = sculptBrush
        var b = brushes[kind] ?? SculptBrush(kind: kind)
        b.radius = sculptBrush.radius
        b.symmetry = sculptBrush.symmetry
        sculptBrush = b
        redraw()
    }

    /// Ctrl-D: dynamic topology on or off (detail added and removed as the brush goes).
    func toggleDyntopo() {
        guard mode == .sculpt else { return }
        dyntopo.toggle()
        if dyntopo, let s = sculpt {
            // Multires levels and dynamic topology don't mix (as in Blender): the level becomes the mesh.
            if s.multiresLevel != nil { report("Dynamic Topology: the multires level is the mesh now") }
            s.multiresLevel = nil
        }
        report(dyntopo ? "Dynamic Topology on (detail \(Int(dyntopoDetail)) px)" : "Dynamic Topology off")
    }

    /// Ctrl-R: the sculpt mesh rebuilt as even quads of the voxel size (Blender's Voxel Remesh); masks and face sets
    /// carried over by nearest point. One undo step.
    func voxelRemesh() {
        guard mode == .sculpt, let s = sculpt else { return }
        let m = s.mesh
        let positions = m.position.map { SIMD3($0.x, $0.y, $0.z) }
        let indices = m.liveIndices()
        let started = Date()
        var remeshed = VoxelRemesh.remesh(positions: positions, indices: indices, voxel: voxelSize)
        guard remeshed.faceCount > 0 else { report("Voxel Remesh: nothing came out (voxel size too large?)"); return }
        // Face sets from the old mesh's nearest triangle.
        let tree = TriangleTree(positions: positions, indices: indices)
        let sets = m.leaves.flatMap { l in m.faceSet[Int(m.nodes[Int(l)].triStart)..<Int(m.nodes[Int(l)].triStart + m.nodes[Int(l)].triCount)] }
        for f in 0..<remeshed.faceCount {
            let h = tree.nearest(remeshed.faceCenter(f))
            if h.triangle >= 0 { remeshed.faceSet[f] = sets[h.triangle] }
        }
        let new = SculptMesh(remeshed)
        // Masks by nearest point.
        for v in 0..<new.vertexCount {
            let p = new.position[v]
            let h = tree.nearest(SIMD3(p.x, p.y, p.z))
            guard h.triangle >= 0 else { continue }
            let t = h.triangle
            new.position[v].w = m.position[Int(indices[3 * t])].w * h.bary.x + m.position[Int(indices[3 * t + 1])].w * h.bary.y
                + m.position[Int(indices[3 * t + 2])].w * h.bary.z
        }
        let record = SculptUndoRecord(topology: m.topologyGeneration)
        record.whole = m.snapshot()
        m.replace(with: new)
        s.multiresLevel = nil
        s.drawing?.markTrianglesDirty(m)
        s.register(record, name: "Voxel Remesh", model: self)
        report(String(format: "Voxel Remesh: %d faces in %.2f s", remeshed.faceCount, Date().timeIntervalSince(started)))
        documentChanged(dirty: true)
    }

    // MARK: Multires (the modifier panel's buttons)

    /// Subdivide: a multires level more on the active object.
    func multiresSubdivide() {
        guard let i = activeIndex else { return }
        let wasSculpt = mode == .sculpt
        if wasSculpt { leaveSculpt() }
        edit("Multires Subdivide") { d in
            var r = d.objects[i].multires ?? MultiresData()
            Multires.addLevel(d.objects[i].mesh, &r)
            d.objects[i].multires = r
        }
        if wasSculpt { enterSculpt() }
    }

    func multiresDeleteHigher() {
        guard let i = activeIndex, document.objects[i].multires != nil else { return }
        let wasSculpt = mode == .sculpt
        if wasSculpt { leaveSculpt() }
        edit("Multires Delete Higher") { d in
            var r = d.objects[i].multires!
            Multires.deleteHigher(&r)
            d.objects[i].multires = r.levels == 0 ? nil : r
        }
        if wasSculpt { enterSculpt() }
    }

    /// The level sculpt mode works on (and the viewport shows).
    func setMultiresLevel(sculpt level: Int? = nil, viewport: Int? = nil, render: Int? = nil) {
        guard let i = activeIndex, document.objects[i].multires != nil else { return }
        let wasSculpt = mode == .sculpt
        if wasSculpt { leaveSculpt() }
        edit("Multires Level") { d in
            var r = d.objects[i].multires!
            if let l = level { r.sculptLevel = max(0, min(r.levels, l)) }
            if let l = viewport { r.viewportLevel = max(0, min(r.levels, l)) }
            if let l = render { r.renderLevel = max(0, min(r.levels, l)) }
            d.objects[i].multires = r
        }
        if wasSculpt { enterSculpt() }
    }

    /// Apply Base: the multires shape becomes the mesh (its levels gone).
    func multiresApply() {
        guard let i = activeIndex, let r = document.objects[i].multires else { return }
        let wasSculpt = mode == .sculpt
        if wasSculpt { leaveSculpt() }
        edit("Apply Multires") { d in
            d.objects[i].mesh = Multires.levelMesh(d.objects[i].mesh, r, level: r.sculptLevel)
            d.objects[i].multires = nil
        }
        if wasSculpt { enterSculpt() }
    }
}
