import Foundation
import simd

/// A character that deforms with a skeleton: its mesh in the bind pose, each vertex's joints and weights, the
/// skeleton, and the animation clips, already retargeted to this skeleton. Metres, Y up, facing +Z.
/// The crowd skins it on the GPU (Crowd, Shaders/Crowd.metal); `palette` and `skin` are the same math on the CPU.
struct SkinnedCharacter: Equatable {
    /// A looping animation: every joint's rotation in its parent's space and the root's translation, at `rate` keys
    /// per second. The last key repeats the first, so a loop is `keyCount - 1` keys long.
    struct Clip: Equatable {
        var name: String
        var keyCount: Int
        var rate: Float
        var rotations: [SIMD4<Float>]      // keyCount x joints, quaternions (xyzw)
        var root: [SIMD4<Float>]           // keyCount: the root joint's translation, with the clip's travel taken out
        var velocity: SIMD3<Float>         // the travel that was taken out (m/s, in the character's space)

        var loopKeys: Int { max(keyCount - 1, 1) }
        var duration: Float { Float(loopKeys) / rate }
    }

    /// The mesh at one level of detail: bind-pose vertices, triangles, and each vertex's joints and weights.
    struct Level: Equatable {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var indices: [UInt32]
        var skin: [GPUSkinVertex]
        var triangleCount: Int { indices.count / 3 }
    }

    var name: String
    var positions: [SIMD3<Float>]      // the mesh at full detail (level 0)
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]
    var indices: [UInt32]
    var skin: [GPUSkinVertex]
    /// Levels 1, 2, ...: each about half the triangles of the one before (CharacterImporter.coarser). A crowd is
    /// skinned and traced at the level its scene asks for: a pose's cost follows its triangles.
    var coarser: [Level] = []
    var joints: [GPUJoint]             // parents first
    var jointNames: [String]
    var color: SIMD3<Float>            // its largest mesh's diffuse colour
    /// Bounds of every pose of every clip (the joints' positions, widened by how far a vertex is from its joints).
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var clips: [Clip]

    var triangleCount: Int { indices.count / 3 }
    func clip(named name: String) -> Int? { clips.firstIndex { $0.name == name } }
    /// Level `i` of detail (0 = full), or the coarsest there is.
    func level(_ i: Int) -> Level {
        i <= 0 || coarser.isEmpty ? Level(positions: positions, normals: normals, uvs: uvs, indices: indices, skin: skin)
                                  : coarser[min(i, coarser.count) - 1]
    }
}

// MARK: - Posing on the CPU

extension SkinnedCharacter {
    /// A clip's pose at `time` (in keys, inside the loop): a rotation per joint and the root's translation.
    private func sample(_ clip: Clip, _ time: Float) -> (rotations: [simd_quatf], root: SIMD3<Float>) {
        let k0 = min(max(Int(time), 0), clip.keyCount - 1), k1 = min(k0 + 1, clip.keyCount - 1)
        let f = min(max(time - Float(k0), 0), 1)
        let count = joints.count
        let rotations = (0..<count).map { j in
            Self.nlerp(clip.rotations[k0 * count + j], clip.rotations[k1 * count + j], f)
        }
        let root = simd_mix(clip.root[k0], clip.root[k1], SIMD4(repeating: f))
        return (rotations.map { simd_quatf(vector: $0) }, SIMD3(root.x, root.y, root.z))
    }

    /// Normalized blend of two quaternions the short way round (crowdPoseKernel's blend).
    static func nlerp(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        simd_normalize(a + ((dot(a, b) < 0 ? -b : b) - a) * t)
    }

    /// Every joint's pose in the character's space (a rotation and where it is): clip `clipA` at `timeA` (in keys),
    /// blended with `clipB` at `timeB` by `blend`.
    func jointPoses(clipA: Int, timeA: Float, clipB: Int = 0, timeB: Float = 0, blend: Float = 0) -> [(q: simd_quatf, t: SIMD3<Float>)] {
        var (rotations, root) = sample(clips[clipA], timeA)
        if blend > 0 {
            let b = sample(clips[clipB], timeB)
            for j in rotations.indices { rotations[j] = simd_quatf(vector: Self.nlerp(rotations[j].vector, b.rotations[j].vector, blend)) }
            root = simd_mix(root, b.root, SIMD3(repeating: blend))
        }
        var world = [(q: simd_quatf, t: SIMD3<Float>)]()
        world.reserveCapacity(joints.count)
        for (j, joint) in joints.enumerated() {
            let local = joint.parent < 0 ? root : SIMD3(joint.local.x, joint.local.y, joint.local.z)
            if joint.parent < 0 {
                world.append((rotations[j], local))
            } else {
                let p = world[joint.parent]
                world.append((p.q * rotations[j], p.q.act(local) + p.t))
            }
        }
        return world
    }

    /// Every joint's pose in the bind pose (where the mesh is): its inverse bind's inverse.
    var bindPoses: [(q: simd_quatf, t: SIMD3<Float>)] {
        joints.map { joint in
            let q = simd_quatf(vector: joint.inverseBindRotation).inverse
            return (q, -q.act(SIMD3(joint.inverseBindTranslation.x, joint.inverseBindTranslation.y, joint.inverseBindTranslation.z)))
        }
    }

    /// The skinning matrices of a pose: clip `clipA` at `timeA` (in keys), blended with `clipB` at `timeB` by `blend`.
    func palette(clipA: Int, timeA: Float, clipB: Int = 0, timeB: Float = 0, blend: Float = 0) -> [GPUJointMatrix] {
        let world = jointPoses(clipA: clipA, timeA: timeA, clipB: clipB, timeB: timeB, blend: blend)
        var out = [GPUJointMatrix]()
        out.reserveCapacity(joints.count)
        for (joint, pose) in zip(joints, world) {
            let ib = simd_quatf(vector: joint.inverseBindRotation)
            let q = pose.q * ib
            let t = pose.q.act(SIMD3(joint.inverseBindTranslation.x, joint.inverseBindTranslation.y, joint.inverseBindTranslation.z)) + pose.t
            let m = simd_float3x3(q)
            out.append(GPUJointMatrix(row0: SIMD4(m.columns.0.x, m.columns.1.x, m.columns.2.x, t.x),
                                      row1: SIMD4(m.columns.0.y, m.columns.1.y, m.columns.2.y, t.y),
                                      row2: SIMD4(m.columns.0.z, m.columns.1.z, m.columns.2.z, t.z)))
        }
        return out
    }

