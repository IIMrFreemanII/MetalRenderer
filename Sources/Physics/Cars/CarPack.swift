import EngineCore
import Foundation
import simd

/// A car's look from a model (CarPack): its body's meshes in car space (CarSpec's: x its left, y up, z forward, the
/// origin on the ground midway between its axles), and its four wheels.
package struct CarModel {
    /// A mesh in car space (a wheel's: in its own, standing along y about its centre, as Scene.wheelMesh's), its
    /// material (the pack's `materials`).
    package struct Mesh {
        package var positions: [SIMD3<Float>] = []
        package var normals: [SIMD3<Float>] = []
        package var uvs: [SIMD2<Float>] = []
        package var indices: [UInt32] = []
        package var material: Int = -1
    }
    package struct Wheel {
        package var centre: SIMD3<Float>
        package var radius: Float
        package var width: Float
        package var meshes: [Mesh]
    }

    package var style: CarStyle
    /// The paint (the body's shell, its trim and its details in one texture), the lamps, the glass.
    package var paint = Mesh()
    package var lamps = Mesh()
    package var glass = Mesh()
    /// Front left, front right, rear left, rear right (CarBlueprint.corners' order).
    package var wheels: [Wheel] = []
}

/// A pack of car models (a glTF file: Assets/Cars, `file`) and how its nodes are cars: which node is each style's
/// body (its paint, glass and lamps its children's meshes, named `_Body_0`, `_Glass_0`, `_Optics_0`), and which way
/// its front is in that node's own space; its wheels are the root's nodes named `Wheel_`, each the car's whose
/// footprint it is in.
///
/// A car's frame comes from its shape (a body's node isn't always square with it): its forward along the longer side
/// of its footprint (the principal axis of its paint's vertices on the ground), toward the end its node's hint says,
/// then squared with its wheels (the front axle's middle less the rear's); its origin on the ground (under its wheels)
/// between its axles.
package enum CarPack {
    /// "Generic passenger car pack" by Comrade1280 (Sketchfab, CC BY 4.0: README, "Cars").
    package static let file = "Cars/generic_passenger_car_pack.glb"

    /// Each style's body node, and its front in the node's space.
    package static let bodies: [(style: CarStyle, node: String, front: SIMD3<Float>)] = [
        (.sedan, "Sedan Body", [0, -1, 0]), (.hatchback, "Hatchback Body", [0, -1, 0]), (.pickup, "Pickup Body", [0, -1, 0]),
        (.coupe, "Coupe Body", [1, 0, 0]), (.wagon, "Wagon Body", [0, -1, 0]), (.compact, "Compact Body", [0, -1, 0]),
        (.minivan, "minivan body", [0, -1, 0]), (.sport, "Sport body", [0, -1, 0]), (.suv, "SUV Body", [0, -1, 0]),
        (.offroad, "Offroad Body", [0, -1, 0]),
    ]

    /// The pack's models and materials (loaded once, from Assets), nil when it isn't there (a clone without git-lfs,
    /// METALRENDERER_CARPACK=0): the cars are then the procedural ones.
    package static let shared: (models: [CarStyle: CarModel], gltf: GLTFModel, url: URL)? = {
        guard ProcessInfo.processInfo.environment["METALRENDERER_CARPACK"] != "0" else { return nil }
        let url = Assets.directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let gltf = try GLTFLoader.load(url)
            let models = CarPack.models(gltf)
            return models.isEmpty ? nil : (models, gltf, url)
        } catch {
            print("Car pack: \(error)")
            return nil
        }
    }()

    /// The cars in `gltf`, by style (those whose body and four wheels were found).
    package static func models(_ gltf: GLTFModel) -> [CarStyle: CarModel] {
        // The wheels: the meshes under each node named Wheel_, in model space.
        var wheelParts: [Int: [Int]] = [:]
        for (k, path) in gltf.partNodes.enumerated() {
            if let w = path.first(where: { gltf.nodeNames[$0].hasPrefix("Wheel_") }) { wheelParts[w, default: []].append(k) }
        }
        let wheels = wheelParts.sorted { $0.key < $1.key }.map { $0.value }
        var out: [CarStyle: CarModel] = [:]
        for entry in bodies {
            guard let node = gltf.nodeNames.firstIndex(of: entry.node) else { continue }
            let parts = gltf.partNodes.indices.filter { gltf.partNodes[$0].contains(node) }
            if let model = model(gltf, entry.style, parts: parts, front: entry.front, wheels: wheels) { out[entry.style] = model }
        }
        return out
    }

    /// Part `k`'s positions in model space.
    private static func positions(_ gltf: GLTFModel, _ k: Int) -> [SIMD3<Float>] {
        let t = gltf.parts[k].transform
        return gltf.meshes[gltf.parts[k].mesh].positions.map { PhysicsMath.xyz(t * SIMD4($0, 1)) }
    }

    private static func model(_ gltf: GLTFModel, _ style: CarStyle, parts: [Int], front hint: SIMD3<Float>, wheels: [[Int]]) -> CarModel? {
        func part(_ suffix: String) -> Int? { parts.first { gltf.nodeNames[gltf.partNodes[$0].last!].hasSuffix(suffix) } }
        guard let paint = part("_Body_0") else { return nil }
        // Its forward on the ground: the principal axis of its paint's footprint, toward the hint's end.
        let points = positions(gltf, paint)
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
        var hinted = PhysicsMath.xyz(gltf.parts[paint].transform * SIMD4(hint, 0))
        hinted.y = 0
        if dot(forward, hinted) < 0 { forward = -forward }
        let up = SIMD3<Float>(0, 1, 0)
        var left = cross(up, forward)
        // Its wheels: those whose centres are within its footprint.
        let along = points.map { dot($0 - middle, forward) }, across = points.map { dot($0 - middle, left) }
        let length = (along.min()!, along.max()!), width = (across.min()!, across.max()!)
        var found: [(centre: SIMD3<Float>, parts: [Int])] = []
        for w in wheels {
            let all = w.flatMap { positions(gltf, $0) }
            let lo = all.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = all.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            let c = (lo + hi) / 2, a = dot(c - middle, forward), s = dot(c - middle, left)
            if a > length.0 && a < length.1 && s > width.0 - 0.1 && s < width.1 + 0.1 { found.append((c, w)) }
        }
        guard found.count == 4 else {
            print("Car pack: \(style.title): \(found.count) wheels in its footprint")
            return nil
        }
        // Squared with the wheels: front and rear by where they are along it, left and right across.
        found.sort { dot($0.centre, forward) > dot($1.centre, forward) }
        let frontMid = (found[0].centre + found[1].centre) / 2, rearMid = (found[2].centre + found[3].centre) / 2
        var axis = frontMid - rearMid
        axis.y = 0
        forward = normalize(axis)
        left = cross(up, forward)
        let centre = (frontMid + rearMid) / 2
        // Car space: the origin between the axles, on the ground under the wheels.
        var radius: Float = 0
        var wheelSize: [(radius: Float, width: Float)] = []
        for w in found {
            let all = w.parts.flatMap { positions(gltf, $0) }
            let r = all.map { simd_length(SIMD2(dot($0 - w.centre, up), dot($0 - w.centre, forward))) }.max()!
            let a = all.map { dot($0 - w.centre, left) }
            wheelSize.append((r, a.max()! - a.min()!))
            radius = max(radius, r)
        }
        let ground = found.map { $0.centre.y }.reduce(0, +) / 4 - radius
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
        var model = CarModel(style: style)
        model.paint = mesh(paint)
        if let k = part("_Optics_0") { model.lamps = mesh(k) }
        if let k = part("_Glass_0") { model.glass = mesh(k) }
        // The wheels in CarBlueprint's corners' order: front left (+x), front right, rear left, rear right.
        let corners = found.enumerated().map { (k, w) in (k, toCar * (w.centre - origin)) }
        let ordered = corners.sorted { a, b in
            let fa = a.1.z > 0, fb = b.1.z > 0
            return fa != fb ? fa : a.1.x > b.1.x
        }
        for (k, c) in ordered {
            model.wheels.append(CarModel.Wheel(centre: c, radius: wheelSize[k].radius, width: wheelSize[k].width,
                                               meshes: found[k].parts.map { mesh($0, about: c) }))
        }
        return model
    }

    /// Car space about a wheel's centre to the wheel's own (standing along y): the inverse of Scene.addCar's turn (a
    /// quarter turn about z, its y to the car's x).
    @inline(__always) static func standing(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-p.y, p.x, p.z) }
}
