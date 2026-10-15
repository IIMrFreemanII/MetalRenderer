import Foundation
import simd

/// A building's inside, made from its plan (BuildingPlan): the inner face of its outer walls (cut round the windows
/// and doors the facades made), partitions with their doorways, floors and ceilings in each room's finish, the
/// stair's flights and landings, the lift's shaft. Each storey is made with its floor at y = 0 and placed at its
/// height, and storeys that are the same (a tower's typical floors) share one mesh.
///
/// Nothing is laid flat on anything else: a partition runs into the wall it meets (never along one in line with it),
/// floors and ceilings meet the walls edge on.
struct Interior {
    struct Part {
        var material: SurfaceMaterial
        var mesh: MeshBuilder
    }
    /// One storey's own geometry, its floor at y = 0 (`key`: what it is made of, the same for the same storey).
    struct Storey {
        var parts: [Part]
        var key: Int
    }
    var storeys: [Storey] = []
    /// Where each storey's mesh stands: `storeys[mesh]` at height `y` (the lot's frame), for storey `storey`.
    var placements: [(mesh: Int, storey: Int, y: Float)] = []
    /// What the walker meets (the lot's frame), and what the scene's lights, doors and furniture are
    /// (Building+Furnish.swift, Interior+Controls).
    var colliders: [Collider] = []
    var lights: [Light] = []
    var switches: [Switch] = []
    var props: [Prop] = []
    var doors: [Door] = []
    var lifts: [LiftShaft] = []
    /// The glTF props (PropLibrary): which, where in its storey's frame (fitted into a piece's box of `size`), on
    /// which storey.
    var models: [(entry: Int, frame: float4x4, size: SIMD3<Float>, storey: Int)] = []
    /// It is night: every room's lights are there to switch (by day only the lit ones'; a light that is off still
    /// costs its sampling).
    var night = false

    /// A door's leaf (the lot's frame): its hinge's foot, the leaf's direction from it when shut, which way it
    /// opens (+1 counter-clockwise seen from above), its size, and whether it starts open.
    struct Door {
        var hinge: SIMD3<Float>
        var along: SIMD2<Float>
        var turn: Float
        var width: Float
        var height: Float
        var glazed: Bool
        var open: Bool
        var storey: Int
        var color: SIMD3<Float>
    }
    /// A lift's shaft (the lot's frame): its inside, the side its doors are on, its floors' heights.
    struct LiftShaft {
        var shaft: CityPlan.Rect
        var doorSide: SIMD2<Float>
        var floors: [Float]
    }
    var triangles = 0

    /// An axis-aligned box the walker can't pass (glass is one too).
    struct Collider: Equatable {
        enum Kind: UInt8 { case solid, glass, stair, furniture }
        var lo: SIMD3<Float>, hi: SIMD3<Float>
        var kind = Kind.solid
    }
}

/// Collects one storey's meshes by material, in the order the materials come.
struct MaterialMeshes {
    private(set) var parts: [Interior.Part] = []
    private var index: [SurfaceMaterial: Int] = [:]

    subscript(_ m: SurfaceMaterial) -> MeshBuilder {
        get { index[m].map { parts[$0].mesh } ?? MeshBuilder(uvScale: m.uvScale) }
        _modify {
            // In place: a storey adds thousands of shapes to the same few meshes.
            let i: Int
            if let found = index[m] { i = found } else {
                i = parts.count
                index[m] = i
                parts.append(Interior.Part(material: m, mesh: MeshBuilder(uvScale: m.uvScale)))
            }
            yield &parts[i].mesh
        }
    }
    var triangles: Int { parts.reduce(0) { $0 + $1.mesh.triangleCount } }
}

enum InteriorBuilder {
    typealias Rect = CityPlan.Rect

    static func build(_ a: BuildingAssembler) -> Interior {
        var maker = Maker(a)
        return maker.make()
    }

    /// The finishes of a building's rooms: drawn once for it from its style.
    struct Finishes {
        let paints: [SIMD3<Float>]
        let wood: SIMD3<Float>, tile: SIMD3<Float>, carpet: SIMD3<Float>, ceiling: SIMD3<Float>, door: SIMD3<Float>
        let concrete = SurfaceMaterial(color: [0.52, 0.51, 0.49], surface: .concrete)
        let step: SurfaceMaterial
        let frame: SurfaceMaterial

