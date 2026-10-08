import Foundation
import simd

/// Procedural plants: trees, bushes, ferns and grass, grown from a `Recipe` and a seed.
///
/// The stages follow a vegetation graph (Unreal's Procedural Vegetation Editor): a grower makes a skeleton of stems
/// level by level (trunk, limbs, branches), bending them by curvature, tropism and a carve envelope; a mesher turns
/// stems into tubes or ribbons; a foliage distributor puts leaves on twigs; a graft distributor hangs boughs (small
/// leafy branches from a per-species palette of shared meshes) on the limbs. A tree is then an assembly: its own trunk
/// and limb meshes plus a few hundred placed palette meshes, each part with a bone for the wind. `flatten` bakes an
/// assembly into two plain meshes (wood, leaves) for whatever cannot trace assemblies.
///
/// Everything is a pure function of the recipe and the seed: sizes are counted before meshing, meshes are filled by
/// index into exactly sized arrays, and the variants are built in parallel, one slot each (FoliageMesh.swift).
enum Foliage {
    /// Of the library: which plants there are, in what order. The open world's tiles name a plant by its place in
    /// its species' set (World.Placement), so a change of the sets makes other tile files.
    static let version = 1

    /// A species: its place in a catalog (PlantCatalog), where its definition (SpeciesDef) says how it grows. The
    /// first seven are the built-in ones, in this order; a catalog's own species follow them.
    struct Species: Hashable, RawRepresentable, Codable, CustomStringConvertible {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let oak = Species(rawValue: 0), birch = Species(rawValue: 1), conifer = Species(rawValue: 2)
        static let dead = Species(rawValue: 3), bush = Species(rawValue: 4), fern = Species(rawValue: 5), grass = Species(rawValue: 6)
        /// The built-in species.
        static let allCases = (0..<7).map(Species.init(rawValue:))
        private static let names = ["oak", "birch", "conifer", "dead", "bush", "fern", "grass"]

        var description: String { rawValue < Species.names.count ? Species.names[rawValue] : "species \(rawValue)" }
        /// (Of the built-in species.) Has a palette of boughs, so its plants are assemblies.
        var hasBoughs: Bool { PlantCatalog.builtIn.species.indices.contains(rawValue) && PlantCatalog.builtIn[self].paletteSize > 0 }
        var isTree: Bool { PlantCatalog.builtIn.species.indices.contains(rawValue) && PlantCatalog.builtIn[self].role == .tree }
    }

    /// Growth stage: the same recipe at a fraction of its height, with fewer limbs and levels (SpeciesDef.Ages).
    enum Age: Int, CaseIterable, Codable { case sapling, young, mature }

    /// How long a limb is by its place along the trunk (`crownRatio`): the presets of a crown's curve.
    enum Crown: String, CaseIterable, Codable { case conical, spherical, hemispherical, cylindrical, flame }
    enum Phyllotaxis: Equatable {
        case spiral            // each leaf 137.5 degrees round from the last
        case distichous        // alternating sides, in the plane across `up`
        case whorled(Int)      // rings of n
    }
    enum LeafShape: String, CaseIterable, Codable {
        case kite              // 2 triangles, folded along the midrib
        case blade             // 4 triangles, rounder
        case needle            // 1 triangle
    }

    static let goldenAngle: Float = 2.39996

    /// One level of stems: how many grow from each stem of the level before, and how they run.
    struct Level: Codable, Equatable {
        var count = 1                       // per parent stem (level 0: stems from the ground)
        var length: Float = 1               // of the parent's length (level 0: metres)
        var lengthV: Float = 0.1            // relative variation
        /// From the parent's direction (level 0: from `up`, its start only), by where along the parent the stem grows.
        var down: Curve = .linear(0.8, 0.8)
        var downAngleV: Float = 0.15
        var rotate: Float = Foliage.goldenAngle   // around the parent, from one child to the next
        var rotateV: Float = 0.3
        var start: Float = 0.2              // the first child sits this far along the parent
        var curve: Float = 0                // total bend toward `up` (+) or away from it (-), radians
        var curveV: Float = 0.3             // random wander
        var tropism: Float = 0              // steady pull toward `up` (+: light) or away (-: weight)
        var segments = 5
        var radial = 5                      // sides of the tube; 1 = a flat ribbon
        /// The radius along the stem, of its radius at its foot (a taper of 0 = a cylinder, 1 = to a point).
        var radius: Curve = .taper(0.9)
        /// How long the stems are by where along the parent they grow, of `length` (level 1's: the crown's shape).
        var along: Curve = .taper(0.5)

