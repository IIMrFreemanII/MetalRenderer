import Foundation
import simd

/// The CPU's step: the reference the GPU's (Shaders/Physics.metal) is checked against, and the backend for scenes with
/// few bodies, where a GPU dispatch costs more than the work. Each stage is what a kernel does, over every body, in
/// the same order. Contacts are solved a colour at a time (Gauss-Seidel): no two pairs of a colour share a body, so
/// the GPU solves a colour's pairs at once and gets the same numbers. So are the joints, after the contacts.
extension PhysicsWorld {
    /// A step (1/60 s), its stages on PhysicsPool's workers.
    func step() {
        PhysicsPool.shared.run { stepStages() }
    }

    private func stepStages() {
        _ = shapeData   // (made here, if the shapes changed: the stages read it from every core)
        let p = params
        if fractures { beginFractureStep() }   // the shots and blasts of this step (Physics+Fracture.swift)
        broadPhase(p)
        wake(p)
        link()
        particleBroadPhase(p)
        // The liquids before each group of substeps (PhysicsFluidCPU.swift), against the bodies where they are, and
        // what they push the bodies by, before the group's contacts.
        stepFluids()
        let start = bodies.map { SIMD8<Float>(lowHalf: $0.position, highHalf: $0.rotation) }
        narrowPhase(p, refresh: false)
        colourPairs()
        for sub in 0..<substeps {
            // The contacts again where the substeps have taken the bodies: found once a step, a turning body's
            // contacts stay where it was (a rolling rim's sinks into the floor, and the push out of it launches it).
            if sub > 0 && sub % PhysicsWorld.contactRefresh == 0 {
                stepFluids()
                narrowPhase(p, refresh: true)
            }
            integrate(p, sub: sub)
            integrateParticles(p)
            solveFlesh(p)       // the muscles, and the flesh held to its bones where this substep moved them
            solveCloth(p)
            solveTets(p)
            solveSkin(p)
            solveParticles(p)   // against the bodies where this substep moved them, before they are pushed apart
            solvePositions(p)
            solveVelocities(p)
        }
        settle(p, start)
        stepHair(start)
        if fractures { endFractureStep() }     // what broke, what came free, what faded
        stepIndex += 1
    }

    // MARK: Broad phase

    /// A body's bounding sphere for this step: its radius, as far as it may go (at up to the cell speed), and the margin.
    @inline(__always) static func reach(_ b: GPUPhysicsBody, _ p: GPUPhysicsParams) -> Float {
        b.invInertia.w + min(length(PhysicsMath.xyz(b.velocity)), p.sleep.w) * p.grid.w + p.grid.y
    }

