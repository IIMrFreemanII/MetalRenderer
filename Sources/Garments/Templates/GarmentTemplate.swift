import Characters
import Foundation
import simd

/// Ready patterns: a T-shirt, a shirt, trousers, a skirt, a dress, a hoodie and a coat, each made from a few
/// parameters (girths with their ease, lengths, a skirt's flare …) into panels, their seams, and where they go round
/// the body. `params(_:body:)` grades a kind's parameters to a body's measurements, so the same garment fits anyone;
/// `make` draws it. A garment made from one keeps its `TemplateRef`: changing a parameter draws it again.
package enum GarmentTemplate {
    package enum Kind: String, Codable, CaseIterable {
        case tshirt, shirt, pants, skirt, dress, hoodie, coat
        package var label: String {
            switch self {
            case .tshirt: return "T-shirt"
            case .shirt: return "Shirt"
            case .pants: return "Trousers"
            case .skirt: return "Skirt"
            case .dress: return "Dress"
            case .hoodie: return "Hoodie"
            case .coat: return "Coat"
            }
        }
    }

    /// A template's parameters by name (metres, or a share).
    package struct Params: Codable, Equatable {
        package var values: [String: Float] = [:]
        package init(_ values: [String: Float] = [:]) { self.values = values }
        package subscript(_ key: String) -> Float {
            get { values[key] ?? 0 }
            set { values[key] = newValue }
        }
    }

    /// One parameter as the inspector shows it.
    package struct Spec {
        package let key: String, label: String
        package let range: ClosedRange<Float>
        /// Shown in centimetres (a length), or as it is (a share).
        package let length: Bool
    }

    package static func specs(_ kind: Kind) -> [Spec] {
        func l(_ k: String, _ label: String, _ lo: Float, _ hi: Float) -> Spec { Spec(key: k, label: label, range: lo...hi, length: true) }
        func s(_ k: String, _ label: String, _ lo: Float, _ hi: Float) -> Spec { Spec(key: k, label: label, range: lo...hi, length: false) }
        let top = [l("chest", "Chest", 0.6, 1.8), l("waist", "Waist", 0.5, 1.8), l("length", "Length", 0.3, 1.4),
                   l("shoulder", "Shoulders", 0.3, 0.6), l("neck", "Neck width", 0.12, 0.3), l("neckDepth", "Neck depth", 0.02, 0.3),
                   l("armhole", "Armhole depth", 0.15, 0.32)]
        let sleeves = [l("sleeve", "Sleeve length", 0, 0.8), l("bicep", "Sleeve width", 0.24, 0.6), l("cuff", "Cuff width", 0.16, 0.5)]
        switch kind {
        case .tshirt, .hoodie: return top + sleeves
        case .shirt, .coat: return top + sleeves + [l("overlap", "Overlap", 0.01, 0.1), s("buttons", "Buttons", 0, 9)]
        case .dress: return top + sleeves + [l("hips", "Hips", 0.6, 1.8), s("flare", "Flare", 0, 1)]
        case .skirt: return [l("waist", "Waist", 0.5, 1.6), l("hips", "Hips", 0.6, 1.8), l("length", "Length", 0.2, 1.2), s("flare", "Flare", 0, 1)]
        case .pants: return [l("waist", "Waist", 0.5, 1.6), l("hips", "Hips", 0.6, 1.8), l("thigh", "Thigh", 0.4, 1.0),
                             l("inseam", "Inseam", 0.4, 1.0), l("rise", "Rise", 0.18, 0.36), l("hem", "Hem width", 0.3, 0.8)]
        }
    }

    /// `kind`'s parameters for `body`, with `ease` (metres round the chest, the waist and the hips) for comfort.
    package static func params(_ kind: Kind, body m: BodyMeasurements, ease: Float = 0.1) -> Params {
        var p = Params()
        let shoulderToHip = m.shoulderHeight - m.hipHeight
        p["chest"] = m.chest + ease
        p["waist"] = m.waist + ease
        p["hips"] = m.hips + ease
        p["shoulder"] = m.shoulderWidth
        p["neck"] = max(0.14, min(0.2, m.neck / 2.3))
        p["neckDepth"] = 0.07
        p["armhole"] = max(0.18, (m.shoulderHeight - m.chestHeight) + 0.08)
        p["bicep"] = m.upperArm + ease * 0.8
        p["cuff"] = m.upperArm * 0.85 + ease * 0.4
        p["thigh"] = m.thigh + ease * 0.8
        p["inseam"] = m.crotchHeight - m.ankleHeight - 0.02
        p["rise"] = max(0.18, m.waistHeight - m.crotchHeight + 0.02)
        p["hem"] = m.thigh * 0.7 + ease
        p["overlap"] = 0.03
        p["buttons"] = 5
        p["flare"] = 0.4
        switch kind {
        case .tshirt: p["length"] = shoulderToHip + 0.12; p["sleeve"] = 0.2
        case .hoodie: p["length"] = shoulderToHip + 0.14; p["sleeve"] = m.armLength * 0.98; p["chest"] = m.chest + ease * 1.6
            p["cuff"] = m.upperArm * 0.7
        case .shirt: p["length"] = shoulderToHip + 0.2; p["sleeve"] = m.armLength * 0.95; p["neckDepth"] = 0.06
            p["cuff"] = m.upperArm * 0.75
        case .coat: p["length"] = m.shoulderHeight - m.kneeHeight + 0.05; p["sleeve"] = m.armLength; p["chest"] = m.chest + ease * 2.2
            p["waist"] = m.waist + ease * 2.6; p["overlap"] = 0.06; p["cuff"] = m.upperArm * 0.95
        case .dress: p["length"] = m.shoulderHeight - m.kneeHeight + 0.02; p["sleeve"] = 0.12; p["flare"] = 0.5
            p["waist"] = m.waist + ease * 0.5
        case .skirt: p["length"] = m.waistHeight - m.kneeHeight + 0.04; p["waist"] = m.waist + 0.01
        case .pants: p["waist"] = m.waist + 0.02
        }
        return p
    }

    /// A garment drawn from `kind` at `p`, placed for `body`.
    package static func make(_ kind: Kind, _ p: Params, body m: BodyMeasurements) -> Garment {
        var b = PatternBuilder(name: kind.label, body: m)
        switch kind {
        case .tshirt: b.top(p, split: false, hood: false, collar: false)
        case .hoodie: b.top(p, split: false, hood: true, collar: false)
        case .shirt: b.top(p, split: true, hood: false, collar: true)
        case .coat: b.top(p, split: true, hood: false, collar: false)
        case .dress: b.top(p, split: false, hood: false, collar: false, dress: true)
        case .skirt: b.skirt(p)
        case .pants: b.pants(p)
        }
        b.g.template = TemplateRef(kind: kind, params: p)
        switch kind {
        case .pants: b.g.fabrics = [.preset(.denim)]
        case .coat: b.g.fabrics = [.preset(.wool)]
        case .hoodie: b.g.fabrics = [.preset(.knit)]
        case .dress, .skirt: b.g.fabrics = [.preset(.silk)]
        case .tshirt, .shirt: b.g.fabrics = [.preset(.cotton)]
        }
        return b.g
    }
}

