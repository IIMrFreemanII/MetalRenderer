import Foundation
import simd

/// What a part of a generated mesh is made of. The scene turns each distinct one into a material (Scene+City), so
/// the buildings of a style share theirs.
struct SurfaceMaterial: Hashable {
    var color: SIMD3<Float>
    /// Its tiling texture, used when the city's textures are on (the colour then tints it).
    var surface: SurfaceKind? = nil
    var roughness: Float = 1
    var metallic: Float = 0
    /// Has a specular lobe (otherwise diffuse only, as the other generated scenes' materials).
    var specular = false
    var emission = SIMD3<Float>.zero
    /// Window glass: seen through and reflecting for the camera, clear to light (Scene.maskGlass); `color` tints it.
    var glass = false

    /// Texture repeats per metre for a mesh of this material.
    var uvScale: Float { 1 / (surface?.tile ?? 2) }
}

/// What to build: a lot in its own frame (width along x, depth along z, the front toward +z, the ground at y = 0,
/// centred on the origin), what each side looks onto, and the building's style, height and seed.
struct BuildingSpec {
    var size: SIMD2<Float>
    /// front (+z), right (+x), back (-z), left (-x).
    var edges: [CityPlan.Edge] = [.street, .party, .open, .party]
    var style = CityStyle.residential
    var floors = 5
    var seed: UInt64 = 1
    /// Night: `lit` of the windows have a light on behind them (emissive blinds, lamps in the rooms).
    var night = false
    var lit: Float = 0.35
    /// The share of windows with a room behind the glass instead of a blind.
    var rooms: Float = 0.15

    init(size: SIMD2<Float>) { self.size = size }
    init(lot: CityPlan.Lot, city: CitySettings, night: Bool) {
        size = lot.size
        edges = lot.edges
        style = lot.style
        floors = lot.floors
        seed = lot.seed
        self.night = night
        lit = city.lit
        rooms = city.rooms
    }
}

/// A generated building: one mesh per material, in the lot's frame.
struct Building {
    /// The parts a building is assembled from; each is one mesh of one material.
    enum Slot: Int, CaseIterable {
        case wall           // the upper floors' walls
        case base           // the ground floor's walls
        case trim           // ledges, cornices, sills, lintels, parapets, balcony slabs
        case frame          // window and door frames, mullions, railings
        case glass
        case blind          // behind a pane with no room: a blind or a curtain...
        case dark           // ...and the dark of the unlit room under it
        case roof
        case metal          // rooftop equipment, loading doors
        case accent         // doors, shutters, shop signs and awnings, furniture
        case interior       // the rooms' walls and ceilings
        case floor          // ...and their floors
        case lit            // at night: the blinds with a light on behind them
        case lamp           // ...and the rooms' ceiling lamps
    }

    private(set) var materials: [SurfaceMaterial?] = Array(repeating: nil, count: Slot.allCases.count)
    private(set) var meshes: [MeshBuilder] = Array(repeating: MeshBuilder(), count: Slot.allCases.count)
    var height: Float = 0
    /// How many windows it has, and how many of them have rooms and lights.
    var windows = 0, rooms = 0, lights = 0

    /// The used parts.
    var parts: [(slot: Slot, material: SurfaceMaterial, mesh: MeshBuilder)] {
        Slot.allCases.compactMap { slot in
            guard let m = materials[slot.rawValue], !meshes[slot.rawValue].isEmpty else { return nil }
            return (slot, m, meshes[slot.rawValue])
        }
    }
    var triangleCount: Int { meshes.reduce(0) { $0 + $1.triangleCount } }

    mutating func setMaterial(_ slot: Slot, _ material: SurfaceMaterial) {
        materials[slot.rawValue] = material
        meshes[slot.rawValue].uvScale = material.uvScale
    }

    /// Slot `slot`'s mesh, to add to. Its frame is whatever the last user left: `setFrame` first.
    subscript(_ slot: Slot) -> MeshBuilder {
        get { meshes[slot.rawValue] }
        _modify { yield &meshes[slot.rawValue] }
    }

    /// Sets every part's frame (a facade's; the identity for what is given in the lot's frame).
    mutating func setFrame(_ frame: float4x4) {
        for i in meshes.indices { meshes[i].frame = frame }
    }
}

