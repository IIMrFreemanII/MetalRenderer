import Foundation
import simd

/// One modifier of an object's stack: what it does to the mesh after the ones above it, and where it shows.
package struct Modifier: Codable, Equatable, Identifiable {
    package enum Kind: String, Codable, CaseIterable {
        case mirror, array, solidify, subdivision, bevel, boolean, triangulate, weld

        package var title: String {
            switch self {
            case .mirror: "Mirror"
            case .array: "Array"
            case .solidify: "Solidify"
            case .subdivision: "Subdivision Surface"
            case .bevel: "Bevel"
            case .boolean: "Boolean"
            case .triangulate: "Triangulate"
            case .weld: "Weld"
            }
        }

        package var symbol: String {
            switch self {
            case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
            case .array: "square.on.square"
            case .solidify: "square.3.layers.3d"
            case .subdivision: "circle.grid.3x3"
            case .bevel: "square.dashed"
            case .boolean: "square.on.circle"
            case .triangulate: "triangle"
            case .weld: "link"
            }
        }
    }

    package enum BooleanOperation: String, Codable, CaseIterable { case difference, union, intersect }
    package enum BooleanSolver: String, Codable, CaseIterable { case exact, voxel }

    package var id = UUID()
    package var kind: Kind
    package var name: String
    package var showInViewport = true
    package var showInRender = true
    package var showInEditMode = true
    package var showOnCage = false

    // Mirror
    package var axes: [Bool] = [true, false, false]
    package var bisect: [Bool] = [false, false, false]
    package var clipping = false
    package var mergeDistance: Float = 0.001
    package var merge = true
    // Array
    package var count = 2
    package var relativeOffset: SIMD3<Float> = [1, 0, 0]
    package var constantOffset: SIMD3<Float> = .zero
    package var useRelative = true
    package var useConstant = false
    package var mergeEnds = false
    // Solidify
    package var thickness: Float = 0.01
    package var offset: Float = -1
    package var evenThickness = false
    package var fillRim = true
    // Subdivision
    package var levels = 1
    package var renderLevels = 2
    package var useCreases = true
    // Bevel (also: segments)
    package var width: Float = 0.1
    package var segments = 1
    package var angleLimit: Float = 30 * .pi / 180
    // Boolean
    package var operation: BooleanOperation = .difference
    package var solver: BooleanSolver = .exact
    package var operand: UUID?
    package var voxelSize: Float = 0.02

    package init(_ kind: Kind) {
        self.kind = kind
        name = kind.title
        if kind == .bevel { width = 0.1; segments = 1 }
        if kind == .weld { mergeDistance = 0.001 }
    }
}
