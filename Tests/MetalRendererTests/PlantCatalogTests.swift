import XCTest
import simd
@testable import MetalRenderer

/// PlantSpecies.swift, PlantCurve.swift: the species as data give exactly what the code before them did, and come
/// back from JSON exactly as they went.
final class PlantCatalogTests: XCTestCase {
    /// The curves' presets are the formulas the recipes had before, bit for bit.
    func testCurvePresetsAreTheOldFormulas() {
        var rng = SplitMix64(seed: 5)
        for _ in 0..<1000 {
            let x = rng.next(), a = rng.range(-2, 2), b = rng.range(-2, 2), t = rng.range(0, 1)
            XCTAssertEqual(Foliage.Curve.taper(t).value(x).bitPattern, (1 - t * x).bitPattern)
            XCTAssertEqual(Foliage.Curve.linear(a, b).value(x).bitPattern, (a + (b - a) * x).bitPattern)
            XCTAssertEqual(Foliage.Curve.linear(a, b).start, a)
            XCTAssertEqual(Foliage.Curve.linear(a, b).end, b)
            XCTAssertEqual(Foliage.Curve.taper(0.5).value(x).bitPattern, (1 - 0.5 * x).bitPattern)
            for crown in Foliage.Crown.allCases {
                XCTAssertEqual(Foliage.Curve.crown(crown).value(x).bitPattern, Foliage.crownRatio(crown, 1 - x).bitPattern)
            }
        }
    }

    /// Points: through each point, flat beyond the ends, never past its neighbours between them (monotone).
    func testPointCurvesStayBetweenTheirPoints() {
        let points: [SIMD2<Float>] = [[0, 0.2], [0.3, 1], [0.5, 0.9], [0.8, 0.1], [1, 0.15]]
        let curve = Foliage.Curve.points(points)
        for p in points { XCTAssertEqual(curve.value(p.x), p.y, accuracy: 1e-6) }
        XCTAssertEqual(curve.value(-1), 0.2)
        XCTAssertEqual(curve.value(2), 0.15)
        for k in 0..<(points.count - 1) {
            let lo = min(points[k].y, points[k + 1].y), hi = max(points[k].y, points[k + 1].y)
            for i in 0...50 {
                let x = points[k].x + (points[k + 1].x - points[k].x) * Float(i) / 50
                XCTAssertTrue(curve.value(x) >= lo - 1e-5 && curve.value(x) <= hi + 1e-5, "\(x): \(curve.value(x))")
            }
        }
        // A preset made editable is the same curve at its points.
        let crown = Foliage.Curve.crown(.flame), editable = crown.editable(samples: 11)
        guard case .points(let ps) = editable else { return XCTFail() }
        for p in ps { XCTAssertEqual(crown.value(p.x), p.y, accuracy: 1e-6) }
    }

    /// The age rules' counts are what the integer arithmetic before them gave.
    func testAgeCountsAreTheIntegerDivisions() {
        for count in 0...2000 {
            XCTAssertEqual(Foliage.CountRule(level: 1, factor: 0.75, minimum: 3).apply(count), max(3, count * 3 / 4))
            XCTAssertEqual(Foliage.CountRule(level: 2, factor: 0.7, minimum: 2).apply(count), max(2, count * 7 / 10))
            XCTAssertEqual(Foliage.CountRule(level: 1, factor: 0.45, minimum: 3).apply(count), max(3, count * 9 / 20))
        }
    }

    private func json(_ catalog: PlantCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(catalog.species)
    }

