import EngineCore
import Foundation
import simd

/// The tools' typed requests to the scene (the socket's `place`, `move`, `remove` and `camera`): what a script would
/// do in a few lines, done without compiling one. They are the scripts promoted to tools (the app-control skill's
/// rule): each is a plain edit of the scene's file (`SceneFile.upsert`, `removeObjects`) or of the camera.
///
///   {"place": {"asset": "prefab:box", "name": "Crate", "position": [0, 0.5, 0], "rotation": [0, 45, 0],
///              "scale": [1, 1, 1], "material": "wood", "parent": "Table"}}       an object of that name is replaced
///   {"move": {"name": "Crate", "position": [...], "rotation": [...], "scale": [...]}}   live, no new scene
///   {"remove": {"names": ["Crate"], "prefix": "Grid "}}                            with what hangs from them
///   {"camera": {"position": [...], "lookAt": [...], "yaw": 30, "pitch": -10, "fov": 60}}   angles in degrees
///
/// A rotation is `[x, y, z]` in degrees (turned about y, then x, then z) or a quaternion `[x, y, z, w]`.
package enum SceneCommand: Equatable {
    case place(SceneFile.Object, parent: String?)
    case move(name: String, position: SIMD3<Float>?, rotation: simd_quatf?, scale: SIMD3<Float>?)
    case remove(names: [String], prefix: String?)
    case camera(position: SIMD3<Float>?, lookAt: SIMD3<Float>?, yaw: Float?, pitch: Float?, fovDegrees: Float?)

    package struct Failure: Error, Equatable, CustomStringConvertible {
        package let description: String
        init(_ message: String) { description = message }
    }

    /// The request's keys this reads.
    package static let keys = ["place", "move", "remove", "camera"]

    /// The command a request asks for; nil if it asks for none of these.
    package static func decode(_ request: [String: Any]) -> Result<SceneCommand, Failure>? {
        guard let key = keys.first(where: { request[$0] != nil }) else { return nil }
        guard let body = request[key] as? [String: Any] else { return .failure(Failure("\(key): give an object")) }
        do {
            switch key {
            case "place":
                guard let asset = body["asset"] as? String, !asset.isEmpty else { throw Failure("place: needs an asset (prefab:box, prefab:ball, prefab:quad, model:<path>)") }
                let name = body["name"] as? String ?? asset.split(separator: ":").last.map(String.init) ?? asset
                var o = SceneFile.Object(asset: asset, name: name)
                if let p = try vector(body["position"], "position") { o.position = p }
                if let r = try rotation(body["rotation"]) { o.rotation = r }
                if let s = try scale(body["scale"]) { o.scale = s }
                o.material = body["material"] as? String ?? ""
                return .success(.place(o, parent: body["parent"] as? String))
            case "move":
                guard let name = body["name"] as? String else { throw Failure("move: needs the object's name") }
                return .success(.move(name: name, position: try vector(body["position"], "position"),
                                      rotation: try rotation(body["rotation"]), scale: try scale(body["scale"])))
            case "remove":
                let names = body["names"] as? [String] ?? (body["name"] as? String).map { [$0] } ?? []
                let prefix = body["prefix"] as? String
                guard !names.isEmpty || !(prefix ?? "").isEmpty else { throw Failure("remove: give names or a prefix") }
                return .success(.remove(names: names, prefix: prefix))
            default:
                return .success(.camera(position: try vector(body["position"], "position"), lookAt: try vector(body["lookAt"], "lookAt"),
                                        yaw: number(body["yaw"]), pitch: number(body["pitch"]), fovDegrees: number(body["fov"])))
            }
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure("\(error)"))
        }
    }

    // MARK: - Doing it

    /// Does it (render thread): the scene file edited and written (Renderer.editPlaced), or the camera moved. What it
    /// did, for the tool's answer.
    package func apply(to renderer: Renderer) -> Result<[String: Any], Failure> {
        switch self {
        case .place(var object, let parent):
            var result: Result<[String: Any], Failure> = .failure(Failure("nothing placed"))
            renderer.editPlaced { file in
                if let parent {
                    guard let p = file.index(named: parent) else { result = .failure(Failure("place: no object named \(parent)")); return }
                    object.parent = p
                }
                let (index, replaced) = file.upsert(object)
                result = .success(["name": object.name, "index": index, "replaced": replaced, "objects": file.objects.count])
            }
            return result
        case .move(let name, let position, let rotation, let scale):
            var result: Result<[String: Any], Failure> = .failure(Failure("move: no object named \(name)"))
            renderer.editPlaced { file in
                guard let k = file.index(named: name) else { return }
                if let position { file.objects[k].position = position }
                if let rotation { file.objects[k].rotation = rotation }
                if let scale { file.objects[k].scale = scale }
                result = .success(["name": name, "index": k])
            }
            return result
        case .remove(let names, let prefix):
            var removed = 0
            renderer.editPlaced { file in
                let gone = Set(file.objects.indices.filter { k in
                    names.contains(file.objects[k].name) || prefix.map { !$0.isEmpty && file.objects[k].name.hasPrefix($0) } ?? false
                })
                removed = file.removeObjects(gone)
            }
            return .success(["removed": removed])
        case .camera(let position, let lookAt, let yaw, let pitch, let fov):
            var camera = renderer.camera
            if let position { camera.position = position }
            if let yaw { camera.yaw = yaw * .pi / 180 }
            if let pitch { camera.pitch = pitch * .pi / 180 }
            if let lookAt {
                guard let (y, p) = SceneCommand.angles(from: camera.position, to: lookAt) else {
                    return .failure(Failure("camera: lookAt is where the camera is"))
                }
                camera.yaw = y
                camera.pitch = p
            }
            renderer.camera = camera
            if let fov { renderer.settings.fovDegrees = fov }
            return .success(["position": [camera.position.x, camera.position.y, camera.position.z].map(Double.init),
                             "yaw": Double(camera.yaw * 180 / .pi), "pitch": Double(camera.pitch * 180 / .pi)])
        }
    }

    /// The camera's yaw and pitch (radians) to look from `eye` at `target` (Camera.forward's inverse).
    package static func angles(from eye: SIMD3<Float>, to target: SIMD3<Float>) -> (yaw: Float, pitch: Float)? {
        let d = target - eye
        guard simd_length(d) > 1e-5 else { return nil }
        let n = simd_normalize(d)
        return (atan2(n.x, -n.z), asin(min(max(n.y, -1), 1)))
    }

    // MARK: - Reading the JSON

    private static func number(_ value: Any?) -> Float? { (value as? NSNumber).map { $0.floatValue } }

    private static func numbers(_ value: Any?, _ what: String) throws -> [Float]? {
        guard let value else { return nil }
        guard let list = value as? [Any], list.allSatisfy({ $0 is NSNumber }) else { throw Failure("\(what): give a list of numbers") }
        return list.map { ($0 as! NSNumber).floatValue }
    }

    private static func vector(_ value: Any?, _ what: String) throws -> SIMD3<Float>? {
        guard let v = try numbers(value, what) else { return nil }
        guard v.count == 3 else { throw Failure("\(what): give [x, y, z]") }
        return SIMD3(v[0], v[1], v[2])
    }

    private static func scale(_ value: Any?) throws -> SIMD3<Float>? {
        if let s = value as? NSNumber { return SIMD3(repeating: s.floatValue) }
        return try vector(value, "scale")
    }

    /// `[x, y, z]` degrees, turned about y, then x, then z; or a quaternion `[x, y, z, w]`.
    private static func rotation(_ value: Any?) throws -> simd_quatf? {
        guard let r = try numbers(value, "rotation") else { return nil }
        let rad: Float = .pi / 180
        switch r.count {
        case 3:
            return simd_normalize(simd_quatf(angle: r[1] * rad, axis: [0, 1, 0]) * simd_quatf(angle: r[0] * rad, axis: [1, 0, 0])
                                  * simd_quatf(angle: r[2] * rad, axis: [0, 0, 1]))
        case 4:
            return simd_normalize(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
        default:
            throw Failure("rotation: give [x, y, z] in degrees or a quaternion [x, y, z, w]")
        }
    }
}

