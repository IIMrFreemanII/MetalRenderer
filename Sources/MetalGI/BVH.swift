import simd

/// Bounding volume hierarchies for the custom ray tracer (Shaders.metal, "Custom BVH traversal").
///
/// Every tree uses the same 64-byte node, which holds the boxes of *both* children, so one fetch tests two:
///   child ref (`lo.w` bits): bit 31 clear = index of an internal node in the same buffer;
///                            bit 31 set   = leaf: BLAS: (count - 1) << 28 | first triangle; TLAS: instance index.
///   `hi.w` bits: TLAS = OR of the instance masks under the child (rays skip subtrees they can't hit); BLAS = 0.
/// Levels:
///   BLAS per mesh, object space, built once here (binned SAH, up to 4 triangles per leaf). Its root is always an
///     internal node, so the union of the root's two child boxes is the mesh's bounds.
///   static TLAS over the instances that never move, built once here.
///   dynamic TLAS over moving instances, rebuilt every frame on the GPU (CustomRayTracer, LBVH).
struct BVHNode {
    var lo0 = SIMD4<Float>(repeating: 0)
    var hi0 = SIMD4<Float>(repeating: 0)
    var lo1 = SIMD4<Float>(repeating: 0)
    var hi1 = SIMD4<Float>(repeating: 0)

    static let leafBit: UInt32 = 0x8000_0000
    static let none: UInt32 = 0xFFFF_FFFF      // root ref of an empty tree
    static let maxLeafTriangles = 4             // leaf triangle count is stored in 3 bits of the ref (1...8)

    mutating func setChild(_ i: Int, lo: SIMD3<Float>, hi: SIMD3<Float>, ref: UInt32, mask: UInt32) {
        let l = SIMD4<Float>(lo, Float(bitPattern: ref)), h = SIMD4<Float>(hi, Float(bitPattern: mask))
        if i == 0 { lo0 = l; hi0 = h } else { lo1 = l; hi1 = h }
    }
    func ref(_ i: Int) -> UInt32 { (i == 0 ? lo0 : lo1).w.bitPattern }
    func mask(_ i: Int) -> UInt32 { (i == 0 ? hi0 : hi1).w.bitPattern }
    func lo(_ i: Int) -> SIMD3<Float> { let v = i == 0 ? lo0 : lo1; return SIMD3(v.x, v.y, v.z) }
    func hi(_ i: Int) -> SIMD3<Float> { let v = i == 0 ? hi0 : hi1; return SIMD3(v.x, v.y, v.z) }

    static func blasLeaf(first: Int, count: Int) -> UInt32 {
        precondition(count >= 1 && count <= 8 && first < 1 << 28)
        return leafBit | UInt32(count - 1) << 28 | UInt32(first)
    }
}

struct AABB {
    var lo = SIMD3<Float>(repeating: .infinity)
    var hi = SIMD3<Float>(repeating: -.infinity)

    mutating func grow(_ p: SIMD3<Float>) { lo = simd_min(lo, p); hi = simd_max(hi, p) }
    mutating func grow(_ b: AABB) { lo = simd_min(lo, b.lo); hi = simd_max(hi, b.hi) }
    var isEmpty: Bool { lo.x > hi.x }
    var centroid: SIMD3<Float> { (lo + hi) * 0.5 }
    var area: Float {
        if isEmpty { return 0 }
        let d = hi - lo
        return 2 * (d.x * d.y + d.y * d.z + d.z * d.x)
    }
    /// Bounds of this box after `m` (all 8 corners).
    func transformed(_ m: float4x4) -> AABB {
        var out = AABB()
        for c in 0..<8 {
            let p = SIMD3<Float>(c & 1 == 0 ? lo.x : hi.x, c & 2 == 0 ? lo.y : hi.y, c & 4 == 0 ? lo.z : hi.z)
            let q = m * SIMD4<Float>(p, 1)
            out.grow(SIMD3(q.x, q.y, q.z))
        }
        return out
    }
}

enum BVHBuilder {
    /// A built tree before it is written as child-pair nodes: `order` holds primitive indices, leaves own ranges of it.
    private struct Node {
        var box: AABB
        var left = -1, right = -1      // -1 = leaf
        var start = 0, count = 0
        var mask: UInt32 = 0
    }

