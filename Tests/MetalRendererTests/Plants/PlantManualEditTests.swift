import XCTest
import simd
@testable import EngineCore
@testable import MetalRenderer
@testable import Plants

/// The Manual Edit node: one hero plant, its points moved, turned and cut, by the tools and in the file.
final class PlantManualEditTests: XCTestCase {
    private var tree: Growth.Plant {
        var p = Growth.Params()
        p.cycles = 24
        p.targetHeight = 8
        p.maxGeneration = 3
        p.trunk.segment = 0.4
        var plant = Growth.Plant(p, seed: 9)
        for _ in 0..<p.cycles { plant.cycle() }
        return plant
    }

    private func editing(_ e: Growth.ManualEdit = Growth.ManualEdit()) -> PlantEditing { PlantEditing(base: tree, settings: e) }

    /// A branch with a branch on it, and a place along it past its foot with both a next point and something beyond.
    private func limb(_ plant: Growth.Plant) -> (branch: Int, child: Int) {
        for (c, branch) in plant.branches.enumerated() where !branch.removed && branch.generation == 3 && branch.points.count >= 3 {
            let parent = Int(branch.parent)
            if plant.branches[parent].generation == 2, plant.branches[parent].points.count >= 6 { return (parent, c) }
        }
        fatalError("no limb")
    }

    private func beyond(_ plant: Growth.Plant, _ point: Int) -> [Int] {
        var out: [Int] = [], on = Set([point])
        for i in plant.points.indices where i > point && !plant.points[i].removed && on.contains(Int(plant.points[i].parent)) {
            out.append(i)
            on.insert(i)
        }
        return out
    }

    private func pick(_ e: PlantEditing, branch: Int, index: Int) -> PlantEditing.Pick {
        PlantEditing.Pick(branch: branch, index: index, point: Int(e.edited.branches[branch].points[index]))
    }

    // MARK: - Move

    /// A move takes the point by the delta, what's beyond with it, nothing below; another order of the edits, the same.
    func testAMoveCarriesWhatIsBeyond() {
        var e = editing()
        let (b, _) = limb(e.base)
        let at = pick(e, branch: b, index: 3)
        var spread = PlantEditing.Spread()
        spread.measure = .neighbours
        let before = e.edited.points.map(\.position)
        let delta = SIMD3<Float>(0.3, -0.1, 0.2)
        e.move(by: delta, weights: e.weights(at, spread))
        XCTAssertEqual(e.settings.points, [at.point], "one point's internode says all of it")
        XCTAssertEqual(e.settings.grown, e.base.points.count)
        let on = Set([at.point] + beyond(e.base, at.point))
        for i in e.edited.points.indices where !e.edited.points[i].removed {
            let expected = on.contains(i) ? before[i] + delta : before[i]
            XCTAssertEqual(simd_distance(e.edited.points[i].position, expected), 0, accuracy: 1e-4, "\(i)")
        }
        // The frames and lengths follow.
        for (i, point) in e.edited.points.enumerated() where i > 0 && !point.removed && point.parent >= 0 {
            let d = point.position - e.edited.points[Int(point.parent)].position
            XCTAssertEqual(simd_length(d), point.segment, accuracy: 1e-3)
            XCTAssertEqual(simd_distance(normalize(d), point.direction), 0, accuracy: 1e-3)
            XCTAssertEqual(simd_length(point.lateral), 1, accuracy: 1e-3)
        }
    }

