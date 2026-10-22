import EngineCore
import Foundation
import simd

/// A car's look from its model (CarPack): its meshes in car space (CarSpec's: x its left, y up, z forward, the origin on
/// the ground midway between its axles), each with its glTF material, what it is (paint, glass, a lamp...), the part it
/// is on (a door, the hood: by its node's name) and the window it is (a pane of its own); and its four wheels.
package struct CarModel {
    /// What a mesh is: the paint (drawn as a clear coat), a lamp (it lights, and goes dark when broken), a window, a
    /// lamp's glass (it breaks with the lamp it is nearest), other glass (a mirror's), or anything else (trim, the
    /// interior, the engine, the underbody).
    package enum Role: UInt8 {
        case paint, other, lamp, window, lampGlass, glass

        package var isGlass: Bool { self == .window || self == .lampGlass || self == .glass }
    }

    /// A mesh in car space (a wheel's: in its own, standing along y about its centre, as Scene.addCar turns it).
    package struct Mesh {
        package var positions: [SIMD3<Float>] = []
        package var normals: [SIMD3<Float>] = []
        package var uvs: [SIMD2<Float>] = []
        package var indices: [UInt32] = []
        /// Its glTF material (the model's `materials`).
        package var material: Int = -1
        package var role = Role.other
        /// The part it is on (CarBlueprint.Part's kind and side, +1 left), nil: the body.
        package var part: CarPartKind?
        package var side: Float = 0
        /// Its node's name; a window's: its pane (its place among the model's windows).
        package var node = ""
        package var window = -1
    }
    package struct Wheel {
        package var centre: SIMD3<Float>
        package var radius: Float
        package var width: Float
        package var meshes: [Mesh]
    }

    package var style: CarStyle
    package var meshes: [Mesh] = []
    /// Front left, front right, rear left, rear right (CarBlueprint.corners' order).
    package var wheels: [Wheel] = []
    /// How many windows (panes) its meshes name.
    package var windows = 0

    /// The positions of its meshes whose role passes `roles`.
    package func positions(_ roles: (Role) -> Bool) -> [SIMD3<Float>] { meshes.filter { roles($0.role) }.flatMap(\.positions) }
    /// ...of those on part `kind` (and `side`, if given).
    package func positions(of kind: CarPartKind, side: Float? = nil) -> [SIMD3<Float>] {
        meshes.filter { m in m.part == kind && (side.map { m.side == $0 } ?? true) }.flatMap(\.positions)
    }
}

