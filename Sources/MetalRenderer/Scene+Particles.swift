import Foundation
import simd

/// The particles scene (Particles.swift; its effects are VFXLibrary's graphs): GPU particle effects, ray traced, in a dark studio with a glossy floor that
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

        // The effects (VFXLibrary: graphs the VFX editor edits), in the scene's own space; the colliders of its own
        // their Collide blocks name.
        let rainArea = (center: SIMD3<Float>(3.6, 6.5, 1.0), half: SIMD3<Float>(1.6, 0, 2.2))
        let rubbleAt = SIMD3<Float>(-1.9, 0.05, 2.2)
        let rock = addMesh(Scene.rock(seed: 7))
        addParticleCollider("floor", .plane(normal: [0, 1, 0], point: [0, 0.001, 0]))
        addParticleCollider("crate", .box(center: crate.center, halfExtents: crate.half))
        addParticleCollider("bowl", .shape(instance: bowl, shape: bowlShape))
        addParticleCollider("stand", .shape(instance: stand, shape: standShape))
        addParticleCollider("plinth", .shape(instance: plinthInstance, shape: plinthShape))
        // (The rubble first: its whirl is then the first field and the fire's hot air the second, as they were before the
        // effects were graphs. The particles step the same either way, but the buffers' layout sways the order the GPU's
        // atomics hand out pool slots in, and with it which samples each slot's light averages: the frames would differ
        // by a little noise.)
        addEffect(builtIn: VFXLibrary.rubble(at: rubbleAt), meshes: ["rock": (rock, stone)])
        addEffect(builtIn: VFXLibrary.campfire(fire: fire))
        addEffect(builtIn: VFXLibrary.grinder(contact: contact, out: out))
        addEffect(builtIn: VFXLibrary.magic(at: plinth + SIMD3(0, 1.1, 0)))
        addEffect(builtIn: VFXLibrary.rain(center: rainArea.center, half: rainArea.half))
        addEffects()
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