    /// With a reach, what's near takes a share by the falloff, and the foot side's points telescope to their weights;
    /// on a branch already turned, the delta is still the world's.
    func testASpreadMoveTakesItsWeights() {
        var e = editing()
        let (b, _) = limb(e.base)
        let at = pick(e, branch: b, index: 3)
        e.turn(pick(e, branch: b, index: 1), axis: [0, 0, 1], angle: 0.6)
        var spread = PlantEditing.Spread()
        spread.reach = 0.7
        spread.carries = true
        let w = e.weights(at, spread)
        let before = e.edited.points.map(\.position)
        let delta = SIMD3<Float>(0, 0.25, 0.1)
        e.move(by: delta, weights: w)
        XCTAssertEqual(w[at.point], 1)
        XCTAssertTrue(w.contains { $0 > 0 && $0 < 1 }, "something takes a share")
        for i in e.edited.points.indices where !e.edited.points[i].removed {
            XCTAssertEqual(simd_distance(e.edited.points[i].position, before[i] + delta * w[i]), 0, accuracy: 2e-3, "\(i), weight \(w[i])")
        }
    }

    /// Unreal's seven falloffs, and its three ways to measure.
    func testASpread() {
        var s = PlantEditing.Spread()
        let cases: [(PlantEditing.Spread.Falloff, Float)] = [(.linear, 0.25), (.smooth, 0.15625), (.sphere, 0.66143), (.root, 0.5), (.sharp, 0.0625), (.sine, 0.38268), (.constant, 1)]
        for (falloff, expected) in cases {
            s.falloff = falloff
            XCTAssertEqual(s.shaped(0.25), expected, accuracy: 1e-4, falloff.rawValue)
        }
        let e = editing()
        let (b, _) = limb(e.base)
        let at = pick(e, branch: b, index: 3)
        s = PlantEditing.Spread()
        s.carries = false
        s.falloff = .linear
        s.measure = .neighbours
        s.neighbours = 0
        XCTAssertEqual(e.weights(at, s).filter { $0 > 0 }.count, 1)
        s.neighbours = 1
        let near = e.weights(at, s)
        XCTAssertEqual(near[at.point], 1)
        XCTAssertEqual(near[Int(e.edited.points[at.point].parent)], 0.5)
        XCTAssertEqual(near[Int(e.edited.branches[b].points[4])], 0.5)
        s.measure = .distance
        s.reach = 0.5
        for (i, weight) in e.weights(at, s).enumerated() where !e.edited.points[i].removed && e.edited.points[i].parent >= 0 {
            let d = simd_distance(e.edited.points[i].position, e.edited.points[at.point].position)
            XCTAssertEqual(weight, i == at.point ? 1 : max(1 - d / 0.5, 0), accuracy: 1e-4)
        }
    }

    // MARK: - Turn

    /// A turn carries all beyond the point about it, rigidly; the point and what's below stay; the opposite turn undoes it.
    func testATurnIsRigidAndCarries() {
        var e = editing()
        let (b, _) = limb(e.base)
        let at = pick(e, branch: b, index: 2)
        let before = e.edited.points.map(\.position)
        let hinge = before[at.point], axis = normalize(SIMD3<Float>(1, 0.5, 0)), q = simd_quatf(angle: 0.5, axis: axis)
        e.turn(at, axis: axis, angle: 0.5)
        let on = Set(beyond(e.base, at.point))
        XCTAssertFalse(on.isEmpty)
        for i in e.edited.points.indices where !e.edited.points[i].removed {
            let expected = on.contains(i) ? hinge + q.act(before[i] - hinge) : before[i]
            XCTAssertEqual(simd_distance(e.edited.points[i].position, expected), 0, accuracy: 1e-3, "\(i)")
        }
        XCTAssertEqual(e.settings.points.count, e.base.points.indices.filter { e.base.points[$0].parent == Int32(at.point) && !e.base.points[$0].removed }.count, "one for each thing on the point")
        e.turn(at, axis: axis, angle: -0.5)
        for i in e.edited.points.indices where !e.edited.points[i].removed {
            XCTAssertEqual(simd_distance(e.edited.points[i].position, before[i]), 0, accuracy: 1e-3, "\(i)")
        }
    }

