import Foundation
import simd

/// A model loaded from glTF 2.0 (`.glb`, or `.gltf` with external or embedded buffers and images): triangle meshes,
/// metallic-roughness materials and their images, flattened into mesh parts with model-space transforms.
/// Static geometry only: skins, morph targets, animations and cameras are ignored. Punctual lights
/// (KHR_lights_punctual: point, spot, directional) come with their node transforms.
struct GLTFModel {
    struct Mesh {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]          // TEXCOORD_0, or zeros
        var indices: [UInt32]            // triangles, relative to this mesh's vertices
        var material: Int?               // index into `materials`
    }
    struct TextureRef {
        var image: Int                   // index into `images`
    }
    struct Material {
        var name = ""
        var baseColor = SIMD4<Float>(1, 1, 1, 1)
        var metallic: Float = 1          // glTF defaults (fully metallic until a texture or factor says otherwise)
        var roughness: Float = 1
        var emissive = SIMD3<Float>(0, 0, 0)
        var normalScale: Float = 1
        var baseColorTexture: TextureRef?
        var metallicRoughnessTexture: TextureRef?   // G = roughness, B = metallic
        var normalTexture: TextureRef?
        var emissiveTexture: TextureRef?
    }
    struct Image {
        var data: Data                   // encoded (PNG, JPEG, ...), decoded later with ImageIO
        var name: String
    }
    /// A KHR_lights_punctual light placed by a node: it sits at the transform's origin and points down its -Z.
    struct Light {
        enum Kind { case point, spot(inner: Float, outer: Float), directional }
        var kind: Kind
        var color: SIMD3<Float>          // linear
        var intensity: Float             // candela (point, spot) or lux (directional)
        var transform: float4x4          // model space
    }

    var name: String
    var meshes: [Mesh] = []
    var parts: [(mesh: Int, transform: float4x4)] = []   // one per mesh use in the node hierarchy
    var materials: [Material] = []
    var images: [Image] = []
    var lights: [Light] = []

    var triangleCount: Int { parts.reduce(0) { $0 + meshes[$1.mesh].indices.count / 3 } }

    /// Model-space bounds of all parts.
    var bounds: AABB {
        var b = AABB()
        for part in parts {
            for p in meshes[part.mesh].positions {
                let q = part.transform * SIMD4<Float>(p, 1)
                b.grow(SIMD3(q.x, q.y, q.z))
            }
        }
        return b
    }
}

enum GLTFError: Error, CustomStringConvertible {
    case invalid(String)
    case unsupported(String)
    var description: String {
        switch self {
        case .invalid(let s): return "invalid glTF: \(s)"
        case .unsupported(let s): return "unsupported glTF feature: \(s)"
        }
    }
}

enum GLTFLoader {
    // MARK: JSON schema (the parts we read)