        init(count: Int = 1, length: Float = 1, lengthV: Float = 0.1, downAngle: Float = 0.8, downAngleEnd: Float? = nil,
             downAngleV: Float = 0.15, rotate: Float = Foliage.goldenAngle, rotateV: Float = 0.3, start: Float = 0.2, curve: Float = 0,
             curveV: Float = 0.3, tropism: Float = 0, segments: Int = 5, radial: Int = 5, taper: Float = 0.9) {
            self.count = count
            self.length = length
            self.lengthV = lengthV
            down = .linear(downAngle, downAngleEnd ?? downAngle)
            self.downAngleV = downAngleV
            self.rotate = rotate
            self.rotateV = rotateV
            self.start = start
            self.curve = curve
            self.curveV = curveV
            self.tropism = tropism
            self.segments = segments
            self.radial = radial
            radius = .taper(taper)
        }
    }

    struct LeafRecipe: Codable, Equatable {
        var shape = LeafShape.kite
        var length: Float = 0.1
        var width: Float = 0.06
        var sizeV: Float = 0.25
        var perMetre: Float = 30            // along a twig
        var start: Float = 0.1              // the first leaf sits this far along the twig
        var angle: Float = 0.9              // from the twig's direction
        var angleV: Float = 0.3
        var phyllotaxis = Phyllotaxis.spiral
        var fold: Float = 0.15              // the sides' lift over the midrib, in widths
        /// Size along the twig, of the size at its base (its end: the tip's leaf; fern pinnae shrink).
        var size: Curve = .linear(1, 1)
        var flutter: Float = 0.4            // how far the faces turn away from `up`, at random
        var fromLevel = 0                   // leaves only on stems of this level and deeper

        init(shape: LeafShape = .kite, length: Float = 0.1, width: Float = 0.06, sizeV: Float = 0.25, perMetre: Float = 30,
             start: Float = 0.1, angle: Float = 0.9, angleV: Float = 0.3, phyllotaxis: Phyllotaxis = .spiral, fold: Float = 0.15,
             tipScale: Float = 1, flutter: Float = 0.4, fromLevel: Int = 0) {
            self.shape = shape
            self.length = length
            self.width = width
            self.sizeV = sizeV
            self.perMetre = perMetre
            self.start = start
            self.angle = angle
            self.angleV = angleV
            self.phyllotaxis = phyllotaxis
            self.fold = fold
            size = .linear(1, tipScale)
            self.flutter = flutter
            self.fromLevel = fromLevel
        }
    }

    /// Where boughs hang on the scaffold.
    struct Graft: Codable, Equatable {
        var spacing: Float = 0.45           // metres between boughs along a stem
        var fromLevel = 1                   // stems of this level and deeper carry boughs ...
        var start: Float = 0.5              // ... from this far along (the last level: from `lastStart`)
        var lastStart: Float = 0.15
        var angle: Float = 0.7              // from the stem's direction
        var angleV: Float = 0.25
        var rotate: Float = Foliage.goldenAngle
        var scale: ClosedRange<Float> = 0.8...1.2
        var droop: Float = 0.1              // pull away from `up`
    }

    /// Stems end where they leave this ellipsoid (pruning to a shape).
    struct Carve: Codable, Equatable {
        var center: SIMD3<Float>
        var radii: SIMD3<Float>
        var fromLevel = 1
    }

    struct Recipe: Codable, Equatable {
        var levels: [Level]
        var ratio: Float = 0.03             // the first stem's radius over its length
        var ratioPower: Float = 1.2         // child radius = parent radius x (length ratio)^power
        var flare: Float = 0.5              // widening at the foot
        var spread: Float = 0               // level 0 stems start within this radius
        var carve: Carve? = nil
        var axis = SIMD3<Float>(0, 1, 0)    // level 0 grows this way
        var up = SIMD3<Float>(0, 1, 0)      // the sky: boughs are grown lying down, along +Y with +Z up
        var leaf: LeafRecipe? = nil         // leaves on this plant's own stems (boughs, ferns)
        var graft: Graft? = nil

