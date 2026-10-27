import EngineCore
import Foundation
import simd

/// Geometry as Houdini's is: points (a position `P` and attributes), primitives (a polygon, closed, or a polyline,
/// open) that are runs of vertices, a vertex a reference to a point with attributes of its own (a UV is a vertex's), and
/// the detail, the attributes of the whole. Flat arrays: a primitive is the range `primStart[p]..<primStart[p + 1]` of
/// `vertexPoint`; each class's attributes and groups are in its `AttributeTable`, as long as the class.
///
/// What a node of a network makes: a value type, so a cooked node's output is kept and handed on without copying until
/// a node changes it.
package struct ProcGeo: Equatable {
    package var P: [SIMD3<Float>] = []
    package var points = AttributeTable()
    package var vertexPoint: [Int32] = []
    package var vertices = AttributeTable()
    package var primStart: [Int32] = [0]
    package var primClosed: [Bool] = []
    package var prims = AttributeTable()
    package var detail = AttributeTable(count: 1)

    package init() {}

    /// Points, and primitives over them (each a list of point indices), closed polygons unless `closed` says not.
    package init(P: [SIMD3<Float>], prims list: [[Int32]], closed: [Bool]? = nil) {
        self.P = P
        for (i, p) in list.enumerated() {
            vertexPoint += p
            primStart.append(Int32(vertexPoint.count))
            primClosed.append(closed?[i] ?? true)
        }
        syncCounts()
    }

    package var pointCount: Int { P.count }
    package var vertexCount: Int { vertexPoint.count }
    package var primCount: Int { primStart.count - 1 }

    @inline(__always) package func vertexRange(_ p: Int) -> Range<Int> { Int(primStart[p])..<Int(primStart[p + 1]) }
    @inline(__always) package func primSize(_ p: Int) -> Int { Int(primStart[p + 1] - primStart[p]) }
    package func primPoints(_ p: Int) -> ArraySlice<Int32> { vertexPoint[vertexRange(p)] }

    /// Is the primitive a polygon (closed, three corners or more)?
    @inline(__always) package func isPolygon(_ p: Int) -> Bool { primClosed[p] && primSize(p) >= 3 }

    package func table(_ c: AttributeClass) -> AttributeTable {
        switch c {
        case .point: points
        case .vertex: vertices
        case .primitive: prims
        case .detail: detail
        }
    }

    package mutating func modify<R>(_ c: AttributeClass, _ body: (inout AttributeTable) throws -> R) rethrows -> R {
        switch c {
        case .point: try body(&points)
        case .vertex: try body(&vertices)
        case .primitive: try body(&prims)
        case .detail: try body(&detail)
        }
    }

    package func count(_ c: AttributeClass) -> Int {
        switch c {
        case .point: pointCount
        case .vertex: vertexCount
        case .primitive: primCount
        case .detail: 1
        }
    }

    /// Makes every table as long as its class (after the arrays were changed by hand): new rows get defaults.
    package mutating func syncCounts() {
        points.resize(P.count)
        vertices.resize(vertexPoint.count)
        prims.resize(primCount)
        detail.resize(1)
    }

    /// Adds a point (its attributes defaults): for nodes adding a few; many go into `P` at once, then `syncCounts`.
    @discardableResult
    package mutating func addPoint(_ p: SIMD3<Float>) -> Int32 {
        P.append(p)
        points.resize(P.count)
        return Int32(P.count - 1)
    }

    @discardableResult
    package mutating func addPrim(_ pts: [Int32], closed: Bool = true) -> Int {
        vertexPoint += pts
        primStart.append(Int32(vertexPoint.count))
        primClosed.append(closed)
        vertices.resize(vertexPoint.count)
        prims.resize(primCount)
        return primCount - 1
    }

    // MARK: Standard attributes

    /// A point attribute's values, or the vertex attribute's averaged onto points: Houdini's look-up order for `N`, `Cd`.
    package func pointVectors3(_ name: String) -> [SIMD3<Float>]? {
        if name == "P" { return P }
        return points.vectors3(name)
    }

    /// The primitive each vertex is of.
    package func vertexPrims() -> [Int32] {
        var out = [Int32](repeating: 0, count: vertexCount)
        for p in 0..<primCount { for v in vertexRange(p) { out[v] = Int32(p) } }
        return out
    }

    // MARK: Measures

    /// A polygon's normal (Newell's), zero if it is degenerate or not a polygon.
    package func primNormal(_ p: Int) -> SIMD3<Float> {
        guard isPolygon(p) else { return .zero }
        var n = SIMD3<Float>.zero
        let r = vertexRange(p)
        var prev = P[Int(vertexPoint[r.upperBound - 1])]
        for v in r {
            let q = P[Int(vertexPoint[v])]
            n += SIMD3((prev.y - q.y) * (prev.z + q.z), (prev.z - q.z) * (prev.x + q.x), (prev.x - q.x) * (prev.y + q.y))
            prev = q
        }
        let l = simd_length(n)
        return l > 0 ? n / l : .zero
    }

    package func primCenter(_ p: Int) -> SIMD3<Float> {
        let r = vertexRange(p)
        guard !r.isEmpty else { return .zero }
        var c = SIMD3<Float>.zero
        for v in r { c += P[Int(vertexPoint[v])] }
        return c / Float(r.count)
    }

    package func primArea(_ p: Int) -> Float {
        guard isPolygon(p) else { return 0 }
        let r = vertexRange(p)
        let o = P[Int(vertexPoint[r.lowerBound])]
        var n = SIMD3<Float>.zero
        for v in (r.lowerBound + 1)..<(r.upperBound - 1) {
            n += simd_cross(P[Int(vertexPoint[v])] - o, P[Int(vertexPoint[v + 1])] - o)
        }
        return simd_length(n) / 2
    }

    package func primPerimeter(_ p: Int) -> Float {
        let r = vertexRange(p)
        guard r.count > 1 else { return 0 }
        var l: Float = 0
        for v in r.lowerBound..<(r.upperBound - 1) { l += simd_distance(P[Int(vertexPoint[v])], P[Int(vertexPoint[v + 1])]) }
        if primClosed[p] { l += simd_distance(P[Int(vertexPoint[r.upperBound - 1])], P[Int(vertexPoint[r.lowerBound])]) }
        return l
    }

    package var bounds: AABB {
        var b = AABB()
        for p in P { b.grow(p) }
        return b
    }

    /// Roughly what the geometry holds, for the cooker's budget.
    package var byteSize: Int {
        P.count * 16 + vertexPoint.count * 4 + primStart.count * 5
            + points.byteSize + vertices.byteSize + prims.byteSize + detail.byteSize
    }

    // MARK: Combining and cutting

    /// Another geometry's elements after these (its point references moved past ours); the attributes of both.
    package mutating func merge(_ o: ProcGeo) {
        let base = Int32(P.count), vbase = Int32(vertexPoint.count)
        P += o.P
        points.append(o.points)
        vertexPoint.reserveCapacity(vertexPoint.count + o.vertexPoint.count)
        for v in o.vertexPoint { vertexPoint.append(v + base) }
        vertices.append(o.vertices)
        primStart.reserveCapacity(primStart.count + o.primCount)
        for s in o.primStart.dropFirst() { primStart.append(s + vbase) }
        primClosed += o.primClosed
        prims.append(o.prims)
        // The detail: ours first, then those only the other has.
        for a in o.detail.attributes where detail[a.name] == nil { detail.set(a.name, a.values) }
    }

    /// The primitives `keep` flags (with their vertices) and the points `keepPoints` flags, numbered again in order;
    /// a primitive whose point went goes too. Points no kept primitive uses stay if flagged.
    package func keeping(prims keep: [Bool], points keepPoints: [Bool]? = nil) -> ProcGeo {
        var pointKept = keepPoints ?? [Bool](repeating: true, count: pointCount)
        var primRows: [Int32] = [], vertexRows: [Int32] = []
        var out = ProcGeo()
        for p in 0..<primCount where keep[p] {
            let r = vertexRange(p)
            if r.contains(where: { !pointKept[Int(vertexPoint[$0])] }) { continue }
            primRows.append(Int32(p))
            for v in r { vertexRows.append(Int32(v)) }
            out.primStart.append(Int32(vertexRows.count))
            out.primClosed.append(primClosed[p])
        }
        if keepPoints == nil {
            // Without a choice of points: those the kept primitives use, and loose ones that were loose.
            var usedBefore = [Bool](repeating: false, count: pointCount), usedAfter = usedBefore
            for v in vertexPoint { usedBefore[Int(v)] = true }
            for p in primRows { for v in vertexRange(Int(p)) { usedAfter[Int(vertexPoint[v])] = true } }
            for i in 0..<pointCount { pointKept[i] = !usedBefore[i] || usedAfter[i] }
        }
        var map = [Int32](repeating: -1, count: pointCount)
        var pointRows: [Int32] = []
        for i in 0..<pointCount where pointKept[i] {
            map[i] = Int32(pointRows.count)
            pointRows.append(Int32(i))
        }
        out.P = pointRows.map { P[Int($0)] }
        out.points = points.gathered(pointRows)
        out.vertexPoint = vertexRows.map { map[Int(vertexPoint[Int($0)])] }
        out.vertices = vertices.gathered(vertexRows)
        out.prims = prims.gathered(primRows)
        out.detail = detail
        return out
    }

    /// Points no primitive uses go.
    package mutating func removeUnusedPoints() {
        var used = [Bool](repeating: false, count: pointCount)
        for v in vertexPoint { used[Int(v)] = true }
        guard used.contains(false) else { return }
        self = keeping(prims: [Bool](repeating: true, count: primCount), points: used)
    }

    /// The points in a new order: `order[i]` is the old index of new point `i` (every point once).
    package func reorderedPoints(_ order: [Int32]) -> ProcGeo {
        var out = self
        var map = [Int32](repeating: 0, count: pointCount)
        for (i, o) in order.enumerated() { map[Int(o)] = Int32(i) }
        out.P = order.map { P[Int($0)] }
        out.points = points.gathered(order)
        out.vertexPoint = vertexPoint.map { map[Int($0)] }
        return out
    }

    /// The primitives in a new order (with their vertices).
    package func reorderedPrims(_ order: [Int32]) -> ProcGeo {
        var out = self
        var vrows: [Int32] = []
        vrows.reserveCapacity(vertexCount)
        out.primStart = [0]
        out.primClosed = []
        for p in order {
            for v in vertexRange(Int(p)) { vrows.append(Int32(v)) }
            out.primStart.append(Int32(vrows.count))
            out.primClosed.append(primClosed[Int(p)])
        }
        out.vertexPoint = vrows.map { vertexPoint[Int($0)] }
        out.vertices = vertices.gathered(vrows)
        out.prims = prims.gathered(order)
        return out
    }

    /// The tables' lengths match their classes, and every vertex names a point: nil, else what is wrong.
    package func validate() -> String? {
        if points.count != pointCount { return "\(points.count) point rows for \(pointCount) points" }
        if vertices.count != vertexCount { return "\(vertices.count) vertex rows for \(vertexCount) vertices" }
        if prims.count != primCount { return "\(prims.count) primitive rows for \(primCount) primitives" }
        if primClosed.count != primCount { return "\(primClosed.count) closed flags for \(primCount) primitives" }
        if detail.count != 1 { return "\(detail.count) detail rows" }
        if primStart.first != 0 || primStart.last != Int32(vertexCount) { return "primitive starts don't span the vertices" }
        for i in 0..<primCount where primStart[i] > primStart[i + 1] { return "primitive \(i) ends before it starts" }
        for v in vertexPoint where v < 0 || Int(v) >= pointCount { return "a vertex names point \(v) of \(pointCount)" }
        return nil
    }
}

/// Runs `body` over `0..<count` in parts of `grain` on every core (one call on small counts). Each part writes only its
/// own rows, through pointers taken before the call.
@inlinable package func parallelChunks(_ count: Int, grain: Int = 4096, _ body: (Range<Int>) -> Void) {
    guard count > grain else { if count > 0 { body(0..<count) }; return }
    let parts = (count + grain - 1) / grain
    DispatchQueue.concurrentPerform(iterations: parts) { i in
        body((i * grain)..<min(count, (i + 1) * grain))
    }
}
