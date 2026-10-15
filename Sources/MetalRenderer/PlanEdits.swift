import Foundation
import simd

/// A hand edit of a building's floor plan (the Floor Plan window's tools), saved with its building (LotOverride).
/// It names what it changes by where it is, not by an id: replayed on the plan the generator makes (BuildingPlanner),
/// it finds its room, wall or door there again, so that it survives a change of the style, the floors or the seed
/// as long as what it changed is still there. One that finds nothing is kept, but does nothing (`BuildingPlan.orphaned`).
struct PlanEdit: Codable, Equatable {
    enum Op: String, Codable, CaseIterable {
        case split          // the room at `at` in two, by a wall through `at` (along x if `alongX`)
        case merge          // the rooms at `at` and `to`, if together they are a rectangle
        case setType        // the room at `at` is a `type`
        case moveWall       // the wall nearest `at` to `to` (its x, or its z)
        case addDoor        // a door `width` wide in the wall nearest `at`
        case removeDoor     // the door nearest `at`
        case moveDoor       // the door nearest `at`, along its wall to `to`
        case flipDoor       // the door nearest `at` turns the other way (its hinge, then the room it opens into)
    }
    var op: Op
    var storeys: StoreySel
    var at: SIMD2<Float>
    var to: SIMD2<Float>? = nil
    var alongX: Bool? = nil
    var type: RoomType? = nil
    var width: Float? = nil

    var changesRooms: Bool { [.split, .merge, .setType, .moveWall].contains(op) }
}

/// Which storeys an edit is for.
enum StoreySel: Codable, Equatable {
    case one(Int)
    case range(Int, Int)
    case all

    func contains(_ s: Int) -> Bool {
        switch self {
        case .one(let k): return s == k
        case .range(let a, let b): return s >= a && s <= b
        case .all: return true
        }
    }
}

/// Which building of which scene a single building's plan is for: its city (seed and settings) or the world's
/// block, and its lot (index, seed, size). The workshop's own building is `workshop`'s.
struct LotRef: Codable, Equatable, Hashable {
    var context: String
    var lot: Int
    var seed: UInt64
    var size: SIMD2<Float>

    static func city(_ city: CitySettings, seed: Int, lot: Int, _ l: CityPlan.Lot) -> LotRef {
        LotRef(context: "city \(seed) \(city.blocks) \(city.style.name)", lot: lot, seed: l.seed, size: l.size)
    }
    static func workshop(style: String, size: SIMD2<Float>, seed: UInt64) -> LotRef {
        LotRef(context: "workshop \(style)", lot: 0, seed: seed, size: size)
    }
    var isWorkshop: Bool { context.hasPrefix("workshop") }
    /// Said in one string (SceneSettings.interior).
    var key: String { "\(context)#\(lot)" }
    var title: String {
        isWorkshop ? "the workshop's \(context.dropFirst(9)) building" : "lot \(lot) of \(context)"
    }
}

/// A single building's own plan: its style, floors, shape, use instead of its lot's and its style's, and its hand
/// edits (Assets/Buildings/overrides.json).
struct LotOverride: Codable, Equatable {
    var ref: LotRef
    var style: String? = nil
    var floors: Int? = nil
    var shape: PlanShape? = nil
    var use: BuildingUse? = nil
    var edits: [PlanEdit] = []

    /// It holds for `ref` (the same lot, the same size: a lot that changed size is another building).
    func matches(_ ref: LotRef) -> Bool {
        self.ref.context == ref.context && self.ref.lot == ref.lot && self.ref.seed == ref.seed
            && simd_length(self.ref.size - ref.size) < 0.01
    }
}

extension BuildingCatalog {
    func override(for ref: LotRef) -> LotOverride? { overrides.first { $0.matches(ref) } }
}

extension BuildingSpec {
    /// `o` applied: its style, floors, use and edits.
    mutating func apply(_ o: LotOverride, catalog: BuildingCatalog) {
        if let id = o.style, let def = catalog.style(id: id) { self.def = def }
        if let f = o.floors { floors = max(1, f) }
        if let shape = o.shape { def.massing.shapes = [shape] }
        if let use = o.use { def.programme.use = use }
        edits = o.edits
    }
}

// MARK: - Replaying the edits