        /// `crown`: level 1's lengths along the trunk (its `along` curve).
        init(levels: [Level], ratio: Float = 0.03, ratioPower: Float = 1.2, flare: Float = 0.5, crown: Crown = .spherical,
             spread: Float = 0, carve: Carve? = nil, axis: SIMD3<Float> = [0, 1, 0], up: SIMD3<Float> = [0, 1, 0],
             leaf: LeafRecipe? = nil, graft: Graft? = nil) {
            self.levels = levels
            if levels.count > 1 { self.levels[1].along = .crown(crown) }
            self.ratio = ratio
            self.ratioPower = ratioPower
            self.flare = flare
            self.spread = spread
            self.carve = carve
            self.axis = axis
            self.up = up
            self.leaf = leaf
            self.graft = graft
        }
    }

    // MARK: - Skeleton

    struct Stem {
        var first: Int32                    // into Skeleton.nodes
        var count: Int32                    // nodes: 2 or more
        var parent: Int32                   // stem, -1 for level 0
        var limb: Int32                     // which level-1 stem it belongs to (-1: level 0)
        var level: UInt8
        var radial: UInt8
        var length: Float
    }

    struct Skeleton {
        var nodes: [SIMD4<Float>] = []      // xyz position, w radius
        var stems: [Stem] = []
        var limbs = 0

        /// A stem at fraction `f` of its length.
        func sample(_ s: Stem, _ f: Float) -> (position: SIMD3<Float>, tangent: SIMD3<Float>, radius: Float) {
            let x = min(max(f, 0), 1) * Float(s.count - 1)
            let i = min(Int(x), Int(s.count) - 2)
            let a = nodes[Int(s.first) + i], b = nodes[Int(s.first) + i + 1]
            let p = a + (b - a) * (x - Float(i))
            return (xyz(p), normalize(xyz(b) - xyz(a)), p.w)
        }
    }

    struct LeafAnchor {
        var position: SIMD3<Float>
        var direction: SIMD3<Float>         // unit, base to tip
        var normal: SIMD3<Float>            // unit, across the direction
        var length: Float
        var width: Float
    }

    static let minRadius: Float = 0.002

    @inline(__always) static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    static func crownRatio(_ crown: Crown, _ r: Float) -> Float {   // r: 1 at the crown's base, 0 at the top
        switch crown {
        case .conical: return 0.2 + 0.8 * r
        case .spherical: return 0.2 + 0.8 * sin(.pi * r)
        case .hemispherical: return 0.2 + 0.8 * sin(0.5 * .pi * r)
        case .cylindrical: return 1
        case .flame: return r <= 0.7 ? 0.15 + 0.85 * r / 0.7 : 0.15 + 0.85 * (1 - r) / 0.3
        }
    }

    /// Unit vector across `t`: across `up` too if it can be (horizontal for an upright plant).
    static func perpendicular(_ t: SIMD3<Float>, up: SIMD3<Float>) -> SIMD3<Float> {
        let h = cross(up, t)
        let l = length_squared(h)
        if l > 1e-8 { return h / l.squareRoot() }
        return normalize(cross(abs(t.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1), t))
    }

    /// `t` turned by `down` away from itself, toward the side at `azimuth` around it (0 = across `up`).
    static func direction(from t: SIMD3<Float>, down: Float, azimuth: Float, up: SIMD3<Float>) -> SIMD3<Float> {
        let a = perpendicular(t, up: up), b = cross(t, a)
        let radial = a * cos(azimuth) + b * sin(azimuth)
        return normalize(t * cos(down) + radial * sin(down))
    }

    /// `t` turned by `angle` toward `up` (unchanged if it already points along it).
    static func bend(_ t: SIMD3<Float>, toward up: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        let across = up - t * dot(up, t)
        let l = length(across)
        guard l > 1e-4 else { return t }
        return normalize(t * cos(angle) + across * (sin(angle) / l))
    }

    static func randomUnit(_ rng: inout SplitMix64) -> SIMD3<Float> {
        let z = rng.range(-1, 1), a = rng.range(0, 2 * .pi)
        let r = max(0, 1 - z * z).squareRoot()
        return SIMD3(r * cos(a), z, r * sin(a))
    }

