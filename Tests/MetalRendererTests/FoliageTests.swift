import XCTest
import simd
@testable import MetalRenderer

/// Foliage.swift: the plants are a pure function of the seed (built in parallel or not), every mesh is sound (a
/// degenerate triangle would shade with a NaN normal), and an assembly baked flat is the same triangles.
final class FoliageTests: XCTestCase {
    private func same(_ a: Foliage.Mesh, _ b: Foliage.Mesh) -> Bool {
        a.positions == b.positions && a.normals == b.normals && a.uvs == b.uvs && a.indices == b.indices
            && a.leafVertex == b.leafVertex && a.leafIndex == b.leafIndex && a.bounds.lo == b.bounds.lo && a.bounds.hi == b.bounds.hi
    }

    private func same(_ a: [Foliage.SpeciesSet], _ b: [Foliage.SpeciesSet]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.species == y.species, x.palette.count == y.palette.count, x.plants.count == y.plants.count else { return false }
            for (m, n) in zip(x.palette, y.palette) where !same(m, n) { return false }
            for (p, q) in zip(x.plants, y.plants) {
                guard p.age == q.age, p.meshes.count == q.meshes.count, p.parts.count == q.parts.count, p.bones.count == q.bones.count
                else { return false }
                for (m, n) in zip(p.meshes, q.meshes) where !same(m, n) { return false }
                for (s, t) in zip(p.parts, q.parts) where s.mesh != t.mesh || s.shared != t.shared || s.transform != t.transform || s.bone != t.bone {
                    return false
                }
                for (s, t) in zip(p.bones, q.bones) where s.pivot != t.pivot || s.parent != t.parent || s.phase != t.phase { return false }
            }
        }
        return true
    }

    func testTheSameSeedGivesTheSameLibrary() {
        let parallel = Foliage.library(seed: 7)
        XCTAssertTrue(same(parallel, Foliage.library(seed: 7)), "two parallel builds differ")
        XCTAssertTrue(same(parallel, Foliage.library(seed: 7, parallel: false)), "the parallel build is not the serial one")
        XCTAssertFalse(same(parallel, Foliage.library(seed: 8)), "another seed gives the same plants")
    }

    /// A species' plants don't depend on which other species are built with it.
    func testASpeciesAloneIsTheSame() {
        let all = Foliage.library(seed: 3)
        let birch = Foliage.library(seed: 3, species: [.birch])
        XCTAssertTrue(same([all[Foliage.Species.birch.rawValue]], birch))
    }

    func testEveryMeshIsSound() {
        for set in Foliage.library(seed: 11) {
            XCTAssertEqual(set.palette.count, Foliage.paletteSize(set.species))
            for (i, m) in set.palette.enumerated() {
                XCTAssertEqual(Foliage.problems(m), [], "\(set.species) bough \(i)")
                XCTAssertGreaterThan(m.leafTriangles, 0, "\(set.species) bough \(i) has no leaves")
                XCTAssertGreaterThan(m.leafIndex, 0, "\(set.species) bough \(i) has no wood")
            }
            for age in Foliage.Age.allCases {
                XCTAssertEqual(set.plants(of: age).count, Foliage.variants(set.species, age), "\(set.species) \(age)")
            }
            for (i, plant) in set.plants.enumerated() {
                let what = "\(set.species) \(plant.age) \(i)"
                for (k, m) in plant.meshes.enumerated() { XCTAssertEqual(Foliage.problems(m), [], "\(what) mesh \(k)") }
                XCTAssertFalse(plant.bounds.isEmpty, what)
                XCTAssertGreaterThan(plant.height, 0.1, what)

                // Bones: the root first, each on an earlier one; every part on a bone and a mesh that exists.
                XCTAssertEqual(plant.bones[0].parent, -1, what)
                for (b, bone) in plant.bones.enumerated().dropFirst() {
                    XCTAssertTrue(bone.parent >= 0 && Int(bone.parent) < b, "\(what) bone \(b)")
                }
                for part in plant.parts {
                    XCTAssertTrue(plant.bones.indices.contains(part.bone), what)
                    XCTAssertTrue(part.mesh >= 0 && part.mesh < (part.shared ? set.palette.count : plant.meshes.count), what)
                }

                // Baked flat: the same triangles, wood and leaves apart, inside the plant's bounds.
                let flat = Foliage.flatten(plant, palette: set.palette)
                XCTAssertEqual(Foliage.problems(flat.wood), [], "\(what) flat wood")
                XCTAssertEqual(Foliage.problems(flat.leaves), [], "\(what) flat leaves")
                var triangles = 0, leaves = 0
                for part in plant.parts {
                    let m = part.shared ? set.palette[part.mesh] : plant.meshes[part.mesh]
                    triangles += m.triangles
                    leaves += m.leafTriangles
                }
                XCTAssertEqual(flat.wood.triangles + flat.leaves.triangles, triangles, what)
                XCTAssertEqual(flat.leaves.triangles, leaves, what)
                let slack = SIMD3<Float>(repeating: 1e-3)
                for m in [flat.wood, flat.leaves] where !m.indices.isEmpty {
                    XCTAssertTrue(all(m.bounds.lo .>= plant.bounds.lo - slack) && all(m.bounds.hi .<= plant.bounds.hi + slack),
                                  "\(what): the flat mesh leaves the plant's bounds")
                }
            }
        }
    }

    func testAgesGrowTaller() {
        for species in [Foliage.Species.oak, .birch, .conifer] {
            let set = Foliage.library(seed: 5, species: [species])[0]
            func tallest(_ age: Foliage.Age) -> Float { set.plants(of: age).map { set.plants[$0].height }.max() ?? 0 }
            XCTAssertLessThan(tallest(.sapling), tallest(.young), "\(species)")
            XCTAssertLessThan(tallest(.young), tallest(.mature), "\(species)")
        }
    }

    /// Carving prunes: no stem of a carved recipe runs on past the envelope by more than one segment.
    func testCarvingKeepsStemsInside() {
        let recipe = Foliage.recipe(.bush, age: .mature)
        let carve = recipe.carve!
        let skeleton = Foliage.grow(recipe, seed: 9)
        for s in skeleton.stems {
            let step = s.length / Float(s.count - 1)
            for i in 0..<Int(s.count) {
                let node = skeleton.nodes[Int(s.first) + i]
                let q = (SIMD3(node.x, node.y, node.z) - carve.center) / (carve.radii + SIMD3(repeating: step + 1e-3))
                XCTAssertLessThanOrEqual(dot(q, q), 1.0 + 1e-3, "a stem of level \(s.level) leaves the carve")
            }
        }
    }

    func testAGrassPatchStaysInItsSquare() {
        let patch = Foliage.grassPatch(seed: 2, size: 2, blades: 300)
        XCTAssertEqual(Foliage.problems(patch), [])
        XCTAssertEqual(patch.triangles, 300 * 5)
        XCTAssertEqual(patch.leafIndex, 0)
        XCTAssertTrue(patch.bounds.lo.x >= -1.5 && patch.bounds.hi.x <= 1.5 && patch.bounds.lo.z >= -1.5 && patch.bounds.hi.z <= 1.5)
        XCTAssertLessThan(patch.bounds.lo.y, 0)   // the roots are under the ground
    }
}