/// Draws panels side by side on the sheet and sews them, by their edges in the order they were drawn ("canonical"
/// edges: a mirrored panel's are found through `mirroredEdge`, run backwards).
struct PatternBuilder {
    var g: Garment
    let body: BodyMeasurements
    private var cursor: Float = 0

    init(name: String, body: BodyMeasurements) {
        g = Garment(name: name)
        self.body = body
    }

    /// A panel from `points` (around its own origin), set down to the right of the last.
    @discardableResult
    mutating func panel(_ name: String, _ points: [PathPoint], _ slot: ArrangementSlot, height: Float, around: Float = 0,
                        flipped: Bool = false, lines: [InternalLine] = []) -> Int {
        var p = Panel(id: g.nextPanelID, name: name, points: points)
        p.lines = lines
        let lo = p.bounds.lo
        p.translate(SIMD2(cursor - lo.x, -lo.y))
        cursor = p.bounds.hi.x + 0.12
        p.arrangement = Arrangement(slot: slot, offset: SIMD2(around, height), flipped: flipped)
        g.panels.append(p)
        return p.id
    }

    /// Panel `id`'s mirror image, set down to the right, on `slot`.
    @discardableResult
    mutating func mirror(_ id: Int, _ name: String, _ slot: ArrangementSlot, height: Float, around: Float = 0, flipped: Bool = false) -> Int {
        guard let src = g.panel(id: id) else { return -1 }
        var p = src.mirrored(axis: src.centre.x)
        p.id = g.nextPanelID
        p.name = name
        p.mirrorOf = id
        let lo = p.bounds.lo
        p.translate(SIMD2(cursor - lo.x, 0))
        cursor = p.bounds.hi.x + 0.12
        p.arrangement = Arrangement(slot: slot, offset: SIMD2(around, height), flipped: flipped)
        g.panels.append(p)
        return p.id
    }