    /// The seed of one piece of the library: the same for the same piece whatever else is built.
    static func seed(_ base: UInt64, _ a: Int, _ b: Int, _ c: Int) -> UInt64 {
        var rng = SplitMix64(seed: base ^ (UInt64(a + 1) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(b + 1) &* 0xC2B2_AE3D_27D4_EB4F)
                             ^ (UInt64(c + 1) &* 0x1656_67B1_9E37_79F9))
        return rng.nextUInt64()
    }

    // MARK: - Grower

    private struct Grower {
        let recipe: Recipe
        var rng: SplitMix64
        var skeleton = Skeleton()
        /// Each level's length when nothing varies: what a stem's child count is scaled against.
        let nominal: [Float]

        init(_ recipe: Recipe, seed: UInt64) {
            self.recipe = recipe
            rng = SplitMix64(seed: seed)
            var lengths: [Float] = []
            for (l, level) in recipe.levels.enumerated() { lengths.append(l == 0 ? level.length : lengths[l - 1] * level.length) }
            nominal = lengths
        }

        mutating func grow() {
            let level = recipe.levels[0]
            var azimuth = rng.range(0, 2 * .pi)
            for _ in 0..<level.count {
                azimuth += level.rotate + rng.range(-1, 1) * level.rotateV
                let down = level.count == 1 ? rng.range(0, 1) * level.downAngleV
                                            : max(0, level.down.start + rng.range(-1, 1) * level.downAngleV)
                let side = Foliage.perpendicular(recipe.axis, up: SIMD3(0.36, 0.48, 0.8))
                let across = cross(recipe.axis, side)
                let radial = side * cos(azimuth) + across * sin(azimuth)
                let dir = normalize(recipe.axis * cos(down) + radial * sin(down))
                let length = level.length * (1 + rng.range(-1, 1) * level.lengthV)
                let foot = radial * (recipe.spread * rng.next().squareRoot())
                stem(0, from: foot, direction: dir, length: length, radius: max(length * recipe.ratio, Foliage.minRadius),
                     parent: -1, limb: -1)
            }
        }

        private func carved(_ p: SIMD3<Float>, _ l: Int) -> Bool {
            guard let carve = recipe.carve, l >= carve.fromLevel else { return false }
            let q = (p - carve.center) / carve.radii
            return dot(q, q) > 1
        }

        private mutating func stem(_ l: Int, from origin: SIMD3<Float>, direction: SIMD3<Float>, length: Float, radius: Float,
                                   parent: Int32, limb: Int32) {
            let level = recipe.levels[l], up = recipe.up
            let index = Int32(skeleton.stems.count)
            let first = skeleton.nodes.count
            let segments = max(level.segments, 1)
            let step = length / Float(segments), inv = 1 / Float(segments)
            let curve = level.curve * inv, tropism = level.tropism * inv, wander = level.curveV * inv
            var p = origin, t = direction
            for i in 0...segments {
                let f = Float(i) * inv
                var r = radius * level.radius.value(f)
                if l == 0 { let foot = max(0, 1 - f * 8); r *= 1 + recipe.flare * foot * foot }
                skeleton.nodes.append(SIMD4(p, max(r, Foliage.minRadius)))
                if i == segments { break }
                t = Foliage.bend(t, toward: up, by: curve)
                t = normalize(t + Foliage.randomUnit(&rng) * wander + up * tropism)
                let next = p + t * step
                if i >= 1 && carved(next, l) { break }   // pruned: the stem ends at this node
                p = next
            }
            let count = skeleton.nodes.count - first
            let grown = step * Float(count - 1)
            skeleton.stems.append(Stem(first: Int32(first), count: Int32(count), parent: parent, limb: limb, level: UInt8(l),
                                       radial: UInt8(max(level.radial, 1)), length: grown))
            guard l + 1 < recipe.levels.count else { return }

            let next = recipe.levels[l + 1]
            // Fewer children on a stem shorter than its level usually is (never none).
            let children = l == 0 ? next.count : max(1, Int((Float(next.count) * min(grown / nominal[l], 1.5)).rounded()))
            // Children to the left and right only (rotate = pi) lie in the plane across `up`.
            var azimuth = abs(next.rotate - .pi) < 1e-3 ? 0 : rng.range(0, 2 * .pi)
            for k in 0..<children {
                let u = (Float(k) + 0.5 + rng.range(-0.3, 0.3)) / Float(children)
                let at = skeleton.sample(skeleton.stems[Int(index)], next.start + (1 - next.start) * u)
                azimuth += next.rotate + rng.range(-1, 1) * next.rotateV
                let down = next.down.value(u) + rng.range(-1, 1) * next.downAngleV
                let dir = Foliage.direction(from: at.tangent, down: down, azimuth: azimuth, up: up)
                var childLength = length * next.length * next.along.value(u)
                childLength *= 1 + rng.range(-1, 1) * next.lengthV
                let r = min(at.radius * 0.7, radius * pow(childLength / length, recipe.ratioPower))
                let childLimb: Int32
                if l == 0 { childLimb = Int32(skeleton.limbs); skeleton.limbs += 1 } else { childLimb = limb }
                stem(l + 1, from: at.position, direction: dir, length: childLength, radius: max(r, Foliage.minRadius),
                     parent: index, limb: childLimb)
            }
        }
    }

