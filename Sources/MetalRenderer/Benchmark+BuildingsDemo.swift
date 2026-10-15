import CoreGraphics
import Foundation
import simd

/// The building editor's demo video (`.claude/skills/offscreen/scripts/video.sh -m buildingsdemo`): about four
/// and a half minutes of the building workshop, the city and the open world at the app's look (cascades, 3x from
/// 0.5x to 1920x1200, the showcase's lens without depth of field). Each shot is a recording setting named
/// `bdemo NN <section> …`; the sections' captions are put on when the shots are joined.
///
/// The styles, live edits as stop-motion (floors, the lot's width, the seed), Mutate's variations, the street, the
/// cutaway floor by floor and the dollhouse, hand edits of a floor plan before and after; then walks inside, the
/// camera a walker's body (`Config.walking`: doors open for it): in from the street, up the stairs into a flat; an
/// office's lift called, ridden and left, past the desks; a flat at night with its lights switched off and a
/// flashlight; the city's building whose interior is loaded; the open world's.
extension Benchmark {
    static func buildingsDemo() -> [Config] {
        var out: [Config] = []
        func shot(_ name: String, _ scene: SceneSettings) -> Config {
            Config("bdemo \(String(format: "%02d", out.count + 1)) \(name)", scale: 0.5, upscale: 3, gi: .radianceCascades, scene: scene) {
                $0.post = ShowcaseLook.lens.with { $0.aperture = 0 }   // sharp throughout: no depth of field
            }.recording()
        }
        func workshop(_ p: BuildingSceneSettings) -> SceneSettings {
            var s = SceneSettings(kind: .buildings)
            s.buildings = p
            return s
        }
        func height(_ p: BuildingSceneSettings) -> Float { BuildingGenerator.generate(Scene.workshopSpec(p, catalog: .builtIn).spec).height }
        func still(_ position: SIMD3<Float>, _ target: SIMD3<Float>) -> Camera {
            CameraTrack([CameraTrack.Key(time: 0, position: position, target: target)]).camera(at: 0)
        }

        var home = BuildingSceneSettings()
        (home.style, home.lot, home.floors) = ("residential", SIMD2(22, 14), 5)

        // The opening: a residential block, round from its left to its right.
        let homeHeight = height(home)
        out.append(shot("intro", workshop(home)).track(orbit(center: [0, homeHeight * 0.45, 0], radius: 34, height: homeHeight * 0.55 + 4,
                                                            from: -1.0, to: 0.9, seconds: 12, eased: true)))

        // The styles: each built-in one on a lot of its district's, a few seconds of a turn round it.
        let styles: [(String, SIMD2<Float>, BuildingSceneSettings.Sides, Int)] = [
            ("oldtown", [9, 12], .row, 3), ("residential", [22, 14], .row, 5), ("warehouse", [34, 28], .free, 2),
            ("office", [34, 30], .free, 8), ("modern", [24, 15], .row, 6)]
        for (k, (style, lot, sides, floors)) in styles.enumerated() {
            var p = BuildingSceneSettings()
            (p.style, p.lot, p.sides, p.floors) = (style, lot, sides, floors)
            let h = height(p), r = max(lot.x, lot.y) * 0.9 + h * 0.6 + 10
            let a0 = -0.7 + Float(k) * 0.2
            out.append(shot("styles \(style)", workshop(p)).track(orbit(center: [0, h * 0.45, 0], radius: r, height: h * 0.5 + 3,
                                                                       from: a0, to: a0 + 0.5, seconds: 4, eased: false)))
        }

        // Live edits, as the editor's sliders make them: the floors, the lot's width, the seed. One camera.
        let editCamera = still([26, 15, 46], [0, 10, 0])
        for floors in 2...9 {
            var p = home
            p.floors = floors
            out.append(shot("edits floors \(floors)", workshop(p)).from(editCamera).frames(60))
        }
        for width: Float in [14, 18, 22, 26, 30] {
            var p = home
            (p.floors, p.lot.x) = (6, width)
            out.append(shot("edits width \(Int(width))", workshop(p)).from(editCamera).frames(60))
        }
        for seed in 1...4 {
            var p = home
            (p.floors, p.seed) = (6, seed)
            out.append(shot("edits seed \(seed)", workshop(p)).from(editCamera).frames(90))
        }

        // Mutate: the style and six variations of it in a row, the camera along them.
        let mutants = BuildingMutate.mutants(of: BuiltInBuildings.residential, seed: 7)
        var mutate = home
        (mutate.layout, mutate.mutants) = (.mutate, BuildingCatalog.register(BuildingCatalog(styles: mutants)))
        let row = 6 * (home.lot.x + 6)
        out.append(shot("mutate", workshop(mutate)).track(CameraTrack([
            CameraTrack.Key(time: 0, position: [-12, 14, 42], target: [4, 8, 0]),
            CameraTrack.Key(time: 12, position: [row + 12, 14, 42], target: [row - 4, 8, 0])])))

        // In its street, between two neighbours of its style.
        var street = home
        street.layout = .street
        out.append(shot("street", workshop(street)).track(orbit(center: [0, homeHeight * 0.4, 0], radius: 46, height: homeHeight * 0.5 + 6,
                                                               from: 0.5, to: -0.3, seconds: 8, eased: true)))

        // The cutaway, floor by floor, then the dollhouse.
        let cutCamera = still([24, 26, 30], [0, 1.5, 0])
        for cut in 0..<home.floors {
            var p = home
            (p.view, p.cut) = (.cutaway, cut)
            out.append(shot("cutaway \(cut)", workshop(p)).from(cutCamera).frames(90))
        }
        var doll = home
        (doll.view, doll.cut) = (.dollhouse, 2)
        out.append(shot("dollhouse", workshop(doll)).track(orbit(center: [0, 4, 0], radius: 26, height: 13, from: -0.6, to: 0.6,
                                                                seconds: 12, eased: true)))

        // Hand edits of the floor plan (the Floor Plan window's): the first floor before, and with two front rooms
        // made one, another split, a room's use changed.
        var plan1 = home
        (plan1.view, plan1.cut) = (.dollhouse, 1)
        let editsTrack = CameraTrack([CameraTrack.Key(time: 0, position: [-14, 15, 22], target: [-2, 2, 0]),
                                      CameraTrack.Key(time: 6, position: [14, 15, 22], target: [2, 2, 0])])
        out.append(shot("plan before", workshop(plan1)).track(editsTrack))
        var edited = workshop(plan1)
        edited.buildingCatalog = planEdits(home)
        out.append(shot("plan after", edited).track(editsTrack))

        // Inside, by day: in from the street, up the stairs, into a flat.
        let homeSpec = Scene.workshopSpec(home, catalog: .builtIn).spec
        let homePlan = BuildingGenerator.generate(homeSpec).plan
        let (day, _) = intoAFlat(homePlan).track(.identity)
        out.append(shot("walk", workshop(home)).track(day).walking())

        // An office tower: to its lift, called, ridden to the third floor, out past the desks into its chairs.
        var office = BuildingSceneSettings()
        (office.style, office.lot, office.sides, office.floors) = ("office", SIMD2(34, 30), .free, 8)
        let officeBuilding = BuildingGenerator.generate(Scene.workshopSpec(office, catalog: .builtIn).spec)
        if let (lift, marks) = liftRide(officeBuilding, to: 3) {
            out.append(shot("lift", workshop(office)).track(lift).walking().riding(0)
                .at(marks["landing"]! + 0.4, .callLift(0, floor: 0)).at(marks["cab"]! + 0.6, .callLift(0, floor: 3)))
        }

        // At night: the lit windows, then a flat's lights switched off, a flashlight, on again.
        var night = home
        night.night = true
        out.append(shot("night outside", workshop(night)).track(orbit(center: [0, homeHeight * 0.45, 0], radius: 36,
                                                                      height: homeHeight * 0.5 + 3, from: 0.7, to: -0.2, seconds: 10, eased: true)))
        let nightPlan = BuildingGenerator.generate(Scene.workshopSpec(night, catalog: .builtIn).spec).plan
        if let (dark, marks) = darkFlat(nightPlan) {
            out.append(shot("night inside", workshop(night)).track(dark).walking()
                .at(marks["off"]!, .lights(on: false, within: 9)).at(marks["off"]! + 1.2, .flashlight(true))
                .at(marks["on"]!, .lights(on: true, within: 9)).at(marks["on"]! + 1.5, .flashlight(false)))
        }

        // The city: down from above to a street, and into the building there whose interior is loaded, to its stair.
        var city = CitySettings()
        (city.blocks, city.style) = (2, .residential)
        let cityPlan = CityPlan(city, seed: 1)
        let lotIndex = cityPlan.lots.firstIndex { $0.edges[0] == .street } ?? 0
        let lot = cityPlan.lots[lotIndex]
        var inCity = SceneSettings(kind: .city, city: city, seed: 1)
        inCity.interior = LotRef.city(city, seed: 1, lot: lotIndex, lot).key
        var citySpec = BuildingSpec(lot: lot, city: city, night: false, catalog: .builtIn)
        citySpec.interior = true
        let cityWalk = intoAFlat(BuildingGenerator.generate(citySpec).plan, upstairs: false)
        let (walkIn, _) = cityWalk.track(lot.transform)
        let start = walkIn.keys[0], away = simd_normalize(SIMD3(start.position.x - start.target.x, 0, start.position.z - start.target.z))
        out.append(shot("city above", inCity).track(CameraTrack([
            CameraTrack.Key(time: 0, position: start.position + away * 120 + [0, 90, 0], target: start.position - away * 20),
            CameraTrack.Key(time: 7, position: start.position + away * 40 + [0, 26, 0], target: start.target),
            CameraTrack.Key(time: 12, position: start.position, target: start.target)])))
        out.append(shot("city walk", inCity).track(walkIn).walking())

        // The open world: the living room of a flat of the building nearest where it starts, looked round from a corner.
        if let (world, spec, transform) = worldInteriorLot() {
            let f = BuildingGenerator.generate(spec).plan.storeys[1]
            if let room = f.rooms.filter({ $0.type == .living }).max(by: { $0.area < $1.area }) {
                out.append(shot("world", world).track(lookRound(room.rect, floor: f.floor, transform: transform, seconds: 10)))
            }
        }
        return out
    }

