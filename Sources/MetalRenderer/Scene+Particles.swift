import Foundation
import simd

/// The particles scene (Particles.swift): GPU particle effects, ray traced, in a dark studio with a glossy floor that
/// mirrors them. A brazier's fire (flames, a flickering light inside) and the smoke above it; a grinder's wheel
/// throwing sparks off its rim where a steel bar is pressed on it, that bounce off the floor, the crate (analytic colliders) and whatever else they meet (a ray a step), and
/// leave puffs of smoke where they die; a swirl of magic motes in curl noise round a plinth; rain falling on the
/// right under a lamp in the ceiling, lit along its fall and splashing in the pool of light where it lands; and bursts of rubble on the left, stone chunks (mesh particles: real geometry)
/// that tumble, bounce and kick up dust. Over the fire, heat haze bends the view (distortion particles).
extension Scene {
    /// Each emitter's pool is its budget (Particles.swift): about its rate x its longest life (and its bursts), with
    /// room to spare. The structures are built over the whole pool every frame.
    func buildParticles() {
        let kit = Kit(self)
        skyColor = [0.01, 0.012, 0.018]
        let floor = addPBRMaterial(baseColor: [0.08, 0.08, 0.09], metallic: 0, roughness: 0.18)
        let wall = addMaterial(albedo: [0.45, 0.45, 0.47])
        kit.room(width: 16, height: 7, depth: 16, floor: floor, walls: wall, ceiling: true)

        let iron = addPBRMaterial(baseColor: [0.12, 0.11, 0.1], metallic: 1, roughness: 0.5)
        let stone = addPBRMaterial(baseColor: [0.5, 0.48, 0.45], metallic: 0, roughness: 0.7)
        let wood = addPBRMaterial(baseColor: [0.55, 0.38, 0.22], metallic: 0, roughness: 0.6)
        let steel = addPBRMaterial(baseColor: [0.6, 0.62, 0.65], metallic: 1, roughness: 0.25)

        // The brazier: a deep bowl on a stand. Deep enough to hold the flames' lower halves (a young flame's picture
        // reaches 0.34 m below where it is born, on the rim): in a shallow one they hung in the air under it, seen
        // from below and in the floor.
        let fire = SIMD3<Float>(-2.6, 0.95, -0.5)
        let standShape = addSDFShape(SDFShape(.cylinder(halfHeight: 0.3, radius: 0.06, rounding: 0.01)))
        let stand = addInstance(sdf: standShape, iron, translate([fire.x, 0.3, fire.z]))
        let bowlShape = addSDFShape(SDFShape(.cylinder(halfHeight: 0.19, radius: 0.44, rounding: 0.04)))
        let bowl = addInstance(sdf: bowlShape, iron, translate([fire.x, 0.77, fire.z]))
        // The fire's light; the flames are what shows it (its proxy is a point: nothing to see).
        let hidden = addMesh((positions: [.zero, .zero, .zero], normals: [[0, 1, 0], [0, 1, 0], [0, 1, 0]], indices: [0, 1, 2]))
        addLight(.sphere(radius: 0.15), color: SIMD3<Float>(1.0, 0.55, 0.2) * 12, proxyMesh: hidden, motion: .scaleOnly) { t in
            let flicker = 0.8 + 0.12 * sin(t * 13.1) + 0.08 * sin(t * 29.3 + 1.7)
            return LightPose(position: fire + SIMD3(0, 0.35, 0), scale: SIMD3(repeating: flicker))
        }

        // The grinder: its housing, and on a shaft in front of it the wheel, facing the room, a steel bar pressed on
        // its rim. The wheel turns the other way to a clock as seen from the front (its top moving left; a real one
        // turns too fast to show, so it stands still), and the sparks leave the rim at the bar along it.
        let grinder = SIMD3<Float>(1.4, 1.1, 0.6)
        addInstance(sdf: addSDFShape(SDFShape(.box(halfExtents: [0.25, 0.5, 0.2], rounding: 0.02))), steel, translate([grinder.x + 0.3, 0.5, grinder.z]))
        let wheel = SIMD3<Float>(1.62, 1.12, 0.88), wheelRadius: Float = 0.16
        addInstance(sdf: addSDFShape(SDFShape(.cylinder(halfHeight: 0.03, radius: wheelRadius, rounding: 0.005))), stone,
                    translate(wheel) * rotate(.pi / 2, [1, 0, 0]))
        addInstance(sdf: addSDFShape(SDFShape(.cylinder(halfHeight: 0.035, radius: 0.02))), steel,
                    translate([wheel.x, wheel.y, 0.82]) * rotate(.pi / 2, [1, 0, 0]))
        let at = Scene.degrees(66), out = SIMD3<Float>(cos(at), sin(at), 0)   // where the bar meets the rim, outward
        let contact = wheel + out * wheelRadius
        let bar = normalize(SIMD3<Float>(0.75, 0.66, 0))                       // held from the upper right
        addInstance(sdf: addSDFShape(SDFShape(.box(halfExtents: [0.15, 0.012, 0.012], rounding: 0.003))), iron,
                    translate(contact + bar * 0.148) * rotate(atan2(bar.y, bar.x), [0, 0, 1]))
        let crate = (center: SIMD3<Float>(-0.4, 0.3, 1.0), half: SIMD3<Float>(0.3, 0.3, 0.3))
        addInstance(sdf: addSDFShape(SDFShape(.box(halfExtents: crate.half, rounding: 0.02))), wood, translate(crate.center))
        let plinth = SIMD3<Float>(0, 0, -2.6)
        let plinthShape = addSDFShape(SDFShape(.cylinder(halfHeight: 0.4, radius: 0.35, rounding: 0.03)))
        let plinthInstance = addInstance(sdf: plinthShape, stone, translate(plinth + SIMD3(0, 0.4, 0)))

        // A dim key light, so the smoke and the rain have something to scatter.
        addLight(.rect(width: 3, height: 1.5), color: SIMD3<Float>(0.75, 0.85, 1.0) * 1.2, motion: .constant) { _ in
            LightPose(position: [1.5, 6.97, 0], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        addLight(.sphere(radius: 0.08), color: SIMD3<Float>(0.4, 0.6, 1.0) * 2, proxyMesh: kit.sphere, motion: .constant) { _ in
            LightPose(position: plinth + SIMD3(0, 1.9, 0))
        }
        // A lamp over the rain: a cone down through it, so the drops show along their whole fall and their splashes
        // land in a pool of light on the floor.
        let lamp = SIMD3<Float>(3.6, 6.82, 1.0)
        kit.box([lamp.x, 6.97, lamp.z], [0.36, 0.06, 0.36], iron)
        addLight(.spot(radius: 0.08, inner: Scene.degrees(14), outer: Scene.degrees(22)), color: SIMD3<Float>(0.75, 0.85, 1.0) * 150,
                 proxyMesh: kit.sphere, motion: .constant) { _ in
            LightPose(position: lamp, direction: [0, -1, 0])
        }

        var flames = ParticleEmitter("flames", capacity: 200, at: fire + SIMD3(0, 0.02, 0))
        flames.shape = .disc(radius: 0.22)
        flames.rate = 180
        flames.lifetime = 0.35...0.7
        flames.speed = 0.3...0.7
        flames.spread = 0.25
        flames.gravity = -0.6
        flames.drag = 1.5
        flames.wind = 0.3
        flames.curl = 2
        flames.curlFrequency = 2.5
        flames.curlSpeed = 1.5
        flames.bakedCurl = true
        flames.size = (0.34, 0.14)
        flames.sizeJitter = 0.3
        flames.colors = ([1, 0.8, 0.5, 0.2], [1, 0.6, 0.3, 0.15], [0.8, 0.25, 0.08, 0])
        flames.midpoint = 0.3
        flames.emission = 1.4
        flames.atlas = .flame
        flames.frames = 64
        flames.fps = 40
        flames.randomFrame = true
        flames.orientation = .axis([0, 1, 0])
        flames.soft = 0.15
        flames.castsShadows = false

        // The glow where the bar grinds: hot points that flare and go, many at once. (No light there: a fifth would
        // take the scene to the many-lights path, whose light pass leaves lit particles only the sky's.)
        var glow = ParticleEmitter("grind glow", capacity: 16, at: contact + out * 0.005 + SIMD3(0, 0, 0.02))
        glow.shape = .sphere(radius: 0.008)
        glow.rate = 90
        glow.lifetime = 0.05...0.12
        glow.gravity = 0
        glow.size = (0.06, 0.03)
        glow.sizeJitter = 0.4
        glow.colors = ([1, 0.9, 0.7, 1], [1, 0.65, 0.3, 0.8], [1, 0.4, 0.1, 0])
        glow.emission = 60
        glow.atlas = .dot
        glow.soft = 0.01
        glow.castsShadows = false

        // The hot air over the fire: never drawn, it bends the view through it (ParticleEmitter.distortion), strongest
        // just over the flames and gone as it rises and cools.
        var heat = ParticleEmitter("heat", capacity: 48, at: fire + SIMD3(0, 0.25, 0))
        heat.shape = .disc(radius: 0.2)
        heat.rate = 30
        heat.lifetime = 0.8...1.3
        heat.speed = 0.6...1.0
        heat.spread = 0.2
        heat.gravity = -0.4
        heat.drag = 1
        heat.curl = 1.5
        heat.curlFrequency = 2
        heat.curlSpeed = 1
        heat.bakedCurl = true
        heat.size = (0.3, 0.6)
        heat.sizeJitter = 0.2
        heat.colors = ([1, 1, 1, 0], [1, 1, 1, 1], [1, 1, 1, 0])
        heat.midpoint = 0.25
        heat.distortion = 0.0025
        heat.field = (index: 1, strength: 0.6, follow: false)   // it rides the fire's hot air, as the smoke does

        var smoke = ParticleEmitter("smoke", capacity: 300, at: fire + SIMD3(0, 0.55, 0))
        smoke.shape = .disc(radius: 0.2)
        smoke.rate = 30
        smoke.lifetime = 4...6.5
        smoke.speed = 0.3...0.6
        smoke.spread = 0.2
        smoke.gravity = -0.08
        smoke.drag = 0.5
        smoke.wind = 1
        smoke.curl = 0.6
        smoke.curlFrequency = 0.8
        smoke.curlSpeed = 0.3
        smoke.bakedCurl = true
        smoke.field = (index: 1, strength: 1, follow: false)   // carried up the fire's hot air (ParticleField.plume)
        smoke.size = (0.22, 0.9)
        smoke.sizeJitter = 0.3
        smoke.colors = ([0.8, 0.78, 0.75, 0.0], [0.85, 0.84, 0.82, 0.75], [0.9, 0.9, 0.9, 0])
        smoke.midpoint = 0.15
        smoke.atlas = .smoke
        smoke.frames = 64
        smoke.randomFrame = true
        smoke.spin = 0.4
        smoke.soft = 0.4
        smoke.shadowDensity = 0.12

        // Off the wheel's rim at the bar, along the rim's way there (a little outward and toward the room).
        var sparks = ParticleEmitter("sparks", capacity: 1200, at: contact + out * 0.01)
        sparks.rate = 260
        sparks.burst = (2, 300, 3, 0)
        sparks.direction = normalize(SIMD3<Float>(-out.y, out.x, 0) + out * 0.15 + SIMD3(0, 0, 0.15))
        sparks.spread = 0.22
        sparks.lifetime = 0.7...1.5
        sparks.speed = 3...6
        sparks.drag = 0.3
        sparks.colliders = 0b11
        sparks.collidesWithScene = true   // the plinth, the brazier, the walls
        sparks.restitution = 0.45
        sparks.friction = 0.25
        sparks.size = (0.012, 0.006)
        sparks.colors = ([1, 0.85, 0.5, 1], [1, 0.55, 0.15, 1], [0.9, 0.2, 0.05, 1])
        sparks.emission = 40
        sparks.atlas = .spark
        sparks.orientation = .velocity(stretch: 0.025)
        sparks.soft = 0.02
        sparks.castsShadows = false

        var puffs = ParticleEmitter("spark smoke", capacity: 900, at: .zero)
        puffs.parent = 2
        puffs.perEvent = 1
        puffs.inherit = 0.15
        puffs.lifetime = 0.8...1.4
        puffs.gravity = -0.05
        puffs.drag = 1.5
        puffs.wind = 1
        puffs.size = (0.03, 0.12)
        puffs.colors = ([0.85, 0.82, 0.78, 0.35], [0.85, 0.85, 0.85, 0.2], [0.85, 0.85, 0.85, 0])
        puffs.atlas = .smoke
        puffs.frames = 64
        puffs.randomFrame = true
        puffs.soft = 0.05
        puffs.castsShadows = false

        var motes = ParticleEmitter("magic", capacity: 1000, at: plinth + SIMD3(0, 1.1, 0))
        motes.shape = .sphere(radius: 0.5)
        motes.rate = 220
        motes.lifetime = 2...3.5
        motes.speed = 0.05...0.2
        motes.radial = true
        motes.gravity = 0
        motes.drag = 0.4
        motes.curl = 1.2
        motes.curlFrequency = 1.6
        motes.curlSpeed = 0.5
        motes.vortex = 1.6
        motes.attraction = 0.6
        motes.size = (0.025, 0.01)
        motes.sizeJitter = 0.5
        motes.colors = ([0.4, 0.7, 1, 0], [0.5, 0.8, 1, 1], [0.8, 0.5, 1, 0])
        motes.midpoint = 0.2
        motes.emission = 5
        motes.atlas = .dot
        motes.castsShadows = false

        // Wisps in the same swirl, fewer and brighter, each with a glowing ribbon behind it (ParticleEmitter.trail).
        var wisps = motes
        wisps.name = "wisps"
        wisps.capacity = 90
        wisps.rate = 24
        wisps.lifetime = 2.5...3.5
        wisps.speed = 0.3...0.6
        wisps.size = (0.018, 0.01)
        wisps.sizeJitter = 0.2
        wisps.colors = ([0.3, 0.9, 1, 0], [0.5, 0.85, 1, 1], [0.9, 0.4, 1, 0])
        wisps.emission = 10
        wisps.trail = (points: 16, every: 2)   // half a second of where it was
        wisps.trailWidth = 0.8

        let rainArea = (center: SIMD3<Float>(3.6, 6.5, 1.0), half: SIMD3<Float>(1.6, 0, 2.2))
        var rain = ParticleEmitter("rain", capacity: 2000, at: rainArea.center)
        rain.shape = .box(halfExtents: rainArea.half)
        rain.rate = 900
        rain.lifetime = 2...2
        rain.speed = 0...0
        rain.velocity = [0.4, -7, 0]
        rain.gravity = 0.4
        rain.colliders = 0b01
        rain.collidesWithScene = true     // it splashes on the grinder's top too
        rain.dieOnCollision = true
        rain.size = (0.009, 0.009)
        rain.colors = ([0.9, 0.95, 1, 0.5], [0.9, 0.95, 1, 0.5], [0.9, 0.95, 1, 0.5])
        rain.atlas = .streak
        rain.orientation = .velocity(stretch: 0.03)
        rain.soft = 0
        rain.castsShadows = false

        var splashes = ParticleEmitter("splashes", capacity: 640, at: .zero)
        splashes.parent = 5
        splashes.trigger = .collision
        splashes.lifetime = 0.35...0.5
        splashes.gravity = 0
        splashes.size = (0.1, 0.18)
        splashes.colors = ([0.9, 0.95, 1, 0.8], [0.9, 0.95, 1, 0.5], [0.9, 0.95, 1, 0])
        splashes.atlas = .ring
        splashes.frames = 64
        splashes.orientation = .world(normal: [0, 1, 0])
        splashes.velocity = .zero
        splashes.soft = 0
        splashes.castsShadows = false
        splashes.frameBlend = true

        // Rubble: a burst of stone chunks every 2.5 s, thrown up from a spot on the floor. They're instances in the
        // scene's structure (shadows, reflections, GI), tumbling; dust where they land.
        let rubbleAt = SIMD3<Float>(-1.9, 0.05, 2.2)
        var rubble = ParticleEmitter("rubble", capacity: 120, at: rubbleAt)
        rubble.mesh = (addMesh(Scene.rock(seed: 7)), stone)
        rubble.burst = (0.5, 36, 2.5, 0)
        rubble.direction = normalize(SIMD3<Float>(0.3, 1, -0.15))
        rubble.spread = 0.45
        rubble.lifetime = 3...3.5
        rubble.speed = 2.5...4.5
        rubble.shape = .disc(radius: 0.15)
        rubble.colliders = 0b11111   // the floor, the crate, and the brazier and plinth by their distance fields
        rubble.collidesWithScene = true
        rubble.restitution = 0.3
        rubble.friction = 0.35
        rubble.size = (0.05, 0.05)
        rubble.sizeJitter = 0.5
        rubble.collisionRadius = 0.035
        rubble.spin = 9

        // (A puff an impact, few and small: crowded near the floor, every ray through them meets them all.)
        var dust = ParticleEmitter("dust", capacity: 160, at: .zero)
        dust.parent = 7
        dust.trigger = .collision
        dust.perEvent = 1
        dust.inherit = 0.1
        dust.speed = 0.2...0.5
        dust.spread = 1.2
        dust.lifetime = 0.6...1.1
        dust.gravity = -0.02
        dust.drag = 2
        dust.size = (0.03, 0.16)
        dust.sizeJitter = 0.3
        dust.colors = ([0.6, 0.55, 0.48, 0.4], [0.6, 0.56, 0.5, 0.25], [0.6, 0.57, 0.52, 0])
        dust.midpoint = 0.2
        dust.atlas = .smoke
        dust.frames = 64
        dust.randomFrame = true
        dust.spin = 0.6
        dust.soft = 0.05
        dust.castsShadows = false
        dust.field = (index: 0, strength: 1.5, follow: true)   // the air the rubble stirs: a little whirl rising

        addParticles(ParticleSystem(emitters: [flames, smoke, sparks, puffs, motes, rain, splashes, rubble, dust, wisps, heat, glow],
                                    colliders: [.plane(normal: [0, 1, 0], point: [0, 0.001, 0]), .box(center: crate.center, halfExtents: crate.half),
                                                .shape(instance: bowl, shape: bowlShape), .shape(instance: stand, shape: standShape),
                                                .shape(instance: plinthInstance, shape: plinthShape)],
                                    fields: [.vortex(center: rubbleAt, radius: 0.7, height: 1.6, swirl: 1.2, lift: 0.6),
                                             .plume(center: fire + SIMD3(0, 0.01, 0), radius: 0.3, height: 2.8, lift: 1.4)]))
        defaultCamera = Scene.demoCamera(.particles)!
    }

    /// A stone chunk about a unit across: an icosphere pushed in and out by a hash of its corners, its faces flat.
    static func rock(seed: UInt32) -> MeshGeometry {
        let ball = icosphere(subdivisions: 1)
        let corners = ball.positions.enumerated().map { i, p -> SIMD3<Float> in
            var r = ParticleMath.Rng(state: ParticleMath.hash(seed &+ UInt32(i) &* 0x9E37_79B9))
            return p * (0.7 + 0.45 * r.next()) * SIMD3(1, 0.75, 0.9)
        }
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for f in stride(from: 0, to: ball.indices.count, by: 3) {
            let a = corners[Int(ball.indices[f])], b = corners[Int(ball.indices[f + 1])], c = corners[Int(ball.indices[f + 2])]
            let n = normalize(cross(b - a, c - a))
            for p in [a, b, c] {
                indices.append(UInt32(positions.count))
                positions.append(p)
                normals.append(n)
            }
        }
        return (positions, normals, indices)
    }
}
