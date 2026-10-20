import Foundation
import simd

/// What a fractured object is made of: how it breaks (its pattern), how hard it is to break, what its broken faces
/// and its dust look like. UE Chaos's damage thresholds per level and its connection graph's strength are these
/// numbers (Fracture/FractureTree.swift, Physics+Fracture.swift).
enum FractureMaterial: Int, Codable, CaseIterable {
    case concrete, stone, brick, glass, wood
    /// The demolition scene's partitions (plasterboard on studs) and its steel furniture (cabinets, desks' frames).
    case plaster, metal

    var title: String {
        switch self {
        case .concrete: return "Concrete"
        case .stone: return "Stone"
        case .brick: return "Brick"
        case .glass: return "Glass"
        case .wood: return "Wood"
        case .plaster: return "Plaster"
        case .metal: return "Metal"
        }
    }

    /// kg/m^3 (lighter than the real thing, so that a cannonball moves a wall's chunks).
    var density: Float {
        switch self {
        case .concrete: return 1300
        case .stone: return 1500
        case .brick: return 1100
        case .glass: return 1600
        case .wood: return 550
        case .plaster: return 700
        case .metal: return 1800
        }
    }

    /// The impact (N s) per m^2 of a piece's size (its volume^(2/3)) that breaks it into its children.
    var toughness: Float {
        switch self {
        case .concrete: return 420
        case .stone: return 520
        case .brick: return 300
        case .glass: return 45
        case .wood: return 260
        case .plaster: return 120
        case .metal: return 700
        }
    }

    /// ...and at least its mass times this (m/s): a small piece isn't broken by one of its size dropped on it.
    var breakSpeed: Float {
        switch self {
        case .concrete: return 4
        case .stone: return 5
        case .brick: return 4
        case .glass: return 1.2
        case .wood: return 6
        case .plaster: return 3
        case .metal: return 8
        }
    }

    /// The force (N) per m^2 of shared face a weld between two pieces holds (the mortar's, the fibres').
    var strength: Float {
        switch self {
        case .concrete: return 4e6
        case .stone: return 4.5e6
        case .brick: return 2e6
        case .glass: return 1.5e6
        case .wood: return 5e6
        case .plaster: return 8e5
        case .metal: return 8e6
        }
    }

    var friction: Float { self == .glass ? 0.35 : self == .wood ? 0.6 : 0.7 }
    var restitution: Float { self == .glass ? 0.15 : 0.08 }

    /// Its dust's colour (linear) and how much it makes; glass makes none, only glints.
    var dust: (colour: SIMD3<Float>, amount: Float) {
        switch self {
        case .concrete: return ([0.42, 0.41, 0.39], 1)
        case .stone: return ([0.5, 0.47, 0.42], 0.8)
        case .brick: return ([0.45, 0.2, 0.12], 0.9)
        case .glass: return ([0.8, 0.85, 0.9], 0)
        case .wood: return ([0.4, 0.3, 0.2], 0.35)
        case .plaster: return ([0.72, 0.7, 0.66], 1.2)
        case .metal: return ([0.4, 0.42, 0.45], 0)
        }
    }

    /// The pattern it breaks in, by default.
    var pattern: FracturePattern {
        switch self {
        case .concrete, .stone, .plaster, .metal: return .voronoi
        case .brick: return .bricks
        case .glass: return .radial
        case .wood: return .splinters
        }
    }
}

/// How an object is cut into pieces, level by level (a piece of one level is cut again into the next's).
enum FracturePattern: String, Codable, CaseIterable {
    /// Voronoi cells of random sites inside each piece (Chaos's uniform / clustered Voronoi).
    case voronoi
    /// Across the grain into planks' lengths, then along it into splinters (Voronoi stretched along the grain).
    case splinters
    /// Courses of staggered bricks, then each brick in halves.
    case bricks
    /// A pane's radial cracks and rings round a point, then each shard across.
    case radial

    var title: String {
        switch self {
        case .voronoi: return "Voronoi"
        case .splinters: return "Splinters"
        case .bricks: return "Bricks"
        case .radial: return "Radial (glass)"
        }
    }
}