    /// Canonical edge `e` of panel `id` from `t0` to `t1` (of a mirrored panel: the edge it became, the other way).
    func end(_ id: Int, _ e: Int, _ t0: Float = 0, _ t1: Float = 1) -> SeamEnd {
        guard let p = g.panel(id: id), let src = p.mirrorOf.flatMap({ g.panel(id: $0) }) else { return SeamEnd(panel: id, edge: e, t0: t0, t1: t1) }
        return SeamEnd(panel: id, edge: src.mirroredEdge(e), t0: 1 - t0, t1: 1 - t1)
    }

    mutating func sew(_ a: [SeamEnd], _ b: [SeamEnd], kind: Seam.Kind = .normal) {
        g.seams.append(Seam(id: g.nextSeamID, a: a, b: b, kind: kind))
    }

    // MARK: Tops

    /// A bodice's outline: the hem, the right side up to the armpit (`side`, from the hem), the armhole, shoulder,
    /// the neck, and the left the same. `split`: half of the front, its centre line `overlap` past the middle.
    static func bodice(side: [SIMD2<Float>], top h: Float, shoulder s: Float, drop: Float, neck n: Float, neckDepth nd: Float,
                       half: Bool = false, overlap: Float = 0) -> [PathPoint] {
        let armpit = side.last!, tip = SIMD2<Float>(s, h - drop)
        let inward = (armpit.x - tip.x) * 0.85, rise = (tip.y - armpit.y) * 0.55
        var pts: [PathPoint] = []
        pts.append(PathPoint(SIMD2(half ? -overlap : -side[0].x, 0)))
        for (k, q) in side.enumerated() {
            var pp = PathPoint(q)
            if k == side.count - 1 { pp.handleOut = SIMD2(-inward, 0) }
            pts.append(pp)
        }
        pts.append(PathPoint(tip, handleIn: SIMD2(inward * 0.18, -rise)))
        if half {
            pts.append(PathPoint(SIMD2(n, h), handleOut: SIMD2(0, -nd * 0.9)))
            pts.append(PathPoint(SIMD2(-overlap, h - nd), handleIn: SIMD2(n * 0.55, 0)))
            return pts
        }
        pts.append(PathPoint(SIMD2(n, h), handleOut: SIMD2(0, -nd * 1.3)))
        pts.append(PathPoint(SIMD2(-n, h), handleIn: SIMD2(0, -nd * 1.3)))
        pts.append(PathPoint(SIMD2(-tip.x, tip.y), handleOut: SIMD2(-inward * 0.18, -rise)))
        for (k, q) in side.reversed().enumerated() where k < side.count - 1 {
            var pp = PathPoint(SIMD2(-q.x, q.y))
            if k == 0 { pp.handleIn = SIMD2(inward, 0) }
            pts.append(pp)
        }
        return pts
    }

