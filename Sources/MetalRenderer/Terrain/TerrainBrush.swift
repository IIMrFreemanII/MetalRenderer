import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// What a terrain brush does where it is dragged.
package enum TerrainTool: String, Codable, CaseIterable, Identifiable {
    // Sculpting.
    case raise, lower, smooth, flatten, setHeight, ramp, noise, terrace
    // Erosion and the generator, as brushes (TerrainErosion, TerrainGenerator).
    case erode, crumble, stamp
    // The ground's layers (TerrainPaint), and where the brushes leave it alone.
    case paint, erase, protect, unprotect

    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .raise: return "Raise"
        case .lower: return "Lower"
        case .smooth: return "Smooth"
        case .flatten: return "Flatten"
        case .setHeight: return "Set height"
        case .ramp: return "Ramp"
        case .noise: return "Noise"
        case .terrace: return "Terrace"
        case .erode: return "Erode (water)"
        case .crumble: return "Crumble (thermal)"
        case .stamp: return "Generator stamp"
        case .paint: return "Paint layer"
        case .erase: return "Erase paint"
        case .protect: return "Protect"
        case .unprotect: return "Unprotect"
        }
    }
    package var symbol: String {
        switch self {
        case .raise: return "arrow.up.circle"
        case .lower: return "arrow.down.circle"
        case .smooth: return "drop"
        case .flatten: return "minus.circle"
        case .setHeight: return "ruler"
        case .ramp: return "line.diagonal"
        case .noise: return "waveform"
        case .terrace: return "stairs"
        case .erode: return "cloud.rain"
        case .crumble: return "mountain.2"
        case .stamp: return "seal"
        case .paint: return "paintbrush"
        case .erase: return "eraser"
        case .protect: return "lock"
        case .unprotect: return "lock.open"
        }
    }
    /// It changes the ground's heights (else its paint or protection).
    package var sculpts: Bool { !paints && self != .protect && self != .unprotect }
    package var paints: Bool { self == .paint || self == .erase }
    /// It acts once, when the stroke ends (a ramp from where it began to where it ends).
    package var actsOnRelease: Bool { self == .ramp }
}

/// A terrain brush: what it does, how large (metres), how strong, how soft its edge, how far apart its dabs are.
package struct TerrainBrush: Codable, Equatable {
    package var tool = TerrainTool.raise
    package var radius: Float = 12
    package var strength: Float = 0.5
    /// Where the edge starts to fade, as a share of the radius (0: from the middle, 1: a hard edge).
    package var hardness: Float = 0.3
    /// Dabs apart, as a share of the radius.
    package var spacing: Float = 0.2
    /// Held still, it keeps acting (dabs a second at full strength).
    package var airbrush: Float = 6
    /// Set height: metres (the world's y). Noise: metres per feature. Terrace: metres a step, and how hard (0...1).
    package var height: Float = 0
    package var noiseScale: Float = 18
    package var terraceStep: Float = 4
    package var terraceSharpness: Float = 0.8
    /// Paint: the layer.
    package var layer = 1
    /// Pen pressure scales its strength.
    package var pressure = true

    /// The brush's weight at `t` (distance / radius, 0...1).
    @inline(__always) package func falloff(_ t: Float) -> Float {
        guard t < 1 else { return 0 }
        let h = min(max(hardness, 0), 0.99)
        if t <= h { return 1 }
        let x = (t - h) / (1 - h)
        return 1 - x * x * (3 - 2 * x)
    }

    /// (As the memberwise initializer, for the modules above this one.)
    package init(tool: TerrainTool = TerrainTool.raise, radius: Float = 12, strength: Float = 0.5, hardness: Float = 0.3, spacing: Float = 0.2, airbrush: Float = 6, height: Float = 0, noiseScale: Float = 18, terraceStep: Float = 4, terraceSharpness: Float = 0.8, layer: Int = 1, pressure: Bool = true) {
        self.tool = tool
        self.radius = radius
        self.strength = strength
        self.hardness = hardness
        self.spacing = spacing
        self.airbrush = airbrush
        self.height = height
        self.noiseScale = noiseScale
        self.terraceStep = terraceStep
        self.terraceSharpness = terraceSharpness
        self.layer = layer
        self.pressure = pressure
    }
}

