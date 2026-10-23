import Foundation
import Metal
import simd

/// Sculpt mode's mesh on the GPU: two vertex buffers and two index buffers taken in turn (a frame the GPU still reads
/// isn't written), each with the leaves and triangle slots still to copy into it (hidden triangles drawn as nothing).
/// A brush's dab marks its leaves, dynamic topology its triangle slots too; a frame copies only those. The buffers
/// have room to spare, so the mesh growing under dynamic topology doesn't make them again each time.
package final class SculptDrawing {
    package let device: MTLDevice
    private var buffers: [MTLBuffer] = []
    private var indexBuffers: [MTLBuffer] = []
    private var pending: [Set<Int>] = [[], []]
    private var pendingTriangles: [[Range<Int>]] = [[], []]
    private var allTriangles = [true, true]
    private var turn = 0
    private var topology: UInt64 = 0
    package let drawn: ViewportMesh

    package init(device: MTLDevice) {
        self.device = device
        drawn = ViewportMesh(device: device)
    }

    package func markDirty(_ leaves: some Sequence<Int>) {
        for l in leaves { pending[0].insert(l); pending[1].insert(l) }
    }

    /// Triangle slots changed (dynamic topology).
    package func markTriangles(_ ranges: [Range<Int>]) {
        pendingTriangles[0] += ranges
        pendingTriangles[1] += ranges
    }

    /// Face sets or hidden triangles changed: the triangles again, and every vertex's colour.
    package func markTrianglesDirty(_ m: SculptMesh) {
        allTriangles = [true, true]
        markDirty(m.leaves.indices)
    }

    /// The buffers for this frame, brought up to date. Returns what to draw.
    package func prepare(_ m: SculptMesh) -> ViewportMesh {
        let vertexBytes = m.vertexCount * MemoryLayout<ViewVertex>.stride
        if topology != m.topologyGeneration || buffers.isEmpty || buffers[0].length < vertexBytes {
            // Room for a quarter more (dynamic topology adds vertices at the end).
            let length = max(1, m.vertexCount + m.vertexCount / 4 + 1024) * MemoryLayout<ViewVertex>.stride
            buffers = (0..<2).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
            for b in buffers { write(m, into: b, start: 0, end: m.vertexCount) }
            pending = [[], []]
        }
        let indexBytes = m.indices.count * MemoryLayout<UInt32>.stride
        if topology != m.topologyGeneration || indexBuffers.isEmpty || indexBuffers[0].length < indexBytes {
            let length = max(4, (m.indices.count + m.indices.count / 4 + 3072) * MemoryLayout<UInt32>.stride)
            indexBuffers = (0..<2).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
            allTriangles = [true, true]
        }
        topology = m.topologyGeneration
        turn = 1 - turn
        let buffer = buffers[turn], index = indexBuffers[turn]
        if allTriangles[turn] {
            writeIndices(m, into: index, 0..<m.triangleSlots)
            allTriangles[turn] = false
            pendingTriangles[turn].removeAll(keepingCapacity: true)
        } else {
            for r in pendingTriangles[turn] { writeIndices(m, into: index, r.clamped(to: 0..<m.triangleSlots)) }
            pendingTriangles[turn].removeAll(keepingCapacity: true)
        }
        let leaves = Array(pending[turn])
        pending[turn].removeAll(keepingCapacity: true)
        if !leaves.isEmpty {
            let ranges = leaves.map { (Int(m.nodes[Int(m.leaves[$0])].vertStart), Int(m.nodes[Int(m.leaves[$0])].vertCount)) }
            m.position.withUnsafeBufferPointer { p in
                m.normal.withUnsafeBufferPointer { n in
                    m.faceSet.withUnsafeBufferPointer { fs in
                        m.vtStart.withUnsafeBufferPointer { vs in
                            m.vtEnd.withUnsafeBufferPointer { ve in
                                m.vtList.withUnsafeBufferPointer { vl in
                                    let out = buffer.contents().bindMemory(to: ViewVertex.self, capacity: m.vertexCount)
                                    let pp = p.baseAddress!, np = n.baseAddress!, fp = fs.baseAddress!
                                    let sp = vs.baseAddress!, ep = ve.baseAddress!, lp = vl.baseAddress!
                                    DispatchQueue.concurrentPerform(iterations: ranges.count) { k in
                                        let (start, count) = ranges[k]
                                        sculptWriteVertices(pp, np, fp, sp, ep, lp, out, start, start + count)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        drawn.setRaw(vertices: buffer, indices: index, indexCount: m.indices.count)
        return drawn
    }

    /// Every vertex slot, in parallel parts.
    private func write(_ m: SculptMesh, into b: MTLBuffer, start: Int, end: Int) {
        guard end > start else { return }
        let out = b.contents().bindMemory(to: ViewVertex.self, capacity: m.vertexCount)
        let parts = max(1, min(64, (end - start) / 16_384))
        m.position.withUnsafeBufferPointer { p in
            m.normal.withUnsafeBufferPointer { n in
                m.faceSet.withUnsafeBufferPointer { fs in
                    m.vtStart.withUnsafeBufferPointer { vs in
                        m.vtEnd.withUnsafeBufferPointer { ve in
                            m.vtList.withUnsafeBufferPointer { vl in
                                let pp = p.baseAddress!, np = n.baseAddress!, fp = fs.baseAddress!
                                let sp = vs.baseAddress!, ep = ve.baseAddress!, lp = vl.baseAddress!
                                DispatchQueue.concurrentPerform(iterations: parts) { k in
                                    let a = start + (end - start) * k / parts, z = start + (end - start) * (k + 1) / parts
                                    sculptWriteVertices(pp, np, fp, sp, ep, lp, out, a, z)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Triangle slots `r` into an index buffer, hidden ones collapsed to a point.
    private func writeIndices(_ m: SculptMesh, into b: MTLBuffer, _ r: Range<Int>) {
        guard !r.isEmpty else { return }
        let out = b.contents().bindMemory(to: UInt32.self, capacity: m.indices.count)
        m.indices.withUnsafeBufferPointer { ix in
            m.hidden.withUnsafeBufferPointer { h in
                for t in r {
                    let a = ix[3 * t]
                    if h[t] {
                        out[3 * t] = a; out[3 * t + 1] = a; out[3 * t + 2] = a
                    } else {
                        out[3 * t] = a; out[3 * t + 1] = ix[3 * t + 1]; out[3 * t + 2] = ix[3 * t + 2]
                    }
                }
            }
        }
    }
}

/// Vertices `start..<end` as the viewport draws them: position, normal, mask, and the colour of their first
/// triangle's face set.
@inline(never)
func sculptWriteVertices(_ p: UnsafePointer<SIMD4<Float>>, _ n: UnsafePointer<SIMD4<Float>>, _ faceSet: UnsafePointer<Int32>,
                         _ vtStart: UnsafePointer<Int32>, _ vtEnd: UnsafePointer<Int32>, _ vtList: UnsafePointer<Int32>,
                         _ out: UnsafeMutablePointer<ViewVertex>, _ start: Int, _ end: Int) {
    var v = start
    while v < end {
        let q = p[v], nn = n[v]
        let k = Int(vtStart[v])
        let set = k < Int(vtEnd[v]) ? faceSet[Int(vtList[k])] : 0
        out[v] = ViewVertex(SIMD3(q.x, q.y, q.z), normal: SIMD3(nn.x, nn.y, nn.z), mask: q.w, faceSet: set != 0 ? faceSetColor(set) : 0)
        v &+= 1
    }
}
