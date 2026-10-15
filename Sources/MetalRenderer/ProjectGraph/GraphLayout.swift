import Foundation
import simd

/// What the Project Graph's layouts place: a tree (the shown part of the project graph, ProjectGraph.Visible), each
/// node's radius, and the links across it (references) that the force layout pulls together too.
struct LayoutTree {
    var parent: [Int]
    var children: [[Int]]
    var radius: [Float]
    var links: [(a: Int, b: Int)] = []

    var count: Int { parent.count }

    init(parent: [Int], radius: [Float], links: [(a: Int, b: Int)] = []) {
        self.parent = parent
        self.radius = radius
        self.links = links
        children = [[Int]](repeating: [], count: parent.count)
        for (k, p) in parent.enumerated() where p >= 0 { children[p].append(k) }
    }

    /// A node's size from the things under it: 7 points alone, growing with the log of its count.
    static func radius(count: Int) -> Float { 7 + 3.2 * log2(Float(max(count, 1))) }

    init(_ v: ProjectGraph.Visible, graph: ProjectGraph) {
        self.init(parent: v.nodes.map(\.parent),
                  radius: v.nodes.map { $0.member != nil ? 6 : LayoutTree.radius(count: graph.nodes[$0.node].count) },
                  links: v.edges.map { ($0.a, $0.b) })
    }

    /// The nodes from the root down, each after its parent.
    var topDown: [Int] {
        var out = (0..<count).filter { parent[$0] < 0 }, i = 0
        while i < out.count { out += children[out[i]]; i += 1 }
        return out
    }

    /// Each node's depth.
    var depths: [Int] {
        var d = [Int](repeating: 0, count: count)
        for n in topDown where parent[n] >= 0 { d[n] = d[parent[n]] + 1 }
        return d
    }

    /// Each node's leaves (itself, for a leaf).
    var leafCounts: [Int] {
        var leaves = [Int](repeating: 0, count: count)
        for n in topDown.reversed() {
            if children[n].isEmpty { leaves[n] = 1 }
            if parent[n] >= 0 { leaves[parent[n]] += leaves[n] }
        }
        return leaves
    }
}

enum GraphLayout: String, CaseIterable, Identifiable {
    case force, radial, tree, cone

    var id: String { rawValue }
    var title: String {
        switch self {
        case .force: return "Force"
        case .radial: return "Radial"
        case .tree: return "Tree"
        case .cone: return "Cone 3D"
        }
    }
}

// MARK: - Radial

/// The root in the middle, each depth a ring further out; a node's share of its parent's angle is its share of the leaves.
enum RadialLayout {
    static func place(_ t: LayoutTree, ring: Float = 140) -> [SIMD2<Float>] {
        var pos = [SIMD2<Float>](repeating: .zero, count: t.count)
        guard t.count > 0 else { return pos }
        let leaves = t.leafCounts, depths = t.depths
        var span = [(lo: Float, hi: Float)](repeating: (0, 2 * .pi), count: t.count)
        // A ring's radius grows enough for its nodes to fit: at least `ring` a step, more where the ring is crowded.
        let maxDepth = depths.max() ?? 0
        var radii = [Float](repeating: 0, count: maxDepth + 1)
        for d in stride(from: 1, through: maxDepth, by: 1) {
            let need = (0..<t.count).filter { depths[$0] == d }.reduce(Float(0)) { $0 + 2 * t.radius[$1] + 10 }
            radii[d] = max(radii[d - 1] + ring, need / (2 * .pi))
        }
        for n in t.topDown {
            let (lo, hi) = span[n]
            if t.parent[n] >= 0 {
                let a = (lo + hi) / 2, r = radii[depths[n]]
                pos[n] = SIMD2(cos(a), sin(a)) * r
            }
            var at = lo
            let total = Float(max(leaves[n], 1))
            for c in t.children[n] {
                let share = (hi - lo) * Float(leaves[c]) / total
                span[c] = (at, at + share)
                at += share
            }
        }
        return pos
    }
}

// MARK: - Tidy tree

/// Top-down: each depth a row, a parent centred over its children, subtrees as close as their outlines allow
/// (Reingold–Tilford: each subtree's left and right edges per depth, the next pushed clear of the ones before it).
enum TidyTreeLayout {
    static func place(_ t: LayoutTree, row: Float = 110, gap: Float = 14) -> [SIMD2<Float>] {
        var relative = [Float](repeating: 0, count: t.count)    // x from the parent's
        var contour = [(left: [Float], right: [Float])](repeating: ([], []), count: t.count)
        for n in t.topDown.reversed() {
            let r = t.radius[n]
            guard !t.children[n].isEmpty else { contour[n] = ([-r], [r]); continue }
            var left: [Float] = [], right: [Float] = []
            var xs: [Float] = []
            for c in t.children[n] {
                let (cl, cr) = contour[c]
                var x: Float = 0
                if !xs.isEmpty {
                    x = -Float.infinity
                    for d in 0..<min(right.count, cl.count) { x = max(x, right[d] - cl[d] + gap) }
                    if x == -.infinity { x = 0 }
                }
                xs.append(x)
                for d in 0..<cl.count {
                    if d < left.count { left[d] = min(left[d], cl[d] + x); right[d] = max(right[d], cr[d] + x) }
                    else { left.append(cl[d] + x); right.append(cr[d] + x) }
                }
            }
            let centre = (xs.first! + xs.last!) / 2
            for (c, x) in zip(t.children[n], xs) { relative[c] = x - centre }
            contour[n] = ([-r] + left.map { $0 - centre }, [r] + right.map { $0 - centre })
        }
        var pos = [SIMD2<Float>](repeating: .zero, count: t.count)
        let depths = t.depths
        for n in t.topDown {
            let x = t.parent[n] >= 0 ? pos[t.parent[n]].x + relative[n] : 0
            pos[n] = SIMD2(x, Float(depths[n]) * row)
        }
        // Roots side by side (there is one: the project).
        return pos
    }
}