        init(_ style: BuildingStyle, seed: UInt64) {
            let i = style.def.interior, d = StyleDraw(seed: seed ^ 0x1A7E_810F)
            paints = i.paints.isEmpty ? [[0.82, 0.8, 0.76]] : i.paints
            wood = i.woods.isEmpty ? [0.42, 0.3, 0.2] : d.pick(i.woods, "wood")
            tile = i.tiles.isEmpty ? [0.82, 0.83, 0.83] : d.pick(i.tiles, "tile")
            carpet = i.carpets.isEmpty ? [0.3, 0.31, 0.33] : d.pick(i.carpets, "carpet")
            ceiling = i.ceiling
            door = i.doors.isEmpty ? [0.88, 0.87, 0.84] : d.pick(i.doors, "door")
            step = style.programme.use == .house ? SurfaceMaterial(color: wood * 0.9) : SurfaceMaterial(color: [0.6, 0.59, 0.56], surface: .concrete)
            frame = SurfaceMaterial(color: door * 0.95)
        }

        func wall(_ room: PlanRoom, seed: UInt64) -> SurfaceMaterial {
            switch room.type {
            case .bath, .wc, .toilets: return SurfaceMaterial(color: tile, surface: .paving, roughness: 0.4, specular: true)
            case .hall, .storage, .lift: return SurfaceMaterial(color: [0.62, 0.61, 0.58], surface: .concrete)
            case .stairs: return SurfaceMaterial(color: paints[0] * 0.95, surface: .plaster)
            default:
                var g = SplitMix64(seed: seed ^ UInt64(room.unit + 7) &* 0x9E37_79B9 ^ UInt64(room.type.hashValue & 0xFFFF))
                let c = paints[Int(g.nextUInt64() % UInt64(paints.count))]
                return SurfaceMaterial(color: c, surface: .plaster)
            }
        }

        func floor(_ type: RoomType) -> SurfaceMaterial {
            switch type {
            case .living, .bedroom, .study, .dining, .entrance, .landing: return SurfaceMaterial(color: wood, roughness: 0.55, specular: true)
            case .office, .openOffice, .meeting: return SurfaceMaterial(color: carpet)
            case .bath, .wc, .toilets, .kitchen, .kitchenette: return SurfaceMaterial(color: tile * 0.9, surface: .paving, roughness: 0.3, specular: true)
            case .lobby, .shop, .corridor: return SurfaceMaterial(color: [0.58, 0.56, 0.52], surface: .paving, roughness: 0.4, specular: true)
            case .hall, .storage, .backroom, .stairs, .lift: return concrete
            }
        }
        var ceilingMaterial: SurfaceMaterial { SurfaceMaterial(color: ceiling, surface: .plaster) }
    }

    /// Makes one building's interior.
    struct Maker {
        let a: BuildingAssembler
        let plan: BuildingPlan
        let finishes: Finishes
        var interior = Interior()
        var m = MaterialMeshes()
        var colliders: [Interior.Collider] = []

        init(_ a: BuildingAssembler) {
            self.a = a
            plan = a.plan
            finishes = Finishes(a.style, seed: a.spec.seed)
        }

        mutating func make() -> Interior {
            var made: [Int: Int] = [:]   // storey key -> mesh
            interior.night = a.spec.night
            doorsAndLifts()
            for s in plan.storeys.indices {
                if let cut = a.spec.cut, s > cut { break }
                let floor = plan.storeys[s]
                // Storeys of the same plan share their furniture in threes (a tower's floors aren't all furnished alike).
                let variant = s % 3
                let key = storeyKey(s) &+ variant
                m = MaterialMeshes()
                colliders = []
                storey(s)
                furnish(s, seed: UInt64(bitPattern: Int64(key)) ^ a.spec.seed)
                for c in colliders {
                    interior.colliders.append(Interior.Collider(lo: c.lo + SIMD3(0, floor.floor, 0), hi: c.hi + SIMD3(0, floor.floor, 0), kind: c.kind))
                }
                let mesh: Int
                if let k = made[key] {
                    mesh = k
                } else {
                    interior.storeys.append(Interior.Storey(parts: m.parts.filter { !$0.mesh.isEmpty }, key: key))
                    mesh = interior.storeys.count - 1
                    made[key] = mesh
                }
                interior.placements.append((mesh, s, floor.floor))
                interior.triangles += m.triangles
            }
            return interior
        }

