import EngineCore
import Foundation
import simd

/// Cars against cars (Physics+Cars.swift's `solveCars`, after each car's own constraints, before its nodes' velocities):
/// each car's nodes against the other car's hull triangles (its body's and its parts'), and a car's parts that came off
/// against its body (and its body's nodes against them). Over buffers, nothing allocated (Tools/perf/hot-functions.txt).
///
/// Each substep, each car that meets another hashes its triangles into cells (`gridCar`: a triangle in every cell its
/// box, grown by `carReach`, is in). A node looks in its own cell's bucket, and the triangle there it is deepest in
/// (within `carSkin` in front of it, or behind its face having been in front a substep ago) pushes it out: the push
/// shared between the node and the triangle's three nodes by their masses (the triangle's at the point met, by its
/// weights), so what one car loses the other takes; held by friction as the ground holds a node; no more than the two
/// came together this substep and `pushSpeed` (a node found deep in the other hull isn't flung out). The pairs run a
/// colour at a time (`CarSystem.pairs`: no car twice in a colour), each colour's side by side, each pair's nodes in
/// a fixed order: the numbers don't depend on the cores.
extension CarSolver {
    /// Metal on metal.
    package static let carFriction: Float = 0.5
    /// How close (m) a node comes to another car's triangle, or its own car's (a part off): a panel's skin, the gap a
    /// part's nodes rest at outside the body (CarBlueprint.partGap). (At a node's radius, 6 cm, a part that came off
    /// started 4 cm in its body, and was flung off it at metres a second.)
    package static let carSkin: Float = CarBlueprint.partGap
    /// How far behind a triangle's face (m) a node that was in front of it a substep ago is still caught: two cars
    /// closing at 100 km/h come 2.9 cm nearer each substep, past the skin (a node through it at 50 + 50 km/h was
    /// missed, and the fronts went 24 cm into each other).
    package static let carReach: Float = 0.08

    @inline(__always) package static func gridKey(_ x: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>((x / CarSystem.gridCell).rounded(.down))
    }

    @inline(__always) package static func gridBucket(_ c: SIMD3<Int32>) -> Int {
        Int(UInt32(bitPattern: (c.x &* 73_856_093) ^ (c.y &* 19_349_663) ^ (c.z &* 83_492_791)) & UInt32(CarSystem.gridBuckets - 1))
    }

    /// Car `c`'s triangles into its hash (CarSystem.gridStarts, gridItems): counted into their buckets, the counts made
    /// starts, then each placed (a triangle once a bucket, though two of its cells share one).
    @inline(__always) package static func gridCar(_ c: Int, _ b: CarBuffers) {
        let s = b.cars[c], buckets = CarSystem.gridBuckets, starts = c * (buckets + 1)
        let base = Int(s.firstTriangle) * CarSystem.gridCells, r = carReach
        for k in starts..<(starts + buckets + 1) { b.gridStarts[k] = 0 }
        for pass in 0..<2 {
            for t in Int(s.firstTriangle)..<Int(s.firstTriangle + s.triangleCount) {
                let tri = b.triangles[t]
                let pa = PhysicsMath.xyz(b.particles[Int(tri.x)].position), pb = PhysicsMath.xyz(b.particles[Int(tri.y)].position)
                let pc = PhysicsMath.xyz(b.particles[Int(tri.z)].position)
                let c0 = gridKey(simd_min(simd_min(pa, pb), pc) - r), c1 = gridKey(simd_max(simd_max(pa, pb), pc) + r)
                var seen = SIMD64<Int32>(repeating: -1), n = 0
                for z in c0.z...c1.z {
                    for y in c0.y...c1.y {
                        for x in c0.x...c1.x where n < CarSystem.gridCells {
                            let k = gridBucket(SIMD3(x, y, z))
                            var known = false
                            for j in 0..<n where seen[j] == Int32(k) { known = true }
                            if known { continue }
                            seen[n] = Int32(k)
                            n += 1
                            if pass == 0 {
                                b.gridStarts[starts + k + 1] += 1
                            } else {
                                b.gridItems[base + Int(b.gridStarts[starts + k])] = UInt32(t)
                                b.gridStarts[starts + k] += 1
                            }
                        }
                    }
                }
            }
            if pass == 0 {
                for k in 1...buckets { b.gridStarts[starts + k] += b.gridStarts[starts + k - 1] }
            } else {
                // (Each start moved to its bucket's end, the next's start: back one.)
                for k in stride(from: buckets, to: 0, by: -1) { b.gridStarts[starts + k] = b.gridStarts[starts + k - 1] }
                b.gridStarts[starts] = 0
            }
        }
    }

