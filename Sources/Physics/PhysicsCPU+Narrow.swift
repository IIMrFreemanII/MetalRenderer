import EngineCore
import Foundation
import Plants
import simd
import CPhysicsAtomics

extension PhysicsWorld {
    // MARK: Narrow phase

    /// The partner's record: a body, or a static collider.
    @inline(__always) package func partner(_ code: UInt32) -> GPUPhysicsBody {
        code & PhysicsWorld.staticBit != 0 ? statics[Int(code & ~PhysicsWorld.staticBit)] : bodies[Int(code)]
    }

    /// Each owned entry's contacts, closer than the margin plus how far the two may close in a step.
    /// `refresh`: within the step, when only the pairs that had contacts at its start, and of which a body moves, are
    /// found again. On every core: an entry writes only its own count and contacts.
    /// Every owned pair's contacts (`refresh`: again, mid-step, those of pairs with contacts of which a body moves).
    /// At the step's start a pair whose bodies are as they were at the last one's keeps the contacts found then
    /// (NarrowMemo: the same bits `collide` would give again); one found again in a refresh isn't kept.
    package func narrowPhase(_ p: GPUPhysicsParams, refresh: Bool) {
        let shapes = shapeData, n = bodies.count, entries = pairs.count
        if !refresh {
            let valid = narrowEpoch == shapeEpoch && narrowPartners.count == entries && narrowSeen.count == n
            if narrowPartners.count != entries {
                narrowPartners = [UInt32](repeating: PhysicsWorld.none, count: entries)
                narrowCounts = [UInt32](repeating: 0, count: entries)
            }
            if narrowSeen.count != n {
                narrowSeen = [SIMD16<UInt32>](repeating: .zero, count: n)
                narrowChanged = [UInt8](repeating: 1, count: n)
            }
            narrowEpoch = shapeEpoch
            // Where each body's samples' world points go (SampleCache), then each static's, from the shapes: once a
            // step.
            let records = n + statics.count
            if sampleStarts.count != records { sampleStarts = [Int32](repeating: 0, count: records) }
            if sampleStates.count != records { sampleStates = [Int](repeating: 0, count: records) }
            var total = 0
            for r in 0..<records {
                sampleStarts[r] = Int32(total)
                total += Int(shapes.shapes[Int((r < n ? bodies[r] : statics[r - n]).info.x)].info.z)
            }
            if sampleWorld.count < max(total, 1) { sampleWorld.append(contentsOf: repeatElement(.zero, count: max(total, 1) - sampleWorld.count)) }
            withNarrowMemo { m in
                withStepBuffers { s in
                    PhysicsPool.shared.parallel(n, grain: 256) { range in
                        for i in range {
                            let key = NarrowMemo.key(s.bodies[i])
                            m.changed[i] = valid && key == m.seen[i] ? 0 : 1
                            m.seen[i] = key
                        }
                    }
                }
            }
        }
        sampleEpoch += 1
        withNarrowMemo { m in
            withSampleCache { cache in
                withStepBuffers { s in
                    guard refresh else {
                        PhysicsPool.shared.parallel(n, grain: 16) { range in
                            for i in range { PhysicsWorld.narrow(i, s, shapes, p, refresh: false, memo: m, samples: cache) }
                        }
                        return
                    }
                    // A refresh's pairs are the coloured ones (`pairEntries`: with contacts at the step's start), each
                    // on its own, not every entry: three buildings settling, 8,000 of 170,000, and a partner read for
                    // each of 24,000 owned. (In entry order: a body's together, its samples' points worked out once.)
                    pairEntries.withUnsafeBufferPointer { order in
                        PhysicsPool.shared.parallel(order.count, grain: 16) { range in
                            for t in range {
                                let e = Int(order[t]), i = e / PhysicsWorld.maxPairs
                                PhysicsWorld.narrowEntry(e, i, s.bodies[i], e % PhysicsWorld.maxPairs < Int(s.pairCounts[i]), s, shapes, p,
                                                         refresh: true, memo: m, samples: cache)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Body i's owned entries' contacts (narrowPhase).
    @inline(__always) package static func narrow(_ i: Int, _ s: StepBuffers, _ shapes: PhysicsShapes, _ p: GPUPhysicsParams, refresh: Bool,
                                         memo m: NarrowMemo, samples: SampleCache) {
        let k = PhysicsWorld.maxPairs
        let a = s.bodies[i], count = Int(s.pairCounts[i])
        for n in 0..<k { narrowEntry(i * k + n, i, a, n < count, s, shapes, p, refresh: refresh, memo: m, samples: samples) }
    }

    /// Entry e's contacts (narrow; a refresh's on their own): `a` its body, body i; `listed`, whether it is one of i's
    /// entries this step.
    @inline(__always) package static func narrowEntry(_ e: Int, _ i: Int, _ a: GPUPhysicsBody, _ listed: Bool, _ s: StepBuffers, _ shapes: PhysicsShapes,
                                              _ p: GPUPhysicsParams, refresh: Bool, memo m: NarrowMemo, samples: SampleCache) {
        let mc = PhysicsWorld.maxContacts
        guard listed && s.pairs[e].link == UInt32(e) else {
            if !refresh { m.partners[e] = PhysicsWorld.none }   // (its contacts aren't this step's)
            return
        }
        let code = s.pairs[e].partner
        // As they were at the last step's start, and found then: those contacts. (Before the weld's: they were found
        // with none alive between them, and a weld only breaks, but at a reset, which drops the memo. Most of a
        // settling heap's pairs, and none of them reads the partner.)
        if !refresh && m.partners[e] == code && m.changed[i] == 0 && (code & PhysicsWorld.staticBit != 0 || m.changed[Int(code)] == 0) {
            let kept = Int(m.counts[e])
            s.pairs[e].contacts = UInt32(kept)
            for c in 0..<kept { s.contacts[e * mc + c].lambda = .zero }
            return
        }
        let b = s.partner(code)
        // A refresh: the coloured pairs (with contacts at the step's start) of which a body moves.
        if refresh && (s.pairs[e].pad == PhysicsWorld.none || !PhysicsWorld.moves(a) && !PhysicsWorld.moves(b)) { return }
        // Two welded pieces: the weld is the pair's one contact (Physics+Fracture.swift).
        if let w = liveWeld(i, code, bodies: UnsafeBufferPointer(s.bodies), starts: s.weldStarts,
                            list: s.weldList, welds: UnsafeBufferPointer(s.welds)) {
            s.pairs[e].contacts = 1
            s.contacts[e * mc] = PhysicsWorld.weldContact(w)
            m.partners[e] = PhysicsWorld.none
            return
        }
        let closing = (length(PhysicsMath.xyz(a.velocity)) + length(PhysicsMath.xyz(b.velocity))
                       + length(PhysicsMath.xyz(a.angular)) * a.invInertia.w
                       + length(PhysicsMath.xyz(b.angular)) * b.invInertia.w) * p.grid.w
        // (Each one's samples' world points from the cache: a static's after the bodies'.)
        let other = code & PhysicsWorld.staticBit != 0 ? s.bodies.count + Int(code & ~PhysicsWorld.staticBit) : Int(code)
        let manifold = shapes.collide(a, b, margin: p.grid.y + closing, pointsA: samples.points(i, a, shapes),
                                      pointsB: samples.points(other, b, shapes))
        let pa = Pose(a), pb = Pose(b)
        s.pairs[e].contacts = UInt32(manifold.count)
        for c in 0..<manifold.count {
            let point = manifold[c]
            s.contacts[e * mc + c] = GPUPhysicsContact(
                normal: SIMD4(point.normal, point.separation),
                anchorA: SIMD4(pa.toBody(point.pointA), point.radiusA),
                anchorB: SIMD4(pb.toBody(point.pointB), point.radiusB),
                lambda: .zero)
        }
        m.partners[e] = refresh ? PhysicsWorld.none : code
        m.counts[e] = UInt32(manifold.count)
    }
}