        /// The doors' leaves and the lifts, every storey's (not shared: they move).
        private mutating func doorsAndLifts() {
            var g = SplitMix64(seed: a.spec.seed ^ 0xD00_25)
            let last = a.spec.cut.map { min($0, plan.storeys.count - 1) } ?? plan.storeys.count - 1
            for s in 0...max(last, 0) where plan.storeys.indices.contains(s) {
                let f = plan.storeys[s]
                for d in f.doors where d.kind == .door || d.kind == .entrance || d.kind == .glazed {
                    let e: SIMD2<Float> = d.alongX ? SIMD2(1, 0) : SIMD2(0, 1)
                    // Into which side: toward the room it opens into.
                    let into = d.into >= 0 ? f.rooms[d.into].rect.center : d.at
                    var n: SIMD2<Float> = d.alongX ? SIMD2(0, into.y > d.at.y ? 1 : -1) : SIMD2(into.x > d.at.x ? 1 : -1, 0)
                    var at = d.at, width = d.width - 0.03
                    if d.b < 0 {
                        // A door in the outer wall: its leaf at the wall's inside, opening in.
                        let inward = f.room(at: d.at + n * (plan.outer + 0.3)) != nil ? n : -n
                        n = inward
                        at = d.at + inward * (plan.outer - 0.06)
                        width = d.width - 0.16
                    }
                    let hingeLow = d.hingeLow
                    let hinge = at - e * (hingeLow ? 1 : -1) * width / 2
                    let along = hingeLow ? e : -e
                    let turn: Float = dot(n, SIMD2(-along.y, along.x)) > 0 ? 1 : -1
                    let open = d.b >= 0 && g.next() < (f.rooms[d.a].type == .bath || f.rooms[d.b].type == .bath ? 0.4 : 0.7)
                    let color = d.b < 0 ? a.style.accent.color : finishes.door
                    interior.doors.append(Interior.Door(hinge: SIMD3(hinge.x, f.floor, hinge.y), along: along, turn: turn, width: width,
                                                        height: d.height - 0.02, glazed: d.kind == .glazed, open: open, storey: s, color: color))
                }
            }
            // A lift: its shaft's room (the same on every storey), its door's side.
            if let f = plan.storeys.first, let liftRoom = f.rooms.first(where: { $0.type == .lift }),
               let d = f.doors.first(where: { $0.kind == .lift && $0.touches(liftRoom.id) }) {
                let r = liftRoom.rect, half = plan.partition / 2
                let inside = CityPlan.Rect(lo: r.lo + SIMD2(half, half), hi: r.hi - SIMD2(half, half))
                let side: SIMD2<Float> = d.alongX ? SIMD2(0, d.at.y > r.center.y ? 1 : -1) : SIMD2(d.at.x > r.center.x ? 1 : -1, 0)
                interior.lifts.append(Interior.LiftShaft(shaft: inside, doorSide: side, floors: plan.storeys.prefix(last + 1).map(\.floor)))
            }
        }