/// A building's plan: a rectangle, or an L, U, T or ring made of a bar along the front (+z) and wings behind it.
/// It knows its outlines (for the walls), a set of rectangles that tile it (for the floors and roofs), and how to
/// step in from its edges (for setbacks and parapets). x and z, in the lot's frame.
struct Footprint {
    typealias Rect = CityPlan.Rect

    enum Shape: Equatable {
        case rect
        case l(bar: Float, wing: Float, right: Bool)    // the wing behind the bar's left or right end
        case u(bar: Float, wing: Float)                 // a wing behind each end
        case t(bar: Float, wing: Float)                 // one wing behind the middle
        case courtyard(ring: Float)                     // four bars around a court
    }

    let rect: Rect
    let shape: Shape

    /// The thinnest a bar or wing may get.
    static let thinnest: Float = 4

    init(_ rect: Rect, _ shape: Shape = .rect) {
        self.rect = rect
        self.shape = shape
    }

    /// The outlines: the outer one, and a courtyard's inner one. Each goes round so that MeshBuilder.prism's walls
    /// (and the facades') face away from the building.
    var loops: [[SIMD2<Float>]] {
        let (x0, z0, x1, z1) = (rect.lo.x, rect.lo.y, rect.hi.x, rect.hi.y)
        switch shape {
        case .rect:
            return [[SIMD2(x0, z0), SIMD2(x0, z1), SIMD2(x1, z1), SIMD2(x1, z0)]]
        case .l(let bar, let wing, let right):
            let zb = z1 - bar
            return right
                ? [[SIMD2(x0, zb), SIMD2(x0, z1), SIMD2(x1, z1), SIMD2(x1, z0), SIMD2(x1 - wing, z0), SIMD2(x1 - wing, zb)]]
                : [[SIMD2(x0, z0), SIMD2(x0, z1), SIMD2(x1, z1), SIMD2(x1, zb), SIMD2(x0 + wing, zb), SIMD2(x0 + wing, z0)]]
        case .u(let bar, let wing):
            let zb = z1 - bar
            return [[SIMD2(x0, z0), SIMD2(x0, z1), SIMD2(x1, z1), SIMD2(x1, z0), SIMD2(x1 - wing, z0), SIMD2(x1 - wing, zb),
                     SIMD2(x0 + wing, zb), SIMD2(x0 + wing, z0)]]
        case .t(let bar, let wing):
            let zb = z1 - bar, a = (x0 + x1 - wing) / 2, b = (x0 + x1 + wing) / 2
            return [[SIMD2(x0, zb), SIMD2(x0, z1), SIMD2(x1, z1), SIMD2(x1, zb), SIMD2(b, zb), SIMD2(b, z0), SIMD2(a, z0), SIMD2(a, zb)]]
        case .courtyard(let ring):
            return [[SIMD2(x0, z0), SIMD2(x0, z1), SIMD2(x1, z1), SIMD2(x1, z0)],
                    [SIMD2(x0 + ring, z0 + ring), SIMD2(x1 - ring, z0 + ring), SIMD2(x1 - ring, z1 - ring), SIMD2(x0 + ring, z1 - ring)]]
        }
    }

    /// Rectangles that tile the plan without overlapping.
    var cover: [Rect] {
        let (x0, z0, x1, z1) = (rect.lo.x, rect.lo.y, rect.hi.x, rect.hi.y)
        func r(_ ax: Float, _ az: Float, _ bx: Float, _ bz: Float) -> Rect { Rect(lo: SIMD2(ax, az), hi: SIMD2(bx, bz)) }
        switch shape {
        case .rect: return [rect]
        case .l(let bar, let wing, let right):
            return [r(x0, z1 - bar, x1, z1), right ? r(x1 - wing, z0, x1, z1 - bar) : r(x0, z0, x0 + wing, z1 - bar)]
        case .u(let bar, let wing):
            return [r(x0, z1 - bar, x1, z1), r(x0, z0, x0 + wing, z1 - bar), r(x1 - wing, z0, x1, z1 - bar)]
        case .t(let bar, let wing):
            return [r(x0, z1 - bar, x1, z1), r((x0 + x1 - wing) / 2, z0, (x0 + x1 + wing) / 2, z1 - bar)]
        case .courtyard(let ring):
            return [r(x0, z1 - ring, x1, z1), r(x0, z0, x1, z0 + ring), r(x0, z0 + ring, x0 + ring, z1 - ring),
                    r(x1 - ring, z0 + ring, x1, z1 - ring)]
        }
    }

