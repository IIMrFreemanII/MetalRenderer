import Foundation
import simd

/// A body's skin as a signed distance in its rest space (negative inside), kept on a grid within `band` of it: what
/// the muscle atlas sculpts to. The mesh may be in pieces (a Mixamo bot's panels and joints overlap): which side is
/// in is found by flooding the grid from outside, around the cells the skin passes near (a gap narrower than about
/// four cells is closed), and the distance is to the skin the flood meets, not to a joint's piece inside the body.
struct BodySurface {
    let lo: SIMD3<Float>
    let cell: Float
    let counts: SIMD3<Int>
    let band: Float
    private let values: [Float]

    /// `solids`: shapes (each its bounds and distance) that are inside too, within a centimetre of the mesh, whatever
    /// it says there (a bot's hollow elbows, its deep grooves).
    init(_ mesh: MeshGeometry, cell: Float = 0.006, band: Float = 0.05, smoothing: Int = 3,
         solids: [(bounds: AABB, distance: (SIMD3<Float>) -> Float)] = []) {
        self.cell = cell
        self.band = band
        let margin = SIMD3<Float>(repeating: band + 2 * cell)
        let lo = mesh.positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) } - margin
        let hi = mesh.positions.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) } + margin
        let n = SIMD3<Int>(((hi - lo) / cell).rounded(.up)) &+ 1
        self.lo = lo
        counts = n
        @inline(__always) func at(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * n.y + y) * n.x + x }
        var boxes: [(lo: SIMD3<Int>, hi: SIMD3<Int>)] = []
        for t in 0..<(mesh.indices.count / 3) {
            let corners = (0..<3).map { mesh.positions[Int(mesh.indices[3 * t + $0])] }
            let a = simd_min(simd_min(corners[0], corners[1]), corners[2]) - band - lo
            let b = simd_max(simd_max(corners[0], corners[1]), corners[2]) + band - lo
            boxes.append((simd_max(SIMD3<Int>((a / cell).rounded(.down)), .zero), simd_min(SIMD3<Int>((b / cell).rounded(.up)), n &- 1)))
        }
        // The distance to the nearest of `triangles` within the band, signed by its facing; each z slab of the grid
        // from the triangles near it.
        func nearest(_ triangles: [Int]) -> [Float] {
            var slabs = [[Int32]](repeating: [], count: n.z)
            for t in triangles { for z in boxes[t].lo.z...boxes[t].hi.z { slabs[z].append(Int32(t)) } }
            var d = [Float](repeating: band, count: n.x * n.y * n.z)
            d.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: n.z) { z in
                    for t in slabs[z] {
                        let i = Int(t)
                        let a = mesh.positions[Int(mesh.indices[3 * i])], b = mesh.positions[Int(mesh.indices[3 * i + 1])],
                            c = mesh.positions[Int(mesh.indices[3 * i + 2])]
                        let normal = simd_cross(b - a, c - a)
                        guard simd_length_squared(normal) > 1e-16 else { continue }
                        let box = boxes[i]
                        for y in box.lo.y...box.hi.y {
                            for x in box.lo.x...box.hi.x {
                                let p = lo + SIMD3(Float(x), Float(y), Float(z)) * cell
                                let (q, _) = SkinShell.closest(p, a, b, c)
                                let distance = simd_length(p - q)
                                let k = at(x, y, z)
                                if distance < abs(out[k]) { out[k] = simd_dot(p - q, normal) >= 0 ? distance : -distance }
                            }
                        }
                    }
                }
            }
            return d
        }
        let neighbours = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
        // Outside: what a flood from the grid's corner reaches without passing within two cells of the skin.
        let wall = 2 * cell
        let all = nearest(Array(0..<(mesh.indices.count / 3)))
        var outside = [Bool](repeating: false, count: all.count)
        var queue = [0]
        outside[0] = true
        var head = 0
        while head < queue.count {
            let k = queue[head]
            head += 1
            let x = k % n.x, y = (k / n.x) % n.y, z = k / (n.x * n.y)
            for (dx, dy, dz) in neighbours {
                let (u, v, w) = (x + dx, y + dy, z + dz)
                guard u >= 0, v >= 0, w >= 0, u < n.x, v < n.y, w < n.z else { continue }
                let j = at(u, v, w)
                guard !outside[j], abs(all[j]) >= wall else { continue }
                outside[j] = true
                queue.append(j)
            }
        }
        // The skin: the triangles with the outside within four cells of a corner or their middle (not a piece within
        // the body, a joint's inside the bot's panels, whose distance would hold everything near it shallow).
        let outer = (0..<(mesh.indices.count / 3)).filter { t in
            let corners = (0..<3).map { mesh.positions[Int(mesh.indices[3 * t + $0])] }
            for p in corners + [(corners[0] + corners[1] + corners[2]) / 3] {
                let c = SIMD3<Int>(((p - lo) / cell).rounded(.toNearestOrAwayFromZero))
                for dz in -4...4 {
                    for dy in -4...4 {
                        for dx in -4...4 {
                            let q = c &+ SIMD3(dx, dy, dz)
                            if q.x >= 0, q.y >= 0, q.z >= 0, q.x < n.x, q.y < n.y, q.z < n.z, outside[at(q.x, q.y, q.z)] { return true }
                        }
                    }
                }
            }
            return false
        }
        // Signed by the flood: a cell it reached is out, one beyond the skin's cells is in, and one of those (near
        // the skin) as the skin's triangle nearest it faces.
        var signed = nearest(outer)
        for k in signed.indices {
            if outside[k] { signed[k] = abs(signed[k]) } else if abs(signed[k]) >= wall { signed[k] = -abs(signed[k]) }
        }
        for solid in solids {
            let first = simd_max(SIMD3<Int>(((solid.bounds.lo - lo) / cell).rounded(.down)), .zero)
            let last = simd_min(SIMD3<Int>(((solid.bounds.hi - lo) / cell).rounded(.up)), n &- 1)
            guard first.x <= last.x, first.y <= last.y, first.z <= last.z else { continue }
            signed.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: last.z - first.z + 1) { k in
                    let z = first.z + k
                    for y in first.y...last.y {
                        for x in first.x...last.x {
                            let i = at(x, y, z)
                            guard out[i] < 0.01 else { continue }   // not across open air (a T pose's armpit)
                            let d = solid.distance(lo + SIMD3(Float(x), Float(y), Float(z)) * cell)
                            out[i] = min(out[i], max(d, -band))
                        }
                    }
                }
            }
        }
        // Smoothed (a box filter `smoothing` cells wide each way, twice: near a Gaussian): the bot's grooves between
        // its panels, narrower than about two of them, close.
        values = BodySurface.smoothed(signed, n, radius: smoothing)
    }

    /// `values` (a grid of `n`) box-filtered `radius` cells each way along each axis, twice.
    static func smoothed(_ values: [Float], _ n: SIMD3<Int>, radius: Int) -> [Float] {
        guard radius > 0 else { return values }
        var a = values, b = values
        let strides = [1, n.x, n.x * n.y], lengths = [n.x, n.y, n.z]
        for _ in 0..<2 {
            for axis in 0..<3 {
                let stride = strides[axis], length = lengths[axis], lines = values.count / length
                a.withUnsafeBufferPointer { source in
                    b.withUnsafeMutableBufferPointer { out in
                        DispatchQueue.concurrentPerform(iterations: lines) { line in
                            // The line's first sample: every index whose coordinate along `axis` is 0.
                            let start: Int
                            switch axis {
                            case 0: start = line * n.x
                            case 1: start = (line / n.x) * n.x * n.y + line % n.x
                            default: start = line
                            }
                            var sum: Float = 0
                            for k in -radius...radius { sum += source[start + min(max(k, 0), length - 1) * stride] }
                            let width = Float(2 * radius + 1)
                            for k in 0..<length {
                                out[start + k * stride] = sum / width
                                sum += source[start + min(k + radius + 1, length - 1) * stride] - source[start + max(k - radius, 0) * stride]
                            }
                        }
                    }
                }
                swap(&a, &b)
            }
        }
        return a
    }

    /// The signed distance at `p` (trilinear between the grid's samples; `band` beyond them).
    func distance(_ p: SIMD3<Float>) -> Float {
        let g = (p - lo) / cell
        let f = g.rounded(.down)
        let i = SIMD3<Int>(f)
        guard i.x >= 0, i.y >= 0, i.z >= 0, i.x < counts.x - 1, i.y < counts.y - 1, i.z < counts.z - 1 else { return band }
        let t = g - f
        @inline(__always) func v(_ x: Int, _ y: Int, _ z: Int) -> Float { values[((i.z + z) * counts.y + i.y + y) * counts.x + i.x + x] }
        let x00 = v(0, 0, 0) + (v(1, 0, 0) - v(0, 0, 0)) * t.x, x10 = v(0, 1, 0) + (v(1, 1, 0) - v(0, 1, 0)) * t.x
        let x01 = v(0, 0, 1) + (v(1, 0, 1) - v(0, 0, 1)) * t.x, x11 = v(0, 1, 1) + (v(1, 1, 1) - v(0, 1, 1)) * t.x
        let y0 = x00 + (x10 - x00) * t.y, y1 = x01 + (x11 - x01) * t.y
        return y0 + (y1 - y0) * t.z
    }

    /// Its gradient at `p` (central differences half a cell apart).
    func gradient(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let h = cell / 2
        return SIMD3(distance(p + [h, 0, 0]) - distance(p - [h, 0, 0]), distance(p + [0, h, 0]) - distance(p - [0, h, 0]),
                     distance(p + [0, 0, h]) - distance(p - [0, 0, h])) / (2 * h)
    }

    /// `p` moved to `depth` under the skin along the gradient (where it is within the band).
    func inset(_ p: SIMD3<Float>, depth: Float) -> SIMD3<Float> {
        var p = p
        for _ in 0..<6 {
            let g = gradient(p), len2 = simd_length_squared(g)
            guard len2 > 0.04 else { break }
            let step = (distance(p) + depth) / len2
            p -= g * min(max(step, -0.01), 0.01)
        }
        return p
    }

    /// Its whole extent.
    var bounds: AABB { AABB(lo: lo, hi: lo + SIMD3<Float>(counts &- 1) * cell) }
}