    /// A tip has nothing to turn; a turn there changes nothing.
    func testATipHasNothingToTurn() {
        var e = editing()
        let (b, _) = limb(e.base)
        let tip = pick(e, branch: b, index: e.edited.branches[b].points.count - 1)
        XCTAssertFalse(e.canTurn(tip))
        XCTAssertTrue(e.canTurn(pick(e, branch: b, index: 2)))
        e.turn(tip, axis: [0, 0, 1], angle: 1)
        XCTAssertTrue(e.settings.points.isEmpty)
    }

    /// Turning at a branch's foot turns that branch alone, not what else is on the point.
    func testATurnAtABranchsFootIsThatBranchs() {
        var e = editing()
        let (b, c) = limb(e.base)
        let at = pick(e, branch: c, index: 0)
        let before = e.edited.points.map(\.position)
        e.turn(at, axis: [0, 1, 0], angle: 0.7)
        let own = Set(e.base.branches[c].points.dropFirst().map(Int.init).flatMap { [$0] + beyond(e.base, $0) })
        for i in e.edited.points.indices where !e.edited.points[i].removed && !own.contains(i) {
            XCTAssertEqual(e.edited.points[i].position, before[i], "\(i), not on the branch")
        }
        XCTAssertNotEqual(e.edited.points[Int(e.base.branches[c].points.last!)].position, before[Int(e.base.branches[c].points.last!)])
        _ = b
    }

    // MARK: - Cut

    /// Trim: beyond the point, what's on it gone, the rest thinner by the share left (Unreal's). Remove: all of it. The
    /// first axis's foot stays.
    func testCuts() {
        var e = editing()
        let (b, c) = limb(e.base)
        let nodes = e.base.branches[b].points
        let foot = e.base.points[Int(nodes[1])].radius
        let childFoot = Int(e.base.branches[c].points[0])
        let index = nodes.firstIndex { Int($0) == childFoot }!
        XCTAssertGreaterThan(index, 0)
        // Above the child's foot: the child stays, thinner; the cut is thin by the share.
        let at = index + 1 < nodes.count - 1 ? index + 1 : index
        XCTAssertTrue(e.remove(pick(e, branch: b, index: at), trim: true))
        let cut = at + 1
        XCTAssertEqual(e.edited.branches[b].points.count, cut)
        for q in nodes[cut...] { XCTAssertTrue(e.edited.points[Int(q)].removed) }
        XCTAssertEqual(e.edited.points[Int(nodes[1])].radius, foot * Float(cut) / Float(nodes.count), accuracy: 1e-5)
        XCTAssertFalse(e.edited.branches[c].removed, "what's below the cut stays")
        XCTAssertLessThan(e.edited.points[Int(e.base.branches[c].points[1])].radius, e.base.points[Int(e.base.branches[c].points[1])].radius)

        // A trim of a tip takes the tip.
        var tip = editing()
        let last = tip.base.branches[b].points.count - 1
        XCTAssertTrue(tip.remove(pick(tip, branch: b, index: last), trim: true))
        XCTAssertEqual(tip.edited.branches[b].points.count, last)

        // Remove: the branch and all on it.
        var whole = editing()
        XCTAssertTrue(whole.remove(pick(whole, branch: b, index: 3), trim: false))
        XCTAssertTrue(whole.edited.branches[b].removed)
        XCTAssertTrue(whole.edited.branches[c].removed)
        for q in beyond(whole.base, Int(nodes[1])) { XCTAssertTrue(whole.edited.points[q].removed, "\(q)") }

        // Of the trunk, only what's above its first internode.
        var trunk = editing()
        XCTAssertFalse(trunk.remove(pick(trunk, branch: 0, index: 2), trim: false))
        XCTAssertFalse(trunk.remove(pick(trunk, branch: 0, index: 0), trim: true))
        XCTAssertTrue(trunk.settings.removed.isEmpty)
        XCTAssertTrue(trunk.remove(pick(trunk, branch: 0, index: 2), trim: true))
        XCTAssertEqual(trunk.edited.branches[0].points.count, 3)
        // A number from a plant that has changed since is left out, and told.
        var stale = Growth.ManualEdit()
        stale.removed = [1_000_000]
        stale.points = [1_000_000]
        stale.moves = [[1, 0, 0]]
        stale.turns = [[0, 0, 0, 1]]
        stale.grown = 3
        let was = editing(stale)
        XCTAssertTrue(was.isStale)
        XCTAssertEqual(was.edited.points.map(\.position), was.base.points.map(\.position))
    }