    /// The bind-pose mesh deformed by `palette` (linear blend skinning, as crowdSkinKernel does it).
    func skin(_ palette: [GPUJointMatrix]) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        var outP = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var outN = outP
        outP.withUnsafeMutableBufferPointer { p in
            outN.withUnsafeMutableBufferPointer { n in
                Self.skin(positions: positions, normals: normals, skin: skin, palette: palette, into: p.baseAddress!, n.baseAddress!)
            }
        }
        return (outP, outN)
    }

    /// Skins a mesh (its bind-pose `positions` and `normals`, each vertex's `skin`) into `outPositions` and `outNormals`.
    static func skin(positions: [SIMD3<Float>], normals: [SIMD3<Float>], skin: [GPUSkinVertex], palette: [GPUJointMatrix],
                     into outPositions: UnsafeMutablePointer<SIMD3<Float>>, _ outNormals: UnsafeMutablePointer<SIMD3<Float>>) {
        for v in positions.indices {
            let s = skin[v]
            let weights = (s.w0, s.w1, s.w2, 1 - s.w0 - s.w1 - s.w2)
            var m = palette[Int(s.joints & 0xFF)]
            var p = m.point(positions[v]) * weights.0, n = m.direction(normals[v]) * weights.0
            if weights.1 != 0 {
                m = palette[Int((s.joints >> 8) & 0xFF)]
                p += m.point(positions[v]) * weights.1
                n += m.direction(normals[v]) * weights.1
            }
            if weights.2 != 0 {
                m = palette[Int((s.joints >> 16) & 0xFF)]
                p += m.point(positions[v]) * weights.2
                n += m.direction(normals[v]) * weights.2
            }
            if weights.3 != 0 {
                m = palette[Int(s.joints >> 24)]
                p += m.point(positions[v]) * weights.3
                n += m.direction(normals[v]) * weights.3
            }
            outPositions[v] = p
            outNormals[v] = simd_normalize(n)
        }
    }
}

// MARK: - Import from FBX

/// Runs `count` pieces of work on all cores; the first error, if any, is thrown when they are done.
func concurrently(_ count: Int, _ work: (Int) throws -> Void) throws {
    let lock = NSLock()
    var failure: Error?
    withoutActuallyEscaping(work) { work in
        DispatchQueue.concurrentPerform(iterations: count) { i in
            do { try work(i) } catch {
                lock.lock()
                if failure == nil { failure = error }
                lock.unlock()
            }
        }
    }
    if let failure { throw failure }
}

/// Reads characters and animation clips from FBX files (FBXReader). What it reads is what Mixamo writes: meshes of
/// polygons with normals and one UV set, skins of clusters, a skeleton of limb nodes with pre-rotations, and one
/// animation layer of baked rotation curves (Euler XYZ) with a translation curve on the root.
enum CharacterImporter {
    /// An FBX file's skeleton: its bones, parents first, children by name (the same order in every file of a rig).
    struct Skeleton {
        var names: [String] = []
        var parents: [Int] = []                      // -1 = root
        var ids: [Int64] = []
        var translations: [SIMD3<Double>] = []       // in the parent's space, metres
        var preRotations: [simd_quatd] = []          // the joint's own axes in its parent's space
        var bindLocal: [simd_quatd] = []             // its rotation in the bind pose: the pre-rotation, then the model's own
        var index: [Int64: Int] = [:]                // by object id

        /// Each joint's bind rotation in model space.
        var bindRotations: [simd_quatd] {
            var out = [simd_quatd]()
            for j in names.indices { out.append(parents[j] < 0 ? bindLocal[j] : out[parents[j]] * bindLocal[j]) }
            return out
        }
        /// Each joint's bind position in model space.
        var bindPositions: [SIMD3<Double>] {
            let rotations = bindRotations
            var out = [SIMD3<Double>]()
            for j in names.indices {
                out.append(parents[j] < 0 ? translations[j] : out[parents[j]] + rotations[parents[j]].act(translations[j]))
            }
            return out
        }
    }

    /// A clip as its file has it: on the file's own skeleton, travel included.
    struct SourceClip {
        var name: String
        var skeleton: Skeleton
        var keyCount: Int
        var rate: Double
        var rotations: [simd_quatd]          // keyCount x joints, in the parent's space
        var root: [SIMD3<Double>]            // keyCount, metres
    }

    /// Euler angles in degrees, applied X then Y then Z (FBX's default rotation order).
    static func rotation(eulerDegrees e: SIMD3<Double>) -> simd_quatd {
        let r = e * (.pi / 180)
        return simd_quatd(angle: r.z, axis: [0, 0, 1]) * simd_quatd(angle: r.y, axis: [0, 1, 0]) * simd_quatd(angle: r.x, axis: [1, 0, 0])
    }

    /// Metres per file unit (`UnitScaleFactor` is centimetres per unit).
    static func unitScale(_ fbx: FBXFile) throws -> Double {
        guard let settings = fbx.top("GlobalSettings"), let p = fbx.property70(settings, "UnitScaleFactor") else { return 0.01 }
        return try fbx.double(p, 4) / 100
    }

    static func skeleton(_ fbx: FBXFile) throws -> Skeleton {
        guard let objects = fbx.top("Objects") else { throw FBXError.invalid("\(fbx.url.lastPathComponent) has no objects") }
        let unit = try unitScale(fbx)
        var bones: [Int64: Int] = [:]   // id -> node
        for n in fbx.children(objects) where fbx.isNamed(n, "Model") && (fbx.propertyIs(n, 2, "LimbNode") || fbx.propertyIs(n, 2, "Root")) {
            bones[try fbx.int(n, 0)] = n
        }
        guard !bones.isEmpty else { throw FBXError.invalid("\(fbx.url.lastPathComponent) has no skeleton") }
        var parentOf: [Int64: Int64] = [:]
        for c in fbx.connections where bones[c.child] != nil && bones[c.parent] != nil && fbx.propertyIs(Int(c.node), 0, "OO") {
            parentOf[c.child] = c.parent
        }
        var names: [Int64: String] = [:]
        for (id, n) in bones { names[id] = try fbx.string(n, 1) }
        var childrenOf: [Int64: [Int64]] = [:]
        for (child, parent) in parentOf { childrenOf[parent, default: []].append(child) }
        let roots = bones.keys.filter { parentOf[$0] == nil }.sorted { names[$0]! < names[$1]! }
        guard roots.count == 1 else { throw FBXError.unsupported("a skeleton with \(roots.count) roots") }

        var s = Skeleton()
        func add(_ id: Int64, parent: Int) throws {
            let n = bones[id]!
            if let order = fbx.property70(n, "RotationOrder"), try fbx.int(order, 4) != 0 {
                throw FBXError.unsupported("rotation orders other than XYZ (\(names[id]!))")
            }
            if let scaling = try fbx.vector70(n, "Lcl Scaling"), simd_reduce_max(simd_abs(scaling - 1)) > 1e-3 {
                throw FBXError.unsupported("scaled joints (\(names[id]!))")
            }
            let index = s.names.count
            s.names.append(names[id]!)
            s.parents.append(parent)
            s.ids.append(id)
            s.index[id] = index
            s.translations.append((try fbx.vector70(n, "Lcl Translation") ?? .zero) * unit)
            let pre = rotation(eulerDegrees: try fbx.vector70(n, "PreRotation") ?? .zero)
            s.preRotations.append(pre)
            // The bind pose: the rotation the model itself holds (none in Mixamo's files) on top of it.
            s.bindLocal.append(pre * rotation(eulerDegrees: try fbx.vector70(n, "Lcl Rotation") ?? .zero))
            for child in (childrenOf[id] ?? []).sorted(by: { names[$0]! < names[$1]! }) { try add(child, parent: index) }
        }
        try add(roots[0], parent: -1)
        guard s.names.count <= 256 else { throw FBXError.unsupported("skeletons of more than 256 joints") }
        return s
    }

