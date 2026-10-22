import Buildings
import Characters
import Effects
import EngineCore
import Foundation
import Materials
import Physics
import Plants
import simd

/// A scene's hand-placed content, as a binary file (Assets/Scenes/<scene>.scene): the objects put where they stand (an
/// asset each, a transform, a parent), the lights, the generators the builder runs with their seeds and parameters,
/// and the camera. The builder is still Swift (SceneDefinition.build): it reads the file, places what the file lists
/// (Scene.place), runs its generators and sets up its gameplay; a scene without a file builds from code alone.
///
/// The file is a SectionFile (mapped, nothing parsed: each section an array of one fixed-size record), so a scene of
/// thousands of objects reads in a few milliseconds. `Tools/scene/scenedump.py` prints one as text, and git shows its
/// diffs that way (README, "Scene files"). A layout change bumps `version`: a file of another version is a miss, read
/// as no file.
package struct SceneFile {
    /// A thing placed in the scene: an asset (`model:<path>`, `prefab:<name>`: SceneFile.prefabs), where it stands
    /// (in its parent's space; -1: the scene's), and what it is called in the outline.
    package struct Object: Equatable {
        package var asset: String
        package var name: String
        package var parent: Int = -1
        package var position = SIMD3<Float>.zero
        package var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        package var scale = SIMD3<Float>(repeating: 1)
        /// One of the builder's named materials (Scene.namedMaterials) in place of the asset's own; "" keeps it.
        package var material = ""
        package var flags: UInt32 = 0

        package init(asset: String, name: String, parent: Int = -1, position: SIMD3<Float> = .zero,
                     rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), scale: SIMD3<Float> = SIMD3(repeating: 1),
                     material: String = "", flags: UInt32 = 0) {
            self.asset = asset
            self.name = name
            self.parent = parent
            self.position = position
            self.rotation = rotation
            self.scale = scale
            self.material = material
            self.flags = flags
        }

        /// Its transform in its parent's space.
        package var transform: float4x4 { translate(position) * float4x4(rotation) * EngineCore.scale(scale) }
    }

    /// A light placed in the scene.
    package struct Light: Equatable {
        package enum Kind: UInt32 { case sphere, spot, rect, tube, sun }
        package var kind: Kind
        package var name: String
        package var position = SIMD3<Float>.zero
        package var direction = SIMD3<Float>(0, -1, 0)
        /// Its colour times its intensity (as Scene.addLight takes it).
        package var color = SIMD3<Float>(repeating: 1)
        /// The kind's sizes: a sphere's radius; a spot's radius, inner and outer angle; a rect's width and height; a
        /// tube's length and radius; the sun's angular radius.
        package var size = SIMD4<Float>.zero

        package init(kind: Kind, name: String, position: SIMD3<Float> = .zero, direction: SIMD3<Float> = SIMD3(0, -1, 0),
                     color: SIMD3<Float> = SIMD3(repeating: 1), size: SIMD4<Float> = .zero) {
            self.kind = kind
            self.name = name
            self.position = position
            self.direction = direction
            self.color = color
            self.size = size
        }
    }

    /// A generator the builder runs (a city's blocks, the office's blueprint): its name, its seed and its parameters.
    package struct Generator: Equatable {
        package var name: String
        package var seed: UInt64 = 0
        package var parameters: [Float] = []

        package init(name: String, seed: UInt64 = 0, parameters: [Float] = []) {
            self.name = name
            self.seed = seed
            self.parameters = parameters
        }
    }

    package var objects: [Object] = []
    package var lights: [Light] = []
    package var generators: [Generator] = []
    package var camera: Camera?

    package init(objects: [Object] = [], lights: [Light] = [], generators: [Generator] = [], camera: Camera? = nil) {
        self.objects = objects
        self.lights = lights
        self.generators = generators
        self.camera = camera
    }

    static let version = 1
    static let key = "scene/\(version)"
    /// Scene `kind`'s file.
    package static func url(for kind: SceneKind) -> URL {
        Scene.assetsDirectory.appendingPathComponent("Scenes").appendingPathComponent("\(kind.name).scene")
    }

    // MARK: - The records

    private static let strings = SectionFile.id("strs"), stringRanges = SectionFile.id("stro")
    private static let objectsID = SectionFile.id("objs"), lightsID = SectionFile.id("lite")
    private static let generatorsID = SectionFile.id("gens"), blobID = SectionFile.id("blob"), cameraID = SectionFile.id("camr")

    /// An object as the file has it: its strings as indices into the string table.
    struct ObjectRecord {
        var position: SIMD4<Float>      // w: 0
        var rotation: SIMD4<Float>      // the quaternion's x, y, z, w
        var scale: SIMD4<Float>         // w: 0
        var asset: UInt32, name: UInt32, material: UInt32
        var parent: Int32
        var flags: UInt32
        var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    }
    struct LightRecord {
        var position: SIMD4<Float>      // w: the kind
        var direction: SIMD4<Float>
        var color: SIMD4<Float>
        var size: SIMD4<Float>
        var name: UInt32
        var pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    }
    struct GeneratorRecord {
        var seed: UInt64
        var name: UInt32
        var first: UInt32, count: UInt32  // its parameters in the blob
        var pad: UInt32 = 0
    }
    struct CameraRecord {
        var position: SIMD4<Float>      // w: yaw
        var angles: SIMD4<Float>        // pitch, vertical field of view
    }

    /// The records' sizes are the file's: a change of one is a new version.
    static func validateLayouts() {
        precondition(MemoryLayout<ObjectRecord>.stride == 80, "SceneFile.ObjectRecord stride")
        precondition(MemoryLayout<LightRecord>.stride == 80, "SceneFile.LightRecord stride")
        precondition(MemoryLayout<GeneratorRecord>.stride == 24, "SceneFile.GeneratorRecord stride")
        precondition(MemoryLayout<CameraRecord>.stride == 32, "SceneFile.CameraRecord stride")
    }

    // MARK: - Reading and writing

    /// The file at `url`; nil when there is none, it is of another version, or it is cut short.
    package init?(url: URL) {
        SceneFile.validateLayouts()
        guard let file = SectionFile(url: url, key: SceneFile.key) else { return nil }
        let bytes = file.array(SceneFile.strings, of: UInt8.self) ?? []
        let ranges = file.array(SceneFile.stringRanges, of: SIMD2<UInt32>.self) ?? []
        func string(_ i: UInt32) -> String {
            guard ranges.indices.contains(Int(i)) else { return "" }
            let r = ranges[Int(i)], lo = Int(r.x), hi = Int(r.x + r.y)
            guard lo <= hi, hi <= bytes.count else { return "" }
            return String(decoding: bytes[lo..<hi], as: UTF8.self)
        }
        objects = (file.array(SceneFile.objectsID, of: ObjectRecord.self) ?? []).map { o in
            Object(asset: string(o.asset), name: string(o.name), parent: Int(o.parent), position: SIMD3(o.position.x, o.position.y, o.position.z),
                   rotation: simd_quatf(vector: o.rotation), scale: SIMD3(o.scale.x, o.scale.y, o.scale.z), material: string(o.material), flags: o.flags)
        }
        lights = (file.array(SceneFile.lightsID, of: LightRecord.self) ?? []).compactMap { l in
            guard let kind = Light.Kind(rawValue: UInt32(l.position.w)) else { return nil }
            return Light(kind: kind, name: string(l.name), position: SIMD3(l.position.x, l.position.y, l.position.z),
                         direction: SIMD3(l.direction.x, l.direction.y, l.direction.z), color: SIMD3(l.color.x, l.color.y, l.color.z), size: l.size)
        }
        let blob = file.array(SceneFile.blobID, of: Float.self) ?? []
        generators = (file.array(SceneFile.generatorsID, of: GeneratorRecord.self) ?? []).map { g in
            let lo = min(Int(g.first), blob.count), hi = min(lo + Int(g.count), blob.count)
            return Generator(name: string(g.name), seed: g.seed, parameters: Array(blob[lo..<hi]))
        }
        if let c = file.array(SceneFile.cameraID, of: CameraRecord.self)?.first {
            var camera = Camera()
            camera.position = SIMD3(c.position.x, c.position.y, c.position.z)
            camera.yaw = c.position.w
            camera.pitch = c.angles.x
            camera.fovY = c.angles.y
            self.camera = camera
        }
    }

    /// Scene `kind`'s file, if it has one.
    package init?(_ kind: SceneKind) { self.init(url: SceneFile.url(for: kind)) }

    /// Writes the file (to a temporary one first, then moved into place: a reader never sees half of it).
    package func write(to url: URL) throws {
        SceneFile.validateLayouts()
        var bytes: [UInt8] = [], ranges: [SIMD2<UInt32>] = [], index: [String: UInt32] = [:]
        func string(_ s: String) -> UInt32 {
            if let i = index[s] { return i }
            let i = UInt32(ranges.count), utf8 = Array(s.utf8)
            ranges.append(SIMD2(UInt32(bytes.count), UInt32(utf8.count)))
            bytes += utf8
            index[s] = i
            return i
        }
        let objectRecords = objects.map { o in
            ObjectRecord(position: SIMD4(o.position, 0), rotation: o.rotation.vector, scale: SIMD4(o.scale, 0),
                         asset: string(o.asset), name: string(o.name), material: string(o.material), parent: Int32(o.parent), flags: o.flags)
        }
        let lightRecords = lights.map { l in
            LightRecord(position: SIMD4(l.position, Float(l.kind.rawValue)), direction: SIMD4(l.direction, 0), color: SIMD4(l.color, 0),
                        size: l.size, name: string(l.name))
        }
        var blob: [Float] = []
        let generatorRecords = generators.map { g -> GeneratorRecord in
            defer { blob += g.parameters }
            return GeneratorRecord(seed: g.seed, name: string(g.name), first: UInt32(blob.count), count: UInt32(g.parameters.count))
        }
        var writer = SectionFile.Writer()
        writer.add(SceneFile.objectsID, objectRecords)
        writer.add(SceneFile.lightsID, lightRecords)
        writer.add(SceneFile.generatorsID, generatorRecords)
        writer.add(SceneFile.blobID, blob)
        if let c = camera {
            writer.add(SceneFile.cameraID, [CameraRecord(position: SIMD4(c.position, c.yaw), angles: SIMD4(c.pitch, c.fovY, 0, 0))])
        }
        writer.add(SceneFile.strings, bytes)
        writer.add(SceneFile.stringRanges, ranges)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer.write(to: url, key: SceneFile.key)
    }

    // MARK: - Prefabs

    /// What a `prefab:<name>` asset puts in a scene, at a transform: the instances it made. The engine has the kit's
    /// shapes (box, ball, quad); a game registers its own (SceneFile.register).
    package typealias Prefab = (Scene, float4x4, Int?) -> [Int]
    private static var registered: [String: Prefab] = [
        "box": { scene, t, m in [scene.addInstance(scene.kitMesh(.box), m ?? scene.defaultMaterial(), t)] },
        "ball": { scene, t, m in [scene.addInstance(scene.kitMesh(.ball), m ?? scene.defaultMaterial(), t)] },
        "quad": { scene, t, m in [scene.addInstance(scene.kitMesh(.quad), m ?? scene.defaultMaterial(), t)] },
    ]
    package static func register(prefab name: String, _ make: @escaping Prefab) { registered[name] = make }
    package static func prefab(_ name: String) -> Prefab? { registered[name] }
}

extension SceneFile.Object {
    /// The object's world transform, its parents' applied (`objects`: the file's list it is in).
    package func world(in objects: [SceneFile.Object]) -> float4x4 {
        var t = transform, p = parent, guardSteps = objects.count
        while objects.indices.contains(p), guardSteps > 0 {
            t = objects[p].transform * t
            p = objects[p].parent
            guardSteps -= 1
        }
        return t
    }
}
