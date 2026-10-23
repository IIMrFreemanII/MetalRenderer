import Foundation
import Metal
import simd

/// Sculpt mode's mesh on the GPU: two vertex buffers taken in turn (a frame the GPU still reads isn't written), each
/// with the leaves still to copy into it; the triangles (hidden ones drawn as nothing). A brush's dab marks its leaves;
/// a frame copies only those leaves' vertex ranges.
package final class SculptDrawing {
    package let device: MTLDevice
    private var buffers: [MTLBuffer] = []
    private var index: MTLBuffer?
    private var pending: [Set<Int>] = [[], []]
    private var turn = 0
    private var topology: UInt64 = 0
    private var indicesDirty = true
    package let drawn: ViewportMesh

    package init(device: MTLDevice) {
        self.device = device
        drawn = ViewportMesh(device: device)
    }

    package func markDirty(_ leaves: some Sequence<Int>) {
        for l in leaves { pending[0].insert(l); pending[1].insert(l) }
    }

    /// Face sets or hidden triangles changed: the triangles again, and every vertex's colour.
    package func markTrianglesDirty(_ m: SculptMesh) {
        indicesDirty = true
        markDirty(m.leaves.indices)
    }

    /// The buffers for this frame, brought up to date. Returns what to draw.
    package func prepare(_ m: SculptMesh) -> ViewportMesh {
        if topology != m.topologyGeneration || buffers.isEmpty || buffers[0].length < m.vertexCount * MemoryLayout<ViewVertex>.stride {
            let length = max(1, m.vertexCount) * MemoryLayout<ViewVertex>.stride
            buffers = (0..<2).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
            topology = m.topologyGeneration
            indicesDirty = true
            pending = [Set(m.leaves.indices), Set(m.leaves.indices)]
            // Vertices no leaf owns: written once.
            let owned = m.leaves.reduce(0) { $0 + Int(m.nodes[Int($1)].vertCount) }
            if owned < m.vertexCount {
                for b in buffers { write(m, into: b, start: owned, end: m.vertexCount) }
            }
        }
        if indicesDirty {
            var ix = m.indices
            for t in 0..<m.triangleCount where m.hidden[t] { ix[3 * t + 1] = ix[3 * t]; ix[3 * t + 2] = ix[3 * t] }
            index = ix.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(4, $0.count), options: .storageModeShared) }
            indicesDirty = false
        }
        turn = 1 - turn
        let buffer = buffers[turn]
        let leaves = Array(pending[turn])
        pending[turn].removeAll(keepingCapacity: true)
        if !leaves.isEmpty {
            let ranges = leaves.map { (Int(m.nodes[Int(m.leaves[$0])].vertStart), Int(m.nodes[Int(m.leaves[$0])].vertCount)) }
            m.position.withUnsafeBufferPointer { p in
                m.normal.withUnsafeBufferPointer { n in
                    m.faceSet.withUnsafeBufferPointer { fs in
                        m.vtStart.withUnsafeBufferPointer { vs in
                            m.vtList.withUnsafeBufferPointer { vl in
                                let out = buffer.contents().bindMemory(to: ViewVertex.self, capacity: m.vertexCount)
                                let pp = p.baseAddress!, np = n.baseAddress!, fp = fs.baseAddress!, sp = vs.baseAddress!, lp = vl.baseAddress!
                                DispatchQueue.concurrentPerform(iterations: ranges.count) { k in
                                    let (start, count) = ranges[k]
                                    sculptWriteVertices(pp, np, fp, sp, lp, out, start, start + count)
                                }
                            }
                        }
                    }
                }
            }
        }
        if let index { drawn.setRaw(vertices: buffer, indices: index, indexCount: m.indices.count) }
        return drawn
    }

    private func write(_ m: SculptMesh, into b: MTLBuffer, start: Int, end: Int) {
        let out = b.contents().bindMemory(to: ViewVertex.self, capacity: m.vertexCount)
        for v in start..<end {
            let p = m.position[v], n = m.normal[v]
            out[v] = ViewVertex(SIMD3(p.x, p.y, p.z), normal: SIMD3(n.x, n.y, n.z), mask: p.w, faceSet: 0)
        }
    }
}

/// Vertices `start..<end` as the viewport draws them: position, normal, mask, and the colour of their first
/// triangle's face set.
@inline(never)
func sculptWriteVertices(_ p: UnsafePointer<SIMD4<Float>>, _ n: UnsafePointer<SIMD4<Float>>, _ faceSet: UnsafePointer<Int32>,
                         _ vtStart: UnsafePointer<Int32>, _ vtList: UnsafePointer<Int32>, _ out: UnsafeMutablePointer<ViewVertex>,
                         _ start: Int, _ end: Int) {
    var v = start
    while v < end {
        let q = p[v], nn = n[v]
        let k = Int(vtStart[v])
        let set = k < Int(vtStart[v + 1]) ? faceSet[Int(vtList[k])] : 0
        out[v] = ViewVertex(SIMD3(q.x, q.y, q.z), normal: SIMD3(nn.x, nn.y, nn.z), mask: q.w, faceSet: set != 0 ? faceSetColor(set) : 0)
        v &+= 1
    }
}