    // MARK: - Tracks

    /// Round a centre at `radius`, `height` above it, from angle `a0` to `a1` (0: in front, +z; positive: to the
    /// right), looking at the centre.
    static func orbit(center: SIMD3<Float>, radius: Float, height: Float, from a0: Float, to a1: Float, seconds: Float,
                      eased: Bool) -> CameraTrack {
        let n = max(2, Int(seconds * 10))
        return CameraTrack((0...n).map { k in
            let u = Float(k) / Float(n), e = eased ? u * u * (3 - 2 * u) : u, a = a0 + (a1 - a0) * e
            return CameraTrack.Key(time: seconds * u, position: center + SIMD3(radius * sin(a), height - center.y, radius * cos(a)),
                                   target: center)
        }, linear: true)
    }

    /// From a corner of room `r` (its floor at `floor`; `transform`: the lot's into the world), the view turning slowly
    /// from along one wall across the room to along the other.
    static func lookRound(_ r: CityPlan.Rect, floor: Float, transform: float4x4, seconds: Float) -> CameraTrack {
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { let w = transform * SIMD4(p, 1); return SIMD3(w.x, w.y, w.z) }
        let eye = SIMD3(r.lo.x + 0.5, floor + 1.6, r.lo.y + 0.5)
        let a = SIMD3(r.hi.x - 0.3, floor + 1.2, r.lo.y + 0.9) - eye, b = SIMD3(r.lo.x + 0.9, floor + 1.2, r.hi.y - 0.3) - eye
        let n = Int(seconds * 10)
        return CameraTrack((0...n).map { k in
            let u = Float(k) / Float(n), s = u * u * (3 - 2 * u)
            let d = simd_normalize(simd_normalize(a) * (1 - s) + simd_normalize(b) * s)
            return CameraTrack.Key(time: seconds * u, position: world(eye), target: world(eye + d * 3))
        }, linear: true)
    }

