import Foundation
import Physics
import simd

/// A garment made into what the solver steps and the renderer draws: every visible panel meshed (PanelTriangulator)
/// at its outline's samples (SeamSampling), its particles in one array panel after panel, and its constraints:
/// each triangle's stretch and shear along the grain, each inner edge's bending (folds at their angles), the seams'
/// pairs and the bends across them, elastics and buttons; coloured so that no two of a colour share a particle, and
/// sorted by colour. Made on a background job at each edit; plain arrays, handed over at a frame boundary.
package struct GarmentBuild {
    /// The panels built (ids, in order) and each one's first particle and count.
    package var panelIDs: [Int] = []
    package var panelFirst: [Int] = []
    package var panelCount: [Int] = []
    package var panelTriangles: [Range<Int>] = []
    /// Each particle: where it is on the sheet, its panel's index in `panelIDs`, its texture coordinate (metres along
    /// the warp and the weft), its inverse mass (0: frozen), its layer.
    package var rest2D: [SIMD2<Float>] = []
    package var panelOf: [Int32] = []
    package var uvs: [SIMD2<Float>] = []
    package var invMass: [Float] = []
    package var layer: [UInt8] = []
    /// The mesh's triangles (particle indices), panel after panel, counter-clockwise on the sheet.
    package var triangles: [UInt32] = []
    /// Each triangle's fabric (its index in the garment's fabrics).
    package var triangleFabric: [UInt8] = []
    package var constraints: [GPUGarmentConstraint] = []
    /// The colours' first constraints, and one past the last (`colourStarts.count - 1` colours).
    package var colourStarts: [Int] = [0]
    /// The seams' pairs of particles (a vertex to a vertex), for drawing the stitches.
    package var stitches: [(UInt32, UInt32)] = []
    /// Each panel's outline (particle indices, in order), for drawing it.
    package var outlines: [[UInt32]] = []
    /// Outline segments lost in triangulation (0 in a clean build).
    package var missingEdges = 0

    /// For self-collision: each particle's place on the sheet, its panel and its layer; and its seam partners (up to
    /// four, ~0 for none), which it is sewn to and never pushed from.
    package var selfRest: [SIMD4<Float>] {
        rest2D.indices.map { SIMD4(rest2D[$0].x, rest2D[$0].y, Float(panelOf[$0]), Float(layer[$0])) }
    }
    package var seamPartners: [SIMD4<UInt32>] {
        var out = [SIMD4<UInt32>](repeating: SIMD4(repeating: .max), count: particleCount)
        var used = [Int](repeating: 0, count: particleCount)
        func add(_ a: UInt32, _ b: UInt32) {
            let i = Int(a)
            guard a != b, used[i] < 4, !(0..<used[i]).contains(where: { out[i][$0] == b }) else { return }
            out[i][used[i]] = b
            used[i] += 1
        }
        for c in constraints where c.kind == .seam {
            add(c.v.x, c.v.y); add(c.v.y, c.v.x); add(c.v.x, c.v.z); add(c.v.z, c.v.x)
        }
        return out
    }

    package var particleCount: Int { rest2D.count }
    package var colourCount: Int { colourStarts.count - 1 }
    package var isEmpty: Bool { rest2D.isEmpty }

    /// The garment's build. `bendScale`: the bending's stiffness times this (tests).
    package static func make(_ g: Garment) -> GarmentBuild {
        var b = GarmentBuild()
        let panels = g.panels.filter { !$0.hidden && $0.points.count >= 3 }
        let samples = SeamSampling.samples(g, panels: panels)
        var meshes: [PanelMesh] = []
        meshes.reserveCapacity(panels.count)
        // (Each panel's mesh is its own: made side by side.)
        var made = [PanelMesh](repeating: PanelMesh(), count: panels.count)
        made.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: panels.count) { i in
                out[i] = PanelTriangulator.mesh(panels[i], samples: samples[i], spacing: SeamSampling.spacing(g, panels[i].id))
            }
        }
        meshes = made
        var mass: [Float] = []
        var bends: [GPUGarmentConstraint] = [], tris: [GPUGarmentConstraint] = [], links: [GPUGarmentConstraint] = []
        // Each panel's particles, triangles, stretch and bending.
        for (pi, panel) in panels.enumerated() {
            let m = meshes[pi]
            let first = b.rest2D.count
            let fabric = g.fabric(of: panel)
            let fabricIndex = UInt8(clamping: g.fabrics.indices.contains(panel.fabric) ? panel.fabric : 0)
            b.panelIDs.append(panel.id)
            b.panelFirst.append(first)
            b.panelCount.append(m.points.count)
            b.missingEdges += m.missingEdges
            let warp = SIMD2<Float>(cos(panel.grain), sin(panel.grain)), weft = SIMD2<Float>(-warp.y, warp.x)
            for q in m.points {
                b.rest2D.append(q)
                b.panelOf.append(Int32(pi))
                b.uvs.append(SIMD2(simd_dot(q, warp), simd_dot(q, weft)))
                b.layer.append(UInt8(clamping: panel.layer))
            }
            mass += [Float](repeating: 0, count: m.points.count)
            let triStart = b.triangles.count / 3
            let warpC = Fabric.compliance(fabric.warp, softest: Fabric.stretchSoftest), weftC = Fabric.compliance(fabric.weft, softest: Fabric.stretchSoftest)
            let shearC = Fabric.compliance(fabric.shear, softest: Fabric.shearSoftest)
            for t in stride(from: 0, to: m.triangles.count, by: 3) {
                let i0 = Int(m.triangles[t]), i1 = Int(m.triangles[t + 1]), i2 = Int(m.triangles[t + 2])
                // The rest shape in the grain's frame: warp along x, weft along y.
                let r0 = b.uvs[first + i0], r1 = b.uvs[first + i1], r2 = b.uvs[first + i2]
                let e1 = r1 - r0, e2 = r2 - r0
                let det = e1.x * e2.y - e2.x * e1.y
                guard abs(det) > 1e-12 else { continue }
                let area = abs(det) / 2
                // The inverse of [e1 e2] (columns), row-major in a.
                let inv = SIMD4<Float>(e2.y, -e2.x, -e1.y, e1.x) / det
                let g0 = UInt32(first + i0), g1 = UInt32(first + i1), g2 = UInt32(first + i2)
                b.triangles += [g0, g1, g2]
                b.triangleFabric.append(fabricIndex)
                tris.append(GPUGarmentConstraint(v: SIMD4(g0, g1, g2, 0), kind: .tri, a: inv, b: SIMD4(warpC, weftC, shearC, area)))
                let share = area * fabric.areaMass / 3
                mass[first + i0] += share; mass[first + i1] += share; mass[first + i2] += share
            }
            b.panelTriangles.append(triStart..<(b.triangles.count / 3))
            // Bending across every inner edge: flat at rest, but on a fold line, where it settles to the fold's angle.
            let bendC = Fabric.compliance(fabric.bending, softest: Fabric.bendSoftest)
            var folds: [UInt64: (line: Int, a: Int)] = [:]
            for s in m.lineSegments { folds[key(s.a, s.b)] = (s.line, s.a) }
            var edgeTris: [UInt64: [(opposite: Int, a: Int, b: Int)]] = [:]
            for t in stride(from: 0, to: m.triangles.count, by: 3) {
                for k in 0..<3 {
                    let a = Int(m.triangles[t + k]), c = Int(m.triangles[t + (k + 1) % 3]), o = Int(m.triangles[t + (k + 2) % 3])
                    edgeTris[key(a, c), default: []].append((o, a, c))
                }
            }
            for (k, pair) in edgeTris where pair.count == 2 {
                var compliance = bendC, rest: Float = 0
                // (Stencil: the edge as the first triangle runs it, its opposite first.)
                let e0 = pair[0].a, e1 = pair[0].b
                if let fold = folds[k] {
                    let line = panel.lines[fold.line]
                    switch line.kind {
                    case .fold:
                        rest = fold.a == e0 ? line.foldAngle : -line.foldAngle
                        compliance = Fabric.compliance(fabric.bending + 40 * line.foldStrength, softest: Fabric.bendSoftest)
                    case .topstitch:
                        compliance = bendC / 8
                    case .elastic: break
                    }
                }
                bends.append(GPUGarmentConstraint(v: SIMD4(UInt32(first + pair[0].opposite), UInt32(first + pair[1].opposite),
                                                           UInt32(first + e0), UInt32(first + e1)),
                                                  kind: .bend, a: SIMD4(compliance, rest, 0, 0)))
            }
            // Elastic lines: each segment shorter than it was cut.
            for s in m.lineSegments where panel.lines[s.line].kind == .elastic {
                let rest = simd_distance(m.points[s.a], m.points[s.b]) * max(0.3, min(1, panel.lines[s.line].ratio))
                links.append(GPUGarmentConstraint(v: SIMD4(UInt32(first + s.a), UInt32(first + s.b), 0, 0), kind: .link,
                                                  a: SIMD4(rest, 1e-7, 0, 0)))
            }
            b.outlines.append(m.boundary.map { UInt32(first + $0) })
            if panel.frozen { for i in 0..<m.points.count { mass[first + i] = 0 } }
        }
        b.invMass = mass.map { $0 > 0 ? 1 / $0 : 0 }
        // The seams.
        var seams: [GPUGarmentConstraint] = []
        var pairs = Set<UInt64>()
        for seam in g.seams {
            let sideA = side(seam.a, panels: panels, meshes: meshes, build: b)
            let sideB = side(seam.b, panels: panels, meshes: meshes, build: b)
            guard sideA.count > 1, sideB.count > 1 else { continue }
            func sew(_ from: [(Int, Float)], _ to: [(Int, Float)]) {
                for (p, s) in from {
                    // The other side's samples on either side of s.
                    var hi = to.firstIndex { $0.1 >= s - 1e-6 } ?? to.count - 1
                    hi = max(hi, 0)
                    let lo = max(0, hi - 1)
                    let (b0, s0) = to[lo], (b1, s1) = to[hi]
                    var w: Float = s1 > s0 ? (s - s0) / (s1 - s0) : 0
                    w = max(0, min(1, w))
                    var q0 = b0, q1 = b1
                    if w < 1e-3 || q0 == q1 { q1 = q0; w = 0 } else if w > 1 - 1e-3 { q0 = q1; w = 0 }
                    if q0 == q1 {
                        guard q0 != p, pairs.insert(key(p, q0)).inserted else { continue }
                        b.stitches.append((UInt32(p), UInt32(q0)))
                    }
                    seams.append(GPUGarmentConstraint(v: SIMD4(UInt32(p), UInt32(q0), UInt32(q1), 0), kind: .seam, a: SIMD4(w, 0, 0, 0)))
                }
            }
            sew(sideA, sideB)
            sew(sideB, sideA)
            // Bending across the seam where its pairs meet one for one: the cloth carries on over it.
            bends += seamBends(sideA, sideB, seam: seam, panels: panels, meshes: meshes, build: b, garment: g)
        }
        // Buttons: their two particles held together.
        for button in g.buttons {
            guard let a = nearestParticle(b, panel: button.panel, at: button.at, panels: panels),
                  let h = nearestParticle(b, panel: button.holePanel, at: button.hole, panels: panels) else { continue }
            links.append(GPUGarmentConstraint(v: SIMD4(UInt32(a), UInt32(h), 0, 0), kind: .link, a: SIMD4(0.003, 1e-7, 0, 0)))
        }
        // Coloured: the biggest stencils first.
        let all = bends + tris + seams + links
        b.colour(all)
        return b
    }

    private static func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }

    /// A seam side's particles and where each is along the side (0...1 of its length), in order.
    static func side(_ ends: [SeamEnd], panels: [Panel], meshes: [PanelMesh], build: GarmentBuild) -> [(Int, Float)] {
        let lengths = ends.map { e -> Float in
            guard let p = panels.first(where: { $0.id == e.panel }), p.points.indices.contains(e.edge) else { return 0 }
            return p.edge(e.edge).length * abs(e.t1 - e.t0)
        }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return [] }
        var out: [(Int, Float)] = []
        var start: Float = 0
        for (k, e) in ends.enumerated() {
            defer { start += lengths[k] / total }
            guard let pi = panels.firstIndex(where: { $0.id == e.panel }) else { continue }
            let m = meshes[pi], first = build.panelFirst[pi], n = panels[pi].points.count
            let lo = min(e.t0, e.t1), hi = max(e.t0, e.t1), span = e.t1 - e.t0
            guard abs(span) > 1e-6 else { continue }
            for (i, at) in m.boundaryAt.enumerated() {
                var f: Float
                if at.edge == e.edge && at.f >= lo - 1e-5 && at.f <= hi + 1e-5 { f = at.f }
                else if hi > 1 - 1e-5 && at.edge == (e.edge + 1) % n && at.f < 1e-5 { f = 1 }
                else { continue }
                let s = start + (f - e.t0) / span * (lengths[k] / total)
                out.append((first + m.boundary[i], s))
            }
        }
        out.sort { $0.1 < $1.1 }
        return out
    }

    /// Bends over a seam: for each pair of consecutive one-for-one pairs, the triangles on either side of the seam's
    /// edge, their opposite particles across it.
    private static func seamBends(_ a: [(Int, Float)], _ b: [(Int, Float)], seam: Seam, panels: [Panel], meshes: [PanelMesh],
                                  build: GarmentBuild, garment g: Garment) -> [GPUGarmentConstraint] {
        guard a.count == b.count else { return [] }
        var out: [GPUGarmentConstraint] = []
        let opposite = edgeOpposites(build)
        let fabric = panels.first { $0.id == seam.a.first?.panel }.map { g.fabric(of: $0) } ?? .preset(.cotton)
        let compliance = Fabric.compliance(fabric.bending, softest: Fabric.bendSoftest) * (seam.kind == .turned ? 0.25 : 1)
        for k in 0..<(a.count - 1) where abs(a[k].1 - b[k].1) < 1e-4 && abs(a[k + 1].1 - b[k + 1].1) < 1e-4 {
            guard let oa = opposite[key(a[k].0, a[k + 1].0)], let ob = opposite[key(b[k].0, b[k + 1].0)] else { continue }
            out.append(GPUGarmentConstraint(v: SIMD4(UInt32(oa), UInt32(ob), UInt32(a[k].0), UInt32(a[k + 1].0)), kind: .bend,
                                            a: SIMD4(compliance, seam.foldAngle, 0, 0), b: SIMD4(1, 0, 0, 0)))
        }
        return out
    }

    /// For each outline edge of the mesh, the particle opposite it in its one triangle.
    private static func edgeOpposites(_ b: GarmentBuild) -> [UInt64: Int] {
        var count: [UInt64: Int] = [:], opposite: [UInt64: Int] = [:]
        for t in stride(from: 0, to: b.triangles.count, by: 3) {
            for k in 0..<3 {
                let e = key(Int(b.triangles[t + k]), Int(b.triangles[t + (k + 1) % 3]))
                count[e, default: 0] += 1
                opposite[e] = Int(b.triangles[t + (k + 2) % 3])
            }
        }
        return opposite.filter { count[$0.key] == 1 }
    }

    private static func nearestParticle(_ b: GarmentBuild, panel id: Int, at q: SIMD2<Float>, panels: [Panel]) -> Int? {
        guard let pi = panels.firstIndex(where: { $0.id == id }) else { return nil }
        let r = b.panelFirst[pi]..<(b.panelFirst[pi] + b.panelCount[pi])
        return r.min { simd_distance(b.rest2D[$0], q) < simd_distance(b.rest2D[$1], q) }
    }

    /// Colours the constraints greedily (each the lowest colour none of its particles has yet) and sorts them by colour.
    mutating func colour(_ all: [GPUGarmentConstraint]) {
        var used = [UInt64](repeating: 0, count: particleCount * 2)   // two words a particle: 128 colours
        var colours = [Int](repeating: 0, count: all.count)
        var top = 0
        for (i, c) in all.enumerated() {
            let n = c.kind == .bend ? 4 : c.kind == .link ? 2 : 3
            var mask0: UInt64 = 0, mask1: UInt64 = 0
            for k in 0..<n { let p = Int(c.v[k]); mask0 |= used[2 * p]; mask1 |= used[2 * p + 1] }
            let free0 = ~mask0, free1 = ~mask1
            let colour = free0 != 0 ? free0.trailingZeroBitCount : free1 != 0 ? 64 + free1.trailingZeroBitCount : 127
            colours[i] = colour
            top = max(top, colour)
            for k in 0..<n {
                let p = Int(c.v[k])
                if colour < 64 { used[2 * p] |= 1 << UInt64(colour) } else { used[2 * p + 1] |= 1 << UInt64(colour - 64) }
            }
        }
        var counts = [Int](repeating: 0, count: top + 2)
        for c in colours { counts[c + 1] += 1 }
        for k in 1..<counts.count { counts[k] += counts[k - 1] }
        colourStarts = counts
        var next = counts
        constraints = [GPUGarmentConstraint](repeating: GPUGarmentConstraint(kind: .link), count: all.count)
        for (i, c) in all.enumerated() {
            var c = c
            c.info.y = UInt32(colours[i])
            constraints[next[colours[i]]] = c
            next[colours[i]] += 1
        }
        if all.isEmpty { colourStarts = [0] }
    }
}