/// How one object is fractured: what the Fracture Editor edits and saves (FractureStore), what a scene builds from.
struct FractureRecipe: Codable, Equatable {
    var material: FractureMaterial
    var pattern: FracturePattern
    var seed: UInt64 = 1
    /// Pieces per piece at each level (the first: the object's pieces). At most `maxLevels`.
    var counts: [Int]
    /// Scales the material's toughness (breaking into children) and strength (welds).
    var toughness: Float = 1
    var strength: Float = 1
    /// Splinters: the grain's direction (shape space) and how much longer than wide a splinter is.
    var grain: SIMD3<Float> = [1, 0, 0]
    var stretch: Float = 4
    /// Bricks: a brick's size (along the wall, up, through it); the wall's length is along x and its height along y.
    var brick: SIMD3<Float> = [0.24, 0.075, 0.115]
    /// Radial: where the cracks start (shape space) and how many sectors and rings.
    var centre: SIMD3<Float> = .zero
    /// How much the sites crowd towards `centre` (0: evenly; 1: most near it), Chaos's clustered Voronoi.
    var clustering: Float = 0
    /// How rough a cell's faces are: each site is jittered by this share of its spacing.
    var jitter: Float = 0.9

    static let maxLevels = 3

    static func defaults(_ material: FractureMaterial) -> FractureRecipe {
        switch material {
        case .concrete, .stone: return FractureRecipe(material: material, pattern: .voronoi, counts: [14, 6])
        case .brick: return FractureRecipe(material: material, pattern: .bricks, counts: [0, 2])
        case .glass: return FractureRecipe(material: material, pattern: .radial, counts: [12, 2], jitter: 0.5)
        case .wood: return FractureRecipe(material: material, pattern: .splinters, counts: [3, 5])
        case .plaster, .metal: return FractureRecipe(material: material, pattern: .voronoi, counts: [6, 3])
        }
    }

    /// The same with every level's count times `scale` (the scene's Pieces setting), at least 2 where it cuts.
    func scaled(_ scale: Float) -> FractureRecipe {
        var r = self
        r.counts = counts.enumerated().map { level, n in
            n <= 0 ? n : max(2, Int((Float(n) * (level == 0 ? scale : scale.squareRoot())).rounded()))
        }
        return r
    }
}

/// The cells each pattern cuts a cell into.
enum FracturePatterns {
    /// `cell` cut into `count` pieces by `pattern` at `level` (0: the object's own cut). `inside`: the object's
    /// distance (shape space), when it isn't the cell itself; sites outside it are moved in. Empty: nothing to cut.
    static func split(_ cell: ConvexCell, recipe: FractureRecipe, level: Int, random: inout SplitMix,
                      inside: ((SIMD3<Float>) -> Float)? = nil) -> [ConvexCell] {
        guard level < recipe.counts.count else { return [] }
        let count = recipe.counts[level]
        switch (recipe.pattern, level) {
        case (.bricks, 0):
            return bricks(cell, size: recipe.brick, random: &random)
        case (.bricks, _), (.radial, 1...):
            return count >= 2 ? across(cell, count: count, random: &random) : []
        case (.radial, _):
            return radial(cell, centre: recipe.centre, sectors: max(count, 3), rings: max(2, count / 4), jitter: recipe.jitter,
                          random: &random)
        case (.splinters, 0):
            return count >= 2 ? slabs(cell, axis: normalize(recipe.grain), count: count, random: &random) : []
        case (.splinters, _):
            return count >= 2 ? voronoi(cell, count: count, metric: stretched(normalize(recipe.grain), recipe.stretch),
                                        recipe: recipe, random: &random, inside: inside) : []
        case (.voronoi, _):
            return count >= 2 ? voronoi(cell, count: count, metric: matrix_identity_float3x3, recipe: recipe, random: &random,
                                        inside: inside) : []
        }
    }

    /// A metric squashing distances along `axis` by `stretch`: its Voronoi cells are that much longer along it.
    static func stretched(_ axis: SIMD3<Float>, _ stretch: Float) -> simd_float3x3 {
        // S = I + (1/stretch - 1) a a^T.
        let k = 1 / max(stretch, 1) - 1
        return matrix_identity_float3x3 + simd_float3x3(rows: [axis * axis.x, axis * axis.y, axis * axis.z]) * k
    }

    // MARK: Voronoi

