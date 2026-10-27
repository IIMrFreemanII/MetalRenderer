import Foundation
import simd

/// New geometry made from an old one's elements: every point, vertex and primitive added names the row of the source
/// it takes its attributes from (-1: defaults), and `build` gathers the source's tables by those rows. What nodes that
/// change topology (extrude, divide, fuse, mirror) build with, so every attribute rides through them.
package struct GeoBuilder {
    package var P: [SIMD3<Float>] = []
    package var pointRows: [Int32] = []
    package var vertexPoint: [Int32] = []
    package var vertexRows: [Int32] = []
    package var primStart: [Int32] = [0]
    package var primClosed: [Bool] = []
    package var primRows: [Int32] = []

    package init() {}

    /// Starting with all of the source's points (in order), and none of its primitives.
    package init(points g: ProcGeo) {
        P = g.P
        pointRows = (0..<Int32(g.pointCount)).map { $0 }
    }

    package var pointCount: Int { P.count }

    @discardableResult
    package mutating func addPoint(_ p: SIMD3<Float>, from row: Int32) -> Int32 {
        P.append(p)
        pointRows.append(row)
        return Int32(P.count - 1)
    }

    /// A primitive over `points`, its vertices' attributes from `vertexRows` (one per point), its own from `prim`.
    package mutating func addPrim(_ points: [Int32], vertices rows: [Int32], from prim: Int32, closed: Bool = true) {
        vertexPoint += points
        vertexRows += rows
        primStart.append(Int32(vertexPoint.count))
        primClosed.append(closed)
        primRows.append(prim)
    }

    /// A source primitive as it was (its points renumbered by `map`, if given).
    package mutating func copyPrim(_ p: Int, of g: ProcGeo, map: [Int32]? = nil, reversed: Bool = false) {
        var r = Array(g.vertexRange(p))
        if reversed { r.reverse() }
        let pts = r.map { map?[Int(g.vertexPoint[$0])] ?? g.vertexPoint[$0] }
        addPrim(pts, vertices: r.map { Int32($0) }, from: Int32(p), closed: g.primClosed[p])
    }

    /// The geometry: the source's tables gathered by the rows recorded, its detail as it was.
    package func build(from g: ProcGeo) -> ProcGeo {
        var out = ProcGeo()
        out.P = P
        out.points = g.points.gathered(pointRows)
        out.vertexPoint = vertexPoint
        out.vertices = g.vertices.gathered(vertexRows)
        out.primStart = primStart
        out.primClosed = primClosed
        out.prims = g.prims.gathered(primRows)
        out.detail = g.detail
        return out
    }
}