        /// Storey `s`'s furniture (into its mesh, and its loose pieces), lights and switches.
        private mutating func furnish(_ s: Int, seed: UInt64) {
            let f = plan.storeys[s]
            var furnisher = Furnisher(floor: f, plan: plan, openings: a.b.openings.filter { $0.storey == s },
                                      palette: FurnishPalette(finishes, style: a.style), style: a.style, seed: seed)
            furnisher.furnishAll()
            let palette = FurnishPalette(finishes, style: a.style)
            let library = PropLibrary.shared
            var choose = SplitMix64(seed: seed ^ 0x9407_5)
            for p in furnisher.placed {
                // A glTF prop in its place, if the library has one for it here; the generated piece otherwise.
                let u = choose.next()
                let at = SIMD2(p.frame.columns.3.x, p.frame.columns.3.z) + SIMD2(p.frame.columns.0.x + p.frame.columns.2.x, p.frame.columns.0.z + p.frame.columns.2.z) * 0.05
                if a.style.def.interior.models, !library.entries.isEmpty, let room = f.room(at: at),
                   let entry = library.entry(for: p.item.kind, in: room.type, u: u) {
                    interior.models.append((entry, p.frame, p.item.size, s))
                } else {
                    p.item.emit(into: &m, frame: p.frame) { palette.material($0, fabric: p.fabric) }
                }
                for c in p.item.collisionBoxes {
                    let a4 = p.frame * SIMD4(c.lo, 1), b4 = p.frame * SIMD4(c.hi, 1)
                    colliders.append(Interior.Collider(lo: simd_min(SIMD3(a4.x, a4.y, a4.z), SIMD3(b4.x, b4.y, b4.z)),
                                                       hi: simd_max(SIMD3(a4.x, a4.y, a4.z), SIMD3(b4.x, b4.y, b4.z)), kind: .furniture))
                }
            }
            for p in furnisher.props {
                interior.props.append(Interior.Prop(item: p.item, frame: p.frame, storey: s,
                                                    materials: FurnitureItem.Role.allCases.map { palette.material($0, fabric: p.fabric) }))
            }
            let i = a.style.def.interior
            for l in furnisher.lights {
                let room = f.rooms[l.room]
                interior.lights.append(Interior.Light(position: l.position + SIMD3(0, f.floor, 0), size: l.size, color: i.lightColor * i.lightPower,
                                                      storey: s, room: l.room, on: room.lit, switchID: -1))
            }
            for w in furnisher.switches {
                interior.switches.append(Interior.Switch(position: w.position + SIMD3(0, f.floor, 0), normal: w.normal, storey: s, room: w.room))
                // Its plate on the wall (the storey's mesh).
                let p = w.position, n = w.normal, side = SIMD3(-n.z, 0, n.x)
                let lo = p - side * 0.04 - SIMD3(0, 0.06, 0), hi = p + side * 0.04 + SIMD3(0, 0.06, 0) + n * 0.012
                m[FurnishPalette.ceramic].box(simd_min(lo, hi), simd_max(lo, hi), faces: [.left, .right, .front, .back, .top, .bottom])
            }
        }

        /// What storey `s` is made of, relative to its floor: two storeys of the same key are the same mesh.
        private func storeyKey(_ s: Int) -> Int {
            let f = plan.storeys[s]
            var h = Hasher()
            h.combine(s == 0)
            h.combine(f.climbs)
            h.combine(PropLibrary.shared.fingerprint)
            h.combine(a.spec.cut == s)
            h.combine(f.ceiling - f.floor)
            h.combine(f.top - f.floor)
            for r in f.rooms { h.combine(r.type); h.combine(r.unit); for v in [r.rect.lo.x, r.rect.lo.y, r.rect.hi.x, r.rect.hi.y] { h.combine(v) } }
            for d in f.doors { h.combine(d.kind); h.combine(d.a); h.combine(d.b); h.combine(d.at.x); h.combine(d.at.y); h.combine(d.width) }
            for o in a.b.openings where o.storey == s {
                for v in [o.a.x, o.a.y, o.c.x, o.c.y, o.y0 - f.floor, o.y1 - f.floor] { h.combine(v) }
            }
            if s > 0 { h.combine(plan.storeys[s - 1].climbs) }
            return h.finalize()
        }

        // MARK: - A storey

        private mutating func storey(_ s: Int) {
            let f = plan.storeys[s]
            let height = f.ceiling - f.floor
            let cutHere = a.spec.cut == s
            outerWalls(s, height: height)
            partitions(s, height: height)
            for room in f.rooms {
                let floorRect: [Rect], ceilingRect: [Rect]
                switch room.type {
                case .stairs:
                    let stair = f.stair!
                    floorRect = s == 0 ? [room.rect] : [stair.entry]
                    ceilingRect = f.climbs ? [stair.entry] : [room.rect]
                case .lift:
                    floorRect = s == 0 ? [room.rect] : []
                    ceilingRect = f.climbs ? [] : [room.rect]
                default:
                    floorRect = [room.rect]
                    ceilingRect = [room.rect]
                }
                for r in floorRect {
                    m[finishes.floor(room.type)].floor(x0: r.lo.x, x1: r.hi.x, z0: r.lo.y, z1: r.hi.y, y: 0)
                    colliders.append(Interior.Collider(lo: SIMD3(r.lo.x, -plan.slab, r.lo.y), hi: SIMD3(r.hi.x, 0, r.hi.y)))
                }
                if !cutHere {
                    for r in ceilingRect {
                        m[finishes.ceilingMaterial].floor(x0: r.lo.x, x1: r.hi.x, z0: r.lo.y, z1: r.hi.y, y: height, up: false)
                        colliders.append(Interior.Collider(lo: SIMD3(r.lo.x, height, r.lo.y), hi: SIMD3(r.hi.x, height + plan.slab, r.hi.y)))
                    }
                }
            }
            if let stair = f.stair, f.climbs { flights(stair, rise: f.top - f.floor, s: s) }
            if let stair = f.stair, !f.climbs, s > 0 { topRail(stair) }
            // The landing slab's edge where it meets the well (seen from the flights below).
            if let stair = f.stair, s > 0 { landingEdge(stair) }
        }

