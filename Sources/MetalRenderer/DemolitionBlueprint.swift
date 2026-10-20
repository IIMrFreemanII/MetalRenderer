import Foundation
import simd

/// What the demolition scene's office is made of (Scene+Demolition.swift): the generated building's plan (BuildingPlan)
/// and openings cut into blocks a fracture each, every one standing on what is under it (no two touch: a millimetre
/// between them, so nothing starts inside anything).
///
/// The outer walls are piers between the windows (full height, at most `pier` long), spandrels under them and lintels
/// over them, the glass in them; each storey's slab over it, in panels at most `panel` long, cut round the stair's well
/// and the lift's shaft; columns where the panels meet in the open floors; the partitions between rooms, less their
/// doorways, and the heads over those; the stair's flights as ramps (a walker climbs a slope where it would trip on a
/// step), its landings, its spine; the rooms' furniture as its collision boxes. Pure: the same settings give the same
/// blocks on any thread.
struct DemolitionBlueprint {
    enum Kind: Int, CaseIterable {
        case pier, spandrel, lintel, glass, slab, column, partition, doorHead, stair, furniture
        var title: String {
            switch self {
            case .pier: return "Pier"
            case .spandrel: return "Spandrel"
            case .lintel: return "Lintel"
            case .glass: return "Glass"
            case .slab: return "Slab"
            case .column: return "Column"
            case .partition: return "Partition"
            case .doorHead: return "Door head"
            case .stair: return "Stair"
            case .furniture: return "Furniture"
            }
        }
    }
    /// What a block looks like and breaks as.
    enum Look: Int, CaseIterable {
        case facade, slab, column, plaster, glass, stair, wood, metal, fabric, plastic
        var material: FractureMaterial {
            switch self {
            case .facade, .slab, .column, .stair: return .concrete
            case .plaster: return .plaster
            case .glass: return .glass
            case .wood, .fabric: return .wood
            case .metal, .plastic: return .metal
            }
        }
    }

    struct Block {
        var kind: Kind
        var look: Look
        var storey: Int
        /// Its shape (shape space) and where it stands (a rotation and a translation).
        var shape: SDFShape
        var transform: float4x4
        /// Its box in the world (for the checks).
        var lo: SIMD3<Float>, hi: SIMD3<Float>
    }

    var blocks: [Block] = []
    /// The building it was cut from, and its storeys' floors (y, the ground floor's at 0).
    var building: Building
    var floors: [Float] = []
    /// The office's outline (x, z: its outer walls' faces).
    var outline = CityPlan.Rect(lo: .zero, hi: .zero)

    /// The longest a pier, partition or slab panel is (m), and the gap between blocks.
    static let pier: Float = 3, partitionRun: Float = 4, panel: Float = 4, gap: Float = 0.001
    /// Narrower than this (m), a slab's cell is joined to its neighbour and a partition's run left out.
    static let sliver: Float = 0.6
    /// The furniture kept on a storey (the biggest), and what is too flat or loose to be worth a fracture.
    static let furniturePerStorey = 24
    static let skipped: Set<FurnitureItem.Kind> = [.rug, .plant, .tallPlant, .frame, .coatRack]

    /// The office's spec: the office style made plain enough to break (one block, no shops or podium, windows in
    /// bays with wall between them, no glTF props).
    static func spec(_ settings: DemolitionSettings) -> BuildingSpec {
        var spec = BuildingSpec(size: [settings.width, settings.depth])
        spec.edges = [.street, .open, .open, .open]
        var d = BuiltInBuildings.office
        d.id = "demolition"
        d.name = "Demolition office"
        d.proportions = BuildingStyleDef.Proportions(groundHeight: Span(4.0, 4.0), floorHeight: Span(3.6, 3.6), bay: Span(3.6, 4.4),
                                                     pier: Choice([1.0]))
        d.window.share = Choice([0.6])
        d.window.sill = Choice([0.9])
        d.window.height = Span(1.9, 1.9)
        d.window.mullions = Choice([0])
        d.groundWindow = d.window
        d.facade.shops = 0
        d.facade.pilasters = 0
        d.massing = BuildingStyleDef.MassingDef(shapes: [.rect], setback: Span(0, 0), tower: 99, podium: 0, setbacks: Choice([0]),
                                                roof: Choice([.flat]), parapet: Choice([0]), mast: 0)
        d.interior.models = false
        d.interior.clutter = 0.3
        d.interior.plants = 0
        spec.def = d
        spec.floors = settings.floors
        spec.seed = UInt64(settings.seed)
        spec.interior = true
        return spec
    }