/// Where marks are on a character's body (MuscleAtlas.Mark): its trunk's line (the hips' joint to the neck's, through
/// the spine's), and a mark's point under its skin.
struct BodyMarks {
    let rig: CharacterRig
    let body: BodySurface
    let trunk: [SIMD3<Float>]
    /// How far along the trunk's line each of its points is.
    let lengths: [Float]

    init(_ rig: CharacterRig, body: BodySurface) {
        self.rig = rig
        self.body = body
        let spine = rig.bones.prefix { $0.role == .pelvis || $0.role == .spine || $0.role == .chest }
        trunk = spine.map(\.from) + [spine.last!.to]
        var lengths = [Float(0)]
        for k in 1..<trunk.count { lengths.append(lengths[k - 1] + simd_length(trunk[k] - trunk[k - 1])) }
        self.lengths = lengths
    }

    func bone(_ role: FleshFigure.Role) -> CharacterRig.Bone? { rig.bones.first { $0.role == role } }

    /// Where a mark's ray starts (on its trunk's line or bone), along what, and which way it goes.
    func ray(_ mark: MuscleAtlas.Mark, side s: Float) -> (origin: SIMD3<Float>, axis: SIMD3<Float>, direction: SIMD3<Float>) {
        func across(_ v: SIMD3<Float>, _ axis: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(v - axis * simd_dot(v, axis)) }
        let origin: SIMD3<Float>, axis: SIMD3<Float>, outer: SIMD3<Float>
        switch mark.place {
        case .trunk(let h):
            let at = h * lengths.last!
            let k = min(max(lengths.lastIndex { $0 <= at } ?? 0, 0), trunk.count - 2)
            let f = (at - lengths[k]) / (lengths[k + 1] - lengths[k])
            origin = trunk[k] + (trunk[k + 1] - trunk[k]) * f
            axis = simd_normalize(trunk[k + 1] - trunk[k])
            outer = [s, 0, 0]
        case .on(let role, let u):
            let b = bone(role)!
            origin = b.from + (b.to - b.from) * u
            axis = simd_normalize(b.to - b.from)
            switch role {
            case .upperArm, .forearm, .hand: outer = [0, 1, 0]
            default: outer = [s, 0, 0]
            }
        }
        let front = across([0, 0, 1], axis), side = across(outer, axis)
        let a = mark.angle * .pi / 180
        return (origin, axis, simd_normalize(front * cos(a) + side * sin(a)))
    }

