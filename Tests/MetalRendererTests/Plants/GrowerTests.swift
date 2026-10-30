import XCTest
import simd
@testable import EngineCore
@testable import Plants

/// The bud-based grower (Growth): what its plants must be whatever its parameters, and what its parts do.
final class GrowerTests: XCTestCase {
    private var tree: Growth.Params {
        var p = Growth.Params()
        p.cycles = 24
        p.targetHeight = 8
        p.maxGeneration = 3
        p.trunk.segment = 0.4
        var b = Growth.Shoot()
        b.segment = 0.3
        b.axillaryRamp = .linear(0.3, 1)
        p.branch = b
        return p
    }

    private func height(_ s: Foliage.Skeleton) -> Float { s.nodes.map(\.y).max() ?? 0 }

    /// A plant of one axis: along +X from the foot, with these radii.
    private func chain(_ radii: [Float], segment: Float = 1, along: SIMD3<Float> = [1, 0, 0]) -> Growth.Plant {
        var p = Growth.Params()
        p.trunk.segment = segment
        var plant = Growth.Plant(p, seed: 1)
        plant.points[1].position = along * segment
        plant.points[1].direction = along
        plant.points[1].lateral = [0, 0, 1]
        for _ in 2..<radii.count { plant.add(to: 0, from: plant.points.count - 1, direction: along, length: segment) }
        for (i, r) in radii.enumerated() { plant.points[i].radius = r }
        return plant
    }

    /// FPVGravity::ApplyGravity (UE 5.8, PVGravity.cpp) on one branch, line by line: what the stage must match.
    private func unrealGravity(_ start: [SIMD3<Float>], scales: [Float], gravity: Float, direction: SIMD3<Float>, angleCorrection: Float) -> [SIMD3<Float>] {
        var position = start
        let lo = scales.min()!, hi = scales.max()!
        var total = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var previous = position[0]
        for i in 1..<position.count {
            let pivot = position[i - 1]
            let relative = total.act(position[i] - previous)
            let tangent = normalize(relative)
            var yDot = 1 - abs(dot(tangent, direction))
            let low = max(0.1, 1 - angleCorrection)
            yDot = low + (1 - low) * min(max(yDot, 0), 1)
            let scaleGradient = (scales[i] - lo) / (hi - lo)
            let impact = (gravity / 10) * (1 - scaleGradient) * yDot
            let force = normalize(tangent + (direction - tangent) * impact)
            let down = simd_quatf(from: tangent, to: force)
            total = down * total
            previous = position[i]
            position[i] = pivot + down.act(relative)
        }
        return position
    }

    /// The Gravity stage's plant is Unreal's, at its sample tree's strength and well beyond it.
    func testGravityIsUnrealsGravity() {
        let radii: [Float] = [0.2, 0.17, 0.14, 0.1, 0.07, 0.04, 0.02, 0.01]
        for (strength, correction) in [(Float(0.329), Float(0)), (1, 0), (1, 0.6), (4, 1)] {
            let directions: [SIMD3<Float>] = [SIMD3(1, 0, 0), normalize(SIMD3(1, 2, 0.5)), normalize(SIMD3(1, -0.5, 0))]
            for along in directions {
                var plant = chain(radii, along: along)
                let start = plant.points.map(\.position)
                var g = Growth.Gravity()
                g.strength = strength
                g.angleCorrection = correction
                plant.bend(g)
                let theirs = unrealGravity(start, scales: radii, gravity: strength, direction: [0, -1, 0], angleCorrection: correction)
                for (ours, unreal) in zip(plant.points.map(\.position), theirs) {
                    XCTAssertEqual(length(ours - unreal), 0, accuracy: 2e-4, "\(strength) \(correction) \(along)")
                }
            }
        }
    }

