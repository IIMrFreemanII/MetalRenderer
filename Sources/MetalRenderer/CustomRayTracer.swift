import Foundation
import Metal
import QuartzCore
import simd

/// Per-instance data the custom traversal reads (MSL `RTInstance`): world -> object rows and the mesh's BLAS root.
struct RTInstance {
    var row0 = SIMD4<Float>()     // rows of inverse(transform): object point = (dot(row0, p1), dot(row1, p1), dot(row2, p1))
    var row1 = SIMD4<Float>()
    var row2 = SIMD4<Float>()
    var blasRoot: UInt32 = 0
    var pad0: UInt32 = 0
    var mask: UInt32 = 0
    var pad1: UInt32 = 0
}

/// A part of an assembly as the traversal reads it (MSL `RTPart`): plant -> part rows, the part mesh's BLAS root, and
/// what shading needs (the mesh, where its leaves start, its bone).
struct RTPart {
    var row0 = SIMD4<Float>()
    var row1 = SIMD4<Float>()
    var row2 = SIMD4<Float>()
    var blasRoot: UInt32 = 0
    var mesh: UInt32 = 0
    var firstLeaf: UInt32 = 0
    var leafCount: UInt32 = 0       // the mesh's leaf triangles, which autumn drops (0 = evergreen)
    var limb = SIMD4<Float>()       // the wind's bones: pivot and largest turn, axis and phase (Scene.Assembly.Bone)
    var limbAxis = SIMD4<Float>()
    var bough = SIMD4<Float>()
    var boughAxis = SIMD4<Float>()
}

/// The wind this frame (Shaders/Foliage.metal): where it blows to, how hard, how gusty; the animation time now and a frame ago.
struct WindFrame {
    var wind = SIMD4<Float>(1, 0, 0, 0)
    var time: Float = 0
    var previousTime: Float = 0
    var lodBias: Float = 0          // plants' voxels: 0 = never, 1 = from where a voxel is a traced pixel, 2 = sooner
    var leafFall: Float = 0         // the share of the leaves that have fallen (deciduous plants; each in its own time)
}

/// Kernels that build the dynamic TLAS (Shaders/BVHBuild.metal).
struct RTPipelines {
    let prep, keys, sortLocal, sortGlobal, hierarchy, fit: MTLComputePipelineState
    let crowdRefit: MTLComputePipelineState   // the crowd's pose slots: their bottom-level trees, every frame
    let vg: VGPipelines
}

/// Where the LBVH kernels read their leaf count and sort size: set by the CPU, or written by an earlier kernel.
enum LBVHCounts {
    case bytes(SIMD2<UInt32>)
    case buffer(MTLBuffer)
}

/// What the virtual-geometry cut needs to know about the view each frame.
struct VGView {
    var camPos: SIMD3<Float>
    var pixelScale: Float       // traced height / (2 tan(fovY / 2))
    var tau: Float              // allowed error in traced pixels
    var frame: UInt32
}

/// The custom ray tracer's scene: per-mesh BLASes and the static TLAS (built once on the CPU), and per frame slot the
/// dynamic TLAS over moving instances plus the `RTScene` argument buffer every ray-tracing kernel gets at buffer 1.
/// See BVH.swift for the node format.
///
/// The dynamic TLAS is rebuilt from scratch every frame on the GPU as an LBVH (Karras 2012): moving instances are
/// sorted along a Morton curve and the tree follows from the sorted keys, all in parallel. `METALRENDERER_RT_BUILD=cpu`
/// builds it on the CPU with binned SAH instead (a better tree, for comparing trace speed).
/// Totals of the custom tracer's traversal counters (RT_COUNT in Shaders/Intersect.metal): 0 rays, 1 top nodes, 2 bottom nodes,
/// 3 instance entries, 4 cluster entries, 5 triangle tests, 6 top nodes inside virtual instances, 7 pushes the full
/// traversal stack turned away (each one a subtree a ray skipped: RT_STACK is then too small for the scene's trees).
struct TraversalStats {
    static let count = 8
    var counts = [UInt64](repeating: 0, count: TraversalStats.count)
    var stackOverflows: UInt64 { counts[7] }

    static func + (a: TraversalStats, b: TraversalStats) -> TraversalStats {
        TraversalStats(counts: zip(a.counts, b.counts).map { $0 + $1 })
    }
    var rays: Double { Double(counts[0]) }
    /// Counter `i` per ray.
    func perRay(_ i: Int) -> Double { Double(counts[i]) / max(rays, 1) }

    var description: String {
        String(format: "rays %.0fk: per ray %.1f top nodes (%.1f inside virtual instances), %.1f bottom nodes, %.2f instance entries, %.2f cluster entries, %.1f triangle tests",
               max(rays, 1) / 1000, perRay(1), perRay(6), perRay(2), perRay(3), perRay(4), perRay(5))
            + (stackOverflows > 0 ? ", \(stackOverflows) STACK OVERFLOWS (rays skipped subtrees: raise RT_STACK)" : ", no stack overflows")
    }
}