    static func grow(_ recipe: Recipe, seed: UInt64) -> Skeleton {
        var grower = Grower(recipe, seed: seed)
        grower.grow()
        return grower.skeleton
    }

    // MARK: - Foliage distributor

    /// Leaves along the stems of `leaf.fromLevel` and deeper, one more at each tip, in a shuffled order: any leading
    /// part of them is then a random sample of them all (leaf fall drops the rest).
    static func leaves(on skeleton: Skeleton, _ leaf: LeafRecipe, up: SIMD3<Float>, rng: inout SplitMix64) -> [LeafAnchor] {
        var anchors: [LeafAnchor] = []
        var total = 0
        func count(_ s: Stem) -> Int { Int(s.length * (1 - leaf.start) * leaf.perMetre) }
        for s in skeleton.stems where Int(s.level) >= leaf.fromLevel { total += count(s) + 1 }
        anchors.reserveCapacity(total)
        let aspect = leaf.width / leaf.length

        func place(_ at: SIMD3<Float>, _ dir: SIMD3<Float>, _ size: Float, _ rng: inout SplitMix64) {
            var normal = up - dir * dot(up, dir)
            if length_squared(normal) < 1e-6 { normal = Foliage.perpendicular(dir, up: up) }
            normal = normalize(normal) + Foliage.randomUnit(&rng) * leaf.flutter
            normal -= dir * dot(normal, dir)
            if length_squared(normal) < 1e-6 { normal = Foliage.perpendicular(dir, up: up) }
            anchors.append(LeafAnchor(position: at, direction: dir, normal: normalize(normal), length: size, width: size * aspect))
        }

        for s in skeleton.stems where Int(s.level) >= leaf.fromLevel {
            let n = count(s)
            var azimuth = rng.range(0, 2 * .pi)
            for k in 0..<n {
                let u = (Float(k) + 0.5) / Float(n)
                let at = skeleton.sample(s, leaf.start + (1 - leaf.start) * u)
                switch leaf.phyllotaxis {
                case .spiral: azimuth += Foliage.goldenAngle
                case .distichous: azimuth = k & 1 == 0 ? 0 : .pi
                case .whorled(let ring): azimuth += k % ring == 0 ? 0.6 : 2 * .pi / Float(ring)
                }
                let down = max(0.05, leaf.angle + rng.range(-1, 1) * leaf.angleV)
                let dir = Foliage.direction(from: at.tangent, down: down, azimuth: azimuth, up: up)
                let size = leaf.length * (1 + rng.range(-1, 1) * leaf.sizeV) * leaf.size.value(u)
                place(at.position, dir, size, &rng)
            }
            let tip = skeleton.sample(s, 1)
            place(tip.position, tip.tangent, leaf.length * leaf.size.end * (1 + rng.range(-1, 1) * leaf.sizeV), &rng)
        }
        for i in stride(from: anchors.count - 1, to: 0, by: -1) { anchors.swapAt(i, rng.int(i + 1)) }
        return anchors
    }

    /// A card stands for a stretch of twig and its leaves: a rectangle from `base` to `top`, `half` to either side,
    /// showing one square of its species' card sheet (FoliageTextures.cardSheet), cut out by the sheet's alpha.
    struct Card {
        var base: SIMD3<Float>
        var top: SIMD3<Float>
        var half: SIMD3<Float>
        var normal: SIMD3<Float>
        var cell: Int
    }

