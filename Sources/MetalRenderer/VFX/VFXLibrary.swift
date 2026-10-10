import Foundation
import simd

/// The built-in effects, as graphs (each a function of where a scene puts it: written in the scene's own space and
/// placed where it is, so its numbers are the scene's own, bit for bit). Each emitter keeps the seed it had as an
/// emitter of the scene before effects were graphs (its place in the scene's list then), so the scenes look as they did.
/// A saved effect of the same name replaces one in every scene (VFXStore).
enum VFXLibrary {
    // MARK: - The particles scene (Scene+Particles.swift)

    /// A fire in a brazier's bowl: flames, the smoke over them, and the heat haze, both carried up the fire's hot air.
    static func campfire(fire: SIMD3<Float>) -> VFXEffect {
        VFXEffect("campfire", origin: fire, emitters: [
            VFXEmitter("flames", capacity: 200, seed: 0,
                       spawn: [.rate(180)],
                       initialize: [.shape("disc", at: fire + SIMD3(0, 0.02, 0), radius: 0.22), .velocity(speed: 0.3...0.7, spread: 0.25),
                                    .lifetime(0.35...0.7)],
                       update: [.gravity(-0.6), .drag(1.5, wind: 0.3), .curl(2, frequency: 2.5, speed: 1.5, baked: true)],
                       output: [.billboard(), .size(0.34, 0.14, jitter: 0.3),
                                .color(VFXGradient([1, 0.8, 0.5, 0.2], [1, 0.6, 0.3, 0.15], [0.8, 0.25, 0.08, 0], midpoint: 0.3), emission: 1.4),
                                .flipbook(.flame, frames: 64, fps: 40, random: true), .orient("axis", axis: [0, 1, 0]),
                                .lighting(soft: 0.15, shadows: false)]),
            VFXEmitter("smoke", capacity: 300, seed: 1,
                       spawn: [.rate(30)],
                       initialize: [.shape("disc", at: fire + SIMD3(0, 0.55, 0), radius: 0.2), .velocity(speed: 0.3...0.6, spread: 0.2),
                                    .lifetime(4...6.5)],
                       update: [.gravity(-0.08), .drag(0.5, wind: 1), .curl(0.6, frequency: 0.8, speed: 0.3, baked: true),
                                .field("hot air", strength: 1)],   // carried up the fire's hot air (ParticleField.plume)
                       output: [.billboard(), .size(0.22, 0.9, jitter: 0.3),
                                .color(VFXGradient([0.8, 0.78, 0.75, 0.0], [0.85, 0.84, 0.82, 0.75], [0.9, 0.9, 0.9, 0], midpoint: 0.15)),
                                .flipbook(.smoke, frames: 64, random: true), .orient("ray facing", spin: 0.4),
                                .lighting(soft: 0.4, shadowDensity: 0.12)]),
            // The hot air over the fire: never drawn, it bends the view through it, strongest just over the flames.
            VFXEmitter("heat", capacity: 48, seed: 10,
                       spawn: [.rate(30)],
                       initialize: [.shape("disc", at: fire + SIMD3(0, 0.25, 0), radius: 0.2), .velocity(speed: 0.6...1.0, spread: 0.2),
                                    .lifetime(0.8...1.3)],
                       update: [.gravity(-0.4), .drag(1), .curl(1.5, frequency: 2, speed: 1, baked: true),
                                .field("hot air", strength: 0.6)],
                       output: [.distortion(0.0025), .size(0.3, 0.6, jitter: 0.2),
                                .color(VFXGradient([1, 1, 1, 0], [1, 1, 1, 1], [1, 1, 1, 0], midpoint: 0.25))]),
        ], fields: [
            VFXField(name: "hot air", kind: .plume, center: fire + SIMD3(0, 0.01, 0), radius: 0.3, height: 2.8, lift: 1.4),
        ])
    }

