import Foundation
import Metal
import simd

/// One object's buffers for the viewport: its faces as triangles to shade (a vertex per corner that differs in
/// normal), and, in edit mode, its cage for the overlays (the mesh's own vertices, edges and face dots with their
/// flags). Made again when the mesh's generation changes; sculpt mode writes its vertices in place (SculptDrawing).
package final class ViewportMesh {
    package let device: MTLDevice
    // Faces.
    package var vertices: MTLBuffer?
    package var indices: MTLBuffer?
    package var triangleFace: MTLBuffer?
    package var triangleMaterial: MTLBuffer?
    package var faceFlags: MTLBuffer?
    package var indexCount = 0
    package var faceCount = 0
    // The cage.
    package var cagePositions: MTLBuffer?
    package var vertexFlags: MTLBuffer?
    package var edges: MTLBuffer?
    package var faceCenters: MTLBuffer?
    package var faceDotFlags: MTLBuffer?
    package var cageVertexCount = 0
    package var edgeCount = 0
    package var cageFaceCount = 0
    /// What the buffers were made from: they are made again when it changes.
    package struct FacesKey: Equatable { var generation: UInt64; var edit: Bool; var activeFace: Int? }
    package struct CageKey: Equatable { var generation: UInt64; var vertex: Int?; var edge: Int?; var face: Int? }
    package var facesKey: FacesKey?
    package var cageKey: CageKey?
    package var bounds = (lo: SIMD3<Float>.zero, hi: SIMD3<Float>.zero)

    package init(device: MTLDevice) { self.device = device }

    private func buffer<T>(_ a: [T]) -> MTLBuffer? {
        guard !a.isEmpty else { return nil }
        return a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    /// The faces of `mesh` (hidden ones left out), shaded as its smooth flags and sharp edges say; face flags with
    /// `activeFace` marked.
    package func setFaces(_ mesh: EditMesh, activeFace: Int? = nil, edit: Bool) {
        let t = TriangleMesh(mesh, skipHidden: edit)
        var vs = [ViewVertex]()
        vs.reserveCapacity(t.positions.count)
        for i in 0..<t.positions.count { vs.append(ViewVertex(t.positions[i], normal: t.normals[i])) }
        vertices = buffer(vs)
        indices = buffer(t.indices)
        triangleFace = buffer(t.triangleFace.map { UInt32(bitPattern: $0) })
        triangleMaterial = buffer(t.triangleMaterial)
        var ff = mesh.faceFlags.map { $0 & 3 }
        if let a = activeFace, a < ff.count { ff[a] |= 32 }
        faceFlags = buffer(ff.isEmpty ? [0] : ff)
        indexCount = t.indices.count
        faceCount = mesh.faceCount
        facesKey = FacesKey(generation: mesh.generation, edit: edit, activeFace: activeFace)
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        bounds = mesh.positions.isEmpty ? (.zero, .zero) : (lo, hi)
    }

    /// The cage of `mesh` for the edit overlays and their picking.
    package func setCage(_ mesh: EditMesh, active: (vertex: Int?, edge: Int?, face: Int?) = (nil, nil, nil)) {
        cagePositions = buffer(mesh.positions.map(PackedFloat3.init))
        var vf = mesh.vertFlags.map { $0 & 3 }
        if let a = active.vertex, a < vf.count { vf[a] |= 32 }
        vertexFlags = buffer(vf)
        var es = [EditEdgeGPU]()
        es.reserveCapacity(mesh.edgeCount)
        for e in 0..<mesh.edgeCount {
            var f = UInt32(mesh.edgeFlags[e] & 3)
            if mesh.edgeFlags[e] & EditMesh.Flag.seam != 0 { f |= EditEdgeGPU.Flag.seam }
            if mesh.edgeFlags[e] & EditMesh.Flag.sharp != 0 { f |= EditEdgeGPU.Flag.sharp }
            if mesh.edgeCrease[e] > 0 { f |= EditEdgeGPU.Flag.crease }
            if e == active.edge { f |= EditEdgeGPU.Flag.active }
            es.append(EditEdgeGPU(a: UInt32(mesh.edges[e].x), b: UInt32(mesh.edges[e].y), flags: f))
        }
        edges = buffer(es)
        var centers = [PackedFloat3](), dots = [UInt8]()
        centers.reserveCapacity(mesh.faceCount)
        for f in 0..<mesh.faceCount {
            centers.append(PackedFloat3(mesh.faceCenter(f)))
            dots.append((mesh.faceFlags[f] & 3) | (f == active.face ? 32 : 0))
        }
        faceCenters = buffer(centers)
        faceDotFlags = buffer(dots)
        cageVertexCount = mesh.vertexCount
        edgeCount = mesh.edgeCount
        cageFaceCount = mesh.faceCount
        cageKey = CageKey(generation: mesh.generation, vertex: active.vertex, edge: active.edge, face: active.face)
    }

    /// No cage (object mode).
    package func clearCage() {
        cagePositions = nil; vertexFlags = nil; edges = nil; faceCenters = nil; faceDotFlags = nil
        cageVertexCount = 0; edgeCount = 0; cageFaceCount = 0; cageKey = nil
    }

    /// Faces given as they are (sculpt mode's vertices, written in place): `vertices` must hold `vertexCount`.
    package func setRaw(vertices v: MTLBuffer, indices i: MTLBuffer, indexCount n: Int) {
        vertices = v
        indices = i
        indexCount = n
        triangleFace = nil
        triangleMaterial = nil
        faceFlags = nil
        facesKey = nil
    }
}
