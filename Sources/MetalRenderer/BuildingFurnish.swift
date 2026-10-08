import Foundation
import simd

extension Interior {
    /// A ceiling light (a rect light facing down), in the lot's frame: on at night if its room's light is, and
    /// switched with its room (`switchID`).
    struct Light {
        var position: SIMD3<Float>
        var size: SIMD2<Float>
        var color: SIMD3<Float>
        var storey: Int
        var room: Int
        var on: Bool
        var switchID: Int
    }
    /// A light switch by a room's door: where its plate is (the lot's frame) and which way it faces.
    struct Switch {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var storey: Int
        var room: Int
    }
    /// A loose piece of furniture (a chair, a box): its own instance, in the storey's frame (its floor at y = 0).
    struct Prop {
        var item: FurnitureItem
        var frame: float4x4
        var storey: Int
        /// Its parts' materials, by role.
        var materials: [SurfaceMaterial]
    }
}

/// The roles' materials for one building (its style's palette) and, for the fabrics, one room.
struct FurnishPalette {
    let wood: SurfaceMaterial, woodDark: SurfaceMaterial
    let fabrics: [SIMD3<Float>]
    let books: [SurfaceMaterial]
    static let linen = SurfaceMaterial(color: [0.88, 0.87, 0.84])
    static let metal = SurfaceMaterial(color: [0.32, 0.33, 0.35], roughness: 0.45, metallic: 0.8, specular: true)
    static let chrome = SurfaceMaterial(color: [0.75, 0.76, 0.78], roughness: 0.2, metallic: 1, specular: true)
    static let ceramic = SurfaceMaterial(color: [0.9, 0.9, 0.88], roughness: 0.15, specular: true)
    static let dark = SurfaceMaterial(color: [0.05, 0.05, 0.055], roughness: 0.4, specular: true)
    static let screen = SurfaceMaterial(color: [0.015, 0.016, 0.02], roughness: 0.1, specular: true)
    static let stone = SurfaceMaterial(color: [0.62, 0.6, 0.57], surface: .concrete, roughness: 0.3, specular: true)
    static let leaf = SurfaceMaterial(color: [0.1, 0.26, 0.08], roughness: 0.6, specular: true)
    static let pot = SurfaceMaterial(color: [0.55, 0.28, 0.17])
    static let soil = SurfaceMaterial(color: [0.1, 0.07, 0.05])
    static let carton = SurfaceMaterial(color: [0.6, 0.45, 0.28])
    static let glass = SurfaceMaterial(color: [0.9, 0.94, 0.94], glass: true)
    static let shade = SurfaceMaterial(color: [0.92, 0.88, 0.78])
    static let paper = SurfaceMaterial(color: [0.94, 0.94, 0.92])

    init(_ finishes: InteriorBuilder.Finishes, style: BuildingStyle) {
        wood = SurfaceMaterial(color: finishes.wood, roughness: 0.5, specular: true)
        woodDark = SurfaceMaterial(color: finishes.wood * 0.55, roughness: 0.5, specular: true)
        fabrics = style.def.interior.fabrics.isEmpty ? [[0.4, 0.4, 0.42]] : style.def.interior.fabrics
        books = [[0.5, 0.12, 0.1], [0.12, 0.22, 0.42], [0.15, 0.32, 0.2], [0.72, 0.62, 0.42]].map { SurfaceMaterial(color: $0) }
    }

    /// Role `role`'s material in a room whose fabric is `fabric`.
    func material(_ role: FurnitureItem.Role, fabric: Int) -> SurfaceMaterial {
        let f = fabrics[fabric % fabrics.count]
        switch role {
        case .wood: return wood
        case .woodDark: return woodDark
        case .fabric: return SurfaceMaterial(color: f)
        case .cushion: return SurfaceMaterial(color: f * 1.15)
        case .rug: return SurfaceMaterial(color: fabrics[(fabric + 2) % fabrics.count] * 0.8)
        case .linen: return FurnishPalette.linen
        case .metal: return FurnishPalette.metal
        case .chrome: return FurnishPalette.chrome
        case .ceramic: return FurnishPalette.ceramic
        case .dark: return FurnishPalette.dark
        case .screen: return FurnishPalette.screen
        case .stone: return FurnishPalette.stone
        case .book0, .book1, .book2, .book3: return books[role.rawValue - FurnitureItem.Role.book0.rawValue]
        case .leaf: return FurnishPalette.leaf
        case .pot: return FurnishPalette.pot
        case .soil: return FurnishPalette.soil
        case .carton: return FurnishPalette.carton
        case .glass: return FurnishPalette.glass
        case .shade: return FurnishPalette.shade
        case .paper: return FurnishPalette.paper
        }
    }
}