    /// Pair `pair`'s contacts: each car's nodes against the other's triangles, which first turn about each substep
    /// (`sub`: the first's nodes, pushed out first, gave way less: two like cars head on crushed 0.81 and 0.58 m, and
    /// carried on together at 1 m/s); or (a car with itself) its parts that came off against the rest of it.
    @inline(__always) package static func meet(_ pair: SIMD2<Int32>, _ b: CarBuffers, _ h: Float, sub: Int) {
        let a = Int(pair.x), c = Int(pair.y)
        if a == c {
            nodesAgainst(a, a, b, h, own: true)
        } else {
            let (first, second) = sub & 1 == 0 ? (a, c) : (c, a)
            nodesAgainst(first, second, b, h, own: false)
            nodesAgainst(second, first, b, h, own: false)
        }
    }

    /// Car `nc`'s nodes against car `tc`'s triangles; `own` (the same car): a node of one part against a triangle of
    /// another, one of the two off.
    @inline(__always) package static func nodesAgainst(_ nc: Int, _ tc: Int, _ b: CarBuffers, _ h: Float, own: Bool) {
        let sn = b.cars[nc], st = b.cars[tc], buckets = CarSystem.gridBuckets
        let starts = tc * (buckets + 1), base = Int(st.firstTriangle) * CarSystem.gridCells
        for i in Int(sn.firstNode)..<Int(sn.firstNode + sn.nodeCount) {
            let x = PhysicsMath.xyz(b.particles[i].position)
            if any(x .< st.lo) || any(x .> st.hi) { continue }
            var nodePart = 0, nodeOff = false
            if own {
                nodePart = Int(b.nodeParts[i])
                nodeOff = nodePart > 0 && b.parts[Int(sn.firstPart) + nodePart - 1].flags & CarPart.off != 0
            }
            // (The deepest of the triangles it meets: the others round a corner it is near would each push it as far.)
            let k = gridBucket(gridKey(x))
            var deepest = -1, most: Float = 0
            for e in Int(b.gridStarts[starts + k])..<Int(b.gridStarts[starts + k + 1]) {
                let t = Int(b.gridItems[base + e]), tri = b.triangles[t]
                if own {
                    let triPart = Int(tri.w)
                    if triPart == nodePart { continue }
                    if !nodeOff && (triPart == 0 || b.parts[Int(st.firstPart) + triPart - 1].flags & CarPart.off == 0) { continue }
                }
                let depth = nodeDepth(i, tri, b)
                if depth > most { (deepest, most) = (t, depth) }
            }
            if deepest >= 0 { nodeTriangle(i, b.triangles[deepest], tc, b, h) }
        }
    }

    /// How deep node `i` is in triangle `tri` (nodeTriangle's test): 0 when they don't meet.
    @inline(__always) package static func nodeDepth(_ i: Int, _ tri: SIMD4<UInt32>, _ b: CarBuffers) -> Float {
        let q = b.particles[i], r = carSkin
        let x = PhysicsMath.xyz(q.position), xa = PhysicsMath.xyz(b.particles[Int(tri.x)].position)
        let xb = PhysicsMath.xyz(b.particles[Int(tri.y)].position), xc = PhysicsMath.xyz(b.particles[Int(tri.z)].position)
        let normal = cross(xb - xa, xc - xa), area = length(normal)
        guard area > 1e-8 else { return 0 }
        let w = closestWeights(x, xa, xb, xc), distance = length(x - (xa * w.x + xb * w.y + xc * w.z))
        let side = dot(x - xa, normal / area)
        if side >= 0 { return max(r - distance, 0) }
        guard distance <= -side + 1e-4, -side < carReach else { return 0 }
        let pa = PhysicsMath.xyz(b.particles[Int(tri.x)].prevPosition), pb = PhysicsMath.xyz(b.particles[Int(tri.y)].prevPosition)
        let pc = PhysicsMath.xyz(b.particles[Int(tri.z)].prevPosition)
        return dot(PhysicsMath.xyz(q.prevPosition) - pa, cross(pb - pa, pc - pa)) > 0 ? r - side : 0
    }