    // MARK: Meshes

    private struct Part {
        var name = ""
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var skin: [GPUSkinVertex] = []
        var color = SIMD3<Float>(repeating: 0.7)
        var inverseBind: [Int: simd_double4x4] = [:]   // by joint, from the clusters
    }

    private enum Mapping { case polygonVertex, controlPoint }

    /// A layer element's mapping and, if it is indexed, its index array.
    private static func layer(_ fbx: FBXFile, _ element: Int, index: StaticString) throws -> (Mapping, [Int32]?) {
        guard let m = fbx.child(element, "MappingInformationType") else { throw FBXError.invalid("a layer without a mapping") }
        let mapping: Mapping
        if fbx.propertyIs(m, 0, "ByPolygonVertex") { mapping = .polygonVertex }
        else if fbx.propertyIs(m, 0, "ByVertice") || fbx.propertyIs(m, 0, "ByVertex") || fbx.propertyIs(m, 0, "ByControlPoint") {
            mapping = .controlPoint
        } else { throw FBXError.unsupported("layer mapping \(try fbx.string(m, 0))") }
        var indices: [Int32]?
        if let r = fbx.child(element, "ReferenceInformationType"), !fbx.propertyIs(r, 0, "Direct"), let i = fbx.child(element, index) {
            indices = try fbx.array(i)
        }
        return (mapping, indices)
    }