/// Furnishes one storey's rooms (Interior Maker): each room's pieces by its type, against its walls clear of its doors'
/// swing and (the tall ones) of its windows, or in its middle; its ceiling lights and the switch by its door.
struct Furnisher {
    typealias Rect = CityPlan.Rect
    let floor: FloorPlan
    let plan: BuildingPlan
    let openings: [Building.WallOpening]
    let palette: FurnishPalette
    let clutter: Float
    let plants: Float
    let light: (color: SIMD3<Float>, power: Float)
    var rng: SplitMix64

    /// What is placed: static pieces (into the storey's mesh), loose ones (props), lights and switches.
    var placed: [(item: FurnitureItem, frame: float4x4, fabric: Int)] = []
    var props: [(item: FurnitureItem, frame: float4x4, fabric: Int)] = []
    var lights: [(position: SIMD3<Float>, size: SIMD2<Float>, room: Int)] = []
    var switches: [(position: SIMD3<Float>, normal: SIMD3<Float>, room: Int)] = []

    // The room being furnished.
    private var room = PlanRoom(id: 0, type: .storage, rect: Rect(lo: .zero, hi: .zero), unit: 0)
    private var inner = Rect(lo: .zero, hi: .zero)
    private var taken: [Rect] = []
    private var keepOut: [Rect] = []
    private var sides: [Side] = []
    private var fabric = 0

    /// One wall of the room, from inside: from `origin` along `u` for `length`, `n` into the room.
    struct Side {
        var origin: SIMD2<Float>
        var u: SIMD2<Float>
        var n: SIMD2<Float>
        var length: Float
        /// Where along it nothing stands (doors), and its windows (where along, and their sill over the floor).
        var blocked: [(Float, Float)]
        var windows: [(Float, Float, sill: Float)]
        var outer: Bool
    }

    init(floor: FloorPlan, plan: BuildingPlan, openings: [Building.WallOpening], palette: FurnishPalette, style: BuildingStyle, seed: UInt64) {
        self.floor = floor
        self.plan = plan
        self.openings = openings
        self.palette = palette
        clutter = style.def.interior.clutter
        plants = style.def.interior.plants
        light = (style.def.interior.lightColor, style.def.interior.lightPower)
        rng = SplitMix64(seed: seed)
    }

    mutating func furnishAll() {
        for r in floor.rooms where !r.type.isCore {
            begin(r)
            furnish()
            ceilingLights()
        }
        for r in floor.rooms where r.type == .stairs {
            // One light over the landing.
            let e = floor.stair?.entry ?? r.rect
            lights.append((SIMD3(e.center.x, floor.ceiling - floor.floor - 0.02, e.center.y), SIMD2(0.4, 0.4), r.id))
        }
    }

    // MARK: - The room

