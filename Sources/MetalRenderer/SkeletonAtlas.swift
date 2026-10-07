import Foundation
import simd

/// The écorché's skeleton (MuscleAtlas): a character's bones as shapes of their own, built from its joints and fitted
/// under its skin (BodySurface) in its rest pose, each piece drawn on the rig bone it rides (rigidly, with that bone's
/// body: PhysicsWorld.addFleshSurface). The skull, the jaw and the teeth; the spine's vertebrae, the ribs and the
/// sternum; each side's clavicle and scapula, humerus, ulna and radius, the hand's bones from the carpals to the finger
/// tips (on the character's finger joints), the hip bone, the femur, the patella, the tibia and the fibula, and the
/// foot's bones. Each is made of a few simple solids (round cones, ellipsoids, thick triangles) joined smoothly; where a
/// bone lies under the skin in life (the skull, a clavicle, the sternum, the spine's processes, the iliac crest, a
/// kneecap, the shin, the ankles, an elbow's point) it is placed `MuscleAtlas.fat` under it, and the muscles, carved
/// from it (`distance`), leave it bare.
struct SkeletonAtlas {
    /// A shape: its distance at a point (negative inside; near the true one near its surface) and the box it is in.
    struct Solid {
        var lo: SIMD3<Float>
        var hi: SIMD3<Float>
        var distance: (SIMD3<Float>) -> Float

        /// How far `p` is outside its box (0 within it): never more than its distance.
        func outside(_ p: SIMD3<Float>) -> Float { simd_length(simd_max(simd_max(lo - p, p - hi), .zero)) }
    }

    struct Piece {
        var name: String
        /// -1 the figure's right, 1 its left, 0 the middle.
        var side: Float
        /// The rig bone it rides.
        var rides: Int
        var solid: Solid
        /// How far apart its grid's samples are (m).
        var cell: Float
    }

    /// How deep under the skin every bone is at least.
    static let within: Float = 0.003
    /// How far apart the samples of the grid of their distance are (m).
    static let gridCell: Float = 0.006

    // MARK: Solids

    /// A round cone: the segment from `a` to `b`, `ra` thick at `a` and `rb` at `b` (Inigo Quilez's).
    static func cone(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ra: Float, _ rb: Float) -> Solid {
        let r = max(ra, rb)
        return Solid(lo: simd_min(a, b) - r, hi: simd_max(a, b) + r) { p in
            let ba = b - a, l2 = simd_dot(ba, ba), rr = ra - rb
            guard l2 > rr * rr + 1e-12 else { return min(simd_length(p - a) - ra, simd_length(p - b) - rb) }
            let a2 = l2 - rr * rr, il2 = 1 / l2
            let pa = p - a, y = simd_dot(pa, ba), z = y - l2
            let x = pa * l2 - ba * y, x2 = simd_dot(x, x), y2 = y * y * l2, z2 = z * z * l2
            @inline(__always) func sign(_ v: Float) -> Float { v > 0 ? 1 : v < 0 ? -1 : 0 }
            let k = sign(rr) * rr * rr * x2
            if sign(z) * a2 * z2 > k { return (x2 + z2).squareRoot() * il2 - rb }
            if sign(y) * a2 * y2 < k { return (x2 + y2).squareRoot() * il2 - ra }
            return ((x2 * a2 * il2).squareRoot() + y * rr) * il2 - ra
        }
    }

    static func ball(_ c: SIMD3<Float>, _ r: Float) -> Solid {
        Solid(lo: c - r, hi: c + r) { simd_length($0 - c) - r }
    }

    /// An ellipsoid of radii `r` along `frame`'s columns (orthonormal).
    static func ellipsoid(_ c: SIMD3<Float>, _ r: SIMD3<Float>, frame: simd_float3x3 = matrix_identity_float3x3) -> Solid {
        let into = frame.transpose
        return Solid(lo: c - r.max(), hi: c + r.max()) { p in
            let q = into * (p - c)
            let k0 = simd_length(q / r), k1 = simd_length(q / (r * r))
            return k1 > 1e-9 ? k0 * (k0 - 1) / k1 : -r.min()
        }
    }

    /// A triangle `thickness` thick each way.
    static func plate(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ thickness: Float) -> Solid {
        Solid(lo: simd_min(simd_min(a, b), c) - thickness, hi: simd_max(simd_max(a, b), c) + thickness) { p in
            simd_length(p - SkinShell.closest(p, a, b, c).0) - thickness
        }
    }

    /// Round cones through `points`, each as thick as its `radii`.
    static func chain(_ points: [SIMD3<Float>], _ radii: [Float]) -> Solid {
        union((0..<(points.count - 1)).map { cone(points[$0], points[$0 + 1], radii[$0], radii[$0 + 1]) }, smooth: 0)
    }

