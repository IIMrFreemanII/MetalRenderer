import Foundation
import simd

/// The particles scene (Particles.swift): GPU particle effects, ray traced, in a dark studio with a glossy floor that
/// mirrors them. A brazier's fire (flames, a flickering light inside) and the smoke above it; a grinder throwing
/// sparks that bounce off the floor, the crate (analytic colliders) and whatever else they meet (a ray a step), and
/// leave puffs of smoke where they die; a swirl of magic motes in curl noise round a plinth; and rain falling on the
/// right, splashing where it lands.
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

        // The brazier: a bowl on a stand.
        let fire = SIMD3<Float>(-2.6, 0.95, -0.5)
        addInstance(sdf: addSDFShape(SDFShape(.cylinder(halfHeight: 0.42, radius: 0.06, rounding: 0.01))), iron,
                    translate([fire.x, 0.42, fire.z]))
        addInstance(sdf: addSDFShape(SDFShape(.cylinder(halfHeight: 0.08, radius: 0.42, rounding: 0.04))), iron,
                    translate([fire.x, 0.88, fire.z]))
        // The fire's light; the flames are what shows it (its proxy is a point: nothing to see).
        let hidden = addMesh((positions: [.zero, .zero, .zero], normals: [[0, 1, 0], [0, 1, 0], [0, 1, 0]], indices: [0, 1, 2]))
        addLight(.sphere(radius: 0.15), color: SIMD3<Float>(1.0, 0.55, 0.2) * 12, proxyMesh: hidden, motion: .scaleOnly) { t in
            let flicker = 0.8 + 0.12 * sin(t * 13.1) + 0.08 * sin(t * 29.3 + 1.7)
            return LightPose(position: fire + SIMD3(0, 0.35, 0), scale: SIMD3(repeating: flicker))
        }

        // The grinder's wheel, the crate the sparks hit, the plinth the motes swirl round.
        let grinder = SIMD3<Float>(1.4, 1.1, 0.6)
        addInstance(sdf: addSDFShape(SDFShape(.box(halfExtents: [0.25, 0.5, 0.2], rounding: 0.02))), steel, translate([grinder.x + 0.3, 0.5, grinder.z]))
        addInstance(sdf: addSDFShape(SDFShape(.cylinder(halfHeight: 0.03, radius: 0.16, rounding: 0.005))), steel,
                    translate([grinder.x + 0.15, grinder.y, grinder.z]) * rotate(.pi / 2, [0, 0, 1]))
        let crate = (center: SIMD3<Float>(-0.4, 0.3, 1.0), half: SIMD3<Float>(0.3, 0.3, 0.3))
        addInstance(sdf: addSDFShape(SDFShape(.box(halfExtents: crate.half, rounding: 0.02))), wood, translate(crate.center))
        let plinth = SIMD3<Float>(0, 0, -2.6)
        addInstance(sdf: addSDFShape(SDFShape(.cylinder(halfHeight: 0.4, radius: 0.35, rounding: 0.03))), stone, translate(plinth + SIMD3(0, 0.4, 0)))

        // A dim key light, so the smoke and the rain have something to scatter.
        addLight(.rect(width: 3, height: 1.5), color: SIMD3<Float>(0.75, 0.85, 1.0) * 1.2, motion: .constant) { _ in
            LightPose(position: [1.5, 6.97, 0], direction: [0, -1, 0], tangent: [1, 0, 0])
        }
        addLight(.sphere(radius: 0.08), color: SIMD3<Float>(0.4, 0.6, 1.0) * 2, proxyMesh: kit.sphere, motion: .constant) { _ in
            LightPose(position: plinth + SIMD3(0, 1.9, 0))
        }

        var flames = ParticleEmitter("flames", capacity: 200, at: fire + SIMD3(0, 0.02, 0))
        flames.shape = .disc(radius: 0.26)
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

        var sparks = ParticleEmitter("sparks", capacity: 1200, at: grinder)
        sparks.rate = 260
        sparks.burst = (2, 300, 3, 0)
        sparks.direction = normalize(SIMD3<Float>(-1, 0.45, 0.3))
        sparks.spread = 0.35
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

        let rainArea = (center: SIMD3<Float>(3.6, 6.5, 1.0), half: SIMD3<Float>(1.6, 0, 2.2))
        var rain = ParticleEmitter("rain", capacity: 1600, at: rainArea.center)
        rain.shape = .box(halfExtents: rainArea.half)
        rain.rate = 650
        rain.lifetime = 2...2
        rain.speed = 0...0
        rain.velocity = [0.4, -7, 0]
        rain.gravity = 0.4
        rain.colliders = 0b01
        rain.collidesWithScene = true     // it splashes on the grinder's top too
        rain.dieOnCollision = true
        rain.size = (0.006, 0.006)
        rain.colors = ([0.9, 0.95, 1, 0.35], [0.9, 0.95, 1, 0.35], [0.9, 0.95, 1, 0.35])
        rain.atlas = .streak
        rain.orientation = .velocity(stretch: 0.03)
        rain.soft = 0
        rain.castsShadows = false

        var splashes = ParticleEmitter("splashes", capacity: 500, at: .zero)
        splashes.parent = 5
        splashes.trigger = .collision
        splashes.lifetime = 0.35...0.5
        splashes.gravity = 0
        splashes.size = (0.08, 0.14)
        splashes.colors = ([0.9, 0.95, 1, 0.6], [0.9, 0.95, 1, 0.4], [0.9, 0.95, 1, 0])
        splashes.atlas = .ring
        splashes.frames = 64
        splashes.orientation = .world(normal: [0, 1, 0])
        splashes.velocity = .zero
        splashes.soft = 0
        splashes.castsShadows = false
        splashes.frameBlend = true

        addParticles(ParticleSystem(emitters: [flames, smoke, sparks, puffs, motes, rain, splashes],
                                    colliders: [.plane(normal: [0, 1, 0], point: [0, 0.001, 0]), .box(center: crate.center, halfExtents: crate.half)]))
        defaultCamera = Scene.demoCamera(.particles)!
    }
}
