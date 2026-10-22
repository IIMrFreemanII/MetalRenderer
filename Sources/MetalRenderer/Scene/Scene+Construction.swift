import Characters
import Effects
import EngineCore
import Foundation
import ImageIO
import Physics
import Plants
import simd

extension Scene {
    // MARK: - Scene construction

    package func buildCornell() {
        let quad = addMesh(Scene.quadMesh(), label: "quad")
        let cube = addMesh(Scene.cubeMesh(), label: "box")
        let sphere = addMesh(Scene.icosphere(subdivisions: 3), label: "ball")

        let white = addMaterial(albedo: [0.75, 0.75, 0.75])
        let red = addMaterial(albedo: [0.65, 0.06, 0.05])
        let green = addMaterial(albedo: [0.12, 0.45, 0.15])
        let gold = addMaterial(albedo: [0.85, 0.62, 0.25])
        let blue = addMaterial(albedo: [0.15, 0.30, 0.75])

        // Room: 10 wide, 5 high, 10 deep, open at the front (+Z) so a little sky light leaks in.
        let w: Float = 10, h: Float = 5, d: Float = 10
        object("Room/Floor") { addInstance(quad, white, translate([0, 0, 0]) * scale([w, 1, d])) }
        object("Room/Ceiling") { addInstance(quad, white, translate([0, h, 0]) * rotate(.pi, [1, 0, 0]) * scale([w, 1, d])) }
        object("Room/Back wall") { addInstance(quad, white, translate([0, h / 2, -d / 2]) * rotate(.pi / 2, [1, 0, 0]) * scale([w, 1, h])) }
        object("Room/Left wall") { addInstance(quad, red, translate([-w / 2, h / 2, 0]) * rotate(-.pi / 2, [0, 0, 1]) * scale([h, 1, d])) }
        object("Room/Right wall") { addInstance(quad, green, translate([w / 2, h / 2, 0]) * rotate(.pi / 2, [0, 0, 1]) * scale([h, 1, d])) }

        // Static objects
        object("Tall box") { addInstance(cube, white, translate([-2.0, 1.6, -2.2]) * rotate(0.35, [0, 1, 0]) * scale([1.4, 3.2, 1.4])) }
        object("Short box") { addInstance(cube, white, translate([2.2, 0.75, -1.2]) * rotate(-0.3, [0, 1, 0]) * scale(1.5)) }
        object("Blue ball") { addInstance(sphere, blue, translate([0.6, 0.7, 0.8]) * scale(0.7)) }

        // Dynamic objects: their transforms change every frame, which only requires
        // rebuilding the (cheap) instance acceleration structure.
        object("Spinning cube") {
            addInstance(cube, gold, matrix_identity_float4x4) { t in
                translate([0, 2.8 + 0.25 * sin(1.3 * t), -2.0]) * rotate(0.8 * t, [1, 1, 0]) * scale(0.9)
            }
        }
        object("Rolling ball") {
            addInstance(sphere, white, matrix_identity_float4x4) { t in
                translate([2.8 * sin(0.6 * t), 0.5, 2.0]) * scale(0.5)
            }
        }

        // Moving sphere lights
        object("Lights/Warm") {
            addLight(color: SIMD3<Float>(1.0, 0.80, 0.60) * 30, radius: 0.15, sphereMesh: sphere) { t in
                [2.2 * cos(0.5 * t), 4.0, -1.0 + 2.2 * sin(0.5 * t)]
            }
        }
        object("Lights/Blue") {
            addLight(color: SIMD3<Float>(0.30, 0.50, 1.0) * 20, radius: 0.12, sphereMesh: sphere) { t in
                [3.5 * sin(0.37 * t), 1.6 + 0.6 * sin(0.9 * t), -3.6]
            }
        }
        object("Lights/Orange") {
            addLight(color: SIMD3<Float>(1.0, 0.45, 0.15) * 15, radius: 0.12, sphereMesh: sphere) { t in
                [-3.9 + 0.5 * sin(0.7 * t), 0.6, 0.8 + 1.6 * cos(0.45 * t)]
            }
        }
    }


