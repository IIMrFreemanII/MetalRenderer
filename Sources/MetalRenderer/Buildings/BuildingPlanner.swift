import Foundation
import simd

/// A building's floor plans, made before its facades so that the facades follow them: its rooms behind its windows,
/// its doors in its bays, its stair's head over its stair. Seeded from the building's own stream (apart from the
/// facades'), and laid out on the bay grid of its walls, so that no partition meets a window.
///
/// Every storey is laid out around one core (a dog-leg stair, and a lift from `Programme.liftFrom` floors), placed
/// inside the topmost tier so that it runs from the ground to the top: each tier is its lower neighbour stepped in.
/// What is around the core depends on the building's use:
/// - apartments: a corridor past the core with flats on either side (or on one, along a blank back wall), each flat
///   a band of rooms on its windows and a hall and bathroom along its door;
/// - a house: the stair against a side wall, a hall beside it, rooms in front and behind;
/// - offices: the core in the middle of an open floor, meeting rooms along the windows;
/// - a warehouse: one hall, the stair and a small office in its back corners.
extension BuildingAssembler {
    /// The bays of a wall `span` long: its piers, how many bays and how wide (the facade divides it so too).
    static func bays(span: Float, pier stylePier: Float, bay styleBay: Float) -> (pier: Float, count: Int, bay: Float, usable: Float) {
        let pier = min(stylePier, span * 0.15)
        let usable = span - 2 * pier
        let count = max(1, Int((usable / styleBay).rounded()))
        return (pier, count, usable / Float(count), usable)
    }

    /// One wall of a tier and its bays.
    struct WallGrid {
        var a: SIMD2<Float>, c: SIMD2<Float>
        var normal: SIMD2<Float>
        var kind: CityPlan.Edge
        var pier: Float, count: Int, bay: Float
        /// It has windows (a party wall, or one too short, is blank).
        var windows: Bool

        var alongX: Bool { abs(normal.y) > 0.5 }
        /// Its face's coordinate across it (z for a wall along x).
        var line: Float { alongX ? a.y : a.x }
        var lo: Float { alongX ? min(a.x, c.x) : min(a.y, c.y) }
        var hi: Float { alongX ? max(a.x, c.x) : max(a.y, c.y) }
        private var e: SIMD2<Float> { normalize(c - a) }
        /// Where along it (x or z in the lot) its bays meet: where a partition may stand.
        var lines: [Float] {
            guard windows else { return [] }
            return (0...count).map { k in let s = pier + Float(k) * bay; return alongX ? a.x + e.x * s : a.y + e.y * s }.sorted()
        }
        /// Its bays' middles, along it.
        var middles: [Float] {
            guard windows else { return [] }
            return (0..<count).map { k in let s = pier + (Float(k) + 0.5) * bay; return alongX ? a.x + e.x * s : a.y + e.y * s }
        }
    }

    func grids(_ tier: BuildingTier) -> [WallGrid] {
        var out: [WallGrid] = []
        for loop in tier.footprint.loops {
            let normals = Footprint.normals(loop)
            for i in loop.indices {
                let a = loop[i], c = loop[(i + 1) % loop.count], kind = edgeKind(a, c)
                let b = BuildingAssembler.bays(span: length(c - a), pier: style.pier, bay: style.bay)
                out.append(WallGrid(a: a, c: c, normal: normals[i], kind: kind, pier: b.pier, count: b.count, bay: b.bay,
                                    windows: kind != .party && b.usable >= 1.6))
            }
        }
        return out
    }

    /// The outer walls' thickness: the style's, and enough for the deepest window's glass and frame.
    var outerThickness: Float {
        max(style.programme.outerWall, max(style.window.recess, style.groundWindow.recess) + 0.12, 0.33)
    }

    // MARK: - The plan

    mutating func makePlan(_ tiers: [BuildingTier]) -> BuildingPlan {
        var rng = SplitMix64(seed: spec.seed ^ 0x51A2_F00D_C0DE)
        let p = style.programme
        var plan = BuildingPlan(outer: outerThickness, partition: p.partition, slab: p.slab)
        let groundGrids = grids(tiers[0])
        plan.shops = style.shops > 0 && groundGrids.contains { $0.kind == .street && $0.windows } && rng.next() < style.shops

        // The storeys' levels.
        var levels: [(tier: Int, floor: Float, top: Float)] = []
        for (k, tier) in tiers.enumerated() {
            var y = tier.y0
            for (i, h) in tier.heights.enumerated() {
                levels.append((k, tier.ground && i == 0 ? y + BuildingAssembler.step : y, y + h))
                y += h
            }
        }
        let tallest = zip(levels, levels.dropFirst()).map { $1.floor - $0.floor }.max() ?? 3
        let lift = p.liftFrom > 0 && levels.count >= p.liftFrom
        let core = placeCore(tiers, stairLength: StairPlan.length(tallest), lift: lift, &rng)

        var planner = StoreyPlanner(assembler: self, plan: plan, core: core, rng: rng)
        planner.edits = spec.edits
        var typical: [Int: FloorPlan] = [:]   // per tier: its first upper storey's plan, for the ones above it
        for (s, level) in levels.enumerated() {
            let tier = tiers[level.tier]
            let ground = tier.ground && s == levels.firstIndex { $0.tier == level.tier }
            let top = s == levels.count - 1
            let next = s + 1 < levels.count ? levels[s + 1].floor : level.top
            var floor: FloorPlan
            let edited = spec.edits.contains { $0.storeys.contains(s) }
            if !ground, !top, !edited, var made = typical[level.tier] {
                made.storey = s
                made.floor = level.floor
                made.top = next
                made.ceiling = next - p.slab
                floor = made
            } else {
                floor = planner.storey(s, tier: tier, tierIndex: level.tier, floor: level.floor, ceiling: next - p.slab, top: next,
                                       ground: s == 0, topmost: top)
                if !ground && !top && !edited && typical[level.tier] == nil { typical[level.tier] = floor }
            }
            floor.climbs = !top
            plan.storeys.append(floor)
        }
        plan.orphaned = spec.edits.indices.filter { !planner.applied.contains($0) }
        // At night, which rooms have a light on: by the storey and the room, an office's floors more or less together.
        for s in plan.storeys.indices {
            let storeyLit: Float = style.isOffice ? Float(hash(s, -1) % 1000) / 1000 * 1.6 + 0.2 : 1
            for r in plan.storeys[s].rooms.indices {
                let u = Float(hash(s, plan.storeys[s].rooms[r].id) % 10_000) / 10_000
                plan.storeys[s].rooms[r].lit = spec.night && u < spec.lit * storeyLit
            }
        }
        return plan
    }

    private func hash(_ a: Int, _ b: Int) -> UInt64 {
        SplitMix64.mix(spec.seed &* 0x2545_F491_4F6C_DD1D &+ UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9 &+ UInt64(bitPattern: Int64(b)))
    }

