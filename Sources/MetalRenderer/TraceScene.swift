import Foundation
import Metal
import simd

/// What the virtual-geometry cut needs to know about the view each frame.
struct VGView {
    var camPos: SIMD3<Float>
    var pixelScale: Float       // traced height / (2 tan(fovY / 2))
    var tau: Float              // allowed error in traced pixels
    var frame: UInt32
}

/// The wind this frame (Shaders/Foliage.metal): where it blows to, how hard, how gusty; the animation time now and a frame ago.
struct WindFrame {
    var wind = SIMD4<Float>(1, 0, 0, 0)
    var time: Float = 0
    var previousTime: Float = 0
    var lodBias: Float = 0          // plants' voxels: 0 = never, 1 = from where a voxel is a traced pixel, 2 = sooner
    var leafFall: Float = 0         // the share of the leaves that have fallen (deciduous plants; each in its own time)

    /// Where the plants' limbs move in the wind (PlantTracing.writeDescriptors): the camera, on a grid, and how far from
    /// it (FoliageSettings.swayReach); 0 = everywhere. Farther plants name their variants at rest.
    var sway = SIMD4<Float>()

    /// What the plants' variants are posed for: the wind and, while it blows, the clock. A frame with the pose a slot
    /// was last posed for (time paused) has nothing to pose or refit.
    var poseKey: SIMD8<Float> {
        wind.z > 0 ? SIMD8(wind.x, wind.y, wind.z, wind.w, time, 0, 0, 0) : SIMD8<Float>()
    }

    /// What the plants' descriptors follow: the pose, the leaf fall and, in the wind, where the limbs move. A frame with
    /// the key a slot was last written for has nothing to write.
    struct PlantKey: Equatable {
        var pose: SIMD8<Float>
        var leafFall: Float
        var sway: SIMD4<Float>
    }
    var plantKey: PlantKey { PlantKey(pose: poseKey, leafFall: leafFall, sway: wind.z > 0 ? sway : SIMD4()) }
}

/// Totals of the ray queries' counters (RT_STATS builds: Shaders/Intersect.metal, `countedHit`), per class of ray (what
/// it is for: MSL `rayMask`): 0 rays, 1 triangles and 2 boxes Metal's traversal handed to the queries' loop (every
/// triangle counts as a candidate in those builds: Metal can't count its nodes, so the candidates are what the counters
/// can see of its work), 3 unused.
struct TraversalStats {
    /// MSL RAY_CAMERA ... RAY_LIGHTMAP.
    static let classes = ["camera", "shadow", "GI", "specular", "far", "light map"]
    static let counters = 4
    static let count = counters * classes.count
    var counts = [UInt64](repeating: 0, count: TraversalStats.count)

    static func + (a: TraversalStats, b: TraversalStats) -> TraversalStats {
        TraversalStats(counts: zip(a.counts, b.counts).map { $0 + $1 })
    }
    /// Counter `i` over every class.
    func total(_ i: Int) -> UInt64 { (0..<Self.classes.count).reduce(0) { $0 + counts[$1 * Self.counters + i] } }
    var rays: Double { Double(total(0)) }
    /// Counter `i` per ray.
    func perRay(_ i: Int) -> Double { Double(total(i)) / max(rays, 1) }
    /// Class `c`'s counters alone.
    func of(_ c: Int) -> TraversalStats {
        var one = TraversalStats()
        for i in 0..<Self.counters { one.counts[c * Self.counters + i] = counts[c * Self.counters + i] }
        return one
    }

    private var line: String {
        String(format: "rays %.0fk: per ray %.1f triangle candidates, %.2f box candidates", max(rays, 1) / 1000, perRay(1), perRay(2))
    }
    /// All rays, then each class that traced any.
    var description: String {
        ([line] + Self.classes.indices.compactMap { c in
            let one = of(c)
            return one.rays > 0 ? "  \(Self.classes[c]): " + one.line : nil
        }).joined(separator: "\n")
    }
}

/// The scene as every ray-tracing kernel gets it at buffer 1 (MSL `TraceScene`, Shaders/Intersect.metal): Metal's
/// top-level structure and what a hit reads besides the instance records. One per frame slot, written every frame
/// (`write`), as its top-level structure and its virtual geometry's tables are the slot's own.
final class TraceSceneArgs {
    static let size = 208
    /// The ray queries' counters (RT_STATS: METALRENDERER_RT_STATS=1, or the Debug window's toggle, which recompiles
    /// the shaders): see TraversalStats.
    static var statsEnabled = ProcessInfo.processInfo.environment["METALRENDERER_RT_STATS"] == "1"

    let buffers: [MTLBuffer]
    let stats: MTLBuffer
    private let dummy: MTLBuffer

    init(device: MTLDevice, slots: Int) throws {
        var made: [MTLBuffer] = []
        for slot in 0..<slots {
            guard let b = device.makeBuffer(length: TraceSceneArgs.size, options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer traceScene\(slot)")
            }
            b.label = "traceScene\(slot)"
            memset(b.contents(), 0, b.length)
            made.append(b)
        }
        guard let stats = device.makeBuffer(length: 4 * TraversalStats.count, options: .storageModeShared),
              let dummy = device.makeBuffer(length: 64, options: .storageModeShared) else {
            throw RendererError.resourceCreation("buffer traceStats")
        }
        memset(stats.contents(), 0, stats.length)
        memset(dummy.contents(), 0, dummy.length)
        stats.label = "traceStats"
        dummy.label = "traceDummy"
        (buffers, self.stats, self.dummy) = (made, stats, dummy)
    }

