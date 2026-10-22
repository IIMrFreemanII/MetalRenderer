import Foundation
import Plants

/// What the Debug window shows, as of the last stats tick (Renderer.debugInfo).
package struct DebugInfo {
    package enum VirtualGeometry {
        case off
        /// Per-instance BLAS over each instance's cut (VirtualBLAS, the default).
        case blas(meshes: Int, instances: Int, sourceTriangles: Int, triangles: Int, clusters: Int, megabytes: Double,
                  rebuilds: Int, lastBuildMs: Double, lastCutMs: Double, skipped: Int, busy: Bool)
        /// One structure over the frame's cut of clusters, streamed into a pool (VirtualGeometry, METALRENDERER_VG_MODE=clusters).
        case clusters(meshes: Int, instances: Int, clusters: Int, groups: Int, sourceTriangles: Int, triangles: Int, selected: Int,
                      capacity: Int, overflow: Bool, residentGroups: Int, residentMB: Double, poolMB: Int, pending: Int, loadedThisFrame: Int)

        /// Triangles traced this frame (the cut).
        package var triangles: Int {
            switch self {
            case .off: 0
            case let .blas(_, _, _, triangles, _, _, _, _, _, _, _): triangles
            case let .clusters(_, _, _, _, _, triangles, _, _, _, _, _, _, _, _): triangles
            }
        }
    }

    package var stats = ""
    package var cpuMs = 0.0                     // the CPU's frame interval, averaged
    package var encodeMs = 0.0                  // the CPU's own work per frame (simulation, uploads, encoding), averaged
    package var sceneTitle = ""
    package var instances = 0, virtualInstances = 0, triangles = 0
    package var analyticLights = 0, meshLights = 0, suns = 0
    package var lightTable = false, lightTableEntries = 0
    package var directMode = "", giMode = ""
    package var vg = VirtualGeometry.off
    package var vgPixelError: Float = 1
    package var vgFrozen = false
    package var lodFreezes = false              // Freeze LOD does something here (Renderer.lodFreezes)
    package var viewNote: String?               // why the view shown has nothing to show here (Renderer.viewNote)
    package var textures: (residentMB: Double, budgetMB: Int, levelsMapped: Int, uploadedMB: Double)?
    package var allocatedMB = 0.0, workingSetMB = 0.0
    package var traversal: (stats: TraversalStats, frames: Int)?

    /// (As the memberwise initializer, for the modules above this one.)
    package init(stats: String = "", cpuMs: Double = 0.0, encodeMs: Double = 0.0, sceneTitle: String = "", instances: Int = 0, virtualInstances: Int = 0, triangles: Int = 0, analyticLights: Int = 0, meshLights: Int = 0, suns: Int = 0, lightTable: Bool = false, lightTableEntries: Int = 0, directMode: String = "", giMode: String = "", vg: VirtualGeometry = VirtualGeometry.off, vgPixelError: Float = 1, vgFrozen: Bool = false, lodFreezes: Bool = false, viewNote: String? = nil, textures: (residentMB: Double, budgetMB: Int, levelsMapped: Int, uploadedMB: Double)? = nil, allocatedMB: Double = 0.0, workingSetMB: Double = 0.0, traversal: (stats: TraversalStats, frames: Int)? = nil) {
        self.stats = stats
        self.cpuMs = cpuMs
        self.encodeMs = encodeMs
        self.sceneTitle = sceneTitle
        self.instances = instances
        self.virtualInstances = virtualInstances
        self.triangles = triangles
        self.analyticLights = analyticLights
        self.meshLights = meshLights
        self.suns = suns
        self.lightTable = lightTable
        self.lightTableEntries = lightTableEntries
        self.directMode = directMode
        self.giMode = giMode
        self.vg = vg
        self.vgPixelError = vgPixelError
        self.vgFrozen = vgFrozen
        self.lodFreezes = lodFreezes
        self.viewNote = viewNote
        self.textures = textures
        self.allocatedMB = allocatedMB
        self.workingSetMB = workingSetMB
        self.traversal = traversal
    }
}