// MARK: - Cone tree (3D)

/// A parent above a ring of its children (Robertson's cone tree): a ring's radius is what its children's own cones
/// need side by side, so no two cones meet; each depth a level lower.
enum ConeTreeLayout {
    static func place(_ t: LayoutTree, level: Float = 120, gap: Float = 12) -> [SIMD3<Float>] {
        var footprint = t.radius        // the radius a node's cone takes, seen from above
        var ring = [Float](repeating: 0, count: t.count)
        for n in t.topDown.reversed() where !t.children[n].isEmpty {
            let cs = t.children[n]
            if cs.count == 1 {
                ring[n] = 0
                footprint[n] = max(t.radius[n], footprint[cs[0]])
                continue
            }
            let around = cs.reduce(Float(0)) { $0 + 2 * footprint[$1] + gap }
            ring[n] = max(around / (2 * .pi), cs.map { footprint[$0] }.max()! + gap / 2)
            footprint[n] = ring[n] + cs.map { footprint[$0] }.max()!
        }
        var pos = [SIMD3<Float>](repeating: .zero, count: t.count)
        for n in t.topDown {
            let cs = t.children[n]
            guard !cs.isEmpty else { continue }
            let around = cs.reduce(Float(0)) { $0 + 2 * footprint[$1] + gap }
            var a: Float = 0
            for c in cs {
                let share = (2 * footprint[c] + gap) / around * 2 * .pi
                let angle = a + share / 2
                a += share
                pos[c] = pos[n] + SIMD3(cos(angle) * ring[n], -level, sin(angle) * ring[n])
            }
        }
        return pos
    }
}

// MARK: - Force-directed

/// Nodes push each other apart (Barnes–Hut: far groups as one), links pull their ends together (a child to its parent
/// harder than a reference), everything drifts to the middle; it cools as it settles (d3-force's scheme). Starts from
/// where it is given (the radial layout's places), so it is the same every time; pinned nodes stay put.
struct ForceLayout {
    var positions: [SIMD2<Float>]
    private var velocity: [SIMD2<Float>]
    let tree: LayoutTree
    var pinned: [Int: SIMD2<Float>] = [:]
    /// How warm it is: 1 to start, stops below `alphaMin`.
    private(set) var alpha: Float = 1
    let alphaMin: Float = 0.001
    let alphaDecay: Float = 1 - pow(0.001, 1 / 300)
    var velocityDecay: Float = 0.4
    var charge: Float = -140
    var childDistance: Float = 70
    var linkDistance: Float = 140
    private var links: [(a: Int, b: Int, strength: Float, distance: Float)] = []

    init(_ tree: LayoutTree, start: [SIMD2<Float>]) {
        self.tree = tree
        positions = start
        velocity = [SIMD2<Float>](repeating: .zero, count: tree.count)
        var degree = [Int](repeating: 0, count: tree.count)
        for (k, p) in tree.parent.enumerated() where p >= 0 { degree[k] += 1; degree[p] += 1 }
        for l in tree.links { degree[l.a] += 1; degree[l.b] += 1 }
        for (k, p) in tree.parent.enumerated() where p >= 0 {
            links.append((p, k, 1 / Float(min(degree[k], degree[p])), childDistance + tree.radius[k] + tree.radius[p]))
        }
        for l in tree.links where l.a != l.b {
            links.append((l.a, l.b, 0.3 / Float(min(degree[l.a], degree[l.b])), linkDistance + tree.radius[l.a] + tree.radius[l.b]))
        }
    }

    var isSettled: Bool { alpha < alphaMin }

    /// Warms it again (after a drag, or a node opened).
    mutating func reheat(_ to: Float = 0.6) { alpha = max(alpha, to) }

