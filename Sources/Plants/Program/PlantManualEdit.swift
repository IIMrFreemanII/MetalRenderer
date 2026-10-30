import EngineCore
import Foundation
import simd

extension Growth {
    /// The manual edit stage's settings (Unreal's Manual Edit): one plant's points moved, turned and cut by hand, in the
    /// plant editor's view. A species has many plants, each of its own seed and points, so the node holds one of them, a
    /// hero: that age and variant grows from `seed` in every scene (SpeciesDef.plantSeed), and only a plant of that seed
    /// is edited. Point numbers are the grower's: an edit of the stages before it can renumber them (`grown`).
    ///
    /// The edits are by the tree's frames, so that what grows beyond a point goes with it: a point's internode is
    /// `moves[k]` longer (in the frame its turns put it in), and it and all beyond it turn by `turns[k]` about its parent.
    package struct ManualEdit: Codable, Equatable {
        package var age = Foliage.Age.mature.rawValue
        package var variant = 0
        package var seed: UInt64 = 0                // 0: no plant yet
        package var grown = 0                       // how many points the plant had when it was last edited
        package var points: [Int] = []
        package var moves: [SIMD3<Float>] = []      // by `points`
        package var turns: [SIMD4<Float>] = []      // by `points`: a quaternion, (x, y, z, w)
        package var removed: [Int] = []             // these points, and all beyond them, are gone

        package init() {}

        /// A point's edit: what it has, and `change` of it.
        fileprivate mutating func edit(_ point: Int, _ change: (inout SIMD3<Float>, inout simd_quatf) -> Void) {
            let k = points.firstIndex(of: point)
            var move = k.map { moves[$0] } ?? .zero
            var turn = k.map { simd_quatf(vector: turns[$0]) } ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            change(&move, &turn)
            if let k {
                moves[k] = move
                turns[k] = turn.vector
            } else {
                points.append(point)
                moves.append(move)
                turns.append(turn.vector)
            }
        }
    }
}

extension Growth.Plant {
    /// The edit's moves, turns and cuts on the plant. By point, how far what's on it is turned.
    @discardableResult
    mutating func edit(_ e: Growth.ManualEdit) -> [simd_quatf] {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var local = [Int: (move: SIMD3<Float>, turn: simd_quatf)]()
        for (k, point) in e.points.enumerated() where points.indices.contains(point) && e.moves.indices.contains(k) && e.turns.indices.contains(k) {
            local[point] = (e.moves[k], simd_normalize(simd_quatf(vector: e.turns[k])))
        }
        var turn = [simd_quatf](repeating: identity, count: points.count)
        // What no edit reaches stays as it was, to the bit.
        var touched = [Bool](repeating: false, count: points.count)
        var moved = points.map(\.position)
        var fromRoot = points.map(\.fromRoot)
        for i in points.indices.dropFirst() where !points[i].removed {
            let parent = Int(points[i].parent)
            // (A carved trunk's foot has nothing below it left: it stays.)
            guard !points[parent].removed else { continue }
            let edit = local[i]
            guard edit != nil || touched[parent] else { continue }
            touched[i] = true
            let q = turn[parent] * (edit?.turn ?? identity)
            turn[i] = q
            let now = q.act(points[i].position - points[parent].position + (edit?.move ?? .zero))
            moved[i] = moved[parent] + now
            let length = edit?.move == nil || edit?.move == .zero ? points[i].fromRoot - points[parent].fromRoot : simd_length(now)
            fromRoot[i] = fromRoot[parent] + length
            // Its frame as far as its internode turned, by the turns and by its own move.
            let was = q.act(points[i].direction), lateral = q.act(points[i].lateral)
            if let move = edit?.move, move != .zero, simd_length(now) > 1e-6 {
                let d = normalize(now)
                points[i].lateral = normalize(simd_quatf(from: was, to: d).act(lateral))
                points[i].direction = d
                points[i].segment = simd_length(now)
            } else {
                points[i].lateral = normalize(lateral)
                points[i].direction = normalize(was)
            }
        }
        for i in points.indices where touched[i] {
            points[i].position = moved[i]
            points[i].fromRoot = fromRoot[i]
        }
        cut(Set(e.removed.filter(points.indices.contains)))
        return turn
    }

