import Foundation
import Metal
import simd

/// The crowd's per-frame GPU work (Shaders/Crowd.metal): every pose slot's skinning matrices from the clips' keys,
/// then every slot's vertices from its bind-pose mesh, written into the slot's range of the scene's position and
/// normal buffers. The acceleration structures follow (the renderer refits the slots' structures).
///
/// The key tables, joints and skin weights are uploaded once. Per frame the CPU writes 32 bytes per slot (what each
/// plays, `Crowd.pose`); everything per joint and per vertex happens on the GPU.
final class CrowdSkinner {
    /// MSL CrowdPoseParams: one character's slots.
    struct PoseParams {
        var jointBase: UInt32, jointCount: UInt32, firstSlot: UInt32, slotCount: UInt32
        var paletteStride: UInt32, pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    }
    /// MSL CrowdSkinParams: one part's slots. A face's (FaceRig): its first range and group (`none`: it has no
    /// expressions, or no face), the weights per slot, and how big its head is against the base's.
    struct SkinParams {
        var bindBase: UInt32, vertexCount: UInt32, currentBase: UInt32, previousBase: UInt32
        var skinBase: UInt32, firstSlot: UInt32, slotCount: UInt32, paletteStride: UInt32
        var faceBase = CrowdSkinner.none, groupBase = CrowdSkinner.none, faceTargets = UInt32(FaceRig.targetNames.count)
        var faceScale: Float = 1
    }
    static let none = UInt32.max

    /// `METALRENDERER_CROWD=frozen`: no skinning and no refits, so the crowd stays in the pose the CPU gave it at
    /// time 0 (to compare a frame with and without the GPU's work).
    static let frozen = ProcessInfo.processInfo.environment["METALRENDERER_CROWD"] == "frozen"
    /// `METALRENDERER_CROWD_CHECK=1` (benchmarks): after each captured frame, the GPU's vertices against the CPU's.
    static let checked = ProcessInfo.processInfo.environment["METALRENDERER_CROWD_CHECK"] == "1"

    let crowd: Crowd
    private let joints: MTLBuffer, rotationKeys: MTLBuffer, rootKeys: MTLBuffer, skin: MTLBuffer
    private let palette: MTLBuffer                 // slots x paletteStride matrices (written and read by the GPU only)
    private var slotBuffers: [MTLBuffer] = []      // per frame slot: a GPUPoseSlot per pose slot
    private let poseParams: [PoseParams]
    private let skinParams: [SkinParams]
    // Faces: their targets by vertex and their vertices' groups (uploaded once), and per frame slot every pose slot's
    // weights and turns (FaceState).
    private let faceRanges: MTLBuffer, faceEntries: MTLBuffer, faceGroups: MTLBuffer
    private var faceWeights: [MTLBuffer] = [], faceTurns: [MTLBuffer] = []
    let hasFaces: Bool