/// Terrain.swift and the forest scene: `height` is the mesh's surface, and the scene is the same for the same seed.
final class ForestTests: XCTestCase {
    func testHeightIsTheMeshSurface() {
        let terrain = Terrain(size: 64, cells: 32, seed: 4, relief: 6, flat: (center: [0, 0], inner: 4, outer: 12))
        let mesh = terrain.mesh()
        XCTAssertEqual(Foliage.problems(mesh), [])
        XCTAssertEqual(mesh.triangles, 32 * 32 * 2)
        for p in mesh.positions { XCTAssertEqual(terrain.height(p.x, p.z), p.y, accuracy: 1e-4) }
        XCTAssertEqual(terrain.height(0, 0), 0, accuracy: 1e-5)   // the clearing is level
        XCTAssertEqual(terrain.normal(0.3, -0.2).y, 1, accuracy: 1e-5)
        // On each triangle the height is the plane through its corners.
        var rng = SplitMix64(seed: 12)
        for f in stride(from: 0, to: mesh.indices.count, by: 3 * 17) {
            let a = mesh.positions[Int(mesh.indices[f])], b = mesh.positions[Int(mesh.indices[f + 1])], c = mesh.positions[Int(mesh.indices[f + 2])]
            var u = rng.next(), v = rng.next()
            if u + v > 1 { u = 1 - u; v = 1 - v }
            let p = a + (b - a) * u + (c - a) * v
            XCTAssertEqual(terrain.height(p.x, p.z), p.y, accuracy: 1e-3)
            XCTAssertGreaterThan(terrain.normal(p.x, p.z).y, 0.2)
        }
    }