    /// The workshop building's first floor with hand edits (a catalog of its own, registered): its biggest front room
    /// split, two rooms beside each other made one, a bedroom made a study.
    private static func planEdits(_ p: BuildingSceneSettings) -> String {
        let (spec, ref) = Scene.workshopSpec(p, catalog: .builtIn)
        let f = BuildingGenerator.generate(spec).plan.storeys[1]
        let front = f.rooms.filter { !$0.type.isCirculation && !$0.type.isCore && $0.rect.hi.y > f.usable[0].hi.y - 0.1 }
        var edits: [PlanEdit] = []
        if let big = front.max(by: { $0.area < $1.area }) {
            edits.append(PlanEdit(op: .split, storeys: .one(1), at: big.rect.center, alongX: false))
        }
        for a in front {
            if let b = front.first(where: { $0.id != a.id && $0.unit == a.unit && SharedEdge.between(a.rect, $0.rect) != nil
                && abs($0.rect.size.y - a.rect.size.y) < 0.05 }) {
                edits.append(PlanEdit(op: .merge, storeys: .one(1), at: a.rect.center, to: b.rect.center))
                break
            }
        }
        if let bed = f.rooms.first(where: { $0.type == .bedroom && !front.contains($0) }) {
            edits.append(PlanEdit(op: .setType, storeys: .one(1), at: bed.rect.center, type: .study))
        }
        var catalog = BuildingCatalog.builtIn
        catalog.overrides = [LotOverride(ref: ref, edits: edits)]
        return BuildingCatalog.register(catalog)
    }

