import Characters
import Effects
import EngineCore
import Foundation
import ImageIO
import Physics
import Plants
import simd

extension Scene {
    // MARK: - Crowd

    /// Takes `crowd` as this scene's: its characters' bind-pose meshes and a mesh per pose slot.
    package func adopt(_ crowd: Crowd) {
        self.crowd = crowd
        for p in crowd.parts.indices {
            let geometry = crowd.geometry(part: p)
            crowd.parts[p].bindVertex = positions.count
            crowd.parts[p].mesh = addMesh((geometry.positions, geometry.normals, geometry.indices), uvs: geometry.uvs,
                                          materials: geometry.materials.isEmpty ? nil : geometry.materials)
        }
        for i in crowd.slots.indices {
            // A pose: its character's triangles over vertices of its own, which `finishCrowd` places. Its bounds are
            // those of every pose the character takes.
            let part = crowd.parts[crowd.slots[i].part], character = crowd.characters[part.character]
            meshes.append(GPUMesh(firstIndex: meshes[part.mesh].firstIndex, indexCount: meshes[part.mesh].indexCount))
            meshBounds.append((character.boundsMin, character.boundsMax))
            crowd.slots[i].mesh = meshes.count - 1
            setDetailLevel(meshes.count - 1, part.level)
        }
    }

    /// Mesh `m` was made at level of detail `level` (0 = the finest) of a system that has levels: the LOD debug view
    /// shows it (GPUMesh.lod).
    /// Mesh `m` is a terrain's sector, its terrain's layer table at `table` in the procedural parameters (TERRAIN).
    /// A borrowed mesh made again before the renderer has it (a terrain sector refined: Scene.refineTerrain), with
    /// its new name and bounds; its size may change.
    package func replaceBorrowed(_ m: Int, with mesh: BorrowedMesh, bounds: AABB, name: String) {
        guard let k = borrowed.firstIndex(where: { $0.mesh == m }) else { return }
        var mesh = mesh
        mesh.mesh = m
        borrowed[k] = mesh
        meshNames[m] = name
        meshes[m].indexCount = UInt32(mesh.indices.count)
        meshes[m].vertexCount = UInt32(mesh.positions.count)
        meshBounds[m] = (bounds.lo, bounds.hi)
    }

    package func setTerrainTable(_ m: Int, _ table: Int) {
        guard m >= 0 else { return }
        meshes[m].terrain = UInt32(table + 1)
    }

    package func setDetailLevel(_ m: Int, _ level: Int) {
        guard m >= 0 else { return }
        meshes[m].lod = UInt32(level + 1)
    }

    /// Mesh `m`'s bounds in its own space: for a pose slot, of every pose it may take.
    package func localBounds(mesh m: Int) -> AABB { AABB(lo: meshBounds[m].0, hi: meshBounds[m].1) }

    /// Marks instance `i` as a member of the crowd (its mesh is a pose slot's).
    package func setSkinned(_ i: Int, travels: Bool) {
        instances[i].deforms = true
        instances[i].travels = travels
        hasSkinned = true
    }

    /// A mesh whose vertices the GPU rewrites every frame (a cloth's: PhysicsGPU), within `bounds` whatever it does.
    /// Its vertices are its own (`vertexOffset` 0), and `finishDeforming` puts last frame's after everything else.
    /// `materials`: per triangle, its material's offset from the instance's (as `addMesh`'s).
    package func addDeformingMesh(_ mesh: MeshGeometry, uvs: [SIMD2<Float>]? = nil, materials: [UInt8]? = nil, bounds: AABB,
                          label: String? = nil) -> Int {
        let m = addMesh(mesh, uvs: uvs, materials: materials, label: label)
        meshBounds[m] = (bounds.lo, bounds.hi)
        deforming.append((mesh: m, first: positions.count - mesh.positions.count, count: mesh.positions.count))
        return m
    }

    /// Instance `i` on `mesh`, its mesh's displaced copy (Scene+Displacement.swift).
    package func setDisplacedMesh(_ i: Int, _ mesh: Int) {
        instances[i].mesh = mesh
    }

    /// Instance `i` given its painted materials (Scene+Painted.swift).
    package func setPaintedMaterial(_ i: Int, _ material: Int) {
        instances[i].material = material
    }

    /// Mesh `m`'s bounds grown by `d` every way (where its displaced vertices may go).
    package func growBounds(mesh m: Int, by d: Float) {
        meshBounds[m] = (meshBounds[m].0 - SIMD3(repeating: d), meshBounds[m].1 + SIMD3(repeating: d))
    }