        // MARK: - Walls

        /// A vertical rectangle from `p` to `q` (x, z) between heights `y0` and `y1`, facing `n`.
        private static func face(_ mesh: inout MeshBuilder, _ p: SIMD2<Float>, _ q: SIMD2<Float>, _ y0: Float, _ y1: Float, facing n: SIMD2<Float>) {
            guard y1 > y0 + 1e-4, distance(p, q) > 1e-4 else { return }
            let a = SIMD3(p.x, y0, p.y), b = SIMD3(q.x, y0, q.y), c = SIMD3(q.x, y1, q.y), d = SIMD3(p.x, y1, p.y)
            let normal = cross(b - a, d - a)
            if dot(SIMD2(normal.x, normal.z), n) >= 0 { mesh.quad(a, b, c, d) } else { mesh.quad(b, a, d, c) }
        }

        /// The face from `p` to `q` (u along it from 0 to its length) between `y0` and `y1`, facing `n`, cut round
        /// `holes` (u0, u1, y0, y1 each).
        private static func cutFace(_ mesh: inout MeshBuilder, _ p: SIMD2<Float>, _ q: SIMD2<Float>, _ y0: Float, _ y1: Float, facing n: SIMD2<Float>,
                                    holes: [(Float, Float, Float, Float)]) {
            let len = distance(p, q), e = (q - p) / max(len, 1e-6)
            func at(_ u: Float) -> SIMD2<Float> { p + e * u }
            var u: Float = 0
            for h in holes.map({ (max($0.0, 0), min($0.1, len), max($0.2, y0), min($0.3, y1)) }).filter({ $0.1 > $0.0 + 1e-3 }).sorted(by: { $0.0 < $1.0 }) {
                face(&mesh, at(u), at(h.0), y0, y1, facing: n)
                face(&mesh, at(h.0), at(h.1), y0, h.2, facing: n)
                face(&mesh, at(h.0), at(h.1), h.3, y1, facing: n)
                u = max(u, h.1)
            }
            face(&mesh, at(u), at(len), y0, y1, facing: n)
        }