    init(_ settings: DemolitionSettings) {
        building = BuildingGenerator.generate(DemolitionBlueprint.spec(settings))
        let plan = building.plan
        guard let first = plan.storeys.first else { return }
        let base = first.floor
        floors = plan.storeys.map { $0.floor - base }
        var footprint = first.usable[0]
        for r in first.usable { footprint = CityPlan.Rect(lo: simd_min(footprint.lo, r.lo), hi: simd_max(footprint.hi, r.hi)) }
        let t = plan.outer
        outline = CityPlan.Rect(lo: footprint.lo - t, hi: footprint.hi + t)
        for s in plan.storeys.indices {
            let f = plan.storeys[s]
            let y = f.floor - base, height = f.ceiling - f.floor
            outerWalls(s, f, footprint: footprint, y: y, height: height, settings: settings)
            let lines = partitions(s, f, footprint: footprint, y: y, height: height)
            if let stair = f.stair, f.climbs {
                let under = s > 0 ? plan.storeys[s - 1] : nil
                let below = under.flatMap { u in u.stair == stair && u.climbs ? (y: u.floor - base, rise: u.top - u.floor) : nil }
                flights(s, stair, y: y, rise: f.top - f.floor, below: below)
            }
            columns(s, f, footprint: footprint, y: y, height: height, lines: lines)
            slab(s, f, y0: f.ceiling - base, y1: f.top - base)
        }
        if settings.furniture { furnish(base: base) }
    }

    // MARK: Blocks

    /// A box from `lo` to `hi`, a gap inside them.
    private mutating func box(_ kind: Kind, _ look: Look, _ storey: Int, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) {
        let g = SIMD3(repeating: DemolitionBlueprint.gap / 2)
        let a = simd_min(lo, hi) + g, b = simd_max(lo, hi) - g
        guard simd_reduce_min(b - a) > 0.005 else { return }
        let half = (b - a) / 2, centre = (a + b) / 2
        blocks.append(Block(kind: kind, look: look, storey: storey, shape: SDFShape(.box(halfExtents: half)), transform: translate(centre),
                            lo: a, hi: b))
    }

    /// ...and the box cut by `planes` too (world space): a ramp.
    private mutating func cut(_ kind: Kind, _ look: Look, _ storey: Int, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>, planes: [SIMD4<Float>]) {
        let g = SIMD3(repeating: DemolitionBlueprint.gap / 2)
        let a = simd_min(lo, hi) + g, b = simd_max(lo, hi) - g
        guard simd_reduce_min(b - a) > 0.005 else { return }
        let half = (b - a) / 2, centre = (a + b) / 2
        var all: [SIMD4<Float>] = [[1, 0, 0, half.x], [-1, 0, 0, half.x], [0, 1, 0, half.y], [0, -1, 0, half.y], [0, 0, 1, half.z], [0, 0, -1, half.z]]
        // (Into the shape's space, centred on the box: n . (p + centre) <= d.)
        for p in planes {
            let n = SIMD3(p.x, p.y, p.z)
            all.append(SIMD4(n, p.w - dot(n, centre) - DemolitionBlueprint.gap / 2))
        }
        let shape = SDFShape([SDFShape.Node(.cell(planes: all, lo: -half, hi: half))])
        blocks.append(Block(kind: kind, look: look, storey: storey, shape: shape, transform: translate(centre), lo: a, hi: b))
    }