final class CustomRayTracer {
    private let device: MTLDevice
    var pipelines: RTPipelines!   // set by the renderer once the custom-RT shaders are compiled
    /// `METALRENDERER_RT_CHECK=1`: a new tracer checks its trees against a CPU traversal of them (`selfTest`).
    static let checked = ProcessInfo.processInfo.environment["METALRENDERER_RT_CHECK"] == "1"
    static let cpuBuild = ProcessInfo.processInfo.environment["METALRENDERER_RT_BUILD"] == "cpu"
    let blasNodes: MTLBuffer
    let triangles: MTLBuffer
    /// The trees that are in buffers of their own (the borrowed meshes': MeshBlock.Tree), and their addresses, which
    /// rtPrepKernel writes into their instances' records.
    private let blockTrees: [MTLBuffer]
    private let blockTable: MTLBuffer
    /// The scene's blocks of instances (InstanceBlock): their trees are parts of the top-level tree, their nodes
    /// after the static ones; their instances are counted after the scene's own, as their records are in the
    /// scene's buffer.
    private let tileNodes: Int
    private let tileInstances: Int
    private let firstAssembly: Int                // in the mesh table: where a block's record's assembly is
    private static let tilePart = 0x2000_0000     // (while the top-level tree is built: a leaf that is a part of a block)
    private var tlasNodes: [MTLBuffer] = []       // per slot: static TLAS nodes, then the dynamic TLAS
    private var instances: [MTLBuffer] = []       // per slot: RTInstance per scene instance
    private var sceneArgs: [MTLBuffer] = []       // per slot: RTScene
    private let staticNodes: [BVHNode]
    private let staticRoot: UInt32
    private let dynamicIds: [Int]                 // scene instances that can move (animated objects, light spheres)
    private let blasRoots: [UInt32]
    private let meshBounds: [AABB]                // as their instances' boxes are made from: ground cover's with room to lean
    private let swayingMeshes: [Bool]
    static let sways: UInt32 = 0x80_0000          // RT_SWAYS in RTInstance.pad1
    /// Assemblies (generated plants): a tree over each one's parts, kept after the static trees in the top-level node
    /// buffer (in the plant's space, shared by all its instances), and every part's record.
    private let assemblyRoots: [UInt32]
    private let assemblyBounds: [AABB]
    private let parts: MTLBuffer
    /// The parts' boxes at rest and how far the full wind moves each; the assemblies' nodes are refitted to the
    /// wind's strength (`fitAssemblies`), a slot at a time.
    private let partBoxes: [AABB]
    private let partPads: [Float]
    private let assemblyNodes: Range<Int>         // in the static nodes
    private var fittedNodes: [BVHNode] = []       // the assemblies' nodes for `fittedWind`
    private var fittedWind: Float = 0
    private var slotWind: [Float]
    /// The assemblies as voxel grids, for the ones far from the camera (FoliageVoxels).
    private let voxelGrids: MTLBuffer
    private let voxels: MTLBuffer
    /// The leaf cards' alpha layers, one after another (Scene.cutouts): a byte a texel.
    private let cutouts: MTLBuffer
    /// The RTScene record: its fields end at 168 bytes (176 with its alignment) (Shaders/Intersect.metal asserts it); the rest is spare.
    private static let argsSize = 256
    private let cpu: (blas: BVHBuilder.BLASResult, tris: [SIMD4<Float>])?  // kept for the self-test, where there is one
    // GPU build inputs and scratch (shared by the frame slots: Metal orders the passes that use them).
    private let meshInfo: MTLBuffer               // per mesh: (box min, BLAS root bits), (box max, RTInstance.pad1 bits)
    private let dynSlot: MTLBuffer                // per instance: index among the moving ones, or ~0
    private let leafBoxes: MTLBuffer              // per moving instance: (min, instance id bits), (max, mask bits)
    private let keys: MTLBuffer, values: MTLBuffer
    private let nodeParent: MTLBuffer, leafParent: MTLBuffer, counters: MTLBuffer
    private let instanceCount: Int
    private let paddedCount: Int                  // moving instances rounded up to a power of two (sort size)
    /// Virtual meshes, if the scene has any. Default: each virtual instance traced through an SAH BLAS over its
    /// current cut (VirtualBLAS). METALRENDERER_VG_MODE=clusters: a third top-level tree over this frame's cut of clusters,
    /// selected and streamed on the GPU (VirtualGeometry).
    let virtualGeometry: VirtualGeometry?
    let virtualBLAS: VirtualBLAS?
    static let clusterMode = ProcessInfo.processInfo.environment["METALRENDERER_VG_MODE"] == "clusters"
    /// The crowd's pose slots (Crowd): their bottom-level trees keep the shape they were built with and are refitted
    /// to the skinned vertices every frame (crowdRefitKernel). `links`: per node its parent and its mesh; `arrived`:
    /// the kernel's counters.
    private var crowdRefit: (links: MTLBuffer, arrived: MTLBuffer, nodeBase: Int, nodeCount: Int, meshes: ClosedRange<Int>)?
    private var refitTag: UInt32 = 0
    /// MSL CrowdRefitParams.
    private struct RefitParams { var nodeBase: UInt32, nodeCount: UInt32, tag: UInt32, pad: UInt32 = 0 }
    private let dummy: MTLBuffer                  // stands in for the virtual-geometry buffers without any
    /// Traversal counters (compiled in with RT_STATS: METALRENDERER_RT_STATS=1, or the Debug window's toggle, which
    /// recompiles the shaders): rays, top-level nodes, bottom-level nodes, instance entries, cluster entries, triangle tests.
    let stats: MTLBuffer
    static var statsEnabled = ProcessInfo.processInfo.environment["METALRENDERER_RT_STATS"] == "1"

    /// Root ref of the dynamic TLAS: its first node when it has 2+ instances, the instance itself when it has one.
    private var dynamicRoot: UInt32 {
        dynamicIds.isEmpty ? BVHNode.none : dynamicIds.count == 1 ? BVHNode.leafBit | UInt32(dynamicIds[0]) : UInt32(dynamicNodeBase)
    }

    /// The first node of the dynamic tree: after the static nodes and the blocks'.
    private var dynamicNodeBase: Int { staticNodes.count + tileNodes }
    /// The first node of this frame's cluster tree (after the static and dynamic trees).
    private var virtualNodeBase: Int { dynamicNodeBase + max(dynamicIds.count - 1, 1) }

    /// A mesh's root that is not a node of `blasNodes` but, with this bit, the mesh's place among the trees that are
    /// in buffers of their own (RT_BLOCK in Shaders/Intersect.metal); and what an instance of such a mesh has in its
    /// mask (RT_OWN_TREE), its tree's address being where its root and `pad0` are.
    static let blockRoot: UInt32 = 0x4000_0000, ownTree: UInt32 = 0x8000_0000

