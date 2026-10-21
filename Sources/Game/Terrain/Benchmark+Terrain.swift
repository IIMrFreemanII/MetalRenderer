import EngineCore
import Foundation
import Plants
import simd
import MetalRenderer

/// The Terrain Editor's benchmark modes: the workshop's terrains, every brush on them, the same edit in every scene
/// whose ground is a terrain, undo, and how long sculpting takes a frame.
extension Benchmark {
    static let terrainModes: [String: () -> [Config]] = [
        "terrain": terrainWorkshop, "terrainsculpt": terrainSculpt, "terrainedit": terrainEdit, "terrainundo": terrainUndo,
        "terrainperf": terrainPerf, "terrainpaint": terrainPaint, "terrainerode": terrainErode, "terrainwater": terrainWater, "terrainscatter": terrainScatter, "terrainphysics": terrainPhysics,
    ]

    /// The workshop's camera for a terrain `size` across: from the south-west, looking at the middle.
    private static func terrainCamera(_ size: Float, at: SIMD3<Float> = .zero, distance: Float? = nil) -> Camera {
        let d = distance ?? size * 0.32
        let eye = at + SIMD3(-d * 0.7, d * 0.45, d * 0.7)
        let n = simd_normalize(at - eye)
        return Scene.camera(eye, yaw: atan2(n.x, -n.z), pitch: asin(n.y))
    }

    private static func workshop(_ name: String, size: TerrainWorkshopSettings.Size = .km1, base: TerrainWorkshopSettings.Base = .hills,
                                 seed: Int = 1) -> Config {
        var s = SceneSettings(kind: .terrain)
        s.terrainWorkshop = TerrainWorkshopSettings(size: size, base: base, seed: seed, document: "bench-\(name)", sea: false)
        return Config(name, scale: 0.75, gi: .pathTraced, scene: s).still(at: 2)
    }

    /// The workshop's terrains as they start.
    private static func terrainWorkshop() -> [Config] {
        [workshop("flat-1km", base: .flat), workshop("hills-1km"), workshop("hills-512m", size: .m512, seed: 3), workshop("hills-4km", size: .km4, seed: 2)]
            .map { c in var c = c; c.camera = terrainCamera(Float(c.settings.scene.terrainWorkshop.size.metres)); return c }
    }