    /// Spans from `lo` to `hi` along a line less `holes` (each lo, hi), each cut into runs of at most `most`.
    private static func spans(_ lo: Float, _ hi: Float, less holes: [(Float, Float)], most: Float) -> [(Float, Float)] {
        var out: [(Float, Float)] = []
        var u = lo
        for h in holes.sorted(by: { $0.0 < $1.0 }) {
            if h.0 > u + 0.02 { out.append((u, min(h.0, hi))) }
            u = max(u, h.1)
        }
        if hi > u + 0.02 { out.append((u, hi)) }
        return out.flatMap { s -> [(Float, Float)] in
            let n = max(1, Int(((s.1 - s.0) / most).rounded(.up)))
            return (0..<n).map { k in (s.0 + (s.1 - s.0) * Float(k) / Float(n), s.0 + (s.1 - s.0) * Float(k + 1) / Float(n)) }
        }
    }

    /// A wall along `lo...hi`, `height` tall, as blocks that stand on each other: parted where `cuts` go through it;
    /// where it has `openings` (u0, u1, y0, y1), solid spans between them up to a band over them all (the highest
    /// opening's top to the wall's), the band in pieces from the middle of one span to the next's (each lies on two),
    /// and what is under each opening. Each block: its part (0 a span, 1 under an opening, 2 the band) and box (u, y).
    static func wall(_ lo: Float, _ hi: Float, height: Float, cuts: [(Float, Float)] = [],
                     openings: [(u0: Float, u1: Float, y0: Float, y1: Float)], most: Float) -> [(part: Int, u0: Float, u1: Float, y0: Float, y1: Float)] {
        var out: [(part: Int, u0: Float, u1: Float, y0: Float, y1: Float)] = []
        for segment in spans(lo, hi, less: cuts, most: .infinity) {
            let here = openings.filter { $0.u1 > segment.0 + 0.02 && $0.u0 < segment.1 - 0.02 }
                .map { (u0: max($0.u0, segment.0), u1: min($0.u1, segment.1), y0: $0.y0, y1: $0.y1) }
            guard !here.isEmpty else {
                for sp in spans(segment.0, segment.1, less: [], most: most) { out.append((0, sp.0, sp.1, 0, height)) }
                continue
            }
            let top = min(here.map(\.y1).max()!, height)
            let band = height - top > 0.05
            let below = band ? top : height
            let solid = spans(segment.0, segment.1, less: here.map { ($0.u0, $0.u1) }, most: .infinity)
            for sp in solid {
                for piece in spans(sp.0, sp.1, less: [], most: most) { out.append((0, piece.0, piece.1, 0, below)) }
            }
            for o in here where o.y0 > 0.03 { out.append((1, o.u0, o.u1, 0, min(o.y0, below))) }
            if band {
                let splits = [segment.0] + solid.map { ($0.0 + $0.1) / 2 }.filter { $0 > segment.0 + 0.05 && $0 < segment.1 - 0.05 } + [segment.1]
                for k in 0..<(splits.count - 1) where splits[k + 1] > splits[k] + 0.02 { out.append((2, splits[k], splits[k + 1], top, height)) }
            }
        }
        return out
    }

    // MARK: The outer walls

