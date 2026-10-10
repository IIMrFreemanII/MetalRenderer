import Foundation
import simd

/// The material workshop: one Material Designer graph (`SceneSettings.materialWorkshop.graph`, by name: the
/// catalog's, or MaterialLibrary's) on a sphere, a rounded cube, a cylinder and a flat tile, lined up (or one of them
/// alone), against a backdrop:
/// - studio: a grey cyclorama, a key light and a fill;
/// - outdoor: a plain under the sun and a blue sky;
/// - dark: a dark floor, one soft light from above.
/// Its material is procedural (Scene+Procedural): the renderer bakes its graph and puts the textures in its slots, and
/// an edit of the graph (the catalog's key, `SceneSettings.materials`) bakes again in place, without making the scene
/// again. The camera turns about the shapes (`focus`, SceneKind.orbits).
extension Scene {
    func buildMaterialWorkshop() {
        let kit = Kit(self)
        let w = settings.materialWorkshop
        materialBackdrop(w.backdrop, kit)
        let material = addProceduralMaterial(graph: w.graph, catalog: MaterialCatalog.resolve(settings.materials))
        let plinth = addPBRMaterial(baseColor: [0.16, 0.16, 0.17], metallic: 0, roughness: 0.5)
        let shapes: [MaterialWorkshopSettings.Layout] = w.layout == .lineup ? [.sphere, .cube, .cylinder, .plane] : [w.layout]
        var bounds = AABB()
        for (i, shape) in shapes.enumerated() {
            let x = (Float(i) - Float(shapes.count - 1) / 2) * 2.6
            let (mesh, transform, size) = materialShape(shape)
            // A low plinth under it.
            kit.box([x, 0.05, 0], [2, 0.1, 2], plinth)
            addInstance(mesh, material, translate([x, 0.1, 0]) * transform)
            if shape == .card {
                // The card's tile on the ground: the material as a decal, once across it.
                let tile: MeshGeometry = ([[-0.9, 0.01, -0.9], [0.9, 0.01, -0.9], [0.9, 0.01, 0.9], [-0.9, 0.01, 0.9]],
                                          [[0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 1, 0]], [0, 2, 1, 0, 3, 2])
                addInstance(addMesh(tile, uvs: [[0, 0], [1, 0], [1, 1], [0, 1]]), material, translate([x, 0.1, 0]))
            }
            bounds.grow([x - size.x / 2, 0, -size.z / 2])
            bounds.grow([x + size.x / 2, 0.1 + size.y, size.z / 2])
        }
        focus = bounds
        // The line-up from the front; one shape alone from closer.
        defaultCamera = shapes.count > 1 ? Scene.demoCamera(.materials)! : Scene.camera([0, 1.5, 3.4], pitch: -0.16)
    }

    /// A shape's mesh (with UVs: a tile a UV unit), its placement over the plinth, and its size.
    private func materialShape(_ shape: MaterialWorkshopSettings.Layout) -> (Int, float4x4, SIMD3<Float>) {
        switch shape {
        case .sphere, .lineup: return (addMesh(Scene.uvSphere(), uvs: Scene.uvSphereUVs()), translate([0, 0.9, 0]) * scale(0.9), [1.8, 1.8, 1.8])
        case .cube:
            var b = MeshBuilder()
            Scene.tiledBox(&b, half: 0.75)
            return (addMesh(b.geometry, uvs: b.uvs), translate([0, 0.75, 0]), [1.5, 1.5, 1.5])
        case .cylinder:
            let (geometry, uvs) = Scene.uvCylinder(radius: 0.7, height: 1.6)
            return (addMesh(geometry, uvs: uvs), .init(1), [1.4, 1.6, 1.4])
        case .card:
            // Standing at the plinth's back, a UV tile across it (V down, as an image).
            let geometry: MeshGeometry = ([[-0.8, 1.6, 0], [-0.8, 0, 0], [0.8, 0, 0], [0.8, 1.6, 0]],
                                          [[0, 0, 1], [0, 0, 1], [0, 0, 1], [0, 0, 1]], [0, 1, 2, 0, 2, 3])
            return (addMesh(geometry, uvs: [[0, 0], [0, 1], [1, 1], [1, 0]]), translate([0, 0.02, -0.55]), [1.8, 1.62, 1.8])
        case .plane:
            let geometry: MeshGeometry = ([[-0.9, 0.01, -0.9], [0.9, 0.01, -0.9], [0.9, 0.01, 0.9], [-0.9, 0.01, 0.9]],
                                          [[0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 1, 0]], [0, 2, 1, 0, 3, 2])
            return (addMesh(geometry, uvs: [[0, 0], [1.8, 0], [1.8, 1.8], [0, 1.8]]), .init(1), [1.8, 0.02, 1.8])
        }
    }