    /// One Geometry object as triangles with split vertices (a vertex per distinct control point, normal and UV),
    /// skinned to `skeleton`'s joints.
    private static func part(_ fbx: FBXFile, geometry: Int, skeleton: Skeleton, unit: Double) throws -> Part {
        guard let verticesNode = fbx.child(geometry, "Vertices"), let polygonsNode = fbx.child(geometry, "PolygonVertexIndex") else {
            throw FBXError.invalid("a mesh without vertices")
        }
        let normalElement = fbx.child(geometry, "LayerElementNormal"), uvElement = fbx.child(geometry, "LayerElementUV")
        let normalsNode = normalElement.flatMap { fbx.child($0, "Normals") }, uvNode = uvElement.flatMap { fbx.child($0, "UV") }

        // The mesh's skin: its clusters, each a joint with the control points it moves.
        let id = try fbx.int(geometry, 0)
        var clusters: [(node: Int, joint: Int)] = []
        for c in fbx.connections where c.parent == id {
            guard let skinNode = fbx.object(c.child), fbx.isNamed(skinNode, "Deformer"), fbx.propertyIs(skinNode, 2, "Skin") else { continue }
            for d in fbx.connections where d.parent == c.child {
                guard let cluster = fbx.object(d.child), fbx.isNamed(cluster, "Deformer") else { continue }
                for e in fbx.connections where e.parent == d.child {
                    if let joint = skeleton.index[e.child] { clusters.append((cluster, joint)) }
                }
            }
        }

        // The big arrays, inflated side by side.
        var vertices: [Double] = [], polygons: [Int32] = [], normalValues: [Double] = [], uvValues: [Double] = []
        var normalLayer: (Mapping, [Int32]?) = (.controlPoint, nil), uvLayer: (Mapping, [Int32]?) = (.controlPoint, nil)
        var influences = [(indices: [Int32], weights: [Double])](repeating: ([], []), count: clusters.count)
        try influences.withUnsafeMutableBufferPointer { slots in
            try concurrently(5 + clusters.count) { task in
                switch task {
                case 0: vertices = try fbx.array(verticesNode)
                case 1: polygons = try fbx.array(polygonsNode)
                case 2: if let normalsNode { normalValues = try fbx.array(normalsNode) }
                case 3: if let uvNode { uvValues = try fbx.array(uvNode) }
                case 4:
                    if let normalElement { normalLayer = try layer(fbx, normalElement, index: "NormalsIndex") }
                    if let uvElement { uvLayer = try layer(fbx, uvElement, index: "UVIndex") }
                default:
                    let cluster = clusters[task - 5].node
                    if let i = fbx.child(cluster, "Indexes"), let w = fbx.child(cluster, "Weights") {
                        slots[task - 5] = (try fbx.array(i), try fbx.array(w))
                    }
                }
            }
        }

        var part = Part(name: try fbx.string(geometry, 1))
        let controlPoints = vertices.count / 3

        // Up to four joints per control point: the heaviest ones, their weights scaled to sum to 1.
        var joints = [SIMD4<UInt32>](repeating: .zero, count: controlPoints)
        var weights = [SIMD4<Float>](repeating: .zero, count: controlPoints)
        var meshBind: simd_double4x4?
        for (k, cluster) in clusters.enumerated() {
            if let link = fbx.child(cluster.node, "TransformLink") {
                let m = matrix(try fbx.array(link), unit: unit)
                part.inverseBind[cluster.joint] = m.inverse
                // `Transform` is the mesh's own place at bind time, seen from the joint.
                if meshBind == nil, let t = fbx.child(cluster.node, "Transform") { meshBind = m * matrix(try fbx.array(t), unit: unit) }
            }
            let (indices, values) = influences[k]
            guard indices.count == values.count else { throw FBXError.invalid("a cluster's indices and weights differ in count") }
            for (i, w) in zip(indices, values) {
                guard i >= 0, Int(i) < controlPoints else { throw FBXError.invalid("a cluster names a vertex the mesh doesn't have") }
                let w = Float(w)
                var lightest = 0
                for s in 1..<4 where weights[Int(i)][s] < weights[Int(i)][lightest] { lightest = s }
                if w > weights[Int(i)][lightest] {
                    weights[Int(i)][lightest] = w
                    joints[Int(i)][lightest] = UInt32(cluster.joint)
                }
            }
        }
        for i in 0..<controlPoints {
            let sum = weights[i].sum()
            if sum > 0 { weights[i] /= sum } else { weights[i] = SIMD4(1, 0, 0, 0); joints[i] = .zero }   // unskinned: the root
        }
        // A mesh that doesn't sit at the origin at bind time is moved there (identity in Mixamo's files).
        let place = meshBind ?? matrix_identity_double4x4
        let placed = simd_reduce_max(simd_abs(place.columns.0 - [1, 0, 0, 0])) > 1e-6 || simd_reduce_max(simd_abs(place.columns.1 - [0, 1, 0, 0])) > 1e-6
            || simd_reduce_max(simd_abs(place.columns.2 - [0, 0, 1, 0])) > 1e-6 || simd_reduce_max(simd_abs(place.columns.3 - [0, 0, 0, 1])) > 1e-6

        // Split vertices: one per distinct (control point, normal, UV), found through an open-addressing table.
        let corners = polygons.count
        var capacity = 16
        while capacity < corners * 2 { capacity *= 2 }
        var table = [Int32](repeating: -1, count: capacity)
        var source = [Int32]()   // each vertex's control point
        part.positions.reserveCapacity(corners)
        part.normals.reserveCapacity(corners)
        part.uvs.reserveCapacity(corners)
        part.indices.reserveCapacity(corners * 3 / 2)
        source.reserveCapacity(corners)
        let (normalMapping, normalIndex) = normalLayer, (uvMapping, uvIndex) = uvLayer

        func element(_ corner: Int, _ controlPoint: Int, _ mapping: Mapping, _ index: [Int32]?) throws -> Int {
            let i = mapping == .polygonVertex ? corner : controlPoint
            guard let index else { return i }
            guard i < index.count else { throw FBXError.invalid("a layer's index is too short") }
            return Int(index[i])
        }
        var polygon: [UInt32] = []
        for corner in 0..<corners {
            let raw = polygons[corner]
            let controlPoint = Int(raw < 0 ? ~raw : raw)
            guard controlPoint < controlPoints else { throw FBXError.invalid("a polygon names a vertex the mesh doesn't have") }
            var normal = SIMD3<Float>(0, 1, 0), uv = SIMD2<Float>(0, 0)
            if !normalValues.isEmpty {
                let n = try element(corner, controlPoint, normalMapping, normalIndex)
                guard n >= 0, 3 * n + 2 < normalValues.count else { throw FBXError.invalid("a normal is out of range") }
                normal = SIMD3(Float(normalValues[3 * n]), Float(normalValues[3 * n + 1]), Float(normalValues[3 * n + 2]))
            }
            if !uvValues.isEmpty {
                let t = try element(corner, controlPoint, uvMapping, uvIndex)
                guard t >= 0, 2 * t + 1 < uvValues.count else { throw FBXError.invalid("a UV is out of range") }
                uv = SIMD2(Float(uvValues[2 * t]), 1 - Float(uvValues[2 * t + 1]))   // FBX's v runs up, the textures' down
            }
            var hash = UInt64(truncatingIfNeeded: controlPoint) &* 0x9E37_79B9_7F4A_7C15
            for bits in [normal.x.bitPattern, normal.y.bitPattern, normal.z.bitPattern, uv.x.bitPattern, uv.y.bitPattern] {
                hash = (hash ^ UInt64(bits)) &* 0xBF58_476D_1CE4_E5B9
                hash ^= hash >> 29
            }
            var slot = Int(truncatingIfNeeded: hash) & (capacity - 1)
            var vertex: Int32 = -1
            while true {
                let v = table[slot]
                if v < 0 { break }
                if source[Int(v)] == Int32(controlPoint) && part.normals[Int(v)] == normal && part.uvs[Int(v)] == uv { vertex = v; break }
                slot = (slot + 1) & (capacity - 1)
            }
            if vertex < 0 {
                vertex = Int32(part.positions.count)
                table[slot] = vertex
                source.append(Int32(controlPoint))
                part.positions.append(SIMD3(Float(vertices[3 * controlPoint] * unit), Float(vertices[3 * controlPoint + 1] * unit),
                                            Float(vertices[3 * controlPoint + 2] * unit)))
                part.normals.append(normal)
                part.uvs.append(uv)
            }
            polygon.append(UInt32(vertex))
            if raw < 0 {   // the polygon's last corner: a fan of triangles
                for k in 1..<max(polygon.count - 1, 1) { part.indices += [polygon[0], polygon[k], polygon[k + 1]] }
                polygon.removeAll(keepingCapacity: true)
            }
        }

        part.skin = source.map { cp in
            // Heaviest first, so the weight that is left over (the fourth) is the smallest.
            let order = (0..<4).sorted { weights[Int(cp)][$0] > weights[Int(cp)][$1] }
            let j = order.map { joints[Int(cp)][$0] }, w = order.map { weights[Int(cp)][$0] }
            return GPUSkinVertex(joints: j[0] | j[1] << 8 | j[2] << 16 | j[3] << 24, w0: w[0], w1: w[1], w2: w[2])
        }
        if placed {
            let linear = simd_float3x3(SIMD3<Float>(place.columns.0.xyz), SIMD3<Float>(place.columns.1.xyz), SIMD3<Float>(place.columns.2.xyz))
            let offset = SIMD3<Float>(place.columns.3.xyz)
            for v in part.positions.indices { part.positions[v] = linear * part.positions[v] + offset }
            let normalMatrix = linear.inverse.transpose
            for v in part.normals.indices { part.normals[v] = normalMatrix * part.normals[v] }
        }
        for v in part.normals.indices {
            let l = simd_length(part.normals[v])
            part.normals[v] = l > 0 ? part.normals[v] / l : SIMD3(0, 1, 0)
        }

        // Its colour: the diffuse colour of the material of the model it hangs from.
        for c in fbx.connections where c.child == id {
            guard let model = fbx.object(c.parent), fbx.isNamed(model, "Model") else { continue }
            for d in fbx.connections where d.parent == c.parent {
                guard let material = fbx.object(d.child), fbx.isNamed(material, "Material"),
                      let diffuse = try fbx.vector70(material, "DiffuseColor") else { continue }
                part.color = SIMD3<Float>(diffuse)
            }
        }
        return part
    }

    /// A 4x4 matrix as FBX stores it (16 doubles, a column after the other), its translation in metres.
    private static func matrix(_ d: [Double], unit: Double) -> simd_double4x4 {
        guard d.count == 16 else { return matrix_identity_double4x4 }
        return simd_double4x4(columns: (SIMD4(d[0], d[1], d[2], d[3]), SIMD4(d[4], d[5], d[6], d[7]), SIMD4(d[8], d[9], d[10], d[11]),
                                        SIMD4(d[12] * unit, d[13] * unit, d[14] * unit, d[15])))
    }

