import EngineCore
import Foundation
import simd

/// A car's damage at a step's end (Physics+Cars.swift's `endCarStep`, after `breakBeams`), each car on a worker of its
/// own, over buffers (Tools/perf/hot-functions.txt):
///
/// * its nodes' damage for the look (GPUPhysicsParticle.info.z, a byte each: crush from the flow of the beams on them,
///   scrapes and dirt from how far they slid on what they touched: `wear`), which the drawn vertices take from the
///   nodes they follow (MSL physicsSoftMeshKernel) and the paint shows as primer, bare metal and dirt;
/// * its parts: an attachment breaks when the body's metal it is fixed to is crushed (`mountCrush`); a part whose
///   attachments are all broken comes off (what it rested on lets go of it; with less than half of them left, the rest
///   tear too), and once still for a second is frozen;
/// * its wheels: one whose knuckle has `linksLost` of its links (wishbones, tie rod) broken, or whose axle was knocked
///   along the ground harder than `axleStrength` in a substep (a curb's knock: a bump's mostly lifts), is off;
/// * its panes and lamps: one whose frame strained past `glassStrain` (a lamp's past `lampStrain`), or whose part came
///   off, breaks (its bit in its car's first nodes' info.z: the kernel folds a pane's vertices away and darkens a
///   lamp's), and scatters shards;
/// * its engine: its front end pushed back toward it (the mean of the four of its nodes that came back furthest) leaks
///   its radiator's coolant, which makes it run hot, which cuts its power and in the end seizes it; pushed back
///   further, the block itself breaks. Steam and smoke rise from it.
///
/// What it leaves for the dust (CarEvent) goes in its slots of `events`, which endCarStep logs in the cars' order.
extension CarSolver {
    /// How far a beam flows (as a share of its length) for its nodes to show fully crushed.
    package static let crushStrain: Float = 0.08
    /// How far (m) a node slides fast to show fully scraped, at all to show fully dirty.
    package static let scrapeLength: Float = 0.4, dirtLength: Float = 3
    /// How long (s) a part that came off stays still before it is frozen, and how slow its nodes are then (m/s).
    package static let freezeAfter: Float = 1, stillSpeed: Float = 0.15
    /// How fast a broken radiator loses its coolant (a share a second, at its worst); how fast the engine heats up
    /// without it (at full throttle), and cools with it.
    package static let coolantLoss: Float = 0.05, heating: Float = 0.03, cooling: Float = 0.05
    /// Steps between puffs of steam or smoke.
    package static let smokeEvery: Int32 = 6
    /// The crush (of 255) of the body node an attachment is fixed to that breaks it: 6% of flow on the beams round it.
    package static let mountCrush: UInt32 = 191
    /// A part with less than 1 / tornBelow of its attachments left is torn off.
    package static let tornBelow: Int32 = 2
    /// A wheel whose knuckle has this many of its links broken is off.
    package static let linksLost = 3