    /// Node `i` against triangle `tri` of car `tc`: pushed out to `carSkin` in front of it, the triangle's nodes
    /// back (`CarContacts.swift`'s top).
    @inline(__always) package static func nodeTriangle(_ i: Int, _ tri: SIMD4<UInt32>, _ tc: Int, _ b: CarBuffers, _ h: Float) {
        let ia = Int(tri.x), ib = Int(tri.y), ic = Int(tri.z)
        let q = b.particles[i], qa = b.particles[ia], qb = b.particles[ib], qc = b.particles[ic]
        let x = PhysicsMath.xyz(q.position), xa = PhysicsMath.xyz(qa.position), xb = PhysicsMath.xyz(qb.position), xc = PhysicsMath.xyz(qc.position)
        let r = carSkin
        var normal = cross(xb - xa, xc - xa)
        let area = length(normal)
        guard area > 1e-8 else { return }
        normal /= area
        let w = closestWeights(x, xa, xb, xc)
        let point = xa * w.x + xb * w.y + xc * w.z, apart = x - point, distance = length(apart)
        let side = dot(x - xa, normal)
        var n = normal, depth: Float
        if side >= 0 {
            guard distance < r else { return }
            if distance > 1e-6 { n = apart / distance }
            depth = r - distance
        } else {
            // Behind it: only through its face, having been in front a substep ago.
            guard distance <= -side + 1e-4, -side < carReach else { return }
            let pa = PhysicsMath.xyz(qa.prevPosition), pb = PhysicsMath.xyz(qb.prevPosition), pc = PhysicsMath.xyz(qc.prevPosition)
            let before = cross(pb - pa, pc - pa)
            guard dot(PhysicsMath.xyz(q.prevPosition) - pa, before) > 0 else { return }
            depth = r - side
        }
        let wn = q.prevPosition.w, wa = qa.prevPosition.w, wb = qb.prevPosition.w, wc = qc.prevPosition.w
        let weight = wn + w.x * w.x * wa + w.y * w.y * wb + w.z * w.z * wc
        guard weight > 0 else { return }
        // How the node went against the triangle's point this substep, and so how far it is pushed (as a node off the
        // ground: no more than they came together and pushSpeed), less what friction holds.
        let before = PhysicsMath.xyz(qa.prevPosition) * w.x + PhysicsMath.xyz(qb.prevPosition) * w.y + PhysicsMath.xyz(qc.prevPosition) * w.z
        let moved = (x - PhysicsMath.xyz(q.prevPosition)) - (point - before)
        let overlap = min(depth, max(-dot(moved, n), 0) + PhysicsWorld.pushSpeed * h)
        guard overlap > 0 else { return }
        let push = PhysicsWorld.particlePush(n, overlap, moved, carFriction) / weight
        b.particles[i].position = SIMD4(x + push * wn, q.position.w)
        b.particles[ia].position = SIMD4(xa - push * (w.x * wa), qa.position.w)
        b.particles[ib].position = SIMD4(xb - push * (w.y * wb), qb.position.w)
        b.particles[ic].position = SIMD4(xc - push * (w.z * wc), qc.position.w)
        b.wear[i] += sliding(moved, n, h)
        // A part frozen where it lies, met: woken next step (carBroadPhase).
        if wa == 0 || wb == 0 || wc == 0 {
            let part = Int(b.nodeParts[ia]), s = b.cars[tc]
            if part > 0 { b.partWake[Int(s.firstPart) + part - 1] = 1 }
        }
    }

    /// The weights of triangle (a, b, c)'s point nearest `p` (Ericson's closest point, its regions' weights).
    @inline(__always) package static func closestWeights(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = dot(ab, ap), d2 = dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return SIMD3(1, 0, 0) }
        let bp = p - b, d3 = dot(ab, bp), d4 = dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return SIMD3(0, 1, 0) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return SIMD3(1 - v, v, 0)
        }
        let cp = p - c, d5 = dot(ab, cp), d6 = dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return SIMD3(0, 0, 1) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let v = d2 / (d2 - d6)
            return SIMD3(1 - v, 0, v)
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 {
            let v = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return SIMD3(0, 1 - v, v)
        }
        let denom = 1 / (va + vb + vc), v = vb * denom, u = vc * denom
        return SIMD3(1 - v - u, v, u)
    }
}