    /// A stroke across the world's x, z from `a` to `b`, through `count` points.
    private static func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, count: Int = 12) -> [SIMD2<Double>] {
        (0..<count).map { a + (b - a) * Double($0) / Double(count - 1) }
    }
    /// A circle of the world's x, z.
    private static func circle(_ c: SIMD2<Double>, _ r: Double, count: Int = 24) -> [SIMD2<Double>] {
        (0...count).map { c + SIMD2(cos(Double($0) / Double(count) * 2 * .pi), sin(Double($0) / Double(count) * 2 * .pi)) * r }
    }

    /// Every brush on the workshop's terrain, each in a document of its own, looked at from close.
    private static func terrainSculpt() -> [Config] {
        func brush(_ tool: TerrainTool, radius: Float = 30, strength: Float = 0.6, _ change: (inout TerrainBrush) -> Void = { _ in }) -> TerrainBrush {
            var b = TerrainBrush(tool: tool, radius: radius, strength: strength)
            change(&b)
            return b
        }
        let cases: [(String, TerrainWorkshopSettings.Base, [TerrainStep])] = [
            ("raise", .flat, [.mode(true), .brush(brush(.raise)), .strokeWorld(circle(.zero, 60)), .strokeWorld(circle(.zero, 60)),
                              .strokeWorld(line([-40, 0], [40, 0]))]),
            ("lower", .hills, [.mode(true), .brush(brush(.lower, radius: 25, strength: 1)), .strokeWorld(line([-100, -20], [100, 20])),
                               .strokeWorld(line([-100, -20], [100, 20]))]),
            ("smooth", .hills, [.mode(true), .brush(brush(.smooth, radius: 80, strength: 1)), .strokeWorld(circle(.zero, 40)),
                                .strokeWorld(circle(.zero, 40)), .strokeWorld(circle(.zero, 40))]),
            ("flatten", .hills, [.mode(true), .brush(brush(.flatten, radius: 50, strength: 1)), .strokeWorld(circle(.zero, 30)),
                                 .strokeWorld(circle(.zero, 30))]),
            ("ramp", .flat, [.mode(true), .brush(brush(.raise, radius: 60, strength: 1)), .strokeWorld(circle([60, 0], 20)),
                             .strokeWorld(circle([60, 0], 20)), .strokeWorld(circle([60, 0], 20)),
                             .brush(brush(.ramp, radius: 8, strength: 1)), .strokeWorld(line([-120, 60], [60, 0]))]),
            ("noise", .flat, [.mode(true), .brush(brush(.noise, radius: 90, strength: 1) { $0.noiseScale = 25 }), .strokeWorld(circle(.zero, 30)),
                              .strokeWorld(circle(.zero, 30))]),
            ("terrace", .hills, [.mode(true), .brush(brush(.terrace, radius: 90, strength: 1) { $0.terraceStep = 3 }),
                                 .strokeWorld(circle(.zero, 30)), .strokeWorld(circle(.zero, 30))]),
        ]
        return cases.map { name, base, steps in
            var c = workshop(name, base: base)
            c.camera = terrainCamera(1024, distance: 260)
            c.events = [(0, .terrain(steps + [.wait(8)]))]
            return c
        }
    }

    /// The same edit in every scene whose ground is a terrain: a ridge raised across the lower middle of the view, then a
    /// ramp; with `METALRENDERER_TERRAINS=none` from the scenes' own ground.
    private static func terrainEdit() -> [Config] {
        let steps: [TerrainStep] = [
            .mode(true), .brush(TerrainBrush(tool: .raise, radius: 6, strength: 0.8)),
            .stroke([[0.3, 0.75], [0.4, 0.73], [0.5, 0.72], [0.6, 0.73], [0.7, 0.75]]),
            .stroke([[0.3, 0.75], [0.4, 0.73], [0.5, 0.72], [0.6, 0.73], [0.7, 0.75]]),
            .brush(TerrainBrush(tool: .ramp, radius: 2, strength: 1)), .stroke([[0.45, 0.9], [0.5, 0.8]]),
            .wait(8),
        ]
        return [SceneKind.forest, .mireland, .valley, .city, .world, .terrain].map { kind in
            var c = Config(kind.envName, scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: kind)).still(at: 2)
            if kind == .terrain { c.settings.scene.terrainWorkshop.document = "bench-edit" }
            c.events = [(0, .terrain(steps))]
            return c
        }
    }

    /// A stroke, then undone: the picture as the untouched one; redone: as the stroke left it.
    private static func terrainUndo() -> [Config] {
        let raise: [TerrainStep] = [.mode(true), .brush(TerrainBrush(tool: .raise, radius: 40, strength: 1)), .strokeWorld(circle(.zero, 50)),
                                    .strokeWorld(circle(.zero, 50))]
        func c(_ name: String, _ steps: [TerrainStep]) -> Config {
            var c = workshop(name, base: .hills)
            c.settings.scene.terrainWorkshop.document = "bench-undo-\(name)"
            c.camera = terrainCamera(1024, distance: 300)
            c.events = [(0, .terrain(steps + [.wait(8), .mode(false)]))]   // (no ring in the picture)
            return c
        }
        return [c("untouched", []), c("stroke", raise), c("undone", raise + [.wait(2), .undo]), c("redone", raise + [.wait(2), .undo, .wait(2), .redo])]
    }

    /// The paint brush: layers painted in the workshop (sand across, gravel in a ring, then erased in part), in the Forest
    /// (mud along the view) and the open world (rock and gravel in the field before the camera).
    private static func terrainPaint() -> [Config] {
        func paint(_ layer: Int, radius: Float, strength: Float = 0.8) -> TerrainStep {
            .brush(TerrainBrush(tool: .paint, radius: radius, strength: strength, layer: layer))
        }
        var workshop = workshop("workshop", base: .hills)
        workshop.settings.scene.terrainWorkshop.document = "bench-paint"
        workshop.camera = terrainCamera(1024, distance: 260)
        workshop.events = [(0, .terrain([
            .mode(true), paint(4, radius: 20), .strokeWorld(line([-150, 40], [150, -40], count: 40)),
            paint(6, radius: 15), .strokeWorld(circle([0, 0], 60, count: 40)),
            .brush(TerrainBrush(tool: .erase, radius: 25, strength: 1)), .strokeWorld(line([-20, -80], [20, 80], count: 20)),
            .wait(8), .mode(false),
        ]))]
        let view: [TerrainStep] = [
            .mode(true), paint(5, radius: 3), .stroke([[0.25, 0.8], [0.4, 0.75], [0.6, 0.75], [0.75, 0.8]]),
            paint(6, radius: 2), .stroke([[0.45, 0.9], [0.5, 0.85], [0.55, 0.9]]), .wait(8), .mode(false),
        ]
        let scenes = [SceneKind.forest, .world].map { kind -> Config in
            var c = Config(kind.envName, scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: kind)).still(at: 2)
            c.events = [(0, .terrain(view))]
            return c
        }
        return [workshop] + scenes
    }

    /// The generator and erosion on the workshop's 512 m terrain: the generator's mountains, then eroded by water, by
    /// crumbling, by both; the erosion brush and the generator stamp on level ground.
    private static func terrainErode() -> [Config] {
        var mountains = GeneratorStack()
        mountains.nodes = [GeneratorNode(kind: .ridged, blend: .add, amplitude: 90, scale: 260, octaves: 6, seed: 3),
                           GeneratorNode(kind: .fbm, blend: .add, amplitude: 20, scale: 120, octaves: 5, seed: 4)]
        var erosion = ErosionSettings()
        erosion.hydraulicIterations = 300
        erosion.thermalIterations = 60
        func c(_ name: String, _ steps: [TerrainStep]) -> Config {
            var c = workshop(name, size: .m512, base: .flat)
            c.settings.scene.terrainWorkshop.document = "bench-erode-\(name)"
            c.camera = terrainCamera(512, distance: 300)
            c.events = [(0, .terrain(steps + [.wait(30)]))]
            return c
        }
        let generated: [TerrainStep] = [.generate(mountains), .wait(2)]
        return [c("generated", generated), c("water", generated + [.erode(.hydraulic, erosion)]),
                c("crumbling", generated + [.erode(.thermal, erosion)]), c("both", generated + [.erode(.both, erosion)]),
                c("brushes", [.mode(true), .document { $0.generator = mountains },
                              .brush(TerrainBrush(tool: .stamp, radius: 60, strength: 1)), .strokeWorld(circle([-60, 0], 30)),
                              .strokeWorld(circle([-60, 0], 30)), .strokeWorld(circle([-60, 0], 30)),
                              .brush(TerrainBrush(tool: .erode, radius: 40, strength: 1)), .strokeWorld(line([-120, 0], [0, 0], count: 30)),
                              .wait(4), .mode(false)])]
    }

    /// Water on the workshop's level ground: a basin dug and a lake in it, a river's bed carved along a line and its
    /// ribbon, a sea under a hill's foot.
    private static func terrainWater() -> [Config] {
        var c = workshop("water", size: .m512, base: .flat)
        c.settings.scene.terrainWorkshop.document = "bench-water"
        c.camera = terrainCamera(512, distance: 260)
        let river = WaterBody(name: "River", kind: .river, points: line([-200, -150], [60, 120], count: 30), width: 12, depth: 2.5)
        c.events = [(0, .terrain([
            .mode(true), .brush(TerrainBrush(tool: .lower, radius: 35, strength: 1)), .strokeWorld(circle([80, -60], 20)),
            .strokeWorld(circle([80, -60], 20)), .strokeWorld(circle([80, -60], 20)),
            .brush(TerrainBrush(tool: .raise, radius: 60, strength: 1)), .strokeWorld(circle([-120, 120], 30)), .strokeWorld(circle([-120, 120], 30)),
            .document { $0.water = [river, WaterBody(name: "Lake", kind: .lake, level: -1, seed: [80, -60])] },
            .carveRiver(0), .wait(4), .mode(false), .rebuild, .wait(40),
        ]))]
        return [c]
    }

    /// Scatter rules on the workshop's hills: rocks on the steep ground, oaks and birches low down, ferns where the
    /// grass layer is (painted across), a few houses on level ground; then a ridge raised through them (re-scattered),
    /// and the check that what shows stands on the ground.
    private static func terrainScatter() -> [Config] {
        var c = workshop("scatter", size: .m512, base: .hills, seed: 5)
        c.settings.scene.terrainWorkshop.document = "bench-scatter"
        c.camera = terrainCamera(512, distance: 200)
        let rules = [
            ScatterRule(name: "Rocks", source: .rock(roughness: 0.6), density: 80, spacing: 3, slopeMin: 12, slopeMax: 70, sizeMin: 0.5, sizeMax: 2,
                        sink: 0.25, seed: 11),
            ScatterRule(name: "Oaks", source: .plant(species: "oak"), density: 25, spacing: 8, slopeMax: 24, patchScale: 90, patchCover: 0.6,
                        seed: 12),
            ScatterRule(name: "Birches", source: .plant(species: "birch"), density: 15, spacing: 8, slopeMax: 28, seed: 13),
            ScatterRule(name: "Ferns", source: .plant(species: "fern"), density: 600, spacing: 1.5, layer: 4, layerThreshold: 0.4, seed: 14),
            ScatterRule(name: "Houses", source: .building(style: "oldtown"), density: 1.5, spacing: 40, slopeMax: 12, sink: 0.4, seed: 15),
        ]
        c.events = [(0, .terrain([
            .mode(true), .brush(TerrainBrush(tool: .paint, radius: 25, strength: 1, layer: 4)), .strokeWorld(line([-200, 40], [200, 60], count: 30)),
            .document { $0.scatter = rules }, .rebuild, .wait(40), .checkScatter,
            .brush(TerrainBrush(tool: .raise, radius: 40, strength: 1)), .strokeWorld(line([-150, -40], [150, -20], count: 30)),
            .strokeWorld(line([-150, -40], [150, -20], count: 30)), .wait(6), .checkScatter, .mode(false), .wait(4),
        ]))]
        return [c]
    }

    /// Bodies dropped onto the workshop's hills (the terrain's heightfield colliders): where they come to rest, then a
    /// mound raised under some of them (they are pushed up with the ground) — the check prints how far they are from it.
    private static func terrainPhysics() -> [Config] {
        var c = workshop("bodies", size: .m512, base: .hills, seed: 7).moving()
        c.settings.scene.terrainWorkshop.bodies = 64
        c.settings.scene.terrainWorkshop.document = "bench-physics"
        c.camera = terrainCamera(512, at: [0, 0, 0], distance: 60)
        c.frames = 600
        c.events = [(0, .terrain([.wait(300), .checkBodies, .mode(true), .brush(TerrainBrush(tool: .raise, radius: 10, strength: 1)),
                                  .strokeWorld(circle([0, 0], 6)), .strokeWorld(circle([0, 0], 6)), .mode(false), .wait(200), .checkBodies]))]
        return [c]
    }

    /// Sculpting's cost: a long stroke over the workshop's terrain and the open world's, frame after frame, the camera
    /// still (the frames' times are the table's).
    private static func terrainPerf() -> [Config] {
        let long: [TerrainStep] = [.mode(true), .brush(TerrainBrush(tool: .raise, radius: 20, strength: 0.3))]
            + (0..<60).map { k in .stroke([[0.3 + Float(k) * 0.006, 0.7], [0.32 + Float(k) * 0.006, 0.7]]) }
        var workshop = workshop("workshop", base: .hills)
        workshop.camera = terrainCamera(1024, distance: 260)
        workshop = workshop.moving()
        workshop.settings.paused = true
        workshop.events = [(0, .terrain(long))]
        var world = Config("world", scale: 0.75, gi: .pathTraced, scene: SceneSettings(kind: .world)).still(at: 2)
        world.settings.paused = true
        world.events = [(0, .terrain(long))]
        return [workshop, world]
    }
}