    /// With fractured objects (physBoxGap): how far apart bodies a and b's boxes are, each grown by its margin `ma`, `mb`
    /// (their reach past their size); the largest gap along the 15 axes that could part two boxes, negative when they
    /// overlap.
    @inline(__always) static func boxGap(_ a: GPUPhysicsBody, _ ca: SIMD4<Float>, _ ha: SIMD4<Float>, _ ma: Float,
                                         _ b: GPUPhysicsBody, _ cb: SIMD4<Float>, _ hb: SIMD4<Float>, _ mb: Float) -> Float {
        let ax = (PhysicsMath.qrot(a.rotation, [1, 0, 0]), PhysicsMath.qrot(a.rotation, [0, 1, 0]), PhysicsMath.qrot(a.rotation, [0, 0, 1]))
        let bx = (PhysicsMath.qrot(b.rotation, [1, 0, 0]), PhysicsMath.qrot(b.rotation, [0, 1, 0]), PhysicsMath.qrot(b.rotation, [0, 0, 1]))
        @inline(__always) func axis(_ t: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), _ k: Int) -> SIMD3<Float> {
            k == 0 ? t.0 : k == 1 ? t.1 : t.2
        }
        let ea = PhysicsMath.xyz(ha) + ma, eb = PhysicsMath.xyz(hb) + mb
        let t = (PhysicsMath.xyz(b.position) + PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(cb)))
            - (PhysicsMath.xyz(a.position) + PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(ca)))
        var gap = -Float.infinity
        for k in 0..<15 {
            var l = k < 3 ? axis(ax, k) : k < 6 ? axis(bx, k - 3) : cross(axis(ax, (k - 6) / 3), axis(bx, (k - 6) % 3))
            if k >= 6 {
                let n = length(l)
                if !(n > 1e-4) { continue }
                l /= n
            }
            let ra = ea.x * abs(dot(ax.0, l)) + ea.y * abs(dot(ax.1, l)) + ea.z * abs(dot(ax.2, l))
            let rb = eb.x * abs(dot(bx.0, l)) + eb.y * abs(dot(bx.1, l)) + eb.z * abs(dot(bx.2, l))
            gap = max(gap, abs(dot(t, l)) - ra - rb)
        }
        return gap
    }

    @inline(__always) static func cell(_ x: SIMD3<Float>, _ size: Float) -> SIMD3<Int32> {
        SIMD3<Int32>((x / size).rounded(.down))
    }

    /// The squared distance between two points, fused as Physics.metal's physDistance2 is: the GPU sorts partners by it
    /// into the same order, bit for bit.
    @inline(__always) static func distance2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d.x * d.x).addingProduct(d.y, d.y).addingProduct(d.z, d.z)
    }

    /// Whether a sphere meets static collider `s`'s box (an endless plane: whether it reaches below it).
    func touchesStatic(_ s: Int, centre: SIMD3<Float>, radius: Float) -> Bool {
        PhysicsWorld.touchesStatic(statics[s], shapes, staticBounds[s], centre: centre, radius: radius)
    }
    @inline(__always) static func touchesStatic(_ st: GPUPhysicsBody, _ shapes: [GPUPhysicsShape], _ box: AABB, centre: SIMD3<Float>,
                                                radius: Float) -> Bool {
        if shapes[Int(st.info.x)].info.x == PhysicsShapeKind.plane.rawValue {
            let n = PhysicsMath.qrot(st.rotation, SIMD3(0, 1, 0))
            return dot(centre - PhysicsMath.xyz(st.position), n) < radius
        }
        let nearest = simd_clamp(centre, box.lo, box.hi)
        return length_squared(centre - nearest) < radius * radius
    }

    /// Every body's partners: the static colliders it meets, then the bodies in the 27 cells around it whose spheres
    /// meet its own, nearest first (the lower first of equals), `maxPairs` at most: a crowded body drops its farthest
    /// bodies, never what holds it up. Two bodies a joint joins aren't partners (they overlap where it is). (Keeping the lowest-numbered instead, a tower's middle blocks dropped a body
    /// dragged into them, which went through.) The grid is built here; each body's query on every core.
    private func broadPhase(_ p: GPUPhysicsParams) {
        let size = p.grid.x
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (i, b) in bodies.enumerated() where !PhysicsWorld.disabled(b) {
            grid[PhysicsWorld.cell(PhysicsMath.xyz(b.position), size), default: []].append(i)
        }
        let shapes = self.shapes, boxes = shapeBoxes, staticBounds = self.staticBounds, byGap = fractures, n = bodies.count
        withStepBuffers { s in
            PhysicsPool.shared.parallel(n, grain: 32) { range in
                withUnsafeTemporaryAllocation(of: (Float, UInt32).self, capacity: PhysicsWorld.maxPairs) { kept in
                    for i in range {
                        PhysicsWorld.partners(i, s, grid, shapes, boxes, staticBounds, p, byGap: byGap, kept: kept)
                    }
                }
            }
        }
    }

    /// Body i's partners (broadPhase), kept nearest first in `kept` as they are found (the same `maxPairs` as sorting
    /// them all: the order is total, and no partner is found twice).
    @inline(__always) static func partners(_ i: Int, _ s: StepBuffers, _ grid: [SIMD3<Int32>: [Int]], _ shapes: [GPUPhysicsShape],
                                           _ boxes: [SIMD4<Float>], _ staticBounds: [AABB], _ p: GPUPhysicsParams, byGap: Bool,
                                           kept: UnsafeMutableBufferPointer<(Float, UInt32)>) {
        let k = PhysicsWorld.maxPairs
        let b = s.bodies[i]
        if PhysicsWorld.disabled(b) { s.pairCounts[i] = 0; return }   // (it is in no cell: nothing finds it either)
        let x = PhysicsMath.xyz(b.position), r = PhysicsWorld.reach(b, p)
        let c = PhysicsWorld.cell(x, p.grid.x)
        var count = 0
        // (Distance squared, -1 for a static; partner. With fractured objects, the gap between their boxes, those
        // that overlap, -infinity for a static: physPairs.)
        @inline(__always) func keep(_ key: Float, _ id: UInt32) {
            if count == k && !(key < kept[k - 1].0 || (key == kept[k - 1].0 && id < kept[k - 1].1)) { return }
            var at = min(count, k - 1)
            while at > 0 && (key < kept[at - 1].0 || (key == kept[at - 1].0 && id < kept[at - 1].1)) {
                kept[at] = kept[at - 1]
                at -= 1
            }
            kept[at] = (key, id)
            count = min(count + 1, k)
        }
        for dz: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dx: Int32 in -1...1 {
                    guard let cell = grid[c &+ SIMD3(dx, dy, dz)] else { continue }
                    for j in cell where j != i && !PhysicsWorld.joined(b, i, s.bodies[j], j) {
                        let o = s.bodies[j]
                        if PhysicsWorld.kinematic(b) && PhysicsWorld.kinematic(o) { continue }   // neither gives
                        if PhysicsWorld.held(b) && PhysicsWorld.held(o) { continue }             // two anchored pieces
                        let reach = r + PhysicsWorld.reach(o, p)
                        let d2 = PhysicsWorld.distance2(PhysicsMath.xyz(o.position), x)
                        guard d2 < reach * reach else { continue }
                        guard byGap else { keep(d2, UInt32(j)); continue }
                        let sa = Int(b.info.x), sb = Int(o.info.x)
                        let gap = PhysicsWorld.boxGap(b, boxes[2 * sa], boxes[2 * sa + 1], r - b.invInertia.w,
                                                      o, boxes[2 * sb], boxes[2 * sb + 1], PhysicsWorld.reach(o, p) - o.invInertia.w)
                        if gap < 0 { keep(gap, UInt32(j)) }
                    }
                }
            }
        }
        if !PhysicsWorld.kinematic(b) {
            for st in s.statics.indices where PhysicsWorld.touchesStatic(s.statics[st], shapes, staticBounds[st], centre: x, radius: r) {
                keep(byGap ? -.infinity : -1, UInt32(st) | PhysicsWorld.staticBit)
            }
        }
        s.pairCounts[i] = UInt32(count)
        for n in 0..<count { s.pairs[i * k + n] = GPUPhysicsPair(partner: kept[n].1) }
    }

    /// A sleeping body wakes when something it touches moves faster than the wake speed, or turns its mass faster than
    /// the wake turn (its turn rate x its radius of gyration about the turn, at most `gyration`), above the sleep ones: a neighbour settling
    /// down beside it doesn't, nor a thin limb jittering about its length.
    @inline(__always) static func stirs(_ b: GPUPhysicsBody, _ p: GPUPhysicsParams) -> Bool {
        if kinematic(b) {   // (no mass: its turn is its turn rate x the most gyration)
            return length(PhysicsMath.xyz(b.velocity)) > p.rolling.z || length(PhysicsMath.xyz(b.angular)) * gyration > p.rolling.w
        }
        guard moves(b) else { return false }
        if length(PhysicsMath.xyz(b.velocity)) > p.rolling.z { return true }
        let omega = PhysicsMath.xyz(b.angular), rate = length(omega)
        guard rate > 1e-9 else { return false }
        let w = turnWeight(b, omega / rate)
        return w > 0 && rate * min(sqrt(b.position.w / w), gyration) > p.rolling.w
    }

    private func wake(_ p: GPUPhysicsParams) {
        let n = bodies.count
        wakeFlags.removeAll(keepingCapacity: true)
        wakeFlags.append(contentsOf: repeatElement(0, count: n))
        // Who wakes, from the bodies as they were (a body woken here stirs nothing: its speeds are a sleeper's 0)...
        wakeFlags.withUnsafeMutableBufferPointer { flags in
            withStepBuffers { s in
                PhysicsPool.shared.parallel(n, grain: 64) { range in
                    for i in range where s.bodies[i].info.y & PhysicsWorld.asleep != 0 {
                        for m in 0..<Int(s.pairCounts[i]) {
                            let partner = s.pairs[i * PhysicsWorld.maxPairs + m].partner
                            guard partner & PhysicsWorld.staticBit == 0, PhysicsWorld.stirs(s.bodies[Int(partner)], p) else { continue }
                            flags[i] = 1
                            break
                        }
                    }
                }
                // ...and they wake.
                PhysicsPool.shared.parallel(n, grain: 256) { range in
                    for i in range where flags[i] != 0 {
                        s.bodies[i].info.y &= ~PhysicsWorld.asleep
                        s.bodies[i].prevPosition.w = 0
                    }
                }
            }
        }
        // A ragdoll wakes whole: if any of its bodies is awake (or held), the rest wake.
        for r in ragdolls {
            let range = Int(r.x)..<Int(r.x + r.y)
            guard range.contains(where: { PhysicsWorld.moves(bodies[$0]) || grab.target.w > 0 && grab.body == UInt32($0) }) else { continue }
            for i in range where bodies[i].info.y & PhysicsWorld.asleep != 0 {
                bodies[i].info.y &= ~PhysicsWorld.asleep
                bodies[i].prevPosition.w = 0
            }
        }
    }

    /// Each entry's owner: the lower body of two, or the body against a static. Another body's entry points at the
    /// owner's. A pair one of the two dropped (a crowded body keeps its nearest) neither has: the colours see a pair
    /// only through both bodies' lists, and one the higher body didn't list took a colour beside its other pairs, and
    /// two GPU threads moved that body at once (a dense pile's runs differed after a second).
    /// With fractured objects, a pair only one of its bodies lists (the other's list is full: a slab in a heap touches
    /// more pieces than it has room for) is that one's, marked (pad = `oneSided`) to be solved one after another after
    /// the colours: without it, the piece sank into the slab and was pushed out again, and the heap stirred on.
    private func link() {
        let k = PhysicsWorld.maxPairs, oneSided = fractures, n = bodies.count
        withStepBuffers { s in
            PhysicsPool.shared.parallel(n, grain: 64) { range in
                for i in range {
                    for m in 0..<Int(s.pairCounts[i]) {
                        let e = i * k + m, partner = s.pairs[e].partner
                        if oneSided { s.pairs[e].pad = PhysicsWorld.none }
                        if partner & PhysicsWorld.staticBit != 0 {
                            s.pairs[e].link = UInt32(e)
                            continue
                        }
                        let o = Int(partner)
                        var link = PhysicsWorld.none
                        for q in 0..<Int(s.pairCounts[o]) where s.pairs[o * k + q].partner == UInt32(i) {
                            link = o > i ? UInt32(e) : UInt32(o * k + q)
                            break
                        }
                        if oneSided && link == PhysicsWorld.none {
                            link = UInt32(e)
                            s.pairs[e].pad = PhysicsWorld.oneSided
                        }
                        s.pairs[e].link = link
                    }
                }
            }
        }
    }

    // MARK: Narrow phase

    /// The partner's record: a body, or a static collider.
    @inline(__always) func partner(_ code: UInt32) -> GPUPhysicsBody {
        code & PhysicsWorld.staticBit != 0 ? statics[Int(code & ~PhysicsWorld.staticBit)] : bodies[Int(code)]
    }

    /// Each owned entry's contacts, closer than the margin plus how far the two may close in a step.
    /// `refresh`: within the step, when only the pairs that had contacts at its start, and of which a body moves, are
    /// found again. On every core: an entry writes only its own count and contacts.
    private func narrowPhase(_ p: GPUPhysicsParams, refresh: Bool) {
        let shapes = shapeData, n = bodies.count
        withStepBuffers { s in
            PhysicsPool.shared.parallel(n, grain: 16) { range in
                for i in range { PhysicsWorld.narrow(i, s, shapes, p, refresh: refresh) }
            }
        }
    }

    /// Body i's owned entries' contacts (narrowPhase).
    @inline(__always) static func narrow(_ i: Int, _ s: StepBuffers, _ shapes: PhysicsShapes, _ p: GPUPhysicsParams, refresh: Bool) {
        let k = PhysicsWorld.maxPairs, mc = PhysicsWorld.maxContacts
        let a = s.bodies[i]
        for n in 0..<Int(s.pairCounts[i]) {
            let e = i * k + n
            guard s.pairs[e].link == UInt32(e) else { continue }
            let b = s.partner(s.pairs[e].partner)
            // A refresh: the coloured pairs (with contacts at the step's start) of which a body moves.
            if refresh && (s.pairs[e].pad == PhysicsWorld.none || !PhysicsWorld.moves(a) && !PhysicsWorld.moves(b)) { continue }
            // Two welded pieces: the weld is the pair's one contact (Physics+Fracture.swift).
            if let w = liveWeld(i, s.pairs[e].partner, bodies: UnsafeBufferPointer(s.bodies), starts: s.weldStarts,
                                list: s.weldList, welds: UnsafeBufferPointer(s.welds)) {
                s.pairs[e].contacts = 1
                s.contacts[e * mc] = PhysicsWorld.weldContact(w)
                continue
            }
            let closing = (length(PhysicsMath.xyz(a.velocity)) + length(PhysicsMath.xyz(b.velocity))
                           + length(PhysicsMath.xyz(a.angular)) * a.invInertia.w
                           + length(PhysicsMath.xyz(b.angular)) * b.invInertia.w) * p.grid.w
            let manifold = shapes.collide(a, b, margin: p.grid.y + closing)
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
        }
    }

    // MARK: Colours

    /// A pair's priority in the colouring: a hash of its entry (Physics.metal physPairPriority), so that neighbours
    /// numbered in a row (a sorted pile) don't wait on each other one at a time; the entry breaks ties.
    @inline(__always) static func priority(_ e: UInt32) -> UInt64 {
        var x = e &* 0x9E37_79B1
        x ^= x >> 16
        x &*= 0x85EB_CA6B
        x ^= x >> 13
        return UInt64(x) << 32 | UInt64(e)
    }

    /// The owned pairs with contacts in colours, once a step, no two of a colour sharing a body (the contacts reach as
    /// far as a pair can close in a step, so a pair without any meets in none of its refreshes either). Jones-Plassmann:
    /// in each round, every pair outranking the uncoloured pairs it shares a body with takes the lowest colour none of
    /// those it shares a body with has (at most 31: a pair shares its bodies with 30 others at most). What
    /// `maxRounds` rounds leave (pad = `leftover`) is solved one pair after another, after the colours.
    private func colourPairs() {
        let k = PhysicsWorld.maxPairs, entries = pairs.count, n = bodies.count, fractured = fractures
        var left: [Int32] = [], oneSided: [Int32] = []
        var won = [UInt8](repeating: 0, count: entries)
        withStepBuffers { s in
            // The pairs with contacts their owner keeps, in entry order (one-sided ones left over from the start).
            for e in 0..<entries {
                let mark = s.pairs[e].pad
                s.pairs[e].pad = PhysicsWorld.none
                guard e % k < Int(s.pairCounts[e / k]) && s.pairs[e].link == UInt32(e) && s.pairs[e].contacts > 0 else { continue }
                if mark == PhysicsWorld.oneSided {
                    s.pairs[e].pad = PhysicsWorld.leftover
                    oneSided.append(Int32(e))
                } else {
                    left.append(Int32(e))
                }
            }
            /// The pairs with contacts beside pair e (through either body), e itself among them, each through `visit`.
            @inline(__always) func around(_ e: Int, _ visit: (Int) -> Bool) -> Bool {
                let code = s.pairs[e].partner
                for body in 0..<2 {
                    guard body == 0 || code & PhysicsWorld.staticBit == 0 else { break }
                    let i = body == 0 ? e / k : Int(code)
                    for m in 0..<Int(s.pairCounts[i]) {
                        let link = s.pairs[i * k + m].link
                        guard link != PhysicsWorld.none && s.pairs[Int(link)].contacts > 0 else { continue }
                        if !visit(Int(link)) { return false }
                    }
                }
                return true
            }
            var rounds = 0
            won.withUnsafeMutableBufferPointer { won in
                while !left.isEmpty && rounds < PhysicsWorld.maxRounds {
                    left.withUnsafeBufferPointer { left in
                        // Who outranks every uncoloured pair beside it (winners never share a body)...
                        PhysicsPool.shared.parallel(left.count, grain: 256) { range in
                            for t in range {
                                let e = Int(left[t]), mine = PhysicsWorld.priority(UInt32(e))
                                won[e] = around(e) { q in q == e || s.pairs[q].pad != PhysicsWorld.none || PhysicsWorld.priority(UInt32(q)) < mine } ? 1 : 0
                            }
                        }
                        // ...takes the lowest colour none beside it has.
                        PhysicsPool.shared.parallel(left.count, grain: 256) { range in
                            for t in range where won[Int(left[t])] != 0 {
                                let e = Int(left[t])
                                var used: UInt64 = 0
                                _ = around(e) { q in
                                    if q != e && s.pairs[q].pad != PhysicsWorld.none { used |= 1 << UInt64(s.pairs[q].pad) }
                                    return true
                                }
                                s.pairs[e].pad = UInt32((~used).trailingZeroBitCount)
                            }
                        }
                    }
                    left.removeAll { s.pairs[Int($0)].pad != PhysicsWorld.none }
                    rounds += 1
                }
            }
            for e in left { s.pairs[Int(e)].pad = PhysicsWorld.leftover }
            if !oneSided.isEmpty { left = (left + oneSided).sorted() }   // (in entry order, as the GPU's one thread takes them)
            // The colours' pairs in entry order, colour by colour (one counting pass).
            var counts = [Int](repeating: 0, count: PhysicsWorld.maxColours + 1)
            var colours = 0
            for e in 0..<entries {
                let pad = s.pairs[e].pad
                guard pad < UInt32(PhysicsWorld.maxColours) else { continue }
                counts[Int(pad)] += 1
                colours = max(colours, Int(pad) + 1)
            }
            pairColourStarts.removeAll(keepingCapacity: true)
            pairColourStarts.append(0)
            var at = 0
            for c in 0..<colours {
                at += counts[c]
                pairColourStarts.append(UInt32(at))
            }
            pairOrder.removeAll(keepingCapacity: true)
            pairOrder.append(contentsOf: repeatElement(0, count: at))
            var cursor = [Int](repeating: 0, count: colours)
            for c in 0..<colours { cursor[c] = Int(pairColourStarts[c]) }
            for e in 0..<entries {
                let pad = s.pairs[e].pad
                guard pad < UInt32(colours) else { continue }
                pairOrder[cursor[Int(pad)]] = UInt32(e)
                cursor[Int(pad)] += 1
            }
            if fractured {
                // The left-over pairs, the one-sided ones most of all, in more colours (in entry order, each body in
                // each at most once), as the GPU's thread 0 colours them; what is left after those, one after another.
                var used = [UInt32](repeating: 0, count: n), more = [[Int32]](repeating: [], count: PhysicsWorld.maxColours)
                var rest: [Int32] = []
                for e32 in left {
                    let e = Int(e32), i = e / k, code = s.pairs[e].partner, both = code & PhysicsWorld.staticBit == 0
                    let taken = used[i] | (both ? used[Int(code)] : 0)
                    guard taken != .max else { rest.append(e32); continue }
                    let c = (~taken).trailingZeroBitCount
                    used[i] |= 1 << c
                    if both { used[Int(code)] |= 1 << c }
                    s.pairs[e].pad = UInt32(PhysicsWorld.maxColours + c)
                    more[c].append(e32)
                }
                for group in more where !group.isEmpty {
                    for e in group { pairOrder.append(UInt32(e)) }
                    pairColourStarts.append(UInt32(pairOrder.count))
                }
                left = rest
            }
            for e in left { pairOrder.append(UInt32(e)) }   // the rest: one after another
            pairColourStarts.append(UInt32(pairOrder.count))
        }
    }

    // MARK: Substeps

    @inline(__always) static func moves(_ b: GPUPhysicsBody) -> Bool {
        b.position.w > 0 && b.info.y & (PhysicsWorld.asleep | PhysicsWorld.disabledBit) == 0
    }
    @inline(__always) static func disabled(_ b: GPUPhysicsBody) -> Bool { b.info.y & PhysicsWorld.disabledBit != 0 }
    /// An anchored piece the ground still holds (it moves only once it comes free).
    @inline(__always) static func held(_ b: GPUPhysicsBody) -> Bool { b.info.y & PhysicsWorld.anchoredBit != 0 && b.position.w == 0 }

    /// Every moving body by its velocity and gravity; the held one (`grab`) woken, slowed and pulled to the target;
    /// a kinematic body to where its table puts it at the end of substep `sub` (PhysicsFlesh.swift).
    private func integrate(_ p: GPUPhysicsParams, sub: Int) {
        let h = p.gravity.w, n = bodies.count, grab = self.grab, step = stepIndex, rows = kinematicRows
        withStepBuffers { s in
            PhysicsPool.shared.parallel(n, grain: 128) { range in
                for i in range {
                    if PhysicsWorld.kinematic(s.bodies[i]) {
                        guard rows > 0 else { continue }
                        PhysicsWorld.moveKinematic(&s.bodies[i], to: kinematicPose(s.bodies[i], step: step, alpha: Float(sub + 1) / p.softDamping.z), h: h)
                        continue
                    }
                    let held = grab.target.w > 0 && grab.body == UInt32(i)
                    if held {
                        s.bodies[i].info.y &= ~PhysicsWorld.asleep
                        s.bodies[i].prevPosition.w = 0
                    }
                    guard PhysicsWorld.moves(s.bodies[i]) else { continue }
                    var b = s.bodies[i]
                    b.prevPosition = SIMD4(PhysicsMath.xyz(b.position), b.prevPosition.w)
                    b.prevRotation = b.rotation
                    let decay: Float = held ? max(1 - PhysicsWorld.holdDamping * h, 0) : 1
                    b.angular = SIMD4(PhysicsMath.xyz(b.angular) * decay, b.angular.w)
                    var v = PhysicsMath.xyz(b.velocity) * decay + PhysicsMath.xyz(p.gravity) * h
                    let speed = length(v)
                    if speed > p.grid.z { v *= p.grid.z / speed }
                    b.velocity = SIMD4(v, b.velocity.w)
                    b.position = SIMD4(PhysicsMath.xyz(b.position) + v * h, b.position.w)
                    b.rotation = PhysicsMath.qturn(b.rotation, PhysicsMath.xyz(b.angular) * h)
                    if held { PhysicsWorld.hold(&b, grab) }
                    s.bodies[i] = b
                }
            }
        }
    }

    /// The held body's anchor a fraction (`holdPull`) of the way to the target, shared between moving and turning
    /// it by its inverse mass and inertia there (as a contact's push is): a body held off its centre swings and hangs.
    @inline(__always) static func hold(_ b: inout GPUPhysicsBody, _ g: GPUPhysicsGrab) {
        let r = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(g.anchor))
        let gap = PhysicsMath.xyz(g.target) - (PhysicsMath.xyz(b.position) + r)
        let l = length(gap)
        guard l > 1e-7 else { return }
        let n = gap / l
        let w = weight(b, r, n)
        guard w > 0 else { return }
        shove(&b, n * (l * holdPull / w), r)
    }

    /// A contact's world points and lever arms (from each centre of mass) for the poses given.
    @inline(__always) static func points(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, previous: Bool = false)
        -> (pa: SIMD3<Float>, pb: SIMD3<Float>, ra: SIMD3<Float>, rb: SIMD3<Float>) {
        let n = PhysicsMath.xyz(c.normal)
        // (A kinematic body went somewhere too: a ball on a moving arm slides on it only as far as the arm left it.)
        let am = previous && (moves(a) || kinematic(a)), bm = previous && (moves(b) || kinematic(b))
        let xa = PhysicsMath.xyz(am ? a.prevPosition : a.position)
        let xb = PhysicsMath.xyz(bm ? b.prevPosition : b.position)
        let ra = PhysicsMath.qrot(am ? a.prevRotation : a.rotation, PhysicsMath.xyz(c.anchorA)) - n * c.anchorA.w
        let rb = PhysicsMath.qrot(bm ? b.prevRotation : b.rotation, PhysicsMath.xyz(c.anchorB)) + n * c.anchorB.w
        return (xa + ra, xb + rb, ra, rb)
    }

    /// The generalised inverse mass of body `b` at lever arm `r` along `n` (0 for one that doesn't move).
    @inline(__always) static func weight(_ b: GPUPhysicsBody, _ r: SIMD3<Float>, _ n: SIMD3<Float>) -> Float {
        guard moves(b) else { return 0 }
        let rn = cross(r, n)
        return b.position.w + dot(rn, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), rn))
    }

    /// A contact's position correction: its normal push (lambda) and, if static friction holds it, its tangential one
    /// (the impulse on A; B takes the opposite), and the normal speed before it. The same numbers for both bodies.
    @inline(__always) static func contactPush(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, h: Float)
        -> (impulse: SIMD3<Float>, lambda: Float, speed: Float, ra: SIMD3<Float>, rb: SIMD3<Float>) {
        let n = PhysicsMath.xyz(c.normal)
        let (pa, pb, ra, rb) = points(c, a, b)
        let va = PhysicsMath.xyz(a.velocity) + cross(PhysicsMath.xyz(a.angular), ra)
        let vb = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), rb)
        let speed = dot(va - vb, n)
        // A deep overlap (bodies placed into each other, or a fast hit) comes apart at no more than `pushSpeed`: what
        // the push moves a body becomes its velocity, and a whole overlap in one substep would fling it.
        let depth = max(dot(pa - pb, n), -PhysicsWorld.pushSpeed * h)
        guard depth < 0 else { return (.zero, 0, speed, ra, rb) }
        let w = weight(a, ra, n) + weight(b, rb, n)
        guard w > 0 else { return (.zero, 0, speed, ra, rb) }
        let lambda = -depth / w
        var impulse = n * lambda
        // Static friction: undo how far the two points slid past each other this substep, if it takes no more than
        // friction x the normal push.
        let (qa, qb, _, _) = points(c, a, b, previous: true)
        let slide = (pa - qa) - (pb - qb)
        let tangent = slide - n * dot(slide, n)
        let l = length(tangent)
        if l > 1e-7 {
            let t = tangent / l
            let wt = weight(a, ra, t) + weight(b, rb, t)
            let friction = sqrt(a.velocity.w * b.velocity.w)
            if wt > 0 && l / wt < friction * lambda { impulse -= t * (l / wt) }
        }
        return (impulse, lambda, speed, ra, rb)
    }

    /// Moves body `b` (if it moves) by `impulse` at lever arm `r`.
    @inline(__always) static func shove(_ b: inout GPUPhysicsBody, _ impulse: SIMD3<Float>, _ r: SIMD3<Float>) {
        guard moves(b) else { return }
        b.position = SIMD4(PhysicsMath.xyz(b.position) + impulse * b.position.w, b.position.w)
        b.rotation = PhysicsMath.qturn(b.rotation, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), cross(r, impulse)))
    }

    /// Speeds body `b` (if it moves) up by `impulse` at lever arm `r` and angular impulse `twist`.
    @inline(__always) static func kick(_ b: inout GPUPhysicsBody, _ impulse: SIMD3<Float>, _ r: SIMD3<Float>, _ twist: SIMD3<Float>) {
        guard moves(b) else { return }
        b.velocity = SIMD4(PhysicsMath.xyz(b.velocity) + impulse * b.position.w, b.velocity.w)
        b.angular = SIMD4(PhysicsMath.xyz(b.angular)
                          + PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), cross(r, impulse) + twist), b.angular.w)
    }

    /// Pair `e`'s contacts' pushes, one after the other, each on both bodies at once.
    @inline(__always) static func pushPair(_ e: Int, _ s: StepBuffers, h: Float) {
        let i = e / PhysicsWorld.maxPairs, code = s.pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = s.bodies[i], b = s.partner(code)
        for c in 0..<Int(s.pairs[e].contacts) {
            let ci = e * PhysicsWorld.maxContacts + c
            let push = PhysicsWorld.contactPush(s.contacts[ci], a, b, h: h)
            s.contacts[ci].lambda = SIMD4(push.lambda, push.speed, 0, 0)
            guard push.lambda > 0 else { continue }
            PhysicsWorld.shove(&a, push.impulse, push.ra)
            PhysicsWorld.shove(&b, -push.impulse, push.rb)
        }
        s.bodies[i] = a
        if dynamic { s.bodies[Int(code)] = b }
    }

    /// Pair `e`'s contacts' kicks.
    @inline(__always) static func kickPair(_ e: Int, _ s: StepBuffers, _ p: GPUPhysicsParams) {
        let i = e / PhysicsWorld.maxPairs, code = s.pairs[e].partner, dynamic = code & PhysicsWorld.staticBit == 0
        var a = s.bodies[i], b = s.partner(code)
        for c in 0..<Int(s.pairs[e].contacts) {
            guard let kick = PhysicsWorld.contactKick(s.contacts[e * PhysicsWorld.maxContacts + c], a, b, p) else { continue }
            PhysicsWorld.kick(&a, kick.impulse, kick.ra, kick.twist)
            PhysicsWorld.kick(&b, -kick.impulse, kick.rb, -kick.twist)
        }
        s.bodies[i] = a
        if dynamic { s.bodies[Int(code)] = b }
    }

    /// The pairs in `pairOrder`, a colour at a time: a colour's pairs (no two sharing a body) on every core, the
    /// rest (the last run of `pairColourStarts`) one after another, in order.
    private func eachColour(_ s: StepBuffers, _ solve: (Int) -> Void) {
        let starts = pairColourStarts, runs = starts.count - 1
        pairOrder.withUnsafeBufferPointer { order in
            for g in 0..<runs {
                let lo = Int(starts[g]), hi = Int(starts[g + 1])
                if g == runs - 1 {
                    for t in lo..<hi { solve(Int(order[t])) }
                } else {
                    PhysicsPool.shared.parallel(hi - lo, grain: 32) { range in
                        for t in range { solve(Int(order[lo + t])) }
                    }
                }
            }
        }
    }

    /// Joint colour by colour (a colour's joints share no body), each joint's two bodies through `solve`.
    private func eachJointColour(_ s: StepBuffers, _ solve: (GPUPhysicsJoint, inout GPUPhysicsBody, inout GPUPhysicsBody) -> Void) {
        let starts = jointStarts
        joints.withUnsafeBufferPointer { joints in
            for c in 0..<(starts.count - 1) {
                let lo = Int(starts[c]), hi = Int(starts[c + 1])
                PhysicsPool.shared.parallel(hi - lo, grain: 32) { range in
                    for t in range {
                        let j = joints[lo + t], ia = Int(j.info.x), ib = Int(j.info.y)
                        var a = s.bodies[ia], b = s.bodies[ib]
                        solve(j, &a, &b)
                        s.bodies[ia] = a
                        s.bodies[ib] = b
                    }
                }
            }
        }
    }

    /// The joints, then the contacts' pushes, a colour at a time, then every moving body's velocities from how far it went.
    private func solvePositions(_ p: GPUPhysicsParams) {
        let h = p.gravity.w, fractured = fractures, substeps = Float(self.substeps), n = bodies.count
        withStepBuffers { s in
            // The joints first, a colour at a time (twice: PhysicsWorld.jointIterations), then the contacts: static
            // friction undoes what the substep slid a contact, the joints' pushes included. (Joints after the contacts
            // slid a resting ragdoll's chest a little every substep, out of friction's reach: it crept and never slept.)
            for _ in 0..<PhysicsWorld.jointIterations {
                eachJointColour(s) { j, a, b in PhysicsWorld.solveJoint(j, &a, &b) }
            }
            if fractured {
                eachColour(s) { e in PhysicsWorld.pushFracturePair(e, s, h: h, substeps: substeps) }
            } else {
                eachColour(s) { e in PhysicsWorld.pushPair(e, s, h: h) }
            }
            PhysicsPool.shared.parallel(n, grain: 128) { range in
                for i in range where PhysicsWorld.moves(s.bodies[i]) {
                    var b = s.bodies[i]
                    b.velocity = SIMD4((PhysicsMath.xyz(b.position) - PhysicsMath.xyz(b.prevPosition)) / h, b.velocity.w)
                    var dq = PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(b.prevRotation))
                    if dq.w < 0 { dq = -dq }
                    b.angular = SIMD4(2 * PhysicsMath.xyz(dq) / h, b.angular.w)
                    s.bodies[i] = b
                }
            }
        }
    }

    /// The generalised inverse inertia of body `b` about axis `k` (0 for one that doesn't move).
    @inline(__always) static func turnWeight(_ b: GPUPhysicsBody, _ k: SIMD3<Float>) -> Float {
        moves(b) ? dot(k, PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), k)) : 0
    }

    /// A contact's velocity change: dynamic friction against the sliding, and restitution (none for slow impacts);
    /// and its angular impulse (on A; B takes the opposite) against rolling and spinning on the spot, each held back by
    /// at most its resistance (a length) x the normal impulse.
    @inline(__always) static func contactKick(_ c: GPUPhysicsContact, _ a: GPUPhysicsBody, _ b: GPUPhysicsBody, _ p: GPUPhysicsParams)
        -> (impulse: SIMD3<Float>, twist: SIMD3<Float>, ra: SIMD3<Float>, rb: SIMD3<Float>)? {
        let lambda = c.lambda.x
        guard lambda > 0 else { return nil }
        let n = PhysicsMath.xyz(c.normal), h = p.gravity.w
        let (_, _, ra, rb) = points(c, a, b)
        let va = PhysicsMath.xyz(a.velocity) + cross(PhysicsMath.xyz(a.angular), ra)
        let vb = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), rb)
        let v = va - vb
        let vn = dot(v, n)
        let vt = v - n * vn
        var dv = SIMD3<Float>()
        let slide = length(vt)
        if slide > 1e-6 {
            // Coulomb: the sliding slows by at most friction x the normal speed the push gave (lambda w / h).
            let friction = sqrt(a.velocity.w * b.velocity.w)
            let pushed = lambda * (weight(a, ra, n) + weight(b, rb, n)) / h
            dv -= vt / slide * min(friction * pushed, slide)
        }
        let before = c.lambda.y
        let e = abs(before) <= 2 * length(PhysicsMath.xyz(p.gravity)) * h ? 0 : max(a.angular.w, b.angular.w)
        dv += n * (-vn + max(-e * before, 0))
        var impulse = SIMD3<Float>()
        let l = length(dv)
        if l > 1e-7 {
            let w = weight(a, ra, dv / l) + weight(b, rb, dv / l)
            if w > 0 { impulse = dv / w }
        }
        // Rolling and spinning: the relative turn across the normal and about it, each stopped by an angular impulse
        // of up to resistance x the normal impulse (lambda / h).
        var twist = SIMD3<Float>()
        let spin = PhysicsMath.xyz(a.angular) - PhysicsMath.xyz(b.angular)
        let about = n * dot(spin, n)
        for k in 0..<2 {
            let part = k == 0 ? spin - about : about, resistance = k == 0 ? p.rolling.x : p.rolling.y
            let speed = length(part)
            guard speed > 1e-6 else { continue }
            let axis = part / speed
            let w = turnWeight(a, axis) + turnWeight(b, axis)
            guard w > 0 else { continue }
            twist -= axis * min(speed / w, resistance * lambda / h)
        }
        guard impulse != .zero || twist != .zero else { return nil }
        return (impulse, twist, ra, rb)
    }

    /// The contacts' velocity changes, a colour of pairs at a time.
    private func solveVelocities(_ p: GPUPhysicsParams) {
        let fractured = fractures
        withStepBuffers { s in
            if fractured {
                eachColour(s) { e in PhysicsWorld.kickFracturePair(e, s, p) }
            } else {
                eachColour(s) { e in PhysicsWorld.kickPair(e, s, p) }
            }
            eachJointColour(s) { j, a, b in PhysicsWorld.dampJoint(j, &a, &b, h: p.gravity.w) }
        }
    }

    // MARK: Joints

    /// Turns `a` by `correction` (an angle times an axis) and `b` by its opposite, shared by their inverse inertia
    /// about the axis (an XPBD angular constraint of no compliance).
    @inline(__always) static func swivel(_ a: inout GPUPhysicsBody, _ b: inout GPUPhysicsBody, _ correction: SIMD3<Float>) {
        let angle = length(correction)
        guard angle > 1e-7 else { return }
        let k = correction / angle
        let w = turnWeight(a, k) + turnWeight(b, k)
        guard w > 0 else { return }
        let impulse = k * (angle / w)
        if moves(a) { a.rotation = PhysicsMath.qturn(a.rotation, PhysicsMath.applyInvInertia(a.rotation, PhysicsMath.xyz(a.invInertia), impulse)) }
        if moves(b) { b.rotation = PhysicsMath.qturn(b.rotation, -PhysicsMath.applyInvInertia(b.rotation, PhysicsMath.xyz(b.invInertia), impulse)) }
    }

    /// The turn of A about `n` that brings the angle from `n1` (A's) to `n2` (B's) about `n` back within [lo, hi].
    @inline(__always) static func limitAngle(_ n: SIMD3<Float>, _ n1: SIMD3<Float>, _ n2: SIMD3<Float>, _ lo: Float, _ hi: Float) -> SIMD3<Float> {
        let phi = atan2(dot(cross(n1, n2), n), dot(n1, n2))
        return n * (phi - min(max(phi, lo), hi))
    }

    /// `v` less its part along unit `n`, as a unit vector (0 if nothing is left).
    @inline(__always) static func across(_ v: SIMD3<Float>, _ n: SIMD3<Float>) -> SIMD3<Float> {
        let u = v - n * dot(v, n)
        let l = length(u)
        return l > 1e-6 ? u / l : .zero
    }

    /// Joint `j` between `a` and `b` (Müller et al. 2020): the turn limits (a ball joint's swing cone and twist; a
    /// hinge's axes together and its angle), then the anchors together.
    @inline(__always) static func solveJoint(_ j: GPUPhysicsJoint, _ a: inout GPUPhysicsBody, _ b: inout GPUPhysicsBody) {
        guard moves(a) || moves(b) else { return }
        let lo = j.axisA.w, hi = j.axisB.w
        var axisA = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.axisA)), axisB = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.axisB))
        let bend = cross(axisA, axisB), sine = length(bend)
        if j.info.z == PhysicsJointKind.hinge.rawValue {
            if sine > 1e-6 { swivel(&a, &b, bend / sine * atan2(sine, dot(axisA, axisB))) }
            axisA = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.axisA))
            let n1 = across(PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.referenceA)), axisA)
            let n2 = across(PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.referenceB)), axisA)
            swivel(&a, &b, limitAngle(axisA, n1, n2, lo, hi))
        } else {
            let swing = atan2(sine, dot(axisA, axisB))
            if sine > 1e-6 && swing > j.referenceA.w { swivel(&a, &b, bend / sine * (swing - j.referenceA.w)) }
            axisA = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.axisA))
            axisB = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.axisB))
            let mid = axisA + axisB, l = length(mid)
            if l > 1e-6 {
                let n = mid / l
                let n1 = across(PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.referenceA)), n)
                let n2 = across(PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.referenceB)), n)
                swivel(&a, &b, limitAngle(n, n1, n2, lo, hi))
            }
        }
        let ra = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.anchorA)), rb = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.anchorB))
        let gap = (PhysicsMath.xyz(b.position) + rb) - (PhysicsMath.xyz(a.position) + ra)
        let l = length(gap)
        guard l > 1e-7 else { return }
        let n = gap / l
        let w = weight(a, ra, n) + weight(b, rb, n)
        guard w > 0 else { return }
        shove(&a, n * (l / w), ra)
        shove(&b, -n * (l / w), rb)
    }

    /// Body `b`'s inverse inertia about axis `k` through the point at lever arm `r` (from its centre): what turning
    /// it about a joint's anchor takes, its mass going round the anchor included (0 for one that doesn't move).
    @inline(__always) static func anchorTurnWeight(_ b: GPUPhysicsBody, _ k: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
        let w = turnWeight(b, k)
        guard w > 0 else { return 0 }
        return 1 / (1 / w + length_squared(cross(k, r)) / b.position.w)
    }

    /// Joint `j`'s damping: the two bodies' relative turning fades at its rate, each turned about the anchor (its
    /// velocity with it) by an angular impulse shared by their inertia about it. (Slowing only their turning about
    /// their centres hardly slowed a head swinging on its neck: the joint gave the turning back from how its centre
    /// still went round the anchor.)
    @inline(__always) static func dampJoint(_ j: GPUPhysicsJoint, _ a: inout GPUPhysicsBody, _ b: inout GPUPhysicsBody, h: Float) {
        let relative = PhysicsMath.xyz(b.angular) - PhysicsMath.xyz(a.angular)
        let speed = length(relative)
        guard speed > 1e-6 else { return }
        let k = relative / speed
        let ra = PhysicsMath.qrot(a.rotation, PhysicsMath.xyz(j.anchorA)), rb = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(j.anchorB))
        let wa = anchorTurnWeight(a, k, ra), wb = anchorTurnWeight(b, k, rb)
        guard wa + wb > 0 else { return }
        let impulse = speed * min(j.referenceB.w * h, 1) / (wa + wb)
        if wa > 0 {
            let turn = k * (impulse * wa)
            a.angular = SIMD4(PhysicsMath.xyz(a.angular) + turn, a.angular.w)
            a.velocity = SIMD4(PhysicsMath.xyz(a.velocity) - cross(turn, ra), a.velocity.w)
        }
        if wb > 0 {
            let turn = -k * (impulse * wb)
            b.angular = SIMD4(PhysicsMath.xyz(b.angular) + turn, b.angular.w)
            b.velocity = SIMD4(PhysicsMath.xyz(b.velocity) - cross(turn, rb), b.velocity.w)
        }
    }

    /// Whether body `b` went slower than the sleep speed this step, and turned its mass slower than the sleep turn (its
    /// turn x its radius of gyration about the turn's axis, at most `gyration`), from `position` and `rotation` (where its velocities say
    /// little: at rest on a few contacts they are what the last substep's kicks left, which the next substep's pushes
    /// take back).
    @inline(__always) static func still(_ b: GPUPhysicsBody, _ position: SIMD4<Float>, _ rotation: SIMD4<Float>,
                                        _ p: GPUPhysicsParams) -> Bool {
        let moved = length(PhysicsMath.xyz(b.position) - PhysicsMath.xyz(position))
        let turn = PhysicsMath.xyz(PhysicsMath.qmul(b.rotation, PhysicsMath.qconj(rotation)))
        let sine = length(turn)
        guard moved < p.sleep.x * p.grid.w else { return false }
        guard sine > 1e-9 else { return true }
        let w = turnWeight(b, turn / sine)
        return w <= 0 || 2 * sine * min(sqrt(b.position.w / w), gyration) < p.sleep.y * p.grid.w
    }

    /// After the substeps: a body that has been slow for long enough falls asleep, once the bodies it touches (has
    /// contacts with) have been slow for half as long (or sleep): a pile goes to sleep together, not one body propped on moving ones.
    private func settle(_ p: GPUPhysicsParams, _ start: [SIMD8<Float>]) {
        let n = bodies.count, k = PhysicsWorld.maxPairs
        wakeFlags.removeAll(keepingCapacity: true)
        wakeFlags.append(contentsOf: repeatElement(0, count: n))
        wakeFlags.withUnsafeMutableBufferPointer { sleeps in
            start.withUnsafeBufferPointer { start in
                withStepBuffers { s in
                    // The timers...
                    PhysicsPool.shared.parallel(n, grain: 128) { range in
                        for i in range where PhysicsWorld.moves(s.bodies[i]) {
                            let b = s.bodies[i]
                            s.bodies[i].prevPosition.w = PhysicsWorld.still(b, start[i].lowHalf, start[i].highHalf, p) ? b.prevPosition.w + p.grid.w : 0
                        }
                    }
                    // ...then who may sleep (reading the timers only)...
                    PhysicsPool.shared.parallel(n, grain: 64) { range in
                        for i in range where PhysicsWorld.moves(s.bodies[i]) && s.bodies[i].prevPosition.w > p.sleep.z {
                            var settled = true
                            for m in 0..<Int(s.pairCounts[i]) {
                                let e = i * k + m, partner = s.pairs[e].partner, link = s.pairs[e].link
                                guard partner & PhysicsWorld.staticBit == 0, link != PhysicsWorld.none, s.pairs[Int(link)].contacts > 0 else { continue }
                                let o = s.bodies[Int(partner)]
                                if PhysicsWorld.moves(o) && o.prevPosition.w <= p.sleep.z / 2 { settled = false; break }
                            }
                            sleeps[i] = settled ? 1 : 0
                        }
                    }
                }
            }
            // A ragdoll sleeps whole: while any of its moving bodies can't, none does (one asleep would hold its joints).
            for r in ragdolls {
                let range = Int(r.x)..<Int(r.x + r.y)
                if range.contains(where: { PhysicsWorld.moves(bodies[$0]) && sleeps[$0] == 0 }) { for i in range { sleeps[i] = 0 } }
            }
            // ...and they sleep.
            withStepBuffers { s in
                PhysicsPool.shared.parallel(n, grain: 256) { range in
                    for i in range where sleeps[i] != 0 {
                        s.bodies[i].info.y |= PhysicsWorld.asleep
                        s.bodies[i].velocity = SIMD4(.zero, s.bodies[i].velocity.w)
                        s.bodies[i].angular = SIMD4(.zero, s.bodies[i].angular.w)
                    }
                }
            }
        }
    }

    // MARK: Particles

    /// A particle's reach this step: its radius, as far as it goes (at up to the particle speed), and the margin.
    @inline(__always) static func particleReach(_ q: GPUPhysicsParticle, _ p: GPUPhysicsParams) -> Float {
        q.position.w + min(length(PhysicsMath.xyz(q.velocity)), p.particleGrid.y) * p.grid.w + p.grid.y
    }

    /// Every particle's neighbours (the nearest `maxNeighbours` within reach, the lower first of equals) and the
    /// colliders it may touch (statics, then bodies, the lowest `maxColliders`).
    private func particleBroadPhase(_ p: GPUPhysicsParams) {
        let size = p.particleGrid.x, k = PhysicsWorld.maxNeighbours, kc = PhysicsWorld.maxColliders
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for (i, q) in particles.enumerated() { grid[PhysicsWorld.cell(PhysicsMath.xyz(q.position), size), default: []].append(i) }
        for (i, q) in particles.enumerated() {
            let x = PhysicsMath.xyz(q.position), r = PhysicsWorld.particleReach(q, p)
            let c = PhysicsWorld.cell(x, size)
            var found: [(Float, UInt32)] = []
            for dz: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dx: Int32 in -1...1 {
                        for j in grid[c &+ SIMD3(dx, dy, dz)] ?? [] where j != i {
                            let o = particles[j]
                            if !PhysicsWorld.meets(q, o) { continue }   // cloths only meet colliders, a soft body not itself
                            let reach = r + PhysicsWorld.particleReach(o, p)
                            let d2 = length_squared(PhysicsMath.xyz(o.position) - x)
                            if d2 < reach * reach { found.append((d2, UInt32(j))) }
                        }
                    }
                }
            }
            found.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
            neighbourCounts[i] = UInt32(min(found.count, k))
            for (n, f) in found.prefix(k).enumerated() { neighbours[i * k + n] = f.1 }
            var touching: [UInt32] = []
            for s in statics.indices where touchesStatic(s, centre: x, radius: r) { touching.append(UInt32(s) | PhysicsWorld.staticBit) }
            // (A figure's flesh and skin don't meet its own bones: info.z = their first << 8 | how many.)
            let soft = q.info.y & PhysicsWorld.softBit != 0
            let own = soft ? Int(q.info.z >> 8)..<Int((q.info.z >> 8) + (q.info.z & 0xFF)) : 0..<0
            for (j, b) in bodies.enumerated() where !own.contains(j) && !PhysicsWorld.disabled(b) {
                let reach = r + PhysicsWorld.reach(b, p)
                if length_squared(PhysicsMath.xyz(b.position) - x) < reach * reach { touching.append(UInt32(j)) }
            }
            touching.sort { ($0 ^ PhysicsWorld.staticBit) < ($1 ^ PhysicsWorld.staticBit) }
            colliderCounts[i] = UInt32(min(touching.count, kc))
            for (n, code) in touching.prefix(kc).enumerated() { colliders[i * kc + n] = code }
        }
    }

    private func integrateParticles(_ p: GPUPhysicsParams) {
        let h = p.gravity.w
        for i in particles.indices where particles[i].prevPosition.w > 0 {   // (a pinned cloth vertex stays)
            var q = particles[i]
            q.prevPosition = SIMD4(PhysicsMath.xyz(q.position), q.prevPosition.w)
            let rate = q.info.y & PhysicsWorld.clothBit != 0 ? p.particleGrid.z : q.info.y & PhysicsWorld.softBit != 0 ? p.softDamping.x : 0
            let drag = max(1 - rate * h, 0)
            var v = PhysicsMath.xyz(q.velocity) * drag + PhysicsMath.xyz(p.gravity) * h
            let speed = length(v)
            if speed > p.grid.z { v *= p.grid.z / speed }
            q.velocity = SIMD4(v, q.velocity.w)
            q.position = SIMD4(PhysicsMath.xyz(q.position) + v * h, q.position.w)
            particles[i] = q
        }
    }

    /// A push of `overlap` along `n` less the sliding friction holds back: all of `slide`'s tangential part while it
    /// is under friction x the overlap (static), otherwise that much of it (dynamic).
    @inline(__always) static func particlePush(_ n: SIMD3<Float>, _ overlap: Float, _ slide: SIMD3<Float>, _ friction: Float) -> SIMD3<Float> {
        var push = n * overlap
        let tangent = slide - n * dot(slide, n)
        let l = length(tangent)
        if l > 1e-7 { push -= tangent * min(friction * overlap / l, 1) }
        return push
    }

    /// Whether a particle that went `moved` this substep stays put (PhysicsCPU.solveParticles).
    @inline(__always) static func rests(_ q: GPUPhysicsParticle, touching: Bool, shoved: Bool, moved: SIMD3<Float>,
                                        _ p: GPUPhysicsParams) -> Bool {
        touching && !shoved && q.info.y & (clothBit | softBit) == 0 && length(moved) < p.particleGrid.w * p.gravity.w
    }

    /// Each particle's pushes (Jacobi): its neighbours' overlaps, shared by mass and averaged, and the colliders' in
    /// full (they don't give), averaged too; then its velocity from how far it went. A soft body's particle takes both
    /// summed, and faster (`softPushSpeed`): its links hold it among its own, and averaged pushes let a body shove it
    /// in, or a jelly on top sink into it.
    private func solveParticles(_ p: GPUPhysicsParams) {
        let h = p.gravity.w, k = PhysicsWorld.maxNeighbours, kc = PhysicsWorld.maxColliders
        let before = particles
        for i in before.indices where before[i].prevPosition.w > 0 {
            let q = before[i]
            let x = PhysicsMath.xyz(q.position), moved = x - PhysicsMath.xyz(q.prevPosition), w = q.prevPosition.w
            let soft = q.info.y & PhysicsWorld.softBit != 0
            let cap = (soft ? PhysicsWorld.softPushSpeed : PhysicsWorld.pushSpeed) * h
            var shared = SIMD3<Float>(), sharedCount: Float = 0
            for n in 0..<Int(neighbourCounts[i]) {
                let o = before[Int(neighbours[i * k + n])]
                let d = x - PhysicsMath.xyz(o.position)
                let dist = length(d)
                let overlap = min(q.position.w + o.position.w - dist, cap)
                guard overlap > 0, dist > 1e-6 else { continue }
                let share = w / (w + o.prevPosition.w)
                let slide = moved - (PhysicsMath.xyz(o.position) - PhysicsMath.xyz(o.prevPosition))
                shared += PhysicsWorld.particlePush(d / dist, overlap, slide, sqrt(q.velocity.w * o.velocity.w)) * share
                sharedCount += 1
            }
            var held = SIMD3<Float>(), heldCount: Float = 0, shoved = false
            for n in 0..<Int(colliderCounts[i]) {
                let b = partner(colliders[i * kc + n])
                let pose = Pose(b), shape = Int(b.info.x)
                let local = pose.toBody(x)
                let depth = distance(shape: shape, local) - q.position.w
                guard depth < 0 else { continue }
                let normal = pose.direction(gradient(shape: shape, local))
                let surface = PhysicsMath.xyz(b.velocity) + cross(PhysicsMath.xyz(b.angular), x - pose.position)
                held += PhysicsWorld.particlePush(normal, min(-depth, cap), moved - surface * h,
                                                  sqrt(q.velocity.w * b.velocity.w))
                heldCount += 1
                shoved = shoved || PhysicsWorld.moves(b)
            }
            var out = q
            var y = x
            if sharedCount > 0 { y += soft ? shared : shared / sharedCount }
            if heldCount > 0 { y += soft ? held : held / heldCount }
            // At rest: a particle in a heap (no body shoving it, not a cloth's or a soft body's) that went slower than
            // the rest speed stays where it was (Macklin et al. 2014's sleeping); the averaged pushes otherwise keep a
            // heap fizzing.
            if PhysicsWorld.rests(q, touching: sharedCount + heldCount > 0, shoved: shoved, moved: y - PhysicsMath.xyz(q.prevPosition), p) {
                y = PhysicsMath.xyz(q.prevPosition)
            }
            out.position = SIMD4(y, q.position.w)
            out.velocity = SIMD4((y - PhysicsMath.xyz(q.prevPosition)) / h, q.velocity.w)
            particles[i] = out
        }
    }

    /// The cloths' and soft bodies' links, a colour at a time (Gauss-Seidel: each sees what the colours before it
    /// moved), each an XPBD distance constraint (one iteration a substep, so its lambda starts at 0); a soft body's
    /// with Macklin et al. 2016's damping of what moves along it.
    private func solveCloth(_ p: GPUPhysicsParams) {
        let h = p.gravity.w
        for c in 0..<(colourStarts.count - 1) {
            for k in Int(colourStarts[c])..<Int(colourStarts[c + 1]) {
                let con = constraints[k]
                let a = Int(con.a), b = Int(con.b)
                let wa = particles[a].prevPosition.w, wb = particles[b].prevPosition.w
                guard wa + wb > 0 else { continue }
                let d = PhysicsMath.xyz(particles[a].position) - PhysicsMath.xyz(particles[b].position)
                let l = length(d)
                guard l > 1e-9 else { continue }
                let n = d / l
                let gamma = particles[a].info.y & PhysicsWorld.softBit != 0 ? con.compliance * p.softDamping.y / h : 0
                let moved = dot(n, PhysicsMath.xyz(particles[a].position - particles[a].prevPosition)
                                   - PhysicsMath.xyz(particles[b].position - particles[b].prevPosition))
                let lambda = (-(l - con.rest) - gamma * moved) / ((1 + gamma) * (wa + wb) + con.compliance / (h * h))
                let push = n * lambda
                particles[a].position += SIMD4(push * wa, 0)
                particles[b].position -= SIMD4(push * wb, 0)
            }
        }
    }
}
