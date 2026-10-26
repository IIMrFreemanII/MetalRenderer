import Foundation
import simd

/// The curve nodes: Curve, Resample, Sweep, Revolve, PolyWire, Carve, Ends, L-System. A curve is a primitive's run of
/// points: open (a polyline) or closed (a polygon, read as a loop).
enum CurveNodes {
    // MARK: Sampling a curve

    /// A curve's points, and the length along it at each (closed: the loop back to the first adds a last length).
    static func lengths(_ pts: [SIMD3<Float>], closed: Bool) -> [Float] {
        var out: [Float] = [0]
        for i in 1..<max(1, pts.count) { out.append(out[i - 1] + simd_distance(pts[i - 1], pts[i])) }
        if closed, let l = pts.last, let f = pts.first { out.append(out[out.count - 1] + simd_distance(l, f)) }
        return out
    }

    /// Catmull-Rom between `p1` and `p2` at `t`.
    static func catmullRom(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * ((2 * p1) + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
    }

    /// Where along the curve each new point is: the span (index of its first point) and how far into it (0...1).
    struct Sample { var span: Int; var t: Float }

    static func samples(_ len: [Float], spans: Int, count: Int, closedEnd: Bool) -> [Sample] {
        let total = len[len.count - 1]
        guard count > 1, total > 0 else { return [Sample(span: 0, t: 0)] }
        var out: [Sample] = []
        var s = 0
        let n = closedEnd ? count : count - 1
        for k in 0..<count {
            let d = total * Float(k) / Float(n)
            while s < spans - 1 && len[s + 1] < d { s += 1 }
            let seg = len[s + 1] - len[s]
            out.append(Sample(span: s, t: seg > 0 ? min(1, max(0, (d - len[s]) / seg)) : 0))
        }
        return out
    }

    static func resample(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let picked = try c.group(in: g, .primitive)
        let byLength = c.bool("dolength")
        let step = max(1e-4, c.float("length"))
        let segments = max(1, c.int("segs"))
        let smooth = c.string("treatpolysas") == "subdivision"
        var P: [SIMD3<Float>] = []
        var pointStart: [Int32] = [0], pointSrc: [Int32] = [], pointW: [Float] = []
        var vertexStart: [Int32] = [0], vertexSrc: [Int32] = [], vertexW: [Float] = []
        var out = ProcGeo()
        var primRows: [Int32] = []
        var curveu: [Float] = []
        func copyPoint(_ v: Int) {
            P.append(g.P[Int(g.vertexPoint[v])])
            pointSrc.append(g.vertexPoint[v]); pointW.append(1); pointStart.append(Int32(pointSrc.count))
            vertexSrc.append(Int32(v)); vertexW.append(1); vertexStart.append(Int32(vertexSrc.count))
        }
        for p in 0..<g.primCount {
            let r = Array(g.vertexRange(p))
            let closed = g.primClosed[p]
            let first = Int32(P.count)
            if !picked[p] || r.count < 2 {
                for v in r { copyPoint(v); curveu.append(0) }
            } else {
                let pts = r.map { g.P[Int(g.vertexPoint[$0])] }
                let len = lengths(pts, closed: closed)
                let spans = closed ? pts.count : pts.count - 1
                let total = len[len.count - 1]
                let count = byLength ? max(2, Int((total / step).rounded()) + (closed ? 0 : 1)) : segments + (closed ? 0 : 1)
                for s in samples(len, spans: spans, count: count, closedEnd: closed) {
                    let a = s.span, b = (s.span + 1) % pts.count
                    let pa = pts[a], pb = pts[b]
                    var q = pa + (pb - pa) * s.t
                    if smooth {
                        let p0 = closed || a > 0 ? pts[(a - 1 + pts.count) % pts.count] : pa + (pa - pb)
                        let p3 = closed || b + 1 < pts.count ? pts[(b + 1) % pts.count] : pb + (pb - pa)
                        q = catmullRom(p0, pa, pb, p3, s.t)
                    }
                    P.append(q)
                    pointSrc += [g.vertexPoint[r[a]], g.vertexPoint[r[b]]]; pointW += [1 - s.t, s.t]
                    pointStart.append(Int32(pointSrc.count))
                    vertexSrc += [Int32(r[a]), Int32(r[b])]; vertexW += [1 - s.t, s.t]
                    vertexStart.append(Int32(vertexSrc.count))
                    curveu.append(total > 0 ? (len[a] + (len[a + 1] - len[a]) * s.t) / total : 0)
                }
            }
            out.vertexPoint += (first..<Int32(P.count)).map { $0 }
            out.primStart.append(Int32(out.vertexPoint.count))
            out.primClosed.append(closed)
            primRows.append(Int32(p))
        }
        out.P = P
        out.points = g.points.blended(start: pointStart, sources: pointSrc, weights: pointW)
        out.vertices = g.vertices.blended(start: vertexStart, sources: vertexSrc, weights: vertexW)
        out.prims = g.prims.gathered(primRows)
        out.detail = g.detail
        if c.bool("docurveu") { out.points.set("curveu", .float(curveu)) }
        return out
    }

    // MARK: Frames along a curve

    /// A frame at each point of a curve: its tangent, and a normal carried along it (parallel transport) from `up`
    /// (an `up` per point overrides it), turned by `twist` degrees from the start to the end.
    static func frames(_ pts: [SIMD3<Float>], closed: Bool, up: SIMD3<Float>, ups: [SIMD3<Float>]?, twist: Float, roll: Float)
        -> [(t: SIMD3<Float>, n: SIMD3<Float>, b: SIMD3<Float>)] {
        let n = pts.count
        guard n > 1 else { return [(SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(1, 0, 0))] }
        var tangents: [SIMD3<Float>] = []
        for i in 0..<n {
            let prev = i > 0 ? pts[i - 1] : (closed ? pts[n - 1] : pts[i])
            let next = i < n - 1 ? pts[i + 1] : (closed ? pts[0] : pts[i])
            var t = next - prev
            if simd_length(t) < 1e-9 { t = i < n - 1 ? pts[i + 1] - pts[i] : pts[i] - pts[i - 1] }
            tangents.append(simd_length(t) > 0 ? simd_normalize(t) : SIMD3(0, 0, 1))
        }
        func perpendicular(_ v: SIMD3<Float>, to t: SIMD3<Float>) -> SIMD3<Float>? {
            let p = v - t * simd_dot(v, t)
            return simd_length(p) > 1e-5 ? simd_normalize(p) : nil
        }
        var normal = perpendicular(ups?[0] ?? up, to: tangents[0])
            ?? perpendicular(SIMD3(1, 0, 0), to: tangents[0]) ?? SIMD3(0, 0, 1)
        var out: [(t: SIMD3<Float>, n: SIMD3<Float>, b: SIMD3<Float>)] = []
        for i in 0..<n {
            if i > 0 {
                if let u = ups.flatMap({ perpendicular($0[i], to: tangents[i]) }) {
                    normal = u
                } else {
                    // Turned by the rotation that takes the last tangent to this one.
                    let a = tangents[i - 1], b = tangents[i]
                    let axis = simd_cross(a, b)
                    let s = simd_length(axis)
                    if s > 1e-7 {
                        let q = simd_quatf(angle: atan2(s, simd_dot(a, b)), axis: axis / s)
                        normal = q.act(normal)
                    }
                    normal = perpendicular(normal, to: b) ?? normal
                }
            }
            let angle = (roll + twist * Float(i) / Float(max(1, n - 1))) * .pi / 180
            let nn = angle != 0 ? simd_quatf(angle: angle, axis: tangents[i]).act(normal) : normal
            out.append((tangents[i], nn, simd_cross(tangents[i], nn)))
        }
        return out
    }

    // MARK: Sweep

    /// The cross-section: points in a plane (x across, y up), and whether it is a loop.
    static func profile(_ c: ProcCook) throws -> (pts: [SIMD2<Float>], closed: Bool) {
        if c.string("surfaceshape") == "input" {
            guard c.inputs.count > 1, let sec = c.inputs[1], sec.primCount > 0 else {
                throw ProcCookError("Surface Shape is Second Input, but nothing is wired there")
            }
            let r = sec.vertexRange(0)
            return (r.map { SIMD2(sec.P[Int(sec.vertexPoint[$0])].x, sec.P[Int(sec.vertexPoint[$0])].y) }, sec.primClosed[0])
        }
        let radius = c.float("radius"), cols = max(3, c.int("cols")), width = c.float("width")
        switch c.string("surfaceshape") {
        case "square":
            let h = width / 2
            return ([SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)], true)
        case "ribbon":
            return ([SIMD2(-width / 2, 0), SIMD2(width / 2, 0)], false)
        default:
            return ((0..<cols).map { k in
                let a = 2 * Float.pi * Float(k) / Float(cols)
                return SIMD2(cos(a), sin(a)) * radius
            }, true)
        }
    }

