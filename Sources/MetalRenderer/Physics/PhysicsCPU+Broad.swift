import EngineCore
import Foundation
import Plants
import simd
import CPhysicsAtomics

extension PhysicsWorld {
    // MARK: Broad phase

    /// A body's bounding sphere for this step: its radius, as far as it may go (at up to the cell speed), and the margin.
    @inline(__always) static func reach(_ b: GPUPhysicsBody, _ p: GPUPhysicsParams) -> Float {
        b.invInertia.w + min(length(PhysicsMath.xyz(b.velocity)), p.sleep.w) * p.grid.w + p.grid.y
    }

    /// With fractured objects (physBoxGap): how far apart bodies a and b's boxes are (`fa`, `fb`, in the world; `ha`,
    /// `hb` their half sizes), each grown by its margin `ma`, `mb` (their reach past their size); the largest gap
    /// along the 15 axes that could part two boxes, negative when they overlap (a gap of zero or more as soon as an
    /// axis parts them: not the largest).
    @inline(__always) static func boxGap(_ fa: PhysicsBoxFrame, _ ha: SIMD4<Float>, _ ma: Float,
                                         _ fb: PhysicsBoxFrame, _ hb: SIMD4<Float>, _ mb: Float) -> Float {
        let ax = (fa.x, fa.y, fa.z), bx = (fb.x, fb.y, fb.z)
        @inline(__always) func axis(_ t: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), _ k: Int) -> SIMD3<Float> {
            k == 0 ? t.0 : k == 1 ? t.1 : t.2
        }
        let ea = PhysicsMath.xyz(ha) + ma, eb = PhysicsMath.xyz(hb) + mb
        let t = fb.centre - fa.centre
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
            if gap >= 0 { return gap }   // (apart: the broad phase keeps only overlaps, how far apart doesn't matter)
        }
        return gap
    }

    @inline(__always) static func cell(_ x: SIMD3<Float>, _ size: Float) -> SIMD3<Int32> {
        let c = (x / size).rounded(.down)
        return SIMD3(Int32(c.x), Int32(c.y), Int32(c.z))   // (SIMD3<Int32>(c) converts through the generic path)
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

    /// Every body's partners: the static colliders it meets, then the bodies whose spheres meet its own, nearest first
    /// (the lower first of equals), `maxPairs` at most: a crowded body drops its farthest bodies, never what holds it
    /// up. Two bodies a joint joins aren't partners (they overlap where it is). (Keeping the lowest-numbered instead, a
    /// tower's middle blocks dropped a body dragged into them, which went through.) The grid is built here; each body's
    /// query on every core.
    ///
    /// The grid has levels of cells, each twice the size of the one before (`bodyLevels`), and a body is in the first
    /// whose cells are twice as big as its reach can be; one too big for the last is in none (`bigBodies`), and every
    /// body looks at those. A body's query takes the cells of each level within its reach and the largest reach of
    /// that level's bodies. The same partners as one grid sized by the largest body (the GPU's, `params.grid.x`):
    /// every body within reach of another is found either way, and the nearest are kept by a total order. (A
    /// fractured object's whole is a body the size of the object: sized by it, a building's cells held a storey each.
    /// Sized by the largest of the pieces, a cell of a heap held hundreds.)
    ///
    /// A body whose partners can't have changed keeps the last step's (BroadMemo): a settled heap's sleepers. Three
    /// buildings at 25 s, 6,152 pieces and 500 awake: 5.1 → 3.1 ms a step. One a changed body reaches, or whose
    /// partner changed, takes theirs from the last step's and the changed bodies (memoPartners).
    func broadPhase(_ p: GPUPhysicsParams) {
        let levels = bodyLevels(), n = bodies.count
        // Who isn't as the last step's broad phase read it (BroadMemo), in a grid of their own.
        let fixed = SIMD4(p.sleep.w, p.grid.w, p.grid.y, 0)
        let valid = broadEpoch == shapeEpoch && broadStatics == staticsVersion && broadParams == fixed && broadSeen.count == n
        if broadSeen.count != n {
            broadSeen = [SIMD16<UInt32>](repeating: .zero, count: n)
            broadChanged = [UInt8](repeating: 1, count: n)
        }
        (broadEpoch, broadStatics, broadParams) = (shapeEpoch, staticsVersion, fixed)
        var changedUsed: UInt32 = 0
        bodies.withUnsafeBufferPointer { b in
            broadSeen.withUnsafeMutableBufferPointer { seen in
                broadChanged.withUnsafeMutableBufferPointer { changed in
                    PhysicsPool.shared.parallel(n, grain: 256) { range in
                        for i in range {
                            let key = BroadMemo.key(b[i])
                            changed[i] = valid && key == seen[i] ? 0 : 1
                            seen[i] = key
                        }
                    }
                }
            }
            bodyCells.build(b.count) { i in
                guard !PhysicsWorld.disabled(b[i]) else { return nil }
                let level = levels.level(b[i])
                guard level < PhysicsLevels.most else { return nil }
                return SIMD4(PhysicsWorld.cell(PhysicsMath.xyz(b[i].position), levels.size(level)), Int32(level))
            }
            changedBodies.removeAll(keepingCapacity: true)
            changedBigs.removeAll(keepingCapacity: true)
            if valid {
                for i in 0..<n where broadChanged[i] != 0 && !PhysicsWorld.disabled(b[i]) {
                    let level = levels.level(b[i])
                    if level < PhysicsLevels.most {
                        changedBodies.append(Int32(i))
                        changedUsed |= 1 << UInt32(level)
                    } else {
                        changedBigs.append(Int32(i))
                    }
                }
            }
            let moved = changedBodies
            changedCells.build(moved.count) { t in
                let i = Int(moved[t]), level = levels.level(b[i])
                return SIMD4(PhysicsWorld.cell(PhysicsMath.xyz(b[i].position), levels.size(level)), Int32(level))
            }
        }
        // Each grid item's body's position and reach, in the grid's order (a query's first test, on what it reads
        // in a row), and with fractured objects each body's box's axes and centre in the world (their gaps'): the
        // same numbers consider and boxGap worked out, once a step. (Three buildings settling: 1.7 million items and
        // 150,000 gaps a step.)
        let byGap = fractures, boxes = shapeBoxes
        bodyCells.withView { grid in
            let count = grid.items.count
            if broadItems.count < count { broadItems.append(contentsOf: repeatElement(.zero, count: count - broadItems.count)) }
            if byGap && broadFrames.count != n { broadFrames = [PhysicsBoxFrame](repeating: PhysicsBoxFrame(), count: n) }
            bodies.withUnsafeBufferPointer { b in
                broadItems.withUnsafeMutableBufferPointer { items in
                    PhysicsPool.shared.parallel(count, grain: 256) { range in
                        for m in range {
                            let o = b[grid.item(m)]
                            items[m] = SIMD4(PhysicsMath.xyz(o.position), PhysicsWorld.reach(o, p))
                        }
                    }
                }
                guard byGap else { return }
                boxes.withUnsafeBufferPointer { boxes in
                    broadFrames.withUnsafeMutableBufferPointer { frames in
                        PhysicsPool.shared.parallel(n, grain: 256) { range in
                            for i in range where !PhysicsWorld.disabled(b[i]) {
                                frames[i] = PhysicsBoxFrame(b[i], boxes[2 * Int(b[i].info.x)])
                            }
                        }
                    }
                }
            }
        }
        let shapes = self.shapes, staticBounds = self.staticBounds, used = changedUsed
        if broadKeys.count != pairs.count { broadKeys = [Float](repeating: 0, count: pairs.count) }
        broadKeys.withUnsafeMutableBufferPointer { keys in
        bodyCells.withView { grid in
        broadItems.withUnsafeBufferPointer { items in
        broadFrames.withUnsafeBufferPointer { frames in
            changedCells.withView { cells in
                bigBodies.withUnsafeBufferPointer { bigs in
                    broadChanged.withUnsafeBufferPointer { changed in
                        changedBodies.withUnsafeBufferPointer { moved in
                            changedBigs.withUnsafeBufferPointer { movedBigs in
                                let memo = valid ? BroadMemo(changed: changed, cells: cells, used: used, bodies: moved, bigs: movedBigs) : nil
                                withStepBuffers { s in
                                    PhysicsPool.shared.parallel(n, grain: 32) { range in
                                        withUnsafeTemporaryAllocation(of: (Float, UInt32).self, capacity: PhysicsWorld.maxPairs) { kept in
                                            for i in range {
                                                if let memo, PhysicsWorld.memoPartners(i, s, levels, p, memo, keys, frames, boxes,
                                                                                        byGap: byGap, kept: kept) { continue }
                                                PhysicsWorld.partners(i, s, grid, items, frames, levels, bigs, shapes, boxes, staticBounds, p,
                                                                      byGap: byGap, kept: kept, keys: keys)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        }
        }
        }
    }

    /// Whether body i's partners follow from the last step's (BroadMemo), and if so they are written as `partners`
    /// writes them. Body i is as it was: so is every body it was a partner of, or wasn't, but those that changed. Its
    /// candidates now are last step's that didn't change, and the changed bodies that pass `consider` now. Last step's
    /// list (`keys`: each partner's key, nearest first) held all its candidates then if it wasn't full, so its
    /// partners now are the nearest `maxPairs` of its unchanged ones and those changed ones; if it was full, and none
    /// of its partners changed, the candidates it dropped are still farther than all of them, so the same holds. A
    /// full list losing a partner that changed takes a whole query (the next nearest could be any it dropped).
    @inline(__always) static func memoPartners(_ i: Int, _ s: StepBuffers, _ levels: PhysicsLevels, _ p: GPUPhysicsParams,
                                               _ memo: BroadMemo, _ keys: UnsafeMutableBufferPointer<Float>,
                                               _ frames: UnsafeBufferPointer<PhysicsBoxFrame>, _ boxes: [SIMD4<Float>], byGap: Bool,
                                               kept: UnsafeMutableBufferPointer<(Float, UInt32)>) -> Bool {
        guard memo.changed[i] == 0 else { return false }
        let k = PhysicsWorld.maxPairs, last = Int(s.pairCounts[i])
        var gone = false
        for m in 0..<last {
            let code = s.pairs[i * k + m].partner
            if code & PhysicsWorld.staticBit == 0 && memo.changed[Int(code)] != 0 { gone = true }
        }
        if gone && last == k { return false }
        var count = 0
        for m in 0..<last {
            let code = s.pairs[i * k + m].partner
            if code & PhysicsWorld.staticBit == 0 && memo.changed[Int(code)] != 0 { continue }
            PhysicsWorld.keep(keys[i * k + m], code, kept, &count)
        }
        let b = s.bodies[i]
        if !PhysicsWorld.disabled(b) {
            let x = PhysicsMath.xyz(b.position), r = PhysicsWorld.reach(b, p)
            var used = memo.used
            while used != 0 {
                let level = used.trailingZeroBitCount
                used &= used - 1
                let size = levels.size(level), far = (r + size / 2) * 1.0001 + 1e-4   // (as partners' query)
                let lo = PhysicsWorld.cell(x - far, size), hi = PhysicsWorld.cell(x + far, size)
                for cz in lo.z...hi.z {
                    for cy in lo.y...hi.y {
                        for cx in lo.x...hi.x {
                            for t in memo.cells.cell(SIMD4(cx, cy, cz, Int32(level))) {
                                let j = Int(memo.bodies[memo.cells.item(t)]), o = s.bodies[j]
                                PhysicsWorld.consider(j, SIMD4(PhysicsMath.xyz(o.position), PhysicsWorld.reach(o, p)), i, b, x, r, s, frames, boxes,
                                                      p, byGap: byGap, kept: kept, &count)
                            }
                        }
                    }
                }
            }
            for j32 in memo.bigs {
                let j = Int(j32), o = s.bodies[j]
                PhysicsWorld.consider(j, SIMD4(PhysicsMath.xyz(o.position), PhysicsWorld.reach(o, p)), i, b, x, r, s, frames, boxes, p,
                                      byGap: byGap, kept: kept, &count)
            }
        }
        s.pairCounts[i] = UInt32(count)
        for n in 0..<count {
            s.pairs[i * k + n] = GPUPhysicsPair(partner: kept[n].1)
            keys[i * k + n] = kept[n].0
        }
        return true
    }

    /// The levels of the broad phase's grid this step (broadPhase), from the enabled bodies: the first's cells twice
    /// the reach a body of their mean radius can have; and the bodies too big for the last (`bigBodies`).
    private func bodyLevels() -> PhysicsLevels {
        var sum: Double = 0, enabled = 0
        for b in bodies where !PhysicsWorld.disabled(b) {
            sum += Double(b.invInertia.w)
            enabled += 1
        }
        let mean = enabled > 0 ? Float(sum / Double(enabled)) : 1
        var levels = PhysicsLevels(first: 2 * PhysicsLevels.most(max(mean, 0.01)), used: 0)
        bigBodies.removeAll(keepingCapacity: true)
        for (i, b) in bodies.enumerated() where !PhysicsWorld.disabled(b) {
            let level = levels.level(b)
            if level < PhysicsLevels.most { levels.used |= 1 << UInt32(level) } else { bigBodies.append(Int32(i)) }
        }
        return levels
    }

    /// Body i's partners (broadPhase), kept nearest first in `kept` as they are found (the same `maxPairs` as sorting
    /// them all: the order is total, and no partner is found twice): from each level's cells within reach, and the
    /// big bodies.
    @inline(__always) static func partners(_ i: Int, _ s: StepBuffers, _ grid: PhysicsCellGrid.View, _ items: UnsafeBufferPointer<SIMD4<Float>>,
                                           _ frames: UnsafeBufferPointer<PhysicsBoxFrame>, _ levels: PhysicsLevels,
                                           _ bigs: UnsafeBufferPointer<Int32>, _ shapes: [GPUPhysicsShape],
                                           _ boxes: [SIMD4<Float>], _ staticBounds: [AABB], _ p: GPUPhysicsParams, byGap: Bool,
                                           kept: UnsafeMutableBufferPointer<(Float, UInt32)>, keys: UnsafeMutableBufferPointer<Float>) {
        let k = PhysicsWorld.maxPairs
        let b = s.bodies[i]
        if PhysicsWorld.disabled(b) { s.pairCounts[i] = 0; return }   // (it is in no cell: nothing finds it either)
        let x = PhysicsMath.xyz(b.position), r = PhysicsWorld.reach(b, p)
        var count = 0
        var used = levels.used
        while used != 0 {
            let level = used.trailingZeroBitCount
            used &= used - 1
            // (A body of this level reaches half its cell at most; a little over, for the rounding of d2.)
            let size = levels.size(level), far = (r + size / 2) * 1.0001 + 1e-4
            let lo = PhysicsWorld.cell(x - far, size), hi = PhysicsWorld.cell(x + far, size)
            for cz in lo.z...hi.z {
                for cy in lo.y...hi.y {
                    for cx in lo.x...hi.x {
                        for m in grid.cell(SIMD4(cx, cy, cz, Int32(level))) {
                            PhysicsWorld.consider(grid.item(m), items[m], i, b, x, r, s, frames, boxes, p, byGap: byGap, kept: kept, &count)
                        }
                    }
                }
            }
        }
        for j in bigs {
            let o = s.bodies[Int(j)]
            PhysicsWorld.consider(Int(j), SIMD4(PhysicsMath.xyz(o.position), PhysicsWorld.reach(o, p)), i, b, x, r, s, frames, boxes, p,
                                  byGap: byGap, kept: kept, &count)
        }
        if !PhysicsWorld.kinematic(b) {
            for st in s.statics.indices where PhysicsWorld.touchesStatic(s.statics[st], shapes, staticBounds[st], centre: x, radius: r) {
                PhysicsWorld.keep(byGap ? -.infinity : -1, UInt32(st) | PhysicsWorld.staticBit, kept, &count)
            }
        }
        s.pairCounts[i] = UInt32(count)
        for n in 0..<count {
            s.pairs[i * k + n] = GPUPhysicsPair(partner: kept[n].1)
            keys[i * k + n] = kept[n].0   // (memoPartners')
        }
    }

    /// Body j as body i's partner (partners), if their spheres meet (with fractured objects, their boxes too): `at`,
    /// its position and reach (broadItems); `frames`, the bodies' boxes in the world (broadFrames).
    @inline(__always) static func consider(_ j: Int, _ at: SIMD4<Float>, _ i: Int, _ b: GPUPhysicsBody, _ x: SIMD3<Float>, _ r: Float,
                                           _ s: StepBuffers, _ frames: UnsafeBufferPointer<PhysicsBoxFrame>, _ boxes: [SIMD4<Float>],
                                           _ p: GPUPhysicsParams, byGap: Bool, kept: UnsafeMutableBufferPointer<(Float, UInt32)>,
                                           _ count: inout Int) {
        // (The spheres first: most items fail it, and it needs only `at`. The tests are all a pair must pass, in
        // any order.)
        let reach = r + at.w
        let d2 = PhysicsWorld.distance2(PhysicsMath.xyz(at), x)
        guard d2 < reach * reach else { return }
        guard j != i && !PhysicsWorld.joined(b, i, s.bodies[j], j) else { return }
        let o = s.bodies[j]
        if PhysicsWorld.kinematic(b) && PhysicsWorld.kinematic(o) { return }   // neither gives
        if PhysicsWorld.held(b) && PhysicsWorld.held(o) { return }             // two anchored pieces
        // (Distance squared, -1 for a static; partner. With fractured objects, the gap between their boxes, those
        // that overlap, -infinity for a static: physPairs.)
        guard byGap else { keep(d2, UInt32(j), kept, &count); return }
        let sa = Int(b.info.x), sb = Int(o.info.x)
        let gap = PhysicsWorld.boxGap(frames[i], boxes[2 * sa + 1], r - b.invInertia.w, frames[j], boxes[2 * sb + 1], at.w - o.invInertia.w)
        if gap < 0 { keep(gap, UInt32(j), kept, &count) }
    }

    /// (`key`, `id`) into `kept` (`count` of them so far, `maxPairs` at most), nearest first.
    @inline(__always) static func keep(_ key: Float, _ id: UInt32, _ kept: UnsafeMutableBufferPointer<(Float, UInt32)>, _ count: inout Int) {
        let k = PhysicsWorld.maxPairs
        if count == k && !(key < kept[k - 1].0 || (key == kept[k - 1].0 && id < kept[k - 1].1)) { return }
        var at = min(count, k - 1)
        while at > 0 && (key < kept[at - 1].0 || (key == kept[at - 1].0 && id < kept[at - 1].1)) {
            kept[at] = kept[at - 1]
            at -= 1
        }
        kept[at] = (key, id)
        count = min(count + 1, k)
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

    /// With fractured objects (wake): whether moving body `o`, which went at `motion` over the last step, wakes a
    /// sleeper it touches: faster than the wake speed or turn over the step (not at the last substep's speeds, which
    /// a heap's solve leaves jittering). Rubble (`rubble`) wakes only for a hit (`rubbleWake` times that), a partner
    /// moving on (it left where its still time began soon after it began, `motion.z`), or one under it (`below`)
    /// leaving its place at all (`motion.w`): about 44 of a settled heap's pieces rock past the wake speed each step,
    /// in place, and they woke 900 pieces a second; but what rests on a piece that slides off slowly must come too
    /// (woken all at once, a heap whose sleepers had stayed put on their supports' last places moved 9 cm).
    @inline(__always) static func rubbleStirs(_ o: GPUPhysicsBody, _ motion: SIMD4<Float>, rubble: Bool, below: Bool, _ p: GPUPhysicsParams) -> Bool {
        guard moves(o), motion.x > p.rolling.z || motion.y > p.rolling.w else { return false }
        return !rubble || (below && motion.w != 0) || motion.z != 0 || motion.x > rubbleWake * p.rolling.z || motion.y > rubbleWake * p.rolling.w
    }

    /// Whether body b (body i, `initial` its first pose) is rubble: a piece more than `fallen` from where it began,
    /// what came down, welded or not. A structure still standing, or sagging on its way down, sleeps and wakes as
    /// before (a collapse starts slowly).
    @inline(__always) static func rubble(_ b: GPUPhysicsBody, _ initial: GPUPhysicsBody) -> Bool {
        b.info.y & pieceBit != 0 && distance2(PhysicsMath.xyz(b.position), PhysicsMath.xyz(initial.position)) > fallen * fallen
    }

    func wake(_ p: GPUPhysicsParams) {
        let n = bodies.count, heaps = fractures
        wakeFlags.removeAll(keepingCapacity: true)
        wakeFlags.append(contentsOf: repeatElement(0, count: n))
        if heaps && stepMotion.count != n { stepMotion = [SIMD4<Float>](repeating: .zero, count: n) }
        // Who wakes, from the bodies as they were (a body woken here stirs nothing: its speeds are a sleeper's 0)...
        stepMotion.withUnsafeBufferPointer { motion in
        initialBodies.withUnsafeBufferPointer { initial in
        wakeFlags.withUnsafeMutableBufferPointer { flags in
            withStepBuffers { s in
                PhysicsPool.shared.parallel(n, grain: 64) { range in
                    for i in range where s.bodies[i].info.y & PhysicsWorld.asleep != 0 {
                        let rubble = heaps && PhysicsWorld.rubble(s.bodies[i], initial[i])
                        for m in 0..<Int(s.pairCounts[i]) {
                            let partner = s.pairs[i * PhysicsWorld.maxPairs + m].partner
                            guard partner & PhysicsWorld.staticBit == 0 else { continue }
                            let o = s.bodies[Int(partner)]
                            let stirs = heaps && !PhysicsWorld.kinematic(o)
                                ? PhysicsWorld.rubbleStirs(o, motion[Int(partner)], rubble: rubble,
                                                           below: o.position.y < s.bodies[i].position.y, p) : PhysicsWorld.stirs(o, p)
                            guard stirs else { continue }
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
    func link() {
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
}
