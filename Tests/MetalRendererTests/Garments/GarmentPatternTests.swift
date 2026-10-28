import XCTest
import CoreGraphics
import ImageIO
import simd
@testable import Characters
@testable import EngineCore
@testable import Garments
@testable import Physics

/// The garment designer's patterns: edges as curves, panels meshed, seams sampled and paired, every template, the
/// file and the DXF. `GARMENT_PNG=<folder>` also draws each template's meshes there.
final class GarmentPatternTests: XCTestCase {
    private func rectangle(_ w: Float, _ h: Float) -> Panel {
        Panel(id: 0, name: "Rect", points: [PathPoint([0, 0]), PathPoint([w, 0]), PathPoint([w, h]), PathPoint([0, h])])
    }

    func testAnEdgeIsMeasuredAlongItsCurve() {
        let line = EdgeCurve(PathPoint([0, 0]), PathPoint([1, 0]))
        XCTAssertEqual(line.length, 1, accuracy: 1e-5)
        XCTAssertEqual(line.point(at: 0.25).x, 0.25, accuracy: 1e-5)
        // A quarter circle as a Bézier (handles 0.5523 of the radius): its length π/2.
        let k: Float = 0.5523
        let arc = EdgeCurve(PathPoint([1, 0], handleOut: [0, k]), PathPoint([0, 1], handleIn: [k, 0]))
        XCTAssertEqual(arc.length, .pi / 2, accuracy: 2e-3)
        XCTAssertEqual(simd_length(arc.point(at: 0.5)), 1, accuracy: 2e-3)
        XCTAssertEqual(arc.nearest([0.8, 0.8]).f, 0.5, accuracy: 0.02)
    }