    /// A character file: its meshes as one, skinned to its skeleton. No clips yet.
    static func character(_ url: URL) throws -> (character: SkinnedCharacter, skeleton: Skeleton) {
        let fbx = try FBXFile(url: url, contents: [.geometry, .skin, .materials])
        let skeleton = try self.skeleton(fbx)
        let unit = try unitScale(fbx)
        guard let objects = fbx.top("Objects") else { throw FBXError.invalid("\(url.lastPathComponent) has no objects") }
        let geometries = fbx.children(objects).filter { fbx.isNamed($0, "Geometry") && fbx.propertyIs($0, 2, "Mesh") }
        guard !geometries.isEmpty else { throw FBXError.invalid("\(url.lastPathComponent) has no mesh") }
        var parts = [Part](repeating: Part(), count: geometries.count)
        try parts.withUnsafeMutableBufferPointer { slots in
            try concurrently(geometries.count) { slots[$0] = try part(fbx, geometry: geometries[$0], skeleton: skeleton, unit: unit) }
        }
        parts.sort { $0.name < $1.name }

        var c = SkinnedCharacter(name: url.deletingPathExtension().lastPathComponent, positions: [], normals: [], uvs: [], indices: [],
                                 skin: [], joints: [], jointNames: skeleton.names, color: .zero, boundsMin: .zero, boundsMax: .zero, clips: [])
        var inverseBind: [Int: simd_double4x4] = [:]
        for p in parts {
            let base = UInt32(c.positions.count)
            c.positions += p.positions
            c.normals += p.normals
            c.uvs += p.uvs
            c.indices += p.indices.map { $0 + base }
            c.skin += p.skin
            inverseBind.merge(p.inverseBind) { a, _ in a }
        }
        c.color = parts.max { $0.indices.count < $1.indices.count }!.color

        // Joints no cluster names (the ends of fingers and toes) take their inverse bind from the skeleton itself.
        let bindRotations = skeleton.bindRotations, bindPositions = skeleton.bindPositions
        for j in skeleton.names.indices {
            let rotation: simd_quatd, translation: SIMD3<Double>
            if let m = inverseBind[j] {
                let linear = simd_double3x3(simd_normalize(m.columns.0.xyz), simd_normalize(m.columns.1.xyz), simd_normalize(m.columns.2.xyz))
                guard abs(simd_length(m.columns.0.xyz) - 1) < 1e-3 else { throw FBXError.unsupported("scaled bind poses (\(skeleton.names[j]))") }
                rotation = simd_quatd(linear)
                translation = m.columns.3.xyz
            } else {
                rotation = bindRotations[j].inverse
                translation = -rotation.act(bindPositions[j])
            }
            let parent = UInt32(skeleton.parents[j] + 1)
            c.joints.append(GPUJoint(local: SIMD4(SIMD3<Float>(skeleton.translations[j]), Float(bitPattern: parent)),
                                     inverseBindRotation: SIMD4<Float>(rotation.vector),
                                     inverseBindTranslation: SIMD4(SIMD3<Float>(translation), 0)))
        }
        return (c, skeleton)
    }

    // MARK: Clips

    /// A clip file: the curves of its animation layer, sampled at their keys.
    static func clip(_ url: URL) throws -> SourceClip {
        let fbx = try FBXFile(url: url, contents: [.animation])
        let skeleton = try self.skeleton(fbx)
        let unit = try unitScale(fbx)

        // Curve nodes drive a bone's rotation or translation; the layer with the most of them is the clip.
        struct Channel { var joint: Int; var rotation: Bool; var node: Int64; var layer: Int64 = 0 }
        var channels: [Channel] = []
        for c in fbx.connections {
            guard let joint = skeleton.index[c.parent], let n = fbx.object(c.child), fbx.isNamed(n, "AnimationCurveNode") else { continue }
            if fbx.propertyIs(Int(c.node), 3, "Lcl Rotation") { channels.append(Channel(joint: joint, rotation: true, node: c.child)) }
            else if fbx.propertyIs(Int(c.node), 3, "Lcl Translation") { channels.append(Channel(joint: joint, rotation: false, node: c.child)) }
        }
        var channelOf: [Int64: Int] = [:]
        for (i, c) in channels.enumerated() { channelOf[c.node] = i }
        var layerCount: [Int64: Int] = [:]
        for c in fbx.connections {
            guard let i = channelOf[c.child], let n = fbx.object(c.parent), fbx.isNamed(n, "AnimationLayer") else { continue }
            channels[i].layer = c.parent
            layerCount[c.parent, default: 0] += 1
        }
        guard let layer = layerCount.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else {
            throw FBXError.invalid("\(url.lastPathComponent) has no animation")
        }

        // Its curves: one per axis of a channel.
        struct Curve { var channel: Int; var axis: Int; var node: Int; var times: [Int64] = []; var values: [Float] = [] }
        var curves: [Curve] = []
        for c in fbx.connections {
            guard let channel = channelOf[c.parent], channels[channel].layer == layer,
                  let n = fbx.object(c.child), fbx.isNamed(n, "AnimationCurve") else { continue }
            let axis = fbx.propertyIs(Int(c.node), 3, "d|X") ? 0 : fbx.propertyIs(Int(c.node), 3, "d|Y") ? 1 : fbx.propertyIs(Int(c.node), 3, "d|Z") ? 2 : -1
            if axis >= 0 { curves.append(Curve(channel: channel, axis: axis, node: n)) }
        }
        try curves.withUnsafeMutableBufferPointer { slots in
            try concurrently(slots.count) { i in
                guard let t = fbx.child(slots[i].node, "KeyTime"), let v = fbx.child(slots[i].node, "KeyValueFloat") else { return }
                slots[i].times = try fbx.array(t)
                slots[i].values = try fbx.array(v)
                guard slots[i].times.count == slots[i].values.count else { throw FBXError.invalid("a curve's times and values differ in count") }
            }
        }
        guard let longest = curves.max(by: { $0.times.count < $1.times.count }), longest.times.count >= 2 else {
            throw FBXError.invalid("\(url.lastPathComponent) has no animated curve")
        }
        // The keys: the longest curve's when they are evenly spaced (baked animation), else 60 per second.
        let first = longest.times[0], last = longest.times[longest.times.count - 1]
        var step = longest.times[1] &- first
        guard first >= 0, last > first, zip(longest.times, longest.times.dropFirst()).allSatisfy({ $1 > $0 }) else {
            throw FBXError.invalid("\(url.lastPathComponent) has a curve whose keys are out of order")
        }
        let even = zip(longest.times, longest.times.dropFirst()).allSatisfy { $1 - $0 == step }
        if !even { step = Int64(FBXFile.ticksPerSecond / 60) }
        let keyCount = Int((last - first) / step) + 1
        guard keyCount <= 1 << 20 else { throw FBXError.unsupported("clips of more than a million keys") }

        /// A curve's value at key `k`: its own key when it has the clip's keys, else interpolated (or held, at its ends).
        func value(_ c: Curve, _ k: Int) -> Double {
            if even && c.times.count == keyCount && c.times[0] == first { return Double(c.values[k]) }
            let t = first + Int64(k) * step
            if c.times.count == 1 || t <= c.times[0] { return Double(c.values[0]) }
            if t >= c.times[c.times.count - 1] { return Double(c.values[c.values.count - 1]) }
            var lo = 0, hi = c.times.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if c.times[mid] <= t { lo = mid } else { hi = mid }
            }
            let f = Double(t &- c.times[lo]) / max(Double(c.times[hi] &- c.times[lo]), 1)
            return Double(c.values[lo]) + (Double(c.values[hi]) - Double(c.values[lo])) * f
        }