    /// Sparks off a grinder's wheel where a bar is pressed on its rim (`contact`, `out` the rim's outward there):
    /// along the rim's way, bouncing off the floor, the crate and the scene; a puff of smoke where each dies; a glow
    /// of hot points at the contact.
    static func grinder(contact: SIMD3<Float>, out: SIMD3<Float>) -> VFXEffect {
        VFXEffect("grinder", origin: contact, emitters: [
            VFXEmitter("sparks", capacity: 1200, seed: 2,
                       spawn: [.rate(260), .burst(at: 2, count: 300, every: 3)],
                       initialize: [.shape("point", at: contact + out * 0.01,
                                           axis: normalize(SIMD3<Float>(-out.y, out.x, 0) + out * 0.15 + SIMD3(0, 0, 0.15))),
                                    .velocity(speed: 3...6, spread: 0.22), .lifetime(0.7...1.5)],
                       update: [.gravity(1), .drag(0.3), .collide(["floor", "crate"], scene: true, restitution: 0.45, friction: 0.25)],
                       output: [.billboard(), .size(0.012, 0.006),
                                .color(VFXGradient([1, 0.85, 0.5, 1], [1, 0.55, 0.15, 1], [0.9, 0.2, 0.05, 1]), emission: 40),
                                .flipbook(.spark), .orient("velocity", stretch: 0.025), .lighting(soft: 0.02, shadows: false)]),
            VFXEmitter("spark smoke", capacity: 900, seed: 3,
                       spawn: [.event("sparks")],
                       initialize: [.velocity(inherit: 0.15), .lifetime(0.8...1.4)],
                       update: [.gravity(-0.05), .drag(1.5, wind: 1)],
                       output: [.billboard(), .size(0.03, 0.12),
                                .color(VFXGradient([0.85, 0.82, 0.78, 0.35], [0.85, 0.85, 0.85, 0.2], [0.85, 0.85, 0.85, 0])),
                                .flipbook(.smoke, frames: 64, random: true), .lighting(soft: 0.05, shadows: false)]),
            // Hot points that flare and go, many at once. (No light there: a fifth would take the particles scene to
            // the many-lights path, whose light pass leaves lit particles only the sky's.)
            VFXEmitter("grind glow", capacity: 16, seed: 11,
                       spawn: [.rate(90)],
                       initialize: [.shape("sphere", at: contact + out * 0.005 + SIMD3(0, 0, 0.02), radius: 0.008), .lifetime(0.05...0.12)],
                       output: [.billboard(), .size(0.06, 0.03, jitter: 0.4),
                                .color(VFXGradient([1, 0.9, 0.7, 1], [1, 0.65, 0.3, 0.8], [1, 0.4, 0.1, 0]), emission: 60),
                                .flipbook(.dot), .lighting(soft: 0.01, shadows: false)]),
        ])
    }

    /// Magic motes swirling in curl noise round a point, and wisps among them with glowing ribbons behind.
    static func magic(at center: SIMD3<Float>) -> VFXEffect {
        let update: [VFXBlock] = [.drag(0.4), .curl(1.2, frequency: 1.6, speed: 0.5), .vortex(swirl: 1.6, attraction: 0.6)]
        return VFXEffect("magic", origin: center, emitters: [
            VFXEmitter("magic", capacity: 1000, seed: 4,
                       spawn: [.rate(220)],
                       initialize: [.shape("sphere", at: center, radius: 0.5), .velocity(speed: 0.05...0.2, radial: true), .lifetime(2...3.5)],
                       update: update,
                       output: [.billboard(), .size(0.025, 0.01, jitter: 0.5),
                                .color(VFXGradient([0.4, 0.7, 1, 0], [0.5, 0.8, 1, 1], [0.8, 0.5, 1, 0], midpoint: 0.2), emission: 5),
                                .flipbook(.dot), .lighting(shadows: false)]),
            VFXEmitter("wisps", capacity: 90, seed: 9,
                       spawn: [.rate(24)],
                       initialize: [.shape("sphere", at: center, radius: 0.5), .velocity(speed: 0.3...0.6, radial: true), .lifetime(2.5...3.5)],
                       update: update,
                       output: [.trail(points: 16, every: 2, width: 0.8), .size(0.018, 0.01, jitter: 0.2),
                                .color(VFXGradient([0.3, 0.9, 1, 0], [0.5, 0.85, 1, 1], [0.9, 0.4, 1, 0], midpoint: 0.2), emission: 10),
                                .flipbook(.dot), .lighting(shadows: false)]),
        ])
    }