    private static let bins = 16
    private static let traversalCost: Float = 1   // relative to one primitive test

    /// Binned-SAH build over `boxes`. `maxLeaf` = most primitives per leaf (1 for instances).
    private static func build(boxes: [AABB], masks: [UInt32]?, maxLeaf: Int) -> (nodes: [Node], order: [Int]) {
        var order = Array(boxes.indices)
        let centroids = boxes.map(\.centroid)
        var nodes: [Node] = []
        nodes.reserveCapacity(max(2 * boxes.count, 1))

        func makeNode(_ start: Int, _ end: Int) -> Int {
            var box = AABB(), cbox = AABB()
            var mask: UInt32 = 0
            for i in start..<end {
                box.grow(boxes[order[i]])
                cbox.grow(centroids[order[i]])
                mask |= masks?[order[i]] ?? 0
            }
            let index = nodes.count
            nodes.append(Node(box: box, start: start, count: end - start, mask: mask))
            let count = end - start
            if count == 1 { return index }

            // Best split over all three axes.
            var bestCost = Float.infinity, bestAxis = -1, bestBin = 0
            let extent = cbox.hi - cbox.lo
            for axis in 0..<3 where extent[axis] > 0 {
                var binBoxes = [AABB](repeating: AABB(), count: bins)
                var binCounts = [Int](repeating: 0, count: bins)
                let scale = Float(bins) / extent[axis]
                for i in start..<end {
                    let b = min(bins - 1, Int((centroids[order[i]][axis] - cbox.lo[axis]) * scale))
                    binBoxes[b].grow(boxes[order[i]])
                    binCounts[b] += 1
                }
                // Sweep: right-side areas and counts first, then left to right.
                var rightArea = [Float](repeating: 0, count: bins), rightCount = [Int](repeating: 0, count: bins)
                var acc = AABB(), n = 0
                for b in stride(from: bins - 1, to: 0, by: -1) {
                    acc.grow(binBoxes[b]); n += binCounts[b]
                    rightArea[b] = acc.area; rightCount[b] = n
                }
                acc = AABB(); n = 0
                for b in 0..<(bins - 1) {
                    acc.grow(binBoxes[b]); n += binCounts[b]
                    guard n > 0, rightCount[b + 1] > 0 else { continue }
                    let cost = acc.area * Float(n) + rightArea[b + 1] * Float(rightCount[b + 1])
                    if cost < bestCost { bestCost = cost; bestAxis = axis; bestBin = b }
                }
            }
            let parentArea = max(box.area, 1e-20)
            let splitCost = traversalCost + bestCost / parentArea
            if count <= maxLeaf && Float(count) <= splitCost { return index }

            var mid: Int
            if bestAxis >= 0 {
                let scale = Float(bins) / extent[bestAxis]
                let lo = cbox.lo[bestAxis]
                var i = start, j = end - 1
                while i <= j {
                    if min(bins - 1, Int((centroids[order[i]][bestAxis] - lo) * scale)) <= bestBin { i += 1 }
                    else { order.swapAt(i, j); j -= 1 }
                }
                mid = i
            } else {
                mid = (start + end) / 2   // all centroids coincide: split the list in half
            }
            if mid == start || mid == end { mid = (start + end) / 2 }
            let l = makeNode(start, mid)
            let r = makeNode(mid, end)
            nodes[index].left = l
            nodes[index].right = r
            return index
        }
        if !boxes.isEmpty { _ = makeNode(0, boxes.count) }
        return (nodes, order)
    }