    private mutating func begin(_ r: PlanRoom) {
        room = r
        fabric = Int(rng.nextUInt64() % 16)
        taken = []
        keepOut = []
        let tp = plan.partition / 2 + 0.01
        func outerSide(_ coordinate: Float, alongX: Bool, _ dir: Float) -> Bool {
            // On the usable plan's edge, with nothing of it beyond: an outer wall.
            let p = alongX ? SIMD2(r.rect.center.x, coordinate + dir * 0.05) : SIMD2(coordinate + dir * 0.05, r.rect.center.y)
            return !floor.usable.contains { $0.contains(p) }
        }
        let outs = [outerSide(r.rect.hi.y, alongX: true, 1), outerSide(r.rect.hi.x, alongX: false, 1),
                    outerSide(r.rect.lo.y, alongX: true, -1), outerSide(r.rect.lo.x, alongX: false, -1)]
        inner = Rect(lo: r.rect.lo + SIMD2(outs[3] ? 0.01 : tp, outs[2] ? 0.01 : tp), hi: r.rect.hi - SIMD2(outs[1] ? 0.01 : tp, outs[0] ? 0.01 : tp))
        let i = inner
        // front (+z) wall seen from inside: along -x; right (+x): along +z; back (-z): along +x; left (-x): along -z.
        let frames: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, Float, Bool)] = [
            (SIMD2(i.hi.x, i.hi.y), SIMD2(-1, 0), SIMD2(0, -1), i.size.x, outs[0]),
            (SIMD2(i.hi.x, i.lo.y), SIMD2(0, 1), SIMD2(-1, 0), i.size.y, outs[1]),
            (SIMD2(i.lo.x, i.lo.y), SIMD2(1, 0), SIMD2(0, 1), i.size.x, outs[2]),
            (SIMD2(i.lo.x, i.hi.y), SIMD2(0, -1), SIMD2(1, 0), i.size.y, outs[3])]
        sides = frames.map { origin, u, n, length, outer in Side(origin: origin, u: u, n: n, length: length, blocked: [], windows: [], outer: outer) }
        // Doors: where they are along their wall, and the swing of those that open into the room.
        for d in floor.doors where d.touches(r.id) && d.kind != .open {
            for k in sides.indices {
                let s = sides[k]
                let across = dot(d.at - s.origin, s.n)
                guard abs(across) < plan.outer + 0.3 else { continue }
                let along = dot(d.at - s.origin, s.u)
                guard along > -d.width && along < s.length + d.width else { continue }
                sides[k].blocked.append((along - d.width / 2 - 0.12, along + d.width / 2 + 0.12))
                let swing = d.into == r.id || d.b < 0 ? d.width + 0.15 : 0.5
                keepOut.append(rect(s, along - d.width / 2 - 0.1, along + d.width / 2 + 0.1, 0, swing))
            }
        }
        // Windows on its outer walls.
        for o in openings {
            for k in sides.indices where sides[k].outer {
                let s = sides[k]
                guard dot(o.normal, -s.n) > 0.5, abs(dot((o.a + o.c) / 2 - s.origin, s.n) + plan.outer) < 0.1 else { continue }
                let a = dot(o.a - s.origin, s.u), c = dot(o.c - s.origin, s.u)
                let lo = min(a, c), hi = max(a, c)
                guard hi > 0, lo < s.length else { continue }
                let sill = o.y0 - floor.floor
                sides[k].windows.append((lo, hi, sill))
                // A door to a balcony, or a shop's front, opens onto the floor: nothing stands in front of it.
                if sill < 0.3 { sides[k].blocked.append((lo, hi)) }
            }
        }
    }

    /// The rectangle (x, z) of side `s` from `a` to `b` along it and `n0` to `n1` out from it.
    private func rect(_ s: Side, _ a: Float, _ b: Float, _ n0: Float, _ n1: Float) -> Rect {
        let p = [s.origin + s.u * a + s.n * n0, s.origin + s.u * b + s.n * n1]
        return Rect(lo: simd_min(p[0], p[1]), hi: simd_max(p[0], p[1]))
    }

    /// The frame of a piece standing against side `s` at `a` along it (its own x along the wall, z into the room).
    private func frame(_ s: Side, _ a: Float, out: Float = 0) -> float4x4 {
        let o = s.origin + s.u * a + s.n * out
        return float4x4(columns: (SIMD4(s.u.x, 0, s.u.y, 0), SIMD4(0, 1, 0, 0), SIMD4(s.n.x, 0, s.n.y, 0), SIMD4(o.x, 0, o.y, 1)))
    }

    private func free(_ r: Rect, access: Rect? = nil) -> Bool {
        guard inner.contains(r, tolerance: 0.02) else { return false }
        if taken.contains(where: { $0.overlaps(r, tolerance: 0.01) }) || keepOut.contains(where: { $0.overlaps(r, tolerance: 0.01) }) { return false }
        if let access, taken.contains(where: { $0.overlaps(access, tolerance: 0.01) }) { return false }
        return true
    }

    enum Prefer { case middle, corner, window, away, any }

    /// Puts `item` against a wall: where it fits (clear of doors, of windows if it is taller than their sill, of
    /// everything placed), with `access` free in front of it; the best place by `prefer`. Returns its side and place.
    @discardableResult
    private mutating func againstWall(_ item: FurnitureItem, prefer: Prefer, access: Float = 0.6, loose: Bool = false,
                                      only: [Int]? = nil) -> (side: Int, at: Float)? {
        var best: (score: Float, side: Int, at: Float)?
        let w = item.size.x, d = item.size.z, h = item.size.y
        for (k, s) in sides.enumerated() where only?.contains(k) ?? true && s.length >= w {
            var a: Float = 0
            while a + w <= s.length + 1e-3 {
                defer { a += 0.1 }
                if s.blocked.contains(where: { $0.0 < a + w && $0.1 > a }) { continue }
                if s.windows.contains(where: { $0.0 < a + w && $0.1 > a && $0.sill < h + 0.03 }) { continue }
                let r = rect(s, a, a + w, 0, d)
                guard free(r, access: access > 0 ? rect(s, a, a + w, d, d + access) : nil) else { continue }
                var score = rng.next() * 0.3
                let mid = a + w / 2
                switch prefer {
                case .middle: score -= abs(mid - s.length / 2) / max(s.length, 1) * 2 - s.length / 10
                case .corner: score -= min(a, s.length - a - w)
                case .window: score += s.windows.contains { $0.0 < a + w && $0.1 > a } ? 2 : 0
                case .away: score += s.blocked.isEmpty ? 1 : 0
                case .any: break
                }
                if score > (best?.score ?? -.infinity) { best = (score, k, a) }
            }
        }
        guard let (_, k, a) = best else { return nil }
        let s = sides[k]
        taken.append(rect(s, a, a + w, 0, d))
        if loose { props.append((item, frame(s, a), fabric)) } else { placed.append((item, frame(s, a), fabric)) }
        return (k, a)
    }

    /// Puts `item` in the room's middle (or as near it as it fits), turned to face along `alongX`.
    @discardableResult
    private mutating func inMiddle(_ item: FurnitureItem, around: Float = 0.6, at want: SIMD2<Float>? = nil) -> Rect? {
        let w = item.size.x, d = item.size.z
        let target = want ?? inner.center
        var best: (Float, Rect)?
        for dx in stride(from: -2.0 as Float, through: 2.0, by: 0.25) {
            for dz in stride(from: -2.0 as Float, through: 2.0, by: 0.25) {
                let c = target + SIMD2(dx, dz)
                let r = Rect(lo: c - SIMD2(w, d) / 2, hi: c + SIMD2(w, d) / 2)
                let around = Rect(lo: r.lo - SIMD2(around, around), hi: r.hi + SIMD2(around, around))
                guard free(r, access: around), inner.contains(around, tolerance: 0.3) || around.area < 1 else { continue }
                let score = -(dx * dx + dz * dz)
                if score > (best?.0 ?? -.infinity) { best = (score, r) }
            }
        }
        guard let (_, r) = best else { return nil }
        taken.append(r)
        placed.append((item, float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(r.lo.x, 0, r.lo.y, 1))), fabric))
        return r
    }

    private mutating func make(_ kind: FurnitureItem.Kind, _ w: Float, _ d: Float) -> FurnitureItem {
        FurnitureItem.make(kind, width: w, depth: d, rng: &rng, clutter: clutter)
    }

    /// Chairs round a table at `r`: on its long sides, a chair every 0.6 m, facing it; loose.
    private mutating func chairs(around r: Rect, office: Bool = false) {
        let alongX = r.size.x >= r.size.y
        let length = alongX ? r.size.x : r.size.y
        let count = max(1, Int((length - 0.2) / 0.62))
        for side: Float in [-1, 1] {
            for k in 0..<count {
                let t = (Float(k) + 0.5) / Float(count) * length
                let item = make(office ? .officeChair : .chair, 0.46, 0.46)
                // The chair's back toward the room, its front to the table.
                let u: SIMD2<Float> = alongX ? SIMD2(-side, 0) : SIMD2(0, side)
                let n: SIMD2<Float> = alongX ? SIMD2(0, -side) : SIMD2(side, 0)
                let edge: SIMD2<Float> = alongX ? SIMD2(r.lo.x + t, side > 0 ? r.hi.y + 0.62 : r.lo.y - 0.62)
                                                : SIMD2(side > 0 ? r.lo.x - 0.62 : r.hi.x + 0.62, r.lo.y + t)
                let origin = edge - u * 0.23
                let foot = Rect(lo: simd_min(origin, origin + u * 0.46 + n * 0.46), hi: simd_max(origin, origin + u * 0.46 + n * 0.46))
                guard free(foot) else { continue }
                taken.append(foot)
                props.append((item, float4x4(columns: (SIMD4(u.x, 0, u.y, 0), SIMD4(0, 1, 0, 0), SIMD4(n.x, 0, n.y, 0), SIMD4(origin.x, 0, origin.y, 1))), fabric))
            }
        }
    }

    // MARK: - By room type

    private mutating func furnish() {
        let area = inner.area
        let longest = sides.indices.max { sides[$0].length < sides[$1].length } ?? 0
        func decorate() {
            if rng.next() < plants { againstWall(make(rng.next() < 0.5 ? .tallPlant : .plant, 0.45, 0.45), prefer: .corner, access: 0) }
            for _ in 0..<Int(clutter * 2 + rng.next()) {
                // Pictures: against a wall above whatever is under them (they take no floor).
                let inside = sides.indices.filter { !sides[$0].outer && sides[$0].length > 1.2 }
                guard !inside.isEmpty else { break }
                let k = inside[rng.int(inside.count)]
                let w = 0.4 + rng.next() * 0.5, s = sides[k]
                let a = rng.next() * (s.length - w)
                guard !s.blocked.contains(where: { $0.0 < a + w && $0.1 > a }) else { continue }
                placed.append((make(.frame, w, 0.03), frame(s, a), fabric))
            }
        }
        switch room.type {
        case .living:
            if let sofa = againstWall(make(.sofa, min(2.3, max(1.6, sides[longest].length * 0.45)), 0.92), prefer: .middle, access: 1.3) {
                let s = sides[sofa.side]
                // A coffee table in front of it, a rug under both, the television facing it.
                let w = make(.coffeeTable, 1.1, 0.6)
                let at = s.origin + s.u * (sofa.at + 0.6) + s.n * (0.92 + 0.45)
                let table = rect(s, sofa.at + 0.6, sofa.at + 1.7, 1.37, 1.97)
                if free(table) {
                    taken.append(table)
                    placed.append((w, frame(s, sofa.at + 0.6, out: 1.37), fabric))
                    _ = at
                }
                placed.append((make(.rug, 2.2, 2.0), frame(s, sofa.at, out: 0.6), fabric))
                let opposite = (sofa.side + 2) % 4
                againstWall(make(.tvUnit, 1.6, 0.45), prefer: .middle, access: 0.8, only: [opposite])
            }
            if rng.next() < 0.6 { againstWall(make(.armchair, 0.85, 0.85), prefer: .corner, access: 0.5) }
            againstWall(make(.bookcase, 0.9, 0.34), prefer: .away, access: 0.7)
            // A flat without a kitchen of its own cooks here.
            if !floor.rooms.contains(where: { $0.unit == room.unit && $0.type == .kitchen }) && room.unit >= 0 {
                if againstWall(make(.kitchen, min(3.0, max(1.8, sides[longest].length * 0.5)), 0.62), prefer: .corner, access: 1.0) != nil {
                    againstWall(make(.fridge, 0.62, 0.65), prefer: .corner, access: 0.9)
                }
                if let t = inMiddle(make(.diningTable, 1.4, 0.85), around: 0.75) { chairs(around: t) }
            }
            decorate()
        case .kitchen, .kitchenette:
            let run = min(3.6, max(1.6, sides[longest].length - 0.8))
            againstWall(make(.kitchen, room.type == .kitchenette ? min(run, 2.2) : run, 0.62), prefer: .corner, access: 1.0, only: [longest])
                ?? againstWall(make(.kitchen, 1.6, 0.62), prefer: .corner, access: 0.9)
            againstWall(make(.fridge, 0.62, 0.65), prefer: .corner, access: 0.9)
            if area > 7.5, let t = inMiddle(make(.diningTable, min(1.4, inner.size.x - 1.6), 0.8), around: 0.7) { chairs(around: t) }
            decorate()
        case .dining:
            if let t = inMiddle(make(.diningTable, min(2.0, max(1.2, inner.size.x - 1.6)), 0.9), around: 0.75) { chairs(around: t) }
            againstWall(make(.bookcase, 1.2, 0.4), prefer: .away, access: 0.6)
            decorate()
        case .bedroom:
            let double = min(inner.size.x, inner.size.y) >= 2.6
            let bed = make(double ? .bed : .single, double ? 1.6 : 0.95, 2.05)
            if let b = againstWall(bed, prefer: .middle, access: 0.55) {
                let s = sides[b.side]
                for (a, ok) in [(b.at - 0.48, b.at - 0.48 >= 0), (b.at + bed.size.x + 0.03, b.at + bed.size.x + 0.48 <= s.length)] where ok {
                    let r = rect(s, a, a + 0.45, 0, 0.4)
                    if free(r) { taken.append(r); placed.append((make(.nightstand, 0.45, 0.4), frame(s, a), fabric)) }
                }
            }
            againstWall(make(.wardrobe, min(1.8, max(1.0, sides[longest].length * 0.35)), 0.6), prefer: .corner, access: 0.7)
            if area > 11 && rng.next() < 0.5, againstWall(make(.desk, 1.2, 0.6), prefer: .window, access: 0.7) != nil {}
            decorate()
        case .study, .office:
            if let desk = againstWall(make(.desk, 1.4, 0.7), prefer: .window, access: 0.9) {
                let s = sides[desk.side]
                let c = s.origin + s.u * (desk.at + 0.47) + s.n * 0.75
                let n = -s.n, u = SIMD2(-n.y, n.x)
                props.append((make(.officeChair, 0.6, 0.6), float4x4(columns: (SIMD4(u.x, 0, u.y, 0), SIMD4(0, 1, 0, 0), SIMD4(n.x, 0, n.y, 0),
                                                                                  SIMD4(c.x - u.x * 0.0, 0, c.y, 1))), fabric))
            }
            againstWall(make(.bookcase, 0.9, 0.34), prefer: .away, access: 0.7)
            decorate()
        case .bath:
            let long = sides.indices.filter { sides[$0].length >= 1.72 }
            if !long.isEmpty, againstWall(make(.bath, 1.7, 0.75), prefer: .corner, access: 0.5, only: long) != nil {} else {
                againstWall(make(.shower, 0.9, 0.9), prefer: .corner, access: 0.5)
            }
            againstWall(make(.wc, 0.45, 0.68), prefer: .corner, access: 0.5)
            againstWall(make(.basin, 0.6, 0.45), prefer: .any, access: 0.55)
        case .wc:
            againstWall(make(.wc, 0.45, 0.68), prefer: .middle, access: 0.5)
            againstWall(make(.basin, 0.5, 0.4), prefer: .any, access: 0.4)
        case .toilets:
            let s = sides[longest]
            let n = max(1, Int(s.length / 0.95))
            for _ in 0..<min(n, 5) { againstWall(make(.cubicle, 0.92, 1.45), prefer: .corner, access: 0.3, only: [longest]) }
            for _ in 0..<2 { againstWall(make(.basin, 0.6, 0.45), prefer: .any, access: 0.5, only: [(longest + 2) % 4]) }
        case .openOffice:
            // Clusters of four desks on a grid, a gangway between them.
            let cw: Float = 3.0, cd: Float = 1.6, gx: Float = 1.6, gz: Float = 1.6
            let nx = Int((inner.size.x - 1) / (cw + gx)), nz = Int((inner.size.y - 1) / (cd + gz))
            if nx > 0 && nz > 0 {
                let x0 = inner.center.x - (Float(nx) * (cw + gx) - gx) / 2, z0 = inner.center.y - (Float(nz) * (cd + gz) - gz) / 2
                for i in 0..<nx {
                    for j in 0..<nz {
                        let c = SIMD2(x0 + Float(i) * (cw + gx) + cw / 2, z0 + Float(j) * (cd + gz) + cd / 2)
                        if let r = inMiddle(make(.deskCluster, cw, cd), around: 0.7, at: c), distance(r.center, c) < 0.3 {
                            chairs(around: r, office: true)
                        }
                    }
                }
            }
            for _ in 0..<2 where rng.next() < plants { againstWall(make(.tallPlant, 0.5, 0.5), prefer: .corner, access: 0) }
        case .meeting:
            if let t = inMiddle(make(.meetingTable, min(3.2, max(1.4, inner.size.x - 1.8)), min(1.2, max(0.9, inner.size.y - 1.8))), around: 0.8) {
                chairs(around: t, office: true)
            }
            decorate()
        case .lobby:
            againstWall(make(.bench, 1.6, 0.45), prefer: .middle, access: 0.8)
            if inner.area > 30 { againstWall(make(.reception, 2.4, 0.8), prefer: .away, access: 1.2) }
            for _ in 0..<2 where rng.next() < max(plants, 0.5) { againstWall(make(.tallPlant, 0.5, 0.5), prefer: .corner, access: 0) }
        case .shop:
            againstWall(make(.counter, min(2.4, inner.size.x * 0.5), 0.7), prefer: .away, access: 1.0)
            for _ in 0..<3 { againstWall(make(.rack, min(2.0, sides[longest].length * 0.4), 0.45), prefer: .any, access: 0.9) }
            if inner.area > 18 { inMiddle(make(.diningTable, 1.4, 0.8), around: 0.9) }
            decorate()
        case .backroom, .storage:
            for _ in 0..<2 { againstWall(make(.rack, min(1.8, sides[longest].length * 0.6), 0.45), prefer: .corner, access: 0.7) }
            for _ in 0..<Int(1 + clutter * 3) { againstWall(make(.boxes, 0.6, 0.6), prefer: .corner, access: 0, loose: true) }
        case .hall:
            // Deep racks along the walls, pallets on the floor, loose boxes.
            for k in sides.indices where sides[k].length > 4 {
                for _ in 0..<Int(sides[k].length / 3.2) { againstWall(make(.rack, 2.7, 1.0), prefer: .any, access: 2.5, only: [k]) }
            }
            for _ in 0..<Int(area / 30) { inMiddle(make(.pallet, 1.2, 0.8), around: 1.4, at: inner.center + SIMD2(rng.next() - 0.5, rng.next() - 0.5) * inner.size * 0.6) }
            for _ in 0..<Int(area / 60 + 1) { againstWall(make(.boxes, 0.6, 0.6), prefer: .any, access: 0, loose: true) }
        case .entrance:
            if inner.area > 2.5 { againstWall(make(.coatRack, 0.8, 0.25), prefer: .any, access: 0.6) }
            if inner.area > 4 { againstWall(make(.nightstand, 0.8, 0.35), prefer: .away, access: 0.7) }
        case .corridor, .landing:
            if rng.next() < plants * 0.5 { againstWall(make(.plant, 0.4, 0.4), prefer: .corner, access: 0) }
        case .stairs, .lift:
            break
        }
    }

    // MARK: - Lights and switches

    /// The room's ceiling lights: one in a small room, a grid of them every 3.2 m or so in a big one; and a switch
    /// beside its door (the one into it, or its first).
    private mutating func ceilingLights() {
        let h = floor.ceiling - floor.floor
        let spacing: Float = room.type == .openOffice || room.type == .hall ? 4.0 : 3.4
        let nx = max(1, min(6, Int((inner.size.x / spacing).rounded()))), nz = max(1, min(6, Int((inner.size.y / spacing).rounded())))
        let size: SIMD2<Float> = room.type == .openOffice || room.type == .office || room.type == .meeting ? SIMD2(1.2, 0.3)
            : room.type == .hall ? SIMD2(1.5, 0.25) : SIMD2(0.5, 0.5)
        for i in 0..<nx {
            for j in 0..<nz {
                let p = inner.lo + inner.size * SIMD2((Float(i) + 0.5) / Float(nx), (Float(j) + 0.5) / Float(nz))
                lights.append((SIMD3(p.x, h - 0.015, p.y), size, room.id))
            }
        }
        // The switch: inside the room, beside the edge of its door away from the hinge, 1.1 m up.
        if let d = floor.doors.first(where: { $0.touches(room.id) && $0.kind != .open && ($0.into == room.id || $0.b < 0) })
            ?? floor.doors.first(where: { $0.touches(room.id) && $0.kind != .open }) {
            for s in sides {
                let across = dot(d.at - s.origin, s.n)
                guard abs(across) < plan.outer + 0.3 else { continue }
                let along = dot(d.at - s.origin, s.u)
                guard along > 0 && along < s.length else { continue }
                let side: Float = d.hingeLow == (dot(s.u, d.alongX ? SIMD2(1, 0) : SIMD2(0, 1)) > 0) ? 1 : -1
                let a = min(max(along + side * (d.width / 2 + 0.15), 0.1), s.length - 0.1)
                let p = s.origin + s.u * a + s.n * 0.012
                switches.append((SIMD3(p.x, 1.1, p.y), SIMD3(s.n.x, 0, s.n.y), room.id))
                break
            }
        }
    }
}