    /// From the street through the front door, to the stair, up a floor, along to a flat and into its living room
    /// and on to a bedroom.
    private static func intoAFlat(_ plan: BuildingPlan, bedroom: Bool = true, upstairs: Bool = true) -> DemoWalk {
        var walk = DemoWalk(plan: plan)
        let f0 = plan.storeys[0]
        guard let door = plan.outsideDoors(0).first(where: { $0.kind == .entrance }) ?? plan.outsideDoors(0).first,
              let stairs = f0.rooms.firstIndex(where: { $0.type == .stairs }) else { return walk }
        walk.enter(door, from: 5)
        walk.route(storey: 0, from: door.a, to: stairs)
        guard plan.storeys.count > 1 else { return walk }
        if !upstairs {
            // At the stair's foot, looking up it.
            walk.climb(from: 0)
            let up = walk.points[walk.points.count - 6].p
            walk.points.removeLast(7)
            walk.wait(3, looking: up + [0, 1.4, 0])
            return walk
        }
        walk.climb(from: 0)
        if let flat = flatWalk(plan, storey: 1, from: plan.storeys[1].rooms.firstIndex { $0.type == .stairs }, bedroom: bedroom) {
            walk.points += flat.points
        }
        return walk
    }

    /// On `storey`, from room `start` (or just inside the flat's door) through a flat's hall into its living room,
    /// a look round, and on into a bedroom: the flat whose door is nearest `start`.
    private static func flatWalk(_ plan: BuildingPlan, storey s: Int, from start: Int? = nil, bedroom: Bool = true) -> DemoWalk? {
        let f = plan.storeys[s]
        var walk = DemoWalk(plan: plan)
        let origin = start.map { f.rooms[$0].rect.center } ?? f.rooms[0].rect.center
        // The flats' doors from the common rooms: into a hall (or a living room).
        let ways = f.doors.filter { d in
            d.b >= 0 && d.kind == .door && [d.a, d.b].contains { f.rooms[$0].unit < 0 } && [d.a, d.b].contains { f.rooms[$0].unit >= 0 }
        }.filter { d in
            let unit = f.rooms[f.rooms[d.a].unit >= 0 ? d.a : d.b].unit
            return f.rooms.contains { $0.unit == unit && $0.type == .living }
        }
        func hasBedroom(_ d: PlanDoor) -> Bool {
            let unit = f.rooms[f.rooms[d.a].unit >= 0 ? d.a : d.b].unit
            return f.rooms.contains { $0.unit == unit && $0.type == .bedroom }
        }
        let best = ways.contains(where: hasBedroom) ? ways.filter(hasBedroom) : ways
        guard let way = best.min(by: { simd_distance($0.at, origin) < simd_distance($1.at, origin) }) else { return nil }
        let (common, hall) = f.rooms[way.a].unit < 0 ? (way.a, way.b) : (way.b, way.a)
        let unit = f.rooms[hall].unit
        // (A bedroom next, or in a studio its kitchen or dining room.)
        guard let living = f.rooms.firstIndex(where: { $0.unit == unit && $0.type == .living }) else { return nil }
        let next = [RoomType.bedroom, .kitchen, .dining].lazy.compactMap { t in
            f.rooms.firstIndex { $0.unit == unit && $0.type == t && $0.id != f.rooms[living].id } }.first
        if let start {
            walk.route(storey: s, from: start, to: common)
        } else {
            walk.go(way.at + way.normal(toward: f.rooms[common].rect.center) * 1.1, storey: s)
            walk.wait(0.8)
        }
        walk.cross(way, storey: s, from: common, to: hall)
        walk.route(storey: s, from: hall, to: living)
        walk.go(f.rooms[living].rect.center, storey: s, short: 1.0)
        walk.wait(3, looking: farCorner(f.rooms[living].rect, from: walk.points.last!.p, y: f.floor + 1.1))
        walk.mark("living")
        if bedroom, let bed = next {
            walk.route(storey: s, from: living, to: bed)
            walk.go(f.rooms[bed].rect.center, storey: s, short: 1.0)
            walk.wait(2.5, looking: farCorner(f.rooms[bed].rect, from: walk.points.last!.p, y: f.floor + 1.0))
            walk.mark("bedroom")
        }
        return walk
    }