    /// Lights share the shadow denoiser's 4 visibility channels by group. Up to 4 lights get one channel each;
    /// more are clustered by chromaticity (k-means, k = 4), so each channel's lights have similar colours.
    /// Lights are then sorted by group, so the shaders can walk one group's lights.
    package func assignLightGroups() {
        defer {
            lights.sort { $0.group < $1.group }   // stable: lights keep their order within a group
            for g in 0..<4 { lightGroupEnd[g] = UInt32(lights.filter { $0.group <= g }.count) }
        }
        guard lights.count > 4 else {
            for i in lights.indices { lights[i].group = i }
            return
        }
        let chroma = lights.map { $0.color / max($0.color.sum(), 1e-6) }   // analytic lights (mesh lights come later)
        // Farthest-point initialisation, deterministic.
        var centers = [chroma[0]]
        while centers.count < 4 {
            let far = chroma.indices.max { a, b in
                centers.map { distance_squared(chroma[a], $0) }.min()! < centers.map { distance_squared(chroma[b], $0) }.min()!
            }!
            centers.append(chroma[far])
        }
        for _ in 0..<10 {
            for i in lights.indices {
                lights[i].group = centers.indices.min { distance_squared(chroma[i], centers[$0]) < distance_squared(chroma[i], centers[$1]) }!
            }
            for g in centers.indices {
                let members = lights.indices.filter { lights[$0].group == g }
                if !members.isEmpty { centers[g] = members.map { chroma[$0] }.reduce(.zero, +) / Float(members.count) }
            }
        }
    }

    /// `materials`: for a mesh of several materials, each triangle's material as an offset from the material its
    /// instance names (which is then the first of a run of materials added one after the other).
    /// `name`: see `meshNames`.
    /// `label`: what the outline calls it (`label(mesh:)`).
    package func addMesh(_ mesh: MeshGeometry, uvs meshUVs: [SIMD2<Float>]? = nil, materials offsets: [UInt8]? = nil, name: String? = nil,
                 label: String? = nil) -> Int {
        if let name { meshNames[meshes.count] = name }
        if let label { meshLabels[meshes.count] = (label, false, nil) }
        let baseVertex = UInt32(positions.count)
        let firstIndex = UInt32(indices.count)
        if let offsets {
            precondition(offsets.count == mesh.indices.count / 3, "one material per triangle")
            triangleMaterials += [UInt8](repeating: 0, count: indices.count / 3 - triangleMaterials.count)   // the meshes before it
            triangleMaterials += offsets
        }
        positions += mesh.positions
        normals += mesh.normals
        uvs += meshUVs ?? [SIMD2<Float>](repeating: .zero, count: mesh.positions.count)
        indices += mesh.indices.map { $0 + baseVertex }   // indices are absolute into the shared vertex buffer
        meshes.append(GPUMesh(firstIndex: firstIndex, indexCount: UInt32(mesh.indices.count)))
        meshBounds.append((mesh.positions.reduce(SIMD3(repeating: .infinity), simd_min),
                           mesh.positions.reduce(SIMD3(repeating: -.infinity), simd_max)))
        return meshes.count - 1
    }

    /// A mesh whose arrays stay where they are (an open world's tile: in its file, mapped) instead of being copied
    /// into the scene's. On the GPU it is in a buffer of its own, which the scenes that have a mesh of its name share
    /// (MeshBlock in SceneBuffers.swift): the renderer copies it from here into that buffer the first time, and
    /// whoever needs its triangles after that reads them there.
    package struct BorrowedMesh {
        var positions: Stored<SIMD3<Float>>
        var normals: Stored<SIMD3<Float>>
        var uvs: Stored<SIMD2<Float>>
        var indices: Stored<UInt32>             // into its own vertices
        var materials: Stored<UInt8>? = nil     // per triangle, as `triangleMaterials` (nil: it has one material)
        /// A terrain's sector's: its vertices' layer weights (TERRAIN), after the triangles' materials in its block.
        var weights: Stored<SIMD16<UInt8>>? = nil
        var mesh = 0                            // in `meshes`
    }

    /// Adds a borrowed mesh, with its bounds as they are known. `sways`, `cutout`: as `addMesh(_: Foliage.Mesh)`'s,
    /// the cutout as the table has it.
    package func addMesh(borrowing mesh: BorrowedMesh, bounds: AABB, name: String, sways: Bool = false, cutout: UInt32 = 0) -> Int {
        precondition(mesh.normals.count == mesh.positions.count && mesh.uvs.count == mesh.positions.count
                     && (mesh.materials.map { $0.count * 3 == mesh.indices.count } ?? true), "a vertex's arrays, and a material per triangle")
        var mesh = mesh
        mesh.mesh = meshes.count
        borrowed.append(mesh)
        meshNames[meshes.count] = name
        meshes.append(GPUMesh(firstIndex: 0, indexCount: UInt32(mesh.indices.count), sways: sways ? 1 : 0, cutout: cutout,
                              vertexCount: UInt32(mesh.positions.count)))
        if sways { hasSwayingMeshes = true }
        meshBounds.append((bounds.lo, bounds.hi))
        return meshes.count - 1
    }

    /// Lets go of the vertex and index arrays, of the borrowed meshes and of the instance groups, once the renderer
    /// has them in its buffers and their structures: for a scene that is made again when anything about
    /// it changes, never built from twice (the open world's). The meshes' table, bounds and names stay.
    package func releaseGeometry() {
        (positions, normals, uvs, indices, triangleMaterials, borrowed) = ([], [], [], [], [], [])
        groups = []
        geometryReleased = true
    }
}