    var area: Float { cover.reduce(0) { $0 + $1.size.x * $1.size.y } }

    /// The plan stepped in: by `front`, `right`, `back` and `left` from the rectangle's sides, and by `inner` from
    /// the edges that face its own yard or court. Nil if a bar or wing would get thinner than `thinnest`.
    func inset(front: Float = 0, right: Float = 0, back: Float = 0, left: Float = 0, inner: Float = 0) -> Footprint? {
        let r = Rect(lo: rect.lo + SIMD2(left, back), hi: rect.hi - SIMD2(right, front))
        let least = Footprint.thinnest
        guard r.size.x >= least, r.size.y >= least else { return nil }
        switch shape {
        case .rect:
            return Footprint(r)
        case .l(let bar, let wing, let onRight):
            let b = bar - front - inner, w = wing - (onRight ? right : left) - inner
            guard b >= least, w >= least, r.size.x - w >= 1, r.size.y - b >= 1 else { return nil }
            return Footprint(r, .l(bar: b, wing: w, right: onRight))
        case .u(let bar, let wing):
            let b = bar - front - inner, w = wing - max(left, right) - inner
            guard b >= least, w >= least, r.size.x - 2 * w >= 1, r.size.y - b >= 1 else { return nil }
            return Footprint(r, .u(bar: b, wing: w))
        case .t(let bar, let wing):
            let b = bar - front - inner, w = wing - 2 * inner - abs(left - right)
            guard b >= least, w >= least, r.size.y - b >= 1 else { return nil }
            return Footprint(r, .t(bar: b, wing: w))
        case .courtyard(let ring):
            let g = ring - inner - max(max(front, back), max(left, right))
            guard g >= least, min(r.size.x, r.size.y) - 2 * g >= 1 else { return nil }
            return Footprint(r, .courtyard(ring: g))
        }
    }

    /// How deep the building is behind the wall from `a` to `b`, one of its outlines' edges.
    func depth(behind a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let e = normalize(b - a), n = SIMD2(-e.y, e.x)
        let inside = (a + b) / 2 - n * 0.05
        for r in cover where inside.x >= r.lo.x && inside.x <= r.hi.x && inside.y >= r.lo.y && inside.y <= r.hi.y {
            return abs(n.x) > 0.5 ? r.size.x : r.size.y
        }
        return 0
    }

    func contains(_ p: SIMD2<Float>, margin: Float = 0) -> Bool {
        cover.contains { p.x >= $0.lo.x - margin && p.x <= $0.hi.x + margin && p.y >= $0.lo.y - margin && p.y <= $0.hi.y + margin }
    }

    /// `loop` moved by `d` along its edges' normals (outwards for d > 0), its corners kept square.
    static func offset(_ loop: [SIMD2<Float>], by d: Float) -> [SIMD2<Float>] {
        let n = normals(loop)
        return loop.indices.map { i in loop[i] + (n[(i + loop.count - 1) % loop.count] + n[i]) * d }
    }

    /// The outward normal of each of `loop`'s edges (edge i goes from corner i to corner i + 1).
    static func normals(_ loop: [SIMD2<Float>]) -> [SIMD2<Float>] {
        loop.indices.map { i in
            let e = normalize(loop[(i + 1) % loop.count] - loop[i])
            return SIMD2(-e.y, e.x)
        }
    }
}

/// One storey-stack of a building: a plan from `y0` up, a storey per entry of `heights`, and what closes its top.
/// A tower on a podium is two tiers; a setback or a penthouse starts another.
struct BuildingTier {
    var footprint: Footprint
    var y0: Float
    var heights: [Float]
    /// Its lowest storey stands on the ground (doors, shop fronts).
    var ground: Bool
    var roof: RoofKind

    var top: Float { y0 + heights.reduce(0, +) }
}

/// Builds `BuildingSpec`s. Pure and seeded: a spec always gives the same building, whatever thread makes it.
enum BuildingGenerator {
    /// A building is kept under this many triangles: the upper floors' windows of a big one lose their frames and sills.
    static let triangleLimit = 60_000

    static func generate(_ spec: BuildingSpec) -> Building {
        var assembler = BuildingAssembler(spec)
        assembler.build()
        return assembler.b
    }
}