    /// The corner of `r` farthest from `p`, a little in, at `y`.
    private static func farCorner(_ r: CityPlan.Rect, from p: SIMD3<Float>, y: Float) -> SIMD3<Float> {
        let x = abs(r.lo.x - p.x) > abs(r.hi.x - p.x) ? r.lo.x + 0.4 : r.hi.x - 0.4
        let z = abs(r.lo.y - p.z) > abs(r.hi.y - p.z) ? r.lo.y + 0.4 : r.hi.y - 0.4
        return SIMD3(x, y, z)
    }

    /// A flat at night: in, its lights off ("off"), round it by flashlight, its lights on again ("on").
    private static func darkFlat(_ plan: BuildingPlan) -> (CameraTrack, [String: Float])? {
        let s = min(2, plan.storeys.count - 1)
        guard var walk = flatWalk(plan, storey: s) else { return nil }
        // (The lights go off as it looks round the living room, on again in the bedroom.)
        if let i = walk.points.firstIndex(where: { $0.mark == "living" }) { walk.points[i].mark = "off"; walk.points[i].pause += 2 }
        if let i = walk.points.firstIndex(where: { $0.mark == "bedroom" }) { walk.points[i].mark = "on"; walk.points[i].pause += 2 }
        return walk.track(.identity)
    }