    /// `count` random sites in the cell (crowding to the recipe's centre by its clustering; inside the object where
    /// `inside` says), each one's cell in the metric `s` (|S (x - site)|): the bisector of sites a and b is the plane
    /// x . S^T S (b - a) = (|S b|^2 - |S a|^2) / 2.
    static func voronoi(_ cell: ConvexCell, count: Int, metric s: simd_float3x3, recipe: FractureRecipe, random: inout SplitMix,
                        inside: ((SIMD3<Float>) -> Float)?) -> [ConvexCell] {
        let box = cell.bounds
        var sites: [SIMD3<Float>] = []
        var tries = 0
        // Random sites kept apart (no slivers), crowded towards the centre by `clustering`.
        let extent = box.hi - box.lo
        while sites.count < count && tries < count * 200 {
            tries += 1
            var p = box.lo + SIMD3(random.float(), random.float(), random.float()) * extent
            if recipe.clustering > 0 {
                let t = pow(random.float(), 1 + 3 * recipe.clustering)
                p = recipe.centre + (p - recipe.centre) * t
            }
            guard cell.contains(p, slack: -1e-4 * cell.size) else { continue }
            if let inside, inside(p) > 0 { continue }
            // Keep sites apart (a sliver between two near sites is a piece nobody sees): at least a share of the
            // spacing `count` sites would have, less as the jitter grows.
            let spacing = pow(cell.volume / Float(count), 1 / 3)
            let least = spacing * 0.55 * (1 - 0.5 * recipe.jitter)
            if sites.contains(where: { length(s * ($0 - p)) < least }) { continue }
            sites.append(p)
        }
        guard sites.count >= 2 else { return [] }
        let metric = s.transpose * s
        var cells: [ConvexCell] = []
        for (i, a) in sites.enumerated() {
            // Nearest first in the metric: past twice the farthest corner's distance, no site cuts the cell.
            let order = sites.indices.filter { $0 != i }.sorted { length(s * (sites[$0] - a)) < length(s * (sites[$1] - a)) }
            var c: ConvexCell? = cell
            for j in order {
                guard let current = c else { break }
                let b = sites[j]
                let reach = current.vertices.map { length(s * ($0 - a)) }.max() ?? 0
                if length(s * (b - a)) > 2 * reach { break }
                var n = metric * (b - a)
                let l = length(n)
                guard l > 1e-9 else { continue }
                let d = (dot(b, metric * b) - dot(a, metric * a)) / 2 / l
                n /= l
                c = current.clipped(by: SIMD4(n, d), tag: Int32(j))
            }
            if let c { cells.append(c) }
        }
        return cells
    }

    // MARK: Splinters

    /// Slabs across `axis` (a beam snapping into lengths): `count` of about equal length, their cuts a little tilted.
    static func slabs(_ cell: ConvexCell, axis: SIMD3<Float>, count: Int, random: inout SplitMix) -> [ConvexCell] {
        let vs = cell.vertices
        let lo = vs.map { dot($0, axis) }.min() ?? 0, hi = vs.map { dot($0, axis) }.max() ?? 0
        let (u, v) = ConvexCell.basis(axis)
        var cuts: [SIMD4<Float>] = []
        for k in 1..<count {
            let t = lo + (hi - lo) * (Float(k) + (random.float() - 0.5) * 0.5) / Float(count)
            let n = normalize(axis + (u * (random.float() - 0.5) + v * (random.float() - 0.5)) * 0.5)
            let middle = cell.centroid
            let at = middle + axis * (t - dot(middle, axis))
            cuts.append(SIMD4(n, dot(n, at)))
        }
        return slices(cell, cuts: cuts)
    }

    /// The cell between each pair of consecutive cuts (planes that don't cross inside it, in order along their normals).
    static func slices(_ cell: ConvexCell, cuts: [SIMD4<Float>]) -> [ConvexCell] {
        var out: [ConvexCell] = []
        for k in 0...cuts.count {
            var c: ConvexCell? = cell
            if k > 0 { c = c?.clipped(by: -cuts[k - 1], tag: Int32(2 * k)) }        // past the cut before
            if k < cuts.count { c = c?.clipped(by: cuts[k], tag: Int32(2 * k + 1)) }  // short of the next
            if let c { out.append(c) }
        }
        return out
    }

    /// `count` pieces of a cell cut across its longest side, a little tilted (a brick in halves, a shard across).
    static func across(_ cell: ConvexCell, count: Int, random: inout SplitMix) -> [ConvexCell] {
        let box = cell.bounds, e = box.hi - box.lo
        let axis: SIMD3<Float> = e.x >= e.y && e.x >= e.z ? [1, 0, 0] : e.y >= e.z ? [0, 1, 0] : [0, 0, 1]
        // A shard's longest side may lie across its box: take the cell's own longest direction among its corners.
        let vs = cell.vertices
        var far = (Float(0), axis)
        for a in vs { for b in vs where length(b - a) > far.0 { far = (length(b - a), normalize(b - a)) } }
        return slabs(cell, axis: far.1, count: count, random: &random)
    }