/// A dab: where (the world's x, z) and how much of the brush's strength (pressure, the airbrush's share of a second).
package struct TerrainDab: Equatable {
    var center: SIMD2<Double>
    var amount: Float
}

/// A stroke: dabs `spacing` apart along the cursor's path over the ground (in the world's metres), and what it began at.
struct TerrainStroke {
    let brush: TerrainBrush
    /// Where it began, and the ground's height there (flatten's level, a ramp's start).
    let start: SIMD2<Double>
    let startHeight: Float
    private(set) var last: SIMD2<Double>
    var lastHeight: Float
    /// The cursor's path over the ground (a river's line), a point every metre or so.
    private(set) var path: [SIMD2<Double>]
    private var carried: Double = 0   // metres along the path since the last dab

    package init(brush: TerrainBrush, start: SIMD2<Double>, height: Float) {
        self.brush = brush
        self.start = start
        startHeight = height
        last = start
        lastHeight = height
        path = [start]
    }

    /// The first dab.
    func begin(pressure: Float) -> [TerrainDab] { [TerrainDab(center: start, amount: brush.pressure ? pressure : 1)] }

    /// The dabs from where the cursor was to `p`.
    mutating func move(to p: SIMD2<Double>, height: Float, pressure: Float) -> [TerrainDab] {
        let step = Double(max(brush.radius * brush.spacing, 0.05))
        let d = p - last, length = simd_length(d)
        lastHeight = height
        if let end = path.last, simd_distance(end, p) >= 1 { path.append(p) }
        guard length > 0 else { return [] }
        var out: [TerrainDab] = []
        var at = step - carried
        while at <= length {
            out.append(TerrainDab(center: last + d * (at / length), amount: brush.pressure ? pressure : 1))
            at += step
        }
        carried = length - (at - step)
        last = p
        return out
    }
}

/// What a stroke (or a generator's run, an import) changed: each tile as it was before and after. Undone, the tiles
/// are put back as they were; redone, as they became. Arrays are shared with the field until it changes them again.
package struct TerrainUndoRecord {
    var before: [SIMD2<Int>: TerrainTile?] = [:]
    var after: [SIMD2<Int>: TerrainTile?] = [:]
    var title = ""

    /// Bytes held (an estimate: the arrays of the tiles' two states).
    var bytes: Int {
        func size(_ t: TerrainTile?) -> Int {
            guard let t else { return 0 }
            return t.delta.count * 4 + (t.paint?.count ?? 0) + (t.mask?.count ?? 0) + (t.protect?.count ?? 0)
        }
        return before.values.reduce(0) { $0 + size($1) } + after.values.reduce(0) { $0 + size($1) }
    }
}

/// The brushes' work on a terrain's snapshot (TerrainField.edit): each changes the samples under a dab and says which
/// tiles it changed. Heights are worked out as the ground's (base + delta) and kept as deltas.
enum TerrainSculpt {
    /// The samples within `radius` of `center` (the world's): their range of sample indices, kept in the terrain.
    static func range(_ grid: TerrainGrid, center: SIMD2<Double>, radius: Float) -> (lo: SIMD2<Int>, hi: SIMD2<Int>)? {
        let a = grid.coordinates(center.x - Double(radius), center.y - Double(radius))
        let b = grid.coordinates(center.x + Double(radius), center.y + Double(radius))
        var lo = SIMD2(Int(a.x.rounded(.up)), Int(a.y.rounded(.up))), hi = SIMD2(Int(b.x.rounded(.down)), Int(b.y.rounded(.down)))
        if let glo = grid.lo, let ghi = grid.hi {
            lo = simd_max(lo, glo)
            hi = simd_min(hi, ghi)
        }
        return lo.x <= hi.x && lo.y <= hi.y ? (lo, hi) : nil
    }