    /// One tick; false once it has settled.
    @discardableResult
    mutating func step() -> Bool {
        guard !isSettled, tree.count > 0 else { return false }
        alpha += (0 - alpha) * alphaDecay
        // Links.
        for l in links {
            var d = positions[l.b] + velocity[l.b] - positions[l.a] - velocity[l.a]
            if d == .zero { d = SIMD2(1e-3, 0) }
            let len = length(d)
            let pull = (len - l.distance) / len * alpha * l.strength
            let share = Float(1) / 2
            velocity[l.b] -= d * pull * share
            velocity[l.a] += d * pull * share
        }
        // Repulsion.
        let quad = QuadTree(positions, mass: tree.radius.map { $0 / 7 })
        for i in positions.indices {
            velocity[i] += quad.force(on: i, at: positions[i], strength: charge * alpha)
        }
        // To the middle, gently.
        for i in positions.indices { velocity[i] -= positions[i] * 0.002 * alpha }
        for i in positions.indices {
            if let p = pinned[i] { positions[i] = p; velocity[i] = .zero; continue }
            velocity[i] *= 1 - velocityDecay
            positions[i] += velocity[i]
        }
        return true
    }

    /// The sum of the links' stretch, squared: what settling lowers (tests).
    var linkEnergy: Float {
        links.reduce(0) { e, l in let s = length(positions[l.b] - positions[l.a]) - l.distance; return e + s * s * l.strength }
    }
}

/// Barnes–Hut's quadtree: each cell's total mass and centre of mass; a cell far enough (its size over its distance below
/// theta) pushes as one.
private struct QuadTree {
    private struct Cell {
        var lo: SIMD2<Float>, size: Float
        var mass: Float = 0
        var centre = SIMD2<Float>()
        var child = -1          // the first of 4, or -1: a leaf
        var body = -1           // a leaf's one body (-1: empty, -2: several at one point)
    }
    private var cells: [Cell] = []
    private let positions: [SIMD2<Float>]
    private let mass: [Float]
    let theta2: Float = 0.81

    init(_ positions: [SIMD2<Float>], mass: [Float]) {
        self.positions = positions
        self.mass = mass
        guard !positions.isEmpty else { return }
        var lo = positions[0], hi = positions[0]
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let size = max(hi.x - lo.x, hi.y - lo.y) + 1
        cells.append(Cell(lo: lo, size: size))
        for i in positions.indices { insert(i, into: 0, depth: 0) }
        accumulate(0)
    }

    private func quadrant(_ c: Cell, _ p: SIMD2<Float>) -> Int {
        let mid = c.lo + c.size / 2
        return (p.x >= mid.x ? 1 : 0) + (p.y >= mid.y ? 2 : 0)
    }

    private mutating func split(_ c: Int) {
        let half = cells[c].size / 2, lo = cells[c].lo
        cells[c].child = cells.count
        for q in 0..<4 { cells.append(Cell(lo: lo + SIMD2(q & 1 == 0 ? 0 : half, q & 2 == 0 ? 0 : half), size: half)) }
    }

    private mutating func insert(_ i: Int, into c: Int, depth: Int) {
        if cells[c].child >= 0 {
            insert(i, into: cells[c].child + quadrant(cells[c], positions[i]), depth: depth + 1)
            return
        }
        if cells[c].body == -1 { cells[c].body = i; return }
        if depth > 24 { cells[c].body = -2; extra.append((c, i)); return }   // (bodies at one point)
        let old = cells[c].body
        cells[c].body = -1
        split(c)
        if old >= 0 { insert(old, into: c, depth: depth) }
        insert(i, into: c, depth: depth)
    }
    private var extra: [(cell: Int, body: Int)] = []

    @discardableResult
    private mutating func accumulate(_ c: Int) -> (Float, SIMD2<Float>) {
        var m: Float = 0, sum = SIMD2<Float>()
        if cells[c].child >= 0 {
            for q in 0..<4 { let (cm, cc) = accumulate(cells[c].child + q); m += cm; sum += cc * cm }
        } else if cells[c].body >= 0 {
            m = mass[cells[c].body]; sum = positions[cells[c].body] * m
        }
        for e in extra where e.cell == c { m += mass[e.body]; sum += positions[e.body] * mass[e.body] }
        cells[c].mass = m
        cells[c].centre = m > 0 ? sum / m : cells[c].lo + cells[c].size / 2
        return (m, cells[c].centre)
    }

    /// The push on body `i` at `p` (`strength` < 0 pushes apart).
    func force(on i: Int, at p: SIMD2<Float>, strength: Float) -> SIMD2<Float> {
        guard !cells.isEmpty else { return .zero }
        var f = SIMD2<Float>(), stack = [0]
        while let c = stack.popLast() {
            let cell = cells[c]
            guard cell.mass > 0 else { continue }
            var d = cell.centre - p
            var l2 = dot(d, d)
            let far = cell.size * cell.size < theta2 * l2
            if cell.child >= 0 && !far { for q in 0..<4 { stack.append(cell.child + q) }; continue }
            if cell.child < 0 && cell.body == i && cell.mass == mass[i] { continue }
            if l2 < 1 {
                // On top of each other: apart in a direction of their numbers.
                d = SIMD2(Float((i * 7919) % 13) - 6, Float((i * 104_729) % 11) - 5) * 0.1
                l2 = max(dot(d, d), 1e-2)
            }
            let m = cell.child < 0 && cell.body == i ? cell.mass - mass[i] : cell.mass
            f += d * (strength * m / max(l2, 25))
        }
        return f
    }
}