    func testTheForestIsItsSettings() {
        var settings = SceneSettings(kind: .forest)
        settings.trees = 150
        settings.undergrowth = 25
        let a = Scene(settings), b = Scene(settings)
        XCTAssertEqual(a.instances.count, b.instances.count)
        XCTAssertEqual(a.positions.count, b.positions.count)
        XCTAssertTrue(zip(a.instances, b.instances).allSatisfy { $0.transform == $1.transform && $0.mesh == $1.mesh && $0.material == $1.material })
        XCTAssertGreaterThan(a.instances.count, 150)
        XCTAssertTrue(a.instances.allSatisfy(\.isStatic))   // nothing moves: it all stays in the static tree
        settings.seed = 2
        XCTAssertFalse(zip(a.instances, Scene(settings).instances).allSatisfy { $0.transform == $1.transform })
        settings.trees = 0
        settings.undergrowth = 0
        XCTAssertEqual(Scene(settings).instances.count, 1)   // just the ground
    }

    /// The same forest as assemblies (the custom tracer's) and baked flat (Metal's): the same plants in the same
    /// places, as far fewer triangles.
    func testAssembliesAreTheFlatForest() {
        var settings = SceneSettings(kind: .forest)
        settings.trees = 120
        settings.undergrowth = 25
        let flat = Scene(settings), parts = Scene(settings, assemblies: true)
        XCTAssertTrue(flat.assemblies.isEmpty && !flat.usesAssemblies && flat.hasPlants)
        XCTAssertEqual(flat.lightTypeMask & 0x4000_0000, 0)
        XCTAssertFalse(parts.assemblies.isEmpty)
        XCTAssertNotEqual(parts.lightTypeMask & 0x4000_0000, 0)   // FOLIAGE: the shaders are specialised for it
        XCTAssertLessThan(parts.instances.count, flat.instances.count)   // a tree is one instance, not wood + leaves
        XCTAssertLessThan(parts.indices.count * 3, flat.indices.count)

        func triangles(_ scene: Scene) -> Int {
            let perAssembly = scene.assemblies.map { $0.parts.reduce(0) { $0 + Int(scene.meshes[$1.mesh].indexCount) / 3 } }
            return scene.instances.reduce(0) { $0 + ($1.assembly >= 0 ? perAssembly[$1.assembly] : Int(scene.meshes[$1.mesh].indexCount) / 3) }
        }
        XCTAssertEqual(triangles(parts), triangles(flat))
        let (lo, hi) = flat.bounds(), (plo, phi) = parts.bounds()
        // The assemblies' bounds leave room for the wind: a little larger, never smaller.
        XCTAssertTrue(all(plo .<= lo + 1e-3) && all(phi .>= hi - 1e-3))
        XCTAssertLessThan(simd_reduce_max(abs(lo - plo)), 2)
        XCTAssertLessThan(simd_reduce_max(abs(hi - phi)), 2)

        // Ferns and grass stay meshes, which lean in the wind; where nothing walks assemblies, nothing leans.
        XCTAssertTrue(parts.hasSwayingMeshes && !flat.hasSwayingMeshes)
        XCTAssertTrue(parts.instances.contains { $0.mesh >= 0 && parts.meshes[$0.mesh].sways != 0 })
        XCTAssertEqual(parts.meshes[parts.instances[0].mesh].sways, 0)   // not the ground
        for assembly in parts.assemblies {
            for part in assembly.parts {
                XCTAssertTrue(parts.meshes.indices.contains(part.mesh))
                XCTAssertLessThanOrEqual(Int(part.firstLeaf) * 3, Int(parts.meshes[part.mesh].indexCount))
                XCTAssertTrue(all(part.bounds.lo .>= assembly.bounds.lo) && all(part.bounds.hi .<= assembly.bounds.hi))
            }
        }
        for inst in parts.instances where inst.assembly >= 0 {
            XCTAssertEqual(inst.mesh, -1)
            XCTAssertLessThan(inst.material + 1, parts.materials.count)   // its wood's material, then its leaves'
        }
    }

