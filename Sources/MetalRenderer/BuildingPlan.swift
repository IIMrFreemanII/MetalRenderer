import Foundation
import simd

/// What a room is for: what furnishes it, what its floor and walls are, what it connects to.
enum RoomType: String, Codable, CaseIterable {
    case entrance       // a home's hall, inside its door
    case corridor
    case landing        // a house's hall upstairs, round the stair
    case living, kitchen, dining, bedroom, bath, wc, study
    case office, openOffice, meeting, toilets, kitchenette
    case storage, shop, backroom, lobby
    case stairs, lift
    case hall           // a warehouse's floor

    var title: String {
        switch self {
        case .openOffice: return "Open office"
        case .wc: return "WC"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Common ground: what anyone may walk through (a home's own rooms are its unit's).
    var isCirculation: Bool { [.corridor, .lobby, .stairs, .lift, .openOffice, .hall].contains(self) }
    /// Tiled floor and walls.
    var isWet: Bool { [.bath, .wc, .toilets, .kitchen, .kitchenette].contains(self) }
    /// Lives by its windows.
    var wantsWindow: Bool { [.living, .bedroom, .kitchen, .dining, .study, .office, .openOffice, .meeting, .shop].contains(self) }
    /// Can have a balcony in front of its window.
    var hasBalcony: Bool { [.living, .bedroom, .dining, .kitchen].contains(self) }
    /// The structure's own (the editor doesn't retype or split them).
    var isCore: Bool { self == .stairs || self == .lift }
}

/// A room: a rectangle of a storey's plan, from wall middle to wall middle (an outer wall's inner face), x and z in
/// the lot's frame.
struct PlanRoom: Equatable {
    var id: Int
    var type: RoomType
    var rect: CityPlan.Rect
    /// Whose it is: a home's or an office's (-1: common ground).
    var unit: Int
    /// At night: its light is on.
    var lit = false

    var area: Float { rect.size.x * rect.size.y }
}

/// An opening between two rooms, or a room and the outside (`b` = -1): a door with a leaf, a doorway, or where two
/// rooms are one (`open`: the whole shared wall is gone).
struct PlanDoor: Equatable {
    enum Kind: String, Codable { case door, open, entrance, lift, glazed }
    var kind: Kind
    var a: Int, b: Int
    /// The opening's middle, on the wall between them (x, z), and which way that wall runs.
    var at: SIMD2<Float>
    var alongX: Bool
    var width: Float
    var height: Float = 2.1
    /// The leaf turns into this room (an id), hinged at its lower (x or z) end or its upper one.
    var into: Int = -1
    var hingeLow = true

    func touches(_ room: Int) -> Bool { a == room || b == room }
    func other(_ room: Int) -> Int { a == room ? b : a }
}

/// A dog-leg stair in its well: from the landing at its entry end, a flight up one side to a half landing at the far
/// end, and a flight back up the other side to the landing above, over the entry. `axis` is the long side's.
struct StairPlan: Equatable {
    var rect: CityPlan.Rect
    var alongX: Bool
    /// The entry end is at the low end of the long side (x or z), or the high one.
    var entryLow: Bool
    /// The first flight's side: the low side across, or the high one.
    var firstLow: Bool
    var flightWidth: Float
    static let landing: Float = 1.2
    static let run: Float = 0.27
    static let spine: Float = 0.14

    /// The landing at the entry end (the slab above isn't cut there).
    var entry: CityPlan.Rect {
        let l = StairPlan.landing
        switch (alongX, entryLow) {
        case (true, true): return CityPlan.Rect(lo: rect.lo, hi: SIMD2(rect.lo.x + l, rect.hi.y))
        case (true, false): return CityPlan.Rect(lo: SIMD2(rect.hi.x - l, rect.lo.y), hi: rect.hi)
        case (false, true): return CityPlan.Rect(lo: rect.lo, hi: SIMD2(rect.hi.x, rect.lo.y + l))
        case (false, false): return CityPlan.Rect(lo: SIMD2(rect.lo.x, rect.hi.y - l), hi: rect.hi)
        }
    }
    /// The well: the stair less its entry landing (the slab of the storey above is cut there).
    var well: CityPlan.Rect {
        let l = StairPlan.landing
        switch (alongX, entryLow) {
        case (true, true): return CityPlan.Rect(lo: SIMD2(rect.lo.x + l, rect.lo.y), hi: rect.hi)
        case (true, false): return CityPlan.Rect(lo: rect.lo, hi: SIMD2(rect.hi.x - l, rect.hi.y))
        case (false, true): return CityPlan.Rect(lo: SIMD2(rect.lo.x, rect.lo.y + l), hi: rect.hi)
        case (false, false): return CityPlan.Rect(lo: rect.lo, hi: SIMD2(rect.hi.x, rect.hi.y - l))
        }
    }
    /// Steps up `rise` (to the next floor): each flight's count, and the step's height.
    static func steps(_ rise: Float) -> (first: Int, second: Int, height: Float) {
        let n = max(2, Int((rise / 0.185).rounded(.up)))
        return ((n + 1) / 2, n / 2, rise / Float(n))
    }
    /// How long a stair for `rise` is.
    static func length(_ rise: Float) -> Float { 2 * landing + Float(steps(rise).first) * run }
}

/// One storey's plan.
struct FloorPlan: Equatable {
    var storey: Int
    var tier: Int
    /// The finished floor's height, the ceiling's (the slab above's underside), and the next floor's (or the top of
    /// the tier: the roof's).
    var floor: Float
    var ceiling: Float
    var top: Float
    /// What the rooms tile: the tier's plan inside its outer walls.
    var usable: [CityPlan.Rect]
    var rooms: [PlanRoom]
    var doors: [PlanDoor]
    var stair: StairPlan?
    /// Its flights go up from this storey (the topmost's don't).
    var climbs = true
    var lift: CityPlan.Rect?

    var height: Float { top - floor }

    func room(_ id: Int) -> PlanRoom? { rooms.first { $0.id == id } }
    func index(_ id: Int) -> Int? { rooms.firstIndex { $0.id == id } }

    /// The room at `p` (x, z), if it is inside one.
    func room(at p: SIMD2<Float>) -> PlanRoom? {
        rooms.first { p.x >= $0.rect.lo.x - 1e-3 && p.x <= $0.rect.hi.x + 1e-3 && p.y >= $0.rect.lo.y - 1e-3 && p.y <= $0.rect.hi.y + 1e-3 }
    }
}

/// A building's plan: its storeys bottom to top. Generated from its spec, style and seed (BuildingPlanner) and its
/// hand edits (PlanEdit); never saved.
struct BuildingPlan: Equatable {
    var storeys: [FloorPlan] = []
    /// The outer walls' thickness, the partitions' and the slabs'.
    var outer: Float = 0.3
    var partition: Float = 0.12
    var slab: Float = 0.25
    /// It has shops on the ground floor.
    var shops = false
    /// The edits that found nothing to change (PlanEdit), by their index.
    var orphaned: [Int] = []

    /// The room behind the outer wall at `p` (x, z: on the wall's face) on `storey`, looking in along `inward`.
    func room(behind p: SIMD2<Float>, inward: SIMD2<Float>, storey: Int) -> PlanRoom? {
        guard storeys.indices.contains(storey) else { return nil }
        return storeys[storey].room(at: p + inward * (outer + 0.2))
    }

    /// The doors through the outer walls on `storey`.
    func outsideDoors(_ storey: Int) -> [PlanDoor] {
        storeys.indices.contains(storey) ? storeys[storey].doors.filter { $0.b < 0 } : []
    }
}

// MARK: - Geometry between rooms

extension CityPlan.Rect {
    var area: Float { size.x * size.y }
    func contains(_ p: SIMD2<Float>, margin: Float = 0) -> Bool {
        p.x >= lo.x - margin && p.x <= hi.x + margin && p.y >= lo.y - margin && p.y <= hi.y + margin
    }
}

/// Where two rooms meet: the wall between them runs along x (at z = `at`) or along z (at x = `at`), from `from` to
/// `to` along it.
struct SharedEdge: Equatable {
    var alongX: Bool
    var at: Float
    var from: Float
    var to: Float
    var length: Float { to - from }
    var middle: SIMD2<Float> { alongX ? SIMD2((from + to) / 2, at) : SIMD2(at, (from + to) / 2) }
    func point(_ t: Float) -> SIMD2<Float> { alongX ? SIMD2(t, at) : SIMD2(at, t) }

    /// The edge `a` and `b` share, if they touch along more than `least`.
    static func between(_ a: CityPlan.Rect, _ b: CityPlan.Rect, least: Float = 0.05) -> SharedEdge? {
        let e: Float = 1e-3
        if abs(a.hi.y - b.lo.y) < e || abs(b.hi.y - a.lo.y) < e {
            let from = max(a.lo.x, b.lo.x), to = min(a.hi.x, b.hi.x)
            if to - from > least { return SharedEdge(alongX: true, at: abs(a.hi.y - b.lo.y) < e ? a.hi.y : a.lo.y, from: from, to: to) }
        }
        if abs(a.hi.x - b.lo.x) < e || abs(b.hi.x - a.lo.x) < e {
            let from = max(a.lo.y, b.lo.y), to = min(a.hi.y, b.hi.y)
            if to - from > least { return SharedEdge(alongX: false, at: abs(a.hi.x - b.lo.x) < e ? a.hi.x : a.lo.x, from: from, to: to) }
        }
        return nil
    }
}