    /// Where the core stands: its stair (and lift) in the topmost tier's main part.
    private func placeCore(_ tiers: [BuildingTier], stairLength: Float, lift: Bool, _ rng: inout SplitMix64) -> Core {
        let t = outerThickness, p = style.programme
        let top = tiers[tiers.count - 1]
        let main = StoreyPlanner.usable(top.footprint, inset: t)[0]
        let walls = grids(top)
        let width = 2 * p.stairWidth + StairPlan.spine, shaft: Float = 2.0
        let length = min(stairLength, max(main.size.x, main.size.y) - 1)
        var core = Core(stair: CityPlan.Rect(lo: .zero, hi: .zero), stairAlongX: false, entryLow: false, firstLow: rng.next() < 0.5,
                        lift: nil, mode: .none)
        func lines(_ alongX: Bool, side: Float) -> [Float] {
            walls.filter { $0.alongX == alongX && abs($0.line - side) < t + 0.05 }.flatMap(\.lines)
        }
        /// x from `lines` (of the front and back walls) nearest `want` so that [x, x + w] stays inside.
        func place(_ want: Float, _ w: Float, lo: Float, hi: Float, _ lines: [Float]) -> Float {
            let candidates = lines.filter { $0 >= lo - 1e-3 && $0 + w <= hi + 1e-3 }
            return candidates.min { abs($0 - want) < abs($1 - want) } ?? min(max(want, lo), hi - w)
        }
        let backWindows = walls.contains { $0.alongX && $0.normal.y < -0.5 && $0.windows }
        let ends = lines(true, side: main.hi.y + t) + lines(true, side: main.lo.y - t)
        switch StoreyPlanner.layout(p.use, main) {
        case .apartments:
            // Against the back wall, the corridor in front of it; or, with a blank back (or too shallow), the corridor
            // along the back and the core in front of it, as deep as the flats.
            let depth = main.size.y
            let double = backWindows && depth >= length + p.corridor + 4
            let w = width + (lift ? shaft : 0)
            let x = place(main.center.x - w / 2, w, lo: main.lo.x + 3, hi: main.hi.x - 3, ends)
            if double {
                core.stair = CityPlan.Rect(lo: SIMD2(x, main.lo.y), hi: SIMD2(x + width, main.lo.y + length))
                core.mode = .backCore
            } else {
                let z0 = main.lo.y + p.corridor
                core.stair = CityPlan.Rect(lo: SIMD2(x, z0), hi: SIMD2(x + width, min(z0 + length, main.hi.y)))
                core.mode = .frontCore
            }
            core.stairAlongX = false
            core.entryLow = !double   // the entry faces the corridor
            if lift {
                core.lift = CityPlan.Rect(lo: SIMD2(x + width, double ? core.stair.hi.y - shaft : core.stair.lo.y),
                                          hi: SIMD2(x + width + shaft, double ? core.stair.hi.y : core.stair.lo.y + shaft))
            }
        case .house:
            // Against a side wall (a party wall if it has one), from the back.
            let right = spec.edges[1] == .party && spec.edges[3] != .party ? true : spec.edges[3] == .party ? false : rng.next() < 0.5
            let depth = main.size.y
            var front = max(3.2, (depth - length) * 0.55)
            var back = depth - length - front
            if back < 2.4 { (back, front) = (0, depth - length) }
            _ = front
            let x = right ? main.hi.x - width : main.lo.x
            core.stair = CityPlan.Rect(lo: SIMD2(x, main.lo.y + back), hi: SIMD2(x + width, main.lo.y + back + length))
            core.stairAlongX = false
            core.entryLow = false     // the entry toward the front
            core.mode = right ? .sideRight : .sideLeft
        case .offices:
            // In the middle: the stair along the floor's long side, the lifts and the toilets beside it.
            let alongX = main.size.x >= main.size.y
            let lifts = lift ? (p.liftFrom > 0 && tiers.reduce(0) { $0 + $1.heights.count } >= 12 ? 2 : 1) : 0
            let block = SIMD2(length, width + Float(lifts) * shaft + (lifts > 0 ? 0 : 0))
            let size = alongX ? block : SIMD2(block.y, block.x)
            // (Too narrow a floor for it in the middle: against the back wall.)
            let c = main.center
            var lo = SIMD2(c.x - size.x / 2, c.y - size.y / 2)
            if (alongX ? main.size.y : main.size.x) - (alongX ? size.y : size.x) < 2 * 2.6 {
                if alongX { lo.y = main.lo.y } else { lo.x = main.lo.x }
            }
            if alongX {
                core.stair = CityPlan.Rect(lo: lo, hi: SIMD2(lo.x + length, lo.y + width))
                if lifts > 0 { core.lift = CityPlan.Rect(lo: SIMD2(lo.x + length - shaft * Float(lifts), lo.y + width),
                                                         hi: SIMD2(lo.x + length, lo.y + width + shaft)) }
            } else {
                core.stair = CityPlan.Rect(lo: lo, hi: SIMD2(lo.x + width, lo.y + length))
                if lifts > 0 { core.lift = CityPlan.Rect(lo: SIMD2(lo.x + width, lo.y + length - shaft * Float(lifts)),
                                                         hi: SIMD2(lo.x + width + shaft, lo.y + length)) }
            }
            core.stairAlongX = alongX
            core.entryLow = rng.next() < 0.5
            core.mode = .centre
        case .warehouse:
            // In a back corner, along the back wall (away from a wing behind it), its entry toward the middle.
            var right = rng.next() < 0.5
            if case .l(_, _, let wingRight) = top.footprint.shape { right = !wingRight }
            let x = right ? main.hi.x - length : main.lo.x
            core.stair = CityPlan.Rect(lo: SIMD2(x, main.lo.y), hi: SIMD2(x + length, main.lo.y + width))
            core.stairAlongX = true
            core.entryLow = right
            core.mode = right ? .sideRight : .sideLeft
        }
        // Inside the plan, whatever the rules wanted (a small lot's).
        let all = core.all
        let shift = simd_max(main.lo - all.lo, .zero) - simd_max(all.hi - main.hi, .zero)
        core.stair = CityPlan.Rect(lo: core.stair.lo + shift, hi: core.stair.hi + shift)
        if let l = core.lift {
            let moved = CityPlan.Rect(lo: l.lo + shift, hi: l.hi + shift)
            core.lift = main.contains(moved) ? moved : nil
        }
        if !main.contains(core.stair) {
            core.stair = CityPlan.Rect(lo: simd_max(core.stair.lo, main.lo), hi: simd_min(core.stair.hi, main.hi))
        }
        return core
    }

    /// The core: where the stair is, which way it climbs, the lift beside it, and how the floors are laid out around it.
    struct Core {
        enum Mode { case none, backCore, frontCore, sideLeft, sideRight, centre }
        var stair: CityPlan.Rect
        var stairAlongX: Bool
        var entryLow: Bool
        var firstLow: Bool
        var lift: CityPlan.Rect?
        var mode: Mode

        var stairPlan: StairPlan {
            StairPlan(rect: stair, alongX: stairAlongX, entryLow: entryLow, firstLow: firstLow,
                      flightWidth: ((stairAlongX ? stair.size.y : stair.size.x) - StairPlan.spine) / 2)
        }
        var all: CityPlan.Rect {
            guard let lift else { return stair }
            return CityPlan.Rect(lo: simd_min(stair.lo, lift.lo), hi: simd_max(stair.hi, lift.hi))
        }
    }
}

/// Lays out one storey (BuildingAssembler.makePlan).
struct StoreyPlanner {
    typealias Rect = CityPlan.Rect
    let assembler: BuildingAssembler
    let plan: BuildingPlan
    let core: BuildingAssembler.Core
    var rng: SplitMix64
    /// The building's hand edits, and which of them found what they change.
    var edits: [PlanEdit] = []
    private(set) var applied = Set<Int>()

    private var rooms: [PlanRoom] = []
    private var doors: [PlanDoor] = []
    private var walls: [BuildingAssembler.WallGrid] = []
    private var units = 0
    private var nextID = 0
    private var t: Float = 0.3

    init(assembler: BuildingAssembler, plan: BuildingPlan, core: BuildingAssembler.Core, rng: SplitMix64) {
        self.assembler = assembler
        self.plan = plan
        self.core = core
        self.rng = rng
        var r = rng
        base = r.nextUInt64()
    }
    private let base: UInt64

    var programme: Programme { assembler.style.programme }

    /// How a storey of `use` is laid out on a plan whose main part is `main`: a block of flats too narrow for a
    /// corridor and flats either side of the stair is laid out as a house (a flat a floor, off the stair's landing);
    /// a house's style on a lot as wide as a block of flats, as flats (a town house of many homes).
    static func layout(_ use: BuildingUse, _ main: CityPlan.Rect) -> BuildingUse {
        if use == .apartments && main.size.x < 12 { return .house }
        if use == .house && main.size.x >= 16 { return .apartments }
        return use
    }

    /// The rectangles of `footprint` inside its outer walls: each of its cover's rectangles stepped in from the
    /// walls on its sides, and out to the next one where they meet (a wing reaches into the bar's inset).
    static func usable(_ footprint: Footprint, inset t: Float) -> [Rect] {
        let cover = footprint.cover
        return cover.enumerated().map { i, r in
            func shared(_ side: Int) -> Bool {
                // A whole side against another rectangle of the cover.
                cover.enumerated().contains { j, o in
                    guard j != i else { return false }
                    switch side {
                    case 0: return abs(o.lo.y - r.hi.y) < 1e-3 && o.lo.x <= r.lo.x + 1e-3 && o.hi.x >= r.hi.x - 1e-3
                    case 1: return abs(o.lo.x - r.hi.x) < 1e-3 && o.lo.y <= r.lo.y + 1e-3 && o.hi.y >= r.hi.y - 1e-3
                    case 2: return abs(o.hi.y - r.lo.y) < 1e-3 && o.lo.x <= r.lo.x + 1e-3 && o.hi.x >= r.hi.x - 1e-3
                    default: return abs(o.hi.x - r.lo.x) < 1e-3 && o.lo.y <= r.lo.y + 1e-3 && o.hi.y >= r.hi.y - 1e-3
                    }
                }
            }
            // Into the wall's thickness from an outer side; out to meet the next rectangle's inset on a shared one.
            return Rect(lo: SIMD2(r.lo.x + (shared(3) ? -t : t), r.lo.y + (shared(2) ? -t : t)),
                        hi: SIMD2(r.hi.x - (shared(1) ? -t : t), r.hi.y - (shared(0) ? -t : t)))
        }
    }

