import Foundation
import simd

/// Bounding volume hierarchies for the custom ray tracer (Shaders/Intersect.metal, "Custom BVH traversal").
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
    struct Node {
        var box: AABB
        var left = -1, right = -1      // -1 = leaf
        var start = 0, count = 0
        var mask: UInt32 = 0
    }

    private static let bins = 16
    private static let traversalCost: Float = 1   // relative to one primitive test
    /// A range of more primitives than this is split and its two halves are built at the same time, level after
    /// level: a big mesh's tree is built on every core. Below it a subtree is built by one thread.
    static let parallelGrain = 1 << 15

    /// A subtree as it was built: its nodes in depth-first order with indices local to it, or a node whose halves
    /// were built apart.
    private indirect enum Part {
        case built([Node])
        case split(Node, Part, Part)
        var count: Int {
            switch self {
            case .built(let nodes): return nodes.count
            case .split(_, let l, let r): return 1 + l.count + r.count
            }
        }
    }

    /// One builder's bins: allocated once per subtree, not per node.
    private struct BinScratch {
        let boxes = UnsafeMutablePointer<AABB>.allocate(capacity: 3 * bins)    // per axis
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: 3 * bins)
        let rightArea = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let rightCount = UnsafeMutablePointer<Int>.allocate(capacity: bins)
        func free() { boxes.deallocate(); counts.deallocate(); rightArea.deallocate(); rightCount.deallocate() }
    }

    /// Binned-SAH build over `boxes`. `maxLeaf` = most primitives per leaf (1 for instances). Raw pointers and scratch
    /// bins: this runs over ~18M triangles for the gallery. A node's split depends only on its own range of `order`,
    /// so the halves of a large range are built in parallel and the result is the same tree, node for node, as a
    /// build by one thread (`grain` = .max; BVHTests checks it).
    static func build(boxes: [AABB], masks: [UInt32]?, maxLeaf: Int, grain: Int = parallelGrain) -> (nodes: [Node], order: [Int]) {
        let n = boxes.count
        var order = Array(0..<n)
        guard n > 0 else { return ([], order) }
        // The boxes in the order of `order`, moved along with it: a node reads its primitives as one contiguous range.
        // (Measured the same speed as reading them through the index array: the passes are not what the build costs.)
        let prims = UnsafeMutablePointer<AABB>.allocate(capacity: n)
        defer { prims.deallocate() }
        boxes.withUnsafeBufferPointer { prims.initialize(from: $0.baseAddress!, count: n) }

        let root: Part = order.withUnsafeMutableBufferPointer { ord in
            do {
                /// The node over ord[start..<end], and where it splits: ord is partitioned around `mid`. mid < 0: a leaf.
                func split(_ start: Int, _ end: Int, _ scratch: BinScratch) -> (node: Node, mid: Int) {
                    let binBoxes = scratch.boxes, binCounts = scratch.counts
                    let rightArea = scratch.rightArea, rightCount = scratch.rightCount
                    var box = AABB(), cbox = AABB()
                    var mask: UInt32 = 0
                    for i in start..<end {
                        box.grow(prims[i])
                        cbox.grow(prims[i].centroid)
                        if let masks { mask |= masks[ord[i]] }
                    }
                    let count = end - start
                    let node = Node(box: box, start: start, count: count, mask: mask)
                    if count == 1 { return (node, -1) }

                    // Best split over all three axes. The primitives are binned along the three at once (one pass
                    // over them instead of three: the pass is what a big node costs); an axis the centroids don't
                    // spread along bins everything in bin 0 and is left out of the sweep.
                    var bestCost = Float.infinity, bestAxis = -1, bestBin = 0
                    let extent = cbox.hi - cbox.lo
                    for b in 0..<(3 * bins) { binBoxes[b] = AABB(); binCounts[b] = 0 }
                    let lo3 = cbox.lo
                    var scale3 = SIMD3<Float>(repeating: 0)
                    for axis in 0..<3 where extent[axis] > 0 { scale3[axis] = Float(bins) / extent[axis] }
                    for i in start..<end {
                        let box = prims[i]
                        let f = (box.centroid - lo3) * scale3
                        let b0 = min(bins - 1, Int(f.x)), b1 = bins + min(bins - 1, Int(f.y)), b2 = 2 * bins + min(bins - 1, Int(f.z))
                        binBoxes[b0].grow(box); binCounts[b0] += 1
                        binBoxes[b1].grow(box); binCounts[b1] += 1
                        binBoxes[b2].grow(box); binCounts[b2] += 1
                    }
                    for axis in 0..<3 where extent[axis] > 0 {
                        let binBoxes = binBoxes + axis * bins, binCounts = binCounts + axis * bins
                        // Sweep: right-side areas and counts first, then left to right.
                        var acc = AABB(), c = 0
                        for b in stride(from: bins - 1, to: 0, by: -1) {
                            acc.grow(binBoxes[b]); c += binCounts[b]
                            rightArea[b] = acc.area; rightCount[b] = c
                        }
                        acc = AABB(); c = 0
                        for b in 0..<(bins - 1) {
                            acc.grow(binBoxes[b]); c += binCounts[b]
                            guard c > 0, rightCount[b + 1] > 0 else { continue }
                            let cost = acc.area * Float(c) + rightArea[b + 1] * Float(rightCount[b + 1])
                            if cost < bestCost { bestCost = cost; bestAxis = axis; bestBin = b }
                        }
                    }
                    let parentArea = max(box.area, 1e-20)
                    let splitCost = traversalCost + bestCost / parentArea
                    if count <= maxLeaf && Float(count) <= splitCost { return (node, -1) }

                    var mid: Int
                    if bestAxis >= 0 {
                        let scale = Float(bins) / extent[bestAxis]
                        let lo = cbox.lo[bestAxis]
                        var i = start, j = end - 1
                        while i <= j {
                            if min(bins - 1, Int((prims[i].centroid[bestAxis] - lo) * scale)) <= bestBin { i += 1 }
                            else {
                                ord.swapAt(i, j)
                                let moved = prims[i]; prims[i] = prims[j]; prims[j] = moved
                                j -= 1
                            }
                        }
                        mid = i
                    } else {
                        mid = (start + end) / 2   // all centroids coincide: split the list in half
                    }
                    if mid == start || mid == end { mid = (start + end) / 2 }
                    return (node, mid)
                }
                /// One thread's build of ord[start..<end] into `nodes`, depth first. Returns the subtree's root.
                func serial(_ start: Int, _ end: Int, _ scratch: BinScratch, into nodes: inout [Node]) -> Int {
                    let (node, mid) = split(start, end, scratch)
                    let index = nodes.count
                    nodes.append(node)
                    if mid < 0 { return index }
                    let l = serial(start, mid, scratch, into: &nodes)
                    let r = serial(mid, end, scratch, into: &nodes)
                    nodes[index].left = l
                    nodes[index].right = r
                    return index
                }
                func part(_ start: Int, _ end: Int) -> Part {
                    let scratch = BinScratch()
                    defer { scratch.free() }
                    if end - start <= grain {
                        var nodes: [Node] = []
                        nodes.reserveCapacity(2 * (end - start))
                        _ = serial(start, end, scratch, into: &nodes)
                        return .built(nodes)
                    }
                    let (node, mid) = split(start, end, scratch)
                    if mid < 0 { return .built([node]) }
                    let halves = UnsafeMutablePointer<Part?>.allocate(capacity: 2)
                    halves.initialize(repeating: nil, count: 2)
                    defer { halves.deinitialize(count: 2); halves.deallocate() }
                    DispatchQueue.concurrentPerform(iterations: 2) { h in   // its own slot each: no lock
                        halves[h] = h == 0 ? part(start, mid) : part(mid, end)
                    }
                    return .split(node, halves[0]!, halves[1]!)
                }
                return part(0, n)
            }
        }
        if case .built(let nodes) = root { return (nodes, order) }
        let total = root.count
        let nodes = [Node](unsafeUninitializedCapacity: total) { buffer, count in
            count = flatten(root, into: buffer.baseAddress!, at: 0)
        }
        return (nodes, order)
    }

    /// Writes a subtree's nodes in depth-first order from `base` on, with their indices made absolute. Returns its size.
    private static func flatten(_ part: Part, into out: UnsafeMutablePointer<Node>, at base: Int) -> Int {
        switch part {
        case .built(let nodes):
            for (i, node) in nodes.enumerated() {
                var node = node
                if node.left >= 0 { node.left += base; node.right += base }
                (out + base + i).initialize(to: node)
            }
            return nodes.count
        case .split(let node, let l, let r):
            let left = flatten(l, into: out, at: base + 1)
            let right = flatten(r, into: out, at: base + 1 + left)
            var node = node
            node.left = base + 1
            node.right = base + 1 + left
            (out + base).initialize(to: node)
            return 1 + left + right
        }
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
            let left = ref(n.left)   // depth first: the left subtree's nodes, then the right one's
            out[slot].setChild(0, lo: tree[n.left].box.lo, hi: tree[n.left].box.hi, ref: left, mask: tree[n.left].mask)
            let right = ref(n.right)
            out[slot].setChild(1, lo: tree[n.right].box.lo, hi: tree[n.right].box.hi, ref: right, mask: tree[n.right].mask)
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

    /// One BLAS per mesh, all in one node buffer and one triangle buffer. Meshes are built in parallel.
    static func buildBLAS(positions: [SIMD3<Float>], indices: [UInt32], meshes: [GPUMesh]) -> BLASResult {
        var trees = [(nodes: [Node], order: [Int])](repeating: ([], []), count: meshes.count)
        // Each mesh's first triangle in the shared triangle buffer (its triangles keep their count, reordered).
        var triBases = [Int](repeating: 0, count: meshes.count + 1)
        for (m, mesh) in meshes.enumerated() { triBases[m + 1] = triBases[m] + Int(mesh.indexCount) / 3 }
        var result = BLASResult()
        result.triangles = [SIMD4<Float>](repeating: .zero, count: 3 * triBases[meshes.count])
        positions.withUnsafeBufferPointer { pos in
            indices.withUnsafeBufferPointer { idx in
                trees.withUnsafeMutableBufferPointer { slots in
                    result.triangles.withUnsafeMutableBufferPointer { tris in
                        DispatchQueue.concurrentPerform(iterations: meshes.count) { m in
                            let mesh = meshes[m]
                            let triCount = Int(mesh.indexCount) / 3, first = Int(mesh.firstIndex)
                            var boxes: [AABB] = []
                            boxes.reserveCapacity(triCount)
                            for t in 0..<triCount {
                                var b = AABB()
                                for k in 0..<3 { b.grow(pos[Int(idx[first + 3 * t + k])]) }
                                boxes.append(b)
                            }
                            let tree = build(boxes: boxes, masks: nil, maxLeaf: BVHNode.maxLeafTriangles)
                            // The mesh's triangles in leaf order, into its own range of the buffer.
                            var out = 3 * triBases[m]
                            for t in tree.order {
                                let base = first + 3 * t
                                let p0 = pos[Int(idx[base])], p1 = pos[Int(idx[base + 1])], p2 = pos[Int(idx[base + 2])]
                                tris[out] = SIMD4(p0, Float(bitPattern: UInt32(t)))
                                tris[out + 1] = SIMD4(p1 - p0, 0)
                                tris[out + 2] = SIMD4(p2 - p0, 0)
                                out += 3
                            }
                            slots[m] = tree   // its own slot: no lock
                        }
                    }
                }
            }
        }
        // Each mesh's nodes go to its own range of the node buffer: a tree of n leaves has n - 1 child-pair nodes (a
        // lone leaf gets a root of its own), so the ranges are known up front and the meshes are written in parallel.
        var nodeBases = [Int](repeating: 0, count: meshes.count + 1)
        for m in meshes.indices {
            let count = trees[m].nodes.count
            nodeBases[m + 1] = nodeBases[m] + (count == 0 ? 0 : max((count - 1) / 2, 1))
        }
        result.nodes = [BVHNode](repeating: BVHNode(), count: nodeBases[meshes.count])
        var roots = [UInt32](repeating: BVHNode.none, count: meshes.count)
        var depths = [Int](repeating: 0, count: meshes.count)
        result.nodes.withUnsafeMutableBufferPointer { out in
            roots.withUnsafeMutableBufferPointer { rootSlots in
            depths.withUnsafeMutableBufferPointer { depthSlots in
                DispatchQueue.concurrentPerform(iterations: meshes.count) { m in
                    let triBase = triBases[m]
                    var local: [BVHNode] = []
                    local.reserveCapacity(nodeBases[m + 1] - nodeBases[m])
                    rootSlots[m] = emit(trees[m].nodes, nodeBase: nodeBases[m], into: &local, forceInternalRoot: true) { n in
                        BVHNode.blasLeaf(first: triBase + n.start, count: n.count)
                    }
                    precondition(local.count == nodeBases[m + 1] - nodeBases[m])
                    for (i, node) in local.enumerated() { out[nodeBases[m] + i] = node }
                    depthSlots[m] = depth(trees[m].nodes)
                }
            }
            }
        }
        for m in meshes.indices {
            let tree = trees[m].nodes
            let root = roots[m]
            result.roots.append(root)
            result.bounds.append(tree.first?.box ?? AABB())
            result.maxDepth = max(result.maxDepth, depths[m])
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

    /// A small BVH over one virtual-geometry cluster's triangles (≤ 128): node indices and leaf refs are local
    /// (BLAS leaf refs with the first triangle in `order`'s numbering). The root is always an internal node.
    static func buildCluster(boxes: [AABB]) -> (nodes: [BVHNode], order: [Int]) {
        let (tree, order) = build(boxes: boxes, masks: nil, maxLeaf: BVHNode.maxLeafTriangles)
        var nodes: [BVHNode] = []
        _ = emit(tree, nodeBase: 0, into: &nodes, forceInternalRoot: true) { n in BVHNode.blasLeaf(first: n.start, count: n.count) }
        return (nodes, order)
    }

    /// An SAH tree over subtrees that already sit in the same node buffer, one per box: each leaf becomes the child ref
    /// `subtreeRef(i)` (an internal node's index), with box `boxes[i]`. The root is node 0, and there are
    /// max(count - 1, 1) nodes, so the subtrees can be placed right after them.
    static func buildOverSubtrees(boxes: [AABB], subtreeRef: (Int) -> UInt32) -> [BVHNode] {
        let (tree, order) = build(boxes: boxes, masks: nil, maxLeaf: 1)
        var nodes: [BVHNode] = []
        nodes.reserveCapacity(max(boxes.count - 1, 1))
        _ = emit(tree, nodeBase: 0, into: &nodes, forceInternalRoot: true) { n in subtreeRef(order[n.start]) }
        return nodes
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