    private mutating func outerWalls(_ s: Int, _ f: FloorPlan, footprint r: CityPlan.Rect, y: Float, height: Float, settings: DemolitionSettings) {
        let t = building.plan.outer
        let openings = building.openings.filter { $0.storey == s }
        // Front and back run past the corners; the sides between them.
        let sides: [(n: SIMD2<Float>, lo: Float, hi: Float, inner: Float)] = [
            ([0, 1], r.lo.x - t, r.hi.x + t, r.hi.y), ([0, -1], r.lo.x - t, r.hi.x + t, r.lo.y),
            ([1, 0], r.lo.y, r.hi.y, r.hi.x), ([-1, 0], r.lo.y, r.hi.y, r.lo.x)]
        for side in sides {
            let alongX = abs(side.n.y) > 0.5
            let out = alongX ? side.n.y : side.n.x
            let face = side.inner + out * t
            let here = openings.filter { o in
                dot(o.normal, side.n) > 0.5 && abs((alongX ? o.a.y : o.a.x) - face) < 0.1
            }
            let holes = here.map { o -> (u0: Float, u1: Float, y0: Float, y1: Float, glass: Bool) in
                let u0 = alongX ? min(o.a.x, o.c.x) : min(o.a.y, o.c.y), u1 = alongX ? max(o.a.x, o.c.x) : max(o.a.y, o.c.y)
                // (Up to the slab: a lintel between piers would be a light block between heavy ones, which a stack
                // of them awake doesn't hold up.)
                return (max(u0, side.lo), min(u1, side.hi), max(o.y0 - f.floor, 0), height, o.glass)
            }.filter { $0.u1 > $0.u0 + 0.05 }
            // The wall's box between `u0` and `u1` along it, `y0` to `y1` up (its own storey's), `inset` its glass's.
            func wall(_ kind: Kind, _ u0: Float, _ u1: Float, _ y0: Float, _ y1: Float, thickness: Float? = nil) -> (SIMD3<Float>, SIMD3<Float>) {
                let w0 = thickness.map { side.inner + out * (t - $0) / 2 } ?? side.inner
                let w1 = thickness.map { side.inner + out * (t + $0) / 2 } ?? face
                return alongX ? (SIMD3(u0, y + y0, w0), SIMD3(u1, y + y1, w1)) : (SIMD3(w0, y + y0, u0), SIMD3(w1, y + y1, u1))
            }
            let kinds: [(Kind, Look)] = [(.pier, .facade), (.spandrel, .facade), (.lintel, .facade)]
            for p in DemolitionBlueprint.wall(side.lo, side.hi, height: height, openings: holes.map { ($0.u0, $0.u1, $0.y0, $0.y1) },
                                              most: DemolitionBlueprint.pier) {
                let (a, b) = wall(kinds[p.part].0, p.u0, p.u1, p.y0, p.y1)
                box(kinds[p.part].0, kinds[p.part].1, s, a, b)
            }
            for h in holes where h.glass && settings.glass {
                // (Short of the slab: what sags onto a pane breaks it.)
                let (a, b) = wall(.glass, h.u0, h.u1, h.y0, h.y1 - 0.02, thickness: 0.024)
                box(.glass, .glass, s, a, b)
            }
        }
    }

    // MARK: Partitions

    /// The partitions between storey `s`'s rooms (but where they are open to each other), cut round their doorways;
    /// returns their lines (alongX, at, from, to) for the columns to keep clear of.
    private mutating func partitions(_ s: Int, _ f: FloorPlan, footprint r: CityPlan.Rect, y: Float, height: Float)
        -> [(alongX: Bool, at: Float, from: Float, to: Float)] {
        let tp = building.plan.partition
        var edges: [(alongX: Bool, at: Float, from: Float, to: Float)] = []
        for i in f.rooms.indices {
            for j in (i + 1)..<f.rooms.count {
                guard let e = SharedEdge.between(f.rooms[i].rect, f.rooms[j].rect) else { continue }
                if f.doors.contains(where: { $0.kind == .open && $0.touches(i) && $0.touches(j) }) { continue }
                edges.append((e.alongX, e.at, e.from, e.to))
            }
        }
        // In line and end to end: one wall.
        edges.sort { ($0.alongX ? 0 : 1, $0.at, $0.from) < ($1.alongX ? 0 : 1, $1.at, $1.from) }
        var lines: [(alongX: Bool, at: Float, from: Float, to: Float)] = []
        for e in edges {
            if let last = lines.last, last.alongX == e.alongX, abs(last.at - e.at) < 1e-3, e.from <= last.to + 1e-3 {
                lines[lines.count - 1].to = max(last.to, e.to)
            } else {
                lines.append(e)
            }
        }
        for line in lines {
            // Its ends: to the outer wall's inside, or short of the wall it meets by half that's thickness.
            let edgeLo = line.alongX ? r.lo.x : r.lo.y, edgeHi = line.alongX ? r.hi.x : r.hi.y
            let from = abs(line.from - edgeLo) < 1e-3 ? line.from : line.from + tp / 2
            let to = abs(line.to - edgeHi) < 1e-3 ? line.to : line.to - tp / 2
            let doors = f.doors.filter { d in
                d.kind != .open && d.b >= 0 && d.alongX == line.alongX && abs((line.alongX ? d.at.y : d.at.x) - line.at) < 0.02
                    && (line.alongX ? d.at.x : d.at.y) > line.from && (line.alongX ? d.at.x : d.at.y) < line.to
            }
            let holes = doors.map { d -> (u0: Float, u1: Float, y0: Float, y1: Float) in
                let c = line.alongX ? d.at.x : d.at.y
                return (c - d.width / 2, c + d.width / 2, 0, height)   // (to the slab: no head, as the windows)
            }
            // Where a wall along x goes on through it (four rooms' corner): that wall's.
            var cuts: [(Float, Float)] = []
            if !line.alongX {
                for other in lines where other.alongX && other.from + 1e-3 < line.at && line.at < other.to - 1e-3
                    && line.from + 1e-3 < other.at && other.at < line.to - 1e-3 {
                    cuts.append((other.at - tp / 2, other.at + tp / 2))
                }
            }
            func wall(_ u0: Float, _ u1: Float, _ y0: Float, _ y1: Float) -> (SIMD3<Float>, SIMD3<Float>) {
                line.alongX ? (SIMD3(u0, y + y0, line.at - tp / 2), SIMD3(u1, y + y1, line.at + tp / 2))
                            : (SIMD3(line.at - tp / 2, y + y0, u0), SIMD3(line.at + tp / 2, y + y1, u1))
            }
            for p in DemolitionBlueprint.wall(from, to, height: height, cuts: cuts, openings: holes, most: DemolitionBlueprint.partitionRun)
                where p.u1 - p.u0 >= DemolitionBlueprint.sliver / 2 {
                let (a, b) = wall(p.u0, p.u1, p.y0, p.y1)
                box(p.part == 2 ? .doorHead : .partition, .plaster, s, a, b)
            }
        }
        return lines
    }