    @inline(__always) package static func damage(_ c: Int, _ b: CarBuffers, substeps: Float) {
        var s = b.cars[c]
        let step = PhysicsWorld.stepLength
        // The nodes' crush, from the plastic beams on them (a broken one crushed through).
        for k in Int(s.firstBeam)..<Int(s.firstBeam + s.beamCount) {
            let beam = b.beams[k], broken = beam.info & CarBeam.brokenBit != 0
            guard beam.info & CarBeam.attachBit == 0 else { continue }
            guard beam.kind == CarBeamKind.plastic.rawValue else { continue }
            let limit = b.limits[k]
            let strain = broken ? crushStrain : abs(beam.rest - limit.rest0) / limit.rest0
            guard strain > 0.004 else { continue }
            let crush = UInt32(min(strain / crushStrain, 1) * 255)
            crushNode(Int(beam.nodes.x), crush, b)
            crushNode(Int(beam.nodes.y), crush, b)
        }
        wearNodes(s, b)
        // What holds each part on: an attachment whose body node is crushed (the metal it was fixed to) breaks.
        var holding = SIMD16<Int32>()
        for k in Int(s.firstBeam)..<Int(s.firstBeam + s.beamCount) where b.beams[k].info & (CarBeam.attachBit | CarBeam.brokenBit) == CarBeam.attachBit {
            let beam = b.beams[k]
            if b.particles[Int(beam.nodes.y)].info.z & 0xFF >= mountCrush {
                b.beams[k].info |= CarBeam.brokenBit
            } else if beam.part > 0 && beam.part <= 16 {
                holding[beam.part - 1] += 1
            }
        }
        let frame = PhysicsWorld.carFrame(s, UnsafeBufferPointer(b.particles))
        // Its parts.
        for p in 0..<Int(s.partCount) {
            var part = b.parts[Int(s.firstPart) + p]
            if part.flags & CarPart.off == 0 {
                part.holding = p < 16 ? holding[p] : 1
                if part.holding > 0 && part.holding * tornBelow < part.attachments {
                    tear(p + 1, s, b)
                    part.holding = 0
                }
                if part.holding == 0 {
                    part.flags |= CarPart.off
                    s.partsOff += 1
                    letGo(p + 1, s, b)
                    event(c, .debris, middle(part, b), PhysicsMath.xyz(b.particles[Int(part.firstNode)].velocity), 0.4, b)
                }
            } else if part.flags & CarPart.frozen == 0 {
                var fastest: Float = 0
                for i in Int(part.firstNode)..<Int(part.firstNode + part.nodeCount) {
                    fastest = max(fastest, length_squared(PhysicsMath.xyz(b.particles[i].velocity)))
                }
                part.still = fastest < stillSpeed * stillSpeed ? part.still + step : 0
                if part.still > freezeAfter {
                    part.flags |= CarPart.frozen
                    for i in Int(part.firstNode)..<Int(part.firstNode + part.nodeCount) {
                        var q = b.particles[i]
                        q.prevPosition = SIMD4(PhysicsMath.xyz(q.position), 0)
                        q.velocity = SIMD4(0, 0, 0, q.velocity.w)
                        b.particles[i] = q
                    }
                }
            }
            b.parts[Int(s.firstPart) + p] = part
        }
        // Its wheels.
        for k in Int(s.firstWheel)..<Int(s.firstWheel + s.wheelCount) {
            var w = b.wheels[k]
            let knock = w.axleKnock
            w.knockPeak = max(w.knockPeak, knock)
            w.axleKnock = 0
            var lost = 0
            for j in 0..<8 where w.links[j] >= 0 && b.beams[Int(w.links[j])].info & CarBeam.brokenBit != 0 { lost += 1 }
            if w.flags & CarWheel.off == 0 && (knock > PhysicsWorld.axleStrength || lost >= linksLost) {
                w.flags = CarWheel.off | (w.flags & CarWheel.front)
                w.brake = 0
                w.tie = -1
                s.wheelsOff += 1
                // A body of its own again: its friction and bounce back, met by the cars' nodes.
                var o = b.bodies[Int(w.body)]
                o.velocity.w = 0.8
                o.angular.w = 0.2
                o.info.y &= ~PhysicsWorld.wheelBit
                b.bodies[Int(w.body)] = o
            }
            b.wheels[k] = w
        }
        // Its panes and lamps.
        for j in 0..<Int(s.paneCount) {
            var pane = b.panes[Int(s.firstPane) + j]
            guard !pane.broken else { continue }
            var strain: Float = 0
            for f in Int(pane.firstFrame)..<Int(pane.firstFrame + pane.frameCount) {
                let k = Int(b.paneFrames[f]), beam = b.beams[k], limit = b.limits[k]
                let stretch = beam.info & CarBeam.brokenBit != 0 ? limit.rest0 : abs(beam.rest - limit.rest0) + (pane.lamp ? 0 : abs(beam.load) * beam.compliance)
                strain = max(strain, stretch / limit.rest0)
            }
            let off = pane.part > 0 && b.parts[Int(s.firstPart + pane.part) - 1].flags & CarPart.off != 0
            guard off || strain > (pane.lamp ? PhysicsWorld.lampStrain : PhysicsWorld.glassStrain) else { continue }
            pane.broken = true
            b.panes[Int(s.firstPane) + j] = pane
            s.panesBroken += 1
            let holder = Int(s.firstNode) + j / 8
            b.particles[holder].info.z |= 1 << UInt32(24 + j % 8)
            for corner in 0..<(pane.lamp ? 1 : 4) {
                let i = Int(pane.corners[corner])
                event(c, .glass, PhysicsMath.xyz(b.particles[i].position), PhysicsMath.xyz(b.particles[i].velocity), pane.lamp ? 0.1 : 0.25, b)
            }
        }
        // Its engine.
        var engine = SIMD3<Float>()
        for k in Int(s.firstReaction)..<Int(s.firstReaction + s.reactionCount) { engine += PhysicsMath.xyz(b.particles[Int(b.reactions[k])].position) }
        engine /= Float(max(s.reactionCount, 1))
        var worst = SIMD4<Float>()   // (the four furthest back, the least first)
        for k in Int(s.firstRadiator)..<Int(s.firstRadiator + s.radiatorCount) {
            let back = b.reach[k] - dot(PhysicsMath.xyz(b.particles[Int(b.radiator[k])].position) - engine, frame.forward)
            if back > worst[0] {
                worst[0] = back
                for j in 1..<4 where worst[j - 1] > worst[j] { (worst[j - 1], worst[j]) = (worst[j], worst[j - 1]) }
            }
        }
        s.frontCrush = max((worst[0] + worst[1] + worst[2] + worst[3]) / 4, 0)
        let leak = simd_clamp((s.frontCrush - PhysicsWorld.radiatorCrush) / PhysicsWorld.radiatorSpan, 0, 1)
        s.coolant = max(s.coolant - leak * coolantLoss * step, 0)
        s.engineDamage = max(s.engineDamage, simd_clamp((s.frontCrush - PhysicsWorld.blockCrush) / PhysicsWorld.blockSpan, 0, 1))
        let cooled = min(s.coolant / 0.3, 1), work: Float = s.running ? 0.3 + 0.7 * s.throttle : 0
        s.heat = simd_clamp(s.heat + (work * (1 - cooled) * heating - cooled * cooling) * step, 0, 1)
        if s.heat >= 1 { s.engineDamage = 1 }
        if s.engineDamage >= 1 { s.running = false }
        s.sinceSmoke += 1
        if s.sinceSmoke >= smokeEvery && (leak > 0 && s.coolant > 0 || s.heat > 0.6 || s.engineDamage > 0.5) {
            s.sinceSmoke = 0
            let rising = frame.velocity + frame.up * 1.2
            let smoke = s.heat > 0.6 || s.engineDamage > 0.5
            event(c, smoke ? .smoke : .steam, engine + frame.up * 0.35 + frame.forward * 0.3, rising, 0.25, b)
        }
        b.cars[c] = s
    }