        /// The inside of the outer walls: each room's sides that are on an outer wall, cut round that wall's openings.
        private mutating func outerWalls(_ s: Int, height: Float) {
            let f = plan.storeys[s]
            let walls = a.grids(a.b.tiers[f.tier])
            let t = plan.outer
            let openings = a.b.openings.filter { $0.storey == s }
            for room in f.rooms where !(room.type == .lift) {
                let r = room.rect
                let material = finishes.wall(room, seed: a.spec.seed &+ UInt64(s))
                let sides: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = [
                    (SIMD2(r.lo.x, r.hi.y), SIMD2(r.hi.x, r.hi.y), SIMD2(0, 1)), (SIMD2(r.hi.x, r.lo.y), SIMD2(r.hi.x, r.hi.y), SIMD2(1, 0)),
                    (SIMD2(r.lo.x, r.lo.y), SIMD2(r.hi.x, r.lo.y), SIMD2(0, -1)), (SIMD2(r.lo.x, r.lo.y), SIMD2(r.lo.x, r.hi.y), SIMD2(-1, 0))]
                for (p, q, n) in sides where !(a.spec.dollhouse && n.y > 0.5) {
                    let alongX = abs(n.y) > 0.5
                    let line = alongX ? p.y : p.x
                    let lo = alongX ? p.x : p.y, hi = alongX ? q.x : q.y
                    // The outer wall on this side, if there is one: its face is `t` out.
                    let on = walls.filter { $0.alongX == alongX && dot($0.normal, n) > 0.5 && abs($0.line - (line + (alongX ? n.y : n.x) * t)) < 0.05
                        && $0.hi > lo + 0.01 && $0.lo < hi - 0.01 }
                    guard !on.isEmpty else { continue }
                    let here = openings.filter { o in
                        dot(o.normal, n) > 0.5 && abs((alongX ? o.a.y : o.a.x) - (line + (alongX ? n.y : n.x) * t)) < 0.05
                    }
                    func hole(_ o: Building.WallOpening) -> (Float, Float, Float, Float) {
                        let u0 = (alongX ? min(o.a.x, o.c.x) : min(o.a.y, o.c.y)) - lo, u1 = (alongX ? max(o.a.x, o.c.x) : max(o.a.y, o.c.y)) - lo
                        return (u0, u1, o.y0 - f.floor, o.y1 - f.floor)
                    }
                    let holes = here.map(hole)
                    // (A stair's or lift's wall goes on down past the slab: the well is open to the storey below.)
                    let below: Float = room.type.isCore && s > 0 ? plan.slab : 0
                    Maker.cutFace(&m[material], p, q, -below, height, facing: -n, holes: holes)
                    // The walker's: the wall and the glass in its windows, down to the floor too (a shopfront, a
                    // curtain wall, a balcony's glazed doors); the doors are left open.
                    let out = alongX ? SIMD3<Float>(0, 0, n.y) : SIMD3<Float>(n.x, 0, 0)
                    let p3 = SIMD3(p.x, 0, p.y)
                    var spans: [(Float, Float)] = [(0, hi - lo)]
                    for h in here.filter({ !$0.glass }).map(hole) {
                        spans = spans.flatMap { s -> [(Float, Float)] in
                            guard h.0 < s.1 && h.1 > s.0 else { return [s] }
                            return [(s.0, max(s.0, h.0)), (min(s.1, h.1), s.1)].filter { $0.1 > $0.0 + 1e-3 }
                        }
                    }
                    for sp in spans {
                        let e3 = alongX ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
                        let c0 = p3 + e3 * sp.0, c1 = SIMD3(p3.x, height, p3.z) + e3 * sp.1 + out * t
                        colliders.append(Interior.Collider(lo: simd_min(c0, c1), hi: simd_max(c0, c1)))
                    }
                }
            }
        }