    // MARK: Columns

    /// Columns where the slab's panels meet inside the open rooms, clear of the partitions and the stair.
    private mutating func columns(_ s: Int, _ f: FloorPlan, footprint r: CityPlan.Rect, y: Float, height: Float,
                                  lines: [(alongX: Bool, at: Float, from: Float, to: Float)]) {
        let half: Float = 0.2, clear = half + building.plan.partition
        for x in DemolitionBlueprint.grid(r.lo.x, r.hi.x).dropFirst().dropLast() {
            for z in DemolitionBlueprint.grid(r.lo.y, r.hi.y).dropFirst().dropLast() {
                let p = SIMD2(x, z)
                guard let room = f.room(at: p), !room.type.isCore, ![.wc, .toilets].contains(room.type) else { continue }
                if let st = f.stair, st.rect.contains(p, margin: clear) { continue }
                if lines.contains(where: { l in
                    let along = l.alongX ? x : z, across = l.alongX ? z : x
                    return abs(across - l.at) < clear && along > l.from - clear && along < l.to + clear
                }) { continue }
                box(.column, .column, s, SIMD3(x - half, y, z - half), SIMD3(x + half, y + height, z + half))
            }
        }
    }

    /// Where a slab's panels part along `lo...hi`: evenly, at most `panel` apart.
    static func grid(_ lo: Float, _ hi: Float) -> [Float] {
        let n = max(1, Int(((hi - lo) / panel).rounded(.up)))
        return (0...n).map { lo + (hi - lo) * Float($0) / Float(n) }
    }

    // MARK: Slabs

