import XCTest
import simd
@testable import MetalRenderer

/// The built-in plants as they were before the plant editor: the library's meshes, where the forest, the valley and
/// the open world put them, their materials and the names the caches know them by. Whoever means to change what a
/// built-in plant looks like or where it grows changes these hashes (and says so); the editor's refactors must not.
final class PlantGoldenTests: XCTestCase {
    private struct Hash {
        var hasher = GeneratedCache.Hasher()
        mutating func add<T>(_ values: [T]) { hasher.add(values) }
        mutating func add(_ text: String) { hasher.add(text) }
        /// (A SIMD3's fourth lane is padding, whatever it holds: only its three count.)
        mutating func add3(_ values: [SIMD3<Float>]) { hasher.add(values.flatMap { [$0.x, $0.y, $0.z] }) }
        mutating func add(_ mesh: Foliage.Mesh) {
            add3(mesh.positions)
            add3(mesh.normals)
            add(mesh.uvs)
            add(mesh.indices)
            add([Int32(mesh.leafVertex), Int32(mesh.leafIndex), mesh.cutout ? 1 : 0] as [Int32])
        }
        var value: String { String(hasher.name().prefix(12)) }
    }

    private func library(_ sets: [Foliage.SpeciesSet]) -> String {
        var h = Hash()
        for set in sets {
            h.add("\(set.species.rawValue)")
            set.palette.forEach { h.add($0) }
            for plant in set.plants {
                h.add("\(plant.age.rawValue)")
                plant.meshes.forEach { h.add($0) }
                h.add(plant.parts.map(\.transform))
                h.add(Array(plant.parts.map { [Int32($0.mesh), $0.shared ? 1 : 0, Int32($0.bone)] as [Int32] }.joined()))
                h.add(plant.bones.map { SIMD4<Float>($0.pivot, $0.length) })
                h.add(plant.bones.map { SIMD4<Float>($0.axis, $0.radius) })
                h.add(plant.bones.map { SIMD2<Float>(Float($0.parent), $0.phase) })
                h.add3([plant.bounds.lo, plant.bounds.hi])
            }
        }
        return h.value
    }

    private func scene(_ scene: Scene) -> String {
        var h = Hash()
        h.add3(scene.positions)
        h.add3(scene.normals)
        h.add(scene.indices)
        h.add(scene.instances.map(\.transform))
        h.add(Array(scene.instances.map { [Int32($0.mesh), Int32($0.material), Int32($0.assembly)] as [Int32] }.joined()))
        scene.setLeaves(season: 0.85)   // autumn: the leaf materials' turns show too
        h.add(scene.materials)
        for assembly in scene.assemblies {
            h.add(assembly.parts.map(\.transform))
            h.add(assembly.parts.map { SIMD4<Float>(Float($0.mesh), Float($0.firstLeaf), Float($0.leafCount), $0.windPad) })
            h.add3(Array(assembly.parts.map { [$0.bounds.lo, $0.bounds.hi, $0.limb.axis, $0.bough.axis] as [SIMD3<Float>] }.joined()))
            h.add([Int32(assembly.evergreen ? 1 : 0)])
        }
        h.add(scene.meshNames.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n"))
        h.add(scene.voxelPlants.map(\.key).joined(separator: "\n"))
        return h.value
    }

    func testTheLibraryIsAsItWas() {
        XCTAssertEqual(library(Foliage.library(seed: 1)), "ee5b50d98f6b")
        XCTAssertEqual(library(Foliage.library(seed: 7, cards: true)), "9f62104e307d")
    }

    func testTheForestIsAsItWas() {
        var settings = SceneSettings(kind: .forest)
        settings.plantCatalog = "builtin"   // (not what Assets/Plants may hold)
        settings.trees = 300
        settings.undergrowth = 25
        XCTAssertEqual(scene(Scene(settings)), "030968abcca8")
        XCTAssertEqual(scene(Scene(settings, assemblies: true, voxelBoxes: true)), "e2437d8c2503")
        settings.leafCards = true
        XCTAssertEqual(scene(Scene(settings, assemblies: true)), "e219abcfc11d")
    }

    func testTheValleyIsAsItWas() {
        var settings = SceneSettings(kind: .valley)
        settings.plantCatalog = "builtin"
        XCTAssertEqual(scene(Scene(settings)), "345d569c562c")
    }

    func testTheWorldsPlantsAreAsTheyWere() {
        let world = World(seed: 1)
        let flora = World.Flora(Foliage.library(seed: 1))
        var h = Hash()
        for (x, z) in [(0, 0), (3, -2), (-5, 7), (12, 4)] {
            let side = Double(World.tileSize), x0 = Double(x) * side, z0 = Double(z) * side
            h.add(world.trees(x0: x0, z0: z0, side: side, flora: flora))
            for j in 0..<4 { h.add(world.groundCover(x0: x0, z0: z0 + Double(j) * 32, side: 32, flora: flora)) }
            h.add(WorldTile.place(world, x: x, z: z))
        }
        XCTAssertEqual(h.value, "fd2a42daf43a")
    }
}