        /// The partitions: a wall on every edge two rooms share but an open one, cut where a door is.
        private mutating func partitions(_ s: Int, height: Float) {
            let f = plan.storeys[s]
            let tp = plan.partition
            var edges: [(i: Int, j: Int, e: SharedEdge)] = []
            for i in f.rooms.indices {
                for j in (i + 1)..<f.rooms.count {
                    guard let e = SharedEdge.between(f.rooms[i].rect, f.rooms[j].rect) else { continue }
                    if f.doors.contains(where: { $0.kind == .open && $0.touches(i) && $0.touches(j) }) { continue }
                    edges.append((i, j, e))
                }
            }
            let usable = f.usable
            func onBoundary(_ p: SIMD2<Float>) -> Bool {
                // On a usable rectangle's side that no other usable rectangle continues past: an outer wall.
                usable.contains { r in
                    (abs(p.x - r.lo.x) < 1e-3 || abs(p.x - r.hi.x) < 1e-3 || abs(p.y - r.lo.y) < 1e-3 || abs(p.y - r.hi.y) < 1e-3)
                        && r.contains(p, margin: 1e-3)
                } && !usable.contains { r in r.contains(p, margin: -1e-3) }
            }
            for (i, j, e) in edges {
                // Its ends: into the outer wall, into a wall across it, in line with the next (no overlap), or free.
                func end(_ u: Float, _ dir: Float) -> (extend: Float, face: Bool) {
                    let p = e.point(u)
                    if onBoundary(p) && !usable.contains(where: { $0.contains(p + (e.alongX ? SIMD2(dir * 0.05, 0) : SIMD2(0, dir * 0.05)), margin: -1e-3) }) {
                        return (0.05, false)
                    }
                    let inLine = edges.contains { o in
                        o.e.alongX == e.alongX && abs(o.e.at - e.at) < 1e-3 && !(o.i == i && o.j == j)
                            && (abs(o.e.from - u) < 1e-3 || abs(o.e.to - u) < 1e-3)
                    }
                    if inLine { return (0, false) }
                    let across = edges.contains { o in
                        o.e.alongX != e.alongX && abs(o.e.at - u) < 1e-3 && o.e.from <= e.at + tp && o.e.to >= e.at - tp
                    }
                    if across { return (tp / 2 - 0.001, false) }
                    return (0, true)
                }
                let start = end(e.from, -1), finish = end(e.to, 1)
                let from = e.from - start.extend, to = e.to + finish.extend
                // This edge's doors: holes from the floor.
                let holes = f.doors.filter { $0.kind != .open && $0.b >= 0 && $0.touches(i) && $0.touches(j) }
                    .map { d -> (Float, Float, Float, Float) in
                        let c = e.alongX ? d.at.x : d.at.y
                        return (c - d.width / 2 - from, c + d.width / 2 - from, -1, d.height)
                    }
                let below: Float = (f.rooms[i].type.isCore || f.rooms[j].type.isCore) && s > 0 ? plan.slab : 0
                // The two faces, each in its room's finish, `tp / 2` either side of the line.
                let n: SIMD2<Float> = e.alongX ? SIMD2(0, 1) : SIMD2(1, 0)
                let line = e.alongX ? SIMD2<Float>(0, e.at) : SIMD2<Float>(e.at, 0)
                func p(_ u: Float, _ side: Float) -> SIMD2<Float> {
                    (e.alongX ? SIMD2(u, 0) : SIMD2(0, u)) + line + n * side * tp / 2
                }
                // Which room is on the +n side.
                let iPlus = (e.alongX ? f.rooms[i].rect.center.y : f.rooms[i].rect.center.x) > e.at
                let plus = iPlus ? f.rooms[i] : f.rooms[j], minus = iPlus ? f.rooms[j] : f.rooms[i]
                Maker.cutFace(&m[finishes.wall(plus, seed: a.spec.seed &+ UInt64(s))], p(from, 1), p(to, 1), -below, height, facing: n, holes: holes)
                Maker.cutFace(&m[finishes.wall(minus, seed: a.spec.seed &+ UInt64(s))], p(from, -1), p(to, -1), -below, height, facing: -n, holes: holes)
                // Free ends' faces, and the doorways' sides and heads (the door frame's colour).
                var frame = m[finishes.frame]
                if start.face { Maker.face(&frame, p(from, -1), p(from, 1), -below, height, facing: e.alongX ? SIMD2(-1, 0) : SIMD2(0, -1)) }
                if finish.face { Maker.face(&frame, p(to, -1), p(to, 1), -below, height, facing: e.alongX ? SIMD2(1, 0) : SIMD2(0, 1)) }
                for h in holes {
                    let u0 = from + h.0, u1 = from + h.1, top = min(h.3, height)
                    Maker.face(&frame, p(u0, -1), p(u0, 1), 0, top, facing: e.alongX ? SIMD2(1, 0) : SIMD2(0, 1))
                    Maker.face(&frame, p(u1, 1), p(u1, -1), 0, top, facing: e.alongX ? SIMD2(-1, 0) : SIMD2(0, -1))
                    if top < height - 1e-3 {
                        let c0 = p(u0, -1), c1 = p(u1, 1)
                        frame.floor(x0: min(c0.x, c1.x), x1: max(c0.x, c1.x), z0: min(c0.y, c1.y), z1: max(c0.y, c1.y), y: top, up: false)
                    }
                }
                m[finishes.frame] = frame
                // The walker's: the wall less its doorways.
                var spans: [(Float, Float)] = [(from, to)]
                for h in holes {
                    let u0 = from + h.0, u1 = from + h.1
                    spans = spans.flatMap { s -> [(Float, Float)] in
                        guard u0 < s.1 && u1 > s.0 else { return [s] }
                        return [(s.0, max(s.0, u0)), (min(s.1, u1), s.1)].filter { $0.1 > $0.0 + 1e-3 }
                    }
                    let lo2 = p(u0, -1), hi2 = p(u1, 1)
                    colliders.append(Interior.Collider(lo: SIMD3(min(lo2.x, hi2.x), min(h.3, height), min(lo2.y, hi2.y)),
                                                       hi: SIMD3(max(lo2.x, hi2.x), height, max(lo2.y, hi2.y))))
                }
                for sp in spans {
                    let lo2 = p(sp.0, -1), hi2 = p(sp.1, 1)
                    colliders.append(Interior.Collider(lo: SIMD3(min(lo2.x, hi2.x), -below, min(lo2.y, hi2.y)),
                                                       hi: SIMD3(max(lo2.x, hi2.x), height, max(lo2.y, hi2.y))))
                }
            }
        }