    /// A mark's point: out from its place at its angle to `depth` under the skin.
    func resolve(_ mark: MuscleAtlas.Mark, side s: Float, depth: Float) -> SIMD3<Float> {
        let r = ray(mark, side: s)
        var p = r.origin
        for _ in 0..<100 where body.distance(p) < -depth { p += r.direction * 0.0025 }
        return p
    }

    /// From `p` along `direction` to where it is `depth` under the skin (to a millimetre).
    func out(_ p: SIMD3<Float>, _ direction: SIMD3<Float>, depth: Float) -> SIMD3<Float> {
        var p = p
        let step = simd_normalize(direction) * 0.001
        for _ in 0..<400 where body.distance(p) < -depth { p += step }
        return p
    }

    /// A Catmull-Rom curve through `points`, `samples` points evenly along it.
    static func curve(_ p: [SIMD3<Float>], samples: Int) -> [SIMD3<Float>] {
        let ends = [2 * p[0] - p[1]] + p + [2 * p[p.count - 1] - p[p.count - 2]]
        var dense: [SIMD3<Float>] = []
        for k in 0..<(p.count - 1) {
            for i in 0..<40 {
                let t = Float(i) / 40, t2 = t * t, t3 = t2 * t
                let (a, b, c, d) = (ends[k], ends[k + 1], ends[k + 2], ends[k + 3])
                dense.append(0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3))
            }
        }
        dense.append(p.last!)
        var along = [Float(0)]
        for k in 1..<dense.count { along.append(along[k - 1] + simd_length(dense[k] - dense[k - 1])) }
        return (0..<samples).map { i in
            let target = along.last! * Float(i) / Float(samples - 1)
            let k = min(along.lastIndex { $0 <= target } ?? 0, dense.count - 2)
            let f = (target - along[k]) / max(along[k + 1] - along[k], 1e-9)
            return dense[k] + (dense[k + 1] - dense[k]) * f
        }
    }
}

/// An écorché of a character: its muscles as shapes of their own, sculpted on its skin (BodySurface) in its rest pose
/// and drawn in place of it (Scene+Muscles.swift), in the flesh's lattice like any drawn surface: the flesh's muscles
/// (MuscleSpec) bulge the ones on them. Like Unreal's Chaos Flesh muscle model (its "Emil"), but made here, from the
/// character's bones: each muscle runs from its origin to its insertion through marks on the bones, a tube (a
/// fusiform muscle, wider along the skin than into it) or a sheet across several such strands (a fan, a strap), red in
/// its belly and white at its tendons, its fibres striped along it. Each is clipped `fat` under the skin, carved a
/// `gap` from the layers above it, and shares with its own layer's neighbours what they both fill, cut where it is
/// equally deep in each, so that they lie side by side with a groove between; under them all a fascia, the skin
/// `fascia` deeper, fills what the grooves show. The head, the hands and the feet are the character's own mesh.
struct MuscleAtlas {
    /// Where a mark is: up the trunk (0 at the hips' joint, 1 at the neck's; beyond that along its ends), or along a
    /// bone (0 at its joint, 1 at the next).
    enum Place {
        case trunk(Float)
        case on(FleshFigure.Role, Float)
    }

    /// A point a muscle passes: from its place out to the skin at `angle` (degrees) round the trunk or bone, 0 its
    /// front and 90 its outer side (the trunk's and the legs' away from the middle, the arms' up: in the T pose their
    /// outer side), then the muscle's depth back under it.
    struct Mark {
        var place: Place
        var angle: Float
    }

    struct Muscle {
        var name: String
        var side: Float
        /// 0: on top; 1: under others (carved by them all).
        var layer = 0
        /// Its strands, each origin to insertion: one is a tube's axis; more, across a sheet in order.
        var strands: [[Mark]]
        /// A tube's belly's radius, a sheet's half its thickness (m), and how deep its middle is under the skin.
        var radius: Float
        var depth: Float
        /// Where along it the belly is fullest (0...1), and its tendons' shares of its length at each end.
        var peak: Float = 0.5
        var tendons: SIMD2<Float> = [0.08, 0.15]
        /// How much wider than deep a tube's section is (along the skin).
        var wide: Float = 1.8
    }

    static let fat: Float = 0.004
    static let gap: Float = 0.0012
    static let fascia: Float = 0.014
    static let tendonRadius: Float = 0.0045
    /// How much fuller than its radius a belly is grown: muscles side by side overlap, and share it (`init`).
    static let swell: Float = 1.35
    /// How far apart the shapes' grid samples are (m), and the fascia's.
    static let cell: Float = 0.005
    static let fasciaCell: Float = 0.01
    /// How long one repeat of the fibres' texture is across them (m).
    static let tile: Float = 0.08
    static let samples = 20

    // MARK: The muscles