    /// Calls `body` with each sample of `lo`...`hi` (sample i, j, its base height, its delta to change), a tile at a time,
    /// making the tiles it needs; `record` keeps the tiles as they were before the stroke first touched them.
    @discardableResult
    static func forEach(_ s: inout TerrainSnapshot, lo: SIMD2<Int>, hi: SIMD2<Int>, record: inout TerrainUndoRecord,
                        _ body: (Int, Int, Float, inout Float) -> Void) -> Set<SIMD2<Int>> {
        let grid = s.grid, n = grid.tileCells
        var touched = Set<SIMD2<Int>>()
        for t in grid.tiles(from: lo, to: hi) {
            let first = grid.firstSample(t)
            let a = simd_max(lo, first), b = simd_min(hi, first &+ (n - 1))
            guard a.x <= b.x, a.y <= b.y else { continue }
            if record.before[t] == nil { record.before[t] = .some(s.tiles[t]) }
            let base = s.baseCache.heights(t, base: s.base)
            var tile = s.tiles[t] ?? TerrainTile(cells: n)
            s.tiles[t] = nil   // (so that the arrays aren't shared while they change)
            tile.delta.withUnsafeMutableBufferPointer { delta in
                for j in a.y...b.y {
                    for i in a.x...b.x {
                        let k = (j - first.y) * n + (i - first.x)
                        body(i, j, base[k], &delta[k])
                    }
                }
            }
            tile.changed(a &- first, b &- first, cells: n)
            s.tiles[t] = tile
            touched.insert(t)
        }
        return touched
    }