    /// The stretch of twig a card's picture shows, metres (in a bough's own space, before it is hung and scaled).
    static let cardTwig: Float = 0.45

    /// Cards in place of `leaves(on:)`: two crossed along each stretch of about `cardTwig` of the stems that carry
    /// leaves, so that a twig shows its leaves from any side. Shuffled, as the leaves are (leaf fall drops whole cards).
    static func cards(on skeleton: Skeleton, _ leaf: LeafRecipe, up: SIMD3<Float>, rng: inout SplitMix64) -> [Card] {
        var cards: [Card] = []
        let size = FoliageTextures.cardSize(leaf, twig: cardTwig)
        for s in skeleton.stems where Int(s.level) >= leaf.fromLevel {
            let stretches = max(Int((s.length / cardTwig).rounded()), 1)
            for k in 0..<stretches {
                let a = skeleton.sample(s, Float(k) / Float(stretches)).position, b = skeleton.sample(s, Float(k + 1) / Float(stretches)).position
                let reach = simd_length(b - a)
                guard reach > 1e-4 else { continue }
                let axis = (b - a) / reach
                var flat = up - axis * dot(up, axis)
                flat = length_squared(flat) < 1e-6 ? Foliage.perpendicular(axis, up: up) : normalize(flat)
                let roll = rng.range(-0.5, 0.5)
                for turn in [roll, roll + .pi / 2 + rng.range(-0.3, 0.3)] {
                    let across = cross(axis, flat)
                    let normal = flat * cos(turn) + across * sin(turn)
                    cards.append(Card(base: a, top: b + axis * (0.9 * leaf.length), half: cross(axis, normal) * (size.x / 2), normal: normal,
                                      cell: rng.int(FoliageTextures.cardCells * FoliageTextures.cardCells)))
                }
            }
        }
        for i in stride(from: cards.count - 1, to: 0, by: -1) { cards.swapAt(i, rng.int(i + 1)) }
        return cards
    }

    // MARK: - Plants

    /// A rigid piece of an assembly turns about its bone's pivot in the wind; a bone hangs on its parent's.
    struct Bone {
        var pivot: SIMD3<Float>             // plant space, at rest
        var axis: SIMD3<Float>              // the stem's direction there
        var parent: Int32                   // -1: the root (the whole plant about its foot)
        var length: Float                   // of what it carries: longer and thinner sways more
        var radius: Float
        var phase: Float                    // 0...1, so that no two move together
    }

    struct Part {
        var mesh: Int                       // in the plant's own meshes, or the species' palette if `shared`
        var shared: Bool
        var transform: float4x4             // into plant space: a rotation, a uniform scale and a translation
        var bone: Int
    }

    /// One variant of a species at an age. Bone 0 is the root; part 0 is the trunk.
    struct Plant {
        let species: Species
        let age: Age
        var meshes: [Mesh]
        var parts: [Part]
        var bones: [Bone]
        var bounds: AABB
        var height: Float { bounds.hi.y }
    }

    struct SpeciesSet {
        let species: Species
        var palette: [Mesh]
        var plants: [Plant]

        func plants(of age: Age) -> [Int] { plants.indices.filter { plants[$0].age == age } }
    }

    /// The part's local frame for a bough along `dir`: +Y along it, +Z as far toward `up` as it goes.
    static func graftTransform(at p: SIMD3<Float>, along dir: SIMD3<Float>, scale s: Float, up: SIMD3<Float>,
                               roll: Float) -> float4x4 {
        var z = up - dir * dot(up, dir)
        z = length_squared(z) < 1e-4 ? perpendicular(dir, up: up) : normalize(z)
        let x0 = cross(dir, z)
        // A little roll about the bough's own direction, so that the palette's few meshes don't all lie alike.
        let x = x0 * cos(roll) + z * sin(roll)
        let zr = cross(x, dir)
        return float4x4(columns: (SIMD4(x * s, 0), SIMD4(dir * s, 0), SIMD4(zr * s, 0), SIMD4(p, 1)))
    }

    /// Grows one plant of a built-in species. `palette`: the species' bough meshes (their bounds place the plant's).
    static func plant(_ species: Species, age: Age, seed: UInt64, palette: [Mesh]) -> Plant {
        plant(PlantCatalog.builtIn[species], species, age: age, seed: seed, palette: palette)
    }