    init(device: MTLDevice, crowd: Crowd, frameSlots: Int) throws {
        self.crowd = crowd
        func buffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
            guard !array.isEmpty, let b = array.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw RendererError.resourceCreation("buffer \(label)")
            }
            b.label = label
            return b
        }
        joints = try buffer(crowd.joints, "crowdJoints")
        rotationKeys = try buffer(crowd.rotationKeys, "crowdRotationKeys")
        rootKeys = try buffer(crowd.rootKeys, "crowdRootKeys")
        let stride = crowd.characters.map { $0.joints.count }.max() ?? 1
        var skinVertices: [GPUSkinVertex] = []
        var skins: [SkinParams] = []
        var ranges: [UInt32] = [], entries: [FaceRig.Entry] = [], groups: [UInt32] = []
        for (p, part) in crowd.parts.enumerated() where part.slotCount > 0 {
            var params = SkinParams(bindBase: UInt32(part.bindVertex), vertexCount: UInt32(part.vertexCount),
                                    currentBase: UInt32(part.currentBase), previousBase: UInt32(part.previousBase),
                                    skinBase: UInt32(skinVertices.count), firstSlot: UInt32(part.firstSlot),
                                    slotCount: UInt32(part.slotCount), paletteStride: UInt32(stride))
            let geometry = crowd.geometry(part: p)
            if part.character < crowd.faces.count, let face = crowd.faces[part.character] {
                // This level's vertices' at full detail (the rig's are the base's).
                let source = geometry.source.isEmpty ? Array(0..<UInt32(geometry.positions.count)) : geometry.source
                params.groupBase = UInt32(groups.count)
                groups += source.map { face.rig.groups[Int($0)] }
                if face.expressive {
                    let table = face.rig.byVertex
                    params.faceBase = UInt32(ranges.count)
                    params.faceScale = face.scale
                    for s in source {
                        ranges.append(UInt32(entries.count))
                        entries += table.entries[Int(table.ranges[Int(s)])..<Int(table.ranges[Int(s) + 1])]
                    }
                    ranges.append(UInt32(entries.count))
                }
            }
            skins.append(params)
            skinVertices += geometry.skin
        }
        skin = try buffer(skinVertices, "crowdSkin")
        skinParams = skins
        hasFaces = !groups.isEmpty
        faceRanges = try buffer(ranges.isEmpty ? [0] : ranges, "crowdFaceRanges")
        faceEntries = try buffer(entries.isEmpty ? [FaceRig.Entry(delta: .zero, normal: .zero)] : entries, "crowdFaceEntries")
        faceGroups = try buffer(groups.isEmpty ? [0] : groups, "crowdFaceGroups")
        // A character's parts are consecutive, and so are their slots.
        poseParams = crowd.characters.indices.compactMap { c in
            let parts = crowd.parts.filter { $0.character == c && $0.slotCount > 0 }
            guard let first = parts.first else { return nil }
            return PoseParams(jointBase: UInt32(crowd.jointBase[c]), jointCount: UInt32(crowd.characters[c].joints.count),
                              firstSlot: UInt32(first.firstSlot), slotCount: UInt32(parts.reduce(0) { $0 + $1.slotCount }),
                              paletteStride: UInt32(stride))
        }
        guard let palette = device.makeBuffer(length: crowd.slots.count * stride * MemoryLayout<GPUJointMatrix>.stride, options: .storageModePrivate) else {
            throw RendererError.resourceCreation("buffer crowdPalette")
        }
        palette.label = "crowdPalette"
        self.palette = palette
        for slot in 0..<frameSlots {
            guard let b = device.makeBuffer(length: crowd.slots.count * MemoryLayout<GPUPoseSlot>.stride, options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer crowdSlots")
            }
            b.label = "crowdSlots\(slot)"
            slotBuffers.append(b)
            let slots = hasFaces ? crowd.slots.count : 1
            guard let w = device.makeBuffer(length: slots * FaceRig.targetNames.count * MemoryLayout<Float>.stride, options: .storageModeShared),
                  let t = device.makeBuffer(length: slots * FaceRig.groupCount * MemoryLayout<FaceState.Turn>.stride, options: .storageModeShared) else {
                throw RendererError.resourceCreation("buffer crowdFaces")
            }
            w.label = "crowdFaceWeights\(slot)"
            t.label = "crowdFaceTurns\(slot)"
            faceWeights.append(w)
            faceTurns.append(t)
        }
    }

    /// What every pose slot plays this frame, for frame slot `slot`.
    func write(slot: Int) {
        let out = slotBuffers[slot].contents().bindMemory(to: GPUPoseSlot.self, capacity: crowd.slots.count)
        for (i, s) in crowd.slots.enumerated() { out[i] = s.record }
        guard hasFaces else { return }
        let count = FaceRig.targetNames.count
        let weights = faceWeights[slot].contents().bindMemory(to: Float.self, capacity: crowd.slots.count * count)
        let turns = faceTurns[slot].contents().bindMemory(to: FaceState.Turn.self, capacity: crowd.slots.count * FaceRig.groupCount)
        for (i, state) in crowd.faceStates.enumerated() {
            guard let state else { continue }
            for k in 0..<count { weights[i * count + k] = state.weights[k] }
            for g in 0..<FaceRig.groupCount { turns[i * FaceRig.groupCount + g] = state.turns[g] }
        }
    }

    /// The pose and skinning dispatches, in order (a serial pass).
    func encode(_ enc: ComputePass, pose: MTLComputePipelineState, skin skinState: MTLComputePipelineState, slot: Int,
                positions: MTLBuffer, normals: MTLBuffer) {
        let group = MTLSize(width: 64, height: 1, depth: 1)
        enc.setComputePipelineState(pose)
        enc.setBuffer(joints, offset: 0, index: 1)
        enc.setBuffer(rotationKeys, offset: 0, index: 2)
        enc.setBuffer(rootKeys, offset: 0, index: 3)
        enc.setBuffer(slotBuffers[slot], offset: 0, index: 4)
        enc.setBuffer(palette, offset: 0, index: 5)
        for var p in poseParams {
            enc.setBytes(&p, length: MemoryLayout<PoseParams>.stride, index: 0)
            enc.dispatchThreads(MTLSize(width: Int(p.jointCount), height: Int(p.slotCount), depth: 1), threadsPerThreadgroup: group)
        }
        enc.setComputePipelineState(skinState)
        enc.setBuffer(skin, offset: 0, index: 1)
        enc.setBuffer(palette, offset: 0, index: 2)
        enc.setBuffer(positions, offset: 0, index: 3)
        enc.setBuffer(normals, offset: 0, index: 4)
        enc.setBuffer(faceRanges, offset: 0, index: 5)
        enc.setBuffer(faceEntries, offset: 0, index: 6)
        enc.setBuffer(faceWeights[slot], offset: 0, index: 7)
        enc.setBuffer(faceGroups, offset: 0, index: 8)
        enc.setBuffer(faceTurns[slot], offset: 0, index: 9)
        for var p in skinParams {
            enc.setBytes(&p, length: MemoryLayout<SkinParams>.stride, index: 0)
            enc.dispatchThreads(MTLSize(width: Int(p.vertexCount), height: Int(p.slotCount), depth: 1), threadsPerThreadgroup: group)
        }
    }

    /// The GPU's skinned vertices against the CPU's for the crowd's current time (the frame that wrote them must be
    /// done): the largest distance between positions, and the largest angle between normals as 1 - their dot product.
    func check(positions: MTLBuffer, normals: MTLBuffer) -> (position: Float, normal: Float) {
        let p = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: positions.length / 16)
        let n = normals.contents().bindMemory(to: SIMD3<Float>.self, capacity: normals.length / 16)
        var worst = [(Float, Float)](repeating: (0, 0), count: crowd.slots.count)
        let geometry = crowd.parts.indices.map { crowd.geometry(part: $0) }
        worst.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: crowd.slots.count) { i in
                var mesh = geometry[crowd.slots[i].part]
                let part = crowd.parts[crowd.slots[i].part]
                if i < crowd.faceStates.count, let state = crowd.faceStates[i], let face = crowd.faces[part.character] {
                    var state = state
                    if !face.expressive { state.weights = state.weights.map { _ in 0 } }
                    face.rig.apply(state, scale: face.scale, source: mesh.source.isEmpty ? nil : mesh.source,
                                   positions: &mesh.positions, normals: &mesh.normals)
                }
                var reference = (positions: [SIMD3<Float>](repeating: .zero, count: mesh.positions.count),
                                 normals: [SIMD3<Float>](repeating: .zero, count: mesh.positions.count))
                reference.positions.withUnsafeMutableBufferPointer { rp in
                    reference.normals.withUnsafeMutableBufferPointer { rn in
                        SkinnedCharacter.skin(positions: mesh.positions, normals: mesh.normals, skin: mesh.skin,
                                              palette: crowd.palette(slot: i), into: rp.baseAddress!, rn.baseAddress!)
                    }
                }
                let range = crowd.vertexRange(slot: i)
                for v in 0..<range.count {
                    out[i].0 = max(out[i].0, simd_distance(p[range.current + v], reference.positions[v]))
                    out[i].1 = max(out[i].1, 1 - simd_dot(n[range.current + v], reference.normals[v]))
                }
            }
        }
        return (worst.map(\.0).max() ?? 0, worst.map(\.1).max() ?? 0)
    }
}