    /// The points `gone`, and all beyond them; the first axis keeps its first internode. A branch cut is thinner, by the
    /// share of its points left, and so is all that's left on it (Unreal's: its nearest children only).
    private mutating func cut(_ gone: Set<Int>) {
        guard !gone.isEmpty else { return }
        var thin = [Float](repeating: 1, count: branches.count)
        for b in branches.indices where !branches[b].removed {
            let nodes = branches[b].points
            if branches[b].parent >= 0 {
                if points[Int(nodes[0])].removed {
                    remove(b)
                    continue
                }
                thin[b] = thin[Int(branches[b].parent)]
            }
            guard var at = nodes.indices.dropFirst().first(where: { gone.contains(Int(nodes[$0])) }) else { continue }
            if b == 0 { at = max(at, 2) }
            guard at < nodes.count else { continue }
            thin[b] *= Float(at) / Float(nodes.count)
            if at <= 1 {
                remove(b)
                continue
            }
            for q in nodes[at...] {
                points[Int(q)].removed = true
                points[Int(q)].bud = false
            }
            branches[b].points = Array(nodes[..<at])
            branches[b].growing = false
        }
        for b in branches.indices where !branches[b].removed && thin[b] != 1 {
            for q in branches[b].points.dropFirst(b == 0 ? 0 : 1) { points[Int(q)].radius *= thin[b] }
        }
    }
}

extension Foliage.SpeciesDef {
    /// The seed its plant of `age` and `variant` grows from, in a library of seed `base`: the one a Manual Edit holds it
    /// at, or its own.
    package func plantSeed(_ base: UInt64, _ age: Foliage.Age, _ variant: Int) -> UInt64 {
        if let graph {
            for node in graph.nodes where node.side == .plant {
                if case .manualEdit(let e) = node.settings, e.seed != 0, e.age == age.rawValue, e.variant == variant { return e.seed }
            }
        }
        return Foliage.seed(base, seedIndex, age.rawValue, variant)
    }
}

