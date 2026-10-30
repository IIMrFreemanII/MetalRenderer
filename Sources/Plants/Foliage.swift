import EngineCore
import Foundation
import simd

/// Procedural plants: trees, bushes, ferns and grass, grown from a species' definition (SpeciesDef) and a seed.
///
/// The stages follow a vegetation graph (Unreal's Procedural Vegetation Editor): a growth simulation grows a skeleton
/// bud by bud (Growth, Growth/Grower.swift), in the light its own shadow leaves it; a mesher turns its branches into
/// tubes, lobed and flared at the foot (Growth/Mesher.swift); a foliage distributor puts leaves on stems; the twig
/// distributor hangs twigs (small leafy plants, grown the same way, from a per-species palette of shared meshes) on
/// the young wood. A tree is then an assembly: its own trunk and limb meshes plus a few hundred placed palette meshes,
/// each part with a bone for the wind. `flatten` bakes an assembly into two plain meshes (wood, leaves) for whatever
/// cannot trace assemblies.
///
/// Everything is a pure function of the definition and the seed: sizes are counted before meshing, meshes are filled
/// by index into exactly sized arrays, and the variants are built in parallel, one slot each (FoliageMesh.swift).
package enum Foliage {
    /// Of the library: which plants there are, in what order. The open world's tiles name a plant by its place in
    /// its species' set (World.Placement), so a change of the sets makes other tile files.
    package static let version = 2

    /// A species: its place in a catalog (PlantCatalog), where its definition (SpeciesDef) says how it grows. The
    /// first seven are the built-in ones, in this order; a catalog's own species follow them.
    package struct Species: Hashable, RawRepresentable, Codable, CustomStringConvertible {
        package let rawValue: Int
        package init(rawValue: Int) { self.rawValue = rawValue }

        package static let oak = Species(rawValue: 0), birch = Species(rawValue: 1), conifer = Species(rawValue: 2)
        package static let dead = Species(rawValue: 3), bush = Species(rawValue: 4), fern = Species(rawValue: 5), grass = Species(rawValue: 6)
        /// The built-in species.
        package static let allCases = (0..<7).map(Species.init(rawValue:))
        private static let names = ["oak", "birch", "conifer", "dead", "bush", "fern", "grass"]

        package var description: String { rawValue < Species.names.count ? Species.names[rawValue] : "species \(rawValue)" }
        /// (Of the built-in species.) Has a palette of twigs, so its plants are assemblies.
        package var hasBoughs: Bool { PlantCatalog.builtIn.species.indices.contains(rawValue) && PlantCatalog.builtIn[self].paletteSize > 0 }
        package var isTree: Bool { PlantCatalog.builtIn.species.indices.contains(rawValue) && PlantCatalog.builtIn[self].role == .tree }
    }

    /// Growth stage: the same seed grown fewer cycles toward a lower height (Growth.aged).
    package enum Age: Int, CaseIterable, Codable { case sapling, young, mature }

    /// How buds and leaves are set round an axis.
    package enum Phyllotaxis: Equatable {
        case spiral            // each leaf 137.5 degrees round from the last
        case distichous        // alternating sides, in the plane across `up`
        case whorled(Int)      // rings of n
    }
    package enum LeafShape: String, CaseIterable, Codable {
        case kite              // 2 triangles, folded along the midrib
        case blade             // 4 triangles, rounder
        case needle            // 1 triangle
        case outline           // 24 triangles, a leaf of the scanned sheet traced (LeafOutline)
    }

    package static let goldenAngle: Float = 2.39996

    package struct LeafRecipe: Codable, Equatable {
        package var shape = LeafShape.kite
        package var length: Float = 0.1
        package var width: Float = 0.06
        package var sizeV: Float = 0.25
        package var perMetre: Float = 30            // along a twig
        package var start: Float = 0.1              // the first leaf sits this far along the twig
        package var angle: Float = 0.9              // from the twig's direction
        package var angleV: Float = 0.3
        package var phyllotaxis = Phyllotaxis.spiral
        package var fold: Float = 0.15              // the sides' lift over the midrib, in widths
        /// Size along the twig, of the size at its base (its end: the tip's leaf; fern pinnae shrink).
        package var size: Curve = .linear(1, 1)
        package var flutter: Float = 0.4            // how far the faces turn away from `up`, at random
        package var fromLevel = 0                   // leaves only on stems of this level and deeper
        /// Leaves at each place along a twig, fanned round it (a rosette, as a twig's cluster grows); nil or 1: one.
        /// (Optional, so species saved before it still decode.)
        package var cluster: Int?
        /// An outline leaf's scanned sheet (a TextureSet's name: its leaves' shapes and their texture); nil: "leaves".
        package var sheet: String?

        /// The sheet its leaves come from.
        package var sheetName: String { sheet ?? LeafOutline.defaultSheet }

        package init(shape: LeafShape = .kite, length: Float = 0.1, width: Float = 0.06, sizeV: Float = 0.25, perMetre: Float = 30,
             start: Float = 0.1, angle: Float = 0.9, angleV: Float = 0.3, phyllotaxis: Phyllotaxis = .spiral, fold: Float = 0.15,
             tipScale: Float = 1, flutter: Float = 0.4, fromLevel: Int = 0, cluster: Int? = nil, sheet: String? = nil) {
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
            self.cluster = cluster
            self.sheet = sheet
        }
    }

    // MARK: - Skeleton

    package struct Stem {
        var first: Int32                    // into Skeleton.nodes
        var count: Int32                    // nodes: 2 or more
        var parent: Int32                   // stem, -1 for level 0
        var limb: Int32                     // which level-1 stem it belongs to (-1: level 0)
        package var level: UInt8
        var radial: UInt8
        var length: Float
    }

    package struct Skeleton {
        package var nodes: [SIMD4<Float>] = []      // xyz position, w radius
        package var stems: [Stem] = []
        package var limbs = 0

        /// A stem at fraction `f` of its length.
        package func sample(_ s: Stem, _ f: Float) -> (position: SIMD3<Float>, tangent: SIMD3<Float>, radius: Float) {
            let x = min(max(f, 0), 1) * Float(s.count - 1)
            let i = min(Int(x), Int(s.count) - 2)
            let a = nodes[Int(s.first) + i], b = nodes[Int(s.first) + i + 1]
            let p = a + (b - a) * (x - Float(i))
            return (xyz(p), normalize(xyz(b) - xyz(a)), p.w)
        }
    }

    package struct LeafAnchor {
        var position: SIMD3<Float>
        var direction: SIMD3<Float>         // unit, base to tip
        var normal: SIMD3<Float>            // unit, across the direction
        var length: Float
        var width: Float
    }

    package static let minRadius: Float = 0.002

    @inline(__always) package static func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    /// Unit vector across `t`: across `up` too if it can be (horizontal for an upright plant).
    package static func perpendicular(_ t: SIMD3<Float>, up: SIMD3<Float>) -> SIMD3<Float> {
        let h = cross(up, t)
        let l = length_squared(h)
        if l > 1e-8 { return h / l.squareRoot() }
        return normalize(cross(abs(t.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1), t))
    }

    /// `t` turned by `down` away from itself, toward the side at `azimuth` around it (0 = across `up`).
    package static func direction(from t: SIMD3<Float>, down: Float, azimuth: Float, up: SIMD3<Float>) -> SIMD3<Float> {
        let a = perpendicular(t, up: up), b = cross(t, a)
        let radial = a * cos(azimuth) + b * sin(azimuth)
        return normalize(t * cos(down) + radial * sin(down))
    }

    package static func randomUnit(_ rng: inout SplitMix64) -> SIMD3<Float> {
        let z = rng.range(-1, 1), a = rng.range(0, 2 * .pi)
        let r = max(0, 1 - z * z).squareRoot()
        return SIMD3(r * cos(a), z, r * sin(a))
    }

    /// The seed of one piece of the library: the same for the same piece whatever else is built.
    package static func seed(_ base: UInt64, _ a: Int, _ b: Int, _ c: Int) -> UInt64 {
        var rng = SplitMix64(seed: base ^ (UInt64(a + 1) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(b + 1) &* 0xC2B2_AE3D_27D4_EB4F)
                             ^ (UInt64(c + 1) &* 0x1656_67B1_9E37_79F9))
        return rng.nextUInt64()
    }

    // MARK: - Foliage distributor

    /// Leaves along the stems of `leaf.fromLevel` and deeper, one more at each tip, in a shuffled order: any leading
    /// part of them is then a random sample of them all (leaf fall drops the rest).
    package static func leaves(on skeleton: Skeleton, _ leaf: LeafRecipe, up: SIMD3<Float>, rng: inout SplitMix64) -> [LeafAnchor] {
        var anchors: [LeafAnchor] = []
        var total = 0
        func count(_ s: Stem) -> Int { Int(s.length * (1 - leaf.start) * leaf.perMetre) }
        let cluster = max(1, leaf.cluster ?? 1)
        for s in skeleton.stems where Int(s.level) >= leaf.fromLevel { total += count(s) * cluster + 1 }
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
                // The rest of the place's cluster: fanned evenly round the twig, each a little smaller and steeper.
                for j in 1..<cluster {
                    let turn = azimuth + 2 * .pi * Float(j) / Float(cluster) + rng.range(-0.3, 0.3)
                    let fanned = Foliage.direction(from: at.tangent, down: max(0.05, down * rng.range(0.75, 1.1)), azimuth: turn, up: up)
                    place(at.position, fanned, size * rng.range(0.75, 0.95), &rng)
                }
            }
            let tip = skeleton.sample(s, 1)
            place(tip.position, tip.tangent, leaf.length * leaf.size.end * (1 + rng.range(-1, 1) * leaf.sizeV), &rng)
        }
        for i in stride(from: anchors.count - 1, to: 0, by: -1) { anchors.swapAt(i, rng.int(i + 1)) }
        return anchors
    }

    /// A card stands for a stretch of twig and its leaves: a rectangle from `base` to `top`, `half` to either side,
    /// showing one square of its species' card sheet (FoliageTextures.cardSheet), cut out by the sheet's alpha.
    package struct Card {
        var base: SIMD3<Float>
        var top: SIMD3<Float>
        var half: SIMD3<Float>
        var normal: SIMD3<Float>
        var cell: Int
    }

    /// The stretch of twig a card's picture shows, metres (in a twig's own space, before it is hung and scaled).
    package static let cardTwig: Float = 0.45

    /// Cards in place of `leaves(on:)`: two crossed along each stretch of about `cardTwig` of the stems that carry
    /// leaves, so that a twig shows its leaves from any side. Shuffled, as the leaves are (leaf fall drops whole cards).
    package static func cards(on skeleton: Skeleton, _ leaf: LeafRecipe, up: SIMD3<Float>, rng: inout SplitMix64) -> [Card] {
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
    package struct Bone {
        package var pivot: SIMD3<Float>             // plant space, at rest
        package var axis: SIMD3<Float>              // the stem's direction there
        package var parent: Int32                   // -1: the root (the whole plant about its foot)
        package var length: Float                   // of what it carries: longer and thinner sways more
        package var radius: Float
        package var phase: Float                    // 0...1, so that no two move together
        package var swing: Float = 1                // of a twig's turn: less on a bone many twigs share
    }

    package struct Part {
        package var mesh: Int                       // in the plant's own meshes, or the species' palette if `shared`
        package var shared: Bool
        package var transform: float4x4             // into plant space: a rotation, a uniform scale and a translation
        package var bone: Int
    }

    /// One variant of a species at an age. Bone 0 is the root; part 0 is the trunk.
    package struct Plant {
        package let species: Species
        package let age: Age
        package var meshes: [Mesh]
        package var parts: [Part]
        package var bones: [Bone]
        package var bounds: AABB
        package var height: Float { bounds.hi.y }
    }

    package struct SpeciesSet {
        package let species: Species
        package var palette: [Mesh]
        package var plants: [Plant]

        package func plants(of age: Age) -> [Int] { plants.indices.filter { plants[$0].age == age } }
    }

    /// The part's local frame for a twig along `dir`: +Y along it, +Z as far toward `up` as it goes.
    package static func graftTransform(at p: SIMD3<Float>, along dir: SIMD3<Float>, scale s: Float, up: SIMD3<Float>,
                               roll: Float) -> float4x4 {
        var z = up - dir * dot(up, dir)
        z = length_squared(z) < 1e-4 ? perpendicular(dir, up: up) : normalize(z)
        let x0 = cross(dir, z)
        // A little roll about the twig's own direction, so that the palette's few meshes don't all lie alike.
        let x = x0 * cos(roll) + z * sin(roll)
        let zr = cross(x, dir)
        return float4x4(columns: (SIMD4(x * s, 0), SIMD4(dir * s, 0), SIMD4(zr * s, 0), SIMD4(p, 1)))
    }

    /// Grows one plant of a built-in species. `palette`: the species' twig meshes (their bounds place the plant's).
    package static func plant(_ species: Species, age: Age, seed: UInt64, palette: [Mesh]) -> Plant {
        plant(PlantCatalog.builtIn[species], species, age: age, seed: seed, palette: palette)
    }

    /// Grows one plant of `def` (the species `species` of its catalog).
    package static func plant(_ def: SpeciesDef, _ species: Species, age: Age, seed: UInt64, palette: [Mesh], bark: Bark? = nil) -> Plant {
        PlantPrograms.runner(for: def).plant(species, age: age, seed: seed, palette: palette, bark: bark)
    }

    // MARK: - Library

    /// `count` values made by `make`, each in its own slot: in parallel, with nothing shared between them.
    package static func slots<T>(_ count: Int, parallel: Bool, _ make: (Int) -> T) -> [T] {
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
    /// `cards`: the twigs' leaves as cards.
    /// `bark`: by species, its bark's relief (the realistic look's, realism high: FoliageMesh.Bark).
    package static func library(seed: UInt64, catalog: PlantCatalog = .builtIn, species: [Species]? = nil, parallel: Bool = true,
                        cards: Bool = false, bark: [Species: Bark] = [:]) -> [SpeciesSet] {
        let species = species ?? catalog.all
        struct Job { var species: Species; var age: Age; var index: Int }
        var twigJobs: [Job] = [], plantJobs: [Job] = []
        for s in species {
            for i in 0..<catalog[s].paletteSize { twigJobs.append(Job(species: s, age: .mature, index: i)) }
            for age in Age.allCases { for i in 0..<catalog[s].variants(age) { plantJobs.append(Job(species: s, age: age, index: i)) } }
        }
        var runners: [PlantRunner?] = Array(repeating: nil, count: catalog.count)
        for s in species { runners[s.rawValue] = PlantPrograms.runner(for: catalog[s]) }
        let twigs = slots(twigJobs.count, parallel: parallel) { j -> Mesh in
            let job = twigJobs[j], def = catalog[job.species]
            return runners[job.species.rawValue]!.twig(job.species, variant: job.index, of: def.paletteSize, sparse: def.twigs?.sparse,
                                                       seed: Foliage.seed(seed, def.seedIndex, -1, job.index), cards: cards)
        }
        var palettes = [[Mesh]](repeating: [], count: catalog.count)
        for (j, job) in twigJobs.enumerated() { palettes[job.species.rawValue].append(twigs[j]) }
        let plants = slots(plantJobs.count, parallel: parallel) { j -> Plant in
            let job = plantJobs[j], def = catalog[job.species]
            return runners[job.species.rawValue]!.plant(job.species, age: job.age, seed: def.plantSeed(seed, job.age, job.index),
                                                        palette: palettes[job.species.rawValue], bark: bark[job.species])
        }
        return species.map { s in
            SpeciesSet(species: s, palette: palettes[s.rawValue],
                       plants: plantJobs.indices.filter { plantJobs[$0].species == s }.map { plants[$0] })
        }
    }
}