/// The car models (glTF files in Assets/Cars), one a car (CarStyle), and how each file's nodes are a car: which are its
/// wheels' rims and tyres, which variants it carries to leave out, which materials are its paint, glass and lamps. Its
/// parts are found by the names every one of them uses (`partNames`): `door_FL`, `hood`, `tailgate`, `bumper_F`...;
/// its windows by theirs (`windowNames`).
///
/// A car's frame comes from its shape: its forward along the longer side of its paint's footprint (the principal axis
/// of its vertices on the ground), toward its front (`front`, in the file's space), squared with its wheels (the front
/// axle's middle less the rear's); its origin on the ground (under its wheels) between its axles.
package enum CarPack {
    /// A model's file and how to read it.
    package struct Entry {
        package var style: CarStyle
        package var file: String
        /// The credit (README, "Cars").
        package var title: String
        package var source: String
        /// Node names to leave out (another variant of a part, an old copy), and whether a node with a twin named
        /// `<its name>_LHD` gives way to it (a model of both left- and right-hand drive).
        package var exclude: String
        package var preferLHD = false
        /// The wheels' rims' and tyres' node names; the paint's, glass's and lamps' material names (regular expressions).
        package var rims: String
        package var tyres: String
        package var paint: String
        package var glass: String
        package var lamps: String
        package var front = SIMD3<Float>(0, 0, 1)
    }

    /// The four cars (KOElkast1007's, Sketchfab: README, "Cars").
    package static let entries: [Entry] = [
        Entry(style: .civic, file: "Cars/honda_civic_type_r.glb", title: "Honda Civic Type-R",
              source: "https://sketchfab.com/3d-models/honda-civic-type-r-6bc1e361969849eb99b45c933fb85e2f",
              exclude: "_OLD$", preferLHD: true, rims: "_wheel_a", tyres: "_tires_19x9", paint: "^CivicTypeR_paint", glass: "^CivicTypeR_glass",
              lamps: "^CivicTypeR_(lowhighbeam|fog|running_[LR]|signal_[LR]|taillight|reverse|brake|redfog)$"),
        Entry(style: .karoq, file: "Cars/skoda_karoq.glb", title: "Skoda Karoq",
              source: "https://sketchfab.com/3d-models/skoda-karoq-4806b6917fe3465882c50fc28f9b990d",
              exclude: "^$", rims: "^karoq_wheel_", tyres: "^tire_01a", paint: "^karoq_color$", glass: "^karoq_glass$",
              lamps: "^karoq_(taillight|chmsl|signal_[LR]|drl_signal_[LR]|reverselight|headlight|highbeam)$"),
        Entry(style: .panamera, file: "Cars/porsche_panamera.glb", title: "Porsche Panamera",
              source: "https://sketchfab.com/3d-models/porsche-panamera-a4045a52962f4301b34a839b9c4ed9b9",
              exclude: "^pan_(?!wheel).*\\\\.00[0-9]$|^pan_engine_3\\\\.0$", rims: "^pan_wheel", tyres: "^tire_01a", paint: "^pan_paint",
              glass: "^(sunburst_glass|pan_lightglass)", lamps: "^pan_(tail|rev|red|signal_[LR]1?|break|linz2?|hod)(\\\\.00[0-9])?$"),
        Entry(style: .santaFe, file: "Cars/hyundai_santa_fe_2024.glb", title: "2024 Hyundai Santa Fe",
              source: "https://sketchfab.com/3d-models/2024-hyundai-santa-fe-a1ee29b80c844b13ba56ac7e28971a53",
              exclude: "_wide$|_(i6|v8)(_turbo)?$|^santafek_header_i4$|^cubedel$|^Cube\\\\.002$", rims: "^santafek_whe", tyres: "^santafek_tire",
              paint: "^santafek_body$", glass: "^santafek_glass", lamps: "^santafek_(led2?|orange|re1?|red|stop|reverse|[LR])$"),
    ]

    /// The parts by the names the models give them (a mesh is on one when a node on its path matches): what the
    /// blueprint's parts are (CarBlueprint.Part), their side (+1 left).
    package static let partNames: [(pattern: String, kind: CarPartKind, side: Float)] = [
        ("_door(glass|panel)?_FL", .frontDoor, 1), ("_door(glass|panel)?_FR", .frontDoor, -1),
        ("_door(glass|panel)?_RL", .rearDoor, 1), ("_door(glass|panel)?_RR", .rearDoor, -1),
        ("_hood", .hood, 0), ("_tailgate", .trunk, 0), ("_bumper_F", .frontBumper, 0), ("_bumper_R", .rearBumper, 0),
        ("_mirror_L", .mirror, 1), ("_mirror_R", .mirror, -1),
    ]
    /// A glass mesh whose node is named so is a window (a pane of its own); a lamp's glass otherwise, or a mirror's or
    /// the dashboard's (`plainGlass`).
    package static let windowNames = "windshield|backlight|doorglass|sideglass|tailgateglass|sunroof|window"
    package static let plainGlass = "mirror|dash"

    /// The entry for `style`.
    package static func entry(_ style: CarStyle) -> Entry { entries.first { $0.style == style }! }

    /// Style `style`'s model and its file (loaded once, from Assets), nil when it isn't there (a clone without git-lfs,
    /// METALRENDERER_CARPACK=0): a scene then has no car of that style.
    package static func model(_ style: CarStyle) -> (model: CarModel, gltf: GLTFModel, url: URL)? {
        lock.lock()
        defer { lock.unlock() }
        if let known = loaded[style] { return known }
        let found = load(entry(style))
        loaded[style] = .some(found)
        return found
    }

    nonisolated(unsafe) private static var loaded: [CarStyle: (model: CarModel, gltf: GLTFModel, url: URL)?] = [:]
    private static let lock = NSLock()

    /// Whether the models may be loaded at all (METALRENDERER_CARPACK=0: none).
    package static var enabled: Bool { ProcessInfo.processInfo.environment["METALRENDERER_CARPACK"] != "0" }

    private static func load(_ e: Entry) -> (model: CarModel, gltf: GLTFModel, url: URL)? {
        guard enabled else { return nil }
        let url = Assets.directory.appendingPathComponent(e.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let gltf = try GLTFLoader.load(url)
            guard let model = model(gltf, e) else { return nil }
            return (model, gltf, url)
        } catch {
            print("Cars: \(e.file): \(error)")
            return nil
        }
    }

    /// Whether `name` matches regular expression `pattern`.
    private static func matches(_ name: String, _ pattern: String) -> Bool { name.range(of: pattern, options: .regularExpression) != nil }

    /// Part `k`'s positions in model space.
    private static func positions(_ gltf: GLTFModel, _ k: Int) -> [SIMD3<Float>] {
        let t = gltf.parts[k].transform
        return gltf.meshes[gltf.parts[k].mesh].positions.map { PhysicsMath.xyz(t * SIMD4($0, 1)) }
    }

    /// The car in `gltf` as entry `e` reads it (nil without paint or four wheels).
    package static func model(_ gltf: GLTFModel, _ e: Entry) -> CarModel? {
        let names = Set(gltf.nodeNames)
        func left(out path: [Int]) -> Bool {
            path.contains { n in
                let name = gltf.nodeNames[n]
                return matches(name, e.exclude) || (e.preferLHD && !name.hasSuffix("_LHD") && names.contains(name + "_LHD"))
            }
        }
        let kept = gltf.parts.indices.filter { !left(out: gltf.partNodes[$0]) }
        func material(_ k: Int) -> String {
            let m = gltf.meshes[gltf.parts[k].mesh].material ?? -1
            return gltf.materials.indices.contains(m) ? gltf.materials[m].name : ""
        }
        func path(_ k: Int) -> [String] { gltf.partNodes[k].map { gltf.nodeNames[$0] } }
        let isRim = { (k: Int) in path(k).contains { matches($0, e.rims) } }, isTyre = { (k: Int) in path(k).contains { matches($0, e.tyres) } }
        let wheelParts = kept.filter { isRim($0) || isTyre($0) }
        let bodyParts = kept.filter { !isRim($0) && !isTyre($0) }
        let paintParts = bodyParts.filter { matches(material($0), e.paint) }
        guard !paintParts.isEmpty else {
            print("Cars: \(e.file): no paint (\(e.paint))")
            return nil
        }
        // Its forward on the ground: the principal axis of its paint's footprint, toward its front.
        let points = paintParts.flatMap { positions(gltf, $0) }
        let middle = points.reduce(SIMD3<Float>(), +) / Float(points.count)
        var xx: Float = 0, xz: Float = 0, zz: Float = 0
        for p in points {
            let d = p - middle
            xx += d.x * d.x
            xz += d.x * d.z
            zz += d.z * d.z
        }
        let angle = 0.5 * atan2(2 * xz, xx - zz)
        var forward = SIMD3<Float>(cos(angle), 0, sin(angle))
        if dot(forward, e.front) < 0 { forward = -forward }
        let up = SIMD3<Float>(0, 1, 0)
        var left = cross(up, forward)
        // Its wheels: rims and tyres grouped by the corner they are at.
        var corners: [[Int]] = [[], [], [], []]
        var boxes = [(lo: SIMD3<Float>, hi: SIMD3<Float>)](repeating: (SIMD3(repeating: .infinity), SIMD3(repeating: -.infinity)), count: 4)
        for k in wheelParts {
            let all = positions(gltf, k)
            let lo = all.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }, hi = all.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            let c = (lo + hi) / 2 - middle
            let corner = (dot(c, forward) > 0 ? 0 : 2) + (dot(c, left) > 0 ? 0 : 1)
            corners[corner].append(k)
            boxes[corner] = (simd_min(boxes[corner].lo, lo), simd_max(boxes[corner].hi, hi))
        }
        guard corners.allSatisfy({ !$0.isEmpty }) else {
            print("Cars: \(e.file): wheels at \(corners.map(\.count)) corners")
            return nil
        }
        let centres = boxes.map { ($0.lo + $0.hi) / 2 }
        // Squared with the wheels: front and rear by where they are along it, left and right across.
        let frontMid = (centres[0] + centres[1]) / 2, rearMid = (centres[2] + centres[3]) / 2
        var axis = frontMid - rearMid
        axis.y = 0
        forward = normalize(axis)
        left = cross(up, forward)
        let centre = (frontMid + rearMid) / 2
        // Car space: the origin between the axles, on the ground under the wheels (a tyre's bottom).
        var radius: Float = 0
        var wheelSize: [(radius: Float, width: Float)] = []
        for (k, parts) in corners.enumerated() {
            let all = parts.filter(isTyre).flatMap { positions(gltf, $0) }
            let tyre = all.isEmpty ? parts.flatMap { positions(gltf, $0) } : all
            let r = tyre.map { simd_length(SIMD2(dot($0 - centres[k], up), dot($0 - centres[k], forward))) }.max()!
            let a = tyre.map { dot($0 - centres[k], left) }
            wheelSize.append((r, a.max()! - a.min()!))
            radius = max(radius, r)
        }
        let ground = centres.map(\.y).reduce(0, +) / 4 - radius
        let origin = SIMD3<Float>(centre.x, ground, centre.z)
        let toCar = simd_float3x3(rows: [left, up, forward])
        func mesh(_ k: Int, about pivot: SIMD3<Float>? = nil) -> CarModel.Mesh {
            let source = gltf.meshes[gltf.parts[k].mesh], t = gltf.parts[k].transform
            let turn = simd_float3x3(columns: (PhysicsMath.xyz(t.columns.0), PhysicsMath.xyz(t.columns.1), PhysicsMath.xyz(t.columns.2)))
            let normalTurn = turn.inverse.transpose
            var m = CarModel.Mesh(uvs: source.uvs, indices: source.indices, material: source.material ?? -1)
            m.positions = source.positions.map { p in
                var x = toCar * (PhysicsMath.xyz(t * SIMD4(p, 1)) - origin)
                if let pivot { x = CarPack.standing(x - pivot) }
                return x
            }
            m.normals = source.normals.map { n in
                let x = simd_normalize(toCar * (normalTurn * n))
                return pivot == nil ? x : CarPack.standing(x)
            }
            // A mirror (a negative determinant) turns the triangles inside out: wound back.
            if turn.determinant < 0 {
                for t in stride(from: 0, to: m.indices.count, by: 3) { m.indices.swapAt(t + 1, t + 2) }
            }
            return m
        }
        var model = CarModel(style: e.style)
        var windows: [String: Int] = [:]
        for k in bodyParts {
            var m = mesh(k)
            let nodes = path(k), mat = material(k)
            m.node = nodes.last ?? ""
            if let rule = partNames.first(where: { r in nodes.contains { matches($0, r.pattern) } }) {
                (m.part, m.side) = (rule.kind, rule.side)
            }
            if matches(mat, e.paint) {
                m.role = .paint
            } else if matches(mat, e.lamps) {
                m.role = .lamp
            } else if matches(mat, e.glass) {
                if let window = nodes.last(where: { matches($0, windowNames) }) {
                    m.role = .window
                    if windows[window] == nil { windows[window] = windows.count }
                    m.window = windows[window]!
                } else {
                    m.role = nodes.contains { matches($0, plainGlass) } ? .glass : .lampGlass
                }
            }
            model.meshes.append(m)
        }
        model.windows = windows.count
        // The wheels in CarBlueprint's corners' order: front left (+x), front right, rear left, rear right.
        for (k, parts) in corners.enumerated() {
            let c = toCar * (centres[k] - origin)
            model.wheels.append(CarModel.Wheel(centre: c, radius: wheelSize[k].radius, width: wheelSize[k].width, meshes: parts.map { mesh($0, about: c) }))
        }
        return model
    }

    /// Car space about a wheel's centre to the wheel's own (standing along y): the inverse of Scene.addCar's turn (a
    /// quarter turn about z, its y to the car's x).
    @inline(__always) static func standing(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-p.y, p.x, p.z) }
}