    /// Storey `s`'s slab over it (`y0` its underside, `y1` the next floor) out to the outer walls' faces, less the
    /// stair's well and the lift's shaft where they go on up, in panels.
    private mutating func slab(_ s: Int, _ f: FloorPlan, y0: Float, y1: Float) {
        let r = outline
        var holes: [CityPlan.Rect] = []
        if f.climbs {
            if let st = f.stair { holes.append(st.well) }
            for room in f.rooms where room.type == .lift { holes.append(room.rect) }
        }
        var xs = DemolitionBlueprint.grid(r.lo.x, r.hi.x), zs = DemolitionBlueprint.grid(r.lo.y, r.hi.y)
        for h in holes { xs += [h.lo.x, h.hi.x]; zs += [h.lo.y, h.hi.y] }
        func clean(_ v: [Float]) -> [Float] {
            var out: [Float] = []
            for x in v.sorted() where out.last.map({ x - $0 > 0.05 }) ?? true { out.append(x) }
            return out
        }
        xs = clean(xs)
        zs = clean(zs)
        var cells: [CityPlan.Rect] = []
        for i in 0..<(xs.count - 1) {
            for j in 0..<(zs.count - 1) {
                let mid = SIMD2((xs[i] + xs[i + 1]) / 2, (zs[j] + zs[j + 1]) / 2)
                if holes.contains(where: { $0.contains(mid, margin: 0) }) { continue }
                cells.append(CityPlan.Rect(lo: SIMD2(xs[i], zs[j]), hi: SIMD2(xs[i + 1], zs[j + 1])))
            }
        }
        // A sliver (between a hole's edge and the grid's) joined to the cell beside it that shares its whole side: a
        // thin strip is light and weak, and comes apart where the rest holds.
        var merged = true
        while merged {
            merged = false
            for a in cells.indices where simd_reduce_min(cells[a].size) < DemolitionBlueprint.sliver {
                let c = cells[a]
                if let b = cells.indices.first(where: { b in
                    guard b != a else { return false }
                    let d = cells[b]
                    let sameX = abs(d.lo.x - c.lo.x) < 1e-3 && abs(d.hi.x - c.hi.x) < 1e-3
                    let sameZ = abs(d.lo.y - c.lo.y) < 1e-3 && abs(d.hi.y - c.hi.y) < 1e-3
                    return sameX && (abs(d.hi.y - c.lo.y) < 1e-3 || abs(d.lo.y - c.hi.y) < 1e-3)
                        || sameZ && (abs(d.hi.x - c.lo.x) < 1e-3 || abs(d.lo.x - c.hi.x) < 1e-3)
                }) {
                    cells[b] = CityPlan.Rect(lo: simd_min(c.lo, cells[b].lo), hi: simd_max(c.hi, cells[b].hi))
                    cells.remove(at: a)
                    merged = true
                    break
                }
            }
        }
        for c in cells { box(.slab, .slab, s, SIMD3(c.lo.x, y0, c.lo.y), SIMD3(c.hi.x, y1, c.hi.y)) }
    }

    // MARK: The stair

    /// A stair's lanes across it (v0, v1) and the top of each along it, piece by piece (u0, u1 and the height at each,
    /// over its storey's floor): the first flight up to the half landing, the spine, the second flight back up to the
    /// next floor; the half landing's over the far end.
    private func lanes(_ st: StairPlan, rise: Float, width: Float, long: Float)
        -> [(v0: Float, v1: Float, top: [(u0: Float, u1: Float, ya: Float, yb: Float)], spine: Bool)] {
        let w = st.flightWidth, l = StairPlan.landing, run = StairPlan.run
        let (n1, n2, h) = StairPlan.steps(rise)
        let top1 = l + Float(n1) * run, start2 = l + Float(n2) * run, mid = Float(n1) * h
        var out: [(v0: Float, v1: Float, top: [(u0: Float, u1: Float, ya: Float, yb: Float)], spine: Bool)] = [
            (0, w, [(l, top1, 0, mid), (top1, long, mid, mid)], false),
            (width - w, width, [(l, start2, rise, mid), (start2, long, mid, mid)], false),
        ]
        if width - 2 * w > 0.03 { out.append((w, width - w, [(l, start2, rise, rise), (start2, long, mid, mid)], true)) }
        return out
    }