    /// One dab of a sculpting brush. `stroke`: the stroke it is part of (its start, for flatten).
    static func dab(_ s: inout TerrainSnapshot, brush b: TerrainBrush, dab: TerrainDab, stroke: TerrainStroke?,
                    record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        guard let (lo, hi) = range(s.grid, center: dab.center, radius: b.radius) else { return [] }
        // (A dab's share of the stroke: as much ground changed per metre dragged whatever the spacing.)
        let grid = s.grid, radius = Double(b.radius), amount = b.strength * dab.amount * min(max(b.spacing, 0.02), 1) / 0.2
        // The heights around it as they are now (smooth reads its neighbours'), one sample beyond on each side.
        let w = hi.x - lo.x + 3
        let before = s.heights(from: lo &- 1, count: SIMD2(w, hi.y - lo.y + 3), step: 1)
        @inline(__always) func h(_ i: Int, _ j: Int) -> Float { before[(j - lo.y + 1) * w + (i - lo.x + 1)] }
        let target: Float
        switch b.tool {
        case .flatten: target = stroke?.startHeight ?? h((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
        case .setHeight: target = b.height
        default: target = 0
        }
        let noiseSeed = UInt32(truncatingIfNeeded: 0x7E44A1)
        let snapshot = s   // (its protection, read while `s` changes)
        return forEach(&s, lo: lo, hi: hi, record: &record) { i, j, base, delta in
            let p = grid.place(i, j), d = simd_distance(p, dab.center) / radius
            var wgt = b.falloff(Float(d)) * amount
            guard wgt > 0 else { return }
            let prot = snapshot.protection(i, j)
            if prot > 0 { wgt *= 1 - prot }
            guard wgt > 0 else { return }
            let now = h(i, j)
            var next = now
            switch b.tool {
            case .raise: next = now + wgt * b.radius * 0.02
            case .lower: next = now - wgt * b.radius * 0.02
            case .smooth:
                // Toward the mean of the 3 x 3 around it.
                var sum: Float = 0
                for dj in -1...1 { for di in -1...1 { sum += h(i + di, j + dj) } }
                next = now + min(wgt * 1.5, 1) * (sum / 9 - now)
            case .flatten, .setHeight: next = now + min(wgt, 1) * (target - now)
            case .noise:
                let q = SIMD2(Float(p.x), Float(p.y)) / max(b.noiseScale, 0.5)
                next = now + wgt * b.noiseScale * 0.03 * Terrain.fbm(q, octaves: 4, seed: noiseSeed)
            case .terrace:
                let step = max(b.terraceStep, 0.1), x = now / step, f = x - x.rounded(.down)
                // A step's flat (sharpness 1: a riser in a twentieth of its width).
                let k = 1 / (1 - min(max(b.terraceSharpness, 0), 0.95))
                let shaped = (x.rounded(.down) + min(max((f - 0.5) * k + 0.5, 0), 1)) * step
                next = now + min(wgt, 1) * (shaped - now)
            default: return
            }
            delta += next - now
        }
    }

    /// A ramp from `a` (at height `ha`) to `b` (`hb`), `width` across (the brush's diameter), its sides fading by the
    /// brush's hardness: the ground along it set to the line between the two heights.
    static func ramp(_ s: inout TerrainSnapshot, from a: SIMD2<Double>, _ ha: Float, to b: SIMD2<Double>, _ hb: Float, brush: TerrainBrush,
                     record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        let r = Double(brush.radius), lo2 = simd_min(a, b) - r, hi2 = simd_max(a, b) + r
        guard let (lo, _) = range(s.grid, center: lo2 + (SIMD2(r, r)), radius: brush.radius),
              let (_, hi) = range(s.grid, center: hi2 - SIMD2(r, r), radius: brush.radius) else { return [] }
        let grid = s.grid, axis = b - a, length2 = max(simd_length_squared(axis), 1e-6)
        let strength = min(brush.strength * 2, 1)
        let snapshot = s
        return forEach(&s, lo: lo, hi: hi, record: &record) { i, j, base, delta in
            let p = grid.place(i, j), t = min(max(simd_dot(p - a, axis) / length2, 0), 1)
            let across = simd_distance(p, a + axis * t) / r
            var wgt = brush.falloff(Float(across)) * strength
            let prot = snapshot.protection(i, j)
            if prot > 0 { wgt *= 1 - prot }
            guard wgt > 0 else { return }
            let now = base + delta, target = ha + (hb - ha) * Float(t)
            delta += wgt * (target - now)
        }
    }

    /// Protection painted under a dab (`on`: protected, else free).
    static func protect(_ s: inout TerrainSnapshot, brush b: TerrainBrush, dab: TerrainDab, on: Bool,
                        record: inout TerrainUndoRecord) -> Set<SIMD2<Int>> {
        guard let (lo, hi) = range(s.grid, center: dab.center, radius: b.radius) else { return [] }
        let grid = s.grid, n = grid.tileCells, radius = Double(b.radius)
        var touched = Set<SIMD2<Int>>()
        for t in grid.tiles(from: lo, to: hi) {
            let first = grid.firstSample(t)
            let a = simd_max(lo, first), c = simd_min(hi, first &+ (n - 1))
            guard a.x <= c.x, a.y <= c.y else { continue }
            if record.before[t] == nil { record.before[t] = .some(s.tiles[t]) }
            var tile = s.tiles[t] ?? TerrainTile(cells: n)
            s.tiles[t] = nil
            if tile.protect == nil {
                // Starts as the base says (the city's streets), then is painted.
                var p = [UInt8](repeating: 0, count: n * n)
                for j in 0..<n { for i in 0..<n { p[j * n + i] = UInt8(min(max(s.base.protection(first.x + i, first.y + j), 0), 1) * 255) } }
                tile.protect = p
            }
            for j in a.y...c.y {
                for i in a.x...c.x {
                    let w = b.falloff(Float(simd_distance(grid.place(i, j), dab.center) / radius)) * min(b.strength * dab.amount * 2, 1)
                    guard w > 0 else { continue }
                    let k = (j - first.y) * n + (i - first.x), now = Float(tile.protect![k]) / 255
                    let next = on ? now + (1 - now) * w : now * (1 - w)
                    tile.protect![k] = UInt8((min(max(next, 0), 1) * 255).rounded())
                }
            }
            tile.changed(a &- first, c &- first, cells: n)
            s.tiles[t] = tile
            touched.insert(t)
        }
        return touched
    }
}