    static func sweep(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let (shape, shapeClosed) = try profile(c)
        guard shape.count >= 2 else { throw ProcCookError("The cross-section has fewer than two points") }
        let ups = g.points.vectors3("up"), pscale = g.points.floats("pscale"), widths = g.points.floats("width")
        let scale = c.float("scale"), ramp = c.param("scaleramp").ramp, useRamp = c.bool("applyscale")
        let caps = c.bool("endcaps"), uvScale = c.vec2("uvscale"), doUV = c.bool("computeuvs")
        var out = ProcGeo()
        var pointRows: [Int32] = [], primRows: [Int32] = []
        var uvs: [SIMD2<Float>] = []
        let polygons = c.bool("polygonsasbackbones")
        for p in 0..<g.primCount where !g.isPolygon(p) || polygons {
            let r = Array(g.vertexRange(p))
            guard r.count >= 2 else { continue }
            let closed = g.primClosed[p] && r.count >= 3
            let ids = r.map { Int(g.vertexPoint[$0]) }
            let pts = ids.map { g.P[$0] }
            let f = frames(pts, closed: closed, up: c.vec3("up"), ups: ups.map { a in ids.map { a[$0] } },
                           twist: c.float("twist"), roll: c.float("roll"))
            let len = lengths(pts, closed: closed)
            let total = max(len[pts.count - 1], 1e-9)
            let base = Int32(out.P.count)
            for (i, id) in ids.enumerated() {
                var s = scale * (pscale?[id] ?? 1) * (widths.map { $0[id] } ?? 1)
                if useRamp { s *= ProcParam.sample(ramp, len[i] / total) }
                for q in shape {
                    out.P.append(pts[i] + (f[i].b * q.x + f[i].n * q.y) * s)
                    pointRows.append(Int32(id))
                }
            }
            let cols = shape.count, rows = pts.count
            let colSpans = shapeClosed ? cols : cols - 1
            let rowSpans = closed ? rows : rows - 1
            let shapeLen = lengths(shape.map { SIMD3($0.x, $0.y, 0) }, closed: shapeClosed)
            let shapeTotal = max(shapeLen[shapeLen.count - 1], 1e-9)
            for i in 0..<rowSpans {
                for k in 0..<colSpans {
                    let i1 = (i + 1) % rows, k1 = (k + 1) % cols
                    let a = base + Int32(i * cols + k), b = base + Int32(i * cols + k1)
                    let cc = base + Int32(i1 * cols + k1), d = base + Int32(i1 * cols + k)
                    // Fronts outward for a profile running counter-clockwise (the tube's).
                    out.vertexPoint += [a, d, cc, b]
                    out.primStart.append(Int32(out.vertexPoint.count))
                    out.primClosed.append(true)
                    primRows.append(Int32(p))
                    if doUV {
                        let u0 = shapeLen[k] / shapeTotal, u1 = (k + 1 == cols ? shapeTotal : shapeLen[k + 1]) / shapeTotal
                        let v0 = len[i] * uvScale.y, v1 = (i + 1 == rows ? len[rows] : len[i + 1]) * uvScale.y
                        uvs += [SIMD2(u0 * uvScale.x, v0), SIMD2(u0 * uvScale.x, v1), SIMD2(u1 * uvScale.x, v1), SIMD2(u1 * uvScale.x, v0)]
                    }
                }
            }
            if caps && !closed && shapeClosed && cols >= 3 {
                let first = (0..<Int32(cols)).map { base + $0 }
                let last = (0..<Int32(cols)).map { base + Int32((rows - 1) * cols) + $0 }
                for cap in [first, last.reversed()] {
                    out.vertexPoint += cap
                    out.primStart.append(Int32(out.vertexPoint.count))
                    out.primClosed.append(true)
                    primRows.append(Int32(p))
                    if doUV { uvs += cap.map { i in shape[Int(i - base) % cols] * 0.5 + 0.5 } }
                }
            }
        }
        out.points = g.points.gathered(pointRows)
        out.points.remove("up")
        out.prims = g.prims.gathered(primRows)
        out.vertices = AttributeTable(count: out.vertexPoint.count)
        if doUV { out.vertices.set("uv", .vector2(uvs)) }
        out.detail = g.detail
        return out
    }