    func testGravityBends() {
        let radii: [Float] = [0.2, 0.15, 0.1, 0.05, 0.02, 0.01]
        var plant = chain(radii)
        let start = plant.points
        var g = Growth.Gravity()
        g.strength = 1
        plant.bend(g)
        // Its foot and thickest point stay; its tip goes down; its lengths and frames go with it.
        XCTAssertEqual(plant.points[0].position, start[0].position)
        XCTAssertEqual(plant.points[1].position.y, 0, accuracy: 0.05)
        XCTAssertLessThan(plant.points.last!.position.y, -0.5)
        for i in 1..<plant.points.count {
            XCTAssertEqual(length(plant.points[i].position - plant.points[i - 1].position), 1, accuracy: 1e-4)
            let d = plant.points[i].position - plant.points[i - 1].position
            XCTAssertEqual(length(normalize(d) - plant.points[i].direction), 0, accuracy: 1e-4)
            XCTAssertEqual(dot(plant.points[i].direction, plant.points[i].lateral), 0, accuracy: 1e-4)
        }

        // No strength, or no pull: nothing moves.
        var still = chain(radii)
        g.strength = 0
        still.bend(g)
        XCTAssertEqual(still.points.map(\.position), start.map(\.position))
        g.strength = 1
        g.direction = .zero
        still.bend(g)
        XCTAssertEqual(still.points.map(\.position), start.map(\.position))

        // A pull of its own; the light's in phototropic mode (not `direction`).
        var sideways = chain(radii, along: [0, 1, 0])
        g.direction = [0, 0, 2]
        sideways.bend(g)
        XCTAssertGreaterThan(sideways.points.last!.position.z, 0.5)
        XCTAssertEqual(sideways.points.last!.position.x, 0, accuracy: 1e-3)
        var toLight = chain(radii)
        for i in toLight.points.indices { toLight.points[i].lightDirection = [0, 1, 0] }
        g.mode = .phototropic
        toLight.bend(g)
        XCTAssertGreaterThan(toLight.points.last!.position.y, 0.5)
        // ...and straight up without one.
        var unlit = chain(radii)
        for i in unlit.points.indices { unlit.points[i].lightDirection = .zero }
        unlit.bend(g)
        XCTAssertGreaterThan(unlit.points.last!.position.y, 0.5)
    }

    /// What grows on a branch goes with it, what's cut stays out of it; a twig's own "down" is its sky's opposite.
    func testGravityOnAGrownPlant() {
        var p = tree
        p.carve = nil
        var plant = Growth.Plant(p, seed: 4)
        for _ in 0..<p.cycles { plant.cycle() }
        plant.carveFoot(0.2)
        let foot = Int(plant.branches[0].points[0]), at = plant.points[foot].position
        let removed = plant.points.indices.filter { plant.points[$0].removed }
        XCTAssertFalse(removed.isEmpty)
        let before = removed.map { plant.points[$0].position }
        var g = Growth.Gravity()
        g.strength = 1
        plant.bend(g)
        XCTAssertEqual(plant.points[foot].position, at, "a carved foot stays")
        XCTAssertEqual(removed.map { plant.points[$0].position }, before)
        // A branch's foot is its parent's point: every branch is still on what it grew from.
        for branch in plant.branches where !branch.removed && branch.parent >= 0 {
            XCTAssertTrue(plant.branches[Int(branch.parent)].points.contains(branch.points[0]) || plant.points[Int(branch.points[0])].removed == false)
        }
        for point in plant.points where !point.removed && point.parent >= 0 && !plant.points[Int(point.parent)].removed {
            let d = point.position - plant.points[Int(point.parent)].position
            XCTAssertLessThan(length(d), point.segment + 1e-3)
            XCTAssertGreaterThan(dot(d, point.direction), 0)
            XCTAssertEqual(length(point.direction), 1, accuracy: 1e-3)
            XCTAssertEqual(length(point.lateral), 1, accuracy: 1e-3)
        }

        var twig = Growth.Plant(Growth.Twigs.twigGrowth, seed: 2)
        for _ in 0..<8 { twig.cycle() }
        let low = twig.points.map(\.position.z).min()!
        twig.bend(g)
        XCTAssertLessThan(twig.points.map(\.position.z).min()!, low, "down is -Z on a twig, whose sky is +Z")
    }

    func testTheSameSeedGrowsTheSamePlant() {
        let a = Growth.grow(tree, seed: 9), b = Growth.grow(tree, seed: 9), c = Growth.grow(tree, seed: 10)
        XCTAssertEqual(a.nodes, b.nodes)
        XCTAssertEqual(a.stems.count, b.stems.count)
        XCTAssertNotEqual(a.nodes, c.nodes)
    }