    /// A sleeve: the cuff at the bottom, the cap at the top (its height made so the cap's length is the armhole's,
    /// a little eased).
    static func sleeve(length: Float, bicep: Float, cuff: Float, armhole: Float) -> [PathPoint] {
        func pts(_ ch: Float) -> [PathPoint] {
            [PathPoint(SIMD2(-cuff / 2, 0)), PathPoint(SIMD2(cuff / 2, 0)),
             PathPoint(SIMD2(bicep / 2, length), handleOut: SIMD2(0, ch * 0.6)),
             PathPoint(SIMD2(0, length + ch), handleIn: SIMD2(bicep * 0.32, 0), handleOut: SIMD2(-bicep * 0.32, 0)),
             PathPoint(SIMD2(-bicep / 2, length), handleIn: SIMD2(0, ch * 0.6))]
        }
        var lo: Float = 0.02, hi: Float = 0.3
        for _ in 0..<24 {
            let ch = (lo + hi) / 2
            let p = Panel(id: 0, name: "", points: pts(ch))
            if p.edge(2).length + p.edge(3).length < armhole * 1.04 { lo = ch } else { hi = ch }
        }
        return pts((lo + hi) / 2)
    }

    mutating func top(_ p: GarmentTemplate.Params, split: Bool, hood: Bool, collar: Bool, dress: Bool = false) {
        let m = body
        let w = p["chest"] / 4, h = p["length"], s = p["shoulder"] / 2, n = p["neck"] / 2
        let drop: Float = 0.045
        let top = max(m.shoulderHeight + 0.08, m.neckHeight + 0.04)
        let armpitY = h - p["armhole"]
        // The side from the hem: straight, or a dress's waist in and hips out to its flare.
        var side: [SIMD2<Float>] = [SIMD2(w, 0), SIMD2(w, armpitY)]
        if dress {
            let waistY = h - (top - m.waistHeight), hipY = h - (top - m.hipHeight)
            let hipW = p["hips"] / 4, hem = hipW * (1 + p["flare"] * 0.9)
            side = [SIMD2(hem, 0), SIMD2(hipW, hipY), SIMD2(p["waist"] / 4, waistY), SIMD2(w, armpitY)]
        } else if p["waist"] > 0, split {
            side = [SIMD2(max(w, p["waist"] / 4), 0), SIMD2(w, armpitY)]
        }
        let k = side.count
        let centre = top - h / 2
        let backNeckDepth: Float = 0.02
        let back = panel("Back", Self.bodice(side: side, top: h, shoulder: s, drop: drop, neck: n, neckDepth: backNeckDepth), .chestBack,
                         height: centre)
        // Edges of a whole bodice: 0 hem, 1..<k side right, k armhole right, k+1 shoulder right, k+2 neck, k+3 shoulder
        // left, k+4 armhole left, k+5... side left down to the hem.
        let sideRight = (1..<k).map { $0 }, sideLeftDown = ((k + 5)...(2 * k + 3)).map { $0 }
        func up(_ id: Int, right: Bool) -> [SeamEnd] {
            right ? sideRight.map { end(id, $0) } : sideLeftDown.reversed().map { end(id, $0, 1, 0) }
        }
        // The armholes, each from the armpit to the shoulder's tip; the neck's halves, each from the middle out to the side.
        var frontPlus: SeamEnd, frontMinus: SeamEnd, neckFrontPlus: SeamEnd, neckFrontMinus: SeamEnd
        if split {
            let ov = p["overlap"]
            let half = Self.bodice(side: side, top: h, shoulder: s, drop: drop, neck: n, neckDepth: p["neckDepth"], half: true, overlap: ov)
            let left = panel("Front left", half, .chestFront, height: centre, around: (w - ov) / 2)
            let right = mirror(left, "Front right", .chestFront, height: centre, around: -(w - ov) / 2)
            // Half edges: 0 hem, 1..<k side, k armhole, k+1 shoulder, k+2 neck (side to middle), k+3 centre front.
            sew(sideRight.map { end(left, $0) }, up(back, right: false))
            sew(sideRight.map { end(right, $0) }, up(back, right: true))
            sew([end(left, k + 1)], [end(back, k + 3, 1, 0)])
            sew([end(right, k + 1)], [end(back, k + 1)])
            frontPlus = end(left, k); frontMinus = end(right, k)
            neckFrontPlus = end(left, k + 2, 1, 0); neckFrontMinus = end(right, k + 2, 1, 0)
            // Buttons down the overlap, from the neck to near the hem.
            let count = Int(p["buttons"].rounded())
            if count > 0, let lp = g.panel(id: left), let rp = g.panel(id: right) {
                let lx = lp.bounds.lo.x + ov, rx = rp.bounds.hi.x - ov
                for i in 0..<count {
                    let y = (h - p["neckDepth"] - 0.03) - Float(i) * (h - p["neckDepth"] - 0.12) / Float(max(1, count - 1))
                    g.buttons.append(Button(panel: right, at: SIMD2(rx, y), holePanel: left, hole: SIMD2(lx, y)))
                }
            }
        } else {
            let neckDepth = dress ? p["neckDepth"] * 1.4 : p["neckDepth"]
            let front = panel("Front", Self.bodice(side: side, top: h, shoulder: s, drop: drop, neck: n, neckDepth: neckDepth), .chestFront,
                              height: centre)
            sew(up(front, right: true), up(back, right: false))
            sew(up(front, right: false), up(back, right: true))
            sew([end(front, k + 1)], [end(back, k + 3, 1, 0)])
            sew([end(front, k + 3, 1, 0)], [end(back, k + 1)])
            frontPlus = end(front, k); frontMinus = end(front, k + 4, 1, 0)
            neckFrontPlus = end(front, k + 2, 0.5, 0); neckFrontMinus = end(front, k + 2, 0.5, 1)
        }
        let backPlus = end(back, k + 4, 1, 0), backMinus = end(back, k)
        let neckBackPlus = end(back, k + 2, 1, 0.5), neckBackMinus = end(back, k + 2, 0, 0.5)
        // Sleeves: on the left arm the sheet's +x goes round to the back; on the right, to the front.
        if p["sleeve"] > 0.03, let bp = g.panel(id: back) {
            let armhole = bp.edge(k).length * 2
            let pts = Self.sleeve(length: p["sleeve"], bicep: p["bicep"], cuff: p["cuff"], armhole: armhole)
            let height = (pts[3].p.y - pts[0].p.y)
            let along = 0.03 - height / 2
            let left = panel("Sleeve left", pts, .armLeft, height: along)
            let right = panel("Sleeve right", pts, .armRight, height: along)
            sew([end(left, 2)], [backPlus])
            sew([end(left, 3, 1, 0)], [frontPlus])
            sew([end(right, 2)], [frontMinus])
            sew([end(right, 3, 1, 0)], [backMinus])
            for id in [left, right] { sew([end(id, 1)], [end(id, 4, 1, 0)]) }
        }
        if hood {
            let hw = (SeamSampling.length(g, neckFrontPlus) + SeamSampling.length(g, neckBackPlus)) * 1.04, hh: Float = 0.34
            // The face's edge, the neck, the back of the head rounded over to the top.
            let pts = [PathPoint(SIMD2(0, 0)), PathPoint(SIMD2(hw, 0)), PathPoint(SIMD2(hw * 1.05, hh * 0.45), handleOut: SIMD2(0, hh * 0.35)),
                       PathPoint(SIMD2(hw * 0.4, hh), handleIn: SIMD2(hw * 0.4, 0), handleOut: SIMD2(-hw * 0.2, 0)), PathPoint(SIMD2(0, hh * 0.95))]
            let headY = m.neckHeight + hh / 2 - 0.03
            let plus = panel("Hood left", pts, .head, height: headY, around: hw / 2)
            let minus = mirror(plus, "Hood right", .head, height: headY, around: -hw / 2)
            sew([end(plus, 1), end(plus, 2), end(plus, 3)], [end(minus, 1), end(minus, 2), end(minus, 3)])
            sew([end(plus, 0)], [neckFrontPlus, neckBackPlus])
            sew([end(minus, 0)], [neckFrontMinus, neckBackMinus])
        }
        if collar {
            // A band round the neck, from the left front's middle round the back to the right's.
            let ends = [neckFrontMinus, neckBackMinus, neckBackPlus.reversed, neckFrontPlus.reversed]
            let length = ends.reduce(Float(0)) { $0 + SeamSampling.length(g, $1) }
            let band: [PathPoint] = [PathPoint(SIMD2(0, 0)), PathPoint(SIMD2(length, 0)), PathPoint(SIMD2(length, 0.04)), PathPoint(SIMD2(0, 0.04))]
            let c = panel("Collar", band, .neckBack, height: m.neckHeight - 0.02, flipped: true)
            sew([end(c, 0)], ends)
        }
    }

