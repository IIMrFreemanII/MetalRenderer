import Foundation
import Characters
import Garments
import simd

/// Garments as nodes: a template's garment for an avatar (graded to its measurements, eased), sewn and draped on it
/// (GarmentDrapes, on the CPU, kept), as polygons with the pattern's texture coordinates (`uv`) and each one's panel
/// (`panel`, a primitive attribute) for the network to go on with.
enum GarmentNodes {
    static func garment(_ c: ProcCook) -> ProcGeo {
        guard let kind = GarmentTemplate.Kind(rawValue: c.string("template")) else { return ProcGeo() }
        let avatar = c.string("avatar")
        guard let body = GarmentAvatars.character(avatar) else { return ProcGeo() }
        let m = BodyMeasurements.measure(body)
        var g = GarmentTemplate.make(kind, GarmentTemplate.params(kind, body: m, ease: c.float("ease")), body: m)
        g.particleDistance = max(0.008, c.float("spacing"))
        let drape = GarmentDrapes.drape(g, on: body, bodyKey: avatar, seconds: max(0.5, c.float("seconds")))
        let b = drape.build
        let prims = stride(from: 0, to: b.triangles.count, by: 3).map { [Int32(b.triangles[$0]), Int32(b.triangles[$0 + 1]), Int32(b.triangles[$0 + 2])] }
        var geo = ProcGeo(P: drape.positions, prims: prims)
        geo.points.set("uv", .vector2(b.uvs.map { $0 * 4 }))
        var panel = [Float](repeating: 0, count: prims.count)
        for (pi, r) in b.panelTriangles.enumerated() { for t in r where t < panel.count { panel[t] = Float(pi) } }
        geo.prims.set("panel", .float(panel))
        return geo
    }
}