extension SceneFile {
    /// The object named `name`, if there is one (the first).
    package func index(named name: String) -> Int? { objects.firstIndex { $0.name == name } }

    /// `object` in the file: in place of the one of its name (its children stay its), or at the end.
    package mutating func upsert(_ object: Object) -> (index: Int, replaced: Bool) {
        if let k = index(named: object.name) {
            objects[k] = object
            return (k, true)
        }
        objects.append(object)
        return (objects.count - 1, false)
    }

    /// Objects `gone` out of the file, with what hangs from them; the others' parents renumbered. How many went.
    @discardableResult
    package mutating func removeObjects(_ gone: Set<Int>) -> Int {
        var gone = gone
        var grew = !gone.isEmpty
        while grew {
            let more = objects.indices.filter { !gone.contains($0) && gone.contains(objects[$0].parent) }
            grew = !more.isEmpty
            gone.formUnion(more)
        }
        var renumber: [Int: Int] = [:]
        var kept: [Object] = []
        for (j, o) in objects.enumerated() where !gone.contains(j) {
            renumber[j] = kept.count
            kept.append(o)
        }
        for j in kept.indices { kept[j].parent = renumber[kept[j].parent] ?? -1 }
        let removed = objects.count - kept.count
        objects = kept
        return removed
    }
}

