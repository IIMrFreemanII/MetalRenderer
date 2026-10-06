import Foundation
import simd

/// The SDF shapes scene (SDFShapes.swift): a studio with a row of primitives on plinths, a row of shapes cut and
/// blended out of several (one of them a mesh baked into a distance grid), and glowing shapes that light the room as
/// mesh lights do.
extension Scene {
    func buildShapes() {
        let kit = Kit(self)
        skyColor = [0.02, 0.02, 0.025]
        let floor = addPBRMaterial(baseColor: [0.14, 0.14, 0.15], metallic: 0, roughness: 0.2)
        let wall = addMaterial(albedo: [0.62, 0.62, 0.64])
        let plinth = addMaterial(albedo: [0.75, 0.75, 0.75])
        kit.room(width: 14, height: 5, depth: 14, floor: floor, walls: wall, ceiling: true)

        func shape(_ nodes: [SDFShape.Node]) -> Int { addSDFShape(SDFShape(nodes)) }
        func node(_ p: SDFShape.Primitive, _ op: SDFShape.Op = .union, smooth: Float = 0, at position: SIMD3<Float> = .zero,
                  rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), material: Int = 0) -> SDFShape.Node {
            SDFShape.Node(p, op, smooth: smooth, at: position, rotation: rotation, material: material)
        }
        /// Two materials in a row: a node's offset 1 is the second.
        func pair(_ a: Int, _ b: GPUMaterial) -> Int { let first = a; _ = addMaterial(b); return first }