    // MARK: Revolve

    static func revolve(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let o = c.vec3("origin")
        let axis = simd_length(c.vec3("dir")) > 0 ? simd_normalize(c.vec3("dir")) : SIMD3<Float>(0, 1, 0)
        let a0 = c.float("beginangle") * .pi / 180, a1 = c.float("endangle") * .pi / 180
        let divs = max(3, c.int("divs"))
        let full = abs(a1 - a0) >= 2 * .pi - 1e-4
        let steps = full ? divs : divs + 1
        var b = GeoBuilder()
        for p in 0..<g.primCount {
            let ids = g.vertexRange(p).map { Int(g.vertexPoint[$0]) }
            guard ids.count >= 2 else { continue }
            // Each profile point round the axis; one on the axis is one point.
            var ring: [[Int32]] = []
            for id in ids {
                let q = g.P[id] - o
                let along = axis * simd_dot(q, axis)
                if simd_length(q - along) < 1e-6 {
                    let i = b.addPoint(g.P[id], from: Int32(id))
                    ring.append([Int32](repeating: i, count: steps))
                    continue
                }
                ring.append((0..<steps).map { k in
                    let a = a0 + (a1 - a0) * Float(k) / Float(divs)
                    return b.addPoint(o + simd_quatf(angle: a, axis: axis).act(q), from: Int32(id))
                })
            }
            let rows = g.primClosed[p] ? ids.count : ids.count - 1
            for i in 0..<rows {
                let i1 = (i + 1) % ids.count
                for k in 0..<(full ? divs : divs) {
                    let k1 = (k + 1) % steps
                    var quad = [ring[i][k], ring[i][k1], ring[i1][k1], ring[i1][k]]
                    var dedup: [Int32] = []
                    for v in quad where dedup.last != v { dedup.append(v) }
                    while dedup.count > 1 && dedup.first == dedup.last { dedup.removeLast() }
                    guard dedup.count >= 3 else { continue }
                    quad = dedup
                    b.addPrim(quad, vertices: [Int32](repeating: -1, count: quad.count), from: Int32(p))
                }
            }
        }
        return b.build(from: g)
    }

