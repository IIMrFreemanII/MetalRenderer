import simd

/// One node of the light tree (MSL LightTreeNode): its lights' bounds, power and emission cone.
struct GPULightTreeNode {
    var lo = SIMD4<Float>()        // xyz = bounds min, w = power (the lights' intensity luminance, lightUnshadowed's units)
    var hi = SIMD4<Float>()        // xyz = bounds max, w = cos of the cone's spread θo (-1: every direction)
    var axis = SIMD4<Float>()      // xyz = cone axis, w = cos of θe, how far past θo the lights still emit
    var link = SIMD4<UInt32>()     // x = left child (or LightTree.leaf | light index), y = right child, z = parent
}

/// A bounding hierarchy over the lights (every one but the suns; a mesh light is one leaf), for MegaLights' far-field
/// samples: a light is drawn by walking down from the root, at each node in proportion to the two children's
/// importance at the pixel (Conty Estevez & Kulla 2018, as in PBRT-v4's BVHLightSampler; a leaf weighs its light's
/// exact unshadowed light), and the probability of any light can be computed back along its path. Built once per
/// scene by median splits (so no path is deeper than 32), refit each frame for the lights that move or change.
struct LightTree {
    static let leaf: UInt32 = 1 << 31
    static let notInTree = UInt32.max

    private(set) var nodes: [GPULightTreeNode] = []
    /// Per light: x = its path from the root (bit k set: right at depth k), y = its depth (notInTree: not in the tree).
    private(set) var paths: [SIMD2<UInt32>] = []
    /// Bumped by every change, so each frame's buffer knows whether it is behind.
    private(set) var version = 0
    private var leafOf: [Int32] = []

    /// Bytes in a frame's buffer: the nodes, then the paths.
    var byteCount: Int { nodes.count * MemoryLayout<GPULightTreeNode>.stride + paths.count * MemoryLayout<SIMD2<UInt32>>.stride }

    init(lights: [GPULight]) {
        paths = [SIMD2<UInt32>](repeating: SIMD2(0, LightTree.notInTree), count: lights.count)
        leafOf = [Int32](repeating: -1, count: lights.count)
        var members = lights.indices.filter { LightTree.type(lights[$0]) != GPULight.sun }
        guard !members.isEmpty else { return }
        nodes.reserveCapacity(2 * members.count - 1)
        let centers = lights.map { LightTree.leafNode($0).center }
        _ = build(&members, 0..<members.count, parent: LightTree.notInTree, depth: 0, path: 0, lights: lights, centers: centers)
    }

    /// Refits the leaves of `moved` lights (bounds, cone and power) and of `scaled` ones (power alone), then their
    /// ancestors, from this frame's light records.
    mutating func refit(lights: [GPULight], moved: [Int], scaled: [Int]) {
        guard !nodes.isEmpty, !(moved.isEmpty && scaled.isEmpty) else { return }
        var full = Set<Int>(), power = Set<Int>()
        func mark(_ l: Int, moved: Bool) {
            let n = Int(leafOf[l])
            guard n >= 0 else { return }
            let leaf = LightTree.leafNode(lights[l]).node
            if moved {
                let link = nodes[n].link
                nodes[n] = leaf
                nodes[n].link = link
            } else {
                nodes[n].lo.w = leaf.lo.w
            }
            var p = nodes[n].link.z
            while p != LightTree.notInTree {
                guard moved ? full.insert(Int(p)).inserted : power.insert(Int(p)).inserted else { break }
                p = nodes[Int(p)].link.z
            }
        }
        for l in moved { mark(l, moved: true) }
        for l in scaled { mark(l, moved: false) }
        // Children come after their parent: deepest first.
        for n in full.union(power).sorted(by: >) {
            let a = nodes[Int(nodes[n].link.x)], b = nodes[Int(nodes[n].link.y)]
            if full.contains(n) {
                let link = nodes[n].link
                nodes[n] = LightTree.merge(a, b)
                nodes[n].link = link
            } else {
                nodes[n].lo.w = a.lo.w + b.lo.w
            }
        }
        version += 1
    }

    // MARK: - Building