    mutating func storey(_ s: Int, tier: BuildingTier, tierIndex: Int, floor: Float, ceiling: Float, top: Float, ground: Bool,
                         topmost: Bool) -> FloorPlan {
        // Its own numbers: a tier's upper storeys are laid out alike, whichever of them is made (an edited one is made
        // afresh, the others are copies).
        rng = SplitMix64(seed: base &+ UInt64(tierIndex) &* 0x9E37_79B9 &+ (ground ? 1 : 2))
        t = plan.outer
        rooms = []
        doors = []
        units = 0
        nextID = 0
        walls = assembler.grids(tier)
        let usable = StoreyPlanner.usable(tier.footprint, inset: t)
        let main = usable[0]
        // The core stands where it stands on every storey: its rooms first.
        add(.stairs, core.stair, unit: -1)
        if let lift = core.lift { add(.lift, lift, unit: -1) }
        switch StoreyPlanner.layout(programme.use, main) {
        case .apartments: apartments(main, wings: Array(usable.dropFirst()), ground: ground)
        case .house: house(main, wings: Array(usable.dropFirst()), ground: ground, topmost: topmost)
        case .offices: offices(main, wings: Array(usable.dropFirst()), ground: ground)
        case .warehouse: warehouse(main, wings: Array(usable.dropFirst()), ground: ground)
        }
        cleanUp(usable)
        if edits.contains(where: { $0.changesRooms && $0.storeys.contains(s) }) {
            applied.formUnion(StoreyPlanner.editRooms(&rooms, edits, storey: s))
            // The street doors' rooms again (the rooms' indices may have changed).
            doors = doors.compactMap { d in
                var d = d
                let inward = (d.alongX ? SIMD2<Float>(0, 1) : SIMD2<Float>(1, 0)) * (t + 0.3)
                guard let r = rooms.firstIndex(where: { $0.rect.contains(d.at + inward) || $0.rect.contains(d.at - inward) }) else { return nil }
                (d.a, d.into) = (r, r)
                return d
            }
        }
        connect(ground: ground)
        if edits.contains(where: { !$0.changesRooms && $0.storeys.contains(s) }) {
            applied.formUnion(StoreyPlanner.editDoors(&doors, rooms: rooms, edits, storey: s))
        }
        return FloorPlan(storey: s, tier: tierIndex, floor: floor, ceiling: ceiling, top: top, usable: usable, rooms: rooms, doors: doors,
                         stair: core.stairPlan, climbs: !topmost, lift: core.lift)
    }

    /// Adds a room: its id (ids are made in order; `cleanUp` makes them the rooms' indices).
    @discardableResult
    private mutating func add(_ type: RoomType, _ rect: Rect, unit: Int) -> Int {
        guard rect.size.x > 0.05, rect.size.y > 0.05 else { return -1 }
        nextID += 1
        rooms.append(PlanRoom(id: nextID - 1, type: type, rect: rect, unit: unit))
        return nextID - 1
    }

    private func index(_ id: Int) -> Int? { rooms.firstIndex { $0.id == id } }

    private mutating func newUnit() -> Int {
        units += 1
        return units - 1
    }

    // MARK: - The bay grid

    /// Where partitions may stand along the side of `r` facing `normal` (its wall's bay lines), and whether that side
    /// has windows at all.
    private func lines(_ r: Rect, facing normal: SIMD2<Float>) -> (lines: [Float], windows: Bool) {
        let alongX = abs(normal.y) > 0.5
        let side: Float = alongX ? (normal.y > 0 ? r.hi.y : r.lo.y) : (normal.x > 0 ? r.hi.x : r.lo.x)
        let lo = alongX ? r.lo.x : r.lo.y, hi = alongX ? r.hi.x : r.hi.y
        let found = walls.filter {
            $0.alongX == alongX && dot($0.normal, normal) > 0.5 && abs($0.line - (side + (alongX ? normal.y : normal.x) * t)) < 0.05
                && $0.hi > lo + 0.1 && $0.lo < hi - 0.1
        }
        let windows = found.contains { $0.windows }
        return (found.flatMap(\.lines).filter { $0 > lo + 0.3 && $0 < hi - 0.3 }.sorted(), windows)
    }

    /// The lines of both sides of `r` across `alongX` (front and back for a band along x).
    private func bandLines(_ r: Rect, alongX: Bool) -> [Float] {
        let a = lines(r, facing: alongX ? SIMD2(0, 1) : SIMD2(1, 0)), b = lines(r, facing: alongX ? SIMD2(0, -1) : SIMD2(-1, 0))
        return (a.lines + b.lines).sorted()
    }

    /// `want` moved to the nearest of `lines` between `lo` and `hi` (or kept, if none is).
    private func snap(_ want: Float, _ lines: [Float], lo: Float, hi: Float) -> Float {
        lines.filter { $0 > lo && $0 < hi }.min { abs($0 - want) < abs($1 - want) } ?? min(max(want, lo), hi)
    }

    /// Cuts from `lo` to `hi` into pieces near `widths` long (in their order), at lines where there are any: the
    /// cuts' positions, ends included. A piece that would be thinner than `least` joins its neighbour.
    private func cut(_ lo: Float, _ hi: Float, _ widths: [Float], _ lines: [Float], least: Float) -> [Float] {
        var at = [lo]
        var want = lo
        for w in widths.dropLast() {
            want += w
            let x = snap(want, lines, lo: at.last! + least, hi: hi - least)
            if x - at.last! >= least && hi - x >= least { at.append(x) }
        }
        at.append(hi)
        return at
    }

    // MARK: - Apartments

    private mutating func apartments(_ m: Rect, wings: [Rect], ground: Bool) {
        let p = programme, c = core.all
        var corridor: Rect
        var bands: [(rect: Rect, toward: SIMD2<Float>)] = []   // what is left for flats, and the way to their windows
        if core.mode == .backCore {
            corridor = Rect(lo: SIMD2(m.lo.x, c.hi.y), hi: SIMD2(m.hi.x, min(c.hi.y + p.corridor, m.hi.y)))
            bands.append((Rect(lo: SIMD2(m.lo.x, corridor.hi.y), hi: m.hi), SIMD2(0, 1)))
            bands.append((Rect(lo: m.lo, hi: SIMD2(c.lo.x, c.hi.y)), SIMD2(0, -1)))
            bands.append((Rect(lo: SIMD2(c.hi.x, m.lo.y), hi: SIMD2(m.hi.x, c.hi.y)), SIMD2(0, -1)))
        } else {
            // The corridor along the core's entry; behind it (a lower tier reaches further back than the top one) flats
            // looking back, or a store.
            let z0 = max(m.lo.y, c.lo.y - p.corridor)
            corridor = Rect(lo: SIMD2(m.lo.x, z0), hi: SIMD2(m.hi.x, z0 + p.corridor))
            bands.append((Rect(lo: SIMD2(m.lo.x, corridor.hi.y), hi: SIMD2(c.lo.x, m.hi.y)), SIMD2(0, 1)))
            bands.append((Rect(lo: SIMD2(c.hi.x, corridor.hi.y), hi: m.hi), SIMD2(0, 1)))
            if z0 > m.lo.y + 1e-3 { bands.append((Rect(lo: m.lo, hi: SIMD2(m.hi.x, z0)), SIMD2(0, -1))) }
        }
        // What of the core's strip the stair and lift leave: stores (a flat's box room, in front of a front core).
        fillGaps(in: Rect(lo: SIMD2(c.lo.x, core.mode == .backCore ? m.lo.y : corridor.hi.y), hi: SIMD2(c.hi.x, core.mode == .backCore ? c.hi.y : m.hi.y)))
        add(.corridor, corridor, unit: -1)
        // The ground floor: a lobby from the front door to the corridor, shops along the street.
        if ground, let front = bands.firstIndex(where: { $0.toward.y > 0 && $0.rect.size.x > 1 }) {
            let door = frontDoorCell(m, avoid: c)
            func overlap(_ r: Rect) -> Float { min(r.hi.x, door.hi) - max(r.lo.x, door.lo) }
            if let k = bands.indices.filter({ bands[$0].toward.y > 0 }).max(by: { overlap(bands[$0].rect) < overlap(bands[$1].rect) })
                ?? Optional(front) {
                let band = bands[k].rect
                let lo = min(max(door.lo, band.lo.x), band.hi.x), hi = min(max(door.hi, band.lo.x), band.hi.x)
                if hi - lo > 1.2 {
                    let lobby = add(.lobby, Rect(lo: SIMD2(lo, band.lo.y), hi: SIMD2(hi, band.hi.y)), unit: -1)
                    doors.append(PlanDoor(kind: .entrance, a: lobby, b: -1, at: SIMD2((lo + hi) / 2, m.hi.y + t),
                                          alongX: true, width: min(1.3, hi - lo - 0.3), height: 2.3, into: lobby))
                    bands[k].rect = Rect(lo: band.lo, hi: SIMD2(lo, band.hi.y))
                    bands.insert((Rect(lo: SIMD2(hi, band.lo.y), hi: band.hi), bands[k].toward), at: k + 1)
                }
            }
        }
        // A wing's corridor reaching through a band to the bar's: the band's flats either side of it, not cut by it.
        for wing in wings where corridor.lo.y > wing.hi.y + 1e-3 && wing.size.x >= p.corridor + 3.5 {
            guard let x0 = wingSpine(wing) else { continue }
            let (a, b) = (x0, x0 + p.corridor)
            bands = bands.flatMap { band -> [(rect: Rect, toward: SIMD2<Float>)] in
                let r = band.rect
                guard r.lo.x < b - 1e-3 && r.hi.x > a + 1e-3 && r.lo.y <= wing.hi.y + 1e-3 && r.hi.y >= corridor.lo.y - 1e-3 else { return [band] }
                return [(Rect(lo: r.lo, hi: SIMD2(a, r.hi.y)), band.toward), (Rect(lo: SIMD2(b, r.lo.y), hi: r.hi), band.toward)]
                    .filter { $0.0.size.x > 0.05 }
            }
        }
        for band in bands where band.rect.size.x > 0.05 && band.rect.size.y > 0.05 {
            guard band.rect.size.x > 3, band.rect.size.y > 2.4 else {
                add(.storage, band.rect, unit: -1)
                continue
            }
            if ground && plan.shops && band.toward.y > 0 && street(band.rect, band.toward) {
                shops(band.rect, toward: band.toward)
            } else {
                flats(band.rect, toward: band.toward)
            }
        }
        for wing in wings { apartmentWing(wing, main: m, corridor: corridor, ground: ground) }
    }

