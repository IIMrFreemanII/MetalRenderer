import Foundation
import simd

/// Where a species grows: for a tree, its weight against the other trees at a place (conifers up the hills, oaks on
/// low ground, birches where the light comes in); for a bush or ground cover, how thickly and in what patches. The
/// forest (Scene+Forest.swift) and the open world (World.swift) both place by these; the built-in species' values
/// are the formulas those had, and give the same plants in the same places.
extension Foliage {
    struct Habitat: Codable, Equatable {
        /// Where its weight is reckoned among the others' (the built-in trees: 0...3), and where it is scattered among
        /// the covers: a place's pick runs through them in this order.
        var order = 100
        /// Of its weight wherever it is (a cover: of its density).
        var frequency: Float = 1

        // A tree's weight: base + elevation + slope + stand + light, at least `floor`, times `frequency`.
        var base: Float = 0.5
        /// `gain` x smoothstep(from, to, height): the height is 0 on the low ground, 1 up the hills.
        var elevation = Ramp()
        var slope: Float = 0                // x the ground's slope (0 flat, 1 a wall)
        var stand: Float = 0                // x the stand noise (-1...1: patches where one species or another grows)
        var light: Float = 0                // x where the light comes in: clearings, the woods' edges, the trail
        var floor: Float = 0.05
        /// A share of all the trees whatever the place (the dead trees: 3.5%), in place of a weight.
        var share: Float? = nil
        /// A tree is a sapling below `x` of a random 0...1, young below `y`, mature above.
        var ages = SIMD2<Float>(0.12, 0.4)

        /// A bush's or ground cover's spread (nil for a tree).
        var cover: Cover? = nil

        struct Ramp: Codable, Equatable {
            var gain: Float = 0
            var from: Float = 0
            var to: Float = 0.7
        }

        struct Cover: Codable, Equatable {
            /// The forest's candidates at undergrowth 100%.
            var count: Float = 2000
            /// The open world's: one candidate to a cell of this many metres.
            var cell: Double = 5
            var patch: Float = 20               // the patches' size, metres
            var salt: UInt32 = 0                // the patches' noise
            var what: UInt64 = 0                // the open world's candidates' random numbers
            var size: ClosedRange<Float> = 0.8...1.3
            var sink: Float = 0.03              // into the ground
            /// In the open (the clearing, meadows) rather than in patches under the trees.
            var open = false
            /// The forest's: on a grid of this many metres, laid on the slope, scaled by `gridScale` (grass), instead
            /// of `count` scattered.
            var grid: Int? = nil
            var gridScale: Float = 1.12
        }

        /// The weight at a place. `light`: the scene's terms for where light comes in, each a coefficient and a value
        /// (summed in order, each times `self.light`).
        func weight(high: Float, slope: Float, stand: Float, light terms: [SIMD2<Float>]) -> Float {
            var w = base + elevation.gain * Habitat.smoothstep(elevation.from, elevation.to, high)
            w = w + self.slope * slope
            w = w + self.stand * stand
            for t in terms { w = w + light * t.x * t.y }
            return max(floor, w) * frequency
        }

        @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
    }

    /// Picks a tree's species from the catalog's trees by their weights at a place.
    struct TreePicker {
        private let weighted: [(species: Species, habitat: Habitat)]
        private let shared: [(species: Species, share: Float)]
        private let scale: Float

        init(_ catalog: PlantCatalog) {
            let trees = catalog.all.filter { catalog[$0].role == .tree }
                .sorted { (catalog[$0].habitat.order, $0.rawValue) < (catalog[$1].habitat.order, $1.rawValue) }
            weighted = trees.filter { catalog[$0].habitat.share == nil }.map { ($0, catalog[$0].habitat) }
            shared = trees.compactMap { s in catalog[s].habitat.share.map { (s, $0) } }
            scale = shared.reduce(1) { $0 + $1.share }
        }

        var isEmpty: Bool { weighted.isEmpty && shared.isEmpty }

        /// `r`: a random 0...1.
        func pick(_ r: Float, high: Float, slope: Float, stand: Float, light: [SIMD2<Float>]) -> Species? {
            var weights: [Float] = []
            weights.reserveCapacity(weighted.count)
            var total: Float = 0
            for t in weighted {
                let w = t.habitat.weight(high: high, slope: slope, stand: stand, light: light)
                weights.append(w)
                total += w
            }
            var p = r * total * scale
            for (k, t) in weighted.enumerated() {
                if p < weights[k] { return t.species }
                p -= weights[k]
            }
            for (k, t) in shared.enumerated() {
                if k == shared.count - 1 || p < total * t.share { return t.species }
                p -= total * t.share
            }
            return weighted.last?.species
        }

        /// The age of a tree of `species`, from a random 0...1.
        static func age(_ u: Float, _ habitat: Habitat) -> Age { u < habitat.ages.x ? .sapling : u < habitat.ages.y ? .young : .mature }
    }
}