    /// In from the street to the lift ("landing": in front of its door, "cab": in it, facing out), up to floor `to`
    /// and out, across the open office to its nearest loose chair. The track is keyed at the lift's lowest floor's
    /// height all through (the ride carries the camera: `Config.riding`).
    private static func liftRide(_ b: Building, to floor: Int) -> (CameraTrack, [String: Float])? {
        let plan = b.plan
        let f0 = plan.storeys[0]
        guard floor < plan.storeys.count, let door = plan.outsideDoors(0).first,
              let liftDoor = f0.doors.first(where: { $0.kind == .lift }) else { return nil }
        let liftRoom = f0.rooms[liftDoor.a].type == .lift ? liftDoor.a : liftDoor.b, landing = liftDoor.other(liftRoom)
        var walk = DemoWalk(plan: plan)
        walk.enter(door, from: 5)
        walk.route(storey: 0, from: door.a, to: landing)
        let out = liftDoor.normal(toward: f0.rooms[landing].rect.center)
        walk.go(liftDoor.at + out * 1.3, storey: 0)
        walk.wait(3.5, looking: SIMD3(liftDoor.at.x, f0.floor + 1.3, liftDoor.at.y))
        walk.mark("landing")
        walk.go(liftDoor.at, storey: 0)
        walk.go(f0.rooms[liftRoom].rect.center, storey: 0)
        let rise = plan.storeys[floor].floor - f0.floor
        let ride = 1.5 + 2 / 1.2 + rise / 1.5 + 0.8
        walk.wait(ride + 2.5, looking: SIMD3(liftDoor.at.x, f0.floor + 1.5, liftDoor.at.y) + SIMD3(out.x, 0, out.y) * 4)
        walk.mark("cab")
        // Out on the floor it goes to, at the same height in the track.
        let f = plan.storeys[floor]
        walk.level = f0.floor
        guard let upper = f.doors.first(where: { $0.kind == .lift }) else { return walk.track(.identity) }
        let upperLift = f.rooms[upper.a].type == .lift ? upper.a : upper.b, upperLanding = upper.other(upperLift)
        walk.go(upper.at, storey: floor)
        walk.go(upper.at + upper.normal(toward: f.rooms[upperLanding].rect.center) * 0.8, storey: floor)
        if let open = f.rooms.indices.filter({ f.rooms[$0].type == .openOffice }).max(by: { f.rooms[$0].area < f.rooms[$1].area }) {
            walk.route(storey: floor, from: upperLanding, to: open)
            let here = walk.points.last!.p
            let chairs = (b.interior?.props ?? []).filter { $0.storey == floor && $0.item.pushable }
                .map { SIMD2($0.frame.columns.3.x, $0.frame.columns.3.z) }
            if let chair = chairs.min(by: { simd_distance($0, SIMD2(here.x, here.z)) < simd_distance($1, SIMD2(here.x, here.z)) }),
               simd_distance(chair, SIMD2(here.x, here.z)) < 12 {
                let along = simd_normalize(chair - SIMD2(here.x, here.z))
                walk.go(chair - along * 1.2, storey: floor)
                walk.go(chair + along * 0.6, storey: floor)
                walk.wait(2)
            } else {
                walk.go(f.rooms[open].rect.center, storey: floor)
                walk.wait(2)
            }
        }
        return walk.track(.identity)
    }
}

/// A walk through a building's plan for a demo's camera: where its feet go (the lot's space), where it stands a
/// while and what it looks at then; made into a track at a walking pace, the eyes looking ahead along the way.
struct DemoWalk {
    struct Point {
        var p: SIMD3<Float>
        var pause: Float = 0
        var look: SIMD3<Float>? = nil
        var mark: String? = nil
    }
    let plan: BuildingPlan
    /// Every point's height instead of its storey's floor (a lift's riders: their track is keyed at its lowest floor).
    var level: Float? = nil
    var points: [Point] = []

    init(plan: BuildingPlan) { self.plan = plan }

    private func y(_ s: Int) -> Float { level ?? plan.storeys[s].floor }

    mutating func go(_ q: SIMD2<Float>, storey s: Int, short: Float = 0) {
        var q = q
        if short > 0, let last = points.last {
            let d = q - SIMD2(last.p.x, last.p.z), l = simd_length(d)
            if l > short { q -= d / l * short }
        }
        points.append(Point(p: SIMD3(q.x, y(s), q.y)))
    }
    mutating func go(_ p: SIMD3<Float>) { points.append(Point(p: p)) }
    /// Stands at the last point `seconds` (turning to look at `looking`, and back to the way on).
    mutating func wait(_ seconds: Float, looking: SIMD3<Float>? = nil) {
        guard !points.isEmpty else { return }
        points[points.count - 1].pause += seconds
        if let looking { points[points.count - 1].look = looking }
    }
    mutating func mark(_ name: String) { if !points.isEmpty { points[points.count - 1].mark = name } }