        // The primitives, each on a plinth, its foot on the plinth's top.
        let z0: Float = -0.6, top: Float = 0.3
        let primitives: [(SDFShape.Primitive, Float, Int, simd_quatf)] = [
            (.sphere(radius: 0.42), 0.42, addPBRMaterial(baseColor: [0.75, 0.1, 0.08], metallic: 0, roughness: 0.3), simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)),
            (.box(halfExtents: [0.36, 0.36, 0.36], rounding: 0.08), 0.36, addMaterial(albedo: [0.8, 0.8, 0.8]), simd_quatf(angle: 0.5, axis: [0, 1, 0])),
            (.torus(major: 0.32, minor: 0.12), 0.44, addPBRMaterial(baseColor: [1.0, 0.78, 0.35], metallic: 1, roughness: 0.25),
             simd_quatf(angle: .pi / 2, axis: [1, 0, 0])),
            (.capsule(halfLength: 0.22, radius: 0.2), 0.42, addPBRMaterial(baseColor: [0.1, 0.25, 0.7], metallic: 0, roughness: 0.15),
             simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)),
            (.cylinder(halfHeight: 0.38, radius: 0.3, rounding: 0.06), 0.38, addMaterial(albedo: [0.2, 0.55, 0.25]), simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)),
            (.cone(halfHeight: 0.4, bottom: 0.38, top: 0.08), 0.4, addPBRMaterial(baseColor: [0.9, 0.45, 0.1], metallic: 0, roughness: 0.4),
             simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)),
        ]
        for (i, (p, half, material, rotation)) in primitives.enumerated() {
            let x = -4 + 1.6 * Float(i)
            kit.box([x, top / 2, z0], [0.9, top, 0.9], plinth)
            addInstance(sdf: shape([node(p)]), material, translate([x, top + half, z0]) * float4x4(rotation))
        }

        // Cuts and blends, between the primitives and behind them.
        let z1: Float = -3.0
        let x1 = (0..<6).map { -4.8 + 1.6 * Float($0) }
        // A rounded cube of brick (its texture projected along its axes: an SDF shape has no UVs) with a sphere cut
        // out of it, the cut in a colour of its own, turning slowly.
        var brick = GPUMaterial(albedo: [0.9, 0.9, 0.9, 0], emission: [0, 0, 0, 1])
        if let maps = ProceduralTextures.sources([.brick], size: 512)[.brick] { brick.textures.x = addTexture(maps.base) }
        let cut = pair(addMaterial(brick), GPUMaterial(albedo: [0.85, 0.15, 0.1, 0], emission: [0, 0, 0, 1]))
        addInstance(sdf: shape([node(.box(halfExtents: [0.42, 0.42, 0.42], rounding: 0.04)),
                                node(.sphere(radius: 0.55), .subtract, material: 1)]),
                    cut, translate([x1[0], 0.6, z1])) { t in translate([x1[0], 0.6, z1]) * rotate(0.3 * t, [0, 1, 0]) * rotate(0.6, [1, 0, 0]) }
        // Three spheres flowing into each other: chrome.
        addInstance(sdf: shape([node(.sphere(radius: 0.32), at: [-0.3, 0, 0]),
                                node(.sphere(radius: 0.26), smooth: 0.3, at: [0.28, 0.1, 0.05]),
                                node(.sphere(radius: 0.2), smooth: 0.3, at: [0, 0.42, -0.05])]),
                    addPBRMaterial(baseColor: [0.95, 0.95, 0.97], metallic: 1, roughness: 0.08), translate([x1[1], 0.42, z1]))
        // The classic: a box and a sphere's intersection with three cylinders cut through it.
        let csg = pair(addPBRMaterial(baseColor: [0.2, 0.35, 0.75], metallic: 0, roughness: 0.35),
                       GPUMaterial(albedo: [0.9, 0.85, 0.7, 0], emission: [0, 0, 0, 1]))
        addInstance(sdf: shape([node(.box(halfExtents: [0.4, 0.4, 0.4])),
                                node(.sphere(radius: 0.53), .intersect),
                                node(.cylinder(halfHeight: 0.6, radius: 0.22), .subtract, material: 1),
                                node(.cylinder(halfHeight: 0.6, radius: 0.22), .subtract, rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]), material: 1),
                                node(.cylinder(halfHeight: 0.6, radius: 0.22), .subtract, rotation: simd_quatf(angle: .pi / 2, axis: [0, 0, 1]), material: 1)]),
                    csg, translate([x1[2], 0.4, z1]) * rotate(0.6, [0, 1, 0]))
        // Two materials blended: a slab and a ball melting into it.
        let blend = pair(addMaterial(albedo: [0.75, 0.7, 0.62]), GPUMaterial(albedo: [0.2, 0.6, 0.3, 0], emission: [0, 0, 0, 0.3], params: [1, 1, 0, 0]))
        addInstance(sdf: shape([node(.box(halfExtents: [0.45, 0.12, 0.45], rounding: 0.03)),
                                node(.sphere(radius: 0.3), smooth: 0.25, at: [0, 0.38, 0], material: 1)]),
                    blend, translate([x1[3], 0.12, z1]))
        // A cylinder with a ring cut out of its waist, blended.
        addInstance(sdf: shape([node(.cylinder(halfHeight: 0.45, radius: 0.3, rounding: 0.05)),
                                node(.torus(major: 0.33, minor: 0.12), .subtract, smooth: 0.08)]),
                    addPBRMaterial(baseColor: [0.6, 0.35, 0.2], metallic: 1, roughness: 0.35), translate([x1[4], 0.45, z1]))
        // A mesh baked into a distance grid (a torus knot), melted onto a pedestal.
        let knot = addSDFVolume(SDFVolume.cached(Scene.torusKnotMesh(), resolution: 64))
        addInstance(sdf: shape([node(.volume(knot), at: [0, 0.62, 0], rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0])),
                                node(.box(halfExtents: [0.4, 0.1, 0.4], rounding: 0.03), smooth: 0.12, at: [0, 0.1, 0])]),
                    addPBRMaterial(baseColor: [0.85, 0.5, 0.35], metallic: 1, roughness: 0.25), translate([x1[5], 0, z1]))

        // Glowing shapes: a blob lamp on a stand in the back left, and a ring turning in the back right.
        kit.box([-5.2, 0.4, -5.4], [0.7, 0.8, 0.7], plinth)
        addInstance(sdf: shape([node(.sphere(radius: 0.3)),
                                node(.sphere(radius: 0.22), smooth: 0.25, at: [0.15, 0.35, 0.05]),
                                node(.sphere(radius: 0.16), smooth: 0.2, at: [-0.1, 0.62, -0.05]),
                                node(.capsule(halfLength: 0.15, radius: 0.08), smooth: 0.15, at: [0, 0.85, 0])]),
                    addMaterial(albedo: .zero, emission: [1.0, 0.5, 0.18] * 6), translate([-5.2, 1.1, -5.4]))
        addInstance(sdf: shape([node(.torus(major: 0.5, minor: 0.05))]), addMaterial(albedo: .zero, emission: Scene.hue([0.15, 0.85, 1.0]) * 5),
                    matrix_identity_float4x4) { t in translate([5, 2.0, -5]) * rotate(0.5 * t, [0, 1, 0]) * rotate(1.1, [1, 0, 0]) }

        // A panel overhead and a light circling the shapes.
        addLight(.rect(width: 4, height: 1.2), color: SIMD3<Float>(1.0, 0.96, 0.9) * 4, motion: .constant) { _ in
            LightPose(position: [0, 4.97, -1.8], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        addLight(color: SIMD3<Float>(0.9, 0.92, 1.0) * 6, radius: 0.08, sphereMesh: kit.sphere) { t in
            [3.5 * sin(0.4 * t), 2.2, -2 + 3.5 * cos(0.4 * t)]
        }
        defaultCamera = Scene.demoCamera(.shapes)!
    }

    /// A (2, 3) torus knot as a closed tube: `size` across, its tube `radius` thick.
    static func torusKnotMesh(size: Float = 0.9, radius: Float = 0.075, segments: Int = 240, sides: Int = 16) -> MeshGeometry {
        let s = size / 6   // the curve reaches 3 from its axis
        func curve(_ t: Float) -> SIMD3<Float> {
            SIMD3((2 + cos(3 * t)) * cos(2 * t), (2 + cos(3 * t)) * sin(2 * t), sin(3 * t)) * s
        }
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        var normal = SIMD3<Float>(0, 0, 1)
        for i in 0..<segments {
            let t = 2 * Float.pi * Float(i) / Float(segments)
            let c = curve(t), tangent = normalize(curve(t + 1e-3) - curve(t - 1e-3))
            normal = normalize(normal - tangent * dot(normal, tangent))   // carried along the curve (no twist)
            let binormal = cross(tangent, normal)
            for j in 0..<sides {
                let a = 2 * Float.pi * Float(j) / Float(sides)
                let n = normal * cos(a) + binormal * sin(a)
                positions.append(c + n * radius)
                normals.append(n)
            }
        }
        for i in 0..<segments {
            let next = (i + 1) % segments
            for j in 0..<sides {
                let k = (j + 1) % sides
                let (a, b, c, d) = (i * sides + j, i * sides + k, next * sides + k, next * sides + j)
                indices += [a, d, c, a, c, b].map { UInt32($0) }
            }
        }
        return (positions, normals, indices)
    }
}