    /// Rain from a box (`center`, `half` its half extents), dying where it lands, and the rings it splashes there.
    static func rain(center: SIMD3<Float>, half: SIMD3<Float>) -> VFXEffect {
        VFXEffect("rain", origin: center, emitters: [
            VFXEmitter("rain", capacity: 2000, seed: 5,
                       spawn: [.rate(900)],
                       initialize: [.shape("box", at: center, halfExtents: half), .velocity(add: [0.4, -7, 0]), .lifetime(2...2)],
                       update: [.gravity(0.4), .collide(["floor"], scene: true, kill: true)],
                       output: [.billboard(), .size(0.009, 0.009),
                                .color(VFXGradient([0.9, 0.95, 1, 0.5], [0.9, 0.95, 1, 0.5], [0.9, 0.95, 1, 0.5])),
                                .flipbook(.streak), .orient("velocity", stretch: 0.03), .lighting(soft: 0, shadows: false)]),
            VFXEmitter("splashes", capacity: 640, seed: 6,
                       spawn: [.event("rain", on: "collision")],
                       initialize: [.lifetime(0.35...0.5)],
                       output: [.billboard(), .size(0.1, 0.18),
                                .color(VFXGradient([0.9, 0.95, 1, 0.8], [0.9, 0.95, 1, 0.5], [0.9, 0.95, 1, 0])),
                                .flipbook(.ring, frames: 64), .orient("world", axis: [0, 1, 0]), .lighting(soft: 0, shadows: false)]),
        ])
    }

    /// A burst of stone chunks every 2.5 s (mesh particles: the scene binds "rock" and "stone"), thrown up from a spot
    /// on the floor, tumbling and bouncing; dust where they land, in the little whirl they stir.
    static func rubble(at: SIMD3<Float>) -> VFXEffect {
        VFXEffect("rubble", origin: at, emitters: [
            VFXEmitter("rubble", capacity: 120, seed: 7,
                       spawn: [.burst(at: 0.5, count: 36, every: 2.5)],
                       initialize: [.shape("disc", at: at, axis: normalize(SIMD3<Float>(0.3, 1, -0.15)), radius: 0.15),
                                    .velocity(speed: 2.5...4.5, spread: 0.45), .lifetime(3...3.5)],
                       update: [.gravity(1), .collide(["floor", "crate", "bowl", "stand", "plinth"], scene: true, restitution: 0.3,
                                                      friction: 0.35, radius: 0.035)],
                       output: [.mesh("rock", material: "stone"), .size(0.05, 0.05, jitter: 0.5), .orient("ray facing", spin: 9)]),
            // (A puff an impact, few and small: crowded near the floor, every ray through them meets them all.)
            VFXEmitter("dust", capacity: 160, seed: 8,
                       spawn: [.event("rubble", on: "collision")],
                       initialize: [.velocity(speed: 0.2...0.5, spread: 1.2, inherit: 0.1), .lifetime(0.6...1.1)],
                       update: [.gravity(-0.02), .drag(2), .field("whirl", strength: 1.5, follow: true)],
                       output: [.billboard(), .size(0.03, 0.16, jitter: 0.3),
                                .color(VFXGradient([0.6, 0.55, 0.48, 0.4], [0.6, 0.56, 0.5, 0.25], [0.6, 0.57, 0.52, 0], midpoint: 0.2)),
                                .flipbook(.smoke, frames: 64, random: true), .orient("ray facing", spin: 0.6),
                                .lighting(soft: 0.05, shadows: false)]),
        ], fields: [
            VFXField(name: "whirl", kind: .vortex, center: at, radius: 0.7, height: 1.6, swirl: 1.2, lift: 0.6),
        ])
    }

    // MARK: - Graphs (generated code: VFXProgram)