    /// `parts` joined, blended where they meet over `k` (0: not).
    static func union(_ parts: [Solid], smooth k: Float) -> Solid {
        let lo = parts.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1.lo) }
        let hi = parts.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1.hi) }
        return Solid(lo: lo, hi: hi) { p in
            var d = Float.infinity
            for part in parts where part.outside(p) < d + k {
                let e = part.distance(p)
                if k > 0 {
                    let h = max(k - abs(d - e), 0) / k
                    d = min(d, e) - h * h * k / 4
                } else {
                    d = min(d, e)
                }
            }
            return d
        }
    }

    /// `a` less `b`, the edge rounded over `k`.
    static func subtract(_ a: Solid, _ b: Solid, smooth k: Float) -> Solid {
        Solid(lo: a.lo, hi: a.hi) { p in
            let d = a.distance(p)
            guard b.outside(p) < k - d else { return d }
            let e = -b.distance(p), h = max(k - abs(d - e), 0) / k
            return max(d, e) + h * h * k / 4
        }
    }

    // MARK: Built

    let pieces: [Piece]
    /// Each piece's surface, whole.
    let meshes: [(positions: [SIMD3<Float>], indices: [UInt32])]
    /// Their distance (the nearest piece's) on a grid over the body: what the muscles are carved from.
    private let lo: SIMD3<Float>
    private let counts: SIMD3<Int>
    private let values: [Float]

    init(_ rig: CharacterRig, marks: BodyMarks) {
        let pieces = SkeletonAtlas.pieces(rig, marks: marks)
        self.pieces = pieces
        // Each piece's surface.
        var meshes = [(positions: [SIMD3<Float>], indices: [UInt32])](repeating: ([], []), count: pieces.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
            let piece = pieces[i], size = piece.cell, h = size * 0.1
            let lo = piece.solid.lo - 2 * size
            let counts = SIMD3<Int>(((piece.solid.hi + 2 * size - lo) / size).rounded(.up)) &+ 1
            let f = piece.solid.distance
            let mesh = SurfaceNets.mesh(lo: lo, size: size, counts: counts, distance: f) { MuscleAtlas.gradient(f, $0, h: h) }
            lock.lock()
            meshes[i] = mesh
            lock.unlock()
        }
        self.meshes = meshes

        // Their distance on a grid over the body: each piece's within a centimetre of its box.
        let cell = SkeletonAtlas.gridCell, box = marks.body.bounds
        let n = SIMD3<Int>(((box.hi - box.lo) / cell).rounded(.up)) &+ 1
        var values = [Float](repeating: 0.05, count: n.x * n.y * n.z)
        for piece in pieces {
            let first = simd_max(SIMD3<Int>(((piece.solid.lo - 0.01 - box.lo) / cell).rounded(.down)), .zero)
            let last = simd_min(SIMD3<Int>(((piece.solid.hi + 0.01 - box.lo) / cell).rounded(.up)), n &- 1)
            guard first.x <= last.x, first.y <= last.y, first.z <= last.z else { continue }
            values.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: last.z - first.z + 1) { dz in
                    let z = first.z + dz
                    for y in first.y...last.y {
                        for x in first.x...last.x {
                            let i = (z * n.y + y) * n.x + x
                            out[i] = min(out[i], piece.solid.distance(box.lo + SIMD3(Float(x), Float(y), Float(z)) * cell))
                        }
                    }
                }
            }
        }
        lo = box.lo
        counts = n
        self.values = values
    }


    /// The character's bones.
    static func pieces(_ rig: CharacterRig, marks: BodyMarks) -> [Piece] {
        let body = marks.body
        let names = rig.character.jointNames.map { $0.replacingOccurrences(of: "mixamorig:", with: "") }
        func joint(_ name: String) -> SIMD3<Float> { rig.bind[names.firstIndex(of: name)!].t }
        func index(_ role: FleshFigure.Role) -> Int { rig.bones.firstIndex { $0.role == role }! }
        let level = rig.character.level(0)
        let ground = level.positions.map(\.y).min() ?? 0
        let k = (joint("HeadTop_End").y - ground) / 1.786   // sized to the Y Bot's 1.79 m
        let fat = MuscleAtlas.fat
        let up = SIMD3<Float>(0, 1, 0), front = SIMD3<Float>(0, 0, 1), x = SIMD3<Float>(1, 0, 0)
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        func point(_ place: MuscleAtlas.Place, _ angle: Float, side s: Float, depth: Float, reach: Float = .infinity) -> SIMD3<Float> {
            let ray = marks.ray(MuscleAtlas.Mark(place: place, angle: angle), side: s)
            let p = marks.out(ray.origin, ray.direction, depth: depth)
            return simd_length(p - ray.origin) > reach ? ray.origin + ray.direction * reach : p
        }
        // The trunk's place (MuscleAtlas.Place.trunk) at height `y`, and the rig bone (pelvis, spine, chest) there.
        func trunk(_ y: Float) -> (h: Float, bone: Int) {
            let t = marks.trunk, lengths = marks.lengths
            let s = min((0..<(t.count - 1)).first { y <= t[$0 + 1].y } ?? t.count - 2, t.count - 2)
            let f = (y - t[s].y) / (t[s + 1].y - t[s].y)
            return ((lengths[s] + f * (lengths[s + 1] - lengths[s])) / lengths.last!, max(min(s, 3), 0))
        }
        let hips = marks.trunk.first!.y, chestTop = marks.trunk.last!.y, height = chestTop - hips
        var pieces: [Piece] = []
        func add(_ name: String, _ side: Float, _ rides: Int, _ solid: Solid, cell: Float) {
            // Never out of the skin.
            let clipped = Solid(lo: solid.lo, hi: solid.hi) { p in max(solid.distance(p), body.distance(p) + SkeletonAtlas.within) }
            pieces.append(Piece(name: name, side: side, rides: rides, solid: clipped, cell: cell))
        }

        // The head: the skull, its inside the skin's 6 mm in, cut off above the teeth, its orbits and nose hollowed and
        // its cheekbones and brow raised; the jaw a U of thin plates, its rami up to the skull; the teeth two rows.
        let head = index(.head)
        let headVertices = zip(level.positions, level.skin).filter { rig.boneOf[Int($0.1.joints & 0xFF)] == head }.map(\.0)
        let headLow = headVertices.map(\.y).min() ?? 0, headHigh = headVertices.map(\.y).max() ?? 0
        let eyes = headLow + 0.48 * (headHigh - headLow)
        let cut = eyes - 0.066 * k
        func face(_ y: Float) -> Float { marks.out(SIMD3(0, y, 0), front, depth: 0).z }
        let cranium = Solid(lo: body.bounds.lo, hi: body.bounds.hi) { p in
            let d = body.distance(p) + 0.006 * k, e = cut - p.y, h = max(0.004 - abs(d - e), 0) / 0.004
            return max(d, e) + h * h * 0.001
        }
        let headBox = Solid(lo: SIMD3(-0.1 * k, cut - 0.01, face(eyes) - 0.25 * k), hi: SIMD3(0.1 * k, headHigh + 0.01, face(eyes) + 0.01)) { _ in 0 }
        var skull = Solid(lo: headBox.lo, hi: headBox.hi, distance: cranium.distance)
        skull = union([skull] + [Float(-1), 1].flatMap { s in [
            ellipsoid(SIMD3(s * 0.048 * k, eyes - 0.022 * k, face(eyes - 0.022 * k) - 0.02 * k), SIMD3(0.016, 0.009, 0.02) * k),   // cheekbone
        ] } + [ellipsoid(SIMD3(0, eyes + 0.02 * k, face(eyes + 0.02 * k) - 0.006 * k), SIMD3(0.045, 0.007, 0.01) * k)],   // brow
                      smooth: 0.006 * k)
        // (The temples hollowed behind the orbits, the cheekbones' arches back over them to the ears.)
        skull = subtract(skull, union([Float(-1), 1].map { s in
            ellipsoid(SIMD3(s * 0.098 * k, eyes - 0.004 * k, face(eyes) - 0.065 * k), SIMD3(0.03, 0.032, 0.04) * k)
        }, smooth: 0), smooth: 0.012 * k)
        skull = union([skull] + [Float(-1), 1].map { s in
            cone(SIMD3(s * 0.05 * k, eyes - 0.024 * k, face(eyes - 0.024 * k) - 0.028 * k), SIMD3(s * 0.064 * k, eyes - 0.03 * k, face(eyes) - 0.095 * k),
                 0.005 * k, 0.004 * k)
        }, smooth: 0.004 * k)
        skull = subtract(skull, union([Float(-1), 1].map { s in
            ellipsoid(SIMD3(s * 0.031 * k, eyes, face(eyes) - 0.012 * k), SIMD3(0.021, 0.018, 0.03) * k)
        } + [ellipsoid(SIMD3(0, eyes - 0.036 * k, face(eyes - 0.036 * k) - 0.006 * k), SIMD3(0.011, 0.017, 0.03) * k)], smooth: 0), smooth: 0.004 * k)
        add("skull", 0, head, skull, cell: 0.0045)
        // An arc round the jaw at height y: from its front (0) to its side (1), `inset` behind the face.
        func arc(_ t: Float, side s: Float, y: Float, wide: Float, deep: Float, inset: Float) -> SIMD3<Float> {
            let phi = t * .pi / 2
            return SIMD3(s * wide * sin(phi), y, face(y) - inset - deep * (1 - cos(phi)))
        }
        let ts: [Float] = [1, 0.75, 0.5, 0.25, 0, 0.25, 0.5, 0.75, 1], sides: [Float] = [-1, -1, -1, -1, 1, 1, 1, 1, 1]
        let top = zip(ts, sides).map { arc($0, side: $1, y: cut - 0.016 * k, wide: 0.036 * k, deep: 0.05 * k, inset: 0.007 * k) }
        let bottom = zip(ts, sides).map { arc($0, side: $1, y: cut - 0.036 * k, wide: 0.04 * k, deep: 0.06 * k, inset: 0.006 * k) }
        var jaw: [Solid] = []
        for i in 0..<(ts.count - 1) {
            jaw += [plate(top[i], bottom[i], bottom[i + 1], 0.0045 * k), plate(top[i], bottom[i + 1], top[i + 1], 0.0045 * k)]
        }
        for (end, s) in [(0, Float(-1)), (ts.count - 1, 1)] {
            let condyle = SIMD3(s * 0.05 * k, cut + 0.016 * k, top[end].z - 0.035 * k)
            let coronoid = SIMD3(s * 0.044 * k, cut + 0.01 * k, top[end].z - 0.004 * k)
            jaw += [plate(top[end], bottom[end], condyle, 0.004 * k), plate(top[end], condyle, coronoid, 0.004 * k), ball(condyle, 0.006 * k)]
        }
        add("mandible", 0, head, union(jaw, smooth: 0.004 * k), cell: 0.0035)
        var teeth: [Solid] = []
        for s: Float in [-1, 1] {
            for i in 0..<7 {
                let t = (Float(i) + 0.5) / 7, r = (0.0028 + 0.0014 * t) * k
                let upper = arc(t, side: s, y: cut, wide: 0.026 * k, deep: 0.04 * k, inset: 0.011 * k)
                let lower = arc(t, side: s, y: cut, wide: 0.025 * k, deep: 0.04 * k, inset: 0.012 * k)
                teeth.append(cone(upper + up * 0.004 * k, upper - up * (0.0055 * k - r), r * 0.8, r))
                teeth.append(cone(lower - up * 0.018 * k, lower - up * (0.0065 * k + r), r * 0.8, r))
            }
        }
        add("teeth", 0, head, union(teeth, smooth: 0), cell: 0.002)

        // The spine: a vertebra's body ahead of its spinous process, whose tip is under the skin of the back's midline;
        // its transverse processes out to each side (the ribs' heads).
        func vertebra(_ name: String, _ place: MuscleAtlas.Place, rides: Int, size: Float, height: Float, droop: Float, tip: Float,
                      reach: Float, span: Float) -> (left: SIMD3<Float>, right: SIMD3<Float>) {
            let ray = marks.ray(MuscleAtlas.Mark(place: place, angle: 180), side: 1)
            let end = marks.out(ray.origin - ray.axis * droop, ray.direction, depth: tip + 0.0045 * k)
            let back = ray.direction, axis = ray.axis
            let centre = end - back * reach
            let frame = simd_float3x3(columns: (x, axis, simd_cross(x, axis)))
            let arch = centre + back * (size * 0.75 + 0.009 * k), base = arch - back * 0.003 * k
            let left = base + x * span, right = base - x * span
            add(name, 0, rides, union([
                ellipsoid(centre, SIMD3(size, height, size * 0.75), frame: frame),
                cone(centre + back * size * 0.5, arch, 0.006 * k, 0.006 * k),
                cone(arch, end, 0.0055 * k, 0.0045 * k),
                cone(base, left, 0.0045 * k, 0.0035 * k), cone(base, right, 0.0045 * k, 0.0035 * k),
            ], smooth: 0.004 * k), cell: 0.003)
            return (left, right)
        }
        for i in 1...7 {   // C1 at the top
            let u = Float(7 - i) * 0.14
            _ = vertebra("C\(i)", .on(.neck, u), rides: index(.neck), size: 0.011 * k, height: 0.0045 * k, droop: 0.004 * k, tip: fat + 0.01 * k,
                         reach: 0.035 * k, span: 0.022 * k)
        }
        var processes: [(left: SIMD3<Float>, right: SIMD3<Float>, y: Float, bone: Int)] = []
        for i in 1...12 {
            let y = chestTop - height * (0.036 + Float(i - 1) * 0.05), at = trunk(y)
            let p = vertebra("T\(i)", .trunk(at.h), rides: at.bone, size: 0.0155 * k, height: 0.009 * k, droop: 0.014 * k, tip: fat,
                             reach: 0.06 * k, span: 0.03 * k)
            processes.append((p.left, p.right, y, at.bone))
        }
        for i in 1...5 {
            let y = chestTop - height * (0.656 + Float(i - 1) * 0.074), at = trunk(y)
            _ = vertebra("L\(i)", .trunk(at.h), rides: at.bone, size: 0.021 * k, height: 0.012 * k, droop: 0.004 * k, tip: fat,
                         reach: 0.068 * k, span: 0.036 * k)
        }
        // The sacrum: a wedge down the back between the hip bones, and the coccyx under it.
        let pelvis = index(.pelvis)
        func behind(_ xy: SIMD2<Float>, depth: Float) -> SIMD3<Float> { marks.out(SIMD3(xy.x, xy.y, -0.03 * k), -front, depth: depth) }
        let hip = rig.bones[index(.thigh(1))].from
        let sacrumTop = hips + 0.002 * k, sacrumTip = hip.y - 0.035 * k
        let sacrum = [behind([-0.045 * k, sacrumTop], depth: 0.016 * k), behind([0.045 * k, sacrumTop], depth: 0.016 * k),
                      behind([-0.032 * k, (sacrumTop + sacrumTip) / 2], depth: 0.016 * k), behind([0.032 * k, (sacrumTop + sacrumTip) / 2], depth: 0.016 * k),
                      behind([0, sacrumTip], depth: 0.02 * k)]
        add("sacrum and coccyx", 0, pelvis, union([
            plate(sacrum[0], sacrum[1], sacrum[3], 0.008 * k), plate(sacrum[0], sacrum[3], sacrum[2], 0.008 * k),
            plate(sacrum[2], sacrum[3], sacrum[4], 0.007 * k),
            chain([sacrum[4], sacrum[4] + SIMD3(0, -0.02, 0.008) * k], [0.005 * k, 0.003 * k]),
        ], smooth: 0.004 * k), cell: 0.003)

        // The ribs: each from its vertebra's transverse process round the side to the sternum (the first seven), to
        // the rib above's cartilage (the next three) or free (the last two); 10 mm under the skin at the side, deeper
        // at the back and under the chest's muscles.
        for s: Float in [-1, 1] {
            for i in 1...12 {
                let process = processes[i - 1]
                let ends: [(y: Float, angle: Float)] = [(0.072, 9), (0.114, 9), (0.156, 9), (0.198, 9), (0.24, 9), (0.282, 9), (0.324, 9),
                                                         (0.4, 22), (0.45, 33), (0.5, 45), (0.56, 80), (0.62, 100)]
                let end = ends[i - 1], frontY = chestTop - height * end.y
                let reach = [0.065, 0.085, 0.1, 0.11, 0.115, 0.12, 0.12, 0.12, 0.118, 0.115, 0.11, 0.105][i - 1] * k
                var points = [s < 0 ? process.right : process.left]
                for j in 0...5 {
                    let w = 1 - Float(j) / 5, angle = 150 + (end.angle - 150) * Float(j) / 5
                    let y = frontY + (process.y - frontY) * pow(w, 0.7)
                    let depth: Float = j == 5 && i <= 7 ? 0.013 : angle >= 120 ? 0.022 + (angle - 120) / 30 * 0.008
                        : angle >= 50 ? 0.0145 : 0.0145 + (50 - angle) / 50 * 0.004
                    points.append(point(.trunk(trunk(y).h), angle, side: s, depth: depth * k, reach: reach))
                }
                let along = BodyMarks.curve(points, samples: 16)
                let radii = along.indices.map { j in (0.0045 + 0.001 * sin(.pi * Float(j) / 15) + (i == 1 ? 0.0012 : 0)) * k }
                add("rib \(i)", s, process.bone, chain(along, radii), cell: 0.003)
            }
        }
        // The sternum: a plate down the chest's midline, `fat` under the skin, its manubrium wide at the top.
        let rows: [(y: Float, half: Float)] = [(0.07, 0.019), (0.13, 0.014), (0.19, 0.011), (0.25, 0.012), (0.31, 0.011), (0.36, 0.007)]
        let midline = rows.map { row -> (c: SIMD3<Float>, half: Float) in
            (point(.trunk(trunk(chestTop - height * row.y).h), 0, side: 1, depth: fat + 0.0055 * k), row.half * k)
        }
        var sternum: [Solid] = []
        for i in 0..<(midline.count - 1) {
            let (a, b) = (midline[i], midline[i + 1])
            let corners = [a.c - x * a.half, a.c + x * a.half, b.c + x * b.half, b.c - x * b.half]
            sternum += [plate(corners[0], corners[1], corners[2], 0.0055 * k), plate(corners[0], corners[2], corners[3], 0.0055 * k)]
        }
        sternum.append(cone(midline.last!.c, midline.last!.c - up * 0.02 * k, 0.005 * k, 0.003 * k))   // the xiphoid
        add("sternum", 0, index(.chest), union(sternum, smooth: 0.004 * k), cell: 0.003)

        for s: Float in [-1, 1] {
            let side = s < 0 ? "Right" : "Left"
            let chest = index(.chest)
            let upper = rig.bones[index(.upperArm(s))], fore = rig.bones[index(.forearm(s))]
            let shoulder = upper.from, elbow = upper.to, wrist = fore.to
            let ax = simd_normalize(elbow - shoulder)
            let along = simd_float3x3(columns: (ax, up, simd_cross(ax, up)))

            // The clavicle: an S from the sternum's notch out over the chest and back to the shoulder's top, `fat`
            // under the skin; the scapula a plate on the back under its muscles, its spine a ridge out to the acromion.
            let notch = chestTop - height * 0.07
            let acromion = marks.out(SIMD3(s * 0.165 * k, shoulder.y, shoulder.z), up, depth: fat + 0.006 * k)
            let clavicle = [marks.out(SIMD3(s * 0.022 * k, notch, 0), front, depth: fat + 0.006 * k),
                            marks.out(SIMD3(s * 0.06 * k, notch + 0.008 * k, 0), front, depth: fat + 0.006 * k),
                            marks.out(SIMD3(s * 0.115 * k, notch + 0.006 * k, -0.035 * k), simd_normalize(SIMD3(0, 1, 0.4)), depth: fat + 0.006 * k),
                            acromion]
            add("clavicle", s, chest, chain(BodyMarks.curve(clavicle, samples: 10), [0.0085, 0.008, 0.0075, 0.007, 0.0065, 0.0065, 0.0065, 0.0068, 0.007, 0.0072].map { $0 * k }),
                cell: 0.003)
            let superior = behind([s * 0.075 * k, shoulder.y + 0.009 * k], depth: 0.022 * k)
            let inferior = behind([s * 0.09 * k, shoulder.y - 0.166 * k], depth: 0.018 * k)
            let medial = behind([s * 0.07 * k, shoulder.y - 0.076 * k], depth: 0.02 * k)
            let lateral = behind([s * 0.125 * k, shoulder.y - 0.106 * k], depth: 0.022 * k)
            let glenoid = shoulder - ax * 0.032 * k
            let spine = [behind([s * 0.075 * k, shoulder.y - 0.036 * k], depth: fat + 0.006 * k),
                         behind([s * 0.12 * k, shoulder.y - 0.012 * k], depth: fat + 0.007 * k), acromion]
            add("scapula", s, chest, union([
                plate(superior, medial, glenoid, 0.003 * k), plate(medial, inferior, lateral, 0.003 * k), plate(medial, lateral, glenoid, 0.003 * k),
                ball(glenoid, 0.013 * k), chain(BodyMarks.curve(spine, samples: 8), [0.005, 0.0055, 0.006, 0.0065, 0.007, 0.0075, 0.008, 0.008].map { $0 * k }),
                ellipsoid(acromion, SIMD3(0.014, 0.006, 0.018) * k),
            ], smooth: 0.006 * k), cell: 0.003)

            // The arm: the humerus's head in the shoulder, its condyles wide along the elbow's hinge (up and down in
            // the T pose, the elbow's crease forward); the ulna along the forearm's back (the pinky's side), its point
            // behind the elbow; the radius from beside the outer condyle round to the thumb's side of the wrist.
            add("humerus", s, index(.upperArm(s)), union([
                ball(shoulder + ax * 0.004 * k, 0.023 * k),
                ball(shoulder + (ax * 0.014 + up * 0.011 + front * 0.006) * k, 0.013 * k),
                chain([shoulder + ax * 0.02 * k, (shoulder + elbow) / 2, elbow - ax * 0.03 * k], [0.0135 * k, 0.011 * k, 0.012 * k]),
                ellipsoid(elbow - ax * 0.014 * k, SIMD3(0.015, 0.029, 0.013) * k, frame: along),
            ], smooth: 0.008 * k), cell: 0.004)
            func forearm(_ u: Float, _ angle: Float, _ depth: Float) -> SIMD3<Float> { point(.on(.forearm(s), u), angle, side: s, depth: depth) }
            add("ulna", s, index(.forearm(s)), union([
                ball(forearm(-0.02, 180, fat + 0.011 * k), 0.011 * k),
                ball(elbow + ax * 0.008 * k, 0.012 * k),
                chain([forearm(0.04, 180, fat + 0.01 * k), forearm(0.4, 176, fat + 0.008 * k), forearm(0.75, 170, fat + 0.007 * k),
                       forearm(0.96, 165, fat + 0.007 * k)], [0.01, 0.0075, 0.0065, 0.007].map { $0 * k }),
                ball(forearm(0.985, 160, fat + 0.006 * k), 0.006 * k),
            ], smooth: 0.006 * k), cell: 0.003)
            add("radius", s, index(.forearm(s)), union([
                ball(elbow + (ax * 0.012 + up * 0.014) * k, 0.0105 * k),
                chain([elbow + (ax * 0.02 + up * 0.012) * k, forearm(0.5, 60, 0.02 * k), forearm(0.9, 20, fat + 0.012 * k)], [0.0075, 0.0085, 0.012].map { $0 * k }),
                ball(forearm(0.95, 10, fat + 0.012 * k), 0.013 * k),
            ], smooth: 0.008 * k), cell: 0.003)

            // The hand: the carpals two rows of four; a metacarpal from them to each finger's first joint, its
            // phalanges between its joints (gaps where they meet), the thumb's from its first.
            func hand(_ name: String) -> SIMD3<Float> { joint(side + "Hand" + name) }
            let fingers = ["Index", "Middle", "Ring", "Pinky"]
            let knuckles = fingers.map { hand($0 + "1") }
            let carpus = SIMD3(wrist.x, wrist.y - 0.002 * k, (wrist.z + (knuckles.first!.z + knuckles.last!.z) / 2) / 2) + ax * 0.02 * k
            var bones: [Solid] = []
            for row in 0..<2 {
                for c in 0..<4 { bones.append(ball(carpus + ax * (Float(row) * 0.016 - 0.008) * k + front * (Float(c) - 1.5) * 0.0135 * k, 0.0078 * k)) }
            }
            func digit(_ joints: [SIMD3<Float>], _ radii: [Float]) {
                for i in 0..<(joints.count - 1) {
                    let a = joints[i], b = joints[i + 1], d = simd_normalize(b - a)
                    bones.append(cone(a + d * 0.0035 * k, b - d * (i == joints.count - 2 ? 0.007 : 0.0035) * k, radii[i] * k, radii[i + 1] * k))
                }
            }
            for (finger, knuckle) in zip(fingers, knuckles) {
                let base = SIMD3(carpus.x, carpus.y, carpus.z + (knuckle.z - carpus.z) * 0.6) + ax * 0.02 * k, head = knuckle - ax * 0.006 * k
                bones += [cone(base, head, 0.0052 * k, 0.0042 * k), ball(head, 0.0058 * k)]
                digit([knuckle, hand(finger + "2"), hand(finger + "3"), hand(finger + "4")], [0.0048, 0.0042, 0.0036, 0.003])
            }
            digit([hand("Thumb1"), hand("Thumb2"), hand("Thumb3"), hand("Thumb4")], [0.0058, 0.0048, 0.0042, 0.0034])
            bones.append(ball(hand("Thumb1") - simd_normalize(hand("Thumb2") - hand("Thumb1")) * 0.004 * k, 0.0065 * k))
            add("hand", s, index(.hand(s)), union(bones, smooth: 0.0015 * k), cell: 0.0022)

            // The hip bone: the ilium a fan of plates from over the hip's socket up to its crest (`fat` under the skin
            // at the front and the side); the pubis forward to the middle, the ischium down and back.
            let socket = rig.bones[index(.thigh(s))].from
            let acetabulum = socket + SIMD3(-s * 0.008, 0.008, 0) * k
            let crest = BodyMarks.curve([(0.0, 38), (0.1, 70), (0.16, 100), (0.14, 130), (0.06, 160)].map { h, angle in
                point(.trunk(Float(h)), Float(angle), side: s, depth: fat + 0.0065 * k)
            }, samples: 9)
            let wing = acetabulum + up * 0.03 * k
            var ilium: [Solid] = [chain(crest, [Float](repeating: 0.0065 * k, count: crest.count)), ball(acetabulum, 0.026 * k)]
            for i in 0..<(crest.count - 1) { ilium.append(plate(wing, crest[i], crest[i + 1], 0.004 * k)) }
            ilium.append(plate(acetabulum, wing, crest[0], 0.006 * k))
            ilium.append(plate(acetabulum, wing, crest.last!, 0.006 * k))
            let symphysis = marks.out(SIMD3(s * 0.006 * k, socket.y - 0.02 * k, 0), front, depth: 0.025 * k)
            ilium.append(chain([acetabulum + SIMD3(-s * 0.01, -0.01, 0.025) * k, symphysis], [0.009 * k, 0.008 * k]))
            ilium.append(chain([acetabulum + SIMD3(0, -0.02, -0.02) * k, acetabulum + SIMD3(-s * 0.02, -0.055, -0.03) * k,
                                symphysis + SIMD3(0, -0.02, -0.03) * k], [0.011 * k, 0.012 * k, 0.008 * k]))
            add("hip bone", s, pelvis, union(ilium, smooth: 0.008 * k), cell: 0.004)

            // The leg: the femur's head in the socket, its neck out to the greater trochanter, its shaft down to the
            // condyles; the kneecap `fat` under the skin in front of them; the tibia's plateau under them, its crest and
            // inner face under the shin's skin, its malleolus the ankle's inner knob; the fibula outside it, its head
            // under the knee, its malleolus the outer knob.
            let thigh = rig.bones[index(.thigh(s))], shinBone = rig.bones[index(.shin(s))]
            let knee = thigh.to, ankle = shinBone.to
            let trochanter = marks.out(socket - up * 0.015 * k, x * s, depth: fat + 0.018 * k)
            add("femur", s, index(.thigh(s)), union([
                ball(socket, 0.022 * k), cone(socket, trochanter, 0.016 * k, 0.015 * k), ball(trochanter, 0.016 * k),
                ball(socket + SIMD3(-s * 0.01, -0.06, -0.012) * k, 0.009 * k),
                chain([trochanter - up * 0.02 * k, mix(socket, knee, 0.5) + (x * s + front) * 0.008 * k, knee + up * 0.06 * k],
                      [0.015 * k, 0.0135 * k, 0.016 * k]),
                ellipsoid(knee + SIMD3(0.021, 0.018, -0.008) * k, SIMD3(0.018, 0.022, 0.026) * k),
                ellipsoid(knee + SIMD3(-0.021, 0.018, -0.008) * k, SIMD3(0.018, 0.022, 0.026) * k),
            ], smooth: 0.01 * k), cell: 0.004)
            add("patella", s, index(.shin(s)), ellipsoid(marks.out(knee + up * 0.012 * k, front, depth: fat + 0.008 * k), SIMD3(0.02, 0.024, 0.0085) * k),
                cell: 0.003)
            func shin(_ u: Float, _ angle: Float, _ depth: Float) -> SIMD3<Float> { point(.on(.shin(s), u), angle, side: s, depth: depth) }
            let crestRadii: [Float] = [0.016, 0.0125, 0.0115, 0.013]
            add("tibia", s, index(.shin(s)), union([
                ellipsoid(knee - up * 0.022 * k, SIMD3(0.037, 0.017, 0.028) * k),
                ball(marks.out(knee - up * 0.05 * k, front, depth: fat + 0.006 * k), 0.008 * k),
                chain(zip([Float(0.15), 0.4, 0.65, 0.88], crestRadii).map { u, r in shin(u, -20, fat + r * k) }, crestRadii.map { $0 * k }),
                ellipsoid(ankle + up * 0.022 * k, SIMD3(0.022, 0.016, 0.02) * k),
                ball(marks.out(ankle + up * 0.005 * k, -x * s, depth: fat + 0.007 * k), 0.009 * k),
            ], smooth: 0.012 * k), cell: 0.003)
            let fibulaHead = marks.out(knee - up * 0.035 * k, simd_normalize(SIMD3(s, 0, -0.6)), depth: fat + 0.009 * k)
            let outerAnkle = marks.out(ankle - up * 0.002 * k, x * s, depth: fat + 0.007 * k)
            add("fibula", s, index(.shin(s)), union([
                ball(fibulaHead, 0.0095 * k), ball(outerAnkle, 0.0095 * k),
                chain([fibulaHead, mix(knee, ankle, 0.5) + SIMD3(s * 0.03, 0, -0.012) * k, outerAnkle], [0.009 * k, 0.0055 * k, 0.008 * k]),
            ], smooth: 0.006 * k), cell: 0.003)

            // The foot: the talus under the ankle, the calcaneus back to the heel, the midfoot's bones in a row; a
            // metatarsal from them to each toe's base (on a line across the foot at the toes' joint), the toes'
            // phalanges forward to their tips.
            let toes = joint(side + "ToeBase"), tips = joint(side + "Toe_End")
            var foot: [Solid] = [ellipsoid(ankle + SIMD3(0, -0.032, 0.012) * k, SIMD3(0.02, 0.014, 0.027) * k)]
            let heel = marks.out(ankle + SIMD3(0, -0.06, 0) * k, -front, depth: fat + 0.016 * k)
            foot.append(chain([ankle + SIMD3(0, -0.05, -0.005) * k, heel], [0.016 * k, 0.02 * k]))
            let midfoot = mix(ankle, toes, 0.38) - up * 0.012 * k
            for o: Float in [-0.024, -0.008, 0.008, 0.022] { foot.append(ball(midfoot + x * s * o * k, 0.011 * k)) }
            foot.append(ball(midfoot - front * 0.018 * k - x * s * 0.012 * k, 0.012 * k))
            foot.append(ball(midfoot - front * 0.012 * k + x * s * 0.02 * k, 0.012 * k))
            let spread: [Float] = [-0.03, -0.01, 0.007, 0.023, 0.038], back: [Float] = [0, -0.002, -0.008, -0.016, -0.026]
            for i in 0..<5 {
                let big = i == 0
                let head = SIMD3(toes.x + s * spread[i] * k, ground + (big ? 0.02 : 0.018) * k, toes.z + back[i] * k)
                let base = midfoot + front * 0.018 * k + x * s * spread[i] * 0.55 * k + up * (0.005 - abs(Float(i) - 1) * 0.002) * k
                foot += [cone(base, head, (big ? 0.009 : 0.0065) * k, (big ? 0.0085 : 0.0055) * k), ball(head, (big ? 0.01 : 0.0065) * k)]
                let end = tips.z - (big ? 0.012 : 0.015 + 0.008 * Float(i)) * k
                let shares: [Float] = big ? [0, 0.55, 1] : [0, 0.45, 0.75, 1]
                let joints = shares.map { t in SIMD3(head.x, head.y - 0.004 * k * t, head.z + (end - head.z) * t) }
                for j in 0..<(joints.count - 1) {
                    let r0: Float = big ? 0.0075 - 0.0012 * Float(j) : 0.0042 - 0.0005 * Float(j)
                    foot.append(cone(joints[j] + front * 0.003 * k, joints[j + 1] - front * 0.003 * k, r0 * k, (r0 - 0.0006) * k))
                }
            }
            add("foot", s, index(.foot(s)), union(foot, smooth: 0.002 * k), cell: 0.003)
        }
        return pieces
    }

    /// The nearest bone's distance at `p` (trilinear between the grid's samples; 5 cm beyond it).
    func distance(_ p: SIMD3<Float>) -> Float {
        let g = (p - lo) / SkeletonAtlas.gridCell
        let f = g.rounded(.down)
        let i = SIMD3<Int>(f)
        guard i.x >= 0, i.y >= 0, i.z >= 0, i.x < counts.x - 1, i.y < counts.y - 1, i.z < counts.z - 1 else { return 0.05 }
        let t = g - f
        @inline(__always) func v(_ x: Int, _ y: Int, _ z: Int) -> Float { values[((i.z + z) * counts.y + i.y + y) * counts.x + i.x + x] }
        let x00 = v(0, 0, 0) + (v(1, 0, 0) - v(0, 0, 0)) * t.x, x10 = v(0, 1, 0) + (v(1, 1, 0) - v(0, 1, 0)) * t.x
        let x01 = v(0, 0, 1) + (v(1, 0, 1) - v(0, 0, 1)) * t.x, x11 = v(0, 1, 1) + (v(1, 1, 1) - v(0, 1, 1)) * t.x
        let y0 = x00 + (x10 - x00) * t.y, y1 = x01 + (x11 - x01) * t.y
        return y0 + (y1 - y0) * t.z
    }
}