        let jointCount = skeleton.names.count
        // Per joint and axis: its rotation curve, and the root's translation curves.
        var rotationCurve = [Int](repeating: -1, count: jointCount * 3), rootCurve = [-1, -1, -1]
        let root = skeleton.parents.firstIndex(of: -1)!
        for (i, c) in curves.enumerated() where !c.times.isEmpty {
            let channel = channels[c.channel]
            if channel.rotation { rotationCurve[channel.joint * 3 + c.axis] = i }
            else if channel.joint == root { rootCurve[c.axis] = i }
        }
        var clip = SourceClip(name: url.deletingPathExtension().lastPathComponent, skeleton: skeleton, keyCount: keyCount,
                              rate: FBXFile.ticksPerSecond / Double(step),
                              rotations: [simd_quatd](repeating: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), count: keyCount * jointCount),
                              root: [SIMD3<Double>](repeating: skeleton.translations[root], count: keyCount))
        clip.rotations.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: keyCount) { k in
                for j in 0..<jointCount {
                    var euler = SIMD3<Double>(repeating: 0)
                    var animated = false
                    for axis in 0..<3 where rotationCurve[j * 3 + axis] >= 0 {
                        euler[axis] = value(curves[rotationCurve[j * 3 + axis]], k)
                        animated = true
                    }
                    // A joint without curves keeps its bind pose.
                    out[k * jointCount + j] = animated ? skeleton.preRotations[j] * rotation(eulerDegrees: euler) : skeleton.bindLocal[j]
                }
            }
        }
        for k in 0..<keyCount {
            for axis in 0..<3 where rootCurve[axis] >= 0 { clip.root[k][axis] = value(curves[rootCurve[axis]], k) * unit }
        }
        return clip
    }

    /// `source` on `character`'s skeleton. Joints are matched by name. Each takes the source joint's rotation away
    /// from its bind pose, in model space, on top of its own bind pose, so a skeleton with other joint axes and bone
    /// lengths makes the same movement; the root's translation is scaled by the two roots' heights. The clip's travel
    /// (the root's net movement over the loop) is taken out and kept as a velocity.
    static func retarget(_ source: SourceClip, to skeleton: Skeleton) -> SkinnedCharacter.Clip {
        let count = skeleton.names.count
        let sourceIndex = Dictionary(uniqueKeysWithValues: source.skeleton.names.enumerated().map { ($1, $0) })
        let match = skeleton.names.map { sourceIndex[$0] ?? -1 }
        let sourceBind = source.skeleton.bindRotations, bind = skeleton.bindRotations
        let sourceCount = source.skeleton.names.count
        let root = skeleton.parents.firstIndex(of: -1)!, sourceRoot = source.skeleton.parents.firstIndex(of: -1)!
        let sourceHeight = simd_length(source.skeleton.translations[sourceRoot])
        let scale = sourceHeight > 1e-6 ? simd_length(skeleton.translations[root]) / sourceHeight : 1

        var clip = SkinnedCharacter.Clip(name: source.name, keyCount: source.keyCount, rate: Float(source.rate),
                                         rotations: [SIMD4<Float>](repeating: .zero, count: source.keyCount * count),
                                         root: [], velocity: .zero)
        clip.rotations.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: source.keyCount) { k in
                var sourceWorld = [simd_quatd]()
                sourceWorld.reserveCapacity(sourceCount)
                for j in 0..<sourceCount {
                    let local = source.rotations[k * sourceCount + j], parent = source.skeleton.parents[j]
                    sourceWorld.append(parent < 0 ? local : sourceWorld[parent] * local)
                }
                var world = [simd_quatd]()
                world.reserveCapacity(count)
                for j in 0..<count {
                    let parent = skeleton.parents[j]
                    let w: simd_quatd
                    if match[j] >= 0 {
                        w = sourceWorld[match[j]] * sourceBind[match[j]].inverse * bind[j]
                    } else {
                        w = parent < 0 ? skeleton.bindLocal[j] : world[parent] * skeleton.bindLocal[j]   // unmatched: its bind pose
                    }
                    world.append(w)
                    let local = simd_normalize(parent < 0 ? w : world[parent].inverse * w)
                    out[k * count + j] = SIMD4<Float>(local.vector)
                }
            }
        }
        // The same quaternion has two signs: keep each joint's from flipping between keys, so keys blend the short way.
        for k in 1..<max(source.keyCount, 1) {
            for j in 0..<count where simd_dot(clip.rotations[k * count + j], clip.rotations[(k - 1) * count + j]) < 0 {
                clip.rotations[k * count + j] = -clip.rotations[k * count + j]
            }
        }

        // Travel: what the root moves by over the loop, on the ground plane.
        var rootKeys = source.root.map { $0 * scale }
        let last = max(source.keyCount - 1, 1)
        var travel = rootKeys[source.keyCount - 1] - rootKeys[0]
        travel.y = 0
        for k in rootKeys.indices { rootKeys[k] -= travel * (Double(k) / Double(last)) }
        clip.root = rootKeys.map { SIMD4(SIMD3<Float>($0), 0) }
        let velocity = travel / (Double(last) / source.rate)
        clip.velocity = simd_length(velocity) > 0.05 ? SIMD3<Float>(velocity) : .zero
        return clip
    }

    /// Coarser levels of `character`'s mesh: each from the one before, with half its triangles (MeshSimplifier: edge
    /// collapses onto existing vertices, so a level's vertices are some of the full mesh's, with their weights).
    /// It stops where the simplifier does (at the mesh's borders and seams).
    static func coarser(_ character: SkinnedCharacter, levels: Int) -> [SkinnedCharacter.Level] {
        // Topology by position: vertices split by a normal or a UV seam share one.
        var welded: [SIMD3<Float>: Int32] = [:]
        let positionID = character.positions.map { p -> Int32 in
            if let id = welded[p] { return id }
            welded[p] = Int32(welded.count)
            return Int32(welded.count - 1)
        }
        var out: [SkinnedCharacter.Level] = []
        var triangles = character.indices
        for _ in 0..<levels {
            let target = triangles.count / 3 / 2
            var next = character.positions.withUnsafeBufferPointer { p in
                positionID.withUnsafeBufferPointer { ids in
                    character.uvs.withUnsafeBufferPointer { uvs in
                        var result = MeshSimplifier.simplify(triangles: triangles, positions: p, posId: ids, uvs: uvs,
                                                             targetTriangles: target, locked: { _ in false }).triangles
                        if result.count > triangles.count * 3 / 4 {   // stuck on seams: let them slide
                            result = MeshSimplifier.simplify(triangles: result, positions: p, posId: ids, uvs: uvs,
                                                             targetTriangles: target, relaxed: true, locked: { _ in false }).triangles
                        }
                        return result
                    }
                }
            }
            if next.isEmpty || next.count > triangles.count * 85 / 100 { break }
            triangles = next
            // The level's own vertices, in the order its triangles first name them.
            var remap = [Int32](repeating: -1, count: character.positions.count)
            var level = SkinnedCharacter.Level(positions: [], normals: [], uvs: [], indices: [], skin: [])
            for i in next.indices {
                let v = Int(next[i])
                if remap[v] < 0 {
                    remap[v] = Int32(level.positions.count)
                    level.positions.append(character.positions[v])
                    level.normals.append(character.normals[v])
                    level.uvs.append(character.uvs[v])
                    level.skin.append(character.skin[v])
                }
                next[i] = UInt32(remap[v])
            }
            level.indices = next
            out.append(level)
        }
        return out
    }

    /// Bounds of every pose of `character`'s clips: the joints' positions over all keys, widened by the furthest a
    /// vertex is from a joint that moves it (and a tenth more, for blends between clips).
    static func bounds(of character: SkinnedCharacter) -> (SIMD3<Float>, SIMD3<Float>) {
        let count = character.joints.count
        var bindWorld = [(q: simd_quatf, t: SIMD3<Float>)]()
        // Bind positions from the inverse bind transforms: the joint is where its space's origin is.
        for joint in character.joints {
            let q = simd_quatf(vector: joint.inverseBindRotation).inverse
            bindWorld.append((q, -q.act(SIMD3(joint.inverseBindTranslation.x, joint.inverseBindTranslation.y, joint.inverseBindTranslation.z))))
        }
        var reach: Float = 0
        for v in character.positions.indices {
            let s = character.skin[v]
            let weights = [s.w0, s.w1, s.w2, 1 - s.w0 - s.w1 - s.w2]
            for k in 0..<4 where weights[k] > 0.01 {
                reach = max(reach, simd_distance(character.positions[v], bindWorld[Int((s.joints >> UInt32(8 * k)) & 0xFF)].t))
            }
        }
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for clip in character.clips {
            for k in 0..<clip.keyCount {
                var world = [(q: simd_quatf, t: SIMD3<Float>)]()
                world.reserveCapacity(count)
                for (j, joint) in character.joints.enumerated() {
                    let q = simd_quatf(vector: clip.rotations[k * count + j])
                    if joint.parent < 0 {
                        world.append((q, SIMD3(clip.root[k].x, clip.root[k].y, clip.root[k].z)))
                    } else {
                        let p = world[joint.parent]
                        world.append((p.q * q, p.q.act(SIMD3(joint.local.x, joint.local.y, joint.local.z)) + p.t))
                    }
                    lo = simd_min(lo, world[j].t)
                    hi = simd_max(hi, world[j].t)
                }
            }
        }
        if character.clips.isEmpty {
            lo = character.positions.reduce(lo, simd_min)
            hi = character.positions.reduce(hi, simd_max)
            reach = 0
        }
        let margin = SIMD3<Float>(repeating: reach) + (hi - lo) * 0.1
        return (lo - margin, hi + margin)
    }
}

