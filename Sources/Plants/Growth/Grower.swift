import EngineCore
import Foundation
import simd

/// Bud-based growth, in the manner of Unreal's Procedural Vegetation Editor: a plant is grown cycle by cycle from a
/// seed, not drawn level by level. Every point of the skeleton is a bud. Each cycle:
/// * the light each bud gets is measured (LightField: the shadow the plant casts on itself);
/// * branches that stay in the shade die and are shed;
/// * each branch's tip may grow one internode, by a chance that falls as the plant nears its target height (the
///   apical ramp), toward the light and the sky as its shoot says; the bud it leaves behind is a dormant axillary bud;
/// * each dormant bud may sprout a branch, by a chance that rises with height (the axillary ramp), unless the auxin
///   of the growth just above it keeps it dormant (apical dominance), it is too dark, or its generation is the last;
/// * everything below new growth thickens (a pipe model: a point's radius is how many cycles grew beyond it), loses
///   auxin and gains ethylene (old wood: the twigs and leaves go where ethylene is low);
/// * branches sag under their load as beams (gravity), thinner and longer ones more.
///
/// The result is a `Foliage.Skeleton`: one stem per branch, its level its generation (0 the trunk). Everything is a
/// pure function of the parameters and the seed.
package enum Growth {
    /// How one kind of axis grows: the trunk's, or (Params.branch) every branch's.
    package struct Shoot: Codable, Equatable {
        package var segment: Float = 0.3            // an internode's length (m)
        package var apicalGrowth: Float = 1         // the tip's growth chance, times the ramp
        package var axillaryGrowth: Float = 1       // a dormant bud's (below 1, buds where the ramp is low never sprout)
        /// By the bud's length from the foot over the target height: the chance a tip grows (falls to 0: the plant
        /// stops at its height), and that a bud sprouts (rises: branches higher up).
        package var apicalRamp: Foliage.Curve = .linear(1, 0)
        package var axillaryRamp: Foliage.Curve = .linear(0.2, 1)
        package var phyllotaxis = Foliage.Phyllotaxis.spiral
        package var axilAngle: Float = 0.8          // a new branch from its parent's axis (rad)
        package var randomAngle: Float = 0.12       // each internode turns at random by up to this (rad)
        package var flatten: Float = 0              // a new branch's pull toward the horizontal
        package var phototropism: Float = 0.2       // each internode's turn toward the light
        package var gravitropism: Float = 0         // each internode's turn toward the sky (negative: toward the ground)
        package var lengthScale: Float = 1          // a branch's internodes, of `segment`
        /// A new branch from this axis turns this far toward the light as it leaves (Unreal's axillary phototropism:
        /// a tree's first branches climb toward the open sky).
        package var sproutLight: Float? = nil
        /// A bud on this axis sprouts only in this much light (nil: Light.requirement). Unreal's trunk asks nearly open
        /// sky of its buds, its branches none.
        package var requirement: Float? = nil

        package init() {}
    }

    package struct Light: Codable, Equatable {
        package var requirement: Float = 0.12       // a bud below this grows nothing
        package var lengthImpact: Float = 0.5       // shaded internodes are shorter by this share of the shade
        package var shadow: Float = 3               // how much shadow is darkness
        package var leafDensity: Float = 2          // young wood's leaves cast this many times a bare point's shadow

        package init() {}
    }

    package struct Senescence: Codable, Equatable {
        package var threshold: Float = 0.25         // a branch whose mean light stays below this...
        package var cycles = 3                      // ...for more cycles than this is shed
        package var fromGeneration = 2              // the trunk and the first branches are never shed

        package init() {}
    }

    /// Short side shoots on the last generation's nodes (what Unreal's sample tree gets from growing its grafted crown a
    /// few cycles more): one at each node from `fromNode` on, alternate, `angle` from the branch, that bear the twigs
    /// that fill the crown.
    package struct Spurs: Codable, Equatable {
        package var length: Float = 0.25
        package var angle: Float = 0.45             // from the branch (rad)
        package var fromNode = 3                    // a branch's first nodes stay bare
        package var fromGeneration: Int? = nil      // nil: the last generation's branches only

        package init() {}
    }

    /// Small shoots set on the outer branches once the plant is grown (Unreal's graft distributor in its parametric
    /// mode, a three-cycle seedling as the graft): `perBranch` along each branch of `fromGeneration` on, where the
    /// plant's gradient (a point's length from the root over the longest) is past `from`. Toward the inside they are
    /// large and lie along their branch, toward the tips small and square to it; each turns 135° round the branch from
    /// the last. Their wood is new, so they carry twigs deep in the crown.
    package struct Grafts: Codable, Equatable {
        package var perBranch = 3
        package var from: Float = 0.51
        package var fromGeneration = 3
        package var segments = 3
        package var length: Float = 0.25            // an internode, at scale 1
        package var scale: SIMD2<Float> = [2, 0.2]  // inside, at the tips
        package var angle: SIMD2<Float> = [0.17, 1.39]  // from the branch (rad), inside, at the tips

        package init() {}
    }

    package struct Bifurcation: Codable, Equatable {
        package var chance: Float = 0.15            // a ripe tip's chance to fork, each cycle
        package var angle: Float = 0.45             // each fork from the old axis (rad)
        package var count = 2
        package var cycles = 3                      // a tip ripens this many cycles after it last forked

        package init() {}
    }

    /// A younger plant: this share of the mature one's cycles, grown toward this share of its height.
    package struct AgeShare: Codable, Equatable {
        package var cycles: Float
        package var height: Float

        package init(cycles: Float, height: Float) {
            self.cycles = cycles
            self.height = height
        }
    }

    package struct Params: Codable, Equatable {
        package var cycles = 32
        package var targetHeight: Float = 12        // the length from the foot at which the apical ramp reaches its end
        package var maxGeneration = 4               // 1: the trunk alone
        package var seedRadius: Float = 0.004
        package var radiusGrowth: Float = 0.006     // per cycle, below new growth
        package var apicalDominance: Float = 0.6    // a bud whose auxin is above 1 - this stays dormant
        package var auxinFalloff: Float = 0.25      // per cycle, below new growth
        package var ethyleneBuildup: Float = 0.12   // per cycle, below new growth
        package var gravity: Float = 0              // the sag of the branches as beams
        package var trunk = Shoot()
        package var branch: Shoot? = nil            // nil: the branches grow as the trunk
        package var light = Light()
        package var senescence: Senescence? = Senescence()
        package var bifurcation: Bifurcation? = nil
        package var spurs: Spurs? = nil
        package var grafts: Grafts? = nil
        /// The foot of the trunk cut off, this share of its length, and the plant lowered onto the cut (Unreal's Carve
        /// from the bottom): a shorter bole under the same crown.
        package var carve: Float? = nil
        /// The first nodes of every axis never sprout (Unreal's radical auxin, halved at each node of an axis).
        package var bareNodes: Int? = nil
        package var wood = Wood()
        package var stems = 1                       // from the seed (a bush's several, a fern's fronds)
        package var stemSpread: Float = 0.3         // ...each leaning out from the axis this far (rad), round it
        package var up: SIMD3<Float> = [0, 1, 0]    // the sky
        package var axis: SIMD3<Float>? = nil       // the way the seed grows (nil: up; a twig grows along +Y, +Z its sky)
        /// The younger ages: shares of the mature plant's cycles and height (Growth.aged).
        package var young = AgeShare(cycles: 0.6, height: 0.7)
        package var sapling = AgeShare(cycles: 0.32, height: 0.4)

        package init() {}

        func shoot(_ generation: Int) -> Shoot { generation <= 1 ? trunk : branch ?? trunk }
    }

    // MARK: - The simulation

    struct Point {
        var position: SIMD3<Float>
        var direction: SIMD3<Float>                 // of the internode that ends here (unit)
        var lateral: SIMD3<Float>                   // where its next axillary bud faces, across `direction` (unit)
        var parent: Int32                           // -1: the seed
        var branch: Int32
        var segment: Float                          // the internode's length
        var radius: Float
        var fromRoot: Float                         // length along the plant from its foot
        var auxin: Float = 1
        var ethylene: Float = 0
        var light: Float = 1
        var lightDirection: SIMD3<Float>
        var bud = false                             // a dormant axillary bud waits here
        var removed = false
        var sagged: Float = 0                       // how far gravity has turned its internode so far (rad)
    }

    struct Branch {
        var points: [Int32]
        var generation: Int
        var parent: Int32                           // branch, -1 the trunk
        var growing = true
        var shaded = 0
        var ripe = 0                                // cycles since it last forked
        var removed = false
    }

    struct Plant {
        let p: Params
        var points: [Point] = []
        var branches: [Branch] = []
        var rng: SplitMix64
        var field: LightField
        let noiseSeed: UInt32

        init(_ p: Params, seed: UInt64) {
            self.p = p
            rng = SplitMix64(seed: seed)
            noiseSeed = UInt32(truncatingIfNeeded: seed ^ (seed >> 29))
            field = LightField(height: p.targetHeight, cell: max(p.trunk.segment * 1.25, p.targetHeight / 48))
            let up = normalize(p.up), axis = normalize(p.axis ?? p.up)
            let lateral = Foliage.perpendicular(axis, up: up)
            // The seed and its first internode.
            points.append(Point(position: .zero, direction: axis, lateral: lateral, parent: -1, branch: 0, segment: 0,
                                radius: p.seedRadius, fromRoot: 0, lightDirection: up))
            branches.append(Branch(points: [0], generation: 1, parent: -1))
            if p.stems <= 1 {
                add(to: 0, from: 0, direction: axis, length: p.trunk.segment)
            } else {
                // Several stems from the seed, leaning out round the axis (each its own first-generation axis).
                let turn = rng.range(0, 2 * .pi)
                for k in 0..<p.stems {
                    if k > 0 { branches.append(Branch(points: [0], generation: 1, parent: -1)) }
                    let around = turn + Float(k) * 2 * .pi / Float(p.stems) + rng.range(-0.3, 0.3)
                    let side = simd_quatf(angle: around, axis: axis).act(lateral)
                    let lean = p.stemSpread * rng.range(0.7, 1.3)
                    let d = normalize(axis * cos(lean) + side * sin(lean))
                    let first = add(to: k, from: 0, direction: d, length: p.trunk.segment)
                    points[first].lateral = side
                }
            }
        }

        /// A new point at the end of `branch`, `length` along `direction` from point `from`.
        @discardableResult
        mutating func add(to branch: Int, from: Int, direction: SIMD3<Float>, length: Float) -> Int {
            let base = points[from]
            var lateral = base.lateral - direction * dot(base.lateral, direction)
            lateral = length_squared(lateral) < 1e-6 ? Foliage.perpendicular(direction, up: p.up) : normalize(lateral)
            points.append(Point(position: base.position + direction * length, direction: direction, lateral: lateral,
                                parent: Int32(from), branch: Int32(branch), segment: length, radius: p.seedRadius,
                                fromRoot: base.fromRoot + length, lightDirection: base.lightDirection))
            branches[branch].points.append(Int32(points.count - 1))
            return points.count - 1
        }

        /// The turn between successive axillary buds about an axis, and how many sprout at a node.
        func phyllotaxy(_ s: Shoot) -> (turn: Float, count: Int) {
            switch s.phyllotaxis {
            case .spiral: return (Foliage.goldenAngle, 1)
            case .distichous: return (.pi, 1)
            case .whorled(let n): return (.pi / Float(max(n, 1)), max(n, 1))
            }
        }

        /// An internode's direction from `d`: turned at random, toward the light and toward the sky.
        mutating func steer(_ d: SIMD3<Float>, _ s: Shoot, light: SIMD3<Float>) -> SIMD3<Float> {
            var d = normalize(d + Foliage.randomUnit(&rng) * s.randomAngle)
            d = normalize(d + (light - d) * s.phototropism)
            d = d + normalize(p.up) * s.gravitropism
            return length_squared(d) < 1e-8 ? normalize(p.up) : normalize(d)
        }

        func relative(_ point: Point) -> Float { min(max(point.fromRoot / max(p.targetHeight, 1e-3), 0), 1) }

        mutating func cycle() {
            let start = points.count
            field.measure(&points, p.light, up: p.up)
            senesce()

            // The tips.
            for b in branches.indices where branches[b].growing && !branches[b].removed {
                let tipIndex = Int(branches[b].points.last!)
                let tip = points[tipIndex]
                let s = p.shoot(branches[b].generation)
                let rel = relative(tip)
                if rel >= 1 { branches[b].growing = false; continue }
                guard tip.light >= p.light.requirement, rng.next() * s.apicalGrowth > 1 - s.apicalRamp.value(rel) else { continue }
                let length = s.segment * (branches[b].generation > 1 ? s.lengthScale : 1)
                    * (1 - p.light.lengthImpact * (1 - tip.light))
                var d = steer(tip.direction, s, light: tip.lightDirection)
                branches[b].ripe += 1
                if let fork = p.bifurcation, branches[b].ripe > fork.cycles, branches[b].generation > 1 || p.maxGeneration == 1,
                   rng.next() < fork.chance {
                    // A fork: this branch goes on to one side, new branches of the same generation to the others.
                    branches[b].ripe = 0
                    let axis = tip.lateral, n = max(fork.count, 2)
                    for k in 1..<n {
                        let around = Float(k) * 2 * .pi / Float(n)
                        let side = simd_quatf(angle: around, axis: d).act(axis)
                        let fd = normalize(d * cos(fork.angle) + side * sin(fork.angle))
                        branches.append(Branch(points: [Int32(tipIndex)], generation: branches[b].generation, parent: Int32(b)))
                        add(to: branches.count - 1, from: tipIndex, direction: fd, length: length)
                    }
                    d = normalize(d * cos(fork.angle) + axis * sin(fork.angle))
                } else {
                    points[tipIndex].bud = branches[b].generation < p.maxGeneration
                        && branches[b].points.count > (p.bareNodes ?? 0)
                }
                let next = add(to: b, from: tipIndex, direction: d, length: length)
                // Its axillary bud faces round from the last by the phyllotaxy's turn.
                points[next].lateral = simd_quatf(angle: phyllotaxy(s).turn, axis: d).act(points[next].lateral)
            }

            // The dormant buds (those of this cycle's tips wait for the next).
            for i in 0..<start where points[i].bud && !points[i].removed {
                let point = points[i]
                let generation = branches[Int(point.branch)].generation
                guard !branches[Int(point.branch)].removed, generation < p.maxGeneration else { points[i].bud = false; continue }
                // Whether it sprouts, how many and at what angle is the axis it is on's (its ramp, its phyllotaxy); how
                // the new branch grows is the branch shoot's.
                let own = p.shoot(generation), s = p.shoot(generation + 1)
                guard point.auxin <= 1 - p.apicalDominance, point.light >= own.requirement ?? p.light.requirement,
                      rng.next() * own.axillaryGrowth > 1 - own.axillaryRamp.value(relative(point)) else { continue }
                points[i].bud = false
                let (_, count) = phyllotaxy(own)
                let length = s.segment * s.lengthScale * (1 - p.light.lengthImpact * (1 - point.light))
                for k in 0..<count {
                    let side = simd_quatf(angle: Float(k) * 2 * .pi / Float(count), axis: point.direction).act(point.lateral)
                    var d = normalize(point.direction * cos(own.axilAngle) + side * sin(own.axilAngle))
                    if s.flatten > 0 {
                        let up = normalize(p.up), level = d - up * dot(d, up)
                        if length_squared(level) > 1e-6 { d = normalize(d + (normalize(level) - d) * s.flatten) }
                    }
                    if let lean = own.sproutLight { d = normalize(d + (point.lightDirection - d) * lean) }
                    d = steer(d, s, light: point.lightDirection)
                    branches.append(Branch(points: [Int32(i)], generation: generation + 1, parent: point.branch))
                    let first = add(to: branches.count - 1, from: i, direction: d, length: length)
                    points[first].lateral = side
                }
            }

            // Below the new growth: thicker, less auxin, more ethylene (once each per cycle).
            var marked = [Bool](repeating: false, count: points.count)
            for n in start..<points.count {
                var q = Int(points[n].parent)
                while q >= 0 && !marked[q] {
                    marked[q] = true
                    q = Int(points[q].parent)
                }
            }
            for q in 0..<start where marked[q] {
                points[q].radius += p.radiusGrowth
                points[q].auxin *= 1 - p.auxinFalloff
                points[q].ethylene = min(points[q].ethylene + p.ethyleneBuildup, 1)
            }
            if p.gravity > 0 { sag() }
        }

        /// Light senescence: a branch shaded too long is shed, and everything on it.
        mutating func senesce() {
            guard let s = p.senescence else { return }
            for b in branches.indices where !branches[b].removed {
                if branches[b].parent >= 0 && branches[Int(branches[b].parent)].removed {
                    remove(b)
                    continue
                }
                guard branches[b].generation >= s.fromGeneration else { continue }
                let own = branches[b].points.dropFirst()   // (its first point is its parent's)
                guard !own.isEmpty else { continue }
                let light = own.reduce(0) { $0 + points[Int($1)].light } / Float(own.count)
                branches[b].shaded = light < s.threshold ? branches[b].shaded + 1 : 0
                if branches[b].shaded > s.cycles { remove(b) }
            }
        }

        mutating func remove(_ b: Int) {
            branches[b].removed = true
            branches[b].growing = false
            for q in branches[b].points.dropFirst() { points[Int(q)].removed = true; points[Int(q)].bud = false }
        }

        /// Gravity: each internode of a branch turns down by its load over its stiffness (load times length over the
        /// radius squared, gently), the turn carried to everything beyond it; at most `sagStep` a cycle and `sagLimit`
        /// in all, so a branch droops but never folds down onto the trunk.
        mutating func sag() {
            let up = normalize(p.up)
            var load = [Float](repeating: 0, count: points.count)
            for i in stride(from: points.count - 1, through: 1, by: -1) where !points[i].removed {
                load[i] += points[i].segment * (1 + p.light.leafDensity * (1 - points[i].ethylene))
                let parent = Int(points[i].parent)
                if parent >= 0 { load[parent] += load[i] }
            }
            var turn = [simd_quatf](repeating: simd_quatf(angle: 0, axis: up), count: points.count)
            var moved = points.map(\.position)
            for i in 1..<points.count {
                let parent = Int(points[i].parent)
                var q = turn[parent]
                if !points[i].removed && branches[Int(points[i].branch)].generation > 1 {
                    let d = points[i].direction
                    let axis = cross(d, -up)
                    if length_squared(axis) > 1e-6 {
                        let r = max(points[i].radius, 2e-3)
                        let wanted = p.gravity * load[i] * points[i].segment * 1e-6 / (r * r) * sqrt(length_squared(axis))
                        let angle = min(wanted, Plant.sagStep, max(Plant.sagLimit - points[i].sagged, 0))
                        points[i].sagged += angle
                        q = q * simd_quatf(angle: angle, axis: normalize(axis))
                    }
                }
                turn[i] = q
                let d = normalize(q.act(points[i].direction))
                moved[i] = moved[parent] + d * points[i].segment
            }
            for i in 1..<points.count {
                points[i].position = moved[i]
                points[i].direction = normalize(turn[i].act(points[i].direction))
                points[i].lateral = normalize(turn[i].act(points[i].lateral))
            }
        }

        /// The gravity stage (Growth.Gravity), once the plant is grown: from the foot out, each internode turns toward
        /// the pull, by strength / 10 times how thin its point is (0 at the plant's thickest, 1 at its thinnest) times how
        /// far across the pull it lies; the turn is carried to all beyond it. The trunk bends too, and nothing limits
        /// the turns but the strength (Params.gravity's sag has a limit, this has none).
        mutating func bend(_ g: Gravity) {
            let up = normalize(p.up)
            let along = g.direction ?? -up
            guard g.strength != 0, length_squared(along) > 1e-8 else { return }
            let pull = normalize(along)
            var thinnest = Float.infinity, thickest = -Float.infinity
            for point in points where !point.removed {
                thinnest = min(thinnest, point.radius)
                thickest = max(thickest, point.radius)
            }
            let spread = thickest - thinnest
            let least = max(0.1, 1 - g.angleCorrection)
            var turn = [simd_quatf](repeating: simd_quatf(angle: 0, axis: up), count: points.count)
            var moved = points.map(\.position)
            for i in points.indices.dropFirst() where !points[i].removed {
                let parent = Int(points[i].parent)
                // (A carved trunk's foot has nothing below it left: it stays.)
                guard !points[parent].removed else { continue }
                let offset = points[i].position - points[parent].position
                var q = turn[parent]
                let turned = q.act(offset)
                if length_squared(turned) > 1e-12 {
                    let d = normalize(turned)
                    var to = pull
                    if g.mode == .phototropic {
                        let light = points[i].lightDirection
                        to = length_squared(light) > 1e-6 ? normalize(light) : up
                    }
                    let across = 1 - abs(dot(d, to))
                    let thin = spread > 0 ? 1 - (points[i].radius - thinnest) / spread : 0
                    let impact = g.strength / 10 * thin * (least + (1 - least) * across)
                    let bent = d + (to - d) * impact
                    if length_squared(bent) > 1e-8 { q = simd_quatf(from: d, to: normalize(bent)) * q }
                }
                turn[i] = q
                moved[i] = moved[parent] + q.act(offset)
            }
            for i in points.indices where !points[i].removed {
                points[i].position = moved[i]
                points[i].direction = normalize(turn[i].act(points[i].direction))
                points[i].lateral = normalize(turn[i].act(points[i].lateral))
            }
        }

        /// The grafts (Params.grafts), once the plant is grown.
        mutating func graft(_ g: Grafts) {
            let reach = points.reduce(Float(0)) { $1.removed ? $0 : max($0, $1.fromRoot) }
            guard reach > 0 else { return }
            for b in branches.indices where !branches[b].removed && branches[b].generation >= g.fromGeneration {
                let nodes = branches[b].points
                guard nodes.count >= 3 else { continue }
                var azimuth = rng.range(0, 2 * .pi)
                for j in 0..<g.perBranch {
                    let k = min(1 + Int(Float(j + 1) / Float(g.perBranch + 1) * Float(nodes.count - 1)), nodes.count - 1)
                    let i = Int(nodes[k]), host = points[i]
                    let u = (host.fromRoot / reach - g.from) / max(1 - g.from, 1e-3)
                    guard !host.removed, u >= 0 else { continue }
                    let t = min(u, 1), scale = g.scale.x + (g.scale.y - g.scale.x) * t
                    let angle = g.angle.x + (g.angle.y - g.angle.x) * t
                    azimuth += 0.75 * .pi
                    let side = simd_quatf(angle: azimuth, axis: host.direction).act(host.lateral)
                    var d = normalize(host.direction * cos(angle) + side * sin(angle))
                    branches.append(Branch(points: [Int32(i)], generation: branches[b].generation + 1, parent: Int32(b), growing: false))
                    let nb = branches.count - 1
                    var from = i
                    for n in 0..<g.segments {
                        from = add(to: nb, from: from, direction: d, length: g.length * scale * rng.range(0.85, 1.15))
                        points[from].radius = max(host.radius * 0.5 * (1 - 0.25 * Float(n)), p.seedRadius)
                        points[from].light = host.light
                        d = normalize(d + Foliage.randomUnit(&rng) * 0.15 + (host.lightDirection - d) * 0.1)
                    }
                }
            }
        }

        /// The spurs (Params.spurs), once the plant is grown: a short shoot at each node of the last generation's
        /// branches, alternate sides, turned a little toward the light.
        mutating func spur(_ s: Spurs) {
            let from = s.fromGeneration ?? p.maxGeneration
            for b in branches.indices where !branches[b].removed && branches[b].generation >= from {
                let nodes = branches[b].points
                guard nodes.count > s.fromNode else { continue }
                var flip: Float = 1
                for k in s.fromNode..<(nodes.count - 1) {
                    let i = Int(nodes[k]), point = points[i]
                    guard !point.removed else { continue }
                    flip = -flip
                    let side = normalize(point.lateral) * flip
                    var d = normalize(point.direction * cos(s.angle) + side * sin(s.angle))
                    d = normalize(d + (point.lightDirection - d) * 0.2)
                    branches.append(Branch(points: [Int32(i)], generation: branches[b].generation + 1, parent: Int32(b), growing: false))
                    add(to: branches.count - 1, from: i, direction: d, length: s.length * rng.range(0.8, 1.2))
                }
            }
        }

        /// Params.carve: the trunk's foot cut off and the plant lowered (along `up`) onto the cut. Whatever grew from
        /// the part cut off goes with it.
        mutating func carveFoot(_ c: Float) {
            guard c > 0, p.stems <= 1, let last = branches[0].points.last else { return }
            let trunk = branches[0].points, cut = c * points[Int(last)].fromRoot
            guard let k = trunk.firstIndex(where: { points[Int($0)].fromRoot >= cut }), k > 0 else { return }
            let a = points[Int(trunk[k - 1])], b = points[Int(trunk[k])]
            let t = (cut - a.fromRoot) / max(b.fromRoot - a.fromRoot, 1e-6)
            let foot = Int(trunk[k - 1])
            points[foot].position = simd_mix(a.position, b.position, SIMD3(repeating: t))
            points[foot].radius = a.radius + (b.radius - a.radius) * t
            for j in 0..<(k - 1) { points[Int(trunk[j])].removed = true; points[Int(trunk[j])].bud = false }
            branches[0].points = Array(trunk[(k - 1)...])
            for b in branches.indices.dropFirst() where !branches[b].removed && points[Int(branches[b].points[0])].removed { remove(b) }
            let up = normalize(p.up), drop = up * dot(points[foot].position, up)
            for i in points.indices { points[i].position -= drop }
        }

        /// Every branch left that was set rather than grown grows from now on (a Grow More's start).
        mutating func revive() {
            for b in branches.indices where !branches[b].removed { branches[b].growing = true }
            for i in points.indices where !points[i].removed && i > 0 && Int(points[i].branch) < branches.count {
                if branches[Int(points[i].branch)].generation < p.maxGeneration { points[i].bud = true }
            }
        }

        /// Where each point goes in the wood: moved across its axis by smooth noise (the trunk's foot stays put).
        /// A branch's first node is its parent's point, so the two move together and the branch stays on.
        func placed(_ w: Wood) -> [SIMD3<Float>] {
            let scale = w.noiseScale
            return points.map { point in
                guard w.noise > 0, !point.removed else { return point.position }
                let generation = branches[Int(point.branch)].generation
                let amount = w.noise * (generation == 1 ? 1 : 0.5) * min(point.fromRoot / 1.5, 1)
                let side = cross(point.direction, point.lateral)
                let q = point.position * scale
                return point.position + (point.lateral * Growth.noise(q, noiseSeed) + side * Growth.noise(q + 31.4, noiseSeed ^ 0x9E3779B9)) * amount
            }
        }

        static let sagStep: Float = 0.01
        static let sagLimit: Float = 0.08

        /// One stem per branch that is left, its level its generation, each generation `wood.thinning` of the last;
        /// and each branch's stem (-1: none).
        func skeleton(_ wood: Wood, at: [SIMD3<Float>]) -> (Foliage.Skeleton, [Int32]) {
            var out = Foliage.Skeleton()
            var stemOf = [Int32](repeating: -1, count: branches.count)
            var limbOf = [Int32](repeating: -1, count: branches.count)
            for (b, branch) in branches.enumerated() where !branch.removed && branch.points.count >= 2 {
                let parentStem = branch.parent >= 0 ? stemOf[Int(branch.parent)] : -1
                if branch.parent >= 0 && parentStem < 0 { continue }   // (its parent was too short to be a stem)
                var limb: Int32 = -1
                if branch.generation == 2 {
                    limb = Int32(out.limbs)
                    out.limbs += 1
                } else if branch.generation > 2 {
                    limb = limbOf[Int(branch.parent)]
                }
                limbOf[b] = limb
                let first = out.nodes.count
                var length: Float = 0
                for (k, q) in branch.points.enumerated() {
                    let point = points[Int(q)]
                    // A branch's first node is on its parent, as thick as its own second (it starts inside the parent).
                    let own = pow(wood.thinning, Float(branch.generation - 1))
                    var radius = (k == 0 && branch.parent >= 0 ? points[Int(branch.points[1])].radius : point.radius) * own
                    if k == 0 && branch.parent >= 0 {
                        // Its first ring, on its parent's axis, inside its parent: no thicker than nine tenths of the
                        // parent there, or it shows through where the branch leaves at an angle.
                        let parentGeneration = branches[Int(branch.parent)].generation
                        radius = min(radius, point.radius * pow(wood.thinning, Float(parentGeneration - 1)) * 0.9)
                    }
                    out.nodes.append(SIMD4(at[Int(q)], radius))
                    if k > 0 { length += point.segment }
                }
                let base = out.nodes[first].w
                let radial: UInt8 = wood.ribbon ? 1 : base > 0.1 ? 12 : base > 0.05 ? 10 : base > 0.02 ? 7 : base > 0.008 ? 5 : 3
                stemOf[b] = Int32(out.stems.count)
                out.stems.append(Foliage.Stem(first: Int32(first), count: Int32(branch.points.count), parent: parentStem, limb: limb,
                                              level: UInt8(min(branch.generation - 1, 255)), radial: radial, length: length))
            }
            return (out, stemOf)
        }

        /// The twigs (Unreal's foliage distributor, its hormone mode): along each branch from its tip back, one every
        /// `spacing`, while the wood is young (its ethylene low); turned out from the branch round it by the golden
        /// angle and toward the light. The tip's points on along the branch.
        func twigs(_ t: Twigs, at: [SIMD3<Float>], stemOf: [Int32]) -> [TwigPlace] {
            var out: [TwigPlace] = []
            var rng = SplitMix64(seed: UInt64(noiseSeed) &* 0x9E3779B97F4A7C15 ^ 0x7A1C)
            let up = normalize(p.up)
            for (b, branch) in branches.enumerated() where !branch.removed && branch.generation >= t.fromGeneration
                && branch.points.count >= 2 && stemOf[b] >= 0 {
                let stem = Int(stemOf[b])
                var total: Float = 0
                for q in branch.points.dropFirst() { total += points[Int(q)].segment }
                var along: Float = 0, next: Float = 0, azimuth = rng.range(0, 2 * .pi)
                let roll = t.roll.map { rng.range(-1, 1) * $0 } ?? 0
                for k in stride(from: branch.points.count - 1, through: 1, by: -1) {
                    let q = Int(branch.points[k]), point = points[q]
                    defer { along += point.segment }
                    guard along >= next else { continue }
                    let tip = k == branch.points.count - 1
                    if !tip && point.ethylene >= t.ethylene { break }
                    next = along + t.spacing * rng.range(0.8, 1.2)
                    var d = point.direction
                    if !tip {
                        let side: SIMD3<Float>
                        if t.alternate == true {
                            // Left and right of the branch in turn, in a plane of the branch's own (Unreal's alternate
                            // phyllotaxy, reset to the bud's frame and flattened across its up): a plane rolled from
                            // the level by up to `roll`, so that branches' sprays don't all lie alike.
                            azimuth += .pi
                            var level = cross(d, up)
                            level = length_squared(level) > 1e-4 ? normalize(level) : point.lateral
                            side = simd_quatf(angle: roll, axis: d).act(level) * (cos(azimuth) < 0 ? -1 : 1)
                        } else {
                            azimuth += Foliage.goldenAngle
                            side = simd_quatf(angle: azimuth, axis: d).act(point.lateral)
                        }
                        d = normalize(d * cos(t.angle) + side * sin(t.angle))
                    }
                    d = normalize(d + (point.lightDirection - d) * t.lightAim)
                    let u = total > 0 ? along / total : 0
                    let size = t.scale * (1 + rng.range(-1, 1) * t.scaleV) * (tip ? t.tipScale ?? 1.1 : 1 + (t.alongScale ?? -0.3) * u)
                    out.append(TwigPlace(position: at[q], direction: d, size: size, stem: stem, light: point.light,
                                         radius: point.radius))
                }
            }
            return out
        }
    }

    /// A plant of `p` as one chain of its stages (what a program's first stages do): for what wants only its skeleton.
    package static func grow(_ p: Params, cycles: Int? = nil, seed: UInt64) -> Foliage.Skeleton {
        var plant = Plant(p, seed: seed)
        for _ in 0..<(cycles ?? p.cycles) { plant.cycle() }
        if let g = p.grafts { plant.graft(g) }
        if let s = p.spurs { plant.spur(s) }
        if let c = p.carve { plant.carveFoot(c) }
        return plant.skeleton(p.wood, at: plant.placed(p.wood)).0
    }

    /// Where a twig of the palette hangs: plant space, its stem (and so its limb), the light it gets there.
    package struct TwigPlace {
        package var position: SIMD3<Float>
        package var direction: SIMD3<Float>
        package var size: Float
        package var stem: Int
        package var light: Float
        package var radius: Float
    }

    /// Whose bone each twig turns on, its own if it keeps one: a stem's n twigs (they come together, tip first) are split
    /// into lerp(n, 1, strength) runs, rounded up (Unreal's Bone Reduction keeps as many between a branch's joints), each on
    /// the bone of its twig nearest the foot.
    static func keptBones(_ places: [TwigPlace], strength: Float) -> [Int] {
        var keeper = Array(places.indices)
        guard strength > 0 else { return keeper }
        let s = min(strength, 1)
        var first = 0
        while first < places.count {
            var end = first + 1
            while end < places.count, places[end].stem == places[first].stem { end += 1 }
            let n = end - first
            let runs = max(Int((Float(n) + (1 - Float(n)) * s).rounded(.up)), 1)
            for run in 0..<runs {
                let last = first + (run + 1) * n / runs - 1
                for i in (first + run * n / runs)...last { keeper[i] = last }
            }
            first = end
        }
        return keeper
    }

    /// One twig of a palette (Unreal's graft palette): a small plant grown along +Y with +Z its sky, with leaves.
    /// The palette's twigs run from sparse to dense (variant 0 the sparsest), for shade to full light.
    /// `cards`: its leaves as cards (the leaf-card scenes', cut out by the species' card sheet).
    package static func twig(_ t: Twigs, variant: Int, seed: UInt64, cards: Bool = false) -> Foliage.Mesh {
        PlantRunner(.graph(.twigs(t))).twig(.oak, variant: variant, of: t.palette, sparse: t.sparse, seed: seed, cards: cards)
    }

    /// What a twig's wood adds to its generation in U (Surface.metal TWIG_WOOD): its young stems shade yellow-green.
    package static let twigWood: Float = 8

    /// How a plant's twigs are grown and hung.
    package struct Twigs: Codable, Equatable {
        package var growth = Twigs.twigGrowth
        package var leaf = Foliage.LeafRecipe(shape: .outline, length: 0.13, width: 0.07, perMetre: 45, angle: 0.9, fold: 0.12,
                                              flutter: 0.6)
        package var palette = 6
        package var spacing: Float = 0.2            // between twigs along a branch (m)
        package var ethylene: Float = 0.85          // twigs only where the wood is younger than this
        package var fromGeneration = 2
        package var scale: Float = 0.9              // a twig's size (its mesh is about a metre)
        package var scaleV: Float = 0.2
        package var angle: Float = 0.75             // out from the branch (rad)
        package var lightAim: Float = 0.3           // turned this far toward the light
        package var alternate: Bool? = nil          // left and right of the branch in turn (nil: spiral)
        package var roll: Float? = nil              // ...in a plane rolled from the level by up to this (rad)
        package var sparse: Float? = nil            // the palette's sparsest twig's leaves, of its densest's (nil: 0.55)
        package var tipScale: Float? = nil          // a branch tip's twig, of `scale` (nil: 1.1)
        /// The others', from the tip back to the branch's foot: 1 + this · the share of the branch behind them (nil:
        /// -0.3, smaller toward the foot; Unreal's sample tree's grow toward it).
        package var alongScale: Float? = nil

        package init() {}

        /// A twig: a few cycles of short internodes, branching freely, flattened into a spray facing the sky.
        package static var twigGrowth: Params {
            var p = Params()
            p.cycles = 8
            p.targetHeight = 0.9
            p.maxGeneration = 3
            p.seedRadius = 0.0018
            p.radiusGrowth = 0.0011
            p.apicalDominance = 0.1
            p.auxinFalloff = 0.5
            p.ethyleneBuildup = 0
            p.trunk.segment = 0.11
            p.trunk.apicalRamp = .linear(1, 0.6)
            p.trunk.axillaryRamp = .linear(0.6, 1)
            p.trunk.axilAngle = 0.9
            p.trunk.randomAngle = 0.15
            p.trunk.phototropism = 0
            p.trunk.flatten = 0.6
            var b = p.trunk
            b.segment = 0.08
            b.flatten = 0.7
            p.branch = b
            p.light.requirement = 0
            p.light.lengthImpact = 0
            p.senescence = nil
            p.wood.noise = 0.004
            p.wood.flare = 0
            p.up = [0, 0, 1]
            p.axis = [0, 1, 0]
            return p
        }
    }

    /// The parameters of a plant of an age: its share of the mature plant's cycles, grown toward its share of the
    /// height (by default a sapling a third of the cycles toward two fifths of the height, a young plant three fifths
    /// toward seven tenths). Its ramps then shape a smaller plant, branched as a small one is, not the foot of the big one.
    package static func aged(_ p: Params, _ age: Foliage.Age) -> Params {
        guard age != .mature else { return p }
        var q = p
        let share = age == .young ? p.young : p.sapling
        q.cycles = max(2, Int((Float(p.cycles) * share.cycles).rounded()))
        q.targetHeight = p.targetHeight * share.height
        return q
    }

    /// The cycles a plant of an age grows.
    package static func cycles(_ p: Params, _ age: Foliage.Age) -> Int { aged(p, age).cycles }
}