/// The state of one building while it is made (Building+Facade.swift, Building+Roof.swift add to it).
struct BuildingAssembler {
    let spec: BuildingSpec
    let style: BuildingStyle
    var rng: SplitMix64
    var b = Building()
    /// The lot: x and z from -half to half.
    let half: SIMD2<Float>
    /// What the building stands on: the lot, less the style's setback if it stands free (set by `massing`).
    var site: CityPlan.Rect
    /// Windows from this storey of the building up are made plainly (no frames, sills or lintels), and from
    /// `ribbonFrom` up there is one to a wall: see `limitDetail`.
    var plainFrom = Int.max, ribbonFrom = Int.max
    /// The storeys under the tier being built.
    var storeysBelow = 0

    /// The ground floor's level above the lot's ground (the sidewalk is 0.15 high).
    static let step: Float = 0.2

    init(_ spec: BuildingSpec) {
        self.spec = spec
        var rng = SplitMix64(seed: spec.seed)
        style = BuildingStyle.preset(spec.style, &rng)
        self.rng = rng
        half = spec.size / 2
        site = CityPlan.Rect(lo: -half, hi: half)
    }

    mutating func build() {
        let slots: [(Building.Slot, SurfaceMaterial)] = [
            (.wall, style.wall), (.base, style.base), (.trim, style.trim), (.frame, style.frame), (.glass, style.glass),
            (.blind, style.blind), (.dark, style.dark), (.roof, style.roofing), (.metal, style.metal), (.accent, style.accent),
            (.interior, style.interior), (.floor, style.flooring), (.lit, style.lit), (.lamp, style.lamp)]
        for (slot, material) in slots { b.setMaterial(slot, material) }

        let tiers = massing()
        b.height = tiers.map(\.top).max() ?? 0
        limitDetail(tiers)
        for (k, tier) in tiers.enumerated() {
            storeysBelow = tiers[..<k].reduce(0) { $0 + $1.heights.count }
            walls(tier)
            roof(tier, under: k + 1 < tiers.count ? tiers[k + 1].footprint : nil)
        }
    }

    // MARK: - Massing

    /// Which of the lot's sides a wall with outward normal `n` at `mid` looks onto with nothing of the building in
    /// front of it (it stands on that edge of the site), if it does: 0 front, 1 right, 2 back, 3 left.
    func lotSide(_ mid: SIMD2<Float>, _ n: SIMD2<Float>) -> Int? {
        if n.y > 0.5 { return abs(mid.y - site.hi.y) < 0.02 ? 0 : nil }
        if n.x > 0.5 { return abs(mid.x - site.hi.x) < 0.02 ? 1 : nil }
        if n.y < -0.5 { return abs(mid.y - site.lo.y) < 0.02 ? 2 : nil }
        return abs(mid.x - site.lo.x) < 0.02 ? 3 : nil
    }

    /// What the wall from `a` to `c` looks onto: the lot's side if it is the building's wall on that side, open
    /// ground otherwise (a yard of its own, a terrace).
    func edgeKind(_ a: SIMD2<Float>, _ c: SIMD2<Float>) -> CityPlan.Edge {
        let e = normalize(c - a)
        return lotSide((a + c) / 2, SIMD2(-e.y, e.x)).map { spec.edges[$0] } ?? .open
    }