    /// Grows one plant of `def` (the species `species` of its catalog).
    static func plant(_ def: SpeciesDef, _ species: Species, age: Age, seed: UInt64, palette: [Mesh]) -> Plant {
        if let grass = def.grass {
            let patch = grassPatch(seed: seed, size: grass.size, blades: grass.blades)
            return Plant(species: species, age: age, meshes: [patch], parts: [Part(mesh: 0, shared: false,
                         transform: matrix_identity_float4x4, bone: 0)],
                         bones: [Bone(pivot: .zero, axis: [0, 1, 0], parent: -1, length: 0.4, radius: 0.004, phase: 0)],
                         bounds: patch.bounds)
        }
        let recipe = def.recipe(age)
        var rng = SplitMix64(seed: seed)
        let skeleton = grow(recipe, seed: rng.nextUInt64())
        let trunk = skeleton.stems[0]
        var bones = [Bone(pivot: .zero, axis: recipe.axis, parent: -1, length: trunk.length,
                          radius: skeleton.nodes[Int(trunk.first)].w, phase: rng.next())]
        var parts: [Part] = []
        var meshes: [Mesh] = []
        var bounds = AABB()

        guard let graft = recipe.graft, !palette.isEmpty else {
            // No boughs: one mesh, the stems and whatever leaves grow on them (ferns, dead trees).
            let anchors = recipe.leaf.map { leaves(on: skeleton, $0, up: recipe.up, rng: &rng) } ?? []
            let mesh = Foliage.mesh(skeleton, stems: nil, leaves: anchors, shape: recipe.leaf?.shape ?? .kite,
                                    fold: recipe.leaf?.fold ?? 0, up: recipe.up, allLeaves: def.stemsAreLeaves)
            return Plant(species: species, age: age, meshes: [mesh],
                         parts: [Part(mesh: 0, shared: false, transform: matrix_identity_float4x4, bone: 0)],
                         bones: bones, bounds: mesh.bounds)
        }

        // The scaffold: the level 0 stems are one part, each limb (a level 1 stem and all that grows on it) another.
        var groups = [[Int]](repeating: [], count: 1 + skeleton.limbs)
        for (i, s) in skeleton.stems.enumerated() { groups[Int(s.limb) + 1].append(i) }
        for (g, stems) in groups.enumerated() {
            let mesh = Foliage.mesh(skeleton, stems: stems, leaves: [], shape: .kite, fold: 0, up: recipe.up, allLeaves: false)
            bounds.grow(mesh.bounds)
            if g > 0 {
                let s = skeleton.stems[stems[0]]
                let foot = skeleton.sample(s, 0)
                bones.append(Bone(pivot: foot.position, axis: foot.tangent, parent: 0, length: s.length, radius: foot.radius,
                                  phase: rng.next()))
            }
            parts.append(Part(mesh: meshes.count, shared: false, transform: matrix_identity_float4x4, bone: g))
            meshes.append(mesh)
        }

        // The graft distributor: boughs along the outer stems, and one at each of their tips.
        let lastLevel = recipe.levels.count - 1
        func hang(_ at: (position: SIMD3<Float>, tangent: SIMD3<Float>, radius: Float), _ dir: SIMD3<Float>, _ size: Float,
                  _ limb: Int32) {
            let pick = rng.int(palette.count)
            let transform = graftTransform(at: at.position, along: dir, scale: size, up: recipe.up, roll: rng.range(-0.5, 0.5))
            bounds.grow(palette[pick].bounds.transformed(transform))
            bones.append(Bone(pivot: at.position, axis: dir, parent: Int32(limb + 1), length: size, radius: at.radius,
                              phase: rng.next()))
            parts.append(Part(mesh: pick, shared: true, transform: transform, bone: bones.count - 1))
        }
        for s in skeleton.stems where Int(s.level) >= min(graft.fromLevel, lastLevel) {
            let from = Int(s.level) == lastLevel ? graft.lastStart : graft.start
            let n = Int(s.length * (1 - from) / graft.spacing)
            var azimuth = abs(graft.rotate - .pi) < 1e-3 ? 0 : rng.range(0, 2 * .pi)
            for k in 0..<n {
                let u = (Float(k) + 0.5 + rng.range(-0.25, 0.25)) / Float(n)
                let at = skeleton.sample(s, from + (1 - from) * u)
                azimuth += graft.rotate
                var dir = direction(from: at.tangent, down: graft.angle + rng.range(-1, 1) * graft.angleV, azimuth: azimuth,
                                    up: recipe.up)
                dir = normalize(dir - recipe.up * graft.droop)
                let size = rng.range(graft.scale.lowerBound, graft.scale.upperBound) * (1 - 0.25 * u)
                hang(at, dir, size, s.limb)
            }
            let tip = skeleton.sample(s, 1)
            hang(tip, tip.tangent, rng.range(graft.scale.lowerBound, graft.scale.upperBound) * 0.85, s.limb)
        }
        return Plant(species: species, age: age, meshes: meshes, parts: parts, bones: bones, bounds: bounds)
    }

