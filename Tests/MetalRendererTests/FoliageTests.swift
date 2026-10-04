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

        for assembly in parts.assemblies {
            XCTAssertGreaterThan(assembly.parts.count, 1)
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