    /// Storey `s`'s part of the stair (its floor at `y`, `rise` to the next), as InteriorBuilder's but as slopes: each
    /// lane from what the storey below's left (or the ground) up to its own top, in pieces where either bends.
    private mutating func flights(_ s: Int, _ st: StairPlan, y: Float, rise: Float, below: (y: Float, rise: Float)?) {
        // (Inside the partitions round it, which stand half in it.)
        let inset = building.plan.partition / 2
        let long = (st.alongX ? st.rect.size.x : st.rect.size.y) - 2 * inset, width = (st.alongX ? st.rect.size.y : st.rect.size.x) - 2 * inset
        func point(_ u: Float, _ v: Float) -> SIMD2<Float> {
            let r = CityPlan.Rect(lo: st.rect.lo + inset, hi: st.rect.hi - inset)
            let along = st.alongX ? (st.entryLow ? r.lo.x + u : r.hi.x - u) : (st.entryLow ? r.lo.y + u : r.hi.y - u)
            let across = st.alongX ? (st.firstLow ? r.lo.y + v : r.hi.y - v) : (st.firstLow ? r.lo.x + v : r.hi.x - v)
            return st.alongX ? SIMD2(along, across) : SIMD2(across, along)
        }
        // Increasing u, in the world (x, z).
        let eu = point(1, 0) - point(0, 0)
        /// The plane under the line from height `ya` at `ua` to `yb` at `ub` along u (world heights; n . p <= d).
        func under(_ ua: Float, _ ya: Float, _ ub: Float, _ yb: Float) -> SIMD4<Float> {
            let slope = (yb - ya) / (ub - ua)
            var n = SIMD3(-slope * eu.x, 1, -slope * eu.y)
            let d = ya - slope * dot(point(ua, 0), eu)
            let len = simd_length(n)
            n /= len
            return SIMD4(n, d / len)
        }
        /// Height (world) of piecewise line `top` at `u`.
        func height(_ top: [(u0: Float, u1: Float, ya: Float, yb: Float)], _ u: Float, _ base: Float) -> Float {
            let p = top.first { u >= $0.u0 - 1e-4 && u <= $0.u1 + 1e-4 } ?? top[top.count - 1]
            return base + p.ya + (p.yb - p.ya) * (u - p.u0) / max(p.u1 - p.u0, 1e-6)
        }
        let mine = lanes(st, rise: rise, width: width, long: long)
        let theirs = below.map { lanes(st, rise: $0.rise, width: width, long: long) }
        for (k, lane) in mine.enumerated() {
            let floorLane = theirs?[k]
            var cuts = lane.top.flatMap { [$0.u0, $0.u1] } + (floorLane?.top.flatMap { [$0.u0, $0.u1] } ?? [])
            cuts = cuts.sorted()
            var us: [Float] = []
            for c in cuts where us.last.map({ c - $0 > 0.02 }) ?? true { us.append(c) }
            for i in 0..<(us.count - 1) {
                let u0 = us[i], u1 = us[i + 1]
                let t0 = height(lane.top, u0, y), t1 = height(lane.top, u1, y)
                let b0 = floorLane.map { height($0.top, u0, below!.y) } ?? y, b1 = floorLane.map { height($0.top, u1, below!.y) } ?? y
                guard max(t0 - b0, t1 - b1) > 0.02 else { continue }
                let p = point(u0, lane.v0), q = point(u1, lane.v1)
                let lo = SIMD3(min(p.x, q.x), min(b0, b1), min(p.y, q.y)), hi = SIMD3(max(p.x, q.x), max(t0, t1), max(p.y, q.y))
                var planes: [SIMD4<Float>] = []
                if abs(t0 - t1) > 1e-4 { planes.append(under(u0, t0, u1, t1)) }
                if abs(b0 - b1) > 1e-4 { planes.append(-under(u0, b0, u1, b1)) }
                let look: Look = lane.spine && abs(t0 - t1) < 1e-4 && t0 > y + rise - 0.01 ? .plaster : .stair
                if planes.isEmpty { box(.stair, look, s, lo, hi) } else { cut(.stair, look, s, lo, hi, planes: planes) }
            }
        }
    }

    // MARK: Furniture