    /// Every built-in species comes back from JSON as it was, and grows the same plants.
    func testJSONRoundTripIsExact() throws {
        let data = try json(.builtIn)
        let back = PlantCatalog(species: try JSONDecoder().decode([Foliage.SpeciesDef].self, from: data))
        XCTAssertEqual(back, .builtIn)
        XCTAssertEqual(try json(back), data)
        let a = Foliage.library(seed: 4), b = Foliage.library(seed: 4, catalog: back)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.palette.map(\.positions), y.palette.map(\.positions))
            XCTAssertEqual(x.plants.map { $0.meshes.map(\.positions) }, y.plants.map { $0.meshes.map(\.positions) })
            XCTAssertEqual(x.plants.map { $0.parts.map(\.transform) }, y.plants.map { $0.parts.map(\.transform) })
        }
        // The forms read as they are written.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"crown\" : \"hemispherical\""))
        XCTAssertTrue(text.contains("\"distichous\""))
        XCTAssertTrue(text.contains("\"barkTexture\" : \"birchBark\""))
    }

    /// A species of a catalog grows the same plants wherever it stands in it: its seeds are its own.
    func testACustomSpeciesKeepsItsPlants() {
        var willow = PlantCatalog.builtIn[.birch]
        willow.id = "willow"
        willow.seedIndex = 100
        var catalog = PlantCatalog.builtIn
        catalog.species.append(willow)
        let first = Foliage.library(seed: 2, catalog: catalog, species: [Foliage.Species(rawValue: 7)])[0]
        catalog.species.insert(PlantCatalog.builtIn[.oak], at: 7)   // another custom species before it
        let again = Foliage.library(seed: 2, catalog: catalog, species: [Foliage.Species(rawValue: 8)])[0]
        XCTAssertEqual(first.plants.map { $0.meshes.map(\.positions) }, again.plants.map { $0.meshes.map(\.positions) })
        let birch = Foliage.library(seed: 2, species: [.birch])[0]
        XCTAssertNotEqual(first.plants[0].meshes[0].positions, birch.plants[0].meshes[0].positions)
    }

    /// The built-in habitats pick the trees the forest's and the world's formulas picked, at any place.
    func testHabitatsPickWhatTheFormulasDid() {
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        func old(_ r: Float, high: Float, slope: Float, mix: Float, birch: Float) -> Foliage.Species {
            let conifer = max(0.05, 0.3 + 1.1 * smoothstep(-0.1, 0.7, high) + 3 * slope + 1.6 * mix)
            let oak = max(0.05, 0.9 - 0.7 * smoothstep(0, 0.7, high) - 1.6 * mix)
            var pick = r * (conifer + oak + birch) * 1.035
            if pick < conifer { return .conifer }
            pick -= conifer
            if pick < oak { return .oak }
            return pick - oak < birch ? .birch : .dead
        }
        XCTAssertEqual(Float(1) + 0.035, 1.035)
        let picker = Foliage.TreePicker(.builtIn)
        var rng = SplitMix64(seed: 9)
        for _ in 0..<100_000 {
            let r = rng.next(), high = rng.range(-0.5, 1.5), slope = rng.range(0, 0.4), mix = rng.range(-1, 1)
            let a = rng.range(0, 1), b = rng.range(0, 1), c = rng.range(0, 1)
            // The forest's birches: by the clearing and the trail; the world's: at the woods' edge.
            let forest = old(r, high: high, slope: slope, mix: mix, birch: 0.25 + 1.2 * a + 0.8 * b)
            XCTAssertEqual(picker.pick(r, high: high, slope: slope, stand: mix, light: [SIMD2(1.2, a), SIMD2(0.8, b)]), forest)
            let world = old(r, high: high, slope: slope, mix: mix, birch: 0.25 + 1.6 * c)
            XCTAssertEqual(picker.pick(r, high: high, slope: slope, stand: mix, light: [SIMD2(1.6, c)]), world)
        }
        XCTAssertEqual(PlantCatalog.builtIn.covers, [.bush, .fern, .grass])
    }

    // MARK: - Storage, keys, custom species

    private func willowCatalog() -> PlantCatalog {
        var willow = PlantCatalog.builtIn[.birch]
        willow.id = "willow"
        willow.name = "Willow"
        willow.seedIndex = 100
        willow.basedOn = "birch"
        willow.recipe.levels[2].tropism = -1.2
        willow.habitat.order = 50
        willow.habitat.base = 2       // everywhere, and a lot of it
        return PlantCatalog.builtIn.merging([willow])
    }

    func testTheBuiltInSpeciesAreSane() {
        XCTAssertEqual(PlantCatalog.builtIn.sanitized(), .builtIn)
        XCTAssertTrue(PlantCatalog.builtIn.placesAsBuiltIn)
        XCTAssertEqual(PlantCatalog.resolve("builtin"), .builtIn)
    }

    /// Files lay over the built-in species: one of a built-in id replaces it (keeping its seeds), another adds one.
    func testFilesLayOverTheBuiltInSpecies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var oak = PlantCatalog.builtIn[.oak]
        oak.look.bark = [0.3, 0.2, 0.1]
        oak.seedIndex = 55
        try PlantStore.save(oak, in: folder)
        try PlantStore.save(willowCatalog()[Foliage.Species(rawValue: 7)], in: folder)
        let loaded = PlantStore.load(from: folder)
        XCTAssertEqual(loaded.count, 8)
        XCTAssertEqual(loaded[.oak].look.bark, [0.3, 0.2, 0.1])
        XCTAssertEqual(loaded[.oak].seedIndex, 0)
        XCTAssertEqual(loaded.species[7].id, "willow")
        XCTAssertEqual(loaded.species(id: "willow")?.rawValue, 7)
        try PlantStore.remove("oak", in: folder)
        XCTAssertEqual(PlantStore.load(from: folder)[.oak], PlantCatalog.builtIn[.oak])
        XCTAssertEqual(PlantStore.load(from: nil), .builtIn)
        let text = String(decoding: try PlantStore.encode(oak), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\n  \"format\" : 1,"), text)
    }

    /// An edit renames the plants for every cache; a change of colour alone leaves where they stand as it was.
    func testEditsChangeTheKeys() {
        var settings = SceneSettings(kind: .forest)
        settings.trees = 60
        settings.undergrowth = 10
        settings.plantCatalog = "builtin"
        let builtIn = Scene(settings, assemblies: true, voxelBoxes: true)
        var edited = PlantCatalog.builtIn
        edited.species[0].recipe.levels[1].count = 9
        settings.plantCatalog = PlantCatalog.register(edited)
        let other = Scene(settings, assemblies: true, voxelBoxes: true)
        XCTAssertTrue(Set(builtIn.voxelPlants.map(\.key)).isDisjoint(with: other.voxelPlants.map(\.key)))
        XCTAssertTrue(Set(builtIn.meshNames.values).isDisjoint(with: other.meshNames.values))
        XCTAssertTrue(other.voxelPlants.allSatisfy { $0.key.contains("recipes \(edited.fingerprint)") })

        var recoloured = PlantCatalog.builtIn
        recoloured.species[1].look.leaves[0] = [0.5, 0.2, 0.1]
        XCTAssertNotEqual(recoloured.fingerprint, PlantCatalog.builtIn.fingerprint)
        XCTAssertEqual(recoloured.placementFingerprint, PlantCatalog.builtIn.placementFingerprint)
        XCTAssertTrue(recoloured.placesAsBuiltIn)
        XCTAssertFalse(willowCatalog().placesAsBuiltIn)
        XCTAssertEqual(PlantCatalog.resolve(PlantCatalog.register(recoloured)), recoloured)
    }

    /// A custom species grows in the forest and in the open world, as sound plants.
    func testACustomSpeciesGrows() {
        let catalog = willowCatalog()
        let willow = Foliage.Species(rawValue: 7)
        var settings = SceneSettings(kind: .forest)
        settings.trees = 200
        settings.undergrowth = 0
        settings.plantCatalog = PlantCatalog.register(catalog)
        let scene = Scene(settings)
        XCTAssertGreaterThan(scene.meshNames.values.filter { $0.contains("willow") }.count, 0)

        let set = Foliage.library(seed: 1, catalog: catalog, species: [willow])[0]
        for plant in set.plants { for m in plant.meshes { XCTAssertEqual(Foliage.problems(m), []) } }
        let world = World(seed: 1), flora = World.Flora(Foliage.library(seed: 1, catalog: catalog), catalog: catalog)
        var willows = 0
        for x in 0..<4 {
            let side = Double(World.tileSize)
            for t in world.trees(x0: Double(x) * side, z0: 0, side: side, flora: flora) {
                XCTAssertLessThan(Int(t.species), catalog.count)
                if Int(t.species) == 7 {
                    willows += 1
                    XCTAssertLessThan(Int(t.plant), set.plants.count)
                }
            }
        }
        XCTAssertGreaterThan(willows, 0)
    }
}