    func testStemsHangOnEarlierStemsAndStartOnThem() {
        let s = Growth.grow(tree, seed: 3)
        XCTAssertGreaterThan(s.stems.count, 5)
        XCTAssertEqual(s.stems[0].level, 0)
        XCTAssertEqual(s.stems[0].parent, -1)
        for (i, stem) in s.stems.enumerated().dropFirst() {
            XCTAssertGreaterThanOrEqual(stem.parent, 0)
            XCTAssertLessThan(Int(stem.parent), i)
            let parent = s.stems[Int(stem.parent)]
            XCTAssertEqual(Int(stem.level), Int(parent.level) + (stem.level == parent.level ? 0 : 1))
            // Its first node is one of its parent's.
            let foot = Foliage.xyz(s.nodes[Int(stem.first)])
            let onParent = (0..<Int(parent.count)).contains { distance(Foliage.xyz(s.nodes[Int(parent.first) + $0]), foot) < 1e-4 }
            XCTAssertTrue(onParent, "stem \(i) does not start on its parent")
            XCTAssertTrue(s.nodes[Int(stem.first)..<Int(stem.first + stem.count)].allSatisfy { $0.w > 0 && $0.w.isFinite })
        }
    }

    func testOlderPlantsAreTallerAndStopAtTheirHeight() {
        let p = tree
        let sapling = Growth.grow(Growth.aged(p, .sapling), seed: 1)
        let young = Growth.grow(Growth.aged(p, .young), seed: 1)
        let mature = Growth.grow(p, seed: 1)
        XCTAssertLessThan(height(sapling), height(young))
        XCTAssertLessThan(height(young), height(mature))
        var long = p
        long.cycles = 120
        // (The trunk's last internode may start just under the target, and the branches sag or reach a little.)
        XCTAssertLessThan(height(Growth.grow(long, seed: 1)), p.targetHeight + 2 * p.trunk.segment + 1)
    }

    func testWoodIsThickestAtTheFoot() {
        let s = Growth.grow(tree, seed: 4)
        let trunk = s.stems[0]
        let foot = s.nodes[Int(trunk.first)].w, tip = s.nodes[Int(trunk.first + trunk.count - 1)].w
        XCTAssertGreaterThan(foot, tip * 5)
        // A child is never thicker than the point it grows from.
        for stem in s.stems.dropFirst() {
            let parent = s.stems[Int(stem.parent)]
            let thickest = (0..<Int(parent.count)).map { s.nodes[Int(parent.first) + $0].w }.max()!
            XCTAssertLessThanOrEqual(s.nodes[Int(stem.first) + 1].w, thickest + 1e-5)
        }
    }

    func testDominanceKeepsBudsDormant() {
        var free = tree, dominant = tree
        free.apicalDominance = 0
        dominant.apicalDominance = 0.95
        dominant.auxinFalloff = 0.05
        XCTAssertLessThan(Growth.grow(dominant, seed: 2).stems.count, Growth.grow(free, seed: 2).stems.count)
    }

    func testOpenSkyIsLitAndACanopyShades() {
        var field = Growth.LightField(height: 8, cell: 0.4)
        var points = [Growth.Point]()
        func point(_ p: SIMD3<Float>) -> Growth.Point {
            Growth.Point(position: p, direction: [0, 1, 0], lateral: [1, 0, 0], parent: -1, branch: 0, segment: 0.4,
                         radius: 0.01, fromRoot: 0, lightDirection: [0, 1, 0])
        }
        points.append(point([0, 1, 0]))                 // under the canopy
        points.append(point([3, 1, 0]))                 // beside it, in the open
        for x in -2...2 { for z in -2...2 { points.append(point([Float(x) * 0.4, 3, Float(z) * 0.4])) } }
        field.measure(&points, Growth.Light(), up: [0, 1, 0])
        XCTAssertGreaterThan(points[1].light, 0.95)
        XCTAssertLessThan(points[0].light, 0.5)
        // The shaded bud's light leads out from under the canopy.
        XCTAssertGreaterThan(points[0].lightDirection.y, 0)
    }

    func testTheGrownOakBuildsASoundPlant() {
        let def = PlantCatalog.builtIn[.oak]
        XCTAssertNotNil(def.growth)
        let palette = (0..<def.paletteSize).map { Growth.twig(def.twigs!, variant: $0, seed: UInt64($0)) }
        let plant = Foliage.plant(.oak, age: .mature, seed: 5, palette: palette)
        XCTAssertGreaterThan(plant.height, 6)
        XCTAssertGreaterThan(plant.parts.count, 50)
        for mesh in plant.meshes { XCTAssertEqual(Foliage.problems(mesh), []) }
    }
}