    /// One bough of a species' palette: a twig with side twigs and leaves, lying along +Y with +Z up. `cards`: its
    /// leaves as cards (a few rectangles with the leaves' picture) instead of a mesh each.
    static func bough(_ species: Species, variant: Int, seed: UInt64, cards: Bool = false) -> Mesh {
        bough(boughRecipe(species, variant: variant), seed: seed, cards: cards)
    }

    static func bough(_ recipe: Recipe, seed: UInt64, cards: Bool = false) -> Mesh {
        var rng = SplitMix64(seed: seed)
        let skeleton = grow(recipe, seed: rng.nextUInt64())
        if cards, let leaf = recipe.leaf {
            return cardMesh(skeleton, cards: Foliage.cards(on: skeleton, leaf, up: recipe.up, rng: &rng), up: recipe.up)
        }
        let anchors = recipe.leaf.map { leaves(on: skeleton, $0, up: recipe.up, rng: &rng) } ?? []
        return mesh(skeleton, stems: nil, leaves: anchors, shape: recipe.leaf?.shape ?? .kite, fold: recipe.leaf?.fold ?? 0,
                    up: recipe.up, allLeaves: false)
    }

    // MARK: - Library

    /// `count` values made by `make`, each in its own slot: in parallel, with nothing shared between them.
    static func slots<T>(_ count: Int, parallel: Bool, _ make: (Int) -> T) -> [T] {
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let out = buffer.baseAddress!
            if parallel {
                DispatchQueue.concurrentPerform(iterations: count) { (out + $0).initialize(to: make($0)) }
            } else {
                for i in 0..<count { (out + i).initialize(to: make(i)) }
            }
            initialized = count
        }
    }

    /// Every species' palette and plants (of `catalog`; `species`: only these). The same seed gives the same
    /// library, built in parallel or not; a species' plants are the same whatever else is built with it.
    /// `cards`: the boughs' leaves as cards.
    static func library(seed: UInt64, catalog: PlantCatalog = .builtIn, species: [Species]? = nil, parallel: Bool = true,
                        cards: Bool = false) -> [SpeciesSet] {
        let species = species ?? catalog.all
        struct Job { var species: Species; var age: Age; var index: Int }
        var boughJobs: [Job] = [], plantJobs: [Job] = []
        for s in species {
            for i in 0..<catalog[s].paletteSize { boughJobs.append(Job(species: s, age: .mature, index: i)) }
            for age in Age.allCases { for i in 0..<catalog[s].variants(age) { plantJobs.append(Job(species: s, age: age, index: i)) } }
        }
        let boughs = slots(boughJobs.count, parallel: parallel) { j -> Mesh in
            let job = boughJobs[j], def = catalog[job.species]
            return bough(def.boughRecipe(variant: job.index)!, seed: Foliage.seed(seed, def.seedIndex, -1, job.index), cards: cards)
        }
        var palettes = [[Mesh]](repeating: [], count: catalog.count)
        for (j, job) in boughJobs.enumerated() { palettes[job.species.rawValue].append(boughs[j]) }
        let plants = slots(plantJobs.count, parallel: parallel) { j -> Plant in
            let job = plantJobs[j], def = catalog[job.species]
            return plant(def, job.species, age: job.age, seed: Foliage.seed(seed, def.seedIndex, job.age.rawValue, job.index),
                         palette: palettes[job.species.rawValue])
        }
        return species.map { s in
            SpeciesSet(species: s, palette: palettes[s.rawValue],
                       plants: plantJobs.indices.filter { plantJobs[$0].species == s }.map { plants[$0] })
        }
    }
}