    /// Each storey's furniture (the biggest `furniturePerStorey`) as its collision boxes, a millimetre off the floor;
    /// none that would stand in a column or in another piece.
    private mutating func furnish(base: Float) {
        guard let interior = building.interior else { return }
        let columns = blocks.filter { $0.kind == .column || $0.kind == .stair || $0.kind == .partition }
        var byStorey: [Int: [(Interior.Furniture, SIMD3<Float>, SIMD3<Float>, Float)]] = [:]
        for item in interior.furniture where !DemolitionBlueprint.skipped.contains(item.kind) && !item.boxes.isEmpty {
            var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
            for b in item.boxes {
                for k in 0..<8 {
                    let c = SIMD3(k & 1 == 0 ? b.lo.x : b.hi.x, k & 2 == 0 ? b.lo.y : b.hi.y, k & 4 == 0 ? b.lo.z : b.hi.z)
                    let w = item.frame * SIMD4(c, 1)
                    lo = simd_min(lo, SIMD3(w.x, w.y, w.z) - [0, base, 0])
                    hi = simd_max(hi, SIMD3(w.x, w.y, w.z) - [0, base, 0])
                }
            }
            let e = hi - lo
            byStorey[item.storey, default: []].append((item, lo, hi, e.x * e.y * e.z))
        }
        for s in byStorey.keys.sorted() {
            let items = byStorey[s]!.sorted { ($0.3, $0.1.x, $0.1.z) > ($1.3, $1.1.x, $1.1.z) }
            var kept: [(SIMD3<Float>, SIMD3<Float>)] = []
            for (item, lo, hi, _) in items where kept.count < DemolitionBlueprint.furniturePerStorey {
                func overlaps(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
                    all(lo .< b - 0.002) && all(a + 0.002 .< hi)
                }
                if columns.contains(where: { overlaps($0.lo, $0.hi) }) || kept.contains(where: { overlaps($0.0, $0.1) }) { continue }
                kept.append((lo, hi))
                // One box round its boxes in its own frame (a table's legs on their own, a few centimetres thick, rattle
                // on the floor and never sleep), lifted a millimetre (and to the ground floor's 0).
                var a = SIMD3<Float>(repeating: .infinity), b = -a
                for x in item.boxes { a = simd_min(a, x.lo); b = simd_max(b, x.hi) }
                let half = simd_max((b - a) / 2 - DemolitionBlueprint.gap / 2, SIMD3(repeating: 0.02))
                let frame = translate([0, DemolitionBlueprint.gap - base, 0]) * item.frame * translate((a + b) / 2)
                blocks.append(Block(kind: .furniture, look: DemolitionBlueprint.look(item.role), storey: s,
                                    shape: SDFShape(.box(halfExtents: half)), transform: frame, lo: lo, hi: hi))
            }
        }
    }

    static func look(_ role: FurnitureItem.Role) -> Look {
        switch role {
        case .wood, .woodDark, .book0, .book1, .book2, .book3, .carton, .paper: return .wood
        case .metal, .chrome: return .metal
        case .fabric, .cushion, .linen, .rug: return .fabric
        default: return .plastic
        }
    }

    // MARK: Checks

    /// Pairs of blocks whose boxes overlap (by more than `tolerance`): none, for a building that stands.
    /// (Ramps and furniture by their boxes, which may touch their neighbours' where the shapes don't.)
    func overlaps(tolerance: Float = 1e-4) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for i in blocks.indices where blocks[i].kind != .furniture {
            for j in (i + 1)..<blocks.count where blocks[j].kind != .furniture {
                let a = blocks[i], b = blocks[j]
                guard all(a.lo .< b.hi - tolerance) && all(b.lo .< a.hi - tolerance) else { continue }
                if a.shape.nodes.count == 1, case .box = a.shape.nodes[0].primitive, b.shape.nodes.count == 1, case .box = b.shape.nodes[0].primitive {
                    out.append((i, j))
                    continue
                }
                // A ramp: inside both anywhere in where their boxes meet?
                let lo = simd_max(a.lo, b.lo), hi = simd_min(a.hi, b.hi), n = 10
                var inside = false
                for k in 0..<(n * n * n) where !inside {
                    let f = (SIMD3(Float(k % n), Float(k / n % n), Float(k / (n * n))) + 0.5) / Float(n)
                    let p = lo + (hi - lo) * f
                    func d(_ x: Block) -> Float {
                        let q = x.transform.inverse * SIMD4(p, 1)
                        return x.shape.distance(SIMD3(q.x, q.y, q.z), volumes: []).d
                    }
                    inside = d(a) < -tolerance && d(b) < -tolerance
                }
                if inside { out.append((i, j)) }
            }
        }
        return out
    }
}