    /// What the ray meets: the nearest wood, or nothing; what the tool's picks say is still there.
    func testPicks() {
        var e = editing()
        let (b, _) = limb(e.base)
        let at = pick(e, branch: b, index: 3)
        let target = e.position(at.point), eye = target + [0.3, 0.2, 9]
        let hit = e.pick(origin: eye, direction: normalize(target - eye), tolerance: 0.0005)
        XCTAssertNotNil(hit)
        XCTAssertEqual(simd_distance(e.position(hit!.point), target), 0, accuracy: 0.45)
        XCTAssertNil(e.pick(origin: [50, 5, 50], direction: normalize(SIMD3(1, 0, 1))))
        XCTAssertTrue(e.isThere(at))
        e.remove(at, trim: false)
        XCTAssertFalse(e.isThere(at))
    }

    /// The handle's parts under a ray.
    func testTheHandlesParts() {
        let handle = SIMD3<Float>(1, 2, 3), eye = handle + [4, 3, 5], size = PlantToolHandle.size(handle, from: eye)
        func at(_ p: SIMD3<Float>) -> PlantToolHandle.Part? { PlantToolHandle.part(handle, size: size, origin: eye, direction: normalize(p - eye)) }
        XCTAssertEqual(at(handle + [size * 0.9, 0, 0]), .arrow(0))
        XCTAssertEqual(at(handle + [0, size * 0.9, 0]), .arrow(1))
        XCTAssertEqual(at(handle + [0, 0, size * 0.9]), .arrow(2))
        // (On a ring, between the arrows.)
        let r = size * 0.7, s = r * Float(0.5).squareRoot()
        XCTAssertEqual(at(handle + [s, s, 0]), .ring(2))
        XCTAssertEqual(at(handle + [0, s, s]), .ring(0))
        XCTAssertEqual(at(handle + [s, 0, s]), .ring(1))
        XCTAssertNil(at(handle + [size * 3, size * 3, 0]))
        // A tip has no rings to press.
        XCTAssertNil(PlantToolHandle.part(handle, size: size, origin: eye, direction: normalize(handle + [s, s, 0] - eye), rings: false))
        XCTAssertLessThan(PlantToolHandle.segments(handle, size: size, rings: false).count, PlantToolHandle.segments(handle, size: size).count)
        XCTAssertFalse(PlantToolHandle.segments(handle, size: size).isEmpty)
    }

    // MARK: - In the graph

    private func hero(_ def: Foliage.SpeciesDef, age: Foliage.Age = .mature, variant: Int = 0, base: UInt64, edit: (inout PlantEditing) -> Void = { _ in }) -> PlantGraph {
        var graph = PlantGraph.standard(def)
        var e = Growth.ManualEdit()
        e.age = age.rawValue
        e.variant = variant
        e.seed = def.plantSeed(base, age, variant)
        // (After what the species has last.)
        graph.insert(.manualEdit(e), after: graph.first(.carve, .plant) == nil ? .grow : .carve)
        let id = graph.first(.manualEdit, .plant)!.id
        var editing = PlantEditing(graph: graph, node: id, species: .oak)!
        edit(&editing)
        graph.nodes[graph.nodes.firstIndex { $0.id == id }!].settings = .manualEdit(editing.settings)
        return graph
    }