    private func materialBackdrop(_ backdrop: MaterialWorkshopSettings.Backdrop, _ kit: Kit) {
        switch backdrop {
        case .studio:
            skyColor = [0.16, 0.16, 0.17]
            let grey = addPBRMaterial(baseColor: [0.36, 0.36, 0.37], metallic: 0, roughness: 0.65)
            cyclorama(kit, grey)
            addLight(.rect(width: 4, height: 2.5), color: SIMD3<Float>(1, 0.97, 0.92) * 9, motion: .constant) { _ in
                LightPose(position: [-4, 6, 5], direction: normalize(SIMD3<Float>(0.45, -0.75, -0.55)), tangent: [1, 0, 0])
            }
            addLight(.rect(width: 3, height: 2), color: SIMD3<Float>(0.8, 0.88, 1) * 3.5, motion: .constant) { _ in
                LightPose(position: [7, 4, 3], direction: normalize(SIMD3<Float>(-0.8, -0.35, -0.45)), tangent: [0, 0, 1])
            }
        case .outdoor:
            let ground = addMaterial(albedo: [0.42, 0.39, 0.33])
            addInstance(kit.quad, ground, scale([200, 1, 200]))
            skyColor = SIMD3<Float>(0.3, 0.45, 0.8) * 0.24
            let e = Scene.degrees(35), az: Float = 0.7
            addLight(.sun(angularRadius: Scene.degrees(0.27)), color: SIMD3<Float>(1, 0.95, 0.88) * 1.8, motion: .constant) { _ in
                LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)])
            }
        case .dark:
            skyColor = [0.01, 0.012, 0.018]
            let floor = addPBRMaterial(baseColor: [0.05, 0.05, 0.055], metallic: 0, roughness: 0.35)
            addInstance(kit.quad, floor, scale([60, 1, 60]))
            addLight(.rect(width: 6, height: 2), color: SIMD3<Float>(1, 1, 1) * 4, motion: .constant) { _ in
                LightPose(position: [0, 6, 2], direction: normalize(SIMD3<Float>(0, -1, -0.2)), tangent: [1, 0, 0])
            }
        }
    }

    // MARK: - Meshes with a tile a UV unit

    /// A unit sphere of latitudes and longitudes (its seam doubled): U twice round it, V once from pole to pole, so a
    /// tile is about as tall as it is wide.
    static func uvSphere(rings: Int = 48, segments: Int = 96) -> MeshGeometry {
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        for r in 0...rings {
            let theta = Float.pi * Float(r) / Float(rings)
            for s in 0...segments {
                let phi = 2 * Float.pi * Float(s) / Float(segments)
                positions.append([sin(theta) * cos(phi), cos(theta), -sin(theta) * sin(phi)])
            }
        }
        let row = UInt32(segments + 1)
        for r in 0..<UInt32(rings) {
            for s in 0..<UInt32(segments) {
                let a = r * row + s, b = a + row
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return (positions, positions, indices)
    }

    static func uvSphereUVs(rings: Int = 48, segments: Int = 96) -> [SIMD2<Float>] {
        var uvs: [SIMD2<Float>] = []
        for r in 0...rings { for s in 0...segments { uvs.append([2 * Float(s) / Float(segments), Float(r) / Float(rings)]) } }
        return uvs
    }

    /// A box of half size `half` whose every face is one tile (its UVs 0...1 across it), V down its sides.
    static func tiledBox(_ b: inout MeshBuilder, half h: Float) {
        b.uvScale = 1 / (2 * h)
        b.box([-h, -h, -h], [h, h, h])
    }

    /// A capped cylinder on its base: U round it (as many tiles as make them square), V down it.
    static func uvCylinder(radius: Float, height: Float, segments: Int = 96) -> (MeshGeometry, [SIMD2<Float>]) {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        let around = (2 * Float.pi * radius / height).rounded()
        for s in 0...segments {
            let phi = 2 * Float.pi * Float(s) / Float(segments)
            let d = SIMD3<Float>(cos(phi), 0, -sin(phi))
            for (y, v) in [(height, Float(0)), (Float(0), Float(1))] {
                positions.append(d * radius + [0, y, 0])
                normals.append(d)
                uvs.append([around * Float(s) / Float(segments), v])
            }
        }
        for s in 0..<UInt32(segments) {
            let a = 2 * s
            indices += [a, a + 1, a + 2, a + 2, a + 1, a + 3]
        }
        // The top: a disc, a tile across.
        let centre = UInt32(positions.count)
        positions.append([0, height, 0]); normals.append([0, 1, 0]); uvs.append([0.5, 0.5])
        for s in 0...segments {
            let phi = 2 * Float.pi * Float(s) / Float(segments)
            positions.append([cos(phi) * radius, height, -sin(phi) * radius])
            normals.append([0, 1, 0])
            uvs.append([0.5 + cos(phi) * 0.5, 0.5 + sin(phi) * 0.5])
        }
        for s in 0..<UInt32(segments) { indices += [centre, centre + 1 + s, centre + 2 + s] }
        return ((positions, normals, indices), uvs)
    }
}