    /// The building's tiers, bottom to top.
    private mutating func massing() -> [BuildingTier] {
        // The site: the lot, less the style's setback on the sides that aren't against a neighbour.
        func free(_ side: Int) -> Bool { spec.edges[side] != .party }
        let back = free(0) && free(1) && free(2) && free(3) ? min(style.setback, min(half.x, half.y) * 0.25) : 0
        site = CityPlan.Rect(lo: -half + SIMD2(back, back), hi: half - SIMD2(back, back))
        let size = site.size
        let floors = max(spec.floors, 1)
        let tower = style.kind == .office && floors >= 10

        // The plan: one of the style's shapes that fits. Wings need room behind the bar, a court room inside it.
        var shape = Footprint.Shape.rect
        let wanted = tower ? PlanShape.rect : style.shapes[rng.int(style.shapes.count)]
        let bar = min(max(size.y * rng.range(0.42, 0.56), 7), size.y - 4), wing = min(max(size.x * rng.range(0.3, 0.42), 6), size.x - 5)
        let roomy = size.x >= 16 && size.y >= 13 && bar >= 6 && wing >= 5
        switch wanted {
        case .l where roomy: shape = .l(bar: bar, wing: wing, right: rng.next() < 0.5)
        case .u where roomy && size.x - 2 * wing >= 5: shape = .u(bar: bar, wing: wing)
        case .t where roomy && size.x >= 20: shape = .t(bar: bar, wing: min(wing, size.x - 10))
        case .courtyard where min(size.x, size.y) >= 24: shape = .courtyard(ring: rng.range(7, 9))
        default: break
        }
        let plan = Footprint(site, shape)

        func heights(_ count: Int, ground: Bool) -> [Float] {
            (0..<count).map { ground && $0 == 0 ? style.groundHeight : style.floorHeight }
        }
        // A pitched roof needs a plan it can be folded over.
        var top = style.roof
        var isL = false
        if case .l = shape { isL = true }
        if top != .flat && !(shape == .rect || (top == .gabled && isL)) { top = .flat }

        var tiers: [BuildingTier] = []
        // A step in from the tier below: on every side that isn't a party wall, and from its own yard.
        func stepped(_ plan: Footprint, by d: Float, front: Float? = nil) -> Footprint? {
            plan.inset(front: free(0) ? front ?? d : 0, right: free(1) ? d : 0, back: free(2) ? d : 0, left: free(3) ? d : 0, inner: d)
        }
        if tower {
            // A podium, then the tower stepping in on its way up.
            var remaining = floors, y: Float = 0, current = plan
            if style.podium, let narrower = stepped(plan, by: rng.range(3, 5)) {
                let count = 2 + rng.int(3)
                tiers.append(BuildingTier(footprint: plan, y0: 0, heights: heights(count, ground: true), ground: true, roof: .flat))
                remaining -= count
                y = tiers[0].top
                current = narrower
            }
            let steps = style.setbacks
            for k in 0...steps {
                let count = k == steps ? remaining : min(remaining, max(4, Int(Float(remaining) * rng.range(0.45, 0.65))))
                guard count > 0 else { break }
                tiers.append(BuildingTier(footprint: current, y0: y, heights: heights(count, ground: tiers.isEmpty), ground: tiers.isEmpty,
                                          roof: .flat))
                remaining -= count
                y = tiers[tiers.count - 1].top
                guard remaining > 0, let narrower = stepped(current, by: rng.range(1.8, 3)) else {
                    // No room to step in again: the rest goes on this tier.
                    tiers[tiers.count - 1].heights += heights(max(remaining, 0), ground: false)
                    break
                }
                current = narrower
            }
        } else if top == .flat, floors >= 4, rng.next() < style.penthouse, let narrower = stepped(plan, by: 1.4, front: 2.6) {
            // The top floor stands back behind a terrace.
            tiers.append(BuildingTier(footprint: plan, y0: 0, heights: heights(floors - 1, ground: true), ground: true, roof: .flat))
            tiers.append(BuildingTier(footprint: narrower, y0: tiers[0].top, heights: [style.floorHeight], ground: false, roof: .flat))
        } else {
            tiers.append(BuildingTier(footprint: plan, y0: 0, heights: heights(floors, ground: true), ground: true, roof: top))
        }
        return tiers
    }

    /// Keeps the building under `triangleLimit`. Its windows are counted, and if they are too many to make in full,
    /// the storeys from `plainFrom` up get plain ones; if that is still too much (a tall tower's thousands), the
    /// storeys from `ribbonFrom` up get one window per wall: a ribbon of glass.
    private mutating func limitDetail(_ tiers: [BuildingTier]) {
        let full: Float = 110, plain: Float = 34, ribbon: Float = 34   // triangles per window, about (rooms included)
        var bays: Float = 0, walls: Float = 0, storeys: Float = 0
        for tier in tiers {
            var tierBays: Float = 0, tierWalls: Float = 0
            for loop in tier.footprint.loops {
                for i in loop.indices where edgeKind(loop[i], loop[(i + 1) % loop.count]) != .party {
                    tierBays += max(1, (length(loop[(i + 1) % loop.count] - loop[i]) / style.bay).rounded())
                    tierWalls += 1
                }
            }
            (bays, walls) = (max(bays, tierBays), max(walls, tierWalls))
            storeys += Float(tier.heights.count)
        }
        // What is left for windows once the walls, trim and roofs have theirs.
        let budget = Float(BuildingGenerator.triangleLimit) * 0.8 - storeys * walls * 20
        guard bays > 0, storeys * bays * full > budget else { return }
        if storeys * bays * plain <= budget {
            // f storeys in full and the rest plain: f * full + (storeys - f) * plain = budget / bays.
            plainFrom = max(1, Int((budget / bays - storeys * plain) / (full - plain)))
        } else {
            plainFrom = 1
            let most = (budget - storeys * walls * ribbon) / max(bays * plain - walls * ribbon, 1)
            ribbonFrom = max(1, Int(most))
        }
    }