    /// A node that edits nothing changes nothing; the hero grows from its seed in every scene, every other plant as ever;
    /// the edit is on it alone.
    func testTheHeroIsOnePlantInEveryScene() throws {
        var def = PlantCatalog.builtIn[.oak]
        let plain = def, s = Foliage.Species.oak
        def.ages.variants = [1, 1, 2]
        let graph = hero(def, variant: 1, base: 5) { e in
            let (b, _) = self.limb(e.base)
            e.remove(self.pick(e, branch: b, index: 1), trim: false)
        }
        def.setGraph(graph)
        XCTAssertFalse(graph.isStandard)
        XCTAssertNil(graph.problem)
        let e = { () -> Growth.ManualEdit in
            guard case .manualEdit(let e) = graph.first(.manualEdit, .plant)!.settings else { fatalError() }
            return e
        }()
        XCTAssertEqual(def.plantSeed(77, .mature, 1), e.seed)
        XCTAssertEqual(def.plantSeed(77, .mature, 0), Foliage.seed(77, def.seedIndex, Foliage.Age.mature.rawValue, 0))
        XCTAssertEqual(plain.plantSeed(77, .mature, 1), Foliage.seed(77, plain.seedIndex, Foliage.Age.mature.rawValue, 1), "no node, its own seed")

        func plants(_ base: UInt64) -> [Foliage.Plant] {
            var catalog = PlantCatalog.builtIn
            catalog.species[s.rawValue] = def
            return Foliage.library(seed: base, catalog: catalog, species: [s])[0].plants
        }
        let a = plants(5), b = plants(6)
        let heroIndex = a.count - 1
        XCTAssertEqual(a[heroIndex].meshes.flatMap(\.positions), b[heroIndex].meshes.flatMap(\.positions), "the hero is the same in another scene")
        XCTAssertEqual(a[heroIndex].parts.map(\.transform), b[heroIndex].parts.map(\.transform), "its twigs hang in the same places")
        XCTAssertNotEqual(a[heroIndex - 1].meshes.flatMap(\.positions), b[heroIndex - 1].meshes.flatMap(\.positions), "the other variant isn't")
        // It has the cut; a plain plant of the same seed hasn't.
        let runner = PlantRunner(.graph(.standard(plain)))
        let uncut = runner.skeleton(s, age: .mature, seed: e.seed)!, cut = PlantRunner(.graph(graph)).skeleton(s, age: .mature, seed: e.seed)!
        XCTAssertLessThan(cut.skeleton.stems.count, uncut.skeleton.stems.count)
        // Of another seed: nothing is edited.
        let other = PlantRunner(.graph(graph)).skeleton(s, age: .mature, seed: e.seed &+ 1)!
        XCTAssertEqual(other.skeleton.stems.count, runner.skeleton(s, age: .mature, seed: e.seed &+ 1)!.skeleton.stems.count)

        // Edits nothing: the same plant, byte for byte.
        var none = PlantGraph.standard(plain)
        var empty = Growth.ManualEdit()
        empty.seed = e.seed
        none.insert(.manualEdit(empty), after: .carve)
        let palette = (0..<2).map { runner.twig(s, variant: $0, of: 2, sparse: 0.85, seed: UInt64($0)) }
        let x = runner.plant(s, age: .mature, seed: e.seed, palette: palette), y = PlantRunner(.graph(none)).plant(s, age: .mature, seed: e.seed, palette: palette)
        XCTAssertEqual(x.meshes.flatMap(\.positions), y.meshes.flatMap(\.positions))
        XCTAssertEqual(x.parts.map(\.transform), y.parts.map(\.transform))
    }