    // MARK: PolyWire

    static func polywire(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        // A Sweep of a tube along each curve and each polygon's outline (a point's `width` scales its radius).
        let tube = ProcNode(.sweep, id: c.node.id, params: [
            "surfaceshape": .string("tube"), "radius": .float(c.float("radius")), "cols": .int(c.int("divs")),
            "endcaps": .bool(c.bool("caps")), "polygonsasbackbones": .bool(true), "computeuvs": .bool(true),
        ])
        return try sweep(ProcCook(node: tube, inputs: [g], environment: c.environment))
    }

    // MARK: Carve

    static func carve(_ c: ProcCook) throws -> ProcGeo {
        let g = try c.input()
        let u0 = max(0, min(1, c.float("firstu"))), u1 = max(0, min(1, c.float("secondu")))
        let lo = min(u0, u1), hi = max(u0, u1)
        var P: [SIMD3<Float>] = []
        var start: [Int32] = [0], src: [Int32] = [], w: [Float] = []
        var out = ProcGeo()
        var primRows: [Int32] = []
        for p in 0..<g.primCount {
            let ids = g.vertexRange(p).map { g.vertexPoint[$0] }
            guard ids.count >= 2 else { continue }
            let pts = ids.map { g.P[Int($0)] }
            let closed = g.primClosed[p]
            let len = lengths(pts, closed: closed)
            let total = len[len.count - 1]
            guard total > 0 else { continue }
            let a = lo * total, bEnd = hi * total
            let first = Int32(P.count)
            func at(_ d: Float) {
                var s = 0
                while s < len.count - 2 && len[s + 1] < d { s += 1 }
                let seg = len[s + 1] - len[s]
                let t = seg > 0 ? (d - len[s]) / seg : 0
                let i = s, j = (s + 1) % pts.count
                P.append(pts[i] + (pts[j] - pts[i]) * t)
                src += [ids[i], ids[j]]; w += [1 - t, t]; start.append(Int32(src.count))
            }
            at(a)
            for k in 1..<len.count - 1 where len[k] > a && len[k] < bEnd {
                P.append(pts[k % pts.count]); src.append(ids[k % pts.count]); w.append(1); start.append(Int32(src.count))
            }
            at(bEnd)
            out.vertexPoint += (first..<Int32(P.count)).map { $0 }
            out.primStart.append(Int32(out.vertexPoint.count))
            out.primClosed.append(false)
            primRows.append(Int32(p))
        }
        out.P = P
        out.points = g.points.blended(start: start, sources: src, weights: w)
        out.vertices = AttributeTable(count: out.vertexPoint.count)
        out.prims = g.prims.gathered(primRows)
        out.detail = g.detail
        return out
    }