/// One hero plant under the plant editor's hand: as it comes into a Manual Edit node, and with the node's settings on it.
/// What the tools do to the settings; what's under a ray; what to draw. All in plant space (the workshop's plant stands
/// at the origin).
package struct PlantEditing {
    /// A point under the cursor: the branch it was found on, its place on that branch, its number.
    package struct Pick: Equatable {
        package var branch: Int
        package var index: Int
        package var point: Int
    }

    /// How a move's selection spreads from the point picked (Unreal's selection params).
    package struct Spread: Equatable {
        package enum Measure: String, CaseIterable { case neighbours, treeDistance, distance }
        package enum Falloff: String, CaseIterable { case linear, smooth, sphere, root, sharp, sine, constant }

        package var measure = Measure.treeDistance
        package var falloff = Falloff.smooth
        package var neighbours = 0                  // along the wood, for `neighbours`
        package var reach: Float = 1                // in metres, for the others
        package var carries = true                  // all beyond the point goes with it

        package init() {}

        /// Of a weight from 1 at the point to 0 at the reach.
        func shaped(_ w: Float) -> Float {
            switch falloff {
            case .linear: return w
            case .smooth: return w * w * (3 - 2 * w)
            case .sphere: return sqrt(max(1 - (w - 1) * (w - 1), 0))
            case .root: return sqrt(w)
            case .sharp: return w * w
            case .sine: return sin(w * .pi / 2)
            case .constant: return 1
            }
        }
    }

    let base: Growth.Plant
    private(set) var edited: Growth.Plant
    private var turn: [simd_quatf]
    private let children: [[Int32]]
    package private(set) var settings: Growth.ManualEdit

    init(base: Growth.Plant, settings: Growth.ManualEdit) {
        self.base = base
        self.settings = settings
        edited = base
        turn = edited.edit(settings)
        var children = [[Int32]](repeating: [], count: base.points.count)
        for (i, point) in base.points.enumerated() where point.parent >= 0 && !point.removed { children[Int(point.parent)].append(Int32(i)) }
        self.children = children
    }

    /// The plant at the graph's Manual Edit `node`. nil: it isn't there, or what comes into it can't run yet.
    package init?(graph: PlantGraph, node: Int32, species: Foliage.Species) {
        guard let n = graph.node(node), case .manualEdit(let e) = n.settings, let age = Foliage.Age(rawValue: e.age) else { return nil }
        var p = PlantContext(.plant(age: age, palette: [], bark: nil), species: species, seed: e.seed, probe: true)
        guard let growing = graph.growing(into: node, &p) else { return nil }
        self.init(base: growing.plant, settings: e)
    }

    /// The node's settings as they are now (an undo, say).
    package mutating func update(_ e: Growth.ManualEdit) {
        guard e != settings else { return }
        settings = e
        apply()
    }

    private mutating func apply() {
        edited = base
        turn = edited.edit(settings)
    }

    // MARK: - What's there

    package func position(_ point: Int) -> SIMD3<Float> { edited.points[point].position }

    /// Whether what was picked is still there.
    package func isThere(_ pick: Pick) -> Bool {
        guard edited.branches.indices.contains(pick.branch), !edited.branches[pick.branch].removed else { return false }
        let nodes = edited.branches[pick.branch].points
        return nodes.indices.contains(pick.index) && Int(nodes[pick.index]) == pick.point
    }

    /// The edits have been made on another plant than comes in now: their numbers may land on other branches.
    package var isStale: Bool { settings.grown != 0 && settings.grown != base.points.count }

    /// What's nearest along the ray, on the wood or within `tolerance` (in radians from the eye) of it.
    package func pick(origin: SIMD3<Float>, direction: SIMD3<Float>, tolerance: Float = 0.006) -> Pick? {
        var best: (pick: Pick, t: Float)?
        for (b, branch) in edited.branches.enumerated() where !branch.removed {
            let nodes = branch.points
            for j in nodes.indices.dropFirst() {
                let a = edited.points[Int(nodes[j - 1])], c = edited.points[Int(nodes[j])]
                let (s, t, miss) = PlantEditing.nearest(origin: origin, direction: direction, a.position, c.position)
                guard t > 0, miss <= max(tolerance * t, c.radius), t < best?.t ?? .infinity else { continue }
                let k = s < 0.5 ? j - 1 : j
                best = (Pick(branch: b, index: k, point: Int(nodes[k])), t)
            }
        }
        return best?.pick
    }

    /// Where along a to b (0...1) and along the ray they pass nearest, and how far apart.
    static func nearest(origin: SIMD3<Float>, direction: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (s: Float, t: Float, miss: Float) {
        let ab = b - a, w = a - origin
        let aa = dot(ab, ab), ad = dot(ab, direction), wa = dot(w, ab), wd = dot(w, direction)
        let denominator = aa - ad * ad
        let s = denominator > 1e-9 ? min(max((ad * wd - wa) / denominator, 0), 1) : 0
        let t = dot(a + ab * s - origin, direction)
        return (s, t, simd_length(a + ab * s - (origin + direction * t)))
    }

    /// By point, how much of a move at `pick` it takes.
    package func weights(_ pick: Pick, _ spread: Spread) -> [Float] {
        let points = edited.points
        var w = [Float](repeating: 0, count: points.count)
        func isFoot(_ i: Int) -> Bool { points[i].parent < 0 || points[Int(points[i].parent)].removed }
        switch spread.measure {
        case .distance:
            let at = points[pick.point].position, reach = max(spread.reach, 1e-3)
            for i in points.indices where !points[i].removed {
                let d = simd_distance(points[i].position, at)
                if d < reach { w[i] = spread.shaped(1 - d / reach) }
            }
        case .neighbours, .treeDistance:
            // Along the wood, both ways: a tree has one way to each point.
            let hops = spread.measure == .neighbours
            let reach = hops ? Float(spread.neighbours + 1) : max(spread.reach, 1e-3)
            var stack: [(point: Int, from: Int, d: Float)] = [(pick.point, -1, 0)]
            while let (i, from, d) = stack.popLast() {
                w[i] = spread.shaped(1 - d / reach)
                var next = children[i].map(Int.init).filter { !points[$0].removed }
                if !isFoot(i) { next.append(Int(points[i].parent)) }
                for j in next where j != from {
                    let step = hops ? 1 : simd_distance(points[i].position, points[j].position)
                    if d + step < reach { stack.append((j, i, d + step)) }
                }
            }
        }
        w[pick.point] = 1
        if spread.carries {
            var stack = children[pick.point].map(Int.init)
            while let i = stack.popLast() {
                guard !points[i].removed else { continue }
                w[i] = 1
                stack += children[i].map(Int.init)
            }
        }
        for i in points.indices where isFoot(i) { w[i] = 0 }
        return w
    }

    // MARK: - The tools

    /// Every point by its weight of `delta`: each internode takes what its point has more than its parent.
    package mutating func move(by delta: SIMD3<Float>, weights: [Float]) {
        let points = edited.points
        for i in points.indices.dropFirst() where !points[i].removed && !points[Int(points[i].parent)].removed {
            let step = weights[i] - weights[Int(points[i].parent)]
            guard step != 0 else { continue }
            let local = turn[i].inverse.act(delta * step)
            settings.edit(i) { move, _ in move += local }
        }
        settings.grown = base.points.count
        apply()
    }

    /// What a turn at `pick` turns: a branch's foot, that branch; anywhere else, all that's on the point.
    private func turned(by pick: Pick) -> [Int32] {
        let nodes = edited.branches[pick.branch].points
        return pick.index == 0 && nodes.count > 1 ? [nodes[1]] : children[pick.point].filter { !edited.points[Int($0)].removed }
    }

    /// Whether there's anything beyond `pick` to turn (a tip has nothing).
    package func canTurn(_ pick: Pick) -> Bool { !turned(by: pick).isEmpty }

    /// All beyond `pick` turned about it.
    package mutating func turn(_ pick: Pick, axis: SIMD3<Float>, angle: Float) {
        let on = turned(by: pick)
        guard !on.isEmpty, simd_length_squared(axis) > 1e-8 else { return }
        let frame = turn[pick.point], change = simd_quatf(angle: angle, axis: normalize(axis))
        for c in on {
            settings.edit(Int(c)) { _, t in t = simd_normalize(frame.inverse * change * frame * t) }
        }
        settings.grown = base.points.count
        apply()
    }

    /// `pick`'s branch cut: all of it, or (`trim`) beyond the point (a tip: the tip). False: it's the first axis's foot,
    /// which stays.
    @discardableResult
    package mutating func remove(_ pick: Pick, trim: Bool) -> Bool {
        let nodes = edited.branches[pick.branch].points
        var at = 1
        if trim { at = max(pick.index < nodes.count - 1 ? pick.index + 1 : pick.index, 1) }
        guard !(pick.branch == 0 && at <= 1), nodes.indices.contains(at) else { return false }
        settings.removed.append(Int(nodes[at]))
        settings.grown = base.points.count
        apply()
        return true
    }
    // MARK: - What to draw

    /// A line along each internode of `branch` from its place `from`.
    package func lines(branch: Int, from: Int = 0) -> [(a: SIMD3<Float>, b: SIMD3<Float>)] {
        let nodes = edited.branches[branch].points
        return nodes.indices.dropFirst(max(from, 0) + 1).map { (position(Int(nodes[$0 - 1])), position(Int(nodes[$0]))) }
    }

    /// An internode's line for each point with a weight.
    package func lines(weights: [Float]) -> [(a: SIMD3<Float>, b: SIMD3<Float>, weight: Float)] {
        edited.points.indices.dropFirst().compactMap { i in
            let point = edited.points[i], parent = Int(point.parent)
            guard weights[i] > 0, !point.removed, !edited.points[parent].removed else { return nil }
            return (edited.points[parent].position, point.position, weights[i])
        }
    }
}