    /// An instance of a deforming mesh (placed where its vertices are: they are in the scene's space).
    @discardableResult
    package func addDeformingInstance(_ mesh: Int, _ material: Int, _ transform: float4x4 = matrix_identity_float4x4) -> Int {
        let i = addInstance(mesh, material, transform)
        instances[i].deforms = true
        return i
    }

    /// A curve mesh's segments and its control points' radii (`curveRadii`).
    package struct CurveMesh {
        var segments: Int
        var radii: Range<Int>
    }
    package var hasCurves: Bool { !curveMeshes.isEmpty }
    package func hasCurveMesh(_ m: Int) -> Bool { curveMeshes[m] != nil }

    /// Strands as curves: `points` control points, `perStrand` of them a strand (a Catmull-Rom curve passes through
    /// all but its first and last), each with its radius (`radii`). The GPU rewrites them every frame (hair:
    /// PhysicsGPU), within `bounds` whatever they do; `finishDeforming` puts last frame's after everything else. The
    /// mesh's vertices start at its `vertexOffset`; its indices, from `firstIndex`, are each segment's first point
    /// counted from there (`indexCount` stays 0: it has no triangles).
    package func addCurves(points: [SIMD3<Float>], perStrand: Int, radii: [Float], bounds: AABB) -> Int {
        precondition(perStrand >= 4 && points.count % perStrand == 0 && radii.count == points.count, "whole strands of 4 points or more")
        let first = positions.count
        let firstIndex = indices.count
        positions += points
        normals += [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: points.count)
        uvs += [SIMD2<Float>](repeating: .zero, count: points.count)
        for s in 0..<(points.count / perStrand) {
            for k in 0..<(perStrand - 3) { indices.append(UInt32(s * perStrand + k)) }
        }
        meshes.append(GPUMesh(firstIndex: UInt32(firstIndex), indexCount: 0, vertexOffset: UInt32(first)))
        meshBounds.append((bounds.lo, bounds.hi))
        let m = meshes.count - 1
        curveMeshes[m] = CurveMesh(segments: indices.count - firstIndex, radii: curveRadii.count..<(curveRadii.count + radii.count))
        curveRadii += radii
        deforming.append((mesh: m, first: first, count: points.count))
        return m
    }

    /// The hair's groups: where their meshes' control points are, and last frame's.
    package func finishHair() {
        guard let physics else { return }
        for (g, m) in hairMeshes {
            physics.hairGroups[g].mesh.x = meshes[m].vertexOffset
            physics.hairGroups[g].mesh.y = meshes[m].prevOffset
        }
    }

    /// Once every mesh is in (after the crowd's): the deforming meshes' last-frame vertices, after everything, as the
    /// first frame's (the same as the current ones).
    package func finishDeforming() {
        for d in deforming {
            let previous = positions.count
            positions += positions[d.first..<(d.first + d.count)]
            meshes[d.mesh].prevOffset = UInt32(previous - d.first)
        }
    }

    /// Some mesh deforms (DEFORMING_MESHES): the crowd's pose slots, cloths.
    package var hasDeformingMeshes: Bool { crowd?.slots.isEmpty == false || !deforming.isEmpty }

    /// Once every mesh is in: the pose slots' vertices go after them (each slot's current positions and normals,
    /// then every slot's previous positions), skinned on the CPU to the pose at time 0. The GPU rewrites them every
    /// frame from then on; these are what the acceleration structures are first built from.
    package func finishCrowd() {
        guard let crowd, !crowd.slots.isEmpty else { return }
        var next = positions.count
        for p in crowd.parts.indices {
            crowd.parts[p].currentBase = next
            next += crowd.parts[p].slotCount * crowd.parts[p].vertexCount
        }
        let currentEnd = next
        for p in crowd.parts.indices {
            crowd.parts[p].previousBase = next
            next += crowd.parts[p].slotCount * crowd.parts[p].vertexCount
        }
        positions += [SIMD3<Float>](repeating: .zero, count: next - positions.count)
        normals += [SIMD3<Float>](repeating: .zero, count: currentEnd - normals.count)
        crowd.pose(at: 0)
        let geometry = crowd.parts.indices.map { crowd.geometry(part: $0) }
        positions.withUnsafeMutableBufferPointer { p in
            normals.withUnsafeMutableBufferPointer { n in
                DispatchQueue.concurrentPerform(iterations: crowd.slots.count) { i in
                    let character = geometry[crowd.slots[i].part]
                    let range = crowd.vertexRange(slot: i)
                    SkinnedCharacter.skin(positions: character.positions, normals: character.normals, skin: character.skin,
                                          palette: crowd.palette(slot: i), into: p.baseAddress! + range.current,
                                          n.baseAddress! + range.current)
                    (p.baseAddress! + range.previous).update(from: p.baseAddress! + range.current, count: range.count)
                }
            }
        }
        for i in crowd.slots.indices {
            let range = crowd.vertexRange(slot: i), part = crowd.parts[crowd.slots[i].part]
            meshes[crowd.slots[i].mesh].vertexOffset = UInt32(range.current - part.bindVertex)
            meshes[crowd.slots[i].mesh].prevOffset = UInt32(range.previous - range.current)
        }
    }