    // MARK: - Walls

    /// A tier's facades, and the bands that run around it: the ledges between its storeys and its cornice.
    private mutating func walls(_ tier: BuildingTier) {
        let top = tier.top
        for loop in tier.footprint.loops {
            let count = loop.count
            let kinds = loop.indices.map { edgeKind(loop[$0], loop[($0 + 1) % count]) }
            let normals = Footprint.normals(loop)
            // The main front: the street or open wall facing +z that is furthest forward (the door is in it).
            let front = loop.indices.filter { normals[$0].y > 0.5 && kinds[$0] != .party }.max { loop[$0].y < loop[$1].y }
            for i in loop.indices {
                let a = loop[i], c = loop[(i + 1) % count]
                let before = (i + count - 1) % count, after = (i + 1) % count
                // A neighbouring wall that has rooms behind it too and turns away at the corner: no rooms near it.
                func crowded(_ other: Int, _ turn: SIMD2<Float>) -> Bool { kinds[other] != .party && dot(turn, normals[i]) < 0 }
                facade(from: a, to: c, tier: tier, kind: kinds[i], front: tier.ground && i == front,
                       depth: tier.footprint.depth(behind: a, c),
                       crowdedStart: crowded(before, loop[before] - a), crowdedEnd: crowded(after, loop[(after + 1) % count] - c))
            }
            // The bands, on every wall that isn't a party wall.
            let on = kinds.map { $0 != .party }
            b.setFrame(matrix_identity_float4x4)
            if tier.ground && style.ledge && tier.heights.count > 1 {
                let y = tier.y0 + tier.heights[0]
                band(loop, on: on, y0: y - 0.1, y1: y + 0.12, depth: 0.12, slot: .trim)
            }
            if style.floorLedges {
                var y = tier.y0 + tier.heights[0]
                for h in tier.heights.dropFirst().dropLast() {
                    y += h
                    band(loop, on: on, y0: y - 0.06, y1: y + 0.06, depth: 0.06, slot: .trim)
                }
            }
            if style.cornice > 0 {
                band(loop, on: on, y0: top - 0.32, y1: top, depth: style.cornice, slot: .trim)
            }
        }
    }

    /// A band around `loop` between `y0` and `y1` that stands `depth` out from the walls (in from them, a parapet,
    /// for a negative depth), on the edges that are `on`: its face, top and underside, mitred at the corners between
    /// two edges that have it and capped where it ends. `wallFace`: its face in the walls' own plane too (a parapet's
    /// outside). The parts' frames must be the identity.
    mutating func band(_ loop: [SIMD2<Float>], on: [Bool], y0: Float, y1: Float, depth: Float, slot: Building.Slot,
                       underside: Bool = true, wallFace: Bool = false) {
        let count = loop.count, normals = Footprint.normals(loop)
        func p(_ v: SIMD2<Float>, _ y: Float) -> SIMD3<Float> { SIMD3(v.x, y, v.y) }
        for i in loop.indices where on[i] {
            let a = loop[i], c = loop[(i + 1) % count], n = normals[i]
            let before = (i + count - 1) % count, after = (i + 1) % count
            let oa = a + (on[before] ? normals[before] + n : n) * depth, oc = c + (on[after] ? n + normals[after] : n) * depth
            b[slot].quad(p(oa, y0), p(oc, y0), p(oc, y1), p(oa, y1))
            b[slot].quad(p(a, y1), p(c, y1), p(oc, y1), p(oa, y1))
            if underside { b[slot].quad(p(a, y0), p(c, y0), p(oc, y0), p(oa, y0)) }
            if wallFace { b[slot].quad(p(a, y0), p(c, y0), p(c, y1), p(a, y1)) }
            if !on[before] { b[slot].quad(p(a, y0), p(oa, y0), p(oa, y1), p(a, y1)) }
            if !on[after] { b[slot].quad(p(c, y0), p(oc, y0), p(oc, y1), p(c, y1)) }
        }
    }
}