    /// Node `i`'s crush (its info.z's low byte) raised to `crush` (0...255).
    @inline(__always) package static func crushNode(_ i: Int, _ crush: UInt32, _ b: CarBuffers) {
        let z = b.particles[i].info.z
        if crush > z & 0xFF { b.particles[i].info.z = (z & ~0xFF) | crush }
    }

    /// Car `s`'s nodes' slides (`wear`) worn into their scrapes and dirt (info.z's second and third bytes), what is
    /// left of a byte kept for the next steps.
    @inline(__always) package static func wearNodes(_ s: CarState, _ b: CarBuffers) {
        let per = SIMD2<Float>(255 / scrapeLength, 255 / dirtLength)
        for i in Int(s.firstNode)..<Int(s.firstNode + s.nodeCount) {
            let w = b.wear[i]
            guard w.x * per.x >= 1 || w.y * per.y >= 1 else { continue }
            let bytes = SIMD2<Float>((w.x * per.x).rounded(.down), (w.y * per.y).rounded(.down))
            b.wear[i] = w - bytes / per
            let z = b.particles[i].info.z
            let scrape = min((z >> 8 & 0xFF) + UInt32(bytes.x), 255), dirt = min((z >> 16 & 0xFF) + UInt32(bytes.y), 255)
            b.particles[i].info.z = (z & 0xFF00_00FF) | scrape << 8 | dirt << 16
        }
    }

    /// Car `s`'s part `p` (1 + its place) torn off: its attachments left broken.
    @inline(__always) package static func tear(_ p: Int, _ s: CarState, _ b: CarBuffers) {
        for k in Int(s.firstBeam)..<Int(s.firstBeam + s.beamCount) where b.beams[k].part == p && b.beams[k].info & CarBeam.attachBit != 0 {
            b.beams[k].info |= CarBeam.brokenBit
        }
    }

    /// Car `s`'s part `p` (1 + its place) let go: the supports it rested on the body by broken.
    @inline(__always) package static func letGo(_ p: Int, _ s: CarState, _ b: CarBuffers) {
        for k in Int(s.firstBeam)..<Int(s.firstBeam + s.beamCount) where b.beams[k].part == p && b.beams[k].kind == CarBeamKind.support.rawValue {
            b.beams[k].info |= CarBeam.brokenBit
        }
    }

    /// The middle of `part`'s nodes.
    @inline(__always) package static func middle(_ part: CarPart, _ b: CarBuffers) -> SIMD3<Float> {
        var x = SIMD3<Float>()
        for i in Int(part.firstNode)..<Int(part.firstNode + part.nodeCount) { x += PhysicsMath.xyz(b.particles[i].position) }
        return x / Float(max(part.nodeCount, 1))
    }

    /// An event of car `c`'s step for the dust (as many as its slots hold).
    @inline(__always) package static func event(_ c: Int, _ kind: CarEvent, _ x: SIMD3<Float>, _ v: SIMD3<Float>, _ radius: Float, _ b: CarBuffers) {
        let n = Int(b.eventCounts[c])
        guard n < CarSystem.maxEvents else { return }
        b.events[c * CarSystem.maxEvents + n] = GPUBreakEvent(position: SIMD4(x, radius), velocity: SIMD4(v, Float(kind.slot)))
        b.eventCounts[c] = Int32(n + 1)
    }
}