    func testTheForestReadsItsSettings() {
        var s = RenderSettings()
        SettingsEnv.apply(.scene, to: &s, from: ["METALRENDERER_SCENE": "forest,trees=300,seed=5,undergrowth=50"])
        XCTAssertEqual(s.scene.kind, .forest)
        XCTAssertEqual([s.scene.trees, s.scene.seed, s.scene.undergrowth], [300, 5, 50])
    }
}

/// What the custom tracer adds to plants: the room the wind's turns need, the voxel grids of far plants, the seasons.
final class FoliageRuntimeTests: XCTestCase {
    private func forest(trees: Int = 120) -> Scene {
        var settings = SceneSettings(kind: .forest)
        settings.trees = trees
        settings.undergrowth = 25
        return Scene(settings, assemblies: true)
    }

    /// p turned by `angle` about the unit `axis` through `pivot` (Shaders/Foliage.metal's windTurn, without its series).
    private func turn(_ p: SIMD3<Float>, _ bone: Scene.Assembly.Bone, _ angle: Float) -> SIMD3<Float> {
        let v = p - bone.pivot, c = cos(angle), s = sin(angle)
        return bone.pivot + v * c + cross(bone.axis, v) * s + bone.axis * dot(bone.axis, v) * (1 - c)
    }

    private func corners(_ box: AABB) -> [SIMD3<Float>] {
        (0..<8).map { SIMD3($0 & 1 == 0 ? box.lo.x : box.hi.x, $0 & 2 == 0 ? box.lo.y : box.hi.y, $0 & 4 == 0 ? box.lo.z : box.hi.z) }
    }