    private mutating func build(_ items: inout [Int], _ range: Range<Int>, parent: UInt32, depth: Int, path: UInt32,
                                lights: [GPULight], centers: [SIMD3<Float>]) -> UInt32 {
        let index = nodes.count
        nodes.append(GPULightTreeNode())
        if range.count == 1 {
            let l = items[range.lowerBound]
            var node = LightTree.leafNode(lights[l]).node
            node.link = SIMD4(LightTree.leaf | UInt32(l), 0, parent, 0)
            nodes[index] = node
            paths[l] = SIMD2(path, UInt32(depth))
            leafOf[l] = Int32(index)
            return UInt32(index)
        }
        // Halve along the widest axis of the lights' centres.
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in range { lo = simd_min(lo, centers[items[i]]); hi = simd_max(hi, centers[items[i]]) }
        let extent = hi - lo
        let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : extent.y >= extent.z ? 1 : 2
        items[range].sort { centers[$0][axis] < centers[$1][axis] }
        let mid = range.lowerBound + range.count / 2
        let left = build(&items, range.lowerBound..<mid, parent: UInt32(index), depth: depth + 1, path: path,
                         lights: lights, centers: centers)
        let right = build(&items, mid..<range.upperBound, parent: UInt32(index), depth: depth + 1,
                          path: path | (1 << UInt32(depth)), lights: lights, centers: centers)
        nodes[index] = LightTree.merge(nodes[Int(left)], nodes[Int(right)])
        nodes[index].link = SIMD4(left, right, parent, 0)
        return UInt32(index)
    }

    private static func type(_ l: GPULight) -> Float { Float(Int(l.color.w) / 4) }

    /// A light's leaf: the box around it, its intensity luminance (as MegaLights' reach counts it) and its cone.
    private static func leafNode(_ l: GPULight) -> (node: GPULightTreeNode, center: SIMD3<Float>) {
        let lum = dot(SIMD3(l.color.x, l.color.y, l.color.z), SIMD3<Float>(0.2126, 0.7152, 0.0722))
        let c = SIMD3(l.positionRadius.x, l.positionRadius.y, l.positionRadius.z), r = l.positionRadius.w
        let axis = SIMD3(l.axis.x, l.axis.y, l.axis.z)
        var half = SIMD3<Float>(repeating: r), power = lum
        var cone = (axis: SIMD3<Float>(0, 0, 1), cosO: Float(-1), cosE: Float(0))   // every direction
        switch type(l) {
        case GPULight.spot:
            // Full strength inside the inner cone (params.y), fading to nothing at the outer one (params.x).
            let inner = acos(min(l.params.y, 1)), outer = acos(min(l.params.x, 1))
            cone = (normalize(axis), cos(inner), cos(max(outer - inner, 1e-4)))
        case GPULight.rect:
            let u = SIMD3(l.params.x, l.params.y, l.params.z), hw = length(u), hh = l.params.w
            let v = normalize(cross(axis, u)) * hh
            half = abs(u) + abs(v)
            power = lum * 4 * hw * hh
            cone = (normalize(axis), 1, 0)   // one-sided, cosine falloff
        case GPULight.tube:
            half = abs(axis) + SIMD3(repeating: r)
            power = lum * 4 / .pi
        case GPULight.mesh:
            let flat = l.params.z
            power = lum * ((1 - flat) * 0.25 + flat)
        default: break
        }
        let node = GPULightTreeNode(lo: SIMD4(c - half, max(power, 0)), hi: SIMD4(c + half, cone.cosO),
                                    axis: SIMD4(cone.axis, cone.cosE), link: .zero)
        return (node, c)
    }

    /// Two nodes as one: the boxes' union, the powers' sum, a cone around both cones (PBRT's DirectionCone union).
    private static func merge(_ a: GPULightTreeNode, _ b: GPULightTreeNode) -> GPULightTreeNode {
        func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
        var out = GPULightTreeNode()
        out.lo = SIMD4(simd_min(xyz(a.lo), xyz(b.lo)), a.lo.w + b.lo.w)
        let wa = xyz(a.axis), wb = xyz(b.axis)
        let ta = acos(max(min(a.hi.w, 1), -1)), tb = acos(max(min(b.hi.w, 1), -1))
        let td = acos(max(min(dot(wa, wb), 1), -1))
        var axis = wa, cosO: Float
        if min(td + tb, .pi) <= ta {
            cosO = a.hi.w
        } else if min(td + ta, .pi) <= tb {
            axis = wb
            cosO = b.hi.w
        } else {
            let to = (ta + td + tb) / 2
            let wr = cross(wa, wb)
            if to >= .pi || length_squared(wr) < 1e-12 {
                cosO = -1
            } else {
                axis = simd_act(simd_quatf(angle: to - ta, axis: normalize(wr)), wa)
                cosO = cos(to)
            }
        }
        out.hi = SIMD4(simd_max(xyz(a.hi), xyz(b.hi)), cosO)
        out.axis = SIMD4(axis, min(a.axis.w, b.axis.w))   // the wider θe
        return out
    }
}