    /// The meshes' trees: the arrays' meshes' in one result, and each borrowed mesh's with its block (MeshBlock.tree:
    /// built here if this is the first scene to trace it), its root the block's place in `blocks`.
    private static func trees(of scene: Scene, geometry: SceneBuffers?, device: MTLDevice) throws
        -> (blas: BVHBuilder.BLASResult, geometry: String?, cached: Bool, blocks: [MeshBlock.Tree], new: Int, copied: Int) {
        guard scene.hasBorrowedMeshes else {
            let trees = BVHBuilder.cachedBLAS(positions: scene.positions, indices: scene.indices, meshes: scene.meshes, uvs: scene.uvs)
            return (trees.blas, trees.geometry, trees.cached, [], 0, 0)
        }
        guard let blocks = geometry?.blocks, blocks.count == scene.meshes.count else {
            throw RendererError.resourceCreation("the trees of a scene with borrowed meshes, without its buffers")
        }
        var meshes = scene.meshes
        for m in meshes.indices where blocks[m] != nil { meshes[m].indexCount = 0 }   // not in the arrays
        var trees = BVHBuilder.cachedBLAS(positions: scene.positions, indices: scene.indices, meshes: meshes, uvs: scene.uvs)
        let own = blocks.indices.filter { blocks[$0] != nil }
        let new = own.reduce(0) { $0 + (blocks[$1]!.hasTree ? 0 : 1) }
        let copied = own.reduce(0) { $0 + (blocks[$1]!.hasBorrowedTree ? 1 : 0) }   // (not built: their tiles' files have them)
        var built = [MeshBlock.Tree?](repeating: nil, count: own.count)
        built.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: own.count) { k in
                out[k] = try? blocks[own[k]]!.tree(device: device, cutout: scene.meshes[own[k]].cutout)
            }
        }
        for (entry, m) in own.enumerated() {
            guard let tree = built[entry] else { throw RendererError.resourceCreation("the tree of mesh \(m)") }
            trees.blas.roots[m] = tree.nodeCount == 0 ? BVHNode.none : CustomRayTracer.blockRoot | UInt32(entry)
            trees.blas.bounds[m] = tree.bounds
            trees.blas.maxDepth = max(trees.blas.maxDepth, tree.depth)
        }
        return (trees.blas, trees.geometry, trees.cached, built.map { $0! }, new, copied)
    }

    /// `instances`: a copy of `scene.instances` taken on the render thread when this runs in the background for a scene
    /// that is still being drawn (`Scene.update` rewrites the transforms there every frame).
    /// `geometry`: the scene's buffers, which have the blocks of its borrowed meshes (its arrays hold only the
    /// others).
    init(device: MTLDevice, scene: Scene, instances sceneInstances: [Scene.Instance]? = nil, geometry sceneGeometry: SceneBuffers? = nil, slots: Int,
         poolMB: Int = 768) throws {
        self.device = device
        let sceneInstances = sceneInstances ?? scene.instances
        let start = CACurrentMediaTime()
        let (blas, geometryHash, cached, blocks, newBlocks, copiedBlocks) = try CustomRayTracer.trees(of: scene, geometry: sceneGeometry, device: device)
        blasRoots = blas.roots
        // An instance's box is its mesh's; ground cover's with room to lean as far as the strongest wind takes it, and
        // a pose slot's (its mesh deforms) that of every pose: on the CPU, the GPU keeps the exact ones.
        var instanceBounds = blas.bounds
        for (m, mesh) in scene.meshes.enumerated() where mesh.sways != 0 {
            let reach = Scene.coverLean * max(abs(instanceBounds[m].lo.y), abs(instanceBounds[m].hi.y))
            instanceBounds[m].lo -= SIMD3(reach, 0, reach)
            instanceBounds[m].hi += SIMD3(reach, 0, reach)
        }
        for s in scene.crowd?.slots ?? [] { instanceBounds[s.mesh] = scene.localBounds(mesh: s.mesh) }
        meshBounds = instanceBounds
        swayingMeshes = scene.meshes.map { $0.sways != 0 }
        cpu = CustomRayTracer.checked ? (blas, blas.triangles) : nil

        // Static instances in two groups: the geometry, and the proxies of lights that stay in place (thousands of bulbs
        // in the market).
        struct Group { var boxes: [AABB] = [], ids: [Int] = [], masks: [UInt32] = [] }
        var geometry = Group(), proxies = Group(), dyn: [Int] = []
        var virtualInstances: [(instance: Int, mesh: Int)] = []
        // Each assembly's parts: their records, and their boxes in the plant's space.
        var partRecords: [RTPart] = []
        var partBoxes: [[AABB]] = []
        var plantBounds: [AABB] = []
        var pads: [Float] = []
        for assembly in scene.assemblies {
            var boxes: [AABB] = [], all = AABB()
            for part in assembly.parts {
                let inv = part.transform.inverse
                partRecords.append(RTPart(row0: SIMD4(inv[0][0], inv[1][0], inv[2][0], inv[3][0]),
                                          row1: SIMD4(inv[0][1], inv[1][1], inv[2][1], inv[3][1]),
                                          row2: SIMD4(inv[0][2], inv[1][2], inv[2][2], inv[3][2]),
                                          blasRoot: blas.roots[part.mesh], mesh: UInt32(part.mesh), firstLeaf: part.firstLeaf,
                                          leafCount: part.leafCount,
                                          limb: SIMD4(part.limb.pivot, part.limb.angle), limbAxis: SIMD4(part.limb.axis, part.limb.phase),
                                          bough: SIMD4(part.bough.pivot, part.bough.angle), boughAxis: SIMD4(part.bough.axis, part.bough.phase)))
                boxes.append(part.bounds)
                pads.append(part.windPad)
                all.grow(part.bounds)
            }
            partBoxes.append(boxes)
            plantBounds.append(assembly.bounds)   // with room for the root's sway
        }
        precondition(MemoryLayout<RTPart>.stride == 128, "RTPart: Shaders/Intersect.metal")
        assemblyBounds = plantBounds
        func bounds(_ inst: Scene.Instance) -> AABB {
            inst.mesh >= 0 ? instanceBounds[inst.mesh] : inst.assembly >= 0 ? plantBounds[inst.assembly] : scene.virtualMeshes[inst.virtualMesh].bounds
        }
        // The blocks of instances: each one's tree (built here if this is the first scene to trace it), whose parts
        // go under the scene's as leaves.
        guard !scene.hasGroups || sceneGeometry != nil else {
            throw RendererError.resourceCreation("the trees of a scene with instance groups, without its buffers")
        }
        let tiles = sceneGeometry?.instanceBlocks ?? []
        let newTiles = tiles.reduce(0) { $0 + ($1.hasTree ? 0 : 1) }
        var builtTiles = [InstanceBlock.Tree?](repeating: nil, count: tiles.count)
        builtTiles.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: tiles.count) { k in
                out[k] = tiles[k].tree { mesh, assembly in mesh.map { instanceBounds[$0] } ?? plantBounds[assembly!] }
            }
        }
        let tileTrees = builtTiles.map { $0! }
        let tileDepth = tileTrees.reduce(0) { max($0, $1.depth) }
        for (i, inst) in sceneInstances.enumerated() {
            if inst.virtualMesh >= 0 { virtualInstances.append((i, inst.virtualMesh)) }
            if inst.virtualMesh >= 0 && CustomRayTracer.clusterMode {
                continue   // in the cluster tree, not the instance trees
            } else if inst.isStatic {
                let box = bounds(inst).transformed(inst.transform)
                if inst.isGeometry {
                    geometry.boxes.append(box); geometry.ids.append(i); geometry.masks.append(inst.mask)
                } else {
                    proxies.boxes.append(box); proxies.ids.append(i); proxies.masks.append(inst.mask)
                }
            } else {
                dyn.append(i)
            }
        }
        var tilePartOf: [(tile: Int, ref: UInt32)] = []
        for (k, tree) in tileTrees.enumerated() {
            for part in tree.parts {
                geometry.boxes.append(part.box)
                geometry.ids.append(CustomRayTracer.tilePart | tilePartOf.count)
                geometry.masks.append(part.mask)
                tilePartOf.append((k, part.ref))
            }
        }
        // One tree per group, joined by a root node. Shadow and GI rays (MASK_GEOMETRY) skip the proxies' tree at the
        // root by its mask and walk a tree of geometry only: one tree over both costs them ~0.5 ms a frame in the market,
        // since the SAH then splits the geometry around the bulbs.
        var nodes: [BVHNode] = []
        let root: UInt32, staticDepth: Int
        if geometry.ids.isEmpty || proxies.ids.isEmpty {
            let group = geometry.ids.isEmpty ? proxies : geometry
            (root, staticDepth) = BVHBuilder.buildTLAS(boxes: group.boxes, ids: group.ids, masks: group.masks, nodeBase: 0, into: &nodes)
        } else {
            nodes.append(BVHNode())   // the joining root, filled in below
            var depth = 0
            for (k, group) in [geometry, proxies].enumerated() {
                let tree = BVHBuilder.buildTLAS(boxes: group.boxes, ids: group.ids, masks: group.masks, nodeBase: 0, into: &nodes)
                var box = AABB()
                for b in group.boxes { box.grow(b) }
                nodes[0].setChild(k, lo: box.lo, hi: box.hi, ref: tree.root, mask: group.masks.reduce(0, |))
                depth = max(depth, tree.depth)
            }
            root = 0
            staticDepth = depth + 1
        }
        let staticCount = geometry.ids.count + proxies.ids.count - tilePartOf.count
        // The assemblies' trees over their parts: a leaf is a part's record. They sit with the static nodes, so the
        // traversal reads them as it reads the top level, in the plant's space (masks too: a part is geometry the raster
        // doesn't draw, Scene.maskShadowTraced).
        var roots: [UInt32] = [], partDepth = 0, firstPart = 0
        let firstAssemblyNode = nodes.count
        for boxes in partBoxes {
            let tree = BVHBuilder.buildTLAS(boxes: boxes, ids: Array(firstPart..<firstPart + boxes.count),
                                            masks: [UInt32](repeating: Scene.maskGeometry | Scene.maskShadowTraced, count: boxes.count),
                                            nodeBase: 0, into: &nodes)
            roots.append(tree.root)
            partDepth = max(partDepth, tree.depth)
            firstPart += boxes.count
        }
        assemblyRoots = roots
        self.partBoxes = partBoxes.flatMap { $0 }
        partPads = pads
        assemblyNodes = firstAssemblyNode..<nodes.count
        slotWind = [Float](repeating: 0, count: slots)
        // The blocks' trees come after these nodes, one after the other, and their instances after the scene's own:
        // where a leaf of the top-level tree says a part of a block, that part's node or instance instead.
        var tileNodeBases: [Int] = [], tileFirsts: [Int] = [], nextNode = nodes.count, nextInstance = sceneInstances.count
        for (k, tile) in tiles.enumerated() {
            tileNodeBases.append(nextNode)
            tileFirsts.append(nextInstance)
            nextNode += tileTrees[k].nodes.count
            nextInstance += tile.count
        }
        /// A ref of a block's tree, where the tree and its instances are in the scene's.
        func moved(_ ref: UInt32, tile k: Int) -> UInt32 {
            ref & BVHNode.leafBit != 0 ? BVHNode.leafBit | ((ref & ~BVHNode.leafBit) + UInt32(tileFirsts[k])) : ref + UInt32(tileNodeBases[k])
        }
        func placed(_ ref: UInt32) -> UInt32 {
            guard ref != BVHNode.none, ref & BVHNode.leafBit != 0, Int(ref) & CustomRayTracer.tilePart != 0 else { return ref }
            let part = tilePartOf[Int(ref & ~BVHNode.leafBit) & ~CustomRayTracer.tilePart]
            return moved(part.ref, tile: part.tile)
        }
        if !tiles.isEmpty {
            for n in 0..<firstAssemblyNode {
                nodes[n].lo0.w = Float(bitPattern: placed(nodes[n].ref(0)))
                nodes[n].lo1.w = Float(bitPattern: placed(nodes[n].ref(1)))
            }
        }
        tileNodes = nextNode - nodes.count
        tileInstances = nextInstance - sceneInstances.count
        firstAssembly = scene.meshes.count + scene.virtualMeshes.count
        staticNodes = nodes
        staticRoot = placed(root)
        dynamicIds = dyn

        func buffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
            let length = max(MemoryLayout<T>.stride * array.count, 16)
            let b = array.isEmpty ? device.makeBuffer(length: length, options: .storageModeShared)
                                  : array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard let b else { throw RendererError.resourceCreation("buffer \(label)") }
            b.label = label
            return b
        }
        blasNodes = try buffer(blas.nodes, "blasNodes")
        triangles = try buffer(blas.triangles, "bvhTriangles")
        blockTrees = blocks.map(\.buffer)
        blockTable = try buffer(blocks.map(\.buffer.gpuAddress), "rtBlockTrees")
        virtualGeometry = virtualInstances.isEmpty || !CustomRayTracer.clusterMode ? nil
            : try VirtualGeometry(device: device, meshes: scene.virtualMeshes, instances: virtualInstances, poolMB: poolMB, slots: slots)
        virtualBLAS = virtualInstances.isEmpty || CustomRayTracer.clusterMode ? nil
            : try VirtualBLAS(device: device, meshes: scene.virtualMeshes, instances: virtualInstances, slots: slots)
        dummy = try buffer([UInt32](repeating: BVHNode.none, count: 4), "rtDummy")
        stats = try buffer([UInt32](repeating: 0, count: 8), "rtStats")
        let tlasCapacity = staticNodes.count + tileNodes + max(dynamicIds.count - 1, 1) + (virtualGeometry == nil ? 0 : VirtualGeometry.capacity)
        let nodeStride = MemoryLayout<BVHNode>.stride
        for slot in 0..<slots {
            guard let t = device.makeBuffer(length: tlasCapacity * nodeStride, options: .storageModeShared),
                  let records = device.makeBuffer(length: max(nextInstance, 1) * MemoryLayout<RTInstance>.stride, options: .storageModeShared) else {
                throw RendererError.resourceCreation("the top-level tree's buffers")
            }
            (t.label, records.label) = ("tlasNodes\(slot)", "rtInstances\(slot)")
            // (Not `staticNodes.withUnsafeBytes { ... copyMemory ... }`: Swift 6.4 compiles that closure to end in a tail
            // call to memmove with the buffer's address still in the error register, and the optimised init then takes
            // its return for a throw.)
            if !staticNodes.isEmpty { memcpy(t.contents(), staticNodes, staticNodes.count * nodeStride) }
            if slot == 0 {
                // The blocks' trees, each where it was placed above: its nodes count from there, its leaves' instances
                // from the block's first.
                let out = t.contents().bindMemory(to: BVHNode.self, capacity: tlasCapacity)
                DispatchQueue.concurrentPerform(iterations: tiles.count) { k in
                    tileTrees[k].nodes.withUnsafeBufferPointer { from in
                        for n in from.indices {
                            var node = from[n]
                            if node.ref(0) != BVHNode.none { node.lo0.w = Float(bitPattern: moved(node.ref(0), tile: k)) }
                            if node.ref(1) != BVHNode.none { node.lo1.w = Float(bitPattern: moved(node.ref(1), tile: k)) }
                            out[tileNodeBases[k] + n] = node
                        }
                    }
                }
            } else if tileNodes > 0 {
                memcpy(t.contents() + staticNodes.count * nodeStride, tlasNodes[0].contents() + staticNodes.count * nodeStride, tileNodes * nodeStride)
            }
            tlasNodes.append(t)
            instances.append(records)
            sceneArgs.append(try buffer([UInt8](repeating: 0, count: CustomRayTracer.argsSize), "rtScene\(slot)"))
        }

        instanceCount = nextInstance
        paddedCount = max(2, 1 << Int(ceil(log2(Double(max(dyn.count, 2))))))
        var info: [SIMD4<Float>] = []
        for (m, b) in instanceBounds.enumerated() {
            info += [SIMD4(b.lo, Float(bitPattern: blas.roots[m])), SIMD4(b.hi, Float(bitPattern: swayingMeshes[m] ? CustomRayTracer.sways : 0))]
        }
        for vm in scene.virtualMeshes {   // after the ordinary meshes (GPUInstanceData.meshIndex of virtual instances)
            info += [SIMD4(vm.bounds.lo, 0), SIMD4(vm.bounds.hi, 0)]
        }
        for (a, b) in plantBounds.enumerated() {   // then the assemblies: the root of the tree over its parts, and its number + 1
            info += [SIMD4(b.lo, Float(bitPattern: roots[a])), SIMD4(b.hi, Float(bitPattern: UInt32(a + 1)))]
        }
        parts = try buffer(partRecords, "rtParts")
        let voxelStart = CACurrentMediaTime()
        let grids = FoliageVoxels.cached(scene.voxelPlants)
        voxelGrids = try buffer(grids.grids, "rtVoxelGrids")
        voxels = try buffer(grids.cells, "rtVoxels")
        cutouts = try buffer(scene.cutouts.flatMap(\.alpha), "rtCutouts")
        if !grids.grids.isEmpty {
            print(String(format: "Plant voxels: %d grids, %.1f MB, built in %.1f ms", grids.grids.count,
                         Double(grids.cells.count * 4) / 1e6, (CACurrentMediaTime() - voxelStart) * 1000))
        }
        var slotOf = [UInt32](repeating: BVHNode.none, count: max(nextInstance, 1))
        for (k, i) in dyn.enumerated() { slotOf[i] = UInt32(k) }
        meshInfo = try buffer(info, "rtMeshInfo")
        dynSlot = try buffer(slotOf, "rtDynSlot")
        leafBoxes = try buffer([SIMD4<Float>](repeating: .zero, count: 2 * max(dyn.count, 1)), "rtLeafBoxes")
        keys = try buffer([UInt32](repeating: 0, count: paddedCount), "rtKeys")
        values = try buffer([UInt32](repeating: 0, count: paddedCount), "rtValues")
        nodeParent = try buffer([UInt32](repeating: 0, count: max(dyn.count, 1)), "rtNodeParent")
        leafParent = try buffer([UInt32](repeating: 0, count: max(dyn.count, 1)), "rtLeafParent")
        counters = try buffer([UInt32](repeating: 0, count: max(dyn.count, 1)), "rtCounters")
        for slot in 0..<slots { writeArgs(slot: slot) }
        if let crowd = scene.crowd, let first = crowd.slots.map(\.mesh).min(), let last = crowd.slots.map(\.mesh).max() {
            precondition(last - first + 1 == crowd.slots.count, "the pose slots' meshes are consecutive")
            let nodeBase = blas.nodeBases[first], nodeCount = blas.nodeBases[last + 1] - nodeBase
            var links = [SIMD2<UInt32>](repeating: SIMD2(BVHNode.none, 0), count: nodeCount)
            for m in first...last {
                for n in blas.nodeBases[m]..<blas.nodeBases[m + 1] {
                    links[n - nodeBase].y = UInt32(m)
                    for k in 0..<2 where blas.nodes[n].ref(k) & BVHNode.leafBit == 0 {
                        links[Int(blas.nodes[n].ref(k)) - nodeBase].x = UInt32(n) | (k == 1 ? 0x8000_0000 : 0)
                    }
                }
            }
            crowdRefit = (try buffer(links, "rtCrowdLinks"), try buffer([UInt32](repeating: 0, count: nodeCount), "rtCrowdArrived"),
                          nodeBase, nodeCount, first...last)
        }
        print(String(format: "Custom BVH: %d BLAS nodes, %d triangles, static TLAS %d instances (%d nodes, depth %d), %d dynamic, built in %.1f ms%@%@",
                     blas.nodes.count, blas.triangles.count / 3, staticCount, staticNodes.count, staticDepth, dynamicIds.count,
                     (CACurrentMediaTime() - start) * 1000, cached ? " (the meshes' trees from the cache)" : "",
                     (blocks.isEmpty ? "" : "; \(blocks.count) meshes with trees of their own (\(newBlocks) new, \(newBlocks - copiedBlocks) built)")
                         + (tiles.isEmpty ? "" : "; \(tileInstances) instances more in \(tilePartOf.count) parts of \(tiles.count) blocks (\(newTiles) new), \(tileNodes) nodes, depth \(tileDepth)")))
        if !roots.isEmpty {
            // The traversal's stack holds one entry per level it has gone down, all three levels together.
            let deepest = staticDepth + tileDepth + partDepth + blas.maxDepth + 3
            print("Assemblies: \(roots.count) plants of \(partRecords.count) parts, trees \(partDepth) deep over BLASes \(blas.maxDepth) deep"
                  + (deepest > 64 ? " — \(deepest) LEVELS IN ALL: the traversal's stack (RT_STACK) may overflow" : ""))
        }
        if CustomRayTracer.checked, !scene.hasBorrowedMeshes { selfTest(scene: scene) }   // (it reads the scene's arrays)
    }

    /// RTScene (160 bytes, asserted in Shaders/Intersect.metal): 10 GPU addresses, then the static and dynamic root refs and the
    /// cluster tree's first node, then the assemblies' parts and their voxels; the wind is written every frame (`encodeBuild`).
    private func writeArgs(slot: Int) {
        let p = sceneArgs[slot].contents()
        let vg = virtualGeometry
        p.storeBytes(of: tlasNodes[slot].gpuAddress, toByteOffset: 0, as: UInt64.self)
        p.storeBytes(of: blasNodes.gpuAddress, toByteOffset: 8, as: UInt64.self)
        p.storeBytes(of: triangles.gpuAddress, toByteOffset: 16, as: UInt64.self)
        p.storeBytes(of: instances[slot].gpuAddress, toByteOffset: 24, as: UInt64.self)
        p.storeBytes(of: (vg?.selectedBuffers[slot] ?? dummy).gpuAddress, toByteOffset: 32, as: UInt64.self)
        p.storeBytes(of: (vg?.pool ?? dummy).gpuAddress, toByteOffset: 40, as: UInt64.self)
        p.storeBytes(of: (vg?.rootsBuffers[slot] ?? dummy).gpuAddress, toByteOffset: 48, as: UInt64.self)
        p.storeBytes(of: (vg?.nodeInstanceBuffers[slot] ?? dummy).gpuAddress, toByteOffset: 56, as: UInt64.self)
        p.storeBytes(of: stats.gpuAddress, toByteOffset: 64, as: UInt64.self)
        p.storeBytes(of: (virtualBLAS?.table(slot: slot) ?? dummy).gpuAddress, toByteOffset: 72, as: UInt64.self)
        p.storeBytes(of: staticRoot, toByteOffset: 80, as: UInt32.self)
        p.storeBytes(of: dynamicRoot, toByteOffset: 84, as: UInt32.self)
        p.storeBytes(of: UInt32(virtualNodeBase), toByteOffset: 88, as: UInt32.self)
        p.storeBytes(of: parts.gpuAddress, toByteOffset: 96, as: UInt64.self)
        p.storeBytes(of: voxelGrids.gpuAddress, toByteOffset: 144, as: UInt64.self)
        p.storeBytes(of: voxels.gpuAddress, toByteOffset: 152, as: UInt64.self)
        p.storeBytes(of: cutouts.gpuAddress, toByteOffset: 160, as: UInt64.self)
    }

    /// `blasRoot`: the mesh's, or for an assembly the root of the tree over its parts (`pad1` is then its number + 1).
    /// `tree`: for a mesh whose tree is in a buffer of its own, that buffer's address.
    static func rtInstance(_ inst: Scene.Instance, blasRoot: UInt32, sways: Bool = false, tree: UInt64? = nil) -> RTInstance {
        let inv = inst.transform.inverse
        return RTInstance(row0: SIMD4(inv[0][0], inv[1][0], inv[2][0], inv[3][0]),
                          row1: SIMD4(inv[0][1], inv[1][1], inv[2][1], inv[3][1]),
                          row2: SIMD4(inv[0][2], inv[1][2], inv[2][2], inv[3][2]),
                          blasRoot: tree.map { UInt32(truncatingIfNeeded: $0) } ?? blasRoot, pad0: tree.map { UInt32($0 >> 32) } ?? 0,
                          mask: inst.mask | (tree == nil ? 0 : ownTree),
                          pad1: UInt32(inst.assembly + 1) | (sways ? CustomRayTracer.sways : 0))
    }

    /// CPU build (`METALRENDERER_RT_BUILD=cpu` only): this frame's instance data and dynamic TLAS.
    func update(slot: Int, scene: Scene) {
        guard CustomRayTracer.cpuBuild else { return }
        let inst = instances[slot].contents().bindMemory(to: RTInstance.self, capacity: scene.instances.count)
        for (i, s) in scene.instances.enumerated() {
            let root = s.mesh >= 0 ? blasRoots[s.mesh] : s.assembly >= 0 ? assemblyRoots[s.assembly] : 0
            let own = s.mesh >= 0 && root != BVHNode.none && root & CustomRayTracer.blockRoot != 0
            inst[i] = CustomRayTracer.rtInstance(s, blasRoot: root, sways: s.mesh >= 0 && swayingMeshes[s.mesh],
                                                 tree: own ? blockTrees[Int(root & ~CustomRayTracer.blockRoot)].gpuAddress : nil)
        }
        guard dynamicIds.count >= 2 else { return }
        let boxes = dynamicIds.map { i -> AABB in
            let inst = scene.instances[i]
            return (inst.mesh >= 0 ? meshBounds[inst.mesh] : inst.assembly >= 0 ? assemblyBounds[inst.assembly]
                    : scene.virtualMeshes[inst.virtualMesh].bounds).transformed(inst.transform)
        }
        var nodes: [BVHNode] = []
        _ = BVHBuilder.buildTLAS(boxes: boxes, ids: dynamicIds, masks: dynamicIds.map { scene.instances[$0].mask },
                                 nodeBase: dynamicNodeBase, into: &nodes)
        nodes.withUnsafeBytes {
            tlasNodes[slot].contents().advanced(by: dynamicNodeBase * MemoryLayout<BVHNode>.stride)
                .copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
    }

    /// GPU build: every instance's RTInstance, the dynamic TLAS from this frame's instance data, and the
    /// virtual-geometry cut and its cluster tree.
    /// The assemblies' nodes with every part's box grown by what a wind of `strength` can move it: the trees keep
    /// their shape (built for the parts at rest), only the boxes change, children before parents.
    private func fitAssemblies(strength: Float) {
        guard fittedNodes.isEmpty || strength != fittedWind else { return }
        fittedWind = strength
        fittedNodes = Array(staticNodes[assemblyNodes])
        let base = assemblyNodes.lowerBound
        for i in fittedNodes.indices.reversed() {
            for k in 0..<2 {
                let ref = fittedNodes[i].ref(k)
                if ref == BVHNode.none { continue }
                var box = AABB()
                if ref & BVHNode.leafBit != 0 {
                    let part = Int(ref & ~BVHNode.leafBit)
                    let pad = SIMD3<Float>(repeating: partPads[part] * strength)
                    box = AABB(lo: partBoxes[part].lo - pad, hi: partBoxes[part].hi + pad)
                } else {
                    let child = fittedNodes[Int(ref) - base]   // written after its parent, so already refitted
                    box.grow(child.lo(0)); box.grow(child.hi(0))
                    if child.ref(1) != BVHNode.none { box.grow(child.lo(1)); box.grow(child.hi(1)) }
                }
                fittedNodes[i].setChild(k, lo: box.lo, hi: box.hi, ref: ref, mask: Scene.maskGeometry | Scene.maskShadowTraced)
            }
        }
    }

    func encodeBuild(_ enc: ComputePass, slot: Int, instanceData: MTLBuffer, view: VGView, wind: WindFrame) {
        if !assemblyNodes.isEmpty && slotWind[slot] != wind.wind.z {
            fitAssemblies(strength: wind.wind.z)
            slotWind[slot] = wind.wind.z
            fittedNodes.withUnsafeBytes {
                tlasNodes[slot].contents().advanced(by: assemblyNodes.lowerBound * MemoryLayout<BVHNode>.stride)
                    .copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }
        let args = sceneArgs[slot].contents()
        args.storeBytes(of: wind.wind, toByteOffset: 112, as: SIMD4<Float>.self)
        args.storeBytes(of: SIMD4(wind.time, wind.previousTime, 0, wind.leafFall), toByteOffset: 128, as: SIMD4<Float>.self)
        guard instanceCount > 0, let pipelines else { return }
        if !CustomRayTracer.cpuBuild || tileInstances > 0 {   // (the blocks' records are only written here)
            var counts = SIMD2(UInt32(instanceCount), UInt32(firstAssembly))
            enc.setBytes(&counts, length: 8, index: 0)
            enc.setBuffer(instanceData, offset: 0, index: 1)
            enc.setBuffer(meshInfo, offset: 0, index: 2)
            enc.setBuffer(dynSlot, offset: 0, index: 3)
            enc.setBuffer(instances[slot], offset: 0, index: 4)
            enc.setBuffer(leafBoxes, offset: 0, index: 5)
            // Plants turn to voxels where a voxel is `lodBias` traced pixels: by the view the virtual geometry is cut for.
            enc.setBuffer(voxelGrids, offset: 0, index: 6)
            enc.setBuffer(blockTable, offset: 0, index: 8)
            var lodView = SIMD4(view.camPos, wind.lodBias / max(view.pixelScale, 1e-6))
            enc.setBytes(&lodView, length: 16, index: 7)
            enc.setComputePipelineState(pipelines.prep)
            enc.dispatchThreads(MTLSize(width: instanceCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            let n = dynamicIds.count
            if n >= 2 {
                CustomRayTracer.encodeLBVH(enc, rt: pipelines, counts: .bytes(SIMD2(UInt32(n), UInt32(paddedCount))), capacity: n,
                                           leafBoxes: leafBoxes, keys: keys, values: values, nodes: tlasNodes[slot],
                                           nodeBase: dynamicNodeBase, nodeParent: nodeParent, leafParent: leafParent, counters: counters)
            }
        }
        virtualGeometry?.encode(enc, slot: slot, rt: pipelines, vg: pipelines.vg, instanceData: instanceData, tlasNodes: tlasNodes[slot],
                                nodeBase: virtualNodeBase, camPos: view.camPos, pixelScale: view.pixelScale, tau: view.tau, frame: view.frame)
    }

    /// The crowd's pose slots: their triangles and boxes from this frame's skinned vertices, and their bounds for the
    /// build above (so it comes first). `positions`, `indices` and `meshes` are the scene's buffers.
    func encodeCrowdRefit(_ enc: ComputePass, positions: MTLBuffer, indices: MTLBuffer, meshes: MTLBuffer) {
        guard let refit = crowdRefit, let pipelines else { return }
        refitTag &+= 1
        var p = RefitParams(nodeBase: UInt32(refit.nodeBase), nodeCount: UInt32(refit.nodeCount), tag: refitTag)
        enc.setComputePipelineState(pipelines.crowdRefit)
        enc.setBytes(&p, length: MemoryLayout<RefitParams>.stride, index: 0)
        enc.setBuffer(blasNodes, offset: 0, index: 1)
        enc.setBuffer(triangles, offset: 0, index: 2)
        enc.setBuffer(refit.links, offset: 0, index: 3)
        enc.setBuffer(refit.arrived, offset: 0, index: 4)
        enc.setBuffer(positions, offset: 0, index: 5)
        enc.setBuffer(indices, offset: 0, index: 6)
        enc.setBuffer(meshes, offset: 0, index: 7)
        enc.setBuffer(meshInfo, offset: 0, index: 8)
        enc.dispatchThreads(MTLSize(width: refit.nodeCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }

    /// The pose slots' trees as the GPU left them (the frame must be done), against `positions`: every triangle
    /// record is its triangle's current vertices, every box is exactly the box of what lies below it, and each mesh's
    /// bounds are its root's. Returns what doesn't hold (METALRENDERER_CROWD_CHECK=1).
    func checkCrowdRefit(scene: Scene, positions: MTLBuffer) -> (triangles: Int, boxes: Int, bounds: Int) {
        guard let refit = crowdRefit else { return (0, 0, 0) }
        let nodes = blasNodes.contents().bindMemory(to: BVHNode.self, capacity: blasNodes.length / MemoryLayout<BVHNode>.stride)
        let tris = triangles.contents().bindMemory(to: SIMD4<Float>.self, capacity: triangles.length / 16)
        let p = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: positions.length / 16)
        let info = meshInfo.contents().bindMemory(to: SIMD4<Float>.self, capacity: meshInfo.length / 16)
        var wrong = (triangles: 0, boxes: 0, bounds: 0)
        for m in refit.meshes {
            let mesh = scene.meshes[m]
            /// The box of what is below `ref`, counting the boxes on the way that aren't it.
            func box(_ ref: UInt32) -> AABB {
                var b = AABB()
                if ref == BVHNode.none { return b }
                if ref & BVHNode.leafBit != 0 {
                    let first = Int(ref & 0x0FFF_FFFF), count = Int((ref >> 28) & 7) + 1
                    for t in first..<(first + count) {
                        let base = Int(mesh.firstIndex) + 3 * Int(tris[3 * t].w.bitPattern), offset = Int(mesh.vertexOffset)
                        let p0 = p[Int(scene.indices[base]) + offset], p1 = p[Int(scene.indices[base + 1]) + offset]
                        let p2 = p[Int(scene.indices[base + 2]) + offset]
                        let v0 = tris[3 * t], e1 = tris[3 * t + 1], e2 = tris[3 * t + 2]
                        if SIMD3(v0.x, v0.y, v0.z) != p0 || SIMD3(e1.x, e1.y, e1.z) != p1 - p0 || SIMD3(e2.x, e2.y, e2.z) != p2 - p0 {
                            wrong.triangles += 1
                        }
                        b.grow(p0); b.grow(p1); b.grow(p2)
                    }
                    return b
                }
                let n = nodes[Int(ref)]
                for k in 0..<2 where n.ref(k) != BVHNode.none {
                    let below = box(n.ref(k))
                    if below.lo != n.lo(k) || below.hi != n.hi(k) { wrong.boxes += 1 }
                    b.grow(below)
                }
                return b
            }
            let all = box(blasRoots[m])
            let lo = info[2 * m], hi = info[2 * m + 1]
            if SIMD3(lo.x, lo.y, lo.z) != all.lo || SIMD3(hi.x, hi.y, hi.z) != all.hi { wrong.bounds += 1 }
        }
        return wrong
    }

    /// An LBVH over `leafBoxes` (Morton keys, bitonic sort, Karras hierarchy, bottom-up boxes) into `nodes` from
    /// `nodeBase` on. Dispatches cover `capacity` leaves; the kernels skip what lies beyond the actual count.
    static func encodeLBVH(_ enc: ComputePass, rt: RTPipelines, counts: LBVHCounts, capacity: Int,
                           leafBoxes: MTLBuffer, keys: MTLBuffer, values: MTLBuffer, nodes: MTLBuffer, nodeBase: Int,
                           nodeParent: MTLBuffer, leafParent: MTLBuffer, counters: MTLBuffer) {
        func dispatch(_ pso: MTLComputePipelineState, _ threads: Int, group: Int = 64) {
            enc.setComputePipelineState(pso)
            enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(group, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        func bindCounts(_ index: Int) {
            switch counts {
            case .bytes(var c): enc.setBytes(&c, length: 8, index: index)
            case .buffer(let b): enc.setBuffer(b, offset: 0, index: index)
            }
        }
        let padded = max(2, 1 << Int(ceil(log2(Double(max(capacity, 2))))))   // sort size the dispatches cover

        bindCounts(0)
        enc.setBuffer(leafBoxes, offset: 0, index: 1)
        enc.setBuffer(keys, offset: 0, index: 2)
        enc.setBuffer(values, offset: 0, index: 3)
        dispatch(rt.keys, 1024, group: 1024)
        encodeSort(enc, rt: rt, counts: counts, capacity: capacity, keys: keys, values: values)

        var params = SIMD2<UInt32>(0, UInt32(nodeBase))
        enc.setBytes(&params, length: 8, index: 0)
        enc.setBuffer(keys, offset: 0, index: 1)
        enc.setBuffer(values, offset: 0, index: 2)
        enc.setBuffer(leafBoxes, offset: 0, index: 3)
        enc.setBuffer(nodes, offset: nodeBase * MemoryLayout<BVHNode>.stride, index: 4)
        enc.setBuffer(nodeParent, offset: 0, index: 5)
        enc.setBuffer(leafParent, offset: 0, index: 6)
        enc.setBuffer(counters, offset: 0, index: 7)
        bindCounts(8)
        dispatch(rt.hierarchy, capacity - 1)
        dispatch(rt.fit, capacity)
    }

    /// Bitonic sort of (key, value) pairs: whole 2048-key blocks in threadgroup memory, then the cross-block stages.
    /// Dispatches cover `capacity`; the kernels skip what lies beyond the padded count in `counts`.
    static func encodeSort(_ enc: ComputePass, rt: RTPipelines, counts: LBVHCounts, capacity: Int,
                           keys: MTLBuffer, values: MTLBuffer) {
        func dispatch(_ pso: MTLComputePipelineState, _ threads: Int) {
            enc.setComputePipelineState(pso)
            enc.dispatchThreads(MTLSize(width: max(threads, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        let padded = max(2, 1 << Int(ceil(log2(Double(max(capacity, 2))))))
        enc.setBuffer(keys, offset: 0, index: 1)
        enc.setBuffer(values, offset: 0, index: 2)
        switch counts {
        case .bytes(var c): enc.setBytes(&c, length: 8, index: 3)
        case .buffer(let b): enc.setBuffer(b, offset: 0, index: 3)
        }
        let block = 2048, blocks = max(padded / block, 1)
        func local(_ k: Int) {
            var p = SIMD2<UInt32>(0, UInt32(k))
            enc.setBytes(&p, length: 8, index: 0)
            enc.setComputePipelineState(rt.sortLocal)
            enc.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1024, height: 1, depth: 1))
        }
        local(0)
        var k = 2 * block
        while k <= padded {
            var j = k / 2
            while j >= block {
                var p = SIMD2<UInt32>(UInt32(k), UInt32(j))
                enc.setBytes(&p, length: 8, index: 0)
                dispatch(rt.sortGlobal, padded / 2)
                j /= 2
            }
            local(k)
            k *= 2
        }
    }

    /// The raw traversal counters (they only grow, wrapping at 2^32). While frames are in flight, read these and take
    /// differences: a reset from the CPU doesn't stick then (the GPU's atomics write their cached values back over it).
    func readCounters() -> [UInt32] {
        let c = stats.contents().bindMemory(to: UInt32.self, capacity: 8)
        return (0..<TraversalStats.count).map { c[$0] }
    }

    /// Traversal counter totals since the last call (then resets them). Only with the GPU idle (benchmarks wait for
    /// each frame), see `readCounters`.
    func takeStats() -> TraversalStats {
        let c = stats.contents().bindMemory(to: UInt32.self, capacity: 8)
        let out = TraversalStats(counts: (0..<TraversalStats.count).map { UInt64(c[$0]) })
        memset(stats.contents(), 0, 32)
        return out
    }

    /// Binds the scene's argument buffer; with `declare` (the first bind in an encoder) also declares what it points at.
    /// The buffers a frame of a scene without virtual geometry reads (SceneBuffers.touch).
    var buffers: [MTLBuffer] { tlasNodes + instances + [blasNodes, triangles, parts, voxelGrids, voxels, cutouts] + blockTrees }

    func bind(_ enc: ComputePass, slot: Int, declare: Bool = true) {
        enc.setBuffer(sceneArgs[slot], offset: 0, index: 1)
        guard declare else { return }
        enc.useResources([tlasNodes[slot], blasNodes, triangles, instances[slot], parts, voxelGrids, voxels, cutouts] + (virtualGeometry?.resources(slot: slot) ?? [dummy])
                         + (virtualBLAS?.resources(slot: slot) ?? []), usage: .read)
        if !blockTrees.isEmpty { enc.useResources(blockTrees, usage: .read) }
        enc.useResource(stats, usage: [.read, .write])
    }

    // MARK: - Self-test (METALRENDERER_RT_CHECK=1)

    /// CPU traversal of one BLAS (the same algorithm as the shader): closest hit t along an object-space ray.
    private func intersectBLAS(root: UInt32, o: SIMD3<Float>, d: SIMD3<Float>, tmax: Float) -> Float {
        guard let cpu else { return tmax }
        var best = tmax
        var stack = [root]
        var dd = d
        dd.replace(with: SIMD3(repeating: 1e-12), where: abs(d) .< 1e-12)
        let inv = SIMD3<Float>(1, 1, 1) / dd
        func slab(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
            let t0 = (lo - o) * inv, t1 = (hi - o) * inv
            let tn = simd_min(t0, t1).max(), tf = simd_max(t0, t1).min()
            return max(tn, 0) <= min(tf, best)
        }
        while let ref = stack.popLast() {
            if ref == BVHNode.none { continue }
            if ref & BVHNode.leafBit != 0 {
                let first = Int(ref & 0x0FFF_FFFF), count = Int((ref >> 28) & 7) + 1
                for t in first..<(first + count) {
                    let v0 = cpu.tris[3 * t], e1 = cpu.tris[3 * t + 1], e2 = cpu.tris[3 * t + 2]
                    if let h = CustomRayTracer.triangle(o, d, SIMD3(v0.x, v0.y, v0.z), SIMD3(e1.x, e1.y, e1.z), SIMD3(e2.x, e2.y, e2.z)),
                       h < best { best = h }
                }
                continue
            }
            let n = cpu.blas.nodes[Int(ref)]
            for k in 0..<2 where slab(n.lo(k), n.hi(k)) { stack.append(n.ref(k)) }
        }
        return best
    }

    static func triangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ v0: SIMD3<Float>, _ e1: SIMD3<Float>, _ e2: SIMD3<Float>) -> Float? {
        let pv = cross(d, e2), det = dot(e1, pv)
        if det == 0 { return nil }
        let inv = 1 / det, tv = o - v0
        let u = dot(tv, pv) * inv
        if u < 0 || u > 1 { return nil }
        let qv = cross(tv, e1), v = dot(d, qv) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = dot(e2, qv) * inv
        return t > 0 ? t : nil
    }

    /// Random rays against every mesh's BLAS, compared with testing every triangle. Prints the result.
    private func selfTest(scene: Scene) {
        var rng = SystemRandomNumberGenerator()
        var mismatches = 0, rays = 0, hits = 0
        for (m, mesh) in scene.meshes.enumerated() {
            let b = meshBounds[m]
            let size = simd_max(b.hi - b.lo, SIMD3(repeating: 1e-3))
            let triCount = Int(mesh.indexCount) / 3
            for _ in 0..<2000 {
                let o = b.lo - size + SIMD3(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng),
                                            Float.random(in: 0...1, using: &rng)) * size * 3
                let target = b.lo + SIMD3(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng),
                                          Float.random(in: 0...1, using: &rng)) * size
                let d = target - o
                var brute = Float.infinity
                for t in 0..<triCount {
                    let base = Int(mesh.firstIndex) + 3 * t
                    let offset = Int(mesh.vertexOffset)
                    let p0 = scene.positions[Int(scene.indices[base]) + offset], p1 = scene.positions[Int(scene.indices[base + 1]) + offset],
                        p2 = scene.positions[Int(scene.indices[base + 2]) + offset]
                    if let h = CustomRayTracer.triangle(o, d, p0, p1 - p0, p2 - p0), h < brute { brute = h }
                }
                let bvh = intersectBLAS(root: blasRoots[m], o: o, d: d, tmax: .infinity)
                rays += 1
                if brute.isFinite { hits += 1 }
                if !(brute == bvh || abs(brute - bvh) <= 1e-5 * max(1, brute)) { mismatches += 1 }
            }
        }
        print("Custom BVH self-test: \(rays) rays over \(scene.meshes.count) meshes, \(hits) hits, \(mismatches) mismatches")
    }
}
