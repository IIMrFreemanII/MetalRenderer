import Foundation
import simd

/// An object's multires levels (Blender's Multiresolution modifier, always first in the stack): the base mesh
/// subdivided by Catmull-Clark level by level, each level's shape that subdivision of the level below plus its own
/// displacements, in each point's tangent frame (so detail sculpted at a fine level rides along when a coarser level,
/// or the base in edit mode, is changed).
package struct MultiresData: Equatable {
    /// How many levels there are.
    package var levels: Int { displacements.count }
    /// The level sculpt mode edits, and the ones the viewport and a render show.
    package var sculptLevel = 0
    package var viewportLevel = 0
    package var renderLevel = 0
    /// Per level (1 first): each point's offset from the subdivided level below (tangent, bitangent, normal).
    package var displacements: [[SIMD3<Float>]] = []
    /// The base's topology the displacements are for (faces, corners): edits of its shape keep them, edits of its
    /// topology drop them.
    package var baseFaces = 0
    package var baseCorners = 0
    /// New on every change of the displacements (caches of the levels are filed under it).
    package var revision: UInt64 = 0

    package init() {}

    package mutating func changed() { revision = EditMesh.nextGeneration() }
}