    private struct Document: Decodable {
        var asset: Asset
        var scene: Int?
        var scenes: [SceneDef]?
        var nodes: [Node]?
        var meshes: [MeshDef]?
        var accessors: [Accessor]?
        var bufferViews: [BufferView]?
        var buffers: [Buffer]?
        var materials: [MaterialDef]?
        var textures: [Texture]?
        var images: [ImageDef]?
        var extensionsRequired: [String]?
        var extensions: DocumentExtensions?
    }
    private struct DocumentExtensions: Decodable { var KHR_lights_punctual: PunctualLights? }
    private struct PunctualLights: Decodable { var lights: [PunctualLight] }
    private struct PunctualLight: Decodable {
        var type: String
        var color: [Float]?
        var intensity: Float?
        var spot: Spot?
        struct Spot: Decodable { var innerConeAngle: Float?; var outerConeAngle: Float? }
    }
    private struct NodeExtensions: Decodable { var KHR_lights_punctual: NodeLight? }
    private struct NodeLight: Decodable { var light: Int }
    private struct Asset: Decodable { var version: String }
    private struct SceneDef: Decodable { var nodes: [Int]? }
    private struct Node: Decodable {
        var children: [Int]?
        var mesh: Int?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
        var extensions: NodeExtensions?
    }
    private struct MeshDef: Decodable { var primitives: [Primitive] }
    private struct Primitive: Decodable {
        var attributes: [String: Int]
        var indices: Int?
        var material: Int?
        var mode: Int?
    }
    private struct Accessor: Decodable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
        var sparse: AnyDecodable?
    }
    private struct BufferView: Decodable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
    }
    private struct Buffer: Decodable { var uri: String?; var byteLength: Int }
    private struct TextureInfo: Decodable { var index: Int; var texCoord: Int?; var scale: Float? }
    private struct PBR: Decodable {
        var baseColorFactor: [Float]?
        var baseColorTexture: TextureInfo?
        var metallicFactor: Float?
        var roughnessFactor: Float?
        var metallicRoughnessTexture: TextureInfo?
    }
    private struct EmissiveStrength: Decodable { var emissiveStrength: Float? }
    private struct MaterialExtensions: Decodable {
        var KHR_materials_emissive_strength: EmissiveStrength?
    }
    private struct MaterialDef: Decodable {
        var name: String?
        var pbrMetallicRoughness: PBR?
        var normalTexture: TextureInfo?
        var emissiveTexture: TextureInfo?
        var emissiveFactor: [Float]?
        var extensions: MaterialExtensions?
    }
    private struct Texture: Decodable { var source: Int? }
    private struct ImageDef: Decodable { var uri: String?; var bufferView: Int?; var mimeType: String?; var name: String? }
    /// Skips any JSON value (used to detect fields we don't support).
    private struct AnyDecodable: Decodable { init(from decoder: Decoder) throws {} }

    /// Extensions that change how data must be read; a file that requires anything else is rejected.
    private static let supportedRequired: Set<String> = ["KHR_materials_emissive_strength", "KHR_lights_punctual"]

    // MARK: Loading

    static func load(_ url: URL) throws -> GLTFModel {
        let file = try Data(contentsOf: url, options: .mappedIfSafe)
        // A clone without git-lfs checks out the pointer text in place of the model.
        if file.starts(with: Data("version https://git-lfs".utf8)) {
            throw GLTFError.invalid("\(url.lastPathComponent) is a Git LFS pointer, not the model: install git-lfs and run git lfs pull")
        }
        var json: Data
        var bin: Data?
        if file.count >= 12, file.prefix(4) == Data("glTF".utf8) {
            (json, bin) = try splitGLB(file)
        } else {
            json = file
        }
        let doc = try JSONDecoder().decode(Document.self, from: json)
        guard doc.asset.version.hasPrefix("2") else { throw GLTFError.unsupported("glTF version \(doc.asset.version)") }
        if let required = doc.extensionsRequired?.filter({ !supportedRequired.contains($0) }), !required.isEmpty {
            throw GLTFError.unsupported("required extensions \(required.joined(separator: ", "))")
        }

        // Buffers: the GLB binary chunk, data: URIs or files next to the model.
        let buffers: [Data] = try (doc.buffers ?? []).enumerated().map { i, b in
            if let uri = b.uri { return try resolve(uri: uri, relativeTo: url) }
            guard i == 0, let bin else { throw GLTFError.invalid("buffer \(i) has no data") }
            return bin
        }
        func view(_ index: Int) throws -> (data: Data, offset: Int, length: Int, stride: Int?) {
            guard let views = doc.bufferViews, views.indices.contains(index) else { throw GLTFError.invalid("bufferView \(index)") }
            let v = views[index]
            guard buffers.indices.contains(v.buffer) else { throw GLTFError.invalid("buffer \(v.buffer)") }
            return (buffers[v.buffer], v.byteOffset ?? 0, v.byteLength, v.byteStride)
        }

        var model = GLTFModel(name: url.deletingPathExtension().lastPathComponent)

        // Images stay encoded; the renderer decodes them at the size it wants.
        for (i, img) in (doc.images ?? []).enumerated() {
            let data: Data
            if let bv = img.bufferView {
                let v = try view(bv)
                data = v.data.subdata(in: (v.data.startIndex + v.offset)..<(v.data.startIndex + v.offset + v.length))
            } else if let uri = img.uri {
                data = try resolve(uri: uri, relativeTo: url)
            } else {
                throw GLTFError.invalid("image \(i) has no data")
            }
            model.images.append(.init(data: data, name: img.name ?? "image\(i)"))
        }

        func textureRef(_ info: TextureInfo?) -> GLTFModel.TextureRef? {
            guard let info, let textures = doc.textures, textures.indices.contains(info.index),
                  let source = textures[info.index].source, model.images.indices.contains(source) else { return nil }
            if (info.texCoord ?? 0) != 0 { print("glTF: \(model.name): texture uses TEXCOORD_\(info.texCoord!), reading TEXCOORD_0") }
            return .init(image: source)
        }
        for m in doc.materials ?? [] {
            var out = GLTFModel.Material(name: m.name ?? "")
            let pbr = m.pbrMetallicRoughness
            if let f = pbr?.baseColorFactor, f.count == 4 { out.baseColor = SIMD4(f[0], f[1], f[2], f[3]) }
            out.metallic = pbr?.metallicFactor ?? 1
            out.roughness = pbr?.roughnessFactor ?? 1
            if let e = m.emissiveFactor, e.count == 3 { out.emissive = SIMD3(e[0], e[1], e[2]) }
            out.emissive *= m.extensions?.KHR_materials_emissive_strength?.emissiveStrength ?? 1
            out.normalScale = m.normalTexture?.scale ?? 1
            out.baseColorTexture = textureRef(pbr?.baseColorTexture)
            out.metallicRoughnessTexture = textureRef(pbr?.metallicRoughnessTexture)
            out.normalTexture = textureRef(m.normalTexture)
            out.emissiveTexture = textureRef(m.emissiveTexture)
            model.materials.append(out)
        }

        // Accessors -> typed arrays.
        func accessor(_ index: Int) throws -> Accessor {
            guard let a = doc.accessors, a.indices.contains(index) else { throw GLTFError.invalid("accessor \(index)") }
            if a[index].sparse != nil { throw GLTFError.unsupported("sparse accessors") }
            return a[index]
        }
        func components(_ type: String) -> Int {
            ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][type] ?? 0
        }
        /// Reads an accessor as floats (normalized integers scaled to [0, 1] or [-1, 1]), `n` components per element.
        func readFloats(_ index: Int, _ n: Int) throws -> [Float] {
            let a = try accessor(index)
            let comps = components(a.type)
            guard comps >= n else { throw GLTFError.invalid("accessor \(index) has \(comps) components, need \(n)") }
            guard let bv = a.bufferView else { return [Float](repeating: 0, count: a.count * n) }
            let v = try view(bv)
            let size = [5126: 4, 5125: 4, 5123: 2, 5122: 2, 5121: 1, 5120: 1][a.componentType] ?? 0
            guard size > 0 else { throw GLTFError.invalid("componentType \(a.componentType)") }
            let stride = v.stride ?? comps * size
            let base = v.offset + (a.byteOffset ?? 0)
            guard a.count == 0 || base + (a.count - 1) * stride + comps * size <= v.data.count else {
                throw GLTFError.invalid("accessor \(index) runs past its buffer")
            }
            var out = [Float](repeating: 0, count: a.count * n)
            let norm = a.normalized ?? false
            v.data.withUnsafeBytes { raw in
                for i in 0..<a.count {
                    for c in 0..<n {
                        let o = base + i * stride + c * size
                        let value: Float
                        switch a.componentType {
                        case 5126: value = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                        case 5125: value = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                        case 5123: let x = raw.loadUnaligned(fromByteOffset: o, as: UInt16.self); value = norm ? Float(x) / 65535 : Float(x)
                        case 5122: let x = raw.loadUnaligned(fromByteOffset: o, as: Int16.self); value = norm ? max(Float(x) / 32767, -1) : Float(x)
                        case 5121: let x = raw.load(fromByteOffset: o, as: UInt8.self); value = norm ? Float(x) / 255 : Float(x)
                        default:   let x = raw.load(fromByteOffset: o, as: Int8.self); value = norm ? max(Float(x) / 127, -1) : Float(x)
                        }
                        out[i * n + c] = value
                    }
                }
            }
            return out
        }
        /// An accessor of 32-bit float vectors, read straight into SIMD values (the usual case for positions, normals
        /// and texture coordinates: no intermediate array, no per-component type test). `load` reads one vector at a
        /// byte offset. nil when the accessor holds another type: `readFloats` converts those.
        func readVectors<T>(_ index: Int, _ n: Int, _ load: (UnsafeRawBufferPointer, Int) -> T) throws -> [T]? {
            let a = try accessor(index)
            let comps = components(a.type)
            guard a.componentType == 5126, comps >= n, let bv = a.bufferView else { return nil }
            let v = try view(bv)
            let stride = v.stride ?? comps * 4
            let base = v.offset + (a.byteOffset ?? 0)
            guard a.count == 0 || base + (a.count - 1) * stride + comps * 4 <= v.data.count else {
                throw GLTFError.invalid("accessor \(index) runs past its buffer")
            }
            return v.data.withUnsafeBytes { raw in
                [T](unsafeUninitializedCapacity: a.count) { out, count in
                    for i in 0..<a.count { (out.baseAddress! + i).initialize(to: load(raw, base + i * stride)) }
                    count = a.count
                }
            }
        }
        func readVec3(_ index: Int) throws -> [SIMD3<Float>] {
            if let fast = try readVectors(index, 3, { raw, o in
                SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                      raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
            }) { return fast }
            let f = try readFloats(index, 3)
            return (0..<f.count / 3).map { SIMD3(f[3 * $0], f[3 * $0 + 1], f[3 * $0 + 2]) }
        }
        func readVec2(_ index: Int) throws -> [SIMD2<Float>] {
            if let fast = try readVectors(index, 2, { raw, o in
                SIMD2(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self))
            }) { return fast }
            let f = try readFloats(index, 2)
            return (0..<f.count / 2).map { SIMD2(f[2 * $0], f[2 * $0 + 1]) }
        }
        func readIndices(_ index: Int) throws -> [UInt32] {
            let a = try accessor(index)
            guard let bv = a.bufferView else { throw GLTFError.invalid("index accessor without data") }
            let v = try view(bv)
            let size = [5125: 4, 5123: 2, 5121: 1][a.componentType] ?? 0
            guard size > 0 else { throw GLTFError.invalid("index componentType \(a.componentType)") }
            let stride = v.stride ?? size
            let base = v.offset + (a.byteOffset ?? 0)
            guard a.count == 0 || base + (a.count - 1) * stride + size <= v.data.count else {
                throw GLTFError.invalid("index accessor runs past its buffer")
            }
            let count = a.count
            return v.data.withUnsafeBytes { raw in
                [UInt32](unsafeUninitializedCapacity: count) { out, written in
                    switch size {   // one loop per index type: the test is not in the loop
                    case 4: for i in 0..<count { out[i] = raw.loadUnaligned(fromByteOffset: base + i * stride, as: UInt32.self) }
                    case 2: for i in 0..<count { out[i] = UInt32(raw.loadUnaligned(fromByteOffset: base + i * stride, as: UInt16.self)) }
                    default: for i in 0..<count { out[i] = UInt32(raw.load(fromByteOffset: base + i * stride, as: UInt8.self)) }
                    }
                    written = count
                }
            }
        }

        // Meshes: one GLTFModel.Mesh per triangle primitive.
        var meshPrimitives: [[Int]] = []   // glTF mesh -> our meshes
        for (mi, m) in (doc.meshes ?? []).enumerated() {
            var ours: [Int] = []
            for p in m.primitives {
                guard (p.mode ?? 4) == 4 else {
                    print("glTF: \(model.name): mesh \(mi) has a non-triangle primitive (mode \(p.mode!)), skipped")
                    continue
                }
                guard let posIndex = p.attributes["POSITION"] else { continue }
                let positions = try readVec3(posIndex)
                let count = positions.count
                let indices = try p.indices.map(readIndices) ?? (0..<UInt32(count)).map { $0 }
                guard indices.allSatisfy({ Int($0) < count }) else { throw GLTFError.invalid("index out of range in mesh \(mi)") }
                var normals: [SIMD3<Float>]
                if let ni = p.attributes["NORMAL"] {
                    normals = try readVec3(ni)
                    if normals.count > count { normals.removeLast(normals.count - count) }
                    guard normals.count == count else { throw GLTFError.invalid("mesh \(mi): \(normals.count) normals for \(count) positions") }
                } else {
                    normals = GLTFLoader.vertexNormals(positions, indices)
                }
                var uvs = [SIMD2<Float>](repeating: .zero, count: count)
                if let ti = p.attributes["TEXCOORD_0"] {
                    uvs = try readVec2(ti)
                    if uvs.count > count { uvs.removeLast(uvs.count - count) }
                    guard uvs.count == count else { throw GLTFError.invalid("mesh \(mi): \(uvs.count) texture coordinates for \(count) positions") }
                }
                model.meshes.append(.init(positions: positions, normals: normals, uvs: uvs, indices: indices, material: p.material))
                ours.append(model.meshes.count - 1)
            }
            meshPrimitives.append(ours)
        }

        // Node hierarchy -> parts with model-space transforms.
        let nodes = doc.nodes ?? []
        func local(_ n: Node) -> float4x4 {
            if let m = n.matrix, m.count == 16 {
                return float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
            }
            var t = matrix_identity_float4x4
            if let tr = n.translation, tr.count == 3 { t = translate(SIMD3(tr[0], tr[1], tr[2])) }
            var r = matrix_identity_float4x4
            if let q = n.rotation, q.count == 4 { r = float4x4(simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])) }
            var s = matrix_identity_float4x4
            if let sc = n.scale, sc.count == 3 { s = scale(SIMD3(sc[0], sc[1], sc[2])) }
            return t * r * s
        }
        func visit(_ index: Int, _ parent: float4x4, depth: Int) {
            guard nodes.indices.contains(index), depth < 64 else { return }
            let n = nodes[index]
            let world = parent * local(n)
            if let m = n.mesh, meshPrimitives.indices.contains(m) {
                for mesh in meshPrimitives[m] { model.parts.append((mesh, world)) }
            }
            if let l = n.extensions?.KHR_lights_punctual?.light, let lights = doc.extensions?.KHR_lights_punctual?.lights,
               lights.indices.contains(l) {
                let def = lights[l]
                let kind: GLTFModel.Light.Kind?
                switch def.type {
                case "point": kind = .point
                case "directional": kind = .directional
                case "spot": kind = .spot(inner: def.spot?.innerConeAngle ?? 0, outer: def.spot?.outerConeAngle ?? .pi / 4)
                default: kind = nil
                }
                let c = def.color ?? [1, 1, 1]
                if let kind, c.count == 3 {
                    model.lights.append(GLTFModel.Light(kind: kind, color: SIMD3(c[0], c[1], c[2]),
                                                        intensity: def.intensity ?? 1, transform: world))
                }
            }
            for c in n.children ?? [] { visit(c, world, depth: depth + 1) }
        }
        var roots: [Int]
        if let scenes = doc.scenes, !scenes.isEmpty {
            roots = scenes[min(doc.scene ?? 0, scenes.count - 1)].nodes ?? []
        } else {
            let children = Set(nodes.flatMap { $0.children ?? [] })
            roots = nodes.indices.filter { !children.contains($0) }
        }
        for r in roots { visit(r, matrix_identity_float4x4, depth: 0) }
        if model.parts.isEmpty {   // no node hierarchy: every mesh once, untransformed
            model.parts = model.meshes.indices.map { ($0, matrix_identity_float4x4) }
        }
        return model
    }

    private static func splitGLB(_ file: Data) throws -> (Data, Data?) {
        func u32(_ o: Int) -> UInt32 { file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        guard u32(4) == 2 else { throw GLTFError.unsupported("GLB version \(u32(4))") }
        let total = min(Int(u32(8)), file.count)
        var offset = 12
        var json: Data?, bin: Data?
        while offset + 8 <= total {
            let length = Int(u32(offset)), type = u32(offset + 4)
            let start = file.startIndex + offset + 8
            guard offset + 8 + length <= total else { throw GLTFError.invalid("GLB chunk runs past the file") }
            let chunk = file.subdata(in: start..<(start + length))
            if type == 0x4E4F_534A { json = chunk } else if type == 0x004E_4942, bin == nil { bin = chunk }
            offset += 8 + (length + 3) & ~3
        }
        guard let json else { throw GLTFError.invalid("GLB without a JSON chunk") }
        return (json, bin)
    }

    private static func resolve(uri: String, relativeTo url: URL) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                throw GLTFError.unsupported("data URI that isn't base64")
            }
            return data
        }
        let path = uri.removingPercentEncoding ?? uri
        return try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(path), options: .mappedIfSafe)
    }

    /// Area-weighted vertex normals, for meshes that come without them.
    static func vertexNormals(_ p: [SIMD3<Float>], _ idx: [UInt32]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: p.count)
        for t in stride(from: 0, to: idx.count - 2, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let f = cross(p[b] - p[a], p[c] - p[a])
            n[a] += f; n[b] += f; n[c] += f
        }
        return n.map { length($0) > 0 ? normalize($0) : SIMD3(0, 1, 0) }
    }
}