        // MARK: - The stair

        /// A point of the stair from its own terms: `u` along it from its entry end, `v` across it from its first
        /// flight's side, to (x, z).
        private func stairPoint(_ st: StairPlan, _ u: Float, _ v: Float) -> SIMD2<Float> {
            let r = st.rect
            let along = st.alongX ? (st.entryLow ? r.lo.x + u : r.hi.x - u) : (st.entryLow ? r.lo.y + u : r.hi.y - u)
            let across = st.alongX ? (st.firstLow ? r.lo.y + v : r.hi.y - v) : (st.firstLow ? r.lo.x + v : r.hi.x - v)
            return st.alongX ? SIMD2(along, across) : SIMD2(across, along)
        }
        /// A box of the stair from its own terms (u0...u1 along, v0...v1 across, y0...y1).
        private mutating func stairBox(_ st: StairPlan, _ u0: Float, _ u1: Float, _ v0: Float, _ v1: Float, _ y0: Float, _ y1: Float,
                                       material: SurfaceMaterial, faces: MeshBuilder.Faces = .all, collide: Interior.Collider.Kind? = .stair) {
            let p = stairPoint(st, u0, v0), q = stairPoint(st, u1, v1)
            let lo = SIMD3(min(p.x, q.x), y0, min(p.y, q.y)), hi = SIMD3(max(p.x, q.x), y1, max(p.y, q.y))
            m[material].box(lo, hi, faces: faces)
            if let collide { colliders.append(Interior.Collider(lo: lo, hi: hi, kind: collide)) }
        }

        /// The flights from this storey's floor up `rise` to the next: steps up the first side to the half landing at
        /// the far end, and up the second side back to the landing over the entry; the spine wall between.
        private mutating func flights(_ st: StairPlan, rise: Float, s: Int) {
            let length = st.alongX ? st.rect.size.x : st.rect.size.y, width = st.alongX ? st.rect.size.y : st.rect.size.x
            let w = st.flightWidth, l = StairPlan.landing, run = StairPlan.run
            let (n1, n2, h) = StairPlan.steps(rise)
            let material = finishes.step, under: Float = 0.18
            // The first flight up its side from the entry landing; the second down its side from the half landing
            // (its top step meets the landing above).
            let top1 = l + Float(n1) * run, start2 = l + Float(n2) * run
            for k in 0..<n1 {
                let u0 = l + Float(k) * run, top = Float(k + 1) * h
                stairBox(st, u0, u0 + run, 0, w, max(0, top - h - under), top, material: material)
            }
            let mid = Float(n1) * h
            for k in 0..<n2 {
                let u1 = start2 - Float(k) * run, top = mid + Float(k + 1) * h
                stairBox(st, u1 - run, u1, width - w, width, top - h - under, top, material: material)
            }
            // The half landing across the far end, at the first flight's top.
            stairBox(st, top1, length, 0, w, mid - 0.2, mid, material: material)
            stairBox(st, start2, length, w, width, mid - 0.2, mid, material: material)
            // The spine between the flights, from the floor (the slab below, above the ground) to the next floor.
            let spine = SurfaceMaterial(color: finishes.paints[0], surface: .plaster)
            stairBox(st, l, start2, w, width - w, s > 0 ? -plan.slab : 0, rise, material: spine, faces: .all, collide: .solid)
        }

        /// The topmost storey's rail along its landing, over the well where no flight goes up.
        private mutating func topRail(_ st: StairPlan) {
            let w = st.flightWidth, l = StairPlan.landing
            let rail = SurfaceMaterial(color: [0.12, 0.12, 0.13], roughness: 0.4, metallic: 0.8, specular: true)
            stairBox(st, l, l + 0.05, 0, w, 0, 1.0, material: rail, collide: .solid)
        }

        /// The slab's edge at the landing over the well, from the ceiling below up to this floor.
        private mutating func landingEdge(_ st: StairPlan) {
            let width = st.alongX ? st.rect.size.y : st.rect.size.x, l = StairPlan.landing
            let p = stairPoint(st, l, 0), q = stairPoint(st, l, width)
            let into = st.alongX ? SIMD2<Float>(st.entryLow ? 1 : -1, 0) : SIMD2<Float>(0, st.entryLow ? 1 : -1)
            Maker.face(&m[finishes.step], p, q, -plan.slab, 0, facing: into)
        }
    }
}