    // MARK: Bricks

    /// The wall (its box's x along it, y up, z through it) in courses of staggered bricks of `size` (snapped so a
    /// whole number of courses and bricks fit), each a box cell.
    static func bricks(_ cell: ConvexCell, size: SIMD3<Float>, random: inout SplitMix) -> [ConvexCell] {
        let box = cell.bounds, e = box.hi - box.lo
        let courses = max(1, Int((e.y / size.y).rounded())), h = e.y / Float(courses)
        let along = max(1, Int((e.x / size.x).rounded())), l = e.x / Float(along)
        var out: [ConvexCell] = []
        for c in 0..<courses {
            let y0 = box.lo.y + Float(c) * h, y1 = y0 + h
            // The course's joints, staggered by half a brick every other course; a sliver at an end joins its neighbour.
            var joints: [Float] = [box.lo.x]
            var x = box.lo.x + (c % 2 == 0 ? l : l / 2)
            while x < box.hi.x - l * 0.2 { joints.append(x); x += l }
            joints.append(box.hi.x)
            if joints.count > 2 && joints[1] - joints[0] < l * 0.2 { joints.remove(at: 1) }
            for k in 0..<(joints.count - 1) {
                var brick: ConvexCell? = cell
                brick = brick?.clipped(by: SIMD4(-1, 0, 0, -joints[k]), tag: 1)
                brick = brick?.clipped(by: SIMD4(1, 0, 0, joints[k + 1]), tag: 2)
                brick = brick?.clipped(by: SIMD4(0, -1, 0, -y0), tag: 3)
                brick = brick?.clipped(by: SIMD4(0, 1, 0, y1), tag: 4)
                if let brick { out.append(brick) }
            }
        }
        return out
    }

    // MARK: Radial

    /// A pane (its thinnest side across it) in `sectors` wedges round `centre` and `rings` rings out to its edge, each
    /// wedge's cracks and each ring's radius jittered: the shards a stone through glass makes.
    static func radial(_ cell: ConvexCell, centre: SIMD3<Float>, sectors: Int, rings: Int, jitter: Float,
                       random: inout SplitMix) -> [ConvexCell] {
        let box = cell.bounds, e = box.hi - box.lo
        let normal: SIMD3<Float> = e.x <= e.y && e.x <= e.z ? [1, 0, 0] : e.y <= e.z ? [0, 1, 0] : [0, 0, 1]
        let (u, v) = ConvexCell.basis(normal)
        let c = centre - normal * dot(centre - box.centroid, normal)
        let reach = cell.vertices.map { length(($0 - c) - normal * dot($0 - c, normal)) }.max() ?? 1
        // The cracks' angles, jittered within their sector.
        var angles: [Float] = []
        let step = 2 * Float.pi / Float(sectors), offset = random.float() * step
        for k in 0..<sectors { angles.append(offset + step * (Float(k) + (random.float() - 0.5) * jitter * 0.8)) }
        // The rings' radii: nearer each other near the centre.
        var radii: [Float] = []
        for k in 1..<rings {
            let t = pow(Float(k) / Float(rings), 1.6)
            radii.append(reach * t * (1 + (random.float() - 0.5) * jitter * 0.3))
        }
        var out: [ConvexCell] = []
        for k in 0..<sectors {
            let a0 = angles[k], a1 = k + 1 < sectors ? angles[k + 1] : angles[0] + 2 * .pi
            let d0 = u * cos(a0) + v * sin(a0), d1 = u * cos(a1) + v * sin(a1)
            // The wedge between the two cracks: inside where it is past d0's crack (counter-clockwise) and short of d1's.
            let n0 = -cross(normal, d0), n1 = cross(normal, d1)
            var wedge: ConvexCell? = cell
            wedge = wedge?.clipped(by: SIMD4(n0, dot(n0, c)), tag: Int32(1000 + k))
            wedge = wedge?.clipped(by: SIMD4(n1, dot(n1, c)), tag: Int32(1000 + (k + 1) % sectors))
            guard let w = wedge else { continue }
            // Its rings: chords across the wedge's middle direction, each a little tilted.
            let mid = normalize(d0 + d1)
            var cuts: [SIMD4<Float>] = []
            for r in radii {
                let tilt = (random.float() - 0.5) * jitter * 0.5
                let n = normalize(mid + cross(normal, mid) * tilt)
                let at = c + mid * r
                cuts.append(SIMD4(n, dot(n, at)))
            }
            out += slices(w, cuts: cuts)
        }
        return out
    }
}