    /// A part's box grown by `windPad` x strength holds the part however its bones turn at that strength (the bough
    /// on its limb, then the limb), and the plant's box holds all of that leaning about its foot as well.
    func testThePadsHoldTheWind() {
        let scene = forest()
        var boughs = 0, limbs = 0
        for assembly in scene.assemblies {
            XCTAssertEqual(assembly.parts[0].windPad, 0)   // the trunk only leans with the plant
            for part in assembly.parts {
                XCTAssertTrue(part.windPad.isFinite && part.windPad >= 0)
                XCTAssertEqual(part.windPad == 0, part.limb.angle == 0 && part.bough.angle == 0)
                XCTAssertLessThan(part.bough.angle, 0.2)   // windTurn's series holds up to here
                XCTAssertLessThan(part.limb.angle, 0.2)
                for bone in [part.limb, part.bough] where bone.angle > 0 { XCTAssertEqual(length(bone.axis), 1, accuracy: 1e-4) }
                boughs += part.bough.angle > 0 ? 1 : 0
                limbs += part.limb.angle > 0 && part.bough.angle == 0 ? 1 : 0
                for strength: Float in [0.4, 1] {
                    let pad = part.windPad * strength
                    for corner in corners(part.bounds) {
                        for signs in 0..<4 {
                            let onLimb = turn(corner, part.bough, part.bough.angle * strength * (signs & 1 == 0 ? 1 : -1))
                            let moved = turn(onLimb, part.limb, part.limb.angle * strength * (signs & 2 == 0 ? 1 : -1))
                            XCTAssertTrue(all(moved .>= part.bounds.lo - pad) && all(moved .<= part.bounds.hi + pad))
                            // Leaning with the whole plant, about any level axis through its foot.
                            for axis in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0.6, 0, -0.8)] {
                                let root = Scene.Assembly.Bone(pivot: .zero, angle: Scene.Assembly.rootSway, axis: axis)
                                let leaned = turn(moved, root, root.angle * strength)
                                XCTAssertTrue(all(leaned .>= assembly.bounds.lo) && all(leaned .<= assembly.bounds.hi))
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(boughs, 100)
        XCTAssertGreaterThan(limbs, 10)
    }

    /// The numbers the shaders and the Swift side each hold a copy of.
    func testTheShadersHoldTheSameNumbers() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders")
        func constant(_ name: String, in file: String) throws -> Float {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            let regex = try NSRegularExpression(pattern: "constant +(?:float|uint) +\(name) *= *([0-9.]+)")
            let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), name)
            return try XCTUnwrap(Float(text[Range(match.range(at: 1), in: text)!]))
        }
        XCTAssertEqual(try constant("WIND_ROOT_SWAY", in: "Foliage.metal"), Scene.Assembly.rootSway)
        XCTAssertEqual(try constant("WIND_COVER_LEAN", in: "Foliage.metal"), Scene.coverLean)
        XCTAssertEqual(try constant("VOXEL_DEPTH", in: "Intersect.metal"), FoliageVoxels.depth)
        XCTAssertEqual(try constant("VOXEL_LEVELS", in: "Intersect.metal"), Float(FoliageVoxels.levels))
        XCTAssertEqual(MemoryLayout<RTPart>.size, 128)             // RTPart's static_assert
        XCTAssertEqual(MemoryLayout<FoliageVoxels.Grid>.size, 48)  // RTVoxels
    }

    /// Each plant's grid covers it, the levels are each half the one before and filled where the one below is, and
    /// the same scene gives the same cells.
    func testVoxelGridsCoverThePlants() {
        let scene = forest(trees: 60)
        let (grids, cells) = FoliageVoxels.build(scene: scene)
        XCTAssertEqual(grids.count, scene.assemblies.count)
        XCTAssertTrue(scene.assemblies.contains(where: \.evergreen) && scene.assemblies.contains { !$0.evergreen })
        var end: UInt32 = 0
        for (grid, assembly) in zip(grids, scene.assemblies) {
            XCTAssertEqual(grid.dims.w, assembly.evergreen ? 1 : 0)
            let size = grid.lo.w, d0 = SIMD3<Int>(Int(grid.dims.x), Int(grid.dims.y), Int(grid.dims.z))
            XCTAssertLessThanOrEqual(d0.max(), FoliageVoxels.resolution + 1)
            XCTAssertGreaterThanOrEqual(d0.max(), FoliageVoxels.resolution - 1)
            let lo = SIMD3(grid.lo.x, grid.lo.y, grid.lo.z), hi = lo + SIMD3<Float>(Float(d0.x), Float(d0.y), Float(d0.z)) * size
            for part in assembly.parts {
                XCTAssertTrue(all(part.bounds.lo .>= lo - 1e-4) && all(part.bounds.hi .<= hi + 1e-4))
            }
            var filled = 0
            for level in 0..<FoliageVoxels.levels {
                XCTAssertEqual(grid.offsets[level], end)   // the levels follow one another, plant after plant
                let d = FoliageVoxels.dims(d0, level: level)
                let base = Int(grid.offsets[level])
                end += UInt32(d.x * d.y * d.z)
                guard level > 0 else {
                    filled = (0..<d.x * d.y * d.z).reduce(0) { $0 + (cells[base + $1] != 0 ? 1 : 0) }
                    continue
                }
                // A coarser voxel holds something exactly when one of the (up to) eight under it does.
                let below = FoliageVoxels.dims(d0, level: level - 1), belowBase = Int(grid.offsets[level - 1])
                var under = [Bool](repeating: false, count: d.x * d.y * d.z)
                for z in 0..<below.z {
                    for y in 0..<below.y {
                        for x in 0..<below.x where cells[belowBase + (z * below.y + y) * below.x + x] != 0 {
                            under[((z / 2) * d.y + y / 2) * d.x + x / 2] = true
                        }
                    }
                }
                for i in under.indices { XCTAssertEqual(cells[base + i] != 0, under[i]) }
            }
            XCTAssertGreaterThan(filled, 50)
            XCTAssertLessThan(filled * 2, d0.x * d0.y * d0.z)   // a plant is mostly air
        }
        XCTAssertEqual(Int(end), cells.count)
        let again = FoliageVoxels.build(scene: forest(trees: 60))
        XCTAssertEqual(again.cells, cells)
    }

    /// The detail textures all have the mean the shaders and the materials' colours assume, the bark tiles, and a
    /// forest names its textures by their pixels (the streamer's cache key).
    func testGeneratedTextures() throws {
        func linear(_ b: UInt8) -> Float { let c = Float(b) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        for kind in FoliageTextures.Kind.allCases {
            let image = FoliageTextures.make(kind)
            XCTAssertEqual(image.pixels.count, image.width * image.height * 4)
            var sum: Float = 0
            for i in stride(from: 0, to: image.pixels.count, by: 4) {
                sum += linear(image.pixels[i]) + linear(image.pixels[i + 1]) + linear(image.pixels[i + 2])
                XCTAssertEqual(image.pixels[i + 3], 255)
            }
            XCTAssertEqual(sum / Float(3 * image.width * image.height), FoliageTextures.mean, accuracy: 0.03, kind.name)
        }
        // Along a stem the bark repeats: its last row meets its first without a step. (Around it the mesh mirrors it.)
        for kind in [FoliageTextures.Kind.roughBark, .birchBark] {
            let bark = FoliageTextures.make(kind)
            var step = 0, inside = 0
            let last = (bark.height - 1) * bark.width * 4, middle = 100 * bark.width * 4
            for x in stride(from: 0, to: bark.width * 4, by: 4) {
                step += abs(Int(bark.pixels[x]) - Int(bark.pixels[last + x]))
                inside += abs(Int(bark.pixels[middle + x]) - Int(bark.pixels[middle + bark.width * 4 + x]))
            }
            XCTAssertLessThan(step, inside * 3 + bark.width * 4, kind.name)
        }

        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders/Surface.metal")
        XCTAssertTrue(try String(contentsOf: folder, encoding: .utf8).contains("GENERATED_TEXTURE_MEAN = \(FoliageTextures.mean)f"))

        let scene = forest(trees: 60), again = forest(trees: 60)
        XCTAssertGreaterThanOrEqual(scene.textures.count, 4)   // the ground, bark, leaves, grass
        XCTAssertTrue(scene.textures.allSatisfy { $0.raw != nil && $0.rawPixels.count == $0.raw!.width * $0.raw!.height * 4 })
        XCTAssertEqual(Set(scene.textures.map(\.cacheKey)).count, scene.textures.count)
        XCTAssertEqual(scene.textures.map(\.cacheKey), again.textures.map(\.cacheKey))

        // The caches name these textures by FoliageTextures.version, not by their pixels (so a cached one is never
        // drawn). Whoever changes what one looks like changes the version, and then these: its pixels' hashes.
        func hash(_ pixels: Data) -> String {
            var hasher = GeneratedCache.Hasher()
            hasher.add([UInt8](pixels))
            return String(hasher.name().prefix(12))
        }
        var hashes = FoliageTextures.Kind.allCases.map { "\($0.name) \(hash(Data(FoliageTextures.make($0).pixels)))" }
        hashes.append("ground \(hash(scene.textures.first { $0.name == "generated/ground" }!.rawPixels))")
        XCTAssertEqual(FoliageTextures.version, 1)
        XCTAssertEqual(hashes, ["roughBark 6cfa2e7e2258", "birchBark 22d9c0664c62", "leaf 946df84d6ae5", "needle b456f98d54ab", "grass 4535a03fea78",
                                "ground 107838e8a4b3"],
                       "a generated texture changed: change FoliageTextures.version, and the version and hashes here")
        for inst in scene.instances {   // every plant's wood and leaves, and the ground, have a texture
            XCTAssertLessThan(Int(scene.materials[inst.material].textures.x), scene.textures.count)
            if inst.assembly >= 0 { XCTAssertLessThan(Int(scene.materials[inst.material + 1].textures.x), scene.textures.count) }
        }
    }

    /// Leaves as cards: sound meshes of far fewer triangles, each card triangle carrying its UVs and layer the way
    /// the shader reads them back, and a scene that says it has them.
    func testLeafCards() throws {
        for species in Foliage.Species.allCases where species.hasBoughs {
            let leaves = Foliage.bough(species, variant: 0, seed: 9), cards = Foliage.bough(species, variant: 0, seed: 9, cards: true)
            XCTAssertEqual(Foliage.problems(cards), [], "\(species)")
            XCTAssertTrue(cards.cutout && !leaves.cutout)
            XCTAssertEqual(cards.leafIndex, leaves.leafIndex)                 // the same wood
            XCTAssertLessThan(cards.leafTriangles * 4, leaves.leafTriangles)
            XCTAssertEqual(cards.leafTriangles % 2, 0)
            let leaf = try XCTUnwrap(Foliage.boughRecipe(species, variant: 0).leaf)
            let sheet = FoliageTextures.cardSheet(leaf, twig: Foliage.cardTwig, seed: 1)
            XCTAssertEqual(sheet.alpha.count, FoliageTextures.cardSheetSize * FoliageTextures.cardSheetSize)
            XCTAssertTrue(sheet.coverage > 0.08 && sheet.coverage < 0.7, "\(species): \(sheet.coverage)")
            XCTAssertEqual(Float(sheet.alpha.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }) / Float(sheet.alpha.count), sheet.coverage, accuracy: 1e-5)
        }
        // The packed UVs, read back as rtCutout does: each corner to within a texel of the sheet.
        let corners: [SIMD2<Float>] = [[0, 0.5], [0.5, 1], [1, 0.25]]
        let (a, b) = BVHBuilder.cutoutBits(corners[0], corners[1], corners[2], layer: 13)
        XCTAssertEqual((a >> 30) | (b >> 30) << 2, 13)
        let read = [SIMD2(Float(a & 1023), Float((a >> 10) & 1023)), SIMD2(Float((a >> 20) & 1023), Float(b & 1023)),
                    SIMD2(Float((b >> 10) & 1023), Float((b >> 20) & 1023))].map { $0 / 1024 }
        for (r, c) in zip(read, corners) { XCTAssertLessThan(simd_reduce_max(abs(r - c)), 1.5 / 1024) }
        XCTAssertTrue(BVHBuilder.cutoutBits(.zero, .zero, .zero, layer: 0) == (0, 0))

        var settings = SceneSettings(kind: .forest)
        settings.trees = 60
        settings.undergrowth = 25
        settings.leafCards = true
        let cards = Scene(settings, assemblies: true), metal = Scene(settings)
        XCTAssertTrue(cards.usesCards && !cards.cutouts.isEmpty)
        XCTAssertNotEqual(cards.lightTypeMask & 0x2000_0000, 0)    // ALPHA_TEST
        XCTAssertTrue(!metal.usesCards && metal.cutouts.isEmpty)   // nothing cuts them out there: leaves stay meshes
        XCTAssertEqual(metal.lightTypeMask & 0x2000_0000, 0)
        let cut = cards.meshes.filter { $0.cutout != 0 }
        XCTAssertFalse(cut.isEmpty)
        for mesh in cut {
            XCTAssertLessThanOrEqual(Int(mesh.cutout >> 24), cards.cutouts.count)
            XCTAssertLessThan(Int(mesh.cutout & 0xFF_FFFF), Int(mesh.indexCount) / 3)
        }
        let blas = BVHBuilder.buildBLAS(positions: cards.positions, indices: cards.indices, meshes: cards.meshes, uvs: cards.uvs)
        let marked = stride(from: 0, to: blas.triangles.count, by: 3).filter { blas.triangles[$0 + 1].w.bitPattern >> 30 != 0 || blas.triangles[$0 + 2].w.bitPattern >> 30 != 0 }.count
        XCTAssertEqual(marked, cut.reduce(0) { $0 + Int($1.indexCount) / 3 - Int($1.cutout & 0xFF_FFFF) })
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders/Intersect.metal")
        XCTAssertTrue(try String(contentsOf: folder, encoding: .utf8).contains("constant uint CUTOUT_SIZE = \(FoliageTextures.cardSheetSize);"))
    }

    /// Autumn recolours the leaves of the species that turn and nothing else; summer brings the colours back.
    func testSeasonsTurnTheLeaves() {
        func leaves(_ species: Foliage.Species) -> (scene: Scene, summer: [SIMD4<Float>]) {
            let scene = Scene(SceneSettings())
            let flora = Scene.Flora(scene, seed: 3, species: [species])
            flora.place(species, flora.plants(species, .mature)[0], at: .zero, yaw: 0, size: 1, shade: 0)
            scene.setLeaves(season: 0.3)
            _ = scene.takeMaterialsDirty()
            return (scene, scene.materials.map(\.albedo))
        }
        let oak = leaves(.oak)
        oak.scene.setLeaves(season: 0.8)
        let dirty = oak.scene.takeMaterialsDirty()
        let changed = oak.scene.materials.indices.filter { oak.scene.materials[$0].albedo != oak.summer[$0] }
        XCTAssertFalse(changed.isEmpty)
        XCTAssertTrue(changed.allSatisfy { dirty?.contains($0) == true })
        for i in changed {
            XCTAssertGreaterThan(oak.scene.materials[i].albedo.x, oak.scene.materials[i].albedo.y)   // red-brown, no longer green
            XCTAssertGreaterThan(oak.scene.materials[i].params.w, 0)                                 // a leaf material: translucent
        }
        oak.scene.setLeaves(season: 0.3)
        XCTAssertEqual(oak.scene.materials.map(\.albedo), oak.summer)

        let conifer = leaves(.conifer)
        conifer.scene.setLeaves(season: 0.8)
        XCTAssertNil(conifer.scene.takeMaterialsDirty())
        XCTAssertEqual(conifer.scene.materials.map(\.albedo), conifer.summer)

        // Opaque leaves: every leaf material lets nothing through, and the colours stay.
        XCTAssertTrue(conifer.scene.materials.contains { $0.params.w > 0 })
        conifer.scene.setLeaves(season: 0.8, translucency: 0)
        XCTAssertNotNil(conifer.scene.takeMaterialsDirty())
        XCTAssertTrue(conifer.scene.materials.allSatisfy { $0.params.w == 0 })
        XCTAssertEqual(conifer.scene.materials.map(\.albedo), conifer.summer)

        // Leaves fall late in the autumn, and only then.
        XCTAssertEqual(Scene.leafFall(season: 0.3), 0)
        XCTAssertEqual(Scene.leafFall(season: 0.62), 0)
        XCTAssertEqual(Scene.leafFall(season: 1), 1)
        let fall = stride(from: Float(0), through: 1, by: 0.05).map { Scene.leafFall(season: $0) }
        XCTAssertTrue(zip(fall, fall.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