    /// From `distance` out in the street to just inside the building's door `d` (its ground floor's).
    mutating func enter(_ d: PlanDoor, from distance: Float) {
        let f = plan.storeys[0]
        let inward = d.normal(toward: f.rooms[d.a].rect.center)
        go(SIMD3(d.at.x - inward.x * distance, 0, d.at.y - inward.y * distance))
        go(SIMD3(d.at.x - inward.x * 1.0, 0, d.at.y - inward.y * 1.0))
        wait(0.6)
        go(SIMD3(d.at.x, f.floor, d.at.y))
        go(SIMD3(d.at.x + inward.x * 1.0, y(0), d.at.y + inward.y * 1.0))
    }

    /// Through door `d` of storey `s` from room `a` to room `b`: before it (a moment, if it has a leaf to open), in it,
    /// past it.
    mutating func cross(_ d: PlanDoor, storey s: Int, from a: Int, to b: Int) {
        let f = plan.storeys[s]
        go(d.at + d.normal(toward: f.rooms[a].rect.center) * 0.8, storey: s)
        if d.kind != .open { wait(0.5) }
        go(d.at, storey: s)
        go(d.at + d.normal(toward: f.rooms[b].rect.center) * 0.8, storey: s)
    }

    /// The fewest doors from room `a` to room `b` of storey `s` (not the lifts'), each crossed.
    mutating func route(storey s: Int, from a: Int, to b: Int) {
        let f = plan.storeys[s]
        var previous: [Int: (room: Int, door: Int)] = [:], queue = [a], seen: Set<Int> = [a]
        while !queue.isEmpty {
            let r = queue.removeFirst()
            if r == b { break }
            for (k, d) in f.doors.enumerated() where d.b >= 0 && d.kind != .lift && d.touches(r) && seen.insert(d.other(r)).inserted {
                previous[d.other(r)] = (r, k)
                queue.append(d.other(r))
            }
        }
        var chain: [(from: Int, door: Int, to: Int)] = []
        var r = b
        while r != a, let p = previous[r] { chain.insert((p.room, p.door, r), at: 0); r = p.room }
        for c in chain { cross(f.doors[c.door], storey: s, from: c.from, to: c.to) }
    }

    /// Up the stair from storey `s` to the next: its entry landing, the first flight, the turn, the second flight.
    mutating func climb(from s: Int) {
        guard let st = plan.storeys[s].stair, s + 1 < plan.storeys.count else { return }
        let r = st.rect, length = st.alongX ? r.size.x : r.size.y, width = st.alongX ? r.size.y : r.size.x, w2 = st.flightWidth / 2
        func point(_ u: Float, _ v: Float, _ y: Float) -> SIMD3<Float> {
            let along = st.alongX ? (st.entryLow ? r.lo.x + u : r.hi.x - u) : (st.entryLow ? r.lo.y + u : r.hi.y - u)
            let across = st.alongX ? (st.firstLow ? r.lo.y + v : r.hi.y - v) : (st.firstLow ? r.lo.x + v : r.hi.x - v)
            return st.alongX ? SIMD3(along, y, across) : SIMD3(across, y, along)
        }
        let f = plan.storeys[s].floor, rise = plan.storeys[s + 1].floor - f
        let (n1, n2, h) = StairPlan.steps(rise)
        let l = StairPlan.landing, top = l + Float(n1) * StairPlan.run, mid = f + Float(n1) * h
        for p in [point(0.6, w2, f), point(l, w2, f), point(top, w2, mid), point(length - 0.6, w2, mid), point(length - 0.6, width - w2, mid),
                  point(top, width - w2, mid), point(top - Float(n2) * StairPlan.run, width - w2, f + rise), point(0.6, width - w2, f + rise)] {
            go(p)
        }
    }