    /// The front wall's bay that the building's door is in (the facade puts it where the plan says): the middle
    /// one, or the one nearest `near`; none over `avoid`.
    private func frontDoorCell(_ m: Rect, near: Float? = nil, avoid: Rect? = nil) -> (lo: Float, hi: Float) {
        let front = walls.filter { $0.alongX && $0.normal.y > 0.5 && $0.windows }.max { $0.line < $1.line }
        guard let front else { return (m.center.x - 1, m.center.x + 1) }
        let l = front.lines
        let cells = zip(l, l.dropFirst()).map { (lo: $0, hi: $1) }.filter { cell in
            avoid.map { cell.hi <= $0.lo.x + 1e-3 || cell.lo >= $0.hi.x - 1e-3 } ?? true
        }
        let want = near ?? (front.lo + front.hi) / 2
        return cells.min { abs(($0.lo + $0.hi) / 2 - want) < abs(($1.lo + $1.hi) / 2 - want) } ?? (m.center.x - 1, m.center.x + 1)
    }

    private func street(_ r: Rect, _ toward: SIMD2<Float>) -> Bool {
        let side: Float = toward.y > 0 ? r.hi.y : r.lo.y
        return walls.contains { $0.alongX && dot($0.normal, toward) > 0.5 && abs($0.line - (side + toward.y * t)) < 0.05 && $0.kind == .street }
    }