    // MARK: Skirt, trousers

    mutating func skirt(_ p: GarmentTemplate.Params) {
        let m = body
        let ww = p["waist"] / 4, hw = max(ww, p["hips"] / 4), L = p["length"]
        let hem = hw * (1 + p["flare"] * 1.2)
        let curve = (hem - ww) * 0.25
        func pts(_ dip: Float) -> [PathPoint] {
            [PathPoint(SIMD2(-hem, 0), handleOut: SIMD2(hem * 0.5, -curve)), PathPoint(SIMD2(hem, 0), handleIn: SIMD2(-hem * 0.5, -curve)),
             PathPoint(SIMD2(hw, L - 0.18)),
             PathPoint(SIMD2(ww, L), handleIn: SIMD2(0, -0.06), handleOut: SIMD2(-ww * 0.5, -dip)),
             PathPoint(SIMD2(-ww, L), handleIn: SIMD2(ww * 0.5, -dip), handleOut: SIMD2(0, -0.06)),
             PathPoint(SIMD2(-hw, L - 0.18))]
        }
        let centre = m.waistHeight + 0.02 - L / 2
        let front = panel("Front", pts(0.01), .hipsFront, height: centre)
        let back = panel("Back", pts(0), .hipsBack, height: centre)
        // Edges: 0 hem, 1 side right low, 2 side right high, 3 waist, 4 side left high, 5 side left low.
        sew([end(front, 1), end(front, 2)], [end(back, 5, 1, 0), end(back, 4, 1, 0)])
        sew([end(front, 5, 1, 0), end(front, 4, 1, 0)], [end(back, 1), end(back, 2)])
    }

