import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd
import MetalRenderer

/// The city scenes: a generated city (CityPlan lays it out, BuildingGenerator makes each lot's building) by day,
/// under the sun and the atmosphere's sky with a day cycle, or at night, lit by its windows, its street lamps and
/// the moon. Every building is its own, in its lot's frame: one mesh of several materials for everything opaque,
/// one for its glass (Scene.maskGlass) and at night one for its lit blinds and one for its rooms' lamps (a mesh
/// light each). The roads, sidewalks, lamp posts and trees are one mesh too, and at night each block's lamp heads
/// are one emissive mesh.
/// Seeded: the same settings build the same city.
extension Scene {
    func buildCity(_ city: CitySettings, seed: Int, night: Bool) {
        let start = CFAbsoluteTimeGetCurrent()
        let plan = CityPlan(city, seed: seed)

        let kit = BuildingKit(self, textures: city.textures)
        let catalog = BuildingCatalog.resolve(settings.buildingCatalog)
        func gpuMaterial(_ m: SurfaceMaterial) -> GPUMaterial { kit.gpuMaterial(m) }
        func sharedMaterial(_ m: SurfaceMaterial) -> Int { kit.sharedMaterial(m) }
        var triangles = 0
        func add(_ parts: [(material: SurfaceMaterial, mesh: MeshBuilder)], at transform: float4x4 = matrix_identity_float4x4) {
            kit.add(parts, at: transform)
        }
        func builder(_ m: SurfaceMaterial) -> MeshBuilder { MeshBuilder(uvScale: m.uvScale) }

        /// The modules' meshes, by what they are (Building.Module.key): a window's shell is one mesh in the whole city.
        var moduleMeshes: [Data: (mesh: Int, bounds: AABB)] = [:]
        var moduleTriangles = 0, placed = 0
        /// A building of modules: an assembly (Scene.Assembly.rigid) of its own mesh (the walls, roofs,
        /// blinds, rooms: everything opaque that is its alone) and its modules where they are, so that a ray walks the
        /// tree over its parts and then a part's mesh; its glass and its lights are instances of their own, as without
        /// modules. A triangle's material is its slot's: the building's materials are its slots' in their order.
        func addBuilding(_ building: Building, at transform: float4x4) {
            func opaque(_ m: SurfaceMaterial) -> Bool { !m.glass && m.emission == .zero }
            for (_, m, mesh) in building.parts where !opaque(m) && !mesh.isEmpty {
                triangles += mesh.triangleCount
                addInstance(addMesh(mesh.geometry, uvs: mesh.uvs), sharedMaterial(m), transform, mask: m.glass ? Scene.maskGlass : Scene.maskGeometry)
            }
            let first = Building.Slot.allCases.map { addMaterial(gpuMaterial(building.materials[$0.rawValue] ?? SurfaceMaterial(color: .one))) }[0]
            func merged(_ meshes: [MeshBuilder]) -> (mesh: MeshBuilder, offsets: [UInt8]) {
                var merged = MeshBuilder(), offsets: [UInt8] = []
                for slot in Building.Slot.allCases where !meshes[slot.rawValue].isEmpty && building.materials[slot.rawValue].map(opaque) ?? false {
                    offsets += [UInt8](repeating: UInt8(slot.rawValue), count: meshes[slot.rawValue].triangleCount)
                    merged.append(meshes[slot.rawValue])
                }
                return (merged, offsets)
            }
            func box(_ m: MeshBuilder) -> AABB { let b = m.bounds; return AABB(lo: b.lo, hi: b.hi) }
            var parts: [Scene.Assembly.Part] = [], bounds = AABB()
            let own = merged(building.meshes)
            if !own.mesh.isEmpty {
                triangles += own.mesh.triangleCount
                parts.append(Scene.Assembly.Part(mesh: addMesh(own.mesh.geometry, uvs: own.mesh.uvs, materials: own.offsets), transform: matrix_identity_float4x4,
                                                 firstLeaf: .max, bone: 0, bounds: box(own.mesh)))
            }
            for (module, placement) in building.placements {
                let m = building.modules[module]
                let made = moduleMeshes[m.key] ?? {
                    let shell = merged(m.meshes)
                    moduleTriangles += shell.mesh.triangleCount
                    let made = (addMesh(shell.mesh.geometry, uvs: shell.mesh.uvs, materials: shell.offsets), box(shell.mesh))
                    moduleMeshes[m.key] = made
                    return made
                }()
                parts.append(Scene.Assembly.Part(mesh: made.mesh, transform: placement, firstLeaf: .max, bone: 0,
                                                 bounds: made.bounds.transformed(placement)))
                placed += 1
            }
            for part in parts { bounds.grow(part.bounds) }
            guard !parts.isEmpty else { return }
            addInstance(assembly: addAssembly(Scene.Assembly(parts: parts, bounds: bounds, rigid: true)), first, transform)
        }

        // The ground: the roads' asphalt under everything, open ground around the city.
        let asphalt = SurfaceMaterial(color: [0.1, 0.1, 0.11], surface: .asphalt)
        let paving = SurfaceMaterial(color: [0.52, 0.5, 0.47], surface: .paving)
        let earth = SurfaceMaterial(color: [0.3, 0.33, 0.2])
        let grass = SurfaceMaterial(color: [0.2, 0.34, 0.12])
        let e = plan.extent, far = CityPlan.margin
        var roads = builder(asphalt)
        if let canal = plan.canal {
            // The canal: the asphalt either side of it, paved quays down to stone walls, water a metre and a half under
            // them, and a bridge where each street along z crosses it (a deck, a parapet each side).
            let water = canal.water, stone = SurfaceMaterial(color: [0.42, 0.4, 0.37], surface: .paving)
            roads.floor(x0: e.lo.x, x1: e.hi.x, z0: e.lo.y, z1: canal.rect.lo.y, y: 0)
            roads.floor(x0: e.lo.x, x1: e.hi.x, z0: canal.rect.hi.y, z1: e.hi.y, y: 0)
            var quays = builder(stone)
            for (z0, z1) in [(canal.rect.lo.y, water.lo.y), (water.hi.y, canal.rect.hi.y)] {
                quays.box([e.lo.x, 0, z0], [e.hi.x, 0.15, z1], faces: [.sides, .top])
            }
            quays.box([e.lo.x - far, -CityPlan.canalBed - 0.3, water.lo.y - 0.6], [e.hi.x + far, 0.15, water.lo.y], faces: [.sides, .top])
            quays.box([e.lo.x - far, -CityPlan.canalBed - 0.3, water.hi.y], [e.hi.x + far, 0.15, water.hi.y + 0.6], faces: [.sides, .top])
            for street in plan.streets where street.along == 1 {
                let x0 = street.rect.lo.x, x1 = street.rect.hi.x
                roads.box([x0, -0.7, water.lo.y], [x1, 0, water.hi.y], faces: [.sides, .top, .bottom])
                quays.box([x0, 0, water.lo.y], [x0 + 0.35, 1.0, water.hi.y], faces: [.sides, .top])
                quays.box([x1 - 0.35, 0, water.lo.y], [x1, 1.0, water.hi.y], faces: [.sides, .top])
            }
        } else {
            roads.floor(x0: e.lo.x, x1: e.hi.x, z0: e.lo.y, z1: e.hi.y, y: 0)
        }
        // The open ground: the terrain "city-<seed>" (Terrain Editor), 4 m a cell, level 3 cm under the asphalt and kept
        // so under the streets and blocks (protected from the brushes). Its sectors' instances after everything else's.
        let groundSize = max(e.size.x, e.size.y) + 2 * far, groundCells = Int((groundSize / 4).rounded(.up))
        let groundGrid = TerrainGrid.square(size: Float(groundCells) * 4, cells: groundCells,
                                            center: SIMD2(Double(e.center.x), Double(e.center.y)))
        // The canal's bed is cut into it (and on through the open ground out to its edge, between grassy banks there),
        // its water a lake filling the cut.
        var shapes = TerrainShapes()
        var canalWater: [WaterBody] = []
        if let canal = plan.canal {
            let water = canal.water
            shapes.flats.append(TerrainShapes.Flat(lo: SIMD2(e.lo.x - far, water.lo.y), hi: SIMD2(e.hi.x + far, water.hi.y), level: -CityPlan.canalBed,
                                                   blend: 8, protect: true))
            var look = WaterLook.preset(.lake)
            look.waves = 0.06
            look.absorption = [0.6, 0.18, 0.25]
            var body = WaterBody(name: "Canal", kind: .lake, level: -CityPlan.canalLevel, seed: SIMD2(0, Double(water.center.y)))
            body.look = look
            canalWater.append(body)
        }
        let groundBase = ShapedTerrainBase(FlatTerrainBase(grid: groundGrid, level: -0.03, protect: [(e.lo - 2, e.hi + 2)]), shapes: shapes)
        let groundEntry = Scene.openTerrain("city-\(seed)", base: groundBase, layers: TerrainDocument.sceneLayers())
        let earthMaterial = sharedMaterial(earth)
        defer {
            addTerrain(name: groundEntry.document.name, field: groundEntry.field, tiles: groundGrid.tiles!.map { ($0, 0) },
                       style: TerrainMeshStyle(uvOrigin: groundGrid.origin, uvScale: earth.uvScale), material: earthMaterial,
                       generatedWater: canalWater)
        }

        // The roads' centre lines: dashes a centimetre proud of the asphalt, none where two roads cross.
        let paint = SurfaceMaterial(color: [0.7, 0.7, 0.66])
        var lines = builder(paint)
        for street in plan.streets where plan.canal.map({ $0.rect != street.rect }) ?? true {
            let along = street.along, r = street.rect
            let length = along == 1 ? r.size.y : r.size.x, start = along == 1 ? r.lo.y : r.lo.x
            let middle = along == 1 ? r.center.x : r.center.y
            for k in 0..<Int(length / 8) {
                let at = start + 4 + Float(k) * 8
                let c = along == 1 ? SIMD2(middle, at) : SIMD2(at, middle)
                if plan.streets.contains(where: { $0.along != along && $0.rect.inset(-2).contains(CityPlan.Rect(lo: c, hi: c)) }) { continue }
                let half: SIMD2<Float> = along == 1 ? SIMD2(0.08, 1.5) : SIMD2(1.5, 0.08)
                lines.box([c.x - half.x, 0, c.y - half.y], [c.x + half.x, 0.012, c.y + half.y], faces: [.sides, .top])
            }
        }

        // The blocks: a raised sidewalk under each (its top is the courtyards' ground too), a lawn on a park.
        var sidewalks = builder(paving), lawns = builder(grass)
        for block in plan.blocks {
            let r = block.rect
            sidewalks.box([r.lo.x, 0, r.lo.y], [r.hi.x, 0.15, r.hi.y], faces: [.sides, .top])
            if block.park {
                let lawn = r.inset(CityPlan.sidewalk)
                lawns.box([lawn.lo.x, 0.15, lawn.lo.y], [lawn.hi.x, 0.22, lawn.hi.y], faces: [.sides, .top])
            }
        }

        // Street lamps (at night their heads are one emissive mesh per block) and trees.
        let iron = SurfaceMaterial(color: [0.07, 0.075, 0.08])
        let bark = SurfaceMaterial(color: [0.25, 0.18, 0.12])
        let leaves = SurfaceMaterial(color: [0.12, 0.26, 0.08])
        let lampLight = SurfaceMaterial(color: .zero, emission: SIMD3<Float>(1.0, 0.78, 0.5) * 140)
        var posts = builder(iron), heads = [MeshBuilder](repeating: MeshBuilder(), count: plan.blocks.count)
        for lamp in plan.lamps {
            let p = SIMD3<Float>(lamp.position.x, 0.15, lamp.position.y), out = SIMD3<Float>(lamp.toRoad.x, 0, lamp.toRoad.y)
            let side = SIMD3<Float>(-out.z, 0, out.x)
            posts.cylinder(p, radius: 0.08, topRadius: 0.05, height: 6.2, segments: 8)
            // An arm over the road with the head at its end; the head's underside is the light.
            let a = p + [0, 6.1, 0], b = a + out * 1.6
            posts.box(simd_min(a - side * 0.04, b + side * 0.04) - [0, 0.04, 0], simd_max(a - side * 0.04, b + side * 0.04) + [0, 0.04, 0])
            let c = b - out * 0.35
            let lo = simd_min(c - side * 0.14 - out * 0.3, c + side * 0.14 + out * 0.3), hi = simd_max(c - side * 0.14 - out * 0.3, c + side * 0.14 + out * 0.3)
            posts.box(lo - [0, 0.14, 0], hi - [0, 0.04, 0], faces: [.sides, .top])
            if night {
                heads[lamp.block].floor(x0: lo.x, x1: hi.x, z0: lo.z, z1: hi.z, y: lo.y - 0.14, up: false)
            } else {
                posts.floor(x0: lo.x, x1: hi.x, z0: lo.z, z1: hi.z, y: lo.y - 0.14, up: false)
            }
        }
        var trunks = builder(bark), crowns = builder(leaves)
        for tree in plan.trees {
            let p = SIMD3<Float>(tree.x, 0.15, tree.y), size = tree.z
            trunks.cylinder(p, radius: 0.16 * size, topRadius: 0.1 * size, height: 2.6 * size, segments: 6, cap: false)
            crowns.ball(p + [0, 3.9 * size, 0], radius: SIMD3(1.7, 1.9, 1.7) * size)
        }
        add([(asphalt, roads), (paint, lines), (paving, sidewalks), (grass, lawns), (iron, posts), (bark, trunks),
             (leaves, crowns)])
        for head in heads { add([(lampLight, head)]) }

        // The buildings: generated in parallel a batch at a time (each lot has its own seed, so the order they are
        // made in doesn't matter), then added in the lots' order.
        // With modules, each building is an assembly of its windows' shells and the rest of it.
        let refs = plan.lots.enumerated().map { LotRef.city(city, seed: seed, lot: $0, $1) }
        let specs = plan.lots.enumerated().map { i, lot in
            var spec = BuildingSpec(lot: lot, city: city, night: night, catalog: catalog)
            spec.modules = city.modules
            if let o = catalog.override(for: refs[i]) { spec.apply(o, catalog: catalog) }
            // The building the camera is near: its interior, and no windows as modules (its own meshes).
            if settings.interior == refs[i].key { (spec.interior, spec.modules) = (true, false) }
            return spec
        }
        var solids: [Interior.Collider] = []
        let batch = 96
        var tallest: Float = 0, windows = 0, rooms = 0
        for first in stride(from: 0, to: specs.count, by: batch) {
            let count = min(batch, specs.count - first)
            var built = [Building?](repeating: nil, count: count)
            built.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: count) { i in out[i] = BuildingGenerator.generate(specs[first + i]) }
            }
            for (i, building) in built.enumerated() {
                guard let building else { continue }
                tallest = max(tallest, building.height)
                let lot = plan.lots[first + i]
                let a = lot.transform * SIMD4(-lot.size.x / 2, 0, -lot.size.y / 2, 1), b = lot.transform * SIMD4(lot.size.x / 2, 0, lot.size.y / 2, 1)
                lotAreas.append((refs[first + i].key, CityPlan.Rect(lo: SIMD2(min(a.x, b.x), min(a.z, b.z)), hi: SIMD2(max(a.x, b.x), max(a.z, b.z))),
                                 building.height))
                if building.interior != nil {
                    walkAreas.append(WalkArea(rect: lot.rect, building: building, at: lot.transform))
                } else {
                    // What the walker meets of a building without its interior: a box over each part of its plan.
                    for tier in building.tiers {
                        for r in tier.footprint.cover {
                            let a = lot.transform * SIMD4(r.lo.x, 0, r.lo.y, 1), b = lot.transform * SIMD4(r.hi.x, 0, r.hi.y, 1)
                            solids.append(Interior.Collider(lo: SIMD3(min(a.x, b.x), 0, min(a.z, b.z)), hi: SIMD3(max(a.x, b.x), tier.top, max(a.z, b.z))))
                        }
                    }
                }
                object("Buildings/Lot \(first + i)", assets: [AssetKey(kind: .buildingStyle, name: specs[first + i].def.id)]) {
                    if building.placements.isEmpty {
                        // Named: another scene of the same city (another building's interior in it) keeps its structures.
                        kit.addBuilding(building, at: plan.lots[first + i].transform,
                                        name: building.interior == nil ? "city \(refs[first + i].key) \(catalog.fingerprint)" : nil)
                    } else {
                        addBuilding(building, at: plan.lots[first + i].transform)
                    }
                }
                windows += building.windows
                rooms += building.rooms
            }
        }

        // The walker's ground: the roads, the blocks' raised pavements (and the canal's quays and bridges: its water, the
        // terrain under it).
        if let canal = plan.canal {
            let water = canal.water
            solids.append(Interior.Collider(lo: SIMD3(e.lo.x - far, -2, e.lo.y - far), hi: SIMD3(e.hi.x + far, 0, water.lo.y)))
            solids.append(Interior.Collider(lo: SIMD3(e.lo.x - far, -2, water.hi.y), hi: SIMD3(e.hi.x + far, 0, e.hi.y + far)))
            for (z0, z1) in [(canal.rect.lo.y, water.lo.y), (water.hi.y, canal.rect.hi.y)] {
                solids.append(Interior.Collider(lo: SIMD3(e.lo.x, 0, z0), hi: SIMD3(e.hi.x, 0.15, z1)))
            }
            for street in plan.streets where street.along == 1 {
                solids.append(Interior.Collider(lo: SIMD3(street.rect.lo.x, -0.7, water.lo.y), hi: SIMD3(street.rect.hi.x, 0, water.hi.y)))
            }
        } else {
            solids.append(Interior.Collider(lo: SIMD3(e.lo.x - far, -2, e.lo.y - far), hi: SIMD3(e.hi.x + far, 0, e.hi.y + far)))
        }
        for block in plan.blocks {
            solids.append(Interior.Collider(lo: SIMD3(block.rect.lo.x, 0, block.rect.lo.y), hi: SIMD3(block.rect.hi.x, 0.15, block.rect.hi.y)))
        }
        walkColliders = kit.colliders + solids
        kit.addFlashlight()

        if night {
            skyColor = [0.006, 0.009, 0.02]
            forcesLightTable = true
            // The moon.
            addLight(.sun(angularRadius: 0.0045), color: [0.035, 0.045, 0.07]) { _ in
                LightPose(position: .zero, direction: normalize([0.45, 0.7, 0.35]))
            }
        } else {
            // The sun: from the south-east in the morning (+x, +z) over the south to the west and back, 90 s each
            // way; t = 0 is mid-morning. It stays 12 degrees or more above the horizon (the exposure is fixed) and
            // never looks straight down a street. Its colour comes from the atmosphere.
            addLight(.sun(angularRadius: 0.27 * .pi / 180), color: [1, 1, 1]) { t in
                let phase = DaySweep.city.phase(t)   // 0 = morning, 1 = evening
                let elevation = (12 + 46 * sin(.pi * phase)) * Float.pi / 180, azimuth = (25 + 130 * phase) * Float.pi / 180
                return LightPose(position: .zero, direction: [cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth)])
            }
        }
        defaultCamera = plan.camera(.overview)

        print(String(format: "City: %d x %d blocks, %d buildings up to %.0f m, %d windows (%d with rooms), %d triangles in %d instances, "
                     + "%d materials, built in %.2f s", city.blocks, city.blocks, specs.count, tallest, windows, rooms, triangles + kit.triangles,
                     instances.count, materials.count, CFAbsoluteTimeGetCurrent() - start)
              + (placed > 0 ? String(format: "; %d modules of %d triangles placed %d times", moduleMeshes.count, moduleTriangles, placed) : ""))
    }
}