    /// An edited hero is a sound plant, whatever's been done to it.
    func testAnEditedPlantIsSound() {
        var def = PlantCatalog.builtIn[.oak]
        let graph = hero(def, base: 3) { e in
            let (b, c) = self.limb(e.base)
            var spread = PlantEditing.Spread()
            spread.reach = 1
            let at = self.pick(e, branch: b, index: 3)
            e.move(by: [0.5, -0.3, 0.1], weights: e.weights(at, spread))
            e.turn(at, axis: [1, 0, 0], angle: 0.8)
            e.turn(self.pick(e, branch: c, index: 0), axis: [0, 1, 0], angle: -0.5)
            e.remove(self.pick(e, branch: 0, index: e.edited.branches[0].points.count - 2), trim: true)
        }
        def.setGraph(graph)
        guard case .manualEdit(let e) = graph.first(.manualEdit, .plant)!.settings else { return XCTFail() }
        let runner = PlantRunner(.graph(graph))
        let palette = (0..<2).map { runner.twig(.oak, variant: $0, of: 2, sparse: 0.85, seed: UInt64($0)) }
        let plant = runner.plant(.oak, age: .mature, seed: e.seed, palette: palette)
        for mesh in plant.meshes { XCTAssertEqual(Foliage.problems(mesh), []) }
        XCTAssertEqual(plant.bones[0].parent, -1)
        for (b, bone) in plant.bones.enumerated().dropFirst() { XCTAssertTrue(bone.parent >= 0 && Int(bone.parent) < b) }
        for part in plant.parts {
            XCTAssertTrue(plant.bones.indices.contains(part.bone))
            for k in 0..<4 { XCTAssertFalse(part.transform[k].x.isNaN || part.transform[k].y.isNaN || part.transform[k].z.isNaN) }
        }
    }

    /// In the file: its edits come back as they were, the seed exact; compiled, the same plant as the graph run.
    func testTheFileRoundTripsAndCompilesToTheSamePlant() throws {
        var def = PlantCatalog.builtIn[.birch]
        var graph = hero(def, base: 11) { e in
            let (b, _) = self.limb(e.base)
            let at = self.pick(e, branch: b, index: 2)
            var spread = PlantEditing.Spread()
            spread.reach = 0.6
            e.move(by: [0.123456789, -0.3, 1e-3], weights: e.weights(at, spread))
            e.turn(at, axis: [0, 0, 1], angle: 0.4)
            e.remove(self.pick(e, branch: b, index: 4), trim: true)
        }
        graph.nodes[0].at = [10, 20]
        def.setGraph(graph)
        guard case .manualEdit(let e) = graph.first(.manualEdit, .plant)!.settings else { return XCTFail() }
        XCTAssertGreaterThan(e.seed, UInt64(1) << 53, "a seed no Double holds")
        let text = PlantSwift.emit(def).text
        XCTAssertTrue(text.contains("let manualEdit = p.manualEdit("), text)
        XCTAssertTrue(text.contains("$0.seed = \(e.seed)"), text)
        let back = try XCTUnwrap(PlantSwift.parse(text))
        XCTAssertEqual(back.graph?.canonical, def.graph?.canonical)
        XCTAssertEqual(PlantSwift.emit(back).text, text)

        if let why = PlantCompiler.shared.problem() { throw XCTSkip(why) }
        let compiled = try PlantCompiler.shared.program(of: def).get()
        func grown(_ runner: PlantRunner) -> (positions: [SIMD3<Float>], transforms: [float4x4], phases: [Float]) {
            let palette = (0..<def.paletteSize).map { runner.twig(.birch, variant: $0, of: def.paletteSize, sparse: def.twigs?.sparse, seed: UInt64($0) &+ 3) }
            let plant = runner.plant(.birch, age: .mature, seed: e.seed, palette: palette)
            return (plant.meshes.flatMap(\.positions), plant.parts.map(\.transform), plant.bones.map(\.phase))
        }
        let a = grown(PlantRunner(.graph(graph))), b = grown(PlantRunner(.program(compiled.program)))
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertEqual(a.transforms, b.transforms)
        XCTAssertEqual(a.phases, b.phases)
        XCTAssertNotEqual(a.positions, grown(PlantRunner(.graph(.standard(PlantCatalog.builtIn[.birch])))).positions, "the edit is on it")
    }
}