    mutating func pants(_ p: GarmentTemplate.Params) {
        let m = body
        let hip = p["hips"] / 4, waist = p["waist"] / 4, thigh = p["thigh"] / 2, rise = p["rise"], inseam = p["inseam"]
        let hem = p["hem"] / 2, H = inseam + rise
        // A leg's half, its outer side to +x: 0 hem, 1 outseam, 2 hip curve, 3 waist, 4 the crotch's curve, 5 inseam.
        func half(front: Bool) -> [PathPoint] {
            let ext: Float = front ? 0.045 : 0.1
            let centre = hip * (front ? 0.42 : 0.5), outer = hip * (front ? 0.58 : 0.5)
            let crotchX = -(thigh / 2 + ext * 0.4)
            let wTop: Float = front ? 0 : 0.03
            return [PathPoint(SIMD2(-hem / 2, 0)), PathPoint(SIMD2(hem / 2, 0)),
                    PathPoint(SIMD2(outer, H - rise * 0.8), handleOut: SIMD2(0, rise * 0.4)),
                    PathPoint(SIMD2(outer - (hip - waist) * 0.5, H), handleIn: SIMD2(0.01, -0.06)),
                    PathPoint(SIMD2(-centre + (hip - waist) * 0.5, H + wTop), handleOut: SIMD2(0, -rise * 0.55)),
                    PathPoint(SIMD2(min(crotchX, -centre - ext), H - rise), handleIn: SIMD2(ext * 0.7, 0))]
        }
        let centre = m.waistHeight + 0.02 - H / 2
        let fl = panel("Front left", half(front: true), .legLeftFront, height: centre)
        let br = panel("Back right", half(front: false), .legRightBack, height: centre)
        let fr = mirror(fl, "Front right", .legRightFront, height: centre)
        let bl = mirror(br, "Back left", .legLeftBack, height: centre)
        for (a, b) in [(fl, bl), (fr, br)] {
            sew([end(a, 1), end(a, 2)], [end(b, 1), end(b, 2)])   // outseams
            sew([end(a, 5)], [end(b, 5)])                         // inseams
        }
        sew([end(fl, 4)], [end(fr, 4)])   // the front's rise
        sew([end(bl, 4)], [end(br, 4)])   // the back's
    }
}