    /// Fireworks: rockets that climb on a trail and, near the top of their climb, burst into stars, each burst a
    /// colour of its own. All in the graph: the burst is a Trigger Event while the rocket slows past 1.5 m/s up (the
    /// stars its children on that condition), the rocket dies as it starts to fall (a Kill), and a star's colour is
    /// its rocket's (its spawn id over 8 is its parent's, through the golden ratio into a rainbow), dimming as it
    /// burns out.
    static func fireworks(at: SIMD3<Float>) -> VFXEffect {
        let rainbow = VFXGradient([.init(0, [1, 0.25, 0.2, 1]), .init(0.17, [1, 0.6, 0.1, 1]), .init(0.33, [1, 0.95, 0.3, 1]),
                                   .init(0.5, [0.3, 1, 0.35, 1]), .init(0.67, [0.25, 0.8, 1, 1]), .init(0.83, [0.55, 0.35, 1, 1]),
                                   .init(1, [1, 0.25, 0.2, 1])])
        return VFXEffect("fireworks", origin: at, emitters: [
            VFXEmitter("rockets", capacity: 24,
                       spawn: [.rate(1.2)],
                       initialize: [.shape("disc", at: at, radius: 0.8), .velocity(speed: 8.5...10, spread: 0.12), .lifetime(4...4)],
                       update: [.gravity(1), .kill(id: "apex"), .trigger(id: "burst")],
                       output: [.trail(points: 16, every: 2, width: 0.6), .size(0.025, 0.025),
                                .color(VFXGradient([1, 0.8, 0.5, 1], [1, 0.7, 0.4, 1], [1, 0.6, 0.3, 1]), emission: 30),
                                .flipbook(.spark), .orient("velocity", stretch: 0.04), .lighting(soft: 0.02, shadows: false)]),
            VFXEmitter("stars", capacity: 1600,
                       spawn: [.event("rockets", on: "condition", count: 8)],
                       initialize: [.velocity(speed: 4...6, spread: 3.1416, inherit: 0.3), .lifetime(1.4...2.2)],
                       update: [.gravity(0.35), .drag(0.7)],
                       output: [.billboard(), .size(curve: VFXCurve([[0, 0.05], [0.15, 0.035], [1, 0]]), jitter: 0.3),
                                .color(rainbow, emission: 6, id: "starColor"), .flipbook(.dot), .lighting(soft: 0.02, shadows: false)]),
        ], nodes: [
            VFXNode(.velocity, id: "v", at: [-760, 0]),
            VFXNode(.splitVector, id: "vy", at: [-560, 0]),
            VFXNode(.compare, ["b": .float(0), "op": .choice("<")], id: "falling", at: [-360, -40]),
            VFXNode(.compare, ["b": .float(1.5), "op": .choice("<")], id: "slowing", at: [-360, 60]),
            VFXNode(.particleID, id: "id", at: [-1160, 300]),
            VFXNode(.divide, ["b": .float(8)], id: "perRocket", at: [-960, 300]),
            VFXNode(.floor, id: "rocket", at: [-760, 300]),
            VFXNode(.multiply, ["b": .float(0.618034)], id: "golden", at: [-560, 300]),
            VFXNode(.fract, id: "hue", at: [-360, 300]),
            VFXNode(.gradient, ["gradient": .gradient(rainbow)], id: "rainbow", at: [-160, 300]),
            VFXNode(.ageOverLife, id: "t", at: [-360, 420]),
            VFXNode(.curve, ["curve": .curve(VFXCurve([[0, 1], [0.6, 0.8], [1, 0.2]]))], id: "burnOut", at: [-160, 420]),
            VFXNode(.multiply, id: "lit", at: [40, 360]),
        ], links: [
            VFXLink("v", to: "vy", "v"), VFXLink("vy", "y", to: "falling", "a"), VFXLink("vy", "y", to: "slowing", "a"),
            VFXLink("falling", to: "apex", "when"), VFXLink("slowing", to: "burst", "when"),
            VFXLink("id", to: "perRocket", "a"), VFXLink("perRocket", to: "rocket", "a"), VFXLink("rocket", to: "golden", "a"),
            VFXLink("golden", to: "hue", "a"), VFXLink("hue", to: "rainbow", "t"),
            VFXLink("t", to: "burnOut", "t"), VFXLink("rainbow", to: "lit", "a"), VFXLink("burnOut", to: "lit", "b"),
            VFXLink("lit", to: "starColor", "color"),
        ])
    }

    // MARK: - By name (the VFX stage's, the editor's)

    static let names = ["campfire", "grinder", "magic", "rain", "rubble", "fireworks", "embers", "bubbles", "dust", "runes"]

    /// A built-in effect, made about the origin (its `origin` there, at its own height).
    static func named(_ name: String) -> VFXEffect? {
        switch name {
        case "campfire": return campfire(fire: [0, 0.95, 0])
        case "grinder": return grinder(contact: [0, 1.2, 0], out: [cos(Scene.degrees(66)), sin(Scene.degrees(66)), 0])
        case "magic": return magic(at: [0, 1.1, 0])
        case "rain": return rain(center: [0, 6.5, 0], half: [1.6, 0, 2.2])
        case "rubble": return rubble(at: [0, 0.05, 0])
        case "fireworks": return fireworks(at: [0, 0.1, 0])
        case "embers": return embers(at: [0, 0.4, 0])
        case "bubbles": return bubbles(radius: 2)
        case "dust": return dust(at: [0, 1.5, 0], half: [3, 1.5, 2.75])
        case "runes": return runes(height: 0.6, radius: 1.2, speed: 0.36, color: [0.4, 0.8, 1])
        default: return nil
        }
    }