    /// The track through it, the lot's space put in the world by `transform`: `speed` metres a second, the eyes `eye`
    /// above the feet looking `ahead` metres on along the way; and the times its marks are reached.
    func track(_ transform: float4x4, speed: Float = 1.25, eye: Float = 1.65, ahead: Float = 2.6) -> (track: CameraTrack, marks: [String: Float]) {
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { let w = transform * SIMD4(p, 1); return SIMD3(w.x, w.y, w.z) }
        // Corners rounded off (not where it stands or is marked).
        var path: [Point] = []
        for (i, p) in points.enumerated() {
            guard i > 0, i < points.count - 1, p.pause == 0, p.mark == nil else { path.append(p); continue }
            let a = points[i - 1].p - p.p, b = points[i + 1].p - p.p
            let r = min(0.35, simd_length(a) / 2, simd_length(b) / 2)
            guard r > 0.05, simd_length(a) > 0, simd_length(b) > 0 else { path.append(p); continue }
            path.append(Point(p: p.p + simd_normalize(a) * r))
            path.append(Point(p: p.p + simd_normalize(b) * r))
        }
        guard path.count > 1 else {
            let p = path.first?.p ?? .zero
            return (CameraTrack([CameraTrack.Key(time: 0, position: world(p + [0, eye, 0]), target: world(p + [0, eye, -1]))]), [:])
        }
        var along = [Float(0)]
        for (a, b) in zip(path, path.dropFirst()) { along.append(along.last! + simd_length(b.p - a.p)) }
        let total = along.last!
        func at(_ s: Float) -> SIMD3<Float> {
            if s >= total {
                let d = path[path.count - 1].p - path[path.count - 2].p
                return path.last!.p + (simd_length(d) > 1e-4 ? simd_normalize(d) : [0, 0, -1]) * (s - total)
            }
            let i = max(0, (along.lastIndex { $0 <= s } ?? 0))
            let j = min(i + 1, path.count - 1)
            let u = along[j] > along[i] ? (s - along[i]) / (along[j] - along[i]) : 0
            return path[i].p + (path[j].p - path[i].p) * u
        }
        func lookahead(_ s: Float) -> SIMD3<Float> {
            // (Up a stair, a little up it, not at the flight overhead.)
            var t = at(s + ahead)
            let y = at(s).y
            t.y = min(max(t.y, y), y + 0.6) + eye - 0.2
            return t
        }

        var keys: [CameraTrack.Key] = [], marks: [String: Float] = [:], time: Float = 0
        func key(_ position: SIMD3<Float>, _ target: SIMD3<Float>) {
            if let last = keys.last, time <= last.time { time = last.time + 1e-3 }
            keys.append(CameraTrack.Key(time: time, position: world(position + [0, eye, 0]), target: world(target)))
        }
        /// Turning from looking at `a` to `b` (from `p`), over `seconds`.
        func turn(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ seconds: Float) {
            let e = p + [0, eye, 0], da = a - e, db = b - e
            for k in 1...8 {
                let u = Float(k) / 8, s = u * u * (3 - 2 * u)
                let d = simd_normalize(simd_normalize(da) * (1 - s) + simd_normalize(db) * s)
                time += seconds / 8
                key(p, e + d * 2.6)
            }
        }
        for (i, point) in path.enumerated() {
            let s = along[i]
            if i > 0 {
                // From the point before to this one, a key every 15 cm.
                let from = along[i - 1], n = max(1, Int(((s - from) / 0.15).rounded(.up)))
                for k in 1...n {
                    let d = from + (s - from) * Float(k) / Float(n)
                    time += (s - from) / Float(n) / speed
                    key(at(d), lookahead(d))
                }
            } else {
                key(point.p, lookahead(0))
            }
            if let mark = point.mark { marks[mark] = time }
            guard point.pause > 0 else { continue }
            if let look = point.look {
                let turns = min(1.0, point.pause / 3)
                turn(point.p, lookahead(s), look, turns)
                time += point.pause - 2 * turns
                key(point.p, look)
                turn(point.p, look, lookahead(s), turns)
            } else {
                time += point.pause
                key(point.p, lookahead(s))
            }
        }
        return (CameraTrack(keys, linear: true), marks)
    }
}

extension PlanDoor {
    /// Across the door's wall, toward `p`'s side of it (unit, in the plan).
    func normal(toward p: SIMD2<Float>) -> SIMD2<Float> {
        let n: SIMD2<Float> = alongX ? [0, 1] : [1, 0]
        return dot(p - at, n) >= 0 ? n : -n
    }
}