    /// How far ground cover leans at full wind, per unit of its height (WIND_COVER_LEAN in Shaders/Foliage.metal).
    package static let coverLean: Float = 0.2

    /// A generated mesh (Foliage, Terrain): its arrays appended whole, its bounds as it counted them. `sways`: ground
    /// cover standing along +y, which leans in the wind (every instance of it: its transform, PlantTracing).
    /// `cutout`: the alpha layer (`addCutout`) that cuts out its leaves, if they are cards.
    /// `name`: see `meshNames`.
    package func addMesh(_ mesh: Foliage.Mesh, sways: Bool = false, cutout: Int? = nil, name: String? = nil) -> Int {
        if let name { meshNames[meshes.count] = name }
        let baseVertex = UInt32(positions.count)
        let firstIndex = UInt32(indices.count)
        positions += mesh.positions
        normals += mesh.normals
        uvs += mesh.uvs
        indices.reserveCapacity(indices.count + mesh.indices.count)
        for i in mesh.indices { indices.append(i + baseVertex) }
        meshes.append(GPUMesh(firstIndex: firstIndex, indexCount: UInt32(mesh.indices.count), sways: sways ? 1 : 0,
                              cutout: cutout.map { UInt32($0 + 1) << 24 | UInt32(mesh.leafIndex / 3) } ?? 0))
        if sways { hasSwayingMeshes = true }
        meshBounds.append((mesh.bounds.lo, mesh.bounds.hi))
        return meshes.count - 1
    }

    package func addCutout(alpha: [UInt8], coverage: Float) -> Int {
        precondition(alpha.count == FoliageTextures.cardSheetSize * FoliageTextures.cardSheetSize && cutouts.count < 15,
                     "Scene.addCutout: a layer is a card sheet's alpha, and a triangle names one of 15")
        cutouts.append((alpha, coverage))
        return cutouts.count - 1
    }

    package func addAssembly(_ assembly: Assembly) -> Int {
        assemblies.append(assembly)
        return assemblies.count - 1
    }

    package func addVoxelPlant(_ plant: FoliageVoxels.Plant) -> Int {
        voxelPlants.append(plant)
        return voxelPlants.count - 1
    }

    /// Mesh `mesh` is voxel plant `plant`'s wood, or its leaves (VoxelLOD).
    package func setMeshVoxels(_ mesh: Int, plant: Int, leaves: Bool) {
        guard mesh >= 0 else { return }
        meshVoxels[mesh] = UInt32(plant) | (leaves ? Scene.meshVoxelsLeaves : 0)
    }

    /// An instance of an assembly: `material` is its wood's, and the next material its leaves'.
    @discardableResult
    package func addInstance(assembly: Int, _ material: Int, _ transform: float4x4) -> Int {
        instances.append(Instance(mesh: -1, material: material, mask: Scene.maskGeometry,
                                  transform: transform, prevTransform: transform,
                                  animation: nil, assembly: assembly, normalMatrix: transform.inverse.transpose))
        return instances.count - 1
    }

    /// An SDF shape for instances to place (`addInstance(sdf:)`).
    package func addSDFShape(_ shape: SDFShape) -> Int {
        sdfLabels[sdfShapes.count] = shape.kindName   // (a builder's own name replaces it: `label(sdf:)`)
        sdfShapes.append(shape)
        sdfBounds.append(shape.bounds(volumes: sdfVolumes))
        return sdfShapes.count - 1
    }

    /// A baked distance grid for SDF shapes' `.volume` nodes (added before the shapes that use it).
    package func addSDFVolume(_ volume: SDFVolume) -> Int {
        sdfVolumes.append(volume)
        return sdfVolumes.count - 1
    }

    /// An instance of SDF shape `sdf`: `material` is its nodes' with offset 0, the others' after it.
    @discardableResult
    package func addInstance(sdf: Int, _ material: Int, _ transform: float4x4, mask: UInt32 = Scene.maskGeometry,
                     animation: ((Float) -> float4x4)? = nil) -> Int {
        instances.append(Instance(mesh: -1, material: material, mask: mask,
                                  transform: transform, prevTransform: transform, animation: animation,
                                  normalMatrix: transform.inverse.transpose, sdf: sdf))
        return instances.count - 1
    }
}