    /// A band of flats: cut into flats of about the programme's width, each laid out from its door (the corridor's
    /// side) to its windows (`toward`).
    private mutating func flats(_ band: Rect, toward: SIMD2<Float>) {
        let p = programme
        let alongX = abs(toward.y) > 0.5
        let length = alongX ? band.size.x : band.size.y
        let target = p.unitWidth.draw(rng.next())
        let count = max(1, Int((length / max(target, 3)).rounded()))
        let window = lines(band, facing: toward)
        // (No windows that way, a party wall: no homes, the floor's stores.)
        guard window.windows else { add(.storage, band, unit: -1); return }
        let cuts = cut(alongX ? band.lo.x : band.lo.y, alongX ? band.hi.x : band.hi.y,
                       Array(repeating: length / Float(count), count: count), window.lines, least: min(4, length))
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            let r = alongX ? Rect(lo: SIMD2(a, band.lo.y), hi: SIMD2(b, band.hi.y)) : Rect(lo: SIMD2(band.lo.x, a), hi: SIMD2(band.hi.x, b))
            flat(r, toward: toward, windows: window.windows)
        }
    }

    /// One flat: rooms along its windows (a living room, bedrooms, maybe a kitchen), and if it is deep enough a hall
    /// and a bathroom along its door's side.
    private mutating func flat(_ r: Rect, toward: SIMD2<Float>, windows: Bool) {
        let p = programme
        let unit = newUnit()
        let alongX = abs(toward.y) > 0.5
        let frontage = alongX ? r.size.x : r.size.y, depth = alongX ? r.size.y : r.size.x
        let lo = alongX ? r.lo.x : r.lo.y, hi = alongX ? r.hi.x : r.hi.y
        let window = lines(r, facing: toward).lines
        let flip = rng.next() < 0.5
        // The outer band's rooms, in order from `lo`.
        var kinds: [RoomType] = [.living]
        let open = rng.next() < p.openKitchen
        var left = frontage - p.living
        while left >= p.bedroom && kinds.count < 4 { kinds.append(.bedroom); left -= p.bedroom }
        if !open && left >= p.kitchen { kinds.insert(.kitchen, at: 1); left -= p.kitchen }
        if !windows { kinds = [.living] }
        var widths = kinds.map { k -> Float in k == .living ? p.living : k == .kitchen ? p.kitchen : p.bedroom }
        let total = widths.reduce(0, +)
        widths = widths.map { $0 * frontage / total }
        if flip { kinds.reverse(); widths.reverse() }

        func span(_ a: Float, _ b: Float, _ d0: Float, _ d1: Float) -> Rect {
            // From a to b along the frontage, d0 to d1 deep from the door's side.
            let door: Float = alongX ? (toward.y > 0 ? r.lo.y : r.hi.y) : (toward.x > 0 ? r.lo.x : r.hi.x)
            let s: Float = alongX ? (toward.y > 0 ? 1 : -1) : (toward.x > 0 ? 1 : -1)
            let e0 = door + s * d0, e1 = door + s * d1
            return alongX ? Rect(lo: SIMD2(a, min(e0, e1)), hi: SIMD2(b, max(e0, e1))) : Rect(lo: SIMD2(min(e0, e1), a), hi: SIMD2(max(e0, e1), b))
        }
        let inner = depth >= p.innerBand + 3.2 ? p.innerBand : 0
        let cuts = cut(lo, hi, widths, window, least: min(2.2, frontage / Float(kinds.count)))
        // (Fewer cuts than rooms: the rooms that didn't fit are dropped from the end.)
        let first = rooms.count
        for i in 0..<(cuts.count - 1) {
            let type: RoomType = i < kinds.count ? kinds[i] : .bedroom
            add(type, span(cuts[i], cuts[i + 1], inner, depth), unit: unit)
        }
        guard inner > 0 else {
            // No room for a hall: the bathroom takes a piece of the end room away from the living room (the first
            // one when the rooms are turned round), on the door side.
            let end = flip ? first : rooms.count - 1
            if rooms.indices.contains(end), end >= first, rooms[end].unit == unit {
                let rr = rooms[end].rect, w = min(p.bath + 0.4, max(1.6, frontage / 3))
                let bath = span(flip ? lo : hi - w, flip ? lo + w : hi, 0, min(2.4, depth / 2))
                if bath.size.x > 1.4 && bath.size.y > 1.4 && rr.contains(bath) {
                    splitOff(end, bath, as: .bath)
                }
            }
            return
        }
        // The inner band: the bathroom under the living room's end, the hall along the rest.
        let livingFirst = (kinds.first == .living)
        let bathWidth = min(max(p.bath, 2.0), frontage * 0.4)
        let bathLo = livingFirst ? lo : hi - bathWidth
        add(.bath, span(bathLo, bathLo + bathWidth, 0, inner), unit: unit)
        add(.entrance, span(livingFirst ? lo + bathWidth : lo, livingFirst ? hi : hi - bathWidth, 0, inner), unit: unit)
    }

    /// Cuts `piece` (inside room `i`, along one of its sides) off it as a room of `type`: what is left of room `i`
    /// stays a rectangle if `piece` spans its side; otherwise it is two.
    private mutating func splitOff(_ i: Int, _ piece: Rect, as type: RoomType) {
        let r = rooms[i].rect, unit = rooms[i].unit, kind = rooms[i].type
        var rest: [Rect] = []
        if piece.size.x >= r.size.x - 1e-3 {
            if piece.lo.y > r.lo.y + 1e-3 { rest.append(Rect(lo: r.lo, hi: SIMD2(r.hi.x, piece.lo.y))) }
            if piece.hi.y < r.hi.y - 1e-3 { rest.append(Rect(lo: SIMD2(r.lo.x, piece.hi.y), hi: r.hi)) }
        } else if piece.size.y >= r.size.y - 1e-3 {
            if piece.lo.x > r.lo.x + 1e-3 { rest.append(Rect(lo: r.lo, hi: SIMD2(piece.lo.x, r.hi.y))) }
            if piece.hi.x < r.hi.x - 1e-3 { rest.append(Rect(lo: SIMD2(piece.hi.x, r.lo.y), hi: r.hi)) }
        } else {
            // A corner: the strip beside it, and the rest of the room.
            let lowX = abs(piece.lo.x - r.lo.x) < 1e-3, lowZ = abs(piece.lo.y - r.lo.y) < 1e-3
            rest.append(lowZ ? Rect(lo: SIMD2(lowX ? piece.hi.x : r.lo.x, r.lo.y), hi: SIMD2(lowX ? r.hi.x : piece.lo.x, piece.hi.y))
                             : Rect(lo: SIMD2(lowX ? piece.hi.x : r.lo.x, piece.lo.y), hi: SIMD2(lowX ? r.hi.x : piece.lo.x, r.hi.y)))
            rest.append(lowZ ? Rect(lo: SIMD2(r.lo.x, piece.hi.y), hi: r.hi) : Rect(lo: r.lo, hi: SIMD2(r.hi.x, piece.lo.y)))
        }
        rooms[i].rect = rest.max { $0.area < $1.area } ?? r
        for other in rest where other != rooms[i].rect { add(kind == .living ? .dining : .storage, other, unit: unit) }
        add(type, piece, unit: unit)
    }

    /// Shops along a street band: one or two bays each, a back room behind any deep enough.
    private mutating func shops(_ band: Rect, toward: SIMD2<Float>) {
        let window = lines(band, facing: toward)
        let length = band.size.x
        let count = max(1, Int((length / 7).rounded()))
        let cuts = cut(band.lo.x, band.hi.x, Array(repeating: length / Float(count), count: count), window.lines, least: min(3, length))
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            let unit = newUnit()
            let depth = band.size.y
            let shop: Rect, back: Rect?
            if depth > 7 {
                let split = band.hi.y - max(4.5, depth * 0.62)
                shop = Rect(lo: SIMD2(a, split), hi: SIMD2(b, band.hi.y))
                back = Rect(lo: SIMD2(a, band.lo.y), hi: SIMD2(b, split))
            } else {
                (shop, back) = (Rect(lo: SIMD2(a, band.lo.y), hi: SIMD2(b, band.hi.y)), nil)
            }
            let s = add(.shop, shop, unit: unit)
            if let back { add(.backroom, back, unit: unit) }
            guard s >= 0 else { continue }
            // Its own door from the street, in the bay nearest its middle.
            if let cell = cellNearest((a + b) / 2, in: (a, b), wallZ: band.hi.y + t) {
                doors.append(PlanDoor(kind: .glazed, a: s, b: -1, at: SIMD2(cell, band.hi.y + t), alongX: true, width: 1.1, height: 2.3, into: s))
            }
        }
    }

    /// The middle of the front wall's bay nearest `x`, within `range`.
    private func cellNearest(_ x: Float, in range: (Float, Float), wallZ: Float) -> Float? {
        let wall = walls.filter { $0.alongX && $0.normal.y > 0.5 && abs($0.line - wallZ) < 0.05 && $0.windows }
        return wall.flatMap(\.middles).filter { $0 > range.0 + 0.6 && $0 < range.1 - 0.6 }.min { abs($0 - x) < abs($1 - x) }
    }

    /// A wing of flats behind the bar: a corridor up its middle from the bar's corridor, flats either side.
    private mutating func apartmentWing(_ w: Rect, main: Rect, corridor: Rect, ground: Bool) {
        let p = programme
        let width = w.size.x
        guard width >= p.corridor + 3.5 else {
            flat(w, toward: SIMD2(0, -1), windows: true)
            return
        }
        guard let x0 = wingSpine(w) else {
            flats(w, toward: SIMD2(0, -1))
            return
        }
        let spine = Rect(lo: SIMD2(x0, w.lo.y), hi: SIMD2(x0 + p.corridor, w.hi.y))
        add(.corridor, spine, unit: -1)
        // Its way through the bar to the bar's corridor, if that isn't against the wing already.
        if corridor.lo.y > w.hi.y + 1e-3 {
            let stub = Rect(lo: SIMD2(x0, w.hi.y), hi: SIMD2(x0 + p.corridor, corridor.lo.y))
            carve(stub, as: .corridor)
        }
        for side in [Rect(lo: w.lo, hi: SIMD2(x0, w.hi.y)), Rect(lo: SIMD2(x0 + p.corridor, w.lo.y), hi: w.hi)] where side.size.x > 1 {
            let toward = SIMD2<Float>(side.lo.x < x0 ? -1 : 1, 0)
            if side.size.x >= 3 { flats(side, toward: toward) } else { add(.storage, side, unit: -1) }
        }
    }

    /// Where a wing's corridor runs (its low x): up the middle with flats both sides, or against a side without
    /// windows (a party wall) with flats along the other; nil if neither side has windows.
    private func wingSpine(_ w: Rect) -> Float? {
        let left = lines(w, facing: SIMD2(-1, 0)).windows, right = lines(w, facing: SIMD2(1, 0)).windows
        guard left || right else { return nil }
        return left && right ? w.center.x - programme.corridor / 2 : left ? w.hi.x - programme.corridor : w.lo.x
    }

    /// Takes `r` out of whatever rooms it overlaps (each keeps what is left of it, in up to four pieces) and makes it
    /// a room of `type`.
    private mutating func carve(_ r: Rect, as type: RoomType) {
        var kept: [PlanRoom] = []
        for room in rooms {
            guard room.rect.overlaps(r) else { kept.append(room); continue }
            if room.type.isCore { kept.append(room); continue }
            let a = room.rect
            var pieces: [Rect] = []
            if r.lo.y > a.lo.y { pieces.append(Rect(lo: a.lo, hi: SIMD2(a.hi.x, r.lo.y))) }
            if r.hi.y < a.hi.y { pieces.append(Rect(lo: SIMD2(a.lo.x, r.hi.y), hi: a.hi)) }
            let y0 = max(a.lo.y, r.lo.y), y1 = min(a.hi.y, r.hi.y)
            if r.lo.x > a.lo.x { pieces.append(Rect(lo: SIMD2(a.lo.x, y0), hi: SIMD2(r.lo.x, y1))) }
            if r.hi.x < a.hi.x { pieces.append(Rect(lo: SIMD2(r.hi.x, y0), hi: SIMD2(a.hi.x, y1))) }
            var first = true
            for piece in pieces where piece.size.x > 0.05 && piece.size.y > 0.05 {
                var copy = room
                copy.rect = piece
                if !first { copy.id = nextID; nextID += 1 }
                first = false
                kept.append(copy)
            }
        }
        rooms = kept
        add(type, r, unit: -1)
    }

    // MARK: - A house

    private mutating func house(_ m: Rect, wings: [Rect], ground: Bool, topmost: Bool) {
        let p = programme
        let unit = 0
        units = 1
        let s = core.stair
        let right = core.mode == .sideRight
        // The hall beside the stair, as long as it (wide enough for a door, its 0.9 and a little).
        let hallW = min(1.3, max(1.15, (m.size.x - s.size.x) * 0.25))
        let hall = right ? Rect(lo: SIMD2(s.lo.x - hallW, s.lo.y), hi: SIMD2(s.lo.x, s.hi.y))
                         : Rect(lo: SIMD2(s.hi.x, s.lo.y), hi: SIMD2(s.hi.x + hallW, s.hi.y))
        let h = add(ground ? .entrance : .landing, hall, unit: unit)
        let hi = index(h)!
        // Beside the hall: a bathroom, a kitchen or a store, as deep as the stair.
        let side = right ? Rect(lo: SIMD2(m.lo.x, s.lo.y), hi: SIMD2(hall.lo.x, s.hi.y)) : Rect(lo: SIMD2(hall.hi.x, s.lo.y), hi: SIMD2(m.hi.x, s.hi.y))
        if side.size.x >= 1.6 {
            add(ground ? (s.lo.y > m.lo.y + 0.1 ? .wc : .kitchen) : .bath, side, unit: unit)
        } else if side.size.x > 0.05 {
            rooms[hi].rect = Rect(lo: simd_min(hall.lo, side.lo), hi: simd_max(hall.hi, side.hi))
        }
        // In front: the living room (or a shop, the hall going through to the door), bedrooms upstairs.
        let front = Rect(lo: SIMD2(m.lo.x, s.hi.y), hi: m.hi)
        if front.size.y > 0.5 {
            let window = lines(front, facing: SIMD2(0, 1)).lines
            if ground {
                // The hall reaches the front door, in the bay over the hall (the facade's door).
                let door = frontDoorCell(m, near: hall.center.x)
                let a = right ? min(door.lo, hall.lo.x) : max(door.hi, hall.hi.x)
                let passage = right ? Rect(lo: SIMD2(a, front.lo.y), hi: SIMD2(m.hi.x, front.hi.y))
                                    : Rect(lo: SIMD2(m.lo.x, front.lo.y), hi: SIMD2(a, front.hi.y))
                let room = right ? Rect(lo: front.lo, hi: SIMD2(a, front.hi.y)) : Rect(lo: SIMD2(a, front.lo.y), hi: front.hi)
                let passageW = passage.size.x
                if passageW > 0.8 && passageW < front.size.x - 2 {
                    let e = add(.entrance, passage, unit: unit)
                    doors.append(PlanDoor(kind: .entrance, a: e, b: -1, at: SIMD2((door.lo + door.hi) / 2, m.hi.y + t), alongX: true,
                                          width: min(1.1, door.hi - door.lo - 0.3), height: 2.25, into: e))
                    let r = add(plan.shops ? .shop : .living, room, unit: plan.shops ? newUnit() : unit)
                    if plan.shops, let cell = cellNearest(room.center.x, in: (room.lo.x, room.hi.x), wallZ: m.hi.y + t) {
                        doors.append(PlanDoor(kind: .glazed, a: r, b: -1, at: SIMD2(cell, m.hi.y + t), alongX: true, width: 1.1, height: 2.3, into: r))
                    }
                } else {
                    let r = add(.living, front, unit: unit)
                    if r >= 0 { doors.append(PlanDoor(kind: .entrance, a: r, b: -1, at: SIMD2((door.lo + door.hi) / 2, m.hi.y + t), alongX: true,
                                          width: 1.0, height: 2.25, into: r)) }
                }
            } else {
                // Two rooms split clear of the hall's end: one has all of it for its door, the other opens off that one.
                let lo = front.lo.x + p.bedroom, hi = front.hi.x - p.bedroom
                let split = [snap(hall.hi.x, window.filter { $0 >= hall.hi.x - 1e-3 }, lo: max(lo, hall.hi.x), hi: hi),
                             snap(hall.lo.x, window.filter { $0 <= hall.lo.x + 1e-3 }, lo: lo, hi: min(hi, hall.lo.x))]
                    .filter { $0 >= lo - 1e-3 && $0 <= hi + 1e-3 && ($0 >= hall.hi.x - 1e-3 || $0 <= hall.lo.x + 1e-3) }
                    .min { abs($0 - front.center.x) < abs($1 - front.center.x) }
                let two = split != nil && front.size.x >= 2 * p.bedroom + 0.5 && rng.next() < 0.7
                if two, let x = split {
                    add(.bedroom, Rect(lo: front.lo, hi: SIMD2(x, front.hi.y)), unit: unit)
                    add(rng.next() < 0.3 ? .study : .bedroom, Rect(lo: SIMD2(x, front.lo.y), hi: front.hi), unit: unit)
                } else {
                    add(topmost || rng.next() < 0.8 ? .bedroom : .living, front, unit: unit)
                }
            }
        }
        // Behind: the kitchen and dining room, or a bedroom and the bathroom.
        let back = Rect(lo: m.lo, hi: SIMD2(m.hi.x, s.lo.y))
        if back.size.y > 0.5 {
            let windows = lines(back, facing: SIMD2(0, -1)).windows
            if ground {
                add(windows ? .kitchen : .storage, back, unit: unit)
            } else if back.size.x >= p.bedroom + p.bath {
                let x = right ? back.lo.x + back.size.x - p.bath - 0.3 : back.lo.x + p.bath + 0.3
                add(windows ? .bedroom : .storage, right ? Rect(lo: back.lo, hi: SIMD2(x, back.hi.y)) : Rect(lo: SIMD2(x, back.lo.y), hi: back.hi), unit: unit)
                add(.bath, right ? Rect(lo: SIMD2(x, back.lo.y), hi: back.hi) : Rect(lo: back.lo, hi: SIMD2(x, back.hi.y)), unit: unit)
            } else {
                add(windows ? .bedroom : .bath, back, unit: unit)
            }
        }
        for w in wings { add(ground ? .dining : .bedroom, w, unit: unit) }
        // A bathroom on every storey above the street (and in a house of one storey): where none fitted beside the
        // hall, a corner of the biggest room, the one nearest the hall.
        if (!ground || topmost) && !rooms.contains(where: { $0.type == .bath }) {
            let lived: Set<RoomType> = [.bedroom, .living, .study, .kitchen, .storage, .dining]
            if let i = rooms.indices.filter({ lived.contains(rooms[$0].type) }).max(by: { rooms[$0].rect.area < rooms[$1].rect.area }) {
                let r = rooms[i].rect, c = rooms[hi].rect.center
                let w = min(p.bath + 0.3, r.size.x * 0.45), d = min(2.4, r.size.y * 0.5)
                let x0 = abs(r.lo.x - c.x) < abs(r.hi.x - c.x) ? r.lo.x : r.hi.x - w
                let y0 = abs(r.lo.y - c.y) < abs(r.hi.y - c.y) ? r.lo.y : r.hi.y - d
                if w > 1.3 && d > 1.3 { splitOff(i, Rect(lo: SIMD2(x0, y0), hi: SIMD2(x0 + w, y0 + d)), as: .bath) }
            }
        }
    }

    // MARK: - Offices

    private mutating func offices(_ m: Rect, wings: [Rect], ground: Bool) {
        let p = programme
        var c = core.all
        // Toilets beside the core: behind it, in front of it, or at either end, wherever the floor goes on beyond them
        // far enough to pass (or they stand against the outer wall).
        let toiletDepth: Float = 2.2, pass: Float = 1.4
        func fits(_ gap: Float) -> Bool { gap >= pass || abs(gap) < 1e-3 }
        let wx = min(c.size.x, 5), wz = min(c.size.y, 5)
        // (Up to the wall, if they nearly reach it.)
        func depth(_ room: Float) -> Float { abs(room - toiletDepth) < 0.05 ? room : toiletDepth }
        let back = depth(c.lo.y - m.lo.y), front = depth(m.hi.y - c.hi.y), left = depth(c.lo.x - m.lo.x), right = depth(m.hi.x - c.hi.x)
        let sides: [(room: Rect, gap: Float, grow: (inout Rect) -> Void)] = [
            (Rect(lo: SIMD2(c.lo.x, c.lo.y - back), hi: SIMD2(c.lo.x + wx, c.lo.y)), c.lo.y - back - m.lo.y, { $0.lo.y -= back }),
            (Rect(lo: SIMD2(c.lo.x, c.hi.y), hi: SIMD2(c.lo.x + wx, c.hi.y + front)), m.hi.y - c.hi.y - front, { $0.hi.y += front }),
            (Rect(lo: SIMD2(c.lo.x - left, c.lo.y), hi: SIMD2(c.lo.x, c.lo.y + wz)), c.lo.x - left - m.lo.x, { $0.lo.x -= left }),
            (Rect(lo: SIMD2(c.hi.x, c.lo.y), hi: SIMD2(c.hi.x + right, c.lo.y + wz)), m.hi.x - c.hi.x - right, { $0.hi.x += right })]
        // (Across the core's long side first: the stair's flights run along it.)
        let order = core.stairAlongX ? [0, 1, 2, 3] : [2, 3, 0, 1]
        // (At an end only with a way past the core in front or behind: else the end's floor is reached by the
        // stair's landing alone, which they would wall off.)
        let around = m.hi.y - c.hi.y >= pass || c.lo.y - m.lo.y >= pass, across = m.hi.x - c.hi.x >= pass || c.lo.x - m.lo.x >= pass
        let toilets = order.first(where: { fits(sides[$0].gap) && ($0 < 2 ? across : around) })
        if let k = toilets {
            add(.toilets, sides[k].room, unit: -1)
            sides[k].grow(&c)
        }
        // The core block's gaps (the stair, lift and toilets needn't fill its bounds) are stores; with no room
        // beside the core for the toilets (a tower's narrow top), the biggest of them is.
        let before = rooms.count
        fillGaps(in: c)
        if toilets == nil, let i = rooms.indices.dropFirst(before).filter({ min(rooms[$0].rect.size.x, rooms[$0].rect.size.y) >= 1.2 })
            .max(by: { rooms[$0].rect.area < rooms[$1].rect.area }) {
            rooms[i].type = .toilets
        }
        // The open floor around the core: left and right of it the full depth, in front and behind it between. On
        // the ground floor the part the front door opens into is the lobby.
        let open = RoomType.openOffice
        let door = frontDoorCell(m, avoid: core.all), doorX = (door.lo + door.hi) / 2
        func kind(_ part: Rect) -> RoomType {
            ground && part.hi.y >= m.hi.y - 1e-3 && part.lo.x <= doorX && part.hi.x >= doorX ? .lobby : open
        }
        var parts: [Rect] = []
        parts.append(Rect(lo: m.lo, hi: SIMD2(c.lo.x, m.hi.y)))
        parts.append(Rect(lo: SIMD2(c.hi.x, m.lo.y), hi: m.hi))
        parts.append(Rect(lo: SIMD2(c.lo.x, c.hi.y), hi: SIMD2(c.hi.x, m.hi.y)))
        parts.append(Rect(lo: SIMD2(c.lo.x, m.lo.y), hi: SIMD2(c.hi.x, c.lo.y)))
        for part in parts where part.size.x > 0.3 && part.size.y > 0.3 {
            // Meeting rooms along the side walls of the end parts, a share of them.
            if part.size.x >= 9 && part.size.y >= 6 && !ground {
                let leftEnd = part.lo.x <= m.lo.x + 1e-3
                let depth: Float = min(4.2, part.size.x * 0.35)
                let column = leftEnd ? Rect(lo: part.lo, hi: SIMD2(part.lo.x + depth, part.hi.y))
                                     : Rect(lo: SIMD2(part.hi.x - depth, part.lo.y), hi: part.hi)
                let rest = leftEnd ? Rect(lo: SIMD2(column.hi.x, part.lo.y), hi: part.hi) : Rect(lo: part.lo, hi: SIMD2(column.lo.x, part.hi.y))
                add(open, rest, unit: -1)
                let side = lines(column, facing: SIMD2(leftEnd ? -1 : 1, 0))
                let cells = max(1, Int(column.size.y * p.cellular / 3.2))
                let cuts = cut(column.lo.y, column.hi.y, Array(repeating: column.size.y / Float(cells * 2 + 1), count: cells * 2 + 1), side.lines,
                               least: 2.4)
                for k in 0..<(cuts.count - 1) {
                    let r = Rect(lo: SIMD2(column.lo.x, cuts[k]), hi: SIMD2(column.hi.x, cuts[k + 1]))
                    let type: RoomType = k % 2 == 1 ? (k == 1 && rng.next() < 0.4 ? .kitchenette : rng.next() < 0.5 ? .meeting : .office) : open
                    add(type, r, unit: type == open ? -1 : newUnit())
                }
            } else {
                add(kind(part), part, unit: -1)
            }
        }
        if ground {
            if let lobby = rooms.first(where: { $0.type == .lobby && $0.rect.hi.y >= m.hi.y - 1e-3
                && $0.rect.lo.x <= doorX && $0.rect.hi.x >= doorX })?.id {
                doors.append(PlanDoor(kind: .glazed, a: lobby, b: -1, at: SIMD2((door.lo + door.hi) / 2, m.hi.y + t), alongX: true,
                                      width: min(2.2, door.hi - door.lo - 0.3), height: 2.6, into: lobby))
            }
        }
        for w in wings { add(open, w, unit: -1) }
    }

    /// Fills what of `block` no room covers with stores (a core's corners).
    private mutating func fillGaps(in block: Rect) {
        var xs = [block.lo.x, block.hi.x], zs = [block.lo.y, block.hi.y]
        for r in rooms where r.rect.overlaps(block) {
            xs += [r.rect.lo.x, r.rect.hi.x].filter { $0 > block.lo.x && $0 < block.hi.x }
            zs += [r.rect.lo.y, r.rect.hi.y].filter { $0 > block.lo.y && $0 < block.hi.y }
        }
        xs = Array(Set(xs)).sorted(); zs = Array(Set(zs)).sorted()
        for i in 0..<(xs.count - 1) {
            for j in 0..<(zs.count - 1) {
                let cell = Rect(lo: SIMD2(xs[i], zs[j]), hi: SIMD2(xs[i + 1], zs[j + 1]))
                let mid = cell.center
                if !rooms.contains(where: { $0.rect.contains(mid) }) && cell.size.x > 0.05 && cell.size.y > 0.05 {
                    add(.storage, cell, unit: -1)
                }
            }
        }
    }

    // MARK: - A warehouse

    private mutating func warehouse(_ m: Rect, wings: [Rect], ground: Bool) {
        let s = core.stair
        let right = core.mode == .sideRight
        var hallParts: [Rect] = []
        // In the other back corner, on the ground floor: an office and a WC.
        var office: Rect?
        if ground && m.size.x >= s.size.x + 10 {
            let w: Float = min(6, m.size.x * 0.25), d: Float = min(4.5, m.size.y * 0.4)
            office = right ? Rect(lo: m.lo, hi: SIMD2(m.lo.x + w, m.lo.y + d)) : Rect(lo: SIMD2(m.hi.x - w, m.lo.y), hi: SIMD2(m.hi.x, m.lo.y + d))
        }
        // The hall: in front of the stair (and the office) the full width, and between them along the back.
        let backTop = max(s.hi.y, office?.hi.y ?? s.hi.y)
        hallParts.append(Rect(lo: SIMD2(m.lo.x, backTop), hi: m.hi))
        let x0 = right ? (office?.hi.x ?? m.lo.x) : s.hi.x, x1 = right ? s.lo.x : (office?.lo.x ?? m.hi.x)
        hallParts.append(Rect(lo: SIMD2(x0, m.lo.y), hi: SIMD2(x1, backTop)))
        // What is left beside the stair (or the office) up to the back strip's top.
        if s.hi.y < backTop { hallParts.append(Rect(lo: SIMD2(s.lo.x, s.hi.y), hi: SIMD2(s.hi.x, backTop))) }
        if let o = office, o.hi.y < backTop { hallParts.append(Rect(lo: SIMD2(o.lo.x, o.hi.y), hi: SIMD2(o.hi.x, backTop))) }
        for part in hallParts where part.size.x > 0.3 && part.size.y > 0.3 { add(.hall, part, unit: -1) }
        if let o = office {
            let unit = newUnit()
            let wc = Rect(lo: SIMD2(right ? o.lo.x : o.hi.x - 1.8, o.lo.y), hi: SIMD2(right ? o.lo.x + 1.8 : o.hi.x, o.lo.y + 2.2))
            if let i = index(add(.office, o, unit: unit)) { splitOff(i, wc, as: .wc) }
        }
        if ground {
            // Its door: the front's middle bay.
            let door = frontDoorCell(m)
            if let h = rooms.first(where: { $0.type == .hall && $0.rect.hi.y >= m.hi.y - 1e-3 })?.id {
                doors.append(PlanDoor(kind: .entrance, a: h, b: -1, at: SIMD2((door.lo + door.hi) / 2, m.hi.y + t), alongX: true,
                                      width: min(1.3, door.hi - door.lo - 0.3), height: 2.3, into: h))
            }
        }
        for w in wings { add(.hall, w, unit: -1) }
    }

    // MARK: - Tidying and doors

    /// Rooms too thin to be rooms join a neighbour they share a whole side with; what overlaps the core is cut away.
    private mutating func cleanUp(_ usable: [Rect]) {
        // Anything over the core's rooms (a band laid out before the core was known) loses that part.
        let coreRooms = rooms.filter(\.type.isCore).map(\.rect)
        for c in coreRooms {
            for i in rooms.indices where !rooms[i].type.isCore && rooms[i].rect.overlaps(c) {
                let r = rooms[i].rect
                // Keep the biggest piece of r outside c.
                let pieces = [Rect(lo: r.lo, hi: SIMD2(r.hi.x, c.lo.y)), Rect(lo: SIMD2(r.lo.x, c.hi.y), hi: r.hi),
                              Rect(lo: r.lo, hi: SIMD2(c.lo.x, r.hi.y)), Rect(lo: SIMD2(c.hi.x, r.lo.y), hi: r.hi)]
                    .filter { $0.size.x > 0.05 && $0.size.y > 0.05 }
                rooms[i].rect = pieces.max { $0.area < $1.area } ?? Rect(lo: r.lo, hi: r.lo)
            }
        }
        rooms.removeAll { $0.rect.size.x <= 0.05 || $0.rect.size.y <= 0.05 }
        var merged = true
        while merged {
            merged = false
            for i in rooms.indices where !rooms[i].type.isCore && min(rooms[i].rect.size.x, rooms[i].rect.size.y) < 1.0 {
                // A neighbour that shares one of its whole sides: the two become one rectangle.
                let r = rooms[i].rect
                if let j = rooms.indices.first(where: { j in
                    j != i && !rooms[j].type.isCore && {
                        guard let e = SharedEdge.between(r, rooms[j].rect) else { return false }
                        let side = e.alongX ? (r.size.x, rooms[j].rect.size.x) : (r.size.y, rooms[j].rect.size.y)
                        return abs(e.length - side.0) < 1e-3 && abs(e.length - side.1) < 1e-3
                    }()
                }) {
                    rooms[j].rect = Rect(lo: simd_min(r.lo, rooms[j].rect.lo), hi: simd_max(r.hi, rooms[j].rect.hi))
                    rooms.remove(at: i)
                    merged = true
                    break
                }
            }
        }
        // Ids follow the order (doors made so far name rooms by index: remap them).
        var map: [Int: Int] = [:]
        for (k, r) in rooms.enumerated() { map[r.id] = k; rooms[k].id = k }
        doors = doors.compactMap { d in
            var d = d
            guard let a = map[d.a] else { return nil }
            d.a = a
            if d.b >= 0 { guard let b = map[d.b] else { return nil }; d.b = b }
            if d.into >= 0 { d.into = map[d.into] ?? a }
            return d
        }
    }

    /// The doors between rooms: each room's door to the room it should open from, then whatever else every room
    /// needs to be reached from the stair.
    private mutating func connect(ground: Bool) {
        // Rooms that are one: an open kitchen's living room and dining room, an office floor's parts, corridors.
        func openTo(_ a: RoomType, _ b: RoomType) -> Bool {
            let pair = Set([a, b])
            return pair == [.openOffice] || pair == [.lobby] || pair == [.hall] || pair == [.corridor] || pair == [.living, .dining]
                || pair == [.lobby, .corridor] || pair == [.openOffice, .lobby] || pair == [.landing] || pair == [.entrance]
        }
        func partners(_ t: RoomType) -> [RoomType] {
            switch t {
            case .entrance: return [.corridor, .lobby, .stairs, .landing, .entrance]
            case .living: return [.entrance, .landing, .corridor, .lobby]
            case .bedroom, .study: return [.entrance, .landing, .living]
            case .bath, .wc: return [.entrance, .landing, .bedroom, .living, .office, .backroom]
            case .kitchen: return [.entrance, .living, .dining, .landing]
            case .dining: return [.living, .kitchen, .entrance]
            case .shop: return [.backroom]
            case .backroom: return [.shop, .corridor, .lobby]
            case .office, .meeting, .kitchenette: return [.openOffice, .lobby, .corridor, .hall]
            case .toilets: return [.openOffice, .lobby, .corridor]
            case .storage: return [.corridor, .landing, .entrance, .hall, .openOffice, .lobby, .kitchen, .living]
            case .stairs: return [.corridor, .lobby, .landing, .entrance, .openOffice, .hall]
            case .lift: return [.corridor, .lobby, .openOffice, .landing, .hall]
            case .landing: return [.stairs]
            case .corridor: return [.stairs, .lobby, .corridor]
            case .lobby: return [.stairs, .corridor]
            case .openOffice: return [.stairs, .lobby, .openOffice]
            case .hall: return [.stairs]
            }
        }
        // Who may open onto whom: a home's rooms to each other, common ground to common ground, and a home to the
        // common ground through one door only (its hall, or its living room if it has none).
        var entered = Set<Int>()
        func allowed(_ a: PlanRoom, _ b: PlanRoom) -> Bool {
            if a.unit == b.unit { return true }
            if a.unit >= 0 && b.unit >= 0 { return false }
            let own = a.unit >= 0 ? a : b
            return !entered.contains(own.unit) && entryRoom(own)
        }
        func entryRoom(_ r: PlanRoom) -> Bool {
            let unitRooms = rooms.filter { $0.unit == r.unit }
            if unitRooms.contains(where: { $0.type == .entrance }) { return r.type == .entrance }
            if r.type == .shop || r.type == .backroom { return r.type == .backroom || !unitRooms.contains { $0.type == .backroom } }
            if unitRooms.contains(where: { $0.type == .living }) { return r.type == .living }
            return true
        }
        func connected(_ i: Int, _ j: Int) -> Bool { doors.contains { $0.touches(i) && $0.touches(j) } }
        func door(_ i: Int, _ j: Int, open: Bool = false) -> Bool {
            guard !connected(i, j), let e = SharedEdge.between(rooms[i].rect, rooms[j].rect) else { return false }
            if open {
                doors.append(PlanDoor(kind: .open, a: i, b: j, at: e.middle, alongX: e.alongX, width: e.length))
                return true
            }
            // Into the stair's room only by its entry landing: across its entry end, or the landing's stretch of a side.
            var from = e.from, to = e.to
            for k in [i, j] where rooms[k].type == .stairs {
                let landing = core.stairPlan.entry
                let lo = e.alongX ? landing.lo.x : landing.lo.y, hi = e.alongX ? landing.hi.x : landing.hi.y
                let across = e.alongX ? [landing.lo.y, landing.hi.y] : [landing.lo.x, landing.hi.x]
                guard across.contains(where: { abs($0 - e.at) < 1e-2 }) || (e.alongX ? (e.at > landing.lo.y && e.at < landing.hi.y)
                                                                                       : (e.at > landing.lo.x && e.at < landing.hi.x)) else { return false }
                from = max(from, lo); to = min(to, hi)
            }
            let width: Float = [rooms[i].type, rooms[j].type].contains(.bath) || [rooms[i].type, rooms[j].type].contains(.wc) ? 0.8
                : [rooms[i].type, rooms[j].type].contains(.lift) ? 1.0 : 0.9
            guard to - from >= width + 0.2 else { return false }
            // Near the end nearer the common room's middle, 0.1 from the corner; a lift's in the middle.
            let common = rooms[i].type.isCirculation ? i : j
            let c = e.alongX ? rooms[common].rect.center.x : rooms[common].rect.center.y
            let lift = rooms[i].type == .lift || rooms[j].type == .lift
            let at: Float
            if lift || to - from < width + 0.6 {
                at = (from + to) / 2
            } else {
                at = abs(from - c) < abs(to - c) ? from + 0.12 + width / 2 : to - 0.12 - width / 2
            }
            // The leaf turns into the room that isn't common ground (into a home's hall from the stair landing).
            let into = rooms[i].type.isCirculation && !rooms[j].type.isCirculation ? j : !rooms[i].type.isCirculation && rooms[j].type.isCirculation ? i
                : rooms[i].area < rooms[j].area ? i : j
            let hingeLow = abs(at - from) < abs(to - at)
            doors.append(PlanDoor(kind: lift ? .lift : .door, a: i, b: j, at: e.point(at), alongX: e.alongX, width: width,
                                  height: lift ? 2.1 : 2.05, into: into, hingeLow: hingeLow))
            return true
        }
        let n = rooms.count
        // Open walls first.
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) where rooms[i].unit == rooms[j].unit && openTo(rooms[i].type, rooms[j].type) {
                if SharedEdge.between(rooms[i].rect, rooms[j].rect, least: 0.5) != nil { _ = door(i, j, open: true) }
            }
        }
        // An open kitchen: no kitchen in the flat, its living room is it.
        // Each room's own door, by its preferences.
        let order = rooms.indices.sorted { (rooms[$0].type.isCirculation ? 1 : 0, $0) < (rooms[$1].type.isCirculation ? 1 : 0, $1) }
        for i in order where rooms[i].type != .stairs || true {
            if rooms[i].type == .lift {
                // A lift opens onto the common room it shares the longest wall with.
                let best = rooms.indices.filter { $0 != i && rooms[$0].type.isCirculation && !rooms[$0].type.isCore && rooms[$0].type != .lift }
                    .compactMap { j in SharedEdge.between(rooms[i].rect, rooms[j].rect).map { (j, $0.length) } }
                    .max { $0.1 < $1.1 }
                if let (j, _) = best { _ = door(i, j) }
                continue
            }
            var made = false
            for want in partners(rooms[i].type) where !made {
                for j in rooms.indices where j != i && rooms[j].type == want && !made {
                    guard allowed(rooms[i], rooms[j]) else { continue }
                    if door(i, j) {
                        made = true
                        if rooms[i].unit != rooms[j].unit { entered.insert(max(rooms[i].unit, rooms[j].unit)) }
                    }
                }
            }
            if rooms[i].type == .stairs {
                // The stair opens onto every common room at its landing (a house's hall).
                for j in rooms.indices where j != i && (rooms[j].type.isCirculation || rooms[j].type == .landing || rooms[j].type == .entrance)
                    && rooms[j].type != .lift && (rooms[j].unit < 0 || programme.use == .house) {
                    _ = door(i, j)
                }
            }
        }
        // Everything reached from the stair (and the street): add what is missing.
        var hopeless = Set<Int>()
        for _ in 0..<(2 * n) {
            var reached = Set<Int>()
            var queue = rooms.indices.filter { rooms[$0].type == .stairs } + doors.filter { $0.b < 0 }.map(\.a)
            while let r = queue.popLast() {
                guard reached.insert(r).inserted else { continue }
                for d in doors where d.touches(r) && d.b >= 0 { queue.append(d.other(r)) }
            }
            guard let lost = rooms.indices.first(where: { !reached.contains($0) && rooms[$0].type != .lift && !hopeless.contains($0) }) else { break }
            // A door to a reached neighbour: an allowed one if there is, any if not.
            let near = rooms.indices.filter { reached.contains($0) && rooms[$0].type != .lift && rooms[$0].type != .stairs }
            if let j = near.first(where: { allowed(rooms[lost], rooms[$0]) && SharedEdge.between(rooms[lost].rect, rooms[$0].rect, least: 1.2) != nil }),
               door(lost, j) {
                if rooms[lost].unit != rooms[j].unit { entered.insert(max(rooms[lost].unit, rooms[j].unit)) }
                continue
            }
            if let j = near.first(where: { SharedEdge.between(rooms[lost].rect, rooms[$0].rect, least: 1.2) != nil }), door(lost, j) { continue }
            // Nothing to open onto: it is part of its neighbour.
            if let j = rooms.indices.first(where: { $0 != lost && SharedEdge.between(rooms[lost].rect, rooms[$0].rect, least: 0.3) != nil
                && !rooms[$0].type.isCore }) {
                rooms[lost].type = rooms[j].type
                rooms[lost].unit = rooms[j].unit
                if !door(lost, j, open: true) { hopeless.insert(lost) }
            } else {
                hopeless.insert(lost)
            }
        }
    }
}
