import EngineCore
import simd

extension ScatterNodes {
    /// A tree over the triangles (EngineCore's binned-SAH builder) for Ray: the nearest hit along a line and the
    /// nearest point. Each finds what testing every triangle in order finds, the lowest triangle on a tie: a box is
    /// passed over only when all of it is farther than the best so far by more than `pad` (a hundred-thousandth of
    /// the triangles' size), which a triangle's computed hit or nearest point can't make up.
    struct TriangleBVH {
        private let nodes: [BVHBuilder.Node]
        private let order: [Int32]
        private let pad: Float

        init(_ t: Triangles) {
            var boxes = [AABB](repeating: AABB(), count: t.count)
            var all = AABB()
            for k in 0..<t.count {
                boxes[k].grow(t.a[k]); boxes[k].grow(t.b[k]); boxes[k].grow(t.c[k])
                all.grow(boxes[k])
            }
            let (nodes, order) = BVHBuilder.build(boxes: boxes, masks: nil, maxLeaf: 4)
            self.nodes = nodes
            self.order = order.map { Int32($0) }
            let size = all.isEmpty ? 0 : max(simd_reduce_max(all.hi - all.lo), simd_reduce_max(simd_max(abs(all.lo), abs(all.hi))))
            pad = size * 1e-5 + 1e-7
        }

        /// How far along the unit `d` from `o` the line first meets node `n`'s box (0 from inside it, only ahead if
        /// not `both`); nil if it misses.
        @inline(__always) private func entry(_ n: Int, _ o: SIMD3<Float>, _ d: SIMD3<Float>, both: Bool) -> Float? {
            let lo = nodes[n].box.lo - pad, hi = nodes[n].box.hi + pad
            var tmin = -Float.infinity, tmax = Float.infinity
            for a in 0..<3 {
                if d[a] == 0 {
                    if o[a] < lo[a] || o[a] > hi[a] { return nil }
                } else {
                    let t1 = (lo[a] - o[a]) / d[a], t2 = (hi[a] - o[a]) / d[a]
                    tmin = max(tmin, min(t1, t2))
                    tmax = min(tmax, max(t1, t2))
                }
            }
            if tmin > tmax { return nil }
            if !both { return tmax < 0 ? nil : max(tmin, 0) }
            return tmin <= 0 && tmax >= 0 ? 0 : min(abs(tmin), abs(tmax))
        }

        /// The hit of least |distance| (`ScatterNodes.hit`): its distance and triangle.
        func cast(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ t: Triangles, both: Bool, stack: inout [Int32]) -> (Float, Int)? {
            guard !nodes.isEmpty, entry(0, o, d, both: both) != nil else { return nil }
            var best: (Float, Int)?
            var bestAbs = Float.infinity
            stack.removeAll(keepingCapacity: true)
            stack.append(0)
            while let top = stack.popLast() {
                let n = Int(top)
                let node = nodes[n]
                if node.left < 0 {
                    for i in node.start..<(node.start + node.count) {
                        let k = Int(order[i])
                        guard let dist = ScatterNodes.hit(o, d, t, k, both: both) else { continue }
                        if abs(dist) < bestAbs || (abs(dist) == bestAbs && k < (best?.1 ?? -1)) { best = (dist, k); bestAbs = abs(dist) }
                    }
                    continue
                }
                // The nearer child last, so it is looked in first.
                let l = entry(node.left, o, d, both: both), r = entry(node.right, o, d, both: both)
                let keepL = l.map { $0 <= bestAbs + pad } ?? false, keepR = r.map { $0 <= bestAbs + pad } ?? false
                if keepL && keepR {
                    if l! <= r! { stack.append(Int32(node.right)); stack.append(Int32(node.left)) } else { stack.append(Int32(node.left)); stack.append(Int32(node.right)) }
                } else if keepL { stack.append(Int32(node.left)) } else if keepR { stack.append(Int32(node.right)) }
            }
            return best
        }

        /// The squared distance from `p` to node `n`'s box.
        @inline(__always) private func distance2(_ n: Int, _ p: SIMD3<Float>) -> Float {
            simd_distance_squared(simd_clamp(p, nodes[n].box.lo - pad, nodes[n].box.hi + pad), p)
        }

        /// The nearest point on the triangles to `p` (as Ray's minimum method finds it): its triangle and the point.
        func nearest(_ p: SIMD3<Float>, _ t: Triangles, stack: inout [Int32]) -> (Int, SIMD3<Float>)? {
            guard !nodes.isEmpty else { return nil }
            var best = Float.infinity, k = -1, at = p
            stack.removeAll(keepingCapacity: true)
            stack.append(0)
            while let top = stack.popLast() {
                let n = Int(top)
                if distance2(n, p) > best { continue }
                let node = nodes[n]
                if node.left < 0 {
                    for i in node.start..<(node.start + node.count) {
                        let j = Int(order[i])
                        let q = ScatterNodes.closest(p, t.a[j], t.b[j], t.c[j])
                        let d = simd_distance_squared(q, p)
                        if d < best || (d == best && j < k) { best = d; k = j; at = q }
                    }
                    continue
                }
                if distance2(node.left, p) <= distance2(node.right, p) {
                    stack.append(Int32(node.right)); stack.append(Int32(node.left))
                } else {
                    stack.append(Int32(node.left)); stack.append(Int32(node.right))
                }
            }
            return k < 0 ? nil : (k, at)
        }
    }
}