    // MARK: Ends

    static func ends(_ c: ProcCook) throws -> ProcGeo {
        var g = try c.input()
        let picked = try c.group(in: g, .primitive)
        switch c.string("closeu") {
        case "close":
            for p in 0..<g.primCount where picked[p] && g.primSize(p) >= 3 { g.primClosed[p] = true }
            return g
        case "unroll":
            // A closed primitive opens, its first point again at its end (a new vertex).
            var b = GeoBuilder(points: g)
            for p in 0..<g.primCount {
                guard picked[p], g.primClosed[p], let first = g.vertexRange(p).first else { b.copyPrim(p, of: g); continue }
                let r = Array(g.vertexRange(p)) + [first]
                b.addPrim(r.map { g.vertexPoint[$0] }, vertices: r.map { Int32($0) }, from: Int32(p), closed: false)
            }
            return b.build(from: g)
        default:
            for p in 0..<g.primCount where picked[p] { g.primClosed[p] = false }
            return g
        }
    }

    // MARK: Curve

    static func curve(_ c: ProcCook) throws -> ProcGeo {
        let pts = c.param("points").points
        guard pts.count >= 2 else { throw ProcCookError("A curve needs two points or more (add them in Points)") }
        let closed = c.bool("closed") && pts.count >= 3
        var g = ProcGeo(P: pts, prims: [(0..<Int32(pts.count)).map { $0 }], closed: [closed])
        if c.string("type") == "smooth" {
            // Catmull-Rom through the points, `segs` per span.
            let segs = max(1, c.int("segs"))
            var out: [SIMD3<Float>] = []
            let spans = closed ? pts.count : pts.count - 1
            for s in 0..<spans {
                let a = s, b = (s + 1) % pts.count
                let p0 = closed || a > 0 ? pts[(a - 1 + pts.count) % pts.count] : pts[a] * 2 - pts[b]
                let p3 = closed || b + 1 < pts.count ? pts[(b + 1) % pts.count] : pts[b] * 2 - pts[a]
                for k in 0..<segs { out.append(catmullRom(p0, pts[a], pts[b], p3, Float(k) / Float(segs))) }
            }
            if !closed { out.append(pts[pts.count - 1]) }
            g = ProcGeo(P: out, prims: [(0..<Int32(out.count)).map { $0 }], closed: [closed])
        }
        return g
    }

    // MARK: L-System

