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
///   {"bookmark": {"name": "7"}}                 the scene's bookmark (by name, number or prefix; or {"bookmark": "7"})
///   {"vg_stats": {"rows": 32, "history": 60}}   virtual geometry's report as JSON (rows: nearest instances)
///   {"vg_set": {"tau": 1, "freeze": false, "wait": true, "waitShare": 0.1, "waitPasses": 16, "recut": true,
///               "evict": "owl", "view": "LOD error", "instances": 256}}      applied in that order
///   {"camera": {"position": [...], "lookAt": [...], "yaw": 30, "pitch": -10, "fov": 60}}   angles in degrees
///
/// A rotation is `[x, y, z]` in degrees (turned about y, then x, then z) or a quaternion `[x, y, z, w]`.
package enum SceneCommand: Equatable {
    case place(SceneFile.Object, parent: String?)
    case move(name: String, position: SIMD3<Float>?, rotation: simd_quatf?, scale: SIMD3<Float>?)
    case remove(names: [String], prefix: String?)
    case camera(position: SIMD3<Float>?, lookAt: SIMD3<Float>?, yaw: Float?, pitch: Float?, fovDegrees: Float?)
    case bookmark(name: String)
    case vgStats(rows: Int, history: Int)
    case vgSet(VGSet)

    /// `vg_set`'s fields: each applied if given, in the order below.
    package struct VGSet: Equatable {
        package var tau: Float?
        package var freeze: Bool?
        package var wait: Bool?
        package var waitShare: Float?
        package var waitPasses: Int?
        package var recut = false
        package var evict: String?          // "" or "all": every mesh; else a part of a mesh's name
        package var view: Int?              // index into RenderSettings.viewModes
        package var instances: Int?
        static let keys: Set<String> = ["tau", "freeze", "wait", "waitShare", "waitPasses", "recut", "evict", "view", "instances"]
    }

    package struct Failure: Error, Equatable, CustomStringConvertible {
        package let description: String
        init(_ message: String) { description = message }
    }

    /// The request's keys this reads.
    package static let keys = ["place", "move", "remove", "camera", "bookmark", "vg_stats", "vg_set"]

    /// The command a request asks for; nil if it asks for none of these.
    package static func decode(_ request: [String: Any]) -> Result<SceneCommand, Failure>? {
        guard let key = keys.first(where: { request[$0] != nil }) else { return nil }
        if key == "bookmark", let name = request[key] as? String { return .success(.bookmark(name: name)) }
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
            case "bookmark":
                guard let name = body["name"] as? String, !name.isEmpty else { throw Failure("bookmark: needs a name") }
                return .success(.bookmark(name: name))
            case "vg_stats":
                try SceneCommand.checkKeys(body, ["rows", "history"], "vg_stats")
                let rows = try integer(body["rows"], "rows") ?? 32, history = try integer(body["history"], "history") ?? 60
                guard rows >= 0, history >= 0 else { throw Failure("vg_stats: rows and history are 0 or more") }
                return .success(.vgStats(rows: rows, history: history))
            case "vg_set":
                try SceneCommand.checkKeys(body, VGSet.keys, "vg_set")
                var v = VGSet()
                v.tau = number(body["tau"], "tau")
                if body["tau"] != nil, v.tau == nil { throw Failure("vg_set: tau is a number") }
                v.freeze = try boolean(body["freeze"], "freeze")
                v.wait = try boolean(body["wait"], "wait")
                v.waitShare = number(body["waitShare"], "waitShare")
                if body["waitShare"] != nil, v.waitShare == nil { throw Failure("vg_set: waitShare is a number") }
                v.waitPasses = try integer(body["waitPasses"], "waitPasses")
                v.recut = try boolean(body["recut"], "recut") ?? false
                if let e = body["evict"] {
                    guard let e = e as? String else { throw Failure("vg_set: evict is a string (\"\" or \"all\": every mesh, else a part of a mesh's name)") }
                    v.evict = e
                }
                if let view = body["view"] {
                    v.view = try viewMode(view)
                }
                v.instances = try integer(body["instances"], "instances")
                return .success(.vgSet(v))
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
            return SceneCommand.moveCamera(renderer, position: position, lookAt: lookAt, yaw: yaw, pitch: pitch, fov: fov)
        case .bookmark(let name):
            let bookmarks = renderer.settings.scene.kind.definition.bookmarks
            guard let b = SceneDefinition.resolve(name, in: bookmarks) else {
                let list = bookmarks.isEmpty ? "this scene has none" : bookmarks.map(\.name).joined(separator: ", ")
                return .failure(Failure("bookmark: no bookmark \"\(name)\" (the bookmarks: \(list))"))
            }
            var answer = SceneCommand.moveCamera(renderer, position: b.position, lookAt: b.lookAt, yaw: nil, pitch: nil, fov: nil)
            if case .success(var a) = answer { a["bookmark"] = b.name; answer = .success(a) }
            return answer
        case .vgStats(let rows, let history):
            return .success(SceneCommand.vgStatsAnswer(renderer, rows: rows, history: history))
        case .vgSet(let v):
            return .success(SceneCommand.vgSetApply(renderer, v))
        }
    }

    private static func vgStatsAnswer(_ renderer: Renderer, rows: Int, history: Int) -> [String: Any] {
        renderer.vgReport()?.json(rows: rows, history: history) ?? ["virtualGeometry": false]
    }

    private static func vgSetApply(_ renderer: Renderer, _ v: VGSet) -> [String: Any] {
        var applied: [String: Any] = [:]
        if let tau = v.tau {
            let r = VirtualGeometrySettings.pixelErrorRange
            renderer.settings.virtualGeometry.pixelError = min(max(tau, r.lowerBound), r.upperBound)
            applied["tau"] = Double(renderer.settings.virtualGeometry.pixelError)
        }
        if let freeze = v.freeze { renderer.settings.virtualGeometry.freeze = freeze; applied["freeze"] = freeze }
        if let wait = v.wait { renderer.settings.virtualGeometry.waitRule = wait; applied["wait"] = wait }
        if let share = v.waitShare {
            let r = VirtualGeometrySettings.waitShareRange
            renderer.settings.virtualGeometry.waitShare = min(max(share, r.lowerBound), r.upperBound)
            applied["waitShare"] = Double(renderer.settings.virtualGeometry.waitShare)
        }
        if let passes = v.waitPasses {
            let r = VirtualGeometrySettings.waitPassesRange
            renderer.settings.virtualGeometry.waitPasses = min(max(passes, r.lowerBound), r.upperBound)
            applied["waitPasses"] = renderer.settings.virtualGeometry.waitPasses
        }
        if v.recut { renderer.vgForceRecut(); applied["recut"] = true }
        if let evict = v.evict {
            let all = evict.isEmpty || evict.lowercased() == "all"
            let after = renderer.vgEvict(matching: all ? nil : evict)
            applied["evict"] = all ? "all" : evict
            applied["residency"] = after.map { ["mesh": $0.mesh, "resident": Double($0.resident)] }
        }
        if let view = v.view {
            renderer.settings.viewMode = view
            applied["view"] = RenderSettings.viewModes[view]
            applied["viewMode"] = view
        }
        if let n = v.instances {
            let r = SceneSettings.objectRange
            renderer.settings.scene.objects = min(max(n, r.lowerBound), r.upperBound)
            applied["instances"] = renderer.settings.scene.objects
        }
        return applied
    }

    private static func checkKeys(_ body: [String: Any], _ allowed: Set<String>, _ what: String) throws {
        let unknown = body.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty { throw Failure("\(what): unknown \(unknown.joined(separator: ", ")) (the keys: \(allowed.sorted().joined(separator: ", ")))") }
    }

    private static func boolean(_ value: Any?, _ what: String) throws -> Bool? {
        guard let value else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw Failure("\(what): true or false") }
        return n.boolValue
    }

    private static func integer(_ value: Any?, _ what: String) throws -> Int? {
        guard let value else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
              abs(n.doubleValue) < 1e9 else { throw Failure("\(what): give a whole number") }
        return n.intValue
    }

    /// A view's number, or its name (any case; the start of a name if one view starts so).
    private static func viewMode(_ value: Any) throws -> Int {
        let names = RenderSettings.viewModes
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            guard n.doubleValue == n.doubleValue.rounded(), names.indices.contains(n.intValue) else {
                throw Failure("view: no view numbered \(n) (0 to \(names.count - 1))")
            }
            return n.intValue
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else {
            throw Failure("view: give a view's name or number")
        }
        if let k = Int(text) {
            guard names.indices.contains(k) else { throw Failure("view: no view numbered \(k) (0 to \(names.count - 1))") }
            return k
        }
        if let k = names.firstIndex(where: { $0.lowercased() == text }) { return k }
        let starts = names.indices.filter { names[$0].lowercased().hasPrefix(text) }
        if starts.count == 1 { return starts[0] }
        let list = names.enumerated().map { "\($0) \($1)" }.joined(separator: ", ")
        throw Failure("view: no view \"\(text)\" (the views: \(list))")
    }

    private static func moveCamera(_ renderer: Renderer, position: SIMD3<Float>?, lookAt: SIMD3<Float>?, yaw: Float?, pitch: Float?,
                                   fov: Float?) -> Result<[String: Any], Failure> {
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

    /// The camera's yaw and pitch (radians) to look from `eye` at `target` (Camera.forward's inverse).
    package static func angles(from eye: SIMD3<Float>, to target: SIMD3<Float>) -> (yaw: Float, pitch: Float)? {
        let d = target - eye
        guard simd_length(d) > 1e-5 else { return nil }
        let n = simd_normalize(d)
        return (atan2(n.x, -n.z), asin(min(max(n.y, -1), 1)))
    }

    // MARK: - Reading the JSON

    private static func number(_ value: Any?) -> Float? { (value as? NSNumber).map { $0.floatValue } }
    private static func number(_ value: Any?, _ what: String) -> Float? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.floatValue
    }

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