    /// What `slot`'s frame reads besides the structures: virtual geometry's tables (the cut's clusters or the
    /// raster's, their pool), the plants' parts, the wind, and what a leaf card's alpha test reads (the mesh table and
    /// the arrays, the alpha layers).
    struct Content {
        var tlas: MTLAccelerationStructure
        var vgTable: MTLBuffer?
        var clusters: MTLBuffer?
        var pool: MTLBuffer?
        var parts: MTLBuffer?
        var meshes: MTLBuffer?
        var indices: MTLBuffer?
        var uvs: MTLBuffer?
        var wind = WindFrame()
        var cutouts: MTLBuffer?
        var clusterInstance = UInt32.max
        /// The particles' structures this slot (the shadow casters', the others'), their records and flipbooks
        /// (ParticlesGPU), and how many slots each covers.
        var particleCasters: MTLAccelerationStructure?
        var particleOthers: MTLAccelerationStructure?
        var particleRender: MTLBuffer?
        var particleAtlas: MTLTexture?
        var particleCounts = SIMD2<UInt32>()
        var particleFlags: UInt32 = 0   // MSL PARTICLES_REFLECTED
        /// The trails' structure this slot, their control points and records, and (trails, control points each).
        var particleTrails: MTLAccelerationStructure?
        var trailPoints: MTLBuffer?
        var trailRecords: MTLBuffer?
        var trailShape = SIMD2<UInt32>()
        var frame: UInt32 = 0
    }

    /// Writes `slot`'s scene (the CPU writes a slot only once the GPU is done with its last frame).
    func write(slot: Int, _ c: Content) {
        let p = buffers[slot].contents()
        func address(_ b: MTLBuffer?) -> UInt64 { (b ?? dummy).gpuAddress }
        p.storeBytes(of: c.tlas.gpuResourceID, toByteOffset: 0, as: MTLResourceID.self)
        p.storeBytes(of: address(c.vgTable), toByteOffset: 8, as: UInt64.self)
        p.storeBytes(of: address(c.clusters), toByteOffset: 16, as: UInt64.self)
        p.storeBytes(of: address(c.pool), toByteOffset: 24, as: UInt64.self)
        p.storeBytes(of: address(c.parts), toByteOffset: 32, as: UInt64.self)
        p.storeBytes(of: address(c.meshes), toByteOffset: 40, as: UInt64.self)
        p.storeBytes(of: c.wind.wind, toByteOffset: 48, as: SIMD4<Float>.self)
        p.storeBytes(of: SIMD4(c.wind.time, c.wind.previousTime, 0, c.wind.leafFall), toByteOffset: 64, as: SIMD4<Float>.self)
        p.storeBytes(of: address(c.cutouts), toByteOffset: 80, as: UInt64.self)
        p.storeBytes(of: c.clusterInstance, toByteOffset: 88, as: UInt32.self)
        p.storeBytes(of: stats.gpuAddress, toByteOffset: 96, as: UInt64.self)
        p.storeBytes(of: address(c.indices), toByteOffset: 104, as: UInt64.self)
        p.storeBytes(of: address(c.uvs), toByteOffset: 112, as: UInt64.self)
        p.storeBytes(of: c.frame, toByteOffset: 120, as: UInt32.self)
        p.storeBytes(of: c.particleCasters?.gpuResourceID ?? MTLResourceID(), toByteOffset: 128, as: MTLResourceID.self)
        p.storeBytes(of: c.particleOthers?.gpuResourceID ?? MTLResourceID(), toByteOffset: 136, as: MTLResourceID.self)
        p.storeBytes(of: address(c.particleRender), toByteOffset: 144, as: UInt64.self)
        p.storeBytes(of: c.particleAtlas?.gpuResourceID ?? MTLResourceID(), toByteOffset: 152, as: MTLResourceID.self)
        p.storeBytes(of: c.particleCounts, toByteOffset: 160, as: SIMD2<UInt32>.self)
        p.storeBytes(of: c.particleFlags, toByteOffset: 168, as: UInt32.self)
        p.storeBytes(of: c.particleTrails?.gpuResourceID ?? MTLResourceID(), toByteOffset: 176, as: MTLResourceID.self)
        p.storeBytes(of: address(c.trailPoints), toByteOffset: 184, as: UInt64.self)
        p.storeBytes(of: address(c.trailRecords), toByteOffset: 192, as: UInt64.self)
        p.storeBytes(of: c.trailShape, toByteOffset: 200, as: SIMD2<UInt32>.self)
    }

    /// What the frames finished since the last read added (in-flight ones in part): read while frames run.
    func readCounters() -> [UInt32] {
        let c = stats.contents().bindMemory(to: UInt32.self, capacity: TraversalStats.count)
        return (0..<TraversalStats.count).map { c[$0] }
    }

    /// Counter totals since the last call (then resets them). Only with the GPU idle (benchmarks wait for each frame).
    func takeStats() -> TraversalStats {
        let c = stats.contents().bindMemory(to: UInt32.self, capacity: TraversalStats.count)
        let out = TraversalStats(counts: (0..<TraversalStats.count).map { UInt64(c[$0]) })
        memset(stats.contents(), 0, stats.length)
        return out
    }
}
