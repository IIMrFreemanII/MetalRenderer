import Foundation
import QuartzCore
import simd

/// What the building workshop's building is, for the building editor: its storeys, rooms and doors, its triangles
/// outside and in, its lights and props, and how long it took to make.
struct BuildingStats: Equatable {
    var style = ""
    var storeys = 0
    var rooms = 0
    var doors = 0
    var shellTriangles = 0
    var interiorTriangles = 0
    var lights = 0
    var props = 0
    var height: Float = 0
    var buildMs = 0.0
    /// Hand edits that found nothing to change.
    var orphaned = 0
}

extension Scene {
    /// The building workshop: one building on its lot, inside and out, as `settings.buildings` says; or a single
    /// building of a city (pinned), or the building between two neighbours, or beside the editor's variations of it.
    /// The building editor rebuilds it at every edit (its styles from `settings.buildingCatalog`), so it is small.
    func buildBuildingWorkshop() {
        let start = CACurrentMediaTime()
        remadeOften = true
        let p = settings.buildings
        var catalog = BuildingCatalog.resolve(settings.buildingCatalog)
        if let other = BuildingCatalog.registered(p.compare) { catalog = other }   // comparing: the saved definitions
        let kit = BuildingKit(self, textures: true)

        // The building: the workshop's own (or a city's, pinned), with its single-building edits.
        let spec = Scene.workshopSpec(p, catalog: catalog).spec
        let building = BuildingGenerator.generate(spec)
        kit.addBuilding(building, at: matrix_identity_float4x4)
        var focus = AABB(lo: [-spec.size.x / 2, 0, -spec.size.y / 2], hi: [spec.size.x / 2, building.height, spec.size.y / 2])
        let site = focus

        // Its street: two neighbours of its style, or the editor's variations of it in a row.
        var others: [(BuildingSpec, SIMD2<Float>)] = []
        if p.layout == .street {
            for side: Float in [-1, 1] {
                var n = spec
                (n.interior, n.cut, n.edits) = (false, nil, [])
                n.seed = spec.seed &+ (side < 0 ? 101 : 202)
                n.floors = max(1, spec.floors + (side < 0 ? -1 : 1))
                others.append((n, SIMD2(side * spec.size.x, 0)))
            }
        } else if p.layout == .mutate, let mutants = BuildingCatalog.registered(p.mutants) {
            for (k, def) in mutants.styles.enumerated() {
                var n = spec
                (n.def, n.interior, n.cut, n.edits) = (def, false, nil, [])
                n.edges = [.street, .open, .open, .open]
                others.append((n, SIMD2(Float(k + 1) * (spec.size.x + 6), 0)))
            }
        }
        for (n, at) in others {
            let made = BuildingGenerator.generate(n)
            kit.addBuilding(made, at: translate([at.x, 0, at.y]))
            focus.grow(AABB(lo: [at.x - n.size.x / 2, 0, at.y - n.size.y / 2], hi: [at.x + n.size.x / 2, made.height, at.y + n.size.y / 2]))
        }

        // The ground: the lot and a pavement round it at the pavement's height, the road in front, a lawn beyond.
        let paving = SurfaceMaterial(color: [0.52, 0.5, 0.47], surface: .paving)
        let asphalt = SurfaceMaterial(color: [0.1, 0.1, 0.11], surface: .asphalt)
        let grass = SurfaceMaterial(color: [0.2, 0.3, 0.13])
        var pavement = MeshBuilder(uvScale: paving.uvScale), road = MeshBuilder(uvScale: asphalt.uvScale), lawn = MeshBuilder()
        let x0 = min(focus.lo.x, site.lo.x) - 6, x1 = max(focus.hi.x, site.hi.x) + 6
        let z0 = site.lo.z - 6, front = site.hi.z + CityPlan.sidewalk
        pavement.box([x0, -0.2, z0], [x1, 0, front], faces: [.top, .sides])
        road.floor(x0: x0 - 200, x1: x1 + 200, z0: front, z1: front + 12, y: -0.15)
        lawn.floor(x0: -2000, x1: 2000, z0: -2000, z1: 2000, y: -0.2)
        kit.add([(paving, pavement), (asphalt, road), (grass, lawn)])
        walkColliders = kit.colliders + [Interior.Collider(lo: [x0, -1, z0], hi: [x1, 0, front]),
                                         Interior.Collider(lo: [-2000, -2, -2000], hi: [2000, -0.15, 2000])]
        kit.addFlashlight()
        walkAreas = [WalkArea(rect: CityPlan.Rect(lo: SIMD2(site.lo.x, site.lo.z), hi: SIMD2(site.hi.x, site.hi.z)), building: building, at: .identity)]

        // The sky: a still sun from the camera's left, or the moon and the city's night.
        if p.night {
            skyColor = [0.006, 0.009, 0.02]
            forcesLightTable = true
            addLight(.sun(angularRadius: 0.0045), color: [0.035, 0.045, 0.07]) { _ in
                LightPose(position: .zero, direction: normalize([0.45, 0.7, 0.35]))
            }
        } else {
            addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1]) { _ in
                let e = Scene.degrees(38), a = Scene.degrees(235)
                return LightPose(position: .zero, direction: [cos(e) * cos(a), sin(e), -cos(e) * sin(a)])
            }
        }
        self.focus = p.layout == .single ? site : focus
        defaultCamera = Camera.framing(self.focus!, fovY: Camera().fovY, yaw: 0.35, pitch: -0.3).camera

        var stats = BuildingStats(style: spec.def.id, storeys: building.plan.storeys.count, height: building.height)
        stats.rooms = building.plan.storeys.reduce(0) { $0 + $1.rooms.count }
        stats.doors = building.plan.storeys.reduce(0) { $0 + $1.doors.filter { $0.kind != .open }.count }
        stats.shellTriangles = building.parts.filter { !$0.slot.isFill }.reduce(0) { $0 + $1.mesh.triangleCount }
        stats.interiorTriangles = building.interior?.triangles ?? 0
        stats.orphaned = building.plan.orphaned.count
        stats.buildMs = (CACurrentMediaTime() - start) * 1000
        buildingStats = stats
        buildingPlan = building.plan
    }

    /// The workshop's building: its spec (with its own plan's edits), and which building it is.
    static func workshopSpec(_ p: BuildingSceneSettings, catalog: BuildingCatalog) -> (spec: BuildingSpec, ref: LotRef) {
        var spec = BuildingSpec(size: p.lot)
        spec.edges = p.sides.edges
        spec.def = catalog.style(id: p.style) ?? BuiltInBuildings.residential
        spec.floors = p.floors
        spec.seed = UInt64(max(p.seed, 0)) &* 0x9E37_79B9 &+ 1
        spec.night = p.night
        spec.lit = 0.65
        var ref = LotRef.workshop(style: p.style, size: p.lot, seed: spec.seed)
        if let pinned = p.pinned, let lot = Scene.cityLot(pinned) {
            ref = pinned
            spec = BuildingSpec(lot: lot.lot, city: lot.city, night: p.night, catalog: catalog)
            spec.lit = 0.65
        }
        if let o = catalog.override(for: ref) { spec.apply(o, catalog: catalog) }
        spec.interior = true
        spec.cut = p.view == .full ? nil : max(p.cut, 0)
        spec.dollhouse = p.view == .dollhouse
        return (spec, ref)
    }

    /// The city lot `ref` names, if its city still has it: rebuilds the city's plan (cheap) to find it.
    static func cityLot(_ ref: LotRef) -> (lot: CityPlan.Lot, city: CitySettings)? {
        let words = ref.context.split(separator: " ")
        guard words.count == 4, words[0] == "city", let seed = Int(words[1]), let blocks = Int(words[2]),
              let style = CityStyle(name: String(words[3])) else { return nil }
        var city = CitySettings()
        (city.blocks, city.style) = (blocks, style)
        let plan = CityPlan(city, seed: seed)
        guard plan.lots.indices.contains(ref.lot) else { return nil }
        let lot = plan.lots[ref.lot]
        guard lot.seed == ref.seed else { return nil }
        // In the workshop it stands at the origin, its front toward +z.
        var moved = lot
        moved.rect = CityPlan.Rect(lo: -lot.size / 2, hi: lot.size / 2)
        moved.yaw = 0
        return (moved, city)
    }
}

/// Where a scene's buildings can be walked in: a building and where it stands (its lot's frame into the scene's).
struct WalkArea {
    var rect: CityPlan.Rect
    var building: Building
    var at: float4x4
}

extension float4x4 {
    static let identity = matrix_identity_float4x4
}