extension StoreyPlanner {
    /// The rooms of `rooms` after the edits that change rooms, on storey `s`: which edits found something to change.
    static func editRooms(_ rooms: inout [PlanRoom], _ edits: [PlanEdit], storey s: Int) -> Set<Int> {
        typealias Rect = CityPlan.Rect
        var applied = Set<Int>()
        func at(_ p: SIMD2<Float>) -> Int? { rooms.firstIndex { $0.rect.contains(p, margin: 1e-3) } }
        for (k, edit) in edits.enumerated() where edit.changesRooms && edit.storeys.contains(s) {
            switch edit.op {
            case .split:
                guard let i = at(edit.at), !rooms[i].type.isCore else { continue }
                let r = rooms[i].rect, alongX = edit.alongX ?? (r.size.y > r.size.x)
                let v = alongX ? edit.at.y : edit.at.x
                let lo = alongX ? r.lo.y : r.lo.x, hi = alongX ? r.hi.y : r.hi.x
                guard v - lo >= 0.9, hi - v >= 0.9 else { continue }
                var other = rooms[i]
                other.id = (rooms.map(\.id).max() ?? 0) + 1
                if alongX {
                    rooms[i].rect = Rect(lo: r.lo, hi: SIMD2(r.hi.x, v))
                    other.rect = Rect(lo: SIMD2(r.lo.x, v), hi: r.hi)
                } else {
                    rooms[i].rect = Rect(lo: r.lo, hi: SIMD2(v, r.hi.y))
                    other.rect = Rect(lo: SIMD2(v, r.lo.y), hi: r.hi)
                }
                rooms.append(other)
                applied.insert(k)
            case .merge:
                guard let to = edit.to, let i = at(edit.at), let j = at(to), i != j,
                      !rooms[i].type.isCore, !rooms[j].type.isCore else { continue }
                let a = rooms[i].rect, b = rooms[j].rect
                let union = Rect(lo: simd_min(a.lo, b.lo), hi: simd_max(a.hi, b.hi))
                guard abs(union.area - a.area - b.area) < 1e-3 else { continue }
                rooms[i].rect = union
                rooms.remove(at: j)
                applied.insert(k)
            case .setType:
                guard let type = edit.type, !type.isCore, let i = at(edit.at), !rooms[i].type.isCore else { continue }
                rooms[i].type = type
                applied.insert(k)
            case .moveWall:
                guard let to = edit.to, moveWall(&rooms, near: edit.at, to: to) else { continue }
                applied.insert(k)
            default:
                break
            }
        }
        // Ids are the rooms' indices again.
        for i in rooms.indices { rooms[i].id = i }
        return applied
    }

    /// Moves the wall nearest `p` (the straight run of shared edges through it, from one cross wall to the next) to
    /// `to`'s x (a wall along z) or z: every room on either side follows, if each stays 0.9 or more across.
    private static func moveWall(_ rooms: inout [PlanRoom], near p: SIMD2<Float>, to: SIMD2<Float>) -> Bool {
        var best: (SharedEdge, Float)?
        for i in rooms.indices {
            for j in (i + 1)..<rooms.count {
                guard let e = SharedEdge.between(rooms[i].rect, rooms[j].rect) else { continue }
                let along = e.alongX ? p.x : p.y, across = e.alongX ? p.y : p.x
                guard along >= e.from - 0.2, along <= e.to + 0.2 else { continue }
                let d = abs(across - e.at)
                if d < 0.6 && d < (best?.1 ?? .infinity) { best = (e, d) }
            }
        }
        guard let (edge, _) = best else { return false }
        let alongX = edge.alongX, line = edge.at, v = alongX ? to.y : to.x
        // The rooms with a side on the line, grown from the edge along it while they touch: below and above it.
        func side(_ r: PlanRoom, above: Bool) -> (Float, Float)? {
            let s = alongX ? (above ? r.rect.lo.y : r.rect.hi.y) : (above ? r.rect.lo.x : r.rect.hi.x)
            guard abs(s - line) < 1e-3 else { return nil }
            return alongX ? (r.rect.lo.x, r.rect.hi.x) : (r.rect.lo.y, r.rect.hi.y)
        }
        var lo = edge.from, hi = edge.to
        var below: Set<Int> = [], above: Set<Int> = []
        var grew = true
        while grew {
            grew = false
            for (i, r) in rooms.enumerated() {
                for up in [false, true] {
                    guard let (a, b) = side(r, above: up), b > lo + 1e-3, a < hi - 1e-3 else { continue }
                    if up ? above.insert(i).inserted : below.insert(i).inserted {
                        if a < lo - 1e-3 || b > hi + 1e-3 { lo = min(lo, a); hi = max(hi, b); grew = true }
                    }
                }
            }
        }
        // Both sides must span the same run (otherwise moving it would open a gap or an overlap).
        func span(_ set: Set<Int>, above: Bool) -> (Float, Float) {
            set.compactMap { side(rooms[$0], above: above) }.reduce((Float.infinity, -Float.infinity)) { (min($0.0, $1.0), max($0.1, $1.1)) }
        }
        let a = span(below, above: false), b = span(above, above: true)
        guard abs(a.0 - b.0) < 1e-3, abs(a.1 - b.1) < 1e-3, !below.isEmpty, !above.isEmpty else { return false }
        guard !(below.union(above)).contains(where: { rooms[$0].type.isCore }) else { return false }
        for i in below {
            let r = rooms[i].rect
            guard v - (alongX ? r.lo.y : r.lo.x) >= 0.9 else { return false }
        }
        for i in above {
            let r = rooms[i].rect
            guard (alongX ? r.hi.y : r.hi.x) - v >= 0.9 else { return false }
        }
        for i in below { if alongX { rooms[i].rect.hi.y = v } else { rooms[i].rect.hi.x = v } }
        for i in above { if alongX { rooms[i].rect.lo.y = v } else { rooms[i].rect.lo.x = v } }
        return true
    }