    /// Writes a built tree as child-pair nodes in depth-first order, starting at `nodeBase` (absolute indices).
    /// `leafRef(node)` gives a leaf's child ref. Returns the root ref.
    private static func emit(_ tree: [Node], nodeBase: Int, into out: inout [BVHNode],
                             forceInternalRoot: Bool, leafRef: (Node) -> UInt32) -> UInt32 {
        guard !tree.isEmpty else { return BVHNode.none }
        func ref(_ i: Int) -> UInt32 { tree[i].left < 0 ? leafRef(tree[i]) : UInt32(write(i)) }
        func write(_ i: Int) -> Int {
            let slot = out.count
            out.append(BVHNode())
            let n = tree[i]
            for (k, c) in [n.left, n.right].enumerated() {
                let r = ref(c)
                out[slot].setChild(k, lo: tree[c].box.lo, hi: tree[c].box.hi, ref: r, mask: tree[c].mask)
            }
            return nodeBase + slot
        }
        if tree[0].left >= 0 { return UInt32(write(0)) }
        if !forceInternalRoot { return leafRef(tree[0]) }
        // A single leaf: wrap it in a node whose second child is empty (a far-away point box, ref `none`).
        let slot = out.count
        var node = BVHNode()
        node.setChild(0, lo: tree[0].box.lo, hi: tree[0].box.hi, ref: leafRef(tree[0]), mask: tree[0].mask)
        node.setChild(1, lo: SIMD3(repeating: 1e30), hi: SIMD3(repeating: 1e30), ref: BVHNode.none, mask: 0)
        out.append(node)
        return UInt32(nodeBase + slot)
    }

    struct BLASResult {
        var nodes: [BVHNode] = []
        var triangles: [SIMD4<Float>] = []   // 3 per triangle in leaf order: v0 (w = triangle index in mesh), e1, e2
        var roots: [UInt32] = []             // per mesh
        var bounds: [AABB] = []              // per mesh
        var maxDepth = 0
    }

    /// One BLAS per mesh, all in one node buffer and one triangle buffer.
    static func buildBLAS(positions: [SIMD3<Float>], indices: [UInt32], meshes: [GPUMesh]) -> BLASResult {
        var result = BLASResult()
        for mesh in meshes {
            let triCount = Int(mesh.indexCount) / 3
            var boxes: [AABB] = []
            boxes.reserveCapacity(triCount)
            for t in 0..<triCount {
                var b = AABB()
                for k in 0..<3 { b.grow(positions[Int(indices[Int(mesh.firstIndex) + 3 * t + k])]) }
                boxes.append(b)
            }
            let (tree, order) = build(boxes: boxes, masks: nil, maxLeaf: BVHNode.maxLeafTriangles)
            let triBase = result.triangles.count / 3
            for t in order {
                let base = Int(mesh.firstIndex) + 3 * t
                let p0 = positions[Int(indices[base])], p1 = positions[Int(indices[base + 1])], p2 = positions[Int(indices[base + 2])]
                result.triangles += [SIMD4(p0, Float(bitPattern: UInt32(t))), SIMD4(p1 - p0, 0), SIMD4(p2 - p0, 0)]
            }
            let root = emit(tree, nodeBase: 0, into: &result.nodes, forceInternalRoot: true) { n in
                BVHNode.blasLeaf(first: triBase + n.start, count: n.count)
            }
            result.roots.append(root)
            result.bounds.append(tree.first?.box ?? AABB())
            result.maxDepth = max(result.maxDepth, depth(tree))
        }
        return result
    }

    /// TLAS over instances with world-space `boxes`; leaves are the instance indices `ids`. Appends to `nodes`, whose
    /// first element will sit at `nodeBase` in the GPU buffer, and returns the root ref (an instance leaf ref if there is only one, `none` if none).
    static func buildTLAS(boxes: [AABB], ids: [Int], masks: [UInt32], nodeBase: Int,
                          into nodes: inout [BVHNode]) -> (root: UInt32, depth: Int) {
        let (tree, order) = build(boxes: boxes, masks: masks, maxLeaf: 1)
        let root = emit(tree, nodeBase: nodeBase, into: &nodes, forceInternalRoot: false) { n in
            BVHNode.leafBit | UInt32(ids[order[n.start]])
        }
        return (root, depth(tree))
    }

    private static func depth(_ tree: [Node]) -> Int {
        guard !tree.isEmpty else { return 0 }
        var best = 0
        var stack = [(0, 1)]
        while let (i, d) = stack.popLast() {
            best = max(best, d)
            if tree[i].left >= 0 { stack.append((tree[i].left, d + 1)); stack.append((tree[i].right, d + 1)) }
        }
        return best
    }
}
