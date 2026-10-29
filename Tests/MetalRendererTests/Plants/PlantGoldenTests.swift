import XCTest
import simd
@testable import Buildings
@testable import Characters
@testable import Editors
@testable import Effects
@testable import EngineCore
@testable import Game
@testable import Landscape
@testable import Materials
@testable import MetalRenderer
@testable import Physics
@testable import Plants

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

    /// (Oct 2026: leaf clusters, LeafRecipe.cluster: the oak's leaves in threes, the birch's, bush's and conifer's in
    /// twos, fuller crowns as Unreal's Mega Plants have. Leaf cards don't grow leaves: their hashes stay.)
    /// (Oct 2026: the oak grown bud by bud, Growth, Unreal's way, its wood by Growth.wood, dressed in
    /// Growth.twig twigs of outline leaves where Growth's distributor puts them: every hash that holds an oak.)
    /// (Oct 2026: every built-in species but grass grown so, birch, conifer, dead tree, bush and fern re-authored.)
    /// (Oct 2026: twig leaves carry their twig's health in U; grown leaves two-sided with a sheen in either look.)
    /// (Oct 2026: the oak as Unreal's vegetation editor shows the Mega Plants tree: open, half-flattened sprays, olive
    /// leaves. Every hash that holds an oak, the leaf cards' too, whose cards follow the twigs.)
    /// (Oct 2026: the birch and the bush measured against Unreal's sample aspen and hazels: the birch's crown open to
    /// every bud, its trunk thinner and its internodes shorter; the bush's stems a hazel's. Then each a leaf sheet of its
    /// own (leaves-birch, leaves-bush), and the built-in plants' meshes named by their recipes too. Every hash that holds
    /// either; the scenes' all, by the names.)
    func testTheLibraryIsAsItWas() {
        XCTAssertEqual(library(Foliage.library(seed: 1)), "d80344403732")
        XCTAssertEqual(library(Foliage.library(seed: 7, cards: true)), "4e70b286ba9e")
    }

    /// (Oct 2026: the ground became the terrain's sectors, its layer materials added: the plants as they were, the
    /// pictures the same as main's. Then its stream and pond: no plant in the water.)
    /// (Oct 2026: Foliage.version 2, the grown species: the same plants, the meshes' and voxels' names "plants v2".
    /// So the valley's and the world's too.)
    /// (Oct 2026: the birch and the bush measured against Unreal's sample aspen and hazels: the birch's crown open to
    /// every bud, its trunk thinner and its internodes shorter; the bush's stems a hazel's. Then each a leaf sheet of its
    /// own (leaves-birch, leaves-bush), and the built-in plants' meshes named by their recipes too. Every hash that holds
    /// either; the scenes' all, by the names.)
    func testTheForestIsAsItWas() {
        var settings = SceneSettings(kind: .forest)
        settings.plantCatalog = "builtin"   // (not what Assets/Plants may hold)
        settings.realism = .off             // (the generated plants, not the scans: the same with or without them)
        settings.trees = 300
        settings.undergrowth = 25
        XCTAssertEqual(scene(Scene(settings)), "975b7bee1496")
        XCTAssertEqual(scene(Scene(settings, assemblies: true, voxelBoxes: true)), "155809edcfce")
        settings.leafCards = true
        XCTAssertEqual(scene(Scene(settings, assemblies: true)), "33ef1dbc0ff2")
    }

    /// (Oct 2026: a lake and its stream in place of the pond's slab, no tree in them.)
    /// (Oct 2026: the birch and the bush measured against Unreal's sample aspen and hazels: the birch's crown open to
    /// every bud, its trunk thinner and its internodes shorter; the bush's stems a hazel's. Then each a leaf sheet of its
    /// own (leaves-birch, leaves-bush), and the built-in plants' meshes named by their recipes too. Every hash that holds
    /// either; the scenes' all, by the names.)
    func testTheValleyIsAsItWas() {
        var settings = SceneSettings(kind: .valley)
        settings.plantCatalog = "builtin"
        settings.realism = .off
        XCTAssertEqual(scene(Scene(settings)), "fd1b2899d878")
    }

    func testTheWorldsPlantsAreAsTheyWere() {
        let world = World(seed: 1)
        let flora = World.Flora(Foliage.library(seed: 1))
        var h = Hash()
        for (x, z) in [(0, 0), (3, -2), (-5, 7), (12, 4)] {
            let side = Double(World.tileSize), x0 = Double(x) * side, z0 = Double(z) * side
            h.add(world.trees(x0: x0, z0: z0, side: side, flora: flora))
            for j in 0..<4 { h.add(world.groundCover(x0: x0, z0: z0 + Double(j) * 32, side: 32, flora: flora)) }
            // (The tiles' name as of World.version 6: 7 changed the buildings, not where the plants stand; 9 its water,
            // which they keep out of.)
            h.add(WorldTile.place(world, x: x, z: z).replacingOccurrences(of: "tile v\(World.version) ", with: "tile v6 "))
        }
        XCTAssertEqual(h.value, "df78ee29ac26")
    }
}