    /// The doors of `doors` after the edits that change doors, on storey `s` of `rooms`.
    static func editDoors(_ doors: inout [PlanDoor], rooms: [PlanRoom], _ edits: [PlanEdit], storey s: Int) -> Set<Int> {
        var applied = Set<Int>()
        func nearest(_ p: SIMD2<Float>) -> Int? {
            doors.indices.filter { doors[$0].b >= 0 && doors[$0].kind != .open }.min { distance(doors[$0].at, p) < distance(doors[$1].at, p) }
                .flatMap { distance(doors[$0].at, p) < 0.9 ? $0 : nil }
        }
        for (k, edit) in edits.enumerated() where !edit.changesRooms && edit.storeys.contains(s) {
            switch edit.op {
            case .addDoor:
                // The wall nearest the point: the edge two rooms share, the door's middle on it.
                var best: (Int, Int, SharedEdge, Float)?
                for i in rooms.indices {
                    for j in (i + 1)..<rooms.count {
                        guard let e = SharedEdge.between(rooms[i].rect, rooms[j].rect) else { continue }
                        let along = e.alongX ? edit.at.x : edit.at.y, across = e.alongX ? edit.at.y : edit.at.x
                        guard along > e.from, along < e.to else { continue }
                        let d = abs(across - e.at)
                        if d < 0.5 && d < (best?.3 ?? .infinity) { best = (i, j, e, d) }
                    }
                }
                guard let (i, j, e, _) = best, !rooms[i].type.isCore || !rooms[j].type.isCore else { continue }
                let width = min(edit.width ?? 0.9, e.length - 0.2)
                guard width >= 0.6 else { continue }
                let along = min(max(e.alongX ? edit.at.x : edit.at.y, e.from + 0.1 + width / 2), e.to - 0.1 - width / 2)
                guard !doors.contains(where: { $0.touches(i) && $0.touches(j) && $0.kind != .open
                    && abs((e.alongX ? $0.at.x : $0.at.y) - along) < ($0.width + width) / 2 }) else { continue }
                doors.append(PlanDoor(kind: .door, a: i, b: j, at: e.point(along), alongX: e.alongX, width: width,
                                      into: rooms[i].type.isCirculation ? j : i))
                applied.insert(k)
            case .removeDoor:
                guard let d = nearest(edit.at) else { continue }
                doors.remove(at: d)
                applied.insert(k)
            case .moveDoor:
                guard let to = edit.to, let d = nearest(edit.at), let e = SharedEdge.between(rooms[doors[d].a].rect, rooms[doors[d].b].rect) else { continue }
                let w = doors[d].width
                let along = min(max(e.alongX ? to.x : to.y, e.from + 0.1 + w / 2), e.to - 0.1 - w / 2)
                doors[d].at = e.point(along)
                applied.insert(k)
            case .flipDoor:
                guard let d = nearest(edit.at) else { continue }
                // Hinge low, hinge high, then the same into the other room.
                if doors[d].hingeLow { doors[d].hingeLow = false } else {
                    doors[d].hingeLow = true
                    doors[d].into = doors[d].other(doors[d].into)
                }
                applied.insert(k)
            default:
                break
            }
        }
        return applied
    }
}