    func testAPanelIsMeshedWholeAndKeepsItsOutline() {
        let p = rectangle(0.4, 0.3)
        var g = Garment(name: "Test")
        g.panels = [p]
        let samples = SeamSampling.samples(g, panels: [p])
        let m = PanelTriangulator.mesh(p, samples: samples[0], spacing: 0.02)
        XCTAssertEqual(m.missingEdges, 0)
        var area: Float = 0
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let a = m.points[Int(m.triangles[t])], b = m.points[Int(m.triangles[t + 1])], c = m.points[Int(m.triangles[t + 2])]
            let s = ((b - a).x * (c - a).y - (c - a).x * (b - a).y) / 2
            XCTAssertGreaterThan(s, 0, "counter-clockwise")
            area += s
        }
        XCTAssertEqual(area, 0.12, accuracy: 1e-4)
        // About the spacing's count of particles (a triangular lattice: 2/(√3 d²) a square metre).
        let expected: Float = 0.12 * 2 / (Float(3).squareRoot() * 0.02 * 0.02)
        XCTAssertEqual(Float(m.points.count), expected, accuracy: expected * 0.25)
        // No sliver: every triangle's smallest angle above 18°.
        var worst: Float = 180
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let q = (0..<3).map { m.points[Int(m.triangles[t + $0])] }
            for k in 0..<3 {
                let u = simd_normalize(q[(k + 1) % 3] - q[k]), v = simd_normalize(q[(k + 2) % 3] - q[k])
                worst = min(worst, acos(max(-1, min(1, simd_dot(u, v)))) * 180 / .pi)
            }
        }
        XCTAssertGreaterThan(worst, 18)
    }

    func testFoldLinesAreEdgesOfTheMesh() {
        var p = rectangle(0.3, 0.3)
        p.lines = [InternalLine([[0.05, 0.15], [0.25, 0.15]], kind: .fold, foldAngle: 1)]
        var g = Garment(name: "Fold")
        g.panels = [p]
        let b = GarmentBuild.make(g)
        let folds = b.constraints.filter { $0.kind == .bend && $0.a.y != 0 }
        XCTAssertGreaterThan(folds.count, 6)
        XCTAssertEqual(b.missingEdges, 0)
    }

    /// A 1:1 seam's samples meet one for one; an N:1 seam's every sample finds the other side.
    func testSeamsPairTheirSides() {
        var g = Garment(name: "Seams")
        var a = rectangle(0.3, 0.2), b = rectangle(0.3, 0.2), c = rectangle(0.6, 0.2)
        b.id = 1; b.translate([0.4, 0]); c.id = 2; c.translate([0, 0.3])
        g.panels = [a, b, c]
        a = g.panels[0]
        g.seams = [Seam(id: 0, a: [SeamEnd(panel: 0, edge: 1)], b: [SeamEnd(panel: 1, edge: 3, t0: 1, t1: 0)]),
                   Seam(id: 1, a: [SeamEnd(panel: 0, edge: 2, t0: 1, t1: 0), SeamEnd(panel: 1, edge: 2, t0: 1, t1: 0)],
                        b: [SeamEnd(panel: 2, edge: 0)])]
        let build = GarmentBuild.make(g)
        let seams = build.constraints.filter { $0.kind == .seam }
        XCTAssertFalse(seams.isEmpty)
        // The 1:1 seam: every pair a vertex to a vertex, 0.2 / 0.02 + 1 of them.
        XCTAssertGreaterThanOrEqual(build.stitches.count, 11)
        // Each pair's two particles were at the same height on the sheet (the seam runs up both sides).
        for s in seams.prefix(11) where s.a.x == 0 {
            let p = build.rest2D[Int(s.v.x)], q = build.rest2D[Int(s.v.y)]
            if abs(p.x - 0.3) < 1e-3 && abs(q.x - 0.4) < 1e-3 { XCTAssertEqual(p.y, q.y, accuracy: 1e-3) }
        }
        // Coloured: no two of a colour share a particle.
        for k in 0..<build.colourCount {
            var seen = Set<UInt32>()
            for c in build.constraints[build.colourStarts[k]..<build.colourStarts[k + 1]] {
                let n = c.kind == .bend ? 4 : c.kind == .link ? 2 : 3
                for i in 0..<n where !(c.kind == .seam && i == 2 && c.v.z == c.v.y) {
                    XCTAssertTrue(seen.insert(c.v[i]).inserted, "colour \(k) shares particle \(c.v[i])")
                }
            }
        }
    }

    /// Every template draws, meshes cleanly, and its seams' sides are about as long as each other.
    func testEveryTemplateBuilds() throws {
        let body = BodyMeasurements()
        for kind in GarmentTemplate.Kind.allCases {
            let g = GarmentTemplate.make(kind, GarmentTemplate.params(kind, body: body), body: body)
            XCTAssertFalse(g.panels.isEmpty, kind.label)
            for p in g.panels { XCTAssertGreaterThan(p.signedArea, 0, "\(kind.label): \(p.name) runs counter-clockwise") }
            for s in g.seams {
                let la = s.a.reduce(Float(0)) { $0 + SeamSampling.length(g, $1) }, lb = s.b.reduce(Float(0)) { $0 + SeamSampling.length(g, $1) }
                XCTAssertGreaterThan(la, 0.01, "\(kind.label) seam \(s.id)")
                XCTAssertEqual(la, lb, accuracy: max(la, lb) * 0.35, "\(kind.label) seam \(s.id): \(la) against \(lb)")
            }
            let b = GarmentBuild.make(g)
            XCTAssertEqual(b.missingEdges, 0, kind.label)
            XCTAssertGreaterThan(b.particleCount, 500, kind.label)
            XCTAssertLessThan(b.colourCount, 100, kind.label)
            XCTAssertTrue(b.invMass.allSatisfy { $0 > 0 && $0.isFinite }, kind.label)
            if let folder = ProcessInfo.processInfo.environment["GARMENT_PNG"] {
                try draw(b, g, to: URL(fileURLWithPath: folder).appendingPathComponent("\(kind.rawValue).png"))
            }
        }
    }

    func testTheFileReadsBackWhatWasSaved() throws {
        let body = BodyMeasurements()
        var g = GarmentTemplate.make(.shirt, GarmentTemplate.params(.shirt, body: body), body: body)
        g.panels[0].lines = [InternalLine([[0.1, 0.1], [0.2, 0.3]], kind: .elastic)]
        let back = try GarmentStore.decode(GarmentStore.encode(g))
        XCTAssertEqual(back, g)
        XCTAssertEqual(GarmentCatalog.fingerprint(back), GarmentCatalog.fingerprint(g))
        XCTAssertEqual(GarmentStore.id(for: "My Shirt #2"), "my-shirt-2")
    }

    func testTheDXFHasEveryPanelOnItsLayers() {
        let body = BodyMeasurements()
        let g = GarmentTemplate.make(.tshirt, GarmentTemplate.params(.tshirt, body: body), body: body)
        let dxf = DXFWriter.write(g)
        XCTAssertTrue(dxf.hasPrefix("0\nSECTION"))
        XCTAssertTrue(dxf.hasSuffix("0\nEOF\n"))
        for layer in ["CUT", "SEAM", "GRAIN", "NOTCH"] { XCTAssertTrue(dxf.contains("8\n\(layer)\n"), layer) }
        XCTAssertEqual(dxf.components(separatedBy: "0\nPOLYLINE\n8\nCUT").count - 1, g.panels.count)
    }

    func testTheSeamAllowanceGoesOutside() {
        let p = rectangle(0.2, 0.1)
        let a = Polygon2D.signedArea(p.allowance(0.01))
        XCTAssertEqual(a, 0.22 * 0.12, accuracy: 1e-5)
    }

    /// Each panel's mesh, its outline and its stitches, into a PNG (5 px a centimetre).
    private func draw(_ b: GarmentBuild, _ g: Garment, to url: URL) throws {
        var lo = SIMD2<Float>(repeating: .infinity), hi = -lo
        for p in b.rest2D { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let scale: Float = 500, pad: Float = 0.05
        let w = Int((hi.x - lo.x + 2 * pad) * scale), h = Int((hi.y - lo.y + 2 * pad) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func pt(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat((p.x - lo.x + pad) * scale), y: CGFloat((p.y - lo.y + pad) * scale)) }
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(red: 0.75, green: 0.75, blue: 0.72, alpha: 1))
        for t in stride(from: 0, to: b.triangles.count, by: 3) {
            ctx.move(to: pt(b.rest2D[Int(b.triangles[t])]))
            ctx.addLine(to: pt(b.rest2D[Int(b.triangles[t + 1])]))
            ctx.addLine(to: pt(b.rest2D[Int(b.triangles[t + 2])]))
            ctx.closePath()
        }
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 1))
        ctx.setLineWidth(3)
        for o in b.outlines {
            guard let f = o.first else { continue }
            ctx.move(to: pt(b.rest2D[Int(f)]))
            for i in o.dropFirst() { ctx.addLine(to: pt(b.rest2D[Int(i)])) }
            ctx.closePath()
        }
        ctx.strokePath()
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