    /// One side's muscles (`s`: -1 the figure's right, 1 its left), from the top of the list down to what it covers.
    static func muscles(side s: Float) -> [Muscle] {
        func t(_ h: Float, _ angle: Float) -> Mark { Mark(place: .trunk(h), angle: angle) }
        func arm(_ u: Float, _ angle: Float) -> Mark { Mark(place: .on(.upperArm(s), u), angle: angle) }
        func fore(_ u: Float, _ angle: Float) -> Mark { Mark(place: .on(.forearm(s), u), angle: angle) }
        func thigh(_ u: Float, _ angle: Float) -> Mark { Mark(place: .on(.thigh(s), u), angle: angle) }
        func shin(_ u: Float, _ angle: Float) -> Mark { Mark(place: .on(.shin(s), u), angle: angle) }
        func neck(_ u: Float, _ angle: Float) -> Mark { Mark(place: .on(.neck, u), angle: angle) }
        func head(_ u: Float, _ angle: Float) -> Mark { Mark(place: .on(.head, u), angle: angle) }
        func tube(_ name: String, _ marks: [Mark], radius: Float, depth: Float? = nil, layer: Int = 0, peak: Float = 0.5,
                  tendons: SIMD2<Float> = [0.08, 0.15]) -> Muscle {
            Muscle(name: name, side: s, layer: layer, strands: [marks], radius: radius, depth: depth ?? radius * 0.6, peak: peak,
                   tendons: tendons)
        }
        func sheet(_ name: String, _ strands: [[Mark]], half: Float, depth: Float? = nil, layer: Int = 0, peak: Float = 0.5,
                   tendons: SIMD2<Float> = [0.08, 0.15]) -> Muscle {
            Muscle(name: name, side: s, layer: layer, strands: strands, radius: half, depth: depth ?? MuscleAtlas.fat + 0.35 * half, peak: peak,
                   tendons: tendons)
        }
        // The rectus abdominis: four segments up each side of the midline, the tendinous bands between them.
        let rectus = [(-0.24, 0.17), (0.19, 0.33), (0.35, 0.48), (0.5, 0.63)].enumerated().map { k, span in
            sheet("rectus abdominis \(k + 1)", [[t(Float(span.0), 6), t(Float(span.1), 6)], [t(Float(span.0), 13), t(Float(span.1), 24)]],
                  half: 0.009, tendons: [0.06, 0.06])
        }
        return [
            // Neck and shoulders.
            tube("sternocleidomastoid", [t(0.97, 8), neck(0.5, 45), head(0.05, 105)], radius: 0.011, tendons: [0.12, 0.1]),
            tube("deltoid, front", [t(0.95, 48), arm(0.12, 25), arm(0.45, 75)], radius: 0.022, peak: 0.4, tendons: [0.05, 0.18]),
            tube("deltoid, side", [arm(-0.12, 90), arm(0.18, 92), arm(0.46, 85)], radius: 0.024, peak: 0.4, tendons: [0.05, 0.18]),
            tube("deltoid, back", [t(0.86, 140), arm(0.12, 150), arm(0.45, 100)], radius: 0.022, peak: 0.4, tendons: [0.05, 0.18]),
            sheet("trapezius", [[neck(0.75, 172), neck(0.25, 135), arm(-0.1, 110)], [t(0.98, 176), t(0.97, 150), arm(-0.1, 130)],
                                [t(0.78, 176), t(0.86, 155), t(0.88, 140)], [t(0.48, 176), t(0.7, 160), t(0.84, 148)]],
                  half: 0.01, tendons: [0.1, 0.08]),
            // The chest and the belly.
            sheet("pectoralis major", [[t(0.95, 28), t(0.96, 55), arm(0.16, 15)], [t(0.88, 4), t(0.86, 45), arm(0.15, 0)],
                                       [t(0.77, 4), t(0.76, 40), arm(0.14, -15)], [t(0.66, 12), t(0.68, 50), arm(0.13, -30)]],
                  half: 0.016, peak: 0.4, tendons: [0.04, 0.16]),
        ] + rectus + [
            sheet("external oblique", [[t(0.58, 70), t(0.25, 55), t(0.05, 45)], [t(0.5, 95), t(0.2, 85), t(0.06, 72)],
                                       [t(0.42, 115), t(0.2, 108), t(0.12, 100)]],
                  half: 0.011, peak: 0.4, tendons: [0.04, 0.2]),
            sheet("serratus anterior", [[t(0.7, 72), t(0.74, 100), t(0.78, 125)], [t(0.6, 78), t(0.68, 102), t(0.74, 128)],
                                        [t(0.5, 85), t(0.6, 105), t(0.7, 130)]],
                  half: 0.008, layer: 1, tendons: [0.1, 0.1]),
            // The back.
            sheet("latissimus dorsi", [[t(0.55, 176), t(0.7, 125), arm(0.12, -150)], [t(0.25, 176), t(0.5, 120), arm(0.14, -140)],
                                       [t(0.0, 170), t(0.4, 110), arm(0.16, -130)]],
                  half: 0.01, peak: 0.45, tendons: [0.18, 0.12]),
            sheet("infraspinatus and teres", [[t(0.84, 155), t(0.86, 130), arm(0.02, 170)], [t(0.62, 150), t(0.7, 125), arm(0.06, -170)]],
                  half: 0.012, layer: 1, tendons: [0.06, 0.15]),
            tube("erector spinae", [t(-0.15, 162), t(0.35, 158), t(0.8, 162)], radius: 0.022, layer: 1, tendons: [0.15, 0.08]),
            // The arm.
            tube("biceps", [arm(0.08, 10), arm(0.55, 0), fore(0.1, 10)], radius: 0.022, depth: 0.017, peak: 0.6, tendons: [0.15, 0.13]),
            tube("triceps, long head", [arm(0.0, -160), arm(0.5, -170), fore(-0.02, 180)], radius: 0.02, tendons: [0.06, 0.22]),
            tube("triceps, lateral head", [arm(0.12, 150), arm(0.55, 140), fore(0.0, 170)], radius: 0.018, tendons: [0.06, 0.25]),
            tube("brachialis", [arm(0.45, -45), arm(0.8, -25), fore(0.12, -10)], radius: 0.016, layer: 1, tendons: [0.05, 0.15]),
            tube("brachioradialis", [arm(0.7, 75), fore(0.3, 45), fore(0.97, 20)], radius: 0.015, peak: 0.3, tendons: [0.05, 0.4]),
            sheet("forearm flexors", [[fore(0.02, -40), fore(0.5, -70), fore(0.97, -90)], [fore(0.05, -110), fore(0.5, -115), fore(0.97, -120)]],
                  half: 0.012, peak: 0.3, tendons: [0.05, 0.42]),
            sheet("forearm extensors", [[fore(0.02, 120), fore(0.5, 105), fore(0.97, 90)], [fore(0.05, 165), fore(0.5, 150), fore(0.97, 130)]],
                  half: 0.011, peak: 0.3, tendons: [0.05, 0.42]),
            // The hip.
            sheet("gluteus maximus", [[t(0.16, 150), t(0.04, 125), thigh(0.18, 115)], [t(0.04, 172), t(-0.06, 145), thigh(0.24, 125)],
                                      [t(-0.18, 176), t(-0.2, 155), thigh(0.3, 135)]],
                  half: 0.024, peak: 0.45, tendons: [0.05, 0.14]),
            sheet("gluteus medius", [[t(0.16, 110), t(0.08, 100), thigh(0.03, 95)], [t(0.14, 140), t(0.06, 125), thigh(0.03, 115)]],
                  half: 0.014, layer: 1, tendons: [0.05, 0.15]),
            tube("tensor fasciae latae and IT band", [t(0.02, 62), thigh(0.12, 80), thigh(0.5, 92), thigh(0.98, 95)], radius: 0.013,
                 peak: 0.15, tendons: [0.04, 0.72]),
            // The thigh.
            tube("rectus femoris", [t(-0.02, 38), thigh(0.5, 0), shin(0.08, 0)], radius: 0.024, depth: 0.018, tendons: [0.08, 0.16]),
            tube("vastus lateralis", [thigh(0.1, 85), thigh(0.55, 60), thigh(0.97, 25)], radius: 0.028, peak: 0.55, tendons: [0.06, 0.12]),
            tube("vastus medialis", [thigh(0.35, -60), thigh(0.8, -45), thigh(0.98, -15)], radius: 0.024, peak: 0.75, tendons: [0.05, 0.1]),
            tube("sartorius", [t(0.0, 52), thigh(0.35, -35), thigh(0.85, -105), shin(0.1, -75)], radius: 0.01, tendons: [0.04, 0.1]),
            sheet("adductors", [[t(-0.22, 18), thigh(0.3, -80), thigh(0.6, -95)], [t(-0.26, 35), thigh(0.4, -110), thigh(0.85, -115)]],
                  half: 0.018, layer: 1, tendons: [0.05, 0.1]),
            tube("biceps femoris", [thigh(0.06, 160), thigh(0.5, 150), shin(0.06, 115)], radius: 0.022, tendons: [0.06, 0.16]),
            tube("semitendinosus and semimembranosus", [thigh(0.06, -170), thigh(0.5, -155), shin(0.1, -130)], radius: 0.024,
                 tendons: [0.06, 0.18]),
            // The calf and the shin.
            tube("gastrocnemius, inner head", [thigh(0.95, -150), shin(0.25, -160), shin(0.97, 180)], radius: 0.022, peak: 0.28,
                 tendons: [0.05, 0.45]),
            tube("gastrocnemius, outer head", [thigh(0.95, 150), shin(0.25, 155), shin(0.97, 180)], radius: 0.019, peak: 0.28,
                 tendons: [0.05, 0.45]),
            tube("soleus", [shin(0.15, 170), shin(0.55, 180), shin(0.97, 180)], radius: 0.022, layer: 1, peak: 0.45, tendons: [0.05, 0.32]),
            tube("tibialis anterior", [shin(0.08, 30), shin(0.6, 25), shin(1.02, -25)], radius: 0.014, peak: 0.35, tendons: [0.05, 0.35]),
            tube("peroneus", [shin(0.1, 100), shin(0.6, 110), shin(0.98, 145)], radius: 0.012, peak: 0.35, tendons: [0.05, 0.35]),
        ]
    }