    // MARK: - The showcase's (Scene+Showcase.swift: what drifts in the air round a model; none casts a shadow)

    /// Embers rising from a pit's box (`at`), swaying in curl noise, shrinking as they cool.
    static func embers(at: SIMD3<Float>) -> VFXEffect {
        VFXEffect("embers", origin: at, emitters: [
            VFXEmitter("embers", capacity: 600, seed: 0,
                       spawn: [.rate(30)],
                       initialize: [.shape("box", at: at, halfExtents: [0.6, 0, 0.6]), .velocity(speed: 0.35...0.9, spread: 0.3),
                                    .lifetime(4...7)],
                       update: [.gravity(-0.06), .drag(0.3), .curl(0.8, frequency: 0.9, speed: 0.3)],
                       output: [.billboard(), .size(0.016, 0.005, jitter: 0.5),
                                .color(VFXGradient([1, 0.5, 0.15, 1], [1, 0.42, 0.1, 1], [0.8, 0.2, 0.05, 1]), emission: 30),
                                .flipbook(.spark), .orient("velocity", stretch: 0.03), .lighting(soft: 0.05, shadows: false)]),
        ])
    }

    /// Bubbles from a sea floor's disc of `radius`, up and wobbling.
    static func bubbles(radius: Float) -> VFXEffect {
        VFXEffect("bubbles", emitters: [
            VFXEmitter("bubbles", capacity: 800, seed: 0,
                       spawn: [.rate(12)],
                       initialize: [.shape("disc", radius: radius), .velocity(speed: 0.4...1), .lifetime(8...20)],
                       update: [.gravity(-0.12), .drag(1), .curl(1.5, frequency: 4, speed: 1)],
                       output: [.billboard(), .size(0.03, 0.045, jitter: 0.5),
                                .color(VFXGradient([0.6, 0.9, 1, 1], [0.6, 0.9, 1, 1], [0.6, 0.9, 1, 1]), emission: 0.6),
                                .flipbook(.bubble), .lighting(soft: 0.05, shadows: false)]),
        ])
    }

    /// Motes drifting in a box (`at`, `half`), lit by what lights them.
    static func dust(at: SIMD3<Float>, half: SIMD3<Float>) -> VFXEffect {
        VFXEffect("dust", origin: at, emitters: [
            VFXEmitter("dust", capacity: 1500, seed: 0,
                       spawn: [.rate(120)],
                       initialize: [.shape("box", at: at, halfExtents: half), .velocity(speed: 0.01...0.05, spread: .pi), .lifetime(10...14)],
                       update: [.drag(0.4), .curl(0.12, frequency: 0.6, speed: 0.1)],
                       output: [.billboard(), .size(0.012, 0.012, jitter: 0.5),
                                .color(VFXGradient([1, 1, 1, 0], [1, 1, 1, 1], [1, 1, 1, 0], midpoint: 0.3)),
                                .flipbook(.dot), .lighting(soft: 0.05, shadows: false)]),
        ])
    }

    /// Glowing tablets circling at `height` on a circle of `radius` at `speed`: held on it by the vortex against the
    /// drag, turned by the pull toward the centre (v^2 / r); each keeps its glyph.
    static func runes(height: Float, radius: Float, speed: Float, color: SIMD3<Float>) -> VFXEffect {
        let c = SIMD4(color, 1)
        return VFXEffect("runes", origin: [0, height, 0], emitters: [
            VFXEmitter("runes", capacity: 12, seed: 0,
                       spawn: [.burst(at: 0, count: 12)],
                       initialize: [.shape("ring", at: [0, height, 0], radius: radius), .lifetime(1e6...1e6)],
                       update: [.drag(1), .vortex(swirl: speed, attraction: speed * speed / radius),
                                .curl(0.04, frequency: 1, speed: 0.2)],
                       output: [.billboard(), .size(0.07, 0.07), .color(VFXGradient(c, c, c), emission: 3),
                                .flipbook(.rune, frames: ParticleTextures.frames, fps: 0.0001, random: true, blend: false),
                                .orient("axis", axis: [0, 1, 0]), .lighting(soft: 0.05, shadows: false)]),
        ])
    }
}