    /// Rewrites `premise` by `rules` (`F=F[+F]F[-F]F`, one a line; `X:0.5=…` a stochastic one) `generations` times.
    static func rewrite(_ premise: String, rules: String, generations: Int, seed: Int) -> [Character] {
        var table: [Character: [(p: Float, to: [Character])]] = [:]
        for line in rules.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var head = parts[0].trimmingCharacters(in: .whitespaces)
            var p: Float = 1
            if let colon = head.firstIndex(of: ":") {
                p = Float(head[head.index(after: colon)...]) ?? 1
                head = String(head[..<colon])
            }
            guard let key = head.first else { continue }
            table[key, default: []].append((p, Array(parts[1].trimmingCharacters(in: .whitespaces))))
        }
        var s = Array(premise)
        var k = 0
        for _ in 0..<max(0, generations) {
            var next: [Character] = []
            next.reserveCapacity(s.count * 4)
            for ch in s {
                guard let options = table[ch] else { next.append(ch); continue }
                if options.count == 1 { next += options[0].to; continue }
                let total = options.reduce(0) { $0 + $1.p }
                var r = ProcNoise.random(k, seed: seed) * total
                k += 1
                var pick = options[options.count - 1].to
                for o in options { if r < o.p { pick = o.to; break }; r -= o.p }
                next += pick
            }
            s = next
            if s.count > 2_000_000 { break }
        }
        return s
    }

    static func lsystem(_ c: ProcCook) throws -> ProcGeo {
        let symbols = rewrite(c.string("premise"), rules: c.string("rules"), generations: c.int("generations"), seed: c.int("seed"))
        let angle = c.float("angle") * .pi / 180, variance = c.float("variance") * .pi / 180
        let step = c.float("step")
        let stepScale = c.float("stepscale"), widthScale = c.float("widthscale")
        // The turtle: where it is, its heading H, left L and up U, its step and width.
        struct Turtle { var p: SIMD3<Float>; var h: SIMD3<Float>; var l: SIMD3<Float>; var u: SIMD3<Float>; var step: Float; var width: Float; var depth: Int32; var current: Int32 }
        var t = Turtle(p: .zero, h: [0, 1, 0], l: [-1, 0, 0], u: [0, 0, 1], step: step, width: c.float("width"), depth: 0, current: -1)
        var stack: [Turtle] = []
        var P: [SIMD3<Float>] = [], width: [Float] = [], depth: [Int32] = []
        var prims: [[Int32]] = []
        var open: [Int32] = []   // the polyline being drawn
        var k = 0
        func turn(_ axis: SIMD3<Float>, _ a: Float) {
            let jitter = variance > 0 ? (ProcNoise.random(k, seed: c.int("seed"), 3) * 2 - 1) * variance : 0
            k += 1
            let q = simd_quatf(angle: a + jitter, axis: axis)
            t.h = q.act(t.h); t.l = q.act(t.l); t.u = q.act(t.u)
        }
        func point() -> Int32 {
            P.append(t.p); width.append(t.width); depth.append(t.depth)
            return Int32(P.count - 1)
        }
        func flush() { if open.count >= 2 { prims.append(open) }; open = [] }
        for ch in symbols {
            switch ch {
            case "F":
                if open.isEmpty { open = [t.current >= 0 ? t.current : point()] }
                t.p += t.h * t.step
                t.current = point()
                open.append(t.current)
            case "f":
                flush()
                t.p += t.h * t.step
                t.current = -1
            case "+": turn(t.u, angle)
            case "-": turn(t.u, -angle)
            case "&": turn(t.l, angle)
            case "^": turn(t.l, -angle)
            case "\\": turn(t.h, angle)
            case "/": turn(t.h, -angle)
            case "|": turn(t.u, .pi)
            case "[":
                stack.append(t)
                flush()
                t.depth += 1
            case "]":
                flush()
                if let s = stack.popLast() { t = s }
            case "!": t.width *= widthScale
            case "\"": t.step *= stepScale
            default: break
            }
        }
        flush()
        var g = ProcGeo(P: P, prims: prims, closed: [Bool](repeating: false, count: prims.count))
        g.points.set("width", .float(width))
        g.points.set("generation", .int(depth))
        return g
    }
}