    /// Both sides', the right's first.
    static let all: [Muscle] = [Float(-1), 1].flatMap { muscles(side: $0) }

    // MARK: Shapes

    /// A muscle sculpted: its strands' points (strand by strand, `samples` each, under the skin), the segments or
    /// triangles between them, each with a sphere round it (to skip it when it can't be nearest).
    struct Shape {
        let muscle: Muscle
        let points: [[SIMD3<Float>]]
        /// Out of the skin at a tube's points (its section is `wide` times wider along the skin than into it).
        let normals: [SIMD3<Float>]
        let lo: SIMD3<Float>
        let hi: SIMD3<Float>
        /// How wide a sheet is at its belly (m).
        let width: Float
        private let pieces: [(corners: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), uv: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
                              centre: SIMD3<Float>, reach: Float)]

        init(_ muscle: Muscle, points: [[SIMD3<Float>]], normals: [SIMD3<Float>]) {
            self.muscle = muscle
            self.points = points
            self.normals = normals
            let n = points[0].count
            var pieces: [(corners: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), uv: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
                          centre: SIMD3<Float>, reach: Float)] = []
            func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ ua: SIMD2<Float>, _ ub: SIMD2<Float>, _ uc: SIMD2<Float>) {
                let centre = (a + b + c) / 3
                pieces.append(((a, b, c), (ua, ub, uc), centre, max(simd_length(a - centre), simd_length(b - centre), simd_length(c - centre))))
            }
            let strands = points.count
            for i in 0..<(n - 1) {
                let u0 = Float(i) / Float(n - 1), u1 = Float(i + 1) / Float(n - 1)
                if strands == 1 {   // a segment: a triangle with two corners at its end
                    add(points[0][i], points[0][i + 1], points[0][i + 1], [u0, 0.5], [u1, 0.5], [u1, 0.5])
                    continue
                }
                for k in 0..<(strands - 1) {
                    let v0 = Float(k) / Float(strands - 1), v1 = Float(k + 1) / Float(strands - 1)
                    let a = points[k][i], b = points[k + 1][i], c = points[k + 1][i + 1], d = points[k][i + 1]
                    add(a, b, c, [u0, v0], [u0, v1], [u1, v1])
                    add(a, c, d, [u0, v0], [u1, v1], [u1, v0])
                }
            }
            self.pieces = pieces
            let all = points.flatMap { $0 }
            let reach = SIMD3<Float>(repeating: muscle.radius * MuscleAtlas.swell * (strands == 1 ? muscle.wide : 1) + 3 * MuscleAtlas.cell)
            lo = all.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) } - reach
            hi = all.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) } + reach
            let belly = Int((muscle.peak * Float(n - 1)).rounded())
            width = strands > 1 ? (1..<strands).reduce(Float(0)) { $0 + simd_length(points[$1][belly] - points[$1 - 1][belly]) } : 0
        }

        /// The nearest point of its middle to `p`: how far, where along (u) and across (v) it that is, and the point.
        func nearest(_ p: SIMD3<Float>) -> (d: Float, uv: SIMD2<Float>, q: SIMD3<Float>) {
            var best = (d: Float.infinity, uv: SIMD2<Float>(), q: SIMD3<Float>())
            for piece in pieces where simd_length(p - piece.centre) - piece.reach < best.d {
                let (a, b, c) = piece.corners
                let (q, w): (SIMD3<Float>, SIMD2<Float>)
                if b == c {
                    let ab = b - a, t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-12), 0), 1)
                    (q, w) = (a + ab * t, [t, 0])
                } else {
                    (q, w) = SkinShell.closest(p, a, b, c)
                }
                let d = simd_length(p - q)
                if d < best.d { best = (d, piece.uv.0 * (1 - w.x - w.y) + piece.uv.1 * w.x + piece.uv.2 * w.y, q) }
            }
            return best
        }

        /// How far out from its middle its surface is at (u, v): its tendons' radius, swelling to its belly's.
        func thickness(_ uv: SIMD2<Float>) -> Float {
            var swell = MuscleAtlas.belly(uv.x, muscle)
            if points.count > 1 { swell *= pow(max(1 - (2 * uv.y - 1) * (2 * uv.y - 1), 0), 0.25) }   // a sheet's edges
            return MuscleAtlas.tendonRadius + (muscle.radius * MuscleAtlas.swell - MuscleAtlas.tendonRadius) * swell
        }

        /// Its distance (not exact: its middle's, less its thickness there; a tube's measured with its width along
        /// the skin squeezed by `wide`).
        func distance(_ p: SIMD3<Float>) -> Float {
            if p.x < lo.x || p.y < lo.y || p.z < lo.z || p.x > hi.x || p.y > hi.y || p.z > hi.z {
                return simd_length(simd_max(simd_max(lo - p, p - hi), .zero)) + MuscleAtlas.cell
            }
            let n = nearest(p)
            guard points.count == 1 else { return n.d - thickness(n.uv) }
            let r = p - n.q, out = normal(n.uv.x)
            let into = simd_dot(r, out), along = simd_length(r - out * into) / muscle.wide
            return (into * into + along * along).squareRoot() - thickness(n.uv)
        }

        /// A tube's outward normal at `u` along it.
        func normal(_ u: Float) -> SIMD3<Float> {
            let f = u * Float(normals.count - 1), k = min(Int(f), normals.count - 2)
            let n = normals[k] + (normals[k + 1] - normals[k]) * (f - Float(k))
            return simd_length_squared(n) > 1e-8 ? simd_normalize(n) : SIMD3(0, 1, 0)
        }
    }

    /// How full muscle `m`'s belly is at `u` along it: 0 in its tendons, 1 at its peak.
    static func belly(_ u: Float, _ m: Muscle) -> Float {
        let x = min(max((u - m.tendons.x) / (1 - m.tendons.x - m.tendons.y), 0), 1)
        let warped = pow(x, log(0.5) / log(min(max(m.peak, 0.05), 0.95)))
        return pow(sin(.pi * warped), 0.6)
    }

    /// Where along it the texture is at `u`: its tendons in [0, 0.12] and [0.88, 1], its belly between.
    static func textureU(_ u: Float, _ m: Muscle) -> Float {
        if u < m.tendons.x { return 0.12 * u / max(m.tendons.x, 1e-4) }
        if u > 1 - m.tendons.y { return 0.88 + 0.12 * (u - (1 - m.tendons.y)) / max(m.tendons.y, 1e-4) }
        return 0.12 + 0.76 * (u - m.tendons.x) / max(1 - m.tendons.x - m.tendons.y, 1e-4)
    }

    // MARK: Built

    let shapes: [Shape]
    /// The skin it is sculpted to.
    let body: BodySurface
    let marks: BodyMarks
    let skeleton: SkeletonAtlas
    /// The drawn mesh: the muscles', then the fascia's, then the bones'; per vertex its texture's place and the rig's
    /// bone it moves with (a muscle's or the fascia's the one it is deepest in, a bone's the one it rides); per triangle
    /// its material (0 muscle, 1 fascia, 2 bone).
    let mesh: MeshGeometry
    let uvs: [SIMD2<Float>]
    let bones: [Int]
    let materials: [UInt8]
    /// Each muscle's vertices, and each of its skeleton's pieces'.
    let ranges: [Range<Int>]
    let pieces: [Range<Int>]

    /// `rig`'s bones' shapes (all but the rigid ones: head, hands, feet) 8 mm within them, as BodySurface's `solids`:
    /// inside too, whatever the mesh says (the Y Bot's elbows are hollow).
    static func boneSolids(_ rig: CharacterRig) -> [(bounds: AABB, distance: (SIMD3<Float>) -> Float)] {
        rig.bones.indices.filter { !rig.bones[$0].rigid }.map { b -> (bounds: AABB, distance: (SIMD3<Float>) -> Float) in
            let shape = rig.bones[b].shape, unplace = rig.restPlacement(b).inverse, placed = rig.restPlacement(b)
            let box = shape.bounds()
            let corners = (0..<8).map { k in
                PhysicsMath.xyz(placed * SIMD4(k & 1 == 0 ? box.lo.x : box.hi.x, k & 2 == 0 ? box.lo.y : box.hi.y, k & 4 == 0 ? box.lo.z : box.hi.z, 1))
            }
            let bounds = AABB(lo: corners.reduce(SIMD3(repeating: .infinity)) { simd_min($0, $1) },
                              hi: corners.reduce(SIMD3(repeating: -.infinity)) { simd_max($0, $1) })
            return (bounds, { p in shape.distance(PhysicsMath.xyz(unplace * SIMD4(p, 1))).d + 0.008 })
        }
    }

    /// The atlas on `rig`'s character, sculpted on its whole mesh (its coarser levels, simplified when the character cache
    /// is built, aren't symmetric: a rebuilt cache moved a muscle a centimetre off its mirror).
    init(_ rig: CharacterRig, muscles: [Muscle] = MuscleAtlas.all) {
        let level = rig.character.level(0)
        let body = BodySurface((level.positions, level.normals, level.indices), solids: MuscleAtlas.boneSolids(rig))
        self.body = body
        let marks = BodyMarks(rig, body: body)
        self.marks = marks
        // Each muscle's strands: a Catmull-Rom curve through its marks, `samples` evenly along it, each moved to its
        // depth under the skin.
        func strand(_ along: [Mark], _ m: Muscle) -> [SIMD3<Float>] {
            let p = along.map { marks.resolve($0, side: m.side, depth: m.depth) }
            return BodyMarks.curve(p, samples: MuscleAtlas.samples).map { body.inset($0, depth: m.depth) }
        }
        let skeleton = SkeletonAtlas(rig, marks: marks)
        self.skeleton = skeleton
        let shapes = muscles.map { m -> Shape in
            let points = m.strands.map { strand($0, m) }
            let normals = points[0].map { p -> SIMD3<Float> in
                let g = body.gradient(p)
                return simd_length_squared(g) > 1e-8 ? simd_normalize(g) : SIMD3(0, 1, 0)
            }
            return Shape(m, points: points, normals: normals)
        }
        self.shapes = shapes

        // Each muscle's surface: its shape, under the skin, carved from those of the layers above it, and sharing with
        // its own layer's what they both fill (cut where they are equally deep in each, less a gap).
        var pieces = [(positions: [SIMD3<Float>], indices: [UInt32])](repeating: ([], []), count: muscles.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: muscles.count) { i in
            let shape = shapes[i]
            let near = muscles.indices.filter { j in
                let o = shapes[j]
                return j != i && muscles[j].layer <= muscles[i].layer && simd_reduce_max(simd_max(o.lo - shape.hi, shape.lo - o.hi)) < 0
            }
            let above = near.filter { muscles[$0].layer < muscles[i].layer }, beside = near.filter { muscles[$0].layer == muscles[i].layer }
            func distance(_ p: SIMD3<Float>) -> Float {
                let own = shape.distance(p)
                if own > 2 * MuscleAtlas.cell { return own }
                var d = max(own, body.distance(p) + MuscleAtlas.fat)
                d = max(d, MuscleAtlas.gap - skeleton.distance(p))
                for j in above { d = max(d, MuscleAtlas.gap - shapes[j].distance(p)) }
                for j in beside { d = max(d, (own - shapes[j].distance(p) + MuscleAtlas.gap) / 2) }
                return d
            }
            let size = MuscleAtlas.cell, h = size * 0.1
            let counts = SIMD3<Int>(((shape.hi - shape.lo) / size).rounded(.up)) &+ 1
            let mesh = SurfaceNets.mesh(lo: shape.lo, size: size, counts: counts, distance: distance) { MuscleAtlas.gradient(distance, $0, h: h) }
            // Without what the fascia hides (its triangles all deeper than it), and its specks.
            let hidden = -(MuscleAtlas.fascia + 0.002)
            var shown: [UInt32] = []
            for t in stride(from: 0, to: mesh.indices.count, by: 3) {
                let corners = mesh.indices[t..<(t + 3)]
                if corners.allSatisfy({ body.distance(mesh.positions[Int($0)]) < hidden }) { continue }
                shown += corners
            }
            let kept = MuscleAtlas.largestParts((mesh.positions, shown))
            lock.lock()
            pieces[i] = kept
            lock.unlock()
        }
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = [], uvs: [SIMD2<Float>] = [], materials: [UInt8] = []
        var ranges: [Range<Int>] = []
        for (i, piece) in pieces.enumerated() {
            let base = UInt32(positions.count), shape = shapes[i], m = muscles[i]
            ranges.append(positions.count..<(positions.count + piece.positions.count))
            positions += piece.positions
            indices += piece.indices.map { $0 + base }
            materials += [UInt8](repeating: 0, count: piece.indices.count / 3)
            for p in piece.positions {
                let n = shape.nearest(p)
                let across: Float
                if shape.points.count > 1 {
                    across = n.uv.y * shape.width
                } else {
                    // Round a tube from its outer side: the seam where it meets the bone.
                    let k = min(Int(n.uv.x * Float(MuscleAtlas.samples - 1)), MuscleAtlas.samples - 2)
                    let along = simd_normalize(shape.points[0][k + 1] - shape.points[0][k])
                    var out = body.gradient(n.q)
                    out -= along * simd_dot(out, along)
                    let x = simd_length_squared(out) > 1e-8 ? simd_normalize(out) : simd_normalize(simd_cross(along, [0, 0, 1]))
                    let y = simd_cross(along, x), r = p - n.q
                    across = atan2(simd_dot(r, y), simd_dot(r, x)) * m.radius * m.wide
                }
                uvs.append([MuscleAtlas.textureU(n.uv.x, m), across / MuscleAtlas.tile])
            }
        }
        // The fascia under them: the skin, deeper, carved from the bones; closed off short of the head, the hands and
        // the feet (deeper the further past the neck, a wrist or an ankle), where the bones are bare.
        let caps = rig.bones.filter(\.rigid).map { b -> (point: SIMD3<Float>, axis: SIMD3<Float>) in
            let axis: SIMD3<Float>
            switch b.role {
            case .foot: axis = simd_normalize(b.from - rig.bones[b.parent].from)   // down the shin
            case .head: axis = [0, 1, 0]
            default: axis = simd_normalize(b.to - b.from)
            }
            return (b.from - axis * 0.008, axis)
        }
        func shell(_ p: SIMD3<Float>) -> Float {
            body.distance(p) + MuscleAtlas.fascia + 1.5 * caps.reduce(Float(0)) { max($0, simd_dot(p - $1.point, $1.axis)) }
        }
        func fascia(_ p: SIMD3<Float>) -> Float { max(shell(p), MuscleAtlas.gap - skeleton.distance(p)) }
        let box = body.bounds
        let size = MuscleAtlas.fasciaCell
        let sheet = SurfaceNets.mesh(lo: box.lo, size: size, counts: SIMD3<Int>(((box.hi - box.lo) / size).rounded(.up)) &+ 1, distance: fascia,
                                     gradient: { MuscleAtlas.gradient(fascia, $0, h: size / 2) })
        let base = UInt32(positions.count)
        positions += sheet.positions
        indices += sheet.indices.map { $0 + base }
        uvs += [SIMD2<Float>](repeating: [0.5, 0], count: sheet.positions.count)
        materials += [UInt8](repeating: 1, count: sheet.indices.count / 3)
        // Each vertex's bone: the one it is deepest in.
        var bones = positions.map { p in
            rig.bones.indices.min { a, b in MuscleAtlas.depth(rig, a, p) < MuscleAtlas.depth(rig, b, p) }!
        }
        // The bones: what the fascia doesn't hide of each (its triangles not all 2 mm or more within it), on the bone it
        // rides.
        var boneRanges: [Range<Int>] = []
        for (piece, mesh) in zip(skeleton.pieces, skeleton.meshes) {
            var remap = [Int32](repeating: -1, count: mesh.positions.count)
            let first = positions.count
            for t in stride(from: 0, to: mesh.indices.count, by: 3) {
                let corners = (0..<3).map { Int(mesh.indices[t + $0]) }
                if corners.allSatisfy({ shell(mesh.positions[$0]) < -0.002 }) { continue }
                for v in corners {
                    if remap[v] < 0 {
                        remap[v] = Int32(positions.count)
                        positions.append(mesh.positions[v])
                        uvs.append(.zero)
                        bones.append(piece.rides)
                    }
                    indices.append(UInt32(remap[v]))
                }
                materials.append(2)
            }
            boneRanges.append(first..<positions.count)
        }
        self.pieces = boneRanges
        self.ranges = ranges
        self.uvs = uvs
        self.bones = bones
        self.materials = materials
        mesh = (positions, MuscleAtlas.normals(positions, indices), indices)
    }

    /// `distance`'s gradient at `p` (central differences `h` apart), no shorter than half a distance's (1): where it is
    /// flat (past the skin's band, between two shapes' sides) a Newton step by a short one would fling a vertex off.
    static func gradient(_ distance: (SIMD3<Float>) -> Float, _ p: SIMD3<Float>, h: Float) -> SIMD3<Float> {
        let g = SIMD3(distance(p + [h, 0, 0]) - distance(p - [h, 0, 0]), distance(p + [0, h, 0]) - distance(p - [0, h, 0]),
                      distance(p + [0, 0, h]) - distance(p - [0, 0, h])) / (2 * h)
        let length = simd_length(g)
        return length < 0.5 ? (length > 1e-6 ? g / length * 0.5 : .zero) : g
    }

    /// How deep `p` is in rig bone `b`'s shape (0 on its axis, 1 on its surface).
    static func depth(_ rig: CharacterRig, _ b: Int, _ p: SIMD3<Float>) -> Float {
        let local = rig.restPlacement(b).inverse * SIMD4(p, 1)
        return 1 + rig.bones[b].shape.distance(PhysicsMath.xyz(local)).d / rig.bones[b].thickness
    }

    /// `mesh` without its specks: the parts (by shared vertices) with less than a fifth of the largest's vertices.
    static func largestParts(_ mesh: (positions: [SIMD3<Float>], indices: [UInt32])) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var parent = Array(mesh.positions.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = find(Int(mesh.indices[t]))
            for k in 1..<3 { let b = find(Int(mesh.indices[t + k])); if a != b { parent[b] = a } }
        }
        var sizes: [Int: Int] = [:]
        for v in mesh.positions.indices { sizes[find(v), default: 0] += 1 }
        let largest = sizes.values.max() ?? 0
        var remap = [Int32](repeating: -1, count: mesh.positions.count)
        var positions: [SIMD3<Float>] = []
        for v in mesh.positions.indices where sizes[find(v)]! * 5 >= largest {
            remap[v] = Int32(positions.count)
            positions.append(mesh.positions[v])
        }
        var indices: [UInt32] = []
        for t in stride(from: 0, to: mesh.indices.count, by: 3) where remap[Int(mesh.indices[t])] >= 0 {
            indices += (0..<3).map { UInt32(remap[Int(mesh.indices[t + $0])]) }
        }
        return (positions, indices)
    }

    /// Area-weighted vertex normals of a mesh.
    static func normals(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        return normals.map { simd_length_squared($0) > 1e-20 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    // MARK: The look

    /// The muscles' textures: along x a tendon's white into the belly's red and back (`textureU`), across y the
    /// fibres' stripes, wandering a little; and their relief as a normal map.
    static func textures() -> (base: FoliageTextures.Image, normal: FoliageTextures.Image) {
        let size = 512, stripes: Float = 16
        func height(_ x: Float, _ y: Float) -> Float {
            let wander = 0.35 * FoliageTextures.noise(x * 6, y * 4, 6, 4, 11)
            let fibre = 0.5 + 0.5 * cos(2 * .pi * (y * stripes + wander))
            return fibre + 0.25 * FoliageTextures.noise(x * 48, y * 64, 48, 64, 5)
        }
        func tendon(_ x: Float) -> Float {
            func ramp(_ a: Float, _ b: Float, _ t: Float) -> Float { let k = min(max((t - a) / (b - a), 0), 1); return k * k * (3 - 2 * k) }
            return 1 - ramp(0.09, 0.15, x) * (1 - ramp(0.85, 0.91, x))
        }
        let base = FoliageTextures.image(size, size) { x, y in
            let h = height(x, y), w = tendon(x)
            let red = SIMD3<Float>(0.62, 0.11, 0.085) * (0.86 + 0.24 * h)
            let white = SIMD3<Float>(0.78, 0.74, 0.68) * (0.95 + 0.06 * h)
            return red + (white - red) * w
        }
        var normal = [UInt8](repeating: 255, count: size * size * 4)
        for py in 0..<size {
            for px in 0..<size {
                let x = (Float(px) + 0.5) / Float(size), y = (Float(py) + 0.5) / Float(size), e = 1 / Float(size)
                let strength = 0.012 * (1 - 0.7 * tendon(x))
                let dx = (height(x + e, y) - height(x - e, y)) / (2 * e), dy = (height(x, y + e) - height(x, y - e)) / (2 * e)
                let n = simd_normalize(SIMD3(-dx * strength, -dy * strength, 1)), i = (py * size + px) * 4
                normal[i] = UInt8(n.x * 127.5 + 127.5)
                normal[i + 1] = UInt8(n.y * 127.5 + 127.5)
                normal[i + 2] = UInt8(n.z * 127.5 + 127.5)
            }
        }
        return (base, FoliageTextures.Image(width: size, height: size, pixels: normal))
    }
}
