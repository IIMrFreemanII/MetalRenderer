import EngineCore
import simd

/// What travels along a program's wires.

/// A plant being grown, its branches still points.
package struct Growing {
    var plant: Growth.Plant
}

/// A plant's branches as stems, ready for wood, leaves and twigs.
package struct PlantSkeleton {
    package private(set) var skeleton: Foliage.Skeleton
    package let wood: Growth.Wood
    package let up: SIMD3<Float>                    // unit
    package let axis: SIMD3<Float>?                 // unit
    let stemOf: [Int32]
    private(set) var placed: [SIMD3<Float>]
    let plant: Growth.Plant
    let rootPhase: Float

    /// Every point of the stems (and what hangs on them: `placed`) moved, for a Swift Code node.
    package mutating func moveStems(_ move: (inout SIMD3<Float>) -> Void) {
        for i in skeleton.nodes.indices {
            var at = Foliage.xyz(skeleton.nodes[i])
            move(&at)
            skeleton.nodes[i] = SIMD4(at, skeleton.nodes[i].w)
        }
        for i in placed.indices { move(&placed[i]) }
    }

    /// How lit each stem is (its points' mean light, 0...1), for the workshop's light view.
    package var light: [Float] {
        var light = [Float](repeating: 1, count: skeleton.stems.count)
        for (b, branch) in plant.branches.enumerated() where stemOf[b] >= 0 && !branch.points.isEmpty {
            light[Int(stemOf[b])] = branch.points.reduce(0) { $0 + plant.points[Int($1)].light } / Float(branch.points.count)
        }
        return light
    }
}

/// Leaves to set on a skeleton. Only the stage that makes a mesh of them sets them: what it draws from the context's
/// random numbers is drawn then.
package struct LeafSet {
    let recipe: Foliage.LeafRecipe
}

/// A species' twigs, in a plant's program: the palette the plant was given.
package struct TwigPalette {}

/// Where a plant's twigs hang.
package struct TwigPlacement {
    let places: [Growth.TwigPlace]
}
