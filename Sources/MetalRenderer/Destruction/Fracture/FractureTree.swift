import EngineCore
import Foundation
import simd

/// An object fractured ahead of time (UE Chaos's geometry collection): a tree of convex cells, the object itself at
/// its root, each node's children the pieces it breaks into, level by level (FracturePatterns.swift); and the welds
/// between pieces that share a face (Chaos's connection graph), at any level, between any two nodes of which neither
/// holds the other. The physics makes every node a body (PhysicsWorld.addFractured): only the root moves at first;
/// a node that breaks hands over to its children, which its welds hold to their neighbours until those break too.
///
/// Built once (plain Swift: a scene's build, the Fracture Editor's preview); the cells are in the object's shape space.
package struct FractureTree {
    package struct Node {
        package var cell: ConvexCell
        package var parent: Int
        /// Its children: contiguous (the tree is built a level at a time).
        package var children: Range<Int>
        package var level: Int
        /// How much of the cell is the object (all of it for a convex object; a share for a statue's box's cells).
        package var volume: Float
        package var isLeaf: Bool { children.isEmpty }
    }

    package struct Weld {
        package var a: Int
        package var b: Int
        /// The shared faces' area inside the object (m^2), their middle and normal (out of a).
        package var area: Float
        package var centre: SIMD3<Float>
        package var normal: SIMD3<Float>
    }

    let recipe: FractureRecipe
    package private(set) var nodes: [Node] = []
    private(set) var welds: [Weld] = []
    /// The object's own shape is the cell (a box): no piece is part outside it.
    let convex: Bool

    var leaves: Int { nodes.filter(\.isLeaf).count }
    var levels: Int { (nodes.map(\.level).max() ?? 0) + 1 }

    /// The object `cell` (its box, shape space) fractured by `recipe`. `inside`: the object's distance when it isn't
    /// the box (a pillar's cylinder, a statue's grid): cells with little of it inside are dropped, and welds count only
    /// the shared faces' part inside it.
    package init(recipe: FractureRecipe, cell: ConvexCell, inside: ((SIMD3<Float>) -> Float)? = nil) {
        self.recipe = recipe
        convex = inside == nil
        var random = SplitMix(seed: recipe.seed &* 0x9E37_79B9 &+ 17)
        let rootVolume = inside.map { FractureTree.insideVolume(cell, $0, random: &random) } ?? cell.volume
        nodes = [Node(cell: cell, parent: -1, children: 0..<0, level: 0, volume: rootVolume)]
        var level = [0]
        for depth in 0..<min(recipe.counts.count, FractureRecipe.maxLevels) {
            var next: [Int] = []
            for i in level {
                var pieces = FracturePatterns.split(nodes[i].cell, recipe: recipe, level: depth, random: &random, inside: inside)
                var volumes = pieces.map(\.volume)
                if let inside {
                    volumes = pieces.map { FractureTree.insideVolume($0, inside, random: &random) }
                    let keep = pieces.indices.filter { volumes[$0] > 2e-3 * nodes[i].volume && volumes[$0] > 0.04 * pieces[$0].volume }
                    pieces = keep.map { pieces[$0] }
                    volumes = keep.map { volumes[$0] }
                }
                guard pieces.count >= 2 else { continue }
                let first = nodes.count
                for (p, v) in zip(pieces, volumes) {
                    nodes.append(Node(cell: p, parent: i, children: 0..<0, level: depth + 1, volume: v))
                }
                nodes[i].children = first..<nodes.count
                next += Array(first..<nodes.count)
            }
            level = next
            if level.isEmpty { break }
        }
        welds = FractureTree.welds(nodes, inside: inside)
    }

    /// Whether node `a` holds node `b` (is it or one of its ancestors).
    func holds(_ a: Int, _ b: Int) -> Bool {
        var k = b
        while k >= 0 {
            if k == a { return true }
            k = nodes[k].parent
        }
        return false
    }

    /// The share of `cell` inside the object, by jittered samples, times its volume.
    private static func insideVolume(_ cell: ConvexCell, _ inside: (SIMD3<Float>) -> Float, random: inout SplitMix) -> Float {
        let box = cell.bounds, e = box.hi - box.lo
        let n = 7
        var hits = 0, total = 0
        for z in 0..<n { for y in 0..<n { for x in 0..<n {
            let p = box.lo + (SIMD3(Float(x), Float(y), Float(z)) + SIMD3(random.float(), random.float(), random.float())) / Float(n) * e
            guard cell.contains(p) else { continue }
            total += 1
            if inside(p) <= 0 { hits += 1 }
        } } }
        return total == 0 ? 0 : cell.volume * Float(hits) / Float(total)
    }

    /// Every pair of nodes neither of which holds the other that share a face (inside the object).
    private static func welds(_ nodes: [Node], inside: ((SIMD3<Float>) -> Float)?) -> [Weld] {
        let bounds = nodes.map(\.cell.bounds)
        func holds(_ a: Int, _ b: Int) -> Bool {
            var k = b
            while k >= 0 { if k == a { return true }; k = nodes[k].parent }
            return false
        }
        var found = [[Weld]](repeating: [], count: nodes.count)
        found.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: nodes.count) { a in
                // (The root touches nothing it doesn't hold.)
                guard a > 0 else { return }
                let pad = nodes[a].cell.size * 1e-3
                var random = SplitMix(seed: UInt64(a) &* 7919 &+ 1)
                for b in (a + 1)..<nodes.count {
                    let x = bounds[a], y = bounds[b]
                    guard x.lo.x <= y.hi.x + pad, y.lo.x <= x.hi.x + pad, x.lo.y <= y.hi.y + pad, y.lo.y <= x.hi.y + pad,
                          x.lo.z <= y.hi.z + pad, y.lo.z <= x.hi.z + pad, !holds(a, b), !holds(b, a) else { continue }
                    let (normal, polygons) = nodes[a].cell.shared(with: nodes[b].cell)
                    guard !polygons.isEmpty else { continue }
                    var area: Float = 0, centre = SIMD3<Float>()
                    for poly in polygons {
                        var (pa, pc) = ConvexCell.polygonArea(poly)
                        if let inside {
                            // Only what of the face is inside the object holds: by samples over the polygon's fan.
                            var hits = 0, sum = SIMD3<Float>()
                            let samples = 24
                            for _ in 0..<samples {
                                let t = 1 + Int(random.next() % UInt64(poly.count - 2))
                                var u = random.float(), v = random.float()
                                if u + v > 1 { u = 1 - u; v = 1 - v }
                                let p = poly[0] + (poly[t] - poly[0]) * u + (poly[t + 1] - poly[0]) * v
                                if inside(p) <= 0 { hits += 1; sum += p }
                            }
                            pa *= Float(hits) / Float(samples)
                            if hits > 0 { pc = sum / Float(hits) }
                        }
                        guard pa > 0 else { continue }
                        centre = (centre * area + pc * pa) / (area + pa)
                        area += pa
                    }
                    if area > 0 { out[a].append(Weld(a: a, b: b, area: area, centre: centre, normal: normal)) }
                }
            }
        }
        return found.flatMap { $0 }
    }
}
