import Effects
import EngineCore
import Foundation
import Physics
import simd
import MetalRenderer

extension Scene {
    /// What the cars' breaks give off (CarDamage.swift's events, CarEvent: ParticlesGPU.breakRing), per kind a proxy
    /// emitter that spawns nothing of its own, whose events are the breaks, and its children: a pane's or a lamp's
    /// shards that tumble and bounce, a broken radiator's steam, a burning engine's smoke, a part's bits as it comes off
    /// and a puff of dust. Returns the proxies by kind (CarRig.breakProxies).
    func addCarDust(_ kit: Kit) -> [UInt32] {
        let shard = addPBRMaterial(baseColor: [0.55, 0.62, 0.62], metallic: 0, roughness: 0.08)
        let bit = addPBRMaterial(baseColor: [0.08, 0.08, 0.085], metallic: 0, roughness: 0.6)
        var emitters: [ParticleEmitter] = []
        var proxies: [UInt32] = []
        func proxy(_ kind: CarEvent) -> Int {
            var p = ParticleEmitter("Car \(kind) breaks", capacity: 64, at: .zero)
            p.lifetime = 0.01...0.01
            p.castsShadows = false
            proxies.append(UInt32(emitters.count))
            emitters.append(p)
            return emitters.count - 1
        }
        func chunks(_ name: String, parent: Int, material: Int, size: Float, capacity: Int, speed: ClosedRange<Float>) -> ParticleEmitter {
            var e = ParticleEmitter(name, capacity: capacity, at: .zero)
            e.parent = parent
            e.trigger = .condition   // (raised by the physics: as many as its pool, not a parent's deaths)
            e.perEvent = 8   // (ParticleSystem.maxPerEvent)
            e.inherit = 0.7
            e.shape = .sphere(radius: 0.2)
            e.speed = speed
            e.radial = true
            e.velocity = [0, 1, 0]
            e.lifetime = 3...5
            e.collidesWithScene = true
            e.restitution = 0.25
            e.friction = 0.6
            e.mesh = (kit.cube, material)
            e.size = (size, size)
            e.sizeJitter = 0.6
            e.collisionRadius = size * 0.5
            e.spin = 10
            return e
        }
        func puffs(_ name: String, parent: Int, colour: SIMD3<Float>, alpha: Float, perEvent: Int, rise: Float, life: ClosedRange<Float>,
                   size: (Float, Float)) -> ParticleEmitter {
            var e = ParticleEmitter(name, capacity: 1200, at: .zero)
            e.parent = parent
            e.trigger = .condition
            e.perEvent = perEvent
            e.inherit = 0.5
            e.shape = .sphere(radius: 0.15)
            e.speed = 0.1...0.5
            e.radial = true
            e.lifetime = life
            e.gravity = -rise
            e.drag = 1.2
            e.curl = 0.3
            e.curlFrequency = 0.9
            e.curlSpeed = 0.4
            e.bakedCurl = true
            e.size = size
            e.sizeJitter = 0.4
            e.colors = (SIMD4(colour, alpha), SIMD4(colour, alpha * 0.6), SIMD4(colour, 0))
            e.midpoint = 0.3
            e.atlas = .smoke
            e.frames = 64
            e.randomFrame = true
            e.spin = 0.5
            e.soft = 0.15
            e.shadowDensity = 0.3
            return e
        }
        for kind in CarEvent.allCases {
            let p = proxy(kind)
            switch kind {
            case .glass:
                emitters.append(chunks("Car glass shards", parent: p, material: shard, size: 0.018, capacity: 1200, speed: 1...3))
            case .steam:
                emitters.append(puffs("Car steam", parent: p, colour: [0.92, 0.93, 0.95], alpha: 0.35, perEvent: 2, rise: 0.12, life: 1.5...3,
                                      size: (0.2, 0.9)))
            case .smoke:
                emitters.append(puffs("Car smoke", parent: p, colour: [0.12, 0.12, 0.12], alpha: 0.4, perEvent: 3, rise: 0.1, life: 3...5.5,
                                      size: (0.3, 1.6)))
            case .debris:
                emitters.append(chunks("Car bits", parent: p, material: bit, size: 0.03, capacity: 600, speed: 1...3.5))
                emitters.append(puffs("Car dust", parent: p, colour: [0.55, 0.53, 0.5], alpha: 0.3, perEvent: 6, rise: 0.02, life: 2...4,
                                      size: (0.25, 1.1)))
            }
        }
        addParticles(ParticleSystem(emitters: emitters))
        return proxies
    }
}
