import EngineCore
import Foundation
import simd
import CPhysicsAtomics

extension PhysicsWorld {
    // MARK: Colours

    /// A pair's priority in the colouring: a hash of its entry (Physics.metal physPairPriority), so that neighbours
    /// numbered in a row (a sorted pile) don't wait on each other one at a time; the entry breaks ties.
    @inline(__always) package static func priority(_ e: UInt32) -> UInt64 {
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
    package func colourPairs() {
        let k = PhysicsWorld.maxPairs, entries = pairs.count, n = bodies.count, fractured = fractures, idleWelds = self.idleWelds
        let held = grab.target.w > 0 ? grab.body : PhysicsWorld.none
        var left: [Int32] = [], oneSided: [Int32] = []
        var won = [UInt8](repeating: 0, count: entries)
        withStepBuffers { s in
            // The pairs with contacts their owner keeps, in entry order (one-sided ones left over from the start).
            // With fractured objects, not a pair neither of whose bodies moves (a heap asleep: PhysicsWorld.idle).
            // Marked on every core (in `won`: 1 to colour, 2 one-sided), then gathered in order.
            won.withUnsafeMutableBufferPointer { kind in
                PhysicsPool.shared.parallel(n, grain: 64) { range in
                    for i in range {
                        let count = Int(s.pairCounts[i])
                        for m in 0..<k {
                            let e = i * k + m, mark = s.pairs[e].pad
                            s.pairs[e].pad = PhysicsWorld.none
                            guard m < count && s.pairs[e].link == UInt32(e) && s.pairs[e].contacts > 0 else { continue }
                            if fractured && PhysicsWorld.idle(s, e, held: held, welds: idleWelds) { s.pairs[e].pad = PhysicsWorld.idlePair; continue }
                            if mark == PhysicsWorld.oneSided {
                                s.pairs[e].pad = PhysicsWorld.leftover
                                kind[e] = 2
                            } else {
                                kind[e] = 1
                            }
                        }
                    }
                }
            }
            for i in 0..<n {
                for m in 0..<Int(s.pairCounts[i]) where won[i * k + m] != 0 {
                    if won[i * k + m] == 2 { oneSided.append(Int32(i * k + m)) } else { left.append(Int32(i * k + m)) }
                }
            }
            let candidates = left
            // Those pairs, all of them in entry order: the refreshes' (narrowPhase).
            pairEntries.removeAll(keepingCapacity: true)
            var c = 0, o = 0
            while c < left.count || o < oneSided.count {
                if o == oneSided.count || c < left.count && left[c] < oneSided[o] { pairEntries.append(left[c]); c += 1 } else { pairEntries.append(oneSided[o]); o += 1 }
            }
            // Each candidate's neighbours: the pairs with contacts beside it (through either body), but itself, as
            // the rounds read them (`adjacent`, `maxNeighbours` apart; the same each round: links, contacts and the
            // idle pairs don't change while they run).
            let roundGrain = 256, wide = 2 * k, listed = candidates.count
            if pairAdjacent.count < listed * wide { pairAdjacent.append(contentsOf: repeatElement(0, count: listed * wide - pairAdjacent.count)) }
            if pairNeighbours.count < listed { pairNeighbours.append(contentsOf: repeatElement(0, count: listed - pairNeighbours.count)) }
            var rounds = 0
            candidates.withUnsafeBufferPointer { candidates in
            pairAdjacent.withUnsafeMutableBufferPointer { adjacent in
            pairNeighbours.withUnsafeMutableBufferPointer { neighbours in
                PhysicsPool.shared.parallel(listed, grain: roundGrain) { range in
                    for c in range {
                        let e = Int(candidates[c]), code = s.pairs[e].partner
                        var count = 0
                        for body in 0..<2 {
                            guard body == 0 || code & PhysicsWorld.staticBit == 0 else { break }
                            let i = body == 0 ? e / k : Int(code)
                            for m in 0..<Int(s.pairCounts[i]) {
                                let link = s.pairs[i * k + m].link
                                guard link != PhysicsWorld.none && Int(link) != e && s.pairs[Int(link)].contacts > 0
                                        && s.pairs[Int(link)].pad != PhysicsWorld.idlePair else { continue }
                                adjacent[c * wide + count] = Int32(link)
                                count += 1
                            }
                        }
                        neighbours[c] = UInt8(count)
                    }
                }
                // The rounds over the candidates (by their place in `candidates`; `won` theirs).
                var open = [Int32](0..<Int32(listed))
                won.withUnsafeMutableBufferPointer { won in
                    while !open.isEmpty && rounds < PhysicsWorld.maxRounds {
                        open.withUnsafeBufferPointer { open in
                            // Who outranks every uncoloured pair beside it (winners never share a body)...
                            PhysicsPool.shared.parallel(open.count, grain: roundGrain) { range in
                                for t in range {
                                    let c = Int(open[t]), mine = PhysicsWorld.priority(UInt32(candidates[c]))
                                    var wins: UInt8 = 1
                                    for m in 0..<Int(neighbours[c]) {
                                        let q = Int(adjacent[c * wide + m])
                                        if !(s.pairs[q].pad != PhysicsWorld.none || PhysicsWorld.priority(UInt32(q)) < mine) { wins = 0; break }
                                    }
                                    won[c] = wins
                                }
                            }
                            // ...takes the lowest colour none beside it has.
                            PhysicsPool.shared.parallel(open.count, grain: roundGrain) { range in
                                for t in range where won[Int(open[t])] != 0 {
                                    let c = Int(open[t])
                                    var used: UInt64 = 0
                                    for m in 0..<Int(neighbours[c]) {
                                        let q = Int(adjacent[c * wide + m])
                                        if s.pairs[q].pad != PhysicsWorld.none { used |= 1 << UInt64(s.pairs[q].pad) }
                                    }
                                    s.pairs[Int(candidates[c])].pad = UInt32((~used).trailingZeroBitCount)
                                }
                            }
                        }
                        open.removeAll { s.pairs[Int(candidates[Int($0)])].pad != PhysicsWorld.none }
                        rounds += 1
                    }
                }
                left = open.map { candidates[Int($0)] }
            }
            }
            }
            for e in left { s.pairs[Int(e)].pad = PhysicsWorld.leftover }
            if !oneSided.isEmpty { left = (left + oneSided).sorted() }   // (in entry order, as the GPU's one thread takes them)
            // The colours' pairs in entry order, colour by colour (one counting pass).
            var counts = [Int](repeating: 0, count: PhysicsWorld.maxColours + 1)
            var colours = 0
            for e32 in candidates {   // (in entry order: the pairs the colours can have)
                let pad = s.pairs[Int(e32)].pad
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
            for e32 in candidates {
                let pad = s.pairs[Int(e32)].pad
                guard pad < UInt32(colours) else { continue }
                pairOrder[cursor[Int(pad)]] = UInt32(e32)
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
            // For eachColour: before each pair, where its bodies' last pairs are (those it waits on); how many it
            // waits on in a row at most (its depth: those it waits on have smaller ones); the pairs by depth
            // (`pairSchedule`, those of a depth in their order); and per pair the chunks before its own that hold
            // those it waits on (`pairWaits`: -1 for none; one in its own chunk is before it there).
            let total = pairOrder.count, grain = PhysicsWorld.colourGrain
            var last = [Int32](repeating: -1, count: n), before = [SIMD2<Int32>](repeating: SIMD2(-1, -1), count: total)
            var depth = [Int32](repeating: 0, count: total), depths = [Int](repeating: 0, count: 1)
            for t in 0..<total {
                let e = Int(pairOrder[t]), i = e / k, code = s.pairs[e].partner
                var wait = SIMD2<Int32>(last[i], -1)
                last[i] = Int32(t)
                if code & PhysicsWorld.staticBit == 0 {
                    wait.y = last[Int(code)]
                    last[Int(code)] = Int32(t)
                }
                before[t] = wait
                let d = max(wait.x >= 0 ? depth[Int(wait.x)] + 1 : 0, wait.y >= 0 ? depth[Int(wait.y)] + 1 : 0)
                depth[t] = d
                if Int(d) >= depths.count { depths.append(0) }
                depths[Int(d)] += 1
            }
            var place = 0
            let starts = depths.map { d -> Int in defer { place += d }; return place }
            for d in depths.indices { depths[d] = starts[d] }
            var slot = [Int32](repeating: 0, count: total)
            pairSchedule.removeAll(keepingCapacity: true)
            pairSchedule.append(contentsOf: repeatElement(0, count: total))
            for t in 0..<total {
                let u = depths[Int(depth[t])]
                depths[Int(depth[t])] += 1
                slot[t] = Int32(u)
                pairSchedule[u] = Int32(pairOrder[t])
            }
            pairWaits.removeAll(keepingCapacity: true)
            pairWaits.append(contentsOf: repeatElement(SIMD2(-1, -1), count: total))
            for t in 0..<total {
                let u = Int(slot[t]), own = Int32(u / grain), w = before[t]
                let x = w.x >= 0 ? slot[Int(w.x)] / Int32(grain) : -1, y = w.y >= 0 ? slot[Int(w.y)] / Int32(grain) : -1
                pairWaits[u] = SIMD2(x == own ? -1 : x, y == own ? -1 : y)
            }
            let flags = ((total + grain - 1) / grain) * PhysicsWorld.flagStride
            if pairDone.count < flags { pairDone.append(contentsOf: repeatElement(0, count: flags - pairDone.count)) }
        }
    }

    /// With fractured objects (colourPairs): pair `e` neither of whose bodies moves this step (asleep, held,
    /// kinematic, static; the held one, which its first substep wakes, moves), not a weld (it counts its load): its
    /// contacts push and kick nothing, so it takes no colour and isn't solved. A sleeping heap's pairs took colours,
    /// and each colour is a stage a substep.
    /// With `welds` (PhysicsWorld.idleWelds), a weld's pair too: one between two bodies that don't move does nothing
    /// (solveWeld, kickFracturePair pass it by) and needn't take a colour.
    @inline(__always) package static func idle(_ s: StepBuffers, _ e: Int, held: UInt32, welds: Bool) -> Bool {
        let i = e / maxPairs, code = s.pairs[e].partner
        if moves(s.bodies[i]) || UInt32(i) == held || (!welds && s.contacts[e * maxContacts].lambda.w == 1) { return false }
        return code & staticBit != 0 || !(moves(s.bodies[Int(code)]) || code == held)
    }
}
