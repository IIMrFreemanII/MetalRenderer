import Foundation
import simd

/// Bounding volume hierarchies: a binned-SAH builder over boxes (`BVHBuilder.build`: Lumen's mesh distance fields,
/// SDF volumes), and the small trees over virtual geometry's clusters, stored in their pages (`buildCluster`), which
/// the ray queries walk in the clusters' boxes (Shaders/Intersect.metal, `clusterWalk`).
///
/// A cluster's tree uses a 64-byte node, which holds the boxes of *both* children, so one fetch tests two:
///   child ref (`lo.w` bits): bit 31 clear = index of an internal node in the same tree;
///                            bit 31 set   = leaf: (count - 1) << 28 | first triangle.
/// Its root is always an internal node, so the union of the root's two child boxes is the cluster's bounds.
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

    static func leaf(first: Int, count: Int) -> UInt32 {
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

    /// A small BVH over one virtual-geometry cluster's triangles (≤ 128): node indices and leaf refs are local (leaf
    /// refs with the first triangle in `order`'s numbering). The root is always an internal node.
    static func buildCluster(boxes: [AABB]) -> (nodes: [BVHNode], order: [Int]) {
        let (tree, order) = build(boxes: boxes, masks: nil, maxLeaf: BVHNode.maxLeafTriangles)
        var nodes: [BVHNode] = []
        _ = emit(tree, nodeBase: 0, into: &nodes, forceInternalRoot: true) { n in BVHNode.leaf(first: n.start, count: n.count) }
        return (nodes, order)
    }
}