private extension SIMD4 where Scalar == Double {
    var xyz: SIMD3<Double> { SIMD3(x, y, z) }
}

// MARK: - The library and its cache

/// The characters in `Assets/Characters` (each `.fbx` there) with the clips in `Assets/Characters/Animations`.
/// Read from the FBX files once, then from one cache file that holds everything the crowd needs.
struct CharacterLibrary {
    var characters: [SkinnedCharacter] = []

    static var directory: URL { Scene.assetsDirectory.appendingPathComponent("Characters") }

    private static func fbxFiles(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "fbx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The library of `directory`; empty (with a message) if it has no characters or they can't be read.
    /// `cache: false` reads the FBX files and leaves the cache file alone.
    static func load(_ directory: URL = CharacterLibrary.directory, cache: Bool = true) -> CharacterLibrary {
        let characterFiles = fbxFiles(directory), clipFiles = fbxFiles(directory.appendingPathComponent("Animations"))
        guard !characterFiles.isEmpty else {
            print("Characters: no .fbx files in \(directory.path)")
            return CharacterLibrary()
        }
        let start = CFAbsoluteTimeGetCurrent()
        let cacheFile = cacheURL(for: characterFiles + clipFiles, in: directory)
        if cache, let library = try? read(cacheFile) {
            print(String(format: "Characters: %d characters, %d clips from the cache in %.1f ms", library.characters.count,
                         library.characters.first?.clips.count ?? 0, (CFAbsoluteTimeGetCurrent() - start) * 1000))
            return library
        }
        do {
            let library = try importFiles(characters: characterFiles, clips: clipFiles)
            if cache {
                do { try CacheFile.write(library.encoded(), to: cacheFile) } catch { print("Characters: could not write \(cacheFile.path): \(error)") }
            }
            return library
        } catch {
            print("Characters: \(error)")
            return CharacterLibrary()
        }
    }

    /// Reads every file at the same time, then puts every clip on every character.
    static func importFiles(characters characterFiles: [URL], clips clipFiles: [URL]) throws -> CharacterLibrary {
        let start = CFAbsoluteTimeGetCurrent()
        var characters = [(character: SkinnedCharacter, skeleton: CharacterImporter.Skeleton)?](repeating: nil, count: characterFiles.count)
        var clips = [CharacterImporter.SourceClip?](repeating: nil, count: clipFiles.count)
        try characters.withUnsafeMutableBufferPointer { characterSlots in
            try clips.withUnsafeMutableBufferPointer { clipSlots in
                try concurrently(characterFiles.count + clipFiles.count) { i in
                    if i < characterFiles.count {
                        characterSlots[i] = try CharacterImporter.character(characterFiles[i])
                    } else {
                        clipSlots[i - characterFiles.count] = try CharacterImporter.clip(clipFiles[i - characterFiles.count])
                    }
                }
            }
        }
        let read = CFAbsoluteTimeGetCurrent()
        var library = CharacterLibrary()
        for entry in characters {
            var (character, skeleton) = entry!
            character.clips = clips.map { CharacterImporter.retarget($0!, to: skeleton) }
            (character.boundsMin, character.boundsMax) = CharacterImporter.bounds(of: character)
            library.characters.append(character)
        }
        let retargeted = CFAbsoluteTimeGetCurrent()
        library.characters.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: slots.count) { i in
                slots[i].coarser = CharacterImporter.coarser(slots[i], levels: CharacterLibrary.coarserLevels)
            }
        }
        let done = CFAbsoluteTimeGetCurrent()
        let bytes = (characterFiles + clipFiles).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        print(String(format: "Characters: %d characters (%@), %d clips from %d FBX files (%.1f MB): read in %.1f ms, retargeted in %.1f ms, levels of detail in %.0f ms",
                     library.characters.count,
                     library.characters.map { c in
                         "\(c.name): \(c.joints.count) joints, \(([c.triangleCount] + c.coarser.map(\.triangleCount)).map(String.init).joined(separator: " > ")) triangles"
                     }.joined(separator: "; "),
                     clipFiles.count, characterFiles.count + clipFiles.count, Double(bytes) / 1_048_576,
                     (read - start) * 1000, (retargeted - read) * 1000, (done - retargeted) * 1000))
        return library
    }

    // MARK: Cache file

    private static let magic: UInt32 = 0x3143_474D   // "MGC1"
    static let version: UInt32 = 2
    /// Levels of detail below the full mesh: 1/2, 1/4, 1/8 and 1/16 of its triangles.
    static let coarserLevels = 4

    /// The cache file for these FBX files (by their names, sizes and modification times): in `.metalrenderer-cache`
    /// of the assets folder, or in ~/Library/Caches/MetalRenderer if that isn't writable.
    static func cacheURL(for files: [URL], in directory: URL) -> URL {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ text: String) { for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 } }
        for file in files {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: file.path)) ?? [:]
            mix(file.lastPathComponent)
            mix("\((attrs[.size] as? NSNumber)?.intValue ?? 0)-\(Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))")
        }
        let name = String(format: "characters-%016llx-v%d.mgc", hash, version)
        let local = directory.deletingLastPathComponent().appendingPathComponent(".metalrenderer-cache")
        if (try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)) != nil,
           FileManager.default.isWritableFile(atPath: local.path) {
            return local.appendingPathComponent(name)
        }
        return CacheFile.userFolder.appendingPathComponent(name)
    }

    func encoded() -> Data {
        var w = BlobWriter()
        w.put(CharacterLibrary.magic)
        w.put(CharacterLibrary.version)
        w.put(UInt32(characters.count))
        for c in characters {
            w.put(c.name)
            w.put(c.positions); w.put(c.normals); w.put(c.uvs); w.put(c.indices); w.put(c.skin); w.put(c.joints)
            w.put(UInt32(c.coarser.count))
            for l in c.coarser { w.put(l.positions); w.put(l.normals); w.put(l.uvs); w.put(l.indices); w.put(l.skin) }
            w.put(UInt32(c.jointNames.count))
            for name in c.jointNames { w.put(name) }
            w.put(c.color); w.put(c.boundsMin); w.put(c.boundsMax)
            w.put(UInt32(c.clips.count))
            for clip in c.clips {
                w.put(clip.name)
                w.put(UInt32(clip.keyCount)); w.put(clip.rate)
                w.put(clip.rotations); w.put(clip.root); w.put(clip.velocity)
            }
        }
        return w.data
    }

    static func read(_ url: URL) throws -> CharacterLibrary {
        var r = BlobReader(try Data(contentsOf: url, options: .alwaysMapped))
        guard try r.get(UInt32.self) == magic, try r.get(UInt32.self) == version else { throw FBXError.invalid("not a character cache") }
        var library = CharacterLibrary()
        for _ in 0..<Int(try r.get(UInt32.self)) {
            var c = SkinnedCharacter(name: try r.string(), positions: try r.array(), normals: try r.array(), uvs: try r.array(),
                                     indices: try r.array(), skin: try r.array(), joints: try r.array(), jointNames: [],
                                     color: .zero, boundsMin: .zero, boundsMax: .zero, clips: [])
            for _ in 0..<Int(try r.get(UInt32.self)) {
                let level = SkinnedCharacter.Level(positions: try r.array(), normals: try r.array(), uvs: try r.array(),
                                                   indices: try r.array(), skin: try r.array())
                guard level.normals.count == level.positions.count, level.skin.count == level.positions.count,
                      level.indices.allSatisfy({ Int($0) < level.positions.count }) else {
                    throw FBXError.invalid("a character cache that doesn't add up")
                }
                c.coarser.append(level)
            }
            for _ in 0..<Int(try r.get(UInt32.self)) { c.jointNames.append(try r.string()) }
            c.color = try r.get(); c.boundsMin = try r.get(); c.boundsMax = try r.get()
            for _ in 0..<Int(try r.get(UInt32.self)) {
                let name = try r.string()
                let keyCount = Int(try r.get(UInt32.self)), rate = try r.get(Float.self)
                c.clips.append(SkinnedCharacter.Clip(name: name, keyCount: keyCount, rate: rate, rotations: try r.array(),
                                                     root: try r.array(), velocity: try r.get()))
            }
            guard c.normals.count == c.positions.count, c.skin.count == c.positions.count, c.uvs.count == c.positions.count,
                  c.clips.allSatisfy({ $0.rotations.count == $0.keyCount * c.joints.count && $0.root.count == $0.keyCount }) else {
                throw FBXError.invalid("a character cache that doesn't add up")
            }
            library.characters.append(c)
        }
        return library
    }
}

/// Values and arrays of plain values, back to back (a cache file's contents).
struct BlobWriter {
    private(set) var data = Data()

    mutating func put<T>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
    mutating func put<T>(_ values: [T]) {
        put(UInt32(values.count))
        values.withUnsafeBytes { data.append(contentsOf: $0) }
    }
    mutating func put(_ text: String) { put(Array(text.utf8)) }
}

struct BlobReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }

    mutating func get<T>(_ type: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { throw FBXError.invalid("truncated cache file") }
        defer { offset += size }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
    mutating func array<T>(_ type: T.Type = T.self) throws -> [T] {
        let count = Int(try get(UInt32.self)), bytes = count * MemoryLayout<T>.stride
        guard offset + bytes <= data.count else { throw FBXError.invalid("truncated cache file") }
        defer { offset += bytes }
        return [T](unsafeUninitializedCapacity: count) { out, initialized in
            data.withUnsafeBytes { raw in
                if bytes > 0 { memcpy(out.baseAddress!, raw.baseAddress! + offset, bytes) }
            }
            initialized = count
        }
    }
    mutating func string() throws -> String { String(decoding: try array(UInt8.self), as: UTF8.self) }
}
